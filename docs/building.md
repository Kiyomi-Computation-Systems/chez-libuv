# Building and testing

This page is for working on chez-libuv itself: building it from source,
running its test gates, and building this documentation. To *use* the
library, [installing](installing.md) is all you need.

`make help` lists every target.

## What make build does

`make build` compiles the C shim and writes
`src/libuv/private/config.sls`. That file holds the shim's absolute path,
the absolute paths of the libuv libraries to load before it, and the range
of libuv versions the binding accepts.

- `config.sls` is **generated and gitignored**. A fresh clone runs
  `make build` before `(import (libuv))` can work.
- **Run it again after every upgrade.** The shim's exports change between
  releases, and a shim built from older sources fails the import with
  `&uv-shim-unavailable`.
- Because `config.sls` is built for each machine, no source-only
  distribution can work without this step, an Akku package included.

## Where libuv comes from

The floor is **libuv 1.48.0**: Ubuntu 24.04 LTS's libuv, which CI tests
against. `make build` derives the version range it writes into `config.sls`
from it. libuv keeps its binary interface stable across 1.x, so this is a
range check, not an equality test. A runtime libuv outside the range makes
the binding raise `&uv-version-incompatible` when it starts, rather than
run.

Which libuv you get depends on whether
`pkg-config --atleast-version=1.48.0 libuv` succeeds:

- **It succeeds** (for example `brew install libuv` on macOS, or
  `libuv1-dev` on Ubuntu 24.04 or 26.04). The shim is compiled against that
  installed libuv. Nothing under `vendor/` is touched.
