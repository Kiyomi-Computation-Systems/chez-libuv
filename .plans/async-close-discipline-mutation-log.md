# Async close discipline — the worker-pool stress block

Evidence for `fix/async-stress-close-discipline`, which rebuilds the worker-pool
block of `tests/test-threading-stress.sps` (the "driver's real shape", design
§6.1) on the close discipline `(libuv async)` requires. Nothing in `src/`
changes.

Every probe and mutation ran on a scratch copy outside the repo. Unless a line
says otherwise: macOS, Chez 10.4.1 (`tarm64osx`), libuv 1.52.1 via pkg-config,
the dev build. Linux runs used the `chez-libuv-valgrind:10.4.1` image (Debian
bookworm, aarch64, vendored libuv 1.52.1, `HAVE_PKG=no`), with `git` shimmed
to a no-op for the submodule steps: a worktree's `.git` is a pointer file the
container cannot resolve, and the submodules were already checked out.

---

## The defect

The old block: 4 workers × 25 items. A worker queued its item under the queue
mutex, then called `uv-async-send!` outside it, catching only
`&uv-handle-closed`. The wake callback drained the queue and called
`uv-close!` as soon as all 100 items were delivered. Nothing joined the
workers.

`uv-async-send!` (`async.sls`) checks the handle's state, then reads its
pointer, then calls `uv_async_send`. The close runs on the loop thread:
`uv-close!` marks the handle `closing` and calls `uv_close`, which for an
async runs `uv__async_close` at once (`unix/core.c:194`); `close-dispatch`
then frees the block, zeroes the pointer and marks it `closed` from
`uv__run_closing_handles`, at the end of the same `uv_run` iteration
(`unix/core.c:475`). libuv's `uv__async_spin` waits only for a sender already
inside `uv_async_send` (its `busy` count, `unix/async.c`); it cannot see one
that has passed the Scheme check and not yet made the call. So a straggler
could:

- **(a)** read `open` and the pointer, then call `uv_async_send` on the freed
  block;
- **(b)** read `open`, then read the zeroed pointer: `&uv-invalid-argument`
  `null-handle-pointer`, which the worker's guard does not catch;
- **(c)** send after `uv-loop-teardown!`, since nothing waited for it.

### Red: the window, widened

Two scratch copies of `src/` whose `uv-async-send!` sleeps 2 ms:

- **W1** — between the open-state check and `handle-pointer`;
- **W2** — after `handle-pointer`, before the native `uv_async_send`.

Probe: the old block verbatim, run R rounds in one process. Two additions,
only so the probe can count: each worker records any raise that escapes its
`uv-handle-closed?` guard, and the probe joins the workers after teardown.

| library    | rounds | rounds with an escaping raise | what escaped |
|------------|-------:|------------------------------:|--------------|
| unmodified |   2000 |                             0 | — |
| W1         |     20 |                            20 | `&uv-invalid-argument`, `who: uv-async-send!`, `reason: null-handle-pointer` |
| W2         |     20 |                            19 | `Exception: invalid memory reference` — the native send on the freed block |

Across all 2040 rounds the guard the old comment relied on, a
`&uv-handle-closed` refusal, fired zero times. The race is structural and, at
its natural width, rare (0/2000).

### Why the old suite could not see it

- An uncaught raise in a Chez `fork-thread` kills only that thread. A probe
  that raised in a worker printed `Exception: boom in worker`; the main
  thread carried on and the process exited 0.
- The old suite file itself, run against W1 and against W2: 3/3 runs each
  exited 0 with `# of expected passes 6` and printed nothing at all. The
  process exits before the unjoined stragglers wake: (c) hides (a) and (b).
- With a 50 ms pause inserted before `test-end`, the same runs print the
  worker exceptions (W1: `null-handle-pointer`, 1–4 per run; W2: `invalid
  memory reference`, 1 per run) and still exit 0 with 6 passes.

The old block passed whether or not a send raced the close.

---

## The fix

