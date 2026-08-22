# v0.4 signal spike — FINDINGS (SQ-S1, SQ-S2, SQ-S3)

Stage 0 of the v0.4 signal milestone
(design spec `.plans/2026-08-22-chez-libuv-v0.4-signal-design.md` §10).
Every expected vendor fact EV-1..EV-10 was **measured on both platforms and
confirmed as predicted — zero surprises**. Four of the ten (EV-1, EV-8, EV-9,
EV-10) originated as adversarial source-reading during spec review; this spike
converts all ten from predictions into observations. The spec's EV table can
be read as V-facts unchanged.

## Environment

| | macOS leg | Linux leg |
|---|---|---|
| Runner | Darwin/arm64 dev machine (`tarm64osx`) | ubuntu-latest = Ubuntu 24.04.4 LTS, x86_64 (`ta6le`) |
| How run | locally, 2026-08-22 | workflow **"Signal spike (Linux legs) [TEMPORARY]"**, run 32575647102, branch `spike/signal-evidence` (deleted after harvest, the v0.2/v0.3 pattern) |
| Chez Scheme | 10.4.1 (brew) | 10.4.1, pinned build restored from ci.yml's cache key |
| libuv | 1.52.1 (vendored submodule, `build/vendor/libuv.{dylib,so}`) | same, built on the runner (`uv_version_string() = 1.52.1`) |
| Constants | Darwin values as committed | rewritten by `spike/dns/apply-probe-constants.sh` from `probe-signal --scheme` (2 files, 4 substitutions — notably SIGUSR1 30→10, SIGUSR2 31→12) |
| Repetition | scripts run to green after harness fixes | every script run **twice**; verdict lines identical across runs; "no SURPRISE lines on this runner" |

Probe scaffolding: `probe-signal.c` (constants, ADR-0005 applied to the spike
itself), `sig-probe.c` (a spike-local shared library reading the installed
disposition via `sigaction(2)` — the structural half of SQ-S1; legal because
ADR-0002's constants-only rule binds the shipped shim, not spike code).

## Summary of verdicts

| SQ | Verdict |
|---|---|
| SQ-S1 — Chez SIGINT coexistence | **AS PREDICTED, both platforms.** Chez installs a real SIGINT handler (`sa_sigaction`) even in `--script` mode, so the steal is not a REPL-only concern. `uv_signal_start` replaces it; delivery reaches Scheme only via `uv_run` (EV-7); `uv_signal_stop` leaves **SIG_DFL** (EV-3) — Chez's handling is NOT restored, in either of its forms (`keyboard-interrupt-handler`, `register-signal-handler`). Both sacrificial children died by SIGINT. |
| SQ-S2 — oneshot end-to-end | **AS PREDICTED, both platforms**: graceful-then-killed, parent observed exit `(0 . SIGTERM)` on kill #2. One spec-feeding finding: the handshake needs THREE acks, not two (below). |
| SQ-S3 — vendor micro-facts | **ALL TEN AS PREDICTED, both platforms**, including both EV-8 ratchet directions and the EV-5 resurrect corollary. |

## SQ-S1 — the caveat text this evidence supports

macOS leg (Linux byte-equivalent modulo addresses):

```
M1 baseline (Chez --script): disposition=sa_sigaction addr=102329974
M2 armed:                    disposition=handler      addr=102522C7C
M3: fires-at-kill=0 after-run fires=1 last=2 steps=1 chez-ki=0
M4 stopped:                  disposition=SIG_DFL      addr=0
--die-leg exit            = (0 . 2)      [killed by SIGINT]
--die-leg-registered exit = (0 . 2)      [killed by SIGINT; Chez handler never fired]
```

The honest caveat for ADR-0017 and the README:

> Watching `sigint` takes SIGINT away from the Chez runtime: while the
> watcher is armed, Ctrl-C/`SIGINT` is delivered to the loop callback and
> Chez's keyboard interrupt never fires; after `uv-signal-stop!` (or oneshot
> auto-disarm) the disposition is **SIG_DFL** — libuv does not restore what
> was there before, so SIGINT then terminates the process. This applies
> equally to handlers installed with Chez's `register-signal-handler`
> (measured: not restored, on both platforms). It is libuv's behavior
> (`uv__signal_unregister_handler`), not something the binding can fix —
> only surface.

EV-7's confirmation is also load-bearing for the binding's threading story:
`kill()` returned with the callback count still 0 on every measurement — no
Scheme code runs in signal-handler context; delivery is an ordinary loop
dispatch. The `__collect_safe` open question (spike/FINDINGS.md:925-927)
stays closed for this milestone.

