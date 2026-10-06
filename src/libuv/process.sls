#!r6rs
;;; Child processes remain handles after exit and still require uv-close!.
;;; Stdio pipe directions are named from the parent: to-child, from-child,
;;; or duplex. A failed spawn consumes every pipe it was given.
(library (libuv process)
  (export uv-spawn! uv-process-kill! uv-kill! uv-process-pid uv-os-getpid)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))

  ;; Embedded NUL would silently truncate a string at the C boundary.
  (define (require-nul-free-string s who type-reason)
    (unless (string? s)
      (raise (make-uv-invalid-argument who type-reason)))
    (let scan ((i 0))
      (when (< i (string-length s))
        (when (char=? #\nul (string-ref s i))
          (raise (make-uv-invalid-argument who 'embedded-nul)))
        (scan (+ i 1)))))

  ;; args is the complete non-empty argv, including argv[0].
  (define (require-string-list lst who reason)
    (unless (and (list? lst) (pair? lst))
      (raise (make-uv-invalid-argument who reason)))
    (for-each (lambda (s) (require-nul-free-string s who reason)) lst))

  (define (require-u32 n who reason)
    (unless (and (integer? n) (exact? n) (>= n 0) (< n 4294967296))
      (raise (make-uv-invalid-argument who reason))))

  (define (require-open-process proc who)
    (unless (uv-process-record? proc)
      (raise (make-uv-invalid-argument who 'not-a-uv-process)))
    (require-open-handle proc who)
    proc)

  (define option-keys '(env cwd stdio detached uid gid))

  ;; Keep one positional representation private to the block builder.
  (define (parsed-env parsed)       (list-ref parsed 0))
  (define (parsed-cwd parsed)       (list-ref parsed 1))
  (define (parsed-stdio parsed)     (list-ref parsed 2))
  (define (parsed-detached? parsed) (list-ref parsed 3))
  (define (parsed-uid parsed)       (list-ref parsed 4))
  (define (parsed-gid parsed)       (list-ref parsed 5))

  ;; Duplicate keys are errors. An absent env inherits the parent environment;
  ;; an explicitly empty env list creates an empty child environment.
  (define (validate-options options who)
    (unless (list? options)
      (raise (make-uv-invalid-argument who 'option-unknown)))
    (for-each
     (lambda (entry)
       (unless (and (pair? entry) (memq (car entry) option-keys))
         (raise (make-uv-invalid-argument who 'option-unknown))))
     options)
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

  ;; stdio spec = ignore | (inherit-fd . integer) | (inherit-stream . stream)
  ;;              | (pipe uv-pipe direction)
  (define (validate-stdio-spec spec who)
    (cond
      ((eq? spec 'ignore) #t)
      ((and (pair? spec) (eq? 'inherit-fd (car spec)))
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
         (when (pipe-connected? p)
           (raise (make-uv-invalid-argument who 'pipe-already-used)))
         (unless (memq dir '(to-child from-child duplex))
           (raise (make-uv-invalid-argument who 'stdio-spec-unknown)))))
      (else (raise (make-uv-invalid-argument who 'stdio-spec-unknown)))))

  (define (stdio-spec-handle spec)
    (cond ((and (pair? spec) (eq? 'inherit-stream (car spec))) (cdr spec))
          ((and (list? spec) (pair? spec) (eq? 'pipe (car spec))) (cadr spec))
          (else #f)))

  (define (require-same-loop-stdio! specs loop who)
    (for-each
     (lambda (spec)
       (let ((h (stdio-spec-handle spec)))
         (when (and h (not (eq? (handle-loop h) loop)))
           (raise (make-uv-invalid-argument who 'pipe-wrong-loop)))))
     specs))

  ;; Mark pipe handles consumed on both successful and failed spawns; retrying
  ;; with a pipe that libuv may already have opened is unsafe.
  (define (mark-consumed-pipes! specs)
    (for-each
     (lambda (spec)
       (let ((h (stdio-spec-handle spec)))
         (when (and h (uv-pipe-record? h))
           (set-pipe-connected! h #t))))
     specs))

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
                      (else (raise (make-uv-invalid-argument
                                    'uv-spawn! 'stdio-spec-unknown))))))))

  (define (utf8-size s) (+ 1 (bytevector-length (string->utf8 s))))

  ;; One zeroed allocation contains options, stdio, pointer arrays, and UTF-8
  ;; strings. libuv consumes it synchronously during uv_spawn.
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
      (guard (e (#t (free-options-block! block) (raise e)))
        (fill-strings-and-arrays! block parsed file args
                                  argv-off env-off strings-off ptr-size)
        (fill-stdio-containers! block specs stdio-off)
        (fill-scalars! block parsed n-stdio stdio-off)
        block)))

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
      ;; Zeroed slots terminate argv and env with NULL.
      (c-uptr-set! (+ block (offsetof-uv-process-options-t-args))
                   (+ block argv-off))
      (when env
        (let env-loop ((es env) (i 0))
          (unless (null? es)
            (c-uptr-set! (+ block env-off (* i ptr-size)) (put-string! (car es)))
            (env-loop (cdr es) (+ i 1))))
        (c-uptr-set! (+ block (offsetof-uv-process-options-t-env))
                     (+ block env-off)))))

  ;; Write the stdio union at the width of the active member: int for an fd,
  ;; pointer width for a stream.
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

  ;; Setting uid or gid must also set the corresponding libuv flag.
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

  ;; uv-spawn! : uv-loop string (listof string) (or procedure #f) -> uv-process
  ;; uv-spawn! : uv-loop string (listof string) (or alist #f) (or procedure #f)
  ;;             -> uv-process
  (define uv-spawn!
    (case-lambda
      ((loop file args on-exit)
       (start-spawn! loop file args '() on-exit))
      ((loop file args options on-exit)
       (start-spawn! loop file args (or options '()) on-exit))))

  (define (start-spawn! loop file args options on-exit)
    (ensure-native-loaded!)
    (require-open-loop loop 'uv-spawn!)
    (require-nul-free-string file 'uv-spawn! 'file-not-a-string)
    (require-string-list args 'uv-spawn! 'args-not-a-string-list)
    (unless (or (not on-exit) (procedure? on-exit))
      (raise (make-uv-invalid-argument 'uv-spawn! 'on-exit-not-a-procedure)))
    (let ((parsed (validate-options options 'uv-spawn!)))
      (require-same-loop-stdio! (parsed-stdio parsed) loop 'uv-spawn!)
      ;; All validation precedes the first allocation.
      (let* ((ptr (alloc-zeroed (uv-handle-size (uv-process-type))))
             (proc (%make-uv-process-record ptr loop on-exit))
             (block (guard (e (#t (free! ptr) (raise e)))
                      (build-options-block parsed file args))))
        (let ((rc (uv-spawn-native (loop-pointer loop 'uv-spawn!) ptr block)))
          (free-options-block! block)
          (mark-consumed-pipes! (parsed-stdio parsed))
          (if (zero? rc)
              (begin
                (registry-register! ptr 'process loop proc)
                (count-process-new!)
                proc)
              (begin
                (clean-up-failed-spawn! loop proc)
                (uv-check rc 'uv-spawn!)))))))

  ;; Spawn failures have opposite cleanups depending on whether libuv left the
  ;; handle in its loop queue. Ask uv_walk; errno values cannot classify this.
  ;; A nonzero pid is an unclassifiable partial-success state and is left intact.
  (define (clean-up-failed-spawn! loop proc)
    (unless (zero? (uv-process-get-pid (handle-pointer proc 'uv-spawn!)))
      (raise (make-uv-invalid-argument 'uv-spawn!
                                       'spawn-failure-state-unclassifiable)))
    (if (handle-in-loop-queue? loop proc)
        (begin
          (registry-register! (handle-pointer proc 'uv-spawn!) 'process loop proc)
          (count-process-new!)
          (close-handle! proc))
        (discard-failed-handle! proc)))

  ;; uv-process-kill! : uv-process (or symbol 0) -> unspecified
  ;; Sending a signal after exit can race operating-system pid reuse.
  (define (uv-process-kill! proc sig)
    (require-open-process proc 'uv-process-kill!)
    (let ((signum (signal-symbol->int sig 'uv-process-kill!)))
      (uv-check (uv-process-kill (handle-pointer proc 'uv-process-kill!)
                                 signum)
                'uv-process-kill!)))

  ;; uv-kill! : exact-integer (or symbol 0) -> unspecified
  ;; Negative pids retain kill(2)'s process-group meaning.
  (define (uv-kill! pid sig)
    (unless (and (integer? pid) (exact? pid))
      (raise (make-uv-invalid-argument 'uv-kill! 'pid-not-an-exact-integer)))
    (let ((signum (signal-symbol->int sig 'uv-kill!)))
      (uv-check (uv-kill pid signum) 'uv-kill!)))

  ;; uv-process-pid : uv-process -> exact-integer
  (define (uv-process-pid proc)
    (require-open-process proc 'uv-process-pid)
    (uv-process-get-pid (handle-pointer proc 'uv-process-pid)))

  ;; uv-os-getpid : -> exact-integer
  (define (uv-os-getpid)
    (ensure-native-loaded!)
    (uv-os-getpid-native))
  ;; Exit does not free or close the handle. Set lifecycle state before invoking
  ;; user code so a callback failure cannot leave the record inconsistent.
  (define (exit-dispatch proc handle-ptr exit-status term-signal)
    (cond
      ((not proc) (record-orphan-callback! 'exit handle-ptr))
      ((not (uv-process-record? proc))
       (raise (condition
               (make-uv-error)
               (make-who-condition 'uv-exit-dispatch)
               (make-message-condition
                "exit completion for a handle of another kind"))))
      (else
       (let ((sig (term-signal->value term-signal))
             (on-exit (process-on-exit proc)))
         (set-process-exited! proc #t)
         (when on-exit (on-exit exit-status sig))))))

  (define exit-dispatch-installed
    (install-dispatch-procedure! 'exit exit-dispatch))

  (define walk-dispatch-installed
    (install-dispatch-procedure! 'walk walk-dispatch)))
