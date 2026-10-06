# API reference

One line per export. Argument lists, span conventions, error behaviour and
the lifecycle state machine are in the design specs under
[`.plans/`](../.plans/) (v0.1 §5–§9 and the per-milestone specs); these
tables exist so you can see the whole surface at once, not to restate it.

Importing the umbrella library `(libuv)` gives you everything below — it is
a facade that re-exports every public binding by name. The per-module
libraries exist for narrower imports.

## The loop — `(libuv loop)`

| Export | |
|---|---|
| `make-uv-loop` | A new loop. Initialises the binding, including the version gate |
| `uv-loop?` `uv-loop-open?` | Is this a loop; is it still open |
| `uv-run` | Run it: `'default`, `'once`, or `'nowait`. `#t` if work remains |
| `uv-stop!` | Stop the loop; legal from inside a callback |
| `uv-loop-alive?` | Whether the loop has anything left to do |
| `uv-now` | libuv's cached "now", in ms, updated once per iteration or by `uv-update-time!` |
| `uv-update-time!` | Refresh that cached "now" from the clock. Timers are armed from it, so a callback that held the loop calls this before arming a deadline, or the deadline starts from before the callback ran. Legal while the loop runs; runs nothing. Loop thread only: `&uv-wrong-thread` from any other. `uv_update_time` |
| `uv-loop-live-handles` | Fresh list of the handle records registered on this loop |
| `uv-loop-deferred-errors` | Everything callbacks raised this run *after* the first |
| `uv-loop-close!` | Close the loop. `'EBUSY` while handles are still open |
| `uv-loop-teardown!` | Close every handle, drain, then close the loop |
| `call-with-uv-loop` | The above as a scope; tears down on every exit path |

