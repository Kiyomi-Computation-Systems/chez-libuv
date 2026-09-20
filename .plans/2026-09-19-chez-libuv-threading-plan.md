# chez-libuv threading — Implementation Plan (#19 → #20)

- **Status:** Draft (2026-09-19). Companion to
  `2026-09-19-chez-libuv-threading-design.md`. Spike complete
  (`spike/threading/`).
- **Shape:** two stages on one arc. Stage 1 = #19 (`__collect_safe`), ships
  alone. Stage 2 = #20 (`uv_async` + enforced affinity), depends on Stage 1.

## Global constraints

- **TDD, red first.** Every behavioural change lands as a failing test (unbound
  identifier / wrong outcome), confirmed red, then made green. Record red
  evidence in a per-stage mutation log (`.plans/threading-stage-N-mutation-
  log.md`), as v0.5/process/dns did.
- **Functional core / imperative shell.** The affinity check and flag parsing
  are pure predicates; the FFI and registry mutation stay at the edge.
- **Run the gate before every commit.** `make test` (16 suites) + `make
  test-memory` (ASan on macOS) locally; the authoritative leak gate is
  `make test-memory-docker` (Linux Valgrind, ADR-0003). The billing-blocked
  `linux (vendored + valgrind)` CI leg is covered by the Docker run.
- **Conventional Commits**, squash-merge, branch before work.
- **Version/CHANGELOG.** Decide at Stage 2 exit whether the arc is a version bump
  (e.g. v0.6.0 "threading") or lands unreleased like #13/#22/#23. `check-pins`
  requires Akku.manifest == CHANGELOG top `## X.Y.Z`; do not drift.
- **`get-thread-id` gating.** All threaded code is guarded by `(threaded?)`;
  the affinity check degenerates cleanly to one owner on a non-threaded Chez.

## File structure

