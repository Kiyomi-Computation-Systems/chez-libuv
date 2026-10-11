# User docs and a published docs site: plan

Branch `docs/site`, worktree `/home/kishu/src/chez-libuv-docs`, on main
13562df, 2026-10-11.

## The ask

- User-facing docs in `docs/` as Markdown, written crisp and plain ("ELI5
  for developers"), in the voice of chez-httparse's and chez-cmark-gfm's
  `docs/`. `docs/README.md` is the index.
- A checked API reference, as chez-cmark-gfm has.
- chez-cmark-gfm comes in through Akku, as a dependency.
- chez-cmark-gfm's site machinery (rendered through chez-cmark-gfm itself)
  is copied here, so the docs publish to GitHub Pages.

## Decisions

### Akku

- `Akku.manifest` gains `("chez-cmark-gfm" "^2.0.0")` in `depends/dev`. It
  is a dev dependency: a project that depends on chez-libuv never installs
  it.
- chez-srfi's range becomes the exact version `"0.0.0-akku.181.7879b52"`.
  With the caret, `akku lock` takes the newest chez-srfi (akku.289), which
  breaks `check-pins` against the submodule. With the exact pin it keeps
  akku.181 (measured with Guix's akku 1.1.0).
- `Akku.lock` is written by `akku lock` (`guix shell akku -- akku lock`),
  not by hand. It pins both packages.
- `make site-deps` gets chez-cmark-gfm one of two ways:
  - an `akku install` tree, when `.akku/lib/cmark/gfm.sls` exists, is used
    as is;
  - otherwise `scripts/fetch-akku-lock chez-cmark-gfm` reads the URL and
    sha256 from `Akku.lock`, downloads the archive to `build/akku/dl/`,
    checks the sha256, and unpacks it to `build/akku/chez-cmark-gfm/`. It
    is a no-op when that tree's recorded sha256 equals the lock's, so it
    runs offline (the Guix container) once fetched on the host.
- `.akkuignore` names `site`, so an Akku consumer does not get the docs
  generator's `(site …)` libraries, and `make check-akku` holds that (a gap
  the review found: the brief never asked what the published package holds).
- chez-srfi stays a git submodule for the test suites. Moving it to the
  same fetch is a separate change.
- chez-cmark-gfm loads the system's `cmark-gfm` C library when imported:
  `manifest.scm` gains `cmark-gfm` (Guix 0.29.0.gfm.13; measured: renders
  in the container).

### The site

- Copied from chez-cmark-gfm `site/` (it has the reference checker that
  chez-httparse's copy lacks): `build-site.sps`, `site/{io,links,pages,
  reference,render,serializer,slug,template,transform}.sls`,
  `site/style.css`, `tests/site-check.sps`, `tests/reference-check.sps`.
- The home page is `docs/README.md`, rendered to `index.html`, and every
  link to `README.md` (or `./`) becomes `index.html`. There is no
  `site/index.md`.
- Make targets: `site-deps`, `site`, `check-reference`, `check-site`. None
  depends on `build`: the site needs Chez and cmark-gfm, not libuv or the
  shim, and `check-reference` reads `src/` with `read` only.
- `.github/workflows/pages.yml` deploys on a `v*` tag and on
  `workflow_dispatch`, as chez-cmark-gfm's does, running `site-deps`,
  `check-site` and `site`.
- `check-history` scans `site/` and `build-site.sps` too. Not
  `.github/`: `ci.yml` names sudo-rs 0.2.13, which the release pattern
  takes for one of ours.

### The pages

| File | Nav label | Covers |
|---|---|---|
| `README.md` | (home) | What this is, a taste, the page list |
| `installing.md` | Installing | Chez, libuv, `make build`, `CHEZ_LIBUV_SHIM`, using it from a project |
| `quickstart.md` | Quickstart | An echo server start to finish; the three rules |
| `loops.md` | The event loop | Make, run, stop, close, tear down; `call-with-uv-loop`; time |
| `callbacks.md` | Callbacks | What a callback may do, raises, escapes and their costs, engines |
| `threads.md` | Threads | One thread per loop, handing a loop over, async wakeups |
| `timers.md` | Timers | Timers |
| `tcp.md` | TCP and streams | Bind, listen, accept, connect, read, write, shutdown, addresses |
| `flow-control.md` | Flow control | Buffers, the write queue, read stop/start |
| `processes.md` | Processes and pipes | Spawning, stdio, exit, kill; pipes |
| `signals.md` | Signals | Signal handles |
| `dns.md` | DNS | getaddrinfo, getnameinfo, cancel |
| `errors.md` | Errors | The condition hierarchy and error symbols |
| `reference.md` | API reference | Every export, checked against `src/` |
| `building.md` | Building and testing | From source, the gates, the docs site |

`docs/api.md` is retired: its content moves to the pages above, and every
citation of it in `src/`, `tests/`, `AGENTS.md` and `README.org` moves to
the page that now holds the fact.

### Writing rules (every writer)

- Voice: second person, short sentences, one idea each. Open each page
  with what the thing is in one or two plain sentences, then one small
  example, then the details. Numbered steps for sequences.
- Every fact comes from `docs/api.md`, `docs/quickstart.md`,
  `docs/building.md`, `README.org` or `src/` (signature comments and
  code). Nothing invented. Where they disagree, `src/` wins: report it.
- Every Scheme example is run in the Guix container before it is
  written down, and a shown result (`;; =>`) is the real one.
- Warnings are a blockquote starting with ⚠️ (the site renders it as a
  callout). Use them for what loses data, hangs or crashes.
- Headings are plain words: no punctuation, code or em dashes, so the
  anchor is the lowercase words joined by hyphens. Link across pages as
  `page.md#anchor`, and to the reference as `reference.md#anchor`.
- No history: no issue or PR numbers, dates, release numbers, ADRs or
  `.plans` paths (`make check-history` fails them in `docs/`).
- No Windows promises: ADR-0004 defers Windows.

## Who does what

1. Me: Akku files, `scripts/fetch-akku-lock`, `manifest.scm`, the Make
   targets, `pages.yml`, `docs/README.md`, the citation sweep, `README.org`.
2. Sonnet: copy and adapt the site machinery (`site/`, `build-site.sps`,
   `tests/site-check.sps`, `tests/reference-check.sps`).
3. Sonnet: `docs/reference.md`, every export, to the checker's convention.
4. Opus writer A: `quickstart.md`, `loops.md`, `callbacks.md`, `threads.md`.
5. Opus writer B: `timers.md`, `tcp.md`, `flow-control.md`, `dns.md`.
6. Opus writer C: `processes.md`, `signals.md`, `errors.md`,
   `installing.md`, `building.md`.
7. Opus: read-only adversarial review of the whole branch.

Agents run in parallel on disjoint files, and none commits.

## Checks

- `make check-reference`: every public export has exactly one entry, in
  the modules that export it, and nothing else.
- `make check-site`: every page in the nav, every link and anchor
  resolves, no `.md` link leaks into the HTML, no `<pre>` is reflowed, and
  every relative link names a file the site writes (added here: without
  it, a home page written as one name and linked as another passed).
- `make check-site-deps`: `scripts/fetch-akku-lock`, offline.
- `make check-history`, `make check-help`, `make check-pins`, `make test`.
- Mutations for the new checks, logged in
  `.plans/docs-site-mutation-log.md`.

## Not in this change

- Moving chez-srfi from the submodule to the Akku fetch.
- A check that runs the docs' examples (chez-cmark-gfm's `examples/` gate).
- Turning Pages on in the repository's settings (Source: GitHub Actions),
  and the first deploy: Actions has no minutes left in October.
