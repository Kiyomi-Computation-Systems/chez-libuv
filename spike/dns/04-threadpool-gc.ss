;;; spike/dns/04-threadpool-gc.ss — Q1: threadpool workers x Chez GC x
;;; re-entrancy x loop-liveness, on the two NEW trampoline shapes.
;;;
;;; Usage:
;;;   chez --script spike/dns/04-threadpool-gc.ss \
;;;        /opt/homebrew/opt/libuv/lib/libuv.dylib [target-lookups]
;;;
;;; What this proves (or refutes):
;;;   libuv's threadpool completion path (worker thread runs pure libc
;;;   getaddrinfo -> wq_async wakes the loop thread -> uv__getaddrinfo_done
;;;   re-enters a locked foreign-callable ON THE LOOP THREAD) can deliver
;;;   10,000 lookups; the callback forces a full `(collect)` on every fire,
;;;   verifies the decoded result address, frees the chain, and RESUBMITS the
;;;   next lookup from inside itself; the counter is exact; teardown is clean;
;;;   the process exits 0. This is the assumption the ADR-0008 amendment
;;;   (ten trampolines) and ADR-0011 (handle-less loop-scoped requests) rest
;;;   on for v0.2.
;;;
;;; Also answers, as recorded observations (design spec section 10, Q1):
;;;   (a) what `uv_run` returns while a getaddrinfo request is pending —
;;;       UV_RUN_NOWAIT immediately after submit, then a capped UV_RUN_ONCE
;;;       loop (does one 'once block until the completion arrives?);
;;;   (b) Chez `string` foreign-argument marshalling: #f -> NULL (measured
;;;       through uv_ip4_addr's NULL guard, vendor/libuv/src/inet.c:147, and
;;;       disambiguated from "" through getaddrinfo, whose empty-hostname
;;;       idna path fails SYNCHRONOUSLY with UV_EINVAL — idna.c:325-326);
;;;       UTF-8 transcoding and embedded-NUL truncation (strlen, resolved
;;;       from the already-loaded process images, plus the behavioral
;;;       getaddrinfo prefix-resolution check behind spec section 4.1's NUL
;;;       refusal);
;;;   (c) `putenv` -> `uv_os_getenv` propagation, done BEFORE any threadpool
;;;       touch (this feeds Q3, whose pool pinning depends on it).
;;;
;;; Entry-point stability (v0.1 Q1's exact check) is asserted for BOTH new
;;; trampoline shapes — getaddrinfo (uptr int uptr) and getnameinfo
;;; (uptr int uptr uptr) — before the engine and again after its 10,000
;;; collections. The getnameinfo shape also gets one live fire (a numeric
;;; reverse lookup) so the 4-argument arity is verified by delivery, not just
;;; by stability of an address.
;;;
;;; SPIKE-ONLY CONSTANTS: every constant below comes from
;;; spike/dns/probe-dns (and spike/probe for the v0.1 ones), never from
;;; memory. Hardcoding platform constants is legal IN THE SPIKE ONLY —
;;; production snapshots them in the shim (ADR-0005); AF_INET6=30,
;;; sin_family-at-offset-1, and the addrinfo field order are all
;;; Darwin-specific and known-different on Linux.

(import (chezscheme))

(define argv (command-line-arguments))

(define lib-path
  (if (null? argv)
      (begin (display "usage: 04-threadpool-gc.ss <libuv.dylib> [target]\n") (exit 2))
      (car argv)))

(define target-lookups
  (if (or (null? argv) (null? (cdr argv)))
      10000
      (string->number (cadr argv))))

;;; --- probe-supplied constants (spike/dns/probe-dns output, Darwin arm64) ---
(define UV_GETADDRINFO      8)
(define UV_GETNAMEINFO      9)
(define UV_RUN_DEFAULT      0)
(define UV_RUN_ONCE         1)
(define UV_RUN_NOWAIT       2)
(define AF_INET             2)
(define SOCK_STREAM         1)
(define AI_NUMERICHOST      4)      ; Darwin; glibc values must come from a
(define AI_NUMERICSERV      4096)   ;   probe-dns run on CI, never from memory
(define NI_NUMERICHOST      2)      ; Darwin
(define NI_NUMERICSERV      8)      ; Darwin
(define NI_MAXHOST          1025)
(define NI_MAXSERV          32)
(define SIZEOF_ADDRINFO     48)
(define OFFSETOF_AI_FLAGS    0)
(define OFFSETOF_AI_FAMILY   4)
(define OFFSETOF_AI_SOCKTYPE 8)
(define OFFSETOF_AI_ADDR    32)     ; Darwin: ai_canonname(24) BEFORE ai_addr(32);
(define OFFSETOF_AI_NEXT    40)     ;   glibc reverses them — the spec 5.2 trap
(define SIZEOF_SOCKADDR_IN  16)
(define OFFSETOF_SIN_FAMILY  1)     ; Darwin: sin_len is byte 0 (v0.1 finding)
(define OFFSETOF_SIN_PORT    2)
(define OFFSETOF_SIN_ADDR    4)
(define UV_EINVAL          -22)

;;; --- load, THEN bind (Q0's trap) -------------------------------------------
(load-shared-object lib-path)

(define uv-loop-size    (foreign-procedure "uv_loop_size"    ()          size_t))
(define uv-req-size     (foreign-procedure "uv_req_size"     (int)       size_t))
(define uv-loop-init    (foreign-procedure "uv_loop_init"    (uptr)      int))
(define uv-loop-close   (foreign-procedure "uv_loop_close"   (uptr)      int))
(define uv-loop-alive   (foreign-procedure "uv_loop_alive"   (uptr)      int))
(define uv-run          (foreign-procedure "uv_run"          (uptr int)  int))
(define uv-getaddrinfo  (foreign-procedure "uv_getaddrinfo"
                                           (uptr uptr uptr string string uptr) int))
(define uv-getnameinfo  (foreign-procedure "uv_getnameinfo"
                                           (uptr uptr uptr uptr int) int))
(define uv-freeaddrinfo (foreign-procedure "uv_freeaddrinfo" (uptr)      void))
(define uv-ip4-addr     (foreign-procedure "uv_ip4_addr"     (string int uptr) int))
(define uv-os-getenv    (foreign-procedure "uv_os_getenv"    (string u8* uptr) int))
(define uv-err-name     (foreign-procedure "uv_err_name"     (int)       uptr))

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

(define (rc-name rc) (if (zero? rc) "0" (c-string->string (uv-err-name rc))))

;;; --- (c) putenv -> uv_os_getenv propagation, BEFORE any threadpool touch ---
;;; The threadpool reads UV_THREADPOOL_SIZE exactly once, at the first
;;; uv__work_submit (threadpool.c:194-217). Q3 (05-cancel-race.ss) pins the
;;; pool to 1 via Chez's putenv; this records that a Chez putenv is visible
;;; to libuv's own environment reader AT ALL — nothing below this block has
;;; touched the pool yet, so the ordering here mirrors the ordering Q3 needs.
(putenv "CHEZ_LIBUV_DNS_SPIKE" "q1-propagation-sentinel")
(putenv "UV_THREADPOOL_SIZE" "4")   ; = the documented default, so this run's
                                    ;   pool behavior is unchanged; the
                                    ;   VALUE-level readback is the check.
(define (getenv-via-uv name)
  (let ((buf (make-bytevector 64 0))
        (szp (foreign-alloc 8)))
    (foreign-set! 'unsigned-64 szp 0 64)
    (let ((rc (uv-os-getenv name buf szp)))
      (let ((out (if (zero? rc)
                     (let* ((n (foreign-ref 'unsigned-64 szp 0))
                            (bv (make-bytevector n)))
                       (bytevector-copy! buf 0 bv 0 n)
                       (utf8->string bv))
                     (rc-name rc))))
        (foreign-free szp)
        out))))

(define sentinel-readback (getenv-via-uv "CHEZ_LIBUV_DNS_SPIKE"))
(define poolsize-readback (getenv-via-uv "UV_THREADPOOL_SIZE"))

(printf "--- (c) putenv -> uv_os_getenv propagation (before any threadpool touch) ---\n")
(printf "uv_os_getenv(CHEZ_LIBUV_DNS_SPIKE) = ~s\n" sentinel-readback)
(printf "uv_os_getenv(UV_THREADPOOL_SIZE)   = ~s\n" poolsize-readback)

;;; --- the two NEW trampoline shapes: created once, locked once --------------
;;; uv_getaddrinfo_cb is  void (*)(uv_getaddrinfo_t*, int, struct addrinfo*)
;;; uv_getnameinfo_cb is  void (*)(uv_getnameinfo_t*, int, const char*, const char*)
;;; (vendor/libuv/include/uv.h:345-352) — neither matches any v0.1 arity.

(define fire-count 0)
(define submit-fail-count 0)
(define verify-fail-count 0)
(define first-verify-fail 'none)  ; sentinel: no failure path produces 'none
(define last-garbage-length 0)

;; Reads one completed chain and answers a symbol: 'ok, or the FIRST thing
;; wrong with it. Every offset is probe-supplied (see the constants block).
(define (verify-result status res)
  (cond
    ((not (zero? status)) 'nonzero-status)
    ((zero? res) 'null-res)
    ((not (= (foreign-ref 'int res OFFSETOF_AI_FAMILY) AF_INET)) 'wrong-family)
    ((not (= (foreign-ref 'int res OFFSETOF_AI_SOCKTYPE) SOCK_STREAM)) 'wrong-socktype)
    ((not (zero? (foreign-ref 'unsigned-64 res OFFSETOF_AI_NEXT))) 'unexpected-second-entry)
    (else
     (let ((sa (foreign-ref 'unsigned-64 res OFFSETOF_AI_ADDR)))
       (cond
         ((zero? sa) 'null-ai-addr)
         ((not (= (foreign-ref 'unsigned-8 sa OFFSETOF_SIN_FAMILY) AF_INET))
          'wrong-sin-family)
         ((not (= (+ (* 256 (foreign-ref 'unsigned-8 sa OFFSETOF_SIN_PORT))
                     (foreign-ref 'unsigned-8 sa (+ OFFSETOF_SIN_PORT 1)))
                  80))
          'wrong-port)
         ((not (and (= (foreign-ref 'unsigned-8 sa (+ OFFSETOF_SIN_ADDR 0)) 127)
                    (= (foreign-ref 'unsigned-8 sa (+ OFFSETOF_SIN_ADDR 1)) 0)
                    (= (foreign-ref 'unsigned-8 sa (+ OFFSETOF_SIN_ADDR 2)) 0)
                    (= (foreign-ref 'unsigned-8 sa (+ OFFSETOF_SIN_ADDR 3)) 1)))
          'wrong-address)
         (else 'ok))))))

;; hints: AF_INET + SOCK_STREAM + AI_NUMERICHOST|AI_NUMERICSERV, so every
;; lookup is pure formatting (zero network, ADR-0013) and the chain is
;; exactly one entry. One blob, allocated once, reused for all 10k submits —
;; legal because uv_getaddrinfo memcpys hints before returning
;; (getaddrinfo.c:174-208, the spec section 7 lifetime fact).
(define hints (alloc-zeroed SIZEOF_ADDRINFO))
(foreign-set! 'int hints OFFSETOF_AI_FLAGS (bitwise-ior AI_NUMERICHOST AI_NUMERICSERV))
(foreign-set! 'int hints OFFSETOF_AI_FAMILY AF_INET)
(foreign-set! 'int hints OFFSETOF_AI_SOCKTYPE SOCK_STREAM)

(define gai-req-size 0)   ; set after the loop exists; used by resubmit
(define loop-ptr 0)

(define (submit-lookup!)
  ;; A FRESH req block per lookup, freed in the callback that completes it —
  ;; the alloc/free-per-request shape production will have, kept adversarial
  ;; for the GC by never reusing a block.
  (let* ((req (foreign-alloc gai-req-size))
         (rc  (uv-getaddrinfo loop-ptr req gai-cb-ptr "127.0.0.1" "80" hints)))
    (unless (zero? rc)
      (set! submit-fail-count (+ submit-fail-count 1))
      (foreign-free req))
    rc))

(define gai-callable
  (foreign-callable
   (lambda (req status res)
     (set! fire-count (+ fire-count 1))
     ;; Allocate garbage, then force a collection, on EVERY fire — the v0.1
     ;; Q1 adversarial pattern, now with uv_run -> uv__work_done ->
     ;; uv__getaddrinfo_done C frames live below us instead of uv__run_timers.
     (let loop ((i 0) (acc '()))
       (if (< i 1000)
           (loop (+ i 1) (cons i acc))
           (set! last-garbage-length (length acc))))
     (collect)
     (let ((v (verify-result status res)))
       (unless (eq? v 'ok)
         (set! verify-fail-count (+ verify-fail-count 1))
         (when (eq? first-verify-fail 'none)
           (set! first-verify-fail (cons fire-count v)))))
     ;; res is libuv-owned; NULL on failure, and uv_freeaddrinfo(NULL) is a
     ;; no-op (getaddrinfo.c:225-228) — so the free is unconditional, the
     ;; same shape the production dispatcher will have.
     (uv-freeaddrinfo res)
     (foreign-free req)
     ;; RESUBMIT FROM INSIDE THE CALLBACK until the target is reached. The
     ;; new registration keeps the loop alive, so one blocking uv_run drives
     ;; the whole chain.
     (when (< fire-count target-lookups)
       (submit-lookup!)))
   (uptr int uptr) void))

;; The getnameinfo shape. Fired once (numeric reverse lookup below); its
;; entry-point stability across the engine's 10,000 collections is asserted
;; alongside the getaddrinfo one.
(define gni-fire-count 0)
(define gni-status 'none)
(define gni-host 'none)
(define gni-service 'none)
(define gni-callable
  (foreign-callable
   (lambda (req status hostname service)
     (set! gni-fire-count (+ gni-fire-count 1))
     (collect)
     (set! gni-status status)
     ;; Copy-before-return: hostname/service point INTO the req block
     ;; (uv/unix.h:353-354) — c-string->string copies, NULL -> #f.
     (set! gni-host (c-string->string hostname))
     (set! gni-service (c-string->string service)))
   (uptr int uptr uptr) void))

(lock-object gai-callable)
(lock-object gni-callable)

(define gai-cb-ptr (foreign-callable-entry-point gai-callable))
(define gni-cb-ptr (foreign-callable-entry-point gni-callable))

;;; --- entry-point stability across (collect), BEFORE the engine -------------
(define gai-ptr-before gai-cb-ptr)
(define gni-ptr-before gni-cb-ptr)
(collect)
(collect (collect-maximum-generation))
(define gai-ptr-warm (foreign-callable-entry-point gai-callable))
(define gni-ptr-warm (foreign-callable-entry-point gni-callable))

(fprintf (current-error-port)
         "addresses: getaddrinfo ~x -> ~x ; getnameinfo ~x -> ~x\n"
         gai-ptr-before gai-ptr-warm gni-ptr-before gni-ptr-warm)

(printf "\n--- setup ---\n")
(printf "uv_req_size(UV_GETADDRINFO)  = ~d\n" (uv-req-size UV_GETADDRINFO))
(printf "locked getaddrinfo entry point stable across (collect)? ~s\n"
        (= gai-ptr-before gai-ptr-warm))
(printf "locked getnameinfo entry point stable across (collect)? ~s\n"
        (= gni-ptr-before gni-ptr-warm))
(printf "target lookups               = ~d\n" target-lookups)

(set! gai-req-size (uv-req-size UV_GETADDRINFO))
(set! loop-ptr (alloc-zeroed (uv-loop-size)))
(define rc-loop-init (uv-loop-init loop-ptr))
(printf "uv_loop_init                 = ~a\n" (rc-name rc-loop-init))

;;; --- (a) uv_run return values while a getaddrinfo request is pending -------
;;; Submitted OUTSIDE the engine so its rc observations are not tangled with
;;; the resubmission chain. NOWAIT immediately after submit, then a CAPPED
;;; 'once loop (iteration cap, never wall-clock — AGENTS.md).
(printf "\n--- (a) uv_run modes with a request in flight ---\n")
(define probe-a-fired 0)
(define probe-a-callable
  (foreign-callable
   (lambda (req status res)
     (set! probe-a-fired (+ probe-a-fired 1))
     (uv-freeaddrinfo res)
     (foreign-free req))
   (uptr int uptr) void))
(lock-object probe-a-callable)
(define probe-a-req (foreign-alloc gai-req-size))
(define rc-probe-a-submit
  (uv-getaddrinfo loop-ptr probe-a-req
                  (foreign-callable-entry-point probe-a-callable)
                  "127.0.0.1" "80" hints))
(printf "submit rc                     = ~a\n" (rc-name rc-probe-a-submit))
(define rc-nowait (uv-run loop-ptr UV_RUN_NOWAIT))
(define fired-at-nowait probe-a-fired)
(printf "uv_run(NOWAIT) immediately    = ~d (callback fired by then: ~d)\n"
        rc-nowait fired-at-nowait)
;; capped 'once loop: how many 'once calls until the completion is delivered?
(define once-iterations 0)
(define rc-last-once 'not-run)   ; sentinel: never printed unless the loop ran
(let loop ((i 0))
  (when (and (< i 1000) (zero? probe-a-fired))
    (set! rc-last-once (uv-run loop-ptr UV_RUN_ONCE))
    (set! once-iterations (+ once-iterations 1))
    (loop (+ i 1))))
(printf "'once calls until delivery    = ~d\n" once-iterations)
(printf "uv_run(ONCE) rc at delivery   = ~s\n" rc-last-once)
(printf "probe-a callback fired        = ~d\n" probe-a-fired)

;;; --- (b) string marshalling probes -----------------------------------------
(printf "\n--- (b) Chez `string` foreign-argument marshalling ---\n")

;; (b1) strlen, resolved from the images already loaded into the process
;; (libSystem on Darwin, libc on Linux) — NOT from libuv. Byte-level view of
;; what the callee receives.
(define strlen-available
  (call/cc
   (lambda (k)
     (with-exception-handler
      (lambda (e) (k #f))
      (lambda () (foreign-procedure "strlen" (string) size_t))))))
(if strlen-available
    (begin
      (printf "strlen resolvable             = yes\n")
      (printf "strlen(\"hello\")               = ~d\n" (strlen-available "hello"))
      (printf "strlen(\"h\\xe9;llo\")           = ~d  (6 = UTF-8 two-byte e-acute; 5 would be Latin-1)\n"
              (strlen-available "h\xe9;llo"))
      (printf "strlen(\"ab\\x0;cd\")            = ~d  (2 = callee sees a prefix truncated at the embedded NUL)\n"
              (strlen-available "ab\x0;cd")))
    (printf "strlen resolvable             = NO (byte-level probes skipped; see FINDINGS)\n"))

;; (b2) #f -> NULL, part 1: uv_ip4_addr's explicit NULL guard answers
;; UV_EINVAL (inet.c:147). Necessary but not sufficient — "" also parses to
;; EINVAL — so (b3) disambiguates.
(define sa-scratch (alloc-zeroed SIZEOF_SOCKADDR_IN))
(define rc-ip4-false (uv-ip4-addr #f 80 sa-scratch))
(define rc-ip4-good  (uv-ip4-addr "127.0.0.1" 80 sa-scratch))
(define rc-ip4-nul   (uv-ip4-addr "127.0.0.1\x0;junk" 80 sa-scratch))
(printf "uv_ip4_addr(#f, 80, sa)       = ~a\n" (rc-name rc-ip4-false))
(printf "uv_ip4_addr(\"127.0.0.1\", ...)  = ~a\n" (rc-name rc-ip4-good))
(printf "uv_ip4_addr(\"127.0.0.1\\x0;junk\") = ~a  (0 = the NUL-truncated prefix parsed)\n"
        (rc-name rc-ip4-nul))

;; (b3) #f -> NULL, part 2, the discriminating pair through uv_getaddrinfo:
;;   node = #f  -> if it crosses as NULL: VALID (numeric service alone),
;;                 async success, loopback address back;
;;   node = ""  -> the idna empty-input path: SYNCHRONOUS UV_EINVAL
;;                 (idna.c:325-326; also the spec section 7
;;                 "post-registration sync failure" fact, measured).
;; If #f were marshalled as "" the two rows would be identical.
(define false-node-status 'none)
(define false-node-verify 'none)
(define false-node-callable
  (foreign-callable
   (lambda (req status res)
     (set! false-node-status status)
     (set! false-node-verify (verify-result status res))
     (uv-freeaddrinfo res)
     (foreign-free req))
   (uptr int uptr) void))
(lock-object false-node-callable)
(define false-node-req (foreign-alloc gai-req-size))
(define rc-false-node
  (uv-getaddrinfo loop-ptr false-node-req
                  (foreign-callable-entry-point false-node-callable)
                  #f "80" hints))
(printf "uv_getaddrinfo(node=#f, \"80\") submit rc = ~a\n" (rc-name rc-false-node))
(let loop ((i 0))
  (when (and (< i 1000) (eq? false-node-status 'none) (zero? rc-false-node))
    (uv-run loop-ptr UV_RUN_ONCE)
    (loop (+ i 1))))
(printf "  async status = ~s, result verifies as 127.0.0.1:80 = ~s\n"
        false-node-status false-node-verify)

(define empty-node-req (foreign-alloc gai-req-size))
(define rc-empty-node
  (uv-getaddrinfo loop-ptr empty-node-req
                  (foreign-callable-entry-point false-node-callable)
                  "" "80" hints))
(printf "uv_getaddrinfo(node=\"\", \"80\") submit rc = ~a  (synchronous; no callback will fire)\n"
        (rc-name rc-empty-node))
(unless (zero? rc-empty-node) (foreign-free empty-node-req))

;; (b4) embedded NUL at the getaddrinfo level: the measurement behind spec
;; section 4.1's NUL refusal. If the callee sees a NUL-truncated prefix,
;; "127.0.0.1\x0;.evil" resolves as 127.0.0.1 — plausible and wrong.
(define nul-node-status 'none)
(define nul-node-verify 'none)
(define nul-node-callable
  (foreign-callable
   (lambda (req status res)
     (set! nul-node-status status)
     (set! nul-node-verify (verify-result status res))
     (uv-freeaddrinfo res)
     (foreign-free req))
   (uptr int uptr) void))
(lock-object nul-node-callable)
(define nul-node-req (foreign-alloc gai-req-size))
(define rc-nul-node
  (uv-getaddrinfo loop-ptr nul-node-req
                  (foreign-callable-entry-point nul-node-callable)
                  "127.0.0.1\x0;.evil" "80" hints))
(printf "uv_getaddrinfo(\"127.0.0.1\\x0;.evil\", \"80\") submit rc = ~a\n"
        (rc-name rc-nul-node))
(let loop ((i 0))
  (when (and (< i 1000) (eq? nul-node-status 'none) (zero? rc-nul-node))
    (uv-run loop-ptr UV_RUN_ONCE)
    (loop (+ i 1))))
(printf "  async status = ~s, result verifies as 127.0.0.1:80 = ~s  ('ok = the NUL-truncated prefix RESOLVED)\n"
        nul-node-status nul-node-verify)

;;; --- THE ENGINE: 10,000 lookups, (collect) + verify + resubmit every fire --
(printf "\n--- engine: ~d lookups, (collect) + verify + resubmit in every callback ---\n"
        target-lookups)
(define rc-first-submit (submit-lookup!))
(printf "first submit rc              = ~a\n" (rc-name rc-first-submit))
(define rc-engine-run (uv-run loop-ptr UV_RUN_DEFAULT))
(printf "uv_run(UV_RUN_DEFAULT)       = ~d  (0 = nothing left alive when the chain ended)\n"
        rc-engine-run)
(printf "fire count after uv_run      = ~d\n" fire-count)
(printf "submit failures              = ~d\n" submit-fail-count)
(printf "verify failures              = ~d\n" verify-fail-count)
(printf "first verify failure         = ~s\n" first-verify-fail)

;;; --- entry-point stability AFTER the engine's 10,000 collections -----------
(define gai-ptr-after (foreign-callable-entry-point gai-callable))
(define gni-ptr-after (foreign-callable-entry-point gni-callable))
(printf "getaddrinfo entry point stable across engine? ~s\n"
        (= gai-ptr-before gai-ptr-after))
(printf "getnameinfo entry point stable across engine? ~s\n"
        (= gni-ptr-before gni-ptr-after))

;;; --- the getnameinfo shape, fired once: numeric reverse of 127.0.0.1:80 ----
(printf "\n--- getnameinfo arity check (numeric reverse lookup) ---\n")
(define gni-sa (alloc-zeroed SIZEOF_SOCKADDR_IN))
(define rc-gni-sa (uv-ip4-addr "127.0.0.1" 80 gni-sa))
(define gni-req (foreign-alloc (uv-req-size UV_GETNAMEINFO)))
(define rc-gni-submit
  (uv-getnameinfo loop-ptr gni-req gni-cb-ptr gni-sa
                  (bitwise-ior NI_NUMERICHOST NI_NUMERICSERV)))
(printf "uv_ip4_addr for reverse       = ~a\n" (rc-name rc-gni-sa))
(printf "uv_getnameinfo submit rc      = ~a\n" (rc-name rc-gni-submit))
(let loop ((i 0))
  (when (and (< i 1000) (zero? gni-fire-count) (zero? rc-gni-submit))
    (uv-run loop-ptr UV_RUN_ONCE)
    (loop (+ i 1))))
(foreign-free gni-req)
(printf "gni callback fired            = ~d\n" gni-fire-count)
(printf "gni status                    = ~s\n" gni-status)
(printf "gni host                      = ~s\n" gni-host)
(printf "gni service                   = ~s\n" gni-service)

;;; --- teardown ---------------------------------------------------------------
(define alive-after (uv-loop-alive loop-ptr))
(printf "\nuv_loop_alive after all work = ~d\n" alive-after)
(define rc-loop-close (uv-loop-close loop-ptr))
(printf "uv_loop_close                = ~a\n" (rc-name rc-loop-close))
(foreign-free loop-ptr)
(foreign-free hints)
(foreign-free sa-scratch)
(foreign-free gni-sa)
(display "foreign-free                 = done\n")
(collect (collect-maximum-generation))
(display "post-teardown collect        = done\n")

;;; --- assertions --------------------------------------------------------------
(define (check name expected actual)
  (printf "~a: expected=~s actual=~s ~a\n"
          name expected actual (if (equal? expected actual) "OK" "MISMATCH")))

(display "\n--- checks ---\n")
(check "putenv sentinel propagated"      "q1-propagation-sentinel" sentinel-readback)
(check "putenv UV_THREADPOOL_SIZE propagated" "4" poolsize-readback)
(check "fire count exact"                target-lookups fire-count)
(check "no submit failures"              0 submit-fail-count)
(check "no verify failures"              0 verify-fail-count)
(check "first verify failure sentinel"   'none first-verify-fail)
(check "getaddrinfo entry point stable"  #t (and (= gai-ptr-before gai-ptr-warm)
                                                 (= gai-ptr-before gai-ptr-after)))
(check "getnameinfo entry point stable"  #t (and (= gni-ptr-before gni-ptr-warm)
                                                 (= gni-ptr-before gni-ptr-after)))
(check "engine uv_run rc"                0 rc-engine-run)
(check "probe-a delivered exactly once"  1 probe-a-fired)
(check "node=#f submit rc"               0 rc-false-node)
(check "node=#f async success"           0 false-node-status)
(check "node=#f result is 127.0.0.1:80"  'ok false-node-verify)
(check "node=\"\" fails SYNCHRONOUSLY EINVAL" UV_EINVAL rc-empty-node)
(check "embedded-NUL node resolved its prefix" 'ok nul-node-verify)
(check "gni fired exactly once"          1 gni-fire-count)
(check "gni status"                      0 gni-status)
(check "gni host"                        "127.0.0.1" gni-host)
(check "gni service"                     "80" gni-service)
(check "garbage really was built"        1000 last-garbage-length)
(check "loop alive after all work"       0 alive-after)
(check "uv_loop_close rc"                0 rc-loop-close)

(define ok?
  (and (string? sentinel-readback)
       (string=? sentinel-readback "q1-propagation-sentinel")
       (string? poolsize-readback) (string=? poolsize-readback "4")
       (= fire-count target-lookups)
       (zero? submit-fail-count) (zero? verify-fail-count)
       (eq? first-verify-fail 'none)
       (= gai-ptr-before gai-ptr-warm) (= gai-ptr-before gai-ptr-after)
       (= gni-ptr-before gni-ptr-warm) (= gni-ptr-before gni-ptr-after)
       (zero? rc-engine-run)
       (= probe-a-fired 1)
       (zero? rc-false-node) (eqv? false-node-status 0)
       (eq? false-node-verify 'ok)
       (= rc-empty-node UV_EINVAL)
       (eq? nul-node-verify 'ok)
       (= gni-fire-count 1) (eqv? gni-status 0)
       (equal? gni-host "127.0.0.1") (equal? gni-service "80")
       (= last-garbage-length 1000)
       (zero? alive-after) (zero? rc-loop-close)))

(printf "\nRESULT: ~a\n" (if ok? "PASS" "FAIL"))
(exit (if ok? 0 1))
