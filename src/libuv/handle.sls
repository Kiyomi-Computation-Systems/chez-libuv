#!r6rs
;;; (libuv handle) -- what every handle type has in common: the state
;;; predicates, the owning loop, and `uv-close!`. Design spec S5 ("Handle
;;; lifecycle state machine") and ADR-0007 ("no guardians: uv_close is always
;;; explicit, never GC-finalization-driven").
;;;
;;; The close protocol lives here, not in timer.sls, because it is generic:
;;; the TCP handle Stage 4 adds reuses this file verbatim. What differs
;;; between handle types is construction and the type-specific verbs, which
;;; is exactly what (libuv timer) and (libuv tcp) carry.
;;;
;;; NOTHING HERE CLOSES ANYTHING BY ITSELF. `uv-close!` is the only path that
;;; begins the close protocol, and a handle nobody closes leaks
;;; deterministically and visibly through the debug counters (design spec
;;; S10) rather than being swept up at some later GC on some other thread
;;; (ADR-0007).
(library (libuv handle)
  (export uv-handle? uv-timer? uv-tcp? uv-pipe? uv-process? uv-signal?
          uv-handle-open? uv-handle-closing? uv-handle-state
          uv-handle-loop
          uv-send-buffer-size uv-send-buffer-size!
          uv-recv-buffer-size uv-recv-buffer-size!
          uv-close!)
  ;; v0.5 adds the OS socket buffer-size wrappers below, which DO raise
  ;; &uv-invalid-argument directly (not merely by way of (libuv private
  ;; handles)), so (libuv private conditions) and (libuv private native) join
  ;; the import here for the first time.
  (import (rnrs)
          (libuv private conditions)
          (libuv private handles)
          (libuv private native))

  ;; WHY THERE IS NO `uv-handle-closed?` PREDICATE. The name is already
  ;; taken, by the condition predicate of &uv-handle-closed (design spec S9),
  ;; which this binding's facade also exports -- two different procedures
  ;; under one name is not a thing R6RS or a reader can resolve. So the third
  ;; state is asked for by name: (eq? 'closed (uv-handle-state h)). The two
  ;; predicates that remain are the ones with no such clash.
  ;;
  ;; uv-handle-open? and uv-handle-closing? NEVER RAISE, on anything: they
  ;; are what an on-close callback or an error path calls to find out whether
  ;; it may touch a handle at all, and a predicate that raises on the state
  ;; it exists to report would be useless there. Non-handles answer #f rather
  ;; than raising for the same reason.
  (define (uv-handle-open? handle)
    (and (uv-handle? handle) (eq? (handle-state handle) 'open)))

  (define (uv-handle-closing? handle)
    (and (uv-handle? handle) (eq? (handle-state handle) 'closing)))

  ;; The state symbol itself: 'open | 'closing | 'closed. This one DOES
  ;; require a handle -- it is an accessor, not a predicate, and answering #f
  ;; for a non-handle would be the defaulting-accessor trap AGENTS.md names
  ;; (a caller comparing the result against 'closed would read "not closed"
  ;; for an argument that is not a handle at all).
  (define (uv-handle-state handle)
    (require-handle handle 'uv-handle-state)
    (handle-state handle))

  ;; Answers for a CLOSED handle too: the loop backpointer outlives the
  ;; pointer, and an on-close callback that wants to create a replacement
  ;; handle needs it.
  (define (uv-handle-loop handle)
    (require-handle handle 'uv-handle-loop)
    (handle-loop handle))

  ;; Kind-keyed rather than record-type-keyed, so Stage 4's TCP record
  ;; answers this the day it exists without editing this file. (uv-timer? is
  ;; the record predicate itself, from handles.sls.)
  (define (uv-tcp? handle)
    (and (uv-handle? handle) (eq? (handle-kind handle) 'tcp)))

  ;; Kind-keyed like uv-tcp?, and for the same reason (THE SPEC §3): the
  ;; predicate lives with the kind vocabulary, not with the module that
  ;; constructs the handle.
  (define (uv-pipe? handle)
    (and (uv-handle? handle) (eq? (handle-kind handle) 'pipe)))

  ;; Kind-keyed like the two above (design spec v0.3 S3/S4.5). A process is a
  ;; handle and not a stream, so this predicate is the one that separates it
  ;; from the two stream kinds -- the stream verbs' own gate answers the
  ;; complementary question, and neither is written in terms of the other.
  (define (uv-process? handle)
    (and (uv-handle? handle) (eq? (handle-kind handle) 'process)))

  ;; Kind-keyed like the three above (v0.4 design spec §4.6): the predicate
  ;; lives with the kind vocabulary, not with the module that constructs
  ;; the handle.
  (define (uv-signal? handle)
    (and (uv-handle? handle) (eq? (handle-kind handle) 'signal)))

  ;; --- OS socket buffer sizes ----------------------------------------------
  ;; THREE DIFFERENT BUFFERS share confusable names, and docs/api.md tabulates
  ;; them together for that reason:
  ;;
  ;;   * chez-libuv's per-handle read buffer -- fixed by the first
  ;;     uv-read-start!, freed by the close dispatcher, 64 KiB by default;
  ;;   * the OS SEND buffer -- these procedures;
  ;;   * the OS RECEIVE buffer -- these procedures.
  ;;
  ;; Setting SO_RCVBUF does not resize the chez-libuv buffer, or vice versa.
  ;; At high connection counts the OS buffers are a first-class memory cost:
  ;; Linux autotunes SO_RCVBUF from roughly 87 KB per socket upward, which at
  ;; ten thousand connections can exceed every read buffer combined.
  ;;
  ;; PLATFORM SUPPORT IS NOT UNIFORM (vendor/libuv/docs/src/handle.rst:202):
  ;; TCP, pipe and UDP on Unix; TCP and UDP only on Windows. The gate is an
  ;; allowlist failing closed for kinds libuv never supports; libuv's own
  ;; UV_ENOTSUP is the backstop for the platform-specific case.
  ;;
  ;; A socket needs an fd but NOT a connection: bind is sufficient.
  ;;
  ;; require-open-handle, not require-handle: on a 'closing handle the pointer
  ;; is still live, so a bare require-handle would let all four SILENTLY
  ;; SUCCEED against a handle that is going away.
  (define (require-socket-handle handle who)
    (require-open-handle handle who)
    (unless (memq (handle-kind handle) '(tcp pipe))
      (raise (make-uv-invalid-argument who 'not-a-socket-handle)))
    handle)

  ;; n must fit an int: c-int-set! bottoms out in foreign-set! 'int, which
  ;; raises a raw Chez exception -- outside this binding's condition hierarchy
  ;; -- for a value that does not fit.
  (define (require-buffer-size n who)
    (unless (and (integer? n) (exact? n) (positive? n) (< n 2147483648))
      (raise (make-uv-invalid-argument who 'buffer-size-out-of-range)))
    n)

  ;; THE ZERO IS THE API. alloc-zeroed, never foreign-alloc.
  (define (get-buffer-size! native handle who)
    (require-socket-handle handle who)
    (let ((cell (alloc-zeroed (c-int-size))))
      (guard (e (#t (free! cell) (raise e)))
        (uv-check (native (handle-pointer handle who) cell) who)
        (let ((v (c-int-ref cell)))
          (free! cell)
          v))))

  (define (set-buffer-size! native handle n who)
    (require-socket-handle handle who)
    (require-buffer-size n who)
    (let ((cell (alloc-zeroed (c-int-size))))
      (guard (e (#t (free! cell) (raise e)))
        (c-int-set! cell n)
        (uv-check (native (handle-pointer handle who) cell) who)
        (free! cell))))

  (define (uv-send-buffer-size handle)
    (get-buffer-size! uv-send-buffer-size-native handle 'uv-send-buffer-size))
  (define (uv-send-buffer-size! handle n)
    (set-buffer-size! uv-send-buffer-size-native handle n 'uv-send-buffer-size!))
  (define (uv-recv-buffer-size handle)
    (get-buffer-size! uv-recv-buffer-size-native handle 'uv-recv-buffer-size))
  (define (uv-recv-buffer-size! handle n)
    (set-buffer-size! uv-recv-buffer-size-native handle n 'uv-recv-buffer-size!))

  ;; (uv-close! handle [on-close]) -- idempotent, asynchronous, and the only
  ;; way a handle is ever freed.
  ;;
  ;; ASYNCHRONOUS is the load-bearing word: this starts the close and
  ;; returns. The handle is 'closing until the loop runs the close callback,
  ;; which is where the pointer is freed and where `on-close` runs -- so a
  ;; caller who needs the close to have COMPLETED must run the loop
  ;; afterwards (uv-loop-teardown! does exactly that).
  ;;
  ;; A second call while the first is still in flight is a no-op, and its
  ;; on-close argument is dropped rather than replacing the first: the
  ;; callback registered when the close started is the one that runs.
  ;;
  ;; Legal from inside a callback (design spec S8) -- including from inside
  ;; the handle's own timer callback, which is how a self-limiting timer
  ;; shuts itself down.
  (define uv-close!
    (case-lambda
      ((handle) (close-handle! handle))
      ((handle on-close) (close-handle! handle on-close)))))
