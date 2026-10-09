# The scratch verbs as one step (#86, part one): evidence and mutation log

2026-10-09. `uv-tcp-bind!`, `uv-tcp-getsockname-port`,
`uv-tcp-sockname-address`, `uv-tcp-peer-address` and the four buffer-size
verbs (`uv-send-buffer-size`, `uv-send-buffer-size!`, `uv-recv-buffer-size`,
`uv-recv-buffer-size!`) each become one interrupt-free step: owner and open
checks, pointer, the block, its fill, the native call, the answer read out
of the block, and the block freed. The sweeps are in
`tests/test-handle-steps.sps`.

## On main (3d3ffe6)

The suite was written first and run against main's verbs, on macOS and on
glibc 2.36 (Debian 12, aarch64, the Valgrind image); the fuel maps were the
same on both. Each sweep runs its verb in an engine at fuel 1, 2, …. It
changes the world at the first expiry, then resumes the verb or drops it.
Every target is a new client of one loop: unbound for the bind, connected
for the peer query, and bound to a loopback port for the rest.

Fuel maps (verdict, first fuel, last fuel):

**Reuse.** At the expiry the run closes the client, runs the loop until the
close has freed it, makes a new client at the freed address, and resumes.

| Verb | refused | `null-handle-pointer` | a call on the new client | returned | untouched |
|---|---|---|---|---|---|
| bind | 1–10 | 11–44 | 45 | 46–49 | 50 |
| getsockname-port | 1–9 | 10–25 | 26 (EBADF) | 27–46 | 47 |
| sockname-address | 1–9 | 10–25 | 26 (EBADF) | 27–62 | 63 |
| peer-address | 1–9 | 10–25 | 26 (EBADF) | 27–62 | 63 |
| send/recv-buffer-size | 1–10 | 11–17 | 18 (EBADF) | 19–25 | 26 |
| send/recv-buffer-size! | 1–10 | 11–20 | 21 (EBADF) | 22–25 | 26 |

The new client is unbound, so a query made on it raises libuv's EBADF. A
probe that asked the new client for its port after each bind run found it
bound (port 58775) after fuel 45 alone: the bind resumed there bound the
new client and returned normally. Fuels 46 and on had made their call
before the change.

**Handoff.** The loop's owner is set to another thread. No run past the
entry check was refused: bind 11–49, the queries 10–46/62, the buffer
sizes 11–25. Those suspended before the call made it on a handle the
other thread now owned.

**Drop.**

| Verb | Fuels | Left |
|---|---|---|
| bind | 28–49 | a block |
| getsockname-port | 12–15, 43–46 | a block |
| | 16–42 | two blocks |
| sockname-address, peer-address | 12–15, 59–62 | a block |
| | 16–58 | two blocks |
| buffer sizes | 13–25 | a block |

**Close.** This sweep stops at its first wrong run. Every verb was refused
there as `null-handle-pointer`, not `&uv-handle-closed`: bind and the
buffer sizes at fuel 11, the queries at 10.

The split oracle counts as wrong every expired run that is not refused,
including main's runs that made their call before the change: its premise,
that no expiry lands after a verb's native call, holds for the step's
shape and not for main's, which reads and frees after the call. On main
the defects are the runs above that the table calls `null-handle-pointer`
or a call on the new client, and the handoff runs before the call.

Five rows failed by name on each platform: reuse, handoff, drop, close
and close-reach. The reuse, handoff and drop reach rows passed, as did the
landing witness and the refusal rows below, which hold the new steps'
failure paths.

## The harness

