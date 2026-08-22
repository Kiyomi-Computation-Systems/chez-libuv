# Design Spec: chez-libuv v0.4 — Signal

Status: **Draft** (pending adversarial review, then the stage-0 spike)
Date: 2026-08-22
Branch: `feat/v0.4-signal`

v0.4 adds in-loop signal *watching* — `uv_signal_t` — completing the pair v0.3
deliberately left half-finished: `(libuv process)` shipped signal **sending**
(`uv-process-kill!`, `uv-kill!`); this milestone ships signal **receiving**.
The deferral was recorded in the v0.3 spec's non-goals
(2026-08-21-chez-libuv-v0.3-process-design.md:41-44) and deferred list (:869),
where `uv_signal_t` is the one item flagged "explicitly requested as a
next-milestone note".

Driving use case: graceful shutdown. A server traps SIGTERM/SIGINT on the loop
thread, closes its listener, drains in-flight work under a deadline timer, and
tears down — the shape the chez-http-server architecture doc requires as an
end-to-end test (`.plans/chez-http-server-architecture.md:718`) and the shape
12-factor deployment (systemd/Docker/Kubernetes SIGTERM-then-SIGKILL) demands.
With both halves bound, a master/worker topology is expressible entirely inside
the binding: the master `uv-kill!`s workers; workers watch and drain.

## 1. Goal and non-goals

**Goal.** A `(libuv signal)` library binding `uv_signal_init`,
`uv_signal_start`, `uv_signal_start_oneshot`, and `uv_signal_stop`, following
the established handle protocol (ADR-0007) and trampoline discipline
(ADR-0008), plus the small additions the milestone forces: the
`signal-symbol->int` / `term-signal->value` lift into `(libuv private native)`
(the second-user rule, recorded at process.sls:530-531) and a raw
`uv_os_getpid` binding (`uv-os-getpid`, exported from `(libuv process)`).

**Non-goals.**

- **No new signal names.** The vocabulary stays ADR-0016's closed nine-symbol
  set. `sigwinch`, `sigpipe`, and `sigchld` stay out; adding one later is one
  shim row plus one case arm (ADR-0016:146-148). `sigchld` in particular stays
  *inexpressible by design*: libuv owns SIGCHLD for child reaping on Linux
  (vendor fact V6, v0.3 spec §V6), and a vocabulary that cannot name it cannot
  break it.
- **No `uv_ref`/`uv_unref`.** Still deferred. A shutdown watcher is closed
  during the shutdown it triggers, so loop-liveness control is not needed for
  the driving use case.
- **No process-wide signal *masking*** (`sigprocmask` and friends) and no
  `SA_*` flag surface. libuv's model — dispositions installed and multiplexed
  by libuv, callbacks delivered on the loop thread via `uv_run` — is the model.
- **No Windows flags or emulation notes** (ADR-0004: Windows deferred, not
  designed out).
- **No armed-state field on the record.** libuv is the source of truth for
  whether a watcher is active (oneshot auto-disarms behind our back);
  mirroring that state in Scheme invites drift. Consequence: there is no
  `uv-signal-watching?` predicate in v0.4.

## 2. Decisions summary

| # | Decision | Where recorded |
|---|----------|----------------|
| D1 | Watchable subset: the ADR-0016 nine minus `sigkill`/`sigstop`, which raise `&uv-invalid-argument` reason `'signal-unwatchable` before any native call | new ADR (§10), this spec §4.2 |
| D2 | Both continuous and oneshot start verbs; same callback type, same trampoline | §4.2 |
| D3 | Callback payload is the signal symbol, converted via `term-signal->value` | §4.3 |
| D4 | Thirteenth trampoline `signal`; second amendment to ADR-0008 | §5.2 |
| D5 | Dispatcher late-installed from `(libuv signal)`'s library body (DNS/process pattern) | §5.3 |
| D6 | `signal-symbol->int` and `term-signal->value` lift to `(libuv private native)` | §5.4 |
| D7 | No armed-state tracking on the record | §1 non-goals, §4.4 |
| D8 | `uv-os-getpid` bound raw, exported from `(libuv process)` beside `uv-process-pid` | §4.5 |
| D9 | DELIVERY ≠ CLOSE: stop (explicit or oneshot auto-stop) never closes; the caller always `uv-close!`s (the EXIT ≠ CLOSE analog, ADR-0007/0016) | §6 |

## 3. Module layout (delta)

New:

- `src/libuv/signal.sls` — `(library (libuv signal))`: constructor, start/stop
  verbs, dispatcher installation. Timer-sized.
