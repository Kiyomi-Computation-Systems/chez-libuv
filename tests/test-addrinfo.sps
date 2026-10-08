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
;;; validate-hints's closed sets, validate-node-and-service's refusals, and
;;; the copies both validators answer, which are what (libuv dns) allocates
;;; and writes from. The symbol->int mapping (AF_INET and friends) is
;;; deliberately NOT here -- it is boundary work in (libuv dns), tested by
;;; tests/test-dns.sps, which is what keeps this module shim-free (design
;;; spec v0.2 S3).
(import (rnrs)
        (rnrs mutable-pairs)
        (rnrs mutable-strings)
        (srfi :64)
        (libuv private conditions)
        (libuv private addrinfo)
        ;; The sweeps below run the validators in engines and change their
        ;; arguments mid-call, from a timer handler and from another thread.
        (only (chezscheme) string-truncate! collect
              fork-thread make-mutex make-condition with-mutex
              condition-wait condition-broadcast getenv)
        ;; The flags' cost, and tests/flags-level-3-child.sps under a
        ;; deadline. Both are pure.
        (uv-meter)
        ;; The engine-sweep driver and describe. Both are pure.
        (uv-sweep)
        (uv-describe)
        (uv-level-3))

;; SRFI-64's default runner does not set a process exit code, so a failing
;; suite would still exit 0 and `make test` would report success. Hold the
;; runner so its fail count can drive the exit status (AGENTS.md).
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

