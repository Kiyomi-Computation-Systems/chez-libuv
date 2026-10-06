# uv-getaddrinfo! reads its arguments once: mutation log

Evidence for `fix/getaddrinfo-snapshot`. Both bugs were found by reading
the code during #49 and measured on 2026-10-05; both were confirmed again
here before any change.

The work began on `main`'s 0e6a8e1 and was rebased three times as PRs
merged during it: onto a0ea0ca (#49), 309c376 (#48) and eb5b719 (#50, #54,
#53, #52). None of them touches `dns.sls`, `addrinfo.sls`, `test-dns.sps`
or `test-addrinfo.sps`; they change `native.sls`, `test-native.sps` and the
Makefile's `PURE_TESTS` comment elsewhere. #53 routes every block the
binding allocates through the debug shim, which now counts them
(`live-counts`' `'block`), and the hints sweep's rows check that count from
eb5b719 on. The probes, the first red and the unfixed Valgrind run ran on
0e6a8e1. The mutation sweep ran five times, the last on the final tree,
b2e8ef6, and every gate ran on that tree.

`uv-getaddrinfo!` validated its node, service and hints, and then read them
again:

- It allocated the request block, and `write-hints!` read the hints alist
  again to fill it, converting each symbol to its platform int. A hint
  turned bogus in between raised `unknown-hint-family` there, with the block
  allocated and not yet registered, and nothing freed it.
- `validate-node-and-service` checked node and service for NUL as Scheme
  strings, and Chez's `string` argument encoded them again during the
  native call. A NUL written in between reached libuv, which read the
  string up to it.

An engine's timer handler can do either, or another thread. Both reads date
from v0.2.0, beside a comment calling the conversions' refusal arms
"UNREACHABLE BY CONSTRUCTION -- validate-hints ran first".

Every probe and mutation ran on a scratch copy outside the repo. Platforms:
macOS arm64 26.6.2 (Chez 10.4.1 `tarm64osx`, libuv 1.52.1 via pkg-config,
the dev build); Linux aarch64 in the `chez-libuv-valgrind:10.4.1` image
(Debian bookworm, Valgrind 3.19, vendored libuv 1.52.1, `HAVE_PKG=no`), from
`--no-hardlinks` clones.

---

## The two bugs, confirmed

Each probe ran `uv-getaddrinfo!` in an engine at fuel 1, 2, …, made one
change at the first expiry, resumed it, and stopped at the first run no
expiry reached. Its control made no change.

- **The leak.** Fresh hints `((family . inet) (socktype . stream))`, the
  family set to `bogus` at the first expiry. On 0e6a8e1, 41 of 67 runs were
  refused with `unknown-hint-family`. `leaks --atExit` counted 19 leaks of
  224 B, 4,256 B in all, and 246 malloc nodes alive at exit against 227 for
  the control, which has 0 leaks. A block counter planted at `alloc-zeroed`
  and `free!` in a scratch copy found 20 blocks never freed (the counter
  moves the fuel map a little).
- **The NUL bypass.** `(string-copy "127.0.0.1")` as the node, hints
  `((family . inet) (flags numeric-host))`, `(string-set! node 3 #\nul)` at
  the first expiry. 63 of 75 runs resolved `0.0.0.127`; 11 were refused with
  `node-contains-nul`, and the last run, untouched, resolved `127.0.0.1`.
  The control resolved `127.0.0.1` in 75 of 75.

## Chez's own string primitives read twice as well

The direction proposed was a snapshot: validation answers copies, and the
call uses nothing else. Measuring it found that encoding a string the
caller can still reach is itself two readings, inside Chez (10.4.1;
`$string->utf8` in `s/prims.ss`):

- **`string->utf8` counts, allocates, then encodes.** An engine can expire
  in between once the string is 64 characters or more. Widening only the
  last character then, the answer has the old length and ends in `#xCE`,
  half of λ: the encoding ran one byte past what was allocated. Split
  points, of the fuel values that expired:

  | characters | 8 | 64 | 128 | 256 | 512 | 1,024 | 2,048 | 4,096 |
  |---|---|---|---|---|---|---|---|---|
  | split runs | 0 | 2 | 4 | 8 | 16 | 32 | 64 | 128 |

  Widening all 2,000 characters of a string the same way overwrote the
  engine's own state: the resumed run raised `no engine active`.
- **The FFI's `string` argument** encodes the same way. Through `strlen`,
  from 512 characters, C saw strings 2 to 13 bytes longer than the one
  given: the NUL the encoder wrote first was overwritten, and `strlen` ran
  on into the heap. So on `main`, a long node or service changed during the
  call could make libuv read past the bytes Chez allocated.
- **Another thread needs no engine.** One thread widened and narrowed a
  4,096-character string while another encoded it 20,000 times:
  `string->utf8` gave 6,976 and 15,819 encodings inconsistent with any one
  reading of it, in two runs. Copying the string first, with interrupts
  disabled, then encoding the copy gave 0 of 20,000.
- **`string-copy` reads the length, allocates, then copies.** A handler
  that truncated a 4,096-character string to 1 and collected made the copy
  read past it: 512 of 1,001 runs answered characters the string never
  held. The same copy with interrupts disabled: none, in 4 runs (the only
  expiries left fall outside it).

So `c-string-bytes` copies the string with interrupts disabled, which runs
no handler and no collection inside the copy, and encodes the private copy.
A copy is fixed-width, so another thread cannot make it overrun. These are
upstream behaviours, not fixed here.

## The fix

- `validate-hints` answers a copy of the alist, made by the walk that
  checks it. Each entry and value is read once, the copy shares no pair with
  the caller's, and `(libuv dns)` converts it to ints before allocating.
  Writing the ints reads no caller data and cannot raise.
- The spine is checked pair by pair as it is walked. The flags are measured
  by one `length` call, whose raise is the refusal, and walked no further
  than that.
- `validate-node-and-service` answers each string's UTF-8 and a terminating
  NUL, checked for any other NUL as encoded. Node and service cross as `u8*`,
  and `uv-getaddrinfo-native` refuses anything but one C string per
  argument (`not-a-c-string`).
- `with-interrupts-disabled` around the copy is the one `(chezscheme)`
  import `(libuv private addrinfo)` gains. It imports the threaded-Chez
  refusal ahead of it, and stays pure: `make check-purity` holds.

A `guard` freeing the block on a late raise would have closed the leak and
kept both double reads; DNS is not a hot path, so the copies' allocation was
not weighed against it.

## The rows

**`tests/test-dns.sps`** sweeps one lookup per change, at rising fuel, and
stops at the first run no expiry reached, whatever its verdict. Every run
must be refused under the call's own name with no request registered or
counted and the block count where it found it, or carry exactly the hints
it was given and resolve exactly the node and service it was given
(`127.0.0.1`, `8080`, one inet/stream entry). A closing row requires the
sweeps to leave no request and no block behind. On the fix:

| change at the first expiry | runs | refused | resolved | untouched |
|---|---|---|---|---|
| the family turns `bogus` | 128 | 31 | 96 | 1 |
| the family turns `inet6`, the socktype key `color` | 128 | 33 | 94 | 1 |
| a NUL at node index 3 | 128 | 11 | 116 | 1 |
| a NUL at service index 2 | 128 | 23 | 104 | 1 |

The second change uses valid values, so a call that reads the hints again
writes them into the request instead of refusing. Its socktype is walked
after the family, so a run that saw the new key was refused for it.

**`tests/test-addrinfo.sps`** sweeps the validators themselves:

| sweep | runs | answers |
|---|---|---|
| hints: family `bogus`, first flag `bogus-flag` | 28 | 10 refused for the family, 16 for the flag, 2 as given |
| hints: spine made improper | 28 | 13 refused, 15 as given |
| hints: flags made circular | 28 | 25 refused, 3 as given |
| node of 256 a: the last widened to λ | 292 | 10 the widened string, 282 the original |
| `"127.0.0.1"`: a NUL at index 3 | 21 | 10 refused, 11 the original |
| node of 512 a: truncated to 1, collected | 572 | 10 `"a"`, 562 the original |

A cross-thread row narrows a 4,096-character node (λ to a) from another
thread while each of 200 rounds widens it and validates it, and requires
every answer to be the bytes of one reading. It only narrows, because a race
that narrows leaves `string->utf8`'s tail unwritten, while one that widens
writes past it and the evidence goes with the heap. Each round waits until
the narrower has visibly started, and the sweep names a dead narrower. An
informational line counts the rounds that read the node mid-change: 81 to
187 of 200 natively.

The row is skipped under Valgrind (`CHEZ_LIBUV_UNDER_VALGRIND`, which the
Linux memory gate sets). Valgrind runs one thread at a time, so no round
overlaps there: 0 of 200. And its default scheduler hands its lock back to
the thread that just held it, so the round's wait starved the narrower. In
a long-lived container, the row failed 4 of 4 runs that way, naming the
narrower dead by round 2 to 5, and passed 4 of 4 with `--fair-sched=yes`.
The first Valgrind run of the fix had passed it by chance.

A copy row requires the hints' copy to equal the caller's alist and share
none of its 8 pairs. The acceptance rows now expect the copies and the C
strings, among them UTF-8 for `"xλ"` and the bare NUL for `""`.

**`tests/test-native.sps`** gives `uv-getaddrinfo-native` a NULL request,
which libuv answers with `EINVAL` before reading anything else: six inputs
that are not one C string must be refused by name instead, and four that are
must reach libuv.

## Red on the base, green on the fix

**Plain, on 0e6a8e1** (`test-dns.sps` alone; the other two suites' new rows
fail there on the old answers, `'present` and `'validated`):

- "a lookup the sweep let through carried the hints it was given" fails by
  name: runs 27 to 53 of the renamed-key sweep carried `(4100 30 0 0)`,
  family `AF_INET6` and no socktype.
- "a lookup the sweep let through resolved the node and service it was
  given" fails by name: runs 12 to 94 of the node sweep resolved
  `0.0.0.127`, and runs 20 to 94 of the service sweep port 80.
- The bogus-family sweep passed every plain row there: the late refusal
  looked exactly like the early one, and nothing counted the block.

**Plain, on eb5b719**, whose shim counts blocks, the same two rows fail, and
two more by name: "… refused by the call itself, leaving no request", whose
bogus-family runs from 25 on were refused with `blocks 1`, and "the sweeps
left no request registered or counted, and no block allocated", which found
29 blocks left: the 29 Valgrind reports below.

**Valgrind, unfixed:** a `--no-hardlinks` clone of 0e6a8e1 with the new
`test-dns.sps` alone, through the unmodified `make test-memory-docker`.
`check-memory-gate` printed MEMORY GATE CAN FAIL. `test-memory` then failed
`test-dns.sps`'s two plain rows above and reported 6,032 B in 29 blocks
definitely lost: 29 × 208 B, the getaddrinfo block on Linux aarch64. make
exited 2.

**Valgrind, fixed:** a `--no-hardlinks` clone of the final tree, the same
target, exit 0. `check-memory-gate` printed MEMORY GATE CAN FAIL, and
`test-dns.sps` passed 126 rows with 0 bytes definitely lost and 0 errors, at
3,909 allocations. Both runs leave the same 3,170 B in 11 blocks still
reachable at exit.

## Mutations

Each mutation was an exact text replacement in a fresh copy of `src/` and
`tests/`, aborted unless its target occurred once and re-checked after. The
owning suites ran against the copy; a mutation counts as caught only if a
named row failed. The table ran five times, the last time on the final
tree, and each run agreed with the one before (MD6 joined it on eb5b719).

| id | mutation | caught by |
|---|---|---|
| MH1 | `validate-hints` answers the caller's alist | the copy equals the caller's hints and shares none of their pairs; hints changed during validation …; test-dns: … refused by the call itself, leaving no request |
| MH2 | the copy re-reads each value after its check | the copy … shares none of their pairs; hints changed during validation … |
| MH3 | the flags copy is the caller's list | the same two |
| MH5 | no `pair?` check of the spine | hints changed during validation … (`car` of the improper tail raises) |
| MH6 | the flags walk is unbounded | hints changed during validation … (`(stuck)` at the resume cap) |
| MH7 | `list?`, then `length` | hints changed during validation …: runs 20 and 21 raised `length`'s own "is circular" |
| MH8 | `length` unguarded | a bare flags symbol …; an improper flags list …; both hints-sweep rows |
| MC1 | encode the caller's string with interrupts disabled, no copy | a node another thread narrows … answers the bytes of one reading, 10 of 10 runs; one run had 50 bad rounds of 200, 47 of them refusing a NUL the node never held |
| MC2 | copy without disabling interrupts | a node truncated during validation answers the bytes of one reading |
| MC3 | encode the caller's string directly | the widened, the truncated and the cross-thread rows |
| MC4 | check the caller's string, then copy and encode unchecked | a NUL written into the node … reaches nothing; test-dns: … refused by the call itself (`uv-getaddrinfo-native`'s refusal named) |
| MC5 | no terminating NUL | the acceptance rows and every node sweep; test-dns dies at its first lookup |
| MC6 | no NUL check on the bytes | both embedded-NUL rows and the NUL sweep; test-dns: the boundary NUL row, the reach row, the refusal row |
| MD2 | write the hints from the caller's alist after allocating (`main`'s shape) | test-dns: … refused by the call itself (bogus-family runs leave a block; the renamed key raises a bare `fold-left` error after the block exists); the sweeps left … no block allocated |
| MD6 | allocate the block before validating | test-dns: the reach row (the first run's refusal leaves a block), … refused by the call itself, the sweeps left … no block allocated |
| MD3 | node and service as the caller's strings, `string` FFI (`main`'s shape) | test-dns: … resolved the node and service it was given; test-native: both C-string rows |
| MN1 | no C-string check | test-native: … refuses a node or service that is not one C string |
| MN2 | the check does not require the terminator | the same |
| MN3 | the check allows a NUL inside | the same |
| MN4 | the check covers the node only | the same |
| MN5 | an empty bytevector passes | the same |
| HD1 | test-dns: fuel cap 5 | each sweep began before the call's own checks and ended in a run no expiry reached |
| HD2 | test-dns: the change does nothing | the same |
| HP1 | test-addrinfo: the changes do nothing | the four reach rows |
| MR1 | `addrinfo.sls` imports `(chezscheme)` before the threaded-Chez refusal | test-require-threaded: src/libuv/private/addrinfo.sls imports (libuv private require-threaded) before (chezscheme) |
| HP2 | test-addrinfo: the narrower never narrows | a node another thread narrows … (the round's wait names the dead narrower) |

## Equivalent, or uncovered

- **MD1, converting the hints after allocating:** equivalent. The copy is
  private and validated, so the conversion cannot raise wherever it runs.
  It runs first anyway, which keeps "nothing between the allocation and the
  guard can raise" true by layout.
- **MH4, re-reading a flag right after its check:** equivalent. No trap
  check falls between the two reads (the sweep visits every one), so no
  engine can split them. A thread could; the unchecked flag would then be
  refused by the conversion, before the block exists.
- **MC7 and MD4, the order of refusals:** node is still refused before
  service, and both before the hints, as before the fix. Nothing specifies
  that order and no row holds it; every input passes either way.
- **The block clauses** hold MD6 alone: MD6 with both clauses removed
  passes every row.
- **HP3, no resume cap in the pure sweeps:** passes on the fix, since only a
  broken validator runs long. With MH6 it is load-bearing: MH6 alone fails
  by name in about 2.6 s; MH6 with HP3 hung until `timeout` killed the
  suite at 300 s.
- **`raw-getaddrinfo` stays plain, not `__collect_safe`:** uncovered. A
  collect-safe call would let another thread's collection move the bytes
  while libuv reads them. `tests/test-threading-stress.sps` pins the same
  property for `copy-in!`, whose window is a whole `memcpy`; here it is a
  `strlen` and a copy of a short name, which no row has been built to hit.
- **Whether the narrower overlaps a call:** informational, not asserted.
  The verdict row cannot fail on a right answer, whatever the schedule; the
  wait proves the narrower is alive, not that it overlaps.
- **The Valgrind skip:** a test that skipped the race everywhere would pass
  every row and hide MC1. Nothing but MC1's catch holds the condition, the
  same standing as test-native's Valgrind-aware dirty-memory seed.

## Found on the way, not fixed here

- **The address strings.** `uv-tcp-bind!`, `uv-tcp-connect!` and
  `uv-getnameinfo!` hand the caller's IP string to `uv_ip4_addr` and
  `uv_ip6_addr` through the same `string` argument, so a long one changed
  during the call meets `string->utf8`'s overrun. `require-address` checks
  only that it is a string, so `"127.0.0.1\x0;anything"` parses as
  `127.0.0.1`: the prefix resolution that ADR-0013's design refused for DNS
  names.
- **`uv-spawn!`'s strings.** Its overflow, measured in #49, comes from
  sizing with `string->utf8` and encoding again. A fix that encodes the
  caller's strings once still meets the overrun above unless it copies them
  first.
- **`test-facade.sps` fails on a loaded host.** Its TCP drain stops after 32
  iterations, and its 1 ms ticker makes that roughly 32 ms. During this
  work other processes held the load average at 40 on 8 cores, and loopback
  connects took 4 to 831 ms through the binding (0.4 to 658 ms through raw
  Python sockets). The suite then failed its first TCP rows and died of the
  late connect callback raising `&uv-handle-closed`, in two full ASan runs,
  alone with and without ASan, and on `main`'s own a0ea0ca under ASan. It
  passed 3 of 3 alone under ASan, and in `make test`, while the host was
  quieter. The rows fail before the suite's one DNS section.

## Gates

On the fix rebased onto eb5b719 (tree b2e8ef6), macOS arm64, at a load
average near 10:

- `make test`: 22 suites pass, among them #48's `test-source-rules.sps`
  and #52's `test-seed-gates.sps`.
- `make test-memory` (ASan, the runtime's banner printed): all 22 suites
  pass.
- `make check-memory-gate`: the recipe still goes red on the planted libc
  overrun. `make check-purity` holds for its five suites, and `make
  check-help` is silent.
- `make check-nothreads-docker`: every public library is refused by name on
  a `--nothreads` Chez, `(libuv dns)` among them.

The same gates passed on the rebases onto a0ea0ca (tree 19a0025, load 3)
and 309c376 (tree b3e935d).

`make test-memory-docker` (Linux aarch64, Valgrind, vendored libuv 1.52.1),
from a `--no-hardlinks` clone of the fix:

- `check-memory-gate` caught the store overrun, the libc overrun and the
  leak, stayed consistent on the possible leak, and printed MEMORY GATE CAN
  FAIL.
- Every suite's own Valgrind summary: 0 errors and 0 bytes definitely lost,
  22 suites.
- The two forked children that `_exit` before exec report 131 B and 117 B
  definitely lost: the known fork artifacts, which never gate (ADR-0003).
