#!r6rs
;;; SRFI-64 suite for (libuv dns) -- the getaddrinfo half (design spec v0.2
;;; S4.1-S4.4, S5.4, S5.5, S9). getnameinfo, uv-cancel!, and the teardown
;;; rows are Stage 5's.
;;;
;;; HERMETIC BY POLICY (ADR-0013): every lookup below is numeric --
;;; AI_NUMERICHOST literals, numeric services -- so the resolver's
;;; configuration (/etc/hosts, nsswitch, mDNSResponder) is never consulted
;;; and nothing here can reach a network. "localhost" and named services
;;; are BANNED. The ban is watched at the VALUE level: one suite-local
;;; helper builds every hints alist, and a pure-arithmetic row asserts its
;;; computed ai_flags integer carries the shim's AI_NUMERICHOST bit -- the
;;; resolve-a-.invalid-name watchdog variant is a trap (NXDOMAIN maps to
;;; the same EAI_NONAME on any networked machine; measured, ADR-0013).
;;;
;;; EVERY DNS WAIT GOES THROUGH run-until/ticking (FINDINGS Q1: a pending
;;; getaddrinfo parks a bare 'once in the poll; FINDINGS item 11: the two
;;; legal NOWAIT outcomes after a submit were BOTH observed on CI, so no
;;; row may assert which branch a post-submit step takes). (collect) runs
;;; in every callback; sentinels are values no failure path produces.
;;;
;;; NOT pure: (libuv dns) reaches (libuv private native). Never add this to
;;; the Makefile's PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv timer)
        (libuv dns)
        (libuv private handles)
        (libuv private conditions)
        ;; alloc-zeroed/free!/copy-in!/c-int-set!/fill-sockaddr! build the
        ;; SYNTHETIC chains (S5.4: hand-built nodes, freed with free!,
        ;; never uv_freeaddrinfo -- that call is legal only on
        ;; getaddrinfo-owned chains). dispatcher-ref reaches the installed
        ;; getaddrinfo dispatcher directly, which is the only way the
        ;; orphan and kind-mismatch arms are observable at all: no public
        ;; API can make libuv deliver a completion for an unregistered or
        ;; wrong-kind pointer.
        (only (libuv private native)
              live-counts alloc-zeroed free! copy-in! c-int-set! c-int-ref
              fill-sockaddr! dispatcher-ref align-16 uv-req-size)
        ;; Shim-snapshotted values (ADR-0005), for the ADR-0013 watchdog
        ;; and the synthetic-chain field writes.
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
        (only (chezscheme) collect putenv))

;; PIN THE THREADPOOL TO ONE WORKER, before any native/threadpool touch.
;; libuv reads UV_THREADPOOL_SIZE exactly once, at the first
;; uv__work_submit (vendor/libuv/src/threadpool.c:194-217); Chez's putenv
;; writes the same process environment libuv reads, measured through
;; libuv's own uv_os_getenv (FINDINGS Q1 observation (c)). Stage 5's
;; cancel rows depend on the pinned pool (FINDINGS Q3); pinning from this
;; suite's first line keeps every row in the same measured regime.
(putenv "UV_THREADPOOL_SIZE" "1")

;; SRFI-64's default runner does not set a process exit code (AGENTS.md).
(define runner (test-runner-simple))
(test-runner-current runner)

(define (live-count kind) (cdr (assq kind (live-counts))))

