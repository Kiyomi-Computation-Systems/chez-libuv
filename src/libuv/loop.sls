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
  ;; that one callback failure cannot be delivered twice, or #f. Called
  ;; while the claim is held: once it is released, another thread's run can
  ;; set a pending error of its own.
  (define (take-pending-callback-error! loop)
    (and (loop-has-pending-error? loop)
         (let ((pending (loop-pending-error loop)))
           (clear-loop-pending-error! loop)
           (if (condition? pending)
               (condition (make-uv-callback-error pending) pending)
               (make-uv-callback-error pending)))))

  (define (raise-if-error! error)
    (when error (raise error)))

  ;; claim-or-raise! : uv-loop boolean symbol -> (or uptr #f)
  ;; claim-loop!, raising its refusal as WHO's; #f for a closed loop, which
  ;; each caller answers in its own way.
  (define (claim-or-raise! loop take-owner? who)
    (let ((claimed (claim-loop! loop take-owner?)))
      (cond ((not (symbol? claimed)) claimed)
            ((eq? claimed 'loop-running)
             (raise (make-uv-invalid-argument who 'loop-running)))
            ((eq? claimed 'loop-not-open) #f)
            (else (raise (step-refusal claimed who #f))))))

  ;; holding-claim : uv-loop (-> object) -> object
  ;; (BODY)'s value, giving LOOP's claim back first if BODY raises. A body
  ;; left any other way, by a continuation or an engine, keeps the claim, as
  ;; a run's frame left from a callback does. For a teardown, whose raises
  ;; come from deep in its work; a run and a close answer theirs instead.
  (define (holding-claim loop body)
    (guard (e (#t (release-loop! loop) (raise e)))
      (body)))

  ;; run-claimed! : uv-loop uptr exact-integer
  ;;                -> (values exact-integer (or condition #f))
  ;; One uv_run of LOOP, whose claim this call holds: libuv's return code,
  ;; and the pending callback error to raise once the claim is released.
  (define (run-claimed! loop ptr mode-int)
    (set-loop-deferred-error-list! loop '())
    (let ((rc (uv-loop-run ptr mode-int)))
      (values rc (take-pending-callback-error! loop))))

  ;; uv-run : uv-loop [symbol] -> boolean
  ;; The boolean says whether work remains; libuv's raw integer would invert
  ;; ordinary Scheme truth tests because zero is true.
  ;;
  ;; The run holds the loop's claim (claim-loop!) for as long as uv_run's
  ;; frame is on the stack, and that can outlast the call: an engine that
  ;; runs out of fuel in a callback suspends the frame, and a continuation
  ;; that escapes a callback abandons it, both in the middle of an iteration
  ;; only a return into the frame can finish. So the claim is given back
  ;; when uv_run returns and not on the way out of the call (#45), and every
  ;; verb that would run, close or tear the loop down meanwhile is refused
  ;; it. No raise needs unwinding here: the seams contain every raise, and
  ;; uv_run returns.
  ;;
  ;; The claim also hands the loop to the calling thread: a loop created on
  ;; one thread and run on another (the worker-pool handoff) becomes owned by
  ;; whichever thread runs it. A call on another thread cannot take the
  ;; claim while this one holds it (#78), so at most one thread runs the loop
  ;; at a time and the transfer is unambiguous (design §6.2).
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
       (let* ((mode-int (run-mode->int mode 'uv-run))
              (ptr (or (claim-or-raise! loop #t 'uv-run)
                       (raise (make-uv-handle-closed 'loop)))))
         (let-values (((rc error) (run-claimed! loop ptr mode-int)))
           (release-loop! loop)
           (raise-if-error! error)
           (not (zero? rc)))))))

  ;; uv-stop! : uv-loop -> unspecified
  (define (uv-stop! loop)
    (require-open-loop loop 'uv-stop!)
    (uv-loop-stop (loop-pointer loop 'uv-stop!)))

  ;; uv-loop-alive? : uv-loop -> boolean
  (define (uv-loop-alive? loop)
    (require-open-loop loop 'uv-loop-alive?)
    (not (zero? (uv-loop-alive (loop-pointer loop 'uv-loop-alive?)))))

  ;; uv-now : uv-loop -> exact-nonnegative-integer
  ;; This is libuv's cached time. It changes only when the loop updates it,
  ;; once per iteration, or when uv-update-time! does.
  (define (uv-now loop)
    (require-open-loop loop 'uv-now)
    (uv-loop-now (loop-pointer loop 'uv-now)))

  ;; uv-update-time! : uv-loop -> unspecified
  ;; Refresh the cached time from libuv's clock. Timers are armed from that
  ;; cache, so a callback that held the loop calls this before arming a
  ;; deadline, or the deadline starts from before the callback ran (#28).
  ;; Legal while the loop runs, and it runs nothing. Unlike uv-now it is
  ;; affinity-checked, before the write: it writes the cache the loop thread
  ;; rewrites every iteration, so from another thread it is a write-write race
  ;; that can move the clock backwards (ADR-0019).
  (define (uv-update-time! loop)
    (require-open-loop loop 'uv-update-time!)
    (require-loop-thread loop 'uv-update-time!)
    (uv-loop-update-time (loop-pointer loop 'uv-update-time!)))

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
  ;; The close holds the loop's claim, without taking the loop over, so no
  ;; run on any thread can enter the loop it frees (#78).
  (define (uv-loop-close! loop)
    (require-loop loop 'uv-loop-close!)
    (let ((ptr (claim-or-raise! loop #f 'uv-loop-close!)))
      (when ptr
        (let-values (((rc error) (close-claimed! loop ptr)))
          (release-loop! loop)
          (uv-check rc 'uv-loop-close!)
          (raise-if-error! error)))))

  ;; close-claimed! : uv-loop uptr -> (values exact-integer (or condition #f))
  ;; uv_loop_close on LOOP, whose claim this call holds, and once libuv has
  ;; closed it, the record marked closed and the block freed. It answers
  ;; libuv's return code and the pending callback error, for the caller to
  ;; raise once the claim is given back: a close is refused 'EBUSY whenever a
  ;; handle is open, and a guard around it, to give the claim back, cost
  ;; 410 B a close. Only a loop missing from the registry raises here, with
  ;; the claim held; the registry would then be corrupt.
  (define (close-claimed! loop ptr)
    (let ((rc (uv-loop-close ptr)))
      (if (zero? rc)
          (begin
            (set-loop-state! loop 'closed)
            (registry-deregister! ptr)
            (free! ptr)
            (set-loop-ptr! loop 0)
            (count-loop-free!)
            (values rc (take-pending-callback-error! loop)))
          (values rc #f))))

  ;; Bound iterations, not wall time, so teardown is deterministic under load.
  (define max-drain-iterations 1024)

  (define teardown-no-error (list 'no-error))

  ;; drain-step : uv-loop uptr -> (or 'work 'drained condition)
  ;; One uv_run 'default of LOOP, whose claim this call holds.
  (define (drain-step loop ptr)
    (let-values (((rc error) (run-claimed! loop ptr (uv-run-default))))
      (cond (error error)
            ((zero? rc) 'drained)
            (else 'work))))

  ;; uv-loop-teardown! : uv-loop -> unspecified
  ;; Cancel handle-less requests, close handles, drain completions, then close.
  ;; A callback failure is retained until cleanup finishes and then re-raised.
  ;; The teardown holds the loop's claim throughout, as a run does, so no run
  ;; on any thread can enter the loop it closes (#78), and it takes the loop
  ;; over as a run does, since its drain runs the loop.
  (define (uv-loop-teardown! loop)
    (require-loop loop 'uv-loop-teardown!)
    (let ((ptr (claim-or-raise! loop #t 'uv-loop-teardown!)))
      (when ptr
        (let ((stored (holding-claim loop (lambda () (teardown-claimed! loop ptr)))))
          (release-loop! loop)
          (unless (eq? stored teardown-no-error) (raise stored))))))

  ;; teardown-claimed! : uv-loop uptr -> object
  ;; uv-loop-teardown!'s work on LOOP, whose claim this call holds. It raises
  ;; what the drain bound or libuv's close refused, and answers the callback
  ;; failure to raise once the claim is given back, or teardown-no-error.
  (define (teardown-claimed! loop ptr)
    ;; One copy of the registry serves both: a cancellation completes in a
    ;; later run, so the loop's handles are the same after it.
    (let-values (((handles requests) (loop-entries loop)))
      (cancel-requests! requests)
      (for-each close-handle! handles))
    (let drain ((i 0) (stored teardown-no-error))
      (let ((outcome (drain-step loop ptr)))
        (cond ((eq? outcome 'drained)
               (let-values (((rc error) (close-claimed! loop ptr)))
                 (uv-check rc 'uv-loop-close!)
                 (cond ((not (eq? stored teardown-no-error)) stored)
                       (error error)
                       (else teardown-no-error))))
              ((< i max-drain-iterations)
               (drain (+ i 1)
                      (if (and (eq? stored teardown-no-error)
                               (not (eq? outcome 'work)))
                          outcome
                          stored)))
              (else
               (raise (condition
                       (make-uv-error)
                       (make-who-condition 'uv-loop-teardown!)
                       (make-message-condition
                        "loop still had work after the drain bound"))))))))

  ;; call-with-uv-loop : (uv-loop -> object) -> object
  ;; The body runs once: the before thunk refuses every return into it after
  ;; it has been left, whatever became of the loop. The after thunk tears the
  ;; loop down however the body left.
  ;; - The loop is made inside the body, and handed over inside its own
  ;;   step, so wherever an engine expires from then on, the after thunk
  ;;   finds the loop. Made before the dynamic-wind, a loop was lost to an
  ;;   engine dropped in between (tests/test-constructors.sps).
  ;; - A body left from inside one of the loop's callbacks, by a continuation
  ;;   or an engine's suspension, leaves the loop marked running by this
  ;;   thread (#45). The after thunk clears that mark first, which is safe
  ;;   because nothing can resume the run the teardown ends.
  ;; - That teardown can fail: escaping one close callback strands the rest
  ;;   of libuv's batch of closes, and the loop cannot be closed. The failure
  ;;   is contained rather than raised in the middle of the escape or the
  ;;   suspension, and the loop stays marked running, as any abandoned run
  ;;   is, so no verb touches it.
  ;; - A loop marked running by another thread is live under that thread's
  ;;   uv_run: its mark stays, and the teardown refuses it, as from any exit.
  (define (call-with-uv-loop proc)
    (ensure-native-loaded!)
    (let ((loop #f) (left #f))
      (dynamic-wind
       (lambda ()
         (when left
           (raise (make-uv-handle-closed 'loop))))
       (lambda ()
         (let ((made (try-construct-loop uv-loop-init (lambda (made) (set! loop made)))))
           (if (uv-loop? made)
               (proc made)
               (raise (step-refusal made 'make-uv-loop #f)))))
       (lambda ()
         (set! left #t)
         (when (loop-open? loop)
           (if (and (loop-running? loop)
                    (eqv? (loop-owner-thread loop) (current-thread-id)))
               (begin
                 (set-loop-running! loop #f)
                 (guard (e (#t (set-loop-running! loop #t)))
                   (uv-loop-teardown! loop)))
               (uv-loop-teardown! loop))))))))
