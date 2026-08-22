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
