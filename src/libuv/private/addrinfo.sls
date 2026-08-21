#!r6rs
;;; The uv-addrinfo result record and the SYMBOLIC half of getaddrinfo
;;; argument validation -- design spec v0.2 S4.2 (hints), S4.3 (the record),
;;; S4.1 (node/service refusals).
;;;
;;; This library imports (rnrs) and (libuv private conditions) ONLY -- the
;;; conditions.sls precedent -- and must never import (libuv private native)
;;; or anything that loads the shim: `make check-purity` runs
;;; tests/test-addrinfo.sps with CHEZ_LIBUV_SHIM poisoned to prove exactly
;;; that (Makefile, PURE_TESTS). That constraint is why NO symbol->int
;;; mapping lives here: 'inet -> AF_INET is a shim-snapshotted constant
;;; lookup (ADR-0005), which is boundary work belonging to (libuv dns).
;;; What lives here is everything that can be decided by looking at the
;;; Scheme values alone.
(library (libuv private addrinfo)
  ;; uv-addrinfo -- the record NAME -- is exported so the pure suite can
  ;; assert field immutability through R6RS record inspection (a check, not
  ;; a comment); the facade re-exports only the constructor, predicate, and
  ;; accessors (design spec v0.2 S4.6).
  (export uv-addrinfo make-uv-addrinfo uv-addrinfo?
          uv-addrinfo-family uv-addrinfo-socktype uv-addrinfo-protocol
          uv-addrinfo-address uv-addrinfo-port uv-addrinfo-canonname
          validate-hints validate-node-and-service)
  (import (rnrs)
          (libuv private conditions))

  ;; --- the uv-addrinfo record (design spec v0.2 S4.3) --------------------
  ;; One decoded entry of a getaddrinfo chain. All fields IMMUTABLE: results
  ;; are already-copied Scheme values (ADR-0009), and nothing may edit a
  ;; delivered record out from under a caller who stored it.
  ;;
  ;; make-uv-addrinfo is PUBLIC, deliberately breaking the %-private
  ;; constructor rule: that rule exists for records backed by native memory
  ;; ("a record whose ptr did not come from a successful uv_*_init is a
  ;; segfault waiting to happen"); this record holds no pointer, and a
  ;; caller's test double is legitimate -- the same reasoning under which
  ;; the facade exports the condition constructors (design spec v0.2 S4.3).
  ;;
  ;; The constructor validates nothing, also deliberately: the fields'
  ;; documented types (family 'inet | 'inet6; socktype/protocol
  ;; symbol-or-raw-int; address string | #f; port 0..65535; canonname
  ;; string | #f) describe what the CHAIN WALK produces, not a contract
  ;; enforced on test doubles -- pure data carries what its maker put in.
  (define-record-type (uv-addrinfo make-uv-addrinfo uv-addrinfo?)
    (fields (immutable family    uv-addrinfo-family)
            (immutable socktype  uv-addrinfo-socktype)
            (immutable protocol  uv-addrinfo-protocol)
            (immutable address   uv-addrinfo-address)
            (immutable port      uv-addrinfo-port)
            (immutable canonname uv-addrinfo-canonname)))

  ;; --- the closed hint sets (design spec v0.2 S4.2) ----------------------
  ;; Closed sets, no raw ints accepted: v0.2 binds what it tests. Note the
  ;; asymmetries, each deliberate:
  ;;   * 'raw is in the DECODE vocabulary (S4.3: Linux NULL-hints chains
  ;;     genuinely contain SOCK_RAW entries) but not in the input set --
  ;;     no offline-deterministic test can assert a raw-socket request.
  ;;   * 'addrconfig / 'v4mapped / 'all are absent entirely (S1 non-goal;
  ;;     ADR-0013 rule 5): their semantics vary by libc, and unwatched
  ;;     behavior cannot ship. Adding one later is one shim table entry
  ;;     plus one symbol here.
  (define hint-keys       '(family socktype protocol flags))
  (define hint-families   '(unspec inet inet6))
  (define hint-socktypes  '(stream dgram))
  (define hint-protocols  '(tcp udp))
  (define hint-flag-set   '(passive canonname numeric-host numeric-serv))

  (define (refuse who reason)
    (raise (make-uv-invalid-argument who reason)))

  ;; --- validate-hints ----------------------------------------------------
  ;; (validate-hints hints who) -> 'absent | 'present
  ;;
  ;; 'absent for #f and '() -- the two in-value spellings of "no hints",
  ;; which S4.2 canonicalizes (together with the omitted-argument arity) to
  ;; a NULL hints pointer at the boundary. The pointer decision itself is
  ;; dns.sls's; the CLASSIFICATION is symbolic and answered here, so the
  ;; two callers of this procedure can never classify differently.
  ;;
  ;; 'present after full validation of a non-empty alist: a list of pairs,
  ;; keys drawn from hint-keys, duplicates refused, every value inside its
  ;; closed set. Both answers are values only success produces; every
  ;; failure is &uv-invalid-argument carrying the caller's own who and a
  ;; specific reason symbol (S4.1).
  ;;
  ;; The duplicate check comes BEFORE the value checks for the pair under
  ;; inspection: '((family . inet) (family . bogus)) is refused as the
  ;; caller's real mistake -- saying family twice -- not as a bad family.
  (define (validate-hints hints who)
    (cond
      ((or (eq? hints #f) (null? hints)) 'absent)
      ((not (list? hints)) (refuse who 'hints-not-an-alist))
      (else
       (let walk ((rest hints) (seen '()))
         (if (null? rest)
             'present
             (let ((entry (car rest)))
               (unless (pair? entry) (refuse who 'hints-not-an-alist))
               (let ((key (car entry)) (value (cdr entry)))
                 (unless (memq key hint-keys) (refuse who 'unknown-hint-key))
                 (when (memq key seen) (refuse who 'duplicate-hint-key))
                 (validate-hint-value key value who)
                 (walk (cdr rest) (cons key seen)))))))))

  (define (validate-hint-value key value who)
    (case key
      ((family)
       (unless (memq value hint-families) (refuse who 'unknown-hint-family)))
      ((socktype)
       (unless (memq value hint-socktypes) (refuse who 'unknown-hint-socktype)))
      ((protocol)
       (unless (memq value hint-protocols) (refuse who 'unknown-hint-protocol)))
      ((flags)
       ;; A LIST of flag symbols, '() included ("no flags" spelled inside a
       ;; hints alist that pins other fields). list? refuses the bare-symbol
       ;; and improper-list shapes before memq can walk off a non-pair.
       (unless (list? value) (refuse who 'hint-flags-not-a-list))
       (for-each (lambda (flag)
                   (unless (memq flag hint-flag-set)
                     (refuse who 'unknown-hint-flag)))
                 value))))

  ;; --- validate-node-and-service (design spec v0.2 S4.1) -----------------
  ;; (validate-node-and-service node service who) -> 'validated
  ;;
  ;; Three refusals, in a fixed order (type errors first, then the
  ;; cross-argument rule, then content):
  ;;
  ;;   * each of node/service must be a string or #f -- #f is the legal
  ;;     "absent" spelling that crosses the FFI as NULL. service NEVER
  ;;     accepts an exact integer: the parameter is genuinely a name domain
  ;;     ("http" or "80"), and auto-number->string is a convenience the
  ;;     mirror rule does not owe (S4.2).
  ;;   * not both absent -- refused HERE, in Scheme, rather than letting
  ;;     libuv answer UV_EINVAL, because it is a caller bug, not a
  ;;     lifecycle outcome (S4.1).
  ;;   * no embedded #\nul in either string. This clause guards a MEASURED
  ;;     behavior: Chez's `string` marshalling NUL-terminates, and the
  ;;     spike observed "127.0.0.1\x0;.evil" resolve silently as its prefix
  ;;     (spike/dns/FINDINGS.md Q1(b)). The refusal is a validation clause,
  ;;     not a comment.
  ;;
  ;; NO empty-string refusal, equally deliberately: "" reaching libuv is
  ;; the one deterministic post-registration sync failure (idna's
  ;; UV_EINVAL) that keeps the abandon-request! guard testable; a Scheme-
  ;; side check here would make that guard unreachable (design spec v0.2
  ;; S5.5, S9).
  (define (validate-node-and-service node service who)
    (unless (or (eq? node #f) (string? node))
      (refuse who 'node-not-a-string-or-false))
    (unless (or (eq? service #f) (string? service))
      (refuse who 'service-not-a-string-or-false))
    (when (and (eq? node #f) (eq? service #f))
      (refuse who 'node-and-service-both-absent))
    (when (and node (string-contains-nul? node))
      (refuse who 'node-contains-nul))
    (when (and service (string-contains-nul? service))
      (refuse who 'service-contains-nul))
    'validated)

  (define (string-contains-nul? s)
    (let scan ((i 0))
      (cond ((= i (string-length s)) #f)
            ((char=? (string-ref s i) #\nul) #t)
            (else (scan (+ i 1)))))))
