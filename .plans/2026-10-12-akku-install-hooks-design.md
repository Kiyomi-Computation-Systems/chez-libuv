# Akku install hooks — design

Status: revised after an adversarial review (Opus, read-only), before
building. Branch `feat/akku-install-hooks` from 803cf94.

## Goal

A project that depends on chez-libuv through Akku gets a working
`(import (libuv))` from `akku install`. Today `akku install` lands `src/`'s 21
libraries and nothing else: no shim and no `config.sls`, so the import fails
with Chez's "library (libuv private config) not found".

**How a hook reaches a consumer** (measured; review finding 1). Akku runs two
kinds of scripts: the current project's own `Akku.manifest` scripts, and the
`(scripts ...)` of each entry in its `Akku.lock`. `akku lock` writes an
entry's scripts only from the Akku index (lock.scm:265-272). A direct
dependency, the only way to depend on a package that is not in the index,
gets a lock entry with none (lock.scm:160-180; measured: a manifest
`(depends ("fakepkg" (version ...) (location (directory ...))))` locked to an
entry with no `scripts`). So:

- **The index route:** chez-libuv's `Akku.manifest` carries the hook. Once
  chez-libuv is in the index, `akku lock` copies it into every consumer's lock
  and it runs with no work on the consumer's side. Publishing is out of
  scope, so this route is checked with a lock entry that carries the scripts,
  as `akku lock` would write it.
- **The consumer route, which works today:** the consumer's own manifest runs
  the same hook script by path:
  `(scripts (cond-expand ((and pre-install (or darwin linux)) (run "sh .akku/src/chez-libuv/scripts/akku-install"))))`.
  It runs from the consumer's root after the fetch and before the install
  (measured), and it survives `akku lock`. For a `(directory D)` dependency
  the path is D's.

Both routes run one script, `scripts/akku-install`.

## Akku, measured on this Mac (2026-10-12)

Two Akkus are installed:
- **Homebrew's 1.1.0** (`/opt/homebrew/opt/akku/bin/akku`), the release Guix
  also ships;
- **1.1.1-beta.0** on `PATH` (`~/.local/bin/akku`), built from Akku's git.

A probe package (`scratchpad/akku-probe`) recorded each script's cwd,
environment and features under both. The review then checked each fact against
both versions' source.

| # | Brief's claim | 1.1.0 | 1.1.1-beta.0 |
|---|---|---|---|
| 1 | order: fetch, pre-install, install, post-install | confirmed | confirmed |
| 2 | `(scripts EXPR ...)`, `run` / `cond-expand` | confirmed | confirmed |
| 3 | exit status ignored, output at debug only | **confirmed**: a hook exiting 3 left `akku install` at 0, everything installed | **overturned**: exit 1, `[error] Script output: ...`, nothing installed |
| 4 | `akku_path_*`, absolute | confirmed | confirmed |
| 5 | cwd: the package's source dir; D for `(directory D)` | confirmed; a current project's script runs in the project root | same |
| 6 | unvetted scripts prompt; EOF or blank is no | confirmed, **per phase**. A lock entry not in the index prompts even when its expansion is a no-op; the current project's no-op does not | same; also `-y`/`--yes` |
| 7 | os feature = `uname -s` lowercased | `darwin` matched, `osx` did not | same |
| 8 | every file scanned | `build/stray.sls` was installed. `.akkuignore` lines match a **bare name at any depth** | same |
| 9 | git fetch skips submodules | confirmed by source | same |

Also:
- A `run` outside a phase `cond-expand` runs in both phases.
- The URL fetch extracts with Akku's own tar reader, which writes every file
  with default permissions: **no executable bits** (fetch.scm:100-125).
- A file a hook writes into `.akku/src/<name>` survives a re-fetch, for both
  git and archive sources.
- Akku *copies* a dependency's files into `.akku/lib` (it symlinks only the
  current project's), and `remove-extraneous-files` walks only `.akku/lib`.
- `AKKU_LOG_LEVEL=debug` shows every script's output under both.
- A cached archive at `$XDG_CACHE_HOME/akku/<name>-<sha256>` is extracted
  without a download when its hash matches.

## Design

### The manifest (the index route)

```scheme
(scripts
  (cond-expand
    ((and pre-install (or darwin linux))
     (run "sh scripts/akku-install"))))
```

- **pre-install only:** `config.sls` must be in the source tree before the
  install step scans it. Nothing is left for post-install.
- **Phase and OS in one clause,** so the hook runs once, and only on the two
  supported systems. `osx` never matches.
- **`sh` by name:** an archive install drops the script's executable bit.

### `scripts/akku-install`

