#!r6rs
;;; The handle registry, the loop record, and the callback error policy --
;;; design spec S5 ("The registry is the GC root"), S8 (store-and-reraise),
;;; and ADR-0007 (no guardians: closing is explicit, never GC-timed).
;;;
;;; Stage 2 delivered the registry and the loop record. Stage 3 adds the
;;; handle records, the full 'open -> 'closing -> 'closed state machine, the
;;; callback guard, and the timer and close dispatchers -- and fills both
;;; seams: (libuv private native)'s eight dispatcher slots and this library's
;;; own `close-handle!`. The remaining six callback types are installed as
;;; raising stubs that Stages 4-5 replace by name through
;;; `install-dispatch-procedure!`, with no second slot install.
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
          registry-count registry-snapshot-for-loop

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
          handle-ptr handle-kind handle-loop
          handle-state set-handle-state!
          handle-on-close set-handle-on-close!
          timer-on-timeout set-timer-on-timeout!
          require-handle require-open-handle handle-pointer

          ;; the callback error policy (design spec S8)
          loop-record-error! dispatch-guarded orphan-callback-events

          ;; the close protocol, and the seam Stages 4-5 replace their own
          ;; dispatchers through
          close-handle! install-close-handle! close-handle-installed?
          install-dispatch-procedure!)
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
          (only (libuv private native)
                uv-loop-stop uv-close-native free! count-timer-free!
                dispatcher-names install-callback-dispatchers!))

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

  ;; kind:   'loop | 'timer | 'tcp | 'write-req | 'connect-req | 'shutdown-req
  ;; loop:   the owning loop record (a loop owns itself)
  ;; object: the Scheme record the dispatchers and the teardown sweep hand
  ;;         back to their callers
  (define (registry-register! ptr kind loop object)
    (unless (valid-pointer? ptr)
      (raise (make-uv-invalid-argument 'uv-registry-register!
                                       'null-or-invalid-pointer)))
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

  ;; Every HANDLE registered against this loop. The loop's own entry is
  ;; excluded by kind -- a loop that appeared in its own snapshot would be
  ;; handed to close-handle! by uv-loop-teardown!, which is not a thing that
  ;; can be uv_close'd.
  (define (registry-snapshot-for-loop loop)
    (let-values (((keys entries) (hashtable-entries registry)))
      (let collect ((i 0) (acc '()))
        (if (= i (vector-length entries))
            acc
            (let ((entry (vector-ref entries i)))
              (collect (+ i 1)
                       (if (and (eq? (registry-entry-loop entry) loop)
                                (not (eq? (registry-entry-kind entry) 'loop)))
                           (cons (registry-entry-object entry) acc)
                           acc)))))))

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

  ;; uv_close_cb: void (*)(uv_handle_t *handle). THE ONLY PLACE A HANDLE
  ;; POINTER IS FREED (design spec S5, S10).
  ;;
  ;; THE ORDER IS THE SPECIFICATION, not an implementation detail:
  ;;   1. pop the registry entry   -- so nothing can dispatch on this pointer
  ;;                                  again, and so the address is free to be
  ;;                                  reused by a later foreign-alloc without
  ;;                                  colliding with a stale entry
  ;;   2. free the read buffer     -- Stage 5's per-handle buffer; nothing to
  ;;                                  free for a timer
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
            (free! handle-ptr)
            (count-handle-free! (handle-kind handle))
            (set-handle-ptr! handle 0)
            (set-handle-state! handle 'closed)
            (let ((on-close (handle-on-close handle)))
              (when on-close
                (dispatch-guarded (handle-loop handle) on-close))))
          (record-orphan-callback! 'close handle-ptr))))

  ;; One counter class per handle kind (design spec S10). Stage 4 adds the
  ;; 'tcp arm next to this one; a kind with no arm has no counter class yet,
  ;; and since `kind` is set by the constructors in this file, that cannot
  ;; be reached from outside it.
  (define (count-handle-free! kind)
    (case kind
      ((timer) (count-timer-free!))
      (else #f)))

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

  ;; --- filling the eight dispatcher slots (ADR-0008) ---------------------
  ;; The slots in (libuv private native) take one procedure each, exactly
  ;; once, for the life of the process. Stage 3 can only implement two of the
  ;; eight, and a second install-callback-dispatchers! call is (rightly)
  ;; refused -- so the eight procedures installed below are thin closures
  ;; that look their real implementation up in this table AT FIRE TIME.
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
  ;; it is invoked inside timer-dispatch and close-dispatch, i.e. only once a
  ;; dispatcher has already been entered successfully.
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
  ;; The first argument of all eight callback signatures is the handle or
  ;; request pointer, which is why `(car args)` is the key to look up.
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
      ;; Looked up by name at fire time, never captured here: that
      ;; indirection is the whole seam. Guarded, because this closure is what
      ;; libuv actually calls.
      (install-callback-dispatchers!
       (map (lambda (name) (cons name (seam-closure name)))
            dispatcher-names))
      (install-close-handle! real-close-handle!)
      'wired)))
