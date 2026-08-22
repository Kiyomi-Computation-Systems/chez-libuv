# Design Spec: chez-libuv v0.4 — Signal

Status: **Accepted** (adversarial review folded in 2026-08-22; stage-0 spike
measured green on both platforms 2026-08-22 — `spike/signal/FINDINGS.md`)
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
(the second-user rule, recorded at process.sls:530-531) and a
`uv-os-getpid` wrapper (exported from `(libuv process)`).

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
  whether a watcher is currently active (oneshot auto-disarms behind our
  back); mirroring *armed-ness* in Scheme invites drift. Consequence: no
  `uv-signal-watching?` predicate in v0.4. (The record does carry a **mode**
  field — see §4.4 — because mode, unlike armed-ness, is a one-way vendor-side
  property that cannot drift.)

## 2. Decisions summary

| # | Decision | Where recorded |
|---|----------|----------------|
| D1 | Watchable subset: the ADR-0016 nine minus `sigkill`/`sigstop`, which raise `&uv-invalid-argument` reason `'signal-unwatchable` before any native call | ADR-0017, §4.2 |
| D2 | Both continuous and oneshot start verbs; same callback type, same trampoline | §4.2 |
| D3 | Callback payload is the signal symbol, converted via `term-signal->value` | §4.3 |
| D4 | Thirteenth trampoline `signal`; third amendment to ADR-0008 | §5.2 |
| D5 | Dispatcher late-installed from `(libuv signal)`'s library body (DNS/process pattern) | §5.3 |
| D6 | `signal-symbol->int` and `term-signal->value` lift to `(libuv private native)` | §5.4 |
| D7 | No armed-state tracking on the record; mode IS tracked (one immutable-after-first-start field) | §1 non-goals, §4.4 |
| D8 | `uv-os-getpid` exported from `(libuv process)` beside `uv-process-pid`, gated by `ensure-native-loaded!` | §4.5 |
| D9 | DELIVERY ≠ CLOSE: stop (explicit or oneshot auto-stop) never closes; the caller always `uv-close!`s (the EXIT ≠ CLOSE analog, ADR-0007/0016) | §6 |
| D10 | **Mode is fixed per handle** by the first start verb; the cross-mode verb raises `'signal-mode-fixed`; mode change = `uv-close!` + `make-uv-signal` (grounds: EV-8, the vendor's one-way `UV_SIGNAL_ONE_SHOT` ratchet) | §4.2, §4.4, ADR-0017 |
| D11 | Rearming a oneshot watcher from inside its own delivery callback does not take effect (EV-9); documented caveat, asserted by a test | §4.2, §9.3 |

## 3. Module layout (delta)

New:

- `src/libuv/signal.sls` — `(library (libuv signal))`: constructor, start/stop
  verbs, dispatcher installation. Timer-sized.
- `tests/test-signal.sps` — auto-discovered by the `TESTS` wildcard; joins the
  memory gate via `MEMORY_TESTS := $(TESTS)`.
- `tests/signal-child.sps` — the spawned-child program for the end-to-end
  graceful-shutdown scenario (§9.3). Deliberately named outside the
  `test-*.sps` wildcard so it is never run as a suite.

Modified:

- `src/libuv-shim.c` / `.h` — constant row `UV_SIGNAL`; debug-counter triple
  `chez_uv_count_signal_new/free` + `chez_uv_live_signal` in **both** the
  `CHEZ_LIBUV_DEBUG_COUNTERS` branch and the no-op branch; header prototypes.
  Constants only — ADR-0002 holds; no uv_* call is wrapped.
- `src/libuv/private/constants.sls` — the **three-part** edit the file's own
  comment prescribes: `'UV_SIGNAL` added to `snapshot-names`, the
  `(uv-signal-type)` accessor, and the export. (`snapshot-ref` never falls
  through to the shim at call time — a name missing from the init-time
  snapshot raises `&uv-constant-unavailable`, so the snapshot-names entry is
  load-bearing, not optional.)
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
- `Makefile` — one line: export the resolved Chez binary (the `$(CHEZ)`
  variable the suites already run under) into the test environment, beside the
  existing `CHEZSCHEMELIBDIRS` export, for the spawned-child scenario.
- `tests/test-loop.sps`, `tests/test-native.sps` — the frozen twelve-name
  literals grow to thirteen (the deliberate friction ADR-0008 designed in).
- `tests/test-facade.sps` — one exercised-through-the-facade row per §4.6
  export (this suite is the sole enforcement of the facade's re-export list;
  v0.3 precedent added a row per new export).
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
(`uv-signal?`), handle state `'open`, mode compatibility (§ below),
`on-signal` a procedure, `watch-symbol` in the **watchable set**:

```
sigterm sigint sighup sigquit sigusr1 sigusr2 sigcont
```

Three named refusals, all `&uv-invalid-argument`:

- `'signal-unknown` — anything outside the nine-symbol set, including raw
  integers (`15` is refused even though it is SIGTERM everywhere — same rule
  as `uv-kill!`) and exact `0`: ADR-0016's `0` is *sending* vocabulary (the
  liveness probe) that names no signal, and probe vocabulary does not survive
  into watching.
