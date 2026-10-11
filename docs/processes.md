# Processes and pipes

`uv-spawn!` starts another program as a child process and hands you a
process handle for it. A pipe connects one of the child's standard streams
to your loop, so you can read what it prints or write what it reads.

This page assumes you can already run a loop. If not, start with the
[quickstart](quickstart.md) and [the event loop](loops.md).

## A first child

This program runs `echo`, reads what it prints through a pipe, and reports
how it exited.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define out (make-uv-pipe loop))
(define chunks '())

(define child
  (uv-spawn! loop "echo" '("echo" "hello from a child")
             (list (cons 'stdio (list 'ignore (list 'pipe out 'from-child))))
             (lambda (status signal)
               (display (list 'exit status signal))
               (newline)
               (uv-close! child))))

(uv-read-start! out
                (lambda (bv start end)                 ; on-data
                  (set! chunks (cons (utf8->string
                                      (let ((b (make-bytevector (- end start))))
                                        (bytevector-copy! bv start b 0 (- end start))
                                        b))
                                     chunks)))
                (lambda () (uv-close! out))            ; on-eof
                (lambda (err) (uv-close! out)))        ; on-error

(uv-run loop 'default)
(uv-loop-teardown! loop)
(display (apply string-append (reverse chunks)))
```

It prints:

```
(exit 0 #f)
hello from a child
```

The steps are always the same:

1. **Make a pipe** with [`make-uv-pipe`](reference.md#make-uv-pipe-procedure)
   for each stream you want to talk to.
2. **Spawn the child** with [`uv-spawn!`](reference.md#uv-spawn-procedure),
   naming each pipe in the `stdio` option. The child is running when it
   returns.
3. **Read or write the pipes** with the stream verbs, as you would a TCP
   connection ([TCP and streams](tcp.md)).
4. **Close the process handle** when the exit callback runs, and close each
   pipe when you are done with it.
5. **Run the loop.** The exit callback and the reads happen inside
   `uv-run`, and nowhere else.

## Spawning a child

```scheme
(uv-spawn! loop file args on-exit)
(uv-spawn! loop file args options on-exit)
```

- **`file`** is the program to run. libuv looks it up the way `execvp`
  does, so a bare name such as `"echo"` is searched for on `PATH`, and a
  path such as `"/bin/echo"` is used as it is. The binding does not check
  that it exists: a missing program is a failed spawn
  ([When a spawn fails](#when-a-spawn-fails)).
- **`args`** is the child's whole argument list, `argv[0]` included. It must
  not be empty. By convention `argv[0]` is the program's name, which is why
  the example passes `"echo"` twice.
- **`options`** is an association list, described next. Leave it out, or
  pass `#f` or `'()`, for none.
- **`on-exit`** is called once, when the child exits. Pass `#f` if you do not
  need to know.

Every string must be free of NUL characters, because C would cut it short
there. A string with one is refused with `&uv-invalid-argument`.

`uv-spawn!` reads `file`, `args` and `options` once, early in the call, and
works only from what it read. A change an engine's timer handler makes
meanwhile reaches the child as it was before the change or after it, never
a mix, and so does a list another thread changes once.

> ⚠️ Don't let another thread keep changing a string or list you passed
> while `uv-spawn!` runs. A string or list changed several times during the
> read can reach the child as pieces of more than one version, and a list
> that was well formed in every version can be refused as malformed with
> `&uv-invalid-argument`. No lock in the binding can order that thread's
> writes against the read.

## The options

| Key | Value | Default |
|:--|:--|:--|
| `env` | a list of `"NAME=value"` strings | the parent's environment |
| `cwd` | the directory to start the child in | the parent's |
| `stdio` | one entry per file descriptor, starting at 0 | all three ignored |
| `detached` | `#t` or `#f` | `#f` |
| `uid` | the user id to run the child as | not changed |
| `gid` | the group id to run the child as | not changed |

An unknown key, or the same key twice, is refused with `&uv-invalid-argument`
(reasons `'option-unknown` and `'option-duplicate`).

The `env` list is the child's **whole** environment, not additions to
yours. An empty list gives the child an empty environment. This program
sets two variables and a working directory, and lets the child write
straight to the parent's standard output:

```scheme
(import (rnrs) (libuv))

;; env, cwd, and inheriting our own stdout.
(define loop (make-uv-loop))

(define child
  (uv-spawn! loop "sh" '("sh" "-c" "echo \"$GREETING from $(pwd)\"")
             (list (cons 'env '("GREETING=hello" "PATH=/bin:/usr/bin"))
                   (cons 'cwd "/tmp")
                   (cons 'stdio (list 'ignore '(inherit-fd . 1))))
             (lambda (status signal) (uv-close! child))))

(uv-run loop 'default)
(uv-loop-teardown! loop)
```

It prints:

```
hello from /tmp
```

## Wiring stdio

The `stdio` list has one entry per file descriptor in the child. The first
is its standard input (0), then standard output (1), then standard error
(2). A list shorter than three is padded with `ignore`. Each entry is one
of these:

| Entry | The child's descriptor is |
|:--|:--|
| `ignore` | `/dev/null`, for 0, 1 and 2 |
| `(inherit-fd . n)` | a copy of the parent's descriptor `n` |
| `(inherit-stream . h)` | a copy of the descriptor of `h`, an open TCP or pipe handle |
| `(pipe p direction)` | one end of a new pipe; the other end goes into `p` |

For a `pipe` entry, `p` is a fresh handle from `make-uv-pipe`, and
`direction` says which way the bytes flow, **seen from the parent**:

| Direction | Bytes flow | Use it for |
|:--|:--|:--|
| `to-child` | from you to the child | its standard input |
| `from-child` | from the child to you | its standard output or error |
| `duplex` | both ways | a descriptor the child reads and writes |

The names follow the parent on purpose. libuv's own flags are named from
the child's side, and that is easy to get backwards.

## Talking to a child

This program writes a line to `cat` and reads it back. Closing your end of
the input pipe, here with `uv-shutdown!`, is what tells `cat` its input is
over. Then `cat` exits and its output pipe reaches end of file.

```scheme
(import (rnrs) (libuv))

;; Talk to cat: write to its stdin, read its stdout.
(define loop (make-uv-loop))
(define to-cat (make-uv-pipe loop))
(define from-cat (make-uv-pipe loop))
(define got '())

(define cat
  (uv-spawn! loop "cat" '("cat")
             (list (cons 'stdio (list (list 'pipe to-cat 'to-child)
                                      (list 'pipe from-cat 'from-child))))
             (lambda (status signal) (uv-close! cat))))

(uv-read-start! from-cat
                (lambda (bv start end)
                  (let ((b (make-bytevector (- end start))))
                    (bytevector-copy! bv start b 0 (- end start))
                    (set! got (cons (utf8->string b) got))))
                (lambda () (uv-close! from-cat))
                (lambda (err) (uv-close! from-cat)))

(uv-write! to-cat (string->utf8 "round trip\n") (lambda (err) #f))
;; Shutting down our end is what tells cat its input is over.
(uv-shutdown! to-cat (lambda (err) (uv-close! to-cat)))

(uv-run loop 'default)
(uv-loop-teardown! loop)
(display (apply string-append (reverse got)))
```

It prints:

```
round trip
```

## Pipes

A pipe here exists for one job: to be one of a child's stdio streams. It
has no `bind`, `connect` or `listen`, and it never carries file
descriptors between processes.

- A new pipe is **open but not connected**. Start reading or writing it only
  after `uv-spawn!` has returned: the spawn is what connects it.
- Once connected, it is a stream. `uv-read-start!`, `uv-write!`,
  `uv-shutdown!` and the rest work on it as they do on TCP
  ([TCP and streams](tcp.md), [flow control](flow-control.md)).
- **A pipe is used once.** A spawn that reaches libuv uses up every pipe it
  names, in a `(pipe p direction)` entry or an `(inherit-stream . p)` entry
  alike, whether the child starts or not. Naming a used pipe in a
  `(pipe p direction)` entry, or naming one pipe in two such entries of one
  spawn, is refused with `&uv-invalid-argument`, reason
  `'pipe-already-used`.
- The pipe and the process must be on the same loop.
- [`uv-pipe?`](reference.md#uv-pipe-predicate) tells you whether a value is
  a pipe handle.

## The exit callback

`on-exit` receives two values, `status` and `signal`. It never receives a
condition: a child that failed is still a child that exited.

| How the child ended | `status` | `signal` |
|:--|:--|:--|
| It exited normally | its exit code | `#f` |
| A signal killed it | `0` | the signal, such as `'sigterm` |

A killed child reports a status of `0`, not `-1`. Look at `signal` to tell
the two apart. A signal outside the named set (below) arrives as its
number, so nothing is lost.

```scheme
(import (rnrs) (libuv))

;; Exit status and a signal death.
(define loop (make-uv-loop))

(define a
  (uv-spawn! loop "sh" '("sh" "-c" "exit 3")
             (lambda (status signal)
               (display (list 'sh-exited status signal)) (newline)
               (uv-close! a))))

(define b
  (uv-spawn! loop "sleep" '("sleep" "30")
             (lambda (status signal)
               (display (list 'sleep-exited status signal)) (newline)
               (uv-close! b))))

(display (list 'pid-is-integer (integer? (uv-process-pid b)))) (newline)
(uv-process-kill! b 'sigterm)

(uv-run loop 'default)
(uv-loop-teardown! loop)
```

It prints:

```
(pid-is-integer #t)
(sh-exited 3 #f)
(sleep-exited 0 sigterm)
```

A child killed with `SIGALRM`, which has no name here, reported
`(0 14)` on Linux. The number is the platform's.

### Exit is not close

When `on-exit` runs, the process handle is stopped but still open. You
close it yourself, usually from inside `on-exit`, as every example here
does. This is the same rule as for a TCP connection: a handle's memory is
released only by its close.

> ⚠️ A process handle you never close keeps its memory until the loop is
> torn down. `on-exit` does not close it for you.

> ⚠️ Close each handle from one place. A second `uv-close!` on a handle that
> is already closing does nothing, and the `on-close` callback you passed it
> **never runs**. Only the first close's callback is kept. This holds for
> every kind of handle.

## Signals and pids

| Verb | What it does |
|:--|:--|
| [`uv-process-kill!`](reference.md#uv-process-kill-procedure) | `(uv-process-kill! process signal)`: signal a child by its handle |
| [`uv-kill!`](reference.md#uv-kill-procedure) | `(uv-kill! pid signal)`: signal any process by its pid |
| [`uv-process-pid`](reference.md#uv-process-pid-procedure) | the child's pid |
| [`uv-os-getpid`](reference.md#uv-os-getpid-procedure) | this process's own pid |

A signal is one of these symbols: `sigterm`, `sigkill`, `sigint`, `sighup`,
`sigquit`, `sigusr1`, `sigusr2`, `sigcont` and `sigstop`. The number `0`
sends nothing; it only checks that the process exists, and raises if it does
not. Anything else is refused with `&uv-invalid-argument`, reason
`'signal-unknown`. A failed send raises `&uv-errno-error`, such as `'ESRCH`
for a process that is gone.

The pid keeps its `kill(2)` meaning:

- a positive pid is that one process;
- `0` is every process in your own process group;
- `-1` is every process you are allowed to signal;
- any other negative pid, such as `-1234`, is every process in process
  group 1234.

> ⚠️ `-1` is not a process group. `(uv-kill! -1 'sigkill)` kills every
> process you are allowed to signal. Negating a group id of 1 gives exactly
> that, so check a pid you computed before you send to it.

A pid must fit a C `int`, from -2147483648 to 2147483647. Any other is
refused with `&uv-invalid-argument`, reason `'pid-out-of-range`, before
anything is sent.

```scheme
(import (rnrs) (libuv))

;; pid, uv-kill!, and the pid after close.
(define loop (make-uv-loop))
(define exited #f)

(define child
  (uv-spawn! loop "sleep" '("sleep" "30")
             (lambda (status signal)
               (set! exited (list status signal)))))

(define pid (uv-process-pid child))
(uv-kill! pid 0)                       ; signal 0: is it there? (raises if not)
(display "alive\n")
(uv-kill! pid 'sigkill)
(let wait () (unless exited (uv-run loop 'once) (wait)))
(display exited) (newline)
(display (= pid (uv-process-pid child))) (newline)  ; still readable after exit
(uv-close! child)
(display (guard (e ((uv-handle-closed? e) (uv-handle-closed-kind e)))
           (uv-process-pid child)))
(newline)
(display (integer? (uv-os-getpid))) (newline)
(uv-loop-teardown! loop)
```

It prints:

```
alive
(0 sigkill)
#t
process
#t
```

`uv-process-pid` works from the spawn until you call `uv-close!`, even after
the child has exited. Once the handle is closing, it raises
`&uv-handle-closed`.

> ⚠️ A pid stops being yours when the child exits. By the time `on-exit`
> runs, the system has reaped the child and may give its pid to a new
> process. A kill sent after that, or a check with signal `0`, usually raises
> `'ESRCH`, but it can reach that unrelated process instead. Signal a child
> only before its exit callback has run.

## When a spawn fails

`uv-spawn!` raises when it cannot start the child. Four kinds of failure
come out of it:

- **`&uv-invalid-argument`** means an argument was wrong: an empty `args`, an
  unknown option, a stdio entry of no known shape, a used pipe. It is
  raised before libuv runs, so nothing is made and the pipes are left
  unused. (One rare reason is the exception; see the last warning below.)
- **`&uv-handle-closed`** means the loop, or a pipe or stream named in
  `stdio`, is already closed or closing. Its `kind` says which. It too is
  raised before libuv runs.
- **`&uv-wrong-thread`** means you called it off the loop's thread
  ([Threads](#threads)).
- **`&uv-errno-error`** means libuv tried and failed, such as `'ENOENT` for a
  program that is not there, or `'ENOMEM` when memory ran out. The binding
  cleans up the process handle for you.

All four are `&uv-error`s, so `uv-error?` catches every one. (So does a bare
`&uv-error` the binding raises only if its own options block comes out
wrong, which is a bug in the binding, not your call.)

```scheme
(import (chezscheme) (libuv))

;; Every kind of failure uv-spawn! raises.
(define loop (make-uv-loop))

(define (spawn-failure thunk)
  (guard (e ((uv-invalid-argument? e) (list 'invalid (uv-invalid-argument-reason e)))
            ((uv-handle-closed? e) (list 'closed (uv-handle-closed-kind e)))
            ((uv-wrong-thread? e) (list 'wrong-thread (uv-wrong-thread-who e)))
            ((uv-errno-error? e) (list 'errno (uv-errno-error-errno e))))
    (thunk)
    'spawned))

;; A closed pipe.
(define closed-pipe (make-uv-pipe loop))
(uv-close! closed-pipe)
(display (spawn-failure
          (lambda ()
            (uv-spawn! loop "true" '("true")
                       (list (cons 'stdio (list 'ignore (list 'pipe closed-pipe 'from-child))))
                       #f))))
(newline)

;; A closed loop.
(define closed-loop (make-uv-loop))
(uv-loop-close! closed-loop)
(display (spawn-failure (lambda () (uv-spawn! closed-loop "true" '("true") #f))))
(newline)

;; Another thread.
(define answer #f)
(define m (make-mutex))
(define c (make-condition))
(fork-thread
 (lambda ()
   (let ((r (spawn-failure (lambda () (uv-spawn! loop "true" '("true") #f)))))
     (with-mutex m (set! answer r) (condition-signal c)))))
(with-mutex m (let wait () (unless answer (condition-wait c m) (wait))))
(display answer) (newline)

;; A program that is not there.
(display (spawn-failure (lambda () (uv-spawn! loop "no-such-program" '("no-such-program") #f))))
(newline)

(uv-loop-teardown! loop)
```

It prints:

```
(closed pipe)
(closed loop)
(wrong-thread uv-spawn!)
(errno ENOENT)
```

A failed spawn that named pipes needs one more look:

```scheme
(import (rnrs) (libuv))

;; A spawn that fails, and the pipe it leaves behind.
(define loop (make-uv-loop))
(define out (make-uv-pipe loop))

(define (try-spawn)
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
    (uv-spawn! loop "no-such-program" '("no-such-program")
               (list (cons 'stdio (list 'ignore (list 'pipe out 'from-child))))
               #f)
    'spawned))

(display (try-spawn)) (newline)     ; the program is not there
(display (try-spawn)) (newline)     ; the pipe is used up
(display (uv-handle-state out)) (newline)
(uv-close! out)
(uv-loop-teardown! loop)
```

It prints:

```
ENOENT
pipe-already-used
open
```

> ⚠️ A spawn that reached libuv uses up its pipes **even when it fails**.
> libuv opens the parent's end of each pipe before it can know whether the
> program will start. So after a failed spawn, each pipe you named is still
> open, cannot be used again, and needs its own `uv-close!`. A spawn refused
> with `&uv-invalid-argument` before it reached libuv leaves its pipes
> unused.

> ⚠️ One failure the binding cannot tidy up: if `uv-spawn!` raises
> `&uv-invalid-argument` with the reason
> `'spawn-failure-state-unclassifiable`, libuv failed after the child had
> started. The binding leaves that native handle alone, and no teardown
> closes it, so its memory is never reclaimed and the child may still be
> running.

Errors in general are on the [errors](errors.md) page.

## Detached children

With `(detached . #t)`, the child can outlive your process. The pattern is
to spawn and close at once:

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define d (uv-spawn! loop "sleep" '("sleep" "1") '((detached . #t)) #f))
(uv-close! d)
(uv-run loop 'default)
(display (uv-handle-state d)) (newline)
(uv-loop-teardown! loop)
```

It prints `closed`: the handle is gone, and the child was left to run.

> ⚠️ This process never reaps a detached child once you have closed its
> handle. You get no exit callback and no exit status for it.

## Running as another user

`uid` and `gid` set the user and group the child runs as. Your own uid and
gid need no privilege: a non-root process that passed its own uid spawned
its child normally. Any other id needs root. Without it the spawn is
refused with `&uv-errno-error`, and which errno you get depends on the
system: in a rootless container, uid 0 was refused with `'EINVAL`. Each must be a whole number from 0 to
4294967295; anything else is refused with `&uv-invalid-argument`.

The test suite that exercises them has to run as root, so it is kept out of
`make test`. [Building and testing](building.md#running-as-root) shows how
to run it.

## Living alongside Chez's own processes

Chez has its own ways to run programs, such as `system` and
`open-process-ports`. You can use them in the same program as `uv-spawn!`.
Mixing them was measured on Linux, where a stolen wait could silently drop
an exit callback, and every libuv exit callback arrived while every Chez
call returned its own correct result.

```scheme
(import (chezscheme) (libuv))

;; libuv's spawn and Chez's own subprocess calls, side by side.
(define loop (make-uv-loop))
(define exits '())

(define child
  (uv-spawn! loop "sh" '("sh" "-c" "exit 7")
             (lambda (status signal)
               (set! exits (cons status exits))
               (uv-close! child))))

(display (list 'system (system "exit 5"))) (newline)

(let-values (((to-stdin from-stdout from-stderr pid)
              (open-process-ports "echo from chez" (buffer-mode block)
                                  (native-transcoder))))
  (display (list 'chez-read (get-line from-stdout))) (newline)
  (close-port to-stdin) (close-port from-stdout) (close-port from-stderr))

(uv-run loop 'default)
(display (list 'libuv-exit exits)) (newline)
(uv-loop-teardown! loop)
```

It prints:

```
(system 5)
(chez-read from chez)
(libuv-exit (7))
```

## Threads

`uv-spawn!`, like every verb that makes something on a loop, must be called
on the loop's own thread. From any other thread it raises `&uv-wrong-thread`
before it reads its arguments. The same goes for `uv-process-kill!` and
`uv-process-pid`. `uv-kill!` and `uv-os-getpid` take no loop. See
[threads](threads.md).

## Read next

- [Signals](signals.md): catching signals, rather than sending them.
- [TCP and streams](tcp.md): the stream verbs a connected pipe takes.
- [Errors](errors.md): the conditions `uv-spawn!` raises.
- [API reference](reference.md#uv-spawn-procedure): every argument, exactly.
