# API reference

This page is the binding-by-binding reference for chez-libuv. Most programs
import `(libuv)`, which re-exports the public API. The narrower libraries are
there for programs that want only one layer. The topic pages explain how the
pieces fit together. This page answers the smaller question: what exactly is
this binding, how do you call it, and which libraries export it?

## Modules

| Library | Purpose |
|---|---|
| `(libuv)` | Everything below except `addrinfo-chain->list`. |
| `(libuv loop)` | Loops: construction, running, closing and teardown. |
| `(libuv handle)` | Handle predicates, state, buffer sizes and `uv-close!`. |
| `(libuv timer)` | Timers. |
| `(libuv tcp)` | TCP handles, plus the stream verbs. |
| `(libuv stream)` | Reading, writing and shutting down TCP handles and pipes. |
| `(libuv pipe)` | Pipes for child stdio. |
| `(libuv process)` | Child processes, `uv-kill!` and pids. |
| `(libuv signal)` | Signal watchers. |
| `(libuv dns)` | Name lookups and address records. |
| `(libuv async)` | Cross-thread wakeups. |

## Conventions

Signatures use `->` to separate the arguments from the result. It is notation,
not Scheme syntax. Separate signatures show separate arities. A `uv-request`
is the record a verb returns for work in flight, and its completion callback
is called with `#f` on success or a condition on failure.

Most verbs that work on an open handle check first that the handle is a
handle of the right kind (`&uv-invalid-argument`, reason `'not-a-uv-handle`
or a kind-specific one such as `'not-a-uv-timer`), that this thread owns the
loop (`&uv-wrong-thread`), and that the handle is open (`&uv-handle-closed`).
A failure from libuv itself is `&uv-errno-error`. The **Raises** lines name
the conditions a call raises and the `&uv-invalid-argument` reasons you are
most likely to meet. They are a guide, not a contract: the source names every
reason, and [Errors](errors.md) explains how to catch them by type.

The thread check does not cover `uv-close!`, `uv-stop!`, `uv-now` or `uv-loop-alive?`, which you still call only on the loop's thread. `uv-run` and `uv-loop-teardown!` are not refused from another thread either: they make that thread the loop's owner. `uv-async-send!` is the one verb you may call from any thread.

See [Errors](errors.md) for the condition family and
[Threads](threads.md) for the thread rules.

## The loop

A loop owns one libuv event loop and the handles made on it. One thread owns each loop.

### `make-uv-loop` (procedure)

`(make-uv-loop) -> uv-loop`

Makes a new loop. The first call in the process that needs the native library, this one or another, also checks it: the libuv version, the constants the binding uses, and the shim's buffer layout. Close the loop with `uv-loop-teardown!`, or use `call-with-uv-loop`.

**Available from:** `(libuv)`, `(libuv loop)`\
**Raises:** on that first check, `&uv-version-incompatible` when the libuv versions are unsupported, `&uv-constant-unavailable` when the running libuv lacks a constant, and `&uv-shim-unavailable` when the shim's buffer layout does not match\
**Details:** [The event loop](loops.md)

### `uv-loop?` (predicate)

`(uv-loop? object) -> boolean`

Returns true if `object` is a loop, open or closed.

**Available from:** `(libuv)`, `(libuv loop)`\
**Details:** [The event loop](loops.md)

### `uv-loop-open?` (procedure)

`(uv-loop-open? loop) -> boolean`

Returns true until the loop is closed.

**Available from:** `(libuv)`, `(libuv loop)`\
**Raises:** `&uv-invalid-argument` if `loop` is not a loop\
**Details:** [The event loop](loops.md)

### `uv-run` (procedure)

`(uv-run loop) -> boolean`\
`(uv-run loop mode) -> boolean`

Runs the loop. `mode` is `'default` (the default), `'once` or `'nowait`. Returns true if work remains. If a callback raised during the run, `uv-run` raises `&uv-callback-error` once it returns.

**Available from:** `(libuv)`, `(libuv loop)`\
**Raises:** `&uv-handle-closed` if the loop is closed, `&uv-invalid-argument` for an unknown mode or `'loop-running`, `&uv-callback-error`, `&uv-stack-exhausted` when the thread has under 128 KiB of C stack left\
**Details:** [The event loop](loops.md)

### `uv-stop!` (procedure)

`(uv-stop! loop) -> unspecified`

Makes the current run return after this iteration. You may call it from inside a callback.

**Available from:** `(libuv)`, `(libuv loop)`\
**Raises:** `&uv-handle-closed` if the loop is closed\
**Details:** [The event loop](loops.md)

### `uv-loop-alive?` (procedure)

`(uv-loop-alive? loop) -> boolean`

Returns true if the loop still has active handles or requests.

**Available from:** `(libuv)`, `(libuv loop)`\
**Raises:** `&uv-handle-closed` if the loop is closed\
**Details:** [The event loop](loops.md)

### `uv-now` (procedure)

`(uv-now loop) -> exact-nonnegative-integer`

Returns libuv's cached time in milliseconds. It changes once per iteration, or when you call `uv-update-time!`.

**Available from:** `(libuv)`, `(libuv loop)`\
**Raises:** `&uv-handle-closed` if the loop is closed\
**Details:** [Timers](timers.md)

### `uv-update-time!` (procedure)

`(uv-update-time! loop) -> unspecified`

Refreshes the cached time from the clock. Call it before arming a timer in a callback that held the loop. Loop thread only. It runs no callbacks.

