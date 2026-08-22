# v0.4 Task 2 mutation log — frozen-literal RED evidence (ADR-0008 third amendment)

Task 2: the thirteenth trampoline and the signal entry points
(`src/libuv/private/native.sls`). Per ADR-0008's third amendment, the two
frozen dispatcher-name literals in `tests/test-loop.sps` and
`tests/test-native.sps` were widened from twelve names to thirteen (`... exit
walk` -> `... exit walk signal`) FIRST, with `native.sls`'s own
`dispatcher-names` left untouched at twelve. `tests/test-native.sps` also
gained the new "the signal slot holds the raising uninstalled stub" row
(mirroring the existing exit/walk rows) in this same RED step. Both suites
were then run unmodified against the still-twelve-name `native.sls`, so the
failures below are a real observation of the gap, not a restatement of the
plan.

## Commands run

```
CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs CHEZ_LIBUV_TEST_CHEZ="$(command -v chez)" chez --program tests/test-loop.sps
CHEZSCHEMELIBDIRS=src:tests:build/scheme-libs CHEZ_LIBUV_TEST_CHEZ="$(command -v chez)" chez --program tests/test-native.sps
```

## Failing output (verbatim, the only failures in each run)

```
=== tests/test-loop.sps ===
%%%% Starting test loop
FAIL dispatcher-names names the thirteen callback types the design commits to
# of expected passes      137
# of unexpected failures  1
```

```
=== tests/test-native.sps ===
%%%% Starting test native
  [informational] uv_buf_t offsets on this platform: base=0 len=8 sizeof=16
  [informational] sockaddr_in offsets: sin_family=1 sin_port=2
  [informational] addrinfo offsets: ai_addr=32 ai_canonname=24 sizeof=48
FAIL dispatcher-names names the thirteen callback types the design commits to
FAIL the signal slot holds the raising uninstalled stub
# of expected passes      249
# of unexpected failures  2
```

## Why this is the expected RED

`dispatcher-names` in `native.sls` is still the twelve-name list (`alloc read
connection write-done close timer shutdown connect getaddrinfo getnameinfo
exit walk`), so:

- The widened literal test fails by name in both suites: the thirteen-name
  expected list cannot `equal?` the still-twelve-name `dispatcher-names`.
- In `test-native.sps`, `(dispatcher-ref 'signal)` finds `'signal` absent
  from `dispatcher-names` altogether, so `dispatcher-ref` raises
  `&uv-invalid-argument` naming `'unknown-dispatcher` rather than the
  uninstalled-stub condition whose message is "callback dispatchers have not
  been installed" — so the new stub-row assertion (which guards specifically
  for that message) also fails, distinctly from the literal-list failure
  above. This is the same failure mode the v0.3 process-stage-2 log recorded
  for the analogous `walk`-drop probe.

Both failures resolve once Step 3's `native.sls` edits append `signal` to
`dispatcher-names` (Step 4, confirmed green).
