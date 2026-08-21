# Stage 0 Findings — chez-libuv v0.3 Process

Evidence for the three questions the
[v0.3 process design spec](../../.plans/2026-08-21-chez-libuv-v0.3-process-design.md)
§10 poses, and on which ADR-0015 (the §5.6 spawn-failure path) and the §9
test discipline are contingent. Every claim below is followed by the command
that produced it and the output that command actually printed. Every
experiment was run **twice** on each platform; where the two runs are not
byte-identical, the difference is named and explained rather than glossed.

The scripts are committed beside this file: `spike/process/probe-process.c`,
`spike/process/07-spawn-failure.ss`, `spike/process/08-sigchld-coexist.ss`,
`spike/process/09-pipe-stdio-gc.ss`. Every number quoted in this document is
reproducible by re-running them.

**This document carries both legs.** The macOS legs were run first, on a
Darwin/arm64 dev machine that has no valgrind. The Linux legs were run second,
in CI — GitHub Actions run **32529167080** (all legs, conclusion **success**),
workflow **"Process spike (Linux legs) [TEMPORARY]"**, job "process spike
(ubuntu, SQ1/SQ2/SQ3 Linux legs)", on the temporary branch
`spike/process-evidence`, which was deleted after harvesting. Every number
quoted in a Linux subsection is copied verbatim from that run's log.

Two earlier attempts on the same branch are named where they are relevant,
because each produced a real finding about the harness rather than about
libuv: run **32527483298** (the plain legs are valid and identical to the
final run's; its valgrind gate was defective — see "Two gate defects" under
SQ1) and run **32528531378** (cancelled after the SQ3 leg stalled on a
shell-portability bug — see the portability note under SQ3).

## Toolchain

### macOS leg (dev machine)

| Item | Value | How determined |
|---|---|---|
| Chez Scheme | 10.4.1 | `chez --version` |
| Machine type | `tarm64osx` | `(machine-type)`, printed by every script |
| libuv | 1.52.1 — the **vendored pinned submodule**, not Homebrew's | `git -C vendor/libuv describe --tags`; `uv_version_string()` in the probe |
| libuv shared object | `build/vendor/libuv.dylib` (`make HAVE_PKG=no vendor`, `-DCMAKE_BUILD_TYPE=Release`) | |
| libuv headers | `vendor/libuv/include/uv.h` | |
| C compiler | Apple clang 21.0.0 (clang-2100.1.1.101) | `cc --version` |
| Target triple | `arm64-apple-darwin25.5.0` | `cc --version` |
| macOS | 26.5.2 (build 25F84) | `sw_vers` |
| Arch | arm64 | `uname -m` |
| valgrind | **none** — unavailable on this machine | (ADR-0003: no leak claim from this leg) |

Unlike `spike/dns`, this spike uses the **vendored** libuv on both platforms,
so every observation below is against the same pinned v1.52.1 source that §7's
vendor facts cite.

### Linux leg (CI)

