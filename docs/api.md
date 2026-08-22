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
| `uv-now` | libuv's cached "now", in ms, updated once per iteration |
| `uv-loop-live-handles` | Fresh list of the handle records registered on this loop |
| `uv-loop-deferred-errors` | Everything callbacks raised this run *after* the first |
| `uv-loop-close!` | Close the loop. `'EBUSY` while handles are still open |
| `uv-loop-teardown!` | Close every handle, drain, then close the loop |
| `call-with-uv-loop` | The above as a scope; tears down on every exit path |

## Handles — `(libuv handle)`

| Export | |
|---|---|
| `uv-handle?` `uv-timer?` `uv-tcp?` `uv-pipe?` `uv-process?` `uv-signal?` | Type predicates |
| `uv-handle-open?` `uv-handle-closing?` | State predicates. Never raise, on anything |
| `uv-handle-state` | `'open` \| `'closing` \| `'closed`. There is no `uv-handle-closed?` — that name is the condition predicate |
| `uv-handle-loop` | The owning loop; answers for a closed handle too |
| `uv-close!` | Start the close, optionally with an `on-close` callback. Idempotent |

## TCP — `(libuv tcp)`

| Export | |
|---|---|
| `make-uv-tcp` | A new TCP handle on a loop |
| `uv-tcp-bind!` | Bind to an address and port; IPv4 or IPv6 literal |
| `uv-tcp-getsockname-port` | The real port the kernel chose, for a bind to port 0 |
| `uv-listen!` | Listen; `on-connection` is called with the error or `#f` |
| `uv-accept!` | A new open handle for the queued connection |
| `uv-tcp-connect!` | Connect; answers the in-flight request record |
| `uv-tcp-nodelay!` | `TCP_NODELAY`. Takes a boolean, not an int |

`uv-write!`, `uv-shutdown!`, `uv-read-start!` and `uv-read-stop!` moved to
`(libuv stream)` in v0.3 (below); `(libuv tcp)` re-exports all four
unchanged, so existing importers compile without touching an import line.

## Streams — `(libuv stream)`

Extracted from `(libuv tcp)` in v0.3 (design spec §4.6) so the gating
predicate is stream-*kind*, not tcp-kind: these four verbs accept any open
tcp or pipe handle.

| Export | |
|---|---|
| `uv-write!` | Write a bytevector or a span of one. The payload is copied |
| `uv-shutdown!` | Shut the write side down; the read side stays open |
| `uv-read-start!` | Start reading: `on-data` `(bv start end)`, `on-eof` `()`, `on-error` `(condition)`. All three required |
| `uv-read-stop!` | Stop reading — backpressure. Idempotent; the buffer and callbacks are kept for the next start |

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
`stdio`, `detached`, and `uid`/`gid`. Six behaviours worth knowing before
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
| `uv-timer-start!` | Arm it: `(timer on-timeout timeout-ms repeat-ms)`; `on-timeout` receives the timer record itself |
| `uv-timer-stop!` | Disarm it |
| `uv-timer-again!` | Restart a repeating timer |
| `uv-timer-repeat` `uv-timer-set-repeat!` | Read and set the repeat interval |

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

v0.3 and v0.4 added no new condition types — every
`(libuv process)`/`(libuv pipe)`/`(libuv stream)`/`(libuv signal)` failure
raises one of the three above (`&uv-errno-error`, `&uv-handle-closed`,
`&uv-invalid-argument`); the closed set of `&uv-invalid-argument` reason
symbols (`'stdio-spec-unknown`, `'pipe-already-used`, `'signal-unknown`,
`'signal-unwatchable`, `'signal-mode-fixed`, and the rest of the validation
walk) is in the design specs' §4.7, not repeated here.
