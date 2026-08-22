# chez-libuv Public-Release Docs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute the accepted spec `.plans/2026-08-22-chez-libuv-public-release-docs-design.md` — relocate the stray superpowers plans, rewrite `README.org` as a thin front page, split depth into `docs/{quickstart,api,building}.md`, add community files, and close the manifest-version drift with a `check-pins` stanza.

**Architecture:** Pure documentation + one Makefile stanza. Every file's full content is IN this plan — tasks are transcription + verification, never invention. Commit order is chosen so the tree is link-complete at every commit: docs/ content lands before the README that links to it, community files land before the README's Contributing section, and the `check-pins` stanza lands RED against the live 0.2.0 drift before the manifest bump turns it GREEN.

**Tech Stack:** Org-mode (README only), GitHub-flavored Markdown (everything else), GNU make 3.81-compatible shell stanzas, git.

## Global Constraints

Every task's requirements implicitly include all of these.

- **Repo:** `/Users/yuzu/github/chez-libuv`, branch `docs/public-release-prep` (exists). Conventional Commits with trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **`make test` before every commit** (it runs build + deps + check-pins + all suites; expect final line `ALL SUITES PASSED`). After any Makefile edit, also `make check-help` (expect exit 0, no output).
- **`README.org` must contain the exact string `libuv 1.44.0`** — `check-pins` greps for it (Makefile:221). Never paraphrase that floor.
- **README.org ≤ ~130 lines** (spec acceptance #2).
- **Relocation, not deletion:** every fact in the pre-rewrite README survives in the new README or a `docs/` file (spec acceptance #3). The old README is retrievable at any time via `git show main:README.org`.
- **No unverified claims in install docs:** the Akku git-URL dependency mechanism is NOT mentioned (spec §2.6 as amended); the documented Akku story is "manages Scheme-level deps; consume this repo as a git checkout until index publication".
- **Link discipline:** relative links only; ADR links point into `.plans/decisions/`; from `docs/*.md` that prefix is `../.plans/`.
- **`docs/` is user-facing only** (AGENTS.md) — no plans, no specs land there.
- **This is not a release:** no new CHANGELOG heading, no tag.

## Commit sequence

Seven commits, refining the spec §7's four-commit sketch so the README always lands after everything it links to (same order-spirit; the spec's grouping said "logical", not "exactly four"). One acknowledged transient: quickstart.md (commit 2) forward-links api.md/building.md until commits 3–4 land.

1. `docs:` move superpowers plans into `.plans/`
2. `docs:` add docs/quickstart.md (drops `.gitkeep`)
3. `docs:` add docs/api.md
4. `docs:` add docs/building.md
5. `docs:` add CONTRIBUTING.md, SECURITY.md, .github templates
6. `docs:` rewrite README.org as a thin front page
7. `chore:` check-pins version stanza + Akku.manifest 0.4.0

---

### Task 1: Relocate the superpowers plans

**Files:**
- Move: `docs/superpowers/plans/2026-08-21-chez-libuv-v0.3-process.md` → `.plans/2026-08-21-chez-libuv-v0.3-process-plan.md`
- Move: `docs/superpowers/plans/2026-08-22-chez-libuv-v0.4-signal.md` → `.plans/2026-08-22-chez-libuv-v0.4-signal-plan.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `.plans/` is the single home for plans; `docs/` holds only `.gitkeep` until Task 2.

- [ ] **Step 1: Move both files with git mv**

```bash
git mv docs/superpowers/plans/2026-08-21-chez-libuv-v0.3-process.md .plans/2026-08-21-chez-libuv-v0.3-process-plan.md
git mv docs/superpowers/plans/2026-08-22-chez-libuv-v0.4-signal.md .plans/2026-08-22-chez-libuv-v0.4-signal-plan.md
```

- [ ] **Step 2: Verify the superpowers directory is gone and nothing references the old paths**

```bash
ls docs/            # expect: .gitkeep only (git mv removed the emptied dirs)
rg -l "docs/superpowers" --hidden -g '!.git' .   # expect: no output
```

If `docs/superpowers` still exists (empty dirs from a partial mv), `rmdir docs/superpowers/plans docs/superpowers`.

- [ ] **Step 3: Run the suite**

Run: `make test` — Expected: `ALL SUITES PASSED`.

- [ ] **Step 4: Commit**

```bash
git add -A docs .plans
git commit -m "docs: move superpowers plans into .plans/ beside their designs

/docs is user-facing documentation only (AGENTS.md); the v0.3 and v0.4
implementation plans now sit beside their design specs under -plan.md
names, preserving the design -> plan -> mutation-log trail.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: docs/quickstart.md

**Files:**
- Create: `docs/quickstart.md`
- Delete: `docs/.gitkeep`

**Interfaces:**
- Consumes: nothing.
- Produces: `docs/quickstart.md` — linked by Task 4 (building.md "where next" is not needed; api.md links it), Task 6 (README §A taste and §Documentation).

- [ ] **Step 1: Write `docs/quickstart.md` with exactly this content**

The echo program is copied verbatim from the pre-rewrite README (`git show main:README.org`, the `#+begin_src scheme` block in *Quickstart*) — it is known-good, being `tests/test-echo.sps` in miniature.

````markdown
# Quickstart

An echo server and one client, on one loop, in one process — the whole
public API surface in miniature. [`tests/test-echo.sps`](../tests/test-echo.sps)
is this program with eight concurrent clients, 32 KiB payloads and
assertions.

## Before you start

Build the native shim once (full story in [Building & testing](building.md)):

```sh
make build
```

Then run any program in this guide with `src` on Chez's library path:

```sh
CHEZSCHEMELIBDIRS=src chez --program echo.sps
```

## The program

```scheme
(import (rnrs) (libuv))

;; A span is [start, end), like every other R6RS range. on-data is handed a
;; FRESH bytevector per delivery (ADR-0009), so this copy is only about
;; taking the sub-range.
(define (span->bytevector bv start end)
  (let ((out (make-bytevector (- end start))))
    (bytevector-copy! bv start out 0 (- end start))
    out))

(define loop (make-uv-loop))
(define echoed #f)

;; --- the server: echo the exact span back, close when the peer is done ---
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(define port (uv-tcp-getsockname-port server))

(uv-listen! server 128
            (lambda (err)
              (unless err
                (let ((peer (uv-accept! server)))
                  (uv-read-start!
                   peer
                   (lambda (bv start end)              ; on-data
                     (uv-write! peer bv start end (lambda (err) #f)))
                   (lambda ()                          ; on-eof: not an error
                     (uv-shutdown! peer (lambda (err) (uv-close! peer))))
                   (lambda (err)                       ; on-error: a condition
                     (uv-close! peer)))))))

;; --- one client, on the SAME loop ---------------------------------------
(define client (make-uv-tcp loop))

(uv-tcp-connect!
 client "127.0.0.1" port
 (lambda (err)
   (unless err
     (uv-read-start!
      client
      (lambda (bv start end)
        (set! echoed (utf8->string (span->bytevector bv start end)))
        (uv-shutdown! client (lambda (err) (uv-close! client)))
        (uv-close! server))
      (lambda () #f)
      (lambda (err) (uv-close! client)))
     (uv-write! client (string->utf8 "hello, libuv\n") (lambda (err) #f)))))

;; Callbacks run here and nowhere else. uv-run answers #f when the loop has
;; run dry; uv-loop-teardown! closes whatever is left, drains it, and closes
;; the loop (there are no guardians -- ADR-0007).
(uv-run loop 'default)
(uv-loop-teardown! loop)

(display echoed)
```

## The three rules

That program depends on three rules, stated in full in the design spec
(§5–§9 of [the v0.1 design](../.plans/2026-08-18-chez-libuv-v0.1-design.md)):

- **A close is asynchronous.** `uv-close!` *starts* the close; the handle is
  `closing` until the loop runs its close callback, which is the only place
  a handle's memory is ever released. Nothing is freed by the garbage
  collector ([ADR-0007](../.plans/decisions/0007-no-guardians-explicit-close.md)).
- **EOF is not an error.** It is its own callback, taking no arguments, and
  it is never wrapped in a condition. A read *error* is delivered to
  `on-error` as a condition *object* — never raised across the callback
  boundary — and does not close the handle: what to do about it is the
  caller's decision.
- **A callback that raises does not cross into C.** The first raise of a run
  is stored, the loop is stopped, and it is re-raised from `uv-run` wrapped
  in `&uv-callback-error` and composed with the original condition, so a
  `guard` written against the original type still matches. Later raises in
  the same run are readable through `uv-loop-deferred-errors`.

## Where next

- [API reference](api.md) — every export of every module, one line each
- [Building & testing](building.md) — acquisition paths, `CHEZ_LIBUV_SHIM`,
  release builds, the test gates
- [Design specs & ADRs](../.plans/) — why it is built this way, with the
  evidence
````

- [ ] **Step 2: Remove the placeholder and verify links resolve to real files**

```bash
git rm docs/.gitkeep
for f in tests/test-echo.sps .plans/2026-08-18-chez-libuv-v0.1-design.md .plans/decisions/0007-no-guardians-explicit-close.md; do test -f "$f" && echo "ok $f"; done
```

Expected: three `ok` lines. (`docs/api.md` / `docs/building.md` arrive in Tasks 3–4; that forward reference is why Tasks 2–4 land before the README.)

- [ ] **Step 3: Run the suite**

Run: `make test` — Expected: `ALL SUITES PASSED`.

- [ ] **Step 4: Commit**

```bash
git add docs/quickstart.md
git commit -m "docs: add docs/quickstart.md — echo walkthrough and the three rules

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: docs/api.md

**Files:**
- Create: `docs/api.md`

**Interfaces:**
- Consumes: nothing (content converted from the pre-rewrite README, `git show main:README.org`).
- Produces: `docs/api.md` — linked by quickstart.md (already, forward ref) and Task 6's README.

- [ ] **Step 1: Write `docs/api.md` with exactly this content**

Conversion rules applied from the org original: `~x~` → `` `x` ``, org tables → GFM tables, `[[file:.plans/…][ADR-n]]` → `[ADR-n](../.plans/…)`, `\vert{}` → `\|` between code spans. The timer-start signature note is new — verified against `src/libuv/timer.sls` (callback second, receives the timer record).

````markdown
# API reference

One line per export. Argument lists, span conventions, error behaviour and
the lifecycle state machine are in the design specs under
[`.plans/`](../.plans/) (v0.1 §5–§9 and the per-milestone specs); these
tables exist so you can see the whole surface at once, not to restate it.

Importing the umbrella library `(libuv)` gives you everything below — it is
a facade that re-exports every public binding by name. The per-module
libraries exist for narrower imports.

## The loop — `(libuv loop)`

| Export | |
|---|---|
| `make-uv-loop` | A new loop. Initialises the binding, including the version gate |
| `uv-loop?` `uv-loop-open?` | Is this a loop; is it still open |
| `uv-run` | Run it: `'default`, `'once`, or `'nowait`. `#t` if work remains |
| `uv-stop!` | Stop the loop; legal from inside a callback |
| `uv-loop-alive?` | Whether the loop has anything left to do |
| `uv-now` | libuv's cached "now", in ms, updated once per iteration |
| `uv-loop-live-handles` | Fresh list of the handle records registered on this loop |
| `uv-loop-deferred-errors` | Everything callbacks raised this run *after* the first |
| `uv-loop-close!` | Close the loop. `'EBUSY` while handles are still open |
| `uv-loop-teardown!` | Close every handle, drain, then close the loop |
| `call-with-uv-loop` | The above as a scope; tears down on every exit path |

## Handles — `(libuv handle)`

| Export | |
|---|---|
| `uv-handle?` `uv-timer?` `uv-tcp?` `uv-pipe?` `uv-process?` `uv-signal?` | Type predicates |
| `uv-handle-open?` `uv-handle-closing?` | State predicates. Never raise, on anything |
| `uv-handle-state` | `'open` \| `'closing` \| `'closed`. There is no `uv-handle-closed?` — that name is the condition predicate |
| `uv-handle-loop` | The owning loop; answers for a closed handle too |
| `uv-close!` | Start the close, optionally with an `on-close` callback. Idempotent |

## TCP — `(libuv tcp)`

| Export | |
|---|---|
| `make-uv-tcp` | A new TCP handle on a loop |
| `uv-tcp-bind!` | Bind to an address and port; IPv4 or IPv6 literal |
| `uv-tcp-getsockname-port` | The real port the kernel chose, for a bind to port 0 |
| `uv-listen!` | Listen; `on-connection` is called with the error or `#f` |
| `uv-accept!` | A new open handle for the queued connection |
| `uv-tcp-connect!` | Connect; answers the in-flight request record |
| `uv-tcp-nodelay!` | `TCP_NODELAY`. Takes a boolean, not an int |

`uv-write!`, `uv-shutdown!`, `uv-read-start!` and `uv-read-stop!` moved to
`(libuv stream)` in v0.3 (below); `(libuv tcp)` re-exports all four
unchanged, so existing importers compile without touching an import line.

## Streams — `(libuv stream)`

Extracted from `(libuv tcp)` in v0.3 (design spec §4.6) so the gating
predicate is stream-*kind*, not tcp-kind: these four verbs accept any open
tcp or pipe handle.

| Export | |
|---|---|
| `uv-write!` | Write a bytevector or a span of one. The payload is copied |
| `uv-shutdown!` | Shut the write side down; the read side stays open |
| `uv-read-start!` | Start reading: `on-data` `(bv start end)`, `on-eof` `()`, `on-error` `(condition)`. All three required |
| `uv-read-stop!` | Stop reading — backpressure. Idempotent; the buffer and callbacks are kept for the next start |

## Pipes — `(libuv pipe)`

Deliberately minimal (design spec §1): no `bind`/`connect`/`listen`, no
`ipc=1` fd-passing. A fresh pipe's only purpose is to be named in
`uv-spawn!`'s `stdio` options as a child's stdio end, or closed.

| Export | |
|---|---|
| `make-uv-pipe` | A new, unconnected pipe handle on a loop (`uv_pipe_init`, ipc always 0) |
| `uv-pipe?` | Type predicate (defined in `(libuv handle)`) |

## Child processes — `(libuv process)`

| Export | |
|---|---|
| `uv-spawn!` | `(loop file args [options] on-exit)` → process handle, child already running |
| `uv-process-kill!` | Send a signal to the process by handle — `uv_process_kill` |
| `uv-kill!` | Send a signal by raw pid — `uv_kill` |
| `uv-process-pid` | The pid; valid from spawn through close, including after exit |
| `uv-os-getpid` | This process's own pid |
| `uv-process?` | Type predicate (defined in `(libuv handle)`) |

`file`/`args` are libuv's own execvp/argv contract — unresolved and
unvalidated by the binding. The `options` alist covers `env` (a list of
`"K=V"` strings, libuv's own format, not an alist encoding), `cwd`,
`stdio`, `detached`, and `uid`/`gid`. Six behaviours worth knowing before
the design spec (§4–§6):

- **The spawn surface.** Each child fd (index = slot; 0/1/2 are
  stdin/stdout/stderr, libuv pads short lists to three `ignore`s) is one
  of: `ignore` (`/dev/null` for slots 0–2), `(inherit-fd . n)` (a dup of
  parent fd *n*), `(inherit-stream . h)` (a dup of an open tcp or pipe
  handle's fd), or `(pipe p dir)` — `uv-spawn!` creates the pipe pair and
  connects the parent end into *p*, a fresh handle from `make-uv-pipe`.
  *dir* is `to-child`, `from-child`, or `duplex` — named from the
  *parent's* perspective, deliberately not libuv's child-perspective
  `READABLE`/`WRITABLE` flag names, which are libuv's single most
  direction-confusing vocabulary.
- **Exit ≠ close.** `on-exit` firing stops the handle but does not close
  it; the caller still calls `uv-close!` — typically from inside
  `on-exit` — before the handle's memory is reclaimed. Exactly the tcp
  discipline (ADR-0007), applied to a handle instead of a stream.
- **Killed-by-signal is `(0 sigterm)`, not `(-1 …)`.** `on-exit` receives
  `(exit-status term-signal)` as results, never a condition — there is no
  error argument. `exit-status` is libuv's `WEXITSTATUS` on a normal exit
  and *zero* on a signal death; `term-signal` is `#f` on a normal exit and
  otherwise the signal symbol (or the raw integer, for a signal outside
  the bound set — information is never dropped).
- **Pid validity ends at the exit callback.** The child is reaped by the
  time `on-exit` runs, so a kill or liveness probe (`uv-process-kill!` /
  `uv-kill!` with signal `0`) issued after exit races pid reuse — it will
  usually raise `'ESRCH`, but the binding cannot promise a recycled pid
  won't be signalled instead.
- **The detached pattern.** `detached` maps to `UV_PROCESS_DETACHED`; the
  documented pattern is spawn, then `uv-close!` immediately — the child
  survives the parent and is never reaped by us.
- **A failed `uv-spawn!` cleans up internally; only its pipes need the
  caller's attention.** libuv's spawn-failure path has two different
  correct cleanups depending on how far the child got before failing
  ([ADR-0015](../.plans/decisions/0015-spawn-copy-lifetime-and-failure-path.md));
  the binding picks the right one at runtime, and the caller only ever
  sees the raise. Any pipe named in any of the spawn's stdio specs is
  marked *connected* by the binding even when the spawn raised — libuv
  opens the parent end before it can know whether the exec will succeed —
  so a raising `uv-spawn!` still leaves its pipes needing an explicit
  `uv-close!`; naming an already-consumed pipe again raises
  `'pipe-already-used`.

**Root lane.** Exercising `uid`/`gid` (which map to
`UV_PROCESS_SETUID`/`SETGID`) needs to actually run as root, so that
coverage is opt-in and kept out of the default suite: `sudo make test-root`
runs `tests/test-process-setuid.sps` alone — excluded from `make test` and
`make test-memory`, and refusing with a clear message under a non-root
euid. CI runs it as its own step on both platforms.

**Coexistence with Chez's own subprocess APIs.** Measured, not assumed:
interleaving libuv spawns with Chez's `system`/`open-process-ports` across
four orderings showed no conflict — 110/110 libuv `exit_cb`s delivered
intact and every Chez call returned its own correct result — measured on
Linux's SIGCHLD-based child-reaping path, the one path where a stolen wait
can silently drop a callback (`spike/process/FINDINGS.md` SQ2).

## Signals — `(libuv signal)`

Completes the pair the process module's `uv-kill!` started
([ADR-0017](../.plans/decisions/0017-signal-watching-vocabulary-and-mode.md)).

| Export | |
|---|---|
| `make-uv-signal` | A new signal watcher on a loop |
| `uv-signal-start!` | Watch continuously: `(watcher signal-symbol on-signal)`; the callback receives the signal as a symbol |
| `uv-signal-start-oneshot!` | Watch for exactly one delivery, then auto-disarm |
| `uv-signal-stop!` | Disarm the watcher |
| `uv-signal?` | Type predicate (defined in `(libuv handle)`) |

The watchable set is the closed vocabulary minus `sigkill`/`sigstop`
(`'signal-unwatchable` — the kernel forbids catching them); exact `0` stays
sending-only. A watcher's *mode* is fixed by its first start verb, and the
other verb thereafter raises `'signal-mode-fixed`; changing mode is
`uv-close!` + `make-uv-signal` (the vendored `UV_SIGNAL_ONE_SHOT` flag is a
one-way per-handle ratchet, measured in
[the v0.4 spike](../spike/signal/FINDINGS.md)). Delivery is not close: the
caller always `uv-close!`s the handle.

Graceful shutdown, the driving use case — first `SIGTERM` drains, a second
one kills (the disposition reverts to `SIG_DFL` once the oneshot fires):

```scheme
(define loop (make-uv-loop))
(define watcher (make-uv-signal loop))
(uv-signal-start-oneshot! watcher 'sigterm
  (lambda (sig)
    ;; close the listener, start the drain timer, then:
    (uv-close! watcher)))
(uv-run loop 'default)
```

**Measured caveat** (both platforms,
[FINDINGS](../spike/signal/FINDINGS.md) SQ-S1): watching `sigint` takes
SIGINT away from the Chez runtime — while the watcher is armed, Ctrl-C is
delivered to the loop callback and Chez's keyboard interrupt never fires;
after `uv-signal-stop!` (or oneshot auto-disarm) the disposition is
*SIG_DFL*, not what was there before, so SIGINT then terminates the
process. This applies equally to handlers installed with Chez's
`register-signal-handler`. It is libuv's behavior
(`uv__signal_unregister_handler`), surfaced rather than fixed. Rearming a
oneshot watcher from inside its own callback does not take effect (the
vendor auto-stop runs after the callback returns) — rearm from a later
dispatch.

## DNS — `(libuv dns)`

| Export | |
|---|---|
| `uv-getaddrinfo!` | Resolve: `(loop node service [hints] on-complete)`; `on-complete` gets `(err results)`, `results` a fresh list of `uv-addrinfo` records in resolver order |
| `uv-getnameinfo!` | Reverse: `(loop ip port [flags] on-complete)`; `on-complete` gets `(err host service)`, both strings on success, both `#f` on failure |
| `uv-cancel!` | Best-effort cancel. `#t` only if the work was still queued — the callback still fires, with `'EAI_CANCELED`; `#f` means too late, the real result is (or was) delivered |
| `uv-dns-request?` | Whether this is a request `uv-cancel!` accepts |
| `make-uv-addrinfo` | Public constructor — the record is pure data, and a caller's test double is legitimate |
| `uv-addrinfo?` | Type predicate |
| `uv-addrinfo-family` | `'inet` \| `'inet6`. Other families are skipped during the chain walk, so a success can answer `'()` |
| `uv-addrinfo-socktype` | `'stream` \| `'dgram` \| `'raw`, or the raw int when unmapped |
| `uv-addrinfo-protocol` | `'tcp` \| `'udp`, or the raw int (0 = unspecified) |
| `uv-addrinfo-address` | Presentation string, rendered by libuv's own formatter |
| `uv-addrinfo-port` | Exact integer 0..65535 |
| `uv-addrinfo-canonname` | `#f` except on the first entry under the `canonname` flag |

`hints` is an alist over closed symbol sets — `'((family . inet6)
(socktype . stream) (protocol . tcp) (flags . (canonname numeric-host)))` —
and errors reach the callback as ordinary `&uv-errno-error` conditions whose
`errno` is the `EAI_*` symbol (`'EAI_NONAME`, `'EAI_AGAIN`,
`'EAI_CANCELED`, …); there are no DNS-specific condition types. Five
behaviours worth knowing before the design spec:

- **This is the binding's first threadpool-backed feature.** The resolver
  calls run on libuv's worker threads — pure C; no Scheme ever runs off the
  loop thread — and completions are delivered on the loop thread like every
  other callback. The pool is sized by `UV_THREADPOOL_SIZE`, which libuv
  reads once, at first use.
- **Omitted, `#f` and `'()` hints all mean NULL hints** — the platform's
  own documented default, which typically answers one entry per (address ×
  socktype): `stream`, `dgram`, and on Linux `raw` too.
  `'((socktype . stream))` is the one-liner for one entry per address.
- **IPv6 scope IDs are dropped**
  ([ADR-0012](../.plans/decisions/0012-address-vocabulary.md)): a
  link-local result renders as `"fe80::1"` with its zone silently absent.
- **Teardown cancels, then drains.** `uv-loop-teardown!` best-effort-cancels
  the loop's in-flight DNS requests before its close sweep, and every
  in-flight `on-complete` runs before teardown returns — with
  `'EAI_CANCELED` if the cancel won, with the real result if the work was
  already running. A `getaddrinfo(3)` already running in a worker cannot be
  interrupted, so that drain iteration waits it out, up to the OS
  resolver's own timeout.
- **`uv-loop-close!` delivers a pending callback error** (a v0.2 behaviour
  change, not DNS-specific): after a successful close it re-raises a stored
  pending callback error composed as `&uv-callback-error`, exactly as
  `uv-run`'s exit does — previously a caller who skipped the next `uv-run`
  and went straight to close lost the error silently. The loop is closed
  when the raise escapes; a close refused with `'EBUSY` still delivers
  nothing, and the error stays pending.

## Timers — `(libuv timer)`

| Export | |
|---|---|
| `make-uv-timer` | A new timer on a loop |
| `uv-timer-start!` | Arm it: `(timer on-timeout timeout-ms repeat-ms)`; `on-timeout` receives the timer record itself |
| `uv-timer-stop!` | Disarm it |
| `uv-timer-again!` | Restart a repeating timer |
| `uv-timer-repeat` `uv-timer-set-repeat!` | Read and set the repeat interval |

## Versions — `(libuv)`

| Export | |
|---|---|
| `uv-version` | The running libuv's version *string*, e.g. `"1.52.1"` |
| `uv-version-compatible?` | Whether compile-time and runtime libuv both fall in the supported range |

## Conditions — all re-exported from `(libuv)`

Every condition type comes with its predicate, its constructor and its field
accessors; the constructors are public because a caller's own `on-error` may
want to build or re-raise one
([ADR-0006](../.plans/decisions/0006-error-codes-are-symbols.md) is why the
discriminant is a symbol).

| Condition | Fields | Raised when |
|---|---|---|
| `&uv-error` | — | The root; everything below derives from it |
| `&uv-errno-error` | `errno` `code` `message` | libuv returned a negative code. `errno` is the portable symbol (`'ECONNRESET`) and the thing to branch on; `code` is the raw platform int, for logs |
| `&uv-handle-closed` | `kind` | An operation on a handle or loop that is already closed |
| `&uv-shim-unavailable` | `path` | The shim could not be found or loaded at `path` |
| `&uv-libuv-unavailable` | `path` (inherited) | libuv's own shared object could not be found or loaded — a subtype of `&uv-shim-unavailable`, so guards on the parent keep matching; the sharper predicate is `uv-libuv-unavailable?` |
| `&uv-version-incompatible` | `compiled` `runtime` | Either libuv version is outside the supported range |
| `&uv-constant-unavailable` | `name` | The shim has no constant under that name |
| `&uv-invalid-argument` | `who` `reason` | A caller error, refused before anything was allocated |
| `&uv-callback-error` | `cause` | A callback raised; composed with the original condition |

v0.3 and v0.4 added no new condition types — every
`(libuv process)`/`(libuv pipe)`/`(libuv stream)`/`(libuv signal)` failure
raises one of the three above (`&uv-errno-error`, `&uv-handle-closed`,
`&uv-invalid-argument`); the closed set of `&uv-invalid-argument` reason
symbols (`'stdio-spec-unknown`, `'pipe-already-used`, `'signal-unknown`,
`'signal-unwatchable`, `'signal-mode-fixed`, and the rest of the validation
walk) is in the design specs' §4.7, not repeated here.
````

- [ ] **Step 2: Verify every relative link target exists**

```bash
rg -o '\]\((\.\./[^)#]+)' -r '$1' docs/api.md | sort -u | while read -r p; do
  test -e "docs/$p" && echo "ok $p" || echo "MISSING $p"
done
```

Expected: all `ok`, no `MISSING`.

- [ ] **Step 3: Run the suite**

Run: `make test` — Expected: `ALL SUITES PASSED`.

- [ ] **Step 4: Commit**

```bash
git add docs/api.md
git commit -m "docs: add docs/api.md — full export tables and per-module semantics

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: docs/building.md

**Files:**
- Create: `docs/building.md`

**Interfaces:**
- Consumes: nothing (content condensed from the pre-rewrite README's *Requirements and Build*, *Running*, *CHEZ_LIBUV_SHIM*, *Release builds*, *Tests* sections).
- Produces: `docs/building.md` — linked by quickstart.md (already) and Task 6's README.

- [ ] **Step 1: Write `docs/building.md` with exactly this content**

````markdown
# Building & testing

## What `make build` does

`make build` compiles the C shim and writes
`src/libuv/private/config.sls` — the shim's absolute path, the absolute
paths of the libuv shared libraries to load before it, and the supported
version range. **That file is generated and gitignored**, not part of the
repository, so a fresh clone has to run `make build` before
`(import (libuv))` can resolve. This is also why no source-only
distribution (an Akku package included) can work without a build step:
`config.sls` is a per-machine build product.

`make help` lists every target.

## Where libuv comes from

The floor is **libuv 1.44.0**; `make build` derives the packed version
range written into `config.sls` from it. libuv guarantees ABI stability
across 1.x, so this is a range check, not an equality test — a runtime
library outside the range makes initialisation raise
`&uv-version-incompatible` rather than run.

Which copy gets used depends on `pkg-config --exists libuv`:

- **Succeeds** (e.g. `brew install libuv` on macOS): the shim is compiled
  directly against that installed copy. Nothing under `vendor/` is touched.
- **Fails** (the common case on a bare Linux box): the same `make build`
  first runs `git submodule update --init --recursive` and builds the
  pinned `vendor/libuv` submodule with CMake (shared library only), then
  links the shim against that. Force this path deliberately, even with a
  system package present — this is what CI's vendored job does — with:

  ```sh
  make HAVE_PKG=no build
  ```

Which path is active, and what it produced:

```sh
make deps-info
```

## Running

Chez has to be told where the library lives; `CHEZSCHEMELIBDIRS` must
include `src`:

```sh
CHEZSCHEMELIBDIRS=src chez --program your-script.sps
```

For interactive use:

```sh
make dev
```

runs `build` and `deps` first — the latter vendors `chez-srfi` into
`build/scheme-libs` for the test suites; `(libuv)` itself needs none of
it — then starts a REPL with `CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs`.

## `CHEZ_LIBUV_SHIM`

Environment override for the shim's absolute path, read once at
initialisation — config in the environment is 12-factor. It is
**validated, never searched**:

- **Unset**: the default path `make build` recorded in `config.sls` is
  used, and must itself exist as a regular file.
- **Set**: must be an *absolute* path (leading `/`) to an *existing regular
  file*; that exact file is loaded.
- Anything else — a relative path, a path that does not exist, a
  directory — raises `&uv-shim-unavailable` immediately. There is no
  `PATH` search, no falling back to the default, and the working directory
  is never consulted.

## Release builds

`make build` links a *dev* shim: `-O0 -g`, with
`-DCHEZ_LIBUV_DEBUG_COUNTERS` defined, which is what makes the allocation
counters the test suites assert on report real numbers. A release build
turns both off:

```sh
make prod
```

cleans, relinks at `-O2` with the counters compiled out, and then runs
`make check-prod` — a *behavioural* check that the surviving artifact
really is the release one: `tests/check-prod.sps` allocates a loop and a
bound TCP handle and fails unless every counter reads zero while they are
demonstrably alive.

The Makefile's `relink-guard` deletes the shim whenever the requested
flavor (or acquisition path) stops matching what the artifact was linked
as, so `make test` after `make prod` self-heals back to a dev shim rather
than running the counter suites against an `-O2` artifact. The full
archaeology — including why the guard *deletes* instead of trusting stamp
mtimes (Apple make 3.81 compares at one-second granularity) — is in the
Makefile's own comments, which are kept deliberately thorough.

## Tests

```sh
make test
```

runs every `tests/test-*.sps` suite and fails if any of them do. It keeps
going after a failure, so one broken suite cannot hide the others.

```sh
make check-purity
```

runs the suites that must have *no* native dependency with
`CHEZ_LIBUV_SHIM` poisoned to a path that does not exist. If anything in
such a suite's import chain reaches the shim, it fails at import time,
before a single assertion runs.

```sh
make check-pins
```

fails if the `chez-srfi` submodule and `Akku.lock` name different commits,
if the vendored libuv is outside the supported range, if `README.org`
stops stating the version floor, or if `Akku.manifest` and `CHANGELOG.md`
disagree about the current version.

```sh
make test-memory
```

runs the suites again under Valgrind on Linux, or an AddressSanitizer
preload on macOS. **Only the Linux run can support a leak claim** —
LeakSanitizer does not exist on macOS/ARM64, so the macOS leg reports
use-after-free and double-free and says nothing at all about leaks
([ADR-0003](../.plans/decisions/0003-linux-valgrind-is-the-sole-memory-gate.md)).
The Linux leg sets `UV_USE_IO_URING=0`: some CI kernels reject `io_uring`
setup calls that Valgrind's syscall emulation does not model, which
produces failures that have nothing to do with this binding. That is an
escape hatch for the Valgrind leg only — `io_uring` stays on for
`make test`.

```sh
sudo make test-root
```

runs the root-gated setuid/setgid suite alone (see
[the API reference](api.md#child-processes--libuv-process)); run
`make build deps` unprivileged first — the target deliberately refuses to
build anything as root.

Every assertion in those suites has been watched to fail. Each stage's
mutation log (`.plans/*-mutation-log.md`) records the mutation that breaks
each decision, the assertion that caught it *by name*, and — where nothing
could catch one — why, rather than leaving the gap silent.
````

- [ ] **Step 2: Verify the link targets exist**

```bash
rg -o '\]\((\.\./[^)#]+)' -r '$1' docs/building.md | sort -u | while read -r p; do
  test -e "docs/$p" && echo "ok $p" || echo "MISSING $p"
done
```

Expected: all `ok`. (The `api.md#…` anchor link is same-directory and exists from Task 3.)

- [ ] **Step 3: Run the suite**

Run: `make test` — Expected: `ALL SUITES PASSED`.

- [ ] **Step 4: Commit**

```bash
git add docs/building.md
git commit -m "docs: add docs/building.md — acquisition paths, shim override, release builds, test gates

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Community files

**Files:**
- Create: `CONTRIBUTING.md`
- Create: `SECURITY.md`
- Create: `.github/ISSUE_TEMPLATE/bug_report.md`
- Create: `.github/ISSUE_TEMPLATE/feature_request.md`
- Create: `.github/PULL_REQUEST_TEMPLATE.md`

**Interfaces:**
- Consumes: `docs/building.md` (linked from CONTRIBUTING).
- Produces: `CONTRIBUTING.md`, `SECURITY.md` — linked by Task 6's README.

- [ ] **Step 1: Write `CONTRIBUTING.md` with exactly this content**

````markdown
# Contributing to chez-libuv

Thanks for wanting to improve this. Two kinds of contribution get two
levels of ceremony: a **drive-by fix** (typo, doc fix, small bug with a
test) needs only the gates below; **feature-sized work** should start as an
issue or design conversation before code — this binding is a legible
mirror of libuv's own vocabulary, and additions that invent vocabulary
need a design decision first.

## Setup

You need Chez Scheme 10.4.1+ (binary `chez`) and either a system libuv
`pkg-config` can see or nothing (the build vendors a pinned libuv
automatically):

```sh
git clone --recursive https://github.com/Kiyomi-Computation-Systems/chez-libuv.git
cd chez-libuv
make build
make test
```

`make help` lists every target; [docs/building.md](docs/building.md) has
the full build story.

## The gates

A PR must keep these green — they are exactly what CI runs:

- `make test` — every suite passes (`ALL SUITES PASSED`).
- `make check-pins` — submodule/lock/version/floor agreement.
- `make check-purity` — the pure suites still import no native code.
- `make test-memory` runs in CI; the Linux Valgrind leg is the only one
  that can support a leak claim.
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
````

- [ ] **Step 2: Write `SECURITY.md` with exactly this content**

````markdown
# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 0.4.x (latest) | ✅ |
| < 0.4 | ❌ |

## Reporting a vulnerability

Please report suspected vulnerabilities privately via GitHub:
**Security → Report a vulnerability** on this repository. Do not open a
public issue.

You can expect an acknowledgement within 7 days.

This is an FFI binding around a C library: reports touching the native
boundary (memory safety, lifetime bugs, argument validation) are
especially welcome. Please include your platform, Chez version, and
`make deps-info` output where relevant.
````

- [ ] **Step 3: Write `.github/ISSUE_TEMPLATE/bug_report.md` with exactly this content**

````markdown
---
name: Bug report
about: Something broke or behaved unexpectedly
labels: bug
---

**Environment**

- OS and architecture (e.g. macOS 15 arm64, Ubuntu 24.04 x86_64):
- Chez Scheme version (`chez --version`):
- libuv acquisition path and version (paste `make deps-info` output; add
  `(uv-version)` if the library loads):

**What happened**

**What you expected**

**Minimal reproduction**

Ideally a small standalone `.sps` program, run as
`CHEZSCHEMELIBDIRS=src chez --program repro.sps`.

**Does `make test` pass locally?**
````

- [ ] **Step 4: Write `.github/ISSUE_TEMPLATE/feature_request.md` with exactly this content**

````markdown
---
name: Feature request
about: Propose an addition to the binding
labels: enhancement
---

**The problem**

What can't you do today?

**Proposed API surface**

Which module does it belong to (`(libuv tcp)`, `(libuv process)`, a new
one), and what would the exports look like?

**Does it mirror an existing libuv verb?**

This binding is a legible mirror of libuv's own vocabulary. If the
proposal wraps an existing `uv_*` function, name it. If it invents
vocabulary libuv doesn't have, expect a design conversation first —
see `CONTRIBUTING.md` in the repository root.
````

(`CONTRIBUTING.md` is deliberately plain text, not a relative link:
issue-template bodies render in contexts where relative links do not
resolve.)

- [ ] **Step 5: Write `.github/PULL_REQUEST_TEMPLATE.md` with exactly this content**

````markdown
## What

<!-- One or two sentences: what changes and why. -->

## Checklist

- [ ] `make test` is green locally (`ALL SUITES PASSED`)
- [ ] Commit/PR title is a Conventional Commit (`feat:`, `fix:`, `docs:`, …)
- [ ] Tests accompany code changes (and each new suite ends with `(exit …)`)
- [ ] `README.org` / `docs/` updated if the public API changed
- [ ] `CHANGELOG.md` entry if the change is user-visible
````

- [ ] **Step 6: Verify links and run the suite**

```bash
for f in docs/building.md AGENTS.md SECURITY.md CONTRIBUTING.md; do test -f "$f" && echo "ok $f"; done
make test
```

Expected: four `ok` lines, then `ALL SUITES PASSED`.

- [ ] **Step 7: Commit**

```bash
git add CONTRIBUTING.md SECURITY.md .github
git commit -m "docs: add CONTRIBUTING, SECURITY, and GitHub issue/PR templates

Gates hard, process soft: PRs must keep the CI gates green; the
mutation-log discipline is presented as house style for feature work.
Security reports go through GitHub private vulnerability reporting.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: README.org rewrite

**Files:**
- Modify: `README.org` (full replacement)

**Interfaces:**
- Consumes: `docs/quickstart.md`, `docs/api.md`, `docs/building.md`, `CONTRIBUTING.md`, `SECURITY.md` (all exist by now — every link resolves at commit time).
- Produces: the public front page. Must keep the literal string `libuv 1.44.0` (check-pins).

- [ ] **Step 1: Replace README.org with exactly this content**

````org
* chez-libuv

[[https://github.com/Kiyomi-Computation-Systems/chez-libuv/actions/workflows/ci.yml][https://github.com/Kiyomi-Computation-Systems/chez-libuv/actions/workflows/ci.yml/badge.svg]]

Thin R6RS bindings to libuv asynchronous I/O for Chez Scheme.

#+begin_quote
✨ *AI Disclosure:* LLMs are used extensively in the planning and development of this project.
#+end_quote

* What it is

A legible, low-level mirror of libuv: the event loop, TCP sockets, timers,
DNS, child processes with pipe stdio, and signal watching. The public API
follows libuv's own verb set — ~accept~, ~read-start~, ~write~,
~shutdown~, ~timer~, ~getaddrinfo~, ~spawn~, ~close~ — closely enough that
a caller who knows libuv recognises the Scheme surface immediately.

It is transport only: it parses nothing, understands no protocol above raw
bytes, and provides no connection-state or backpressure policy of its own —
those belong to the layers built on top of these primitives. The full
design, with seventeen accepted decision records, lives under
[[file:.plans/][.plans/]].

* Status

*v0.4.0* — event loop, TCP (bind, listen, accept, connect, reads with
backpressure, writes, shutdown), timers, DNS (~getaddrinfo~,
~getnameinfo~, ~cancel~), child processes (the full ~uv_spawn~ stdio
vocabulary) with minimal pipes, and signal watching (continuous and
oneshot). No filesystem, no UDP, no zero-copy I/O
([[file:.plans/decisions/0009-copy-at-the-boundary.md][ADR-0009]]). CI
covers macOS and Linux on both dependency-acquisition paths; Windows is
deferred, not designed out
([[file:.plans/decisions/0004-windows-deferred-design-clean.md][ADR-0004]]).

* Install

Prerequisites:

- *Chez Scheme* 10.4.1 or later (the binary is ~chez~)
- *libuv 1.44.0* or later in the 1.x series — either a system package
  ~pkg-config~ can see (e.g. ~brew install libuv~), or nothing at all: the
  build falls back to a pinned, vendored libuv submodule automatically.

Then:

#+begin_src sh
git clone --recursive https://github.com/Kiyomi-Computation-Systems/chez-libuv.git
cd chez-libuv
make build
#+end_src

~make build~ compiles the small C shim and generates
~src/libuv/private/config.sls~, which records absolute paths for /this/
machine. That file is deliberately not in the repository, so every clone
runs ~make build~ once before ~(import (libuv))~ resolves. ~make help~
lists all targets; [[file:docs/building.md][docs/building.md]] has the full
story, release builds included.

** Using Akku

Akku manages this project's Scheme-level dependency (~chez-srfi~, used by
the test suites only — ~(libuv)~ itself imports nothing beyond ~(rnrs)~).
The package is not yet on the Akku index; until it is, consume it as a git
checkout exactly as above. A source-only install cannot work anywhere:
the native shim and the generated ~config.sls~ are per-machine build
products.

** Running your program

Chez needs ~src~ on its library path:

#+begin_src sh
CHEZSCHEMELIBDIRS=src chez --program your-script.sps
#+end_src

~make dev~ starts a REPL with everything wired.

* A taste

#+begin_src scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define timer (make-uv-timer loop))
(define fires 0)

(uv-timer-start! timer
                 (lambda (t)              ; the callback receives the timer
                   (set! fires (+ fires 1))
                   (display "tick\n")
                   (when (= fires 3)
                     (uv-timer-stop! t)
                     (uv-close! t)))
                 0 100)                   ; first fire now, then every 100 ms

(uv-run loop 'default)    ; callbacks run here and nowhere else
(uv-loop-teardown! loop)
#+end_src

The real walkthrough — an echo server and client on one loop, and the
three rules every program here depends on — is
[[file:docs/quickstart.md][docs/quickstart.md]].

* Documentation

| [[file:docs/quickstart.md][Quickstart]]         | An echo server start to finish, and the rules that make it work |
| [[file:docs/api.md][API reference]]             | Every export of every module, one line each, with semantics     |
| [[file:docs/building.md][Building & testing]]   | Acquisition paths, ~CHEZ_LIBUV_SHIM~, release builds, test gates |
| [[file:CHANGELOG.md][CHANGELOG]]                | Per-release history                                             |
| [[file:.plans/][Design specs & ADRs]]           | Why it is built this way, with the evidence                     |

* Contributing

See [[file:CONTRIBUTING.md][CONTRIBUTING.md]] for the build/test workflow
and conventions, and [[file:SECURITY.md][SECURITY.md]] for reporting
vulnerabilities privately.

* License

BSD 3-Clause. See ~LICENSE~.

Third-party software arrives as git submodules under its own licenses —
[[https://github.com/libuv/libuv][libuv]] (MIT; see ~vendor/libuv/LICENSE~
and ~LICENSE-extra~) and
[[https://github.com/arcfide/chez-srfi][chez-srfi]] (permissive; see
~vendor/chez-srfi/LICENSE~; test suites only). Nothing third-party is
copied into this tree. If you redistribute binaries or archives that
bundle libuv, carry its license texts.

-----

© [[https://kiyomicomputation.systems/][Kiyomi Computation Systems LLC]], all rights reserved.
````

- [ ] **Step 2: Verify the floor string, length, and links**

```bash
grep -c "libuv 1.44.0" README.org        # expect: 1 (or more)
wc -l README.org                          # expect: ~130 (spec says "≤ ~130"; a handful over is fine, 200 is not)
rg -o '\[\[file:([^]]+)\]' -r '$1' README.org | sort -u | while read -r p; do
  test -e "$p" && echo "ok $p" || echo "MISSING $p"
done
```

Expected: count ≥ 1, ≤ 130 lines, all `ok`.

- [ ] **Step 3: Relocation audit (spec acceptance #3)**

Diff the old README against the new corpus by spot-checking that each
removed section's content exists in its new home:

```bash
git show main:README.org | grep -c "relink-guard"   # old README had it
rg -c "relink-guard" docs/building.md               # expect ≥ 1
rg -c "pipe-already-used" docs/api.md               # expect ≥ 1
rg -c "EAI_CANCELED" docs/api.md                    # expect ≥ 1
rg -c "SIG_DFL" docs/api.md                         # expect ≥ 1
rg -c "check-purity" docs/building.md               # expect ≥ 1
```

Expected: every count ≥ 1. Anything the audit finds missing gets added to
the owning `docs/` file before committing.

- [ ] **Step 4: Run the suite (check-pins now greps the NEW README)**

Run: `make test` — Expected: `ALL SUITES PASSED`, including the line
`README states the libuv floor (1.44.0)`.

- [ ] **Step 5: Commit**

```bash
git add README.org
git commit -m "docs: rewrite README.org as a thin open-source front page

What-it-is, status, install for Akku and non-Akku users, a 15-line
runnable taste, and links into docs/ — depth moved to docs/quickstart.md,
docs/api.md, docs/building.md (one home per fact). Keeps the exact
'libuv 1.44.0' floor string check-pins greps for, and adds the
third-party licensing paragraph (submodules carry their own licenses;
no NOTICE file needed).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: check-pins version stanza + manifest bump

The stanza lands FIRST so it fails RED against the live 0.2.0/0.4.0 drift —
the real-world mutation this check exists to catch — then the manifest bump
turns it GREEN. That RED run is the spec's watched-to-fail evidence
(acceptance #5); record its output in the PR description.

**Files:**
- Modify: `Makefile` (check-pins recipe, after the README-floor stanza ending `@echo "README states the libuv floor ($(UV_FLOOR_DOTTED))"`; also the target's `##` description on the `check-pins:` line)
- Modify: `Akku.manifest` (version `"0.2.0"` → `"0.4.0"`)

**Interfaces:**
- Consumes: `CHANGELOG.md`'s top heading format `## X.Y.Z — DATE`; `Akku.manifest`'s `(akku-package ("chez-libuv" "X.Y.Z")` line.
- Produces: `make check-pins` gains a fourth agreement check; output line `manifest version matches CHANGELOG (0.4.0)`.

- [ ] **Step 1: Update the check-pins `##` description**

In `Makefile`, change the target line:

```make
check-pins: ## Verify chez-srfi submodule <-> Akku.lock, vendored libuv version, and README floor all agree
```

to:

```make
check-pins: ## Verify chez-srfi/Akku.lock pins, vendored libuv range, README floor, and manifest/CHANGELOG version agree
```

- [ ] **Step 2: Append the version stanza to the check-pins recipe**

Immediately after the recipe line
`@echo "README states the libuv floor ($(UV_FLOOR_DOTTED))"`, add:

```make
	@man=$$(sed -n 's/.*("chez-libuv" "\([0-9][^"]*\)").*/\1/p' Akku.manifest | head -1); \
	chg=$$(sed -n 's/^## \([0-9][0-9.]*\).*/\1/p' CHANGELOG.md | head -1); \
	if [ -z "$$man" ] || [ -z "$$chg" ]; then \
	  echo "check-pins: could not read both versions (manifest='$$man' changelog='$$chg')" >&2; \
	  exit 1; \
	fi; \
	if [ "$$man" != "$$chg" ]; then \
	  echo "VERSION DRIFT: Akku.manifest declares $$man but CHANGELOG.md's top release is $$chg." >&2; \
	  echo "Bump the manifest when cutting a release; consumers read the manifest." >&2; \
	  exit 1; \
	fi; \
	echo "manifest version matches CHANGELOG ($$man)"
```

(Recipe lines are TAB-indented, like every stanza above them.)

- [ ] **Step 3: Watch it fail RED against the live drift**

Run: `make check-pins`
Expected: the three existing checks pass, then:

```
VERSION DRIFT: Akku.manifest declares 0.2.0 but CHANGELOG.md's top release is 0.4.0.
Bump the manifest when cutting a release; consumers read the manifest.
```

and exit status 2 (make reports the recipe's exit 1). If it does NOT fail,
STOP — the stanza is an empty check; fix the `sed` extraction until this
exact failure appears. Save the output for the PR description.

- [ ] **Step 4: Bump the manifest**

In `Akku.manifest`, change:

```scheme
(akku-package ("chez-libuv" "0.2.0")
```

to:

```scheme
(akku-package ("chez-libuv" "0.4.0")
```

- [ ] **Step 5: Watch it pass GREEN, and check the help contract**

```bash
make check-pins    # expect: ...  manifest version matches CHANGELOG (0.4.0)
make check-help    # expect: exit 0, no output (all .PHONY targets documented)
```

- [ ] **Step 6: Run the full suite**

Run: `make test` — Expected: `ALL SUITES PASSED`.

- [ ] **Step 7: Commit**

```bash
git add Makefile Akku.manifest
git commit -m "chore: bump Akku.manifest to 0.4.0; check-pins gates manifest/CHANGELOG agreement

The manifest sat at 0.2.0 through two releases and nothing noticed —
the new stanza was watched to fail against exactly that drift before
the bump turned it green (check beats comment).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Final verification (after Task 7)

- [ ] `make test && make check-purity && make check-help` — all green.
- [ ] Spec acceptance sweep:
  1. `ls docs/` → exactly `api.md building.md quickstart.md`; `.plans/` has both `-plan.md` files; `rg -l "docs/superpowers" --hidden -g '!.git' .` → only this plan and the design doc (historical references in `.plans/` are fine — acceptance #1 is about the tree, not the archives).
  2. `wc -l README.org` ≤ 130; floor string present; every `docs/` file linked.
  3. Relocation audit from Task 6 Step 3 green.
  4. `CONTRIBUTING.md`, `SECURITY.md`, three `.github` templates exist.
  5. Manifest 0.4.0; RED evidence from Task 7 Step 3 recorded.
- [ ] Push and open the PR (squash-merge per closing ritual):

```bash
git push -u origin docs/public-release-prep
gh pr create --title "docs: public-release documentation pass" --body "$(cat <<'EOF'
Implements .plans/2026-08-22-chez-libuv-public-release-docs-design.md:
superpowers plans relocated to .plans/, thin README front page, docs/
split (quickstart/api/building), CONTRIBUTING + SECURITY + templates,
Akku.manifest 0.4.0 with a check-pins stanza watched-to-fail against
the live drift (RED output below).

<paste Task 7 Step 3 RED output here>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] Post-merge owner action (not automatable): enable **Private
  vulnerability reporting** in the repo's GitHub settings when it flips
  public.