**Available from:** `(libuv)`, `(libuv loop)`\
**Raises:** `&uv-handle-closed` if the loop is closed, `&uv-wrong-thread` from another thread\
**Details:** [Timers](timers.md)

### `uv-loop-live-handles` (procedure)

`(uv-loop-live-handles loop) -> (listof uv-handle)`

Returns a fresh list of the handles registered on the loop.

**Available from:** `(libuv)`, `(libuv loop)`\
**Raises:** `&uv-handle-closed` if the loop is closed\
**Details:** [The event loop](loops.md)

### `uv-loop-deferred-errors` (procedure)

`(uv-loop-deferred-errors loop) -> list`

Returns the objects that callbacks raised after the first during the last run, oldest first. They are the raw raised values, which need not be conditions. The first one is raised by `uv-run`.

**Available from:** `(libuv)`, `(libuv loop)`\
**Raises:** `&uv-handle-closed` if the loop is closed\
**Details:** [Errors](errors.md)

### `uv-loop-close!` (procedure)

`(uv-loop-close! loop) -> unspecified`

Closes a loop that has no open handles. Closing a closed loop does nothing. A callback error still pending is raised after the close.

**Available from:** `(libuv)`, `(libuv loop)`\
**Raises:** `&uv-errno-error` with errno `'EBUSY` while handles remain, `&uv-invalid-argument` with reason `'loop-running` while a call is inside the loop, `&uv-callback-error`\
**Details:** [The event loop](loops.md)

### `uv-loop-teardown!` (procedure)

`(uv-loop-teardown! loop) -> unspecified`

Cancels pending requests, closes every handle, runs the loop until the closes finish, then closes the loop. The first callback error is raised once the teardown is done.

**Available from:** `(libuv)`, `(libuv loop)`\
**Raises:** `&uv-invalid-argument` with reason `'loop-running`, `&uv-errno-error` with errno `'EBUSY` if libuv cannot close the loop, `&uv-error` if the loop still has work after 1024 drain runs, `&uv-callback-error`, `&uv-stack-exhausted`\
**Details:** [The event loop](loops.md)

### `call-with-uv-loop` (procedure)

`(call-with-uv-loop proc) -> object`

Makes a loop, calls `(proc loop)` once, and tears the loop down however `proc` exits. Returns what `proc` returns.

**Available from:** `(libuv)`, `(libuv loop)`\
**Raises:** what the body raises, `uv-loop-teardown!`'s conditions, and `&uv-handle-closed` if control re-enters the body after it was left\
**Details:** [The event loop](loops.md)

## Handles

Every handle is open, then closing, then closed. Closing is asynchronous: the handle's memory is released when a later loop iteration runs its close completion.

### `uv-handle?` (predicate)

`(uv-handle? object) -> boolean`

Returns true if `object` is any handle, open or closed.

**Available from:** `(libuv)`, `(libuv handle)`\
**Details:** [The event loop](loops.md)

### `uv-timer?` (predicate)

`(uv-timer? object) -> boolean`

Returns true if `object` is a timer, open or closed.

**Available from:** `(libuv)`, `(libuv handle)`\
**Details:** [The event loop](loops.md)

### `uv-tcp?` (predicate)

`(uv-tcp? object) -> boolean`

Returns true if `object` is a TCP handle, open or closed.

**Available from:** `(libuv)`, `(libuv handle)`\
**Details:** [The event loop](loops.md)

### `uv-pipe?` (predicate)

`(uv-pipe? object) -> boolean`

Returns true if `object` is a pipe, open or closed.

**Available from:** `(libuv)`, `(libuv handle)`\
**Details:** [The event loop](loops.md)

### `uv-process?` (predicate)

`(uv-process? object) -> boolean`

Returns true if `object` is a process handle, open or closed.

**Available from:** `(libuv)`, `(libuv handle)`\
**Details:** [The event loop](loops.md)

### `uv-signal?` (predicate)

`(uv-signal? object) -> boolean`

Returns true if `object` is a signal watcher, open or closed.

**Available from:** `(libuv)`, `(libuv handle)`\
**Details:** [The event loop](loops.md)

### `uv-async?` (predicate)

`(uv-async? object) -> boolean`

Returns true if `object` is an async handle, open or closed.

**Available from:** `(libuv)`, `(libuv handle)`\
**Details:** [The event loop](loops.md)

### `uv-handle-open?` (predicate)

`(uv-handle-open? object) -> boolean`

Returns true if `object` is a handle that is open. It accepts any object and never raises.

**Available from:** `(libuv)`, `(libuv handle)`\
**Details:** [The event loop](loops.md)

### `uv-handle-closing?` (predicate)

`(uv-handle-closing? object) -> boolean`

Returns true if `object` is a handle whose close has begun but not finished. It accepts any object and never raises.

**Available from:** `(libuv)`, `(libuv handle)`\
**Details:** [The event loop](loops.md)

### `uv-handle-state` (procedure)

`(uv-handle-state handle) -> symbol`

Returns `'open`, `'closing` or `'closed`.

**Available from:** `(libuv)`, `(libuv handle)`\
**Raises:** `&uv-invalid-argument` if `handle` is not a handle\
**Details:** [The event loop](loops.md)

### `uv-handle-loop` (procedure)

`(uv-handle-loop handle) -> uv-loop`

Returns the loop that owns the handle. It answers for a closed handle too.

**Available from:** `(libuv)`, `(libuv handle)`\
**Raises:** `&uv-invalid-argument` if `handle` is not a handle\
**Details:** [The event loop](loops.md)

### `uv-close!` (procedure)