POSIX sh. It changes to its own package directory (`$(dirname "$0")/..`,
physical), so it does the same from either route.

1. **Akku's environment required:** without `akku_path_root` and
   `akku_path_lib_ffi` it exits 2 with a usage line.
2. **chez-libuv's own checkout is skipped.** When `dirname
   "$akku_path_root"` equals the package directory (both physical:
   `akku_path_root` comes from Guile's `getcwd`), the project being installed
   is chez-libuv itself. `akku install` there fetches the docs site's
   development dependency, and the checkout builds with `make build`. The hook
   prints that and exits 0, writing nothing.
3. **A built checkout used as a `(directory D)` source is left alone.** This
   applies only when the package directory is not under
   `$akku_path_root/src/`. If D holds `build/lib/libchezlibuv.*` or a
   `config.sls` that `make` generated, the hook refuses, names it, and exits 1
   without writing. Under 1.1.0 the install then uses D's own `config.sls`,
   which names a shim that exists.
   - The decision is by origin. `config.sls`'s header says which generator
     wrote it: `make`, or `akku-install` for the hook's own files, success or
     stub. It is not decided by where `shim-path` points, so a moved consumer
     and two consumers sharing D both work.
4. **Facts from the Makefile:** `make -s akku-facts` prints, one per line:
   - `have_pkg`;
   - the libuv floor;
   - the library suffix;
   - `config.sls`'s export list;
   - the libuv paths `config.sls` will name.
   Every make the hook runs has `MAKEFLAGS`, `MFLAGS` and `MAKELEVEL` cleared,
   so a parent make's command-line variables can't reach it, and takes
   `FLAVOR=prod` on its own command line.
5. **Checks, each with its own reason:**
   - `akku_path_lib_ffi` holds no character that make or a Scheme string
     can't take (whitespace, `$ : % ' " \`);
   - a C compiler: `$CC`'s first word, else `cc`, `gcc`, `clang`, passed on as
     `CC`;
   - `pkg-config` on `PATH`;
   - `have_pkg` = yes, meaning libuv at the floor or newer. The vendored leg
     is not tried: an Akku source has no `vendor/libuv`;
   - `src/libuv/private/` is writable.
   Chez is not needed: `config.sls` is written by `printf`.
