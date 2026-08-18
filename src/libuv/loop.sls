#!r6rs
;;; (libuv loop) -- the event loop's public surface, per design spec S5's
;;; "Loop operations" and S8's callback error policy.
;;;
;;; Nothing here hands a caller a pointer. A loop is an opaque record; every
;;; procedure below takes that record, and the only way to get one is
;;; make-uv-loop or call-with-uv-loop.
;;;
;;; TEARDOWN IS EXPLICIT (ADR-0007). No guardian, no finalizer: a loop the
;;; caller never closes stays allocated and stays visible in the debug
;;; counters (design spec S10), which is the point -- a leak that a test can
;;; see beats a close that happens at some indeterminate later GC.
(library (libuv loop)
  (export make-uv-loop uv-loop? uv-loop-open?
          uv-run uv-stop! uv-loop-alive? uv-now
          uv-loop-live-handles uv-loop-deferred-errors
          uv-loop-close! uv-loop-teardown! call-with-uv-loop)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))

  ;; --- construction -------------------------------------------------------
  ;; ensure-native-loaded! is called HERE rather than being assumed: it is
  ;; idempotent and mutex'd (design spec S4), and make-uv-loop is the first
  ;; thing any program using this binding calls, so this is where the version
  ;; gate, the constants snapshot, and the uv_buf_t layout check actually run
  ;; for most callers.
  ;;
  ;; The allocation size comes from uv_loop_size() -- the RUNNING library's
  ;; own answer -- not from the shim's compile-time SIZEOF_UV_LOOP_T. They
  ;; agree (tests/test-native.sps asserts it), and the version gate is what
  ;; keeps them agreeing; but the block libuv writes into should be sized by
  ;; libuv.
  ;;
  ;; Order matters on the failure path: if uv_loop_init fails, the block is
  ;; freed BEFORE the condition escapes and nothing has been registered, so
  ;; there is no half-built loop for a caller to find (design spec S5's
  ;; "nonzero rc => free immediately + raise; nothing registered yet").
  (define (make-uv-loop)
    (ensure-native-loaded!)
    (let ((ptr (alloc-zeroed (uv-loop-size))))
      (guard (e (#t (free! ptr) (raise e)))
        (uv-check (uv-loop-init ptr) 'make-uv-loop))
      (let ((loop (%make-uv-loop-record ptr)))
        (registry-register! ptr 'loop loop loop)
        (count-loop-new!)
        loop)))

  (define (uv-loop-open? loop)
    (require-loop loop 'uv-loop-open?)
    (loop-open? loop))

  ;; --- running ------------------------------------------------------------
  ;; The mode symbols are mapped through (libuv private constants), never
  ;; transcribed (ADR-0005): UV_RUN_DEFAULT/ONCE/NOWAIT are whatever the
  ;; running libuv's enum says they are.
  (define (run-mode->int mode who)
    (case mode
      ((default) (uv-run-default))
      ((once)    (uv-run-once))
      ((nowait)  (uv-run-nowait))
      (else (raise (make-uv-invalid-argument who 'unknown-run-mode)))))

  ;; (uv-run loop [mode]) -> #t if work remains, #f if the loop ran dry.
  ;;
  ;; The return value is a BOOLEAN, deliberately, even though uv_run returns
  ;; an int: 0 is true in Scheme, so handing the raw int to a caller would
  ;; make `(when (uv-run l) ...)` fire on precisely the case it means to
  ;; skip (AGENTS.md's named trap).
  ;;
  ;; Re-entry is refused. Design spec S8 lists uv-run among the operations
  ;; that are illegal from inside a callback; the running? flag is what makes
  ;; that detectable, and dynamic-wind is what clears it even when the extent
  ;; is left by a raise or a continuation jump.
  ;;
  ;; WHAT IS CLEARED WHEN, and why they differ (design spec S8): the DEFERRED
  ;; list is cleared at the START of a run, because it is a record of the
  ;; previous run's aftermath that the caller had until now to read. The
  ;; PENDING error is consumed at the END, by the re-raise, because that is
  ;; the value being delivered -- clearing it on the way in would silently
  ;; discard an error a callback stored during the run that is only just
  ;; finishing.
  (define uv-run
    (case-lambda
      ((loop) (uv-run loop 'default))
      ((loop mode)
       (require-open-loop loop 'uv-run)
       (when (loop-running? loop)
         (raise (make-uv-invalid-argument 'uv-run 'loop-running)))
       (let ((mode-int (run-mode->int mode 'uv-run))
             (ptr (loop-pointer loop 'uv-run)))
         (set-loop-deferred-error-list! loop '())
         (let ((rc (dynamic-wind
                    (lambda () (set-loop-running! loop #t))
                    (lambda () (uv-loop-run ptr mode-int))
                    (lambda () (set-loop-running! loop #f)))))
           ;; Tested with the predicate, never with the VALUE's truthiness: a
           ;; callback may legitimately have raised #f, and `(when pending
           ;; ...)` would drop exactly that error on the floor (handles.sls's
           ;; `no-pending` note).
           (when (loop-has-pending-error? loop)
             (let ((pending (loop-pending-error loop)))
               (clear-loop-pending-error! loop)
               ;; Composed with the cause when the cause is a condition, so a
               ;; guard written against the ORIGINAL type still matches -- the
               ;; load-bearing half of store-and-reraise (design spec S8).
               ;; R6RS `raise` accepts any object, so a callback may also have
               ;; raised a non-condition; that one is wrapped alone, since
               ;; `condition` only composes conditions.
               (raise (if (condition? pending)
                          (condition (make-uv-callback-error pending) pending)
                          (make-uv-callback-error pending)))))
           ;; uv_run's int is "handles or requests still active", NOT an
           ;; errno: it must not go through uv-check, whose contract is that
           ;; any nonzero is a failure (native.sls).
           (not (zero? rc)))))))

  ;; Legal from inside a callback (design spec S8), which is why it takes the
  ;; open-loop check and nothing else: stopping a loop that is currently
  ;; running is the entire point.
  (define (uv-stop! loop)
    (require-open-loop loop 'uv-stop!)
    (uv-loop-stop (loop-pointer loop 'uv-stop!)))

  (define (uv-loop-alive? loop)
    (require-open-loop loop 'uv-loop-alive?)
    (not (zero? (uv-loop-alive (loop-pointer loop 'uv-loop-alive?)))))

  ;; libuv's cached "now", in milliseconds from an arbitrary origin. Cached
  ;; is the important word: it is updated once per loop iteration, so two
  ;; calls with no run between them answer the same number by design.
  (define (uv-now loop)
    (require-open-loop loop 'uv-now)
    (uv-loop-now (loop-pointer loop 'uv-now)))

  ;; --- inspection ---------------------------------------------------------
  ;; A fresh list of the handle RECORDS registered against this loop. Fresh
  ;; because the registry is the binding's own dispatch table; handing out a
  ;; structure a caller could mutate would let them unhook a live callback.
  (define (uv-loop-live-handles loop)
    (require-open-loop loop 'uv-loop-live-handles)
    (registry-snapshot-for-loop loop))

  ;; Everything a callback raised this run AFTER the first (design spec S8).
  ;; In occurrence order, freshly consed, cleared by the next uv-run.
  (define (uv-loop-deferred-errors loop)
    (require-open-loop loop 'uv-loop-deferred-errors)
    (reverse (loop-deferred-error-list loop)))

  ;; --- teardown -----------------------------------------------------------
  ;; Idempotent by an explicit state test: closing an already-closed loop is
  ;; a no-op, not an error, because cleanup code that has to remember whether
  ;; it already ran is cleanup code that eventually gets it wrong. This is
  ;; also what makes call-with-uv-loop's after-thunk safe to run on a loop
  ;; the body already closed.
  ;;
  ;; uv_loop_close returns -EBUSY (spike FINDINGS Q2 measured -16) when
  ;; handles are still open. That IS an errno, so it goes through uv-check
  ;; and reaches the caller as &uv-errno-error with errno 'EBUSY -- a symbol,
  ;; never a raw int (ADR-0006). Nothing is freed on that path: the loop is
  ;; still open and still usable, which is exactly what a caller who needs to
  ;; close their handles first requires.
  ;;
  ;; V0.2 DECISION (final review, Task 6 triage): a pending callback error is
  ;; silently discarded when the caller skips the next uv-run and goes
  ;; straight here -- the error cell lives on the record, nothing in this
  ;; procedure reads it, and closing makes it unreachable. v0.1 ships that
  ;; as-is: inventing a delivery channel at close time would change this
  ;; procedure's contract (today it raises only for a running loop, a bad
  ;; argument, or libuv's own errno). v0.2 must pick one deliberately --
  ;; either re-raise the composed &uv-callback-error from here, exactly as
  ;; uv-run's exit does, or document the discard as the contract. Until
  ;; then: the error is only ever lost by calling THIS procedure directly;
  ;; uv-run re-raises it, and uv-loop-teardown!'s drain delivers it after
  ;; the close.
  (define (uv-loop-close! loop)
    (require-loop loop 'uv-loop-close!)
    (when (loop-running? loop)
      (raise (make-uv-invalid-argument 'uv-loop-close! 'loop-running)))
    (when (eq? (loop-state loop) 'open)
      (let ((ptr (loop-pointer loop 'uv-loop-close!)))
        (uv-check (uv-loop-close ptr) 'uv-loop-close!)
        ;; 'closed the INSTANT the native close succeeds, before the registry
        ;; pop and the free: nothing after uv_loop_close can un-close the
        ;; native loop, so a raise from a later step (unreachable today --
        ;; the entry is registered and the pointer valid by construction)
        ;; must not leave a record still claiming 'open over a loop libuv
        ;; has already shut down, where a retried close! would hand the
        ;; closed loop back to uv_loop_close. Final-review triage item;
        ;; ordering rationale recorded in .plans/stage-2-mutation-log.md.
        (set-loop-state! loop 'closed)
        (registry-deregister! ptr)
        (free! ptr)
        ;; Zeroed IMMEDIATELY at the freeing site (design spec S10): a freed
        ;; uv_loop_t does not fault when read, it answers plausibly and
        ;; wrongly (spike FINDINGS Q1), so the stored pointer is the only
        ;; thing that can make a use-after-free detectable.
        (set-loop-ptr! loop 0)
        (count-loop-free!))))

  ;; An upper bound on drain iterations, not a timeout. Design spec S11:
  ;; "failure is iteration exhaustion, never wall-clock elapsed time" --
  ;; a wall-clock bound turns a slow machine into a flaky suite.
  (define max-drain-iterations 1024)

  ;; Close every handle on this loop, drain until they have finished closing,
  ;; then close the loop. The sweep is over the registry filtered by loop,
  ;; because v0.1 binds no uv_walk (design spec S5).
  ;;
  ;; The snapshot is taken ONCE, before the sweep: close-handle! deregisters
  ;; as it goes, and iterating a hashtable while deleting from it is
  ;; undefined behaviour in R6RS.
  ;;
  ;; The drain is what turns uv_close (which only STARTS a close) into a
  ;; completed one -- close_cb fires from inside uv_run, and until it does,
  ;; uv_loop_close would answer EBUSY.
  ;;
  ;; A CALLBACK ERROR DURING THE DRAIN IS CAUGHT, THE TEARDOWN IS FINISHED,
  ;; AND THE ERROR IS RE-RAISED AFTERWARDS. This was Stage 2's recorded open
  ;; question; Stage 3 made it reachable (an on-close callback that raises)
  ;; and decided it here. The alternative -- letting the first re-raise
  ;; escape as it stood -- leaves the loop OPEN with its handles half-closed,
  ;; which is precisely the invisible cleanup obligation spike FINDINGS Q2
  ;; measured and design spec S8 exists to avoid: the caller sees an error,
  ;; goes to close the loop, and gets EBUSY with no explanation. Teardown's
  ;; contract is that the loop is closed when it returns, and an error raised
  ;; by one on-close callback is not a reason to abandon the other handles.
  ;;
  ;; Only &uv-callback-error is caught -- the class uv-run itself
  ;; manufactures. Anything else (a broken pointer, a closed loop) is a
  ;; failure of the teardown machinery rather than a message from a callback,
  ;; and escapes immediately.
  ;;
  ;; Only the FIRST is kept, matching the pending/deferred split of S8. Later
  ;; drain iterations clear the deferred list as they go, which is the one
  ;; thing this policy costs: an error deferred during teardown is reported
  ;; by count only if the caller read it before the next iteration. Recorded
  ;; in .plans/stage-3-mutation-log.md rather than papered over.
  (define teardown-no-error (list 'no-error))

  ;; Answers 'drained, 'work, or the caught &uv-callback-error object.
  (define (drain-step loop)
    (guard (e ((uv-callback-error? e) e))
      (if (uv-run loop 'default) 'work 'drained)))

  (define (uv-loop-teardown! loop)
    (require-loop loop 'uv-loop-teardown!)
    (when (loop-running? loop)
      (raise (make-uv-invalid-argument 'uv-loop-teardown! 'loop-running)))
    (when (eq? (loop-state loop) 'open)
      (for-each close-handle! (registry-snapshot-for-loop loop))
      (let drain ((i 0) (stored teardown-no-error))
        (let ((outcome (drain-step loop)))
          (cond ((eq? outcome 'drained)
                 (uv-loop-close! loop)
                 (unless (eq? stored teardown-no-error) (raise stored)))
                ((< i max-drain-iterations)
                 (drain (+ i 1)
                        (if (and (eq? stored teardown-no-error)
                                 (not (eq? outcome 'work)))
                            outcome
                            stored)))
                (else
                 (raise (condition
                         (make-uv-error)
                         (make-who-condition 'uv-loop-teardown!)
                         (make-message-condition
                          "loop still had work after the drain bound")))))))))

  ;; dynamic-wind is valid around a LOOP, unlike around an individual handle:
  ;; teardown is synchronous once entered, whereas a handle's close completes
  ;; in a later callback (design spec S5).
  ;;
  ;; The before-thunk is the re-entry guard. On the first entry it is a
  ;; no-op; on a re-entry through a continuation captured inside the body and
  ;; invoked after the extent was left, the loop has already been torn down,
  ;; and the body would otherwise resume holding a record whose pointer is 0.
  ;; Refusing there means the failure names the actual problem
  ;; (&uv-handle-closed, kind 'loop) at the moment of re-entry, instead of
  ;; surfacing as a null-pointer condition from whatever the body did first.
  (define (call-with-uv-loop proc)
    (let ((loop (make-uv-loop)))
      (dynamic-wind
       (lambda ()
         (unless (loop-open? loop)
           (raise (make-uv-handle-closed 'loop))))
       (lambda () (proc loop))
       (lambda ()
         (when (loop-open? loop)
           (uv-loop-teardown! loop)))))))
