# Chez Scheme HTTP/1 Server Architecture

> Status: Background design writeup for the downstream web-server project.

## Goal

Build a small, composable HTTP/1.x server stack for Chez Scheme with clear separation between:

1. a thin `libuv` binding,
2. a reusable byte-oriented state-machine generator,
3. an HTTP/1 parser defined using that state-machine layer,
4. an HTTP server/connection layer that composes the parser with `libuv`,
5. application-facing request/response APIs.

The intent is to keep transport, parsing, protocol semantics, and application behavior independently understandable and testable.

---

## High-Level Architecture

```text
              ┌─────────────────────┐
              │     Application     │
              │ routes / handlers   │
              └──────────▲──────────┘
                         │
                         │ request / response API
                         │
              ┌──────────┴──────────┐
              │  chez-http-server   │
              │                     │
              │ connection state    │
              │ HTTP semantics      │
              │ response encoding   │
              │ backpressure        │
              └───────┬───────┬─────┘
                      │       │
             parser   │       │ transport
                      │       │
          ┌───────────▼──┐  ┌─▼───────────┐
          │  chez-http1  │  │  chez-libuv │
          │              │  │             │
          │ HTTP grammar │  │ thin FFI    │
          │ parser API   │  │ TCP / loop  │
          └──────┬───────┘  └─────────────┘
                 │
                 ▼
        ┌───────────────────┐
        │ chez-byte-machine │
        │                   │
        │ parser/state DSL  │
        │ compiler          │
        │ verification      │
        └───────────────────┘
```

The dependency direction should remain one-way. In particular:

- the HTTP parser must not depend on `libuv`;
- the state-machine library must know nothing about HTTP;
- the `libuv` layer must know nothing about HTTP;
- HTTP connection semantics belong in the server layer, not in the parser.

---

## 1. `chez-libuv`: Thin Transport Layer

The `libuv` package should stay deliberately thin.

Its purpose is to expose the useful parts of `libuv` to Chez without becoming an application framework.

Likely areas:

```text
chez-libuv/
  raw.sls
  loop.sls
  tcp.sls
  timer.sls
  dns.sls
  process.sls
```

The raw layer can closely reflect the C API, while higher-level modules can provide safer Scheme wrappers around:

- event loops,
- TCP handles,
- accepting connections,
- asynchronous reads,
- asynchronous writes,
- timers,
- DNS,
- handle closing,
- callback registration,
- buffer lifetime.

### Design constraints

The wrapper should make ownership and lifetime explicit.

`libuv` commonly requires C objects and buffers to remain alive across asynchronous operations. The binding should therefore define clear rules around:

- Scheme objects referenced by C callbacks,
- foreign pointers,
- GC reachability,
- write buffers that must survive until a write callback,
- closing handles exactly once,
- callback registration and release.

Avoid hiding `libuv` behavior behind too much abstraction. The HTTP server should be able to reason directly about:

```text
accept
read
stop reading
start reading
write
timer
close
```

This is especially important for implementing backpressure correctly.

---

## 2. `chez-byte-machine`: State-Machine Generator

Rather than hand-writing the HTTP parser directly, define a small byte-oriented deterministic state-machine system inspired by `llparse` / `llhttp`.

The initial scope should be intentionally narrow: generate efficient incremental parsers over bytevectors.

Conceptually:

```scheme
(define-machine http-parser
  (state request-start
    ...)
  (state method
    ...)
  (state request-target
    ...)
  ...)
```

Possible primitives include:

- named states,
- transitions on exact bytes,
- transitions on byte classes,
- fallback/error transitions,
- terminal states,
- callbacks/actions,
- spans over ranges of input,
- integer accumulation,
- parser-local mutable fields.

A simple conceptual example:

```scheme
(state method
  (#\G -> method-g)
  (#\P -> method-p)
  (else -> invalid-method))
```

The state-machine definition should compile to ordinary Chez Scheme procedures operating directly on bytevectors.

### Important properties

The parser engine should be:

- incremental,
- allocation-conscious,
- deterministic,
- byte-oriented,
- resumable across arbitrary input boundaries,
- independent of the transport,
- suitable for parsing several messages from one input buffer.

