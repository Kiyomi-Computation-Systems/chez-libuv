# ADR-0018: Write submission is unbuffered; queue-depth policy belongs to the consumer

- **Status:** Accepted (2026-08-30)
- **Date:** 2026-08-30
- **Scope:** chez-libuv v0.5
- **Related:** [design spec](../2026-08-29-chez-libuv-v0.5-flow-control-design.md) §1, §11,
  [ADR-0007](0007-no-guardians-explicit-close.md),
  [ADR-0009](0009-copy-at-the-boundary.md),
  [ADR-0011](0011-handle-less-loop-scoped-requests.md)

## Context

v0.5's driving use case is a server holding thousands of concurrent
connections, and the write side is where an unbounded producer can grow
memory without limit: nothing today stops a caller from issuing `uv-write!`
in a tight loop against a slow reader. The natural-looking fix is to have the
binding hold back writes once some threshold is crossed — buffer them
Scheme-side, or refuse the call outright — and only submit to libuv as the
peer drains.

That fix runs into two structural facts about how this binding is built,
both true independent of where the threshold is set or how it is measured.

**Ordering.** `uv-shutdown!` submits to libuv immediately — there is no
deferral point in its own path:

```scheme
(define (uv-shutdown! stream on-shutdown)
  (require-open-stream stream 'uv-shutdown!)
  (require-callback on-shutdown 'uv-shutdown! 'on-shutdown-not-a-procedure)
  (let* ((block (alloc-zeroed (uv-req-size (uv-shutdown-req-type))))
         (req (%make-uv-req-record block 'shutdown stream on-shutdown)))
    (registry-register! block 'shutdown-req (handle-loop stream) req)
    (guard (e (#t (abandon-request! req) (raise e)))
      (uv-check (uv-shutdown-native block (handle-pointer stream 'uv-shutdown!))
                'uv-shutdown!))
    req))
```
(`src/libuv/stream.sls:111-120`)

If `uv-write!` held a block back — queued rather than submitted — a caller
that writes, then shuts down, would have the shutdown reach libuv *first*.
libuv would see `uv_shutdown` ahead of the write it was issued after, and
the FIN would go out ahead of data the caller believed it had already sent.
A binding that queues writes therefore either has to make `uv-shutdown!`
drain the queue first — new coordination between two verbs that today know
nothing about each other — or it ships a reordering bug.

**Teardown.** `uv-close!` frees exactly two things and nothing else: the
read buffer, then the handle pointer.

```scheme
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
```
(`src/libuv/private/handles.sls:984-997`)

A block libuv never received is a block libuv cannot cancel. Any write held
back by a Scheme-side queue needs its own teardown path — something has to
walk that queue, free every unsubmitted block, and invoke every
`on-complete` so a caller waiting on a completion is not left hanging
forever. `close-dispatch` has no such step today, and adding one is not a
detail: it is a second free site for write memory (the first is the
write-done dispatcher, ADR-0009's amendment), a second place a completion
callback can fire from, and a new interaction with the teardown sweep
(`uv-loop-teardown!`) that today closes every handle and trusts each one's
own close path to finish its own bookkeeping.

## Decision

**The binding will not hold unsubmitted write blocks, will not enforce a
queue-depth or byte cap, and `uv-write!` will not refuse.** Every write that
passes validation is submitted to libuv before `uv-write!` returns, exactly
as it is today. Queueing and admission control remain server policy, built
on top of the two quantities §4.1 gives the consumer to bound its own memory
(outstanding payload bytes and outstanding request count) and the congestion
signal `uv-stream-write-queue-size` reports once bytes are inside libuv.

## Consequences

- **Both grounds above are bugs the binding would own**, not tuning
  questions: FIN-before-data is a correctness violation of the shutdown
  contract, and an unswept queue on close is a resource leak with no test
  covering it. Neither is fixed by choosing a better threshold.
- **The property a bounded queue forfeits: visibility.** A producer that
  writes without limit still grows without limit — the difference is only
  which heap it grows on. A Scheme-side queue is invisible to `live-counts`
  and to both teardown sweeps (`handles.sls:500`, `:508`), which is worse
  than today's foreign-block growth, because that at least shows up in the
  request-count and payload-byte totals the consumer is already keeping.
  The OOM arrives regardless; a Scheme-side queue only adds a layer between
  cause and symptom, and takes away the debug counters that would have shown
  the cause.
- **Consumers stay responsible for their own admission policy**, exactly as
  they are for connection tracking (§9): the binding reports, the layer
  above decides.
- **Rejected, more cheaply: `uv-stream-set-write-limit!`.** A
  caller-declared, binding-enforced cap whose default is a no-op is
  genuinely opt-in — no existing caller's behaviour changes until it asks
  for the limit — and could be added later without breaking anything. That
  is exactly why it should wait: nothing in this milestone has a consumer
  asking for it, and adding an enforcement mechanism on speculation would
  amend a promise this binding has made since v0.1 — "transport only, no
  backpressure policy of its own" (`README.org:19-21`) — before any real
  workload has shown the promise wrong.

Queueing and admission remain server policy.
