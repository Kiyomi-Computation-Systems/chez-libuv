# chez-libuv v0.3 — Process Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v0.3.0: `(libuv process)` (uv_spawn/kill/pid with full stdio control), a minimal `(libuv pipe)`, and the `(libuv stream)` extraction both require — per the accepted spec `.plans/2026-08-21-chez-libuv-v0.3-process-design.md` (THE SPEC below; section references like §5.5 point into it).

**Architecture:** Thin legible mirror of libuv 1.52.1 (vendored, pinned). Direct FFI from `(libuv private native)` only; a constants-only C shim; static locked trampolines (ten → eleven); handle registry as GC root; explicit close, no guardians; copy-at-the-boundary. The stream verbs move from TCP-kind gating to a new `uv-stream-record` hierarchy so pipes reuse them unchanged.

**Tech Stack:** Chez Scheme (R6RS), libuv 1.52.1 (vendored submodule), C shim (`src/libuv-shim.c`), SRFI-64 tests, GNU/Apple make, GitHub Actions (linux valgrind gate + macos ASan).

## Global Constraints

Every task implicitly includes these. They are the house rules the whole repo runs on; violating one is a review-blocking defect.

- **Validate every argument BEFORE the first allocation**; a failed native call leaves nothing half-built (undo exactly what was allocated/registered/counted).
- **No procedure outside `private/` takes or returns a pointer.** Trampoline entry points never leave `native.sls` except baked into `uv-*-native` wrappers.
- **Constants are never transcribed** (ADR-0005): every sizeof/offsetof/flag/signal is a `src/libuv-shim.c` table row + `constants.sls` snapshot name + nullary accessor. A deleted row must fail a named test.
- **Errors are symbols** (ADR-0006): sync failures raise `&uv-errno-error` via `(uv-check rc 'public-who)`; callback status ints become condition OBJECTS via `status->err`, never raised across C frames.
- **Copy at the boundary** (ADR-0009): no Scheme heap pointer ever enters foreign memory; everything delivered to a callback is a fresh Scheme value copied before anything foreign is freed.
- **Explicit close** (ADR-0007): the close dispatcher is the only place a handle pointer is freed; every freeing site zeroes the stored uptr immediately.
- **Callbacks are guarded**: dispatchers run user code LAST under `dispatch-guarded`; an unguarded raise into a C frame is measured process death (exit 255).
- **Tests**: SRFI-64; iteration caps never wall-clock; `run-until/ticking` for any wait whose predicate depends on a callback; sentinels are symbols never `#f`/0; every suite ends with counter-balance + registry-balance rows and `(exit (if (zero? (test-runner-fail-count runner)) 0 1))`; every loop-driving callback calls `(collect)`.
- **Vocabulary** (spec §4.3): "open/closed" is always handle state; "connected/unconnected" is always the pipe spawn-consumption state.
- **Git**: Conventional Commits; run `make test` before every commit; work happens on `feat/v0.3-process`.
- **Makefile/awk caveat**: target lines need trailing `## ` descriptions (check-help enforces).
- Chez floor and libuv range are what the Makefile already declares — do not touch them.

## File Structure (delta)

```
spike/process/probe-process.c        Task 1  platform-constant probe (spike-only)
spike/process/07-spawn-failure.ss    Task 1  SQ1
spike/process/08-sigchld-coexist.ss  Task 1  SQ2
spike/process/09-pipe-stdio-gc.ss    Task 1  SQ3
spike/process/FINDINGS.md            Task 1  the deliverable
.plans/decisions/0014-*.md 0015 0016 Task 2  new ADRs; 0008 amended
src/libuv-shim.c                     Task 3  constant rows + 3 counter pairs
src/libuv/private/constants.sls      Task 3  snapshot names + accessors
src/libuv/private/native.sls         Task 4  exit trampoline; process/pipe FFI; helpers
src/libuv/private/handles.sls        Task 5  uv-stream-record hierarchy; pipe/process records
src/libuv/pipe.sls                   Task 6  make-uv-pipe
src/libuv/handle.sls                 Task 6/8  uv-pipe?, uv-process?
src/libuv/stream.sls                 Task 7  the four stream verbs, stream-gated
src/libuv/tcp.sls                    Task 7  loses the verbs; re-exports them
src/libuv/process.sls                Task 8-10  uv-spawn!, exit dispatcher, kill family
src/libuv.sls                        Task 11 facade blocks
tests/test-pipe.sps                  Task 6
tests/test-stream.sps                Task 7
tests/test-process.sps               Task 8-10
tests/test-process-setuid.sps        Task 12 root lane
Makefile                             Task 12 TESTS filter-out + test-root
.github/workflows/ci.yml             Task 12 sudo test-root steps
README.org CHANGELOG.md              Task 13
```

---

### Task 1: Stage 0 spike — SQ1/SQ2/SQ3 evidence

The spec gates ADR-0015 on SQ1 and the test discipline on SQ2/SQ3 (§10). Spike code is throwaway; `spike/process/FINDINGS.md` is the deliverable. Spike-only constant hardcoding is legal (the `spike/dns/` precedent); production never transcribes.

**Files:**
- Create: `spike/process/probe-process.c`, `spike/process/07-spawn-failure.ss`, `spike/process/08-sigchld-coexist.ss`, `spike/process/09-pipe-stdio-gc.ss`, `spike/process/FINDINGS.md`

**Interfaces:**
- Consumes: the built shim/libuv (`make build`), the spike harness pattern in `spike/dns/04-threadpool-gc.ss` (FFI preamble: `(import (chezscheme))`, argv-supplied libuv path, `load-shared-object`, local `foreign-procedure` defs).
- Produces: FINDINGS.md sections **SQ1**, **SQ2**, **SQ3**, each with the observation, the platform(s) it was measured on, and the decision it feeds. Tasks 2 and 8 read these.

- [ ] **Step 1: Write the probe C program**

`spike/process/probe-process.c` — prints every constant the spike scripts hardcode, so the scripts' literals have a checked provenance (the `spike/dns/probe-dns.c` pattern):

```c
#include <uv.h>
#include <signal.h>
#include <stdio.h>
#include <stddef.h>

#define P(n, v) printf("%-42s %ld\n", n, (long)(v))

int main(void) {
  P("UV_PROCESS", UV_PROCESS);
  P("UV_NAMED_PIPE", UV_NAMED_PIPE);
  P("sizeof(uv_process_options_t)", sizeof(uv_process_options_t));
  P("offsetof exit_cb", offsetof(uv_process_options_t, exit_cb));
  P("offsetof file", offsetof(uv_process_options_t, file));
  P("offsetof args", offsetof(uv_process_options_t, args));
  P("offsetof env", offsetof(uv_process_options_t, env));
  P("offsetof cwd", offsetof(uv_process_options_t, cwd));
  P("offsetof flags", offsetof(uv_process_options_t, flags));
  P("offsetof stdio_count", offsetof(uv_process_options_t, stdio_count));
  P("offsetof stdio", offsetof(uv_process_options_t, stdio));
  P("offsetof uid", offsetof(uv_process_options_t, uid));
  P("offsetof gid", offsetof(uv_process_options_t, gid));
  P("sizeof(uv_stdio_container_t)", sizeof(uv_stdio_container_t));
  P("offsetof container flags", offsetof(uv_stdio_container_t, flags));
  P("offsetof container data", offsetof(uv_stdio_container_t, data));
  P("UV_IGNORE", UV_IGNORE);
  P("UV_CREATE_PIPE", UV_CREATE_PIPE);
  P("UV_INHERIT_FD", UV_INHERIT_FD);
  P("UV_INHERIT_STREAM", UV_INHERIT_STREAM);
  P("UV_READABLE_PIPE", UV_READABLE_PIPE);
  P("UV_WRITABLE_PIPE", UV_WRITABLE_PIPE);
  P("UV_PROCESS_SETUID", UV_PROCESS_SETUID);
  P("UV_PROCESS_SETGID", UV_PROCESS_SETGID);
  P("UV_PROCESS_DETACHED", UV_PROCESS_DETACHED);
  P("SIGTERM", SIGTERM);
  P("SIGKILL", SIGKILL);
  return 0;
}
```

Build/run it the way `spike/dns/probe-dns.c` is built (see the compile line recorded at the top of that file / `apply-probe-constants.sh`), against the vendored headers: `cc -Ivendor/libuv/include -o spike/process/probe-process spike/process/probe-process.c -Lbuild-of-vendored-libuv -luv` (copy the exact `-L` path from how `spike/dns` did it; `rg -n "probe-dns" spike/dns/apply-probe-constants.sh` shows it).

- [ ] **Step 2: Write `07-spawn-failure.ss` (SQ1)**

Standalone `chez --script` probe. Copy the preamble shape of `spike/dns/04-threadpool-gc.ss` (argv libuv path, `load-shared-object`, local `foreign-procedure`s for `uv_loop_init`, `uv_run`, `uv_loop_close`, `uv_loop_size`, `uv_handle_size`, plus `uv_spawn`, `uv_close`, `foreign-callable` for exit_cb `(uptr integer-64 int)` and close_cb `(uptr)`). Core logic:

```scheme
;; Build a minimal options block with probe-verified offsets (hardcoded
;; HERE ONLY): file = "/nonexistent/definitely-missing", args = [file, NULL],
;; everything else zeroed (stdio_count 0, flags 0, exit_cb = locked
;; trampoline entry).
;;
;; Strategy A (close-through-protocol): rc = uv_spawn(...); expect nonzero
;; (UV_ENOENT). Then uv_close(handle, close_cb); run the loop; record
;; whether close_cb fires, whether the process exits cleanly.
;; Strategy B (direct free): rc = uv_spawn(...); foreign-free the handle
;; block immediately, run the loop 100 iterations, record whether anything
;; crashes or fires.
;; Repeat each strategy 1000x with (collect) between iterations.
;; ALSO: spawn with stdio_count 1, a CREATE_PIPE container pointing at a
;; uv_pipe_init'd pipe, against the same missing file: record whether the
;; pipe handle is left touched (uv_pipe's fd) and whether uv_close on the
;; pipe still works.
(display "SQ1 strategy A: ...")  ;; print every observation
```

Print observations; never assert silently. What decides ADR-0015: which strategy leaves valgrind clean (Linux leg) AND fires no stray callbacks.

- [ ] **Step 3: Write `08-sigchld-coexist.ss` (SQ2)**

Same preamble. Logic: in ONE process, alternate 50 iterations of (a) libuv spawn of `/bin/sh -c 'exit 7'` waiting for exit_cb via capped `uv_run` stepping, and (b) Chez's own `(system "/bin/true")` and `open-process-ports` + close + status read. Record for each iteration: did exit_cb fire with (7, 0)? did Chez's call return its status? Then interleave harder: start a libuv spawn, run Chez `system` BEFORE stepping the loop, then step. Print a per-iteration tally. macOS: expect all green (kqueue path). Linux (CI leg): this is the real question — record any dropped exit_cb.

- [ ] **Step 4: Write `09-pipe-stdio-gc.ss` (SQ3)**

Same preamble plus `uv_pipe_init`, `uv_write`, `uv_read_start`, `uv_shutdown`. Logic: spawn `/bin/cat` with stdio `[CREATE_PIPE|READABLE_PIPE → stdin-pipe, CREATE_PIPE|WRITABLE_PIPE → stdout-pipe, IGNORE]`. Echo loop: write a 64-byte seeded payload to stdin-pipe, read it back from stdout-pipe, `(collect)` in EVERY callback (alloc/read/write/exit), 10,000 round trips, then shutdown stdin → expect EOF then/before exit `(0,0)` — record WHICH order arrived, per run, over 20 runs. Assert no payload corruption (compare bytes), counters exact.

- [ ] **Step 5: Run all three on macOS; harvest Linux evidence via a spike CI branch**

Run: `make build && cc ... && ./spike/process/probe-process && chez --script spike/process/07-spawn-failure.ss <libuv path> ...` for each.
Then create branch `spike/process-evidence` off `feat/v0.3-process`, add a workflow triggered on `push: branches: ['spike/**']` that reuses ci.yml's pinned-Chez cache key (the verified pattern from the DNS milestone: cache restores cross-branch in ~30s), builds, and runs the three probes — 07 under valgrind (`--errors-for-leak-kinds=definite --undef-value-errors=no`, gate on the marker lines "definitely lost:"/"Invalid read", not the exit code). Push, harvest logs, delete the branch.

- [ ] **Step 6: Write FINDINGS.md**

