# Constructors as one step: mutation log

Evidence for making each constructor one interrupt-free step, the second
part of the series #53 began with the stream verbs
(`.plans/stream-step-mutation-log.md`). That log's drop survey found the
constructors' residue. This one confirms it and adds what the survey had
not looked for:

- the splits: a teardown between a constructor's loop check and its init;
- `uv-accept!`'s server, closed between its check and `uv_accept`;
- the init lock that every constructor takes;
- `call-with-uv-loop`'s loop, made before its `dynamic-wind`.

The probes, the survey and the red runs ran on `main` at eb5b719 (#52),
against a scratch copy of `src/` whose `native.sls` also exports
`init-mutex`, the probes' witness for the lock. The fix is c2d1b0e,
rebased onto c6bdcf0 as 9a79e92 once #51 and #55–#58 had merged (Gates,
below).

Platforms:

- macOS arm64: Chez 10.4.1 `tarm64osx`, libuv 1.52.1 via pkg-config, the
  dev build.
- Linux aarch64: the `chez-libuv-valgrind:10.4.1` image (Valgrind 3.19,
  vendored libuv 1.52.1), run from a `--no-hardlinks` clone.

Every probe and mutation ran on a scratch copy outside the repo.

---

## The defects, confirmed

### Dropped

The probe ran each constructor in an engine at fuel 1, 2, … and dropped
the engine at the first expiry. It then tore the loop down without letting
a hang stop it: close the registered handles, step the loop with
`'nowait` until their closes are done, and report `would-hang` if the loop
is still alive. It compared four things with the run's start:

- the registry and the fourteen debug counters, blocks included;
- the open descriptors (`/dev/fd`);
- the init lock, probed from another thread, since the lock is recursive.

Plain macOS, eb5b719:

| constructor | lock held | block lost | handle left unregistered | counter at −1 | untouched from |
|---|---|---|---|---|---|
| `make-uv-timer` | 12 | 18–23 | 24–26 | 27 | 28 |
| `make-uv-tcp` | 12 | 22–27 | 28–32 | 33 | 36 |
| `make-uv-pipe` | 12 | 22–27 | 28–32 | 33 | 36 |
| `make-uv-signal` | 12 | 18–23 | 24–26 | 27 | 28 |
| `make-uv-async` | 12 | 19–25 | 26–28 | 29 | 30 |
| `uv-accept!` | 14 | 24–29 | 30–34 | 35 | 44 |
| `make-uv-loop` | 11 | 15–20 | — | — | 25 |
| `call-with-uv-loop` | 12 | 16–21 | — | — | body at 30 |

