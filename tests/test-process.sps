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
        (only (libuv private native) live-counts alloc-block free-block! uv-handle-size)
        (only (libuv private constants) uv-process-type)
        (uv-testing)
        (only (uv-evidence) live-count describe under-memory-tool?)
        ;; uv-spawn!'s list reads against another thread (#66), the
        ;; meter its cost rows use, and the level-3 child's runner.
        (spawn-list-races)
        (only (uv-meter) fewest-bytes)
        (uv-level-3)
        ;; The engine-sweep driver caps the changing-data sweeps' resumes;
        ;; a state sweep hands its loop to other-thread, and the drop sweeps
        ;; check that no run leaves interrupts off.
        (only (uv-sweep) run-capped other-thread interrupts-enabled?)
        (only (chezscheme) collect putenv mkdir
              get-string-all open-file-output-port port-file-descriptor
              ;; The changing-data sweeps drive a spawn in an engine, or race
              ;; it from another thread, and change the caller's lists and
              ;; strings mid-call.
              make-engine last-pair list-head set-car! set-cdr! string-set!
              fork-thread thread-join getenv
              ;; The state sweeps count this process's open descriptors.
              directory-list
              ;; A drop run that left interrupts off turns them back on.
              enable-interrupts))

(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner prints only a failing row's title. The sweep rows
;; return their evidence when they fail, so print that too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

(test-begin "process")

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
;; Which errno refuses it depends on whether uid 1 exists here. In a user
;; namespace that maps only the caller's own uid, as a rootless container's
;; does (the Guix container's, ADR-0020), the kernel refuses an unmapped uid
;; with EINVAL before it checks permission. Elsewhere it is EPERM, or EACCES
;; on some platforms. uid-in-map? reads a uid_map from port: #t when a line
;; of it, "inside outside count", maps uid. uid-mapped? is #t where there is
;; no /proc/self/uid_map (macOS), or where that map holds uid.
(define (uid-in-map? uid port)
  (let next ()
    (let* ((inside (read port)) (outside (read port)) (count (read port)))
      (cond ((eof-object? inside) #f)
            ((and (<= inside uid) (< uid (+ inside count))) #t)
            (else (next))))))

(define (uid-mapped? uid)
  (or (not (file-exists? "/proc/self/uid_map"))
      (call-with-input-file "/proc/self/uid_map"
        (lambda (port) (uid-in-map? uid port)))))

;; Any one environment takes only one of the row's branches, so the parser
;; that picks the branch is held here, on maps of both kinds.
(define (map-answer uid text)
  (if (uid-in-map? uid (open-string-input-port text)) 'mapped 'unmapped))
(test-equal "uid map: the initial namespace's maps uid 1"
  'mapped (map-answer 1 "         0          0 4294967295\n"))
(test-equal "uid map: a rootless container's, only its own uid, does not"
  'unmapped (map-answer 1 "      1000       1000          1\n"))
(test-equal "uid map: it does map its own uid"
  'mapped (map-answer 1000 "      1000       1000          1\n"))
(test-equal "uid map: a range's end is outside it"
  'unmapped (map-answer 1001 "      1000       1000          1\n"))
(test-equal "uid map: a later line can map it"
  'mapped (map-answer 1 "      1000       1000          1\n         0     100000      65536\n"))

(with-loop
 (lambda (loop)
   (define raised
     (guard (e ((uv-errno-error? e) (uv-errno-error-errno e)))
       (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 0")
                  (list (cons 'uid 1)) #f)
       'no-raise))
   ;; The map is read inside the tested expression, so a failure to read
   ;; it fails this row instead of aborting the suite.
   (test-equal "uid as non-root is refused at spawn: 'EPERM ('EACCES per platform), or 'EINVAL where uid 1 is unmapped"
     'refused-as-expected
     (let ((expected (if (uid-mapped? 1) '(EPERM EACCES) '(EINVAL))))
       (if (memq raised expected)
           'refused-as-expected
           (list 'raised raised 'expected expected))))
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
   ;; The scan reaches a string's first and last bytes, where C would read
   ;; the string as empty or as one character short.
   (test-equal "a NUL as the first or the last character of an args string"
     '(embedded-nul embedded-nul)
     (list (reason-of (spawn-with "/bin/sh" '("\x0;sh") #f))
           (reason-of (spawn-with "/bin/sh" '("sh\x0;") #f))))
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
   ;; A (pipe ...) spec is exactly a pipe and a direction.
   (test-equal "a (pipe) spec with no pipe" 'stdio-spec-unknown
     (reason-of (spawn-with "/bin/sh" ok-args '((stdio . ((pipe)))) #f)))
   (test-equal "a (pipe ...) spec with no direction" 'stdio-spec-unknown
     (reason-of (spawn-with "/bin/sh" ok-args
                            (list (cons 'stdio
                                        (list (list 'pipe (make-uv-pipe loop)))))
                            #f)))
   (test-equal "a (pipe ...) spec with more than a pipe and a direction"
     'stdio-spec-unknown
     (reason-of (spawn-with "/bin/sh" ok-args
                            (list (cons 'stdio
                                        (list (list 'pipe (make-uv-pipe loop)
                                                    'from-child 'extra))))
                            #f)))
   (test-equal "a NUL inside cwd" 'embedded-nul
     (reason-of (spawn-with "/bin/sh" ok-args '((cwd . "/\x0;tmp")) #f)))
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
;;     Measured, not inferred: CI's pkg-config leg takes this arm, on
;;     Ubuntu 24.04's apt libuv 1.48.0 and on 26.04's 1.51.0 (a mirror of
;;     the job, 2026-10-08); its vendored leg (1.52.1) and macOS's homebrew
;;     libuv (1.52.1) take the other.
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
     (test-equal "an inherit-stream handle from another loop is refused by name"
       'pipe-wrong-loop
       (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
         (uv-spawn! loop "/bin/cat" '("cat")
                    (list (cons 'stdio (list (cons 'inherit-stream foreign-pipe))))
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
   (test-equal "seed: the inherit-stream pair connected and was accepted"
     'satisfied (run-until/ticking loop (lambda () (and (uv-tcp? accepted)
                                                        (eq? 'ok connected))) 2048))
   ;; Gated on the seed: without a peer, the rows below fail by name instead
   ;; of the spawn aborting the suite (AGENTS.md).
   (when (uv-tcp? accepted)
     (set! proc
       (uv-spawn! loop "/bin/sh" '("sh" "-c" "printf over-the-socket")
                  (list (cons 'stdio (list 'ignore (cons 'inherit-stream accepted))))
                  (lambda (s g) (collect) (set! exit-result (list s g))))))
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
   (when (uv-tcp? accepted) (uv-close! accepted))
   (test-equal "client sees EOF once the parent's accepted end closes too"
     'satisfied (run-until/ticking loop (lambda () (eq? eof 'eof)) 4096))
   (when (uv-process? proc) (uv-close! proc))))
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

;; --- uv-os-getpid (v0.4, ADR-0017 D8) -------------------------------------
(test-equal "uv-os-getpid answers a positive exact integer, stable across calls"
  'stable-positive
  (let ((a (uv-os-getpid)) (b (uv-os-getpid)))
    (if (and (integer? a) (exact? a) (positive? a) (= a b))
        'stable-positive
        'wrong)))

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
   ;; The exit dispatcher calls on-exit last, so a raise there skips none
   ;; of its own steps (#45).
   (test-equal "the record was marked exited before on-exit raised"
     'exited (if (process-exited? proc) 'exited 'not-exited))
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

;; --- the caller's data changing during the call ---------------------------
;; uv-spawn! reads what its caller passed (file, args, env, cwd and the stdio
;; specs) once, into copies nothing else can reach, and checks, sizes and
;; fills its options block from those alone. It used to check the caller's
;; data, size the block from it, and read it again to fill the block, and an
;; engine's timer handler (or another thread) could change it in between.
;; Strings and lists that grew were written past the block's end, a stdio
;; list that grew wrote a container over argv, a pipe swapped in after the
;; check reached libuv unchecked, and a NUL set after the check cut the
;; child's strings short.
;;
;; Each sweep runs a spawn in an engine at rising fuel. At the first expiry it
;; changes the caller's data, then resumes the spawn. Fuel 1 expires before
;; the spawn reads anything, and the sweep stops at the first run no expiry
;; reached, whatever its verdict, so between them it visits every point in
;; the verb. The spawn reads in one step no timer can split, so each run has
;; two right answers: the outcome of the data as it was before the change, or
;; as it was after. Each child reports what it saw on a pipe (its operands,
;; three environment variables and the last part of its working directory)
;; and exits 7, so a child run on a mix of the two, or on bytes nobody passed,
;; matches neither. Each change touches several strings or lists at once for
;; that reason: one of them read again after the others shows up as a mix.
;;
;; An overrun that leaves the child's view intact is invisible to these rows.
;; `make test-memory` reports its invalid write: Valgrind on Linux, ASan on
;; macOS. Sixteen children run at a time: waiting for each child in turn
;; took about 10 ms a run on macOS, and sixteen at a time take about 2.5.

(define sweep-loop (make-uv-loop))
;; The stdio sweep swaps in a pipe of this loop, which a spawn must refuse.
(define other-loop (make-uv-loop))
(define sweep-process-baseline (live-count 'process))
(define sweep-registry-baseline (registry-count))

(define report-script
  "printf '%s|' \"$0\" \"$@\" \"V=$V\" \"W=$W\" \"X=$X\" \"cwd=${PWD##*/}\"; exit 7")
(define four-lambdas (make-string 4 (integer->char #x3bb)))

;; The strings sweep's working directory, as it was before the change and
;; after it.
(for-each (lambda (d) (unless (file-exists? d) (mkdir d)))
          (list "tests/tmp" "tests/tmp/spawn-cwd-aaaa"
                (string-append "tests/tmp/spawn-cwd-" four-lambdas)))

(define (overwrite-tail! s tail)
  (let ((at (- (string-length s) (string-length tail))))
    (do ((i 0 (+ i 1))) ((= i (string-length tail)))
      (string-set! s (+ at i) (string-ref tail i)))))

(define (stdout-to pipe) (list 'ignore (list 'pipe pipe 'from-child)))

;; A variant's setup builds one run's copy of the caller's data around the
;; pipe its child reports on: (list args options change! pipes), where PIPES
;; are the pipes whose marks the run reports, that one first. BEFORE and
;; AFTER are what a run comes to on the data before the change and after it.
(define-record-type sweep-variant
  (fields name setup before after))

(define sweep-variants
  (list
   ;; Each "aaaa" becomes four lambdas, two bytes each in UTF-8.
   (make-sweep-variant
    'strings-grow
    (lambda (pipe)
      (let ((arg (string-copy "aaaa"))
            (var (string-copy "V=aaaa"))
            (cwd (string-copy "tests/tmp/spawn-cwd-aaaa")))
        (list (list "sh" "-c" report-script "zero" arg)
              (list (cons 'env (list var "W=w"))
                    (cons 'cwd cwd)
                    (cons 'stdio (stdout-to pipe)))
              (lambda ()
                (for-each (lambda (s) (overwrite-tail! s four-lambdas))
                          (list arg var cwd)))
              (list pipe))))
    '(ran (7 #f) "zero|aaaa|V=aaaa|W=w|X=|cwd=spawn-cwd-aaaa|" (marked))
    (list 'ran '(7 #f)
          (string-append "zero|" four-lambdas "|V=" four-lambdas
                         "|W=w|X=|cwd=spawn-cwd-" four-lambdas "|")
          '(marked)))
   (make-sweep-variant
    'lists-grow
    (lambda (pipe)
      (let ((args (list "sh" "-c" report-script "zero" "one"))
            (env (list "V=v" "W=w")))
        (list args
              (list (cons 'env env) (cons 'cwd "/") (cons 'stdio (stdout-to pipe)))
              (lambda ()
                (set-cdr! (last-pair args) (list "xxxx"))
                (set-cdr! (last-pair env) (list "X=xxxx")))
              (list pipe))))
    '(ran (7 #f) "zero|one|V=v|W=w|X=|cwd=|" (marked))
    '(ran (7 #f) "zero|one|xxxx|V=v|W=w|X=xxxx|cwd=|" (marked)))
   ;; The pipe the child would report on is swapped for another loop's, which
   ;; the spawn must refuse, and the list gains a fourth spec.
   (make-sweep-variant
    'stdio-changes
    (lambda (pipe)
      (let ((specs (list 'ignore (list 'pipe pipe 'from-child) 'ignore))
            (other (make-uv-pipe other-loop)))
        (list (list "sh" "-c" report-script "zero")
              (list (cons 'env (list "V=v" "W=w")) (cons 'cwd "/")
                    (cons 'stdio specs))
              (lambda ()
                (set-car! (cdr (cadr specs)) other)
                (set-cdr! (cddr specs) (list 'ignore)))
              (list pipe other))))
    '(ran (7 #f) "zero|V=v|W=w|X=|cwd=|" (marked unmarked))
    '(refused uv-spawn! pipe-wrong-loop (unmarked unmarked)))
   (make-sweep-variant
    'nuls-appear
    (lambda (pipe)
      (let ((script (string-copy report-script))
            (arg (string-copy "abcd"))
            (var (string-copy "V=abcd")))
        (list (list "sh" "-c" script "zero" arg)
              (list (cons 'env (list var "W=w")) (cons 'cwd "/")
                    (cons 'stdio (stdout-to pipe)))
              (lambda ()
                ;; Cut short at the NUL, "exit 7" is "exit ", which exits
                ;; with printf's status, 0.
                (string-set! script (- (string-length script) 1) #\nul)
                (string-set! arg 2 #\nul)
                (string-set! var 4 #\nul))
              (list pipe))))
    '(ran (7 #f) "zero|abcd|V=abcd|W=w|X=|cwd=|" (marked))
    '(refused uv-spawn! embedded-nul (unmarked)))))

;; One engine run of a sweep, and what its child has reported so far.
(define-record-type spawn-run
  (fields fuel pipes report
          (mutable expired run-expired? set-run-expired!)
          (mutable outcome run-outcome set-run-outcome!)
          (mutable status run-status set-run-status!)
          (mutable eof run-eof set-run-eof!))
  (protocol
   (lambda (new)
     (lambda (fuel pipes)
       (new fuel pipes (make-byte-collector) #f '(not-run) 'not-yet 'not-yet)))))

;; start-run! : sweep-variant exact-positive-integer -> spawn-run
;; Spawns in an engine with FUEL ticks, makes the variant's change at the
;; first expiry, resumes, and starts reading the child's report. A spawn
;; still running at the driver's cap answers its give-up, so a read that
;; came to loop fails its run by name instead of hanging the suite: until
;; #81 this resumed without a cap.
(define (start-run! variant fuel)
  (let* ((pipe (make-uv-pipe sweep-loop))
         (data ((sweep-variant-setup variant) pipe))
         (run (make-spawn-run fuel (cadddr data))))
    (set-run-outcome!
     run
     (let-values (((outcome expired)
                   (run-capped
                    (lambda ()
                      (guard (e ((uv-invalid-argument? e)
                                 (list 'refused (uv-invalid-argument-who e)
                                       (uv-invalid-argument-reason e)))
                                ((uv-errno-error? e)
                                 (list 'errno (uv-errno-error-errno e)))
                                (#t (list 'raised (describe e))))
                        (list 'spawned
                              (uv-spawn! sweep-loop "/bin/sh" (car data) (cadr data)
                                         (lambda (status signal)
                                           (collect)
                                           (set-run-status! run (list status signal)))))))
                    fuel
                    (lambda ()
                      (set-run-expired! run #t)
                      ((caddr data))))))
       outcome))
    (when (eq? (car (run-outcome run)) 'spawned)
      (guard (e (#t (set-run-eof! run (list 'read-refused (describe e)))))
        (uv-read-start! pipe
                        (lambda (bv start end)
                          (collect)
                          (collect-span! (spawn-run-report run) bv start end))
                        (lambda () (collect) (set-run-eof! run 'eof))
                        (lambda (err) (collect) (set-run-eof! run (list 'read-error err))))))
    run))

(define (run-spawned? run) (eq? (car (run-outcome run)) 'spawned))

(define (run-finished? run)
  (or (not (run-spawned? run))
      (and (pair? (run-status run)) (not (eq? (run-eof run) 'not-yet)))))

;; run-seen : spawn-run -> list
;; What a run came to, in the shape of a variant's before and after.
(define (run-seen run)
  (let ((outcome (run-outcome run))
        (marks (map (lambda (p) (if (pipe-connected? p) 'marked 'unmarked))
                    (spawn-run-pipes run))))
    (cond ((not (run-spawned? run)) (append outcome (list marks)))
          ((eq? (run-eof run) 'eof)
           (list 'ran (run-status run)
                 (utf8->string (collector-bytes (spawn-run-report run))) marks))
          (else
           (list 'ran (run-status run) 'report-ended (run-eof run)
                 (utf8->string (collector-bytes (spawn-run-report run))) marks)))))

;; run-verdict : sweep-variant spawn-run -> verdict
;; A verdict is 'before, 'after or 'untouched, or else the evidence, a list.
(define (run-verdict variant run)
  (let ((seen (run-seen run)))
    (cond ((not (run-finished? run)) (list 'unfinished seen))
          ((not (run-expired? run))
           (if (equal? seen (sweep-variant-before variant))
               'untouched
               (list 'untouched-but seen)))
          ((equal? seen (sweep-variant-before variant)) 'before)
          ((equal? seen (sweep-variant-after variant)) 'after)
          (else (list 'neither seen)))))

(define (unfinished? verdict) (and (pair? verdict) (eq? (car verdict) 'unfinished)))

(define (sweep-residue)
  (list (live-count 'spawn-options)
        (- (live-count 'process) sweep-process-baseline)
        (- (registry-count) sweep-registry-baseline)))

;; finish-batch! : sweep-variant (list-of spawn-run) -> (list-of (list fuel verdict))
;; Waits for every child in BATCH, closes the batch's handles, and gives each
;; run its verdict. If the batch leaves an options block, a process or a
;; registry entry behind, its last run carries the residue instead.
(define (finish-batch! variant batch)
  (run-until/ticking sweep-loop (lambda () (for-all run-finished? batch)) 20000)
  (let ((rows (map (lambda (run) (list (spawn-run-fuel run) (run-verdict variant run)))
                   batch)))
    (for-each (lambda (run)
                (when (run-spawned? run) (uv-close! (cadr (run-outcome run))))
                (for-each (lambda (p) (when (uv-handle-open? p) (uv-close! p)))
                          (spawn-run-pipes run)))
              batch)
    ;; Closes on the other loop finish when it runs.
    (run-until sweep-loop
               (lambda ()
                 (uv-run other-loop 'nowait)
                 (equal? (sweep-residue) '(0 0 0)))
               64)
    (let ((residue (sweep-residue)))
      (if (equal? residue '(0 0 0))
          rows
          (let ((last-row (list-ref rows (- (length rows) 1))))
            (append (list-head rows (- (length rows) 1))
                    (list (list (car last-row) (list 'residue residue (cadr last-row))))))))))

(define spawn-max-fuel 3000)
(define spawn-batch-size 16)

;; spawn-sweep : sweep-variant -> (list-of (list fuel verdict))
;; Stops at the first run no expiry reached, at the fuel cap, or after a batch
;; whose children did not all finish. A raise between runs would abort the
;; suite, so the whole sweep is caught and its evidence handed to the rows.
(define (spawn-sweep variant)
  (guard (e (#t (list (list 0 (list 'sweep-raised (describe e))))))
    (let next ((fuel 1) (batch '()) (rows '()))
      (let* ((run (start-run! variant fuel))
             (batch (cons run batch))
             (last? (or (not (run-expired? run)) (= fuel spawn-max-fuel))))
        (if (or last? (= (length batch) spawn-batch-size))
            (let* ((done (finish-batch! variant (reverse batch)))
                   (rows (append rows done)))
              (if (or last? (exists (lambda (row) (unfinished? (cadr row))) done))
                  rows
                  (next (+ fuel 1) '() rows)))
            (next (+ fuel 1) batch rows))))))

;; In order, one after another: Chez's map applies its procedure in no fixed
;; order.
(define spawn-sweeps
  (let next ((vs sweep-variants) (acc '()))
    (if (null? vs)
        (reverse acc)
        (next (cdr vs)
              (cons (cons (sweep-variant-name (car vs)) (spawn-sweep (car vs)))
                    acc)))))

(uv-loop-teardown! sweep-loop)
(uv-loop-teardown! other-loop)

(for-each
 (lambda (sweep)
   (let ((count (lambda (v) (length (filter (lambda (row) (eq? (cadr row) v))
                                             (cdr sweep))))))
     (display "  [informational] spawn sweep ")
     (display (car sweep))
     (display ": ")
     (display (length (cdr sweep)))
     (display " runs, ")
     (display (count 'after))
     (display " after the change, ")
     (display (count 'before))
     (display " before it\n")))
 spawn-sweeps)

;; The rows below look for wrong verdicts and must find none, which says
;; nothing unless each sweep saw the change land before the spawn read its
;; data and ran the spawn to its end.
(test-equal "each spawn sweep saw the change before the spawn read its data, and ended in a run no expiry reached"
  (map (lambda (v) (list (sweep-variant-name v) 'after 'untouched)) sweep-variants)
  (map (lambda (sweep)
         (let ((rows (cdr sweep)))
           (list (car sweep)
                 (cadr (car rows))
                 (cadr (list-ref rows (- (length rows) 1))))))
       spawn-sweeps))

;; wrong-runs : symbol -> (list-of (list fuel verdict))
(define (wrong-runs name)
  (filter (lambda (row) (not (memq (cadr row) '(before after untouched))))
          (cdr (assq name spawn-sweeps))))

(test-equal "a spawn whose strings grew during the call ran its child on them as they were before the change or after it"
  '() (wrong-runs 'strings-grow))

(test-equal "a spawn whose args and env lists grew during the call ran its child on them as they were before the change or after it"
  '() (wrong-runs 'lists-grow))

(test-equal "a spawn whose stdio specs changed during the call ran on them as they were before the change, or refused them as they were after it"
  '() (wrong-runs 'stdio-changes))

(test-equal "a spawn whose strings gained a NUL during the call ran on them as they were before the change, or refused them as they were after it"
  '() (wrong-runs 'nuls-appear))

;; --- a stdio handle or the loop changing state during the call ------------
;; The read above makes the caller's data private, but what a stdio spec
;; names is a handle, and the handle stays the caller's. Between the checks
;; and uv_spawn an engine's timer handler can close it, consume a pipe in a
;; spawn of its own, or tear the loop down. uv-spawn! checked them on entry
;; and then handed libuv what it had checked:
;; - a pipe closed in between was opened into its closing handle, and
;;   nothing ever closed that descriptor;
;; - a pipe closed and freed in between, with a new pipe made at its
;;   address, connected the child to the new pipe;
;; - a pipe consumed in between made libuv fork and then fail to open it,
;;   ADR-0015 decision 5's unclassifiable state, its handle left to leak;
;; - a loop torn down in between leaked the options block and the process
;;   handle, reached uv_spawn freed, or failed its teardown with EBUSY on a
;;   process the spawn had not registered yet;
;; - a loop handed to another thread in between, by uv-run on that thread,
;;   was spawned on from this one, racing the loop's own thread on libuv's
;;   handle queue (#79).
;; Now the step that calls uv_spawn checks the loop, its owner and every
;; stdio handle again, and in the same step marks the pipes and registers the process,
;; or cleans up after a failure.
;;
;; Each sweep runs a spawn in an engine at rising fuel, as above. At the
;; first expiry it notes whether the spawn has registered its process yet,
;; that is, whether that step has run, and then makes its change. So each
;; run has one right answer. If the step had run, the child ran and the
;; change found the spawn complete. If not, the spawn was refused under the
;; change's own name, and nothing was marked, left allocated or started.
;; Each batch must also leave the options blocks, processes, registry, the
;; binding's blocks and the open descriptors as it found them: a pipe opened
;; into a closing handle shows up only as a descriptor nobody closes. A sweep stops after its
;; first wrong run, since a spawn that reached a freed loop could take the
;; suite down with it.

(define (fd-count) (length (directory-list "/dev/fd")))

(define (spawn-outcome thunk)
  (guard (e ((uv-invalid-argument? e)
             (list 'refused (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            ((uv-handle-closed? e) (list 'closed (uv-handle-closed-kind e)))
            ((uv-wrong-thread? e) (list 'wrong-thread (uv-wrong-thread-who e)))
            ((uv-errno-error? e) (list 'errno (uv-errno-error-errno e)))
            (#t (list 'raised (describe e))))
    (thunk)))

(define (mark pipe) (if (pipe-connected? pipe) 'marked 'unmarked))

;; opened? : uv-pipe -> symbol
;; Whether libuv opened a descriptor into PIPE: an unopened pipe refuses to
;; read with ENOTCONN.
(define (opened? pipe)
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e)))
    (uv-read-start! pipe (lambda (bv start end) #f) (lambda () #f) (lambda (err) #f))
    (uv-read-stop! pipe)
    'opened))

(define state-loop (make-uv-loop))

;; A variant's setup makes one run's handles on LOOP and answers
;; (list stdio change! handles report): the spawn's stdio specs; the change,
;; which takes the run and answers what it did; a thunk listing the run's
;; handles, closed when it ends; and a thunk listing what the run's handles
;; show at its end. PROGRAM is the spawn's file and args. BEFORE, AFTER and
;; UNTOUCHED are what a run comes to when the change found the step not yet
;; run, found it run, or never came. TITLE is the sweep's row: a title kept
;; apart from its variant is looked up outside SRFI-64's catch, where a
;; missing one aborts the suite.
(define-record-type state-variant
  (fields name title own-loop? program setup before after untouched))

(define exits-7 '("/bin/sh" "sh" "-c" "exit 7"))

(define addresses-reused 0)

(define state-variants
  (list
   (make-state-variant
    'close-pipe
    "a spawn whose pipe closed during the call was refused as closed, or had consumed the pipe first, and left no descriptor open"
    #f exits-7
    (lambda (loop)
      (let ((p (make-uv-pipe loop)))
        (list (stdout-to p)
              (lambda (run) (uv-close! p) 'closed)
              (lambda () (list p))
              (lambda () (list (mark p))))))
    '((closed pipe) not-yet closed not-yet (unmarked))
    '((spawned) (7 #f) closed not-yet (marked))
    '((spawned) (7 #f) unchanged not-yet (marked)))
   ;; The change also runs the loop until the close has freed the pipe, and
   ;; makes a new one, which malloc tends to place at the freed address.
   (make-state-variant
    'close-pipe-and-replace-it
    "a spawn whose pipe closed and was replaced at its address during the call never connected the child to the new pipe"
    #f exits-7
    (lambda (loop)
      (let ((p (make-uv-pipe loop)) (q #f))
        (list (stdout-to p)
              (lambda (run)
                (let ((address (handle-ptr p)))
                  (uv-close! p)
                  (run-until loop (lambda () (eq? 'closed (uv-handle-state p))) 64)
                  (set! q (make-uv-pipe loop))
                  (when (eqv? address (handle-ptr q))
                    (set! addresses-reused (+ addresses-reused 1)))
                  'replaced))
              (lambda () (list p q))
              (lambda () (list (mark p) (if q (opened? q) 'no-new-pipe))))))
    '((closed pipe) not-yet replaced not-yet (unmarked ENOTCONN))
    '((spawned) (7 #f) replaced not-yet (marked ENOTCONN))
    '((spawned) (7 #f) unchanged not-yet (marked no-new-pipe)))
   ;; The change spawns a child of its own on the same pipe, which exits 3.
   (make-state-variant
    'consume-pipe
    "a spawn whose pipe another spawn consumed during the call was refused as already used, or consumed it first"
    #f exits-7
    (lambda (loop)
      (let ((p (make-uv-pipe loop)) (rival #f))
        (list (stdout-to p)
              (lambda (run)
                (let ((outcome
                       (spawn-outcome
                        (lambda ()
                          (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 3")
                                     (list (cons 'stdio (list (list 'pipe p 'to-child))))
                                     (lambda (status signal)
                                       (collect)
                                       (set-state-run-change-status!
                                        run (list status signal))))))))
                  (if (uv-process? outcome)
                      (begin (set! rival outcome) '(spawned))
                      outcome)))
              (lambda () (list p rival))
              (lambda () (list (mark p))))))
    '((refused uv-spawn! pipe-already-used) not-yet (spawned) (3 #f) (marked))
    '((spawned) (7 #f) (refused uv-spawn! pipe-already-used) not-yet (marked))
    '((spawned) (7 #f) unchanged not-yet (marked)))
   ;; A bound socket has a descriptor for the child to inherit.
   (make-state-variant
    'close-inherited-stream
    "a spawn whose inherited stream closed during the call was refused as closed, or had passed the stream on first"
    #f exits-7
    (lambda (loop)
      (let ((t (make-uv-tcp loop)))
        (bind-loopback! t)
        (list (list 'ignore (cons 'inherit-stream t))
              (lambda (run) (uv-close! t) 'closed)
              (lambda () (list t))
              (lambda () '()))))
    '((closed tcp) not-yet closed not-yet ())
    '((spawned) (7 #f) closed not-yet ())
    '((spawned) (7 #f) unchanged not-yet ()))
   ;; Each run has a loop of its own, handed to another thread as uv-run on
   ;; that thread would: the change only names another owner, and the run's
   ;; finish takes the loop back by running it (finish-own-loop-run!).
   (make-state-variant
    'hand-off-loop
    "a spawn whose loop was handed to another thread during the call was refused as the wrong thread, or had spawned first"
    #t exits-7
    (lambda (loop)
      (list (list 'ignore)
            (lambda (run)
              (set-loop-owner-thread! loop other-thread)
              'handed-off)
            (lambda () '())
            (lambda () '())))
    '((wrong-thread uv-spawn!) not-yet handed-off not-yet ())
    '((spawned) (7 #f) handed-off not-yet ())
    '((spawned) (7 #f) unchanged not-yet ()))
   ;; Each run has a loop of its own. A child spawned before the teardown
   ;; runs on, its handle closed by the teardown, so its exit never arrives.
   (make-state-variant
    'tear-down-loop
    "a spawn whose loop was torn down during the call was refused as closed, or had registered its process for the teardown to close"
    #t exits-7
    (lambda (loop)
      (list (list 'ignore)
            (lambda (run)
              (spawn-outcome (lambda () (uv-loop-teardown! loop) 'torn-down)))
            (lambda () '())
            (lambda () '())))
    '((closed loop) not-yet torn-down not-yet ())
    '((spawned) not-yet torn-down not-yet ())
    '((spawned) (7 #f) unchanged not-yet ()))
   ;; A spawn libuv forks for and fails, its handle still in the loop
   ;; (ADR-0015's exec class): the cleanup registers the handle and closes
   ;; it, so the teardown must find it registered or never see it.
   (make-state-variant
    'tear-down-loop-of-a-failed-spawn
    "a failed spawn whose loop was torn down during the call was refused as closed, or had handed its handle to the loop's close first"
    #t
    '("/nonexistent/definitely-missing" "definitely-missing")
    (lambda (loop)
      (list (list 'ignore)
            (lambda (run)
              (spawn-outcome (lambda () (uv-loop-teardown! loop) 'torn-down)))
            (lambda () '())
            (lambda () '())))
    '((closed loop) not-yet torn-down not-yet ())
    '((errno ENOENT) not-yet torn-down not-yet ())
    '((errno ENOENT) not-yet unchanged not-yet ()))))

;; One engine run of a state sweep. registered-before and blocks-before are
;; the registry's size and the options blocks held once the run's handles
;; exist. found is what the change found: the step 'run or 'not-run, or
;; 'no-expiry. built says whether the change found the run's options block
;; allocated, which on this code it never does: the step makes the block
;; and frees it. Only a broken step can show it built.
(define-record-type state-run
  (fields fuel loop setup registered-before blocks-before
          (mutable found state-run-found set-state-run-found!)
          (mutable built state-run-built? set-state-run-built!)
          (mutable outcome state-run-outcome set-state-run-outcome!)
          (mutable status state-run-status set-state-run-status!)
          (mutable change state-run-change set-state-run-change!)
          (mutable change-status state-run-change-status set-state-run-change-status!))
  (protocol
   (lambda (new)
     (lambda (fuel loop setup)
       (new fuel loop setup (registry-count) (live-count 'spawn-options)
            'no-expiry #f '(not-run) 'not-yet 'unchanged 'not-yet)))))

;; start-state-run! : state-variant exact-positive-integer uv-loop -> state-run
;; Its resumes are capped as start-run!'s are (tests/uv-sweep.sls).
(define (start-state-run! variant fuel loop)
  (let* ((setup ((state-variant-setup variant) loop))
         (run (make-state-run fuel loop setup)))
    (set-state-run-outcome!
     run
     (let-values (((outcome expired)
                   (run-capped
                    (lambda ()
                      (spawn-outcome
                       (lambda ()
                         (uv-spawn! loop (car (state-variant-program variant))
                                    (cdr (state-variant-program variant))
                                    (list (cons 'stdio (car setup)))
                                    (lambda (status signal)
                                      (collect)
                                      (set-state-run-status! run (list status signal)))))))
                    fuel
                    (lambda ()
                      (set-state-run-found!
                       run (if (> (registry-count) (state-run-registered-before run)) 'run 'not-run))
                      (set-state-run-built!
                       run (> (live-count 'spawn-options) (state-run-blocks-before run)))
                      (set-state-run-change! run (spawn-outcome (lambda () ((cadr setup) run))))))))
       outcome))
    run))

(define (state-run-finished? run)
  (and (or (not (uv-process? (state-run-outcome run)))
           (pair? (state-run-status run)))
       (or (not (equal? (state-run-change run) '(spawned)))
           (pair? (state-run-change-status run)))))

(define (state-run-seen run)
  (let ((outcome (state-run-outcome run)))
    (list (if (uv-process? outcome) '(spawned) outcome)
          (state-run-status run)
          (state-run-change run)
          (state-run-change-status run)
          ((cadddr (state-run-setup run))))))

;; state-verdict : state-variant state-run -> verdict
;; 'before, 'after or 'untouched, or else the evidence, a list. A change that
;; found the step run must also have found the options block freed.
(define (state-verdict variant run)
  (let ((seen (state-run-seen run)))
    (case (state-run-found run)
      ((no-expiry)
       (if (equal? seen (state-variant-untouched variant)) 'untouched (list 'no-expiry seen)))
      ((not-run)
       (if (equal? seen (state-variant-before variant)) 'before (list 'step-not-run seen)))
      (else
       (if (and (equal? seen (state-variant-after variant)) (not (state-run-built? run)))
           'after
           (list 'step-run (if (state-run-built? run) 'block-still-built 'block-freed)
                 seen))))))

(define (close-state-run! run)
  (for-each (lambda (h) (when (uv-handle-open? h) (uv-close! h)))
            (filter uv-handle?
                    (cons (state-run-outcome run) ((caddr (state-run-setup run)))))))

;; held : -> list
;; The options blocks, processes, registry entries, the binding's blocks and
;; the descriptors this process holds. A process handle a refused spawn
;; failed to free is a block no counter of its own sees.
(define (held)
  (list (live-count 'spawn-options) (live-count 'process) (registry-count)
        (live-count 'block) (fd-count)))

;; state-residue : list -> list
;; What is held beyond BEFORE, taken when the runs began.
(define (state-residue before) (map - (held) before))

;; with-residue : (list-of row) list -> (list-of row)
;; ROWS, the last carrying RESIDUE if any is left.
(define (with-residue rows residue)
  (if (equal? residue '(0 0 0 0 0))
      rows
      (let ((last-row (list-ref rows (- (length rows) 1))))
        (append (list-head rows (- (length rows) 1))
                (list (list (car last-row) (list 'residue residue (cadr last-row))
                            (caddr last-row)))))))

;; finish-state-batch! : state-variant (list-of state-run) exact-integer
;;                       -> (list-of (list fuel verdict))
(define (finish-state-batch! variant batch before)
  (run-until/ticking state-loop (lambda () (for-all state-run-finished? batch)) 20000)
  (let ((rows (map (lambda (run)
                     (list (state-run-fuel run) (state-verdict variant run)
                           (state-run-built? run)))
                   batch)))
    (for-each close-state-run! batch)
    (run-until state-loop (lambda () (equal? (state-residue before) '(0 0 0 0 0))) 64)
    (with-residue rows (state-residue before))))

;; finish-own-loop-run! : state-variant state-run exact-integer
;;                        -> (list-of (list fuel verdict))
;; A run on a loop of its own: waits for its child if the loop is still
;; open, then tears it down. Running the loop first takes it back from
;; another owner a change named (hand-off-loop), as the waits' timers are
;; made on it.
(define (finish-own-loop-run! variant run before)
  (let ((loop (state-run-loop run)))
    (when (uv-loop-open? loop)
      (uv-run loop 'nowait)
      (run-until/ticking loop (lambda () (state-run-finished? run)) 20000))
    (let* ((verdict (state-verdict variant run))
           (verdict (if (uv-loop-open? loop)
                        (begin
                          (close-state-run! run)
                          (let ((torn (spawn-outcome
                                       (lambda () (uv-loop-teardown! loop) 'torn-down))))
                            (if (eq? torn 'torn-down)
                                verdict
                                (list 'final-teardown torn verdict))))
                        verdict)))
      (with-residue (list (list (state-run-fuel run) verdict (state-run-built? run)))
                    (state-residue before)))))

(define (right-verdict? verdict) (memq verdict '(before after untouched)))

;; state-sweep : state-variant -> (list-of (list fuel verdict built))
;; Stops at the first run no expiry reached, at the fuel cap, or after the
;; first wrong or unfinished run. A raise between runs would abort the
;; suite, so the whole sweep is caught and its evidence handed to the rows.
(define (state-sweep variant)
  (guard (e (#t (list (list 0 (list 'sweep-raised (describe e)) #f))))
    (if (state-variant-own-loop? variant)
        (let next ((fuel 1) (rows '()))
          (let* ((before (held))
                 (run (start-state-run! variant fuel (make-uv-loop)))
                 (rows (append rows (finish-own-loop-run! variant run before))))
            (if (or (eq? (state-run-found run) 'no-expiry)
                    (= fuel spawn-max-fuel)
                    (not (right-verdict? (cadr (list-ref rows (- (length rows) 1))))))
                rows
                (next (+ fuel 1) rows))))
        (let next ((fuel 1) (batch '()) (rows '()) (before (held)))
          (let* ((run (start-state-run! variant fuel state-loop))
                 (batch (cons run batch))
                 (last? (or (eq? (state-run-found run) 'no-expiry)
                            (= fuel spawn-max-fuel))))
            (if (or last? (= (length batch) spawn-batch-size))
                (let* ((done (finish-state-batch! variant (reverse batch) before))
                       (rows (append rows done)))
                  (if (or last? (exists (lambda (row) (not (right-verdict? (cadr row)))) done))
                      rows
                      (next (+ fuel 1) '() rows (held))))
                (next (+ fuel 1) batch rows before)))))))

;; libuv keeps a descriptor per loop from the loop's first stream on,
;; /dev/null held in reserve for EMFILE (uv__stream_init), and sets up for
;; children at its first spawn. So spawn once on a pipe before any batch
;; counts descriptors.
(let* ((status 'not-yet)
       (pipe (make-uv-pipe state-loop))
       (proc (uv-spawn! state-loop "/bin/sh" '("sh" "-c" "exit 7")
                        (list (cons 'stdio (stdout-to pipe)))
                        (lambda (s g) (collect) (set! status (list s g))))))
  (run-until/ticking state-loop (lambda () (pair? status)) 20000)
  (uv-close! proc)
  (uv-close! pipe)
  (run-until state-loop
             (lambda () (for-all (lambda (h) (eq? 'closed (uv-handle-state h)))
                                 (list proc pipe)))
             64))

;; Each sweep's row runs as soon as the sweep ends, so its verdict is out
;; before the next sweep starts. On a broken build a later sweep can take the
;; process down: a spawn handed a freed loop aborts it outright, where no
;; guard can catch it. The sweeps that tear loops down run last for that
;; reason, after the row for the shared loop's own teardown.

;; state-sweeps : (list-of (cons name rows)), in the order the sweeps ran
(define state-sweeps '())

(define (run-state-sweep! variant)
  (let* ((name (state-variant-name variant))
         (rows (state-sweep variant)))
    (set! state-sweeps (append state-sweeps (list (cons name rows))))
    (test-equal (state-variant-title variant)
      '() (filter (lambda (row) (not (right-verdict? (cadr row)))) rows))))

(for-each run-state-sweep!
          (filter (lambda (v) (not (state-variant-own-loop? v))) state-variants))

;; A spawn that went wrong can leave the loop a handle it never registered,
;; which the teardown cannot close: kept for a row, not raised mid-suite.
(test-equal "the state sweeps left their loop nothing the teardown could not close"
  'torn-down (spawn-outcome (lambda () (uv-loop-teardown! state-loop) 'torn-down)))

(for-each run-state-sweep! (filter state-variant-own-loop? state-variants))

(for-each
 (lambda (sweep)
   (let ((count (lambda (v) (length (filter (lambda (row) (eq? (cadr row) v))
                                             (cdr sweep))))))
     (display "  [informational] state sweep ")
     (display (car sweep))
     (display ": ")
     (display (length (cdr sweep)))
     (display " runs, ")
     (display (count 'after))
     (display " after the spawn's step, ")
     (display (count 'before))
     (display " before it\n")))
 state-sweeps)
(display "  [informational] the replacing pipe took the closed pipe's address in ")
(display addresses-reused)
(display " runs\n")

;; every-fuel : (list-of row) -> (or 'every-fuel list)
;; Whether a sweep's rows ran at fuel 1, 2, 3, ... with none skipped. Each
;; fuel expires at a later point in the call than the one before, so a sweep
;; that skipped some could pass over the one point that matters.
(define (every-fuel rows)
  (let check ((rows rows) (fuel 1))
    (cond ((null? rows) 'every-fuel)
          ((eqv? (caar rows) fuel) (check (cdr rows) (+ fuel 1)))
          (else (list 'skipped-to (caar rows) 'at fuel)))))

;; The rows above look for wrong verdicts and must find none, which says
;; nothing unless each sweep saw its change land at every point from the
;; start of the call to its end: at every fuel from 1 to a run no expiry
;; reached. #60 also asked that some change find the options block built,
;; the last point before the step; the step now makes the block, so no
;; change can, and the drop sweeps below hold that nothing is allocated
;; before it. A spawn that succeeds has nothing after its step that its
;; changes land in, so all its runs but the last are refused; a failed
;; spawn's refusal is raised after its step, and some changes land there.
(test-equal "each state sweep saw its change land at every fuel from the start of the call, and ended in a run no expiry reached"
  (map (lambda (v) (list (state-variant-name v) 'before 'every-fuel 'untouched)) state-variants)
  (map (lambda (sweep)
         (let ((rows (cdr sweep)))
           (list (car sweep)
                 (cadr (car rows))
                 (every-fuel rows)
                 (cadr (list-ref rows (- (length rows) 1))))))
       state-sweeps))

;; --- an engine dropped during the call -------------------------------------
;; A scheduler can drop a task at its engine's expiry, as a timeout does,
;; and never resume it. Nothing after the expiry then runs: no guard's
;; handler, and no dynamic-wind exit but those taken at the suspension
;; itself. Whatever
;; uv-spawn! holds at that moment and has not handed to libuv or the loop is
;; lost. It allocated the process handle, then built the options block, and
;; only then entered the step that spawns, so a drop in between lost the
;; handle, or the handle and the options block: 124 of 190 dropped runs on
;; a473313. Now the step allocates both, builds the options block, spawns
;; and frees it. Before the step the verb holds nothing a drop can strand,
;; and after it the loop holds the process.
;;
;; Each sweep runs a spawn in an engine at rising fuel, each run on a loop
;; of its own, and drops the engine at its first expiry, noting whether the
;; step had run: the step marks the run's pipe consumed. The run then closes
;; the pipe, waits for any child the step started, and tears its loop down,
;; which must finish. It must leave interrupts enabled, and the options
;; blocks, processes, registry entries, the binding's blocks and the open
;; descriptors as it found them.
;; The second sweep's spawn is one libuv refuses before it forks, given an
;; inherited stream that was never opened, so the verb still has a refusal
;; to raise after its step, and some drops land there: the failure's
;; cleanup must be over when the step ends. A sweep stops at its first run
;; no expiry reached, at the fuel cap, or after its first wrong run.

;; A drop variant's spawn takes the run's loop and pipe and an on-exit.
;; CHILD? says whether a step that runs starts a child. UNTOUCHED is what a
;; run no expiry reached comes to: the spawn's outcome and its child's
;; exit. TITLE is the sweep's row, as for the state variants.
(define-record-type drop-variant
  (fields name title child? spawn untouched))

(define drop-variants
  (list
   (make-drop-variant
    'spawn
    "a spawn whose engine was dropped during the call left no block, process, registry entry or descriptor behind, and its loop tore down"
    #t
    (lambda (loop pipe on-exit)
      (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 7")
                 (list (cons 'stdio (stdout-to pipe)))
                 on-exit))
    '(spawned (7 #f)))
   (make-drop-variant
    'refused-by-libuv
    "a spawn libuv refused, its engine dropped during the call, left no block, process, registry entry or descriptor behind, and its loop tore down"
    #f
    (lambda (loop pipe on-exit)
      (uv-spawn! loop "/bin/cat" '("cat")
                 (list (cons 'stdio (list (cons 'inherit-stream pipe))))
                 on-exit))
    '((errno EINVAL) not-yet))))

;; drop-run : drop-variant exact-positive-integer -> (list fuel found verdict)
;; FOUND is 'run or 'not-run, whether the step had run at the expiry, or
;; 'no-expiry. The verdict is 'dropped or 'untouched, or else the evidence.
(define (drop-run variant fuel)
  (let* ((before (held))
         (loop (make-uv-loop))
         (pipe (make-uv-pipe loop))
         (status 'not-yet)
         (found 'no-expiry)
         (outcome
          ((make-engine
            (lambda ()
              (spawn-outcome
               (lambda ()
                 ((drop-variant-spawn variant)
                  loop pipe
                  (lambda (s g) (collect) (set! status (list s g))))))))
           fuel
           (lambda (ticks v) v)
           (lambda (resume)
             (set! found (if (pipe-connected? pipe) 'run 'not-run))
             'dropped))))
    ;; A child the step started runs to its exit before the loop goes. An
    ;; engine can be dropped just after a step that spawned: a collection
    ;; that comes due inside the step is taken where it ends, and spends
    ;; fuel there.
    (when (or (uv-process? outcome)
              (and (eq? found 'run) (drop-variant-child? variant)))
      (run-until/ticking loop (lambda () (pair? status)) 20000))
    (when (uv-handle-open? pipe) (uv-close! pipe))
    (let* ((torn (spawn-outcome (lambda () (uv-loop-teardown! loop) 'torn-down)))
           (residue (state-residue before))
           (seen (list (if (uv-process? outcome) 'spawned outcome) status)))
      (list fuel found
            (cond ((not (interrupts-enabled?))
                   (enable-interrupts)
                   (list 'interrupts-left-disabled seen))
                  ((not (eq? torn 'torn-down)) (list 'teardown torn seen residue))
                  ((not (equal? residue '(0 0 0 0 0))) (list 'residue residue seen))
                  ((eq? outcome 'dropped) 'dropped)
                  ((equal? seen (drop-variant-untouched variant)) 'untouched)
                  (else (list 'untouched-but seen)))))))

;; drop-sweep : drop-variant -> (list-of (list fuel found verdict))
;; A raise between runs would abort the suite, so the whole sweep is caught
;; and its evidence handed to the rows.
(define (drop-sweep variant)
  (guard (e (#t (list (list 0 'no-expiry (list 'sweep-raised (describe e))))))
    (let next ((fuel 1) (rows '()))
      (let* ((row (drop-run variant fuel))
             (rows (cons row rows)))
        (if (or (eq? (cadr row) 'no-expiry)
                (= fuel spawn-max-fuel)
                (not (memq (caddr row) '(dropped untouched))))
            (reverse rows)
            (next (+ fuel 1) rows))))))

;; drop-sweeps : (list-of (cons name rows)), in the order the sweeps ran.
;; Each sweep's row runs as soon as the sweep ends, as the state sweeps' do.
(define drop-sweeps '())

(for-each
 (lambda (variant)
   (let* ((name (drop-variant-name variant))
          (rows (drop-sweep variant)))
     (set! drop-sweeps (append drop-sweeps (list (cons name rows))))
     (test-equal (drop-variant-title variant)
       '() (filter (lambda (row) (not (memq (caddr row) '(dropped untouched)))) rows))))
 drop-variants)

(for-each
 (lambda (sweep)
   (let ((dropped (lambda (found)
                    (length (filter (lambda (row) (and (eq? (cadr row) found)
                                                       (eq? (caddr row) 'dropped)))
                                    (cdr sweep))))))
     (display "  [informational] drop sweep ")
     (display (car sweep))
     (display ": ")
     (display (length (cdr sweep)))
     (display " runs, ")
     (display (dropped 'not-run))
     (display " dropped before the spawn's step, ")
     (display (dropped 'run))
     (display " after it\n")))
 drop-sweeps)

;; The rows above must find no wrong run, which says nothing unless each
;; sweep dropped its spawn at every fuel from 1 to a run no expiry reached.
(test-equal "each drop sweep dropped its spawn at every fuel from the start of the call, and ended in a run no expiry reached"
  '((spawn dropped every-fuel untouched) (refused-by-libuv dropped every-fuel untouched))
  (map (lambda (sweep)
         (let ((rows (cdr sweep)))
           (list (car sweep)
                 (caddr (car rows))
                 (every-fuel rows)
                 (caddr (list-ref rows (- (length rows) 1))))))
       drop-sweeps))

;; Drops after the step are where a failure's cleanup would be stranded,
;; were it left out of the step. The refused spawn raises its refusal after
;; its step, so its sweep must reach them. A spawn that succeeds may or may
;; not be dropped there: only a collection taken at the step's end spends
;; fuel after it.
(test-equal "the refused spawn's sweep dropped it after its step too, where its refusal is raised"
  'some
  (if (exists (lambda (row) (eq? (cadr row) 'run))
              (cdr (assq 'refused-by-libuv drop-sweeps)))
      'some
      'none))

;; --- a spawn whose handle block another entry holds --------------------------
;; The step registers the process before uv_spawn, with registry-add!, as a
;; constructor's step registers its handle before the init. A registration
;; refused there is answered with nothing forked: both blocks freed and no
;; pipe marked. Registered after uv_spawn, as it was, the refusal raised from
;; the step with the child running and its handle in the loop, unregistered,
;; where no teardown could close it (#68's review).
;;
;; A fresh block is never registered already, so the row makes one that is:
;; it allocates blocks of a process handle's size through the shim, leaves an
;; entry at each, and frees them, so that the shim's allocator hands one back
;; to the spawn's step (test-native.sps's seed).
;;
;; How many, and where, is glibc's doing. Its calloc hands out the oldest
;; free block of a size first, and skips the thread's cache, where the first
;; 7 frees of each size go. With 8 blocks freed in a row, a free block of a
;; process handle's size left by the suite's earlier spawns came first, and
;; CI's vendored pass spawned (2026-10-07: two runs, one on main's own code).
;; A heap seeded with 16 such blocks spawned 19 times in 20 that way. So each
;; planted block now lies between two spacers, kept until the spawn is
;; over, which stop glibc merging it with a freed neighbour, and allocating
;; squatted-blocks of these pairs takes up the older free blocks first: the
;; seeded heap spawned 0 times in 20 (.plans/spawn-drop-mutation-log.md).
;;
;; Neither memory tool hands a freed block back, Memcheck's freelist and
;; ASan's quarantine both hold it, so under either the row asks only that
;; the spawn ran and left nothing. Which run this is, under-memory-tool?
;; asks the allocator as well as the environment: asked of the environment
;; alone, a plain run that inherited ASAN_OPTIONS from a shell took the
;; weaker row, and failed a correct build, whose spawn was refused.
(define squatted-blocks 64)

;; squatted-spawn : -> list
;; A spawn made just after SQUATTED-BLOCKS handle-size blocks, each between
;; two spacers, were freed with entries left at them: whether the next
;; handle-size block the shim allocated was one of them, what came of the
;; spawn, the pipe's mark, the teardown, and what the run left.
(define (squatted-spawn)
  (let* ((before (held))
         (loop (make-uv-loop))
         (pipe (make-uv-pipe loop))
         (size (uv-handle-size (uv-process-type)))
         (pairs (let make ((i 0) (acc '()))
                  (if (= i squatted-blocks)
                      acc
                      (let* ((spacer (alloc-block size))
                             (planted (alloc-block size)))
                        (make (+ i 1) (cons (cons planted spacer) acc))))))
         (blocks (map car pairs))
         (spacers (map cdr pairs)))
    (for-each (lambda (b) (registry-add! b 'process loop 'squatter)) blocks)
    (for-each free-block! blocks)
    ;; The seed's check takes a planted block and frees it again, still
    ;; named by its entry.
    (let* ((seed (let ((next (alloc-block size)))
                   (free-block! next)
                   (if (memv next blocks) 'planted 'not-planted)))
           (status 'not-yet)
           (outcome (spawn-outcome
                     (lambda ()
                       (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 7")
                                  (list (cons 'stdio (stdout-to pipe)))
                                  (lambda (s g) (collect) (set! status (list s g))))))))
      (for-each registry-remove! blocks)
      (for-each free-block! spacers)
      (when (uv-process? outcome)
        (run-until/ticking loop (lambda () (pair? status)) 20000))
      (let* ((marked (mark pipe))
             (torn (begin (when (uv-handle-open? pipe) (uv-close! pipe))
                          (spawn-outcome (lambda () (uv-loop-teardown! loop) 'torn-down)))))
        (list seed (if (uv-process? outcome) 'spawned outcome) marked torn
              (state-residue before))))))

(if under-memory-tool?
    (test-equal "a spawn made among freed blocks that entries still name left nothing behind (a memory tool: reuse unobservable by design)"
      '(spawned marked torn-down (0 0 0 0 0))
      (cdr (squatted-spawn)))
    ;; Run outside a row, so caught here: a raise would end the suite.
    (let ((squatted (guard (e (#t (list 'raised (describe e))))
                      (squatted-spawn))))
      ;; Without its seed the row below says nothing about the code: a spawn
      ;; given a fresh block forks. This row tells the two apart.
      (test-equal "precondition: the next block of a process handle's size the shim allocated was one an entry still names"
        'planted
        (car squatted))
      (test-equal "a spawn whose handle block another entry holds is refused before it forks, leaving nothing behind"
        '((refused uv-registry-register! pointer-already-registered) unmarked torn-down (0 0 0 0 0))
        (cdr squatted))))

;; --- one pipe named twice in one spawn -------------------------------------
;; libuv opens each (pipe p dir) spec's end into p after it forks, so a pipe
;; named twice is opened twice, and the second open fails with the child
;; already running: ADR-0015 decision 5's unclassifiable state, which leaks
;; the process handle. It is refused before anything is allocated, so the
;; pipe stays free for a spawn that names it once.
(with-loop
 (lambda (loop)
   (let* ((p (make-uv-pipe loop))
          (blocks-before (live-count 'spawn-options))
          (twice (spawn-outcome
                  (lambda ()
                    (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 7")
                               (list (cons 'stdio (list (list 'pipe p 'to-child)
                                                        (list 'pipe p 'from-child))))
                               #f))))
          (mark-after-refusal (mark p))
          (status 'not-yet)
          (once (spawn-outcome
                 (lambda ()
                   (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 7")
                              (list (cons 'stdio (stdout-to p)))
                              (lambda (s g) (collect) (set! status (list s g))))))))
     (when (uv-process? once)
       (run-until/ticking loop (lambda () (pair? status)) 20000)
       (uv-close! once))
     (test-equal "a spawn naming one pipe twice is refused as already used, and the pipe stays free for a spawn naming it once"
       '((refused uv-spawn! pipe-already-used) unmarked 0 spawned (7 #f))
       (list (if (uv-process? twice) 'spawned twice)
             mark-after-refusal
             (- (live-count 'spawn-options) blocks-before)
             (if (uv-process? once) 'spawned once)
             status))
     (uv-close! p))))

;; --- an argument another thread changes during the call -------------------
;; No engine is needed for a string to change while uv-spawn! reads it:
;; another thread can, and an interrupt-free step does not hold another
;; thread off. A narrower thread turns every λ of an argument back into a,
;; over and over, while this thread widens it to all λ before each spawn. It
;; only narrows, because a race that narrows leaves the end of Chez's
;; string->utf8 answer unwritten, while one that widens writes past it and
;; would take the evidence with the heap. Each round's child must report
;; race-length characters, each an a or a λ, and exit 7.
;;
;; Each round spawns once the narrower has turned the argument's first
;; character back, so the narrower is mid-pass when the spawn reads it; a
;; round that waits race-wait-cap steps for that ends the race, naming the
;; narrower dead. The narrower spins race-spin steps after each character,
;; so that its pass outlasts the read. Without the spin a pass took about as
;; long as the read, and was often over, or its thread off the CPU, by the
;; time the read began: under load averages near 200 from other sessions,
;; 2 to 17 of 200 rounds overlapped, and the read without its copy passed.
;; With it, 167 to 182 overlapped at that load, and that read failed 184 to
;; 190 rounds. Whether a pass overlaps the read is still up to the
;; scheduler, so the row asserts only what no schedule can make fail on a
;; right answer, and an informational line counts the rounds whose child
;; reported a mix, which only an overlap produces. These callbacks do not
;; collect: an explicit collection raises while another thread is active.
;;
;; Not under Valgrind, which runs one thread at a time, so no round could
;; overlap there (tests/test-addrinfo.sps measured 0 of 200).
(define race-length 4096)
(define race-rounds 200)
(define race-wait-cap 100000000)
(define race-spin 200)

;; race-reading : list -> (or 'all-wide 'all-narrow 'mixed #f)
;; What a round's child reported, if it is one reading of the argument.
(define (race-reading seen)
  (and (equal? (list (car seen) (cadr seen)) '(ran (7 #f)))
       (let ((text (caddr seen)))
         (and (string? text)
              (= (string-length text) race-length)
              (let ((chars (string->list text)))
                (cond ((for-all (lambda (c) (char=? c #\x3bb)) chars) 'all-wide)
                      ((for-all (lambda (c) (char=? c #\a)) chars) 'all-narrow)
                      ((for-all (lambda (c) (memv c '(#\a #\x3bb))) chars) 'mixed)
                      (else #f)))))))

;; race-spawn : uv-loop string -> list
;; Spawns a child that prints ARG, and answers what came of it.
(define (race-spawn loop arg)
  (let ((pipe (make-uv-pipe loop))
        (out (make-byte-collector))
        (status 'not-yet)
        (eof 'not-yet))
    (let ((outcome
           (guard (e ((uv-invalid-argument? e)
                      (list 'refused (uv-invalid-argument-who e)
                            (uv-invalid-argument-reason e)))
                     (#t (list 'raised (describe e))))
             (uv-spawn! loop "/bin/sh"
                        (list "sh" "-c" "printf '%s' \"$1\"; exit 7" "zero" arg)
                        (list (cons 'stdio (stdout-to pipe)))
                        (lambda (s g) (set! status (list s g)))))))
      (let ((seen
             (if (uv-process? outcome)
                 (begin
                   (uv-read-start! pipe
                                   (lambda (bv start end) (collect-span! out bv start end))
                                   (lambda () (set! eof 'eof))
                                   (lambda (err) (set! eof (list 'read-error err))))
                   (run-until/ticking loop
                                      (lambda () (and (pair? status)
                                                      (not (eq? eof 'not-yet))))
                                      20000)
                   (uv-close! outcome)
                   (list 'ran status (utf8->string (collector-bytes out)) eof))
                 outcome)))
        (when (uv-handle-open? pipe) (uv-close! pipe))
        (run-until loop (lambda () (eq? 'closed (uv-handle-state pipe))) 64)
        seen))))

;; race-evidence : list -> list
;; A wrong round, without its 8 KiB report.
(define (race-evidence seen)
  (if (and (eq? (car seen) 'ran) (string? (caddr seen)))
      (let ((text (caddr seen)))
        (list 'ran (cadr seen) 'length (string-length text)
              'first-other
              (let scan ((i 0))
                (cond ((= i (string-length text)) 'none)
                      ((memv (string-ref text i) '(#\a #\x3bb)) (scan (+ i 1)))
                      (else (list i (char->integer (string-ref text i))))))))
      seen))

;; race-sweep : -> (list rounds-run (list-of bad-round) mixed-rounds)
;; Every exit, a raise included, stops the narrower and joins it. Until its
;; thread has exited, an explicit collection raises "cannot collect when
;; multiple threads are active", and the suite's last one did, under load,
;; while the narrower was on its way out after signalling it had stopped.
(define (race-sweep)
  (let* ((arg (make-string race-length #\a))
         (loop (make-uv-loop))
         (stop #f)
         (narrower
          (fork-thread
           (lambda ()
             (let narrow ()
               (unless stop
                 (let pass ((i 0))
                   (when (< i race-length)
                     (string-set! arg i #\a)
                     (let spin ((k 0)) (when (< k race-spin) (spin (+ k 1))))
                     (pass (+ i 1))))
                 (narrow)))))))
    (let ((result
           (guard (e (#t (list 0 (list (list 'raised (describe e))) 0)))
             (let round ((r 0) (bad '()) (mixed 0))
               (if (= r race-rounds)
                   (list r (reverse bad) mixed)
                   (begin
                     (let widen ((i 0))
                       (when (< i race-length)
                         (string-set! arg i #\x3bb)
                         (widen (+ i 1))))
                     (let wait ((k 0))
                       (cond ((char=? (string-ref arg 0) #\a) 'narrowing)
                             ((= k race-wait-cap)
                              (raise (list 'the-narrower-never-narrowed 'round r)))
                             (else (wait (+ k 1)))))
                     (let* ((seen (race-spawn loop arg))
                            (reading (race-reading seen)))
                       (round (+ r 1)
                              (if reading
                                  bad
                                  (cons (list r (race-evidence seen)) bad))
                              (if (eq? reading 'mixed) (+ mixed 1) mixed)))))))))
      (set! stop #t)
      (thread-join narrower)
      (uv-loop-teardown! loop)
      result)))

(if (getenv "CHEZ_LIBUV_UNDER_VALGRIND")
    (begin
      (display "  [informational] cross-thread race: skipped under Valgrind,")
      (display " which runs one thread at a time")
      (newline))
    (let ((race (race-sweep)))
      (display "  [informational] cross-thread race: ")
      (display (caddr race))
      (display " of ")
      (display (car race))
      (display " children reported the argument mid-change")
      (newline)
      (test-equal "a spawn whose argument another thread narrows during the call ran its child on one reading of it"
        (list race-rounds '())
        (list (car race) (cadr race)))))

;; --- a list another thread changes during the call --------------------------
;; tests/spawn-list-races.sls has the races, and why each is shaped as it is
;; (#66 items 2 and 3). Every call in them is refused before anything is
;; allocated, so they leave no handle, block or registry entry behind, which
;; the suite's last rows hold. The races skip under Valgrind, which runs one
;; thread at a time.
;;
;; list-race-rows is the one list of the races, each with its row's name:
;; the races run, and their rows are made, from it, so a race added to it
;; is run and gets its row.
(define list-race-rows
  '((args . "uv-spawn! refuses a call whose args another thread cuts, for the whole list or the cut one, and for nothing else")
    (args-circular . "uv-spawn! refuses a call whose args another thread makes circular, for the whole list or the circular one, and for nothing else")
    (env . "uv-spawn! refuses a call whose env another thread cuts, for the whole list or the cut one, and for nothing else")
    (options . "uv-spawn! refuses a call whose options another thread cuts, for the whole list or the cut one, and for nothing else")
    (stdio . "uv-spawn! refuses a call whose stdio list another thread cuts, for the whole list or the cut one, and for nothing else")
    (pipe-spec . "uv-spawn! refuses a call whose pipe spec another thread cuts, for the whole spec or the cut one, and for nothing else")
    (pipe-spec-head . "uv-spawn! refuses a call whose pipe spec's first pair another thread cuts, for the whole spec or the cut one, and for nothing else")
    (entry-key . "uv-spawn! refuses a call whose options entry's key another thread turns, for either key, and for nothing else")
    (spec-kind . "uv-spawn! refuses a call whose stdio spec's kind another thread turns, for either kind, and for nothing else")))

(define list-race-names (map car list-race-rows))

;; And a race defined in the library but left out of list-race-rows would
;; never run.
(test-equal "every race tests/spawn-list-races.sls defines has its row here, in its order"
  list-race-names
  (defined-list-races))

;; Each of uv-spawn!'s lists, improper or circular from the start, is
;; refused for that list. No thread is needed for this, so it runs under
;; Valgrind too; at --optimize-level 3 it runs in a child, below.
(define malformed-reasons
  '((improper-args . args-not-a-string-list) (circular-args . args-not-a-string-list)
    (improper-env . env-not-a-string-list) (circular-env . env-not-a-string-list)
    (improper-options . option-unknown) (circular-options . option-unknown)
    (improper-stdio . stdio-not-a-list) (circular-stdio . stdio-not-a-list)))

(test-equal "uv-spawn! refuses each of its lists improper or circular, for that list"
  malformed-reasons
  (guard (e (#t (list 'raised (describe e))))
    (malformed-refusals)))

(if (getenv "CHEZ_LIBUV_UNDER_VALGRIND")
    (begin
      (display "  [informational] spawn's list races: skipped under Valgrind,")
      (display " which runs one thread at a time")
      (newline))
    (let ((races (guard (e (#t (list (list 'raised (describe e)))))
                   (list-races list-race-names))))
      (for-each
       (lambda (race)
         (when (and (list? race) (= (length race) 7))
           (display "  [informational] spawn's ")
           (display (car race))
           (display " race: ")
           (display (list-ref race 4))
           (display " of ")
           (display (list-ref race 1))
           (display " calls were refused for the cut")
           (newline)))
       races)
      (for-each
       (lambda (row)
         (test-equal (cdr row)
           (list (list (car row) 0 #f))
           (list-race-verdicts races (list (car row)))))
       list-race-rows)
      ;; The rows above say nothing unless each flipper was changing its
      ;; list while the calls read it.
      (test-equal "precondition: each list race's flipper was changing the list its calls were given before the first call and after the last, and a call was refused for the cut"
        (map (lambda (name) (list name 'flipping 'flipping 'cut-seen)) list-race-names)
        (list-race-liveness races list-race-names))))

;; --- what a refused spawn allocates for its args -----------------------------
;; Counting a list allocates nothing (proper-length), where a guarded length
;; (#51's shape) allocates a guard on every call and a condition for every
;; list it refuses, which no other row sees: a guarded count refuses the
;; same lists for the same reasons. So args improper or circular must be
;; refused at what args of () cost: each call is refused at the same check,
;; for the same reason, with nothing read from its args. A difference, not
;; a figure, so it is 0 on every platform. And args that are read cost
;; their read and nothing more: a pair, a copy and its UTF-8 a string, made
;; directly by the second row. That row holds the check's NUL scan
;; (nul-free?), which allocates nothing; the scan it replaced cost a
;; refused three-string spawn 64 B. tests/uv-meter.sls is the meter.

;; refused-spawn-cost : uv-loop -> (object -> (list reason bytes))
;; A meter of one refused spawn on LOOP given its args: the reason it was
;; refused for, and the fewest bytes a call allocated. Every call is the one
;; closure CALL, which reads its args from a variable the meter assigns, so
;; that the row's own allocation is the same for each shape: a literal ()
;; folded into a closure of its own made that closure 16 B smaller.
(define (refused-spawn-cost loop)
  (let* ((args 'unset)
         (call (lambda ()
                 (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e))
                           (#t (list 'raised (describe e))))
                   (uv-spawn! loop "/nonexistent/sh" args #f)
                   'not-refused))))
    (lambda (shape)
      (set! args shape)
      (list (call) (fewest-bytes call)))))

(test-equal "a refused uv-spawn! costs as much with its args improper or circular as with args of (): counting them allocates nothing"
  '((args-not-a-string-list 0) (args-not-a-string-list 0) meter-live)
  (guard (e (#t (list 'raised (describe e))))
    (call-with-uv-loop
     (lambda (loop)
       (let* ((cost (refused-spawn-cost loop))
              (empty (cost '()))
              (improper (cost (cons "sh" "x")))
              (circular (cost (let ((l (list "sh" "x"))) (set-cdr! (cdr l) l) l))))
         (list (list (car improper) (- (cadr improper) (cadr empty)))
               (list (car circular) (- (cadr circular) (cadr empty)))
               (if (positive? (cadr empty)) 'meter-live 'meter-blind)))))))

(test-equal "a refused uv-spawn! allocates for its args their read and nothing more: a pair, a copy and its UTF-8 a string"
  '(embedded-nul 0 meter-live)
  (guard (e (#t (list 'raised (describe e))))
    (call-with-uv-loop
     (lambda (loop)
       (let* ((cost (refused-spawn-cost loop))
              (strings (list "sh" "-c" "x\x0;"))
              (empty (cost '()))
              (three (cost strings))
              (made (fewest-bytes
                     (lambda ()
                       (map (lambda (s) (string->utf8 (string-copy s))) strings)))))
         (list (car three) (- (cadr three) (cadr empty) made)
               (if (positive? made) 'meter-live 'meter-blind)))))))

;; --- the malformed lists at --optimize-level 3 -------------------------------
;; A program compiled at --optimize-level 3 compiles these libraries from
;; source at that level too, where Chez's length, car and cdr check nothing:
;; a read that counted a list with length walked a circular one forever,
;; with interrupts disabled, and read through an improper one.
;; tests/spawn-level-3-child.sps runs the malformed lists at level 3 in a
;; process of its own (tests/uv-level-3.sls kills it at its deadline, and
;; its rows then fail with killed-at-cap). The cross-thread races run at the
;; default level only; the child's header says why. The child runs
;; natively under the memory gates too, since neither tool follows a child.
(define level-3-chez (getenv "CHEZ_LIBUV_TEST_CHEZ"))
(define level-3-report
  (and level-3-chez (level-3-run level-3-chez "tests/spawn-level-3-child.sps" '())))

(if (not level-3-chez)
    (test-equal "level-3 malformed-list rows SKIPPED: CHEZ_LIBUV_TEST_CHEZ unset (run via make test)"
      'skipped 'skipped)
    (begin
      ;; The child must run at level 3, with the libraries under test
      ;; compiled there from source: a library loaded from a .so beside its
      ;; source keeps the level it was compiled at.
      (test-equal "seed: the malformed lists' child ran at --optimize-level 3, with no library under test loaded from a compiled object"
        '(3 (#f #f #f #f))
        (list (level-3-entry level-3-report 'level)
              (level-3-entry level-3-report 'objects)))
      (test-equal "at --optimize-level 3, uv-spawn! refuses each of its lists improper or circular, for that list, and never walks one forever"
        malformed-reasons
        (level-3-entry level-3-report 'malformed))))

(collect)
(test-assert "counters all zero at suite end"
  (for-all (lambda (kv) (zero? (cdr kv))) (live-counts)))
(test-equal "registry back to baseline" registry-count-at-start (registry-count))
(test-end "process")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
