# AGENTS.md

## Project guidelines

* Use the functional core / imperative shell pattern
* Follow the 12 Factor Apps philosophy
* Project is specific to Chez Scheme and will be a Chez library.
* Project requires C ffi and handling C libraries *safely*
* Project should be portable across macos (darwin), linux, and windows
* Project should be portable across amd64 and arm64
* Plans live in `/.plans`, decision records in `/.plans/decisions`
* `/docs` is only for user facing documentation, not project plans or specs.
* Shipped files state facts, not their history. Comments in `src/`, the
  docs, README.org, NOTICE, SECURITY.md and the build files never cite
  issue or PR numbers, decision records, `.plans/` or `spike/` paths,
  dates or release numbers: state the fact or the hazard itself, in the
  present tense. Provenance belongs in commit messages, PR descriptions
  and CHANGELOG.md. `make check-history` holds this, and `make test` runs
  it; `tests/` is not covered yet.
* Add entries to `CHANGELOG.md` for each release
* Makefile should have a `help` command which lists all of the make commands.
* Library should be distributable with Akku.
* Closing Ritual: Squash merge PR, catchup local main, cleanup branches, reflect on session
* Use TDD / test-driven development
* A test that passes whether the code is right or wrong is worse than no test.
  Every decision in a module gets a mutation that breaks it, and the owning
  specification must notice. Seed an output variable before asserting it is empty.

  **A test is not finished when it passes. It is finished when you have watched
  it fail.** Before calling any new assertion done: copy the code under test to a
  scratch location outside the repo, break the specific decision that assertion
  claims to guard, run the suite, and confirm that assertion fails *by name*.
  Then revert and confirm it passes again. State the evidence when you report.
  - The mutation must break the test *through the asserted property*. If it fails
    for some other reason — a side effect of the edit, a syntax or import error —
    it has proved nothing. Narrow the mutation until the failure is the one you
    predicted.
  - If no mutation can break the assertion, the assertion is empty. Rewrite it, or
    write down in the mutation log that the property is uncovered and why. Leaving
    it silently is the exact failure this rule exists to prevent.
  - **Expect a value only success can produce.** Ask what *else* yields it.
    Truthiness is the obvious trap — in Scheme almost everything is true, so
    `test-assert` is where empty tests hide — but `#f` is worse: it is what a
    missing key returns, what a defaulting accessor returns, and what a
    swallowed exception returns. Prefer a sentinel no failure path produces.
* **Prefer a check to a comment.** When you are about to write a comment stating
  an invariant — these two things must stay equal, this must run before that,
  never call X from here — ask first whether it can be a make target, a test, or
  an assertion. A stated rule does not enforce itself, and the person who most
  needs the comment is the one who did not read it.

  This is not abstract. The rule above about empty tests was already written down
  here, and five tests violating it shipped anyway; it only started holding once
  it carried an executable standard. A Makefile comment requiring the `chez-srfi`
  submodule and `Akku.lock` to name the same commit was violated *in the same
  commit that introduced it*, and only became true once it was `make check-pins`.
  When a comment is load-bearing, that is the signal it should not be a comment.
* **A plan's code blocks are executable spec — review them like spec prose.**
  The v0.4 design spec got a four-lens adversarial review and shipped zero
  surprises; its implementation plan got only a self-review, and both defects
  that survived into execution lived in the plan's *example code*, not its
  decisions — a test assertion that could not fail (caught by a task review)
  and a hardcoded argv[0] (caught only by CI, one platform, post-merge-review).
  When a milestone's process reviews the spec adversarially, the plan's code
  blocks get the same pass.

## Guix development container

* **On a Guix host, run every build and test through `scripts/guix-env`**,
  e.g. `scripts/guix-env make test`. Batch commands with
  `scripts/guix-env sh -c 'make a && make b'`: each call takes about 3 s
  to start. The first call builds Chez 10.4.1 from source, in about
  two minutes.
* Edit, commit, fetch and push on the host. The container has git, but no
  identity, credentials or agent, and no network but loopback (ADR-0020).
  A fresh clone runs `git submodule update --init --recursive` on the host
  once: that clone needs the network.
* Verify it with `make check-guix`, run on the host.
* The container exports `CHEZ` (the real `scheme` binary) and `CC` (gcc;
  the toolchain has no `cc`). pkg-config finds the profile's libuv 1.52.1,
  so the default build is the pkg-config leg; `make HAVE_PKG=no …` builds
  the vendored one. It sets no `LD_LIBRARY_PATH`.