`(uv-close! handle) -> unspecified`\
`(uv-close! handle on-close) -> unspecified`

Starts closing the handle. `on-close` is called with no arguments once the close completes. `on-close` may be `#f`. A second close does nothing, and its `on-close` is discarded.

**Available from:** `(libuv)`, `(libuv handle)`\
**Raises:** `&uv-invalid-argument` if `on-close` is not a procedure\
**Details:** [The event loop](loops.md)

### `uv-send-buffer-size` (procedure)

`(uv-send-buffer-size handle) -> exact-nonnegative-integer`

Returns the OS send buffer (`SO_SNDBUF`) of a TCP handle or pipe, in bytes. The kernel may round what you set, so read the answer back.

**Available from:** `(libuv)`, `(libuv handle)`\
**Raises:** `&uv-handle-closed`, `&uv-invalid-argument` with reason `'not-a-socket-handle`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [Flow control](flow-control.md)

### `uv-send-buffer-size!` (procedure)

`(uv-send-buffer-size! handle size) -> unspecified`

Asks the kernel for a send buffer of `size` bytes, a positive integer below 2^31. The kernel may round it.

**Available from:** `(libuv)`, `(libuv handle)`\
**Raises:** `&uv-handle-closed`, `&uv-invalid-argument` with reason `'not-a-socket-handle` or `'buffer-size-out-of-range`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [Flow control](flow-control.md)

### `uv-recv-buffer-size` (procedure)

`(uv-recv-buffer-size handle) -> exact-nonnegative-integer`

Returns the OS receive buffer (`SO_RCVBUF`) of a TCP handle or pipe, in bytes. The kernel may round what you set, so read the answer back.

**Available from:** `(libuv)`, `(libuv handle)`\
**Raises:** `&uv-handle-closed`, `&uv-invalid-argument` with reason `'not-a-socket-handle`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [Flow control](flow-control.md)

### `uv-recv-buffer-size!` (procedure)

`(uv-recv-buffer-size! handle size) -> unspecified`

Asks the kernel for a receive buffer of `size` bytes, a positive integer below 2^31. The kernel may round it.

**Available from:** `(libuv)`, `(libuv handle)`\
**Raises:** `&uv-handle-closed`, `&uv-invalid-argument` with reason `'not-a-socket-handle` or `'buffer-size-out-of-range`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [Flow control](flow-control.md)

## Timers

### `make-uv-timer` (procedure)

`(make-uv-timer loop) -> uv-timer`

Makes a timer on the loop. It is idle until you start it.

**Available from:** `(libuv)`, `(libuv timer)`\
**Raises:** `&uv-handle-closed` if the loop is closed, `&uv-wrong-thread`\
**Details:** [Timers](timers.md)

### `uv-timer-start!` (procedure)

`(uv-timer-start! timer on-timeout timeout-ms repeat-ms) -> unspecified`

Arms the timer. `on-timeout` is called with the timer after `timeout-ms`, then every `repeat-ms` unless that is 0. Both are exact integers from 0 below 2^64. The delay counts from `uv-now`, not the wall clock.

**Available from:** `(libuv)`, `(libuv timer)`\
**Raises:** `&uv-invalid-argument` with reason `'not-a-uv-timer`, `'not-a-uv-handle`, `'on-timeout-not-a-procedure`, `'timeout-out-of-range` or `'repeat-out-of-range`, `&uv-handle-closed`, `&uv-wrong-thread`\
**Details:** [Timers](timers.md)

### `uv-timer-stop!` (procedure)

`(uv-timer-stop! timer) -> unspecified`

Disarms the timer. It keeps its callback, so `uv-timer-again!` can restart it.

**Available from:** `(libuv)`, `(libuv timer)`\
**Raises:** `&uv-invalid-argument`, `&uv-handle-closed`, `&uv-wrong-thread`\
**Details:** [Timers](timers.md)

### `uv-timer-again!` (procedure)

`(uv-timer-again! timer) -> unspecified`

Restarts a timer using its repeat interval as the timeout. With a repeat interval of 0 it does nothing. On a timer that was never started it raises `&uv-errno-error` with errno `'EINVAL`.

**Available from:** `(libuv)`, `(libuv timer)`\
**Raises:** `&uv-invalid-argument`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [Timers](timers.md)

### `uv-timer-repeat` (procedure)

`(uv-timer-repeat timer) -> exact-nonnegative-integer`

Returns the timer's repeat interval in milliseconds.

**Available from:** `(libuv)`, `(libuv timer)`\
**Raises:** `&uv-invalid-argument`, `&uv-handle-closed`, `&uv-wrong-thread`\
**Details:** [Timers](timers.md)

### `uv-timer-set-repeat!` (procedure)

`(uv-timer-set-repeat! timer repeat-ms) -> unspecified`

Sets the repeat interval, an exact integer from 0 below 2^64. It takes effect the next time the timer fires.

**Available from:** `(libuv)`, `(libuv timer)`\
**Raises:** `&uv-invalid-argument` with reason `'repeat-out-of-range`, `&uv-handle-closed`, `&uv-wrong-thread`\
**Details:** [Timers](timers.md)

## TCP

### `make-uv-tcp` (procedure)

`(make-uv-tcp loop) -> uv-tcp`

Makes a TCP handle on the loop. Use it as a client or bind it and listen.

**Available from:** `(libuv)`, `(libuv tcp)`\
**Raises:** `&uv-handle-closed` if the loop is closed, `&uv-wrong-thread`\
**Details:** [TCP](tcp.md)