## SQ-S2 — the handshake finding (feeds spec §9.3)

The end-to-end shape works exactly as designed: child arms oneshot
`sigterm` → READY → kill #1 → handler runs → auto-disarm + disposition
reversion → kill #2 kills, parent sees `(0 . 15)`. Both platforms, both runs.

**Finding SQ-S2-F1 (spec §9.3 amendment):** the spec's two-byte handshake
gates kill #2 on an ack written *from inside the sigterm callback*. Per EV-9's
mechanism the vendor auto-stop runs only **after** `signal_cb` returns, so at
the moment that ack is observable the watcher may still be armed and libuv's
sigaction handler still installed — a fast kill #2 in that window would be
caught-then-dropped (stopped handle) and the child would never die. The spike
therefore used **three** acks — `READY` (armed), `GOT1` (in-callback:
delivery), `DISARMED` (from a later dispatch, after `uv_is_active` reads 0:
disarm) — and gated kill #2 on the third. Measured: the third line read
`DISARMED` on every run. The graduated suite test must use the three-ack
shape; the in-callback ack alone proves delivery, not disarm.

In-process legs (identical on both platforms): oneshot fires exactly once per
arm under a continuous guard (H=2 across 3 kills); stop on a fired oneshot is
rc 0 (EV-2); out-of-callback rearm delivers; **in-callback rearm returns rc 0
yet is silently undone by the auto-stop** (EV-9 — H2=1 after two kills).

## SQ-S3 — micro-facts (identical verdict lines, both platforms, both runs)

```
EV-6:  both watchers fired once on one delivery (A=1 B=1)
EV-1a: signum-change rearm: rc=0, old signum silent, new delivered
EV-1b: same-signum swap kept the pending delivery for the NEW callback (cbX=0 cbY=1)
EV-5:  pending delivery suppressed for stopped E (E=0) while F got it
EV-5-corollary: pre-stop delivery RESURRECTED by a same-signum rearm (G=1)
EV-8a: 'continuous' restart of a once-oneshot handle fired once then disarmed (I=2 after two kills)
EV-8b: 'oneshot' restart of an armed same-signum continuous stayed continuous (J=2 after two kills)
EV-2:  stop is rc 0 on never-started, idempotent
EV-10: close-with-pending: cb suppressed (L=0), close_cb after 1 steps, guards delivered
EV-4:  armed watcher held the loop; close released it; loop closed clean
```

Notes on individual facts:

- **EV-8a/EV-8b** are the measured form of the adversarial review's two
  critical findings: the `UV_SIGNAL_ONE_SHOT` ratchet and the same-signum
  short-circuit are real on both platforms. D10 (mode fixed per handle,
  `'signal-mode-fixed`) is therefore grounded in measurement, not only
  source-reading.
- **EV-5-corollary** confirms suppression is a dispatch-time signum
  comparison, not a pipe purge: a same-signum rearm before the next `uv_run`
  resurrects the pre-stop delivery. The suite must keep stop-suppression and
  same-signum-rearm probes in separate loop drains (spec §6 already says so).
- **EV-10**'s close deferral was benign here (close_cb after 1 step with a
  delivery pending) — the iteration-agnostic wait rule stands, and no
  fixed-step assertion is safe.
- The every-send-guarded discipline (§9.2) held throughout: no send in any
  script ever targeted a signum without an armed watcher, except inside the
  sacrificial die-leg children whose death IS the assertion.

## Harness lessons (spike-internal, recorded for the implementation stage)

- Chez `file-options`: `(no-fail append)` **truncates on every open** —
  `no-fail` without `no-truncate` replaces the file, so each "append" left
  exactly one line and the parent's line-count gate never advanced. The
  correct option set for an append-or-create handshake writer is
  `(no-fail no-truncate append)`. Cost one debugging round; worth knowing
  before test-signal.sps writes any evidence files.
- Delivery latency was 1 loop step in every measurement on both platforms,
  but nothing asserts that: all waits stayed iteration-capped with the 20ms
  watchdog bounding each `'once` step.

## The decisions this feeds

1. **ADR-0017** can cite measurements for: the watchable-subset refusals, the
   mode-fixed-per-handle rule (EV-8a/b), the in-callback rearm caveat (EV-9),
   the delivery-≠-close discipline (EV-10), and the SQ-S1 caveat text above,
   verbatim.
2. **Spec §7**: every EV is now a V-fact; no renumbering needed, no API
   reshaping — the spike found zero surprises against the reviewed spec.
3. **Spec §9.3**: the graduated E2E test adopts the three-ack handshake
   (SQ-S2-F1).
