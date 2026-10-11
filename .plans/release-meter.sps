;;; The release meter: bytes on the Scheme heap per call, the fewest of 64
;;; ((uv-meter)'s fewest-bytes, collections held off), through the public
;;; API only, so one program runs against the previous release and the new
;;; one. Run it from a built tree's root, twice per build:
;;;   CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program .plans/release-meter.sps
;;; The previous release goes in a --no-hardlinks clone at its tag, with
;;; this file copied in. The cons control must read 16, or the meter
;;; itself is off. A verb that answers two values needs call-with-values
;;; around it here. CHANGELOG.md's 0.9.0 entry quotes its figures; to
;;; find which PR moved one, run it at the squash commits around each
;;; candidate.
(import (chezscheme) (libuv) (uv-meter))

(define loop (make-uv-loop))
(define (row name n) (printf "~a: ~a~%" name n))

(define (on-thread thunk)
  (let ((m (make-mutex)) (c (make-condition)) (result #f) (done #f))
    (fork-thread
     (lambda ()
       (let ((r (thunk)))
         (with-mutex m (set! result r) (set! done #t) (condition-broadcast c)))))
    (with-mutex m (let wait () (unless done (condition-wait c m) (wait))))
    result))

(row "cons control" (fewest-bytes (lambda () (cons 1 2))))
(row "uv-run 'nowait, empty loop" (fewest-bytes (lambda () (uv-run loop 'nowait))))
(row "uv-run 'default, empty loop" (fewest-bytes (lambda () (uv-run loop 'default))))
(row "uv-loop-alive?" (fewest-bytes (lambda () (uv-loop-alive? loop))))
(row "uv-now" (fewest-bytes (lambda () (uv-now loop))))
(row "uv-update-time!" (fewest-bytes (lambda () (uv-update-time! loop))))

(define t (make-uv-timer loop))
(define fired 0)
(define (on-fire h) (set! fired (+ fired 1)))
(row "uv-timer-start! + uv-timer-stop!"
     (fewest-bytes (lambda () (uv-timer-start! t on-fire 1000 0) (uv-timer-stop! t))))
(row "a 0 ms timer started and run to its callback"
     (fewest-bytes
      (lambda ()
        (let ((f fired))
          (uv-timer-start! t on-fire 0 0)
          (let spin () (when (= f fired) (uv-run loop 'once) (spin)))))))
(row "make-uv-timer, uv-close! and a run to the close callback"
     (fewest-bytes
      (lambda ()
        (let ((h (make-uv-timer loop)) (done #f))
          (uv-close! h (lambda () (set! done #t)))
          (let spin () (unless done (uv-run loop 'once) (spin)))))))
(row "call-with-uv-loop, body returns"
     (fewest-bytes (lambda () (call-with-uv-loop (lambda (l) #t)))))
(row "call-with-uv-loop, body raises a symbol to an outer guard"
     (fewest-bytes (lambda () (guard (e (#t e)) (call-with-uv-loop (lambda (l) (raise 'x)))))))
(row "uv-update-time! refused on another thread"
     (on-thread
      (lambda ()
        (fewest-bytes (lambda () (guard (e ((uv-wrong-thread? e) e)) (uv-update-time! loop)))))))
(row "uv-timer-start! refused on another thread"
     (on-thread
      (lambda ()
        (fewest-bytes
         (lambda () (guard (e ((uv-wrong-thread? e) e)) (uv-timer-start! t on-fire 1000 0)))))))
(uv-loop-teardown! loop)