- `'signal-unwatchable` — `sigkill` and `sigstop`: valid vocabulary, in the
  sending set, but the kernel forbids catching them. Refusing at the boundary
  names the real constraint; letting libuv answer EINVAL would name the
  syscall instead.
- `'signal-mode-fixed` — the start verb whose mode contradicts the handle's
  pinned mode (D10, below).

The callback is stored on the record **before** arming (timer discipline,
timer.sls:64-80); rcs route through `uv-check` with `who` = the public verb.

Semantics:

- **Continuous** (`uv-signal-start!`): fires `on-signal` on every delivery
  until stopped or closed.
- **Oneshot** (`uv-signal-start-oneshot!`): fires exactly once; libuv disarms
  the watcher itself. Same `uv_signal_cb` type — no extra trampoline. Once no
  watcher remains for a signum **process-wide**, the disposition reverts
  (expected: `SIG_DFL`, EV-3 — *not* the pre-libuv handler), which yields the
  classic shutdown UX: first SIGTERM drains gracefully, a second one kills.
- **Mode is fixed per handle (D10).** The first start verb pins the handle's
  mode; thereafter the other verb raises `'signal-mode-fixed`. Changing mode
  means `uv-close!` + `make-uv-signal`. This is not policy taste but vendor
  fact: `UV_SIGNAL_ONE_SHOT` is a one-way per-handle ratchet — set by a
  oneshot start and never cleared by stop or auto-stop (only
  `uv_signal_init`'s flag reset clears it), and a same-signum start
  short-circuits to a callback swap without touching the flag (EV-8). Both
  cross-mode transitions therefore silently misbehave on the pinned vendor
  (a "continuous" rearm of a once-oneshot handle fires once and disarms; a
  "oneshot" rearm of an actively-continuous same-signum handle stays
  continuous). The binding refuses what the vendor cannot deliver.
- **Rearm (within mode).** A continuous handle may be re-`start!`ed while
  armed: a signum change is an internal stop-then-start inside libuv; a
  same-signum restart is a deliberate callback-swap short-circuit that
  preserves pending deliveries and never unregisters the OS handler (EV-1).
  Consequently the wrapper **never** issues a bare stop-then-start for a
  same-signum rearm — doing so would open a window in which the last-watcher
  stop restores `SIG_DFL` and a watched fatal signal kills the process, the
  exact hazard the vendor short-circuit exists to prevent. A oneshot handle
  may be re-`start-oneshot!`ed after it fires or after an explicit stop.
- **In-callback rearm caveat (D11).** Rearming a oneshot watcher from inside
  its *own* delivery callback does not take effect: the vendor's auto-stop
  runs after the callback returns and undoes the rearm (EV-9). Rearm from a
  later dispatch (a timer callback, or after `uv-run` returns). Continuous
  watchers keep the full timer discipline: a callback may stop or close the
  handle that fired.
- **Stop** is idempotent: stopping a never-started or already-stopped (incl.
  oneshot-fired) watcher succeeds (rc 0, EV-2). The `'open` pre-check on
  start/stop is load-bearing, not cosmetic: the native calls assert-abort on
  a closing handle in assert-enabled builds, and the wrappers never issue a
  native stop after `uv-close!` — close stops the watcher itself (EV-10).

### 4.3 The callback contract

```scheme
(on-signal sig)   ; sig = the signal symbol, e.g. 'sigterm
```

- `sig` arrives via the `term-signal->value` reverse map (ADR-0016: bound
  signal → symbol, unbound → raw integer, never dropped, never fabricated).
  Because start validated the symbol, `sig` is in practice always the watched
  symbol — the map is used for uniformity, not necessity. (The map's third
  arm, `0 → #f`, is exit-payload vocabulary and unreachable here: start
  validated a nonzero watchable symbol and libuv refuses signum 0 with
  EINVAL, so `on-signal`'s domain is exactly the watched symbol.)
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

### 4.4 Mode tracking, not armed-state tracking

The record carries `on-signal` and one more field: `mode` — `#f` until the
first start verb, then `'continuous` or `'oneshot`, never changed afterward.
Mode mirrors a vendor-side one-way flag (EV-8): it is stable by construction
and cannot drift, which is exactly why it is safe to track where armed-state
is not. Armed-ness stays untracked: oneshot auto-disarm happens inside libuv,
and a Scheme-side `watching?` flag maintained from the dispatcher would still
race libuv's own view. Callers who need arm state track it themselves.
(Direct consequence: tests observe arm state behaviorally — deliveries
counted — never structurally.)

### 4.5 `uv-os-getpid`

```scheme
(uv-os-getpid) → exact integer
```

A thin wrapper — `ensure-native-loaded!` then the raw `uv_os_getpid` binding —
matching the `uv-version` precedent (the answer must come from a library this
binding has validated). Exported from `(libuv process)` beside
`uv-process-pid` (pid vocabulary lives there). Needed by the suite
(self-delivery: `uv-kill!` to own pid inside the loop) and genuinely useful
public surface. No callback, no allocation, no failure mode worth modeling.

### 4.6 Facade and conditions

Facade exports by name (house rule libuv.sls:14-17): `make-uv-signal`,
`uv-signal-start!`, `uv-signal-start-oneshot!`, `uv-signal-stop!`,
`uv-signal?`, `uv-os-getpid`. No new condition types; the new reason symbols
`'signal-unwatchable` and `'signal-mode-fixed` ride the existing
`&uv-invalid-argument`. Each export gains its row in tests/test-facade.sps
(§3, §9.3).

## 5. Internals

### 5.1 handles.sls: the signal record

`uv-signal-record`: direct `uv-handle-record` child with two mutable fields,
`on-signal` and `mode` (§4.4) — the process-record shape (handles.sls:383-389
is the model). `'signal` joins `handle-kinds` and `count-handle-free!` gets
its arm. The close path needs zero changes: signal handles own no buffers, so
`close-dispatch`'s freeing order applies untouched.

### 5.2 native.sls: the trampoline set grows to thirteen

`signal-callable`, signature `(uptr int)` → void (`uv_signal_cb`: handle +
signum). It shares `connection`'s arity but is a distinct callback **type**,
and the rule is one locked trampoline per type: the original eight already
contain same-arity distinct-type pairs (`timer`/`close` are both
`(uptr)` → void), so the precedent is the founding set itself — the DNS and
exit/walk amendments happened to be argued from arity mismatch, and this
amendment states the per-type rule explicitly so the next one needn't
re-derive it. `'signal` is appended to the **end** of `dispatcher-names`
(append-only contract, native.sls:926-934); the callable joins
`trampolines-locked`; its entry point stays module-private, baked into
`uv-signal-start-native` and `uv-signal-start-oneshot-native` (both wrappers
bake the same entry — the `uv-timer-start-native` pattern). `uv_signal_init`,
`uv_signal_stop`, and `uv_os_getpid` are bound raw (no callback arguments).
This is ADR-0008's **third** amendment (eight → ten → twelve → thirteen).

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
lifted `signal-symbol->int`, signal.sls layers the watchable-subset and mode
checks: sending and watching share the **vocabulary** but not the **refusal
policy** (sending accepts `sigkill`/`sigstop` and exact `0`; watching refuses
all three) — the distinction ADR-0017 records.

### 5.5 Shim and constants additions

One constant row (`UV_SIGNAL`), one counter triple in both branches, header
prototypes; on the Scheme side the three-part constants.sls edit (§3):
snapshot-names entry, accessor, export. The nine `SIG*` rows already exist
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
- **Close implicitly stops (EV-10).** `uv_close` on an armed watcher stops it
  on the way down (`uv__signal_close` → `uv__signal_stop`) — this is what
  makes "closing it releases the loop" true and what disarms armed watchers in
  the teardown sweep. A signal handle's close callback may additionally be
  **deferred** across extra loop iterations while signals already trapped in
  the self-pipe drain — a shape no other bound handle kind has. Lifecycle
  assertions therefore stay iteration-agnostic (§9.1's existing rule; stated
  here so nobody "optimizes" a signal close-wait into a fixed iteration
  count).
- **Teardown**: `'signal` in `handle-kinds` puts signal handles in
  `uv-loop-teardown!`'s snapshot-then-sweep; the existing drain delivers their
  close callbacks (deferred or not). No teardown code changes.
- **Pending-delivery race**: a signal already accepted by libuv when
  `uv-signal-stop!` runs before the next `uv-run` is expected to be
  suppressed, not delivered (EV-5). Note the suppression mechanism: a
  dispatch-time signum comparison, **not** a purge of the self-pipe — so
  rearming the *same* signum before the next `uv-run` can resurrect pre-stop
  deliveries. The suite keeps stop-suppression probes and same-signum rearm
  probes in separate loop drains for exactly this reason.

## 7. Vendor facts (pinned libuv v1.52.1 — **measured**, both platforms)

All ten were measured by the stage-0 spike on Darwin/arm64 and Ubuntu
24.04/x86_64 (twice per script on CI) and confirmed exactly as written —
zero surprises (`spike/signal/FINDINGS.md`). The EV numbering is kept; read
each as a V-fact. EV-1, EV-8, EV-9, and EV-10 originated as adversarial
source-reading during spec review; the spike converted them to observations.

- **EV-1** Continuous rearm has two vendor mechanisms: a **signum change** is
  an internal stop-then-start (signal.c:401-404); a **same-signum** restart
  short-circuits to a callback swap that preserves pending deliveries and
  never unregisters the OS handler (signal.c:391-399, deliberately — the
  comment cites the pending-loss window). The wrapper never issues a bare
  stop-then-start for a same-signum rearm: when the stopping watcher is the
  last for that signum, the stop installs `SIG_DFL` and a watched fatal
  signal delivered in the gap kills the process.
- **EV-2** `uv_signal_stop` on a never-started or auto-disarmed watcher
  returns 0.
- **EV-3** When the last watcher for a signum stops **process-wide**, libuv
  restores **`SIG_DFL`** — *not* the previously installed handler
  (`uv__signal_unregister_handler`). Load-bearing for SQ-S1: it predicts that
  watching `sigint` and stopping **does not give Chez its keyboard interrupt
  back**. If confirmed, that is a documented caveat in the ADR and README
  (honest surfacing, the V6 pattern) — not something the binding papers over.
- **EV-4** An active signal watcher keeps `uv_run` from returning (default
  ref'd handle).
- **EV-5** A delivery pending at stop time is suppressed for the stopped
  watcher — by dispatch-time signum comparison, not pipe purge (§6).
- **EV-6** Two watchers on the same signum in one loop both fire on one
  delivery.
- **EV-7** Signal callbacks are delivered from `uv_run` on the loop thread;
  no user code runs in signal-handler context.
- **EV-8** `UV_SIGNAL_ONE_SHOT` is a one-way per-handle ratchet: set by a
  oneshot start (signal.c:424-425), cleared by nothing on the unix path —
  `uv__signal_stop` resets only `signum` and the ACTIVE bit — and a
  same-signum start short-circuits without touching the flag
  (signal.c:396-399). Only `uv_signal_init`'s flag reset clears it. Grounds
  for D10 (mode fixed per handle). Spike legs cover **both** broken
  transition directions: continuous verb on a once-oneshot handle (fires
  once, disarms), oneshot verb on an actively-continuous same-signum handle
  (stays continuous).
- **EV-9** The oneshot auto-stop runs **after** `signal_cb` returns
  (signal.c:486-487), so a rearm issued from inside the watcher's own
  callback is undone when the callback returns. Grounds for D11.
- **EV-10** `uv_close` on an armed watcher implicitly stops it
  (`uv__signal_close` → `uv__signal_stop`: disarms, un-refs, participates in
  disposition reversion), and its close callback may be deferred across extra
  loop iterations while trapped signals drain (`uv__finish_close` re-queue).

## 8. GC and memory invariants (delta)

None new. The registry remains the sole GC root for the open handle and its
`on-signal` closure (ADR-0007); no threadpool involvement, no owned buffers,
no libuv-owned result memory. The valgrind lane needs no new suppressions or
escape hatches. Counter balance (`live-signal` returns to baseline) is the
leak oracle, as for every other kind.

## 9. Testing strategy (delta)

### 9.1 Harness rules (unchanged, restated as obligations)

Iteration-capped waits only, never wall-clock — and **every wait whose
predicate depends on a callback being delivered uses `run-until/ticking`**
(the v0.3 wording, carried forward verbatim). An armed signal watcher is an
active handle with no due timer: if the delivery path regresses, plain
`run-until`'s first `'once` step blocks in the kernel where the iteration cap
never gets to count (tests/uv-testing.sls:64-79). Plain `run-until` only where
a timer of the suite's own already keeps the loop waking, or in close-drains.
Sentinels never `#f`/`0`; `(collect)` in every callback; assert on observed
deliveries, never on which loop iteration delivered them.

### 9.2 Self-delivery harness

`(uv-kill! (uv-os-getpid) 'sigusr1)` from inside the loop. Only `sigusr1`/
`sigusr2` are self-delivered while testing delivery mechanics. The suite never
self-sends a signal without an armed watcher for it (EV-3: an unwatched send
lands on `SIG_DFL` and kills the suite). Concretely, **every negative or
post-disarm probe keeps a continuous guard watcher armed on the probed signum
for the probe's duration**: the guard keeps libuv's disposition installed and
supplies the positive ordering event that makes negative assertions
deterministic (send once, run-until the guard's counter moves, assert the
probed watcher's counter unchanged).

### 9.3 test-signal.sps scenarios

- Delivery: correct symbol delivered; continuous watcher fires across
  repeated sends; distinct watchers (sigusr1/sigusr2) route to the right
  callbacks; two watchers on one signum both fire (EV-6).
- Oneshot (guard watcher armed throughout): exactly one delivery across
  repeated sends — guard counts every send, oneshot counts one;
  stop-after-fire rc 0 (EV-2); rearm-after-fire **from outside the callback**
  works; **in-callback rearm asserted ineffective** (EV-9/D11).
- Mode fixedness (D10/EV-8): `uv-signal-start!` on a oneshot-mode handle and
  `uv-signal-start-oneshot!` on a continuous-mode handle both raise
  `'signal-mode-fixed` — asserted in both directions, armed and stopped.
- Rearm (continuous, guard on the old signum): signum switch — old signum's
  guard counts while the switched watcher stays silent, new signum delivered;
  same-signum restart swaps the callback with pending deliveries preserved
  (EV-1) — kept in a separate loop drain from the stop-suppression probe
  (§6).
- Stop suppression (EV-5, the send→stop→run ordering §6 defines): watchers A
  and B both armed on one signum; one kill (self-delivery from the loop
  thread is synchronous); stop A before the next `uv-run`; run-until B's
  counter moves; assert A's counter unchanged — B's delivery proves the event
  was dequeued, A's silence proves suppression, and B keeps the disposition
  installed. Falls back to the v0.2 bounded-retry-with-discriminating-asserts
  pattern only if the spike shows the ordering cannot be forced.
- Refusals: `sigkill`/`sigstop` → `'signal-unwatchable`; `0`, `15`, `'sigfoo`
  → `'signal-unknown`; cross-mode verbs → `'signal-mode-fixed`; verbs on
  closed handles → state conditions; wrong-kind handle → kind condition.
- Loop liveness and close: an armed watcher holds `uv-run` (EV-4); closing it
  releases (EV-10's implicit stop); a kill-then-close-before-run leg
  exercises the deferred-close shape (EV-10), with iteration-agnostic waits
  per §9.1.
- End-to-end graceful shutdown (the SQ-S2 probe graduated into the suite):
  the parent `uv-spawn!`s `tests/signal-child.sps` under the Chez binary the
  Makefile exports into the suite environment (§3; the suite **skips with a
  named row** if the variable is absent — deterministic, honest). Handshake:
  **three acks**, not two (spike finding SQ-S2-F1): the child arms its
  oneshot `sigterm` watcher, then writes READY; the parent waits for it
  before kill #1; the child acks delivery from inside the sigterm callback
  (GOT1), then acks **disarm from a later dispatch** (DISARMED, once the
  watcher reads inactive) — because the vendor auto-stop runs only after the
  callback returns (EV-9), the in-callback ack proves delivery, not disarm,
  and a kill #2 gated on it could be caught-then-dropped. The parent gates
  kill #2 on DISARMED, then asserts exit `(0 sigterm)`. Dogfoods v0.3.
- Facade: one exercised-through-the-facade row per §4.6 export in
  tests/test-facade.sps (the v0.3 process-block pattern).
- Lifecycle: close protocol, counter balance to baseline, teardown sweep
  closes an armed watcher (in test-lifecycle.sps).
- Frozen-list edits: test-loop.sps / test-native.sps thirteen-name literals;
  the uninstalled-stub matrix grows a `signal` row.

### 9.4 Memory lane

test-signal.sps joins `make test-memory` automatically. Signal delivery under
valgrind involves no threadpool and no io_uring; both legs run the same code
path. Gate stays definite-only with no new suppressions expected.

## 10. Stage 0 spike (`spike/signal/`, findings in `spike/signal/FINDINGS.md`)

**Done 2026-08-22, both platforms green, zero surprises.** Probes:
`10-sigint-coexist.ss`, `11-oneshot-e2e.ss`, `12-vendor-microfacts.ss`, with
`probe-signal.c` (constants) and `sig-probe.c` (disposition reads via
`sigaction` — spike-local shared library; ADR-0002 binds the shipped shim,
not spike scaffolding). Darwin locally; Linux via the spike-branch CI push
pattern (`push: branches: ['spike/**']`, ci.yml's cached pinned Chez), run
32575647102 on the since-deleted `spike/signal-evidence` branch, each script
twice. One spec amendment came back: the three-ack E2E handshake (§9.3,
SQ-S2-F1). The SQ descriptions below are as designed; FINDINGS carries the
measurements and the ADR-ready SQ-S1 caveat text.

- **SQ-S1 — Chez SIGINT coexistence.** Baseline: what disposition does the
  Chez runtime install for SIGINT in a script (and note REPL differences)?
  Then: arm a `sigint` watcher → structural read of the disposition +
  behavioral self-delivery (expect loop callback, no Chez keyboard
  interrupt); stop → structural read again (EV-3 predicts `SIG_DFL`, i.e.
  Chez's handling is NOT restored). The post-stop **behavioral** leg runs in
  a sacrificial child (spawned via v0.3's `uv-spawn!` or a shell wrapper)
  whose termination-by-SIGINT is asserted from the parent's exit observation
  — `SIG_DFL` for SIGINT terminates, so it must be the last observation of
  its process. Output: the honest caveat text for ADR/README, and
  confirmation that no Scheme code runs in handler context (EV-7).
- **SQ-S2 — oneshot end-to-end.** Child arms oneshot `sigterm`; parent sends
  SIGTERM twice, with the readiness/acknowledgment handshake of §9.3. Expect:
  first delivery runs the handler; second kills with `(0 sigterm)` —
  measuring auto-disarm + disposition reversion together. In-process legs:
  EV-2 rc; rearm-after-fire from outside the callback; **in-callback rearm
  undone** (EV-9).
- **SQ-S3 — vendor micro-facts.** EV-1 both mechanisms (signum-change
  stop-then-start; same-signum callback swap preserving a pending delivery);
  EV-8 both broken mode transitions (continuous verb on a once-oneshot
  handle; oneshot verb on an actively-continuous same-signum handle); EV-4
  (loop liveness); EV-5 (send→stop→run suppression — forced ordering; if
  racy, bounded-retry with discriminating asserts checked every attempt, the
  v0.2 lesson); EV-6 (two watchers, one signum); EV-10 (kill-then-close-
  before-run: implicit stop + deferred close callback).

ADRs (written 2026-08-22, post-spike):

- **[ADR-0017](decisions/0017-signal-watching-vocabulary-and-mode.md):
  signal watching — watchable subset with its own refusal policy, mode fixed
  per handle, symbol payload, the coexistence caveat.** Records D1-D3, D7,
  D9-D11 with the spike measurements as evidence. Extends ADR-0016 from
  sending-vocabulary to watching-policy.
- **[ADR-0008](decisions/0008-static-trampolines-and-handle-registry.md)
  third amendment**: thirteen trampolines — the amendment that states the
  one-per-callback-TYPE rule in its own terms (uv_signal_cb shares
  connection's arity, and the original eight already contain same-arity
  distinct-type pairs), with the frozen-list widening as designed friction.

## 11. Milestone sequence

1. ~~Adversarial spec review of this document.~~ Done 2026-08-22 (four-lens
   review; findings folded into this revision — the mode-fixed contract D10,
   EV-8..10, and the §9 hardening all originate there).
2. ~~Stage-0 spike (SQ-S1..S3) → `spike/signal/FINDINGS.md`.~~ Done
   2026-08-22: both platforms green, zero surprises; EV-1..10 are measured
   V-facts; §9.3's handshake amended to three acks (SQ-S2-F1).
3. ~~ADRs: ADR-0017 + ADR-0008 third amendment.~~ Done 2026-08-22 (§10 links).
4. Implementation plan (writing-plans skill) → subagent-driven tasks with
   per-task reviews and mutation logs. **Each task brief carries an explicit
   "inherited obligations" section** — the v0.3 lesson: soft cross-task
   expectation notes got dropped once; only the hard-obligation mechanism
   held.
5. Final whole-branch review; squash-merge PR; annotated tag `v0.4.0`.
6. Docs: README status line loses "no `uv_signal_t`" and gains a
   graceful-shutdown usage example + the SQ-S1 caveat; CHANGELOG v0.4.0.