The block now follows the discipline `docs/api.md`'s Async section documents
(#30):

- A worker holds `qm` while it checks `open?`, queues its item, and calls
  `uv-async-send!`, so every send, from its open check to its native call,
  happens inside the lock.
- The loop thread clears `open?` under `qm`, then calls `uv-close!`, then
  drains once more. `on-wake` never runs once a close has started, even for a
  send made before it.
- The main thread joins every worker (a mutex and a condition) before
  `uv-loop-teardown!`.

Three test-design choices make the rows able to fail:

- **Workers post until refused**, so every worker meets the close mid-stream,
  and "refused" is an outcome only the cleared flag can produce. A cap bounds
  a worker that is never refused (a failure, reported as `never-refused`).
- **The close waits for a wake that finds items queued**, and does not drain
  them first, so the drain after `uv-close!` always has work. Without that
  condition about 3% of natural closes found the queue empty (M9 below),
  which would leave the final drain unexercised in that round.
- **The pool runs 30 rounds**, fresh each time, and each row requires its
  property in every round. A discipline slip loses its race only in some
  pools (M2, M3, M6 below), and 300 rounds cost under 0.25 s more than one.

Four rows, each a sentinel on success and the evidence otherwise:

1. the loop thread closed the async with posts still queued (the
   precondition: the queue was non-empty at every close, so rows 3 and 4 are
   not vacuous);
2. every worker posted until the close refused it, and no send raised;
3. a worker pool delivers every accepted item exactly once through one async
   handle (per worker, the delivered sequence numbers sorted equal
   `0 .. accepted-1`);
4. the shared queue is fully drained.

---

## Green

- `make test`: all 17 suites pass. `make test-threading`: 8 expected passes
  (the old block contributed 2 rows; this one contributes 4).
- The final suite, macOS: 30/30 runs green. Before the review follow-up, 50/50
  and 30/30.
- The final suite, Linux: 30/30 at 8 vCPU, 30/30 under `--cpus=2`.
- The final suite with `rounds` set to 1, against **W1** and **W2** — the
  widened windows that broke the old block in 20/20 and 19/20 rounds: 5/5
  green on each, no thread exception printed. (One round takes ~16 s there,
  every send holding `qm` for 2 ms, so 30 rounds would outrun any sane
  timeout; the rounds only repeat the same discipline.)

---

## Mutations

Each mutation was applied to a scratch copy of the final
`tests/test-threading-stress.sps` (after the review follow-up below) and run
against the unmodified library. Counts are failing runs out of runs; every
failure was a `FAIL` line naming the row, never a crash or a hang, and no run
printed a thread exception. The unmutated copy, run alongside: 30/30 green.
Before the review follow-up the same sweep failed the same rows, except that
M6 also failed row 3 in 4 of 30 runs.

Rows: **1** closed with posts still queued · **2** every worker refused, no
send raised · **3** every accepted item delivered exactly once · **4** the
shared queue is fully drained.

| #  | Mutation | Decision it breaks | Rows that failed |
|----|----------|--------------------|------------------|
| M1 | the drain after `uv-close!` skipped on the closing wake: `(unless closing? (deliver! …))` | drain once more after the close | 3: 10/10 · 4: 10/10 |
| M2 | `open?` cleared after `uv-close!`, not before it | clear the flag, then close | 2: 30/30 · 3: 30/30 |
| M3 | `uv-async-send!` moved out of `qm`: check and enqueue under it, send after | send while holding the lock | 2: 30/30 · 3: 30/30 |
| M4 | `open?` not cleared by the closing wake | refuse senders before the close | 2: 30/30 · 3: 30/30 · 4: 30/30 |
| M5 | `take-queue!` does not reset the queue | a drain takes each item once | 3: 10/10 · 4: 10/10 |
| M6 | the join removed | wait for every worker before teardown | 2: 30/30 |
| M7 | the item consed onto `queue` outside `qm` (flag check and send still under it) | enqueue under the lock | 2: 30/30 · 3: 30/30 · 4: 30/30 |
| M8 | close condition `(pair? queue)` negated to `(null? queue)` | close only with items queued | 1: 10/10 |
| M9 | close condition `(pair? queue)` removed | close only with items queued | 1: 14/20 |

How the probabilistic ones fail:

- **M2, M3, M4.** A send that meets the close sees the handle `closing` and
  raises `&uv-handle-closed` (row 2). Its item was already queued, so the
  final drain delivers an item its worker never counted as accepted (row 3).
  Under M4 the flag is cleared only after `uv-run` returns (the follow-up's
  post-run clear), and workers keep posting until then.
- **M6.** The rows read `results` before every worker has recorded its
  outcome (row 2). Before the follow-up, 4 of 30 runs also read `accepted`
  before a worker's last write (row 3).
- **M9.** Without the condition, a close finds the queue empty in about 3% of
  rounds (30 of 50 runs failed across three batches, at 30 rounds a run).

**Why 30 rounds.** With `rounds` set to 1, final text: M2 10/20, M3 5/20, M6
6/20, M4 20/20. Earlier shapes of the same block measured M2 8/20, 7/20 and
10/20, M3 6/20 and 2/20, M6 8/20, 11/20 and 8/20. At 10 rounds, M3 was caught
in 18/20 runs; at 30, every probabilistic mutation above was caught in every
run.

---

## Review follow-up — failure paths

A `/code-review` pass found three ways the block's own plumbing could hang or
blow up where it should fail a row, plus a duplicated helper. Each was
reproduced against the reviewed commit, fixed, and re-run. The probes are
scratch copies of the suite with one failure injected. "Before" is the
reviewed text: the mechanism below, absent.

| Probe: the failure injected | Before | After |
|---|---|---|
| `cap` 10, so no close can come (4 × 10 < 400) | hangs; killed at 30 s (rc 124), no `FAIL` line | row 2 fails by name, 0.74 s |
| every worker raises at item 50 | hangs; rc 124 | row 2 fails by name, 0.73 s |
| worker 0 raises an object whose printer raises | the worker dies (`Exception occurred with non-condition value cannot-print`), the join waits; rc 124 | row 2 fails by name, 0.73 s |
| `on-wake` raises after 100 deliveries | rows 1–4 fail only after every worker posts to `cap`: 1.49 s, 189 MB peak (1 round); 23.5 s, 595 MB (30 rounds) | rows 1, 3, 4 fail by name: 0.70 s, 49 MB (1 round); 0.79 s, 49 MB (30 rounds) |

A normal run: 0.72 s, 52 MB peak.

- **A worker that stops unrefused wakes the loop.** It raised, or it reached
  `cap`; either way it bumps `stopped-early` and wakes the loop thread, under
  the discipline, and `on-wake` closes at once when `stopped-early` is
  positive. The review named only the cap. The second probe showed that a
  worker that raised leaves the loop waiting the same way. The wake is
  guarded and its failure dropped: it can raise only when the discipline is
  already broken (the handle closing under an open flag, as in M2 and M4),
  and the worker's outcome has recorded the failure by then.
- **The flag is cleared after `uv-run` returns**, under `qm`, before the join.
  The closing wake has already cleared it on the normal path. After a raise
  it refuses the workers before teardown closes the async.
- **`describe` is total and shared.** A raise while printing the raised
  object yields a fixed string. It moved to top level, and the GC-freedom
  block uses it too; that block's worker had the same exposure, since a raise
  escaping its handler skipped `worker-done`. With that block's `(collect)`
  made to raise, both of its rows fail by name.

These mechanisms matter only once something else has already failed, so no
row can observe them on a healthy library. The probes above are their
evidence.

---

## The cap

A worker still unrefused after `cap` posts stops and fails row 2. Workers spin,
so a loop thread that loses the queue mutex for a while lets them run ahead;
the cap must sit far above that. The busiest worker in one round, per
300-round run (a scratch probe reporting the per-round maximum):

| where                         | runs × rounds | busiest worker, per run |
|-------------------------------|---------------|-------------------------|
| macOS                         | 3 × 300       | 1295 – 2871 |
| Linux, 8 vCPU                 | 13 × 300      | 911 – 20143 |
| Linux, `--cpus=2`             | 10 × 300      | 921 – 11125 |

20143 is a fifth of the 100000 the block was first written with, so the cap is
1000000. It binds only on a failure path, where it bounds memory: at most four
million queued items, roughly 130 MB by arithmetic, if the loop thread stops
draining altogether.

---

## Not covered

- **M9, removing the "items queued" close condition**, is caught only when a
  round's close happens to find the queue empty. The condition is a
  guarantee the natural shape usually does not need; M8, which does break
  the property, is caught every run.
- **The widened window is a probe, not part of the suite.** Nothing in the
  suite widens it, so a regression that moves a send outside `qm` is caught
  through its symptoms at the natural width: a send that meets the close
  raises `&uv-handle-closed` (rows 2 and 3). The use-after-free itself is
  observed only with W2.
- **`async.sls`'s own decisions** are `tests/test-async.sps`'s to guard. This
  block claims none of them.
- **The failure-path plumbing** (the early-stop wake, the post-run clear, the
  total `describe`) is covered by the review follow-up's probes, not by the
  suite: removing any of it changes nothing a healthy run can see.
- **Deferred from the review:** the close discipline is the caller's to
  implement (`async.sls` fences nothing), so every consumer re-implements it;
  a library-level sender fence would move it below the API. Two invariants
  here remain comments ("with qm held", "each worker writes only its own
  slot"). Row 1 is guaranteed by the close condition it sits beside, so it
  checks that condition, not the library.