- **A handle left unregistered** is linked into its loop, and no teardown
  can close it: `uv_loop_close` fails with `EBUSY` for good. The loop then
  leaks its own block, registry entry and descriptors: 2, plus the
  reserve descriptor libuv opens with a loop's first stream (tcp, pipe,
  accept), plus the loop's signal pipe once a signal handle exists. For
  `make-uv-async` the loop is never torn down at all, because an async
  keeps it alive. Teardown's `'default` drain would block for good, which
  the probe reports as `would-hang`.
- **A counter at −1:** the handle was registered and not yet counted, and
  the teardown's close uncounted it.
- **`make-uv-loop`:**
  - 21–23 lost the initialised loop with its 2 descriptors.
  - 24 left the loop registered and uncounted, where no one could reach
    it.
- **`call-with-uv-loop`:**
  - 22–25 lost what `make-uv-loop` does.
  - 26–27 lost a whole loop, made and counted, between `make-uv-loop`'s
    return and the `dynamic-wind`.
  - From fuel 28 on, the body's exit tore the loop down.

The earlier survey had counted the same residue with a Scheme-side block
counter (six blocks lost per constructor, three runs of `EBUSY`, the async
hang, `make-uv-loop`'s descriptors). It had not probed the lock.

### The init lock

Every constructor begins with `ensure-native-loaded!`, which took its lock
with `with-mutex` on every call.

- A drop sweep of a bare `(ensure-native-loaded!)` after initialisation
  left the lock held at fuel 5 only.
- A `with-mutex` with a marker in its body showed the window's side: at
  fuel 4 the body had run and the lock was held. At no fuel was it held
  before the body ran. So the window is the exit thunk, after the winder is
  gone and before `mutex-release`, as AGENTS.md's trap already says of the
  async fence.
- The lock is recursive, so the thread that dropped the engine carries on.
  Any other thread's next constructor waits on it forever.
- The first initialisation takes 6,796 ticks. Drops at fuels 1–5000 of it
  never left the lock held: the exit window lies past the body, by which
  time the flag is set.

### Split by a teardown

At the first expiry, the split probe tore the loop down, then resumed the
constructor. It ran under Guard Malloc
(`DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib`), where any use of freed
memory faults and Chez raises the fault as "invalid memory reference".
On eb5b719:

| constructor | refused, `&uv-handle-closed` | refused as `null-loop-pointer` | freed memory used | teardown `EBUSY` | made before, closed |
|---|---|---|---|---|---|
| `make-uv-timer` | 1–12 | 13–22 | 23: init on the freed loop | 24–26 | 27 |
| `make-uv-tcp`, `make-uv-pipe` | 1–12 | 13–26 | 27: init; 35: descriptor into the freed handle | 28–32 | — |
| `make-uv-signal` | 1–12 | 13–22 | 23 | 24–26 | 27 |
| `make-uv-async` | 1–12 | 13–23 | 24–25 | 26–28 (would hang) | 29 |
| `uv-accept!` | 1–14 | 15–28 | 29: init; 37: descriptor; 43: `uv_accept` | 30–34 | — |

- `make-uv-tcp` and `make-uv-pipe` raised `null-handle-pointer` at 33–34,
  from `attach-stream-descriptor!` on the closed handle.
- `uv-accept!` raised the same at 35–36 and 38–42, from its own read of
  the server's or the client's pointer.

A plain run of the red suite crashed at its first split sweep with
SIGTRAP (exit 133): macOS malloc found the heap corrupted.

### `uv-accept!` split by its server's close

The new suite's sweep, red on eb5b719 under Guard Malloc. At the expiry it
closes only the server, then resumes the accept either at once
(`closing`) or after the loop has freed the server (`freed`):

- `closing`: refused at 1–8, then libuv's `EAGAIN` at 9–42, from a client
  made at 9–33 and again at 34–42; untouched at 43.
- `freed`: refused at 1–8, `null-handle-pointer` at 9–41, and at 42
  `uv_accept` on the freed server; untouched at 43.

### The handoff

`make-uv-async` checks the loop's owner before allocating. The handoff
sweep gives the loop to another thread at the expiry, as `uv-run` there
would, and resumes on this one. Red: refused at 1–12, then at 13–27 it
made the async anyway, for a loop this thread no longer owned.

### Found, not fixed

A drop inside `call-with-uv-loop`'s own teardown, on the way out of the
body, leaves the loop open. That covers fuel 29–59 of the drop probe,
whose cleanup then tore the loop down. At 60, and every two or three
fuels after, the drop landed in `uv-run` between setting the running mark
and clearing it. That leaves the loop marked running, which no verb then
touches, so even the probe's teardown was refused. Each such run leaked a
loop, and the loops added to the registry made every later teardown
longer, so the probe never reached a run without an expiry. Both belong to
the loop verbs, the series' last part (ADR-0019's amendment, "Found, not
done").

## The fix

Each constructor validates its arguments, then makes one interrupt-free
step (`one-step`), `try-construct-handle` in `(libuv private handles)`.
In order, the step:

1. checks the loop's open state and pointer again (`open-loop-ptr`);
2. allocates the block (`alloc-block`) and makes the record;
3. registers the handle, then runs libuv's init (`register-then-init!`);
4. points a stream's handle data at its descriptor
   (`attach-stream-descriptor!`, still `uv_handle_set_data`'s only call
   site);
5. counts the handle.

For `make-uv-async` the step also checks the loop's owner.

- **Refusal.** The step answers the handle or a status, and
  `construct-handle` raises after it (`step-refusal`):
  - a torn-down loop as `&uv-handle-closed` for the loop;
  - a missing pointer as `null-loop-pointer`;
  - a wrong owner as `&uv-wrong-thread`.
- **Order.** The handle is registered before the init. A refused
  registration therefore frees a block libuv never saw, and a failed init
  unregisters it. Either way nothing is left behind.
- **`uv-accept!`** checks its server and calls `uv_accept` in one step.
  The client's construction nests inside it, and a refused accept begins
  the client's close inside the step.
- **`make-uv-loop`** makes the same step for a loop, `try-construct-loop`.
- **`call-with-uv-loop`** makes its loop inside its body. The step hands it
  the loop (`KEEP!`), so wherever an engine expires from there on, the exit
  finds the loop to tear down.
- **`ensure-native-loaded!`** takes and releases its lock inside
  `with-interrupts-disabled`. That is the send fence's discipline, the
  reverse of #43's second fence: no engine expires and no collection stops
  a thread that holds the lock. A raise from a refused library unwinds
  both forms.
- **`make-uv-async`** makes its send fence before the step
  (`make-send-fence`), because making a mutex can raise.

Measured after:

- Every split run is refused before its step.
- Every dropped run leaves the registry, the counters, the blocks, the
  descriptors and the lock as it found them.
- No run is suspended after a step: the allowed verdicts
  `made-before-teardown`, `made-before-close` and `made-before-handoff`
  never occur.
- The fuel maps are the same on Linux under Valgrind.

Allocation per call (`bytes-allocated`, median of 50, after two warm
calls):

| | main | fix |
|---|---|---|
| `make-uv-timer`, `make-uv-signal` | 608 | 496 |
| `make-uv-tcp`, `make-uv-pipe` | 656 | 560 |
| `make-uv-async` | 688 | 592 |
| `make-uv-loop` | 592 | 480 |

No `guard` wraps the init any more. The `dynamic-wind` that
`with-interrupts-disabled` adds to `ensure-native-loaded!` is within these
numbers.

## The tests

`tests/test-constructors.sps`, new. Every row returns its evidence when it
fails.

- **The sweeps.** Each runs from fuel 1 to the first run no expiry
  reaches:
  - **Split by a teardown:** the five handle constructors and
    `uv-accept!`.
  - **`uv-accept!` split by its server's close:** while closing, and once
    freed.
  - **The handoff:** `make-uv-async`.
  - **Dropped:** all six, plus `make-uv-loop`.
  - **`call-with-uv-loop` dropped:** its body blocks its engine as soon as
    it is entered, so the sweep stops at the first run that reached it.
  - **Witnesses.** Whether a handle was made is read from the registry at
    the expiry. After every run the registry, the counters, the
    descriptors, the init lock (from another thread) and the interrupt
    state are compared with its start.
  - A row per kind requires no bad run, and a reach row requires each
    sweep to begin with a refusal or a drop at fuel 1 and to end
    untouched.
- **The descriptor row:** a constructed tcp, pipe and accepted client each
  have their handle data at their descriptor, before any read.
- **The refused-step rows**, driven through the steps themselves, since no
  libuv init fails on an open loop:
  - an init answering `EMFILE`, for a handle and for a loop;
  - a block registered by another entry first;
  - a size of 0, which `alloc-block` refuses.

  Each must leave nothing behind. A further row requires the loop handed
  to `KEEP!` to be the one answered.
- **The forced-state row**, last: a loop forced open with its pointer
  zeroed, and a server likewise.
  - Each constructor is refused with `null-loop-pointer`, `uv-accept!`
    with `null-handle-pointer`, and interrupts stay enabled.
  - The suite opens with one loop made and torn down. libuv opens a pipe
    with a process's first loop and keeps it, which would otherwise show
    in whichever run came first: Chez's `map` did not run the sweeps in
    list order.

`tests/test-loop.sps`'s `step-refusal` row gains `'loop-not-open` and
`'no-loop-pointer`.

