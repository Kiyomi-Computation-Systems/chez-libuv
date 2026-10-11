# User docs and the docs site: mutation log

Branch `docs/site`, on main 13562df, 2026-10-11. Guix container
(ADR-0020), x86_64, Chez 10.4.1. The plan is
`.plans/2026-10-11-docs-site-plan.md`.

## What is checked

- `make check-site-deps` (`tests/fetch-akku-lock.sh`, on the host): eight
  rows over `scripts/fetch-akku-lock`, offline, with an archive and a lock
  of its own behind a `file://` URL.
- `make check-akku` (`scripts/check-akku`, on the host, ported from
  chez-cmark-gfm): installs this package into a throwaway Akku consumer and
  requires exactly the tracked `src/*.sls` to land. `.akkuignore` keeps
  `site/` out.
- `make check-reference` (`tests/reference-check.sps`): every export of
  `(libuv)` and `src/libuv/*.sls` has one entry in `docs/reference.md`, with
  a kind label from a fixed list, available from exactly the libraries that
  export it. It checks presence only: an entry's kind is never compared with
  the definition, and its signature, text and Raises line are free text.
- `make check-site` (`tests/site-check.sps`), on the real pages:
  1. the nav names exactly `docs/*.md`;
  2. every anchor resolves;
  3. no relative `.md` link reaches the HTML;
  4. no `<pre>` is reflowed;
  5. every relative link names a file the site writes. New here: chez-cmark-gfm
     has no such check, and without it a home page written under one name and
     linked under another passes 1 to 4;
  6. every link out to the repository (a `../` escape) names a file the
     checkout has;
  7. every heading's anchor is the same on GitHub as on the site.

  Checks 3, 5 and 6 scan only markup: a code sample that shows `href="…"`
  is text, not a link, and a fixed probe holds that.
- CI runs `check-site-deps` and `check-site` in the vendored job, so a pull
  request that breaks the docs fails before merge, not at the release's
  Pages job.

## Mutants

### fetch-akku-lock

In a copy outside the repo (`$SCRATCH/mfetch2`), against
`tests/fetch-akku-lock.sh`:

| Mutant | Rows that failed |
|---|---|
| M1 the sha256 is not compared | "an archive whose sha256 differs from the lock is refused, and nothing is unpacked" |
| M2 the recorded sha256 is ignored, so every run downloads | "an unpacked tree that records the lock's sha256 is left alone, offline" |
| M3 the lookup ignores the project's name | five of six: unpacked, offline, refused, missing, re-pin |
| M4 a refused archive is kept | "an archive whose sha256 differs …" |
| M5 the old tree is not removed before a re-pin | "a re-pinned archive replaces the old tree whole" (the row was added for it: M5 survived the first five rows), and "without xz …" |
| M6 the archive piped from `xz` into `tar -xf -`, the first version | nothing, with GNU tar: on an empty stream GNU tar fails, so the pipe fails too. With bsdtar (macOS) an empty stream is an empty archive and the pipe succeeded with an empty tree (the review showed it with libarchive's bsdtar); row 8's empty-tree refusal is what catches that there |
| M7 an empty tree accepted | "an archive that unpacks to nothing is refused" |
| M8 the old tree removed before the new one unpacks | "without xz the run fails, and the tree from before stays", "an archive that unpacks to nothing is refused" |

Two first drafts of M3 were equivalent, not survivors: dropping the name
test from the URL line alone, or from the sha256 line alone, changes
nothing, because each `(name …)` line resets the URL and the URL is only set
inside the wanted project.

### check-akku

| Mutant | Failure |
|---|---|
| none | `19 libraries installed, exactly src/` |
| `.akkuignore` removed | the nine `site/*.sls` listed as extra |

Porting it found two things. chez-cmark-gfm's script names `--no-recursion`
after `-T`, where GNU tar ignores it (and says so, but the pipe hides tar's
failure), so the chez-srfi submodule's 1,121 libraries were copied into the
package. Here it comes first. And Akku installs a one-part library name,
`(libuv)`, twice: as `libuv.sls` and as `libuv/main.sls`. The check accepts
the second only as a byte-for-byte copy of the first.

### The site and the reference

Each in a fresh copy of the worktree outside the repo (`$SCRATCH/msite`),
the copy as the container's root, `make check-site`:

| Mutant | Failure |
|---|---|
| none | both green: 11 modules, 128 bindings; all five site checks |
| S1 a same-page anchor in loops.md misspelt | `anchor resolution FAILED. danglers=((loops.md . #let-call-with-uv-loop-do-that))` |
| S2 docs/signals.md deleted | `nav completeness FAILED. … extra-in-site/pages.sls=(signals.md)` |
| S3 `(site links)` keeps `.md` | `a relative .md link leaked into README.md: (installing.md …)` |
| S4 `(site io)` writes the home page as README.html | `a link names a file the site does not write, in README.md: (index.html)` |
| S5 the `uv-run` entry heading lost its kind | `missing-bindings=(uv-run)`, `malformed-entry-headings=("### uv-run")` |
| S6 `(libuv timer)` dropped from `uv-timer-repeat`'s Available line | `module-membership-mismatches=((uv-timer-repeat ((libuv) (libuv timer)) ((libuv))))` |
| S7 `(site links)` stops mapping README.md to index.html | nothing: all green |

S4 passed checks 1 to 4 before check 5 existed: that is why it was added.

After the code review, the same way:

| Mutant | Failure |
|---|---|
| none | all seven checks green |
| R1 the link scan reads text too (the copied scan) | `the link scan reads text as links: (x.md y.md)` |
| R2 building.md links `../CONTRIBUTNG.md` | `a link out to the repository names no file in it, in building.md: (…/blob/main/CONTRIBUTNG.md)` |
| R3 README.md links `../../docs` | `… names no file in it, in README.md: (…/blob/main/../docs)` |
| R4 a heading `Stop — then close` | `a heading's anchor differs on GitHub, in timers.md: … site stop-then-close, GitHub stop--then-close` |
| R5 R4, with the comparison made against the site's own slug | nothing: shows the GitHub slug is what catches R4 |

### The generator's own suites

`tests/site-unit.sps` (53 assertions) and `tests/site-render-unit.sps` (16),
ported from chez-cmark-gfm's site suites and adapted (README.md as
index.html, the wordmark, the blob base, `./` links), run first in
`check-site`. Each mutation, in a copy outside the repo, failed only the
assertions named:

| Mutation | Failing assertions |
|---|---|
| escape-attr's `&quot;` | "escape-attr turns a double quote into &quot;" (rerun here: 52 passes, that 1 failure) |
| the slugger's `-N` suffix dropped | "duplicate headings get -1, -2 suffixes", and three that depend on it |
| no warning-callout rewrap; or U+26A0 changed | "a warning-sign blockquote is rewrapped …", "a warning blockquote is rendered inside a callout div" |
| README no longer mapped to index in links | four unit and two render assertions on README links |
| page-file-name's README case | "README.md is written as index.html" |
| the wordmark | "the wordmark names chez-libuv …" (both suites) |
| the nav/footer README case | "a README.md nav entry links index.html", "the footer nav links the previous and next pages" |
| strip-dot-slash removed | "a link to ./README.md …", "a ./page.md link has its ./ stripped" |
| the blob base | "a ../ escape is pinned to the GitHub blob at the ref" |
| the dangler test always true | "a bare .md link to a page absent from the registry is a dangler" |
| text newlines re-indented | "indentation inside pre/code is content, preserved byte-for-byte" |
| the rail takes h3 | "the rail does not link the h1 anchor", "the rail lists h2 sections, not h3 details" |
| README.md left in the nav | three home-page assertions |

Not mutated: the theme script's no-entities assertion.

### check-pins

Akku.lock now holds two projects, and chez-cmark-gfm sorts first. The old
lookup took the first `akku.N.<hex>_repack` URL in the file: with
chez-cmark-gfm relocked to a snapshot version (`…_0.0.0-akku.3.abc1234_repack`)
it read `abc1234`. The lookup now reads only chez-srfi's project, and gives
`7879b52` on both locks.

### check-akku's copy

A tracked file missing from the working tree (`tests/uv-race.sls` moved
away for the run) now stops the check: `could not archive the tracked
files`. Before, the copy was a pipeline, and only its last command's
status counted.

### Uncovered

- **S7, a link to README.md.** No page links to `README.md` today; the
  wordmark's `index.html` comes from the template. The first page that does
  is held by check 5: its link would name `README.html`, a file the site
  does not write. The site agent watched the mapping work on a stub tree.
- **`akku install`'s `.akku/lib`.** `make site-deps` uses it when present.
  No machine here has run `akku install`, so that branch has not run.
- **The Pages workflow.** Not run: Actions has no minutes left this month.
  `make -n site check-site CHEZ=chezscheme` reads cleanly with a bare PATH.
  Ubuntu's chezscheme (9.5.8) has not run the generator here.
- **The reference's content.** See check-reference above. The review
  found wrong Raises lines and entries the check cannot see; they were fixed
  by hand. A check that compares each entry's kind and arity with its
  `define` would close most of it.
- **The examples in the pages.** Every writer ran every example and
  checked each shown output; a later run of a sample matched. Nothing holds
  them to the source from now on (chez-cmark-gfm's `examples/` gate would).

## Gates

- `make check-site-deps`, `check-akku`, `check-reference`, `check-site`, `check-history`
  (126 files, now with `site/` and `build-site.sps`), `check-help`,
  `check-pins`: pass.
- `make test`: all 37 suites pass.
- `make site`: 15 pages written to `build/site/`.
