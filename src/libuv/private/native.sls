#!r6rs
;;; The private FFI layer. This is the ONLY library in chez-libuv permitted
;;; to use load-shared-object, foreign-procedure, foreign-ref/foreign-set!,
;;; foreign-alloc/foreign-free, foreign-callable, define-ftype, or
;;; lock-object (design spec S3, S4). Nothing here is a supported public API.
;;;
;;; ORDERING NOTE -- the subtle part of this file, and the one AGENTS.md
;;; records in this repo's blood. Chez resolves a foreign entry point when
;;; the `foreign-procedure` expression is EVALUATED, not when the resulting
;;; procedure is first called. Every such definition below therefore has to
;;; run after the shared objects are loaded; library bodies evaluate their
;;; definitions in order, so each load is written as a `define` placed ahead
;;; of them. Moving one later fails at IMPORT time -- verbatim, from spike
;;; FINDINGS Q0:
;;;
;;;     Exception in foreign-procedure: no entry for "uv_version"
;;;
;;; which points at the binding, nowhere near the missing load.
;;;
;;; LOAD ORDER -- libuv's own shared object is loaded EXPLICITLY, and BEFORE
;;; the shim (design spec S4 rule 2). On Linux the symbols of a dlopen'd
;;; library's dependencies are not placed in the global namespace, so
;;; resolving uv_* entry points through the shim alone fails there while
;;; succeeding on macOS, whose loader searches dependencies. The sibling
;;; chez-cmark-gfm project's CI caught exactly that: green on macOS, red on
;;; Linux. Because macOS cannot observe the difference, Linux CI is the real
;;; guard for this invariant -- see .plans/stage-1-mutation-log.md.
(library (libuv private native)
  (export ;; loading and the init gate
          ensure-native-loaded! native-init-count native-initialized?
          resolve-shim-path load-shim shim-file
          version-supported? version-compatible? check-version-compatible!

          ;; version queries
          shim-compiled-version uv-version uv-version-string

          ;; errors (ADR-0006)
          errno->symbol errno->message uv-check

          ;; boundary copying (ADR-0009)
          c-string->string
          alloc-zeroed zero-out! free! copy-in! copy-out

          ;; uv_buf_t, the one struct this binding constructs
          uv-buf-set! uv-buf-base uv-buf-len uv-buf-ftype-layout

          ;; runtime sizes
          uv-loop-size uv-handle-size uv-req-size

          ;; the loop entry points (design spec S5). These are the RAW
          ;; bindings, one per libuv function, with libuv's own return
          ;; conventions intact -- uv-loop-run answers uv_run's int, not a
          ;; boolean. (libuv loop) owns the public spellings (uv-run,
          ;; uv-stop!, uv-loop-alive?, uv-now, uv-loop-close!) and every
          ;; policy decision about them.
          uv-loop-init uv-loop-run uv-loop-stop
          uv-loop-alive uv-loop-now uv-loop-close

          ;; callback dispatcher slots (ADR-0008, design spec S4)
          dispatcher-names dispatcher-ref dispatchers-installed?
          install-callback-dispatchers!

          ;; debug counters (design spec S10)
          live-counts
          count-loop-new!        count-loop-free!
          count-tcp-new!         count-tcp-free!
          count-timer-new!       count-timer-free!
          count-write-req-new!   count-write-req-free!
          count-connect-req-new! count-connect-req-free!
          count-read-buffer-new! count-read-buffer-free!)
  ;; file-exists? is deliberately absent from the (chezscheme) import below:
  ;; (rnrs) already exports it via (rnrs files), and importing it from both
  ;; raises "multiple definitions for file-exists? in body". The same is true
  ;; of `exit`.
  (import (rnrs)
          (only (chezscheme)
                load-shared-object foreign-procedure foreign-ref foreign-set!
                foreign-alloc foreign-free foreign-sizeof
                define-ftype ftype-sizeof ftype-set! ftype-ref ftype-&ref
                make-ftype-pointer ftype-pointer-address
                file-regular? make-mutex with-mutex getenv)
          (libuv private config)
          (libuv private conditions)
          (libuv private constants))

  ;; --- shim path resolution (design spec S4 rule 1) ---------------------
  ;; The override exists because config-in-the-environment is 12-factor. It
  ;; is VALIDATED, never searched: an absolute path to an existing regular
  ;; file, or nothing at all. There is no fallback search and the working
  ;; directory is never consulted. "Existing" alone is not enough --
  ;; file-exists? is also true of a directory, which would otherwise reach
  ;; load-shared-object and escape as a raw dlopen error instead of a
  ;; structured condition; the same goes for the generated default path if
  ;; the built shim is corrupt.
  ;;
  ;; Both steps (path validation, and wrapping the load) are ordinary
  ;; exported procedures rather than bare expressions, so they can be
  ;; unit-tested directly with synthetic paths from a single process
  ;; (tests/test-native.sps). The real wiring below still runs exactly once
  ;; per process, which is why tests/test-shim-loading.sps needs subprocesses
  ;; on top of that.
  (define (regular-file? path)
    (and (file-exists? path) (file-regular? path)))

  (define (absolute-path? path)
    (and (string? path)
         (> (string-length path) 0)
         (char=? (string-ref path 0) #\/)))

  ;; Absoluteness is required of BOTH candidates, not just the override.
  ;; Design spec S4 rule 1 says "an absolute, existing, regular-file path --
  ;; either the CHEZ_LIBUV_SHIM environment override or the path baked into
  ;; generated config.sls", and the generated path is produced by the
  ;; Makefile's $(abspath ...) precisely so it satisfies that. Checking only
  ;; the override would leave the rule true by construction rather than by
  ;; enforcement -- and a relative path that happens to exist under the
  ;; current working directory is exactly the "never searched" case this
  ;; procedure exists to refuse.
  (define (resolve-shim-path default-path override)
    (let ((candidate (or override default-path)))
      (if (and (absolute-path? candidate) (regular-file? candidate))
          candidate
          (raise (make-uv-shim-unavailable candidate)))))

  (define (load-shim path)
    (guard (e (#t (raise (make-uv-shim-unavailable path))))
      (load-shared-object path)))

  (define resolved-shim-path
    (resolve-shim-path shim-path (getenv "CHEZ_LIBUV_SHIM")))

  (define (shim-file) resolved-shim-path)

  ;; A definition, not a bare expression, so it is legal at this position in
  ;; an R6RS library body while still running before every binding below.
  ;; libuv FIRST (see the LOAD ORDER note in this file's header). Each path
  ;; goes through the SAME resolve-shim-path validation as the shim's --
  ;; design spec S4 rule 2 says "by absolute path", and routing it through
  ;; the one validated, tested procedure is what makes that a rule rather
  ;; than a property the generator happens to satisfy.
  (define uv-loaded
    (for-each (lambda (path) (load-shim (resolve-shim-path path #f)))
              uv-library-paths))

  (define shim-loaded (load-shim resolved-shim-path))

  ;; --- shim bindings ----------------------------------------------------
  ;; Everything below this point may assume both shared objects are loaded.
  (define shim-compiled-version
    (foreign-procedure "chez_uv_shim_compiled_version" () int))

  ;; chez_uv_constant writes through a `long *` out-parameter and returns
  ;; 1/0 for found/absent. The out-parameter is a foreign-alloc'd long rather
  ;; than a bytevector so the width comes from the C ABI (foreign-sizeof)
  ;; instead of an assumption baked into this file.
  (define raw-constant
    (foreign-procedure "chez_uv_constant" (string uptr) int))

  (define raw-errno-count (foreign-procedure "chez_uv_errno_count" () int))
  (define raw-errno-name  (foreign-procedure "chez_uv_errno_name" (int) uptr))
  (define raw-errno-value (foreign-procedure "chez_uv_errno_value" (int) int))

  ;; Debug counters. Bound unconditionally: the shim exports all eighteen
  ;; entry points in both build modes, the production build compiling them to
  ;; no-ops whose live queries return 0. Binding them conditionally would
  ;; make the FFI surface differ between builds -- exactly the kind of
  ;; difference that only shows up in the build nobody tested.
  (define count-loop-new!  (foreign-procedure "chez_uv_count_loop_new" () void))
  (define count-loop-free! (foreign-procedure "chez_uv_count_loop_free" () void))
  (define live-loop        (foreign-procedure "chez_uv_live_loop" () long))

  (define count-tcp-new!  (foreign-procedure "chez_uv_count_tcp_new" () void))
  (define count-tcp-free! (foreign-procedure "chez_uv_count_tcp_free" () void))
  (define live-tcp        (foreign-procedure "chez_uv_live_tcp" () long))

  (define count-timer-new!  (foreign-procedure "chez_uv_count_timer_new" () void))
  (define count-timer-free! (foreign-procedure "chez_uv_count_timer_free" () void))
  (define live-timer        (foreign-procedure "chez_uv_live_timer" () long))

  (define count-write-req-new!
    (foreign-procedure "chez_uv_count_write_req_new" () void))
  (define count-write-req-free!
    (foreign-procedure "chez_uv_count_write_req_free" () void))
  (define live-write-req (foreign-procedure "chez_uv_live_write_req" () long))

  (define count-connect-req-new!
    (foreign-procedure "chez_uv_count_connect_req_new" () void))
  (define count-connect-req-free!
    (foreign-procedure "chez_uv_count_connect_req_free" () void))
  (define live-connect-req
    (foreign-procedure "chez_uv_live_connect_req" () long))

  (define count-read-buffer-new!
    (foreign-procedure "chez_uv_count_read_buffer_new" () void))
  (define count-read-buffer-free!
    (foreign-procedure "chez_uv_count_read_buffer_free" () void))
  (define live-read-buffer
    (foreign-procedure "chez_uv_live_read_buffer" () long))

  ;; --- libuv bindings ---------------------------------------------------
  ;; v0.1 binds only what the version gate, the error translation, and the
  ;; allocation sizes need. Loop, timer, and TCP entry points arrive with the
  ;; stages that test them (design spec S12), so this file never carries a
  ;; binding no test exercises.
  ;;
  ;; uv_version() returns unsigned int; `int` is exact for it because
  ;; UV_VERSION_HEX is (major<<16 | minor<<8 | patch) and the sign bit is
  ;; unreachable for any libuv 1.x release (spike FINDINGS Q0, which bound it
  ;; both ways as a control and got the same value).
  (define uv-version (foreign-procedure "uv_version" () int))

  ;; Borrowed `const char *`, declared uptr and copied immediately by
  ;; c-string->string -- never `string`, so neither the lifetime nor the
  ;; encoding decision is delegated to Chez's marshalling (ADR-0009), and
  ;; NULL stays distinguishable from "".
  (define raw-version-string
    (foreign-procedure "uv_version_string" () uptr))

  ;; The _r forms write into a caller-supplied buffer and return it. The
  ;; non-_r uv_strerror/uv_err_name are deliberately avoided: they own a
  ;; static buffer that is not thread-safe and, in older libuv, leaked on
  ;; unknown codes.
  (define raw-strerror-r
    (foreign-procedure "uv_strerror_r" (int u8* size_t) uptr))
  (define raw-err-name-r
    (foreign-procedure "uv_err_name_r" (int u8* size_t) uptr))

  (define uv-loop-size   (foreign-procedure "uv_loop_size" () size_t))
  (define uv-handle-size (foreign-procedure "uv_handle_size" (int) size_t))
  (define uv-req-size    (foreign-procedure "uv_req_size" (int) size_t))

  ;; --- the loop entry points (design spec S5, spike/01-callback-gc.ss) ---
  ;; Every pointer is `uptr` (design spec S4 rule 4).
  ;;
  ;; uv_run's int is NOT an errno: it is 0 for "nothing left to do" and
  ;; nonzero for "handles or requests are still active", which is the exact
  ;; case uv-check's header warns must not be routed through it. (libuv
  ;; loop)'s uv-run interprets it directly.
  ;;
  ;; uv_loop_close's int IS an errno (-EBUSY when handles remain open --
  ;; spike FINDINGS Q2 measured -16), so that one goes through uv-check.
  ;;
  ;; uv_now returns uint64_t milliseconds; binding it `unsigned-64` rather
  ;; than `long` keeps it exact on every ILP32/LLP64 target and keeps the
  ;; value unsigned, which matters because the clock is an arbitrary origin,
  ;; not a small number.
  (define uv-loop-init  (foreign-procedure "uv_loop_init"  (uptr) int))
  (define uv-loop-run   (foreign-procedure "uv_run"        (uptr int) int))
  (define uv-loop-stop  (foreign-procedure "uv_stop"       (uptr) void))
  (define uv-loop-alive (foreign-procedure "uv_loop_alive" (uptr) int))
  (define uv-loop-now   (foreign-procedure "uv_now"        (uptr) unsigned-64))
  (define uv-loop-close (foreign-procedure "uv_loop_close" (uptr) int))

  ;; --- uv_buf_t (design spec S4 rule 4) ---------------------------------
  ;; The one libuv struct this binding CONSTRUCTS rather than merely holding
  ;; a pointer to. The declaration below is the POSIX layout; on Windows
  ;; uv_buf_t is {ULONG len; char *base;} (WSABUF order), which is why the
  ;; layout is validated against the shim's own offsetof()/sizeof() at init
  ;; and fails the library closed on any platform where the two disagree,
  ;; rather than silently writing the length into the pointer field
  ;; (ADR-0004 defers Windows; this is what "design stays portable" means
  ;; here -- it does not pretend to work, it refuses).
  (define-ftype uv-buf (struct (base uptr) (len size_t)))

  (define (uv-buf-set! addr base len)
    (let ((p (make-ftype-pointer uv-buf addr)))
      (ftype-set! uv-buf (base) p base)
      (ftype-set! uv-buf (len) p len)))

  (define (uv-buf-base addr)
    (ftype-ref uv-buf (base) (make-ftype-pointer uv-buf addr)))

  (define (uv-buf-len addr)
    (ftype-ref uv-buf (len) (make-ftype-pointer uv-buf addr)))

  ;; MEASURES the declared ftype rather than restating it:
  ;;   * size comes from ftype-sizeof;
  ;;   * each field's offset from ftype-&ref address arithmetic against a
  ;;     real allocation (Chez 10.4.1 has no ftype-offset-of; confirmed
  ;;     unbound);
  ;;   * each field's WIDTH from the byte extent a real ftype-set! actually
  ;;     writes -- fill with #xff, zero the field through the ftype, and see
  ;;     which bytes changed. That last one is what catches a field narrowed
  ;;     to 32 bits, which would leave every offset and the struct size
  ;;     intact while writing half the value libuv reads.
  ;; Nothing here consults the shim, so comparing this against the shim's
  ;; constants is a genuine two-source check rather than a tautology.
  ;; Returns (sizeof base-offset base-width len-offset len-width).
  (define (uv-buf-ftype-layout)
    (let* ((size (ftype-sizeof uv-buf))
           (addr (foreign-alloc size))
           (p    (make-ftype-pointer uv-buf addr)))
      (define (offset-of getter) (- (ftype-pointer-address (getter p)) addr))
      (define (fill! v)
        (let loop ((i 0))
          (when (< i size) (foreign-set! 'unsigned-8 addr i v) (loop (+ i 1)))))
      ;; Width of the run of bytes the setter cleared. Contiguity is checked
      ;; by construction: the run must start where the offset arithmetic says
      ;; the field starts, and any zero byte outside it makes the two
      ;; disagree, which the caller's assertions catch.
      (define (written-width setter!)
        (fill! #xff)
        (setter!)
        (let loop ((i 0) (n 0))
          (cond ((= i size) n)
                ((zero? (foreign-ref 'unsigned-8 addr i)) (loop (+ i 1) (+ n 1)))
                (else (loop (+ i 1) n)))))
      (let ((base-off (offset-of (lambda (q) (ftype-&ref uv-buf (base) q))))
            (len-off  (offset-of (lambda (q) (ftype-&ref uv-buf (len) q))))
            (base-width (written-width
                         (lambda () (ftype-set! uv-buf (base) p 0))))
            (len-width  (written-width
                         (lambda () (ftype-set! uv-buf (len) p 0)))))
        (foreign-free addr)
        (list size base-off base-width len-off len-width))))

  ;; --- borrowed string copying (ADR-0009) -------------------------------
  ;; Copies immediately into Scheme-owned storage. NULL becomes #f, which is
  ;; deliberately distinct from "": conflating them would invent data that
  ;; the C side never provided.
  (define (c-string->string addr)
    (if (zero? addr)
        #f
        (let scan ((len 0))
          (if (zero? (foreign-ref 'unsigned-8 addr len))
              (let ((bv (make-bytevector len)))
                (let copy ((i 0))
                  (if (= i len)
                      (utf8->string bv)
                      (begin
                        (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 addr i))
                        (copy (+ i 1))))))
              (scan (+ len 1))))))

  (define (uv-version-string) (c-string->string (raw-version-string)))

  ;; --- foreign memory helpers -------------------------------------------
  ;; Argument validation is not defensive padding here: this is the boundary
  ;; where a bad index stops being a Scheme error and becomes a segfault or a
  ;; silent heap corruption, so every one of these fails as a structured
  ;; condition instead.
  ;; Validated on the same terms as its neighbours, and BEFORE the loop: an
  ;; unvalidated (zero-out! 0 64) writes through NULL, and an inexact length
  ;; compares fine against `<` and would zero a prefix before anything
  ;; noticed. Both now fail as a structured condition with nothing written.
  (define (zero-out! addr len)
    (unless (and (integer? addr) (exact? addr) (positive? addr))
      (raise (make-uv-invalid-argument 'uv-zero-out! 'null-or-invalid-destination)))
    (unless (and (integer? len) (exact? len) (>= len 0))
      (raise (make-uv-invalid-argument 'uv-zero-out! 'length-out-of-range)))
    (let loop ((i 0))
      (when (< i len)
        (foreign-set! 'unsigned-8 addr i 0)
        (loop (+ i 1)))))

  (define (alloc-zeroed n)
    (unless (and (integer? n) (exact? n) (positive? n))
      (raise (make-uv-invalid-argument 'uv-alloc-zeroed 'size-must-be-positive)))
    (let ((addr (foreign-alloc n)))
      (zero-out! addr n)
      addr))

  ;; A null pointer reaching free! is always a bug: design spec S5/S6/S7
  ;; require every freeing site to zero the stored uptr immediately, so a
  ;; zeroed slot arriving here means something is freeing twice. Failing
  ;; loudly is the whole value of that rule -- a freed uv_* pointer answers
  ;; plausibly and wrongly rather than faulting (spike FINDINGS Q1).
  (define (free! addr)
    (unless (and (integer? addr) (exact? addr) (positive? addr))
      (raise (make-uv-invalid-argument 'uv-free! 'null-or-invalid-pointer)))
    (foreign-free addr))

  (define (copy-in! dst bv start len)
    (unless (and (integer? dst) (exact? dst) (positive? dst))
      (raise (make-uv-invalid-argument 'uv-copy-in! 'null-or-invalid-destination)))
    (unless (bytevector? bv)
      (raise (make-uv-invalid-argument 'uv-copy-in! 'source-not-a-bytevector)))
    (unless (and (exact? start) (integer? start) (>= start 0)
                 (exact? len) (integer? len) (>= len 0)
                 (<= (+ start len) (bytevector-length bv)))
      (raise (make-uv-invalid-argument 'uv-copy-in! 'span-out-of-range)))
    (let loop ((i 0))
      (when (< i len)
        (foreign-set! 'unsigned-8 dst i (bytevector-u8-ref bv (+ start i)))
        (loop (+ i 1)))))

  (define (copy-out src len)
    (unless (and (integer? src) (exact? src) (positive? src))
      (raise (make-uv-invalid-argument 'uv-copy-out 'null-or-invalid-source)))
    (unless (and (exact? len) (integer? len) (>= len 0))
      (raise (make-uv-invalid-argument 'uv-copy-out 'length-out-of-range)))
    (let ((bv (make-bytevector len)))
      (let loop ((i 0))
        (if (= i len)
            bv
            (begin
              (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 src i))
              (loop (+ i 1)))))))

  ;; --- error translation (ADR-0006) -------------------------------------
  ;; Both _r calls get a FRESH scratch bytevector rather than sharing one:
  ;; uv-check is reachable from inside a callback (design spec S8), and a
  ;; shared buffer would be a re-entrancy bug that only shows up under load.
  ;; 256 bytes is comfortably above libuv's longest strerror text; the call
  ;; truncates rather than overruns either way, since the length is passed.
  (define scratch-size 256)

  (define (r-call proc code)
    (let ((bv (make-bytevector scratch-size 0)))
      (proc code bv scratch-size)
      (let scan ((i 0))
        (if (or (= i scratch-size) (zero? (bytevector-u8-ref bv i)))
            (let ((out (make-bytevector i)))
              (bytevector-copy! bv 0 out 0 i)
              (utf8->string out))
            (scan (+ i 1))))))

  ;; libuv's own name for a code, as a symbol. Distinct from
  ;; (errno-value->symbol code): that one reads the shim's snapshot of
  ;; UV_ERRNO_MAP, this one asks the running library. tests/test-native.sps
  ;; asserts the two agree across the whole enumeration, which is what makes
  ;; either of them trustworthy.
  ;;
  ;; For a code libuv does NOT name, uv_err_name_r writes descriptive prose
  ;; ("Unknown system error -4096"), which would become a nonsense symbol. So
  ;; this is the cross-check, not the discriminant: `errno-value->symbol` is
  ;; what uv-check and every caller branch on, because its answer for an
  ;; unmapped code is the single documented sentinel 'UV_UNKNOWN.
  (define (errno->symbol code) (string->symbol (r-call raw-err-name-r code)))

  (define (errno->message code) (r-call raw-strerror-r code))

  ;; Nonzero is a failure. Callers whose C function legitimately returns a
  ;; positive value -- uv_run's "handles still active" is the one that
  ;; matters -- must NOT route it through here; they interpret their own
  ;; return value and call uv-check only on the negative-errno contract.
  ;;
  ;; The zero test is written `(zero? rc)`, never `(if rc ...)`: 0 is TRUE in
  ;; Scheme, so the latter would make this procedure never raise at all
  ;; (AGENTS.md's named trap).
  ;;
  ;; The raised object is a compound of &uv-errno-error (carrying the symbol
  ;; callers discriminate on, the raw platform int for diagnostics, and
  ;; uv_strerror_r's text), &who, and &message, so both a uv-aware guard and
  ;; a generic condition report see what happened.
  (define (uv-check rc who)
    (if (zero? rc)
        rc
        (let ((message (errno->message rc)))
          (raise (condition
                  (make-uv-errno-error (errno-value->symbol rc) rc message)
                  (make-who-condition who)
                  (make-message-condition message))))))

  (define (live-counts)
    (list (cons 'loop        (live-loop))
          (cons 'tcp         (live-tcp))
          (cons 'timer       (live-timer))
          (cons 'write-req   (live-write-req))
          (cons 'connect-req (live-connect-req))
          (cons 'read-buffer (live-read-buffer))))

  ;; --- callback dispatcher slots (ADR-0008, design spec S4) -------------
  ;; The eight trampolines Task 7 declares here as `foreign-callable`s have
  ;; mechanical bodies: they call the slot named for their callback type.
  ;; The slots' CONTENTS -- all dispatch policy, including the
  ;; store-and-reraise guard of design spec S8 -- are installed exactly once
  ;; by (libuv private handles), which is what keeps this file, the one
  ;; reviewed for FFI declarations, free of policy.
  ;;
  ;; The slots live HERE rather than in handles.sls for an import-graph
  ;; reason, not a stylistic one: handles.sls calls uv_stop (design spec S8's
  ;; "and uv_stop is called on that loop"), so handles.sls imports this
  ;; library. A trampoline body reaching the other way would close the cycle,
  ;; and R6RS libraries may not import circularly. The registry lookup the
  ;; design spec describes in the trampoline body therefore happens one step
  ;; later, inside the installed dispatcher itself -- same two steps, same
  ;; file boundary, no cycle.
  ;;
  ;; Task 6 creates no foreign-callables: only the slots, the stubs, and the
  ;; install gate exist yet.
  (define dispatcher-names
    '(alloc read connection write-done close timer shutdown connect))

  (define dispatchers (make-eq-hashtable))
  (define dispatchers-installed #f)

  (define (dispatchers-installed?) dispatchers-installed)

  ;; The uninstalled stub. It raises rather than returning a harmless value
  ;; because a callback firing before its policy exists means libuv is
  ;; already holding a pointer to a trampoline this binding cannot service --
  ;; there is no state in which quietly doing nothing is right. Raising from
  ;; inside a C frame is survivable exactly once, at development time; see
  ;; ADR-0008 on why the real dispatchers guard their bodies instead.
  (define (uninstalled-dispatcher name)
    (lambda args
      (raise (condition
              (make-uv-error)
              (make-who-condition name)
              (make-message-condition
               "callback dispatchers have not been installed")))))

  ;; A definition, not a bare expression: R6RS library bodies take all their
  ;; definitions before any expression, and this seeding has to run before
  ;; anything can look a slot up. Same shape as the `uv-loaded` definition
  ;; above, for the same reason.
  (define dispatchers-seeded
    (for-each (lambda (name)
                (hashtable-set! dispatchers name (uninstalled-dispatcher name)))
              dispatcher-names))

  ;; Looked up by name at fire time, never cached at declaration time: the
  ;; install happens after this library's body has finished running, so a
  ;; trampoline that captured its slot's value up front would capture the
  ;; stub forever.
  (define (dispatcher-ref name)
    (let ((proc (hashtable-ref dispatchers name #f)))
      (or proc
          (raise (make-uv-invalid-argument 'uv-dispatcher-ref
                                           'unknown-dispatcher)))))

  ;; alist: (name . procedure) for all eight names, in any order.
  ;;
  ;; All-or-nothing, and once only. A partial install would leave some slots
  ;; holding the raising stub while libuv already had their addresses; a
  ;; second install would let dispatch policy be rebound underneath a running
  ;; loop, which ADR-0008 rules out ("a second call asserts").
  (define (install-callback-dispatchers! alist)
    (when dispatchers-installed
      (raise (make-uv-invalid-argument 'uv-install-callback-dispatchers!
                                       'dispatchers-already-installed)))
    (unless (and (list? alist)
                 (= (length alist) (length dispatcher-names))
                 (for-all (lambda (name)
                            (let ((entry (assq name alist)))
                              (and entry (procedure? (cdr entry)))))
                          dispatcher-names))
      (raise (make-uv-invalid-argument 'uv-install-callback-dispatchers!
                                       'incomplete-dispatcher-set)))
    ;; Committed only after the whole set has been validated, so a refused
    ;; install leaves every slot exactly as it was.
    (for-each (lambda (name)
                (hashtable-set! dispatchers name (cdr (assq name alist))))
              dispatcher-names)
    (set! dispatchers-installed #t))

  ;; --- the init gate (design spec S4) -----------------------------------
  (define (version-supported? v)
    (let ((lo (car uv-supported-version-range))
          (hi (cdr uv-supported-version-range)))
      (and (>= v lo) (<= v hi))))

  ;; Compatible when BOTH the version the shim was COMPILED against and the
  ;; version uv_version() reports at RUNTIME fall inside the supported range.
  ;; Deliberately not `(= compiled runtime)`: libuv guarantees ABI stability
  ;; across its 1.x series, so equality would force a shim rebuild on every
  ;; upstream patch release the project already declares supported. Checking
  ;; `compiled` as well as `runtime` catches a shim built against an
  ;; unsupported header, which the runtime check alone would miss.
  (define (version-compatible? compiled runtime)
    (and (version-supported? compiled)
         (version-supported? runtime)))

  ;; The gate itself, as a named exported procedure rather than an inline
  ;; expression inside ensure-native-loaded! -- the same reasoning that makes
  ;; resolve-shim-path and load-shim ordinary procedures. Against a matching
  ;; shim and library the raise arm runs zero times per process, so calling
  ;; it directly with synthetic versions is the ONLY way its PAYLOAD can be
  ;; asserted: without that, swapping the condition's compiled/runtime
  ;; arguments would be an uncaught mutation. Returns `runtime` on success so
  ;; the happy path has a value only success produces.
  (define (check-version-compatible! compiled runtime)
    (if (version-compatible? compiled runtime)
        runtime
        (raise (make-uv-version-incompatible compiled runtime))))

  ;; The name-keyed constant lookup handed to (libuv private constants).
  ;; Returns the value, or #f when the shim's table has no such name -- the
  ;; #f is consumed immediately by constants.sls, which turns it into
  ;; &uv-constant-unavailable naming the constant. The out-parameter's width
  ;; comes from foreign-sizeof, not from a literal 8.
  (define (lookup-constant name)
    (let* ((out (foreign-alloc (foreign-sizeof 'long)))
           (found (guard (e (#t (foreign-free out) (raise e)))
                    (raw-constant name out)))
           (value (if (zero? found) #f (foreign-ref 'long out 0))))
      (foreign-free out)
      value))

  (define (errno-name-at i) (c-string->string (raw-errno-name i)))

  ;; Chez here is threaded, and this runs before anything else in the
  ;; binding, so it is serialised. The mutex lives in Scheme rather than C
  ;; deliberately: a C mutex would need pthreads, and POSIX-only APIs are
  ;; barred so Windows stays reachable later (ADR-0004).
  (define init-mutex (make-mutex))
  (define initialized? #f)
  (define init-count 0)

  (define (native-initialized?) initialized?)

  ;; Exported for tests/test-native.sps: counting how often the guarded body
  ;; actually ran is what makes the idempotence assertion discriminating.
  ;; "Calling it twice does not raise" would pass identically against a
  ;; native.sls with no guard at all.
  (define (native-init-count) init-count)

  ;; Validated at init, not asserted in a comment (AGENTS.md): the ftype
  ;; declared above and the struct the shim's C compiler measured must agree
  ;; on size, on both offsets, and on both field widths. A mismatch fails the
  ;; whole library closed with &uv-shim-unavailable carrying the shim path,
  ;; because the shim is the artifact that has come apart from the ftype.
  (define (validate-uv-buf-layout!)
    (let* ((layout     (uv-buf-ftype-layout))
           (size       (list-ref layout 0))
           (base-off   (list-ref layout 1))
           (base-width (list-ref layout 2))
           (len-off    (list-ref layout 3))
           (len-width  (list-ref layout 4)))
      (unless (and (= size (sizeof-uv-buf-t))
                   (= base-off (offsetof-uv-buf-t-base))
                   (= len-off (offsetof-uv-buf-t-len))
                   ;; Each field must exactly fill the span the offsets
                   ;; imply, so a narrowed or widened field type is caught
                   ;; even though every offset still matches.
                   (= (+ base-off base-width) len-off)
                   (= (+ len-off len-width) size))
        (raise (make-uv-shim-unavailable resolved-shim-path)))))

  ;; Idempotent, mutex'd, and fails closed on every gate: an out-of-range
  ;; version pair, a constant the shim does not define, or a uv_buf_t layout
  ;; the ftype does not match. All of it happens before a single handle can
  ;; be created.
  (define (ensure-native-loaded!)
    (with-mutex init-mutex
      (unless initialized?
        (check-version-compatible! (shim-compiled-version) (uv-version))
        (constants-init! lookup-constant raw-errno-count
                         errno-name-at raw-errno-value)
        (validate-uv-buf-layout!)
        (set! init-count (+ init-count 1))
        (set! initialized? #t)))))
