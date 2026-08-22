# chez-libuv public-release docs — design

- **Status:** Accepted
- **Date:** 2026-08-22
- **Scope:** Documentation, community files, and one `check-pins` stanza. No
  source, test, CI, or build/install behavior changes.
- **Branch:** `docs/public-release-prep`

## Goal

Prepare the repository for going public: remove tool-workspace files that
landed in `docs/`, rewrite `README.org` as a crisp open-source front page,
split the deep material into user-facing Markdown files under `docs/`, add
the standard community files, and fix the version drift in `Akku.manifest`
so it cannot recur.

## Decisions taken during brainstorming

These were resolved interactively and are settled inputs to this design:

1. **Akku story: document reality, publish later.** The Akku index
   (akkuscm.org) publication is a separate, later milestone. Install docs
   describe what works today: `(libuv private native)` imports the generated,
   gitignored `src/libuv/private/config.sls`, so *every* consumer — Akku or
   not — needs a checkout that has run `make build`. Akku users are served
   honestly: Akku manages the Scheme-level dependency; the native shim comes
   from `make build` in a clone. No loader or distribution changes in this
   pass. **Tripwire for the publication milestone:** verify what
   `akku publish` actually packs — if submodule contents ride along, the
   package redistributes libuv/chez-srfi source and must include their
   license texts; likewise any future release tarball or prebuilt-shim
   artifact that bundles libuv.
2. **CONTRIBUTING rigor: gates hard, process soft.** The file requires what
   CI enforces (green `make test` / `check-pins` / `check-purity`,
   Conventional Commits, tests accompany code) and presents the deeper house
   discipline (AGENTS.md, `.plans/` designs, ADRs, watched-to-fail evidence)
   as how the repo is developed — encouraged for feature work, not demanded
   of drive-by fixes.
3. **Community files:** `CONTRIBUTING.md`, `SECURITY.md`, and
   `.github` issue/PR templates. No CODE_OF_CONDUCT.md in this pass.
4. **Security channel:** GitHub private vulnerability reporting (Security
   Advisories). No email address is published. Owner action after the repo
   flips public: enable *Private vulnerability reporting* in repo settings.
5. **Docs shape: thin README, `docs/` carries depth.** One home per fact.
   The README keeps a ~15-line runnable taste; the full quickstart, API
   tables, and build-system deep dive move to `docs/`.

## 1. Repo hygiene

- `git mv docs/superpowers/plans/2026-08-21-chez-libuv-v0.3-process.md
  .plans/2026-08-21-chez-libuv-v0.3-process-plan.md`
- `git mv docs/superpowers/plans/2026-08-22-chez-libuv-v0.4-signal.md
  .plans/2026-08-22-chez-libuv-v0.4-signal-plan.md`
- Delete `docs/superpowers/` (empty after the moves) and `docs/.gitkeep`
  (obsolete once real docs land).
- Verified before design: nothing in the tree references the
  `docs/superpowers` paths, so the moves break no links. The `-plan.md`
  names sit beside their `-design.md` specs, preserving the
  design → plan → mutation-log evidence trail.
- This also restores AGENTS.md's own rule: plans live in `/.plans`;
  `/docs` is user-facing documentation only.

## 2. README.org — thin front page (~120 lines, org format)

Section order:

1. Title + one-line description ("Thin R6RS bindings to libuv asynchronous
   I/O for Chez Scheme").
2. The AI-disclosure quote block, kept verbatim.
3. CI badge for `.github/workflows/ci.yml` (org-mode link to the workflow
   badge SVG on the `Kiyomi-Computation-Systems/chez-libuv` repo).
4. **What it is** — two tight paragraphs: (a) a legible, low-level mirror of
   libuv's own verb set (accept, read-start, write, shutdown, timer,
   getaddrinfo, spawn, close…) covering the loop, TCP, timers, DNS, child
   processes + pipes, and signal watching; (b) transport only — parses
   nothing, no protocol, no connection-state or backpressure policy, so
   higher layers build on primitives rather than an invented abstraction.
   Links to the design specs and ADR directory in `.plans/`.
5. **Status** — v0.4.0 scope in one paragraph (what is in; no filesystem,
   no UDP, no zero-copy with ADR-0009 link). CI on macOS + Linux, both
   acquisition paths. Windows deferred, not designed out (ADR-0004 link).