- `tests/test-signal.sps` — auto-discovered by the `TESTS` wildcard; joins the
  memory gate via `MEMORY_TESTS := $(TESTS)`. No Makefile edits.

Modified:

- `src/libuv-shim.c` / `.h` — constant row `UV_SIGNAL`; debug-counter triple
  `chez_uv_count_signal_new/free` + `chez_uv_live_signal` in **both** the
  `CHEZ_LIBUV_DEBUG_COUNTERS` branch and the no-op branch; header prototypes.
  Constants only — ADR-0002 holds; no uv_* call is wrapped.
- `src/libuv/private/constants.sls` — `(uv-signal-type)` accessor + export.
- `src/libuv/private/native.sls` — thirteenth trampoline; raw
  `uv_signal_init`/`uv_signal_stop`/`uv_os_getpid`; wrappers
  `uv-signal-start-native`/`uv-signal-start-oneshot-native`; `'signal`
  appended to `dispatcher-names`; counter bindings joined to `live-counts`;
  receives the lifted `signal-symbol->int`/`term-signal->value`.
- `src/libuv/private/handles.sls` — `uv-signal-record`; `'signal` joins
  `handle-kinds` (handles.sls:478 — mandatory, or the teardown sweep never
  closes signal handles); a `(signal)` arm in `count-handle-free!`.
- `src/libuv/handle.sls` — public `uv-signal?` beside `uv-pipe?`.
- `src/libuv/process.sls` — imports the lifted validators back (behavior
  unchanged); exports `uv-os-getpid`.
- `src/libuv.sls` — facade imports `(libuv signal)`; exports added by name.
- `tests/test-loop.sps`, `tests/test-native.sps` — the frozen twelve-name
  literals grow to thirteen (the deliberate friction ADR-0008 designed in).
- `tests/test-lifecycle.sps` — signal counter-balance scenarios.
- `README.org`, `CHANGELOG.md` — status/notes (§11).

## 4. Public API

### 4.1 `make-uv-signal`

```scheme
(make-uv-signal loop) → uv-signal record
```

The `make-uv-timer` shape verbatim (timer.sls:41-51): `ensure-native-loaded!`,
`require-open-loop`, `alloc-zeroed` sized by `uv_handle_size(UV_SIGNAL)`
(ADR-0005 — no transcribed sizes), `uv_signal_init` under a guard that `free!`s
the block on failure, `%make-uv-signal-record`, `registry-register!` under kind
`'signal`, `count-signal-new!`. Public libraries never take or return pointers.

### 4.2 `uv-signal-start!`, `uv-signal-start-oneshot!`, `uv-signal-stop!`

```scheme
(uv-signal-start! sig watch-symbol on-signal)          → unspecified
(uv-signal-start-oneshot! sig watch-symbol on-signal)  → unspecified
(uv-signal-stop! sig)                                  → unspecified
```

Validation, in order, before the first native call (house rule): record kind
(`uv-signal?`), handle state `'open`, `on-signal` a procedure, `watch-symbol`
in the **watchable set**:

```
sigterm sigint sighup sigquit sigusr1 sigusr2 sigcont
```

Two named refusals, both `&uv-invalid-argument`:

- `'signal-unknown` — anything outside the ADR-0016 vocabulary, including raw
  integers (`15` is refused even though it is SIGTERM everywhere — same rule
  as `uv-kill!`). Note the sending set's exact-`0` liveness probe is *sending*
  vocabulary only; `0` is `'signal-unknown` here.
- `'signal-unwatchable` — `sigkill` and `sigstop`: valid vocabulary, in the
  sending set, but the kernel forbids catching them. Refusing at the boundary
  names the real constraint; letting libuv answer EINVAL would name the
  syscall instead.

The callback is stored on the record **before** arming (timer discipline,
timer.sls:64-80); rcs route through `uv-check` with `who` = the public verb.

Semantics:

- **Continuous** (`uv-signal-start!`): fires `on-signal` on every delivery
  until stopped or closed.
- **Oneshot** (`uv-signal-start-oneshot!`): fires exactly once; libuv disarms
  the watcher itself. Same `uv_signal_cb` type — no extra trampoline. Once no
  watcher remains for a signum, the disposition reverts (expected: `SIG_DFL`,
  EV-3 — *not* the pre-libuv handler), which yields the classic shutdown UX:
  first SIGTERM drains gracefully, a second one kills.
