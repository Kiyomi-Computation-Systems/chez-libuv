# ADR-0003: Linux Valgrind is the sole memory-leak gate; macOS ASan is supplementary

- **Status:** Accepted (2026-08-18) — no spike dependency; accepted at Stage 0 exit
- **Date:** 2026-08-18
- **Scope:** chez-libuv v0.1
- **Related:** [design spec](../2026-08-18-chez-libuv-v0.1-design.md), [ADR-0002](0002-direct-ffi-with-constants-only-shim.md)

## Context

The lifecycle logic this binding's memory safety depends on lives in Scheme
(handle registration, close-time freeing, the read/write allocation paths of
[ADR-0009](0009-copy-at-the-boundary.md)), so it cannot be exercised by a
pure-C test harness — it has to run in-process, with Chez actually running.

Chez is not built with sanitizers, so ASan requires preloading its runtime
(`DYLD_INSERT_LIBRARIES` on macOS) into a process that was never instrumented
for it. Valgrind needs no such instrumentation of anything it runs.

The decisive constraint, carried over from the same finding in
`chez-cmark-gfm`'s own memory-verification ADR: **LeakSanitizer is not
supported on macOS/ARM64**, the development machine's platform. ASan there
still catches use-after-free and buffer overflows, but it cannot find leaks.
Separately, neither Valgrind nor ASan attributes a leak to a specific test —
both report at process granularity, and this binding's tests need per-test
granularity to be useful (a leaking `test-tcp` case should not force
re-reading all of `test-lifecycle` to find it).

## Decision

Linux CI is the authoritative gate for every memory-leak claim, running
Valgrind against the built suite (`make test-memory`). macOS runs ASan via
`DYLD_INSERT_LIBRARIES` on a supplementary basis — useful for use-after-free
and overflow detection, but never cited as leak evidence, documented as such
directly in the Makefile and CI configuration rather than left implicit.

Independently, the shim maintains debug allocation counters
(`CHEZ_LIBUV_DEBUG_COUNTERS`) across six classes — `loop`, `tcp`, `timer`,
`write_req`, `connect_req`, `read_buffer` — queryable from Scheme as
`live-counts`, so any individual test can assert its own balance rather than
waiting for a process-level verdict. `UV_USE_IO_URING=0` is documented as an
escape hatch for Valgrind noise against io_uring on the pinned Linux kernel,
should it appear.

## Consequences

- A green macOS run is never sufficient evidence for a memory claim; CI
  configuration and any release notes referencing memory safety must say so
  explicitly.
- Counters give per-test granularity that neither tool provides natively,
  behave identically on both platforms, and compile to nothing under
  `make prod`.
- Counters make failure-path testing tractable: inject a failure, assert
  counters returned to baseline — the pattern `test-lifecycle` uses
  throughout.
- Valgrind remains the outer gate for what counters cannot see by
  construction: overflows, use-after-free, and any leak originating inside
  libuv itself rather than in this binding's own allocations.

> **Amended 2026-08-18 (final review).** The Linux `test-memory` invocation
> now passes `--undef-value-errors=no`. Real CI output showed hundreds of
> Memcheck "Conditional jump or move depends on uninitialised value(s)"
> reports from a single context -- anonymous frames inside Chez's own
> `S_call_help`, i.e. Chez's JIT-generated machine code, not this binding's
> allocations. This is Memcheck's *Value* check (definedness tracking via
> shadow bits), a different mechanism from the *Leak* checks this ADR's gate
> is actually about, and it is not one a JIT can be expected to satisfy: the
> code Memcheck is inspecting was generated at runtime with no static
> provenance for its registers to inherit definedness from, so the check is
> structurally unable to distinguish a real bug from JIT noise there.
> Addressability checking -- invalid reads/writes, use-after-free, and every
> leak-kind check this ADR decided on -- stays fully enabled and gating; only
> undefined-value tracking is scoped out, and only because it was never
> capable of discriminating for JIT'd code in the first place. The
> alternative considered was a suppressions file keyed on `fun:S_call_help`,
> rejected because Chez's internal call paths are not a stable target to
> pin a suppression to -- it risks whack-a-mole as those paths shift across
> Chez versions, where a single flag scoped to the check *class* does not.

