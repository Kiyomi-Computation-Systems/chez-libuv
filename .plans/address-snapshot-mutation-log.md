# The address verbs read their arguments once: mutation log

Evidence for `fix/address-snapshot`. `uv-tcp-bind!`, `uv-tcp-connect!` and
`uv-getnameinfo!` checked that an address was a string, then handed the
caller's string to libuv through Chez's `string` argument, once for
`uv_ip4_addr` and again for `uv_ip6_addr`:

- **No NUL check.** C reads a string only up to its first NUL, so
  `"127.0.0.1\x0;anything"` was bound, connected to and reverse-resolved as
  `127.0.0.1`: the prefix resolution the v0.2 DNS design refused for node
  names (§4.1).
- **Read during the call.** The `string` argument encodes the string while
  the call runs, after the check. An engine's timer handler, or another
  thread, could change it in between. A NUL written into `"::1"` made it
  `"::"`: `uv-tcp-bind!` bound every interface instead of loopback,
  `uv-tcp-connect!` was handed the unspecified address, and
  `uv-getnameinfo!` resolved `"::"`. And Chez's encoder counts, allocates,
  then encodes, so a character widened in between made C read past the
  bytes Chez allocated.

The review of this branch found the same two readings in `uv-tcp-bind!`'s
and `uv-getnameinfo!`'s flag lists: `list?`, then `fold-left`. A list made
circular in between was walked forever.

All of it dates from v0.1 (`uv-tcp-bind!`, `uv-tcp-connect!`) and v0.2
(`uv-getnameinfo!`).