- **Rearm**: calling a start verb on an already-watching handle rearms it,
  possibly with a different signal and/or callback. Contract fixed here;
  whether the wrapper can rely on the vendor to stop-then-start or must issue
  an explicit `uv_signal_stop` first is decided by EV-1.
- **Stop** is idempotent: stopping a never-started or already-stopped (incl.
  oneshot-fired) watcher succeeds (expected rc 0, EV-2). Re-arming after any
  stop is allowed.

### 4.3 The callback contract

```scheme
(on-signal sig)   ; sig = the signal symbol, e.g. 'sigterm
```

- `sig` arrives via the `term-signal->value` reverse map (ADR-0016: bound
  signal → symbol, unbound → raw integer, never dropped, never fabricated).
  Because start validated the symbol, `sig` is in practice always the watched
  symbol — the map is used for uniformity, not necessity.
- Delivering the symbol lets one handler serve several watchers (`sigterm` +
  `sigint` sharing one shutdown routine).
- Fires only on `'open` handles (timer discipline); runs under
  `dispatch-guarded` — store-and-reraise policy unchanged (first raise stops
  the loop, `uv-run` re-raises; ADR-0010 discipline).
- Delivery arrives through `uv_run` on the loop thread like every other
  dispatcher: libuv internalizes the async-signal-safe half, so **no Scheme
  code ever runs in signal-handler context**. Consequence: the recorded
  `__collect_safe` × re-entry open question (spike/FINDINGS.md:925-927) is not
  newly triggered by this milestone. SQ-S1's behavioral leg confirms this in
  passing.

### 4.4 No armed-state tracking

The record carries `on-signal` and nothing else beyond the parent fields.
Oneshot auto-disarm happens inside libuv; a Scheme-side `watching?` flag would
have to be maintained from the dispatcher and would still race libuv's own
view. Callers who need to know arm state track it themselves. (Direct
consequence: tests observe arm state behaviorally — deliveries counted — never
structurally.)

### 4.5 `uv-os-getpid`

```scheme
(uv-os-getpid) → exact integer
```

Raw nullary binding in native.sls, exported from `(libuv process)` beside
`uv-process-pid` (pid vocabulary lives there). Needed by the suite
(self-delivery: `uv-kill!` to own pid inside the loop) and genuinely useful
public surface. No callback, no allocation, no failure mode worth modeling
(libuv returns the pid directly).

### 4.6 Facade and conditions

Facade exports by name (house rule libuv.sls:14-17): `make-uv-signal`,
`uv-signal-start!`, `uv-signal-start-oneshot!`, `uv-signal-stop!`,
`uv-signal?`, `uv-os-getpid`. No new condition types; the new reason symbol
`'signal-unwatchable` rides the existing `&uv-invalid-argument`.

## 5. Internals

### 5.1 handles.sls: the signal record

`uv-signal-record`: direct `uv-handle-record` child, one mutable field
`on-signal` — the process-record shape minus `exited?` (handles.sls:383-389 is
the model). `'signal` joins `handle-kinds` and `count-handle-free!` gets its
arm. The close path needs zero changes: signal handles own no buffers, so
`close-dispatch`'s freeing order applies untouched.

### 5.2 native.sls: the trampoline set grows to thirteen

`signal-callable`, signature `(uptr int)` → void (`uv_signal_cb`: handle +
signum). It shares `connection`'s arity but is a distinct callback **type**;
ADR-0008's rule is one locked trampoline per type (native.sls:1013-1026 —
DNS/exit/walk each got their own on the same grounds). `'signal` is appended
to the **end** of `dispatcher-names` (append-only contract,
native.sls:926-934); the callable joins `trampolines-locked`; its entry point
stays module-private, baked into `uv-signal-start-native` and
`uv-signal-start-oneshot-native` (both wrappers bake the same entry — the
`uv-timer-start-native` pattern). `uv_signal_init`, `uv_signal_stop`, and
`uv_os_getpid` are exported raw (no callback arguments). This is ADR-0008's
second amendment (twelve → thirteen).

### 5.3 signal.sls and the late-installed dispatcher

`(libuv signal)`'s library body installs `signal-dispatch` via
`install-dispatch-procedure!` (the DNS/process pattern: dns.sls:540-547,
process.sls:629-640). A process image that never imports `(libuv signal)`
keeps the contained raising stub — loud, not silent. `signal-dispatch` is
timer-shaped: registry lookup with kind check, deliver only to `'open`
handles, convert signum via `term-signal->value`, run `on-signal` under
`dispatch-guarded`. A delivery dequeued for a `'closing` handle is dropped
silently (timer discipline, handles.sls:678-686).

