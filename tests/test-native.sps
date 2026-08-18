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
              current-directory))

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
        (cons 'SIZEOF_SOCKADDR_STORAGE sizeof-sockaddr-storage)))

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

;; The three request tags are distinct members of uv_req_type, exactly as
;; UV_TCP/UV_TIMER are of uv_handle_type. Without this, a snapshot that
;; collapsed them would still satisfy the three assertions above only if the
;; sizes happened to coincide -- which two of them nearly do.
(test-equal "the write, connect, and shutdown request tags are pairwise distinct"
  #t
  (pairwise-distinct? (list (uv-write-req-type) (uv-connect-req-type)
                            (uv-shutdown-req-type))))

;; UV_TCP and UV_TIMER are different members of uv_handle_type; a snapshot
;; that collapsed them would make the two handle families indistinguishable.
(test-equal "the tcp and timer handle type tags are distinct"
  #t (not (= (uv-tcp-type) (uv-timer-type))))

(test-equal "AF_INET and AF_UNSPEC are distinct"
  #t (not (= (af-inet) (af-unspec))))

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
(test-equal "c-string->string maps NULL to #f" #f (c-string->string 0))

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

(churn-dirty-blocks! 32)
(test-equal "seed: a plain foreign-alloc really does hand back dirty memory at this size"
  #t
  (let* ((a (foreign-alloc churn-size))
         (dirty (any-nonzero? a churn-size)))
    (foreign-free a)
    dirty))

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

;; --- debug counters (design spec S10) -----------------------------------
;; The dev shim is built with CHEZ_LIBUV_DEBUG_COUNTERS, so these are live.
;; Seeded: the counter is driven to a non-zero value and asserted there
;; first, so a counter permanently stuck at 0 cannot pass the balance check.
(define (live-count kind)
  (cdr (assq kind (live-counts))))

(test-equal "live-counts reports all six allocation classes"
  '(loop tcp timer write-req connect-req read-buffer)
  (map car (live-counts)))

(test-equal "the counters start at zero"
  #t (for-all (lambda (p) (zero? (cdr p))) (live-counts)))

;; All six classes, not just one. There are eighteen near-identical entry
;; point names in the shim, and binding count-timer-new! to
;; chez_uv_count_tcp_new would be invisible to any test that only exercised
;; a single class. Each class is driven to a non-zero value (the seed),
;; checked to be the ONLY one that moved, then returned to zero.
(define counter-classes
  (list (list 'loop        count-loop-new!        count-loop-free!)
        (list 'tcp         count-tcp-new!         count-tcp-free!)
        (list 'timer       count-timer-new!       count-timer-free!)
        (list 'write-req   count-write-req-new!   count-write-req-free!)
        (list 'connect-req count-connect-req-new! count-connect-req-free!)
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

;; The path this process actually resolved is the generated one, since the
;; suite runs with CHEZ_LIBUV_SHIM unset. Positive control for everything
;; above: if resolve-shim-path were broken in the other direction, the
;; library would not have imported at all.
(test-equal "the shim this process loaded is the one config.sls names"
  shim-path (shim-file))

(test-end "native")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
