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
          (libuv private native)
          (only (libuv private c-types) c-int?))

  ;; uv-handle? : object -> boolean
  ;; uv-timer? : object -> boolean
  ;; The handle and timer records' predicates, defined with the records in
  ;; (libuv private handles) and exported from here.

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
  ;; uv-async? : object -> boolean
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

  ;; require-socket-handle : object symbol -> uv-handle
  ;; Buffer-size operations support TCP and pipes on Unix, but only TCP on
  ;; Windows; libuv reports unsupported platform cases.
  (define (require-socket-handle handle who)
    (require-open-handle handle who)
    (unless (memq (handle-kind handle) '(tcp pipe))
      (raise (make-uv-invalid-argument who 'not-a-socket-handle)))
    handle)

  ;; require-buffer-size : object symbol -> exact-positive-integer
  ;; Keep the value inside positive C int range; foreign-set! would truncate.
  (define (require-buffer-size n who)
    (unless (and (c-int? n) (positive? n))
      (raise (make-uv-invalid-argument who 'buffer-size-out-of-range)))
    n)

  ;; buffer-size-step : procedure uv-handle exact-integer symbol
  ;;                    -> exact-nonnegative-integer
  ;; NATIVE's answer for HANDLE: libuv selects get versus set by whether the
  ;; caller's int cell is zero, so N is 0 to get, and the size to set. One
  ;; interrupt-free step checks again that this thread owns the loop and
  ;; that the handle is open, and allocates the cell, writes N, calls libuv,
  ;; reads the cell back and frees it. So no engine can split the call from
  ;; those checks, or drop it holding the cell (tests/test-handle-steps.sps).
  (define (buffer-size-step native handle n who)
    (let ((answer
           (one-step
            (let ((ptr (owned-handle-ptr handle)))
              (if (refused? ptr)
                  ptr
                  (let ((cell (alloc-block (c-int-size))))
                    (if (zero? cell)
                        'no-memory
                        (let ((answer
                               (if (try-c-int-set! cell n)
                                   (let ((rc (native ptr cell)))
                                     (if (eqv? rc 0) (c-int-ref cell) rc))
                                   'buffer-size-out-of-range)))
                          (free-block! cell)
                          answer))))))))
      (if (and (fixnum? answer) (fx>=? answer 0))
          answer
          (raise (step-refusal answer who handle)))))

  (define (get-buffer-size! native handle who)
    (require-socket-handle handle who)
    (buffer-size-step native handle 0 who))

  (define (set-buffer-size! native handle n who)
    (require-socket-handle handle who)
    (require-buffer-size n who)
    (buffer-size-step native handle n who)
    (if #f #f))

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
