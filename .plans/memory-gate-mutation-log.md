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

---

## Port-back from chez-cmark-gfm (2026-09-28)

chez-cmark-gfm copied this check in its PR #23 (branch
`fix/asan-preload-reaches-chez`) and found three things that apply here
too. Each was measured here before anything changed, on branch
`fix/memory-gate-port-findings`. The environment is as above, plus macOS
26.6.2 (25G83), and GNU Make 4.3 in the Linux image.

**This session's environment already had `MallocNanoZone=0`.** The Claude
desktop app exports it to every process it starts. `Claude`, its
`disclaimer` helper, `claude` and the shell all carry it, and it appears
in no shell profile, no `launchctl` setting and no settings file. So every
"without" leg below ran under `env -u MallocNanoZone`. Run from the app
without `env -u`, the same leg compares `0` with `0`. chez-cmark-gfm's log
does not say how its "unset" legs were unset.

### 1. An empty mode list passed

On the unmodified recipe (fe3cc3e), `make check-memory-gate
MEMORY_SABOTAGE_MODES=` exited 0 and printed only `MEMORY GATE CAN FAIL`.
It wrote no log, because nothing was planted. The check now counts the
modes it runs and fails when there were none.

| # | run | macOS | Linux |
|---|---|---|---|
| — | before the guard | exit 0, `MEMORY GATE CAN FAIL`, no log | not run: the same shell code as E′ |
| E | an empty list | exit 2, `MEMORY_SABOTAGE_MODES is empty; nothing was planted.` (3 of 3, and for `MEMORY_SABOTAGE_MODES=' '`) | exit 2, the same line |
| E′ | E, with the guard's test replaced by `false` | exit 0, `MEMORY GATE CAN FAIL` (3 of 3) | exit 0, `MEMORY GATE CAN FAIL` |

A subset such as `MEMORY_SABOTAGE_MODES=leak` still runs and can pass. It
checks less, which is what the override is for.

### 2. `MallocNanoZone=0` had no measured effect, and is gone

v0.1 (35f290b) added it, saying chez-cmark-gfm "observed this on this
exact recipe". Nothing in this repository ever measured it. The DNS stage
4 and 5 logs and `spike/dns/FINDINGS.md` Q2 list it only as part of the
preload. chez-cmark-gfm has since traced its source run to one where ASan
was never loaded.

These are direct launches, 3 of 3 in every cell. Every ASan run printed
the `verbosity=1` witness, `AddressSanitizer: libc interceptors
initialized`.

| probe | no tool, unset | no tool, `=0` | ASan, unset | ASan, `=0` |
|---|---|---|---|---|
| double free of a 16, 23 or 1024-byte block | 133 (SIGTRAP), no report | 133, no report | 134, `attempting double-free` | 134, `attempting double-free` |
| `memset` 30 into 29 (the libc-overrun plant) | 0 | 0 | 134, `0 bytes after 29-byte region` | 134, the same |
| a clean program | 0 | 0 | 0 | 0 |

- **No run printed a "nano zone" or `malloc:` line.**
- **Once pids, addresses and thread ids are normalized,** each ASan leg's
  stderr is byte-identical with and without the variable, banner included.
- **The mechanism.** Under ASan, every `foreign-alloc` block comes from
  ASan's own allocator. Blocks of 16, 64, 200, 1024 and 100000 bytes land
  at the same addresses with and without the variable (16 bytes at
  `0x602000000130`). The system allocator that the variable tunes never
  sees them. Without a tool, unset, `0` and `1` gave the same block layout
  too.
- **A plain double free depends on block size, not on the variable.** It
  exits 133 (SIGTRAP) from 1 to 4096 bytes, and 134 (SIGABRT) from 32768
  bytes up, with the variable set or unset. This corrects "Documentation
  claims" above: "exit 134 with no tool" holds only for large blocks.

**Through the recipe,** `make test-memory MEMORY_TESTS=df.sps` ran under
`env -u` on a 16-byte and a 100000-byte double free, 3 of 3 each. The old
recipe (with the variable) and the new one (without) both exit 2. Every
log holds `ERROR: AddressSanitizer: attempting double-free` and ends in
ASan's own `Abort trap: 6`. Normalized, the old and new logs are
identical. The bare `Trace/BPT trap` that the old comment warned about
never appeared. That trap is what plain malloc does when ASan is not
loaded.

- **N1:** without the variable, `check-memory-gate` printed `gate caught
  libc-overrun` 3 of 3. It is also green with the app's inherited `=0`,
  and with the variable put back into the recipe (sweep row N1 below).
- **The full run:** `env -u MallocNanoZone make test-memory` exits 0 in
  9 s: 17 suites, 0 ASan reports. A scratch copy of the recipe with
  `verbosity=1` printed 17 witness lines (one per suite), 17 pass
  summaries, 0 reports and 0 nano or `malloc:` lines.

