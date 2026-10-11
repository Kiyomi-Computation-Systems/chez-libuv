#!r6rs
;;; Child program for tests/test-process.sps: uv-kill! as the first call
;;; into libuv in a process. Importing (libuv) loads the shim but reads no
;;; constants, so a verb that reaches them before the first verb that does
;;; finds none. A suite's process has made other calls long before, which is
;;; why this runs in a process of its own.
;;;
;;; Its one argument names the signal: `zero` sends 0, `sigterm` sends
;;; 'sigterm, to a pid no system hands out. It prints what it saw as one
;;; datum, an alist; a raise becomes its entry's value, so a regressed build
;;; still prints a complete datum.
(import (rnrs)
        (libuv)
        (only (libuv private constants) constants-initialized?)
        (only (uv-describe) describe))

(define signal
  (let ((args (command-line)))
    (if (and (pair? args) (pair? (cdr args)) (equal? (cadr args) "sigterm"))
        'sigterm
        0)))

;; Above every pid limit: Linux's is at most 2^22, macOS's 99999.
(define missing-pid 99999999)

(define initialized-before (constants-initialized?))

(define kill
  (guard (e ((uv-errno-error? e) (list 'errno (uv-errno-error-errno e)))
            ((uv-invalid-argument? e)
             (list 'invalid-argument (uv-invalid-argument-reason e)))
            (#t (list 'raised (describe e))))
    (uv-kill! missing-pid signal)
    'no-raise))

(write (list (cons 'initialized-before initialized-before)
             (cons 'kill kill)))
(newline)