The hot path should work on:

```scheme
(bytevector, start, end)
```

rather than Scheme strings.

### Static verification

One of the more valuable ideas from `llparse` is that the parser graph itself can be inspected before execution.

The state-machine generator should eventually verify useful invariants such as:

- every referenced state exists,
- unreachable states can be reported,
- transitions are deterministic,
- invalid epsilon cycles are rejected,
- terminal and error states are well-formed,
- spans are opened and closed consistently,
- callback transitions are legal,
- all expected byte classes are handled where required.

This is not intended to constitute formal verification of HTTP correctness. It is structural verification of the generated parser graph.

The abstraction should initially be designed around the needs of HTTP rather than trying to become a completely general parser generator.

---

## 3. `chez-http1`: HTTP/1 Parser

The HTTP parser should be expressed using the byte-machine layer.

Possible layout:

```text
chez-http1/
  parser.sls
  grammar.sls
  errors.sls
```

The parser API should remain independent of sockets:

```scheme
(make-http-parser callbacks)
(http-parser-feed! parser bytevector start end)
(http-parser-reset! parser)
(http-parser-error parser)
```

The parser should retain its state between calls because TCP input boundaries have no relationship to HTTP message boundaries.

For example, one read may contain:

```text
GET /foo HTTP/1.1\r\nHost: exam
```

and the next:

```text
ple.com\r\n\r\n
```

Conversely, one read may contain several pipelined requests.

### Parser output

Prefer events or spans over eagerly constructing complete Scheme objects.

Examples:

```text
message-begin
method
request-target
header-name
header-value
headers-complete
body
message-complete
```

Callbacks should ideally receive bytevector ranges:

```scheme
(on-header-name bv start end)
(on-header-value bv start end)
(on-body bv start end)
```

rather than allocating Scheme strings in the parser.

The server layer can decide what must be copied, normalized, decoded, or retained.

---

## 4. Use `llhttp` as a Behavioral Reference

The HTTP parser should aim for behavioral compatibility with `llhttp` where practical.

The most valuable upstream asset is not necessarily the generated C implementation; it is the accumulated parser behavior and test corpus.

The project should reuse or adapt the `llhttp` test harness so that the Chez implementation is exercised against the same cases.

Testing should cover:

- valid requests,
- invalid requests,
- malformed headers,
- request targets,
- HTTP versions,
- `Content-Length`,
- chunked transfer encoding,
- connection semantics,
- upgrades where supported,
- arbitrary input fragmentation,
- multiple messages in one buffer,
- parser callback ordering,
- exact consumed-byte positions,
- error positions and error categories.

### Differential testing

During development, treat upstream `llhttp` as an executable oracle.

Given the same byte stream:

```text
                 ┌── llhttp ───────→ result A
input bytes ─────┤
                 └── Chez parser ──→ result B

                       compare
```

Compare more than simple success/failure.

Useful comparison dimensions include:

- accepted vs rejected,
- number of bytes consumed,
- error position,
- error class,
- callback/event sequence,
- parsed method,
- parsed version,
- body boundaries,
- message boundaries.

Property-based or fuzz testing can generate fragmented and mutated HTTP input and run it through both implementations.

This is especially valuable for HTTP because security problems frequently occur when two parsers disagree about message boundaries or malformed syntax.

---

## 5. `chez-http-server`: HTTP Connection Layer

The server package composes the HTTP parser and `libuv`.

Possible layout:

```text
chez-http-server/
  server.sls
  connection.sls
  request.sls
  response.sls
  limits.sls
```

The central internal abstraction should be the HTTP connection, not the parser itself.

Conceptually:

```scheme
(define-record-type http-connection
  (fields
    socket
    parser
    current-request
    request-queue
    write-queue
    timer
    (mutable state)))
```

Each connection owns:

- a `uv_tcp_t`,
- parser state,
- current HTTP request state,
- response/write queue,
- connection lifecycle state,
- timeout state,
- buffering state.

### Input path

