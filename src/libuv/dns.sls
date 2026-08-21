#!r6rs
;;; (libuv dns) -- libuv's DNS verbs, as a legible mirror (design spec v0.2
;;; S1): uv_getaddrinfo, uv_getnameinfo, and uv_cancel -- the complete DNS
;;; surface as of Stage 5 of the v0.2 milestone. This is the binding's
;;; first use of libuv's worker threads and its first handle-less,
;;; loop-scoped request kind (ADR-0011); the resolver itself is whatever
;;; getaddrinfo(3)/getnameinfo(3) do on the host -- no c-ares, no record
;;; types, no caching (S1 non-goals).
;;;
;;; NO PROCEDURE HERE TAKES OR RETURNS A POINTER. Results are uv-addrinfo
;;; records -- pure copied Scheme values (ADR-0009) -- and the start call
;;; answers the same opaque request record every other request verb
;;; answers. Pointers appear only inside the completion dispatcher and the
;;; chain walk, which is the posture handles.sls established for dispatch
;;; code (S3). The ONE deliberate exception is addrinfo-chain->list, whose
;;; argument is a chain-head address: it is exported as a TEST SEAM so the
;;; skip policy and the NULL-field arms can be driven with synthetic
;;; chains (S5.4) -- no public path hands anyone an address to pass it.
;;;
;;; THE TWO RULES OF EVERY START CALL (tcp.sls's, verbatim): every argument
;;; is validated before the first allocation, and a failed native call
;;; leaves nothing half-built -- the abandon-request! guard undoes exactly
;;; the register/count the call performed (S5.5).
;;;
;;; DNS DISPATCH POLICY LIVES HERE AND ONLY HERE. native.sls carries the
;;; mechanical trampoline (ADR-0008); handles.sls carries the generic
;;; completion machinery; the getaddrinfo dispatcher below is installed
;;; through install-dispatch-procedure! at THIS library's body time -- the
;;; late-added-callback-type seam handles.sls anticipates. A process that
;;; never imports (libuv dns) keeps the contained raising stub, and
;;; nothing can start a DNS request without the import (S5.4).
(library (libuv dns)
  ;; make-uv-addrinfo, uv-addrinfo? and the six accessors are re-exported
  ;; from (libuv private addrinfo): the record is this library's public
  ;; result vocabulary (S4.3), and the facade re-exports it from here by
  ;; name in Stage 6 (S4.6).
  (export uv-getaddrinfo! uv-getnameinfo! uv-cancel! uv-dns-request?
          addrinfo-chain->list
          make-uv-addrinfo uv-addrinfo?
          uv-addrinfo-family uv-addrinfo-socktype uv-addrinfo-protocol
          uv-addrinfo-address uv-addrinfo-port uv-addrinfo-canonname)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles)
          (libuv private addrinfo))

  ;; --- the symbol->int boundary (ADR-0005) --------------------------------
  ;; The pure module validated the closed sets (S4.2); these mappers turn
  ;; the surviving symbols into the shim-snapshotted platform values. The
  ;; else arms are UNREACHABLE BY CONSTRUCTION -- validate-hints ran first,
  ;; and these procedures have no other caller -- and are recorded raising
  ;; rather than silently writing a 0, per the house convention for
  ;; unreachable arms (tcp.sls:150-156 precedent).
  (define (family-symbol->int sym)
    (case sym
      ((unspec) (af-unspec))
      ((inet)   (af-inet))
      ((inet6)  (af-inet6))
      (else (raise (make-uv-invalid-argument 'uv-getaddrinfo!
                                             'unknown-hint-family)))))

  (define (socktype-symbol->int sym)
    (case sym
      ((stream) (sock-stream))
      ((dgram)  (sock-dgram))
      (else (raise (make-uv-invalid-argument 'uv-getaddrinfo!
                                             'unknown-hint-socktype)))))

  (define (protocol-symbol->int sym)
    (case sym
      ((tcp) (ipproto-tcp))
      ((udp) (ipproto-udp))
      (else (raise (make-uv-invalid-argument 'uv-getaddrinfo!
                                             'unknown-hint-protocol)))))

  (define (flag-symbols->int flags)
    (fold-left (lambda (acc flag)
                 (bitwise-ior acc
                              (case flag
                                ((passive)      (ai-passive))
                                ((canonname)    (ai-canonname))
                                ((numeric-host) (ai-numerichost))
                                ((numeric-serv) (ai-numericserv))
                                (else (raise (make-uv-invalid-argument
                                              'uv-getaddrinfo!
                                              'unknown-hint-flag))))))
               0 flags))

  ;; Write the present hint fields into the zeroed struct addrinfo tail, at
  ;; the SHIM's offsets (never a declared ftype: glibc and Darwin order
  ;; ai_addr/ai_canonname oppositely, S5.2). An omitted key writes nothing
  ;; -- the field keeps the block's zero, which is the platform's own
  ;; "unspecified" for every one of these (S4.2).
  (define (write-hints! tail hints)
    (let ((family   (assq 'family hints))
          (socktype (assq 'socktype hints))
          (protocol (assq 'protocol hints))
          (flags    (assq 'flags hints)))
      (when family
        (c-int-set! (+ tail (offsetof-addrinfo-ai-family))
                    (family-symbol->int (cdr family))))
      (when socktype
        (c-int-set! (+ tail (offsetof-addrinfo-ai-socktype))
                    (socktype-symbol->int (cdr socktype))))
      (when protocol
        (c-int-set! (+ tail (offsetof-addrinfo-ai-protocol))
                    (protocol-symbol->int (cdr protocol))))
      (when flags
        (c-int-set! (+ tail (offsetof-addrinfo-ai-flags))
                    (flag-symbols->int (cdr flags))))))

  ;; --- uv-getaddrinfo! (S4.1, S5.5) ---------------------------------------
  ;; (uv-getaddrinfo! loop node service on-complete)          hints omitted
  ;; (uv-getaddrinfo! loop node service hints on-complete)
  ;;   => opaque dns request
  ;;
  ;; on-complete is (err results): err #f or a condition OBJECT, results a
  ;; fresh list of uv-addrinfo records in resolver order -- '() on every
  ;; error, never #f (S4.4). The callback fires exactly once in every
  ;; outcome (cancellation included, as 'EAI_CANCELED), with the one
  ;; documented S5.4 caveat for a conversion-raising dispatcher bug.
  (define uv-getaddrinfo!
    (case-lambda
      ((loop node service on-complete)
       (start-getaddrinfo! loop node service #f on-complete))
      ((loop node service hints on-complete)
       (start-getaddrinfo! loop node service hints on-complete))))

  ;; EVERY CHECK FIRST, THE ALLOCATION AFTER THEM (S4.1: all validation
  ;; before the first allocation), the native call after that, under the
  ;; abandon guard -- the uv-tcp-connect! shape verbatim (tcp.sls:226-246).
  ;;
  ;; ONE foreign-alloc: [uv_getaddrinfo_t | pad to 16 | struct addrinfo].
  ;; libuv memcpys node, service, AND hints into one req-owned block before
  ;; returning and frees that block itself
  ;; (vendor/libuv/src/unix/getaddrinfo.c:174-208 copies, :114-126 frees),
  ;; so the hints only NEED to survive the synchronous call -- but
  ;; co-allocation settles the lifetime by construction, the
  ;; connect-sockaddr rule verbatim (S5.5). The same vendor fact is what
  ;; makes node/service safe to cross as Chez `string` arguments
  ;; (marshalled copies live for the duration of the call; #f crosses as
  ;; NULL -- both spike-measured, FINDINGS Q1(b)).
  ;;
  ;; Omitted, #f, and '() hints all canonicalize to a NULL hints POINTER --
  ;; the platform's own documented default, NOT a zeroed struct: glibc
  ;; documents NULL as implying AI_V4MAPPED|AI_ADDRCONFIG while a zeroed
  ;; struct disables that, so "omitted" and "empty" would otherwise be two
  ;; silently different behaviors on Linux (S4.2). The block keeps its one
  ;; unconditional layout either way; in the absent case the zeroed tail
  ;; is simply never handed to libuv.
  ;;
  ;; NO empty-string refusal here, deliberately: "" reaching libuv is the
  ;; deterministic post-registration sync failure (idna's UV_EINVAL,
  ;; vendor/libuv/src/idna.c:325-326, raised after our register/count and
  ;; before any possible callback, getaddrinfo.c:163-171) that keeps the
  ;; abandon guard below testable (S5.5, S9).
  (define (start-getaddrinfo! loop node service hints on-complete)
    (require-open-loop loop 'uv-getaddrinfo!)
    (validate-node-and-service node service 'uv-getaddrinfo!)
    (let ((hints-state (validate-hints hints 'uv-getaddrinfo!)))
      (unless (procedure? on-complete)
        (raise (make-uv-invalid-argument 'uv-getaddrinfo!
                                         'on-complete-not-a-procedure)))
      (let* ((hints-offset (align-16 (uv-req-size (uv-getaddrinfo-req-type))))
             (block (alloc-zeroed (+ hints-offset (sizeof-addrinfo))))
             (hints-tail (+ block hints-offset)))
        (when (eq? hints-state 'present)
          (write-hints! hints-tail hints))
        ;; handle = #f: a DNS request belongs to no handle; the registry
        ;; entry carries the loop EXPLICITLY, and that entry is both what
        ;; keeps req and on-complete reachable across the threadpool
        ;; flight and how the completion finds its loop (ADR-0011).
        (let ((req (%make-uv-req-record block 'getaddrinfo #f on-complete)))
          (registry-register! block 'getaddrinfo-req loop req)
          (count-getaddrinfo-req-new!)
          (guard (e (#t (abandon-request! req) (count-getaddrinfo-req-free!)
                        (raise e)))
            (uv-check (uv-getaddrinfo-native
                       (loop-pointer loop 'uv-getaddrinfo!)
                       block node service
                       (if (eq? hints-state 'present) hints-tail 0))
                      'uv-getaddrinfo!))
          req))))

  ;; --- uv-dns-request? (S4.5) --------------------------------------------
  ;; The domain predicate for Stage 5's uv-cancel!: a KIND check over the
  ;; reused request record, answering for both DNS kinds so Stage 5 needs
  ;; no second predicate. Kind-based rather than liveness-based: a request
  ;; whose completion already fired is still a dns request (its record
  ;; survives; only its ptr is zeroed), and uv-cancel! answers #f for it
  ;; rather than refusing it.
  (define (uv-dns-request? x)
    (and (uv-req? x)
         (memq (req-kind x) '(getaddrinfo getnameinfo))
         #t))

  ;; --- the TCP input vocabulary, on the way in (S4.5, ADR-0012) -----------
  ;; uv-getnameinfo! takes ip/port exactly as uv-tcp-connect! does: a
  ;; presentation-form string and a separate exact integer. require-address
  ;; and require-port come from (libuv private native), imported above --
  ;; restated verbatim here through v0.2, then lifted beside fill-sockaddr!
  ;; when the whole-branch review flagged the duplication -- so this verb
  ;; and the TCP verbs cannot drift on what an address or a port IS.

  ;; The nameinfo flags mapper IS the validation (unlike the getaddrinfo
  ;; mappers above, whose else arms sit unreachable behind validate-hints):
  ;; a closed set -- numeric-host, numeric-serv, name-required, dgram --
  ;; with anything else refused by name, and no raw ints accepted (S4.5:
  ;; v0.2 binds what it tests). Pure arithmetic over the shim's snapshot
  ;; (ADR-0005), so it runs BEFORE the first allocation.
  (define (nameinfo-flag-symbols->int flags)
    (unless (list? flags)
      (raise (make-uv-invalid-argument 'uv-getnameinfo!
                                       'nameinfo-flags-not-a-list)))
    (fold-left (lambda (acc flag)
                 (bitwise-ior acc
                              (case flag
                                ((numeric-host)  (ni-numerichost))
                                ((numeric-serv)  (ni-numericserv))
                                ((name-required) (ni-namereqd))
                                ((dgram)         (ni-dgram))
                                (else (raise (make-uv-invalid-argument
                                              'uv-getnameinfo!
                                              'unknown-nameinfo-flag))))))
               0 flags))

  ;; --- uv-getnameinfo! (S4.5, S5.5) ---------------------------------------
  ;; (uv-getnameinfo! loop ip port on-complete)           flags omitted => '()
  ;; (uv-getnameinfo! loop ip port flags on-complete)
  ;;   => opaque dns request
  ;;
  ;; on-complete is (err host service): err #f or a condition OBJECT; on
  ;; success host and service are both fresh STRINGS, on every failure --
  ;; cancellation included, as 'EAI_CANCELED -- both are #f, mechanically:
  ;; libuv passes NULL for both on every nonzero status and
  ;; c-string->string maps NULL to #f (S4.4). The callback fires exactly
  ;; once in every outcome.
  (define uv-getnameinfo!
    (case-lambda
      ((loop ip port on-complete)
       (start-getnameinfo! loop ip port '() on-complete))
      ((loop ip port flags on-complete)
       (start-getnameinfo! loop ip port flags on-complete))))

  ;; EVERY CHECK FIRST, THE ALLOCATION AFTER THEM, the native call under
  ;; the abandon guard -- the start-call shape a third time (S5.5).
  ;;
  ;; ONE foreign-alloc: [uv_getnameinfo_t | pad to 16 | sockaddr_storage].
  ;; The sockaddr is scratch to libuv -- uv_getnameinfo memcpys it into
  ;; req->storage before returning (vendor/libuv/src/unix/getnameinfo.c:
  ;; 89-99) -- but co-allocation settles the lifetime by construction, the
  ;; connect-sockaddr rule verbatim, and it dies in the block's single
  ;; free.
  ;;
  ;; fill-sockaddr! runs AFTER the allocation (it writes into the tail) and
  ;; BEFORE registration: a garbage address unwinds with exactly one free
  ;; and no other bookkeeping (tcp.sls:235-237 verbatim). This is the
  ;; PRE-registration guard; the POST-registration abandon guard below is a
  ;; different animal:
  ;;
  ;; UNREACHABLE BY CONSTRUCTION, KEPT HONEST: getnameinfo has no reachable
  ;; post-registration sync failure -- both EINVAL paths in
  ;; vendor/libuv/src/unix/getnameinfo.c:86-98 precede the uv__req_init at
  ;; :101, and with a non-NULL callback the call then returns 0
  ;; unconditionally (:109-115) -- so
  ;; the abandon arm below can never run (S5.5; contrast getaddrinfo's,
  ;; which idna makes testable). It is kept because deleting it would make
  ;; this start call the only one whose native rc is unguarded, and
  ;; recorded raising-through per the house convention for unreachable arms
  ;; (tcp.sls:150-156 precedent).
  (define (start-getnameinfo! loop ip port flags on-complete)
    (require-open-loop loop 'uv-getnameinfo!)
    (require-address ip 'uv-getnameinfo!)
    (require-port port 'uv-getnameinfo!)
    (let ((flags-int (nameinfo-flag-symbols->int flags)))
      (unless (procedure? on-complete)
        (raise (make-uv-invalid-argument 'uv-getnameinfo!
                                         'on-complete-not-a-procedure)))
      (let* ((addr-offset (align-16 (uv-req-size (uv-getnameinfo-req-type))))
             (block (alloc-zeroed (+ addr-offset (sizeof-sockaddr-storage))))
             (addr (+ block addr-offset)))
        (guard (e (#t (free! block) (raise e)))
          (fill-sockaddr! addr ip port 'uv-getnameinfo!))
        ;; handle = #f, loop carried by the registry entry -- ADR-0011,
        ;; exactly as the getaddrinfo start call above.
        (let ((req (%make-uv-req-record block 'getnameinfo #f on-complete)))
          (registry-register! block 'getnameinfo-req loop req)
          (count-getnameinfo-req-new!)
          (guard (e (#t (abandon-request! req) (count-getnameinfo-req-free!)
                        (raise e)))
            (uv-check (uv-getnameinfo-native
                       (loop-pointer loop 'uv-getnameinfo!)
                       block addr flags-int)
                      'uv-getnameinfo!))
          req))))

  ;; --- uv-cancel! (S4.5) --------------------------------------------------
  ;; (uv-cancel! req) => #t | #f
  ;;
  ;; #t  -- the native cancel won (rc 0: the work was still queued); the
  ;;        callback WILL still fire, with 'EAI_CANCELED, through the
  ;;        normal freeing site. #t is a value only success produces.
  ;; #f  -- too late, uniformly: running or completed (rc UV_EBUSY), or
  ;;        already freed (the stored ptr is zeroed at the freeing site) --
  ;;        in the freed case NO NATIVE CALL IS MADE, since uv_cancel reads
  ;;        req->type through whatever pointer it is handed
  ;;        (vendor/libuv/src/threadpool.c:399-441) and this one is stale.
  ;;        Either way the callback delivers (or delivered) the real
  ;;        result.
  ;;
  ;; BOOLEAN, NOT RAISE: loop-close's 'EBUSY names a state the caller must
  ;; fix; cancel's EBUSY is the unavoidable outcome of a race the caller
  ;; cannot influence -- information, not an error (S4.5).
  ;;
  ;; DOUBLE-CANCEL before the callback fires answers #t twice -- harmless:
  ;; libuv unlinks and re-inserts the same queue node, rc 0 again
  ;; (threadpool.c:399-441; verified vendor fact, design spec S7).
  ;; Documented, not defended.
  ;;
  ;; DOMAIN: dns requests only, checked FIRST -- a v0.1 write/connect/
  ;; shutdown request record RAISES 'not-a-cancellable-request rather than
  ;; answering #f (libuv would answer UV_EINVAL for the non-threadpool
  ;; kinds; refusing in Scheme names the mistake as static, not racy). A
  ;; future uv_work/uv_fs binding widens uv-dns-request?'s kind list
  ;; without a rename (tcp.sls:16-18 reserved exactly this shape).
  ;;
  ;; The else arm is UNREACHABLE BY CONSTRUCTION, kept honest through
  ;; uv-check: a live registered DNS request's pointer names a genuine
  ;; uv_getaddrinfo_t/uv_getnameinfo_t, for which uv_cancel answers only 0
  ;; or UV_EBUSY (UV_EINVAL is the non-threadpool-kind answer the domain
  ;; check already excluded). If libuv ever grows a third answer it raises
  ;; here by name instead of becoming a silent #f.
  (define (uv-cancel! req)
    (unless (uv-dns-request? req)
      (raise (make-uv-invalid-argument 'uv-cancel!
                                       'not-a-cancellable-request)))
    (let ((ptr (req-ptr req)))
      (if (zero? ptr)
          #f
          (let ((rc (uv-cancel ptr)))
            (cond ((zero? rc) #t)
                  ((eq? 'EBUSY (errno-value->symbol rc)) #f)
                  (else (uv-check rc 'uv-cancel!)))))))

  ;; --- the chain walk (S4.3, S5.4) ----------------------------------------
  ;; (addrinfo-chain->list chain-head) -> list of uv-addrinfo, chain order.
  ;;
  ;; Reads every field at the SHIM's offsets through c-uptr-ref/c-int-ref
  ;; -- never a declared layout (the S5.2 portability trap: glibc puts
  ;; ai_addr before ai_canonname, Darwin the reverse). A NULL head answers
  ;; '(), which is what makes the dispatcher's conversion correct on every
  ;; failure status (res is NULL there). Copies everything it delivers
  ;; (ADR-0009): the strings are fresh, the records pure Scheme values,
  ;; and nothing points into the chain when uv_freeaddrinfo runs.
  ;;
  ;; NON-INET-FAMILY ENTRIES ARE SKIPPED: the record has no honest
  ;; representation for them -- uv_ip_name answers UV_EAFNOSUPPORT for
  ;; anything but INET/INET6 (vendor/libuv/src/uv-common.c:318-320) -- and
  ;; skipping cannot fabricate data. Documented corollary: err = #f,
  ;; results = '() is a possible outcome (S4.3).
  ;;
  ;; The port is read at the PER-FAMILY offset (sin_port vs sin6_port,
  ;; both shim-snapshotted): the chain names each entry's family, so the
  ;; v0.1 getsockname shortcut of arguing the two offsets coincide is not
  ;; repeated (S5.2). A NULL ai_addr -- unreachable from a real resolver
  ;; chain, reachable from a synthetic one -- delivers address #f through
  ;; sockaddr->address-string's zero refusal (which never calls native on
  ;; 0, S5.1) and port 0, the only honest number for a sockaddr that is
  ;; not there.
  (define (addrinfo-chain->list chain)
    (let walk ((node chain) (acc '()))
      (if (zero? node)
          (reverse acc)
          (let ((next (c-uptr-ref (+ node (offsetof-addrinfo-ai-next))))
                (family-int (c-int-ref (+ node (offsetof-addrinfo-ai-family)))))
            (cond
              ((= family-int (af-inet))
               (walk next (cons (decode-entry node 'inet
                                              (offsetof-sockaddr-in-sin-port))
                                acc)))
              ((= family-int (af-inet6))
               (walk next (cons (decode-entry node 'inet6
                                              (offsetof-sockaddr-in6-sin6-port))
                                acc)))
              (else (walk next acc)))))))

  (define (decode-entry node family port-offset)
    (let* ((addr-ptr (c-uptr-ref (+ node (offsetof-addrinfo-ai-addr))))
           (address (sockaddr->address-string addr-ptr))
           (port (if (zero? addr-ptr) 0 (read-net-u16 addr-ptr port-offset)))
           (socktype (decode-socktype
                      (c-int-ref (+ node (offsetof-addrinfo-ai-socktype)))))
           (protocol (decode-protocol
                      (c-int-ref (+ node (offsetof-addrinfo-ai-protocol)))))
           (canonname (c-string->string
                       (c-uptr-ref (+ node (offsetof-addrinfo-ai-canonname))))))
      (make-uv-addrinfo family socktype protocol address port canonname)))

  ;; An unmapped value passes through as the raw exact int -- lossless,
  ;; trivially discriminable with symbol?, and deliberately NOT ADR-0006's
  ;; sentinel-symbol-plus-raw-code shape: the raw int IS the diagnostic
  ;; payload here (S4.3). 'raw is in the known set because Linux
  ;; NULL-hints chains genuinely contain SOCK_RAW entries; their protocol
  ;; 0 passes through as 0, the documented "unspecified".
  (define (decode-socktype n)
    (cond ((= n (sock-stream)) 'stream)
          ((= n (sock-dgram))  'dgram)
          ((= n (sock-raw))    'raw)
          (else n)))

  (define (decode-protocol n)
    (cond ((= n (ipproto-tcp)) 'tcp)
          ((= n (ipproto-udp)) 'udp)
          (else n)))

  ;; --- the getaddrinfo dispatcher (S5.4) ----------------------------------
  ;; uv_getaddrinfo_cb: void (*)(uv_getaddrinfo_t *req, int status,
  ;; struct addrinfo *res). Runs inside handles.sls's seam guard, so a
  ;; raise from any arm below is contained and recorded, never unwound
  ;; into libuv's C frame (S8; spike Q2's exit-255 measurement).
  ;;
  ;; EACH STEP'S POSITION IS LOAD-BEARING; the numbered order is S5.4's:
  ;;
  ;;   1. Registry lookup, checking the req record's KIND, not merely
  ;;      uv-req?. The two DNS callback arities differ, so a cross-paired
  ;;      trampoline is UB in C terms -- walking uv_getnameinfo_t's
  ;;      interior char array as an addrinfo chain would end in
  ;;      freeaddrinfo(3) on an interior pointer of a foreign-alloc block.
  ;;      A kind mismatch therefore raises into the containment arm with
  ;;      NO uv_freeaddrinfo: the chain pointer's provenance is unknown in
  ;;      that bug state, and the leak is accepted (the entry itself is
  ;;      left untouched -- it still describes a live object of its own
  ;;      kind). An ORPHAN (no entry at all) frees the chain -- its
  ;;      provenance is then presumably genuine -- and records the orphan
  ;;      event; the recording is delegated to complete-request!, whose
  ;;      no-entry arm IS the orphan recorder (handles.sls owns that
  ;;      vocabulary; nothing else here could reach it).
  ;;   2. Capture the loop via registry-loop-of BEFORE anything pops the
  ;;      entry -- the conversion-failure arm needs it after the entry is
  ;;      gone. It provably answers: the registry-ref above just succeeded
  ;;      on the same key.
  ;;   3. Convert the chain while it is alive, under a capture-guard: the
  ;;      results must exist as pure Scheme values before anything foreign
  ;;      is freed (ADR-0009).
  ;;   4. uv_freeaddrinfo -- EXACTLY ONCE, UNCONDITIONALLY, BEFORE ANY
  ;;      USER CODE. res is NULL on every failure/cancel status
  ;;      (initialized NULL at submit, written only by a successful
  ;;      getaddrinfo(3)) and uv_freeaddrinfo(NULL) is a no-op
  ;;      (vendor/libuv/src/unix/getaddrinfo.c:188, :225-228), so the
  ;;      unconditional call is correct on every path -- success, error,
  ;;      cancel, and conversion failure alike.
  ;;   5. Conversion succeeded -> complete-request! with the results as
  ;;      extras: deregister -> free block -> count -> zero ptr -> THEN
  ;;      on-complete under dispatch-guarded, receiving already-copied
  ;;      values only.
  ;;   6. Conversion raised (a dispatcher bug, not user code) -> the block
  ;;      is freed through the same sequence WITHOUT delivery
  ;;      (abandon-request! + this kind's counter) and the failure
  ;;      surfaces via loop-record-error! -- the binding never invokes
  ;;      on-complete with fabricated data. This is the one documented
  ;;      caveat on "the callback fires exactly once" (S4.4).
  (define (getaddrinfo-dispatch block-ptr status res)
    (let ((req (registry-ref block-ptr)))
      (cond
        ((not req)
         (uv-freeaddrinfo res)
         (complete-request! 'getaddrinfo 'uv-getaddrinfo!
                            count-getaddrinfo-req-free! block-ptr status))
        ((not (and (uv-req? req) (eq? (req-kind req) 'getaddrinfo)))
         (raise (condition
                 (make-uv-error)
                 (make-who-condition 'uv-getaddrinfo-dispatch)
                 (make-message-condition
                  "getaddrinfo completion for a request of another kind"))))
        (else
         (let ((loop (registry-loop-of block-ptr)))
           (let-values (((tag payload)
                         (guard (e (#t (values 'conversion-raised e)))
                           (values 'converted (addrinfo-chain->list res)))))
             (uv-freeaddrinfo res)
             (if (eq? tag 'converted)
                 (complete-request! 'getaddrinfo 'uv-getaddrinfo!
                                    count-getaddrinfo-req-free!
                                    block-ptr status payload)
                 (begin
                   (abandon-request! req)
                   (count-getaddrinfo-req-free!)
                   (loop-record-error! loop payload)))))))))

  ;; --- the getnameinfo dispatcher (S5.4) ----------------------------------
  ;; uv_getnameinfo_cb: void (*)(uv_getnameinfo_t *req, int status,
  ;; const char *hostname, const char *service). Runs inside handles.sls's
  ;; seam guard, like its sibling above.
  ;;
  ;; THE COPY COMES FIRST, and its position is the whole dispatcher:
  ;; hostname and service point INTO the request block itself -- req->host
  ;; and req->service are char arrays inside uv_getnameinfo_t
  ;; (vendor/libuv/include/uv/unix.h:353-354) -- and complete-request!
  ;; frees that block before delivery. Copying after the free would read
  ;; freed memory; passing the pointers through would hand the callback
  ;; dangling foreign addresses (ADR-0009). c-string->string copies, and
  ;; maps NULL to #f -- libuv passes NULL for both on every nonzero status,
  ;; so the S4.4 failure contract (err set, host #f, service #f, cancel
  ;; included) falls out with no branch here.
  ;;
  ;; The step-1 arms mirror the getaddrinfo dispatcher's, minus any
  ;; freeing question -- there is no libuv-owned chain on this path,
  ;; nothing to free but the block itself, and that only through the one
  ;; freeing site:
  ;;   * ORPHAN (no entry): nothing is copied and nothing is freed -- the
  ;;     strings would point into a block whose provenance is unknown;
  ;;     complete-request!'s no-entry arm records the orphan.
  ;;   * KIND MISMATCH: raise into the seam's containment BEFORE touching
  ;;     hostname/service. A cross-paired trampoline means those registers
  ;;     hold garbage (the 3-argument getaddrinfo callback shape read as
  ;;     4), and a uv_getaddrinfo_t walked as a getnameinfo block would
  ;;     deliver interior bytes as strings -- fabricated data, refused
  ;;     (S5.4). The entry itself is left untouched.
  (define (getnameinfo-dispatch block-ptr status hostname-ptr service-ptr)
    (let ((req (registry-ref block-ptr)))
      (cond
        ((not req)
         (complete-request! 'getnameinfo 'uv-getnameinfo!
                            count-getnameinfo-req-free! block-ptr status))
        ((not (and (uv-req? req) (eq? (req-kind req) 'getnameinfo)))
         (raise (condition
                 (make-uv-error)
                 (make-who-condition 'uv-getnameinfo-dispatch)
                 (make-message-condition
                  "getnameinfo completion for a request of another kind"))))
        (else
         (let ((hostname (c-string->string hostname-ptr))
               (service  (c-string->string service-ptr)))
           (complete-request! 'getnameinfo 'uv-getnameinfo!
                              count-getnameinfo-req-free!
                              block-ptr status hostname service))))))

  ;; Installed at library-body time, through the once-per-name seam
  ;; (S5.4): each slot held handles.sls's contained raising stub until
  ;; this instant, and can never be rebound after it.
  (define getaddrinfo-dispatch-installed
    (install-dispatch-procedure! 'getaddrinfo getaddrinfo-dispatch))

  (define getnameinfo-dispatch-installed
    (install-dispatch-procedure! 'getnameinfo getnameinfo-dispatch)))
