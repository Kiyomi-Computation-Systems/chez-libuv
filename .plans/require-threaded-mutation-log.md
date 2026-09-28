# A threaded Chez is required, and any other is refused by name (#41)

This is the evidence for `fix/require-threaded-chez`. The change has three parts:

- `(libuv private require-threaded)` refuses a non-threaded Chez by name, and `native.sls` imports it ahead of `(chezscheme)`.
- `tests/test-require-threaded.sps` holds that import order on every `make test`.
- `make check-nothreads-docker` proves the refusal on a real `--nothreads` Chez.

The change also drops the non-threaded branches: `current-thread-id` becomes `get-thread-id`, the stress suite's `(threaded?)` guards go, and so do the D5 comments. It amends ADR-0019's decision 5 and updates the user docs.

Unless a line says otherwise, every run used Chez 10.4.1 and libuv 1.52.1:

- threaded Chez: macOS arm64 (`tarm64osx`), with libuv from pkg-config;
- `--nothreads` Chez: Linux arm64 in Docker (`arm64le`), built by `docker/nothreads.Dockerfile`.

Every mutation ran on a scratch copy outside the repo. Each was applied by an exact-text replacement that aborts unless its target matches exactly once, and each was re-read to confirm the edit landed.

---

## The defect

`(libuv private native)` has imported `make-mutex` and `with-mutex` since v0.1 (35f290b). Chez builds those names only into threaded builds. In the 10.4.1 release tarball's `s/primdata.ss`:

- `with-mutex` (line 1138), `make-mutex` (1540), `mutex-acquire` (1574), `mutex-release` (1576), `make-condition` (1522) and `fork-thread` (1388) are all flagged `[feature pthreads]`;
- `get-thread-id` (898) and `threaded?` (906) are not flagged.

On a `--nothreads` Chez at e358156, `make HAVE_PKG=no test` gave:

- **14 of the 17 default suites died at import.** Each printed:
  ```
  Exception: missing import for make-mutex (only (chezscheme) load-shared-object foreign-procedure foreign-entry? foreign-ref ...) at line 94, char 11 of src/libuv/private/native.sls
  ```
- `test-shim-loading` failed 13 rows.
- Only `test-addrinfo` and `test-conditions` passed. Neither loads `(libuv private native)`.

The stress suite's "[skipped] non-threaded Chez" branch could never have run either, because the suite imports `fork-thread` itself.

ADR-0019 decision 5, the threading design's D5 and the threading plan's ticked box all said the opposite. They were reasoned, never run. Every Chez this project uses is threaded, which is Chez 10's default: Homebrew's, CI's pinned build and the Docker image. That was measured during #33's review.

## The mechanism, measured before it was written

A library whose macro checks `(threaded?)` in its transformer raises while it is being expanded. Probed on the same `--nothreads` image, with a two-library importer:

| importer's import form | `--nothreads` | threaded |
|---|---|---|
| `(rnrs) (libuv private require-threaded) (only (chezscheme) make-mutex)` | the refusal's message | loads |
| `(rnrs) (only (chezscheme) make-mutex) (libuv private require-threaded)` | `missing import for make-mutex` | loads |

Chez processes a library's imports in order, so the refusal works only when it comes first. That order is the load-bearing invariant `tests/test-require-threaded.sps` holds.

## RED

- **The suite**, against e358156: 9 passes and 2 failures, each by name:
  - `src/ defines (libuv private require-threaded)`;
  - `src/libuv/private/native.sls imports (libuv private require-threaded) before (chezscheme)`.

  The liveness row "the scan read the whole tree" came later, from C6 below.
- **`make check-nothreads-docker`**, against e358156, exited 2:
  - the precondition held;
  - all 11 public libraries were `NOT REFUSED BY NAME`, each printing `missing import for make-mutex … line 94 … native.sls`;
  - the run ended `NOTHREADS CHECK FAILED`.

## GREEN