6. **Install** —
   - *Prerequisites:* Chez Scheme 10.4.1+ (binary `chez`); libuv — and the
     sentence must contain the exact string `libuv 1.44.0`, which
     `check-pins` greps this file for. State: satisfied by a system package
     `pkg-config` can see, or by the vendored submodule automatically.
   - *With Akku:* Akku manages the Scheme-level dependency (this package
     depends on `chez-srfi` only for its test suites; `(libuv)` itself needs
     no Scheme deps). Until the package is on the Akku index (planned),
     consume it as a git checkout: clone, `make build`, and put `src` on
     `CHEZSCHEMELIBDIRS`. Plainly state why: `config.sls` is generated
     per-machine, so no source-only distribution can work without a build
     step. (If Akku's git-URL dependency mechanism is verified to work here
     during implementation, mention it; otherwise omit — no unverified
     claims in install docs.)
   - *Without Akku:* clone → `make build` → run with
     `CHEZSCHEMELIBDIRS=src chez --program your-script.sps`;
     `make dev` for a REPL; `make help` lists everything.
7. **A taste** — a complete, runnable ~15-line timer example (make a loop,
   arm a repeating timer, stop after N fires, `uv-run`,
   `uv-loop-teardown!`), so the reader sees the API texture without
   scrolling. Points at `docs/quickstart.md` for the real walkthrough.
8. **Documentation** — link table: `docs/quickstart.md`, `docs/api.md`,
   `docs/building.md`, `CHANGELOG.md`, design specs & ADRs under `.plans/`.
9. **Contributing** — two sentences pointing at `CONTRIBUTING.md` and
   `SECURITY.md`.
10. License + the existing copyright footer, unchanged — plus a short
    *Third-party software* paragraph: dependencies arrive as git submodules
    under their own licenses — libuv (MIT; `vendor/libuv/LICENSE` and
    `LICENSE-extra`) and chez-srfi (permissive; `vendor/chez-srfi/LICENSE`,
    test suites only); nothing third-party is copied into this tree (no
    NOTICE file is needed — that is an Apache-2.0 mechanism, and this repo
    redistributes no third-party source); anyone redistributing binaries or
    archives that bundle libuv must carry libuv's license texts.

Everything else currently in the README moves to `docs/` (below) — nothing
is deleted from the corpus, only relocated and tightened.

## 3. docs/ — three Markdown files, one home per fact

- **`docs/quickstart.md`** — the echo server walkthrough moved from the
  README (server + client on one loop, span convention comment,
  `uv-run`/`uv-loop-teardown!`), pointer to `tests/test-echo.sps` as the
  assertive big sibling, then the three rules stated in full: a close is
  asynchronous (ADR-0007); EOF is not an error; a callback that raises does
  not cross into C (`&uv-callback-error`, `uv-loop-deferred-errors`). Ends
  with "where to go next" (api.md, building.md, design specs).
- **`docs/api.md`** — the complete per-module export tables from today's
  README (loop, handle, tcp, stream, pipe, process, signal, dns, timer,
  versions, conditions), converted org → Markdown, each with its
  behavioral notes kept adjacent: the tcp→stream re-export note, the
  process module's six behaviors + root lane + coexistence measurement,
  the signal mode-ratchet and SIGINT caveat, DNS's five behaviors, the
  conditions table with the ADR-0006 rationale. ADR links point into
  `.plans/decisions/`.
- **`docs/building.md`** — the build-system deep dive: what `make build`
  generates and why a fresh clone must run it; the two acquisition paths
  (`pkg-config` vs vendored submodule, `HAVE_PKG=no` to force, CI parity);
  `make deps-info`; `CHEZ_LIBUV_SHIM` (validated, never searched — the
  three-bullet contract); release builds (`make prod`, flavor stamps,
  `relink-guard`, `check-prod` — condensed to what a packager needs, with
  a pointer to the Makefile's own comments for the archaeology); and the
  test-target catalog: `test`, `check-purity`, `check-pins`,
  `test-memory` (Linux Valgrind is the sole leak gate, ADR-0003),
  `test-root` (sudo lane; run `make build deps` unprivileged first).

Style for all three: crisp, imperative, information-first — same voice as
the new README. GitHub-flavored Markdown, fenced code blocks with language
tags, relative links.

## 4. Community files

- **`CONTRIBUTING.md`** — sections:
  1. *Setup* — prerequisites and the clone → `make build` → `make test`
     loop; `make help`.
  2. *The gates* — what a PR must keep green, verbatim targets:
     `make test`, `make check-pins`, `make check-purity`; `make test-memory`
     runs in CI (Linux leg carries the leak claim); tests accompany code
     changes; new suites end with `(exit …)` (SRFI-64 does not set exit
     status).
  3. *Conventions* — Conventional Commits; branch names
     `feat/…` `fix/…` `docs/…` `refactor/…`; PRs squash-merge.
  4. *How this repo is developed* — house style, encouraged not demanded:
     designs in `.plans/*-design.md`, ADRs in `.plans/decisions/`,
     AGENTS.md's testing discipline (a test is finished when you have
     watched it fail; mutation logs). Feature-sized contributions should
     start with an issue/design conversation; drive-by fixes need only the
     gates.
  5. *Security* — one line pointing at SECURITY.md.