* In a linked worktree the launcher also shares the main repository's
  `.git`, so git works there too.
* `make test-root` and the Docker targets do not run in the container. On
  a Linux Guix host, `scripts/guix-env make HAVE_PKG=no test-memory` is
  CI's Valgrind leg itself; `test-memory-docker` is for macOS boxes.

## Traps this repo has already hit

Each of these shipped a passing test or a working-looking build that was wrong.
None is obvious from reading the code.

### Scheme and SRFI-64

* **`0` is truthy in Scheme, and `guard` returns the body's value when nothing
  raises.** So `(test-assert "…" (guard (e ((pred e) #t) (#t #f)) (accessor x)))`
  passes even when `accessor` never raises — freed pointer fields are zeroed, and
  `0` satisfies `test-assert`. Assert on *what was raised*, compared against an
  expected value, with a distinct sentinel for the no-raise case. Three tests
  guarding the liveness mechanism passed against code with that mechanism deleted.
* **Every `tests/test-*.sps` must end with its own `(exit …)`.** SRFI-64 does not set
  a process exit status, so a suite missing that line always reports success and
  `make test` stays green through real failures. Anything appended *after* it is
  dead code — a sabotage test added that way silently never runs.
* **SRFI-64 turns any exception in a test's *actual* expression into `#f`**
  (`vendor/chez-srfi/%3a64/testing-impl.scm:568-571`: the R6RS
  `%test-evaluate-with-catch` is `(guard (ex (else #F)) …)`). An assertion
  expecting `#f` therefore passes when the code under test raises. Never make
  `#f` the expected value of an assertion that can raise — use a sentinel the
  failure path cannot produce: `'agree (or (compare …) 'agree)`.
* **Chez evaluates argument expressions right-to-left in compiled library code**,
  left-to-right when interpreted. Never let an assertion's meaning depend on
  which argument runs first: one named "rejected before anything is allocated"
  was in fact satisfied by the *last* argument's accessor raising.
* **`(file-options no-fail append)` truncates the file on every open.**
  `no-fail` without `no-truncate` replaces an existing file, so each "append"
  leaves exactly the last write — the v0.4 spike's three-line handshake file
  kept showing one line and read as a vendor bug until measured. Append-or-create
  is `(file-options no-fail no-truncate append)`.
