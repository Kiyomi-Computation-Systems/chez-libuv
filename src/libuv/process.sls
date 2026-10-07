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

  ;; One zeroed block holds the options, the stdio containers, the argv and
  ;; env pointer arrays, and the UTF-8 strings; libuv reads it only during
  ;; uv_spawn. Its layout is worked out from the request before the step that
  ;; spawns, and the step allocates the block, fills it, spawns and frees it,
  ;; so no engine can strand it (the step's comment below).

  ;; The options block's size, and where its argv and env arrays and its
  ;; strings begin, as offsets from its start.
  (define-record-type options-layout
    (fields size argv-off env-off strings-off))

  ;; layout-options-block : spawn-request spawn-options -> options-layout
  (define (layout-options-block request options)
    (let* ((args        (spawn-request-args request))
           (env         (spawn-options-env options))
           (cwd         (spawn-options-cwd options))
           (ptr-size    (c-uptr-size))
           (n-stdio     (length (spawn-options-stdio options)))
           (argv-off    (align-16 (+ (stdio-offset)
                                     (* n-stdio (sizeof-uv-stdio-container-t)))))
           (env-off     (align-16 (+ argv-off (* (+ 1 (length args)) ptr-size))))
           (strings-off (align-16 (+ env-off
                                     (if env (* (+ 1 (length env)) ptr-size) 0)))))
      (make-options-layout
       ;; Each string and its terminating NUL.
       (fold-left (lambda (at bv) (+ at (bytevector-length bv) 1))
                  strings-off
                  (cons (spawn-request-file request)
                        (append (if cwd (list cwd) '()) args (or env '()))))
       argv-off env-off strings-off)))

  ;; fill-options-block! : uptr options-layout spawn-request spawn-options
  ;;                       -> boolean
  ;; Inside the step: writes everything but the stream pointers into BLOCK,
  ;; zeroed and LAYOUT's size, and answers #t; #f when a string would not
  ;; fit. A stream's pointer is left to the handle's check
  ;; (fill-stream-pointers!).
  (define (fill-options-block! block layout request options)
    (let ((specs (spawn-options-stdio options)))
      (and (fill-strings-and-arrays! block layout request options)
           (begin (fill-stdio-containers! block specs (stdio-offset))
                  (fill-scalars! block options (length specs) (stdio-offset))
                  #t))))

  ;; fill-strings-and-arrays! : uptr options-layout spawn-request
  ;;                            spawn-options -> boolean
  ;; The strings go in the order the layout sized them: file, cwd, args,
  ;; env. The block is zeroed, so the byte after each string is its NUL, and
  ;; zeroed slots end argv and env with NULL. A string that would not fit,
  ;; with its NUL, is never written, and the fill answers #f: only a layout
  ;; that disagrees with this fill comes here, since it sized the block from
  ;; these strings, and a copy is bounded by its source, not by the block.
  (define (fill-strings-and-arrays! block layout request options)
    (let ((size (options-layout-size layout))
          (ptr-size (c-uptr-size))
          (env (spawn-options-env options))
          (cwd (spawn-options-cwd options))
          (cursor (options-layout-strings-off layout)))
      ;; put! : exact-nonnegative-integer bytevector -> boolean
      ;; Copies BV in at the cursor and points the slot at offset SLOT at it.
      (define (put! slot bv)
        (let ((at cursor) (len (bytevector-length bv)))
          (and (<= (+ at len 1) size)
               (begin (copy-in-unchecked! (+ block at) bv 0 len)
                      (c-uptr-set! (+ block slot) (+ block at))
                      (set! cursor (+ at len 1))
                      #t))))
      ;; put-array! : exact-nonnegative-integer (listof bytevector) -> boolean
      ;; Each of BVS, its pointer in the array at offset OFF.
      (define (put-array! off bvs)
        (let next ((bvs bvs) (i 0))
          (or (null? bvs)
              (and (put! (+ off (* i ptr-size)) (car bvs))
                   (next (cdr bvs) (+ i 1))))))
      (and (put! (offsetof-uv-process-options-t-file) (spawn-request-file request))
           (or (not cwd) (put! (offsetof-uv-process-options-t-cwd) cwd))
           (put-array! (options-layout-argv-off layout) (spawn-request-args request))
           (begin (c-uptr-set! (+ block (offsetof-uv-process-options-t-args))
                               (+ block (options-layout-argv-off layout)))
                  #t)
           (or (not env)
               (and (put-array! (options-layout-env-off layout) env)
                    (begin (c-uptr-set! (+ block (offsetof-uv-process-options-t-env))
                                        (+ block (options-layout-env-off layout)))
                           #t))))))

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
    (free-block! block)
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
        (let* ((layout (layout-options-block request options))
               (handle-size (uv-handle-size (uv-process-type)))
               (made (with-interrupts-disabled
                       (spawn-step! loop on-exit handle-size layout
                                    request options))))
          (if (uv-process-record? made)
              made
              (raise (spawn-refusal made)))))))

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
  ;; And an engine can be dropped, as a timeout drops a task, and never
  ;; resumed. Nothing after its expiry runs, so what the verb held then and
  ;; had not handed on was lost: the process handle and the options block,
  ;; allocated and built before the step (test-process.sps's drop sweeps).
  ;;
  ;; So one interrupt-free step checks the loop and each handle again,
  ;; allocates the process handle and the options block, fills the block,
  ;; hands libuv the pointers it just checked, spawns, frees the options
  ;; block, marks the pipes, and registers the process or cleans up after a
  ;; failure. An engine that expires during uv-spawn! is suspended or dropped
  ;; before the step, holding nothing, or after it, when the loop holds the
  ;; process or the failure is cleaned up (test-process.sps's state and drop
  ;; sweeps).
  ;;
  ;; The step raises nothing. It answers the process or a status, and the
  ;; verb raises after it (spawn-refusal). It frees what a refusal leaves, so
  ;; a refused spawn holds nothing. Its writes raise only for values the
  ;; checks above refuse, as the stream verbs' uv-buf-set! does, and its
  ;; allocations answer 0 rather than raise (alloc-block).
  ;; with-interrupts-disabled, a dynamic-wind, costs 112 B a spawn over
  ;; one-step, a bare interrupt pair, its body's closure included, and keeps
  ;; interrupts from staying off should anything in the step raise after
  ;; all: a fault in uv_spawn arrives as a Scheme condition.

  ;; spawn-step! : uv-loop (or procedure #f) exact-positive-integer
  ;;               options-layout spawn-request spawn-options
  ;;               -> (or uv-process status)
  (define (spawn-step! loop on-exit handle-size layout request options)
    (let* ((specs (spawn-options-stdio options))
           (loop-address (open-loop-ptr loop))
           (refusal (if (symbol? loop-address)
                        loop-address
                        (stdio-refusal specs))))
      (if refusal
          refusal
          (let ((ptr (alloc-block handle-size))
                (block (alloc-block (options-layout-size layout))))
            (if (or (zero? ptr) (zero? block))
                (begin (free-block! ptr)
                       (free-block! block)
                       'no-memory)
                (begin
                  (count-spawn-options-new!)
                  (if (fill-options-block! block layout request options)
                      (spawn-from-block! loop loop-address
                                         (%make-uv-process-record ptr loop on-exit)
                                         block specs)
                      (begin (free-options-block! block)
                             (free-block! ptr)
                             'options-block-too-small))))))))

  ;; spawn-from-block! : uv-loop uptr uv-process uptr (listof stdio-spec)
  ;;                     -> (or uv-process status)
  ;; The rest of the step, once BLOCK holds all the options but the stream
  ;; pointers: those, from the handles just checked; uv_spawn on the loop at
  ;; LOOP-ADDRESS; the options block freed; the pipes marked; and PROC
  ;; registered, or the failure cleaned up.
  (define (spawn-from-block! loop loop-address proc block specs)
    (let ((ptr (handle-ptr proc)))
      (fill-stream-pointers! block specs)
      (let ((rc (uv-spawn-native loop-address ptr block)))
        (free-options-block! block)
        (mark-consumed-pipes! specs)
        (if (zero? rc)
            (begin (registry-register! ptr 'process loop proc)
                   (count-process-new!)
                   proc)
            (clean-up-failed-spawn! loop proc rc)))))

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
  ;; on entry raise for the same state, ENOMEM, or libuv's errno. A handle's
  ;; refusal comes paired with the handle (stdio-refusal). A layout the fill
  ;; disagrees with is the binding's own fault, not the caller's.
  (define (spawn-refusal status)
    (cond ((pair? status) (step-refusal (car status) 'uv-spawn! (cdr status)))
          ((eq? status 'options-block-too-small)
           (condition (make-uv-error)
                      (make-who-condition 'uv-spawn!)
                      (make-message-condition
                       "the options block is too small for its strings")))
          (else (step-refusal status 'uv-spawn! #f))))

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
