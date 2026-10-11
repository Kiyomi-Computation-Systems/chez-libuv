# Signals

A signal handle watches for one signal sent to your process, such as
`SIGTERM` or `SIGHUP`, and calls your procedure when it arrives. libuv
catches the signal; your procedure runs later, inside `uv-run`, on the
loop's thread, like any other callback.

To *send* a signal, use `uv-kill!` or `uv-process-kill!`
([processes](processes.md)).

## A first watcher

This program watches `SIGUSR1`, sends it to itself three times, and closes
the watcher after the third.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define watcher (make-uv-signal loop))
(define seen 0)

(uv-signal-start! watcher 'sigusr1
                  (lambda (sig)
                    (set! seen (+ seen 1))
                    (display (list 'got sig seen)) (newline)
                    (if (< seen 3)
                        (uv-kill! (uv-os-getpid) 'sigusr1)   ; once more
                        (uv-close! watcher))))

(uv-kill! (uv-os-getpid) 'sigusr1)
(uv-run loop 'default)
(uv-loop-teardown! loop)
```

It prints:

```
(got sigusr1 1)
(got sigusr1 2)
(got sigusr1 3)
```

The first signal was sent before `uv-run` started. It waited, and was
delivered once the loop ran.

## The verbs

| Verb | What it does |
|:--|:--|
| [`make-uv-signal`](reference.md#make-uv-signal-procedure) | `(make-uv-signal loop)`: a new watcher, not yet watching |
| [`uv-signal-start!`](reference.md#uv-signal-start-procedure) | `(uv-signal-start! watcher signal on-signal)`: call `on-signal` on every delivery |
| [`uv-signal-start-oneshot!`](reference.md#uv-signal-start-oneshot-procedure) | the same arguments: call it on the next delivery only, then stop |
| [`uv-signal-stop!`](reference.md#uv-signal-stop-procedure) | `(uv-signal-stop! watcher)`: stop watching |
| [`uv-signal?`](reference.md#uv-signal-predicate) | whether a value is a signal handle |

`on-signal` receives the signal as a symbol, such as `'sigusr1`.

You can watch `sigterm`, `sigint`, `sighup`, `sigquit`, `sigusr1`,
`sigusr2` and `sigcont`.

- `sigkill` and `sigstop` are refused with `&uv-invalid-argument`, reason
  `'signal-unwatchable`. The kernel does not let any process catch them.
- `0` can be sent but not watched: reason `'signal-unknown`.
- Any other symbol is refused with `'signal-unknown`.

## Stop is not close

Neither a delivery nor `uv-signal-stop!` closes the handle. A one-shot
watcher that has fired is stopped, but still open. Close every watcher with
`uv-close!` when you are done with it.

Once you have called `uv-close!`, a signal still waiting to be delivered
is dropped: the binding never calls the handler of a closing watcher.

## One shot

A one-shot watcher fires once and stops itself. The first start verb you
use fixes a watcher's mode **for its whole life**: after a one-shot start,
`uv-signal-start!` is refused, and the other way round. To change mode,
close the watcher and make a new one.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define watcher (make-uv-signal loop))

(uv-signal-start-oneshot! watcher 'sigusr2
                          (lambda (sig) (display (list 'once sig)) (newline)))
(uv-kill! (uv-os-getpid) 'sigusr2)
(uv-run loop 'default)
(display (uv-handle-state watcher)) (newline)    ; delivered, not closed

(define (reason thunk)
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
    (thunk)
    'accepted))

;; The first start fixed the mode.
(display (reason (lambda () (uv-signal-start! watcher 'sigusr2 (lambda (s) #f)))))
(newline)
(display (reason (lambda () (uv-signal-start-oneshot! watcher 'sigusr2 (lambda (s) #f)))))
(newline)
(uv-close! watcher)

;; Some signals cannot be watched.
(define other (make-uv-signal loop))
(display (reason (lambda () (uv-signal-start! other 'sigkill (lambda (s) #f)))))
(newline)
(display (reason (lambda () (uv-signal-start! other 0 (lambda (s) #f)))))
(newline)
(display (reason (lambda () (uv-signal-start! other 'sigwinch (lambda (s) #f)))))
(newline)
(uv-close! other)
(uv-loop-teardown! loop)
```

It prints:

```
(once sigusr2)
open
signal-mode-fixed
accepted
signal-unwatchable
signal-unknown
signal-unknown
```

> ⚠️ Rearming a one-shot watcher from inside its own callback does
> nothing. libuv stops the watcher after the callback returns, which undoes
> the new start, so the next signal is not caught by it. Rearm it later,
> from another callback or after `uv-run` returns, as the example above
> does.

## Graceful shutdown

The usual reason to watch a signal is to shut down cleanly. Watch
`SIGTERM` once. When it comes, stop taking new work, let the work in hand
finish, and close up. A second `SIGTERM` then kills the process, because
after a one-shot fires the signal's handling goes back to the system
default.

```scheme
(import (rnrs) (libuv))

;; Graceful shutdown: the first SIGTERM stops the work and closes up.
(define loop (make-uv-loop))
(define work (make-uv-timer loop))
(define watcher (make-uv-signal loop))
(define ticks 0)

(uv-timer-start! work (lambda (t) (set! ticks (+ ticks 1))) 0 10)

(uv-signal-start-oneshot! watcher 'sigterm
  (lambda (sig)
    (display "draining\n")
    (uv-close! work)
    (uv-close! watcher)))

;; Stand-in for another process sending SIGTERM after a while.
(define sender (make-uv-timer loop))
(uv-timer-start! sender
                 (lambda (t)
                   (uv-close! t)
                   (uv-kill! (uv-os-getpid) 'sigterm))
                 50 0)

(uv-run loop 'default)
(uv-loop-teardown! loop)
(display (list 'worked (> ticks 0))) (newline)
```

It prints:

```
draining
(worked #t)
```

In a server, the handler would close the listening socket and start a
timer that bounds the drain.

## What a handler may do

A handler is an ordinary callback. It does not run inside the operating
system's signal handler, so the usual limits of signal handlers do not
apply. It may do what any callback may:

- call any verb on its loop, as the first example sends another signal;
- close handles, its own watcher included;
- stop the run with `uv-stop!`;
- raise. The run stops, and `uv-run` raises the condition again, wrapped
  in `&uv-callback-error` ([errors](errors.md)).

The rules every callback follows are on the [callbacks](callbacks.md) page.

## SIGINT and Chez

> ⚠️ Watching `sigint` takes `SIGINT` away from Chez. While the watcher is
> armed, Ctrl-C goes to your handler, and Chez's own keyboard interrupt
> never fires. This applies to handlers installed with Chez's
> `register-signal-handler` too.

> ⚠️ Once the watcher stops, or a one-shot fires, `SIGINT` is **not** given
> back to Chez. Its handling becomes the system default, so the next
> `SIGINT` ends the process. The same holds for every signal: stopping the
> last watcher of a signal leaves the default.

This is libuv's behaviour, and the binding passes it on rather than hide
it. A program that watched `SIGINT`, stopped, and sent itself `SIGINT`
again was killed: its shell reported exit status 130.

## Threads

Make, start, stop and close a watcher on its loop's thread.
`make-uv-signal` and the start and stop verbs raise `&uv-wrong-thread` from
any other thread. `uv-close!` does not check, but belongs on the loop's
thread all the same ([threads](threads.md)).

## Read next

- [Processes and pipes](processes.md): sending signals with `uv-kill!`.
- [Callbacks](callbacks.md): what any callback may do.
- [Errors](errors.md): the conditions these verbs raise.
