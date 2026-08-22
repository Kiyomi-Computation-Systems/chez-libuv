#!r6rs
;;; tests/signal-child.sps -- the spawned-child half of test-signal.sps's
;;; end-to-end graceful-shutdown scenario (v0.4 design spec §9.3; spike
;;; finding SQ-S2-F1). NOT a suite: the name stays outside the test-*.sps
;;; wildcard on purpose.
;;;
;;; Protocol, one line each on stdout (the parent's from-child pipe):
;;;   READY      after the oneshot sigterm watcher is armed
;;;   GOT1       from INSIDE the sigterm callback -- proves DELIVERY
;;;   DISARMED   from a LATER dispatch (a repeating timer's next tick) --
;;;              proves DISARM: the vendor auto-stop runs only after the
;;;              signal callback returns (EV-9), so any later dispatch is
;;;              after it by construction. The parent gates kill #2 here.
;;; Then kill #2 lands on SIG_DFL (EV-3) and this process dies (0 sigterm).
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

;; Iteration-capped stepping, never wall-clock: kill #2 ends this process
;; long before 4000 ticks of the 5 ms timer.
(let step ((i 0))
  (when (< i 4000)
    (uv-run l 'once)
    (step (+ i 1))))

(say! "SURVIVED")
(exit 43)
