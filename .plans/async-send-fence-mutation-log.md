# Async send fence (#33): mutation log

Evidence for `fix/async-send-fence`. Two fixes to one code path, `uv-close!`
against a second party:

- **Send against close (#33).** `uv-async-send!` checked that the handle was
  open, read its pointer, then called `uv_async_send`. A close on the loop
  thread could free the block in between. Each async handle now has a send
  fence (`with-send-fence`), which the send and the close both take.
- **Close against close.** Two `uv-close!` calls on one handle, interleaved by
  an engine, could both see it open and both call `uv_close`. Found while
  restructuring the close for the fence. The open check, the move to closing
  and `uv_close` are now one step with interrupts disabled, for every kind of
  handle.

**Read "The reworked fence", at the end, first.** The first fence shape,
`with-mutex` around `with-interrupts-disabled`, passed everything in the
first half of this log. PR #43's review then found that it held the fence
across an engine suspension, and that a collection could deadlock on it. It
was replaced. The first half stays as the record of what the first shape's
tests could and could not see; where a claim there no longer holds, the last
section says so.

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

## Close against close

Probe (scratch): an engine runs `(uv-close! h cb-first)`. Where it is
suspended, `(uv-close! h cb-second)` runs, then the engine resumes. The
second close's move is detected by its callback being stored; the first
close replacing it means both moved, so `uv_close` ran twice.

- **On main:** fuel 4 double-closes a timer and an async alike.
- **Running the loop after a double close** (timer, fuel 4, 2 runs each):
  - macOS: one close callback, then `invalid memory reference`;
  - Linux: `uv_run` hangs, killed at 20 s.
- **On this branch** the probe was clean before the explicit fix:
  - the async by design, since its move runs inside the fence's
    interrupt-free body;
  - the timer by accident: `begin-close!`'s helper happens to compile with no
    suspension point between the check and the move.

`tests/test-timer.sps` now sweeps this for a timer and an async, with a
reach row for each. A row that sees a double close answers its evidence and
leaks its loop rather than run it.

| | mutation | result, both platforms |
|---|---|---|
| D1 | main's close shape: inline check, then two `set!`s | both sweep rows fail by name; the three balance rows fail too, from the leaked loops |
| C3 | the timer path without its explicit `with-interrupts-disabled` | 132 pass: an equivalent mutation, as the accident above predicts |

The explicit `with-interrupts-disabled` guarantees what the helper's code
generation gives today by accident. No mutation can observe that choice on
Chez 10.4.1 at the default optimize level, so it is uncovered by design. D1
shows the sweep catches a move that is split.

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

---

## The reworked fence (after PR #43's review, 2026-09-28)

### What the review found in the first shape

The first shape was `(with-mutex fence (with-interrupts-disabled body))`.
Measured by the review's finders and verifiers (probes in its scratch
directories), on Chez 10.4.1:

- **The fence was held across an engine suspension.** `with-mutex` releases
  in a `dynamic-wind` exit thunk, after the winder is gone and after
  `with-interrupts-disabled` has re-enabled interrupts. Its entry is a trap
  check, so an engine whose fuel ran out there was suspended holding the
  fence: the send at fuel 12 in the sweep's setup, the close at fuel 10–15
  depending on the setup.
  - An engine abandoned there kept the fence for good. The loop thread's
    `uv-close!` stayed blocked past 3 s, and so did a worker's send.
  - Resuming the engine on another thread raised "mutex-release: thread does
    not own mutex".
- **A collection could deadlock on it.** Give a caller its own
  `with-interrupts-disabled` around a send, or send from a
  `collect-request-handler`. Such a caller waited for the fence while still
  active, while the holder was parked at a collection rendezvous at that same
  exit edge. The process hung, where main (no lock) finished.
- **Other gaps:**
  - no row made a real sender wait on the fence;
  - nothing checked the release after a success or a close;
  - `uv_close` ran outside the close's atomic step, a window main had too;
  - `make-mutex` ran after `uv_async_init`, outside its guard;
  - the send read its pointer raw.

### The new shape

`(disable-interrupts) (mutex-acquire fence) body (mutex-release fence)
(enable-interrupts)`, with no `dynamic-wind`.

- The close's open check, move to closing and `uv_close` are one step: inside
  the fence for an async, and with interrupts disabled for every kind.
