#!r6rs
;;; uv_async: the one cross-thread wakeup (#20). An async handle is created and
;;; closed on its loop's owning thread like every other handle, but uv-async-send!
;;; may be called from ANY thread — uv_async_send is libuv's sole thread-safe
;;; call. Sends coalesce: N sends may yield a single wake callback, so the wake
;;; callback should drain a caller-side queue rather than assume one item.
(library (libuv async)
  (export make-uv-async uv-async-send!)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))

  ;; make-uv-async : uv-loop procedure -> uv-async
  ;; Loop-thread-only: it initialises native state and mutates the registry.
  ;; require-loop-thread runs before any allocation, so a wrong-thread create is
  ;; a named refusal, not a corrupted registry.
  (define (make-uv-async loop on-wake)
    (ensure-native-loaded!)
    (require-open-loop loop 'make-uv-async)
    (require-loop-thread loop 'make-uv-async)
    (require-callback on-wake 'make-uv-async 'on-wake-not-a-procedure)
    (let ((ptr (alloc-zeroed (uv-handle-size (uv-async-type)))))
      (guard (e (#t (free! ptr) (raise e)))
        (uv-check (uv-async-init-native (loop-pointer loop 'make-uv-async) ptr)
                  'make-uv-async))
      (let ((async (%make-uv-async-record ptr loop on-wake)))
        (registry-register! ptr 'async loop async)
        (count-async-new!)
        async)))

  ;; uv-async-send! : uv-async -> unspecified
  ;; The ONE verb exempt from the loop-thread affinity check (design §6.3):
  ;; uv_async_send is thread-safe, so a worker thread wakes the loop with it. It
  ;; does not touch the registry. Kind and open state are validated as a
  ;; courtesy for the already-closed case; the caller must ensure the async
  ;; outlives its senders (libuv's own lifetime contract — close happens on the
  ;; loop thread and is the consumer's responsibility to sequence).
  (define (uv-async-send! async)
    (unless (uv-async-record? async)
      (raise (make-uv-invalid-argument 'uv-async-send! 'not-a-uv-async)))
    (unless (eq? (handle-state async) 'open)
      (raise (make-uv-handle-closed 'async)))
    (uv-check (uv-async-send (handle-pointer async 'uv-async-send!))
              'uv-async-send!))

  ;; Never deliver a wake to a handle already closing; the callback runs on the
  ;; loop thread, so it may safely touch the loop and its handles.
  (define (async-dispatch handle-ptr)
    (let ((async (registry-ref handle-ptr)))
      (if (uv-async-record? async)
          (when (eq? (handle-state async) 'open)
            (let ((on-wake (async-on-wake async)))
              (when on-wake
                (dispatch-guarded (handle-loop async)
                                  (lambda () (on-wake async))))))
          (record-orphan-callback! 'async handle-ptr))))

  (define async-dispatch-installed
    (install-dispatch-procedure! 'async async-dispatch)))
