#!r6rs
;;; TCP-specific operations. Stream reads, writes, and shutdown are re-exported
;;; from (libuv stream); all handles and requests remain opaque.
(library (libuv tcp)
  (export make-uv-tcp
          uv-tcp-bind! uv-tcp-getsockname-port
          uv-tcp-sockname-address uv-tcp-peer-address
          uv-listen! uv-accept! uv-tcp-connect!
          uv-tcp-nodelay! uv-tcp-keepalive!
          ;; stream operations
          uv-write! uv-write*! uv-shutdown! uv-read-start! uv-read-stop!
          uv-stream-write-queue-size)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles)
          (libuv stream))

  ;; Passing another handle kind to a libuv TCP function is undefined.
  (define (require-open-tcp tcp who)
    (unless (uv-tcp-record? tcp)
      (raise (make-uv-invalid-argument who 'not-a-uv-tcp)))
    (require-open-handle tcp who)
    tcp)

  ;; make-uv-tcp : uv-loop -> uv-tcp
  ;; The block holds libuv's handle and the stream's read descriptor.
  (define (make-uv-tcp loop)
    (ensure-native-loaded!)
    (require-open-loop loop 'make-uv-tcp)
    (let ((handle-size (uv-handle-size (uv-tcp-type))))
      (construct-handle 'make-uv-tcp loop (stream-block-size handle-size)
                        uv-tcp-init (tcp-record-maker loop handle-size)
                        count-tcp-new! #f)))

  (define (tcp-record-maker loop handle-size)
    (lambda (ptr) (%make-uv-tcp-record ptr loop handle-size)))

  ;; bind-flags->bits : (listof symbol) symbol -> exact-integer
  ;; Fold a bind-flag list into the unsigned bitmask uv_tcp_bind's third
  ;; argument takes. 'reuseport is the only flag today; any other symbol is a
  ;; named refusal. 'reuseport on a libuv without UV_TCP_REUSEPORT surfaces as
  ;; &uv-constant-unavailable from uv-tcp-reuseport (see (libuv private
  ;; constants)), never as a silent bind with the flag dropped.
  (define (bind-flags->bits flags who)
    (unless (list? flags)
      (raise (make-uv-invalid-argument who 'flags-not-a-list)))
    (fold-left
     (lambda (bits flag)
       (case flag
         ((reuseport) (bitwise-ior bits (uv-tcp-reuseport)))
         (else (raise (make-uv-invalid-argument who 'unknown-bind-flag)))))
     0 flags))

  ;; uv-tcp-bind! : uv-tcp string exact-nonnegative-integer -> unspecified
  ;; uv-tcp-bind! : uv-tcp string exact-nonnegative-integer (listof symbol)
  ;;               -> unspecified
  ;; The optional flag list accepts '(reuseport) for SO_REUSEPORT load balancing
  ;; across processes or loops. Flags are resolved to a bitmask BEFORE any
  ;; allocation, so a malformed flag list (or one naming reuseport on a libuv
  ;; that lacks it) leaves no scratch behind. The sockaddr is synchronous
  ;; scratch and is freed on every exit path.
  (define uv-tcp-bind!
    (case-lambda
      ((tcp ip port) (bind! tcp ip port '()))
      ((tcp ip port flags) (bind! tcp ip port flags))))

  (define (bind! tcp ip port flags)
    (require-open-tcp tcp 'uv-tcp-bind!)
    (require-address ip 'uv-tcp-bind!)
    (require-port port 'uv-tcp-bind!)
    ;; Resolve flags first, in its own let: a raise here (bad flag, or reuseport
    ;; on a libuv without it) must happen before alloc-zeroed, or the scratch
    ;; leaks -- the guard below covers only the allocated window.
    (let ((flag-bits (bind-flags->bits flags 'uv-tcp-bind!)))
      (let ((addr (alloc-zeroed (sizeof-sockaddr-storage))))
        (guard (e (#t (free! addr) (raise e)))
          (fill-sockaddr! addr ip port 'uv-tcp-bind!)
          (uv-check (uv-tcp-bind (handle-pointer tcp 'uv-tcp-bind!) addr flag-bits)
                    'uv-tcp-bind!))
        (free! addr))))

  ;; uv-tcp-getsockname-port : uv-tcp -> exact-nonnegative-integer
  ;; Read the in/out length and the network-order port before freeing scratch.
  (define (uv-tcp-getsockname-port tcp)
    (require-open-tcp tcp 'uv-tcp-getsockname-port)
    (let ((addr (alloc-zeroed (sizeof-sockaddr-storage)))
          (len  (alloc-zeroed (c-int-size))))
      (guard (e (#t (free! addr) (free! len) (raise e)))
        (c-int-set! len (sizeof-sockaddr-storage))
        (uv-check (uv-tcp-getsockname
                   (handle-pointer tcp 'uv-tcp-getsockname-port) addr len)
                  'uv-tcp-getsockname-port)
        (unless (>= (c-int-ref len) (+ (offsetof-sockaddr-in-sin-port) 2))
          (raise (make-uv-invalid-argument 'uv-tcp-getsockname-port
                                           'sockaddr-too-small-for-a-port)))
        (let ((port (read-net-u16 addr (offsetof-sockaddr-in-sin-port))))
          (free! addr)
          (free! len)
          port))))

  ;; uv-tcp-peer-address : uv-tcp
  ;;                       -> (values (or string #f) exact-nonnegative-integer)
  ;; An unconnected handle raises the native ENOTCONN condition.
  (define (uv-tcp-peer-address tcp)
    (require-open-tcp tcp 'uv-tcp-peer-address)
    (let ((addr (alloc-zeroed (sizeof-sockaddr-storage)))
          (len  (alloc-zeroed (c-int-size))))
      (guard (e (#t (free! addr) (free! len) (raise e)))
        (c-int-set! len (sizeof-sockaddr-storage))
        (uv-check (uv-tcp-getpeername-native
                   (handle-pointer tcp 'uv-tcp-peer-address) addr len)
                  'uv-tcp-peer-address)
        (unless (>= (c-int-ref len) (+ (offsetof-sockaddr-in-sin-port) 2))
          (raise (make-uv-invalid-argument 'uv-tcp-peer-address
                                           'sockaddr-too-small-for-a-port)))
        (let ((address (sockaddr->address-string addr))
              (port    (read-net-u16 addr (offsetof-sockaddr-in-sin-port))))
          (free! addr)
          (free! len)
          (values address port)))))

  ;; uv-tcp-sockname-address : uv-tcp
  ;;                           -> (values (or string #f) exact-nonnegative-integer)
  ;; A bound, unconnected handle already has a local address.
  (define (uv-tcp-sockname-address tcp)
    (require-open-tcp tcp 'uv-tcp-sockname-address)
    (let ((addr (alloc-zeroed (sizeof-sockaddr-storage)))
          (len  (alloc-zeroed (c-int-size))))
      (guard (e (#t (free! addr) (free! len) (raise e)))
        (c-int-set! len (sizeof-sockaddr-storage))
        (uv-check (uv-tcp-getsockname
                   (handle-pointer tcp 'uv-tcp-sockname-address) addr len)
                  'uv-tcp-sockname-address)
        (unless (>= (c-int-ref len) (+ (offsetof-sockaddr-in-sin-port) 2))
          (raise (make-uv-invalid-argument 'uv-tcp-sockname-address
                                           'sockaddr-too-small-for-a-port)))
        (let ((address (sockaddr->address-string addr))
              (port    (read-net-u16 addr (offsetof-sockaddr-in-sin-port))))
          (free! addr)
          (free! len)
          (values address port)))))

  ;; uv-listen! : uv-tcp exact-nonnegative-integer procedure -> unspecified
  ;; Store the callback before listening because connections may arrive at once.
  (define (uv-listen! tcp backlog on-connection)
    (require-open-tcp tcp 'uv-listen!)
    (unless (and (integer? backlog) (exact? backlog) (>= backlog 0))
      (raise (make-uv-invalid-argument 'uv-listen! 'backlog-out-of-range)))
    (require-callback on-connection 'uv-listen! 'on-connection-not-a-procedure)
    (set-tcp-on-connection! tcp on-connection)
    (uv-check (uv-listen-native (handle-pointer tcp 'uv-listen!) backlog)
              'uv-listen!))

  ;; uv-accept! : uv-tcp -> uv-tcp
  ;; One interrupt-free step makes the client and accepts into it: the
  ;; server's open check and pointer, the client's construction
  ;; (try-construct-handle, whose step nests), and uv_accept. So no engine
  ;; can split the accept from the server's check, or drop it holding a
  ;; client it has not registered. An initialized client must close
  ;; asynchronously if uv_accept fails; freeing it directly would leave
  ;; libuv's handle queue pointing at freed memory.
  (define (uv-accept! server)
    (require-open-tcp server 'uv-accept!)
    (let* ((loop (handle-loop server))
           (handle-size (uv-handle-size (uv-tcp-type)))
           (size (stream-block-size handle-size))
           (make-record (tcp-record-maker loop handle-size))
           (accepted
            (one-step
             (let ((server-ptr (open-handle-ptr server)))
               (if (symbol? server-ptr)
                   server-ptr
                   (let ((client (try-construct-handle loop size uv-tcp-init make-record
                                                       count-tcp-new! #f)))
                     (if (not (uv-handle? client))
                         client
                         (let ((rc (uv-accept server-ptr (handle-ptr client))))
                           (if (zero? rc)
                               client
                               (begin (begin-close! client #f) rc))))))))))
      (if (uv-handle? accepted)
          accepted
          (raise (step-refusal accepted 'uv-accept! server)))))

  ;; uv-tcp-connect! : uv-tcp string exact-nonnegative-integer procedure
  ;;                   -> uv-request
  ;; Co-allocate the sockaddr with the request because retention varies by OS.
  (define (uv-tcp-connect! tcp ip port on-connect)
    (require-open-tcp tcp 'uv-tcp-connect!)
    (require-address ip 'uv-tcp-connect!)
    (require-port port 'uv-tcp-connect!)
    (require-callback on-connect 'uv-tcp-connect! 'on-connect-not-a-procedure)
    (let* ((addr-offset (align-16 (uv-req-size (uv-connect-req-type))))
           (block (alloc-zeroed (+ addr-offset (sizeof-sockaddr-storage))))
           (addr (+ block addr-offset)))
      (guard (e (#t (free! block) (raise e)))
        (fill-sockaddr! addr ip port 'uv-tcp-connect!))
      (let ((req (%make-uv-req-record block 'connect tcp on-connect)))
        (registry-register! block 'connect-req (handle-loop tcp) req)
        (count-connect-req-new!)
        (guard (e (#t (abandon-request! req) (count-connect-req-free!)
                      (raise e)))
          (uv-check (uv-tcp-connect-native
                     block (handle-pointer tcp 'uv-tcp-connect!) addr)
                    'uv-tcp-connect!))
        req)))

  ;; uv-tcp-nodelay! : uv-tcp boolean -> unspecified
  ;; Require a boolean because Scheme's 0 is true while C's 0 is false.
  (define (uv-tcp-nodelay! tcp enable?)
    (require-open-tcp tcp 'uv-tcp-nodelay!)
    (unless (boolean? enable?)
      (raise (make-uv-invalid-argument 'uv-tcp-nodelay! 'enable-not-a-boolean)))
    (uv-check (uv-tcp-nodelay (handle-pointer tcp 'uv-tcp-nodelay!)
                              (if enable? 1 0))
              'uv-tcp-nodelay!))

  ;; uv-tcp-keepalive! : uv-tcp boolean -> unspecified
  ;; uv-tcp-keepalive! : uv-tcp boolean exact-positive-integer -> unspecified
  ;; TCP SO_KEEPALIVE. The idle delay is in whole seconds and is REQUIRED when
  ;; enabling: uv_tcp_keepalive answers UV_EINVAL for idle < 1 once the socket
  ;; has an fd, but returns 0 for that same call on a not-yet-connected handle
  ;; (unix/tcp.c) -- so the delay is pinned to one contract here rather than
  ;; left to depend on whether the fd exists yet. Disabling ignores the delay,
  ;; exactly as libuv does. Require a boolean for the same reason as nodelay.
  (define uv-tcp-keepalive!
    (case-lambda
      ((tcp enable?)
       (require-open-tcp tcp 'uv-tcp-keepalive!)
       (unless (boolean? enable?)
         (raise (make-uv-invalid-argument 'uv-tcp-keepalive! 'enable-not-a-boolean)))
       (when enable?
         (raise (make-uv-invalid-argument 'uv-tcp-keepalive!
                                          'delay-required-when-enabling)))
       (uv-check (uv-tcp-keepalive (handle-pointer tcp 'uv-tcp-keepalive!) 0 0)
                 'uv-tcp-keepalive!))
      ((tcp enable? delay)
       (require-open-tcp tcp 'uv-tcp-keepalive!)
       (unless (boolean? enable?)
         (raise (make-uv-invalid-argument 'uv-tcp-keepalive! 'enable-not-a-boolean)))
       (unless (and (integer? delay) (exact? delay) (positive? delay))
         (raise (make-uv-invalid-argument 'uv-tcp-keepalive! 'delay-out-of-range)))
       (uv-check (uv-tcp-keepalive (handle-pointer tcp 'uv-tcp-keepalive!)
                                   (if enable? 1 0) delay)
                 'uv-tcp-keepalive!)))))
