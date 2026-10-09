# #95: why a macOS `fork-thread` thread hung on stranded callback frames

Measured 2026-10-09 on macOS 26.6.2 arm64, Chez 10.4.1 (Homebrew), libuv
1.52.1, and on Linux arm64 in `chez-libuv-valgrind:10.4.1` (Chez 10.4.1).
Probes: `.plans/escape-costs-probe.sps` (#94's; its `vmstk` now answers
"?" where there is no `/proc`) and `.plans/fault-deactivated-probe.sps`
(no libuv).

## The answers to the issue's three questions

1. **What the hung thread waits on.** Chez's collect rendezvous
   (`$collect-rendezvous`, s/7.ss:1265-1292). It waits on `$collect-cond`
   for `$active-threads` to be 1, and the count is 0 while the thread runs
   Scheme code.
2. **The stack size.** `pthread_get_stacksize_np` reads 536,576 B on a
   `fork-thread` thread (pthread's 512 KiB default plus its guard) and
   8,372,224 B on the main thread. Chez sets no size. glibc's default
   follows `RLIMIT_STACK`, 8 MB, which is why Linux threads held 16,000.
3. **Whether it is Chez's.** Yes, the hang. It needs neither libuv nor a
   thread nor an overflow (below).

## How the overflow arrives

lldb on the swallowing repro (#94's, run on a `fork-thread` thread): the
first fault is `EXC_BAD_ACCESS` at 0x16fe03ff8, in `___chkstk_darwin` called
from `uv__io_poll` + 44. The thread's stack is [0x16fe04000, 0x16fe87000);
the fault is the first word of the guard page below it, and `sp` is
0x16fe0c040, 32 KiB above the guard. `uv__io_poll`'s frame holds
`struct kevent events[1024]` (vendor/libuv/src/unix/kqueue.c:159), 32 KiB,
and macOS probes a large frame page by page before moving `sp`. So Chez's
`SIGSEGV` handler has room to run, and raises "invalid memory reference".
Nothing below the stack is written. The main thread faults the same way,
at the same offset into its 8 MB.

The fault came at escape 1,430 (index 1429) on every run, about 375 B an
escape.

Chez delivers the error by `longjmp` to the newest C context in the
thread's chain (`do_error`, c/schsig.c:412). After escapes that is a
stranded callback's, near the bottom of the stack, so whatever runs next
is still at the guard. Measured outcomes:

| Run | Result |
|---|---|
| probe `escape 1000 thread` | survived |
| probe `escape 1500`…`8000 thread` | the thread's guard caught "invalid memory reference"; the thread ended; exit 1 |
| probe `escape 20000` (main) | survived |
| probe `escape 30000`, `40000` (main) | `SIGSEGV` (139), nothing printed: unguarded, and the default handler faults again |
| #94's repro (guard swallows each raise) on a thread, 2,000+ | caught 24 faults (escapes 1429-1452), then hung, 0% CPU, in `S_condition_wait` |
| the same, patched Chez (below) | caught 90 faults, then spun at 100% CPU in `handle_signal` under `_sigtramp` |

## The hang: a fault in a `__collect_safe` call leaves the thread inactive

`uv_run` is `__collect_safe` here (src/libuv/private/native.sls:321), so
Chez deactivates the thread for the call. The fault's `longjmp` back into
Scheme skips the reactivation, and `$active-threads` stays one short:

| Point in #94's repro | `$active-threads` |
|---|---|
| before escapes 0, 1000, 1428 | 1 |
| in the guard, after each fault | 0 |
| before the next escape | 1 (the next `__collect_safe` return reactivates) |

So the count is wrong only until the next `__collect_safe` call returns. A
collection requested in that window waits for good. `fault-deactivated-
probe.sps` faults with `strlen(8)` and allocates 1 MB before any other
foreign call, 1,000 times:

| Shape | macOS arm64 | Linux arm64 |
|---|---|---|
| `none` (control: no fault) | finished | finished |
| `flat` (fault in a `__collect_safe` call) | hung | hung |
| `unsafe` (fault in a plain call inside a callable) | finished | finished |
| `nested` (fault in a `__collect_safe` call inside a callable) | hung | hung |
| `escaped` (one escape, then `flat`) | hung | hung |

A single `flat` fault followed by printing did not hang: the port write
reactivates the thread first.

## The fix in Chez, built and run

Chez 10.4.1 from the tag (`./configure --disable-x11 --disable-curses`,
serial `make`), with one line in `do_error` (c/schsig.c), after the mutex
releases:

```c
if (tc != (ptr)0 && !ACTIVE(tc)) reactivate_thread(tc);
```

All five shapes then finished on macOS. The swallowing repro no longer
hung in the rendezvous; it ran on to the spin in the table above, which is
the stack itself running out under a handler with nowhere to go. The patched
build was compared against Homebrew's 10.4.1, not against the same tree
built without the line.

## What this leaves for the binding

- The rendezvous hang is Chez's and needs the upstream fix; drafted in
  `.plans/upstream-chez-fault-deactivated-issue.md`.
- The overflow itself is #94's: frames stranded by escapes. The binding
  could check the stack room left before each `uv_run` and refuse by name,
  which would turn both of the failures above into a condition.
- docs/api.md's escape-cost paragraph and AGENTS.md's escape trap now say
  what the macOS thread does, instead of "it hung".
