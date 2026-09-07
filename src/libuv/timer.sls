#!r6rs
;;; Timer handles are explicitly closed through uv-close!.
(library (libuv timer)
  (export make-uv-timer
          uv-timer-start! uv-timer-stop! uv-timer-again!
          uv-timer-repeat uv-timer-set-repeat!)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))

  ;; valid-milliseconds? : object -> boolean
  (define (valid-milliseconds? n)
    (and (integer? n) (exact? n) (>= n 0)))

  ;; make-uv-timer : uv-loop -> uv-timer
  (define (make-uv-timer loop)
    (ensure-native-loaded!)
    (require-open-loop loop 'make-uv-timer)
    (let ((ptr (alloc-zeroed (uv-handle-size (uv-timer-type)))))
      (guard (e (#t (free! ptr) (raise e)))
        (uv-check (uv-timer-init (loop-pointer loop 'make-uv-timer) ptr)
                  'make-uv-timer))
      (let ((timer (%make-uv-timer-record ptr loop)))
        (registry-register! ptr 'timer loop timer)
        (count-timer-new!)
        timer)))

  ;; uv-timer-start! : uv-timer procedure exact-nonnegative-integer
  ;;                   exact-nonnegative-integer -> unspecified
  ;; Store the callback before arming: a zero-delay timer may fire immediately.
  (define (uv-timer-start! timer on-timeout timeout-ms repeat-ms)
    (require-open-handle timer 'uv-timer-start!)
    (unless (procedure? on-timeout)
      (raise (make-uv-invalid-argument 'uv-timer-start!
                                       'on-timeout-not-a-procedure)))
    (unless (valid-milliseconds? timeout-ms)
      (raise (make-uv-invalid-argument 'uv-timer-start! 'timeout-out-of-range)))
    (unless (valid-milliseconds? repeat-ms)
      (raise (make-uv-invalid-argument 'uv-timer-start! 'repeat-out-of-range)))
    (set-timer-on-timeout! timer on-timeout)
    (uv-check (uv-timer-start-native (handle-pointer timer 'uv-timer-start!)
                                     timeout-ms repeat-ms)
              'uv-timer-start!))

  ;; uv-timer-stop! : uv-timer -> unspecified
  ;; Keep the callback so uv-timer-again! can re-arm a stopped timer.
  (define (uv-timer-stop! timer)
    (require-open-handle timer 'uv-timer-stop!)
    (uv-check (uv-timer-stop (handle-pointer timer 'uv-timer-stop!))
              'uv-timer-stop!))

  ;; uv-timer-again! : uv-timer -> unspecified
  (define (uv-timer-again! timer)
    (require-open-handle timer 'uv-timer-again!)
    (uv-check (uv-timer-again (handle-pointer timer 'uv-timer-again!))
              'uv-timer-again!))

  ;; uv-timer-repeat : uv-timer -> exact-nonnegative-integer
  (define (uv-timer-repeat timer)
    (require-open-handle timer 'uv-timer-repeat)
    (uv-timer-get-repeat (handle-pointer timer 'uv-timer-repeat)))

  ;; uv-timer-set-repeat! : uv-timer exact-nonnegative-integer -> unspecified
  (define (uv-timer-set-repeat! timer repeat-ms)
    (require-open-handle timer 'uv-timer-set-repeat!)
    (unless (valid-milliseconds? repeat-ms)
      (raise (make-uv-invalid-argument 'uv-timer-set-repeat!
                                       'repeat-out-of-range)))
    (uv-timer-set-repeat (handle-pointer timer 'uv-timer-set-repeat!)
                         repeat-ms)))