> **Amended 2026-09-27: both arms were vacuous, and now there is a check.**
> Neither arm of `make test-memory` was checking the Chez process that runs
> the suites, and nothing noticed, because no run of either had ever been
> watched failing.
>
> - **Linux, 2026-08-30 to 2026-09-27.** #14 (17b62b0) capped each suite by
>   putting `timeout 900` between `valgrind` and `scheme`. Valgrind checks
>   the command it is handed and does not follow an exec, so its client was
>   `timeout` (2 allocations, 44 bytes, every suite) and Chez ran natively.
>   **v0.6.0 and v0.7.0 shipped on that gate.** v0.5.0 predates #14 and was
>   really gated. Found while working on #35. A planted one-byte heap
>   overrun exited 0 through the recipe and 9 under `valgrind scheme`
>   directly.
> - **macOS, since v0.1 (35f290b).** The ASan arm set
>   `DYLD_INSERT_LIBRARIES` on `sh -c '…'`. `/bin/sh` is SIP-protected, and
>   macOS purges every `DYLD_*` variable when it launches a protected
>   binary, so no suite ever loaded ASan. The runs recorded in
>   `spike/dns/FINDINGS.md` Q2 were live, because they invoked `chez`
>   directly; the make target never was. A second trap sits beside the
>   first: ASan's Darwin runtime strips itself from
>   `DYLD_INSERT_LIBRARIES` in whatever process it loads into (its
>   `strip_env` default), so a wrapper such as `timeout(1)` gets ASan and
>   the Chez it starts does not.
>
> **Fix.** The cap now wraps Valgrind (`timeout N valgrind … scheme`), and
> the ASan arm sets `DYLD_INSERT_LIBRARIES` on the `chez` command itself.
> With both live, all 17 suites pass. Under Valgrind every suite's own
> process reports 0 errors and 0 bytes definitely lost (aarch64 container,
> 163 s in total). Under ASan there are 0 reports.
>
> **Check.** `make check-memory-gate` plants defects
> (`tests/memory-gate-sabotage.sps`) and runs the real `test-memory` recipe
> on each. It requires a non-zero exit *and* the tool's own report of that
> defect, after a plain run has shown the planted program is clean without
> a tool. Linux plants a one-byte overrun by a Scheme store, the same by
> libc `memset`, and a 777-byte definite leak. macOS plants only the
> `memset` overrun. CI and `make test-memory-docker` run the check before
> `test-memory`. Mutations and evidence are in
> `.plans/memory-gate-mutation-log.md`.
>
> **What the macOS arm sees, now that it is live.** Only what passes
> through libc or the allocator: overruns inside `memcpy` and `memset`,
> double and invalid frees. Chez's generated code is not instrumented. A
> `foreign-set!` past a block and a `foreign-ref` of freed memory both got
> past live ASan and were caught by Valgrind. That covers the binding's own
> copy loops, so the Decision above holds for more than leaks: Linux
> Valgrind is the gate for any memory claim about Scheme-side access.
>
> **Forked children do not gate, deliberately.** `test-process.sps` has two
> rows whose child fails before `exec` (ENOENT, and a stdio setup EINVAL).
> Under Valgrind each child reports one definite leak: 131 and 117 bytes on
> arm64. Each is that row's spawn-options block. The parent holds it while
> `uv_spawn` forks and frees it as soon as `uv_spawn` returns, but the child
> `_exit`s inside `uv_spawn`, and Memcheck cannot see Chez's tagged
> references. So these are fork artifacts. Planting a block that the parent
> held for the whole suite made the same children report 131+333 and
> 117+333 bytes, while the parent stayed at 0. libuv discards such a
> child's exit status (it reads errno from its pipe), and a child that
> `exec`s leaves Valgrind at the `exec`. No child's report reaches the
> gate, and none should.
>
> Two alternatives were considered. `--child-silent-after-fork=yes` changes
> no gate outcome, and it would delete the only diagnostic for a fault in
> the pre-exec window, where libuv's child reads the marshalled
> file/args/env/cwd. That output stays visible, and non-gating.
> `--trace-children=yes` was measured and rejected. On `test-process.sps`
> it traced 24 processes, every `exec`'d `/bin/sh` and `/bin/cat`
> included, and took 13 s against 10 s. None of those children's reports
> reached the make log. What it adds are
> checks of other programs, the shells and `cat`s the suites spawn. It
> checks no more of this binding, whose code runs only in the parent and,
> before `exec`, in forked children that Valgrind already follows.

