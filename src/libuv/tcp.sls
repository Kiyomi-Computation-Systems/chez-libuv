#!r6rs
;;; TCP-specific operations. Stream reads, writes, and shutdown are re-exported
;;; from (libuv stream); all handles and requests remain opaque.
(library (libuv tcp)
  (export make-uv-tcp
          uv-tcp-bind! uv-tcp-getsockname-port
          uv-tcp-sockname-address uv-tcp-peer-address
          uv-listen! uv-accept! uv-tcp-connect!
          uv-tcp-nodelay!
          ;; stream operations
          uv-write! uv-shutdown! uv-read-start! uv-read-stop!
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
  (define (make-uv-tcp loop)
    (ensure-native-loaded!)
    (require-open-loop loop 'make-uv-tcp)
    (let ((ptr (alloc-zeroed (uv-handle-size (uv-tcp-type)))))
      (guard (e (#t (free! ptr) (raise e)))
        (uv-check (uv-tcp-init (loop-pointer loop 'make-uv-tcp) ptr)
                  'make-uv-tcp))
      (let ((tcp (%make-uv-tcp-record ptr loop)))
        (registry-register! ptr 'tcp loop tcp)
        (count-tcp-new!)
        tcp)))

  ;; uv-tcp-bind! : uv-tcp string exact-nonnegative-integer -> unspecified
  ;; The sockaddr is synchronous scratch and is freed on every exit path.
  (define (uv-tcp-bind! tcp ip port)
    (require-open-tcp tcp 'uv-tcp-bind!)
    (require-address ip 'uv-tcp-bind!)
    (require-port port 'uv-tcp-bind!)
    (let ((addr (alloc-zeroed (sizeof-sockaddr-storage))))
      (guard (e (#t (free! addr) (raise e)))
        (fill-sockaddr! addr ip port 'uv-tcp-bind!)
        (uv-check (uv-tcp-bind (handle-pointer tcp 'uv-tcp-bind!) addr 0)
                  'uv-tcp-bind!))
      (free! addr)))

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
  ;; An initialized client must close asynchronously if uv_accept fails; direct
  ;; foreign-free would leave libuv's handle queue pointing at freed memory.
  (define (uv-accept! server)
    (require-open-tcp server 'uv-accept!)
    (let ((client (make-uv-tcp (handle-loop server))))
      (guard (e (#t (close-handle! client) (raise e)))
        (uv-check (uv-accept (handle-pointer server 'uv-accept!)
                             (handle-pointer client 'uv-accept!))
                  'uv-accept!))
      client))

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
              'uv-tcp-nodelay!)))
