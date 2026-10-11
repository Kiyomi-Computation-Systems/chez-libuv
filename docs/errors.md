# Errors

Every failure chez-libuv reports is an R6RS condition of type `&uv-error`.
A failure reaches you in one of two ways: a call **raises** it, or a
callback is **handed** it as an ordinary value.

## A first catch

Catch a condition with R6RS `guard` and the predicate for its type. Each
type has accessors for what it carries.

```scheme
(import (rnrs) (libuv))

;; Failures raised by a call.
(define loop (make-uv-loop))
(define timer (make-uv-timer loop))

;; libuv said no: an &uv-errno-error.
(guard (e ((uv-errno-error? e)
           (display (list (uv-errno-error-errno e) (condition-who e)))
           (newline)))
  (uv-loop-close! loop))

;; You passed something wrong: an &uv-invalid-argument.
(guard (e ((uv-invalid-argument? e)
           (display (list (uv-invalid-argument-who e)
                          (uv-invalid-argument-reason e)))
           (newline)))
  (uv-timer-start! timer 'not-a-procedure 10 0))

;; The handle is closed: an &uv-handle-closed.
(uv-close! timer)
(guard (e ((uv-handle-closed? e)
           (display (list 'closed (uv-handle-closed-kind e)))
           (newline)))
  (uv-timer-start! timer (lambda (t) #f) 10 0))

;; All of them are &uv-error, and &error too.
(guard (e ((uv-error? e) (display (list 'uv-error (error? e))) (newline)))
  (uv-timer-again! timer))

(uv-loop-teardown! loop)
```

It prints:

```
(EBUSY uv-loop-close!)
(uv-timer-start! on-timeout-not-a-procedure)
(closed timer)
(uv-error #t)
```

The loop could not close because the timer was still open, so libuv
answered `EBUSY`.

## Raised or handed to you

**A call raises.** When a verb such as `uv-spawn!` or `uv-loop-close!`
cannot do what you asked, it raises a condition, and you catch it with
`guard`.

**A callback is handed one.** When something you started finishes later,
such as a connect, a write or a read, its callback gets the outcome as an
argument: `#f` for success, or a condition for a failure. That condition
is **not raised**. It is a plain value, and you test it with the same
predicates.

```scheme
(import (rnrs) (libuv))

;; A failure delivered to a callback: a condition value, not a raise.
(define loop (make-uv-loop))

;; Find a port nobody listens on: bind one, note it, close it.
(define probe (make-uv-tcp loop))
(uv-tcp-bind! probe "127.0.0.1" 0)
(define port (uv-tcp-getsockname-port probe))
(uv-close! probe)
(uv-run loop 'default)

(define client (make-uv-tcp loop))
(uv-tcp-connect! client "127.0.0.1" port
                 (lambda (err)
                   (when (uv-errno-error? err)
                     (display (uv-errno-error-errno err)) (newline)
                     (display (condition-who err)) (newline)
                     (display (uv-errno-error-message err)) (newline))
                   (uv-close! client)))
(uv-run loop 'default)
(uv-loop-teardown! loop)
```

It prints:

```
ECONNREFUSED
uv-tcp-connect!
connection refused
```

Two outcomes are not failures at all, and never arrive as conditions:

- **End of file** has its own callback, `on-eof`, which takes no arguments
  ([TCP and streams](tcp.md)).
- **A child's exit** goes to `on-exit` as a status and a signal, even when
  the child failed ([processes](processes.md)).

## The tree

```
&error                         (R6RS)
└── &uv-error
    ├── &uv-errno-error         errno, code, message
    ├── &uv-handle-closed       kind
    ├── &uv-invalid-argument    who, reason
    ├── &uv-callback-error      cause
    ├── &uv-wrong-thread        who, expected, actual
    ├── &uv-stack-exhausted     who, headroom, floor
    ├── &uv-shim-unavailable    path
    │   └── &uv-libuv-unavailable   (path, inherited)
    ├── &uv-version-incompatible    compiled, runtime
    └── &uv-constant-unavailable    name
```

