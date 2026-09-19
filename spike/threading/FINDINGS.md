# Threading Spike Findings — chez-libuv issues #19 / #20

Evidence for the `__collect_safe` rebinding (#19) and the `uv_async` cross-thread
wakeup (#20), gathered before designing either. Every number below is produced
by a committed script in this directory and was **run twice**; where a claim
differs from the issue text it was filed from, the difference is named, not
glossed (repo rule: *instrument, never reason* — see the v0.5 process lessons).

## Toolchain

| Item | Value |
|---|---|
| Chez Scheme | 10.4.1, **threaded build** (`(threaded?)` → `#t`) |
| Machine type | `tarm64osx` |
| libuv | 1.52.1 (Homebrew), `/opt/homebrew/opt/libuv/lib/libuv.dylib` |
| macOS | 26.6.2, arm64 |

Scripts: `01-collect-safe-reentry.ss`, `02-two-thread-gc.ss`,
`03-auto-gc-and-workaround.ss`. Constants (`UV_TIMER`, `UV_RUN_*`) are
probe-values inlined per the spike convention (ADR-0005 applied to the spike).

## Summary of verdicts

| Q | Verdict |
|---|---|
| **T1 — collect-safe callback re-entry** | **PASS.** `uv_run` + both callables `__collect_safe`, 10,000 re-entries with `(collect)` on every fire, locked entry stable, teardown clean, exit 0, twice. The `__collect_safe` conversion #19 requires does not break the single-thread callback machinery. |
| **T2 — does a plain uv_run block another thread's GC?** | **YES, hard.** Loop thread in a plain `uv_run`: a worker thread's explicit `(collect)` **fails outright** — `cannot collect when multiple threads are active` — 0/50 succeed. Rebind `uv_run` `__collect_safe`: 50/50 succeed while the loop thread blocks 400 ms. |
| **T2b — auto-GC stall + the ticker workaround** | Auto (allocation-triggered) GC **stalls** rather than erroring: worker alloc load 590 ms (plain) vs **6 ms (safe)** — ~85–100×. The "arm a 1 ms timer" interim workaround #19 proposes was **ineffective** here: 448 ms (`UV_RUN_DEFAULT`+timer) / 445 ms (`UV_RUN_ONCE` loop+timer), both ≈ plain, not the issue's 92 ms. |

## T1 — collect-safe callback re-entry (`01-collect-safe-reentry.ss`)

`spike/01-callback-gc.ss` proved 10k C→Scheme re-entries under GC pressure, but
ran **plain** — it does not cover the collect-safe regime #19 forces (CSUG
§4.3/4.8: a `__collect_safe` foreign proc that invokes callables requires each
callable to be `__collect_safe`). This is that proof redone with `__collect_safe`
on `uv_run` and both callables.

```
chez --script spike/threading/01-collect-safe-reentry.ss <libuv> 10000
→ fire count exact: 10000 OK   close_cb fired exactly once: 1 OK
  entry point stable: #t OK    handle arg round-tripped: #t OK
  uv_loop_close rc: 0 OK       RESULT: PASS   (exit 0, twice)
```

**Reading.** Converting the callback layer to `__collect_safe` is viable: locked
entry points still stable across GC, callbacks still re-enter from inside a
blocking `uv_run`, `(collect)` inside a collect-safe callback still works, clean
teardown. This de-risks #19's largest mechanical cost (all 13 trampolines →
`__collect_safe`). NOT yet exercised under collect-safe here and left for the
implementation stage: the store-and-reraise continuation escape (ADR-0008/spike
Q2, measured plain) and in-callback errors.

## T2 — plain uv_run blocks the whole process's GC (`02-two-thread-gc.ss`)

The loop thread arms a oneshot timer at `block-ms` and enters `uv_run`; a worker
thread waits until the loop thread is inside the poll, then attempts 50 guarded
`(collect)`s. Each collect is guarded, so a failure is data, not an unhandled
exception.

