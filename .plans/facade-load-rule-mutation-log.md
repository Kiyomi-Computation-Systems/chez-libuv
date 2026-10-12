# Rule 13 (a public verb reaches native code only once loaded): mutation log

Each mutant was applied to a copy of the worktree outside the repository
(`scratchpad/m13`), run under the copy's own `scripts/guix-env` with
`CHEZ_LIBUV_SHIM` pointed at the copy's shim and `CHEZ_LIBUV_TEST_CHEZ` set,
and reverted. The unmutated copy passed test-source-rules (74) and
test-first-call (11).

## Against the source

| # | Mutation | Failed, by name |
|---|---|---|
| S1 | `uv-os-getpid` without its `(ensure-native-loaded!)` | source-rules word row `((uv-os-getpid . loads))`; first-call `getpid` row `(not-loaded a-pid not-loaded)` |
| S2 | `uv-os-getpid` loads after its native call (`(define pid (uv-os-getpid-native))` first) | source-rules word row only: the first-call row passes, since the call answers a pid either way |
| S3 | a new export, `uv-os-getppid`, reaching a foreign binding, unlisted | coverage row `(unlisted (uv-os-getppid) …)` |
| S6 | `uv-cancel!` without its `uv-dns-request?` check | word row `((uv-cancel! . record))`; sweep row `((uv-cancel! (invalid-argument constants-not-initialized) not-loaded))` |
| S7a | a loop-free export `uv-family->int` over `family-symbol->int`, labelled `record` | word row `((uv-family->int . record))`, and the sweep agreement row (unswept) |
| S7b | S7a with `symbols-of` counting quoted data again | the word row no longer names `uv-family->int` (it names `uv-kill!`, whose quoted `'uv-kill!` now "reaches" native code), and rule 9 fails on `uv-family->int`: the quote fix is what catches S7a's mislabel |
| S10 | `(libuv)` exports `uv-loaded?`, a rename of an import | resolution row `((uv-loaded? ()))` |
| S11 | `(libuv loop)` exports `ensure-native-loaded!` | public-library row `(("src/libuv/loop.sls" ensure-native-loaded!))` |
| D2 | `uv-kill!` loads after naming its signal | word row `((uv-kill! . loads))`; first-call `killterm` row `(not-loaded (invalid-argument constants-not-initialized) not-loaded)` |
| D3 | `make-uv-loop` without its load | word row; first-call `loop` row `(not-loaded a-loop not-loaded)` |
| D5 | `uv-cancel!` reads `(errno-symbol->value 'EBUSY)` before its record check | first-call sweep row only, with `constants-not-initialized`: the order is the run's to hold |
| D6 | `uv-run`'s two-argument arm loads before its record check | sweep row: every shape from `uv-run` on reports `loaded` |

## Against the table and the lists

| # | Mutation | Failed, by name |
|---|---|---|
| S4 | `(uv-loop? . record)` added to the table | coverage `(not-native (uv-loop?))`, word row, sweep agreement |
| S5a | `uv-async-send!` relabelled `loads` | word row; first-call agreement `(not-run (uv-async-send!) …)` |
| S5b | `uv-kill!` relabelled `record` | word row; first-call agreement `(not-loads (uv-kill!))`; sweep agreement |
| S8a | `uv-version` dropped from `first-call-verbs` | first-call agreement `(not-run (uv-version) …)` |
| S8b | `(uv-run (run . ran))` added to `first-call-verbs` | first-call agreement `(not-loads (uv-run))` |
| S9a | the sweep's `uv-cancel!` shape dropped | sweep agreement `(unswept (uv-cancel!) …)` |
| S9b | a shape for `uv-cancel-all!`, which nothing exports | sweep agreement `(not-exported (uv-cancel-all!))` |
| D4 | the child calls `uv-os-getpid` before its token's call (broken seed) | every first-call row on `before`, the sweep's seed row, and the sweep row |

## Against the checks' plumbing

| # | Mutation | Failed, by name |
|---|---|---|
| P1 | `native-reachers` empty | coverage row, every listed verb `not-native` |
| P2 | `record-checkers` empty | word row, every `record` verb |
| P3 | `first-call-verbs` renamed in test-first-call | first-call agreement, `(no-definition first-call-verbs …)` |
| P4 | `export-form` answers `#f` for every name | resolution, coverage and word rows |
| P5 | the child's unloading list empty | the sweep's seed row, `()` |
| P6 | the child no longer knows the token `version` | that verb's row, each entry `(no-entry … ((unknown-token . "version")))` |

Every mutant failed only the rows named, and passed again once reverted.

## Uncovered

- A reach through a procedure installed at run time is invisible to the
  scan; `uv-close!`'s is the one today, and the sweep covers it.
- A name imported under another one is invisible to `reaching`; the
  resolution row fails an export bound that way, so none can hide.