- The steps check the state and the pointer and answer a status. The caller
  raises after the release.

The measured facts it rests on:

- **`with-interrupts-disabled` and `critical-section` both expand to a
  `dynamic-wind`.** Their closures allocate once they capture locals.
- **`enable-interrupts` does not take a pending engine timer itself.** An
  engine whose fuel ran out with interrupts disabled is suspended at the next
  trap check (probe: it finished instead, since no trap check followed).
- **Fuel maps, where the engine is suspended:**

  | | first shape (328dc8a) | new shape |
  |---|---|---|
  | `uv-async-send!` | 1–11 before the call; **12 after the call, fence held**; 13+ finished | 1–7 before the call; 8+ finished |
  | `uv-close!` (async) | 1–9 open; **10–12 closing**; 13+ finished | 1–5 open; 6+ finished |

  In the new shape nothing in either verb can be suspended after its step.
- **A waiter stays active.** It blocks in `mutex-acquire` with interrupts
  disabled. The holder is always inside a step that never waits, so the wait
  is short and no collection is ever waiting on the holder.

### Red on the first shape, green on the new

The new rows, run against 328dc8a:

- **test-async-fence:**
  - "no send is suspended by an engine while it holds the fence":
    `((12 sent-before-close held))`;
  - "no close is suspended …": `((15 closing held))`;
  - the pointer row: `((raised "Exception: invalid memory reference…")
    (uv-close! null-handle-pointer))`.
- **test-timer:** every suspension after the close's mark was a split,
  `(12 split-close closing 0) (13 …)` for a timer and `15–17` for an async.

On the new shape the fence suite passes 11 rows and test-timer 132.

The reach rows at first also required a suspension after the step, where the
first shape held the fence. The new shape has none (the fuel map above), so
the reach rows now require a suspension before the step and a run to the end.

### Mutations

Every mutant ran on macOS and Linux native.

