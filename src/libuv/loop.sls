#!r6rs
;;; Event-loop lifecycle and callback-error delivery. Loops own native memory
;;; explicitly; callers close or tear them down rather than relying on GC.
(library (libuv loop)
  (export make-uv-loop uv-loop? uv-loop-open?
          uv-run uv-stop! uv-loop-alive? uv-now uv-update-time!
          uv-loop-live-handles uv-loop-deferred-errors
          uv-loop-close! uv-loop-teardown! call-with-uv-loop)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))

  ;; make-uv-loop : -> uv-loop
  (define (make-uv-loop)
    (ensure-native-loaded!)
    (let ((made (try-construct-loop uv-loop-init values)))
      (if (uv-loop? made) made (raise (step-refusal made 'make-uv-loop #f)))))

  ;; uv-loop? : object -> boolean
  ;; The loop record's predicate, defined with the record in (libuv private
  ;; handles) and exported from here.

  ;; uv-loop-open? : uv-loop -> boolean
  (define (uv-loop-open? loop)
    (require-loop loop 'uv-loop-open?)
    (loop-open? loop))

  (define (run-mode->int mode who)
    (case mode
      ((default) (uv-run-default))
      ((once)    (uv-run-once))
      ((nowait)  (uv-run-nowait))
      (else (raise (make-uv-invalid-argument who 'unknown-run-mode)))))

  ;; take-pending-callback-error! : uv-loop -> (or condition #f)
  ;; The condition to raise for LOOP's pending callback error, consumed so
  ;; that one callback failure cannot be delivered twice, or #f. Only the
  ;; claim's holder takes it: once the claim is given back, another thread's
  ;; run can set a pending error of its own, and a take after that would
  ;; hand it to the wrong caller. A take by any other thread is a defect in
  ;; the binding, and raised.
  (define (take-pending-callback-error! loop)
    (unless (eqv? (loop-holder loop) (current-thread-id))
      (assertion-violation 'take-pending-callback-error!
                           "the loop's claim is not this thread's"
                           (loop-holder loop)))
    (and (loop-has-pending-error? loop)
         (let ((pending (loop-pending-error loop)))
           (clear-loop-pending-error! loop)
           (if (condition? pending)
               (condition (make-uv-callback-error pending) pending)
               (make-uv-callback-error pending)))))

  (define (raise-if-error! error)
    (when error (raise error)))

  ;; run-step! : uv-loop exact-integer exact-integer
  ;;             -> (values (or uptr stack-shortfall 'loop-running 'loop-not-open
  ;;                            'no-loop-pointer)
  ;;                        exact-integer (or condition #f))
  ;; One uv_run of LOOP in MODE-INT, claimed, taking the loop over, and given
  ;; back once uv_run returns: the claim's answer, libuv's return code, and
  ;; the pending callback error, for the caller to raise. uv-run and every
  ;; drain step of a teardown run this way, so the claim is held only
  ;; between the claim's step and the release's, around the native call: an
  ;; engine dropped anywhere else leaves the loop unclaimed. Every uv_run
  ;; the binding makes starts here, so this is where the C stack's headroom
  ;; is checked against FLOOR (claim-loop-for-run!): uv-run's is
  ;; run-stack-floor and a drain's teardown-stack-floor.
  (define (run-step! loop mode-int floor)
    (let ((ptr (claim-loop-for-run! loop floor)))
      (if (refused? ptr)
          (values ptr 0 #f)
          (begin
            (set-loop-deferred-error-list! loop '())
            (let ((rc (uv-loop-run ptr mode-int)))
              (values ptr rc (one-step (let ((error (take-pending-callback-error! loop)))
                                         (release-loop! loop)
                                         error))))))))

  ;; uv-run : uv-loop [symbol] -> boolean
  ;; The boolean says whether work remains; libuv's raw integer would invert
  ;; ordinary Scheme truth tests because zero is true.
  ;;
  ;; The run holds the loop's claim (claim-loop!) for as long as uv_run's
  ;; frame is on the stack, and that can outlast the call: an engine that
  ;; runs out of fuel in a callback suspends the frame, and a continuation
  ;; that escapes a callback abandons it, both in the middle of an iteration
  ;; only a return into the frame can finish. So the claim is given back
  ;; when uv_run returns and not on the way out of the call, and every
  ;; verb that would run, close or tear the loop down meanwhile is refused
  ;; it. No raise needs unwinding here: the seams contain every raise, and
  ;; uv_run returns.
  ;;
  ;; The claim also hands the loop to the calling thread: a loop created on
  ;; one thread and run on another (the worker-pool handoff) becomes owned by
  ;; whichever thread runs it. A call on another thread cannot take the
  ;; claim while this one holds it, so at most one thread runs the loop at
  ;; a time and the transfer is unambiguous.
  ;;
  ;; The first check of the mark only keeps the order of uv-run's refusals,
  ;; 'loop-running before an unknown mode; the claim is what refuses.
  (define uv-run
    (case-lambda
      ((loop) (uv-run loop 'default))
      ((loop mode)
       (require-open-loop loop 'uv-run)
       (when (loop-running? loop)
         (raise (make-uv-invalid-argument 'uv-run 'loop-running)))
       (let-values (((ptr rc error)
                     (run-step! loop (run-mode->int mode 'uv-run) run-stack-floor)))
         (when (refused? ptr)
           (raise (step-refusal ptr 'uv-run #f)))
         (raise-if-error! error)
         (not (zero? rc))))))

  ;; (loop-call loop who ptr-of native) answers (NATIVE ptr) for LOOP's
  ;; pointer, taken in the same interrupt-free step from PTR-OF:
  ;; open-loop-ptr, or owned-loop-ptr for a query that also checks this
  ;; thread owns the loop. Once the step is over it raises WHO's refusal
  ;; for a check that failed. With the open check made on entry and the
  ;; pointer read after it, interrupts enabled between, an engine could
  ;; suspend the query there while a teardown freed the loop: resumed, it
  ;; would call libuv on the freed block, or on a new loop the allocator
  ;; gave its address (tests/test-handle-steps.sps). NATIVE must answer
  ;; something refused? does not take for a refusal.
  (define-syntax loop-call
    (syntax-rules ()
      ((_ loop who ptr-of native)
       (let* ((l loop)
              (answer (one-step
                       (let ((ptr (ptr-of l)))
                         (if (refused? ptr) ptr (native ptr))))))
         (if (refused? answer)
             (raise (step-refusal answer who #f))
             answer)))))

  ;; uv-stop! : uv-loop -> unspecified
  (define (uv-stop! loop)
    (require-loop loop 'uv-stop!)
    (loop-call loop 'uv-stop! open-loop-ptr uv-loop-stop))

  ;; uv-loop-alive? : uv-loop -> boolean
  (define (uv-loop-alive? loop)
    (require-loop loop 'uv-loop-alive?)
    (not (zero? (loop-call loop 'uv-loop-alive? open-loop-ptr uv-loop-alive))))

  ;; uv-now : uv-loop -> exact-nonnegative-integer
  ;; This is libuv's cached time. It changes only when the loop updates it,
  ;; once per iteration, or when uv-update-time! does.
  (define (uv-now loop)
    (require-loop loop 'uv-now)
    (loop-call loop 'uv-now open-loop-ptr uv-loop-now))

  ;; uv-update-time! : uv-loop -> unspecified
  ;; Refresh the cached time from libuv's clock. Timers are armed from that
  ;; cache, so a callback that held the loop calls this before arming a
  ;; deadline, or the deadline starts from before the callback ran.
  ;; Legal while the loop runs, and it runs nothing. Unlike uv-now it is
  ;; affinity-checked, in the step that writes: it writes the cache the loop
  ;; thread rewrites every iteration, so from another thread it is a
  ;; write-write race that can move the clock backwards. A closed loop is
  ;; refused before the owner is asked, as make-uv-async's order.
  (define (uv-update-time! loop)
    (require-loop loop 'uv-update-time!)
    (loop-call loop 'uv-update-time! owned-loop-ptr uv-loop-update-time))

  ;; uv-loop-live-handles : uv-loop -> (listof uv-handle)
  (define (uv-loop-live-handles loop)
    (require-open-loop loop 'uv-loop-live-handles)
    (registry-snapshot-for-loop loop))

  ;; uv-loop-deferred-errors : uv-loop -> list
  (define (uv-loop-deferred-errors loop)
    (require-open-loop loop 'uv-loop-deferred-errors)
    (reverse (loop-deferred-error-list loop)))

  ;; uv-loop-close! : uv-loop -> unspecified
  ;; Idempotent, but raises EBUSY while handles remain. Native state is marked
  ;; closed before freeing, then any pending callback error is delivered.
  (define (uv-loop-close! loop)
    (require-loop loop 'uv-loop-close!)
    (let ((closed (close-step! loop)))
      (cond ((memq closed '(closed loop-not-open)) (if #f #f))
            ((condition? closed) (raise closed))
            (else (raise (step-refusal closed 'uv-loop-close! #f))))))

  ;; close-step! : uv-loop
  ;;               -> (or 'closed 'loop-not-open 'loop-running 'no-loop-pointer
  ;;                      'pointer-not-registered exact-integer condition)
  ;; A close as one interrupt-free step: the claim, without taking the loop
  ;; over; uv_loop_close; once libuv has closed the loop, the record marked
  ;; closed and its block freed; and the claim given back. It answers
  ;; 'closed, or the loop's pending callback error once it is closed; libuv's
  ;; errno, EBUSY while a handle is open; the claim's refusal; or
  ;; 'pointer-not-registered for a loop missing from the registry, which only
  ;; a defect in the binding makes. Its caller raises.
  ;; - Claimed, no run on any thread can enter the loop it frees.
  ;; - One step, so no engine is suspended or dropped inside a close. Held
  ;;   across trap checks, the claim would let a dropped close leave the
  ;;   loop claimed for good, open or closed.
  ;; - Nothing in it raises: a raise would leave interrupts disabled.
  (define (close-step! loop)
    (one-step
     (let ((ptr (claim-loop! loop #f)))
       (if (refused? ptr)
           ptr
           (let ((rc (uv-loop-close ptr)))
             (if (not (zero? rc))
                 (begin (release-loop! loop) rc)
                 (let ((registered (registry-take! ptr)))
                   (set-loop-state! loop 'closed)
                   (free! ptr)
                   (set-loop-ptr! loop 0)
                   (count-loop-free!)
                   (let ((error (take-pending-callback-error! loop)))
                     (release-loop! loop)
                     (cond (error error)
                           (registered 'closed)
                           (else 'pointer-not-registered))))))))))

  ;; Bound iterations, not wall time, so teardown is deterministic under load.
  (define max-drain-iterations 1024)

  ;; uv-loop-teardown! : uv-loop -> unspecified
  ;; Cancel handle-less requests, close handles, drain completions, then close.
  ;; A callback failure is retained until cleanup finishes and then re-raised.
  (define (uv-loop-teardown! loop)
    (require-loop loop 'uv-loop-teardown!)
    (raise-if-error! (teardown! loop #f)))

  ;; teardown! : uv-loop boolean -> (or condition #f)
  ;; uv-loop-teardown!'s work, answering the condition to raise, or #f. With
  ;; HELD?, this thread already holds the loop's claim (call-with-uv-loop's
  ;; exit). The teardown is three kinds of step, and each holds the claim
  ;; only while it calls libuv:
  ;; - start-teardown! begins every handle's close, as one interrupt-free
  ;;   step;
  ;; - each drain step (drain-step!) is a run, claimed as uv-run's is, and
  ;;   takes the loop over as a run does;
  ;; - close-step! closes the loop, as one interrupt-free step.
  ;; So no other call is inside the loop while a step calls libuv, and an
  ;; engine dropped between steps leaves the loop unclaimed and its teardown
  ;; retryable. Only a drop inside a drain step's uv_run leaves it claimed,
  ;; as a run's does. Held across the whole teardown, the claim would let a
  ;; dropped teardown strand its loop at almost every point.
  ;; Between steps another call can get in: then a teardown that finds the
  ;; loop closed has nothing left to do, and one that finds it claimed is
  ;; refused 'loop-running, its handles already closing.
  ;; The callback failure retained is the first; libuv's refusal to close,
  ;; and the drain bound, take precedence over it. Nothing here raises: a
  ;; guard around the teardown, to give a claim back on a raise, would cost
  ;; about 400 B a teardown, and would give the claim back over a fault
  ;; raised out of uv_run.
  (define (teardown! loop held?)
    (let ((started (start-teardown! loop held?)))
      (cond ((eq? started 'loop-not-open) #f)
            ((eq? started 'started) (drain-then-close! loop))
            (else (step-refusal started 'uv-loop-teardown! #f)))))

  ;; start-teardown! : uv-loop boolean
  ;;                   -> (or 'started 'loop-not-open 'loop-running 'no-loop-pointer)
  ;; The teardown's first step, interrupt-free: the claim, taking the loop
  ;; over, unless HELD?; the cancellation of the loop's handle-less requests
  ;; and the start of every handle's close, from one copy of the registry (a
  ;; cancellation completes in a later run, so the loop's handles are the
  ;; same after it); and the claim given back. Nothing in it raises but a
  ;; defect in the binding: a registered open handle with no pointer.
  (define (start-teardown! loop held?)
    (one-step
     (let ((ptr (if held? (loop-ptr loop) (claim-loop! loop #t))))
       (if (refused? ptr)
           ptr
           (let-values (((handles requests) (loop-entries loop)))
             (cancel-requests! requests)
             (for-each close-handle! handles)
             (release-loop! loop)
             'started)))))

  ;; drain-step! : uv-loop -> (or 'work 'drained 'loop-not-open 'loop-running
  ;;                              'no-loop-pointer stack-shortfall condition)
  ;; One run-step! in 'default mode, as uv-run's: 'work or
  ;; 'drained, the run's pending callback error, or the claim's refusal. Its
  ;; floor is the teardown's, under uv-run's, so a run refused for the stack
  ;; can still be torn down.
  (define (drain-step! loop)
    (let-values (((ptr rc error) (run-step! loop (uv-run-default) teardown-stack-floor)))
      (cond ((refused? ptr) ptr)
            (error error)
            ((zero? rc) 'drained)
            (else 'work))))

  ;; drain-then-close! : uv-loop -> (or condition #f)
  (define (drain-then-close! loop)
    (let drain ((i 0) (stored #f))
      (let ((outcome (drain-step! loop)))
        (cond ((condition? outcome)
               (if (< i max-drain-iterations)
                   (drain (+ i 1) (or stored outcome))
                   (drain-bound)))
              ((eq? outcome 'work)
               (if (< i max-drain-iterations)
                   (drain (+ i 1) stored)
                   (drain-bound)))
              ((eq? outcome 'drained) (close-after-drain loop stored))
              ((eq? outcome 'loop-not-open) stored)
              (else (step-refusal outcome 'uv-loop-teardown! #f))))))

  ;; close-after-drain : uv-loop (or condition #f) -> (or condition #f)
  ;; The teardown's close-step!, and what the teardown raises after it:
  ;; libuv's refusal, under uv-loop-close!'s name as uv-loop-close! itself
  ;; raises it, ahead of STORED, the first callback failure the drain
  ;; retained; and any other refusal under uv-loop-teardown!'s.
  (define (close-after-drain loop stored)
    (let ((closed (close-step! loop)))
      (cond ((memq closed '(closed loop-not-open)) stored)
            ((condition? closed) (or stored closed))
            ((integer? closed) (step-refusal closed 'uv-loop-close! #f))
            (else (step-refusal closed 'uv-loop-teardown! #f)))))

  (define (drain-bound)
    (condition
     (make-uv-error)
     (make-who-condition 'uv-loop-teardown!)
     (make-message-condition "loop still had work after the drain bound")))

  ;; claim-refusal? : condition -> boolean
  ;; Whether a teardown failed because another call held the loop's claim.
  (define (claim-refusal? e)
    (and (uv-invalid-argument? e)
         (eq? (uv-invalid-argument-reason e) 'loop-running)))

  ;; call-with-uv-loop : (uv-loop -> object) -> object
  ;; The body runs once: the before thunk refuses every return into it after
  ;; it has been left, whatever became of the loop. The after thunk tears the
  ;; loop down however the body left.
  ;; - The loop is made inside the body, and handed over inside its own
  ;;   step, so wherever an engine expires from then on, the after thunk
  ;;   finds the loop. Made before the dynamic-wind, a loop would be lost to
  ;;   an engine dropped in between (tests/test-constructors.sps).
  ;; - A body left from inside one of the loop's callbacks, by a continuation
  ;;   or an engine's suspension, leaves the loop claimed by this thread.
  ;;   The teardown takes that claim over as it stands, which is safe
  ;;   because nothing can resume the run the teardown ends. The mark names
  ;;   the claim's thread, so a claim another thread holds, a run's or a
  ;;   close's, is never taken for this thread's own. The claim passes
  ;;   straight to the teardown's first step, so every handle's close has
  ;;   begun before another call can get in.
  ;; - That teardown can fail: escaping one close callback strands the rest
  ;;   of libuv's batch of closes, and the loop cannot be closed. The failure
  ;;   is contained rather than raised in the middle of the escape or the
  ;;   suspension, and the loop is claimed by this thread again, as any
  ;;   abandoned run's is, so no verb touches it. A teardown refused because
  ;;   another call took the claim between its steps leaves the loop to that
  ;;   call: claimed again here, it would stay claimed with no run in it.
  ;; - A loop claimed by another thread is live under that thread's call:
  ;;   the teardown refuses it, as from any exit.
  ;; - A guard unwinds to itself before it tests its clauses, and when none
  ;;   matches it re-raises from where the body raised: a re-entry.
  ;;   So the first re-entry after the body was left while raising raises
  ;;   that raise again, and every other re-entry &uv-handle-closed: the
  ;;   guards outside get the body's own condition, and nothing resumes the
  ;;   body. Only the first: a handler outside that answers the raise by
  ;;   re-entering the body, to retry it, would otherwise get the same raise
  ;;   for good.
  ;;   RAISING is that raise in a list, so that a body that raises #f is told
  ;;   from one that raised nothing. The handler that records it hands the
  ;;   raise on in place, with raise-continuable, so handlers outside run in
  ;;   the body's dynamic environment, and one that returns from a
  ;;   raise-continuable resumes the body, as it would without this
  ;;   handler. One that returns from a raise sees one call more: R6RS
  ;;   raises the &non-continuable from the handler that was returned to,
  ;;   and that handler is this one.
  ;;   A return ends the raise, and so does the body's: RAISING goes back to
  ;;   #f, not to a raise it interrupted. A raise can interrupt another only
  ;;   when a handler gave the other up by jumping back into the body.
  (define (call-with-uv-loop proc)
    (ensure-native-loaded!)
    (let ((loop #f) (left #f) (raising #f) (left-raising #f))
      (dynamic-wind
       (lambda ()
         (when left
           (let ((pending left-raising))
             (set! left-raising #f)
             (raise (if pending
                        (car pending)
                        (make-uv-handle-closed 'loop))))))
       (lambda ()
         (let ((made (try-construct-loop uv-loop-init (lambda (made) (set! loop made)))))
           (if (uv-loop? made)
               (with-exception-handler
                (lambda (c)
                  (set! raising (list c))
                  (call-with-values
                   (lambda () (raise-continuable c))
                   (lambda answers
                     (set! raising #f)
                     (apply values answers))))
                (lambda ()
                  (call-with-values
                   (lambda () (proc made))
                   (lambda answers
                     (set! raising #f)
                     (apply values answers)))))
               (raise (step-refusal made 'make-uv-loop #f)))))
       (lambda ()
         (set! left #t)
         (set! left-raising raising)
         (when (loop-open? loop)
           (if (eqv? (loop-holder loop) (current-thread-id))
               (let ((failure (teardown! loop #t)))
                 (when (and failure (not (claim-refusal? failure)) (loop-open? loop))
                   (claim-loop! loop #f)))
               (uv-loop-teardown! loop))))))))
