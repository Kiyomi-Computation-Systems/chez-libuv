# uv-spawn! reads its caller's data once: mutation log

Evidence for `fix/spawn-read-once`. The scratch probes below ran on
0e6a8e1, and the rows, the mutations and the gates first on a0ea0ca (#49)
and the fix on top of it. Main then gained #48, #50, #53, #54 and #52,
none of which touches `process.sls`. The fix now sits on eb5b719 as
9c50b89, and the rows' red (on 32ea8d7), the mutation sweep and every gate
ran again on the final tree, as the sections below say.

`uv-spawn!` (`src/libuv/process.sls`) checked its caller's strings and
lists, sized one options block from them, allocated it with
`alloc-zeroed`, and then read the caller's data again to fill it:
`put-string!` encoded every string a second time, the fill walked the args,
env and stdio lists again, and the same-loop check and the marking of
consumed pipes read the stdio specs again. An engine's timer handler (or
another thread) can change any of it in between, and `copy-in!` bounds a
copy by its source bytevector only, never by the block it writes to.

Every probe and mutation ran on a scratch copy outside the repo. Platforms:
macOS arm64 26.6 (Chez 10.4.1 `tarm64osx`, libuv 1.52.1 via pkg-config, the
dev build); Linux aarch64 in the `chez-libuv-valgrind:10.4.1` image (Debian
bookworm, Valgrind 3.19, vendored libuv 1.52.1, `HAVE_PKG=no`), from a
`--no-hardlinks` clone, with the gate's own Valgrind flags.

---

## The bugs, confirmed

A scratch probe ran `uv-spawn!` in an engine at fuel 1, 2, …, changed the
caller's data at the first expiry, resumed, and drained the loop between
runs. Each child was `/bin/sh -c` printing its operands and three
environment variables on a pipe, then `exit 7`. The scan stopped at the
first run no expiry reached. On 0e6a8e1:

| change at the first expiry | runs | natively | under Valgrind |
|---|---|---|---|
| an argument's 16 ASCII characters become λ | 343 | no run visibly wrong | 915 errors: `Invalid write of size 1 at __GI_memcpy by chez_uv_copy_in (libuv-shim.c:211)`; 61 children: `execve(argv[i]) points to unaddressable byte(s)` |
| an env value's 16 characters become λ | 383 | no run visibly wrong | 1,050 errors from 2 contexts |
| the args list gains an 8-character string | 330 | 73 refused `EFAULT` | 536 errors; those 73 children report `execve(argv)` unaddressable |
| the env list gains `X=xxxxxxxx` | 368 | no run visibly wrong | 870 errors |
| `(ignore (pipe p from-child) ignore)` gains an `ignore` | 318 | 116 refused `EFAULT` | the parent 0 errors, so the gate stays green; 116 children exit 0 with an empty argv (`execve(argv[0])` unaddressable) |
| `"exit 7"` becomes `"exit \0"` | 231 | 103 children exit 0, not 7 | the same; no memory error, as a NUL is no overrun |

A list that grew between the pointer arrays' sizing and the fill also
overwrote argv's NULL slot, so the child's argv ran on into the block's
next bytes: the sweep below catches children whose argv carries the env
strings.

### Chez's own readers trust the data to keep still

`$string->utf8` (Chez 10.4.1, `s/prims.ss`, compiled at optimize-level 3)
counts the string's UTF-8 bytes in one pass, allocates, and writes them in a
second pass with unchecked `string-ref` and `bytevector-u8-set!`. An engine
sweep over `(string->utf8 s)` that turned every character of `s` into λ at
the first expiry got torn results: at 64 characters, 2 runs returned a
64-byte bytevector holding 32 λs; at 200 characters, 6 runs. At 1,000
characters the program died with `Exception in raise: no engine active`, its
heap overwritten. Both `utf8-size` and `put-string!` called it on the
caller's strings with interrupts enabled.

Another thread needs no engine to do the same, and an interrupt-free step
does not hold it off. The cross-thread race row below, run against the fix
before it copied strings (the read encoding each string as the caller holds
it, with interrupts disabled), failed in each of eight runs: 1 to 14 of 200
rounds. Some were spurious `embedded-nul` refusals, from bytes the encoder
left unwritten. Others gave the child 4,097 to 4,100 characters, stale
bytes past the 4,096th. The getaddrinfo fix (`fix/getaddrinfo-snapshot`,
another session) measured the same of its node and service strings.

