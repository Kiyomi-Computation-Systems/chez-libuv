# Akku install hooks — mutation log

The design is `.plans/2026-10-12-akku-install-hooks-design.md`. The check
under test is `scripts/check-akku` (`make check-akku`).

## How the rows ran

- **The harness:** `scratchpad/akku-hooks/mutate.py` and `rows.py`.
  - Each row copies the worktree's tracked and new files (`git ls-files
    --cached --others --exclude-standard`) into a fresh directory outside the
    repository, and makes that copy a git repository, because check-akku
    archives what git tracks.
  - It applies exact replacements, aborting unless each matches once.
  - It then runs `make check-akku` there, under the Akku named by `AKKU`.
  - `runall.py` runs four rows at a time.
- **Where:** macOS arm64, Darwin 25.6.0, Chez 10.4.1, Homebrew libuv 1.52.1.
- **The two Akkus:**
  - 1.1.1-beta.0 (`~/.local/bin/akku`, on `PATH`), which stops an install
    whose script fails;
  - Homebrew's 1.1.0 (`/opt/homebrew/opt/akku/bin/akku`), which ignores a
    script's exit status.

## The red

Before the hook existed, check-akku on the tree with no `scripts` in
Akku.manifest failed:

```
check-akku: FAIL: row 1 (index route, archive, a parent make's MAKEFLAGS): the hook ran 0 times, not once
```

Two earlier stops were the check's own:
- macOS tar's pax headers, which carry binary xattrs, crash Akku's tar
  reader (`utf8->string` decoding error). The archive is now ustar, with
  `COPYFILE_DISABLE=1`.
- A new script is not in `git ls-files` until it is added. It is now added
  intent-to-add.

## Mutants

All rows ran on the final tree, under both Akkus, four at a time.
- **Controls (no mutation):** pass under both, in 35-43 s (1.1.1) and
  52-66 s (1.1.0).
- **"Row 1:"** in the table is short for "row 1 (index route, archive, a
  parent make's MAKEFLAGS)".
- **`no-trap`** was rerun after the row-1 assertion was fixed (see below).
  That assertion runs only on leftover files in `.akku/ffi`, and no other
  mutant touches the build directory's cleanup.
- **`flavor-dropped`** ran under 1.1.1 only.

| Mutant | The decision it breaks | 1.1.1 fails | 1.1.0 fails |
|---|---|---|---|
| `no-scripts` | Akku.manifest carries the hook | row 1: the hook ran 0 times, not once | same |
| `osx` | the OS feature is `darwin` | row 1: the hook ran 0 times | same |
| `phase` | the phase is in the clause | row 1: the hook ran 2 times, not once | same |
| `no-sh` | `run` invokes `sh` (archives keep no modes) | row 1: akku install failed (`Permission denied`, 126) | row 1: the hook did not say it built the shim into .akku/ffi |
| `prompt-no` (the check answers n) | the check answers both prompts y | row 1: the hook ran 0 times | same |
| `ignore-build` | `.akkuignore` has `build` | row 1: the installed libraries are not exactly src/'s plus config.sls (+stray.sls) | same |
| `ignore-vendor` | `.akkuignore` has `vendor` | row 1: same (+stray/stray.sls) | same |
| `hook-exits-first` | the hook runs at all | row 1: akku install failed | row 1: the hook did not say it built the shim |
| `no-config` | config.sls is generated and verified | row 1: the installed libraries are not exactly ... (-config.sls) | same |
| `makeflags` | the hook clears MAKEFLAGS | row 1: akku install failed ("pkg-config finds no libuv") | row 1: the hook did not say it built the shim |
| `flavor-dropped` | `FLAVOR=prod` on make's command line | row 1: akku install failed ("FLAVOR must be dev or prod, got 'bogus'") | not run |
| `dev-flavor` | the shim is a release build | row 1: the installed shim is a dev build (it exports the pool hold) | same |
| `shim-in-source` | the shim goes to `.akku/ffi` | row 1: the hook did not say it built the shim into .akku/ffi | same |
| `no-trap` | the build directory is removed | row 1: the hook left .../.chez-libuv-build.XXXXXX in .akku/ffi | same |
| `delete-final-first` | the old shim is replaced only after a build | row 2 (reinstall with a compiler that fails): the previous install: the program failed on the installed libraries | **passes**: 1.1.0 installs the stub over a failed reinstall whatever the shim, so the property is 1.1.1's alone |
| `no-stub` | a failure writes the stub | row 3: the source's own config.sls: the program did not raise the hook's reason | row 2: the program did not raise the hook's reason (compiling the shim failed) |
| `stub-no-log` | the stub names the log | row 3: the source's own config.sls: the raised message does not name the hook's log | row 2: the raised message does not name the hook's log |
| `guard-by-shim-path` | the guard decides by origin | row 3b: akku install failed | row 3b: the program failed on the installed libraries |
| `build-dir-in-source` | the build's files go outside the source | row 3b: the hook wrote a build/ directory into the source | same |
| `logical-path` | the root skip compares physical paths | row 4: the hook did not say it skipped chez-libuv's own checkout | same |
| `root-skip-dropped` | the hook skips chez-libuv's own checkout | row 4: same | same |
| `guard-dropped` | a built directory source is refused | row 5: akku install succeeded; the hook should have refused | row 5: the hook did not refuse the built checkout |
| `werror` | the hook passes `WERROR=` | row 6: the compiler's warning failed the hook's build (-Werror) | same |
| `path-check-dropped` | unsafe characters in `.akku/ffi`'s path are refused | row 7 (space and double quote): akku's output does not give the hook's reason | row 7: the program did not raise the hook's reason |
| `stub-unescaped` | the stub escapes `\` and `"` | row 7: the source's own config.sls: the program did not raise the hook's reason | row 7: the program did not raise the hook's reason |
| `cc-check-dropped` | a missing compiler is named | row 7 (no C compiler): akku's output does not give the hook's reason | row 7: the program did not raise the hook's reason |
| `writable-check-dropped` | an unwritable source is named | row 7 (unwritable source): the hook did not say it cannot write into the source | same |

The first full run found three defects in the check itself, each fixed and
each mutant rerun:
- `no-trap` survived under both Akkus. The assertion was `! ls -d A* B*`,
  and `ls` exits nonzero when either glob matches nothing, so it passed
  whatever was left. Each name is now tested on its own.
- `delete-final-first` and `werror`; see below.

## What the rows taught

- **`delete-final-first` survived the first version of row 2.** Row 2's
  failing reinstall hid libuv, and the hook stops for that before the step
  the mutant changes. The row now fails the reinstall with a compiler that
  exits 1, which gets past every earlier check. Then the mutant fails it:
  under 1.1.1 the previous install's program no longer loads.
- **`werror` failed row 6 on the wrong assertion at first.** Under
  `-Werror`, clang prints the diagnostic as `error: ... [-Werror,-W#warnings]`,
  with no `warning:`, so "shown as a warning" failed before "failed the
  build (-Werror)". The `error:` assertion now comes first.
- **A declined reinstall installs whatever `config.sls` the hook last wrote
  into Akku's copy of the package.** Measured on a kept work directory:
  - row 2's failed 1.1.1 reinstall left the stub in
    `.akku/src/chez-libuv/src/...`, and the good copy in `.akku/lib`;
  - an `akku install` answered `n` twice (two prompts: pre- and
    post-install, since an entry not in the index prompts even for a no-op)
    then installed the stub;
  - the program raised the stub's old reason, though libuv was visible.

  docs/installing.md says so. Nothing in the package can change it: the
  hook is what didn't run.

## Uncovered, and why

- **"pkg-config not found":** no row. It needs a `PATH` that has `make`, `sh`
  and a compiler but no `pkg-config`, and no fixture builds one.
- **The facts step's failures** ("make could not read chez-libuv's
  Makefile", "make printed no config.sls exports") need a broken Makefile.
- **The checks after a make that succeeded** ("make built no shim", "could
  not move the shim", "writing config.sls failed", "config.sls does not name
  ..."): no fixture makes make succeed without its file.
- **"the libuv library ... does not exist":** unreachable through a
  fixture. A `.pc` file whose libdir doesn't exist fails the link first.
- **The order of the `cc`, `gcc`, `clang` fallback:** every row has `CC`
  unset on a machine with `cc`, or sets it. Row 7 holds the "no C compiler"
  reason through a `CC` that doesn't exist.
- **Without Akku's environment the hook exits 2:** run by hand, not by a
  row. It printed "akku-install: akku install runs this (akku_path_root and
  akku_path_lib_ffi are unset)" and exited 2.
## Linux, on kishu

kishu-libuv-issues-b ran the check at d9e0108, in a fresh worktree and a
`guix shell --pure`. A non-pure shell keeps the host's `/usr/bin/cc`, so the
hook would never look for gcc.

- **`CC` unset, Guix's packages** (Akku 1.1.0, libuv-for-node-lts 1.52.1,
  gcc 16.2.0, Chez 10.4.0, no `cc`):
  - rows 1-4 passed;
  - the hook found gcc itself: c3b's log says "building with gcc, libuv
    1.52.1";
  - row 5 failed in the check's own setup: "make build: cc not found", then
    "row 5 (a built checkout as a directory source): make build failed in
    the copy" (finding A).