| File | Stage 1 (#19) | Stage 2 (#20) |
|---|---|---|
| `src/libuv/private/native.sls` | `uv_run` + 13 callables `__collect_safe` | `uv_async_init`/`send` bindings; 14th trampoline |
| `src/libuv/private/constants.sls` | — | `UV_ASYNC`, `SIZEOF_UV_ASYNC_T` (snapshot) |
| `src/libuv-shim.c` | — | `UV_ASYNC`, `sizeof(uv_async_t)` table entries |
| `src/libuv/private/conditions.sls` | — | `&uv-wrong-thread` |
| `src/libuv/private/handles.sls` | — | loop owner-thread field; `require-loop-thread`; async handle record + close arm |
| `src/libuv/loop.sls` | — | set/transfer owner at `uv-run` entry |
| `src/libuv/async.sls` (new) | — | `make-uv-async`, `uv-async-send!` |
| `src/libuv.sls` (facade) | — | re-export async verbs + `&uv-wrong-thread` |
| `tests/` | store-and-reraise-under-collect-safe; existing suites regress green | affinity + async suites; stress tier |
| `.plans/decisions/` | ADR-0008 amend | new threading ADR; ADR-0010 companion |

---

# Stage 1 — #19 `__collect_safe`

### Task 1.0 — Branch
`git checkout main && git pull --ff-only && git checkout -b feat/uv-run-collect-safe`.
(The spike lives on `spike/threading-collect-safe`; cherry-pick or merge it, or
land the spike as part of this branch.)

### Task 1.1 — Red: store-and-reraise under collect-safe
The one behaviour T1 did not cover (design §5.2). Add to `test-lifecycle.sps`
(or `test-loop.sps`): a callback that `raise`s a known condition, caught by a
`guard` outside `uv-run`; assert the condition type/fields survive, `uv-run`
returned through its epilogue, the loop is reusable, and counters/registry
return to baseline. This test passes *today* (plain); it is the **regression
oracle** for the conversion — it must stay green after Task 1.2, proving the
collect-safe rebind did not change the escape semantics. Also add a threaded
GC-freedom assertion mirroring spike T2 (worker collects while the loop blocks)
in the **stress tier** (not the default gate).

### Task 1.2 — Green: the conversion
- `native.sls`: `uv_run` → `(foreign-procedure __collect_safe "uv_run" (uptr int) int)`.
- `native.sls:653–747`: add `__collect_safe` to all 13 `foreign-callable` forms.
- No wrapper change (loop.sls:50 stands).
Run `make test`; every existing suite must stay green (the conversion is
invisible single-threaded except for the released interlock).
**Cost note (measured, chez-http-server E5f):** the reactivate/deactivate pair
adds ~60 ns per callback (177–192 ns → 235–249 ns on `uv_idle`), negligible for
I/O-bound callbacks — see design §5.4.

### Task 1.3 — Gate
`make test` (16 suites) + `make test-memory` (ASan) + `make test-memory-docker`
(Linux Valgrind, 0 errors). The store-and-reraise oracle (1.1) green confirms
the escape is unchanged.

### Task 1.4 — ADR-0008 amend + docs
Amend ADR-0008: all trampolines are now `__collect_safe` (cite CSUG §4.3/4.8 and
spike T1); the invariant is otherwise unchanged. Note in `docs/` that `uv-run`
no longer holds the collect interlock, so a second Scheme thread may run
concurrently (and that per-#20 it must still obey loop-thread affinity).

**Stage 1 exits** shippable on its own: a correctness change, no new public
surface, unblocks threaded consumers.

---

# Stage 2 — #20 `uv_async` + enforced affinity

### Task 2.0 — Branch
`feat/uv-async-thread-affinity` off updated `main` (after Stage 1 merges).

### Task 2.1 — Vendor pin: `UV_ASYNC`, `sizeof(uv_async_t)`
- `spike/threading/`: probe `uv_async_*` signatures + coalescing (design §7),
  record in `spike/threading/FINDINGS.md`.
- `src/libuv-shim.c`: add `{ "UV_ASYNC", UV_ASYNC }` and `{ "SIZEOF_UV_ASYNC_T",
  (long)sizeof(uv_async_t) }`.
- `constants.sls`: add both to `snapshot-names` (these are always-present, unlike
  the version-gated `UV_TCP_REUSEPORT`) + accessors `uv-async-type`,
  `sizeof-uv-async-t`. Red: `test-native.sps`'s constant round-trip first fails
  by name, then green.

### Task 2.2 — Red+green: `&uv-wrong-thread` + per-loop affinity
- `conditions.sls`: `&uv-wrong-thread` (subtype `&uv-error`; fields `who`,
  `expected`, `actual`). Red in `test-conditions.sps` (constructor/accessors,
  subtype), then green.
- `handles.sls`: add an owner-thread field to the loop record; `require-loop-
  thread`. Wire it into `require-open-handle` so every verb inherits the check.
- `loop.sls`: set owner at `make-uv-loop`; transfer to the caller at `uv-run`
  entry, under the `loop-running?` guard.
- Red (deterministic, `test-loop.sps` / `test-tcp.sps`): a verb called from a
  non-owning thread raises `&uv-wrong-thread` naming who/expected/actual; owner
  transfers when thread B runs a loop A created; on a non-threaded Chez the check
  is a no-op. Then green.

### Task 2.3 — Red+green: `uv_async` bindings + the 14th trampoline
- `native.sls`: `uv_async_init` `(uptr uptr uptr) int`; `uv_async_send`
  `(uptr) int`; the 14th locked `foreign-callable __collect_safe` for
  `uv_async_cb` `(uptr) -> void`, installed via `install-dispatch-procedure!`
  from `(libuv async)` (the dns/process/signal late-install seam).
- `handles.sls`: async handle record + register/close arms; widen the frozen
  trampoline-name literals (test-loop.sps, test-native.sps) to 14, watched to
  fail first (ADR-0008 amendment procedure).
- `async.sls` (new): `make-uv-async` (loop-thread-only, via `require-loop-
  thread`); `uv-async-send!` — the **exempt** path (validates kind + open, skips
  the thread assertion).
- Red: `(uv-async-send! a)` from a worker thread succeeds; the callback fires on
  the loop thread; `make-uv-async` from a non-owning thread raises
  `&uv-wrong-thread`. Then green.

### Task 2.4 — Tests: deterministic + stress tier
- Deterministic (`test-async.sps`, on the default gate): construction, the
  callback fires on the loop thread, send-coalescing tolerated (N sends ⇒ ≥1
  callback), gating rows, counters/registry balance.
- Stress tier (`test-threading-stress.sps`, OFF the default gate, ADR-0010
  companion): a worker pool posting work via `uv-async-send!` to a loop thread;
  the hazard reproduction (concurrent verb from a worker now raises rather than
  corrupts). Run repeatedly, not on `make test`'s critical path.

### Task 2.5 — Gate + ADRs + facade + release decision
- Facade: re-export `make-uv-async`, `uv-async-send!`, `&uv-wrong-thread`.
- New threading ADR; ADR-0010 companion (design §10).
- `make test` + `make test-memory-docker` green.
- Decide version/CHANGELOG for the arc (§Global constraints).

## Self-review checklist

- [ ] `uv_run` and **all 13→14** trampolines `__collect_safe`; no plain/safe mix.
- [ ] Store-and-reraise oracle green pre- and post-conversion (escape unchanged).
- [ ] Affinity check on one central site (`require-open-handle`); `uv-async-send!`
      is the only exempt verb, and the exemption is explicit and commented.
- [ ] Owner set at `make-uv-loop`, transferred at `uv-run` entry; concurrent
      `uv-run` still refused.
- [ ] `&uv-wrong-thread` raised *before* any registry mutation.
- [ ] 14th trampoline installed via the late-install seam; frozen name literals
      widened, watched-to-fail.
- [ ] Non-threaded Chez: check is a tautology, `uv-async-send!` still works.
- [ ] Default suite flake-free (races confined to the stress tier); Linux
      Valgrind gate clean.
- [ ] ADR-0008 amended; threading ADR + ADR-0010 companion written.
