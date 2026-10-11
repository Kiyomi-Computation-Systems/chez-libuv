# Threads

Each loop belongs to one thread at a time. Only that thread may use the
loop and its handles. Other threads reach it one way: they wake it with
an async handle, and the loop's own thread does the work.

```scheme
(import (chezscheme) (libuv))

;; 1. Build the loop on this thread.
(define loop (make-uv-loop))
(define timer (make-uv-timer loop))
(uv-timer-start! timer
                 (lambda (t)
                   (display "the timer fired on the loop thread\n")
                   (uv-close! t))
                 10 0)

;; 2. Hand it over: the thread that runs it owns it from then on.
(define loop-thread (fork-thread (lambda () (uv-run loop 'default))))
(thread-join loop-thread)

;; 3. This thread no longer owns the loop.
(guard (e ((uv-wrong-thread? e)
           (display (list 'wrong-thread (uv-wrong-thread-who e)
                          'owner-is-not-me (not (= (uv-wrong-thread-expected e)
                                                    (uv-wrong-thread-actual e)))))
           (newline)))
  (make-uv-timer loop))

;; 4. Running it again takes it back.
(uv-run loop 'nowait)
(display (list 'made-a-timer (uv-timer? (make-uv-timer loop))))
(newline)
(uv-loop-teardown! loop)
```

It prints:

```
the timer fired on the loop thread
(wrong-thread make-uv-timer owner-is-not-me #t)
(made-a-timer #t)
```

The library needs a threaded Chez, which is Chez's default build
([installing.md](installing.md)).

## Which thread owns a loop

A loop's owner is:

1. the thread that made it, until
2. another thread runs it with `uv-run`, or tears it down with
   `uv-loop-teardown!`. That thread is the owner from then on, even after
   `uv-run` returns.

A close with `uv-loop-close!` does not change the owner, and neither does
a call that is refused.

Why one thread? libuv's loop is not thread-safe. Its structures are
changed without locks, so two threads using one loop at once would
corrupt it.

While the owner waits inside `uv-run`, other Scheme threads keep running.
They allocate and collect garbage freely: a waiting loop does not hold up
the collector.

## Hand a loop to another thread

You can build a loop on one thread and run it on another, as the example
above does:

1. Make the loop and its handles on the first thread.
2. Stop using the loop there.
3. Start the other thread, and have it call `uv-run`. From that call on,
   it owns the loop.

> ⚠️ **Hand a loop over only once its builder is done with it.** The
> thread check cannot see a call made on the old thread while the new
> thread is entering `uv-run`. Such a call can corrupt the loop.

## The wrong thread

Most verbs check the thread before they touch anything. Called from a
thread that does not own the loop, they raise
[`&uv-wrong-thread`](reference.md#uv-wrong-thread-condition-type) and
change nothing. These are checked:

- every verb on an open handle (writes, reads, timer starts and the
  rest), except `uv-close!` and `uv-async-send!`;
- every verb that makes something on a loop: the handle constructors,
  `uv-accept!`, `uv-spawn!`, `uv-getaddrinfo!` and `uv-getnameinfo!`;
- `uv-cancel!` and `uv-update-time!`.

The condition has three fields:

| Field      | Accessor                   | What it holds                      |
|:-----------|:---------------------------|:-----------------------------------|
| `who`      | `uv-wrong-thread-who`      | the verb that refused              |
| `expected` | `uv-wrong-thread-expected` | the id of the thread that owned the loop |
| `actual`   | `uv-wrong-thread-actual`   | the id of the calling thread       |

`expected` and `actual` always differ.

The check covers every verb on an open handle except `uv-close!`, every
verb that makes something on a loop (the handle constructors, `uv-accept!`,
`uv-spawn!`, `uv-getaddrinfo!` and `uv-getnameinfo!`), `uv-cancel!` and
`uv-update-time!`. The rest are not checked:

- `uv-close!`;
- the loop verbs `uv-stop!`, `uv-loop-close!`, `uv-now`, `uv-loop-alive?`,
  `uv-loop-open?`, `uv-loop-live-handles` and `uv-loop-deferred-errors`.

They belong to the loop's thread all the same. (`uv-run` and
`uv-loop-teardown!` are not checked either: called from another thread,
they take the loop over.)

