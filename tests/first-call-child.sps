#!r6rs
;;; Child program for tests/test-first-call.sps: a verb of (libuv) as the
;;; first call into libuv in a process. Importing (libuv) loads the shim but
;;; checks no version and reads no constant: ensure-native-loaded! does
;;; both, once per process. A suite's process has made other calls long
;;; before, which is why this runs in a process of its own.
;;;
;;; Its one argument is a token. A token from first-call-verbs in
;;; tests/test-first-call.sps calls a verb that takes no loop, handle or
;;; request, and the child prints whether the native library was loaded
;;; before and after, and a sentinel for what the call answered. `records`
;;; calls every verb that takes one of those with a symbol in its place and
;;; prints what each raised, and whether anything loaded meanwhile.
;;;
;;; It prints one datum, an alist. A raise becomes its entry's value,
;;; written with describe, so a regressed build still prints a datum that
;;; reads back.
(import (rnrs)
        (libuv)
        (only (libuv private native) native-initialized?)
        (only (uv-describe) describe))

(define token
  (let ((args (command-line)))
    (if (and (pair? args) (pair? (cdr args))) (cadr args) "")))

(define (loaded) (if (native-initialized?) 'loaded 'not-loaded))

(define (outcome thunk)
  (guard (e ((uv-errno-error? e) (list 'errno (uv-errno-error-errno e)))
            ((uv-invalid-argument? e)
             (list 'invalid-argument (uv-invalid-argument-reason e)))
            (#t (list 'raised (describe e))))
    (thunk)))

;; Above every pid limit: Linux's is at most 2^22, macOS's 99999.
(define missing-pid 99999999)

;; The loop make-uv-loop made, closed once the report is taken.
(define made-loop #f)

;; Each token's call, answering a sentinel only a working call gives.
(define calls
  (list (cons "kill0" (lambda () (uv-kill! missing-pid 0) 'sent))
        (cons "killterm" (lambda () (uv-kill! missing-pid 'sigterm) 'sent))
        (cons "loop" (lambda ()
                       (let ((l (make-uv-loop)))
                         (set! made-loop l)
                         (if (uv-loop? l) 'a-loop 'not-a-loop))))
        (cons "withloop" (lambda ()
                           (call-with-uv-loop
                            (lambda (l) (if (uv-loop? l) 'body-ran 'not-a-loop)))))
        (cons "getpid" (lambda ()
                         (let ((p (uv-os-getpid)))
                           (if (and (integer? p) (exact? p) (positive? p))
                               'a-pid
                               'not-a-pid))))
        (cons "version" (lambda () (if (string? (uv-version)) 'a-string 'not-a-string)))
        (cons "compatible" (lambda ()
                             (if (eq? (uv-version-compatible?) #t)
                                 'compatible
                                 'not-compatible)))))

(define cb (lambda args #f))

;; shape : a verb and its arguments, as (verb . thunk). The thunk answers
;; 'returned if the verb does, so no record is ever printed.
(define-syntax shape
  (syntax-rules ()
    ((_ verb arg ...) (cons 'verb (lambda () (verb arg ...) 'returned)))))

;; Every verb that takes a loop, handle or request and loads nothing
;; itself, each arity once, with a symbol for the record. Any argument that
;; would read a constant is given too: a run mode, a signal, hints, flags,
;; an address.
(define unloading-shapes
  (list (shape uv-run 'x 'once)
        (shape uv-stop! 'x)
        (shape uv-loop-alive? 'x)
        (shape uv-now 'x)
        (shape uv-update-time! 'x)
        (shape uv-loop-close! 'x)
        (shape uv-loop-teardown! 'x)
        (shape uv-close! 'x)
        (shape uv-send-buffer-size 'x)
        (shape uv-send-buffer-size! 'x 4096)
        (shape uv-recv-buffer-size 'x)
        (shape uv-recv-buffer-size! 'x 4096)
        (shape uv-timer-start! 'x cb 1 0)
        (shape uv-timer-stop! 'x)
        (shape uv-timer-again! 'x)
        (shape uv-timer-repeat 'x)
        (shape uv-timer-set-repeat! 'x 1)
        (shape uv-tcp-bind! 'x "127.0.0.1" 0)
        (shape uv-tcp-bind! 'x "::1" 0 '(ipv6-only))
        (shape uv-tcp-getsockname-port 'x)
        (shape uv-tcp-sockname-address 'x)
        (shape uv-tcp-peer-address 'x)
        (shape uv-listen! 'x 16 cb)
        (shape uv-accept! 'x)
        (shape uv-tcp-connect! 'x "127.0.0.1" 1 cb)
        (shape uv-tcp-nodelay! 'x #t)
        (shape uv-tcp-keepalive! 'x #t 10)
        (shape uv-tcp-keepalive! 'x #f)
        (shape uv-write! 'x (u8-list->bytevector '(1 2)) cb)
        (shape uv-write! 'x (u8-list->bytevector '(1 2)) 0 1 cb)
        (shape uv-write*! 'x (list (u8-list->bytevector '(1))) cb)
        (shape uv-shutdown! 'x cb)
        (shape uv-read-start! 'x cb cb cb)
        (shape uv-read-start! 'x cb cb cb 4096)
        (shape uv-read-stop! 'x)
        (shape uv-stream-write-queue-size 'x)
        (shape uv-getaddrinfo! 'x "localhost" "80" cb)
        (shape uv-getaddrinfo! 'x "localhost" "80" '((family . inet)) cb)
        (shape uv-getnameinfo! 'x "127.0.0.1" 80 cb)
        (shape uv-getnameinfo! 'x "127.0.0.1" 80 '(namereqd) cb)
        (shape uv-cancel! 'x)
        (shape uv-process-kill! 'x 'sigterm)
        (shape uv-process-pid 'x)
        (shape uv-signal-start! 'x 'sigint cb)
        (shape uv-signal-start-oneshot! 'x 'sigint cb)
        (shape uv-signal-stop! 'x)
        (shape uv-async-send! 'x)))

;; The verbs that take a loop and load before they check it. They run last,
;; since each leaves the library loaded.
(define loading-shapes
  (list (shape make-uv-timer 'x)
        (shape make-uv-tcp 'x)
        (shape make-uv-pipe 'x)
        (shape make-uv-signal 'x)
        (shape make-uv-async 'x cb)
        (shape uv-spawn! 'x "/bin/sh" '("sh") cb)))

;; run-shapes : (list-of (symbol . thunk)) -> (list-of list)
;; Each shape's verb, what it raised, and whether the library was loaded
;; once it had, in the order listed.
(define (run-shapes shapes)
  (let next ((ss shapes) (acc '()))
    (if (null? ss)
        (reverse acc)
        (let* ((o (outcome (cdar ss)))
               (l (loaded)))
          (next (cdr ss) (cons (list (caar ss) o l) acc))))))

(define report
  (cond
    ((string=? token "records")
     (let* ((before (loaded))
            (unloading (run-shapes unloading-shapes))
            (loading (run-shapes loading-shapes)))
       (list (cons 'before before) (cons 'unloading unloading)
             (cons 'loading loading))))
    ((assoc token calls)
     => (lambda (call)
          (let* ((before (loaded))
                 (value (outcome (cdr call)))
                 (after (loaded)))
            (list (cons 'before before) (cons 'value value) (cons 'after after)))))
    (else (list (cons 'unknown-token token)))))

(when made-loop (uv-loop-close! made-loop))

(write report)
(newline)
