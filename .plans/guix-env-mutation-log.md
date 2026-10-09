# Guix development container mutation log

Evidence that the checks [ADR-0020](decisions/0020-pinned-guix-container.md) added fail
through the property each claims to guard. Every mutation was applied to a fresh copy made
in the session scratchpad; the working tree was never edited. A driver applied each one,
flagged any that changed nothing, and kept the failures verbatim.

`/bin/sh` is dash on the host these ran on, so the scripts and the host-side tests ran under
a strict POSIX shell. Inside the container, `sh` is bash.

## Host side (`tests/guix-env-launcher.sh`)

Each copy held the Makefile, `scripts/`, the shim's two sources, the test and ci.yml. Each
mutation ran in its own copy, so the run after it is the baseline itself. The table is the
final run, after the review's fixes ([below](#the-review)).

**Baseline:** `100 passed, 0 failed`, exit 0.

| # | Mutation | Failed (all others passed) |
|---|---|---|
| L1 | `--network` added | `T1 no network flag`, `T1 the whole command`, and the whole-command checks of T10–T13 |
| L2 | `--emulate-fhs` dropped | `T1 emulates FHS`, `T1 the whole command`, T10–T13's |
| L3a | `SSH_AUTH_SOCK` added to `--preserve` | `T1 preserves only TERM, COLORTERM and LANG`, `T3 [make check-guix-inside] no agent socket`, `T3 [no-args] no agent socket`, `T1 the whole command`, T10–T13's |
| L3b | a second `--preserve=^HOME$` | `T1 preserves only …`, `T1 the whole command`, T10–T13's |
| L4a | `"--share=$HOME/.ssh"` added | `T1 main checkout: shares nothing more`, both T3 cases' `no --share` and `nothing from HOME`, `T13 git dir inside the tree: shares nothing more`, the whole-command checks |
| L4b | `"--expose=$HOME/.gitconfig"` added | both T3 cases' `no --expose` and `nothing from HOME`, the whole-command checks |
| L5 | the nesting refusal deleted | `T4 nested: exit 2`, `… names GUIX_ENVIRONMENT`, `… prints no command` |
| L6 | `cd "$root"` deleted | `T5 subdirectory: runs from the repo root` |
| L7 | `"$@"` unquoted in the guix command | `T2 args pass through verbatim` |
| L8 | default command `sh`, not `bash` | `T1 enters through guix-env-enter`, `T1 the whole command` |
| L9 | `-C channels.scm` dropped | `T1 pins guix via channels.scm`, `T1 uses manifest.scm`, `T1 the whole command`, T10–T13's |
| L10 | `--container` dropped | `T1 container flag`, `T1 the whole command`, T10–T13's |
| W1 | the common directory never shared | `T10 worktree outside`, `T11 worktree inside main`, both T12 cases, `T13 separate git dir: shares it` |
| W2 | the gitdir shared instead of the common directory | T10, T11, both T12 cases. T13's separate git dir has no commondir, so there the two are one directory |
| W3 | a relative gitdir not resolved against `$root` | **Survived; see the finding below** |
| W4 | the `commondir` file ignored | T10, T11, both T12 cases |
| W5 | a relative `commondir` taken as it is | T10, T11, `T12 relative gitdir` (the absolute case is unaffected) |
| W6 | a common directory inside the tree shared too | `T13 git dir inside the tree: shares nothing more` |
| W7 | the no-gitdir-line refusal dropped | `T14 no gitdir line: says why`. An empty gitdir resolves to the checkout itself, which V1's rule then refuses, so the launcher still exits 2 and runs nothing; only the message is W7's |
| W8 | a missing common directory not refused | `T14 missing git dir: exit 2`, `… says why`, `… prints no command`, `T15 a directory with no HEAD: exit 2` |
| W9 | the `--share` flag put after the `--` that ends guix's options | T10, T11, both T12 cases, T13's separate git dir |
| E1 | the entry script's host refusal deleted | `T6 enter on host: exit 2`, `… says why, and what to use`. `… runs nothing` passed: `set -u` stops the script at the first `need`. E10 fails it |
| E2 | `export LD_LIBRARY_PATH="$GUIX_ENVIRONMENT/lib"` | `T7a no LD_LIBRARY_PATH` |
| E4 | `need …/lib/pkgconfig/libuv.pc` deleted | T7b's and T7c's `exit 2`, `names …` and `runs nothing` |
| E5 | `need` widened to accept a dangling symlink | T7c's three |
| E6a, E6b | `need …/bin/scheme`, then `need …/bin/gcc`, deleted | T7d's three, then T7e's three |
| E8 | `exec "$@"` unquoted | T7a's four checks, since its command is one `sh -c '…'` argument that splits, and `T8 enter passes args verbatim` |
| E9a, E9b | `CC=gcc`, then `CHEZ=scheme` | `T7a CC is the profile's gcc`, then `T7a CHEZ is the profile's scheme` |
| E10 | `exec "$@"` right after `set -eu` | 17, among them `T6 enter on host: runs nothing` and every `runs nothing` of T7b–T7e |
| Q1 | the hint's `GUIX_ENVIRONMENT` test dropped | `R4 inside an environment: install hint` |
| Q2 | `break` after the first missing tool | `R3 two missing: both named, then one hint`, `M4 vendored build without git or cmake: names both` |
| Q3 | usage test `-lt 2` changed to `-lt 1` | `R6 no tools: exit 2`, `R6 no tools: usage` |
| Q4 | `echo all found` on success | `R1 all found: silent` |
| Q5 | `exit 0` after `set -eu` | 18: every `exit 2` and stderr check of R2–R6, and every M case's naming check |
| Q7 | `$goal` dropped from the container hint | R2's and R3's stderr checks |
| K1 | check-guix's `require-tools … guix` deleted | `M1 … names the goal`, `M1 … runs no test` |
| K2 | that line prefixed with `-`, so make ignores its failure | `M1 … runs no test` |
| K3 | `require-toolchain` dropped from `build`'s prerequisites | `M2 … hint names test`, `M2 … runs nothing`, `M3 … names it`, `M3 … runs nothing`, `M4 … runs nothing`. M4's naming row passed: `vendor`'s own check names git and cmake for `make build` |
| K4 | `require-toolchain` moved after `$(SHIM)` | `M2 … runs nothing`, `M3 … names it`, `M3 … runs nothing`, `M4 … runs nothing`: the stamps, git and cmake run first |
| K5 | `require-toolchain` passes `$@`, not `$(GOAL)` | M2, M3, M4's naming rows: the hint names `require-toolchain` |
| K6, K7 | `$(CHEZ)`, then `$(CC)`, not required | `M2 … names test`, `M2 … runs nothing`; then `M3 … names it`, `M3 … runs nothing` |
| K8 | the vendored leg's git and cmake not required | `M4 … runs nothing` |
| K9 | that condition inverted to `HAVE_PKG=yes` | `M4 …` |
| K10 | `deps`'s `require-tools … git` deleted | `M6 make deps without git: names it` |
| K11 | `vendor`'s `require-tools … git cmake` deleted | `M5 make vendor without cmake: names it`, `M5 … runs no git` |
| K12 | test-memory's `require-tools … valgrind` deleted | `M7 make test-memory without valgrind: names it` |
| K13 | `GOAL = $@` | M2, M3, M4's naming rows |
| V1 | the refusal of a directory holding the checkout deleted | T15 `the checkout's parent`'s three |
| V2 | the refusal of a directory holding HOME deleted | T15 `HOME itself`'s and `HOME's parent`'s three |
| V3 | the refusal of a path with `=` deleted | T15 `a path with =`'s three |
| V4 | the `HEAD` check made `true` | T15 `a directory with no HEAD`'s three |
| V5 | `${common%/}` back to `$common` in the checkout rule | **Survived**: it matters only for `/`, and only where `/HEAD` exists; without one, the `HEAD` check refuses `/` anyway. See Not covered |
| V6 | the missing-directory error names the resolved path | `T14 missing git dir: says why`: the resolved path is empty by then |

### Finding: the launcher resolved a relative gitdir twice

W3 deleted the line that made a relative gitdir absolute against `$root`, and all 87 checks
still passed, T12's relative-gitdir case among them. That case's expected command names the
absolute common directory, so it is not an empty check. The line itself was dead: the
launcher has already `cd`'d to `$root`, so the relative path resolves from there
regardless, and the `cd … && pwd` that follows makes it absolute. The line is gone, and the
comment says why a relative gitdir needs nothing more. L6, which deletes the `cd`, is still
caught by T5.

## Notes (host side)

- **K4 was misread in the first draft of this log,** as "the shim's link runs first, and
  the stub compiler starts". At the time, the copy held no shim sources, and make stopped at
  a missing prerequisite; only the naming rows failed. The review caught it. The copy now
  holds them, and stubs record `mkdir`, `rm` and `touch`, which is what the table records.

- **`T1 uses manifest.scm` is positional.** L9 failed it because the lines shifted. `T1 the
  whole command` is the check that pins the manifest's place.
- **V5, the launcher's `${common%/}`,** only matters on a host with a `/HEAD`; elsewhere the
  `HEAD` check refuses `/`.
- **The M cases run make with only stubs on PATH.** make prints a few `printf: No such file
  or directory` lines while it reads the Makefile; each case compares only the lines it
  names.

## Container (`make check-guix-inside`)

Each mutation ran `scripts/guix-env make check-guix-inside` in a fresh copy of a scratch
clone. The clone's submodules were cloned from this checkout's own `.git/modules`, with
this branch's working tree laid over it and the manifest touched. Setup-only mutations
change the copy after it is made: the entry script, through a snippet read in after its
`export CC=` line, or the clone's own git config.

**Baseline:** `check-guix: ALL CHECKS PASSED`, exit 0, in 24–26 s, `make test` included.

| # | Mutation | Failed |
|---|---|---|
| S1 | `--container --emulate-fhs` dropped: plain `guix shell` | `isolated-home`, once for each of 47 entries of the host's HOME, `.ssh`, `.gnupg`, `.password-store` and `.gitconfig` among them; `tool-path[-lc]` and `[-lic]` for scheme, which a login shell found in Guix Home (10.4.0); `loopback-only`, naming the host's 11 interfaces; `no-git-credentials`, twice, for your identity |
| S2 | `--network` added | `loopback-only` (`/sys/class/net` is not mounted, and 192.0.2.1 did not refuse at once), and `test`: test-dns's double-cancel and queued-tail rows, which depend on the resolver having nowhere to go |
| S3 | `--emulate-fhs` dropped | `fhs-paths` for `/bin/cat` and `/usr/bin/id`, and `test`: 11 rows of test-process-steps and test-process that spawn `/bin/cat` |
| S4 | `CHEZ` a wrapper script that `exec`s the profile's scheme | `chez-variable`, `chez-is-elf` (`23212f62`, `#!/b`), `valgrind-instruments-chez` |
| S5 | the same wrapper without `exec` | `chez-variable`, `chez-is-elf`, and `test`: test-signal's four ack rows, since its signals reach the shell, not Chez. `valgrind-instruments-chez` passed: Valgrind reported on the shell |
| S6 | `CHEZ` a symlink named `chez` | `chez-variable`, `chez-threaded` (`cannot find compatible chez.boot in search path`), `test`. `chez-floor` passed, and rightly: `--version` prints the version before Chez looks for boot files |
| S7 | `CC=gcc` | `cc-variable` |
| S8 | the pin's own `chez-scheme`, 10.4.0 | `chez-floor: … is '10.4.0', below the floor 10.4.1`. Every suite passed on it |
| S9 | ci.yml's `CHEZ_FLOOR_VERSION` raised to 10.4.2 | `chez-floor: … is '10.4.1', below the floor 10.4.2`: the floor is read, not written down |
| S10 | the pin's own `libuv`, 1.44.2 | `libuv-floor: pkg-config's libuv is '1.44.2', below the floor 1.48.0`. `make test` passed on the vendored build the Makefile then chose |
| S11 | `unset PKG_CONFIG_PATH` | `libuv-headers` (`undefined reference to uv_version_string`: gcc still found the header), `libuv-floor` |
| S12 | a stub `cmake` first on the inherited PATH | **Survived at first; see the finding below.** After the fix: `tool-path[env]` for cmake |
| S13 | `git config credential.helper store` | `no-git-credentials: git has credential settings: credential.helper store` |
| S14 | origin's URL given a user and password | `no-git-credentials: a URL carries a password: remote.origin.url https`. The password is not printed |
| S15 | `git config user.email …` | `no-git-credentials: git has user.email …` |
| S16 | `SSH_AUTH_SOCK` exported | `no-git-credentials: SSH_AUTH_SOCK is set` |
| S17 | `--expose=$HOME/.gitconfig` | `isolated-home` for `.gitconfig`, and `no-git-credentials` twice, for your identity |
| S18 | `git` dropped from the manifest | `tool-path[-lc]`, `[-lic]` for git, `git-reads-repo`, `test`. `make test` stopped at `make deps: git not found.` |
| S19 | `## ` removed from `help`'s line | `check-help` |
| S20 | a suite that exits 1 added | `test` |
| S21 | an `http.<url>.extraheader` with a basic-auth header, as actions/checkout leaves one | `no-git-credentials: git has credential settings: http.https://example.com/.extraheader` |
| S22 | origin's URL given a token as its user, no password | `no-git-credentials: a URL carries credentials: remote.origin.url` |
| S23 | an `insteadOf` rule whose key carries a token | `no-git-credentials: a URL carries credentials: url.https://***@example.com/.insteadof`. The first run printed the token: the key is the URL. Userinfo is now masked |
| S24 | `core.askPass` set | `no-git-credentials: git has credential settings: core.askpass` |
| S25 | `CHEZ` a script that prints Chez's boot-file error and exits 1 | `chez-floor: … is 'Exception: cannot find compatible scheme.boot in search path', not a version at or above the floor 10.4.1` |
| F1 | S25, with `at_least`'s check that the version is a dotted number removed | `chez-floor` **passed**: `sort -V` puts a digit before a letter, so any message counted as later than the floor. This is the control for the review's first finding |
| F2 | run on this checkout, under HOME, with one file of the sibling chez-curl checkout exposed | `isolated-home: /home/kishu/src/chez-curl is visible inside the container` |
| F2b | F2 with the walk cut back to HOME's top level, as first written | `isolated-home` **passed**: the control for the review's second finding |
| F4 | `make check-guix-inside CHEZ_FLOOR_VERSION=10.4.0`, on the pin's Chez 10.4.0 | `chez-floor: … is '10.4.0', not a version at or above the floor 10.4.1` |
| F4b | F4 with `cleanmake` passing MAKEFLAGS through | `chez-floor` **passed** (`10.4.0, floor 10.4.0`): the control |
| U1 | test-process's `uid-mapped?` always true | `uid as non-root is refused at spawn: …`, actual `(raised EINVAL expected (EPERM EACCES))` |
| U2 | a mapping line answers false | `uid map: the initial namespace's maps uid 1`, `… it does map its own uid`, `… a later line can map it` |
| U3 | the spawn given no `uid` option | `uid as non-root is refused at spawn: …`, actual `(raised no-raise expected (EINVAL))` |
| U4 | a range's end taken as inside it | `uid map: a range's end is outside it` |
| U5 | only the map's first line read | `uid map: a later line can map it` |
| U6 | a range's start ignored | `uid map: a rootless container's, only its own uid, does not`, and the spawn row, actual `(raised EINVAL expected (EPERM EACCES))` |