Red on eb5b719, under Guard Malloc and without the rows that need the new
procedures, these rows failed by name:

- the split row;
- the server-close row;
- the handoff row;
- the drop row;
- the closing balance rows: the registry 28 above its start, and the
  counters at `loop 26, block 107`, with `tcp −2` and one each of the
  others at −1.

The descriptor and forced-state rows pass there too: main sets the
descriptor and refuses a zeroed pointer, outside any step.

## Mutations

Each mutation is an exact text replacement in a scratch copy of `src/`
and `tests/`. The runner aborts a mutation unless its target matches
exactly once. It runs the named suites and requires the predicted rows to
fail by name. 25 mutations ran; every target matched. 23 are caught by the
predicted rows. Two are equivalent, and so is M21's first prediction:

| ID | mutation | caught by |
|---|---|---|
| M1 | `open-loop-ptr` skips the open check | the split row (`null-loop-pointer` refusals) |
| M2 | `open-loop-ptr` skips the pointer check | the forced-state row (init on a null loop, interrupts left disabled) |
| M3 | the step skips the owner check | the handoff row |
| M4 | a zero block is not refused | "a handle no block is made for …" (answers `null-or-invalid-pointer`) |
| M5 | a refused registration keeps its block | "a handle whose block is already registered …"; counters |
| M6 | a failed init stays registered | both init-failure rows; the squatter and `KEEP!` rows too, once the freed address came back |
| M7 | a failed init keeps its block | both init-failure rows |
| M8 | init before registration | the squatter row (the freed handle stays linked into the loop) |
| M9 | no descriptor | the descriptor row |
| M10 | a handle is not counted | the split, server-close, drop and balance rows |
| M11 | `KEEP!` not called | the `KEEP!` row; the drop row (`call-with-uv-loop` leaves its loop) |
| M12 | `KEEP!` called before the init | "a loop whose init fails …" (kept a freed loop) |
| M13 | a loop is not counted | the split, server-close, drop and balance rows |
| M14 | the loop's zero-block check removed | equivalent: see below |
| M15 | `'loop-not-open` unmapped | the split row; test-loop's `step-refusal` row |
| M16 | `'no-loop-pointer` unmapped | the forced-state row; test-loop's `step-refusal` row |
| M17 | `'wrong-thread` raised as an invalid argument | the handoff row |
| M18 | `ensure-native-loaded!` takes its lock with interrupts enabled | the drop row (`init-lock-held` at fuel 12) |
| M19 | `uv-accept!` uses the server's pointer unchecked | the server-close row; the forced-state row |
| M20 | a refused accept keeps its client | test-tcp: "the failed accept's client was closed …" |
| M21 | `uv-accept!` reads the server's pointer before the step, checking only its state inside | the forced-state row (`uv_accept` on a null server) |
| M21b | `uv-accept!` checks its server before the step | the server-close row (`EAGAIN` at 9–15, from the freed server) |
| M22 | `call-with-uv-loop` makes its loop before the `dynamic-wind` | the drop row; the balance rows |
| M23 | `call-with-uv-loop` keeps its loop after the step, not in it | equivalent: see below |
| M24 | `make-uv-async` does not ask for the owner check | the handoff row |

