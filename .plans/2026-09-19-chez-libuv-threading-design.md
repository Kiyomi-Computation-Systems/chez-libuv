# Design Spec: chez-libuv threading — `__collect_safe` (#19) → `uv_async` (#20)

- **Status:** Implemented (2026-09-19). Spike complete (`spike/threading/`); this
  design is grounded in its measurements. The T2b/E5c ticker discrepancy is
  **reconciled** (§5.3, chez-http-server E5d–E5f) — both measurements were
  correct; the ticker is not a workaround and is withdrawn.
- **Implementation notes.** Stage 1 (#19) landed as **twelve** `__collect_safe`
  trampolines + `walk` plain (13 types; the "all 13" phrasing below predates that
  refinement — `walk` fires only from the synchronous `uv_walk`, so it stays
  plain, ADR-0008). Stage 2 (#20) adds `async` as the 14th type, itself
  `__collect_safe` (13 of 14 now carry it). Two deviations from this spec, both
  justified in `.plans/threading-stage-2-mutation-log.md`: **no
  `SIZEOF_UV_ASYNC_T`** (the handle is sized at runtime via
  `(uv-handle-size (uv-async-type))`, the signal precedent), and the enforced
  surface is **`require-open-handle` + `make-uv-async`** (not `require-open-loop`,
  which `uv-run` calls before the owner transfers). The model is recorded in
  [ADR-0019](decisions/0019-threading-model-collect-safe-and-per-loop-affinity.md).
- **Scope:** post-v0.5.0. Two issues, one arc: #19 (rebind `uv_run`
  `__collect_safe`) is the foundation; #20 (`uv_async` cross-thread wakeup +
  enforced per-loop thread affinity) builds on it.
- **Driver:** a real near-term consumer — the chez-http-server worker pool /
  thread-per-core design (2026-09-19 decision). Not speculative.
