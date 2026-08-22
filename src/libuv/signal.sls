#!r6rs
;;; (libuv signal) -- uv_signal_t watching (v0.4 design spec, ADR-0017).
;;; The receiving half of the pair (libuv process)'s uv-kill! started.
;;;
;;; DELIVERY != CLOSE (ADR-0007/0017): neither delivery, uv-signal-stop!,
;;; nor oneshot auto-disarm closes the handle; the caller always
;;; uv-close!s, and close implicitly stops an armed watcher (EV-10).
;;;
;;; MODE IS FIXED PER HANDLE (D10, EV-8 -- measured): the first successful
;;; start verb pins 'continuous | 'oneshot; the other verb thereafter
;;; raises 'signal-mode-fixed. Changing mode = uv-close! + make-uv-signal.
;;;
;;; THE COEXISTENCE CAVEAT (SQ-S1, measured both platforms): watching
;;; sigint takes SIGINT away from the Chez runtime, and uv_signal_stop
;;; restores SIG_DFL -- NOT what was there before. libuv's behavior,
;;; surfaced not fixed (README carries the caveat).
;;;
;;; NO PROCEDURE HERE TAKES OR RETURNS A POINTER.
(library (libuv signal)
  (export make-uv-signal
          uv-signal-start! uv-signal-start-oneshot! uv-signal-stop!)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))

  ;; The make-uv-timer shape verbatim: size from the RUNNING library via
  ;; uv_handle_size, type tag from the shim (ADR-0005); a failed init frees
  ;; the block before the condition escapes, and nothing is registered or
  ;; counted yet.
  (define (make-uv-signal loop)
    (ensure-native-loaded!)
    (require-open-loop loop 'make-uv-signal)
    (let ((ptr (alloc-zeroed (uv-handle-size (uv-signal-type)))))
      (guard (e (#t (free! ptr) (raise e)))
        (uv-check (uv-signal-init (loop-pointer loop 'make-uv-signal) ptr)
                  'make-uv-signal))
      (let ((sig (%make-uv-signal-record ptr loop)))
        (registry-register! ptr 'signal loop sig)
        (count-signal-new!)
        sig)))

  ;; The verbs and the dispatcher land with the next task; nothing can arm
  ;; a watcher yet, so the 'signal dispatcher slot deliberately still holds
  ;; handles.sls's contained raising stub.
  (define (uv-signal-start! sig watch-symbol on-signal)
    (raise (make-uv-invalid-argument 'uv-signal-start! 'not-yet-implemented)))
  (define (uv-signal-start-oneshot! sig watch-symbol on-signal)
    (raise (make-uv-invalid-argument 'uv-signal-start-oneshot!
                                     'not-yet-implemented)))
  (define (uv-signal-stop! sig)
    (raise (make-uv-invalid-argument 'uv-signal-stop! 'not-yet-implemented))))
