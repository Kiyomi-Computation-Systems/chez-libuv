#!r6rs
;;; Shared test plumbing for the suites that drive a real event loop --
;;; design spec S11 ("tests/uv-testing.sls provides run-until ... failure is
;;; iteration exhaustion, never wall-clock elapsed time").
;;;
;;; Stage 3 needs exactly one procedure. The loopback connection plumbing S11
;;; also mentions arrives with the TCP stages, in this file, when there is a
;;; suite to exercise it.
;;;
;;; NOT pure: (libuv loop) reaches (libuv private native). No suite importing
;;; this library may appear in the Makefile's PURE_TESTS.
(library (uv-testing)
  (export run-until)
  (import (rnrs)
          (libuv loop))

  ;; Step the loop until `pred` holds, or until `max-iters` steps have been
  ;; taken. Answers the symbol 'satisfied or the symbol
  ;; 'iterations-exhausted -- never a boolean, and never a wall-clock
  ;; timeout.
  ;;
  ;; WHY SYMBOLS. `#t`/`#f` would be indistinguishable from what SRFI-64
  ;; produces when the expression under test raises (AGENTS.md's named trap:
  ;; %test-evaluate-with-catch turns any exception into #f), so a drain that
  ;; blew up would read as "predicate never held" -- the same answer an
  ;; honestly-exhausted drain gives. Two distinct symbols make the three
  ;; outcomes -- satisfied, exhausted, raised -- three distinct values.
  ;;
  ;; WHY AN ITERATION CAP, NOT A DEADLINE. Design spec S11: a wall-clock
  ;; bound turns a slow machine into a flaky suite. The cap counts loop
  ;; steps, which is a property of the program under test rather than of the
  ;; hardware running it.
  ;;
  ;; `pred` is tested BEFORE the first step, so a condition that already
  ;; holds costs no iterations -- and so a caller cannot accidentally assert
  ;; that a step was required.
  ;;
  ;; The mode is 'once: it blocks until the loop's next due event, which is
  ;; what makes a 1 ms timer test deterministic instead of a spin. A loop
  ;; with nothing left to do returns immediately, so exhaustion is bounded
  ;; by max-iters rather than by time in that case too.
  (define (run-until loop pred max-iters)
    (unless (procedure? pred)
      (assertion-violation 'run-until "predicate is not a procedure" pred))
    (unless (and (integer? max-iters) (exact? max-iters) (positive? max-iters))
      (assertion-violation 'run-until "iteration cap must be a positive exact integer"
                           max-iters))
    (let step ((i 0))
      (cond ((pred) 'satisfied)
            ((>= i max-iters) 'iterations-exhausted)
            (else (uv-run loop 'once) (step (+ i 1)))))))