Sections SQ1/SQ2/SQ3. Each: the question (quote §10), the harness, the raw observations (both platforms), the decision it feeds (SQ1 → ADR-0015's failure path + the pipe-after-failed-spawn contract; SQ2 → whether README needs a mutual-exclusion warning about Chez subprocess APIs on Linux; SQ3 → measured EOF/exit orderings justifying wait-both-independently).

- [ ] **Step 7: Commit**

```bash
git add spike/process/
git commit -m "spike: process Stage 0 — SQ1 spawn-failure, SQ2 SIGCHLD coexistence, SQ3 pipe stdio under GC"
```

---

### Task 2: ADRs 0014–0016 + ADR-0008 amendment

**Files:**
- Create: `.plans/decisions/0014-stream-record-generalization.md`, `.plans/decisions/0015-spawn-copy-lifetime-and-failure-path.md`, `.plans/decisions/0016-signal-vocabulary-and-root-lane.md`
- Modify: `.plans/decisions/0008-static-trampolines-and-handle-registry.md` (append a second amendment)

**Interfaces:**
- Consumes: `spike/process/FINDINGS.md` (Task 1), THE SPEC §2/§5.1/§5.5/§5.6/§4.5/§9.4.
- Produces: accepted decisions later tasks cite in code comments by ADR number.

- [ ] **Step 1: Write ADR-0014** — stream-record generalization. Decision: `uv-stream-record` intermediate type (fields: read-buf, read-buf-len, reading, on-data, on-eof, on-error) between `uv-handle-record` and tcp/pipe children; stream verbs move to `(libuv stream)`; tcp re-exports; alloc/read/free-read-buffer! arms gate on `uv-stream-record?`. Alternatives considered (from the spec): duplicate fields per child (rejected: two freeing sites), keep verbs in tcp and duplicate for pipe (rejected: same). Follow the house ADR format — copy the heading structure of `.plans/decisions/0011-handle-less-loop-scoped-requests.md`.

- [ ] **Step 2: Write ADR-0015** — spawn co-allocation + lifetime + failure path. Decision: one co-allocated options block freed unconditionally the moment `uv_spawn` returns (V1, process.c:1054 citation); failure path is **whichever strategy SQ1's evidence selected**, with the FINDINGS observation quoted; register/count only after rc 0. Status "Accepted", evidence link to `spike/process/FINDINGS.md`.

- [ ] **Step 3: Write ADR-0016** — signal vocabulary + root lane. Decision: closed signal symbol set from the shim table, exact `0` as the documented liveness probe; term-signal reverse-mapped (unknown ints pass raw); `uid`/`gid` presence implies SETUID/SETGID; `to-child`/`from-child`/`duplex` direction vocabulary with the UV_READABLE_PIPE/UV_WRITABLE_PIPE mapping stated; the root-lane policy refining v0.2's "untestable ⇒ unbound" (privileged-but-deterministic is bindable via an opt-in root lane; host-config-dependent stays unbound).

- [ ] **Step 4: Amend ADR-0008** — append (below the 2026-08-21 amendment):

```markdown
## Amendment (v0.3, <date>): eleven trampolines

The set grows ten → eleven: `exit`, for uv_exit_cb
`(uv_process_t*, int64_t, int)` (vendor/libuv/include/uv.h:340) — a foreign
type signature no existing trampoline has. The invariant is restated
unchanged: one locked trampoline per callback TYPE, a constant small set
per process; the set moves only when libuv's callback typology does. The
two frozen literals (tests/test-loop.sps, tests/test-native.sps) were
widened watched-to-fail first (see .plans/process-stage-2-mutation-log.md).
```

- [ ] **Step 5: Commit**

```bash
git add .plans/decisions/
git commit -m "docs: ADR-0014/0015/0016 + ADR-0008 amendment (eleven trampolines)"
```

---

### Task 3: Shim constant rows + counters, constants.sls snapshot

**Files:**
- Modify: `src/libuv-shim.c` (constant table + 3 counter pairs), `src/libuv/private/constants.sls` (snapshot-names + exports + accessors)
- Test: `tests/test-native.sps` (new constant rows), `tests/test-conditions.sps` untouched

**Interfaces:**
- Consumes: nothing new (pure ADR-0005 mechanics).
- Produces (for Tasks 4–10): constants.sls accessors, all nullary → exact integer: `uv-process-type`, `uv-named-pipe-type`, `sizeof-uv-process-options-t`, `offsetof-uv-process-options-t-exit-cb / -file / -args / -env / -cwd / -flags / -stdio-count / -stdio / -uid / -gid`, `sizeof-uv-stdio-container-t`, `offsetof-uv-stdio-container-t-flags`, `offsetof-uv-stdio-container-t-data`, `uv-process-setuid-flag`, `uv-process-setgid-flag`, `uv-process-detached-flag`, `uv-stdio-ignore`, `uv-stdio-create-pipe`, `uv-stdio-inherit-fd`, `uv-stdio-inherit-stream`, `uv-stdio-readable-pipe`, `uv-stdio-writable-pipe`, `sig-term`, `sig-kill`, `sig-int`, `sig-hup`, `sig-quit`, `sig-usr1`, `sig-usr2`, `sig-cont`, `sig-stop`. Shim C entry points: `chez_uv_count_pipe_new/free`, `chez_uv_live_pipe`, `chez_uv_count_process_new/free`, `chez_uv_live_process`, `chez_uv_count_spawn_options_new/free`, `chez_uv_live_spawn_options` (both build modes, no-op in prod — the existing pattern).

- [ ] **Step 1: Write the failing tests**

In `tests/test-native.sps`, find the existing constants section (`rg -n "snapshot|constant" tests/test-native.sps` — add beside the existing sizeof/offset sanity rows, AFTER `ensure-native-loaded!` has run in that suite) and add:

```scheme
;; --- v0.3 process/pipe constants (THE SPEC §5.3; ADR-0005) --------------
;; Structural sanity only: values are platform truths, so the assertions
;; are relations, never literals.
(test-assert "process options struct has positive size"
  (positive? (sizeof-uv-process-options-t)))
(test-assert "every options offset lies inside the struct"
  (for-all (lambda (off) (and (>= off 0) (< off (sizeof-uv-process-options-t))))
           (list (offsetof-uv-process-options-t-exit-cb)
                 (offsetof-uv-process-options-t-file)
                 (offsetof-uv-process-options-t-args)
                 (offsetof-uv-process-options-t-env)
                 (offsetof-uv-process-options-t-cwd)
                 (offsetof-uv-process-options-t-flags)
                 (offsetof-uv-process-options-t-stdio-count)
                 (offsetof-uv-process-options-t-stdio)
                 (offsetof-uv-process-options-t-uid)
                 (offsetof-uv-process-options-t-gid))))
(test-assert "stdio container: flags precede data, both inside"
  (and (>= (offsetof-uv-stdio-container-t-flags) 0)
       (> (offsetof-uv-stdio-container-t-data)
          (offsetof-uv-stdio-container-t-flags))
       (< (offsetof-uv-stdio-container-t-data)
          (sizeof-uv-stdio-container-t))))
(test-assert "the three process flags are distinct nonzero bits"
  (let ((flags (list (uv-process-setuid-flag) (uv-process-setgid-flag)
                     (uv-process-detached-flag))))
    (and (for-all positive? flags)
         (= 3 (length flags))
         (zero? (bitwise-and (car flags) (cadr flags)))
         (zero? (bitwise-and (car flags) (caddr flags)))
         (zero? (bitwise-and (cadr flags) (caddr flags))))))
(test-equal "UV_IGNORE is zero (the header's own definition)"
  0 (uv-stdio-ignore))
(test-assert "the stdio modes and direction bits are distinct"
  (let ((bits (list (uv-stdio-create-pipe) (uv-stdio-inherit-fd)
                    (uv-stdio-inherit-stream) (uv-stdio-readable-pipe)
                    (uv-stdio-writable-pipe))))
    (and (for-all positive? bits)
         (= (length bits)
            (length (filter (lambda (b) (= 1 (length (filter (lambda (c) (= b c)) bits)))) bits))))))
(test-assert "nine signals, all positive and distinct"
  (let ((sigs (list (sig-term) (sig-kill) (sig-int) (sig-hup) (sig-quit)
                    (sig-usr1) (sig-usr2) (sig-cont) (sig-stop))))
    (and (for-all positive? sigs)
         (= 9 (length sigs))
         (let loop ((s sigs))
           (or (null? s)
               (and (not (memv (car s) (cdr s))) (loop (cdr s))))))))
(test-assert "process/pipe type tags resolve"
  (and (integer? (uv-process-type)) (integer? (uv-named-pipe-type))))
```

Also extend the suite's `live-counts` expectations wherever the row set is asserted (`rg -n "live-counts" tests/test-native.sps`) with the three new rows `'pipe`, `'process`, `'spawn-options` (Task 4 adds them to `live-counts`; if the row-set assertion lives in this suite, widen it HERE watched-to-fail and let it stay red until Task 4 — otherwise skip).

- [ ] **Step 2: Run to verify failure**

```bash
make test 2>&1 | grep -A2 "test-native"
```
Expected: FAIL/error — the accessors are unbound (compile error in the suite is the failure mode here; that counts).

- [ ] **Step 3: Add the shim rows**

In `src/libuv-shim.c`, add `#include <signal.h>` to the include block, then append to `chez_uv_constant_table` (before the closing `};`):

```c
  /* v0.3 process + pipe (THE SPEC §5.3; ADR-0005). */
  { "UV_PROCESS",    UV_PROCESS },
  { "UV_NAMED_PIPE", UV_NAMED_PIPE },
  { "SIZEOF_UV_PROCESS_OPTIONS_T", (long)sizeof(uv_process_options_t) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_EXIT_CB",
    (long)offsetof(uv_process_options_t, exit_cb) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_FILE",
    (long)offsetof(uv_process_options_t, file) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_ARGS",
    (long)offsetof(uv_process_options_t, args) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_ENV",
    (long)offsetof(uv_process_options_t, env) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_CWD",
    (long)offsetof(uv_process_options_t, cwd) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_FLAGS",
    (long)offsetof(uv_process_options_t, flags) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_STDIO_COUNT",
    (long)offsetof(uv_process_options_t, stdio_count) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_STDIO",
    (long)offsetof(uv_process_options_t, stdio) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_UID",
    (long)offsetof(uv_process_options_t, uid) },
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_GID",
    (long)offsetof(uv_process_options_t, gid) },
  { "SIZEOF_UV_STDIO_CONTAINER_T", (long)sizeof(uv_stdio_container_t) },
  { "OFFSETOF_UV_STDIO_CONTAINER_T_FLAGS",
    (long)offsetof(uv_stdio_container_t, flags) },
  { "OFFSETOF_UV_STDIO_CONTAINER_T_DATA",
    (long)offsetof(uv_stdio_container_t, data) },
  { "UV_PROCESS_SETUID",   UV_PROCESS_SETUID },
  { "UV_PROCESS_SETGID",   UV_PROCESS_SETGID },
  { "UV_PROCESS_DETACHED", UV_PROCESS_DETACHED },
  { "UV_IGNORE",         UV_IGNORE },
  { "UV_CREATE_PIPE",    UV_CREATE_PIPE },
  { "UV_INHERIT_FD",     UV_INHERIT_FD },
  { "UV_INHERIT_STREAM", UV_INHERIT_STREAM },
  { "UV_READABLE_PIPE",  UV_READABLE_PIPE },
  { "UV_WRITABLE_PIPE",  UV_WRITABLE_PIPE },
  { "SIGTERM", SIGTERM },
  { "SIGKILL", SIGKILL },
  { "SIGINT",  SIGINT },
  { "SIGHUP",  SIGHUP },
  { "SIGQUIT", SIGQUIT },
  { "SIGUSR1", SIGUSR1 },
  { "SIGUSR2", SIGUSR2 },
  { "SIGCONT", SIGCONT },
  { "SIGSTOP", SIGSTOP },
```

Then add the three counter pairs, following the existing pattern EXACTLY in both `#ifdef` branches (debug: real counters over `static long live_pipe/live_process/live_spawn_options`; prod: no-ops returning 0):

```c
/* debug branch */
void chez_uv_count_pipe_new(void)  { live_pipe += 1; }
void chez_uv_count_pipe_free(void) { live_pipe -= 1; }
long chez_uv_live_pipe(void)       { return live_pipe; }
void chez_uv_count_process_new(void)  { live_process += 1; }
void chez_uv_count_process_free(void) { live_process -= 1; }
long chez_uv_live_process(void)       { return live_process; }
void chez_uv_count_spawn_options_new(void)  { live_spawn_options += 1; }
void chez_uv_count_spawn_options_free(void) { live_spawn_options -= 1; }
long chez_uv_live_spawn_options(void)       { return live_spawn_options; }
```

(and the matching empty-bodied prod versions). Add the declarations to `src/libuv-shim.h` beside the existing counter declarations.

- [ ] **Step 4: Add the constants.sls names + accessors**

Append every new name to `snapshot-names` (keeping the C-table order for readability), the matching accessors at the bottom (the exact `(define (uv-process-type) (snapshot-ref 'UV_PROCESS))` shape — one per name; signals are `(define (sig-term) (snapshot-ref 'SIGTERM))` etc.), and every accessor to the export list. Note the required-names walk is `snapshot-names` itself — adding the name IS joining the fail-closed init walk.

- [ ] **Step 5: Run tests to verify pass**

```bash
make build && make test
```
Expected: ALL SUITES PASSED (the new rows green; suite count in test-native grows).

- [ ] **Step 6: Mutation probe + log**

Delete the `{ "SIGTERM", SIGTERM },` row, `make build && make test` → the signals row (and init itself once Task 8 uses it) must fail by name; restore. Delete `OFFSETOF_UV_PROCESS_OPTIONS_T_FILE` row → the offsets row fails. Record both in `.plans/process-stage-1-mutation-log.md` (observed output, verbatim).

- [ ] **Step 7: Commit**

```bash
git add src/libuv-shim.c src/libuv-shim.h src/libuv/private/constants.sls tests/test-native.sps .plans/process-stage-1-mutation-log.md
git commit -m "feat: shim + constants rows for process/pipe (types, options/container layout, flags, signals, 3 counter pairs)"
```

---

### Task 4: native.sls — the eleventh trampoline + process/pipe FFI

**Files:**
- Modify: `src/libuv/private/native.sls`, `tests/test-loop.sps:199-202`, `tests/test-native.sps:1344-1347` (and its exit-stub/live-counts rows)

**Interfaces:**
- Consumes: Task 3's accessors (`offsetof-uv-process-options-t-exit-cb` for the wrapper).
- Produces (for Tasks 5–10), all exported from `(libuv private native)`:
  - `(uv-spawn-native loop-ptr handle-ptr options-ptr) → int` — writes the exit trampoline entry into `options-ptr + (offsetof-uv-process-options-t-exit-cb)` then calls `uv_spawn`. THE ONLY WAY the exit entry point leaves this file.
  - `(uv-process-kill proc-ptr signum) → int`, `(uv-kill pid signum) → int`, `(uv-process-get-pid proc-ptr) → int`, `(uv-pipe-init loop-ptr pipe-ptr ipc-int) → int` — raw errno-returning bindings (no callback args, so exported directly).
  - `(c-uptr-set! addr value)`, `(c-u32-set! addr value)`, `(c-uptr-size)` — boundary writers beside `c-int-set!` (same validation shape; `c-u32-set!` writes `'unsigned-32`, needed because uid/gid are unsigned 32-bit and `foreign-set! 'int` rejects values ≥ 2³¹).
  - `(require-callback proc who reason)` — lifted verbatim from tcp.sls:56-58 (the PR #4 shared-validator rule; tcp.sls and stream.sls/process.sls all need it).
  - `count-pipe-new!/free!`, `count-process-new!/free!`, `count-spawn-options-new!/free!` + three new `live-counts` rows `'pipe`, `'process`, `'spawn-options`.
  - `dispatcher-names` now ends in `exit` (eleven names).

- [ ] **Step 1: Widen the two frozen literals — watched to fail**

`tests/test-loop.sps:199-202` and `tests/test-native.sps:1344-1347`, both currently:

```scheme
(test-equal "dispatcher-names names the ten callback types the design commits to"
  '(alloc read connection write-done close timer shutdown connect
    getaddrinfo getnameinfo)
  dispatcher-names)
```

change both to:

```scheme
(test-equal "dispatcher-names names the eleven callback types the design commits to"
  '(alloc read connection write-done close timer shutdown connect
    getaddrinfo getnameinfo exit)
  dispatcher-names)
```

- [ ] **Step 2: Run to verify both fail**

```bash
make test 2>&1 | grep -B1 -A3 "eleven"
```
Expected: two FAILs (expected list has `exit`, actual has ten). This is the ADR-0008 amendment's watched-to-fail requirement — record the observed failure text for the mutation log.

- [ ] **Step 3: Implement in native.sls**

(a) Append `exit` to `dispatcher-names` (native.sls:854-856):

```scheme
  (define dispatcher-names
    '(alloc read connection write-done close timer shutdown connect
      getaddrinfo getnameinfo exit))
```

(b) Beside the DNS callables (after `getnameinfo-callable`), the eleventh trampoline — libuv's exact signature, mechanical body:

```scheme
  ;; uv_exit_cb: void (*)(uv_process_t*, int64_t exit_status, int
  ;; term_signal) (vendor/libuv/include/uv.h:340) — a foreign type
  ;; signature no other trampoline has (ADR-0008, v0.3 amendment).
  (define exit-callable
    (foreign-callable (lambda (handle exit-status term-signal)
                        ((dispatcher-ref 'exit) handle exit-status term-signal))
                      (uptr integer-64 int) void))
```

(c) Add `exit-callable` to the `trampolines-locked` list (after `getnameinfo-callable`), and beside the other entries:

```scheme
  (define exit-cb-entry (foreign-callable-entry-point exit-callable))
```

(d) The raw bindings + wrapper, after the DNS wrappers:

```scheme
  ;; --- the process and pipe entry points (THE SPEC §5.2) ----------------
  ;; uv_spawn takes its callback INSIDE uv_process_options_t rather than as
  ;; an argument, so the wrapper writes the entry point into the caller's
  ;; options block at the shim-reported offset and then calls the raw
  ;; binding — the same "entry points leave this file only baked into
  ;; wrappers" rule as uv-timer-start-native, adapted to a struct field.
  ;; NULL is never written: THE SPEC §4.1 — on-exit = #f is resolved
  ;; Scheme-side by the dispatcher, so the lifecycle machinery always runs.
  (define raw-spawn
    (foreign-procedure "uv_spawn" (uptr uptr uptr) int))

  (define (uv-spawn-native loop-ptr handle-ptr options-ptr)
    (foreign-set! 'uptr options-ptr
                  (offsetof-uv-process-options-t-exit-cb) exit-cb-entry)
    (raw-spawn loop-ptr handle-ptr options-ptr))

  ;; No callback pointers in any of these, so they are exported raw; every
  ;; int is an errno except uv_process_get_pid's, which is the pid itself.
  (define uv-process-kill
    (foreign-procedure "uv_process_kill" (uptr int) int))
  (define uv-kill
    (foreign-procedure "uv_kill" (int int) int))
  (define uv-process-get-pid
    (foreign-procedure "uv_process_get_pid" (uptr) int))
  (define uv-pipe-init
    (foreign-procedure "uv_pipe_init" (uptr uptr int) int))
```

(e) The boundary writers, beside `c-int-set!` (same validation, same order — `integer?` before `exact?`):

```scheme
  (define (c-uptr-size) (foreign-sizeof 'uptr))

  (define (c-uptr-set! addr value)
    (unless (and (integer? addr) (exact? addr) (positive? addr))
      (raise (make-uv-invalid-argument 'uv-c-uptr-set! 'null-or-invalid-destination)))
    (unless (and (integer? value) (exact? value) (>= value 0))
      (raise (make-uv-invalid-argument 'uv-c-uptr-set! 'value-not-a-pointer)))
    (foreign-set! 'uptr addr 0 value))

  (define (c-u32-set! addr value)
    (unless (and (integer? addr) (exact? addr) (positive? addr))
      (raise (make-uv-invalid-argument 'uv-c-u32-set! 'null-or-invalid-destination)))
    (unless (and (integer? value) (exact? value) (>= value 0)
                 (< value 4294967296))
      (raise (make-uv-invalid-argument 'uv-c-u32-set! 'value-out-of-range)))
    (foreign-set! 'unsigned-32 addr 0 value))
```

(The `4294967296` literal is 2³², a width of the C ABI like `c-int-size`'s `foreign-sizeof` — not a libuv constant, so ADR-0005 does not apply to it.)

(f) `require-callback`, moved beside `require-address`/`require-port` (delete it from tcp.sls in Task 7 when the verbs move; until then tcp.sls's private copy shadows nothing since it is not imported there yet):

```scheme
  (define (require-callback proc who reason)
    (unless (procedure? proc)
      (raise (make-uv-invalid-argument who reason))))
```

(g) The six counter bindings following the existing foreign-procedure pattern (`chez_uv_count_pipe_new` … `chez_uv_live_spawn_options`), and three new rows appended to `live-counts`:

```scheme
          (cons 'pipe          (live-pipe))
          (cons 'process       (live-process))
          (cons 'spawn-options (live-spawn-options))
```

(h) Export everything listed in **Produces** above.

- [ ] **Step 4: Add the exit-stub row to test-native.sps**

Beside the existing uninstalled-stub rows (`rg -n "uninstalled\|not been installed" tests/test-native.sps`), following their exact shape:

```scheme
(test-assert "the exit slot holds the raising uninstalled stub"
  (guard (e (#t (and (uv-error? e)
                     (string=? (condition-message e)
                               "callback dispatchers have not been installed"))))
    ((dispatcher-ref 'exit) 0 0 0)
    #f))
```

(test-native.sps never imports handles.sls, so its slots stay uninstalled — the suite's own documented property.)

- [ ] **Step 5: Run tests to verify pass**

```bash
make test
```
Expected: ALL SUITES PASSED — both widened literals green, exit stub row green, live-counts rows green.

- [ ] **Step 6: Mutation log**

`.plans/process-stage-2-mutation-log.md`: record (1) the Step 2 watched-to-fail output verbatim; (2) probe: swap `integer-64` and `int` in exit-callable's signature → no test can catch this until Task 8's exit-delivery test exists — record it as a FORWARD obligation Task 8 discharges (its exit-code test `(7 #f)` fails against the swap); (3) probe: point `uv-spawn-native`'s offset at `offsetof-uv-process-options-t-flags` → same forward obligation.

- [ ] **Step 7: Commit**

```bash
git add src/libuv/private/native.sls tests/test-loop.sps tests/test-native.sps .plans/process-stage-2-mutation-log.md
git commit -m "feat: eleventh trampoline (exit) + process/pipe FFI in native.sls"
```

---

### Task 5: handles.sls — stream record hierarchy + pipe/process records

This is a behavior-preserving refactor plus new (not-yet-reachable) records; the existing suite is the test. New records get their assertion coverage in Tasks 6 and 8, which construct them through public constructors.

**Files:**
- Modify: `src/libuv/private/handles.sls`, `src/libuv/tcp.sls` (accessor renames only), `tests/test-tcp.sps` + `tests/test-lifecycle.sps` + `tests/test-echo.sps` (accessor renames only — `rg` finds the sites)

**Interfaces:**
- Consumes: Task 4's `count-pipe-free!`, `count-process-free!` (imported via the existing `(only (libuv private native) ...)` clause).
- Produces (exported from `(libuv private handles)`):
  - `uv-stream-record?` — the new gating predicate.
  - Stream accessors (renamed from tcp-*): `stream-on-data set-stream-on-data! stream-on-eof set-stream-on-eof! stream-on-error set-stream-on-error! stream-read-buf set-stream-read-buf! stream-read-buf-len set-stream-read-buf-len! stream-reading? set-stream-reading!`.
  - `%make-uv-pipe-record` (ptr loop → record), `uv-pipe-record?`, `pipe-connected?`, `set-pipe-connected!`.
  - `%make-uv-process-record` (ptr loop on-exit → record), `uv-process-record?`, `process-on-exit`, `process-exited?`, `set-process-exited!`.
  - `handle-kinds` = `'(timer tcp pipe process)` (not exported; behavior: teardown sweeps all four).

- [ ] **Step 1: Run the suite green first**

```bash
make test
```
Expected: ALL SUITES PASSED. (Refactor baseline.)

- [ ] **Step 2: Restructure the records**

Replace the `uv-tcp-record` definition (handles.sls:297-309) with the hierarchy (keep the existing comments about `reading?` recording caller intent and the declared-now-filled-later fields — move them onto the stream record):

```scheme
  ;; The stream-generic read-path fields, hoisted from the v0.1 tcp record
  ;; (ADR-0014): everything the alloc/read dispatchers and the close
  ;; dispatcher's buffer arm touch, shared by tcp and pipe children. The
  ;; protocol threads the KIND through, because each child names its own.
  (define-record-type (uv-stream-record %make-uv-stream-record uv-stream-record?)
    (parent uv-handle-record)
    (fields (mutable on-data      stream-on-data      set-stream-on-data!)
            (mutable on-eof       stream-on-eof       set-stream-on-eof!)
            (mutable on-error     stream-on-error     set-stream-on-error!)
            (mutable read-buf     stream-read-buf     set-stream-read-buf!)
            (mutable read-buf-len stream-read-buf-len set-stream-read-buf-len!)
            (mutable reading      stream-reading?     set-stream-reading!))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr kind loop) ((pargs->new ptr kind loop) #f #f #f 0 0 #f)))))

  ;; The TCP child keeps exactly what is TCP-specific: the listener's
  ;; callback (listen/accept remain TCP-only, THE SPEC §4.6).
  (define-record-type (uv-tcp-record %make-uv-tcp-record uv-tcp-record?)
    (parent uv-stream-record)
    (fields (mutable on-connection tcp-on-connection set-tcp-on-connection!))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr loop) ((pargs->new ptr 'tcp loop) #f)))))

  ;; The pipe child (THE SPEC §5.1). `connected?` is the spawn-consumption
  ;; state — NOT handle state ("open/closed" vs "connected/unconnected",
  ;; §4.3's vocabulary rule): it starts #f and flips exactly once, when a
  ;; successful uv-spawn! consumes this pipe in a (pipe ...) spec. It
  ;; exists to make 'pipe-already-used raisable before any allocation.
  (define-record-type (uv-pipe-record %make-uv-pipe-record uv-pipe-record?)
    (parent uv-stream-record)
    (fields (mutable connected pipe-connected? set-pipe-connected!))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr loop) ((pargs->new ptr 'pipe loop) #f)))))

  ;; The process child (THE SPEC §5.1): a process is a handle, not a
  ;; stream. on-exit is stored AT CONSTRUCTION — the callback travels
  ;; inside uv_process_options_t, so it must be on the record before
  ;; uv_spawn runs (§4.1); there is nothing to clobber on a fresh record.
  ;; exited? is set by the exit dispatcher (§5.4 step 4) and read by the
  ;; lifecycle tests; exit stops the handle but never closes it (§6).
  (define-record-type (uv-process-record %make-uv-process-record uv-process-record?)
    (parent uv-handle-record)
    (fields (mutable on-exit process-on-exit set-process-on-exit!)
            (mutable exited  process-exited? set-process-exited!))
    (protocol
     (lambda (pargs->new)
       (lambda (ptr loop on-exit) ((pargs->new ptr 'process loop) on-exit #f)))))
```

- [ ] **Step 3: Generalize the dispatch arms**

- `alloc-dispatch` (handles.sls:771-776): `uv-tcp-record?` → `uv-stream-record?`, `tcp-read-buf`/`tcp-read-buf-len` → `stream-read-buf`/`stream-read-buf-len`.
- `read-dispatch` (:803-810): `uv-tcp-record?` → `uv-stream-record?`.
- `deliver-read-data!`/`deliver-read-eof!`/`deliver-read-error!` (:821-846): `tcp-on-data/eof/error` → `stream-on-data/eof/error`, `tcp-read-buf` → `stream-read-buf`.
- `free-read-buffer!` (:894-901): `uv-tcp-record?` → `uv-stream-record?`, accessors likewise.
- `handle-kinds` (:396): `'(timer tcp)` → `'(timer tcp pipe process)`.
- `count-handle-free!` (:906-910): add arms `((pipe) (count-pipe-free!))` and `((process) (count-process-free!))`, and add `count-pipe-free! count-process-free!` to the `(only (libuv private native) ...)` import.
- Export list: remove the six `tcp-on-data`…`tcp-reading?` pairs, add the stream accessor pairs, `uv-stream-record?`, and the pipe/process names from **Produces**.

- [ ] **Step 4: Rename the use sites**

```bash
rg -n "tcp-on-data|tcp-on-eof|tcp-on-error|tcp-read-buf|tcp-reading" src/ tests/
```
Every hit in `src/libuv/tcp.sls` (start-reading!, ensure-read-buffer!, uv-read-stop!) and any test that imports the accessors by name changes `tcp-` → `stream-` (`set-tcp-on-data!` → `set-stream-on-data!` etc.). `tcp-on-connection` stays. Do NOT touch the semantics-locking test names/strings — only the identifiers.

- [ ] **Step 5: Run the suite to verify unchanged behavior**

```bash
make test
```
Expected: ALL SUITES PASSED, same assertion counts as Step 1 (record them both in the log).

- [ ] **Step 6: Mutation log**

`.plans/process-stage-3-mutation-log.md`: probe — revert `free-read-buffer!`'s predicate to `uv-tcp-record?` while leaving everything else: suite must stay green TODAY (no pipe exists yet) — record as a forward obligation that Task 9's echo test (pipe read buffer freed on close, counters balanced) discharges. Probe — drop `'pipe` from `handle-kinds`: green today, discharged by Task 6's teardown-sweep row.

- [ ] **Step 7: Commit**

```bash
git add src/libuv/private/handles.sls src/libuv/tcp.sls tests/ .plans/process-stage-3-mutation-log.md
git commit -m "refactor: uv-stream-record hierarchy; pipe/process records; kinds+counters widen (ADR-0014)"
```

---

### Task 6: `(libuv pipe)` + `uv-pipe?`

**Files:**
- Create: `src/libuv/pipe.sls`, `tests/test-pipe.sps`
- Modify: `src/libuv/handle.sls` (add `uv-pipe?`)

**Interfaces:**
- Consumes: `uv-pipe-init` (Task 4), `uv-named-pipe-type` (Task 3), `%make-uv-pipe-record`/`pipe-connected?` (Task 5), `count-pipe-new!` (Task 4).
- Produces: `(make-uv-pipe loop) → pipe record` from `(libuv pipe)`; `(uv-pipe? x) → boolean` from `(libuv handle)`. Task 8's stdio specs and Task 7's gating matrix use both.

- [ ] **Step 1: Write the failing tests**

`tests/test-pipe.sps` (model the boilerplate on tests/test-timer.sps: `#!r6rs`, imports, `test-runner-simple`, baseline `registry-count`, final counter/registry balance + exit form):

```scheme
#!r6rs
;;; SRFI-64 suite for (libuv pipe) — construction and lifecycle only:
;;; a v0.3 pipe is unconnected until uv-spawn! consumes it (THE SPEC §4.6),
;;; so everything a pipe DOES is covered by test-stream.sps (verb gating)
;;; and test-process.sps (stdio). NOT pure; never add to PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv pipe)
        (libuv private handles)
        (libuv private conditions)
        (only (libuv private native) live-counts)
        (uv-testing)
        (only (chezscheme) collect))

(define runner (test-runner-simple))
(test-runner-current runner)
(define (live-count kind) (cdr (assq kind (live-counts))))
(define registry-count-at-start (registry-count))

(test-begin "pipe")

;; --- construction --------------------------------------------------------
(define loop (make-uv-loop))
(define p (make-uv-pipe loop))

(test-assert "make-uv-pipe answers an open pipe handle"
  (and (uv-handle? p) (uv-pipe? p) (uv-handle-open? p)))
(test-assert "a pipe is not a tcp and a tcp predicate refuses it"
  (not (uv-tcp? p)))
(test-equal "pipe counter counts the construction" 1 (live-count 'pipe))
(test-assert "a fresh pipe is unconnected (spawn-consumption state)"
  (not (pipe-connected? p)))
(test-equal "the registry holds the pipe" (+ registry-count-at-start 2)
  (registry-count)) ;; loop entry + pipe entry

;; --- refusals ------------------------------------------------------------
(test-assert "make-uv-pipe refuses a non-loop"
  (guard (e (#t (and (uv-invalid-argument? e)
                     (eq? 'not-a-uv-loop (uv-invalid-argument-reason e)))))
    (make-uv-pipe 42) #f))

;; --- explicit close ------------------------------------------------------
(define closed (list 'not-yet))
(uv-close! p (lambda () (collect) (set! closed 'closed)))
(test-equal "close drains through the loop"
  'satisfied (run-until loop (lambda () (eq? closed 'closed)) 64))
(test-equal "pipe counter returns to zero" 0 (live-count 'pipe))
(test-equal "closed state reads back" 'closed (uv-handle-state p))

;; --- teardown sweep covers an unclosed pipe ------------------------------
(define p2 (make-uv-pipe loop))
(test-equal "second pipe counted" 1 (live-count 'pipe))
(uv-loop-teardown! loop)
(test-equal "teardown swept the unclosed pipe" 0 (live-count 'pipe))
(test-equal "registry back to baseline" registry-count-at-start (registry-count))

(collect)
(test-assert "counters all zero after teardown"
  (for-all (lambda (kv) (zero? (cdr kv))) (live-counts)))

(test-end "pipe")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
```

- [ ] **Step 2: Run to verify failure**

```bash
make test 2>&1 | grep -A3 "test-pipe"
```
Expected: FAIL — `(libuv pipe)` library not found.

- [ ] **Step 3: Implement**

`src/libuv/pipe.sls` — `make-uv-tcp`'s shape verbatim (tcp.sls:80-90), ipc always 0 (§1 non-goal):

```scheme
#!r6rs
;;; (libuv pipe) -- deliberately minimal in v0.3 (THE SPEC §4.6): a pipe
;;; exists to be consumed by uv-spawn! in a (pipe p dir) stdio spec, where
;;; uv_spawn creates the socketpair and connects the parent end into it
;;; (vendor fact V3). No bind/connect/listen (named-pipe IPC is a future
;;; milestone), no ipc=1 fd passing. Stream verbs come from (libuv stream)
;;; and work on a pipe once it is connected; closing is (libuv handle)'s
;;; generic uv-close!.
;;;
;;; VOCABULARY (§4.3): "open/closed" is handle state; "connected/
;;; unconnected" is the spawn-consumption state tracked by the record's
;;; connected? flag. A fresh pipe is open AND unconnected.
(library (libuv pipe)
  (export make-uv-pipe)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))

  ;; The make-uv-tcp shape verbatim: size from the RUNNING library via
  ;; uv_handle_size, type tag from the shim (ADR-0005); a failed init frees
  ;; the block before the condition escapes, and nothing is registered or
  ;; counted yet. ipc is 0 ALWAYS in v0.3 (§1).
  (define (make-uv-pipe loop)
    (ensure-native-loaded!)
    (require-open-loop loop 'make-uv-pipe)
    (let ((ptr (alloc-zeroed (uv-handle-size (uv-named-pipe-type)))))
      (guard (e (#t (free! ptr) (raise e)))
        (uv-check (uv-pipe-init (loop-pointer loop 'make-uv-pipe) ptr 0)
                  'make-uv-pipe))
      (let ((pipe (%make-uv-pipe-record ptr loop)))
        (registry-register! ptr 'pipe loop pipe)
        (count-pipe-new!)
        pipe))))
```

`src/libuv/handle.sls`: add beside `uv-tcp?` (and to the export list):

```scheme
  ;; Kind-keyed like uv-tcp?, and for the same reason (THE SPEC §3): the
  ;; predicate lives with the kind vocabulary, not with the module that
  ;; constructs the handle.
  (define (uv-pipe? handle)
    (and (uv-handle? handle) (eq? (handle-kind handle) 'pipe)))
```

Note `require-open-loop`'s `not-a-uv-loop` reason comes via `require-loop` — the refusal row's expected reason in Step 1 matches handles.sls:206-209.

- [ ] **Step 4: Run tests to verify pass**

```bash
make test
```
Expected: ALL SUITES PASSED including test-pipe.

- [ ] **Step 5: Commit**

```bash
git add src/libuv/pipe.sls src/libuv/handle.sls tests/test-pipe.sps
git commit -m "feat: (libuv pipe) — make-uv-pipe + uv-pipe? (minimal, spawn-stdio only)"
```

---

### Task 7: `(libuv stream)` extraction + gating matrix

**Files:**
- Create: `src/libuv/stream.sls`, `tests/test-stream.sps`
- Modify: `src/libuv/tcp.sls` (verbs move out; re-export)

**Interfaces:**
- Consumes: Task 5's `uv-stream-record?` + stream accessors; Task 4's `require-callback` (from native); Task 6's `make-uv-pipe` (tests only).
- Produces: `(libuv stream)` exporting `uv-write!`, `uv-shutdown!`, `uv-read-start!`, `uv-read-stop!` with signatures, callback contracts, and copy/free discipline IDENTICAL to v0.2's — only the gate widens. `(libuv tcp)` re-exports all four, so every existing importer compiles unchanged. Private: `(require-open-stream s who)` raises `'not-a-uv-stream` (kind) then `&uv-handle-closed` (state).

- [ ] **Step 1: Write the failing tests**

`tests/test-stream.sps` (same boilerplate skeleton as test-pipe.sps; imports add `(libuv stream)`, `(libuv tcp)`, `(libuv timer)`, `(libuv pipe)`):

```scheme
(test-begin "stream")

(define loop (make-uv-loop))
(define tcp (make-uv-tcp loop))
(define pipe (make-uv-pipe loop))
(define timer (make-uv-timer loop))
(define (nop . args) #f)

;; --- the gating matrix (THE SPEC §9.3) -----------------------------------
;; Each verb: accepts tcp (proved by the untouched v0.1/v0.2 suites),
;; refuses a non-stream kind with 'not-a-uv-stream, refuses a closed
;; stream with &uv-handle-closed carrying ITS kind. The refuses-process
;; row lands in Task 10 (test-process.sps), once uv-spawn! can construct
;; one — recorded there, not here.
(define (refuses-timer? thunk)
  (guard (e (#t (and (uv-invalid-argument? e)
                     (eq? 'not-a-uv-stream (uv-invalid-argument-reason e)))))
    (thunk) #f))

(test-assert "uv-write! refuses a timer"
  (refuses-timer? (lambda () (uv-write! timer (make-bytevector 1 0) nop))))
(test-assert "uv-shutdown! refuses a timer"
  (refuses-timer? (lambda () (uv-shutdown! timer nop))))
(test-assert "uv-read-start! refuses a timer"
  (refuses-timer? (lambda () (uv-read-start! timer nop nop nop))))
(test-assert "uv-read-stop! refuses a timer"
  (refuses-timer? (lambda () (uv-read-stop! timer))))

;; --- stream verbs on an UNCONNECTED pipe (THE SPEC §4.6, §9.3) -----------
;; A fresh pipe has no fd yet — uv_spawn is what connects it (V3). The
;; verbs pass the kind gate and libuv answers an errno; this row PINS
;; whatever that errno is (bind what you test): expected 'EBADF-class.
;; The assertion accepts the symbol family rather than one platform's
;; spelling; the informational row prints the observed symbol so the
;; pinned value is recorded in every run's output.
(define unconnected-errno
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e)))
    (uv-write! pipe (make-bytevector 1 7) nop)
    'no-error))
(test-assert "uv-write! on an unconnected pipe surfaces an errno symbol"
  (and (symbol? unconnected-errno) (not (eq? 'no-error unconnected-errno))))
(test-assert "[informational] unconnected-pipe errno recorded"
  (begin (display "  [informational] unconnected pipe write: ")
         (display unconnected-errno) (newline) #t))

;; --- closed-stream refusals ---------------------------------------------
(uv-close! pipe)
(run-until loop (lambda () (eq? 'closed (uv-handle-state pipe))) 64)
(test-assert "uv-write! on a closed pipe raises &uv-handle-closed kind 'pipe"
  (guard (e (#t (and (uv-handle-closed? e)
                     (eq? 'pipe (uv-handle-closed-kind e)))))
    (uv-write! pipe (make-bytevector 1 0) nop) #f))

;; --- tcp still works through the re-export (regression canary) ----------
(test-assert "uv-write! still accepts an open tcp (kind gate only — EBADF-class errno is fine)"
  (guard (e ((uv-errno-error? e) #t))   ;; unbound tcp: libuv may refuse; the KIND gate passed
    (uv-write! tcp (make-bytevector 1 0) nop) #t))

(uv-loop-teardown! loop)
(collect)
(test-assert "counters all zero after teardown"
  (for-all (lambda (kv) (zero? (cdr kv))) (live-counts)))
(test-equal "registry back to baseline" registry-count-at-start (registry-count))

(test-end "stream")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
```

- [ ] **Step 2: Run to verify failure**

```bash
make test 2>&1 | grep -A3 "test-stream"
```
Expected: FAIL — `(libuv stream)` not found.

- [ ] **Step 3: Create `src/libuv/stream.sls`**

Move — verbatim, then transform — from tcp.sls: `uv-write!` (tcp.sls:252-295), `uv-shutdown!` (:300-309), `uv-read-start!`/`start-reading!`/`default-read-buffer-size`/`ensure-read-buffer!` (:326-395), `uv-read-stop!` (:402-406). Header comments move with their procedures. The transformation, uniformly:

1. `require-open-tcp` → `require-open-stream`, defined at the top of stream.sls:

```scheme
  ;; A STREAM handle (tcp or pipe), and open. Kind check first, state check
  ;; second, different conditions — the require-open-tcp split (tcp.sls:44-54),
  ;; widened to the record hierarchy ADR-0014 introduces. uv_write/uv_read
  ;; on a non-stream handle is undefined behaviour, not an errno; a closed
  ;; stream still answers &uv-handle-closed with ITS kind.
  (define (require-open-stream stream who)
    (unless (uv-stream-record? stream)
      (raise (make-uv-invalid-argument who 'not-a-uv-stream)))
    (require-open-handle stream who)
    stream)
```

2. Every `tcp` parameter name → `stream` (readability only); every `set-tcp-on-data!`-family accessor → the `stream-` spelling (already done inside handles.sls in Task 5 — here it is the call sites moving).
3. `require-callback` now comes from `(libuv private native)` (Task 4) — delete tcp.sls's private copy when the verbs leave.
4. Library form:

```scheme
(library (libuv stream)
  (export uv-write! uv-shutdown! uv-read-start! uv-read-stop!)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))
  ...)
```

Library header comment: state that these are v0.1's stream verbs with an unchanged contract, gate widened per ADR-0014, and quote the two iron rules.

- [ ] **Step 4: Shrink tcp.sls and re-export**

tcp.sls keeps `make-uv-tcp`, `uv-tcp-bind!`, `uv-tcp-getsockname-port`, `uv-listen!`, `uv-accept!`, `uv-tcp-connect!`, `uv-tcp-nodelay!`. Its export form re-exports the four moved verbs so importers compile unchanged:

```scheme
(library (libuv tcp)
  (export make-uv-tcp
          uv-tcp-bind! uv-tcp-getsockname-port
          uv-listen! uv-accept! uv-tcp-connect!
          uv-tcp-nodelay!
          ;; re-exported from (libuv stream) (ADR-0014): the verbs moved,
          ;; the import surface did not.
          uv-write! uv-shutdown! uv-read-start! uv-read-stop!)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles)
          (libuv stream))
  ...)
```

`uv-listen!` still calls `require-open-tcp` (which stays in tcp.sls) and `require-callback` (now from native).

- [ ] **Step 5: Run tests to verify pass**

```bash
make test
```
Expected: ALL SUITES PASSED — test-stream green AND the untouched test-tcp/test-echo suites green through the re-export (the real regression assertion of this task).

- [ ] **Step 6: Mutation log**

`.plans/process-stage-4-mutation-log.md`: probe — narrow `require-open-stream`'s predicate back to `uv-tcp-record?`: test-stream's unconnected-pipe row fails ('not-a-uv-stream instead of an errno). Probe — swap the kind/state check order: the closed-pipe row fails (wrong condition type). Record both observed.

- [ ] **Step 7: Commit**

```bash
git add src/libuv/stream.sls src/libuv/tcp.sls tests/test-stream.sps .plans/process-stage-4-mutation-log.md
git commit -m "refactor: extract (libuv stream) — verbs gate on stream kind; tcp re-exports (ADR-0014)"
```

---

### Task 8: `(libuv process)` core — validation, spawn, exit dispatcher

The largest task: `uv-spawn!` end to end with the full stdio-spec vocabulary, the exit dispatcher, and the validation walk. Kill/pid/detached/lifecycle rows follow in Tasks 9–10 against this foundation.

**Files:**
- Create: `src/libuv/process.sls`, `tests/test-process.sps`
- Modify: `src/libuv/handle.sls` (add `uv-process?`)

**Interfaces:**
- Consumes: everything Tasks 3–7 produced (accessors, `uv-spawn-native`, records, `make-uv-pipe`, stream verbs).
- Produces (public, from `(libuv process)`): `uv-spawn!` per THE SPEC §4.1-§4.4. From `(libuv handle)`: `uv-process?`. Private within process.sls, reused by Tasks 9–10: `require-open-process`, `signal-symbol->int`, `term-signal->value`.
- Exit delivery: `(on-exit exit-status term-signal)`, term-signal `#f` | symbol | raw int.

- [ ] **Step 1: Write the failing tests (core scenarios)**

`tests/test-process.sps` (test-timer.sps boilerplate; imports: `(rnrs) (srfi :64) (libuv loop) (libuv handle) (libuv pipe) (libuv process) (libuv stream) (libuv tcp) (libuv private handles) (libuv private conditions) (only (libuv private native) live-counts) (uv-testing) (only (chezscheme) collect putenv)`):

```scheme
(test-begin "process")
(define (live-count kind) (cdr (assq kind (live-counts))))
(define registry-count-at-start (registry-count))

;; Every scenario runs on a fresh loop torn down at its end, so counter
;; rows localize failures. Helper:
(define (with-loop body)
  (let ((loop (make-uv-loop)))
    (body loop)
    (uv-loop-teardown! loop)))

;; --- exit-code delivery (THE SPEC §9.2) ----------------------------------
(with-loop
 (lambda (loop)
   (define result 'not-yet)   ;; sentinel symbol, never #f
   (define proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 7")
                (lambda (status sig)
                  (collect)
                  (set! result (list status sig)))))
   (test-assert "uv-spawn! answers an open process handle"
     (and (uv-process? proc) (uv-handle-open? proc)))
   (test-equal "process counter counts the spawn" 1 (live-count 'process))
   (test-equal "exit callback delivers (7 #f)"
     'satisfied (run-until/ticking loop (lambda () (pair? result)) 2048))
   (test-equal "normal exit: status is the code, term-signal #f"
     '(7 #f) result)
   (test-assert "exit does not close: the handle is still open (§6)"
     (uv-handle-open? proc))
   (uv-close! proc)
   (test-equal "close drains"
     'satisfied (run-until loop
                           (lambda () (eq? 'closed (uv-handle-state proc)))
                           64))
   (test-equal "process counter back to zero" 0 (live-count 'process))))

;; --- argv/env/cwd combined: THE mutation target for every §5.3 offset row
(with-loop
 (lambda (loop)
   (define out (make-byte-collector))
   (define done 'not-yet)
   (define stdout-pipe (make-uv-pipe loop))
   (define proc
     (uv-spawn! loop "/bin/sh"
                '("sh" "-c" "printf '%s|%s|%s|%s' \"$0\" \"$1\" \"$FOO\" \"$(pwd)\"" "argv-zero" "argv-one")
                (list (cons 'env '("FOO=from-env" "PATH=/usr/bin:/bin"))
                      (cons 'cwd "/")
                      (cons 'stdio (list 'ignore
                                         (list 'pipe stdout-pipe 'from-child))))
                (lambda (status sig) (collect) (set! done (list status sig)))))
   (define eof 'not-yet)
   (uv-read-start! stdout-pipe
                   (lambda (bv start end) (collect) (collect-span! out bv start end))
                   (lambda () (set! eof 'eof))
                   (lambda (err) (set! eof (list 'error err))))
   (test-equal "child exited cleanly"
     'satisfied (run-until/ticking loop (lambda () (pair? done)) 4096))
   (test-equal "EOF and exit both observed — independently, either order"
     'satisfied (run-until/ticking loop (lambda () (eq? eof 'eof)) 4096))
   (test-equal "argv[0], argv[1], env, and cwd all arrived as written"
     "argv-zero|argv-one|from-env|/"
     (utf8->string (collector-bytes out)))
   (uv-close! proc)
   (uv-close! stdout-pipe)
   (run-until loop (lambda () (and (eq? 'closed (uv-handle-state proc))
                                   (eq? 'closed (uv-handle-state stdout-pipe))))
              128)))

;; --- env inheritance (no env key ⇒ parent env crosses) -------------------
(with-loop
 (lambda (loop)
   (putenv "CHEZ_LIBUV_TEST_INHERIT" "inherited-value")
   (define out (make-byte-collector))
   (define done 'not-yet)
   (define p (make-uv-pipe loop))
   (uv-spawn! loop "/bin/sh"
              '("sh" "-c" "printf '%s' \"$CHEZ_LIBUV_TEST_INHERIT\"")
              (list (cons 'stdio (list 'ignore (list 'pipe p 'from-child))))
              (lambda (s g) (collect) (set! done 'exited)))
   (define eof 'not-yet)
   (uv-read-start! p (lambda (bv s e) (collect-span! out bv s e))
                     (lambda () (set! eof 'eof))
                     (lambda (err) (set! eof 'error)))
   (run-until/ticking loop (lambda () (and (eq? done 'exited) (eq? eof 'eof))) 4096)
   (test-equal "omitted env inherits the parent's"
     "inherited-value" (utf8->string (collector-bytes out)))
   ;; teardown sweeps the un-closed handles — that is also an assertion:
   ))

;; --- 'ENOENT: synchronous, nothing half-built (SQ1's production twin) ----
(with-loop
 (lambda (loop)
   (define procs-before (live-count 'process))
   (define registry-before (registry-count))
   (test-assert "spawning a missing file raises 'ENOENT synchronously"
     (guard (e ((uv-errno-error? e) (eq? 'ENOENT (uv-errno-error-errno e))))
       (uv-spawn! loop "/nonexistent/definitely-missing"
                  '("definitely-missing") #f)
       #f))
   (test-equal "no process counted on the failure path"
     procs-before (live-count 'process))
   (test-equal "no registry entry leaked on the failure path"
     registry-before (registry-count))
   (test-equal "no options block leaked" 0 (live-count 'spawn-options))))

;; --- 'EPERM: setuid as non-root (THE SPEC §9.2 — the NORMAL suite) -------
(with-loop
 (lambda (loop)
   (test-assert "uid option as non-root fails 'EPERM (or 'EACCES per platform) at spawn"
     (guard (e ((uv-errno-error? e)
                (memq (uv-errno-error-errno e) '(EPERM EACCES))))
       (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 0")
                  (list (cons 'uid 1)) #f)
       #f))))

;; --- on-exit #f: reaping still happens, lifecycle machinery still runs ---
(with-loop
 (lambda (loop)
   (define proc (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 0") #f))
   (test-equal "loop drains with no user callback (reaped via the dispatcher)"
     'satisfied (run-until/ticking loop
                                   (lambda () (process-exited? proc)) 2048))
   (test-assert "handle still open and closeable after silent reap"
     (uv-handle-open? proc))
   (uv-close! proc)
   (run-until loop (lambda () (eq? 'closed (uv-handle-state proc))) 64)))

;; --- the validation walk: every §4.7 reason symbol -----------------------
(with-loop
 (lambda (loop)
   (define (reason-of thunk)
     (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
       (thunk) 'no-raise))
   (define (spawn-with . args) (lambda () (apply uv-spawn! loop args)))
   (define ok-args '("sh" "-c" "exit 0"))
   (test-equal 'file-not-a-string
     (reason-of (spawn-with 42 ok-args #f)))
   (test-equal 'args-not-a-string-list
     (reason-of (spawn-with "/bin/sh" '() #f)))
   (test-equal 'args-not-a-string-list
     (reason-of (spawn-with "/bin/sh" '("sh" 42) #f)))
   (test-equal 'embedded-nul
     (reason-of (spawn-with "/bin/\x0;sh" ok-args #f)))
   (test-equal 'embedded-nul
     (reason-of (spawn-with "/bin/sh" '("sh\x0;x") #f)))
   (test-equal 'option-unknown
     (reason-of (spawn-with "/bin/sh" ok-args '((bogus . 1)) #f)))
   (test-equal 'env-not-a-string-list
     (reason-of (spawn-with "/bin/sh" ok-args '((env . "A=b")) #f)))
   (test-equal 'embedded-nul
     (reason-of (spawn-with "/bin/sh" ok-args (list (cons 'env '("A=\x0;b"))) #f)))
   (test-equal 'cwd-not-a-string
     (reason-of (spawn-with "/bin/sh" ok-args '((cwd . 7)) #f)))
   (test-equal 'detached-not-a-boolean
     (reason-of (spawn-with "/bin/sh" ok-args '((detached . 1)) #f)))
   (test-equal 'uid-out-of-range
     (reason-of (spawn-with "/bin/sh" ok-args '((uid . -1)) #f)))
   (test-equal 'gid-out-of-range
     (reason-of (spawn-with "/bin/sh" ok-args '((gid . 4294967296)) #f)))
   (test-equal 'stdio-not-a-list
     (reason-of (spawn-with "/bin/sh" ok-args '((stdio . ignore)) #f)))
   (test-equal 'stdio-spec-unknown
     (reason-of (spawn-with "/bin/sh" ok-args '((stdio . (bogus))) #f)))
   (test-equal 'stdio-fd-not-an-fd
     (reason-of (spawn-with "/bin/sh" ok-args
                            '((stdio . ((inherit-fd . not-a-number)))) #f)))
   (test-equal 'on-exit-not-a-procedure
     (reason-of (spawn-with "/bin/sh" ok-args 'not-a-proc)))
   ;; pipe-already-used / pipe-wrong-loop rows land in Task 9 (they need a
   ;; consumed pipe / second loop); signal-unknown lands in Task 10.
   (test-equal "validation raised nothing into the counters"
     0 (live-count 'spawn-options))))

(collect)
(test-assert "counters all zero at suite end"
  (for-all (lambda (kv) (zero? (cdr kv))) (live-counts)))
(test-equal "registry back to baseline" registry-count-at-start (registry-count))
(test-end "process")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
```

Note on stdio spec syntax in tests: specs are `'ignore`, `(list 'pipe p dir)`, `'(inherit-fd . n)` written as a pair `(inherit-fd . 3)` — see Step 3's parser for the exact accepted shapes: `(inherit-fd . n)`, `(inherit-stream . h)`, `(pipe h dir)` (a 3-list). The `'(stdio . ((inherit-fd . not-a-number)))` row above matches that.

- [ ] **Step 2: Run to verify failure**

```bash
make test 2>&1 | grep -A3 "test-process"
```
Expected: FAIL — `(libuv process)` not found.

- [ ] **Step 3: Implement `src/libuv/process.sls`**

Complete implementation (kill/pid arrive in Task 10 — the export list below already names them; add `(define (uv-process-kill! . _) ...)` NOT as a stub — instead export only what exists now and widen the export list in Task 10):

```scheme
#!r6rs
;;; (libuv process) -- uv_spawn and friends as a legible mirror (THE SPEC
;;; §4). A process is a HANDLE (not a stream): explicit uv-close! even
;;; after exit (ADR-0007, §6), swept by teardown, kept reachable by its
;;; registry entry alone.
;;;
;;; EXIT != CLOSE (§6, V5): on-exit stops the handle; the caller still
;;; closes it. Killed-by-SIGTERM arrives as (0 sigterm), NOT (-1 ...) —
;;; libuv's own semantics, mirrored not repaired.
;;;
;;; PID VALIDITY ENDS AT THE EXIT CALLBACK (§4.5): the child is reaped by
;;; the time on-exit runs, so kill-after-exit races pid reuse. Kill before
;;; exit is the supported path.
;;;
;;; THE TWO RULES OF EVERY START CALL (tcp.sls's, verbatim): every argument
;;; is validated before the first allocation, and a failed native call
;;; leaves nothing half-built.
;;;
;;; EXIT DISPATCH POLICY LIVES HERE (the dns.sls late-install precedent):
;;; native.sls carries the mechanical trampoline; the dispatcher below is
;;; installed through install-dispatch-procedure! at THIS library's body
;;; time. A process image that never imports (libuv process) keeps the
;;; contained raising stub, and nothing can spawn without the import.
(library (libuv process)
  (export uv-spawn!)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))

  ;; --- argument predicates ------------------------------------------------
  (define (require-open-process proc who)
    (unless (uv-process-record? proc)
      (raise (make-uv-invalid-argument who 'not-a-uv-process)))
    (require-open-handle proc who)
    proc)

  ;; NUL validation (§5.5): an embedded NUL silently truncates at the C
  ;; boundary (spike-measured, v0.2 FINDINGS) — the C callee would see a
  ;; prefix, which is how "/bin/sh\0 -rf" becomes /bin/sh. Refused by name.
  (define (require-nul-free-string s who type-reason)
    (unless (string? s)
      (raise (make-uv-invalid-argument who type-reason)))
    (let scan ((i 0))
      (when (< i (string-length s))
        (when (char=? #\nul (string-ref s i))
          (raise (make-uv-invalid-argument who 'embedded-nul)))
        (scan (+ i 1)))))

  (define (require-string-list lst who reason)
    (unless (and (list? lst) (not (null? lst)))
      (raise (make-uv-invalid-argument who reason)))
    (for-each (lambda (s) (require-nul-free-string s who reason)) lst))

  ;; uid/gid: exact integers in [0, 2^32) (§4.2's table, reasons named
  ;; there). The width matches uv_uid_t/uv_gid_t (32-bit on Unix).
  (define (require-u32 n who reason)
    (unless (and (integer? n) (exact? n) (>= n 0) (< n 4294967296))
      (raise (make-uv-invalid-argument who reason))))

  ;; --- the options alist (§4.2): closed key set ---------------------------
  ;; Omitted, #f, and '() all mean "defaults" (the hints precedent).
  ;; Unknown keys are refused BY NAME; a malformed alist entry is
  ;; 'option-unknown too (it is not any known option).
  (define option-keys '(env cwd stdio detached uid gid))

  (define (validate-options options who)
    (unless (list? options)
      (raise (make-uv-invalid-argument who 'option-unknown)))
    (for-each
     (lambda (entry)
       (unless (and (pair? entry) (memq (car entry) option-keys))
         (raise (make-uv-invalid-argument who 'option-unknown))))
     options)
    (let ((env      (assq 'env options))
          (cwd      (assq 'cwd options))
          (stdio    (assq 'stdio options))
          (detached (assq 'detached options))
          (uid      (assq 'uid options))
          (gid      (assq 'gid options)))
      (when env
        (unless (and (list? (cdr env)) (not (null? (cdr env))))
          (raise (make-uv-invalid-argument who 'env-not-a-string-list)))
        (for-each (lambda (s)
                    (require-nul-free-string s who 'env-not-a-string-list))
                  (cdr env)))
      (when cwd (require-nul-free-string (cdr cwd) who 'cwd-not-a-string))
      (when detached
        (unless (boolean? (cdr detached))
          (raise (make-uv-invalid-argument who 'detached-not-a-boolean))))
      (when uid (require-u32 (cdr uid) who 'uid-out-of-range))
      (when gid (require-u32 (cdr gid) who 'gid-out-of-range))
      (when stdio
        (unless (list? (cdr stdio))
          (raise (make-uv-invalid-argument who 'stdio-not-a-list)))
        (for-each (lambda (spec) (validate-stdio-spec spec who)) (cdr stdio)))
      ;; The parsed view later steps consume: (env cwd stdio-specs
      ;; detached? uid gid), absent → #f (stdio absent → '()).
      (list (and env (cdr env))
            (and cwd (cdr cwd))
            (if stdio (cdr stdio) '())
            (and detached (cdr detached))
            (and uid (cdr uid))
            (and gid (cdr gid)))))

  ;; --- stdio specs (§4.3) --------------------------------------------------
  ;; 'ignore | (inherit-fd . n) | (inherit-stream . h) | (pipe h dir),
  ;; dir in to-child / from-child / duplex (NOT libuv's child-perspective
  ;; READABLE/WRITABLE names — ADR-0016 records the mapping: to-child =
  ;; UV_READABLE_PIPE, from-child = UV_WRITABLE_PIPE, duplex = both).
  (define (validate-stdio-spec spec who)
    (cond
      ((eq? spec 'ignore) #t)
      ((and (pair? spec) (eq? 'inherit-fd (car spec)))
       (let ((fd (cdr spec)))
         (unless (and (integer? fd) (exact? fd) (>= fd 0))
           (raise (make-uv-invalid-argument who 'stdio-fd-not-an-fd)))))
      ((and (pair? spec) (eq? 'inherit-stream (car spec)))
       (let ((h (cdr spec)))
         (unless (uv-stream-record? h)
           (raise (make-uv-invalid-argument who 'stdio-spec-unknown)))
         (require-open-handle h who)))
      ((and (list? spec) (= 3 (length spec)) (eq? 'pipe (car spec)))
       (let ((p (cadr spec)) (dir (caddr spec)))
         (unless (uv-pipe-record? p)
           (raise (make-uv-invalid-argument who 'stdio-spec-unknown)))
         (require-open-handle p who)
         (when (pipe-connected? p)
           (raise (make-uv-invalid-argument who 'pipe-already-used)))
         (unless (memq dir '(to-child from-child duplex))
           (raise (make-uv-invalid-argument who 'stdio-spec-unknown)))))
      (else (raise (make-uv-invalid-argument who 'stdio-spec-unknown)))))

  ;; The pipe/inherit-stream loop check needs the spawn loop, so it runs in
  ;; start-spawn! after validate-options (§4.3: 'pipe-wrong-loop).
  (define (require-same-loop-stdio! specs loop who)
    (for-each
     (lambda (spec)
       (let ((h (cond ((and (pair? spec) (eq? 'inherit-stream (car spec)))
                       (cdr spec))
                      ((and (list? spec) (eq? 'pipe (car spec))) (cadr spec))
                      (else #f))))
         (when (and h (not (eq? (handle-loop h) loop)))
           (raise (make-uv-invalid-argument who 'pipe-wrong-loop)))))
     specs))

  (define (stdio-spec-flags spec)
    (cond
      ((eq? spec 'ignore) (uv-stdio-ignore))
      ((eq? 'inherit-fd (car spec)) (uv-stdio-inherit-fd))
      ((eq? 'inherit-stream (car spec)) (uv-stdio-inherit-stream))
      (else ;; (pipe h dir)
       (bitwise-ior (uv-stdio-create-pipe)
                    (case (caddr spec)
                      ((to-child)   (uv-stdio-readable-pipe))
                      ((from-child) (uv-stdio-writable-pipe))
                      ((duplex)     (bitwise-ior (uv-stdio-readable-pipe)
                                                 (uv-stdio-writable-pipe)))
                      ;; validate-stdio-spec ran first; unreachable, kept
                      ;; raising (house convention, tcp.sls:150-156).
                      (else (raise (make-uv-invalid-argument
                                    'uv-spawn! 'stdio-spec-unknown))))))))

  ;; --- the co-allocated options block (§5.5, ADR-0015) --------------------
  ;; ONE foreign-alloc: [uv_process_options_t | stdio containers | argv
  ;; ptr array | env ptr array | string bytes]. Zeroed, so every absent
  ;; field is already NULL/0 and every string's NUL terminator is the
  ;; zeroed gap after its bytes. Freed unconditionally the moment
  ;; uv_spawn returns (V1: libuv consumes everything synchronously and
  ;; copies only exit_cb and pid into the handle — process.c:1054).
  ;;
  ;; Layout arithmetic is all in exact integers; pointer slots are
  ;; c-uptr-size wide, aligned by align-16 between REGIONS (stricter than
  ;; needed — one rule, no per-field cases).
  (define (utf8-size s) (+ 1 (bytevector-length (string->utf8 s))))

  (define (build-options-block parsed file args)
    (let* ((env       (car parsed))
           (cwd       (cadr parsed))
           (specs     (caddr parsed))
           (detached? (cadddr parsed))
           (uid       (car (cddddr parsed)))
           (gid       (cadr (cddddr parsed)))
           (ptr-size  (c-uptr-size))
           (n-stdio   (length specs))
           (stdio-off (align-16 (sizeof-uv-process-options-t)))
           (argv-off  (align-16 (+ stdio-off
                                   (* n-stdio (sizeof-uv-stdio-container-t)))))
           (env-off   (align-16 (+ argv-off (* (+ 1 (length args)) ptr-size))))
           (strings-off (align-16 (+ env-off
                                     (if env (* (+ 1 (length env)) ptr-size) 0))))
           (strings-size (+ (utf8-size file)
                            (if cwd (utf8-size cwd) 0)
                            (fold-left + 0 (map utf8-size args))
                            (if env (fold-left + 0 (map utf8-size env)) 0)))
           (block (alloc-zeroed (+ strings-off strings-size))))
      (count-spawn-options-new!)
      ;; String area cursor: copy each string's UTF-8 bytes, return its
      ;; absolute address, advance past the zeroed NUL gap.
      (let ((cursor strings-off))
        (define (put-string! s)
          (let* ((bv (string->utf8 s))
                 (at (+ block cursor)))
            (copy-in! at bv 0 (bytevector-length bv))
            (set! cursor (+ cursor (bytevector-length bv) 1))
            at))
        ;; file / cwd / argv / env — pointers written as we go.
        (c-uptr-set! (+ block (offsetof-uv-process-options-t-file))
                     (put-string! file))
        (when cwd
          (c-uptr-set! (+ block (offsetof-uv-process-options-t-cwd))
                       (put-string! cwd)))
        (let arg-loop ((as args) (i 0))
          (unless (null? as)
            (c-uptr-set! (+ block argv-off (* i ptr-size))
                         (put-string! (car as)))
            (arg-loop (cdr as) (+ i 1))))
        ;; argv's terminating NULL is the zeroed slot already there.
        (c-uptr-set! (+ block (offsetof-uv-process-options-t-args))
                     (+ block argv-off))
        (when env
          (let env-loop ((es env) (i 0))
            (unless (null? es)
              (c-uptr-set! (+ block env-off (* i ptr-size))
                           (put-string! (car es)))
              (env-loop (cdr es) (+ i 1))))
          (c-uptr-set! (+ block (offsetof-uv-process-options-t-env))
                       (+ block env-off))))
      ;; stdio containers: flags int at +FLAGS, fd as int / stream ptr as
      ;; uptr at +DATA (the union — V2).
      (let stdio-loop ((ss specs) (i 0))
        (unless (null? ss)
          (let ((c (+ block stdio-off (* i (sizeof-uv-stdio-container-t))))
                (spec (car ss)))
            (c-int-set! (+ c (offsetof-uv-stdio-container-t-flags))
                        (stdio-spec-flags spec))
            (cond
              ((eq? spec 'ignore) #f)
              ((eq? 'inherit-fd (car spec))
               (c-int-set! (+ c (offsetof-uv-stdio-container-t-data))
                           (cdr spec)))
              ((eq? 'inherit-stream (car spec))
               (c-uptr-set! (+ c (offsetof-uv-stdio-container-t-data))
                            (handle-pointer (cdr spec) 'uv-spawn!)))
              (else ;; (pipe h dir)
               (c-uptr-set! (+ c (offsetof-uv-stdio-container-t-data))
                            (handle-pointer (cadr spec) 'uv-spawn!)))))
          (stdio-loop (cdr ss) (+ i 1))))
      (c-int-set! (+ block (offsetof-uv-process-options-t-stdio-count)) n-stdio)
      (when (positive? n-stdio)
        (c-uptr-set! (+ block (offsetof-uv-process-options-t-stdio))
                     (+ block stdio-off)))
      ;; flags: uid/gid PRESENCE implies the flag (§4.2 — the footgun is
      ;; closed at the public boundary; "field set, flag clear" cannot be
      ;; expressed). V8: only these three bits can ever be OR'd, so
      ;; libuv's unknown-flag assert is unreachable from Scheme.
      (c-int-set! (+ block (offsetof-uv-process-options-t-flags))
                  (bitwise-ior (if detached? (uv-process-detached-flag) 0)
                               (if uid (uv-process-setuid-flag) 0)
                               (if gid (uv-process-setgid-flag) 0)))
      (when uid (c-u32-set! (+ block (offsetof-uv-process-options-t-uid)) uid))
      (when gid (c-u32-set! (+ block (offsetof-uv-process-options-t-gid)) gid))
      block))

  (define (free-options-block! block)
    (free! block)
    (count-spawn-options-free!))

  ;; --- uv-spawn! (§4.1, §5.5) ----------------------------------------------
  ;; (uv-spawn! loop file args on-exit)
  ;; (uv-spawn! loop file args options on-exit)
  ;; on-exit: procedure or #f — #f is surface-only (§4.1): the trampoline
  ;; is ALWAYS baked in (uv-spawn-native writes it), NULL is never passed,
  ;; and the dispatcher runs the lifecycle machinery for every spawn.
  (define uv-spawn!
    (case-lambda
      ((loop file args on-exit)
       (start-spawn! loop file args '() on-exit))
      ((loop file args options on-exit)
       (start-spawn! loop file args (or options '()) on-exit))))

  (define (start-spawn! loop file args options on-exit)
    (ensure-native-loaded!)
    ;; EVERY CHECK FIRST, THE FIRST ALLOCATION AFTER ALL OF THEM (§5.5
    ;; step 1; the two iron rules).
    (require-open-loop loop 'uv-spawn!)
    (require-nul-free-string file 'uv-spawn! 'file-not-a-string)
    (require-string-list args 'uv-spawn! 'args-not-a-string-list)
    (unless (or (not on-exit) (procedure? on-exit))
      (raise (make-uv-invalid-argument 'uv-spawn! 'on-exit-not-a-procedure)))
    (let ((parsed (validate-options options 'uv-spawn!)))
      (require-same-loop-stdio! (caddr parsed) loop 'uv-spawn!)
      ;; Step 2: the handle block + record (on-exit stored NOW — it rides
      ;; in the options struct, §4.1). Not registered, not counted yet.
      (let ((ptr (alloc-zeroed (uv-handle-size (uv-process-type)))))
        (let ((proc (%make-uv-process-record ptr loop on-exit))
              ;; Step 3: the one co-allocated options block.
              (block (build-options-block parsed file args)))
          ;; Step 4: spawn. Step 5: free the block UNCONDITIONALLY.
          (let ((rc (uv-spawn-native (loop-pointer loop 'uv-spawn!)
                                     ptr block)))
            (free-options-block! block)
            (if (zero? rc)
                ;; Step 6: only now does anything become findable.
                (begin
                  (registry-register! ptr 'process loop proc)
                  (count-process-new!)
                  (for-each (lambda (spec)
                              (when (and (list? spec) (eq? 'pipe (car spec)))
                                (set-pipe-connected! (cadr spec) #t)))
                            (caddr parsed))
                  proc)
                ;; §5.6: the SQ1-selected cleanup. KEEP EXACTLY ONE of the
                ;; two variants below, per ADR-0015's accepted answer, and
                ;; delete the other plus this sentence.
                (begin
                  ;; §5.6: the SQ1-selected cleanup — KEEP EXACTLY ONE
                  ;; variant per ADR-0015's accepted answer, delete the
                  ;; other and this sentence.
                  ;;
                  ;; Variant A (direct free): libuv's error path removed
                  ;; the handle from the loop's queue; no callback will
                  ;; ever fire for it, so the block is freed here — via
                  ;; handles.sls's discard-failed-handle! (added Step 3
                  ;; wiring note (2)) so freeing stays in one file:
                  ;;   (discard-failed-handle! proc)
                  ;;
                  ;; Variant B (close through the protocol): the handle
                  ;; WAS initialized, so it may only die by close_cb:
                  ;;   (registry-register! ptr 'process loop proc)
                  ;;   (count-process-new!)
                  ;;   (close-handle! proc)
                  ;;   ;; close completes on the caller's next uv-run;
                  ;;   ;; counters balance then, and the ENOENT test's
                  ;;   ;; counter row must drain the loop first.
                  ;;
                  (uv-check rc 'uv-spawn!))))))))

  ;; --- the exit dispatcher (§5.4) ------------------------------------------
  ;; uv_exit_cb: void (*)(uv_process_t*, int64_t, int). Runs inside
  ;; handles.sls's seam guard. NO handle state check, deliberately: an
  ;; exit queued behind a uv_close still deserves delivery (the request-
  ;; dispatcher tolerance rule, §5.4). Nothing is freed here — exit stops
  ;; the handle; the close dispatcher remains the only freeing site.
  (define (term-signal->value n)
    (cond ((zero? n) #f)
          ((= n (sig-term)) 'sigterm)
          ((= n (sig-kill)) 'sigkill)
          ((= n (sig-int))  'sigint)
          ((= n (sig-hup))  'sighup)
          ((= n (sig-quit)) 'sigquit)
          ((= n (sig-usr1)) 'sigusr1)
          ((= n (sig-usr2)) 'sigusr2)
          ((= n (sig-cont)) 'sigcont)
          ((= n (sig-stop)) 'sigstop)
          ;; A signal outside the bound set passes through RAW — never
          ;; dropped, never fabricated (§4.4).
          (else n)))

  (define (exit-dispatch handle-ptr exit-status term-signal)
    (let ((proc (registry-ref handle-ptr)))
      (if (uv-process-record? proc)
          (begin
            (set-process-exited! proc #t)
            (let ((on-exit (process-on-exit proc))
                  (sig (term-signal->value term-signal)))
              (when on-exit
                (dispatch-guarded (handle-loop proc)
                                  (lambda () (on-exit exit-status sig))))))
          (record-orphan-callback! 'exit handle-ptr))))

  ;; The once-per-name late install (dns.sls:543-547 precedent).
  (define exit-dispatch-installed
    (install-dispatch-procedure! 'exit exit-dispatch)))
```

Two wiring notes: (1) `record-orphan-callback!` is not currently exported from handles.sls — export it (it is defined at handles.sls:580; dns delegates orphan recording to complete-request!, but a process has no request path, so the direct call is right; add it to the export list beside `orphan-callback-events`). (2) `set-handle-ptr!`/`set-handle-state!` are internal to handles.sls — if Variant A wins SQ1, export them (or better: add a `(discard-failed-handle! record)` helper in handles.sls that does pop-nothing/free/zero/'closed in one exported procedure, keeping the freeing discipline in one file — prefer this; the code above then reads `(discard-failed-handle! proc)`).

`src/libuv/handle.sls`: add `uv-process?` beside `uv-pipe?`:

```scheme
  (define (uv-process? handle)
    (and (uv-handle? handle) (eq? (handle-kind handle) 'process)))
```

and export it.

- [ ] **Step 4: Run tests to verify pass**

```bash
make test
```
Expected: ALL SUITES PASSED. The argv/env/cwd row failing here means an offset row or the block layout is wrong — that is the test doing its job (it is the named mutation target for §5.3).

- [ ] **Step 5: Discharge Task 4's forward obligations + mutation log**

`.plans/process-stage-5-mutation-log.md`: (1) swap `integer-64`/`int` in exit-callable → exit-code test fails (record observed); revert. (2) point `uv-spawn-native`'s write at the flags offset → spawn fails or exit never fires (record); revert. (3) swap the shim's FILE and CWD offset rows → argv/env/cwd test fails by name (ADR-0005's deletion/mutation claim); revert. (4) delete `count-spawn-options-free!` from the failure path → ENOENT scenario's `spawn-options = 0` row fails; revert.

- [ ] **Step 6: Commit**

```bash
git add src/libuv/process.sls src/libuv/handle.sls tests/test-process.sps src/libuv/private/handles.sls .plans/process-stage-5-mutation-log.md
git commit -m "feat: (libuv process) — uv-spawn! with full stdio vocabulary + exit dispatcher (eleventh seam)"
```

---

### Task 9: stdio scenarios — echo, duplex, extra fd, inherit-fd/stream

All-new test scenarios against Task 8's implementation; production code changes only if a scenario exposes a defect (fix inline, note in the log).

**Files:**
- Modify: `tests/test-process.sps` (append scenarios), `tests/tmp/` used at runtime (already exists)

**Interfaces:**
- Consumes: `uv-spawn!`, `make-uv-pipe`, stream verbs, `bind-loopback!`/`connect-loopback!` (uv-testing), Chez `port-file-descriptor` + `open-file-output-port`.
- Produces: the §9.2 stdio coverage later reviews point at; discharges Task 5's forward obligations (pipe read-buffer freeing, pipe in handle-kinds).

- [ ] **Step 1: Append the failing/observing scenarios**

```scheme
;; --- full echo loop (§9.2; SQ3's production twin) ------------------------
(with-loop
 (lambda (loop)
   (define stdin-pipe  (make-uv-pipe loop))
   (define stdout-pipe (make-uv-pipe loop))
   (define out (make-byte-collector))
   (define exit-result 'not-yet)
   (define eof 'not-yet)
   (define payload (seeded-bytes 4096 42))
   (define proc
     (uv-spawn! loop "/bin/cat" '("cat")
                (list (cons 'stdio (list (list 'pipe stdin-pipe 'to-child)
                                         (list 'pipe stdout-pipe 'from-child))))
                (lambda (s g) (collect) (set! exit-result (list s g)))))
   (test-assert "both pipes are connected after the spawn"
     (and (pipe-connected? stdin-pipe) (pipe-connected? stdout-pipe)))
   (uv-read-start! stdout-pipe
                   (lambda (bv s e) (collect) (collect-span! out bv s e))
                   (lambda () (set! eof 'eof))
                   (lambda (err) (set! eof (list 'error err))))
   (uv-write! stdin-pipe payload
              (lambda (err) (collect)
                (when (not err)
                  (uv-shutdown! stdin-pipe (lambda (err2) #f)))))
   ;; EOF and exit are waited for INDEPENDENTLY — both orders are legal
   ;; (V5, SQ3's measured evidence). Neither wait implies the other.
   (test-equal "all bytes echo back and EOF arrives"
     'satisfied (run-until/ticking
                 loop (lambda () (and (= 4096 (collector-count out))
                                      (eq? eof 'eof))) 8192))
   (test-equal "the child exits (0 #f) after its stdin closed"
     'satisfied (run-until/ticking loop (lambda () (pair? exit-result)) 8192))
   (test-equal "clean exit" '(0 #f) exit-result)
   (test-assert "payload survived byte-for-byte"
     (bytevector=? payload (collector-bytes out)))
   ;; pipe-already-used: a consumed pipe refuses a second spawn (§4.3).
   (test-assert "a connected pipe refuses reuse"
     (guard (e ((uv-invalid-argument? e)
                (eq? 'pipe-already-used (uv-invalid-argument-reason e))))
       (uv-spawn! loop "/bin/cat" '("cat")
                  (list (cons 'stdio (list (list 'pipe stdin-pipe 'to-child))))
                  #f)
       #f))
   (uv-close! proc)
   (uv-close! stdin-pipe)
   (uv-close! stdout-pipe)
   (run-until loop (lambda () (eq? 'closed (uv-handle-state stdout-pipe))) 128)))
   ;; teardown at with-loop exit; the suite-end counter rows discharge
   ;; Task 5's forward obligation: the pipes' read buffer freed via the
   ;; STREAM arm of the close dispatcher.

;; --- pipe-wrong-loop (§4.3) ----------------------------------------------
(with-loop
 (lambda (loop)
   (let* ((other (make-uv-loop))
          (foreign-pipe (make-uv-pipe other)))
     (test-assert "a pipe from another loop is refused by name"
       (guard (e ((uv-invalid-argument? e)
                  (eq? 'pipe-wrong-loop (uv-invalid-argument-reason e))))
         (uv-spawn! loop "/bin/cat" '("cat")
                    (list (cons 'stdio (list (list 'pipe foreign-pipe 'to-child))))
                    #f)
         #f))
     (uv-loop-teardown! other))))

;; --- duplex (§9.2: sole coverage of the OR'd direction bits) -------------
(with-loop
 (lambda (loop)
   (define duplex-pipe (make-uv-pipe loop))
   (define out (make-byte-collector))
   (define exit-result 'not-yet)
   (define eof 'not-yet)
   ;; The child reads fd 0 and writes fd 0 — a socketpair end is
   ;; bidirectional (V3): cat's stdout is redirected back onto fd 0.
   (define proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "/bin/cat >&0")
                (list (cons 'stdio (list (list 'pipe duplex-pipe 'duplex))))
                (lambda (s g) (collect) (set! exit-result (list s g)))))
   (uv-read-start! duplex-pipe
                   (lambda (bv s e) (collect) (collect-span! out bv s e))
                   (lambda () (set! eof 'eof))
                   (lambda (err) (set! eof (list 'error err))))
   (uv-write! duplex-pipe (string->utf8 "ping-pong")
              (lambda (err) (when (not err)
                              (uv-shutdown! duplex-pipe (lambda (e2) #f)))))
   (test-equal "duplex round-trip delivers"
     'satisfied (run-until/ticking
                 loop (lambda () (= 9 (collector-count out))) 8192))
   (test-equal "duplex payload intact" "ping-pong"
     (utf8->string (collector-bytes out)))
   (run-until/ticking loop (lambda () (pair? exit-result)) 8192)
   (uv-close! proc) (uv-close! duplex-pipe)
   (run-until loop (lambda () (eq? 'closed (uv-handle-state duplex-pipe))) 128)))

;; --- extra fd, slot 3 (§9.2: >3-slot stdio + libuv's own 0-2 padding) ----
(with-loop
 (lambda (loop)
   (define fd3-pipe (make-uv-pipe loop))
   (define out (make-byte-collector))
   (define eof 'not-yet)
   (define exit-result 'not-yet)
   (define proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "printf x >&3")
                (list (cons 'stdio (list 'ignore 'ignore 'ignore
                                         (list 'pipe fd3-pipe 'from-child))))
                (lambda (s g) (collect) (set! exit-result (list s g)))))
   (uv-read-start! fd3-pipe
                   (lambda (bv s e) (collect-span! out bv s e))
                   (lambda () (set! eof 'eof))
                   (lambda (err) (set! eof (list 'error err))))
   (test-equal "the byte crosses fd 3"
     'satisfied (run-until/ticking
                 loop (lambda () (= 1 (collector-count out))) 4096))
   (test-equal "x" (utf8->string (collector-bytes out)))
   (run-until/ticking loop (lambda () (pair? exit-result)) 4096)
   (uv-close! proc) (uv-close! fd3-pipe)
   (run-until loop (lambda () (eq? 'closed (uv-handle-state fd3-pipe))) 128)))

;; --- inherit-fd (§9.2: child writes an inherited temp-file fd) -----------
(with-loop
 (lambda (loop)
   (define path "tests/tmp/inherit-fd-probe.txt")
   (when (file-exists? path) (delete-file path))
   (define port (open-file-output-port path))
   (define fd (port-file-descriptor port))
   (define exit-result 'not-yet)
   (define proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "printf inherited >&1")
                (list (cons 'stdio (list 'ignore (cons 'inherit-fd fd))))
                (lambda (s g) (collect) (set! exit-result (list s g)))))
   (test-equal "child exits"
     'satisfied (run-until/ticking loop (lambda () (pair? exit-result)) 4096))
   (close-port port)
   (test-equal "the inherited fd carried the bytes into the file"
     "inherited"
     (call-with-port (open-input-file path) get-string-all))
   (delete-file path)
   (uv-close! proc)
   (run-until loop (lambda () (eq? 'closed (uv-handle-state proc))) 64)))

;; --- inherit-stream (§9.2: sole coverage; loopback TCP, ADR-0010) --------
(with-loop
 (lambda (loop)
   (define server (make-uv-tcp loop))
   (define port-num (bind-loopback! server))
   (define client (make-uv-tcp loop))
   (define accepted 'not-yet)
   (uv-listen! server 8 (lambda (err)
                          (when (not err)
                            (set! accepted (uv-accept! server)))))
   (define connected 'not-yet)
   (connect-loopback! client port-num (lambda (err) (set! connected (or err 'ok))))
   (run-until/ticking loop (lambda () (and (uv-tcp? accepted)
                                           (eq? 'ok connected))) 2048)
   ;; Child stdout dups onto the ACCEPTED socket; parent reads the CLIENT.
   (define out (make-byte-collector))
   (define eof 'not-yet)
   (define exit-result 'not-yet)
   (define proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "printf over-the-socket")
                (list (cons 'stdio (list 'ignore (cons 'inherit-stream accepted))))
                (lambda (s g) (collect) (set! exit-result (list s g)))))
   (uv-read-start! client
                   (lambda (bv s e) (collect) (collect-span! out bv s e))
                   (lambda () (set! eof 'eof))
                   (lambda (err) (set! eof (list 'error err))))
   (test-equal "the bytes crossed the inherited socket"
     'satisfied (run-until/ticking
                 loop (lambda () (= 15 (collector-count out))) 4096))
   (test-equal "over-the-socket" (utf8->string (collector-bytes out)))
   (run-until/ticking loop (lambda () (pair? exit-result)) 4096)
   (uv-close! proc)))
   ;; server/client/accepted swept by teardown — also an assertion.
```

Adjust `get-string-all`: import `(only (chezscheme) ... get-string-all open-file-output-port port-file-descriptor)` — check availability with `rg`/REPL; `open-file-output-port` is (rnrs io ports) with a file-options argument on existing files, hence the delete-first. If `port-file-descriptor` needs an unbuffered port, pass `(buffer-mode none)`.

- [ ] **Step 2: Run to observe failures/passes**

```bash
make test 2>&1 | grep -B2 -A6 "test-process"
```
Expected: rows fail only if Task 8's implementation has a defect (direction bits swapped, container union written at the wrong width). Fix production inline; every fix gets a one-line note in the log.

- [ ] **Step 3: Full suite + memory lane**

```bash
make test && make test-memory
```
Expected: ALL SUITES PASSED both. test-memory on macOS = ASan (no leak claim); the Linux valgrind verdict comes from CI on push.

- [ ] **Step 4: Mutation log**

`.plans/process-stage-5-mutation-log.md` (append): probe — swap `to-child`/`from-child` bit mapping in `stdio-spec-flags`: echo scenario fails (record); revert. Probe — write the container fd via `c-uptr-set!` instead of `c-int-set!`: inherit-fd scenario fails on LP64 only if garbage lands in the union high bytes — record the actual observation honestly, both if it fails and if it passes (V2's union layout makes this platform-shaped). Revert.

- [ ] **Step 5: Commit**

```bash
git add tests/test-process.sps .plans/process-stage-5-mutation-log.md
git commit -m "test: stdio scenarios — echo, duplex, extra fd, inherit-fd, inherit-stream, pipe reuse/wrong-loop"
```

---

### Task 10: kill family, pid, detached, lifecycle

**Files:**
- Modify: `src/libuv/process.sls` (add the three verbs + accessor), `tests/test-process.sps`, `tests/test-stream.sps` (the refuses-process row), `.plans/2026-08-21-chez-libuv-v0.3-process-design.md` (one-line spec amendment)

**Interfaces:**
- Consumes: Task 4's `uv-process-kill`/`uv-kill`/`uv-process-get-pid` natives; Task 8's `require-open-process`/`signal-symbol->int`.
- Produces (public): `(uv-process-kill! proc sig)`, `(uv-kill! pid sig)`, `(uv-process-pid proc) → exact integer`. `sig`: closed symbol set or exact `0`. New reason symbol `'pid-not-an-exact-integer` (spec §4.7 table gains this row — Step 4).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test-process.sps`:

```scheme
;; --- kill by handle: deterministic blocked child (§9.2) ------------------
(with-loop
 (lambda (loop)
   (define stdin-pipe (make-uv-pipe loop))
   (define exit-result 'not-yet)
   (define proc
     (uv-spawn! loop "/bin/cat" '("cat")
                (list (cons 'stdio (list (list 'pipe stdin-pipe 'to-child))))
                (lambda (s g) (collect) (set! exit-result (list s g)))))
   (test-assert "pid is a positive exact integer while the child runs"
     (let ((pid (uv-process-pid proc)))
       (and (integer? pid) (exact? pid) (positive? pid))))
   (test-assert "liveness probe 0 returns without raising while blocked"
     (begin (uv-process-kill! proc 0) #t))
   (uv-process-kill! proc 'sigterm)
   (test-equal "sigterm death delivers (0 sigterm) — V5's shape"
     'satisfied (run-until/ticking loop (lambda () (pair? exit-result)) 4096))
   (test-equal '(0 sigterm) exit-result)
   (test-assert "pid still readable between exit and close (§4.5)"
     (positive? (uv-process-pid proc)))
   (uv-close! proc) (uv-close! stdin-pipe)
   (run-until loop (lambda () (eq? 'closed (uv-handle-state proc))) 128)))

;; --- kill by raw pid ------------------------------------------------------
(with-loop
 (lambda (loop)
   (define stdin-pipe (make-uv-pipe loop))
   (define exit-result 'not-yet)
   (define proc
     (uv-spawn! loop "/bin/cat" '("cat")
                (list (cons 'stdio (list (list 'pipe stdin-pipe 'to-child))))
                (lambda (s g) (collect) (set! exit-result (list s g)))))
   (uv-kill! (uv-process-pid proc) 'sigkill)
   (run-until/ticking loop (lambda () (pair? exit-result)) 4096)
   (test-equal "sigkill by pid delivers (0 sigkill)" '(0 sigkill) exit-result)
   (uv-close! proc) (uv-close! stdin-pipe)
   (run-until loop (lambda () (eq? 'closed (uv-handle-state proc))) 128)))

;; --- signal vocabulary refusals ------------------------------------------
(with-loop
 (lambda (loop)
   (define stdin-pipe (make-uv-pipe loop))
   (define proc
     (uv-spawn! loop "/bin/cat" '("cat")
                (list (cons 'stdio (list (list 'pipe stdin-pipe 'to-child)))) #f))
   (define (reason-of thunk)
     (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
       (thunk) 'no-raise))
   (test-equal 'signal-unknown
     (reason-of (lambda () (uv-process-kill! proc 'sigfoo))))
   (test-equal 'signal-unknown
     (reason-of (lambda () (uv-process-kill! proc 15))))  ;; ints other than 0: symbols only
   (test-equal 'signal-unknown
     (reason-of (lambda () (uv-kill! 99999999 'sigfoo)))) ;; validated BEFORE the errno path
   (test-equal 'pid-not-an-exact-integer
     (reason-of (lambda () (uv-kill! "42" 'sigterm))))
   (test-assert "uv-kill! on a vanished pid raises an errno symbol"
     (guard (e ((uv-errno-error? e)
                ;; ESRCH normally; EPERM if the pid was recycled to another
                ;; user's process — both prove the errno path.
                (memq (uv-errno-error-errno e) '(ESRCH EPERM))))
       (uv-kill! 99999999 0) #f))
   (uv-process-kill! proc 'sigkill)
   (run-until/ticking loop (lambda () (process-exited? proc)) 4096)
   (uv-close! proc) (uv-close! stdin-pipe)
   (run-until loop (lambda () (eq? 'closed (uv-handle-state proc))) 128)))

;; --- detached (§9.2: no-hang + counters only; never reaped) --------------
(with-loop
 (lambda (loop)
   (define proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 0")
                (list (cons 'detached #t)) #f))
   (uv-close! proc)
   (test-equal "loop drains without waiting on the detached child"
     'satisfied (run-until loop
                           (lambda () (eq? 'closed (uv-handle-state proc)))
                           128))
   (test-equal "process counter balanced" 0 (live-count 'process))))

;; --- lifecycle: close from inside on-exit / teardown sweep / seam --------
(with-loop
 (lambda (loop)
   (define states 'not-yet)
   (define proc 'not-yet)
   (set! proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 3")
                (lambda (s g)
                  (collect)
                  ;; close from INSIDE on-exit — the documented pattern (§6)
                  (uv-close! proc (lambda () (set! states 'closed-from-exit))))))
   (test-equal "close-from-on-exit completes"
     'satisfied (run-until/ticking loop
                                   (lambda () (eq? states 'closed-from-exit))
                                   4096))))

(with-loop
 (lambda (loop)
   ;; spawn, wait for silent reap, never close: the TEARDOWN SWEEP owns it.
   (define proc (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 0") #f))
   (run-until/ticking loop (lambda () (process-exited? proc)) 4096)))
   ;; with-loop tears down; the suite-end counter/registry rows assert the
   ;; sweep closed it (Task 5's handle-kinds forward obligation).

(with-loop
 (lambda (loop)
   ;; a raise inside on-exit is stored and re-raised by uv-run (S8 seam).
   (define-condition-type &exit-probe &error make-exit-probe exit-probe?)
   (define proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "exit 0")
                (lambda (s g) (raise (make-exit-probe)))))
   (test-assert "the exit callback's raise surfaces as &uv-callback-error wrapping the probe"
     (guard (e (#t (and (uv-callback-error? e) (exit-probe? e))))
       (let drain ((i 0))
         (uv-run loop 'once)
         (if (< i 2048) (drain (+ i 1)) 'never-raised))))
   (uv-close! proc)
   (run-until loop (lambda () (eq? 'closed (uv-handle-state proc))) 128)))
```

And in `tests/test-stream.sps`, insert BEFORE its `(uv-loop-teardown! loop)` / counter-balance block (never after `test-end`/`exit` — rows there would silently not run; needs `(libuv process)` added to that suite's imports):

```scheme
;; --- the refuses-process row (deferred here from Task 7) -----------------
(define loop2 (make-uv-loop))
(define proc (uv-spawn! loop2 "/bin/sh" '("sh" "-c" "exit 0") #f))
(test-assert "uv-write! refuses a process handle"
  (guard (e (#t (and (uv-invalid-argument? e)
                     (eq? 'not-a-uv-stream (uv-invalid-argument-reason e)))))
    (uv-write! proc (make-bytevector 1 0) (lambda (err) #f)) #f))
(uv-loop-teardown! loop2)
```

Also append the raw-signal passthrough row to `tests/test-process.sps` (§4.4: a death signal OUTSIDE the bound set is delivered as the raw int — the child kills itself with SIGPIPE, which v0.3 does not bind):

```scheme
;; --- term-signal outside the bound set passes through RAW (§4.4) ---------
(with-loop
 (lambda (loop)
   (define exit-result 'not-yet)
   (define proc
     (uv-spawn! loop "/bin/sh" '("sh" "-c" "kill -PIPE $$")
                (lambda (s g) (collect) (set! exit-result (list s g)))))
   (run-until/ticking loop (lambda () (pair? exit-result)) 4096)
   (test-assert "unbound death signal arrives as its raw exact integer"
     (and (= 0 (car exit-result))
          (integer? (cadr exit-result))
          (exact? (cadr exit-result))
          (positive? (cadr exit-result))))
   (uv-close! proc)
   (run-until loop (lambda () (eq? 'closed (uv-handle-state proc))) 128)))
```

- [ ] **Step 2: Run to verify the new rows fail**

```bash
make test 2>&1 | grep -A4 "test-process\|test-stream"
```
Expected: unbound `uv-process-kill!`/`uv-process-pid`/`uv-kill!` (compile failure of the suite = the failing state).

- [ ] **Step 3: Implement the verbs in process.sls**

Add to the export list `uv-process-kill! uv-kill! uv-process-pid`, and the bodies:

```scheme
  ;; --- signals (§4.5, ADR-0016) --------------------------------------------
  ;; A closed symbol set, values from the shim (ADR-0005: SIGTERM's number
  ;; is never written here), plus exact 0 — the POSIX liveness probe
  ;; (kill(pid,0), V9). Symbols only otherwise: 15 is refused even though
  ;; it is SIGTERM everywhere, because "everywhere" is how transcription
  ;; bugs start. Lifts to (libuv private native) on its second user
  ;; (the PR #4 rule) — today process.sls is the only one.
  (define (signal-symbol->int sig who)
    (cond
      ((eqv? sig 0) 0)
      ((symbol? sig)
       (case sig
         ((sigterm) (sig-term)) ((sigkill) (sig-kill)) ((sigint) (sig-int))
         ((sighup) (sig-hup)) ((sigquit) (sig-quit))
         ((sigusr1) (sig-usr1)) ((sigusr2) (sig-usr2))
         ((sigcont) (sig-cont)) ((sigstop) (sig-stop))
         (else (raise (make-uv-invalid-argument who 'signal-unknown)))))
      (else (raise (make-uv-invalid-argument who 'signal-unknown)))))

  ;; (uv-process-kill! proc sig) — by handle. On Unix this is literally
  ;; uv_kill(handle->pid, sig) (V9). Success returns unspecified; failure
  ;; raises the errno symbol ('ESRCH after reaping — see the pid-validity
  ;; header note).
  (define (uv-process-kill! proc sig)
    (require-open-process proc 'uv-process-kill!)
    (let ((signum (signal-symbol->int sig 'uv-process-kill!)))
      (uv-check (uv-process-kill (handle-pointer proc 'uv-process-kill!)
                                 signum)
                'uv-process-kill!)))

  ;; (uv-kill! pid sig) — by raw pid; the escape hatch for pids learned
  ;; elsewhere. The pid is validated as an exact integer (the FFI declares
  ;; int; an inexact or non-number would be a marshalling crash) but NOT
  ;; range-policed: negative pids are kill(2)'s process-group vocabulary,
  ;; passed through — the mirror rule.
  (define (uv-kill! pid sig)
    (unless (and (integer? pid) (exact? pid))
      (raise (make-uv-invalid-argument 'uv-kill! 'pid-not-an-exact-integer)))
    (let ((signum (signal-symbol->int sig 'uv-kill!)))
      (uv-check (uv-kill pid signum) 'uv-kill!)))

  ;; (uv-process-pid proc) — valid between spawn and close, exit included
  ;; (§4.5): the handle memory holds the pid until the close dispatcher
  ;; frees it, and require-open-process is what enforces the window.
  (define (uv-process-pid proc)
    (require-open-process proc 'uv-process-pid)
    (uv-process-get-pid (handle-pointer proc 'uv-process-pid)))
```

- [ ] **Step 4: Amend the spec's §4.7 table**

Add one row to `.plans/2026-08-21-chez-libuv-v0.3-process-design.md`'s reason-symbol table:

```markdown
| `'pid-not-an-exact-integer` | `uv-kill!` given a non-exact-integer pid |
```

(The table promised closure; the implementation found one genuinely missing row. Amending the spec beats an undocumented symbol.)

- [ ] **Step 5: Run tests to verify pass**

```bash
make test
```
Expected: ALL SUITES PASSED.

- [ ] **Step 6: Commit**

```bash
git add src/libuv/process.sls tests/test-process.sps tests/test-stream.sps .plans/2026-08-21-chez-libuv-v0.3-process-design.md
git commit -m "feat: uv-process-kill!/uv-kill!/uv-process-pid + detached and lifecycle coverage"
```

---

### Task 11: Facade + facade tests

**Files:**
- Modify: `src/libuv.sls`, `tests/test-facade.sps`

**Interfaces:**
- Consumes: every public name Tasks 6–10 produced.
- Produces: `(libuv)` re-exports — the only import a consumer needs.

- [ ] **Step 1: Extend test-facade.sps (failing first)**

Follow the suite's existing shape (`rg -n "test-facade" -A5 tests/test-facade.sps` to see how it asserts exports — it imports `(libuv)` and touches each name). Add rows touching: `make-uv-pipe`, `uv-pipe?`, `uv-process?`, `uv-spawn!`, `uv-process-kill!`, `uv-kill!`, `uv-process-pid` — e.g. `(test-assert "uv-spawn! is exported" (procedure? uv-spawn!))` per name, plus one end-to-end smoke row (spawn `sh -c 'exit 5'` through facade names only, assert `(5 #f)`).

- [ ] **Step 2: Run to verify failure**

```bash
make test 2>&1 | grep -A3 "test-facade"
```
Expected: FAIL — names not exported from `(libuv)`.

- [ ] **Step 3: Implement**

`src/libuv.sls`: add `(libuv stream)`, `(libuv pipe)`, `(libuv process)` to the import form. In the export list: add `uv-pipe? uv-process?` to the handle block (with a comment line noting they live in `(libuv handle)` beside `uv-tcp?`); change the TCP block comment to note the four stream verbs now originate in `(libuv stream)` (names unchanged); add:

```scheme
          ;; --- Pipe, from (libuv pipe) ---
          ;; Minimal by design (v0.3): a pipe exists to be consumed by
          ;; uv-spawn!'s (pipe p dir) stdio spec. Stream verbs above accept
          ;; it once connected; uv-close! is the generic one.
          make-uv-pipe

          ;; --- Process, from (libuv process) ---
          ;; uv-spawn! options/stdio vocabulary: THE SPEC §4.2-§4.3.
          ;; EXIT IS NOT CLOSE: on-exit fires, the handle still needs
          ;; uv-close! (ADR-0007). Killed-by-signal arrives as (0 'sig...).
          uv-spawn! uv-process-kill! uv-kill! uv-process-pid
```

- [ ] **Step 4: Run tests to verify pass**

```bash
make test
```
Expected: ALL SUITES PASSED.

- [ ] **Step 5: Commit**

```bash
git add src/libuv.sls tests/test-facade.sps
git commit -m "feat: facade re-exports for stream/pipe/process"
```

---

### Task 12: The root lane — setuid/setgid suite, Makefile, CI

**Files:**
- Create: `tests/test-process-setuid.sps`
- Modify: `Makefile` (lines 90-91 area + a new target + .PHONY), `.github/workflows/ci.yml` (one step per job)

**Interfaces:**
- Consumes: the full `(libuv process)` surface. The suite uses `uv-spawn!` ITSELF (with a from-child pipe running `/usr/bin/id`) for both the root check and the assertions — no second subprocess mechanism.
- Produces: `make test-root` (refuses non-root, exit 1); the suite excluded from `TESTS`/`MEMORY_TESTS`; CI runs it under sudo on both jobs.

- [ ] **Step 1: Write the suite**

`tests/test-process-setuid.sps`:

```scheme
#!r6rs
;;; ROOT LANE (THE SPEC §9.4, ADR-0016): the setuid/setgid POSITIVE tests.
;;; Excluded from the default TESTS list; run only via `sudo make
;;; test-root`. Refuses to run as non-root with a loud exit 1 — being
;;; skipped silently is how a lane dies. The 'EPERM NEGATIVE test lives in
;;; tests/test-process.sps, in the normal suite.
;;;
;;; The unprivileged target identity is looked up AT RUNTIME (`id -u
;;; nobody`) — never a transcribed uid (the ADR-0005 spirit applied to a
;;; test fixture). All child output crosses a from-child pipe; the runner
;;; is uv-spawn! itself, so the lane exercises the module under test even
;;; in its own plumbing.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv pipe)
        (libuv process)
        (libuv stream)
        (uv-testing)
        (only (chezscheme) collect))

(define runner (test-runner-simple))
(test-runner-current runner)

;; (run-capture loop file args options) → (exit-status . output-string)
;; Blocks via capped ticking until both exit and EOF arrive.
(define (run-capture loop file args extra-options)
  (let* ((out-pipe (make-uv-pipe loop))
         (out (make-byte-collector))
         (exit-status 'not-yet)
         (eof 'not-yet)
         (options (cons (cons 'stdio (list 'ignore
                                           (list 'pipe out-pipe 'from-child)))
                        extra-options))
         (proc (uv-spawn! loop file args options
                          (lambda (s g) (collect) (set! exit-status s)))))
    (uv-read-start! out-pipe
                    (lambda (bv s e) (collect) (collect-span! out bv s e))
                    (lambda () (set! eof 'eof))
                    (lambda (err) (set! eof 'error)))
    (run-until/ticking loop
                       (lambda () (and (number? exit-status) (eq? eof 'eof)))
                       8192)
    (uv-close! proc)
    (uv-close! out-pipe)
    (run-until loop (lambda () (and (eq? 'closed (uv-handle-state proc))
                                    (eq? 'closed (uv-handle-state out-pipe))))
               128)
    (cons exit-status (utf8->string (collector-bytes out)))))

(define (trim s)  ;; strip the trailing newline id(1) prints
  (let loop ((end (string-length s)))
    (if (and (positive? end)
             (memv (string-ref s (- end 1)) '(#\newline #\return)))
        (loop (- end 1))
        (substring s 0 end))))

(define gate-loop (make-uv-loop))

;; --- the root gate -------------------------------------------------------
(define my-uid (trim (cdr (run-capture gate-loop "/usr/bin/id" '("id" "-u") '()))))
(unless (string=? "0" my-uid)
  (display "test-process-setuid: refusing to run: euid is ")
  (display my-uid)
  (display " — run via `sudo make test-root`\n")
  (exit 1))

;; --- the unprivileged target, looked up at runtime -----------------------
(define nobody-uid
  (trim (cdr (run-capture gate-loop "/usr/bin/id" '("id" "-u" "nobody") '()))))
(define nobody-gid
  (trim (cdr (run-capture gate-loop "/usr/bin/id" '("id" "-g" "nobody") '()))))
(uv-loop-teardown! gate-loop)

(test-begin "process-setuid")

(let ((loop (make-uv-loop)))
  (let ((r (run-capture loop "/usr/bin/id" '("id" "-u")
                        (list (cons 'uid (string->number nobody-uid))))))
    (test-equal "child ran as the requested uid" (cons 0 nobody-uid)
      (cons (car r) (trim (cdr r)))))
  (let ((r (run-capture loop "/usr/bin/id" '("id" "-g")
                        (list (cons 'uid (string->number nobody-uid))
                              (cons 'gid (string->number nobody-gid))))))
    (test-equal "child ran as the requested gid" (cons 0 nobody-gid)
      (cons (car r) (trim (cdr r)))))
  (uv-loop-teardown! loop))

(test-end "process-setuid")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
```

- [ ] **Step 2: Makefile — exclude from TESTS, add the target**

Line 90-91, change:

```make
TESTS        := $(filter-out $(ROOT_TESTS),$(wildcard tests/test-*.sps))
MEMORY_TESTS := $(TESTS)
```

and just above them:

```make
# The root lane (design spec v0.3 §9.4): privileged-but-deterministic
# setuid/setgid tests, run ONLY by an explicit `sudo make test-root` —
# never by the default suite, never under the memory gate. The filter-out
# below is what keeps a `tests/test-*.sps` wildcard from silently running
# it unprivileged (where it would loudly exit 1 and fail `make test`).
ROOT_TESTS   := tests/test-process-setuid.sps
```

New target after `test:` (keeping the `## ` help discipline), and `test-root` added to the `.PHONY` line:

```make
# Refusal is the SUITE's job (it checks euid itself and exits 1 with a
# message), so a bare `make test-root` fails loudly rather than skipping.
test-root: build deps check-pins ## Run the root-gated setuid/setgid suite (needs sudo)
	@for t in $(ROOT_TESTS); do \
	  echo "=== $$t (root lane) ==="; \
	  CHEZSCHEMELIBDIRS=$(CHEZ_LIBDIRS) $(CHEZ) --program $$t || exit 1; \
	done; \
	echo "ROOT LANE PASSED"
```

- [ ] **Step 3: Verify the refusal and the exclusion locally**

```bash
make test-root
```
Expected: `refusing to run: euid is 501` (your uid) and exit 1.

```bash
make test
```
Expected: ALL SUITES PASSED and `test-process-setuid` does NOT appear in the output (the filter-out worked).

```bash
sudo make test-root
```
Expected: `ROOT LANE PASSED` (macOS: `nobody` exists; both rows green). If sudo resets PATH such that the pinned chez is missing, use `sudo env "PATH=$PATH" make test-root` and note it in the README line Task 13 adds.

- [ ] **Step 4: CI steps**

`.github/workflows/ci.yml` — linux job, after the `Test (vendored path)` step (line ~182):

```yaml
      - name: Root lane (setuid/setgid, sudo)
        run: sudo -E env "PATH=$PATH" make HAVE_PKG=no test-root
```

macos job, after the `Build and test (vendored path)` step:

```yaml
      - name: Root lane (setuid/setgid, sudo)
        run: sudo -E env "PATH=$PATH" make HAVE_PKG=no test-root
```

(`-E env "PATH=$PATH"` because the pinned/homebrew Chez lives on the runner user's PATH, which plain sudo drops. `HAVE_PKG=no` matches the preceding vendored-path build so `test-root`'s `build deps` prerequisites re-resolve identically instead of relinking the other flavor.)

- [ ] **Step 5: Commit and verify on CI**

```bash
git add tests/test-process-setuid.sps Makefile .github/workflows/ci.yml
git commit -m "feat: root lane — setuid/setgid suite, make test-root, sudo CI steps"
git push -u origin feat/v0.3-process
```

Watch the run: `gh run watch` — both jobs' root-lane steps must be green (a red `nobody`-lookup on ubuntu means the user is spelled differently there — it is not; ubuntu has `nobody` — investigate before touching the suite).

---

### Task 13: Docs, changelog, spec acceptance, closing

**Files:**
- Modify: `README.org`, `CHANGELOG.md`, `.plans/2026-08-21-chez-libuv-v0.3-process-design.md` (Status line)

- [ ] **Step 1: README.org**

- The "legible mirror" sentence gains processes and pipes: "...event loop, TCP sockets, timers, DNS, child processes and their stdio pipes...".
- Status section: "No processes, ..." becomes "No filesystem, no UDP, no zero-copy I/O, no uv_signal_t (signal *sending* ships with the process module; handling is a recorded future milestone)".
- New short section under the API overview: the spawn surface (the §4.1-§4.5 signatures in brief), the EXIT ≠ CLOSE contract, the (0 sigterm) shape, the pid-validity-ends-at-exit warning, the detached pattern, and the root lane (`sudo make test-root`). If SQ2 found a Linux SIGCHLD conflict with Chez's own subprocess APIs, add the mutual-exclusion warning FINDINGS recorded (macOS unaffected).
- Condition table: no new types; note the new reason symbols live in spec §4.7.

- [ ] **Step 2: CHANGELOG.md**

Follow the v0.2 entry's format:

```markdown
## v0.3.0 — <date>

`(libuv process)`, `(libuv pipe)` (minimal), and the `(libuv stream)`
extraction. uv_spawn with the full stdio vocabulary (ignore / inherit-fd /
inherit-stream / pipe with to-child/from-child/duplex), env/cwd, detached,
setuid/setgid behind an opt-in root lane (`sudo make test-root`);
uv-process-kill!/uv-kill! with a closed signal-symbol set; uv-process-pid.
Eleventh trampoline (exit). ADRs 0014-0016; ADR-0008 amended. Stream verbs
moved to (libuv stream) with gating widened tcp → stream ((libuv tcp)
re-exports them; no import changes needed).
```

- [ ] **Step 3: Flip the spec's Status line**

`- **Status:** Accepted (<date>) — Stage 0 spike complete (spike/process/FINDINGS.md); implemented on feat/v0.3-process` (mirroring the v0.2 doc's accepted form).

- [ ] **Step 4: Full verification**

```bash
make test && make test-memory && make check-purity && sudo make test-root
```
Expected: all green. `check-purity` unchanged (no new pure suites).

- [ ] **Step 5: Commit and hand off to review**

```bash
git add README.org CHANGELOG.md .plans/2026-08-21-chez-libuv-v0.3-process-design.md
git commit -m "docs: README/CHANGELOG for v0.3.0; accept the process design spec"
git push
```

Then the house closing sequence (NOT part of this plan's automation — each is its own gate): final whole-branch review (superpowers:requesting-code-review), fix findings, squash-merge PR titled `feat: chez-libuv v0.3 — process support ((libuv process), (libuv pipe), (libuv stream))`, tag `v0.3.0`, closing ritual per AGENTS.md (main caught up, branches deleted remote+local).

---

## Plan-wide notes for the executor

- **Task order is dependency order**; do not parallelize Tasks 3→8. Tasks 9/10 both append to test-process.sps — run them sequentially.
- **Spike evidence gates Task 8's failure path**: if FINDINGS is ambiguous on SQ1, stop and ask rather than picking a variant.
- **Any deviation from spec §4/§5 surfaces as a spec amendment in the same commit** (the Task 10 Step 4 pattern), never as silent drift.
- **The valgrind verdict is CI's** (linux job); local macOS `make test-memory` is ASan and cannot support a leak claim.
- Where a step says `rg` to find a site, the finding is part of the step — record surprising hits in the task's mutation log rather than improvising.




