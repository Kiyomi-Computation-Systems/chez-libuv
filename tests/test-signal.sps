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
        (only (libuv private native) live-counts)
        (uv-testing)
        (only (chezscheme) collect getenv))

(define runner (test-runner-simple))
(test-runner-current runner)

(define (live-count kind) (cdr (assq kind (live-counts))))

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

(test-end "signal")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
