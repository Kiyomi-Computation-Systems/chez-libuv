;;; spike/dns/06-hermetic-matrix.ss — Q4: the hermetic determinism matrix.
;;;
;;; Usage:
;;;   chez --script spike/dns/06-hermetic-matrix.ss \
;;;        /opt/homebrew/opt/libuv/lib/libuv.dylib [scope-interface]
;;; where [scope-interface] is the loopback interface name for the
;;; scoped-literal rows: "lo0" (the default; Darwin) or "lo" (Linux CI leg).
;;;
;;; One line per case: input -> family/socktype/address/port list + errno
;;; symbol, in a deterministic format so two runs diff cleanly (the design
;;; spec section 10 Q4 exit criterion) and so the macOS and glibc legs can be
;;; compared cell by cell.
;;;
;;; What is ASSERTED here is only what ADR-0013 claims is deterministic on
;;; EVERY platform: numeric literals resolve to themselves, AI_NUMERICHOST
;;; plus a non-numeric name answers EAI_NONAME with no network, AF_UNSPEC
;;; plus a literal yields a single family, and the numeric reverse lookups
;;; format exactly. The PER-OS chain shape (entry count and order when the
;;; socktype is unpinned — spec section 9 expects Darwin 2-entries-dgram-first
;;; and glibc 3-including-raw) is MEASURED AND PRINTED, never asserted, so
;;; this same script runs unmodified on the CI glibc leg and the cross-OS
;;; differences are enumerated by diffing the two outputs.
;;;
;;; The scoped-literal rows are ADR-0012's documentation evidence: a
;;; link-local literal with a %zone parses INBOUND (uv_ip6_addr fills
;;; sin6_scope_id via if_nametoindex, uv-common.c:265-296), but the OUTBOUND
;;; render (uv_ip_name) never reads sin6_scope_id (uv-common.c:305-321), so
;;; the zone is dropped — and feeding the de-scoped string back in builds a
;;; sockaddr with scope 0. Measured here, on record, per the ADR's
;;; "no document may claim scope IDs are representable" clause.
;;;
;;; SPIKE-ONLY CONSTANTS: from spike/dns/probe-dns (Darwin arm64); production
;;; snapshots them in the shim (ADR-0005). The AI_* flag VALUES differ on
;;; glibc — the CI leg must re-run probe-dns there and patch these four
;;; defines from its output (recorded as part of the Q4 CI recipe).

(import (chezscheme))

(define argv (command-line-arguments))

(define lib-path
  (if (null? argv)
      (begin (display "usage: 06-hermetic-matrix.ss <libuv.dylib> [scope-interface]\n")
             (exit 2))
      (car argv)))

(define scope-if
  (if (or (null? argv) (null? (cdr argv))) "lo0" (cadr argv)))

;;; --- probe-supplied constants (spike/dns/probe-dns output, Darwin arm64) ---
(define UV_GETADDRINFO      8)
(define UV_GETNAMEINFO      9)
(define UV_RUN_DEFAULT      0)
(define AF_UNSPEC           0)
(define AF_INET             2)
(define AF_INET6           30)      ; Darwin; 10 on Linux — probe per OS
(define SOCK_STREAM         1)
(define SOCK_DGRAM          2)
(define SOCK_RAW            3)
(define AI_NUMERICHOST      4)      ; Darwin values; glibc differs — probe per OS
(define AI_NUMERICSERV      4096)
(define NI_NUMERICHOST      2)
(define NI_NUMERICSERV      8)
(define SIZEOF_ADDRINFO     48)
(define OFFSETOF_AI_FLAGS    0)
(define OFFSETOF_AI_FAMILY   4)
(define OFFSETOF_AI_SOCKTYPE 8)
(define OFFSETOF_AI_PROTOCOL 12)
(define OFFSETOF_AI_ADDR    32)     ; Darwin field order; glibc reverses
(define OFFSETOF_AI_NEXT    40)     ;   canonname/addr — probe per OS
(define SIZEOF_SOCKADDR_IN  16)
(define SIZEOF_SOCKADDR_IN6 28)
(define OFFSETOF_SIN_PORT    2)     ; same offset both families, per probe
(define OFFSETOF_SIN6_PORT   2)
(define OFFSETOF_SIN6_SCOPE 24)

;;; --- load, THEN bind --------------------------------------------------------
(load-shared-object lib-path)