- **It fails**, because no system libuv is installed, or because the
  installed one is older than the floor (Debian 12's is 1.44.2). Then the
  same `make build`:
  1. runs `git submodule update --init --recursive`;
  2. builds the pinned `vendor/libuv` submodule with CMake, as a shared
     library only;
  3. links the shim against it.

To take the vendored path on purpose, even with a system libuv present, as
CI's vendored job does:

```sh
make HAVE_PKG=no build
```

To see which path is active, and what it produced:

```sh
make deps-info
```

## Running from the checkout

Chez finds the library through `CHEZSCHEMELIBDIRS`, which must include
`src`:

```sh
CHEZSCHEMELIBDIRS=src chez --program your-script.sps
```

The Chez must be threaded, which is Chez's default build. The binding uses
Chez's thread system, and a Chez configured with `--nothreads` has none. On
such a Chez the import stops before it loads anything, with the message
shown in [installing](installing.md#when-the-import-fails).

For a REPL:

```sh
make dev
```

It runs `build` and `deps` first, then starts a REPL with
`CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs`. `deps` puts `chez-srfi`
into `build/scheme-libs` for the test suites; `(libuv)` itself needs none
of it.

## The shim override

`CHEZ_LIBUV_SHIM` overrides the shim's path. It is read once, when the
library loads, and it is checked, never searched: it must be an absolute
path to an existing regular file, or the binding raises
`&uv-shim-unavailable` at once. Unset, the path in `config.sls` is used, and
that file must exist. There is no `PATH` search and no fallback to the
default, and the working directory is never consulted.
[Installing](installing.md#choosing-the-shim) shows it failing.

## Release builds

`make build` links a **dev** shim:

- compiled `-O0 -g`;
- with `-DCHEZ_LIBUV_DEBUG_COUNTERS` defined, which makes the allocation
  counters the test suites assert on report real numbers;
- with a test hook, the *pool hold*: a threadpool item that
  `tests/test-dns.sps` queues to keep the pool's worker busy until the
  suite releases it.

A release build turns all of these off:

```sh
make prod
```

It cleans, relinks at `-O2` with the counters and the hold compiled out,
and then runs `make check-prod`. That checks by behaviour that the artifact
really is the release one: `tests/check-prod.sps` makes a loop and a bound
TCP handle, and fails unless every counter reads zero while they are alive,
and unless the shim exports none of the hold's entry points.

The Makefile's `relink-guard` deletes the shim whenever the flavour you ask
for, or the libuv path, stops matching what the shim was linked as. So
`make test` after `make prod` rebuilds a dev shim, rather than running the
counter suites against an `-O2` one. The guard deletes the shim rather than
trust the stamp files' times, because Apple's make 3.81 compares times to
the whole second. The Makefile's own comments give the full reasoning.

## The test gates

### The test suites

```sh
make test
```

runs every `tests/test-*.sps` suite and fails if any of them fails. It keeps
going after a failure, so one broken suite cannot hide the others. The
root-only and threading-stress suites have targets of their own
(`make help`).

### Purity

```sh
make check-purity
```

runs the suites that must have **no** native dependency, with
`CHEZ_LIBUV_SHIM` pointed at a path that does not exist. If anything such a
suite imports reaches the shim, it fails at import time, before a single
assertion runs.

### Pins

```sh
make check-pins
```

fails if:

- the `chez-srfi` submodule and `Akku.lock` name different commits;
- the vendored libuv is outside the supported range;
- `README.org` stops stating the version floor;
- `Akku.manifest` and `CHANGELOG.md` disagree about the current version.

### The memory gate

```sh
make test-memory
```

runs the suites again under Valgrind on Linux, or with AddressSanitizer
preloaded on macOS.

> ⚠️ **Only the Linux run can support a claim about leaks.** LeakSanitizer
> does not exist on macOS/ARM64, so the macOS run says nothing at all about
> leaks.

The macOS run also sees less than you might expect of everything else.
Chez's generated code is not instrumented, so ASan checks only what passes
through libc and the allocator: an overrun inside `memcpy` or `memset` (the
C shim's bulk copies included), and a double or invalid `free`. A Scheme
`foreign-set!` one byte past a block, or a `foreign-ref` of freed memory,
gets past it. Valgrind catches both.

The Linux run sets `UV_USE_IO_URING=0`. Some CI kernels reject `io_uring`
setup calls that Valgrind's syscall emulation does not model, which causes
failures that have nothing to do with this binding. That setting is for the
Valgrind run only; `io_uring` stays on for `make test`.

> ⚠️ If you develop on macOS, the leak gate you most need is the one you
> cannot run. A leak passes every macOS run unless a suite's own assertions
> happen to catch it, so there is no local signal for that kind of defect,
> and CI is the first thing to see it.

### Proving the memory gate can fail

```sh
make check-memory-gate
```

proves the memory gate can still go red. It plants real defects
(`tests/memory-gate-sabotage.sps`), runs `make test-memory` on each, and
passes only if the gate fails **and** the log carries the tool's own report
of that defect.

- **On Linux** the defects are a one-byte overrun by a Scheme store, the same
  by `memset`, the same by the binding's own bulk copy (`copy-in!`, one
  `memcpy` in the C shim), and a definite leak.
- **On macOS** only the `memset` and `copy-in!` overruns apply, because ASan
  cannot see the others.
- The `copy-in!` report must also name the shim function that made the
  overrun.
- On Linux it also plants a block that only a pointer into its middle
  reaches, which Valgrind counts as "possibly lost". The gate may pass on
  that block, but it must never fail on it without printing the block's loss
  record.

CI and `make test-memory-docker` run it before the memory gate. Run it
yourself after touching either `test-memory` recipe, and on macOS after
touching the shim's copies: only the macOS run can lose sight of them,
which happens if they stop going through libc.

> ⚠️ Either run can pass while checking nothing. Valgrind handed
> `timeout(1)` checks `timeout`, not Chez, and an ASan preload passed
> through `sh -c` is lost on the way. This target is what notices.

### The memory gate in Docker

```sh
make test-memory-docker
```

runs the Linux Valgrind run in a container that mirrors CI's toolchain:
Debian, Valgrind, and Chez built from the same release tarball CI pins. The
first run builds Chez and takes several minutes. After that the image is
cached by version, and only the suites run.

It handles two details for you, both of which bite if you build such a
container by hand:

- **The repository is mounted read-only and copied inside**, so a Linux
  `make build` cannot overwrite your macOS `build/` or the generated
  `config.sls`.
- **It runs Chez as `scheme`**, not through a `chez` symlink. Chez finds its
  boot files by `argv[0]`, so a symlink with another name aborts in
  `find_boot` before running a line. Under Valgrind that shows up as a
  "definitely lost" of about 12 KB from the aborted boot: a leak report
  with nothing to do with your code.

Set `DOCKER=` to use another CLI (`podman` works). The Chez version is
read from `.github/workflows/ci.yml`, so it cannot drift from CI's.

It runs the **vendored** libuv as an **unprivileged** user, because that is
what CI's Valgrind step does, and neither choice is cosmetic:

- Through `pkg-config` you would be testing Debian's libuv, not the pinned
  one, and two `test-lifecycle` rows that assert libuv's order of close
  against timer fail on a clean tree.
- As root, `test-process.sps`'s row "setting a child's uid as an
  unprivileged user is refused" inverts, and the spawn-options block whose
  cleanup runs only on the failure path is reported as a 131-byte definite
  leak. That comes from the environment, but it looks exactly like a defect
  in the binding.

### Reading leak summaries

**Expect more leak summaries than suites, and expect some of them to be
non-zero.**

- Each suite's own process prints one.
- So does every forked child that exits under Valgrind without reaching
  `exec`. `test-process.sps` does that on purpose, in the rows that exercise
  spawn failures.
- Each such child reports that row's spawn-options block as lost. The parent
  holds the block while `uv_spawn` forks and frees it as soon as `uv_spawn`
  returns, but the child exits inside `uv_spawn`. On arm64 the block shows
  as definitely lost; CI's x86_64 runner has shown it at zero.

None of these is a leak in this binding. Plant a block that the parent holds
for the whole suite, and every such child reports it as well, while the
parent stays at zero. None of them gates the run either: libuv discards the
exit status of a child whose `exec` failed, and the suite's own process is
the one whose status counts.

> ⚠️ **Read the exit status, not the scrollback.**

### Hung suites

`make test` and `make test-memory` cap each suite separately. A suite that
hangs, rather than failing an assertion, is reported as

```
HUNG: tests/test-tcp.sps exceeded 300s and was killed (not a failing assertion)
```

- Under `make test`, the run **continues** to the remaining suites.
- `make test-memory` stops at its first failing suite, hung or not. There
  the cap wraps Valgrind itself, so a hung suite is killed together with
  the Valgrind process running it.
- Change the caps with `SUITE_TIMEOUT=` (default 300 s) and
  `MEMORY_SUITE_TIMEOUT=` (default 900 s, because Valgrind is far slower).

The cap needs GNU coreutils' `timeout(1)`, which **stock macOS does not
ship**. Homebrew installs it as `timeout`, or as `gtimeout` when coreutils
is installed with prefixed names. Without either, the target prints a note
and runs the suites uncapped: the same results, but no HUNG diagnosis.

### Non-threaded Chez

```sh
make check-nothreads-docker
```

builds Chez with `--nothreads` in a container and imports each public
library there. The refusal must stop every import: the first exception
printed must be its message, not the bare `missing import for make-mutex`
that a non-threaded Chez raises at the first thread primitive it meets.

- The message wins only when `(libuv private require-threaded)` is imported
  ahead of every `(chezscheme)` import. `make test` holds that order
  (`tests/test-require-threaded.sps`).
- The same suite expands the refusal's source with `(threaded?)` answering
  `#f`, so a refusal that stops refusing fails the default gate too.
- This target is the only thing that runs a real non-threaded Chez, so run
  it after touching either.

Like `make test-memory-docker`, it is off the default gate. The first run
builds Chez and takes a few minutes, and the image is cached by version
after that. It mounts only `src/`, so it needs no build and runs from any
checkout. The mount is copied inside as root and checked as an unprivileged
user, so the checkout's owner and permissions do not matter.

### Running as root

```sh
sudo make test-root
```

runs the root-only suite, which checks the `uid` and `gid` spawn options
([processes](processes.md#running-as-another-user)), on its own. It is kept
out of `make test` and `make test-memory`, refuses with a clear message
when not run as root, and CI runs it as its own step. Run `make build deps`
unprivileged first: the target refuses to build anything as root.

### How the tests are held

Every assertion in these suites has been watched to fail: a mutation that
breaks the decision it guards makes it fail *by name*. Where nothing could
catch a mutation, the gap is written down rather than left silent.
[CONTRIBUTING.md](../CONTRIBUTING.md) describes the discipline.

## On a Guix host

A machine managed by [Guix](https://guix.gnu.org) can build and test without
installing anything into the host.

1. Fill the submodules once, on the host, since that clones from the
   network:

   ```sh
   git submodule update --init --recursive
   ```

2. Run any target through the pinned container:

   ```sh
   scripts/guix-env make test
   scripts/guix-env make test-memory
   scripts/guix-env            # an interactive shell
   ```

`scripts/guix-env` runs `guix time-machine` at the Guix commit in
`channels.scm`, with the toolchain in `manifest.scm`, in a container that
holds:

- **Chez Scheme 10.4.1**, this project's floor. The pinned Guix packages
  10.4.0, so the first run builds Chez from source, in about two minutes.
  Later runs start in about 3 s.
- **libuv 1.52.1** through `pkg-config`. `make HAVE_PKG=no …` builds the
  vendored one with the container's `cmake`.
- gcc, Valgrind, git, make and the usual shell tools.

The container shares the checkout and nothing else from your home
directory, and has no network but loopback. Its git can read the repository
but has no identity or credentials, so commit, fetch and push on the host.
It exports `CHEZ` and `CC`, so no `CHEZ=` is needed.

Outside the container on such a host, `make build`, and every target that
builds, stops before it builds anything when a tool is missing, and says to
use the container:

```
make build: cmake not found.
On this Guix host, run it in the project's container: scripts/guix-env make build
```

```sh
make check-guix
```

tests the launcher on the host, then checks the container from inside: the
pinned tools, Chez and libuv at their floors, the isolation, the
loopback-only network, and finally `make test`.

`sudo make test-root` and the Docker targets cannot run in the container.
On this host neither needs to: `scripts/guix-env make HAVE_PKG=no test-memory`
there is CI's Valgrind run itself.

## The docs site

The pages in `docs/` are also published as a website, rendered by
chez-cmark-gfm.

1. **Get chez-cmark-gfm:**

   ```sh
   make site-deps
   ```

   chez-cmark-gfm is a development dependency, pinned in `Akku.lock`. If an
   `akku install` tree is present, `make site-deps` uses it. Otherwise it
   downloads the archive the lock names and checks its sha256 before using
   it.

2. **Build the site:**

   ```sh
   make site
   ```

   writes it to `build/site/`.

3. **Check it:**

   ```sh
   make check-site
   make check-reference
   ```

chez-cmark-gfm loads the system's `cmark-gfm` C library, so that library
must be installed.

Two more checks run on the host, outside the container:

- `make check-site-deps` tests the archive download offline: the sha256 is
  checked, a second run needs no network, and a failed unpack leaves the old
  tree alone.
- `make check-akku` installs this package into a throwaway Akku project and
  fails unless exactly the libraries in `src/` land there. `.akkuignore`
  keeps the site generator out. It needs `akku` and a Chez:

  ```sh
  guix shell akku chez-scheme -- make check-akku CHEZ=scheme
  ```

## Read next

- [Installing](installing.md): using the library from your own project.
- [Processes and pipes](processes.md): the spawn options the root suite
  tests.
- [CONTRIBUTING.md](../CONTRIBUTING.md): the test discipline.