- **M14 is equivalent.** A loop's block has a fixed size, and nothing in a
  test can make calloc refuse it. The same branch for a handle is M4's,
  which a size of 0 drives.
- **M23 is equivalent on Chez 10.4.1.** No fuel lands between a step's
  last form and its caller's next one. The sweeps never suspended a run
  after a step, and the timer does not run while interrupts are disabled:
  the steps' calls cost no fuel. `KEEP!` stays because it holds wherever a
  compiler puts its trap checks, and it costs one closure.
- **M21 was predicted to fail the server-close row**, and did not: the
  step still checked the server's state, which every closed server fails.
  It failed the forced-state row instead, which requires a step to check
  the pointer it uses. M21b moves the whole check out of the step, and the
  server-close row catches it.

## Valgrind

Linux aarch64, `chez-libuv-valgrind:10.4.1`, with the recipe's own flags
(`--leak-check=full --show-leak-kinds=definite
--errors-for-leak-kinds=definite --undef-value-errors=no`).

- **The base.** The red copy of `tests/test-constructors.sps` ran against
  eb5b719's `src/`, with `init-mutex` exported, in a container of its own.
  - Valgrind exited 9: 131 errors from 80 contexts.
  - 73 invalid reads and writes fell inside a freed 856-byte block, the
    `uv_loop_t` the teardown had freed. They came from `uv_timer_init`,
    `uv_signal_init`, `uv_async_init` and `uv__stream_init` (the tcp and
    pipe inits), most of them in `uv__io_init_start`.
  - Two fell inside a freed 272-byte block, a stream's: `uv_handle_set_data`
    writing the descriptor, and `uv_accept` reading the freed server.
  - 41,688 B were definitely lost, in 88 blocks: the loops and handles
    the drops stranded.
  - The same six rows failed by name as on macOS.
