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

  ;; --- policy helpers (§4.2, ADR-0017) ------------------------------------
  ;; The watchable subset: ADR-0016's nine minus the two the kernel forbids
  ;; catching. Layered on top of the lifted signal-symbol->int: vocabulary
  ;; is shared, refusal policy is not. Exact 0 -- the SENDING liveness
  ;; probe -- names no signal, so watching refuses it as unknown, not
  ;; unwatchable.
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

  ;; The one start path both verbs share. VALIDATION ORDER (§4.2): kind,
  ;; state, mode compatibility, procedure, symbol -- all before any native
  ;; call. The callback is stored BEFORE arming (a pending same-signum
  ;; delivery can dispatch on the very next uv-run: the vendor's
  ;; same-signum restart is a callback swap that preserves pending
  ;; deliveries, EV-1 -- which is also why this wrapper NEVER issues a
  ;; stop-then-start for a rearm: a last-watcher stop would install SIG_DFL
  ;; and a watched fatal signal in that window kills the process). MODE IS
  ;; PINNED ONLY AFTER uv-check SUCCEEDS: a refused or failed start pins
  ;; nothing (ADR-0017 D10 -- "the first start verb" means the first one
  ;; that arms).
  (define (start-signal! sig watch-symbol on-signal wanted-mode
                         native-start who)
    (require-signal-handle sig who)
    (let ((mode (signal-mode sig)))
      (when (and mode (not (eq? mode wanted-mode)))
        (raise (make-uv-invalid-argument who 'signal-mode-fixed))))
    (require-callback on-signal who 'on-signal-not-a-procedure)
    (let ((signum (watch-symbol->int watch-symbol who)))
      (set-signal-on-signal! sig on-signal)
      (uv-check (native-start (handle-pointer sig who) signum) who)
      (set-signal-mode! sig wanted-mode)))

  ;; Continuous: fires on every delivery until stopped or closed. Rearm
  ;; while armed is allowed WITHIN the mode: a signum change is libuv's
  ;; internal stop-then-start; same-signum is the pending-preserving
  ;; callback swap (EV-1, measured).
  (define (uv-signal-start! sig watch-symbol on-signal)
    (start-signal! sig watch-symbol on-signal 'continuous
                   uv-signal-start-native 'uv-signal-start!))

  ;; Oneshot: fires exactly once; libuv disarms the watcher itself, and
  ;; once no watcher remains for the signum PROCESS-WIDE the disposition
  ;; reverts to SIG_DFL (EV-3) -- first-SIGTERM-drains, second-kills.
  ;; REARMING FROM INSIDE ITS OWN CALLBACK DOES NOT TAKE EFFECT: the
  ;; vendor auto-stop runs after the callback returns and undoes it,
  ;; rc 0 (EV-9, measured; D11). Rearm from a later dispatch instead.
  (define (uv-signal-start-oneshot! sig watch-symbol on-signal)
    (start-signal! sig watch-symbol on-signal 'oneshot
                   uv-signal-start-oneshot-native 'uv-signal-start-oneshot!))

  ;; Idempotent (EV-2: rc 0 on a never-started or auto-disarmed watcher).
  ;; The 'open pre-check is load-bearing, not cosmetic: the native calls
  ;; assert-abort on a closing handle in assert-enabled builds, and close
  ;; stops the watcher itself (EV-10) -- so no native stop ever follows
  ;; uv-close!.
  (define (uv-signal-stop! sig)
    (require-signal-handle sig 'uv-signal-stop!)
    (uv-check (uv-signal-stop (handle-pointer sig 'uv-signal-stop!))
              'uv-signal-stop!))

  ;; --- the dispatcher (timer-shaped; §5.3) --------------------------------
  ;; Delivers only to 'open handles (timer discipline: a delivery dequeued
  ;; for a 'closing handle is dropped silently -- close already stopped the
  ;; watcher, EV-10). The signum is converted through the lifted reverse
  ;; map for uniformity; start validated the symbol, so only symbol arms
  ;; are reachable. Runs under dispatch-guarded: store-and-reraise
  ;; unchanged.
  (define (signal-dispatch handle-ptr signum)
    (let ((sig (registry-ref handle-ptr)))
      (if (uv-signal-record? sig)
          (when (eq? (handle-state sig) 'open)
            (let ((on-signal (signal-on-signal sig)))
              (when on-signal
                (dispatch-guarded
                 (handle-loop sig)
                 (lambda () (on-signal (term-signal->value signum)))))))
          (record-orphan-callback! 'signal handle-ptr))))

  ;; The late install (the dns.sls seam's third application, ADR-0008): the
  ;; 'signal slot held handles.sls's contained raising stub until this
  ;; instant; a process image that never imports (libuv signal) keeps it.
  (define signal-dispatch-installed
    (install-dispatch-procedure! 'signal signal-dispatch)))
