# TCP and streams

A TCP handle is one end of a TCP connection, or a server waiting for
connections. Reading, writing and shutting down are *stream* verbs: they
work the same way on a TCP handle and on a pipe
([processes.md](processes.md)).

Here is a server and a client on one loop. The client sends five bytes
and says it is done; the server prints what arrived.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))

;; The server: accept one connection, print what arrives, close on EOF.
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)            ; port 0: the kernel picks one
(define port (uv-tcp-getsockname-port server))

(uv-listen! server 16
  (lambda (err)
    (unless err
      (let ((conn (uv-accept! server)))
        (uv-read-start! conn
          (lambda (bv start end)                    ; on-data
            (display (list 'got (utf8->string bv) start end)) (newline))
          (lambda ()                                ; on-eof
            (display "peer finished\n")
            (uv-close! conn)
            (uv-close! server))
          (lambda (err)                             ; on-error
            (uv-close! conn)))))))

;; The client: connect, write, then shut down the write side.
(define client (make-uv-tcp loop))
(uv-tcp-connect! client "127.0.0.1" port
  (lambda (err)
    (unless err
      (uv-write! client (string->utf8 "hello") (lambda (err) #f))
      (uv-shutdown! client (lambda (err) (uv-close! client))))))

(uv-run loop 'default)
(uv-loop-teardown! loop)
```

It prints:

```
(got hello 0 5)
peer finished
```

[quickstart.md](quickstart.md) builds the same pieces into an echo
server.

## What to import

`(libuv)` gives you everything. If you want less, `(libuv tcp)` has the
TCP verbs and re-exports the six stream verbs (`uv-write!`, `uv-write*!`,
`uv-shutdown!`, `uv-read-start!`, `uv-read-stop!` and
`uv-stream-write-queue-size`), so a TCP program needs only that one
library. `(libuv stream)` has the stream verbs alone.

## The two sides

A server:

1. **Makes a handle** with [`make-uv-tcp`](reference.md#make-uv-tcp-procedure).
2. **Binds it** to an address and port with
   [`uv-tcp-bind!`](reference.md#uv-tcp-bind-procedure).
3. **Listens** with [`uv-listen!`](reference.md#uv-listen-procedure).
4. **Accepts** each connection with
   [`uv-accept!`](reference.md#uv-accept-procedure), inside the listen
   callback. That gives a new handle for the connection.
5. **Reads and writes** on the new handle, and closes it when done.

A client:

1. **Makes a handle** with `make-uv-tcp`.
2. **Connects** with
   [`uv-tcp-connect!`](reference.md#uv-tcp-connect-procedure).
3. **Reads and writes** once the connect callback says it worked.

## Bind

```scheme
(uv-tcp-bind! tcp ip port)
(uv-tcp-bind! tcp ip port flags)
```

- `ip` is an IPv4 or IPv6 literal, such as `"127.0.0.1"` or `"::1"`. A
  host name is not an address: `"localhost"` is refused with reason
  `bad-address`. To turn a name into an address, see [dns.md](dns.md).
- `port` is 0 to 65535. Port 0 asks the kernel to pick a free port. Read
  the one it picked with
  [`uv-tcp-getsockname-port`](reference.md#uv-tcp-getsockname-port-procedure).
- `flags` is a list. The only flag is `reuseport`, which binds with
  `SO_REUSEPORT`: several sockets share one port, and the kernel spreads
  connections across them. It needs libuv 1.49 or later; on an older one
  it raises `&uv-constant-unavailable`. On a platform whose libuv has no
  TCP reuseport (macOS, for one), libuv answers with an errno.

### Addresses are read once

`uv-tcp-bind!`, `uv-tcp-connect!` and
[`uv-getnameinfo!`](reference.md#uv-getnameinfo-procedure) copy the
address string at the start of the call, and hand libuv only the copy.
So changing the string afterwards changes nothing.

An address holding a NUL character is refused, with reason
`address-contains-nul`. C reads a string only up to its first NUL, so
`"127.0.0.1\x0;anything"` would otherwise quietly mean `127.0.0.1`.

If another thread changes the string *while* the copy is being taken, the
copy can hold some of its changes and not others. What libuv gets is
still checked for a NUL. A change an engine's timer handler makes on the
calling thread is either wholly in the copy or wholly out of it.

## Listen and accept

```scheme
(uv-listen! server backlog on-connection)
```

- `backlog` is how many connections the kernel may queue before you
  accept them. It is a C `int`: from 2^31 on it is refused with
  `backlog-out-of-range`.
- `on-connection` is called with one argument: `#f` when a connection is
  waiting, or a condition when listening failed.

Inside `on-connection`, call `uv-accept!`. It answers a new, open TCP
handle for that connection. The new handle is yours: read from it, write
to it, and close it when you are done.

## Connect

```scheme
(uv-tcp-connect! client ip port on-connect)
```

`on-connect` is called with `#f` when the connection is made, or with a
condition when it failed. The verb itself answers the request record,
which you can ignore.

A connect to a port where nothing listens fails in the callback, not at
the call:

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))

;; Find a port nobody listens on: bind, read the port, close.
(define probe (make-uv-tcp loop))
(uv-tcp-bind! probe "127.0.0.1" 0)
(define dead-port (uv-tcp-getsockname-port probe))
(uv-close! probe)
(uv-run loop 'default)

(define client (make-uv-tcp loop))
(uv-tcp-connect! client "127.0.0.1" dead-port
  (lambda (err)
    (display (if err (uv-errno-error-errno err) 'connected)) (newline)
    (uv-close! client)))
(uv-run loop 'default)
(uv-loop-teardown! loop)
```

It prints:

```
ECONNREFUSED
```

The condition is an `&uv-errno-error`. Branch on its errno, a symbol such
as `ECONNREFUSED` ([errors.md](errors.md)).

## Reading

```scheme
(uv-read-start! stream on-data on-eof on-error)
(uv-read-start! stream on-data on-eof on-error buffer-size)
```

All three callbacks are required. The loop calls one of them each time
something happens on the stream:

| Callback   | Arguments        | When                                         |
|:-----------|:-----------------|:---------------------------------------------|
| `on-data`  | `bv start end`   | bytes arrived                                |
| `on-eof`   | none             | the peer finished sending                    |
| `on-error` | `err`            | the read failed; `err` is a condition object |

**`on-data` gets a fresh bytevector every time.** The bytes are copied
out of the read buffer before your callback runs, so you can keep `bv`
as long as you like. The data is the span from `start` up to, not
including, `end`, like every R6RS range.

**End of file is not an error.** It has its own callback, with no
arguments, and is never wrapped in a condition.

**A read error does not close the stream.** It reaches `on-error` as a
condition object, not as a raise. What to do next is your decision; most
programs close the stream.

**Nothing closes the stream for you.** Not EOF and not an error. Call
[`uv-close!`](reference.md#uv-close-procedure) when you are done.

[`uv-read-stop!`](reference.md#uv-read-stop-procedure) stops reading. The
stream keeps its callbacks and its read buffer, so a later
`uv-read-start!` picks up where it left off. Stopping a stream that is not
reading does nothing. Stopping and starting is how you push back on a
peer that sends faster than you can process: see
[flow-control.md](flow-control.md).

The optional `buffer-size` sets the size of the stream's read buffer, in
bytes. It defaults to 65536 and is fixed by the first start.
[flow-control.md](flow-control.md) explains how to choose it.

## Writing

```scheme
(uv-write! stream bv on-complete)
(uv-write! stream bv start end on-complete)
```

The first form writes the whole bytevector. The second writes the span
from `start` up to, not including, `end`.

`on-complete` is called once, with `#f` when the write finished, or with a
condition when it failed. The verb answers the request record.

**`uv-write!` copies your bytes during the call.** Once it returns, the
bytevector is yours again: change it, reuse it, or drop it.

```scheme
(let ((buf (string->utf8 "original")))
  (uv-write! client buf (lambda (err) #f))
  ;; uv-write! has already copied buf, so reusing it is safe.
  (bytevector-fill! buf (char->integer #\x)))
```

The server on the other end printed:

```
original
```

The copy runs at `memcpy` speed. On a threaded Chez, which is the only
kind this library runs on, the whole call holds off other threads'
garbage collections: the copy, and libuv's own write, which on an idle
socket hands the kernel as much as it will take before returning. That
matters only for single writes of a MiB or more. On macOS loopback it was
0.2 to 0.9 ms for 1 MiB, and 2.4 to 4.4 ms for 4 MiB.

A finished write means the bytes reached your own socket. It does not
mean the peer has read them.

### Writing several pieces at once

`uv-write*!` sends a list of
*segments* as one write. Each segment is a bytevector or a
`(bv start end)` span.

```scheme
(let ((msg (string->utf8 "--hello--")))
  ;; a span: bytes 2 up to (not including) 7
  (uv-write! client msg 2 7 (lambda (err) #f))
  ;; three segments, one request, one completion
  (uv-write*! client
              (list (string->utf8 ", ")
                    (list msg 2 7)
                    (string->utf8 "!"))
              (lambda (err) (display (list 'write*-done err)) (newline))))
```

From [this program](#a-program-with-every-verb) it prints, and the server
receives:

```
(write*-done #f)
(received hello, hello!)
```

- All the segments are copied into one block during the call, and sent as
  one libuv write. You get **one** completion for the whole list.
- The list must not be empty: `'()` is refused with `empty-segment-list`.
- The list is read once. If another thread or an engine's timer handler
  changes it once during the call, the write uses the list as it was, or
  as the change left it, or refuses it. A span whose bytevector shrank
  before the copy is refused with `segment-span-out-of-range`.

> ⚠️ A list changed **more than once** during the call can be written as
> a mix of its versions: bytes from no single version of your list reach
> the peer. Do not change a segment list while another thread may be
> writing it.

## Shutdown

```scheme
(uv-shutdown! stream on-shutdown)
```

[`uv-shutdown!`](reference.md#uv-shutdown-procedure) closes the write side
of the stream. The peer sees EOF. Your read side stays open, so you can
still receive the peer's answer. `on-shutdown` gets `#f` or a condition.

In the first example the client shut down right after its write, and the
server still got the bytes first, then EOF.

Shutdown does not close the handle. Close it too, usually from
`on-shutdown`.

## Socket options

[`uv-tcp-nodelay!`](reference.md#uv-tcp-nodelay-procedure) turns
`TCP_NODELAY` on or off. It takes a boolean, not a number: Scheme's `0` is
true, so `1` and `0` are refused with `enable-not-a-boolean`.

```scheme
(uv-tcp-nodelay! client #t)
```

[`uv-tcp-keepalive!`](reference.md#uv-tcp-keepalive-procedure) turns
`SO_KEEPALIVE` on or off. To turn it on you must give the idle delay, in
whole seconds, above 0 and below 2^32.

```scheme
(uv-tcp-keepalive! client #t 60)   ; on, after 60 idle seconds
(uv-tcp-keepalive! client #f)      ; off
```

## Socket and peer addresses

Both verbs answer two values: the address as a string (or `#f`), and the
port.

- [`uv-tcp-sockname-address`](reference.md#uv-tcp-sockname-address-procedure)
  is this end's own address. A handle has one as soon as it is bound,
  connected or not.
- [`uv-tcp-peer-address`](reference.md#uv-tcp-peer-address-procedure) is
  the other end's. It needs a connection.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define tcp (make-uv-tcp loop))

(define (errno-of thunk)
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e)))
    (thunk)
    'no-raise))

(display (errno-of (lambda () (uv-tcp-peer-address tcp)))) (newline)
(uv-tcp-bind! tcp "::1" 0)
(let-values (((host port) (uv-tcp-sockname-address tcp)))
  (display (list host (= port (uv-tcp-getsockname-port tcp)))) (newline))
(display (errno-of (lambda () (uv-tcp-peer-address tcp)))) (newline)
(uv-loop-teardown! loop)
```

It prints:

```
EBADF
(::1 #t)
ENOTCONN
```

A handle with no socket yet has no peer (`EBADF`), and nor does a bound
one with no connection (`ENOTCONN`).

## Closing

[`uv-close!`](reference.md#uv-close-procedure) starts the close. The
loop finishes it on its next run, and only then frees the handle's
memory and its read buffer. Closing twice does nothing.

A request still pending when you close its stream still gets its
callback. What it gets depends on how far it got:

- **A write still queued**, with bytes libuv has not yet handed to the
  kernel, completes with `ECANCELED`. So do a pending shutdown and a
  pending connect.
- **A small write the kernel already took** completes with `#f`, even
  when you close before its callback ran. The kernel already had its
  bytes.

This program writes 16 MiB to a peer that never reads, then closes:

```scheme
(display (list 'before (uv-stream-write-queue-size client))) (newline)
(uv-write! client (make-bytevector (* 16 1024 1024) 0)
           (lambda (err)
             (display (list 'write-finished (and err (uv-errno-error-errno err))))
             (newline)))
(display (list 'queued-after-write (positive? (uv-stream-write-queue-size client))))
(newline)

;; Close with the write still queued: its callback still runs, with an error.
(uv-close! client)
(uv-close! conn)
(uv-close! server)
(uv-run loop 'default)
```

It prints:

```
(before 0)
(queued-after-write #t)
(write-finished ECANCELED)
```

> ⚠️ Closing a stream cancels the writes still queued on it. Each gets
> `ECANCELED`, and the peer may never get the bytes that had not left. To be sure
> everything was sent, close only after the last write's `on-complete`
> has reported `#f`.

A verb on a closed stream raises `&uv-handle-closed`. It never touches
the freed memory.

## A program with every verb

The `uv-write*!` fragment under [Writing](#writing) comes from this
program. It also sets the socket options and shows both ends' addresses.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(define port (uv-tcp-getsockname-port server))
(define received '())

(uv-listen! server 16
  (lambda (err)
    (unless err
      (let ((conn (uv-accept! server)))
        (let-values (((host p) (uv-tcp-peer-address conn)))
          (display (list 'server-sees host)) (newline))
        (uv-read-start! conn
          (lambda (bv start end) (set! received (cons (utf8->string bv) received)))
          (lambda ()
            (display (list 'received (apply string-append (reverse received))))
            (newline)
            (uv-close! conn)
            (uv-close! server))
          (lambda (err) (uv-close! conn)))))))

(define client (make-uv-tcp loop))
(uv-tcp-connect! client "127.0.0.1" port
  (lambda (err)
    (unless err
      (uv-tcp-nodelay! client #t)
      (uv-tcp-keepalive! client #t 60)
      (let-values (((host p) (uv-tcp-sockname-address client)))
        (display (list 'client-is host (integer? p))) (newline))
      (let-values (((host p) (uv-tcp-peer-address client)))
        (display (list 'client-peer host (= p port))) (newline))
      (let ((msg (string->utf8 "--hello--")))
        ;; a span: bytes 2 up to (not including) 7
        (uv-write! client msg 2 7 (lambda (err) #f))
        ;; three segments, one request, one completion
        (uv-write*! client
                    (list (string->utf8 ", ")
                          (list msg 2 7)
                          (string->utf8 "!"))
                    (lambda (err) (display (list 'write*-done err)) (newline))))
      (uv-shutdown! client (lambda (err) (uv-close! client))))))

(uv-run loop 'default)
(uv-loop-teardown! loop)
```

It prints:

```
(server-sees 127.0.0.1)
(client-is 127.0.0.1 #t)
(client-peer 127.0.0.1 #t)
(write*-done #f)
(received hello, hello!)
```

## Engines and stream verbs

You can skip this section unless you run code inside Chez engines, which
can pause a computation part way and resume it later, or never.

An engine can run out of fuel in the middle of a stream verb. While it is
paused, your scheduler might close the stream, hand the loop to another
thread, or drop the engine for good. The verbs are built for that:

- Each verb makes its checks, its allocation and its call into libuv in
  one step that an engine cannot split.
- A verb resumed after its stream was closed raises `&uv-handle-closed`,
  and does not touch the stream.
- A verb resumed after its loop moved to another thread raises
  `&uv-wrong-thread`.
- A verb whose engine is never resumed leaves nothing behind. Either it
  had not begun, or libuv holds its request, and the request's completion
  frees it.

`uv-tcp-connect!`, `uv-tcp-bind!`, `uv-listen!`, the address queries,
`uv-tcp-nodelay!`, `uv-tcp-keepalive!` and the buffer-size verbs make the
same promises.

`make-uv-tcp` and `uv-accept!` make the same promises when resumed, but
not when dropped. Each makes its handle in one step, and an engine
dropped after that step leaves the handle made, registered on the loop,
and never handed to you. You cannot close a handle you never got, so it
stays open until the loop's teardown closes it.

> ⚠️ An engine dropped inside `uv-accept!` after its step leaves an
> accepted connection your program never sees. It stays open until the
> loop's teardown closes it.

> ⚠️ An engine dropped while it is inside a callback leaves that callback
> the way an escaping continuation does, and costs the same: its thread's
> stack and a little heap, for good. [callbacks.md](callbacks.md) has the
> numbers and the rules for resuming engines safely.

> ⚠️ `uv-close!` checks no thread. Do not hand a loop to another thread
> while an engine is paused inside `uv-close!` on one of its handles: when
> resumed, it would close the handle from a thread that does not own the
> loop.

## Mistakes the verbs refuse

Each verb checks its arguments before it does anything, and raises
`&uv-invalid-argument` with a reason symbol. Nothing is allocated.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define tcp (make-uv-tcp loop))
(define timer (make-uv-timer loop))

(define (reason thunk)
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
    (thunk)
    'no-raise))

(display (reason (lambda () (uv-tcp-bind! tcp "localhost" 0)))) (newline)
(display (reason (lambda () (uv-tcp-bind! tcp "127.0.0.1\x0;junk" 0)))) (newline)
(display (reason (lambda () (uv-tcp-bind! tcp "127.0.0.1" 70000)))) (newline)
(display (reason (lambda () (uv-tcp-nodelay! tcp 1)))) (newline)
(display (reason (lambda () (uv-tcp-keepalive! tcp #t)))) (newline)
(display (reason (lambda () (uv-write*! tcp '() (lambda (err) #f))))) (newline)
(display (reason (lambda () (uv-write! timer (make-bytevector 1) (lambda (err) #f))))) (newline)
(uv-loop-teardown! loop)
```

It prints:

```
bad-address
address-contains-nul
port-out-of-range
enable-not-a-boolean
delay-required-when-enabling
empty-segment-list
not-a-uv-stream
```

A few more you may meet: `span-out-of-range` (a `uv-write!` span past the
bytevector's end), `delay-out-of-range` (a keepalive delay of 0 or
2^32 and above), `unknown-bind-flag`, `backlog-out-of-range`, and
`not-a-uv-tcp` (a TCP verb given a pipe or another handle).
[errors.md](errors.md) lists the condition types.

## Read next

- [flow-control.md](flow-control.md): buffers, the write queue, and
  pausing reads.
- [dns.md](dns.md): turning a host name into an address to connect to.
- [callbacks.md](callbacks.md): what your callbacks may do.
- [threads.md](threads.md): which thread may call these verbs.
