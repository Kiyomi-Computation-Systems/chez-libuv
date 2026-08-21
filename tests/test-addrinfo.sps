#!r6rs
;;; SRFI-64 suite for (libuv private addrinfo) -- design spec v0.2 S4.2/S4.3.
;;;
;;; This is a PURE suite, the tests/test-conditions.sps pattern: it imports
;;; no native code, so `make check-purity` runs it with CHEZ_LIBUV_SHIM
;;; poisoned to prove the record and the symbolic hints validation never
;;; reach (libuv private native). It is listed in the Makefile's PURE_TESTS
;;; (a deliberate explicit edit -- that list is not a wildcard).
;;;
;;; WHAT IS AND IS NOT HERE. Everything symbolic: the uv-addrinfo record,
;;; validate-hints's closed sets, validate-node-and-service's refusals. The
;;; symbol->int mapping (AF_INET and friends) is deliberately NOT here -- it
;;; is boundary work in (libuv dns), tested by tests/test-dns.sps, which is
;;; what keeps this module shim-free (design spec v0.2 S3).
(import (rnrs)
        (srfi :64)
        (libuv private conditions)
        (libuv private addrinfo))

;; SRFI-64's default runner does not set a process exit code, so a failing
;; suite would still exit 0 and `make test` would report success. Hold the
;; runner so its fail count can drive the exit status (AGENTS.md).
(define runner (test-runner-simple))
(test-runner-current runner)

