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
        (srfi :64)
        (libuv private native)
        (libuv private constants)
        (libuv private conditions)
        (libuv private config)
        ;; foreign-alloc / foreign-set! / foreign-ref / foreign-free build
        ;; and mutate real C buffers for the string- and memory-helper tests
        ;; below; current-directory anchors the synthetic absolute paths used
        ;; by the resolve-shim-path matrix. None collides with an (rnrs)
        ;; export (unlike file-exists? and exit, which do).
        (only (chezscheme) foreign-alloc foreign-set! foreign-ref foreign-free
              foreign-sizeof current-directory getenv))

;; SRFI-64's default runner does not set a process exit code, so a failing
;; suite would still exit 0 and `make test` would report success. Hold the
;; runner so its fail count can drive the exit status (AGENTS.md).
(define runner (test-runner-simple))
(test-runner-current runner)

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

;; The rejection must happen BEFORE any write. An inexact length is the case
;; that discriminates: `(< i 3.0)` is perfectly true, so an unvalidated
;; zero-out! would zero three bytes and only then (never) complain. The
;; buffer is seeded #xff, asserted #xff, then must still be #xff afterwards.
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
;; The seed assertion below is what keeps this honest across platforms: it
;; proves the churn really does leave dirty memory on the free list. On an
;; allocator that always zeroes, that assertion fails BY NAME -- telling us
;; the next one is non-discriminating -- instead of letting it pass vacuously
;; against an alloc-zeroed that does nothing (AGENTS.md).
(define churn-size (sizeof-uv-loop-t))