Catch a narrow type with its own predicate, such as `uv-handle-closed?`, or
the whole family with [`uv-error?`](reference.md#uv-error-predicate). Every
one is also an R6RS `&error`, so `error?` matches it too.

Day to day you meet four of them. The process, pipe, stream, signal,
handle and async verbs fail with an `&uv-errno-error`, an
`&uv-handle-closed` or an `&uv-invalid-argument`, or with `&uv-wrong-thread`
when the verb is called off its loop's thread. The rest come from running
a loop, from callbacks, and from loading the library.

## What each one means

### libuv said no

[`&uv-errno-error`](reference.md#uv-errno-error-condition-type): libuv
returned an error code. It carries three fields:

| Accessor | Gives you |
|:--|:--|
| [`uv-errno-error-errno`](reference.md#uv-errno-error-errno-accessor) | the error's name as a symbol, such as `'ECONNRESET`. **Branch on this.** |
| [`uv-errno-error-code`](reference.md#uv-errno-error-code-accessor) | the raw number. It differs between platforms, so log it, don't match it. |
| [`uv-errno-error-message`](reference.md#uv-errno-error-message-accessor) | libuv's text, such as `"connection refused"`. Log it. |

It also carries R6RS `&who` and `&message`, so `condition-who` names the
verb that failed.

### The handle is closed

[`&uv-handle-closed`](reference.md#uv-handle-closed-condition-type): you
used a handle or a loop that is already closed, or closing. Its `kind`,
from [`uv-handle-closed-kind`](reference.md#uv-handle-closed-kind-accessor),
says what it was: `'timer`, `'process`, `'loop` and so on. The binding
checks before it touches native memory, so this is a refusal, not a crash.

### A wrong argument

[`&uv-invalid-argument`](reference.md#uv-invalid-argument-condition-type):
you passed something the verb cannot take. It is raised before anything
is allocated, with one rare exception from `uv-spawn!`
([processes](processes.md)).

| Accessor | Gives you |
|:--|:--|
| [`uv-invalid-argument-who`](reference.md#uv-invalid-argument-who-accessor) | the verb, such as `'uv-spawn!` |
| [`uv-invalid-argument-reason`](reference.md#uv-invalid-argument-reason-accessor) | why, as a symbol, such as `'pipe-already-used` |

The reasons are a closed set of symbols. A few you may meet:
`'stdio-spec-unknown`, `'pipe-already-used`, `'signal-unknown`,
`'signal-unwatchable`, `'signal-mode-fixed`, `'buffer-size-fixed`,
`'buffer-size-out-of-range`, `'not-a-socket-handle` and
`'sockaddr-too-small-for-a-port`. The page for each verb names the ones it
raises.

### A callback raised

[`&uv-callback-error`](reference.md#uv-callback-error-condition-type): a
callback raised while the loop ran. A raise never crosses into C. The
binding stores the first one, stops the loop, and `uv-run` raises it again,
wrapped in `&uv-callback-error`.

The wrapper is **composed** with the original condition, so a `guard`
written for the original still matches. Here the callback raised a plain
R6RS error, and the caught condition answers both predicates:

```scheme
(import (rnrs) (libuv))

;; A callback that raises: uv-run raises it again, wrapped.
(define loop (make-uv-loop))
(define timer (make-uv-timer loop))
(uv-timer-start! timer
                 (lambda (t) (error 'my-callback "the sky fell"))
                 0 0)

(guard (e ((uv-callback-error? e)
           (display (list (uv-callback-error? e)
                          (error? e)
                          (condition-who e)
                          (condition-message e)))
           (newline)))
  (uv-run loop 'default))

(uv-loop-teardown! loop)
```

It prints:

```
(#t #t my-callback the sky fell)
```

[`uv-callback-error-cause`](reference.md#uv-callback-error-cause-accessor)
gives you what the callback raised. Use it when that was not a condition: a
callback that raised the symbol `'handler-failed` was caught as an
`&uv-callback-error` whose cause was `handler-failed`.

Only the first raise of a run comes out of `uv-run`. Later ones in the same
run are kept in
[`uv-loop-deferred-errors`](reference.md#uv-loop-deferred-errors-procedure).
`uv-loop-teardown!` can raise an `&uv-callback-error` too, for a callback
that raised while it drained the loop, and `uv-loop-close!` raises one that
is still waiting to be delivered. The
[callbacks](callbacks.md) page has the whole story.

### The wrong thread

[`&uv-wrong-thread`](reference.md#uv-wrong-thread-condition-type): a verb
ran on a thread that does not own its loop. A loop belongs to one thread at
a time ([threads](threads.md)).

| Accessor | Gives you |
|:--|:--|
| [`uv-wrong-thread-who`](reference.md#uv-wrong-thread-who-accessor) | the verb |
| [`uv-wrong-thread-expected`](reference.md#uv-wrong-thread-expected-accessor) | the id of the thread that owned the loop when the verb checked |
| [`uv-wrong-thread-actual`](reference.md#uv-wrong-thread-actual-accessor) | the id of the calling thread |

The two ids always differ.

```scheme
(import (chezscheme) (libuv))

;; A loop belongs to the thread that made it.
(define loop (make-uv-loop))
(define answer #f)
(define m (make-mutex))
(define c (make-condition))

(fork-thread
 (lambda ()
   (let ((r (guard (e ((uv-wrong-thread? e)
                       (list (uv-wrong-thread-who e)
                             (not (= (uv-wrong-thread-expected e)
                                     (uv-wrong-thread-actual e))))))
              (make-uv-timer loop)
              'made)))
     (with-mutex m (set! answer r) (condition-signal c)))))

(with-mutex m (let wait () (unless answer (condition-wait c m) (wait))))
(display answer) (newline)
(uv-loop-teardown! loop)
```

It prints:

```
(make-uv-timer #t)
```

### Out of stack

[`&uv-stack-exhausted`](reference.md#uv-stack-exhausted-condition-type): a
run was refused because its thread had too little C stack left. Only a run
raises it: `uv-run` needs 131,072 bytes (128 KiB), and the drain inside a
teardown needs 65,536. `headroom` is what the thread had, and `floor` what
the run needed.

What uses the stack up is leaving callbacks without returning from them: a
continuation that escapes a callback, or an engine dropped inside one. The
thread gets that stack back in only two ways: when the thread ends, or when
an engine that was resumed inside a callback returns from it.

> ⚠️ Retrying does not help. Short of one of those two, a thread that gets
> `&uv-stack-exhausted` will keep getting it. End the thread, and do the
> work on a fresh one. The [callbacks](callbacks.md) page explains what
> escapes cost.

### Loading and versions

These come from loading the library, not from using it. The
[installing](installing.md#when-the-import-fails) page says what to do
about each.

| Condition | Raised when |
|:--|:--|
| [`&uv-shim-unavailable`](reference.md#uv-shim-unavailable-condition-type) | the C shim could not be found or loaded. `path` says where it looked. |
| [`&uv-libuv-unavailable`](reference.md#uv-libuv-unavailable-condition-type) | libuv's own shared library could not be found or loaded. It is a kind of `&uv-shim-unavailable`, so a `guard` for that catches it too. |
| [`&uv-version-incompatible`](reference.md#uv-version-incompatible-condition-type) | the libuv the shim was compiled against, or the one running, is outside the supported range. `compiled` and `runtime` are the two versions as packed numbers, such as `#x013401` for 1.52.1. |
| [`&uv-constant-unavailable`](reference.md#uv-constant-unavailable-condition-type) | the shim has no constant under a name the binding asked for. `name` says which. |

## Error symbols

Symbols name failures in two places, and neither is raised on its own:

- **Error names**, such as `'EBUSY`, `'ECONNREFUSED` or `'ECANCELED`, are
  the `errno` field of an `&uv-errno-error`. They are libuv's names, the same
  on every platform. A DNS failure uses libuv's `EAI_` names, such as
  `'EAI_NONAME` or `'EAI_CANCELED` ([DNS](dns.md)).
- **Reasons**, such as `'pipe-already-used`, are the `reason` field of an
  `&uv-invalid-argument`.

So to react to one error, catch the condition and compare its symbol with
`eq?`. Match the symbol, not the message: the message is text for people.

`'ECANCELED` is worth knowing. It is not something going wrong: it is how
work you abandoned reports back. A write still queued when its stream was
closed calls its callback with an `&uv-errno-error` whose errno is
`'ECANCELED`.

## Catching them

Use plain R6RS `guard`, with one clause per type you handle:

```scheme
(guard (e ((uv-errno-error? e)
           (display (list (uv-errno-error-errno e) (condition-who e)))
           (newline)))
  (uv-loop-close! loop))
```

A few habits help:

1. **Put narrow types before wide ones.** `guard` tries its clauses in
   order, and `uv-error?` matches everything here.
2. **Leave out what you can't handle.** A `guard` with no matching clause
   raises the condition again, so it reaches whoever can deal with it.
3. **In a callback, test the argument.** It is `#f` or a condition, and is
   never raised for you.

> ⚠️ Don't wrap a run in a catch-all such as `(guard (e (#t ...)) ...)`
> and carry on in a loop. When a thread runs out of C stack anyway, Chez
> reports it as an "invalid memory reference" error on a stack that is
> still full. A handler that catches it can fault again, or hang the
> process for good, with no message, at the next garbage collection. Catch
> the conditions you expect by their predicates, and let that one end the
> program.

## Making your own

Every condition type exports its constructor, such as
[`make-uv-errno-error`](reference.md#make-uv-errno-error-record-constructor).
They are public so that your own code, such as an `on-error` callback, can
build one or raise one again.

## Read next

- [Callbacks](callbacks.md): raises from callbacks, and escapes.
- [Threads](threads.md): which thread owns a loop.
- [Installing](installing.md): what the loading conditions mean for your
  setup.
- [API reference](reference.md): every accessor and predicate.
