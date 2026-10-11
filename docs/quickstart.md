# Quickstart

In this page you build an echo server: a program that sends back every
byte it receives. You also build a client that talks to it. Both live in
one program, on one event loop.

It takes five small steps. At the end are the three rules that every
program here depends on.

## Before you start

Build the native part once, from the repository's root
([installing.md](installing.md) has the details):

```sh
make build
```

Then run each program in this page with `src` on Chez's library path:

```sh
CHEZSCHEMELIBDIRS=src chez --program echo.sps
```

Your Chez may be called `scheme` instead of `chez`.

## Make a loop

A loop waits for things to happen, and calls your procedures when they
do. Everything in this library starts with one.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(display (uv-run loop 'default))   ; nothing to do, so it returns at once
(newline)
(uv-loop-teardown! loop)
```

It prints:

```
#f
```

1. [`make-uv-loop`](reference.md#make-uv-loop-procedure) makes the loop.
2. [`uv-run`](reference.md#uv-run-procedure) runs it until it has nothing
   left to do. It answers `#f` when no work remains.
3. [`uv-loop-teardown!`](reference.md#uv-loop-teardown-procedure) frees it.
   Nothing frees a loop for you, so you always end with this.

[loops.md](loops.md) covers loops in full.

## Listen for connections

A server is a TCP handle that is bound to an address and listening.

```scheme
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)          ; port 0: let the kernel choose
(define port (uv-tcp-getsockname-port server))

(uv-listen! server 128
            (lambda (err)
              (display "a client connected\n")))
```

- Port 0 asks the kernel for any free port.
  `uv-tcp-getsockname-port` tells you which one it chose.
- The procedure you give `uv-listen!` is a *callback*. The loop calls it
  each time a client connects. `err` is `#f`, or a condition saying what
  went wrong.

Nothing has connected yet. Nothing can, until the loop runs.

## Echo what arrives

Now give `uv-listen!` a callback that does the work. When a client
connects, accept it and start reading. Write back every piece you read.

```scheme
(uv-listen! server 128
            (lambda (err)
              (unless err
                (let ((peer (uv-accept! server)))
                  (uv-read-start!
                   peer
                   (lambda (bv start end)              ; on-data
                     (uv-write! peer bv start end (lambda (err) #f)))
                   (lambda ()                          ; on-eof
                     (uv-shutdown! peer (lambda (err) (uv-close! peer))))
                   (lambda (err)                       ; on-error
                     (uv-close! peer)))))))
```

`uv-read-start!` takes three callbacks:

| Callback   | Called when        | What this one does                      |
|:-----------|:-------------------|:----------------------------------------|
| `on-data`  | bytes arrive       | writes the same bytes back              |
| `on-eof`   | the client is done | shuts down our side, then closes the peer |
| `on-error` | reading failed     | closes the peer                         |

`on-data` gets a bytevector and a span of it, from `start` up to (not
including) `end`. `uv-write!` sends that span. It copies the bytes before
it returns, so the bytevector stays yours.

[tcp.md](tcp.md) covers reading and writing in full.

## Connect a client

The client is another TCP handle, on the same loop.

```scheme
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
```

Once it is connected, the client starts reading and sends one line. When
the echo comes back, it saves the text, then shuts down and closes
everything. (`span->bytevector` copies a span into a new bytevector; it is
in the whole program below.)

Closing the server matters. A listening server waits for clients for
ever, so while it is open the loop never runs out of work.

## Run the loop and clean up

```scheme
(uv-run loop 'default)      ; every callback above runs in here
(uv-loop-teardown! loop)

(display echoed)
```

Every callback runs inside `uv-run`, and nowhere else. `uv-run` returns
when nothing is left to do: here, once every handle has closed.

## The whole program

```scheme
(import (rnrs) (libuv))

;; Copy the bytes from start up to end into a new bytevector.
(define (span->bytevector bv start end)
  (let ((out (make-bytevector (- end start))))
    (bytevector-copy! bv start out 0 (- end start))
    out))

(define loop (make-uv-loop))
(define echoed #f)

;; The server: send back whatever arrives, and close when the client is done.
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
                   (lambda ()                          ; on-eof
                     (uv-shutdown! peer (lambda (err) (uv-close! peer))))
                   (lambda (err)                       ; on-error
                     (uv-close! peer)))))))

;; The client, on the same loop.
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

(uv-run loop 'default)      ; every callback above runs in here
(uv-loop-teardown! loop)

(display echoed)
```

It prints:

```
hello, libuv
```

## The three rules

That program depends on three rules.

### A close is asynchronous

[`uv-close!`](reference.md#uv-close-procedure) only *starts* a close. The
handle stays `closing` until the loop runs again and finishes it. Only
then is its memory freed.

```scheme
(define timer (make-uv-timer loop))

(uv-close! timer)
(display (uv-handle-state timer)) (newline)   ; the close has only started
(uv-run loop 'default)
(display (uv-handle-state timer)) (newline)   ; the loop finished it
```

It prints:

```
closing
closed
```

The garbage collector frees nothing here. A handle you never close stays
allocated until its loop is torn down.

### EOF is not an error

The end of the stream has its own callback, `on-eof`, which takes no
arguments. It is never wrapped in a condition.

A read *error* goes to `on-error`, as a condition object. It is handed to
you, not raised. It does not close the handle either: what to do about it
is your decision. The echo server closes the peer.

### A callback that raises does not cross into C

Your callbacks are called from libuv's C code, and a Scheme raise must not
pass through C. So the library catches the raise. It stores the first
one, stops the loop, and raises it again from `uv-run`.

What `uv-run` raises is your own condition, combined with
[`&uv-callback-error`](reference.md#uv-callback-error-condition-type). A
`guard` written for your own condition type still matches:

```scheme
(define timer (make-uv-timer loop))
(uv-timer-start! timer
                 (lambda (t) (assertion-violation 'on-timeout "bad state"))
                 0 0)

(guard (e ((assertion-violation? e)
           (display (list 'caught (condition-message e)
                          'callback-error? (uv-callback-error? e)))
           (newline)))
  (uv-run loop 'default))
```

It prints:

```
(caught bad state callback-error? #t)
```

Raises after the first, in the same run, are kept for you to read
([callbacks.md](callbacks.md#when-a-callback-raises)). A raise is one of
the two ways a callback can end a run early. The other is
[`uv-stop!`](reference.md#uv-stop-procedure).

> ⚠️ **A callback ends only by returning.** Never leave one with a
> continuation, such as an escape from `call/cc`. The loop stays marked
> running for good: you can no longer run it, close it or tear it down,
> and its memory is never freed. [callbacks.md](callbacks.md#escapes)
> explains why, and the one exception.

## Read next

- [loops.md](loops.md): running, stopping and tearing down a loop.
- [callbacks.md](callbacks.md): what a callback may do, and what happens
  when it raises.
- [tcp.md](tcp.md): servers, clients, reading and writing.
- [threads.md](threads.md): loops and threads.
