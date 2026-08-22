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

(test-end "signal")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
