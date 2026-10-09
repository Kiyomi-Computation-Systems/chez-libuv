# #87: a close or a completion takes the registry lock once: mutation log

Branch `perf/registry-lock-once-87`, built on main 27520e3, 2026-10-09.
macOS arm64 (Darwin 25.6), Chez 10.4.1, vendored libuv 1.52.1.

## What was slow

Every request completion (write, connect, shutdown, getaddrinfo,
getnameinfo) and every handle close took `registry-lock` twice. The seam
looked the callback's pointer up under it. Then `complete-request!` or
`close-dispatch` called `registry-deregister!`, which took it again to
delete the entry the seam had just found. Every loop's thread shares the
lock (#70).

## The change

- `registry-take-accepted! ptr accepts?` finds PTR's entry and deletes it
  in one body under the lock. Then, after the release, it asks ACCEPTS? of
  the entry's object, and puts a refused entry back in a second use.
- `seam-lambda` takes its lookup as an argument, and `seams` pairs each
  callback with one:
  - `take-handle-entry!` (by `uv-handle?`) for close;
  - `take-request-entry!` (by `uv-req?`) for write-done, shutdown and
    connect;
  - `take-getaddrinfo-entry!` and `take-getnameinfo-entry!` for the DNS
    completions, by `getaddrinfo-req?` and `getnameinfo-req?`, which the
    DNS dispatchers now test with as well;
  - `registry-find` for the rest, which leave their pointer registered.
- `complete-request!`, `close-dispatch` and `abandon-request!` delete
  nothing.

Why the put-back, rather than checking the kind under the lock: rule 6 of
`tests/test-source-rules.sps` keeps every lock body to table operations
and `cons`, and a record accessor is neither. The issue allowed either
shape. Only the refusals pay the second use, and a refusal is a bug state:
a completion for a pointer registered as something else.

## Rows

New or changed:

- test-loop, "the close seam leaves a request's entry in place, and records
  an orphan": the close seam on a registered non-handle.
- test-loop, "the handle-less completion counted and zeroed the block, and
  left the registry to the seam": this was "…deregistered, counted, and
  zeroed the block". Called directly, `complete-request!` no longer touches
  the registry. It failed by name on main's source before the change.
- test-loop, "abandon-request! zeroes the request, delivers nothing, and
  leaves the registry to the seam".
- test-tcp, "the request seams left the handle's registry entry in place",
  and "the dispatch loop tears down with its handle". The second replaces
  a bare `(uv-loop-teardown! dl)`, which aborted the suite under M1 and M5.
- test-dns, "a getnameinfo request at the getaddrinfo seam: raised by name,
  entry kept, nothing completed", and the getnameinfo mirror.

Cleanup made safe, so a failing build runs the rest of the suite: test-loop's
`(registry-deregister! (car fake-req))` and test-timer's
`(registry-deregister! seam-block)` now run only when the entry is there.
Under M1 both raised and ended their suites before.

## Mutants

Each was applied to a copy of the tree outside the repository, then run
against test-loop, test-tcp, test-dns, test-timer, test-callback-alloc and
test-loop-threads. M0 is the unmutated copy, and it passed all six.

| Mutant | What it breaks | Caught by (first rows, by name) |
|---|---|---|
| M1 | no put-back: a refused entry stays deleted | test-loop "the close seam leaves a request's entry in place…"; test-tcp "the request seams left the handle's registry entry in place", "the dispatch loop tears down with its handle"; test-dns "kind-mismatch arm: the wrong-kind registry entry is untouched", "getnameinfo kind-mismatch arm: the wrong-kind registry entry is untouched", both other-kind rows |
| M2 | the getaddrinfo seam accepts any `uv-req?` | test-dns "a getnameinfo request at the getaddrinfo seam…" |
| M3 | the getnameinfo seam accepts any `uv-req?` | test-dns "a getaddrinfo request at the getnameinfo seam…" |
| M4 | the close seam accepts anything | test-loop "the close seam leaves a request's entry in place…" |
| M5 | the request seams accept anything | test-tcp "the request seams left the handle's registry entry in place", "the dispatch loop tears down with its handle" |
| M6 | `complete-request!` deletes again | test-loop "…left the registry to the seam", "the raise was recorded on the loop the registry entry named"; test-callback-alloc's completion rows |
| M7 | `close-dispatch` deletes again | test-timer "the close dispatcher zeroed the stored handle pointer" and five more; test-loop-threads' races; test-callback-alloc's close row |
| M8 | the write-done seam only looks | test-tcp "the write request was already deregistered when on-complete ran"; test-callback-alloc "delivering a write's completion…", "the registry is back to its starting size" |
| M9 | the close seam only looks | test-timer "the close dispatcher deregistered the handle"; test-tcp "the construction loop tore down cleanly"; test-loop-threads "the registry is back to its starting size" |
| M10 | `abandon-request!` deletes again | test-loop "abandon-request! zeroes the request…" (added for it: on the first pass M10 survived) |
| M11 | the getaddrinfo seam only looks | test-dns "v4: the lookup starts"; test-callback-alloc "delivering a getaddrinfo's completion…" |

M10 survived the first pass because `abandon-request!`'s one caller, the
getaddrinfo dispatcher's conversion-failure arm, cannot be reached by any
input (`.plans/dns-stage-4-mutation-log.md`). The new row drives
`abandon-request!` directly, as the `complete-request!` row does.

What no row holds: that a take uses the lock once rather than twice. M8
and M9 are the old shape with the deletes removed, and they fail. But the
old shape itself, a seam that looks and a dispatcher that deletes, is
correct. It is only slower, and the timing below is its evidence.

## Allocation

`tests/test-callback-alloc.sps` printed the same 24 figures on main's source
and on the branch, byte for byte.

## Timing

`bench.sps` (below) runs on each thread's own loop. Each repetition:

- makes 2,000 timers ("make": one registry add each);
- fires them at timeout 0 ("fire": one seam lookup each);
- closes them ("close": a seam take, formerly a lookup and a delete);
- completes 2,000 synthetic requests through the shutdown seam
  ("complete": an `alloc-zeroed` block, a registration, and a seam take).

Each figure is the median, over 5 alternated rounds, of the threads'
median of each thread's best of 30 repetitions, in ns an operation. Both
builds used the release shim (`make prod`) with
`collect-trip-bytes` 2^29, at load 5–7.

| Threads | Build | make | fire | close | complete |
|---|---|---|---|---|---|
| 1 | main | 160 (154–164) | 385 (380–398) | 395 (392–406) | 219 (215–226) |
| 1 | #87 | 156 (154–164) | 389 (381–404) | 360 (356–380) | 184 (174–188) |
| 4 | main | 276 (215–484) | 1,500 (904–1,817) | 2,340 (1,188–3,204) | 538 (276–740) |
| 4 | #87 | 363 (338–470) | 2,062 (1,068–2,514) | 2,136 (1,829–2,542) | 490 (238–526) |

At one thread a close is 35 ns cheaper and a completion 35 ns cheaper,
with no overlap between the builds' ranges. #77 measured about 35 ns for a
lock use, so this is one use. make and fire, which this change does not
touch, agree within their ranges. At four threads every column's ranges
overlap between the builds, including make and fire, so these runs settle
nothing there. #77 saw the same spread and put it down to something else
shared.

```scheme
;; bench.sps THREADS REPS
(import (chezscheme)
        (libuv loop) (libuv handle) (libuv timer)
        (libuv private handles)
        (only (libuv private native) alloc-zeroed dispatcher-ref))

(define n 2000)
(define threads (string->number (cadr (command-line))))
(define reps (string->number (caddr (command-line))))

(define (now-ns)
  (let ((t (current-time 'time-monotonic)))
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (run-until loop done?)
  (let spin ((i 0))
    (unless (done?)
      (when (> i 10000000) (error 'bench "loop never finished"))
      (uv-run loop 'once)
      (spin (+ i 1)))))

(define (one-rep loop)
  (let* ((fired 0) (closed 0)
         (t0 (now-ns))
         (timers (let make ((i 0) (acc '()))
                   (if (= i n) acc (make (+ i 1) (cons (make-uv-timer loop) acc)))))
         (t1 (now-ns)))
    (for-each (lambda (t) (uv-timer-start! t (lambda (h) (set! fired (+ fired 1))) 0 0)) timers)
    (let ((t2 (now-ns)))
      (run-until loop (lambda () (= fired n)))
      (let ((t3 (now-ns)))
        (for-each (lambda (t) (uv-close! t (lambda () (set! closed (+ closed 1))))) timers)
        (run-until loop (lambda () (= closed n)))
        (let ((t4 (now-ns)) (slot (dispatcher-ref 'shutdown)) (done 0))
          (let complete ((i 0))
            (when (< i n)
              (let ((block (alloc-zeroed 64)))
                (registry-register! block 'shutdown-req loop
                                    (%make-uv-req-record block 'shutdown #f
                                                         (lambda (err) (set! done (+ done 1)))))
                (slot block 0))
              (complete (+ i 1))))
          (let ((t5 (now-ns)))
            (unless (= done n) (error 'bench "completions missing" done))
            (vector (/ (- t1 t0) n) (/ (- t3 t2) n) (/ (- t4 t3) n) (/ (- t5 t4) n))))))))

(define (thread-best)
  (let ((loop (make-uv-loop)))
    (let rep ((i 0) (best #f))
      (if (= i reps)
          (begin (uv-loop-teardown! loop) best)
          (let ((r (one-rep loop)))
            (rep (+ i 1) (if best (vector-map min best r) r)))))))

(define (median xs)
  (let ((v (list->vector (sort < xs))))
    (vector-ref v (quotient (vector-length v) 2))))

(collect)
(collect-trip-bytes (expt 2 29))
(define m (make-mutex))
(define c (make-condition))
(define results '())
(define go #f)
(do ((i 0 (+ i 1))) ((= i threads))
  (fork-thread
   (lambda ()
     (with-mutex m (let wait () (unless go (condition-wait c m) (wait))))
     (let ((r (thread-best)))
       (with-mutex m (set! results (cons r results)) (condition-broadcast c))))))
(with-mutex m (set! go #t) (condition-broadcast c))
(with-mutex m (let wait () (unless (= (length results) threads) (condition-wait c m) (wait))))
(let ((cols (map (lambda (k) (median (map (lambda (r) (vector-ref r k)) results))) '(0 1 2 3))))
  (printf "~a ~{~a ~}~%" threads (map (lambda (x) (exact (round x))) cols)))
```

The rounds ran each build from a copy of the tree, with main's `src/`
taken from `git archive origin/main src` and the same release shim,
alternating main and #87 at 1 and then 4 threads in each round.
