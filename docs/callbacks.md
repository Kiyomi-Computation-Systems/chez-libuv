# Callbacks

A callback is a procedure you hand the library, for it to call later:
when a timer comes due, when bytes arrive, when a close finishes. It runs
inside `uv-run`, on the loop's thread, and nowhere else.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define timer (make-uv-timer loop))
(uv-timer-start! timer
                 (lambda (t)
                   (display "2. the callback runs\n")
                   (uv-close! t))
                 0 0)                        ; due at once...
(display "1. the timer is started\n")        ; ...but nothing has run yet
(uv-run loop 'default)
(display "3. uv-run has returned\n")
(uv-loop-teardown! loop)
```

It prints:

```
1. the timer is started
2. the callback runs
3. uv-run has returned
```

## When a callback runs

Only inside [`uv-run`](reference.md#uv-run-procedure), or inside a
teardown, which runs the loop to finish its closes. Never in the middle
of your own code. Even a timer with no delay waits for the loop to run.

So a callback can rely on this: nothing else on its loop runs at the same
time. Callbacks on one loop run one after another, on one thread
([threads.md](threads.md)).

What each callback receives depends on what called it. Each page says:
[timers.md](timers.md), [tcp.md](tcp.md), [processes.md](processes.md),
[signals.md](signals.md), [dns.md](dns.md), and
[threads.md](threads.md#wake-a-loop-from-another-thread) for async
handles.

Inside a callback you may use the loop and its handles freely: start and
stop timers, write, close. You may not run, close or tear down the loop
itself. It is already running, so each of those is refused
([threads.md](threads.md#one-call-inside-a-loop-at-a-time)).

## A callback ends by returning

Let every callback return. To end the run early, do one of two things:

- **Call [`uv-stop!`](reference.md#uv-stop-procedure).** The run ends after
  the current turn, and `uv-run` returns.
- **Raise.** The run ends, and `uv-run` raises
  ([below](#when-a-callback-raises)).

Do not leave a callback any other way. A continuation that jumps out of
it leaves the loop broken ([below](#escapes)).

## When a callback raises

Your callback is called from libuv's C code. A Scheme raise must not
unwind through C, so the library catches every raise at the edge of the
callback. Then:

1. It stores the first raise of the run.
2. It stops the loop. Other callbacks already due in this turn still run.
3. `uv-run` returns by raising what it stored.

What `uv-run` raises is your condition combined with
[`&uv-callback-error`](reference.md#uv-callback-error-condition-type). So a
`guard` for your own condition type matches it, and so does one for
`uv-callback-error?`.

If you raised something that is not a condition, `uv-run` raises a plain
`&uv-callback-error`. `uv-callback-error-cause` answers what you raised:

```scheme
(define loop (make-uv-loop))
(define timer (make-uv-timer loop))
(uv-timer-start! timer (lambda (t) (raise 'out-of-patience)) 0 10)

(guard (e ((uv-callback-error? e)
           (display (list 'cause (uv-callback-error-cause e)))
           (newline)))
  (uv-run loop 'default))

;; The run ended early. The repeating timer is still armed.
(display (list 'alive (uv-loop-alive? loop) 'timer (uv-handle-state timer)))
(newline)
(uv-loop-teardown! loop)
```

It prints:

```
(cause out-of-patience)
(alive #t timer open)
```

A raise closes nothing. The timer is still open and still repeating. You
decide what to do: run the loop again, or tear it down.

**Raises after the first.** If more callbacks raise in the same run, the
first one is still what `uv-run` raises. The rest wait in
[`uv-loop-deferred-errors`](reference.md#uv-loop-deferred-errors-procedure),
oldest first. Read them before you run or close the loop again
([loops.md](loops.md#deferred-errors) has an example).

**Raises during a teardown.** A teardown runs callbacks too: close
callbacks, and the last completions of requests. If one raises, the
teardown still finishes, then raises the first such raise.

## Raises from the body of call-with-uv-loop

[`call-with-uv-loop`](reference.md#call-with-uv-loop-procedure) tears its
loop down on the way out, and lets a raise from its body through
unchanged, unless the teardown raises too ([below](#when-the-teardown-raises)).
A guard outside sees your own condition, not a wrapped one:

```scheme
(define kept #f)

(guard (e ((error? e)
           (display (list 'caught (condition-message e)
                          'callback-error? (uv-callback-error? e)))
           (newline)))
  (call-with-uv-loop
   (lambda (loop)
     (set! kept loop)
     (make-uv-timer loop)
     (error 'body "the body gave up"))))

(display (list 'loop-open (uv-loop-open? kept)))
(newline)
```

It prints:

```
(caught the body gave up callback-error? #f)
(loop-open #f)
```

The body runs once. That has a few effects you may notice:

- A `guard` whose clauses do not match the body's condition tests them
  twice. A handler between that guard and the body sees the condition
  twice.
- A handler that answers the raise by re-entering the body, to retry it,
  gets the same raise once more, and after that
  [`&uv-handle-closed`](reference.md#uv-handle-closed-condition-type).
  To retry, call `call-with-uv-loop` again.
- A handler that returns from a `raise` (not `raise-continuable`) is
  called once more, with the `&non-continuable` condition R6RS raises
  for that.

### When the teardown raises

The teardown on the way out runs callbacks too: close callbacks, and the
last completions of requests. If one of them raises, the teardown raises
it, as `uv-loop-teardown!` does. That raise is what leaves
`call-with-uv-loop`. It takes the place of the body's return value, or of
the body's own raise:

```scheme
(define (describe e)
  (if (uv-callback-error? e)
      (list 'callback-error (uv-callback-error-cause e))
      (list 'other e)))

;; The body returns a value, but a close callback raises in the teardown.
(display
 (guard (e (#t (list 'raised (describe e))))
   (call-with-uv-loop
    (lambda (loop)
      (let ((timer (make-uv-timer loop)))
        (uv-close! timer (lambda () (raise 'close-failed)))
        'body-value)))))
(newline)

;; The body raises, and so does a close callback in the teardown.
(display
 (guard (e (#t (list 'raised (describe e))))
   (call-with-uv-loop
    (lambda (loop)
      (let ((timer (make-uv-timer loop)))
        (uv-close! timer (lambda () (raise 'close-failed)))
        (raise 'body-failed))))))
(newline)
```

It prints:

```
(raised (callback-error close-failed))
(raised (callback-error close-failed))
```

In both, the body's result is lost: `'body-value` and `'body-failed` never
reach the guard. If you need the body's result whatever happens, keep
close callbacks from raising.

One exit is different. When the body was left from inside one of the
loop's callbacks, by an escape or an engine's suspension, the teardown
still runs, but a raise from it is kept in, not raised.

## Escapes

An *escape* is a continuation that leaves a callback without returning
from it: calling a continuation captured outside, for instance.

libuv was in the middle of a turn when it called your callback. Only the
callback's return lets it finish that turn. After an escape, nothing can.
So the library keeps the loop marked as running, to stop anything from
touching it.

```scheme
(define loop (make-uv-loop))
(define timer (make-uv-timer loop))
(define leave #f)
(uv-timer-start! timer (lambda (t) (leave 'escaped)) 0 0)

(display (call/cc (lambda (k) (set! leave k) (uv-run loop 'default))))
(newline)

(define (reason thunk)
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
    (thunk)
    'no-refusal))
(display (list 'run (reason (lambda () (uv-run loop 'default)))
               'teardown (reason (lambda () (uv-loop-teardown! loop)))))
(newline)
```

It prints:

```
escaped
(run loop-running teardown loop-running)
```

> ⚠️ **An escape from a callback breaks its loop for good.** `uv-run`,
> `uv-loop-close!` and `uv-loop-teardown!` refuse the loop with
> `'loop-running` from then on. Its handles are never closed and its
> memory is never freed.

**The exception is `call-with-uv-loop`.** It still tears its own loop
down when an escape leaves its body:

```scheme
(define kept #f)

(define result
  (call/cc
   (lambda (k)
     (call-with-uv-loop
      (lambda (loop)
        (set! kept loop)
        (let ((timer (make-uv-timer loop)))
          (uv-timer-start! timer (lambda (t) (k 'left-from-a-callback)) 0 0)
          (uv-run loop 'default)))))))

(display (list result 'loop-open (uv-loop-open? kept)))
(newline)
```

It prints:

```
(left-from-a-callback loop-open #f)
```

> ⚠️ **Do not escape from a close callback**, even inside
> `call-with-uv-loop`. libuv closes handles in batches, and an escape
> from one close callback strands the rest of its batch. The teardown
> cannot finish, and the loop is left marked running, with its memory
> never freed.

## What an escape costs

Even when the loop is torn down, an escape costs its thread something it
does not get back.

**Stack.** The C frames of the run you left stay on the thread's stack
for as long as the thread lives. How much depends on the kind of
callback you left:

| Callback left                     | Stack left behind, per escape            |
|:----------------------------------|:-----------------------------------------|
| A timer                           | about 400 bytes (400 to 500 on arm64)    |
| One libuv calls while polling for I/O: a read, connect, accept, async wake, signal, child's exit, or a request's completion | 34,352 bytes on macOS arm64; 22,272 on Linux arm64 |

Polling callbacks cost more because libuv's poll keeps an array of events
in its frame, and that frame stays too. A write's completion is that kind
when the poll finished the write.

Measured, before the library checked for it:

- On Linux, 16,000 to 24,000 timer escapes filled an 8 MB stack, and the
  process died with `SIGSEGV`. A thread made with `fork-thread` held
  16,000.
- On macOS arm64 the main thread held 20,000 timer escapes. A thread made
  with `fork-thread` gets only 512 KiB of stack: its 1,430th timer escape
  crashed it.
- Escapes from polling callbacks fill a stack far sooner. An 8 MB stack
  held 242 of them on macOS and 375 on Linux. A macOS `fork-thread`
  thread held 14.

So the library now refuses a run when its thread is short of stack:
`uv-run` raises
[`&uv-stack-exhausted`](reference.md#uv-stack-exhausted-condition-type)
instead of crashing ([loops.md](loops.md#stack-headroom)). Under that
check a macOS `fork-thread` thread holds 12 escapes from polling
callbacks, or 1,152 from timers, before its runs are refused.

**Heap.** Each call from C into Scheme gets a small block of memory,
freed when the call returns. An escape never returns, so its block stays
allocated until the process exits: 312 bytes an escape on Linux arm64,
200 on x86-64. Ending the thread does not free it.

A raise costs none of this. The library catches it inside the callback,
which then returns.

> ⚠️ **The check sees only runs the library makes.** C code that a
> callback calls on its own, or another library's callback that a
> continuation escapes, uses the same stack unseen. A thread that runs out
> anyway gets a Scheme error, "invalid memory reference", on a stack that
> is still full. Do not catch it and carry on: the handler can fault
> again, or hang the whole process at the next garbage collection, with
> no message. That is Chez's behaviour, with or without libuv.

If you leave callbacks by continuation as a habit, do it on a thread you
can end, and end it when `&uv-stack-exhausted` arrives.

## Engines inside callbacks

A Chez engine runs a computation for a slice of time, then suspends it.
If the slice runs out while a callback is running, the callback is
suspended in the middle, with libuv's turn around it.

That is not an escape: the engine can be resumed, and then the callback
returns as usual. While the engine is suspended, the loop stays marked
running, so nothing can run, close or free it under the engine.

```scheme
(import (chezscheme) (libuv))

(define loop (make-uv-loop))
(define timer (make-uv-timer loop))
(define (spin n) (if (> n 0) (spin (- n 1)) 'done))
(uv-timer-start! timer
                 (lambda (t)
                   (spin 1000000)               ; long enough to run out of fuel
                   (uv-close! t))
                 0 0)

(define refused-while-suspended #f)

(let resume ((engine (make-engine (lambda () (uv-run loop 'default)))))
  (engine 1000
          (lambda (fuel-left value)
            (display (list 'run-finished value
                           'refused-while-suspended refused-while-suspended))
            (newline))
          (lambda (next)
            ;; Suspended. Nothing else may run the loop meanwhile.
            (guard (e ((uv-invalid-argument? e)
                       (set! refused-while-suspended
                             (uv-invalid-argument-reason e))))
              (uv-run loop 'nowait))
            (resume next))))

(uv-loop-teardown! loop)
```

It prints:

```
(run-finished #f refused-while-suspended loop-running)
```

### The safe resume order

Callbacks on one thread nest: each is entered from C, and returns by
jumping back to the C frame that entered it. That jump abandons every
callback entered after it, on the same thread, that has not returned yet.
An abandoned callback can never return.

So you may resume an engine suspended inside a callback only when all of
these hold:

1. You resume it on the same thread it ran on.
2. Every callback entered on that thread since the engine was suspended
   has returned.
3. No callback that was already running when you started the engine has
   returned yet.

The example above is safe: the engine was started outside any callback,
and resumed outside any callback. Starting and resuming an engine within
one call of the same callback is safe too.

Three cases break the order:

- **Two engines suspended inside callbacks.** Resume the later one first.
  Resumed the other way, the earlier one finishes its run, but the later
  one's callback is abandoned, and resuming it raises the error below.
- **An engine started inside a callback that has since returned.** Say a
  scheduler starts an engine from its own timer callback, and lets that
  callback return while the engine is suspended. Resuming the engine
  raises the error, wherever you resume it.
- **An engine resumed from inside a callback entered after it was
  suspended.** The engine finishes its run, but the callback you resumed
  it from is abandoned, and the `uv-run` that callback was part of raises
  the error.

Resumed on another thread, an engine runs the rest of its callback there,
and its return then raises the same error. A thread-checked verb that
callback calls there raises
[`&uv-wrong-thread`](reference.md#uv-wrong-thread-condition-type); an
unchecked one, such as `uv-close!`, runs on the wrong thread
([threads.md](threads.md#the-wrong-thread)).

> ⚠️ **Resuming in the wrong order breaks a loop for good.** The run
> raises Chez's "attempt to return to stale foreign context", and its
> loop is left marked running, as an escape leaves it. Each abandoned
> callback also keeps its heap block until the process exits.

### What engines cost

- An engine resumed while its callback still nests costs nothing.
- An engine dropped while it is suspended inside a callback, never
  resumed, costs what an escape costs: stack and heap
  ([above](#what-an-escape-costs)). Its loop stays marked running.
- An abandoned callback costs its heap block, whether its engine is
  resumed or not.

> ⚠️ **An engine dropped inside a run leaves its loop claimed for good.**
> Dropped inside `uv-run`, or inside a run of a teardown's drain, it
> leaves the loop refused with `'loop-running` from then on, and its
> memory is never freed. One dropped inside `uv-loop-close!` never leaves
> the loop claimed. One dropped anywhere else in a teardown leaves it
> unfinished: call `uv-loop-teardown!` again to finish it.

### Engines inside call-with-uv-loop

Inside `call-with-uv-loop`, an engine's suspension is a way out of the
body like any other. The loop is torn down when the engine is suspended,
and resuming the engine then raises
[`&uv-handle-closed`](reference.md#uv-handle-closed-condition-type).

> ⚠️ **Do not drop an engine suspended inside `call-with-uv-loop`'s
> teardown,** on the way out of its body. Nothing else can tear that loop
> down, so its memory is never freed.

## Read next

- [loops.md](loops.md): running, stopping and tearing down a loop.
- [threads.md](threads.md): which thread owns a loop, and waking one from
  another thread.
- [errors.md](errors.md): every condition type.
