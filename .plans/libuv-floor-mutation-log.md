# libuv floor 1.48.0 (#90): evidence and mutation log

2026-10-09, on 27d84bb plus this branch. The floor moves from 1.44.0 to
1.48.0 (Ubuntu 24.04 LTS's libuv). A system libuv below it is passed over
for the vendored build. A second CI job runs `make test` against exactly
that version.

## Why the floor moved

`make test` on 27d84bb against Debian 12's libuv 1.44.2:
- **Setup:** the `chez-libuv-valgrind:10.4.1` image, a `--no-hardlinks` clone, the pkg-config path, run as `dev`.
- **Result:** all 30 suites ran, and two rows failed, both in test-lifecycle:
  - "the close the raising callback started is still pending when uv-run returns"
  - "seed: the timer is still counted while its close is pending"
- **Why they fail:** both rows assert the ordering newer libuv has. There, `uv_run` runs due timers before its loop, so a close that a raising callback starts is still pending when `uv-run` returns. On 1.44.2 that close has already finished.
- **Everything else passed,** including the reuseport refusal, `(constant-unavailable UV_TCP_REUSEPORT)`.

So the 1.44.0 floor was never one the suite passed on. The Makefile's
`test-memory-docker` comment had recorded the same two failures on
2026-08-30.

## The floor-detection check (`make check-pins`)

The check gives a second `make` a fake `libuv.pc` just below the floor
(1.47.99) and one at it (1.48.0), and reads `deps-info`'s
`libuv source` from it. It requires `vendored` for the first and
`pkg-config` for the second.

Each mutant below was made in a scratch clone by exact single-match
replacement in the Makefile, on macOS with GNU Make 3.81.

| Mutant | Result |
|---|---|
| Before the fix: floor 1.44, detection `pkg-config --exists` | **fails**: 1.43.99 chose `pkg-config` (want vendored) |
| Base | passes |
| Base, `make HAVE_PKG=no check-pins` | passes |
| M1: detection back to `--exists` | **fails**: 1.47.99 chose `pkg-config` |
| M2: detection `--atleast-version=<floor>.1`, so the floor itself is excluded | **fails**: 1.48.0 chose `vendored` |
| M3: `MAKEFLAGS=` not cleared, run as `make HAVE_PKG=no check-pins` | **fails**: 1.48.0 chose `vendored` (the outer command line answered) |
| M3 control: the same edit, plain `make check-pins` | passes |

- **Dry run.** `make -n check-pins` prints the recipe and runs nothing: no output line begins with an outcome. The sub-make goes through the `PINS_MAKE` alias, as check-memory-gate's does.
- **GNU Make 4.3,** in the Debian 12 image (libuv 1.44.2):
  - `make -s deps-info` says `libuv source : vendored`;
  - `make HAVE_PKG=no check-pins` passes.

## The floor job's assert step (ci.yml)

The step was extracted verbatim from ci.yml with a YAML parser. It ran
under `bash --noprofile --norc -eo pipefail`, as GitHub runs it, in the
`chez-libuv-noble-scratch:10.4.1` mirror (Ubuntu 24.04, libuv 1.48.0).
Each mutant Makefile was made on the host by exact single-match
replacement and copied over a fresh copy of the tree.

| Mutant | Result |
|---|---|
| A0: control | passes: "system libuv 1.48.0, floor 1.48.0" |
| A1: floor 1.49 | **fails**: "the build took the 'vendored' path: the system libuv (1.48.0) does not meet the floor (1.49.0)" |
| A2: floor 1.47 | **fails**: "the system libuv is 1.48.0, not the floor's 1.47.x" |
| A3: `deps-info` no longer prints the floor | **fails**: "could not read the floor out of make deps-info" |

A first attempt edited the mutants inside the mirror with `python3`. The
image has none, so every mutant ran unmutated and "passed". Those runs
are discarded; the table above is the rerun.

## The floor job's steps, in the 24.04 mirror

The job's steps ran in order, as `dev`, with `CHEZ=scheme` as the action
exports it:
1. `make check-pins`: floor detection ok.
2. `make deps`.
3. `make build`.
4. The assert step: links the libuv floor, 1.48.0.
5. `make test`: **ALL SUITES PASSED**. test-tcp's reuseport row took the refusal arm: `(constant-unavailable UV_TCP_REUSEPORT)`.

The composite action itself, `.github/actions/pinned-chez`, cannot run
locally; this PR's own CI run is its test. The main job's cache key is the
same string as before (`chez-<version>-<os-id>-<arch>-v2`), so its
existing cache entry should still hit.

## macOS

`make check-help` passes. `make test` passes all suites (Homebrew libuv
1.52.1, pkg-config path).
