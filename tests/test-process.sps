#!r6rs
;;; SRFI-64 suite for (libuv process) -- uv-spawn!'s core: exit-code
;;; delivery, the argv/env/cwd block layout, env inheritance, the two
;;; spawn-failure classes, on-exit = #f, and the full validation walk
;;; (design spec v0.3 §9.2), PLUS (Task 9) the full stdio vocabulary: echo,
;;; duplex, extra fd, inherit-fd, inherit-stream, and pipe reuse/wrong-loop.
;;; The kill/pid/detached rows land in Task 10.
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
        (libuv tcp)
        (libuv private handles)
        (libuv private conditions)
        (only (libuv private native) live-counts)
        (uv-testing)
        (only (chezscheme) collect putenv mkdir
              get-string-all open-file-output-port port-file-descriptor))

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
   ;; Duplicates are refused, not first-wins: assq-shaped validation would
   ;; validate only the first entry, so '((cwd . "/") (cwd . 7)) used to
   ;; pass with the malformed second entry silently ignored -- invisible to
   ;; everything but this row.
   (test-equal "a duplicated key whose second entry is malformed" 'option-duplicate
     (reason-of (spawn-with "/bin/sh" ok-args '((cwd . "/") (cwd . 7)) #f)))
   (test-equal "a duplicated key is refused even when both entries validate"
     'option-duplicate
     (reason-of (spawn-with "/bin/sh" ok-args
                            '((detached . #t) (detached . #t)) #f)))
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
   ;; The container field is a C int, so 2^31 cannot be an fd. Unbounded,
   ;; this escaped as a raw Chez condition from c-int-set! mid-build (the
   ;; guard freed the block -- no leak, but not the uniform
   ;; &uv-invalid-argument either). reason-of's guard passes a raw
   ;; condition through, so the pre-fix behavior fails this row by shape,
   ;; not just by name.
   (test-equal "an inherit-fd value too wide for the C int container field"
     'stdio-fd-not-an-fd
     (reason-of (spawn-with "/bin/sh" ok-args
                            '((stdio . ((inherit-fd . 2147483648)))) #f)))
   (test-equal "an on-exit that is neither procedure nor #f"
     'on-exit-not-a-procedure
     (reason-of (spawn-with "/bin/sh" ok-args 'not-a-proc)))
   ;; pipe-already-used / pipe-wrong-loop rows land in Task 9 (they need a
   ;; consumed pipe / a second loop); signal-unknown lands in Task 10.
   (test-equal "validation raised nothing into the options counter"
     0 (live-count 'spawn-options))
   (test-equal "validation created no process handle"
     0 (live-count 'process))))

;; --- full echo loop (§9.2; SQ3's production twin) ------------------------
(with-loop
 (lambda (loop)
   (define stdin-pipe  (make-uv-pipe loop))
   (define stdout-pipe (make-uv-pipe loop))
   (define out (make-byte-collector))
   (define exit-result 'not-yet)
   (define eof 'not-yet)
   (define payload (seeded-bytes 4096 42))
   (define proc
     (uv-spawn! loop "/bin/cat" '("cat")
                (list (cons 'stdio (list (list 'pipe stdin-pipe 'to-child)
                                         (list 'pipe stdout-pipe 'from-child))))
                (lambda (s g) (collect) (set! exit-result (list s g)))))
   (test-assert "both pipes are connected after the spawn"
     (and (pipe-connected? stdin-pipe) (pipe-connected? stdout-pipe)))
   (uv-read-start! stdout-pipe
                   (lambda (bv s e) (collect) (collect-span! out bv s e))
                   (lambda () (collect) (set! eof 'eof))
                   (lambda (err) (collect) (set! eof (list 'error err))))
   (uv-write! stdin-pipe payload
              (lambda (err) (collect)
                (when (not err)
                  (uv-shutdown! stdin-pipe (lambda (err2) (collect))))))
   ;; EOF and exit are waited for INDEPENDENTLY -- both orders are legal
   ;; (V5, SQ3's measured evidence). Neither wait implies the other.
   (test-equal "all bytes echo back and EOF arrives"
     'satisfied (run-until/ticking
                 loop (lambda () (and (= 4096 (collector-count out))
                                      (eq? eof 'eof))) 8192))
   (test-equal "the child exits (0 #f) after its stdin closed"
     'satisfied (run-until/ticking loop (lambda () (pair? exit-result)) 8192))
   (test-equal "clean exit" '(0 #f) exit-result)
   (test-assert "payload survived byte-for-byte"
     (bytevector=? payload (collector-bytes out)))
   ;; pipe-already-used: a consumed pipe refuses a second spawn (§4.3).
   ;; Sentinel + test-equal, not test-assert over a guard defaulting to #f
   ;; (AGENTS.md's named #f trap; Task 8's review caught the same shape in
   ;; the 'ENOENT/'EPERM rows and this suite has followed the fix since).
   (test-equal "a connected pipe refuses reuse" 'pipe-already-used
     (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
       (uv-spawn! loop "/bin/cat" '("cat")
                  (list (cons 'stdio (list (list 'pipe stdin-pipe 'to-child))))
                  #f)
       'no-raise))
   (uv-close! proc)
   (uv-close! stdin-pipe)
   (uv-close! stdout-pipe)
   (test-equal "the process and both pipes finish closing"
     'satisfied (run-until loop
                           (lambda () (and (eq? 'closed (uv-handle-state proc))
                                           (eq? 'closed (uv-handle-state stdin-pipe))
                                           (eq? 'closed (uv-handle-state stdout-pipe))))
                           128))))
;; the suite-end counter rows discharge Task 5's forward obligation: the
;; pipes' read buffer freed via the STREAM arm of the close dispatcher.

;; --- stdio-setup spawn failure: the second ADR-0015 failure trigger -------
;; (ADR-0015; post-spike addition) (inherit-stream <unconnected pipe>) makes
;; uv_spawn fail while initialising stdio, BEFORE any fork/exec: process.c's
;; UV_INHERIT_STREAM arm reads a never-opened stream's fd, gets -1, and
;; returns UV_EINVAL out through uv_spawn's `error:` label. Task 8's
;; mutation probe 6 shipped the direct-free arm UNTESTED
;; (.plans/process-stage-5-mutation-log.md); this scenario is its forward
;; obligation, and the probe is re-run against it (see the mutation log).
;;
;; WHICH CLEANUP ARM THIS TRIGGER TAKES IS A LIBUV-VERSION QUESTION, NOT A
;; PLATFORM ONE, and this suite must not hardcode either answer:
;;
;;   * libuv >= 1.52.0 unlinks the handle on the way out -- upstream commit
;;     3e9ae1bc "unix: remove handle from queue on uv_spawn() error"
;;     (#4980, 2025-12-26) added `uv__queue_remove(&process->handle_queue)`
;;     as the error: label's first statement. The handle is gone from
;;     loop->handle_queue, so this binding takes the DIRECT-FREE arm and
;;     nothing is ever counted.
;;   * libuv < 1.52.0 has no such statement, so the handle uv__handle_init
;;     put into loop->handle_queue at the top of uv_spawn is STILL LINKED
;;     when EINVAL comes back. Closing through the protocol is then the
;;     correct cleanup, so this binding takes the EXEC-CLASS arm: the handle
;;     is registered and counted, and `process` returns to baseline only
;;     after the loop turns (ADR-0015 decision 3 -- the free is async).
;;     Measured, not inferred: CI's ubuntu-noble leg links apt's libuv
;;     1.48.0 and takes this arm; its vendored leg (1.52.1) and macOS's
;;     homebrew libuv (1.52.1) take the other.
;;
;; That divergence is exactly what ADR-0015 decision 2 exists to absorb --
;; the class is decided BY ASKING THE LOOP, never by the errno and never by
;; a version table -- so this scenario asserts the same class-INDEPENDENT
;; observables the 'ENOENT scenario does (counters balance once the loop has
;; turned; no registry entry survives; a handle registered after the failure
;; is still properly linked) and records which arm ran informationally.
;; Asserting one arm's timing would be asserting a build-time fact about the
;; libuv underneath, which is not a property of this binding.
(with-loop
 (lambda (loop)
   (define unconnected (make-uv-pipe loop))
   (define procs-before (live-count 'process))
   (define registry-before (registry-count))
   (define raised
     (guard (e ((uv-errno-error? e) (uv-errno-error-errno e)))
       (uv-spawn! loop "/bin/cat" '("cat")
                  (list (cons 'stdio (list (cons 'inherit-stream unconnected))))
                  #f)
       'no-raise))
   (define procs-at-raise (live-count 'process))
   (test-equal "inherit-stream of an unconnected pipe fails at spawn with 'EINVAL"
     'EINVAL raised)
   (test-equal "no options block leaked" 0 (live-count 'spawn-options))
   (test-assert "the failure took exactly one of ADR-0015's two arms"
     (or (= procs-at-raise procs-before)
         (= procs-at-raise (+ procs-before 1))))
   (test-assert "[informational] stdio-setup failure class recorded"
     (begin (display "  [informational] stdio-setup (EINVAL) cleanup arm: ")
            (display (if (= procs-at-raise procs-before)
                         'setup-class-direct-free
                         'exec-class-close-through-protocol))
            (newline)
            #t))
   ;; ADR-0015's second observable, and THE row that kills an arm-collapse
   ;; mutant on either libuv: the wrong cleanup splices a LATER-registered
   ;; LIVE handle out of loop->handle_queue (spike SQ1 Observation 2,
   ;; "late handle survived #f"). uv_walk -- through the `walk` dispatcher
   ;; (libuv process) installs -- is the measured instrument.
   ;;
   ;; ORDER IS LOAD-BEARING, and getting it wrong is how this row silently
   ;; stops testing anything: the damage is done by the FAILED handle's
   ;; close callback (uv__finish_close unlinking a second time through a
   ;; node that still points at its old neighbours), so `late` must be in
   ;; the queue BEFORE the loop turns. A handle created after the drain
   ;; cannot witness a splice that already happened -- verified: with
   ;; clean-up-failed-spawn! mutated to take the close-through-protocol arm
   ;; unconditionally, the drain-then-create order passes and this order
   ;; fails.
   (let ((late (make-uv-pipe loop)))
     (test-assert "a handle registered before the failure is cleaned up is in the queue"
       (handle-in-loop-queue? loop late))
     (test-equal "the failed spawn's handle is gone once the loop has turned"
       'satisfied (run-until loop
                             (lambda () (= procs-before (live-count 'process)))
                             64))
     (test-assert "and that live handle SURVIVED the cleanup, still in the queue"
       (handle-in-loop-queue? loop late))
     (uv-close! late)
     (test-equal "the late handle closes normally"
       'satisfied (run-until loop
                             (lambda () (eq? 'closed (uv-handle-state late)))
                             64))
     (test-assert "and is out of the queue once closed"
       (not (handle-in-loop-queue? loop late))))
   (test-equal "no registry entry leaked on the failure path"
     registry-before (registry-count))
   ;; §4.3's amended consumed-pipe contract: a pipe named in ANY raising
   ;; spawn's stdio specs is marked connected, whichever spec form named
   ;; it -- this scenario's own RED against the pre-fix mark-consumed-
   ;; pipes! (which matched only (pipe h dir)) is what exposed that the
   ;; inherit-stream form had been left out; see the mutation log / task
   ;; report for the fix. Deliberately NOT asserting a real fd here: the
   ;; setup class closes libuv's own socketpair fds before this record
   ;; could see one (§4.3's own caveat forbids that assertion).
   (test-assert "the named pipe is marked connected even on the failure path"
     (pipe-connected? unconnected))
   (uv-close! unconnected)
   (test-equal "the consumed-but-fdless pipe still closes cleanly"
     'satisfied (run-until loop (lambda () (eq? 'closed (uv-handle-state unconnected))) 64))))

;; --- pipe-wrong-loop (§4.3) ------------------------------------------------
(with-loop
 (lambda (loop)
   (let* ((other (make-uv-loop))
          (foreign-pipe (make-uv-pipe other)))
     (test-equal "a pipe from another loop is refused by name" 'pipe-wrong-loop
       (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
         (uv-spawn! loop "/bin/cat" '("cat")
                    (list (cons 'stdio (list (list 'pipe foreign-pipe 'to-child))))
                    #f)
         'no-raise))
     (uv-loop-teardown! other))))

;; --- duplex (§9.2: sole coverage of the OR'd direction bits) --------------
(with-loop
 (lambda (loop)
   (define duplex-pipe (make-uv-pipe loop))
   (define out (make-byte-collector))
   (define exit-result 'not-yet)
   (define eof 'not-yet)
   ;; The child reads fd 0 and writes fd 0 -- a socketpair end is
   ;; bidirectional (V3): cat's stdout is redirected back onto fd 0.
   (define proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "/bin/cat >&0")
                (list (cons 'stdio (list (list 'pipe duplex-pipe 'duplex))))
                (lambda (s g) (collect) (set! exit-result (list s g)))))
   (uv-read-start! duplex-pipe
                   (lambda (bv s e) (collect) (collect-span! out bv s e))
                   (lambda () (collect) (set! eof 'eof))
                   (lambda (err) (collect) (set! eof (list 'error err))))
   (uv-write! duplex-pipe (string->utf8 "ping-pong")
              (lambda (err) (collect)
                (when (not err)
                  (uv-shutdown! duplex-pipe (lambda (e2) (collect))))))
   (test-equal "duplex round-trip delivers"
     'satisfied (run-until/ticking
                 loop (lambda () (= 9 (collector-count out))) 8192))
   (test-equal "duplex payload intact" "ping-pong"
     (utf8->string (collector-bytes out)))
   (test-equal "the child exits after its duplex end closed"
     'satisfied (run-until/ticking loop (lambda () (pair? exit-result)) 8192))
   ;; The eof sentinel was captured-but-unasserted (v0.3 final-review
   ;; follow-up): an (error err) delivery after the ninth byte was
   ;; invisible. Independent wait, matching the argv/env/cwd scenario's
   ;; "either order" shape -- the child's exit and its end's EOF are
   ;; separate observations.
   (test-equal "duplex read reaches EOF once the child's end closed"
     'satisfied (run-until/ticking loop (lambda () (eq? eof 'eof)) 8192))
   (uv-close! proc) (uv-close! duplex-pipe)
   (test-equal "process and duplex pipe finish closing"
     'satisfied (run-until loop
                           (lambda () (and (eq? 'closed (uv-handle-state proc))
                                           (eq? 'closed (uv-handle-state duplex-pipe))))
                           128))))

;; --- extra fd, slot 3 (§9.2: >3-slot stdio + libuv's own 0-2 padding) ----
(with-loop
 (lambda (loop)
   (define fd3-pipe (make-uv-pipe loop))
   (define out (make-byte-collector))
   (define eof 'not-yet)
   (define exit-result 'not-yet)
   (define proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "printf x >&3")
                (list (cons 'stdio (list 'ignore 'ignore 'ignore
                                         (list 'pipe fd3-pipe 'from-child))))
                (lambda (s g) (collect) (set! exit-result (list s g)))))
   (uv-read-start! fd3-pipe
                   (lambda (bv s e) (collect) (collect-span! out bv s e))
                   (lambda () (collect) (set! eof 'eof))
                   (lambda (err) (collect) (set! eof (list 'error err))))
   (test-equal "the byte crosses fd 3"
     'satisfied (run-until/ticking
                 loop (lambda () (= 1 (collector-count out))) 4096))
   (test-equal "x" (utf8->string (collector-bytes out)))
   (test-equal "the child exits"
     'satisfied (run-until/ticking loop (lambda () (pair? exit-result)) 4096))
   ;; Captured-but-unasserted until the v0.3 follow-up wave: same
   ;; independent-wait shape as the duplex scenario's eof row.
   (test-equal "the fd-3 pipe reaches EOF once the child's end closed"
     'satisfied (run-until/ticking loop (lambda () (eq? eof 'eof)) 4096))
   (uv-close! proc) (uv-close! fd3-pipe)
   (test-equal "process and fd-3 pipe finish closing"
     'satisfied (run-until loop
                           (lambda () (and (eq? 'closed (uv-handle-state proc))
                                           (eq? 'closed (uv-handle-state fd3-pipe))))
                           128))))

;; --- inherit-fd (§9.2: child writes an inherited temp-file fd) -----------
;; tests/tmp/ is .gitignored, so a fresh checkout (any CI runner) does NOT
;; have it and open-file-output-port below would raise unhandled, aborting
;; the whole suite mid-run. Created here rather than assumed. The
;; file-exists? guard is not a race check -- it is the ordinary
;; already-there case; a genuine concurrent creator would make `mkdir`
;; raise EEXIST, which is a real error worth surfacing, not one to swallow.
(with-loop
 (lambda (loop)
   (define tmp-dir (let ((d "tests/tmp"))
                     (unless (file-exists? d) (mkdir d))
                     d))
   (define path (let ((p (string-append tmp-dir "/inherit-fd-probe.txt")))
                  (when (file-exists? p) (delete-file p))
                  p))
   (define port (open-file-output-port path))
   (define fd (port-file-descriptor port))
   (define exit-result 'not-yet)
   (define proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "printf inherited >&1")
                (list (cons 'stdio (list 'ignore (cons 'inherit-fd fd))))
                (lambda (s g) (collect) (set! exit-result (list s g)))))
   (test-equal "child exits"
     'satisfied (run-until/ticking loop (lambda () (pair? exit-result)) 4096))
   (close-port port)
   (test-equal "the inherited fd carried the bytes into the file"
     "inherited"
     (call-with-port (open-input-file path) get-string-all))
   (delete-file path)
   (uv-close! proc)
   (test-equal "the process handle finishes closing"
     'satisfied (run-until loop (lambda () (eq? 'closed (uv-handle-state proc))) 64))))

;; --- inherit-stream (§9.2: sole coverage; loopback TCP, ADR-0010) --------
(with-loop
 (lambda (loop)
   ;; Every DEFINE up front (R6RS body order): accepted/connected/proc start
   ;; as sentinels and are set! once the value they need exists, the same
   ;; sentinel-then-set! shape every other scenario in this suite uses for
   ;; a callback-delivered value.
   (define server (make-uv-tcp loop))
   (define port-num (bind-loopback! server))
   (define client (make-uv-tcp loop))
   (define accepted 'not-yet)
   (define connected 'not-yet)
   ;; Child stdout dups onto the ACCEPTED socket; parent reads the CLIENT.
   (define out (make-byte-collector))
   (define eof 'not-yet)
   (define exit-result 'not-yet)
   (define proc 'not-yet)
   (uv-listen! server 8 (lambda (err)
                          (when (not err)
                            (set! accepted (uv-accept! server)))))
   (connect-loopback! client port-num (lambda (err) (set! connected (or err 'ok))))
   (run-until/ticking loop (lambda () (and (uv-tcp? accepted)
                                           (eq? 'ok connected))) 2048)
   (set! proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "printf over-the-socket")
                (list (cons 'stdio (list 'ignore (cons 'inherit-stream accepted))))
                (lambda (s g) (collect) (set! exit-result (list s g)))))
   (uv-read-start! client
                   (lambda (bv s e) (collect) (collect-span! out bv s e))
                   (lambda () (collect) (set! eof 'eof))
                   (lambda (err) (collect) (set! eof (list 'error err))))
   (test-equal "the bytes crossed the inherited socket"
     'satisfied (run-until/ticking
                 loop (lambda () (= 15 (collector-count out))) 4096))
   (test-equal "over-the-socket" (utf8->string (collector-bytes out)))
   (test-equal "the child exits"
     'satisfied (run-until/ticking loop (lambda () (pair? exit-result)) 4096))
   ;; UV_INHERIT_STREAM dups the fd into the child; the PARENT's accepted
   ;; end stays open, so the child's exit alone cannot EOF the client --
   ;; the sentinel was captured-but-unasserted because nothing here made
   ;; EOF observable. Closing the accepted end is what lets the row exist:
   ;; the child's dup is gone (exit waited above), so this close releases
   ;; the last copy and the client's read must reach EOF.
   (uv-close! accepted)
   (test-equal "client sees EOF once the parent's accepted end closes too"
     'satisfied (run-until/ticking loop (lambda () (eq? eof 'eof)) 4096))
   (uv-close! proc)))
   ;; server/client swept by with-loop's teardown -- also an assertion (the
   ;; suite-end counter/registry rows are what confirm it). accepted is
   ;; closed above, where the eof row needs it.

;; --- kill by handle: deterministic blocked child (§9.2) ------------------
(with-loop
 (lambda (loop)
   (define stdin-pipe (make-uv-pipe loop))
   (define exit-result 'not-yet)
   (define proc
     (uv-spawn! loop "/bin/cat" '("cat")
                (list (cons 'stdio (list (list 'pipe stdin-pipe 'to-child))))
                (lambda (s g) (collect) (set! exit-result (list s g)))))
   (test-assert "pid is a positive exact integer while the child runs"
     (let ((pid (uv-process-pid proc)))
       (and (integer? pid) (exact? pid) (positive? pid))))
   (test-assert "liveness probe 0 returns without raising while blocked"
     (begin (uv-process-kill! proc 0) #t))
   (uv-process-kill! proc 'sigterm)
   (test-equal "sigterm death delivers (0 sigterm) — V5's shape"
     'satisfied (run-until/ticking loop (lambda () (pair? exit-result)) 4096))
   (test-equal '(0 sigterm) exit-result)
   (test-assert "pid still readable between exit and close (§4.5)"
     (positive? (uv-process-pid proc)))
   (uv-close! proc) (uv-close! stdin-pipe)
   (run-until loop (lambda () (eq? 'closed (uv-handle-state proc))) 128)))

;; --- kill by raw pid ------------------------------------------------------
(with-loop
 (lambda (loop)
   (define stdin-pipe (make-uv-pipe loop))
   (define exit-result 'not-yet)
   (define proc
     (uv-spawn! loop "/bin/cat" '("cat")
                (list (cons 'stdio (list (list 'pipe stdin-pipe 'to-child))))
                (lambda (s g) (collect) (set! exit-result (list s g)))))
   (uv-kill! (uv-process-pid proc) 'sigkill)
   (run-until/ticking loop (lambda () (pair? exit-result)) 4096)
   (test-equal "sigkill by pid delivers (0 sigkill)" '(0 sigkill) exit-result)
   (uv-close! proc) (uv-close! stdin-pipe)
   (run-until loop (lambda () (eq? 'closed (uv-handle-state proc))) 128)))

;; --- signal vocabulary refusals ------------------------------------------
(with-loop
 (lambda (loop)
   (define stdin-pipe (make-uv-pipe loop))
   (define proc
     (uv-spawn! loop "/bin/cat" '("cat")
                (list (cons 'stdio (list (list 'pipe stdin-pipe 'to-child)))) #f))
   (define (reason-of thunk)
     (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
       (thunk) 'no-raise))
   (test-equal 'signal-unknown
     (reason-of (lambda () (uv-process-kill! proc 'sigfoo))))
   (test-equal 'signal-unknown
     (reason-of (lambda () (uv-process-kill! proc 15))))  ;; ints other than 0: symbols only
   (test-equal 'signal-unknown
     (reason-of (lambda () (uv-kill! 99999999 'sigfoo)))) ;; validated BEFORE the errno path
   (test-equal 'pid-not-an-exact-integer
     (reason-of (lambda () (uv-kill! "42" 'sigterm))))
   (test-assert "uv-kill! on a vanished pid raises an errno symbol"
     (guard (e ((uv-errno-error? e)
                ;; ESRCH normally; EPERM if the pid was recycled to another
                ;; user's process -- both prove the errno path.
                (memq (uv-errno-error-errno e) '(ESRCH EPERM))))
       (uv-kill! 99999999 0) #f))
   (uv-process-kill! proc 'sigkill)
   (run-until/ticking loop (lambda () (process-exited? proc)) 4096)
   (uv-close! proc) (uv-close! stdin-pipe)
   (run-until loop (lambda () (eq? 'closed (uv-handle-state proc))) 128)))

;; --- detached (§9.2: no-hang + counters only; never reaped) --------------
(with-loop
 (lambda (loop)
   (define proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 0")
                (list (cons 'detached #t)) #f))
   (uv-close! proc)
   (test-equal "loop drains without waiting on the detached child"
     'satisfied (run-until loop
                           (lambda () (eq? 'closed (uv-handle-state proc)))
                           128))
   (test-equal "process counter balanced" 0 (live-count 'process))))

;; --- lifecycle: close from inside on-exit / teardown sweep / seam --------
(with-loop
 (lambda (loop)
   (define states 'not-yet)
   (define proc 'not-yet)
   (set! proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 3")
                (lambda (s g)
                  (collect)
                  ;; close from INSIDE on-exit -- the documented pattern (§6)
                  (uv-close! proc (lambda () (set! states 'closed-from-exit))))))
   (test-equal "close-from-on-exit completes"
     'satisfied (run-until/ticking loop
                                   (lambda () (eq? states 'closed-from-exit))
                                   4096))))

(with-loop
 (lambda (loop)
   ;; spawn, wait for silent reap, never close: the TEARDOWN SWEEP owns it.
   (define proc (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 0") #f))
   (run-until/ticking loop (lambda () (process-exited? proc)) 4096)))
   ;; with-loop tears down; the suite-end counter/registry rows assert the
   ;; sweep closed it (Task 5's handle-kinds forward obligation).

(with-loop
 (lambda (loop)
   ;; a raise inside on-exit is stored and re-raised by uv-run (S8 seam).
   (define-condition-type &exit-probe &error make-exit-probe exit-probe?)
   (define proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 0")
                (lambda (s g) (raise (make-exit-probe)))))
   (test-assert "the exit callback's raise surfaces as &uv-callback-error wrapping the probe"
     (guard (e (#t (and (uv-callback-error? e) (exit-probe? e))))
       (let drain ((i 0))
         (uv-run loop 'once)
         (if (< i 2048) (drain (+ i 1)) 'never-raised))))
   (uv-close! proc)
   (run-until loop (lambda () (eq? 'closed (uv-handle-state proc))) 128)))

;; --- term-signal outside the bound set passes through RAW (§4.4) ---------
(with-loop
 (lambda (loop)
   (define exit-result 'not-yet)
   (define proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "kill -PIPE $$")
                (lambda (s g) (collect) (set! exit-result (list s g)))))
   (run-until/ticking loop (lambda () (pair? exit-result)) 4096)
   (test-assert "unbound death signal arrives as its raw exact integer"
     (and (= 0 (car exit-result))
          (integer? (cadr exit-result))
          (exact? (cadr exit-result))
          (positive? (cadr exit-result))))
   (uv-close! proc)
   (run-until loop (lambda () (eq? 'closed (uv-handle-state proc))) 128)))

(collect)
(test-assert "counters all zero at suite end"
  (for-all (lambda (kv) (zero? (cdr kv))) (live-counts)))
(test-equal "registry back to baseline" registry-count-at-start (registry-count))
(test-end "process")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
