# Contributing to chez-libuv

Thanks for wanting to improve this. Two kinds of contribution get two
levels of ceremony: a **drive-by fix** (typo, doc fix, small bug with a
test) needs only the gates below; **feature-sized work** should start as an
issue or design conversation before code — this binding is a legible
mirror of libuv's own vocabulary, and additions that invent vocabulary
need a design decision first.

## Setup

You need a threaded Chez Scheme 10.4.1+ (binary `chez`; threaded is Chez's
default, so anything not configured with `--nothreads`) and either a
system libuv `pkg-config` can see or nothing (the build vendors a pinned
libuv automatically):

```sh
git clone --recursive https://github.com/Kiyomi-Computation-Systems/chez-libuv.git
cd chez-libuv
make build
make test
```

`make help` lists every target; [docs/building.md](docs/building.md) has
the full build story.

On a [Guix](https://guix.gnu.org) host, run targets through the pinned
development container instead, e.g. `scripts/guix-env make test`
([docs/building.md](docs/building.md#on-a-guix-host)).

## The gates

A PR must keep these green — they are exactly what CI runs:

- `make test` — every suite passes (`ALL SUITES PASSED`).
- `make check-history` and `make check-archive`, which `make test` runs
  first: no shipped file cites plans or history, and a release archive
  leaves out the repository's own records and holds everything else.
- `make check-pins` — submodule/lock/version/floor agreement.
- `make check-purity` — the pure suites still import no native code.
- `make test-memory` runs in CI; the Linux Valgrind leg is the only one
  that can support a leak claim.
- `make check-memory-gate` — the memory gate still fails on planted
  defects. CI runs it before `test-memory`; run it yourself after touching
  either `test-memory` recipe, and on macOS after touching the C shim's
  copies (CI's Linux run cannot tell when ASan loses sight of them).
- **Tests accompany code changes.** A behavior change without a test that
  fails against the old behavior will be asked for one.
- Every new test suite ends with its own `(exit …)` — SRFI-64 does not set
  a process exit status, and a suite missing that line reports success
  forever.

## Conventions

- [Conventional Commits](https://www.conventionalcommits.org): `feat:`,
  `fix:`, `docs:`, `refactor:`, `test:`, `chore:`.
- Branch names: `feat/<slug>`, `fix/<slug>`, `docs/<slug>`, etc.
- PRs are squash-merged.

## How this repo is developed

The house style — encouraged for feature work, not demanded of drive-by
fixes: designs are written and accepted before implementation
(`.plans/*-design.md`), architectural decisions get numbered records
(`.plans/decisions/`), and the testing discipline in
[AGENTS.md](AGENTS.md) applies — *a test is not finished when it passes;
it is finished when you have watched it fail*, with the evidence recorded
in a mutation log. Reading one of the existing mutation logs in `.plans/`
is the fastest way to understand what that means in practice.

## Security

Please do not open public issues for suspected vulnerabilities — see
[SECURITY.md](SECURITY.md).
