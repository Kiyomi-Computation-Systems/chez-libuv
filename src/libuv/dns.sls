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

  (define (write-hints! tail writes)
    (for-each (lambda (w) (c-int-set! (+ tail (car w)) (cdr w))) writes))

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
  ;; still change reaches C, and nothing between the allocation and the
  ;; guard can raise (tests/test-dns.sps's sweeps; Valgrind holds the free).
  (define (start-getaddrinfo! loop node service hints on-complete)
    (require-open-loop loop 'uv-getaddrinfo!)
    (let* ((strings (validate-node-and-service node service 'uv-getaddrinfo!))
           (writes (hint-writes (validate-hints hints 'uv-getaddrinfo!))))
      (unless (procedure? on-complete)
        (raise (make-uv-invalid-argument 'uv-getaddrinfo!
                                         'on-complete-not-a-procedure)))
      (let* ((hints-offset (align-16 (uv-req-size (uv-getaddrinfo-req-type))))
             (block (alloc-zeroed (+ hints-offset (sizeof-addrinfo))))
             (hints-tail (+ block hints-offset)))
        ;; Absent hints must cross as NULL, not as a zeroed struct: libc may
        ;; assign different defaults to those two forms.
        (unless (eq? writes 'absent)
          (write-hints! hints-tail writes))
        (let ((req (%make-uv-req-record block 'getaddrinfo #f on-complete)))
          (registry-register! block 'getaddrinfo-req loop req)
          (count-getaddrinfo-req-new!)
          (guard (e (#t (abandon-request! req) (count-getaddrinfo-req-free!)
                        (raise e)))
            (uv-check (uv-getaddrinfo-native
                       (loop-pointer loop 'uv-getaddrinfo!)
                       block (car strings) (cdr strings)
                       (if (eq? writes 'absent) 0 hints-tail))
                      'uv-getaddrinfo!))
          req))))

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
  ;; copy (tests/test-address.sps).
  (define (start-getnameinfo! loop ip port flags on-complete)
    (require-open-loop loop 'uv-getnameinfo!)
    (let ((ip-bytes (validate-address ip 'uv-getnameinfo!)))
      (require-port port 'uv-getnameinfo!)
      (let ((flags-int (nameinfo-flag-symbols->int flags)))
        (unless (procedure? on-complete)
          (raise (make-uv-invalid-argument 'uv-getnameinfo!
                                           'on-complete-not-a-procedure)))
        (let* ((addr-offset (align-16 (uv-req-size (uv-getnameinfo-req-type))))
               (block (alloc-zeroed (+ addr-offset (sizeof-sockaddr-storage))))
               (addr (+ block addr-offset)))
          (guard (e (#t (free! block) (raise e)))
            (fill-sockaddr! addr ip-bytes port 'uv-getnameinfo!))
          (let ((req (%make-uv-req-record block 'getnameinfo #f on-complete)))
            (registry-register! block 'getnameinfo-req loop req)
            (count-getnameinfo-req-new!)
            (guard (e (#t (abandon-request! req) (count-getnameinfo-req-free!)
                          (raise e)))
              (uv-check (uv-getnameinfo-native
                         (loop-pointer loop 'uv-getnameinfo!)
                         block addr flags-int)
                        'uv-getnameinfo!))
            req)))))

  ;; uv-cancel! : uv-dns-request -> boolean
  ;; A true result means cancellation won, but the completion callback still
  ;; fires. False covers work already running or already completed.
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
             ;; The loop is read while the request is still registered.
             (let ((loop (registry-loop-of block-ptr)))
               (abandon-request! req)
               (count-getaddrinfo-req-free!)
               (loop-record-error! loop payload)))))))

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
