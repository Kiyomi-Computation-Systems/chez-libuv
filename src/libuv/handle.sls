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
  (export uv-handle? uv-timer? uv-tcp?
          uv-handle-open? uv-handle-closing? uv-handle-state
          uv-handle-loop
          uv-close!)
  ;; No (libuv private conditions) import: every condition this library can
  ;; produce is raised by (libuv private handles) on its behalf
  ;; (require-handle, and the close protocol's own checks). Importing it
  ;; "just in case" would put a name in scope that nothing here uses.
  (import (rnrs)
          (libuv private handles))

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
