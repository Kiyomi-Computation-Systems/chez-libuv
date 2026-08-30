# v0.5 flow-control spike — FINDINGS

Stage 0 of the v0.5 flow-control milestone (design spec
`.plans/2026-08-29-chez-libuv-v0.5-flow-control-design.md` §10), **run late**.

This spike was scheduled as Stage 0 and never executed. The milestone shipped
without it, and nothing recorded the drop — the sequence in §14 walked from
Stage 0 straight to the closing ritual as though it had happened. That matters
beyond a missed deliverable, because **Q2's answer had already shipped as
user-facing fact**: `docs/api.md`'s three-buffers table and
`src/libuv/handle.sls`'s comment both told readers the Linux receive buffer
"can substantially exceed" the per-handle read buffer at high connection
counts. The spec said plainly that this was "currently arithmetic, not
measurement" and scheduled Q2 to settle it. The arithmetic shipped; the
measurement did not.

It is measured now, and **the arithmetic was wrong in the direction that
matters**.

## Environment

| | Linux leg | macOS leg |
|---|---|---|
| Runner | Debian bookworm container, aarch64, via `make test-memory-docker`'s image | Darwin/arm64 dev machine |
| How run | locally, 2026-08-30 | n/a — Q2 is Linux-only by construction |
| Chez Scheme | 10.4.1, built from the pinned release tarball | 10.4.1 (brew) |
| libuv | 1.52.1 (vendored submodule) | same |
| Repetition | each N run twice; figures below stable across runs | — |

**A note on method, because it changed what was affordable.** Every previous
spike in this repo obtained its Linux leg through a temporary spike-branch CI
run — push, dispatch, harvest, delete. Q2 ran in a local container instead,
using the image `make test-memory-docker` builds. That is the first dividend
from that target beyond the leak gate: an iteration on a measurement script
costs seconds rather than a CI round trip, which is very likely why this leg
felt affordable now and did not when it was scheduled.

---

## Q2 — what does the OS receive buffer actually cost per connection?

Script: `13-rcvbuf-cost.ss`. Linux only; it reports SKIPPED elsewhere rather
than inventing a number.

### Kernel defaults on the measured host

```
/proc/sys/net/ipv4/tcp_rmem   4096   131072   6291456
/proc/sys/net/core/rmem_max   212992
/proc/sys/net/ipv4/tcp_wmem   4096   16384    4194304
```

**`tcp_rmem[1]` is 131072.** The v0.5 fix wave already flagged the 87 KB
figure in the shipped docs as dated — that is the older default — and this
confirms it directly rather than by inference.

### Measurements

```
N = 100
  SO_RCVBUF reported per accepted socket: 131072 bytes
  chez-libuv read buffer, if read-started:  65536 bytes
  idle  : TCP mem = 383 pages   (1 MiB total,  15 KiB/conn)
  unread: TCP mem = 13526 pages (52 MiB total, 541 KiB/conn)

N = 200
  SO_RCVBUF reported per accepted socket: 131072 bytes
  chez-libuv read buffer, if read-started:  65536 bytes
  idle  : TCP mem = 594 pages   (2 MiB total,  11 KiB/conn)
  unread: TCP mem = 26368 pages (103 MiB total, 527 KiB/conn)
```

`unread` = 512 KiB pushed per client with the peer never calling
`uv-read-start!`. Both ends live in the measuring process, so the figures
include the client's send queues as well as the peer's receive queues; treat
the per-connection numbers as an upper bound on the receive side alone.

### The finding

**`SO_RCVBUF` is a ceiling the kernel may grow into, not memory it has
charged.** Reading only the reported value — which is what the shipped claim
amounts to — asserts a per-connection cost the kernel never pays at rest.

Against the 64 KiB per-handle read buffer:

| | per connection | vs the 64 KiB read buffer |
|---|---|---|
| `SO_RCVBUF`, reported | 131072 B | **2× — the ceiling** |
| Kernel memory actually charged, **idle** | ~11–15 KiB | **~0.2× — five times SMALLER** |
| Kernel memory actually charged, **unread** | ~530 KiB | **~8× — larger, and unbounded in principle** |

So the shipped sentence is true of the ceiling, **false of the idle cost**,
and true-and-then-some of a state that only arises when the consumer has
stopped reading.

**The determining variable is not connection count. It is whether the
application reads** — which is precisely this milestone's own subject. The OS
receive buffer is not a fixed per-connection tax that scales past the read
buffer; it is near-free at rest and becomes the dominant cost exactly when
backpressure discipline has failed. Stated that way it is both accurate and
useful, where the shipped version was neither.

**The chez-libuv read buffer is the opposite shape.** It is committed the
moment `uv-read-start!` runs, 65536 bytes of resident foreign memory per
handle, whether or not a byte ever arrives. At rest it is the larger cost by
roughly 5×, and it is the one the application cannot avoid paying.

### What changed as a result

`docs/api.md`'s three-buffers table and `src/libuv/handle.sls`'s comment were
both corrected to state the measured behaviour rather than the ceiling. See
the commit that lands this file.

### Honest limits of this measurement

- One kernel, one distribution, one architecture (Debian bookworm, aarch64).
  `tcp_rmem` is sysctl-tunable and distributions differ; the *shape* of the
  finding (ceiling ≠ charge) is structural, the *numbers* are this host's.
- `sockstat`'s TCP `mem` is process-wide, not per-socket. With both ends local
  it cannot separate send-side from receive-side charge. A single-ended
  measurement across two processes would sharpen the per-connection receive
  figure; it was not needed to overturn the claim.
- N = 100 and 200 only. Higher N needs `ulimit -n` raised (the script assumes
  the caller has done so; the container run used 4096) and would exercise
  autotuning pressure this did not.

---

## Q1 — what should the read-buffer default be?

Not yet run. See `14-readbuf-default.ss` when it lands.

Q1 is the input to a *future* milestone — the one that changes
`default-read-buffer-size` — and unlike Q2 nothing about its answer has
shipped. v0.5 deliberately did not change the default and pinned the current
value with a test instead, precisely so that change could be made later on
evidence. Q1 produces that evidence.
