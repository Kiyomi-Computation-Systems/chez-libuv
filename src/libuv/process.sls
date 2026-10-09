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
          (only (libuv private lists) read-proper-list let-fixed-list)
          (only (libuv private c-string) read-utf8 nul-free?)
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
  ;;   encoded (read-utf8, in (libuv private c-string)).
  ;; - Each list is read with read-proper-list ((libuv private lists)):
  ;;   counted without raising, walked at most that many pairs, each checked
  ;;   before it is read through, and its end required after them, counted
  ;;   and walked once more when the walk contradicts the count. Measured
  ;;   with list? and then length, a list another thread changed in between
  ;;   made length raise its own condition, and one cut or made longer
  ;;   during the walk was read as a list the caller never had: the part
  ;;   before the cut, or the stale length's worth of the longer list. At
  ;;   --optimize-level 3, where length checks nothing, it read through the
  ;;   cut, and a list made circular for good during length was walked
  ;;   forever with interrupts disabled (#66).
  ;; - Each field of a stdio spec and of an options entry is read once,
  ;;   after its pair is found to be one (read-stdio-spec, read-option).
  ;; So whatever another thread does, the read raises nothing, never reads
  ;; through a non-pair, and ends once the changes stop. A list it finds
  ;; malformed is kept as #f, a stdio spec of no known shape as a spec of
  ;; kind #f, and the checks refuse them afterwards in the order they have
  ;; always run. A list changed once during the read is read as it was
  ;; before the change or after it; one changed several times can be read as
  ;; a mix of its versions, as a string can, or found malformed though every
  ;; version was a list (docs/api.md). test-process.sps's cross-thread list
  ;; races and test-native.sps's one-change race hold this.
  ;;
  ;; The read raises nothing, so a bare interrupt pair, such as read-utf8
  ;; takes, would do, and save the dynamic-wind's 80 B a spawn. The step
  ;; keeps with-interrupts-disabled all the same: should an edit make the
  ;; read raise, that unwinds the step and the change fails its rows by
  ;; name, where a bare pair would leave interrupts off for good and
  ;; test-process would hang (#73's review).

  ;; file is a bytevector, or #f for a non-string. args is a list of
  ;; (bytevector or #f), or #f for anything but a proper list as the read
  ;; found it; options is a list of read entries (read-option), or #f
  ;; likewise.
  (define-record-type spawn-request
    (fields file args options))

  ;; A stdio spec as read. kind is ignore, inherit-fd, inherit-stream or pipe,
  ;; or #f for any other shape; value is the fd or the handle.
  (define-record-type stdio-spec
    (fields kind value direction))

  ;; read-spawn-request : object object object -> spawn-request
  (define (read-spawn-request file args options)
    (make-spawn-request (read-utf8 file)
                        (read-proper-list args read-utf8)
                        (read-proper-list options read-option)))

  ;; An options entry as (key . value), its value read as its key needs; #f
  ;; for anything but a pair.
  (define (read-option entry)
    (and (pair? entry)
         (let ((key (car entry)) (value (cdr entry)))
           (cons key (case key
                       ((env)   (read-proper-list value read-utf8))
                       ((cwd)   (read-utf8 value))
                       ((stdio) (read-proper-list value read-stdio-spec))
                       (else    value))))))

  ;; stdio spec = ignore | (inherit-fd . integer) | (inherit-stream . stream)
  ;;              | (pipe uv-pipe direction)
  ;; Each pair of a spec is read once, a pipe spec's tail with
  ;; let-fixed-list. Its (cdr rest), checked as a pair and then read again as
  ;; (cddr rest) and (cadr rest), could be a non-pair by the second read:
  ;; Chez's own cddr or cadr raised there, and at --optimize-level 3 the read
  ;; went through it (#66).
  (define (read-stdio-spec spec)
    (cond
      ((eq? spec 'ignore) (make-stdio-spec 'ignore #f #f))
      ((pair? spec)
       (let ((kind (car spec)) (rest (cdr spec)))
         (case kind
           ((inherit-fd inherit-stream) (make-stdio-spec kind rest #f))
           ((pipe)
            (let-fixed-list (pipe direction) rest (make-stdio-spec #f #f #f)
              (make-stdio-spec 'pipe pipe direction)))
           (else (make-stdio-spec #f #f #f)))))
      (else (make-stdio-spec #f #f #f))))

  ;; --- checking what was read -----------------------------------------------
  ;; Every check precedes the first allocation.

  ;; An embedded NUL would cut the string short at the C boundary.
  (define (check-string bv who type-reason)
    (unless bv
      (raise (make-uv-invalid-argument who type-reason)))
    (unless (nul-free? bv (bytevector-length bv))
      (raise (make-uv-invalid-argument who 'embedded-nul))))

  (define (check-strings lst who reason)
    (unless lst
      (raise (make-uv-invalid-argument who reason)))
    (for-each (lambda (bv) (check-string bv who reason)) lst))

  ;; The C types the options block holds a caller's number in: an fd is a C
  ;; int, a uid or gid an unsigned 32-bit int. The checks refuse a number
  ;; outside its type before anything is allocated, and the fill, inside the
  ;; step that spawns, writes none (fill-options-block!).
  (define (c-int-fd? x) (and (integer? x) (exact? x) (<= 0 x 2147483647)))
  (define (u32? x) (and (integer? x) (exact? x) (<= 0 x 4294967295)))

  (define (require-u32 n who reason)
    (unless (u32? n)
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
         (unless (c-int-fd? fd)
           (raise (make-uv-invalid-argument who 'stdio-fd-not-an-fd)))))
      ((inherit-stream)
       (let ((h (stdio-spec-value spec)))
         (unless (uv-stream-record? h)
           (raise (make-uv-invalid-argument who 'stdio-spec-unknown)))
         (require-open-handle h who)))
      ((pipe)
       (let ((p (stdio-spec-value spec)))
         (unless (uv-pipe-record? p)
           (raise (make-uv-invalid-argument who 'stdio-spec-unknown)))
         (require-open-handle p who)
         (when (pipe-connected? p)
           (raise (make-uv-invalid-argument who 'pipe-already-used)))
         (unless (stdio-spec-flags spec)
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

  ;; stdio-spec-flags : stdio-spec -> (or exact-integer #f)
  ;; A container's flags for SPEC, or #f for a kind or direction there are
  ;; no flags for: the checks refuse that spec, and the fill writes none.
  (define (stdio-spec-flags spec)
    (case (stdio-spec-kind spec)
      ((ignore)         (uv-stdio-ignore))
      ((inherit-fd)     (uv-stdio-inherit-fd))
      ((inherit-stream) (uv-stdio-inherit-stream))
      ((pipe)
       (let ((direction (case (stdio-spec-direction spec)
                          ((to-child)   (uv-stdio-readable-pipe))
                          ((from-child) (uv-stdio-writable-pipe))
                          ((duplex)     (bitwise-ior (uv-stdio-readable-pipe)
                                                     (uv-stdio-writable-pipe)))
                          (else #f))))
         (and direction (bitwise-ior (uv-stdio-create-pipe) direction))))
      (else #f)))

  ;; The stdio containers' offset in the options block.
  (define (stdio-offset) (align-16 (sizeof-uv-process-options-t)))

  ;; One zeroed block holds the options, the stdio containers, the argv and
  ;; env pointer arrays, and the UTF-8 strings; libuv reads it only during
  ;; uv_spawn. Its layout is worked out from the request before the step that
  ;; spawns, and the step allocates the block, fills it, spawns and frees it,
  ;; so no engine can strand it (the step's comment below).

  ;; The process handle's size, and the options block's: its size and where
  ;; its argv and env arrays and its strings begin, as offsets from its
  ;; start.
  (define-record-type options-layout
    (fields handle-size size argv-off env-off strings-off))

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
                                     (if env (* (+ 1 (length env)) ptr-size) 0))))
           ;; Each string and its terminating NUL.
           (add         (lambda (at bv) (+ at (bytevector-length bv) 1)))
           (at          (add strings-off (spawn-request-file request)))
           (at          (if cwd (add at cwd) at))
           (at          (fold-left add at args)))
      (make-options-layout (uv-handle-size (uv-process-type))
                           (fold-left add at (or env '()))
                           argv-off env-off strings-off)))

  ;; fill-options-block! : uptr options-layout spawn-request spawn-options
  ;;                       -> boolean
  ;; Inside the step: writes the options into BLOCK, zeroed and LAYOUT's
  ;; size, and answers #t. It raises nothing: a string that would not fit, or
  ;; a number its C type cannot hold, is not written, and it answers #f. The
  ;; checks refuse both before the step, so only a check that has drifted
  ;; from the fill comes here, and the step then frees both blocks.
  (define (fill-options-block! block layout request options)
    (let ((specs (spawn-options-stdio options)))
      (and (fill-strings-and-arrays! block layout request options)
           (fill-stdio-containers! block specs)
           (fill-scalars! block options (length specs)))))

  ;; fill-strings-and-arrays! : uptr options-layout spawn-request
  ;;                            spawn-options -> boolean
  ;; Each string after the last, in the order the layout summed them, its
  ;; slot pointed at it. The block is zeroed, so the byte after each string
  ;; is its NUL, and zeroed slots end argv and env with NULL. A copy is
  ;; bounded by its source, not by the block, so a string that would not
  ;; fit, with its NUL, is not copied, and the fill answers #f.
  (define (fill-strings-and-arrays! block layout request options)
    (let ((size     (options-layout-size layout))
          (argv-off (options-layout-argv-off layout))
          (env-off  (options-layout-env-off layout))
          (ptr-size (c-uptr-size))
          (env      (spawn-options-env options))
          (cwd      (spawn-options-cwd options)))
      ;; put! : offset bytevector offset -> (or offset #f)
      ;; Copies BV in at offset AT and points the slot at offset SLOT at it;
      ;; answers the offset after its NUL.
      (define (put! slot bv at)
        (let ((next (+ at (bytevector-length bv) 1)))
          (and (<= next size)
               (begin (copy-in-unchecked! (+ block at) bv 0 (bytevector-length bv))
                      (c-uptr-set! (+ block slot) (+ block at))
                      next))))
      ;; put-array! : offset (listof bytevector) offset -> (or offset #f)
      ;; Each of BVS, its pointer in the array at offset OFF.
      (define (put-array! off bvs at)
        (let next ((bvs bvs) (slot off) (at at))
          (if (null? bvs)
              at
              (let ((at (put! slot (car bvs) at)))
                (and at (next (cdr bvs) (+ slot ptr-size) at))))))
      (c-uptr-set! (+ block (offsetof-uv-process-options-t-args)) (+ block argv-off))
      (when env
        (c-uptr-set! (+ block (offsetof-uv-process-options-t-env)) (+ block env-off)))
      (let* ((at (put! (offsetof-uv-process-options-t-file)
                       (spawn-request-file request)
                       (options-layout-strings-off layout)))
             (at (and at (if cwd (put! (offsetof-uv-process-options-t-cwd) cwd at) at)))
             (at (and at (put-array! argv-off (spawn-request-args request) at))))
        (and at (or (not env) (put-array! env-off env at)) #t))))

  ;; fill-stdio-containers! : uptr (listof stdio-spec) -> boolean
  ;; Each spec's container: its flags, and its data at the width of the
  ;; active member, an int for an inherited fd, or the stream's pointer, read
  ;; from the handle the step has just checked (stdio-refusal). Answers #f,
  ;; writing nothing, when a spec has no flags or its fd is no C int.
  (define (fill-stdio-containers! block specs)
    (and (for-all (lambda (spec)
                    (and (stdio-spec-flags spec)
                         (or (not (eq? (stdio-spec-kind spec) 'inherit-fd))
                             (c-int-fd? (stdio-spec-value spec)))))
                  specs)
         (let fill ((ss specs) (c (+ block (stdio-offset))))
           (if (null? ss)
               #t
               (let ((spec (car ss))
                     (data (+ c (offsetof-uv-stdio-container-t-data))))
                 (c-int-set! (+ c (offsetof-uv-stdio-container-t-flags))
                             (stdio-spec-flags spec))
                 (case (stdio-spec-kind spec)
                   ((inherit-fd) (c-int-set! data (stdio-spec-value spec)))
                   ((inherit-stream pipe)
                    (c-uptr-set! data (handle-ptr (stdio-spec-value spec)))))
                 (fill (cdr ss) (+ c (sizeof-uv-stdio-container-t))))))))

  ;; fill-scalars! : uptr spawn-options exact-nonnegative-integer -> boolean
  ;; Setting uid or gid must also set the corresponding libuv flag. Answers
  ;; #f, writing nothing, for a uid or gid that is no unsigned 32-bit int.
  (define (fill-scalars! block options n-stdio)
    (let ((uid (spawn-options-uid options))
          (gid (spawn-options-gid options)))
      (and (or (not uid) (u32? uid))
           (or (not gid) (u32? gid))
           (begin
             (c-int-set! (+ block (offsetof-uv-process-options-t-stdio-count)) n-stdio)
             (when (positive? n-stdio)
               (c-uptr-set! (+ block (offsetof-uv-process-options-t-stdio))
                            (+ block (stdio-offset))))
             (c-int-set! (+ block (offsetof-uv-process-options-t-flags))
                         (bitwise-ior
                          (if (spawn-options-detached? options) (uv-process-detached-flag) 0)
                          (if uid (uv-process-setuid-flag) 0)
                          (if gid (uv-process-setgid-flag) 0)))
             (when uid (c-u32-set! (+ block (offsetof-uv-process-options-t-uid)) uid))
             (when gid (c-u32-set! (+ block (offsetof-uv-process-options-t-gid)) gid))
             #t))))

  ;; alloc-options-block : exact-positive-integer -> uptr
  ;; A zeroed options block of SIZE bytes, counted, or 0, uncounted, when it
  ;; cannot be had (alloc-block).
  (define (alloc-options-block size)
    (let ((block (alloc-block size)))
      (unless (zero? block) (count-spawn-options-new!))
      block))

  ;; free-options-block! : uptr -> unspecified
  ;; Frees and uncounts what alloc-options-block answered; ignores 0.
  (define (free-options-block! block)
    (unless (zero? block)
      (free-block! block)
      (count-spawn-options-free!)))

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
    ;; A caller on the wrong thread is told so before its arguments are
    ;; read, as require-open-handle tells it before a handle's state.
    (require-loop-thread loop 'uv-spawn!)
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
               (made (with-interrupts-disabled
                       (spawn-step! loop on-exit layout request options))))
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
  ;; the process in the loop where the teardown could not close it. And the
  ;; handler can hand the loop to another thread, whose uv_run then races
  ;; uv_spawn on libuv's handle queue (#79).
  ;;
  ;; And an engine can be dropped, as a timeout drops a task, and never
  ;; resumed. Nothing after its expiry runs, so what the verb held then and
  ;; had not handed on was lost: the process handle and the options block,
  ;; allocated and built before the step (test-process.sps's drop sweeps).
  ;;
  ;; So one interrupt-free step checks the loop, its owner and each handle
  ;; again, allocates the process handle and the options block, fills the
  ;; block, hands libuv the pointers it just checked, spawns, frees the
  ;; options block, marks the pipes, and registers the process or cleans up
  ;; after a failure. An engine that expires during uv-spawn! is suspended or dropped
  ;; before the step, holding nothing, or after it, when the loop holds the
  ;; process or the failure is cleaned up (test-process.sps's state and drop
  ;; sweeps).
  ;;
  ;; The step answers the process or a status, and the verb raises after it
  ;; (spawn-refusal). A refused step frees what it allocated. Its
  ;; allocations answer 0 rather than raise, its fill writes no value it has
  ;; not checked (fill-options-block!), and it registers the process before
  ;; uv_spawn, answering a refused registration (spawn-from-block!). One call
  ;; in it can still raise, and only where an invariant outside it is
  ;; broken: the failure cleanup's close, a one-step of its own
  ;; (begin-close!), should uv_close fault.
  ;; with-interrupts-disabled, a dynamic-wind, costs 96 B a spawn over
  ;; one-step, a bare interrupt pair, as it did on a473313. It re-enables
  ;; interrupts after a raise in the step's own body, a fault in uv_spawn
  ;; among them, which arrives as a Scheme condition; after a raise inside
  ;; the close's nested one-step they stay disabled.

  ;; spawn-step! : uv-loop (or procedure #f) options-layout spawn-request
  ;;               spawn-options -> (or uv-process status)
  (define (spawn-step! loop on-exit layout request options)
    (let* ((specs (spawn-options-stdio options))
           (loop-address (owned-loop-ptr loop))
           (refusal (if (refused? loop-address)
                        loop-address
                        (stdio-refusal specs))))
      (if refusal
          refusal
          (let ((ptr (alloc-block (options-layout-handle-size layout)))
                (block (alloc-options-block (options-layout-size layout))))
            (cond ((or (zero? ptr) (zero? block))
                   (free-block! ptr)
                   (free-options-block! block)
                   'no-memory)
                  ((fill-options-block! block layout request options)
                   (spawn-from-block! loop loop-address ptr block specs on-exit))
                  (else
                   (free-block! ptr)
                   (free-options-block! block)
                   'options-not-written))))))

  ;; spawn-from-block! : uv-loop uptr uptr uptr (listof stdio-spec)
  ;;                     (or procedure #f) -> (or uv-process status)
  ;; The rest of the step, once BLOCK holds the options: the process record
  ;; on the handle block at PTR, registered before libuv sees the block, as
  ;; a constructor registers its handle before its init (register-then-init!);
  ;; uv_spawn on the loop at LOOP-ADDRESS; the options block freed; the pipes
  ;; marked; and the process counted, or the failure cleaned up. A refused
  ;; registration frees both blocks and is answered, with nothing forked and
  ;; no pipe marked. Registered after uv_spawn, it raised from the step with
  ;; the child running and its handle in the loop, out of the teardown's
  ;; reach (#68's review).
  (define (spawn-from-block! loop loop-address ptr block specs on-exit)
    (let* ((proc (%make-uv-process-record ptr loop on-exit))
           (registered (registry-add! ptr 'process loop proc)))
      (if (not (eq? registered 'registered))
          (begin (free-block! ptr)
                 (free-options-block! block)
                 registered)
          (let ((rc (uv-spawn-native loop-address ptr block)))
            (free-options-block! block)
            (mark-consumed-pipes! specs)
            (if (zero? rc)
                (begin (count-process-new!) proc)
                (clean-up-failed-spawn! loop proc rc))))))

  ;; stdio-refusal : (listof stdio-spec) -> (or status #f)
  ;; The first spec the entry checks would now refuse for its handle's state:
  ;; open-handle-ptr's refusal paired with the handle, or 'pipe-already-used.
  (define (stdio-refusal specs)
    (exists (lambda (spec)
              (let ((h (stdio-spec-handle spec)))
                (and h
                     (let ((ptr (open-handle-ptr h)))
                       (cond ((refused? ptr) (cons ptr h))
                             ((and (eq? (stdio-spec-kind spec) 'pipe)
                                   (pipe-connected? h))
                              'pipe-already-used)
                             (else #f))))))
            specs))

  ;; spawn-refusal : status -> condition
  ;; What uv-spawn! raises for a status the step answered: what the checks
  ;; on entry raise for the same state, the owner its loop's check found,
  ;; ENOMEM, or libuv's errno. A handle's refusal comes paired with the
  ;; handle (stdio-refusal). Options the fill could not write are the
  ;; binding's own fault, not the caller's: the checks accepted them.
  (define (spawn-refusal status)
    (cond ((pair? status) (step-refusal (car status) 'uv-spawn! (cdr status)))
          ((eq? status 'options-not-written)
           (condition (make-uv-error)
                      (make-who-condition 'uv-spawn!)
                      (make-message-condition
                       "the options block could not hold the options checked for it")))
          (else (step-refusal status 'uv-spawn! #f))))

  ;; clean-up-failed-spawn! : uv-loop uv-process exact-integer -> status
  ;; Spawn failures have opposite cleanups depending on whether libuv left the
  ;; handle in its loop queue. Ask uv_walk; errno values cannot classify this.
  ;; The step registered the handle before uv_spawn. One still in the queue
  ;; keeps its entry and is closed through it; one libuv unlinked loses its
  ;; entry and is freed. A nonzero pid is an unclassifiable partial-success
  ;; state, and the handle is left intact, its entry removed so that no
  ;; teardown closes it. Answers the status the verb raises, RC unless
  ;; unclassifiable.
  (define (clean-up-failed-spawn! loop proc rc)
    (let ((ptr (handle-ptr proc)))
      (cond ((not (zero? (uv-process-get-pid ptr)))
             (registry-remove! ptr)
             'spawn-failure-state-unclassifiable)
            ((handle-in-loop-queue? loop proc)
             (count-process-new!)
             (close-handle! proc)
             rc)
            (else
             (registry-remove! ptr)
             (discard-failed-handle! proc)
             rc))))

  ;; uv-process-kill! and uv-process-pid check again that this thread owns
  ;; the loop and that the process is open (owned-handle-ptr), read its
  ;; pointer and call libuv in one interrupt-free step (one-step), as the
  ;; stream verbs do. Split by an engine between the open check and the
  ;; call, each reached a handle a close had freed meanwhile, and a spawn
  ;; given the freed address was signalled in the process's place, or had
  ;; its pid answered (#71); a kill resumed after a handoff signalled the
  ;; process from a thread that no longer owned its loop (#86;
  ;; tests/test-process-steps.sps). The step answers a status, and the verb
  ;; raises after it (step-refusal): a process closed meanwhile is refused
  ;; with &uv-handle-closed, and a loop handed on with &uv-wrong-thread.

  ;; uv-process-kill! : uv-process (or symbol 0) -> unspecified
  ;; Sending a signal after exit can race operating-system pid reuse.
  (define (uv-process-kill! proc sig)
    (require-open-process proc 'uv-process-kill!)
    (let* ((signum (signal-symbol->int sig 'uv-process-kill!))
           (sent (one-step
                  (let ((ptr (owned-handle-ptr proc)))
                    (if (refused? ptr) ptr (uv-process-kill ptr signum))))))
      (unless (eqv? sent 0)
        (raise (step-refusal sent 'uv-process-kill! proc)))))

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
    (let ((pid (one-step
                (let ((ptr (owned-handle-ptr proc)))
                  (if (refused? ptr) ptr (uv-process-get-pid ptr))))))
      (if (refused? pid)
          (raise (step-refusal pid 'uv-process-pid proc))
          pid)))

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
