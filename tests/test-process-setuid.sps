#!r6rs
;;; ROOT LANE: the setuid/setgid POSITIVE tests. Excluded from the default
;;; TESTS list; run only via `sudo make test-root`. Refuses to run as
;;; non-root with a loud exit 1 — being skipped silently is how a lane
;;; dies. The 'EPERM NEGATIVE test lives in tests/test-process.sps, in the
;;; normal suite.
;;;
;;; The unprivileged target identity is looked up AT RUNTIME (`id -u
;;; nobody`) — never a transcribed uid, which differs across platforms and
;;; would be wrong silently. All child output crosses a from-child pipe;
;;; the runner is uv-spawn! itself, so the lane exercises the module under
;;; test even in its own plumbing.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv pipe)
        (libuv process)
        (libuv stream)
        (uv-testing)
        (only (chezscheme) collect))

(define runner (test-runner-simple))
(test-runner-current runner)

;; (run-capture loop file args options) → (exit-status . output-string)
;; Blocks via capped ticking until both exit and EOF arrive.
(define (run-capture loop file args extra-options)
  (let* ((out-pipe (make-uv-pipe loop))
         (out (make-byte-collector))
         (exit-status 'not-yet)
         (eof 'not-yet)
         (options (cons (cons 'stdio (list 'ignore
                                           (list 'pipe out-pipe 'from-child)))
                        extra-options))
         (proc (uv-spawn! loop file args options
                          (lambda (s g) (collect) (set! exit-status s)))))
    (uv-read-start! out-pipe
                    (lambda (bv s e) (collect) (collect-span! out bv s e))
                    (lambda () (set! eof 'eof))
                    (lambda (err) (set! eof 'error)))
    (run-until/ticking loop
                       (lambda () (and (number? exit-status) (eq? eof 'eof)))
                       8192)
    (uv-close! proc)
    (uv-close! out-pipe)
    (run-until loop (lambda () (and (eq? 'closed (uv-handle-state proc))
                                    (eq? 'closed (uv-handle-state out-pipe))))
               128)
    (cons exit-status (utf8->string (collector-bytes out)))))

(define (trim s)  ;; strip the trailing newline id(1) prints
  (let loop ((end (string-length s)))
    (if (and (positive? end)
             (memv (string-ref s (- end 1)) '(#\newline #\return)))
        (loop (- end 1))
        (substring s 0 end))))

(define gate-loop (make-uv-loop))

;; --- the root gate -------------------------------------------------------
(define my-uid (trim (cdr (run-capture gate-loop "/usr/bin/id" '("id" "-u") '()))))
(unless (string=? "0" my-uid)
  (display "test-process-setuid: refusing to run: euid is ")
  (display my-uid)
  (display " — run via `sudo make test-root`\n")
  (exit 1))

;; --- the unprivileged target, looked up at runtime -----------------------
(define nobody-uid
  (trim (cdr (run-capture gate-loop "/usr/bin/id" '("id" "-u" "nobody") '()))))
(define nobody-gid
  (trim (cdr (run-capture gate-loop "/usr/bin/id" '("id" "-g" "nobody") '()))))
(uv-loop-teardown! gate-loop)

(test-begin "process-setuid")

(let ((loop (make-uv-loop)))
  (let ((r (run-capture loop "/usr/bin/id" '("id" "-u")
                        (list (cons 'uid (string->number nobody-uid))))))
    (test-equal "child ran as the requested uid" (cons 0 nobody-uid)
      (cons (car r) (trim (cdr r)))))
  (let ((r (run-capture loop "/usr/bin/id" '("id" "-g")
                        (list (cons 'uid (string->number nobody-uid))
                              (cons 'gid (string->number nobody-gid))))))
    (test-equal "child ran as the requested gid" (cons 0 nobody-gid)
      (cons (car r) (trim (cdr r)))))
  (uv-loop-teardown! loop))

(test-end "process-setuid")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
