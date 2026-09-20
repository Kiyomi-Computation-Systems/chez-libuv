# Threading Stage 2 (#20) — mutation log

Red-first evidence for `feat/uv-async-thread-affinity`, per the plan's global
constraints. Each behavioural change lands as a failing test first (unbound
identifier or wrong outcome), confirmed red, then made green. Newest last.

Design: `.plans/2026-09-19-chez-libuv-threading-design.md` (§6, D3/D4).
Plan:   `.plans/2026-09-19-chez-libuv-threading-plan.md` (Stage 2).

## Deviations from the plan text (justified against the actual code)

- **No `SIZEOF_UV_ASYNC_T`.** The plan (Task 2.1) named it, but every existing
  handle kind (tcp/timer/pipe/process/signal) is sized at runtime via
  `(uv-handle-size (uv-<kind>-type))` — libuv's `uv_handle_size()` — and none
  adds a `SIZEOF_UV_*_T`. Signal is the precedent (v0.4 added `UV_SIGNAL` only).
  Async follows it: `UV_ASYNC` in the constant table + snapshot + accessor, and
  `(uv-handle-size (uv-async-type))` for allocation. One fewer constant, no new
  pattern.
- **Enforcement surface = `require-open-handle` (operational verbs) +
  `make-uv-async` (construction).** The design's "one central site" is
  `require-open-handle`; construction can't use it (the handle does not exist
  yet), so `make-uv-async` calls `require-loop-thread` directly, exactly as the
  design §6.1 mandates for it. `require-open-loop` is deliberately NOT the site:
  `uv-run` calls it *before* transferring ownership, so a check there would
  break the create-on-A / run-on-B handoff the worker-pool driver needs.
  `uv-close!`/loop-verbs keep their existing guards (documented in the ADR as
  the scope boundary).

## Entries

### A — `UV_ASYNC` constant + `uv-async-type` (Task 2.1)

- **Red:** `test-native.sps` "UV_ASYNC is snapshotted and distinct…" →
  `Exception: attempt to reference unbound identifier uv-async-type`.
- **Green:** `src/libuv-shim.c` adds `{ "UV_ASYNC", UV_ASYNC }`;
  `constants.sls` adds `UV_ASYNC` to `snapshot-names`, exports and defines
  `(uv-async-type)`. Rebuilt shim; test-native 260/260, exit 0.

### B — `&uv-wrong-thread` condition (Task 2.2a)

- **Red:** `test-conditions.sps` new section →
  `Exception: attempt to reference unbound identifier make-uv-wrong-thread`.
- **Green:** `conditions.sls` adds `&uv-wrong-thread` (subtype of `&uv-error`;
  fields who/expected/actual) + exports. Pure suite: test-conditions 115/115,
  exit 0 (purity preserved — no native import added).
