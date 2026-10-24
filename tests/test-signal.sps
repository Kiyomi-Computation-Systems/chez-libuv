#!r6rs
;;; SRFI-64 suite for (libuv signal).
;;;
;;; HARNESS RULES: every wait whose predicate depends on a callback is
;;; run-until/ticking with an iteration cap; sentinels are symbols, never
;;; #f or 0; every callback (collect)s; EVERY self-sent signal has a
;;; continuous GUARD watcher armed on its signum -- except in the spawned
;;; child whose death IS the assertion. When the last watcher on a signum
;;; stops, libuv leaves SIG_DFL, not the handler that was there before, so
;;; an unwatched self-send kills this suite. The guard also gives each
;;; negative row a positive event to wait for: send once, run until the
;;; guard's counter moves, then assert the probed watcher's count.
;;;
;;; NOT pure: (libuv loop) reaches (libuv private native). Never add this
;;; to the Makefile's PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv timer)
        (libuv signal)
        (libuv process)
        (libuv pipe)
        (libuv stream)
        (libuv private conditions)
        (uv-testing)
        (only (uv-evidence) live-count)
        (only (uv-describe) describe)
        (only (chezscheme) collect getenv))

(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner prints only a failing row's title. The E2E rows answer
;; what they found as their actual value (an early exit's status, how the
;; child's pipe ended), so print that too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

(test-begin "signal")

(define signal-base (live-count 'signal))

;; Mode is deliberately not public; the suite observes "no mode
;; pinned" behaviorally: BOTH verbs still being willing to validate past
;; the mode check is what an unpinned handle looks like. This probe asks
;; with a deliberately-invalid callback so nothing is ever armed: reaching
;; 'on-signal-not-a-procedure means the mode gate passed.
(define (signal-mode-via-behavior sig)
  (define (gate-passes? verb)
    (guard (e ((uv-invalid-argument? e)
               (eq? (uv-invalid-argument-reason e) 'on-signal-not-a-procedure)))
      (verb sig 'sigusr1 'not-a-procedure)
      #f))
  (not (and (gate-passes? uv-signal-start!)
            (gate-passes? uv-signal-start-oneshot!))))

;; --- construction and close (the whole explicit-close lifecycle) --------
(define l0 (make-uv-loop))
(define s0 (make-uv-signal l0))

(test-assert "make-uv-signal answers an open signal handle"
  (and (uv-signal? s0) (uv-handle-open? s0)))

(test-assert "a signal handle is not a timer, and vice versa"
  (and (not (uv-timer? s0))
       (not (uv-signal? (make-uv-timer l0)))))

(test-equal "the signal counter counts the construction"
  (+ signal-base 1) (live-count 'signal))

(uv-close! s0)
(test-equal "close drains to 'closed"
  'satisfied (run-until l0 (lambda () (eq? (uv-handle-state s0) 'closed)) 64))

(uv-close! s0)  ;; a second close on 'closed is the documented no-op
(test-equal "close is idempotent and the state stays 'closed"
  'closed (uv-handle-state s0))

;; --- the teardown sweep (handle-kinds membership) ------------------------
(define s1 (make-uv-signal l0))
(uv-loop-teardown! l0)
(test-equal "teardown swept the open signal handle to 'closed"
  'closed (uv-handle-state s1))

(test-equal "signal counter balanced after teardown"
  signal-base (live-count 'signal))

;; --- the refusal matrix -------------------------------------------------
(define l2 (make-uv-loop))
(define sv (make-uv-signal l2))

(define (start-refusal sig-arg cb)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-signal-start! sv sig-arg cb)
    'no-raise))

(test-equal "sigkill is refused as unwatchable, before any native call"
  '(uv-signal-start! signal-unwatchable)
  (start-refusal 'sigkill (lambda (s) s)))

(test-equal "sigstop is refused as unwatchable"
  '(uv-signal-start! signal-unwatchable)
  (start-refusal 'sigstop (lambda (s) s)))

(test-equal "exact 0 is sending vocabulary, unknown to watching"
  '(uv-signal-start! signal-unknown)
  (start-refusal 0 (lambda (s) s)))

(test-equal "a raw integer is refused even where it is right (15)"
  '(uv-signal-start! signal-unknown)
  (start-refusal 15 (lambda (s) s)))

(test-equal "an unknown symbol is refused"
  '(uv-signal-start! signal-unknown)
  (start-refusal 'sigfoo (lambda (s) s)))

(test-equal "a non-procedure callback is refused by name"
  '(uv-signal-start! on-signal-not-a-procedure)
  (start-refusal 'sigusr1 'not-a-procedure))

(test-equal "a non-handle is refused by name"
  '(uv-signal-start! not-a-uv-signal)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e))))
    (uv-signal-start! "nope" 'sigusr1 (lambda (s) s))
    'no-raise))

(test-equal "a timer handle is the wrong kind, refused by name"
  '(uv-signal-start! not-a-uv-signal)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e))))
    (uv-signal-start! (make-uv-timer l2) 'sigusr1 (lambda (s) s))
    'no-raise))

(test-equal "a refused start pinned no mode"
  'no-mode (if (not (signal-mode-via-behavior sv)) 'no-mode 'pinned))

;; --- mode fixedness -----------------------------------------------------
;; libuv's oneshot flag is one-way per handle: a oneshot start sets it,
;; only uv_signal_init clears it, and a same-signum start leaves it as it
;; is. So the first start fixes the handle's mode, and the other mode's
;; verb is refused rather than half obeyed.
;; sv becomes continuous; the oneshot verb must then refuse, armed or not.
(define sv-fired '())
(uv-signal-start! sv 'sigusr1 (lambda (s) (set! sv-fired (cons s sv-fired)) (collect)))

(test-equal "the oneshot verb on a continuous-mode handle raises 'signal-mode-fixed"
  '(uv-signal-start-oneshot! signal-mode-fixed)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e))))
    (uv-signal-start-oneshot! sv 'sigusr2 (lambda (s) s))
    'no-raise))

(uv-signal-stop! sv)
(test-equal "mode survives stop: still refused after uv-signal-stop!"
  '(uv-signal-start-oneshot! signal-mode-fixed)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e))))
    (uv-signal-start-oneshot! sv 'sigusr1 (lambda (s) s))
    'no-raise))

;; The mode is checked in the start's step, after its arguments, so a
;; start that has both faults is refused for its callback.
(test-equal "a start in the other mode whose callback is not a procedure is refused for the callback"
  '(uv-signal-start-oneshot! on-signal-not-a-procedure)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e))))
    (uv-signal-start-oneshot! sv 'sigusr1 'not-a-procedure)
    'no-raise))

(define os (make-uv-signal l2))
(uv-signal-start-oneshot! os 'sigusr2 (lambda (s) (collect)))
(test-equal "the continuous verb on a oneshot-mode handle raises 'signal-mode-fixed"
  '(uv-signal-start! signal-mode-fixed)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e))))
    (uv-signal-start! os 'sigusr2 (lambda (s) s))
    'no-raise))

;; --- delivery (guard discipline: sv re-armed continuous on sigusr1) -----
(uv-signal-start! sv 'sigusr1 (lambda (s) (set! sv-fired (cons s sv-fired)) (collect)))
(uv-kill! (uv-os-getpid) 'sigusr1)
(test-equal "a self-sent SIGUSR1 arrives as its symbol"
  '(satisfied (sigusr1))
  (list (run-until/ticking l2 (lambda () (pair? sv-fired)) 512) sv-fired))

;; Two watchers on one signum both fire on one delivery.
(define twin-fired '())
(define twin (make-uv-signal l2))
(uv-signal-start! twin 'sigusr1
                  (lambda (s) (set! twin-fired (cons s twin-fired)) (collect)))
(set! sv-fired '())
(uv-kill! (uv-os-getpid) 'sigusr1)
(test-equal "both watchers on one signum fire once each"
  '(satisfied (sigusr1) (sigusr1))
  (list (run-until/ticking l2
                           (lambda () (and (pair? sv-fired) (pair? twin-fired)))
                           512)
        sv-fired twin-fired))

;; --- stop is idempotent; closed handles refuse by state -----------------
;; uv_signal_stop answers 0 on a watcher never started, so both stops
;; return, and neither closes it. A refusal comes back as the row's value.
(define never-started (make-uv-signal l2))
(test-equal "stop on a never-started watcher returns, twice, and leaves it open"
  '(stopped-twice open)
  (guard (e (#t (list 'raised (describe e))))
    (uv-signal-stop! never-started)
    (uv-signal-stop! never-started)
    (list 'stopped-twice (uv-handle-state never-started))))

(uv-close! never-started)
(run-until l2 (lambda () (eq? (uv-handle-state never-started) 'closed)) 64)
(test-equal "verbs on a closed handle raise &uv-handle-closed naming 'signal"
  'signal
  (guard (e ((uv-handle-closed? e) (uv-handle-closed-kind e)))
    (uv-signal-stop! never-started)
    'no-raise))

(uv-loop-teardown! l2)
(test-equal "signal counter balanced after the verb sections"
  signal-base (live-count 'signal))

;; ========================================================================
;; The measured-behavior sections: each holds a libuv behavior measured
;; alike on macOS and Linux, so a red row here indicts the binding.
;; ========================================================================
(define l3 (make-uv-loop))
(define g3-fired 0)   ; the section guard: continuous on sigusr1, armed throughout
(define g3 (make-uv-signal l3))
(uv-signal-start! g3 'sigusr1 (lambda (s) (set! g3-fired (+ g3-fired 1)) (collect)))

(define (send-usr1-and-wait-guard!)
  (let ((before g3-fired))
    (uv-kill! (uv-os-getpid) 'sigusr1)
    (run-until/ticking l3 (lambda () (> g3-fired before)) 512)))

;; --- oneshot: exactly once, rearm-outside works -------------------------
(define once-fired 0)
(define once (make-uv-signal l3))
(uv-signal-start-oneshot! once 'sigusr1
                          (lambda (s) (set! once-fired (+ once-fired 1)) (collect)))
(test-equal "oneshot fires on the first delivery" 'satisfied (send-usr1-and-wait-guard!))
(test-equal "…exactly once" 1 once-fired)
(test-equal "a second send reaches only the guard" 'satisfied (send-usr1-and-wait-guard!))
(test-equal "the oneshot stayed disarmed (auto-disarm)" 1 once-fired)
(test-equal "stop on an auto-disarmed oneshot watcher returns, and leaves it open"
  '(stopped open)
  (guard (e (#t (list 'raised (describe e))))
    (uv-signal-stop! once)
    (list 'stopped (uv-handle-state once))))
(uv-signal-start-oneshot! once 'sigusr1
                          (lambda (s) (set! once-fired (+ once-fired 1)) (collect)))
(test-equal "rearm from OUTSIDE the callback delivers again"
  'satisfied (send-usr1-and-wait-guard!))
(test-equal "…and again exactly once" 2 once-fired)

;; --- an in-callback rearm is silently undone ----------------------------
;; libuv's oneshot auto-stop runs after the signal callback returns.
(define incb-fired 0)
(define incb (make-uv-signal l3))
(define (incb-cb s)
  (set! incb-fired (+ incb-fired 1))
  ;; The rearm attempt the vendor auto-stop undoes after this returns.
  (uv-signal-start-oneshot! incb 'sigusr1 incb-cb)
  (collect))
(uv-signal-start-oneshot! incb 'sigusr1 incb-cb)
(test-equal "in-callback-rearm oneshot fires" 'satisfied (send-usr1-and-wait-guard!))
(test-equal "the in-callback rearm did NOT take effect: second send silent"
  'satisfied (send-usr1-and-wait-guard!))
(test-equal "…count still 1" 1 incb-fired)

;; --- continuous rearm across a signum change ----------------------------
;; A signum change is a stop and a start inside uv_signal_start.
(define sw-fired-1 0)
(define sw-fired-2 0)
(define sw (make-uv-signal l3))
(uv-signal-start! sw 'sigusr1 (lambda (s) (set! sw-fired-1 (+ sw-fired-1 1)) (collect)))
(test-equal "armed on the old signum" 'satisfied (send-usr1-and-wait-guard!))
(test-equal "…delivered" 1 sw-fired-1)
;; Switch signum while armed -- and arm a sigusr2 guard FIRST, by the
;; guard rule above.
(define g3b-fired 0)
(define g3b (make-uv-signal l3))
(uv-signal-start! g3b 'sigusr2 (lambda (s) (set! g3b-fired (+ g3b-fired 1)) (collect)))
(uv-signal-start! sw 'sigusr2 (lambda (s) (set! sw-fired-2 (+ sw-fired-2 1)) (collect)))
(test-equal "after the switch, the old signum reaches only its guard"
  'satisfied (send-usr1-and-wait-guard!))
(test-equal "…switched watcher silent on old signum" 1 sw-fired-1)
(uv-kill! (uv-os-getpid) 'sigusr2)
(test-equal "…and fires on the new signum"
  'satisfied (run-until/ticking l3 (lambda () (positive? sw-fired-2)) 512))

;; --- same-signum restart swaps the callback, keeps pending --------------
;; libuv swaps only the callback: the OS handler stays registered, and a
;; delivery pending at the restart reaches the new callback.
;; ITS OWN DRAIN, apart from the stop-suppression probe below: libuv
;; suppresses a stopped watcher's pending delivery by comparing signums at
;; dispatch, not by purging it, so a same-signum rearm before the next run
;; can bring a delivery from before the stop back.
(define swap-old 0)
(define swap-new 0)
(define swap (make-uv-signal l3))
(uv-signal-start! swap 'sigusr2 (lambda (s) (set! swap-old (+ swap-old 1)) (collect)))
(let ((before g3b-fired))
  (uv-kill! (uv-os-getpid) 'sigusr2)          ; pending: accepted inside kill
  (uv-signal-start! swap 'sigusr2             ; same-signum swap, PRE-run
                    (lambda (s) (set! swap-new (+ swap-new 1)) (collect)))
  (test-equal "the guard proves the pending delivery was dispatched"
    'satisfied (run-until/ticking l3 (lambda () (> g3b-fired before)) 512)))
(test-equal "the swap preserved the pending delivery for the NEW callback"
  '(0 1) (list swap-old swap-new))

;; --- send -> stop -> run suppression (the discriminating shape) --------
;; A delivery pending when its watcher stops is suppressed for it. B, on
;; the same signum, shows the event was dispatched, so A's silence is
;; suppression and not a delivery still to come; B also keeps libuv's
;; disposition installed.
(define ev5-a 0)
(define ev5-b 0)
(define ev5-A (make-uv-signal l3))
(define ev5-B (make-uv-signal l3))
(uv-signal-start! ev5-A 'sigusr2 (lambda (s) (set! ev5-a (+ ev5-a 1)) (collect)))
(uv-signal-start! ev5-B 'sigusr2 (lambda (s) (set! ev5-b (+ ev5-b 1)) (collect)))
(uv-kill! (uv-os-getpid) 'sigusr2)            ; accepted synchronously
(uv-signal-stop! ev5-A)                       ; stop A BEFORE the next run
(test-equal "B's delivery proves the event was dequeued"
  'satisfied (run-until/ticking l3 (lambda () (positive? ev5-b)) 512))
(test-equal "A's silence proves suppression" 0 ev5-a)

;; --- a raising callback rides store-and-reraise, counters balance -------
(define boom (make-uv-signal l3))
(uv-signal-start! boom 'sigusr1 (lambda (s) (collect) (raise 'signal-boom)))
(uv-kill! (uv-os-getpid) 'sigusr1)
(test-equal "a callback raise surfaces from uv-run as &uv-callback-error"
  'signal-boom
  (guard (e ((uv-callback-error? e) (uv-callback-error-cause e)))
    (let drain ((i 0))
      (if (< i 512) (begin (uv-run l3 'once) (drain (+ i 1))) 'never-raised))))
(uv-signal-stop! boom)

;; --- close with a delivery pending --------------------------------------
;; uv_close stops an armed watcher, and a signal handle's close callback
;; may be deferred across loop iterations while trapped signals drain, so
;; the wait counts no particular iteration.
(define ev10-fired 0)
(define ev10 (make-uv-signal l3))
(uv-signal-start! ev10 'sigusr1
                  (lambda (s) (set! ev10-fired (+ ev10-fired 1)) (collect)))
(define g3-before-ev10 g3-fired)              ; snapshot BEFORE the send
(uv-kill! (uv-os-getpid) 'sigusr1)            ; pending for ev10 AND guard g3
(uv-close! ev10)                              ; close BEFORE the next run
(test-equal "the close drains (iteration-agnostic: signal closes may defer)"
  'satisfied
  (run-until/ticking l3 (lambda () (eq? (uv-handle-state ev10) 'closed)) 512))
(test-equal "the closing watcher's callback was suppressed" 0 ev10-fired)
(test-assert "the guard still got THIS delivery (delta, not cumulative)"
  (> g3-fired g3-before-ev10))

;; --- an armed watcher keeps the loop alive ------------------------------
(test-assert "the loop is alive while watchers are armed"
  (uv-loop-alive? l3))

(uv-loop-teardown! l3)
(test-equal "teardown swept every armed watcher; counters balanced"
  signal-base (live-count 'signal))

;; ========================================================================
;; End-to-end graceful shutdown, with tests/signal-child.sps.
;; Three-ack handshake: the second kill gates on DISARMED, never GOT1.
;; ========================================================================
(define chez-exe (getenv "CHEZ_LIBUV_TEST_CHEZ"))

(if (not chez-exe)
    (test-equal "E2E graceful shutdown SKIPPED: CHEZ_LIBUV_TEST_CHEZ unset (run via make test)"
      'skipped 'skipped)
    (let ((l4 (make-uv-loop)))
      (define out (make-byte-collector))
      (define eof-mark 'not-yet)
      (define done 'not-yet)
      (define child-out (make-uv-pipe l4))
      (define proc
        (uv-spawn! l4 chez-exe
                   ;; argv[0] = the REAL binary name, never a hardcoded
                   ;; "chez": Chez resolves its boot files by the invoked
                   ;; name, so argv[0] "chez" against a scheme-named install
                   ;; hunts for a nonexistent chez.boot and dies of SIGABRT
                   ;; before its first write, silently even with stderr
                   ;; inherited.
                   (list chez-exe "--program" "tests/signal-child.sps")
                   (list (cons 'stdio (list 'ignore
                                            (list 'pipe child-out 'from-child))))
                   (lambda (status sig) (collect) (set! done (list status sig)))))
      (define (ack-lines)
        (let ((s (utf8->string (collector-bytes out))))
          (let count ((i 0) (n 0))
            (if (= i (string-length s))
                n
                (count (+ i 1) (if (char=? (string-ref s i) #\newline) (+ n 1) n))))))
      ;; Every gate FAILS BY NAME when the child exits early, carrying the
      ;; exit payload -- and the kills are guarded on the child being alive
      ;; -- so a dead child fails one row with evidence instead of crashing
      ;; the whole suite on a later ESRCH uv-kill!, which would hide all
      ;; evidence, the child's exit status included.
      (define (await-acks n cap)
        (let ((w (run-until/ticking
                  l4 (lambda () (or (>= (ack-lines) n) (pair? done))) cap)))
          (cond ((>= (ack-lines) n) 'acked)
                ((pair? done) (list 'child-exited-early done))
                (else w))))
      (define (kill-child!)
        (if (pair? done)
            (list 'child-already-exited done)
            (begin (uv-kill! (uv-process-pid proc) 'sigterm) 'sent)))
      (uv-read-start! child-out
                      (lambda (bv start end) (collect) (collect-span! out bv start end))
                      (lambda () (collect) (set! eof-mark 'eof))
                      (lambda (err) (collect) (set! eof-mark (list 'error err))))

      (test-equal "the child armed and acked READY"
        'acked (await-acks 1 4096))

      (test-equal "the first kill is sent to a live child"
        'sent (kill-child!))

      (test-equal "the child acked delivery (GOT1, from inside the callback)"
        'acked (await-acks 2 4096))

      (test-equal "the child acked disarm (DISARMED, from a later dispatch)"
        'acked (await-acks 3 4096))

      (test-equal "the second kill is sent to a live child, gated on DISARMED"
        'sent (kill-child!))

      (test-equal "the child exited"
        'satisfied (run-until/ticking l4 (lambda () (pair? done)) 4096))
      (test-equal "…killed by the second SIGTERM: (0 sigterm) -- graceful then killed"
        '(0 sigterm) done)
      ;; A short transcript fails carrying how the pipe ended: at EOF, by a
      ;; read error, or not yet.
      (let ((acks "READY\nGOT1\nDISARMED\n"))
        (test-equal "the ack transcript is exactly READY/GOT1/DISARMED"
          acks
          (let ((transcript (utf8->string (collector-bytes out))))
            (if (string=? transcript acks)
                transcript
                (list transcript 'pipe eof-mark)))))

      (uv-loop-teardown! l4)
      (test-equal "signal counter balanced after the E2E"
        signal-base (live-count 'signal))))

(test-end "signal")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