### `uv-tcp-bind!` (procedure)

`(uv-tcp-bind! tcp address port) -> unspecified`\
`(uv-tcp-bind! tcp address port flags) -> unspecified`

Binds to an IPv4 or IPv6 literal and a port from 0 to 65535. `flags` is a list; the only flag is `'reuseport`.

**Available from:** `(libuv)`, `(libuv tcp)`\
**Raises:** `&uv-invalid-argument` with reason `'address-not-a-string`, `'address-contains-nul`, `'port-out-of-range`, `'not-a-uv-tcp`, `'bad-address`, `'flags-not-a-list` or `'unknown-bind-flag`, `&uv-constant-unavailable` for `'reuseport` on a libuv without it, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [TCP](tcp.md)

### `uv-tcp-getsockname-port` (procedure)

`(uv-tcp-getsockname-port tcp) -> exact-nonnegative-integer`

Returns the port the handle is bound to. Use it after binding to port 0.

**Available from:** `(libuv)`, `(libuv tcp)`\
**Raises:** `&uv-invalid-argument`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [TCP](tcp.md)

### `uv-tcp-sockname-address` (procedure)

`(uv-tcp-sockname-address tcp) -> (values (or string #f) exact-nonnegative-integer)`

Returns this end's address and port. A bound handle has one before it connects.

**Available from:** `(libuv)`, `(libuv tcp)`\
**Raises:** `&uv-invalid-argument`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [TCP](tcp.md)

### `uv-tcp-peer-address` (procedure)

`(uv-tcp-peer-address tcp) -> (values (or string #f) exact-nonnegative-integer)`

Returns the remote end's address and port.

**Available from:** `(libuv)`, `(libuv tcp)`\
**Raises:** `&uv-invalid-argument`, `&uv-handle-closed`, `&uv-wrong-thread`, and `&uv-errno-error` with errno `'EBADF` on a fresh handle, or `'ENOTCONN` once it is bound but not connected\
**Details:** [TCP](tcp.md)

### `uv-listen!` (procedure)

`(uv-listen! tcp backlog on-connection) -> unspecified`

Starts listening. `backlog` is an exact integer from 0 below 2^31. `on-connection` is called with `#f`, or with a condition if the connection failed, and you then call `uv-accept!`.

**Available from:** `(libuv)`, `(libuv tcp)`\
**Raises:** `&uv-invalid-argument` with reason `'backlog-out-of-range`, `'on-connection-not-a-procedure` or `'not-a-uv-tcp`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [TCP](tcp.md)

### `uv-accept!` (procedure)

`(uv-accept! server) -> uv-tcp`

Accepts the queued connection and returns a new open TCP handle for it.

**Available from:** `(libuv)`, `(libuv tcp)`\
**Raises:** `&uv-invalid-argument`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [TCP](tcp.md)

### `uv-tcp-connect!` (procedure)

`(uv-tcp-connect! tcp address port on-connect) -> uv-request`

Starts a connection to an IPv4 or IPv6 literal and returns the in-flight request. `on-connect` is called with `#f`, or with a condition if the connection failed.

**Available from:** `(libuv)`, `(libuv tcp)`\
**Raises:** `&uv-invalid-argument` with reason `'address-not-a-string`, `'address-contains-nul`, `'port-out-of-range`, `'bad-address` or `'on-connect-not-a-procedure`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [TCP](tcp.md)

### `uv-tcp-nodelay!` (procedure)

`(uv-tcp-nodelay! tcp enable?) -> unspecified`

Sets `TCP_NODELAY`. `enable?` must be a boolean.

**Available from:** `(libuv)`, `(libuv tcp)`\
**Raises:** `&uv-invalid-argument` with reason `'enable-not-a-boolean`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [TCP](tcp.md)

### `uv-tcp-keepalive!` (procedure)

`(uv-tcp-keepalive! tcp #f) -> unspecified`\
`(uv-tcp-keepalive! tcp enable? delay) -> unspecified`

Sets `SO_KEEPALIVE`. `delay` is the idle time in whole seconds, a positive integer below 2^32, and is required when enabling. The three-argument form also accepts `#f` for `enable?`, and still checks `delay`.

**Available from:** `(libuv)`, `(libuv tcp)`\
**Raises:** `&uv-invalid-argument` with reason `'enable-not-a-boolean`, `'delay-required-when-enabling` or `'delay-out-of-range`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [TCP](tcp.md)

## Streams

These verbs take any open TCP handle or pipe that is connected.

### `uv-write!` (procedure)

`(uv-write! stream bytevector on-complete) -> uv-request`\
`(uv-write! stream bytevector start end on-complete) -> uv-request`

Writes a bytevector, or its span from `start` to `end`. The bytes are copied during the call. `on-complete` is called with `#f`, or with a condition if the write failed.

**Available from:** `(libuv)`, `(libuv stream)`, `(libuv tcp)`\
**Raises:** `&uv-invalid-argument` with reason `'source-not-a-bytevector`, `'span-out-of-range` or `'on-complete-not-a-procedure`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [Flow control](flow-control.md)

### `uv-write*!` (procedure)

`(uv-write*! stream segments on-complete) -> uv-request`

Writes a non-empty list of segments as one request with one completion. A segment is a bytevector or a list `(bytevector start end)`.

**Available from:** `(libuv)`, `(libuv stream)`, `(libuv tcp)`\
**Raises:** `&uv-invalid-argument` with reason `'segments-not-a-list`, `'empty-segment-list`, `'segment-not-a-bytevector` or `'segment-span-out-of-range`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [Flow control](flow-control.md)