- **The fix.** The same suite in `make test-memory-docker`: 0 errors, 0
  bytes definitely lost, and the same fuel maps as on macOS.

## Gates

On c2d1b0e, on eb5b719:

- **macOS arm64:**
  - `make test`: all 23 suites pass.
  - `make test-threading`: 12 rows.
  - `make test-memory` (ASan): all 23 suites.
  - `make check-memory-gate`: MEMORY GATE CAN FAIL.
  - `make check-purity` holds (5 suites), and `make check-help` is silent.
- **The mutation sweep** ran again on this tree: 23 caught, M14 and M23
  equivalent.
- **`make test-memory-docker`** (Linux aarch64, Valgrind 3.19, vendored libuv
  1.52.1), from a `--no-hardlinks` clone, took 238 s:
  - `check-memory-gate` caught store-overrun, libc-overrun and leak, and
    was consistent on possible-leak.
  - Every suite's own summary shows 0 errors and 0 bytes definitely lost.
  - test-process's forked children lost 131 B and 117 B, the known fork
    artifacts.

**Rebased onto c6bdcf0.** #51 and #55–#58 merged while this was open. The
rebase was clean, and none of them touched the files this change edits
most (`handles.sls`, the constructors, `uv-testing.sls`). Everything ran
again on the rebased head (8e445df):

- **macOS arm64:**
  - `make test`: all 23 suites.
  - The mutation sweep: 23 caught, M14 and M23 equivalent.
  - `make test-threading`.
  - `make test-memory` (ASan): all 23 suites.
  - `make check-memory-gate`, now with #55's shim-overrun mode: MEMORY
    GATE CAN FAIL.
  - `make check-purity` holds (5 suites), and `make check-help` is silent.
- **`make test-memory-docker`**, from a fresh `--no-hardlinks` clone, took
  240 s:
  - `check-memory-gate` caught all five planted defects.
  - Every suite's own summary shows 0 errors and 0 bytes definitely lost,
    apart from test-process's forked children, as above.

The pushed head differs from 8e445df only in this section.

## Not done

- `call-with-uv-loop`'s teardown on the way out of the body, and
  `uv-run`'s running mark (above). They belong to the loop verbs.
- The stream verbs' steps (#53) do not re-check the loop's owner. This
  change does so for `make-uv-async` only, the one constructor inside
  ADR-0019's enforced surface.
- The remaining families: `uv-tcp-connect!` and DNS, `uv-spawn!`, the
  scratch verbs, and the remaining handle and loop verbs.
