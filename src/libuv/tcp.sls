#!r6rs
;;; (libuv tcp) -- libuv's TCP verbs, as a legible mirror (design spec S1):
;;; init, bind, getsockname, listen, accept, connect, write, shutdown, and
;;; the one socket option v0.1 needs. Closing a TCP handle is (libuv
;;; handle)'s uv-close!, because the close protocol is generic.
;;;
;;; Reading is here too, as of Stage 5: uv-read-start! / uv-read-stop! and
;;; the per-handle buffer of design spec S6. The alloc and read DISPATCHERS
;;; live in (libuv private handles) with every other dispatcher; what belongs
;;; here is the buffer's allocation and the two verbs that arm and disarm the
;;; read.
;;;
;;; NO PROCEDURE HERE TAKES OR RETURNS A POINTER. A TCP handle is an opaque
;;; record and make-uv-tcp is the only way to get one; the request records
;;; uv-write! / uv-shutdown! / uv-tcp-connect! answer with are opaque too --
;;; they exist so a caller can hold on to an in-flight request (and so a
;;; future uv_cancel binding has something to take), not so anything can be
;;; read out of them.
;;;
;;; TWO RULES RUN THROUGH EVERY PROCEDURE BELOW, and both are design spec
;;; requirements rather than style:
;;;
;;;   * EVERY ARGUMENT IS VALIDATED BEFORE THE FIRST ALLOCATION. Not merely
;;;     before the native call: a span check that runs after the block has
;;;     been foreign-alloc'd leaks it on the failure path, and the leak is
;;;     invisible to everything except Valgrind. tests/test-tcp.sps asserts
;;;     the allocation counters are unchanged across a refused write.
;;;   * A FAILED NATIVE CALL LEAVES NOTHING HALF-BUILT. Every path that has
;;;     allocated, registered or counted something undoes exactly that much
;;;     before the condition escapes (design spec S5, S7).
(library (libuv tcp)
  (export make-uv-tcp
          uv-tcp-bind! uv-tcp-getsockname-port
          uv-listen! uv-accept! uv-tcp-connect!
          uv-write! uv-shutdown! uv-tcp-nodelay!
          uv-read-start! uv-read-stop!)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))

  ;; --- argument predicates ------------------------------------------------
  ;; A TCP handle, and open. The kind check comes FIRST and is separate from
  ;; require-open-handle's: a timer is a perfectly good open handle, and
  ;; handing a uv_timer_t to uv_tcp_bind is undefined behaviour rather than
  ;; an errno -- there is no return code that says "that was the wrong kind
  ;; of handle". A closed TCP handle still answers &uv-handle-closed with
  ;; kind 'tcp, which is the documented lifecycle error (design spec S9).
  (define (require-open-tcp tcp who)
    (unless (uv-tcp-record? tcp)
      (raise (make-uv-invalid-argument who 'not-a-uv-tcp)))
    (require-open-handle tcp who)
    tcp)

  ;; A port as libuv takes it: an exact integer in 0..65535, where 0 means
  ;; "let the kernel choose" for bind. Checked explicitly because the FFI
  ;; declares `int`, so a bignum or an inexact number is either a Chez
  ;; marshalling error from deep inside the call or a silently truncated
  ;; port number.
  (define (valid-port? n)
    (and (integer? n) (exact? n) (>= n 0) (<= n 65535)))

  (define (require-port port who)
    (unless (valid-port? port)
      (raise (make-uv-invalid-argument who 'port-out-of-range))))

  (define (require-address ip who)
    (unless (string? ip)
      (raise (make-uv-invalid-argument who 'address-not-a-string))))

  (define (require-callback proc who reason)
    (unless (procedure? proc)
      (raise (make-uv-invalid-argument who reason))))

  ;; --- filling a sockaddr (spike FINDINGS Q3) -----------------------------
  ;; IPv4 first, IPv6 second, and a failure of both is a CALLER error rather
  ;; than an errno: uv_ip4_addr's UV_EINVAL says "this text is not a dotted
  ;; quad", which is only interesting once the IPv6 reading has also been
  ;; refused. Reporting the first attempt's errno would name a family the
  ;; caller never mentioned.
  ;;
  ;; The scratch is written in place; the caller owns it and frees it.
  (define (fill-sockaddr! addr ip port who)
    (unless (or (zero? (uv-ip4-addr ip port addr))
                (zero? (uv-ip6-addr ip port addr)))
      (raise (make-uv-invalid-argument who 'bad-address))))

  ;; --- construction (design spec S5) --------------------------------------
  ;; The size comes from uv_handle_size(UV_TCP) -- the RUNNING library's own
  ;; answer, with UV_TCP itself looked up from the shim's table rather than
  ;; transcribed (ADR-0005).
  ;;
  ;; Order on the failure path is the specification, exactly as it is for
  ;; make-uv-timer: a nonzero uv_tcp_init frees the block before the
  ;; condition escapes, and nothing has been registered or counted yet, so
  ;; there is no half-built handle for a caller to find.
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

  ;; --- binding ------------------------------------------------------------
  ;; The sockaddr is scratch: uv_tcp_bind copies what it needs out of it
  ;; before returning, so it is freed on EVERY path out of this procedure --
  ;; the guard's, and the normal one. (The connect request's sockaddr is a
  ;; different case entirely; see uv-tcp-connect! below.)
  ;;
  ;; sockaddr_storage, not sockaddr_in: it is the union big enough for either
  ;; family, and its size comes from the shim's sizeof rather than from a
  ;; literal 128 (ADR-0005).
  (define (uv-tcp-bind! tcp ip port)
    (require-open-tcp tcp 'uv-tcp-bind!)
    (require-address ip 'uv-tcp-bind!)
    (require-port port 'uv-tcp-bind!)
    (let ((addr (alloc-zeroed (sizeof-sockaddr-storage))))
      (guard (e (#t (free! addr) (raise e)))
        (fill-sockaddr! addr ip port 'uv-tcp-bind!)
        ;; flags 0: no UV_TCP_IPV6ONLY. v0.1 binds what it tests.
        (uv-check (uv-tcp-bind (handle-pointer tcp 'uv-tcp-bind!) addr 0)
                  'uv-tcp-bind!))
      (free! addr)))

  ;; --- the bound port (ADR-0010's ephemeral-port dance) -------------------
  ;; PORT ONLY, and the name says so. Returning a decoded address as well
  ;; would mean deciding what an address IS in this binding's vocabulary --
  ;; a string? a family plus bytes? -- and v0.1 has exactly one caller for
  ;; this: a test (or a server) that bound port 0 and needs to know which
  ;; port the kernel chose.
  ;;
  ;; sin_port is at the same offset for AF_INET and AF_INET6 (both put it
  ;; immediately after the family), and it is stored in NETWORK byte order,
  ;; which is why read-net-u16 exists: reading it as a host u16 would answer
  ;; a byte-swapped number that is still in range and still looks like a port
  ;; (spike FINDINGS Q3). The family byte is deliberately NOT read here --
  ;; its offset and width differ between Darwin and Linux (FINDINGS Q3 again)
  ;; and nothing in this procedure needs it.
  ;;
  ;; THE NAMELEN IS READ BACK, not merely written. libuv's out-parameter says
  ;; how many bytes of `addr` it actually filled in (16 for a sockaddr_in, 28
  ;; for a sockaddr_in6), and the two bytes this procedure decodes have to be
  ;; INSIDE that. Without the check, a short answer would be decoded out of
  ;; the zeroed tail of the scratch and returned as port 0 -- a plausible,
  ;; in-range, entirely wrong number, which is the same failure shape the
  ;; byte-order note above exists to prevent. The refusal arm is not
  ;; reachable through this API on either supported platform (recorded in
  ;; .plans/stage-5-mutation-log.md); the acceptance arm is asserted at two
  ;; different real namelens, IPv4's and IPv6's, so a check written too
  ;; strictly fails a test.
  ;;
  ;; Everything runs inside the guard, including the decode, so there is one
  ;; freeing rule for every path out rather than one for the native call and
  ;; another for the arithmetic after it.
  (define (uv-tcp-getsockname-port tcp)
    (require-open-tcp tcp 'uv-tcp-getsockname-port)
    (let ((addr (alloc-zeroed (sizeof-sockaddr-storage)))
          (len  (alloc-zeroed (c-int-size))))
      (guard (e (#t (free! addr) (free! len) (raise e)))
        ;; Seeded with the buffer's real size, as an in/out parameter:
        ;; libuv writes back how much it used (16 for sockaddr_in).
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

  ;; --- listening ----------------------------------------------------------
  ;; The callback is stored BEFORE uv_listen, not after: a connection can
  ;; arrive as soon as the socket is listening, and a callback stored
  ;; afterwards would be a race on a loop that is already running (the same
  ;; reasoning as uv-timer-start!).
  ;;
  ;; on-connection is called with ONE argument, the error: #f on success, an
  ;; &uv-errno-error object otherwise. It is not handed the server handle,
  ;; because unlike a timer -- which may be armed far from where it was
  ;; created -- a listener is always in lexical scope at its own uv-listen!
  ;; call, which is the only place this callback can be written.
  (define (uv-listen! tcp backlog on-connection)
    (require-open-tcp tcp 'uv-listen!)
    (unless (and (integer? backlog) (exact? backlog) (>= backlog 0))
      (raise (make-uv-invalid-argument 'uv-listen! 'backlog-out-of-range)))
    (require-callback on-connection 'uv-listen! 'on-connection-not-a-procedure)
    (set-tcp-on-connection! tcp on-connection)
    (uv-check (uv-listen-native (handle-pointer tcp 'uv-listen!) backlog)
              'uv-listen!))

  ;; --- accepting ----------------------------------------------------------
  ;; Answers a NEW, open TCP handle on the server's own loop. Legal (and
  ;; required) from inside on-connection; libuv answers UV_EAGAIN when
  ;; nothing is queued, which surfaces as &uv-errno-error with errno 'EAGAIN.
  ;;
  ;; THE FAILURE PATH IS THE INTERESTING ONE. The client handle has already
  ;; been through uv_tcp_init by the time uv_accept can fail, and a
  ;; successfully-initialised libuv handle's memory may only be released by
  ;; its close callback -- foreign-free'ing it here would be freeing a block
  ;; libuv still has in its handle queue. So the fresh handle goes through
  ;; the NORMAL close path (uv-close!, close_cb, the one freeing site), and
  ;; only then does the condition escape. The close COMPLETES on the next
  ;; loop iteration, like every other close in this binding; inside an
  ;; on-connection callback that is the iteration already in progress.
  (define (uv-accept! server)
    (require-open-tcp server 'uv-accept!)
    (let ((client (make-uv-tcp (handle-loop server))))
      (guard (e (#t (close-handle! client) (raise e)))
        (uv-check (uv-accept (handle-pointer server 'uv-accept!)
                             (handle-pointer client 'uv-accept!))
                  'uv-accept!))
      client))

  ;; --- connecting ---------------------------------------------------------
  ;; ONE foreign-alloc: [uv_connect_t | pad to 16 | sockaddr_storage].
  ;;
  ;; WHY CO-ALLOCATED. Whether libuv retains the caller's `addr` pointer past
  ;; the uv_tcp_connect call is platform-dependent, and design spec S7
  ;; settles the question by construction instead of per platform: the
  ;; sockaddr lives in the request's own block, so it is alive for exactly as
  ;; long as the request is and dies in the same single free.
  (define (uv-tcp-connect! tcp ip port on-connect)
    (require-open-tcp tcp 'uv-tcp-connect!)
    (require-address ip 'uv-tcp-connect!)
    (require-port port 'uv-tcp-connect!)
    (require-callback on-connect 'uv-tcp-connect! 'on-connect-not-a-procedure)
    (let* ((addr-offset (align-16 (uv-req-size (uv-connect-req-type))))
           (block (alloc-zeroed (+ addr-offset (sizeof-sockaddr-storage))))
           (addr (+ block addr-offset)))
      ;; Nothing is registered or counted yet, so a bad address unwinds with
      ;; one free and no other bookkeeping.
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

  ;; --- writing ------------------------------------------------------------
  ;; (uv-write! tcp bv on-complete)
  ;; (uv-write! tcp bv start end on-complete)
  ;;
  ;; ONE foreign-alloc: [uv_write_t | pad to 16 | uv_buf_t | payload copy]
  ;; (design spec S7). One block means one free, in one place -- the
  ;; write-done dispatcher -- and one debug counter for the whole thing.
  ;;
  ;; The payload is COPIED (ADR-0009). The caller's bytevector is free to be
  ;; mutated or collected the instant this returns: nothing libuv holds
  ;; points into the Scheme heap, so there is no pinning, no lock-object, and
  ;; no window in which a moving collector could invalidate an in-flight
  ;; write.
  ;;
  ;; The span is `[start, end)`, matching bytevector-copy! and every other
  ;; R6RS range. An empty span is legal and is passed to libuv as a
  ;; zero-length buffer.
  (define uv-write!
    (case-lambda
      ((tcp bv on-complete)
       ;; The implicit span is computed from the bytevector, so both checks
       ;; have to happen HERE too rather than waiting for the general clause
       ;; -- and in the same order, so which condition a caller gets does not
       ;; depend on which arity they used.
       (require-open-tcp tcp 'uv-write!)
       (unless (bytevector? bv)
         (raise (make-uv-invalid-argument 'uv-write! 'source-not-a-bytevector)))
       (uv-write! tcp bv 0 (bytevector-length bv) on-complete))
      ((tcp bv start end on-complete)
       (require-open-tcp tcp 'uv-write!)
       (unless (bytevector? bv)
         (raise (make-uv-invalid-argument 'uv-write! 'source-not-a-bytevector)))
       (require-callback on-complete 'uv-write! 'on-complete-not-a-procedure)
       (unless (and (integer? start) (exact? start)
                    (integer? end) (exact? end)
                    (<= 0 start) (<= start end)
                    (<= end (bytevector-length bv)))
         (raise (make-uv-invalid-argument 'uv-write! 'span-out-of-range)))
       ;; EVERY CHECK ABOVE, THE FIRST ALLOCATION BELOW. Moving one of them
       ;; the other way leaks the block on the failure path.
       (let* ((len (- end start))
              (buf-offset (align-16 (uv-req-size (uv-write-req-type))))
              (payload-offset (+ buf-offset (sizeof-uv-buf-t)))
              ;; max 1: an empty write still needs its payload pointer to
              ;; address memory this block actually owns, rather than one
              ;; byte past its end.
              (block (alloc-zeroed (+ payload-offset (max len 1))))
              (payload (+ block payload-offset)))
         (copy-in! payload bv start len)
         (uv-buf-set! (+ block buf-offset) payload len)
         (let ((req (%make-uv-req-record block 'write tcp on-complete)))
           (registry-register! block 'write-req (handle-loop tcp) req)
           (count-write-req-new!)
           (guard (e (#t (abandon-request! req) (count-write-req-free!)
                         (raise e)))
             (uv-check (uv-write-native block
                                        (handle-pointer tcp 'uv-write!)
                                        (+ block buf-offset)
                                        1)
                       'uv-write!))
           req)))))

  ;; --- shutting down the write side ---------------------------------------
  ;; A plain request block: uv_shutdown_t and nothing else. Same pattern as
  ;; the other two, and the same single freeing site.
  (define (uv-shutdown! tcp on-shutdown)
    (require-open-tcp tcp 'uv-shutdown!)
    (require-callback on-shutdown 'uv-shutdown! 'on-shutdown-not-a-procedure)
    (let* ((block (alloc-zeroed (uv-req-size (uv-shutdown-req-type))))
           (req (%make-uv-req-record block 'shutdown tcp on-shutdown)))
      (registry-register! block 'shutdown-req (handle-loop tcp) req)
      (guard (e (#t (abandon-request! req) (raise e)))
        (uv-check (uv-shutdown-native block (handle-pointer tcp 'uv-shutdown!))
                  'uv-shutdown!))
      req))

  ;; --- reading (design spec S6) -------------------------------------------
  ;; (uv-read-start! tcp on-data on-eof on-error [buffer-size])
  ;;
  ;;   on-data  (bv start end) -- a FRESH bytevector per delivery, handed as a
  ;;            SPAN so a future zero-copy variant can answer a sub-range of a
  ;;            larger buffer without changing the call shape (ADR-0009).
  ;;   on-eof   () -- the end of the stream, which is NOT an error and is
  ;;            never wrapped in a condition (design spec S6, ADR-0006).
  ;;   on-error (condition) -- a plain object, never raised across the
  ;;            callback boundary (design spec S8). The handle is not closed:
  ;;            what to do about a read error is the caller's decision.
  ;;
  ;; All three are REQUIRED. There is no "just give me the data" arity,
  ;; because a stream whose end and whose failure both go unnoticed is not a
  ;; simplification -- it is the two bugs this split exists to prevent.
  (define default-read-buffer-size 65536)

  (define uv-read-start!
    (case-lambda
      ;; #f, not the default size: "the caller did not ask for a size" and
      ;; "the caller asked for 65536" are different questions to the
      ;; buffer-size rule below, and collapsing them here would make a
      ;; re-start with the size omitted fail against any handle whose buffer
      ;; was fixed at anything else.
      ((tcp on-data on-eof on-error)
       (start-reading! tcp on-data on-eof on-error #f))
      ((tcp on-data on-eof on-error buffer-size)
       (start-reading! tcp on-data on-eof on-error buffer-size))))

  ;; EVERY CHECK FIRST, THE ALLOCATION AFTER THEM, the native call after
  ;; that, and the record updated only once libuv has said yes -- the same
  ;; order, and for the same reasons, as uv-write!.
  ;;
  ;; The callbacks are stored AFTER the native call, unlike uv-listen!'s: a
  ;; uv_read_start that libuv refuses (UV_EALREADY on a handle that is
  ;; already reading, UV_ENOTCONN on one that is not connected) must not
  ;; leave this handle's stored callbacks swapped for a read that never
  ;; started. Nothing can be delivered in the window either way, since libuv
  ;; only ever calls read_cb from inside uv_run.
  (define (start-reading! tcp on-data on-eof on-error buffer-size)
    (require-open-tcp tcp 'uv-read-start!)
    (require-callback on-data 'uv-read-start! 'on-data-not-a-procedure)
    (require-callback on-eof 'uv-read-start! 'on-eof-not-a-procedure)
    (require-callback on-error 'uv-read-start! 'on-error-not-a-procedure)
    (when buffer-size
      (unless (and (integer? buffer-size) (exact? buffer-size)
                   (positive? buffer-size))
        (raise (make-uv-invalid-argument 'uv-read-start!
                                         'buffer-size-out-of-range))))
    (ensure-read-buffer! tcp buffer-size)
    (uv-check (uv-read-start-native (handle-pointer tcp 'uv-read-start!))
              'uv-read-start!)
    (set-tcp-on-data! tcp on-data)
    (set-tcp-on-eof! tcp on-eof)
    (set-tcp-on-error! tcp on-error)
    (set-tcp-reading! tcp #t))

  ;; The per-handle buffer of design spec S6, allocated by the FIRST
  ;; uv-read-start! and never again -- which is what lets the alloc dispatcher
  ;; be infallible: it has an already-allocated pointer to hand back on every
  ;; read and never allocates on the hot path.
  ;;
  ;; ITS SIZE IS FIXED BY THAT FIRST CALL, and a later call asking for a
  ;; different explicit size is REFUSED rather than honoured. Honouring it
  ;; would mean freeing the old buffer here, and design spec S6 makes the
  ;; close dispatcher the only place that buffer may ever be freed -- so that
  ;; a read completion queued against it (Windows' overlapped model) cannot
  ;; outlive it. A caller who wants a different size closes the handle.
  ;;
  ;; A call that omits the size is not asking for anything, so it is always
  ;; allowed. That is what makes re-starting after a stop the cheap operation
  ;; backpressure needs it to be.
  ;;
  ;; NOTHING FREES THE BUFFER ON A FAILURE PATH, including one where
  ;; uv_read_start goes on to fail: the buffer belongs to the HANDLE, not to
  ;; the read, and the close dispatcher will free it exactly once.
  (define (ensure-read-buffer! tcp buffer-size)
    (if (zero? (tcp-read-buf tcp))
        (let ((size (or buffer-size default-read-buffer-size)))
          (set-tcp-read-buf! tcp (alloc-zeroed size))
          (set-tcp-read-buf-len! tcp size)
          (count-read-buffer-new!))
        (when (and buffer-size (not (= buffer-size (tcp-read-buf-len tcp))))
          (raise (make-uv-invalid-argument 'uv-read-start!
                                           'buffer-size-fixed)))))

  ;; Stopping a stream that is not reading is rc 0 at the libuv level, so this
  ;; is idempotent without a state test of its own. The stored callbacks and
  ;; the buffer are left alone on purpose: a stop is backpressure, not a
  ;; teardown, and the next uv-read-start! is meant to be able to pass the
  ;; same callbacks against the same buffer (design spec S6).
  (define (uv-read-stop! tcp)
    (require-open-tcp tcp 'uv-read-stop!)
    (uv-check (uv-read-stop (handle-pointer tcp 'uv-read-stop!))
              'uv-read-stop!)
    (set-tcp-reading! tcp #f))

  ;; --- socket options -----------------------------------------------------
  ;; The one v0.1 needs. A boolean is required rather than accepted-and-
  ;; coerced: `(uv-tcp-nodelay! t 0)` would otherwise mean "on", since 0 is
  ;; true in Scheme (AGENTS.md's named trap) while meaning "off" in C.
  (define (uv-tcp-nodelay! tcp enable?)
    (require-open-tcp tcp 'uv-tcp-nodelay!)
    (unless (boolean? enable?)
      (raise (make-uv-invalid-argument 'uv-tcp-nodelay! 'enable-not-a-boolean)))
    (uv-check (uv-tcp-nodelay (handle-pointer tcp 'uv-tcp-nodelay!)
                              (if enable? 1 0))
              'uv-tcp-nodelay!))

  ;; --- shared helpers -----------------------------------------------------
  ;; Undo a registration that a synchronous native failure has just made
  ;; pointless: pop the entry, free the block, zero the record's pointer.
  ;; This is the SAME order the completion dispatcher uses, minus the
  ;; callback -- there is nothing to report to, since the caller is about to
  ;; receive the condition itself. The counter, where there is one, is bumped
  ;; by the caller so that each site names its own class.
  (define (abandon-request! req)
    (let ((ptr (req-ptr req)))
      (registry-deregister! ptr)
      (free! ptr)
      (set-req-ptr! req 0)))

  ;; Round up to a 16-byte boundary. The uv_buf_t and sockaddr_storage that
  ;; follow a request inside its block contain pointers and (on some targets)
  ;; 16-byte-aligned members, and uv_req_size answers the request's size, not
  ;; a padded stride -- so the offset is aligned here rather than assumed.
  ;; 16 rather than 8: it is the strictest fundamental alignment on every
  ;; target this binding supports, so one rule covers both structs.
  (define (align-16 n) (* 16 (div (+ n 15) 16))))
