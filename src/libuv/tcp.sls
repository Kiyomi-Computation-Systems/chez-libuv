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
          (only (libuv private lists) fold-flags)
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
                        count-tcp-new!)))

  (define (tcp-record-maker loop handle-size)
    (lambda (ptr) (%make-uv-tcp-record ptr loop handle-size)))

  ;; bind-flags->bits : (listof symbol) symbol -> exact-integer
  ;; Fold a bind-flag list into the unsigned bitmask uv_tcp_bind's third
  ;; argument takes, reading the list once (fold-flags). 'reuseport is the
  ;; only flag today; any other symbol is a named refusal. 'reuseport on a
  ;; libuv without UV_TCP_REUSEPORT surfaces as &uv-constant-unavailable from
  ;; uv-tcp-reuseport (see (libuv private constants)), never as a silent bind
  ;; with the flag dropped.
  (define (bind-flags->bits flags who)
    (fold-flags flags who 'flags-not-a-list
                (lambda (flag)
                  (case flag
                    ((reuseport) (uv-tcp-reuseport))
                    (else (raise (make-uv-invalid-argument who 'unknown-bind-flag)))))))

  ;; uv-tcp-bind! : uv-tcp string exact-nonnegative-integer -> unspecified
  ;; uv-tcp-bind! : uv-tcp string exact-nonnegative-integer (listof symbol)
  ;;               -> unspecified
  ;; The optional flag list accepts '(reuseport) for SO_REUSEPORT load balancing
  ;; across processes or loops. Flags are resolved to a bitmask before the
  ;; step, so a malformed flag list (or one naming reuseport on a libuv that
  ;; lacks it) is refused with nothing allocated. The address is read once, by
  ;; validate-address, and libuv parses that copy (tests/test-address.sps).
  ;; One interrupt-free step checks again that this thread owns the loop and
  ;; that the client is open, and allocates the sockaddr, fills it, binds and
  ;; frees it (#86). So no engine can split the bind from those checks, or
  ;; drop it holding the sockaddr (tests/test-handle-steps.sps).
  (define uv-tcp-bind!
    (case-lambda
      ((tcp ip port) (bind! tcp ip port '()))
      ((tcp ip port flags) (bind! tcp ip port flags))))

  (define (bind! tcp ip port flags)
    (require-open-tcp tcp 'uv-tcp-bind!)
    (let ((ip-bytes (validate-address ip 'uv-tcp-bind!)))
      (require-port port 'uv-tcp-bind!)
      (let* ((flag-bits (bind-flags->bits flags 'uv-tcp-bind!))
             (size (sizeof-sockaddr-storage))
             (rc (one-step
                  (let ((ptr (owned-handle-ptr tcp)))
                    (if (symbol? ptr)
                        ptr
                        (let ((addr (alloc-block size)))
                          (if (zero? addr)
                              'no-memory
                              (let* ((filled (try-fill-sockaddr! addr ip-bytes port))
                                     (rc (if (eq? filled 'filled)
                                             (uv-tcp-bind ptr addr flag-bits)
                                             filled)))
                                (free-block! addr)
                                rc))))))))
        (unless (eqv? rc 0)
          (raise (step-refusal rc 'uv-tcp-bind! tcp))))))

  ;; query-sockaddr : uv-tcp procedure boolean symbol
  ;;                  -> (or exact-nonnegative-integer
  ;;                         (pair (or string #f) exact-nonnegative-integer))
  ;; TCP's port, or its address and port when ADDRESS?, as NATIVE
  ;; (uv_tcp_getsockname or uv_tcp_getpeername) reports them. One
  ;; interrupt-free step checks again that this thread owns the loop and
  ;; that the client is open, and allocates the sockaddr and its in/out
  ;; length in one block, asks libuv, reads the answer out and frees the
  ;; block (#86). So no engine can split the call from those checks, or drop
  ;; it holding the block (tests/test-handle-steps.sps).
  (define (query-sockaddr tcp native address? who)
    (require-open-tcp tcp who)
    (let* ((storage (sizeof-sockaddr-storage))
           (len-offset (align-16 storage))
           (port-offset (offsetof-sockaddr-in-sin-port))
           (answer
            (one-step
             (let ((ptr (owned-handle-ptr tcp)))
               (if (symbol? ptr)
                   ptr
                   (let ((block (alloc-block (+ len-offset (c-int-size)))))
                     (if (zero? block)
                         'no-memory
                         (let* ((len (+ block len-offset))
                                (rc (if (try-c-int-set! len storage)
                                        (native ptr block len)
                                        'sockaddr-length-not-set))
                                (answer
                                 (cond
                                   ((not (eqv? rc 0)) rc)
                                   ((< (c-int-ref len) (+ port-offset 2))
                                    'sockaddr-too-small-for-a-port)
                                   (address?
                                    (cons (sockaddr->address-string block)
                                          (read-net-u16 block port-offset)))
                                   (else (read-net-u16 block port-offset)))))
                           (free-block! block)
                           answer))))))))
      (if (or (pair? answer) (and (fixnum? answer) (fx>=? answer 0)))
          answer
          (raise (step-refusal answer who tcp)))))

  ;; uv-tcp-getsockname-port : uv-tcp -> exact-nonnegative-integer
  (define (uv-tcp-getsockname-port tcp)
    (query-sockaddr tcp uv-tcp-getsockname #f 'uv-tcp-getsockname-port))

  ;; uv-tcp-peer-address : uv-tcp
  ;;                       -> (values (or string #f) exact-nonnegative-integer)
  ;; An unconnected handle raises the native ENOTCONN condition.
  (define (uv-tcp-peer-address tcp)
    (let ((answer (query-sockaddr tcp uv-tcp-getpeername-native #t
                                  'uv-tcp-peer-address)))
      (values (car answer) (cdr answer))))

  ;; uv-tcp-sockname-address : uv-tcp
  ;;                           -> (values (or string #f) exact-nonnegative-integer)
  ;; A bound, unconnected handle already has a local address.
  (define (uv-tcp-sockname-address tcp)
    (let ((answer (query-sockaddr tcp uv-tcp-getsockname #t
                                  'uv-tcp-sockname-address)))
      (values (car answer) (cdr answer))))

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
                                                       count-tcp-new!)))
                     (if (not (uv-handle? client))
                         client
                         (let ((rc (uv-accept server-ptr (handle-ptr client))))
                           (if (zero? rc)
                               client
                               (begin (begin-close! client #f) rc))))))))))
      (cond ((uv-handle? accepted) accepted)
            ((eq? accepted 'wrong-thread) (raise (wrong-thread-refusal loop 'uv-accept!)))
            (else (raise (step-refusal accepted 'uv-accept! server))))))

  ;; uv-tcp-connect! : uv-tcp string exact-nonnegative-integer procedure
  ;;                   -> uv-request
  ;; Co-allocate the sockaddr with the request because retention varies by OS.
  ;; The address is read once, by validate-address, and libuv parses that copy.
  ;; One interrupt-free step checks again that this thread owns the loop and
  ;; that the client is open, and allocates, fills, registers and counts the
  ;; request and starts it (#85). So no engine can split the connect from
  ;; those checks, or drop it holding a request libuv has not taken
  ;; (tests/test-request-steps.sps).
  (define (uv-tcp-connect! tcp ip port on-connect)
    (require-open-tcp tcp 'uv-tcp-connect!)
    (let ((ip-bytes (validate-address ip 'uv-tcp-connect!)))
      (require-port port 'uv-tcp-connect!)
      (require-callback on-connect 'uv-tcp-connect! 'on-connect-not-a-procedure)
      (let* ((loop (handle-loop tcp))
             (addr-offset (align-16 (uv-req-size (uv-connect-req-type))))
             (size (+ addr-offset (sizeof-sockaddr-storage)))
             (started
              (one-step
               (let ((ptr (owned-handle-ptr tcp)))
                 (if (symbol? ptr)
                     ptr
                     (let ((block (alloc-block size)))
                       (if (zero? block)
                           'no-memory
                           (let* ((addr (+ block addr-offset))
                                  (filled (try-fill-sockaddr! addr ip-bytes port)))
                             (if (eq? filled 'filled)
                                 (submit-request!
                                  block (%make-uv-req-record block 'connect tcp on-connect)
                                  'connect-req loop
                                  count-connect-req-new! count-connect-req-free!
                                  (uv-tcp-connect-native block ptr addr))
                                 (begin (free-block! block) filled))))))))))
        (cond ((uv-req? started) started)
              ((eq? started 'wrong-thread)
               (raise (wrong-thread-refusal loop 'uv-tcp-connect!)))
              (else (raise (step-refusal started 'uv-tcp-connect! tcp)))))))

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
