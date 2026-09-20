#!r6rs
;;; Shared handle state and explicit asynchronous close ownership.
(library (libuv handle)
  (export uv-handle? uv-timer? uv-tcp? uv-pipe? uv-process? uv-signal? uv-async?
          uv-handle-open? uv-handle-closing? uv-handle-state
          uv-handle-loop
          uv-send-buffer-size uv-send-buffer-size!
          uv-recv-buffer-size uv-recv-buffer-size!
          uv-close!)
  (import (rnrs)
          (libuv private conditions)
          (libuv private handles)
          (libuv private native))

  ;; uv-handle-open? : object -> boolean
  ;; uv-handle-closing? : object -> boolean
  ;; These predicates accept non-handles so cleanup paths can probe safely.
  (define (uv-handle-open? handle)
    (and (uv-handle? handle) (eq? (handle-state handle) 'open)))

  (define (uv-handle-closing? handle)
    (and (uv-handle? handle) (eq? (handle-state handle) 'closing)))

  ;; uv-handle-state : uv-handle -> (or 'open 'closing 'closed)
  (define (uv-handle-state handle)
    (require-handle handle 'uv-handle-state)
    (handle-state handle))

  ;; uv-handle-loop : uv-handle -> uv-loop
  ;; The loop backpointer remains valid after the handle closes.
  (define (uv-handle-loop handle)
    (require-handle handle 'uv-handle-loop)
    (handle-loop handle))

  ;; uv-tcp? : object -> boolean
  ;; uv-pipe? : object -> boolean
  ;; uv-process? : object -> boolean
  ;; uv-signal? : object -> boolean
  (define (uv-tcp? handle)
    (and (uv-handle? handle) (eq? (handle-kind handle) 'tcp)))

  (define (uv-pipe? handle)
    (and (uv-handle? handle) (eq? (handle-kind handle) 'pipe)))

  (define (uv-process? handle)
    (and (uv-handle? handle) (eq? (handle-kind handle) 'process)))

  (define (uv-signal? handle)
    (and (uv-handle? handle) (eq? (handle-kind handle) 'signal)))

  (define (uv-async? handle)
    (and (uv-handle? handle) (eq? (handle-kind handle) 'async)))

  ;; Buffer-size operations support TCP and pipes on Unix, but only TCP on
  ;; Windows; libuv reports unsupported platform cases.
  (define (require-socket-handle handle who)
    (require-open-handle handle who)
    (unless (memq (handle-kind handle) '(tcp pipe))
      (raise (make-uv-invalid-argument who 'not-a-socket-handle)))
    handle)

  ;; Keep the value inside positive C int range; foreign-set! would truncate.
  (define (require-buffer-size n who)
    (unless (and (integer? n) (exact? n) (positive? n) (< n 2147483648))
      (raise (make-uv-invalid-argument who 'buffer-size-out-of-range)))
    n)

  ;; libuv selects get versus set by whether the caller's int cell is zero.
  (define (get-buffer-size! native handle who)
    (require-socket-handle handle who)
    (let ((cell (alloc-zeroed (c-int-size))))
      (guard (e (#t (free! cell) (raise e)))
        (uv-check (native (handle-pointer handle who) cell) who)
        (let ((v (c-int-ref cell)))
          (free! cell)
          v))))

  (define (set-buffer-size! native handle n who)
    (require-socket-handle handle who)
    (require-buffer-size n who)
    (let ((cell (alloc-zeroed (c-int-size))))
      (guard (e (#t (free! cell) (raise e)))
        (c-int-set! cell n)
        (uv-check (native (handle-pointer handle who) cell) who)
        (free! cell))))

  ;; uv-send-buffer-size : uv-handle -> exact-nonnegative-integer
  ;; uv-send-buffer-size! : uv-handle exact-positive-integer -> unspecified
  ;; uv-recv-buffer-size : uv-handle -> exact-nonnegative-integer
  ;; uv-recv-buffer-size! : uv-handle exact-positive-integer -> unspecified
  ;; These are OS socket buffers, independent of the stream read buffer.
  (define (uv-send-buffer-size handle)
    (get-buffer-size! uv-send-buffer-size-native handle 'uv-send-buffer-size))
  (define (uv-send-buffer-size! handle n)
    (set-buffer-size! uv-send-buffer-size-native handle n 'uv-send-buffer-size!))
  (define (uv-recv-buffer-size handle)
    (get-buffer-size! uv-recv-buffer-size-native handle 'uv-recv-buffer-size))
  (define (uv-recv-buffer-size! handle n)
    (set-buffer-size! uv-recv-buffer-size-native handle n 'uv-recv-buffer-size!))

  ;; uv-close! : uv-handle [procedure] -> unspecified
  ;; Idempotent and asynchronous. The first callback wins; memory is released
  ;; only when a later loop iteration dispatches the close completion.
  (define uv-close!
    (case-lambda
      ((handle) (close-handle! handle))
      ((handle on-close) (close-handle! handle on-close)))))
