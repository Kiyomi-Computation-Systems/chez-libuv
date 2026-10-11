# Flow control

Flow control is keeping memory in check when data arrives faster than you
can handle it, or when you write faster than the peer reads. chez-libuv
has no policy of its own for this. It gives you the switches and the
gauges, and this page shows how to use them.

The main switch is on the read side: stop reading when you are busy, and
start again when you are ready. The kernel holds what arrives in between,
and the peer slows down.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(define port (uv-tcp-getsockname-port server))
(define received 0)
(define pauses 0)

(define (serve conn)
  (define resume (make-uv-timer loop))
  (define (on-data bv start end)
    (set! received (+ received (- end start)))
    ;; Pretend each delivery takes a while to process: stop reading,
    ;; and start again 5 ms later. The kernel holds what arrives meanwhile.
    (when (uv-handle-open? conn)
      (uv-read-stop! conn)
      (set! pauses (+ pauses 1))
      (uv-timer-start! resume
                       (lambda (t)
                         (when (uv-handle-open? conn)
                           (uv-read-start! conn on-data on-eof on-error)))
                       5 0)))
  (define (on-eof)
    (uv-close! resume) (uv-close! conn) (uv-close! server))
  (define (on-error err)
    (uv-close! resume) (uv-close! conn) (uv-close! server))
  (uv-read-start! conn on-data on-eof on-error 16384))

(uv-listen! server 16
  (lambda (err) (unless err (serve (uv-accept! server)))))

