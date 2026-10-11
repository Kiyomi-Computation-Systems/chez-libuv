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

The non-threaded refusal reads:

```
Exception in chez-libuv: chez-libuv needs a threaded Chez Scheme, and (threaded?) is #f in this one. Chez builds threaded unless configured with --nothreads (require-threaded-chez) at line …, char … of …/libuv/private/require-threaded.sls
```

The [errors](errors.md#loading-and-versions) page has the full list of
loading conditions.

## Akku

Akku cannot install chez-libuv on its own. The shim and `config.sls` are
built for each machine, so a copy of the source alone cannot load. Install
from a git checkout, as above.

The repository does have an `Akku.manifest`. It lists only development
dependencies: `chez-srfi`, which the test suites use, and `chez-cmark-gfm`,
which renders the docs site. A project that depends on chez-libuv installs
neither, and `(libuv)` itself needs neither.

## Read next

- [Quickstart](quickstart.md): an echo server, start to finish.
- [The event loop](loops.md): what `make-uv-loop` and `uv-run` do.
- [Building and testing](building.md): where libuv comes from, release
  builds and the test gates.