> **Amended 2026-09-28: three findings from chez-cmark-gfm's port of the
> check.** chez-cmark-gfm copied `check-memory-gate` in its PR #23 and
> found three things that hold here too. Each was measured here before
> anything changed; the evidence is in `.plans/memory-gate-mutation-log.md`,
> under "Port-back from chez-cmark-gfm".
>
> - **An empty mode list passed.** `make check-memory-gate
>   MEMORY_SABOTAGE_MODES=` planted nothing, yet exited 0 and printed
>   `MEMORY GATE CAN FAIL`. The check now counts the modes it runs and
>   fails when there were none. With that test disabled, the empty list
>   passes again.
> - **`MallocNanoZone=0` is gone from the macOS arm.** v0.1 added it on
>   chez-cmark-gfm's word that the Nano allocator traps a double free
>   before ASan sees it. That trap was plain malloc, observed while ASan
>   was not loaded. With ASan live, a double free and a `memset` overrun
>   give the same report, exit status and output with the variable and
>   without it. Every block comes from ASan's own allocator, at the same
>   addresses either way. `check-memory-gate` and all 17 suites pass
>   without it. Plain malloc also traps a double free the same way whether
>   the variable is set or not: SIGTRAP up to 4 KiB, and SIGABRT from
>   32 KiB up. When measuring this again, remember that the Claude desktop
>   app exports `MallocNanoZone=0` to everything it runs, so "without" has
>   to mean `env -u MallocNanoZone`.
> - **A check now holds the Linux leak flags consistent.**
>   `--errors-for-leak-kinds=definite` keeps the gate failing only on
>   leak kinds it prints. Valgrind's default for that flag adds "possible",
>   and a possibly-lost block then fails the run with no loss record in
>   the log. A new `possible-leak` mode plants 555 bytes that only an
>   interior pointer reaches. The gate may pass on that block, or fail and
>   print its record, but it must not fail without the record (`GATE RED
>   WITHOUT A REPORT`). Removing the flag turns the check red. The flag's
>   old justification, that Chez's runtime "routinely" makes such blocks,
>   was never measured, and a run shows otherwise. No suite's own process
>   has one. Only forked children do, and they never gate.

