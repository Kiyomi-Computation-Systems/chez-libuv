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
          (libuv private handles)
          ;; Ahead of (chezscheme) (#41; tests/test-require-threaded.sps).
          (libuv private require-threaded)
          (only (chezscheme) with-interrupts-disabled))

  ;; --- reading the caller's data, once --------------------------------------
  ;; uv-spawn! reads everything its caller passed exactly once, into a request
  ;; nothing else can reach: each string as a fresh UTF-8 bytevector, each
  ;; list as a fresh list, each stdio spec as a fresh record. The checks, the
  ;; options block's sizing and filling, and the marking of pipes all read the
  ;; request, never the caller's data again. Read twice, that data could change
  ;; in between, from an engine's timer handler or another thread: a string or
  ;; list that grew after the block was sized from it was written past the
  ;; block's end, a stdio list that grew wrote a container over argv, a pipe
  ;; swapped in after the check reached libuv, and a NUL set after the check
  ;; cut a C string short (test-process.sps's changing-data sweeps).
  ;;
  ;; The read is one interrupt-free step, so to an engine it happens at one
  ;; instant. That does not hold another thread off, so the read never
  ;; trusts the caller's data to keep still while it reads it:
  ;; - Chez's string->utf8 counts a string's bytes in one pass and writes
  ;;   them, unchecked, in a second (s/prims.ss). A string that changes in
  ;;   between gets bytes it never held, or bytes written past the
  ;;   bytevector sized for it. So each string is copied and the copy
  ;;   encoded: a copy is fixed-width, and nothing runs inside one with
  ;;   interrupts disabled.
  ;; - Chez's map walks a list it has measured without checking it again,
  ;;   where list? and length check every pair they pass (s/4.ss, s/5_2.ss).
  ;;   So a list is measured with those and walked a pair at a time.
  ;; On data that keeps still the read raises nothing: what is malformed is
  ;; kept as #f, and the checks refuse it afterwards in the order they have
  ;; always run.

  ;; file is a bytevector, or #f for a non-string. args is a list of
  ;; (bytevector or #f), or #f for anything but a proper list; options is a
  ;; list of read entries (read-option), or #f likewise.
  (define-record-type spawn-request
    (fields file args options))

  ;; A stdio spec as read. kind is ignore, inherit-fd, inherit-stream or pipe,
  ;; or #f for any other shape; value is the fd or the handle.
  (define-record-type stdio-spec
    (fields kind value direction))

  ;; read-spawn-request : object object object -> spawn-request
  (define (read-spawn-request file args options)
    (make-spawn-request (read-string file)
                        (read-list args read-string)
                        (read-list options read-option)))

  (define (read-string s) (and (string? s) (string->utf8 (string-copy s))))

  ;; At most as many steps as LST had pairs when it was measured, each pair
  ;; checked, so a list another thread changes during the walk only ends it
  ;; early, and is never walked forever.
  (define (read-list lst read-element)
    (and (list? lst)
         (let walk ((p lst) (left (length lst)))
           (cond ((zero? left) '())
                 ((pair? p)
                  (let ((element (read-element (car p))))
                    (cons element (walk (cdr p) (- left 1)))))
                 (else '())))))

  ;; An options entry as (key . value), its value read as its key needs; #f
  ;; for anything but a pair.
  (define (read-option entry)
    (and (pair? entry)
         (let ((key (car entry)) (value (cdr entry)))
           (cons key (case key
                       ((env)   (read-list value read-string))
                       ((cwd)   (read-string value))
                       ((stdio) (read-list value read-stdio-spec))
                       (else    value))))))

  ;; stdio spec = ignore | (inherit-fd . integer) | (inherit-stream . stream)
  ;;              | (pipe uv-pipe direction)
  (define (read-stdio-spec spec)
    (cond
      ((eq? spec 'ignore) (make-stdio-spec 'ignore #f #f))
      ((pair? spec)
       (let ((kind (car spec)) (rest (cdr spec)))
         (case kind
           ((inherit-fd inherit-stream) (make-stdio-spec kind rest #f))
           ((pipe)
            (if (and (pair? rest) (pair? (cdr rest)) (null? (cddr rest)))
                (make-stdio-spec 'pipe (car rest) (cadr rest))
                (make-stdio-spec #f #f #f)))
           (else (make-stdio-spec #f #f #f)))))
      (else (make-stdio-spec #f #f #f))))

  ;; --- checking what was read -----------------------------------------------
  ;; Every check precedes the first allocation.

  ;; An embedded NUL would cut the string short at the C boundary. UTF-8
  ;; encodes NUL, and nothing else, as a zero byte.
  (define (check-string bv who type-reason)
    (unless bv
      (raise (make-uv-invalid-argument who type-reason)))
    (let scan ((i 0))
      (when (< i (bytevector-length bv))
        (when (zero? (bytevector-u8-ref bv i))
          (raise (make-uv-invalid-argument who 'embedded-nul)))
        (scan (+ i 1)))))

  (define (check-strings lst who reason)
    (unless lst
      (raise (make-uv-invalid-argument who reason)))
    (for-each (lambda (bv) (check-string bv who reason)) lst))

  (define (require-u32 n who reason)
    (unless (and (integer? n) (exact? n) (>= n 0) (< n 4294967296))
      (raise (make-uv-invalid-argument who reason))))

  (define (require-open-process proc who)
    (unless (uv-process-record? proc)
      (raise (make-uv-invalid-argument who 'not-a-uv-process)))
    (require-open-handle proc who)
    proc)

  (define option-keys '(env cwd stdio detached uid gid))

  ;; The options as checked: env is a list of bytevectors, or #f to inherit
  ;; the parent's; cwd a bytevector or #f; stdio a list of stdio-specs.
  (define-record-type spawn-options
    (fields env cwd stdio detached? uid gid))

  ;; Duplicate keys are errors. An absent env inherits the parent environment;
  ;; an explicitly empty env list creates an empty child environment.
  (define (check-options entries who)
    (unless entries
      (raise (make-uv-invalid-argument who 'option-unknown)))
    (for-each
     (lambda (entry)
       (unless (and entry (memq (car entry) option-keys))
         (raise (make-uv-invalid-argument who 'option-unknown))))
     entries)
    (let dup-scan ((entries entries) (seen '()))
      (unless (null? entries)
        (let ((key (caar entries)))
          (when (memq key seen)
            (raise (make-uv-invalid-argument who 'option-duplicate)))
          (dup-scan (cdr entries) (cons key seen)))))
    (let ((env      (assq 'env entries))
          (cwd      (assq 'cwd entries))
          (stdio    (assq 'stdio entries))
          (detached (assq 'detached entries))
          (uid      (assq 'uid entries))
          (gid      (assq 'gid entries)))
      (when env (check-strings (cdr env) who 'env-not-a-string-list))
      (when cwd (check-string (cdr cwd) who 'cwd-not-a-string))
      (when detached
        (unless (boolean? (cdr detached))
          (raise (make-uv-invalid-argument who 'detached-not-a-boolean))))
      (when uid (require-u32 (cdr uid) who 'uid-out-of-range))
      (when gid (require-u32 (cdr gid) who 'gid-out-of-range))
      (when stdio
        (unless (cdr stdio)
          (raise (make-uv-invalid-argument who 'stdio-not-a-list)))
        (for-each (lambda (spec) (check-stdio-spec spec who)) (cdr stdio)))
      (make-spawn-options (and env (cdr env))
                          (and cwd (cdr cwd))
                          (if stdio (cdr stdio) '())
                          (and detached (cdr detached))
                          (and uid (cdr uid))
                          (and gid (cdr gid)))))

  (define (check-stdio-spec spec who)
    (case (stdio-spec-kind spec)
      ((ignore) #t)
      ((inherit-fd)
       (let ((fd (stdio-spec-value spec)))
         (unless (and (integer? fd) (exact? fd) (>= fd 0)
                      (< fd 2147483648))
           (raise (make-uv-invalid-argument who 'stdio-fd-not-an-fd)))))
      ((inherit-stream)
       (let ((h (stdio-spec-value spec)))
         (unless (uv-stream-record? h)
           (raise (make-uv-invalid-argument who 'stdio-spec-unknown)))
         (require-open-handle h who)))
      ((pipe)
       (let ((p (stdio-spec-value spec)) (dir (stdio-spec-direction spec)))
         (unless (uv-pipe-record? p)
           (raise (make-uv-invalid-argument who 'stdio-spec-unknown)))
         (require-open-handle p who)
         (when (pipe-connected? p)
           (raise (make-uv-invalid-argument who 'pipe-already-used)))
         (unless (memq dir '(to-child from-child duplex))
           (raise (make-uv-invalid-argument who 'stdio-spec-unknown)))))
      (else (raise (make-uv-invalid-argument who 'stdio-spec-unknown)))))

  (define (stdio-spec-handle spec)
    (and (memq (stdio-spec-kind spec) '(inherit-stream pipe))
         (stdio-spec-value spec)))

  (define (require-same-loop-stdio! specs loop who)
    (for-each
     (lambda (spec)
       (let ((h (stdio-spec-handle spec)))
         (when (and h (not (eq? (handle-loop h) loop)))
           (raise (make-uv-invalid-argument who 'pipe-wrong-loop)))))
     specs))

  ;; libuv opens each (pipe ...) spec's end into its pipe after it forks, so
  ;; a pipe named twice fails its second open with the child running:
  ;; ADR-0015 decision 5's unclassifiable state. One spawn consumes a pipe
  ;; once.
  (define (require-distinct-pipes! specs who)
    (let scan ((specs specs) (seen '()))
      (unless (null? specs)
        (let ((spec (car specs)))
          (if (eq? (stdio-spec-kind spec) 'pipe)
              (let ((p (stdio-spec-value spec)))
                (when (memq p seen)
                  (raise (make-uv-invalid-argument who 'pipe-already-used)))
                (scan (cdr specs) (cons p seen)))
              (scan (cdr specs) seen))))))

  ;; Mark pipe handles consumed on both successful and failed spawns; retrying
  ;; with a pipe that libuv may already have opened is unsafe.
  (define (mark-consumed-pipes! specs)
    (for-each
     (lambda (spec)
       (let ((h (stdio-spec-handle spec)))
         (when (and h (uv-pipe-record? h))
           (set-pipe-connected! h #t))))
     specs))

  ;; --- the options block ------------------------------------------------------

  (define (stdio-spec-flags spec)
    (case (stdio-spec-kind spec)
      ((ignore)         (uv-stdio-ignore))
      ((inherit-fd)     (uv-stdio-inherit-fd))
      ((inherit-stream) (uv-stdio-inherit-stream))
      (else ;; pipe
       (bitwise-ior (uv-stdio-create-pipe)
                    (case (stdio-spec-direction spec)
                      ((to-child)   (uv-stdio-readable-pipe))
                      ((from-child) (uv-stdio-writable-pipe))
                      ((duplex)     (bitwise-ior (uv-stdio-readable-pipe)
                                                 (uv-stdio-writable-pipe)))
                      (else (raise (make-uv-invalid-argument
                                    'uv-spawn! 'stdio-spec-unknown))))))))

  ;; The stdio containers' offset in the options block.
  (define (stdio-offset) (align-16 (sizeof-uv-process-options-t)))

  ;; One zeroed allocation contains options, stdio, pointer arrays, and UTF-8
  ;; strings. libuv consumes it synchronously during uv_spawn.
  (define (build-options-block file args options)
    (let* ((env         (spawn-options-env options))
           (cwd         (spawn-options-cwd options))
           (specs       (spawn-options-stdio options))
           (ptr-size    (c-uptr-size))
           (n-stdio     (length specs))
           (stdio-off   (stdio-offset))
           (argv-off    (align-16 (+ stdio-off
                                     (* n-stdio (sizeof-uv-stdio-container-t)))))
           (env-off     (align-16 (+ argv-off (* (+ 1 (length args)) ptr-size))))
           (strings-off (align-16 (+ env-off
                                     (if env (* (+ 1 (length env)) ptr-size) 0))))
           ;; Each string and its terminating NUL.
           (size        (fold-left (lambda (at bv) (+ at (bytevector-length bv) 1))
                                   strings-off
                                   (cons file (append (if cwd (list cwd) '())
                                                      args
                                                      (or env '())))))
           (block (alloc-zeroed size)))
      (count-spawn-options-new!)
      (guard (e (#t (free-options-block! block) (raise e)))
        (fill-strings-and-arrays! block size file args options
                                  argv-off env-off strings-off ptr-size)
        (fill-stdio-containers! block specs stdio-off)
        (fill-scalars! block options n-stdio stdio-off)
        block)))

  (define (fill-strings-and-arrays! block size file args options
                                    argv-off env-off strings-off ptr-size)
    (let ((env (spawn-options-env options))
          (cwd (spawn-options-cwd options))
          (cursor strings-off))
      ;; The block is zeroed, so the byte after each string is its NUL. A
      ;; string that would not fit, with that byte, is refused, never written:
      ;; copy-in! bounds a copy by its source, not by the block it writes to.
      (define (put-bytes! bv)
        (let ((at cursor) (len (bytevector-length bv)))
          (unless (<= (+ at len 1) size)
            (raise (condition
                    (make-uv-error)
                    (make-who-condition 'uv-spawn!)
                    (make-message-condition
                     "the options block is too small for its strings"))))
          (copy-in! (+ block at) bv 0 len)
          (set! cursor (+ at len 1))
          (+ block at)))
      (c-uptr-set! (+ block (offsetof-uv-process-options-t-file))
                   (put-bytes! file))
      (when cwd
        (c-uptr-set! (+ block (offsetof-uv-process-options-t-cwd))
                     (put-bytes! cwd)))
      (let arg-loop ((as args) (i 0))
        (unless (null? as)
          (c-uptr-set! (+ block argv-off (* i ptr-size)) (put-bytes! (car as)))
          (arg-loop (cdr as) (+ i 1))))
      ;; Zeroed slots terminate argv and env with NULL.
      (c-uptr-set! (+ block (offsetof-uv-process-options-t-args))
                   (+ block argv-off))
      (when env
        (let env-loop ((es env) (i 0))
          (unless (null? es)
            (c-uptr-set! (+ block env-off (* i ptr-size)) (put-bytes! (car es)))
            (env-loop (cdr es) (+ i 1))))
        (c-uptr-set! (+ block (offsetof-uv-process-options-t-env))
                     (+ block env-off)))))

  ;; Write the stdio union at the width of the active member: int for an fd,
  ;; pointer width for a stream. A stream's pointer is left to the step that
  ;; checks its handle (fill-stream-pointers!).
  (define (fill-stdio-containers! block specs stdio-off)
    (let stdio-loop ((ss specs) (i 0))
      (unless (null? ss)
        (let ((c (+ block stdio-off (* i (sizeof-uv-stdio-container-t))))
              (spec (car ss)))
          (c-int-set! (+ c (offsetof-uv-stdio-container-t-flags))
                      (stdio-spec-flags spec))
          (when (eq? (stdio-spec-kind spec) 'inherit-fd)
            (c-int-set! (+ c (offsetof-uv-stdio-container-t-data))
                        (stdio-spec-value spec))))
        (stdio-loop (cdr ss) (+ i 1)))))

  ;; The step's half of the fill: each stream spec's handle pointer, read
  ;; from the handle the step has just checked.
  (define (fill-stream-pointers! block specs)
    (let fill ((ss specs) (i 0))
      (unless (null? ss)
        (let ((h (stdio-spec-handle (car ss))))
          (when h
            (c-uptr-set! (+ block (stdio-offset)
                            (* i (sizeof-uv-stdio-container-t))
                            (offsetof-uv-stdio-container-t-data))
                         (handle-ptr h))))
        (fill (cdr ss) (+ i 1)))))

  ;; Setting uid or gid must also set the corresponding libuv flag.
  (define (fill-scalars! block options n-stdio stdio-off)
    (let ((uid (spawn-options-uid options))
          (gid (spawn-options-gid options)))
      (c-int-set! (+ block (offsetof-uv-process-options-t-stdio-count)) n-stdio)
      (when (positive? n-stdio)
        (c-uptr-set! (+ block (offsetof-uv-process-options-t-stdio))
                     (+ block stdio-off)))
      (c-int-set! (+ block (offsetof-uv-process-options-t-flags))
                  (bitwise-ior
                   (if (spawn-options-detached? options) (uv-process-detached-flag) 0)
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
    (let ((request (with-interrupts-disabled
                     (read-spawn-request file args options))))
      (check-string (spawn-request-file request) 'uv-spawn! 'file-not-a-string)
      ;; args is the complete non-empty argv, including argv[0].
      (unless (pair? (spawn-request-args request))
        (raise (make-uv-invalid-argument 'uv-spawn! 'args-not-a-string-list)))
      (check-strings (spawn-request-args request) 'uv-spawn! 'args-not-a-string-list)
      (unless (or (not on-exit) (procedure? on-exit))
        (raise (make-uv-invalid-argument 'uv-spawn! 'on-exit-not-a-procedure)))
      (let ((options (check-options (spawn-request-options request) 'uv-spawn!)))
        (require-same-loop-stdio! (spawn-options-stdio options) loop 'uv-spawn!)
        (require-distinct-pipes! (spawn-options-stdio options) 'uv-spawn!)
        (let* ((ptr (alloc-zeroed (uv-handle-size (uv-process-type))))
               (proc (%make-uv-process-record ptr loop on-exit))
               (block (guard (e (#t (free! ptr) (raise e)))
                        (build-options-block (spawn-request-file request)
                                             (spawn-request-args request)
                                             options)))
               (status (with-interrupts-disabled
                         (spawn-step! loop proc block
                                      (spawn-options-stdio options)))))
          (unless (eq? status 'spawned)
            (raise (spawn-refusal status)))
          proc))))

  ;; --- the step that spawns ---------------------------------------------------
  ;; The checks above see the loop and the stdio handles as they were on
  ;; entry, and the loop and the handles stay the caller's: an engine's timer
  ;; handler can close a handle, consume a pipe in a spawn of its own, or
  ;; tear the loop down before uv_spawn runs. libuv then opened a closing
  ;; pipe's end into it, a descriptor nothing ever closed; reached a freed
  ;; pipe through an address another pipe could hold by then; forked, then
  ;; failed to open a consumed pipe (ADR-0015 decision 5's state); or spawned
  ;; on a freed loop. A teardown between uv_spawn and the registration left
  ;; the process in the loop where the teardown could not close it.
  ;;
  ;; So once the options block is built, one interrupt-free step checks the
  ;; loop and each handle again, hands libuv the pointers it just checked,
  ;; spawns, frees the options block, marks the pipes, and registers the
  ;; process or cleans up after a failure. An engine that expires during
  ;; uv-spawn! is suspended before the step or after it (test-process.sps's
  ;; state sweeps). One suspended between the allocations and the step and
  ;; never resumed still strands the process handle and the options block.
  ;;
  ;; The step raises nothing. It answers 'spawned or a status, and the verb
  ;; raises after it (spawn-refusal). It frees what a refusal leaves, so a
  ;; refused spawn holds nothing. with-interrupts-disabled, a dynamic-wind,
  ;; costs 32 B a spawn over one-step, a bare interrupt pair, and keeps
  ;; interrupts from staying off should anything in the step raise after all:
  ;; a fault in uv_spawn arrives as a Scheme condition.

  ;; spawn-step! : uv-loop uv-process uptr (listof stdio-spec)
  ;;               -> (or 'spawned status)
  (define (spawn-step! loop proc block specs)
    (let* ((loop-address (open-loop-ptr loop))
           (refusal (if (symbol? loop-address)
                        loop-address
                        (stdio-refusal specs))))
      (if refusal
          (begin (free-options-block! block)
                 (discard-failed-handle! proc)
                 refusal)
          (let ((ptr (handle-ptr proc)))
            (fill-stream-pointers! block specs)
            (let ((rc (uv-spawn-native loop-address ptr block)))
              (free-options-block! block)
              (mark-consumed-pipes! specs)
              (if (zero? rc)
                  (begin (registry-register! ptr 'process loop proc)
                         (count-process-new!)
                         'spawned)
                  (clean-up-failed-spawn! loop proc rc)))))))

  ;; stdio-refusal : (listof stdio-spec) -> (or status #f)
  ;; The first spec the entry checks would now refuse for its handle's state:
  ;; open-handle-ptr's refusal paired with the handle, or 'pipe-already-used.
  (define (stdio-refusal specs)
    (exists (lambda (spec)
              (let ((h (stdio-spec-handle spec)))
                (and h
                     (let ((ptr (open-handle-ptr h)))
                       (cond ((symbol? ptr) (cons ptr h))
                             ((and (eq? (stdio-spec-kind spec) 'pipe)
                                   (pipe-connected? h))
                              'pipe-already-used)
                             (else #f))))))
            specs))

  ;; spawn-refusal : status -> condition
  ;; What uv-spawn! raises for a status the step answered: what the checks
  ;; on entry raise for the same state, or libuv's errno. A handle's refusal
  ;; comes paired with the handle (stdio-refusal).
  (define (spawn-refusal status)
    (if (pair? status)
        (step-refusal (car status) 'uv-spawn! (cdr status))
        (step-refusal status 'uv-spawn! #f)))

  ;; clean-up-failed-spawn! : uv-loop uv-process exact-integer -> status
  ;; Spawn failures have opposite cleanups depending on whether libuv left the
  ;; handle in its loop queue. Ask uv_walk; errno values cannot classify this.
  ;; A nonzero pid is an unclassifiable partial-success state and is left
  ;; intact. Answers the status the verb raises, RC unless unclassifiable.
  (define (clean-up-failed-spawn! loop proc rc)
    (let ((ptr (handle-ptr proc)))
      (cond ((not (zero? (uv-process-get-pid ptr)))
             'spawn-failure-state-unclassifiable)
            ((handle-in-loop-queue? loop proc)
             (registry-register! ptr 'process loop proc)
             (count-process-new!)
             (close-handle! proc)
             rc)
            (else
             (discard-failed-handle! proc)
             rc))))

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
