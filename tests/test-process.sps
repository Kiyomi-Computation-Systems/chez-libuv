#!r6rs
;;; SRFI-64 suite for (libuv process) -- uv-spawn!'s core: exit-code
;;; delivery, the argv/env/cwd block layout, env inheritance, the two
;;; spawn-failure classes, on-exit = #f, and the full validation walk
;;; (design spec v0.3 §9.2). The stdio vocabulary's remaining scenarios
;;; (echo, duplex, extra fd, inherit-fd, inherit-stream, pipe reuse) and
;;; the kill/pid/detached rows land in Tasks 9-10.
;;;
;;; HARNESS RULES (design spec v0.3 §9.1): every wait whose predicate
;;; depends on a callback is run-until/ticking with an iteration cap;
;;; child programs are /bin/sh only, by absolute path; EOF-vs-exit
;;; ordering is never asserted (both orders are legal, vendor fact V5), so
;;; every scenario that involves both waits for each independently;
;;; sentinels are symbols, never #f or 0; every callback (collect)s.
;;;
;;; NOT pure; never add to PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv pipe)
        (libuv process)
        (libuv stream)
        (libuv private handles)
        (libuv private conditions)
        (only (libuv private native) live-counts)
        (uv-testing)
        (only (chezscheme) collect putenv))

(define runner (test-runner-simple))
(test-runner-current runner)

(test-begin "process")

(define (live-count kind) (cdr (assq kind (live-counts))))
(define registry-count-at-start (registry-count))

;; Every scenario runs on a fresh loop torn down at its end, so counter
;; rows localize failures: a leak inside one scenario cannot be paid for
;; by the next scenario's teardown.
(define (with-loop body)
  (let ((loop (make-uv-loop)))
    (body loop)
    (uv-loop-teardown! loop)))

