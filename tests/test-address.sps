#!r6rs
;;; SRFI-64 suite for the address string that uv-tcp-bind!, uv-tcp-connect!
;;; and uv-getnameinfo! hand libuv (ADR-0012's vocabulary, ADR-0009's
;;; "what a call checks, it copies").
;;;
;;; Each call reads the caller's string once, into a private copy, and hands
;;; libuv only that copy's bytes: its UTF-8 and one terminating NUL. A string
;;; holding a NUL of its own is refused, because C reads a string only up to
;;; its first NUL: "::1" with a NUL written at index 2 reads as "::", which
;;; uv-tcp-bind! would bind on every interface instead of loopback. A change
;;; an engine's timer handler makes to the string during the call is wholly
;;; in that copy or wholly absent from it (the sweeps below). Another thread
;;; writing the string during the copy can land partly in it; this suite does
;;; not exercise that, and what libuv gets is checked all the same.
;;;
;;; What libuv parsed is the oracle throughout, read the way each call
;;; exposes it: the address a bound socket reports, the sockaddr in an
;;; in-flight connect request, the host a reverse lookup answers.
;;;
;;; NOT pure: (libuv tcp) and (libuv dns) reach (libuv private native).
;;; Never add this to the Makefile's PURE_TESTS.
(import (rnrs)
        (rnrs mutable-strings)
        (srfi :64)
        (libuv loop)
        (libuv handle)
        (libuv tcp)
        (libuv dns)
        (libuv private conditions)
        ;; The registry, and the in-flight connect request whose sockaddr is
        ;; what libuv was handed.
        (only (libuv private handles) req-ptr registry-count)
        (only (libuv private native)
              live-counts uv-req-size align-16 sockaddr->address-string copy-out)
        (only (libuv private constants) uv-connect-req-type sizeof-sockaddr-in6)
        (uv-testing)
        (only (uv-evidence) describe)
        ;; make-engine drives the changed-address sweeps. foreign-procedure
        ;; reaches libuv's own parser and if_nametoindex, for references made
        ;; without the binding.
        (only (chezscheme) collect make-engine foreign-procedure))