U1–U6 ran test-process.sps alone, in the container, against a copy of the tree. Before the
map rows existed, U2 survived: no container run can take the branch where uid 1 is mapped.
The parser now has rows on fixed maps of both kinds.

### Worktrees

A clone under `$HOME` (in `build/`, which git ignores) with a linked worktree in the
scratchpad, outside `$HOME`, so the container's `$HOME` holds the path to the shared `.git`
and not to the worktree.

| # | Case | Result |
|---|---|---|
| WT0 | baseline | `ALL CHECKS PASSED`; `isolated-home` names both paths, `git-reads-repo` the common directory |
| WT1 | the launcher's share removed (W1) | `git-reads-repo: toplevel 'fatal: not a git repository: (null)'`, and `test`: `check-pins` read an empty submodule pin |
| WT2 | the self-test's allowance for the common directory removed | `isolated-home` for `/home/kishu/src`, and, with the walk the review asked for, each directory below it on the way to the clone's `.git` |

WT0–WT2 were run again after the review's fixes, with the same results.

### Finding: a stub first on PATH reached make, unseen

S12 put a stub `cmake` ahead of the profile on the PATH the entry script hands on, and every
check passed. `tool-path` asked only login shells, which rebuild PATH from the container's
`/etc/profile` and never saw the stub. make runs with the inherited PATH, though, so a
vendored build would have run it. `tool-path` now also resolves each tool on the self-test's
own PATH, `tool-path[env]`, which is make's.