### `uv-shutdown!` (procedure)

`(uv-shutdown! stream on-shutdown) -> uv-request`

Shuts down the write side after queued writes finish. The read side stays open. `on-shutdown` is called with `#f`, or with a condition.

**Available from:** `(libuv)`, `(libuv stream)`, `(libuv tcp)`\
**Raises:** `&uv-invalid-argument` with reason `'on-shutdown-not-a-procedure`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [Flow control](flow-control.md)

### `uv-read-start!` (procedure)

`(uv-read-start! stream on-data on-eof on-error) -> unspecified`\
`(uv-read-start! stream on-data on-eof on-error buffer-size) -> unspecified`

Starts reading. `on-data` is called with `(bytevector start end)`, `on-eof` with no arguments and `on-error` with a condition. The first start fixes the read buffer size, 65536 bytes unless you pass `buffer-size`.

**Available from:** `(libuv)`, `(libuv stream)`, `(libuv tcp)`\
**Raises:** `&uv-invalid-argument` with reason `'buffer-size-fixed` or `'buffer-size-out-of-range`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [Flow control](flow-control.md)

### `uv-read-stop!` (procedure)

`(uv-read-stop! stream) -> unspecified`

Stops reading and keeps the callbacks and buffer for the next start. A stop on a stream that is no longer open raises.

**Available from:** `(libuv)`, `(libuv stream)`, `(libuv tcp)`\
**Raises:** `&uv-invalid-argument`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [Flow control](flow-control.md)

### `uv-stream-write-queue-size` (procedure)

`(uv-stream-write-queue-size stream) -> exact-nonnegative-integer`

Returns the bytes libuv has queued for the stream. It is a congestion signal, not a memory gauge, and its meaning differs between platforms.

**Available from:** `(libuv)`, `(libuv stream)`, `(libuv tcp)`\
**Raises:** `&uv-invalid-argument`, `&uv-handle-closed`, `&uv-wrong-thread`\
**Details:** [Flow control](flow-control.md)

## Pipes

### `make-uv-pipe` (procedure)

`(make-uv-pipe loop) -> uv-pipe`

Makes an unconnected pipe. Name it in the `stdio` option of `uv-spawn!` to connect it to a child, or close it.

**Available from:** `(libuv)`, `(libuv pipe)`\
**Raises:** `&uv-handle-closed` if the loop is closed, `&uv-wrong-thread`\
**Details:** [Child processes](processes.md)

## Child processes

### `uv-spawn!` (procedure)

`(uv-spawn! loop file args on-exit) -> uv-process`\
`(uv-spawn! loop file args options on-exit) -> uv-process`

Starts a child. `file` is the program, `args` the complete argv including argv[0], and `on-exit` a procedure or `#f`. `options` is an alist, or `#f` for none, with the keys `env`, `cwd`, `stdio`, `detached`, `uid` and `gid`. `on-exit` is called with `(exit-status term-signal)`.

**Available from:** `(libuv)`, `(libuv process)`\
**Raises:** `&uv-invalid-argument` with reason `'file-not-a-string`, `'args-not-a-string-list`, `'embedded-nul`, `'on-exit-not-a-procedure`, `'option-unknown`, `'option-duplicate`, `'pipe-wrong-loop`, `'env-not-a-string-list`, `'cwd-not-a-string`, `'detached-not-a-boolean`, `'uid-out-of-range`, `'gid-out-of-range`, `'stdio-not-a-list`, `'stdio-spec-unknown`, `'stdio-fd-not-an-fd`, `'pipe-already-used` or `'spawn-failure-state-unclassifiable`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [Child processes](processes.md)

### `uv-process-kill!` (procedure)

`(uv-process-kill! process signal) -> unspecified`

Sends a signal to the child. `signal` is `'sigterm`, `'sigkill`, `'sigint`, `'sighup`, `'sigquit`, `'sigusr1`, `'sigusr2`, `'sigcont`, `'sigstop` or `0` to test that the process exists.

**Available from:** `(libuv)`, `(libuv process)`\
**Raises:** `&uv-invalid-argument` with reason `'signal-unknown`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [Child processes](processes.md)

### `uv-kill!` (procedure)

`(uv-kill! pid signal) -> unspecified`

Sends a signal to a process id, with the same signals as `uv-process-kill!`. A negative pid means a process group.

**Available from:** `(libuv)`, `(libuv process)`\
**Raises:** `&uv-invalid-argument` with reason `'pid-not-an-exact-integer` or `'signal-unknown`, `&uv-errno-error` (`'ESRCH` for a missing process)\
**Details:** [Child processes](processes.md)

### `uv-process-pid` (procedure)

`(uv-process-pid process) -> exact-integer`

Returns the child's pid. It answers from the spawn until `uv-close!` is called on the handle, including after the child exits.

**Available from:** `(libuv)`, `(libuv process)`\
**Raises:** `&uv-invalid-argument`, `&uv-handle-closed`, `&uv-wrong-thread`\
**Details:** [Child processes](processes.md)

### `uv-os-getpid` (procedure)

`(uv-os-getpid) -> exact-integer`

Returns the pid of this process.

**Available from:** `(libuv)`, `(libuv process)`\
**Details:** [Child processes](processes.md)

## Signals

### `make-uv-signal` (procedure)

`(make-uv-signal loop) -> uv-signal`

Makes a signal watcher on the loop. It is idle until you start it.

