# v0.5 Task 5 Mutation Log: overlapped-model comments + vendor tripwire

Covers the two Windows-overlapped-model comment sites in `src/libuv/stream.sls`
and `src/libuv/private/handles.sls`, and the new `UV_HANDLE_ZERO_READ` /
`read_buffer` tripwire appended to the `check-pins` recipe in `Makefile`.

**Process note.** Per the controller's explicit instruction for this task, the
Step 3 tripwire mutation was **NOT executed** by this agent. `vendor/libuv` is
a git submodule, which makes a stray edit even easier to leave behind than the
`src/` mutations Task 3/4 flagged twice. Everything under "Step 3 (predicted,
not executed)" below is a prediction against the tripwire's actual shell
logic, not a measurement. The controller runs it and records the verbatim
output.

## Discrepancy from the brief, found on inspection

The brief states `rg -n 'overlapped' src/libuv/` "returns exactly two hits."
Measured on this tree it returns **three**:

```
src/libuv/stream.sls:188:  ;; a read completion queued against it (Windows' overlapped model) cannot
src/libuv/stream.sls:227:  ;; incomplete overlapped send -- and the immediate-completion branch never
src/libuv/private/handles.sls:1001:  ;; earlier, because Windows' overlapped-read model can still reference it
```

`stream.sls:227` is not the close-only-free claim this task corrects — it's
part of the `uv-stream-write-queue-size` comment, describing Windows'
`write_queue_size` counting semantics (`win/tcp.c:986`, the
`UV_SUCCEEDED_WITH_IOCP` branch for outstanding *writes*), a separate and
factually distinct claim about a different code path. Only `stream.sls:188`
and `handles.sls:1001` carry "the identical claim" the brief describes
(close-only-free justified by an overlapped *read* completion outliving the
buffer), so those are the two sites corrected. Per instruction 4
("trust the source tree... find both sites yourself"), this is noted rather
than silently reconciled — a future task touching the write-queue-size
comment should not assume this task touched it.

## Step 1: comment corrections (both sites)

### `src/libuv/stream.sls` (was lines 187-189, now 188-189 after the earlier
tasks' shifts — matches instruction 4's warning not to trust brief line
numbers)

Before:
```scheme
  ;; different explicit size is REFUSED rather than honoured. Honouring it
  ;; would mean freeing the old buffer here, and design spec S6 makes the
  ;; close dispatcher the only place that buffer may ever be freed -- so that
  ;; a read completion queued against it (Windows' overlapped model) cannot
  ;; outlive it. A caller who wants a different size closes the handle.
```

After:
```scheme
  ;; different explicit size is REFUSED rather than honoured. Honouring it
  ;; would mean freeing the old buffer here, and design spec S6 makes the
  ;; close dispatcher the only place that buffer may ever be freed -- so that
  ;; nothing on a path libuv can call into ever has to allocate. THAT is the
  ;; reason, and it is portable: alloc-dispatch is required to be infallible
  ;; (handles.sls:846-858), and a realloc reachable from a uv-read-start!
  ;; issued inside on-data would break the invariant on every platform.
  ;;
  ;; This comment used to say the reason was Windows' overlapped-read model
  ;; keeping a completion queued against the buffer. For the two handle kinds
  ;; this binding supports, that is DEAD CODE at the pinned libuv: uv_tcp_t
  ;; never posts a user buffer at all (win/tcp.c:559 queues a zero-byte
  ;; WSARecv against static uv_zero_; the real read at :1100 is
  ;; non-overlapped), and uv_pipe_t drains its overlapped ReadFile with
  ;; CancelIoEx + a blocking GetOverlappedResult before returning
  ;; (win/pipe.c:2000-2013). The residue: pipe.c:2006 checks CancelIoEx only
  ;; through an assert that release builds compile out. `make check-pins`
  ;; carries a tripwire over these vendor facts.
  ;;
  ;; A caller who wants a different size closes the handle.
```

### `src/libuv/private/handles.sls` (was line 1001, now 1001 unchanged —
Task 5 is the first to touch this comment)

Before:
```scheme
  ;; Step 2 of the close order above. Design spec S6: the per-handle read
  ;; buffer "is freed in exactly one place: the close dispatcher, never
  ;; earlier, because Windows' overlapped-read model can still reference it
  ;; after a read completion is queued but before the handle has fully
  ;; stopped". A handle that never called uv-read-start! has 0 here, and
  ;; free! refuses 0 by design -- so the test is on the pointer, not on the
  ;; handle type.
```

