# Async send fence (#33): mutation log

Evidence for `fix/async-send-fence` (#33). `uv-async-send!` checked that the
handle was open, read its pointer, then called `uv_async_send`. A close on the
loop thread could free the block in between. Each async handle now has a send
fence (`with-send-fence`), which the send and the close both take.

Every probe and mutation ran on a scratch copy outside the repo. macOS runs:
Chez 10.4.1 (`tarm64osx`), libuv 1.52.1 via pkg-config, the dev build. Linux
runs: one long-lived container of the `chez-libuv-valgrind:10.4.1` image
(Debian bookworm, aarch64, vendored libuv 1.52.1, `HAVE_PKG=no`), built from a
`--no-hardlinks` clone. The Linux Valgrind runs used the real `test-memory`
recipe (`make test-memory MEMORY_TESTS=…`) or, for probes, its exact flags.

Mutations were exact text replacements that abort unless the target occurs
exactly once, re-checked after the write. After one harness slip (a call
missing its file arguments ran an unmutated copy, which passed), the harness
was changed to delete a half-made mutant and to refuse to run a missing one.
No other run was affected: every other mutant reported "ready".

---

## Red: the engine sweep on main (e79996c)

`tests/test-async-fence.sps`'s sweep steps `uv-async-send!` inside an engine
with fuel 1, 2, … 200. Wherever the engine is suspended, the sweep polls the
loop (`'nowait`, at most 8 times) to learn whether the send's native call has
already run, closes the handle, runs the loop once (the close callback frees
the block and zeroes the pointer), then resumes the send.

The oracle differs from the #33 review's. The review's could not tell a stale
send from a legitimate late return, so Linux native was blind. Here, a send
that returns normally must have had its wake land before the close. A stale
send returns normally with no wake, and that is visible on every platform.

Probe output on main (both platforms, 2 runs each, identical):

| fuel | macOS | Linux native |
|---|---|---|
| 1–7 | resumed, refused, no wake | resumed, refused, no wake |
| 8 | resumed, `invalid memory reference` | resumed, **sent, no wake before the close** |
| 9–120 | finished, sent, woke | finished, sent, woke |

The suite on main, first row, both platforms: FAIL by name. macOS evidence:
`((8 resumed "Exception: invalid memory reference.  Some debugging context
lost" no-wake-before-close))`. Linux: `((8 resumed sent
no-wake-before-close))`.

## The build-order check caught the new import

Adding `(only (chezscheme) make-mutex with-mutex with-interrupts-disabled)`
to `handles.sls` without the refusal ahead of it failed
`tests/test-require-threaded.sps` by name: "src/libuv/private/handles.sls
imports (libuv private require-threaded) before (chezscheme)". The import
went in after the refusal, and that suite now holds 17 rows.

## Green, step by step

1. **Sender fenced, closer not yet.** The sweep passes on both platforms. The
   fenced fuel map: 1–11 refused, 12 sent before the close (suspended after
   the native send, which woke the loop), 13+ finished. All three kinds of row
   occur.
2. **The three two-thread rows written.** The closer row failed 3/3 runs:
   `(closing torn-down)`, with the main thread holding the fence while the
   loop's owner closed. The handler and collection rows passed; they pin
   decisions already made, and their red is the mutations below.
3. **Closer fenced.** 5/5 rows, 3/3 runs on each platform.

## Mutations: `tests/test-async-fence.sps`

Each mutant ran on both platforms. "Row" names the row that failed.

| | mutation | macOS | Linux native |
|---|---|---|---|
| M0 | none (control) | 5 pass | 5 pass |
| M1 | sender unfenced: main's shape | sweep row: fuel 8, `invalid memory reference` | sweep row: fuel 8, sent with no wake |
| M2 | fence as first proposed: `with-mutex`, no `with-interrupts-disabled` | sweep row: fuel 10–11, `invalid memory reference` | sweep row: fuel 10 `invalid memory reference` (NULL pointer), fuel 11 sent with no wake |
| M3 | closer unfenced | closer row: `(closing torn-down)` | closer row: `(closed torn-down)` |
| M4 | refusal raised inside the fence | handler row: `held` | handler row: `held` |
| M5 | interrupts disabled before the fence is taken | collection row: "cannot collect when multiple threads are active" | same |
| M6 | wrong refusal (`&uv-invalid-argument`) | sweep row, reach row (`never-refused`), handler row | same |
| M7 | open check outside the fence | sweep row: fuel 8–11, `invalid memory reference` | same |
| M8 | sweep fuel capped at 5 | reach row: `(refused (5 . refused))` | same |
| M9 | no wake polls | sweep row (every finished row "no-wake") and reach row | same |
| M10 | sweep starts at fuel 20 | reach row: `(never-refused finished)` | same |

M3, M4 and M5 fork threads: 5/5 runs of each failed by name on each
platform, and M0 passed 5/5 on each.

Two runs needed fixing before they counted:

- **M3's first run proved nothing.** Its replacement text dropped a
  parenthesis, and the copy died at import ("missing definition for multiple
  exports"). Rerun with the corrected text: the table's result.
- **M5 first hung, silently, until the 120 s probe timeout.** The closer
  row deadlocked:
  - the main thread held the fence and allocated, which requested a
    collection;
  - the collection waited for the closer thread, blocked on the fence with
    interrupts disabled and so still active;
  - the closer waited for the fence.

  That is the defect M5 plants, but it has to fail the row that checks for
  it, by name. The fix is `while-holding-fence`, which puts off
  allocation-triggered collection while a row holds the fence (the stress
  suite's bulk-copy block does the same). On a correct build, a thread
  blocked on the fence is deactivated and no row can deadlock this way.

### Counterfactuals: decisions no row holds, by design

| | mutation | result | why it is not a safety property |
|---|---|---|---|
| C1 | the closer takes the fence with plain `with-mutex` | 5 pass, both platforms | The close's move is three field operations. If an engine suspends it, the fence is released, and a send that runs meanwhile sees the handle open and completes before `uv_close` starts. No send can be between its check and its call when the close begins. |
| C2 | one fence for every async in the process | 5 pass, both platforms | Only contention changes: senders to different handles would take turns. |

### Injected failures: the rows fail, they do not hang

| | injection | result (both platforms) |
|---|---|---|
| F1 | the closer thread raises before reaching `uv-close!` | closer row: `(open (raised "injected-closer-failure"))` |
| F2 | the probe thread raises | handler row: `(raised "injected-probe-failure")` |
| F3 | the sender thread raises before reaching the fence | collection row: `(collected (raised "injected-sender-failure"))` |
| F5 | the careless pool's `on-wake` raises | stress suite: "a careless pool's loop closes its async while workers send" fails; 11 others pass |
| F6 | every careless worker raises after 10 sends | stress suite: "every careless sender is refused …" fails; 11 others pass |
| F6b | F6, without the pool's close-on-failure (a worker ending unrefused sends one more wake, and `on-wake` then closes) | **hangs**, killed at 60 s |

F6b is why the careless pool has that logic.

## Valgrind (Linux, the real `test-memory` recipe)

| tree | exit | Memcheck | suite |
|---|---|---|---|
| fenced | 0 | 0 errors; 2,539 allocs; definitely lost 0 | 5 pass |
| M1 | 2 (make) | 1 × `Invalid read of size 4 at uv_async_send … 120 bytes inside a block of size 128 free'd` | sweep row fails by name |
| M2 | 2 (make) | 2 × `Invalid read of size 4 at uv_async_send`: `Address 0x78` (NULL + 120) and 120 bytes inside a freed block of 128 | sweep row fails by name |

Each async now owns a Chez mutex. The fenced run's "definitely lost: 0" shows
they do not leak under the definite-only gate.

## The cross-thread half, widened

`careless-pool.sps` (scratch) is the stress suite's careless block. It runs K
= 4 workers that send with no lock of their own, and the loop thread closes
at the 50th wake. The widened copies sleep 2 ms inside the send's critical
section, between reading the pointer and `uv_async_send`, or at the same
place in main's shape.

| send path | macOS, 3 × 10 rounds | Linux native, 10 rounds | Linux Valgrind, 3 rounds |
|---|---|---|---|
| fenced, widened | 10/10 clean, every run | 10/10 clean | exit 0, 0 errors |
| closer unfenced, widened | 0/10 clean, every run: an `invalid memory reference` escapes in each round | 10/10 "clean" | exit 9, 3 × invalid read in the freed 128-byte block |
| main's shape, widened (#32's W2) | 0/10 clean, every run | 10/10 "clean" | — |

- **Linux native is blind here.** The stale sends return normally, so the
  in-process accounting passes while Memcheck reports the invalid reads. The
  #33 review saw the same.
- **The default gate's witness is the closer row.** It sees the fence
  protocol itself on every platform.
- **At natural width the race does not show.** The careless pool ran clean
  in 30/30 rounds against both main's shape and the fence (macOS, 2 runs
  each). So the stress block is a check that the fence holds under
  contention: four senders and a closer, with no deadlock and no other
  raise. It is not the witness for a missing fence.

## Cost

Scratch bench: 1M `uv-async-send!` on one async, on libuv's fast path (the
pending flag is already set, so no send makes a syscall), 5 runs each.

| ns per send | main | fenced |
|---|---|---|
| macOS, 1 thread | 7.9–8.1 | 41.6–42.2 |
| macOS, 4 threads | 2.2–2.8 | 106.6–118.3 |
| Linux (Docker, arm64), 1 thread | 8.0–8.1 | 89.7–95.4 |
| Linux (Docker, arm64), 4 threads | 2.3–2.7 | 170.0–178.5 |

These are close to the #33 review's prototype (47–48 and 114–120 ns on
macOS). A send that takes libuv's slow path makes a `write` or `kevent`,
which costs far more than the fence.
