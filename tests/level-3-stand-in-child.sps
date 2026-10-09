#!r6rs
;;; Stand-in child for tests/test-level-3.sps, which runs it through
;;; tests/uv-level-3.sls's level-3-run the way the real children run. It
;;; tests the runner, not the binding, so it imports none of it. Its one
;;; argument picks what it does:
;;;
;;;   flood    writes 1 MiB to stderr, more than a pipe holds, then prints
;;;            its datum: a runner that reads stderr only once stdout is
;;;            ready leaves it blocked on the full pipe until the deadline
;;;   stall    prints half a datum, in two pieces 100 ms apart, and a line
;;;            on stderr, then sleeps 60 s: a runner that reads stdout to
;;;            its end once anything is there waits out the sleep, past any
;;;            deadline
;;;   garbage  prints a non-datum, closes its stdout, and 500 ms later
;;;            prints a line on stderr and exits: a runner that stops at
;;;            stdout's end loses the line
(import (rnrs)
        (only (chezscheme) sleep make-time foreign-procedure
              load-shared-object))

(define out (current-output-port))
(define err (current-error-port))

(define (say port text)
  (put-string port text)
  (flush-output-port port))

(define (pause ms)
  (sleep (make-time 'time-duration (* (mod ms 1000) 1000000) (div ms 1000))))

;; close-stdout! : -> void
;; Closes file descriptor 1. Closing Chez's port does not: the runner saw
;; stdout end only when the child exited.
(define (close-stdout!)
  (guard (e (#t (load-shared-object "libc.dylib")))
    (load-shared-object "libc.so.6"))
  ((foreign-procedure "close" (int) int) 1))

(case (string->symbol (cadr (command-line)))
  ((flood)
   (let ((line (string-append (make-string 1023 #\e) "\n")))
     (do ((i 0 (+ i 1))) ((= i 1024))
       (put-string err line))
     (flush-output-port err))
   (say out "((stderr-bytes . 1048576))\n"))
  ((stall)
   (say err "stall child: stalling\n")
   (say out "((level . 3)")
   (pause 100)
   (say out " (objects")
   (pause 60000))
  ((garbage)
   (say out "garbage\n")
   (close-stdout!)
   (pause 500)
   (say err "garbage child: no datum\n")))
