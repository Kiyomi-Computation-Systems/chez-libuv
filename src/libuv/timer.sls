#!r6rs
;;; (libuv timer) -- libuv's timer verbs, as a legible mirror (design spec
;;; S1): start, stop, again, and the repeat interval. Closing a timer is
;;; (libuv handle)'s uv-close!, because the close protocol is generic.
;;;
;;; A timer is the smallest surface that exercises the whole callback path
;;; end to end (design spec S12, Stage 3): C calls Scheme, the registry turns
;;; a bare pointer back into a record, the guard of S8 keeps a raise out of
;;; libuv's C frames, and the close protocol of S5 frees the handle in
;;; exactly one place.
;;;
;;; NO PROCEDURE HERE TAKES OR RETURNS A POINTER. A timer is an opaque
;;; record; make-uv-timer is the only way to get one.
(library (libuv timer)
  (export make-uv-timer
          uv-timer-start! uv-timer-stop! uv-timer-again!
          uv-timer-repeat uv-timer-set-repeat!)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))

  ;; Milliseconds, as libuv takes them: an exact non-negative integer. The
  ;; check is explicit and happens BEFORE any native call, because
  ;; `unsigned-64` is what the binding declares -- handing it a negative or
  ;; inexact number is either a Chez marshalling error from deep inside the
  ;; FFI or, worse, a very large timeout that looks like a hang.
  (define (valid-milliseconds? n)
    (and (integer? n) (exact? n) (>= n 0)))

  ;; --- construction (design spec S5) --------------------------------------
  ;; The size comes from uv_handle_size(UV_TIMER) -- the RUNNING library's
  ;; own answer, with UV_TIMER itself looked up from the shim's table rather
  ;; than transcribed (ADR-0005).
  ;;
  ;; Order on the failure path is the specification: a nonzero uv_timer_init
  ;; frees the block before the condition escapes, and nothing has been
  ;; registered or counted yet, so there is no half-built handle for a caller
  ;; to find.
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

  ;; --- arming -------------------------------------------------------------
  ;; (uv-timer-start! timer on-timeout timeout-ms repeat-ms)
  ;;
  ;; `on-timeout` is called with the timer record itself, mirroring libuv's
  ;; uv_timer_cb(uv_timer_t*) -- so a callback can stop or close the handle
  ;; that fired without having captured it, which is what makes a
  ;; self-limiting timer expressible.
  ;;
  ;; A repeat of 0 is libuv's one-shot. Restarting an already-started timer
  ;; is libuv's own documented way to re-arm it, so it is not refused here.
  ;;
  ;; EVERY ARGUMENT IS VALIDATED BEFORE THE FIRST NATIVE CALL, and the
  ;; callback is stored before uv_timer_start rather than after: the timer
  ;; can fire as soon as it is armed, and a callback stored afterwards would
  ;; be a race with a 0 ms timeout on a loop that is already running.
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

  ;; Stopping is idempotent in libuv (uv_timer_stop on a stopped timer
  ;; returns 0), so it is not gated on anything but the handle being open.
  ;; The stored callback is deliberately KEPT: uv_timer_again re-arms with
  ;; the timer's own callback, and clearing it here would make that verb
  ;; unusable after a stop.
  (define (uv-timer-stop! timer)
    (require-open-handle timer 'uv-timer-stop!)
    (uv-check (uv-timer-stop (handle-pointer timer 'uv-timer-stop!))
              'uv-timer-stop!))

  ;; libuv's uv_timer_again: restart a repeating timer with its stored
  ;; repeat interval. On a timer that was never started there is no callback
  ;; to re-arm and libuv answers UV_EINVAL, which uv-check surfaces as
  ;; &uv-errno-error carrying the SYMBOL 'EINVAL (ADR-0006) -- not a raw
  ;; -22, and not a silent no-op.
  (define (uv-timer-again! timer)
    (require-open-handle timer 'uv-timer-again!)
    (uv-check (uv-timer-again (handle-pointer timer 'uv-timer-again!))
              'uv-timer-again!))

  ;; --- the repeat interval ------------------------------------------------
  ;; Read straight back out of the uv_timer_t rather than from a Scheme-side
  ;; copy: libuv itself changes it (uv_timer_start overwrites it), so a
  ;; cached copy would drift from the value that actually governs the timer.
  (define (uv-timer-repeat timer)
    (require-open-handle timer 'uv-timer-repeat)
    (uv-timer-get-repeat (handle-pointer timer 'uv-timer-repeat)))

  ;; uv_timer_set_repeat returns void: there is no rc to check. Applied to a
  ;; RUNNING repeating timer it takes effect on the next expiry, not this
  ;; one -- libuv's documented behaviour, mirrored rather than smoothed over.
  (define (uv-timer-set-repeat! timer repeat-ms)
    (require-open-handle timer 'uv-timer-set-repeat!)
    (unless (valid-milliseconds? repeat-ms)
      (raise (make-uv-invalid-argument 'uv-timer-set-repeat!
                                       'repeat-out-of-range)))
    (uv-timer-set-repeat (handle-pointer timer 'uv-timer-set-repeat!)
                         repeat-ms)))
