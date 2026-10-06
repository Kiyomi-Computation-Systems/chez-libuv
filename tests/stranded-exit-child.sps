#!r6rs
;;; Child program for tests/test-loop.sps: a call-with-uv-loop body left from
;;; inside a close callback while a second close waits in the same batch of
;;; libuv's. libuv walks that batch from a list it has already detached, so
;;; the second close never finishes and the exit's teardown cannot close the
;;; loop: the loop and the stranded handle stay allocated for good. That is
;;; why this runs in a process of its own, outside the suites the memory gate
;;; checks. It prints what it saw as one datum, an alist, for the suite to
;;; check row by row.
;;;
;;; Every scenario's raise becomes its entry's value, so a regressed build
;;; still prints a complete datum.
(import (rnrs)
        (libuv)
        (only (libuv private handles) loop-running?)
        (only (chezscheme) make-engine))

(define (evidence e)
  (cond ((uv-handle-closed? e) (list 'refused (uv-handle-closed-kind e)))
        ((uv-errno-error? e) (list 'errno (uv-errno-error-errno e) (condition-who e)))
        ((message-condition? e) (list 'raised (condition-message e)))
        (else (list 'raised e))))

(define (marked loop) (if (loop-running? loop) 'running 'not-running))

(define (spin n) (let lp ((i 0)) (when (< i n) (lp (+ i 1)))))

;; strand! : uv-loop procedure -> unspecified
;; Closes two timers so that ON-FIRST-CLOSE runs while the other's close
;; still waits in libuv's batch: libuv runs closes newest first.
(define (strand! l on-first-close)
  (let ((a (make-uv-timer l)) (b (make-uv-timer l)))
    (uv-close! b (lambda () #f))
    (uv-close! a on-first-close)
    (uv-run l 'default)))

;; --- an escape, then a return into the body -----------------------------------
;; The callback keeps a continuation of its own. Re-entered, it escapes again
;; through `done` at once, so a build that lets the return in never hands
;; control back to libuv's abandoned frame.
(define escape-loop #f)
(define escape-value 'never-escaped)
(define back-in #f)
(define coming-back #f)

(define reentry
  (call/cc
   (lambda (done)
     (guard (e (#t (done (evidence e))))
       (set! escape-value
             (call/cc
              (lambda (escape)
                (call-with-uv-loop
                 (lambda (l)
                   (set! escape-loop l)
                   (strand! l (lambda ()
                                (call/cc (lambda (k) (set! back-in k)))
                                (if coming-back
                                    (done 'got-back-into-the-body)
                                    (escape 'escaped))))
                   'body-returned)))))
       (if back-in
           (begin (set! coming-back #t) (back-in #f) 'return-came-back)
           'no-continuation-kept)))))

;; --- an engine whose fuel runs out in the same place ---------------------
;; One loop first, outside the engine, so the library's set-up does not spend
;; the slice's fuel.
(call-with-uv-loop (lambda (l) (uv-run l 'nowait)))

(define engine-loop #f)
(define in-close #f)

(define first-slice
  (guard (e (#t (evidence e)))
    ((make-engine
      (lambda ()
        (call-with-uv-loop
         (lambda (l)
           (set! engine-loop l)
           (strand! l (lambda () (set! in-close #t) (spin 2000000) (set! in-close #f)))
           'body-returned))))
     20000
     (lambda (ticks value) (list 'finished value))
     (lambda (resume) (list 'expired resume)))))

(define resumed
  (if (and (pair? first-slice) (eq? (car first-slice) 'expired))
      (guard (e (#t (evidence e)))
        ((cadr first-slice) 100000000
         (lambda (ticks value) (list 'finished value))
         (lambda (resume) 'expired-again)))
      'never-expired))

(write (list (cons 'escape escape-value)
             (cons 'escape-marked (if escape-loop (marked escape-loop) 'no-loop))
             (cons 'reentry reentry)
             (cons 'engine (if (and (pair? first-slice) (eq? (car first-slice) 'expired))
                               'expired
                               first-slice))
             (cons 'engine-in-close in-close)
             (cons 'engine-marked (if engine-loop (marked engine-loop) 'no-loop))
             (cons 'engine-resume resumed)))
(newline)
