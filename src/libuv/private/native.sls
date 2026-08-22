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
          errno->symbol errno->message uv-check uv-errno-condition

          ;; boundary copying (ADR-0009)
          c-string->string
          alloc-zeroed zero-out! free! copy-in! copy-out
          c-int-size c-int-ref c-int-set! c-uptr-ref read-net-u16
          ;; the pointer-wide and unsigned-32 siblings of c-int-set! (v0.3
          ;; S5.5): argv/env pointer arrays and uid/gid need widths c-int-set!
          ;; cannot write.
          c-uptr-size c-uptr-set! c-u32-set!

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

          ;; the timer and close entry points (design spec S5). The two that
          ;; take a C function pointer -- uv_timer_start and uv_close -- are
          ;; NOT exported raw: their wrappers below bake in this library's own
          ;; trampoline entry points, which is what keeps every locked
          ;; callable and every entry-point uptr inside this file.
          uv-timer-init uv-timer-start-native uv-timer-stop uv-timer-again
          uv-timer-set-repeat uv-timer-get-repeat
          uv-close-native uv-is-closing

          ;; the TCP and stream entry points (design spec S5, S6, S7). The
          ;; five that take a C function pointer -- uv_listen, uv_tcp_connect,
          ;; uv_write, uv_shutdown and uv_read_start (which takes two) -- are
          ;; NOT exported raw, for the same reason as uv_timer_start and
          ;; uv_close above: their wrappers bake in this library's own
          ;; trampoline entry points.
          uv-tcp-init uv-tcp-bind uv-tcp-getsockname uv-tcp-nodelay
          uv-listen-native uv-accept uv-tcp-connect-native
          uv-write-native uv-shutdown-native
          uv-read-start-native uv-read-stop
          uv-ip4-addr uv-ip6-addr

          ;; the DNS entry points (design spec v0.2 S5.1). The two that take
          ;; a C function pointer -- uv_getaddrinfo and uv_getnameinfo -- are
          ;; NOT exported raw, for the same reason as the timer and stream
          ;; wrappers above: their wrappers bake in this library's own
          ;; trampoline entry points. uv_ip_name is not exported raw either
          ;; -- it dereferences its argument unconditionally, so its whole
          ;; public face is the zero-refusing sockaddr->address-string.
          uv-getaddrinfo-native uv-getnameinfo-native
          uv-cancel uv-freeaddrinfo
          sockaddr->address-string

          ;; helpers lifted from (libuv tcp) (design spec v0.2 S5.1):
          ;; boundary-writing mechanics and allocation-layout arithmetic,
          ;; shared by tcp.sls and (v0.2 Stage 4) dns.sls. Neither carries
          ;; dispatch policy, so this file's mechanical/policy-free review
          ;; property survives the lift.
          fill-sockaddr! align-16
          ;; ADR-0012's argument validators followed post-v0.2 (the
          ;; whole-branch review's duplication finding): one copy for the
          ;; tcp.sls and dns.sls verbs that had each restated them.
          require-address require-port
          ;; lifted verbatim from tcp.sls (PR #4's shared-validator rule):
          ;; the same "is this an on-callback argument a real procedure" gate
          ;; tcp.sls, stream.sls, and process.sls all need.
          require-callback

          ;; callback dispatcher slots (ADR-0008, design spec S4)
          dispatcher-names dispatcher-ref dispatchers-installed?
          install-callback-dispatchers!

          ;; the process and pipe entry points (design spec v0.3 S5.2). The
          ;; one that takes a C function pointer -- uv_spawn's exit_cb, which
          ;; lives INSIDE uv_process_options_t rather than arriving as an
          ;; argument -- is NOT exported raw, for the same reason as every
          ;; other *-native wrapper above: it bakes in this library's own
          ;; trampoline entry point. uv_process_kill, uv_kill,
          ;; uv_process_get_pid, and uv_pipe_init take no callback, so they
          ;; are exported directly. uv-walk-native bakes in the walk
          ;; trampoline the same way as the timer/stream/DNS *-native
          ;; wrappers; the query built on top of it lives in handles.sls.
          uv-spawn-native
          uv-process-kill uv-kill uv-process-get-pid uv-pipe-init
          uv-walk-native

          ;; the signal entry points (design spec 2026-08-22 §5.2,
          ;; ADR-0017). The two start calls take a uv_signal_cb and are NOT
          ;; exported raw: both wrappers bake in the ONE signal trampoline
          ;; (ADR-0008 third amendment). init/stop take no callback.
          ;; uv-os-getpid-native is the raw pid query (libuv process) gates.
          uv-signal-init uv-signal-start-native
          uv-signal-start-oneshot-native uv-signal-stop
          uv-os-getpid-native

          ;; debug counters (design spec S10)
          live-counts
          count-loop-new!        count-loop-free!
          count-tcp-new!         count-tcp-free!
          count-timer-new!       count-timer-free!
          count-write-req-new!   count-write-req-free!
          count-connect-req-new! count-connect-req-free!
          count-getaddrinfo-req-new! count-getaddrinfo-req-free!
          count-getnameinfo-req-new! count-getnameinfo-req-free!
          count-read-buffer-new! count-read-buffer-free!
          count-pipe-new!         count-pipe-free!
          count-process-new!      count-process-free!
          count-spawn-options-new! count-spawn-options-free!
          count-signal-new!      count-signal-free!)
  ;; file-exists? is deliberately absent from the (chezscheme) import below:
  ;; (rnrs) already exports it via (rnrs files), and importing it from both
  ;; raises "multiple definitions for file-exists? in body". The same is true
  ;; of `exit`.
  (import (rnrs)
          (only (chezscheme)
                load-shared-object foreign-procedure foreign-ref foreign-set!
                foreign-alloc foreign-free foreign-sizeof
                foreign-callable foreign-callable-entry-point lock-object
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
  ;;
  ;; The optional third/second argument is the condition MAKER, defaulting
  ;; to the shim's own: the libuv leg below passes make-uv-libuv-unavailable
  ;; so a libuv-path failure carries the subtype instead of being mislabeled
  ;; as the shim's (final-review triage; both arities are asserted in
  ;; tests/test-native.sps, the wiring end to end in
  ;; tests/test-shim-loading.sps).
  (define resolve-shim-path
    (case-lambda
      ((default-path override)
       (resolve-shim-path default-path override make-uv-shim-unavailable))
      ((default-path override make-unavailable)
       (let ((candidate (or override default-path)))
         (if (and (absolute-path? candidate) (regular-file? candidate))
             candidate
             (raise (make-unavailable candidate)))))))

  (define load-shim
    (case-lambda
      ((path) (load-shim path make-uv-shim-unavailable))
      ((path make-unavailable)
       (guard (e (#t (raise (make-unavailable path))))
         (load-shared-object path)))))

  (define resolved-shim-path
    (resolve-shim-path shim-path (getenv "CHEZ_LIBUV_SHIM")))

  (define (shim-file) resolved-shim-path)

  ;; A definition, not a bare expression, so it is legal at this position in
  ;; an R6RS library body while still running before every binding below.
  ;; libuv FIRST (see the LOAD ORDER note in this file's header). Each path
  ;; goes through the SAME resolve-shim-path validation as the shim's --
  ;; design spec S4 rule 2 says "by absolute path", and routing it through
  ;; the one validated, tested procedure is what makes that a rule rather
  ;; than a property the generator happens to satisfy. A failure here raises
  ;; &uv-libuv-unavailable -- a SUBTYPE of the shim's &uv-shim-unavailable,
  ;; so guards on the parent keep matching while the sharper predicate now
  ;; tells a libuv-path failure apart from a shim failure without reading
  ;; the path field (README.org's condition table; the v0.2 subtype
  ;; consideration, resolved post-v0.1).
  (define uv-loaded
    (for-each (lambda (path)
                (load-shim (resolve-shim-path path #f make-uv-libuv-unavailable)
                           make-uv-libuv-unavailable))
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

  (define count-getaddrinfo-req-new!
    (foreign-procedure "chez_uv_count_getaddrinfo_req_new" () void))
  (define count-getaddrinfo-req-free!
    (foreign-procedure "chez_uv_count_getaddrinfo_req_free" () void))
  (define live-getaddrinfo-req
    (foreign-procedure "chez_uv_live_getaddrinfo_req" () long))

  (define count-getnameinfo-req-new!
    (foreign-procedure "chez_uv_count_getnameinfo_req_new" () void))
  (define count-getnameinfo-req-free!
    (foreign-procedure "chez_uv_count_getnameinfo_req_free" () void))
  (define live-getnameinfo-req
    (foreign-procedure "chez_uv_live_getnameinfo_req" () long))

  (define count-read-buffer-new!
    (foreign-procedure "chez_uv_count_read_buffer_new" () void))
  (define count-read-buffer-free!
    (foreign-procedure "chez_uv_count_read_buffer_free" () void))
  (define live-read-buffer
    (foreign-procedure "chez_uv_live_read_buffer" () long))

  (define count-pipe-new!  (foreign-procedure "chez_uv_count_pipe_new" () void))
  (define count-pipe-free! (foreign-procedure "chez_uv_count_pipe_free" () void))
  (define live-pipe        (foreign-procedure "chez_uv_live_pipe" () long))

  (define count-process-new!
    (foreign-procedure "chez_uv_count_process_new" () void))
  (define count-process-free!
    (foreign-procedure "chez_uv_count_process_free" () void))
  (define live-process (foreign-procedure "chez_uv_live_process" () long))

  (define count-spawn-options-new!
    (foreign-procedure "chez_uv_count_spawn_options_new" () void))
  (define count-spawn-options-free!
    (foreign-procedure "chez_uv_count_spawn_options_free" () void))
  (define live-spawn-options
    (foreign-procedure "chez_uv_live_spawn_options" () long))

  (define count-signal-new!
    (foreign-procedure "chez_uv_count_signal_new" () void))
  (define count-signal-free!
    (foreign-procedure "chez_uv_count_signal_free" () void))
  (define live-signal (foreign-procedure "chez_uv_live_signal" () long))

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

  ;; --- the timer and close entry points (design spec S5) ----------------
  ;; Every pointer is `uptr` (design spec S4 rule 4), including the two
  ;; CALLBACK pointers -- uv_timer_start's uv_timer_cb and uv_close's
  ;; uv_close_cb -- which is why these two are bound with a `raw-` prefix
  ;; and reached only through the wrappers further down: those supply the
  ;; entry point, so no caller outside this file ever holds one.
  ;;
  ;; The two timeouts are `unsigned-64` because libuv declares them
  ;; uint64_t: milliseconds since the loop's now, unsigned, and wide enough
  ;; that binding them `long` would be a silent narrowing on an ILP32 host.
  ;;
  ;; uv_timer_init/start/stop/again return errnos, so they go through
  ;; uv-check at the call site; uv_timer_set_repeat and uv_close return
  ;; void, and uv_is_closing returns a C boolean that is NOT an errno --
  ;; routing that one through uv-check would make "yes, it is closing"
  ;; (which is 1) raise.
  (define uv-timer-init
    (foreign-procedure "uv_timer_init" (uptr uptr) int))
  (define raw-timer-start
    (foreign-procedure "uv_timer_start" (uptr uptr unsigned-64 unsigned-64) int))
  (define uv-timer-stop
    (foreign-procedure "uv_timer_stop" (uptr) int))
  (define uv-timer-again
    (foreign-procedure "uv_timer_again" (uptr) int))
  (define uv-timer-set-repeat
    (foreign-procedure "uv_timer_set_repeat" (uptr unsigned-64) void))
  (define uv-timer-get-repeat
    (foreign-procedure "uv_timer_get_repeat" (uptr) unsigned-64))
  (define raw-close
    (foreign-procedure "uv_close" (uptr uptr) void))
  (define uv-is-closing
    (foreign-procedure "uv_is_closing" (uptr) int))

  ;; --- the TCP and stream entry points (design spec S5, S7) -------------
  ;; Every pointer is `uptr` (design spec S4 rule 4). The three scalar
  ;; parameters mirror libuv's own declarations rather than being widened or
  ;; narrowed here: uv_tcp_bind's `flags` and uv_write's `nbufs` are
  ;; `unsigned int`, uv_listen's `backlog` and uv_tcp_nodelay's `enable` are
  ;; `int`. `unsigned-int` is what spike/03-buf-loopback.ss bound and drove a
  ;; real loopback write through.
  ;;
  ;; uv_ip4_addr / uv_ip6_addr take a `const char *` that they parse and
  ;; discard before returning, so `string` is safe here specifically: Chez's
  ;; marshalled copy lives for the duration of the call, and libuv writes the
  ;; PARSED result into the caller's sockaddr rather than retaining the text
  ;; (ADR-0009's "bytevectors cross the FFI only as arguments to synchronous
  ;; calls that complete before the call returns", applied to a string).
  ;;
  ;; All of these return errnos and go through uv-check at the call site.
  (define uv-tcp-init
    (foreign-procedure "uv_tcp_init" (uptr uptr) int))
  (define uv-tcp-bind
    (foreign-procedure "uv_tcp_bind" (uptr uptr unsigned-int) int))
  (define uv-tcp-getsockname
    (foreign-procedure "uv_tcp_getsockname" (uptr uptr uptr) int))
  (define uv-tcp-nodelay
    (foreign-procedure "uv_tcp_nodelay" (uptr int) int))
  (define uv-accept
    (foreign-procedure "uv_accept" (uptr uptr) int))
  (define uv-ip4-addr
    (foreign-procedure "uv_ip4_addr" (string int uptr) int))
  (define uv-ip6-addr
    (foreign-procedure "uv_ip6_addr" (string int uptr) int))

  (define raw-listen
    (foreign-procedure "uv_listen" (uptr int uptr) int))
  (define raw-tcp-connect
    (foreign-procedure "uv_tcp_connect" (uptr uptr uptr uptr) int))
  (define raw-write
    (foreign-procedure "uv_write" (uptr uptr uptr unsigned-int uptr) int))
  (define raw-shutdown
    (foreign-procedure "uv_shutdown" (uptr uptr uptr) int))

  ;; uv_read_start takes TWO callback pointers (uv_alloc_cb, uv_read_cb) and
  ;; is the only entry point here that does. uv_read_stop takes none, so it
  ;; needs no wrapper and is exported as it is; it returns 0 even when the
  ;; stream was not reading, which is what makes uv-read-stop! idempotent.
  (define raw-read-start
    (foreign-procedure "uv_read_start" (uptr uptr uptr) int))
  (define uv-read-stop
    (foreign-procedure "uv_read_stop" (uptr) int))

  ;; --- the DNS entry points (design spec v0.2 S5.1) ---------------------
  ;; Every pointer is `uptr` (design spec S4 rule 4), including the two
  ;; CALLBACK pointers -- uv_getaddrinfo's uv_getaddrinfo_cb and
  ;; uv_getnameinfo's uv_getnameinfo_cb -- which is why those two are bound
  ;; with a `raw-` prefix and reached only through the wrappers further
  ;; down, exactly like uv_timer_start and uv_tcp_connect.
  ;;
  ;; uv_getaddrinfo's node and service are `const char *` that libuv memcpys
  ;; into one req-owned block BEFORE returning, and frees itself
  ;; (vendor/libuv/src/unix/getaddrinfo.c:174-208 copies, :114-126 frees).
  ;; So `string` is safe here specifically: Chez's marshalled copy lives for
  ;; the duration of the call, and libuv retains its own copy rather than
  ;; the text -- the same reasoning as uv_ip4_addr above, extended across
  ;; the request's threadpool flight by libuv's own copy. Chez marshals #f
  ;; as NULL, which uv_getaddrinfo permits for either argument (not both).
  (define raw-getaddrinfo
    (foreign-procedure "uv_getaddrinfo"
                       (uptr uptr uptr string string uptr) int))

  ;; uv_getnameinfo memcpys the caller's sockaddr into req->storage before
  ;; returning (vendor/libuv/src/unix/getnameinfo.c:89-99), so the addr
  ;; argument is scratch the caller may free as soon as the call returns.
  (define raw-getnameinfo
    (foreign-procedure "uv_getnameinfo" (uptr uptr uptr uptr int) int))

  ;; uv_cancel: 0 only while the work is still queued -- the callback STILL
  ;; fires, with UV_ECANCELED rewritten to UV_EAI_CANCELED for both DNS req
  ;; kinds; running or completed work answers UV_EBUSY (uv__work_cancel,
  ;; vendor/libuv/src/threadpool.c:292-307 -- uv_cancel itself, :399-429,
  ;; only maps req->type to its work item and delegates there, answering
  ;; UV_EINVAL for non-threadpool req kinds); exactly one callback in every
  ;; outcome (vendor/libuv/src/unix/getaddrinfo.c:128-133). The int is an
  ;; errno, but a nonzero here is an ANSWER, not a failure: which codes matter is
  ;; cancellation policy, and policy lives with the callers (design spec
  ;; v0.2 S5.3), so this is exported raw and never routed through uv-check
  ;; unconditionally.
  (define uv-cancel (foreign-procedure "uv_cancel" (uptr) int))

  ;; Legal ONLY on a getaddrinfo-owned chain. `res` is NULL on every
  ;; getaddrinfo failure and cancellation, and uv_freeaddrinfo(NULL) is a
  ;; no-op, so an unconditional free in the getaddrinfo dispatcher is
  ;; correct on every path (vendor/libuv/src/unix/getaddrinfo.c:188,
  ;; :225-228). Synthetic test chains are foreign-alloc'd and freed with
  ;; free!, never with this.
  (define uv-freeaddrinfo
    (foreign-procedure "uv_freeaddrinfo" (uptr) void))

  ;; NOT exported raw: uv_ip_name dereferences sa_family through its pointer
  ;; unconditionally (vendor/libuv/src/uv-common.c:311), so the exported
  ;; face is the zero-refusing wrapper sockaddr->address-string below. In
  ;; libuv since 1.43, below this binding's declared floor of 1.44.0
  ;; (vendor/libuv/src/uv-common.c:305-321; Makefile:57-59). It does not
  ;; render IPv6 scope IDs.
  (define raw-ip-name
    (foreign-procedure "uv_ip_name" (uptr u8* size_t) int))

  ;; (sockaddr->address-string addr) -> string | #f
  ;;
  ;; The uv_strerror_r caller-buffer pattern (see scratch-size below): a
  ;; FRESH scratch bytevector per call, because this runs inside completion
  ;; dispatchers and a shared buffer would be a re-entrancy bug that only
  ;; shows up under load. 64 bytes: INET6_ADDRSTRLEN is 46, and scratch
  ;; sizes are not protocol constants (design spec v0.2 S5.1), so this is a
  ;; local margin rather than a shim lookup.
  ;;
  ;; A ZERO pointer answers #f WITHOUT calling native -- see the uv_ip_name
  ;; note above. That refusal is what lets synthetic addrinfo chains carry
  ;; NULL ai_addr safely, and what makes the ai_addr/ai_canonname
  ;; offset-swap mutation fail BY NAME instead of by SIGSEGV (design spec
  ;; v0.2 S9). A nonzero rc -- an address family uv_ip_name does not render
  ;; -- is also #f: "this sockaddr has no text" is an answer, not an error.
  (define address-scratch-size 64)

  (define (sockaddr->address-string addr)
    (if (zero? addr)
        #f
        (let ((bv (make-bytevector address-scratch-size 0)))
          (if (zero? (raw-ip-name addr bv address-scratch-size))
              (scratch->string bv address-scratch-size)
              #f))))

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

  ;; DELIBERATELY UNVALIDATED, unlike copy-in!/copy-out/zero-out! next door,
  ;; and that is load-bearing rather than an omission: it is what makes
  ;; alloc-dispatch (src/libuv/private/handles.sls, see its "THIS DISPATCHER
  ;; IS INFALLIBLE" note at handles.sls:626) unable to raise. libuv has no
  ;; error path for an alloc_cb that fails to answer, so a check added here
  ;; would turn a bad argument into a raise on the one call site that must
  ;; not have one.
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
    ;; integer? FIRST, exact? second -- the same safe order as zero-out!'s
    ;; checks above: integer? is total, while exact? on a non-number raises
    ;; a bare Chez &assertion, which would replace this structured rejection
    ;; with an undiscriminable crash (tests/test-native.sps's non-numeric
    ;; span rows).
    (unless (and (integer? start) (exact? start) (>= start 0)
                 (integer? len) (exact? len) (>= len 0)
                 (<= (+ start len) (bytevector-length bv)))
      (raise (make-uv-invalid-argument 'uv-copy-in! 'span-out-of-range)))
    (let loop ((i 0))
      (when (< i len)
        (foreign-set! 'unsigned-8 dst i (bytevector-u8-ref bv (+ start i)))
        (loop (+ i 1)))))

  ;; --- the C `int` out-parameter (uv_tcp_getsockname's namelen) ---------
  ;; The width comes from the C ABI (foreign-sizeof), never from a literal 4:
  ;; this is the same reasoning as lookup-constant's `long` out-parameter
  ;; below, and it is what keeps the caller in (libuv tcp) from having to
  ;; know anything about the platform's int.
  (define (c-int-size) (foreign-sizeof 'int))

  (define (c-int-ref addr)
    (unless (and (integer? addr) (exact? addr) (positive? addr))
      (raise (make-uv-invalid-argument 'uv-c-int-ref 'null-or-invalid-source)))
    (foreign-ref 'int addr 0))

  ;; The pointer-wide sibling of c-int-ref, with the same validation shape.
  ;; It exists for the addrinfo chain walk (design spec v0.2 S5.1): ai_next,
  ;; ai_addr, and ai_canonname are pointer fields read at shim-reported
  ;; offsets, and only this library may call foreign-ref -- so the reader
  ;; has to live here, not beside the walk.
  (define (c-uptr-ref addr)
    (unless (and (integer? addr) (exact? addr) (positive? addr))
      (raise (make-uv-invalid-argument 'uv-c-uptr-ref 'null-or-invalid-source)))
    (foreign-ref 'uptr addr 0))

  (define (c-int-set! addr value)
    (unless (and (integer? addr) (exact? addr) (positive? addr))
      (raise (make-uv-invalid-argument 'uv-c-int-set! 'null-or-invalid-destination)))
    (unless (and (integer? value) (exact? value))
      (raise (make-uv-invalid-argument 'uv-c-int-set! 'value-not-an-exact-integer)))
    (foreign-set! 'int addr 0 value))

  ;; The pointer-wide sibling of c-int-set!, with the same validation shape.
  ;; Needed for the process/pipe co-allocation (design spec S5.5): argv/env
  ;; pointer arrays and the internal pointers a spawn options block fixes up
  ;; are all uptr-width, not int-width.
  (define (c-uptr-size) (foreign-sizeof 'uptr))

  (define (c-uptr-set! addr value)
    (unless (and (integer? addr) (exact? addr) (positive? addr))
      (raise (make-uv-invalid-argument 'uv-c-uptr-set! 'null-or-invalid-destination)))
    (unless (and (integer? value) (exact? value) (>= value 0))
      (raise (make-uv-invalid-argument 'uv-c-uptr-set! 'value-not-a-pointer)))
    (foreign-set! 'uptr addr 0 value))

  ;; uid/gid are unsigned 32-bit (design spec S4.2); `foreign-set! 'int`
  ;; rejects any value >= 2^31, which a large uid/gid legitimately is.
  (define (c-u32-set! addr value)
    (unless (and (integer? addr) (exact? addr) (positive? addr))
      (raise (make-uv-invalid-argument 'uv-c-u32-set! 'null-or-invalid-destination)))
    (unless (and (integer? value) (exact? value) (>= value 0)
                 (< value 4294967296))
      (raise (make-uv-invalid-argument 'uv-c-u32-set! 'value-out-of-range)))
    (foreign-set! 'unsigned-32 addr 0 value))

  ;; ntohs, by hand, over two unsigned bytes. `sin_port` is stored in NETWORK
  ;; byte order (big-endian) whatever the host's order is, so reading it as a
  ;; host `unsigned-16` would answer a byte-swapped number on every
  ;; little-endian target -- plausible, in range, and wrong (spike FINDINGS
  ;; Q3, which did exactly this by hand and needed no htons/ntohs binding).
  ;;
  ;; Two unsigned-8 reads rather than one unsigned-16 plus a swap: this way
  ;; the code has no host-order branch to get backwards, and it is identical
  ;; on a big-endian host.
  (define (read-net-u16 addr offset)
    (unless (and (integer? addr) (exact? addr) (positive? addr))
      (raise (make-uv-invalid-argument 'uv-read-net-u16 'null-or-invalid-source)))
    (unless (and (integer? offset) (exact? offset) (>= offset 0))
      (raise (make-uv-invalid-argument 'uv-read-net-u16 'offset-out-of-range)))
    (+ (* 256 (foreign-ref 'unsigned-8 addr offset))
       (foreign-ref 'unsigned-8 addr (+ offset 1))))

  (define (copy-out src len)
    (unless (and (integer? src) (exact? src) (positive? src))
      (raise (make-uv-invalid-argument 'uv-copy-out 'null-or-invalid-source)))
    ;; integer? before exact?, for the same reason as copy-in!'s span check.
    (unless (and (integer? len) (exact? len) (>= len 0))
      (raise (make-uv-invalid-argument 'uv-copy-out 'length-out-of-range)))
    (let ((bv (make-bytevector len)))
      (let loop ((i 0))
        (if (= i len)
            bv
            (begin
              (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 src i))
              (loop (+ i 1)))))))

  ;; --- helpers lifted from (libuv tcp) (design spec v0.2 S5.1) ----------
  ;; Boundary-writing mechanics and allocation-layout arithmetic, shared by
  ;; tcp.sls and (v0.2 Stage 4) dns.sls. Neither carries dispatch policy, so
  ;; this file's mechanical/policy-free review property (ADR-0008) survives
  ;; the lift; both arrived with their validation intact.
  ;;
  ;; Filling a sockaddr (spike FINDINGS Q3): IPv4 first, IPv6 second, and a
  ;; failure of both is a CALLER error rather than an errno: uv_ip4_addr's
  ;; UV_EINVAL says "this text is not a dotted quad", which is only
  ;; interesting once the IPv6 reading has also been refused. Reporting the
  ;; first attempt's errno would name a family the caller never mentioned.
  ;;
  ;; The scratch is written in place; the caller owns it and frees it.
  (define (fill-sockaddr! addr ip port who)
    (unless (or (zero? (uv-ip4-addr ip port addr))
                (zero? (uv-ip6-addr ip port addr)))
      (raise (make-uv-invalid-argument who 'bad-address))))

  ;; Round up to a 16-byte boundary. The uv_buf_t and sockaddr_storage that
  ;; follow a request inside its block contain pointers and (on some
  ;; targets) 16-byte-aligned members, and uv_req_size answers the request's
  ;; size, not a padded stride -- so the offset is aligned here rather than
  ;; assumed. 16 rather than 8: it is the strictest fundamental alignment on
  ;; every target this binding supports, so one rule covers both structs.
  (define (align-16 n) (* 16 (div (+ n 15) 16)))

  ;; require-address / require-port followed post-v0.2 (the whole-branch
  ;; review's duplication finding): ADR-0012's input vocabulary, restated
  ;; verbatim in tcp.sls and dns.sls through v0.2, now one copy beside the
  ;; fill-sockaddr! both feed. Address-ness here is string?-ness only --
  ;; parse refusal is fill-sockaddr!'s job (spike FINDINGS Q3), which is
  ;; why an unparseable string passes this gate.
  (define (require-address ip who)
    (unless (string? ip)
      (raise (make-uv-invalid-argument who 'address-not-a-string))))

  ;; A port as libuv takes it: an exact integer in 0..65535, where 0 means
  ;; "let the kernel choose" for bind. Checked explicitly because the FFI
  ;; declares `int`, so a bignum or an inexact number is either a Chez
  ;; marshalling error from deep inside the call or a silently truncated
  ;; port number.
  (define (require-port port who)
    (unless (and (integer? port) (exact? port) (>= port 0) (<= port 65535))
      (raise (make-uv-invalid-argument who 'port-out-of-range))))

  ;; Lifted verbatim from tcp.sls:56-58 (the PR #4 shared-validator rule):
  ;; tcp.sls and stream.sls/process.sls all need the same "is this an
  ;; on-callback argument a real procedure" gate. tcp.sls keeps its own
  ;; private copy until Task 7 moves the verbs that use it; the two copies
  ;; coexist harmlessly until then because tcp.sls does not import this
  ;; export.
  (define (require-callback proc who reason)
    (unless (procedure? proc)
      (raise (make-uv-invalid-argument who reason))))

  ;; --- error translation (ADR-0006) -------------------------------------
  ;; Both _r calls get a FRESH scratch bytevector rather than sharing one:
  ;; uv-check is reachable from inside a callback (design spec S8), and a
  ;; shared buffer would be a re-entrancy bug that only shows up under load.
  ;; 256 bytes is comfortably above libuv's longest strerror text; the call
  ;; truncates rather than overruns either way, since the length is passed.
  (define scratch-size 256)

  ;; The NUL-terminated prefix of a scratch bytevector, as a fresh Scheme
  ;; string. Shared by r-call and sockaddr->address-string -- factored
  ;; rather than duplicated so the two scans can never disagree about what
  ;; "the written prefix" means (the uv-check/uv-errno-condition reasoning).
  (define (scratch->string bv limit)
    (let scan ((i 0))
      (if (or (= i limit) (zero? (bytevector-u8-ref bv i)))
          (let ((out (make-bytevector i)))
            (bytevector-copy! bv 0 out 0 i)
            (utf8->string out))
          (scan (+ i 1)))))

  (define (r-call proc code)
    (let ((bv (make-bytevector scratch-size 0)))
      (proc code bv scratch-size)
      (scratch->string bv scratch-size)))

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
    (if (zero? rc) rc (raise (uv-errno-condition rc who))))

  ;; The same object, BUILT rather than raised. Design spec S9: "these are
  ;; the same condition record types delivered as plain objects to
  ;; asynchronous callbacks (on-error, on-complete's err argument) and raised
  ;; synchronously from procedures that fail immediately." A callback's
  ;; status int is not an exception -- raising it would unwind into libuv
  ;; (ADR-0008) -- so the dispatchers in (libuv private handles) call this
  ;; and pass the result along as a value.
  ;;
  ;; Factored out of uv-check rather than duplicated so the two can never
  ;; describe the same errno differently.
  (define (uv-errno-condition rc who)
    (let ((message (errno->message rc)))
      (condition
       (make-uv-errno-error (errno-value->symbol rc) rc message)
       (make-who-condition who)
       (make-message-condition message))))

  (define (live-counts)
    (list (cons 'loop        (live-loop))
          (cons 'tcp         (live-tcp))
          (cons 'timer       (live-timer))
          (cons 'write-req   (live-write-req))
          (cons 'connect-req (live-connect-req))
          (cons 'getaddrinfo-req (live-getaddrinfo-req))
          (cons 'getnameinfo-req (live-getnameinfo-req))
          (cons 'read-buffer (live-read-buffer))
          (cons 'pipe          (live-pipe))
          (cons 'process       (live-process))
          (cons 'spawn-options (live-spawn-options))
          (cons 'signal        (live-signal))))

  ;; --- callback dispatcher slots (ADR-0008, design spec S4) -------------
  ;; The twelve trampolines declared below as `foreign-callable`s have
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
  ;; APPEND-ONLY, and the order is part of the contract: the two literal
  ;; rows in tests/test-loop.sps and tests/test-native.sps freeze exactly
  ;; this list (ADR-0008 as amended 2026-08-21 -- one locked trampoline per
  ;; callback TYPE, a constant small set per process; the set moves only
  ;; when libuv's callback typology does, never with handle or request
  ;; volume).
  (define dispatcher-names
    '(alloc read connection write-done close timer shutdown connect
      getaddrinfo getnameinfo exit walk signal))

  (define dispatchers (make-eq-hashtable))
  (define dispatchers-installed #f)

  (define (dispatchers-installed?) dispatchers-installed)

  ;; The uninstalled stub. It raises rather than returning a harmless value
  ;; because a callback firing before its policy exists means libuv is
  ;; already holding a pointer to a trampoline this binding cannot service --
  ;; there is no state in which quietly doing nothing is right. Raising from
  ;; inside a C frame is survivable exactly once, at development time; see
  ;; ADR-0008 on why the real dispatchers guard their bodies instead.
  ;;
  ;; In a process that has instantiated (libuv private handles) this stub is
  ;; unreachable FROM C, and structurally so: a trampoline's entry point
  ;; reaches libuv only through uv-timer-start-native / uv-close-native, both
  ;; of which are called from handles.sls or from a library that imports it,
  ;; and instantiating handles.sls is what fills these slots. It can still be
  ;; reached by calling `dispatcher-ref` directly from Scheme, which is how
  ;; tests/test-native.sps asserts it (that suite never imports handles.sls,
  ;; so its slots stay empty for the life of the process).
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
  ;;
  ;; The per-fire hashtable lookup was measured against a vector-slot
  ;; replacement and kept: it costs ~6 ns of a >=26 microsecond fire, ~0.02%
  ;; of the cheapest callback path this binding can execute
  ;; (.plans/2026-08-18-dispatch-benchmark.md).
  (define (dispatcher-ref name)
    (let ((proc (hashtable-ref dispatchers name #f)))
      (or proc
          (raise (make-uv-invalid-argument 'uv-dispatcher-ref
                                           'unknown-dispatcher)))))

  ;; alist: (name . procedure) for all twelve names, in any order.
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

  ;; --- the twelve static trampolines (ADR-0008, design spec S4/S10) -----
  ;; ONE `foreign-callable` per callback TYPE, never per callback instance,
  ;; each `lock-object`'d exactly once here and never unlocked, for the life
  ;; of the process. That bound is the whole point of ADR-0008: libuv retains
  ;; a callback pointer for the entire life of a handle, and a lock per
  ;; handle or per request would leave the collector permanently unable to
  ;; move an ever-growing set of code objects -- a leak by another name.
  ;;
  ;; ALL TWELVE ARE CREATED HERE, together -- the original eight in v0.1
  ;; Stage 3, the two DNS trampolines in v0.2 Stage 2 (ADR-0008 as amended:
  ;; neither DNS callback typedef matches an existing trampoline's arity,
  ;; vendor/libuv/include/uv.h:345-352), and `exit`/`walk` in v0.3 (ADR-0015:
  ;; `walk` is ADR-0015's spawn-failure-path discriminator, `uv_walk_cb`
  ;; matches no existing arity either) -- even when a callback type cannot
  ;; fire yet. Creating them together is what keeps `lock-object` in exactly
  ;; one place, evaluated once; the stages add dispatch policy behind the
  ;; slots, not new locked objects. Spike FINDINGS Q1 measured the property
  ;; this depends on: a locked callable's `foreign-callable-entry-point` was
  ;; identical before and after both a default `(collect)` and a
  ;; maximum-generation collection.
  ;;
  ;; Each body is mechanical and carries NO policy: look up the slot by name
  ;; at FIRE time and call it. The lookup is deliberately not hoisted out of
  ;; the lambda -- the install happens after this library's body has finished
  ;; running, so a trampoline that captured its slot's value at declaration
  ;; time would capture the raising stub forever.
  ;;
  ;; Signatures are libuv's own (vendor/libuv/include/uv.h, lines 323-335),
  ;; and `nread` is `ssize_t`: spike Q3 confirmed it is a native Chez foreign
  ;; type AND that binding it unsigned routes UV_EOF into the data path as
  ;; 2^64 - 4095 (design spec S4 rule 4).
  (define alloc-callable
    (foreign-callable (lambda (handle suggested buf)
                        ((dispatcher-ref 'alloc) handle suggested buf))
                      (uptr size_t uptr) void))

  (define read-callable
    (foreign-callable (lambda (stream nread buf)
                        ((dispatcher-ref 'read) stream nread buf))
                      (uptr ssize_t uptr) void))

  (define connection-callable
    (foreign-callable (lambda (server status)
                        ((dispatcher-ref 'connection) server status))
                      (uptr int) void))

  (define write-done-callable
    (foreign-callable (lambda (req status)
                        ((dispatcher-ref 'write-done) req status))
                      (uptr int) void))

  (define close-callable
    (foreign-callable (lambda (handle) ((dispatcher-ref 'close) handle))
                      (uptr) void))

  (define timer-callable
    (foreign-callable (lambda (handle) ((dispatcher-ref 'timer) handle))
                      (uptr) void))

  (define shutdown-callable
    (foreign-callable (lambda (req status)
                        ((dispatcher-ref 'shutdown) req status))
                      (uptr int) void))

  (define connect-callable
    (foreign-callable (lambda (req status)
                        ((dispatcher-ref 'connect) req status))
                      (uptr int) void))

  ;; The two DNS completion signatures (vendor/libuv/include/uv.h:345-352):
  ;; uv_getaddrinfo_cb is (uv_getaddrinfo_t*, int, struct addrinfo*),
  ;; uv_getnameinfo_cb is (uv_getnameinfo_t*, int, const char*, const
  ;; char*). Neither matches any of the eight arities above, which is why
  ;; these exist (ADR-0008 as amended). The two borrowed `const char *`s
  ;; arrive as uptr, never `string`: they point INTO the request's own block
  ;; and are NULL on every failure (vendor/libuv/include/uv/unix.h:353-354),
  ;; so the copy-or-#f decision belongs to the installed dispatcher, one
  ;; step later.
  (define getaddrinfo-callable
    (foreign-callable (lambda (req status res)
                        ((dispatcher-ref 'getaddrinfo) req status res))
                      (uptr int uptr) void))

  (define getnameinfo-callable
    (foreign-callable (lambda (req status hostname service)
                        ((dispatcher-ref 'getnameinfo)
                         req status hostname service))
                      (uptr int uptr uptr) void))

  ;; uv_exit_cb: void (*)(uv_process_t*, int64_t exit_status, int
  ;; term_signal) (vendor/libuv/include/uv.h:340) -- a foreign type
  ;; signature no other trampoline has (ADR-0008, v0.3 amendment).
  (define exit-callable
    (foreign-callable (lambda (handle exit-status term-signal)
                        ((dispatcher-ref 'exit) handle exit-status term-signal))
                      (uptr integer-64 int) void))

  ;; uv_walk_cb: void (*)(uv_handle_t*, void* arg) (vendor/libuv/include/
  ;; uv.h:341). SYNCHRONOUS: fires only inside a uv_walk call on the
  ;; caller's own thread, never from uv_run -- locked with the others
  ;; because libuv still calls it by address (ADR-0008, v0.3 amendment).
  (define walk-callable
    (foreign-callable (lambda (handle arg)
                        ((dispatcher-ref 'walk) handle arg))
                      (uptr uptr) void))

  ;; uv_signal_cb: void (*)(uv_signal_t*, int signum). It SHARES
  ;; connection's (uptr int) arity and still gets its own locked trampoline:
  ;; the rule is one per callback TYPE, not per arity (ADR-0008, third
  ;; amendment -- the original eight already contain same-arity
  ;; distinct-type pairs: timer and close are both (uptr) -> void).
  (define signal-callable
    (foreign-callable (lambda (handle signum)
                        ((dispatcher-ref 'signal) handle signum))
                      (uptr int) void))

  ;; void uv_walk(uv_loop_t*, uv_walk_cb, void* arg) -- no errno.
  (define raw-walk
    (foreign-procedure "uv_walk" (uptr uptr uptr) void))

  ;; (uv-walk-native loop-ptr arg) -- bakes in the walk trampoline; the
  ;; installed walk dispatcher (handles.sls) interprets arg. walk-cb-entry
  ;; is defined further down, beside the other entry points; referencing it
  ;; here is a forward reference inside a lambda body that is not invoked
  ;; until well after this library's definitions have all run, same as
  ;; every other *-native wrapper in this file.
  (define (uv-walk-native loop-ptr arg)
    (raw-walk loop-ptr walk-cb-entry arg))

  ;; A definition, not a bare expression, for the same reason as `uv-loaded`
  ;; and `dispatchers-seeded` above: R6RS library bodies take all their
  ;; definitions before any expression, and every lock has to be in place
  ;; before an entry point below is read.
  (define trampolines-locked
    (for-each lock-object
              (list alloc-callable read-callable connection-callable
                    write-done-callable close-callable timer-callable
                    shutdown-callable connect-callable
                    getaddrinfo-callable getnameinfo-callable
                    exit-callable walk-callable signal-callable)))

  ;; The entry points are module-private ON PURPOSE (design spec S3: nothing
  ;; outside private/ sees a pointer -- and these are the pointers whose
  ;; misuse is least recoverable, since libuv would call a C address with the
  ;; wrong argument shape). They leave this file only baked into the two
  ;; wrappers below.
  (define close-cb-entry      (foreign-callable-entry-point close-callable))
  (define timer-cb-entry      (foreign-callable-entry-point timer-callable))
  (define connection-cb-entry (foreign-callable-entry-point connection-callable))
  (define write-cb-entry      (foreign-callable-entry-point write-done-callable))
  (define connect-cb-entry    (foreign-callable-entry-point connect-callable))
  (define shutdown-cb-entry   (foreign-callable-entry-point shutdown-callable))
  (define alloc-cb-entry      (foreign-callable-entry-point alloc-callable))
  (define read-cb-entry       (foreign-callable-entry-point read-callable))
  (define getaddrinfo-cb-entry
    (foreign-callable-entry-point getaddrinfo-callable))
  (define getnameinfo-cb-entry
    (foreign-callable-entry-point getnameinfo-callable))
  (define exit-cb-entry (foreign-callable-entry-point exit-callable))
  (define walk-cb-entry (foreign-callable-entry-point walk-callable))
  (define signal-cb-entry (foreign-callable-entry-point signal-callable))

  ;; (uv-timer-start-native timer-ptr timeout repeat) -> int (an errno).
  (define (uv-timer-start-native timer-ptr timeout repeat)
    (raw-timer-start timer-ptr timer-cb-entry timeout repeat))

  ;; (uv-close-native handle-ptr) -> void. uv_close only STARTS the close;
  ;; the close trampoline fires from inside a later uv_run iteration, which
  ;; is where the pointer is actually freed (design spec S5).
  (define (uv-close-native handle-ptr)
    (raw-close handle-ptr close-cb-entry))

  ;; The four stream wrappers, each baking in ITS OWN trampoline. Getting one
  ;; of these pairings wrong is not a type error in any language involved --
  ;; every entry point is a bare address and every one of these callbacks
  ;; takes (uptr int) except close's -- so it would be libuv calling the
  ;; wrong dispatcher with a plausible argument shape. The pairing is
  ;; therefore asserted end to end by tests/test-tcp.sps, where a connection
  ;; that arrived through the write-done dispatcher (or vice versa) shows up
  ;; as a callback that never fires and a request that is never freed.
  ;;
  ;; (uv-listen-native server-ptr backlog) -> int (an errno).
  (define (uv-listen-native server-ptr backlog)
    (raw-listen server-ptr backlog connection-cb-entry))

  ;; (uv-tcp-connect-native req-ptr handle-ptr addr-ptr) -> int (an errno).
  ;; addr-ptr is a `const struct sockaddr *`; libuv copies what it needs
  ;; before returning on every platform this build supports, but design spec
  ;; S7 has the caller co-allocate it with the request anyway, so the
  ;; question never has to be re-answered per platform.
  (define (uv-tcp-connect-native req-ptr handle-ptr addr-ptr)
    (raw-tcp-connect req-ptr handle-ptr addr-ptr connect-cb-entry))

  ;; (uv-write-native req-ptr stream-ptr bufs-ptr nbufs) -> int (an errno).
  ;; `bufs-ptr` points at an array of nbufs uv_buf_t; v0.1 always passes 1
  ;; (design spec S7 defers vectored writes to a reserved uv-write*!).
  (define (uv-write-native req-ptr stream-ptr bufs-ptr nbufs)
    (raw-write req-ptr stream-ptr bufs-ptr nbufs write-cb-entry))

  ;; (uv-shutdown-native req-ptr stream-ptr) -> int (an errno).
  (define (uv-shutdown-native req-ptr stream-ptr)
    (raw-shutdown req-ptr stream-ptr shutdown-cb-entry))

  ;; (uv-read-start-native stream-ptr) -> int (an errno).
  ;;
  ;; BOTH callbacks are baked in here, together, and that pairing is the whole
  ;; reason this wrapper exists: libuv calls alloc_cb and read_cb as a pair on
  ;; every read, and handing it the two entry points the other way round is
  ;; not a type error in any language involved -- it would be libuv writing a
  ;; buffer descriptor through what it believes is a read completion. The
  ;; pairing is asserted end to end by tests/test-tcp.sps, where a read that
  ;; arrived through the alloc dispatcher shows up as data that never
  ;; arrives.
  (define (uv-read-start-native stream-ptr)
    (raw-read-start stream-ptr alloc-cb-entry read-cb-entry))

  ;; The two DNS wrappers, each baking in ITS OWN trampoline, mirroring
  ;; uv-tcp-connect-native above: every entry point is a bare address, so a
  ;; cross-pairing here would be libuv calling the wrong dispatcher with a
  ;; plausible argument shape, not a type error in any language involved.
  ;;
  ;; (uv-getaddrinfo-native loop-ptr req-ptr node service hints-ptr) -> int
  ;; (an errno). node/service are Scheme strings or #f (marshalled NULL);
  ;; hints-ptr is a caller-owned struct addrinfo, or 0 for no hints.
  (define (uv-getaddrinfo-native loop-ptr req-ptr node service hints-ptr)
    (raw-getaddrinfo loop-ptr req-ptr getaddrinfo-cb-entry
                     node service hints-ptr))

  ;; (uv-getnameinfo-native loop-ptr req-ptr addr-ptr flags) -> int (an
  ;; errno). addr-ptr is scratch: libuv copies the sockaddr into the
  ;; request's own storage before returning (see raw-getnameinfo above).
  (define (uv-getnameinfo-native loop-ptr req-ptr addr-ptr flags)
    (raw-getnameinfo loop-ptr req-ptr getnameinfo-cb-entry addr-ptr flags))

  ;; --- the process and pipe entry points (THE SPEC S5.2) -----------------
  ;; uv_spawn takes its callback INSIDE uv_process_options_t rather than as
  ;; an argument, so the wrapper writes the entry point into the caller's
  ;; options block at the shim-reported offset and then calls the raw
  ;; binding -- the same "entry points leave this file only baked into
  ;; wrappers" rule as uv-timer-start-native, adapted to a struct field.
  ;; NULL is never written: THE SPEC S4.1 -- on-exit = #f is resolved
  ;; Scheme-side by the dispatcher, so the lifecycle machinery always runs.
  (define raw-spawn
    (foreign-procedure "uv_spawn" (uptr uptr uptr) int))

  (define (uv-spawn-native loop-ptr handle-ptr options-ptr)
    (foreign-set! 'uptr options-ptr
                  (offsetof-uv-process-options-t-exit-cb) exit-cb-entry)
    (raw-spawn loop-ptr handle-ptr options-ptr))

  ;; No callback pointers in any of these, so they are exported raw; every
  ;; int is an errno except uv_process_get_pid's, which is the pid itself.
  (define uv-process-kill
    (foreign-procedure "uv_process_kill" (uptr int) int))
  (define uv-kill
    (foreign-procedure "uv_kill" (int int) int))
  (define uv-process-get-pid
    (foreign-procedure "uv_process_get_pid" (uptr) int))
  (define uv-pipe-init
    (foreign-procedure "uv_pipe_init" (uptr uptr int) int))

  ;; --- the signal entry points (design spec 2026-08-22 §5.2, ADR-0017) ---
  ;; uv_signal_start AND uv_signal_start_oneshot both take a uv_signal_cb,
  ;; so both are bound raw- and reached only through the wrappers below,
  ;; which bake in the ONE signal trampoline -- two verbs, one callback
  ;; TYPE (ADR-0008 third amendment). uv_signal_init and uv_signal_stop
  ;; take no callback and are exported raw; every int is an errno
  ;; (uv_signal_stop is rc 0 even on a never-started watcher, EV-2).
  (define uv-signal-init
    (foreign-procedure "uv_signal_init" (uptr uptr) int))
  (define raw-signal-start
    (foreign-procedure "uv_signal_start" (uptr uptr int) int))
  (define raw-signal-start-oneshot
    (foreign-procedure "uv_signal_start_oneshot" (uptr uptr int) int))
  (define uv-signal-stop
    (foreign-procedure "uv_signal_stop" (uptr) int))

  (define (uv-signal-start-native handle-ptr signum)
    (raw-signal-start handle-ptr signal-cb-entry signum))

  (define (uv-signal-start-oneshot-native handle-ptr signum)
    (raw-signal-start-oneshot handle-ptr signal-cb-entry signum))

  ;; uv_os_getpid: this process's own pid. No errno, no callback; the
  ;; public gated spelling lives in (libuv process) beside uv-process-pid.
  (define uv-os-getpid-native
    (foreign-procedure "uv_os_getpid" () int))

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