**Available from:** `(libuv)`, `(libuv signal)`\
**Raises:** `&uv-handle-closed` if the loop is closed, `&uv-wrong-thread`\
**Details:** [Signals](signals.md)

### `uv-signal-start!` (procedure)

`(uv-signal-start! signal name on-signal) -> unspecified`

Watches the signal `name` until you stop or close the watcher. `on-signal` is called with the signal's symbol. The first start fixes the watcher to continuous mode.

**Available from:** `(libuv)`, `(libuv signal)`\
**Raises:** `&uv-invalid-argument` with reason `'signal-unknown`, `'signal-unwatchable`, `'signal-mode-fixed`, `'not-a-uv-signal` or `'on-signal-not-a-procedure`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [Signals](signals.md)

### `uv-signal-start-oneshot!` (procedure)

`(uv-signal-start-oneshot! signal name on-signal) -> unspecified`

Watches for one delivery of the signal `name`, then disarms. The first start fixes the watcher to one-shot mode.

**Available from:** `(libuv)`, `(libuv signal)`\
**Raises:** `&uv-invalid-argument` with reason `'signal-unknown`, `'signal-unwatchable`, `'signal-mode-fixed`, `'not-a-uv-signal` or `'on-signal-not-a-procedure`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [Signals](signals.md)

### `uv-signal-stop!` (procedure)

`(uv-signal-stop! signal) -> unspecified`

Disarms the watcher. Close the handle when you are done with it.

**Available from:** `(libuv)`, `(libuv signal)`\
**Raises:** `&uv-invalid-argument` with reason `'not-a-uv-signal`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [Signals](signals.md)

## DNS

### `uv-getaddrinfo!` (procedure)

`(uv-getaddrinfo! loop node service on-complete) -> uv-dns-request`\
`(uv-getaddrinfo! loop node service hints on-complete) -> uv-dns-request`

Resolves a host name. `node` and `service` are strings or `#f`, and `hints` is an alist with the keys `family` (`unspec`, `inet`, `inet6`), `socktype` (`stream`, `dgram`), `protocol` (`tcp`, `udp`) and `flags` (a list of `passive`, `canonname`, `numeric-host`, `numeric-serv`). `on-complete` is called with `(error results)`, where `results` is a list of address records.

**Available from:** `(libuv)`, `(libuv dns)`\
**Raises:** `&uv-invalid-argument` with reason `'on-complete-not-a-procedure`, `'node-and-service-both-absent`, `'node-not-a-string-or-false`, `'node-contains-nul`, `'service-not-a-string-or-false`, `'service-contains-nul`, `'hints-not-an-alist`, `'duplicate-hint-key`, `'hint-flags-not-a-list` or one of the `'unknown-hint-...` reasons, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [DNS](dns.md)

### `uv-getnameinfo!` (procedure)

`(uv-getnameinfo! loop address port on-complete) -> uv-dns-request`\
`(uv-getnameinfo! loop address port flags on-complete) -> uv-dns-request`

Looks up the host and service names of an address. `flags` is a list of `'numeric-host`, `'numeric-serv`, `'name-required` and `'dgram`. `on-complete` is called with `(error host service)`, both strings on success and both `#f` on failure.

**Available from:** `(libuv)`, `(libuv dns)`\
**Raises:** `&uv-invalid-argument` with reason `'address-not-a-string`, `'address-contains-nul`, `'port-out-of-range`, `'bad-address`, `'unknown-nameinfo-flag` or `'nameinfo-flags-not-a-list`, `&uv-handle-closed`, `&uv-wrong-thread`, `&uv-errno-error`\
**Details:** [DNS](dns.md)

### `uv-cancel!` (procedure)

`(uv-cancel! request) -> boolean`

Tries to cancel a DNS request. Returns true only if the work was still queued, and its callback then still runs with `'EAI_CANCELED`. Returns false when it is too late.

**Available from:** `(libuv)`, `(libuv dns)`\
**Raises:** `&uv-invalid-argument` with reason `'not-a-cancellable-request`, `&uv-wrong-thread`\
**Details:** [DNS](dns.md)

### `uv-dns-request?` (predicate)

`(uv-dns-request? object) -> boolean`

Returns true if `object` is a request that `uv-cancel!` accepts.

**Available from:** `(libuv)`, `(libuv dns)`\
**Details:** [DNS](dns.md)

### `make-uv-addrinfo` (record constructor)

`(make-uv-addrinfo family socktype protocol address port canonname) -> uv-addrinfo`

Builds an address record. The fields are not validated. The resolver makes these for you; build one yourself for a test double.

**Available from:** `(libuv)`, `(libuv dns)`\
**Details:** [DNS](dns.md)

### `uv-addrinfo?` (predicate)

`(uv-addrinfo? object) -> boolean`

Returns true if `object` is an address record.

**Available from:** `(libuv)`, `(libuv dns)`\
**Details:** [DNS](dns.md)

### `uv-addrinfo-family` (accessor)

`(uv-addrinfo-family record) -> symbol`

Returns `'inet` or `'inet6`.

**Available from:** `(libuv)`, `(libuv dns)`\
**Details:** [DNS](dns.md)

### `uv-addrinfo-socktype` (accessor)

`(uv-addrinfo-socktype record) -> (or symbol exact-integer)`

Returns `'stream`, `'dgram` or `'raw`, or the raw integer for another type.

**Available from:** `(libuv)`, `(libuv dns)`\
**Details:** [DNS](dns.md)

### `uv-addrinfo-protocol` (accessor)

`(uv-addrinfo-protocol record) -> (or symbol exact-integer)`

