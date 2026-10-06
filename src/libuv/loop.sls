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

  ;; Consume before raising so one callback failure cannot be delivered twice.
  (define (deliver-pending-callback-error! loop)
    (when (loop-has-pending-error? loop)
      (let ((pending (loop-pending-error loop)))
        (clear-loop-pending-error! loop)
        (raise (if (condition? pending)
                   (condition (make-uv-callback-error pending) pending)
                   (make-uv-callback-error pending))))))

  ;; uv-run : uv-loop [symbol] -> boolean
  ;; The boolean says whether work remains; libuv's raw integer would invert
  ;; ordinary Scheme truth tests because zero is true.
  ;;
  ;; The loop is marked running for as long as uv_run's frame is on the
  ;; stack, and that can outlast the call: an engine that runs out of fuel in
  ;; a callback suspends the frame, and a continuation that escapes a
  ;; callback abandons it, both in the middle of an iteration only a return
  ;; into the frame can finish. So the mark is cleared when uv_run returns
  ;; and not on the way out of the call (#45), and every verb that would run,
  ;; close or tear the loop down meanwhile refuses it. No raise needs
  ;; unwinding here: the seams contain every raise, and uv_run returns.
  (define uv-run
    (case-lambda
      ((loop) (uv-run loop 'default))
      ((loop mode)
       (require-open-loop loop 'uv-run)
       (when (loop-running? loop)
         (raise (make-uv-invalid-argument 'uv-run 'loop-running)))
       (let ((mode-int (run-mode->int mode 'uv-run))
             (ptr (loop-pointer loop 'uv-run)))
         (set-loop-deferred-error-list! loop '())
         ;; Transfer ownership to the calling thread: a loop created on one
         ;; thread and run on another (the worker-pool handoff) becomes owned by
         ;; whichever thread runs it. Concurrent uv-run is already refused above,
         ;; so at most one thread runs the loop at a time and the transfer is
         ;; unambiguous (design §6.2).
         (set-loop-owner-thread! loop (current-thread-id))
         (set-loop-running! loop #t)
         (let ((rc (uv-loop-run ptr mode-int)))
           (set-loop-running! loop #f)
           (deliver-pending-callback-error! loop)
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
  (define (uv-loop-close! loop)
    (require-loop loop 'uv-loop-close!)
    (when (loop-running? loop)
      (raise (make-uv-invalid-argument 'uv-loop-close! 'loop-running)))
    (when (eq? (loop-state loop) 'open)
      (let ((ptr (loop-pointer loop 'uv-loop-close!)))
        (uv-check (uv-loop-close ptr) 'uv-loop-close!)
        (set-loop-state! loop 'closed)
        (registry-deregister! ptr)
        (free! ptr)
        (set-loop-ptr! loop 0)
        (count-loop-free!)
        (deliver-pending-callback-error! loop))))

  ;; Bound iterations, not wall time, so teardown is deterministic under load.
  (define max-drain-iterations 1024)

  (define teardown-no-error (list 'no-error))

  (define (drain-step loop)
    (guard (e ((uv-callback-error? e) e))
      (if (uv-run loop 'default) 'work 'drained)))

  ;; uv-loop-teardown! : uv-loop -> unspecified
  ;; Cancel handle-less requests, close handles, drain completions, then close.
  ;; A callback failure is retained until cleanup finishes and then re-raised.
  (define (uv-loop-teardown! loop)
    (require-loop loop 'uv-loop-teardown!)
    (when (loop-running? loop)
      (raise (make-uv-invalid-argument 'uv-loop-teardown! 'loop-running)))
    (when (eq? (loop-state loop) 'open)
      (cancel-requests-for-loop! loop)
      (for-each close-handle! (registry-snapshot-for-loop loop))
      (let drain ((i 0) (stored teardown-no-error))
        (let ((outcome (drain-step loop)))
          (cond ((eq? outcome 'drained)
                 (uv-loop-close! loop)
                 (unless (eq? stored teardown-no-error) (raise stored)))
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
                          "loop still had work after the drain bound")))))))))

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