;; --- exit-code delivery (design spec v0.3 §9.2) --------------------------
(with-loop
 (lambda (loop)
   (define result 'not-yet)   ;; sentinel symbol, never #f
   (define proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 7")
                (lambda (status sig)
                  (collect)
                  (set! result (list status sig)))))
   (test-assert "uv-spawn! answers an open process handle"
     (and (uv-process? proc) (uv-handle-open? proc)))
   (test-equal "process counter counts the spawn" 1 (live-count 'process))
   (test-equal "the spawn left no options block behind"
     0 (live-count 'spawn-options))
   (test-equal "exit callback delivers (7 #f)"
     'satisfied (run-until/ticking loop (lambda () (pair? result)) 2048))
   (test-equal "normal exit: status is the code, term-signal #f"
     '(7 #f) result)
   (test-assert "the record's exited? flag is set by the dispatcher"
     (process-exited? proc))
   (test-assert "exit does not close: the handle is still open (§6)"
     (uv-handle-open? proc))
   (uv-close! proc)
   (test-equal "close drains"
     'satisfied (run-until loop
                           (lambda () (eq? 'closed (uv-handle-state proc)))
                           64))
   (test-equal "process counter back to zero" 0 (live-count 'process))))

;; --- argv/env/cwd combined: THE mutation target for every §5.3 offset row
(with-loop
 (lambda (loop)
   (define out (make-byte-collector))
   (define done 'not-yet)
   (define eof 'not-yet)
   (define stdout-pipe (make-uv-pipe loop))
   (define proc
     (uv-spawn! loop "/bin/sh"
                '("sh" "-c" "printf '%s|%s|%s|%s' \"$0\" \"$1\" \"$FOO\" \"$(pwd)\"" "argv-zero" "argv-one")
                (list (cons 'env '("FOO=from-env" "PATH=/usr/bin:/bin"))
                      (cons 'cwd "/")
                      (cons 'stdio (list 'ignore
                                         (list 'pipe stdout-pipe 'from-child))))
                (lambda (status sig) (collect) (set! done (list status sig)))))
   (test-assert "a (pipe ...) spec marks its pipe connected"
     (pipe-connected? stdout-pipe))
   (uv-read-start! stdout-pipe
                   (lambda (bv start end) (collect) (collect-span! out bv start end))
                   (lambda () (collect) (set! eof 'eof))
                   (lambda (err) (collect) (set! eof (list 'error err))))
   (test-equal "child exited cleanly"
     'satisfied (run-until/ticking loop (lambda () (pair? done)) 4096))
   (test-equal "EOF and exit both observed -- independently, either order"
     'satisfied (run-until/ticking loop (lambda () (eq? eof 'eof)) 4096))
   (test-equal "argv[0], argv[1], env, and cwd all arrived as written"
     "argv-zero|argv-one|from-env|/"
     (utf8->string (collector-bytes out)))
   (test-equal "explicit env replaces the parent's rather than extending it"
     '(0 #f) done)
   (uv-close! proc)
   (uv-close! stdout-pipe)
   (test-equal "both handles finish closing"
     'satisfied
     (run-until loop (lambda () (and (eq? 'closed (uv-handle-state proc))
                                     (eq? 'closed (uv-handle-state stdout-pipe))))
                128))))

;; --- env inheritance (no env key => parent env crosses) ------------------
(with-loop
 (lambda (loop)
   (define ignored (putenv "CHEZ_LIBUV_TEST_INHERIT" "inherited-value"))
   (define out (make-byte-collector))
   (define done 'not-yet)
   (define eof 'not-yet)
   (define p (make-uv-pipe loop))
   (define proc
     (uv-spawn! loop "/bin/sh"
                '("sh" "-c" "printf '%s' \"$CHEZ_LIBUV_TEST_INHERIT\"")
                (list (cons 'stdio (list 'ignore (list 'pipe p 'from-child))))
                (lambda (s g) (collect) (set! done 'exited))))
   (uv-read-start! p (lambda (bv s e) (collect) (collect-span! out bv s e))
                     (lambda () (collect) (set! eof 'eof))
                     (lambda (err) (collect) (set! eof 'error)))
   (test-equal "child exited"
     'satisfied (run-until/ticking loop (lambda () (eq? done 'exited)) 4096))
   (test-equal "stdout reached EOF"
     'satisfied (run-until/ticking loop (lambda () (eq? eof 'eof)) 4096))
   (test-equal "omitted env inherits the parent's"
     "inherited-value" (utf8->string (collector-bytes out)))
   ;; Deliberately NOT closed here: with-loop's teardown sweeps the process
   ;; and the pipe, and the suite-final counter rows are the assertion that
   ;; it did (design spec v0.3 §6).
   #f))

;; --- explicitly EMPTY env: the child inherits NOTHING (§4.2) ------------
(with-loop
 (lambda (loop)
   (define ignored (putenv "CHEZ_LIBUV_TEST_EMPTY" "should-not-cross"))
   (define out (make-byte-collector))
   (define done 'not-yet)
   (define eof 'not-yet)
   (define p (make-uv-pipe loop))
   (define proc
     (uv-spawn! loop "/bin/sh"
                '("sh" "-c" "printf 'x%sx' \"$CHEZ_LIBUV_TEST_EMPTY\"")
                (list (cons 'env '())
                      (cons 'stdio (list 'ignore (list 'pipe p 'from-child))))
                (lambda (s g) (collect) (set! done 'exited))))
   (uv-read-start! p (lambda (bv s e) (collect) (collect-span! out bv s e))
                     (lambda () (collect) (set! eof 'eof))
                     (lambda (err) (collect) (set! eof 'error)))
   (run-until/ticking loop (lambda () (and (eq? done 'exited) (eq? eof 'eof))) 8192)
   (test-equal "empty env: the parent's variable did not cross" "xx"
     (utf8->string (collector-bytes out)))
   (uv-close! proc) (uv-close! p)
   (run-until loop (lambda () (and (eq? 'closed (uv-handle-state proc))
                                   (eq? 'closed (uv-handle-state p)))) 128)))

;; --- spawn failure: 'ENOENT, SQ1's production twin (ADR-0015) ------------
;; ADR-0015's failure path is CLASS-DEPENDENT and the class is decided by
;; asking the loop, never by the errno -- so this scenario asserts the two
;; class-INDEPENDENT observables ADR-0015's consequences name (the counters
;; balance once the loop has turned; a handle registered after the failure
;; still exists) plus the always-immediate one (no options block survives).
;;
;; WHY THE DRAIN. The exec-class arm registers and counts its handle before
;; closing it through the normal protocol, because close-dispatch is
;; registry-driven and is the only place a handle pointer is freed
;; (ADR-0015 decision 3). That close is ASYNCHRONOUS, so `process` reads
;; procs-before + 1 between the raise and the next turn of the loop and
;; returns to baseline only after it. Asserting the counter without the
;; drain would be asserting the setup class's timing against whichever
;; class libuv actually took.
(with-loop
 (lambda (loop)
   (define procs-before (live-count 'process))
   (define registry-before (registry-count))
   (define raised
     (guard (e ((uv-errno-error? e) (uv-errno-error-errno e)))
       (uv-spawn! loop "/nonexistent/definitely-missing"
                  '("definitely-missing") #f)
       'no-raise))
   (define procs-at-raise (live-count 'process))
   (test-equal "spawning a missing file raises 'ENOENT synchronously"
     'ENOENT raised)
   (test-equal "no options block leaked on the failure path"
     0 (live-count 'spawn-options))
   (test-assert "the failure took exactly one of ADR-0015's two arms"
     (or (= procs-at-raise procs-before)
         (= procs-at-raise (+ procs-before 1))))
   (test-assert "[informational] ENOENT failure class recorded"
     (begin (display "  [informational] ENOENT cleanup arm: ")
            (display (if (= procs-at-raise procs-before)
                         'setup-class-direct-free
                         'exec-class-close-through-protocol))
            (newline)
            #t))
   (test-equal "the failed spawn's handle is gone once the loop has turned"
     'satisfied (run-until loop
                           (lambda () (= procs-before (live-count 'process)))
                           64))
   (test-equal "no registry entry leaked on the failure path"
     registry-before (registry-count))
   ;; ADR-0015's second observable: the wrong cleanup arm silently splices a
   ;; LATER-registered live handle out of loop->handle_queue. uv_walk (the
   ;; measured instrument, installed as the `walk` dispatcher by
   ;; (libuv process)) is what can see that.
   (let ((late (make-uv-pipe loop)))
     (test-assert "a handle created after the failure is in the loop's queue"
       (handle-in-loop-queue? loop late))
     (uv-close! late)
     (test-equal "the late handle closes normally"
       'satisfied (run-until loop
                             (lambda () (eq? 'closed (uv-handle-state late)))
                             64))
     (test-assert "and is out of the queue once closed"
       (not (handle-in-loop-queue? loop late))))))

;; --- 'EPERM: setuid as non-root (design spec v0.3 §9.2 -- the NORMAL suite)
(with-loop
 (lambda (loop)
   (define raised
     (guard (e ((uv-errno-error? e) (uv-errno-error-errno e)))
       (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 0")
                  (list (cons 'uid 1)) #f)
       'no-raise))
   (test-assert "uid as non-root fails 'EPERM (or 'EACCES per platform) at spawn"
     (memq raised '(EPERM EACCES)))
   (test-equal "the uid failure leaked no options block"
     0 (live-count 'spawn-options))))

;; --- on-exit #f: reaping still happens, lifecycle machinery still runs ---
(with-loop
 (lambda (loop)
   (define proc (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 0") #f))
   (test-equal "loop drains with no user callback (reaped via the dispatcher)"
     'satisfied (run-until/ticking loop
                                   (lambda () (process-exited? proc)) 2048))
   (test-assert "handle still open and closeable after silent reap"
     (uv-handle-open? proc))
   (uv-close! proc)
   (test-equal "the silently-reaped handle closes"
     'satisfied (run-until loop
                           (lambda () (eq? 'closed (uv-handle-state proc)))
                           64))))

;; --- the validation walk: every §4.7 reason symbol this task can drive ---
(with-loop
 (lambda (loop)
   (define (reason-of thunk)
     (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
       (thunk) 'no-raise))
   (define (spawn-with . args) (lambda () (apply uv-spawn! loop args)))
   (define ok-args '("sh" "-c" "exit 0"))
   (test-equal "a non-string file" 'file-not-a-string
     (reason-of (spawn-with 42 ok-args #f)))
   (test-equal "an empty args list" 'args-not-a-string-list
     (reason-of (spawn-with "/bin/sh" '() #f)))
   (test-equal "a non-string inside args" 'args-not-a-string-list
     (reason-of (spawn-with "/bin/sh" '("sh" 42) #f)))
   (test-equal "a NUL inside file" 'embedded-nul
     (reason-of (spawn-with "/bin/\x0;sh" ok-args #f)))
   (test-equal "a NUL inside an args string" 'embedded-nul
     (reason-of (spawn-with "/bin/sh" '("sh\x0;x") #f)))
   (test-equal "an options key outside the closed set" 'option-unknown
     (reason-of (spawn-with "/bin/sh" ok-args '((bogus . 1)) #f)))
   (test-equal "a malformed options alist entry" 'option-unknown
     (reason-of (spawn-with "/bin/sh" ok-args '(not-a-pair) #f)))
   (test-equal "env that is not a list of strings" 'env-not-a-string-list
     (reason-of (spawn-with "/bin/sh" ok-args '((env . "A=b")) #f)))
   (test-equal "a NUL inside an env string" 'embedded-nul
     (reason-of (spawn-with "/bin/sh" ok-args (list (cons 'env '("A=\x0;b"))) #f)))
   (test-equal "a non-string cwd" 'cwd-not-a-string
     (reason-of (spawn-with "/bin/sh" ok-args '((cwd . 7)) #f)))
   (test-equal "a non-boolean detached" 'detached-not-a-boolean
     (reason-of (spawn-with "/bin/sh" ok-args '((detached . 1)) #f)))
   (test-equal "a negative uid" 'uid-out-of-range
     (reason-of (spawn-with "/bin/sh" ok-args '((uid . -1)) #f)))
   (test-equal "a gid at 2^32" 'gid-out-of-range
     (reason-of (spawn-with "/bin/sh" ok-args '((gid . 4294967296)) #f)))
   (test-equal "stdio that is not a list" 'stdio-not-a-list
     (reason-of (spawn-with "/bin/sh" ok-args '((stdio . ignore)) #f)))
   (test-equal "an unknown stdio spec shape" 'stdio-spec-unknown
     (reason-of (spawn-with "/bin/sh" ok-args '((stdio . (bogus))) #f)))
   (test-equal "an unknown (pipe ...) direction" 'stdio-spec-unknown
     (reason-of (spawn-with "/bin/sh" ok-args
                            (list (cons 'stdio
                                        (list (list 'pipe (make-uv-pipe loop)
                                                    'sideways))))
                            #f)))
   (test-equal "an inherit-fd value that is not an fd" 'stdio-fd-not-an-fd
     (reason-of (spawn-with "/bin/sh" ok-args
                            '((stdio . ((inherit-fd . not-a-number)))) #f)))
   (test-equal "an on-exit that is neither procedure nor #f"
     'on-exit-not-a-procedure
     (reason-of (spawn-with "/bin/sh" ok-args 'not-a-proc)))
   ;; pipe-already-used / pipe-wrong-loop rows land in Task 9 (they need a
   ;; consumed pipe / a second loop); signal-unknown lands in Task 10.
   (test-equal "validation raised nothing into the options counter"
     0 (live-count 'spawn-options))
   (test-equal "validation created no process handle"
     0 (live-count 'process))))

(collect)
(test-assert "counters all zero at suite end"
  (for-all (lambda (kv) (zero? (cdr kv))) (live-counts)))
(test-equal "registry back to baseline" registry-count-at-start (registry-count))
(test-end "process")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