Returns `'tcp` or `'udp`, or the raw integer for another protocol. 0 means unspecified.

**Available from:** `(libuv)`, `(libuv dns)`\
**Details:** [DNS](dns.md)

### `uv-addrinfo-address` (accessor)

`(uv-addrinfo-address record) -> (or string #f)`

Returns the address as a string.

**Available from:** `(libuv)`, `(libuv dns)`\
**Details:** [DNS](dns.md)

### `uv-addrinfo-port` (accessor)

`(uv-addrinfo-port record) -> exact-nonnegative-integer`

Returns the port, from 0 to 65535.

**Available from:** `(libuv)`, `(libuv dns)`\
**Details:** [DNS](dns.md)

### `uv-addrinfo-canonname` (accessor)

`(uv-addrinfo-canonname record) -> (or string #f)`

Returns the canonical name. It is `#f` except on the first record when the `canonname` hint flag is set.

**Available from:** `(libuv)`, `(libuv dns)`\
**Details:** [DNS](dns.md)

### `addrinfo-chain->list` (procedure)

`(addrinfo-chain->list chain) -> (listof uv-addrinfo)`

Converts a native `addrinfo` chain, given as an address, into address records. It copies every string and skips families other than `'inet` and `'inet6`. You do not need it to resolve names: `uv-getaddrinfo!` hands its callback the records already.

> ⚠️ It reads memory at whatever address it is given, and checks nothing. Any number that is not the start of a live `addrinfo` chain crashes the process or returns garbage.

**Available from:** `(libuv dns)`\
**Details:** [DNS](dns.md)

## Async

### `make-uv-async` (procedure)

`(make-uv-async loop on-wake) -> uv-async`

Makes an async handle. `on-wake` is called with the handle on the loop thread after any thread calls `uv-async-send!`. Loop thread only. An open async keeps the loop alive.

**Available from:** `(libuv)`, `(libuv async)`\
**Raises:** `&uv-invalid-argument` with reason `'on-wake-not-a-procedure`, `&uv-handle-closed` if the loop is closed, `&uv-wrong-thread`\
**Details:** [Threads](threads.md)

### `uv-async-send!` (procedure)

`(uv-async-send! async) -> unspecified`

Wakes the loop. Any thread may call it. Several sends may produce one wake, so drain a queue of your own in `on-wake`.

**Available from:** `(libuv)`, `(libuv async)`\
**Raises:** `&uv-invalid-argument` with reason `'not-a-uv-async`, `&uv-handle-closed` if the handle is closed\
**Details:** [Threads](threads.md)

## Versions

### `uv-version` (procedure)

`(uv-version) -> string`

Returns the running libuv's version as a string, such as `"1.52.1"`.

**Available from:** `(libuv)`\
**Details:** [The event loop](loops.md)

### `uv-version-compatible?` (procedure)

`(uv-version-compatible?) -> boolean`

Returns `#t` when the libuv this binding was built against and the one running are both in the supported range. The native libraries are already loaded when you import `(libuv)`. The first call checks the versions, and where they are unsupported it raises `&uv-version-incompatible` instead of returning `#f`.

**Available from:** `(libuv)`\
**Raises:** `&uv-version-incompatible`\
**Details:** [Installing](installing.md)

## Conditions

Every condition type comes with a constructor, a predicate and one accessor per field. The root is `&uv-error`, which derives from R6RS `&error`.

### `&uv-error` (condition type)

The root of every condition the binding raises. It has no fields.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `make-uv-error` (record constructor)

`(make-uv-error) -> &uv-error`

Builds a `&uv-error` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-error?` (predicate)

`(uv-error? object) -> boolean`

Returns true if `object` is a `&uv-error` condition or one of its subtypes.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `&uv-errno-error` (condition type)

A subtype of `&uv-error`. libuv returned an error code. `errno` is the portable symbol such as `'ECONNRESET`, which is what you branch on; `code` is the raw platform integer; `message` is a string.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `make-uv-errno-error` (record constructor)

`(make-uv-errno-error errno code message) -> &uv-errno-error`

Builds a `&uv-errno-error` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-errno-error?` (predicate)

`(uv-errno-error? object) -> boolean`

Returns true if `object` is a `&uv-errno-error` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-errno-error-errno` (accessor)

`(uv-errno-error-errno condition) -> symbol`

Returns the `errno` field.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-errno-error-code` (accessor)

`(uv-errno-error-code condition) -> exact-integer`

Returns the `code` field.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-errno-error-message` (accessor)

`(uv-errno-error-message condition) -> string`

Returns the `message` field.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `&uv-handle-closed` (condition type)

A subtype of `&uv-error`. An operation used a handle or loop that is already closed. `kind` is a symbol naming it.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `make-uv-handle-closed` (record constructor)

`(make-uv-handle-closed kind) -> &uv-handle-closed`

Builds a `&uv-handle-closed` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-handle-closed?` (predicate)

`(uv-handle-closed? object) -> boolean`

Returns true if `object` is a `&uv-handle-closed` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-handle-closed-kind` (accessor)

`(uv-handle-closed-kind condition) -> symbol`

Returns the `kind` field.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `&uv-shim-unavailable` (condition type)

A subtype of `&uv-error`. The native shim could not be found or loaded. `path` is where it looked.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `make-uv-shim-unavailable` (record constructor)

`(make-uv-shim-unavailable path) -> &uv-shim-unavailable`

