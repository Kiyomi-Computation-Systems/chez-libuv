# Timers

A timer calls your function after a delay, once or again and again. It is
a handle, like a TCP socket: you make it on a loop, start it, and close it
when you are done.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define timer (make-uv-timer loop))

(uv-timer-start! timer
                 (lambda (t)
                   (display "fired once\n")
                   (uv-close! t))
                 50     ; fire after 50 ms
                 0)     ; 0 means never repeat

(uv-run loop 'default)
(uv-loop-teardown! loop)
```

It prints:

```
fired once
```

## The four steps

1. **Make it** with [`make-uv-timer`](reference.md#make-uv-timer-procedure),
   on an open loop.
2. **Start it** with
   [`uv-timer-start!`](reference.md#uv-timer-start-procedure).
3. **Run the loop.** The callback runs inside
   [`uv-run`](reference.md#uv-run-procedure) and nowhere else, so even a
   delay of 0 does not fire until you run.
4. **Close it** with [`uv-close!`](reference.md#uv-close-procedure) when
   you no longer need it. Stopping a timer does not close it.

## Starting a timer

```scheme
(uv-timer-start! timer on-timeout timeout-ms repeat-ms)
```

| Argument     | What to pass                                                       |
|:-------------|:-------------------------------------------------------------------|
| `timer`      | the timer                                                          |
| `on-timeout` | a procedure of one argument; it receives the timer itself          |
| `timeout-ms` | milliseconds until the first fire                                  |
| `repeat-ms`  | milliseconds between later fires, or `0` to fire once              |

Mind the order: the callback comes **before** the two delays.

Both delays are exact integers from 0 up to, but not including, 2^64.
Starting a timer that is already running starts it over with the new
callback and delays.

The callback gets the timer, so one procedure can serve many timers, and
it can stop or close the timer it was called for.

## Repeating timers

Give `repeat-ms` a value above 0, and the timer keeps firing until you
stop or close it.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define timer (make-uv-timer loop))
(define ticks 0)

(uv-timer-start! timer
                 (lambda (t)
                   (set! ticks (+ ticks 1))
                   (display "tick ") (display ticks) (newline)
                   (when (= ticks 3)
                     (uv-close! t)))
                 0      ; first fire on the next loop iteration
                 20)    ; then every 20 ms

(display (uv-timer-repeat timer)) (newline)
(uv-run loop 'default)
(display (uv-handle-state timer)) (newline)
(uv-loop-teardown! loop)
```

It prints:

```
20
tick 1
tick 2
tick 3
closed
```

[`uv-timer-repeat`](reference.md#uv-timer-repeat-procedure) reads the
repeat interval, and
[`uv-timer-set-repeat!`](reference.md#uv-timer-set-repeat-procedure)
changes it.

`uv-run` returned on its own here: once the timer closed, the loop had
nothing left to wait for.

## Stop and again

[`uv-timer-stop!`](reference.md#uv-timer-stop-procedure) disarms a timer.
The timer stays open, and it keeps its callback.

[`uv-timer-again!`](reference.md#uv-timer-again-procedure) restarts a
repeating timer with the callback it already has. It waits the repeat
interval, counted from the loop's cached time
([The cached clock](#the-cached-clock)), then repeats at that interval.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define timer (make-uv-timer loop))
(define fired 0)

(uv-timer-start! timer (lambda (t) (set! fired (+ fired 1))) 10 0)
(uv-timer-stop! timer)               ; disarmed before it could fire
(uv-run loop 'default)               ; returns at once: nothing is armed
(display fired) (newline)

(uv-timer-set-repeat! timer 10)      ; give it a repeat interval,
(uv-timer-again! timer)              ; and restart it with the same callback
(uv-run loop 'once)
(uv-timer-stop! timer)
(display fired) (newline)
(uv-loop-teardown! loop)
```

It prints:

```
0
1
```

Two cases do nothing useful, so watch for them:

- **A timer that was never started** has no callback to restart.
  `uv-timer-again!` raises an `&uv-errno-error` whose errno is `EINVAL`.
- **A timer whose repeat interval is 0** is left as it is: a one-shot
  timer that is still pending still fires once, at its first deadline.

### An idle timeout

`uv-timer-again!` is the natural way to say "fire only after things go
quiet". Each sign of activity pushes the deadline back.

```scheme
(import (rnrs) (libuv))

;; An idle timeout: the timer fires only when 100 ms pass with no activity.
;; Each bit of activity calls uv-timer-again!, which starts the wait over.
(define loop (make-uv-loop))
(define idle (make-uv-timer loop))
(define activity (make-uv-timer loop))
(define pokes 0)

(uv-timer-start! idle
                 (lambda (t)
                   (display "idle after ") (display pokes) (display " pokes\n")
                   (uv-close! t)
                   (uv-close! activity))
                 100 100)          ; repeat must be set for again to restart

(uv-timer-start! activity
                 (lambda (t)
                   (set! pokes (+ pokes 1))
                   (uv-timer-again! idle)       ; push the deadline back
                   (when (= pokes 5) (uv-timer-stop! t)))
                 30 30)

(uv-run loop 'default)
(uv-loop-teardown! loop)
```

It prints:

```
idle after 5 pokes
```

## The cached clock

The loop does not read the clock every time you ask. It reads it once per
iteration and keeps the answer, which
[`uv-now`](reference.md#uv-now-procedure) returns in milliseconds. A
timer's delay counts from that cached time, not from the real one.

Usually the two are close. They drift apart when a callback holds the
loop: it does slow work and only then arms a timer. The cached time is
still from before the slow work, so the new timer comes due early, or at
once.

The fix is one call. Run
[`uv-update-time!`](reference.md#uv-update-time-procedure) before you arm
the timer, and the cached time catches up with the clock.

> ⚠️ After a callback that held the loop, call `uv-update-time!` before
> starting a timer. Otherwise the timer fires early: its delay started
> before your callback did its work.

This program holds the loop for 200 ms in a callback, then arms a 100 ms
timer, and checks whether at least 100 ms really passed:

```scheme
(import (rnrs) (libuv)
        (only (chezscheme) real-time))

;; Busy for about MS milliseconds, holding the loop.
(define (hold-loop ms)
  (let ((until (+ (real-time) ms)))
    (let spin () (when (< (real-time) until) (spin)))))

(define (arm-after-busy-callback refresh?)
  (let* ((loop (make-uv-loop))
         (kick (make-uv-timer loop))
         (deadline (make-uv-timer loop))
         (elapsed #f))
    (uv-timer-start! kick
                     (lambda (t)
                       (hold-loop 200)
                       (when refresh? (uv-update-time! loop))
                       (let ((armed-at (real-time)))
                         (uv-timer-start! deadline
                                          (lambda (d)
                                            (set! elapsed (- (real-time) armed-at))
                                            (uv-close! d))
                                          100 0))
                       (uv-close! t))
                     0 0)
    (uv-run loop 'default)
    (uv-loop-teardown! loop)
    elapsed))

(display (list 'without-update (>= (arm-after-busy-callback #f) 100))) (newline)
(display (list 'with-update (>= (arm-after-busy-callback #t) 100))) (newline)
```

It prints:

```
(without-update #f)
(with-update #t)
```

`uv-update-time!` runs nothing and is safe to call while the loop runs.
Call it on the loop's own thread: from any other thread it raises
`&uv-wrong-thread` ([threads.md](threads.md)).

## Closing a timer

[`uv-close!`](reference.md#uv-close-procedure) starts the close. The loop
finishes it on its next run, and only then is the timer's memory freed.
In between, the timer is `closing`, and it does not fire.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define timer (make-uv-timer loop))

(uv-timer-start! timer (lambda (t) (display "never\n")) 0 10)
(uv-close! timer (lambda () (display "closed\n")))
(display (uv-handle-state timer)) (newline)   ; the close has only started
(uv-run loop 'default)                        ; the loop finishes it
(display (uv-handle-state timer)) (newline)

(display
 (guard (e ((uv-handle-closed? e) 'handle-closed))
   (uv-timer-start! timer (lambda (t) #f) 10 0)
   'no-raise))
(newline)
(uv-loop-teardown! loop)
```

It prints:

```
closing
closed
closed
handle-closed
```

- The optional second argument to `uv-close!` is a callback of no
  arguments. It runs once the close is done.
- Closing twice does nothing. The first close callback is the one that
  runs.
- You do not need to stop a timer before closing it.
- A verb on a closed timer raises `&uv-handle-closed` without touching
  freed memory.
- [`uv-loop-teardown!`](reference.md#uv-loop-teardown-procedure) closes any
  timer you left open ([loops.md](loops.md)).

## Mistakes the timer verbs refuse

Every timer verb checks its arguments first, and raises
`&uv-invalid-argument` with a reason symbol:

| Reason                         | Cause                                             |
|:-------------------------------|:--------------------------------------------------|
| `timeout-out-of-range`         | `timeout-ms` is not an exact integer in 0 to 2^64 − 1 |
| `repeat-out-of-range`          | the same, for `repeat-ms`                         |
| `on-timeout-not-a-procedure`   | the callback is not a procedure, often because the delays came first |
| `not-a-uv-timer`               | a handle of another kind, such as a TCP handle    |
| `not-a-uv-handle`              | not a handle at all                               |

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define timer (make-uv-timer loop))
(define tcp (make-uv-tcp loop))

(define (reason thunk)
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
    (thunk)
    'no-raise))

(display (reason (lambda () (uv-timer-start! timer (lambda (t) #f) -1 0)))) (newline)
(display (reason (lambda () (uv-timer-start! timer 100 0 0)))) (newline)
(display (reason (lambda () (uv-timer-stop! tcp)))) (newline)
(uv-loop-teardown! loop)
```

It prints:

```
timeout-out-of-range
on-timeout-not-a-procedure
not-a-uv-timer
```

[errors.md](errors.md) covers the condition types.

## Read next

- [loops.md](loops.md): running the loop, and tearing it down.
- [callbacks.md](callbacks.md): what a callback such as `on-timeout` may
  do, and what happens when it raises.
- [tcp.md](tcp.md): the other handle you will use most.
