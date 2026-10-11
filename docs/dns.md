# DNS

DNS turns a host name into addresses, and an address back into a name.
chez-libuv asks the host's own resolver, without blocking the loop, and
hands the answer to your callback.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))

(uv-getaddrinfo! loop "localhost" "8080"
                 '((family . inet) (socktype . stream))
  (lambda (err results)
    (if err
        (begin (display (uv-errno-error-errno err)) (newline))
        (for-each
         (lambda (ai)
           (display (list (uv-addrinfo-family ai)
                          (uv-addrinfo-socktype ai)
                          (uv-addrinfo-protocol ai)
                          (uv-addrinfo-address ai)
                          (uv-addrinfo-port ai)
                          (uv-addrinfo-canonname ai)))
           (newline))
         results))))

(uv-run loop 'default)
(uv-loop-teardown! loop)
```

On a host whose `localhost` is `127.0.0.1`, it prints:

```
(inet stream tcp 127.0.0.1 8080 #f)
```

That is the whole scope: whatever the host's resolver does, done
asynchronously. There is no DNS client of its own, no record types and
no caching.

## Looking up a name

```scheme
(uv-getaddrinfo! loop node service on-complete)
(uv-getaddrinfo! loop node service hints on-complete)
```

| Argument      | What to pass                                                    |
|:--------------|:----------------------------------------------------------------|
| `loop`        | an open loop                                                    |
| `node`        | a host name or address string, or `#f`                          |
| `service`     | a port number or service name, as a string, or `#f`             |
| `hints`       | optional; an alist narrowing the answer ([Hints](#hints))       |
| `on-complete` | a procedure of two arguments, `err` and `results`               |

`node` and `service` cannot both be `#f`.

[`uv-getaddrinfo!`](reference.md#uv-getaddrinfo-procedure) returns at
once, with a request record. Later, inside `uv-run`, `on-complete` is
called:

- **On success**, `err` is `#f` and `results` is a fresh list of
  `uv-addrinfo` records, in the order the resolver gave them.
- **On failure**, `err` is a condition and `results` is `'()`.

A success can still answer `'()`. Only IPv4 and IPv6 entries become
records; any other family is skipped.

### Resolve then connect

`uv-tcp-connect!` takes an address, not a name. So a client resolves
first and connects in the callback:

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))

;; Something to connect to.
(define server (make-uv-tcp loop))
(uv-tcp-bind! server "127.0.0.1" 0)
(uv-listen! server 16
  (lambda (err)
    (unless err
      (uv-close! (uv-accept! server))
      (uv-close! server))))
(define service (number->string (uv-tcp-getsockname-port server)))

;; Resolve "localhost", then connect to the first address it gave.
(uv-getaddrinfo! loop "localhost" service '((family . inet) (socktype . stream))
  (lambda (err results)
    (if (or err (null? results))
        (begin (display "lookup failed\n") (uv-close! server))
        (let ((ai (car results))
              (client (make-uv-tcp loop)))
          (uv-tcp-connect! client (uv-addrinfo-address ai) (uv-addrinfo-port ai)
            (lambda (err)
              (display (list 'connected-to (uv-addrinfo-address ai) (not err)))
              (newline)
              (uv-close! client)))))))

(uv-run loop 'default)
(uv-loop-teardown! loop)
```

It prints:

```
(connected-to 127.0.0.1 #t)
```

The `(family . inet)` hint matters here. The server listens on IPv4
only, and on some hosts `localhost` answers `::1` first.

## The addrinfo records

Each result is a `uv-addrinfo` record. It is plain data, copied out of
the resolver's answer, so you can keep it as long as you like.

| Accessor                                                                    | Answers                                                         |
|:----------------------------------------------------------------------------|:----------------------------------------------------------------|
| [`uv-addrinfo-family`](reference.md#uv-addrinfo-family-accessor)            | `inet` or `inet6`                                               |
| [`uv-addrinfo-socktype`](reference.md#uv-addrinfo-socktype-accessor)        | `stream`, `dgram` or `raw`, or the raw integer for another type |
| [`uv-addrinfo-protocol`](reference.md#uv-addrinfo-protocol-accessor)        | `tcp` or `udp`, or the raw integer (0 means unspecified)        |
| [`uv-addrinfo-address`](reference.md#uv-addrinfo-address-accessor)          | the address as a string, such as `"127.0.0.1"`, or `#f`         |
| [`uv-addrinfo-port`](reference.md#uv-addrinfo-port-accessor)                | the port, an exact integer from 0 to 65535                      |
| [`uv-addrinfo-canonname`](reference.md#uv-addrinfo-canonname-accessor)      | `#f`, except on the first entry when you asked for `canonname`  |

`uv-addrinfo?` is the type predicate.

**IPv6 scope IDs are dropped.** A link-local result reads `"fe80::1"`,
with its zone silently missing, even when the name you looked up named
one. No verb here gets the zone back for you: keep it from your own
input if you need it.

The constructor,
[`make-uv-addrinfo`](reference.md#make-uv-addrinfo-record-constructor),
is public. Its arguments are the six fields in the order above. It is
there so a test can hand your code a result without a real lookup:

```scheme
(define fake (make-uv-addrinfo 'inet 'stream 'tcp "10.0.0.1" 443 #f))
(display (list (uv-addrinfo? fake) (uv-addrinfo-address fake) (uv-addrinfo-port fake)))
(newline)
```

It prints:

```
(#t 10.0.0.1 443)
```

## Hints

Hints narrow the answer. They are an alist, and every key and value
comes from a fixed set:

| Key        | Values                                                     |
|:-----------|:-----------------------------------------------------------|
| `family`   | `unspec`, `inet`, `inet6`                                  |
| `socktype` | `stream`, `dgram`                                          |
| `protocol` | `tcp`, `udp`                                               |
| `flags`    | a list of `passive`, `canonname`, `numeric-host`, `numeric-serv` |

For example, `'((family . inet6) (socktype . stream) (flags . (canonname)))`.

**No hints answers one entry per address and socket type.** Leaving hints
out, or passing `#f` or `'()`, gives the resolver no hints at all. Its
default is typically one entry for each address times each socket type:
`stream`, `dgram`, and on Linux `raw` too. `'((socktype . stream))` is the
short way to get one entry per address.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define (show label)
  (lambda (err results)
    (display label) (display ": ")
    (display (map (lambda (ai) (list (uv-addrinfo-address ai) (uv-addrinfo-socktype ai)))
                  results))
    (newline)))

;; No hints: one entry per address and socket type.
(uv-getaddrinfo! loop "127.0.0.1" #f (show "no hints"))
;; One socket type: one entry per address.
(uv-getaddrinfo! loop "127.0.0.1" #f '((socktype . stream)) (show "stream only"))
(uv-run loop 'default)
(uv-loop-teardown! loop)
```

On Linux it printed:

```
stream only: ((127.0.0.1 stream))
no hints: ((127.0.0.1 stream) (127.0.0.1 dgram) (127.0.0.1 raw))
```

The two lookups run at the same time, so their answers can arrive in
either order. Other runs printed `no hints` first.

The `canonname` flag puts the host's canonical name on the first result:

```scheme
(uv-getaddrinfo! loop "localhost" "8080" '((socktype . stream) (flags . (canonname)))
  (lambda (err results)
    (display (map (lambda (ai) (list (uv-addrinfo-address ai)
                                     (uv-addrinfo-port ai)
                                     (uv-addrinfo-canonname ai)))
                  results))
    (newline)))
```

It printed:

```
((127.0.0.1 8080 localhost))
```

## Errors

A failed lookup reaches `on-complete` as an ordinary `&uv-errno-error`.
Its errno is a resolver symbol such as `EAI_NONAME`, `EAI_AGAIN` or
`EAI_CANCELED`. There are no condition types of DNS's own.

Arguments that are wrong to begin with are refused at the call instead,
with `&uv-invalid-argument` and a reason.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))

;; numeric-host forbids a name lookup, so a name is refused by the resolver.
(uv-getaddrinfo! loop "localhost" #f '((flags . (numeric-host)))
  (lambda (err results)
    (display (list (uv-errno-error? err) (uv-errno-error-errno err) results))
    (newline)))
(uv-run loop 'default)

(define (reason thunk)
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e)))
    (thunk)
    'no-raise))
(define (ignore . args) #f)
(display (reason (lambda () (uv-getaddrinfo! loop #f #f ignore)))) (newline)
(display (reason (lambda () (uv-getaddrinfo! loop "localhost" #f '((family . ipx)) ignore)))) (newline)
(display (reason (lambda () (uv-getaddrinfo! loop "localhost" #f '((colour . red)) ignore)))) (newline)
(display (reason (lambda () (uv-cancel! 'not-a-request)))) (newline)
(uv-loop-teardown! loop)
```

It prints:

```
(#t EAI_NONAME ())
node-and-service-both-absent
unknown-hint-family
unknown-hint-key
not-a-cancellable-request
```

Others you may meet: `duplicate-hint-key`, `unknown-hint-socktype`,
`unknown-hint-protocol`, `unknown-hint-flag`, `hints-not-an-alist`, and
`node-contains-nul` or `service-contains-nul` (C would read a string only
up to its first NUL). [errors.md](errors.md) covers the condition types.

## Reverse lookup

```scheme
(uv-getnameinfo! loop ip port on-complete)
(uv-getnameinfo! loop ip port flags on-complete)
```

[`uv-getnameinfo!`](reference.md#uv-getnameinfo-procedure) asks for the
name of an address and port. `on-complete` gets three arguments:
`err host service`. On success both are strings; on failure, including a
cancel, both are `#f`.

`flags` is a list of `numeric-host`, `numeric-serv`, `name-required` and
`dgram`.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))

(uv-getnameinfo! loop "127.0.0.1" 80 '(numeric-host numeric-serv)
  (lambda (err host service)
    (display (list err host service)) (newline)))

(uv-getnameinfo! loop "127.0.0.1" 22 '(numeric-serv)
  (lambda (err host service)
    (display (list err host service)) (newline)))

(uv-run loop 'default)
(uv-loop-teardown! loop)
```

On a host whose `127.0.0.1` is `localhost`, it printed:

```
(#f 127.0.0.1 80)
(#f localhost 22)
```

`ip` is an address literal, read once at the start of the call, exactly
as `uv-tcp-bind!` reads it
([tcp.md](tcp.md#addresses-are-read-once)). The host it answers is the
system resolver's own rendering. When the `ip` you pass names a
link-local zone, as in `"fe80::1%lo"`, macOS and glibc keep that zone in
the host they answer.

## Cancelling a lookup

```scheme
(uv-cancel! request)
```

[`uv-cancel!`](reference.md#uv-cancel-procedure) takes the request that
`uv-getaddrinfo!` or `uv-getnameinfo!` returned.
[`uv-dns-request?`](reference.md#uv-dns-request-predicate) tells you
whether something is one.

A cancel is best effort:

- **`#t`** means the lookup was still waiting its turn, and the cancel
  won. The callback **still runs**, with errno `EAI_CANCELED` (and `'()`
  results, or `#f` host and service).
- **`#f`** means it was too late: the lookup was already running or done.
  The real result is, or was, delivered as usual.

Either way the callback runs at most once. There is one case where it
does not run at all: if turning a successful answer into records raises,
the request is freed without calling your callback, and the loop stores
that error and stops, as it does when a callback raises
([callbacks.md](callbacks.md)).

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define (ignore err results) #f)

;; Queue more lookups than the thread pool has workers,
;; so the last one is likely still waiting its turn.
(let fill ((n 0))
  (when (< n 63)
    (uv-getaddrinfo! loop "localhost" #f ignore)
    (fill (+ n 1))))

(define last-one
  (uv-getaddrinfo! loop "localhost" #f
    (lambda (err results)
      (display (list 'callback (and err (uv-errno-error-errno err)) results))
      (newline))))

(display (list 'dns-request? (uv-dns-request? last-one))) (newline)
(display (list 'cancelled (uv-cancel! last-one))) (newline)
(uv-run loop 'default)
(display (list 'cancel-after-completion (uv-cancel! last-one))) (newline)
(uv-loop-teardown! loop)
```

It printed:

```
(dns-request? #t)
(cancelled #t)
(callback EAI_CANCELED ())
(cancel-after-completion #f)
```

## Where the work runs

DNS is the one feature here that uses libuv's thread pool. The resolver
calls run on libuv's worker threads, in plain C: no Scheme code ever runs
off the loop's thread. The answers come back to the loop's thread like
every other callback.

- The pool's size is set by the `UV_THREADPOOL_SIZE` environment
  variable. libuv reads it once, the first time the pool is used.
- Call `uv-getaddrinfo!`, `uv-getnameinfo!` and `uv-cancel!` on the
  loop's own thread. From any other thread they raise `&uv-wrong-thread`
  ([threads.md](threads.md)).

## Teardown cancels then waits

[`uv-loop-teardown!`](reference.md#uv-loop-teardown-procedure) tries to
cancel the loop's lookups still in flight, then waits for every one of
their callbacks before it returns. Each gets `EAI_CANCELED` if the cancel
won, or its real result if the work was already running.

```scheme
(import (rnrs) (libuv))

(define loop (make-uv-loop))
(define answer 'not-yet)

(uv-getaddrinfo! loop "localhost" #f
  (lambda (err results)
    (set! answer (if err (uv-errno-error-errno err) 'resolved))))

;; Tear down without ever running the loop.
(uv-loop-teardown! loop)
(display (list 'callback-ran (not (eq? answer 'not-yet)))) (newline)
```

It prints:

```
(callback-ran #t)
```

> ⚠️ A lookup already running in a worker cannot be interrupted. The
> teardown waits it out, for as long as the operating system's resolver
> takes, up to its own timeout. A slow or unreachable DNS server can hold
> up your teardown for that long.

## Arguments are read once

`uv-getaddrinfo!` copies `node`, `service` and `hints` at the start of the
call, checking each as it copies, and builds the request from the copies.
Nothing you change afterwards reaches libuv.

The copies are not one snapshot, though. If an engine's timer handler, or
another thread, changes both `node` and `service` during the call, the
request can see the change in one and not the other. Another thread can
even be caught halfway through one string. If that matters to you, do
not change the arguments while the call runs.

`uv-getnameinfo!` reads its flag list once, as `uv-write*!` reads its
segment list ([tcp.md](tcp.md#writing-several-pieces-at-once)). A list
changed once during the read is used as it was, or as the change left
it, or refused. A list changed more than once can be read as a mix of
its versions.

## Engines

An engine can pause any of the four verbs part way, as it can a stream
verb ([tcp.md](tcp.md#engines-and-stream-verbs)). A lookup resumed after
its loop was torn down raises `&uv-handle-closed`, and one resumed after
its loop moved to another thread raises `&uv-wrong-thread`. A cancel
resumed after its request completed answers `#f`. A lookup whose engine
is never resumed leaves nothing behind: either it had not begun, or
libuv holds its request, and the loop's teardown sees it complete.

## Read next

- [tcp.md](tcp.md): connecting to the address you resolved.
- [loops.md](loops.md): running and tearing down the loop.
- [errors.md](errors.md): `&uv-errno-error` and its errno symbols.