6. **Build, leaving the previous install working until the new one is
   ready:**
   - make links `$ffi/.libchezlibuv.EXT.new`, with `FLAVOR=prod`, `WERROR=`,
     and `BUILD_DIR` a temporary directory removed afterwards, so the hook
     writes nothing into the source but `config.sls`;
   - verify it, then `mv` it to `$ffi/libchezlibuv.EXT`;
   - make writes `config.sls` with `SHIM` set to that final path and `-o` on
     it (so make doesn't relink), and `CONFIG_GENERATOR=akku-install`.
7. **Verify:** `config.sls` names the final shim, and each libuv path exists.
8. **Log** every step to `$ffi/chez-libuv-install.log`, and print one success
   line.

**On a failure from step 5 on:**
- the hook writes a stub `config.sls` (header `GENERATED by akku-install`),
  with the reason and the log's path escaped into a Scheme string;
- it prints the log and exits 1.

The stub defines every export as a call that raises, so the first use of
chez-libuv raises:

```
Exception in chez-libuv: <reason>. The install hook's log is <path>
```

Chez invokes libraries lazily, so a program that imports `(libuv)` and calls
nothing never raises. Measured: `uv-version` raises it.

**What each Akku shows:**

| Case | 1.1.0 | 1.1.1 |
|---|---|---|
| fresh install, hook fails | install succeeds; first use raises the stub's message | `akku install` fails with the hook's output; nothing installed |
| reinstall, hook fails | the stub replaces the previous `config.sls` | previous install intact: its `config.sls` in `.akku/lib`, its shim untouched (only `.new` was written) |
| hook never ran (prompt declined, another OS, no `make`) | "library (libuv private config) not found" on a fresh install; the previous `config.sls` on a reinstall | same |

The docs map each message to its cause.

### Makefile

- `CONFIG_EXPORTS` (the export list) and `CONFIG_GENERATOR := make`, both
  used by `GEN_CONFIG_SLS`.
- `WERROR := -Werror` in `CFLAGS_BASE`. The hook passes `WERROR=`, because a
  consumer's newer compiler or libuv headers must not fail the install over a
  warning. Dev builds and CI keep it.
- `akku-facts`, documented in `make help`.

### `.akkuignore`

Add `build` and `vendor`. A built checkout used as a `(directory D)` source
has `.sls` files under both (`build/akku/...`, `vendor/chez-srfi`). Nothing in
`src/` is named either.

## The check (`make check-akku`), test first

- **Akku runs** with `AKKU_LOG_LEVEL=debug`, stdin `y\ny\n` (both prompts,
  and never a tty), and `MAKEFLAGS` cleared, except where a row says
  otherwise.
- **Consumer programs** run under `env -u CHEZ_LIBUV_SHIM` with
  `CHEZSCHEMELIBDIRS=.akku/lib`.
- **The Akku's version** (`$AKKU version`) picks the expected outcome where
  1.1.0 and 1.1.1 differ.

1. **Index route, from an archive** (a `.tar.gz` of the tracked files, plus
   the planted `build/stray.sls` and `vendor/stray/stray.sls`, in a private
   `XDG_CACHE_HOME`, locked by URL and sha256 with the manifest's
   `(scripts ...)`). The environment is hostile: `MAKEFLAGS='HAVE_PKG=no'
   FLAVOR=bogus`.
   - `akku install` exits 0, with exactly one `Running "sh scripts/akku-install"`
     line and the hook's success line;
   - the installed set is the tracked `src/*.sls` plus
     `libuv/private/config.sls`, exactly: neither stray;
   - the program prints `(uv-version)`, which must equal `pkg-config
     --modversion libuv`, and a timer's callback fired, both of which only a
     loaded shim can produce;
   - the shim is a release build: `chez_uv_debug_pool_hold` absent, with
     `chez_uv_constant` present as the control;
   - `(shim-file)` is under this consumer's `.akku/ffi/`.
2. **Reinstall,** in the same consumer:
   - once more, which must still work;
   - once with no libuv visible. Under 1.1.1 the install fails with the reason
     and the program still works; under 1.1.0 the program raises the stub's
     message, naming the log.
3. **No usable libuv** (`PKG_CONFIG_LIBDIR` an empty directory,
   `PKG_CONFIG_PATH` empty), on a fresh consumer from a clean `(directory D)`
   copy:
   - under 1.1.1, the install fails with the reason; under 1.1.0, the
     program's first verb raises it, naming the log;
   - under both, D's `config.sls` is the stub, and a program on D's `src/`
     raises the same.
4. **chez-libuv's own checkout:** the copy, with an `Akku.lock` listing no
   projects. Expect the hook's skip line, no `config.sls`, and no shim.
5. **A built checkout as `(directory D)`:** `make build` in a copy, then a
   consumer from it. Expect the hook's refusal naming D's `config.sls`, which
   is byte-identical afterwards.
6. **Consumer route:**
   - a consumer whose manifest `depends` on a clean D directly and runs D's
     `scripts/akku-install`, through `akku lock` then `akku install`;
   - `CC` is a wrapper that adds a `#warning` header. The hook's log must show
     the warning as a warning, and the install must succeed;
   - the lock entry has no `scripts`, which is the fact the route exists for;
   - the program works.

## Mutants

In a copy outside the repo, each failing its row by name. Each runs under
1.1.1, and the hook-failure ones under 1.1.0 too.

| Mutant | Row |
|---|---|
| no `scripts` in Akku.manifest | 1: library set lacks config.sls |
| the script exits 1 first | 1 (1.1.1: install fails; 1.1.0: the program raises) |
| the check answers `n` | 1: library set lacks config.sls |
| config.sls not generated, verification dropped | 1: library set |
| `build` dropped from .akkuignore | 1: library set has `stray.sls` |
| `vendor` dropped from .akkuignore | 1: library set has `stray/stray.sls` |
| `osx` for `darwin` | 1: library set lacks config.sls |
| phase dropped from the clause | 1: two `Running` lines |
| `run "scripts/akku-install"` without `sh` | 1: archive install loses the exec bit |
| `MAKEFLAGS` not cleared | 1 |
| `FLAVOR=prod` dropped | 1: release-shim assertion |
| shim built inside the source (`SHIM` not overridden) | 1: `.akku/ffi` assertion |
| final shim deleted before the build | 2: 1.1.1 program after a failed reinstall |
| root skip compares logical paths (`pwd`) | 4 (macOS `$TMPDIR` is a symlink) |
| root skip dropped | 4 |
| built-checkout guard dropped | 5 |
| guard by `shim-path` instead of origin | 5, or 1 on reinstall |
| no stub / stub without the log path | 3 |
| `WERROR=` not passed | 6: the warning becomes an error |

Logged in `.plans/akku-install-hooks-mutation-log.md`.

## Docs

docs/installing.md's Akku section:
- **The two routes,** with the consumer route's manifest lines.
- **What the hook needs:** a C compiler, pkg-config, and libuv at the floor
  or newer.
- **The prompts:** two on the index route for a package not in the index,
  one on the consumer route.
- **Where things go:** `.akku/ffi` for the shim and the log.
- **Failure messages:** each one and what it means, including that 1.1.0
  shows the hook's output only with `AKKU_LOG_LEVEL=debug`.
- **What moves later:**
  - Homebrew names a versioned libuv directory, so `brew upgrade` with a
    cleanup needs a reinstall;
  - Guix's `gc` can remove the store libuv that `config.sls` names;
  - `.akku` doesn't move between machines.
- **Edge cases:**
  - a built `(directory D)` is left alone;
  - `CHEZ_LIBUV_SHIM` can't get past a stub;
  - Akku never removes `.akku/ffi`.

Elsewhere:
- README.org's install paragraph;
- docs/building.md's `check-akku` entry and `akku-facts`;
- CHANGELOG's Unreleased section, under Added.

## Review findings and what became of them

1. **Blocker, the hook can't reach a consumer.** Adopted: both routes, one
   script, row 6.
2. **Blocker, the exec bit is lost on archive installs.** Adopted: run with
   `sh`; row 1 installs from an archive.
3. **Major, the guard refused moved and shared consumers.** Adopted: it
   decides by origin, and only for sources outside `.akku/src`.
   - It also refuses a D with a dev shim and no `config.sls`. That replaces
     the suggested Makefile `config-guard`, so `build` is unchanged.
4. **Major, a declined prompt on upgrade installs the old `config.sls`.**
   Documented, not built.
   - A `make build` user who upgrades without rebuilding has the same hazard.
     The shim's export check (`shim-entry`) catches a missing entry for both,
     and a changed signature for neither.
   - A version stamp in `config.sls`, checked by native.sls, is the fix for
     both. It is deferred as its own change.
5. **Major, `-Werror` on consumers.** Adopted: `WERROR`; row 6's warning.
6. **Major, the environment and `MAKEFLAGS` leak in.** Adopted: cleared for
   every make, `FLAVOR=prod` on its command line; row 1 is hostile.
7. **Major, no `cc` on Guix; Linux never checked.** CC fallback adopted. The
   Linux run of check-akku waits for the user's go, per the brief.
8. **Major, a failed rebuild breaks a working install.** Adopted: link to
   `.new`, `mv` on success, `config.sls` via `-o`; row 2.
9. **Major, rows that pass on wrong code.** Adopted: debug log level, the
   hook's own words, branching on the Akku version, `y\ny\n` with one
   `Running` line, stdin always redirected, `env -u CHEZ_LIBUV_SHIM`, a verb
   called in the failure rows.
10. **Minor, unusual characters in paths.** Adopted: refused with a reason,
    and the stub's strings escaped.
11. **Minor, stamps written into D's build/.** Adopted: a temporary
    `BUILD_DIR`.
12. **Minor, the docs.** Adopted, as listed above.
13. **Minor, `$(MAKE)` in a recipe.** Moot: the entry is the script, and
    `akku-facts` only prints.
14. **Nit, failure reasons.** Adopted: pkg-config missing and libuv missing
    or old are separate reasons, and so is an unwritable source.
15. **Nit, a tracked fallback config.** Not taken: it changes how the dev
    build resolves `config.sls`.

The open questions:
- **Q1:** the guard was reworked, as above.
- **Q2:** bypassing `build` loses nothing.
- **Q3:** the stub raises at first use, not on import (measured).

## As built

The evidence is in `.plans/akku-install-hooks-mutation-log.md`.

- **Row 2's failing reinstall uses a compiler that fails, not hidden
  libuv.** The hook stops for hidden libuv before it touches the shim, so
  the "delete the final shim first" mutant survived the first version.
- **Row 3b:** a second consumer of a directory whose `config.sls` is the
  first consumer's stub. The hook's origin check must replace it, and a
  `shim-path` guard fails it.
- **Row 7:**
  - a project path with a space and a double quote, which also holds the
    stub's escaping;
  - a `CC` that doesn't exist;
  - a source the hook can't write.
- **Row 1 also checks** that no temporary build directory or `.new` shim is
  left in `.akku/ffi`, and row 3b that no `build/` lands in a directory
  source.
- **Row 4 enters through a symbolic link,** so a hook comparing logical
  paths fails it.
- **Akku 1.1.1 logs a script's output lines written,** with `\` and `"`
  escaped, so the check compares written forms there.
- **A declined reinstall installs the `config.sls` the hook last wrote in
  Akku's copy** (measured). That can be a stub whose reason no longer holds.
  docs/installing.md says so.

## Out of scope

- Publishing to the Akku index;
- Windows;
- the vendored libuv under Akku;
- chez-http-server;
- the version stamp (finding 4).
