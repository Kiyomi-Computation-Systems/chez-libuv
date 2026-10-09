# Building & testing

## What `make build` does

`make build` compiles the C shim and writes
`src/libuv/private/config.sls` — the shim's absolute path, the absolute
paths of the libuv shared libraries to load before it, and the supported
version range. **That file is generated and gitignored**, not part of the
repository, so a fresh clone has to run `make build` before
`(import (libuv))` can resolve. Run it again after every upgrade. The
shim's exports change between releases, and a shim built from older sources
fails the import with `&uv-shim-unavailable`. This is also why no source-only
distribution (an Akku package included) can work without a build step:
`config.sls` is a per-machine build product.

`make help` lists every target.

## Where libuv comes from

The floor is **libuv 1.48.0**, Ubuntu 24.04 LTS's libuv, which CI tests
against; `make build` derives the packed version range written into
`config.sls` from it. libuv guarantees ABI stability across 1.x, so this
is a range check, not an equality test — a runtime library outside the
range makes initialisation raise `&uv-version-incompatible` rather than
run.

Which copy gets used depends on `pkg-config --atleast-version=1.48.0 libuv`:

- **Succeeds** (e.g. `brew install libuv` on macOS, or `libuv1-dev` on
  Ubuntu 24.04 or 26.04): the shim is compiled directly against that
  installed copy. Nothing under `vendor/` is touched.
