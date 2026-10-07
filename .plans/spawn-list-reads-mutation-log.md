# uv-spawn!'s lists, read once: mutation log

Evidence for #66 items 2 and 3, and #64 item 4. `uv-spawn!` reads its
lists with `(libuv private lists)`'s `read-proper-list`, where it measured
each with `list?` and then `length`. It reads each pair of a pipe spec
once, and it reads its strings with `read-utf8`, the copy-then-encode that
`c-string-bytes` now shares from `(libuv private c-string)`.

## The faults

`uv-spawn!` reads `file`, `args` and `options` once, in one interrupt-free
step (#56). The step holds engines off, but not another thread.

- **`read-list`** (`src/libuv/process.sls`, #56) asked `list?`, then took
  `length`, then walked at most that many pairs, checking each, and
  answered what it had read when it met a non-pair. It never required the
  list's end.
  - A list another thread cut between `list?` and `length` made `length`
    raise its own condition, which escaped `uv-spawn!` instead of
    `&uv-invalid-argument`.
  - A list cut during the walk was read as the part before the cut, and
    one made circular there was walked around its cycle for the count.
    Either way the call went on with a list the caller never had.
  - At `--optimize-level 3`, where Chez 10.4.1 inlines `length` with no
    pair, cycle or trap check, `length` read through the cut, and walked a
    list made circular for good forever, with interrupts disabled.
- **`read-stdio-spec`** checked a pipe spec's second pair as `(cdr rest)`,
  then read it again as `(cddr rest)` and `(cadr rest)`. Cut in between,
  Chez's own `cddr` raised; at level 3 the second read went through the
  cut.
- **`read-string`** and `c-string-bytes` each wrote the copy-then-encode
  recipe and the NUL scan (#64 item 4). `c-string-bytes` took its copy
  inside `with-interrupts-disabled`, a dynamic-wind: 64 B a call.

### Measured on main's code

A probe ran main's `read-list` and `read-stdio-spec`, copied out, and this
branch's `read-proper-list`, against a flipper thread, 100,000 reads a
variant (macOS arm64, Chez 10.4.1, load near 4):

| flipper | main's `read-list` | `read-proper-list` |
|---|---|---|
| third cdr ↔ a vector | 7,333 raised `length`'s condition; 1,361 read short | the list or `#f` |
| third cdr ↔ a longer tail | 3,253 read the stale count's worth of the longer tail | the list, the longer list, or `#f` |
| third cdr ↔ the head | 5,925 read around the cycle for the count | 88 read once around the cycle, then to the end |
| a pipe spec's second pair ↔ 0 (`read-stdio-spec`) | 68 raised `cddr`'s condition | the spec, or a spec of no kind |

At level 3 a thread made the list circular for good at a moment of its
own, while main's `read-list` read it until `list?` saw the cycle. The
first of 3,000 such trials hung, killed at 90 s. At the default level the
same 3,000 trials finished, and 306 raised `length`'s "is circular".

## The change

- `read-spawn-request` and `read-option` read `args`, `options`, `env` and
  `stdio` with `read-proper-list`: counted with `proper-length`, walked at
  most that many pairs, each checked before it is read through, and the
  end required after them. It answers `#f` for a list that is not one
  proper list as it read it, and the checks refuse that with the list's
  reason, as on entry.
- `read-stdio-spec` reads `(cdr rest)` once, and each pair after it once.
- `(libuv private c-string)` gains `read-utf8`, the copy taken with
  interrupts disabled and then encoded (`#f` for a non-string), and
  `nul-free?`, the NUL scan. `uv-spawn!` reads with the first inside its
  step and checks with the second after it; `c-string-bytes` uses both at
  once, and `c-string?` uses the scan. `read-utf8` disables interrupts with
  a bare pair, which allocates nothing, so it hands `string-copy` only a
  string, which raises nothing between the two.

**Cost.** `c-string-bytes` allocates 112 B for `"127.0.0.1"`, down from
176 B. Four strings read inside one interrupt-free step cost 304 B with
the bare pair, as with no fence at all, and would cost 560 B with a nested
`with-interrupts-disabled`. A spawn allocates slightly less than on main:
argv of 3 went 1,040 → 1,008 B, argv of 3 with a 40-string env 5,600 →
5,536 B, and argv of 3 with three ignored stdio slots 1,136 → 1,104 B (the
fewest of 32 spawns).

## A read is not a snapshot

`read-proper-list`'s comment (#69) said a list changed during the read
"answers as the walk found it, or `#f`: never a list it never was". That
holds for a list changed once, but not for one changed several times. A
thread that makes a list circular and whole again, during both the count
and the walk, gets it read once around its cycle: `(0 1 2 0 1 2 3 … 11)`,
its elements in an order it never held. In three probe runs at load near
2, 67, 76 and 74 of 100,000 reads answered that, each exactly once around,
and none answered anything else. At load near 200 the same probe saw 0, 0
and 1. No read that takes no lock can rule this out. The comment now says
so, and so does ADR-0009. `uv-spawn!`'s read is one interrupt-free step, so
only another thread can do this to it, and `docs/api.md` already allows
that a thread's change can reach the child mixed.

## Tests

- **`tests/spawn-list-races.sls`** (new, shared) holds six races. In each,
  a flipper thread turns one cdr of a list a call is given, while this
  thread calls `uv-spawn!` with it 100,000 times. Every call is refused
  before anything is allocated: with the list whole, for something the
  list holds after the flipped pair; with it cut, for the list itself. A
  read that stops short skips that last element, so its call goes on and
  is refused for its pipe, which is on another loop (`'pipe-wrong-loop`).

  | race | whole | cut |
  |---|---|---|
  | `args`, third cdr ↔ a vector | `'embedded-nul` (the last string) | `'args-not-a-string-list` |
  | `args-circular`, third cdr ↔ the head | `'embedded-nul` | `'args-not-a-string-list` |
  | `env`, third cdr ↔ a vector | `'embedded-nul` | `'env-not-a-string-list` |
  | `options`, third cdr ↔ a vector | `'uid-out-of-range` (the last entry) | `'option-unknown` |
  | `stdio`, third cdr ↔ a vector | `'stdio-fd-not-an-fd` (the last spec) | `'stdio-not-a-list` |
  | `pipe-spec`, `(pipe p from-child)`'s second cdr ↔ 0 | `'pipe-wrong-loop` | `'stdio-spec-unknown` |

  In `args-circular` a read can go around the cycle, but every walk to the
  list's end passes its last string, so the same two reasons hold. Before
  the first call and after the last, each race waits up to 10^8 steps to
  see its flipper cut the list and make it whole again (#67), watching the
  pair through the argument the calls are given. The library also checks
  each of the four lists improper and circular from the start, with no
  thread (`malformed-refusals`); each call there names the pipe on another
  loop too, so a read that took a malformed list for a shorter one is
  refused rather than spawning.
- **`tests/test-process.sps`**:
  - the six race rows and a precondition row holding every flipper live,
    skipped under Valgrind, which runs one thread at a time;
  - the malformed lists, which need no thread and run under Valgrind too;
  - a NUL at an args string's first or last byte;
  - **level 3.** `tests/spawn-level-3-child.sps` runs the races and the
    malformed lists at `--optimize-level 3` in two children: the five cut
    races in one, and in the other the circular race and the malformed
    lists, whose circular ones a read counting with `length` walks
    forever. A child still running after 6,000 polls of 10 ms is killed. A
    seed row holds that both ran at level 3, and the rows skip without
    `CHEZ_LIBUV_TEST_CHEZ`.
- **`tests/test-c-string.sps`** (new, pure, in `PURE_TESTS`):
  - `read-utf8` answers a string's UTF-8 and `#f` for anything else, and
    leaves interrupts enabled either way. The row undoes any disable left
    outstanding, so a mutant fails it rather than stalling the engines
    after it.
  - `nul-free?` finds a NUL anywhere in its first END bytes, and looks no
    further; `c-string?` accepts exactly a bytevector whose only NUL is its
    last byte; `c-string-bytes` answers UTF-8 and one NUL, and refuses a
    NUL of its own, naming its caller and reason.
  - A cost row: `c-string-bytes` allocates what its copy, the copy's UTF-8
    and its answer cost made directly. The difference is 0, where main
    gives 64. A second element holds the meter live.
  - Pure, so a mutant of these procedures fails rows here by name. Every
    suite that loads `native.sls` instead fails at import, since its
    constant table checks each name with `c-string?` (#72).
- **`tests/test-native.sps`** gains a cycle race: `read-proper-list`
  against a flipper that makes the list circular and whole again. Every
  read answers `#f` or a walk of the list to its end, around the cycle as
  often as it found it there, and an informational line counts the walks
  that went around. A read that did not require the end fails it.

## On main

The new rows on main's `process.sls` (bfd2bbe) all fail by name, and the
precondition rows pass, so each flipper was live. At load near 4:

| row | wrong calls of 100,000 | first wrong outcome |
|---|---|---|
| `args` | 13,493 | `'pipe-wrong-loop` (read short) |
| `args-circular` | 7,920 | `'pipe-wrong-loop` |
| `env` | 14,900 | `length`'s "is not a proper list" |
| `options` | 21,439 | `length`'s "is not a proper list" |
| `stdio` | 24,418 | `length`'s "is not a proper list" |
| `pipe-spec` | 1,709 | `cddr`'s "incorrect list structure" |
| level 3: `args`, `env`, `options`, `stdio`, `pipe-spec` | 11,620, 14,287, 15,482, 6,178, 41 | `invalid memory reference` for `args` and `options`, else as above |
| level 3: `args-circular` | 3,730 | `'pipe-wrong-loop` |

At load near 140 the same rows found 9 to 443 wrong calls a race: a
flipper starved of CPU flips less often. Either way every race row fails.

The malformed lists and the NUL row pass on main: `list?` refuses an
improper or circular list, and main's scan reached every byte. They hold
shapes main never had; P6 and S1 below show what each catches.
`tests/test-c-string.sps` cannot load on main, which has no `read-utf8`,
so its rows are held by the mutations too.

## Mutations

Each ran on a scratch copy of `src/` and `tests/` (`build/` linked in),
every target replaced exactly once, at load near 4. The process mutations
ran test-process.sps; the c-string ones test-c-string.sps,
test-native.sps, test-addrinfo.sps and test-address.sps. In the scratch
copies, test-native.sps fails three shim-path rows in every run, the
control included, which look for the shim under the working directory;
the table leaves them out.

| id | mutation | failed rows |
|---|---|---|
| P1 | `args` read with main's `read-list` | the `args` and `args-circular` race rows, and both level-3 race rows |
| P2 | `options` read with main's `read-list` | the `options` race row, and the level-3 cut row (`invalid memory reference`) |
| P3 | `env` read with main's `read-list` | the `env` race row, and the level-3 cut row |
| P4 | `stdio` read with main's `read-list` | the `stdio` race row, and the level-3 cut row |
| P5 | `read-stdio-spec` as on main, the second pair read twice | the `pipe-spec` race row, and the level-3 cut row |
| P6 | `args` counted with a guarded `length` (#51's shape), the walk unchanged | the level-3 circular child, killed at the cap: the seed row, the `args-circular` and malformed rows, and the level-3 precondition |
| P7 | `args` read without requiring the end | the `args-circular` race row, at both levels |
| P8 | a pipe spec's end not required | "a (pipe ...) spec with more than a pipe and a direction", and "validation created no process handle" |
| P9 | a pipe spec's rest read as a pair unchecked | "a (pipe) spec with no pipe" |
| S1 | `check-string` misses a final NUL | the new NUL row, "validation created no process handle", and the `env` race rows |
| S2 | `check-string` scans nothing | 13 rows, every NUL row among them |
| C1 | `read-utf8` hands `string-copy` a non-string | both `read-utf8` rows |
| C2 | the copy taken with interrupts enabled | test-addrinfo: "a node truncated during validation answers the bytes of one reading" |
| C3 | the copy inside `with-interrupts-disabled`, as on main | the cost row (64) |
| C4 | interrupts never enabled again | the interrupts row; test-native's engine sweeps and test-addrinfo's sweeps fail by name, and both then deadlock in a race |
| N1 | `nul-free?` starts at byte 1 | the `nul-free?` and `c-string?` rows; the address-NUL rows of test-native and test-address |
| N2 | `nul-free?` misses the byte before END | the `nul-free?`, `c-string?` and `c-string-bytes` rows; 7 rows of test-address |
| N3 | `nul-free?` ignores END | the `nul-free?` and `c-string?` rows; test-native and test-address cannot load (`&uv-constant-unavailable: UV_RUN_DEFAULT`) |
| K1 | `c-string?` asks for no terminator | the `c-string?` row; test-native's two "not one C string" rows |
| B1 | `c-string-bytes` refuses no NUL | the `c-string-bytes` row; 4 rows of test-addrinfo, 5 of test-address, 1 of test-native |
| B2 | `c-string-bytes` answers no terminator | the `c-string-bytes` row; 11 rows of test-addrinfo, 5 of test-address, 1 of test-native |
| F1 | a flipper that never flips | both precondition rows (`not-flipping`) |
| F2 | the `args` flipper turns another pair than the one watched | both precondition rows, for `args` |
| F3 | a flipper that cuts and never makes the list whole | both precondition rows |
| F4 | a flipper that swaps the cut for another bad value | both precondition rows |
| F5 | F4, and the watch without its "whole again" check | none: passes |
| F6 | every outcome counted right | none: passes |
| F7 | the children run without `--optimize-level 3` | the seed row alone (`(0 0)`) |
| F8 | a level-3 cap of 1 poll | all five level-3 rows (`killed-at-cap`) |

27 of the 29 fail rows by name. F5 and F6 pass as their pairings require.

- **F5** shows the watch's "whole again" check is what catches F4: without
  it a flipper that never restores the list passes as live.
- **F6** shows the outcome classification is what catches main: main's
  `process.sls` with F6 passes all 153 rows, where alone it fails 8.
- **P6** passes every default-level row: there the guard catches what
  `length` raises. Only the level-3 malformed lists see it, where a
  circular list hangs `length`, killed after the 60 s cap. Its cost, a
  guard of 256 to 272 B a list, is not held by a row.
- **C2** is invisible to the pure suite, which changes no string mid-copy.
  For `uv-spawn!` it is equivalent: its read step disables interrupts
  around the whole read.
- **C4 and N3** fail rows by name in `tests/test-c-string.sps`. Elsewhere C4
  leaves interrupts off for good, so test-native and test-addrinfo, after
  failing their sweeps by name, deadlock in their thread races (killed). N3
  breaks `c-string?` for every constant name, so native.sls does not load.
  That is why these rows live in a pure suite.

The control run of the same copies passes every suite, but for
test-native's three shim-path rows.


## Gates

At load averages near 3 to 14, after another session's 96-hog window:

- `make test`: 25 suites pass. tests/test-c-string.sps is new (6 rows);
  test-process has 153 rows (was 139) and test-native 316 (was 314).
- `make test-threading`, `make check-purity` (six suites, test-c-string
  among them) and `make check-help` pass.
- macOS ASan, `make test-memory`: 25 suites pass with no AddressSanitizer
  report. Every race was live (30,843 to 87,520 calls of 100,000 found
  their list cut), and the level-3 rows ran.
- The Valgrind skip path, run natively with `CHEZ_LIBUV_UNDER_VALGRIND=1`:
  the thread races skip in both suites, and the malformed and level-3 rows
  still run. test-native passes. test-process fails one row, #68's
  squatter row, which picks its expectation by that variable: with no real
  memory tool the allocator does reuse the freed blocks. main (bfd2bbe)
  fails it the same way, run the same way. Valgrind itself is left to CI.
- At a load near 160 from that window, test-process passed in 93 s and the
  level-3 children took 6 to 13 s each (about 1 s of CPU); at low load the
  suite takes 3 to 6 s.