**One thread per loop**
([ADR-0019](../.plans/decisions/0019-threading-model-collect-safe-and-per-loop-affinity.md)).
A loop and its handles belong to one thread: the one that created the loop,
then whichever thread most recently entered `uv-run` on it — so a loop can be
built on one thread and handed to a dedicated loop thread, which keeps it
after `uv-run` returns. Every verb that operates on an open handle, plus
`make-uv-async` and `uv-update-time!`, raises `&uv-wrong-thread` from any
other thread before it touches anything. Verbs outside that check — among
them `uv-close!`, the other constructors, `uv-stop!`, and loop queries such
as `uv-now` — are loop-thread-only all the same, just unchecked. The one
exemption is `uv-async-send!`, which is how another thread reaches the loop
([Async](#async--libuv-async)). While the loop thread waits in `uv-run`, other
Scheme threads allocate and collect freely.

**A callback ends only by returning.** To end a run early, call `uv-stop!` or
raise. A continuation that escapes a callback leaves libuv in the middle of
an iteration that nothing can finish, so the loop stays marked running:
`uv-run`, `uv-loop-close!` and `uv-loop-teardown!` refuse it from then on.
The one exception is `call-with-uv-loop`, which still tears down its own loop
on the way out. If libuv cannot finish that teardown (escaping a close
callback strands the rest of libuv's batch of closes), the loop is left
marked running instead, and its body cannot be re-entered either way. An engine whose fuel runs out inside a callback is different,
because it can be resumed. The loop stays marked running while the engine is
suspended, so nothing can run, close or free the loop under it, and resuming
the engine finishes the run. Inside `call-with-uv-loop` the suspension is an
exit like any other: the loop is torn down, and resuming the engine raises
`&uv-handle-closed`.

## Handles — `(libuv handle)`

| Export | |
|---|---|
| `uv-handle?` `uv-timer?` `uv-tcp?` `uv-pipe?` `uv-process?` `uv-signal?` `uv-async?` | Type predicates |
| `uv-handle-open?` `uv-handle-closing?` | State predicates. Never raise, on anything |
| `uv-handle-state` | `'open` \| `'closing` \| `'closed`. There is no `uv-handle-closed?` — that name is the condition predicate |
| `uv-handle-loop` | The owning loop; answers for a closed handle too |
| `uv-send-buffer-size` `uv-send-buffer-size!` | The OS send buffer (`SO_SNDBUF`), in bytes. tcp/pipe/UDP on Unix, tcp/UDP only on Windows |
| `uv-recv-buffer-size` `uv-recv-buffer-size!` | The OS receive buffer (`SO_RCVBUF`), in bytes. Same platform support as the send-side pair |
| `uv-close!` | Start the close, optionally with an `on-close` callback. Idempotent |

## TCP — `(libuv tcp)`

| Export | |
|---|---|
| `make-uv-tcp` | A new TCP handle on a loop |
| `uv-tcp-bind!` | Bind to an address and port; IPv4 or IPv6 literal. Optional flag list: `'(reuseport)` binds with `SO_REUSEPORT` load balancing (libuv ≥ 1.49; the kernel distributes connections across sockets sharing the port). On a libuv without the flag it raises `&uv-constant-unavailable`; on a platform whose libuv lacks TCP reuseport (e.g. macOS) libuv answers an errno |
| `uv-tcp-getsockname-port` | The real port the kernel chose, for a bind to port 0 |
| `uv-tcp-sockname-address` | This end's own address and port, as `(values address-string-or-#f port)`. Unlike the peer side it needs no connection — a bound handle has a local name |
| `uv-listen!` | Listen; `on-connection` is called with the error or `#f` |
| `uv-accept!` | A new open handle for the queued connection |
| `uv-tcp-connect!` | Connect; answers the in-flight request record |
| `uv-tcp-nodelay!` | `TCP_NODELAY`. Takes a boolean, not an int |
| `uv-tcp-keepalive!` | `SO_KEEPALIVE`. `(tcp #f)` disables; `(tcp #t idle-seconds)` enables — the idle delay is in whole seconds and is required (and must be positive) when enabling. `uv_tcp_keepalive` |
| `uv-tcp-peer-address` | `(values address-string-or-#f port)` for the remote end. `uv_tcp_getpeername` |

`uv-write!`, `uv-shutdown!`, `uv-read-start!` and `uv-read-stop!` moved to
`(libuv stream)` in v0.3 (below); `(libuv tcp)` re-exports all four
unchanged, so existing importers compile without touching an import line.

## Streams — `(libuv stream)`

Extracted from `(libuv tcp)` in v0.3 (design spec §4.6) so the gating
predicate is stream-*kind*, not tcp-kind: these verbs accept any open tcp or
pipe handle.

| Export | |
|---|---|
| `uv-write!` | Write a bytevector or a span of one. The payload is copied during the call, at `memcpy` speed. On a threaded Chez, the whole call holds off other threads' garbage collections: the copy, and libuv's `uv_write`, which on an idle socket hands the kernel as much as it will take before returning. On macOS loopback that was 0.2 to 0.9 ms for 1 MiB and 2.4 to 4.4 ms for 4 MiB. That matters only for single writes of a MiB or more |
| `uv-write*!` | Vectored write: one request over a list of segments, each a bytevector or a `(bv start end)` span. All segments are copied into one block and sent as `uv_write` with `nbufs = N`. One completion for the whole write. The list must be non-empty |
| `uv-shutdown!` | Shut the write side down; the read side stays open |
| `uv-read-start!` | Start reading: `on-data` `(bv start end)`, `on-eof` `()`, `on-error` `(condition)`. All three required |
| `uv-read-stop!` | Stop reading — backpressure. Idempotent; the buffer and callbacks are kept for the next start |
| `uv-stream-write-queue-size` | Queued write bytes libuv is holding for this stream. Allocation-free. See Flow control, below |

**Inside an engine.** An engine's fuel can run out anywhere in a stream
verb, and a scheduler may close the stream before resuming it, or never
resume it at all. Each verb makes its checks, its allocation and its native
call in one step that no engine timer interrupts. A verb resumed after its
stream was closed raises `&uv-handle-closed` without touching it. A verb
whose engine is never resumed leaves nothing behind: either it had not
begun, or libuv holds its request and the request's completion frees it.
The other verbs do not promise this yet
([ADR-0019](../.plans/decisions/0019-threading-model-collect-safe-and-per-loop-affinity.md),
decision 3, amended 2026-10-06). Until they do, close a handle only from
the task that is using it, and do not abandon an engine inside a
constructor, `uv-tcp-connect!`, a DNS request or `uv-spawn!`.

## Flow control

v0.5 adds no new libuv subsystem and changes no default: it makes three
per-connection memory surfaces visible and adjustable, and gives write
callers the one congestion signal they cannot derive themselves. At high
connection counts these surfaces are the difference between a server whose
memory is legible and one that grows silently.

**Three buffers share confusable names.** Setting `SO_RCVBUF` does not
resize the chez-libuv read buffer, or vice versa — they are three
independent quantities:

| Buffer | Set by | Freed by | Typical scale |
|---|---|---|---|
| chez-libuv read buffer | first `uv-read-start!`, irreversibly | close dispatcher | 64 KiB default |
| OS send buffer | `uv-send-buffer-size!` | kernel, at socket close | tens of KB, tunable |
| OS receive buffer | `uv-recv-buffer-size!` | kernel, at socket close | a *ceiling*, autotuned; what the kernel charges depends on whether you read |

**A setter's argument is a request to the kernel, not an assignment.**
`uv-send-buffer-size!` and `uv-recv-buffer-size!` wrap `setsockopt`, and the
kernel is free to round the value they ask for. On Linux, `setsockopt`
doubles the requested size and floors it at `SOCK_MIN_SNDBUF`/
`SOCK_MIN_RCVBUF` (i.e. it stores `max(2n, SOCK_MIN_*BUF)`), then clamps the
result to the `net.core.wmem_max`/`net.core.rmem_max` sysctls — so
`(uv-send-buffer-size! h 262144)` followed immediately by
`(uv-send-buffer-size h)` can answer `425984`, not `262144`. That is not a
broken binding: read the getter's return as the kernel's answer, not as
confirmation that the requested number took effect.

**`SO_RCVBUF` is a ceiling, not memory the kernel has charged — and the
difference is most of the story.** Measured on Debian bookworm (aarch64,
libuv 1.52.1) with `spike/flow/13-rcvbuf-cost.ss`; figures are that host's,
the shape is structural:

| Per connection | Bytes | vs the 64 KiB read buffer |
|---|---|---|
| `SO_RCVBUF` as reported | 131072 | 2× — the ceiling |
| Kernel memory charged, connections **idle** | ~11–15 KiB | ~0.2× — five times *smaller* |
| Kernel memory charged, data pushed and **never read** | ~530 KiB | ~8× — and unbounded in principle |

So the receive buffer is **not** a fixed per-connection tax that outweighs
the read buffer. It is close to free at rest, and becomes the dominant cost
exactly when the application has stopped reading. The variable that decides
which regime you are in is backpressure discipline, not connection count —
see `uv-read-stop!` and `uv-stream-write-queue-size` below.

**The chez-libuv read buffer is the opposite shape**, and at rest it is the
larger of the two by roughly 5×: 65536 bytes of resident foreign memory
committed the moment `uv-read-start!` runs, whether or not a byte ever
arrives, and not reclaimed until close.

`tcp_rmem[1]` was 131072 on the measured host. A commonly cited 87 KB is the
older default; both are sysctl-tunable, so measure on the target kernel
rather than trusting either. Full method, honest limits, and the reason this
was measured after the fact rather than before are in
[`spike/flow/FINDINGS.md`](../spike/flow/FINDINGS.md).

**The read-buffer sizing contract is a tradeoff, not a recommendation.**
The buffer is allocated by the first `uv-read-start!` and freed only by the
close dispatcher; its size is fixed by that first call, irreversibly — a
later call with a differing explicit size raises `'buffer-size-fixed`, and a
call that omits the size is always accepted, which is what makes
`uv-read-stop!` → `uv-read-start!` the cheap operation read-side
backpressure needs. 64 KiB is libuv's own suggestion and the current default.

The tradeoff has now been measured (`spike/flow/14-readbuf-default.ss`,
Debian bookworm/aarch64; full method and limits in
[`spike/flow/FINDINGS.md`](../spike/flow/FINDINGS.md)), and it is more
one-sided than it looks.

**Memory scales linearly and is the term that clearly differentiates.** The
buffer is committed at the first `uv-read-start!` whether or not a byte ever
arrives:

| buffer | 200 connections | extrapolated to 10,000 |
|---|---|---|
| 4096 | ~1.2 MiB | ~40 MiB |
| 16384 | ~3.1 MiB | ~160 MiB |
| 65536 | ~12.4 MiB | ~625 MiB |

**The costs on the other side are small.** Moving 16 MiB through one
socket, a 4 KiB buffer produced 16× as many `on-data` deliveries as a 64 KiB
one, exactly as expected. Garbage collection stayed at two or three
collections at every size, each sub-millisecond.

The first measurement found no throughput difference either, but about 97%
of its CPU time was byte-at-a-time copying, which cost the same at every
size and hid the difference. Issue #35 replaced that copying with `memcpy`.
Measured again after #35 (drain time only, same image), 16 MiB drained in a
median 13.6 / 10.0 / 8.6 ms at 4096 / 16384 / 65536. So a 4 KiB buffer takes
about 1.6× as long as 64 KiB, roughly 1.3 µs per extra delivery.

Note also that *total bytes* allocated cannot vary with buffer size: each
delivery allocates exactly `nread` bytes, so a given transfer produces the
same volume of bytevectors however it is chunked. Only the object count
changes.

**Two limits worth knowing before you act on this.** The measurement
discarded every delivery, and a copying collector charges for what
*survives* — a consumer that **retains** deliveries, as any protocol
reassembler holding fragments across reads does, was not measured and is
where an object-count cost would first appear. And the buffer only governs
delivery size for reads that fill it: under small-message traffic the
delivery size is set by what arrives, so the buffer does not affect object
count at all.

**In practice.** Many connections carrying small messages — the case this
milestone was built for — is where a smaller buffer is close to free and the
saving is linear; 4096 or 16384 are reasonable there. Bulk transfer keeps
64 KiB, where the memory is amortised over far fewer connections and where
the per-delivery time above shows. If you retain deliveries across reads,
treat the object-count question as open.

This still is not a change to the default: v0.5 pinned 65536 with a test
rather than moving it, so that a later milestone can move it deliberately
and with its own decision record.

**The read-stop/read-start pairing invariant.** `uv-read-stop!` goes through
the same open-handle gate as every other stream verb, while `read-dispatch`
deliberately tolerates a `'closing` handle for a delivery already in flight.
A stop issued from inside `on-data` for a delivery that raced a close
therefore *raises* rather than succeeding as a no-op. Guard it:

```scheme
(when (uv-handle-open? stream)
  (uv-read-stop! stream))
```

**Bounding write memory.** Each `uv-write!` allocates one foreign block
sized for its request plus its payload — a **zero-length write allocates a
full request block while contributing zero payload bytes** — so payload
bytes alone are not a memory bound and request count alone is not either.
A `uv-write*!` is the same for accounting: **one** request block and one
completion, whose payload is the sum of its segments' spans. A consumer
that wants a deterministic bound tracks both:

- **outstanding payload bytes**, and
- **outstanding request count**,

incrementing each **only after `uv-write!` returns successfully** — a
synchronous failure raises and produces no completion callback, so nothing
was actually queued — and decrementing both from the matching
`on-complete`.

**The write-queue gauge's contract, stated portably.** `uv-stream-write-queue-size`
is libuv's own platform-dependent counter, not this binding's:

- **Unix** counts bytes not yet handed to the kernel, and deliberately
  leaves the count non-zero after a *failed* write, so the caller stops
  writing instead of retrying blind.
- **Windows** counts the opposite direction: it increments only when the
  kernel has *accepted* an overlapped send that has not yet completed: the
  immediate-completion path never increments it at all.

Treat it as **a congestion signal, not a memory gauge, and not a portable
measure of kernel occupancy** — thresholds need platform- and
workload-specific calibration. Callback status remains the authoritative
answer to "is this stream healthy"; the payload-byte and request-count
bounds above are what actually bound memory, with this gauge supplemental
to them.

## Pipes — `(libuv pipe)`

Deliberately minimal (design spec §1): no `bind`/`connect`/`listen`, no
`ipc=1` fd-passing. A fresh pipe's only purpose is to be named in
`uv-spawn!`'s `stdio` options as a child's stdio end, or closed.

| Export | |
|---|---|
| `make-uv-pipe` | A new, unconnected pipe handle on a loop (`uv_pipe_init`, ipc always 0) |
| `uv-pipe?` | Type predicate (defined in `(libuv handle)`) |

## Child processes — `(libuv process)`

| Export | |
|---|---|
| `uv-spawn!` | `(loop file args [options] on-exit)` → process handle, child already running |
| `uv-process-kill!` | Send a signal to the process by handle — `uv_process_kill` |
| `uv-kill!` | Send a signal by raw pid — `uv_kill` |
| `uv-process-pid` | The pid; valid from spawn through close, including after exit |
| `uv-os-getpid` | This process's own pid |
| `uv-process?` | Type predicate (defined in `(libuv handle)`) |

`file`/`args` are libuv's own execvp/argv contract — unresolved and
unvalidated by the binding. The `options` alist covers `env` (a list of
`"K=V"` strings, libuv's own format, not an alist encoding), `cwd`,
`stdio`, `detached`, and `uid`/`gid`. Eight behaviours worth knowing before
the design spec (§4–§6):

- **The spawn surface.** Each child fd (index = slot; 0/1/2 are
  stdin/stdout/stderr, libuv pads short lists to three `ignore`s) is one
  of: `ignore` (`/dev/null` for slots 0–2), `(inherit-fd . n)` (a dup of
  parent fd *n*), `(inherit-stream . h)` (a dup of an open tcp or pipe
  handle's fd), or `(pipe p dir)` — `uv-spawn!` creates the pipe pair and
  connects the parent end into *p*, a fresh handle from `make-uv-pipe`.
  *dir* is `to-child`, `from-child`, or `duplex` — named from the
  *parent's* perspective, deliberately not libuv's child-perspective
  `READABLE`/`WRITABLE` flag names, which are libuv's single most
  direction-confusing vocabulary.
- **Exit ≠ close.** `on-exit` firing stops the handle but does not close
  it; the caller still calls `uv-close!` — typically from inside
  `on-exit` — before the handle's memory is reclaimed. Exactly the tcp
  discipline (ADR-0007), applied to a handle instead of a stream.
- **A second `uv-close!` silently discards its callback.** The close path
  guards on the handle being `'open`, so a close issued against a handle
  that is already `'closing` stores nothing and the supplied `on-close`
  never runs — this applies to every handle kind, not just processes. A
  server that deregisters a connection from `on-close` must own *every*
  close initiation for that handle; the protocol for doing that is server-
  layer design, not binding design — see
  [`.plans/chez-http-server-architecture.md`](../.plans/chez-http-server-architecture.md).
- **Killed-by-signal is `(0 sigterm)`, not `(-1 …)`.** `on-exit` receives
  `(exit-status term-signal)` as results, never a condition — there is no
  error argument. `exit-status` is libuv's `WEXITSTATUS` on a normal exit
  and *zero* on a signal death; `term-signal` is `#f` on a normal exit and
  otherwise the signal symbol (or the raw integer, for a signal outside
  the bound set — information is never dropped).
- **Pid validity ends at the exit callback.** The child is reaped by the
  time `on-exit` runs, so a kill or liveness probe (`uv-process-kill!` /
  `uv-kill!` with signal `0`) issued after exit races pid reuse — it will
  usually raise `'ESRCH`, but the binding cannot promise a recycled pid
  won't be signalled instead.
- **The detached pattern.** `detached` maps to `UV_PROCESS_DETACHED`; the
  documented pattern is spawn, then `uv-close!` immediately — the child
  survives the parent and is never reaped by us.
- **A failed `uv-spawn!` cleans up internally; only its pipes need the
  caller's attention.** libuv's spawn-failure path has two different
  correct cleanups depending on how far the child got before failing
  ([ADR-0015](../.plans/decisions/0015-spawn-copy-lifetime-and-failure-path.md));
  the binding picks the right one at runtime, and the caller only ever
  sees the raise. Any pipe named in any of the spawn's stdio specs is
  marked *connected* by the binding even when the spawn raised — libuv
  opens the parent end before it can know whether the exec will succeed —
  so a raising `uv-spawn!` still leaves its pipes needing an explicit
  `uv-close!`; naming an already-consumed pipe again raises
  `'pipe-already-used`.
- **The arguments are read once.** `uv-spawn!` reads `file`, `args` and
  `options`, with every string, list and stdio spec in them, once, early in
  the call and in one step no engine's timer can split. Everything after
  that, the checks included, works from what it read. So if an engine's
  timer handler changes them while the call runs, the child gets them as
  they were before the change or as they were after it, never a mix. A NUL
  that appears in a string during the call is refused, or never reaches the
  child. Another thread changing them during the call races that read, which
  no lock here can order: the child may get part of each version, or the
  call may raise on a list that stopped being one, but the read never takes
  bytes a string did not hold.

**Root lane.** Exercising `uid`/`gid` (which map to
`UV_PROCESS_SETUID`/`SETGID`) needs to actually run as root, so that
coverage is opt-in and kept out of the default suite: `sudo make test-root`
runs `tests/test-process-setuid.sps` alone — excluded from `make test` and
`make test-memory`, and refusing with a clear message under a non-root
euid. CI runs it as its own step on both platforms.

**Coexistence with Chez's own subprocess APIs.** Measured, not assumed:
interleaving libuv spawns with Chez's `system`/`open-process-ports` across
four orderings showed no conflict — 110/110 libuv `exit_cb`s delivered
intact and every Chez call returned its own correct result — measured on
Linux's SIGCHLD-based child-reaping path, the one path where a stolen wait
can silently drop a callback (`spike/process/FINDINGS.md` SQ2).

## Signals — `(libuv signal)`

Completes the pair the process module's `uv-kill!` started
([ADR-0017](../.plans/decisions/0017-signal-watching-vocabulary-and-mode.md)).

| Export | |
|---|---|
| `make-uv-signal` | A new signal watcher on a loop |
| `uv-signal-start!` | Watch continuously: `(watcher signal-symbol on-signal)`; the callback receives the signal as a symbol |
| `uv-signal-start-oneshot!` | Watch for exactly one delivery, then auto-disarm |
| `uv-signal-stop!` | Disarm the watcher |
| `uv-signal?` | Type predicate (defined in `(libuv handle)`) |

The watchable set is the closed vocabulary minus `sigkill`/`sigstop`
(`'signal-unwatchable` — the kernel forbids catching them); exact `0` stays
sending-only. A watcher's *mode* is fixed by its first start verb, and the
other verb thereafter raises `'signal-mode-fixed`; changing mode is
`uv-close!` + `make-uv-signal` (the vendored `UV_SIGNAL_ONE_SHOT` flag is a
one-way per-handle ratchet, measured in
[the v0.4 spike](../spike/signal/FINDINGS.md)). Delivery is not close: the
caller always `uv-close!`s the handle.

Graceful shutdown, the driving use case — first `SIGTERM` drains, a second
one kills (the disposition reverts to `SIG_DFL` once the oneshot fires):

```scheme
(define loop (make-uv-loop))
(define watcher (make-uv-signal loop))
(uv-signal-start-oneshot! watcher 'sigterm
  (lambda (sig)
    ;; close the listener, start the drain timer, then:
    (uv-close! watcher)))
(uv-run loop 'default)
```

**Measured caveat** (both platforms,
[FINDINGS](../spike/signal/FINDINGS.md) SQ-S1): watching `sigint` takes
SIGINT away from the Chez runtime — while the watcher is armed, Ctrl-C is
delivered to the loop callback and Chez's keyboard interrupt never fires;
after `uv-signal-stop!` (or oneshot auto-disarm) the disposition is
*SIG_DFL*, not what was there before, so SIGINT then terminates the
process. This applies equally to handlers installed with Chez's
`register-signal-handler`. It is libuv's behavior
(`uv__signal_unregister_handler`), surfaced rather than fixed. Rearming a
oneshot watcher from inside its own callback does not take effect (the
vendor auto-stop runs after the callback returns) — rearm from a later
dispatch.

## DNS — `(libuv dns)`

The scope is deliberate: whatever the host's resolver does, asynchronously —
no c-ares, no record types, no caching.

| Export | |
|---|---|
| `uv-getaddrinfo!` | Resolve: `(loop node service [hints] on-complete)`; `on-complete` gets `(err results)`, `results` a fresh list of `uv-addrinfo` records in resolver order |
| `uv-getnameinfo!` | Reverse: `(loop ip port [flags] on-complete)`; `on-complete` gets `(err host service)`, both strings on success, both `#f` on failure |
| `uv-cancel!` | Best-effort cancel. `#t` only if the work was still queued — the callback still fires, with `'EAI_CANCELED`; `#f` means too late, the real result is (or was) delivered |
| `uv-dns-request?` | Whether this is a request `uv-cancel!` accepts |
| `make-uv-addrinfo` | Public constructor — the record is pure data, and a caller's test double is legitimate |
| `uv-addrinfo?` | Type predicate |
| `uv-addrinfo-family` | `'inet` \| `'inet6`. Other families are skipped during the chain walk, so a success can answer `'()` |
| `uv-addrinfo-socktype` | `'stream` \| `'dgram` \| `'raw`, or the raw int when unmapped |
| `uv-addrinfo-protocol` | `'tcp` \| `'udp`, or the raw int (0 = unspecified) |
| `uv-addrinfo-address` | Presentation string, rendered by libuv's own formatter |
| `uv-addrinfo-port` | Exact integer 0..65535 |
| `uv-addrinfo-canonname` | `#f` except on the first entry under the `canonname` flag |

`hints` is an alist over closed symbol sets — `'((family . inet6)
(socktype . stream) (protocol . tcp) (flags . (canonname numeric-host)))` —
and errors reach the callback as ordinary `&uv-errno-error` conditions whose
`errno` is the `EAI_*` symbol (`'EAI_NONAME`, `'EAI_AGAIN`,
`'EAI_CANCELED`, …); there are no DNS-specific condition types. Five
behaviours worth knowing before the design spec:

- **This is the binding's first threadpool-backed feature.** The resolver
  calls run on libuv's worker threads — pure C; no Scheme ever runs off the
  loop thread — and completions are delivered on the loop thread like every
  other callback. The pool is sized by `UV_THREADPOOL_SIZE`, which libuv
  reads once, at first use.
- **Omitted, `#f` and `'()` hints all mean NULL hints** — the platform's
  own documented default, which typically answers one entry per (address ×
  socktype): `stream`, `dgram`, and on Linux `raw` too.
  `'((socktype . stream))` is the one-liner for one entry per address.
- **IPv6 scope IDs are dropped**
  ([ADR-0012](../.plans/decisions/0012-address-vocabulary.md)): a
  link-local result renders as `"fe80::1"` with its zone silently absent.
- **Teardown cancels, then drains.** `uv-loop-teardown!` best-effort-cancels
  the loop's in-flight DNS requests before its close sweep, and every
  in-flight `on-complete` runs before teardown returns — with
  `'EAI_CANCELED` if the cancel won, with the real result if the work was
  already running. A `getaddrinfo(3)` already running in a worker cannot be
  interrupted, so that drain iteration waits it out, up to the OS
  resolver's own timeout.
- **`uv-loop-close!` delivers a pending callback error** (a v0.2 behaviour
  change, not DNS-specific): after a successful close it re-raises a stored
  pending callback error composed as `&uv-callback-error`, exactly as
  `uv-run`'s exit does — previously a caller who skipped the next `uv-run`
  and went straight to close lost the error silently. The loop is closed
  when the raise escapes; a close refused with `'EBUSY` still delivers
  nothing, and the error stays pending.

## Timers — `(libuv timer)`

| Export | |
|---|---|
| `make-uv-timer` | A new timer on a loop |
| `uv-timer-start!` | Arm it: `(timer on-timeout timeout-ms repeat-ms)`; `on-timeout` receives the timer record itself. The timeout counts from the loop's cached `uv-now`, not the wall clock: after a callback that held the loop, call `uv-update-time!` first or the timer is due early |
| `uv-timer-stop!` | Disarm it |
| `uv-timer-again!` | Restart a repeating timer |
| `uv-timer-repeat` `uv-timer-set-repeat!` | Read and set the repeat interval |

## Async — `(libuv async)`

libuv's one cross-thread wakeup, and the way a worker thread hands work back
to the loop thread. `uv-async-send!` is the one exception to the thread rule
under [the loop](#the-loop--libuv-loop), above.

| Export | |
|---|---|
| `make-uv-async` | A new async handle on a loop: `(loop on-wake)`. Loop thread only: `&uv-wrong-thread` from any other. `on-wake` runs on the loop thread and receives the async handle itself |
| `uv-async-send!` | Wake the loop so it runs `on-wake`. Callable from **any** thread: `uv_async_send` is libuv's one thread-safe call, and this is the one verb exempt from the thread rule. Sends coalesce — N sends may yield one `on-wake` — so `on-wake` should drain a queue of your own, and tolerate finding it empty, rather than assume one item per send |
| `uv-async?` | Type predicate (defined in `(libuv handle)`) |

Three behaviours worth knowing before the
[threading design](../.plans/2026-09-19-chez-libuv-threading-design.md) (§6):

- **An open async keeps the loop alive.** Like any active handle it keeps
  `uv-run 'default` from returning (short of `uv-stop!`), and there is no
  `uv_unref` binding to exempt it (the design's §12 defers one), so close the
  async to let the loop finish.
- **A send that races the close is refused.** Each async handle has a lock
  that `uv-async-send!` and `uv-close!` both take, so a send from any thread
  either completes before a close begins or raises `&uv-handle-closed`
  without touching the handle. That holds when the close frees the handle a
  moment later, and when either runs inside an engine. The lock is held only
  around one native call, with interrupts disabled, so no engine is ever
  suspended holding it and no collection ever waits on it. A send may
  therefore be made with interrupts disabled, or from a collect-request
  handler. Sends to one handle from several threads take turns on its lock.
  `uv-close!` itself still runs on the loop thread only.
- **A close drops wakes still pending.** `on-wake` never runs once
  `uv-close!` has started, even for a send made before it, so after closing,
  drain the queue once more yourself. A refusal tells a sender only that its
  wake was not sent. To know which items will be handled, queue and send
  only while holding a mutex of your own and seeing an open flag, and have
  the loop thread clear the flag under that mutex before it closes. Then the
  final drain handles every item queued, and a sender that sees the flag
  clear knows its item was not queued.

## Versions — `(libuv)`

| Export | |
|---|---|
| `uv-version` | The running libuv's version *string*, e.g. `"1.52.1"` |
| `uv-version-compatible?` | Whether compile-time and runtime libuv both fall in the supported range |

## Conditions — all re-exported from `(libuv)`

Every condition type comes with its predicate, its constructor and its field
accessors; the constructors are public because a caller's own `on-error` may
want to build or re-raise one
([ADR-0006](../.plans/decisions/0006-error-codes-are-symbols.md) is why the
discriminant is a symbol).

| Condition | Fields | Raised when |
|---|---|---|
| `&uv-error` | — | The root; everything below derives from it |
| `&uv-errno-error` | `errno` `code` `message` | libuv returned a negative code. `errno` is the portable symbol (`'ECONNRESET`) and the thing to branch on; `code` is the raw platform int, for logs |
| `&uv-handle-closed` | `kind` | An operation on a handle or loop that is already closed |
| `&uv-shim-unavailable` | `path` | The shim could not be found or loaded at `path` |
| `&uv-libuv-unavailable` | `path` (inherited) | libuv's own shared object could not be found or loaded — a subtype of `&uv-shim-unavailable`, so guards on the parent keep matching; the sharper predicate is `uv-libuv-unavailable?` |
| `&uv-version-incompatible` | `compiled` `runtime` | Either libuv version is outside the supported range |
| `&uv-constant-unavailable` | `name` | The shim has no constant under that name |
| `&uv-invalid-argument` | `who` `reason` | A caller error, refused before anything was allocated |
| `&uv-callback-error` | `cause` | A callback raised; composed with the original condition |
| `&uv-wrong-thread` | `who` `expected` `actual` | A verb ran off its loop's owning thread; `expected` is the owner's thread id, `actual` the caller's ([ADR-0019](../.plans/decisions/0019-threading-model-collect-safe-and-per-loop-affinity.md)) |

v0.3, v0.4, v0.5 and v0.7 added no new condition types, and v0.6 added one — every
`(libuv process)`/`(libuv pipe)`/`(libuv stream)`/`(libuv signal)`/`(libuv
handle)`/`(libuv async)` failure raises one of the three above
(`&uv-errno-error`, `&uv-handle-closed`, `&uv-invalid-argument`), or
`&uv-wrong-thread` off the loop's thread; the closed set of
`&uv-invalid-argument` reason symbols (`'stdio-spec-unknown`,
`'pipe-already-used`, `'signal-unknown`, `'signal-unwatchable`,
`'signal-mode-fixed`, `'buffer-size-fixed`, `'buffer-size-out-of-range`
(reused from `uv-read-start!`, not new to v0.5), `'not-a-socket-handle`
(the one reason symbol v0.5 actually adds),
`'sockaddr-too-small-for-a-port`, and the rest of the validation walk) is
in the per-milestone design specs (v0.3 §4.7; v0.4 §4.2/§4.6; v0.5 §4.2),
not repeated here.