- The suite: 12 passes.
- `make test`: 18 suites, `ALL SUITES PASSED`.
- `make check-purity`: all three pure suites hold. The new suite joined `PURE_TESTS`, because it reads `src/`'s import forms as data and imports none of them.
- `make check-nothreads-docker`: the precondition held, all 11 public libraries were `refused by name`, and it printed `NOTHREADS REFUSED BY NAME`. The refusal's text:
  ```
  Exception in chez-libuv: chez-libuv needs a threaded Chez Scheme, and (threaded?) is #f in this one. Chez builds threaded unless configured with --nothreads (require-threaded-chez) at line 31, char 3 of /src/libuv/private/require-threaded.sls
  ```

## Mutations: tests/test-require-threaded.sps

The control ran 12 passes. Each row below exited 1, failing the rows named.

| | mutation | fails, by name |
|---|---|---|
| S1 | the refusal import removed from `native.sls` | `…/native.sls imports … before (chezscheme)` |
| S2 | the refusal imported after `(only (chezscheme) …)` | `…/native.sls imports … before (chezscheme)` |
| S3 | `require-threaded.sls` deleted | `src/ defines (libuv private require-threaded)` |
| S4 | `handles.sls` gains `(only (chezscheme) with-mutex)` without the refusal: #33's shape | a NEW row, `…/handles.sls imports … before (chezscheme)`, while the other 12 pass |
| C1 | the checker never records the refusal | 3 rows: the two seeded "guards it" rows and `native.sls`'s row |
| C2 | the checker accepts the refusal anywhere in the list | `the refusal listed AFTER the (chezscheme) import does not guard it` |
| C3 | the checker does not look through `only`/`prefix`/… wrappers | 6 rows, including the liveness row `the order rows are live` |
| C4 | `(scheme)` dropped from the thread libraries | `(scheme) is (chezscheme) under its other name` |
| C5 | a reference keeps its version | `a versioned reference is the same library` |
| C6 | the scan rooted at `src/libuv` | `the scan read the whole tree: (libuv) and (libuv private native)` |
| C6b | the scan rooted at a directory with no libraries (`tests` in the scratch copy) | 3 rows: whole tree, `src/ defines …`, and `the order rows are live` |
| C7 | the coverage filter drops every library | `the order rows are live: native.sls imports from (chezscheme)` |

**C6 first survived.** `src/libuv` still holds `private/`, so a scan rooted there reads everything except the facade `src/libuv.sls`. The suite passed. The existing liveness rows checked only that `native.sls` and the refusal were found. A narrowed scan root is exactly the vacuous-check failure these rows exist for, so the suite gained `the scan read the whole tree: (libuv) and (libuv private native)`. C6 now fails on it.

**C6b's first form proved nothing.** Rooted at `docker`, a directory the scratch copy did not contain, `directory-list` raised and the suite crashed with no FAIL line. Narrowed to a root that exists and holds no libraries, it fails the three rows it should.

## Mutations: make check-nothreads-docker

Each row runs the same container command the Makefile runs, with scratch copies of `src/` and the script mounted.

| | mutation | result |
|---|---|---|
| D0 | none (control) | exit 0: 11 refused by name |
| D1 | the refusal imported after `(only (chezscheme) …)` | exit 1: 11 not refused; `missing import for make-mutex` |
| D2 | the refusal's message changed | exit 1: 11 not refused; the changed message, no marker |
| D3 | the refusal import removed | exit 1: 11 not refused; `missing import for make-mutex` |
| D4 | the refusal disabled: `(if #t …)` | exit 1: 11 not refused; `missing import for make-mutex` |
| D5 | the refusal inverted: `(if (not (threaded?)) …)` | exit 1: 11 not refused; `missing import for make-mutex` |
| D6 | the check run on a THREADED Chez (the valgrind image) | exit 1: `NOT A NON-THREADED CHEZ` |
| D7 | `NOTHREADS_MARKER` unset | exit 1: `NOTHREADS_MARKER is not set` |
| D8 | an empty `src/` mounted | exit 1: both globs stay literal, 2 not refused; `library (libuv) not found` |
| D9 | the script's marker clause dropped (exit status alone), run against D2 | **exit 0, 11 "refused"**: without the marker, a changed message passes |
| D10 | the refusal only PRINTS its message, and the import goes on | exit 1: 11 not refused; the first exception is `missing import` |
| D11 | the script takes the marker from anywhere in the output, not the first exception, run against D10 | **exit 0, 11 "refused"**: a refusal that only prints would pass |

