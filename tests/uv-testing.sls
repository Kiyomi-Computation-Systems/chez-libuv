#!r6rs
;;; Shared test plumbing for the suites that drive a real event loop: a loop
;;; stepper whose failure is iteration exhaustion, never wall-clock elapsed
;;; time; the loopback connection plumbing every TCP suite shares; and the
;;; two pieces a read test needs: a payload that is the same on every run,
;;; and somewhere to put the spans that arrive.
;;;
;;; NOT pure: (libuv loop) reaches (libuv private native). No suite importing
;;; this library may appear in the Makefile's PURE_TESTS.
(library (uv-testing)
  (export run-until run-until/ticking
          bind-loopback! connect-loopback! loopback-address
          seeded-bytes compare-bytes
          make-byte-collector byte-collector? collect-span!
          collector-count collector-bytes)
  (import (rnrs)
          (libuv loop)
          (libuv handle)
          (libuv timer)
          (libuv tcp))

  ;; Step the loop until `pred` holds, or until `max-iters` steps have been
  ;; taken. Answers the symbol 'satisfied or the symbol
  ;; 'iterations-exhausted -- never a boolean, and never a wall-clock
  ;; timeout.
  ;;
  ;; WHY SYMBOLS. `#t`/`#f` would be indistinguishable from what SRFI-64
  ;; produces when the expression under test raises (its
  ;; %test-evaluate-with-catch turns any exception into #f), so a drain that
  ;; blew up would read as "predicate never held" -- the same answer an
  ;; honestly-exhausted drain gives. Two distinct symbols make the three
  ;; outcomes -- satisfied, exhausted, raised -- three distinct values.
  ;;
  ;; WHY AN ITERATION CAP, NOT A DEADLINE. A wall-clock bound turns a slow
  ;; machine into a flaky suite. The cap counts loop steps, which is a
  ;; property of the program under test rather than of the hardware running
  ;; it.
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

  ;; run-until, with a 1 ms repeating timer armed for the duration.
  ;;
  ;; WHY THIS EXISTS. `uv-run loop 'once` BLOCKS until the loop's next due
  ;; event. That is what makes a 1 ms timer test deterministic, but it also
  ;; means a predicate that never holds -- on a loop whose only remaining
  ;; handles are waiting on a socket that will never be readable -- leaves
  ;; the FIRST step blocked in the kernel, where run-until's iteration cap
  ;; never gets to count. The suite then hangs instead of failing, and
  ;; "failure is iteration exhaustion, never wall-clock elapsed time"
  ;; quietly stops being true.
  ;;
  ;; A timer that fires every millisecond gives 'once something to return
  ;; for, so the cap does the deciding again and a broken delivery path
  ;; produces 'iterations-exhausted -- a NAMED assertion failure -- rather
  ;; than a stuck process. This is measured, not theorised: mutations to the
  ;; read path (an EOF routed to on-error, a span framed wrongly, an alloc_cb
  ;; that answers a corrupt buffer) hang a suite that waits with plain
  ;; run-until, and fail by name with this one.
  ;;
  ;; EVERY WAIT WHOSE PREDICATE DEPENDS ON A CALLBACK BEING DELIVERED SHOULD
  ;; USE THIS ONE. Plain run-until is right where something else already
  ;; guarantees the loop keeps waking (a timer of the suite's own), or where
  ;; the predicate is about a timer in the first place.
  ;;
  ;; The ticker is closed before returning, and its close is DRAINED, so a
  ;; caller that goes straight from here to a debug-counter assertion does
  ;; not see this fixture's own handle still live.
  ;;
  ;; IT IS DISARMED ON THE UNWIND PATH TOO, and that is the whole reason the
  ;; guard below exists. `run-until` raises whenever a callback under test
  ;; raised: uv-run stores a callback's raise on the loop and re-raises it,
  ;; as an &uv-callback-error, out of the very `uv-run` this fixture is
  ;; driving. Without the guard the ticker stays ARMED on the loop, and every
  ;; later assertion in the suite is measuring a loop this fixture is still
  ;; holding open -- a live timer in the counters, a non-empty live-handle
  ;; snapshot, a loop that never runs dry, and a teardown that has one more
  ;; handle to close than the test thinks it created. The capstone
  ;; (tests/test-echo.sps) leans on this helper for every wait including the
  ;; ones a raising callback ends, so the leak would be attributed to the code
  ;; under test rather than to the fixture.
  (define (run-until/ticking loop pred max-iters)
    (let ((ticker (make-uv-timer loop)))
      ;; The tick callback deliberately does nothing -- not even (collect).
      ;; This timer is a fixture whose only job is to wake the loop; GC
      ;; pressure on the callback path is the job of the callbacks UNDER
      ;; TEST, which collect, and a full collection every millisecond
      ;; for the length of a megabyte transfer would buy no coverage at a
      ;; cost measured in seconds.
      (uv-timer-start! ticker (lambda (t) #f) 1 1)
      (let ((outcome
             (guard (e (#t
                        ;; The disarm is itself guarded HERE and nowhere else:
                        ;; a condition raised while unwinding would REPLACE the
                        ;; callback error the caller is trying to see, which is
                        ;; the one thing worse than a leaked ticker. On the
                        ;; normal path below it is deliberately left unguarded,
                        ;; so a fixture that cannot clean up after a SUCCESSFUL
                        ;; wait still fails loudly.
                        (guard (cleanup-failure (#t #f))
                          (disarm-ticker! loop ticker))
                        (raise e)))
               (run-until loop pred max-iters))))
        (disarm-ticker! loop ticker)
        outcome)))

  ;; Stop, close and DRAIN the close of the fixture's own timer. Every step is
  ;; conditional on the state that step needs, because this also runs on the
  ;; unwind path, where the body may have closed the ticker or the whole loop
  ;; already.
  (define (disarm-ticker! loop ticker)
    (when (uv-handle-open? ticker)
      (uv-timer-stop! ticker)
      (uv-close! ticker))
    ;; A close callback is already pending, so these steps cannot block.
    (when (uv-loop-open? loop)
      (run-until loop (lambda () (eq? (uv-handle-state ticker) 'closed)) 8)))

  ;; --- loopback plumbing -------------------------------------------------
  ;; Every TCP test binds 127.0.0.1:0, reads the real ephemeral port back
  ;; via uv_tcp_getsockname, and connects to it from the same loop and
  ;; process. Both halves of that live here so no suite spells the address
  ;; literal out for itself -- a suite that bound something other than
  ;; loopback would be an external-network test, which no suite makes: the
  ;; TCP suites test the real kernel stack looped back on itself, in one
  ;; process a single Valgrind run can see.
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
  ;; other callback in this binding. Answers the request record uv-tcp-connect!
  ;; returned, so a caller can assert on the in-flight request.
  (define (connect-loopback! tcp port on-connect)
    (uv-tcp-connect! tcp loopback-address port on-connect))

  ;; --- deterministic payloads --------------------------------------------
  ;; A linear congruential generator with a CALLER-SUPPLIED seed and no other
  ;; input. Deliberately not `random` and deliberately not the clock: a suite
  ;; that compares a megabyte byte-for-byte has to be able to say which byte
  ;; differed and have that mean the same thing on the next run. The
  ;; constants are the classic ANSI-C ones; the high bits are the ones taken,
  ;; because the low bits of an LCG modulo a power of two have short periods
  ;; (bit 0 alternates), which would make a "random" payload that a wrong
  ;; offset could still match.
  ;;
  ;; This is a test fixture, not a source of randomness: nothing here is
  ;; suitable for anything but filling a buffer with bytes that are stable,
  ;; unequal to their neighbours, and not all the same value.
  (define lcg-modulus 2147483648)       ; 2^31
  (define lcg-multiplier 1103515245)
  (define lcg-increment 12345)

  (define (seeded-bytes n seed)
    (unless (and (integer? n) (exact? n) (>= n 0))
      (assertion-violation 'seeded-bytes "length must be a non-negative exact integer" n))
    (unless (and (integer? seed) (exact? seed) (>= seed 0))
      (assertion-violation 'seeded-bytes "seed must be a non-negative exact integer" seed))
    (let ((bv (make-bytevector n)))
      (let fill ((i 0) (x (mod seed lcg-modulus)))
        (if (= i n)
            bv
            (let ((next (mod (+ (* lcg-multiplier x) lcg-increment) lcg-modulus)))
              (bytevector-u8-set! bv i (mod (div next 65536) 256))
              (fill (+ i 1) next))))))

  ;; 'identical, or the FIRST index that differs and both bytes there. A bare
  ;; test-equal on two 32 KiB bytevectors reports a failure by printing both of
  ;; them; this reports the one number that says what went wrong.
  (define (compare-bytes expected actual)
    (cond ((not (= (bytevector-length expected) (bytevector-length actual)))
           (list 'wrong-length (bytevector-length actual)))
          (else
           (let scan ((i 0))
             (cond ((= i (bytevector-length expected)) 'identical)
                   ((= (bytevector-u8-ref expected i) (bytevector-u8-ref actual i))
                    (scan (+ i 1)))
                   (else (list 'differs-at i
                               (bytevector-u8-ref expected i)
                               (bytevector-u8-ref actual i))))))))

  ;; --- accumulating what a read delivered ---------------------------------
  ;; Somewhere for on-data to put its spans, plus the running byte count a
  ;; run-until predicate can test without concatenating a megabyte on every
  ;; loop iteration.
  ;;
  ;; IT KEEPS THE CALLER'S BYTEVECTOR RATHER THAN COPYING IT, on purpose.
  ;; Every on-data delivery is a FRESH copy of the read buffer; a collector
  ;; that copied immediately would be just as green against a binding that
  ;; handed the same scratch bytevector out on every read, because the
  ;; corruption would happen after the copy. Holding the references means the
  ;; byte-for-byte comparison at the end of a chunked transfer is also the
  ;; assertion that each delivery was its own object.
  (define-record-type (byte-collector make-byte-collector byte-collector?)
    (fields (mutable spans collector-spans set-collector-spans!)
            (mutable count collector-count set-collector-count!))
    (protocol (lambda (new) (lambda () (new '() 0)))))

  (define (collect-span! collector bv start end)
    (set-collector-spans! collector
                          (cons (list bv start end) (collector-spans collector)))
    (set-collector-count! collector
                          (+ (collector-count collector) (- end start))))

  ;; Everything collected so far, in arrival order, as one bytevector.
  (define (collector-bytes collector)
    (let ((out (make-bytevector (collector-count collector))))
      (let copy ((spans (reverse (collector-spans collector))) (at 0))
        (if (null? spans)
            out
            (let* ((span (car spans))
                   (bv (car span))
                   (start (cadr span))
                   (end (caddr span)))
              (bytevector-copy! bv start out at (- end start))
              (copy (cdr spans) (+ at (- end start)))))))))
