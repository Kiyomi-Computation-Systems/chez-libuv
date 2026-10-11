# The event loop

A loop is a waiting room for events. You give it things to watch, such as
a timer or a socket. When you run it, it waits until one of them has
something to say, then calls your procedure for it. Nothing happens
until you run it.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))                 ; 1. make a loop
(define timer (make-uv-timer loop))          ; 2. give it something to do
(uv-timer-start! timer
                 (lambda (t)
                   (display "the timer fired\n")
                   (uv-close! t))
                 10 0)                       ; once, after 10 ms
(display (uv-run loop 'default))             ; 3. run it until it is done
(newline)
(uv-loop-teardown! loop)                     ; 4. free it
```

It prints:

```
the timer fired
#f
```

## The life of a loop

1. **Make** it with [`make-uv-loop`](reference.md#make-uv-loop-procedure).
2. **Add handles** to it: timers, TCP sockets, processes and the rest.
   Each is made on one loop and stays on it.
3. **Run** it with [`uv-run`](reference.md#uv-run-procedure). Your
   callbacks run in here, and nowhere else.
4. **Tear it down** with
   [`uv-loop-teardown!`](reference.md#uv-loop-teardown-procedure). That
   closes what is still open and frees the loop.

Or let [`call-with-uv-loop`](reference.md#call-with-uv-loop-procedure)
do steps 1 and 4 for you ([below](#let-call-with-uv-loop-do-it)).

> ⚠️ **Nothing is freed by the garbage collector.** A loop you drop
> without tearing it down, and every handle still open on it, stay
> allocated until the process exits. Tear down every loop you make.

## Make a loop

```scheme
(define loop (make-uv-loop))
```

The first loop you make also loads and checks the native library. A loop
belongs to the thread that made it, until another thread runs it
([threads.md](threads.md)).

`uv-loop?` says whether a value is a loop, and
[`uv-loop-open?`](reference.md#uv-loop-open-procedure) whether it is still
open.

## Run it

`(uv-run loop mode)` runs the loop, calling your callbacks as their
events come in. `mode` says how long to keep going:

| Mode       | What it does                                                    |
|:-----------|:----------------------------------------------------------------|
| `'default` | Runs until nothing is left to do. This is the default.          |
| `'once`    | Runs one turn. Waits for something to happen if nothing has.    |
| `'nowait`  | Runs one turn without waiting. Handles only what is ready now.  |

`uv-run` answers `#t` if work remains, and `#f` if none does. Any other
mode is refused with
[`&uv-invalid-argument`](reference.md#uv-invalid-argument-condition-type),
reason `'unknown-run-mode`.

```scheme
(define timer (make-uv-timer loop))
(define fired 0)
(uv-timer-start! timer
                 (lambda (t) (set! fired (+ fired 1)) (uv-close! t))
                 50 0)

;; 'nowait looks once and returns: the timer is not due yet.
(display (list 'nowait (uv-run loop 'nowait) 'fired fired))
(newline)

;; 'once can return before a timer is due, so run it in a capped loop.
(let step ((turns 0))
  (when (and (= fired 0) (< turns 100))
    (uv-run loop 'once)
    (step (+ turns 1))))
(display (list 'once 'fired fired))
(newline)

;; 'default runs until nothing is left: the timer closed, so that is now.
(display (list 'default (uv-run loop 'default)))
(newline)
```

It prints:

```
(nowait #t fired 0)
(once fired 1)
(default #f)
```

One `'once` is not promised to fire a timer that is about to come due:
libuv can end the turn first. When you step a loop with `'once`, step it
until the thing you wait for has happened, with a cap on the number of
turns. Never count on a single call.

**What keeps `'default` going.** Anything active, such as a started
timer, a listening server, an open async handle or a connect still in
flight. A handle that is open but idle, such as a timer that was never
started, does not.

> ⚠️ **An open listening server or async handle keeps `'default` running
> for ever.** Close it when you are done with it, or stop the run with
> `uv-stop!`, or `uv-run` never returns.

## Stop a run early

[`uv-stop!`](reference.md#uv-stop-procedure) asks the current run to end.
Call it from inside a callback. `uv-run` then returns, even though work
remains.

```scheme
(define timer (make-uv-timer loop))
(define fires 0)
(uv-timer-start! timer
                 (lambda (t)
                   (set! fires (+ fires 1))
                   (when (= fires 3) (uv-stop! loop)))
                 0 10)                       ; now, then every 10 ms

(display (list 'run (uv-run loop 'default) 'fires fires
               'alive (uv-loop-alive? loop)))
(newline)

(uv-close! timer)
(display (list 'run (uv-run loop 'default) 'alive (uv-loop-alive? loop)))
(newline)
(uv-loop-close! loop)
(display (list 'open (uv-loop-open? loop)))
(newline)
```

It prints:

```
(run #t fires 3 alive #t)
(run #f alive #f)
(open #f)
```

The first run stopped with the repeating timer still armed, so it
answered `#t`. [`uv-loop-alive?`](reference.md#uv-loop-alive-procedure)
asks the same question without running anything.

A raise from a callback also ends the run
([callbacks.md](callbacks.md#when-a-callback-raises)). Those are the only
two ways. A continuation that escapes a callback does not end the run: it
breaks the loop ([callbacks.md](callbacks.md#escapes)).

## Close the loop

[`uv-loop-close!`](reference.md#uv-loop-close-procedure) closes a loop and
frees it. It works only when every handle on the loop has finished
closing, and no request is still in flight, such as a DNS lookup.
Otherwise it is refused with an
[`&uv-errno-error`](reference.md#uv-errno-error-condition-type) whose
errno is `'EBUSY`, and the loop stays open.

```scheme
(define timer (make-uv-timer loop))           ; open, never started

(guard (e ((uv-errno-error? e)
           (display (list 'refused (uv-errno-error-errno e)))
           (newline)))
  (uv-loop-close! loop))
```

It prints:

```
(refused EBUSY)
```

Closing a closed loop does nothing.

If a callback's raise is still waiting to be delivered, a close that
succeeds raises it, as `uv-run` would have. The loop is closed by then. A
close refused with `'EBUSY` delivers nothing, and the raise keeps
waiting.

## Tear it down

Most of the time you want
[`uv-loop-teardown!`](reference.md#uv-loop-teardown-procedure) instead of
a close. It finishes everything for you:

1. It cancels the loop's DNS lookups that have not started yet.
2. It starts closing every handle that is still open.
3. It runs the loop until those closes, and any requests still in
   flight, have finished. Their callbacks run here.
4. It closes the loop.

Continuing the example above:

```scheme
(uv-loop-teardown! loop)                      ; closes the timer, then the loop
(display (list 'open (uv-loop-open? loop) 'timer (uv-handle-state timer)))
(newline)
(uv-loop-teardown! loop)                      ; a second time does nothing
(uv-loop-close! loop)                         ; and so does a close
```

It prints:

```
(open #f timer closed)
```

- If a callback raises during the teardown, the teardown finishes first,
  then raises the first such raise.
- A DNS lookup that is already running cannot be stopped. The teardown
  waits for it, up to the system resolver's own timeout
  ([dns.md](dns.md)).
- The teardown runs the loop at most 1,024 times. A loop that still has
  work after that is left open, and the teardown raises an
  [`&uv-error`](reference.md#uv-error-condition-type) saying so.

## Let call-with-uv-loop do it

`(call-with-uv-loop proc)` makes a loop, calls `proc` with it, and tears
the loop down however `proc` ends: by returning, by raising, or by a
continuation that leaves it. It answers what `proc` answers, unless the
teardown itself raises: then that raise is what comes out, in place of
`proc`'s value or raise
([callbacks.md](callbacks.md#when-the-teardown-raises)).

Two ways out leave the loop behind, never freed: an escape from a close
callback ([callbacks.md](callbacks.md#escapes)), and an engine dropped
inside the teardown
([callbacks.md](callbacks.md#engines-inside-call-with-uv-loop)).

```scheme
(define kept #f)

(define fires
  (call-with-uv-loop
   (lambda (loop)
     (set! kept loop)
     (let ((timer (make-uv-timer loop))
           (count 0))
       (uv-timer-start! timer
                        (lambda (t)
                          (set! count (+ count 1))
                          (when (= count 3) (uv-stop! loop)))
                        0 10)
       (make-uv-tcp loop)                     ; left open on purpose
       (uv-run loop 'default)
       count))))

(display (list 'fires fires 'loop-open (uv-loop-open? kept)))
(newline)
```

It prints:

```
(fires 3 loop-open #f)
```

The timer and the TCP handle were still open when the body returned. The
teardown closed them.

`proc` runs once. Once it has been left, a continuation that tries to
re-enter it is refused. [callbacks.md](callbacks.md#raises-from-the-body-of-call-with-uv-loop)
says what happens to a raise from the body.

## Cached time

[`uv-now`](reference.md#uv-now-procedure) answers the loop's idea of
"now", in milliseconds. It is a cached value. The loop reads the clock
once per turn, and the value does not move between those reads.

[`uv-update-time!`](reference.md#uv-update-time-procedure) reads the clock
again, now. It runs no callbacks, and you may call it while the loop runs.

```scheme
(uv-timer-start! timer
                 (lambda (t)
                   (let ((a (uv-now loop)))
                     (sleep (make-time 'time-duration 0 1))   ; hold the loop 1 s
                     (let ((b (uv-now loop)))
                       (uv-update-time! loop)
                       (let ((c (uv-now loop)))
                         (display (list 'cached-time-moved (not (= a b))
                                        'after-update-moved-1s (>= (- c a) 1000)))
                         (newline))))
                   (uv-close! t))
                 0 0)
```

It prints:

```
(cached-time-moved #f after-update-moved-1s #t)
```

(`sleep` and `make-time` come from `(chezscheme)`.)

**Why it matters: timers count from the cached time.** Say a callback
spends a second working, then starts a 100 ms timer. The timer counts
from the "now" cached before that second, so it is due at once. Call
`uv-update-time!` first, and it counts from the real now
([timers.md](timers.md)).

`uv-update-time!` is checked to be on the loop's thread
([threads.md](threads.md)). `uv-now` is not checked, but belongs there
just the same.

## Live handles

[`uv-loop-live-handles`](reference.md#uv-loop-live-handles-procedure)
answers a fresh list of the handles on the loop. A handle leaves the list
once its close has finished, not when it starts.

```scheme
(define a (make-uv-timer loop))
(define b (make-uv-tcp loop))
(display (list 'live (length (uv-loop-live-handles loop))))
(newline)
(uv-close! a)
(display (list 'after-close (length (uv-loop-live-handles loop))))
(newline)
(uv-run loop 'nowait)
(display (list 'after-run (length (uv-loop-live-handles loop))))
(newline)
```

It prints:

```
(live 2)
(after-close 2)
(after-run 1)
```

It is a debugging aid: it copies a table shared by every loop in the
process, so it is not free ([threads.md](threads.md#several-loops-on-several-threads)).

## Deferred errors

When a callback raises, `uv-run` raises it again
([callbacks.md](callbacks.md#when-a-callback-raises)). Only the first
raise of a run is raised. Every later raise in the same run is kept, in
order, and [`uv-loop-deferred-errors`](reference.md#uv-loop-deferred-errors-procedure)
answers them.

```scheme
(define (failing-timer message)
  (let ((t (make-uv-timer loop)))
    (uv-timer-start! t (lambda (t) (error 'on-timeout message)) 0 0)
    t))
(failing-timer "first")
(failing-timer "second")

(guard (e ((uv-callback-error? e)
           (display (list 'raised (condition-message e)))
           (newline)))
  (uv-run loop 'default))

(display (list 'deferred (map condition-message (uv-loop-deferred-errors loop))))
(newline)
```

It prints:

```
(raised first)
(deferred (second))
```

- The list starts empty at each run, so read it before you run the loop
  again.
- Read it before you close the loop, too. On a closed loop it raises
  [`&uv-handle-closed`](reference.md#uv-handle-closed-condition-type).

## Stack headroom

Every run needs some C stack under it. A callback that is left by a
continuation leaves its run's C frames on the thread's stack for as long
as the thread lives ([callbacks.md](callbacks.md#what-an-escape-costs)).
Enough of them, and the stack overflows: the process crashes.

So before each run, the library measures how much C stack the thread has
left. With less than 128 KiB, `uv-run` refuses to start. It raises
[`&uv-stack-exhausted`](reference.md#uv-stack-exhausted-condition-type),
whose fields say how much was left (`headroom`) and how much the run
needed (`floor`). A teardown needs only 64 KiB, so a loop whose run was
refused can still be torn down. `call-with-uv-loop` still tears its loop
down around a `uv-run` that raised this.

```scheme
(guard (e ((uv-stack-exhausted? e)
           (display (list 'stack-exhausted
                          (uv-stack-exhausted-headroom e)
                          (uv-stack-exhausted-floor e)))
           (newline)))
  (call-with-uv-loop
   (lambda (loop)
     (let ((timer (make-uv-timer loop)))
       (uv-timer-start! timer (lambda (t) (uv-close! t)) 0 0)
       (uv-run loop 'default)
       (display "ran normally\n")))))
```

Run on the main thread, which has plenty of stack, it prints:

```
ran normally
```

> ⚠️ **A thread that gets `&uv-stack-exhausted` cannot get its stack
> back.** Trying again gains nothing. Tear its loops down and end the
> thread. If your program leaves callbacks by continuation as a habit, do
> it on a thread you can end.

## Read next

- [callbacks.md](callbacks.md): what a callback may do, raises, escapes
  and engines.
- [threads.md](threads.md): which thread owns a loop, and waking one from
  another thread.
- [timers.md](timers.md): one-shot and repeating timers.
- [errors.md](errors.md): every condition type.
