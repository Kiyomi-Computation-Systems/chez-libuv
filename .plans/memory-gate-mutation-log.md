# The memory gate was vacuous on both arms: mutation log

Evidence for `fix/memory-gate-traces-chez`. `make test-memory` was not
checking the Chez process that runs the suites, on either platform. This
change makes both arms live and adds `make check-memory-gate`, which requires
the real recipe to fail on planted defects. ADR-0003's 2026-09-27 amendment
records the decision; this file records the measurements.

Environment, unless a line says otherwise:

- **macOS:** arm64, Chez 10.4.1 (`tarm64osx`), make 3.81, brew coreutils
  `timeout`, and the ASan runtime from Xcode's clang 21
  (`libclang_rt.asan_osx_dynamic.dylib`). SIP was enabled.
- **Linux:** the `chez-libuv-valgrind:10.4.1` image: Debian bookworm on
  aarch64, Valgrind 3.19.0, vendored libuv 1.52.1 (`HAVE_PKG=no`), run as
  the unprivileged `dev` user.

A worktree's `.git` is a pointer file that the container cannot resolve, so
every Linux run used a real clone in the session scratchpad, with submodules
cloned `--reference … --dissociate`.

Every mutation ran on a copy outside the repo: a second scratch clone on
macOS, and `/tmp/mut` inside the container. CI's valgrind job has been
billing-blocked since 2026-09-19, so the only x86_64 evidence is one
emulated run, recorded under "Markers".

---

## The defects

### Linux: Valgrind's client was `timeout`, from #14 (17b62b0, 2026-08-30)

#14 capped each suite by putting `$(TIMEOUT_BIN) 900` between `valgrind` and
`$(CHEZ)`. Valgrind checks the command it is handed and does not follow an
exec (`--trace-children=no`), so it checked `timeout`, and Chez ran
natively. This is the pre-fix recipe on a planted one-byte overrun
(`foreign-set!` one byte past a 16-byte `foreign-alloc`):

```
make CHEZ=scheme HAVE_PKG=no test-memory MEMORY_TESTS=/tmp/bad.sps   -> exit 0
==2527== Command: /usr/bin/timeout 900 scheme --program /tmp/bad.sps
==2527==   total heap usage: 2 allocs, 2 frees, 44 bytes allocated
==2527== ERROR SUMMARY: 0 errors from 0 contexts (suppressed: 0 from 0)
```

`git tag --contains 17b62b0` returns v0.6.0 and v0.7.0. v0.5.0 (2628dd0) is
not a descendant, so it was really gated.

Something did visibly change when #14 landed, and nobody noticed. The
`docs/building.md` paragraph written in #10, just before #14, describes
eighteen leak summaries for sixteen suites, two of them non-zero on arm64.
After #14 every summary was `timeout`'s, one per suite, and all were zero.

### macOS: ASan never reached Chez, from v0.1 (35f290b)

The ASan arm set `DYLD_INSERT_LIBRARIES` on `sh -c 'for t in …; do chez …'`.
Two mechanisms each drop the preload, and both were measured with a probe
that `memset`s 24 bytes into a 23-byte block:

| launch shape | exit | ASan report |
|---|---|---|
| `env DYLD_INSERT_LIBRARIES=… chez --program p` | 134 | heap-buffer-overflow, `0 bytes after 23-byte region` |
| `DYLD_INSERT_LIBRARIES=… sh -c 'chez --program p'` (the v0.1 recipe) | 0 | none |
| `DYLD_INSERT_LIBRARIES=… timeout 60 chez --program p` | 0 | none |
| the same, with `ASAN_OPTIONS=…:strip_env=0` | 134 | heap-buffer-overflow |
| `timeout 60 /usr/bin/env DYLD_INSERT_LIBRARIES=… chez --program p` | 134 | heap-buffer-overflow |
| no preload | 0 | none |

