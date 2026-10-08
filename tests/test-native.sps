#!r6rs
;;; SRFI-64 suite for (libuv private native) + (libuv private constants) --
;;; design spec S4 (native.sls rules), S9 (conditions), S11 (testing), and
;;; ADR-0005 (constants are never transcribed).
;;;
;;; This suite is NOT pure: importing (libuv private native) loads libuv and
;;; the shim as a side effect of library instantiation (that is the whole
;;; point of the load-before-bind ordering, design spec S4 rule 3). So this
;;; file must never appear in the Makefile's PURE_TESTS.
;;;
;;; Division of labour with tests/test-shim-loading.sps: that suite drives
;;; the real CHEZ_LIBUV_SHIM wiring through fresh subprocesses, because the
;;; resolution happens exactly once per process at import time. Here we call
;;; resolve-shim-path / load-shim directly, with synthetic paths, any number
;;; of times -- which is the precise way to check the condition TYPE and its
;;; path field, something a subprocess exit code cannot show.
(import (rnrs)
        (rnrs mutable-pairs)
        (srfi :64)
        (libuv private native)
        (libuv private lists)
        (libuv private constants)
        (libuv private conditions)
        (libuv private config)
        ;; The bulk rows' libc reference and timing (issue #35).
        (uv-bulk)
        ;; foreign-alloc / foreign-set! / foreign-ref / foreign-free build
        ;; and mutate real C buffers for the string- and memory-helper tests
        ;; below; current-directory anchors the synthetic absolute paths used
        ;; by the resolve-shim-path matrix; bytevector-truncate! and collect
        ;; drive the copy-in! truncation scan. None collides with
        ;; an (rnrs) export (unlike file-exists? and exit, which do).
        ;; bytes-allocated, bytes-deallocated and collect-request-handler
        ;; meter fold-flags. random draws proper-length's random trials, and
        ;; the thread primitives run its cross-thread races.
        (only (chezscheme) foreign-alloc foreign-set! foreign-ref foreign-free
              foreign-sizeof current-directory getenv
              bytevector-truncate! collect
              random random-seed fork-thread thread-join)
        ;; The races' liveness watch and the allocation meter, shared and
        ;; pure.
        (only (uv-race) watch-flipper)
        (only (uv-meter) fewest-bytes)
        (uv-sweep)
        ;; Reaches (libuv private native) only, never handles.sls.
        (only (uv-evidence) live-count describe under-memory-tool? under-asan?))