| Item | Value | How determined |
|---|---|---|
| CI run | 32529167080 (all legs, success) | GitHub Actions run log |
| Job | "process spike (ubuntu, SQ1/SQ2/SQ3 Linux legs)" | run log |
| Runner | `ubuntu-latest` = Ubuntu 24.04.4 LTS, x86_64 | `distro:` step output |
| Kernel | Linux 6.17.0-1022-azure x86_64 | `uname -srm` |
| Chez Scheme | 10.4.1 (built from the pinned release tarball, restored from ci.yml's cache) | `$CHEZ --version` |
| Machine type | `ta6le` | `(machine-type)` |
| libuv | 1.52.1 — the same vendored submodule, built on the runner | `uv_version_string()` in the probe |
| libuv shared object | `build/vendor/libuv.so` | |
| C compiler | `cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0` | `cc --version` |
| libc | GLIBC 2.39-0ubuntu8.8 | `ldd --version` |
| valgrind | valgrind-3.22.0 | `valgrind --version` |
| cmake | 3.31.6 | `cmake --version` |

## Summary of verdicts

| SQ | Verdict |
|---|---|
| SQ1 — spawn failure cleanup | **ANSWERED, and the answer is not the one either plan variant assumed.** There are **two** failure classes with **opposite** correct cleanups, and the spike measured both on both platforms. An **exec** failure (`ENOENT`) leaves the handle **still linked into `loop->handle_queue`** → `uv_close` is mandatory, direct `foreign-free` leaves the loop permanently `EBUSY`. A **stdio-setup** failure (`EINVAL`) has already unlinked it → direct `foreign-free` is correct, and `uv_close` **silently splices a later-registered live handle out of the loop's handle queue**. Additionally: `(pipe …)`-spec pipes are **NOT left untouched** by a failed spawn — libuv connects the parent end anyway (`uv_fileno` goes `EBADF` → a real fd), and failing to close them leaks one fd per slot per attempt (measured: parent-end fd climbed 9 → 606 over 300 rounds). |
| SQ2 — SIGCHLD coexistence | **NO CONFLICT OBSERVED, on either platform, in any of four orderings.** 110/110 libuv `exit_cb`s delivered with the exact `(7 . 0)` payload while Chez's `system` and `open-process-ports` ran interleaved; every Chez call also returned its own correct result. The Linux leg is the load-bearing one: the probe confirms that build reaps children via the **SIGCHLD handler + `waitpid(WNOHANG)`** path, i.e. the path that can silently drop an `exit_cb`. No README mutual-exclusion warning is required by this evidence. |
| SQ3 — pipe stdio under GC pressure | **PASS, and BOTH orderings measured.** 200,100 round trips per run-set, `(collect)` in every callback, zero payload corruption, zero lost deliveries, counters exact, callable entry points stable, `uv_loop_close` 0 on every run. Ordering: with `/bin/cat` as the child, **EOF arrived before `exit_cb` in 70/70 runs**; with `sh -c 'exec 3<&0; cat <&3 & exit 0'` (the echo done by a grandchild, so the watched process retires first), **`exit_cb` arrived before EOF in 50/50 runs**. The order is a property of the child's process structure, not something libuv guarantees — which is exactly the evidence the wait-both-independently discipline needs. |

---

## SQ-0: the constants probe (`spike/process/probe-process.c`)

Same role as v0.1's `spike/probe.c` and v0.2's `spike/dns/probe-dns.c`: no
enum value, struct size, or `offsetof` in any script below was transcribed
from a header or from memory (ADR-0005's rule, applied to the spike itself).

**Commands run (verbatim):**

```bash
make HAVE_PKG=no vendor
cc -Ivendor/libuv/include -o spike/process/probe-process \
   spike/process/probe-process.c -Lbuild/vendor -luv \
   -Wl,-rpath,"$PWD/build/vendor"
./spike/process/probe-process
```

**macOS (Darwin arm64) output, verbatim:**

```
uv_version_string()                        1.52.1

== the rows spike/process hardcodes ==
UV_PROCESS                                 10
UV_NAMED_PIPE                              7
sizeof(uv_process_options_t)               64
offsetof exit_cb                           0
offsetof file                              8
offsetof args                              16
offsetof env                               24
offsetof cwd                               32
offsetof flags                             40
offsetof stdio_count                       44
offsetof stdio                             48
offsetof uid                               56
offsetof gid                               60
sizeof(uv_stdio_container_t)               16
offsetof container flags                   0
offsetof container data                    8
UV_IGNORE                                  0
UV_CREATE_PIPE                             1
UV_INHERIT_FD                              2
UV_INHERIT_STREAM                          4
UV_READABLE_PIPE                           16
UV_WRITABLE_PIPE                           32
UV_PROCESS_SETUID                          1
UV_PROCESS_SETGID                          2
UV_PROCESS_DETACHED                        8
SIGTERM                                    15
SIGKILL                                    9

== additional rows the three scripts need ==
UV_TCP                                     12
UV_TIMER                                   13
uv_handle_size(UV_TIMER)                   152
UV_RUN_DEFAULT                             0
UV_RUN_ONCE                                1
UV_RUN_NOWAIT                              2
UV_WRITE                                   3
UV_SHUTDOWN                                4
sizeof(uv_buf_t)                           16
offsetof uv_buf_t.base                     0
offsetof uv_buf_t.len                      8
offsetof uv_process_t.pid                  104
sizeof(uv_process_t)                       136
sizeof(uv_pipe_t)                          280
uv_handle_size(UV_PROCESS)                 136
uv_handle_size(UV_NAMED_PIPE)              280
uv_req_size(UV_WRITE)                      192
uv_req_size(UV_SHUTDOWN)                   80
uv_loop_size()                             1072

== errno rows ==
UV_ENOENT                                  -2
UV_EINVAL                                  -22
UV_EBUSY                                   -16
UV_EBADF                                   -9
UV_EOF                                     -4095
UV_ECANCELED                               -89
UV_EAGAIN                                  -35

== SIGCHLD delivery path compiled into this libuv ==
child reaping backend                      kqueue EVFILT_PROC (no SIGCHLD handler)
```

**Linux (glibc x86_64) output — only the rows that DIFFER from Darwin:**

```
sizeof(uv_pipe_t)                          264
uv_handle_size(UV_NAMED_PIPE)              264
uv_loop_size()                             848
UV_ECANCELED                               -125
UV_EAGAIN                                  -11
child reaping backend                      SIGCHLD handler + waitpid(WNOHANG)
```

Every other row is byte-identical across the two platforms — including the
whole of `uv_process_options_t` and `uv_stdio_container_t`, the stdio flags,
the process flags, `SIGTERM`/`SIGKILL`, and `offsetof(uv_process_t, pid)`.

**Two consequences worth recording.**

1. The two sizes that DO differ (`uv_pipe_t`, `uv_loop_t`) are
   never hardcoded by the scripts: they are read at run time from
   `uv_handle_size` / `uv_loop_size`. `UV_ECANCELED` and `UV_EAGAIN` differ but
   are not used by any script. So when the CI leg ran
   `spike/dns/apply-probe-constants.sh` over the three `.ss` files against the
   glibc probe, **the resulting `git diff` was empty** — the Darwin constants
   block was already correct on Linux. That is a measured result, not an
   assumption, and it is the reason the two platforms' script output can be
   compared line-for-line below.
2. `child reaping backend` is the row that makes the Linux SQ2 leg
   load-bearing: the two platforms genuinely take different code paths
   (`#ifdef UV_HAVE_KQUEUE` in `vendor/libuv/src/unix/process.c:67`), and only
   the Linux one can drop a status.

---

## SQ1 — spawn failure cleanup

> **SQ1 — spawn failure cleanup.** Drive `'ENOENT` spawns under valgrind +
> debug counters with both cleanup strategies (close-through-protocol vs
> direct `foreign-free`); also assert `(pipe …)`-spec pipes remain
> consistently unconnected and closeable after a failed spawn. Evidence
> decides ADR-0015's failure path.
> — design spec §10

### Harness

`spike/process/07-spawn-failure.ss`, run as

```bash
chez --script spike/process/07-spawn-failure.ss build/vendor/libuv.dylib 1000 all
```

(the third argument selects which cleanup **engine** runs — `all`, `a`
(close-through-protocol) or `b` (direct free) — so the valgrind leg can run
the two strategies in separate processes and attribute the difference).

The script never reads libuv's source to answer a question it can measure.
Whether a failed spawn's handle is still owned by the loop is measured with
`uv_walk` (which walks `loop->handle_queue`) and with `uv_loop_close`'s own
`EBUSY` busy-check; whether a pipe was touched is measured with `uv_fileno`.

### Observation 1 — there are TWO failure classes, not one

`uv_spawn` has two exits. Setup errors leave through an `error:` label that
calls `uv__queue_remove(&process->handle_queue)`; an **exec** failure does
not go through that label at all — libuv forks, the child's `execvp` fails,
the errno comes back over the error pipe, and `uv_spawn` falls off the end
returning `exec_errorno` with the handle **still linked into the loop**
(`vendor/libuv/src/unix/process.c`, `uv_spawn`). Measured, both platforms:

| | exec failure (`file` does not exist) | stdio-setup failure (`UV_INHERIT_FD`, fd = -1) |
|---|---|---|
| `uv_spawn` rc | `ENOENT` | `EINVAL` |
| our handle still visible to `uv_walk` | **`#t`** | **`#f`** |
| `uv_is_active` / `uv_is_closing` | 0 / 0 | — |
| `uv_loop_close` before any cleanup | **`EBUSY`** | 0† |
| `handle->pid` | 0 | — |
| stray `exit_cb` | 0 | 0 |

† Inferred from the `uv_walk = #f` row — the handle is not in the queue, so close-before-cleanup cannot return EBUSY for it; not directly measured because parts 2/2b/2c hold a sentinel pipe in the loop at that point.

macOS and Linux printed the same values for every row (the Linux run's only
differences anywhere in this script's output are fd numbers and
`uv_handle_size(PIPE)` 264 vs 280).

### Observation 2 — the 2×2, measured

Both strategies were applied to both classes. `close_cb`-fired,
`uv_loop_close` rc, and — for the stdio class — whether a **live handle
registered after the failed spawn** was still visible to `uv_walk` afterwards
(Part 2b/2c: libuv's `error:` path leaves the handle's own queue node pointing
at its old neighbours, and `uv__finish_close` unlinks it a *second* time):

```
the 2x2 (failure class x cleanup strategy):
  exec failure  + uv_close    : close_cb #t, loop_close 0
  exec failure  + direct free : loop_close EBUSY
  stdio failure + uv_close    : late handle survived #f, loop_close 0
  stdio failure + direct free : late handle survived #t, loop_close 0
```

Read that carefully, because it is the ADR-0015 decision:

* **exec failure + `uv_close`** — correct. 1000/1000 `close_cb`s delivered,
  0 stray `exit_cb`s, 0 handles left in the queue, final `uv_loop_close` = 0.
* **exec failure + direct `foreign-free`** — **wrong**. 1000/1000 iterations
  "survived" (nothing crashed on either platform), but the freed blocks stay
  linked into `loop->handle_queue`: `uv_walk` afterwards still visits one, and
  `uv_loop_close` returns **`EBUSY` forever**. The loop is unusable and the
  next `uv__handle_init` writes through a dangling tail pointer.
* **stdio failure + `uv_close`** — **wrong, and silently so**. The handle
  registered *after* the failed spawn disappeared from `loop->handle_queue`
  (`late handle survived #f`) while remaining a perfectly live handle. Nothing
  errored; `uv_loop_close` still returned 0 — because the handle it should
  have refused for is no longer in the queue it checks.
* **stdio failure + direct `foreign-free`** — correct. Both sentinels still
  visible, `uv_loop_close` = 0.

The two rows that are "wrong" fail in opposite directions, which is why a
single uniform cleanup cannot be correct for both.

### Observation 3 — `(pipe …)`-spec pipes are NOT left untouched

The spec's §5.6 expectation was that "our pipe records remain consistently
unconnected and closeable". The *closeable* half holds. The *unconnected* half
is refuted.

```
uv_pipe_init(in)                   = 0
uv_pipe_init(out)                  = 0
uv_fileno(in)  BEFORE spawn        = rc EBADF, fd -12345
uv_fileno(out) BEFORE spawn        = rc EBADF, fd -12345
uv_spawn rc                        = ENOENT
uv_fileno(in)  AFTER failed spawn  = rc 0, fd 9
uv_fileno(out) AFTER failed spawn  = rc 0, fd 11
uv_is_readable(in) / writable(in)  = 0 / 1
uv_is_readable(out)/ writable(out) = 1 / 0
uv_is_active(in) / (out)           = 0 / 0
all three close_cbs fired?         = #t (after 1 steps, 3 fires)
uv_loop_close                      = 0
```

(Linux: identical except the fds are 12 and 14.)

libuv creates the socketpairs *before* forking and opens the parent ends into
the pipe handles **regardless of whether the exec succeeded** — the
`uv__process_open_stream` loop in `uv_spawn` runs on the exec-failure path
too. So after a failed spawn the pipe handles are **connected, correctly
directioned, inactive, and closeable**.

That is not academic. Part 4b measures the cost of believing otherwise:

```
closing the pipes: 300 rounds, non-ENOENT rcs = 0, first = none
  parent-end fd on round 0 / last  = 9 / 9  (stable => fds recycled)
NOT closing the pipes: rounds completed = 300, first non-ENOENT = never
  parent-end fd on round 0 / last  = 9 / 606  (climbing => fds LEAKED)
handles left open in that loop     = 600
```

One fd per pipe slot per failed attempt, forever. (Linux: 12 → 611, same
shape.) A caller that treats a failed spawn's pipes as never-connected leaks
them; 300 rounds did not hit `EMFILE` on either runner, so the failure mode is
a slow leak rather than a prompt error — the worst kind.

### Linux valgrind

Strategy A and strategy B were run in **separate processes** (the script's
third argument), 40 iterations each, so the difference between the two logs is
attributable to the strategy and nothing else:

```
valgrind --leak-check=full --show-leak-kinds=all \
         --errors-for-leak-kinds=definite --undef-value-errors=no \
         --child-silent-after-fork=yes --error-exitcode=9 \
  scheme --script spike/process/07-spawn-failure.ss build/vendor/libuv.so 40 a
  # and again with ... 40 b
```

**Strategy A (close-through-protocol) — clean, and the CI gate passed:**

```
==10299== LEAK SUMMARY:
==10299==    definitely lost: 0 bytes in 0 blocks
==10299==    indirectly lost: 0 bytes in 0 blocks
==10299==      possibly lost: 0 bytes in 0 blocks
==10299==    still reachable: 1,946 bytes in 5 blocks
==10299==         suppressed: 0 bytes in 0 blocks
==10299== ERROR SUMMARY: 0 errors from 0 contexts (suppressed: 0 from 0)
```

The 1,946 still-reachable bytes are glibc's `dlopen` bookkeeping (`_dl_open`,
`_dl_new_object`, `_dl_check_map_versions` in the loss records) — the same
never-freed-by-design allocation the v0.2 DNS spike recorded. Still reachable
is not a leak, no suppression file is needed, and that is the suppression
decision for this spike too.

**Strategy B (direct `foreign-free`) — 402 errors:**

```
(derived tally, not verbatim valgrind lines:)
Invalid read  : 6
Invalid write : 7
Invalid free  : 0
==10431==    definitely lost: 576 bytes in 2 blocks
==10431==    indirectly lost: 0 bytes in 0 blocks
==10431==      possibly lost: 0 bytes in 0 blocks
==10431==    still reachable: 1,946 bytes in 5 blocks
==10431== ERROR SUMMARY: 402 errors from 15 contexts (suppressed: 0 from 0)
```

The counts above are error *contexts*; the 15 contexts break down by the
libuv frame that touched the freed block as `uv_walk` ×9, `uv_spawn` ×2,
`uv_loop_close` ×1, `uv_handle_get_type` ×1; the remaining 2 contexts are the
two `definitely lost` blocks (576 bytes in 2 blocks) promoted to errors by
`--errors-for-leak-kinds=definite`. The first one, verbatim, is the
mechanism in one screen:

```
==10431== Invalid write of size 8
==10431==    at 0x4FBD737: uv_spawn (in .../build/vendor/libuv.so.1.0.0)
==10431==    by 0x6EE2156: ???
...
==10431==  Address 0x4bb8220 is 32 bytes inside a block of size 136 free'd
==10431==    at 0x484988F: free (in .../vgpreload_memcheck-amd64-linux.so)
==10431==    by 0x713CB72: ???
...
==10431==  Block was alloc'd at
==10431==    at 0x4846828: malloc (...)
==10431==    by 0x1B97FC: s_malloc (.../ta6le/scheme)
```

136 bytes is exactly `uv_handle_size(UV_PROCESS)`; offset 32 is inside the
handle's `handle_queue` node. The *next* `uv_spawn`'s `uv__handle_init`
appends to `loop->handle_queue` through the tail pointer that still names the
block we freed. `uv_walk` and `uv_loop_close` then read it. Nothing crashed on
either platform — which is precisely why this needed valgrind and not a test.

**Two gate defects, recorded because they are reusable lessons.** The first CI
attempt (run 32527483298) failed strategy A's gate for two reasons that were
both about the gate, not the code:

1. **Forked-child reports.** `uv_spawn` forks, and when the exec fails the
   forked child stays under valgrind and emits its own full leak report at
   `_exit`. Each such report claimed `4 bytes in 1 blocks definitely lost` for
   a `foreign-alloc` the *parent* still owns and later frees. About 300 of them
   drowned the parent's report. `--child-silent-after-fork=yes` is the fix, and
   it is the right one here: the pre-exec child is libuv's code, not ours.
2. **A gate matching the spike's own prose.** The gate grepped the captured
   stdout+stderr for `Invalid write`; 07's Part 5 banner *explains* that
   valgrind's invalid-access reports are the discriminator, and that sentence
   matched. Anchoring the greps to `^==PID==` fixes it; the banner was also
   reworded so no future gate can trip on it.

Both are now encoded in the workflow's comments (and the workflow is quoted in
this repo's mutation/CI lore, not kept, since the branch is deleted).

### Reproducibility

Both platforms, both runs: **byte-identical stdout** (macOS `diff` empty;
CI's in-job `diff sq1-run1.log sq1-run2.log` printed `(byte-identical)`).

### The decision this feeds

ADR-0015's failure path must be **class-dependent**, and the binding can tell
the classes apart because it controls the call: libuv returns setup errors
before any fork, and exec errors as the child's own errno. The safe formulation
the evidence supports:

1. On any non-zero `uv_spawn` rc, free the options block immediately (V1 holds
   — it is consumed synchronously).
2. Ask the loop, don't guess: the binding can distinguish the classes by rc,
   but the *robust* discriminator measured here is whether the handle is still
   in the loop. `uv_close`-then-free is correct exactly when it is; direct free
   is correct exactly when it is not.
3. Either way: no registry entry, no counter increment, no record escape, and
   the raise carries the errno symbol.
4. **The pipe contract changes.** Pipes named in `(pipe …)` specs must be
   marked *connected* and closed by the failure path (or handed back to the
   caller as closeable), not assumed untouched. §5.6's "remain consistently
   unconnected" sentence is refuted by measurement and must be rewritten.

---

## SQ2 — SIGCHLD coexistence with Chez's own subprocess APIs

> **SQ2 — SIGCHLD coexistence (Linux).** In one process, interleave libuv
> spawns with Chez's own subprocess machinery (`open-process-ports`,
> `system`): assert libuv's `exit_cb` still fires and Chez still gets its
> statuses, in both orderings, repeatedly. macOS's kqueue path is structurally
> unaffected — one smoke run anyway. If they conflict, the finding becomes a
> documented mutual-exclusion rule in the README.
> — design spec §10

### Why this can fail (so a green run is read correctly)

On a non-kqueue platform libuv reaps from a SIGCHLD handler and calls
`waitpid(pid, …, WNOHANG)` per registered process. Its loop contains, verbatim
(`vendor/libuv/src/unix/process.c`, `uv__wait_children`):

```c
    if (pid == -1) {
      if (errno != ECHILD) abort();
      /* The child died, and we missed it. This probably means someone else
         stole the waitpid from us. Handle this by not handling it at all. */
      continue;
    }
```

A stolen status is therefore a **silently dropped `exit_cb`** and a process
handle that stays active forever — a hang, not an error. A host runtime can
steal one two ways: by reaping with `wait()`/`waitpid(-1)`, or by installing
its own SIGCHLD disposition over libuv's. Both are ordering-sensitive.

### Harness

`spike/process/08-sigchld-coexist.ss`, four orderings:

| Phase | What it interleaves |
|---|---|
| 1 | Chez `system` + `open-process-ports` **before libuv has ever spawned** (so Chez's SIGCHLD arrangements, if any, are installed first) |
| 2 | libuv spawn driven to completion, **then** Chez's calls |
| 3 | libuv spawn registered, Chez's calls run **before the loop is stepped at all** — the child can exit while Chez is inside its own wait |
| 4 | a libuv child that `sleep 0.2`s, with 8 Chez `system` calls and an `open-process-ports` running **while it is alive** — arranged to make it possible for its SIGCHLD to land inside a Chez wait, though no ordering marker proves it did |

libuv's child is `/bin/sh -c 'exit 7'` — status 7 is discriminating, so a
garbled delivery is not silently plausible. Chez's side is `(system "exit 7")`
(**not** `/bin/true`, which does not exist on macOS) and
`open-process-ports "/bin/echo sq2-sentinel-<tag>"` with the line read back and
compared. Waits are **iteration-capped**; a repeating 20 ms libuv timer only
guarantees each `uv_run 'once` returns, so a dropped `exit_cb` shows up as a
capped-out wait in a tally rather than as a hang.

### Observations

**macOS (`tarm64osx`, kqueue `EVFILT_PROC` backend):**

```
=== Phase 1: Chez subprocess calls BEFORE libuv's first spawn ===
chez system ok/bad      = 5 / 0
chez ports  ok/bad      = 5 / 0

=== Phase 2: alternating libuv spawn / Chez subprocess x 50 ===
phase 2: exit_cb fired 50/50, payload (7,0) 50, DROPPED 0, spawn failures 0

=== Phase 3: libuv spawn registered, Chez runs BEFORE any stepping x 50 ===
phase 3: exit_cb fired 50/50, payload (7,0) 50, DROPPED 0, spawn failures 0

=== Phase 4: sleeping libuv child, Chez system() calls during its life ===
phase 4: exit_cb fired 10/10, payload (7,0) 10, DROPPED 0, spawn failures 0

libuv exit_cb delivered            : 110 / 110 rounds
  payload exactly (7 . 0)          : 110
  DROPPED (capped out, no exit_cb) : 0
Chez (system "exit 7") -> 7        : 185 ok / 0 wrong, first wrong none
Chez open-process-ports echo       : 115 ok / 0 wrong, first wrong none
uv_loop_close                      : 0
VERDICT: NO CONFLICT OBSERVED on this platform
```

**Linux (`ta6le`, SIGCHLD + `waitpid(WNOHANG)` backend) — the load-bearing
leg — printed the same tallies, line for line:**

```
libuv exit_cb delivered            : 110 / 110 rounds
  payload exactly (7 . 0)          : 110
  DROPPED (capped out, no exit_cb) : 0
  spawn failures                   : 0
Chez (system "exit 7") -> 7        : 185 ok / 0 wrong, first wrong none
Chez open-process-ports echo       : 115 ok / 0 wrong, first wrong none
uv_loop_close                      : 0
VERDICT: NO CONFLICT OBSERVED on this platform
```

Run-to-run: **byte-identical on both platforms**, including the `watchdog
timer ticks` line (macOS 141 and 141; Linux 122 and 122). That line counts
20 ms timer fires and is therefore the one wall-clock-driven number in the
output, so the CI check excludes it on principle — the way `spike/dns`
excluded its race lines — rather than because it varied here. It has varied
across *sessions* on the same machine (146/144 in an earlier macOS pair), so
the exclusion is not superstition; it just did not fire in the recorded runs.

### Linux valgrind

The whole script (6 iterations per phase, to keep the fork count sane under
Memcheck) was run under the same flags. The coexistence tallies stayed
correct *and* the memory picture is clean:

```
libuv exit_cb delivered            : 17 / 17 rounds
  DROPPED (capped out, no exit_cb) : 0
Chez (system "exit 7") -> 7        : 57 ok / 0 wrong, first wrong none
Chez open-process-ports echo       : 22 ok / 0 wrong, first wrong none
VERDICT: NO CONFLICT OBSERVED on this platform

==10592== LEAK SUMMARY:
==10592==    definitely lost: 0 bytes in 0 blocks
==10592==    indirectly lost: 0 bytes in 0 blocks
==10592==      possibly lost: 0 bytes in 0 blocks
==10592==    still reachable: 1,946 bytes in 5 blocks
==10592== ERROR SUMMARY: 0 errors from 0 contexts (suppressed: 0 from 0)
```

### The decision this feeds

**No README mutual-exclusion warning is justified by this evidence.** Chez
10.4.1's `system` and `open-process-ports` do not steal libuv's child
statuses, in any of the four orderings, on the platform where stealing is
possible.

Two honest limits on that claim, which the README wording should respect if it
says anything at all:

* This measures Chez 10.4.1 on glibc 2.39, not "all Chez versions"; the
  hazard is a property of the host runtime's reaping strategy, which is not
  part of Chez's documented contract.
* It measures `system` and `open-process-ports`. Any *user* C code linked into
  the same process that calls `wait()`/`waitpid(-1)` or installs a SIGCHLD
  handler still breaks libuv's reaping, and that is libuv's constraint (V6),
  not something the binding can fix. Documenting it as a caveat — "libuv owns
  SIGCHLD in this process" — is accurate; documenting Chez's own APIs as
  mutually exclusive is not.

---

## SQ3 — pipe stdio under GC pressure

> **SQ3 — pipe stdio under GC pressure.** The echo loop (stdin pipe → `cat` →
> stdout pipe) for 10k round-trips with `(collect)` in every callback; record
> observed EOF/exit orderings (expect both); assert no delivery is lost and
> counters balance. Justifies the wait-both-independently test discipline with
> measured evidence.
> — design spec §10

### Harness

`spike/process/09-pipe-stdio-gc.ss`, run as

```bash
chez --script spike/process/09-pipe-stdio-gc.ss build/vendor/libuv.dylib 10000 20 50 50
```

* `/bin/cat` spawned with stdio `[CREATE_PIPE|READABLE_PIPE,
  CREATE_PIPE|WRITABLE_PIPE, IGNORE]`;
* a 64-byte payload seeded from `(run, trip, byte)` per round trip, compared
  byte-for-byte on the way back — a cross-run or cross-trip mix-up is
  detectable, not just a dropped byte;
* the next write is issued **from inside the read callback** (re-entrancy);
* `(collect)` in **every** callback — alloc, read, write, shutdown, exit,
  close;
* read buffers `foreign-alloc`'d fresh in `alloc_cb` and freed in `read_cb`;
  each write's `uv_write_t` + `uv_buf_t` + payload is one block freed in
  `write_cb` — deliberate allocation churn on every delivery;
* after the last trip the write side is `uv_shutdown`'d, which is what makes
  `cat` see EOF and exit;
* three sweeps: 20 long runs (10,000 trips), 50 short runs (1 trip) to sample
  the shutdown→exit window in a different timing regime, and 50 **early-exit**
  runs whose child is `sh -c 'exec 3<&0; cat <&3 & exit 0'` — the echo runs in
  a grandchild that inherits both pipes while the *watched* process retires
  immediately (see the portability note below);
* drive loop capped on iterations **and** on watchdog ticks, never asserting on
  wall clock.

**A portability finding, recorded because it cost a CI round trip.** Getting a
grandchild to inherit the real stdin is not as simple as `cat &`. POSIX assigns
an asynchronous list's standard input to `/dev/null` "before any explicit
redirections", so plain `cat &` echoes nothing (measured directly:
`printf X | sh -c 'cat & wait'` prints nothing). The obvious fix
`cat 0<&0 &` works under macOS's `/bin/sh` (bash in POSIX mode) but **hangs
under Ubuntu's dash**, which opens `/dev/null` on fd 0 in `forkchild()` before
the command's own redirections run, so `0<&0` dups the already-replaced
descriptor onto itself. Saving the real stdin on fd 3 in the *parent* shell
first (`exec 3<&0`) and then redirecting fd 0 from fd 3 in the async command
works on both. The first Linux CI attempt with the `0<&0` form is what
surfaced this: every early-exit run sat until the harness's watchdog-tick cap
fired, which is also the evidence that the cap does its job.

### Observations — delivery and integrity

macOS and Linux printed the same totals:

```
runs                                  : 20 x 10000 + 50 x 1 (cat) + 50 x 1 (sh -c 'exec 3<&0; cat <&3 & exit 0')
round trips completed (total)         : 200100 / 200100
bytes written / bytes read back       : 12806400 / 12806400
payload verification failures         : 0
first bad byte                        : none
write callbacks / write errors        : 200100 / 0
alloc callbacks / read callbacks      : 200220 / 200220
read callbacks with nread == 0        : 0
read errors (other than UV_EOF)       : 0
shutdown callbacks                    : 120
close callbacks (3 handles + watchdog): 480
callable entry points stable          : #t
distinct exit payloads seen           : ((0 . 0))
distinct uv_loop_close rcs            : ("0")
VERDICT: all deliveries accounted for, no corruption
```

Per long run: `trips 10000/10000, bytes 640000/640000, verify-fails 0,
writes 10000, reads 10001 (zero 0, err 0)` — 10,000 data reads plus exactly one
UV_EOF read, on every one of the 20 runs, on both platforms. Every 64-byte
payload came back intact through a full Chez collection taken inside each of
the callbacks that touched it.

### Observations — the EOF/exit ordering

```
ORDERING: EOF before exit             : 70 run(s)  (long 20 / short 50 / early-exit 0)
ORDERING: exit before EOF             : 50 run(s)  (long 0 / short 0 / early-exit 50)
ORDERING: incomplete (one never came) : 0 run(s)
```

Identical on macOS and Linux, and identical across both runs on each platform.

This is worth stating plainly, because it is sharper than "expect both":

* With `/bin/cat` as the child — the ordinary case — the stdout EOF arrived
  **before** the `exit_cb` in **140/140 runs across both platforms** (70/70 per
  platform; kqueue `EVFILT_PROC` on Darwin, SIGCHLD + `waitpid` on Linux). Not
  once did the exit land first. Both the long (10,000-trip) and the short
  (1-trip) sweeps agree, so it is not an artifact of how much traffic preceded
  the shutdown.
* With the echo moved into a grandchild, so that the watched process exits long
  before the pipe closes, the order **inverts completely**: `exit_cb` first in
  **100/100 runs across both platforms**.

So the order is determined by the *child's process structure*, not by libuv
scheduling and not by anything the binding controls. Both orderings are
reachable with entirely ordinary child commands — a wrapper script that
backgrounds the real work is enough to flip it.

### Linux valgrind

Run under Memcheck at a reduced size (`200 2 5 5` — 410 round trips total —
because every round trip is two syscalls and a full Chez collection under
instrumentation):

```
round trips completed (total)         : 410 / 410
ORDERING: EOF before exit             : 7 run(s)  (long 2 / short 5 / early-exit 0)
ORDERING: exit before EOF             : 5 run(s)  (long 0 / short 0 / early-exit 5)
ORDERING: incomplete (one never came) : 0 run(s)
VERDICT: all deliveries accounted for, no corruption

==10569== LEAK SUMMARY:
==10569==    definitely lost: 0 bytes in 0 blocks
==10569==    indirectly lost: 0 bytes in 0 blocks
==10569==      possibly lost: 0 bytes in 0 blocks
==10569==    still reachable: 1,946 bytes in 5 blocks
==10569== ERROR SUMMARY: 0 errors from 0 contexts (suppressed: 0 from 0)
```

So the alloc-in-`alloc_cb` / free-in-`read_cb` and one-block-per-write
lifetimes hold up under instrumentation, and both orderings reproduce there
too.

### The decision this feeds

**Wait for the two events independently — this is now measured, not assumed.**
A test (or an API contract) that waits for `on-exit` and then assumes the
stdout stream has already reported EOF is correct for `/bin/cat` and wrong for
`sh -c 'worker &'`; a test that waits for EOF and assumes the process has been
reaped is wrong in the ordinary case. Concretely, for §9.3/§9.2:

* every stdio scenario must have **two** sentinels, one per event, and wait on
  both, with an iteration cap;
* neither sentinel may be `#f` or `0` (the v0.1 rule), and neither may be
  derived from the other;
* the `(0 . 0)` exit payload and the EOF are independently asserted;
* no test may assert on the *order* — it is a property of the child.

The GC discipline is also licensed by measurement: a full `(collect)` inside
alloc/read/write/shutdown/exit/close callbacks, 200,100 round trips, zero
losses, entry points stable.

---

## Spike exit

All three questions have run on both required legs. This document records the
evidence; ADR-0014/0015/0016 are written against it in Task 2. The two places
where the design spec's stated expectation was **refuted by measurement** —
§5.6's "pipes remain consistently unconnected" and §10's implicit assumption
that one cleanup strategy wins for all spawn failures — must be corrected
there rather than carried forward.

The `spike/process-evidence` branch and its temporary workflow were deleted
after the logs above were harvested.
