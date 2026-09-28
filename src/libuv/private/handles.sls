#!r6rs
;;; Handle and request records, the pointer registry, and callback policy.
;;; The registry is the GC root for open native objects. Closing is explicit;
;;; no guardian or finalizer owns native teardown. Instantiating this library
;;; also installs the process-wide dispatcher layer.
(library (libuv private handles)
  (export ;; the registry
          registry-register! registry-deregister! registry-ref
          registry-loop-of registry-count registry-snapshot-for-loop

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
          async-fence with-send-fence
          handle-ptr handle-kind handle-loop
          handle-state set-handle-state!
          handle-on-close set-handle-on-close!
          timer-on-timeout set-timer-on-timeout!
          tcp-on-connection set-tcp-on-connection!
          stream-on-data set-stream-on-data!
          stream-on-eof set-stream-on-eof!
          stream-on-error set-stream-on-error!
          stream-read-buf set-stream-read-buf!
          stream-read-buf-len set-stream-read-buf-len!
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

          loop-record-error! dispatch-guarded
          record-orphan-callback! orphan-callback-events

          ;; close and dispatcher installation
          close-handle! install-close-handle! close-handle-installed?
          install-dispatch-procedure!
          discard-failed-handle!

          ;; loop-queue query
          handle-in-loop-queue? walk-dispatch)
  (import (rnrs)
          ;; Ahead of (chezscheme): make-mutex and with-mutex exist only in a
          ;; threaded Chez (#41; tests/test-require-threaded.sps).
          (libuv private require-threaded)
          (only (chezscheme) make-mutex with-mutex with-interrupts-disabled)
          (libuv private conditions)
          (only (libuv private native)
                uv-cancel
                uv-loop-stop uv-close-native free!
                count-timer-free! count-tcp-free!
                count-pipe-free! count-process-free!
                count-signal-free! count-async-free!
                count-write-req-free! count-connect-req-free!
                count-read-buffer-free!
                uv-buf-set! copy-out
                uv-errno-condition
                uv-walk-native
                current-thread-id
                dispatcher-names install-callback-dispatchers!)
          (only (libuv private constants) uv-eof))

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
  ;; reading records caller intent; EOF and read errors do not clear it.
  (define-record-type (uv-stream-record %make-uv-stream-record uv-stream-record?)
    (parent uv-handle-record)
    (fields (mutable on-data      stream-on-data      set-stream-on-data!)
            (mutable on-eof       stream-on-eof       set-stream-on-eof!)
            (mutable on-error     stream-on-error     set-stream-on-error!)
            (mutable read-buf     stream-read-buf     set-stream-read-buf!)
            (mutable read-buf-len stream-read-buf-len set-stream-read-buf-len!)
            (mutable reading      stream-reading?     set-stream-reading!))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr kind loop) ((pargs->new ptr kind loop) #f #f #f 0 0 #f)))))

  (define-record-type (uv-tcp-record %make-uv-tcp-record uv-tcp-record?)
    (parent uv-stream-record)
    (fields (mutable on-connection tcp-on-connection set-tcp-on-connection!))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr loop) ((pargs->new ptr 'tcp loop) #f)))))

  ;; connected means consumed by a spawn, independently of handle state.
  (define-record-type (uv-pipe-record %make-uv-pipe-record uv-pipe-record?)
    (parent uv-stream-record)
    (fields (mutable connected pipe-connected? set-pipe-connected!))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr loop) ((pargs->new ptr 'pipe loop) #f)))))

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
  ;; except inside the send fence: no raise is allowed there, and uv-async-send!
  ;; reads the pointer only after seeing the handle open.
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

  ;; registry-register! : uptr symbol uv-loop object -> object
  ;; Validate the loop at the sole write site so callback containment can always
  ;; find a valid error cell without raising from its handler.
  (define (registry-register! ptr kind loop object)
    (unless (valid-pointer? ptr)
      (raise (make-uv-invalid-argument 'uv-registry-register!
                                       'null-or-invalid-pointer)))
    (unless (uv-loop? loop)
      (raise (make-uv-invalid-argument 'uv-registry-register!
                                       'loop-not-a-uv-loop)))
    (when (hashtable-contains? registry ptr)
      (raise (make-uv-invalid-argument 'uv-registry-register!
                                       'pointer-already-registered)))
    (hashtable-set! registry ptr (%make-registry-entry kind loop object))
    object)

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

  ;; Catch every raised object, not just conditions.
  (define (dispatch-guarded loop thunk)
    (guard (e (#t (loop-record-error! loop e)))
      (thunk)))

  ;; An orphan callback has no owning loop on which to report an error.
  (define orphan-events '())

  (define (record-orphan-callback! kind ptr)
    (set! orphan-events (cons (cons kind ptr) orphan-events)))

  (define (orphan-callback-events) (reverse orphan-events))

  ;; Handle callbacks require open state; request callbacks remain deliverable
  ;; while their handle is closing.
  (define (timer-dispatch handle-ptr)
    (let ((handle (registry-ref handle-ptr)))
      (if (uv-timer? handle)
          (when (eq? (handle-state handle) 'open)
            (let ((on-timeout (timer-on-timeout handle)))
              (when on-timeout
                (dispatch-guarded (handle-loop handle)
                                  (lambda () (on-timeout handle))))))
          (record-orphan-callback! 'timer handle-ptr))))

  ;; Callback statuses become condition values; they are never raised here.
  (define (status->err status who)
    (if (zero? status) #f (uv-errno-condition status who)))

  (define (connection-dispatch server-ptr status)
    (let ((server (registry-ref server-ptr)))
      (if (uv-tcp-record? server)
          (let ((on-connection (tcp-on-connection server)))
            (when on-connection
              (dispatch-guarded
               (handle-loop server)
               (lambda () (on-connection (status->err status 'uv-listen!))))))
          (record-orphan-callback! 'connection server-ptr))))

  ;; Deregister and free the complete request block before invoking user code.
  ;; Extra payloads must already be Scheme-owned values.
  (define (complete-request! name who count-free! block-ptr status . extras)
    (let ((req (registry-ref block-ptr)))
      (if (uv-req? req)
          (let ((loop (registry-loop-of block-ptr))
                (on-complete (req-on-complete req)))
            (registry-deregister! block-ptr)
            (free! block-ptr)
            (count-free!)
            (set-req-ptr! req 0)
            (when on-complete
              (dispatch-guarded
               loop
               (lambda ()
                 (apply on-complete (status->err status who) extras)))))
          (record-orphan-callback! name block-ptr))))

  ;; Synchronous-start failure uses the same release order without a callback.
  (define (abandon-request! req)
    (let ((ptr (req-ptr req)))
      (registry-deregister! ptr)
      (free! ptr)
      (set-req-ptr! req 0)))

  (define (write-done-dispatch req-ptr status)
    (complete-request! 'write-done 'uv-write! count-write-req-free!
                       req-ptr status))

  (define (connect-dispatch req-ptr status)
    (complete-request! 'connect 'uv-tcp-connect! count-connect-req-free!
                       req-ptr status))

  (define (no-request-counter) #f)

  (define (shutdown-dispatch req-ptr status)
    (complete-request! 'shutdown 'uv-shutdown! no-request-counter
                       req-ptr status))

  ;; This dispatcher must remain infallible: it can only return the existing
  ;; handle buffer or a zero-length buffer. libuv provides no alloc error path.
  (define (alloc-dispatch handle-ptr suggested buf-ptr)
    (let ((handle (registry-ref handle-ptr)))
      (if (and (uv-stream-record? handle)
               (valid-pointer? (stream-read-buf handle)))
          (uv-buf-set! buf-ptr (stream-read-buf handle) (stream-read-buf-len handle))
          (uv-buf-set! buf-ptr 0 0))))

  ;; nread is signed so UV_EOF cannot masquerade as a huge positive read. The
  ;; buffer argument is ignored; the registered handle owns the trusted base.
  (define (read-dispatch stream-ptr nread buf-ptr)
    (let ((handle (registry-ref stream-ptr)))
      (if (uv-stream-record? handle)
          (cond ((positive? nread) (deliver-read-data! handle nread))
                ((zero? nread) #f)
                ((= nread (uv-eof)) (deliver-read-eof! handle))
                (else (deliver-read-error! handle nread)))
          (record-orphan-callback! 'read stream-ptr))))

  (define (deliver-read-data! handle nread)
    (let ((on-data (stream-on-data handle)))
      (when on-data
        (dispatch-guarded
         (handle-loop handle)
         (lambda ()
           (on-data (copy-out (stream-read-buf handle) nread) 0 nread))))))

  (define (deliver-read-eof! handle)
    (let ((on-eof (stream-on-eof handle)))
      (when on-eof
        (dispatch-guarded (handle-loop handle) on-eof))))

  (define (deliver-read-error! handle nread)
    (let ((on-error (stream-on-error handle)))
      (when on-error
        (dispatch-guarded
         (handle-loop handle)
         (lambda () (on-error (uv-errno-condition nread 'uv-read-start!)))))))

  ;; The close callback is the sole handle-freeing site. Deregister, free the
  ;; read buffer and handle, zero the pointer, mark closed, then call user code.
  (define (close-dispatch handle-ptr)
    (let ((handle (registry-ref handle-ptr)))
      (if (uv-handle? handle)
          (begin
            (registry-deregister! handle-ptr)
            (free-read-buffer! handle)
            (free! handle-ptr)
            (count-handle-free! (handle-kind handle))
            (set-handle-ptr! handle 0)
            (set-handle-state! handle 'closed)
            (let ((on-close (handle-on-close handle)))
              (when on-close
                (dispatch-guarded (handle-loop handle) on-close))))
          (record-orphan-callback! 'close handle-ptr))))

  ;; A zero buffer means reading never started; free! deliberately rejects zero.
  (define (free-read-buffer! handle)
    (when (uv-stream-record? handle)
      (let ((buf (stream-read-buf handle)))
        (when (valid-pointer? buf)
          (free! buf)
          (count-read-buffer-free!)
          (set-stream-read-buf! handle 0)
          (set-stream-read-buf-len! handle 0)))))

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

  (define (walk-dispatch walked-ptr arg)
    (set! walk-query-cell (cons walked-ptr walk-query-cell)))

  (define (handle-in-loop-queue? loop handle)
    (set! walk-query-cell '())
    (uv-walk-native (loop-ptr loop) 0)
    (and (memv (handle-ptr handle) walk-query-cell) #t))

  ;; (with-send-fence async body ...) runs BODY holding ASYNC's send fence
  ;; (#33), the lock that orders uv-async-send! against uv-close!. The send's
  ;; open check and native call run inside it, and so does the close's
  ;; open -> closing step (begin-close!). So no close begins while a send is
  ;; between its check and its call, and no send gets past the check once a
  ;; close has begun.
  ;; - The fence is taken with interrupts enabled. A thread blocked taking it
  ;;   is then deactivated, so another thread's collection is not refused.
  ;; - BODY runs with interrupts disabled, so no engine suspends it there.
  ;;   with-mutex is a dynamic-wind: a suspension would release the fence and
  ;;   resume BODY after a close, on a stale check.
  ;; - BODY must not raise. A with-exception-handler handler runs in the
  ;;   raise's dynamic extent, so it would run holding the fence. Return a
  ;;   status and raise after the release.
  (define-syntax with-send-fence
    (syntax-rules ()
      ((_ async body1 body2 ...)
       (with-mutex (async-fence async)
         (with-interrupts-disabled body1 body2 ...)))))

  ;; Starting close is idempotent and asynchronous. A repeated call cannot
  ;; replace the original on-close callback.
  (define (real-close-handle! handle on-close)
    (require-handle handle 'uv-close!)
    (unless (or (not on-close) (procedure? on-close))
      (raise (make-uv-invalid-argument 'uv-close! 'on-close-not-a-procedure)))
    (when (begin-close! handle on-close)
      (uv-close-native (handle-pointer handle 'uv-close!))))

  ;; begin-close! : uv-handle (or procedure #f) -> boolean
  ;; Moves an open handle to closing and answers #t, or answers #f if the
  ;; handle was not open. An async makes the move inside its send fence, so
  ;; the close waits for a send already past its open check, and every later
  ;; send sees the handle closing.
  (define (begin-close! handle on-close)
    (define (open->closing!)
      (and (eq? (handle-state handle) 'open)
           (begin (set-handle-on-close! handle on-close)
                  (set-handle-state! handle 'closing)
                  #t)))
    (if (uv-async-record? handle)
        (with-send-fence handle (open->closing!))
        (open->closing!)))

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

  ;; This is the outermost Scheme error boundary reachable from libuv.
  (define (contain-dispatcher-raise! name ptr obj)
    (let ((loop (registry-loop-of ptr)))
      (if loop
          (loop-record-error! loop obj)
          (record-orphan-callback! name ptr))))

  (define (seam-closure name)
    (lambda args
      (let ((ptr (if (pair? args) (car args) 0)))
        (guard (e (#t (contain-dispatcher-raise! name ptr e)))
          (apply (dispatch-procedure name) args)))))

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
                      (cons 'alloc      alloc-dispatch)
                      (cons 'read       read-dispatch)))
      (install-callback-dispatchers!
       (map (lambda (name) (cons name (seam-closure name)))
            dispatcher-names))
      (install-close-handle! real-close-handle!)
      'wired)))