(define client (make-uv-tcp loop))
(uv-tcp-connect! client "127.0.0.1" port
  (lambda (err)
    (unless err
      (uv-write! client (make-bytevector (* 1024 1024) 1) (lambda (err) #f))
      (uv-shutdown! client (lambda (err) (uv-close! client))))))

(uv-run loop 'default)
(uv-loop-teardown! loop)
(display (list 'received received 'paused-at-least-64-times (>= pauses 64)))
(newline)
```

It prints:

```
(received 1048576 paused-at-least-64-times #t)
```

All 1 MiB arrived, in pieces of at most 16 KiB, with a pause after each.

## Three buffers with confusable names

Each connection has three buffers. They are independent: setting one does
not change the others. In particular, setting the kernel's receive buffer
(`SO_RCVBUF`) does not resize chez-libuv's read buffer, or the other way
round.

| Buffer                 | Set by                                 | Freed by                    | Typical size                              |
|:-----------------------|:---------------------------------------|:----------------------------|:------------------------------------------|
| chez-libuv read buffer | the first `uv-read-start!`, for good   | the stream's close          | 64 KiB by default                         |
| kernel send buffer     | `uv-send-buffer-size!`                 | the kernel, at socket close | tens of KB, tunable                       |
| kernel receive buffer  | `uv-recv-buffer-size!`                 | the kernel, at socket close | a ceiling, autotuned; see below           |

## The read buffer

Every stream that reads has one buffer that libuv reads into. Each
delivery is then copied out of it into a fresh bytevector for your
`on-data`.

1. **The first `uv-read-start!` makes it.** Its optional fifth argument is
   the size in bytes. Leave it out and you get 65536, libuv's own
   suggestion.
2. **The size is fixed from then on.** A later `uv-read-start!` with a
   different size raises `&uv-invalid-argument`, reason
   `buffer-size-fixed`. One with the same size, or with no size, is always
   accepted. That keeps `uv-read-stop!` then `uv-read-start!` cheap.
3. **The close frees it.** Not stopping, not EOF: only the close.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(define port (uv-tcp-getsockname-port server))
(define (ignore . args) #f)

(define (reason thunk)
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
    (thunk)
    'accepted))

(uv-listen! server 16
  (lambda (err)
    (let ((conn (uv-accept! server)))
      ;; The first start fixes the buffer at 4096 bytes until close.
      (uv-read-start! conn ignore ignore ignore 4096)
      (uv-read-stop! conn)
      (uv-read-stop! conn)                      ; stopping twice is fine
      (display (reason (lambda () (uv-read-start! conn ignore ignore ignore)))) (newline)
      (uv-read-stop! conn)
      (display (reason (lambda () (uv-read-start! conn ignore ignore ignore 4096)))) (newline)
      (uv-read-stop! conn)
      (display (reason (lambda () (uv-read-start! conn ignore ignore ignore 65536)))) (newline)
      (uv-close! conn)
      (uv-close! server))))

(define client (make-uv-tcp loop))
(uv-tcp-connect! client "127.0.0.1" port (lambda (err) (uv-close! client)))
(uv-run loop 'default)
(uv-loop-teardown! loop)
```

It prints:

```
accepted
accepted
buffer-size-fixed
```

> ⚠️ The read buffer is committed the moment `uv-read-start!` runs,
> whether or not a byte ever arrives, and it stays until the stream
> closes. A stream that never closes keeps its buffer for good.

### Choosing its size

The size is a trade, not a recommendation. These numbers were measured on
Debian bookworm (aarch64). The figures belong to that host, but the shape
holds elsewhere.

**Memory grows with the size, linearly.** This is the cost that clearly
differs:

| Buffer size | 200 connections | Extrapolated to 10,000 |
|------------:|----------------:|-----------------------:|
| 4096        | ~1.2 MiB        | ~40 MiB                |
| 16384       | ~3.1 MiB        | ~160 MiB               |
| 65536       | ~12.4 MiB       | ~625 MiB               |

**The costs of a small buffer are small.** Moving 16 MiB through one
socket:

- A 4 KiB buffer gave 16 times as many `on-data` calls as a 64 KiB one,
  as you would expect.
- Garbage collection stayed at two or three collections at every size,
  each under a millisecond.
- The 16 MiB drained in a median of 13.6 ms at 4096, 10.0 ms at 16384 and
  8.6 ms at 65536. So 4 KiB took about 1.6 times as long as 64 KiB, about
  1.3 µs per extra delivery.

The total bytes allocated do not change with the size: each delivery
allocates exactly as many bytes as arrived. Only the number of
bytevectors changes.

**Two limits on those numbers.**

- The measurement threw every delivery away. A copying collector charges
  for what *survives*, so a program that **keeps** deliveries across
  reads, as any protocol reassembler holding fragments does, was not
  measured. That is where a cost from the number of objects would first
  show.
- The buffer only sets the delivery size for reads that fill it. With
  small messages, what arrives sets the size, and the buffer does not
  change the object count at all.

**In practice:**

- Many connections carrying small messages: a smaller buffer is close to
  free, and the saving is linear. 4096 or 16384 are reasonable there.
- Bulk transfer: keep 64 KiB. The memory is spread over far fewer
  connections, and the per-delivery time shows.
- If you keep deliveries across reads, treat the question as open.

The default stays 65536 whatever the traffic. Choose a smaller size per
stream, at its first `uv-read-start!`.

## Pausing reads

[`uv-read-stop!`](reference.md#uv-read-stop-procedure) is your
backpressure. It keeps the stream's callbacks and buffer, so the next
[`uv-read-start!`](reference.md#uv-read-start-procedure) can leave out the
size. Stopping a stream that is already stopped does nothing.

There is one trap. A delivery already on its way can still reach
`on-data` after the stream began to close. `uv-read-stop!`, like every
stream verb, refuses a stream that is not open, so a stop made from that
late `on-data` raises. Guard it:

```scheme
(when (uv-handle-open? stream)
  (uv-read-stop! stream))
```

The example at the top of the page does this, and also checks before it
starts reading again.

> ⚠️ While you are not reading, the kernel keeps accepting the peer's
> bytes into its receive buffer. With data pushed and never read, the
> kernel charged about 530 KiB per connection on the measured host, and
> in principle the charge has no bound. Pausing is for a while, not for
> good: a peer you will not read from again should be closed.

## Bounding write memory

Every `uv-write!` takes a block of foreign memory: its request plus a copy
of its payload. The block is held until the write completes. Nothing
limits how many you queue, so a fast writer and a slow peer pile up
memory.

> ⚠️ Queued writes are unbounded. A program that writes to a slow peer
> without counting what is in flight can grow its memory without limit.

Two facts make bytes alone a poor bound:

- **A zero-length write still takes a full request block**, while adding
  no payload bytes.
- **A `uv-write*!` is one request**, with one completion. Its payload is
  the sum of its segments.

So to bound write memory, count both:

1. **Payload bytes in flight**, and
2. **Writes in flight.**

Add to each only **after** `uv-write!` returns. A write that fails at the
call raises, gets no completion callback, and queued nothing. Subtract
from both in the matching `on-complete`.

This writer never has more than 256 KiB or 8 writes in flight:

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(define port (uv-tcp-getsockname-port server))
(define received 0)

(uv-listen! server 16
  (lambda (err)
    (unless err
      (let ((conn (uv-accept! server)))
        (uv-read-start! conn
          (lambda (bv start end) (set! received (+ received (- end start))))
          (lambda () (uv-close! conn) (uv-close! server))
          (lambda (err) (uv-close! conn) (uv-close! server)))))))

;; A writer that never has more than 256 KiB or 8 writes in flight.
(define max-bytes (* 256 1024))
(define max-writes 8)
(define chunk (make-bytevector (* 64 1024) 7))
(define to-send 100)               ; chunks left to write
(define bytes-out 0)               ; payload bytes in flight
(define writes-out 0)              ; requests in flight
(define peak-bytes 0)

(define client (make-uv-tcp loop))

(define (pump!)
  (when (and (> to-send 0)
             (< writes-out max-writes)
             (<= (+ bytes-out (bytevector-length chunk)) max-bytes))
    (uv-write! client chunk on-written)
    ;; Count only after uv-write! returned: a write that raised queued nothing.
    (set! bytes-out (+ bytes-out (bytevector-length chunk)))
    (set! writes-out (+ writes-out 1))
    (set! peak-bytes (max peak-bytes bytes-out))
    (set! to-send (- to-send 1))
    (pump!))
  (when (and (= to-send 0) (= writes-out 0))
    (uv-shutdown! client (lambda (err) (uv-close! client)))))

(define (on-written err)
  (set! bytes-out (- bytes-out (bytevector-length chunk)))
  (set! writes-out (- writes-out 1))
  (if err
      (uv-close! client)
      (pump!)))

(uv-tcp-connect! client "127.0.0.1" port
  (lambda (err) (unless err (pump!))))

(uv-run loop 'default)
(uv-loop-teardown! loop)
(display (list 'received received 'peak-in-flight peak-bytes)) (newline)
```

It prints:

```
(received 6553600 peak-in-flight 262144)
```

## The write queue gauge

[`uv-stream-write-queue-size`](reference.md#uv-stream-write-queue-size-procedure)
answers how many bytes of queued writes libuv is holding for a stream.
It allocates nothing, so you can call it as often as you like.

It is libuv's own counter, not chez-libuv's, and its meaning depends on
the platform. On Linux and macOS it counts bytes not yet handed to the
kernel. After a write *fails*, it deliberately stays above 0, so that you
stop writing instead of retrying blind.

This program writes 16 MiB to a peer that never reads:

```scheme
(display (list 'before (uv-stream-write-queue-size client))) (newline)
(uv-write! client (make-bytevector (* 16 1024 1024) 0)
           (lambda (err)
             (display (list 'write-finished (and err (uv-errno-error-errno err))))
             (newline)))
(display (list 'queued-after-write (positive? (uv-stream-write-queue-size client))))
(newline)
```

It prints, before closing the stream:

```
(before 0)
(queued-after-write #t)
```

Treat the gauge as **a congestion signal**:

- It is not a memory gauge. The two counts above are what bound memory.
- It is not a portable measure of what the kernel holds. A threshold
  needs tuning for your platform and your traffic.
- It is not a health check. A write's `on-complete` status is the answer
  to "is this stream healthy".

## Kernel buffers

The kernel keeps its own send and receive buffers for each socket. Four
verbs read and set them, in bytes:

- [`uv-send-buffer-size`](reference.md#uv-send-buffer-size-procedure)
  and `uv-send-buffer-size!` for `SO_SNDBUF`;
- [`uv-recv-buffer-size`](reference.md#uv-recv-buffer-size-procedure)
  and `uv-recv-buffer-size!` for `SO_RCVBUF`.

They take a TCP handle or a pipe; anything else is refused with
`not-a-socket-handle`. The handle needs a socket, so bind or connect it
first: on a fresh TCP handle they raise an `&uv-errno-error` whose errno
is `EBADF`. A size must be a positive
exact integer below 2^31, or it is refused with
`buffer-size-out-of-range`.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define tcp (make-uv-tcp loop))
(uv-tcp-bind! tcp "127.0.0.1" 0)     ; the socket exists once it is bound

(display (list 'send (uv-send-buffer-size tcp) 'recv (uv-recv-buffer-size tcp)))
(newline)
(uv-send-buffer-size! tcp 262144)
(display (list 'asked 262144 'got (uv-send-buffer-size tcp)))
(newline)
(display
 (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
   (uv-send-buffer-size! tcp 0)
   'no-raise))
(newline)
(display
 (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
   (uv-send-buffer-size (make-uv-timer loop))
   'no-raise))
(newline)
(uv-loop-teardown! loop)
```

On one Linux host it printed:

```
(send 16384 recv 131072)
(asked 262144 got 524288)
buffer-size-out-of-range
not-a-socket-handle
```

### A setter only asks

A setter's argument is a request, not an assignment. The kernel is free
to change it. Linux first caps the size you ask for at the
`net.core.wmem_max` or `net.core.rmem_max` sysctl, then doubles it, and
raises the result to a minimum. So the answer can be twice the cap. That
is why asking for 262144 above read back as 524288.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define tcp (make-uv-tcp loop))
(uv-tcp-bind! tcp "127.0.0.1" 0)
(for-each (lambda (n)
            (uv-send-buffer-size! tcp n)
            (display (list 'asked n 'got (uv-send-buffer-size tcp)))
            (newline))
          '(1 262144 4194304 16777216))
(uv-loop-teardown! loop)
```

On one Linux host, with `net.core.wmem_max` at 4194304, it printed:

```
(asked 1 got 4608)
(asked 262144 got 524288)
(asked 4194304 got 8388608)
(asked 16777216 got 8388608)
```

It is not a broken binding: read the getter's answer as the kernel's
decision.

### The receive buffer is a ceiling

`SO_RCVBUF` is the most the kernel will hold for a socket, not memory it
has already charged. The difference matters. Measured on Debian bookworm
(aarch64, libuv 1.52.1), per connection:

| What                                            | Bytes          | Against a 64 KiB read buffer   |
|:------------------------------------------------|:---------------|:-------------------------------|
| `SO_RCVBUF` as reported                         | 131072         | 2×: the ceiling                |
| kernel memory charged, connection idle          | ~11–15 KiB     | ~0.2×: five times smaller      |
| kernel memory charged, data pushed, never read  | ~530 KiB       | ~8×, and unbounded in principle |

So the receive buffer is close to free at rest. It becomes the largest
cost exactly when you stop reading. What decides which case you are in is
how you handle backpressure, not how many connections you have.

The chez-libuv read buffer is the other way round. At rest it is the
larger of the two, by about five times: 65536 bytes committed at the
first `uv-read-start!` and kept until close.

The kernel's default receive size (`tcp_rmem[1]`) was 131072 on the
measured host. A commonly quoted 87 KB is an older default. Both are
sysctl settings, so measure on the kernel you deploy to.

## Read next

- [tcp.md](tcp.md): the stream verbs themselves.
- [callbacks.md](callbacks.md): what happens when a callback raises.
- [errors.md](errors.md): the conditions these verbs raise.