* **An unguarded raise in suite plumbing between rows aborts the suite and
  destroys the evidence.** test-signal's E2E once crashed mid-file on an ESRCH
  from a bare `uv-kill!` after its child died early: the remaining rows never
  ran, and the child's exit status — the one datum that explained the failure —
  was never printed (the first PR #7 CI run yielded nothing to debug with).
  Plumbing that can fail (kills, reads of another process's output) belongs
  inside a named row that fails *carrying the evidence*: gate every wait on
  `(or acked (pair? done))`, guard kills on the child being alive.
  A row's name and expected value count as plumbing: SRFI-64 evaluates them
  outside its catch, and only the tested expression, the last argument, is
  caught. So does the body of a lambda handed to `with-loop` or
  `call-with-uv-loop`, which runs at once. Loopback placeholders such as
  test-tcp.sps's `(define p 'never-accepted)` raised from all of these when a
  handshake missed its cap (2026-10-06). `tests/test-seed-gates.sps` now holds
  every suite that waits for an accepted peer to this. Its rule 4 holds every
  suite that calls an address or DNS verb to it as well, callbacks included:
  test-dns.sps died at its first lookup when a verb raised, with no summary
  (#64). Rule 4 does not follow procedures a suite imports, so a suite still
  dies at a loopback fixture (uv-testing's `bind-loopback!`) when every
  address is refused. A late handshake also
  reaches teardown: a connect still pending there completes as `'ECANCELED`,
  and a callback that goes on from it raises `&uv-handle-closed` out of
  `uv-loop-teardown!` (test-tcp and test-facade), so a connect callback goes
  on only from success.
* **`with-mutex` does not fence a check-then-call, even around
  `with-interrupts-disabled`.** It is a `dynamic-wind`. An engine that runs
  out of fuel inside the body releases the mutex, and on resuming carries on
  from a check made before whatever ran meanwhile. And the release itself
  runs in the exit thunk, after the winder is gone, where an engine can still
  be suspended: holding the mutex. `uv-async-send!` shipped from v0.6.0 to
  v0.7.2 checking that a handle was open and then sending on it, and a close
  could free the handle in between (#33). The first fence proposed, a plain
  `with-mutex`, kept that hole. The second, `with-mutex` around
  `with-interrupts-disabled`, held the lock across an engine suspension: an
  engine dropped there kept it for good, and a collection could park its
  holder while a caller with interrupts disabled waited on it, deadlocking
  the process (PR #43's review). `with-send-fence` in `(libuv private
  handles)` shows what a fence needs:
  - take and release the lock inside one interrupt-free step, so no engine
    or collection can ever stop a thread that holds it;
  - raise nothing inside: answer a status, and raise after the release.

  `tests/test-async-fence.sps` holds both. Its sweeps probe the lock from
  another thread at every point where an engine can suspend the send or the
  close: the lock is recursive, so the thread holding it cannot see it
  held.

  `ensure-native-loaded!`, where every constructor starts, took its lock
  with a bare `with-mutex` until 2026-10-06. A constructor dropped in its
  exit thunk left the lock held for good. It now takes the lock inside
  `with-interrupts-disabled`, the reverse of #43's second fence: the lock
  is held only with interrupts disabled, and a raise from the init still
  unwinds both. `tests/test-constructors.sps` probes the lock after every
  dropped constructor.
* **A verb's open check does not cover its native call, and a dropped
  engine never finishes a verb.** No second thread is needed. An engine can
  suspend a verb between its check and its call, and a scheduler on the
  same thread can close the handle and run the loop meanwhile. Resumed, the
  verb calls libuv on freed memory. A new connection given the freed
  address gets the verb's effect: a `uv-write!` reported success and its
  bytes reached the new peer. An engine that is dropped runs nothing after
  its suspension, neither a `guard` nor a `dynamic-wind` exit. Whatever the
  verb had allocated but not yet handed to libuv is lost, or stays
  registered and counted for good.
  - Every stream verb shipped this way until each became one `one-step`
    (2026-10-06): check, pointer, allocation, registration and native
    call. `tests/test-stream.sps`'s split, reuse and drop sweeps hold
    them.
  - So did every constructor, `uv-accept!` included: a teardown between
    the loop check and the init linked the handle into the freed loop,
    and a drop after the init left a handle no teardown could close
    (`EBUSY` for good; for an async, a drain that never returns). Each is
    now one step too (`try-construct-handle`, `try-construct-loop`), and
    `tests/test-constructors.sps` sweeps them.
  - The other families ADR-0019's decision 3 amendments listed followed
    (#85, #86): the request verbs, the scratch and other handle verbs, and
    the loop queries. A verb that checks its handle's owner on entry
    checks it again in its step (`owned-handle-ptr`): the stream verbs'
    and the process kill's steps checked only that the handle was open,
    and a kill resumed after a handoff signalled its process from a thread
    that no longer owned the loop. Rule 8 of `tests/test-source-rules.sps`
    holds every route from a handle record to its pointer to the
    definitions it lists. A new verb, or a change to one, takes the same shape and the same
    sweeps: split, reuse and drop, and handoff for a verb that checks the
    owner on entry.
  - A refusal built after the step must not read the owner again. The
    steps answered a bare `'wrong-thread`, and the refusal read the
    loop's owner once the step was over: a loop handed on and back to the
    caller in between made fifteen verbs say `expected` = `actual` (#102).
    An owner check now answers an `owner-mismatch` holding what it
    compared, and a step tests its pointer with `refused?`, never
    `symbol?`, which would take the record for a pointer. Rule 9 holds
    both. `tests/test-owner-refusal.sps`'s hand-back sweep holds what each
    owner-checked verb's refusal names, and rule 9 fails a new
    owner-checked verb until that sweep lists it.
* **Affinity keeps each loop to one thread, not the process.** ADR-0019
  left the handle registry unlocked because only a loop's own thread uses
  that loop's handles. But the registry is one table for every loop, and
  from v0.6.0 on two loops run on two threads at once corrupted it in 4 of
  4 runs (#70). The walk cell, the orphan list and the debug shim's
  counters were shared the same way, losing pointers, events and updates.
  - The registry and the orphan list now hold one lock, taken only with
    interrupts disabled (`with-registry-lock`, over `with-step-lock`).
  - The walk cell is a thread parameter, and the counters are atomic.
  - `tests/test-loop-threads.sps` races each on two loops' threads, and
    sweeps engines over the calls whose way to the lock crosses a trap
    check.
  - Rule 6 of `tests/test-source-rules.sps` lists each process-wide
    variable in `src/` with how threads share it: what a library's top
    level defines and then assigns, changes in place or makes mutable,
    and each static in the C shim. A new one fails there until it is
    listed, and each word is checked against the source. The registry's
    uses must sit inside the lock, and its bodies call only table
    operations. Before adding state that more than one loop can reach,
    decide which of its words it is.
  - A race thread waits on the other only as long as the other makes
    progress (#74's rule), so no schedule can fail a correct build's
    precondition row. A suite whose rows race two threads needs the same.

### C and the FFI

* **`foreign-procedure` resolves its entry point when the expression is evaluated,
  not when the procedure is first called.** Every binding must be defined after
  `load-shared-object`, which is why the load is written as a definition placed
  ahead of them in `native.sls`. Getting this wrong fails at *import* time, not at
  first use, so the error points nowhere near the mistake.
* **A struct tag first named in a prototype's parameter list has prototype scope
  only** (C99 6.2.1p7). Forward-declare it at file scope before the prototype.
* **Chez encodes a `string` argument during the foreign call, and takes a
  `u8*` in a `__collect_safe` call without a word.** A caller's string
  changed after it was checked reached C changed, and a NUL cut it short
  (#51, #61). A `__collect_safe` copy out of a bytevector was corrupted by
  another thread's collection (#35). `tests/test-source-rules.sps` holds
  every foreign call in `src/` to both. No string crosses as a string
  argument, and no `__collect_safe` call takes `u8*`, `u16*`, `u32*`,
  `scheme-object`, `ptr`, `ftype-pointer` or `ftype-scheme-object-pointer`.
  It also keeps every call in a form those rules read, with no function
  ftype, pointer alias or other wrapper. And it holds the type families
  complete against every parameter type Chez's expander accepts.
* **A few bytes in front of a power-of-two allocation cost a whole macOS size
  class.** macOS malloc rounds 65,552 B (a 64 KiB read buffer behind a
  16-byte header) up to 81,920 B, and zeroing the request touches every
  16 KiB page of that: #48's review measured 65,823 B resident per reading
  stream become 82,289 B. glibc rounds to 16 bytes, so neither Linux nor
  either memory gate shows it. The alloc callback's descriptor lives in the
  stream's handle block instead, which keeps its 320 B class, and
  `tests/test-tcp.sps` holds the read buffer to its length within one malloc
  granule. Compare `malloc_size` of both sizes before putting a header on an
  allocation.
* **A continuation that escapes a callback strands the C frames under it
  for the life of its thread.** Every escape from a libuv callback leaves
  its `uv_run`'s frames on the thread's stack, and the next call pushes
  below them. A probe of #91's fix, 20,000 escapes on one thread, died with
  `SIGSEGV` on Linux at 8 MB (16,000 passed; a 64 MB stack held 40,000). On
  macOS the main thread held 20,000. A `fork-thread` thread there has
  pthread's 512 KiB default, and its 1,430th escape faulted (arm64). Those
  were timer callbacks' escapes, 352–384 B each on arm64. An escape from a
  callback `uv__io_poll` calls (a read, an async wake, a request's
  completion…) strands the poll's 1,024-event array too: 34,352 B on macOS
  and 22,272 B on Linux arm64, so that macOS thread holds 14
  (`.plans/2026-10-09-escape-headroom-check-design.md`). Measure an escape
  cost per callback kind, never from timers alone. The
  fault reached Scheme as "invalid memory reference", and #94's repro,
  which caught it and kept going, hung (#95; next trap). So every `uv_run`
  now starts in `run-step!`, which reads the thread's headroom through the
  shim first and refuses with `&uv-stack-exhausted` under a floor: 128 KiB
  for `uv-run`, 64 KiB for a teardown's drain, so that a refused run can
  still be torn down. Rule 11 of `tests/test-source-rules.sps` holds every
  `uv_run` there, and `tests/test-stack-headroom.sps` holds the floors
  against what one escape strands on the platform running it. A new path
  into `uv_run` goes through `run-step!` or it is unchecked. A suite that
  escapes callbacks in bulk (test-loop-claim's exit race) runs them in
  batches on threads it lets end, and docs/api.md tells users the cost.
  Each escape also strands a heap block, the `jmp_buf` Chez's `S_call_help`
  mallocs for the call into Scheme (312 B on aarch64 glibc), which even a
  thread's end does not free; so does an engine dropped inside a callback. Valgrind calls it reachable or definitely
  lost by collection timing, so the gate suppresses exactly it
  (`tests/valgrind-chez.supp`; #94, ADR-0003's amendment of 2026-10-09).
* **A fault caught from a `__collect_safe` call can deadlock the next
  collection.** Chez turns a `SIGSEGV` in foreign code into "invalid
  memory reference" and jumps back into Scheme, but a `__collect_safe`
  call had deactivated the thread, and nothing reactivates it until the
  next such call returns. A collection requested in between waits for
  good in `$collect-rendezvous`, at 0% CPU and with no message, even with
  one thread. `uv_run` is `__collect_safe`, so a thread whose stack runs
  out there and catches the error to keep going hangs: #94's repro did,
  on a macOS `fork-thread` thread (#95). macOS probes `uv__io_poll`'s
  32 KiB frame before moving `sp`, so the handler has room there. On
  Linux arm64 the same overflow, swallowing repro included, ended in a
  plain `SIGSEGV`; why it differs there was not measured. A Chez patched
  to reactivate in `do_error` stopped hanging, and ran on until the
  handler itself had no stack. Never treat that error as recoverable, and never write a
  `(guard (e (#t …)))` that swallows it in a loop. The no-libuv repro is
  `.plans/fault-deactivated-probe.sps`, and the upstream draft is
  `.plans/upstream-chez-fault-deactivated-issue.md`
  (`.plans/macos-thread-overflow-log.md`).
* **A return from a callback abandons every callback entered after it on
  the thread that has not returned.** Chez's `S_return` longjmps to the
  frame that entered the callback and drops every newer context from the
  thread's chain. A callback dropped that way can never return, so an
  engine suspended inside a callback can be resumed only while that
  callback still nests: on its own thread, after every callback entered
  since has returned, and before any callback that was running when it
  stopped has returned. Each way of breaking that was measured, and each
  raises "attempt to return to stale foreign context" and leaves a loop
  marked running for good:
  - two engines, the earlier resumed first: the later one's resume raises;
  - an engine started from a scheduler's timer callback that then
    returned: the engine's resume raises, from anywhere;
  - an engine resumed from inside a callback entered after it stopped: the
    engine finishes, and that callback's `uv-run` raises.
  A round-robin scheduler has the first shape, and a scheduler driven by
  libuv's own timers has the other two. docs/api.md promised that resuming
  always finishes the run. The first statement of this rule named only the
  first shape, and two rounds of review found the others (PR #115).
  - The same jump gives the stack back. 40,000 escapes, in batches of
    1,000 above an engine resumed after each batch, never grew the stack
    past one batch.
  - It does not give the heap back. `S_call_help` sets `CCHAIN` to the
    returning context *before* its walk "to unlock code objects that we're
    escaping past" (schlib.c:257-258). The walk stops at once, so the
    newer contexts' `jmp_buf`s are never freed, and their code objects
    stay immobilized.
  - test-loop's "two runs suspended inside callbacks" rows hold all
    three shapes and the safe order
    (`.plans/escape-costs-mutation-log.md`).

### The event loop and child processes

* **A single `uv-run 'once` is not guaranteed to fire an imminently-due
  timer.** libuv only arms a blocking poll timeout for a `UV_RUN_ONCE`
  iteration that ran no callbacks that same iteration, so one bare `'once`
  after activity can return before the timer comes due. This flaked exactly
  once in five CI runs. Always step with a capped `'once` loop
  (`run-until`-style), never a single call and never wall-clock.
* **A ticking wait's cap is a time budget, and CPU load does not test it.**
  `run-until/ticking` spends an iteration on every 1 ms tick, so a cap of 64
  gives up after about 64 ms. Under CPU load the ticks slow down along with
  the deliveries: 128 copies of test-tcp at once (load 411) never took a
  wait past 14 ticks, so running many copies proves nothing about a cap. A
  loopback flood on a box with CPU to spare does. There test-tcp's
  deliveries took up to 1529 ticks, and its waits at their old caps (64,
  and 1024 for the 1 MiB drain) failed by name in 12 of 125 runs.
  `tests/test-seed-gates.sps` now holds test-tcp's ticking waits to that.
  Other suites' ticking waits need measuring under a flood the same way
  (`.plans/tcp-delivery-cap-mutation-log.md`).
* **A completed write is not a byte in the peer's receive queue.** The write
  callback means the bytes reached the sending socket. The kernel delivers
  them to the peer after that, and under load the gap outlasts any fixed
  number of `'nowait` turns. test-tcp's reset section closed after two such
  turns. Under a loopback flood, up to one run in five closed on an empty
  queue, sent a FIN instead of an RST, and failed its contract rows with EOF.
  CPU load alone (load average 106) never did it. A fixture that depends on
  the peer's kernel state has to look at it: the section now waits on
  `recv(MSG_PEEK)` and asserts what it saw as a named precondition
  (`.plans/reset-precondition-mutation-log.md`).
* **A worker thread's cap on its own work races the loop thread's
  scheduling, and CPU load does test that.** Each worker in
  test-threading-stress's careless pool sent until refused or until
  1,000,000 sends, and the loop thread closed at its 50th wake. Idle, the
  busiest worker sent at most 9,049 times. With CPU hogs at load 76–160 it
  sent up to 774,427, and 3 of 170 suite runs at load 40–214 failed a
  correct build with `(never-refused 1000000)`: the one-off failure of
  2026-10-06. The pool now has no cap. What ends a worker on a build that
  never refuses is the contract instead: a send made once the close has
  begun is refused. Bound a worker by the other thread's progress, never by
  a count of its own. The discipline pool's 1,000,000-post cap had the same
  shape and hit it once at load 200; its posts now wait for the loop
  thread's drains. Any wait on another thread needs a bound of its own, or
  a broken build hangs where it should fail a row: each pool's join, and the
  discipline pool's wait for a drain, give up after 10 s and say so
  (`.plans/careless-pool-starvation-mutation-log.md`). The bulk-copy rows
  were the same shape inverted: a fixed count of copy intervals, and a
  verdict that needed the helper inside one. At loads of 170–340 it was
  in none, in either row. They now run until it has tried, parking it
  between intervals so each interval starts with it awake
  (`.plans/bulk-copy-liveness-mutation-log.md`).
* **A bounded retry assumes its draws are independent, and on CI they
  were not.** test-dns's queued-tail teardown and double-cancel rows needed
  a lookup still queued when a cancel looked, and retried up to 16 times
  at about 1% loss a draw. One CI run lost all 16 on a correct build
  (#127). Locally, 3,000 draws on macOS and Linux never lost twice in a
  row, whatever order the sweep cancelled in. A row that needs a race won
  makes the state certain instead: test-dns now waits until the pool's
  only worker is inside a dev-shim hold before it queues anything behind
  it (`.plans/dns-pool-hold-mutation-log.md`).
* **Chez resolves its boot files by argv[0], not by the executable's path.**
  A Chez child spawned with `file` = the real binary but argv[0] hardcoded to
  another name (e.g. `"chez"` against an install whose binary is `scheme`)
  hunts for a boot file named after argv[0], finds none, and dies of SIGABRT
  ~60-90ms in — with nothing on stdout or stderr even when inherited. Green on
  macOS (brew's binary really is named `chez`) and 15 straight local runs;
  dead on the first Linux CI run. Spawn Chez children with argv[0] = the
  binary's real name (tests/test-signal.sps passes the resolved path as both
  `file` and argv[0]); the A/B proof is in the v0.4 SDD ledger's diagnostic
  narrative.
* **Chez's collector reaps the children `open-process-ports` starts, and
  drops their status.** `s_process` records each child's pid. Each
  collection then calls `waitpid(pid, WNOHANG)` on the recorded children
  in the generations it collects, and keeps no status (`c/gc.c`, the
  `child_process` list). A collection between a child's end and the
  suite's own `waitpid` leaves that wait `ECHILD`. That happened once on
  CI: test-level-3's 1 MiB stderr row allocated while it drained, and its
  status came back `(wait-failed)` (#128).
  - The list moves up the generations with the child. A plain `(collect)`
    can miss a child that a collection promoted while it still ran:
    test-level-3's precondition, which shows the collector doing it,
    missed one time in three until it collected every generation.
  - `child-run` (`tests/uv-child.sls`) defers collections from the spawn
    to the last wait, through `collect-request-handler`, and puts the
    handler back when the last run on any thread ends. An explicit
    `collect` on any thread meanwhile can still take the status, and an
    engine dropped inside a run leaves collections off.
  - A row that counts zombies has the same hole: a collection clears
    them first. test-level-3 turns collections off for the whole suite.
  - test-level-3's outlived row, a child that ends while its pipes stay
    open for a second, with collections forced every 256 B, fails 10 runs
    in 10 without the deferral (`.plans/child-reap-mutation-log.md`).
  
  Only `open-process-ports` and `process` put a pid on that list, not
  libuv's `uv-spawn!`. A pid stays on it after its own waiter has reaped
  it, until a collection of its generation. A child that reuses the pid
  in that window, `uv-spawn!`'s included, can lose its status to the
  collector too. That takes the pid numbers wrapping around, and nothing
  holds it.

### The build (make)

* **Apple make 3.81 compares mtimes at whole-second granularity, and deleting a
  stale artifact from within the artifact rule's own evaluation makes it worse.**
  A stamp-identity flip in the same wall-clock second does not force a relink
  (GNU make 4.x sub-second mtimes mask this), and a delete performed by a recipe
  attached to the artifact's own rule runs after make has cached the target's
  stat — the build exits 0 with *no artifact at all*. Delete from a prerequisite
  of a PHONY aggregate that runs strictly before the artifact rule is stat'd
  (`relink-guard`, a prerequisite of `build`), or detect the flip at Makefile
  read time via a phony always-remade prerequisite. Both shapes verified in
  `.plans/stage-6-mutation-log.md` ("The guard's own failure mode, checked
  rather than reasoned about"); the broken shapes were hit in both this repo
  and chez-cmark-gfm on the same day.

### valgrind and ASan (the memory gate)

* **Anything between the memory tool and Chez gets checked instead of
  Chez.** Valgrind checks the command it is handed and does not follow an
  exec. `valgrind … timeout 900 scheme …` therefore checked timeout's two
  allocations while Chez ran natively and exited 0. #14 wrote that shape,
  and the Linux gate stayed green from 2026-08-30 to 2026-09-27; v0.6.0 and
  v0.7.0 shipped on it. On macOS, `DYLD_INSERT_LIBRARIES` is lost two ways.
  SIP purges it when it launches a protected binary such as `/bin/sh`, and
  the ASan arm's `sh -c` never loaded ASan from v0.1 on. ASan's Darwin
  runtime also strips itself from the variable in whatever process it loads
  into, so under `timeout` it is `timeout` that gets ASan. Put wrappers
  *outside* the tool, and put the preload on the `chez` command itself.
  `make check-memory-gate` holds this: it plants defects and requires the
  real recipe to fail on each, with the tool's own report in the log. Watch
  it go red whenever you touch either `test-memory` recipe.
  - Ad-hoc probes fall into this too, and ASan's `verbosity=1` banner will
    not show it: the banner prints in whichever process loaded ASan. On
    2026-10-05, probes run as `DYLD_INSERT_LIBRARIES=… timeout N chez …`
    reported no overrun. They took the banner in their logs as proof that
    ASan was live, and concluded that it cannot see the C shim's copies.
    With the preload on Chez, every one of those overruns was reported.
    The banner shows ASan is in Chez only when its `==PID==` is Chez's own.
    Better, ask through `check-memory-gate`: its `shim-overrun` mode now
    holds that answer.
* **A suppression is a check's business, not a comment's.** The gate has
  one, `tests/valgrind-chez.supp`, for the block Chez strands on each
  callback escape, and it was only added once a check could prove it:
  `make check-memory-gate`'s escape mode requires it to suppress exactly
  the three blocks three escapes strand, and the leak modes require it to
  hide none of theirs. A suppression also hides what the binding could do
  the same way, so `test-memory` fails any suite outside
  `MEMORY_ESCAPE_SUITES` whose own process had a block suppressed, and the
  stray-escape mode watches it fail. The three escapes' blocks are still
  reachable, and the one that gated was definitely lost, so the escape
  mode also requires the file's kinds to name definite. A new suppression
  gets the same: a mode that counts what it hides, a planted leak it must
  not, and a rule for where it may match at all.
* **A C thread-local in the shim is a malloc on every thread, and
  Valgrind hides it.** glibc allocates a dlopened library's `__thread`
  storage on each thread's first use. On x86-64 Valgrind's own default
  suppressions hide that block, and the gate counts every suppressed block:
  `check-memory-gate`'s escape mode went red on PR #126 (4 blocks for 3),
  and `test-memory` fails any non-escape suite with one. arm64's Debian 12
  showed no block at all, so only CI saw it. Rule 6 of
  `tests/test-source-rules.sps` holds the shim to no thread-local storage;
  keep per-thread state in a Scheme thread parameter.
* **valgrind gates on leak kinds it does not display.** `--errors-for-leak-kinds`
  defaults to `definite,possible` while `--show-leak-kinds=definite` hides the
  "possible" ones — the gate exits 9 with nothing in the log explaining why.
  Pass `--errors-for-leak-kinds=definite` explicitly. `make check-memory-gate`
  holds this with its `possible-leak` mode: it plants a block only an
  interior pointer reaches, and prints `GATE RED WITHOUT A REPORT` if the
  gate fails on it without printing its loss record. Separately, Chez's
  JIT-generated code produces uninitialised-value false positives by the
  hundreds from unstable call paths; the gate is scoped with
  `--undef-value-errors=no` (leaks and addressability stay fully enabled —
  ADR-0003's amendment records this).
* **memcheck deliberately delays freed-block reuse, so "recycled memory is
  dirty" is unobservable under valgrind by design.** Its freelist exists to
  catch use-after-free; no alloc-after-free warm-up depth ever returns the
  just-freed block. The dirty-memory seed in `test-native.sps` is
  environment-aware (`CHEZ_LIBUV_UNDER_VALGRIND`, exported by `test-memory`);
  its strong form runs in plain `make test`, which is where M35's mutation
  detection lives.

### CI and platform

* **Every Chez here is threaded, so nothing checks a claim about the other
  kind unless something runs one.** Chez builds `make-mutex`, `with-mutex` and
  the rest of its thread system only into threaded builds. The binding has
  imported them since v0.1, so it never loaded on a `--nothreads` Chez, while
  ADR-0019 called the threading work "free" there. That claim was reasoned,
  never run (#41).
  - A threaded Chez is now required, and a non-threaded one is refused by
    name. That works only because `(libuv private require-threaded)` is
    imported ahead of every `(chezscheme)` import. Chez processes imports in
    order, so a thread primitive imported first still fails with the bare
    "missing import for make-mutex".
  - When a library in `src/` gains a `(chezscheme)` import, import the
    refusal before it. `tests/test-require-threaded.sps` holds the order,
    and holds the refusal by expanding it with `(threaded?)` answering `#f`.
    `make check-nothreads-docker` proves both on a real `--nothreads` Chez.

* **glibc under strict `-std=c99` hides POSIX types that macOS exposes
  unconditionally.** `uv/unix.h` needs `pthread_rwlock_t`; every local macOS
  build passed and the first Linux compile failed. The Makefile adds
  `-D_DEFAULT_SOURCE -D_POSIX_C_SOURCE=200809L` in the non-Darwin branch only
  (defining `_POSIX_C_SOURCE` on macOS can hide BSD extensions).
* **apt's `chezscheme` is below this project's floor — 9.5.8 on Ubuntu 24.04,
  10.0.0 on 26.04, which CI runs on by name, not as ubuntu-latest — and
  building pinned Chez has two of its own traps.** CI builds 10.4.1 from
  the release tarball with `./configure --disable-x11 --disable-curses` (the
  expeditor otherwise requires X11/ncurses headers absent on runners) and a
  SERIAL `make` (parallel bootstrap raced: `nanopass.so` not created). A
  version assertion beside "Report versions" keeps the floor from silently
  drifting — the same check-not-comment logic as `check-pins`.
* **In a rootless container, `setuid` to another uid fails with `EINVAL`,
  not `EPERM`.** The Guix container is a user namespace that maps only the
  caller's own uid (`/proc/self/uid_map` is `1000 1000 1`), and the kernel
  rejects an unmapped uid before it checks permission. test-process's
  non-root `uid` row expected `EPERM` or `EACCES` and failed a correct build
  there. It now reads the map to choose which to expect, and rows on fixed
  maps hold the parser, since any one environment takes only one branch.
  An errno a row expects from the kernel can depend on the namespace it
  runs in.
* **In a linked worktree, `.git` is a file naming a directory outside the
  working tree, so a container that shares only the worktree has no
  repository.** git there says `fatal: not a git repository: (null)`, and
  `make check-pins` fails reading an empty submodule pin; chez-curl hit
  the same and took git out of its container. `scripts/guix-env` reads the
  `.git` file and shares the main repository's `.git` as well, and the
  self-test's `git-reads-repo` fails without it.
