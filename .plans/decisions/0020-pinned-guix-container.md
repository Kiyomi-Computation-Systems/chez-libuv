# ADR-0020: Builds and tests on a Guix host run in a pinned, toolchain-only container

- **Status:** Accepted (2026-10-09)
- **Date:** 2026-10-09
- **Scope:** development tooling. No library change.
- **Prior art:** chez-curl's ADR-0006, whose launcher, entry script, self-test and
  `require-tools` this copies. That ADR in turn copies cl-commonmark-gfm's ADR-0004 and
  chez-cmark-gfm's ADR-0018 and ADR-0019.
- **Related:** [ADR-0001](0001-hybrid-native-dependency-acquisition.md) (pkg-config or the
  vendored libuv) · [ADR-0003](0003-linux-valgrind-is-the-sole-memory-gate.md) (the memory
  gate) · [ADR-0013](0013-offline-deterministic-dns-tests.md) (no test needs the network) ·
  [mutation log](../guix-env-mutation-log.md)

## Context

The maintainer also develops on a Guix-managed x86_64 Linux machine: a foreign distro with
Guix Home. That host has no cmake, no Valgrind and no `chez`; its Chez is Guix Home's
`scheme`. Building there means installing a toolchain into the host, unpinned, where it
drifts from CI and from every other machine.

chez-curl solved the same problem with a pinned container: `guix time-machine` at one Guix
commit, a manifest of the toolchain and nothing else, no network, and a self-test that
proves those properties. This repository has the same needs, and four that chez-curl does
not:

