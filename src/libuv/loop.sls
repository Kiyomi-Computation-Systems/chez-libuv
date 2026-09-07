#!r6rs
;;; Event-loop lifecycle and callback-error delivery. Loops own native memory
;;; explicitly; callers close or tear them down rather than relying on GC.
(library (libuv loop)
  (export make-uv-loop uv-loop? uv-loop-open?
          uv-run uv-stop! uv-loop-alive? uv-now
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
    (let ((ptr (alloc-zeroed (uv-loop-size))))
      (guard (e (#t (free! ptr) (raise e)))
        (uv-check (uv-loop-init ptr) 'make-uv-loop))
      (let ((loop (%make-uv-loop-record ptr)))
        (registry-register! ptr 'loop loop loop)
        (count-loop-new!)
        loop)))

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
         (let ((rc (dynamic-wind
                    (lambda () (set-loop-running! loop #t))
                    (lambda () (uv-loop-run ptr mode-int))
                    (lambda () (set-loop-running! loop #f)))))
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
  ;; This is libuv's cached time and changes only when the loop updates it.
  (define (uv-now loop)
    (require-open-loop loop 'uv-now)
    (uv-loop-now (loop-pointer loop 'uv-now)))

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
  ;; The before thunk rejects continuation re-entry after teardown.
  (define (call-with-uv-loop proc)
    (let ((loop (make-uv-loop)))
      (dynamic-wind
       (lambda ()
         (unless (loop-open? loop)
           (raise (make-uv-handle-closed 'loop))))
       (lambda () (proc loop))
       (lambda ()
         (when (loop-open? loop)
           (uv-loop-teardown! loop)))))))
