#!chezscheme
;; #95: which shapes leave the thread inactive in Scheme after a caught fault.
;; Each shape faults (strlen on address 8) N times, allocating 1 MB after each
;; fault before any other foreign call. A hang (timeout) is the bug.
;;   flat:    the fault in a __collect_safe call made directly from Scheme
;;   unsafe:  the fault in a plain call, inside a callable that a __collect_safe qsort entered
;;   nested:  the fault in a __collect_safe call, inside that callable
;;   escaped: one escape from a callable first, then the fault in a flat __collect_safe call
;;   none:    nested, but strlen on a valid string (the control)
;; Needs no libuv and no CHEZSCHEMELIBDIRS:
;;   timeout 20 scheme --program .plans/fault-deactivated-probe.sps SHAPE 1000
;; .plans/macos-thread-overflow-log.md records what each shape did.
(import (chezscheme))
(load-shared-object (if (memq (machine-type) '(tarm64osx ta6osx)) "libc.dylib" "libc.so.6"))
(define shape (string->symbol (cadr (command-line))))
(define n (string->number (caddr (command-line))))
(define safe-strlen (foreign-procedure __collect_safe "strlen" (uptr) size_t))
(define plain-strlen (foreign-procedure "strlen" (uptr) size_t))
(define qsort (foreign-procedure __collect_safe "qsort" (uptr size_t size_t uptr) void))
(define buf (foreign-alloc 16))
(define ok (let ((p (foreign-alloc 2))) (foreign-set! 'unsigned-8 p 0 65) (foreign-set! 'unsigned-8 p 1 0) p))
(define (callable proc)
  (let ((co (foreign-callable __collect_safe proc (uptr uptr) int)))
    (lock-object co)
    (foreign-callable-entry-point co)))
(define nested-ep (callable (lambda (a b) (safe-strlen 8) 0)))
(define unsafe-ep (callable (lambda (a b) (plain-strlen 8) 0)))
(define none-ep (callable (lambda (a b) (safe-strlen ok) 0)))
(define esc #f)
(define escape-ep (callable (lambda (a b) (esc 'escaped))))
(when (eq? shape 'escaped) (call/cc (lambda (k) (set! esc k) (qsort buf 2 8 escape-ep))))
(define keep #f)
(let loop ((i 0))
  (when (< i n)
    (guard (e (#t #f))
      (case shape
        ((flat escaped) (safe-strlen 8))
        ((unsafe) (qsort buf 2 8 unsafe-ep))
        ((nested) (qsort buf 2 8 nested-ep))
        ((none) (qsort buf 2 8 none-ep))))
    (set! keep (make-bytevector 1000000))
    (loop (+ i 1))))
(printf "~a: finished ~a\n" shape n)
