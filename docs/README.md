# chez-libuv

R6RS bindings to [libuv](https://libuv.org) for Chez Scheme: an event loop,
timers, TCP, DNS, child processes, pipes, signals, and wakeups from other
threads.

libuv is the C library under Node.js. It waits for many things at once, such
as sockets, timers, children and signals, and calls you back when one of them
is ready. chez-libuv lets a Scheme program do the same. The names follow
libuv's own verbs (`accept`, `read-start`, `write`, `timer`, `spawn`,
`close`), so if you know libuv you will recognise them.

⚠️ **This is not a web server.** You can use it to *build* a server, or
anything that needs async I/O using libuv. This library powers
[chez-http-server](https://github.com/Kiyomi-Computation-Systems/chez-http-server).

It moves bytes and nothing more. It parses no protocol and has no policy of
its own about connections or backpressure: those belong to the code you build
on top.

💡 These pages are Markdown in the repository's [docs](../docs) directory,
rendered by [chez-cmark-gfm](https://github.com/Kiyomi-Computation-Systems/chez-cmark-gfm).

## A taste

A timer that fires three times, 100 ms apart, then closes itself:

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define timer (make-uv-timer loop))
(define fires 0)

(uv-timer-start! timer
                 (lambda (t)                 ; called with the timer
                   (set! fires (+ fires 1))
                   (display "tick ") (display fires) (newline)
                   (when (= fires 3)
                     (uv-close! t)))
                 0 100)                      ; first fire now, then every 100 ms

(uv-run loop 'default)                       ; callbacks run here, and only here
(display "the loop has nothing left to do\n")
(uv-loop-teardown! loop)
```

It prints:

```text
tick 1
tick 2
tick 3
the loop has nothing left to do
```

`uv-run` returns once nothing is left to wait for. The closed timer was the
last thing, so the run ends.

## Four ideas to keep in mind

- **Callbacks run only inside `uv-run`.** Nothing happens behind your back,
  on another thread or at some random moment.
- **You close what you open.** A handle stays open until you close it. No
  finalizer cleans up for you, so a handle's whole life is visible in your
  code.
- **Bytes are copied at the edge.** A read gives you a fresh bytevector, and a
  write copies your bytes before libuv sees them. C never holds on to a
  Scheme object.
- **Errors have names.** A libuv error arrives as a symbol such as
  `'ECONNREFUSED`, inside an R6RS condition you can catch.

## Read next

- [Installing](installing.md): what you need, building the native shim, and
  importing `(libuv)` from your own project.
- [Quickstart](quickstart.md): an echo server, start to finish, and the three
  rules every program follows.
- [The event loop](loops.md): making, running, stopping and tearing down a
  loop.
- [Callbacks](callbacks.md): what a callback may do, what a raise does, and
  what leaving one early costs.
- [Threads](threads.md): one thread per loop, handing a loop over, and waking
  a loop from another thread.
- [Timers](timers.md): one-shot and repeating timers.
- [TCP and streams](tcp.md): listening, connecting, reading and writing.
- [Flow control](flow-control.md): buffers, the write queue, and pausing
  reads.
- [Processes and pipes](processes.md): running a child and talking to it.
- [Signals](signals.md): catching signals on the loop.
- [DNS](dns.md): turning names into addresses and back.
- [Errors](errors.md): every condition the library raises, and how to catch
  it.
- [API reference](reference.md): every exported binding, one entry each.
- [Building and testing](building.md): working on the library itself.
