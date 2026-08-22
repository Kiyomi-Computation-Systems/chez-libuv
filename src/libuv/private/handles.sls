#!r6rs
;;; The handle registry, the loop record, and the callback error policy --
;;; design spec S5 ("The registry is the GC root"), S8 (store-and-reraise),
;;; and ADR-0007 (no guardians: closing is explicit, never GC-timed).
;;;
;;; Stage 2 delivered the registry and the loop record. Stage 3 added the
;;; handle records, the full 'open -> 'closing -> 'closed state machine, the
;;; callback guard, and the timer and close dispatchers -- and filled both
;;; seams: (libuv private native)'s dispatcher slots (eight through v0.1,
;;; ten as of v0.2 Stage 2) and this library's own `close-handle!`. The
;;; remaining six v0.1 callback types were installed as raising stubs that
;;; Stages 4 and 5 replaced by name through `install-dispatch-procedure!`,
;;; with no second slot install; by v0.1's Stage 5 all eight of its names
;;; held a real dispatcher. v0.2's two DNS names (getaddrinfo, getnameinfo)
;;; hold the raising stub again, BY DESIGN, until (libuv dns) installs the
;;; real dispatchers through the same seam at its library-body time.
;;;
;;; THIS LIBRARY'S BODY HAS EFFECTS. Instantiating it fills the process-global
;;; dispatcher slots, so any suite whose import chain reaches this file finds
;;; them already installed (tests/test-native.sps is the one suite that does
;;; not, which is where the uninstalled behaviour is asserted).
;;;
;;; WHY THE REGISTRY IS A GLOBAL. libuv hands a callback nothing but the
;;; firing handle's C pointer. The registry is what turns that pointer back
;;; into a Scheme record, so it has to be reachable from a trampoline that
;;; received no other context. Being the sole strong reference to an open
;;; handle is the second half of the same design: an open handle and its
;;; stored closures stay alive because they are IN this table, so a caller
;;; who drops every reference to a handle still gets deterministic,
;;; visible-in-the-counters behaviour rather than a GC-timed close
;;; (ADR-0007).
;;;
;;; This library is private and imports (libuv private native), so it loads
;;; the shim. It must never appear in a pure suite's import chain.
(library (libuv private handles)
  (export ;; the registry
          registry-register! registry-deregister! registry-ref
          registry-loop-of registry-count registry-snapshot-for-loop

          ;; the loop record (design spec S5's loop row)
          %make-uv-loop-record uv-loop?
          loop-ptr set-loop-ptr!
          loop-state set-loop-state!
          loop-running? set-loop-running!
          ;; set-loop-pending-error! is deliberately NOT exported: the
          ;; #f-sentinel hole this record's `no-pending` marker exists to
          ;; close (see below) can only be reintroduced by a caller who can
          ;; write the slot directly. Reading it (uv-run's re-raise) needs
          ;; loop-pending-error; asking whether there IS one needs the
          ;; predicate; emptying it needs clear-loop-pending-error!. Nothing
          ;; outside this library needs to set it, so nothing outside can.
          loop-pending-error
          loop-has-pending-error? clear-loop-pending-error!
          loop-deferred-error-list set-loop-deferred-error-list!
          loop-open? require-open-loop require-loop loop-pointer

          ;; the handle records (design spec S5's handle rows). The
          ;; constructors are %-prefixed and private-by-convention for the
          ;; same reason the loop's is: a record whose ptr did not come from
          ;; a successful uv_*_init is a segfault waiting to happen.
          %make-uv-handle-record uv-handle? %make-uv-timer-record uv-timer?
          ;; the stream hierarchy (ADR-0014): uv-stream-record is the parent
          ;; carrying the read-path fields tcp and pipe share; uv-tcp-record
          ;; and uv-pipe-record are its children. uv-process-record is a
          ;; direct uv-handle-record child -- a process is a handle, not a
          ;; stream (design spec v0.3 S5.1).
          uv-stream-record?
          %make-uv-tcp-record uv-tcp-record?
          %make-uv-pipe-record uv-pipe-record?
          %make-uv-process-record uv-process-record?
          handle-ptr handle-kind handle-loop
          handle-state set-handle-state!
          handle-on-close set-handle-on-close!
          timer-on-timeout set-timer-on-timeout!
          tcp-on-connection set-tcp-on-connection!
          ;; the stream-generic read-path fields (ADR-0014; renamed from
          ;; tcp-* now that uv-pipe-record shares them too), declared on
          ;; uv-stream-record and filled by v0.1 Stage 5 (see the record
          ;; definition below for why they are declared where they are)
          stream-on-data set-stream-on-data!
          stream-on-eof set-stream-on-eof!
          stream-on-error set-stream-on-error!
          stream-read-buf set-stream-read-buf!
          stream-read-buf-len set-stream-read-buf-len!
          stream-reading? set-stream-reading!
          ;; the pipe record's one field (design spec v0.3 S5.1): spawn's
          ;; consumption state, not handle open/closed state
          pipe-connected? set-pipe-connected!
          ;; the process record's two fields (design spec v0.3 S5.1)
          process-on-exit process-exited? set-process-exited!
          require-handle require-open-handle handle-pointer

          ;; the request records (design spec S5's "for both handles and
          ;; requests", S7's request-allocation pattern)
          %make-uv-req-record uv-req?
          req-ptr set-req-ptr! req-kind req-handle
          req-on-complete set-req-on-complete!

          ;; the request-completion machinery (ADR-0011). complete-request!
          ;; and abandon-request! are exported for (libuv dns) -- Stage 4's
          ;; dispatchers complete through the one freeing site, and its
          ;; start calls need the identical sync-failure undo tcp.sls uses.
          ;; cancel-requests-for-loop! is uv-loop-teardown!'s cancel sweep,
          ;; here so loop.sls never has to import (libuv dns).
          complete-request! abandon-request! cancel-requests-for-loop!

          ;; the callback error policy (design spec S8). record-orphan-callback!
          ;; is exported for (libuv process)'s exit dispatcher (design spec
          ;; v0.3 S5.4 step 1): the DNS dispatchers reach the orphan list
          ;; through complete-request!, but a process has no request path, so
          ;; its dispatcher records the event directly.
          loop-record-error! dispatch-guarded
          record-orphan-callback! orphan-callback-events

          ;; the close protocol, and the seam Stages 4-5 replace their own
          ;; dispatchers through
          close-handle! install-close-handle! close-handle-installed?
          install-dispatch-procedure!
          ;; the OTHER handle-freeing discipline (design spec v0.3 S5.6,
          ;; ADR-0015): the setup-class spawn failure, whose handle libuv has
          ;; already unlinked from the loop queue and which therefore never
          ;; gets a close callback. Here, not in process.sls, so that every
          ;; way a handle pointer dies stays in this one file.
          discard-failed-handle!

          ;; the walk QUERY machinery (design spec v0.3 S5.2, ADR-0015).
          ;; Exported but NOT installed here: handle-in-loop-queue? is the
          ;; §5.6 spawn-failure discriminator, and walk-dispatch is the
          ;; closure that backs it -- (libuv process) installs it as the
          ;; 'walk slot at its own library-body time, through
          ;; install-dispatch-procedure!, the dns.sls late-install seam's
          ;; second v0.3 application (beside `exit`). A process image that
          ;; never imports (libuv process) keeps the raising stub for
          ;; `walk`.
          handle-in-loop-queue? walk-dispatch)
  (import (rnrs)
          (libuv private conditions)
          ;; The FFI surface this library needs, and nothing more:
          ;;   uv-loop-stop      design spec S8 stops the loop when the FIRST
          ;;                     callback error is recorded, and that
          ;;                     recording happens here, in the policy, not
          ;;                     at the call site.
          ;;   uv-close-native   the close protocol (S5) starts here.
          ;;   free!             and ends here: the close dispatcher is the
          ;;                     ONLY place a handle pointer is freed.
          ;;   count-timer-free! the freeing site owns its counter (S10).
          ;;   the dispatcher slots: this library fills all eight, once, in
          ;;                     its own body (S4).
          ;;   uv-buf-set!       the alloc dispatcher's whole job (S6): fill
          ;;                     the uv_buf_t libuv passed with the handle's
          ;;                     own buffer.
          ;;   copy-out          the read dispatcher's whole job (ADR-0009):
          ;;                     a FRESH copy per delivery, so nothing the
          ;;                     caller keeps points into foreign memory.
          ;;   uv-cancel         the teardown cancel sweep (ADR-0011):
          ;;                     best-effort uv_cancel over this loop's
          ;;                     handle-less DNS requests, return codes
          ;;                     ignored. The raw binding's only other
          ;;                     caller is (libuv dns)'s uv-cancel! policy.
          ;;   count-pipe-free!/count-process-free! the freeing site owns
          ;;                     its counter (S10), same as count-tcp-free!,
          ;;                     for the two v0.3 handle kinds.
          ;;   uv-walk-native    the walk query machinery's own instrument
          ;;                     (ADR-0015): bakes in the walk trampoline,
          ;;                     interpreted here through walk-dispatch.
          (only (libuv private native)
                uv-cancel
                uv-loop-stop uv-close-native free!
                count-timer-free! count-tcp-free!
                count-pipe-free! count-process-free!
                count-write-req-free! count-connect-req-free!
                count-read-buffer-free!
                uv-buf-set! copy-out
                uv-errno-condition
                uv-walk-native
                dispatcher-names install-callback-dispatchers!)
          ;; UV_EOF is READ FROM THE SHIM's table, never transcribed as
          ;; -4095 (ADR-0005). The read dispatcher's EOF/error split is the
          ;; one comparison in this binding where a transcribed constant
          ;; would be invisible: -4095 is platform-independent, so a literal
          ;; would pass every test on every platform this project supports
          ;; and still be a violation of the rule that keeps every other
          ;; constant honest.
          (only (libuv private constants) uv-eof))

  ;; --- the loop record ---------------------------------------------------
  ;; Fields, per design spec S5 and S8:
  ;;   ptr             the foreign-alloc'd uv_loop_t, ZEROED the moment it is
  ;;                   freed (S10) so a use-after-free is a structured
  ;;                   condition rather than a plausible wrong answer -- a
  ;;                   freed uv_loop_t answers uv_loop_alive() without
  ;;                   faulting, measured in spike FINDINGS Q1.
  ;;   state           'open | 'closed
  ;;   running?        set for the dynamic extent of uv_run, so re-entrant
  ;;                   uv-run / uv-loop-close! / uv-loop-teardown! can be
  ;;                   refused (S8, "Illegal from inside a callback")
  ;;   pending-error   the FIRST value a callback guard caught this run, or
  ;;                   the private `no-pending` sentinel when there is none
  ;;   deferred-errors every later one, newest first (reversed on read)
  ;;
  ;; WHY THE EMPTY PENDING SLOT IS NOT #f. R6RS `raise` takes ANY object, so
  ;; a callback is entirely within its rights to `(raise #f)`. With #f as the
  ;; empty marker, that value would be stored, uv_stop would fire with
  ;; nothing to show for it, uv-run's re-raise test would read the slot as
  ;; empty and drop the error silently, and the NEXT error would be
  ;; misclassified as the first (overwriting the pending slot instead of
  ;; deferring). `no-pending` is a freshly allocated pair, so it is `eq?` to
  ;; nothing a callback can produce -- the sentinel rule AGENTS.md states for
  ;; assertions, applied to a data structure.
  ;;
  ;; The constructor is private (%-prefixed) because a loop record whose ptr
  ;; did not come from a successful uv_loop_init is a segfault waiting to
  ;; happen; (libuv loop)'s make-uv-loop is the only sanctioned way to get
  ;; one.
  ;; Allocated, not quoted: a quoted literal may be shared with an equal
  ;; literal elsewhere in the program, and `eq?` on it would then be a
  ;; coincidence rather than an identity. This pair is unique by
  ;; construction and never escapes this library.
  (define no-pending (list 'no-pending))

  (define-record-type (uv-loop-record %make-uv-loop-record uv-loop?)
    (fields (mutable ptr             loop-ptr             set-loop-ptr!)
            (mutable state           loop-state           set-loop-state!)
            (mutable running         loop-running?        set-loop-running!)
            (mutable pending-error   loop-pending-error   set-loop-pending-error!)
            (mutable deferred-errors loop-deferred-error-list
                                     set-loop-deferred-error-list!))
    (protocol
     (lambda (new)
       (lambda (ptr) (new ptr 'open #f no-pending '())))))

  ;; The two operations every caller outside this library should use instead
  ;; of testing the pending slot's truthiness. `loop-pending-error` still
  ;; reads the raw slot -- it is what uv-run re-raises, #f included -- but
  ;; whether there IS one is this predicate's answer, never the value's.
  (define (loop-has-pending-error? loop)
    (not (eq? (loop-pending-error loop) no-pending)))

  (define (clear-loop-pending-error! loop)
    (set-loop-pending-error! loop no-pending))

  (define (loop-open? loop)
    (and (uv-loop? loop) (eq? (loop-state loop) 'open)))

  ;; Type check first, state check second, and both raise DIFFERENT
  ;; conditions: handing a string to uv-now is a caller bug
  ;; (&uv-invalid-argument, naming who), while touching a loop that has been
  ;; closed is the documented lifecycle error callers guard for
  ;; (&uv-handle-closed with kind 'loop, design spec S9). Returns the loop so
  ;; the happy path has a value only success produces.
  (define (require-loop loop who)
    (unless (uv-loop? loop)
      (raise (make-uv-invalid-argument who 'not-a-uv-loop)))
    loop)

  (define (require-open-loop loop who)
    (require-loop loop who)
    (unless (eq? (loop-state loop) 'open)
      (raise (make-uv-handle-closed 'loop)))
    loop)

  ;; The one way to read the pointer for a native call. A zero here means
  ;; something already freed this loop and is about to hand NULL to libuv --
  ;; the same reasoning as (libuv private native)'s free!, and the same
  ;; outcome: a structured condition instead of a segfault. It is also what
  ;; makes a broken close-idempotence guard fail as a named assertion rather
  ;; than as a crash.
  (define (loop-pointer loop who)
    (let ((ptr (loop-ptr loop)))
      (unless (and (integer? ptr) (exact? ptr) (positive? ptr))
        (raise (make-uv-invalid-argument who 'null-loop-pointer)))
      ptr))

  ;; --- the handle records (design spec S5) -------------------------------
  ;; One parent record for everything that is a HANDLE (as opposed to a loop
  ;; or a request), plus one child per handle type. The parent carries
  ;; exactly the fields the generic machinery needs -- the close protocol,
  ;; the state machine, and the loop backpointer -- so `uv-close!`, the close
  ;; dispatcher, and the teardown sweep are written once and reused verbatim
  ;; by the TCP handle Stage 4 adds as a second child. That is why this lives
  ;; here and not in timer.sls.
  ;;
  ;; Fields:
  ;;   ptr       the foreign-alloc'd uv_timer_t / uv_tcp_t, ZEROED the moment
  ;;             the close dispatcher frees it (S10) -- a freed uv_* pointer
  ;;             answers plausibly and wrongly rather than faulting (spike
  ;;             FINDINGS Q1), so the zeroed slot is the only thing that can
  ;;             make a use-after-free detectable.
  ;;   kind      'timer | 'tcp -- the registry's kind, the &uv-handle-closed
  ;;             kind, and the debug-counter class, all one symbol.
  ;;   loop      the owning loop record. IMMUTABLE: a handle cannot migrate
  ;;             between loops, and the close dispatcher needs it to reach
  ;;             the error policy after the pointer is already gone.
  ;;   state     'open | 'closing | 'closed
  ;;   on-close  the caller's close callback, or #f
  (define-record-type (uv-handle-record %make-uv-handle-record uv-handle?)
    (fields (mutable ptr      handle-ptr      set-handle-ptr!)
            (immutable kind   handle-kind)
            (immutable loop   handle-loop)
            (mutable state    handle-state    set-handle-state!)
            (mutable on-close handle-on-close set-handle-on-close!))
    (protocol
     (lambda (new)
       (lambda (ptr kind loop) (new ptr kind loop 'open #f)))))

  ;; The timer adds exactly one field: the callback uv_timer_start armed it
  ;; with. It is stored on the Scheme side rather than read back out of the
  ;; uv_timer_t because libuv's copy is a C function pointer -- always this
  ;; binding's single timer trampoline, which says nothing about WHICH
  ;; Scheme procedure should run.
  (define-record-type (uv-timer-record %make-uv-timer-record uv-timer?)
    (parent uv-handle-record)
    (fields (mutable on-timeout timer-on-timeout set-timer-on-timeout!))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr loop) ((pargs->new ptr 'timer loop) #f)))))

  ;; The stream-generic read-path fields, hoisted from the v0.1 tcp record
  ;; (ADR-0014): everything the alloc/read dispatchers and the close
  ;; dispatcher's buffer arm touch, shared by tcp and pipe children. The
  ;; protocol threads the KIND through, because each child names its own.
  ;;
  ;;   * the close dispatcher below already frees `read-buf`, because design
  ;;     spec S5 fixes the close order (pop registry -> free read buffer ->
  ;;     free handle pointer) and S6 makes the close dispatcher the ONLY
  ;;     place that buffer is ever freed. Splitting that arm across handle
  ;;     types would mean shipping a close protocol that is right for one
  ;;     stream kind and incomplete for the other.
  ;;   * a record's field list is its layout. Adding fields later is a
  ;;     recompile of every importer; declaring the shape once, from the
  ;;     design spec's own record row, is not.
  ;;
  ;; `read-buf` is a uptr (0 when there is none), `read-buf-len` its size in
  ;; bytes.
  ;;
  ;; `reading?` RECORDS CALLER INTENT -- a successful uv-read-start! not yet
  ;; followed by uv-read-stop! -- NOT libuv's live read state (final-review
  ;; triage, Task 9 Minors; decided post-v0.1). libuv clears its own
  ;; UV_HANDLE_READING on EOF and stops the watcher on read errors, so a
  ;; field that mirrored libuv would need per-arm knowledge of stream.c that
  ;; varies across the supported 1.x range; intent needs none. The EOF and
  ;; error dispatchers therefore deliberately leave it set. No production
  ;; code reads it today; tests/test-tcp.sps locks the semantics in by name.
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

  ;; The TCP child keeps exactly what is TCP-specific: the listener's
  ;; callback (listen/accept remain TCP-only, THE SPEC §4.6).
  (define-record-type (uv-tcp-record %make-uv-tcp-record uv-tcp-record?)
    (parent uv-stream-record)
    (fields (mutable on-connection tcp-on-connection set-tcp-on-connection!))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr loop) ((pargs->new ptr 'tcp loop) #f)))))

  ;; The pipe child (THE SPEC §5.1). `connected?` is the spawn-consumption
  ;; state -- NOT handle state ("open/closed" vs "connected/unconnected",
  ;; §4.3's vocabulary rule): it starts #f and flips exactly once, when a
  ;; successful uv-spawn! consumes this pipe in a (pipe ...) spec. It
  ;; exists to make 'pipe-already-used raisable before any allocation.
  (define-record-type (uv-pipe-record %make-uv-pipe-record uv-pipe-record?)
    (parent uv-stream-record)
    (fields (mutable connected pipe-connected? set-pipe-connected!))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr loop) ((pargs->new ptr 'pipe loop) #f)))))

  ;; The process child (THE SPEC §5.1): a process is a handle, not a
  ;; stream. on-exit is stored AT CONSTRUCTION -- the callback travels
  ;; inside uv_process_options_t, so it must be on the record before
  ;; uv_spawn runs (§4.1); there is nothing to clobber on a fresh record.
  ;; exited? is set by the exit dispatcher (§5.4 step 4) and read by the
  ;; lifecycle tests; exit stops the handle but never closes it (§6).
  (define-record-type (uv-process-record %make-uv-process-record uv-process-record?)
    (parent uv-handle-record)
    (fields (mutable on-exit process-on-exit set-process-on-exit!)
            (mutable exited  process-exited? set-process-exited!))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr loop on-exit) ((pargs->new ptr 'process loop) on-exit #f)))))

  ;; --- the request records (design spec S5, S7) --------------------------
  ;; A request is NOT a handle: it has no state machine, no close protocol,
  ;; and exactly one lifetime rule -- it lives from the call that started it
  ;; until its completion dispatcher frees its block. So it is a separate
  ;; record type rather than another child of uv-handle-record, and the
  ;; live-handle snapshot below excludes it by kind.
  ;;
  ;; Fields:
  ;;   ptr         the ONE foreign-alloc'd block: the uv_*_t request, plus
  ;;               whatever design spec S7 co-allocates with it (a uv_buf_t
  ;;               and the payload copy for a write; a sockaddr_storage for a
  ;;               connect). ZEROED the moment the block is freed, for the
  ;;               same reason a handle's is.
  ;;   kind        'write | 'shutdown | 'connect
  ;;   handle      the stream the request runs on, or #f for a handle-less
  ;;               request -- v0.2's DNS kinds, whose uv_getaddrinfo_t /
  ;;               uv_getnameinfo_t take the loop directly and belong to no
  ;;               handle at all (ADR-0011). IMMUTABLE either way. For the
  ;;               handle-owned kinds this field was v0.1's only route from
  ;;               a completion back to the owning loop (the handle may
  ;;               already be 'closing by then (S5), but its loop
  ;;               backpointer outlives everything); since ADR-0011 the
  ;;               completion path reads the loop off the REGISTRY ENTRY
  ;;               instead (complete-request! below), which answers for
  ;;               both shapes.
  ;;   on-complete the caller's completion callback, or #f
  (define-record-type (uv-req-record %make-uv-req-record uv-req?)
    (fields (mutable ptr        req-ptr         set-req-ptr!)
            (immutable kind     req-kind)
            (immutable handle   req-handle)
            (mutable on-complete req-on-complete set-req-on-complete!))
    (protocol
     (lambda (new)
       (lambda (ptr kind handle on-complete)
         (new ptr kind handle on-complete)))))

  ;; Type check first, state check second, and both raise DIFFERENT
  ;; conditions -- the same split as require-loop / require-open-loop, and
  ;; for the same reason: handing a string to uv-timer-stop! is a caller bug,
  ;; while touching a handle that has been closed is the documented lifecycle
  ;; error callers guard for (design spec S9). Returns the handle so the
  ;; happy path has a value only success produces.
  (define (require-handle handle who)
    (unless (uv-handle? handle)
      (raise (make-uv-invalid-argument who 'not-a-uv-handle)))
    handle)

  ;; 'closing is NOT open: a handle whose close has been started must refuse
  ;; new work even though its pointer is still live, because the close
  ;; dispatcher is already scheduled to free it.
  (define (require-open-handle handle who)
    (require-handle handle who)
    (unless (eq? (handle-state handle) 'open)
      (raise (make-uv-handle-closed (handle-kind handle))))
    handle)

  ;; The one way to read a handle pointer for a native call, mirroring
  ;; loop-pointer: a zero here means something already freed this handle and
  ;; is about to hand NULL to libuv.
  (define (handle-pointer handle who)
    (let ((ptr (handle-ptr handle)))
      (unless (valid-pointer? ptr)
        (raise (make-uv-invalid-argument who 'null-handle-pointer)))
      ptr))

  ;; --- the registry ------------------------------------------------------
  ;; uptr -> entry. eqv, not eq: pointers are exact integers wide enough to
  ;; be bignums on a 64-bit host, and bignums are not eq? to each other.
  ;;
  ;; Entries carry the kind and the owning loop so the table can serve both
  ;; of its roles: dispatch (pointer -> the Scheme object libuv just fired
  ;; on) and teardown (every handle belonging to THIS loop, since v0.1 binds
  ;; no uv_walk).
  (define registry (make-eqv-hashtable))

  (define-record-type (registry-entry %make-registry-entry registry-entry?)
    (fields kind loop object))

  (define (valid-pointer? ptr)
    (and (integer? ptr) (exact? ptr) (positive? ptr)))

  ;; The kinds that name a HANDLE, as opposed to a loop or a request. This
  ;; is what registry-snapshot-for-loop filters on, and therefore what
  ;; uv-loop-teardown! sweeps: every element of that snapshot is handed to
  ;; close-handle!, which refuses anything that is not a handle record.
  ;; Widened to four in v0.3 (design spec S5.1): pipe and process are both
  ;; handles that need the same teardown sweep tcp and timer already get.
  (define handle-kinds '(timer tcp pipe process))

  ;; The kinds that name a HANDLE-LESS request -- one registered against
  ;; the loop directly because no owning handle exists (ADR-0011; Stage 4's
  ;; DNS start calls register these). This is what cancel-requests-for-loop!
  ;; filters on, and DELIBERATELY not what registry-snapshot-for-loop
  ;; filters on: handle-kinds is untouched, so these entries stay out of
  ;; the close sweep automatically.
  (define dns-request-kinds '(getaddrinfo-req getnameinfo-req))

  ;; kind:   'loop | 'timer | 'tcp | 'pipe | 'process | 'write-req | 'connect-req | 'shutdown-req
  ;;         | 'getaddrinfo-req | 'getnameinfo-req
  ;; loop:   the owning loop record (a loop owns itself). A handle-owned
  ;;         request registers its HANDLE's loop; a handle-less DNS request
  ;;         (ADR-0011) has no handle to inherit one from and registers its
  ;;         loop EXPLICITLY. Either way the loop lives on the ENTRY, which
  ;;         is what makes registry-loop-of answer for every request block
  ;;         through one code path (complete-request! below).
  ;; object: the Scheme record the dispatchers and the teardown sweep hand
  ;;         back to their callers
  (define (registry-register! ptr kind loop object)
    (unless (valid-pointer? ptr)
      (raise (make-uv-invalid-argument 'uv-registry-register!
                                       'null-or-invalid-pointer)))
    ;; THE LOOP FIELD IS VALIDATED HERE BECAUSE contain-dispatcher-raise! --
    ;; the outermost Scheme frame libuv can reach (see the seam's guard
    ;; below) -- reads it back through registry-loop-of and hands it to
    ;; loop-record-error!, whose require-loop would RAISE on a non-loop. That
    ;; raise would happen inside the seam guard's HANDLER, i.e. outside the
    ;; guard, i.e. into a C stack frame: spike FINDINGS Q2's exit 255, with
    ;; no teardown and no foreign-free. Refusing a bad loop at the one place
    ;; this field is ever written makes that unreachable by construction,
    ;; which is a check rather than a comment (AGENTS.md).
    (unless (uv-loop? loop)
      (raise (make-uv-invalid-argument 'uv-registry-register!
                                       'loop-not-a-uv-loop)))
    (when (hashtable-contains? registry ptr)
      ;; Two live objects on one address means something was freed without
      ;; being deregistered, and the dispatchers would deliver this handle's
      ;; callbacks to the wrong record. Never a recoverable situation.
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

  ;; The owning loop of a registered pointer, or #f. Distinct from
  ;; registry-ref on purpose: the loop lives on the ENTRY, not on the object,
  ;; so this answers for a request block (which has no loop field of its own)
  ;; as well as for a handle, and it answers without knowing what kind of
  ;; object is registered. The dispatcher seam's guard is the caller -- it has
  ;; a raised object and a bare pointer, and needs the error cell that
  ;; pointer belongs to.
  (define (registry-loop-of ptr)
    (let ((entry (hashtable-ref registry ptr #f)))
      (and entry (registry-entry-loop entry))))

  (define (registry-count) (hashtable-size registry))

  ;; Every HANDLE registered against this loop -- an INCLUSION test on
  ;; handle-kinds, not an exclusion of 'loop. Both the loop's own entry and
  ;; every request entry have to stay out of this list, and for the same
  ;; reason: uv-loop-teardown! hands each element to close-handle!, which
  ;; refuses anything that is not a handle record. A snapshot that excluded
  ;; only 'loop would make teardown raise 'not-a-uv-handle the moment a write
  ;; or a connect was in flight -- and an in-flight HANDLE-OWNED request
  ;; needs no sweeping anyway: libuv fires every request callback before the
  ;; close callback of the handle it belongs to (design spec S5), so closing
  ;; the handle is what frees the request block. A HANDLE-LESS request
  ;; (dns-request-kinds, ADR-0011) has no close to ride on; those are
  ;; covered by cancel-requests-for-loop! below, which uv-loop-teardown!
  ;; runs BEFORE this close sweep.
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

  ;; uv-loop-teardown!'s CANCEL SWEEP (ADR-0011): best-effort uv_cancel on
  ;; every handle-less DNS request registered against this loop, run before
  ;; the close sweep so the teardown drain then delivers every in-flight
  ;; on-complete before teardown returns -- 'EAI_CANCELED where the cancel
  ;; won, the real result where the work was already running.
  ;;
  ;; SNAPSHOT-FIRST, the same R6RS iterating-while-mutating rationale as the
  ;; close sweep's snapshot (loop.sls:210-214): uv_cancel mutates no
  ;; registry state, but the snapshot (hashtable-entries answers fresh
  ;; vectors) costs nothing and removes the question.
  ;;
  ;; RETURN CODES ARE IGNORED, by decision rather than omission: 0 means
  ;; the queued work completes on the next drain iteration with
  ;; 'EAI_CANCELED; UV_EBUSY means it is running or finished and the drain
  ;; waits out its real completion (uv__work_cancel,
  ;; vendor/libuv/src/threadpool.c:292-307). Exactly one callback fires in
  ;; every outcome, so there is nothing here to act on. Cancellation POLICY
  ;; -- which codes a caller should care about -- lives with (libuv dns)'s
  ;; uv-cancel!, not in this sweep.
  ;;
  ;; The keys vector is the live pointers: a registered entry's block has
  ;; not been freed (every freeing site deregisters first), and
  ;; registry-register! refused anything that was not a valid pointer.
  (define (cancel-requests-for-loop! loop)
    (let-values (((keys entries) (hashtable-entries registry)))
      (do ((i 0 (+ i 1)))
          ((= i (vector-length entries)))
        (let ((entry (vector-ref entries i)))
          (when (and (eq? (registry-entry-loop entry) loop)
                     (memq (registry-entry-kind entry) dns-request-kinds))
            (uv-cancel (vector-ref keys i)))))))

  ;; --- the callback error policy (design spec S8) ------------------------
  ;; Store-and-reraise. The FIRST value a trampoline's guard catches is
  ;; stored and the loop is stopped; every later one is deferred, readable
  ;; via uv-loop-deferred-errors until the next uv-run clears it. uv-run
  ;; itself performs the re-raise, which is why nothing here raises: this
  ;; runs inside a C stack frame, where an escaping condition is precisely
  ;; what the policy exists to prevent (ADR-0008).
  ;;
  ;; uv_stop is called only on the first error, and only while the loop is
  ;; open with a live pointer: recording an error against a loop that is
  ;; already being torn down must not hand NULL to libuv.
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

  ;; --- the callback guard (design spec S8, ADR-0008) ---------------------
  ;; EVERY dispatcher body runs inside this. Not a style rule: spike
  ;; FINDINGS Q2 measured an unguarded raise from a foreign-callable
  ;; terminating the process outright -- exit 255, no teardown, no
  ;; uv_loop_close, no foreign-free. The guard is what turns that into a
  ;; recorded error and a stopped loop, which uv-run then re-raises from
  ;; Scheme, outside every C frame.
  ;;
  ;; The clause is `#t`, not a condition predicate: R6RS `raise` takes ANY
  ;; object, and a callback that raises a symbol (or #f) must be caught here
  ;; exactly like one that raises a condition. A predicate clause would let
  ;; those unwind into libuv.
  ;;
  ;; Nothing is returned to libuv: uv_timer_cb and uv_close_cb are void.
  ;;
  ;; Stages 4-5: this is the procedure your dispatchers must call through.
  (define (dispatch-guarded loop thunk)
    (guard (e (#t (loop-record-error! loop e)))
      (thunk)))

  ;; --- the orphan fallback -----------------------------------------------
  ;; A trampoline receives nothing but a pointer. If the registry has no
  ;; entry for it there is no loop record, hence no error cell to record
  ;; against and no loop to stop -- design spec S8's policy has no arm for
  ;; this case because it cannot be expressed. Raising is not an option
  ;; either (that is the process death above). So the event is recorded in a
  ;; module-level list and the dispatcher returns.
  ;;
  ;; This is a bug reporter, not a recovery mechanism: a callback for an
  ;; unregistered pointer means libuv is holding a handle this binding has
  ;; already forgotten, which is exactly the double-free-shaped defect
  ;; registry-register!'s duplicate check exists to prevent. Tests assert the
  ;; list, so the situation is observable rather than silent.
  (define orphan-events '())

  (define (record-orphan-callback! kind ptr)
    (set! orphan-events (cons (cons kind ptr) orphan-events)))

  ;; Freshly consed, in occurrence order.
  (define (orphan-callback-events) (reverse orphan-events))

  ;; --- the dispatchers (design spec S4/S5/S8) ----------------------------
  ;; uv_timer_cb: void (*)(uv_timer_t *handle).
  ;;
  ;; Only an 'open timer gets its callback. A 'closing one has had uv_close
  ;; called on it -- libuv stops the timer as part of that, so this arm is
  ;; not reachable through libuv today; it is a state check rather than a
  ;; race guard, and it is what stops a timeout from being delivered to a
  ;; handle whose pointer is already scheduled to be freed. (Design spec S5
  ;; tolerates 'closing for REQUEST callbacks -- an in-flight write
  ;; completing with 'ECANCELED -- which is a different dispatcher.)
  (define (timer-dispatch handle-ptr)
    (let ((handle (registry-ref handle-ptr)))
      (if (uv-timer? handle)
          (when (eq? (handle-state handle) 'open)
            (let ((on-timeout (timer-on-timeout handle)))
              (when on-timeout
                (dispatch-guarded (handle-loop handle)
                                  (lambda () (on-timeout handle))))))
          (record-orphan-callback! 'timer handle-ptr))))

  ;; --- the Stage 4 dispatchers (design spec S5, S7) ----------------------
  ;; A callback's `status` int is NOT an exception. Raising it would unwind
  ;; into libuv (ADR-0008), and design spec S9 is explicit that these are
  ;; "the same condition record types delivered as plain objects to
  ;; asynchronous callbacks". So a nonzero status becomes a condition OBJECT
  ;; and is passed as an argument; #f means success.
  ;;
  ;; `who` is the public procedure that STARTED the operation, so a caller
  ;; reading the condition sees uv-write! rather than the name of an internal
  ;; dispatcher.
  (define (status->err status who)
    (if (zero? status) #f (uv-errno-condition status who)))

  ;; uv_connection_cb: void (*)(uv_stream_t *server, int status).
  ;;
  ;; No state check on the server, unlike timer-dispatch: a connection
  ;; arriving for a 'closing listener is a real (if rare) race, and the
  ;; callback is the caller's only chance to see it. What IS checked is that
  ;; the pointer resolves to a TCP handle -- an incoming connection for
  ;; anything else means the registry and libuv disagree.
  (define (connection-dispatch server-ptr status)
    (let ((server (registry-ref server-ptr)))
      (if (uv-tcp-record? server)
          (let ((on-connection (tcp-on-connection server)))
            (when on-connection
              (dispatch-guarded
               (handle-loop server)
               (lambda () (on-connection (status->err status 'uv-listen!))))))
          (record-orphan-callback! 'connection server-ptr))))

  ;; uv_write_cb / uv_shutdown_cb / uv_connect_cb, all
  ;; void (*)(uv_*_t *req, int status). THE ONLY PLACE A REQUEST BLOCK IS
  ;; FREED (design spec S7, S10).
  ;;
  ;; THE ORDER IS THE SPECIFICATION, exactly as it is for close-dispatch:
  ;;   1. read what is needed FIRST -- the owning loop off the REGISTRY
  ;;      ENTRY (registry-loop-of, which must run before step 2 pops the
  ;;      entry; it provably answers here, because the registry-ref above
  ;;      just succeeded on the same key and the entry's loop was validated
  ;;      uv-loop? at its single write site) and the callback off the
  ;;      record -- because steps 2-5 leave both pointing at nothing.
  ;;      The entry, not the record's handle field, is the authority on
  ;;      ownership (ADR-0011): a handle-less DNS request has handle = #f,
  ;;      so there is no (handle-loop (req-handle req)) route at all, while
  ;;      for the handle-owned kinds the entry's loop IS the handle's loop
  ;;      by construction (every TCP start call registers it) -- one code
  ;;      path for all five request kinds, the TCP suites guarding the
  ;;      equivalence.
  ;;   2. pop the registry entry   -- so nothing can dispatch on this pointer
  ;;                                  again, and so the address is free to be
  ;;                                  reused by a later foreign-alloc
  ;;   3. free the whole block     -- request, uv_buf_t and payload together;
  ;;                                  design spec S7 allocates them as one
  ;;   4. bump the counter for this class, at the freeing site (S10)
  ;;   5. zero the stored uptr     -- at the freeing site, so a use-after-free
  ;;                                  is a structured condition rather than
  ;;                                  the plausible wrong answer spike Q1
  ;;                                  measured
  ;;   6. THEN run the caller's on-complete, under the guard
  ;; Step 6 last is design spec S7's "frees the block BEFORE invoking
  ;; (on-complete err)", and it is what makes the memory bound on a stream
  ;; with many queued writes a property of the code rather than of how long
  ;; each callback happens to take.
  ;;
  ;; DELIVERY IS (apply on-complete err extras) as of ADR-0011. The rest-arg
  ;; extras are the completion's payload beyond the err -- getaddrinfo's
  ;; converted record list, getnameinfo's two copied strings -- and they
  ;; must always be already-copied Scheme values computed BEFORE this
  ;; procedure is called, because step 6 runs after everything foreign is
  ;; freed (ADR-0009's boundary). The v0.1 dispatchers below pass none, so
  ;; their callbacks still receive exactly (err).
  ;;
  ;; NO HANDLE STATE CHECK, deliberately: design spec S5 says request
  ;; callbacks land on a 'closing handle (an in-flight write losing its race
  ;; against uv_close completes with 'ECANCELED), and refusing to deliver
  ;; there would drop the one notification that says the block is gone.
  ;; `block-ptr`, not `req-ptr`: the latter would shadow the record accessor
  ;; of the same name (final-review triage, Task 8 Minors). The name also
  ;; says what it is -- the address of the whole co-allocated block, which
  ;; is what gets freed.
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

  ;; Undo a registration that a synchronous native failure has just made
  ;; pointless: pop the entry, free the block, zero the record's pointer.
  ;; This is the SAME order complete-request! uses, minus the callback --
  ;; there is nothing to report to, since the caller is about to receive
  ;; the condition itself. The counter, where there is one, is bumped by
  ;; the caller so that each site names its own class. Private to tcp.sls
  ;; through v0.1; lifted here in v0.2 Stage 3 (design spec v0.2 S5.3),
  ;; exported, because (libuv dns)'s start calls need the identical
  ;; sync-failure undo.
  (define (abandon-request! req)
    (let ((ptr (req-ptr req)))
      (registry-deregister! ptr)
      (free! ptr)
      (set-req-ptr! req 0)))

  ;; The write payload lives INSIDE the write request's own block (design
  ;; spec S7: "exactly one foreign-alloc, sized for
  ;; [uv_write_t | pad | uv_buf_t | payload copy] in a single block"), so one
  ;; allocation gets one counter. There is no second class to bump.
  (define (write-done-dispatch req-ptr status)
    (complete-request! 'write-done 'uv-write! count-write-req-free!
                       req-ptr status))

  (define (connect-dispatch req-ptr status)
    (complete-request! 'connect 'uv-tcp-connect! count-connect-req-free!
                       req-ptr status))

  ;; Design spec S10 enumerates six debug-counter classes and a shutdown
  ;; request is not one of them, so this one is deliberately uncounted rather
  ;; than counted under someone else's class. What stands in for the counter
  ;; is the REGISTRY: tests/test-tcp.sps asserts the shutdown request's entry
  ;; is gone by the time on-shutdown runs, and the balance rows assert the
  ;; registry returns to its baseline. The block's actual free is covered by
  ;; Valgrind on Linux (ADR-0003) like every other allocation here.
  (define (no-request-counter) #f)

  (define (shutdown-dispatch req-ptr status)
    (complete-request! 'shutdown 'uv-shutdown! no-request-counter
                       req-ptr status))

  ;; --- the Stage 5 read-path dispatchers (design spec S6) ----------------
  ;; uv_alloc_cb: void (*)(uv_handle_t *handle, size_t suggested, uv_buf_t *buf).
  ;;
  ;; THIS DISPATCHER IS INFALLIBLE, and that is a requirement rather than an
  ;; observation. Design spec S6: uv-read-start! allocates one reusable buffer
  ;; per handle "so the alloc_cb libuv invokes on every read is infallible --
  ;; it hands back an already-allocated pointer, never allocates on the hot
  ;; path". Every step below is a hashtable lookup, a record-field read, or a
  ;; foreign-set! through a validated ftype; none of them can raise, so the
  ;; seam's guard has nothing to contain on this path. KEEP IT THAT WAY:
  ;; anything added here that CAN raise (an allocation, a uv-check, one of
  ;; native.sls's validating helpers) breaks the invariant even though the
  ;; seam would still catch it, because libuv has no error path for an
  ;; alloc_cb that fails to answer -- the buffer it gets is the one it reads
  ;; into.
  ;;
  ;; `suggested` is deliberately ignored. The buffer is the handle's own and
  ;; its size was fixed by the first uv-read-start!; libuv's hint is a hint.
  ;;
  ;; A pointer this binding cannot resolve, or a handle with no buffer, gets
  ;; base = 0 / len = 0, which libuv reads as "the user cannot or will not
  ;; handle this read" and turns into a read_cb carrying UV_ENOBUFS
  ;; (vendor/libuv/src/unix/stream.c, lines 1050-1053) -- a condition
  ;; delivered to on-error below, never a crash and never a silent stall.
  ;;
  ;; THE WHOLE BUFFER, FROM ITS BASE, IS THE ANSWER THIS DISPATCHER MAY GIVE:
  ;; read-dispatch copies out of (stream-read-buf handle), not out of
  ;; buf->base (see its own note below), so answering a SUB-RANGE here would
  ;; have to change both sites together or the copy would start at the wrong
  ;; address.
  ;;
  ;; uv-stream-record?, not uv-tcp-record? (ADR-0014): tcp and pipe share
  ;; this whole read path, so the gate generalizes to the parent that owns
  ;; the fields rather than naming either child.
  (define (alloc-dispatch handle-ptr suggested buf-ptr)
    (let ((handle (registry-ref handle-ptr)))
      (if (and (uv-stream-record? handle)
               (valid-pointer? (stream-read-buf handle)))
          (uv-buf-set! buf-ptr (stream-read-buf handle) (stream-read-buf-len handle))
          (uv-buf-set! buf-ptr 0 0))))

  ;; uv_read_cb: void (*)(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf).
  ;;
  ;; `nread` is ssize_t and the four arms are design spec S6's, in the order
  ;; that makes each one unambiguous: positive is data, zero is libuv's
  ;; "nothing to read this time" (never EOF), UV_EOF is its own callback, and
  ;; every other negative is an error condition OBJECT. Spike FINDINGS Q3
  ;; measured what binding `nread` unsigned would do instead: UV_EOF arrives
  ;; as 2^64 - 4095, `(> nread 0)` is true, and the end of the stream is
  ;; delivered as four gigabytes of data.
  ;;
  ;; NO HANDLE STATE CHECK, deliberately -- the same rule as the request
  ;; dispatchers above (design spec S5's tolerance clause). A read completion
  ;; can be queued behind a uv_close, and refusing to deliver it there would
  ;; drop the EOF a caller's own bookkeeping may be waiting for.
  ;;
  ;; THE `buf` ARGUMENT IS NOT DEREFERENCED. libuv hands read_cb back the
  ;; same uv_buf_t alloc-dispatch filled in, and alloc-dispatch fills it with
  ;; the handle's own buffer and nothing else -- so `(stream-read-buf handle)`
  ;; and `buf->base` are the same address by construction. Reading the
  ;; record's own field keeps this dispatcher's data source inside the
  ;; binding's bookkeeping (if the two ever disagreed, copying from the
  ;; foreign pointer would be the less safe of the two answers), and it is
  ;; what makes the nread = 0, UV_EOF and error arms callable from a test
  ;; with a null buf -- which is the only way the nread = 0 arm is observable
  ;; at all, since no public API can ask libuv for one.
  ;;
  ;; uv-stream-record?, not uv-tcp-record?, for the same reason as
  ;; alloc-dispatch above.
  (define (read-dispatch stream-ptr nread buf-ptr)
    (let ((handle (registry-ref stream-ptr)))
      (if (uv-stream-record? handle)
          (cond ((positive? nread) (deliver-read-data! handle nread))
                ((zero? nread) #f)
                ((= nread (uv-eof)) (deliver-read-eof! handle))
                (else (deliver-read-error! handle nread)))
          (record-orphan-callback! 'read stream-ptr))))

  ;; The copy happens INSIDE the guard, not before it: copy-out validates its
  ;; source, and a zero or absent buffer here would mean the registry and the
  ;; read state had come apart -- which is a callback error to record on the
  ;; loop, exactly like a raise from the user's own callback, rather than a
  ;; segfault.
  ;;
  ;; The span is `(bv 0 nread)` -- start and end, not a bare bytevector, so a
  ;; future zero-copy variant can answer a sub-range of a larger buffer
  ;; without changing the call shape (design spec S6, ADR-0009).
  (define (deliver-read-data! handle nread)
    (let ((on-data (stream-on-data handle)))
      (when on-data
        (dispatch-guarded
         (handle-loop handle)
         (lambda ()
           (on-data (copy-out (stream-read-buf handle) nread) 0 nread))))))

  ;; EOF is NOT an error and is never wrapped in a condition (design spec S6,
  ;; ADR-0006): it is its own callback, taking no arguments, because there is
  ;; nothing to report beyond "that was the last byte".
  (define (deliver-read-eof! handle)
    (let ((on-eof (stream-on-eof handle)))
      (when on-eof
        (dispatch-guarded (handle-loop handle) on-eof))))

  ;; `who` is uv-read-start!, the public procedure that started the read --
  ;; the same rule the request dispatchers follow. The handle is NOT closed
  ;; here: design spec S6 says "the binding never auto-closes the handle on a
  ;; read error", so what happens next is the caller's decision.
  (define (deliver-read-error! handle nread)
    (let ((on-error (stream-on-error handle)))
      (when on-error
        (dispatch-guarded
         (handle-loop handle)
         (lambda () (on-error (uv-errno-condition nread 'uv-read-start!)))))))

  ;; uv_close_cb: void (*)(uv_handle_t *handle). THE ONLY PLACE A HANDLE
  ;; POINTER IS FREED (design spec S5, S10).
  ;;
  ;; THE ORDER IS THE SPECIFICATION, not an implementation detail:
  ;;   1. pop the registry entry   -- so nothing can dispatch on this pointer
  ;;                                  again, and so the address is free to be
  ;;                                  reused by a later foreign-alloc without
  ;;                                  colliding with a stale entry
  ;;   2. free the read buffer     -- the per-handle buffer of design spec
  ;;                                  S6, freed HERE and nowhere else and
  ;;                                  never earlier; nothing to free for a
  ;;                                  timer, or for a TCP handle that never
  ;;                                  started reading
  ;;   3. free the handle pointer
  ;;   4. bump the counter for this kind, at the freeing site (S10)
  ;;   5. zero the stored uptr     -- immediately, at the freeing site, so a
  ;;                                  use-after-free is a structured
  ;;                                  condition rather than the plausible
  ;;                                  wrong answer spike Q1 measured
  ;;   6. transition to 'closed
  ;;   7. THEN run the user's on-close, under the guard
  ;; Step 7 last is what makes "touching the handle from inside on-close
  ;; deterministically raises &uv-handle-closed" true by construction rather
  ;; than by timing.
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

  ;; Step 2 of the close order above. Design spec S6: the per-handle read
  ;; buffer "is freed in exactly one place: the close dispatcher, never
  ;; earlier, because Windows' overlapped-read model can still reference it
  ;; after a read completion is queued but before the handle has fully
  ;; stopped". A handle that never called uv-read-start! has 0 here, and
  ;; free! refuses 0 by design -- so the test is on the pointer, not on the
  ;; handle type.
  ;;
  ;; uv-stream-record?, not uv-tcp-record? (ADR-0014): pipe shares the same
  ;; buffer field and the same close-time free.
  (define (free-read-buffer! handle)
    (when (uv-stream-record? handle)
      (let ((buf (stream-read-buf handle)))
        (when (valid-pointer? buf)
          (free! buf)
          (count-read-buffer-free!)
          (set-stream-read-buf! handle 0)
          (set-stream-read-buf-len! handle 0)))))

  ;; One counter class per handle kind (design spec S10). A kind with no arm
  ;; has no counter class, and since `kind` is set by the constructors in
  ;; this file, that cannot be reached from outside it.
  (define (count-handle-free! kind)
    (case kind
      ((timer)   (count-timer-free!))
      ((tcp)     (count-tcp-free!))
      ((pipe)    (count-pipe-free!))
      ((process) (count-process-free!))
      (else #f)))

  ;; --- the setup-class spawn failure's undo (design spec v0.3 S5.6) ------
  ;; ADR-0015 measured two spawn-failure classes with opposite correct
  ;; cleanups. The exec class rides the ordinary close protocol above -- its
  ;; handle is still in loop->handle_queue, so uv_close is what unlinks it
  ;; and close-dispatch is what frees it. The SETUP class left uv_spawn
  ;; through its `error:` label, which already unlinked the handle
  ;; (vendor/libuv/src/unix/process.c:1075-1076); calling uv_close there was
  ;; measured to splice a LATER-registered live handle out of the queue
  ;; while still answering uv_loop_close 0. So that class frees directly,
  ;; and this is where it does it.
  ;;
  ;; THE SAME ORDER AS close-dispatch, MINUS THE PARTS THAT DO NOT APPLY:
  ;;   1. free the handle pointer  -- there is no read buffer (uv-read-start!
  ;;                                  was never reachable on a handle that
  ;;                                  never escaped uv-spawn!) and no
  ;;                                  registry entry to pop, because the
  ;;                                  setup class never registers and never
  ;;                                  counts (ADR-0015 decision 3)
  ;;   2. zero the stored uptr     -- at the freeing site, so a use-after-free
  ;;                                  is a structured condition rather than
  ;;                                  the plausible wrong answer spike Q1
  ;;                                  measured
  ;;   3. transition to 'closed
  ;; There is no on-close to run: nothing was ever registered, so no caller
  ;; could have attached one, and no close callback is expected from libuv.
  ;;
  ;; The not-registered precondition is CHECKED rather than commented
  ;; (AGENTS.md): a registered pointer here means the caller took the wrong
  ;; ADR-0015 arm, and freeing it would leave the registry holding a dangling
  ;; address for the next dispatcher to resolve. That is worth losing the
  ;; original errno over.
  (define (discard-failed-handle! handle)
    (require-handle handle 'uv-discard-failed-handle!)
    (let ((ptr (handle-pointer handle 'uv-discard-failed-handle!)))
      (when (registry-ref ptr)
        (raise (make-uv-invalid-argument 'uv-discard-failed-handle!
                                         'failed-handle-still-registered)))
      (free! ptr)
      (set-handle-ptr! handle 0)
      (set-handle-state! handle 'closed)))

  ;; --- the walk QUERY machinery (design spec v0.3 S5.2, ADR-0015) --------
  ;; ADR-0015's spawn-failure discriminator needs an instrument for "is this
  ;; handle still in loop->handle_queue" -- "ask the loop, don't guess"
  ;; rather than a guess from the rc -- and `uv_walk` is the one this binding
  ;; ships (the rejected alternative, a private handle_queue back-pointer
  ;; read, was unmeasured by the spike and reads a field uv.h marks
  ;; private). The QUERY lives here, beside the registry it complements.
  ;; INSTALLING walk-dispatch as the 'walk dispatcher slot is (libuv
  ;; process)'s job, at its own library-body time, through
  ;; install-dispatch-procedure! -- the dns.sls late-install seam's second
  ;; v0.3 application, same as `exit` -- so a process image that never
  ;; imports (libuv process) keeps the raising stub for `walk`.
  ;;
  ;; The cell is RESET, THEN FILLED, once per call -- never accumulated
  ;; across calls: `uv_walk` fires walk-dispatch once per handle currently
  ;; in the loop's queue, synchronously, only for the duration of the
  ;; uv_walk call and on the caller's own thread (never from uv_run), so the
  ;; fresh list a single call builds is what handle-in-loop-queue? compares
  ;; against. Mirrors spike/process/07-spawn-failure.ss's `walk-acc`.
  (define walk-query-cell '())

  ;; uv_walk_cb: void (*)(uv_handle_t *handle, void *arg). `arg` is ignored
  ;; -- the query rides the closed-over cell instead of the void* libuv
  ;; passes through. NOT dispatch-guarded and NOT routed through
  ;; record-orphan-callback!: walk visits whatever libuv says is in the
  ;; queue, recognized by this registry or not, and the point of the query
  ;; is exactly "what does libuv say is there", not "what do we recognize".
  (define (walk-dispatch walked-ptr arg)
    (set! walk-query-cell (cons walked-ptr walk-query-cell)))

  ;; (handle-in-loop-queue? loop handle) -- ADR-0015's measured instrument.
  ;; Resets the cell, walks the loop, and answers whether HANDLE's own
  ;; pointer was among the pointers walk-dispatch just collected. Takes the
  ;; loop and handle RECORDS, not raw uptrs, and reads their pointers
  ;; through this file's own loop-ptr/handle-ptr accessors -- the same
  ;; boundary rule every other query in this file follows.
  (define (handle-in-loop-queue? loop handle)
    (set! walk-query-cell '())
    (uv-walk-native (loop-ptr loop) 0)
    (and (memv (handle-ptr handle) walk-query-cell) #t))

  ;; --- the close protocol (design spec S5) -------------------------------
  ;; IDEMPOTENT BY AN EXPLICIT STATE TEST, and the on-close argument of a
  ;; second call is deliberately DROPPED rather than replacing the first: the
  ;; close is already in flight, so the callback the caller registered when
  ;; they started it is the one that has to run. Silently replacing it would
  ;; make which callback runs depend on how many times a caller happened to
  ;; call uv-close!.
  ;;
  ;; Nothing is freed here. uv_close only SCHEDULES close_cb; the dispatcher
  ;; above is where the pointer dies. That asymmetry is why no dynamic-wind
  ;; may wrap a handle's lifetime (design spec S5).
  (define (real-close-handle! handle on-close)
    (require-handle handle 'uv-close!)
    (unless (or (not on-close) (procedure? on-close))
      (raise (make-uv-invalid-argument 'uv-close! 'on-close-not-a-procedure)))
    (when (eq? (handle-state handle) 'open)
      (set-handle-on-close! handle on-close)
      (set-handle-state! handle 'closing)
      (uv-close-native (handle-pointer handle 'uv-close!))))

  ;; --- the close seam ----------------------------------------------------
  ;; uv-loop-teardown!'s sweep (in (libuv loop)) closes every handle
  ;; registered against the loop, and it must do so without importing the
  ;; handle types -- so it calls through this slot. The slot is filled once,
  ;; by this library's own body below, for the same reason as the dispatcher
  ;; slots: close policy must not be rebindable underneath a live handle.
  (define close-handle-proc
    (lambda (handle on-close)
      (raise (condition
              (make-uv-error)
              (make-who-condition 'uv-close-handle!)
              (make-message-condition
               "no handle close procedure has been installed")))))

  (define close-handle-installed #f)

  (define (close-handle-installed?) close-handle-installed)

  ;; The optional on-close is what makes this the whole of (libuv handle)'s
  ;; uv-close!; the teardown sweep uses the one-argument form.
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

  ;; --- filling the twelve dispatcher slots (ADR-0008) -----------------------
  ;; The slots in (libuv private native) take one procedure each, exactly
  ;; once, for the life of the process. v0.1's Stage 3 could only implement
  ;; two of its eight, and a second install-callback-dispatchers! call is
  ;; (rightly) refused -- so the procedures installed below (one per name
  ;; in dispatcher-names, twelve as of v0.3) are thin closures that look their
  ;; real implementation up in this table AT FIRE TIME.
  ;;
  ;; THE SEAM FOR STAGES 4 AND 5: a later stage calls
  ;; install-dispatch-procedure! with one of the six names still stubbed
  ;; here. That replaces the implementation behind an already-installed slot
  ;; without touching the slot, so the once-only guarantee ADR-0008 makes
  ;; about the slots survives intact. Each name is still install-once in its
  ;; own right, and the two names this stage implements are already spoken
  ;; for -- so nothing can be rebound underneath a running loop.
  (define dispatch-table (make-eq-hashtable))

  ;; The stub for a callback type whose stage has not landed. It raises for
  ;; the same reason native.sls's uninstalled stub does: a callback of this
  ;; type firing means libuv holds a pointer to a trampoline this binding
  ;; cannot service, and quietly doing nothing would leave a handle or a
  ;; request in a state nothing will ever complete. The raise is CONTAINED by
  ;; the seam's own guard below -- `dispatch-guarded` is no help here, since
  ;; it is invoked inside a dispatcher, i.e. only once one has already been
  ;; entered successfully.
  ;;
  ;; Through v0.1's Stage 5 every name in `dispatcher-names` was seeded with
  ;; this stub and then replaced, so nothing reached it. As of v0.2 Stage 2
  ;; the two DNS names (getaddrinfo, getnameinfo) hold it AGAIN, by design
  ;; -- exactly the added-callback-type case anticipated here: their real
  ;; dispatchers are installed through install-dispatch-procedure! at
  ;; (libuv dns)'s library-body time, so a process that never imports that
  ;; library keeps the contained raising stub, and nothing can start a DNS
  ;; request without the import. The stub's own property (a name with no
  ;; implementation fails loudly and contained, rather than silently doing
  ;; nothing) is precisely what such a process needs.
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

  ;; The names whose real implementation is in place. Seeded with this
  ;; stage's two, so install-dispatch-procedure! refuses to hijack them by
  ;; the same rule that stops a later stage installing twice.
  (define installed-dispatch-names '(timer close))

  ;; --- the seam's own guard ----------------------------------------------
  ;; THE OUTERMOST SCHEME FRAME LIBUV CAN REACH. `dispatch-guarded` protects
  ;; the USER's callback, but it runs *inside* timer-dispatch and
  ;; close-dispatch -- so anything that raises before a dispatcher gets that
  ;; far is not covered by it: the six stubs above, a bug in a dispatcher's
  ;; own registry lookup, and whatever Stages 4-5 install here. Every one of
  ;; those would otherwise unwind into a C stack frame, which spike FINDINGS
  ;; Q2 measured as process death (exit 255, no teardown, no foreign-free).
  ;; So the closure that goes into the native slot is guarded too, and this
  ;; guard is the one that makes "nothing raised inside a callback is
  ;; permitted to unwind into libuv" (design spec S8) true of the WHOLE
  ;; dispatch path rather than of its last step.
  ;;
  ;; Where the caught object goes depends on whether there is anywhere to put
  ;; it, which is the same fork the orphan fallback documents further up:
  ;;
  ;;   * pointer IS registered -> the entry knows its loop, so the object
  ;;     goes on that loop's error cell and surfaces from uv-run as
  ;;     &uv-callback-error, exactly like a user callback's raise. A Stage 4
  ;;     dispatcher bug therefore reaches the caller through the documented
  ;;     channel instead of a list nobody reads.
  ;;   * pointer is NOT registered -> there is no error cell and no loop to
  ;;     stop, so it is recorded as an orphan event. Ambiguity acknowledged:
  ;;     an entry there means "a callback arrived that this binding could not
  ;;     service", and does not distinguish an unknown pointer from a
  ;;     dispatcher that raised on a known-bad one. It is a bug reporter of
  ;;     last resort; both readings are bugs, and neither is recoverable.
  ;;
  ;; The first argument of all twelve callback signatures is the handle or
  ;; request pointer, which is why `(car args)` is the key to look up.
  (define (contain-dispatcher-raise! name ptr obj)
    (let ((loop (registry-loop-of ptr)))
      (if loop
          (loop-record-error! loop obj)
          (record-orphan-callback! name ptr))))

  ;; The rest-args list this closure conses per fire, and its second
  ;; hashtable lookup (dispatch-procedure), were measured against an
  ;; arity-specific case-lambda replacement and kept: together with
  ;; dispatcher-ref's lookup they cost ~6 ns of a >=26 microsecond fire
  ;; (.plans/2026-08-18-dispatch-benchmark.md) -- and the rest-args half of
  ;; that is pure noise, since Chez compiles this shape as well as the fixed
  ;; arities.
  (define (seam-closure name)
    (lambda args
      (let ((ptr (if (pair? args) (car args) 0)))
        (guard (e (#t (contain-dispatcher-raise! name ptr e)))
          (apply (dispatch-procedure name) args)))))

  ;; A definition, not a bare expression: R6RS library bodies take all their
  ;; definitions before any expression, and this wiring has to run before
  ;; anything can fire a callback or sweep a handle. Same shape, and same
  ;; reason, as native.sls's `uv-loaded`.
  (define dispatchers-wired
    (begin
      (for-each (lambda (name)
                  (hashtable-set! dispatch-table name
                                  (unimplemented-dispatcher name)))
                dispatcher-names)
      (hashtable-set! dispatch-table 'timer timer-dispatch)
      (hashtable-set! dispatch-table 'close close-dispatch)
      ;; Stages 4 and 5's six go in through the SEAM rather than by writing
      ;; the table directly, even though they live in this same file: that is
      ;; the documented once-per-name path (ADR-0008, and
      ;; .plans/stage-3-mutation-log.md's "the seam Stages 4 and 5 plug
      ;; into"), and using it here means the path is the one already
      ;; exercised rather than one nothing has run. With these six every
      ;; v0.1 callback type has an implementation and its name is spoken
      ;; for against a later install. The two v0.2 DNS names (getaddrinfo,
      ;; getnameinfo) are NOT installed here: they keep the raising stub
      ;; seeded above, BY DESIGN, until (libuv dns) installs the real
      ;; dispatchers through this same install-dispatch-procedure! seam at
      ;; its library-body time -- a process that never imports (libuv dns)
      ;; keeps the contained stub, and nothing can start a DNS request
      ;; without the import (ADR-0011; design spec v0.2 S5.4).
      (for-each (lambda (entry)
                  (install-dispatch-procedure! (car entry) (cdr entry)))
                (list (cons 'connection connection-dispatch)
                      (cons 'write-done write-done-dispatch)
                      (cons 'shutdown   shutdown-dispatch)
                      (cons 'connect    connect-dispatch)
                      (cons 'alloc      alloc-dispatch)
                      (cons 'read       read-dispatch)))
      ;; Looked up by name at fire time, never captured here: that
      ;; indirection is the whole seam. Guarded, because this closure is what
      ;; libuv actually calls.
      (install-callback-dispatchers!
       (map (lambda (name) (cons name (seam-closure name)))
            dispatcher-names))
      (install-close-handle! real-close-handle!)
      'wired)))