;; SRFI-64's default runner does not set a process exit code, so a failing
;; suite would still exit 0 and `make test` would report success. Hold the
;; runner so its fail count can drive the exit status (AGENTS.md).
(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner prints only a failing row's title. The race and sweep
;; rows return their evidence when they fail, so print that too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

;; Captured BEFORE the first ensure-native-loaded! call anywhere in this
;; process, so the "has not run yet" assertions below are real observations
;; rather than a restatement of whatever state the suite happens to start in.
(define init-count-at-start      (native-init-count))
(define constants-count-at-start (constants-init-count))
(define native-initialized-at-start    (native-initialized?))
(define constants-initialized-at-start (constants-initialized?))

(test-begin "native")

;; --- initialisation is gated and idempotent ----------------------------
;; Not the vacuous "calling it twice does not raise": the initialiser keeps
;; a count of how many times its BODY actually ran, so removing the
;; `unless initialized?` guard makes the second call increment it and the
;; third assertion below fails by name. Seeded per AGENTS.md -- the count is
;; asserted to be 0 first, then exactly 1, so a counter stuck at any single
;; value cannot satisfy all three.
(test-equal "before any call, ensure-native-loaded!'s body has not run"
  0 init-count-at-start)

(test-equal "before any call, native-initialized? reports not-yet-initialised"
  #t (not native-initialized-at-start))

(test-equal "before any call, constants-initialized? reports not-yet-initialised"
  #t (not constants-initialized-at-start))

(ensure-native-loaded!)
(define init-count-after-first (native-init-count))

(ensure-native-loaded!)
(ensure-native-loaded!)
(define init-count-after-more (native-init-count))

(test-equal "one call runs the initialiser body exactly once"
  1 init-count-after-first)

(test-equal "further calls do not re-run the initialiser body"
  1 init-count-after-more)

(test-equal "native-initialized? flips to true once the gate has run"
  #t (native-initialized?))

(test-equal "constants-initialized? flips to true once the snapshot is built"
  #t (constants-initialized?))

;; ensure-native-loaded! is what forces the constants snapshot (design spec
;; S4). Same seeding: 0 before, exactly 1 after, and it does not rebuild.
(test-equal "before any call, the constants snapshot has not been built"
  0 constants-count-at-start)

(test-equal "ensure-native-loaded! builds the constants snapshot exactly once"
  1 (constants-init-count))

;; constants-init! carries its OWN double-init guard, independent of
;; ensure-native-loaded!'s. Calling ensure-native-loaded! twice cannot
;; exercise it -- the outer guard short-circuits first -- so it is called
;; directly here, which is possible precisely because (libuv private
;; constants) takes its lookup procedures as arguments rather than importing
;; the FFI. Every one of those arguments RAISES if consulted, so this cannot
;; pass by way of a re-initialisation that happens to recompute the same
;; values: if the guard is gone, the lookup fires and the assertion fails.
(test-equal "a direct second constants-init! is a no-op and never consults its lookups"
  1
  (begin
    (constants-init! (lambda (name) (raise 'lookup-must-not-be-consulted))
                     (lambda () (raise 'errno-count-must-not-be-consulted))
                     (lambda (i) (raise 'errno-name-must-not-be-consulted))
                     (lambda (i) (raise 'errno-value-must-not-be-consulted)))
    (constants-init-count)))

;; ...and the snapshot itself survived that call intact.
(test-equal "the snapshot still answers after a rejected re-initialisation"
  'EOF (errno-value->symbol (uv-eof)))

;; --- version gate -------------------------------------------------------
;; The range comes from generated config.sls, never from a literal here: the
;; floor lives in exactly one place (the Makefile's UV_FLOOR_MAJOR/MINOR),
;; and a test that restated it would pass against a shifted range.
(define range-lo (car uv-supported-version-range))
(define range-hi (cdr uv-supported-version-range))

;; Every rejection case is written as (not ...) with expected #t, never as
;; expected #f: SRFI-64 turns a raise in the actual expression into #f, so an
;; expected-#f assertion would pass if the predicate blew up (AGENTS.md).
(test-equal "version-supported? accepts the floor of the configured range"
  #t (version-supported? range-lo))

(test-equal "version-supported? accepts the ceiling of the configured range"
  #t (version-supported? range-hi))

(test-equal "version-supported? rejects one below the floor"
  #t (not (version-supported? (- range-lo 1))))

(test-equal "version-supported? rejects one above the ceiling"
  #t (not (version-supported? (+ range-hi 1))))

(test-equal "version-compatible? accepts a compiled/runtime pair at the floor"
  #t (version-compatible? range-lo range-lo))

(test-equal "version-compatible? accepts a compiled/runtime pair at the ceiling"
  #t (version-compatible? range-hi range-hi))

;; A runtime libuv newer than the shim's headers, both inside the range, is
;; the ordinary case for a patch upgrade and must be ACCEPTED -- otherwise
;; the range check would be an equality check wearing a range's clothes.
(test-equal "version-compatible? accepts a runtime ahead of the compiled version, both in range"
  #t (version-compatible? range-lo range-hi))

;; ...but checking `compiled` too is what catches a shim built against an
;; unsupported header while the runtime is fine. Without that half, this
;; assertion passes vacuously.
(test-equal "version-compatible? rejects a compiled version below the floor"
  #t (not (version-compatible? (- range-lo 1) range-lo)))

(test-equal "version-compatible? rejects a runtime above the ceiling"
  #t (not (version-compatible? range-hi (+ range-hi 1))))

(test-equal "version-compatible? rejects a self-consistent pair outside the range"
  #t (not (version-compatible? (- range-lo 1) (- range-lo 1))))

;; The live pair really is inside the range -- this is what ensure-native-
;; loaded! just checked, restated against the actual shim and library so the
;; boundary tests above cannot be the only thing keeping the gate honest.
(test-equal "the shim's compiled version and the runtime libuv are both in range"
  #t (version-compatible? (shim-compiled-version) (uv-version)))

;; --- the version gate's RAISE arm and its payload -----------------------
;; version-compatible? is a pure predicate; the gate that acts on it is
;; check-version-compatible!, and against a matching shim its raise arm runs
;; zero times per process. Calling it directly with synthetic versions is
;; therefore the only way the &uv-version-incompatible payload can be
;; asserted at all -- without these, swapping the condition's two arguments
;; would be an entirely uncaught mutation.
;;
;; The two probes are DISTINCT and both out of range, so a compiled/runtime
;; swap cannot hide behind two same-typed fields (the same discipline
;; test-conditions.sps uses for this condition type).
(define incompatible-compiled (- range-lo 2))
(define incompatible-runtime  (- range-lo 1))

(test-equal "check-version-compatible! returns the runtime version for an in-range pair"
  range-hi (check-version-compatible! range-lo range-hi))

(test-equal "check-version-compatible! raises uv-version-incompatible for an out-of-range pair"
  #t
  (guard (e ((uv-version-incompatible? e) #t) (#t 'wrong-condition))
    (check-version-compatible! incompatible-compiled incompatible-runtime)
    'no-raise))

(test-equal "the raised condition carries the COMPILED version in its compiled field"
  incompatible-compiled
  (guard (e ((uv-version-incompatible? e) (uv-version-incompatible-compiled e))
            (#t 'wrong-condition))
    (check-version-compatible! incompatible-compiled incompatible-runtime)
    'no-raise))

(test-equal "the raised condition carries the RUNTIME version in its runtime field"
  incompatible-runtime
  (guard (e ((uv-version-incompatible? e) (uv-version-incompatible-runtime e))
            (#t 'wrong-condition))
    (check-version-compatible! incompatible-compiled incompatible-runtime)
    'no-raise))

;; A shim built against an unsupported header while the runtime is fine must
;; still be rejected, and must report the in-range runtime unaltered -- the
;; asymmetric case, where a payload swap is most tempting to overlook.
(test-equal "an out-of-range compiled version with an in-range runtime still raises, payload intact"
  (list (- range-lo 1) range-hi)
  (guard (e ((uv-version-incompatible? e)
             (list (uv-version-incompatible-compiled e)
                   (uv-version-incompatible-runtime e)))
            (#t 'wrong-condition))
    (check-version-compatible! (- range-lo 1) range-hi)
    'no-raise))

(test-equal "the raised condition is also a uv-error"
  #t
  (guard (e ((uv-error? e) #t) (#t 'wrong-condition))
    (check-version-compatible! incompatible-compiled incompatible-runtime)
    'no-raise))

;; uv_version_string() and the packed uv_version() must agree. Not asserted
;; against a hardcoded "1.52.1", which would only pin the fixture: the
;; expected value is DECODED from the packed integer, so a stale pointer, an
;; empty string, or a wrong-width read all fail here.
(define (decode-version v)
  (string-append
   (number->string (bitwise-arithmetic-shift-right v 16)) "."
   (number->string (bitwise-and (bitwise-arithmetic-shift-right v 8) #xff)) "."
   (number->string (bitwise-and v #xff))))

(test-equal "uv-version-string agrees with the packed uv_version()"
  (decode-version (uv-version))
  (uv-version-string))

;; --- constants: the snapshot (ADR-0005) ---------------------------------
;; The three run modes must be three DIFFERENT values. A snapshot that
;; resolved all three names to the same entry -- or to a default -- would
;; silently make uv-run 'once behave as 'default.
(define (pairwise-distinct? xs)
  (cond ((null? xs) #t)
        ((memv (car xs) (cdr xs)) #f)
        (else (pairwise-distinct? (cdr xs)))))

(test-equal "the three uv_run modes are pairwise distinct"
  #t
  (pairwise-distinct? (list (uv-run-default) (uv-run-once) (uv-run-nowait))))

;; Every struct size the binding allocates against must be positive. A zero
;; would mean the name resolved to a default and every handle allocation
;; would be a zero-byte block -- an immediate heap corruption, not an error.
(define sizeof-accessors
  (list (cons 'SIZEOF_UV_LOOP_T     sizeof-uv-loop-t)
        (cons 'SIZEOF_UV_TCP_T      sizeof-uv-tcp-t)
        (cons 'SIZEOF_UV_TIMER_T    sizeof-uv-timer-t)
        (cons 'SIZEOF_UV_WRITE_T    sizeof-uv-write-t)
        (cons 'SIZEOF_UV_CONNECT_T  sizeof-uv-connect-t)
        (cons 'SIZEOF_UV_SHUTDOWN_T sizeof-uv-shutdown-t)
        (cons 'SIZEOF_UV_BUF_T      sizeof-uv-buf-t)
        (cons 'SIZEOF_SOCKADDR_IN   sizeof-sockaddr-in)
        (cons 'SIZEOF_SOCKADDR_STORAGE sizeof-sockaddr-storage)
        (cons 'SIZEOF_UV_GETADDRINFO_T sizeof-uv-getaddrinfo-t)
        (cons 'SIZEOF_UV_GETNAMEINFO_T sizeof-uv-getnameinfo-t)
        (cons 'SIZEOF_ADDRINFO      sizeof-addrinfo)
        (cons 'SIZEOF_SOCKADDR_IN6  sizeof-sockaddr-in6)))

(for-each
 (lambda (entry)
   (test-equal (string-append "snapshot: " (symbol->string (car entry))
                              " is a positive size")
     #t
     (positive? ((cdr entry)))))
 sizeof-accessors)

;; The runtime accessors and the compile-time sizeof must agree -- spike
;; FINDINGS Q-1 finding 1 is what lets the binding allocate handles from
;; uv_handle_size() rather than needing a struct definition. If they ever
;; diverged, every handle allocation would be the wrong size.
(test-equal "uv_loop_size() agrees with the shim's sizeof(uv_loop_t)"
  (sizeof-uv-loop-t) (uv-loop-size))

(test-equal "uv_handle_size(UV_TCP) agrees with the shim's sizeof(uv_tcp_t)"
  (sizeof-uv-tcp-t) (uv-handle-size (uv-tcp-type)))

(test-equal "uv_handle_size(UV_TIMER) agrees with the shim's sizeof(uv_timer_t)"
  (sizeof-uv-timer-t) (uv-handle-size (uv-timer-type)))

(test-equal "uv_req_size(UV_WRITE) agrees with the shim's sizeof(uv_write_t)"
  (sizeof-uv-write-t) (uv-req-size (uv-write-req-type)))

(test-equal "uv_req_size(UV_CONNECT) agrees with the shim's sizeof(uv_connect_t)"
  (sizeof-uv-connect-t) (uv-req-size (uv-connect-req-type)))

(test-equal "uv_req_size(UV_SHUTDOWN) agrees with the shim's sizeof(uv_shutdown_t)"
  (sizeof-uv-shutdown-t) (uv-req-size (uv-shutdown-req-type)))

(test-equal "uv_req_size(UV_GETADDRINFO) agrees with the shim's sizeof(uv_getaddrinfo_t)"
  (sizeof-uv-getaddrinfo-t) (uv-req-size (uv-getaddrinfo-req-type)))

(test-equal "uv_req_size(UV_GETNAMEINFO) agrees with the shim's sizeof(uv_getnameinfo_t)"
  (sizeof-uv-getnameinfo-t) (uv-req-size (uv-getnameinfo-req-type)))

;; The five request tags are distinct members of uv_req_type, exactly as
;; UV_TCP/UV_TIMER are of uv_handle_type. Without this, a snapshot that
;; collapsed them would still satisfy the five assertions above only if the
;; sizes happened to coincide -- which two of them nearly do.
(test-equal "the write, connect, shutdown, getaddrinfo, and getnameinfo request tags are pairwise distinct"
  #t
  (pairwise-distinct? (list (uv-write-req-type) (uv-connect-req-type)
                            (uv-shutdown-req-type)
                            (uv-getaddrinfo-req-type)
                            (uv-getnameinfo-req-type))))

;; UV_TCP and UV_TIMER are different members of uv_handle_type; a snapshot
;; that collapsed them would make the two handle families indistinguishable.
(test-equal "the tcp and timer handle type tags are distinct"
  #t (not (= (uv-tcp-type) (uv-timer-type))))

(test-equal "AF_INET and AF_UNSPEC are distinct"
  #t (not (= (af-inet) (af-unspec))))

;; --- constants: the DNS additions (design spec v0.2 S5.2) ---------------
;; Presence is enforced at init (a snapshot name the shim lacks raises
;; &uv-constant-unavailable before any row here runs); what these rows add
;; is INTERNAL consistency -- distinctness, bounds -- never a
;; platform-specific value. glibc and Darwin genuinely disagree on the
;; addrinfo layout (ai_addr/ai_canonname swap order), which is exactly why
;; a value assertion here would be wrong on one platform.
(test-equal "the three address families are pairwise distinct"
  #t (pairwise-distinct? (list (af-unspec) (af-inet) (af-inet6))))

(test-equal "the three socket types are pairwise distinct"
  #t (pairwise-distinct? (list (sock-stream) (sock-dgram) (sock-raw))))

(test-equal "IPPROTO_TCP and IPPROTO_UDP are distinct"
  #t (not (= (ipproto-tcp) (ipproto-udp))))

;; The AI_/NI_ constants are OR-combinable bit flags: a zero would be a
;; no-op that silently drops the caller's request, and two equal values
;; would make two spellings of the hints vocabulary indistinguishable.
(define ai-flag-accessors
  (list (cons 'AI_PASSIVE     ai-passive)
        (cons 'AI_CANONNAME   ai-canonname)
        (cons 'AI_NUMERICHOST ai-numerichost)
        (cons 'AI_NUMERICSERV ai-numericserv)))

(define ni-flag-accessors
  (list (cons 'NI_NUMERICHOST ni-numerichost)
        (cons 'NI_NUMERICSERV ni-numericserv)
        (cons 'NI_NAMEREQD    ni-namereqd)
        (cons 'NI_DGRAM       ni-dgram)))

(for-each
 (lambda (entry)
   (test-equal (string-append "snapshot: " (symbol->string (car entry))
                              " is a nonzero flag")
     #t
     (positive? ((cdr entry)))))
 (append ai-flag-accessors ni-flag-accessors))

(test-equal "the four AI_ flags are pairwise distinct"
  #t (pairwise-distinct? (map (lambda (e) ((cdr e))) ai-flag-accessors)))

(test-equal "the four NI_ flags are pairwise distinct"
  #t (pairwise-distinct? (map (lambda (e) ((cdr e))) ni-flag-accessors)))

;; The eight addrinfo field offsets. ai_flags sits at offset 0 on both
;; glibc and Darwin, so positivity is NOT asserted -- zero is a legal
;; offset. What cannot legally happen: two fields at the same offset, or a
;; field starting outside the struct the same shim measured.
(define addrinfo-offset-accessors
  (list (cons 'OFFSETOF_ADDRINFO_AI_FLAGS     offsetof-addrinfo-ai-flags)
        (cons 'OFFSETOF_ADDRINFO_AI_FAMILY    offsetof-addrinfo-ai-family)
        (cons 'OFFSETOF_ADDRINFO_AI_SOCKTYPE  offsetof-addrinfo-ai-socktype)
        (cons 'OFFSETOF_ADDRINFO_AI_PROTOCOL  offsetof-addrinfo-ai-protocol)
        (cons 'OFFSETOF_ADDRINFO_AI_ADDRLEN   offsetof-addrinfo-ai-addrlen)
        (cons 'OFFSETOF_ADDRINFO_AI_ADDR      offsetof-addrinfo-ai-addr)
        (cons 'OFFSETOF_ADDRINFO_AI_CANONNAME offsetof-addrinfo-ai-canonname)
        (cons 'OFFSETOF_ADDRINFO_AI_NEXT      offsetof-addrinfo-ai-next)))

(test-equal "the eight addrinfo field offsets are pairwise distinct"
  #t
  (pairwise-distinct?
   (map (lambda (e) ((cdr e))) addrinfo-offset-accessors)))

(for-each
 (lambda (entry)
   (test-equal (string-append "snapshot: " (symbol->string (car entry))
                              " lies inside sizeof(struct addrinfo)")
     #t
     (let ((off ((cdr entry))))
       (and (>= off 0) (< off (sizeof-addrinfo))))))
 addrinfo-offset-accessors)

;; sin6_port is read with read-net-u16, so its two bytes must fit inside
;; the struct the same shim measured. And sockaddr_storage exists to hold
;; ANY sockaddr, sockaddr_in6 included -- a snapshot violating that would
;; make every storage-sized allocation too small for an IPv6 peer.
(test-equal "sin6_port's two network-order bytes fit inside sockaddr_in6"
  #t
  (<= (+ (offsetof-sockaddr-in6-sin6-port) 2) (sizeof-sockaddr-in6)))

(test-equal "sockaddr_storage can hold a sockaddr_in6"
  #t (<= (sizeof-sockaddr-in6) (sizeof-sockaddr-storage)))

;; Informational, deliberately NOT asserted: uv_buf_t is {base,len} on POSIX
;; but {len,base} on Windows (WSABUF order), so an assertion here would
;; encode a platform fact ADR-0004 has not committed to. The layout CHECK
;; that does run is the ftype-vs-shim comparison below, which fails closed
;; on any platform where the declared ftype and the real struct disagree.
(display "  [informational] uv_buf_t offsets on this platform: base=")
(display (offsetof-uv-buf-t-base))
(display " len=")
(display (offsetof-uv-buf-t-len))
(display " sizeof=")
(display (sizeof-uv-buf-t))
(newline)
(display "  [informational] sockaddr_in offsets: sin_family=")
(display (offsetof-sockaddr-in-sin-family))
(display " sin_port=")
(display (offsetof-sockaddr-in-sin-port))
(newline)
;; Informational for the same reason as the two above: glibc orders ai_addr
;; before ai_canonname, Darwin the reverse, so the ORDER of these two is a
;; platform fact no assertion should encode (design spec v0.2 S5.2).
(display "  [informational] addrinfo offsets: ai_addr=")
(display (offsetof-addrinfo-ai-addr))
(display " ai_canonname=")
(display (offsetof-addrinfo-ai-canonname))
(display " sizeof=")
(display (sizeof-addrinfo))
(newline)

;; --- v0.3 process/pipe constants (THE SPEC §5.3; ADR-0005) --------------
;; Structural sanity only: values are platform truths, so the assertions
;; are relations, never literals.
(test-assert "process options struct has positive size"
  (positive? (sizeof-uv-process-options-t)))
(test-assert "every options offset lies inside the struct"
  (for-all (lambda (off) (and (>= off 0) (< off (sizeof-uv-process-options-t))))
           (list (offsetof-uv-process-options-t-exit-cb)
                 (offsetof-uv-process-options-t-file)
                 (offsetof-uv-process-options-t-args)
                 (offsetof-uv-process-options-t-env)
                 (offsetof-uv-process-options-t-cwd)
                 (offsetof-uv-process-options-t-flags)
                 (offsetof-uv-process-options-t-stdio-count)
                 (offsetof-uv-process-options-t-stdio)
                 (offsetof-uv-process-options-t-uid)
                 (offsetof-uv-process-options-t-gid))))
(test-assert "stdio container: flags precede data, both inside"
  (and (>= (offsetof-uv-stdio-container-t-flags) 0)
       (> (offsetof-uv-stdio-container-t-data)
          (offsetof-uv-stdio-container-t-flags))
       (< (offsetof-uv-stdio-container-t-data)
          (sizeof-uv-stdio-container-t))))
(test-assert "the three process flags are distinct nonzero bits"
  (let ((flags (list (uv-process-setuid-flag) (uv-process-setgid-flag)
                     (uv-process-detached-flag))))
    (and (for-all positive? flags)
         (= 3 (length flags))
         (zero? (bitwise-and (car flags) (cadr flags)))
         (zero? (bitwise-and (car flags) (caddr flags)))
         (zero? (bitwise-and (cadr flags) (caddr flags))))))
(test-equal "UV_IGNORE is zero (the header's own definition)"
  0 (uv-stdio-ignore))
(test-assert "the stdio modes and direction bits are distinct"
  (let ((bits (list (uv-stdio-create-pipe) (uv-stdio-inherit-fd)
                    (uv-stdio-inherit-stream) (uv-stdio-readable-pipe)
                    (uv-stdio-writable-pipe))))
    (and (for-all positive? bits)
         (= (length bits)
            (length (filter (lambda (b) (= 1 (length (filter (lambda (c) (= b c)) bits)))) bits))))))
(test-assert "nine signals, all positive and distinct"
  (let ((sigs (list (sig-term) (sig-kill) (sig-int) (sig-hup) (sig-quit)
                    (sig-usr1) (sig-usr2) (sig-cont) (sig-stop))))
    (and (for-all positive? sigs)
         (= 9 (length sigs))
         (let loop ((s sigs))
           (or (null? s)
               (and (not (memv (car s) (cdr s))) (loop (cdr s))))))))
(test-assert "process/pipe type tags resolve"
  (and (integer? (uv-process-type)) (integer? (uv-named-pipe-type))))

;; v0.4 signal (design spec 2026-08-22 S5.5; ADR-0017): UV_SIGNAL must be a
;; snapshotted, distinct handle type tag, exactly like every other
;; uv_handle_type member above.
(test-equal "UV_SIGNAL is snapshotted and distinct from the other handle type tags"
  'distinct-positive
  (if (and (integer? (uv-signal-type))
           (exact? (uv-signal-type))
           (positive? (uv-signal-type))
           (not (memv (uv-signal-type)
                      (list (uv-timer-type) (uv-tcp-type)
                            (uv-process-type) (uv-named-pipe-type)))))
      'distinct-positive
      'wrong))

;; #20 async (issue #20, threading arc): UV_ASYNC must be a snapshotted,
;; distinct handle type tag, exactly like UV_SIGNAL above. Sized at runtime via
;; (uv-handle-size (uv-async-type)); no SIZEOF_UV_ASYNC_T (signal precedent).
(test-equal "UV_ASYNC is snapshotted and distinct from the other handle type tags"
  'distinct-positive
  (if (and (integer? (uv-async-type))
           (exact? (uv-async-type))
           (positive? (uv-async-type))
           (not (memv (uv-async-type)
                      (list (uv-timer-type) (uv-tcp-type) (uv-signal-type)
                            (uv-process-type) (uv-named-pipe-type)))))
      'distinct-positive
      'wrong))

;; --- constants: a name the shim does not have (ADR-0005) ----------------
;; The failure must be structured and must NAME the missing constant. A
;; default value, a zero, or a bare #f here is the exact silent-transcription
;; failure ADR-0005 exists to prevent. The sentinel 'no-raise (not #f) is the
;; no-raise case, since SRFI-64 turns a raise into #f (AGENTS.md).
(test-equal "a constant name the shim does not define raises uv-constant-unavailable"
  #t
  (guard (e ((uv-constant-unavailable? e) #t) (#t 'wrong-condition))
    (constant-ref 'UV_NO_SUCH_CONSTANT_ZZZ_9F3A)
    'no-raise))

(test-equal "the raised condition names the missing constant"
  'UV_NO_SUCH_CONSTANT_ZZZ_9F3A
  (guard (e ((uv-constant-unavailable? e) (uv-constant-unavailable-name e))
            (#t 'wrong-condition))
    (constant-ref 'UV_NO_SUCH_CONSTANT_ZZZ_9F3A)
    'no-raise))

;; The positive control for the two above: a name the shim DOES define must
;; come back as its value, not raise. Without this, a constant-ref that
;; raised unconditionally would satisfy both assertions above.
(test-equal "a constant name the shim does define resolves to the snapshot's value"
  (uv-eof)
  (constant-ref 'UV_EOF))

;; A name holding a NUL names no constant. The shim reads a name as a C
;; string, up to its first NUL, so this one resolved to UV_EOF's value
;; while names crossed as Chez strings (#64).
(define nul-name (string->symbol "UV_EOF\x0;junk"))

(test-equal "a constant name holding a NUL names no constant, not the one before its NUL"
  (list 'unavailable nul-name)
  (guard (e ((uv-constant-unavailable? e)
             (list 'unavailable (uv-constant-unavailable-name e)))
            (#t (list 'wrong-condition (describe e))))
    (list 'answered (constant-ref nul-name))))

;; --- errno enumeration (ADR-0006) ---------------------------------------
(test-equal "the errno enumeration is non-empty"
  #t (positive? (errno-count)))

(test-equal "errno-symbols lists one symbol per enumeration entry"
  (errno-count) (length (errno-symbols)))

;; The mapping's most load-bearing single entry: UV_EOF is what the read
;; path discriminates on, and it is the one libuv value that is identical
;; across platforms (spike FINDINGS Q-1 finding 4).
(test-equal "errno-value->symbol maps UV_EOF's value to 'EOF"
  'EOF (errno-value->symbol (uv-eof)))

(test-equal "errno-symbol->value maps 'EOF back to UV_EOF's value"
  (uv-eof) (errno-symbol->value 'EOF))

;; Precondition for the round-trip below, asserted separately so that if a
;; platform ever ships an aliased errno pair the failure names the real
;; cause instead of showing up as a confusing round-trip mismatch.
(test-equal "no two errno names share a value on this platform"
  #t
  (pairwise-distinct? (map errno-symbol->value (errno-symbols))))

;; Round-trip over the WHOLE enumeration, not a sample: swapping any two
;; entries at snapshot time must be caught here.
(test-equal "every errno symbol round-trips symbol -> value -> symbol"
  (errno-symbols)
  (map (lambda (s) (errno-value->symbol (errno-symbol->value s)))
       (errno-symbols)))

;; libuv's own uv_err_name_r must agree with the shim's snapshot for every
;; entry: two independent sources for the same mapping, so a snapshot built
;; from the wrong index -- or an off-by-one in the enumeration walk -- shows
;; up here even though the round-trip above would still be self-consistent.
(test-equal "the snapshot agrees with uv_err_name_r for every errno value"
  (errno-symbols)
  (map (lambda (s) (errno->symbol (errno-symbol->value s))) (errno-symbols)))

;; An unmapped code must fall back to the documented sentinel, not to #f and
;; not to a wrong symbol. The absence of the probe code is asserted first,
;; so this cannot pass because the probe code happens to be in the table.
;;
;; The obvious probe -- UV_EOF + 1 -- is NOT unmapped: libuv reserves -4094
;; for its own `XX(UNKNOWN, ...)` entry, which the shim exports under the
;; bare name "UNKNOWN". (Discovered by this very assertion failing on the
;; first GREEN run; it is the reason the probe code is checked rather than
;; assumed.) UV_EOF - 1 is below libuv's entire sentinel range instead.
(define probe-unknown-code (- (uv-eof) 1))

(test-equal "the probe code used for the unknown-errno case really is unmapped"
  #t
  (not (memv probe-unknown-code (map errno-symbol->value (errno-symbols)))))

(test-equal "an unmapped errno value falls back to 'UV_UNKNOWN"
  'UV_UNKNOWN (errno-value->symbol probe-unknown-code))

;; The fallback symbol cannot collide with a real name: libuv's own names are
;; the bare UV_ERRNO_MAP tokens ("EOF", "ECONNRESET"), never UV_-prefixed.
;; This matters concretely rather than theoretically -- libuv HAS an errno
;; called UNKNOWN (value -4094), which the shim exports unprefixed, so
;; 'UV_UNKNOWN (the binding's "no name for this code" answer) and 'UNKNOWN
;; (libuv's own named code) stay two different things.
(test-equal "'UV_UNKNOWN is not itself a real errno name"
  #t (not (memq 'UV_UNKNOWN (errno-symbols))))

(test-equal "libuv's own UNKNOWN errno is a real, distinct entry"
  'UNKNOWN (errno-value->symbol (errno-symbol->value 'UNKNOWN)))

;; errno->message goes through uv_strerror_r into a scratch buffer. Asserted
;; as a non-empty string rather than against libuv's exact wording, which is
;; not part of any contract -- but "non-empty string" already rules out #f,
;; "", and a stale/NULL pointer read.
(test-equal "errno->message returns a non-empty string for a real errno"
  #t
  (let ((m (errno->message (uv-eof))))
    (and (string? m) (positive? (string-length m)))))

(test-equal "errno->message returns different text for two different errnos"
  #t
  (not (string=? (errno->message (uv-eof))
                 (errno->message (errno-symbol->value 'EACCES)))))

;; --- uv-check (design spec S9) ------------------------------------------
;; The "0 is truthy" trap, head on: a uv-check written as (if rc rc (raise ...))
;; never raises at all, because every integer including 0 is true in Scheme.
;; The raise-path assertion below therefore compares the errno SYMBOL against
;; an expected value, with 'no-raise as the sentinel for "nothing was raised"
;; -- if it expected #f instead, both the mutation AND a correct
;; implementation would satisfy it.
(test-equal "uv-check passes a zero return code straight through"
  0 (uv-check 0 'test-who))

(test-equal "uv-check raises uv-errno-error on a negative return code"
  #t
  (guard (e ((uv-errno-error? e) #t) (#t 'wrong-condition))
    (uv-check (uv-eof) 'test-who)
    'no-raise))

(test-equal "the raised condition carries the errno as a symbol"
  'EOF
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e)) (#t 'wrong-condition))
    (uv-check (uv-eof) 'test-who)
    'no-raise))

;; ADR-0006: the raw platform int stays reachable for diagnostics even though
;; the symbol is the discriminant. Several libuv errnos are derived from the
;; host errno.h and differ across platforms (spike FINDINGS Q-1 finding 3),
;; so the expected value is the constant, never a literal.
(test-equal "the raised condition preserves the raw return code"
  (uv-eof)
  (guard (e ((uv-errno-error? e) (uv-errno-error-code e)) (#t 'wrong-condition))
    (uv-check (uv-eof) 'test-who)
    'no-raise))

(test-equal "the raised condition carries uv_strerror_r's message"
  (errno->message (uv-eof))
  (guard (e ((uv-errno-error? e) (uv-errno-error-message e)) (#t 'wrong-condition))
    (uv-check (uv-eof) 'test-who)
    'no-raise))

;; The compound also carries &who, so a caller sees WHICH call failed. `who`
;; is the sentinel symbol passed in above, which no failure path invents.
(test-equal "the raised condition names the calling procedure via &who"
  'test-who
  (guard (e ((who-condition? e) (condition-who e)) (#t 'wrong-condition))
    (uv-check (uv-eof) 'test-who)
    'no-raise))

(test-equal "the raised condition is also a uv-error"
  #t
  (guard (e ((uv-error? e) #t) (#t 'wrong-condition))
    (uv-check (uv-eof) 'test-who)
    'no-raise))

;; An unmapped negative code must still raise, with the fallback symbol --
;; failing closed rather than passing an unrecognised failure through.
(test-equal "uv-check raises with 'UV_UNKNOWN for an unmapped negative code"
  'UV_UNKNOWN
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e)) (#t 'wrong-condition))
    (uv-check probe-unknown-code 'test-who)
    'no-raise))

;; --- c-string->string (ADR-0009) ----------------------------------------
;; NULL must stay distinguishable from the empty string: uv_err_name_r and
;; friends can return either, and conflating them invents data.
;;
;; Written as (not …) with expected #t, NOT as expected #f: SRFI-64 folds any
;; raise in the actual expression into #f, so `(test-equal … #f (c-string->string 0))`
;; would pass identically against a c-string->string that blew up on a null
;; address -- the exact AGENTS.md trap. The (not …) form turns a raise into a
;; propagating failure instead.
(test-equal "c-string->string maps NULL to #f"
  #t (not (c-string->string 0)))

;; ...and #f specifically, not some other false-ish answer. Paired with the
;; above so the distinction from "" below is pinned from both directions.
(test-equal "c-string->string's NULL answer is exactly #f, not '() or 0"
  'is-false
  (let ((v (c-string->string 0))) (if (eq? v #f) 'is-false v)))

(let ((buf (foreign-alloc 1)))
  (foreign-set! 'unsigned-8 buf 0 0)
  (test-equal "c-string->string maps a zero-length buffer to \"\", not #f"
    "" (c-string->string buf))
  (foreign-free buf))

;; Multi-byte UTF-8 must decode by codepoint, not by byte: "caf" + U+00E9
;; encodes as 5 bytes but is 4 characters. The expected value is built with
;; integer->char so the test does not depend on this file's own encoding.
(let ((buf (foreign-alloc 6))
      (expected (string #\c #\a #\f (integer->char #xe9))))
  (foreign-set! 'unsigned-8 buf 0 #x63)
  (foreign-set! 'unsigned-8 buf 1 #x61)
  (foreign-set! 'unsigned-8 buf 2 #x66)
  (foreign-set! 'unsigned-8 buf 3 #xc3)
  (foreign-set! 'unsigned-8 buf 4 #xa9)
  (foreign-set! 'unsigned-8 buf 5 0)
  (test-equal "c-string->string decodes multi-byte UTF-8 by codepoint"
    expected (c-string->string buf))
  (foreign-free buf))

;; The single most important property here: it must COPY, not alias. Every
;; string libuv hands back is borrowed, so an aliasing conversion would make
;; every one of them a latent use-after-free.
(let ((buf (foreign-alloc 3)))
  (foreign-set! 'unsigned-8 buf 0 (char->integer #\h))
  (foreign-set! 'unsigned-8 buf 1 (char->integer #\i))
  (foreign-set! 'unsigned-8 buf 2 0)
  (let ((s (c-string->string buf)))
    (foreign-set! 'unsigned-8 buf 0 (char->integer #\X))
    (foreign-set! 'unsigned-8 buf 1 (char->integer #\X))
    (test-equal "c-string->string copies: mutating the source afterwards leaves the result unchanged"
      "hi" s))
  (foreign-free buf))

;; --- memory helpers ------------------------------------------------------
;; zero-out! is tested with the buffer SEEDED non-zero, and the seeding is
;; itself asserted first -- otherwise "every byte is zero" would pass against
;; a zero-out! that does nothing, on memory the allocator happened to hand
;; back clean (AGENTS.md's "seed an output variable before asserting it is
;; empty").
(define (all-bytes-equal? addr len v)
  (let loop ((i 0))
    (cond ((= i len) #t)
          ((= (foreign-ref 'unsigned-8 addr i) v) (loop (+ i 1)))
          (else #f))))

(let ((addr (foreign-alloc 64)))
  (let fill ((i 0))
    (when (< i 64) (foreign-set! 'unsigned-8 addr i #xff) (fill (+ i 1))))
  (test-equal "the zero-out! probe buffer really was seeded non-zero first"
    #t (all-bytes-equal? addr 64 #xff))
  (zero-out! addr 64)
  (test-equal "zero-out! clears every byte it was given"
    #t (all-bytes-equal? addr 64 0))
  (foreign-free addr))

;; zero-out! is in the group whose contract is "fails as a structured
;; condition rather than a segfault". (zero-out! 0 64) writes through NULL,
;; so the null check is the difference between a condition and a crash.
(test-equal "zero-out! rejects a null destination"
  'uv-zero-out!
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-who e))
            (#t 'wrong-condition))
    (zero-out! 0 64)
    'no-raise))

;; The rejection must happen BEFORE any write. The buffer is seeded #xff,
;; asserted #xff, then must still be #xff afterwards. Since #35 no single
;; mutation of zero-out! can break "wrote nothing": the shim's memset
;; receives the length through a size_t argument, and Chez refuses 3.0 there
;; before C runs. The check-before-call ORDER is pinned instead by the
;; rejection row's who, which a raise from the FFI would not carry. This row
;; still fails if zero-out! goes back to a Scheme loop that writes before it
;; validates -- `(< i 3.0)` is true, so such a loop zeroes three bytes -- the
;; shape it was written against (stage-1 M52; bulk-copy mutation log).
(let ((addr (foreign-alloc 64)))
  (let fill ((i 0))
    (when (< i 64) (foreign-set! 'unsigned-8 addr i #xff) (fill (+ i 1))))
  (test-equal "the zero-out!-ordering probe buffer really was seeded non-zero first"
    #t (all-bytes-equal? addr 64 #xff))
  (test-equal "zero-out! rejects an inexact length"
    'uv-zero-out!
    (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-who e))
              (#t 'wrong-condition))
      (zero-out! addr 3.0)
      'no-raise))
  (test-equal "zero-out! wrote nothing before rejecting"
    #t (all-bytes-equal? addr 64 #xff))
  (foreign-free addr))

(test-equal "zero-out! rejects a negative length"
  'uv-zero-out!
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-who e))
            (#t 'wrong-condition))
    (zero-out! 4096 -1)
    'no-raise))

;; zero-out! must not run past its length. Seeded the same way: the guard
;; byte is set non-zero, checked non-zero, then must SURVIVE the call.
(let ((addr (foreign-alloc 65)))
  (let fill ((i 0))
    (when (< i 65) (foreign-set! 'unsigned-8 addr i #xff) (fill (+ i 1))))
  (zero-out! addr 64)
  (test-equal "zero-out! does not write past the length it was given"
    #xff (foreign-ref 'unsigned-8 addr 64))
  (foreign-free addr))

;; alloc-zeroed must zero even when the allocator hands back a dirty block --
;; fresh pages are often already zero, so "the block I just got is zero"
;; proves nothing on its own.
;;
;; The size matters, and is not arbitrary: macOS routes small allocations
;; (<= ~256 bytes) through the nano zone, which returns them CLEAN, so a
;; churn at 128 bytes is non-discriminating there. sizeof(uv_loop_t) is both
;; large enough to leave that zone and the size this binding will actually
;; allocate at, so the test exercises the real case.
;;
;; The dirt is laid through the shim's own allocator, which alloc-zeroed
;; uses (chez_uv_alloc). The shim does not draw on the blocks Chez's
;; foreign-free releases: measured on macOS, a block foreign-free had just
;; released came back from the shim 0 times in 200, and one the shim had
;; just freed came back 200 times in 200. A churn through foreign-alloc, as
;; this row once used, left the shim nothing dirty, and a shim that did not
;; zero (malloc in place of calloc) passed it in three runs of five (the
;; stream-step mutation log). So each allocation first dirties a block
;; through the shim and frees it, and records whether alloc-zeroed was
;; handed that very block and whether it came back zeroed.
(define churn-size (sizeof-uv-loop-t))

;; dirty-then-alloc-zeroed : -> (list reused? zeroed?)
(define (dirty-then-alloc-zeroed)
  (let ((dirty (alloc-block churn-size)))
    (libc-memset! dirty #xff churn-size)
    (free-block! dirty)
    (let* ((a (alloc-zeroed churn-size))
           (seen (list (= a dirty) (all-bytes-equal? a churn-size 0))))
      (free! a)
      seen)))

(define shim-dirt
  (let loop ((i 0) (acc '()))
    (if (= i 32)
        acc
        (loop (+ i 1) (cons (dirty-then-alloc-zeroed) acc)))))

;; The seed: the row below can fail only if alloc-zeroed was handed a block
;; just dirtied. Neither memory tool hands back a block just freed. Memcheck's
;; freelist (--freelist-vol, ~20MB by default) and ASan's quarantine both
;; delay reuse so that they can still flag a use-after-free. make
;; test-memory sets CHEZ_LIBUV_UNDER_VALGRIND=1 on its Linux leg and
;; ASAN_OPTIONS on its macOS one, and under either the seed requires only
;; that the allocations were made; the dirty-memory property is held by the
;; plain run (the stage-1 mutation log addendum). under-memory-tool? asks
;; the allocator as well, so a plain run that inherits ASAN_OPTIONS from a
;; shell still holds the seed.
(if under-memory-tool?
    (test-equal "seed: alloc-zeroed made every allocation (a memory tool: reuse unobservable by design)"
      32 (length shim-dirt))
    (test-equal "seed: the shim's allocator handed alloc-zeroed the very block just dirtied"
      #t (exists car shim-dirt)))

(test-equal "alloc-zeroed returns zeroed memory even when the allocator hands back a dirty block"
  #t (for-all cadr shim-dirt))

(test-equal "alloc-zeroed rejects a non-positive size"
  'uv-alloc-zeroed
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-who e))
            (#t 'wrong-condition))
    (alloc-zeroed 0)
    'no-raise))

;; --- the step forms: alloc-block, free-block!, copy-in-unchecked! ---------
;; A verb calls these inside an interrupt-free step, where a raise would
;; leave interrupts disabled for good (stream.sls). So each is total: it
;; answers or ignores an argument it cannot use, and no argument makes it
;; raise. Each row's expected value is one a raise cannot produce, since
;; SRFI-64 turns a raise in the actual expression into #f.
(test-equal "alloc-block answers 0 for a size that is not a positive fixnum, and counts no block"
  '((0 0 0 0 0) 0)
  (let* ((before (live-count 'block))
         (answers (map alloc-block (list 0 -16 (expt 2 70) 16.0 'sixteen))))
    (list answers (- (live-count 'block) before))))

(test-equal "alloc-block answers a zeroed block, counted until free-block! frees it"
  '(zeroed 1 0)
  (let* ((before (live-count 'block))
         (addr (alloc-block 64))
         (zeroed (if (and (positive? addr) (all-bytes-equal? addr 64 0))
                     'zeroed
                     (list 'not-zeroed addr)))
         (held (- (live-count 'block) before)))
    (free-block! addr)
    (list zeroed held (- (live-count 'block) before))))

;; Each input the FFI would refuse, rather than wrap: a uptr argument takes
;; -2^63 and up and wraps a negative one, so -8 would reach free() as a huge
;; address and abort the process instead of failing this row.
(test-equal "free-block! ignores what cannot be an address, 0 included, and counts nothing"
  '(ignored 0)
  (let ((before (live-count 'block)))
    (for-each free-block! (list 'addr (expt 2 64) (- (expt 2 64)) 0))
    (list 'ignored (- (live-count 'block) before))))

;; A size the allocator refuses. ASan aborts on a request this large
;; rather than answering NULL, so the macOS memory gate (which sets
;; ASAN_OPTIONS) leaves these two rows to the plain run and to Valgrind.
;; under-asan? asks the allocator as well: asked of the environment alone,
;; a plain run that inherited ASAN_OPTIONS from a shell skipped both.
(define refused-size (expt 2 59))
(unless under-asan?
  (test-equal "alloc-block answers 0 when the allocator refuses, and counts no block"
    '(0 0)
    (let* ((before (live-count 'block))
           (addr (alloc-block refused-size)))
      (list addr (- (live-count 'block) before))))

  (test-equal "alloc-zeroed raises ENOMEM under its own name when the allocator refuses"
    '(uv-alloc-zeroed ENOMEM)
    (guard (e ((uv-errno-error? e) (list (condition-who e) (uv-errno-error-errno e)))
              (#t 'wrong-condition))
      (alloc-zeroed refused-size)
      'no-raise)))

(let ((addr (alloc-zeroed 8))
      (src (u8-list->bytevector (list 10 20 30 40 50))))
  (test-equal "copy-in-unchecked! copies the requested span, honouring start, and nothing past it"
    (u8-list->bytevector (list 20 30 40 0))
    (begin
      (copy-in-unchecked! addr src 1 3)
      (copy-out addr 4)))
  (free! addr))

;; free! of a null pointer is always a bug: design spec S5/S6/S7 require the
;; freeing site to zero the stored uptr immediately, so a zeroed slot
;; reaching free! means something tried to free twice. It fails loudly rather
;; than handing 0 to the C allocator.
(test-equal "free! rejects a null pointer instead of passing it to the allocator"
  'uv-free!
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-who e))
            (#t 'wrong-condition))
    (free! 0)
    'no-raise))

;; free-block! ignores an address past the address space; free!, the checked
;; form, refuses it, as foreign-free did before the shim's free replaced it.
(test-equal "free! rejects an address past the address space"
  '(uv-free! null-or-invalid-pointer)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (free! (expt 2 64))
    'no-raise))

;; copy-in! / copy-out are the two halves of ADR-0009's copy-at-the-boundary
;; rule. Round-trip through real foreign memory, including a non-zero start
;; offset so an implementation ignoring `start` is caught. The helpers run
;; inside the rows, so one that raises fails a row by name instead of
;; aborting the suite (AGENTS.md).
(let ((addr (alloc-zeroed 8))
      (src (u8-list->bytevector (list 10 20 30 40 50))))
  (test-equal "copy-in! copies the requested span, honouring start"
    (u8-list->bytevector (list 20 30 40))
    (begin
      (copy-in! addr src 1 3)
      (copy-out addr 3)))
  (test-equal "copy-in! writes nothing past the copied length"
    0 (foreign-ref 'unsigned-8 addr 3))
  ;; copy-out must copy, not alias: mutating the source afterwards must not
  ;; change the bytevector already handed back.
  (test-equal "copy-out copies: mutating the foreign source afterwards leaves the result unchanged"
    (u8-list->bytevector (list 20 30 40))
    (let ((out (copy-out addr 3)))
      (foreign-set! 'unsigned-8 addr 0 #x7f)
      out))
  (free! addr))

(test-equal "copy-in! rejects a span that runs past the end of the bytevector"
  '(uv-copy-in! span-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (let ((addr (alloc-zeroed 8)))
      (guard (inner (#t (free! addr) (raise inner)))
        (copy-in! addr (u8-list->bytevector (list 1 2 3)) 1 3)))
    'no-raise))

;; try-copy-in! is copy-in! for a caller that owns a block it must free when
;; the span no longer fits (the write verbs): that refusal is its answer, not
;; a raise, and nothing is written.
(test-equal "try-copy-in! answers copied for a span that fits, and copies it"
  (list 'copied (u8-list->bytevector (list 20 30 40 0)))
  (let* ((addr (alloc-zeroed 4))
         (answer (try-copy-in! addr (u8-list->bytevector (list 10 20 30 40)) 1 3))
         (written (copy-out addr 4)))
    (free! addr)
    (list answer written)))

;; refused-span-under-seed : byte -> (list answer bytevector)
;; A span past the end, copied onto a destination seeded with SEED. As for
;; the empty span further down, two seeds: a refusal that wrote zeros, or
;; ones, matches one of them.
(define (refused-span-under-seed seed)
  (let ((dst (foreign-alloc 4)))
    (libc-memset! dst seed 4)
    (let* ((answer (guard (e (#t 'raised))
                     (try-copy-in! dst (u8-list->bytevector (list 1 2 3)) 1 3)))
           (written (foreign->bytevector dst 4)))
      (foreign-free dst)
      (list answer written))))

(test-equal "try-copy-in! answers span-out-of-range for a span past the end, and writes nothing"
  (list (list 'span-out-of-range (make-bytevector 4 #x00))
        (list 'span-out-of-range (make-bytevector 4 #xff)))
  (let* ((under-zeros (refused-span-under-seed #x00))
         (under-ones (refused-span-under-seed #xff)))
    (list under-zeros under-ones)))

;; Only that is answered. The caller's own mistakes raise, under copy-in!'s
;; name, so a verb can never take one for a payload that shrank.
(test-equal "try-copy-in! raises for the caller's own mistakes rather than answering"
  '((uv-copy-in! null-or-invalid-destination)
    (uv-copy-in! source-not-a-bytevector)
    (uv-copy-in! span-out-of-range))
  (let ((dst (alloc-zeroed 4)))
    (define (raised thunk)
      (guard (e ((uv-invalid-argument? e)
                 (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
                (#t 'wrong-condition))
        (list 'answered (thunk))))
    (let* ((null-dst (raised (lambda () (try-copy-in! 0 (make-bytevector 1 1) 0 1))))
           (not-bv (raised (lambda () (try-copy-in! dst "abc" 0 1))))
           (bad-start (raised (lambda ()
                                (try-copy-in! dst (make-bytevector 1 1) 'one 1)))))
      (free! dst)
      (list null-dst not-bv bad-start))))

(test-equal "copy-out rejects a null source"
  'uv-copy-out
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-who e))
            (#t 'wrong-condition))
    (copy-out 0 4)
    'no-raise))

;; A NON-NUMBER span argument is the ordering case for copy-in!'s span check,
;; exactly as an inexact length is for zero-out!'s: `exact?` is only defined
;; on numbers, so testing it before `integer?` (which is total) turns the
;; structured rejection into a bare Chez &assertion ("not a number") that
;; nothing downstream can discriminate. zero-out! already tests integer?
;; first; these two rows are what keep all three helpers agreeing on the
;; safe order.
(test-equal "copy-in! rejects a non-numeric start as a structured condition, not a bare assertion"
  '(uv-copy-in! span-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (let ((addr (alloc-zeroed 8)))
      (guard (inner (#t (free! addr) (raise inner)))
        (copy-in! addr (u8-list->bytevector (list 1 2 3)) 'one 2)))
    'no-raise))

(test-equal "copy-out rejects a non-numeric length as a structured condition, not a bare assertion"
  '(uv-copy-out length-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (copy-out 4096 'four)
    'no-raise))

;; copy-in!'s sign checks are all that stands between a negative argument and
;; the shim's memcpy: Chez's size_t accepts -2^63..2^64-1 and wraps a
;; negative value into a huge one (bulk-copy mutation log). Each row keeps
;; the span bound (<= (+ start len) (bytevector-length bv)) satisfied, so the
;; sign check is the only possible rejection. The negative length is below
;; size_t's range, so a copy-in! without its length check fails this row by
;; name when the FFI refuses the argument; a length of -1 would instead wrap
;; to SIZE_MAX and run memcpy off the heap.
(test-equal "copy-in! rejects a negative start even when start+len is in range"
  '(uv-copy-in! span-out-of-range)
  (let ((addr (alloc-zeroed 8)))
    (let ((r (guard (e ((uv-invalid-argument? e)
                        (list (uv-invalid-argument-who e)
                              (uv-invalid-argument-reason e)))
                       (#t 'wrong-condition))
               (copy-in! addr (u8-list->bytevector (list 1 2 3)) -1 1)
               'no-raise)))
      (free! addr)
      r)))

(test-equal "copy-in! rejects a negative length even when start+len is in range"
  '(uv-copy-in! span-out-of-range)
  (let ((addr (alloc-zeroed 8)))
    (let ((r (guard (e ((uv-invalid-argument? e)
                        (list (uv-invalid-argument-who e)
                              (uv-invalid-argument-reason e)))
                       (#t 'wrong-condition))
               (copy-in! addr (u8-list->bytevector (list 1 2 3))
                         (expt 2 63) (- -1 (expt 2 63)))
               'no-raise)))
      (free! addr)
      r)))

(test-equal "copy-out rejects a negative length"
  '(uv-copy-out length-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (copy-out 4096 -1)
    'no-raise))

;; --- uv-getaddrinfo-native's node and service ----------------------------
;; libuv reads each as a C string, with strlen and then a copy, so the
;; wrapper takes the bytes and refuses any that are not one C string: one
;; NUL, the last byte. The request pointer here is NULL, which libuv answers
;; with UV_EINVAL before it reads anything else (getaddrinfo.c), so a
;; wrapper that skipped its check would answer that errno instead.
(define (getaddrinfo-native-answer node service)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t (list 'wrong-condition (describe e))))
    (list 'returned (errno->symbol (uv-getaddrinfo-native 0 0 node service 0)))))

(test-equal "uv-getaddrinfo-native refuses a node or service that is not one C string, before calling libuv"
  '((uv-getaddrinfo-native not-a-c-string)    ; no terminator
    (uv-getaddrinfo-native not-a-c-string)    ; the service, no terminator
    (uv-getaddrinfo-native not-a-c-string)    ; a NUL inside
    (uv-getaddrinfo-native not-a-c-string)    ; the service, a NUL inside
    (uv-getaddrinfo-native not-a-c-string)    ; empty: no terminator either
    (uv-getaddrinfo-native not-a-c-string))   ; a string, not its bytes
  (map (lambda (args) (apply getaddrinfo-native-answer args))
       (list (list (u8-list->bytevector '(49 50)) #f)
             (list #f (u8-list->bytevector '(56 48)))
             (list (u8-list->bytevector '(49 0 50 0)) #f)
             (list #f (u8-list->bytevector '(56 0 48 0)))
             (list (u8-list->bytevector '()) #f)
             (list "127.0.0.1" #f))))

;; The other side: C strings, and #f for NULL, pass the check and reach
;; libuv, which answers EINVAL for the NULL request.
(test-equal "uv-getaddrinfo-native passes C strings and #f through to libuv"
  '((returned EINVAL) (returned EINVAL) (returned EINVAL) (returned EINVAL))
  (map (lambda (args) (apply getaddrinfo-native-answer args))
       (list (list (u8-list->bytevector '(49 0)) (u8-list->bytevector '(56 48 0)))
             (list (u8-list->bytevector '(0)) #f)
             (list #f (u8-list->bytevector '(56 48 0)))
             (list #f #f))))

;; --- bulk, not byte-at-a-time (issue #35) --------------------------------
;; copy-in!, copy-out and zero-out! each move their span in ONE call into the
;; shim. They used to loop in Scheme, one foreign-set! or foreign-ref per
;; byte, and a 4 MiB uv-write! held its loop ~250 ms: half zeroing its block,
;; half copying the payload in. Each row times its helper against libc's own
;; memcpy or memset over the same bytes and wants it within bulk-bar of libc;
;; tests/uv-bulk.sls says why libc is the reference and records the margins.
;; test-stream.sps times the write verbs the same way.
(define bulk-size (* 4 1024 1024))

(define (within-bar-name what reference)
  (string-append what " at libc speed: within " (number->string bulk-bar)
                 "x of " reference " over the same bytes"))

(test-equal "libc's memcpy and memset resolve, for the bulk rows' reference"
  #t libc-available?)

(let ((dst (foreign-alloc bulk-size))
      (src (make-bytevector bulk-size 7)))
  (test-equal (within-bar-name "copy-in! moves a span" "memcpy")
    'bulk
    (bulk-verdict 'copy-in! bulk-size
                  (lambda () (copy-in! dst src 0 bulk-size))
                  (lambda () (libc-memcpy-to-foreign! dst src bulk-size))))
  (test-equal (within-bar-name "copy-out moves a span" "allocating and memcpy")
    'bulk
    (bulk-verdict 'copy-out bulk-size
                  (lambda () (copy-out dst bulk-size))
                  (lambda () (foreign->bytevector dst bulk-size))))
  (test-equal (within-bar-name "zero-out! clears a span" "memset")
    'bulk
    (bulk-verdict 'zero-out! bulk-size
                  (lambda () (zero-out! dst bulk-size))
                  (lambda () (libc-memset! dst 0 bulk-size))))
  (foreign-free dst))

;; The rows above only time. These check a bulk move's CONTENT at a size where
;; a truncated or mis-based move shows (the rows further up use a 3-byte
;; span). Each seeds and reads back foreign memory through libc, never
;; through the other helper, and compares against bytes the helper under test
;; was never handed, so a move in the wrong direction cannot bring its own
;; reference into agreement. The patterns run 1..251 with period 251, a
;; prime, so no byte is 0 and a shift of under 251 bytes mismatches. Each row
;; has its own multiplier and keeps its reference live, because copy-out's
;; result is a fresh bytevector that Chez does not zero: storage recycled
;; from a dead bytevector carrying the same pattern would let a copy-out that
;; stopped short pass (bulk-copy mutation log).
(define big-size (* 1024 1024))

;; patterned-bytes : exact-nonnegative-integer multiplier offset -> bytevector
;; Byte i is pattern byte (i + offset).
(define (patterned-bytes n mult offset)
  (let ((bv (make-bytevector n)))
    (let loop ((i 0))
      (when (< i n)
        (bytevector-u8-set! bv i (+ 1 (mod (* (+ i offset) mult) 251)))
        (loop (+ i 1))))
    bv))

;; first-difference : bytevector bytevector -> 'identical | list
(define (first-difference got want)
  (cond ((not (= (bytevector-length got) (bytevector-length want)))
         (list 'length (bytevector-length got)))
        ((bytevector=? got want) 'identical)
        (else
         (let loop ((i 0))
           (if (= (bytevector-u8-ref got i) (bytevector-u8-ref want i))
               (loop (+ i 1))
               (list 'first-difference-at i))))))

(test-equal "copy-in! writes every byte of a 1 MiB span taken from a non-zero start"
  'identical
  (let ((dst (alloc-zeroed big-size)))
    (copy-in! dst (patterned-bytes (+ big-size 8) 7 0) 3 big-size)
    (let ((r (first-difference (foreign->bytevector dst big-size)
                               (patterned-bytes big-size 7 3))))
      (free! dst)
      r)))

(test-equal "copy-out reads every byte of a 1 MiB span"
  'identical
  (let ((src (foreign-alloc big-size))
        (want (patterned-bytes big-size 11 0)))
    (libc-memcpy-to-foreign! src want big-size)
    (let ((r (first-difference (copy-out src big-size) want)))
      (foreign-free src)
      r)))

(let ((addr (foreign-alloc big-size)))
  (libc-memset! addr #xff big-size)
  (test-equal "the 1 MiB zero-out! probe really was seeded non-zero first"
    'identical
    (first-difference (foreign->bytevector addr big-size)
                      (make-bytevector big-size #xff)))
  (test-equal "zero-out! clears every byte of a 1 MiB span"
    'identical
    (begin
      (zero-out! addr big-size)
      (first-difference (foreign->bytevector addr big-size)
                        (make-bytevector big-size 0))))
  (foreign-free addr))

;; An empty span at the very END of its bytevector is the edge a bulk move
;; reaches with a one-past-the-end source address: it must be accepted, and
;; it must write nothing. The call runs inside the row, so a regression that
;; refuses the span fails the row by name instead of aborting the suite
;; (AGENTS.md). The destination is checked under two seeds, because a byte
;; wrongly copied from past the bytevector's end could equal any one seed.
(define (empty-span-at-end-writes-nothing? seed)
  (let ((dst (foreign-alloc 4)))
    (libc-memset! dst seed 4)
    (let ((r (guard (e ((uv-invalid-argument? e)
                        (list 'refused (uv-invalid-argument-reason e))))
               (copy-in! dst (u8-list->bytevector (list 1 2 3)) 3 0)
               (if (bytevector=? (foreign->bytevector dst 4)
                                 (make-bytevector 4 seed))
                   'nothing-written
                   (list 'wrote-over seed)))))
      (foreign-free dst)
      r)))

(test-equal "copy-in! of an empty span at the end of its bytevector writes nothing"
  '(nothing-written nothing-written)
  (let* ((under-zeros (empty-span-at-end-writes-nothing? #x00))
         (under-ones (empty-span-at-end-writes-nothing? #xff)))
    (list under-zeros under-ones)))

;; The shim's zero-length moves rely on Chez passing an EMPTY bytevector's
;; storage as a real, non-null address: C99 wants valid pointers even for a
;; zero length, and only #f passes NULL. The CSUG does not say what an empty
;; bytevector passes, so this pins it rather than a comment.
(test-equal "an empty bytevector reaches C as a non-null pointer"
  '(non-null non-null non-null)
  (map (lambda (bv) (if (zero? (libc-bytevector-address bv)) 'null 'non-null))
       (list (make-bytevector 0) #vu8() (string->utf8 ""))))

;; copy-in! checks its span against the bytevector, then hands the
;; bytevector to memcpy. If an interrupt handler ran between the two -- an
;; engine's timer expiry is one -- and truncated the bytevector, memcpy would
;; read past its new end, and a uv-write! would send the Chez heap that
;; follows to the peer. The old per-byte loop re-checked every index; now
;; copy-in! makes the final check and the copy one interrupt-free step.
;;
;; The scan runs copy-in! in an engine at rising fuel. On the first expiry it
;; truncates the source to 16 bytes, collects, and fills the heap with #x77,
;; then resumes. Every run must either be refused (the expiry came before the
;; check) or copy only the source's #x11 (the copy came first). The scan stops
;; at the first run that finishes before any expiry, since more fuel changes
;; nothing after that. The scan runs outside any row, so every raise inside
;; the engine becomes an outcome and fails the second row by name instead of
;; aborting the suite (AGENTS.md).
(define (truncation-outcome fuel)
  (let* ((n 4096)
         (bv (make-bytevector n #x11))
         (dst (alloc-zeroed n))
         (spray '()))
    (let-values (((answer expired)
                  (run-capped
                   (lambda ()
                     (guard (e ((uv-invalid-argument? e) 'refused)
                               (#t 'raised-otherwise))
                       (copy-in! dst bv 0 n)
                       'returned))
                   fuel
                   (lambda ()
                     (bytevector-truncate! bv 16)
                     (collect)
                     (set! spray
                       (let fill ((i 0) (acc '()))
                         (if (= i 2000)
                             acc
                             (fill (+ i 1) (cons (make-bytevector 48 #x77) acc)))))))))
      (let ((copied (foreign->bytevector dst n)))
        (free! dst)
        (values
         (cond ((memq answer '(refused raised-otherwise)) answer)
               ((stuck? answer) answer)
               ((not (bytevector=? copied (make-bytevector n #x11))) 'read-past-the-end)
               (expired 'copied-before-the-truncation)
               (else 'finished-before-any-expiry))
         expired)))))

(define truncation-scan
  (map cadr (sweep-fuels truncation-outcome 512 (lambda (outcome) #f))))

(test-equal "the truncation scan spanned the check: some runs refused, the last untouched"
  '(#t #t)
  (list (and (memq 'refused truncation-scan) #t)
        (eq? 'finished-before-any-expiry
             (list-ref truncation-scan (- (length truncation-scan) 1)))))

(test-equal "copy-in! never copies past the end of a bytevector truncated during the call"
  '()
  (filter (lambda (o)
            (not (memq o '(refused copied-before-the-truncation
                           finished-before-any-expiry))))
          truncation-scan))

;; --- uv_buf_t ftype vs the shim's real layout (design spec S4 rule 4) ---
;; uv-buf-ftype-layout MEASURES the declared ftype -- offsets via
;; ftype-&ref address arithmetic, widths via the byte extent a real
;; ftype-set! actually writes -- so neither side of these comparisons is
;; derived from the other. ensure-native-loaded! makes the same comparison
;; and fails the whole library closed; these assertions pin it by name.
(define buf-layout (uv-buf-ftype-layout))
(define layout-sizeof     (list-ref buf-layout 0))
(define layout-base-off   (list-ref buf-layout 1))
(define layout-base-width (list-ref buf-layout 2))
(define layout-len-off    (list-ref buf-layout 3))
(define layout-len-width  (list-ref buf-layout 4))

(test-equal "the uv_buf_t ftype's size matches the shim's sizeof(uv_buf_t)"
  (sizeof-uv-buf-t) layout-sizeof)

(test-equal "the uv_buf_t ftype's base offset matches the shim's offsetof"
  (offsetof-uv-buf-t-base) layout-base-off)

(test-equal "the uv_buf_t ftype's len offset matches the shim's offsetof"
  (offsetof-uv-buf-t-len) layout-len-off)

;; Widths, not just offsets: a `len` field narrowed to 32 bits would keep
;; every offset and the struct size intact while writing only half the value
;; libuv reads -- the buffer-length corruption that spike FINDINGS Q3's
;; ssize_t mutation is the read-side twin of.
(test-equal "the uv_buf_t ftype's base field fills the space before len"
  (offsetof-uv-buf-t-len) (+ layout-base-off layout-base-width))

(test-equal "the uv_buf_t ftype's len field fills the rest of the struct"
  (sizeof-uv-buf-t) (+ layout-len-off layout-len-width))

;; Functional round-trip through the exported accessors, cross-checked
;; against a raw read at the SHIM's offset -- so the accessors are shown to
;; use the offsets the shim reports, not merely to agree with themselves.
(let ((buf (alloc-zeroed (sizeof-uv-buf-t)))
      (payload (alloc-zeroed 8)))
  (uv-buf-set! buf payload 5)
  (test-equal "uv-buf-set!/uv-buf-base round-trip the base pointer"
    payload (uv-buf-base buf))
  (test-equal "uv-buf-set!/uv-buf-len round-trip the length"
    5 (uv-buf-len buf))
  (test-equal "the base pointer is readable at the shim's offsetof(uv_buf_t, base)"
    payload (foreign-ref 'uptr buf (offsetof-uv-buf-t-base)))
  ;; uv-buf-set! checks its arguments like the other setters, before it
  ;; writes: a refused call leaves the buffer as it was.
  (test-equal "uv-buf-set! refuses a null destination and a negative length, naming who and why"
    '((uv-buf-set! null-or-invalid-destination)
      (uv-buf-set! value-out-of-range)
      (left payload 5))
    (map (lambda (call)
           (guard (e ((uv-invalid-argument? e)
                      (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
                     (#t 'wrong-condition))
             (call)
             (list 'left (if (= (uv-buf-base buf) payload) 'payload (uv-buf-base buf))
                   (uv-buf-len buf))))
         (list (lambda () (uv-buf-set! 0 payload 5))
               (lambda () (uv-buf-set! buf payload -1))
               (lambda () 'no-call))))
  (free! payload)
  (free! buf))

;; --- the C `int` out-parameter (uv_tcp_getsockname's namelen) -----------
;; The width comes from the C ABI, so it is asserted as "what a raw `int`
;; read at the same address sees", never against a literal 4: the point of
;; c-int-size is that no caller has to know the platform's int.
(let ((cell (alloc-zeroed (c-int-size))))
  (c-int-set! cell 128)
  (test-equal "c-int-set!/c-int-ref round-trip a value through a C int cell"
    128 (c-int-ref cell))
  (test-equal "the value is readable as a raw C int at the same address"
    128 (foreign-ref 'int cell 0))
  (free! cell))

(test-equal "c-int-size is the width of the platform's C int, not a Scheme guess"
  (foreign-sizeof 'int) (c-int-size))

(test-equal "c-int-set! rejects a null destination, naming who"
  'uv-c-int-set!
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-who e))
            (#t 'wrong-condition))
    (c-int-set! 0 1)
    'no-raise))

(test-equal "c-int-set! rejects an inexact value, naming who and why"
  '(uv-c-int-set! value-not-an-exact-integer)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (let ((cell (alloc-zeroed (c-int-size))))
      (guard (inner (#t (free! cell) (raise inner)))
        (c-int-set! cell 1.5)))
    'no-raise))

(test-equal "c-int-ref rejects a null source, naming who"
  'uv-c-int-ref
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-who e))
            (#t 'wrong-condition))
    (c-int-ref 0)
    'no-raise))

;; --- v0.5's natives: the size_t return and the int out-parameter --------
;; Design spec v0.5 §13.5. STUB-LEVEL round-trips: a raw loop and a raw tcp
;; handle sized from uv_loop_size/uv_handle_size, no dispatcher installed and
;; no live socket, so these exercise the FFI marshalling and nothing else. The
;; wrappers' live-socket behaviour is tests/test-flow.sps's job.
;;
;; This suite deliberately never imports (libuv private handles): doing so
;; instantiates its body and installs the dispatchers, which would break the
;; "before installation" rows further down. Everything here is raw pointers.
;; NO uv_loop_init HERE, and that is the point. An earlier version of this
;; block built a real loop and a real tcp handle, freed its own two blocks,
;; and skipped uv_loop_close on the reasoning that the handle was never
;; closed so a close would answer EBUSY. That reasoning was wrong in a way
;; macOS cannot see: uv_loop_init allocates libuv's own internals
;; (uv_loop_init -> uv__process_init -> uv_signal_init -> uv__io_init_start),
;; and skipping the close leaks them. CI's Linux Valgrind leg caught it at
;; 128 + 448 bytes definitely lost; the macOS ASan leg makes no leak claim
;; and stayed green.
;;
;; A ZEROED, UNINITIALISED handle exercises both marshalling paths without
;; libuv allocating anything at all, which is what "stub-level" should have
;; meant in the first place: write_queue_size is a struct field read, and
;; uv__socket_sockopt dispatches on handle->type, which is 0
;; (UV_UNKNOWN_HANDLE) in a zeroed block and answers UV_ENOTSUP.
(let ((tp (alloc-zeroed (uv-handle-size (uv-tcp-type)))))

  ;; size_t, and deliberately not a signed type: the queue size cannot be
  ;; negative and the call cannot fail. Binding it signed would be the mirror
  ;; of the `nread` scar the read dispatcher records -- there, reading UV_EOF
  ;; through an unsigned binding delivered four gigabytes of data.
  (test-equal "uv_stream_get_write_queue_size marshals as a non-negative exact integer"
    '(exact non-negative)
    (let ((q (uv-stream-get-write-queue-size-native tp)))
      (list (if (and (integer? q) (exact? q)) 'exact 'inexact)
            (if (>= q 0) 'non-negative 'negative))))

  ;; The int OUT-parameter, which is the half that can go wrong silently.
  ;; A zeroed block has handle->type = 0, so libuv refuses with UV_ENOTSUP --
  ;; a real negative errno rather than garbage, which is what makes this a
  ;; marshalling assertion. And the cell is still the
  ;; zero alloc-zeroed put there: on the failure path libuv never writes back,
  ;; so a getter built on foreign-alloc instead would be carrying whatever the
  ;; heap held, unnoticed.
  (let ((cell (alloc-zeroed (c-int-size))))
    ;; THE SIGN IS THE ASSERTION, and the symbol alone cannot carry it:
    ;; errno->symbol answers EBADF for -9 AND for its unsigned 32-bit wrap
    ;; 4294967287 (measured -- it normalises the wraparound). A row asserting
    ;; only the symbol is therefore blind to the exact defect it looks like it
    ;; is testing, an `int` rc bound as `unsigned-int`. The wrappers survive
    ;; that mutation only because uv-check gates on negativity before mapping;
    ;; at this level the row has to gate on it itself. This row was written
    ;; the blind way first and caught by running the mutation.
    (test-equal "uv_send_buffer_size on an unknown handle type answers a NEGATIVE ENOTSUP rc"
      '(negative ENOTSUP)
      (let ((rc (uv-send-buffer-size-native tp cell)))
        (list (if (negative? rc) 'negative 'not-negative)
              (errno->symbol rc))))
    (test-equal "the int out-parameter still holds alloc-zeroed's zero after a failed call"
      0 (c-int-ref cell))
    (free! cell))

  (free! tp))

;; --- c-uptr-ref: the pointer-wide sibling (design spec v0.2 S5.1) -------
;; The probe value deliberately does NOT fit in 32 bits: on every supported
;; target a c-uptr-ref accidentally narrowed to a 32-bit read would answer a
;; truncated number that is still a plausible pointer, so a value whose high
;; bits are load-bearing is what makes the width assertion discriminating.
(let ((cell (alloc-zeroed (foreign-sizeof 'uptr))))
  (foreign-set! 'uptr cell 0 #x123456789A)
  (test-equal "c-uptr-ref reads the full pointer width a raw uptr write stored"
    #x123456789A (c-uptr-ref cell))
  (free! cell))

(test-equal "c-uptr-ref rejects a null source, naming who"
  'uv-c-uptr-ref
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-who e))
            (#t 'wrong-condition))
    (c-uptr-ref 0)
    'no-raise))

;; --- read-net-u16: ntohs, by hand (spike FINDINGS Q3) -------------------
;; `sin_port` is stored big-endian whatever the host's order is, so this is
;; the one decision in the getsockname path that a host-order read would get
;; PLAUSIBLY wrong -- a different number, still in port range. The bytes are
;; asymmetric on purpose: #xB4 #x39 decodes to 46137 big-endian and 14772
;; host-endian, so the two answers cannot be confused. tests/test-tcp.sps
;; makes the same check end to end against a real bound port; this one makes
;; it without a socket, on bytes this suite chose.
;; The bytes are written one at a time with foreign-set!, not with copy-in!,
;; so a broken copy-in! fails its own rows rather than aborting these.
(let ((cell (alloc-zeroed 4)))
  (foreign-set! 'unsigned-8 cell 0 #xb4)
  (foreign-set! 'unsigned-8 cell 1 #x39)
  (foreign-set! 'unsigned-8 cell 2 #x00)
  (foreign-set! 'unsigned-8 cell 3 #x50)
  (test-equal "read-net-u16 decodes two bytes in NETWORK order, not host order"
    #xb439 (read-net-u16 cell 0))
  (test-equal "read-net-u16 reads at the offset it is given"
    80 (read-net-u16 cell 2))
  (free! cell))

(test-equal "read-net-u16 rejects a null source, naming who"
  'uv-read-net-u16
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-who e))
            (#t 'wrong-condition))
    (read-net-u16 0 0)
    'no-raise))

(test-equal "read-net-u16 rejects a negative offset, naming who and why"
  '(uv-read-net-u16 offset-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (let ((cell (alloc-zeroed 4)))
      (guard (inner (#t (free! cell) (raise inner)))
        (read-net-u16 cell -1)))
    'no-raise))

;; --- sockaddr->address-string (design spec v0.2 S5.1) -------------------
;; Both refusal rows expect a SENTINEL reached through `or`, never a bare
;; #f: SRFI-64 turns any raise in the actual expression into #f (AGENTS.md's
;; named trap), so a row expecting #f would pass identically against a
;; wrapper that raises.
;;
;; The zero-pointer refusal must not reach native at all: uv_ip_name
;; dereferences sa_family unconditionally (vendor/libuv/src/uv-common.c:311),
;; so the arm under test here is the one that keeps synthetic addrinfo
;; chains with NULL ai_addr safe and makes the v0.2 offset-swap mutation
;; fail by name instead of by SIGSEGV.
(test-equal "sockaddr->address-string refuses a zero pointer with #f, without calling native"
  'refused-null
  (or (sockaddr->address-string 0) 'refused-null))

;; Round trip, hermetic (no resolver): uv_ip4_addr parses the text into a
;; real sockaddr_in, uv_ip_name renders it back. Expecting the dotted quad
;; itself means only the genuine parse-then-render path can pass. The parse
;; runs inside the row, so a fill-sockaddr! that refuses good bytes fails
;; this row by name instead of aborting the suite.
(let ((addr (alloc-zeroed (sizeof-sockaddr-storage))))
  (test-equal "sockaddr->address-string renders back the dotted quad uv_ip4_addr parsed"
    "127.0.0.1"
    (guard (e ((uv-invalid-argument? e)
               (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
              (#t (list 'wrong-condition (describe e))))
      (fill-sockaddr! addr (string->utf8 "127.0.0.1\x0;") 8080 'test-sockaddr-round-trip)
      (sockaddr->address-string addr)))
  (free! addr))

;; The nonzero-rc arm: a zeroed sockaddr_storage carries sa_family 0
;; (AF_UNSPEC), which uv_ip_name's switch refuses with UV_EAFNOSUPPORT
;; (vendor/libuv/src/uv-common.c:305-321) -- deterministic, no network, no
;; resolver configuration consulted.
(let ((addr (alloc-zeroed (sizeof-sockaddr-storage))))
  (test-equal "sockaddr->address-string answers #f for a family uv_ip_name refuses"
    'refused-family
    (or (sockaddr->address-string addr) 'refused-family))
  (free! addr))

;; --- validate-address / require-port (post-v0.2 lift) -------------------
;; The ADR-0012 input vocabulary's validators, asserted at their shared
;; home: tcp.sls and dns.sls both import THIS copy, so these rows pin the
;; semantics every verb boundary observes. `who` is a symbol no real
;; caller passes: each raise must name the caller handed in, not the
;; helper or a baked-in verb name.
(test-equal "validate-address refuses a non-string, naming its caller and why"
  '(test-lift address-not-a-string)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (validate-address 42 'test-lift)
    'no-raise))

;; C reads an address only up to its first NUL, so "127.0.0.1\x0;x" would
;; parse as 127.0.0.1 (tests/test-address.sps has the verbs' rows).
(test-equal "validate-address refuses a string holding a NUL, naming its caller and why"
  '((test-lift address-contains-nul) (test-lift address-contains-nul))
  (map (lambda (ip)
         (guard (e ((uv-invalid-argument? e)
                    (list (uv-invalid-argument-who e)
                          (uv-invalid-argument-reason e)))
                   (#t 'wrong-condition))
           (validate-address ip 'test-lift)
           'no-raise))
       '("127.0.0.1\x0;x" "\x0;")))

;; Address-ness here is C-string-ness, a string holding no NUL, BY DESIGN:
;; parse refusal is fill-sockaddr!'s job (spike FINDINGS Q3), so a validator
;; tightened to pre-parse would fail this row by name. What it answers is
;; the string's C string, the bytes libuv parses: UTF-8 and one terminating
;; NUL.
(test-equal "validate-address answers a string it cannot parse as that string's C string (parsing is fill-sockaddr!'s job)"
  (list (string->utf8 "not-an-ip\x0;") (u8-list->bytevector '(120 206 187 0)))
  (list (validate-address "not-an-ip" 'test-lift)
        (validate-address "x\x3bb;" 'test-lift)))

;; --- fill-sockaddr!'s address ---------------------------------------------
;; libuv reads it as a C string, so fill-sockaddr! takes the bytes and
;; refuses any that are not one C string: one NUL, the last byte. A NUL
;; inside is the case a missing check would let through: libuv would parse
;; "127.0.0.1" and the row would carry that parse instead of the refusal.
(define (fill-sockaddr-answer ip)
  (let ((addr (alloc-zeroed (sizeof-sockaddr-storage))))
    (let ((answer
           (guard (e ((uv-invalid-argument? e)
                      (list (uv-invalid-argument-who e)
                            (uv-invalid-argument-reason e)))
                     (#t (list 'wrong-condition (describe e))))
             (fill-sockaddr! addr ip 8080 'test-fill)
             (list 'parsed (sockaddr->address-string addr)))))
      (free! addr)
      answer)))

(test-equal "fill-sockaddr! refuses an address that is not one C string, before calling libuv"
  '((uv-fill-sockaddr! not-a-c-string)    ; a NUL inside, then the terminator
    (uv-fill-sockaddr! not-a-c-string)    ; no terminator
    (uv-fill-sockaddr! not-a-c-string)    ; empty: no terminator either
    (uv-fill-sockaddr! not-a-c-string))   ; a string, not its bytes
  (map fill-sockaddr-answer
       (list (string->utf8 "127.0.0.1\x0;9\x0;")
             (string->utf8 "127.0.0.1")
             (u8-list->bytevector '())
             "127.0.0.1")))

;; The other side: C strings reach libuv, IPv4 and IPv6 alike, and a parse
;; refusal names the caller handed in.
(test-equal "fill-sockaddr! passes C strings through to libuv"
  '((parsed "127.0.0.1") (parsed "::1") (test-fill bad-address))
  (map fill-sockaddr-answer
       (list (string->utf8 "127.0.0.1\x0;")
             (string->utf8 "::1\x0;")
             (string->utf8 "not-an-ip\x0;"))))

;; --- fold-flags: a caller's flag list, read once ---------------------------
;; uv-tcp-bind! and uv-getnameinfo! fold their flag lists through fold-flags,
;; which measures the list without raising and then walks at most that many
;; pairs, each checked as it is read. A list that is improper or circular,
;; or is made one during the call, is refused under the caller's own name and
;; reason, never walked forever (tests/test-address.sps sweeps the change).
;; Each call here runs in an engine whose resumes are capped, so a walk that
;; loops answers the driver's give-up instead of hanging the suite
;; (tests/uv-sweep.sls).
(define (fold-flags-answer flags)
  (capped
   (lambda ()
     (guard (e ((uv-invalid-argument? e)
                (list (uv-invalid-argument-who e)
                      (uv-invalid-argument-reason e)))
               (#t (list 'wrong-condition (describe e))))
       (fold-flags flags 'test-flags 'flags-not-a-list
                   (lambda (flag)
                     (case flag ((a) 1) ((b) 2) ((c) 4) (else 64))))))))

;; A list whose last pair points back at its pair number K (0-based).
(define (circular items k)
  (let ((l (list-copy-of items)))
    (let last ((p l))
      (if (pair? (cdr p)) (last (cdr p)) (set-cdr! p (list-tail l k))))
    l))

(define (list-copy-of l) (map (lambda (x) x) l))

(define (iota* n) (let up ((i 0)) (if (= i n) '() (cons i (up (+ i 1))))))

(test-equal "fold-flags folds a proper list's flags, odd and even lengths alike"
  '(0 1 3 7 4)
  (map fold-flags-answer '(() (a) (a b) (a b c) (c c c c c))))

(test-equal "fold-flags refuses an improper or circular list under its caller's name, never walking it forever"
  (map (lambda (x) '(test-flags flags-not-a-list)) (iota* 8))
  (map fold-flags-answer
       (list 'a
             '(a . b)
             '(a b . c)
             (circular '(a) 0)
             (circular '(a b) 0)
             (circular '(a b c) 0)
             (circular '(a b c d) 2)
             (circular '(a b c d e) 1))))

;; --- proper-length: a list changed during the count (#64) ------------------
;; proper-length counts with a hare and a tortoise, and the tortoise walks
;; pairs the hare has passed, which a change made during the count (by an
;; engine's handler or another thread) can have cut behind the hare. It took
;; the cdr of whatever it found there: `cdr: ... is not a pair` for a list of
;; twelve cut during the count, and at optimize-level 3 an unchecked read.
;; Each sweep counts a fresh twelve-element list in an engine at rising
;; fuel and changes it at the first expiry: the third pair's cdr becomes a
;; vector, or the list's head. A run must answer #f or 12, the count the
;; list began with, without raising; a count it answers can be stale, which
;; is why uv-write*! walks to the end it counted. Each sweep stops at the
;; first run no expiry reached, or a run whose resumes ran out.
(define (length-sweep change!) (list-sweep proper-length change!))

;; list-sweep : (list -> answer) (list -> any) -> (list-of (fuel answer expired?))
;; OP on a fresh twelve-element list in an engine at rising fuel, with
;; CHANGE! made to the list at the first expiry.
(define (list-sweep op change!)
  (sweep-fuels
   (lambda (fuel)
     (let ((l (iota* 12)))
       (run-capped (lambda ()
                     (guard (e (#t (list 'raised (describe e))))
                       (op l)))
                   fuel
                   (lambda () (change! l)))))
   400
   (lambda (answer) #f)))

;; Two cycles at once: the fifth pair's cdr back to the fourth, and the
;; twelfth's back to the eleventh. A count that walked a second pointer
;; behind the first could be left on one cycle while the first went round
;; the other, and never end (#64's review).
(define (two-cycles! l)
  (let ((p4 (list-tail l 4)) (p5 (list-tail l 5))
        (p10 (list-tail l 10)) (p11 (list-tail l 11)))
    (set-cdr! p5 p4)
    (set-cdr! p11 p10)))

(define length-sweeps
  (list (cons 'cut (length-sweep
                    (lambda (l) (set-cdr! (cddr l) (vector 'not 'a 'pair)))))
        (cons 'made-circular (length-sweep
                              (lambda (l) (set-cdr! (cddr l) l))))
        (cons 'two-cycles (length-sweep two-cycles!))))

(test-equal "proper-length answers #f or the count it began with for a list changed during the count, never raising"
  '()
  (apply append
         (map (lambda (s)
                (map (lambda (run) (cons (car s) run))
                     (filter (lambda (run) (not (memv (cadr run) '(#f 12))))
                             (cdr s))))
              length-sweeps)))

;; The row above finds no bad answer, which says nothing unless each sweep
;; changed the list before the count began and ran the last count whole.
(test-equal "each proper-length sweep changed the list before the count began and ended with a count no expiry reached"
  '((cut (1 #f #t) 12) (made-circular (1 #f #t) 12) (two-cycles (1 #f #t) 12))
  (map (lambda (s)
         (let ((runs (cdr s)))
           (list (car s)
                 (car runs)
                 (let ((last-run (list-ref runs (- (length runs) 1))))
                   (if (caddr last-run) 'expired (cadr last-run))))))
       length-sweeps))

;; --- read-proper-list: a caller's list, read once (#66) -------------------
;; read-proper-list counts with proper-length, walks at most that many
;; pairs, checking each, and requires the list's end after them. Its READ
;; sees each element once, in order, and its answer is a fresh list or #f.

;; read-trace : object -> (list answer elements-read)
;; What read-proper-list answered for X, 'refused for #f, with the elements
;; its READ saw, in the order it saw them. It reads in an engine whose
;; resumes are capped, so a read that never ends answers the driver's
;; give-up and fails its row instead of hanging the suite.
(define (read-trace x)
  (let* ((seen '())
         (answer
          (capped
           (lambda ()
             (guard (e (#t (list 'raised (describe e))))
               (or (read-proper-list
                    x (lambda (element)
                        (set! seen (cons element seen))
                        (list 'read element)))
                   'refused))))))
    (list answer (reverse seen))))

(define (read-all l) (read-proper-list l (lambda (e) e)))

(test-equal "read-proper-list reads each element once, in order, into a fresh list"
  '((((read a) (read b) (read c)) (a b c)) equal unshared)
  (let* ((l (list 'a 'b 'c))
         (copy (read-all l)))
    (list (read-trace l)
          (if (equal? copy l) 'equal (list 'copy-was copy))
          (if (and (pair? copy)
                   (exists (lambda (p) (memq p (list l (cdr l) (cddr l))))
                           (list copy (cdr copy) (cddr copy))))
              'shared
              'unshared))))

(test-equal "read-proper-list reads () as (), and refuses a non-list, an improper list or a circular one, reading none of it"
  '((() ()) (refused ()) (refused ()) (refused ()) (refused ()))
  (map read-trace
       (list '()
             42
             (cons 'a 'b)
             (cons 'a (cons 'b 'c))
             (let ((l (list 'a 'b 'c)))
               (set-cdr! (cddr l) l)
               l))))

;; The read sweeps change the list at the first expiry, as the count's do,
;; and add a splice: the third pair's cdr becomes a longer list. A read the
;; splice reaches has a stale count, and stops short of the list's end; a
;; read that did not require the end would answer the twelve elements it
;; walked, a list the caller never had. A run must answer the list as it
;; was, the list as the change left it, or #f.
(define splice-tail (map (lambda (i) (+ 100 i)) (iota* 20)))

;; (name change! the-list-as-changed-or-#f)
(define read-variants
  (list (list 'cut (lambda (l) (set-cdr! (cddr l) (vector 'not 'a 'pair))) #f)
        (list 'made-circular (lambda (l) (set-cdr! (cddr l) l)) #f)
        (list 'two-cycles two-cycles! #f)
        (list 'spliced-longer (lambda (l) (set-cdr! (cddr l) splice-tail))
              (append '(0 1 2) splice-tail))))

(define read-sweeps
  (map (lambda (v) (cons (car v) (list-sweep read-all (cadr v)))) read-variants))

(test-equal "read-proper-list answers a list changed during the read as it was, as the change left it, or #f, never raising"
  '()
  (apply append
         (map (lambda (v s)
                (map (lambda (run) (cons (car s) run))
                     (filter (lambda (run)
                               (let ((answer (cadr run)))
                                 (not (or (not answer)
                                          (equal? answer (iota* 12))
                                          (and (caddr v) (equal? answer (caddr v)))))))
                             (cdr s))))
              read-variants read-sweeps)))

;; The row above finds no bad answer, which says nothing unless each sweep
;; changed the list before the read began and ran the last read whole.
(test-equal "each read-proper-list sweep changed the list before the read began and ended with a read no expiry reached"
  (map (lambda (v) (list (car v) (list 1 (caddr v) #t) (iota* 12))) read-variants)
  (map (lambda (s)
         (let ((runs (cdr s)))
           (list (car s)
                 (car runs)
                 (let ((last-run (list-ref runs (- (length runs) 1))))
                   (if (caddr last-run) 'expired (cadr last-run))))))
       read-sweeps))

;; --- let-fixed-list: a caller's list of a fixed length, read once (#81) ----
;; uv-spawn!'s pipe specs and uv-write*!'s (bv start end) spans are lists of
;; a fixed length. let-fixed-list binds their elements walking the list once,
;; each pair checked before it is read through, and requires the end after
;; the last. Each pipe spec's tail used to be checked and then read again, a
;; read Chez's own cadr raised on, or at --optimize-level 3 read through, when
;; another thread cut it in between (#66). The race row below holds the
;; once-only read; these hold the shape.
(define (fixed-3 x)
  (let-fixed-list (a b c) x 'mismatch (list a b c)))

;; The race list's twelve elements, or #f, which the race counts as a cut.
(define (fixed-12 x)
  (let-fixed-list (e0 e1 e2 e3 e4 e5 e6 e7 e8 e9 e10 e11) x #f
    (list e0 e1 e2 e3 e4 e5 e6 e7 e8 e9 e10 e11)))

(test-equal "let-fixed-list binds each element of a list exactly as long as its names"
  '((1) (1 2) (1 2 3))
  (list (let-fixed-list (a) (list 1) 'mismatch (list a))
        (let-fixed-list (a b) (list 1 2) 'mismatch (list a b))
        (fixed-3 (list 1 2 3))))

(test-equal "let-fixed-list answers its mismatch for any other shape, wherever it goes wrong"
  (map (lambda (i) 'mismatch) (iota* 11))
  (map fixed-3
       (list 'x
             (vector 1 2 3)
             '()
             (list 1)
             (list 1 2)
             (list 1 2 3 4)
             (cons 1 2)
             (cons 1 (cons 2 3))
             (cons 1 (cons 2 (cons 3 4)))
             (circular '(1 2 3) 0)
             (circular '(1) 0))))

(test-equal "let-fixed-list evaluates its mismatch only on a mismatch, once"
  '(1 0 mismatch 1)
  (let* ((evaluated 0)
         (read (lambda (x)
                 (let-fixed-list (a) x
                   (begin (set! evaluated (+ evaluated 1)) 'mismatch)
                   a)))
         (matched (read (list 1)))
         (after-match evaluated)
         (mismatched (read (list 1 2))))
    (list matched after-match mismatched evaluated)))

;; --- fold-flags: a flag list spliced longer during the walk ---------------
;; fold-flags walks no further than its count and requires the list's end
;; after it, as read-proper-list does. Without the end, a tail spliced in
;; during the walk was folded as far as the stale count, into flags the
;; caller never held. A walk the splice contradicts counts and walks the
;; list once more, as read-proper-list does, so a list that was proper
;; before the splice and after it is never refused (#81). The sweep splices
;; splice-tail in at the first expiry, as the read sweeps do, and folds 2^e
;; for each element e, so that each list's flags are its own: every run must
;; answer the flags of the list as it was or as the splice left it.
(define (flag-bit e) (expt 2 e))

(define (bits-of l)
  (fold-left (lambda (bits e) (bitwise-ior bits (flag-bit e))) 0 l))

(define (fold-all l)
  (guard (e ((uv-invalid-argument? e) (list 'refused (uv-invalid-argument-reason e))))
    (fold-flags l 'test-flags 'flags-not-a-list flag-bit)))

(define fold-splice-sweep
  (list-sweep fold-all (lambda (l) (set-cdr! (cddr l) splice-tail))))

(define spliced-bits (bits-of (append '(0 1 2) splice-tail)))

(test-equal "fold-flags folds a flag list spliced longer during the walk as it was or as the splice left it, never refusing it"
  '()
  (filter (lambda (run)
            (not (member (cadr run) (list (bits-of (iota* 12)) spliced-bits))))
          fold-splice-sweep))

;; The row above finds no bad answer, which says nothing unless the sweep
;; spliced the list before the walk began and ran the last walk whole.
(test-equal "the fold-flags splice sweep spliced the list before the walk began and ended with a walk no expiry reached"
  (list (list 1 spliced-bits #t) (bits-of (iota* 12)))
  (list (car fold-splice-sweep)
        (let ((last-run (list-ref fold-splice-sweep (- (length fold-splice-sweep) 1))))
          (if (caddr last-run) 'expired (cadr last-run)))))

;; --- proper-length against changes nobody chose ---------------------------
;; The sweeps above make the changes a reader thought of; one reader thought
;; only of single changes, and the count above hung on two. These trials
;; make changes at random: a list of 1 to 16 pairs, counted in an engine
;; whose fuel runs out somewhere in the count (a count of N pairs takes
;; N + 1 ticks), and one or two changes at each of its first one or two
;; expiries. A change points a random pair's cdr at a random pair of the
;; list, at '() or at a vector. The count may then answer #f or any length,
;; since the list may now have it, but it must end and raise nothing. The
;; seed is fixed, so every run makes the same trials.
(define count-trials 3000)

;; count-trial : -> (list changed? answer)
(define (count-trial)
  (let* ((len (+ 1 (random 16)))
         (l (iota* len))
         (pairs (let collect ((p l) (acc '()))
                  (if (pair? p) (collect (cdr p) (cons p acc)) (reverse acc))))
         (fuel (+ 1 (random (+ len 1))))
         (expiries (+ 1 (random 2)))
         (changes 0))
    (define (change!)
      (set! changes (+ changes 1))
      (let ((p (list-ref pairs (random len))))
        (case (random 3)
          ((0) (set-cdr! p (list-ref pairs (random len))))
          ((1) (set-cdr! p '()))
          (else (set-cdr! p (vector 'not 'a 'pair))))))
    (let-values (((answer expired)
                  (run-capped* (lambda ()
                                 (guard (e (#t (list 'raised (describe e))))
                                   (proper-length l)))
                               fuel
                               (lambda ()
                                 (change!)
                                 (when (zero? (random 2)) (change!)))
                               expiries)))
      ;; Changed only if a change was made: an expiry alone is no change.
      (list (and expired (positive? changes)) answer))))

(random-seed 64)
(define trial-results
  (let run ((i 0) (acc '()))
    (if (= i count-trials) (reverse acc) (run (+ i 1) (cons (count-trial) acc)))))

(test-equal "proper-length ends and raises nothing for a list changed at random during the count"
  '()
  (let collect ((results trial-results) (i 0) (bad '()))
    (if (null? results)
        (reverse bad)
        (let ((answer (cadr (car results))))
          (collect (cdr results) (+ i 1)
                   (if (or (not answer)
                           (and (integer? answer) (exact? answer) (>= answer 0)))
                       bad
                       (cons (list i answer) bad)))))))

;; The row above says nothing unless the changes landed mid-count.
(define trials-changed (length (filter car trial-results)))
(display "  [informational] proper-length trials: ")
(display trials-changed)
(display " of ")
(display count-trials)
(display " changed their list during the count")
(newline)

(test-equal "precondition: at least a third of the trials changed their list during the count"
  'changed-mid-count
  (if (>= (* 3 trials-changed) count-trials)
      'changed-mid-count
      (list 'changed trials-changed)))

;; --- proper-length and read-proper-list against another thread ----------
;; Another thread can change a list between any two instructions, where an
;; engine stops only at a trap check. A flipper turns the third pair's cdr
;; between a cut and the rest of the list while this thread counts or reads
;; the list. Cut to a vector, every count must answer #f or 12, and every
;; read #f or the list, without raising. A count or read that took a cdr
;; twice, checking it the first time, would read through the vector the
;; second: the shape #61's count had, which no engine sweep can split. Cut
;; to the list's head, which makes it circular, a read can go around the
;; cycle, below. As in test-addrinfo's cross-thread row, the rows assert
;; only what no schedule can make fail on a right answer, and the
;; informational lines count the counts and reads the flipper's change
;; reached.
;;
;; A flipper that never ran, or stopped, would leave those rows passing. So
;; before the first count or read and after the last, each race waits to
;; see the flipper cut the list and make it whole again (tests/uv-race.sls),
;; and a precondition row holds both. The first wait also holds the race
;; until the flipper is flipping. The race finds the pair it watches
;; through l, the list each call is given, so a flipper changing any other
;; list fails that row too, and so does one that never makes the list
;; whole, which no count could tell from a cut. Not under Valgrind, which
;; runs one thread at a time.
(define list-race-rounds 100000)

;; list-race : (list -> answer) (list -> object) (answer -> (or symbol #f))
;;             -> (list rounds bad first-bad cut turned before after)
;; OP's answers for a twelve-element list another thread changes, its third
;; pair's cdr turned between (CUT-OF l) and the rest of the list. CLASSIFY
;; names each answer 'whole, 'cut or 'turned (once around a cycle), or #f
;; for one no right read gives, which is counted as bad. It stops the
;; flipper and joins it before it answers.
(define (list-race op cut-of classify)
  (let* ((l (iota* 12))
         (p (list-tail l 2))
         (rest (cdr p))
         (cut (cut-of l))
         (stop #f)
         (flipper
          (fork-thread
           (lambda ()
             (let flip ()
               (unless stop
                 (set-cdr! p cut)
                 (set-cdr! p rest)
                 (flip))))))
         (before (watch-flipper (list-tail l 2) cut rest)))
    (let ((result
           (let round ((r 0) (bad 0) (first-bad #f) (cuts 0) (turned 0))
             (if (= r list-race-rounds)
                 (list r bad first-bad cuts turned)
                 (let ((answer (guard (e (#t (list 'raised (describe e))))
                                 (op l))))
                   (case (classify answer)
                     ((whole) (round (+ r 1) bad first-bad cuts turned))
                     ((cut) (round (+ r 1) bad first-bad (+ cuts 1) turned))
                     ((turned) (round (+ r 1) bad first-bad cuts (+ turned 1)))
                     (else (round (+ r 1) (+ bad 1)
                                  (or first-bad (list r answer))
                                  cuts turned))))))))
      (let ((after (watch-flipper (list-tail l 2) cut rest)))
        (set! stop #t)
        (thread-join flipper)
        (append result (list before after))))))

(define (vector-cut l) (vector 'not 'a 'pair))
(define (head-cut l) l)

;; whole-or-cut : object -> (answer -> (or 'whole 'cut #f))
(define (whole-or-cut whole)
  (lambda (answer)
    (cond ((equal? answer whole) 'whole)
          ((not answer) 'cut)
          (else #f))))

;; A flipper that turns the third pair's cdr between the list's head and
;; the rest of the list makes the list circular and whole again. A read the
;; list changes in once answers the list or #f, as in the cut race. One it
;; changes in during the count and again during the walk can count a walk
;; once around the cycle and then take it: (0 1 2 0 1 2 3 ... 11), the
;; list's elements in an order the list never held (lists.sls). No read
;; that takes no lock can rule that out, so the row holds what a read can:
;; each answers #f, or a walk of the list to its end, around the cycle as
;; many times as the walk found it there, and none raises or stops short of
;; the end. A read that did not require the end would answer the count's
;; worth of such a walk. The informational line counts the answers that
;; went around the cycle.

;; cycle-turns : object list -> (or exact-nonnegative-integer #f)
;; How many times ANSWER went around the race list's cycle of three before
;; it ended as WHOLE does, or #f when it is no such walk.
(define (cycle-turns answer whole)
  (let strip ((a answer) (turns 0))
    (cond ((equal? a whole) turns)
          ((and (pair? a) (pair? (cdr a)) (pair? (cddr a))
                (equal? (list (car a) (cadr a) (caddr a)) '(0 1 2)))
           (strip (cdddr a) (+ turns 1)))
          (else #f))))

;; whole-cut-or-turned : answer -> (or 'whole 'cut 'turned #f)
(define (whole-cut-or-turned answer)
  (let ((turns (and answer (cycle-turns answer (iota* 12)))))
    (cond ((not answer) 'cut)
          ((eqv? turns 0) 'whole)
          (turns 'turned)
          (else #f))))

;; --- read-proper-list: a list another thread changes exactly once -------
;; Another thread turns the second pair's cdr between two proper tails, so
;; that the list is a proper list at every instant and only its length
;; changes, once a round, at a moment of its own while this thread reads
;; the list; the round waits for that change before the next read, so no
;; read sees two. A walk the change reaches contradicts its count, and
;; read-proper-list then counts and walks the list once more, so every read
;; must answer the list before the change or after it, never #f. With one
;; count and one walk, a change between the two answered #f for a list that
;; was proper before and after it, and uv-spawn! refused it as no list
;; (#73's review: 20,246 of 100,000 spawns). A precondition row holds that
;; the reads saw both lengths, so the other thread was changing the list.
;; Not under Valgrind.
(define one-change-rounds 20000)
(define one-change-span 400)
(define one-change-wait-cap 100000000)

;; one-change-race : -> (list rounds bad first-bad short-reads long-reads)
;; It stops the other thread and joins it on every exit, a raise included.
(define (one-change-race)
  (let* ((short-tail (list 'c 'd))
         (long-tail (iota* 20))
         (l (cons 'a (cons 'b short-tail)))
         (p (cdr l))
         (short (cons 'a (cons 'b (list 'c 'd))))
         (long (cons 'a (cons 'b (iota* 20))))
         (go 0)
         (done 0)
         (stop #f)
         (changer
          (fork-thread
           (lambda ()
             (let watch ((seen 0))
               (cond (stop 'stopped)
                     ((> go seen)
                      (let ((this go))
                        (let spin ((k (random one-change-span)))
                          (unless (zero? k) (spin (- k 1))))
                        (set-cdr! p (if (eq? (cdr p) short-tail) long-tail short-tail))
                        (set! done this)
                        (watch this)))
                     (else (watch seen))))))))
    (dynamic-wind
     (lambda () #f)
     (lambda ()
       (let round ((r 1) (bad 0) (first-bad #f) (shorts 0) (longs 0))
         (if (> r one-change-rounds)
             (list one-change-rounds bad first-bad shorts longs)
             (begin
               (set! go r)
               (let ((answer (guard (e (#t (list 'raised (describe e))))
                               (read-all l))))
                 (let wait ((k 0))
                   (cond ((= done r) 'changed)
                         ((= k one-change-wait-cap)
                          (raise (list 'the-other-thread-never-changed-the-list 'round r)))
                         (else (wait (+ k 1)))))
                 (cond ((equal? answer short)
                        (round (+ r 1) bad first-bad (+ shorts 1) longs))
                       ((equal? answer long)
                        (round (+ r 1) bad first-bad shorts (+ longs 1)))
                       (else
                        (round (+ r 1) (+ bad 1) (or first-bad (list r answer))
                               shorts longs))))))))
     (lambda ()
       (set! stop #t)
       (thread-join changer)))))

(if (getenv "CHEZ_LIBUV_UNDER_VALGRIND")
    (begin
      (display "  [informational] proper-length and read-proper-list races:")
      (display " skipped under Valgrind, which runs one thread at a time")
      (newline))
    (begin
      (let ((race (list-race proper-length vector-cut (whole-or-cut 12))))
        (display "  [informational] proper-length race: ")
        (display (cadddr race))
        (display " of ")
        (display (car race))
        (display " counts found the list cut")
        (newline)
        (test-equal "proper-length answers #f or 12 for a list another thread changes, never raising"
          (list list-race-rounds 0 #f)
          (list (car race) (cadr race) (caddr race)))
        ;; The row above says nothing unless the flipper was changing the list.
        (test-equal "precondition: the race's flipper was changing the counted list before the first count and after the last"
          '(flipping flipping)
          (list-tail race 5)))
      (let ((race (list-race fixed-12 vector-cut (whole-or-cut (iota* 12)))))
        (display "  [informational] let-fixed-list race: ")
        (display (cadddr race))
        (display " of ")
        (display (car race))
        (display " reads found the list cut")
        (newline)
        ;; A read that always answered its mismatch would pass as cut every
        ;; round, so the row requires some reads to answer the list.
        (test-equal "let-fixed-list answers the list or its mismatch for a list another thread changes, never raising"
          (list list-race-rounds 0 #f 'some-whole)
          (list (car race) (cadr race) (caddr race)
                (if (< (cadddr race) (car race)) 'some-whole 'never-whole)))
        (test-equal "precondition: the let-fixed-list race's flipper was changing the read list before the first read and after the last"
          '(flipping flipping)
          (list-tail race 5)))
      (let ((race (list-race read-all vector-cut (whole-or-cut (iota* 12)))))
        (display "  [informational] read-proper-list race: ")
        (display (cadddr race))
        (display " of ")
        (display (car race))
        (display " reads found the list cut")
        (newline)
        (test-equal "read-proper-list answers #f or the list for a list another thread changes, never raising"
          (list list-race-rounds 0 #f)
          (list (car race) (cadr race) (caddr race)))
        (test-equal "precondition: the read race's flipper was changing the read list before the first read and after the last"
          '(flipping flipping)
          (list-tail race 5)))
      (let ((race (list-race read-all head-cut whole-cut-or-turned)))
        (display "  [informational] read-proper-list cycle race: ")
        (display (cadddr race))
        (display " of ")
        (display (car race))
        (display " reads found the list circular, and ")
        (display (list-ref race 4))
        (display " answered a walk around its cycle")
        (newline)
        (test-equal "read-proper-list answers #f or a walk of the list to its end for a list another thread makes circular, never raising"
          (list list-race-rounds 0 #f)
          (list (car race) (cadr race) (caddr race)))
        (test-equal "precondition: the cycle race's flipper was making the read list circular and whole again before the first read and after the last"
          '(flipping flipping)
          (list-tail race 5)))
      (let ((race (guard (e (#t (list 0 1 (list 'raised (describe e)) 0 0)))
                    (one-change-race))))
        (display "  [informational] read-proper-list one-change race: ")
        (display (list-ref race 3))
        (display " reads answered the shorter list and ")
        (display (list-ref race 4))
        (display " the longer")
        (newline)
        (test-equal "read-proper-list answers a list another thread changes once during the read as it was before the change or after it, never #f"
          (list one-change-rounds 0 #f)
          (list (car race) (cadr race) (caddr race)))
        (test-equal "precondition: the one-change race's reads answered both the shorter list and the longer"
          'both
          (if (and (positive? (list-ref race 3)) (positive? (list-ref race 4)))
              'both
              (list 'shorter (list-ref race 3) 'longer (list-ref race 4)))))))


;; The flags were measured with a guarded length, and a guard costs a few
;; hundred bytes a call even when nothing raises; the walk that replaced it
;; allocates nothing. tests/uv-meter.sls has the meter; the row's second
;; element shows it sees an allocation.
(test-equal "fold-flags allocates nothing, where the meter sees a 64-byte allocation"
  '(0 meter-live)
  (let ((flags (list 'a 'b 'c))
        (bit (lambda (flag) (case flag ((a) 1) ((b) 2) ((c) 4) (else 64)))))
    (list (fewest-bytes (lambda () (fold-flags flags 'test-flags 'flags-not-a-list bit)))
          (if (>= (fewest-bytes (lambda () (make-bytevector 64))) 64)
              'meter-live
              'meter-blind))))

;; A read of a span or a pipe spec allocates nothing of its own, so a write
;; of a million spans pays nothing for reading them.
(test-equal "let-fixed-list allocates nothing, where the meter sees a 64-byte allocation"
  '(0 0 meter-live)
  (let ((span (list 1 2 3)) (short (list 1 2)))
    (list (fewest-bytes (lambda () (let-fixed-list (a b c) span 'mismatch (+ a b c))))
          (fewest-bytes (lambda () (let-fixed-list (a b c) short 'mismatch (+ a b c))))
          (if (>= (fewest-bytes (lambda () (make-bytevector 64))) 64)
              'meter-live
              'meter-blind))))

(test-equal "require-port refuses 65536, naming its caller and why"
  '(test-lift port-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (require-port 65536 'test-lift)
    'no-raise))

(test-equal "require-port refuses a negative port, naming its caller and why"
  '(test-lift port-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (require-port -1 'test-lift)
    'no-raise))

;; The FFI declares `int`: an inexact 8080.0 is either a Chez marshalling
;; error from deep inside the call or a silently truncated port, so
;; exactness is part of port-ness. 8080.0 satisfies integer? -- this row
;; fails through the exact? clause specifically.
(test-equal "require-port refuses an inexact port even inside the range"
  '(test-lift port-out-of-range)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (require-port 8080.0 'test-lift)
    'no-raise))

;; Both ends inclusive: 0 is "let the kernel choose" for uv-tcp-bind!, and
;; 65535 is a real port. A boundary nudged either way fails here.
(test-equal "require-port accepts both ends of 0..65535"
  'accepted
  (begin (require-port 0 'test-lift)
         (require-port 65535 'test-lift)
         'accepted))

;; --- debug counters (design spec S10) -----------------------------------
;; The dev shim is built with CHEZ_LIBUV_DEBUG_COUNTERS, so these are live.
;; Seeded: the counter is driven to a non-zero value and asserted there
;; first, so a counter permanently stuck at 0 cannot pass the balance check.

;; Task 2 (v0.4) added the signal row; #20 added async as the thirteenth;
;; block, every block the binding allocates, is the fourteenth.
(test-equal "live-counts reports all fourteen allocation classes"
  '(loop tcp timer write-req connect-req
    getaddrinfo-req getnameinfo-req read-buffer pipe process spawn-options
    signal async block)
  (map car (live-counts)))

;; Superseded by the twelve-class row above, kept for provenance:
;; (test-equal "live-counts reports all eleven allocation classes"
;;   '(loop tcp timer write-req connect-req
;;     getaddrinfo-req getnameinfo-req read-buffer pipe process spawn-options)
;;   (map car (live-counts)))
;;
;; (test-equal "live-counts reports all eight allocation classes"
;;   '(loop tcp timer write-req connect-req
;;     getaddrinfo-req getnameinfo-req read-buffer)
;;   (map car (live-counts)))

(test-equal "the counters start at zero"
  #t (for-all (lambda (p) (zero? (cdr p))) (live-counts)))

;; SEED / PRECONDITION, asserted before the eleven-class matrix below. Every
;; assertion in that matrix requires the DEV shim (built with
;; CHEZ_LIBUV_DEBUG_COUNTERS -- the Makefile's CFLAGS_DEV). Against a
;; production shim the counter entry points are no-ops whose live queries
;; always return 0, so all eleven "increments are visible" assertions would
;; fail while pointing at cross-wiring that is not there. This names the
;; real precondition first, so it is the assertion that fails, by name.
(count-loop-new!)
(test-equal "seed: this suite requires the debug-counter shim (a live query must move)"
  1 (live-count 'loop))
(count-loop-free!)

;; All eleven classes, not just one. There are twenty-two near-identical
;; count entry point names in the shim, and binding count-timer-new! to
;; chez_uv_count_tcp_new would be invisible to any test that only exercised
;; a single class. Each class is driven to a non-zero value (the seed),
;; checked to be the ONLY one that moved, then returned to zero. The
;; process and spawn-options rows are driven through the same exported
;; count-* procedures as every other row -- this suite deliberately
;; imports neither (libuv pipe) nor (libuv process); without these rows a
;; cross-wired spawn-options pair was invisible to everything but
;; valgrind.
(define counter-classes
  (list (list 'loop        count-loop-new!        count-loop-free!)
        (list 'tcp         count-tcp-new!         count-tcp-free!)
        (list 'pipe        count-pipe-new!        count-pipe-free!)
        (list 'process     count-process-new!     count-process-free!)
        (list 'timer       count-timer-new!       count-timer-free!)
        (list 'write-req   count-write-req-new!   count-write-req-free!)
        (list 'connect-req count-connect-req-new! count-connect-req-free!)
        (list 'getaddrinfo-req
              count-getaddrinfo-req-new! count-getaddrinfo-req-free!)
        (list 'getnameinfo-req
              count-getnameinfo-req-new! count-getnameinfo-req-free!)
        (list 'read-buffer count-read-buffer-new! count-read-buffer-free!)
        (list 'spawn-options
              count-spawn-options-new! count-spawn-options-free!)
        (list 'signal count-signal-new! count-signal-free!)
        (list 'async  count-async-new!  count-async-free!)
        ;; The block class has no count entries of its own: the shim's
        ;; allocator and free count it, so it is driven through those.
        (let ((held '()))
          (list 'block
                (lambda () (set! held (cons (alloc-zeroed 16) held)))
                (lambda () (free! (car held)) (set! held (cdr held)))))))

(for-each
 (lambda (entry)
   (let ((kind (car entry)) (inc! (cadr entry)) (dec! (caddr entry)))
     (inc!) (inc!)
     (test-equal (string-append "counter " (symbol->string kind)
                                ": increments are visible (seeded non-zero)")
       2 (live-count kind))
     (test-equal (string-append "counter " (symbol->string kind)
                                ": no other class moved")
       #t
       (for-all (lambda (p) (or (eq? (car p) kind) (zero? (cdr p))))
                (live-counts)))
     (dec!) (dec!)
     (test-equal (string-append "counter " (symbol->string kind)
                                ": decrements return it to zero")
       0 (live-count kind))))
 counter-classes)

(test-equal "every counter is back at its baseline afterwards"
  #t (for-all (lambda (p) (zero? (cdr p))) (live-counts)))

;; --- resolve-shim-path, in process, with synthetic paths ----------------
;; The real wiring is exercised end to end by tests/test-shim-loading.sps in
;; fresh subprocesses; here the pure resolution logic is called directly, so
;; the CONDITION TYPE and its path field can be asserted -- which an exit
;; code cannot show.
(define a-real-directory (current-directory))
(define a-real-non-library-file (string-append (current-directory) "/Makefile"))

(test-equal "resolve-shim-path accepts a valid absolute regular-file override"
  a-real-non-library-file
  (resolve-shim-path "/irrelevant/default" a-real-non-library-file))

(test-equal "resolve-shim-path accepts the default path when there is no override"
  a-real-non-library-file
  (resolve-shim-path a-real-non-library-file #f))

(test-equal "resolve-shim-path rejects a directory given as an override, naming it"
  a-real-directory
  (guard (e ((uv-shim-unavailable? e) (uv-shim-unavailable-path e))
            (#t 'wrong-condition))
    (resolve-shim-path "/irrelevant/default" a-real-directory)
    'no-raise))

(test-equal "resolve-shim-path rejects a directory as the default path"
  a-real-directory
  (guard (e ((uv-shim-unavailable? e) (uv-shim-unavailable-path e))
            (#t 'wrong-condition))
    (resolve-shim-path a-real-directory #f)
    'no-raise))

(test-equal "resolve-shim-path rejects a non-absolute override, naming it"
  "relative/path.dylib"
  (guard (e ((uv-shim-unavailable? e) (uv-shim-unavailable-path e))
            (#t 'wrong-condition))
    (resolve-shim-path a-real-non-library-file "relative/path.dylib")
    'no-raise))

;; The discriminating case for the absoluteness rule. A relative path that
;; does NOT exist is rejected by the regular-file? check alone, so it proves
;; nothing about absoluteness -- dropping the absolute-path? test entirely
;; still passes the assertion above. What must be refused is a relative path
;; that DOES resolve, under the current working directory: design spec S4
;; rule 1's "the working directory is never consulted".
;;
;; Seeded, so it cannot pass vacuously from a different cwd: the probe is
;; asserted to name a real file first. Both suites are run from the repo
;; root (the Makefile's `test` target, and the documented direct
;; invocation), where "Makefile" exists.
(define a-relative-existing-file "Makefile")

(test-equal "the relative-path probe really does name an existing file in the working directory"
  #t (file-exists? a-relative-existing-file))

(test-equal "resolve-shim-path rejects a relative override even when it names an existing regular file"
  a-relative-existing-file
  (guard (e ((uv-shim-unavailable? e) (uv-shim-unavailable-path e))
            (#t 'wrong-condition))
    (resolve-shim-path a-real-non-library-file a-relative-existing-file)
    'no-raise))

;; ...and the same rule applies to the DEFAULT path, not only the override.
;; The generated config.sls always holds an absolute path (the Makefile uses
;; $(abspath ...)), so without this assertion the rule would hold by
;; construction rather than by enforcement.
(test-equal "resolve-shim-path rejects a relative default path even when it names an existing regular file"
  a-relative-existing-file
  (guard (e ((uv-shim-unavailable? e) (uv-shim-unavailable-path e))
            (#t 'wrong-condition))
    (resolve-shim-path a-relative-existing-file #f)
    'no-raise))

(test-equal "resolve-shim-path rejects a nonexistent override, naming it"
  "/no/such/path.dylib"
  (guard (e ((uv-shim-unavailable? e) (uv-shim-unavailable-path e))
            (#t 'wrong-condition))
    (resolve-shim-path a-real-non-library-file "/no/such/path.dylib")
    'no-raise))

(test-equal "resolve-shim-path rejects an empty override, naming it"
  ""
  (guard (e ((uv-shim-unavailable? e) (uv-shim-unavailable-path e))
            (#t 'wrong-condition))
    (resolve-shim-path a-real-non-library-file "")
    'no-raise))

;; load-shim must wrap a genuine dlopen failure, not let the raw error out.
(test-equal "load-shim wraps a real dlopen failure in uv-shim-unavailable, carrying the path"
  a-real-non-library-file
  (guard (e ((uv-shim-unavailable? e) (uv-shim-unavailable-path e))
            (#t 'wrong-condition))
    (load-shim a-real-non-library-file)
    'no-raise))

;; --- the libuv leg: the SUBTYPE, through the same two procedures ---------
;; native.sls's uv-loaded definition routes libuv's own shared objects
;; through resolve-shim-path and load-shim with make-uv-libuv-unavailable,
;; so a libuv-path failure is no longer mislabeled as the shim's (the
;; final-review triage item). The maker argument is asserted here directly;
;; tests/test-shim-loading.sps drives the real uv-loaded wiring end to end
;; in a subprocess and greps for the subtype's name.
;;
;; Each row asserts the SHARPER predicate. The plain rows above prove the
;; default maker still answers the parent type, so the pair together is what
;; shows the argument actually selects the condition.
(test-equal "resolve-shim-path raises the caller-supplied maker: the libuv leg gets the subtype"
  '(libuv-unavailable "/no/such/libuv.dylib")
  (guard (e ((uv-libuv-unavailable? e)
             (list 'libuv-unavailable (uv-shim-unavailable-path e)))
            (#t 'wrong-condition))
    (resolve-shim-path "/no/such/libuv.dylib" #f make-uv-libuv-unavailable)
    'no-raise))

(test-equal "load-shim raises the caller-supplied maker on a real dlopen failure"
  '(libuv-unavailable #t)
  (guard (e ((uv-libuv-unavailable? e)
             (list 'libuv-unavailable
                   (string=? (uv-shim-unavailable-path e)
                             a-real-non-library-file)))
            (#t 'wrong-condition))
    (load-shim a-real-non-library-file make-uv-libuv-unavailable)
    'no-raise))

;; The two-argument resolve-shim-path and one-argument load-shim keep their
;; old contract: without a maker they still raise the PARENT type and not
;; the subtype, so no existing caller's discrimination changed underneath it.
(test-equal "without a maker, resolve-shim-path still raises the plain parent type"
  'parent-only
  (guard (e ((uv-libuv-unavailable? e) 'subtype)
            ((uv-shim-unavailable? e) 'parent-only)
            (#t 'wrong-condition))
    (resolve-shim-path "/no/such/path.dylib" #f)
    'no-raise))

;; The path this process actually resolved is the generated one, since the
;; suite runs with CHEZ_LIBUV_SHIM unset. Positive control for everything
;; above: if resolve-shim-path were broken in the other direction, the
;; library would not have imported at all.
(test-equal "the shim this process loaded is the one config.sls names"
  shim-path (shim-file))

;; --- the thirteen callback dispatcher slots, BEFORE anything installs them --
;; These rows live here, and only here, because this is the one suite whose
;; import chain never reaches (libuv private handles) -- and handles.sls
;; installs the thirteen dispatchers in its own library body, at instantiation
;; (design spec S4: "the slots themselves are filled exactly once, by
;; handles.sls"). In every other suite's process the install has therefore
;; already happened before the first test line runs, so the uninstalled
;; state, the partial-install refusal, and the install itself are only
;; observable from here.
;;
;; ORDER IS LOAD-BEARING: the slots are process-global and install-once, so
;; every "not installed yet" assertion has to run before the install below.
(test-equal "dispatcher-names names the thirteen callback types that cross into Scheme"
  '(read connection write-done close timer shutdown connect
    getaddrinfo getnameinfo exit walk signal async)
  dispatcher-names)

(test-equal "before installation, dispatchers-installed? is false"
  'not-installed (if (dispatchers-installed?) 'installed 'not-installed))

(for-each
 (lambda (name)
   (test-equal (string-append "an uninstalled " (symbol->string name)
                              " dispatcher raises &uv-error when invoked")
     'uv-error
     (guard (e ((uv-error? e) 'uv-error) (#t 'wrong-condition))
       ((dispatcher-ref name) 0)
       'no-raise)))
 dispatcher-names)

;; The exit and walk slots, specifically: v0.3's two additions to the
;; twelve, asserted with their own real arity (three args for exit, two for
;; walk) and the exact uninstalled-stub message, beside the generic
;; single-arg loop above (ADR-0015; test-native.sps never imports
;; handles.sls, so both slots stay uninstalled for the life of this suite's
;; process).
(test-assert "the exit slot holds the raising uninstalled stub"
  (guard (e (#t (and (uv-error? e)
                     (string=? (condition-message e)
                               "callback dispatchers have not been installed"))))
    ((dispatcher-ref 'exit) 0 0 0)
    #f))

(test-assert "the walk slot holds the raising uninstalled stub"
  (guard (e (#t (and (uv-error? e)
                     (string=? (condition-message e)
                               "callback dispatchers have not been installed"))))
    ((dispatcher-ref 'walk) 0 0)
    #f))

;; The signal slot, v0.4's thirteenth: uv_signal_cb's own (handle signum)
;; arity. It shares connection's arity and still has its own slot -- the
;; per-TYPE rule ADR-0008's third amendment states in its own terms.
(test-assert "the signal slot holds the raising uninstalled stub"
  (guard (e (#t (and (uv-error? e)
                     (string=? (condition-message e)
                               "callback dispatchers have not been installed"))))
    ((dispatcher-ref 'signal) 0 0)
    #f))

;; The async slot, #20's fourteenth: uv_async_cb's (handle) arity. Same arity
;; as close/timer, distinct callback TYPE, own slot (ADR-0008's per-type rule).
(test-assert "the async slot holds the raising uninstalled stub"
  (guard (e (#t (and (uv-error? e)
                     (string=? (condition-message e)
                               "callback dispatchers have not been installed"))))
    ((dispatcher-ref 'async) 0)
    #f))

(test-equal "dispatcher-ref rejects a name that is not one of the thirteen"
  '(uv-dispatcher-ref unknown-dispatcher)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (dispatcher-ref 'not-a-callback-type)
    'no-raise))

;; A partial install must be refused OUTRIGHT, leaving nothing installed --
;; a half-installed dispatcher table would hand libuv a trampoline that
;; raises from inside a C frame.
(test-equal "an install missing one of the thirteen is refused, naming who and why"
  '(uv-install-callback-dispatchers! incomplete-dispatcher-set)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (install-callback-dispatchers! (list (cons 'timer (lambda args 'partial))))
    'no-raise))

(test-equal "the refused install left the slots uninstalled"
  'not-installed (if (dispatchers-installed?) 'installed 'not-installed))

;; Stand-ins for the real dispatchers (which live in handles.sls, out of
;; this process's reach): each answers with its own name, so a cross-wired
;; slot is visible.
(install-callback-dispatchers!
 (map (lambda (name) (cons name (lambda args (list 'stub name args))))
      dispatcher-names))

(test-equal "after installation, dispatchers-installed? is true"
  'installed (if (dispatchers-installed?) 'installed 'not-installed))

(for-each
 (lambda (name)
   (test-equal (string-append "the " (symbol->string name)
                              " slot now answers with the procedure installed for it")
     (list 'stub name '(7))
     ((dispatcher-ref name) 7)))
 dispatcher-names)

(test-equal "a second install is refused, naming who and why"
  '(uv-install-callback-dispatchers! dispatchers-already-installed)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (install-callback-dispatchers!
     (map (lambda (name) (cons name (lambda args 'second))) dispatcher-names))
    'no-raise))

(test-equal "the refused second install did not rebind a slot"
  (list 'stub 'timer '(7))
  ((dispatcher-ref 'timer) 7))

(test-end "native")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