### 5.4 The validator lift

`signal-symbol->int` and `term-signal->value` move from process.sls to
`(libuv private native)`, exactly as the comment at process.sls:530-531
promises ("Lifts to (libuv private native) on its second user (the PR #4
rule)") — the same lift already applied to
`require-address`/`require-port`/`require-callback`. process.sls imports them
back; `(libuv process)`'s exports and behavior are unchanged. On top of the
lifted `signal-symbol->int`, signal.sls layers the watchable-subset check:
sending and watching share the **vocabulary** but not the **refusal policy**
(sending accepts `sigkill`/`sigstop` and exact `0`; watching refuses all
three) — the distinction the new ADR records.

### 5.5 Shim and constants additions

One constant row (`UV_SIGNAL`), one counter triple in both branches, header
prototypes, `(uv-signal-type)` accessor. The nine `SIG*` rows already exist
(libuv-shim.c:148-156); no new signal numbers.

## 6. Stop, close, and teardown semantics

- **DELIVERY ≠ CLOSE.** Neither delivery, `uv-signal-stop!`, nor oneshot
  auto-disarm closes the handle or frees anything. The caller always
  `uv-close!`s; `close-dispatch` remains the only place handle memory dies
  (ADR-0007). A forgotten close leaks deterministically and visibly via the
  debug counters, never GC-swept.
- An **active watcher keeps the loop alive** (active handles are ref'd;
  EV-4). The graceful-shutdown idiom is therefore: `on-signal` closes the
  listener, starts the drain timer, and closes the signal handle itself (or
  used oneshot and closes it in the drain path). Documented in README's usage
  example.
- **Teardown**: `'signal` in `handle-kinds` puts signal handles in
  `uv-loop-teardown!`'s snapshot-then-sweep; the existing drain delivers their
  close callbacks. No teardown code changes.
- **Pending-delivery race**: a signal already accepted by libuv when
  `uv-signal-stop!` runs before the next `uv-run` is expected to be
  suppressed, not delivered (EV-5). The test suite's "no delivery after stop"
  assertion takes the strict or weak form this fact dictates.

## 7. Expected vendor facts (pinned libuv v1.52.1 — to be verified by the spike)

Numbered EV (expected vendor fact) until the spike converts each to a measured
V-fact in `spike/signal/FINDINGS.md`. A surprising answer reshapes this spec
before implementation.

- **EV-1** `uv_signal_start` on an active watcher rearms (stops-then-starts
  internally), including across a signum change. If false: wrappers issue an
  explicit `uv_signal_stop` first; public contract (§4.2) unchanged.
- **EV-2** `uv_signal_stop` on a never-started or auto-disarmed watcher
  returns 0.
- **EV-3** When the last watcher for a signum stops, libuv restores
  **`SIG_DFL`** — *not* the previously installed handler. This is the
  expected reading of `uv__signal_unregister_handler`. Load-bearing for
  SQ-S1: it predicts that watching `sigint` and stopping **does not give Chez
  its keyboard interrupt back**. If confirmed, that is a documented caveat in
  the ADR and README (honest surfacing, the V6 pattern) — not something the
  binding papers over.
