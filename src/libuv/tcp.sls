#!r6rs
;;; (libuv tcp) -- libuv's TCP verbs, as a legible mirror (design spec S1):
;;; init, bind, getsockname, listen, accept, connect, and the one socket
;;; option v0.1 needs. Closing a TCP handle is (libuv handle)'s uv-close!,
;;; because the close protocol is generic.
;;;
;;; write/shutdown/read-start/read-stop moved to (libuv stream) in Task 7
;;; (ADR-0014): they gate on uv-stream-record?, not uv-tcp-record?, so a
;;; pipe can use them too once uv-spawn! has connected one. This library
;;; RE-EXPORTS all four below, so every importer of (libuv tcp) that wrote
;;; uv-write! / uv-shutdown! / uv-read-start! / uv-read-stop! compiles
;;; unchanged -- the verbs moved, the import surface did not.
;;;
;;; NO PROCEDURE HERE TAKES OR RETURNS A POINTER. A TCP handle is an opaque
;;; record and make-uv-tcp is the only way to get one; the request record
;;; uv-tcp-connect! answers with is opaque too -- it exists so a caller can
;;; hold on to an in-flight request (and so a future uv_cancel binding has
;;; something to take), not so anything can be read out of it.
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
          uv-tcp-nodelay!
          ;; re-exported from (libuv stream) (ADR-0014): the verbs moved,
          ;; the import surface did not.
          uv-write! uv-shutdown! uv-read-start! uv-read-stop!)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles)
          (libuv stream))

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

  ;; require-callback moved to (libuv private native) in Task 4 (v0.3); this
  ;; file kept its own private copy alongside an `except` import until Task 7
  ;; moved the verbs that used it (uv-write! / uv-shutdown! / uv-read-start!
  ;; / uv-read-stop!, now (libuv stream)) -- uv-listen! and uv-tcp-connect!
  ;; below now use the native-exported one, imported plainly above.

  ;; fill-sockaddr! and align-16 were private here through v0.1; as of v0.2
  ;; Stage 2 both live in (libuv private native) (design spec v0.2 S5.1),
  ;; imported above, so dns.sls can share them without a second copy.
  ;; abandon-request! followed in v0.2 Stage 3: it lives in (libuv private
  ;; handles) beside complete-request! (design spec v0.2 S5.3, ADR-0011),
  ;; imported above, for the same reason -- dns.sls's start calls need the
  ;; identical sync-failure undo the three request verbs below guard with.
  ;; require-address and require-port went the same way post-v0.2 (the
  ;; whole-branch review's duplication finding): dns.sls had restated them
  ;; verbatim, so ADR-0012's vocabulary now lives beside fill-sockaddr!.

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
              'uv-tcp-nodelay!)))