;; Every rejection row asserts (who reason) out of the raised
;; &uv-invalid-argument, with a distinct sentinel for "raised something
;; else" and 'no-raise for "did not raise" -- never a bare #t/#f
;; (AGENTS.md's truthiness and SRFI-64-swallows-raises traps).
(define (rejection thunk)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e)
                   (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (thunk)
    'no-raise))

;; Acceptance rows run under the same guard shape, so a validator that
;; raises on legal input fails by (who reason) rather than as SRFI-64's
;; swallowed #f.
(define (acceptance thunk)
  (guard (e ((uv-invalid-argument? e)
             (list 'rejected
                   (uv-invalid-argument-who e)
                   (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (thunk)))

(test-begin "addrinfo")

;; --- the uv-addrinfo record (design spec v0.2 S4.3) ----------------------
;; make-uv-addrinfo is PUBLIC: the record holds no pointer, so a caller's
;; test double is legitimate -- the same reasoning under which the facade
;; exports the condition constructors. Six distinct-typed/valued sentinels,
;; one per field, so a swapped pair of accessors cannot hide behind two
;; fields sharing a value.
(define rec
  (make-uv-addrinfo 'sentinel-family 'sentinel-socktype 'sentinel-protocol
                    "sentinel-address" 54321 "sentinel-canonname"))

(test-equal "uv-addrinfo? accepts its own instance"
  'an-addrinfo (if (uv-addrinfo? rec) 'an-addrinfo 'not-an-addrinfo))

(test-equal "uv-addrinfo? refuses a non-record"
  'not-an-addrinfo
  (if (uv-addrinfo? '(sentinel-family sentinel-socktype))
      'an-addrinfo 'not-an-addrinfo))

(test-equal "family accessor answers the family field"
  'sentinel-family (uv-addrinfo-family rec))

(test-equal "socktype accessor answers the socktype field"
  'sentinel-socktype (uv-addrinfo-socktype rec))

(test-equal "protocol accessor answers the protocol field"
  'sentinel-protocol (uv-addrinfo-protocol rec))

(test-equal "address accessor answers the address field"
  "sentinel-address" (uv-addrinfo-address rec))

(test-equal "port accessor answers the port field"
  54321 (uv-addrinfo-port rec))

(test-equal "canonname accessor answers the canonname field"
  "sentinel-canonname" (uv-addrinfo-canonname rec))

;; ALL fields immutable (design spec v0.2 S4.3) -- asserted through R6RS
;; record inspection rather than stated in a comment (AGENTS.md). The
;; expected value is a list, so a raise (SRFI-64's swallowed #f) cannot
;; satisfy it.
(test-equal "every uv-addrinfo field is declared immutable"
  '(#f #f #f #f #f #f)
  (let ((rtd (record-type-descriptor uv-addrinfo)))
    (map (lambda (k) (record-field-mutable? rtd k)) '(0 1 2 3 4 5))))

;; --- validate-hints: the absent spellings (design spec v0.2 S4.2) --------
;; Omitted, #f, and '() all canonicalize to "no hints" -- the NULL-pointer
;; decision itself is dns.sls's, but the classification is symbolic and
;; lives here. 'absent and 'present are values only success produces.
(test-equal "hints #f classifies as absent"
  'absent (acceptance (lambda () (validate-hints #f 'test-who))))

(test-equal "hints '() classifies as absent"
  'absent (acceptance (lambda () (validate-hints '() 'test-who))))

;; --- validate-hints: acceptance of the closed sets -----------------------
(test-equal "a full well-formed hints alist validates"
  'present
  (acceptance
   (lambda ()
     (validate-hints '((family . inet6) (socktype . stream) (protocol . tcp)
                       (flags . (canonname numeric-host)))
                     'test-who))))

(test-equal "family unspec validates"
  'present (acceptance (lambda () (validate-hints '((family . unspec)) 'test-who))))

(test-equal "family inet validates"
  'present (acceptance (lambda () (validate-hints '((family . inet)) 'test-who))))

(test-equal "socktype dgram validates"
  'present (acceptance (lambda () (validate-hints '((socktype . dgram)) 'test-who))))

(test-equal "protocol udp validates"
  'present (acceptance (lambda () (validate-hints '((protocol . udp)) 'test-who))))

(test-equal "all four flags together validate"
  'present
  (acceptance
   (lambda ()
     (validate-hints '((flags . (passive canonname numeric-host numeric-serv)))
                     'test-who))))

(test-equal "an empty flags list validates"
  'present (acceptance (lambda () (validate-hints '((flags . ())) 'test-who))))

;; --- validate-hints: rejections, each by (who reason) --------------------
(test-equal "hints that are not a list are refused"
  '(test-who hints-not-an-alist)
  (rejection (lambda () (validate-hints 42 'test-who))))

(test-equal "a non-pair element is refused"
  '(test-who hints-not-an-alist)
  (rejection (lambda () (validate-hints '((family . inet) bogus) 'test-who))))

(test-equal "an improper hints list is refused"
  '(test-who hints-not-an-alist)
  (rejection (lambda () (validate-hints '((family . inet) . tail) 'test-who))))

(test-equal "an unknown key is refused (design spec S4.2's reason symbol)"
  '(test-who unknown-hint-key)
  (rejection (lambda () (validate-hints '((family . inet) (color . blue))
                                        'test-who))))

(test-equal "a duplicate key is refused (design spec S4.2's reason symbol)"
  '(test-who duplicate-hint-key)
  (rejection (lambda () (validate-hints '((family . inet) (family . inet6))
                                        'test-who))))

(test-equal "a family outside {unspec inet inet6} is refused"
  '(test-who unknown-hint-family)
  (rejection (lambda () (validate-hints '((family . ipx)) 'test-who))))

;; Closed sets, NO raw ints accepted (design spec S4.2): even the right
;; platform integer is refused, because v0.2 binds what it tests.
(test-equal "a raw integer family is refused even if it is a real AF_ value"
  '(test-who unknown-hint-family)
  (rejection (lambda () (validate-hints '((family . 2)) 'test-who))))

(test-equal "a socktype outside {stream dgram} is refused"
  '(test-who unknown-hint-socktype)
  (rejection (lambda () (validate-hints '((socktype . seqpacket)) 'test-who))))

;; 'raw is in the DECODE vocabulary (a chain may contain SOCK_RAW entries)
;; but deliberately NOT in the input set -- no offline-deterministic test
;; can assert a raw-socket request, so it cannot be shipped honestly
;; (ADR-0013, design spec S4.2 vs S4.3).
(test-equal "socktype raw is decode vocabulary, not input vocabulary"
  '(test-who unknown-hint-socktype)
  (rejection (lambda () (validate-hints '((socktype . raw)) 'test-who))))

(test-equal "a protocol outside {tcp udp} is refused"
  '(test-who unknown-hint-protocol)
  (rejection (lambda () (validate-hints '((protocol . sctp)) 'test-who))))

(test-equal "a bare flags symbol (not a list) is refused"
  '(test-who hint-flags-not-a-list)
  (rejection (lambda () (validate-hints '((flags . numeric-host)) 'test-who))))

(test-equal "an improper flags list is refused"
  '(test-who hint-flags-not-a-list)
  (rejection (lambda () (validate-hints '((flags . (numeric-host . passive)))
                                        'test-who))))

(test-equal "a flag outside the closed set is refused"
  '(test-who unknown-hint-flag)
  (rejection (lambda () (validate-hints '((flags . (numeric-host bogus-flag)))
                                        'test-who))))

;; AI_ADDRCONFIG is a real getaddrinfo flag that this binding deliberately
;; does not carry (S1 non-goal; ADR-0013 rule 5): its semantics vary by
;; libc and no offline-deterministic test can assert them. The refusal is
;; what makes "never set in any suite" unbypassable through the public API.
(test-equal "addrconfig is refused: deliberately unbound, not merely unknown"
  '(test-who unknown-hint-flag)
  (rejection (lambda () (validate-hints '((flags . (addrconfig))) 'test-who))))

;; --- validate-node-and-service: acceptance -------------------------------
(test-equal "string node + string service validates"
  'validated
  (acceptance (lambda () (validate-node-and-service "127.0.0.1" "80" 'test-who))))

(test-equal "absent node with a service validates (NULL node is legal input)"
  'validated
  (acceptance (lambda () (validate-node-and-service #f "80" 'test-who))))

(test-equal "node with an absent service validates"
  'validated
  (acceptance (lambda () (validate-node-and-service "::1" #f 'test-who))))

;; --- validate-node-and-service: rejections -------------------------------
(test-equal "a non-string non-#f node is refused"
  '(test-who node-not-a-string-or-false)
  (rejection (lambda () (validate-node-and-service 42 "80" 'test-who))))

;; service accepts strings or #f ONLY, never exact integers: the parameter
;; is genuinely a name domain, and auto-number->string is a convenience the
;; mirror rule does not owe (design spec v0.2 S4.2).
(test-equal "an integer service is refused: resolver text, not a port"
  '(test-who service-not-a-string-or-false)
  (rejection (lambda () (validate-node-and-service "127.0.0.1" 80 'test-who))))

(test-equal "node and service both absent is refused in Scheme"
  '(test-who node-and-service-both-absent)
  (rejection (lambda () (validate-node-and-service #f #f 'test-who))))

;; The NUL refusals guard a MEASURED behavior, not a hypothesis: Chez's
;; `string` marshalling NUL-terminates, and the spike observed
;; uv_getaddrinfo("127.0.0.1\x0;.evil", "80") resolve successfully to
;; 127.0.0.1 -- a hostile string resolving as its prefix, plausibly and
;; wrongly (spike/dns/FINDINGS.md Q1 observation (b); design spec v0.2 S4.1).
(test-equal "an embedded NUL in node is refused"
  '(test-who node-contains-nul)
  (rejection (lambda ()
               (validate-node-and-service "127.0.0.1\x0;.evil" "80" 'test-who))))

(test-equal "an embedded NUL in service is refused"
  '(test-who service-contains-nul)
  (rejection (lambda ()
               (validate-node-and-service "127.0.0.1" "8\x0;0" 'test-who))))

;; --- who passthrough -----------------------------------------------------
;; The pure validators are shared vocabulary: the boundary passes its own
;; who ('uv-getaddrinfo!) in, so the condition names the public procedure
;; the caller actually called. A distinct sentinel who proves the value is
;; threaded through rather than baked in.
(test-equal "the caller's who symbol is carried, not a baked-in name"
  '(sentinel-who-4242 duplicate-hint-key)
  (rejection (lambda () (validate-hints '((flags . ()) (flags . ()))
                                        'sentinel-who-4242))))

(test-end "addrinfo")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