;; SRFI-64's default runner sets no process exit status (AGENTS.md).
(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner prints only a failing row's title. These rows return
;; their evidence when they fail, so print that too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

(test-begin "address")

(define registry-count-at-start (registry-count))
(define counts-at-start (live-counts))

;; #f is the worst possible expected value (AGENTS.md), so every err maps to
;; a symbol.
(define (err->symbol err)
  (cond ((not err) 'no-error)
        ((uv-errno-error? err) (uv-errno-error-errno err))
        (else (list 'unexpected-err-object (describe err)))))

;; What a raise inside a call becomes: a refusal names who refused and why,
;; an errno its symbol, anything else carries its message.
(define (raise->observation e)
  (cond ((uv-invalid-argument? e)
         (list 'refused (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
        ((uv-errno-error? e) (list 'errno (uv-errno-error-errno e)))
        (else (list 'raised (describe e)))))

;; Waits for something to land: generous, and paid only when it never does.
(define landing-cap 2000)

;; Every call here runs in an engine whose resumes are capped, so a call
;; that never finishes answers (stuck-after-resumes n) instead of hanging
;; the suite.
(define resume-fuel 100000)
(define resume-cap 100)

(define l (make-uv-loop))

;; --- fixtures ------------------------------------------------------------
;; The port every connect here aims at: bound on ::1, never listening, so a
;; stray SYN reaches no one else's socket. Each connect is closed before the
;; loop runs, which cancels it, so none ever completes.
(define reserve (make-uv-tcp l))

(define reserve-port
  (guard (e (#t (list 'raised (describe e))))
    (uv-tcp-bind! reserve "::1" 0)
    (uv-tcp-getsockname-port reserve)))

(define port-ok? (and (integer? reserve-port) (positive? reserve-port)))

(test-equal "precondition: ::1 can be bound, for the connect target"
  'bound
  (if port-ok? 'bound reserve-port))

;; The port the connects and their references use: a number even when the
;; bind above failed, so nothing at top level raises over it.
(define connect-port (if port-ok? reserve-port 9))

;; The loopback interface's name, which an IPv6 zone can carry: lo0 on macOS
;; and the BSDs, lo on Linux.
(define if-nametoindex (foreign-procedure "if_nametoindex" (string) unsigned))

(define loopback-zone
  (cond ((positive? (if-nametoindex "lo0")) "lo0")
        ((positive? (if-nametoindex "lo")) "lo")
        (else #f)))

(define zone (or loopback-zone "no-zone"))

(test-equal "precondition: the loopback interface has a name a zone can carry"
  'named
  (if (and loopback-zone (positive? (if-nametoindex loopback-zone)))
      'named
      'no-loopback-interface-named-lo0-or-lo))

;; libuv's own parse of an IPv6 address, called directly rather than through
;; the binding: what a connect's in-flight sockaddr is compared with, byte
;; for byte, so no field offset is transcribed here (ADR-0005).
(define raw-ip6-addr (foreign-procedure "uv_ip6_addr" (u8* int u8*) int))

(define (libuv-ip6-parse s port)
  (let ((out (make-bytevector (sizeof-sockaddr-in6) 0)))
    (if (zero? (raw-ip6-addr (string->utf8 (string-append s "\x0;")) port out))
        out
        (list 'libuv-refused s))))

;; --- one call of each verb -----------------------------------------------
;; A run is made fresh for each call: (values call finish). `call` makes the
;; call on an address and answers what it returned; it may be run inside an
;; engine, and may raise. `finish` takes that answer, or the observation of
;; the raise, after the call is over, and answers the observation:
;;   (bound address)           uv-tcp-bind!: the address getsockname reports;
;;   (parsed address sockaddr) uv-tcp-connect!: the in-flight request's
;;                             sockaddr, which libuv was handed, as text and
;;                             as its bytes;
;;   (host host)               uv-getnameinfo!: the reverse lookup's numeric
;;                             host;
;;   (refused who reason), (errno symbol), (raised message), or other
;;   evidence.
;; `finish` closes and drains whatever the run made, so a run leaves nothing
;; behind but what a broken call left.
(define (close-and-drain! h)
  (when (uv-handle-open? h) (uv-close! h))
  ;; The close callback is pending, so these steps cannot block.
  (run-until l (lambda () (eq? (uv-handle-state h) 'closed)) 64))

(define (bind-run)
  (let ((t (make-uv-tcp l)))
    (values
     (lambda (address) (uv-tcp-bind! t address 0) 'bound)
     (lambda (answer)
       (let ((observed
              (if (eq? answer 'bound)
                  (guard (e (#t (list 'sockname-raised (describe e))))
                    (let-values (((address port) (uv-tcp-sockname-address t)))
                      (list 'bound address)))
                  answer)))
         (close-and-drain! t)
         observed)))))

(define (connect-run)
  (let ((c (make-uv-tcp l))
        (status 'callback-never-fired))
    (values
     (lambda (address)
       (list 'submitted
             (uv-tcp-connect! c address connect-port
                              (lambda (err)
                                (collect)
                                (set! status (err->symbol err))))))
     (lambda (answer)
       (let* ((submitted? (and (pair? answer) (eq? (car answer) 'submitted)))
              ;; The request is read before the loop runs, which is when it
              ;; could complete and be freed; the check holds that.
              (observed
               (if submitted?
                   (let ((ptr (req-ptr (cadr answer))))
                     (if (positive? ptr)
                         (guard (e (#t (list 'read-raised (describe e))))
                           (let ((addr (+ ptr (align-16
                                               (uv-req-size (uv-connect-req-type))))))
                             (list 'parsed
                                   (sockaddr->address-string addr)
                                   (copy-out addr (sizeof-sockaddr-in6)))))
                         (list 'request-released-before-the-read ptr)))
                   answer)))
         ;; The close cancels a submitted connect, whose callback then fires.
         (when (uv-handle-open? c) (uv-close! c))
         (run-until l (lambda ()
                        (and (eq? (uv-handle-state c) 'closed)
                             (or (not submitted?)
                                 (not (eq? status 'callback-never-fired)))))
                    64)
         observed)))))

(define (nameinfo-run)
  (let ((answered 'callback-never-fired))
    (values
     (lambda (address)
       (uv-getnameinfo! l address 80 '(numeric-host numeric-serv)
                        (lambda (err host service)
                          (collect)
                          (set! answered
                                (if err
                                    (list 'lookup-failed (err->symbol err))
                                    (list 'host host)))))
       'submitted)
     (lambda (answer)
       (if (eq? answer 'submitted)
           (begin
             (run-until/ticking
              l (lambda () (not (eq? answered 'callback-never-fired)))
              landing-cap)
             answered)
           answer)))))

;; observe : (-> (values call finish)) object -> observation
;; One call, run to its end: an engine only caps it, and nothing changes the
;; argument.
(define (observe make-run argument)
  (let-values (((call finish) (make-run)))
    (finish
     (let run ((eng (make-engine
                     (lambda ()
                       (guard (e (#t (raise->observation e)))
                         (call argument)))))
               (resumes 0))
       (eng resume-fuel
            (lambda (left v) v)
            (lambda (next)
              (if (= resumes resume-cap)
                  (list 'stuck-after-resumes resumes)
                  (run next (+ resumes 1)))))))))

;; --- an address holding a NUL --------------------------------------------
;; Before this was refused, each verb handed the caller's string to libuv
;; through Chez's `string` argument, and C read it only up to the NUL:
;; "127.0.0.1\x0;anything" was bound, connected to and reverse-resolved as
;; 127.0.0.1. The DNS design refused exactly this prefix resolution for node
;; names (v0.2 design §4.1); an address is refused the same way, wherever
;; the NUL sits.
(define nul-addresses '("127.0.0.1\x0;anything" "::1\x0;" "\x0;"))

(test-equal "uv-tcp-bind! refuses an address holding a NUL, which C would read as its end"
  (map (lambda (a) '(refused uv-tcp-bind! address-contains-nul)) nul-addresses)
  (map (lambda (a) (observe bind-run a)) nul-addresses))

(test-equal "uv-tcp-connect! refuses an address holding a NUL, which C would read as its end"
  (map (lambda (a) '(refused uv-tcp-connect! address-contains-nul)) nul-addresses)
  (map (lambda (a) (observe connect-run a)) nul-addresses))

(test-equal "uv-getnameinfo! refuses an address holding a NUL, which C would read as its end"
  (map (lambda (a) '(refused uv-getnameinfo! address-contains-nul)) nul-addresses)
  (map (lambda (a) (observe nameinfo-run a)) nul-addresses))

;; --- addresses that change during the call -------------------------------
;; Each verb checks its address, allocates, and passes libuv the address. An
;; engine's timer can expire anywhere in that, and its handler can change
;; the caller's string before the call resumes. The call copies the string
;; once, with interrupts disabled, and checks and passes libuv that copy
;; alone, so a handler's change is either wholly in that copy or wholly
;; absent from it.
;;
;; Each sweep runs one call in an engine at rising fuel, makes its change at
;; the first expiry, then resumes the call. Fuel 1 expires before the call
;; reads the address, and the sweep stops at the first run no expiry
;; reached, whatever that run's verdict, so between them every point in the
;; call is visited. It also stops at the first run that stalled (a call that
;; never finished within its resumes, a lookup that never landed) or raised
;; outside the call, keeping that run as the evidence, so a broken build
;; fails by name instead of paying a cap on every later run. A run answers
;; as the call answers for one reading of the address, outside any engine:
;;   'changed   the reading the change made: the call saw the change;
;;   'original  the reading it was given: the change came too late;
;;   'untouched the last run, which no expiry reached.
;; Anything else is the evidence, a list.
;;
;; Two changes:
;;
;; - A NUL written at index 2 of "::1". The reading it makes is refused, so
;;   a run that saw it must be refused for it. Before the fix the NUL reached
;;   libuv, which read "::": uv-tcp-bind! bound every interface,
;;   uv-tcp-connect! was handed the unspecified address, and uv-getnameinfo!
;;   resolved "::".
;;
;; - A long address, with one character widened. Chez's string->utf8, which
;;   the old `string` argument also used, counts a string's bytes, allocates,
;;   then encodes, and a character widened in between is encoded past what
;;   was allocated: the last byte lands on the terminator or past the
;;   allocation. To show that in what libuv parsed, the address is a
;;   full-form IPv6 address, 200 characters of filler and a zone naming the
;;   loopback interface. With a zone, libuv parses only the first 39
;;   characters as the address (uv-common.c's uv_ip6_addr), so the filler is
;;   accepted, and the zone becomes the sockaddr's scope id. A split encoding
;;   changes the zone name: it loses its last byte when the encoding is cut
;;   to the counted length, or runs on into whatever follows the allocation
;;   when that byte is not 0. Either way it names no interface, and the scope
;;   is 0. A filler character is widened, so the change shows only through a
;;   split. The change also writes the address's last digit, 1 to 0, so a
;;   run that saw the change is told from one that did not.
;;
;;   uv-tcp-bind! is not swept this way: the kernel ignores the scope of a
;;   non-link-local address, so the bound address cannot show it, and Linux
;;   gives lo no link-local address to bind instead. It reads the address
;;   through the same validate-address as the two verbs swept here, and its
;;   NUL sweep shows that what it hands libuv is the copy.
;;
;; A sweep that reaches the fuel cap fails the reach row by name; the cap is
;; a safety net, not a measurement.
(define sweep-max-fuel 2000)

(define zone-filler-length 200)

(define (zoned-address address-part)
  (string-append address-part (make-string zone-filler-length #\x) "%" zone))

;; Index 38 is the address part's last digit; the widened character is in
;; the filler.
(define widened-index (+ 39 (div zone-filler-length 2)))

(define (nul-at-2! s) (string-set! s 2 #\nul))

(define (widen-and-zero! s)
  (string-set! s 38 #\0)
  (string-set! s widened-index #\x3bb))

;; What a change makes of a string, without changing the string.
(define (changed-copy change! s)
  (let ((c (string-copy s)))
    (change! c)
    c))

;; A variant names its sweep, the fixtures it needs, the run it sweeps, the
;; address it starts from, the change, and what the call answers for each
;; reading.
(define-record-type sweep-variant
  (fields name needs make-run address change! original changed))

;; The fixtures a sweep needs that are missing here.
(define (missing-fixtures needs)
  (filter (lambda (need)
            (not (case need
                   ((v6-loopback) port-ok?)
                   ((loopback-zone) loopback-zone)
                   (else #f))))
          needs))

(define v6-loopback-full "0000:0000:0000:0000:0000:0000:0000:0001")
(define v6-link-local-full "fe80:0000:0000:0000:0000:0000:0000:0001")

(define bind-nul
  (make-sweep-variant
   'bind-nul '(v6-loopback) bind-run "::1" nul-at-2!
   '(bound "::1")
   '(refused uv-tcp-bind! address-contains-nul)))

(define connect-nul
  (make-sweep-variant
   'connect-nul '(v6-loopback) connect-run "::1" nul-at-2!
   (list 'parsed "::1" (libuv-ip6-parse "::1" connect-port))
   '(refused uv-tcp-connect! address-contains-nul)))

(define getnameinfo-nul
  (make-sweep-variant
   'getnameinfo-nul '() nameinfo-run "::1" nul-at-2!
   '(host "::1")
   '(refused uv-getnameinfo! address-contains-nul)))

;; The in-flight sockaddr carries the scope id; libuv's own parse of each
;; reading is the reference.
(define connect-widened
  (let ((address (zoned-address v6-loopback-full)))
    (make-sweep-variant
     'connect-widened '(v6-loopback loopback-zone) connect-run address
     widen-and-zero!
     (list 'parsed "::1" (libuv-ip6-parse address connect-port))
     (list 'parsed "::"
           (libuv-ip6-parse (changed-copy widen-and-zero! address)
                            connect-port)))))

;; A reverse lookup renders a link-local address's zone, by name, on macOS
;; and on glibc, so the host alone shows the scope.
(define getnameinfo-widened
  (make-sweep-variant
   'getnameinfo-widened '(loopback-zone) nameinfo-run
   (zoned-address v6-link-local-full) widen-and-zero!
   (list 'host (string-append "fe80::1%" zone))
   (list 'host (string-append "fe80::%" zone))))

(define sweep-variants
  (list bind-nul connect-nul getnameinfo-nul connect-widened getnameinfo-widened))

;; The widened sweeps can see a split only because the given address has a
;; scope and a zone name one byte longer names no interface, so its scope
;; drops to 0: it parses as plain "::1" and reverse-resolves as "fe80::1".
;; And each widened sweep's references must be what the call answers for
;; each reading outside any engine. Every element has its own expected
;; value, one only success produces.
(test-equal "precondition: one more byte on the zone drops the scope, and each widened reference is what the call answers for its reading"
  (list 'scoped
        (libuv-ip6-parse "::1" connect-port)
        '(host "fe80::1")
        (sweep-variant-original connect-widened)
        (sweep-variant-changed connect-widened)
        (sweep-variant-original getnameinfo-widened)
        (sweep-variant-changed getnameinfo-widened))
  (let ((longer (lambda (v) (string-append (sweep-variant-address v) "x")))
        (changed (lambda (v)
                   (changed-copy (sweep-variant-change! v)
                                 (sweep-variant-address v)))))
    (list (if (equal? (libuv-ip6-parse (sweep-variant-address connect-widened)
                                       connect-port)
                      (libuv-ip6-parse "::1" connect-port))
              'unscoped
              'scoped)
          (libuv-ip6-parse (longer connect-widened) connect-port)
          (observe nameinfo-run (longer getnameinfo-widened))
          (observe connect-run (sweep-variant-address connect-widened))
          (observe connect-run (changed connect-widened))
          (observe nameinfo-run (sweep-variant-address getnameinfo-widened))
          (observe nameinfo-run (changed getnameinfo-widened)))))

;; run-in-engine : sweep-variant exact-positive-integer
;;                 -> (list expired? observation)
;; The run's address is a fresh copy, so each run starts from the same
;; string.
(define (run-in-engine variant fuel)
  (let ((address (string-copy (sweep-variant-address variant)))
        (expired #f))
    (let-values (((call finish) ((sweep-variant-make-run variant))))
      (let ((answer
             (let run ((eng (make-engine
                             (lambda ()
                               (guard (e (#t (raise->observation e)))
                                 (call address)))))
                       (ticks fuel)
                       (resumes 0))
               (eng ticks
                    (lambda (left v) v)
                    (lambda (next)
                      (unless expired
                        (set! expired #t)
                        ((sweep-variant-change! variant) address))
                      (if (= resumes resume-cap)
                          (list 'stuck-after-resumes resumes)
                          (run next resume-fuel (+ resumes 1))))))))
        (list expired (finish answer))))))

;; A run that waited out a cap, a call that never finished or a lookup that
;; never landed, would cost every later run the same.
(define (stalled? observed)
  (or (eq? observed 'callback-never-fired)
      (and (pair? observed) (eq? (car observed) 'stuck-after-resumes))))

;; The registry and every debug count, and how a run moved them: a run must
;; leave both as it found them. A snapshot per run keeps a leak attributed
;; to the run that made it.
(define (balance) (cons (registry-count) (live-counts)))

(define (residue before)
  (let ((after (balance)))
    (append
     (if (= (car before) (car after))
         '()
         (list (list 'registry (- (car after) (car before)))))
     (filter (lambda (x) x)
             (map (lambda (b a)
                    (and (not (= (cdr b) (cdr a)))
                         (list (car b) (- (cdr a) (cdr b)))))
                  (cdr before) (cdr after))))))

;; run-verdict : sweep-variant exact-positive-integer -> (list go-on? verdict)
;; go-on? holds only for a run an expiry reached that neither stalled nor
;; raised; a raise outside the call (in finish, say) is that run's verdict.
(define (run-verdict variant fuel)
  (let ((before (balance)))
    (guard (e (#t (list #f (list 'run-raised (describe e)))))
      (let* ((r (run-in-engine variant fuel))
             (expired (car r))
             (observed (cadr r))
             (left (residue before)))
        (list (and expired (not (stalled? observed)))
              (cond ((stalled? observed) (list 'stalled observed left))
                    ((pair? left) (list 'left left observed))
                    ((equal? observed (sweep-variant-changed variant)) 'changed)
                    ((equal? observed (sweep-variant-original variant))
                     (if expired 'original 'untouched))
                    (else (list 'answered observed))))))))

;; sweep : sweep-variant -> (list-of (list fuel verdict))
(define (sweep variant)
  (let run ((fuel 1) (acc '()))
    (let* ((v (run-verdict variant fuel))
           (acc (cons (list fuel (cadr v)) acc)))
      (if (and (car v) (< fuel sweep-max-fuel))
          (run (+ fuel 1) acc)
          (reverse acc)))))

;; One sweep after another, in the order listed (map would not fix one).
(define sweeps
  (let next ((vs sweep-variants) (acc '()))
    (if (null? vs)
        (reverse acc)
        (let* ((v (car vs))
               (missing (missing-fixtures (sweep-variant-needs v))))
          (next (cdr vs)
                (cons (cons (sweep-variant-name v)
                            (if (null? missing)
                                (sweep v)
                                (list (list 0 (cons 'fixtures-missing missing)))))
                      acc))))))

;; rows-where : (verdict -> boolean) -> (list-of (list name fuel verdict))
(define (rows-where bad?)
  (apply append
         (map (lambda (s)
                (map (lambda (row) (cons (car s) row))
                     (filter (lambda (row) (bad? (cadr row))) (cdr s))))
              sweeps)))

(define (answered-with? kind)
  (lambda (v)
    (and (pair? v) (eq? (car v) 'answered)
         (pair? (cadr v)) (eq? (car (cadr v)) kind))))

;; The rows below look for bad verdicts and must find none, which says
;; nothing unless each sweep began before the call read its address and ran
;; the call to the end.
(test-equal "each sweep's first run saw its change and its last run none"
  (map (lambda (v) (list (sweep-variant-name v) 'changed 'untouched))
       sweep-variants)
  (map (lambda (s)
         (let ((rows (cdr s)))
           (list (car s)
                 (cadr (car rows))
                 (cadr (list-ref rows (- (length rows) 1))))))
       sweeps))

(test-equal "a call refused during a sweep was refused by the call itself, for the NUL it saw"
  '()
  (rows-where (answered-with? 'refused)))

(test-equal "a bind the sweep let through bound the address it was given"
  '()
  (rows-where (answered-with? 'bound)))

(test-equal "a connect the sweep let through handed libuv one reading of its address"
  '()
  (rows-where (answered-with? 'parsed)))

(test-equal "a reverse lookup the sweep let through resolved one reading of its address"
  '()
  (rows-where (answered-with? 'host)))

(test-equal "no run raised anything else, stalled, or left a request, handle or count behind"
  '()
  (rows-where (lambda (v)
                (and (pair? v)
                     (not (or ((answered-with? 'refused) v)
                              ((answered-with? 'bound) v)
                              ((answered-with? 'parsed) v)
                              ((answered-with? 'host) v)))))))

;; --- epilogue ------------------------------------------------------------
(close-and-drain! reserve)

(uv-loop-teardown! l)

(test-equal "epilogue: every debug count is back where the suite started"
  counts-at-start (live-counts))

(test-equal "epilogue: the registry is empty again"
  registry-count-at-start (registry-count))

(test-end "address")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
