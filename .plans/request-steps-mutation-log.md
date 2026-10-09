# Request verbs as one step (#85): evidence and mutation log

2026-10-09. `uv-tcp-connect!`, `uv-getaddrinfo!`, `uv-getnameinfo!` and
`uv-cancel!` each become one interrupt-free step: owner and open checks,
pointer, allocation, fill, registration, count and native call. The sweeps
are in `tests/test-request-steps.sps`.

## On main (27d84bb), macOS

The suite was written first and run against main's verbs. Each sweep runs
its verb in an engine at fuel 1, 2, …. It changes the world at the first
expiry, then resumes the verb or drops it.

Fuel maps (verdict, first fuel, last fuel):

**Reuse.** At the expiry the run closes the client or tears the loop down,
makes a new one (macOS gives it the freed address), then resumes.
- `uv-tcp-connect!`: refused 1–9; `null-handle-pointer` 10–52; **a call
  after the change reached libuv** 53–54; untouched 55.
- `uv-getaddrinfo!`: refused 1–9; `null-loop-pointer` 10–69; **reached
  libuv** 70–80; untouched 81.
- `uv-getnameinfo!`: refused 1–9; `null-loop-pointer` 10–64; **reached
  libuv** 65–66; untouched 67.

**Handoff.** The loop's owner is set to another thread.
- Every run past the entry check made its call after the handoff:
  - connect 10–54;
  - getaddrinfo 11–80;
  - getnameinfo 11–66.

**Drop.** What each run left behind:

| Verb | Fuels | Left |
|---|---|---|
| connect | 30–46 | a block |
| | 47 | a block and a registry entry |
| | 48–54 | a block, a registry entry and a `connect-req` count |
| getaddrinfo | 56–63 | a block |
| | 64 | a block and a registry entry |
| | 65–80 | a block, a registry entry and a request count |
| getnameinfo | 42–58 | a block |
| | 59 | a block and a registry entry |
| | 60–66 | a block, a registry entry and a request count |

**Close, teardown.** These sweeps stop at their first wrong run, since a
wrong run here may have handed libuv freed memory. Connect and both
lookups were refused at fuel 10 as `null-handle-pointer` or
`null-loop-pointer`, not `&uv-handle-closed`.

**uv-cancel!** These ran with the other three verbs already fixed.
- **Completion split.** At the expiry the run:
  1. frees seven same-size blocks, which fills glibc's thread cache;
  2. steps the loop until the lookup completes;
  3. takes the freed address back with zeroed blocks from the binding's
     allocator.

  Result: answered `#f` 1–8; at **fuel 9, `uv_cancel` was handed the
  zeroed block and libuv answered EINVAL**; untouched 10.
- **Handoff.** Refused 1–8; at **fuel 9 the cancel cancelled (`#t`) after
  the handoff**; untouched 10.

Seven rows failed by name, three passed: the reach rows for reuse, handoff
and drop.

## After the fix, macOS

Every split run is refused. No new client or loop is touched, every
dropped run leaves the registry and every counter as it found them, and a
resumed cancel answers `#f`.

| Verb | Refused or dropped | Untouched |
|---|---|---|
| connect | fuels 1–27 | 28 |
| getaddrinfo | fuels 1–53 | 54 |
| getnameinfo | fuels 1–39 | 40 |
| cancel | fuels 1–9 | 10 |

No run landed after a step. The cancel's zeroed block took the freed
address in every expired run. The rest of `make test` passes.

**Bytes per call:** the fewest of 64, `(+ (bytes-allocated)
(bytes-deallocated))` with collections held off, the same `build/` for both
legs, three runs each, identical.

| Verb | main | after |
|---|---|---|
| `uv-tcp-connect!` | 848 | 240 |
| `uv-getaddrinfo!` | 720 | 400 |
| `uv-getnameinfo!` | 864 | 240 |
| `uv-cancel!` | 0 | 0 |

## The cancel's entry check

The first fix kept `uv-cancel!`'s entry owner check (`require-loop-thread`)
and added the same check inside the step. The mutant removing the step's
check (X1) survived. The entry check sat directly before the step, with no
trap check between them, so the step's check could never refuse a call the
entry check had passed.