> **Amended 2026-10-06: the macOS arm sees the shim's own copies, and a
> check now holds that.** Probes on 2026-10-05 (during #49) reported that
> the macOS arm could not see an overrun made by the C shim's bulk copies:
> `chez_uv_copy_in`, `chez_uv_copy_out` and `chez_uv_zero`, behind
> `copy-in!`, `copy-out` and `zero-out!`. The cause they proposed was that
> Apple's SDK compiles the shim's `memcpy` and `memset` to the fortified
> `__memcpy_chk` and `__memset_chk`, which ASan does not intercept.
>
> - **The fortification is real.** The SDK's `_types.h` defines
>   `_FORTIFY_SOURCE` as 2 whenever it is undefined, at every optimization
>   level, so the `-O0` dev shim imports `___memcpy_chk` and
>   `___memset_chk`. `-U_FORTIFY_SOURCE` changes nothing, since there is no
>   predefined macro to undefine.
> - **The blindness is not.** The shim passes an unknown size
>   (`(size_t)-1`), so the check cannot fire. libsystem_c's `__memcpy_chk`
>   then tail-calls `memcpy` through a bound pointer, and with ASan loaded
>   that pointer is ASan's own `memcpy` wrapper. `__memset_chk` does the
>   same with `memset`. With the preload on Chez, as the recipe sets it, an
>   overrun through each of the three entry points was reported, naming the
>   shim function.
> - **Every probe that said otherwise had launched
>   `DYLD_INSERT_LIBRARIES=… timeout N chez …`**, the trap the 2026-09-27
>   amendment records. ASan loaded into `timeout`, and the `verbosity=1`
>   banner that three of the four runs took as their witness came from
>   `timeout`'s process. Re-run that way, the same probe printed a
>   banner whose PID was not Chez's, and no report. The real `uv-spawn!`
>   overflow those probes "missed" is reported once ASan is in Chez:
>   `0 bytes after 196-byte region`, in `chez_uv_copy_in`.
>
> **Check.** `make check-memory-gate` gains a `shim-overrun` mode on both
> platforms. `copy-in!` writes one byte past a 19-byte block, and the
> report must name both the block and `chez_uv_copy_in`. On macOS it is
> the mode that notices if the shim's copies stop reaching libc: with
> `chez_uv_copy_in` rewritten as a C loop, it goes vacuous while the
> `memset` mode still passes. On Linux, Valgrind sees the loop too, so
> there the mode keeps the planted program honest on every CI run.
>
> **Not adopted: `-D_FORTIFY_SOURCE=0` for the dev shim**, the fix the
> report proposed. It changes nothing ASan can see: the shim then imports
> `memcpy` and `bzero`, both intercepted, and all three entry points are
> still reported. The prod shim (`-O2`) already imports plain `memcpy` and
> `bzero`. Evidence: `.plans/memory-gate-mutation-log.md`, "The shim's own
> copies (2026-10-06)".

> **Amended 2026-10-09 (#94, found gating #85): the gate's first
> suppression, for a block Chez strands on every callback escape.**
> `S_call_help`, Chez's entry from C into Scheme, mallocs a `jmp_buf` for
> each call and frees it only when that call returns. A continuation that
> escapes a libuv callback never returns through it, and nor does an engine
> dropped while inside one, so the block is never freed, even when its
> thread ends. Measured with Valgrind 3.19 on Debian 12, aarch64: 312 B a
> block, allocated by `malloc` called directly from `S_call_help`. 0, 1 and
> 3 escapes left 0, 1 and 3 blocks; three engines dropped inside a timer
> callback left 3, and three resumed there left none.
> - **Where the gate meets it.** With the suppression in place, the full
>   gate on #85's branch suppressed it in test-loop-claim (1, the escaped
>   teardown), test-loop (3), test-async-fence (1) and test-loop-threads
>   (1), whose sweeps drop engines inside callbacks, and in each of 82
>   children that a spawn forked and that exited before exec, which report
>   the one their parent held. Only test-loop-claim's had ever read
>   "definitely lost"; the rest were "still reachable", and none gated.
>
> - **Why it gated only now.** Valgrind calls the block "still reachable"
>   or "definitely lost" by whether a stray raw pointer to it survives,
>   which depends on how collections ran. test-loop-claim's escaped
>   teardown, an escape on a thread that then ends, read "still
>   reachable" in 5 of 5 runs on main and "definitely lost" in 5 of 5 on
>   #85's branch. Bisected by file, the flip came with a change to
>   `handles.sls` that the suite never calls: the same allocation, the
>   same stack, the same count of blocks allocated. Only the kind differed,
>   and the gate fails on definite leaks.
> - **Why a suppression, not skipped rows.** The block is Chez's, and
>   nothing the binding does can free it. Skipping the escaping rows under
>   Valgrind would leave the next suite to escape on a thread exposed to
>   the same timing. The suppression (`tests/valgrind-chez.supp`) matches
>   only a block whose allocation is `malloc` called directly from
>   `S_call_help`. The binding allocates through its shim's `calloc`, and
>   `foreign-alloc` through `s_malloc`, so no block of the binding's
>   matches. It matches every leak kind so that a check can count it; only
>   definite leaks gate.
> - **The check.** `make check-memory-gate` gains an `escape` mode (Linux).
>   It makes three escapes on the main thread, and requires the real
>   recipe to pass with Valgrind reporting three blocks suppressed. Its
>   `leak` and `possible-leak` modes go on requiring their planted blocks
>   to be reported. Measured: with the suppression's `S_call_help` frame
>   dropped, `leak` went vacuous (its 777 B block suppressed) and `escape`
>   counted 10 blocks; with the kinds narrowed to definite, the frame
>   misnamed, or the file not passed to Valgrind, `escape` failed by name.
>   Evidence: `.plans/escape-suppression-mutation-log.md`.
