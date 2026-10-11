#!r6rs
;;; tests/signal-child.sps -- the spawned-child half of test-signal.sps's
;;; end-to-end graceful-shutdown scenario. NOT a suite: the name stays
;;; outside the test-*.sps wildcard on purpose.
;;;
;;; Protocol, one line each on stdout (the parent's from-child pipe):
;;;   READY      after the oneshot sigterm watcher is armed
;;;   GOT1       from INSIDE the sigterm callback -- proves DELIVERY
;;;   DISARMED   from a LATER dispatch (a repeating timer's next tick) --
;;;              proves DISARM: the vendor auto-stop runs only after the
;;;              signal callback returns, so any later dispatch is after
;;;              it by construction. The parent gates its second kill here.
;;; GOT1 proves delivery only: libuv stops a oneshot watcher after its
;;; callback returns, so while the callback runs the watcher still reads
;;; active. DISARMED comes from a dispatch after that stop.
;;; Then the second kill lands on SIG_DFL (libuv leaves SIG_DFL when the last
;;; watcher on a signum stops) and this process dies (0 sigterm).
;;; Surviving to the iteration cap is the named failure: exit 43.
(import (rnrs)
        (libuv)
        (only (chezscheme) collect))

(define l (make-uv-loop))
(define got #f)
(define acked #f)

(define (say! line)
  (put-string (current-output-port) line)
  (put-string (current-output-port) "\n")
  (flush-output-port (current-output-port)))

(define w (make-uv-signal l))
(define tick (make-uv-timer l))

(uv-signal-start-oneshot! w 'sigterm
  (lambda (s) (set! got #t) (say! "GOT1") (collect)))

(uv-timer-start! tick
  (lambda (t)
    (when (and got (not acked))
      (set! acked #t)
      (say! "DISARMED")))
  5 5)

(say! "READY")

;; Iteration-capped stepping, never wall-clock: the second kill ends this process
;; long before 4000 ticks of the 5 ms timer.
(let step ((i 0))
  (when (< i 4000)
    (uv-run l 'once)
    (step (+ i 1))))

(say! "SURVIVED")
(exit 43)