The entry check is gone, and the step's check is the only one. X1 then
failed two suites by name: the handoff sweep, and test-constructor-owner's
two cancel refusal rows. This is the reason #79 gave the constructors no
entry check.

The lookups and connect keep their entry checks. Between those and their
steps lie validations with trap checks (C1, D1 and D2 below), and the entry
checks decide what a caller is told first: test-constructor-owner's
"bad arguments from the wrong thread" rows.

## Mutants

Each mutant is an exact single-match replacement in a fresh scratch copy
(`src/`, `tests/`, the Makefile, `build/` linked). The named suites ran from
the copy. Driver: the session scratchpad's `rs-mut/mutants.py`.

| Mutant | Change | Result |
|---|---|---|
| C1 | connect's step uses `open-handle-ptr`, no owner recheck | **killed**: handoff sweep |
| C2 | `owned-handle-ptr` checks only the pointer, not the state | **killed**: reuse, close and close-reach rows |
| C3 | connect's `one-step` → `begin` | **killed**: reuse, handoff, drop, close, close-reach |
| C4 | a bad address keeps connect's block | **killed**: "a connect to an address libuv cannot parse … its block freed" |
| C6 | `'wrong-thread` raised as a generic step refusal | **killed**: handoff sweep |
| S1 | `submit-request!`'s failure keeps the registration | **killed**: EALREADY row |
| S2 | … keeps the count | **killed**: EALREADY row |
| S3 | … keeps the block | **killed**: EALREADY row |
| S4 | … leaves the record's pointer | survived: **equivalent**. The refused record is dropped with the refusal; nothing reads it. |
| S5 | a registry refusal keeps the block | survived: **uncovered**. A request block is fresh from the allocator, so the registry never refuses it (also run against test-stream: passes). |
| D1 | getaddrinfo's step uses `open-loop-ptr` | **killed**: handoff sweep |
| D2 | getnameinfo's step uses `open-loop-ptr` | **killed**: handoff sweep |
| D3 | getaddrinfo's `one-step` → `begin` | **killed**: reuse, handoff, drop, teardown, teardown-reach |
| D4 | getnameinfo's `one-step` → `begin` | **killed**: the same five rows. The process then aborted (SIGABRT) after the rows: the stale lookup on a freed loop let through at teardown fuel 40 completed later. |
| D5 | getnameinfo's bad address keeps the block | **killed**: the getnameinfo bad-address row |
| D6 | the hints refusal keeps the block | survived: **uncovered**. hint-writes makes every value from the platform's constants, so no input reaches it (test-dns also passes). |
| D7 (demo) | hint-writes drifts: flags become 2^40 | every hinted lookup in test-dns refused by name, `'hint-not-a-c-int`. The suite ran to its end (79 pass, 71 fail), interrupts enabled. |
| N1 | `try-fill-sockaddr!` without its port check | **killed**: "try-fill-sockaddr! answers each refusal" |
| N2 | `try-c-int-set!` without its range check | **killed**: the try-c-int-set! value row |
| N3 | `try-c-int-set!` without its address check | **killed**: the try-c-int-set! address row |
| N4 | `uv-getaddrinfo-native` without its C-string check | **killed**: its refusal row (libuv's EINVAL instead) |
| X1 | cancel's step without the owner check | **killed**: handoff sweep and reach, and test-constructor-owner's two cancel refusals |
| X2 | cancel reads its pointer just before the step | survived: **equivalent**. Nothing between the read and the step can expire. |
| X3 | cancel's `one-step` → `begin` | **killed**: completion and handoff rows |
| X4 | cancel tells EBUSY with a call after its step | survived. Not a defect: it probes the handoff oracle's premise, that no expiry lands after the step. It produced no false failure in these runs. |

One harness note: an earlier driver applied its mutants with `python3`
inside the Ubuntu image, which has none, and every "mutant" ran
unmutated. Mutants are made on the host now, and a setup failure is
reported as such.