```text
uv_accept
   ↓
create HTTP connection
   ↓
uv_read_start
   ↓
bytes arrive
   ↓
http-parser-feed!
   ↓
parser events
   ↓
HTTP connection semantics
   ↓
application handler
```

`libuv` is the front line. It owns the event loop and drives the parser from read callbacks.

The parser itself should be synchronous: given some bytes, consume as much as possible and update its state.

---

## 6. HTTP Semantics Belong Above the Parser

The parser should recognize HTTP syntax but should not own broader connection or application behavior.

The server/connection layer should handle concerns such as:

- request construction,
- keep-alive,
- persistent connection policy,
- pipelining policy,
- request body streaming,
- maximum request sizes,
- maximum header sizes,
- timeout policy,
- routing/dispatch,
- response serialization,
- connection shutdown.

Some HTTP semantics may necessarily influence parser behavior, but the parser should remain as close as possible to:

```text
bytes → syntax/events
```

while the connection layer handles:

```text
events → HTTP request lifecycle
```

---

## 7. Backpressure

Backpressure must cross the HTTP/parser boundary cleanly.

For example, a large request body should not automatically accumulate in Scheme memory:

```text
libuv
  ↓
HTTP parser
  ↓
body callback
  ↓
streaming consumer
```

If the downstream consumer cannot accept more data:

```text
consumer saturated
      ↓
uv_read_stop()
```

Reading can resume later with:

```text
uv_read_start()
```

The parser provides useful protocol boundaries, but actual control over incoming network data belongs to the transport layer.

The server layer coordinates the two.

---

## 8. Response Path

Responses do not require a parser.

The outbound path is:

```text
application
   ↓
response object
   ↓
HTTP response serializer
   ↓
libuv
   ↓
socket
```

Avoid requiring one large contiguous response string.

The response serializer should be able to produce a sequence of buffers suitable for vectored writes:

```text
HTTP/1.1 200 OK\r\n
Content-Type: text/plain\r\n
Content-Length: 5\r\n
\r\n
hello
```

For large or streaming bodies, headers and body chunks should flow independently.

The write queue must retain references to buffers until `libuv` reports that the write operation has completed.

---

## 9. Buffer Ownership and Zero-Copy Concerns

Parser callbacks may refer directly to regions of a libuv read buffer.

Therefore the design must make buffer lifetime explicit.

A parser event such as:

```scheme
(on-header-value bv start end)
```

is only safe while `bv` remains alive and unmodified.

The server must decide when to:

- process a span immediately,
- copy it,
- retain the entire input buffer,
- normalize it,
- decode it.

Avoid prematurely designing everything around zero-copy behavior. Correct ownership semantics are more important.

However, keeping the parser API span-oriented preserves the ability to optimize later.

---

## 10. Pipelining

HTTP/1.1 permits pipelined requests.

The parser must therefore be capable of consuming:

```text
request 1
request 2
request 3
```

from one byte stream without requiring libuv reads to align with request boundaries.

The server layer should explicitly decide its pipelining behavior.

Possible initial policy:

- parse pipelined requests correctly,
- preserve response ordering,
- limit the number of outstanding requests,
- optionally avoid concurrent execution initially.

A conservative implementation can queue complete requests while ensuring responses are written in request order.

---

## 11. Limits and Defensive Parsing

The server should impose configurable resource limits independent of whether the grammar technically accepts an input.

Examples:

- maximum request-target size,
- maximum header field size,
- maximum total header bytes,
- maximum number of headers,
- maximum body size when buffering,
- maximum pipelined requests,
- maximum queued response bytes,
- idle timeout,
- header timeout,
- body timeout.

These are server policy rather than state-machine grammar.

HTTP request-smuggling behavior deserves particular attention. Differential testing against `llhttp` should include ambiguous combinations involving:

- `Content-Length`,
- `Transfer-Encoding`,
- duplicate framing headers,
- unusual whitespace,
- malformed chunking,
- invalid line endings.

---

## 12. Error Model

Keep transport, parser, protocol, and application errors distinct.

For example:

```text
transport:
  ECONNRESET
  write failure

parser:
  malformed method
  invalid header syntax
  invalid chunk encoding

HTTP/server policy:
  headers too large
  body too large
  timeout

application:
  handler exception
  invalid response
```

The server layer can map parser and policy errors to HTTP responses where appropriate, then close the connection according to HTTP rules.

---

## 13. Application API

The public server API should eventually be considerably simpler than the internal machinery.

A rough target:

```scheme
(define server
  (make-http-server
    #:host "0.0.0.0"
    #:port 8080
    #:handler
    (lambda (request respond)
      (respond
        200
        '((content-type . "text/plain"))
        #"hello\n"))))

(http-server-run! server)
```

The first implementation does not need routing or a large web framework.

A good initial abstraction boundary is:

```text
request → handler → response
```

with explicit support for streaming added at the connection/response layer.

---

## 14. Testing Strategy by Layer

Each library has a different ideal testing strategy.

### `chez-libuv`

Integration tests:

- loop creation/destruction,
- TCP listen/connect,
- reads,
- writes,
- timers,
- close semantics,
- callback lifetime,
- buffer lifetime,
- error propagation.

### `chez-byte-machine`

Unit and property tests:

- transition compilation,
- reachability analysis,
- deterministic transitions,
- spans,
- partial input,
- resume behavior,
- terminal states,
- invalid graph rejection.

### `chez-http1`

Use the `llhttp` test corpus plus differential testing.

Test every possible input split for representative messages where feasible:

```text
GET / HTTP/1.1\r\nHost: x\r\n\r\n
^
 ^
  ^
   ...
```

The result must not depend on TCP/read fragmentation.

### `chez-http-server`

End-to-end socket tests:

- request/response,
- keep-alive,
- multiple requests,
- pipelining,
- chunked bodies,
- streaming,
- backpressure,
- slow clients,
- timeout behavior,
- disconnect during read,
- disconnect during write,
- graceful shutdown.

---

## 15. Suggested Initial Build Order

A practical sequence:

```text
1. minimal libuv FFI
        ↓
2. TCP echo server
        ↓
3. byte-machine prototype
        ↓
4. trivial HTTP request-line grammar
        ↓
5. incremental parsing tests
        ↓
6. llhttp corpus integration
        ↓
7. complete HTTP/1 request parser
        ↓
8. HTTP connection object
        ↓
9. response serializer
        ↓
10. keep-alive / limits / timeouts
        ↓
11. body streaming / backpressure
        ↓
12. pipelining and robustness work
```

The echo server is an important early checkpoint because it validates Chez ↔ C callback handling, buffer ownership, and `libuv` lifecycle before HTTP complexity is introduced.

Likewise, the state-machine library should begin with only enough machinery to express HTTP parsing cleanly. Generalize it later based on actual needs.

---

## Core Design Principles

1. **libuv owns I/O and scheduling.**
2. **The parser consumes bytes synchronously and incrementally.**
3. **The parser does not know about sockets.**
4. **The libuv layer does not know about HTTP.**
5. **HTTP connection semantics live above the parser.**
6. **Operate on bytevectors in the parser hot path.**
7. **Prefer spans/events over eager allocation.**
8. **Make memory and callback ownership explicit.**
9. **Use the llhttp corpus as a compatibility target.**
10. **Differential-test the Chez parser against llhttp.**
11. **Perform structural checks on generated state machines.**
12. **Keep the state-machine abstraction narrow until HTTP demonstrates what should be generalized.**
13. **Treat request boundaries as parser state, never as socket-read boundaries.**
14. **Make backpressure a first-class concern.**
15. **Keep server resource limits separate from grammar correctness.**

---

## Initial Package Shape

```text
chez-libuv/
  raw.sls
  loop.sls
  tcp.sls
  timer.sls

chez-byte-machine/
  machine.sls
  compile.sls
  verify.sls

chez-http1/
  grammar.sls
  parser.sls
  errors.sls

chez-http-server/
  server.sls
  connection.sls
  request.sls
  response.sls
  limits.sls
```

These can initially live in one repository while retaining clean library boundaries. Splitting them into separate distributions can be deferred until the APIs stabilize.
