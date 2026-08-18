#!r6rs
;;; The handle registry, the loop record, and the callback error policy --
;;; design spec S5 ("The registry is the GC root"), S8 (store-and-reraise),
;;; and ADR-0007 (no guardians: closing is explicit, never GC-timed).
;;;
;;; Stage 2 delivers the registry and the loop record. The handle records
;;; themselves (timer, TCP), the lifecycle state machine's 'closing arm, and
;;; the eight dispatcher procedures arrive with Tasks 7-9; the seams they
;;; plug into -- `close-handle!` and (libuv private native)'s dispatcher
;;; slots -- exist here now, and refuse to be used until they are filled.
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
          loop-pending-error set-loop-pending-error!
          loop-has-pending-error? clear-loop-pending-error!
          loop-deferred-error-list set-loop-deferred-error-list!
          loop-open? require-open-loop require-loop loop-pointer

          ;; the callback error policy (design spec S8)
          loop-record-error!

          ;; the close seam Task 7 fills
          close-handle! install-close-handle! close-handle-installed?)
  (import (rnrs)
          (libuv private conditions)
          ;; uv_stop only: design spec S8 requires the loop to be stopped
          ;; when the FIRST callback error is recorded, and that recording
          ;; happens here, in the policy, not at the call site.
          (only (libuv private native) uv-loop-stop))

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

  ;; --- the close seam ----------------------------------------------------
  ;; uv-loop-teardown!'s sweep closes every handle registered against the
  ;; loop, but no handle TYPE exists until Task 7, and the close protocol
  ;; (design spec S5: uv_close, then the close dispatcher frees the pointer
  ;; and zeroes it) belongs with the handle records that Task 7 introduces.
  ;;
  ;; So this is a slot, not a procedure: Task 7 installs the real uv-close!
  ;; here, and until it does, sweeping a registered handle raises rather than
  ;; silently leaking it. Install-once for the same reason as the dispatcher
  ;; slots -- close policy must not be rebindable underneath a live handle.
  (define close-handle-proc
    (lambda (handle)
      (raise (condition
              (make-uv-error)
              (make-who-condition 'uv-close-handle!)
              (make-message-condition
               "no handle close procedure has been installed")))))

  (define close-handle-installed #f)

  (define (close-handle-installed?) close-handle-installed)

  (define (close-handle! handle) (close-handle-proc handle))

  (define (install-close-handle! proc)
    (when close-handle-installed
      (raise (make-uv-invalid-argument 'uv-install-close-handle!
                                       'close-handle-already-installed)))
    (unless (procedure? proc)
      (raise (make-uv-invalid-argument 'uv-install-close-handle!
                                       'not-a-procedure)))
    (set! close-handle-proc proc)
    (set! close-handle-installed #t)))