D9 and D11 are the counterfactuals. Each shows that a clause of the script is what catches its mutation.

D11 changed the check. Its first version required a non-zero exit and the marker anywhere in the output. A refusal that only printed its message would have passed that, because the import goes on to fail with `missing import for make-mutex`, which exits non-zero with the marker already printed. An added "no `missing import` in the output" clause caught D10, but D1 then triggered two clauses, so D9 could not isolate the marker clause. The final rule is simpler and subsumes both: **the first exception printed must carry the marker.** In other words, the refusal is what stopped the import, whatever would have failed next.

**Not isolatable: the non-zero-exit clause.** A Chez `--program` that prints an uncaught exception always exits 255 (every NOT REFUSED line above says so). A successful import prints no exception, so the first-exception clause already fails it. The exit clause states "the import failed" directly, but no realistic mutation breaks it alone. It stays as a guard, and that is recorded here rather than left silent.

## The stress suite's dead guards

`tests/test-threading-stress.sps` had one `(cond ((not (threaded?)) <skip>) (else …))` and four `(when (threaded?) …)` guards. None could ever run on a non-threaded Chez, because the suite's own `fork-thread` import fails first. All five were unwrapped by a paren-aware script that aborts on any unexpected shape. Chez's reader then read the old and new files, and a transform stripped the guards from the old forms. The new forms equal the stripped old ones: 12 top-level forms, `new == strip(old)`. `git diff -w` shows only the guard lines, the import, and the closing parens.

Against the same `src/`, the original file and the new one both report 10 passes.

## Gates

- On macOS:
  - `make test`: 18 suites, `ALL SUITES PASSED`;
  - `make check-purity`, `make check-help`, and `make test-threading` (10 passes);
  - `make check-memory-gate` (`MEMORY GATE CAN FAIL`) and `make test-memory` (the ASan arm, 18 suites);
  - `make prod` (`check-prod: PASS`).
- `make check-nothreads-docker`: green, as above.
- `make test-memory-docker`, the Linux Valgrind gate with vendored libuv, run from a `--no-hardlinks` clone carrying this tree. Only this log and one docs sentence changed after the clone. It exited 0 in 2:59:
  - `check-memory-gate` caught all three planted defects, stayed consistent on the possible leak, and printed `MEMORY GATE CAN FAIL`.
  - All 18 suites ran under Valgrind with 0 errors in each suite's own process. That includes `test-require-threaded.sps`: 12 passes, 0 bytes definitely lost.
  - No suite was checked through `timeout`.
  - The two 1-error summaries are test-process's forked children, with their documented 131- and 117-byte artifacts (ADR-0003), the same as on main.
- `hadolint docker/nothreads.Dockerfile` is clean. `DL3008` (unpinned apt packages, as in `valgrind.Dockerfile`) and `DL3003` (`cd`, to keep the source tree out of the image) are annotated.
- `shellcheck docker/check-nothreads.sh` is clean.

## Not covered

- **The refusal's text on a threaded Chez.** By construction it is never shown there. Only `make check-nothreads-docker` sees it.
- **The Docker check is off the default gate and not in CI**, like `make test-memory-docker`: it builds Chez from source. The order it depends on is held on every `make test` by the static suite. Run the target after touching either the refusal or a library's import form.
- **Libraries outside `src/`** (`tests/uv-bulk.sls`) are not held by the order rule. They load only in suites, which need a threaded Chez anyway.
- **Windows** is not built here (ADR-0004).