Chez's `map` (`s/4.ss`) measures a list with `$list-length`, then walks it
with the unchecked `#3%map`. `list?` and `length` (`s/5_2.ss`) check every
pair they pass, and `list?` says why: "to avoid a crash if the list is
mutated".

## The fix

`start-spawn!` reads `file`, `args` and `options` once, inside
`with-interrupts-disabled`, into a `spawn-request` nothing else can reach:
each string as a fresh UTF-8 bytevector (or `#f` for a non-string), each
list as a fresh list (or `#f` for anything but a proper list), each options
entry as a fresh `(key . value)` with its value read as its key needs, and
each stdio spec as an immutable `stdio-spec` record. Each string is copied
with `string-copy` and the copy encoded: a copy is fixed-width, and with
interrupts disabled no handler or collection runs inside it. Each list is
measured with `list?` and `length` and walked at most that many steps, each
pair checked. On data that keeps still the read raises nothing. The checks then run on the request in the order they always ran,
with the NUL check on the encoded bytes (UTF-8 encodes NUL, and nothing
else, as a zero byte). The block is sized from the request's bytevectors and
filled from them, and the same-loop check and the marking of consumed pipes
read the request's specs. `put-bytes!` refuses a string that would not fit,
with its NUL, in the block: a bound `copy-in!` does not have. The block's
layout is unchanged, so an unchanged call builds the same bytes.

Bytes one `uv-spawn!` call allocates, fewest of 32 (every run identical),
macOS arm64, on a0ea0ca and on the fix:

| spawn | main | **fix** | without the copy (engines only) |
|---|---|---|---|
| argv of 3, no options | 1,760 | **1,984** | 1,872 |
| argv of 5, env of 2, cwd, 3 stdio specs | 2,512 | **3,040** | 2,784 |
| argv of 3, env of 40 strings of 64 characters | 12,656 | **20,624** | 9,632 |

Main encoded every string twice. Read once without the copy, a spawn
allocates less than main where strings dominate, and more where it copies
lists, entries and specs. The copy costs 4 bytes a character, a Chez
string's width, so the fix allocates more than main in every shape. It is
what makes the read safe against another thread. A spawn's cost is its fork
and exec, so it stays; dropping it is a one-line change, with the race row,
for engines-only safety. The checked walk costs nothing over `map`.

The interrupt-free step costs 80 B as `with-interrupts-disabled` (a
`dynamic-wind` and its body's closure; measured without the copy, 1,872
against 1,792 B). A bare `disable-interrupts` / `enable-interrupts` pair
costs nothing and would be safe on data that keeps still, but a raise inside
it, from a later edit or from `length` on a list another thread breaks,
would leave interrupts off for good. Sharing one `stdio-spec` for every
`ignore` saved nothing: Chez folds a constant immutable record already.

## The rows

`tests/test-process.sps` gains four sweeps, one per case. Each runs
`uv-spawn!` in an engine at fuel 1, 2, …; at the first expiry it changes the
caller's data, then resumes. Each child reports what it saw on a pipe (its
operands, `$V`, `$W`, `$X` and the last part of its working directory) and
exits 7. Because the read is one interrupt-free step, each run has two right
answers, the outcome of the data before the change or after it, and each
change touches several strings or lists at once, so that one of them read
again after the others shows up as a mix.

| sweep | change at the first expiry | before | after |
|---|---|---|---|
| strings grow | an argument, an env value and the cwd: each `aaaa` becomes four λs | the child reports `aaaa` throughout | λ throughout, in `tests/tmp/spawn-cwd-λλλλ` |
| lists grow | args gains `xxxx`, env gains `X=xxxx` | without them | with both |
| stdio changes | the stdout pipe is swapped for another loop's, and a fourth spec is appended | the child reports on the run's own pipe, which alone is marked consumed | refused `pipe-wrong-loop`, nothing marked |
| NULs appear | a NUL in the script's `7`, in an argument and in an env value | exit 7, whole strings | refused `embedded-nul` |

