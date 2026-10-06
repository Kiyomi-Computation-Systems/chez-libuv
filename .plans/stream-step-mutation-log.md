# Stream verbs as one step: mutation log

Evidence for making each stream verb one interrupt-free step. Two defects
were found reviewing #49 and confirmed here before any change. Both are
engine splits: a verb suspended by an engine anywhere between its checks
and its native call, and either resumed after a close or never resumed.

The probes and the survey ran on `main` at 0e6a8e1. #49 merged during the
work (a0ea0ca), and the change was rebased onto it; the red runs, the
sweeps and the first two mutation sweeps ran there. Then #48 merged
(309c376), and the change was rebased again ("Rebased onto #48", below).
The third mutation sweep and the gates ran on that tree.

Platforms: macOS arm64 26.6.2 (Chez 10.4.1 `tarm64osx`, libuv 1.52.1 via
pkg-config, the dev build). Linux aarch64 in the `chez-libuv-valgrind:10.4.1`
image (Debian bookworm, Valgrind 3.19, vendored libuv 1.52.1), from a
`--no-hardlinks` clone. Every probe and mutation ran on a scratch copy
outside the repo.

---

## The defects, confirmed

### A close between the check and the call

A probe connected a loopback pair and ran a verb in an engine at fuel 1,
2, … At the first expiry it closed the client, stepped the loop until
`close-dispatch` had freed the `uv_tcp_t`, and resumed the verb. The scan
stopped at the first run no expiry reached.

Plain macOS, on 0e6a8e1:

| verb | `&uv-handle-closed` | `null-handle-pointer` | invalid memory reference | errno from the freed stream |
|---|---|---|---|---|
| `uv-write!` | 1–10 | | 11–18 | 19–29 EPIPE |
| `uv-write*!` | 1–10 | 11–16 | 17–28 | 29–42 EPIPE |
| `uv-shutdown!` | 1–10 | | | 11–22 ENOTCONN |

**Delivered to the wrong connection.** In a second mode the probe opened a
new connection after the free and before the resume. On every run the new
`uv_tcp_t` got the freed address. `uv-write!` at fuel 11–29 then returned
normally, and its 64 bytes reached the NEW connection's peer.

**Every handle verb has the gap.** The same sweep, run under Guard Malloc
(`DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib`, so any read of freed
memory faults), over every verb that reads a pointer and calls libuv:

