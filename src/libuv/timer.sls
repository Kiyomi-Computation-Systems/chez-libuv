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

  ;; libuv takes milliseconds as a uint64_t. Chez's own check of a larger
  ;; argument would raise inside a verb's step, where nothing may raise.
  (define uint64-limit (expt 2 64))

  ;; valid-milliseconds? : object -> boolean
  (define (valid-milliseconds? n)
    (and (integer? n) (exact? n) (>= n 0) (< n uint64-limit)))

  ;; require-open-timer : object symbol -> uv-timer
  ;; libuv's timer calls take any handle's address as a uv_timer_t's, so
  ;; another kind of handle is refused by name; a non-handle stays
  ;; 'not-a-uv-handle (tests/test-timer.sps).
  (define (require-open-timer timer who)
    (require-handle timer who)
    (unless (uv-timer? timer)
      (raise (make-uv-invalid-argument who 'not-a-uv-timer)))
    (require-open-handle timer who))

  ;; make-uv-timer : uv-loop -> uv-timer
  (define (make-uv-timer loop)
    (ensure-native-loaded!)
    (require-open-loop loop 'make-uv-timer)
    (construct-handle 'make-uv-timer loop (uv-handle-size (uv-timer-type))
                      uv-timer-init
                      (lambda (ptr) (%make-uv-timer-record ptr loop))
                      count-timer-new!))

  ;; uv-timer-start! : uv-timer procedure exact-nonnegative-integer
  ;;                   exact-nonnegative-integer -> unspecified
  ;; libuv counts timeout-ms from the loop's CACHED time (uv-now), which a
  ;; callback that held the loop has left behind; such a caller refreshes it
  ;; with uv-update-time! before arming, or the timer comes due early.
  ;; One interrupt-free step checks again that this thread owns the loop and
  ;; that the timer is open, arms it, and stores the callback once libuv has
  ;; armed it. A timer fires only inside uv-run, so even a zero delay
  ;; cannot fire between the two, and no engine can split the start from
  ;; those checks or drop it half made (tests/test-handle-steps.sps).
  (define (uv-timer-start! timer on-timeout timeout-ms repeat-ms)
    (require-open-timer timer 'uv-timer-start!)
    (unless (procedure? on-timeout)
      (raise (make-uv-invalid-argument 'uv-timer-start!
                                       'on-timeout-not-a-procedure)))
    (unless (valid-milliseconds? timeout-ms)
      (raise (make-uv-invalid-argument 'uv-timer-start! 'timeout-out-of-range)))
    (unless (valid-milliseconds? repeat-ms)
      (raise (make-uv-invalid-argument 'uv-timer-start! 'repeat-out-of-range)))
    (let ((rc (one-step
               (let ((ptr (owned-handle-ptr timer)))
                 (if (refused? ptr)
                     ptr
                     (let ((rc (uv-timer-start-native ptr timeout-ms repeat-ms)))
                       (when (eqv? rc 0) (set-timer-on-timeout! timer on-timeout))
                       rc))))))
      (unless (eqv? rc 0)
        (raise (step-refusal rc 'uv-timer-start! timer)))))

  ;; Each verb below is one interrupt-free step too, which checks again that
  ;; this thread owns the loop and that the timer is open: no engine can
  ;; split the call from those checks (tests/test-handle-steps.sps).

  ;; uv-timer-stop! : uv-timer -> unspecified
  ;; Keep the callback so uv-timer-again! can re-arm a stopped timer.
  (define (uv-timer-stop! timer)
    (require-open-timer timer 'uv-timer-stop!)
    (handle-call! timer 'uv-timer-stop! uv-timer-stop))

  ;; uv-timer-again! : uv-timer -> unspecified
  (define (uv-timer-again! timer)
    (require-open-timer timer 'uv-timer-again!)
    (handle-call! timer 'uv-timer-again! uv-timer-again))

  ;; uv-timer-repeat : uv-timer -> exact-nonnegative-integer
  (define (uv-timer-repeat timer)
    (require-open-timer timer 'uv-timer-repeat)
    (let ((repeat (one-step
                   (let ((ptr (owned-handle-ptr timer)))
                     (if (refused? ptr) ptr (uv-timer-get-repeat ptr))))))
      (if (refused? repeat)
          (raise (step-refusal repeat 'uv-timer-repeat timer))
          repeat)))

  ;; uv-timer-set-repeat! : uv-timer exact-nonnegative-integer -> unspecified
  (define (uv-timer-set-repeat! timer repeat-ms)
    (require-open-timer timer 'uv-timer-set-repeat!)
    (unless (valid-milliseconds? repeat-ms)
      (raise (make-uv-invalid-argument 'uv-timer-set-repeat!
                                       'repeat-out-of-range)))
    (let ((ptr (one-step
                (let ((ptr (owned-handle-ptr timer)))
                  (unless (refused? ptr) (uv-timer-set-repeat ptr repeat-ms))
                  ptr))))
      (when (refused? ptr)
        (raise (step-refusal ptr 'uv-timer-set-repeat! timer))))))
