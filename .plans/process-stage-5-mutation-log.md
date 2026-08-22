# Process Stage 5 Mutation Log

Task 8: `src/libuv/process.sls` (new) -- `uv-spawn!` end to end with the full
stdio-spec vocabulary, the exit dispatcher, the walk dispatcher, and
ADR-0015's class-dependent spawn-failure path; `tests/test-process.sps`
(new); `uv-process?` added to `src/libuv/handle.sls`; two minimal additions
to `src/libuv/private/handles.sls` (`record-orphan-callback!` exported,
`discard-failed-handle!` added and exported); design spec §4.3's stdio table
amended to the dotted-pair spelling the implementation and every planned
test row use.

## Method

Per AGENTS.md ("a test is not finished when it passes; it is finished when
you have watched it fail"): Step 1 wrote `tests/test-process.sps` against the
not-yet-existing `(libuv process)` and confirmed RED, the library landed,
Step 4 confirmed GREEN, and the probes below were then run against the
committed tree and reverted. Every probe was taken from a byte-for-byte
backup of the file it mutated (scratchpad copies of `process.sls`,
`native.sls`, `libuv-shim.c`) and restored from that backup; `git status`
after the last revert showed only the task's own intended changes.

Two of the brief's four probes did **not** fail in the literal form the brief
predicted. Both are recorded here with the narrowed mutation that does fail
through the asserted property, per AGENTS.md's "narrow the mutation until the
failure is the one you predicted" -- not quietly replaced.

## RED (Step 2, before `src/libuv/process.sls` exists)

```
=== tests/test-process.sps ===
Exception: library (libuv process) not found
```

Every other suite passed unchanged in the same run.

## GREEN (Step 4)

```
=== tests/test-addrinfo.sps ===       41
=== tests/test-conditions.sps ===     94
=== tests/test-dns.sps ===           121
=== tests/test-echo.sps ===           32
=== tests/test-facade.sps ===         49
=== tests/test-lifecycle.sps ===      64
=== tests/test-loop.sps ===          138
=== tests/test-native.sps ===        243
=== tests/test-pipe.sps ===           13
=== tests/test-process.sps ===        54
=== tests/test-shim-loading.sps ===   24
=== tests/test-stream.sps ===         10
=== tests/test-tcp.sps ===           168
=== tests/test-timer.sps ===         128
ALL SUITES PASSED
```

`test-process.sps` contributes 54; every pre-existing suite is at its
Task 7 total, unchanged.

The suite's own informational row records which ADR-0015 arm the `'ENOENT`
spawn actually took on this platform (macOS/arm64, libuv 1.52.1):

```
  [informational] ENOENT cleanup arm: exec-class-close-through-protocol
```

which is exactly what FINDINGS SQ1 Observation 1 measured for the exec class
on both platforms -- the handle is still in `loop->handle_queue`, so the
close-through-protocol arm is the correct one and the test's counter rows
only balance after the loop has turned.

## Probe 1 (Task 4 forward obligation 1): `exit-callable`'s type list

### 1a -- the brief's literal form: swap `integer-64` / `int`

**Mutation**, in `src/libuv/private/native.sls`:

```scheme
  (define exit-callable
    (foreign-callable (lambda (handle exit-status term-signal)
                        ((dispatcher-ref 'exit) handle exit-status term-signal))
                      (uptr int integer-64) void))   ; was (uptr integer-64 int)
```

**Command and output, verbatim:**

```
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-process.sps
%%%% Starting test process
  [informational] ENOENT cleanup arm: exec-class-close-through-protocol
# of expected passes      54
```

**Result: GREEN -- the mutation is NOT caught, and cannot be by any exit-code
test.** Traced rather than shrugged at. `uv_exit_cb` is
`void (*)(uv_process_t *, int64_t, int)`; on both supported ABIs (AArch64
AAPCS and SysV x86-64) each scalar argument occupies its own register by
POSITION -- x1/rsi for the second, x2/rdx for the third. Swapping the two
TYPE names in the `foreign-callable` type list therefore changes only the
WIDTH each argument is read at, never which register it is read from. A
normal exit delivers `exit_status = 7` (a `WEXITSTATUS`, so always 0-255,
which is why no exit-code test can ever put a value outside 32 bits in that
slot) and `term_signal = 0` (libuv zeroes the whole register writing an int
0), so reading the first narrow and the second wide answers 7 and 0 either
way. The width declaration is unfalsifiable through this callback's own value
range, and saying so is the honest answer rather than pretending the row
guards it.

### 1b -- narrowed to the property the row actually asserts: argument ROUTING

**Mutation**, same file, type list left correct:

```scheme
  (define exit-callable
    (foreign-callable (lambda (handle term-signal exit-status)   ; names swapped
                        ((dispatcher-ref 'exit) handle exit-status term-signal))
                      (uptr integer-64 int) void))
```

**Command and output, verbatim:**

```
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-process.sps
%%%% Starting test process
FAIL normal exit: status is the code, term-signal #f
  [informational] ENOENT cleanup arm: exec-class-close-through-protocol
# of expected passes      53
# of unexpected failures  1
```

**Result: FAILS BY NAME.** The trampoline now hands libuv's `exit_status`
(7) to the dispatcher as `term_signal` and its `term_signal` (0) as
`exit_status`, so `(7 #f)` becomes `(0 7)` -- 7 is outside `term-signal->value`'s
bound signal set, so it passes through raw, exactly as §4.4 requires. This is
the assertion doing its job: the exit-code row guards *which int is which*,
which is the decision that can actually be got wrong. Reverted; the suite
reconfirmed 54 passes before the next probe.

**Task 4's obligation is therefore discharged with a correction**: the
obligation was recorded as "swap `integer-64`/`int` -> exit-code test fails",
and the width half of that is not testable. The routing half is, and it is
covered.

## Probe 2 (Task 4 forward obligation 2): mispoint `uv-spawn-native`'s exit_cb write

**Mutation**, in `src/libuv/private/native.sls`:

```scheme
  (define (uv-spawn-native loop-ptr handle-ptr options-ptr)
    (foreign-set! 'uptr options-ptr
                  (offsetof-uv-process-options-t-flags) exit-cb-entry)  ; was -exit-cb
    (raw-spawn loop-ptr handle-ptr options-ptr))
```

**Command and output, verbatim:**

```
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-process.sps
%%%% Starting test process
Exception: invalid memory reference.  Some debugging context lost
```
(exit code 255 -- the suite dies on the FIRST spawn, before any assertion
after it runs)

**Result: FAILS, harder than the brief predicted.** The obligation anticipated
"spawn fails or exit never fires"; what actually happens is worse and louder.
`flags` is an `unsigned int` and `stdio_count` the `int` immediately after it,
so a pointer-wide write at the flags offset clobbers BOTH: libuv is handed a
garbage flag word (its unknown-flag assert is compiled out of a release
build) and, more fatally, a garbage `stdio_count`, which it then uses to
iterate a `uv_stdio_container_t` array of that length. The process takes a
SIGSEGV that Chez reports as `invalid memory reference`. Recorded as-is
rather than narrowed: the brief asked for the observation, and a segfault on
the first spawn is an unambiguous one. Reverted; the suite reconfirmed 54
passes.

## Probe 3 (brief item 3): swap two §5.3 shim offset rows

### 3a -- the brief's literal form: swap `FILE` and `CWD`

**Mutation**, in `src/libuv-shim.c` (both rows, then `make build`):

```c
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_FILE",
    (long)offsetof(uv_process_options_t, cwd) },     /* was file */
  ...
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_CWD",
    (long)offsetof(uv_process_options_t, file) },    /* was cwd */
```

**Command and output, verbatim:**

```
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-process.sps
%%%% Starting test process
Exception in uv-spawn!: no such file or directory
```
(exit code 255)

**Result: FAILS, but not at the row the brief named.** With the two offsets
swapped, `"/bin/sh"` is written into `options.cwd` and `options.file` stays
NULL, so the very FIRST scenario's spawn raises `'ENOENT` -- an uncaught
condition that aborts the whole `.sps` before the argv/env/cwd scenario is
reached. Sharp, but it proves the `FILE` row is load-bearing rather than that
the argv/env/cwd scenario is §5.3's mutation target. Reverted and rebuilt.

### 3b -- narrowed to a pair of offsets only that scenario exercises: `ARGS` / `ENV`

**Mutation**, in `src/libuv-shim.c` (both rows, then `make build`):

```c
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_ARGS",
    (long)offsetof(uv_process_options_t, env) },     /* was args */
  { "OFFSETOF_UV_PROCESS_OPTIONS_T_ENV",
    (long)offsetof(uv_process_options_t, args) },    /* was env */
```

**Command and output, verbatim:**

```
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-process.sps
%%%% Starting test process
FAIL normal exit: status is the code, term-signal #f
FAIL argv[0], argv[1], env, and cwd all arrived as written
FAIL explicit env replaces the parent's rather than extending it
FAIL omitted env inherits the parent's
  [informational] ENOENT cleanup arm: exec-class-close-through-protocol
# of expected passes      50
# of unexpected failures  4
```

**Result: FAILS BY NAME, at the named target.** `argv[0], argv[1], env, and
cwd all arrived as written` is design spec §5.5's declared mutation target
for the offset rows, and it fails; the exit-code and env-inheritance rows
fail alongside it because argv itself is now written through the env slot, so
every child receives the wrong argument vector. Reverted and rebuilt; the
suite reconfirmed 54 passes.

## Probe 4 (brief item 4): skip the options-block free on the failure path

The brief's wording was "delete `count-spawn-options-free!` from the failure
path", which does not map onto the implementation as written: ADR-0015
decision 1 puts the free at ONE unconditional site, so there is no
failure-path copy to delete. The faithful translation -- and the leak the ADR
itself names ("an early return that skips the free is a definite leak under
`make test-memory`") -- is to make that one free conditional.

**Mutation**, in `src/libuv/process.sls`:

```scheme
        (let ((rc (uv-spawn-native (loop-pointer loop 'uv-spawn!) ptr block)))
          (when (zero? rc) (free-options-block! block))   ; was unconditional
```

**Command and output, verbatim:**

```
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-process.sps
%%%% Starting test process
FAIL no options block leaked on the failure path
  [informational] ENOENT cleanup arm: exec-class-close-through-protocol
FAIL the uid failure leaked no options block
FAIL validation raised nothing into the options counter
FAIL counters all zero at suite end
# of expected passes      50
# of unexpected failures  4
```

**Result: FAILS BY NAME**, at the `'ENOENT` scenario's `spawn-options` row
exactly as the brief predicted, plus the `'EPERM` scenario's row, the
validation walk's row (which runs after both failures and sees the leaked
count), and the suite-final counter balance. Reverted; the suite reconfirmed
54 passes.

## Probe 5 (ADR-0015 conformance, not in the brief): collapse the discriminator to the setup-class arm

The largest decision in this task is ADR-0015 decision 2 -- ask the loop, not
the errno -- and the brief's four probes do not touch it. ADR-0015's own
consequences say what a test must catch: "a mutation that collapses the two
arms into one fails one of them."

**Mutation**, in `src/libuv/process.sls`:

```scheme
    (if #f                                    ; was (handle-in-loop-queue? loop proc)
        (begin (registry-register! ...) (count-process-new!) (close-handle! proc))
        (discard-failed-handle! proc))
```

**Command and output, verbatim:**

```
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-process.sps
%%%% Starting test process
  [informational] ENOENT cleanup arm: setup-class-direct-free
Exception in uv-loop-close!: resource busy or locked
```
(exit code 255)

**Result: FAILS, and with precisely the signature ADR-0015's 2x2 predicts.**
The informational row records the wrong arm, and the loop then refuses to
close: `exec failure + direct free : loop_close EBUSY` is the ADR's own cell,
reproduced here from the public API on the first attempt. Reverted; the suite
reconfirmed 54 passes.

## Probe 6 (the same decision, the other way): collapse to the close-through-protocol arm

**Mutation**, in `src/libuv/process.sls`:

```scheme
    (if #t                                    ; was (handle-in-loop-queue? loop proc)
```

**Command and output, verbatim:**

```
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-process.sps
%%%% Starting test process
  [informational] ENOENT cleanup arm: exec-class-close-through-protocol
# of expected passes      54
```

**Result: GREEN -- NOT CAUGHT, and this is a real gap, recorded rather than
left silent.** Every spawn failure this suite drives (`'ENOENT` from a
missing file, `'EPERM` from `uid` as non-root) is an EXEC-class failure, for
which the close-through-protocol arm is the correct one; nothing here reaches
the setup class, so the `discard-failed-handle!` arm is currently
implemented, exported, and untested. The wrong-cell outcome it guards is the
worse of the two ADR-0015 measured -- `uv_close` on an already-unlinked
handle silently splices a LATER-registered live handle out of
`loop->handle_queue` while `uv_loop_close` still answers 0.

**Forward obligation (Task 9).** The milestone plan already carries the row
that closes this: `(inherit-stream . h)` naming an open-but-never-connected
stream reaches `vendor/libuv/src/unix/process.c:226` and returns `EINVAL`
through the `error:` label -- the setup class, network-free and
deterministic, from the public API. When that row lands, this probe must be
re-run against it and must fail; the two ADR-0015 observables to assert there
are the ones the 2x2 separated (a handle registered AFTER the failure still
exists, and the loop closes cleanly), both of which `tests/test-process.sps`
already asserts for the exec class in its `'ENOENT` scenario.

## Memory lane

```
$ make test-memory
macOS: ASan preload only; LeakSanitizer is unsupported on arm64.
Leak claims must come from Linux CI (ADR-0003).
test-memory: ASan runtime .../libclang_rt.asan_osx_dynamic.dylib
... all fourteen suites at their normal totals ...
EXIT: 0
```

Clean: no `AddressSanitizer` report of any kind, every suite at its plain-`make
test` total, exit 0. Per ADR-0003 this is an addressability result only -- the
leak claim for the new options-block alloc/free pair and for the two
spawn-failure cleanup arms has to come from Linux CI's valgrind leg. The
counter pair around the options block (probe 4 above) is what makes the leak
visible without valgrind in the meantime.

## Post-revert gate tail (pre-commit)

```
=== tests/test-addrinfo.sps ===       41
=== tests/test-conditions.sps ===     94
=== tests/test-dns.sps ===           121
=== tests/test-echo.sps ===           32
=== tests/test-facade.sps ===         49
=== tests/test-lifecycle.sps ===      64
=== tests/test-loop.sps ===          138
=== tests/test-native.sps ===        243
=== tests/test-pipe.sps ===           13
=== tests/test-process.sps ===        54
=== tests/test-shim-loading.sps ===   24
=== tests/test-stream.sps ===         10
=== tests/test-tcp.sps ===           168
=== tests/test-timer.sps ===         128
ALL SUITES PASSED
```

Identical to the Step-4 GREEN run; no probe mutation was left in the tree
(`git status` after the last revert listed only `src/libuv/handle.sls`,
`src/libuv/private/handles.sls`, `src/libuv/process.sls`,
`tests/test-process.sps` -- and neither `src/libuv-shim.c` nor
`src/libuv/private/native.sls`, both of which the probes had touched and
which `git diff` reported as unchanged).

## Coverage notes

- **The `'spawn-failure-state-unclassifiable` guard is uncovered**, by
  construction rather than by omission. ADR-0015 decision 5 introduces it for
  the one state the spike could not measure (exec succeeded, a later
  `uv__process_open_stream` failed), and the ADR itself records that the only
  trigger reachable through this binding's API by construction --
  an already-connected target stream -- is foreclosed before any allocation by
  `'pipe-already-used`. The remaining arm is a macOS-only
  `setsockopt(SO_OOBINLINE)` failure inside libuv (stream.c:424-430), which no
  test can provoke. The guard is a loud assertion about a state that should be
  unreachable, and the honest record is that nothing drives it.
- **`term-signal->value`'s signal arms are uncovered here.** Only the
  `term_signal = 0 -> #f` arm runs in this suite. The `'sigterm` arm arrives
  with Task 10's kill scenarios; the raw-passthrough arm is exercised
  incidentally by probe 1b above (7 came back as the raw integer 7), which is
  evidence the else arm works but is not a standing test.
- **`'pipe-already-used` and `'pipe-wrong-loop` are implemented and
  unexercised**, deferred to Task 9 by the brief (they need a consumed pipe
  and a second loop respectively).
- **`discard-failed-handle!`'s not-registered check** (handles.sls) is a
  check-instead-of-comment guard on a state the correct discriminator makes
  unreachable; no test drives it, for the same reason probe 6 documents.

## Task 9: stdio scenarios (echo, duplex, extra fd, inherit-fd, inherit-stream,
## pipe reuse/wrong-loop) -- GREEN, and probe 6's forward obligation discharged

Seven new scenarios appended to `tests/test-process.sps` (54 -> 82
assertions): full echo loop (write/read/shutdown/EOF/exit + `pipe-already-
used` reuse refusal), the setup-class spawn-failure twin (`(inherit-stream .
<unconnected pipe>)` -> `'EINVAL`), `pipe-wrong-loop`, duplex
(`UV_READABLE_PIPE|UV_WRITABLE_PIPE`), extra fd at slot 3, `inherit-fd` via a
real temp-file fd (`port-file-descriptor`/`open-file-output-port`, both
available in this Chez without a fallback), and `inherit-stream` over a real
loopback TCP pair (ADR-0010 machinery). Full detail, RED/GREEN transcripts,
and the fix below are in `.superpowers/sdd/task-9-report.md`.

### Fix found while writing the setup-class scenario: `mark-consumed-pipes!`
### only matched `(pipe h dir)`, never `(inherit-stream . h)`

The setup-class scenario's own record-level assertion --
"the named pipe is marked connected even on the setup-class path"
(`pipe-connected?` on the pipe named via `(inherit-stream . unconnected)`) --
was written RED first and stayed RED against the pre-Task-9 tree:

```
  [informational] pipe-connected? on the inherit-stream target: #f
```

`stdio-spec-handle`'s own header comment already claimed "the connected-
marking walk" as its second caller ("One place decides that, so the loop
check and the connected-marking walk cannot drift apart") -- but
`mark-consumed-pipes!` had its own narrower `(and (list? spec) (pair? spec)
(eq? 'pipe (car spec)))` match instead of calling `stdio-spec-handle`, so the
two had already drifted. Fixed by routing `mark-consumed-pipes!` through
`stdio-spec-handle`, guarded by `uv-pipe-record?` (inherit-stream also
accepts tcp handles, which have no `connected?` field). GREEN after the fix:

```
  [informational] pipe-connected? on the inherit-stream target: #t
```

Both the module header comment (S4.3/ADR-0015 decision 6 paragraph) and the
`mark-consumed-pipes!` comment were updated to state the widened scope. No
existing test asserted the narrower behavior (grepped `pipe-connected?` and
`inherit-stream` across every suite before making the change).

### Probe (brief item, Step 4): swap `to-child`/`from-child` in `stdio-spec-flags`

**Mutation**, in `src/libuv/process.sls`:

```scheme
                      ((to-child)   (uv-stdio-writable-pipe))  ; was readable
                      ((from-child) (uv-stdio-readable-pipe))  ; was writable
```

**Command and output, verbatim:**

```
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-process.sps
%%%% Starting test process
Exception in uv-read-start!: socket is not connected
```
(exit code 255)

**Result: FAILS, louder than a named assertion.** With the bits swapped, the
echo scenario's `from-child` slot is written `UV_READABLE_PIPE` (child
reads, parent side stays write-only), so `uv_read_start` on the PARENT's
`stdout-pipe` end -- the very first stream call the echo scenario makes --
raises `UV_ENOTCONN` synchronously, before any `test-equal` row runs. Same
shape as Task 8's probe 2 (a mutation that aborts the suite is still an
unambiguous FAIL; recorded as observed rather than narrowed to a quieter
row). Reverted; the suite reconfirmed 82 passes.

### Probe (brief item, Step 4): write the inherit-fd container's data via
### `c-uptr-set!` instead of `c-int-set!`

**Mutation**, in `src/libuv/process.sls`:

```scheme
            ((eq? 'inherit-fd (car spec))
             (c-uptr-set! (+ c (offsetof-uv-stdio-container-t-data)) (cdr spec)))
             ; was c-int-set!
```

**Command and output, verbatim:**

```
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-process.sps
%%%% Starting test process
  [informational] ENOENT cleanup arm: exec-class-close-through-protocol
# of expected passes      82
```
(exit code 0)

**Result: GREEN -- NOT CAUGHT on this platform, exactly the shape the brief
flagged as possible, recorded honestly rather than reworded into a pass.**
Measured rather than assumed: a small C probe against the vendored headers
gives `sizeof(uv_stdio_container_t)=16`, `offsetof(data)=8`,
`sizeof(data)=8` (the union is sized for its pointer member, on this
LP64/little-endian arm64 build). Two facts combine to make the 8-byte write
harmless here: (1) the union already occupies a full 8-byte slot at the end
of the 16-byte container, so an 8-byte write at `+8` never overruns into a
neighbouring container's `flags` field; (2) `(cdr spec)` is a small
non-negative fd (this scenario uses 3), so `c-uptr-set!` zero-extends it
into all 8 bytes rather than writing any pre-existing garbage into the high
4 -- and a little-endian re-read of the low 4 bytes as `int fd` recovers the
exact value written. No garbage ever lands in the union's high bytes because
nothing non-zero was ever placed there. The width declaration is real (V2:
"an fd as a 32-bit int, a stream as a pointer... writing an fd pointer-wide
would also clear the union's high bytes, which is indistinguishable from
correct on LP64 until it is not") -- it is simply not falsifiable by THIS
mutation on THIS platform with a small fd value, the same unfalsifiable-by-
value-range shape Task 8's probe 1a found for `exit-callable`'s width
declaration. A value with set high bits (a large fd, or reading the union
back as a pointer) would be a different, more discriminating probe; not run,
because inventing an artificially large fd defeats the "measure the real
code path" rule. Reverted; the suite reconfirmed 82 passes.

### Probe 6 discharged (Context item 2's hard obligation)

Task 8's mutation log recorded probe 6 (collapse ADR-0015's discriminator to
ALWAYS take the close-through-protocol/exec-class arm) as **GREEN --
uncovered, and a real gap**, because every spawn failure Task 8's suite
drove was exec-class; the setup-class arm (`discard-failed-handle!`) shipped
untested. The forward obligation was explicit: re-run this exact probe once
the setup-class scenario lands, and it must fail.

**Mutation**, in `src/libuv/process.sls` (identical to Task 8's probe 6):

```scheme
    (if #t                                    ; was (handle-in-loop-queue? loop proc)
        (begin (registry-register! ...) (count-process-new!) (close-handle! proc))
        (discard-failed-handle! proc))
```

**Command and output, verbatim:**

```
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-process.sps
%%%% Starting test process
  [informational] ENOENT cleanup arm: exec-class-close-through-protocol
FAIL setup-class failure: no process counted (direct-free arm)
# of expected passes      81
# of unexpected failures  1
```
(exit code 1)

**Result: FAILS BY NAME -- the setup-class row catches it, exactly as
predicted.** With the discriminator collapsed, the `(inherit-stream .
<unconnected pipe>)` spawn -- genuinely setup-class (libuv's `error:` label
at process.c:1075 already unlinked the handle before this code runs) -- is
now wrongly treated as exec-class: `clean-up-failed-spawn!` registers,
counts, and asynchronously closes a handle libuv's own `error:` cleanup
already unlinked from `loop->handle_queue`. The scenario's `procs-before
(live-count 'process)` check, taken with NO drain (by design -- a genuine
setup-class failure never registers, so there is nothing to wait for), reads
`procs-before + 1` and fails by name. Only one row fails: the wrongly-
registered handle's async close still completes during this scenario's own
closing `run-until`, so the counters resettle to baseline before the suite-
end balance rows run -- the corruption ADR-0015 warns about (a live handle
silently spliced out of `loop->handle_queue`) is a C-level hazard against a
LATER-registered handle, which this narrow probe run had none of to victimize;
the discriminator being wrong is still caught, cleanly, by the counter row
alone. This is a quieter failure signature than Task 8's probe 5 (which blew
up the whole suite with `loop_close EBUSY`), which is exactly what ADR-0015
predicts for this direction of the collapse -- probe 5's arm corrupts loudly
(a live, needed handle gets orphaned from a queue the loop still owns),
probe 6's arm corrupts quietly (a dead handle gets a redundant, technically-
survivable close) -- and quiet corruption is precisely why it needed a
purpose-built test rather than relying on collateral damage to catch it.
Reverted; the suite reconfirmed 82 passes.

`discard-failed-handle!`'s not-registered check (handles.sls) remains
formally uncovered by any test that reaches it through the CORRECT
discriminator (it guards a state the correct code makes unreachable), but
the setup-class scenario now exercises the `discard-failed-handle!` call
itself on the normal, undisturbed path -- so the coverage note above is
narrowed: the ARM is covered; the impossible-state check inside it is not,
by construction, same as before.

### Post-revert gate tail (pre-commit, Task 9)

```
=== tests/test-addrinfo.sps ===       41
=== tests/test-conditions.sps ===     94
=== tests/test-dns.sps ===           121
=== tests/test-echo.sps ===           32
=== tests/test-facade.sps ===         49
=== tests/test-lifecycle.sps ===      64
=== tests/test-loop.sps ===          138
=== tests/test-native.sps ===        243
=== tests/test-pipe.sps ===           13
=== tests/test-process.sps ===        82
=== tests/test-shim-loading.sps ===   24
=== tests/test-stream.sps ===         10
=== tests/test-tcp.sps ===           168
=== tests/test-timer.sps ===         128
ALL SUITES PASSED
```

`make test-memory`: exit 0, no `AddressSanitizer` report, every suite at its
plain-`make test` total (macOS/arm64 ASan-only leg, ADR-0003 -- the Linux
valgrind leg is the leak authority). `git status` after the last revert
listed only `src/libuv/process.sls` and `tests/test-process.sps`, matching
this task's two intended files; `git diff` reported both mutation-touched
regions (the `to-child`/`from-child` case arms, the `inherit-fd` data write,
and the `(if ...)` discriminator) byte-identical to pre-probe.

### Task 9 coverage notes

- **`'pipe-already-used` and `'pipe-wrong-loop`, deferred by Task 8, are now
  driven** -- the former by the echo scenario's second-spawn reuse attempt,
  the latter by its own dedicated scenario.
- **The setup-class arm (`discard-failed-handle!`) is no longer an
  uncovered forward obligation.** Probe 6 above is its discharge.
- **`inherit-stream`'s pipe-vs-tcp guard (`uv-pipe-record?` in the widened
  `mark-consumed-pipes!`) is exercised by both branches**: the setup-class
  scenario (pipe target, marked connected) and the inherit-stream scenario
  (tcp target `accepted`, which has no `connected?` field and is correctly
  left untouched -- `test-tcp.sps`/`test-facade.sps` totals are unchanged,
  which is the negative evidence that the guard did not misfire on a tcp
  handle).
- **`duplex`'s OR'd `UV_READABLE_PIPE|UV_WRITABLE_PIPE` bits are exercised
  for the first time** (Task 8's suite never used `'duplex`); the
  direction-bit-swap probe above is this row's mutation coverage.
- **The container fd-width declaration (V2) remains formally unfalsifiable
  by a small-fd probe on this LP64 platform**, same shape as Task 8's probe
  1a for `exit-callable`. Recorded rather than hidden; Linux CI's valgrind
  leg does not change this (a wrong-width read that happens to recover the
  right bytes is not a memory error).

## Task 10: swap `sig-term`/`sig-kill` in `signal-symbol->int`

Task 10 introduces `uv-process-kill!`, `uv-kill!`, and `uv-process-pid` with
their signal-vocabulary tests, including rows for SIGTERM and SIGKILL. A probe
swapping the signal mappings in `signal-symbol->int` verifies both rows are
sensitive to the mapping.

**Mutation**, in `src/libuv/process.sls`:

```scheme
         ((sigterm) (sig-kill)) ((sigkill) (sig-term)) ((sigint) (sig-int))
         ; was: ((sigterm) (sig-term)) ((sigkill) (sig-kill)) ...
```

**Command and output, verbatim:**

```
$ CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs chez --program tests/test-process.sps
%%%% Starting test process
  [informational] ENOENT cleanup arm: exec-class-close-through-protocol
FAIL
FAIL sigkill by pid delivers (0 sigkill)
# of expected passes      96
# of unexpected failures  2
```

**Result: FAILS BY NAME, at both rows the swap touches.** `(uv-process-kill!
proc 'sigterm)` now sends the real SIGKILL int; the child dies by actual
SIGKILL, so `term-signal->value` (unmodified, reads the raw delivered
signal) reports `'sigkill`, and the unnamed `(test-equal '(0 sigterm)
exit-result)` row fails (shown as bare `FAIL` -- `test-equal` with no
message argument prints no name). Symmetrically, `(uv-kill! pid 'sigkill)`
now sends the real SIGTERM int, the child dies by actual SIGTERM, and
`"sigkill by pid delivers (0 sigkill)"` fails by name with `exit-result`
= `(0 sigterm)`. Exactly the outcome named in the task's own
Context ("the KILL is sent as SIGKILL so exit delivers (0 sigkill) ≠ (0
sigterm)"), confirmed empirically rather than merely predicted. Reverted
immediately; `diff` against the pre-probe backup showed the file
byte-identical; `make test` reconfirmed `ALL SUITES PASSED` at the GREEN
totals above before commit.