| | mutation | result, both platforms |
|---|---|---|
| N0 | none (control) | fence 11 pass; timer 132 pass |
| N1 | the first shape: `with-mutex` around `with-interrupts-disabled` | "no send … holds the fence" `((12 sent-before-close held))` and "no close …" `((15 closing held))`; test-timer passes, since that shape kept the close's step whole |
| N2 | release after re-enabling interrupts | 11 pass: equivalent on 10.4.1, since nothing between the two calls is a trap check |
| N3 | acquire before disabling interrupts | 11 pass: equivalent, for the same reason |
| N4 | the send skips the mutex, keeping interrupts disabled | "uv-async-send! waits …": `(returned-while-held sent)` |
| N5 | the async close skips the fence | "uv-close! waits …": `(closing torn-down)`, or `(closed torn-down)` on Linux |
| N6 | the refusal raised inside the fence | handler row `held`; release row `(free free held held)`; the close-sweep reach row fails too, because a raise inside the fence leaves interrupts disabled |
| N7 | no pointer check in the send | pointer row: `(raised "…invalid memory reference…")` |
| N8 | no pointer check in the close | pointer row: `(raised "…invalid memory reference…")` for the close |
| N9 | `uv_close` outside the step (the old split) | test-timer: timer and async rows, `(11 split-close closing 0) (12 …)` |
| N10 | the timer path's step with interrupts on (the first half's C3) | test-timer: `(11 both-closes-began) (12 split-close closing 0) …`, plus the balance rows from the leaked loop |
| N11 | the async close with plain `with-mutex` (the first half's C1) | "no close …" `((17 closing held))`; test-timer's async row `(14 both-closes-began) …` |
| N12 | a repeated close leaves the fence held | release row `(free free free held)` |
| N13 | a successful send leaves the fence held | "uv-async-send! waits …" `(waiting sent fence-left-held)`; release row `(held held held held)` |
| N14 | the probe answers `free` without trying | only the probe-liveness row: `(free free)` |
| N15 / N16 / N17 | send sweep capped at 3; close sweep capped at 3; both sweeps started at fuel 30 (they share `sweep-rows`) | the matching reach rows fail by name; N17 fails both |
| R1 / R2 | test-timer's close sweep capped at 5; started at fuel 20 | both reach rows: `(second-began second-began)` / `(never-caught-before-the-step finished)` |

N0, N4, N5 and N13 fork threads, and each gave its predicted result in 5 of 5
runs on each platform.

Two runs needed fixing before they counted:

- **N13 first hung, in 3 of 8 runs, instead of failing.** A stack sample
  showed main alone, blocked in `mutex-acquire`: the cleanup's `uv-close!`
  was waiting on a fence left held by the sender thread, which had exited.
  The probe had answered `free`, because it ran on a fresh thread. Chez
  treats a thread whose id matches a mutex's recorded owner as its owner, and
  a new thread can be given an exited thread's id. Measured: 20, 19 and 20 of
  20 new threads (macOS twice, then Linux) took, without blocking, a mutex a
  dead thread still held.
  - The probe is now one thread that lives as long as the suite, so no holder
    can share its id. The sender row also reports a held fence instead of
    closing into it.
  - Since then N13 fails by name in 10 of 10 runs.
- **N14's first version made the probe release a mutex it did not hold.**
  It proved nothing. The version above makes the probe simply answer `free`.

### The review's deadlock reproducers

| reproducer | first shape | new shape |
|---|---|---|
| one sender allocates; another sends inside its own `with-interrupts-disabled` | hung 3/3, killed at 30 s | finished 3/3 in 3 s, up to 38M sends |
| two senders plus an allocator, with a `collect-request-handler` that sends | hung 3/3, killed at 30 s | finished 3/3, 188 collections |

### The widened window, again

The careless pool, with a 2 ms sleep inside the send's step:

| send path | macOS | Linux under Valgrind, 3 rounds |
|---|---|---|
| new fence, widened | 10/10 rounds clean, 3 runs | exit 0, 0 errors |
| closer unfenced, widened | **hangs** | exit 9, 3 × invalid read in the freed 128-byte block |

On macOS the stale send faults inside the step. The new shape has no
`dynamic-wind`, so a fault there leaves the fence held and interrupts
disabled, and the pool deadlocks instead of reporting the fault. A fault can
reach a step only once a handle's memory is already gone, which is what the
fence prevents; the default gate catches this mutant (N5) without a fault.

The alternative is a `dynamic-wind` whose entry disables interrupts and takes
the fence, and whose exit releases it and re-enables them. That would contain
a fault, at about 80 B a send, half the first shape's allocation. The trade
was made for no allocation.

### Cost

1M sends on one async, on libuv's no-syscall fast path, 5 runs each.

| | main | first shape | new shape |
|---|---|---|---|
| ns per send, macOS, 1 thread | 8.0–8.6 | 41–42 | 29.6–29.8 |
| ns per send, macOS, 4 threads | 2.7–4.6 | 103–114 | 87–99 |
| ns per send, Linux Docker, 1 thread | 7.9–8.0 | 97–108 | 74–80 |
| ns per send, Linux Docker, 4 threads | 3.1–4.3 | 168–178 | 87–98 |
| bytes per send (`sstats-bytes`) | 0 | 160 | 0 |
| collections per 1M sends | 0 | 19 | 0 |

`bytes-allocated` under-counts here, because each thread has its own
allocation area. `(statistics)` confirmed the review's 160 B.

### Removed: the collection row

The first shape's M5 row said "a sender waiting for the send fence does not
keep another thread from collecting". It required a waiter to be
deactivated. The new shape deliberately waits with interrupts disabled, which
is safe only because the holder never waits. The hazard that row guarded, a
collection blocked by the fence, is now held more directly: the sweeps show
the fence is never held where a thread could be stopped for a collection. The
reproducers above show the end-to-end case.

### Uncovered by design

- **The mutex is made before `uv_async_init`.** Only a failing allocation
  could show it. The review's verifier interposed malloc to fail
  `S_make_mutex`: with the old order, teardown hung, and `uv-loop-close!`
  answered EBUSY. The order is now record and mutex, then init, then
  registration.
- **N2 and N3 are equivalent on Chez 10.4.1.**
- **A fault inside a step is not contained.** See "The widened window,
  again".

### Corrections to the first half

- **The M5 row's premise is superseded.** It required the fence to be taken
  with interrupts enabled; the new shape takes it with them disabled.
- **C1's "not a safety property" was wrong.** The async close's interrupt-free
  step is what keeps two closes of one async apart. N11, the same mutation,
  now fails both suites.
- **C3 is no longer uncovered.** With `uv_close` inside the step, N10 fails
  test-timer's timer row.
- **The first "Cost" section is superseded** by the table above.