;; #f is the worst possible expected value (AGENTS.md), so every err
;; observation maps to a symbol: 'no-error for success, the errno symbol
;; for an &uv-errno-error, and a tagged list for anything else.
;; 'callback-never-fired is the seed every observer starts at, and no
;; delivery path can produce it.
(define (err->symbol err)
  (cond ((not err) 'no-error)
        ((uv-errno-error? err) (uv-errno-error-errno err))
        (else (list 'unexpected-err-object err))))

(define cap 64)

;; --- THE hints helper (ADR-0013's value-level watchdog target) -----------
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

;; --- the ADR-0013 value-level watchdog -----------------------------------
;; Pure arithmetic over the helper's own output and the shim's snapshot;
;; fails instantly and offline if the helper ever stops carrying the
;; numeric flags. (The constants snapshot exists because make-uv-loop just
;; ran ensure-native-loaded!.)
(test-equal "ADR-0013 watchdog: helper flags carry the AI_NUMERICHOST bit"
  'numeric-host-bit-set
  (let ((n (flags->int (cdr (assq 'flags (suite-hints #t))))))
    (if (= (ai-numerichost) (bitwise-and n (ai-numerichost)))
        'numeric-host-bit-set
        (list 'numeric-host-bit-missing n))))

(test-equal "ADR-0013 watchdog: with a service the helper also carries AI_NUMERICSERV"
  'numeric-serv-bit-set
  (let ((n (flags->int (cdr (assq 'flags (suite-hints #t))))))
    (if (= (ai-numericserv) (bitwise-and n (ai-numericserv)))
        'numeric-serv-bit-set
        (list 'numeric-serv-bit-missing n))))

(test-equal "ADR-0013 watchdog: the no-service spelling still carries AI_NUMERICHOST"
  'numeric-host-bit-set
  (let ((n (flags->int (cdr (assq 'flags (suite-hints #f))))))
    (if (= (ai-numerichost) (bitwise-and n (ai-numerichost)))
        'numeric-host-bit-set
        (list 'numeric-host-bit-missing n))))

;; --- prologue: one throwaway drained lookup pins the pool ----------------
;; The pool is process-global and sized at the FIRST submit, so this
;; lookup is what latches UV_THREADPOOL_SIZE=1 before any dependent row
;; (design spec v0.2 S9; FINDINGS Q3, consequence 6). Asserted rather than
;; fire-and-forgotten: a comment-that-is-a-check.
(define pin-err 'callback-never-fired)

(uv-getaddrinfo! l "127.0.0.1" "80"
                 (suite-hints #t '(family . inet) '(socktype . stream))
                 (lambda (err results)
                   (collect)
                   (set! pin-err (err->symbol err))))

(run-until/ticking l (lambda () (not (eq? pin-err 'callback-never-fired))) cap)

(test-equal "prologue: the pool-pinning throwaway lookup drained clean"
  'no-error pin-err)

;; --- row a: numeric v4, fully pinned hints -------------------------------
;; family/socktype/protocol pinned so every symbol->int write in the hints
;; tail is exercised; the answer is spike-measured identical on both libcs
;; (FINDINGS Q4 f1): one inet/stream/tcp entry, the literal rendered back,
;; the numeric service decoded, no canonname.
(define a-err 'callback-never-fired)
(define a-results 'callback-never-fired)

(uv-getaddrinfo! l "127.0.0.1" "80"
                 (suite-hints #t '(family . inet) '(socktype . stream)
                              '(protocol . tcp))
                 (lambda (err results)
                   (collect)
                   (set! a-err (err->symbol err))
                   (set! a-results results)))

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
;; service #f -> NULL (FINDINGS Q1(b) measured #f->NULL marshalling); with
;; no service there is nothing to put in sin_port, so the port is 0 --
;; pure formatting, no /etc/services.
(define a2-err 'callback-never-fired)
(define a2-results 'callback-never-fired)

(uv-getaddrinfo! l "127.0.0.1" #f
                 (suite-hints #f '(family . inet) '(socktype . stream))
                 (lambda (err results)
                   (collect)
                   (set! a2-err (err->symbol err))
                   (set! a2-results results)))

(run-until/ticking l (lambda () (not (eq? a2-err 'callback-never-fired))) cap)

(test-equal "absent service: lookup succeeds" 'no-error a2-err)

(test-equal "absent service: port decodes as 0"
  '(0) (map uv-addrinfo-port a2-results))

;; --- row b: numeric v6 ---------------------------------------------------
;; The v6 row is the PORTABILITY TRAP's live check (design spec S5.2 / S9):
;; the walk reads sin6_port at the shim's own offset and renders through
;; uv_ip_name, on a family whose struct layout the two libcs disagree
;; about. Family pinned inet6 exercises the AF_INET6 hint write.
(define b-err 'callback-never-fired)
(define b-results 'callback-never-fired)

(uv-getaddrinfo! l "::1" "80"
                 (suite-hints #t '(family . inet6) '(socktype . stream))
                 (lambda (err results)
                   (collect)
                   (set! b-err (err->symbol err))
                   (set! b-results results)))

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

(uv-getaddrinfo! l "::1" "443"
                 (suite-hints #t '(family . inet6) '(socktype . dgram)
                              '(protocol . udp))
                 (lambda (err results)
                   (collect)
                   (set! b2-err (err->symbol err))
                   (set! b2-results results)))

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
;; both shapes measured twice per OS (FINDINGS Q4 f4, consequence 12). A
;; row asserting order or exact count passes on one CI OS and fails on the
;; other by construction.
(define c-err 'callback-never-fired)
(define c-results 'callback-never-fired)

(uv-getaddrinfo! l "127.0.0.1" "80"
                 (suite-hints #t)
                 (lambda (err results)
                   (collect)
                   (set! c-err (err->symbol err))
                   (set! c-results results)))

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
;; family the resolver answers (FINDINGS Q4 f1/f4: all-inet on both libcs).
(define d-err 'callback-never-fired)
(define d-results 'callback-never-fired)

(uv-getaddrinfo! l "127.0.0.1" "80"
                 (suite-hints #t '(family . unspec) '(socktype . stream))
                 (lambda (err results)
                   (collect)
                   (set! d-err (err->symbol err))
                   (set! d-results results)))

(run-until/ticking l (lambda () (not (eq? d-err 'callback-never-fired))) cap)

(test-equal "unspec + v4 literal: lookup succeeds" 'no-error d-err)

(test-equal "unspec + v4 literal: a nonempty all-inet chain"
  'single-family-inet
  (if (and (not (null? d-results))
           (for-all (lambda (r) (eq? 'inet (uv-addrinfo-family r))) d-results))
      'single-family-inet
      (list 'families (map uv-addrinfo-family d-results))))

;; --- row e: non-numeric name under numeric-host => EAI_NONAME ------------
;; The deterministic OFFLINE error path ADR-0013 substitutes for banned
;; resolver lookups: AI_NUMERICHOST makes a non-numeric name fail in pure
;; formatting, asynchronously, with empty results -- '() and never #f
;; (err is the sole discriminant, S4.4).
(define e-err 'callback-never-fired)
(define e-results 'callback-never-fired)

(uv-getaddrinfo! l "chez-libuv-not-numeric.invalid" "80"
                 (suite-hints #t '(socktype . stream))
                 (lambda (err results)
                   (collect)
                   (set! e-err (err->symbol err))
                   (set! e-results results)))

(run-until/ticking l (lambda () (not (eq? e-err 'callback-never-fired))) cap)

(test-equal "numeric-host + non-numeric name: errno is EAI_NONAME, by symbol"
  'EAI_NONAME e-err)

(test-equal "numeric-host + non-numeric name: results are '(), never #f"
  '() e-results)

;; --- row f: every run delivers fresh records (ADR-0009) ------------------
(define f1-results 'callback-never-fired)
(define f2-results 'callback-never-fired)

(uv-getaddrinfo! l "127.0.0.1" "80"
                 (suite-hints #t '(family . inet) '(socktype . stream))
                 (lambda (err results) (collect) (set! f1-results results)))

(run-until/ticking l (lambda () (not (eq? f1-results 'callback-never-fired))) cap)

(uv-getaddrinfo! l "127.0.0.1" "80"
                 (suite-hints #t '(family . inet) '(socktype . stream))
                 (lambda (err results) (collect) (set! f2-results results)))

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
;; The lifetime contract of S4.4: the block is deregistered, freed,
;; counted, and ptr-zeroed all before on-complete runs. Observed from
;; INSIDE the callback, which is the only vantage point that can tell
;; "freed before" from "freed after".
(define g-live-in-callback 'callback-never-fired)
(define g-ptr-in-callback 'callback-never-fired)
(define g-registry-in-callback 'callback-never-fired)
(define g-registry-before-submit (registry-count))

(define g-req
  (uv-getaddrinfo! l "127.0.0.1" "80"
                   (suite-hints #t '(family . inet) '(socktype . stream)
                                '(protocol . tcp))
                   (lambda (err results)
                     (collect)
                     (set! g-live-in-callback (live-count 'getaddrinfo-req))
                     (set! g-ptr-in-callback (req-ptr g-req))
                     (set! g-registry-in-callback (registry-count)))))

;; Between the submit and the first uv-run nothing can deliver (callbacks
;; run only inside uv-run, on the loop thread), so these two mid-flight
;; assertions are race-free -- unlike anything about a post-submit NOWAIT
;; branch, which FINDINGS item 11 bans outright.
(test-equal "in flight: the live counter reads 1 after submit, before stepping"
  1 (live-count 'getaddrinfo-req))

(test-equal "in flight: the request block is registered"
  (+ g-registry-before-submit 1) (registry-count))

(test-equal "in flight: the start call answered an opaque request record"
  'a-req (if (uv-req? g-req) 'a-req 'not-a-req))

;; THE BOUNDARY-WRITE WATCHDOG, closing the loop the helper watchdog above
;; cannot see: dropping a c-int-set! in the start call's hints writing
;; would otherwise leave this suite green on any networked machine (the
;; same NXDOMAIN trap ADR-0013 documents for the flags bit). The
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

;; --- uv-dns-request? (S4.5's kind-based domain predicate) ----------------
(test-equal "uv-dns-request? accepts a getaddrinfo request record"
  'dns-request (if (uv-dns-request? g-req) 'dns-request 'not-dns))

(test-equal "uv-dns-request? refuses a non-record"
  'not-dns (if (uv-dns-request? "127.0.0.1") 'dns-request 'not-dns))

(define probe-timer (make-uv-timer l))

(test-equal "uv-dns-request? refuses a handle record"
  'not-dns (if (uv-dns-request? probe-timer) 'dns-request 'not-dns))

;; The discriminating case for the KIND check: a request record that is
;; not a DNS request. Constructed bare (no registration, no native call)
;; -- the S3 synthetic-completion precedent; the predicate reads only the
;; kind field, so the placeholder ptr is never dereferenced.
(test-equal "uv-dns-request? refuses a non-DNS request record, by kind"
  'not-dns
  (if (uv-dns-request? (%make-uv-req-record 1 'write #f #f))
      'dns-request 'not-dns))

;; --- row h: resubmit from inside the callback, chain of three ------------
;; The FINDINGS Q1 engine shape in miniature: each completion submits the
;; next lookup from inside on-complete, and the completions arrive in
;; submission order.
(define h-order '())

(define (h-submit! n)
  (uv-getaddrinfo! l "127.0.0.1" "80"
                   (suite-hints #t '(family . inet) '(socktype . stream))
                   (lambda (err results)
                     (collect)
                     (set! h-order (cons (list n (err->symbol err)
                                               (length results))
                                         h-order))
                     (when (< n 3) (h-submit! (+ n 1))))))

(h-submit! 1)

(run-until/ticking l (lambda () (= 3 (length h-order))) cap)

(test-equal "a chain of three resubmissions completes in order, each clean"
  '((1 no-error 1) (2 no-error 1) (3 no-error 1))
  (reverse h-order))

;; --- row i: the post-registration sync failure, and its undo -------------
;; An empty hostname reaches libuv (NO Scheme-side empty-string validation,
;; deliberately -- S5.5: adding one would make this guard untestable) and
;; fails DETERMINISTICALLY in uv__idna_toascii with UV_EINVAL, after our
;; register/count, before any possible callback. The abandon-request!
;; guard must undo exactly that much. This row also drives the THREE-
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
;; pointer (S4.2), proven on the same deterministic sync-failure path.
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
;; The raise is caught by dispatch-guarded, recorded against the loop the
;; dispatcher found through registry-loop-of (no handle-loop route exists
;; for a handle-less request -- ADR-0011), and re-raised by uv-run.
(uv-getaddrinfo! l "127.0.0.1" "80"
                 (suite-hints #t '(family . inet) '(socktype . stream))
                 (lambda (err results)
                   (collect)
                   (raise 'dns-on-complete-sentinel-raise)))

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

(uv-getaddrinfo! l "127.0.0.1" "80"
                 (suite-hints #t '(family . inet) '(socktype . stream))
                 (lambda (err results)
                   (collect)
                   (set! j2-err (err->symbol err))))

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

;; Guards the MEASURED prefix-resolution hazard (FINDINGS Q1(b)):
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

;; --- row k: synthetic chains through addrinfo-chain->list ----------------
;; Hand-built struct addrinfo nodes: alloc-zeroed memory, fields written at
;; the SHIM's offsets, freed below with free! -- NEVER uv_freeaddrinfo,
;; which is legal only on getaddrinfo-owned chains (S8 delta). This is the
;; only honest way to drive the skip policy and the NULL-field arms: no
;; hermetic lookup can make the resolver hand back a non-INET entry or a
;; NULL ai_addr.

;; Pointer width derived from the shim's own layout rather than
;; transcribed: ai_addr and ai_canonname are ADJACENT pointer fields on
;; both supported libcs -- in opposite orders (the S5.2 portability trap),
;; which is exactly why the absolute difference of their offsets is
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
    (fill-sockaddr! addr ip port 'test-dns-synthetic)
    addr))

;; k1: the skip policy. A non-INET entry (family AF_UNSPEC -- a value the
;; record has no honest representation for) is SKIPPED, and the walk
;; advances past it to the INET entry behind it. 203.0.113.9 is
;; TEST-NET-3: decode-only, never routed, and no lookup happens anyway.
(define k-sockaddr (make-synthetic-sockaddr "203.0.113.9" 8080))
(define k-canon (make-c-string "synthetic-canon.example"))
(define k-skip-node
  (make-synthetic-node (af-unspec) (sock-stream) 0 0 0))
(define k-inet-node
  (make-synthetic-node (af-inet) (sock-stream) 6151 k-sockaddr k-canon))

(test-equal "synthetic: a non-INET entry is skipped, the entry behind it decoded"
  '((inet "203.0.113.9" 8080))
  (map (lambda (r) (list (uv-addrinfo-family r) (uv-addrinfo-address r)
                         (uv-addrinfo-port r)))
       (addrinfo-chain->list (link-nodes! (list k-skip-node k-inet-node)))))

;; k2: an unmapped protocol passes through as the raw exact int (S4.3:
;; lossless, discriminable with symbol?; deliberately NOT the ADR-0006
;; sentinel-symbol shape). 6151 maps to no IPPROTO this binding knows.
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

;; k4: all entries skipped is a legal '() -- the documented S4.3 corollary
;; (a success whose entries were all skipped, indistinguishable from an
;; empty success).
(define k-lone-skip (make-synthetic-node (af-unspec) (sock-dgram) 0 0 0))

(test-equal "synthetic: an all-skipped chain answers '()"
  '() (addrinfo-chain->list (link-nodes! (list k-lone-skip))))

;; k5: NULL ai_addr on an INET entry. The zero-refusing
;; sockaddr->address-string answers #f WITHOUT calling native (S5.1) --
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
;; dispatcher's uniform conversion correct on every failure status (S5.4:
;; res is NULL on every failure/cancel).
(test-equal "synthetic: a NULL chain head answers '()"
  '() (addrinfo-chain->list 0))

;; Synthetic memory is freed with free!, never uv_freeaddrinfo.
(for-each free! (list k-skip-node k-inet-node k-lone-skip k-null-addr-node
                      k-sockaddr k-canon))

;; --- the dispatcher's step-1 arms, driven directly (S5.4) ----------------
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

;; --- balance epilogue ----------------------------------------------------
(uv-close! probe-timer)
(run-until l (lambda () (eq? (uv-handle-state probe-timer) 'closed)) 8)

(test-equal "epilogue: no getaddrinfo request is live"
  0 (live-count 'getaddrinfo-req))

(test-equal "epilogue: the registry is back to its with-loop baseline"
  registry-with-loop (registry-count))

(test-equal "epilogue: exactly the one deliberate orphan event, no strays"
  (+ orphans-at-start 1) (length (orphan-callback-events)))

(uv-loop-teardown! l)

(test-equal "epilogue: teardown leaves no loop live"
  0 (live-count 'loop))

(test-equal "epilogue: the registry is empty again"
  registry-count-at-start (registry-count))

(test-end "dns")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