The branch began on PR #51's d2fb572, reusing its `c-string-bytes`, and was
rebased onto main's d816e65 when #51 merged; `c-string-bytes` merged byte
for byte as it was moved here. It was rebased again onto cff802b, after #55
(a memory-gate mode) and #56 (`uv-spawn!` reads its arguments once), which
change none of the files this branch touches. The first probes ran on main's
a0ea0ca, which #51 does not touch on this path; the red runs below are on
d816e65, whose code for these verbs cff802b keeps. The final mutation table
ran on the code tree 9e21665 (on d816e65); every gate ran on it and again on
the rebased code tree 7de3821. The non-allocating length check came after
those gates; the branch then rebased onto 652bb40 (#57, test-only), and
every gate ran again on the final code tree c681abb (commits b95dd72 and
e5581d3).

Every probe and mutation ran on a scratch copy outside the repo. Platforms:
macOS arm64 26.6.2 (Chez 10.4.1 `tarm64osx`, libuv 1.52.1 via pkg-config,
the dev build); Linux aarch64 in the `chez-libuv-valgrind:10.4.1` image
(Debian bookworm, Valgrind 3.19, vendored libuv 1.52.1, `HAVE_PKG=no`), from
`--no-hardlinks` clones. The macOS host carried other sessions' load
throughout (load average 3 to 220) and two loopback floods (07:37–07:49 and
08:06–08:12). Nothing here waits on loopback delivery, and the fuel maps
below are deterministic.

---

## The bugs, confirmed

**The NUL, outside any engine** (a0ea0ca, both platforms):

| call | address | what libuv acted on |
|---|---|---|
| `uv-tcp-bind!` | `"127.0.0.1\x0;anything"` | bound `127.0.0.1` |
| `uv-tcp-connect!` | `"127.0.0.1\x0;anything"` | connected, peer `127.0.0.1` |
| `uv-getnameinfo!` | `"127.0.0.1\x0;anything"` | host `127.0.0.1` |
| `uv-getnameinfo!` | `"1.2.3.4\x0;5"` | host `1.2.3.4` |

**The encoder.** Chez 10.4.1's `$fp-string->utf8` (`s/prims.ss`) counts the
bytes, allocates one more, writes the terminating NUL, then encodes. A
character widened between the count and the encode writes its extra byte
over that NUL, or past the allocation. Through `strlen`, a split at 1,024
characters read n + 5 bytes: the widened string with no terminator, then
4 bytes of the heap.

A first probe found splits only from 1,024 characters, and an earlier draft
of this log and of the suite's comments said so. The threshold was the
probe's artifact. A split followed by a zero byte gives `strlen` the same C
string, so the probe saw only splits followed by non-zero heap bytes. With
the heap dirtied before each sweep, the same probe found splits at every
length from 64 (2 of 4 runs at 64 characters, 16 of 18 at 512). The review's
verifier measured this; the suite's widened sweeps catch the split at 200
characters on every platform run.

**Through the verbs** (a0ea0ca; Linux gave the same counts, run for run):

| sweep | runs | parsed wrongly | parsed as given |
|---|---|---|---|
| bind, NUL at index 2 of `"::1"` | 28 | 24 bound `::` | 4 bound `::1` |
| connect, NUL at index 2 | 39 | 27 in-flight `::` | 12 `::1` |
| getnameinfo, NUL at index 2 | 51 | 39 host `::` | 12 `::1` |
| connect, a 1,043-character zoned address, one filler character widened | 103 | 22 scope 0 | 81 scope 1 |
| getnameinfo, the same address | 115 | 32 scope 0 | 83 scope 1 |
| bind, the same address | 92 | none visible | 92 `::1` |

The widened rows need an address that libuv still accepts. With a zone,
`uv_ip6_addr` copies at most 39 characters before the `%` and parses only
those (`uv-common.c`), so a full-form address, filler and `%lo0` (`%lo` on
Linux) parses as `::1` with the loopback interface's scope. A split encoding
changes the zone name, which then names no interface, and the scope becomes
0. Bind cannot show it: the kernel ignores the scope of a non-link-local
address, and Linux gives `lo` no link-local address to bind.

**The flag lists** (the review's verifier, on this branch before the flags
commit): `uv-getnameinfo!` with flags `(numeric-host numeric-serv)` made
circular at the first expiry was refused by name at fuel 1–23, raised
`fold-left`'s raw "is circular" at 24–26, and never returned at 27–31,
still spinning after 20,000,000 ticks. `uv-tcp-bind!` behaved the same. Not
memory-unsafe (the conversion runs before anything is allocated), but a
raw Chez condition where `&uv-invalid-argument` is promised, and a call that
spins the calling thread forever.

## The fix

- `require-address` became `validate-address`, which answers the address
  as the bytes libuv parses: `c-string-bytes` copies the string with
  interrupts disabled, encodes the copy, appends the NUL and refuses an
  embedded one (`'address-contains-nul`). It runs before anything is
  allocated, in the old order: not a string, then a NUL, then the port.
- `fill-sockaddr!` takes those bytes and passes the same bytevector to
  `uv_ip4_addr` and then `uv_ip6_addr`, both now `u8*`. It refuses anything
  that is not one C string (`(uv-fill-sockaddr! not-a-c-string)`), as
  `uv-getaddrinfo-native` does. The raw parsers are no longer exported.
- `c-string-bytes` moved out of `(libuv private addrinfo)` into a new pure
  library, `(libuv private c-string)`, beside `c-string?`, the predicate
  both native wrappers share. `(libuv private addrinfo)` no longer imports
  `(chezscheme)`; `make check-purity` holds.
- `fold-flags` reads a flag list once: its length from `proper-length`, a
  tortoise-and-hare walk that answers `#f` for an improper or circular list
  (the refusal), then at most that many pairs, each checked as it is read.
  Both verbs fold their flags through it and refuse under their own names
  with the reasons they had. `proper-length` raises nothing, so no guard is
  needed, and `fold-flags` allocates nothing. The first version measured
  with a guarded `length` (#51's shape for the hint flags), which cost 272 B
  a call however short the list; you chose the non-allocating check.

## The rows

**`tests/test-address.sps`** is new. Three rows refuse
`"127.0.0.1\x0;anything"`, `"::1\x0;"` and `"\x0;"` under each verb's own
name. Eight sweeps run one call each in an engine at rising fuel and change
the argument at the first expiry. A run must answer as the call answers for
one reading, outside any engine: `'changed` for the reading the change made,
`'original` for the one it was given, `'untouched` for the last run.

Each sweep stops at the first run with no expiry, whatever its verdict. It
also stops at the first run that stalled (a call that never finished within
its capped resumes, a lookup that never landed) or raised outside the call,
keeping that run as its evidence. Every run is checked against a snapshot of
the registry and every debug count taken just before it, and the sweeps run
one after another in a fixed order. Every call the suite makes, the sweeps'
and the preconditions' alike, runs in an engine with capped resumes. What
libuv parsed is the oracle: the address getsockname reports after a bind,
the in-flight connect request's sockaddr byte for byte against libuv's own
`uv_ip6_addr` called directly, and the reverse lookup's numeric host.

On the fix (macOS; Linux's widened sweeps are 2 runs shorter, `%lo` being
one byte shorter than `%lo0`):

| sweep | runs | changed | original | untouched |
|---|---|---|---|---|
| bind, NUL at index 2 of `"::1"` | 45 | 13 | 31 | 1 |
| connect, NUL | 47 | 12 | 34 | 1 |
| getnameinfo, NUL | 63 | 12 | 50 | 1 |
| connect, 243-character zoned address, filler widened, last address digit 1 → 0 | 548 | 12 | 535 | 1 |
| getnameinfo, link-local `fe80:…:0001` form of the same | 564 | 12 | 551 | 1 |
| bind, flags `(bogus-flag)` made circular | 39 | 24 | 14 | 1 |
| getnameinfo, flags `(numeric-host numeric-serv)` made circular | 63 | 24 | 38 | 1 |
| getnameinfo, the same flags cut after the first | 63 | 28 | 34 | 1 |

- **The widened change also writes the address part's last digit.** A run
  that saw the change (`::`, `fe80::%lo0`) is told from one that did not, and
  the reach row can name each sweep's first run `'changed`.
- **The getnameinfo sweep needs no private reads.** A reverse lookup renders
  a link-local address's zone by name on macOS and on glibc, so it reads the
  scope from its host alone.
- **The connect sweep's oracle is white-box.** It reads the sockaddr
  `fill-sockaddr!` wrote beside the request, the one `uv_tcp_connect` is
  handed; no end-to-end observation tells `::` from `::1` there, since the
  kernel routes both to loopback.
- **bind's flag sweep starts from a flag it refuses everywhere.**
  `'reuseport` answers differently by platform and libuv, and either refusal
  is right for the reading the call made.

Three preconditions hold the oracles:

- `::1` can be bound for the connect target;
- the loopback interface has a name a zone can carry;
- one more byte on the zone drops the scope, and each widened reference is
  what the call answers for its reading. The given address is scoped, the
  longer one parses as plain `::1` and reverse-resolves as `fe80::1`, and
  each sweep's two references equal what the call answers outside any engine.

**`tests/test-native.sps`:**

- `validate-address` refuses a non-string and a NUL, naming its caller, and
  answers a C string for one it cannot parse.
- `fill-sockaddr!` refuses four inputs that are not one C string (the NUL
  inside first, which a missing check would parse as `127.0.0.1`), and
  passes IPv4, IPv6 and an unparseable C string through.
- `fold-flags` folds proper lists of odd and even length, refuses improper
  and circular lists (cycles at the head and further in) under its caller's
  name, each call in an engine with capped resumes so a looping walk answers
  `'stuck`, and allocates nothing: 0 bytes a call, fewest of 64, beside a
  check that the meter sees a 64-byte allocation.
- The round trip now runs inside its row, so a `fill-sockaddr!` that refuses
  good bytes fails that row instead of aborting the suite.

`test-dns.sps`'s synthetic sockaddrs pass bytes.

## Red on the base

**main d816e65** (the old address path and the old flag fold), the final
suite, plain: 8 rows fail by name on both platforms, exit 1. Two runs on
each platform gave the same counts, run for run.

- The three refusal rows answer what libuv did: `(bound "127.0.0.1")`,
  `(parsed "127.0.0.1" …)`, `(host "127.0.0.1")` for the first address;
  `"::1\x0;"` is bound as `::1`; `"\x0;"` is refused as `bad-address`.
- The reach row: each NUL sweep's first run parsed `::` instead of being
  refused.
- The bind, connect and reverse-lookup rows: 22, 25 and 37 runs of the NUL
  sweeps acted on `::`, and 7 runs of each widened sweep parsed the changed
  address with scope 0 (the count ran before the change, the encode after
  it).
- The catch-all row: 2, 4 and 5 runs of the flags sweeps raised `fold-left`'s
  own conditions or stalled.

**The flags sweeps, on the first commit** (flags still read twice): the
reach row and the catch-all row fail by name. The sweeps show:

- bind: raw `fold-left` "is circular" at fuel 18–19;
- getnameinfo, circular: the same at 18–20, then a stall at 21, where the
  sweep stops with `(stalled (stuck-after-resumes 100) ())`;
- getnameinfo, cut short: "not a proper list" at 17–19 and "input list was
  altered during operation" at 20–21.

## Valgrind

`make test-memory-docker`, unmodified, from a `--no-hardlinks` clone of the
code tree: exit 0 in 241 s.

- `check-memory-gate` caught the store overrun, the libc overrun and the
  leak, stayed consistent on the possible leak, and printed MEMORY GATE CAN
  FAIL.
- Every suite's own Valgrind summary: 0 errors and 0 bytes definitely lost.
  `test-address.sps` passed 14 rows at 6,802 allocations. The two forked
  children of `test-process.sps` that `_exit` before exec report 131 B and
  117 B: the known fork artifacts, which never gate (ADR-0003).
- MD2 below, run alone through the recipe's Valgrind command on the first
  tree, failed with exit 9 and 1,664 B in 13 blocks definitely lost
  (13 × 128 B of `sockaddr_storage`). On main, `alloc-zeroed` counts into
  #53's `'block` class, so the per-run balance now catches it in plain runs
  too.

## Mutations

Each mutation was an exact text replacement in a fresh copy of the code
tree's `src/`, `tests/` and `Makefile`, aborted unless its target occurred
once, and re-checked after. The owning suites ran from the copy against the
repo's shim. A mutation counts as caught only if a named row failed; a suite
that died without a summary is listed as a crash, never as a catch. The
control, the unmutated copy, passed all five suites. The table ran on the
code tree 9e21665. The PL rows, and the MF rows of the walk they feed, ran
on the final code tree, after the guarded `length` gave way to
`proper-length`; no other file under mutation changed between the two.

Validation and the shared copy:

| id | mutation | caught by |
|---|---|---|
| MA1 | `validate-address` answers the encoded copy with no NUL check | test-address: the three refusal rows (refused by `uv-fill-sockaddr!` instead), the reach row, "refused by the call itself"; test-native: "validate-address refuses a string holding a NUL" |
| MA2 | `validate-address` checks the caller's string, then copies and encodes unchecked | test-address: "refused by the call itself": a run that saw the NUL after the check was refused by `uv-fill-sockaddr!` |
| MA3 | `c-string-bytes` encodes the caller's string, no copy (#51's MC3) | test-address: the connect and reverse-lookup rows (the zone's last byte lost: scope 0, `fe80::`); test-addrinfo: its widened, truncated and cross-thread rows |
| MA5 | `validate-address` refuses a NUL with a plain `error` | test-address: the three refusal rows, the reach row, the catch-all; test-native |
| MA6 | no `string?` check | test-native, test-dns, test-tcp: their non-string rows |
| MA8 | `c-string-bytes` answers the UTF-8 without the terminator | test-native: "validate-address answers a string it cannot parse as that string's C string"; test-address: five rows; test-addrinfo: eleven. test-dns and test-tcp die at their first address (crashes, not catches) |
| MA9 | `c-string-bytes` has no NUL check (#51's MC6) | test-address, test-native, test-addrinfo, test-dns: their NUL rows |

`fill-sockaddr!`:

| id | mutation | caught by |
|---|---|---|
| MB1 | no C-string check | test-native: "fill-sockaddr! refuses an address that is not one C string" |
| MB2 | the check requires only the terminator | the same row (the NUL inside parses as `127.0.0.1`) |
| MB3 | the check's refusal names the verb | the same row |
| MB4 | the check lets an empty bytevector through | the same row |
| MB5 | IPv4 only | test-native: "fill-sockaddr! passes C strings through to libuv"; test-address: five rows; test-tcp: "accepts an IPv6 address literal" |
| MB6 | the bad-address refusal names the boundary, not the caller | test-native: "passes C strings through"; test-dns and test-tcp: their garbage-address rows |
| MN3 | `c-string?` allows a NUL inside (#51's MN3) | test-native: both C-string rows, `uv-getaddrinfo-native`'s and `fill-sockaddr!`'s |

The verbs:

| id | mutation | caught by |
|---|---|---|
| MV1 | main's shape: `string` arguments, the verbs pass the caller's string | test-address: the bind, connect and reverse-lookup rows; test-native: the round trip (by name now) and both `fill-sockaddr!` rows. test-dns dies at its top-level synthetic sockaddr (a crash) |
| MV2 | `uv-tcp-bind!` encodes the caller's string again after validating | test-address: "refused by the call itself" (refused by `uv-fill-sockaddr!`) |
| MV3 | the same in `uv-tcp-connect!` | the same row |
| MV4 | the same in `uv-getnameinfo!` | the same row |
| MD1 | `uv-tcp-connect!` validates again after registering its request, outside the guard | test-address: the catch-all (`(left (registry 1) (connect-req 1) …)`), both epilogue rows |
| MD2 | `uv-tcp-bind!` validates again between allocating and guarding its scratch | test-address: the catch-all (`(left (block 1))`), the counts epilogue. Plain, not Valgrind-only |
| MD4 | the same in `uv-tcp-connect!`, before registration | the same two rows |
| MD5 | the same in `uv-getnameinfo!` | the same two rows |
| MS-A | `uv-tcp-connect!` never returns once its arguments are checked | test-address in 0.3 s: the widened-references precondition (stuck), the reach row, the catch-all (the sweep stopped at its first stalled run) |
| MS-B | `getnameinfo-dispatch` completes a lookup without its request, so the callback never lands | test-address in 18 s: the precondition, the reach row, the catch-all, both epilogue rows |
| MX | `uv-tcp-connect!` answers a symbol instead of its request | test-address: the precondition, the reach row, the catch-all (`run-raised` at the fuel it happened) |
| MT | `uv-loop-teardown!` drains but never closes the loop | test-address: both epilogue rows |

The flag lists:

| id | mutation | caught by |
|---|---|---|
| PL1 | `proper-length` has no cycle check | test-native: "fold-flags refuses an improper or circular list…" (`'stuck` at the cap); test-address: the reach row, the catch-all (the circular sweeps stall, and stop) |
| PL2 | `proper-length` does not check the cdr of a pair | test-native: the same row (`cdr` of an improper tail raises); test-address: the reach row, the catch-all |
| PL3 | `proper-length` does not check that its argument is a pair | test-native: the same row; test-dns and test-tcp: their non-list flags rows |
| PL4 | `proper-length` counts an odd list one short | test-native: "fold-flags folds a proper list's flags, odd and even lengths alike"; test-address: the reach row, the catch-all; test-tcp: its unknown-flag row |
| PL5 | `fold-flags` measures with a guarded `length` again | test-native: "fold-flags allocates nothing…" (272 B), and nothing else: allocation is what only that row holds |
| MF3 | the walk runs until the list ends, not at most its length | test-address: the reach row, the catch-all (the circular sweeps stall, and stop) |
| MF4 | no check of each pair | test-address: the catch-all (`car` of the cut tail) |
| MF5 | `uv-tcp-bind!` asks `list?` and folds with `fold-left` (main's shape) | test-address: the catch-all |
| MF6 | the same in `uv-getnameinfo!` | test-address: the reach row, the catch-all |

The suite's own decisions:

| id | mutation | caught by |
|---|---|---|
| HA1 | fuel cap 5 | the reach row |
| HA2 | the change is never made | the reach row |
| HA3 | the widened change keeps the address digit | the widened-references precondition, the reach row |
| HA4 | the sweeps start at fuel 13 | the reach row |
| HA5 | the zone names no interface | both zone preconditions, the reach row, the reverse-lookup row |
| HA7 + MS-B | a stalled run no longer ends its sweep, with MS-B | the suite hangs: killed at 300 s (exit 124) with one row printed. The stall stop is what turns MS-B into a named failure |
| HA8 + MX | no per-run guard, with MX | the suite aborts at the raise (exit 255). The guard is what keeps MX's evidence |
| HM4 | the connect target bound to an address no interface has | the `::1` precondition, the reach row, the catch-all |
| HM5 | the zone candidates name no interface | the loopback-name precondition, the widened-references precondition, the reach row, the catch-all |
| HM6 | the suite does not tear its loop down | both epilogue rows |

## Equivalent, or held elsewhere

- **MA4, the copy without interrupts disabled** (#51's MC2): test-address
  passes; test-addrinfo's truncated-and-collected node fails by name. The
  fence lives in `c-string-bytes`, shared, and its owning suite holds it. A
  truncation sweep through the verbs was not built: a copy that reads past
  a truncated address yields heap characters, which libuv refuses as
  `bad-address` just as it refuses most short readings, so the oracle would
  have to be the refusal rather than the parse.
- **MA7, encoding inside the fence with no copy** (#51's MC1): test-address
  passes; test-addrinfo's cross-thread row fails by name. Only another
  thread can split an encoding made with interrupts disabled, and this suite
  runs none. That row is skipped under Valgrind, which runs one thread at a
  time (#51's log).
- **MD3, `uv-getnameinfo!` checking the port before the address:** passes.
  Nothing specifies the order of refusals, and no row holds it; the fix
  keeps the old one.
- **HA6, the per-run balance gutted:** passes on the fix, which leaves
  nothing. With MD2 the counts epilogue still fails by name, so the per-run
  check is not the only guard; it is the one that names the sweep and fuel.
- **HA9, the sweeps built by `map`:** passes. With a snapshot per run, which
  sweep a leak is found in no longer depends on their order; the fixed order
  only keeps the evidence in a stable order.
- **The parsers stay plain, not `__collect_safe`:** uncovered, as #51
  records for `uv_getaddrinfo`. A collect-safe call would let another
  thread's collection move the bytes while libuv parses them; the window is
  a parse of a few dozen bytes, and no row has been built to hit it. A
  source rule would hold it (below).
- **Bind's widened sweep:** not built, for the reason above. Bind reads its
  address through the same `validate-address` and `fill-sockaddr!`; MV2 shows
  its NUL sweep catches it handing libuv anything but the copy.

## Allocation

What a call allocates, fewest of 200 calls, macOS arm64 (two alternated
runs, identical):

| | bind | connect | getnameinfo |
|---|---|---|---|
| main, `127.0.0.1` or `::1` | 352 B | 768 B | 800 B |
| fix, `127.0.0.1` | 496 B | 912 B | 944 B |
| fix, `::1` | 448 B | 864 B | 896 B |

- **The address copy costs +144 B for a 9-character address and +96 B for a
  3-character one.** That is the private copy at 4 B a character,
  `with-interrupts-disabled`'s `dynamic-wind`, the UTF-8 and the terminated
  bytes, less the bytevector the `string` argument used to allocate. The
  copy is what makes the encoding safe against another thread (#51's MC1).
  The `dynamic-wind` belongs to `c-string-bytes`, shared with #51, and was
  left as #51 chose it.
- **The flag lists cost nothing.** `fold-flags` allocates 0 bytes a call,
  which test-native holds. The guarded `length` it first used cost 272 B a
  call (bind 768 B, getnameinfo 1,280 B per call with it), and #51's
  `checked-flags` for getaddrinfo's hint flags still has that guard.

## The review

A max-effort code review (ten finder angles, a verifier per candidate, a
gap sweep) reported 15 findings, all confirmed, and all fixed on the final
tree:

- the flag lists read twice (the second commit);
- sweeps running on past stalled runs, which hung the suite at its 300 s cap
  with no evidence (mutants MS-A and MS-B below);
- the round trip's top-level plumbing in test-native;
- a precondition whose expected values failure paths produced, so a source
  change refusing long addresses left the suite green, and whose two other
  parts could not fail;
- a four-counter leftover check against the fixtures, and sweeps built by
  `map`, whose order Chez does not fix, so a leak in one sweep was reported
  in another;
- a catch-all that discarded a sweep's evidence;
- docs and comments that overclaimed:
  - "either seen or not seen" for another thread's writes (torn copies
    measured: 24,000 to 27,000 in 1,000,000 under fenced stores);
  - "every interface" for connect and getnameinfo;
  - ADR-0012's "strings are immutable";
  - what test-address holds;
  - a stale test-native comment;
  - api.md's scope-ID bullet, false for getnameinfo;
- the 1,000-character filler and its threshold claim;
- the Makefile's drifting PURE_TESTS note;
- this log's gaps.

The connect read's unchecked request pointer was refuted (no path hands it a
freed request, and Chez turns such a fault into a condition), but the read
is now checked anyway, replacing a comment.

After the review, at your choice, the flags walk measures with a
non-allocating tortoise-and-hare count instead of a guarded `length`.

Decisions the review raised and this branch kept:

- `fill-sockaddr!` keeps its own C-string check (#51's boundary);
- `c-string-bytes` stays byte-identical to #51's;
- the refusal order stays address before port;
- the snapshot stays a bytevector rather than a record type only
  `(libuv private c-string)` could make.

## Found on the way, not fixed here

- **libuv truncates a zoned address.** `uv_ip6_addr` copies at most 39
  characters before the `%` and silently ignores an unknown zone, so
  `"0000:0000:0000:0000:0000:0000:0000:0001junk…%lo0"` parses as `::1%lo0`
  and `"::1%bogus"` as `::1`. That is libuv's parse, which ADR-0012 adopts
  as the vocabulary. Refusing it would mean the binding parsing addresses
  itself. Recorded, not changed.
- **`uv-write*!` walks its segment list with `map`.** The verb checks
  `list?` first, and `map` walks unchecked. In a sweep through the real verb
  on this branch and on main, the third cdr replaced at the first expiry
  gave "invalid memory reference" at fuel 18–22. Filed as its own task.
- **`uv-spawn!`'s strings were the other instance of the string class.**
  #56 (cff802b) fixed them while this branch was in review. It reads each
  string with its own `read-string`, `(string->utf8 (string-copy s))`,
  inside one interrupt-free step around the whole request. That is the same
  recipe as `c-string-bytes`, written twice; one helper could serve both.
- **test-dns calls its async verbs at top level throughout.** A refusal
  from `fill-sockaddr!` aborts that suite rather than failing a row. This
  predates the branch.
- **#51's DNS bullet in docs/api.md overclaims.** "Either seen by that check
  or not seen at all" fails for another thread, and for an engine handler
  that changes node and service together, which are read in separate steps.
- **Two source rules would hold by check what this branch and #51 apply by
  hand.** One: no `string` FFI argument except `chez_uv_constant`'s, whose
  names are the binding's own. Two: no `u8*` argument in a `__collect_safe`
  call. Main's `tests/test-source-rules.sps` is their home.

## Gates

Each gate ran three times: on the code tree 9e21665 (on d816e65), on the
rebased 7de3821 (on cff802b), and on the final code tree c681abb (commits
b95dd72 and e5581d3, on 652bb40), after the non-allocating length check.
All three runs were on macOS arm64 at a load average of about 3.5 to 5,
with no flood running, and all were green:

- `make test`: 23 suites pass.
- `make test-memory`: all 23 suites pass with the ASan runtime preloaded on
  Chez (Xcode clang 21's `libclang_rt.asan_osx_dynamic.dylib`).
- `make check-memory-gate`: the recipe goes red on its planted defects
  ("MEMORY GATE CAN FAIL"). On c681abb that includes #55's shim-overrun mode
  (`in chez_uv_copy_in`).
- `make check-purity` holds for all five pure suites; `make check-help` is
  silent.
- `make check-nothreads-docker`: every public library is refused by name on
  a `--nothreads` Chez, the new `(libuv private c-string)` reached through
  them.
- `make test-memory-docker`, from a `--no-hardlinks` clone each time: exit 0,
  in 241 s, 269 s and 249 s.
  - Its `check-memory-gate` caught the store overrun, the libc overrun, the
    shim overrun (from 7de3821 on) and the leak, and stayed consistent on
    the possible leak.
  - Every suite's own summary was 0 errors and 0 bytes definitely lost,
    apart from `test-process`'s two fork artifacts (131 B, 117 B).
  - On c681abb, `test-address.sps` passed 14 rows at 6,700 allocations and
    `test-native.sps` 301 rows.

The commit that adds this log changes only this file and `docs/api.md`'s
DNS bullet, so no code changed after the gates.
