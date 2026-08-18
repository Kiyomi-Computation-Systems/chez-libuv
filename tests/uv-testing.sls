#!r6rs
;;; Shared test plumbing for the suites that drive a real event loop --
;;; design spec S11 ("tests/uv-testing.sls provides run-until ... failure is
;;; iteration exhaustion, never wall-clock elapsed time", "plus loopback
;;; connection plumbing shared across suites").
;;;
;;; Stage 3 needed exactly one procedure. Stage 4 adds the loopback plumbing
;;; S11 also mentions, now that there is a suite to exercise it.
;;;
;;; NOT pure: (libuv loop) reaches (libuv private native). No suite importing
;;; this library may appear in the Makefile's PURE_TESTS.
(library (uv-testing)
  (export run-until bind-loopback! connect-loopback! loopback-address)
  (import (rnrs)
          (libuv loop)
          (libuv tcp))

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
            (else (uv-run loop 'once) (step (+ i 1))))))

  ;; --- loopback plumbing (ADR-0010, design spec S11) ---------------------
  ;; "Every TCP test binds 127.0.0.1:0, reads the real ephemeral port back
  ;; via uv_tcp_getsockname, and connects to it from the same loop and
  ;; process." Both halves of that live here so no suite spells the address
  ;; literal out for itself -- a suite that bound something other than
  ;; loopback would be an external-network test, which ADR-0010 rejects by
  ;; design.
  (define loopback-address "127.0.0.1")

  ;; (bind-loopback! tcp) -> the REAL ephemeral port the kernel chose, read
  ;; back through uv_tcp_getsockname. Never a fixed number, so two suites --
  ;; or two runs of one suite -- can never collide on a port.
  ;;
  ;; DELIBERATELY NOT a make-server-and-listen helper. The listen callback
  ;; almost always needs the server handle in order to accept, so the handle
  ;; has to be bound by the caller BEFORE the callback closure is written;
  ;; a helper that created the handle and took the callback in one call
  ;; would force every caller into a forward reference.
  (define (bind-loopback! tcp)
    (uv-tcp-bind! tcp loopback-address 0)
    (uv-tcp-getsockname-port tcp))

  ;; (connect-loopback! tcp port on-connect) -- starts a connect to
  ;; 127.0.0.1:port. The connect COMPLETES in a later uv-run, like every
  ;; other callback in this binding.
  (define (connect-loopback! tcp port on-connect)
    (uv-tcp-connect! tcp loopback-address port on-connect)))
