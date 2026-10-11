#!r6rs
;;; SRFI-64 suite for (libuv dns) -- the full DNS surface: getaddrinfo,
;;; getnameinfo, uv-cancel!, the cancel race, and teardown with lookups in
;;; flight.
;;;
;;; BRANCH DISCIPLINE for the cancel rows: a cancel lands on exactly one of
;;; two branches, cancelled or already running, each with exactly one
;;; callback. Where the race is real (a same-turn cancel, a teardown sweep
;;; racing a worker pickup) the row is TOLERANT -- the outcome is asserted
;;; boolean and each branch is asserted with its PAIRED consequence, never
;;; the boolean alone. Where the setup forces the branch (a queued tail
;;; behind a blocker at pool 1) the row is FORCED and must not be weakened
;;; to tolerant.
;;;
;;; HERMETIC BY POLICY: every lookup below is numeric --
;;; AI_NUMERICHOST literals, numeric services -- so the resolver's
;;; configuration (/etc/hosts, nsswitch, mDNSResponder) is never consulted
;;; and nothing here can reach a network. "localhost" and named services
;;; are BANNED. The ban is watched at the VALUE level: one suite-local
;;; helper builds every hints alist, and a pure-arithmetic row asserts its
;;; computed ai_flags integer carries the shim's AI_NUMERICHOST bit -- the
;;; resolve-a-.invalid-name watchdog variant is a trap (NXDOMAIN maps to
;;; the same EAI_NONAME on any networked machine; measured).
;;;
;;; EVERY DNS WAIT GOES THROUGH run-until/ticking: a pending getaddrinfo
;;; parks a bare 'once in the poll until the pool posts, and the two legal
;;; NOWAIT outcomes after a submit (delivered already, still pending) were
;;; BOTH observed on CI, so no row may assert which branch a post-submit
;;; step takes. (collect) runs in every callback; sentinels are values no
;;; failure path produces.
;;;
;;; NOT pure: (libuv dns) reaches (libuv private native). Never add this to
;;; the Makefile's PURE_TESTS.
(import (rnrs)
        (rnrs mutable-pairs)
        (rnrs mutable-strings)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv timer)
        (libuv dns)
        ;; The chain walker reads raw memory, so (libuv dns) does not
        ;; export it; row k drives it with chains built here.
        (only (libuv private addrinfo-chain) addrinfo-chain->list)
        (only (rnrs eval) eval environment)
        (libuv private handles)
        (libuv private conditions)
        ;; alloc-zeroed/free!/copy-in!/c-int-set!/fill-sockaddr! build the
        ;; SYNTHETIC chains (hand-built nodes, freed with free!,
        ;; never uv_freeaddrinfo -- that call is legal only on
        ;; getaddrinfo-owned chains). dispatcher-ref reaches the installed
        ;; getaddrinfo dispatcher directly, which is the only way the
        ;; orphan and kind-mismatch arms are observable at all: no public
        ;; API can make libuv deliver a completion for an unregistered or
        ;; wrong-kind pointer.
        (only (libuv private native)
              live-counts alloc-zeroed free! copy-in! c-int-set! c-int-ref
              fill-sockaddr! dispatcher-ref align-16 uv-req-size
              ;; The request-seam matrix balances the counters a completion
              ;; it provokes moves.
              count-write-req-new! count-write-req-free!
              count-connect-req-new! count-connect-req-free!
              count-getaddrinfo-req-new! count-getaddrinfo-req-free!
              count-getnameinfo-req-new! count-getnameinfo-req-free!)
        ;; Shim-snapshotted values (read from the C headers, never
        ;; transcribed), for the numeric-flags watchdog and the
        ;; synthetic-chain field writes.
        (only (libuv private constants)
              ai-numerichost ai-numericserv ipproto-tcp
              af-inet af-inet6 af-unspec sock-stream sock-dgram
              uv-getaddrinfo-req-type
              sizeof-addrinfo sizeof-sockaddr-storage
              offsetof-addrinfo-ai-flags
              offsetof-addrinfo-ai-family offsetof-addrinfo-ai-socktype
              offsetof-addrinfo-ai-protocol offsetof-addrinfo-ai-addr
              offsetof-addrinfo-ai-canonname offsetof-addrinfo-ai-next)
        (uv-testing)
        (only (uv-evidence) live-count describe)
        ;; The engine-sweep driver drives the changed-arguments sweeps.
        (uv-sweep)
        (only (chezscheme) collect putenv foreign-procedure foreign-entry?))

;; PIN THE THREADPOOL TO ONE WORKER, before any native/threadpool touch.
;; libuv reads UV_THREADPOOL_SIZE exactly once, at the first
;; uv__work_submit (vendor/libuv/src/threadpool.c:194-217); Chez's putenv
;; writes the same process environment libuv reads, measured through
;; libuv's own uv_os_getenv. The cancel rows depend on the pinned pool (at
;; pool 1 a queued lookup's cancel was measured to win 1000 of 1000
;; trials); pinning from this suite's first line keeps every row in the
;; same measured regime.
(putenv "UV_THREADPOOL_SIZE" "1")