After:
```scheme
  ;; Step 2 of the close order above. Design spec S6: the per-handle read
  ;; buffer is freed in exactly one place -- the close dispatcher, never
  ;; earlier -- so that nothing on a path libuv can call into ever has to
  ;; allocate. THAT is the reason, and it is portable: alloc-dispatch is
  ;; required to be infallible (handles.sls:846-858), and a realloc reachable
  ;; from a uv-read-start! issued inside on-data would break the invariant on
  ;; every platform.
  ;;
  ;; This comment used to say the reason was Windows' overlapped-read model
  ;; keeping a completion queued against the buffer. For the two handle kinds
  ;; this binding supports, that is DEAD CODE at the pinned libuv: uv_tcp_t
  ;; never posts a user buffer at all (win/tcp.c:559 queues a zero-byte
  ;; WSARecv against static uv_zero_; the real read at :1100 is
  ;; non-overlapped), and uv_pipe_t drains its overlapped ReadFile with
  ;; CancelIoEx + a blocking GetOverlappedResult before returning
  ;; (win/pipe.c:2000-2013). The residue: pipe.c:2006 checks CancelIoEx only
  ;; through an assert that release builds compile out. `make check-pins`
  ;; carries a tripwire over these vendor facts.
  ;;
  ;; A handle that never called uv-read-start! has 0 here, and free! refuses
  ;; 0 by design -- so the test is on the pointer, not on the handle type.
```

## Step 2: tripwire — counts measured against the pinned vendor tree

Measured directly against `vendor/libuv` (pinned at v1.52.1, submodule
`1cfa32f`) before writing the check, per instruction 6:

```
$ grep -rn 'UV_HANDLE_ZERO_READ' vendor/libuv/src
vendor/libuv/src/uv-common.h:102:  UV_HANDLE_ZERO_READ  = 0x00040000,   (enum def, not a set/clear)
vendor/libuv/src/win/udp.c:280:  handle->flags |= UV_HANDLE_ZERO_READ;
vendor/libuv/src/win/udp.c:422,430,438:  (reads only, & test / ternary)
vendor/libuv/src/win/tcp.c:559:  handle->flags |= UV_HANDLE_ZERO_READ;
vendor/libuv/src/win/tcp.c:1051,1054,1071:  (reads only, & test / ternary)
```

- `|=` (set) count: **2** — `win/tcp.c:559`, `win/udp.c:280`.
- `&= *~` (clear) count: **0** — grepped, no matches anywhere in the tree.
- `read_buffer *=` (assignment) count, excluding `read_buffer ==`: **0** —
  the only occurrences of `read_buffer` outside the `win.h:444` struct-field
  declaration are at `win/tcp.c:1055` (ternary read), `:1077` (`&...read_buffer`
  passed by address to the OS read call — no `=` token adjacent to
  `read_buffer`, so this correctly does not match the assignment pattern),
  and `:1091` (read, passed to `read_cb`). None is `read_buffer = ...`.

These match the brief's stated expectation (2 / 0 / 0) exactly — the brief's
"earlier draft asserted one" warning (instruction 6) did not materialize as a
discrepancy in the current tripwire text, which already said 2.

