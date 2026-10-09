#!r6rs
;;; Asynchronous host resolver operations. Results are copied into Scheme
;;; records before libuv-owned memory is released.
(library (libuv dns)
  (export uv-getaddrinfo! uv-getnameinfo! uv-cancel! uv-dns-request?
          addrinfo-chain->list
          make-uv-addrinfo uv-addrinfo?
          uv-addrinfo-family uv-addrinfo-socktype uv-addrinfo-protocol
          uv-addrinfo-address uv-addrinfo-port uv-addrinfo-canonname)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (only (libuv private lists) fold-flags)
          (libuv private handles)
          (libuv private addrinfo))

  ;; Validated symbols map to compiler-derived platform constants.
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

  ;; hint-writes : (or 'absent alist) -> (or 'absent (list-of (offset . int)))
  ;; What to write into the request's zeroed hints tail, and where, worked
  ;; out from validate-hints's copy before the block exists. Writing it then
  ;; reads no caller data and cannot raise. struct addrinfo field order
  ;; differs between glibc and Darwin, so the offsets are the shim's.
  (define (hint-writes hints)
    (if (eq? hints 'absent)
        'absent
        (map (lambda (entry)
               (let ((value (cdr entry)))
                 (case (car entry)
                   ((family)
                    (cons (offsetof-addrinfo-ai-family) (family-symbol->int value)))
                   ((socktype)
                    (cons (offsetof-addrinfo-ai-socktype) (socktype-symbol->int value)))
                   ((protocol)
                    (cons (offsetof-addrinfo-ai-protocol) (protocol-symbol->int value)))
                   (else
                    (cons (offsetof-addrinfo-ai-flags) (flag-symbols->int value))))))
             hints)))

  ;; write-hints! : uptr (or 'absent (list-of (offset . int))) -> boolean
  ;; Inside the step: writes the hints into the request's zeroed tail at
  ;; TAIL and answers #t. It raises nothing: a value that is no C int is not
  ;; written, and it answers #f. hint-writes makes every value from the
  ;; platform's constants, so only a hint-writes that has drifted comes here.
  (define (write-hints! tail writes)
    (or (eq? writes 'absent)
        (for-all (lambda (w) (try-c-int-set! (+ tail (car w)) (cdr w))) writes)))

  ;; uv-getaddrinfo! : uv-loop (or string #f) (or string #f) procedure
  ;;                   -> uv-dns-request
  ;; uv-getaddrinfo! : uv-loop (or string #f) (or string #f) alist procedure
  ;;                   -> uv-dns-request
  ;; on-complete receives (error-or-#f results); errors carry an empty list.
  (define uv-getaddrinfo!
    (case-lambda
      ((loop node service on-complete)
       (start-getaddrinfo! loop node service #f on-complete))
      ((loop node service hints on-complete)
       (start-getaddrinfo! loop node service hints on-complete))))

  ;; Every argument is read once, by the validators, and everything from the
  ;; allocation on uses their copies: node and service as the bytes C reads,
  ;; the hints as the ints the block receives. So nothing the caller can
  ;; still change reaches C (tests/test-dns.sps's sweeps).
  ;; Loop-thread-only: libuv counts the request in the loop with a plain
  ;; increment the loop's thread decrements, so from another thread the
  ;; loop could exit early or never (#79). Checked on entry, and again in
  ;; one interrupt-free step with the loop's pointer, the allocation, the
  ;; hints, the registration, the count and uv_getaddrinfo (#85). So no
  ;; engine can split the lookup from its checks, or drop it holding a
  ;; request libuv has not taken (tests/test-request-steps.sps).
  (define (start-getaddrinfo! loop node service hints on-complete)
    (require-open-loop loop 'uv-getaddrinfo!)
    (require-loop-thread loop 'uv-getaddrinfo!)
    (let* ((strings (validate-node-and-service node service 'uv-getaddrinfo!))
           (writes (hint-writes (validate-hints hints 'uv-getaddrinfo!))))
      (unless (procedure? on-complete)
        (raise (make-uv-invalid-argument 'uv-getaddrinfo!
                                         'on-complete-not-a-procedure)))
      (let* ((hints-offset (align-16 (uv-req-size (uv-getaddrinfo-req-type))))
             (size (+ hints-offset (sizeof-addrinfo)))
             (started
              (one-step
               (let ((loop-ptr (owned-loop-ptr loop)))
                 (if (symbol? loop-ptr)
                     loop-ptr
                     (let ((block (alloc-block size)))
                       (cond
                         ((zero? block) 'no-memory)
                         ((not (write-hints! (+ block hints-offset) writes))
                          (free-block! block)
                          'hint-not-a-c-int)
                         (else
                          (submit-request!
                           block (%make-uv-req-record block 'getaddrinfo #f on-complete loop)
                           'getaddrinfo-req loop
                           count-getaddrinfo-req-new! count-getaddrinfo-req-free!
                           ;; Absent hints must cross as NULL, not as a zeroed
                           ;; struct: libc may assign different defaults to
                           ;; those two forms.
                           (uv-getaddrinfo-native
                            loop-ptr block (car strings) (cdr strings)
                            (if (eq? writes 'absent) 0 (+ block hints-offset))))))))))))
        (cond ((uv-req? started) started)
              ((eq? started 'wrong-thread)
               (raise (wrong-thread-refusal loop 'uv-getaddrinfo!)))
              (else (raise (step-refusal started 'uv-getaddrinfo! #f)))))))

  ;; uv-dns-request? : object -> boolean
  (define (uv-dns-request? x)
    (and (uv-req? x)
         (memq (req-kind x) '(getaddrinfo getnameinfo))
         #t))

  ;; The flag list is read once (fold-flags).
  (define (nameinfo-flag-symbols->int flags)
    (fold-flags flags 'uv-getnameinfo! 'nameinfo-flags-not-a-list
                (lambda (flag)
                  (case flag
                    ((numeric-host)  (ni-numerichost))
                    ((numeric-serv)  (ni-numericserv))
                    ((name-required) (ni-namereqd))
                    ((dgram)         (ni-dgram))
                    (else (raise (make-uv-invalid-argument
                                  'uv-getnameinfo!
                                  'unknown-nameinfo-flag)))))))

  ;; uv-getnameinfo! : uv-loop string exact-nonnegative-integer procedure
  ;;                   -> uv-dns-request
  ;; uv-getnameinfo! : uv-loop string exact-nonnegative-integer list procedure
  ;;                   -> uv-dns-request
  ;; on-complete receives (error-or-#f host service); both strings are #f on
  ;; failure, including cancellation.
  (define uv-getnameinfo!
    (case-lambda
      ((loop ip port on-complete)
       (start-getnameinfo! loop ip port '() on-complete))
      ((loop ip port flags on-complete)
       (start-getnameinfo! loop ip port flags on-complete))))

  ;; The address is read once, by validate-address, and libuv parses that
  ;; copy (tests/test-address.sps). Loop-thread-only, and one interrupt-free
  ;; step from the owner check to uv_getnameinfo, as uv-getaddrinfo! is.
  (define (start-getnameinfo! loop ip port flags on-complete)
    (require-open-loop loop 'uv-getnameinfo!)
    (require-loop-thread loop 'uv-getnameinfo!)
    (let ((ip-bytes (validate-address ip 'uv-getnameinfo!)))
      (require-port port 'uv-getnameinfo!)
      (let ((flags-int (nameinfo-flag-symbols->int flags)))
        (unless (procedure? on-complete)
          (raise (make-uv-invalid-argument 'uv-getnameinfo!
                                           'on-complete-not-a-procedure)))
        (let* ((addr-offset (align-16 (uv-req-size (uv-getnameinfo-req-type))))
               (size (+ addr-offset (sizeof-sockaddr-storage)))
               (started
                (one-step
                 (let ((loop-ptr (owned-loop-ptr loop)))
                   (if (symbol? loop-ptr)
                       loop-ptr
                       (let ((block (alloc-block size)))
                         (if (zero? block)
                             'no-memory
                             (let* ((addr (+ block addr-offset))
                                    (filled (try-fill-sockaddr! addr ip-bytes port)))
                               (if (eq? filled 'filled)
                                   (submit-request!
                                    block (%make-uv-req-record block 'getnameinfo #f
                                                               on-complete loop)
                                    'getnameinfo-req loop
                                    count-getnameinfo-req-new! count-getnameinfo-req-free!
                                    (uv-getnameinfo-native loop-ptr block addr flags-int))
                                   (begin (free-block! block) filled))))))))))
          (cond ((uv-req? started) started)
                ((eq? started 'wrong-thread)
                 (raise (wrong-thread-refusal loop 'uv-getnameinfo!)))
                (else (raise (step-refusal started 'uv-getnameinfo! #f))))))))

  ;; uv-cancel! : uv-dns-request -> boolean
  ;; A true result means cancellation won, but the completion callback still
  ;; fires. False covers work already running or already completed.
  ;; Loop-thread-only, checked: from another thread, the loop's thread could
  ;; complete the request and free its block between the pointer's read and
  ;; uv_cancel (#79). The owner check, the pointer's read and uv_cancel are
  ;; one interrupt-free step (#85): an engine suspended between the read and
  ;; the call, while its scheduler ran the loop, handed uv_cancel the freed
  ;; block, and one suspended while the loop changed hands cancelled on the
  ;; other thread's loop (tests/test-request-steps.sps). The step's check is
  ;; the only one: nothing is read or made before it, so a check on entry
  ;; too could never refuse a call the step would not (as for the
  ;; constructors, ADR-0019's #79 amendment). After the step it only
  ;; answers, calling nothing for 0 or EBUSY.
  (define (uv-cancel! req)
    (unless (uv-dns-request? req)
      (raise (make-uv-invalid-argument 'uv-cancel!
                                       'not-a-cancellable-request)))
    (let ((loop (req-loop req))
          (busy (errno-symbol->value 'EBUSY)))
      (let ((rc (one-step
                 (if (eqv? (loop-owner-thread loop) (current-thread-id))
                     (let ((ptr (req-ptr req)))
                       (if (zero? ptr) 'done (uv-cancel ptr)))
                     'wrong-thread))))
        (cond ((eqv? rc 0) #t)
              ((or (eq? rc 'done) (eqv? rc busy)) #f)
              ((eq? rc 'wrong-thread) (raise (wrong-thread-refusal loop 'uv-cancel!)))
              (else (uv-check rc 'uv-cancel!))))))

  ;; addrinfo-chain->list : uptr -> (listof uv-addrinfo)
  ;; Read fields through shim offsets, skip unsupported families, and copy all
  ;; strings so the records outlive the native chain.
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

  ;; Preserve unknown socket types and protocols as their raw integers.
  (define (decode-socktype n)
    (cond ((= n (sock-stream)) 'stream)
          ((= n (sock-dgram))  'dgram)
          ((= n (sock-raw))    'raw)
          (else n)))

  (define (decode-protocol n)
    (cond ((= n (ipproto-tcp)) 'tcp)
          ((= n (ipproto-udp)) 'udp)
          (else n)))

  ;; Convert first, then free the chain unconditionally before user delivery.
  ;; A conversion failure frees the request without fabricating callback data.
  (define (getaddrinfo-dispatch req block-ptr status res)
    (cond
      ((not req)
       (uv-freeaddrinfo res)
       (complete-request! 'getaddrinfo 'uv-getaddrinfo!
                          count-getaddrinfo-req-free! req block-ptr status))
      ((not (and (uv-req? req) (eq? (req-kind req) 'getaddrinfo)))
       (raise (condition
               (make-uv-error)
               (make-who-condition 'uv-getaddrinfo-dispatch)
               (make-message-condition
                "getaddrinfo completion for a request of another kind"))))
      (else
       (let-values (((tag payload)
                     (guard (e (#t (values 'conversion-raised e)))
                       (values 'converted (addrinfo-chain->list res)))))
         (uv-freeaddrinfo res)
         (if (eq? tag 'converted)
             (complete-request! 'getaddrinfo 'uv-getaddrinfo!
                                count-getaddrinfo-req-free!
                                req block-ptr status payload)
             (begin (abandon-request! req)
                    (count-getaddrinfo-req-free!)
                    (loop-record-error! (req-loop req) payload)))))))

  ;; hostname and service point inside the request block; copy both before
  ;; complete-request! frees that block.
  (define (getnameinfo-dispatch req block-ptr status hostname-ptr service-ptr)
    (cond
      ((not req)
       (complete-request! 'getnameinfo 'uv-getnameinfo!
                          count-getnameinfo-req-free! req block-ptr status))
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
                            req block-ptr status hostname service)))))

  (define getaddrinfo-dispatch-installed
    (install-dispatch-procedure! 'getaddrinfo getaddrinfo-dispatch))

  (define getnameinfo-dispatch-installed
    (install-dispatch-procedure! 'getnameinfo getnameinfo-dispatch)))
