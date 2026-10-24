# Changelog

All notable changes to this project are documented here. This project follows
[Semantic Versioning](https://semver.org).

## Unreleased

### Changed

- **A release's package leaves out the repository's own records.**
  0.11.0's package, on Akku and as GitHub's tarball, held the design
  records and plans (137 files), the early experiments (35), the
  instructions for coding agents, the contributor guide and the CI
  configuration. `akku install` unpacks all of it into each consumer's
  `.akku/src/chez-libuv/`. `.gitattributes` now marks them export-ignore,
  so `git archive` of a tag, which the Akku archive and GitHub both serve,
  leaves them out. Everything else still ships.
  - The Makefile reads the Chez floor from CI's workflow only where that
    file exists. Without that, every make in a package, the install
    hook's included, printed `sed: can't read .github/workflows/ci.yml`.
    The two Docker targets that need the floor refuse by name there.
  - `make check-archive`, run by `make test` and CI, archives the working
    tree and fails if a left-out path would ship, or if any other tracked
    file would not. It also fails if the install hook's makes, its facts
    and dry runs of its builds, differ between the package and the same
    tree with the left-out paths.
  - The Guix development container's manifest lists `tar`, which
    `make check-archive` runs.

### Fixed

- **`make check-site-deps` failed three of its rows on macOS** and passed
  on Linux. `scripts/fetch-akku-lock` was right on both and is unchanged;
  the test was not.
  - Its wrong-sha256 fixture used a sed form BSD sed rejects, so the lock
    pinned an empty string.
  - Its "without xz" row expected a failure that macOS's tar never has: it
    reads xz itself. The row now asserts what the host's tar can do, and a
    new row has every platform refuse an archive tar cannot read.
  - Under bash 3.2, macOS's `/bin/sh`, the row's PATH without xz outlived
    it. That PATH now stays in a subshell, and a check fails if it leaks.
  - The empty-archive row compared against a baseline taken before the
    "without xz" row ran. It now takes its own.

## 0.11.0 — 2026-10-15

This release lets Akku install chez-libuv. An install hook, which
`akku install` runs, builds the shim and `config.sls` in the project that
depends on chez-libuv; until now an Akku install could not load. The hook
is new, so this is a minor release. No library changed: nothing in `src/`
differs from 0.10.0, and a checkout's release shim is the same as
0.10.0's, byte for byte on macOS. The README and the docs site now say
what chez-libuv is and is not, and the site links to the source.

### Added

- **Akku can install chez-libuv for a project that depends on it.** Until
  now `akku install` landed the libraries but no shim and no `config.sls`,
  so the import failed with "library (libuv private config) not found". An
  install hook, `scripts/akku-install`, now runs before Akku installs the
  libraries. It builds a release shim into the project's `.akku/ffi`
  against the libuv pkg-config finds, and writes `config.sls` naming it.
  - `akku lock` copies a package's scripts into a project's lock only from
    the Akku index, so for now a project's own `Akku.manifest` runs the
    hook, by path. `docs/installing.md` has the lines, with the entry that
    names chez-libuv's git repository, tag and commit. `Akku.manifest`
    carries the same hook for the index.
  - It needs a C compiler, pkg-config and libuv 1.48.0 or newer, and runs
    on macOS and Linux, in a project whose path holds no spaces and none of
    `$ : % ' " \`, which make cannot take.
  - A failure stops the install under Akku 1.1.1 and later. Under 1.1.0,
    which ignores a script's exit status, the program's first call raises
    the reason and names the hook's log.
  - It does nothing in chez-libuv's own checkout, and leaves alone a
    checkout that `make build` built and that is used as a directory
    dependency.
  - `.akkuignore` now keeps `build/` and `vendor/` out of an install as
    well as `site/`.
  - `Akku.manifest` gains a `description` and a `homepage`, which Akku
    copies into the package's index entry, and a shorter `synopsis`.
  - `make check-akku` installs by both routes and checks each case, under
    whichever Akku runs it. `make akku-facts` prints what the hook reads
    from the Makefile.
  - Release and dev builds keep `-Werror`; the hook turns it off
    (`WERROR=`), since it builds with the consumer's compiler and libuv
    headers.
- **The README and the docs site's front page say chez-libuv is not a
  web server,** but something to build one on, or anything else that
  needs async I/O.
- **The docs site links to the source.** Its top bar has a "Source code"
  link to the GitHub repository, and every page carries a description and
  keywords. Sidebar links underline on hover.

### Fixed

- **The docs site's light/dark toggle did nothing where the browser
  refuses the page storage** (site data blocked, some private modes). The
  page's script threw at its first `localStorage` call, before it wired the
  toggle; the page still followed the system setting. Each call is now
  inside a `try`, so the toggle works for the page's life and is not
  remembered. `tests/site-unit.sps` holds every access to a `try` block.
  The same fix is in chez-cmark-gfm, whose site generator this one copies.

## 0.10.0 — 2026-10-12

This release takes `addrinfo-chain->list` out of `(libuv dns)`. It read
memory at whatever address it was given, and `uv-getaddrinfo!` already
hands its callback the address records. Its removal is why this is a
minor release. `uv-kill!` refuses a pid no C `int` holds: Chez had
wrapped 4294967295 to -1, which signals every process the caller may
signal. It also works now as a process's first call into libuv. The docs
are rewritten as plain-language guides with a checked API reference, and
render as a site. A project that depends on chez-libuv no longer
installs chez-srfi. The release shim compiles to the same code as
0.9.0's.

### Fixed

- **`uv-kill!` refuses a pid outside a C `int`'s range** (#137). libuv
  takes the pid as a C `int`, and Chez's `int` argument also takes the
  unsigned range and wraps it. So 2147483648 reached `kill(2)` as the
  process group -2147483648, and 4294967295 as -1, which signals every
  process the caller may signal. A pid past 2^32 raised a malformed Chez
  condition ("invalid who argument"). Every pid outside -2147483648 to
  2147483647 now raises `&uv-invalid-argument` with reason
  `'pid-out-of-range`, before anything is sent.
- **`uv-kill!` works as a process's first call into libuv** (#137). It
  was the one verb that did not load the native constants first, so as
  the first call it raised `&uv-invalid-argument` with reason
  `'constants-not-initialized` in place of the signal's result. It loads
  them now, as `uv-os-getpid` and `uv-version` do.

### Changed

- **`(libuv dns)` no longer exports `addrinfo-chain->list`** (#137). It
  was never meant for programs: it reads memory at whatever address it is
  given, and any number that is not a live `addrinfo` chain crashes the
  process or answers garbage. `(libuv)` never exported it, and
  `uv-getaddrinfo!` hands its callback the records already. It now lives
  in `(libuv private addrinfo-chain)`, which, like every
  `(libuv private …)` library, is not part of the API and can change in
  any release.
- **`uv-write*!` refuses a list of 2^32 segments or more** with reason
  `'too-many-segments`, before anything is allocated (#139). libuv takes
  the count as an unsigned int. Chez's own check of a larger count raised
  inside the write's interrupt-free step, leaving interrupts disabled,
  and at `--optimize-level 3` it wrapped the count instead.
- **A project that depends on chez-libuv installs neither chez-srfi nor
  chez-cmark-gfm** (#135). Both are development dependencies in
  `Akku.manifest`: the test suites use chez-srfi, and `make site` uses
  chez-cmark-gfm. No library in `src/` imports either. chez-srfi's
  version is exact, so that `akku lock` takes the commit the test suites'
  submodule names. `make check-akku` holds that an Akku install lands
  exactly `src/`'s libraries, 21 of them.
- **Costs.** Every figure the release meter prints is unchanged from
  0.9.0: bytes on the Scheme heap per call, the fewest of 64, the same on
  two runs of each build, measured on Linux x86-64. `call-with-uv-loop`
  takes 1,008 B when its body returns and 1,760 B when the body raises to
  a guard outside; refusals on another thread take 672 B for
  `uv-update-time!` and 688 B for `uv-timer-start!`. The meter covers the
  loop and timer verbs. Time was not measured.

### Notes

- **The docs** (#135, #137). `docs/` is fifteen plain-language pages,
  indexed by `docs/README.md`: installing, a quickstart, loops,
  callbacks, threads, timers, TCP and streams, flow control, processes
  and pipes, signals, DNS, errors, and building and testing.
  `docs/reference.md` has one entry per public binding and replaces
  `docs/api.md`.
  - `make check-reference` fails unless every export has one entry,
    listed under exactly the libraries that export it. It checks that
    each entry is there, not what it says.
  - `make site` renders `docs/` into `build/site/`, through
    chez-cmark-gfm, and `make check-site` checks its navigation, links and
    anchors. `.github/workflows/pages.yml` deploys it on a `v*` tag, once
    GitHub Pages is enabled for the repository.
  - `docs/processes.md` says what 0 and negative pids mean to
    `uv-kill!`, and warns about -1.
- **Shipped files state facts, not their history** (#132, #134). The
  comments in `src/` and `tests/`, the docs, README.org and the build
  files no longer cite issues, plans, dates or releases. About forty
  comments that did not match the code were corrected. `make
  check-history` holds this, and `make test` runs it. README.org is
  rewritten for developers, and a new NOTICE file gives the licences of
  libuv, chez-srfi and Chez Scheme.
- **test-dns no longer depends on winning a race** (#127, #133), which
  was 0.9.0's known failure. Its queued-tail teardown and double-cancel
  rows wait until the threadpool's only worker is inside a hold before
  they queue their lookups, so every cancel finds its lookup queued. The
  hold is compiled only into the dev shim. `check-prod` refuses a release
  shim that exports it, and rule 12 of `tests/test-source-rules.sps`
  holds `check-prod`'s list to the shim's dev-only functions. ADR-0002 is
  amended for it.
- **New checks** (#138, #139):
  - Rule 13 of `tests/test-source-rules.sps` holds every public verb to
    loading the native library before its first native call, or to
    checking its record first. `tests/test-first-call.sps` calls each
    verb that takes no record as a process's first call, and gives each
    other verb a symbol in place of its record, each in a fresh process.
  - Rule 14 holds every caller's number to its C type's predicate before
    it reaches a foreign call. `(libuv private c-types)` defines each
    range once, from `foreign-sizeof`, and the pure suite
    `tests/test-c-types.sps` holds each range's edges. The spawn step's
    memory writes no longer raise inside the step.
- `.plans/release-meter.sps` and `.plans/release-bench.sps` keep the
  programs behind the cost figures, so each release can run them against
  the last (#131).
- Known: the test suites assume a POSIX host (#125).
- The evidence is in `.plans/*-mutation-log.md`, one log per change.

## 0.9.0 — 2026-10-11

This release refuses a run before its thread's C stack runs out. A
continuation that escapes a libuv callback, or an engine dropped inside
one, leaves that run's C frames on the thread's stack for as long as the
thread lives. Enough of them crashed the thread, or on macOS could hang
it, and nothing warned first. Every run the binding makes now measures
the stack first, and short of its floor raises a new condition,
`&uv-stack-exhausted`, which is why this is a minor release. The shim
gains two exports, so run `make build` after upgrading. A raise out of
`call-with-uv-loop`'s body now reaches the guards outside it as itself,
and `&uv-wrong-thread` names the owner its check found.

### Added

- **A run is refused before its thread's C stack runs out** (#94, #126).
  Before every `uv_run` it makes, the binding reads how much C stack its
  thread has left. `uv-run` raises `&uv-stack-exhausted` (`who`,
  `headroom`, `floor`) with less than 128 KiB left. The drain of
  `uv-loop-teardown!`, and so of every `call-with-uv-loop` exit, raises
  it under the name `uv-loop-teardown!` with less than 64 KiB. A refused
  run changes nothing, and the gap between the two floors leaves it room
  to tear its loops down: `call-with-uv-loop` still tears down around a
  `uv-run` that raised it. Where a thread's stack cannot be read, nothing
  is refused.
  - Before, nothing warned. A macOS `fork-thread` thread held 14 escapes
    from callbacks libuv calls while it polls for I/O, or 1,429 from
    timer callbacks, and the next escape faulted. The fault reached
    Scheme as "invalid memory reference", and a program that caught it
    and went on could hang at the next collection (#95). On Linux the
    process died with `SIGSEGV`.
  - Under the check, a macOS `fork-thread` thread's run is refused after
    12 escapes from I/O callbacks, or 1,152 from timer callbacks.
  - A thread refused this way gets its stack back only by ending.
    `docs/api.md`'s loop section says what to do instead.

### Fixed

- **A raise out of `call-with-uv-loop`'s body reaches the guards outside
  it as itself** (#118, #120). R6RS `guard` unwinds to itself before it
  tests its clauses, and when none matches, it re-raises from where the
  body raised, which re-enters the body. `call-with-uv-loop` refuses
  every return into a body it has left, and that refusal raised
  `&uv-handle-closed` in place of the body's condition. So a guard whose
  clauses did not match handed its caller `&uv-handle-closed`, and a
  `uv-error?` guard further out took a user's error for the binding's.
  Against 0.8.0, a body that raised `'boom`, or an `&error`, through such
  a guard arrived as `&uv-handle-closed`; each now arrives as itself.
  The first return into a body left while one of its raises was being
  handled is refused with that raise, and every other with
  `&uv-handle-closed`. `docs/api.md` lists what this costs: a guard whose
  clauses do not match tests them twice, and a handler between that
  guard and the body sees the condition twice.
- **`&uv-wrong-thread` names the owner its check found** (#102, #113). A
  verb checks its loop's owner inside its step and raises once the step
  is over, and the refusal read the owner again to build the condition.
  A loop handed to another thread and back in between made the condition
  name the caller as both `expected` and `actual`. An engine alone did
  that to fifteen verbs: `uv-accept!`, `uv-tcp-bind!`,
  `uv-tcp-getsockname-port`, `uv-tcp-sockname-address`,
  `uv-tcp-peer-address`, the four buffer-size verbs, `uv-tcp-connect!`,
  both signal starts, `uv-write!`, `uv-write*!` and `uv-shutdown!`.
  `expected` is now the owner the check compared against, and the two
  always differ.

### Changed

- **Costs.** Measured on macOS arm64, bytes on the Scheme heap per call,
  the fewest of 64, the same on two runs of each build:

  | Call | 0.8.0 | 0.9.0 |
  |---|---|---|
  | `call-with-uv-loop`, the body returns | 752 | 1,008 |
  | `call-with-uv-loop`, the body raises to a guard outside | 1,344 | 1,760 |
  | `uv-update-time!`, refused on another thread | 640 | 672 |
  | `uv-timer-start!`, refused on another thread | 656 | 688 |

  The first two are #120's handler around the body, and the others #113's
  record of the owner the check compared. The stack check allocates
  nothing. Unchanged: an empty `uv-run` at 16 B; a 0 ms timer started and
  run to its callback, 400 B; a timer made, closed and run to its close
  callback, 928 B; `uv-loop-alive?`, `uv-now`, `uv-update-time!` and a
  timer's start and stop, nothing.
- **Time** (#87, #116, #126). A close and a request completion take the
  registry lock once, where they took it twice, and every run now reads
  its thread's stack first. Measured on macOS arm64 with #116's
  benchmark, release shims, one thread: ns per operation, the median of
  10 rounds alternating the builds, each round the best of 30
  repetitions, with the range. Other work kept the load average at
  45–95, so the figures run high:

  | Operation | 0.8.0 | 0.9.0 |
  |---|---|---|
  | a close | 497 (440–598) | 416 (396–526) |
  | a request completion | 228 (224–264) | 195 (190–227) |
  | an empty `uv-run` | 106 (105–108) | 122 (121–128) |

  Making a timer and firing one are unchanged within their ranges. The
  run's 16 ns are #126's check: run the same way at #126 and its parent,
  an empty run took 117–122 ns against 106–107. On a quiet machine #116
  measured a close at 382 → 352 ns and a completion at 210 → 178 ns
  against its own base.

### Notes

- `docs/api.md` now says what an escape costs, and when an engine
  suspended inside a callback can be resumed (#94, #115, #124):
  - An escape from a callback libuv calls while it polls for I/O also
    leaves the poll's frame, which holds libuv's array of events: 34,352
    bytes of stack on macOS arm64 and 22,272 on Linux arm64, against
    about 400 for a timer callback's.
  - An engine suspended inside a callback can be resumed only on its own
    thread, and only while its callback still nests. 0.8.0's docs
    promised that resuming always finishes the run. Resumed out of that
    order, a run raises Chez's "attempt to return to stale foreign
    context" and leaves its loop marked running for good.
- The macOS hang at a full stack is Chez's (#95, #121). After a fault
  inside a `__collect_safe` call, as `uv_run` is, Chez leaves the thread
  deactivated, and a collection requested before the next such call
  returns deadlocks. Never treat "invalid memory reference" as
  recoverable.
- ADR-0002 is amended for the shim's seventh kind of export, where the
  calling thread's stack is (#126). ADR-0019 is amended for #102 and #87.
- New checks hold these changes: the suites `test-stack-headroom`,
  `test-loop-guard` and `test-owner-refusal`, and rules 9, 10 and 11 of
  `tests/test-source-rules.sps`. A new pure suite,
  `test-unread-assignments`, fails any variable a test assigns and never
  reads (#89, #123).
- The test runners: the level-3 child is reaped, with its exit status
  reported (#110, #114); the stranded-exit child runs under the shared
  runner (#117, #122); and the runner holds off Chez's collections while
  it waits on a child, since a collection reaps the children
  `open-process-ports` starts and takes their status (#128, #129). The
  step suites share one copy of their sweep helpers (#103, #119), and
  `test-loop-claim` catches the exit's re-claim after a refusal every run
  (#96, #112).
- Known: `test-dns`'s queued-tail teardown row can fail a correct build
  when its cancel loses every attempt (#127), and the test suites assume
  a POSIX host (#125).
- The evidence is in `.plans/*-mutation-log.md`, one log per change.

## 0.8.0 — 2026-10-09

This release finishes the work 0.7.4 began on calls an engine stops part
way. Every verb that 0.7.4 listed as not yet safe to abandon now checks
its handle or loop and calls libuv in one step that no engine can split.
A verb that checks its handle's owner on entry now checks it again in
that step. The libuv floor rises to 1.48.0, which is why this is a minor
release, and seven verbs return nothing where they returned 0. The
shim's C is unchanged, but run `make build` after upgrading. The build
now passes over a system libuv below 1.48.0 for the vendored one. The
configuration it generates refuses a libuv below 1.48.0 at load with
`&uv-version-incompatible`.

### Fixed

- **Verbs an engine stops.** An engine's timer can stop a verb anywhere. A
  scheduler can then close the handle, tear the loop down or hand it to
  another thread before resuming the engine, or never resume it. These
  verbs now make their checks, their allocation and their native call in
  one step. One resumed after its handle or loop was closed raises
  `&uv-handle-closed` without touching it. One resumed after its loop was
  handed to another thread raises `&uv-wrong-thread`. One whose engine is
  never resumed leaves nothing behind (`docs/api.md`, "Inside an engine"):
  - `uv-tcp-connect!`, `uv-getaddrinfo!`, `uv-getnameinfo!` and
    `uv-cancel!` (#85). Resumed, each called libuv on what a close or a
    teardown had freed, or on the loop another thread now owned. Dropped,
    a connect or a lookup lost a block, or left a request registered and
    counted that libuv never saw. A cancel resumed after its lookup completed handed
    libuv the request's freed block;
  - `uv-tcp-bind!`, `uv-tcp-getsockname-port`, `uv-tcp-sockname-address`,
    `uv-tcp-peer-address` and the four buffer-size verbs (#86). Resumed,
    each called libuv on whatever client had taken the closed one's
    address (a bind bound the new client and returned normally), or,
    after a handoff, on a handle another thread now owned. Dropped, each
    lost one or two blocks;
  - the timer verbs, the signal verbs, `uv-listen!`, `uv-tcp-nodelay!` and
    `uv-tcp-keepalive!` (#86). A timer start, a signal start or a listen
    resumed after a close started whatever handle had taken the freed
    address, and resumed after a handoff, it started its handle on the
    loop another thread now owned. A timer start resumed on the freed
    block faulted. A signal start resumed after another task had fixed the
    other mode returned normally. A start dropped part way left its
    callback stored and nothing started;
  - `uv-stop!`, `uv-now`, `uv-loop-alive?` and `uv-update-time!` (#86).
    Resumed after a teardown, each called libuv on the freed loop, or on
    a new loop given its address: `uv-stop!` set that loop's stop flag,
    `uv-update-time!` moved its clock, and on macOS `uv-loop-alive?`
    answered `#t` for a loop with nothing on it. `uv-update-time!` resumed
    at one point raised `'null-loop-pointer` instead, and resumed after a
    handoff it wrote the clock of a loop another thread owned;
  - the stream verbs, `uv-process-kill!` and `uv-process-pid`, which 0.7.4
    made one step, now check the loop's owner there too (#86). Resumed
    after a handoff, `uv-write!`, `uv-write*!` and `uv-shutdown!` made
    their call on the loop another thread owned and returned normally, and
    `uv-process-kill!` signalled its process.

- **The timer verbs on another kind of handle** (#86). They took any
  handle as a timer: given a TCP handle, `uv-timer-set-repeat!` wrote
  into its struct and `uv-timer-stop!` faulted. They now refuse it as
  `'not-a-uv-timer`.
- **Numbers a C parameter cannot hold** (#86). A timeout or repeat from
  2^64, given to `uv-timer-start!` or `uv-timer-set-repeat!`, and a
  keepalive delay from 2^32 raised a malformed condition from Chez's own
  check of the foreign call's arguments. A backlog from 2^31 was accepted.
  Each is now refused by name with `&uv-invalid-argument`:
  `'timeout-out-of-range`, `'repeat-out-of-range`, `'delay-out-of-range`
  and `'backlog-out-of-range`.

### Changed

- **The libuv floor is 1.48.0**, Ubuntu 24.04 LTS's libuv (#90). It was
  1.44.0, and no run had tested it: against Debian 12's 1.44.2, two
  `test-lifecycle` rows fail. A system libuv below the floor is passed
  over for the vendored build, as a missing one is, where a shim was
  built that refused itself at load. A second CI job on `ubuntu-24.04`
  links exactly 1.48 and runs `make test`.
- **Return values.** `uv-timer-start!`, `uv-timer-stop!`,
  `uv-timer-again!`, `uv-signal-stop!`, `uv-listen!`, `uv-tcp-nodelay!`
  and `uv-tcp-keepalive!` return nothing where they returned 0 (#86).
- **Refusal order.** A signal start in the mode its handle is not fixed
  in, given a callback that is not a procedure, reports the callback
  (`'on-signal-not-a-procedure`) where it reported `'signal-mode-fixed`
  (#86).
- **Calls allocate less** (#85, #86). Measured on macOS arm64, bytes on
  the Scheme heap per call, the fewest of 64:

  | Call | 0.7.4 | 0.8.0 |
  |---|---|---|
  | `uv-tcp-connect!` | 848 | 240 |
  | `uv-getaddrinfo!`, no hints | 576 | 256 |
  | `uv-getnameinfo!` | 864 | 240 |
  | `uv-tcp-bind!` | 432 | 112 |
  | `uv-tcp-sockname-address`, `uv-tcp-peer-address` | 512 | 176 |
  | `uv-tcp-getsockname-port` | 320 | 0 |
  | a buffer-size verb, getting or setting | 320 | 0 |

  The others measured allocate as in 0.7.4: `uv-timer-start!`,
  `uv-timer-stop!`, `uv-tcp-nodelay!`, `uv-tcp-keepalive!`, `uv-now` and
  `uv-update-time!` nothing, `uv-write!` 144 B and a one-segment
  `uv-write*!` 192 B.
- **A development container for Guix hosts** (#106, ADR-0020).
  `scripts/guix-env` runs a build or a test in a container pinned to a
  Guix channel commit, with Chez 10.4.1 and libuv 1.52.1, no network but
  loopback, and nothing of `HOME`. `make check-guix` verifies it. `make
  build`, `deps`, `vendor` and `test-memory` now stop early, naming what
  is missing, when the compiler, Chez or the vendored build's tools are.
- **The memory gate** (#94, #99, #104). Valgrind's report suppresses one
  block Chez allocates and never frees: the `jmp_buf` for a call into
  Scheme that a continuation escapes, or an engine drops (312 B on
  aarch64, 200 B on x86-64). It matches only a `malloc` made directly by
  Chez's `S_call_help`, so none of the binding's blocks. `test-memory`
  fails any suite outside four named ones whose own process had a block
  suppressed. The suites that load no native code no longer run under
  Valgrind.
- **CI** (#104). The vendored Valgrind job takes 6m11s, where it took
  19m14s: a suite waited out a 20,000-tick cap after each call it
  expected refused.

### Notes

- `docs/api.md`'s "Inside an engine" covers each verb above.
- ADR-0019's decision 3 is amended for each change to the verbs, ADR-0001
  for the floor, and ADR-0003 for the suppression and the narrower
  Valgrind lane. ADR-0020 is new, for the container.
- New checks hold these changes:
  - new suites `test-request-steps` and `test-handle-steps`, and handoff
    sweeps in `test-stream` and `test-process-steps`. Rows in each
    failed by name on the code it replaced;
  - `tests/test-source-rules.sps`'s rule 8: every route from a handle
    record to its pointer is taken only where the rule says why;
  - `make check-pins` checks which libuv a build at and just below the
    floor would use;
  - `make check-memory-gate` gains escape modes that hold the suppression
    to exactly the blocks it is for.
- The level-3 test runner drains the child's stderr and keeps its
  deadline (#88), with its own suite, `test-level-3`.
- A wrong-thread refusal built after a step reads the loop's owner then,
  so a loop handed on again in between is named wrongly (#102).
- The evidence is in `.plans/*-mutation-log.md`, one log per change.

## 0.7.4 — 2026-10-08

This release closes the ways a call could reach freed or wrong memory while
something else ran in the middle of it: an engine's timer, a scheduler that
closed a handle or tore its loop down before resuming the engine, another
thread, or a caller's string or list that changed while the verb read it.
The verbs that checked a handle and then called libuv now do both in one
step that no engine can split. The verbs that read a caller's data read it
once. Two loops on two threads no longer corrupt the table they share. And
no two calls are ever inside one loop at once. Calls and callbacks allocate
less. There are no API changes, but the shim gained exports: run
`make build` after upgrading. An old shim is refused at import with
`&uv-shim-unavailable`, naming it.

### Fixed

- **Loops on several threads.**
  - Two loops run on two threads at once no longer corrupt the binding's
    table from libuv's pointers to handles and requests (#70). It is one
    table for every loop, and it now has one lock, taken only with
    interrupts disabled. On macOS arm64 the lock costs about 30 ns an
    access uncontended. Four threads that did nothing but make, fire and
    close timers ran 1.6 to 2.2 times slower than with a table each. A
    teardown, and `uv-loop-live-handles`, copy the whole table while they
    hold it. The walk that classifies a failed spawn keeps its pointers per
    thread, orphan-callback events are no longer lost, and the debug
    shim's counters are atomic.
  - No two calls are inside one loop at once (#78). `uv-run`,
    `uv-loop-close!` and `uv-loop-teardown!` claim the loop atomically
    before they call libuv on it. While one holds the claim, the others are
    refused `'loop-running` from any thread, and the refusal changes
    nothing, not even the loop's owner. Before, the check and the mark were
    two steps, and two threads could both get in: two of the loop's
    callbacks ran at once, `invalid memory reference` was raised out of
    `uv-run`, both threads hung, or a close freed the loop under a run. A
    teardown claims the loop for each of its steps, so another thread's
    call can get in between and make it refuse `'loop-running` part-way,
    its handles already closing; calling it again finishes it.
    `call-with-uv-loop`'s exit no longer tears down a loop another thread's
    call is inside.
  - Every verb that makes something on a loop now refuses a thread that
    does not own it with `&uv-wrong-thread`, leaving nothing behind (#79):
    the handle constructors, `uv-accept!`, `uv-spawn!`, `uv-getaddrinfo!`
    and `uv-getnameinfo!`, and `uv-cancel!`. Before, libuv's init raced the
    loop's thread on its handle queue and corrupted it without an error (11
    of 13 runs), the lookups raced the loop's count of requests, and
    `uv-cancel!` could read a request its completion had freed. A call made
    while the loop is being handed to another thread still goes unseen
    (`docs/api.md`, "One thread per loop").
- **Verbs an engine stops.** An engine's timer can stop a verb anywhere. A
  scheduler can then close the handle or tear the loop down before resuming
  the engine, or never resume it. These verbs now check the handle and the
  loop, allocate, and call libuv in one step that no engine timer
  interrupts. One resumed after its handle or loop was closed raises
  `&uv-handle-closed` without touching it, and one whose engine is never
  resumed leaves nothing behind (`docs/api.md`, "Inside an engine"):
  - the stream verbs: `uv-write!`, `uv-write*!`, `uv-shutdown!`,
    `uv-read-start!`, `uv-read-stop!` and `uv-stream-write-queue-size`
    (#53). Resumed after its stream closed, a `uv-write!` called libuv on
    the freed handle, and a new connection given the same address received
    the bytes;
  - the constructors, `make-uv-loop` and `call-with-uv-loop` included, and
    `uv-accept!` (#59). A teardown between the check and the init linked
    the new handle into the freed loop. A constructor dropped after the
    init left a handle no teardown could close: `EBUSY` for good, and for
    an async a teardown that never returned. A thread could also be left
    holding the library's initialisation lock;
  - `uv-spawn!` (#60, #63). It checks its `stdio` handles and its loop
    again where it spawns, and allocates its process handle and options
    block there. A pipe consumed or a handle closed mid-call had leaked a
    descriptor, connected the child to another pipe, or left the spawn in
    its unclassifiable state, and a dropped spawn leaked one or two blocks
    in 124 of 190 runs;
  - `uv-process-kill!` and `uv-process-pid` (#71). Resumed after their
    process was closed, the kill signalled whatever process a later spawn
    had been given at the same address, and returned normally.

  The rest are not safe to abandon yet, and `docs/api.md` lists them: the
  DNS verbs, `uv-tcp-connect!`, the verbs that borrow a scratch block, and
  the other handle verbs (#85, #86).
- **Arguments read once.** A caller's string or list can change while a
  verb reads it, from an engine's handler or from another thread. These
  verbs now read it once, into a copy nothing else reaches, and work only
  from the copy:
  - `uv-getaddrinfo!` reads `node`, `service` and `hints` (#51, #66). A
    bogus hint written mid-call had leaked the request block, and a NUL
    written into the node after the check resolved its prefix;
  - `uv-tcp-bind!`, `uv-tcp-connect!` and `uv-getnameinfo!` read the
    address and the flag list (#61). An address holding a NUL is refused
    (`&uv-invalid-argument`, `'address-contains-nul`): C read it only up
    to the NUL, so `"127.0.0.1\x0;anything"` bound `127.0.0.1`. Mid-call, a
    NUL written into `"::1"` bound, connected or resolved `::`, a widened
    character overran the encoding, and a list made circular spun forever;
  - `uv-spawn!` reads `file`, `args` and `options` (#56, #66). Before, a
    string or list that grew mid-call was written past the options block,
    a growing `stdio` list wrote over argv, a NUL written after the check
    cut the child's strings short, and at `--optimize-level 3` a list made
    circular was walked forever with interrupts disabled;
  - `uv-write*!` reads its segment list, and each `(bv start end)` span
    (#64, #81). Chez's `map` had read through a non-pair put in its way
    (`invalid memory reference`), or walked a list made circular without
    end.

  A list changed once during the read is read as it was or as the change
  left it. A list changed several times, by another thread, can be read as
  a mix of its versions or refused, but never read through a non-pair or
  walked without end.
- **Writes.** A write whose payload shrinks during the call no longer
  leaks its block (#49). It is refused under the verb's own name,
  `uv-write!`'s `'span-out-of-range` or `uv-write*!`'s
  `'segment-span-out-of-range`, where it was `uv-copy-in!`'s.

### Changed

- **A continuation that escapes a callback leaves its loop marked
  running** (#45). The escape leaves libuv in the middle of an iteration
  that nothing can finish, and `uv-run` no longer clears the mark on the
  way out, so `uv-run`, `uv-loop-close!` and `uv-loop-teardown!` refuse
  the loop from then on. `call-with-uv-loop` still tears its own loop
  down on the way out. To end a run early, call `uv-stop!` or raise. The
  same mark protects an engine suspended inside a callback: its loop now
  stays marked until the engine is resumed and the run finishes. Before,
  `uv-run` cleared the mark on the way out of the call, a teardown was
  accepted while the engine was suspended, and resuming the engine died
  with `invalid memory reference`.
- **Calls and callbacks allocate less.** Each callback crosses one guarded
  seam, `uv-run` has no `dynamic-wind`, and libuv's alloc callback for
  reads is answered by the shim, with no Scheme at all (#45). Measured on
  macOS arm64, bytes on the Scheme heap per call, the fewest of 64:

  | Call | 0.7.3 | 0.7.4 |
  |---|---|---|
  | `uv-write!` of 64 bytes | 544 | 144 |
  | `uv-write*!`, 1 segment | 624 | 176 |
  | `uv-write*!`, 64 segments | 11,712 | 3,200 |
  | `make-uv-timer` | 624 | 512 |
  | `uv-spawn!`, argv of 3 | 1,744 | 1,056 |
  | a timer started and its callback run | 880 | 416 |
- **Refusals.** A pipe named twice in one spawn is refused
  `'pipe-already-used`; libuv had opened it twice, with the child already
  running. A segment or flag list that changes once during the call is
  now read as one of its versions, where it was refused.
- **The shim** gained exports (`chez_uv_alloc_cb`, `chez_uv_alloc`,
  `chez_uv_free`, `chez_uv_live_block`), and its debug counters are
  atomic. Run `make build` after upgrading.
- **CI** runs on `ubuntu-26.04` by name, not `ubuntu-latest`, and keys its
  cached Chez by the runner's image (#92). The pkg-config leg now links
  libuv 1.51.0, so no CI run links a libuv below 1.49, though the floor
  is 1.44.0 (#90).

### Notes

- **Escaping a callback costs stack.** Each escape leaves the C frames of
  the `uv_run` it left on its thread's stack for the life of the thread.
  On Linux, 16,000 to 20,000 escapes filled an 8 MB stack and the process
  died with `SIGSEGV`. On macOS a `fork-thread` thread held 1,000 to 2,000,
  and then hung. This is as old as the binding. `docs/api.md` now says so,
  and #94 and #95 track what is still unknown.
- `docs/api.md` gains "One call inside a loop at a time", "A callback ends
  only by returning" and "Inside an engine", and states the cost of the
  registry's lock, how a segment list and an address are read, and two
  more `uv-spawn!` behaviours.
- ADR-0019 is amended for the engine-split series (decision 3), the
  registry lock (decision 4), the owner checks and the loop's claim.
  ADR-0002 and ADR-0008 are amended for the shim's alloc callback,
  ADR-0003 for the memory gate's view of the shim's copies, ADR-0009 and
  ADR-0012 for the read-once copies and addresses, and ADR-0015 for the
  spawn step.
- New checks hold these changes:
  - `tests/test-source-rules.sps` holds every foreign call to the FFI
    rules (no string arguments, nothing in Scheme memory passed to a
    `__collect_safe` call), and lists every process-wide variable with how
    threads share it.
  - New suites: `test-constructors`, `test-constructor-owner`,
    `test-loop-claim`, `test-loop-threads`, `test-process-steps`,
    `test-address`, `test-c-string`, `test-callback-alloc`,
    `test-seed-gates` and `test-sweep`. Most suites gained engine sweeps
    that split or drop each verb at every point an engine can.
  - `make check-memory-gate` also plants an overrun through the shim's own
    copy, on both platforms, and requires the report to name
    `chez_uv_copy_in` (#55).
- Rows that relax under a memory tool now ask the allocator as well as the
  environment, so a plain run that inherits `ASAN_OPTIONS` from a shell
  still checks everything (#92).
- The evidence is in `.plans/*-mutation-log.md`, one log per change.

## 0.7.3 — 2026-09-28

`uv-async-send!` can no longer send on a handle that a close has freed. It
checked that the handle was open and then called `uv_async_send`, and a
close on the loop thread could free the handle in between; only the caller
could prevent that, by following the discipline `docs/api.md` describes. A
send that races a close is now refused. `uv-close!` is now one step, even
inside an engine. And a Chez built without threads, where the binding never
loaded, is refused at import with a message saying so. No API changes, and
the shim needs no rebuild.

### Fixed

- `uv-async-send!` no longer races `uv-close!` (#33). Each async handle has
  a lock that both take, so a send from any thread either completes before
  a close begins or raises `&uv-handle-closed` without touching the handle.
  That holds when the close frees the handle a moment later, and when
  either runs inside an engine. The race was there from 0.6.0, when
  `uv-async-send!` arrived.
  - The lock is held only around one native call, with interrupts
    disabled, so no engine is ever suspended holding it and no collection
    ever waits on it. A send may be made with interrupts disabled, or from
    a collect-request handler.
  - Measured on macOS arm64 while a wake is already pending (libuv's fast
    path, with no system call): a send costs about 30 ns, up from 8, and
    allocates nothing. Senders sharing one handle take turns on its lock:
    about 90 ns a send with four.
  - `uv-close!` still runs on the loop thread only, and delivery is still
    the caller's: a close drops wakes still pending. `docs/api.md`'s Async
    section shows how to know which queued items will be handled.
- `uv-close!` is one step, even inside an engine, for every kind of handle.
  Checking that the handle is open, marking it closing and calling
  `uv_close` now happen with no point between them where an engine can be
  suspended. An engine on the loop thread could split the old close two
  ways:
  - between the check and the mark, so that two closes of one handle both
    called `uv_close`. Running the loop afterwards crashed with
    `invalid memory reference` on macOS and hung on Linux.
  - between the mark and `uv_close`, so that a handle read as closing
    before libuv had begun to close it. A teardown then hung (an async) or
    failed with EBUSY (a timer).

### Changed

- A threaded Chez Scheme is required (#41). The binding has used Chez's
  thread system since 0.1, and a Chez configured with `--nothreads` has
  none, so the binding never loaded there: the import failed with a bare
  "missing import for make-mutex". It now stops before loading anything,
  with a message that begins "chez-libuv needs a threaded Chez Scheme"
  (`docs/building.md` shows it whole). Chez builds threaded by default, so
  every Chez that ran an earlier release is unaffected.

### Notes

- ADR-0019 is amended twice. Its decision 5 said the threading work was
  free on a non-threaded Chez. That was reasoned, never run, and never
  true. Its decision 3 now describes the send fence.
- New checks hold all three changes:
  - `tests/test-async-fence.sps` suspends a send and a close at every point
    where an engine can, and checks from another thread that the lock is
    free at each. It forks threads, but none of its verdicts depends on
    timing, so it runs on the default gate and the memory gate (ADR-0010
    amended).
  - `tests/test-timer.sps` checks, at every such point in a close of a
    timer and of an async, that the handle's state agrees with libuv's.
  - `make check-nothreads-docker` builds a `--nothreads` Chez in Docker and
    requires each public library to be refused by name.
    `tests/test-require-threaded.sps` holds, on every `make test`, the
    import order that lets the refusal win.
- The evidence is in `.plans/async-send-fence-mutation-log.md` and
  `.plans/require-threaded-mutation-log.md`.

## 0.7.2 — 2026-09-28

No library changes: nothing under `src/` changed, and the shim needs no
rebuild. This release tightens `make check-memory-gate`, the check that
proves the memory gate can fail. chez-cmark-gfm copied that check and found
three gaps, and all three applied here too (#39).

### Fixed

- `make check-memory-gate MEMORY_SABOTAGE_MODES=` planted nothing, yet
  passed with `MEMORY GATE CAN FAIL`. It now fails with "nothing was
  planted".

### Changed

- On Linux, `make check-memory-gate` also plants a block that only a
  pointer into its middle reaches, which Valgrind counts as "possibly lost".
  The gate may pass on that block, or fail and print its loss record. It
  must never fail on it without the record. This holds the gate's
  `--errors-for-leak-kinds=definite`, the flag that keeps Valgrind from
  failing a run on a leak kind the log does not show.
- The macOS `make test-memory` no longer sets `MallocNanoZone=0`. With ASan
  live, it made no measurable difference: the reports, exit statuses and
  output were the same with or without it, because every block comes from
  ASan's own allocator. The reason given for it, a trap on a double free
  before ASan could report one, came from a run where ASan was never
  loaded.

### Notes

- The Makefile used to justify `--errors-for-leak-kinds=definite` by saying
  Chez's runtime routinely produces possibly-lost blocks. Measured, no
  suite's own process has one. Only forked `uv_spawn` children do, and those
  never gate. The flag stays, for the reason above.
- The evidence is in `.plans/memory-gate-mutation-log.md` ("Port-back from
  chez-cmark-gfm") and ADR-0003's 2026-09-28 amendment.

## 0.7.1 — 2026-09-28

Writes and reads no longer hold the event loop for a time proportional to
their size at Scheme speed. Every write, every read delivery and every
spawned argument copied its bytes one at a time through the FFI, and every
request block was zeroed the same way. A 4 MiB `uv-write!` held its loop
about 250 ms: half zeroing the block, half copying the payload into it. Each
move is now one `memcpy` or `memset` in the shim, and the same write takes
about half a millisecond. No API changes, but **run `make build` again after
upgrading**: the shim gained three exports.

This release also repairs the memory gate itself, which had been checking
the wrong process; see Notes.

### Fixed

- Bytes cross the FFI boundary in bulk (#35). `uv-write!`, `uv-write*!`,
  every `on-data` delivery and `uv-spawn!`'s string arguments copy each span
  with one `memcpy`. Every handle and request block is zeroed with one
  `memset`.
  - Measured on macOS arm64: a 4 MiB `uv-write!` call went from 247–251 ms to
    0.41–0.54 ms, and a 16 KiB one from 1.0 ms to about 0.03 ms. Copying a
    16 KiB read had cost about 0.47 ms at the measured per-byte rate.
  - The argument checks are unchanged and still run before the copy.
    `copy-in!`'s span check and its copy are one uninterruptible step, so
    even an interrupt handler that truncates the bytevector cannot make it
    read past the end.

### Changed

- A shim built from older sources now fails `(import (libuv))` with
  `&uv-shim-unavailable` naming the shim. It used to fail with a bare
  `no entry for "chez_uv_…"` assertion. Rebuild after every upgrade, patch
  releases like this one included.
- `make test-memory` checks the Chez process again, on both arms, and the new
  `make check-memory-gate` proves it can fail (#37). It plants a heap
  overrun and a leak and requires the gate to report them. CI and
  `make test-memory-docker` run it first.

### Notes

- **v0.6.0 and v0.7.0 shipped on a memory gate that could not fail.**
  - From 2026-08-30 (#14) the Linux gate ran `valgrind timeout scheme …`:
    Valgrind checked `timeout`, and Chez ran unchecked.
  - The macOS ASan arm never loaded ASan at all.
  - v0.5.0 was really gated.
  - Rerun live for this release, all 17 suites pass with no memory errors in
    the binding. The only reports come from forked `uv_spawn` children and are
    fork artifacts
    ([ADR-0003](.plans/decisions/0003-linux-valgrind-is-the-sole-memory-gate.md),
    dated note).
- `docs/api.md` corrects the read-buffer tradeoff. The measurement behind
  "the buffer size makes no throughput difference" spent about 97% of its CPU
  in the per-byte copying this release removes. Measured again, a 4 KiB read
  buffer drains about 1.6× slower than 64 KiB. The practical advice stands:
  small buffers for many small-message connections, 64 KiB for bulk.
- `docs/api.md`'s `uv-write!` entry now says the copy happens during the
  call. On a threaded Chez it holds off other threads' garbage collections
  while it runs: roughly 0.05–0.35 ms per MiB, which matters only for single
  writes of tens of MiB.

## 0.7.0 — 2026-09-27

One new loop verb, and the reference documentation 0.6.0's threading work
shipped without. libuv reads its clock once per loop iteration and arms every
timer from that cached value, so a callback that holds the loop leaves the
clock behind, and a deadline armed after it starts from before the callback
ran. A server that computes in a request handler and then arms a write timeout
saw it fire early: a response cut off mid-write, and a keep-alive connection
closed as soon as its response was written. `uv-update-time!` is libuv's
answer, `uv_update_time`. Purely additive: no existing call changes behaviour.

### Added

- `(libuv loop)`: `uv-update-time!` refreshes the loop's cached "now" (`uv-now`)
  from libuv's clock. A callback that held the loop calls it before arming a
  deadline; without it the deadline counts from before the callback ran. It is
  legal while the loop runs and runs nothing — no callback fires, not even a
  timer already due. It is loop-thread-only and **checked**: `&uv-wrong-thread`
  from any other thread. It is the first loop-level verb inside the enforced
  affinity surface, because unlike `uv-now` it writes the cache the loop thread
  rewrites every iteration
  ([ADR-0019](.plans/decisions/0019-threading-model-collect-safe-and-per-loop-affinity.md),
  dated note). Re-exported from `(libuv)`.

### Notes

- `docs/api.md` now documents what 0.6.0 shipped without a reference entry: the
  `(libuv async)` module, a one-thread-per-loop rule naming which verbs are
  checked and which are loop-thread-only but unchecked, and the
  `&uv-wrong-thread` condition. `uv-async?` is listed with the other type
  predicates in `(libuv handle)`, where it has always lived; importing
  `(libuv async)` alone does not bring it in.
- Two `uv_async` lifetime rules are now written down, both libuv's contract
  and both unchanged since 0.6.0. The handle must outlive every
  `uv-async-send!`: the send's open check cannot stop the loop thread from
  closing the handle between the check and the send. And `on-wake` never runs
  once `uv-close!` has started, even for a send made before it, so drain your
  own queue once more after closing. `docs/api.md`'s Async section shows one
  safe shape.
- The `uv-timer-start!` entry now says a timeout counts from the cached
  `uv-now`, and points at `uv-update-time!`.

## 0.6.0 — 2026-09-19

Threading, and the TCP surfaces v0.5's review left open. A loop thread can now
block in `uv-run` without freezing garbage collection for every other Scheme
thread, and a worker thread has one thread-safe way to hand work back to the
loop thread — the minimum that makes a second Scheme thread usable alongside a
libuv loop. The rule that a loop and its handles belong to one thread is now
**enforced**, not merely documented. Alongside: vectored writes, TCP keepalive
and a reuseport bind flag, and the local-address accessor that mirrors the peer
side. A single-threaded program is unchanged beyond the released collect
interlock. The threading design is
`.plans/2026-09-19-chez-libuv-threading-design.md`
([ADR-0019](.plans/decisions/0019-threading-model-collect-safe-and-per-loop-affinity.md)).

### Added

- `(libuv async)`: `make-uv-async` and `uv-async-send!` — libuv's one
  cross-thread wakeup. `make-uv-async` creates a `uv_async` handle on its loop's
  owning thread; `uv-async-send!` is callable from **any** thread
  (`uv_async_send` is libuv's sole thread-safe call) and is the one verb exempt
  from the affinity check below. Sends coalesce — N sends may yield a single
  wake — so the wake callback should drain a caller-side queue rather than
  assume one item per send. `uv-async?` and the handle join the registry, the
  teardown sweep, and the allocation counters like every other handle;
  `uv_async_cb` is the fourteenth locked `__collect_safe` trampoline
  ([ADR-0008](.plans/decisions/0008-static-trampolines-and-handle-registry.md)).
  Re-exported from `(libuv)`.
- `&uv-wrong-thread` (subtype of `&uv-error`; fields `who`, `expected` owner
  thread id, `actual` caller thread id), raised when a handle verb runs off its
  loop's owning thread. Re-exported from `(libuv)`.
- `(libuv tcp)`: `uv-write*!`, vectored (scatter-gather) writes — N segments,
  each a bytevector or an explicit `(bv start end)` span, copied into one
  request block and issued as a single `uv_write` with `nbufs = N`. The name
  [ADR-0009](.plans/decisions/0009-copy-at-the-boundary.md) reserved; one owned
  block, so the completion and submit-immediately discipline are `uv-write!`'s
  unchanged.
- `(libuv tcp)`: `uv-tcp-keepalive!` (wraps `uv_tcp_keepalive`; `(tcp #f)`
  disables, `(tcp #t idle-seconds)` enables with a required positive
  whole-second delay), and an optional flag list on `uv-tcp-bind!` —
  `'(reuseport)` for `SO_REUSEPORT` load balancing. `UV_TCP_REUSEPORT` arrived
  in libuv 1.49.0 and is looked up lazily
  ([ADR-0005](.plans/decisions/0005-constants-are-never-transcribed.md)
  extended), so an older libuv works normally and raises
  `&uv-constant-unavailable` only for a caller that actually requests the flag,
  and only on a platform where libuv supports it (Linux/BSD, not macOS).
- `(libuv tcp)`: `uv-tcp-sockname-address` → `(values address-string-or-#f
  port)`, the local-end mirror of `uv-tcp-peer-address`, closing a deferral open
  since v0.2 ([ADR-0012](.plans/decisions/0012-address-vocabulary.md) amended).
- [ADR-0019](.plans/decisions/0019-threading-model-collect-safe-and-per-loop-affinity.md):
  the threading model. ADR-0008 gains the fourteenth-trampoline and
  `__collect_safe` amendments; ADR-0010 a threaded-test companion.
- `make test-memory-docker` — the Linux Valgrind leak gate
  ([ADR-0003](.plans/decisions/0003-linux-valgrind-is-the-sole-memory-gate.md))
  runnable from a macOS box — and `make test-threading`, the threaded stress
  tier kept off the default gate (ADR-0010 companion; forks OS threads, is
  timing-dependent).

### Changed

- `uv_run` is now `__collect_safe`: a thread blocked in it is deactivated for
  the poll, so it no longer holds Chez's collect interlock and other Scheme
  threads collect freely. Twelve of the thirteen trampolines it can invoke carry
  the attribute; `walk` alone stays plain (it fires only from the synchronous
  `uv_walk`). A single-threaded program is unaffected beyond the released
  interlock; the cost is ~60 ns per callback.
- A libuv loop and its handles are enforced loop-thread-only: every operational
  handle verb asserts it runs on the loop's owning thread and raises
  `&uv-wrong-thread` otherwise, at one central site before any registry
  mutation. The owner is set at `make-uv-loop` and transferred to the caller at
  `uv-run` entry, so a loop may be created on one thread and handed to a
  dedicated loop thread (the worker-pool pattern). Cross-thread use previously
  corrupted the process-global registry silently; it is now a named refusal.
  `uv-async-send!` is the one exemption.
- CI drops the macOS job — LeakSanitizer is unavailable there and macOS is
  covered by the local `make test` / `make test-memory` — and each test suite is
  now capped individually, so a hang is reported as `HUNG` rather than
  mislabelled a failing assertion.

## 0.5.0 — 2026-08-30

Flow control: three per-connection memory surfaces made visible and
adjustable, and the one write-side congestion signal Scheme could not
otherwise derive. No new libuv subsystem and **no behaviour changes** — the
read-buffer default is pinned, not altered, and every new procedure reports
or configures. The full design is
`.plans/2026-08-29-chez-libuv-v0.5-flow-control-design.md`.

### Added

- `(libuv stream)`: `uv-stream-write-queue-size`, libuv's own
  `uv_stream_get_write_queue_size` — a platform-dependent congestion
  signal, not a memory gauge: Unix counts bytes not yet handed to the
  kernel and deliberately leaves the count non-zero after a *failed*
  write; Windows increments only when the kernel has accepted an
  overlapped send that has not completed. Allocation-free; re-exported
  from `(libuv tcp)`.
- `(libuv handle)`: `uv-send-buffer-size`/`uv-send-buffer-size!` and
  `uv-recv-buffer-size`/`uv-recv-buffer-size!`, mirroring
  `uv_send_buffer_size`/`uv_recv_buffer_size`. Handle-generic (tcp, pipe
  and UDP on Unix; tcp and UDP only on Windows — libuv's own platform
  split, not this binding's), gated to handles with a socket
  (`'not-a-socket-handle`) and validating the setter's argument before
  any allocation (`'buffer-size-out-of-range`, exact/positive/below
  2^31 — `c-int-set!` truncates silently outside that range rather than
  raising).
- `(libuv tcp)`: `uv-tcp-peer-address`, mirroring `uv_tcp_getpeername` —
  `(values address-string-or-#f port)` for the remote end, completing the
  local/peer address mirror `uv-tcp-getsockname-port` has covered alone
  since v0.1.
- `docs/api.md`: a **Flow control** section — the read-buffer sizing
  contract stated as a tradeoff rather than a recommendation (a smaller
  buffer cuts foreign memory linearly and raises `read(2)` count,
  `on-data` delivery count, and Scheme bytevector allocation
  proportionally; no measurement has been taken), the read-stop/read-start
  pairing invariant with the `uv-handle-open?` guard for a stop that races
  a close, how a consumer bounds write memory (outstanding payload bytes
  **and** outstanding request count, incremented only after `uv-write!`
  returns successfully — a zero-length write allocates a full request
  block for zero payload bytes), and the write-queue gauge's contract
  restated in prose. A **three-buffers table** distinguishing the
  chez-libuv read buffer from the OS send and receive buffers — setting
  `SO_RCVBUF` does not resize the chez-libuv buffer, or vice versa — plus
  the six new rows in their per-module tables, the new
  `&uv-invalid-argument` reason symbol (`'not-a-socket-handle`;
  `'buffer-size-out-of-range` is reused from `uv-read-start!`, not new
  here), and a close-hazard note beside "Exit ≠ close": a second
  `uv-close!` silently discards its callback,
  because the close path guards on the handle being `'open`.
- [ADR-0018](.plans/decisions/0018-unbuffered-write-submission.md): the
  binding will not hold unsubmitted write blocks, enforce a queue-depth or
  byte cap, or have `uv-write!` refuse. `uv-shutdown!` submits immediately,
  so a deferred write would let a later shutdown reach libuv first; and
  `uv-close!` frees only the read buffer and the handle pointer, so
  nothing would free a queued block or fire its `on-complete`. Queueing
  and admission stay server policy.
- A dated amendment to
  [ADR-0009](.plans/decisions/0009-copy-at-the-boundary.md): `uv__read` is
  a loop (`alloc_cb`/`read()`/`read_cb`, repeated until the read does not
  fill the buffer), so callback-scoped borrowing is the natural lifetime
  under any read-buffer ownership model; and, correcting an assumption
  made at v0.1, `uv-read-stop!` does not make a retained span safe — the
  close dispatcher frees the buffer unconditionally, so a retained-borrow
  design needs explicit borrow ownership of its own.
- `make check-pins` gained a vendor read-path audit: it now asserts, over
  the vendored tree, that `UV_HANDLE_ZERO_READ` is assigned in exactly two
  places and cleared in none, that `read_buffer` is never assigned, and
  that the TCP `WSARecv` call-site count and the pipe
  `CancelIoEx`/`GetOverlappedResult` counts match the read-path shape the
  binding's two Scheme comments describe — replacing a claim a grep can
  check with a check, per AGENTS.md. Tripping it names both Scheme
  comment sites as the thing to re-verify; not tripping is not evidence
  the underlying claim survived.
- Both of those Scheme comments (`src/libuv/stream.sls`,
  `src/libuv/private/handles.sls`) corrected: the buffer-freed-only-at-close
  rule was previously attributed to Windows' overlapped-read model
  retaining a queued completion against the buffer, which is dead code for
  the two handle kinds this binding supports — `uv_tcp_t` never posts a
  user buffer at all, and `uv_pipe_t` drains its overlapped read
  synchronously before returning. The rule itself is unchanged and still
  correct, for the portable reason now stated: `alloc-dispatch` must stay
  infallible.
- The read-buffer default (65536 bytes) is now pinned by a test — prior
  suites exercised a size-omitted `uv-read-start!` call (`test-tcp.sps`,
  `test-echo.sps`, `test-process.sps`, `test-stream.sps`,
  `test-signal.sps`, `test-facade.sps`), but none asserted the resulting
  buffer's length — so a future change to the default is a deliberate,
  reviewed edit rather than a silent one.

## 0.4.0 — 2026-08-22

### Added

- `(libuv signal)`: `make-uv-signal`, `uv-signal-start!`,
  `uv-signal-start-oneshot!`, `uv-signal-stop!`; kind predicate
  `uv-signal?`; `uv-os-getpid` (exported from `(libuv process)` beside
  `uv-process-pid`). The callback receives the watched signal as a symbol.
- The thirteenth locked trampoline (`signal`) — ADR-0008's third
  amendment, which states the one-per-callback-TYPE rule in its own terms
  (`uv_signal_cb` shares `connection`'s arity and still gets its own slot).

### Semantics

- Watchable set: the closed nine-symbol vocabulary minus
  `sigkill`/`sigstop` (`'signal-unwatchable`); exact `0` stays
  sending-only (`'signal-unknown`); `sigchld` remains inexpressible (libuv
  owns SIGCHLD for child reaping — vendor fact V6).
- **Mode is fixed per handle** (`'signal-mode-fixed`): the first
  successful start verb pins continuous/oneshot for the handle's life;
  mode change is close-and-recreate (the vendored `UV_SIGNAL_ONE_SHOT`
  ratchet, measured — spike/signal/FINDINGS.md EV-8).
- DELIVERY ≠ CLOSE: stop and oneshot auto-disarm never close; the caller
  always `uv-close!`s (close implicitly stops an armed watcher, EV-10).
- Rearming a oneshot watcher from inside its own callback does not take
  effect (the vendor auto-stop runs after the callback returns, EV-9).

### Notes

- Measured caveat (SQ-S1, both platforms): watching `sigint` takes SIGINT
  from the Chez runtime, and `uv-signal-stop!` leaves `SIG_DFL` — neither
  `keyboard-interrupt-handler` nor `register-signal-handler` handling is
  restored. libuv's behavior, surfaced rather than fixed (README).
- The signal vocabulary validators lifted from `process.sls` to
  `(libuv private native)` on their second user — the rule recorded at
  their v0.3 introduction. `(libuv process)`'s surface is unchanged
  (plus `uv-os-getpid`).

## 0.3.0 — 2026-08-21

Child processes: `uv_spawn` with the full stdio vocabulary, as `(libuv
process)`, plus a deliberately minimal `(libuv pipe)` (`uv_pipe_init` only,
no bind/connect/listen, no `ipc=1`) that exists so pipes can be handed to a
spawn as a child's stdio end. Getting there required the one honest
refactor both needed: the stream verbs (`uv-write!`, `uv-shutdown!`,
`uv-read-start!`, `uv-read-stop!`) move out of `(libuv tcp)` into a new
`(libuv stream)`, gated on stream-*kind* rather than tcp-kind — `(libuv
tcp)` re-exports all four, so no importer has to change. This is the
binding's first subprocess machinery and its first interaction with the
host's child-reaping signals; both are governed by three new decision
records (ADRs 0014–0016 under `.plans/decisions/`, gated on the Stage 0
spike under `spike/process/`), and the full design is
`.plans/2026-08-21-chez-libuv-v0.3-process-design.md`.

### Added

- `(libuv process)`: `uv-spawn!` (`loop file args [options] on-exit` →
  process handle, child already running), with an options alist covering
  `env` (a list of `"K=V"` strings, libuv's own format — no alist
  encoding invented), `cwd`, `stdio`, `detached`, and `uid`/`gid` (setting
  either implies the matching `UV_PROCESS_SETUID`/`SETGID` flag — the
  binding closes the "field set, flag clear" footgun libuv leaves open).
  The `stdio` vocabulary covers `ignore`, `(inherit-fd . n)`,
  `(inherit-stream . h)`, and `(pipe p dir)` with `dir` one of
  `to-child`/`from-child`/`duplex` — named from the parent's perspective,
  deliberately not libuv's child-perspective `READABLE`/`WRITABLE` flags.
  `uv-process-kill!`/`uv-kill!` take a signal from a closed symbol set
  (`sigterm sigkill sigint sighup sigquit sigusr1 sigusr2 sigcont
  sigstop`) or the exact integer `0` as the POSIX liveness probe;
  `uv-process-pid` and `uv-process?` round out the surface. All of it
  re-exported from `(libuv)`.
- `(libuv pipe)`: `make-uv-pipe` (`uv_pipe_init`, ipc always 0) and
  `uv-pipe?`.
- `(libuv stream)`: the four verbs extracted from `(libuv tcp)`, now
  accepting any open tcp or pipe handle.
- The exit callback contract: `on-exit` receives `(exit-status
  term-signal)` as results, never a condition — libuv's `exit_cb` has no
  error argument. A child killed by signal delivers `(0 sigterm)`, not
  `(-1 …)` — `exit-status` is `WEXITSTATUS` on a normal exit and *zero* on
  a signal death; `term-signal` is `#f` on a normal exit, otherwise the
  signal symbol or the raw integer for a signal outside the bound set.
- The root lane: `tests/test-process-setuid.sps`, excluded from `make
  test`/`make test-memory` and run separately by `sudo make test-root`
  (refuses with a clear message under a non-root euid), to exercise
  `uid`/`gid` as the privileged behaviour they are. Both CI jobs (`linux`,
  `macos`) gained a `sudo make test-root` step.

### Changed

- Callback dispatch grows from ten to twelve static locked trampolines
  (`exit`, `walk`). ADR-0008 is amended a second time; the "one locked
  trampoline per callback type, constant per process" invariant now
  covers twelve.
- `uv-loop-teardown!`'s close sweep now also covers pipe and process
  handles (`handle-kinds` widens to include them); an un-closed process
  handle is caught exactly like an un-closed tcp handle. Exit and close
  remain two distinct events (unchanged from libuv, newly documented
  here): `on-exit` firing stops the handle but does not close it — the
  caller still calls `uv-close!`, typically from inside `on-exit`.
- The spawn-failure cleanup path is class-dependent, decided at runtime by
  asking the loop (`uv_walk`, the twelfth trampoline) rather than by
  errno (ADR-0015): an exec failure leaves the handle still linked into
  the loop's handle queue and needs `uv-close!`-through-protocol; a
  stdio-setup failure has already been unlinked by libuv and needs a
  direct free. Getting the wrong arm either corrupts the loop's handle
  queue or leaves it permanently `EBUSY`. A pipe named in any of the spawn's stdio specs is marked *connected* by a failed spawn too — libuv opens
  the parent end before it can know whether the exec will succeed — so
  the caller must still close it; naming it again raises
  `'pipe-already-used`. **Version-dependent finding, not a binding bug:**
  which failure class a given trigger lands in also depends on the
  libuv underneath — upstream commit `3e9ae1bc` (libuv 1.52.0) is what
  first unlinks a stdio-setup failure's handle; on an older libuv (found
  via Linux CI's apt `libuv1-dev` 1.48.0) the same trigger lands in the
  exec class instead, and the runtime discriminator handles both
  correctly. ADR-0015 and the design spec's §5.6 carry the full account.

### Notes

- **SQ2 spike finding: no conflict with Chez's own subprocess APIs.**
  Interleaving libuv spawns with Chez's `system`/`open-process-ports`
  across four orderings delivered 110/110 libuv `exit_cb`s intact, with
  every Chez call also returning its own correct result — measured on
  Linux's SIGCHLD-based child-reaping path, the one path where a stolen
  wait can silently drop a callback (`spike/process/FINDINGS.md` SQ2). No
  mutual-exclusion warning was needed as a result.
- No `uv_signal_t`: v0.3 binds only the signal-*sending* side
  (`uv-process-kill!`/`uv-kill!`). Handling signals in the loop is a
  recorded future-milestone candidate.
- Run 32544754290, which executed the root lane as root on both
  platforms, also delivered the first Linux valgrind verdict over the
  process surface (the root suite itself is excluded from the memory
  gate): zero errors, zero definitely/indirectly lost bytes across all
  sixteen valgrinded processes.
- The libuv version floor is unchanged: 1.44.0 or later in the 1.x
  series.

## 0.2.0 — 2026-08-21

DNS: libuv's complete resolver surface — `uv_getaddrinfo`, `uv_getnameinfo`,
`uv_cancel` — as `(libuv dns)`, in the established house style. What
`getaddrinfo(3)` and `getnameinfo(3)` do on the host is what this binding
does: no c-ares, no record types (MX/TXT/SRV), no caching, async only. This
is the binding's first use of libuv's worker threads and its first
handle-less, loop-scoped request kind; both firsts are governed by new
decision records (ADRs 0011–0013 under `.plans/decisions/`, gated on the
Stage 0 spike under `spike/dns/`), and the full design is
`.plans/2026-08-21-chez-libuv-v0.2-dns-design.md`.

### Added

- `(libuv dns)`: `uv-getaddrinfo!` (node/service strings or `#f`, hints as
  an alist over closed symbol sets — `family`/`socktype`/`protocol`/`flags`,
  no raw ints), `uv-getnameinfo!` (the TCP address vocabulary on the way
  in), `uv-cancel!` (`#t` only if the work was still queued; the callback
  still fires, with `'EAI_CANCELED`), and `uv-dns-request?`. Results are
  `uv-addrinfo` records — pure copied Scheme values with a public
  constructor and six accessors; nothing here takes or returns a pointer.
  All of it re-exported from `(libuv)`.
- Resolver failures surface as ordinary `&uv-errno-error` conditions whose
  `errno` is the `EAI_*` symbol (`'EAI_NONAME`, `'EAI_AGAIN`,
  `'EAI_CANCELED`, …) — no DNS-specific condition types, and cancellation
  is `'EAI_CANCELED` in exactly one spelling, because libuv itself rewrites
  `UV_ECANCELED` before the callback runs.
- `&uv-libuv-unavailable`, raised when libuv's own shared object
  cannot be resolved or loaded — a subtype of `&uv-shim-unavailable`, so
  guards on the parent keep matching (previously both failures were raised
  as the parent, with the `path` field as the only discriminant).
  Re-exported from `(libuv)`; sharper predicate `uv-libuv-unavailable?`.

### Changed

- Callback dispatch grows from eight to ten static locked trampolines.
  ADR-0008 is amended in place: the invariant is "one locked trampoline per
  callback *type*, constant per process", which the literal eight was an
  instance of.
- `uv-loop-teardown!` is now cancel-then-drain: it best-effort-cancels the
  loop's in-flight DNS requests before its close sweep, and every in-flight
  `on-complete` runs before teardown returns — with `'EAI_CANCELED` if the
  cancel won, with the real result if the work was already running. A
  running `getaddrinfo(3)` is uninterruptible, so that drain iteration
  waits it out, up to the OS resolver's own timeout.
- **Behaviour change:** `uv-loop-close!` now re-raises a stored pending
  callback error after a *successful* close, composed as
  `&uv-callback-error` with the original condition — the exact composition
  `uv-run`'s exit path uses. Previously a caller who skipped the next
  `uv-run` and went straight to close lost the error silently; code that
  relied on that discard will now see the raise (the loop is closed when it
  escapes). A close refused with `'EBUSY` is unchanged: nothing is
  delivered, and the error stays pending for a later `uv-run` or close.

### Fixed

- `copy-in!`/`copy-out` (private FFI helpers): a non-numeric span
  argument now raises the structured `&uv-invalid-argument` instead of a
  bare Chez assertion escaping from `exact?`.

### Notes

- IPv6 scope IDs are dropped (ADR-0012): a link-local result renders as
  `"fe80::1"` with its zone silently absent. The fix path (a shim offset
  for `sin6_scope_id` plus `uv_if_indextoname`) is recorded in the ADR.
- Threadpool workers run pure C — no Scheme ever runs off the loop thread —
  and completions are delivered on the loop thread like every other
  callback. `UV_THREADPOOL_SIZE` is read by libuv once, at first use.
- The libuv version floor is unchanged: 1.44.0 or later in the 1.x series.

## 0.1.0 — 2026-08-18

The first release: a legible, low-level mirror of libuv's event loop, TCP
sockets and timers as an R6RS library for Chez Scheme. Transport only — it
parses nothing and understands no protocol above raw bytes, so the HTTP layer
above it implements its own connection-state and backpressure policy directly
against these primitives.

Four decisions shape everything else, and each has its own record under
`.plans/decisions/`:

- **Direct FFI, constants-only shim** (ADR-0002). `uv_*` entry points are
  bound with `foreign-procedure` straight from Chez; the C shim exports the
  constants, struct sizes and offsets this binding must not transcribe, plus
  the debug counters. No hand-written C wrapper stands between a caller and
  libuv.
- **Copy at the boundary** (ADR-0009). Every buffer crossing the FFI is
  copied, in both directions. Nothing libuv holds points into the Scheme
  heap, so there is no pinning, no `lock-object` per write, and no window in
  which a moving collector can invalidate an in-flight operation. Zero-copy
  is deferred, not foreclosed: `on-data` is handed a *span*, so a sub-range
  variant needs no new call shape.
- **Errors are symbols** (ADR-0006). A negative libuv return code becomes
  `&uv-errno-error` carrying the portable symbol `uv_err_name_r` gives
  (`'ECONNRESET`), which is what callers branch on. The raw platform integer
  is preserved beside it for logs and is never the discriminant.
- **No guardians** (ADR-0007). `uv_close` is always explicit. A handle nobody
  closes leaks deterministically and visibly in the debug counters, rather
  than being swept up at some later GC on some other thread — a leak a test
  can see beats a close that happens eventually.

### Added

- `(libuv loop)`: `make-uv-loop`, `uv-run` (`'default` / `'once` /
  `'nowait`), `uv-stop!`, `uv-loop-alive?`, `uv-now`, `uv-loop-live-handles`,
  `uv-loop-deferred-errors`, `uv-loop-close!`, `uv-loop-teardown!`, and
  `call-with-uv-loop`. `uv-run` answers a **boolean**, not libuv's int: `0`
  is true in Scheme, so handing the raw value back would make `(when (uv-run
  l) …)` fire on exactly the case it means to skip.
- `(libuv handle)`: `uv-handle-state` (`'open` / `'closing` / `'closed`), the
  two never-raising state predicates, `uv-handle-loop`, and `uv-close!` —
  idempotent, asynchronous, and the only path by which a handle's memory is
  ever released. There is deliberately no `uv-handle-closed?` predicate; that
  name belongs to the condition.
- `(libuv tcp)`: `make-uv-tcp`, `uv-tcp-bind!`, `uv-tcp-getsockname-port`,
  `uv-listen!`, `uv-accept!`, `uv-tcp-connect!`, `uv-write!` (whole
  bytevector or span), `uv-shutdown!`, `uv-read-start!` / `uv-read-stop!`,
  and `uv-tcp-nodelay!`. Reads deliver through three **required** callbacks —
  `on-data (bv start end)`, `on-eof ()`, `on-error (condition)` — because a
  stream whose end and whose failure both go unnoticed is not a
  simplification. EOF is not an error and is never wrapped in a condition; a
  read error does not close the handle.
- `(libuv timer)`: `make-uv-timer`, `uv-timer-start!`, `uv-timer-stop!`,
  `uv-timer-again!`, `uv-timer-repeat`, `uv-timer-set-repeat!`.
- `(libuv)`, the facade: every name above, re-exported by hand rather than
  wholesale, plus `uv-version` and `uv-version-compatible?`. A facade that
  re-exported whatever its imports happened to have would leak a private
  binding the day someone added one.
- The condition hierarchy, rooted at `&uv-error`: `&uv-errno-error`,
  `&uv-handle-closed`, `&uv-shim-unavailable`, `&uv-version-incompatible`,
  `&uv-constant-unavailable`, `&uv-invalid-argument`, `&uv-callback-error`.
  Predicates, accessors *and* constructors are public — a caller's own
  `on-error` may want to build or re-raise one.
- Callback-boundary discipline (design spec §8): a raise inside a callback
  never crosses into C. The first one of a run is stored, the loop is
  stopped, and it is re-raised from `uv-run` composed with
  `&uv-callback-error`, so a `guard` written against the original condition
  type still matches; later raises are readable through
  `uv-loop-deferred-errors`. Dispatch goes through eight static, `lock-object`'d
  trampolines and a handle/request registry (ADR-0008) — never one locked
  callable per handle.
- The build harness: hybrid native acquisition (`pkg-config` with a pinned
  vendored `libuv` submodule fallback, ADR-0001), the constants-only C shim,
  a generated `config.sls` carrying absolute paths so the loader never
  searches, the validated-never-searched `CHEZ_LIBUV_SHIM` override, Akku
  packaging, and CI over macOS and Linux on both acquisition paths.
- `make prod` / `make check-prod`: a validated `FLAVOR` variable, a
  `build/.flavor-*` stamp recording which flavor the artifact was linked as,
  and `relink-guard` — the first prerequisite of `build`, which **deletes**
  an artifact whose recorded provenance no longer matches what was asked for.
  The deletion is what forces the relink, not the stamp: make 3.81 compares
  mtimes at one-second granularity and treats equal as up to date, so a stamp
  recreated in the same second as the previous link forces nothing, while a
  missing artifact is rebuilt whatever the clock said. The guard covers a
  change of acquisition path too. Alongside them, a behavioural probe that
  fails unless the built shim really is the counters-free release artifact.
  `prod` and `build` write the same path, so `make prod && make test &&
  package` used to package a dev relink.
- `tests/test-echo.sps`, the capstone: an echo server and eight concurrent
  in-process clients on one loop, 512 KiB of loopback traffic (256 KiB each
  way) compared byte for byte, with a read-stop/read-start applied and
  released from inside delivery callbacks, ending in seventeen closed
  handles and every counter at
  zero. It imports the facade and nothing else from this project, which is
  how the public surface is checked for sufficiency.
- Documentation: the design spec and ADRs 0001–0010 under `.plans/`, the
  Stage 0 spike and its `spike/FINDINGS.md` (which is what flipped ADR-0002
  and corrected ADR-0008's rationale), and a per-stage mutation log recording
  every assertion watched to fail — including the ones nothing could catch,
  and why.

### Known limitations

- No DNS, process, filesystem, UDP, pipe or signal bindings. v0.1 is the
  loop, TCP and timers.
- **Windows is deferred, not designed out** (ADR-0004). The one libuv struct
  this binding constructs has a different field order there, and its layout
  is validated at initialisation, so an unverified platform fails closed
  rather than writing a length into a pointer field.
- **Leak claims come from Linux only** (ADR-0003). LeakSanitizer does not
  exist on macOS/ARM64, so the macOS `make test-memory` leg reports
  use-after-free and double-free and says nothing about leaks.