Appended to the `check-pins` recipe in `Makefile` (verbatim from the brief,
confirmed to reproduce the measured counts — see "Step 2: make check-pins
output" below), and the target's `## ` description at (now) `Makefile:195`
updated from:

```
check-pins: ## Verify chez-srfi/Akku.lock pins, vendored libuv range, README floor, and manifest/CHANGELOG version agree
```

to:

```
check-pins: ## Verify chez-srfi/Akku.lock pins, vendored libuv range, README floor, manifest/CHANGELOG version, and vendor read-path facts agree
```

so `make check-help` (which fails on any undocumented `.PHONY` target) stays
green.

## Step 3 (predicted, not executed): watch the tripwire fail

Per protocol, this agent did **not** run the brief's Step 3 mutation
(`vendor/libuv/src/win/tcp.c` submodule edit). The prediction below follows
mechanically from the tripwire shell above and is unverified until the
controller runs it.

**Mutation to apply** (brief's exact text):
```bash
printf '\nvoid drift(uv_tcp_t*h){h->flags |= UV_HANDLE_ZERO_READ;}\n' >> vendor/libuv/src/win/tcp.c
make check-pins; echo "exit=$?"
```

**Predicted effect on the counts:** the appended line adds one more `|=`
match against `UV_HANDLE_ZERO_READ` inside `$(VENDOR_DIR)/src` (now three:
the two pre-existing real assignments plus this synthetic one in
`win/tcp.c`), while `zc` and `rb` are untouched by this specific mutation
(the injected function only sets the flag, never clears it, and never
touches `read_buffer`). So `zr=3`, `zc=0`, `rb=0`; the `if` guard trips on
`zr != 2` alone.

**Predicted stderr:**
```
VENDOR DRIFT: UV_HANDLE_ZERO_READ assigned 3 (expected 2: win/tcp.c, win/udp.c),
  cleared 0 (expected 0); read_buffer assigned 0 (expected 0).
src/libuv/stream.sls and src/libuv/private/handles.sls both cite these
facts in the read-buffer comments. Re-verify BOTH before bumping.
```

**Predicted exit status:** the brief asserts `exit=2` for a recipe whose
shell block exits `1`, on the grounds that "make reports 2 for a recipe that
exits 1" and instructs to "gate on the message, not the number." This agent
did not independently verify that make-exit-code claim (it depends on which
`check-pins` sub-recipe line is reached and how this `make` build reports
compound recipe failures) — the controller's run should record the actual
`$?` alongside the message rather than assume 2.

**Revert + re-verify (also not executed by this agent, per protocol):**
```bash
git -C vendor/libuv checkout -- src/win/tcp.c
git -C vendor/libuv status --porcelain    # must be empty
make check-pins && make check-help
```
Predicted output: `vendor read-path facts ok: ZERO_READ set=2 cleared=0, read_buffer assigned=0`, `check-help` green (both are exactly this agent's own unmutated-tree measurements below, since the revert restores the identical tree state).

## Step 2: `make check-pins` output (this agent's run, unmutated tree)

```
pins agree: chez-srfi 7879b52
vendored libuv pin ok: 1.52.1 (0x013401) in [0x012c00,0x01ffff]
README states the libuv floor (1.44.0)
manifest version matches CHANGELOG (0.4.0)
vendor read-path facts ok: ZERO_READ set=2 cleared=0, read_buffer assigned=0
```
Exit 0.

## `make check-help`

Exit 0, no output (silent success — no undocumented `.PHONY` target).

## `make test` (this agent's run, Darwin, unmutated tree)

`ALL SUITES PASSED`, all sixteen `tests/test-*.sps` suites, exit 0. No new
test rows were added by this task (none were required — Task 5 replaces a
comment's factual claim with a `make check-pins` tripwire, not a test-suite
assertion). Full tail:

```
=== tests/test-timer.sps ===
%%%% Starting test timer
# of expected passes      128
ALL SUITES PASSED
```

## Note for final-review triage, not this task's problem

`make test` has no per-suite timeout; a hanging suite (cf. Probe C2's
deadlock in the Task 4 log) would consume the whole run rather than fail
fast. Already logged per the controller's instruction; not fixed here.

## Final state

`git status --porcelain` clean except the three intended files
(`Makefile`, `src/libuv/private/handles.sls`, `src/libuv/stream.sls`) plus
this log. `git -C vendor/libuv status --porcelain` (and top-level
`git submodule status`) confirm `vendor/libuv` was never touched — no Step 3
mutation was applied or left behind.

---

## Controller-run: the vendor drift probe

Run by the controller, not the implementer. This probe edits a **git
submodule**, where a stray leftover is easier to miss than in the parent tree —
two subagents earlier in this milestone returned control with live mutations
applied, so mutation execution moved here.

**Baseline, unmutated:**
```
vendor read-path facts ok: ZERO_READ set=2 cleared=0, read_buffer assigned=0
```

**Mutation:** append a third assignment to `vendor/libuv/src/win/tcp.c`:
```c
void chez_probe_drift(uv_tcp_t*h){h->flags |= UV_HANDLE_ZERO_READ;}
```

**Output:**
```
VENDOR DRIFT: UV_HANDLE_ZERO_READ assigned 3 (expected 2: win/tcp.c, win/udp.c),
  cleared 0 (expected 0); read_buffer assigned 0 (expected 0).
src/libuv/stream.sls and src/libuv/private/handles.sls both cite these
facts in the read-buffer comments. Re-verify BOTH before bumping.
make: *** [check-pins] Error 1
```

`make check-pins` exit status **2** — make's own code for a recipe that exited
1. Measured directly rather than through a pipe: `make check-pins | tail` reports
*tail's* status, which is 0 and looks like a pass. Anyone gating this in a
script must capture make's status, not a pipeline's.

**Reverted** via `git -C vendor/libuv checkout -- src/win/tcp.c`; submodule and
parent both clean; `make check-pins` and `make check-help` green again.

**Result: GREEN.** The guard fires on the drift it exists to catch, and its
message names both Scheme comment sites — which is the whole point, since the
failure a future maintainer needs to act on is not "a count changed" but
"two comments in this repo now cite something untrue."

### What this probe does and does not bind

- It binds the **vendored** path only. ADR-0001's system-libuv acquisition path
  is unaudited by it — a system libuv whose read path differs would not trip
  this guard.
- The rule the corrected comments state does **not** depend on the vendor fact.
  It rests on the portable infallible-alloc invariant
  (`src/libuv/private/handles.sls:846-858`): freeing anywhere but close means
  `alloc-dispatch` might have to allocate on a path libuv can call into, and
  that breaks on every platform. The vendor facts are a *footnote* to the rule,
  and the tripwire protects the footnote, not the rule.

That distinction is the reason this task exists. The old comments made a
platform-specific dead-code claim carry a portable invariant's weight; a reader
who checked the claim would find nothing and could reasonably conclude the rule
was obsolete.