| verb | faults at fuel | (earlier: refused) |
|---|---|---|
| `uv-write!` | 12–30 | 1–11 |
| `uv-write*!` | 12–37 | 1–9, then `null-handle-pointer` 10–11 |
| `uv-shutdown!` | 10–21 | 1–9 |
| `uv-read-start!` | 16–17 | 1–10, then `null-handle-pointer` 11–15 |
| `uv-read-stop!`, `uv-stream-write-queue-size` | 10 | 1–9 |
| `uv-tcp-nodelay!`, `uv-tcp-keepalive!`, `uv-timer-stop!`, `uv-timer-set-repeat!`, `uv-timer-repeat` | 10 | 1–9 |
| `uv-timer-start!`, `uv-listen!` | 10–11 | 1–9 |
| `uv-timer-again!` | 10 | 1–9 |
| `uv-signal-start!` | 14–15 | `null-handle-pointer` 11–13 |
| `uv-tcp-bind!` | 24 | `null-handle-pointer` 11–23 |
| `uv-tcp-getsockname-port`, `uv-tcp-peer-address`, `uv-tcp-sockname-address` | 30 | `null-handle-pointer` 10–29 |
| `uv-send-buffer-size` / `uv-recv-buffer-size!` | 20 / 23 | `null-handle-pointer` 11–19 / 11–22 |
| `uv-accept!` | 37 | `null-handle-pointer` 10–36 |
| `uv-tcp-connect!` | 36–37 | `null-handle-pointer` 10–35 |
| `uv-run` (after a teardown) | 9–10 | 1–8 |
| `uv-stop!`, `uv-loop-alive?`, `uv-now` | 9 | 1–8 |
| `uv-update-time!` | 10 | `null-loop-pointer` 9 |
| `uv-async-send!` (the #33 fence) | none | 1–8 |
| `uv-close!` (`begin-close!`) | none | |

A `null-handle-pointer` refusal is safe but misnamed: the close had freed
the handle before `handle-pointer` read it.

### An engine dropped mid-verb

The drop probe dropped the engine at the first expiry, never resuming it,
tore the loop down, and counted what was left. An instrumented copy of
`src/` counted every block `alloc-zeroed` made and `free!` freed. On
0e6a8e1, for each verb that allocates (runs with residue / runs swept):

| verb | residue |
|---|---|
| `uv-write!` | 6 blocks lost; 3 requests registered and counted that libuv never saw |
| `uv-write*!` | 9 blocks lost; 3 requests left registered |
| `uv-shutdown!` | 3 blocks lost; 2 requests left registered |
| `uv-tcp-connect!` | 10 blocks lost; 8 requests left registered |
| `uv-getaddrinfo!` / `uv-getnameinfo!` | 27 / 10 blocks lost; 8 / 8 requests left registered |
| `make-uv-timer`, `-tcp`, `-pipe`, `-signal`; `uv-accept!` | 6 blocks lost each; 3 runs each where teardown raised EBUSY for good |
| `make-uv-async` | teardown never returned: the drain's `uv_run` blocks on the unregistered async |
| `make-uv-loop` | 10 blocks lost; 4 kqueue fds leaked (`/dev/fd`: 4 open before, 8 after) |
| `uv-spawn!` | 92 runs losing 1–2 blocks; 7 runs where teardown raised EBUSY |
| bind, the address and port queries, the buffer sizes | 9 to 48 runs losing 1–2 blocks each |
| `uv-read-start!` | none |

`leaks --atExit` on the `uv-write!` drop sweep, against a control that
resumed every engine: 199 malloc nodes alive at exit against 188, the 8
unregistered blocks and the 3 registered requests.

`registry-snapshot-for-loop` collects handles only, and
`cancel-requests-for-loop!` cancels DNS requests only, so a request that
was registered but never submitted outlives its loop's teardown.

## The fix

Each stream verb validates its arguments as before. Then it makes one
interrupt-free step. The step checks again that the stream is open, reads
the stream's pointer, and checks again what it reads of the caller's data:
the spans, the read buffer's size. Then it allocates, registers and counts
the request, and calls libuv. The step answers a status, and the verb
raises after the step. Nothing inside raises:

- `one-step` (`(libuv private handles)`) is a bare
  `disable-interrupts`/`enable-interrupts` pair. `begin-close!` now uses it
  too.
- `open-handle-ptr` answers the pointer, or `'not-open` or `'no-pointer`.
  `step-refusal` turns a status into the condition the checks outside a
  step raise.
- `registry-add!` is the registry's one write site. It answers its
  refusals, and `registry-register!` raises them. `registry-remove!` is
  `registry-deregister!` without the raise.
- The shim's `chez_uv_alloc` (calloc) answers NULL where `foreign-alloc`
  raised "Cannot allocate memory". `alloc-block`, `free-block!` and
  `copy-in-unchecked!` are total: no argument makes them raise.
  `alloc-zeroed` and `free!` are built on them and keep their checks.
- The debug shim counts every block alive (`'block` in `live-counts`), in
  `chez_uv_alloc` and `chez_uv_free` themselves.

`uv-read-start!` also stores its callbacks inside the step, once libuv
accepts the start. Before, a read delivered between the two found no
callback.

**Allocation**, fewest of 64 calls, `tests/test-callback-alloc.sps`'s meter:

| path | before | after |
|---|---|---|
| `uv-write!` of 16 B | 240 | 144 |
| `uv-write*!`, one 16 B segment | 304 | 208 |
| `uv-shutdown!` | 128 | 128 |

The 96 B saved per write is `copy-in!`'s `with-interrupts-disabled`: a
`dynamic-wind` and its closure. A prototype of `uv-write!` in this shape on
0e6a8e1 read the same 144 B.

**The step's length.** A plain foreign call keeps its thread active, so
other threads' collections always waited for each foreign call in a write.
The step makes them wait for all of them together. One `uv-write!` call on
a connected loopback stream, fewest and median of 15, macOS:

| payload | before | after |
|---|---|---|
| 1 MiB | 0.40 / 0.73 ms | 0.17 / 0.87 ms |
| 4 MiB | 2.41 / 3.42 ms | 2.51 / 4.36 ms |
| 16 MiB | 1.44 / 4.51 ms | 1.82 / 3.56 ms |

`uv_write`'s own copy into the socket dominates, before and after.

**#49.** The step checks the span before it allocates, so the leak #49
fixed cannot arise in the write verbs. #49's shrinking-payload sweep passes
unchanged against the step, and `try-copy-in!` stays as `copy-in!`'s base.

## The tests

`tests/test-stream.sps` runs three sweeps over the six stream verbs, each
on a fresh loopback connection per run:

- **split:** at the first expiry, close the stream, step the loop until the
  close has freed it, and resume;
- **reuse** (the write verbs): the same, opening a new connection after the
  free;
- **drop:** drop the engine, then close the connection.

**The split oracle.** Before closing, the sweep asks whether the verb's
native call has been made. Each witness is deterministic:

- a write: its callback has run (libuv queues it once `uv_write` has
  written, and the next loop step runs it);
- `uv-shutdown!`: `uv_is_writable` reads 0;
- `uv-read-start!` / `uv-read-stop!`: `uv_is_active` reads 1 / 0.

Then each run has one right answer:

- refused with `&uv-handle-closed`, not made;
- made before the close (or the verb had returned before the expiry), and
  its effect landed;
- untouched: no expiry, and the effect landed.

Each run must also leave the registry, every counter and the blocks alive
as it found them, and leave interrupts enabled. The reuse sweeps also
require the new connection's peer to receive nothing.

On the fix, every suspended run in every sweep is refused before the step,
and the first run with no expiry is untouched:

| verb | split / reuse: refused, untouched | drop: dropped, untouched |
|---|---|---|
| `uv-write!` | 1–17, 18 | 1–17, 18 |
| `uv-write*!` | 1–33, 34 | 1–33, 34 |
| `uv-shutdown!` | 1–12, 13 | 1–12, 13 |
| `uv-read-start!` | 1–10, 11 | 1–10, 11 |
| `uv-read-stop!` | 1–9, 10 | 1–9, 10 |
| `uv-stream-write-queue-size` | 1–9, 10 | 1–9, 10 |

No run is suspended after its step: the expiry an engine reaches inside a
step is taken only once the verb has returned.

**Red on the base.** The new sweeps against a0ea0ca's `stream.sls`, with
the new shim, `native.sls` and `handles.sls` underneath, failed by name in
two of two runs (bad runs per sweep):

| verb | split | reuse | drop |
|---|---|---|---|
| `uv-write!` | 17–18 | 17 | 9 |
| `uv-write*!` | 41 | 41 | 18 |
| `uv-shutdown!` | 10 | | 5 |
| `uv-read-start!` | 5 | | 1 |
| `uv-read-stop!` | 1 | | |
| `uv-stream-write-queue-size` | 1 | | |

`uv-read-start!`'s split runs showed the read buffer left in a closed
record (`read-buffer 1`, `block 1` after the close). Its drop run showed the
`read-buffer` counter at −1: dropped between storing the buffer and
counting it. `uv-read-stop!`'s and the queue size's single runs returned
normally without having been made: a native call on the freed stream.

**Other rows:**

- `test-stream.sps`: a stream left open with no native block, for all six
  verbs: refused with `null-handle-pointer`, interrupts enabled after. It
  comes last, as test-async-fence's does. The libuv-refusal rows now count
  blocks.
- `test-native.sps`: the fourteenth counter class; `alloc-block`,
  `free-block!` and `copy-in-unchecked!`; `alloc-zeroed`'s ENOMEM.
- `test-loop.sps`: `registry-add!`'s answers, `registry-remove!`, and
  `step-refusal`'s mapping.
- `test-callback-alloc.sps`: the write paths' bounds are now 144, 208 and
  128 B, with half a dynamic-wind (40 B) of margin, not half a guard
  (128 B), so a `with-interrupts-disabled` put back around a step fails
  them.

### Two flaky waits, found by the mutation runs

The first full mutation sweep ran while the machine's load average was 43
(other work in progress). Rows failed in mutants that did not touch them:

- **This sweep's own wait.** An untouched write's 64 bytes had not reached
  the peer within the 20 one-millisecond steps the oracle then allowed
  (`never-landed`, 5 of about 25 runs). Reproduced on unmutated code in 2
  of 10 back-to-back runs. Quiet again, the same loop gave 0 of 30, and 0
  of 20 with four suites in parallel.
- **#49's shrinking-payload sweep.** Its drain of 256 steps expired with
  nothing received. The write's bytes then landed in the next run's count
  (`wrong-length 3008`, 7 bytes more than that run wrote).

Nagle's algorithm was ruled out by measurement. Writing 3,001 B and then 64
B, 300 times each, on one long-lived connection, every write drained in one
step, with and without `TCP_NODELAY`. The first try of that A/B ran both
legs with the option set: `NODELAY=` (empty) is set too, and `""` is true
in Scheme.

The waits are now in two kinds:

- **Waiting for something to land** waits up to 2,000 steps
  (`landing-steps`, and #49's `drain-steps`). Only a build whose effect
  never lands pays that.
- **Waiting to see that nothing lands** keeps 20 steps (`stray-steps`). A
  late arrival there can only let a broken build pass, never fail a sound
  one.

The "made" witnesses never wait on the kernel.

### The zeroing row

`alloc-zeroed` now allocates through the shim, and its row's churn went
through `foreign-alloc`. The two do not share a free list. Measured on
macOS, a block `foreign-free` had just released came back from the shim's
allocator 0 times in 200, while one the shim had just freed came back 200
times in 200. So the row had become blind: with `malloc` in place of
`calloc` (S1 below) it passed 3 of 5 runs.

The row now dirties a block through the shim and frees it before each
allocation. A seed requires that `alloc-zeroed` was handed that very block
at least once. With that, S1 failed it in 5 of 5 runs, and the control
passed 3 of 3.

Neither memory tool hands back a block just freed. Memcheck's freelist and
ASan's quarantine both delay reuse, so under `CHEZ_LIBUV_UNDER_VALGRIND` or
`ASAN_OPTIONS` the seed requires only the allocations. The first macOS
`make test-memory` run failed the strong seed until it learned this.

## Mutations

Each mutation is an exact text replacement in a scratch clone, which aborts
unless its target matches exactly once. The clone is reset before every
row, and the shim is rebuilt from scratch after any C mutation. The table
is the third full sweep, on the tree rebased onto #48: 57 mutations, every
target matched. The machine's load average reached 270 during it (other
work), and no row flaked. A mutation is caught when the named row fails:
50 of 57. The other seven are equivalent (five) or weaken only what the
sweeps see of the base (two).

| ID | mutation | caught by |
|---|---|---|
| S1 | `chez_uv_alloc` mallocs, no zeroing | "alloc-zeroed returns zeroed memory …" (5/5 after the row's rewrite) |
| S2 | the alloc does not count | "alloc-block answers a zeroed block, counted until free-block! frees it"; the counter matrix |
| S3 | the free does not uncount | the same row; the counter matrix |
| S4 | `chez_uv_free` does not free | "seed: the shim's allocator handed alloc-zeroed the very block just dirtied" (a block never freed is never handed back); Valgrind too (below) |
| S5 | a refused allocation is counted | "alloc-block answers 0 when the allocator refuses …" |
| N1 | `alloc-block` passes any size to the shim | "alloc-block answers 0 for a size that is not a positive fixnum …" |
| N2 | `alloc-block` accepts 0 | same row |
| N3 | `free-block!` passes anything to the shim | "free-block! ignores what cannot be an address …" |
| N4 / N4b | no upper / lower bound | same row |
| N5 | `alloc-zeroed` answers 0 for a refused allocation | "alloc-zeroed raises ENOMEM under its own name …" |
| N6 | `copy-in-unchecked!` ignores start | "copy-in-unchecked! copies the requested span …" |
| N7 | `live-counts` leaves blocks out | "live-counts reports all fourteen allocation classes" |
| N8 | `free!` has no upper bound | "free! rejects an address past the address space" |
| H1 | `registry-add!` overwrites | "registry-add! answers each refusal …", "registering the same pointer twice is refused …" |
| H2 | `registry-add!` accepts a non-loop | "registry-add! answers each refusal …" and four more |
| H3 | `registry-remove!` raises for an absent entry | "registry-remove! … raises nothing for an absent one" |
| H4 | `one-step` leaves interrupts enabled | split, reuse and drop rows; test-timer's close sweep |
| H5 | `one-step` never enables them again | every reach row |
| H6 | `one-step` is `with-interrupts-disabled` | all three write-path bounds (test-callback-alloc) |
| H7 | `open-handle-ptr` skips the open check | split and reuse rows; test-timer's close rows |
| H8 | `open-handle-ptr` skips the pointer check | the no-native-block row; test-async-fence's |
| H9 | `'not-open` raised as an invalid argument | split and reuse rows; the `step-refusal` row |
| H10 / H11 / H12 / H14 | `step-refusal`: ENOMEM, the registry's who, an errno's who, `'no-pointer` | the `step-refusal` row (H12 also the libuv-refusal rows; H14 also the no-native-block row) |
| H13 | `begin-close!` not one step | test-timer: "a timer's close suspended anywhere is one step …" |
| W1 | `uv-write!`'s step skips the span | #49's "a write the sweep let through sent the peer exactly the bytes …" |
| W2 | `uv-write!` reads its pointer just before the step | equivalent, see below |
| W3 | `uv-write!` allocates just before the step | split: a refused step leaks the early block |
| W5 | a write libuv refuses counts as started | "a uv-write! libuv refuses raises its errno …" |
| W6 / W7 / W8 | a refused write's block not freed / not deregistered / not uncounted | the same rows (the block counter for W6) |
| W10 / W11 | `uv-write*!`'s step skips the spans; `spans-fit?` checks none | #49's content row |
| W12 | `place-spans!` reuses one `uv_buf_t` | split and reuse content rows; test-tcp's `uv-write*!` rows |
| W13 | `uv-shutdown!` allocates just before the step | split: a refused step leaks it |
| W14 | a refused shutdown's block not freed | "a uv-shutdown! libuv refuses … leaves no request" |
| W15 | callbacks stored when libuv refuses | test-tcp: "a failed start leaves the handle NOT reading" |
| W16 | the read buffer installed before the step | equivalent since #48: the install is its own step, and checks the stream is open (see I5) |
| W17 | a new read buffer not counted (`install-read-buffer!`) | split, reuse and drop rows; test-tcp |
| W18 / W22 | a restart may resize the buffer; the buffer's status ignored | test-tcp's buffer-size rows |
| W19 / W20 | read-stop / the queue size read the pointer just before the step | equivalent, see below |
| W21 | `uv-read-stop!` leaves the reading flag | test-tcp: "uv-read-stop! outside a callback clears the reading flag" |
| W23 | `uv-write!`'s step raises its span refusal inside | `interrupts-left-disabled` in a later sweep; #49's reach row |
| I1 | `install-read-buffer!` skips its open check | "install-read-buffer! answers not-open for a closing stream, installing nothing" |
| I2 | it skips its buffered check | "install-read-buffer! answers buffered for a stream that has one, and keeps the first" |
| I3 | it is not a step of its own | equivalent: the read start's step contains it (see I5) |
| I4 | it leaves the descriptor empty | test-tcp's read rows (every read answers ENOBUFS) |
| I5 | I3 and W16 together: the install outside any step | split and drop rows; #48's install sweeps; "closing the two reading handles freed both read buffers" |
| T1 | `poll!` never steps the loop | every split, reuse and drop row |
| T2 | the split resumes without freeing the stream | passes: the stream is still closing, so the step refuses it |
| T3 | the reuse sweep's stray check never waits | passes: the split oracle already fails a write made after the close |

**Equivalent mutants (W2, W19, W20).** A pointer read immediately before
the step leaves no point where an engine can suspend. The next trap check
after `enable-interrupts` falls inside the next step, whose
`disable-interrupts` defers it again. The fuel maps match the fix's to the
run. On the base, the read and the call were separated by real calls
(`alloc-zeroed`, the copy, the record), and the red runs above show the
sweeps catching that.

**W3 and W13** are caught by the split sweep rather than the drop sweep,
for the same reason: no run can be dropped between an allocation just
before the step and the step.

**W16 and I3** are each equivalent since the rebase onto #48. The read
buffer's install is a step of its own, which checks the stream is open, and
the read start's step contains it. Either alone keeps the install atomic.
I5 removes both, recreating the gap #48 shipped with, and every layer's
sweeps catch it: this suite's split and drop sweeps, and #48's install
sweeps.

**T2 and T3** weaken only what the sweeps can see of the base: the oracle
already fails a write the base makes on a closing stream, or after the
close.

## Rebased onto #48

#48 (309c376) answers libuv's alloc callback in the shim, from a
descriptor in the stream's handle block, and made the read buffer's
install a step of its own (`install-read-buffer!`). That step re-checks
that the stream is open, so a start resumed after a close no longer
installs into the freed block. Two gaps remained, measured on 309c376
itself, with these sweeps run over its `stream.sls` and `handles.sls`:

- **drop:** a start dropped at fuel 14 (of 17) lost a block. The install
  allocated with `alloc-zeroed` before its step, and the engine stopped
  inside that call, after the allocation.
- **split:** a start resumed at fuel 15–16 after the close called
  `uv_read_start` on the freed handle (ENOTCONN on macOS): the start read
  the stream's pointer outside any step.

The merge keeps #48's design and puts its install inside the read start's
step:

- `install-read-buffer!` is now total. It allocates with `alloc-block`
  inside its own `one-step`, fills the descriptor and the record together,
  and answers `'installed`, `'not-open`, `'buffered` or `'no-memory`.
- `uv-read-start!`'s step calls it through `ensure-read-buffer!`, and the
  steps nest.
- #48's row for a size of 0 now expects `'no-memory` rather than
  `alloc-zeroed`'s raise. Two rows hold the install's other answers:
  `'buffered` keeps the first buffer, and `'not-open` installs nothing on
  a closing stream.
- #48's install sweeps pass unchanged, as do its read rows. Allocation is
  unchanged: 144 / 208 / 128 B for the write paths, and #48's 448 B for a
  read through libuv.

## Valgrind

Linux aarch64, `chez-libuv-valgrind:10.4.1`, the recipe's own flags
(`--leak-check=full --show-leak-kinds=definite
--errors-for-leak-kinds=definite --undef-value-errors=no`), one long-lived
container.

- **The base.** `tests/test-stream.sps` against a0ea0ca's `stream.sls`, with
  the new pieces underneath: exit 9, 115 errors from 6 contexts. Five are
  invalid reads inside a freed 248-byte block, the `uv_tcp_t` the close had
  freed, in `uv_write2`, `uv_shutdown`, `uv_read_start`, `uv_read_stop` and
  `uv_stream_get_write_queue_size`. The sixth is 133,456 B in 14 blocks
  definitely lost. Five plain rows failed by name as well.
- **The fix.** The same suite in `make test-memory-docker`: 0 errors, 0
  bytes definitely lost.
- **S4**, `chez_uv_free` not freeing: under Valgrind every row passes
  (293 in `test-native.sps`, where the zeroing seed takes its weak form,
  and 32 in `test-stream.sps`), and Valgrind fails both: 94 blocks
  (96,428 B) and 977 blocks (32.7 MB) definitely lost, every one allocated
  at `chez_uv_alloc`. The block counter cannot see it, since the free
  counts itself before freeing. A plain run does: the zeroing seed requires
  the shim to hand back the block just freed, and a block never freed never
  comes back (the mutation table).

## Gates

On the tree rebased onto #48 (cef68e0):

- **macOS arm64:**
  - `make test`: all suites pass.
  - `make test-threading`: 12 rows.
  - `make test-memory` (ASan): all 21 suites.
  - `make check-memory-gate`: MEMORY GATE CAN FAIL.
  - `make check-purity` holds, and `make check-help` is silent.
- **`make test-memory-docker`** (Linux aarch64, Valgrind 3.19, vendored libuv
  1.52.1), from a `--no-hardlinks` clone:
  - `check-memory-gate` catches all four planted defects.
  - Every suite's own summary shows 0 errors and 0 bytes definitely lost,
    `test-stream.sps` with its sweeps included.
  - The forked children's 131 B and 117 B are the known fork artifacts.

The same list passed on the tree before the rebase (9c1aa1c, on a0ea0ca).
The pushed head differs from cef68e0 only in this section.

## Not done

The other verb families have the same splits and drops (the tables
above). They follow this one, each with its own sweeps: the constructors
(the async hang and the loop's fd), `uv-tcp-connect!` and DNS, `uv-spawn!`,
the scratch verbs, and the remaining handle and loop verbs. ADR-0019's
decision 3 amendment lists them.
