# Installing

chez-libuv is a set of R6RS libraries plus a small C library, the *shim*,
that sits between Chez Scheme and libuv. You build the shim once on each
machine with `make build`, then put the checkout's `src` folder on Chez's
library path and import `(libuv)`.

It runs on macOS and Linux. Windows is not supported yet.

## What you need

- **Chez Scheme 10.4.1 or newer, threaded.** Threaded is Chez's default
  build: anything not configured with `--nothreads`. A non-threaded Chez is
  refused when you import the library, with a message saying so.
- **libuv 1.48.0 or newer, in the 1.x series**, installed where
  `pkg-config` can see it: `brew install libuv` on macOS, `libuv1-dev` on
  Ubuntu 24.04. If you have none, or yours is older, the build uses a copy
  of libuv pinned in the repository instead. Building that copy needs
  `cmake`.
- **A C compiler and `make`.**

The examples here call Chez `chez`. Your install may name the binary
`scheme`; use whatever yours is called.

## Build it

1. Clone the repository with its submodules:

   ```sh
   git clone --recursive https://github.com/Kiyomi-Computation-Systems/chez-libuv.git
   cd chez-libuv
   ```

2. Build the shim:

   ```sh
   make build
   ```

3. Check it works. Save this as `hello.sps`:

   ```scheme
   (import (rnrs) (libuv))

   (define loop (make-uv-loop))
   (define timer (make-uv-timer loop))
   (uv-timer-start! timer
                    (lambda (t)
                      (display (string-append "libuv " (uv-version) " says hello\n"))
                      (uv-close! t))
                    0 0)
   (uv-run loop 'default)
   (uv-loop-teardown! loop)
   ```

   and run it with `src` on the library path:

   ```sh
   CHEZSCHEMELIBDIRS=src chez --program hello.sps
   ```

   It prints the version of the libuv it loaded, such as:

   ```
   libuv 1.52.1 says hello
   ```

`make help` lists every other target. `make dev` builds and starts a REPL
with everything on the path.

## What make build leaves behind

`make build` does two things:

1. It compiles the shim into `build/`.
2. It writes `src/libuv/private/config.sls`. That file records, for **this
   machine**, the shim's absolute path, the absolute paths of the libuv
   libraries to load before it, and the range of libuv versions the binding
   accepts.

`config.sls` is generated and is not in the repository. That is why a fresh
clone cannot `(import (libuv))` until it has run `make build`.

Run `make build` again:

- **after every upgrade.** The shim changes between releases, and a shim
  built from older sources fails the import with `&uv-shim-unavailable`.
- **after moving the checkout**, since `config.sls` holds absolute paths.

## Use it from your own project

Point `CHEZSCHEMELIBDIRS` at the checkout's `src` folder, by its absolute
path, and import `(libuv)`. Your program can live anywhere: `config.sls`
finds the shim by absolute path, not from the folder you run in.

```sh
CHEZSCHEMELIBDIRS=/path/to/chez-libuv/src chez --program app.sps
```

`(libuv)` gives you everything. Narrower libraries, such as
`(libuv process)` or `(libuv tcp)`, exist for smaller imports; the
[API reference](reference.md) lists them. The library imports nothing
beyond `(rnrs)` and Chez itself, so there is no other Scheme dependency to
put on the path.

## Choosing the shim

`CHEZ_LIBUV_SHIM` overrides where the shim is loaded from. It is read once,
when the library loads. It is configuration, so it lives in the
environment, not in your code.

It is **checked, never searched**:

- **Unset:** the path `make build` recorded in `config.sls` is used. That
  file must exist.
- **Set:** it must be an **absolute** path to a file that exists. That
  exact file is loaded.
- **Anything else** (a relative path, a path that does not exist, a
  directory) raises `&uv-shim-unavailable` at once. Nothing falls back to
  the default, nothing is searched for on any path, and the current
  directory is never consulted.

```sh
CHEZ_LIBUV_SHIM=build/lib/libchezlibuv.so CHEZSCHEMELIBDIRS=src chez --program hello.sps
```

fails because the path is relative:

```
Exception occurred with condition components:
  0. &uv-shim-unavailable: "build/lib/libchezlibuv.so"
```

## The version check

libuv keeps its binary interface stable across 1.x, so the binding accepts a
**range** of versions, not one exact version. The range starts at 1.48.0.

