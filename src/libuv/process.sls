#!r6rs
;;; (libuv process) -- uv_spawn and friends as a legible mirror (design spec
;;; v0.3 S4). A process is a HANDLE, not a stream: explicit uv-close! even
;;; after exit (ADR-0007, S6), swept by uv-loop-teardown!, kept reachable by
;;; its registry entry alone.
;;;
;;; EXIT != CLOSE (S6, vendor fact V5): on-exit stops the handle; the caller
;;; still closes it. Killed-by-SIGTERM arrives as (0 sigterm), NOT (-1 ...)
;;; -- libuv's own semantics, mirrored rather than repaired.
;;;
;;; PID VALIDITY ENDS AT THE EXIT CALLBACK (S4.5): the child is reaped by the
;;; time on-exit runs, so kill-after-exit races pid reuse. Kill before exit
;;; is the supported path.
;;;
;;; PIPE DIRECTION IS NAMED FROM THE PARENT'S SIDE (S4.3, ADR-0016):
;;; to-child = UV_READABLE_PIPE, from-child = UV_WRITABLE_PIPE, duplex =
;;; both. This is the one place v0.3 deliberately does not mirror libuv's
;;; names, whose child's-eye "readable"/"writable" are its single most
;;; direction-confusing vocabulary and whose failure mode is a silent
;;; direction bug.
;;;
;;; A FAILED SPAWN CONSUMES ITS PIPES (S4.3 as amended, ADR-0015 decision 6).
;;; libuv creates the socketpairs before it forks, so on the exec-failure
;;; class the parent ends are genuinely open by the time uv_spawn returns
;;; (spike FINDINGS SQ1 Observation 3); the binding marks every pipe named in
;;; ANY stdio spec -- (pipe h dir) OR (inherit-stream . h) -- connected on
;;; BOTH paths, uniformly (Task 9 widened this from (pipe ...)-only once the
;;; setup-class scenario's own record-level assertion showed the two forms
;;; had drifted), because under-reporting connectedness is what would let a
;;; later spawn hand libuv an already-opened stream. So the recovery pattern
;;; after a raising uv-spawn! is close-and-remake, never retry-with-the-same-
;;; pipes, and the caller still closes those pipes -- not doing so leaks one
;;; fd per slot per attempt, with no EMFILE to announce it. On the SETUP
;;; class the fd behind the mark is not necessarily real (S4.3's own
;;; caveat) -- the mark is a conservative reuse-refusal, not a claim about
;;; what libuv actually opened.
;;;
;;; THE TWO RULES OF EVERY START CALL (tcp.sls's, verbatim): every argument
;;; is validated before the first allocation, and a failed native call
;;; leaves nothing half-built (S5.5, S5.6).
;;;
;;; EXIT AND WALK DISPATCH POLICY LIVES HERE (the dns.sls late-install
;;; precedent): native.sls carries the two mechanical trampolines, and the
;;; dispatchers below are installed through install-dispatch-procedure! at
;;; THIS library's body time. A process image that never imports
;;; (libuv process) keeps the contained raising stubs for both names, and
;;; nothing can spawn without the import (S5.2, S5.4, ADR-0015).
(library (libuv process)
  (export uv-spawn! uv-process-kill! uv-kill! uv-process-pid uv-os-getpid)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))

  ;; --- argument predicates ------------------------------------------------
  ;; NUL validation (S5.5, S4.7's 'embedded-nul row): an embedded NUL
  ;; silently truncates at the C boundary (spike-measured, v0.2 FINDINGS) --
  ;; the C callee would see only a prefix, which is how "/bin/sh\x0;-rf"
  ;; becomes /bin/sh. Refused by name rather than silently honoured.
  ;;
  ;; The type check raises the CALLER'S reason symbol (file-not-a-string,
  ;; args-not-a-string-list, ...) while the NUL scan always raises
  ;; 'embedded-nul: S4.7 gives every string position its own type reason but
  ;; one shared NUL reason.
  (define (require-nul-free-string s who type-reason)
    (unless (string? s)
      (raise (make-uv-invalid-argument who type-reason)))
    (let scan ((i 0))
      (when (< i (string-length s))
        (when (char=? #\nul (string-ref s i))
          (raise (make-uv-invalid-argument who 'embedded-nul)))
        (scan (+ i 1)))))

  ;; args is the COMPLETE argv INCLUDING argv[0] (S4.1), so an empty list is
  ;; a caller error rather than a defaulted-to-file convenience: libuv passes
  ;; the array through unmodified and argv[0] tricks stay possible, which is
  ;; only true if the binding never invents one.
  (define (require-string-list lst who reason)
    (unless (and (list? lst) (pair? lst))
      (raise (make-uv-invalid-argument who reason)))
    (for-each (lambda (s) (require-nul-free-string s who reason)) lst))

  ;; uid/gid: exact integers in [0, 2^32) (S4.2's table, reasons named
  ;; there). The width matches uv_uid_t/uv_gid_t, which are 32-bit on Unix --
  ;; the same range c-u32-set! enforces at the boundary.
  (define (require-u32 n who reason)
    (unless (and (integer? n) (exact? n) (>= n 0) (< n 4294967296))
      (raise (make-uv-invalid-argument who reason))))

  ;; A process handle, and open. Mirrors require-open-stream/require-open-tcp
  ;; (stream.sls, tcp.sls): kind check first, state check second, different
  ;; conditions -- a process is a HANDLE, not a stream (S5.1), so it gets its
  ;; own gate rather than joining uv-stream-record?'s hierarchy. A closed
  ;; process handle still answers &uv-handle-closed with kind 'process.
  (define (require-open-process proc who)
    (unless (uv-process-record? proc)
      (raise (make-uv-invalid-argument who 'not-a-uv-process)))
    (require-open-handle proc who)
    proc)

  ;; --- the options alist (S4.2): a closed key set --------------------------
  ;; Omitted, #f, and '() all mean "defaults" (the uv-getaddrinfo! hints
  ;; precedent). An unknown key is refused BY NAME, and a malformed alist
  ;; entry is 'option-unknown too -- it is not any known option.
  (define option-keys '(env cwd stdio detached uid gid))

  ;; The parsed view every later step consumes. A named accessor per field
  ;; rather than (cadr (cddddr parsed)) at the use sites: the block builder
  ;; reads all six, and a positional mix-up there would write a cwd into the
  ;; env slot without any type in the program disagreeing.
  (define (parsed-env parsed)       (list-ref parsed 0))
  (define (parsed-cwd parsed)       (list-ref parsed 1))
  (define (parsed-stdio parsed)     (list-ref parsed 2))
  (define (parsed-detached? parsed) (list-ref parsed 3))
  (define (parsed-uid parsed)       (list-ref parsed 4))
  (define (parsed-gid parsed)       (list-ref parsed 5))

  (define (validate-options options who)
    (unless (list? options)
      (raise (make-uv-invalid-argument who 'option-unknown)))
    (for-each
     (lambda (entry)
       (unless (and (pair? entry) (memq (car entry) option-keys))
         (raise (make-uv-invalid-argument who 'option-unknown))))
     options)
    ;; Duplicates are refused, not first-wins. The assq reads below take the
    ;; FIRST entry per key, so a second entry would be silently ignored
    ;; WITHOUT VALIDATION -- '((cwd . "/") (cwd . 7)) validated clean while
    ;; carrying a malformed member. Refusing is also the only unambiguous
    ;; answer to which of two agreeing-in-type entries the caller meant.
    (let dup-scan ((entries options) (seen '()))
      (unless (null? entries)
        (let ((key (caar entries)))
          (when (memq key seen)
            (raise (make-uv-invalid-argument who 'option-duplicate)))
          (dup-scan (cdr entries) (cons key seen)))))
    (let ((env      (assq 'env options))
          (cwd      (assq 'cwd options))
          (stdio    (assq 'stdio options))
          (detached (assq 'detached options))
          (uid      (assq 'uid options))
          (gid      (assq 'gid options)))
      (when env
        ;; env mirrors libuv's own "K=V" array format (S4.2): the binding
        ;; invents no alist encoding and parses none of the strings
        ;; (ADR-0012's never-invent rule applied to a value format). Only the
        ;; NUL trap is policed. An empty env list is explicitly permitted:
        ;; absent env inherits the parent's (options.env NULL), while '() gives
        ;; the child an empty environment (a NULL-terminated empty array).
        (unless (list? (cdr env))
          (raise (make-uv-invalid-argument who 'env-not-a-string-list)))
        (for-each (lambda (s)
                    (require-nul-free-string s who 'env-not-a-string-list))
                  (cdr env)))
      (when cwd (require-nul-free-string (cdr cwd) who 'cwd-not-a-string))
      (when detached
        (unless (boolean? (cdr detached))
          (raise (make-uv-invalid-argument who 'detached-not-a-boolean))))
      (when uid (require-u32 (cdr uid) who 'uid-out-of-range))
      (when gid (require-u32 (cdr gid) who 'gid-out-of-range))
      (when stdio
        (unless (list? (cdr stdio))
          (raise (make-uv-invalid-argument who 'stdio-not-a-list)))
        (for-each (lambda (spec) (validate-stdio-spec spec who)) (cdr stdio)))
      (list (and env (cdr env))
            (and cwd (cdr cwd))
            (if stdio (cdr stdio) '())
            (and detached (cdr detached))
            (and uid (cdr uid))
            (and gid (cdr gid)))))

  ;; --- stdio specs (S4.3) --------------------------------------------------
  ;; ignore | (inherit-fd . n) | (inherit-stream . h) | (pipe h dir), where
  ;; dir is to-child / from-child / duplex (the parent's-side vocabulary the
  ;; header explains). Index in the list = child fd: 0 stdin, 1 stdout, 2
  ;; stderr; fewer than three is fine (libuv pads 0-2 to UV_IGNORE, V4) and
  ;; more passes extra fds to the child in order.
  ;;
  ;; CLOSED SET WITH A KEPT-RAISING ELSE ARM (tcp.sls's convention): a spec
  ;; matching no form above is 'stdio-spec-unknown rather than a slot libuv
  ;; is handed with whatever flags happened to be zero.
  (define (validate-stdio-spec spec who)
    (cond
      ((eq? spec 'ignore) #t)
      ((and (pair? spec) (eq? 'inherit-fd (car spec)))
       ;; Upper bound: the container's data field is a C int, so nothing
       ;; >= 2^31 can be an fd. Without this clause the value survived to
       ;; c-int-set! mid-build and escaped as a raw Chez range condition
       ;; (freed, not leaked -- but not the uniform &uv-invalid-argument
       ;; every other refusal in this walk raises).
       (let ((fd (cdr spec)))
         (unless (and (integer? fd) (exact? fd) (>= fd 0)
                      (< fd 2147483648))
           (raise (make-uv-invalid-argument who 'stdio-fd-not-an-fd)))))
      ((and (pair? spec) (eq? 'inherit-stream (car spec)))
       (let ((h (cdr spec)))
         (unless (uv-stream-record? h)
           (raise (make-uv-invalid-argument who 'stdio-spec-unknown)))
         (require-open-handle h who)))
      ((and (list? spec) (= 3 (length spec)) (eq? 'pipe (car spec)))
       (let ((p (cadr spec)) (dir (caddr spec)))
         (unless (uv-pipe-record? p)
           (raise (make-uv-invalid-argument who 'stdio-spec-unknown)))
         (require-open-handle p who)
         ;; Connected means "already consumed by a spawn" -- including a
         ;; FAILED one (ADR-0015 decision 6). This check is also what
         ;; forecloses the one state ADR-0015's pid guard could otherwise
         ;; have to catch: uv__stream_open answers UV_EBUSY for an
         ;; already-connected target (vendor/libuv/src/unix/stream.c:407-408).
         (when (pipe-connected? p)
           (raise (make-uv-invalid-argument who 'pipe-already-used)))
         (unless (memq dir '(to-child from-child duplex))
           (raise (make-uv-invalid-argument who 'stdio-spec-unknown)))))
      (else (raise (make-uv-invalid-argument who 'stdio-spec-unknown)))))

  ;; The handle a spec names, or #f for the two specs that name none. One
  ;; place decides that, so the loop check and the connected-marking walk
  ;; cannot drift apart in what they consider a handle-bearing spec.
  (define (stdio-spec-handle spec)
    (cond ((and (pair? spec) (eq? 'inherit-stream (car spec))) (cdr spec))
          ((and (list? spec) (pair? spec) (eq? 'pipe (car spec))) (cadr spec))
          (else #f)))

  ;; The cross-loop check needs the spawn's loop, which validate-stdio-spec
  ;; does not have, so it runs immediately after it (S4.3: 'pipe-wrong-loop)
  ;; and still before the first allocation.
  (define (require-same-loop-stdio! specs loop who)
    (for-each
     (lambda (spec)
       (let ((h (stdio-spec-handle spec)))
         (when (and h (not (eq? (handle-loop h) loop)))
           (raise (make-uv-invalid-argument who 'pipe-wrong-loop)))))
     specs))

  ;; ADR-0015 decision 6: consumed on BOTH paths, so this runs once,
  ;; unconditionally, rather than twice with the same body. Uses
  ;; stdio-spec-handle (Task 9 fix; see below) rather than its own narrower
  ;; (pipe h dir)-only match: a pipe named through (inherit-stream . h) is
  ;; every bit as much "named in a raising spawn's stdio specs" as one named
  ;; through (pipe h dir) (S4.3's amended wording), and stdio-spec-handle's
  ;; own header comment already claimed this walk as its second caller
  ;; before the code agreed. inherit-stream also accepts tcp handles, which
  ;; have no connected? field, so the guard is uv-pipe-record? rather than
  ;; "has a handle at all".
  (define (mark-consumed-pipes! specs)
    (for-each
     (lambda (spec)
       (let ((h (stdio-spec-handle spec)))
         (when (and h (uv-pipe-record? h))
           (set-pipe-connected! h #t))))
     specs))

  ;; Every bit comes from the shim's table (ADR-0005), never a transcribed
  ;; literal, and only these six can ever be OR'd -- which is what makes
  ;; libuv's own unknown-flag assert unreachable from Scheme (V8).
  (define (stdio-spec-flags spec)
    (cond
      ((eq? spec 'ignore) (uv-stdio-ignore))
      ((eq? 'inherit-fd (car spec)) (uv-stdio-inherit-fd))
      ((eq? 'inherit-stream (car spec)) (uv-stdio-inherit-stream))
      (else ;; (pipe h dir)
       (bitwise-ior (uv-stdio-create-pipe)
                    (case (caddr spec)
                      ((to-child)   (uv-stdio-readable-pipe))
                      ((from-child) (uv-stdio-writable-pipe))
                      ((duplex)     (bitwise-ior (uv-stdio-readable-pipe)
                                                 (uv-stdio-writable-pipe)))
                      ;; validate-stdio-spec ran first, so this is
                      ;; unreachable -- and kept raising, per the house
                      ;; convention, because the alternative is a slot whose
                      ;; direction silently defaults.
                      (else (raise (make-uv-invalid-argument
                                    'uv-spawn! 'stdio-spec-unknown))))))))

  ;; --- the co-allocated options block (S5.5, ADR-0015 decision 1) ---------
  ;; ONE foreign-alloc holds, in order: the uv_process_options_t, the
  ;; uv_stdio_container_t array, the argv pointer array, the env pointer
  ;; array, and every string's UTF-8 bytes. Zeroed, so every absent field is
  ;; already NULL/0, every pointer array's terminating NULL is the slot
  ;; already there, and every string's NUL terminator is the zeroed gap after
  ;; its bytes.
  ;;
  ;; It is freed unconditionally the instant uv_spawn returns: libuv consumes
  ;; everything synchronously and copies only exit_cb and pid into the handle
  ;; (V1, vendor/libuv/src/unix/process.c:1054). One alloc site, one free
  ;; site, no conditional -- the uv-write! discipline, and ADR-0009's
  ;; boundary applied to a struct instead of a payload. The counter pair
  ;; around those two sites is what makes an early return that skips the free
  ;; a definite leak under make test-memory.
  ;;
  ;; All arithmetic is exact integers; REGIONS are align-16'd (stricter than
  ;; any field needs -- one rule, no per-field cases).
  (define (utf8-size s) (+ 1 (bytevector-length (string->utf8 s))))

  (define (build-options-block parsed file args)
    (let* ((env         (parsed-env parsed))
           (cwd         (parsed-cwd parsed))
           (specs       (parsed-stdio parsed))
           (ptr-size    (c-uptr-size))
           (n-stdio     (length specs))
           (stdio-off   (align-16 (sizeof-uv-process-options-t)))
           (argv-off    (align-16 (+ stdio-off
                                     (* n-stdio (sizeof-uv-stdio-container-t)))))
           (env-off     (align-16 (+ argv-off (* (+ 1 (length args)) ptr-size))))
           (strings-off (align-16 (+ env-off
                                     (if env (* (+ 1 (length env)) ptr-size) 0))))
           (strings-size (+ (utf8-size file)
                            (if cwd (utf8-size cwd) 0)
                            (fold-left + 0 (map utf8-size args))
                            (if env (fold-left + 0 (map utf8-size env)) 0)))
           (block (alloc-zeroed (+ strings-off strings-size))))
      (count-spawn-options-new!)
      ;; Nothing below can fail against inputs validate-options already
      ;; accepted -- but the block is live from the line above, so a raise
      ;; here would leak it past the counter that exists to notice. Same
      ;; guard shape, and same reason, as make-uv-pipe's around uv_pipe_init.
      (guard (e (#t (free-options-block! block) (raise e)))
        (fill-strings-and-arrays! block parsed file args
                                  argv-off env-off strings-off ptr-size)
        (fill-stdio-containers! block specs stdio-off)
        (fill-scalars! block parsed n-stdio stdio-off)
        block)))

  ;; file / cwd / argv / env, plus the two pointer arrays that index into the
  ;; string area. The cursor walks the string region once, in write order;
  ;; put-string! answers the ABSOLUTE address it wrote at, which is what goes
  ;; into the struct field or the array slot.
  (define (fill-strings-and-arrays! block parsed file args
                                    argv-off env-off strings-off ptr-size)
    (let ((env (parsed-env parsed))
          (cwd (parsed-cwd parsed))
          (cursor strings-off))
      (define (put-string! s)
        (let* ((bv (string->utf8 s))
               (at (+ block cursor)))
          (copy-in! at bv 0 (bytevector-length bv))
          (set! cursor (+ cursor (bytevector-length bv) 1))
          at))
      (c-uptr-set! (+ block (offsetof-uv-process-options-t-file))
                   (put-string! file))
      (when cwd
        (c-uptr-set! (+ block (offsetof-uv-process-options-t-cwd))
                     (put-string! cwd)))
      (let arg-loop ((as args) (i 0))
        (unless (null? as)
          (c-uptr-set! (+ block argv-off (* i ptr-size)) (put-string! (car as)))
          (arg-loop (cdr as) (+ i 1))))
      ;; The terminating NULL of each array is the zeroed slot already there.
      (c-uptr-set! (+ block (offsetof-uv-process-options-t-args))
                   (+ block argv-off))
      (when env
        (let env-loop ((es env) (i 0))
          (unless (null? es)
            (c-uptr-set! (+ block env-off (* i ptr-size)) (put-string! (car es)))
            (env-loop (cdr es) (+ i 1))))
        ;; Left NULL when env is absent, which is exactly how libuv is told
        ;; to hand the child the parent's environment (S4.2).
        (c-uptr-set! (+ block (offsetof-uv-process-options-t-env))
                     (+ block env-off)))))

  ;; The stdio containers: flags as an int at +FLAGS, and the union at +DATA
  ;; written at the width its member has -- an fd as a 32-bit int, a stream
  ;; as a pointer (V2). Writing an fd pointer-wide would also clear the
  ;; union's high bytes, which is indistinguishable from correct on LP64
  ;; until it is not.
  (define (fill-stdio-containers! block specs stdio-off)
    (let stdio-loop ((ss specs) (i 0))
      (unless (null? ss)
        (let ((c (+ block stdio-off (* i (sizeof-uv-stdio-container-t))))
              (spec (car ss)))
          (c-int-set! (+ c (offsetof-uv-stdio-container-t-flags))
                      (stdio-spec-flags spec))
          (cond
            ((eq? spec 'ignore) #f)
            ((eq? 'inherit-fd (car spec))
             (c-int-set! (+ c (offsetof-uv-stdio-container-t-data)) (cdr spec)))
            ((eq? 'inherit-stream (car spec))
             (c-uptr-set! (+ c (offsetof-uv-stdio-container-t-data))
                          (handle-pointer (cdr spec) 'uv-spawn!)))
            (else ;; (pipe h dir)
             (c-uptr-set! (+ c (offsetof-uv-stdio-container-t-data))
                          (handle-pointer (cadr spec) 'uv-spawn!)))))
        (stdio-loop (cdr ss) (+ i 1)))))

  ;; stdio_count / stdio, the flag word, and uid/gid.
  ;;
  ;; UID/GID PRESENCE IMPLIES THE FLAG (S4.2). libuv ignores options.uid
  ;; unless UV_PROCESS_SETUID is set; that split is a documented footgun, and
  ;; closing it at the public boundary means "field set, flag clear" cannot
  ;; be expressed at all rather than merely being discouraged.
  (define (fill-scalars! block parsed n-stdio stdio-off)
    (let ((uid (parsed-uid parsed))
          (gid (parsed-gid parsed)))
      (c-int-set! (+ block (offsetof-uv-process-options-t-stdio-count)) n-stdio)
      (when (positive? n-stdio)
        (c-uptr-set! (+ block (offsetof-uv-process-options-t-stdio))
                     (+ block stdio-off)))
      (c-int-set! (+ block (offsetof-uv-process-options-t-flags))
                  (bitwise-ior
                   (if (parsed-detached? parsed) (uv-process-detached-flag) 0)
                   (if uid (uv-process-setuid-flag) 0)
                   (if gid (uv-process-setgid-flag) 0)))
      (when uid (c-u32-set! (+ block (offsetof-uv-process-options-t-uid)) uid))
      (when gid (c-u32-set! (+ block (offsetof-uv-process-options-t-gid)) gid))))

  (define (free-options-block! block)
    (free! block)
    (count-spawn-options-free!))

  ;; --- uv-spawn! (S4.1, S5.5) ----------------------------------------------
  ;; (uv-spawn! loop file args on-exit)
  ;; (uv-spawn! loop file args options on-exit)
  ;;
  ;; on-exit is a procedure or #f, and #f is SURFACE-ONLY (S4.1): the exit
  ;; trampoline is always baked into the options block by uv-spawn-native,
  ;; NULL is never written, and #f merely means the dispatcher runs the
  ;; lifecycle machinery without a user callback. The argument position is
  ;; always present, so the two arities stay unambiguous exactly as
  ;; uv-getaddrinfo!'s optional hints do.
  (define uv-spawn!
    (case-lambda
      ((loop file args on-exit)
       (start-spawn! loop file args '() on-exit))
      ((loop file args options on-exit)
       (start-spawn! loop file args (or options '()) on-exit))))

  (define (start-spawn! loop file args options on-exit)
    (ensure-native-loaded!)
    ;; EVERY CHECK FIRST, THE FIRST ALLOCATION AFTER ALL OF THEM (S5.5 step
    ;; 1). The ordering property itself is enforced by the memory lane: a
    ;; mis-ordered implementation leaks the handle or the options block on
    ;; the raise path and fails valgrind.
    (require-open-loop loop 'uv-spawn!)
    (require-nul-free-string file 'uv-spawn! 'file-not-a-string)
    (require-string-list args 'uv-spawn! 'args-not-a-string-list)
    (unless (or (not on-exit) (procedure? on-exit))
      (raise (make-uv-invalid-argument 'uv-spawn! 'on-exit-not-a-procedure)))
    (let ((parsed (validate-options options 'uv-spawn!)))
      (require-same-loop-stdio! (parsed-stdio parsed) loop 'uv-spawn!)
      ;; Step 2: the handle block and its record. on-exit is stored NOW,
      ;; because the callback travels inside uv_process_options_t and the
      ;; child can be running before uv_spawn returns. Not registered, not
      ;; counted yet -- nothing is findable until libuv has said yes (or
      ;; until ADR-0015's exec-class arm needs it findable in order to
      ;; close it).
      (let* ((ptr (alloc-zeroed (uv-handle-size (uv-process-type))))
             (proc (%make-uv-process-record ptr loop on-exit))
             ;; Step 3: the one co-allocated options block. A raise from the
             ;; builder frees only its own block, so the handle is freed
             ;; here -- nothing registered, nothing counted, nothing left.
             (block (guard (e (#t (free! ptr) (raise e)))
                      (build-options-block parsed file args))))
        ;; Step 4: spawn. Step 5: free the block, unconditionally.
        (let ((rc (uv-spawn-native (loop-pointer loop 'uv-spawn!) ptr block)))
          (free-options-block! block)
          ;; ADR-0015 decision 6, one site for both paths: libuv opens the
          ;; parent ends of the socketpairs it created before it forks, so a
          ;; consumed pipe is consumed whatever uv_spawn answered.
          (mark-consumed-pipes! (parsed-stdio parsed))
          (if (zero? rc)
              ;; Step 6: only now does anything become findable.
              (begin
                (registry-register! ptr 'process loop proc)
                (count-process-new!)
                proc)
              (begin
                (clean-up-failed-spawn! loop proc)
                ;; Nothing escapes but the condition: no record is returned,
                ;; no on-exit can fire for it, the options block is already
                ;; gone (ADR-0015 decision 4).
                (uv-check rc 'uv-spawn!)))))))

  ;; --- the spawn failure path (S5.6, ADR-0015 decision 2) ------------------
  ;; THE CLASS IS DECIDED BY ASKING THE LOOP, NEVER BY THE ERRNO. libuv has
  ;; two exits from uv_spawn with opposite correct cleanups:
  ;;
  ;;   * an EXEC failure (the child's execvp failed and the errno came back
  ;;     over libuv's error pipe) falls off the end at process.c:1073 with
  ;;     the handle STILL LINKED into loop->handle_queue. uv_close-then-free
  ;;     is correct; a direct free leaves the loop permanently EBUSY and a
  ;;     dangling queue node the next spawn writes through (402 valgrind
  ;;     errors, 576 bytes definitely lost).
  ;;   * a SETUP failure leaves through the error: label (process.c:1075),
  ;;     whose first statement unlinks the handle. A direct free is correct;
  ;;     uv_close there silently splices a LATER-registered live handle out
  ;;     of the queue and still answers uv_loop_close 0.
  ;;
  ;; The two classes' errno sets overlap on both sides of the fork (UV_ENOMEM
  ;; and EMFILE/ENFILE arise in each), so an errno table would be a guess
  ;; whose wrong answers are a permanently-EBUSY loop or a silently-spliced
  ;; live handle. uv_walk is the property's measured instrument and the one
  ;; this binding ships, through handles.sls's handle-in-loop-queue?.
  (define (clean-up-failed-spawn! loop proc)
    ;; ADR-0015 decision 5: the state the spike could NOT measure -- exec
    ;; succeeded, a later uv__process_open_stream failed (process.c:1056-1067)
    ;; -- leaves the handle unlinked AND started with a live child, where
    ;; neither arm below is correct. AGENTS.md prefers a check to a comment,
    ;; so the path asserts the state rather than the reasoning: pid is only
    ;; written at process.c:1053, once the exec succeeded, so a nonzero pid
    ;; here means exactly that state. It raises loudly and leaves the handle
    ;; DELIBERATELY UNTOUCHED -- a leaked handle block is recoverable and
    ;; diagnosable; queue corruption and use-after-free are neither.
    (unless (zero? (uv-process-get-pid (handle-pointer proc 'uv-spawn!)))
      (raise (make-uv-invalid-argument 'uv-spawn!
                                       'spawn-failure-state-unclassifiable)))
    (if (handle-in-loop-queue? loop proc)
        ;; Exec class. REGISTERING IS PART OF CLOSING in this binding
        ;; (ADR-0015 decision 3): close-dispatch resolves the firing pointer
        ;; through the registry and is the only place a handle pointer is
        ;; freed, so an unregistered pointer would be filed as an orphan and
        ;; never freed at all. The free is therefore ASYNCHRONOUS -- the
        ;; caller's next uv-run or uv-loop-teardown! reclaims it and bumps
        ;; count-process-free!, exactly like every other uv-close! in this
        ;; binding (ADR-0007).
        (begin
          (registry-register! (handle-pointer proc 'uv-spawn!) 'process loop proc)
          (count-process-new!)
          (close-handle! proc))
        ;; Setup class: already unlinked, so no close callback will ever
        ;; arrive. handles.sls owns the direct free, for the same reason it
        ;; owns close-dispatch's.
        (discard-failed-handle! proc)))

  ;; --- signals (§4.5, ADR-0016) --------------------------------------------
  ;; A closed symbol set, values from the shim (ADR-0005: SIGTERM's number
  ;; is never written here), plus exact 0 -- the POSIX liveness probe
  ;; (kill(pid,0), V9). Symbols only otherwise: 15 is refused even though
  ;; it is SIGTERM everywhere, because "everywhere" is how transcription
  ;; bugs start. Lifts to (libuv private native) on its second user
  ;; (the PR #4 rule) -- today process.sls is the only one.
  ;; signal-symbol->int / term-signal->value moved to (libuv private native)
  ;; on their second user, (libuv signal) -- ADR-0016's own lift rule, ADR-0017.

  ;; (uv-process-kill! proc sig) -- by handle. On Unix this is literally
  ;; uv_kill(handle->pid, sig) (V9). Success returns unspecified; failure
  ;; raises the errno symbol ('ESRCH after reaping -- see the pid-validity
  ;; header note).
  (define (uv-process-kill! proc sig)
    (require-open-process proc 'uv-process-kill!)
    (let ((signum (signal-symbol->int sig 'uv-process-kill!)))
      (uv-check (uv-process-kill (handle-pointer proc 'uv-process-kill!)
                                 signum)
                'uv-process-kill!)))

  ;; (uv-kill! pid sig) -- by raw pid; the escape hatch for pids learned
  ;; elsewhere. The pid is validated as an exact integer (the FFI declares
  ;; int; an inexact or non-number would be a marshalling crash) but NOT
  ;; range-policed: negative pids are kill(2)'s process-group vocabulary,
  ;; passed through -- the mirror rule.
  (define (uv-kill! pid sig)
    (unless (and (integer? pid) (exact? pid))
      (raise (make-uv-invalid-argument 'uv-kill! 'pid-not-an-exact-integer)))
    (let ((signum (signal-symbol->int sig 'uv-kill!)))
      (uv-check (uv-kill pid signum) 'uv-kill!)))

  ;; (uv-process-pid proc) -- valid between spawn and close, exit included
  ;; (§4.5): the handle memory holds the pid until the close dispatcher
  ;; frees it, and require-open-process is what enforces the window.
  (define (uv-process-pid proc)
    (require-open-process proc 'uv-process-pid)
    (uv-process-get-pid (handle-pointer proc 'uv-process-pid)))

  ;; (uv-os-getpid) -- this process's OWN pid, through the init gate like
  ;; every public nullary query (the uv-version precedent: the answer must
  ;; come from a library this binding has validated). It lives here beside
  ;; uv-process-pid because pid vocabulary is this module's (ADR-0017 D8);
  ;; the suites' self-delivery ((uv-kill! (uv-os-getpid) 'sigusr1)) is its
  ;; first consumer.
  (define (uv-os-getpid)
    (ensure-native-loaded!)
    (uv-os-getpid-native))

  ;; --- the exit dispatcher (S5.4) ------------------------------------------
  ;; uv_exit_cb: void (*)(uv_process_t *, int64_t exit_status, int
  ;; term_signal). Runs inside handles.sls's seam guard.
  ;;
  ;; NO HANDLE STATE CHECK, deliberately -- the request-dispatcher tolerance
  ;; rule (design spec S5): an exit queued behind a uv_close still deserves
  ;; delivery. NOTHING IS FREED HERE either: exit stops the handle, and the
  ;; close dispatcher remains the only place process memory dies (ADR-0007).

  ;; The three arms are S5.4's steps 1-2, and the middle one is why this
  ;; dispatcher is not shaped like timer-dispatch: an UNREGISTERED pointer
  ;; has no loop and therefore no error cell, which is precisely what the
  ;; orphan list exists for; a pointer that IS registered but resolves to
  ;; something other than a process record has a loop, so raising into the
  ;; seam's containment reports it through the documented &uv-callback-error
  ;; channel instead of a list nobody reads.
  (define (exit-dispatch handle-ptr exit-status term-signal)
    (let ((proc (registry-ref handle-ptr)))
      (cond
        ((not proc) (record-orphan-callback! 'exit handle-ptr))
        ((not (uv-process-record? proc))
         (raise (condition
                 (make-uv-error)
                 (make-who-condition 'uv-exit-dispatch)
                 (make-message-condition
                  "exit completion for a handle of another kind"))))
        (else
         ;; The two ints become Scheme values, then the flag the lifecycle
         ;; scenarios observe, and the user's callback runs LAST -- so a
         ;; callback that raises cannot leave exited? unset.
         (let ((sig (term-signal->value term-signal))
               (on-exit (process-on-exit proc)))
           (set-process-exited! proc #t)
           (when on-exit
             (dispatch-guarded (handle-loop proc)
                               (lambda () (on-exit exit-status sig)))))))))

  ;; --- the two late installs (S5.2, S5.4, ADR-0015) ------------------------
  ;; The once-per-name seam (the dns.sls precedent): each slot held
  ;; handles.sls's contained raising stub until this instant and can never be
  ;; rebound after it. walk-dispatch is handles.sls's own closure over the
  ;; query cell that backs handle-in-loop-queue? -- exported there, installed
  ;; here, because the failure path above is its only consumer and a program
  ;; that never imports this library has no use for it.
  (define exit-dispatch-installed
    (install-dispatch-procedure! 'exit exit-dispatch))

  (define walk-dispatch-installed
    (install-dispatch-procedure! 'walk walk-dispatch)))