(define uv-loop-size    (foreign-procedure "uv_loop_size"    ()          size_t))
(define uv-req-size     (foreign-procedure "uv_req_size"     (int)       size_t))
(define uv-loop-init    (foreign-procedure "uv_loop_init"    (uptr)      int))
(define uv-loop-close   (foreign-procedure "uv_loop_close"   (uptr)      int))
(define uv-run          (foreign-procedure "uv_run"          (uptr int)  int))
(define uv-getaddrinfo  (foreign-procedure "uv_getaddrinfo"
                                           (uptr uptr uptr string string uptr) int))
(define uv-getnameinfo  (foreign-procedure "uv_getnameinfo"
                                           (uptr uptr uptr uptr int) int))
(define uv-freeaddrinfo (foreign-procedure "uv_freeaddrinfo" (uptr)      void))
(define uv-ip4-addr     (foreign-procedure "uv_ip4_addr"     (string int uptr) int))
(define uv-ip6-addr     (foreign-procedure "uv_ip6_addr"     (string int uptr) int))
(define uv-ip-name      (foreign-procedure "uv_ip_name"      (uptr u8* size_t) int))
(define uv-err-name     (foreign-procedure "uv_err_name"     (int)       uptr))

(define (c-string->string addr)
  (if (= addr 0)
      #f
      (let loop ((i 0) (acc '()))
        (let ((b (foreign-ref 'unsigned-8 addr i)))
          (if (= b 0)
              (utf8->string (u8-list->bytevector (reverse acc)))
              (loop (+ i 1) (cons b acc)))))))

(define (alloc-zeroed n)
  (let ((p (foreign-alloc n)))
    (do ((i 0 (+ i 1))) ((= i n) p)
      (foreign-set! 'unsigned-8 p i 0))))

(define (rc-name rc) (if (zero? rc) "0" (c-string->string (uv-err-name rc))))

;; uv_ip_name renders into a caller buffer (the uv_strerror_r shape). 64
;; bytes: INET6_ADDRSTRLEN is 46 per probe; scratch sizes are not protocol
;; constants (spec section 5.1). Fresh bytevector per call.
(define (sockaddr->address sa)
  (if (zero? sa)
      'null-ai-addr
      (let* ((buf (make-bytevector 64 0))
             (rc  (uv-ip-name sa buf 64)))
        (if (zero? rc)
            (let loop ((i 0))
              (if (or (= i 64) (zero? (bytevector-u8-ref buf i)))
                  (let ((out (make-bytevector i)))
                    (bytevector-copy! buf 0 out 0 i)
                    (utf8->string out))
                  (loop (+ i 1))))
            (string->symbol (string-append "ip-name-" (rc-name rc)))))))

(define (family->symbol f)
  (cond ((= f AF_UNSPEC) 'unspec) ((= f AF_INET) 'inet)
        ((= f AF_INET6) 'inet6) (else f)))
(define (socktype->symbol s)
  (cond ((= s SOCK_STREAM) 'stream) ((= s SOCK_DGRAM) 'dgram)
        ((= s SOCK_RAW) 'raw) (else s)))

(define (sockaddr-port sa fam)
  ;; two-byte big-endian read at the per-family probe offset (ntohs by hand)
  (let ((off (if (= fam AF_INET6) OFFSETOF_SIN6_PORT OFFSETOF_SIN_PORT)))
    (+ (* 256 (foreign-ref 'unsigned-8 sa off))
       (foreign-ref 'unsigned-8 sa (+ off 1)))))

(define (sockaddr-scope sa fam)
  (if (= fam AF_INET6)
      (foreign-ref 'unsigned-32 sa OFFSETOF_SIN6_SCOPE)
      'n/a))

;; Copy-at-the-boundary chain walk: every field is read into Scheme values
;; INSIDE the callback, before uv_freeaddrinfo.
(define (walk-chain res)
  (let loop ((p res) (acc '()) (i 0))
    (if (or (zero? p) (= i 32))          ; 32 = runaway-chain cap
        (reverse acc)
        (let* ((fam  (foreign-ref 'int p OFFSETOF_AI_FAMILY))
               (sock (foreign-ref 'int p OFFSETOF_AI_SOCKTYPE))
               (prot (foreign-ref 'int p OFFSETOF_AI_PROTOCOL))
               (sa   (foreign-ref 'unsigned-64 p OFFSETOF_AI_ADDR))
               (addr (sockaddr->address sa))
               (port (if (zero? sa) 'n/a (sockaddr-port sa fam)))
               (scope (if (zero? sa) 'n/a (sockaddr-scope sa fam))))
          (loop (foreign-ref 'unsigned-64 p OFFSETOF_AI_NEXT)
                (cons (list (family->symbol fam) (socktype->symbol sock)
                            prot addr port scope)
                      acc)
                (+ i 1))))))

;;; --- machinery --------------------------------------------------------------
(define loop-ptr (alloc-zeroed (uv-loop-size)))
(define rc-loop-init (uv-loop-init loop-ptr))
(define gai-req-size (uv-req-size UV_GETADDRINFO))
(define gni-req-size (uv-req-size UV_GETNAMEINFO))

(define case-fired 0)
(define case-status 'never-fired)   ; sentinels: no callback path produces these
(define case-entries 'never-fired)
(define gni-host 'never-fired)
(define gni-service 'never-fired)

(define gai-callable
  (foreign-callable
   (lambda (req status res)
     (set! case-fired (+ case-fired 1))
     (set! case-status status)
     (set! case-entries (walk-chain res))
     (uv-freeaddrinfo res))
   (uptr int uptr) void))
(define gni-callable
  (foreign-callable
   (lambda (req status hostname service)
     (set! case-fired (+ case-fired 1))
     (set! case-status status)
     (set! gni-host (c-string->string hostname))
     (set! gni-service (c-string->string service)))
   (uptr int uptr uptr) void))
(lock-object gai-callable)
(lock-object gni-callable)
(define gai-cb (foreign-callable-entry-point gai-callable))
(define gni-cb (foreign-callable-entry-point gni-callable))

(define fired-not-once 0)   ; every case must deliver exactly one callback

(define (entry-families entries)
  ;; the SET of families in the chain, deduplicated, order of first appearance
  (let loop ((es entries) (acc '()))
    (cond ((null? es) (reverse acc))
          ((memq (caar es) acc) (loop (cdr es) acc))
          (else (loop (cdr es) (cons (caar es) acc))))))

(define (print-entries entries)
  (printf "  entries = ~d   families = ~s\n" (length entries) (entry-families entries))
  (let loop ((es entries) (i 0))
    (unless (null? es)
      (let ((e (car es)))
        (printf "    [~d] family=~s socktype=~s proto=~d addr=~s port=~s scope=~s\n"
                i (list-ref e 0) (list-ref e 1) (list-ref e 2)
                (list-ref e 3) (list-ref e 4) (list-ref e 5)))
      (loop (cdr es) (+ i 1)))))

(define (flags->string flags)
  (if (= flags (bitwise-ior AI_NUMERICHOST AI_NUMERICSERV))
      "numerichost|numericserv"
      (number->string flags)))

;; Runs one forward case to quiescence; returns (submit-rc status entries).
(define (run-gai-case! label node service family socktype flags)
  (set! case-fired 0)
  (set! case-status 'never-fired)
  (set! case-entries 'never-fired)
  (printf "case ~a: node=~s service=~s family=~s socktype=~s flags=~a\n"
          label node service (family->symbol family)
          (if (zero? socktype) 'unpinned (socktype->symbol socktype))
          (flags->string flags))
  (let ((hints (alloc-zeroed SIZEOF_ADDRINFO))
        (req   (foreign-alloc gai-req-size)))
    (foreign-set! 'int hints OFFSETOF_AI_FLAGS flags)
    (foreign-set! 'int hints OFFSETOF_AI_FAMILY family)
    (foreign-set! 'int hints OFFSETOF_AI_SOCKTYPE socktype)
    (let ((rc (uv-getaddrinfo loop-ptr req gai-cb node service hints)))
      (when (zero? rc)
        (uv-run loop-ptr UV_RUN_DEFAULT))
      (unless (zero? rc) (foreign-free req))  ; sync failure: no callback owns it
      (foreign-free hints)
      (when (zero? rc) (foreign-free req))    ; callback fired; block is done
      (unless (= case-fired (if (zero? rc) 1 0))
        (set! fired-not-once (+ fired-not-once 1)))
      (printf "  submit rc = ~a   status = ~a   fired = ~d\n"
              (rc-name rc)
              (if (symbol? case-status) case-status (rc-name case-status))
              case-fired)
      (if (pair? case-entries)
          (print-entries case-entries)
          (printf "  entries = ~s\n" case-entries))
      (list rc case-status (if (pair? case-entries) case-entries '())))))

;; Runs one reverse case; returns (submit-rc status host service).
(define (run-gni-case! label sa flags flags-str)
  (set! case-fired 0)
  (set! case-status 'never-fired)
  (set! gni-host 'never-fired)
  (set! gni-service 'never-fired)
  (let ((req (foreign-alloc gni-req-size)))
    (let ((rc (uv-getnameinfo loop-ptr req gni-cb sa flags)))
      (when (zero? rc) (uv-run loop-ptr UV_RUN_DEFAULT))
      (foreign-free req)
      (unless (= case-fired (if (zero? rc) 1 0))
        (set! fired-not-once (+ fired-not-once 1)))
      (printf "case ~a: flags=~a\n" label flags-str)
      (printf "  submit rc = ~a   status = ~a   fired = ~d\n"
              (rc-name rc)
              (if (symbol? case-status) case-status (rc-name case-status))
              case-fired)
      (printf "  host = ~s   service = ~s\n" gni-host gni-service)
      (list rc case-status gni-host gni-service))))

(printf "uv_loop_init = ~a\n" (rc-name rc-loop-init))
(printf "scope interface for s-rows = ~s\n\n" scope-if)

;;; --- forward matrix ---------------------------------------------------------
(display "== forward lookups (uv_getaddrinfo) ==\n")
(define NHNS (bitwise-ior AI_NUMERICHOST AI_NUMERICSERV))

(define f1 (run-gai-case! "f1" "127.0.0.1" "80" AF_UNSPEC SOCK_STREAM NHNS))
(define f2 (run-gai-case! "f2" "::1"       "80" AF_UNSPEC SOCK_STREAM NHNS))
(define f3 (run-gai-case! "f3" "chez-libuv-not-numeric.invalid" "80"
                          AF_UNSPEC SOCK_STREAM NHNS))
(define f4 (run-gai-case! "f4" "127.0.0.1" "80" AF_UNSPEC 0 NHNS))
(define f5 (run-gai-case! "f5" "::1"       "80" AF_UNSPEC 0 NHNS))

;;; --- reverse matrix ---------------------------------------------------------
(display "\n== reverse lookups (uv_getnameinfo, NI_NUMERICHOST|NI_NUMERICSERV) ==\n")
(define NINN (bitwise-ior NI_NUMERICHOST NI_NUMERICSERV))
(define sa4 (alloc-zeroed SIZEOF_SOCKADDR_IN))
(define rc-sa4 (uv-ip4-addr "127.0.0.1" 80 sa4))
(define r1 (run-gni-case! "r1 (127.0.0.1:80)" sa4 NINN "numerichost|numericserv"))
(define sa6 (alloc-zeroed SIZEOF_SOCKADDR_IN6))
(define rc-sa6 (uv-ip6-addr "::1" 443 sa6))
(define r2 (run-gni-case! "r2 (::1:443)" sa6 NINN "numerichost|numericserv"))

;;; --- scoped-literal rows (ADR-0012 documentation evidence) ------------------
(display "\n== scoped literal (ADR-0012 documented-drop row) ==\n")
(define scoped-literal (string-append "fe80::1%" scope-if))
(define s1 (run-gai-case! "s1" scoped-literal "80" AF_UNSPEC SOCK_STREAM NHNS))

;; s2: INBOUND parse keeps the zone (sin6_scope_id nonzero), OUTBOUND render
;; drops it. s3: the dropped string round-trips to scope 0 — the ambiguity
;; ADR-0012 documents.
(define sa6-scoped (alloc-zeroed SIZEOF_SOCKADDR_IN6))
(define rc-s2 (uv-ip6-addr scoped-literal 0 sa6-scoped))
(define s2-scope (foreign-ref 'unsigned-32 sa6-scoped OFFSETOF_SIN6_SCOPE))
(define s2-render (sockaddr->address sa6-scoped))
(printf "case s2: uv_ip6_addr(~s) rc = ~a   sin6_scope_id = ~d   uv_ip_name -> ~s\n"
        scoped-literal (rc-name rc-s2) s2-scope s2-render)

(define sa6-descoped (alloc-zeroed SIZEOF_SOCKADDR_IN6))
(define rc-s3 (uv-ip6-addr "fe80::1" 0 sa6-descoped))
(define s3-scope (foreign-ref 'unsigned-32 sa6-descoped OFFSETOF_SIN6_SCOPE))
(define s3-render (sockaddr->address sa6-descoped))
(printf "case s3: uv_ip6_addr(\"fe80::1\") rc = ~a   sin6_scope_id = ~d   uv_ip_name -> ~s\n"
        (rc-name rc-s3) s3-scope s3-render)

;;; --- teardown ---------------------------------------------------------------
(define rc-loop-close (uv-loop-close loop-ptr))
(printf "\nuv_loop_close = ~a\n" (rc-name rc-loop-close))
(foreign-free loop-ptr)
(foreign-free sa4)
(foreign-free sa6)
(foreign-free sa6-scoped)
(foreign-free sa6-descoped)
(collect (collect-maximum-generation))

;;; --- checks -----------------------------------------------------------------
;; Only the cross-OS-deterministic cells are asserted; per-OS chain shape is
;; enumerated above and compared by diffing the two OS legs' outputs.
(define (check name expected actual)
  (printf "~a: expected=~s actual=~s ~a\n"
          name expected actual (if (equal? expected actual) "OK" "MISMATCH")))

(define (entries-of c) (list-ref c 2))
(define (status-of c) (list-ref c 1))
(define (all-entries-are? entries fam addr port)
  (and (pair? entries)
       (for-all (lambda (e)
                  (and (eq? (list-ref e 0) fam)
                       (equal? (list-ref e 3) addr)
                       (eqv? (list-ref e 4) port)))
                entries)))

(display "\n--- checks ---\n")
(check "every case fired exactly once"   0 fired-not-once)
(check "f1 status"                       0 (status-of f1))
(check "f1 single entry"                 1 (length (entries-of f1)))
(check "f1 entries all inet 127.0.0.1:80" #t
       (all-entries-are? (entries-of f1) 'inet "127.0.0.1" 80))
(check "f2 status"                       0 (status-of f2))
(check "f2 single entry"                 1 (length (entries-of f2)))
(check "f2 entries all inet6 ::1:80"     #t
       (all-entries-are? (entries-of f2) 'inet6 "::1" 80))
(check "f3 errno symbol"                 "EAI_NONAME"
       (if (symbol? (status-of f3)) (symbol->string (status-of f3))
           (rc-name (status-of f3))))
(check "f3 empty chain"                  '() (entries-of f3))
(check "f4 status"                       0 (status-of f4))
(check "f4 nonempty, single family (unspec + v4 literal)" #t
       (all-entries-are? (entries-of f4) 'inet "127.0.0.1" 80))
(check "f5 status"                       0 (status-of f5))
(check "f5 nonempty, single family (unspec + v6 literal)" #t
       (all-entries-are? (entries-of f5) 'inet6 "::1" 80))
(check "r1 host"                         "127.0.0.1" (list-ref r1 2))
(check "r1 service"                      "80" (list-ref r1 3))
(check "r2 host"                         "::1" (list-ref r2 2))
(check "r2 service"                      "443" (list-ref r2 3))
(check "sa4/sa6 fills"                   '(0 0) (list rc-sa4 rc-sa6))
(check "s2 scoped literal parses inbound" 0 rc-s2)
(check "s2 scope id nonzero inbound"     #t (> s2-scope 0))
(check "s2 render drops the zone"        "fe80::1" s2-render)
(check "s3 descoped round-trip scope"    0 s3-scope)
(check "s3 render"                       "fe80::1" s3-render)
(check "uv_loop_close rc"                0 rc-loop-close)

(define ok?
  (and (zero? fired-not-once)
       (eqv? (status-of f1) 0) (= 1 (length (entries-of f1)))
       (all-entries-are? (entries-of f1) 'inet "127.0.0.1" 80)
       (eqv? (status-of f2) 0) (= 1 (length (entries-of f2)))
       (all-entries-are? (entries-of f2) 'inet6 "::1" 80)
       (equal? "EAI_NONAME" (if (symbol? (status-of f3))
                                (symbol->string (status-of f3))
                                (rc-name (status-of f3))))
       (null? (entries-of f3))
       (eqv? (status-of f4) 0)
       (all-entries-are? (entries-of f4) 'inet "127.0.0.1" 80)
       (eqv? (status-of f5) 0)
       (all-entries-are? (entries-of f5) 'inet6 "::1" 80)
       (equal? (list-ref r1 2) "127.0.0.1") (equal? (list-ref r1 3) "80")
       (equal? (list-ref r2 2) "::1") (equal? (list-ref r2 3) "443")
       (zero? rc-sa4) (zero? rc-sa6)
       (zero? rc-s2) (> s2-scope 0) (equal? s2-render "fe80::1")
       (zero? rc-s3) (zero? s3-scope) (equal? s3-render "fe80::1")
       (zero? rc-loop-close)))

(printf "\nRESULT: ~a\n" (if ok? "PASS" "FAIL"))
(exit (if ok? 0 1))
