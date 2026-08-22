# ADR-0017: Signal watching reuses the closed vocabulary with its own refusal policy; a watcher's mode is fixed per handle

- **Status:** Accepted (2026-08-22) — evidence: spike/signal/FINDINGS.md SQ-S1, SQ-S2, SQ-S3 (EV-1..EV-10, measured on both platforms)
- **Date:** 2026-08-22
- **Scope:** chez-libuv v0.4
- **Related:** [design spec](../2026-08-22-chez-libuv-v0.4-signal-design.md) §4.2-§4.4, §6, §7,
  [ADR-0005](0005-constants-are-never-transcribed.md),
  [ADR-0007](0007-no-guardians-explicit-close.md),
  [ADR-0008](0008-static-trampolines-and-handle-registry.md),
  [ADR-0016](0016-signal-vocabulary-and-root-lane.md)

## Context

v0.3 bound the signal-*sending* side behind ADR-0016's closed nine-symbol
vocabulary. v0.4 binds the receiving side — `uv_signal_t` watchers — and
watching drags three questions across the boundary that sending never faced,
each with a wrong answer that is *plausible*:

- **Not everything sendable is watchable.** `sigkill`/`sigstop` are legal
  arguments to `uv-kill!` and illegal to `uv_signal_start` (the kernel forbids
  catching them; libuv answers `EINVAL`). Exact `0`, ADR-0016's liveness
  probe, names no signal at all. A watching API that simply reuses the
  sending validator accepts all three and reports the failure as a syscall
  errno instead of the actual constraint.