Builds a `&uv-shim-unavailable` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-shim-unavailable?` (predicate)

`(uv-shim-unavailable? object) -> boolean`

Returns true if `object` is a `&uv-shim-unavailable` condition or one of its subtypes.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-shim-unavailable-path` (accessor)

`(uv-shim-unavailable-path condition) -> string`

Returns the `path` field.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `&uv-libuv-unavailable` (condition type)

A subtype of `&uv-shim-unavailable`. libuv's shared library could not be found or loaded. It has the fields of `&uv-shim-unavailable`.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `make-uv-libuv-unavailable` (record constructor)

`(make-uv-libuv-unavailable path) -> &uv-libuv-unavailable`

Builds a `&uv-libuv-unavailable` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-libuv-unavailable?` (predicate)

`(uv-libuv-unavailable? object) -> boolean`

Returns true if `object` is a `&uv-libuv-unavailable` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `&uv-version-incompatible` (condition type)

A subtype of `&uv-error`. The compiled or running libuv is outside the supported range. `compiled` and `runtime` are version numbers.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `make-uv-version-incompatible` (record constructor)

`(make-uv-version-incompatible compiled runtime) -> &uv-version-incompatible`

Builds a `&uv-version-incompatible` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-version-incompatible?` (predicate)

`(uv-version-incompatible? object) -> boolean`

Returns true if `object` is a `&uv-version-incompatible` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-version-incompatible-compiled` (accessor)

`(uv-version-incompatible-compiled condition) -> exact-integer`

Returns the `compiled` field.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-version-incompatible-runtime` (accessor)

`(uv-version-incompatible-runtime condition) -> exact-integer`

Returns the `runtime` field.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `&uv-constant-unavailable` (condition type)

A subtype of `&uv-error`. The shim has no constant of that name. `name` is a symbol.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `make-uv-constant-unavailable` (record constructor)

`(make-uv-constant-unavailable name) -> &uv-constant-unavailable`

Builds a `&uv-constant-unavailable` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-constant-unavailable?` (predicate)

`(uv-constant-unavailable? object) -> boolean`

Returns true if `object` is a `&uv-constant-unavailable` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-constant-unavailable-name` (accessor)

`(uv-constant-unavailable-name condition) -> symbol`

Returns the `name` field.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `&uv-invalid-argument` (condition type)

A subtype of `&uv-error`. A caller error, refused before anything was allocated. `who` is the verb and `reason` a symbol naming what was wrong.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `make-uv-invalid-argument` (record constructor)

`(make-uv-invalid-argument who reason) -> &uv-invalid-argument`

Builds a `&uv-invalid-argument` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-invalid-argument?` (predicate)

`(uv-invalid-argument? object) -> boolean`

Returns true if `object` is a `&uv-invalid-argument` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-invalid-argument-who` (accessor)

`(uv-invalid-argument-who condition) -> symbol`

Returns the `who` field.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-invalid-argument-reason` (accessor)

`(uv-invalid-argument-reason condition) -> symbol`

Returns the `reason` field.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `&uv-callback-error` (condition type)

A subtype of `&uv-error`. A callback raised. `cause` is the original condition or object. The raised condition also carries the original, when it was a condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `make-uv-callback-error` (record constructor)

`(make-uv-callback-error cause) -> &uv-callback-error`

Builds a `&uv-callback-error` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-callback-error?` (predicate)

`(uv-callback-error? object) -> boolean`

Returns true if `object` is a `&uv-callback-error` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-callback-error-cause` (accessor)

`(uv-callback-error-cause condition) -> object`

Returns the `cause` field.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `&uv-wrong-thread` (condition type)

A subtype of `&uv-error`. A verb ran on a thread that does not own the loop. `who` is the verb, `expected` the owner's thread id and `actual` the caller's.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `make-uv-wrong-thread` (record constructor)

`(make-uv-wrong-thread who expected actual) -> &uv-wrong-thread`

Builds a `&uv-wrong-thread` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-wrong-thread?` (predicate)

`(uv-wrong-thread? object) -> boolean`

Returns true if `object` is a `&uv-wrong-thread` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-wrong-thread-who` (accessor)

`(uv-wrong-thread-who condition) -> symbol`

Returns the `who` field.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-wrong-thread-expected` (accessor)

`(uv-wrong-thread-expected condition) -> exact-integer`

Returns the `expected` field.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-wrong-thread-actual` (accessor)

`(uv-wrong-thread-actual condition) -> exact-integer`

Returns the `actual` field.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `&uv-stack-exhausted` (condition type)

A subtype of `&uv-error`. A run was refused because its thread had `headroom` bytes of C stack left, under the `floor` it needs: 131072 for `uv-run`, 65536 for a teardown's drain. The thread gets the stack back when it ends, or when an engine resumed inside the callback returns from it.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `make-uv-stack-exhausted` (record constructor)

`(make-uv-stack-exhausted who headroom floor) -> &uv-stack-exhausted`

Builds a `&uv-stack-exhausted` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-stack-exhausted?` (predicate)

`(uv-stack-exhausted? object) -> boolean`

Returns true if `object` is a `&uv-stack-exhausted` condition.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-stack-exhausted-who` (accessor)

`(uv-stack-exhausted-who condition) -> symbol`

Returns the `who` field.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-stack-exhausted-headroom` (accessor)

`(uv-stack-exhausted-headroom condition) -> exact-integer`

Returns the `headroom` field.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)

### `uv-stack-exhausted-floor` (accessor)

`(uv-stack-exhausted-floor condition) -> exact-integer`

Returns the `floor` field.

**Available from:** `(libuv)`\
**Details:** [Errors](errors.md)
