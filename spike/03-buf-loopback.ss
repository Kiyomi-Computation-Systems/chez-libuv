;;; spike/03-buf-loopback.ss — Q3: build a uv_buf_t by hand, then run the
;;; smallest possible in-process TCP loopback exchange through it.
;;;
;;; Usage:
;;;   chez --script spike/03-buf-loopback.ss <libuv.dylib> [mode]
;;; where [mode] is one of:
;;;   normal              (default) the plain loopback exchange
;;;   raise-in-read-cb    escape from read_cb, then close the handles Scheme
;;;                       side and drain
;;;   drain-before-close  escape from read_cb, then leave every handle open
;;;                       and the read STILL STARTED and drain — does the
;;;                       abandoned iteration's UV_EOF get redelivered?
;;;   no-recovery         escape from read_cb, then call uv_loop_close
;;;                       immediately with the handles still open
;;;
;;; What this proves:
;;;   * uv_buf_t can be constructed and read back through foreign-alloc /
;;;     foreign-set! / foreign-ref at probe-verified offsets (no define-ftype
;;;     needed to get the layout right, though Stage 1 will use one).
;;;   * All six callback signatures the binding needs round-trip:
;;;     connection_cb, connect_cb, alloc_cb, read_cb, write_cb, close_cb.
;;;   * `ssize_t` is a real Chez foreign type and a negative nread (UV_EOF,
;;;     -4095) arrives intact rather than as a huge unsigned value.
;;;   * The ephemeral-port dance works: bind to 127.0.0.1:0, read the real
;;;     port back with uv_tcp_getsockname, ntohs it by hand from
;;;     offsetof(sockaddr_in, sin_port) (ADR-0010's loopback test strategy).
;;;
;;; The three raise modes re-run Q2's escape experiment from a callback that
;;; fires from INSIDE uv__io_poll rather than from uv__run_timers — a
;;; materially deeper libuv C frame, with in-progress poll state. See
;;; FINDINGS.md Q2 for why that distinction matters. `drain-before-close` and
;;; `no-recovery` exist specifically so the two claims FINDINGS makes about
;;; the aftermath of an escape are measured rather than asserted.
;;;
;;; Every offset, size, and enum value below comes from spike/probe.
;;;
;;; The foreign-callables here are deliberately left locked for the life of
;;; the process and never unlocked — ADR-0008's process-lifetime rule, which
;;; is what makes the entry points libuv retains safe to hold.

(import (chezscheme))

(define argv (command-line-arguments))
(define (usage)
  (display "usage: 03-buf-loopback.ss <libuv.dylib> \
[normal|raise-in-read-cb|drain-before-close|no-recovery]\n")
  (exit 2))

(define lib-path (if (null? argv) (usage) (car argv)))

(define mode
  (if (or (null? argv) (null? (cdr argv))) "normal" (cadr argv)))

(unless (member mode '("normal" "raise-in-read-cb" "drain-before-close" "no-recovery"))
  (usage))

;; All three non-normal modes raise from read_cb; they differ only in what
;; they do with the loop afterwards.
(define raise-in-read-cb? (not (string=? mode "normal")))

;;; --- probe-supplied constants (spike/probe output, verbatim) ---------------
(define UV_TCP            12)
(define UV_TIMER          13)
(define UV_RUN_DEFAULT     0)
(define UV_CONNECT         2)
(define UV_WRITE           3)
(define UV_EOF         -4095)
(define AF_INET            2)

(define SIZEOF_UV_BUF_T         16)
(define OFFSETOF_UV_BUF_BASE     0)
(define OFFSETOF_UV_BUF_LEN      8)
(define SIZEOF_SOCKADDR_STORAGE 128)
(define SIZEOF_SOCKADDR_IN      16)
;; Darwin/BSD layout: sin_len is byte 0, so sin_family is a ONE-byte field at
;; offset 1. Linux has no sin_len and sin_family is a two-byte field at 0.
;; sin_port sits at offset 2 on both, which is why the port read below is
;; portable even though the family read is not. (probe output; see FINDINGS.)
(define OFFSETOF_SIN_FAMILY      1)
(define SIZEOF_SIN_FAMILY        1)
(define OFFSETOF_SIN_PORT        2)
(define OFFSETOF_SIN_ADDR        4)

(define READ-BUFFER-SIZE 65536)
(define PAYLOAD "hello")

;;; --- load, THEN bind --------------------------------------------------------
(load-shared-object lib-path)

(define uv-loop-size       (foreign-procedure "uv_loop_size"       ()               size_t))
(define uv-handle-size     (foreign-procedure "uv_handle_size"     (int)            size_t))
(define uv-req-size        (foreign-procedure "uv_req_size"        (int)            size_t))
(define uv-loop-init       (foreign-procedure "uv_loop_init"       (uptr)           int))
(define uv-loop-close      (foreign-procedure "uv_loop_close"      (uptr)           int))
(define uv-loop-alive      (foreign-procedure "uv_loop_alive"      (uptr)           int))
(define uv-run             (foreign-procedure "uv_run"             (uptr int)       int))
(define uv-close           (foreign-procedure "uv_close"           (uptr uptr)      void))
(define uv-is-closing      (foreign-procedure "uv_is_closing"      (uptr)           int))
(define uv-tcp-init        (foreign-procedure "uv_tcp_init"        (uptr uptr)      int))
(define uv-tcp-bind        (foreign-procedure "uv_tcp_bind"        (uptr uptr unsigned-int) int))
(define uv-tcp-getsockname (foreign-procedure "uv_tcp_getsockname" (uptr uptr uptr) int))
(define uv-tcp-connect     (foreign-procedure "uv_tcp_connect"     (uptr uptr uptr uptr) int))
(define uv-listen          (foreign-procedure "uv_listen"          (uptr int uptr)  int))
(define uv-accept          (foreign-procedure "uv_accept"          (uptr uptr)      int))
(define uv-read-start      (foreign-procedure "uv_read_start"      (uptr uptr uptr) int))
(define uv-read-stop       (foreign-procedure "uv_read_stop"       (uptr)           int))
(define uv-write           (foreign-procedure "uv_write"
                                              (uptr uptr uptr unsigned-int uptr) int))
(define uv-ip4-addr        (foreign-procedure "uv_ip4_addr"        (uptr int uptr)  int))
(define uv-stop            (foreign-procedure "uv_stop"            (uptr)           void))
(define uv-timer-init      (foreign-procedure "uv_timer_init"      (uptr uptr)      int))
(define uv-timer-start     (foreign-procedure "uv_timer_start"
                                              (uptr uptr unsigned-64 unsigned-64) int))
(define uv-strerror        (foreign-procedure "uv_strerror"        (int)            uptr))
(define uv-err-name        (foreign-procedure "uv_err_name"        (int)            uptr))

(define (c-string->string addr)
  (if (= addr 0)
      #f
      (let loop ((i 0) (acc '()))
        (let ((b (foreign-ref 'unsigned-8 addr i)))
          (if (= b 0)
              (utf8->string (u8-list->bytevector (reverse acc)))
              (loop (+ i 1) (cons b acc)))))))

(define (alloc-zeroed n)
  (let ((p (foreign-alloc n)))
    (do ((i 0 (+ i 1))) ((= i n) p)
      (foreign-set! 'unsigned-8 p i 0))))

(define (string->c-string s)
  (let* ((bv (string->utf8 s))
         (n  (bytevector-length bv))
         (p  (foreign-alloc (+ n 1))))
    (do ((i 0 (+ i 1))) ((= i n))
      (foreign-set! 'unsigned-8 p i (bytevector-u8-ref bv i)))
    (foreign-set! 'unsigned-8 p n 0)
    p))

;; Chez's (chezscheme) has no `bytevector-append`; this spike needs one to
;; accumulate successive read_cb deliveries.
(define (bv-append a b)
  (let* ((la (bytevector-length a))
         (lb (bytevector-length b))
         (out (make-bytevector (+ la lb))))
    (bytevector-copy! a 0 out 0 la)
    (bytevector-copy! b 0 out la lb)
    out))

(define (foreign-bytes->bytevector addr n)
  (let ((bv (make-bytevector n)))
    (do ((i 0 (+ i 1))) ((= i n) bv)
      (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 addr i)))))

(define (rc-name rc)
  (if (zero? rc)
      "0"
      (format "~d (~a: ~a)" rc (c-string->string (uv-err-name rc))
              (c-string->string (uv-strerror rc)))))

;;; ===========================================================================
;;; Part 0: which foreign types does this Chez actually accept?
;;;
;;; Design spec §4 rule 4 hedges: bind `nread` as `ssize_t`, "falling back to
;;; `iptr` if the spike's round-trip shows Chez has no native `ssize_t`
;;; mapping". This settles that, reproducibly, rather than by assertion.
;;; ===========================================================================
(display "--- part 0: foreign type availability ---\n")
(for-each
 (lambda (t)
   (guard (e (#t (printf "~a: REJECTED -- " t)
                 (display-condition e) (newline)))
     (eval `(foreign-callable (lambda (x) (void)) (,t) void)
           (environment '(chezscheme)))
     (printf "~a: accepted by foreign-callable\n" t)))
 '(ssize_t size_t iptr uptr int integer-64 unsigned-64 long))

;;; ===========================================================================
;;; Part 1: uv_buf_t by hand — construct, then read back through the offsets.
;;; ===========================================================================
(display "\n--- part 1: uv_buf_t built by hand ---\n")

(define payload-bv  (string->utf8 PAYLOAD))
(define payload-len (bytevector-length payload-bv))
(define payload-ptr (foreign-alloc payload-len))
(do ((i 0 (+ i 1))) ((= i payload-len))
  (foreign-set! 'unsigned-8 payload-ptr i (bytevector-u8-ref payload-bv i)))

(define write-buf (alloc-zeroed SIZEOF_UV_BUF_T))
(foreign-set! 'uptr   write-buf OFFSETOF_UV_BUF_BASE payload-ptr)
(foreign-set! 'size_t write-buf OFFSETOF_UV_BUF_LEN  payload-len)

(define readback-base (foreign-ref 'uptr   write-buf OFFSETOF_UV_BUF_BASE))
(define readback-len  (foreign-ref 'size_t write-buf OFFSETOF_UV_BUF_LEN))

(printf "sizeof(uv_buf_t)          = ~d\n" SIZEOF_UV_BUF_T)
(printf "buf.base readback == payload pointer? ~s\n" (= readback-base payload-ptr))
(printf "buf.len  readback         = ~d (payload ~s is ~d bytes)\n"
        readback-len PAYLOAD payload-len)
(printf "bytes at buf.base         = ~s\n"
        (utf8->string (foreign-bytes->bytevector readback-base readback-len)))

;;; ===========================================================================
;;; Part 2: the loopback exchange.
;;; ===========================================================================
(display "\n--- part 2: TCP loopback on 127.0.0.1:0 ---\n")

;;; --- observable state, all seeded with sentinels no success path yields ----
(define connection-cb-calls 0)
(define connect-cb-calls    0)
(define alloc-cb-calls      0)
(define read-cb-calls       0)
(define write-cb-calls      0)
(define close-cb-calls      0)

(define connection-status 'connection-cb-never-fired)
(define connect-status    'connect-cb-never-fired)
(define write-status      'write-cb-never-fired)
(define nread-values      '())            ; every nread libuv delivered, in order
(define received          (make-bytevector 0))
(define alloc-suggested   'alloc-cb-never-fired)
(define read-buf-base-seen 'read-cb-never-fired)
(define eof-seen          #f)
(define read-cb-raise-escaped 'no-raise-attempted)

(define-condition-type &spike-raise &error
  make-spike-raise spike-raise? (where spike-raise-where))

;;; --- foreign memory --------------------------------------------------------
(define loop-ptr    (alloc-zeroed (uv-loop-size)))
(define server-ptr  (alloc-zeroed (uv-handle-size UV_TCP)))
(define client-ptr  (alloc-zeroed (uv-handle-size UV_TCP)))
(define peer-ptr    (alloc-zeroed (uv-handle-size UV_TCP)))
(define connect-req (alloc-zeroed (uv-req-size UV_CONNECT)))
(define write-req   (alloc-zeroed (uv-req-size UV_WRITE)))
(define bind-addr   (alloc-zeroed SIZEOF_SOCKADDR_IN))
(define conn-addr   (alloc-zeroed SIZEOF_SOCKADDR_IN))
(define name-addr   (alloc-zeroed SIZEOF_SOCKADDR_STORAGE))
(define name-len    (alloc-zeroed 4))
(define read-buffer (alloc-zeroed READ-BUFFER-SIZE))
(define loopback-ip (string->c-string "127.0.0.1"))
;; Deadline timer, used only by `drain-before-close` to bound the drain so a
;; non-redelivered EOF cannot hang the script forever (the listening server
;; keeps the loop alive on its own).
(define deadline-ptr   (alloc-zeroed (uv-handle-size UV_TIMER)))
(define DEADLINE-MS    250)
(define deadline-fired 'deadline-never-fired)   ; sentinel

;;; --- the six callbacks, each created once and locked once ------------------
;;; Signatures, from uv.h:
;;;   uv_alloc_cb      void (*)(uv_handle_t*, size_t, uv_buf_t*)
;;;   uv_read_cb       void (*)(uv_stream_t*, ssize_t, const uv_buf_t*)
;;;   uv_write_cb      void (*)(uv_write_t*, int)
;;;   uv_connect_cb    void (*)(uv_connect_t*, int)
;;;   uv_connection_cb void (*)(uv_stream_t*, int)
;;;   uv_close_cb      void (*)(uv_handle_t*)

(define alloc-callable
  (foreign-callable
   (lambda (handle suggested buf)
     (set! alloc-cb-calls (+ alloc-cb-calls 1))
     (when (eq? alloc-suggested 'alloc-cb-never-fired)
       (set! alloc-suggested suggested))
     ;; Infallible: hand back the already-allocated per-handle buffer
     ;; (design spec §6). Never allocates on the hot path.
     (foreign-set! 'uptr   buf OFFSETOF_UV_BUF_BASE read-buffer)
     (foreign-set! 'size_t buf OFFSETOF_UV_BUF_LEN  READ-BUFFER-SIZE))
   (uptr size_t uptr) void))

(define read-callable
  (foreign-callable
   (lambda (stream nread buf)
     (set! read-cb-calls (+ read-cb-calls 1))
     (set! nread-values (append nread-values (list nread)))
     (when (eq? read-buf-base-seen 'read-cb-never-fired)
       (set! read-buf-base-seen (foreign-ref 'uptr buf OFFSETOF_UV_BUF_BASE)))
     (cond
       ((> nread 0)
        (let ((base (foreign-ref 'uptr buf OFFSETOF_UV_BUF_BASE)))
          ;; Copy out immediately (ADR-0009). The buffer is reused next read.
          (set! received (bv-append received
                                    (foreign-bytes->bytevector base nread))))
        (when raise-in-read-cb?
          (raise (condition (make-spike-raise 'read-cb)
                            (make-message-condition
                             "spike raise from inside a libuv READ callback")))))
       ((= nread UV_EOF)
        (set! eof-seen #t)
        (uv-read-stop stream)
        (uv-close peer-ptr   close-cb-ptr)
        (uv-close server-ptr close-cb-ptr))
       ((< nread 0)
        (printf "  [read] unexpected negative nread: ~a\n" (rc-name nread)))))
   (uptr ssize_t uptr) void))

(define write-callable
  (foreign-callable
   (lambda (req status)
     (set! write-cb-calls (+ write-cb-calls 1))
     (set! write-status status)
     ;; Closing the client here is what produces UV_EOF at the server, which
     ;; is the point: it exercises the negative-nread path deliberately.
     (uv-close client-ptr close-cb-ptr))
   (uptr int) void))

(define connect-callable
  (foreign-callable
   (lambda (req status)
     (set! connect-cb-calls (+ connect-cb-calls 1))
     (set! connect-status status)
     (when (zero? status)
       (let ((rc (uv-write write-req client-ptr write-buf 1 write-cb-ptr)))
         (printf "  [connect] uv_write rc = ~a\n" (rc-name rc)))))
   (uptr int) void))

(define connection-callable
  (foreign-callable
   (lambda (server status)
     (set! connection-cb-calls (+ connection-cb-calls 1))
     (set! connection-status status)
     (when (zero? status)
       (let* ((rc-init   (uv-tcp-init loop-ptr peer-ptr))
              (rc-accept (uv-accept server peer-ptr))
              (rc-read   (uv-read-start peer-ptr alloc-cb-ptr read-cb-ptr)))
         (printf "  [connection] uv_tcp_init=~a uv_accept=~a uv_read_start=~a\n"
                 (rc-name rc-init) (rc-name rc-accept) (rc-name rc-read)))))
   (uptr int) void))

(define close-callable
  (foreign-callable
   (lambda (handle) (set! close-cb-calls (+ close-cb-calls 1)))
   (uptr) void))

(define deadline-callable
  (foreign-callable
   (lambda (handle)
     (set! deadline-fired 'yes)
     (uv-stop loop-ptr))
   (uptr) void))

;; Locked once, never unlocked, for the life of the process (ADR-0008).
(for-each lock-object
          (list alloc-callable read-callable write-callable
                connect-callable connection-callable close-callable
                deadline-callable))

(define alloc-cb-ptr      (foreign-callable-entry-point alloc-callable))
(define read-cb-ptr       (foreign-callable-entry-point read-callable))
(define write-cb-ptr      (foreign-callable-entry-point write-callable))
(define connect-cb-ptr    (foreign-callable-entry-point connect-callable))
(define connection-cb-ptr (foreign-callable-entry-point connection-callable))
(define close-cb-ptr      (foreign-callable-entry-point close-callable))
(define deadline-cb-ptr   (foreign-callable-entry-point deadline-callable))

;;; --- bring the server up ----------------------------------------------------
(printf "uv_loop_init      = ~a\n" (rc-name (uv-loop-init loop-ptr)))
(printf "uv_tcp_init(srv)  = ~a\n" (rc-name (uv-tcp-init loop-ptr server-ptr)))
(printf "uv_ip4_addr(:0)   = ~a\n" (rc-name (uv-ip4-addr loopback-ip 0 bind-addr)))
(printf "uv_tcp_bind       = ~a\n" (rc-name (uv-tcp-bind server-ptr bind-addr 0)))
(printf "uv_listen         = ~a\n" (rc-name (uv-listen server-ptr 128 connection-cb-ptr)))

;;; --- read the real ephemeral port back --------------------------------------
(foreign-set! 'int name-len 0 SIZEOF_SOCKADDR_STORAGE)
(printf "uv_tcp_getsockname= ~a\n" (rc-name (uv-tcp-getsockname server-ptr name-addr name-len)))

(define sockname-len (foreign-ref 'int name-len 0))
(define sin-family   (foreign-ref 'unsigned-8 name-addr OFFSETOF_SIN_FAMILY))
;; ntohs by hand: sin_port is stored big-endian regardless of host order.
(define bound-port
  (+ (* 256 (foreign-ref 'unsigned-8 name-addr OFFSETOF_SIN_PORT))
     (foreign-ref 'unsigned-8 name-addr (+ OFFSETOF_SIN_PORT 1))))
(define sin-addr-bytes
  (list (foreign-ref 'unsigned-8 name-addr OFFSETOF_SIN_ADDR)
        (foreign-ref 'unsigned-8 name-addr (+ OFFSETOF_SIN_ADDR 1))
        (foreign-ref 'unsigned-8 name-addr (+ OFFSETOF_SIN_ADDR 2))
        (foreign-ref 'unsigned-8 name-addr (+ OFFSETOF_SIN_ADDR 3))))

(printf "namelen written back = ~d (sizeof(struct sockaddr_in))\n" sockname-len)
(printf "sin_family byte      = ~d (AF_INET = ~d)\n" sin-family AF_INET)
(printf "sin_addr             = ~d.~d.~d.~d\n"
        (car sin-addr-bytes) (cadr sin-addr-bytes)
        (caddr sin-addr-bytes) (cadddr sin-addr-bytes))
;; The port itself is ephemeral and differs every run, so it goes to stderr;
;; stdout carries only the range verdict, keeping stdout reproducible.
(fprintf (current-error-port) "bound ephemeral port = ~d\n" bound-port)
(printf "port is nonzero and in the ephemeral range? ~s\n"
        (and (> bound-port 1024) (< bound-port 65536)))

;;; --- connect the client from the same loop ---------------------------------
(printf "uv_tcp_init(cli)  = ~a\n" (rc-name (uv-tcp-init loop-ptr client-ptr)))
(printf "uv_ip4_addr(:port)= ~a\n" (rc-name (uv-ip4-addr loopback-ip bound-port conn-addr)))
(printf "uv_tcp_connect    = ~a\n"
        (rc-name (uv-tcp-connect connect-req client-ptr conn-addr connect-cb-ptr)))

;;; --- run ---------------------------------------------------------------------
(display "MARKER: entering blocking uv_run\n")
(flush-output-port (current-output-port))

(define rc-run
  (if raise-in-read-cb?
      (guard (e (#t (set! read-cb-raise-escaped
                          (if (spike-raise? e) 'escaped-to-guard-around-uv-run 'other))
                    'guard-fired))
        (uv-run loop-ptr UV_RUN_DEFAULT))
      (uv-run loop-ptr UV_RUN_DEFAULT)))

(printf "uv_run returned   = ~s\n" rc-run)

;;; --- results ------------------------------------------------------------------
(display "\n--- results ---\n")
(printf "connection_cb calls = ~d, status = ~s\n" connection-cb-calls connection-status)
(printf "connect_cb    calls = ~d, status = ~s\n" connect-cb-calls connect-status)
(printf "alloc_cb      calls = ~d, suggested_size = ~s\n" alloc-cb-calls alloc-suggested)
(printf "read_cb       calls = ~d, nread values = ~s\n" read-cb-calls nread-values)
(printf "write_cb      calls = ~d, status = ~s\n" write-cb-calls write-status)
(printf "close_cb      calls = ~d\n" close-cb-calls)
(printf "alloc_cb buffer pointer reached read_cb? ~s\n" (eqv? read-buf-base-seen read-buffer))
(printf "received ~d bytes = ~s\n"
        (bytevector-length received) (utf8->string received))
(when raise-in-read-cb?
  (printf "raise from read_cb: ~s\n" read-cb-raise-escaped))

;;; Measured BEFORE any recovery attempt below, so the raise variant can tell
;;; "the loop was left alive by the escape" from "the loop is alive because
;;; recovery has not finished yet".
(define alive-after-run (uv-loop-alive loop-ptr))
(printf "uv_loop_alive after uv_run = ~d\n" alive-after-run)

;; nread deliveries at the moment control left uv_run, before any aftermath
;; block below touches the loop.
(define nread-at-escape nread-values)

;;; ===========================================================================
;;; Aftermath of the escape — one block per mode. These exist because the two
;;; claims FINDINGS.md makes about what an escape costs must be MEASURED:
;;;   * `drain-before-close` answers "is the abandoned iteration's UV_EOF lost,
;;;     or merely deferred until something runs the loop again?" It must leave
;;;     every handle open and the read STILL STARTED, otherwise no read_cb
;;;     could fire and the question answers itself.
;;;   * `no-recovery` answers "what does uv_loop_close actually return when the
;;;     escape left handles open?" — measured, not predicted.
;;;   * `raise-in-read-cb` is the original recoverability check: closing the
;;;     handles from Scheme separates "unusable because control flow was
;;;     abandoned" (recoverable) from "unusable because libuv's state is
;;;     broken" (not).
;;; ===========================================================================
(define recovery-drain-rc   'not-applicable-in-this-mode)
(define recovery-close-cbs  'not-applicable-in-this-mode)
(define recovery-alive      'not-applicable-in-this-mode)
(define nread-before-drain  'not-applicable-in-this-mode)
(define nread-after-drain   'not-applicable-in-this-mode)
(define eof-redelivered     'not-applicable-in-this-mode)
(define no-recovery-close-rc 'not-applicable-in-this-mode)

(define escaped?
  (and raise-in-read-cb?
       (eq? read-cb-raise-escaped 'escaped-to-guard-around-uv-run)))

(when (and escaped? (string=? mode "raise-in-read-cb"))
  (display "MARKER: closing handles from Scheme, then draining\n")
  (flush-output-port (current-output-port))
  (uv-close peer-ptr   close-cb-ptr)
  (uv-close server-ptr close-cb-ptr)
  (set! recovery-drain-rc
        (guard (e (#t 'guard-fired)) (uv-run loop-ptr UV_RUN_DEFAULT)))
  (set! recovery-close-cbs close-cb-calls)
  (set! recovery-alive (uv-loop-alive loop-ptr))
  (printf "recovery: drain uv_run = ~s, close_cb total = ~s, uv_loop_alive = ~s\n"
          recovery-drain-rc recovery-close-cbs recovery-alive)
  ;; NOTE: the handles were closed BEFORE this drain, so no read_cb could fire
  ;; during it. This value says nothing about whether the EOF was recoverable —
  ;; that is what the `drain-before-close` mode below is for.
  (printf "recovery: nread values after drain = ~s (handles were closed first)\n"
          nread-values))

(when (and escaped? (string=? mode "drain-before-close"))
  (display "MARKER: draining with every handle still open and read still started\n")
  (flush-output-port (current-output-port))
  (set! nread-before-drain nread-values)
  ;; A one-shot deadline timer bounds the drain. Without it, a NON-redelivered
  ;; EOF would hang forever: the listening server keeps the loop alive by
  ;; itself, so uv_run(DEFAULT) would block with nothing left to deliver.
  ;; Bounded by iteration/deadline, never by "it seemed to finish".
  (printf "uv_timer_init(deadline)  = ~a\n"
          (rc-name (uv-timer-init loop-ptr deadline-ptr)))
  (printf "uv_timer_start(~dms one-shot) = ~a\n" DEADLINE-MS
          (rc-name (uv-timer-start deadline-ptr deadline-cb-ptr DEADLINE-MS 0)))
  (set! recovery-drain-rc
        (guard (e (#t 'guard-fired)) (uv-run loop-ptr UV_RUN_DEFAULT)))
  (set! nread-after-drain nread-values)
  (set! recovery-close-cbs close-cb-calls)
  (set! eof-redelivered
        (if (member UV_EOF nread-values) 'yes-eof-was-redelivered 'no-eof-never-arrived))
  (printf "drain uv_run = ~s (deadline fired: ~s)\n" recovery-drain-rc deadline-fired)
  (printf "nread values BEFORE drain = ~s\n" nread-before-drain)
  (printf "nread values AFTER  drain = ~s\n" nread-after-drain)
  (printf "close_cb calls after drain = ~d\n" close-cb-calls)
  (printf "EOF redelivered? ~s\n" eof-redelivered)
  ;; Whatever the answer, get the loop to a closable state before teardown.
  (uv-close deadline-ptr close-cb-ptr)
  (when (zero? (uv-is-closing peer-ptr))   (uv-close peer-ptr   close-cb-ptr))
  (when (zero? (uv-is-closing server-ptr)) (uv-close server-ptr close-cb-ptr))
  (uv-run loop-ptr UV_RUN_DEFAULT)
  (set! recovery-alive (uv-loop-alive loop-ptr)))

(when (and escaped? (string=? mode "no-recovery"))
  (display "MARKER: calling uv_loop_close immediately, handles still open\n")
  (flush-output-port (current-output-port))
  (set! no-recovery-close-rc (uv-loop-close loop-ptr))
  (printf "uv_loop_close with handles open = ~a\n" (rc-name no-recovery-close-rc)))

;;; --- teardown -------------------------------------------------------------
(define rc-loop-close (uv-loop-close loop-ptr))
(printf "uv_loop_close = ~a\n" (rc-name rc-loop-close))

(for-each foreign-free
          (list payload-ptr write-buf loop-ptr server-ptr client-ptr peer-ptr
                connect-req write-req bind-addr conn-addr name-addr name-len
                read-buffer loopback-ip deadline-ptr))
(display "foreign-free  = done\n")
(collect (collect-maximum-generation))
(display "post-teardown collect = done\n")

;;; --- checks ---------------------------------------------------------------
(define (check name expected actual)
  (printf "~a: expected=~s actual=~s ~a\n"
          name expected actual (if (equal? expected actual) "OK" "MISMATCH")))

;;; The raise modes are diagnostics, not gates: their whole point is that the
;;; loopback exchange does NOT complete. Each reports its own verdict and stops
;;; here rather than running the success checks below, which it must fail.
(when raise-in-read-cb?
  (printf "\n--- ~a verdict ---\n" mode)
  (check "raise escaped uv_run into the Scheme guard"
         'escaped-to-guard-around-uv-run read-cb-raise-escaped)
  (check "loop was left alive with handles open" 1 alive-after-run)
  (check "at the escape, only the data read had been delivered"
         (list payload-len) nread-at-escape)

  (cond
    ((string=? mode "raise-in-read-cb")
     (check "explicit close + drain finished the loop" 0 recovery-alive)
     (check "all three close_cbs eventually fired" 3 recovery-close-cbs)
     (check "uv_loop_close then returns 0" 0 rc-loop-close))

    ((string=? mode "drain-before-close")
     ;; THE measurement. Sentinel: `eof-redelivered` starts as
     ;; 'not-applicable-in-this-mode, which neither branch can produce.
     (check "deadline timer bounded the drain" 'yes deadline-fired)
     ;; MEASURED FIRST, then locked in as a regression check. The sentinel
     ;; 'not-applicable-in-this-mode is what a drain that never ran leaves
     ;; behind, and 'no-eof-never-arrived is the opposite outcome — neither
     ;; can be produced by the branch this expects.
     (check "EOF is REDELIVERED, not lost"
            'yes-eof-was-redelivered eof-redelivered)
     (check "nread before drain (escape branch only)"
            (list payload-len) nread-before-drain)
     (check "nread after drain (EOF arrives late)"
            (list payload-len UV_EOF) nread-after-drain)
     ;; The redelivered EOF ran read_cb's EOF branch, which closes peer and
     ;; server: 1 close_cb (the client, from write_cb) becomes 3.
     (check "the late EOF ran the cleanup branch that the escape skipped"
            3 recovery-close-cbs)
     (check "loop closable after drain" 0 recovery-alive)
     (check "uv_loop_close returns 0" 0 rc-loop-close))

    ((string=? mode "no-recovery")
     ;; THE measurement: what uv_loop_close actually returns with handles open.
     (printf "measured uv_loop_close with handles open: ~a\n"
             (rc-name no-recovery-close-rc))
     (check "uv_loop_close with handles open is nonzero"
            #t (not (eqv? no-recovery-close-rc 0)))))

  (let ((ok (and (eq? read-cb-raise-escaped 'escaped-to-guard-around-uv-run)
                 (eqv? alive-after-run 1)
                 (cond
                   ((string=? mode "raise-in-read-cb")
                    (and (eqv? recovery-alive 0) (eqv? recovery-close-cbs 3)
                         (zero? rc-loop-close)))
                   ((string=? mode "drain-before-close")
                    (and (eq? deadline-fired 'yes)
                         (memq eof-redelivered
                               '(yes-eof-was-redelivered no-eof-never-arrived))
                         (eqv? recovery-alive 0)))
                   ((string=? mode "no-recovery")
                    (not (eqv? no-recovery-close-rc 'not-applicable-in-this-mode)))
                   (else #f)))))
    (printf "\nRESULT: ~a\n"
            (if ok "DIAGNOSTIC-COMPLETE (see measured values above)"
                "DIAGNOSTIC-UNEXPECTED (see values above)"))
    (exit (if ok 0 1))))

(display "\n--- checks ---\n")
(check "uv_buf_t base round-trips"  #t (= readback-base payload-ptr))
(check "uv_buf_t len round-trips"   payload-len readback-len)
(check "sin_family is AF_INET"      AF_INET sin-family)
(check "getsockname namelen"        SIZEOF_SOCKADDR_IN sockname-len)
(check "sin_addr is 127.0.0.1"      '(127 0 0 1) sin-addr-bytes)
(check "connection_cb status"       0 connection-status)
(check "connect_cb status"          0 connect-status)
(check "write_cb status"            0 write-status)
(check "connection_cb fired once"   1 connection-cb-calls)
(check "connect_cb fired once"      1 connect-cb-calls)
(check "write_cb fired once"        1 write-cb-calls)
(check "close_cb fired 3x"          3 close-cb-calls)
(check "alloc_cb buffer reached read_cb" #t (eqv? read-buf-base-seen read-buffer))
(check "received exactly the payload" PAYLOAD (utf8->string received))
(check "received byte count"        payload-len (bytevector-length received))
;; The load-bearing one for ssize_t: the LAST nread must be exactly UV_EOF.
;; A wrong (unsigned) marshalling would deliver 18446744073709547521 here.
(check "last nread is UV_EOF (-4095)" UV_EOF (car (reverse nread-values)))
(check "nread sequence"             (list payload-len UV_EOF) nread-values)
(check "uv_loop_alive after uv_run" 0 alive-after-run)
(check "uv_loop_close rc"           0 rc-loop-close)

(define ok?
  (and (= readback-base payload-ptr)
       (= readback-len payload-len)
       (= sin-family AF_INET)
       (= sockname-len SIZEOF_SOCKADDR_IN)
       (equal? sin-addr-bytes '(127 0 0 1))
       (eqv? connection-status 0) (eqv? connect-status 0) (eqv? write-status 0)
       (= connection-cb-calls 1) (= connect-cb-calls 1) (= write-cb-calls 1)
       (= close-cb-calls 3)
       (eqv? read-buf-base-seen read-buffer)
       (string=? (utf8->string received) PAYLOAD)
       (equal? nread-values (list payload-len UV_EOF))
       eof-seen
       (zero? alive-after-run)
       (zero? rc-loop-close)))

(printf "\nRESULT: ~a\n" (if ok? "PASS" "FAIL"))
(exit (if ok? 0 1))