**The new client at the freed address.** The reuse sweep proves nothing in
a run where the new client is elsewhere, so a row asks it of every expired
run (`missed-landings`, #100's lesson), excused under a memory tool.

- glibc's calloc takes nothing from the thread cache, so seven blocks of
  the client's size are freed before the close to fill it.
- macOS sometimes handed out other blocks first, so the run takes blocks
  of the client's size until one lands at the freed address (at most 64),
  frees that one and makes the client.
- One reuse run against main still missed on macOS, the same run in
  every suite run (`uv-recv-buffer-size`, fuel 2; fuel 4 without the
  cache fill), with the peer query's target not yet connected. The freed
  block
  stayed free throughout (`malloc_size` 0), and neither 64 blocks nor 8
  fresh clients took it: macOS kept it where no allocation on this thread
  looked. So a run whose client missed drops its engine and starts again
  with a new target, at most four times, keeping its first balance. In
  the suite as committed no run restarted (it prints the count).
- Under Valgrind no client can land: memcheck never hands a freed block
  back. The first gate run restarted every expired reuse run three times,
  336 restarts, before the witness excused them all. A run under a memory
  tool now never restarts (0 in the next run).

**The peer query's target is connected.** Unconnected, the query raises
ENOTCONN, and builds that condition after its step. Against the fixed
verbs that put expiries after the step in the handoff and reuse sweeps:
fuels 16–74 returned after the change, through the raise. A target
connected to a server on a loop of its own answers normally, with nothing
after the step.

## After the fix

Every split run is refused, every dropped run leaves the registry and every
counter, blocks included, as it found them, and the new client took the
freed address in every expired run. The same maps on macOS and on glibc
(three runs there):

| Verb | refused or dropped | untouched |
|---|---|---|
| bind | 1–25 | 26 |
| getsockname-port, sockname-address, peer-address | 1–15 | 16 |
| send/recv-buffer-size | 1–10 | 11 |
| send/recv-buffer-size! | 1–11 | 12 |

No run was suspended after a step. The rest of `make test` passes.

**Bytes per call:** the fewest of 64 (`tests/uv-meter.sls`), the same
`build/` for both legs, on a connected client.

| Verb | main | after |
|---|---|---|
| `uv-tcp-getsockname-port` | 320 | 0 |
| `uv-tcp-sockname-address` | 544 | 208 |
| `uv-tcp-peer-address` | 544 | 208 |
| each buffer-size verb | 320 | 0 |
| `uv-tcp-bind!` | 432 | 112 |

The address figures include the meter's own 32 B list of the two values.

## Mutants

Each mutant is an exact single-match replacement in a fresh scratch copy of
`src/` and `tests/`, run from the copy with the repo's `build/`. Driver: the
session scratchpad's `hs-mut/run_mutants.py`, with `mutants.py`,
`nmutants.py` and `tmutants.py`. The unmutated copy (B0) passes
test-handle-steps, test-tcp and test-facade.

| Mutant | Change | Result |
|---|---|---|
| O1 | the queries' step uses `open-handle-ptr`, no owner check | **killed**: handoff |
| O2 | the bind's step, the same | **killed**: handoff |
| O3 | the buffer sizes' step, the same | **killed**: handoff |
| O4 | `step-refusal` without its `'wrong-thread` clause | **killed**: handoff |
| S1 | the queries read the pointer before the step and call with it | **killed**: reuse, handoff, close, close-reach |
| S2 | the bind, the same | **killed**: the same four |
| S3 | the buffer sizes, the same | **killed**: the same four |
| N1 | the queries' `one-step` → `begin` | **killed**: reuse, handoff, drop, close, close-reach |
| N2 | the bind's, the same | **killed**: the same five |
| N3 | the buffer sizes', the same | **killed**: the same five |
| A1 | the queries' block made before the step | **killed**: reuse, handoff, drop, close, close-reach |
| A2 | the bind's block made before the step | **killed**: reuse, handoff, close, close-reach |
| A3 | the buffer sizes' cell made before the step | **killed**: the same four |
| F1 | the queries keep the block on libuv's refusal | **killed**: the EBADF and ENOTCONN rows |
| F2 | the bind keeps the block on a bad address | **killed**: the bad-address row |
| F3 | the bind keeps the block on libuv's refusal | **killed**: the second-bind row |
| F4 | the buffer sizes keep the cell on libuv's refusal | **killed**: the buffer EBADF row |
| F5 | the queries never free the block | **killed**: every sweep and reach row, and the refusal rows |
| R1 | the queries answer libuv's errno as a port | **killed**: the EBADF and ENOTCONN rows |
| R2 | the buffer sizes answer libuv's errno as a size | **killed**: the buffer EBADF row |
| R3 | the bind ignores libuv's errno | **killed**: the second-bind row |
| R4 | the bind calls libuv with an unparsed address | **killed**: the bad-address row (libuv's own refusal instead) |
| D1 | a set writes 0, which asks instead | **killed**: test-facade's two "track at two points" rows |
| D2 | the length cell at offset 0, inside the sockaddr | **killed**: test-tcp's first row, `(not-an-ephemeral-port 0)`, after which the process died of SIGKILL; test-facade, 12 rows |
| D3 | the length check against the port's end gone | survived: **uncovered** |
| D4 | the length's write not checked | survived: **uncovered** |
| D5 | the size's write not checked | survived: **uncovered** |
| NM1 | the queries' step ignores a 0 block | survived: **uncovered** (handle-steps 15, tcp 238 pass) |
| NM2 | the bind's, the same | survived: **uncovered** (handle-steps 15, tcp 238 pass) |
| NM3 | the buffer sizes', the same | survived: **uncovered** (handle-steps 15, facade 76 pass) |

A2 and A3 are not caught by the drop row: nothing between the allocation
and the step has a trap check, so no engine expires there. They are caught
through the block a refused run leaves behind.

The uncovered ones:

- **D3.** libuv's getsockname and getpeername answer at least a
  `sockaddr_in` for a TCP socket, so no length falls short of the port.
  The check was main's too.
- **D4, D5.** `try-c-int-set!` refuses only an address that is not one or
  a value that is no C int. The length is `sizeof(struct sockaddr_storage)`
  and the size has passed `require-buffer-size` on entry, so neither write
  can be refused; a refusal is answered as `'sockaddr-length-not-set` or
  `'buffer-size-out-of-range` rather than written as 0, which libuv would
  read as a request for the size.
- **NM1–NM3.** `alloc-block` answers 0 only for a size that is not a
  positive fixnum or one the allocator refuses; each size here is a
  platform constant, and the shim has no hook to fail an allocation
  (#85's NM1–NM3).

**The harness's own mutants.**

| Mutant | Change | Result |
|---|---|---|
| T1 | the landing block kept, so the new client lands elsewhere | **killed**: the witness row, and reuse and reuse-reach through the kept block |
| T2 | no restart for a missed landing | survived on the committed suite, where no run restarts: a guard |
| T3 | no `(collect)` before an attempt | survived: no collection came due inside a step in these runs; the premise's guard, as in test-request-steps and test-process-steps |
| T4 | the handoff changes nothing | **killed**: handoff and handoff-reach |

## The review's follow-ups

PR #101's review (2026-10-09, /code-review xhigh) found nine things. Seven
are fixed here; two are filed as issues of their own (below).

**The suite's plumbing.** Each was reproduced on the committed suite first,
with one edit in a scratch copy, then run against the fixed one.

| Probe | Committed suite | Fixed suite |
|---|---|---|
| P1: the peer target connects to 10.255.255.1, which never answers | each peer sweep blocked in `'once` until macOS's own connect timeout: **300 s**, `make test`'s per-suite cap | the connect ticks (`run-until/ticking`, 4000) and gives up: `connect-never-completed`, every row named, **20 s** |
| P2: the peer target connects to port 1, refused | the peer sweep stopped by name, and the **next sweep's first bind run** reported `left ((registry -1) (tcp -1) (block -1))`: the refused client's close, completed inside it | the refused client's close is run to its end in `prepare`; the bind runs are clean |
| P3: the server's `uv-listen!` refused (backlog −1) | the suite **exited 255** before any row | a precondition row fails by name, `(listen-raised … backlog-out-of-range)`, and the suite runs to its end |

**`step-refusal` and `'wrong-thread`.** The clause read the handle's loop,
and the constructors, the lookups, `uv-spawn!` and the loop verbs call
`step-refusal` with no handle. Each of those refuses `'wrong-thread` for its
loop before, so none reached the clause, but nothing held that. The clause
now maps `'wrong-thread` only when it has a handle; without one it is WHO's
own named refusal, carrying no owner. `uv-tcp-connect!` and `uv-accept!`
dropped their own `'wrong-thread` intercepts, which now duplicated it, and
test-loop's status table gained the clause.

| Mutant | Change | Result |
|---|---|---|
| W1 | the clause reads the loop of a missing handle | **killed**: test-loop, "step-refusal names 'wrong-thread from a step with no handle …" |
| W2 | the clause removed | **killed**: test-loop's status table, and the handoff sweeps of test-handle-steps, test-request-steps (connect) and test-constructors (accept); test-constructor-owner passes, its accept refusals coming from the entry check |

**The landing's cost.** The cache fill now runs in reuse runs only, and
neither it nor the block hunt runs under a memory tool. The suite took 10 s
under Valgrind before and after: the change saves nothing measurable, and
stays because it does no harm.

Under Valgrind (Debian 12 aarch64) test-handle-steps (16 rows), test-loop,
test-request-steps, test-constructors and test-tcp pass, each with nothing
lost; test-loop's 936 B in 3 blocks is its escape allowance.

**Filed, not fixed here:** the sweep helpers copied into five suites (#103), and
`wrong-thread-refusal` reading the owner after the step (#102).

# The other handle verbs as one step (#86, part two)

2026-10-09. The timer verbs (`uv-timer-start!`, `uv-timer-stop!`,
`uv-timer-again!`, `uv-timer-repeat`, `uv-timer-set-repeat!`), the signal
verbs (`uv-signal-start!`, `uv-signal-start-oneshot!`, `uv-signal-stop!`),
`uv-listen!`, `uv-tcp-nodelay!` and `uv-tcp-keepalive!` each become one
interrupt-free step: owner and open checks, pointer, the native call, and,
for a start, the callback stored once libuv has accepted it (and a signal's
mode, checked again in the step). The verbs that do only that share
`handle-call!`. Their sweeps join the scratch verbs' in
`tests/test-handle-steps.sps`, with `uv-tcp-keepalive!`'s two forms swept
apart.

## What the suite gained

- **Kinds.** A target is a TCP client, a timer or a signal handle, each
  made on `h-loop`. A stop or an again gets a timer started an hour out,
  with a repeat, and a signal stop a handle watching `SIGUSR2`; nothing
  ever fires. The new handle of a reuse run is of the target's kind, and
  the landing takes blocks of that kind's size.
- **The other mode.** For the two signal starts, a fourth change starts the
  target in the mode the verb does not ask for. The resumed verb owes
  `'signal-mode-fixed`.
- **Whole or not begun.** A dropped run must leave the handle as it found
  it, or as a call nothing interrupts leaves it: what libuv says of the
  handle (`uv_is_active`), the callback its record holds, and a timer's
  repeat or a signal's mode.
- **Rows of their own.** A listen libuv refuses (a client bound to the
  server's port, `EADDRINUSE` held back by the bind until the listen) is
  refused, storing no callback. A number its C parameter cannot take is
  refused by name, and the largest each takes reaches libuv.
- **test-timer.sps:** each timer verb refuses another kind of handle (a
  signal handle never started), naming `'not-a-uv-timer`.

## On main (87337b9)

Run first against main's verbs, on macOS and on glibc 2.36 (the Valgrind
image), twice on each: eight rows fail by name on both, with the same fuel
maps. The scratch verbs' rows pass, #101 having fixed them.

| Row | macOS and glibc |
|---|---|
| reuse: never reaches the new handle | fails: every new verb returns after the change, at one or two fuels, but the again, which raises libuv's EINVAL for the new timer (it has no callback); the signal starts raise `null-handle-pointer` at 11–13 first |
| handoff: refused | fails: every new verb returns after the change |
| other mode: refused | fails: both starts return at 11–15 |
| drop: whole or not begun | fails: the listen and timer start at 10–11 and the signal starts at 14–15 left `(0 the-verbs …)`, the callback stored and nothing active |
| close: refused | fails; each stale call on the freed block, below |
| close reach | fails |
| the listen libuv refuses | fails: `((refused EADDRINUSE) the-verbs)` |
| the out-of-range numbers | fails: Chez's own `invalid foreign-procedure argument` for the timer's 2^64 and the keepalive's 2^32; the backlog of 2^31 reached libuv |

The test-timer kind rows fail on main too: start, stop and again raised
something else (start from its record mutator, stop with `invalid memory
reference`), repeat and set-repeat returned.

**The close sweep's stale calls on the freed block**, at fuel 10 (11 for
the signal starts):

| Verb | macOS | glibc |
|---|---|---|
| `uv-timer-start!` | `invalid memory reference` | the same |
| `uv-timer-stop!` | `invalid memory reference` | returned |
| `uv-timer-again!` | libuv's EINVAL | returned |
| `uv-timer-repeat`, `uv-timer-set-repeat!` | returned, reading and writing the freed block | the same |
| `uv-signal-stop!` | returned | the same |
| `uv-listen!` | libuv's EINVAL | the same |
| `uv-tcp-nodelay!`, `uv-tcp-keepalive!` | `ENOTSOCK` | returned |
| the signal starts | `null-handle-pointer` at 11 | the same |

**Made after the change, not before.** The strict oracle calls a verb that
returns after the change wrong, though on main it could also have made its
call before the expiry. A probe (scratchpad `g2/made-probe.sps`) asked
libuv at each expiry whether the timer start, the signal start or the
listen had already made its call (the target active), and after the
resume whether the new handle at the freed address (reuse) or the target
(handoff) was. On both platforms, every run that returned had not made its
call before the change, and its handle was active after it: the new
handle in the reuse runs, the handed-off target in the handoff runs. On
the fixed verbs no run returned.

## After the fix

Every split run is refused, every dropped run leaves the handle whole or
untouched and every counter as it found it, and the new handle took the
freed address in every expired run. The same maps on macOS and glibc; each
new verb is refused at fuels 1–9 and untouched at 10, the signal starts at
1–13 and 14. macOS restarted one reuse run for a missed landing in each
run, main's and the fix's; glibc none. Bytes per call (`uv-meter`'s
fewest of 64, scratchpad `g2/meter.sps`): 0 for every one of these verbs,
on main and after.

## Mutants

Driver and base as in part one (scratchpad `g2/mut/`: `mutants.py`,
`window.py`, `window2.py`, `window3.py`, `harness.py`). The unmutated copy
passes. Of the 33 source mutants, 19 are killed by name, 12 are
equivalent in the committed code and killed once a window is opened
(below), and 2 are uncovered.

| Mutant | Change | Result |
|---|---|---|
| HC1 | `handle-call!`'s step uses `open-handle-ptr` | survived: **equivalent**, below |
| HC2 | `handle-call!` reads the pointer just before the step | survived: **equivalent** |
| HC3 | `handle-call!`'s `one-step` → `begin` | **killed**: reuse, handoff, close, close-reach |
| HC4 | `handle-call!` ignores libuv's errno | **killed**: test-timer's "uv-timer-again! on a never-started timer surfaces libuv's EINVAL" |
| TS1 | the timer start's step uses `open-handle-ptr` | survived: **equivalent** |
| TS2 | the timer start reads the pointer just before the step | survived: **equivalent** |
| TS3 | the timer start's `one-step` → `begin` | **killed**: reuse, handoff, close, close-reach |
| TS4 | the timer start stores its callback before the step | survived: **equivalent** |
| TS5 | the timer start stores its callback on a refusal too | survived: **uncovered**, below |
| TS6 | no upper bound on a timer interval | **killed**: the out-of-range row |
| TS7 | the bound inclusive | **killed**: the out-of-range row |
| TS8 | the bound one too low | **killed**: the largest-number row |
| TR1, TSR1 | the repeat's and set-repeat's steps use `open-handle-ptr` | survived: **equivalent** |
| TR2, TSR2 | they read the pointer just before the step | survived: **equivalent** |
| K1 | no kind check on the timer verbs | **killed**: test-timer's five kind rows (and its two close-sweep reach rows) |
| K2 | the kind checked before `require-handle` | **killed**: test-timer's five non-handle rows |
| SS1 | the signal start's step uses `open-handle-ptr` | **killed**: handoff |
| SS2 | the signal start reads the pointer before the step | **killed**: reuse, handoff, close, close-reach |
| SS3 | no mode check in the step | **killed**: other-mode, other-mode reach; test-signal's mode rows |
| SS4 | the mode check inverted | **killed**: the same, and test-signal's EV-6 |
| SS5 | the callback and mode stored before the step | **killed**: drop, other-mode, other-mode reach; test-signal's mode rows |
| SS6 | the mode fixed after the step | survived: **equivalent** |
| SS7 | the callback and mode stored on a refusal too | survived: **uncovered** |
| L1 | the listen's step uses `open-handle-ptr` | survived: **equivalent** |
| L2 | the listen reads the pointer just before the step | survived: **equivalent** |
| L3 | the listen stores its callback before the step | **killed**: the listen-refusal row (the drop row only with a window, below) |
| L4 | the listen stores its callback on a refusal too | **killed**: the listen-refusal row |
| L5, KA1 | no upper bound on the backlog, on the keepalive delay | **killed**: the out-of-range row |
| L6, KA2 | each bound one too low | **killed**: the largest-number row |

SS1 and SS2 die where TS1 and TS2 survive because the signal start can
trap between its entry check and its step, where it reads the signal
(`watch-symbol->int`): its sweeps run four fuels longer than the others'.
The listen's `require-callback` in the same place adds none (the listen and
the timer stop are both refused at 1–9), and L1 and L2 survive.

**The equivalent ones, checked with a window.** In every other verb here
nothing between the entry check (`require-open-*`) and the step can trap,
so no engine expires there: the step's own owner and open checks, a
pointer read just before it, and a store just before or after it cannot be
split from the entry check today. Each was run again with a loop of three
engine ticks opened at that point (`window.py`, `window2.py`,
`window3.py`). With the window alone the suite passes, each sweep three
fuels longer. With the window:

| Mutant | Result |
|---|---|
| W-HC1, W-TS1, W-TR1, W-TSR1, W-L1 (owner) | **killed**: handoff |
| W-HC2, W-TS2, W-TR2, W-TSR2, W-L2 (pointer before the step) | **killed**: reuse, handoff, close, close-reach |
| W-TS4, W-L3 (store before the step) | **killed**: drop (and W-L3 the listen-refusal row) |
| W-SS6 (mode after the step) | **killed**: reuse, handoff, other-mode, drop, close, close-reach |

So the steps hold these properties whatever comes to stand between the
entry check and the step, and the sweeps catch their loss the moment
something does.

**The uncovered ones.** TS5 and SS7: libuv refuses `uv_timer_start` only
for a closing handle or no callback, and `uv_signal_start` only for signal
0 or a signal `sigaction` will not take. The step checks the first, the
callback entry is never null, and the signal vocabulary has neither. No
input reaches a refused start of either, so where its store sits cannot be
seen. The listen's (L4) can, and is held.

**The harness's own mutants.**

| Mutant | Change | Result |
|---|---|---|
| H1 | the drop oracle accepts only the state the run found | **killed**: drop, drop reach (an untouched start leaves the whole state) |
| H2 | nothing observed | survived on the committed suite: a guard. With SS5 as well, the drop row passes, which SS5 alone fails |
| H3 | the mode change does nothing | **killed**: other-mode, other-mode reach |
| H4 | the mode change starts the same mode | **killed**: the same |
| H5 | a timer's landing takes TCP-sized blocks | survived on both platforms, twice on glibc: a freed timer block comes back to the next timer without the fill or the hunt |

## Gates

- macOS: `make test` (18.5 s), `make test-threading`, `make check-purity`,
  `make test-memory` (ASan; handle-steps 21 rows).
- Debian 12 aarch64 (the Valgrind image), vendored: `make test`, `make
  check-memory-gate`, `make test-memory`.

## Part two: the review's follow-ups

PR #105's review (2026-10-09, /code-review xhigh) found nine things. Five
are fixed here, one went to #102 as a comment, and three are left.

- **The largest-backlog row listened on every interface.** Unbound, a
  listening client is bound by the kernel to `0.0.0.0` (measured: its
  sockname answered `0.0.0.0` and an ephemeral port). Both listen rows now
  bind the client to `127.0.0.1` first, and its sockname answers
  `127.0.0.1`.
- **The suite's header claimed two defects main never showed**: a split
  signal start starting the signal "in a mode no longer its own", and a
  drop leaving a signal started with no mode fixed. It now says what the
  sweeps saw: the start returned normally where it owed
  `'signal-mode-fixed`, and a drop left the callback stored and nothing
  started.
- **A verb that does nothing passed the drop sweep.** Its `whole` state is
  computed from the code under test, so a verb that silently did nothing
  agreed with itself. A row now holds each verb's whole state to what the
  verb promises (`promised-wholes`). A tighter verdict for untouched runs
  (left must equal whole) was tried and dropped: an untouched run executes
  the same code as the reference call, so no mutant could break it.

  | Mutant | Committed suite | With the row |
  |---|---|---|
  | R2: the listen stores no callback | passes | **killed**: the promised-state row |
  | R4: the set repeat writes nothing | passes | **killed**: the promised-state row |
  | R1: the timer start never arms | not run | **killed**: the promised-state row, and the reuse, handoff and close rows with their reach rows (its sweep's fuels moved), and drop reach |
  | R3: a oneshot start fixes `'continuous` | not run | **killed**: the promised-state row, other-mode, other-mode reach |

- **The signal start's new error order was stated only in prose.**
  tests/test-signal.sps now holds it: a start in the fixed-other mode
  whose callback is no procedure is refused with
  `'on-signal-not-a-procedure`. It fails on main, which answered
  `'signal-mode-fixed`, and R5 (the entry mode check restored) fails it.
- **The verbs now return nothing where they returned 0** (`uv-check`
  answered its rc). docs/api.md types them as unspecified, as it does
  #101's verbs, which return nothing too. The PR now says so.
- **#102** gained a comment listing these verbs' refusals, which read the
  owner after the step as well.

Left, as the review's lowest: the store-on-success step written out three
times beside `handle-call!`, `uv-timer-set-repeat!`'s bound missing from
its row in docs/api.md, and the C type limits written as literals.

Gates for the follow-ups: macOS `make test`, and `make test-memory` (ASan)
on test-handle-steps and test-signal; on Debian 12 aarch64, both suites
plain and under `make test-memory` (Valgrind, 0 bytes definitely lost in
each suite's own process).

# The loop queries as one step (#86, part three)

2026-10-09. `uv-stop!`, `uv-now`, `uv-loop-alive?` and `uv-update-time!`
each become one interrupt-free step: the loop's open check (and, for
`uv-update-time!`, its owner check) again, the pointer, and the native
call (`loop-call` in loop.sls, over `open-loop-ptr` or `owned-loop-ptr`).
On entry each now checks only that its argument is a loop, since the step
reads the loop's record. `loop-pointer`, which no verb used any more, is
gone. Their sweeps join the handle verbs' in `tests/test-handle-steps.sps`.

## What the suite gained

- **Kinds.** A loop query's target is a new loop with nothing on it, made
  by the run. Its close is a teardown, its reuse a teardown and then a new
  loop that takes the freed block (the landing hunts with blocks of
  `uv_loop_size`), and its handoff hands the target loop itself, not
  `h-loop`. The run's finish tears down both loops.
- **Sweeps.** Reuse and close for all four, and handoff for
  `uv-update-time!` only: the other three are loop-thread-only by
  contract, unchecked (docs/api.md, ADR-0019's scope boundary). The loop
  reuse sweeps run before the landing witness row, which now covers them.
- **No drop sweep.** A query holds nothing and makes one native call, so a
  drop leaves it not begun or finished whatever the code; no mutant could
  fail one.
- **test-loop.sps:** `uv-stop!`, `uv-now` and `uv-loop-alive?` refuse a
  non-loop by name (only `uv-update-time!` had that row), and
  `uv-update-time!` on a closed loop another thread owns is refused as
  closed, holding the order the step now decides.

## On main (63b3164)

Run first against main's `src/`, on macOS and on glibc 2.36 (the Valgrind
image): four rows fail by name on both, with the same fuel maps.

| Row | macOS and glibc |
|---|---|
| loop reuse: never reaches the new loop | fails: each query returns after the change at fuel 9; `uv-update-time!` raises `null-loop-pointer` at 9 and returns at 10 |
| loop handoff: `uv-update-time!` refused | fails: returns at fuel 10 |
| loop close: refused | fails: each returns at fuel 9 (`uv-update-time!` raises `null-loop-pointer` there) |
| loop close reach | fails |

The loop reuse reach row and the landing witness pass on main: every
query is refused at 1–8 and the new loop took the freed address.

**What the stale calls did** (scratchpad `g3/split-probe.sps`, macOS, the
same fuels): after a reuse, `uv-stop!` left the new loop's stop flag at 1
(`uv_loop_t` offset 48) and `uv-update-time!` moved the new loop's cached
now, so each made its call on the new loop after the change, not before
the expiry; `uv-now` and `uv-loop-alive?` returned without raising. After
a teardown alone, `uv-loop-alive?` answered `#t` for a loop with nothing
on it.

## After the fix

Every split run is refused, `&uv-handle-closed` for the loop or
`&uv-wrong-thread` after the handoff, and the new loop took the freed
address in every expired run. Each query is refused at fuels 1–8 and
untouched at 9, on both platforms. On macOS the first loop reuse run
(`uv-stop!`, fuel 1) misses its landing once and lands on its restart, in
every suite run, so the restart count reads 2 (the handle sweeps' one, as
in part two, and this one); glibc restarts none. Bytes per call (fewest of
64, scratchpad `g3/meter.sps`, with a 16 B cons as the meter's live
control): 0 for each query, on main and after.

## Mutants

Driver as in part two (scratchpad `g3/mut/`: `mutants.py`, `window.py`,
and `l2b.py` for L2b and W-L2b), on a copy of the committed `src/` and
`tests/`. Of the 20 source mutants,
14 are killed by name, 5 are equivalent in the committed code, each
killed once a window is opened, and 1 is equivalent in any build.

| Mutant | Change | Result |
|---|---|---|
| L1 | `loop-call`'s `one-step` → `begin` | **killed**: loop reuse, handoff, close, close reach |
| L2 | `loop-call` takes the pointer (`ptr-of`) just before the step | **killed**: loop reuse, close, close reach |
| L2b | the step checks the loop, but uses the pointer field read just before it | survived, with a window too: **equivalent in any build**, below |
| L3a–d | each query's open check on entry (`require-open-loop`) and none in the step, main's shape (`uv-update-time!` keeps its owner check in the step) | survived: **equivalent**, below |
| L4a | `uv-update-time!`'s step uses `open-loop-ptr` | **killed**: loop handoff and its reach; test-loop's wrong-thread rows |
| L4b | `uv-update-time!`'s owner and open checks on entry, as main, and `open-loop-ptr` in the step | survived: **equivalent** |
| L5 | `'wrong-thread` falls through to `step-refusal` | **killed**: loop handoff and its reach; test-loop's "naming who, owner and caller" |
| L6a–d | no `require-loop` on entry, one query each | **killed**: test-loop's non-loop rows (the step raises from the record accessor with interrupts disabled, so later engine rows fail after it) |
| L7 | `uv-update-time!` asks for the owner before the open check | **killed**: test-loop's "on a closed loop another thread owns is refused as closed" |
| L8 | `loop-call` answers a refusal instead of raising it | **killed**: every loop sweep and reach row; test-loop's use-after-close rows, its wrong-thread row and the closed-before-owner row |
| L9a–d | the step takes the pointer without the open check, entry unchanged | **killed**: test-loop's use-after-close row for that query (`null-loop-pointer`), and for `uv-update-time!` the closed-before-owner row |

L2 dies where part two's pointer-before-the-step mutants survived: an
engine can expire between `open-loop-ptr`'s open check and the step,
where nothing could trap between part two's entry checks and their steps.
L2b reads the field early but checks the loop in the step, and survives
even with a three-tick window between the read and the step: the step
uses the early pointer only when it finds the loop open, and an open
loop's pointer never changes.

**The equivalent ones, checked with a window.** Nothing between
`require-open-loop` (or `require-loop-thread`) returning and the step can
trap, so a check kept there is in effect inside the step today. Each
survivor was run again with a loop of three engine ticks opened between
the entry check and `loop-call` (`window.py`). With the window alone, in
all four queries (W0), test-handle-steps and test-loop pass. With the
window:

| Mutant | Result |
|---|---|
| W-L3a–d (open check on entry only) | **killed**: loop reuse, close, close reach |
| W-L4b (owner check on entry only) | **killed**: loop handoff |

**The harness's own mutants.**

| Mutant | Change | Result |
|---|---|---|
| HL1 | a loop's landing hunts with TCP-sized blocks | survived on macOS (a freed loop block comes back to the next loop without the hunt); **killed** on glibc: the landing witness, with 3 restarts |
| HL1b | a decoy takes the loop size's freed block before the new loop | **killed** on both: the landing witness (96 restarts on glibc) |
| HL2 | the run's finish leaves the new loop open | **killed**: loop reuse and its reach (the loop counted as left behind) |
| HL3 | the loop handoff hands `h-loop`, not the target | **killed**: loop handoff and its reach; the suite then exits 255 from rows that find `h-loop` owned elsewhere |

## Gates

- macOS: `make test`, `make test-threading`, `make check-purity`, `make
  test-memory` (ASan, 25 suites).
- Debian 12 aarch64 (the Valgrind image), vendored: `make test`, `make
  check-memory-gate`, `make test-memory`.

## Part three: the review's follow-ups

PR #107's review (2026-10-09, /code-review xhigh) found seven things. Two
are fixed here, one went to #102 as a comment, one was refuted by
measurement, and three are left.

- **`uv-update-time!` now builds its wrong-thread refusal after its
  step**, reading the owner again (#102's defect), where
  `require-loop-thread` built it from the owner it had just compared. #102
  gained a comment adding it, with the six copies of the
  `'wrong-thread`/`step-refusal` mapping its fix will have to change.
- **`require-loop-thread`'s comment called it "the single affinity
  predicate".** It is the entry check now, and the comment says so, and
  that the steps check again.
- **This log named only `mutants.py` and `window.py`;** L2b and W-L2b ran
  from `l2b.py`, which it now names.
- **Refuted: "the fill does nothing for loops".** The review took a loop
  block (1072 B on macOS) to be above glibc's tcache limit (1032 B), so
  that only the hunt could land it. On Linux `uv_loop_size` is 856 B, and
  the fill counts (scratchpad `g3/nofill/`, the loop fill skipped, with
  each restart printed):

  | Platform | With the fill | Without it |
  |---|---|---|
  | glibc 2.36, 2 and 3 runs | no restart | the first loop reuse run (`uv-stop!`, fuel 1) restarts once, every run |
  | macOS, 3 and 5 runs | `uv-stop!` restarts once at fuel 1 | it restarts once at fuel 2 |

  So the fill stays, for loops as for handles.

Left: the `'wrong-thread`/`step-refusal` mapping written out a sixth time
(#102's fix is where to fold it); the loop sweeps living in a suite named
for handles, since moving them means copying its harness (#103); and
`loop-call`'s rule that its native never answers a symbol, held only by a
comment, which no native today can break (each answers void, an int or an
unsigned-64).

# The stream and process verbs' owner (#86, part four)

2026-10-09. The steps of the six stream verbs (`uv-write!`, `uv-write*!`,
`uv-shutdown!`, `uv-read-start!`, `uv-read-stop!`,
`uv-stream-write-queue-size`), `uv-process-kill!` and `uv-process-pid`
take their pointer from `owned-handle-ptr` instead of `open-handle-ptr`,
so each checks again that this thread owns the loop, as its entry check
(`require-open-handle`) does. Their sweeps stay in their own suites:
`tests/test-stream.sps` (#53) and `tests/test-process-steps.sps` (#71).

## What the suites gained

- **test-stream.sps:** a handoff sweep for each of the six verbs. At the
  expiry the run hands `sw-loop` to another thread id, resumes the verb,
  and hands the loop back; the stream stays open. A run not made before
  the handoff must raise `&uv-wrong-thread` (`'refused`), and one made
  before it must return with its effect landed (`'made-before-handoff`).
  The split run became `close-run` and `handoff-run`, sharing the engine,
  the no-expiry verdict and the residue check.
- **test-process-steps.sps:** a handoff mode in `split-run`, swept for
  `uv-process-kill!` with SIGTERM and `uv-process-pid`. The process stays
  open, so a kill made after the handoff reaches only its own child, and
  SIGTERM tells a kill that was made from one that was not: a refused run
  must leave the child's fate `(0 #f)`.
- **test-source-rules.sps, rule 8:** the top-level definitions in `src/`
  that call `open-handle-ptr` are exactly `owned-handle-ptr`,
  `begin-close!` (`uv-close!`'s step, loop-thread-only by contract and
  unchecked), `stdio-refusal` (`uv-spawn!`'s step checks its loop's owner
  first, and its stdio handles are on that loop) and `uv-accept!` (its
  client's construction checks the owner of the server's loop). It holds
  the claim that a verb checking the owner on entry checks it again in
  its step, where a comment would have stated it. (The review below
  widened it to every route to a handle's pointer.)

## On main (6e848d3)

Run first against main's `src/`, on macOS and on glibc 2.36 (the Valgrind
image, aarch64): the same rows fail by name on both, with the same fuel
maps.

| Row | macOS and glibc |
|---|---|
| test-stream: a stream verb split by its loop's handoff is refused | fails: `uv-write!` returns at fuel 12–17, `uv-write*!` at 13–31, `uv-shutdown!` at 10–12 |
| test-process-steps: split by its loop's handoff | fails: `uv-process-kill!` returns at fuel 10–12, and its child dies of SIGTERM |
| test-source-rules: rule 8 | fails, naming the eight verbs' definitions (`uv-read-start!`'s step is in `start-reading!`) |

The reach rows pass on main: each sweep is refused at fuel 1 and runs its
verb to the end. `uv-read-start!` (refused 1–10), `uv-read-stop!`,
`uv-stream-write-queue-size` and `uv-process-pid` (each refused 1–9) show
no window: nothing between their entry check and their step can trap.

## After the fix

Every handoff run is refused with `&uv-wrong-thread` until the step, and
untouched after it: `uv-write!` refused 1–17, `uv-write*!` 1–31,
`uv-shutdown!` 1–12, `uv-read-start!` 1–10, `uv-read-stop!` and
`uv-stream-write-queue-size` 1–9, `uv-process-kill!` 1–12 with its child
unsignalled, `uv-process-pid` 1–9. The same on both platforms. Bytes per
call (fewest of 64, scratchpad `g4/meter.sps`, with a 16 B cons as the
live control), the same on main and after: `uv-write!` 144, a one-segment
`uv-write*!` 192, `uv-shutdown!` 128, a read start and stop together 0,
and 0 for `uv-read-stop!`, `uv-stream-write-queue-size`,
`uv-process-kill!` and `uv-process-pid`.

## Mutants

Driver as in part three (scratchpad `g4/mut/`: `mutants.py`,
`run_mutants.py`), on a copy of the branch's `src/` and `tests/`. A
source-rule suite runs from the copy's root, since it reads `src/` from
its working directory: run from the repo, rule 8 first read the repo's
own `src/` and let every mutant through. On macOS; the four equivalent
mutants and their windows also on glibc 2.36, with the same results.

| Mutant | Change | Result |
|---|---|---|
| S1 | `uv-write!`'s step takes `open-handle-ptr` | **killed**: test-stream's handoff row; rule 8 |
| S2 | the same for `uv-write*!` | **killed**: the handoff row; rule 8 |
| S3 | the same for `uv-shutdown!` | **killed**: the handoff row; rule 8 |
| S4 | the same for `uv-read-start!` | survived the sweeps: **equivalent today**, below; **killed** by rule 8 |
| S5 | the same for `uv-read-stop!` | the same as S4 |
| S6 | the same for `uv-stream-write-queue-size` | the same as S4 |
| P1 | the same for `uv-process-kill!` | **killed**: test-process-steps's handoff row; rule 8 |
| P2 | the same for `uv-process-pid` | the same as S4 |

**The equivalent ones, checked with a window.** A loop of three engine
ticks opened after the entry check (`(let spin ((i 0)) (when (< i 3) (spin
(+ i 1))))`, as in parts two and three). With the windows alone, in all
four verbs (W0), test-stream (42 rows) and test-process-steps (14) pass.
With the window and `open-handle-ptr` again, W-S4, W-S5, W-S6 and W-P2
are each **killed** by their suite's handoff row.

**The harness's own mutants.**

| Mutant | Change | Result |
|---|---|---|
| H1 | test-stream's handoff run never hands the loop over | **killed**: the handoff row and its reach |
| H2 | test-process-steps's handoff mode never hands the loop over | **killed**: the handoff row and its reach |
| H3 | rule 8 counts `open-handle-ptr`'s own definition as a caller | **killed**: rule 8 |

## Gates

- macOS: `make test`, `make test-threading`, `make check-purity`, `make
  test-memory` (ASan, 25 suites).
- Debian 12 aarch64 (the Valgrind image), vendored: `make test`, `make
  check-memory-gate`, `make test-memory`. test-stream's and
  test-process-steps's own processes have 0 bytes definitely lost and
  nothing suppressed.
- The engine census in `tests/test-sweep.sps` failed `make test` first:
  test-stream's split runs now make their engine in `start-engine`, which
  the census lists in place of `split-run`.

## Part four: the review's follow-ups

PR #109's review (2026-10-09, /code-review xhigh) found eight things.
Four are fixed here, one went to #102 as a comment, and three are left.

- **Rule 8 counted only calls.** `calls-of` counts the lists headed by a
  name, so `open-handle-ptr` passed as a value, as loop.sls passes
  `open-loop-ptr` to `loop-call`, escaped it. It now counts every mention
  (`mentions-of`).
- **It named the definitions, not how often each names the helper.** A
  second `open-handle-ptr` in `uv-accept!` passed. Each definition now
  carries its count.
- **Its row said every step, but it held only `open-handle-ptr`.** A step
  that read the pointer field itself passed. Rule 8 now pins each route
  from a handle record to its pointer: `open-handle-ptr`, the field's
  accessor `handle-ptr` (eight definitions, each with its reason in the
  rule's header) and `handle-pointer` (one). A definition with a
  parameter named `handle-ptr`, as the dispatchers and native.sls have,
  shadows the accessor and is not counted.
- **Comments said every step checks the owner with `owned-handle-ptr`.**
  `uv-close!`'s step checks none, and `uv-accept!`'s and `uv-spawn!`'s
  check the owner of the loop they make something on. `require-open-handle`'s
  comment, the ADR and AGENTS.md now say so.
- **#102:** the eight verbs now raise `&uv-wrong-thread` from their steps
  through `wrong-thread-refusal`, which reads the owner after the step.
  #102 gained a comment adding them.

Mutants, on a copy of the fixed tree (scratchpad `g4/mut/mutants2.py`),
each run against the fixed rule and, for R1–R3, the committed one:

| Mutant | Change | Fixed rule | Committed rule |
|---|---|---|---|
| R1 | `uv-stream-write-queue-size`'s step takes `((values open-handle-ptr) stream)` | **killed**: the `open-handle-ptr` row | passes |
| R2 | `uv-read-stop!`'s step reads `handle-ptr` after its own open test | **killed**: the pointer-field row | passes |
| R3 | `uv-accept!` names `open-handle-ptr` twice | **killed**: the `open-handle-ptr` row (count 2) | passes |
| R4 | no definition counts as shadowing `handle-ptr` | **killed**: the pointer-field row lists the dispatchers and native.sls | — |
| R5 | `uv-stream-write-queue-size`'s step takes `handle-pointer` | **killed**: the `handle-pointer` row | — |

Left: `open-handle-ptr` keeps its name, though the owner-blind helper is
now the exception; test-stream's `handoff-run` repeats `close-run`'s
skeleton; and `me` and `other-thread` are now defined in four suites
(#103's territory).