```
chez --script .../02-two-thread-gc.ss <libuv> plain 400
→ worker collects that SUCCEEDED = 0 of 50
  first collect error = Exception in collect: cannot collect when multiple threads are active
chez --script .../02-two-thread-gc.ss <libuv> safe 400
→ worker collects that SUCCEEDED = 50 of 50   first collect error = none
```
(Both byte-stable across two runs.)

**Reading — the core #19 result, and sharper than "stall".** Chez's collector is
stop-the-world and requires every *other* thread deactivated. A thread is
deactivated inside a `__collect_safe` foreign call (or blocked on a
mutex/condition); a thread inside a **plain** foreign call stays **active**. So a
loop thread blocked in a plain `uv_run` makes the entire process
un-collectable — an explicit `(collect)` on any other thread **errors
immediately**, it does not merely slow down. `__collect_safe` deactivates the
loop thread for the blocking poll, and other threads collect freely.

## T2b — auto-GC stalls; the ticker workaround does not save it (`03-auto-gc-and-workaround.ss`)

T2 used explicit `(collect)`. #19 quotes a *stall* (10.27 s), implying
allocation-triggered GC **waits** rather than errors — and that premise is what
its documented workaround ("a second thread needs a short-period timer armed")
rests on. Worker allocates only (no explicit collect); measure a fixed alloc load.

| mode | worker alloc load (ms), 2 runs |
|---|---|
| `plain` (one `UV_RUN_DEFAULT` block) | 591 / 590 |
| `safe` (`__collect_safe` uv_run) | 6 / 7 |
| `plain-ticker` (`UV_RUN_DEFAULT` + 1 ms repeating timer) | 448 / 449 |
| `plain-once-ticker` (`UV_RUN_ONCE` loop + 1 ms timer) | 445 / 448 |

(uv_run blocked ~600 ms in every mode; no `worker error` in any — auto-GC waits, it does not raise.)

**Reading.**
1. **Auto-GC stalls, explicit-collect errors** — same root cause (loop thread
   active), two different failure modes. Both are removed by `__collect_safe`
   (6 ms, ~100×). This is #19's value, measured in this repo.
2. **The interim ticker workaround was ineffective here.** Neither a 1 ms
   repeating timer under `UV_RUN_DEFAULT` nor a `UV_RUN_ONCE` loop with the same
   timer brought the worker near the collect-safe number — both sat at ~448 ms,
   ≈ plain, ≈75× slower than safe. This **contradicts the chez-http-server
   spike's "92 ms with a 1 ms poll timer"**. Reported as a measurement, not a
   mechanism claim; the discrepancy is likely a harness difference (Chez
   version, how the worker deactivates, poll/timer structure) and **must be
   reconciled with that spike before the workaround is documented as usable**.
   Design consequence: do not lean on the timer workaround — treat `__collect_safe`
   (#19) as the actual prerequisite for any second allocating thread.

## What this means for #20 (registry / cross-thread)

Measured, not asserted: **today, with a plain `uv_run`, no second Scheme thread
can even safely allocate** while the loop runs (T2/T2b). So #20's registry
concern is strictly downstream of #19 — a worker thread is not viable at all
until `uv_run` is `__collect_safe`. The registry corruption the chez-http-server
spike measured (`0 is not of type registry-entry`) is the *next* hazard once
threads can coexist: the registry is one process-global unsynchronized
`eqv-hashtable` ([handles.sls:218](../../src/libuv/private/handles.sls)), both
dispatch table and GC root (ADR-0008). The chosen mitigation (2026-09-19
decision) is **enforced per-loop thread affinity**: every verb asserts it runs
on the loop's owning thread, `uv-async-send!` the one documented exception. A
local reproduction of the corruption was **not** re-done here — the hazard is
established and the enforcement decision already made; it is a possible
implementation-stage regression probe.

## Deliberately untested (implementation-stage obligations)

- Store-and-reraise / continuation escape (ADR-0008 / Q2) under `__collect_safe`.
- The full 13-trampoline conversion compiled and run under `make test-memory`
  (Valgrind) — these probes are standalone FFI, not the real binding.
- Whether the ticker workaround can be made to work at all (see T2b.2) — parked
  pending reconciliation with the chez-http-server harness.