1. **Chez must be at the floor, 10.4.1** (README.org, ci.yml's `CHEZ_FLOOR_VERSION`). The
   pin, `b532aa7d…`, packages 10.4.0, and so does Guix's master as of 2026-10-09.
2. **libuv must be at the floor, 1.48.0.** The pin's `libuv` is 1.44.2, which the Makefile
   passes over for the vendored build. The pin also has `libuv-for-node-lts`, 1.52.1: hidden
   from `guix search` but public in `(gnu packages libevent)`, and substituted, since node
   uses it.
3. **`make test` reads git.** It runs `deps` (`git submodule update --init`) and
   `check-pins` (`git ls-files`), and the vendored leg's `vendor` runs
   `git submodule update --init --recursive`. chez-curl's container has no git. Its Makefile
   was written for that, and this one was not.
4. **The suites spawn `/bin/cat` and `/usr/bin/id` by absolute path.** A plain Guix
   container has `/bin/sh` and no `/usr` at all.

Measured at the pin, in `guix shell --container` without `--network`: the one interface is
`lo`, and connecting to 192.0.2.1 fails at once with "Network is unreachable". With
`--emulate-fhs`, `/bin/cat`, `/usr/bin/id` and `/usr/bin/env` are the profile's coreutils.

## Decision

**Copy chez-curl's container, with the changes below.**

1. **The launcher.** `scripts/guix-env` runs
   `guix time-machine -C channels.scm -- shell -m manifest.scm --container --emulate-fhs -- sh scripts/guix-env-enter CMD…`.
   - It runs without `--network`.
   - It runs with `--emulate-fhs`, for the suites' `/bin/cat` and `/usr/bin/id`. chez-curl
     rejected the flag because it looks up libraries by bare name. Nothing here does:
     `config.sls` names libuv and the shim by absolute path.
   - The default command is `bash`. It refuses to run inside a Guix environment. It
     preserves only `TERM`, `COLORTERM` and `LANG`.
   - In a linked worktree it also shares the main repository's `.git`, the git common
     directory (decision 4).
   - `GUIX_ENV_DRY_RUN=1` prints the command instead of running it, for the host-side
     tests.
2. **The pin.** `channels.scm` pins Guix at `b532aa7d0bb345aafabf6b63cbfbda45abbec091`,
   chez-curl's pin and this host's Guix.
3. **The manifest.** `manifest.scm` holds:
   - **Chez 10.4.1, built from source, without its own test suite.** It is Guix's own
     `chez-scheme` recipe at the `v10.4.1` tag, with its boot files rebuilt from the same
     source, since Chez refuses to build from another version's boot files. The first
     `scripts/guix-env` builds it in about two minutes: 72 s for the boot files and 55 s
     for Chez, measured here. Later runs reuse the store item.

     Chez's test suite is off. Guix's recipe calls it "on the order of an hour", and no
     substitute server will ever carry this variant, so every machine and every pin bump
     would pay it. What it would protect is checked another way: `make check-guix` asserts
     this Chez's version and threading, then runs this project's suites on it, and
     `check-memory-gate` and `test-memory` run on it under Valgrind. The suite was run once,
     with the variant's tests on ([amendment](#measured-2026-10-09)).

     Overriding the recipe's arguments evaluates the parent's arguments with `this-package`
     bound to the parent, and its `unpack` phase names `(package-source this-package)`. Left
     alone, it unpacked 10.4.0's source. The variant replaces `unpack` with one that unpacks
     the 10.4.1 source.
   - `libuv-for-node-lts` (1.52.1, the vendored submodule's version) and `pkg-config`, so the
     default build takes the pkg-config leg at a libuv above the floor.
   - `gcc-toolchain`; `cmake` for the vendored leg (`make HAVE_PKG=no …`); `valgrind` for
     the memory gate.
   - `git` (decision 4).
   - The shell tools the Makefile, the scripts and the suites' children call, and nothing
     else.
4. **git is in the container, with nothing to act as anyone with.** The Makefile is left as
   it is, and `make test` in the container runs `deps` and `check-pins` as it does
   everywhere. The container gives git no identity, no credentials and no network:
   - Nothing of `HOME` is shared: no `~/.gitconfig`, `~/.git-credentials`, `~/.ssh` or
     `~/.config/gh`.
   - Only three variables are let in: no `SSH_AUTH_SOCK`, `GH_TOKEN` or `GIT_ASKPASS`.
   - The only interface is loopback.

   So git there can read the repository and check out submodules already cloned, and cannot
   commit as anyone, fetch or push. The first `git submodule update --init` clones, so it
   runs on the host.

   The repository's own `.git/config` is shared, since the repository is. The self-test
   fails if it carries an identity, a credential helper, or a URL with a password.

   chez-curl found that git in a container breaks every linked worktree. A worktree's `.git`
   is a file naming a directory inside the main repository's `.git`, outside the one
   directory the container shares. So the launcher reads that file, without git, and also
   shares the common directory it names, read-write, since `git submodule update` writes
   there. It shares only a git directory, one with a `HEAD`. It refuses a directory that holds
   the checkout or HOME, as a hand-edited `gitdir: ..` would name, and a path with `=`, which
   guix would split.
5. **What `scripts/guix-env-enter` sets inside the container:**
   - **`CHEZ`** is `$GUIX_ENVIRONMENT/bin/scheme`, the real binary. The Makefile's default,
     `chez`, is not in the profile. A `chez` symlink breaks boot-file lookup, and a wrapper
     script hides Chez from Valgrind.
   - **`CC`** is `$GUIX_ENVIRONMENT/bin/gcc`. `gcc-toolchain` installs no `cc`.
   - It refuses to start when `bin/scheme`, `bin/gcc` or `lib/pkgconfig/libuv.pc` is
     missing.
   - **No `LD_LIBRARY_PATH`.** pkg-config finds libuv through the `PKG_CONFIG_PATH` the
     profile sets, and the shim records libuv's absolute path.
6. **`scripts/require-tools GOAL TOOL…`** fails a target before it runs when a tool is
   missing. On a Guix host outside any environment, it points at `scripts/guix-env make
   GOAL`. The Makefile calls it from:
   - `require-toolchain`, the first prerequisite of `build`: `$(CC)` and `$(CHEZ)`, plus
     git and cmake on the vendored leg;
   - `deps` (git);
   - `vendor` (git and cmake);
   - `test-memory`'s Linux arm (valgrind);
   - `check-guix` (guix).
7. **`make check-guix`** runs `tests/guix-env-launcher.sh` on the host, then
   `make check-guix-inside` in the container. The self-test asserts:
   - the container's `HOME`, and every directory on the way down from it, holds only the
     path to the repository and, in a worktree, to its common directory;
   - scheme, gcc, pkg-config, cmake, valgrind, git and make resolve to the profile's own
     binaries, both on the PATH make runs with and however a login shell rebuilds it;
   - `CHEZ` lies under the profile, is an ELF binary, and Valgrind instruments it;
   - that Chez reports a version number at or above the floor (read from the Makefile, which
     reads ci.yml; command-line variables are not passed to that make), and is threaded;
   - `CC` lies under the profile, and builds and runs a program against `<uv.h>` and libuv;
   - pkg-config's libuv is at the floor (read from the Makefile), `make deps-info` chooses
     pkg-config, and the library it names is in the store;
   - `/bin/sh`, `/bin/cat` and `/usr/bin/id` exist;
   - the network is loopback only;
   - git reads this repository, worktree or not;
   - git has no identity, no credential settings (`credential.*`, `http.*.extraheader`,
     `core.askPass`), no URL with userinfo in a remote or an `insteadOf` key, and no agent.
     It prints key names only, with userinfo masked;
   - `make check-help` and `make test` pass inside.

   Each assertion is watched failing under a targeted change before it counts
   ([mutation log](../guix-env-mutation-log.md)).
8. **People and agents edit, commit, fetch and push on the host.** Builds and tests go
   through `scripts/guix-env`.

### Rejected

- **No git in the container, as chez-curl has it.** `deps` and `vendor` would have to skip
  git once the submodules are filled, and `test`, `test-memory` and `test-threading` would
  stop depending on `check-pins`. That weakens `make test` on every host. A pin bump pulled on
  the host would also stop resyncing the submodules on its own.
- **Guix's Chez 10.4.0.** It is below the floor the README promises and CI asserts. A green
  run on it would claim support for a Chez that CI never ran.
- **The pin's `libuv` (1.44.2).** The Makefile would pass it over for the vendored build,
  and the pkg-config leg would go untested here.
- **Changing the suites' `/bin/cat` and `/usr/bin/id` to PATH lookups.** That is a change
  to the tests for the sake of one environment, on every platform. `--emulate-fhs` gives the
  container the paths every FHS host has.
- **`--network`.** Nothing fetches at build or test time (ADR-0013). Without it, "no test
  touches the network" is a property of the environment, checked by the self-test.
- **Agents inside the container.** chez-cmark-gfm tried that in its ADR-0018 and withdrew it
  in ADR-0019.

## Consequences

- **The container is a user namespace that maps only the caller's uid.** `setuid` to any
  other uid fails with `EINVAL` there, not `EPERM`: the kernel rejects an unmapped uid before
  it checks permission. test-process's non-root `uid` row reads `/proc/self/uid_map` to
  choose which errno to expect. Rows on fixed maps hold the parser, since any one
  environment takes only one branch.
- **`make test-root` cannot run in the container,** which has no root. It runs where it
  always has: under sudo on a host with a toolchain, and in CI.
- **The Docker targets (`test-memory-docker`, `check-nothreads-docker`) run on the host.**
  On this Linux host, `scripts/guix-env make HAVE_PKG=no test-memory` runs CI's own
  Valgrind leg directly, which is what `test-memory-docker` exists to give a macOS box.
- **The CI floor job is not reproduced.** The container's pkg-config leg links libuv 1.52.1,
  not 1.48.0. CI's floor job remains the only run at the libuv floor.
- **The first `scripts/guix-env` builds Chez from source,** in about two minutes, and
  fetches the rest as substitutes. Later calls pay only the `time-machine` start, about 3 s.
  Batch commands: `scripts/guix-env sh -c 'make a && make b'`.
- **No CI job runs the container.** CI keeps its own toolchain. The container and CI can
  drift apart. The self-test's floor assertions keep the container's Chez and libuv at or
  above CI's floor.
- **The container isolates the toolchain; it is not a sandbox.** The repository, and in a
  worktree the main repository's `.git`, are shared read-write, and the host later runs what
  the container writes there.
- **Bumping the pin** means changing `channels.scm` and running `make check-guix`. When Guix
  packages Chez 10.4.1 or later, the manifest's variant goes, and the floor assertion says
  whether the pin's own Chez will do.

## Measured, 2026-10-09

On this host (x86_64, 18 cores), at the pin, with the [mutation log](../guix-env-mutation-log.md)
holding each check's failure:

- **`make check-guix`**: the host tests (87 checks), then the self-test and `make test` in
  the container, in 25 s once the profile is cached.
- **`make test`** passes in the container on both legs: pkg-config against libuv 1.52.1,
  and the vendored build (`make HAVE_PKG=no vendor test`, 32 s with cmake's build).
- **`make check-memory-gate`** prints `MEMORY GATE CAN FAIL`: every planted defect is
  caught, and the escape mode's three jmp_bufs are suppressed (600 bytes in 3 blocks, 200 B
  each on x86_64, against 312 B on aarch64).
- **`make HAVE_PKG=no test-memory`**, CI's Valgrind leg, passes in 321 s.
- **One suite row failed a correct build in the container:** test-process's non-root `uid`
  row, which got `EINVAL` (Consequences, above).
- **Chez 10.4.1's own test suite, under Guix's recipe:** passed, once, in a build of the
  variant with its tests on. The check phase took 3108 s, 52 minutes, across 12
  configurations. That build is the evidence for the variant: its build itself took 35 s.
  The manifest's variant differs from it only in skipping that phase and in its replaced
  `unpack`, which unpacks the same 10.4.1 source.