- **`CC=gcc`, same shell:** rows 1-7 pass.
- **`CC=gcc`, the repo's pinned toolchain** (`guix time-machine -C
  channels.scm -- shell --pure -m manifest.scm akku`; Chez 10.4.1): rows 1-7
  pass, in 47 s.
- **Guix's plain `libuv` (1.44.2):** the hook refused it correctly. Its log
  said "pkg-config finds no libuv 1.48.0 or newer". But the check reported
  only "row 1: the hook did not say it built the shim", and the tail it
  printed lacked the reason, since 1.1.0 shows script output only at debug
  level (finding B).
- **`make test` through `scripts/guix-env`:** 39 suites, 2,354 passes. The
  dev build still compiles with `-Werror`.

### The two findings, reproduced on macOS and fixed

- **A: the check's setup took the caller's compiler.** Row 5 ran `make
  build` with `CC` unset, and row 6's warning wrapper executed `$CC`, which
  defaulted to `cc`.
  - **Reproduced:** with `CC` unset and a `PATH` holding every tool but `cc`
    (symlinks to all of this Mac's `PATH`, `gcc` included), the committed
    check failed exactly as on kishu.
  - **Fixed:** the check finds its setup compiler the way the hook does
    (`CC`, else `cc`, `gcc`, `clang`) and passes it to row 5's make and row
    6's wrapper. The same no-`cc` run now passes under 1.1.1 and 1.1.0.
- **B: a libuv below the floor failed row 1 without its reason.**
  - **Reproduced:** a `libuv.pc` copy that says 1.44.2, under
    `PKG_CONFIG_LIBDIR`.
  - **Fixed:**
    - the check reads the floor from `make akku-facts` and refuses up front:
      "pkg-config finds no libuv 1.48.0 or newer (it finds 1.44.2); every
      row needs one";
    - a failing row's `fail_log` also prints the consumer's
      `.akku/ffi/chez-libuv-install.log`. Seen under 1.1.0 with the
      `makeflags` mutant: row 1's failure is now followed by the hook's log,
      which names the reason.
- **Docs:** the documented Guix command used Guix's own `libuv`, which is
  1.44.2. It now uses the pinned toolchain plus Akku, in the Makefile
  comment and docs/building.md.

### The rerun at f3fecf0, on kishu, with `CC` unset

- **The documented command, as written, failed in 3 s:** "tar: not found",
  then "could not archive the tracked files" (finding C). The `--pure`
  shell holds only manifest.scm's packages, and those have no `tar` or
  `gzip`. kishu probed that shell for every tool the check and the hook
  call, and only those two were missing. `shasum`, `cc` and `clang` are
  absent too, but each is only a fallback.
  - **Fix:** the documented command adds `tar gzip` after `akku`.
    manifest.scm is unchanged, since a change there would also change the
    guix-env container and its pin check.
- **The same command plus `tar gzip`:** rows 1-7 pass, in 47 s. The first
  decision line of each consumer's hook log:

  | Consumer | First decision line |
  |---|---|
  | c3b | "building with gcc, libuv 1.52.1" (the fallback with `CC` unset) |
  | c3 | "pkg-config finds no libuv 1.48.0 or newer ..." |
  | c6 | "building with .../cc-warn" |
  | c7b | "no C compiler ..." |
  | c7 "odd" | "the path ... holds a character make cannot take ..." |
  | c5, c7c | the header line alone: their refusals went to the hook's output, and both rows passed |

  Row 5 passes, so finding A holds fixed on Linux.
- **Guix's plain libuv (1.44.2), `CC` unset:** the check stopped in 2 s,
  before any row: "pkg-config finds no libuv 1.48.0 or newer (it finds
  1.44.2); every row needs one". So finding B holds fixed on Linux.

The command as now documented (with `tar gzip`) is the one kishu ran in the
second item, less `CHECK_AKKU_KEEP=1`.

## Gates

On the final tree, macOS arm64:

- **`make check-akku`:** passes under 1.1.1-beta.0 (35 s) and 1.1.0
  (52 s).
- **`make test`:** passes; 39 suites, 2,354 expected passes, none
  unexpected.
- **`make check-history`, `check-pins`, `check-help`:** pass. Every changed
  shipped file was also given to `scripts/check-history-refs` by name. Only
  `Akku.manifest`'s package version, which it must carry, is flagged.
- **`make check-site`:** passes, including the two new in-page links.
