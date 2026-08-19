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
* Add entries to `CHANGELOG.md` for each release
* Makefile should have a `help` command which lists all of the make commands.
* Library should be distributable with Akku.
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

## Traps this repo has already hit

Each of these shipped a passing test or a working-looking build that was wrong.
None is obvious from reading the code.

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
* **`foreign-procedure` resolves its entry point when the expression is evaluated,
  not when the procedure is first called.** Every binding must be defined after
  `load-shared-object`, which is why the load is written as a definition placed
  ahead of them in `native.sls`. Getting this wrong fails at *import* time, not at
  first use, so the error points nowhere near the mistake.
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
* **A struct tag first named in a prototype's parameter list has prototype scope
  only** (C99 6.2.1p7). Forward-declare it at file scope before the prototype.
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
* **valgrind gates on leak kinds it does not display.** `--errors-for-leak-kinds`
  defaults to `definite,possible` while `--show-leak-kinds=definite` hides the
  "possible" ones — the gate exits 9 with nothing in the log explaining why.
  Pass `--errors-for-leak-kinds=definite` explicitly. Separately, Chez's
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
* **A single `uv-run 'once` is not guaranteed to fire an imminently-due
  timer.** libuv only arms a blocking poll timeout for a `UV_RUN_ONCE`
  iteration that ran no callbacks that same iteration, so one bare `'once`
  after activity can return before the timer comes due. This flaked exactly
  once in five CI runs. Always step with a capped `'once` loop
  (`run-until`-style), never a single call and never wall-clock.
* **glibc under strict `-std=c99` hides POSIX types that macOS exposes
  unconditionally.** `uv/unix.h` needs `pthread_rwlock_t`; every local macOS
  build passed and the first Linux compile failed. The Makefile adds
  `-D_DEFAULT_SOURCE -D_POSIX_C_SOURCE=200809L` in the non-Darwin branch only
  (defining `_POSIX_C_SOURCE` on macOS can hide BSD extensions).
* **apt's `chezscheme` on ubuntu-latest is 9.5.x — below this project's floor —
  and building pinned Chez has two of its own traps.** CI builds 10.4.1 from
  the release tarball with `./configure --disable-x11 --disable-curses` (the
  expeditor otherwise requires X11/ncurses headers absent on runners) and a
  SERIAL `make` (parallel bootstrap raced: `nanopass.so` not created). A
  version assertion beside "Report versions" keeps the floor from silently
  drifting — the same check-not-comment logic as `check-pins`.