- **EV-4** An active signal watcher keeps `uv_run` from returning (default
  ref'd handle).
- **EV-5** A delivery pending at stop time is suppressed for the stopped
  watcher.
- **EV-6** Two watchers on the same signum in one loop both fire on one
  delivery.
- **EV-7** Signal callbacks are delivered from `uv_run` on the loop thread;
  no user code runs in signal-handler context.

## 8. GC and memory invariants (delta)

None new. The registry remains the sole GC root for the open handle and its
`on-signal` closure (ADR-0007); no threadpool involvement, no owned buffers,
no libuv-owned result memory. The valgrind lane needs no new suppressions or
escape hatches. Counter balance (`live-signal` returns to baseline) is the
leak oracle, as for every other kind.

## 9. Testing strategy (delta)

### 9.1 Harness rules (unchanged, restated as obligations)

Iteration-capped `run-until` waits only, never wall-clock; sentinels never
`#f`/`0`; `(collect)` in every callback; assert on observed deliveries, never
on which loop iteration delivered them.

### 9.2 Self-delivery harness

`(uv-kill! (uv-os-getpid) 'sigusr1)` from inside the loop. Only `sigusr1`/
`sigusr2` are self-delivered while testing delivery mechanics — benign names,
and while a watcher is armed the default disposition is replaced anyway. The
suite never self-sends a fatal signal without an armed watcher for it.

### 9.3 test-signal.sps scenarios

- Delivery: correct symbol delivered; continuous watcher fires across
  repeated sends; distinct watchers (sigusr1/sigusr2) route to the right
  callbacks; two watchers on one signum both fire (EV-6).
- Oneshot: exactly one delivery across repeated sends; stop-after-fire rc 0
  (EV-2); rearm-after-fire works.
- Rearm: start! on an active watcher with a new signum/callback — old signum
  no longer delivered, new one is (EV-1).
- Stop: stop-then-send asserts the EV-5 form; stop idempotence.
- Refusals: `sigkill`/`sigstop` → `'signal-unwatchable`; `0`, `15`, `'sigfoo`
  → `'signal-unknown`; verbs on closed handles → state conditions; wrong-kind
  handle → kind condition.
- Loop liveness: an armed watcher holds `uv-run` (EV-4), closing it releases.
- End-to-end graceful shutdown (the SQ-S2 probe graduated into the suite):
  parent `uv-spawn!`s a child that arms oneshot `sigterm`; parent kills
  twice; asserts graceful-then-killed (`(0 sigterm)` on the second). Dogfoods
  v0.3.
- Lifecycle: close protocol, counter balance to baseline, teardown sweep
  closes an armed watcher (in test-lifecycle.sps).
- Frozen-list edits: test-loop.sps / test-native.sps thirteen-name literals;
  the uninstalled-stub matrix grows a `signal` row.

### 9.4 Memory lane

test-signal.sps joins `make test-memory` automatically. Signal delivery under
valgrind involves no threadpool and no io_uring; both legs run the same code
path. Gate stays definite-only with no new suppressions expected.

## 10. Stage 0 spike (`spike/signal/`, findings in `spike/signal/FINDINGS.md`)

Spike code is throwaway (may include a spike-local C probe to read installed
dispositions via `sigaction`; ADR-0002's constants-only rule binds the shipped
shim, not spike scaffolding). Platforms: Darwin locally + Linux via the
spike-branch CI push pattern (`push: branches: ['spike/**']`, cached pinned
Chez) that served the process spike.

- **SQ-S1 — Chez SIGINT coexistence.** Baseline: what disposition does the
  Chez runtime install for SIGINT in a script (and note REPL differences)?
  Then: arm a `sigint` watcher → structural read of the disposition +
  behavioral self-delivery (expect loop callback, no Chez keyboard
  interrupt); stop → read again (EV-3 predicts `SIG_DFL`, i.e. Chez's
  handling is NOT restored) + behavioral check. Output: the honest caveat
  text for ADR/README, and confirmation that no Scheme code runs in handler
  context (EV-7).
- **SQ-S2 — oneshot end-to-end.** Child arms oneshot `sigterm`; parent sends
  SIGTERM twice. Expect: first delivery runs the handler; second kills with
  `(0 sigterm)` — measuring auto-disarm + disposition reversion together.
  In-process legs: EV-2 rc, rearm-after-fire.
- **SQ-S3 — vendor micro-facts.** EV-1 (rearm/signum switch), EV-4 (loop
  liveness), EV-5 (pending-delivery race — forced with kill-before-run
  orderings; if racy, bounded-retry with discriminating asserts checked every
  attempt, the v0.2 lesson), EV-6 (two watchers, one signum).

ADRs after the spike:

- **ADR-0017: signal watching — watchable subset, symbol payload, oneshot.**
  Records D1-D3, D7, D9, the `sigchld`-stays-out
  rationale (V6), and the SQ-S1 caveat verbatim. Extends ADR-0016 from
  sending-vocabulary to watching-policy.
- **ADR-0008 second amendment**: thirteen trampolines, citing the frozen-list
  test edits as the designed friction.

## 11. Milestone sequence

1. Adversarial spec review of this document.
2. Stage-0 spike (SQ-S1..S3) → `spike/signal/FINDINGS.md`; fold surprises
   back into this spec (EV → V renumbering).
3. ADRs: new signal-watching ADR + ADR-0008 amendment.
4. Implementation plan (writing-plans skill) → subagent-driven tasks with
   per-task reviews and mutation logs. **Each task brief carries an explicit
   "inherited obligations" section** — the v0.3 lesson: soft cross-task
   expectation notes got dropped once; only the hard-obligation mechanism
   held.
5. Final whole-branch review; squash-merge PR; annotated tag `v0.4.0`.
6. Docs: README status line loses "no `uv_signal_t`" and gains a
   graceful-shutdown usage example + the SQ-S1 caveat; CHANGELOG v0.4.0.