;; SRFI-64's default runner does not set a process exit code, so the suite
;; ends with its own (exit ...).
(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner prints only a failing row's title. The sweep rows
;; return their evidence when they fail, so print that too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

;; #f is the worst possible expected value -- a missing key, a defaulting
;; accessor and a swallowed raise all produce it -- so every err
;; observation maps to a symbol: 'no-error for success, the errno symbol
;; for an &uv-errno-error, and a tagged list for anything else.
;; 'callback-never-fired is the seed every observer starts at, and no
;; delivery path can produce it.
(define (err->symbol err)
  (cond ((not err) 'no-error)
        ((uv-errno-error? err) (uv-errno-error-errno err))
        (else (list 'unexpected-err-object err))))

(define cap 64)

;; --- THE hints helper (the value-level watchdog's target) ----------------
;; Every hints alist a lookup in this suite passes is built HERE, and the
;; helper ALWAYS includes 'numeric-host -- plus 'numeric-serv when the row
;; passes a service. Rows append their own family/socktype/protocol pairs.
;; (The boundary-REJECTION rows further down build malformed hints inline,
;; deliberately: those calls are refused before any allocation or native
;; call, so no resolver can be consulted through them.)
(define (suite-hints with-serv? . pairs)
  (append pairs
          (list (cons 'flags (if with-serv?
                                 '(numeric-host numeric-serv)
                                 '(numeric-host))))))

;; The suite's own symbol->bit view of the numeric flags, for the watchdog
;; rows only: an unrecognized symbol contributes 0, so a helper that loses
;; or misspells a flag loses the bit and the watchdog fails by name.
(define (flags->int flags)
  (fold-left (lambda (acc flag)
               (bitwise-ior acc
                            (case flag
                              ((numeric-host) (ai-numerichost))
                              ((numeric-serv) (ai-numericserv))
                              (else 0))))
             0 flags))

(test-begin "dns")

;; --- seeds ---------------------------------------------------------------
;; Counter rows need the DEV shim (Makefile CFLAGS_DEV); against a
;; production shim the live queries answer a constant 0 and the "moved"
;; rows would fail pointing at cross-wiring that is not there.
(test-equal "seed: no getaddrinfo request is live before this suite starts one"
  0 (live-count 'getaddrinfo-req))

(define registry-count-at-start (registry-count))

(test-equal "seed: the registry is empty before this suite registers anything"
  0 registry-count-at-start)

(define orphans-at-start (length (orphan-callback-events)))

(define l (make-uv-loop))
(define registry-with-loop (registry-count))

;; --- the value-level watchdog on the numeric flags -----------------------
;; Pure arithmetic over the helper's own output and the shim's snapshot;
;; fails instantly and offline if the helper ever stops carrying the
;; numeric flags. (The constants snapshot exists because make-uv-loop just
;; ran ensure-native-loaded!.)
(test-equal "numeric-flags watchdog: helper flags carry the AI_NUMERICHOST bit"
  'numeric-host-bit-set
  (let ((n (flags->int (cdr (assq 'flags (suite-hints #t))))))
    (if (= (ai-numerichost) (bitwise-and n (ai-numerichost)))
        'numeric-host-bit-set
        (list 'numeric-host-bit-missing n))))

(test-equal "numeric-flags watchdog: with a service the helper also carries AI_NUMERICSERV"
  'numeric-serv-bit-set
  (let ((n (flags->int (cdr (assq 'flags (suite-hints #t))))))
    (if (= (ai-numericserv) (bitwise-and n (ai-numericserv)))
        'numeric-serv-bit-set
        (list 'numeric-serv-bit-missing n))))

(test-equal "numeric-flags watchdog: the no-service spelling still carries AI_NUMERICHOST"
  'numeric-host-bit-set
  (let ((n (flags->int (cdr (assq 'flags (suite-hints #f))))))
    (if (= (ai-numerichost) (bitwise-and n (ai-numerichost)))
        'numeric-host-bit-set
        (list 'numeric-host-bit-missing n))))

;; --- prologue: one throwaway drained lookup pins the pool ----------------
;; The pool is process-global and sized at the FIRST submit, so this
;; lookup is what latches UV_THREADPOOL_SIZE=1 before any dependent row.
;; Asserted rather than fire-and-forgotten: a comment-that-is-a-check.
(define pin-err 'callback-never-fired)

(test-equal "prologue: the pool-pinning lookup starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-getaddrinfo! l "127.0.0.1" "80"
                     (suite-hints #t '(family . inet) '(socktype . stream))
                     (lambda (err results)
                       (collect)
                       (set! pin-err (err->symbol err))))
    'started))

(run-until/ticking l (lambda () (not (eq? pin-err 'callback-never-fired))) cap)

(test-equal "prologue: the pool-pinning throwaway lookup drained clean"
  'no-error pin-err)

;; --- row a: numeric v4, fully pinned hints -------------------------------
;; family/socktype/protocol pinned so every symbol->int write in the hints
;; tail is exercised; the answer is measured identical on both libcs: one
;; inet/stream/tcp entry, the literal rendered back, the numeric service
;; decoded, no canonname.
(define a-err 'callback-never-fired)
(define a-results 'callback-never-fired)

(test-equal "v4: the lookup starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-getaddrinfo! l "127.0.0.1" "80"
                     (suite-hints #t '(family . inet) '(socktype . stream)
                                  '(protocol . tcp))
                     (lambda (err results)
                       (collect)
                       (set! a-err (err->symbol err))
                       (set! a-results results)))
    'started))

(run-until/ticking l (lambda () (not (eq? a-err 'callback-never-fired))) cap)

(test-equal "v4: err is #f on success" 'no-error a-err)

(test-equal "v4: exactly one record" 1 (length a-results))

(test-equal "v4: the result is a uv-addrinfo record"
  'an-addrinfo (if (uv-addrinfo? (car a-results)) 'an-addrinfo 'not-a-record))

(test-equal "v4: family decodes to the symbol inet"
  'inet (uv-addrinfo-family (car a-results)))

(test-equal "v4: the literal renders back through uv_ip_name"
  "127.0.0.1" (uv-addrinfo-address (car a-results)))

(test-equal "v4: the numeric service decodes to the integer port"
  80 (uv-addrinfo-port (car a-results)))

(test-equal "v4: socktype decodes to the symbol stream"
  'stream (uv-addrinfo-socktype (car a-results)))

(test-equal "v4: protocol decodes to the symbol tcp"
  'tcp (uv-addrinfo-protocol (car a-results)))

(test-equal "v4: canonname is #f without the canonname flag"
  'absent (if (uv-addrinfo-canonname (car a-results)) 'present 'absent))

;; --- row a2: absent service crosses as NULL ------------------------------
;; service #f -> NULL (measured: #f crosses as NULL, not ""); with
;; no service there is nothing to put in sin_port, so the port is 0 --
;; pure formatting, no /etc/services.
(define a2-err 'callback-never-fired)
(define a2-results 'callback-never-fired)

(test-equal "absent service: the lookup starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-getaddrinfo! l "127.0.0.1" #f
                     (suite-hints #f '(family . inet) '(socktype . stream))
                     (lambda (err results)
                       (collect)
                       (set! a2-err (err->symbol err))
                       (set! a2-results results)))
    'started))

(run-until/ticking l (lambda () (not (eq? a2-err 'callback-never-fired))) cap)

(test-equal "absent service: lookup succeeds" 'no-error a2-err)

(test-equal "absent service: port decodes as 0"
  '(0) (map uv-addrinfo-port a2-results))

;; --- row b: numeric v6 ---------------------------------------------------
;; The v6 row is the PORTABILITY TRAP's live check:
;; the walk reads sin6_port at the shim's own offset and renders through
;; uv_ip_name, on a family whose struct layout the two libcs disagree
;; about. Family pinned inet6 exercises the AF_INET6 hint write.
(define b-err 'callback-never-fired)
(define b-results 'callback-never-fired)

(test-equal "v6: the lookup starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-getaddrinfo! l "::1" "80"
                     (suite-hints #t '(family . inet6) '(socktype . stream))
                     (lambda (err results)
                       (collect)
                       (set! b-err (err->symbol err))
                       (set! b-results results)))
    'started))

(run-until/ticking l (lambda () (not (eq? b-err 'callback-never-fired))) cap)

(test-equal "v6: err is #f on success" 'no-error b-err)

(test-equal "v6: exactly one record" 1 (length b-results))

(test-equal "v6: family decodes to the symbol inet6"
  'inet6 (uv-addrinfo-family (car b-results)))

(test-equal "v6: the literal renders back"
  "::1" (uv-addrinfo-address (car b-results)))

(test-equal "v6: the port decodes at the sin6_port offset"
  80 (uv-addrinfo-port (car b-results)))

;; --- row b2: dgram/udp decode through a real chain -----------------------
;; Exercises the SOCK_DGRAM and IPPROTO_UDP hint writes and their decode
;; arms with a pinned, deterministic single-entry answer.
(define b2-err 'callback-never-fired)
(define b2-results 'callback-never-fired)

(test-equal "dgram/udp: the lookup starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-getaddrinfo! l "::1" "443"
                     (suite-hints #t '(family . inet6) '(socktype . dgram)
                                  '(protocol . udp))
                     (lambda (err results)
                       (collect)
                       (set! b2-err (err->symbol err))
                       (set! b2-results results)))
    'started))

(run-until/ticking l (lambda () (not (eq? b2-err 'callback-never-fired))) cap)

(test-equal "dgram/udp: lookup succeeds" 'no-error b2-err)

(test-equal "dgram/udp: socktype and protocol decode to their symbols"
  '((dgram udp 443))
  (map (lambda (r) (list (uv-addrinfo-socktype r) (uv-addrinfo-protocol r)
                         (uv-addrinfo-port r)))
       b2-results))

;; --- row c: unpinned socktype => a real multi-entry chain ----------------
;; SET-CONTAINMENT, NEVER ORDER OR COUNT EQUALITY: Darwin answers 2 entries
;; dgram-first with no raw; glibc answers 3 stream-first including raw --
;; both shapes measured twice per OS. A
;; row asserting order or exact count passes on one CI OS and fails on the
;; other by construction.
(define c-err 'callback-never-fired)
(define c-results 'callback-never-fired)

(test-equal "unpinned socktype: the lookup starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-getaddrinfo! l "127.0.0.1" "80"
                     (suite-hints #t)
                     (lambda (err results)
                       (collect)
                       (set! c-err (err->symbol err))
                       (set! c-results results)))
    'started))

(run-until/ticking l (lambda () (not (eq? c-err 'callback-never-fired))) cap)

(test-equal "unpinned socktype: lookup succeeds" 'no-error c-err)

(test-equal "unpinned socktype: the chain has at least two entries"
  'multi-entry
  (if (>= (length c-results) 2) 'multi-entry (list 'entries (length c-results))))

(test-equal "unpinned socktype: the socktype set contains stream and dgram"
  'both-present
  (let ((socktypes (map uv-addrinfo-socktype c-results)))
    (if (and (memq 'stream socktypes) (memq 'dgram socktypes))
        'both-present
        (list 'socktypes socktypes))))

(test-equal "unpinned socktype: every entry carries the same address"
  'all-same-address
  (if (for-all (lambda (r) (equal? "127.0.0.1" (uv-addrinfo-address r)))
               c-results)
      'all-same-address
      (list 'addresses (map uv-addrinfo-address c-results))))

(test-equal "unpinned socktype: every entry carries the same port"
  'all-port-80
  (if (for-all (lambda (r) (equal? 80 (uv-addrinfo-port r))) c-results)
      'all-port-80
      (list 'ports (map uv-addrinfo-port c-results))))

;; --- row d: AF_UNSPEC + a v4 literal => exactly one family ---------------
;; The unspec symbol is written EXPLICITLY (exercising the AF_UNSPEC hint
;; write, distinct from row c's omitted-family zero); the literal pins the
;; family the resolver answers (measured: all-inet on both libcs).
(define d-err 'callback-never-fired)
(define d-results 'callback-never-fired)

(test-equal "unspec + v4 literal: the lookup starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-getaddrinfo! l "127.0.0.1" "80"
                     (suite-hints #t '(family . unspec) '(socktype . stream))
                     (lambda (err results)
                       (collect)
                       (set! d-err (err->symbol err))
                       (set! d-results results)))
    'started))

(run-until/ticking l (lambda () (not (eq? d-err 'callback-never-fired))) cap)

(test-equal "unspec + v4 literal: lookup succeeds" 'no-error d-err)

(test-equal "unspec + v4 literal: a nonempty all-inet chain"
  'single-family-inet
  (if (and (not (null? d-results))
           (for-all (lambda (r) (eq? 'inet (uv-addrinfo-family r))) d-results))
      'single-family-inet
      (list 'families (map uv-addrinfo-family d-results))))

;; --- row e: non-numeric name under numeric-host => EAI_NONAME ------------
;; The deterministic OFFLINE error path that stands in for banned
;; resolver lookups: AI_NUMERICHOST makes a non-numeric name fail in pure
;; formatting, asynchronously, with empty results -- '() and never #f
;; (err is the sole discriminant).
(define e-err 'callback-never-fired)
(define e-results 'callback-never-fired)

(test-equal "numeric-host + non-numeric name: the lookup starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-getaddrinfo! l "chez-libuv-not-numeric.invalid" "80"
                     (suite-hints #t '(socktype . stream))
                     (lambda (err results)
                       (collect)
                       (set! e-err (err->symbol err))
                       (set! e-results results)))
    'started))

(run-until/ticking l (lambda () (not (eq? e-err 'callback-never-fired))) cap)

(test-equal "numeric-host + non-numeric name: errno is EAI_NONAME, by symbol"
  'EAI_NONAME e-err)

(test-equal "numeric-host + non-numeric name: results are '(), never #f"
  '() e-results)

;; --- row f: every run delivers fresh records (copied at the boundary) ----
(define f1-results 'callback-never-fired)
(define f2-results 'callback-never-fired)

(test-equal "two identical lookups: the first starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-getaddrinfo! l "127.0.0.1" "80"
                     (suite-hints #t '(family . inet) '(socktype . stream))
                     (lambda (err results) (collect) (set! f1-results results)))
    'started))

(run-until/ticking l (lambda () (not (eq? f1-results 'callback-never-fired))) cap)

(test-equal "two identical lookups: the second starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-getaddrinfo! l "127.0.0.1" "80"
                     (suite-hints #t '(family . inet) '(socktype . stream))
                     (lambda (err results) (collect) (set! f2-results results)))
    'started))

(run-until/ticking l (lambda () (not (eq? f2-results 'callback-never-fired))) cap)

(test-equal "two identical lookups answer distinct result lists"
  'fresh (if (eq? f1-results f2-results) 'shared 'fresh))

(test-equal "two identical lookups answer pairwise-distinct records"
  'fresh
  (if (exists (lambda (r1) (exists (lambda (r2) (eq? r1 r2)) f2-results))
              f1-results)
      'shared
      'fresh))

;; --- row g: in flight, and freed BEFORE on-complete ----------------------
;; The lifetime contract: the block is deregistered, freed,
;; counted, and ptr-zeroed all before on-complete runs. Observed from
;; INSIDE the callback, which is the only vantage point that can tell
;; "freed before" from "freed after".
(define g-live-in-callback 'callback-never-fired)
(define g-ptr-in-callback 'callback-never-fired)
(define g-registry-in-callback 'callback-never-fired)
(define g-registry-before-submit (registry-count))

;; The request the start answers, once it has started.
(define g-req 'never-started)

(test-equal "in flight: the lookup starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (set! g-req
          (uv-getaddrinfo! l "127.0.0.1" "80"
                           (suite-hints #t '(family . inet) '(socktype . stream)
                                        '(protocol . tcp))
                           (lambda (err results)
                             (collect)
                             (set! g-live-in-callback (live-count 'getaddrinfo-req))
                             (set! g-ptr-in-callback (req-ptr g-req))
                             (set! g-registry-in-callback (registry-count)))))
    'started))

;; Between the submit and the first uv-run nothing can deliver (callbacks
;; run only inside uv-run, on the loop thread), so these two mid-flight
;; assertions are race-free -- unlike anything about a post-submit NOWAIT
;; branch, which the header bans outright.
(test-equal "in flight: the live counter reads 1 after submit, before stepping"
  1 (live-count 'getaddrinfo-req))

(test-equal "in flight: the request block is registered"
  (+ g-registry-before-submit 1) (registry-count))

(test-equal "in flight: the start call answered an opaque request record"
  'a-req (if (uv-req? g-req) 'a-req 'not-a-req))

;; THE BOUNDARY-WRITE WATCHDOG, closing the loop the helper watchdog above
;; cannot see: dropping a c-int-set! in the start call's hints writing
;; would otherwise leave this suite green on any networked machine (the
;; same NXDOMAIN trap the header describes for the flags bit). The
;; co-allocated hints tail of the IN-FLIGHT block is read back at the same
;; shim offsets the start call wrote through. Deterministic, offline, and
;; race-free: libuv memcpys node/service/hints into its own req-owned
;; block before uv_getaddrinfo returns (getaddrinfo.c:174-208) and never
;; reads ours again, and the worker writes only the request head -- the
;; tail past align-16(req-size) is exclusively ours.
(test-equal "in flight: the hints tail carries exactly what the start call wrote"
  (list (flags->int '(numeric-host numeric-serv))
        (af-inet) (sock-stream) (ipproto-tcp))
  (let ((tail (+ (req-ptr g-req)
                 (align-16 (uv-req-size (uv-getaddrinfo-req-type))))))
    (list (c-int-ref (+ tail (offsetof-addrinfo-ai-flags)))
          (c-int-ref (+ tail (offsetof-addrinfo-ai-family)))
          (c-int-ref (+ tail (offsetof-addrinfo-ai-socktype)))
          (c-int-ref (+ tail (offsetof-addrinfo-ai-protocol))))))

(run-until/ticking l (lambda () (not (eq? g-live-in-callback
                                          'callback-never-fired)))
                   cap)

(test-equal "freed before on-complete: the live counter reads 0 inside the callback"
  0 g-live-in-callback)

(test-equal "freed before on-complete: the record's ptr is zeroed inside the callback"
  0 g-ptr-in-callback)

;; +1 is run-until/ticking's own 1 ms ticker, live for the duration of the
;; wait; the DNS entry itself must already be gone.
(test-equal "freed before on-complete: the registry entry is popped inside the callback"
  (+ g-registry-before-submit 1) g-registry-in-callback)

;; --- uv-dns-request? (the kind-based domain predicate) -------------------
(test-equal "uv-dns-request? accepts a getaddrinfo request record"
  'dns-request (if (uv-dns-request? g-req) 'dns-request 'not-dns))

(test-equal "uv-dns-request? refuses a non-record"
  'not-dns (if (uv-dns-request? "127.0.0.1") 'dns-request 'not-dns))

(define probe-timer (make-uv-timer l))

(test-equal "uv-dns-request? refuses a handle record"
  'not-dns (if (uv-dns-request? probe-timer) 'dns-request 'not-dns))

;; The discriminating case for the KIND check: a request record that is
;; not a DNS request. Constructed bare (no registration, no native call);
;; the predicate reads only the kind field, so the placeholder ptr is never
;; dereferenced.
(test-equal "uv-dns-request? refuses a non-DNS request record, by kind"
  'not-dns
  (if (uv-dns-request? (%make-uv-req-record 1 'write #f #f))
      'dns-request 'not-dns))

;; --- row h: resubmit from inside the callback, chain of three ------------
;; Re-entrant submission in miniature: each completion submits the
;; next lookup from inside on-complete, and the completions arrive in
;; submission order.
(define h-order '())

;; The next submission runs in this callback, and a raise there would leave
;; from the wait below as the suite's end. Caught, it is the chain's next
;; entry, and the chain row fails carrying it.
(define (h-submit! n)
  (uv-getaddrinfo! l "127.0.0.1" "80"
                   (suite-hints #t '(family . inet) '(socktype . stream))
                   (lambda (err results)
                     (collect)
                     (set! h-order (cons (list n (err->symbol err)
                                               (length results))
                                         h-order))
                     (when (< n 3)
                       (guard (e (#t (set! h-order
                                           (cons (list (+ n 1) 'raised (describe e))
                                                 h-order))))
                         (h-submit! (+ n 1)))))))

(test-equal "a chain of three resubmissions: the first lookup starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (h-submit! 1)
    'started))

(run-until/ticking l (lambda () (= 3 (length h-order))) cap)

(test-equal "a chain of three resubmissions completes in order, each clean"
  '((1 no-error 1) (2 no-error 1) (3 no-error 1))
  (reverse h-order))

;; --- row i: the post-registration sync failure, and its undo -------------
;; An empty hostname reaches libuv (NO Scheme-side empty-string validation,
;; deliberately -- adding one would make this guard untestable) and
;; fails DETERMINISTICALLY in uv__idna_toascii with UV_EINVAL, after our
;; register/count, before any possible callback. submit-request!'s undo must
;; reverse exactly that much. This row also drives the THREE-
;; ARGUMENT arity (hints omitted => NULL hints pointer) all the way to the
;; native call, without any resolver consultation.
(define i-fired 'callback-never-fired)

(test-equal "empty node: the idna UV_EINVAL surfaces as a sync raise"
  'EINVAL
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t 'wrong-condition))
    (uv-getaddrinfo! l "" "80" (lambda (err results) (set! i-fired 'fired)))
    'no-raise))

;; The explicit #f and '() hint spellings canonicalize to the same NULL
;; pointer, proven on the same deterministic sync-failure path.
(test-equal "empty node via #f hints: same sync EINVAL through the 4-arity"
  'EINVAL
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t 'wrong-condition))
    (uv-getaddrinfo! l "" "80" #f (lambda (err results) (set! i-fired 'fired)))
    'no-raise))

(test-equal "empty node via '() hints: same sync EINVAL through the 4-arity"
  'EINVAL
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t 'wrong-condition))
    (uv-getaddrinfo! l "" "80" '() (lambda (err results) (set! i-fired 'fired)))
    'no-raise))

(test-equal "sync failure: the live counter is back to 0 (register undone)"
  0 (live-count 'getaddrinfo-req))

(test-equal "sync failure: the registry is back to its pre-call population"
  (+ registry-with-loop 1) (registry-count))  ; loop + probe-timer

;; No request exists after a sync failure, so stepping the loop cannot race
;; anything (the NOWAIT ban is about steps AFTER a live submit).
(uv-run l 'nowait)

(test-equal "sync failure: no callback ever fires"
  'callback-never-fired i-fired)

;; --- row j: a raising on-complete surfaces as &uv-callback-error ---------
;; The raise is caught by the seam's guard and recorded against the loop the
;; seam found through registry-loop-of before the dispatcher deregistered
;; the request (no handle-loop route exists for a handle-less request),
;; then re-raised by uv-run.
(test-equal "a raising on-complete: the lookup starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-getaddrinfo! l "127.0.0.1" "80"
                     (suite-hints #t '(family . inet) '(socktype . stream))
                     (lambda (err results)
                       (collect)
                       (raise 'dns-on-complete-sentinel-raise)))
    'started))

(test-equal "a raising on-complete re-raises from uv-run as &uv-callback-error"
  '(callback-error dns-on-complete-sentinel-raise)
  (guard (e ((uv-callback-error? e)
             (list 'callback-error (uv-callback-error-cause e)))
            (#t (list 'wrong-condition e)))
    (run-until/ticking l (lambda () #f) cap)
    'no-raise))

;; The loop survives its callback's raise: the same loop answers another
;; full lookup afterwards.
(define j2-err 'callback-never-fired)

(test-equal "after the callback error: the lookup starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-getaddrinfo! l "127.0.0.1" "80"
                     (suite-hints #t '(family . inet) '(socktype . stream))
                     (lambda (err results)
                       (collect)
                       (set! j2-err (err->symbol err))))
    'started))

(run-until/ticking l (lambda () (not (eq? j2-err 'callback-never-fired))) cap)

(test-equal "the loop is usable after the callback error" 'no-error j2-err)

;; --- row l: boundary validation, before the first allocation -------------
;; The pure validators run inside uv-getaddrinfo! with who
;; 'uv-getaddrinfo!; each refusal happens before anything is allocated,
;; registered, or counted -- asserted by the counter/registry rows after
;; the block. Malformed hints are built inline here BECAUSE these calls
;; must never reach a native call (see the helper's note).
(define (getaddrinfo-rejection thunk)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e)
                   (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (thunk)
    'no-raise))

(test-equal "boundary: a non-loop first argument is refused"
  '(uv-getaddrinfo! not-a-uv-loop)
  (getaddrinfo-rejection
   (lambda () (uv-getaddrinfo! 'not-a-loop "127.0.0.1" "80"
                               (lambda (err results) #f)))))

(test-equal "boundary: a duplicate hint key is refused"
  '(uv-getaddrinfo! duplicate-hint-key)
  (getaddrinfo-rejection
   (lambda () (uv-getaddrinfo! l "127.0.0.1" "80"
                               '((family . inet) (family . inet6))
                               (lambda (err results) #f)))))

(test-equal "boundary: an unknown flag is refused"
  '(uv-getaddrinfo! unknown-hint-flag)
  (getaddrinfo-rejection
   (lambda () (uv-getaddrinfo! l "127.0.0.1" "80"
                               '((flags . (numeric-host addrconfig)))
                               (lambda (err results) #f)))))

(test-equal "boundary: node and service both absent is refused in Scheme"
  '(uv-getaddrinfo! node-and-service-both-absent)
  (getaddrinfo-rejection
   (lambda () (uv-getaddrinfo! l #f #f (suite-hints #t)
                               (lambda (err results) #f)))))

;; Guards the MEASURED prefix-resolution hazard:
;; "127.0.0.1\x0;.evil" would otherwise resolve silently as 127.0.0.1.
(test-equal "boundary: an embedded NUL in node is refused"
  '(uv-getaddrinfo! node-contains-nul)
  (getaddrinfo-rejection
   (lambda () (uv-getaddrinfo! l "127.0.0.1\x0;.evil" "80" (suite-hints #t)
                               (lambda (err results) #f)))))

(test-equal "boundary: a non-procedure on-complete is refused"
  '(uv-getaddrinfo! on-complete-not-a-procedure)
  (getaddrinfo-rejection
   (lambda () (uv-getaddrinfo! l "127.0.0.1" "80" (suite-hints #t)
                               'not-a-procedure))))

(test-equal "boundary: every rejection above allocated and registered nothing"
  (list 0 (+ registry-with-loop 1))   ; loop + probe-timer
  (list (live-count 'getaddrinfo-req) (registry-count)))

;; --- arguments that change during the call -------------------------------
;; uv-getaddrinfo! validates its node, service and hints, allocates the
;; request block, writes the hints into it, and passes libuv the node and
;; service. An engine's timer can expire anywhere in that, and its handler
;; can change the caller's arguments before the call resumes (so can another
;; thread). The validators answer copies, and the call allocates and writes
;; from those alone, so a change is either refused before anything is
;; allocated or reaches nothing.
;;
;; Each sweep runs one lookup in an engine at rising fuel, makes its change
;; at the first expiry, then resumes the lookup. Fuel 1 expires before the
;; call checks anything, and the sweep stops at the first run no expiry
;; reached, whatever that run's verdict, so between them every point in the
;; call is visited and a broken build fails by name instead of running to
;; the fuel cap. Each run has one right answer:
;;   'refused   the call refused the change under its own name, with no
;;              request left registered or counted;
;;   'resolved  the change came too late to matter: the request carries the
;;              hints the call was given, and resolves the node and service
;;              the call was given;
;;   'untouched the last run, which no expiry reached.
;; Anything else is the evidence, a list.
;;
;; The first sweep is the leak's. A call that checks the hints again after
;; allocating its block refuses a family turned bogus after the block exists
;; exactly as one turned bogus before it, but with the block allocated and
;; unregistered, and nothing frees it. The request counters count from
;; registration on and never see that block; the debug shim's block counter
;; does (live-counts' 'block), so a refused run must leave it where it found
;; it, and Valgrind reports the block definitely lost when `make
;; test-memory` runs this suite. The other three fail here by name on a call
;; that reads its arguments again after checking them: a hints change made
;; with valid values lands in the request's hints, and a NUL written into
;; the node or the service reaches libuv as a shorter name.
(define sweep-max-fuel 400)

(define sweep-hints-tail
  (list (flags->int '(numeric-host numeric-serv)) (af-inet) (sock-stream) 0))

(define sweep-resolution '((inet "127.0.0.1" 8080 stream)))

;; The hints tail of an in-flight request, read as row g reads it.
(define (in-flight-hints req)
  (let ((tail (+ (req-ptr req)
                 (align-16 (uv-req-size (uv-getaddrinfo-req-type))))))
    (list (c-int-ref (+ tail (offsetof-addrinfo-ai-flags)))
          (c-int-ref (+ tail (offsetof-addrinfo-ai-family)))
          (c-int-ref (+ tail (offsetof-addrinfo-ai-socktype)))
          (c-int-ref (+ tail (offsetof-addrinfo-ai-protocol))))))

(define (resolution err results)
  (if err
      (list 'err (err->symbol err))
      (map (lambda (r) (list (uv-addrinfo-family r) (uv-addrinfo-address r)
                             (uv-addrinfo-port r) (uv-addrinfo-socktype r)))
           results)))

;; A variant names its change, the reason the call refuses it with, and the
;; change itself, made to the run's own fresh node, service and hints.
(define-record-type sweep-variant
  (fields name refusal change!))

(define sweep-variants
  (list
   ;; The leak's own shape.
   (make-sweep-variant
    'family-turned-bogus 'unknown-hint-family
    (lambda (node service hints) (set-cdr! (assq 'family hints) 'bogus)))
   ;; Valid values, so a call that reads the hints again after checking them
   ;; writes inet6 and no socktype into the request rather than refusing.
   ;; The socktype is walked after the family, so a run that saw its new key
   ;; was refused for it, and a run that was not saw the family as given.
   (make-sweep-variant
    'family-changed-socktype-renamed 'unknown-hint-key
    (lambda (node service hints)
      (set-cdr! (assq 'family hints) 'inet6)
      (set-car! (assq 'socktype hints) 'color)))
   ;; "127\x0;0.0.1" reads as "127", which resolves as 0.0.0.127.
   (make-sweep-variant
    'nul-in-node 'node-contains-nul
    (lambda (node service hints) (string-set! node 3 #\nul)))
   ;; "80\x0;0" reads as "80".
   (make-sweep-variant
    'nul-in-service 'service-contains-nul
    (lambda (node service hints) (string-set! service 2 #\nul)))))

;; lookup-verdict : sweep-variant exact-positive-integer (-> any)
;;                  -> (values verdict expired?)
;; One run of a sweep: uv-getaddrinfo! on a fresh node, service and hints,
;; in an engine with FUEL, with the variant's change made at the first
;; expiry. BEFORE runs in the engine just ahead of the lookup; the sweeps'
;; does nothing. A call still running after the driver's cap is given up
;; there (tests/uv-sweep.sls), so a lookup whose walk came to loop fails
;; its run by name instead of hanging the suite, as a driver that resumed
;; without a cap would. The verb is called here by name, inside the
;; guard, where seed-gates' rule 4 reads it.
(define (lookup-verdict variant fuel before)
  (let* ((node (string-copy "127.0.0.1"))
         (service (string-copy "8080"))
         (hints (suite-hints #t (cons 'family 'inet) (cons 'socktype 'stream)))
         (delivered 'callback-never-fired)
         (registry-before (registry-count))
         (requests-before (live-count 'getaddrinfo-req))
         (blocks-before (live-count 'block)))
    (let-values (((outcome expired)
                  (run-capped
                   (lambda ()
                     (guard (e ((uv-invalid-argument? e)
                                (list 'refused
                                      (uv-invalid-argument-who e)
                                      (uv-invalid-argument-reason e)))
                               (#t (list 'raised (describe e))))
                       (before)
                       (list 'submitted
                             (uv-getaddrinfo! l node service hints
                                              (lambda (err results)
                                                (collect)
                                                (set! delivered
                                                      (resolution err results)))))))
                   fuel
                   (lambda ()
                     ((sweep-variant-change! variant) node service hints)))))
      (let* ((registry-after (registry-count))
             (requests-after (live-count 'getaddrinfo-req))
             (blocks-after (live-count 'block)))
        (values
         (case (car outcome)
           ((refused)
            (if (and (equal? (cdr outcome)
                             (list 'uv-getaddrinfo! (sweep-variant-refusal variant)))
                     (= registry-after registry-before)
                     (= requests-after requests-before)
                     (= blocks-after blocks-before))
                'refused
                (list 'refused-as (cdr outcome)
                      'registered (- registry-after registry-before)
                      'counted (- requests-after requests-before)
                      'blocks (- blocks-after blocks-before))))
           ((submitted)
            ;; Read before the drain: nothing can deliver before uv-run.
            (let* ((tail (in-flight-hints (cadr outcome)))
                   (drained (run-until/ticking
                             l (lambda () (not (eq? delivered 'callback-never-fired)))
                             cap)))
              (cond ((not (equal? tail sweep-hints-tail)) (list 'tail-was tail))
                    ((not (equal? delivered sweep-resolution))
                     (list 'resolved-as delivered drained))
                    (expired 'resolved)
                    (else 'untouched))))
           ;; A give-up, with what the run left behind.
           ((stuck-after-resumes)
            (append outcome
                    (list 'registered (- registry-after registry-before)
                          'counted (- requests-after requests-before)
                          'blocks (- blocks-after blocks-before))))
           (else outcome))
         expired)))))

;; lookup-sweep : sweep-variant -> (list-of (list fuel verdict expired?))
;; The driver keeps a raise between runs from aborting the suite: the
;; sweep ends there with a sweep-raised verdict (tests/uv-sweep.sls).
(define (lookup-sweep variant)
  (sweep-fuels (lambda (fuel) (lookup-verdict variant fuel (lambda () #f)))
               sweep-max-fuel
               (lambda (verdict) #f)))

(define blocks-before-sweeps (live-count 'block))

(define lookup-sweeps
  (map (lambda (v) (cons (sweep-variant-name v) (lookup-sweep v)))
       sweep-variants))

;; rows-where : (verdict -> boolean) -> (list-of (list name fuel verdict))
(define (rows-where bad?)
  (apply append
         (map (lambda (sweep)
                (map (lambda (row) (cons (car sweep) row))
                     (filter (lambda (row) (bad? (cadr row))) (cdr sweep))))
              lookup-sweeps)))

(define (verdict-is? kind) (lambda (v) (and (pair? v) (eq? (car v) kind))))

;; The rows below look for bad verdicts and must find none, which says
;; nothing unless each sweep saw its change refused and ran the call to the
;; end.
(test-equal "each sweep began before the call's own checks and ended in a run no expiry reached"
  (map (lambda (v) (list (sweep-variant-name v) 'refused 'untouched))
       sweep-variants)
  (map (lambda (sweep)
         (let ((rows (cdr sweep)))
           (list (car sweep)
                 (cadr (car rows))
                 (cadr (list-ref rows (- (length rows) 1))))))
       lookup-sweeps))

(test-equal "a lookup whose arguments changed during the call is refused by the call itself, leaving no request"
  '()
  (rows-where (lambda (v) (or ((verdict-is? 'refused-as) v)
                              ((verdict-is? 'raised) v)
                              ((verdict-is? 'sweep-raised) v)))))

(test-equal "a lookup the sweep let through carried the hints it was given"
  '()
  (rows-where (verdict-is? 'tail-was)))

(test-equal "a lookup the sweep let through resolved the node and service it was given"
  '()
  (rows-where (verdict-is? 'resolved-as)))

;; A lookup still running at the driver's cap is given up. The run spins
;; for three times the cap's ticks before it calls uv-getaddrinfo!, so a
;; driver that resumed without a cap would let it finish, and the run
;; would answer the lookup's own verdict instead of the
;; give-up. With no cap at all, a lookup that never ended would hang the
;; suite where this row fails.
(define (spin-past-cap)
  (let spin ((i 0))
    (when (< i (* 3 resume-cap resume-fuel)) (spin (+ i 1)))))

;; The give-up carries the run's counts, so a lookup given up after it had
;; registered a request or allocated a block says so.
(test-equal "a lookup still running at the driver's cap is given up, failing its run by name instead of hanging the suite"
  (list (list 'stuck-after-resumes resume-cap 'registered 0 'counted 0 'blocks 0) #t)
  (let-values (((verdict expired)
                (lookup-verdict (car sweep-variants) 1 spin-past-cap)))
    (list verdict expired)))

(test-equal "the sweeps left no request registered or counted, and no block allocated"
  (list 0 (+ registry-with-loop 1) blocks-before-sweeps)   ; loop + probe-timer
  (list (live-count 'getaddrinfo-req) (registry-count) (live-count 'block)))

;; A program that imports (libuv dns) cannot reach the walker: given any
;; number that is not a live chain, it crashes the process or answers
;; garbage. The control shows that the lookup finds a name the library
;; does export.
(test-equal "(libuv dns) exports its verbs but not the raw chain walker"
  '(exported not-exported)
  (map (lambda (name)
         (guard (e ((undefined-violation? e) 'not-exported)
                   (#t (list 'raised e)))
           (if (procedure? (eval name (environment '(libuv dns))))
               'exported
               'not-a-procedure)))
       '(uv-getaddrinfo! addrinfo-chain->list)))

;; --- row k: synthetic chains through addrinfo-chain->list ----------------
;; Hand-built struct addrinfo nodes: alloc-zeroed memory, fields written at
;; the SHIM's offsets, freed below with free! -- NEVER uv_freeaddrinfo,
;; which is legal only on getaddrinfo-owned chains. This is the
;; only honest way to drive the skip policy and the NULL-field arms: no
;; hermetic lookup can make the resolver hand back a non-INET entry or a
;; NULL ai_addr.

;; Pointer width derived from the shim's own layout rather than
;; transcribed: ai_addr and ai_canonname are ADJACENT pointer fields on
;; both supported libcs -- in opposite orders (an ftype that guessed
;; either order would be wrong on the other libc), which is exactly why
;; the absolute difference of their offsets is
;; sizeof(void*) either way.
(define pointer-width
  (abs (- (offsetof-addrinfo-ai-addr) (offsetof-addrinfo-ai-canonname))))

(define (write-pointer! base offset value)
  (let ((bv (make-bytevector pointer-width 0)))
    (bytevector-uint-set! bv 0 value (native-endianness) pointer-width)
    (copy-in! (+ base offset) bv 0 pointer-width)))

(define (make-synthetic-node family socktype protocol addr-ptr canon-ptr)
  (let ((node (alloc-zeroed (sizeof-addrinfo))))
    (c-int-set! (+ node (offsetof-addrinfo-ai-family)) family)
    (c-int-set! (+ node (offsetof-addrinfo-ai-socktype)) socktype)
    (c-int-set! (+ node (offsetof-addrinfo-ai-protocol)) protocol)
    (write-pointer! node (offsetof-addrinfo-ai-addr) addr-ptr)
    (write-pointer! node (offsetof-addrinfo-ai-canonname) canon-ptr)
    node))

(define (link-nodes! nodes)
  (for-each (lambda (node next)
              (write-pointer! node (offsetof-addrinfo-ai-next) next))
            nodes (append (cdr nodes) '(0)))
  (car nodes))

(define (make-c-string s)
  (let* ((bv (string->utf8 s))
         (len (bytevector-length bv))
         (mem (alloc-zeroed (+ len 1))))   ; the zeroed tail is the NUL
    (copy-in! mem bv 0 len)
    mem))

(define (make-synthetic-sockaddr ip port)
  (let ((addr (alloc-zeroed (sizeof-sockaddr-storage))))
    (fill-sockaddr! addr (string->utf8 (string-append ip "\x0;")) port
                    'test-dns-synthetic)
    addr))

;; k1: the skip policy. A non-INET entry (family AF_UNSPEC -- a value the
;; record has no honest representation for) is SKIPPED, and the walk
;; advances past it to the INET entry behind it. 203.0.113.9 is
;; TEST-NET-3: decode-only, never routed, and no lookup happens anyway.
;; fill-sockaddr! parses the address, so a parse that raises fails the
;; first row here by name. The node then carries a NULL ai_addr, and the
;; row that decodes its address fails too.
(define k-sockaddr
  (guard (e (#t (list 'raised (describe e))))
    (make-synthetic-sockaddr "203.0.113.9" 8080)))

(test-equal "synthetic: the sockaddr is built"
  'built (if (integer? k-sockaddr) 'built k-sockaddr))

(define k-canon (make-c-string "synthetic-canon.example"))
(define k-skip-node
  (make-synthetic-node (af-unspec) (sock-stream) 0 0 0))
(define k-inet-node
  (make-synthetic-node (af-inet) (sock-stream) 6151
                       (if (integer? k-sockaddr) k-sockaddr 0) k-canon))

(test-equal "synthetic: a non-INET entry is skipped, the entry behind it decoded"
  '((inet "203.0.113.9" 8080))
  (map (lambda (r) (list (uv-addrinfo-family r) (uv-addrinfo-address r)
                         (uv-addrinfo-port r)))
       (addrinfo-chain->list (link-nodes! (list k-skip-node k-inet-node)))))

;; k2: an unmapped protocol passes through as the raw exact int (lossless,
;; discriminable with symbol?; deliberately NOT a sentinel symbol, the shape
;; error codes take). 6151 maps to no IPPROTO this binding knows.
(test-equal "synthetic: an unmapped protocol int passes through losslessly"
  '(6151)
  (map uv-addrinfo-protocol
       (addrinfo-chain->list (link-nodes! (list k-skip-node k-inet-node)))))

;; k3: a canonname pointer decodes to a fresh Scheme string (the copy side
;; of the NULL->#f rule rows a/b pinned).
(test-equal "synthetic: a canonname C string is copied out"
  '("synthetic-canon.example")
  (map uv-addrinfo-canonname
       (addrinfo-chain->list (link-nodes! (list k-skip-node k-inet-node)))))

;; k4: all entries skipped is a legal '() -- the documented corollary
;; (a success whose entries were all skipped, indistinguishable from an
;; empty success).
(define k-lone-skip (make-synthetic-node (af-unspec) (sock-dgram) 0 0 0))

(test-equal "synthetic: an all-skipped chain answers '()"
  '() (addrinfo-chain->list (link-nodes! (list k-lone-skip))))

;; k5: NULL ai_addr on an INET entry. The zero-refusing
;; sockaddr->address-string answers #f WITHOUT calling native --
;; the entry is delivered, address #f, port 0, canonname #f. An unmapped
;; socktype int (424242) rides along, pinning the raw-int passthrough on
;; the socktype side.
(define k-null-addr-node
  (make-synthetic-node (af-inet) 424242 0 0 0))

(test-equal "synthetic: NULL ai_addr delivers address #f, port 0; raw socktype passes through"
  '((inet 424242 0 address-absent 0 canonname-absent))
  (map (lambda (r) (list (uv-addrinfo-family r)
                         (uv-addrinfo-socktype r)
                         (uv-addrinfo-protocol r)
                         (if (uv-addrinfo-address r) 'address-present 'address-absent)
                         (uv-addrinfo-port r)
                         (if (uv-addrinfo-canonname r) 'canonname-present 'canonname-absent)))
       (addrinfo-chain->list (link-nodes! (list k-null-addr-node)))))

;; k6: the empty chain (a NULL head) is '(), which is what makes the
;; dispatcher's uniform conversion correct on every failure status (res
;; is NULL on every failure/cancel).
(test-equal "synthetic: a NULL chain head answers '()"
  '() (addrinfo-chain->list 0))

;; Synthetic memory is freed with free!, never uv_freeaddrinfo.
(for-each free! (filter integer?
                        (list k-skip-node k-inet-node k-lone-skip
                              k-null-addr-node k-sockaddr k-canon)))

;; --- the dispatcher's step-1 arms, driven directly ----------------------
;; No public API can make libuv deliver a completion for an unregistered
;; pointer or a wrong-kind entry, so the installed dispatcher is invoked
;; from Scheme through its own seam -- the same technique
;; tests/test-native.sps uses on the uninstalled stubs.

;; Normal operation produced no orphans up to here.
(test-equal "no orphan events accumulated through normal operation"
  orphans-at-start (length (orphan-callback-events)))

;; The ORPHAN arm: an unregistered pointer with a NULL chain. The
;; dispatcher must record the orphan (there is no loop to record an error
;; against) and survive; uv_freeaddrinfo(NULL) is its documented no-op.
(define orphan-probe-ptr 987654321)

((dispatcher-ref 'getaddrinfo) orphan-probe-ptr 0 0)

(test-equal "orphan arm: the event is recorded with the dispatcher's name and pointer"
  (list 'getaddrinfo orphan-probe-ptr)
  (let ((events (orphan-callback-events)))
    (if (= (length events) (+ orphans-at-start 1))
        (let ((last (car (reverse events))))
          (list (car last) (cdr last)))
        (list 'orphan-count (length events)))))

;; The KIND-MISMATCH arm: a registered pointer of the WRONG kind (a timer
;; handle stands in for the cross-paired-trampoline bug state). The
;; dispatcher must refuse to free a chain of unknown provenance and raise;
;; the seam contains the raise, records it against the entry's loop, and
;; uv-run re-raises it -- while the mistaken entry itself is untouched.
((dispatcher-ref 'getaddrinfo) (handle-ptr probe-timer) 0 0)

(test-equal "kind-mismatch arm: contained, and re-raised from uv-run by name"
  '(callback-error uv-getaddrinfo-dispatch)
  (guard (e ((uv-callback-error? e) (list 'callback-error (condition-who e)))
            (#t (list 'wrong-condition e)))
    (uv-run l 'nowait)
    'no-raise))

(test-equal "kind-mismatch arm: the wrong-kind registry entry is untouched"
  'still-registered
  (if (eq? probe-timer (registry-ref (handle-ptr probe-timer)))
      'still-registered
      'entry-disturbed))

;; ========================================================================
;; uv-getnameinfo!, uv-cancel!, cancel/teardown rows
;; ========================================================================

;; --- seed: the second counter class starts at zero -----------------------
(test-equal "seed: no getnameinfo request is live before this suite starts one"
  0 (live-count 'getnameinfo-req))

;; --- row m: numeric reverse v4 ------------------------------------------
;; NI_NUMERICHOST|NI_NUMERICSERV makes the reverse pure formatting: the
;; hostname IS the literal rendered back and the service IS the port
;; printed in decimal -- both STRINGS (getnameinfo(3)'s output
;; vocabulary), no resolver, no /etc/services.
(define m-err 'callback-never-fired)
(define m-host 'callback-never-fired)
(define m-serv 'callback-never-fired)

(test-equal "reverse v4: the lookup starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-getnameinfo! l "127.0.0.1" 8080 '(numeric-host numeric-serv)
                     (lambda (err host service)
                       (collect)
                       (set! m-err (err->symbol err))
                       (set! m-host host)
                       (set! m-serv service)))
    'started))

(run-until/ticking l (lambda () (not (eq? m-err 'callback-never-fired))) cap)

(test-equal "reverse v4: err is #f on success" 'no-error m-err)

(test-equal "reverse v4: hostname is the literal rendered back"
  "127.0.0.1" m-host)

(test-equal "reverse v4: service is the port as a decimal STRING"
  "8080" m-serv)

;; --- row m2: numeric reverse v6 ------------------------------------------
;; The v6 reverse crosses fill-sockaddr!'s AF_INET6 arm into the request's
;; co-allocated sockaddr_storage tail and formats back out of it.
(define m2-err 'callback-never-fired)
(define m2-host 'callback-never-fired)
(define m2-serv 'callback-never-fired)

(test-equal "reverse v6: the lookup starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-getnameinfo! l "::1" 8080 '(numeric-host numeric-serv)
                     (lambda (err host service)
                       (collect)
                       (set! m2-err (err->symbol err))
                       (set! m2-host host)
                       (set! m2-serv service)))
    'started))

(run-until/ticking l (lambda () (not (eq? m2-err 'callback-never-fired))) cap)

(test-equal "reverse v6: err is #f on success" 'no-error m2-err)

(test-equal "reverse v6: hostname is the v6 literal rendered back"
  "::1" m2-host)

(test-equal "reverse v6: service is the port as a decimal STRING"
  "8080" m2-serv)

;; --- row n: getnameinfo request lifecycle, mirroring row g ---------------
;; The lifetime contract for the second request kind: deregistered,
;; freed, counted, ptr-zeroed all BEFORE on-complete runs -- observed from
;; inside the callback, the only vantage point that can tell "freed
;; before" from "freed after". The two strings the callback received were
;; copied out of the request block BEFORE that free (unix.h:353-354: they
;; point INTO it), which is what row m already proved by value.
(define n-live-in-callback 'callback-never-fired)
(define n-ptr-in-callback 'callback-never-fired)
(define n-registry-in-callback 'callback-never-fired)
(define n-registry-before-submit (registry-count))

;; The request the start answers, once it has started.
(define n-req 'never-started)

(test-equal "getnameinfo in flight: the lookup starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (set! n-req
          (uv-getnameinfo! l "127.0.0.1" 8080 '(numeric-host numeric-serv)
                           (lambda (err host service)
                             (collect)
                             (set! n-live-in-callback (live-count 'getnameinfo-req))
                             (set! n-ptr-in-callback (req-ptr n-req))
                             (set! n-registry-in-callback (registry-count)))))
    'started))

(test-equal "getnameinfo in flight: the live counter reads 1 after submit, before stepping"
  1 (live-count 'getnameinfo-req))

(test-equal "getnameinfo in flight: the request block is registered"
  (+ n-registry-before-submit 1) (registry-count))

(test-equal "getnameinfo in flight: the start call answered an opaque request record"
  'a-req (if (uv-req? n-req) 'a-req 'not-a-req))

;; The second kind in uv-dns-request?'s kind list, watched on a real
;; getnameinfo request.
(test-equal "uv-dns-request? accepts a getnameinfo request record"
  'dns-request (if (uv-dns-request? n-req) 'dns-request 'not-dns))

(run-until/ticking l (lambda () (not (eq? n-live-in-callback
                                          'callback-never-fired)))
                   cap)

(test-equal "getnameinfo freed before on-complete: the live counter reads 0 inside the callback"
  0 n-live-in-callback)

(test-equal "getnameinfo freed before on-complete: the record's ptr is zeroed inside the callback"
  0 n-ptr-in-callback)

(test-equal "getnameinfo freed before on-complete: the registry entry is popped inside the callback"
  (+ n-registry-before-submit 1) n-registry-in-callback)

;; --- cancel after completion: the zeroed-ptr guard ----------------------
;; n-req's block was freed and its stored ptr zeroed at the freeing site;
;; uv-cancel! must answer #f WITHOUT calling native -- uv_cancel reads
;; req->type through whatever pointer it is handed
;; (vendor/libuv/src/threadpool.c:399-441), and this one is stale. Both
;; observable halves are asserted: the #f, and that nothing raised. With
;; the zero check removed, uv_cancel reads req->type through the NULL
;; pointer; Chez raises that fault as "invalid memory reference", which
;; this row's guard catches, so the row fails by name and the suite runs
;; on. The zeroing at the freeing site is what makes a stale pointer NULL
;; here: a call through a stale address that was reused would not fault,
;; and only the memory gate would see it.
(test-equal "cancel after completion: answers #f, and nothing raises"
  'cancelled-too-late
  (guard (e (#t (list 'raised e)))
    (case (uv-cancel! n-req)
      ((#f) 'cancelled-too-late)
      ((#t) 'cancel-claimed-success)
      (else 'not-a-boolean))))

;; --- uv-cancel! domain rows ---------------------------------------------
;; DNS requests ONLY. A request record of a stream or connect kind is
;; REFUSED, not answered #f: libuv would answer UV_EINVAL for the
;; non-threadpool kinds, and refusing in Scheme names the mistake as
;; static, not racy. The record is constructed bare (ptr never
;; dereferenced), as in the uv-dns-request? row above.
(define (cancel-rejection thunk)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e)
                   (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (thunk)
    'no-raise))

(test-equal "uv-cancel! refuses a non-record"
  '(uv-cancel! not-a-cancellable-request)
  (cancel-rejection (lambda () (uv-cancel! "127.0.0.1"))))

(test-equal "uv-cancel! refuses a write request record, by kind"
  '(uv-cancel! not-a-cancellable-request)
  (cancel-rejection
   (lambda () (uv-cancel! (%make-uv-req-record 1 'write #f #f)))))

;; --- the tolerant tail-cancel -------------------------------------------
;; The measured regime exactly: pool pinned to 1 (prologue), four numeric
;; blockers occupying the single worker's queue, a tail behind them,
;; uv-cancel! on the tail in the SAME turn -- no loop step between submit
;; and cancel. The cancelled branch was measured at 1000/1000 twice here,
;; but the race is real, so the outcome is asserted BOOLEAN and each
;; branch carries its PAIRED consequence -- never the boolean alone.
(define tc-blocker-fires (make-vector 4 0))
(define tc-tail-fires 0)
(define tc-tail-err 'callback-never-fired)
(define tc-tail-results 'callback-never-fired)

(test-equal "tolerant cancel: the four blockers start"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (let submit ((i 0))
      (when (< i 4)
        (let ((idx i))
          (uv-getaddrinfo! l "127.0.0.1" "80"
                           (suite-hints #t '(family . inet) '(socktype . stream))
                           (lambda (err results)
                             (collect)
                             (vector-set! tc-blocker-fires idx
                                          (+ 1 (vector-ref tc-blocker-fires idx))))))
        (submit (+ i 1))))
    'started))

;; The tail the start answers, once it has started.
(define tc-tail-req 'never-started)

(test-equal "tolerant cancel: the tail starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (set! tc-tail-req
          (uv-getaddrinfo! l "127.0.0.1" "80"
                           (suite-hints #t '(family . inet) '(socktype . stream))
                           (lambda (err results)
                             (collect)
                             (set! tc-tail-fires (+ tc-tail-fires 1))
                             (set! tc-tail-err (err->symbol err))
                             (set! tc-tail-results results))))
    'started))

;; SAME TURN: nothing has stepped the loop since the five submits. A cancel
;; that raises, of a tail that never started too, is the outcome the next
;; row reports.
(define tc-outcome
  (guard (e (#t (list 'raised (describe e))))
    (uv-cancel! tc-tail-req)))

(test-equal "tolerant cancel: the outcome is a boolean"
  'boolean-outcome
  (if (boolean? tc-outcome) 'boolean-outcome (list 'not-boolean tc-outcome)))

(run-until/ticking l
                   (lambda ()
                     (and (>= tc-tail-fires 1)
                          (>= (vector-ref tc-blocker-fires 0) 1)
                          (>= (vector-ref tc-blocker-fires 1) 1)
                          (>= (vector-ref tc-blocker-fires 2) 1)
                          (>= (vector-ref tc-blocker-fires 3) 1)))
                   cap)

;; BRANCH-INVARIANT: holds whichever way the race went.
(test-equal "tolerant cancel: every one of the five callbacks fired EXACTLY once"
  '(1 1 1 1 1)
  (list (vector-ref tc-blocker-fires 0) (vector-ref tc-blocker-fires 1)
        (vector-ref tc-blocker-fires 2) (vector-ref tc-blocker-fires 3)
        tc-tail-fires))

(test-equal "tolerant cancel: the branch taken carries its paired consequence"
  'branch-consistent
  (cond ((eq? tc-outcome #t)
         ;; Cancel won while queued. libuv REWRITES UV_ECANCELED to
         ;; UV_EAI_CANCELED before the callback (getaddrinfo.c:128-133) --
         ;; one spelling, never 'ECANCELED -- and results are '(), never #f.
         (if (and (eq? tc-tail-err 'EAI_CANCELED) (null? tc-tail-results))
             'branch-consistent
             (list 'cancel-won-but tc-tail-err tc-tail-results)))
        ((eq? tc-outcome #f)
         ;; Too late: the real result was delivered.
         (if (and (eq? tc-tail-err 'no-error) (pair? tc-tail-results))
             'branch-consistent
             (list 'cancel-lost-but tc-tail-err tc-tail-results)))
        (else (list 'not-a-boolean tc-outcome))))

(test-equal "tolerant cancel: counters and registry are back to baseline"
  (list 0 0 (+ registry-with-loop 1))   ; loop + probe-timer
  (list (live-count 'getaddrinfo-req) (live-count 'getnameinfo-req)
        (registry-count)))

;; --- the pool hold -------------------------------------------------------
;; Two rows below need a lookup still QUEUED when a cancel looks at it: the
;; double-cancel's and the teardown sweep's. Without a hold that is a bet.
;; A numeric lookup takes the worker microseconds, so a row would retry
;; until a draw found its request still queued, and a draw loses about 1%
;; of the time. Retried up to 16 times, the teardown row has still lost
;; every draw on CI, a failure that looked exactly like the defect that
;; row exists to catch.
;;
;; A hold makes the queued state certain. A hold is a dev-shim work item
;; (src/libuv-shim.c) that keeps the worker running it until the row
;; releases it. A row queues one and waits until the pool's only worker
;; (pinned above) is inside it, before it queues any lookup: from then on
;; no lookup can start until the release. The double-cancel row releases
;; it once both its cancels have answered. The teardown row cannot, since
;; its sweep and drain are one call, so its lookups' callbacks release it:
;; a cancelled lookup's callback runs while the worker is still held, and
;; no uncancelled one can run before the release.
;;
;; The hold's bound is a backstop, not a verdict. A wait on another thread
;; needs a bound of its own, or a broken build hangs where it should fail a
;; row. A build whose sweep cancels nothing
;; runs no callback to release the teardown row's hold, so its rows fail by
;; name, the hold 'timed-out, instead of hanging the suite.

;; The hold's entries, resolved only when the shim has them. A dev shim has
;; all seven, and a release shim none (tests/check-prod.sps). Against a
;; shim without one, the row just below fails by name, and so does every
;; row that holds the pool, instead of the suite stopping here with no
;; summary: a raise between rows would destroy the evidence.
(define pool-hold-missing '())

(define-syntax hold-entry
  (syntax-rules ()
    ((_ name (arg ...) result)
     (if (foreign-entry? name)
         (foreign-procedure name (arg ...) result)
         (begin
           (set! pool-hold-missing (cons name pool-hold-missing))
           (lambda args (error 'pool-hold "the shim has no entry" name)))))))

(define pool-hold-size
  (hold-entry "chez_uv_debug_pool_hold_size" () size_t))
(define pool-hold-queue
  (hold-entry "chez_uv_debug_pool_hold" (uptr uptr unsigned-64) int))
(define pool-hold-started
  (hold-entry "chez_uv_debug_pool_hold_started" (uptr unsigned-64) int))
(define pool-hold-release
  (hold-entry "chez_uv_debug_pool_release" (uptr) void))
(define pool-hold-state
  (hold-entry "chez_uv_debug_pool_hold_state" (uptr) int))
(define pool-hold-finished
  (hold-entry "chez_uv_debug_pool_hold_finished" (uptr) int))
(define pool-hold-dispose
  (hold-entry "chez_uv_debug_pool_hold_dispose" (uptr) void))

(test-equal "pool hold: the shim exports every entry of the hold"
  '()
  (reverse pool-hold-missing))

(define pool-hold-bound-ns (* 10 1000 1000 1000))

;; hold-state : integer -> symbol
;; The shim's CHEZ_UV_HOLD_* numbers. The seeded rows below hold this
;; reading to what the shim means by each.
(define (hold-state n)
  (case n
    ((1) 'queued)
    ((2) 'waiting)
    ((3) 'released)
    ((4) 'timed-out)
    (else (list 'state n))))

;; A hold: its block, until it is freed, and #f from then on, so that a
;; release after the free is ignored rather than handed freed memory.
(define-record-type pool-hold (fields (mutable block)))

;; pool-hold! : uv-loop exact-nonnegative-integer -> (values pool-hold symbol)
;; A hold queued on LOOP, from LOOP's thread, with a bound of BOUND-NS, and
;; its state once a worker took it: 'waiting, or whatever it was when the
;; wait for a worker gave up. Raises, before queueing anything, when the
;; shim lacks an entry or libuv refuses the hold.
(define (pool-hold! loop bound-ns)
  (unless (null? pool-hold-missing)
    (error 'pool-hold! "the shim has no pool hold" pool-hold-missing))
  (let* ((block (alloc-zeroed (pool-hold-size)))
         (rc (pool-hold-queue (loop-ptr loop) block bound-ns)))
    (unless (zero? rc)
      (free! block)
      (error 'pool-hold! "libuv refused the hold" rc))
    (values (make-pool-hold block)
            (hold-state (pool-hold-started block pool-hold-bound-ns)))))

;; release-hold! : pool-hold -> (or 'released 'ignored)
(define (release-hold! hold)
  (let ((block (pool-hold-block hold)))
    (cond (block (pool-hold-release block) 'released)
          (else 'ignored))))

;; hold-finished? : pool-hold -> boolean
;; Whether the hold's after-work callback has run on its loop: from then on
;; nothing in libuv touches the block. A freed hold had.
(define (hold-finished? hold)
  (let ((block (pool-hold-block hold)))
    (or (not block) (= 1 (pool-hold-finished block)))))

;; hold-outcome : pool-hold -> (or (list symbol symbol) 'freed)
;; How the hold ended, and whether it has finished.
(define (hold-outcome hold)
  (let ((block (pool-hold-block hold)))
    (if block
        (list (hold-state (pool-hold-state block))
              (if (= 1 (pool-hold-finished block)) 'finished 'unfinished))
        'freed)))

;; free-hold! : pool-hold -> (or 'freed 'kept)
;; Frees a finished hold and forgets its block. One the worker or the loop
;; may still touch is kept: a leak on a failing run, never a use after
;; free.
(define (free-hold! hold)
  (let ((block (pool-hold-block hold)))
    (cond ((not block) 'freed)
          ((= 1 (pool-hold-finished block))
           (pool-hold-dispose block)
           (free! block)
           (pool-hold-block-set! hold #f)
           'freed)
          (else 'kept))))

;; settle-hold! : uv-loop pool-hold -> unspecified
;; Releases HOLD, when nothing has, and steps LOOP until the hold has
;; finished and no lookup is live, so that a row leaves nothing queued for
;; a later one. Its cap outlasts the hold's bound, so even a hold that
;; ignores its release ends before a later row runs. Total, since it also
;; runs in a guard's handler, where a raise would end the suite.
(define settle-cap (+ 2048 (div pool-hold-bound-ns (* 1000 1000))))

(define (settle-hold! loop hold)
  (guard (e (#t #f))
    (release-hold! hold)
    (run-until/ticking loop
                       (lambda () (and (hold-finished? hold)
                                       (zero? (live-count 'getaddrinfo-req))
                                       (zero? (live-count 'getnameinfo-req))))
                       settle-cap)))

;; The hold on seeded cases, before the rows below rely on it. Its states
;; cross as numbers, which hold-state must read as the shim means them: a
;; hold left unreleased past its bound has to read 'timed-out, and one
;; released while its worker waits 'released. And a free must keep a hold
;; its worker is still in, and a release after the free must not reach C.
(define (seed-timed-out-hold)
  (guard (e (#t (list 'raised (describe e))))
    (let-values (((hold started) (pool-hold! l (* 1000 1000))))
      (run-until/ticking l (lambda () (hold-finished? hold)) settle-cap)
      (let ((outcome (hold-outcome hold)))
        (free-hold! hold)
        outcome))))

(test-equal "pool hold: a hold left unreleased past its bound reads timed-out, and finishes"
  '(timed-out finished)
  (seed-timed-out-hold))

(define (seed-hold-lifecycle)
  (guard (e (#t (list 'raised (describe e))))
    (let-values (((hold started) (pool-hold! l pool-hold-bound-ns)))
      (let* ((early-free (free-hold! hold))
             (released (release-hold! hold)))
        (run-until/ticking l (lambda () (hold-finished? hold)) settle-cap)
        (let* ((outcome (hold-outcome hold))
               (freed (free-hold! hold))
               (late-release (release-hold! hold)))
          (list started early-free released outcome freed late-release))))))

(test-equal "pool hold: a free keeps a hold its worker waits in, a release ends it as released, and a release after its free is ignored"
  '(waiting kept released (released finished) freed ignored)
  (seed-hold-lifecycle))

;; --- double-cancel before the drain -------------------------------------
;; The target is a getnameinfo request, covering the second kind's cancel
;; path and its 'EAI_CANCELED delivery (host and service #f through the
;; NULL->#f rule). Both cancels land in the same turn, before any drain:
;; the vendor unlinks and re-inserts the same queue node, rc 0 twice
;; (vendor/libuv/src/threadpool.c:399-441) -- #t twice, documented not
;; defended, and the callback still fires EXACTLY once.
;;
;; Four numeric lookups and the request wait behind a pool hold (above),
;; so both cancels find the request queued, behind the lookups. The hold is
;; released only once both have answered. The lookups then run for real,
;; after the cancelled delivery, each callback collecting. Without the
;; hold, the lookups alone would keep the request queued only by a race.
(define (double-cancel-attempt!)
  (let-values (((hold started) (pool-hold! l pool-hold-bound-ns)))
    (let ((lookup-fires (make-vector 4 0))
          (lookup-errs (make-vector 4 'callback-never-fired))
          (tail-fires 0)
          (tail-err 'callback-never-fired)
          (tail-host 'callback-never-fired)
          (tail-serv 'callback-never-fired))
      ;; A raise after the hold is queued releases it, and lets anything
      ;; already queued drain, before it goes on to be recorded below.
      (guard (e (#t (settle-hold! l hold)
                    (free-hold! hold)
                    (raise e)))
        (let submit ((i 0))
          (when (< i 4)
            (let ((idx i))
              (uv-getaddrinfo! l "127.0.0.1" "80"
                               (suite-hints #t '(family . inet) '(socktype . stream))
                               (lambda (err results)
                                 (collect)
                                 (vector-set! lookup-fires idx
                                              (+ 1 (vector-ref lookup-fires idx)))
                                 (vector-set! lookup-errs idx (err->symbol err)))))
            (submit (+ i 1))))
        (let* ((req (uv-getnameinfo!
                     l "127.0.0.1" 8080 '(numeric-host numeric-serv)
                     (lambda (err host service)
                       (collect)
                       (set! tail-fires (+ tail-fires 1))
                       (set! tail-err (err->symbol err))
                       (set! tail-host (if host (list 'host host) 'host-absent))
                       (set! tail-serv (if service
                                           (list 'service service)
                                           'service-absent)))))
               ;; SAME TURN: no loop step since the submit.
               (first (uv-cancel! req))
               (second (if (eq? first #t)
                           (uv-cancel! req)
                           'not-attempted)))
          (settle-hold! l hold)
          (let* ((outcome (hold-outcome hold))
                 (freed (free-hold! hold)))
            (list (cons 'hold (append (list started) outcome (list freed)))
                  (cons 'first first)
                  (cons 'second second)
                  (cons 'delivery (list tail-fires tail-err tail-host tail-serv))
                  (cons 'lookups (list (vector->list lookup-fires)
                                       (vector->list lookup-errs)))
                  (cons 'balance (list (live-count 'getaddrinfo-req)
                                       (live-count 'getnameinfo-req)
                                       (registry-count))))))))))

;; An attempt that raised is kept as ((raised description)), and each row
;; below then shows that instead of its own value.
(define dc-obs
  (guard (e (#t (list (list 'raised (describe e)))))
    (double-cancel-attempt!)))

(define (dc-read key)
  (cond ((assq 'raised dc-obs) => (lambda (r) r))
        (else (cdr (assq key dc-obs)))))

(test-equal "double-cancel: the attempt did not raise"
  'no-raise
  (if (assq 'raised dc-obs) dc-obs 'no-raise))

(test-equal "double-cancel: the worker was inside the hold before the request was queued, stayed until the release, and the hold was freed"
  '(waiting released finished freed)
  (dc-read 'hold))

(test-equal "double-cancel: a same-turn first cancel of a queued request answers #t"
  #t
  (dc-read 'first))

(test-equal "double-cancel: the second cancel on the same queued node also answers #t"
  'second-cancel-true
  (let ((second (dc-read 'second)))
    (case second
      ((#t) 'second-cancel-true)
      ((#f) 'second-cancel-false)
      (else (list 'second-was second)))))

(test-equal "double-cancel: the callback fired exactly once, cancelled, host and service #f"
  '(1 EAI_CANCELED host-absent service-absent)
  (dc-read 'delivery))

(test-equal "double-cancel: the four lookups queued ahead of it ran for real once the hold was released, once each"
  '((1 1 1 1) (no-error no-error no-error no-error))
  (dc-read 'lookups))

(test-equal "double-cancel: no lookup or registry entry outlived the drain"
  (list 0 0 (+ registry-with-loop 1))   ; loop + probe-timer
  (dc-read 'balance))

;; --- boundary: uv-getnameinfo! validation, before the first allocation ---
;; The TCP address vocabulary on the way in, each refusal before anything
;; is allocated, registered, or counted -- asserted by the balance row
;; after the block.
(define (getnameinfo-rejection thunk)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e)
                   (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (thunk)
    'no-raise))

(test-equal "boundary: a non-loop first argument is refused"
  '(uv-getnameinfo! not-a-uv-loop)
  (getnameinfo-rejection
   (lambda () (uv-getnameinfo! 'not-a-loop "127.0.0.1" 8080 '(numeric-host)
                               (lambda (err host service) #f)))))

(test-equal "boundary: a non-string address is refused"
  '(uv-getnameinfo! address-not-a-string)
  (getnameinfo-rejection
   (lambda () (uv-getnameinfo! l 2130706433 8080 '(numeric-host)
                               (lambda (err host service) #f)))))

(test-equal "boundary: an out-of-range port is refused"
  '(uv-getnameinfo! port-out-of-range)
  (getnameinfo-rejection
   (lambda () (uv-getnameinfo! l "127.0.0.1" 65536 '(numeric-host)
                               (lambda (err host service) #f)))))

(test-equal "boundary: a flag outside the closed nameinfo set is refused"
  '(uv-getnameinfo! unknown-nameinfo-flag)
  (getnameinfo-rejection
   (lambda () (uv-getnameinfo! l "127.0.0.1" 8080 '(numeric-host addrconfig)
                               (lambda (err host service) #f)))))

(test-equal "boundary: a non-list flags argument is refused"
  '(uv-getnameinfo! nameinfo-flags-not-a-list)
  (getnameinfo-rejection
   (lambda () (uv-getnameinfo! l "127.0.0.1" 8080 'numeric-host
                               (lambda (err host service) #f)))))

(test-equal "boundary: a non-procedure on-complete is refused"
  '(uv-getnameinfo! on-complete-not-a-procedure)
  (getnameinfo-rejection
   (lambda () (uv-getnameinfo! l "127.0.0.1" 8080 '(numeric-host)
                               'not-a-procedure))))

;; The PRE-REGISTRATION guard:
;; "not-an-ip" passes validate-address (it IS a string, with no NUL) and fails
;; inside fill-sockaddr! AFTER the block is allocated, BEFORE anything is
;; registered or counted -- the guard's undo is exactly one free. Driven
;; through the THREE-argument arity, so the flags-omitted => '() spelling
;; reaches the native boundary logic without any resolver consultation.
(test-equal "boundary: a garbage address fails in fill-sockaddr!, through the 3-arity"
  '(uv-getnameinfo! bad-address)
  (getnameinfo-rejection
   (lambda () (uv-getnameinfo! l "not-an-ip" 8080
                               (lambda (err host service) #f)))))

(test-equal "boundary: every rejection above allocated and registered nothing"
  (list 0 (+ registry-with-loop 1))   ; loop + probe-timer
  (list (live-count 'getnameinfo-req) (registry-count)))

;; --- the getnameinfo dispatcher's step-1 arms, driven directly ----------
;; Same seam technique as the getaddrinfo arms above. The ORPHAN arm is
;; driven with NULL hostname/service: for a pointer this binding has
;; forgotten there is nothing to copy and nothing to free -- the strings
;; would point INTO the unknown block anyway (unix.h:353-354).
(define ni-orphan-probe-ptr 123456789)

((dispatcher-ref 'getnameinfo) ni-orphan-probe-ptr 0 0 0)

(test-equal "getnameinfo orphan arm: the event is recorded with the dispatcher's name and pointer"
  (list 'getnameinfo ni-orphan-probe-ptr)
  (let ((events (orphan-callback-events)))
    (if (= (length events) (+ orphans-at-start 2))
        (let ((last (car (reverse events))))
          (list (car last) (cdr last)))
        (list 'orphan-count (length events)))))

;; The KIND-MISMATCH arm: probe-timer stands in for the cross-paired-
;; trampoline bug state again. The dispatcher must raise BEFORE touching
;; hostname/service (their provenance is unknown in that bug state); the
;; seam contains the raise and uv-run re-raises it by name.
((dispatcher-ref 'getnameinfo) (handle-ptr probe-timer) 0 0 0)

(test-equal "getnameinfo kind-mismatch arm: contained, and re-raised from uv-run by name"
  '(callback-error uv-getnameinfo-dispatch)
  (guard (e ((uv-callback-error? e) (list 'callback-error (condition-who e)))
            (#t (list 'wrong-condition e)))
    (uv-run l 'nowait)
    'no-raise))

(test-equal "getnameinfo kind-mismatch arm: the wrong-kind registry entry is untouched"
  'still-registered
  (if (eq? probe-timer (registry-ref (handle-ptr probe-timer)))
      'still-registered
      'entry-disturbed))

;; A request of the OTHER DNS kind is a request too, so only the kind
;; comparison tells the seam to leave it. Each DNS seam takes its pointer's
;; entry in the step that finds it, and puts back one its dispatcher
;; refuses: this is the case where a seam that asked only uv-req? would keep
;; the entry its dispatcher raised over.
(define (other-kind-dns-run slot-name registered-kind req-kind call)
  (set! other-kind-completed 'not-completed)
  (let* ((block (alloc-zeroed 64))
         (req (%make-uv-req-record block req-kind #f
                                   (lambda args (set! other-kind-completed 'completed))
                                   l)))
    (registry-register! block registered-kind l req)
    (call (dispatcher-ref slot-name) block)
    (let* ((raised (guard (e ((uv-callback-error? e) (condition-who e))
                             (#t (list 'wrong-condition e)))
                     (uv-run l 'nowait)
                     'no-raise))
           (entry (if (eq? req (registry-ref block)) 'still-registered 'entry-disturbed)))
      (when (eq? entry 'still-registered) (registry-deregister! block))
      ;; A dispatcher that completed the request freed its block and zeroed
      ;; its pointer.
      (unless (eqv? (req-ptr req) 0) (free! block))
      (list raised entry other-kind-completed))))

(define other-kind-completed 'not-completed)

(test-equal "a getnameinfo request at the getaddrinfo seam: raised by name, entry kept, nothing completed"
  '(uv-getaddrinfo-dispatch still-registered not-completed)
  (other-kind-dns-run 'getaddrinfo 'getnameinfo-req 'getnameinfo
                      (lambda (slot block) (slot block 0 0))))

(test-equal "a getaddrinfo request at the getnameinfo seam: raised by name, entry kept, nothing completed"
  '(uv-getnameinfo-dispatch still-registered not-completed)
  (other-kind-dns-run 'getnameinfo 'getaddrinfo-req 'getaddrinfo
                      (lambda (slot block) (slot block 0 0 0))))

;; THE REQUEST-SEAM MATRIX. Each request seam takes its entry by the test
;; its dispatcher makes before completing (handles.sls's seam forms), and
;; nothing makes the two agree but this: whatever the predicates, a seam
;; must keep exactly the entries its dispatcher leaves, and take exactly
;; those whose block it frees. A seam that took an entry its dispatcher
;; then left would lose it; one that kept an entry whose block its
;; dispatcher freed would leave the registry naming freed memory. So a
;; request of every kind goes to every request seam, and each cell reports
;; whether the entry stayed and whether the request completed (its pointer
;; zeroed and its block freed). Requests only: an object that is not one
;; records an orphan at three of these seams, which this suite's epilogue
;; counts, and tests/test-tcp.sps puts a handle to them instead.
;;
;; seam-cell : symbol (-> any) (-> any) symbol procedure -> (list symbol symbol symbol symbol)
;; COUNT-NEW! and COUNT-FREE! are the seam's own counter, which a completion
;; there moves down; the cell moves it up first and back if nothing completed.
(define (seam-cell seam count-new! count-free! req-kind deliver)
  (let* ((block (alloc-zeroed 64))
         (completed 'not-completed)
         (req (%make-uv-req-record block req-kind #f
                                   (lambda args (set! completed 'completed))
                                   l)))
    (registry-register! block 'getaddrinfo-req l req)
    (count-new!)
    (deliver (dispatcher-ref seam) block)
    (guard (e (#t 'cleared)) (uv-run l 'nowait))
    (let* ((freed (if (eqv? (req-ptr req) 0) 'freed 'not-freed))
           (entry (if (eq? req (registry-ref block)) 'kept 'taken)))
      (when (eq? entry 'kept) (registry-deregister! block))
      (when (eq? freed 'not-freed) (count-free!) (free! block))
      (list seam req-kind entry completed freed))))

(define matrix-seams
  (list (list 'write-done count-write-req-new! count-write-req-free!
              (lambda (slot block) (slot block 0)))
        (list 'shutdown (lambda () #f) (lambda () #f) (lambda (slot block) (slot block 0)))
        (list 'connect count-connect-req-new! count-connect-req-free!
              (lambda (slot block) (slot block 0)))
        (list 'getaddrinfo count-getaddrinfo-req-new! count-getaddrinfo-req-free!
              (lambda (slot block) (slot block 0 0)))
        (list 'getnameinfo count-getnameinfo-req-new! count-getnameinfo-req-free!
              (lambda (slot block) (slot block 0 0 0)))))

(define matrix-kinds '(write shutdown connect getaddrinfo getnameinfo))

(define matrix
  (apply append
         (map (lambda (s)
                (map (lambda (kind)
                       (seam-cell (car s) (cadr s) (caddr s) kind (cadddr s)))
                     matrix-kinds))
              matrix-seams)))

(test-equal "every request seam keeps exactly the entries its dispatcher leaves, and takes exactly those it completes"
  '()
  (filter (lambda (cell)
            (not (member (cddr cell)
                         '((kept not-completed not-freed) (taken completed freed)))))
          matrix))

;; The outcomes themselves: the stream and connect dispatchers complete a
;; request of any kind, and each DNS dispatcher only its own kind.
(test-equal "the request seams complete any request, and the DNS seams only their own kind"
  '((write-done taken taken taken taken taken)
    (shutdown taken taken taken taken taken)
    (connect taken taken taken taken taken)
    (getaddrinfo kept kept kept taken kept)
    (getnameinfo kept kept kept kept taken))
  (map (lambda (s)
         (cons (car s)
               (map (lambda (cell) (caddr cell))
                    (filter (lambda (cell) (eq? (car cell) (car s))) matrix))))
       matrix-seams))

;; --- pool-pinned queued-tail teardown -----------------------------------
;; A second loop: a pool hold (above), four numeric lookups and a
;; getnameinfo tail queued behind it, then uv-loop-teardown! in the SAME
;; turn. The cancel sweep, in the teardown's first step, finds all five
;; still queued and cancels them, and each drains as 'EAI_CANCELED before
;; teardown returns (teardown's contract: every in-flight on-complete runs
;; before teardown returns). The first of their callbacks releases the
;; hold, which the drain also waits for.
;;
;; THE CANCELLED-TAIL ROW IS THE NAMED CATCHER for a kind-narrowed sweep:
;; a sweep that misses getnameinfo-req never cancels the tail, which then
;; runs for real once a cancelled lookup's callback releases the hold, and
;; the row fails by name. A sweep that misses getaddrinfo-req fails the
;; blockers' row the same way.
;;
;; Behind the four lookups and no hold, the tail would stay queued only by
;; a race that loses about 1% of draws, and 16 retries have all lost on CI.
(define td-registry-before (registry-count))

(define (teardown-attempt!)
  (let ((l2 (make-uv-loop))
        (hold #f)
        (started 'never-queued)
        (blocker-fires (make-vector 4 0))
        (blocker-errs (make-vector 4 'callback-never-fired))
        (tail-fires 0)
        (tail-err 'callback-never-fired)
        (tail-host 'callback-never-fired)
        (tail-serv 'callback-never-fired))
    ;; A raise while queueing leaves l2 open with what was already queued.
    ;; The hold is released and l2 torn down before the raise goes on to be
    ;; recorded below.
    (guard (e (#t (when hold (release-hold! hold))
                  (guard (x (#t #f))
                    (when (uv-loop-open? l2) (uv-loop-teardown! l2)))
                  (when hold (free-hold! hold))
                  (raise e)))
      (let-values (((h s) (pool-hold! l2 pool-hold-bound-ns)))
        (set! hold h)
        (set! started s))
      (let submit ((i 0))
        (when (< i 4)
          (let ((idx i))
            (uv-getaddrinfo! l2 "127.0.0.1" "80"
                             (suite-hints #t '(family . inet)
                                          '(socktype . stream))
                             (lambda (err results)
                               (release-hold! hold)
                               (collect)
                               (vector-set! blocker-fires idx
                                            (+ 1 (vector-ref blocker-fires idx)))
                               (vector-set! blocker-errs idx
                                            (err->symbol err)))))
          (submit (+ i 1))))
      (uv-getnameinfo! l2 "127.0.0.1" 8080 '(numeric-host numeric-serv)
                       (lambda (err host service)
                         (release-hold! hold)
                         (collect)
                         (set! tail-fires (+ tail-fires 1))
                         (set! tail-err (err->symbol err))
                         (set! tail-host (if host (list 'host host) 'host-absent))
                         (set! tail-serv (if service
                                             (list 'service service)
                                             'service-absent)))))
    ;; Teardown IMMEDIATELY: no loop step between the submits and the sweep.
    ;; A teardown that raises frees the hold too, when it has finished,
    ;; before the raise goes on to be recorded below.
    (guard (e (#t (free-hold! hold) (raise e)))
      (uv-loop-teardown! l2))
    (let* ((outcome (hold-outcome hold))
           (freed (free-hold! hold)))
      (list (cons 'hold (append (list started) outcome (list freed)))
            (cons 'end-state
                  (list (if (uv-loop-open? l2) 'still-open 'closed)
                        (list (vector-ref blocker-fires 0)
                              (vector-ref blocker-fires 1)
                              (vector-ref blocker-fires 2)
                              (vector-ref blocker-fires 3)
                              tail-fires)
                        (list (live-count 'getaddrinfo-req)
                              (live-count 'getnameinfo-req)
                              (registry-count))))
            (cons 'blocker-errs (vector->list blocker-errs))
            (cons 'tail-err tail-err)
            (cons 'tail-delivery (list tail-err tail-host tail-serv))))))

;; An attempt that raised is kept as ((raised description)), as above.
(define td-obs
  (guard (e (#t (list (list 'raised (describe e)))))
    (teardown-attempt!)))

(define (td-read key)
  (cond ((assq 'raised td-obs) => (lambda (r) r))
        (else (cdr (assq key td-obs)))))

(test-equal "queued-tail teardown: the attempt did not raise"
  'no-raise
  (if (assq 'raised td-obs) td-obs 'no-raise))

;; Only a lookup's callback releases the hold on this path, so 'released
;; here means one ran while the worker was held.
(test-equal "queued-tail teardown: the worker was inside the hold before the lookups were queued, stayed until a lookup's callback released it, and the hold was freed"
  '(waiting released finished freed)
  (td-read 'hold))

(test-equal "queued-tail teardown: teardown closed the loop, fired all five callbacks exactly once, and balanced"
  (list 'closed '(1 1 1 1 1) (list 0 0 td-registry-before))
  (td-read 'end-state))

(test-equal "queued-tail teardown: the sweep cancelled every queued getaddrinfo request"
  '(EAI_CANCELED EAI_CANCELED EAI_CANCELED EAI_CANCELED)
  (td-read 'blocker-errs))

(test-equal "queued-tail teardown: the sweep cancelled the queued tail"
  'EAI_CANCELED
  (td-read 'tail-err))

(test-equal "queued-tail teardown: the cancelled tail delivered EAI_CANCELED with host and service #f"
  '(EAI_CANCELED host-absent service-absent)
  (td-read 'tail-delivery))

;; --- uv-loop-close! with an in-flight request => 'EBUSY -----------------
;; libuv's own guard is the check (vendor/libuv/src/uv-common.c:885): an
;; active request keeps the loop alive, so uv_loop_close answers EBUSY --
;; surfacing as the SYMBOL through &uv-errno-error -- with the
;; loop untouched and usable. Deterministic without a step: whatever the
;; worker has done meanwhile, the req stays active until its completion
;; callback runs inside uv-run, which has not happened yet.
(define l3 (make-uv-loop))
(define eb-err 'callback-never-fired)
(define eb-host 'callback-never-fired)

(test-equal "close with in-flight request: the lookup starts"
  'started
  (guard (e (#t (list 'raised (describe e))))
    (uv-getnameinfo! l3 "127.0.0.1" 8080 '(numeric-host numeric-serv)
                     (lambda (err host service)
                       (collect)
                       (set! eb-err (err->symbol err))
                       (set! eb-host host)))
    'started))

(test-equal "close with in-flight request: EBUSY, as a symbol"
  'EBUSY
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e))
            (#t (list 'wrong-condition e)))
    (uv-loop-close! l3)
    'no-raise))

(test-equal "close with in-flight request: the loop is untouched and still open"
  'still-open (if (uv-loop-open? l3) 'still-open 'closed))

;; ... and still USABLE: the same loop drains the request normally. With no
;; request in flight, the close above succeeded, and a closed loop takes no
;; wait.
(when (uv-loop-open? l3)
  (run-until/ticking l3 (lambda () (not (eq? eb-err 'callback-never-fired))) cap))

(test-equal "close with in-flight request: the drained lookup delivered normally"
  '(no-error "127.0.0.1") (list eb-err eb-host))

;; A loop the EBUSY row already closed had nothing to drain, so this close
;; proves nothing about one: closing a closed loop answers the same.
(test-equal "close with in-flight request: the loop closes cleanly after the drain"
  'closed-clean
  (if (uv-loop-open? l3)
      (begin (uv-loop-close! l3)
             (if (uv-loop-open? l3) 'still-open 'closed-clean))
      'closed-before-any-drain))

;; --- balance epilogue ----------------------------------------------------
(uv-close! probe-timer)
(run-until l (lambda () (eq? (uv-handle-state probe-timer) 'closed)) 8)

(test-equal "epilogue: no getaddrinfo request is live"
  0 (live-count 'getaddrinfo-req))

(test-equal "epilogue: no getnameinfo request is live"
  0 (live-count 'getnameinfo-req))

(test-equal "epilogue: the registry is back to its with-loop baseline"
  registry-with-loop (registry-count))

(test-equal "epilogue: exactly the two deliberate orphan events, no strays"
  (+ orphans-at-start 2) (length (orphan-callback-events)))

(uv-loop-teardown! l)

(test-equal "epilogue: teardown leaves no loop live"
  0 (live-count 'loop))

(test-equal "epilogue: the registry is empty again"
  registry-count-at-start (registry-count))

(test-end "dns")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
