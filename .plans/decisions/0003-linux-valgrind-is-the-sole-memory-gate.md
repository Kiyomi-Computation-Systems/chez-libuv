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