;; describe : object -> string
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
;; Present hints validate to a copy of themselves (see the copy rows below).
(test-equal "a full well-formed hints alist validates"
  '((family . inet6) (socktype . stream) (protocol . tcp)
    (flags . (canonname numeric-host)))
  (acceptance
   (lambda ()
     (validate-hints '((family . inet6) (socktype . stream) (protocol . tcp)
                       (flags . (canonname numeric-host)))
                     'test-who))))

(test-equal "family unspec validates"
  '((family . unspec))
  (acceptance (lambda () (validate-hints '((family . unspec)) 'test-who))))

(test-equal "family inet validates"
  '((family . inet))
  (acceptance (lambda () (validate-hints '((family . inet)) 'test-who))))

(test-equal "socktype dgram validates"
  '((socktype . dgram))
  (acceptance (lambda () (validate-hints '((socktype . dgram)) 'test-who))))

(test-equal "protocol udp validates"
  '((protocol . udp))
  (acceptance (lambda () (validate-hints '((protocol . udp)) 'test-who))))

(test-equal "all four flags together validate"
  '((flags . (passive canonname numeric-host numeric-serv)))
  (acceptance
   (lambda ()
     (validate-hints '((flags . (passive canonname numeric-host numeric-serv)))
                     'test-who))))

(test-equal "an empty flags list validates"
  '((flags . ()))
  (acceptance (lambda () (validate-hints '((flags . ())) 'test-who))))

;; --- validate-hints answers a copy nothing else can reach ----------------
;; (libuv dns) writes the request's hints from this copy after allocating
;; the request block, so the copy may share no pair with the caller's alist:
;; a shared pair is one the caller can still change after it was checked.
;; pairs-of walks every pair reachable through car and cdr.
(define (pairs-of x)
  (if (pair? x)
      (cons x (append (pairs-of (car x)) (pairs-of (cdr x))))
      '()))

;; 8 is the caller's pairs: three of the spine, three entries, two of flags.
(test-equal "the copy equals the caller's hints and shares none of their pairs"
  '(equal 8 unshared)
  (let* ((flags (list 'numeric-host 'canonname))
         (hints (list (cons 'family 'inet) (cons 'socktype 'stream)
                      (cons 'flags flags)))
         (copy (acceptance (lambda () (validate-hints hints 'test-who))))
         (theirs (pairs-of hints)))
    (list (if (equal? copy hints) 'equal (list 'copy-was copy))
          (length theirs)
          (if (exists (lambda (p) (memq p theirs)) (pairs-of copy))
              'shared
              'unshared))))

;; What the copy costs. checked-flags measured the flag list with a guarded
;; length, and a guard allocates a few hundred bytes a call even when
;; nothing raises (#64 item 3): a flags entry cost 272 B more than a family
;; entry. Read with read-proper-list, it costs what a family entry does,
;; plus one pair a flag. tests/uv-meter.sls has the meter.

(define (hints-bytes hints)
  (fewest-bytes (lambda () (validate-hints hints 'test-who))))

;; The second difference is three pairs, 48 B, so a blind meter fails too.
(test-equal "a flags entry costs what a family entry does, plus a pair a flag"
  '(0 48)
  (let ((family (hints-bytes (list (cons 'family 'inet))))
        (no-flags (hints-bytes (list (cons 'flags '()))))
        (three-flags (hints-bytes
                      (list (cons 'flags (list 'passive 'canonname 'numeric-host))))))
    (list (- no-flags family) (- three-flags no-flags))))

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
;; A present string validates to the bytes C reads for it: its UTF-8 and a
;; terminating NUL. An absent one stays #f, which crosses as NULL. The
;; answer is a pair, node first.
(define (c-string . bytes) (u8-list->bytevector (append bytes '(0))))

(test-equal "string node + string service validate to their C strings"
  (cons (c-string 49 50 55 46 48 46 48 46 49) (c-string 56 48)) ; "127.0.0.1" "80"
  (acceptance (lambda () (validate-node-and-service "127.0.0.1" "80" 'test-who))))

(test-equal "absent node with a service validates (NULL node is legal input)"
  (cons #f (c-string 56 48))
  (acceptance (lambda () (validate-node-and-service #f "80" 'test-who))))

(test-equal "node with an absent service validates"
  (cons (c-string 58 58 49) #f)                                  ; "::1"
  (acceptance (lambda () (validate-node-and-service "::1" #f 'test-who))))

(test-equal "a non-ASCII node crosses as UTF-8"
  (cons (c-string 120 206 187) #f)                               ; "xλ"
  (acceptance (lambda () (validate-node-and-service "x\x3bb;" #f 'test-who))))

;; libuv refuses the empty name itself (tests/test-dns.sps's row i), so it
;; must reach libuv as the empty C string, not be dropped or refused here.
(test-equal "an empty node crosses as the empty C string"
  (cons (c-string) (c-string 56 48))
  (acceptance (lambda () (validate-node-and-service "" "80" 'test-who))))

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

;; --- arguments that change during the call -------------------------------
;; An engine's timer can expire anywhere in a validator, and its handler can
;; change the caller's arguments before the validator resumes (so can another
;; thread, below). Each sweep runs a validator in an engine at fuel 1, 2, ...,
;; changes its argument at the first expiry, then resumes it. Fuel 1 expires
;; before the validator reads anything, and the sweep stops at the first run
;; no expiry reached, so between them every point in the validator is
;; visited. Every run must answer for ONE reading of the argument, the old or
;; the changed: refused for the changed one, or exactly the answer for one of
;; the two. Anything else means the validator read the argument more than
;; once, or handed back something the change still reached.
(define sweep-max-fuel 2000)

;; engine-sweep : (-> state) (state -> answer) (state -> any)
;;                -> (list-of (list fuel outcome expired?))
;; OUTCOME is (answered answer), (refused reason), (raised text), or the
;; driver's give-up for a call still running at its cap, which a validator
;; that walks a changed list forever comes to (tests/uv-sweep.sls).
(define (engine-sweep make-state call change!)
  (sweep-fuels
   (lambda (fuel)
     (let ((state (make-state)))
       (run-capped (lambda ()
                     (guard (e ((uv-invalid-argument? e)
                                (list 'refused (uv-invalid-argument-reason e)))
                               (#t (list 'raised (describe e))))
                       (list 'answered (call state))))
                   fuel
                   (lambda () (change! state)))))
   sweep-max-fuel
   (lambda (outcome) #f)))

;; sweep-reach : rows -> (list outcome-of-the-first-run expired?-of-the-last)
(define (sweep-reach rows)
  (list (cadr (car rows)) (caddr (list-ref rows (- (length rows) 1)))))

;; bad-rows : rows (outcome -> boolean) -> rows
(define (bad-rows rows legal?)
  (filter (lambda (row) (not (legal? (cadr row)))) rows))

;; The hints sweeps. Each makes one change at the first expiry, and a run
;; either refuses the change or answers the hints as they were.
(define sweep-hints-as-given
  '((family . inet) (socktype . stream) (flags . (numeric-host numeric-serv))))

(define (sweep-hints)
  (list (cons 'family 'inet) (cons 'socktype 'stream)
        (cons 'flags (list 'numeric-host 'numeric-serv))))

;; (name first-refusal legal-refusals change!)
(define hints-variants
  (list
   ;; Values: read once, so a checked value is the one copied.
   (list 'values-turned-bogus 'unknown-hint-family
         '(unknown-hint-family unknown-hint-flag)
         (lambda (hints)
           (set-cdr! (assq 'family hints) 'bogus)
           (set-car! (cdr (assq 'flags hints)) 'bogus-flag)))
   ;; The spine: walked pair by pair, so an end that stops being a list is
   ;; refused where the walk meets it.
   (list 'spine-made-improper 'hints-not-an-alist '(hints-not-an-alist)
         (lambda (hints) (set-cdr! (cdr hints) 'tail)))
   ;; The spine again: read by read-proper-list, whose one walk finds a
   ;; cycle however the list is cut. Chez's list?, which the validator asked
   ;; first until #66, walks two pointers, and a self-loop made at each of
   ;; the first two pairs at one expiry could leave them on separate cycles,
   ;; where the call never returned: the driver's give-up.
   (list 'spine-split-in-two 'hints-not-an-alist '(hints-not-an-alist)
         (lambda (hints)
           (let ((first hints) (second (cdr hints)))
             (set-cdr! first first)
             (set-cdr! second second))))
   ;; A spine made circular once list? had answered was walked to its first
   ;; repeated key and refused as a duplicate, a reason no version earns.
   (list 'spine-made-circular 'hints-not-an-alist '(hints-not-an-alist)
         (lambda (hints) (set-cdr! (cddr hints) hints)))
   ;; The flags: walked no further than the list was long when found
   ;; proper, so a list made circular is not walked forever.
   (list 'flags-made-circular 'hint-flags-not-a-list '(hint-flags-not-a-list)
         (lambda (hints)
           (let ((flags (cdr (assq 'flags hints))))
             (set-cdr! (cdr flags) flags))))
   ;; The flags again: read to the end they were counted to and refused if
   ;; the list goes on past it, so a tail spliced in during the read is not
   ;; read only as far as the stale count. Read whole, the tail's last flag
   ;; is refused, so no run can answer it.
   (list 'flags-spliced-longer 'unknown-hint-flag
         '(hint-flags-not-a-list unknown-hint-flag)
         (lambda (hints)
           (let ((flags (cdr (assq 'flags hints))))
             (set-cdr! flags (list 'passive 'canonname 'bogus-flag)))))))

(define hints-sweeps
  (map (lambda (v)
         (cons (car v)
               (engine-sweep sweep-hints
                             (lambda (hints) (validate-hints hints 'test-who))
                             (cadddr v))))
       hints-variants))

(test-equal "each hints sweep began before the walk read the hints and ended untouched"
  (map (lambda (v) (list (car v) (list 'refused (cadr v)) #f)) hints-variants)
  (map (lambda (sweep) (cons (car sweep) (sweep-reach (cdr sweep))))
       hints-sweeps))

(test-equal "hints changed during validation are refused or answered as they were"
  (map (lambda (v) (list (car v))) hints-variants)
  (map (lambda (v sweep)
         (cons (car v)
               (bad-rows (cdr sweep)
                         (lambda (outcome)
                           (or (and (eq? (car outcome) 'refused)
                                    (memq (cadr outcome) (caddr v)))
                               (equal? outcome
                                       (list 'answered sweep-hints-as-given)))))))
       hints-variants hints-sweeps))

;; The node sweeps. A node answers as validate-node-and-service's car.
(define (node-sweep make-node change!)
  (engine-sweep make-node
                (lambda (node)
                  (car (validate-node-and-service node #f 'test-who)))
                change!))

(define (answered-c-string s) (list 'answered (c-string-of s)))
(define (c-string-of s)
  (let* ((utf8 (string->utf8 s))
         (out (make-bytevector (+ (bytevector-length utf8) 1) 0)))
    (bytevector-copy! utf8 0 out 0 (bytevector-length utf8))
    out))

;; Widening. Chez's string->utf8 counts a string's UTF-8 bytes, allocates,
;; and then encodes, and an engine can expire in between once the string is
;; 64 characters or more (measured on Chez 10.4.1). A character widened then
;; is encoded into room counted for the old one: the encoding runs past the
;; end of what was allocated, and the answer holds neither string. The
;; validator encodes a copy of its own, so a widened run answers one string.
(define wide-length 256)
(define wide-original (make-string wide-length #\a))
(define wide-changed
  (let ((s (make-string wide-length #\a)))
    (string-set! s (- wide-length 1) #\x3bb)
    s))

(define widening-sweep
  (node-sweep (lambda () (make-string wide-length #\a))
              (lambda (node) (string-set! node (- wide-length 1) #\x3bb))))

(test-equal "the widening sweep began before the copy and ended untouched"
  (list (answered-c-string wide-changed) #f)
  (sweep-reach widening-sweep))

(test-equal "a node widened during validation answers the bytes of one reading"
  '()
  (bad-rows widening-sweep
            (lambda (outcome)
              (member outcome (list (answered-c-string wide-original)
                                    (answered-c-string wide-changed))))))

;; A NUL written into the node. The check runs on the bytes the copy
;; encodes, so a run refuses the NUL or answers the node as it was: never
;; bytes a NUL truncates, which C would read as a shorter name.
(define nul-sweep
  (node-sweep (lambda () (string-copy "127.0.0.1"))
              (lambda (node) (string-set! node 3 #\nul))))

(test-equal "the NUL sweep began before the check and ended untouched"
  '((refused node-contains-nul) #f)
  (sweep-reach nul-sweep))

(test-equal "a NUL written into the node during validation is refused, or reaches nothing"
  '()
  (bad-rows nul-sweep
            (lambda (outcome)
              (member outcome (list '(refused node-contains-nul)
                                    (answered-c-string "127.0.0.1"))))))

;; Truncating, then collecting. Chez's string-copy reads the length, then
;; allocates the copy, then copies, and an engine can expire in between. A
;; string truncated and collected then has fewer characters behind it than
;; the copy reads: the copy reads past it, into whatever the collector put
;; next (measured). The validator copies with interrupts disabled, so no
;; handler runs inside the copy. The z strings make what lies next
;; recognizable.
(define trunc-length 512)
(define trunc-neighbours '())

(define truncation-sweep
  (node-sweep (lambda () (make-string trunc-length #\a))
              (lambda (node)
                (string-truncate! node 1)
                (collect)
                (set! trunc-neighbours
                      (list (make-string trunc-length #\z)
                            (make-string trunc-length #\z))))))

(test-equal "the truncation sweep began before the copy and ended untouched"
  (list (answered-c-string "a") #f)
  (sweep-reach truncation-sweep))

(test-equal "a node truncated during validation answers the bytes of one reading"
  '()
  (bad-rows truncation-sweep
            (lambda (outcome)
              (member outcome (list (answered-c-string "a")
                                    (answered-c-string
                                     (make-string trunc-length #\a)))))))

;; --- a node another thread changes during the call -----------------------
;; No engine is needed for the widening above: another thread can change the
;; string while string->utf8 runs. A narrower thread turns every λ of the
;; node back into a, while this thread widens it to all λ before each call.
;; It only ever narrows, because a race that narrows leaves the end of
;; string->utf8's answer unwritten, while one that widens writes past it, and
;; the evidence would go with the heap. Encoding the node as the caller holds
;; it failed a quarter of this row's rounds, and 14-40% in the probe the row
;; came from; the copy, none (macOS arm64). Each round must answer the bytes
;; of race-length characters, each an a or a λ.
;;
;; Each round starts its call once the narrower has turned the node's first
;; character back, so the narrower is mid-pass when the call reads the node;
;; a round that waits race-wait-cap steps for that ends the sweep, naming the
;; narrower dead. Whether a pass then overlaps the call's read is up to the
;; scheduler, so the row asserts only what no schedule can make fail on a
;; right answer. The informational line counts the rounds that answered a
;; mix of a and λ, which only an overlap produces.
(define race-length 4096)
(define race-rounds 200)
(define race-wait-cap 100000000)

;; reading : outcome -> (or 'all-wide 'mixed 'all-narrow #f)
;; What an answer read, if it is the bytes of one reading; #f otherwise.
(define (reading outcome)
  (and (pair? outcome)
       (eq? (car outcome) 'answered)
       (let* ((bytes (cadr outcome))
              (n (- (bytevector-length bytes) 1)))
         (and (>= n 0)
              (zero? (bytevector-u8-ref bytes n))
              (let ((text (utf8->string
                           (let ((head (make-bytevector n)))
                             (bytevector-copy! bytes 0 head 0 n)
                             head))))
                (and (= (string-length text) race-length)
                     (equal? (c-string-of text) bytes)
                     (let ((chars (string->list text)))
                       (cond ((for-all (lambda (c) (char=? c #\x3bb)) chars)
                              'all-wide)
                             ((for-all (lambda (c) (char=? c #\a)) chars)
                              'all-narrow)
                             ((for-all (lambda (c) (memv c '(#\a #\x3bb))) chars)
                              'mixed)
                             (else #f)))))))))

;; race-sweep : -> (list rounds-run (list-of bad-round) mixed-rounds)
;; Every exit, a raise included, stops the narrower and waits for it.
(define (race-sweep)
  (let ((node (make-string race-length #\a))
        (stop #f)
        (stopped #f)
        (m (make-mutex))
        (c (make-condition)))
    (fork-thread
     (lambda ()
       (let narrow ()
         (unless stop
           (let pass ((i 0))
             (when (< i race-length)
               (string-set! node i #\a)
               (pass (+ i 1))))
           (narrow)))
       (with-mutex m (set! stopped #t) (condition-broadcast c))))
    (let ((result
           (guard (e (#t (list 0 (list (list 'raised (describe e))) 0)))
             (let round ((r 0) (bad '()) (mixed 0))
               (if (= r race-rounds)
                   (list r (reverse bad) mixed)
                   (begin
                     (let widen ((i 0))
                       (when (< i race-length)
                         (string-set! node i #\x3bb)
                         (widen (+ i 1))))
                     (let wait ((k 0))
                       (cond ((char=? (string-ref node 0) #\a) 'narrowing)
                             ((= k race-wait-cap)
                              (raise (list 'the-narrower-never-narrowed
                                           'round r)))
                             (else (wait (+ k 1)))))
                     (let* ((outcome
                             (guard (e ((uv-invalid-argument? e)
                                        (list 'refused
                                              (uv-invalid-argument-reason e)))
                                       (#t (list 'raised (describe e))))
                               (list 'answered
                                     (car (validate-node-and-service
                                           node #f 'test-who)))))
                            (read (reading outcome)))
                       (round (+ r 1)
                              (if read
                                  bad
                                  (cons (list r (if (eq? (car outcome) 'answered)
                                                    'not-one-reading
                                                    outcome))
                                        bad))
                              (if (eq? read 'mixed) (+ mixed 1) mixed)))))))))
      (set! stop #t)
      (with-mutex m (let wait () (unless stopped (condition-wait c m) (wait))))
      result)))

;; Not under Valgrind. It runs one thread at a time, so no round can overlap
;; there (0 of 200, measured), and its default scheduler hands its lock back
;; to the thread that just held it, so this thread's wait starves the
;; narrower: the row failed 4 of 4 runs that way, and passed 4 of 4 with
;; --fair-sched=yes. The Linux memory gate says when it is running
;; (CHEZ_LIBUV_UNDER_VALGRIND, as for tests/test-native.sps's dirty-memory
;; seed).
(if (getenv "CHEZ_LIBUV_UNDER_VALGRIND")
    (begin
      (display "  [informational] cross-thread race: skipped under Valgrind,")
      (display " which runs one thread at a time")
      (newline))
    (let ((race-result (race-sweep)))
      (display "  [informational] cross-thread race: ")
      (display (caddr race-result))
      (display " of ")
      (display (car race-result))
      (display " rounds read the node mid-change")
      (newline)
      (test-equal "a node another thread narrows during validation answers the bytes of one reading"
        (list race-rounds '())
        (list (car race-result) (cadr race-result)))))

;; --- at --optimize-level 3 (#66) ----------------------------------------
;; A program compiled at --optimize-level 3 compiles these libraries from
;; source at that level too, where Chez's length, car and cdr check nothing.
;; checked-flags measured its list with a guarded length, which at level 3
;; walked a circular flag list forever: no guard could catch that, and no
;; engine could stop it. tests/flags-level-3-child.sps runs validate-hints
;; at level 3 in a process of its own and prints what it answered, in two
;; children so a hang takes only its own rows (tests/uv-level-3.sls runs
;; each under a deadline; its rows then fail with killed-at-cap). Each runs
;; in under a second.
(define level-3-chez (getenv "CHEZ_LIBUV_TEST_CHEZ"))
(define level-3-program "tests/flags-level-3-child.sps")
(define level-3-lists
  (and level-3-chez (level-3-run level-3-chez level-3-program '(proper improper))))
(define level-3-circular
  (and level-3-chez (level-3-run level-3-chez level-3-program '(circular))))

(if (not level-3-chez)
    (test-equal "level-3 rows SKIPPED: CHEZ_LIBUV_TEST_CHEZ unset (run via make test)"
      'skipped 'skipped)
    (begin
      ;; The children must run at level 3, with the libraries under test
      ;; compiled there from source, or the rows below test the default
      ;; level, where length checks for itself: a library loaded from a .so
      ;; beside its source keeps the level it was compiled at.
      (test-equal "seed: both children ran at --optimize-level 3, with no library under test loaded from a compiled object"
        '((3 (#f #f #f)) (3 (#f #f #f)))
        (map (lambda (report)
               (list (level-3-entry report 'level) (level-3-entry report 'objects)))
             (list level-3-lists level-3-circular)))
      (test-equal "at --optimize-level 3, a proper flag list is answered as given"
        '(answered ((flags passive canonname))) (level-3-entry level-3-lists 'proper))
      (test-equal "at --optimize-level 3, an improper flag list is refused"
        '(refused hint-flags-not-a-list) (level-3-entry level-3-lists 'improper))
      (test-equal "at --optimize-level 3, a circular flag list is refused, not walked forever"
        '(refused hint-flags-not-a-list) (level-3-entry level-3-circular 'circular))))

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