A run that is neither (or a spawn that leaves an options block, a process or
a registry entry behind) is evidence, printed by the failing row. Fuel 1
expires before the read, and each sweep stops at the first run no expiry
reached whatever its verdict, at fuel 3,000, or after a batch whose children
did not all finish, so a broken build fails by name rather than hanging. A
reach row requires each sweep to begin with `after` and end with an
untouched run. Sixteen children run at a time: waiting for each in turn took
about 10 ms a run on macOS, and sixteen at a time take about 2.5.

A cross-thread race row holds the copy. A narrower thread turns every λ of
a 4,096-character argument back into `a`, over and over, spinning 200 steps
after each character so that its pass outlasts the read. Each of 200 rounds
widens the argument to all λ, waits until the narrower has begun a pass,
then spawns a child that prints the argument. Each child must report 4,096
characters, each an `a` or a λ, and exit 7. Whether a pass overlaps the
read is up to the scheduler. So the row asserts only what no schedule can
make fail on a right answer, and counts the rounds whose child reported a
mix, which only an overlap produces. The callbacks do not collect, since an
explicit collection raises while another thread is active. It is skipped
under Valgrind, which runs one thread at a time.

Five validation rows pin shapes the rewrite touched, all also passing on
main: `(pipe)`, `(pipe p)` and `(pipe p from-child extra)` are refused as
`stdio-spec-unknown`, a NUL inside `cwd` as `embedded-nul`, and an
`(inherit-stream . h)` of another loop's handle as `pipe-wrong-loop`.

**Red on a0ea0ca**, macOS: the reach row passes, and the four sweep rows
fail by name (on 32ea8d7: 51, 116, 213 and 151 runs).

- **strings grow:** 51 runs, each a mix. In 39 the argument and env value
  were read after the change and the cwd before it; in 12 only the env
  value was read after.
- **lists grow:** 118 runs. In 99 the child's argv ran on into the env
  strings (`zero|one|xxxx|V=v|W=w|X=xxxx|V=v|…`); in 19 the env list was
  read after the change and the args before it.
- **stdio changes:** 215 runs. 160 were refused `EFAULT`, with the other
  loop's pipe marked consumed. In 17 the child's stdout went to the other
  loop's pipe: the swapped-in pipe reached libuv. In 38 the child used the
  run's own pipe but the other one was marked.
- **NULs appear:** 155 runs. 129 children exited 0 with their strings cut at
  the NUL; 26 exited 7 with some of them cut.

Under Valgrind, the real recipe (`make CHEZ=scheme HAVE_PKG=no test-memory
MEMORY_TESTS=…`) on a0ea0ca's code with only one sweep enabled fails for the
strings sweep with 667 errors from 2 contexts (`Invalid write of size 1 at
__GI_memcpy … by chez_uv_copy_in (libuv-shim.c:211)`), make exit 2, and for
the lists sweep with 909 errors, make exit 2. The stdio and NUL sweeps leave
the parent clean there; their rows fail. The macOS ASan arm sees cases 1
and 2 as well: run in the recipe's environment (the preload on `chez`
itself, nothing in between), each of the two sweeps alone aborts with
`AddressSanitizer: heap-buffer-overflow … in memcpy … chez_uv_copy_in
libuv-shim.c:211`, exit 134.

The race row passes on main's code, 0 mixed of 200 in two runs, and for a
reason of timing: main scans each argument for NUL a character at a time
before it encodes anything, and that scan outlasts the narrower's pass. Its
target is a read that encodes the caller's string itself, which fails it
(M19).

**Green on the fix:** 124 rows. The sweeps take 403, 376, 374 and 380 runs
on the final tree (two more each on a0ea0ca), 13 of each `after` and one
untouched, the rest `before`. In the race, 146
to 182 of 200 children per run reported a mixed argument, at load averages
up to 200, and none a wrong one.
Under Valgrind the suite's own process has 0 errors and 0 bytes definitely
lost (see Gates).

## Mutations

Each mutation was an exact text replacement in a fresh copy of the fix's
`src/` (or of `tests/`), aborted unless its target occurred once and
re-checked after. `tests/test-process.sps` ran against the copy; a mutation
counts as caught only if the predicted rows failed by name. The whole table
ran on the final tree.

