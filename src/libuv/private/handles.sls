#!r6rs
;;; Handle and request records, the pointer registry, and callback policy.
;;; The registry is the GC root for open native objects. Closing is explicit;
;;; no guardian or finalizer owns native teardown. Instantiating this library
;;; also installs the process-wide dispatcher layer.
(library (libuv private handles)
  (export ;; the registry
          registry-register! registry-deregister! registry-ref
          registry-loop-of registry-count registry-snapshot-for-loop
          registry-add! registry-remove!

          ;; interrupt-free steps
          one-step open-handle-ptr step-refusal

          ;; loop record
          %make-uv-loop-record uv-loop?
          loop-ptr set-loop-ptr!
          loop-state set-loop-state!
          loop-running? set-loop-running!
          loop-pending-error
          loop-has-pending-error? clear-loop-pending-error!
          loop-deferred-error-list set-loop-deferred-error-list!
          loop-owner-thread set-loop-owner-thread! require-loop-thread
          loop-open? require-open-loop require-loop loop-pointer

          ;; handle records
          %make-uv-handle-record uv-handle? %make-uv-timer-record uv-timer?
          uv-stream-record?
          %make-uv-tcp-record uv-tcp-record?
          %make-uv-pipe-record uv-pipe-record?
          %make-uv-process-record uv-process-record?
          %make-uv-signal-record uv-signal-record?
          signal-on-signal set-signal-on-signal!
          signal-mode set-signal-mode!
          %make-uv-async-record uv-async-record?
          async-on-wake set-async-on-wake!
          async-fence with-send-fence valid-pointer?
          handle-ptr handle-kind handle-loop
          handle-state set-handle-state!
          handle-on-close set-handle-on-close!
          timer-on-timeout set-timer-on-timeout!
          tcp-on-connection set-tcp-on-connection!
          stream-on-data set-stream-on-data!
          stream-on-eof set-stream-on-eof!
          stream-on-error set-stream-on-error!
          stream-read-buf stream-read-buf-len stream-descriptor
          stream-block-size attach-stream-descriptor!
          install-read-buffer! free-read-buffer!
          stream-reading? set-stream-reading!
          pipe-connected? set-pipe-connected!
          process-on-exit process-exited? set-process-exited!
          require-handle require-open-handle handle-pointer

          ;; request records
          %make-uv-req-record uv-req?
          req-ptr set-req-ptr! req-kind req-handle
          req-on-complete set-req-on-complete!

          ;; completion and callback policy
          complete-request! abandon-request! cancel-requests-for-loop!

          loop-record-error!
          record-orphan-callback! orphan-callback-events

          ;; close and dispatcher installation
          close-handle! install-close-handle! close-handle-installed?
          install-dispatch-procedure!
          discard-failed-handle!

          ;; loop-queue query
          handle-in-loop-queue? walk-dispatch)
  (import (rnrs)
          ;; Ahead of (chezscheme): the mutex primitives exist only in a
          ;; threaded Chez (#41; tests/test-require-threaded.sps).
          (libuv private require-threaded)
          (only (chezscheme) make-mutex mutex-acquire mutex-release
                disable-interrupts enable-interrupts)
          (libuv private conditions)
          (only (libuv private native)
                uv-cancel
                uv-loop-stop uv-close-native free!
                count-timer-free! count-tcp-free!
                count-pipe-free! count-process-free!
                count-signal-free! count-async-free!
                count-write-req-free! count-connect-req-free!
                count-read-buffer-new! count-read-buffer-free!
                alloc-block align-16 uv-buf-set! copy-out
                uv-handle-set-data
                uv-errno-condition
                uv-walk-native
                current-thread-id
                dispatcher-names install-callback-dispatchers!)
          (only (libuv private constants) uv-eof sizeof-uv-buf-t errno-symbol->value))

  ;; A unique sentinel is required because R6RS permits (raise #f).
  (define no-pending (list 'no-pending))

  ;; Pointer fields are zeroed at their freeing sites; deferred errors are
  ;; newest first and reversed at the public boundary.
  ;; owner-thread is the id of the only thread allowed to run this loop's verbs
  ;; (#20). It is set to the creating thread here and transferred to the caller
  ;; at uv-run entry (loop.sls), so a loop may be created on one thread and run
  ;; on another. eqv? against current-thread-id gates every handle verb.
  (define-record-type (uv-loop-record %make-uv-loop-record uv-loop?)
    (fields (mutable ptr             loop-ptr             set-loop-ptr!)
            (mutable state           loop-state           set-loop-state!)
            (mutable running         loop-running?        set-loop-running!)
            (mutable pending-error   loop-pending-error   set-loop-pending-error!)
            (mutable deferred-errors loop-deferred-error-list
                                     set-loop-deferred-error-list!)
            (mutable owner-thread    loop-owner-thread    set-loop-owner-thread!))
    (protocol
     (lambda (new)
       (lambda (ptr) (new ptr 'open #f no-pending '() (current-thread-id))))))

  ;; require-loop-thread : uv-loop symbol -> unspecified
  ;; The single affinity predicate. Raised BEFORE any registry mutation, so a
  ;; wrong-thread verb is a named refusal, never the registry corruption it
  ;; would otherwise cause.
  (define (require-loop-thread loop who)
    (let ((owner (loop-owner-thread loop))
          (caller (current-thread-id)))
      (unless (eqv? owner caller)
        (raise (make-uv-wrong-thread who owner caller)))))

  (define (loop-has-pending-error? loop)
    (not (eq? (loop-pending-error loop) no-pending)))

  (define (clear-loop-pending-error! loop)
    (set-loop-pending-error! loop no-pending))

  (define (loop-open? loop)
    (and (uv-loop? loop) (eq? (loop-state loop) 'open)))

  (define (require-loop loop who)
    (unless (uv-loop? loop)
      (raise (make-uv-invalid-argument who 'not-a-uv-loop)))
    loop)

  (define (require-open-loop loop who)
    (require-loop loop who)
    (unless (eq? (loop-state loop) 'open)
      (raise (make-uv-handle-closed 'loop)))
    loop)

  ;; The checked accessor is the only route from a loop record to native code.
  (define (loop-pointer loop who)
    (let ((ptr (loop-ptr loop)))
      (unless (and (integer? ptr) (exact? ptr) (positive? ptr))
        (raise (make-uv-invalid-argument who 'null-loop-pointer)))
      ptr))

  ;; Common handle fields support one open -> closing -> closed protocol.
  (define-record-type (uv-handle-record %make-uv-handle-record uv-handle?)
    (fields (mutable ptr      handle-ptr      set-handle-ptr!)
            (immutable kind   handle-kind)
            (immutable loop   handle-loop)
            (mutable state    handle-state    set-handle-state!)
            (mutable on-close handle-on-close set-handle-on-close!))
    (protocol
     (lambda (new)
       (lambda (ptr kind loop) (new ptr kind loop 'open #f)))))

  (define-record-type (uv-timer-record %make-uv-timer-record uv-timer?)
    (parent uv-handle-record)
    (fields (mutable on-timeout timer-on-timeout set-timer-on-timeout!))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr loop) ((pargs->new ptr 'timer loop) #f)))))

  ;; The reusable read buffer belongs to the handle and is freed only at close.
  ;; read-buf is its block, the payload alone, and read-buf-len its length.
  ;; descriptor is the address of the uv_buf_t in the handle block that
  ;; libuv's alloc callback answers (stream-block-size). reading records
  ;; caller intent; EOF and read errors do not clear it.
  (define-record-type (uv-stream-record %make-uv-stream-record uv-stream-record?)
    (parent uv-handle-record)
    (fields (mutable on-data      stream-on-data      set-stream-on-data!)
            (mutable on-eof       stream-on-eof       set-stream-on-eof!)
            (mutable on-error     stream-on-error     set-stream-on-error!)
            (mutable read-buf     stream-read-buf     set-stream-read-buf!)
            (mutable read-buf-len stream-read-buf-len set-stream-read-buf-len!)
            (mutable reading      stream-reading?     set-stream-reading!)
            (immutable descriptor stream-descriptor))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr kind loop descriptor)
         ((pargs->new ptr kind loop) #f #f #f 0 0 #f descriptor)))))

  ;; A stream record takes the size of libuv's handle, which places its
  ;; descriptor in the block stream-block-size allocated.
  (define-record-type (uv-tcp-record %make-uv-tcp-record uv-tcp-record?)
    (parent uv-stream-record)
    (fields (mutable on-connection tcp-on-connection set-tcp-on-connection!))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr loop handle-size)
         ((pargs->new ptr 'tcp loop (+ ptr (descriptor-offset handle-size))) #f)))))

  ;; connected means consumed by a spawn, independently of handle state.
  (define-record-type (uv-pipe-record %make-uv-pipe-record uv-pipe-record?)
    (parent uv-stream-record)
    (fields (mutable connected pipe-connected? set-pipe-connected!))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr loop handle-size)
         ((pargs->new ptr 'pipe loop (+ ptr (descriptor-offset handle-size))) #f)))))

  ;; Exit updates this record but does not close it.
  (define-record-type (uv-process-record %make-uv-process-record uv-process-record?)
    (parent uv-handle-record)
    (fields (mutable on-exit process-on-exit set-process-on-exit!)
            (mutable exited  process-exited? set-process-exited!))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr loop on-exit) ((pargs->new ptr 'process loop) on-exit #f)))))

  ;; mode is fixed after the first successful start; armed state remains native.
  (define-record-type (uv-signal-record %make-uv-signal-record uv-signal-record?)
    (parent uv-handle-record)
    (fields (mutable on-signal signal-on-signal set-signal-on-signal!)
            (mutable mode      signal-mode      set-signal-mode!))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr loop) ((pargs->new ptr 'signal loop) #f #f)))))

  ;; on-wake runs on the loop thread when a coalesced uv_async_send lands.
  ;; fence is the handle's send fence (#33); see with-send-fence.
  (define-record-type (uv-async-record %make-uv-async-record uv-async-record?)
    (parent uv-handle-record)
    (fields (mutable on-wake async-on-wake set-async-on-wake!)
            (immutable fence async-fence))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr loop on-wake)
         ((pargs->new ptr 'async loop) on-wake (make-mutex))))))

  ;; Requests are not handles: their one block lives until completion and has
  ;; no close state. DNS requests have no owning handle.
  (define-record-type (uv-req-record %make-uv-req-record uv-req?)
    (fields (mutable ptr        req-ptr         set-req-ptr!)
            (immutable kind     req-kind)
            (immutable handle   req-handle)
            (mutable on-complete req-on-complete set-req-on-complete!))
    (protocol
     (lambda (new)
       (lambda (ptr kind handle on-complete)
         (new ptr kind handle on-complete)))))

  (define (require-handle handle who)
    (unless (uv-handle? handle)
      (raise (make-uv-invalid-argument who 'not-a-uv-handle)))
    handle)

  ;; The single central affinity site: every operational verb enters through
  ;; require-open-handle, so the loop-thread check here covers them all with no
  ;; per-verb sprinkling (design §6.3). The thread check comes first — a verb
  ;; from the wrong thread is refused before its handle's open state is even
  ;; consulted. uv-async-send! is the one verb that does NOT come through here
  ;; (it is libuv's sole thread-safe call); it validates kind on its own path in
  ;; (libuv async), and checks open state inside the send fence.
  (define (require-open-handle handle who)
    (require-handle handle who)
    (require-loop-thread (handle-loop handle) who)
    (unless (eq? (handle-state handle) 'open)
      (raise (make-uv-handle-closed (handle-kind handle))))
    handle)

  ;; The checked accessor is the only route from a handle record to native code,
  ;; except inside an interrupt-free step (one-step, the send fence), where
  ;; nothing may raise: a step makes the same check with open-handle-ptr, or
  ;; valid-pointer?, and answers a status instead. The read buffer's install
  ;; and free write a stream's descriptor only while its handle block is
  ;; alive.
  (define (handle-pointer handle who)
    (let ((ptr (handle-ptr handle)))
      (unless (valid-pointer? ptr)
        (raise (make-uv-invalid-argument who 'null-handle-pointer)))
      ptr))

  ;; Pointer values may be bignums, so registry identity uses eqv?, not eq?.
  (define registry (make-eqv-hashtable))

  (define-record-type (registry-entry %make-registry-entry registry-entry?)
    (fields kind loop object))

  (define (valid-pointer? ptr)
    (and (integer? ptr) (exact? ptr) (positive? ptr)))

  (define handle-kinds '(timer tcp pipe process signal async))

  (define dns-request-kinds '(getaddrinfo-req getnameinfo-req))

  ;; registry-add! : uptr symbol uv-loop object
  ;;                 -> (or 'registered 'null-or-invalid-pointer
  ;;                        'loop-not-a-uv-loop 'pointer-already-registered)
  ;; The registry's sole write site. It validates the loop so callback
  ;; containment can always find a valid error cell without raising from its
  ;; handler. A refusal is answered, not raised, so a verb can register from
  ;; inside an interrupt-free step (one-step).
  (define (registry-add! ptr kind loop object)
    (cond ((not (valid-pointer? ptr)) 'null-or-invalid-pointer)
          ((not (uv-loop? loop)) 'loop-not-a-uv-loop)
          ((hashtable-contains? registry ptr) 'pointer-already-registered)
          (else (hashtable-set! registry ptr (%make-registry-entry kind loop object))
                'registered)))

  ;; registry-register! : uptr symbol uv-loop object -> object
  ;; registry-add!, raising its refusal.
  (define (registry-register! ptr kind loop object)
    (let ((status (registry-add! ptr kind loop object)))
      (unless (eq? status 'registered)
        (raise (make-uv-invalid-argument 'uv-registry-register! status)))
      object))

  ;; registry-remove! : uptr -> unspecified
  ;; registry-deregister! for a step: removes PTR's entry if it has one, and
  ;; raises nothing.
  (define (registry-remove! ptr)
    (hashtable-delete! registry ptr))

  ;; (one-step body ...) runs BODY as one interrupt-free step and answers its
  ;; value. Neither an engine's timer nor a collect request is taken inside
  ;; it, so nothing else runs on this thread between a verb's checks and the
  ;; native call they guard, and an engine is suspended, or dropped, either
  ;; before the step or after it, never inside.
  ;; - Split by an engine, a verb's open check stops covering its native
  ;;   call: a close can free the handle in between (#33 for a send; the
  ;;   stream verbs' sweeps in test-stream.sps). Dropped there, a verb
  ;;   strands whatever it had allocated and not yet handed on.
  ;; - It is a bare disable-interrupts/enable-interrupts pair, not
  ;;   with-interrupts-disabled, which is a dynamic-wind: about 96 B a step
  ;;   around a copy (ADR-0019's decision 3 amendment of 2026-10-06).
  ;; - BODY must not raise: interrupts would stay disabled for good. It
  ;;   checks what can fail and answers a status, makes only calls that are
  ;;   total for their arguments (alloc-block, registry-add!), and the verb
  ;;   raises after the step (step-refusal). A fault in a native call inside
  ;;   it still leaves interrupts disabled; begin-close! has always accepted
  ;;   that.
  ;; - BODY must not wait. This thread stays active throughout, so another
  ;;   thread's collection waits for the step to end.
  (define-syntax one-step
    (syntax-rules ()
      ((_ body1 body2 ...)
       (begin (disable-interrupts)
              (let ((result (begin body1 body2 ...)))
                (enable-interrupts)
                result)))))

  ;; open-handle-ptr : uv-handle -> (or uptr 'not-open 'no-pointer)
  ;; For a step: HANDLE's pointer, when it is open and has one. The open
  ;; check a verb makes on entry does not cover a native call an engine can
  ;; suspend it before, so the step checks again.
  (define (open-handle-ptr handle)
    (let ((ptr (handle-ptr handle)))
      (cond ((not (eq? (handle-state handle) 'open)) 'not-open)
            ((not (valid-pointer? ptr)) 'no-pointer)
            (else ptr))))

  ;; step-refusal : (or symbol exact-integer) symbol uv-handle -> condition
  ;; What verb WHO raises, once its step is over, for a step on HANDLE that
  ;; answered STATUS instead of starting. A closed handle and a missing
  ;; pointer are the refusals the checked accessors raise outside a step; a
  ;; refused registration is registry-register!'s; an integer is libuv's
  ;; errno. Any other symbol is a refusal of WHO's own argument, and names it.
  (define (step-refusal status who handle)
    (case status
      ((not-open) (make-uv-handle-closed (handle-kind handle)))
      ((no-pointer) (make-uv-invalid-argument who 'null-handle-pointer))
      ((no-memory) (uv-errno-condition (errno-symbol->value 'ENOMEM) who))
      ((null-or-invalid-pointer loop-not-a-uv-loop pointer-already-registered)
       (make-uv-invalid-argument 'uv-registry-register! status))
      (else (if (symbol? status)
                (make-uv-invalid-argument who status)
                (uv-errno-condition status who)))))

  (define (registry-deregister! ptr)
    (let ((entry (hashtable-ref registry ptr #f)))
      (unless entry
        (raise (make-uv-invalid-argument 'uv-registry-deregister!
                                         'pointer-not-registered)))
      (hashtable-delete! registry ptr)
      (registry-entry-object entry)))

  (define (registry-ref ptr)
    (let ((entry (hashtable-ref registry ptr #f)))
      (and entry (registry-entry-object entry))))

  (define (registry-loop-of ptr)
    (let ((entry (hashtable-ref registry ptr #f)))
      (and entry (registry-entry-loop entry))))

  (define (registry-count) (hashtable-size registry))

  ;; Snapshot handles only. Requests stay out of the close sweep.
  (define (registry-snapshot-for-loop loop)
    (let-values (((keys entries) (hashtable-entries registry)))
      (let collect ((i 0) (acc '()))
        (if (= i (vector-length entries))
            acc
            (let ((entry (vector-ref entries i)))
              (collect (+ i 1)
                       (if (and (eq? (registry-entry-loop entry) loop)
                                (memq (registry-entry-kind entry) handle-kinds))
                           (cons (registry-entry-object entry) acc)
                           acc)))))))

  ;; Best-effort cancellation of handle-less DNS requests. Ignore return codes:
  ;; teardown drains either the cancellation or the real completion.
  (define (cancel-requests-for-loop! loop)
    (let-values (((keys entries) (hashtable-entries registry)))
      (do ((i 0 (+ i 1)))
          ((= i (vector-length entries)))
        (let ((entry (vector-ref entries i)))
          (when (and (eq? (registry-entry-loop entry) loop)
                     (memq (registry-entry-kind entry) dns-request-kinds))
            (uv-cancel (vector-ref keys i)))))))

  ;; Never raise through a C callback frame. Store the first object and stop the
  ;; loop; retain later objects for inspection.
  (define (loop-record-error! loop obj)
    (require-loop loop 'uv-loop-record-error!)
    (if (loop-has-pending-error? loop)
        (set-loop-deferred-error-list!
         loop (cons obj (loop-deferred-error-list loop)))
        (begin
          (set-loop-pending-error! loop obj)
          (when (and (eq? (loop-state loop) 'open)
                     (valid-pointer? (loop-ptr loop)))
            (uv-loop-stop (loop-ptr loop))))))

  ;; An orphan callback has no owning loop on which to report an error.
  (define orphan-events '())

  (define (record-orphan-callback! kind ptr)
    (set! orphan-events (cons (cons kind ptr) orphan-events)))

  (define (orphan-callback-events) (reverse orphan-events))

  ;; Handle callbacks require open state; request callbacks remain deliverable
  ;; while their handle is closing.
  ;;
  ;; A dispatcher receives the object registered under the callback's pointer,
  ;; or #f, ahead of libuv's arguments: the seam has already looked it up
  ;; (#45). It calls user code directly and last: the seam contains whatever
  ;; user code raises, and a raise skips none of the dispatcher's own steps.
  (define (timer-dispatch handle handle-ptr)
    (if (uv-timer? handle)
        (when (eq? (handle-state handle) 'open)
          (let ((on-timeout (timer-on-timeout handle)))
            (when on-timeout (on-timeout handle))))
        (record-orphan-callback! 'timer handle-ptr)))

  ;; Callback statuses become condition values; they are never raised here.
  (define (status->err status who)
    (if (zero? status) #f (uv-errno-condition status who)))

  (define (connection-dispatch server server-ptr status)
    (if (uv-tcp-record? server)
        (let ((on-connection (tcp-on-connection server)))
          (when on-connection
            (on-connection (status->err status 'uv-listen!))))
        (record-orphan-callback! 'connection server-ptr)))

  ;; Deregister and free the complete request block before invoking user code.
  ;; REQ is what the seam found registered under BLOCK-PTR. Extra payloads
  ;; must already be Scheme-owned values.
  (define (complete-request! name who count-free! req block-ptr status . extras)
    (if (uv-req? req)
        (let ((on-complete (req-on-complete req)))
          (registry-deregister! block-ptr)
          (free! block-ptr)
          (count-free!)
          (set-req-ptr! req 0)
          (when on-complete
            (apply on-complete (status->err status who) extras)))
        (record-orphan-callback! name block-ptr)))

  ;; Synchronous-start failure uses the same release order without a callback.
  (define (abandon-request! req)
    (let ((ptr (req-ptr req)))
      (registry-deregister! ptr)
      (free! ptr)
      (set-req-ptr! req 0)))

  (define (write-done-dispatch req req-ptr status)
    (complete-request! 'write-done 'uv-write! count-write-req-free!
                       req req-ptr status))

  (define (connect-dispatch req req-ptr status)
    (complete-request! 'connect 'uv-tcp-connect! count-connect-req-free!
                       req req-ptr status))

  (define (no-request-counter) #f)

  (define (shutdown-dispatch req req-ptr status)
    (complete-request! 'shutdown 'uv-shutdown! no-request-counter
                       req req-ptr status))

  ;; nread is signed so UV_EOF cannot masquerade as a huge positive read. The
  ;; buffer argument is ignored; the registered handle owns the trusted base.
  (define (read-dispatch handle stream-ptr nread buf-ptr)
    (if (uv-stream-record? handle)
        (cond ((positive? nread) (deliver-read-data! handle nread))
              ((zero? nread) #f)
              ((= nread (uv-eof)) (deliver-read-eof! handle))
              (else (deliver-read-error! handle nread)))
        (record-orphan-callback! 'read stream-ptr)))

  (define (deliver-read-data! handle nread)
    (let ((on-data (stream-on-data handle)))
      (when on-data
        (on-data (copy-out (stream-read-buf handle) nread) 0 nread))))

  (define (deliver-read-eof! handle)
    (let ((on-eof (stream-on-eof handle)))
      (when on-eof (on-eof))))

  (define (deliver-read-error! handle nread)
    (let ((on-error (stream-on-error handle)))
      (when on-error
        (on-error (uv-errno-condition nread 'uv-read-start!)))))

  ;; The close callback is the sole handle-freeing site. Deregister, free the
  ;; read buffer and handle, zero the pointer, mark closed, then call user code.
  (define (close-dispatch handle handle-ptr)
    (if (uv-handle? handle)
        (begin
          (registry-deregister! handle-ptr)
          (free-read-buffer! handle)
          (free! handle-ptr)
          (count-handle-free! (handle-kind handle))
          (set-handle-ptr! handle 0)
          (set-handle-state! handle 'closed)
          (let ((on-close (handle-on-close handle)))
            (when on-close (on-close))))
        (record-orphan-callback! 'close handle-ptr)))

  ;; A stream's handle block is libuv's handle, then, at the first 16-byte
  ;; boundary after it, the uv_buf_t descriptor that the shim's alloc callback
  ;; answers libuv with before every read (#45; ADR-0002, amended
  ;; 2026-10-05). The handle's data points at it from creation, and it
  ;; outlives every alloc callback because libuv is done with the handle
  ;; block only once the close dispatcher frees it. The read buffer is then
  ;; exactly its payload: behind a 16-byte header, a 64 KiB buffer took the
  ;; next malloc size class on macOS, 81,920 B, while a 264 B uv_tcp_t and
  ;; its 288 B block both take 320 B.
  (define (descriptor-offset handle-size) (align-16 handle-size))

  ;; stream-block-size : exact-positive-integer -> exact-positive-integer
  ;; The bytes to allocate for a stream whose libuv handle is HANDLE-SIZE.
  (define (stream-block-size handle-size)
    (+ (descriptor-offset handle-size) (sizeof-uv-buf-t)))

  ;; attach-stream-descriptor! : uv-stream -> unspecified
  ;; Points the handle's data at its descriptor, for the stream's whole life:
  ;; the one write of data in src/ (tests/test-source-rules.sps). The block
  ;; is zeroed, so until the first read start the descriptor is the empty
  ;; buffer, which libuv reports as UV_ENOBUFS.
  (define (attach-stream-descriptor! stream)
    (uv-handle-set-data (handle-pointer stream 'uv-attach-stream-descriptor!)
                        (stream-descriptor stream)))

  ;; install-read-buffer! : uv-stream object
  ;;                        -> (or 'installed 'not-open 'buffered 'no-memory)
  ;; Gives an open STREAM with no read buffer one of SIZE bytes, and answers
  ;; 'installed, or what stood in the way. The checks, the allocation, and the
  ;; fill of the descriptor and the record are one interrupt-free step. So no
  ;; engine or interrupt can come between a check and the fill, or into the
  ;; fill (tests/test-tcp.sps's install sweeps), and none can drop a start
  ;; holding a block it has not installed (tests/test-stream.sps's drop
  ;; sweep). The open check keeps a start suspended while its stream closed
  ;; from writing the descriptor into the freed handle block: a stream stops
  ;; being open when its close begins, before the close dispatcher frees the
  ;; block. Nothing in it raises, since alloc-block answers 0 for a size it
  ;; cannot allocate, so a read start makes it inside its own step
  ;; (stream.sls), where it nests.
  (define (install-read-buffer! stream size)
    (one-step
     (cond ((not (eq? (handle-state stream) 'open)) 'not-open)
           ((not (zero? (stream-read-buf stream))) 'buffered)
           (else
            (let ((block (alloc-block size)))
              (if (zero? block)
                  'no-memory
                  (begin (uv-buf-set! (stream-descriptor stream) block size)
                         (set-stream-read-buf! stream block)
                         (set-stream-read-buf-len! stream size)
                         (count-read-buffer-new!)
                         'installed)))))))

  ;; free-read-buffer! : uv-handle -> unspecified
  ;; Empties the descriptor before the block goes, so it never names freed
  ;; memory, in the same interrupt-free step as clearing the record. A zero
  ;; buffer means reading never started; free! deliberately rejects zero.
  (define (free-read-buffer! handle)
    (when (uv-stream-record? handle)
      (disable-interrupts)
      (let ((buf (stream-read-buf handle)))
        (when (valid-pointer? buf)
          (uv-buf-set! (stream-descriptor handle) 0 0)
          (set-stream-read-buf! handle 0)
          (set-stream-read-buf-len! handle 0)
          (count-read-buffer-free!))
        (enable-interrupts)
        (when (valid-pointer? buf) (free! buf)))))

  (define (count-handle-free! kind)
    (case kind
      ((timer)   (count-timer-free!))
      ((tcp)     (count-tcp-free!))
      ((pipe)    (count-pipe-free!))
      ((process) (count-process-free!))
      ((signal)  (count-signal-free!))
      ((async)   (count-async-free!))
      (else #f)))

  ;; Direct free is valid only for a spawn failure libuv already unlinked.
  (define (discard-failed-handle! handle)
    (require-handle handle 'uv-discard-failed-handle!)
    (let ((ptr (handle-pointer handle 'uv-discard-failed-handle!)))
      (when (registry-ref ptr)
        (raise (make-uv-invalid-argument 'uv-discard-failed-handle!
                                         'failed-handle-still-registered)))
      (free! ptr)
      (set-handle-ptr! handle 0)
      (set-handle-state! handle 'closed)))

  ;; uv_walk is synchronous, so one resettable cell can collect its pointers.
  (define walk-query-cell '())

  (define (walk-dispatch walked walked-ptr arg)
    (set! walk-query-cell (cons walked-ptr walk-query-cell)))

  (define (handle-in-loop-queue? loop handle)
    (set! walk-query-cell '())
    (uv-walk-native (loop-ptr loop) 0)
    (and (memv (handle-ptr handle) walk-query-cell) #t))

  ;; (with-send-fence async body ...) runs BODY holding ASYNC's send fence
  ;; (#33), the lock that orders uv-async-send! against uv-close!. The send's
  ;; open check and native call run inside it, and so does the close's whole
  ;; step (begin-close!). So no close begins while a send is between its check
  ;; and its call, and no send gets past the check once a close has begun.
  ;;
  ;; The fence is taken and released only with interrupts disabled, so no
  ;; thread ever holds it where an engine can suspend it or a collection can
  ;; stop it. Held across either, an abandoned engine would keep it for good,
  ;; and a collection could wait for a thread that waits for the fence. That
  ;; rules out with-mutex: it releases in a dynamic-wind exit thunk, after the
  ;; winder is gone, at a point where an engine can be suspended (the review
  ;; of #43). tests/test-async-fence.sps probes every such point from another
  ;; thread.
  ;; - A thread that finds the fence taken waits for it inside the same
  ;;   interrupt-free step, so it stays active while it waits. The holder is
  ;;   always running a BODY, which never waits on anything, so the wait is
  ;;   short, and no collection can be waiting on the holder meanwhile.
  ;; - BODY must not raise or block: a raise would leave the fence held and
  ;;   interrupts disabled. The bodies check what could fault, the state and
  ;;   the pointer, and answer a status; their callers raise after.
  (define-syntax with-send-fence
    (syntax-rules ()
      ((_ async body1 body2 ...)
       (let ((fence (async-fence async)))
         (disable-interrupts)
         (mutex-acquire fence)
         (let ((result (begin body1 body2 ...)))
           (mutex-release fence)
           (enable-interrupts)
           result)))))

  ;; Starting close is idempotent and asynchronous. A repeated call cannot
  ;; replace the original on-close callback.
  (define (real-close-handle! handle on-close)
    (require-handle handle 'uv-close!)
    (unless (or (not on-close) (procedure? on-close))
      (raise (make-uv-invalid-argument 'uv-close! 'on-close-not-a-procedure)))
    (when (eq? (begin-close! handle on-close) 'no-pointer)
      (raise (make-uv-invalid-argument 'uv-close! 'null-handle-pointer))))

  ;; begin-close! : uv-handle (or procedure #f)
  ;;                -> (or 'closing 'not-open 'no-pointer)
  ;; Starts an open handle's close in one step: the open check, the move to
  ;; closing, and libuv's uv_close, with interrupts disabled throughout.
  ;; Split by an engine, two closes of one handle could both see it open and
  ;; both call uv_close, or the handle could read closing while libuv had not
  ;; begun to close it (test-timer.sps's close sweep). An async takes the step
  ;; inside its send fence, so the close also waits for a send past its open
  ;; check, and every later send sees the handle closing. Nothing here may
  ;; raise (see with-send-fence): the caller raises for 'no-pointer.
  (define (begin-close! handle on-close)
    (define (close-if-open!)
      (let ((ptr (open-handle-ptr handle)))
        (if (symbol? ptr)
            ptr
            (begin (set-handle-on-close! handle on-close)
                   (set-handle-state! handle 'closing)
                   (uv-close-native ptr)
                   'closing))))
    (if (uv-async-record? handle)
        (with-send-fence handle (close-if-open!))
        (one-step (close-if-open!))))

  (define close-handle-proc
    (lambda (handle on-close)
      (raise (condition
              (make-uv-error)
              (make-who-condition 'uv-close-handle!)
              (make-message-condition
               "no handle close procedure has been installed")))))

  (define close-handle-installed #f)

  (define (close-handle-installed?) close-handle-installed)

  (define close-handle!
    (case-lambda
      ((handle) (close-handle-proc handle #f))
      ((handle on-close) (close-handle-proc handle on-close))))

  (define (install-close-handle! proc)
    (when close-handle-installed
      (raise (make-uv-invalid-argument 'uv-install-close-handle!
                                       'close-handle-already-installed)))
    (unless (procedure? proc)
      (raise (make-uv-invalid-argument 'uv-install-close-handle!
                                       'not-a-procedure)))
    (set! close-handle-proc proc)
    (set! close-handle-installed #t))

  ;; Native callback slots are installed once; this table permits each policy
  ;; implementation to arrive later without rebinding a native trampoline.
  (define dispatch-table (make-eq-hashtable))

  (define (unimplemented-dispatcher name)
    (lambda args
      (raise (condition
              (make-uv-error)
              (make-who-condition name)
              (make-message-condition
               "this callback type is not implemented in this version")))))

  (define (dispatch-procedure name)
    (or (hashtable-ref dispatch-table name #f)
        (raise (make-uv-invalid-argument 'uv-dispatch-procedure
                                         'unknown-dispatcher))))

  (define (install-dispatch-procedure! name proc)
    (unless (memq name dispatcher-names)
      (raise (make-uv-invalid-argument 'uv-install-dispatch-procedure!
                                       'unknown-dispatcher)))
    (unless (procedure? proc)
      (raise (make-uv-invalid-argument 'uv-install-dispatch-procedure!
                                       'not-a-procedure)))
    (when (memq name installed-dispatch-names)
      (raise (make-uv-invalid-argument 'uv-install-dispatch-procedure!
                                       'dispatch-procedure-already-installed)))
    (hashtable-set! dispatch-table name proc)
    (set! installed-dispatch-names (cons name installed-dispatch-names)))

  (define installed-dispatch-names '(timer close))

  ;; This is the outermost Scheme error boundary reachable from libuv, and
  ;; the only one a callback crosses (#45). ENTRY is what the seam found
  ;; registered under PTR before dispatch: a dispatcher deregisters a
  ;; completing request or a closing handle before it calls user code, and
  ;; the address may belong to another object by the time a raise arrives.
  (define (contain-dispatcher-raise! name ptr entry obj)
    (if entry
        (loop-record-error! (registry-entry-loop entry) obj)
        (record-orphan-callback! name ptr)))

  ;; (seam-lambda name (ptr arg ...) ...) is a case-lambda with one clause
  ;; per argument list, so a callback's arguments are never gathered into a
  ;; rest list. Each clause looks PTR up in the registry once, hands the
  ;; dispatcher the registered object, and contains every raise with one
  ;; guard; an else clause takes Chez's cheaper guard path. A one-shot
  ;; continuation would allocate less for an empty callback, but a callback
  ;; that captures a full continuation, as its own guard does, promotes it and
  ;; copies the stack: about 4 KB a callback on the mean
  ;; (tests/test-callback-alloc.sps holds both).
  (define-syntax seam-lambda
    (syntax-rules ()
      ((_ name (ptr arg ...) ...)
       (case-lambda
         ((ptr arg ...)
          (let ((entry (hashtable-ref registry ptr #f)))
            (guard (e (else (contain-dispatcher-raise! name ptr entry e)))
              ((dispatch-procedure name)
               (and entry (registry-entry-object entry)) ptr arg ...))))
         ...))))

  ;; (seams name ...) builds each seam with its name as a literal, so no
  ;; closure inside it captures the name: one variable fewer is 16 B less on
  ;; every callback. The trampolines pass one to four arguments (native.sls).
  ;; install-callback-dispatchers! refuses a set that does not name every
  ;; slot in dispatcher-names exactly once.
  (define-syntax seams
    (syntax-rules ()
      ((_ name ...)
       (list (cons 'name (seam-lambda 'name (a) (a b) (a b c) (a b c d))) ...))))

  ;; Use definitions for library-body effects; R6RS requires definitions before
  ;; expressions, and wiring must complete before a callback can fire.
  (define dispatchers-wired
    (begin
      (for-each (lambda (name)
                  (hashtable-set! dispatch-table name
                                  (unimplemented-dispatcher name)))
                dispatcher-names)
      (hashtable-set! dispatch-table 'timer timer-dispatch)
      (hashtable-set! dispatch-table 'close close-dispatch)
      (for-each (lambda (entry)
                  (install-dispatch-procedure! (car entry) (cdr entry)))
                (list (cons 'connection connection-dispatch)
                      (cons 'write-done write-done-dispatch)
                      (cons 'shutdown   shutdown-dispatch)
                      (cons 'connect    connect-dispatch)
                      (cons 'read       read-dispatch)))
      (install-callback-dispatchers!
       (seams read connection write-done close timer shutdown connect
              getaddrinfo getnameinfo exit walk signal async))
      (install-close-handle! real-close-handle!)
      'wired)))