### Finding: the driver's empty field

The first run of S4–S7, S11–S16 and S20 passed every check. Each mutation was a setup
command with an empty sed field before it, and `read` collapses two adjacent tabs, since a
tab is whitespace to it. The setup landed in the sed field, which a `-` file skips, so
none of them ran. The rerun, with a placeholder in the field, is what the table records.

## The review

A read-only adversarial review on Opus, after the build, reproduced these in scratch.
Each fix has a row above that fails without it:

1. **`at_least` passed any text that starts with a letter**, so a Chez that printed an error
   for `--version` met the floor. The version must now be a dotted number (S25, F1).
2. **`isolated-home` listed only HOME's top level,** so a sibling of the checkout under an
   entry that leads to it went unseen. The assertion now walks every directory on the way
   down to the checkout and to the common directory (F2, F2b, WT2).
3. **`no-git-credentials` missed `http.*.extraheader`, `core.askPass`, a token as a URL's
   user, and a token in an `insteadOf` key** (S21–S24).
4. **The launcher shared whatever the `.git` file named.** `gitdir: ..`, `/` or HOME would
   have shared a parent of the checkout. It now refuses a directory that holds the checkout
   or HOME, a path with `=`, which guix splits at, and anything without a `HEAD`
   (T15, V1–V4).