(define (any-nonzero? addr len)
  (let loop ((i 0))
    (cond ((= i len) #f)
          ((zero? (foreign-ref 'unsigned-8 addr i)) (loop (+ i 1)))
          (else #t))))

;; Allocate, fill with #xff, free -- leaving the allocator's free list dirty.
(define (churn-dirty-blocks! reps)
  (let loop ((i 0) (acc '()))
    (if (= i reps)
        (for-each foreign-free acc)
        (let ((a (foreign-alloc churn-size)))
          (let fill ((j 0))
            (when (< j churn-size)
              (foreign-set! 'unsigned-8 a j #xff)
              (fill (+ j 1))))
          (loop (+ i 1) (cons a acc))))))

;; Self-dirtying, not hoping. This used to churn 32 blocks, free all of
;; them, then allocate ONE fresh block and hope the allocator handed back
;; one of the 32 just-freed ones. It doesn't always: Valgrind's own
;; allocator quarantines freed blocks (to catch use-after-free) rather than
;; recycling them straight back, so the "fresh" block it hands the next
;; caller can be a genuinely fresh, zeroed one -- which is exactly what this
;; seed is here to catch, and exactly what it caught under Valgrind.
;;
;; Freeing and immediately re-requesting the SAME size targets the
;; allocator's own free-list/fastbin path directly instead of depending on
;; what an unrelated batch of frees happened to leave behind. But a SINGLE
;; alloc/free/alloc cycle is not enough either -- measured directly
;; (scratchpad probe, macOS): the first ~3 cycles at a size class come back
;; clean every time (a first-touch page, zero-filled on fault), and only
;; from the 4th cycle onward does the allocator actually recycle the same
;; bytes it was just handed. So this warms the SAME slot up across several
;; cycles and only asserts on the last one, with margin over the observed
;; threshold.
(define (alloc-fill-free-cycle! size)
  (let ((a (foreign-alloc size)))
    (let fill ((i 0))
      (when (< i size)
        (foreign-set! 'unsigned-8 a i #xff)
        (fill (+ i 1))))
    (foreign-free a)))

;; Root-caused under real Valgrind (run 4): recycled-dirt is unobservable
;; there BY DESIGN, not by an insufficient warm-up. Memcheck's own freelist
;; (--freelist-vol, ~20MB by default) exists SPECIFICALLY to delay reusing a
;; freed block, so it can still flag a use-after-free against it -- no
;; warm-up depth can make an alloc-after-free observe the just-freed block's
;; leftover bytes there, because Memcheck's whole point is to keep serving
;; genuinely different memory instead. make test-memory's Linux leg sets
;; CHEZ_LIBUV_UNDER_VALGRIND=1 for exactly this reason: under it, the seed
;; drops to the weak form below (proves the fill/read-back machinery works,
;; nothing about allocator dirt) rather than asserting a property Valgrind
;; makes structurally unobservable. See the stage-1 mutation log addendum
;; for what this costs and where that coverage actually lives instead.
(if (getenv "CHEZ_LIBUV_UNDER_VALGRIND")
    (test-equal "seed: a plain foreign-alloc really does hand back dirty memory at this size (valgrind: recycled-dirt unobservable by design)"
      #t
      (let ((a (foreign-alloc churn-size)))
        (let fill ((i 0))
          (when (< i churn-size)
            (foreign-set! 'unsigned-8 a i #xff)
            (fill (+ i 1))))
        (let ((filled (all-bytes-equal? a churn-size #xff)))
          (foreign-free a)
          filled)))
    (test-equal "seed: a plain foreign-alloc really does hand back dirty memory at this size"
      #t
      (begin
        (let loop ((i 0)) (when (< i 8) (alloc-fill-free-cycle! churn-size) (loop (+ i 1))))
        (let* ((a (foreign-alloc churn-size))
               (dirty (any-nonzero? a churn-size)))
          (foreign-free a)
          dirty))))

(churn-dirty-blocks! 32)
(test-equal "alloc-zeroed returns zeroed memory even when the allocator hands back a dirty block"
  #t
  (let loop ((i 0) (blocks '()) (ok #t))
    (if (= i 32)
        (begin (for-each free! blocks) ok)
        (let ((a (alloc-zeroed churn-size)))
          (loop (+ i 1) (cons a blocks)
                (and ok (all-bytes-equal? a churn-size 0)))))))

(test-equal "alloc-zeroed rejects a non-positive size"
  'uv-alloc-zeroed
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-who e))
            (#t 'wrong-condition))
    (alloc-zeroed 0)
    'no-raise))

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

;; copy-in! / copy-out are the two halves of ADR-0009's copy-at-the-boundary
;; rule. Round-trip through real foreign memory, including a non-zero start
;; offset so an implementation ignoring `start` is caught.
(let ((addr (alloc-zeroed 8))
      (src (u8-list->bytevector (list 10 20 30 40 50))))
  (copy-in! addr src 1 3)
  (test-equal "copy-in! copies the requested span, honouring start"
    (u8-list->bytevector (list 20 30 40))
    (copy-out addr 3))
  (test-equal "copy-in! writes nothing past the copied length"
    0 (foreign-ref 'unsigned-8 addr 3))
  ;; copy-out must copy, not alias: mutating the source afterwards must not
  ;; change the bytevector already handed back.
  (let ((out (copy-out addr 3)))
    (foreign-set! 'unsigned-8 addr 0 #x7f)
    (test-equal "copy-out copies: mutating the foreign source afterwards leaves the result unchanged"
      (u8-list->bytevector (list 20 30 40)) out))
  (free! addr))

(test-equal "copy-in! rejects a span that runs past the end of the bytevector"
  'uv-copy-in!
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-who e))
            (#t 'wrong-condition))
    (let ((addr (alloc-zeroed 8)))
      (guard (inner (#t (free! addr) (raise inner)))
        (copy-in! addr (u8-list->bytevector (list 1 2 3)) 1 3)))
    'no-raise))

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
(let ((cell (alloc-zeroed 4)))
  (copy-in! cell (u8-list->bytevector (list #xb4 #x39 #x00 #x50)) 0 4)
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
;; itself means only the genuine parse-then-render path can pass.
(let ((addr (alloc-zeroed (sizeof-sockaddr-storage))))
  (fill-sockaddr! addr "127.0.0.1" 8080 'test-sockaddr-round-trip)
  (test-equal "sockaddr->address-string renders back the dotted quad uv_ip4_addr parsed"
    "127.0.0.1" (sockaddr->address-string addr))
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

;; --- require-address / require-port (post-v0.2 lift) --------------------
;; The ADR-0012 input vocabulary's validators, asserted at their shared
;; home: tcp.sls and dns.sls both import THIS copy, so these rows pin the
;; semantics every verb boundary observes. `who` is a symbol no real
;; caller passes: each raise must name the caller handed in, not the
;; helper or a baked-in verb name.
(test-equal "require-address refuses a non-string, naming its caller and why"
  '(test-lift address-not-a-string)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (require-address 42 'test-lift)
    'no-raise))

;; Address-ness here is string?-ness BY DESIGN: parse refusal is
;; fill-sockaddr!'s job (spike FINDINGS Q3), so a validator tightened to
;; pre-parse would fail this row by name.
(test-equal "require-address accepts a string it cannot parse (parsing is fill-sockaddr!'s job)"
  'accepted
  (begin (require-address "not-an-ip" 'test-lift) 'accepted))

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
(define (live-count kind)
  (cdr (assq kind (live-counts))))

;; Task 4 adds the three new rows to live-counts; until then this assertion
;; stays RED and is skipped by the commented block below.
;; (test-equal "live-counts reports all eleven allocation classes"
;;   '(loop tcp timer write-req connect-req
;;     getaddrinfo-req getnameinfo-req read-buffer pipe process spawn-options)
;;   (map car (live-counts)))

;; For now, assert the eight existing classes:
(test-equal "live-counts reports all eight allocation classes"
  '(loop tcp timer write-req connect-req
    getaddrinfo-req getnameinfo-req read-buffer)
  (map car (live-counts)))

(test-equal "the counters start at zero"
  #t (for-all (lambda (p) (zero? (cdr p))) (live-counts)))

;; SEED / PRECONDITION, asserted before the eight-class matrix below. Every
;; assertion in that matrix requires the DEV shim (built with
;; CHEZ_LIBUV_DEBUG_COUNTERS -- the Makefile's CFLAGS_DEV). Against a
;; production shim the counter entry points are no-ops whose live queries
;; always return 0, so all eight "increments are visible" assertions would
;; fail while pointing at cross-wiring that is not there. This names the
;; real precondition first, so it is the assertion that fails, by name.
(count-loop-new!)
(test-equal "seed: this suite requires the debug-counter shim (a live query must move)"
  1 (live-count 'loop))
(count-loop-free!)

;; All eight classes, not just one. There are twenty-four near-identical
;; entry point names in the shim, and binding count-timer-new! to
;; chez_uv_count_tcp_new would be invisible to any test that only exercised
;; a single class. Each class is driven to a non-zero value (the seed),
;; checked to be the ONLY one that moved, then returned to zero.
(define counter-classes
  (list (list 'loop        count-loop-new!        count-loop-free!)
        (list 'tcp         count-tcp-new!         count-tcp-free!)
        (list 'timer       count-timer-new!       count-timer-free!)
        (list 'write-req   count-write-req-new!   count-write-req-free!)
        (list 'connect-req count-connect-req-new! count-connect-req-free!)
        (list 'getaddrinfo-req
              count-getaddrinfo-req-new! count-getaddrinfo-req-free!)
        (list 'getnameinfo-req
              count-getnameinfo-req-new! count-getnameinfo-req-free!)
        (list 'read-buffer count-read-buffer-new! count-read-buffer-free!)))

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

;; --- the ten callback dispatcher slots, BEFORE anything installs them ---
;; These rows live here, and only here, because this is the one suite whose
;; import chain never reaches (libuv private handles) -- and handles.sls
;; installs the ten dispatchers in its own library body, at instantiation
;; (design spec S4: "the slots themselves are filled exactly once, by
;; handles.sls"). In every other suite's process the install has therefore
;; already happened before the first test line runs, so the uninstalled
;; state, the partial-install refusal, and the install itself are only
;; observable from here.
;;
;; ORDER IS LOAD-BEARING: the slots are process-global and install-once, so
;; every "not installed yet" assertion has to run before the install below.
(test-equal "dispatcher-names names the ten callback types the design commits to"
  '(alloc read connection write-done close timer shutdown connect
    getaddrinfo getnameinfo)
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

(test-equal "dispatcher-ref rejects a name that is not one of the ten"
  '(uv-dispatcher-ref unknown-dispatcher)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (dispatcher-ref 'not-a-callback-type)
    'no-raise))

;; A partial install must be refused OUTRIGHT, leaving nothing installed --
;; a half-installed dispatcher table would hand libuv a trampoline that
;; raises from inside a C frame.
(test-equal "an install missing one of the ten is refused, naming who and why"
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
