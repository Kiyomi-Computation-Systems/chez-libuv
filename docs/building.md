# Building & testing

## What `make build` does

`make build` compiles the C shim and writes
`src/libuv/private/config.sls` — the shim's absolute path, the absolute
paths of the libuv shared libraries to load before it, and the supported
version range. **That file is generated and gitignored**, not part of the
repository, so a fresh clone has to run `make build` before
`(import (libuv))` can resolve. This is also why no source-only
distribution (an Akku package included) can work without a build step:
`config.sls` is a per-machine build product.

`make help` lists every target.

## Where libuv comes from

The floor is **libuv 1.44.0**; `make build` derives the packed version
range written into `config.sls` from it. libuv guarantees ABI stability
across 1.x, so this is a range check, not an equality test — a runtime
library outside the range makes initialisation raise
`&uv-version-incompatible` rather than run.

Which copy gets used depends on `pkg-config --exists libuv`:

- **Succeeds** (e.g. `brew install libuv` on macOS): the shim is compiled
  directly against that installed copy. Nothing under `vendor/` is touched.
- **Fails** (the common case on a bare Linux box): the same `make build`
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
LeakSanitizer does not exist on macOS/ARM64, so the macOS leg reports
use-after-free and double-free and says nothing at all about leaks
([ADR-0003](../.plans/decisions/0003-linux-valgrind-is-the-sole-memory-gate.md)).
The Linux leg sets `UV_USE_IO_URING=0`: some CI kernels reject `io_uring`
setup calls that Valgrind's syscall emulation does not model, which
produces failures that have nothing to do with this binding. That is an
escape hatch for the Valgrind leg only — `io_uring` stays on for
`make test`.

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

**Expect more leak summaries than suites, and expect a couple to be
non-zero.** `test-process.sps` deliberately exercises spawn failures, so
some forked children never reach `exec` and exit under Valgrind, reporting
whatever the parent had allocated at fork time as lost. Sixteen suites
produce eighteen summaries. CI's x86_64 runner happens to show all
eighteen at zero; on arm64 two of them report a hundred-odd bytes. Neither
is a leak in this binding, and neither gates: `--error-exitcode` applies
per process, and the suite's own process is the one whose status the loop
checks. **Read the exit status, not the scrollback** — the same rule
`make test-memory` has always needed.

Both `make test` and `make test-memory` cap each suite individually. A
suite that hangs — rather than failing an assertion — is reported as

```
HUNG: tests/test-tcp.sps exceeded 300s and was killed (not a failing assertion)
```

and **the run continues to the remaining suites**. Before this, a single
hang took the whole run with it and produced no failing-row output at all,
so a hang and a failure were indistinguishable in the log. Override with
`SUITE_TIMEOUT=` (default 300s) or `MEMORY_SUITE_TIMEOUT=` (default 900s,
because Valgrind is far slower).

The cap needs GNU coreutils' `timeout(1)`, which **stock macOS does not
ship**; Homebrew installs it as `timeout`, or as `gtimeout` when coreutils
is installed with prefixed names. Without either, the target prints a note
and runs exactly as before — you get the same suite results, just no HUNG
diagnosis.

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
