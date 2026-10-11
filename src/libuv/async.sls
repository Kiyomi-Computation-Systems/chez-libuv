#!r6rs
;;; uv_async: the one cross-thread wakeup. An async handle is created and
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
  ;; Loop-thread-only: uv_async_init links the handle into the loop's
  ;; handle and async queues, which the loop's thread changes without a
  ;; lock. require-loop-thread runs before any allocation, so a wrong-thread
  ;; create is a named refusal, not a corrupted loop, and the constructor's
  ;; step checks the owner again, since an engine can suspend the
  ;; constructor while the loop is handed to another thread. The send
  ;; fence, a native mutex, is made before the step, because making one can
  ;; raise.
  (define (make-uv-async loop on-wake)
    (ensure-native-loaded!)
    (require-open-loop loop 'make-uv-async)
    (require-loop-thread loop 'make-uv-async)
    (require-callback on-wake 'make-uv-async 'on-wake-not-a-procedure)
    (let ((fence (make-send-fence)))
      (construct-handle 'make-uv-async loop (uv-handle-size (uv-async-type))
                        uv-async-init-native
                        (lambda (ptr) (%make-uv-async-record ptr loop on-wake fence))
                        count-async-new!)))

  ;; uv-async-send! : uv-async -> unspecified
  ;; The ONE verb exempt from loop-thread affinity: uv_async_send is
  ;; thread-safe, so a worker thread wakes the loop with it. It does not
  ;; touch the registry. The open check and the native send run inside the
  ;; handle's send fence, which uv-close! takes too, so a send either
  ;; completes before a close begins or is refused with &uv-handle-closed, never
  ;; made on a freed handle. Nothing may raise inside the fence, so the step
  ;; checks the pointer as handle-pointer would and answers a status, and the
  ;; refusal is raised after the release.
  (define (uv-async-send! async)
    (unless (uv-async-record? async)
      (raise (make-uv-invalid-argument 'uv-async-send! 'not-a-uv-async)))
    (let ((status (with-send-fence async
                    (let ((ptr (handle-ptr async)))
                      (cond ((not (eq? (handle-state async) 'open)) 'closed)
                            ((not (valid-pointer? ptr)) 'no-pointer)
                            (else (uv-async-send ptr)))))))
      (case status
        ((closed) (raise (make-uv-handle-closed 'async)))
        ((no-pointer)
         (raise (make-uv-invalid-argument 'uv-async-send! 'null-handle-pointer)))
        (else (uv-check status 'uv-async-send!)))))

  ;; Never deliver a wake to a handle already closing; the callback runs on the
  ;; loop thread, so it may safely touch the loop and its handles.
  (define (async-dispatch async handle-ptr)
    (if (uv-async-record? async)
        (when (eq? (handle-state async) 'open)
          (let ((on-wake (async-on-wake async)))
            (when on-wake (on-wake async))))
        (record-orphan-callback! 'async handle-ptr)))

  (define async-dispatch-installed
    (install-dispatch-procedure! 'async async-dispatch)))