> ⚠️ **Call unchecked verbs only from the loop's thread.** Nothing stops
> `uv-close!` or `uv-stop!` from running on another thread, and there
> they race the loop's own thread on structures that have no lock. To
> stop or close something from another thread, wake the loop instead
> ([below](#wake-a-loop-from-another-thread)).

The same holds inside an engine. A checked verb whose engine is suspended
while the loop is handed to another thread raises `&uv-wrong-thread` when
it is resumed. An unchecked verb does not: it carries on, on the wrong
thread.

> ⚠️ **Do not hand a loop on while an engine is suspended inside
> `uv-close!`** on one of its handles. Resumed, it closes the handle from
> a thread that does not own the loop.

## One call inside a loop at a time

`uv-run`, `uv-loop-close!` and `uv-loop-teardown!` each claim the loop
before they call libuv, and give the claim back when they are done. While
one call holds it, the others are refused with
[`&uv-invalid-argument`](reference.md#uv-invalid-argument-condition-type),
reason `'loop-running`, from any thread. A refused call changes nothing,
not even the owner.

A callback is inside a run, so it meets the same refusal:

```scheme
(define (reason thunk)
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
    (thunk)
    'no-refusal))

(uv-timer-start! timer
                 (lambda (t)
                   (display (list 'run (reason (lambda () (uv-run loop 'nowait)))
                                  'close (reason (lambda () (uv-loop-close! loop)))
                                  'teardown (reason (lambda () (uv-loop-teardown! loop)))))
                   (newline)
                   (uv-close! t))
                 0 0)
(uv-run loop 'default)
```

It prints:

```
(run loop-running close loop-running teardown loop-running)
```

So the loop's callbacks never run on two threads at once. Running one loop
from two threads is still a bug in the caller, but the second call is
refused by name instead of corrupting anything.

A teardown claims the loop separately for each of its steps: starting the
closes, each run of its drain, and closing the loop. Another call can get
in between steps. Then:

- a teardown that finds the loop already closed just returns;
- one that finds it claimed is refused with `'loop-running`, with its
  handles already closing. Call it again later to finish.

## Wake a loop from another thread

An async handle is how another thread asks the loop's thread to do
something.

- [`make-uv-async`](reference.md#make-uv-async-procedure) `(loop on-wake)`
  makes one. Call it on the loop's thread.
- [`uv-async-send!`](reference.md#uv-async-send-procedure) `(async)` wakes
  the loop. It is the one verb you may call from **any** thread.
- When the loop wakes, it calls `on-wake` on the loop's thread, with the
  async handle.

**Sends coalesce.** Several sends can produce one `on-wake`. So do not
pass work in the send. Keep your own queue, and have `on-wake` empty it.
It may find the queue empty, too.

**A send that races a close is refused.** A send either finishes before a
close begins, or raises
[`&uv-handle-closed`](reference.md#uv-handle-closed-condition-type)
without touching the handle. That holds from any thread, and inside
engines.

> ⚠️ **A close drops wakes still pending.** Once `uv-close!` has started
> on an async handle, `on-wake` never runs again, even for a send made
> before the close. Items you queued for it are lost unless you drain the
> queue once more yourself after closing.

> ⚠️ **An open async handle keeps `uv-run 'default` from returning.**
> There is no way to exempt it. Close it when you are done, or the run
> never ends.

A refused send tells the sender only that its wake was not sent. To know
exactly which items will be handled, follow these steps:

1. Keep a mutex of your own, a queue, and an "open" flag.
2. A sender takes the mutex, checks the flag, and only if it is set,
   queues its item and sends. A sender that finds the flag clear knows its
   item was not queued.
3. `on-wake` takes the mutex to empty the queue, then handles the items.
4. To shut down, the loop's thread clears the flag under the mutex, then
   closes the async handle, then empties the queue one last time.

Every item queued is then handled. Here a worker thread sends five items:

```scheme
(import (chezscheme) (libuv))

(define loop (make-uv-loop))

;; Your own queue, guarded by your own mutex, with an open flag.
(define lock (make-mutex))
(define queue '())
(define open #t)
(define handled '())

(define (take-all!)
  (with-mutex lock
    (let ((items (reverse queue)))
      (set! queue '())
      items)))

(define (handle! items)
  (set! handled (append handled items)))

(define async
  (make-uv-async loop
                 (lambda (a)                    ; runs on the loop thread
                   (handle! (take-all!))        ; may find the queue empty
                   (when (>= (length handled) 5)
                     (with-mutex lock (set! open #f))
                     (uv-close! a)
                     (handle! (take-all!))))))  ; the final drain

;; Any thread: queue an item and wake the loop, or answer #f.
(define (submit! item)
  (with-mutex lock
    (and open
         (begin
           (set! queue (cons item queue))
           (uv-async-send! async)
           #t))))

(define worker
  (fork-thread
   (lambda ()
     (do ((i 1 (+ i 1))) ((> i 5))
       (submit! i)))))

(uv-run loop 'default)            ; returns once the async is closed
(thread-join worker)
(display (list 'handled handled 'late-submit (submit! 6)))
(newline)
(uv-loop-teardown! loop)
```

It prints:

```
(handled (1 2 3 4 5) late-submit #f)
```

Closing the async handle from `on-wake` is also what ended the run. The
same pattern stops a loop from another thread: send a wake, and have
`on-wake` close what keeps the loop running, or call `uv-stop!`.

`uv-async-send!` holds its handle's lock only around one native call,
with interrupts disabled. So you may call it with interrupts disabled, or
from a collect-request handler. Sends to one handle from several threads
take turns on that lock.

## Several loops on several threads

Each thread can run a loop of its own, at the same time: one per core,
for instance.

```scheme
(import (chezscheme) (libuv))

(define (count-ticks name ticks)
  (call-with-uv-loop
   (lambda (loop)
     (let ((timer (make-uv-timer loop))
           (count 0))
       (uv-timer-start! timer
                        (lambda (t)
                          (set! count (+ count 1))
                          (when (= count ticks) (uv-close! t)))
                        0 5)
       (uv-run loop 'default)
       (list name count)))))

(define results (make-vector 2 #f))
(define a (fork-thread (lambda () (vector-set! results 0 (count-ticks 'a 3)))))
(define b (fork-thread (lambda () (vector-set! results 1 (count-ticks 'b 4)))))
(thread-join a)
(thread-join b)
(display results)
(newline)
```

It prints:

```
#((a 3) (b 4))
```

The loops share one thing: the library's table from libuv's pointers back
to your handles and requests. It has one lock. Every constructor,
callback and close takes it briefly, for a table operation or two.
What that costs, measured:

- On one thread, about 30 ns each time, allocating nothing.
- Threads that do nothing but make, fire and close handles contend for
  it. At four threads, timers made and closed that way took 1.6 to 2.2
  times as long as with a table for each loop.
- A loopback round trip took as long as with a table for each loop, up to
  four threads: each loop thread spends most of its time waiting on the
  kernel. At eight threads it took 7% longer, within the runs' spread.

Two calls copy the whole table, every loop's entries, while they hold the
lock: `uv-loop-teardown!` (so every `call-with-uv-loop` exit too) and
`uv-loop-live-handles`. One took about 0.7 ms at 100,000 entries, and
13 ms at 1,000,000, on macOS arm64. Every other loop's thread waits that
out at its next constructor, callback or close.

## Read next

- [loops.md](loops.md): running, stopping and tearing down a loop.
- [callbacks.md](callbacks.md): raises, escapes and engines inside
  callbacks.
- [dns.md](dns.md): the one feature that uses libuv's worker threads.
- [errors.md](errors.md): every condition type.
