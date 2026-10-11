#!r6rs
;;; The walk of a native addrinfo chain into Scheme records. It reads
;;; memory at whatever address it is given and checks nothing, so it is
;;; private: (libuv dns) hands it only the chains getaddrinfo answers, and
;;; tests/test-dns.sps hands it chains it builds.
(library (libuv private addrinfo-chain)
  (export addrinfo-chain->list)
  (import (rnrs)
          (libuv private constants)
          (only (libuv private native)
                c-uptr-ref c-int-ref sockaddr->address-string read-net-u16
                c-string->string)
          (only (libuv private addrinfo) make-uv-addrinfo))

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
          (else n))))
