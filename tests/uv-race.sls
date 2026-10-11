#!r6rs
;;; What a cross-thread race needs to show that its other thread raced: a
;;; liveness watch, shared by tests/test-native.sps, tests/test-stream.sps
;;; and tests/spawn-list-races.sls.
;;;
;;; A race whose flipper never ran, or stopped, passes every row it has. So
;;; before the race's first call and after its last, the race waits up to
;;; race-wait-cap steps to see its flipper cut the datum and make it whole
;;; again, watching it through the value the calls are given, and a
;;; precondition row holds the answer. The watch requires the datum's own
;;; WHOLE value back, not just a change, since a flipper that swapped the cut
;;; for another bad value would otherwise pass as live.
;;;
;;; PURE: (rnrs) only, so a pure suite can use it too.
(library (uv-race)
  (export watch-flipper watch-change)
  (import (rnrs))

  (define race-wait-cap 100000000)

  ;; watch-change : (-> object) object object -> (or 'flipping 'not-flipping)
  ;; Whether READ was seen to answer CUT and then WHOLE again within
  ;; race-wait-cap steps.
  (define (watch-change read cut whole)
    (let wait ((k 0) (seen-cut #f))
      (cond ((= k race-wait-cap) 'not-flipping)
            ((eq? (read) cut) (wait (+ k 1) #t))
            ((and seen-cut (eq? (read) whole)) 'flipping)
            (else (wait (+ k 1) seen-cut)))))

  ;; watch-flipper : pair object object -> (or 'flipping 'not-flipping)
  ;; Whether P's cdr was seen to be CUT and then WHOLE again within
  ;; race-wait-cap steps.
  (define (watch-flipper p cut whole)
    (watch-change (lambda () (cdr p)) cut whole)))