- **The pinned vendor cannot change a watcher's mode.** Two behaviors of
  vendored v1.52.1, found by adversarial source-reading during spec review
  and then measured (EV-8a/EV-8b, identical on Darwin and glibc): the
  `UV_SIGNAL_ONE_SHOT` flag is a one-way per-handle ratchet
  (`uv__signal_start` sets it; `uv__signal_stop` clears only `signum` and the
  ACTIVE bit; only `uv_signal_init`'s flag reset clears it), and a
  same-signum start short-circuits to a callback swap that never touches the
  flag. Measured consequences: a "continuous" restart of a once-oneshot
  handle silently fires once and disarms (I=2 after two guarded kills); a
  "oneshot" restart of an armed same-signum continuous watcher silently stays
  continuous (J=2 after two kills). Both are rc 0. A contract that promises
  free rearm across modes is unimplementable on the pinned vendor, and the
  failures are silent.
- **Watching a signal takes it away from the host runtime — permanently.**
  SQ-S1 measured, on both platforms: Chez installs a real SIGINT handler
  (`sa_sigaction`) even in `--script` mode; `uv_signal_start` replaces it;
  and `uv_signal_stop` restores **`SIG_DFL`**, not what was there before —
  `uv__signal_unregister_handler`'s behavior, confirmed structurally
  (disposition reads) and behaviorally (two sacrificial children killed by
  SIGINT after stop, including one whose `register-signal-handler` handler
  never fired).

Two further measured facts bound the delivery semantics: the vendor's
oneshot auto-stop runs only **after** `signal_cb` returns, so a rearm issued
from inside the watcher's own callback returns rc 0 and is silently undone
(EV-9); and stop-suppression of a pending delivery is a dispatch-time signum
comparison, not a pipe purge, so a same-signum rearm before the next `uv_run`
resurrects the pre-stop delivery (EV-5 + corollary).

## Decision

**Watching reuses ADR-0016's vocabulary but not its refusal policy.** The
watchable set is the nine symbols minus `sigkill`/`sigstop`:
`sigterm sigint sighup sigquit sigusr1 sigusr2 sigcont`. The two unwatchables
raise `&uv-invalid-argument` with the reason `'signal-unwatchable` — a new
reason, distinct from `'signal-unknown`, because "valid signal you cannot
watch" and "not a signal" are different mistakes and the refusal names the
kernel's constraint rather than libuv's errno. Exact `0` is *sending*
vocabulary only and raises `'signal-unknown` here. `sigchld` stays outside
the vocabulary entirely: libuv owns SIGCHLD for child reaping on Linux
(ADR-0016, vendor fact V6), and a vocabulary that cannot name it cannot
break it. The symbol→int validator and the int→symbol reverse map lift from
`process.sls` into `(libuv private native)` — the second-user rule ADR-0016
anticipated ("lifts ... on its second user") — and `(libuv signal)` layers
the watchable-subset check on top.

**A watcher's mode is fixed for the life of the handle.** The first start
verb (`uv-signal-start!` or `uv-signal-start-oneshot!`) pins the handle's
mode; the other verb thereafter raises `'signal-mode-fixed`. Changing mode
means `uv-close!` + `make-uv-signal`. This is not API taste but the measured
vendor ratchet (EV-8a/b): both cross-mode transitions succeed with rc 0 and
then silently do the wrong thing, and no wrapper can fix them —
`uv_signal_stop` does not clear the flag, and clearing it from outside is not
available to a constants-only shim (ADR-0002) nor safe (the flag participates
in libuv's watcher-tree ordering). The record carries a `mode` field set once
by the first start verb; it mirrors a vendor-side one-way flag, so it is
stable by construction. **Armed-state stays untracked**: oneshot auto-disarm
happens inside libuv, and a Scheme-side `watching?` flag would race the
vendor's own view. Mode is trackable precisely because it cannot change;
armed-ness is untrackable precisely because it can.

**Within its mode, rearm follows the vendor's two mechanisms.** A continuous
handle may be re-`start!`ed while armed: a signum change is libuv's internal
stop-then-start; a same-signum restart is the deliberate callback-swap
short-circuit that preserves pending deliveries and never unregisters the OS
handler (EV-1a/b). The wrapper therefore **never** issues a bare
stop-then-start for a same-signum rearm — when the stopping watcher is the
last for that signum the stop installs `SIG_DFL`, and a watched fatal signal
delivered in that gap kills the process; the vendor short-circuit exists to
close exactly that window. A oneshot handle may be re-`start-oneshot!`ed
after it fires or is stopped — but **not from inside its own delivery
callback**: the auto-stop runs after the callback returns and silently undoes
an in-callback rearm (EV-9, rc 0 both platforms). Rearm from a later
dispatch, or after `uv-run` returns. This caveat is documented at the verb
and asserted by a suite scenario, never left to discovery.

**Delivery is the signal symbol; DELIVERY ≠ CLOSE.** `on-signal` receives
the watched signal as a symbol through the lifted reverse map — one handler
can serve `sigterm` and `sigint` without closure gymnastics, and the
conversion discipline is ADR-0016's (never dropped, never fabricated; the
map's `0 → #f` arm is exit-payload vocabulary and unreachable here). Neither
delivery, `uv-signal-stop!`, nor oneshot auto-disarm closes the handle or
frees anything: the caller always `uv-close!`s, exactly as EXIT ≠ CLOSE
obliges process owners (ADR-0007/0016). `uv_close` on an armed watcher stops
it on the way down, and its close callback may arrive iterations late while
trapped signals drain (EV-10) — so lifecycle waits stay iteration-agnostic.

**The coexistence caveat is surfaced, not fixed.** Watching `sigint` takes
SIGINT away from the Chez runtime: while the watcher is armed, Ctrl-C is
delivered to the loop callback and Chez's keyboard interrupt never fires;
after `uv-signal-stop!` (or oneshot auto-disarm with no other watcher) the
disposition is `SIG_DFL` — libuv does not restore what was there before, so
SIGINT then terminates the process. Measured on both platforms, for both of
Chez's handler surfaces (`keyboard-interrupt-handler`,
`register-signal-handler`). This is `uv__signal_unregister_handler`'s
behavior — libuv's constraint, documented in the README beside the
graceful-shutdown example (the V6 pattern: surfaced rather than fixed). The
same reversion is also the feature: a oneshot `sigterm` watcher yields
first-SIGTERM-drains, second-SIGTERM-kills with no extra code.

## Consequences

- **`'signal-mode-fixed` is a new way to be refused, and refusal is the
  point**: the alternative is a rc-0 call that silently changes nothing
  (oneshot verb, armed same-signum continuous) or a "continuous" watcher
  that disarms after one delivery (continuous verb, once-oneshot handle) —
  both measured. Mode change costs one close + one constructor call,
  explicit and cheap.
- **Delivery reaches Scheme only via `uv_run` on the loop thread** (EV-7,
  measured: callback count still 0 when `kill()` returns). No Scheme code
  ever runs in signal-handler context, so the store-and-reraise policy and
  the `__collect_safe` open question (spike/FINDINGS.md:925-927) are
  untouched by this milestone.
- **Every suite send is guarded.** EV-3 makes an unwatched self-send fatal
  (`SIG_DFL`), so the test discipline keeps a continuous guard watcher armed
  on any probed signum — which doubles as the positive ordering event that
  makes negative assertions deterministic (design spec §9.2). Stop-suppression
  and same-signum-rearm probes live in separate loop drains, because
  suppression is a signum comparison, not a purge (EV-5 corollary).
- **The E2E handshake is three acks** (READY / delivery / DISARMED): the
  in-callback ack proves delivery, not disarm — EV-9's mechanism — so a
  kill gated on it can be caught-then-dropped (spike finding SQ-S2-F1).
- **Rejected: exposing the vendor's rearm semantics as-is** (document the
  ratchet, refuse nothing). Both broken transitions return rc 0; "unwatched
  behavior cannot ship" (ADR-0013's rule) applies doubly to *silently wrong*
  behavior.
- **Rejected: clearing `UV_SIGNAL_ONE_SHOT` from the binding.** The flag is
  vendor-internal state that participates in watcher-tree ordering and
  handler registration decisions; ADR-0002's constants-only shim has no
  legitimate way to touch it, and reaching into the struct from Scheme would
  be exactly the transcription ADR-0005 forbids.
- **Rejected: restoring the pre-libuv disposition ourselves** (save
  `sigaction` before start, reinstall after stop). It would put the binding
  in the signal-disposition bookkeeping business libuv deliberately owns,
  race any other disposition change in the process, and lie about libuv's
  model. The caveat is one paragraph; the fix would be a subsystem.
- **Rejected: a `watching?` predicate / armed-state field.** Auto-disarm
  makes any Scheme-side mirror eventually wrong; the suites observe arm
  state behaviorally (deliveries counted), and callers can too.
- Adding a watchable signal later (e.g. `sigwinch`) stays one shim row plus
  one case arm (ADR-0016), plus its membership in the watchable subset — the
  refusal split means the sending and watching sets grow independently.