- **Related:** ADR-0008 (static trampolines + registry), ADR-0002 (direct FFI),
  ADR-0010 (loopback-only tests), spike/FINDINGS.md Q1 (the deferred gate),
  spike/threading/FINDINGS.md (this arc's evidence), chez-http-server spike
  E5c–E5f (the trap-tick reconciliation, §5.3).

## 1. Goal and non-goals

**Goal.** Let a loop thread block in `uv_run` without freezing garbage
collection for every other Scheme thread (#19), and give worker threads one
thread-safe way to hand work back to the loop thread (#20). Together these are
the minimum that makes a second Scheme thread *usable* alongside a libuv loop.

**Non-goals.**
- **Not** making the binding thread-safe in general. Everything except
  `uv-async-send!` stays **loop-thread-only**, and that rule becomes *enforced*,
  not merely documented (§6).
- **Not** a scheduler, work-stealing, or a thread pool — those live in the
  consumer (chez-http-server), above the binding.
- **Not** changing the single-threaded default: a program that never forks a
  thread sees identical behaviour, minus the (now-released) collect interlock
  around `uv_run`.
- **Not** shared handles across threads: a handle belongs to its loop's thread
  for its whole life.

## 2. Decisions summary

1. **D1 — `uv_run` becomes `__collect_safe`, and so do all 13 trampolines.**
   CSUG §4.3/4.8: a `__collect_safe` foreign procedure that can invoke callables
   requires *each* callable to be `__collect_safe`. `uv_run` invokes every
   trampoline, so the conversion is all-or-nothing. Spike T1 proves it is safe
   single-threaded (§5.1).
2. **D2 — the "arm a short-period timer" workaround is withdrawn, not shipped.**
   The T2b/E5c discrepancy is now understood (§5.3): the ticker opens GC windows
   only when each tick's Scheme path burns ~1000 Chez trap ticks, an accident of
   the dispatch path, never a guarantee. #19 (D1) is the only reliable
   prerequisite; there is no lighter substitute in the shipped guidance.
3. **D3 — cross-thread safety is ENFORCED per-loop thread affinity, not a prose
   rule.** Every handle/loop verb asserts it runs on the loop's owning thread and
   raises a structured `&uv-wrong-thread` otherwise. `uv-async-send!` is the one
   documented exception (§6).
4. **D4 — `uv_async` is the 14th locked trampoline** (ADR-0008's invariant: one
   locked trampoline per libuv callback *type*). `uv-async-send!` is libuv's only
   thread-safe call and is the sole verb exempt from D3.
5. **D5 — the threaded model is opt-in and gated on a threaded Chez.** On a
   non-threaded Chez the affinity check degenerates to a single owner and costs
   nothing; `uv-async-send!` still works (it is thread-safe regardless).
   *Corrected 2026-09-28 (#41): never true. The binding has imported Chez's
   thread primitives since v0.1, so it never loaded on a non-threaded Chez. A
   threaded Chez is now required; see ADR-0019's decision-5 amendment.*
6. **D6 — a new ADR records the threading model**; ADR-0008 is amended (14th
   trampoline + the `__collect_safe` attribute); ADR-0010 gets a threading-test
   companion (§9).

## 3. Blast radius

| Change | Files | Kind |
|---|---|---|
| `uv_run` `__collect_safe` | `native.sls` (the `uv_run` foreign-procedure) | 1 line, semantic |
| 13 trampolines `__collect_safe` | `native.sls` (`foreign-callable` forms, native.sls:653–747) | mechanical, but changes every callback's execution context |
| per-loop owner + affinity check | `handles.sls` (loop record + `require-open-handle`), `loop.sls` (`uv-run` sets owner) | new invariant on every verb |
| `&uv-wrong-thread` condition | `conditions.sls`, facade | additive |
| `uv_async` binding + trampoline | `native.sls`, new `(libuv async)` module, facade | additive (14th type) |

#19 is small in diff, large in semantics: it re-homes every callback into a
collect-safe context. #20 is larger in surface (a new handle type + a check on
every verb) but each piece is additive.

## 4. Spike evidence (see `spike/threading/FINDINGS.md`)

Threaded Chez 10.4.1, libuv 1.52.1, `tarm64osx`, macOS 26.6.2. Each probe run
twice.

- **T1 — collect-safe re-entry PASSES.** `uv_run` + both callables
  `__collect_safe`, 10,000 re-entries with `(collect)` on every fire, stable
  locked entry points, clean teardown, exit 0. The conversion does not break
  the callback machinery.
- **T2 — a plain `uv_run` makes the process un-collectable.** A worker thread's
  explicit `(collect)` **errors** — `cannot collect when multiple threads are
  active` — 0/50, while the loop thread sits in a plain `uv_run`. With
  `__collect_safe`: 50/50 succeed while the loop blocks 400 ms.
- **T2b — auto-GC stalls (~100×), and the ticker workaround does not save it.**
  Allocation-triggered GC waits rather than erroring: 591 ms (plain) vs 6 ms
  (safe). A 1 ms repeating timer — under `UV_RUN_DEFAULT` *and* under a
  `UV_RUN_ONCE` loop — stayed at ~448 ms, i.e. ≈ plain. This *appeared* to
  contradict the chez-http-server spike's "92 ms with a 1 ms timer" — now
  **reconciled** (§5.3): both are correct, and the difference is how much Scheme
  the loop thread runs per tick. The reason for D2 either way.

**Consequence for sequencing.** Since a plain `uv_run` blocks *all* other-thread
GC, no worker thread can even allocate usefully today. #20's registry hazard is
therefore strictly downstream of #19: there is no worker thread to corrupt the
registry until `uv_run` is collect-safe.

## 5. #19 — `__collect_safe`

### 5.1 The conversion

- `native.sls`: `(define uv-loop-run (foreign-procedure __collect_safe "uv_run"
  (uptr int) int))`.
- All 13 `foreign-callable` forms (native.sls:653–747) gain the `__collect_safe`
  keyword: `alloc, read, connection, write-done, close, timer, connect,
  shutdown, getaddrinfo, getnameinfo, exit, walk, signal`. A collect-safe
  foreign call may only invoke collect-safe callables (T2b's mode-matched
  callables were the spike's stand-in for this rule).
- The `uv-run` wrapper (loop.sls:50) is unchanged in shape; the `dynamic-wind`
  that sets/clears `loop-running` still holds. `walk` fires synchronously inside
  `uv_walk` (not from `uv_run`), but it converts too — the invariant is one
  trampoline per callback type, and a collect-safe callable is safe to invoke
  from either a collect-safe or an ordinary foreign call.

### 5.2 What T1 did NOT cover — implementation-stage obligations

- **Store-and-reraise under collect-safe.** ADR-0008's store-and-reraise policy
  and the Q2 continuation-escape were measured *plain*. A `raise` from inside a
  now-collect-safe trampoline, caught by the `guard` outside `uv_run`, must be
  re-measured. The policy itself (store the condition, let `uv_run` return, re-
  raise from Scheme) is expected to hold — it deliberately does *not* unwind
  through C — but the reactivation boundary is new and gets a dedicated test.
- **`(collect)` inside a collect-safe callback** worked in T1 (every fire). The
  binding does not itself call `(collect)`; only tests/consumers do (design
  spec S11). Keep that property under the Valgrind gate.
- **The full 13-trampoline build under `make test-memory`.** The spike probes
  are standalone FFI; the real conversion must pass the Linux Valgrind gate
  (ADR-0003) with the whole suite.

### 5.3 Why a plain `uv_run` blocks GC, and why the ticker is not a workaround (reconciled)

The T2b/E5c discrepancy is resolved (chez-http-server E5d–E5f, 2026-09-19; both
measurements are correct). The variable is **how much Scheme the loop thread
runs per tick**.

**Mechanism (Chez 10.4.1 sources).** `S_fire_collector` only sets
`$collect-request-pending` and every thread's `something-pending` flag
(c/schsig.c:574–594) — nothing more. A thread acts on it at its next `$event`,
which fires when that thread's *trap counter* reaches zero; the counter starts
at `default-timer-ticks` = 1000 (s/cmacros.ss:2118, c/thread.c:355), and
`$event` then calls `$collect-rendezvous` (s/library.ss:1219–1236). A thread
inside a plain foreign call never trips its counter, and `mutex-acquire` is a
plain lock that neither deactivates the thread nor trips it (s/prims.ss:2007,
c/thread.c:388–404). Only a thread *created* while a request is already pending
is told to check immediately (c/thread.c:181–183). So a loop thread in a plain
`uv_run` reaches a collection rendezvous only after its callbacks have burned
~1000 trap ticks — which a light callback never does inside a 400-fire window.

**The ticker helps only by accident.** E5d swept the single knob — how many
non-inlined, non-allocating procedure calls the loop thread runs per 1 ms tick,
same worker (the result is the same whether the calls run between `UV_RUN_ONCE`
polls or inside the callback under `UV_RUN_DEFAULT`):

| loop-thread work per tick | worker alloc load (ms) |
|---|---|
| nothing (T2b's harness) | 439–447 |
| 100 procedure calls | 82–85 |
| 300 procedure calls | 29–32 |
| 1 000 procedure calls | 9–19 |
| 2 000 procedure calls | 9–20 |
| uncontended `with-mutex`, no calls | 437–438 |
| `(sleep 0)` between polls | 9–12 |
| `uv_run` + callables `__collect_safe` | 6–10 |

**Through the binding** (E5e: worker unchanged, loop thread in a single
`(uv-run loop 'default)` so only the dispatch path runs per fire — trampoline →
registry → `dispatch-guarded` → closure): 1 ms timer 44–92 ms, 300 ms timer
10 223–10 240 ms, baseline 26–29 ms. The dispatch path happens to spend about a
trap budget per fire, which is why the chez-http-server E5c saw only ~3× where
T2b's empty callback saw ~75×.

**Verdict (D2).** The 1 ms ticker is not a workaround: it opens GC windows only
when each tick's Scheme path burns on the order of a thousand trap ticks — an
accident of the dispatch path, not a guarantee an application can rely on.
`(sleep 0)` between polls or `__collect_safe` are the only reliable rows.
#19's proposal to document the ticker is **withdrawn**; `__collect_safe` is the
prerequisite for a second allocating thread, full stop. (chez-http-server's
options paper, spike report, ADR-0003 and ADR-0008 are corrected to match.)

### 5.4 Cost of the conversion, single-threaded

E5f measured plain vs `__collect_safe` on `uv_run` and the callable (5 M
`uv_idle` callbacks per trial, the poll amortized over 256 handles, three trials
× two runs): **177–192 ns → 235–249 ns per callback**, ~60 ns for the
reactivate/deactivate pair. Negligible for any I/O-bound callback; recorded so
Stage 1 notes the floor rather than rediscovering it. The reconciliation
programs live in chez-http-server's spike record
(`.plans/research/spike/e5{d,e,f}-*.sps`, outputs under `out/`) and can be
imported under `spike/threading/` here if we want them co-located.

## 6. #20 — `uv_async` and enforced per-loop thread affinity

### 6.1 The one thread-safe verb

libuv guarantees exactly one thread-safe function: `uv_async_send`. Everything
else — including `uv_async_init` and creating/closing the async handle — is
loop-thread-only. So:

- **`make-uv-async : uv-loop procedure -> uv-async`** — created on the loop
  thread (it mutates the registry). The procedure is the wake callback, run on
  the loop thread when a send is coalesced.
- **`uv-async-send! : uv-async -> unspecified`** — callable from *any* thread.
  The **only** verb exempt from the affinity check (§6.3). It touches no
  registry state; it calls `uv_async_send`, which libuv makes thread-safe.
- The async callback is the **14th locked trampoline** (D4), signature
  `uv_async_cb (uv_async_t*) -> void` — same arity as `timer`/`close` but a
  distinct callback *type*, so it gets its own slot (ADR-0008's rule, as the
  v0.4 `signal` amendment already established for a same-arity type).

### 6.2 The affinity model

A loop has an **owning thread**: the only thread that may run its verbs.

- **Set at `make-uv-loop`** to the creating thread (so setup before the first
  `uv-run` works).
- **Transferred at `uv-run` entry** to the calling thread, under the existing
  `loop-running?` guard (loop.sls:55). This is what lets a program create a loop
  on the main thread and then hand it to a dedicated loop thread — the
  worker-pool pattern. Concurrent `uv-run` from two threads is already refused,
  so the transfer is unambiguous: at most one thread runs the loop at a time,
  and it becomes the owner.
- Identity uses Chez's thread id (`get-thread-id`); on a non-threaded Chez there
  is one id and the check is a tautology (D5).

### 6.3 The check

Centralize it: `require-open-handle` (handles.sls) already runs at the top of
every verb via `require-open-tcp` / `require-open-stream` / etc. Add the
affinity assertion there:

```
(define (require-loop-thread loop who)
  (let ((owner (loop-owner-thread loop)))
    (unless (eqv? owner (get-thread-id))
      (raise (make-uv-wrong-thread who owner (get-thread-id))))))
```

- One site, every verb covered — no per-verb sprinkling to forget.
- `uv-async-send!` does **not** go through `require-open-handle`'s thread arm: it
  takes a dedicated path that validates the handle kind and open state but skips
  the thread assertion (the documented exception). This is the single place the
  rule is relaxed, and it is relaxed for the single call libuv makes safe.

### 6.4 New condition

`&uv-wrong-thread` (subtype of `&uv-error`), fields `who`, `expected` (owner
thread id), `actual` (caller thread id). Turns the measured registry corruption
(`0 is not of type registry-entry`) into a loud, named refusal at the boundary,
before any registry mutation.

## 7. Vendor facts to pin (libuv 1.52.1)

Establish in the plan's Stage 0, via `spike/threading/` + probe, not from memory:

- `uv_async_init(loop, handle, cb)` returns int; `uv_async_send(handle)` returns
  int and is the documented thread-safe call; `uv_async_cb` is `(uv_async_t*) ->
  void`. `UV_ASYNC` handle-type tag and `sizeof(uv_async_t)` via the constants
  shim (ADR-0005), added to `snapshot-names`.
- `uv_async_send` coalesces: N sends may yield 1 callback. The design must not
  assume one callback per send (the wake callback drains a caller-side queue).
- Confirm `__collect_safe` interaction with a callback that itself calls
  `uv_async_send` from the loop thread (re-entrant send) is benign.

## 8. GC and memory invariants (delta)

- The registry stays one process-global `eqv-hashtable` (handles.sls:218). D3
  makes it safe by construction: only the owning thread mutates it, enforced.
  **No mutex on the registry** — libuv handle calls are themselves
  loop-thread-only, so a lock there would be false safety (it would guard the
  hashtable while the libuv call it wraps is still unsafe off-thread).
- An async handle is one more registered handle: one `foreign-alloc` block, freed
  on close through the same close dispatcher, counted by the same counters.
- The collect interlock is *released* around `uv_run` (D1) — the one behavioural
  change a single-threaded program sees, and a strict improvement.

## 9. Testing strategy

Threaded tests fight ADR-0010 (single loop, loopback, iteration-capped, no
wall-clock). Two tiers:

- **Deterministic invariants (default suite).** The affinity check is pure and
  single-threaded to test: call a verb from a non-owning thread → `&uv-wrong-
  thread` by name; `uv-async-send!` from another thread → succeeds; the async
  callback fires on the loop thread; counters/registry balance. Owner transfer:
  create on thread A, run on thread B, assert B owns it. All bounded, all
  by-name — no race.
- **A threading stress tier (opt-in, off the default gate).** The reproduction
  of the *hazard* (concurrent registry mutation) and of the *fix* (worker
  allocates freely while the loop blocks) are inherently racy; they live beside
  the spike scripts or in a `test-threading-stress.sps` that is not on the
  `make test` critical path, so the deterministic suite stays flake-free (cf.
  the Probe C hashtable-iteration flake, v0.5 lessons).
- **Memory gate.** The 13-trampoline conversion and the async handle both pass
  `make test-memory` / `make test-memory-docker` (ADR-0003, Linux Valgrind).

## 10. ADRs

- **New ADR (threading model).** Records: `__collect_safe` on `uv_run` + all
  trampolines; loop-thread-only-except-`uv-async-send!`; enforced per-loop
  affinity + owner-transfer-at-`uv-run`; the no-mutex-on-registry rationale.
- **ADR-0008 amended.** 14th trampoline (`async`); note that all trampolines are
  now `__collect_safe` and why (CSUG §4.3/4.8).
- **ADR-0010 companion.** Threaded tests are the documented exception to
  loopback-only single-thread testing; the stress tier is off the default gate.

## 11. Milestone sequence

0. **Spike — DONE** (`spike/threading/`, this design rests on it).
1. **Stage 1 — #19 — DONE** (PRs #24/#25, on `main`). Rebound `uv_run` + twelve
   trampolines `__collect_safe` (`walk` plain); re-tested store-and-reraise;
   full suite + Valgrind gate green.
2. **Stage 2 — #20 — DONE** (`feat/uv-async-thread-affinity`). `UV_ASYNC`
   constant; `make-uv-async` / `uv-async-send!`; the 14th trampoline; the
   per-loop owner + `&uv-wrong-thread` + centralized affinity check
   (`require-open-handle`); deterministic tests (`test-async.sps`) + stress tier;
   [ADR-0019](decisions/0019-threading-model-collect-safe-and-per-loop-affinity.md).

Stage 1 is independently valuable and lower-risk; Stage 2 depends on it.

## 12. Deferred, with reasons

- `uv_ref`/`uv_unref` (keep-alive control a worker pool wants) — separate, not
  needed for the wakeup path.
- Multiple async handles per loop, priority wakeups — the consumer can multiplex
  over one async handle + its own queue; revisit only if measured necessary.
- Importing the chez-http-server reconciliation programs (E5d–E5f) under
  `spike/threading/` — optional co-location; the evidence and mechanism are
  captured in §5.3 regardless.

## Appendix A — the collect-safe rule, stated for the implementer

A `__collect_safe` foreign procedure deactivates the calling thread for the
call's duration (releasing Chez's collect interlock). Any callable it invokes
runs with the thread *reactivated* for the callback body, and must therefore
itself be `__collect_safe`. Mixing — a collect-safe `uv_run` invoking a plain
callable, or vice versa — is the error the spike's mode-matched callables avoid.
The conversion is all-or-nothing across `uv_run` and its 13 (soon 14) callbacks.