- **`SECURITY.md`** — supported versions (latest 0.4.x); report privately
  via GitHub's *Report a vulnerability* on this repo; please do not open
  public issues for suspected vulnerabilities; acknowledgement within
  7 days.
- **`.github/ISSUE_TEMPLATE/bug_report.md`** — asks for: OS + arch, Chez
  version (`chez --version`), libuv provenance + version (`make deps-info`
  output and `(uv-version)`), what happened vs expected, minimal repro
  (ideally a `.sps` snippet), and whether `make test` passes locally.
- **`.github/ISSUE_TEMPLATE/feature_request.md`** — problem statement,
  proposed API surface (which module it belongs to), whether it mirrors an
  existing libuv verb (this binding is a legible mirror — features that
  invent vocabulary need a design conversation first).
- **`.github/PULL_REQUEST_TEMPLATE.md`** — checklist: `make test` green
  locally; Conventional Commit title; tests accompany code changes;
  docs (`README.org` / `docs/`) updated if the public API changed;
  CHANGELOG entry if user-visible.

## 5. Metadata + the one Makefile change

- **`Akku.manifest`:** version `0.2.0` → `0.4.0` (drift; CHANGELOG and the
  code are at 0.4.0).
- **`check-pins` gains one stanza:** the `akku-package` version in
  `Akku.manifest` must equal the topmost `## X.Y.Z` heading in
  `CHANGELOG.md`. Extraction: `sed`/`awk` over the two files, same shape as
  the existing srfi-pin and README-floor stanzas; failure message names both
  values and both files. Rationale: check-beats-comment — this exact drift
  (manifest at 0.2.0 through two releases) is sitting in the tree today and
  nothing noticed. No other Makefile changes; the install story was decided
  as documentation-only.
- The existing `check-pins` README-floor grep keeps passing because the new
  README states the floor with the exact `libuv 1.44.0` string (§2.6).

## 6. Explicitly unchanged

Source under `src/`, tests, `ci.yml`, CHANGELOG content (this is a docs
pass, not a release — no new heading), `.plans/` content beyond the two
moved plan files and this design, LICENSE, and the copyright footer.

## 7. Process

- Branch `docs/public-release-prep` (created). Conventional Commits;
  logical commit sequence: (1) `docs:` move superpowers plans into
  `.plans/`; (2) `docs:` README rewrite + `docs/` split; (3) `docs:`
  community files; (4) `chore:` manifest bump + `check-pins` stanza
  (+ this design doc with whichever commit touches it first).
- `make test` (which includes `check-pins`) before every commit —
  load-bearing here, since both the README grep and the new manifest stanza
  gate on files this pass edits. `make check-help` after the Makefile edit.
- PR at the end; squash-merge per the closing ritual.

## Acceptance criteria

1. `docs/` contains only user-facing Markdown (`quickstart.md`, `api.md`,
   `building.md`); `docs/superpowers/` and `docs/.gitkeep` are gone; the two
   plans live in `.plans/` under `-plan.md` names.
2. `README.org` is ≤ ~130 lines, states the `libuv 1.44.0` floor, shows a
   runnable example, covers both install audiences, and links every
   `docs/` file.
3. Every fact currently in README survives somewhere (README or `docs/`) —
   relocation, not deletion.
4. `CONTRIBUTING.md`, `SECURITY.md`, and the three `.github` templates
   exist with the content above.
5. `Akku.manifest` says `0.4.0` and `make check-pins` fails if manifest and
   CHANGELOG versions ever disagree (to be watched-to-fail during
   implementation by temporarily reverting the manifest bump).
6. `make test` green on the branch.
