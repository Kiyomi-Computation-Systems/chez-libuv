#!r6rs
;;; Signal delivery, stopping, and one-shot disarming do not close a handle.
;;; The first successful start fixes its mode for life. Watching SIGINT takes
;;; it from Chez, and stopping the last watcher leaves the default disposition.
(library (libuv signal)
  (export make-uv-signal
          uv-signal-start! uv-signal-start-oneshot! uv-signal-stop!)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))

  ;; make-uv-signal : uv-loop -> uv-signal
  (define (make-uv-signal loop)
    (ensure-native-loaded!)
    (require-open-loop loop 'make-uv-signal)
    (construct-handle 'make-uv-signal loop (uv-handle-size (uv-signal-type))
                      uv-signal-init
                      (lambda (ptr) (%make-uv-signal-record ptr loop))
                      count-signal-new! #f))

  ;; watch-symbol->int : (or symbol 0) symbol -> exact-integer
  (define (watch-symbol->int sig who)
    (when (memq sig '(sigkill sigstop))
      (raise (make-uv-invalid-argument who 'signal-unwatchable)))
    (when (eqv? sig 0)
      (raise (make-uv-invalid-argument who 'signal-unknown)))
    (signal-symbol->int sig who))

  (define (require-signal-handle sig who)
    (unless (uv-signal-record? sig)
      (raise (make-uv-invalid-argument who 'not-a-uv-signal)))
    (require-open-handle sig who))

  (define (start-signal! sig watch-symbol on-signal wanted-mode
                         native-start who)
    (require-signal-handle sig who)
    (let ((mode (signal-mode sig)))
      (when (and mode (not (eq? mode wanted-mode)))
        (raise (make-uv-invalid-argument who 'signal-mode-fixed))))
    (require-callback on-signal who 'on-signal-not-a-procedure)
    (let ((signum (watch-symbol->int watch-symbol who)))
      (set-signal-on-signal! sig on-signal)
      ;; A pending signal may dispatch as soon as the handle is armed.
      (uv-check (native-start (handle-pointer sig who) signum) who)
      ;; Failed starts must not pin the mode.
      (set-signal-mode! sig wanted-mode)))

  ;; uv-signal-start! : uv-signal symbol procedure -> unspecified
  (define (uv-signal-start! sig watch-symbol on-signal)
    (start-signal! sig watch-symbol on-signal 'continuous
                   uv-signal-start-native 'uv-signal-start!))

  ;; uv-signal-start-oneshot! : uv-signal symbol procedure -> unspecified
  ;; Rearming inside the callback is ineffective: libuv auto-stops afterwards.
  (define (uv-signal-start-oneshot! sig watch-symbol on-signal)
    (start-signal! sig watch-symbol on-signal 'oneshot
                   uv-signal-start-oneshot-native 'uv-signal-start-oneshot!))

  ;; uv-signal-stop! : uv-signal -> unspecified
  (define (uv-signal-stop! sig)
    (require-signal-handle sig 'uv-signal-stop!)
    (uv-check (uv-signal-stop (handle-pointer sig 'uv-signal-stop!))
              'uv-signal-stop!))

  ;; Never deliver a queued signal to a handle already closing.
  (define (signal-dispatch sig handle-ptr signum)
    (if (uv-signal-record? sig)
        (when (eq? (handle-state sig) 'open)
          (let ((on-signal (signal-on-signal sig)))
            (when on-signal
              (on-signal (term-signal->value signum)))))
        (record-orphan-callback! 'signal handle-ptr)))

  (define signal-dispatch-installed
    (install-dispatch-procedure! 'signal signal-dispatch)))