- **Fails**, because no system libuv is installed, or because the one
  installed is older than the floor (Debian 12's is 1.44.2): the same `make build`
  first runs `git submodule update --init --recursive` and builds the
  pinned `vendor/libuv` submodule with CMake (shared library only), then
  links the shim against that. Force this path deliberately, even with a
  system package present — this is what CI's vendored job does — with:

  ```sh
  make HAVE_PKG=no build
  ```

Which path is active, and what it produced:

```sh
make deps-info
```

## Running

Chez has to be told where the library lives; `CHEZSCHEMELIBDIRS` must
include `src`:

```sh
CHEZSCHEMELIBDIRS=src chez --program your-script.sps
```

The Chez must be threaded, which is Chez's default build. The binding uses
Chez's thread system, and a Chez configured with `--nothreads` does not
have one. On such a Chez the import stops before loading anything:

```
Exception in chez-libuv: chez-libuv needs a threaded Chez Scheme, and (threaded?) is #f in this one. Chez builds threaded unless configured with --nothreads (require-threaded-chez) at line …, char … of …/libuv/private/require-threaded.sls
```

For interactive use:

```sh
make dev
```

runs `build` and `deps` first — the latter vendors `chez-srfi` into
`build/scheme-libs` for the test suites; `(libuv)` itself needs none of
it — then starts a REPL with `CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs`.

## `CHEZ_LIBUV_SHIM`

Environment override for the shim's absolute path, read once at
initialisation — config in the environment is 12-factor. It is
**validated, never searched**:

- **Unset**: the default path `make build` recorded in `config.sls` is
  used, and must itself exist as a regular file.
- **Set**: must be an *absolute* path (leading `/`) to an *existing regular
  file*; that exact file is loaded.
- Anything else — a relative path, a path that does not exist, a
  directory — raises `&uv-shim-unavailable` immediately. There is no
  `PATH` search, no falling back to the default, and the working directory
  is never consulted.

## Release builds

`make build` links a *dev* shim: `-O0 -g`, with
`-DCHEZ_LIBUV_DEBUG_COUNTERS` defined, which is what makes the allocation
counters the test suites assert on report real numbers. A release build
turns both off:

```sh
make prod
```

cleans, relinks at `-O2` with the counters compiled out, and then runs
`make check-prod` — a *behavioural* check that the surviving artifact
really is the release one: `tests/check-prod.sps` allocates a loop and a
bound TCP handle and fails unless every counter reads zero while they are
demonstrably alive.

The Makefile's `relink-guard` deletes the shim whenever the requested
flavor (or acquisition path) stops matching what the artifact was linked
as, so `make test` after `make prod` self-heals back to a dev shim rather
than running the counter suites against an `-O2` artifact. The full
archaeology — including why the guard *deletes* instead of trusting stamp
mtimes (Apple make 3.81 compares at one-second granularity) — is in the
Makefile's own comments, which are kept deliberately thorough.

## Tests

```sh
make test
```

runs every `tests/test-*.sps` suite and fails if any of them do. It keeps
going after a failure, so one broken suite cannot hide the others.

```sh
make check-purity
```

runs the suites that must have *no* native dependency with
`CHEZ_LIBUV_SHIM` poisoned to a path that does not exist. If anything in
such a suite's import chain reaches the shim, it fails at import time,
before a single assertion runs.

```sh
make check-pins
```

fails if the `chez-srfi` submodule and `Akku.lock` name different commits,
if the vendored libuv is outside the supported range, if `README.org`
stops stating the version floor, or if `Akku.manifest` and `CHANGELOG.md`
disagree about the current version.

```sh
make test-memory
```

runs the suites again under Valgrind on Linux, or an AddressSanitizer
preload on macOS. **Only the Linux run can support a leak claim** —
LeakSanitizer does not exist on macOS/ARM64, so the macOS leg says nothing
at all about leaks
([ADR-0003](../.plans/decisions/0003-linux-valgrind-is-the-sole-memory-gate.md)).
It sees less than you might expect about everything else, too. Chez's
generated code is not instrumented, so ASan checks only what passes
through libc and the allocator: an overrun inside `memcpy` or `memset`
(the C shim's bulk copies included), a double or invalid `free`. A Scheme
`foreign-set!` one byte past a block, or a `foreign-ref` of freed memory,
gets past it; Valgrind catches both.
The Linux leg sets `UV_USE_IO_URING=0`: some CI kernels reject `io_uring`
setup calls that Valgrind's syscall emulation does not model, which
produces failures that have nothing to do with this binding. That is an
escape hatch for the Valgrind leg only — `io_uring` stays on for
`make test`.

```sh
make check-memory-gate
```

proves the memory gate can still fail. It plants real defects
(`tests/memory-gate-sabotage.sps`), runs `make test-memory` on each, and
passes only if the gate fails *and* the log carries the tool's own report
of that defect. On Linux the defects are a one-byte overrun by a Scheme
store, the same by `memset`, the same by the binding's own bulk copy
(`copy-in!`, one `memcpy` in the C shim), and a definite leak. On macOS
the `memset` and `copy-in!` overruns apply, because ASan cannot see the
others. The `copy-in!` report must also name the shim function that made
the overrun. On Linux it also plants a block that only a pointer into its
middle reaches, which Valgrind counts as "possibly lost". The gate may
pass on that block, but it must never fail on it without printing the
block's loss record. CI and `make test-memory-docker` run it before the
memory gate. Run it yourself after touching either `test-memory` recipe,
and on macOS after touching the shim's copies: only the macOS arm can lose
sight of them, which happens if they stop going through libc. Both arms
once passed while checking nothing: Valgrind was handed `timeout(1)`
instead of Chez, and the ASan preload was lost on its way through `sh -c`.

If you develop on macOS, that leaves a real hole: the leak gate you most
need is the one leg you cannot run. v0.5 measured what it costs — four
independent ways to leak foreign memory in the OS-buffer wrappers, and
every one of them left the suite fully green. On macOS there is no local
signal for that entire class of defect, and CI is the first thing to see
it.

```sh
make test-memory-docker
```

runs the Linux Valgrind leg in a container that mirrors CI's toolchain:
Debian, Valgrind, and Chez built from the same release tarball CI pins.
The first run builds Chez and takes several minutes; afterwards the image
is cached by version and only the suites run.

Two details it handles for you, both of which bite if you build such a
container by hand. The repository is mounted **read-only** and copied
inside, so a Linux `make build` cannot overwrite your macOS `build/`
artifacts or the generated `config.sls`. And it invokes Chez as `scheme`
rather than through a `chez` symlink: Chez resolves its boot files by
`argv[0]`, so a differently-named symlink aborts in `find_boot` before
running a line — under Valgrind that shows up as a ~12 KB "definitely
lost" from the aborted boot, a leak report with nothing to do with your
code.

Override `DOCKER=` to use another CLI (`podman` works). The Chez version
is read from `.github/workflows/ci.yml`, so it cannot drift from CI's.

It runs the **vendored** leg as an unprivileged user, because that is what
CI's Valgrind step does and neither detail is cosmetic. Through
`pkg-config` you would be testing Debian's libuv rather than the pinned
one, and two `test-lifecycle` rows that assert libuv's close-versus-timer
ordering fail on a clean tree. As root, `test-process.sps`'s "setting a
child's uid as an unprivileged user is refused" row inverts, and the
spawn-options block whose cleanup only runs on the failure path is
reported as a 131-byte definite leak — an environment artifact that looks
exactly like a defect in the binding.

**Expect more leak summaries than suites, and expect some of them to be
non-zero.** Each suite's own process prints one. So does every forked
child that exits under Valgrind without reaching `exec`, and
`test-process.sps` arranges that on purpose in the rows that exercise
spawn failures. Each such child reports that row's spawn-options block as
lost: the parent holds the block while `uv_spawn` forks and frees it as
soon as `uv_spawn` returns, but the child exits inside `uv_spawn`. On
arm64 the block shows up as definitely lost; in v0.5, CI's x86_64 runner
showed it at zero. None of these is a leak in this binding. Plant a block
that the parent holds for the whole suite, and every such child reports it
as well, while the parent stays at zero. None of them gates, either.
libuv discards the exit status of a child whose `exec` failed, and the
suite's own process is the one whose status the loop checks. **Read the
exit status, not the scrollback**; the evidence is in
`.plans/memory-gate-mutation-log.md`.

Both `make test` and `make test-memory` cap each suite individually. A
suite that hangs — rather than failing an assertion — is reported as

```
HUNG: tests/test-tcp.sps exceeded 300s and was killed (not a failing assertion)
```

and, under `make test`, **the run continues to the remaining suites**.
`make test-memory` stops at its first failing suite, hung or not. Before
this, a single hang took the whole run with it and produced no failing-row
output at all, so a hang and a failure were indistinguishable in the log.
Under `make test-memory` the cap wraps Valgrind itself, so a hung suite is
killed together with the Valgrind process running it. Override with
`SUITE_TIMEOUT=` (default 300s) or `MEMORY_SUITE_TIMEOUT=` (default 900s,
because Valgrind is far slower).

The cap needs GNU coreutils' `timeout(1)`, which **stock macOS does not
ship**; Homebrew installs it as `timeout`, or as `gtimeout` when coreutils
is installed with prefixed names. Without either, the target prints a note
and runs exactly as before — you get the same suite results, just no HUNG
diagnosis.

```sh
make check-nothreads-docker
```

builds Chez with `--nothreads` in a container and imports each public
library there. The refusal itself must stop every import: the first
exception printed must be its message, not the bare `missing import for
make-mutex` a non-threaded Chez raises at the first thread primitive it
meets. The message only wins when
`(libuv private require-threaded)` is imported ahead of every `(chezscheme)`
import. `make test` holds that order (`tests/test-require-threaded.sps`).
The same suite expands the refusal's own source with `(threaded?)` answering
`#f`, so a refusal that stops refusing fails the default gate too. This
target is the only thing that runs a real non-threaded Chez, so run it after
touching either. Like `make test-memory-docker`, it is off the default gate:
the first run builds Chez and takes a few minutes, and the image is cached
by version after that. It mounts only `src/`, so it needs no build and runs
from any checkout. The mount is copied inside as root and checked as an
unprivileged user, so the checkout's owner and permissions do not matter.

```sh
sudo make test-root
```

runs the root-gated setuid/setgid suite alone (see
[the API reference](api.md#child-processes--libuv-process)); run
`make build deps` unprivileged first — the target deliberately refuses to
build anything as root.

Every assertion in those suites has been watched to fail. Each stage's
mutation log (`.plans/*-mutation-log.md`) records the mutation that breaks
each decision, the assertion that caught it *by name*, and — where nothing
could catch one — why, rather than leaving the gap silent.