- **SIP.** `DYLD_INSERT_LIBRARIES=/x FOO=bar sh -c 'echo …'` prints `FOO`
  and an empty `DYLD_INSERT_LIBRARIES`. With `DYLD_PRINT_LIBRARIES=1`, a
  direct launch loads `libclang_rt.asan_osx_dynamic.dylib` ("has
  interposing tuples"), and the `sh -c` launch does not load it. The brew
  `chez` binary itself honours DYLD variables: it is ad-hoc signed, with no
  hardened runtime.
- **ASan's `strip_env`.** ASan's Darwin runtime removes itself from
  `DYLD_INSERT_LIBRARIES` in the process it loads into, so a wrapper gets
  ASan and its child does not. It bit this session too. A first "all 17
  suites pass under ASan" run went through `timeout` and was vacuous: every
  suite finished at native speed. The rerun below is direct, and every log
  carries the `verbosity=1` witness.

`spike/dns/FINDINGS.md` Q2's ASan runs were live, because they invoked `chez`
directly and printed the `libc interceptors initialized` witness. The make
target never was.

---

## The fix

- **Linux:** `$(TIMEOUT_BIN) N valgrind … $(CHEZ) --program $t`. The cap
  wraps Valgrind, and a hang is still reported as `HUNG` (exit 124).
- **macOS:** the loop runs in the recipe's own shell, and
  `DYLD_INSERT_LIBRARIES` is set on each `$(CHEZ)` command, with nothing in
  between.

---

## The check: `make check-memory-gate`

`tests/memory-gate-sabotage.sps` plants one defect, chosen by
`CHEZ_LIBUV_SABOTAGE`. `check-memory-gate` runs `$(MAKE) test-memory
MEMORY_TESTS=tests/memory-gate-sabotage.sps` for each of the platform's
defects, and requires three things:

1. a plain run with no tool exits 0 and prints `memory-gate-sabotage:
   planted <mode>`;
2. the gate exits non-zero;
3. the gate's log contains the tool's own report of the defect.

### Markers

Each marker was measured on 3 of 3 runs, directly under the gate's Valgrind
flags:

| mode | defect | Valgrind (Linux) | ASan (macOS) |
|---|---|---|---|
| `store-overrun` | `foreign-set!` 1 byte past a 23-byte block | `0 bytes after a block of size 23 alloc'd` | **not seen**: exit 0 under live ASan (the witness was printed) |
| `libc-overrun` | `memset` of 30 bytes into a 29-byte block | `0 bytes after a block of size 29 alloc'd` | `0 bytes after 29-byte region` |
| `leak` | `foreign-alloc 777`, dropped | `777 bytes in 1 blocks are definitely lost` | not applicable (`detect_leaks=0`; no LeakSanitizer on arm64) |

So Linux runs all three modes and macOS runs `libc-overrun`. `memset` is not
a foreign entry until libc is loaded, on either platform: `foreign-entry?`
returned `#f` on both.

x86_64 was checked once, under emulation, in a `--platform linux/amd64`
Debian bookworm container with Valgrind 3.19.0 and Debian's Chez 9.5.8. All
three reports read exactly as above. CI's own Valgrind versions were
measured the next day, after review; see "Review follow-ups" below. If the
wording ever drifts, the check fails loudly with "failed, but not on the
planted defect". It cannot pass silently.

### Red, then green

With the check in place and both recipes still unfixed:

- **macOS:** `MEMORY GATE VACUOUS: make test-memory exited 0 with the
  libc-overrun defect planted`. The log shows `memory-gate-sabotage: planted
  libc-overrun` printed inside the "ASan" arm, which cannot happen when ASan
  is loaded, because ASan aborts at the `memset`.
- **Linux:** `MEMORY GATE VACUOUS` for all three modes. Every log shows
  `Command: /usr/bin/timeout 900 scheme …` and `2 allocs, 2 frees, 44
  bytes`.

After the fix, macOS prints `gate caught libc-overrun: 0 bytes after 29-byte
region` and `MEMORY GATE CAN FAIL`. Linux prints `gate caught` for all three
modes, with `Command: scheme --program tests/memory-gate-sabotage.sps` and
about 396 allocations per run.

---

## Mutations

### macOS (scratch clone)

| # | mutation | check-memory-gate |
|---|---|---|
| — | control: fixed and unmutated | exit 0, `gate caught libc-overrun`, `MEMORY GATE CAN FAIL` |
| A1 | the v0.1 shape: the loop under `sh -c` | exit 2, `MEMORY GATE VACUOUS … libc-overrun` |
| A2 | the ASan arm through `timeout(1)` | exit 2, `MEMORY GATE VACUOUS … libc-overrun` |
| A3 | the `DYLD_INSERT_LIBRARIES` line deleted | exit 2, `MEMORY GATE VACUOUS … libc-overrun` |
| C2 | an unrelated failure: `ASAN_DYLIB_PATTERN=/nonexistent/x.dylib`, so the recipe refuses | exit 2, `make test-memory failed, but not on the planted libc-overrun` |
| C2′ | the marker test disabled (`elif false`), with C2's refusal | **exit 0, `gate caught libc-overrun`, `MEMORY GATE CAN FAIL`**, while the sub-make had printed `no ASan runtime matched …; refusing` |
| C1 | the sabotage program ends with `(exit 3)` | exit 2, `SABOTAGE NOT CLEAN: the libc-overrun program exited 3` |

C2′ shows that the marker test is load-bearing. Without it, a gate that
never ran a tool is credited. The first C2′ attempt deleted the `elif`'s
body along with its test, and that left a shell syntax error ("syntax error
near unexpected token `else'"). It failed for the wrong reason and proved
nothing, so it was narrowed to replace only the test.

### Linux (`/tmp/mut` in the container)

| # | mutation | check-memory-gate |
|---|---|---|
| — | control: fixed and unmutated | exit 0, all three `gate caught`, `MEMORY GATE CAN FAIL` |
| M1 | the #14 shape: the cap inside Valgrind | exit 2, `MEMORY GATE VACUOUS` for store-overrun, libc-overrun and leak |
| M2 | `--error-exitcode=9` dropped | exit 2, `MEMORY GATE VACUOUS` for all three |
| M3 | `--leak-check=full` dropped | exit 2: store-overrun and libc-overrun caught, **leak `VACUOUS`** |
| M4 | `--errors-for-leak-kinds=possible` | exit 2: both overruns caught, **leak `VACUOUS`** |
| C2 | an unrelated failure: Valgrind rejects a `--bogus-flag` | exit 2, `failed, but not on the planted` for all three |
| C1 | the sabotage program ends with `(exit 3)` | exit 2, `SABOTAGE NOT CLEAN … exited 3` for all three |
| C1′ | the clean-run guard disabled, plus M2, plus C1 | **exit 0, all three `gate caught`, `MEMORY GATE CAN FAIL`**, on a gate with no `--error-exitcode` |

- **M4 needs the exit-status test.** Valgrind still *prints* `777 bytes in
  1 blocks are definitely lost` under `--show-leak-kinds=definite`, but it
  exits 0. A marker-only check would credit it.
- **C1′ is why the clean-run guard exists.** With M2 in place, Valgrind
  still prints its report but exits with the program's own status. A
  program that fails by itself then makes a broken gate look like a working
  one.
- **The first Linux sweep's control failed,** and it failed correctly:
  `failed, but not on the planted …` for all three modes. The copy of
  `/work-repo` carried a `build/vendor` CMake cache that names `/work-repo`,
  so the sub-make's `vendor` step refused ("The current CMakeCache.txt
  directory … is different"). That was an unplanned C2. A CMake cache is
  bound to its build directory: a copied tree must rebuild `build/vendor`
  from clean. The sweep now does, and asserts that the cache names
  `/tmp/mut`.

### The HUNG path

This is a one-off check, not a permanent one: the exit-124 branch predates
this change. A program that sleeps for 60 s was run with `make test-memory
MEMORY_TESTS=/tmp/sleeper.sps MEMORY_SUITE_TIMEOUT=3`. It exited 2 after
**4 s**, printed `HUNG: /tmp/sleeper.sps exceeded 3s under valgrind and was
killed`, and the Valgrind client was `scheme`. No sleeper process was left
behind.

---

## Forked children: artifacts, and deliberately non-gating

With the fixed order and `--log-file=…/vg.%p.log`, `test-process.sps`
produced 21 logs:

- the suite's own process, with 0 errors;
- 18 children that reached `exec` (banner only);
- 2 children that did not, with one error each. They report 131 and 117
  bytes definitely lost, from `malloc` ← `s_malloc` (Chez's `foreign-alloc`)
  ← a JIT frame.

Two probes ran in a scratch copy:

- **A, identity.** `build-options-block` printed each block's size. 131
  bytes matches exactly one spawn, `file=/nonexistent/definitely-missing`,
  which is the ENOENT row. Several `/bin/sh` spawns use 117 bytes, and the
  stdio-setup EINVAL row, the other child that exits before `exec`, is
  among them.
- **B, mechanism.** A 333-byte `foreign-alloc` was held by the suite for its
  whole run and freed before `(exit …)`. The same two children then
  reported **464 = 131 + 333** and **450 = 117 + 333** bytes. The parent
  stayed at 0 errors.

So each child "leaks" whatever Scheme-referenced foreign memory the parent
held when `uv_spawn` forked. It `_exit`s inside `uv_spawn`, before the
parent's `free-options-block!` runs, and Memcheck cannot see Chez's tagged
references. These are fork artifacts. libuv discards such a child's exit
status (it reads errno from its pipe), so they never gated, and should not.

Rejected alternatives:

- **`--child-silent-after-fork=yes`** changes no gate outcome. It would
  also delete the only diagnostic for a fault in the pre-exec window, where
  libuv's child reads the marshalled file/args/env/cwd, and so it would
  remove evidence.
- **`--trace-children=yes`** was measured on `test-process.sps`. It traced
  24 processes, every `exec`'d `/bin/sh -c …` and `/bin/cat` included, took
  13 s against the reorder's 10 s, and still passed (112). No child report
  reached the make log. It adds checks of other programs, not of this
  binding.

---

## Full runs, both arms live

- **Linux, `make CHEZ=scheme HAVE_PKG=no test-memory`:** exit 0 in 163 s.
  All 17 suites ran as `Command: scheme --program tests/test-*.sps`. Each
  suite's own process reported `ERROR SUMMARY: 0 errors` and `definitely
  lost: 0 bytes in 0 blocks`, and no Valgrind client was `timeout`. There
  were 19 summaries in total: the 17 suites plus the two artifact children
  (117 and 131 bytes).
- **`make test-memory-docker`,** the real target run from the scratch
  clone, runs `check-memory-gate` and then `test-memory`. It exited 0 in
  188 s. `check-memory-gate` printed `gate caught` for all three modes and
  `MEMORY GATE CAN FAIL`. `test-memory` then ran all 17 suites as
  `scheme --program …`, each suite's own process at 0 errors and 0 bytes
  definitely lost. The only other summaries were the two artifact children
  (117 and 131 bytes), and no Valgrind client was `timeout`.
- **macOS, `make test-memory`:** exit 0 in 8 s, 17 suites, 0 ASan reports.
  `check-memory-gate` shows through this same recipe that ASan is live. A
  direct run of each suite printed the `verbosity=1` witness in all 17 logs.
- **macOS, `make test`:** all 17 suites passed. `check-help` and
  `check-purity` also passed.

---

## Documentation claims, measured before they were written

`docs/building.md` and ADR-0003 now state what the live ASan arm can see.
Each claim was probed on both tools:

| probe | macOS, ASan live | Linux Valgrind |
|---|---|---|
| `foreign-ref` of a freed 23-byte block | missed (exit 0) | `Invalid read of size 1 … inside a block of size 23 free'd` |
| `memcpy` of 30 bytes into a 29-byte block | heap-buffer-overflow (exit 134) | `Invalid write of size 2 … inside a block of size 29 alloc'd` |
| double free | `attempting double-free` (exit 134) | `Invalid free()` |

A double free also aborts plain macOS malloc (exit 134 with no tool), which
is why it cannot be a sabotage witness: a red gate would not prove the tool
was loaded.

---

## Not covered

- **`--undef-value-errors=no` and `--show-leak-kinds=definite`.** These are
  pre-existing decisions (ADR-0003's 2026-08-18 amendment) and were not
  re-mutated here.
- **Faults in the pre-exec window of a forked child.** These stay visible
  and non-gating, by decision (above). The spawn-options block is one
  allocation that the parent also reads, so a freed or undersized block is
  mostly caught in the parent. A child-only fault needs, for example, the
  last string's NUL terminator to fall one byte past the block.
- **The macOS arm still has no per-suite cap,** which is pre-existing. Any
  cap added there must not sit between `DYLD_INSERT_LIBRARIES` and `chez`
  (A2 above).

---

## Review follow-ups (2026-09-28)

A `/code-review high` pass on PR #37 raised seven findings. Four were fixed
(1, 2, 4 and 6) and three were left as they are (3, 5 and 7).

### 1. The Linux libc-overrun marker depended on how `memset` stores

The review's concern: the marker `0 bytes after a block of size 29 alloc'd`
assumed that the tail of the overrun is written a byte at a time, and it had
been measured only on Valgrind 3.19.

**CI's own Valgrind versions were then measured,** under emulation
(`--platform linux/amd64`, the distribution's `valgrind` and `chezscheme`):

| image | Valgrind | store-overrun | libc-overrun | leak |
|---|---|---|---|---|
| ubuntu:24.04 (today's `ubuntu-latest`) | 3.22.0 | `0 bytes after a block of size 23 alloc'd` | `0 bytes after a block of size 29 alloc'd` | `777 bytes in 1 blocks are definitely lost` |
| ubuntu:26.04 (`ubuntu-latest` from 2026-10-19) | 3.26.0 | the same | the same | the same |

So the reviewed marker would have held on every version measured, and the
failure scenario did not occur in practice. The dependency was real all the
same, and one mutation shows it. W1 changes the planted `memset` to 32
bytes, which makes Valgrind's replacement end in an 8-byte store. Valgrind
3.19 then reports `Invalid write of size 8 … 24 bytes inside a block of size
29 alloc'd`, and the reviewed marker raised a false alarm on that run. The
marker is now `a block of size 29 alloc'd`: it names the planted block and
not where in it the store landed. The Scheme-store marker stays exact,
because Chez's `unsigned-8` store is one byte wide on every platform.

In `/tmp/mut` in the container, libc-overrun mode only:

| # | mutation | check-memory-gate |
|---|---|---|
| — | control, new marker | `gate caught libc-overrun: a block of size 29 alloc'd` |
| C2 | an unrelated failure: Valgrind rejects `--bogus-flag` | `failed, but not on the planted libc-overrun` |
| S1 | the wrong block: sentinel 31 (`memset` 32) | `failed, but not on the planted libc-overrun`; the report names `a block of size 31` |
| W1 | wider stores: `memset` 32 into the 29-byte block, new marker | `gate caught` |
| W1′ | W1 with the reviewed (old) marker | `failed, but not on the planted libc-overrun`: the false alarm |

### 2. `make -n check-memory-gate` reported the gate VACUOUS

make runs any recipe line that names `$(MAKE)` even under `-n`, `-t` and
`-q`, and check-memory-gate's recipe is a single line. Before the fix, a dry
run really ran the planted program and a sub-make that only printed
test-memory's commands. It then reported the gate vacuous.

- **make 3.81 (macOS):** `make -n check-memory-gate` exited 2 with
  `MEMORY GATE VACUOUS … libc-overrun`, and wrote
  `build/check-memory-gate-libc-overrun.log`.
- **make 4.3 (container, from the old Makefile):** it exited 2 with
  `MEMORY GATE VACUOUS` for all three defects, and wrote all three logs.

The recipe now re-enters make through `MEMORY_GATE_MAKE = $(MAKE)`. On
both make versions, make did not treat a line that reaches `$(MAKE)` only
through the alias as recursive. After the fix, on both 3.81 and 4.3:

- `make -n` exits 0, prints the recipe, and runs nothing. No check output
  is printed and no log is written.
- `make -t` exits 0 and `make -q` exits 1, and neither writes a log.
- A real `make check-memory-gate` is unchanged: green on both platforms.

### 4. The C library's name was guessed from `(machine-type)`

The planted program now tries `libc.so.6`, `libc.dylib`, `libc.so.7`,
`libc.so` and `msvcrt.dll` in turn until `memset` resolves. If none does, it
exits 4 with `no C library providing memset loaded; tried (…)`.

- **macOS:** `libc.so.6` fails to load and `libc.dylib` succeeds. All three
  plain runs are clean, and the check is green.
- **Debian:** `libc.so.6`. The check is green (above).
- **A mutation with no loadable candidate** fails by name: `SABOTAGE NOT
  CLEAN: the libc-overrun program exited 4`, and its output carries the
  "tried" line.
- **musl (Alpine 3.24, Chez 10.3.0):** all three plain runs are clean. A
  correction to the finding itself: **the old code also worked on musl**.
  musl's loader hands back its own libc for any `libc.*` name, and there
  every candidate "loaded", `libc.dylib` included. The fix matters for
  platforms that name libc otherwise, such as FreeBSD (`libc.so.7`) and
  Windows (`msvcrt.dll`), and for the diagnosis. Neither of those platforms
  was measured.

### 6. The docs hard-coded suite and summary counts

`docs/building.md` now states the rule instead: one summary per suite, plus
one per forked child that exits before `exec`. It no longer cites "seventeen
… nineteen" or the byte counts; the text it replaced ("sixteen …
eighteen") had gone stale unnoticed. The leak sentinel's size is dropped
from that page too. This log and ADR-0003 keep their counts, because they
are dated records.

### Not changed

- **3.** Run the canary inside every `test-memory`.
- **5.** Run the prerequisites once per check instead of once per defect.
- **7.** Keep the sentinel sizes in one place.
