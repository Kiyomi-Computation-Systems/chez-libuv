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