### 3. `possible-leak` holds `--errors-for-leak-kinds=definite`

AGENTS.md's rule, that the gate must not fail on a leak kind it does not
print, was a comment. A probe in the Linux image took 555 bytes from
`foreign-alloc` (3 of 3 in each cell):

| what reaches the block | gate flags | `--errors-for-leak-kinds` removed |
|---|---|---|
| `p+8`, as raw bytes in a live bytevector | exit 0, `possibly lost: 555 bytes in 1 blocks`, 0 errors, no loss record | **exit 9**, the same total, `ERROR SUMMARY: 1 errors`, **no loss record** |
| `p` itself | exit 0, nothing possibly lost (still reachable) | exit 0 |
| nothing | exit 9, `555 bytes in 1 blocks are definitely lost` | exit 9, the same |

Showing and failing on both kinds prints the record: `555 bytes in 1
blocks are possibly lost in loss record 2 of 2`, and exits 9.

**Do the suites have such blocks?** Not their own processes. On fe3cc3e's
recipe, all 17 suite processes report `possibly lost: 0 bytes in 0
blocks`. The only possibly-lost blocks in the run, 1,576 bytes in 4 blocks
each, are in the two forked children that also carry the 131- and 117-byte
fork artifacts (matched by pid), and those never gate. So the Makefile's
old reason for the flag ("a GC runtime's interior pointers … routinely
classify as possibly lost") is not what a run shows. The comment now
states what was measured, and names the check.

The new mode plants the `p+8` block, written with `bytevector-uint-set!`
into a bytevector that `keep-live` holds until exit. The check requires:

- the summary total `possibly lost: 555 bytes in 1 blocks`. Without it
  the mode proved nothing, and the check reports "never counted";
- if the gate failed, the loss record `555 bytes in 1 blocks are possibly
  lost` too. Without it the check reports `GATE RED WITHOUT A REPORT`.

### The sweeps, on the final recipe

Every row ran on a scratch clone whose HEAD held this branch's changes.
The clone was reset to that commit before each row. Each mutation replaced
whole lines, and aborted unless every target line matched exactly once.

**Linux** (`chez-libuv-valgrind:10.4.1`, make 4.3; `store` and `libc` are
the two overruns):

| # | mutation | store | libc | leak | possible-leak | exit |
|---|---|---|---|---|---|---|
| — | control, at both ends | caught | caught | caught | consistent, exit 0 | 0 |
| M1 | `timeout 900` between `valgrind` and `$(CHEZ)` (#14's shape) | VACUOUS | VACUOUS | VACUOUS | never counted | 2 |
| M2 | `--error-exitcode=9` dropped | VACUOUS | VACUOUS | VACUOUS | consistent, exit 0 | 2 |
| M3 | `--leak-check=full` dropped | caught | caught | VACUOUS | consistent, exit 0 | 2 |
| M4 | `--errors-for-leak-kinds=possible` | caught | caught | VACUOUS | **red without a report** | 2 |
| M5 | `--errors-for-leak-kinds` deleted | caught | caught | caught | **red without a report** | 2 |
| M5′ | M5, with the loss-record test replaced by `false` | caught | caught | caught | **consistent, exit 2** | **0** |
| P7 | not a defect: show and fail on `definite,possible` | caught | caught | caught | consistent, exit 2 | 0 |
| PL1 | the plant keeps `p`, not `p+8` | caught | caught | caught | never counted | 2 |
| PL1′ | PL1, with the counted test replaced by `false` | caught | caught | caught | **consistent, exit 0** | **0** |
| C1 | the sabotage program ends `(exit 3)` | not clean | not clean | not clean | not clean | 2 |
| C2 | Valgrind rejects `--bogus-flag` | not on planted | not on planted | not on planted | never counted | 2 |
| C2′ | C2, with the marker test replaced by `false` | **caught** | **caught** | **caught** | never counted | 2 |
| C1′ | the clean-run guard off, plus M2, plus C1 | **caught** | **caught** | **caught** | red without a report | 2 |
| E | `MEMORY_SABOTAGE_MODES=` | — | — | — | — | 2, `nothing was planted.` |
| E′ | E, with the empty-list test replaced by `false` | — | — | — | — | **0, `MEMORY GATE CAN FAIL`** |

- **M5 is the new check's red.** Its log counts the block and shows
  `ERROR SUMMARY: 1 errors` and make's `Error 1`, and holds no loss
  record at all.
- **M5′ and PL1′ are the counterfactuals, and show that both new tests are
  load-bearing.** M5′ credits a gate that fails on a block it never
  prints. PL1′ credits a block that was never possibly lost: its log
  counts it as still reachable (`still reachable: 619 bytes in 2 blocks`,
  which is 555 + 64).
- **M1's logs name the client:** `Command: /usr/bin/timeout 900 scheme …`.
  Every other row that ran Valgrind shows `Command: scheme --program
  tests/memory-gate-sabotage.sps`.
- **C2′ and C1′ still exit 2,** but only because `possible-leak` has tests
  of its own. Both credit the three defect modes wrongly, which is what
  those rows test.
- **`make -n check-memory-gate` on make 4.3** exits 0, prints no check
  output and writes no log. That rechecks #37's review finding 2 against
  the new recipe.

**macOS** (scratch clone; every row under `env -u MallocNanoZone`):

| # | mutation | check-memory-gate |
|---|---|---|
| — | control, at both ends | exit 0, `gate caught libc-overrun` |
| A1 | `sh -c` between the preload and `$(CHEZ)` (the v0.1 shape) | exit 2, `MEMORY GATE VACUOUS`. The log has no ASan report, and it does have the `planted` line |
| A2 | `timeout 600` between the preload and `$(CHEZ)` | exit 2, `MEMORY GATE VACUOUS` |
| A3 | the `DYLD_INSERT_LIBRARIES` line deleted | exit 2, `MEMORY GATE VACUOUS` |
| H | `ASAN_OPTIONS=detect_leaks=0:halt_on_error=0` | exit 2, `MEMORY GATE VACUOUS`, though the log holds ASan's `heap-buffer-overflow` report |
| N1 | `MallocNanoZone=0` put back | exit 0, `gate caught libc-overrun` |
| C1 | the sabotage program ends `(exit 3)` | exit 2, `SABOTAGE NOT CLEAN … exited 3` |
| C2 | `ASAN_DYLIB_PATTERN=/nonexistent/x.dylib`, so the recipe refuses | exit 2, `failed, but not on the planted libc-overrun` |
| C2′ | C2, with the marker test replaced by `false` | **exit 0, `gate caught`**, while its log says `refusing to run un-sanitized` |
| C1′ | the clean-run guard off, plus H, plus C1 | **exit 0, `gate caught`** |
| E | `MEMORY_SABOTAGE_MODES=` | exit 2, `nothing was planted.` |
| E′ | E, with the empty-list test replaced by `false` | **exit 0, `MEMORY GATE CAN FAIL`** |

H is new to this repository. It shows the exit-status test is needed on
macOS as well, because a marker-only check would credit it. On make 3.81,
`make -n`, `-t` and `-q` still run nothing and write no log.

**amd64, CI's Valgrind versions.** The `p+8` probe ran under emulation
(`--platform linux/amd64`, with the distribution's `valgrind` and
`chezscheme`), 3 of 3 on each image. Each column is one set of flags:

| image | Valgrind | gate flags | `--errors-for-leak-kinds` removed | show and fail on `possible` |
|---|---|---|---|---|
| ubuntu:24.04 (today's `ubuntu-latest`) | 3.22.0 | exit 0, `possibly lost: 555 bytes in 1 blocks`, no record | exit 9, no record | exit 9, `555 bytes in 1 blocks are possibly lost` |
| ubuntu:26.04 (`ubuntu-latest` from 2026-10-19) | 3.26.0 | the same | the same | the same |

On 26.04, whose Chez is 10.0.0, the real sabotage program also counts
`possibly lost: 555 bytes in 1 blocks`. It cannot run on 24.04's Chez
9.5.8, where `keep-live` is unbound. The project's floor is 10.4.1, and CI
builds that version.

The sweep clones were cut before one comment paragraph moved. Their
Makefiles match the commit below in every line that is not a comment, and
their sabotage program is byte-identical.

### Full runs, on the commit (272b07c)

- **Linux:** the unmodified `make test-memory-docker`, from a clean clone
  of 272b07c, exits 0 in 165 s.
  - `check-memory-gate` prints `gate caught` for store-overrun,
    libc-overrun and leak, then `gate consistent on possible-leak: exit
    0`, then `MEMORY GATE CAN FAIL`.
  - `test-memory` then runs all 17 suites, each as `Command: scheme
    --program tests/test-*.sps`, with 778 to 2,990 allocations apiece.
  - Every suite's own process reports 0 errors, 0 bytes definitely lost
    and 0 bytes possibly lost.
  - The only other summaries are the two fork-artifact children (131 and
    117 bytes).
- **macOS:** `make test` passes (17 suites, `ALL SUITES PASSED`), and so
  do `check-help`, `check-purity` and `check-pins`. Under `env -u
  MallocNanoZone`, `check-memory-gate` catches libc-overrun, and
  `test-memory` passes all 17 suites with 0 ASan reports.