| id | mutation | caught by |
|---|---|---|
| M1 | the read is not one interrupt-free step | strings grow, lists grow (mixes: an argument read before the change and the env after) |
| M2 | the block's args are read again from the caller after the checks | strings grow, lists grow, NULs appear, the cross-thread race (it re-encodes the caller's strings) |
| M3 | the block's env is read again after the checks | strings grow, lists grow, NULs appear |
| M4 | the block's cwd is read again after the checks | strings grow |
| M5 | the block's stdio specs are read again after the checks (sized and filled from that read) | stdio changes |
| M5o | the containers are filled from the caller's specs read again; their count from the request | stdio changes |
| M6 | the pipes marked consumed are the caller's specs, read again | stdio changes |
| M7 | the same-loop check reads the caller's specs, before the read | stdio changes |
| M8 | the NUL check reads the caller's strings, before the read | NULs appear |
| M9 | the destination bound is gone | nothing: equivalent (below) |
| M10 | the sizing leaves out the terminating NULs | the suite dies at its first spawn, refused by the bound; a crash, not a kill, narrowed to M10n |
| M10n | M10 for spawns whose env holds `W=w` (the sweeps') | the reach row and all four sweep rows, every run refused by the bound by name |
| M10bn | M10n with the bound gone | plain rows on macOS: none (123 pass). **Valgrind:** `Invalid write of size 2 … chez_uv_copy_in … 0 bytes after a block of size 308`, 12,183 errors, exit 9, and the four sweep rows and the reach row fail there too. **ASan:** `heap-buffer-overflow … chez_uv_copy_in libuv-shim.c:211`, exit 134 |
| M11a | a pipe spec may run past its direction | a (pipe ...) spec with more than a pipe and a direction |
| M11b | a pipe spec need not have a direction | a (pipe ...) spec with no direction |
| M11c | a pipe spec need not have a pipe | a (pipe) spec with no pipe |
| M12 | `read-list` walks anything, not only a list | env that is not a list of strings; stdio that is not a list |
| M13 | no string is checked for NUL | the four NUL rows (file, args, env, cwd), NULs appear, the reach row |
| M14 | cwd is checked for its type only | a NUL inside cwd |
| M15 | env strings are checked for their type only | a NUL inside an env string |
| M16 | an empty args list is accepted | an empty args list |
| M17 | file is checked for its type only | a NUL inside file |
| M18 | `inherit-stream` handles are neither loop-checked nor marked | the named pipe is marked connected even on the failure path; an inherit-stream handle from another loop is refused by name |
| M18a | the same-loop check skips `inherit-stream` handles | an inherit-stream handle from another loop is refused by name |
| M19 | each string is encoded as the caller holds it, not from a copy | the cross-thread race row: 193 rounds of 200 at load averages near 200 (Uncovered says how it once escaped) |
| M20 | lists are read with Chez's `map` | nothing: equivalent on data that keeps still (below) |
| M21 | the list walk is unbounded | nothing: equivalent on data that keeps still (below) |
| H1 | the sweeps' fuel cap is 5 | the reach row |
| H2 | the strings change changes nothing | the reach row |
| H3 | a batch waits one loop step for its children | the reach row and all four sweep rows, each listing its unfinished runs; no hang |
| H4 | the race's narrower never narrows | the cross-thread race row: `(the-narrower-never-narrowed round 0)`; no hang |

M10b, the sizing short by every terminator with the bound gone, is undefined
behaviour natively: one run passed every row, another died on a stray
`stdio-spec-unknown` raised from a corrupted heap, and others failed the
race row with children given up to 4,426 characters. M10bn is its
deterministic form.

## Uncovered

- **M9, the destination bound, is equivalent on the fix.** The block is
  sized from the same bytevectors the fill copies, so no input reaches the
  bound. Its job is the case M10n and M10bn separate: a sizing that
  disagrees with the fill is a refusal by name in plain `make test` with
  the bound, and an overrun only the memory gate sees without it.
- **The sweeps' strings are four characters,** too short for an expiry to
  land inside Chez's `string->utf8` (the probe above needed 64). M1 is
  caught by the mixes it makes, not by a torn string.
- **M20 and M21, the checked list walk, are equivalent on data that keeps
  still.** Inside the interrupt-free step no engine can change a list, so
  `map` and an unbounded walk read what the checked walk reads. What they
  would do differently, under another thread that breaks a list mid-walk,
  is crash in `#3%map` or walk a made-circular list forever: neither fails
  a row by name. The walk rests on Chez's own source, quoted above.
- **The race row's power is the scheduler's.** It first ran without the
  narrower's spin, and its pass then took about as long as the read. M19
  was caught in each of eight runs at ordinary load, by as few as 1 round
  of 200. But in the sweep on 32ea8d7, run at load averages of 140 to 200
  from other sessions, only 2 to 17 rounds per run overlapped at all, and
  M19 passed. Alternated at that load, the row without the spin passed M19
  twice in three runs, and with the spin failed it by 188, 184 and 190
  rounds while 167 to 182 rounds of the fix overlapped. The spin stays.

## Harness notes

- **Run the sweeps in order, and give each run its own pipes.** The sweeps
  ran under `map` at first, which applies its procedure in no fixed order,
  and shared one pipe of the other loop. On main a broken stdio run consumed
  that pipe, and every later sweep then reported it marked; the evidence
  pointed at the wrong case.
- **A cost measured once under load is not a cost.** The sweeps' callbacks
  first left out the suite's `(collect)`: one run with it took 17 s and one
  without took 4 s. Alternated runs under the same load showed no
  difference (3.8 and 4.0 s without, 4.2 and 3.9 s with; under Valgrind 43
  and 42 s, 45 and 69 s), so the callbacks collect, as the suite's rule
  says. The 17 s had been the machine: load averages of 40 to 116, from
  other sessions.

## Found on the way, not fixed here

- **A stdio handle can change state between the checks and `uv_spawn`.**
  The read makes the caller's data private; it cannot fence the handles. An
  engine sweep on 0e6a8e1 with a stdio pipe closed at the first expiry: of
  216 runs, 58 were refused `&uv-handle-closed` and 157 spawned on the
  closed pipe, and the process's open descriptors went from 8 to 150. With
  the pipe consumed instead, by a spawn from the handler: 141 runs were
  refused `spawn-failure-state-unclassifiable` (libuv forked, then found
  the pipe open: ADR-0015 decision 5's state), 58 `pipe-already-used`, 16
  spawned. Checking the handles' state, calling `uv_spawn` and marking the
  pipes in one interrupt-free step would close it, the `with-send-fence`
  shape. The loop being torn down from a handler mid-call belongs to the
  same window (not measured).
- **Another thread changing an argument list during the call** can still
  make `length` raise its own error mid-read; `docs/api.md` says so. The
  read stays within what it checked.
- **Three TCP suites failed in stretches, on main and on this branch
  alike,** while other sessions' TCP mutation sweeps ran on this machine
  (load averages 20 to 116). Alternating a0ea0ca and the fix, five runs
  each: test-facade failed 5 of 5 on each (its seven TCP rows, exit 255; its
  chain gets 32 loop steps), test-flow 3 of 5 on each (five rows), and
  test-stream 1 and 2 of 5 (its shrinking-payload sweep rows). Later runs of
  the same tree passed all three.

## Gates

On 9c50b89's tree (eb2851b), macOS arm64:

- `make test`: 22 suites pass (test-process: 124 rows; 179 of 200 race
  rounds overlapped).
- `make test-memory` (ASan): 22 suites pass, the race row included (175 of
  200 rounds overlapped). That arm sees the shim's own `memcpy` (it
  aborts on cases 1 and 2 on a0ea0ca's code, above); an earlier belief that
  it could not came from probes run under `timeout`.
- `make check-memory-gate`: the planted libc overrun was caught, MEMORY GATE
  CAN FAIL.
- `make check-purity` holds, and `make check-help` is silent.

`make test-memory-docker` (Linux aarch64, Valgrind, vendored libuv 1.52.1)
from a `--no-hardlinks` clone of 9c50b89, make exit 0:

- `check-memory-gate` caught the store overrun, the libc overrun and the
  leak, stayed consistent on the possible leak, and printed MEMORY GATE CAN
  FAIL.
- Every one of the 22 suites' own Valgrind summaries: 0 errors and 0 bytes
  definitely lost, at 773 to 16,198 allocations each (`test-process.sps`:
  16,198, its sweeps taking the same 403, 376, 374 and 380 runs as on
  macOS, its race row skipped). No invalid read or write anywhere in the
  log.
- The two forked children that `_exit` before exec report 131 B and 117 B
  definitely lost: the known fork artifacts, which never gate (ADR-0003).