5. **The missing-directory error printed an empty path** (V6).
6. **Host rows that could not fail.** The make copy had no shim sources, so a build whose
   check was gone stopped at a missing prerequisite anyway. M2's "writes no config.sls" and
   M6's "runs nothing" could not fail even with the sources there, and are gone (K3, K4).
7. **The hint's wording promised too much.** It names the goals typed, not variables set
   on the command line, and `make prod` cleans before its inner build checks. The comments
   and docs/building.md now say so.

It also flagged, unreproduced: `makevar` and `deps-info` inheriting the outer make's
MAKEFLAGS, which F4 then confirmed and `cleanmake` fixes; and three ways of stating the
start-up time, now one (about 3 s).

## Not covered

- **`chez-threaded` on a Chez that answers `#f`.** No non-threaded Chez is at hand here. S6
  fails the assertion, but because Chez aborts, not through threading.
  `make check-nothreads-docker` holds the binding's own refusal.
- **`libuv-floor`'s store check.** No environment here offers pkg-config a libuv outside the
  store.
- **`no-git-credentials` for `GIT_ASKPASS`, `SSH_ASKPASS`, `GH_TOKEN` and
  `GITHUB_TOKEN`.** One loop checks every variable, and S16 fails it through
  `SSH_AUTH_SOCK`.
- **test-process's `uid-mapped?` where there is no `/proc/self/uid_map`.** That is macOS,
  where the row expects `EPERM` or `EACCES` as before.
- **test-process's uid row widened to accept `EINVAL` everywhere.** That passes on every
  host: no environment here maps uid 1 and refuses with `EINVAL`. The map rows hold the
  parser that picks the expected errno, not the choice to have one per branch.
- **The launcher under symlinked paths, and clones with alternates.** Reasoned by the
  review, not run. A missing share fails `git-reads-repo`, and nothing extra is shared.
