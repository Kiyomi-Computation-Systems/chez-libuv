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

### C — enforced per-loop thread affinity (Task 2.2b)

- **Scaffolding (no behaviour yet):** `native.sls` `current-thread-id`
  (`threaded?`-guarded `get-thread-id`); `handles.sls` loop `owner-thread`
  field (set to the creating thread in the protocol) + `require-loop-thread`;
  `loop.sls` transfers the owner to the caller at `uv-run` entry; facade
  re-exports `&uv-wrong-thread`.
- **Red:** `test-async.sps` affinity section with `require-loop-thread` NOT yet
  wired into `require-open-handle` → the two refusal rows FAIL (verb returns
  `'no-raise`); the positive control and the uv-run-transfer row pass. 2 passed
  / 2 failed.
- **Green:** wired `(require-loop-thread (handle-loop handle) who)` into
  `require-open-handle` (thread check first, before the open-state check).
  test-async 4/4. Full `make test` = 17/17 suites (the check is invisible to
  every existing single-threaded suite: owner == caller always). check-purity
  still holds.

### D — uv_async wakeup, 14th trampoline, make-uv-async/uv-async-send! (Tasks 2.3–2.4)

- **Red (frozen literals, ADR-0008 amendment procedure):** widened the
  dispatcher-names literal to 14 (+`async`) in test-loop.sps and test-native.sps,
  the live-counts class list to 13 (+`async`) and the counter matrix (+`async`
  row) in test-native.sps, and added an "async slot holds the raising
  uninstalled stub" row. test-loop → `FAIL dispatcher-names names the fourteen…`;
  test-native → `unbound identifier count-async-free!`.
- **Green:** shim async counters (both arms + header); native.sls async counter
  procs + `async` in dispatcher-names + `uv_async_init`/`uv_async_send` bindings
  + the 14th `__collect_safe` trampoline (`async-callable`, locked,
  `async-cb-entry`) + `uv-async-init-native`; handles.sls `uv-async-record` +
  `async` in handle-kinds + `count-async-free!` arm; handle.sls `uv-async?`;
  new `(libuv async)` (`make-uv-async` loop-thread-only via `require-loop-thread`,
  `uv-async-send!` exempt, `async-dispatch` late-installed); facade re-exports.
  Rebuilt shim. test-native 266, test-loop 138.
- **Behaviour tests (test-async.sps, default gate, deterministic — no fork):**
  construction + counter balance across close; same-thread send delivers a wake
  callback receiving its own handle; N sends → 1..N callbacks (coalescing
  tolerated); `make-uv-async` off-owner raises `&uv-wrong-thread`;
  `uv-async-send!` succeeds while the loop is owned elsewhere (the exemption,
  proved fork-free); send on a closed async → `&uv-handle-closed`; send on a
  non-async → `&uv-invalid-argument`. test-async 12/12.
- **Gate:** full `make test` 17/17; macOS ASan gate RC 0, no sanitizer errors
  (leak claim deferred to Linux Valgrind per ADR-0003).

### E — async worker-pool stress tier (Task 2.4, ADR-0010 companion)

- Extended `test-threading-stress.sps` (off the default + memory gates) with
  three real-thread blocks: (1) a genuine worker thread's handle verb is refused
  with `&uv-wrong-thread`; (2) a loop run by thread B is owned by B (real owner
  transfer); (3) a K=4 × M=25 worker pool posts 100 items through one async
  handle whose callback drains the whole queue each wake — every item delivered
  despite coalescing, queue fully drained. The straggler send-after-close race
  is expected and caught (`uv-handle-closed?`) in the worker; nothing is lost
  because close ⟺ all delivered.
- **R6RS fix:** the worker-pool `let` initially placed `(set! async …)` before
  `(define (worker …))` → `invalid context for definition`. Reordered defines
  first. Stress suite 6/6, stable across repeated runs.
