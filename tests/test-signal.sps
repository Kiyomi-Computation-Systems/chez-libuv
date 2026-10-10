#!r6rs
;;; SRFI-64 suite for (libuv signal) -- v0.4 (design spec
;;; .plans/2026-08-22-chez-libuv-v0.4-signal-design.md §9.3, ADR-0017).
;;;
;;; HARNESS RULES (§9.1/§9.2): every wait whose predicate depends on a
;;; callback is run-until/ticking with an iteration cap; sentinels are
;;; symbols, never #f or 0; every callback (collect)s; EVERY self-sent
;;; signal has a continuous GUARD watcher armed on its signum (EV-3: an
;;; unwatched self-send lands on SIG_DFL and kills this suite) -- except in
;;; the spawned child whose death IS the assertion.
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
        (only (chezscheme) collect getenv))

(define runner (test-runner-simple))
(test-runner-current runner)

(test-begin "signal")

(define signal-base (live-count 'signal))

;; Mode is deliberately not public (§4.4); the suite observes "no mode
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

;; --- construction and close (the whole ADR-0007 lifecycle) --------------
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

;; --- the teardown sweep (handle-kinds membership, spec §5.1) ------------
(define s1 (make-uv-signal l0))
(uv-loop-teardown! l0)
(test-equal "teardown swept the open signal handle to 'closed"
  'closed (uv-handle-state s1))

(test-equal "signal counter balanced after teardown"
  signal-base (live-count 'signal))

;; --- the refusal matrix (§4.2, ADR-0017) --------------------------------
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

;; --- mode fixedness (D10, EV-8 -- measured) -----------------------------
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

;; The mode is checked in the start's step, after its arguments (#86), so a
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

;; EV-6: two watchers on one signum both fire on one delivery.
(define twin-fired '())
(define twin (make-uv-signal l2))
(uv-signal-start! twin 'sigusr1
                  (lambda (s) (set! twin-fired (cons s twin-fired)) (collect)))
(set! sv-fired '())
(uv-kill! (uv-os-getpid) 'sigusr1)
(test-equal "both watchers on one signum fire once each (EV-6)"
  '(satisfied (sigusr1) (sigusr1))
  (list (run-until/ticking l2
                           (lambda () (and (pair? sv-fired) (pair? twin-fired)))
                           512)
        sv-fired twin-fired))

;; --- stop is idempotent (EV-2); closed handles refuse by state ----------
(define never-started (make-uv-signal l2))
(uv-signal-stop! never-started)
(uv-signal-stop! never-started)
(test-assert "stop on a never-started watcher is rc 0, twice (EV-2)"
  #t)

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
;; The measured-behavior sections (spike/signal/FINDINGS.md; every EV cited
;; was measured on both platforms -- a red row here indicts the binding).
;; ========================================================================
(define l3 (make-uv-loop))
(define g3-fired 0)   ; the section guard: continuous on sigusr1, armed throughout
(define g3 (make-uv-signal l3))
(uv-signal-start! g3 'sigusr1 (lambda (s) (set! g3-fired (+ g3-fired 1)) (collect)))

(define (send-usr1-and-wait-guard!)
  (let ((before g3-fired))
    (uv-kill! (uv-os-getpid) 'sigusr1)
    (run-until/ticking l3 (lambda () (> g3-fired before)) 512)))

;; --- oneshot: exactly once, rearm-outside works (EV-2, spike leg1) ------
(define once-fired 0)
(define once (make-uv-signal l3))
(uv-signal-start-oneshot! once 'sigusr1
                          (lambda (s) (set! once-fired (+ once-fired 1)) (collect)))
(test-equal "oneshot fires on the first delivery" 'satisfied (send-usr1-and-wait-guard!))
(test-equal "…exactly once" 1 once-fired)
(test-equal "a second send reaches only the guard" 'satisfied (send-usr1-and-wait-guard!))
(test-equal "the oneshot stayed disarmed (auto-disarm)" 1 once-fired)
(uv-signal-stop! once)   ; rc 0 on an auto-disarmed watcher (EV-2)
(uv-signal-start-oneshot! once 'sigusr1
                          (lambda (s) (set! once-fired (+ once-fired 1)) (collect)))
(test-equal "rearm from OUTSIDE the callback delivers again"
  'satisfied (send-usr1-and-wait-guard!))
(test-equal "…and again exactly once" 2 once-fired)

;; --- EV-9: an in-callback rearm is silently undone ----------------------
(define incb-fired 0)
(define incb (make-uv-signal l3))
(define (incb-cb s)
  (set! incb-fired (+ incb-fired 1))
  ;; The rearm attempt the vendor auto-stop undoes after this returns.
  (uv-signal-start-oneshot! incb 'sigusr1 incb-cb)
  (collect))
(uv-signal-start-oneshot! incb 'sigusr1 incb-cb)
(test-equal "in-callback-rearm oneshot fires" 'satisfied (send-usr1-and-wait-guard!))
(test-equal "the in-callback rearm did NOT take effect (EV-9): second send silent"
  'satisfied (send-usr1-and-wait-guard!))
(test-equal "…count still 1" 1 incb-fired)

;; --- EV-1a: continuous rearm across a signum change ---------------------
(define sw-fired-1 0)
(define sw-fired-2 0)
(define sw (make-uv-signal l3))
(uv-signal-start! sw 'sigusr1 (lambda (s) (set! sw-fired-1 (+ sw-fired-1 1)) (collect)))
(test-equal "armed on the old signum" 'satisfied (send-usr1-and-wait-guard!))
(test-equal "…delivered" 1 sw-fired-1)
;; Switch signum while armed -- and arm a sigusr2 guard FIRST (§9.2).
(define g3b-fired 0)
(define g3b (make-uv-signal l3))
(uv-signal-start! g3b 'sigusr2 (lambda (s) (set! g3b-fired (+ g3b-fired 1)) (collect)))
(uv-signal-start! sw 'sigusr2 (lambda (s) (set! sw-fired-2 (+ sw-fired-2 1)) (collect)))
(test-equal "after the switch, the old signum reaches only its guard"
  'satisfied (send-usr1-and-wait-guard!))
(test-equal "…switched watcher silent on old signum" 1 sw-fired-1)
(uv-kill! (uv-os-getpid) 'sigusr2)
(test-equal "…and fires on the new signum (EV-1a)"
  'satisfied (run-until/ticking l3 (lambda () (positive? sw-fired-2)) 512))

;; --- EV-1b: same-signum restart swaps the callback, keeps pending -------
;; ITS OWN DRAIN, apart from the stop-suppression probe below (§6).
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
(test-equal "the swap preserved the pending delivery for the NEW callback (EV-1b)"
  '(0 1) (list swap-old swap-new))

;; --- EV-5: send -> stop -> run suppression (the discriminating shape) ---
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
(test-equal "A's silence proves suppression (EV-5)" 0 ev5-a)

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

;; --- EV-10: close with a delivery pending -------------------------------
(define ev10-fired 0)
(define ev10 (make-uv-signal l3))
(uv-signal-start! ev10 'sigusr1
                  (lambda (s) (set! ev10-fired (+ ev10-fired 1)) (collect)))
(define g3-before-ev10 g3-fired)              ; snapshot BEFORE the send
(uv-kill! (uv-os-getpid) 'sigusr1)            ; pending for ev10 AND guard g3
(uv-close! ev10)                              ; close BEFORE the next run
(test-equal "the close drains (iteration-agnostic: signal closes may defer, EV-10)"
  'satisfied
  (run-until/ticking l3 (lambda () (eq? (uv-handle-state ev10) 'closed)) 512))
(test-equal "the closing watcher's callback was suppressed" 0 ev10-fired)
(test-assert "the guard still got THIS delivery (delta, not cumulative)"
  (> g3-fired g3-before-ev10))

;; --- EV-4: an armed watcher keeps the loop alive ------------------------
(test-assert "the loop is alive while watchers are armed (EV-4)"
  (uv-loop-alive? l3))

(uv-loop-teardown! l3)
(test-equal "teardown swept every armed watcher; counters balanced"
  signal-base (live-count 'signal))

;; ========================================================================
;; End-to-end graceful shutdown: the SQ-S2 spike probe, graduated (§9.3).
;; Three-ack handshake (SQ-S2-F1): kill #2 gates on DISARMED, never GOT1.
;; ========================================================================
(define chez-exe (getenv "CHEZ_LIBUV_TEST_CHEZ"))

(if (not chez-exe)
    (test-equal "E2E graceful shutdown SKIPPED: CHEZ_LIBUV_TEST_CHEZ unset (run via make test)"
      'skipped 'skipped)
    (let ((l4 (make-uv-loop)))
      (define out (make-byte-collector))
      (define done 'not-yet)
      (define child-out (make-uv-pipe l4))
      (define proc
        (uv-spawn! l4 chez-exe
                   ;; argv[0] = the REAL binary name, never a hardcoded
                   ;; "chez": Chez resolves its boot files by the invoked
                   ;; name, so argv[0] "chez" against a scheme-named install
                   ;; hunts for a nonexistent chez.boot and dies of SIGABRT
                   ;; before its first write (measured: the PR #7 Linux CI
                   ;; failure; spike/e2e-diag legs E/F were the A/B pair).
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
      ;; the whole suite on a later ESRCH uv-kill! (the original CI failure
      ;; mode, which hid all evidence).
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
                      (lambda () (collect))
                      (lambda (err) (collect)))

      (test-equal "the child armed and acked READY"
        'acked (await-acks 1 4096))

      (test-equal "kill #1 sent to a live child"
        'sent (kill-child!))

      (test-equal "the child acked delivery (GOT1, from inside the callback)"
        'acked (await-acks 2 4096))

      (test-equal "the child acked disarm (DISARMED, from a later dispatch)"
        'acked (await-acks 3 4096))

      (test-equal "kill #2 sent to a live child, gated on DISARMED"
        'sent (kill-child!))

      (test-equal "the child exited"
        'satisfied (run-until/ticking l4 (lambda () (pair? done)) 4096))
      (test-equal "…killed by the second SIGTERM: (0 sigterm) -- graceful then killed"
        '(0 sigterm) done)
      (test-equal "the ack transcript is exactly READY/GOT1/DISARMED"
        "READY\nGOT1\nDISARMED\n" (utf8->string (collector-bytes out)))

      (uv-loop-teardown! l4)
      (test-equal "signal counter balanced after the E2E"
        signal-base (live-count 'signal))))

(test-end "signal")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
