#!r6rs
;;; Probe for #128: does a collection between a child's exit and child-run's
;;; reap take the child's status? Runs the stand-in's quiet-exit and flood
;;; children N times each with collections made frequent, and counts each
;;; answer's shape. Run as make test runs a suite:
;;;   CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs CHEZ_LIBUV_TEST_CHEZ=$CHEZ \
;;;     $CHEZ --program .plans/child-reap-probe.sps [trip-bytes] [runs]
(import (rnrs) (uv-child) (only (chezscheme) getenv collect-trip-bytes))

(define chez (getenv "CHEZ_LIBUV_TEST_CHEZ"))
(define args (cdr (command-line)))
(define trip (if (pair? args) (string->number (car args)) #f))
(define runs (if (and (pair? args) (pair? (cdr args))) (string->number (cadr args)) 20))

;; shape : report -> datum, the report with its strings dropped
(define (shape report)
  (cond ((and (pair? report) (memq (car report) '(unreadable bad-exit killed-at-cap)))
         (list (car report) (list-ref report 3)))
        ((and (pair? report) (eq? (car report) 'run-failed)) (list 'run-failed (caddr report)))
        (else 'datum)))

(define (tally mode)
  (let loop ((i 0) (seen '()))
    (if (= i runs)
        seen
        (let ((k (shape (child-run chez '() "tests/level-3-stand-in-child.sps" (list mode) 20))))
          (loop (+ i 1)
                (let ((n (cond ((assoc k seen) => cdr) (else 0))))
                  (cons (cons k (+ n 1))
                        (remp (lambda (e) (equal? (car e) k)) seen))))))))

(when trip (collect-trip-bytes trip))
(for-each (lambda (mode)
            (write (list mode 'trip (collect-trip-bytes) (tally mode)))
            (newline))
          '(quiet-exit flood))