The first call that needs libuv, such as `make-uv-loop` or `uv-version`,
checks two versions: the libuv the shim was compiled against, and the one
actually loaded. If either is outside the range, that call raises
[`&uv-version-incompatible`](reference.md#uv-version-incompatible-condition-type)
rather than run against a libuv it was not built for.

- [`uv-version`](reference.md#uv-version-procedure) returns the loaded
  libuv's version as a string, such as `"1.52.1"`.
- [`uv-version-compatible?`](reference.md#uv-version-compatible-procedure)
  returns `#t` when both versions are in range. It runs the same check
  first, so when they are not, it raises `&uv-version-incompatible` rather
  than return `#f`.

## When the import fails

These failures happen while the library loads, before your program's first
line runs, so a `guard` in your program cannot catch them. Each prints a
message and stops.

| You see | It means | Do this |
|:--|:--|:--|
| `&uv-shim-unavailable` | the shim is missing, unreadable, or built from older sources, or `CHEZ_LIBUV_SHIM` is not an absolute path to a file | run `make build`; check `CHEZ_LIBUV_SHIM` |
| `&uv-libuv-unavailable` | the libuv library recorded in `config.sls` could not be loaded | reinstall libuv, or run `make build` again |
| `chez-libuv needs a threaded Chez Scheme` | your Chez was built with `--nothreads` | use a threaded Chez |
| `library (libuv private config) not found` | the shim was never built: no `make build`, or [Akku's install hook](#akku) did not run | run `make build`, or `akku install` and answer `y` |
| `Exception in chez-libuv: … The install hook's log is …` | [Akku's install hook](#akku) could not build the shim, for the reason it names | fix that, then run `akku install` again |

The non-threaded refusal reads:

```
Exception in chez-libuv: chez-libuv needs a threaded Chez Scheme, and (threaded?) is #f in this one. Chez builds threaded unless configured with --nothreads (require-threaded-chez) at line …, char … of …/libuv/private/require-threaded.sls
```

The [errors](errors.md#loading-and-versions) page has the full list of
loading conditions.

## Akku

A project can depend on chez-libuv through [Akku](https://akkuscm.org/).
The libraries alone cannot load, since the shim and `config.sls` are built
for each machine. So chez-libuv has an **install hook**: a script that
`akku install` runs before it installs the libraries. It does what
`make build` does, in your project:

- it builds a release shim into `.akku/ffi/` (`libchezlibuv.dylib` on
  macOS, `libchezlibuv.so` on Linux);
- it writes `config.sls` naming that shim, and Akku installs it with the
  other libraries;
- it logs every step to `.akku/ffi/chez-libuv-install.log`.

### What the hook needs

- **A C compiler:** `CC` if you set it, otherwise the first of `cc`, `gcc`
  and `clang` on your `PATH`.
- **pkg-config, and libuv 1.48.0 or newer** where pkg-config can see it:
  `brew install libuv pkg-config` on macOS, `libuv1-dev` and `pkg-config` on
  Ubuntu. The hook does not build the copy of libuv the repository pins: an
  Akku install has none.
- **`make`,** and macOS or Linux. Elsewhere the hook does not run.

### Running the hook

Akku copies a package's install scripts into your `Akku.lock` only from
the Akku index. A direct dependency, which is how a project depends on a
package that is not in the index, gets none. So your own `Akku.manifest`
runs the hook. Add this to your `akku-package` form, beside your
`depends`:

```scheme
(scripts
  (cond-expand
    ((and pre-install (or darwin linux))
     (run "sh .akku/src/chez-libuv/scripts/akku-install"))))
```

For a `(location (directory D))` dependency, use D's path in place of
`.akku/src/chez-libuv`. `chez-libuv`'s own `Akku.manifest` carries the
same hook, which is what the index would copy.

`akku install` asks before it runs a script nobody has vetted:

```
Run these commands (y/N)?
```

Answer `y`. It may ask twice, before and after it installs. An answer of
no, or no answer at all (a pipe that ends), skips the hook, and
chez-libuv cannot load. Akku 1.1.1 and later also take `akku install --yes`.

Run `akku install` again after upgrading libuv, and after moving the
project: `config.sls` holds absolute paths. Homebrew's libuv path names its
version (`/opt/homebrew/Cellar/libuv/1.52.1/lib`), and Guix's `gc` can
remove a libuv no profile uses, so either can take away the libuv the hook
found. A `.akku` folder works only on the machine that built it.

### When the hook fails

Akku 1.1.1 and later stop `akku install` and show the hook's output.

Akku 1.1.0 goes on with the install, and shows the hook's output only
with `AKKU_LOG_LEVEL=debug`. The hook leaves a `config.sls` that raises the
reason instead, so your program's first call into chez-libuv stops with it:

```
Exception in chez-libuv: pkg-config finds no libuv 1.48.0 or newer: install libuv (brew install libuv, or apt install libuv1-dev) and run akku install again. The install hook's log is /…/.akku/ffi/chez-libuv-install.log
```

Fix what it names, and run `akku install` again. `CHEZ_LIBUV_SHIM` does not
get past this message, since the failure is raised before the shim is
looked for.

The hook replaces an installed shim only once a new one is built. Under
Akku 1.1.1, a reinstall whose hook fails therefore leaves the previous
install working.

A hook that never ran leaves no `config.sls` on a first install, and the
import fails with `library (libuv private config) not found`. On a
reinstall, Akku installs whatever `config.sls` the hook last wrote into its
copy of the package: the previous build's, with that build's shim, or the
reason the hook last failed, even if that reason no longer holds. With the
previous build's, an entry the new release's sources need and the old shim
lacks raises `&uv-shim-unavailable`. Either way, run `akku install` again
and answer `y`.

### Directory dependencies and your own checkout

The hook writes `config.sls` into the package's own `src/`, which for a
`(location (directory D))` dependency is D's.

- **A D that `make build` has built is left alone:** one with a shim in
  `build/lib`, or a `config.sls` that make wrote. The hook says so and
  stops, so a checkout you work in keeps its own build. Point the lock at
  a clean copy, or run `make clean` there.
- **Two projects installing from one D at the same moment** can each
  install the other's `config.sls`.
- **In chez-libuv's own checkout,** `akku install` fetches the docs site's
  tools and runs the hook too. The hook does nothing there, since the
  checkout builds with `make build`.

The repository's `Akku.manifest` lists two development dependencies:
`chez-srfi`, which the test suites use, and `chez-cmark-gfm`, which renders
the docs site. A project that depends on chez-libuv installs neither, and
`(libuv)` itself needs neither.

## Read next

- [Quickstart](quickstart.md): an echo server, start to finish.
- [The event loop](loops.md): what `make-uv-loop` and `uv-run` do.
- [Building and testing](building.md): where libuv comes from, release
  builds and the test gates.
