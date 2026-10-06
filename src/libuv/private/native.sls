#!r6rs
;;; Sole FFI layer. Shared objects must load before any foreign-procedure form
;;; is evaluated because Chez resolves symbols at definition time. Load libuv
;;; before the shim so uv_* symbols are globally available on Linux.
(library (libuv private native)
  (export ;; loading and the init gate
          ensure-native-loaded! native-init-count native-initialized?
          resolve-shim-path load-shim shim-file
          version-supported? version-compatible? check-version-compatible!

          ;; version
          shim-compiled-version uv-version uv-version-string

          ;; errors
          errno->symbol errno->message uv-check uv-errno-condition

          ;; foreign memory and copying
          c-string->string
          alloc-zeroed zero-out! free! copy-in! try-copy-in! copy-out
          alloc-block free-block! copy-in-unchecked!
          c-int-size c-int-ref c-int-set! c-uptr-ref read-net-u16
          c-uptr-size c-uptr-set! c-u32-set!

          ;; uv_buf_t
          uv-buf-set! uv-buf-base uv-buf-len uv-buf-ftype-layout

          ;; runtime sizes and loop entry points
          uv-loop-size uv-handle-size uv-req-size

          uv-loop-init uv-loop-run uv-loop-stop
          uv-loop-alive uv-loop-now uv-loop-update-time uv-loop-close

          ;; timers and close
          uv-timer-init uv-timer-start-native uv-timer-stop uv-timer-again
          uv-timer-set-repeat uv-timer-get-repeat
          uv-close-native uv-is-closing
          uv-send-buffer-size-native uv-recv-buffer-size-native

          ;; TCP and streams
          uv-tcp-init uv-tcp-bind uv-tcp-getsockname uv-tcp-getpeername-native
          uv-tcp-nodelay uv-tcp-keepalive
          uv-listen-native uv-accept uv-tcp-connect-native
          uv-write-native uv-shutdown-native
          uv-read-start-native uv-read-stop uv-handle-set-data alloc-cb-entry
          uv-stream-get-write-queue-size-native

          ;; DNS
          uv-getaddrinfo-native uv-getnameinfo-native
          uv-cancel uv-freeaddrinfo
          sockaddr->address-string

          ;; shared validators and boundary helpers
          fill-sockaddr! align-16
          validate-address require-port fold-flags
          require-callback
          signal-symbol->int term-signal->value

          ;; thread identity (per-loop affinity, #20)
          current-thread-id

          ;; callback dispatch
          dispatcher-names dispatcher-ref dispatchers-installed?
          install-callback-dispatchers!

          ;; processes and pipes
          uv-spawn-native
          uv-process-kill uv-kill uv-process-get-pid uv-pipe-init
          uv-walk-native

          ;; signals
          uv-signal-init uv-signal-start-native
          uv-signal-start-oneshot-native uv-signal-stop
          uv-os-getpid-native

          ;; async (#20)
          uv-async-init-native uv-async-send

          ;; debug counters
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
          count-signal-new!      count-signal-free!
          count-async-new!       count-async-free!)
  (import (rnrs)
          ;; Ahead of (chezscheme): make-mutex and with-mutex exist only in a
          ;; threaded Chez (#41; tests/test-require-threaded.sps).
          (libuv private require-threaded)
          (only (chezscheme)
                load-shared-object foreign-procedure foreign-entry? foreign-entry
                foreign-ref foreign-set!
                foreign-alloc foreign-free foreign-sizeof
                with-interrupts-disabled
                foreign-callable foreign-callable-entry-point lock-object
                define-ftype ftype-sizeof ftype-set! ftype-ref ftype-&ref
                make-ftype-pointer ftype-pointer-address
                file-regular? make-mutex with-mutex getenv
                get-thread-id)
          (libuv private config)
          (libuv private conditions)
          (libuv private constants)
          (only (libuv private c-string) c-string-bytes c-string?))

  ;; resolve-shim-path : string (or string #f) [procedure] -> string
  ;; Accept an absolute regular file only; never search the working directory.
  (define (regular-file? path)
    (and (file-exists? path) (file-regular? path)))

  (define (absolute-path? path)
    (and (string? path)
         (> (string-length path) 0)
         (char=? (string-ref path 0) #\/)))

  (define resolve-shim-path
    (case-lambda
      ((default-path override)
       (resolve-shim-path default-path override make-uv-shim-unavailable))
      ((default-path override make-unavailable)
       (let ((candidate (or override default-path)))
         (if (and (absolute-path? candidate) (regular-file? candidate))
             candidate
             (raise (make-unavailable candidate)))))))

  ;; load-shim : string [procedure] -> unspecified
  ;; Convert loader failures to the requested structured condition type.
  (define load-shim
    (case-lambda
      ((path) (load-shim path make-uv-shim-unavailable))
      ((path make-unavailable)
       (guard (e (#t (raise (make-unavailable path))))
         (load-shared-object path)))))

  (define resolved-shim-path
    (resolve-shim-path shim-path (getenv "CHEZ_LIBUV_SHIM")))

  (define (shim-file) resolved-shim-path)

  ;; Definitions preserve R6RS library ordering while forcing libuv to load
  ;; before the shim and every foreign binding below.
  (define uv-loaded
    (for-each (lambda (path)
                (load-shim (resolve-shim-path path #f make-uv-libuv-unavailable)
                           make-uv-libuv-unavailable))
              uv-library-paths))

  (define shim-loaded (load-shim resolved-shim-path))

  ;; shim-entry : string -> exact-integer
  ;; The address of an entry the shim exports, or &uv-shim-unavailable naming
  ;; the shim. A shim built from older sources loads cleanly but lacks newer
  ;; entries, and resolving one unchecked would fail the whole import with a
  ;; bare "no entry" assertion instead of the condition every other unusable
  ;; shim raises (test-shim-loading.sps). Every shim entry is resolved
  ;; through here (tests/test-source-rules.sps).
  (define (shim-entry entry)
    (if (foreign-entry? entry)
        (foreign-entry entry)
        (raise (make-uv-shim-unavailable resolved-shim-path))))

  ;; shim-procedure : like foreign-procedure, for an entry the shim exports,
  ;; resolved through shim-entry. foreign-procedure resolves an address
  ;; expression when the form is evaluated, as it does a name.
  (define-syntax shim-procedure
    (syntax-rules ()
      ((_ entry (arg ...) result)
       (foreign-procedure (shim-entry entry) (arg ...) result))))

  (define shim-compiled-version
    (shim-procedure "chez_uv_shim_compiled_version" () int))

  ;; chez_uv_constant writes a C long through an out-parameter.
  (define raw-constant
    (shim-procedure "chez_uv_constant" (string uptr) int))

  (define raw-errno-count (shim-procedure "chez_uv_errno_count" () int))
  (define raw-errno-name  (shim-procedure "chez_uv_errno_name" (int) uptr))
  (define raw-errno-value (shim-procedure "chez_uv_errno_value" (int) int))

  ;; Bulk byte moves (issue #35). Plain, not __collect_safe: a u8* argument
  ;; is the bytevector's own storage, and a plain call keeps this thread
  ;; active, so no collection can move that storage before the call returns
  ;; (test-threading-stress.sps pins this). The price is that other threads'
  ;; collections wait for the whole move (ADR-0009's #35 note).
  (define raw-copy-in
    (shim-procedure "chez_uv_copy_in" (uptr u8* size_t size_t) void))
  (define raw-copy-out
    (shim-procedure "chez_uv_copy_out" (u8* uptr size_t) void))
  (define raw-zero (shim-procedure "chez_uv_zero" (uptr size_t) void))

  ;; libuv's alloc callback for reads is the shim's own C function, not a
  ;; trampoline (#45; ADR-0002 and ADR-0008, amended 2026-10-05): its answer,
  ;; the stream's own read buffer, is fixed per handle and needs no Scheme.
  ;; uv-read-start-native hands libuv this address.
  (define alloc-cb-entry (shim-entry "chez_uv_alloc_cb"))

  ;; The binding's blocks come from the shim: zeroed, 0 when the allocator
  ;; refuses, and counted alive by the debug shim (live-counts' 'block).
  ;; foreign-alloc raises when malloc fails, so it cannot be used inside an
  ;; interrupt-free step; neither of these raises for arguments in range.
  (define raw-alloc (shim-procedure "chez_uv_alloc" (size_t) uptr))
  (define raw-free (shim-procedure "chez_uv_free" (uptr) void))
  (define live-block (shim-procedure "chez_uv_live_block" () long))

  ;; Counter symbols exist in every build; production implementations are no-ops.
  (define count-loop-new!  (shim-procedure "chez_uv_count_loop_new" () void))
  (define count-loop-free! (shim-procedure "chez_uv_count_loop_free" () void))
  (define live-loop        (shim-procedure "chez_uv_live_loop" () long))

  (define count-tcp-new!  (shim-procedure "chez_uv_count_tcp_new" () void))
  (define count-tcp-free! (shim-procedure "chez_uv_count_tcp_free" () void))
  (define live-tcp        (shim-procedure "chez_uv_live_tcp" () long))

  (define count-timer-new!  (shim-procedure "chez_uv_count_timer_new" () void))
  (define count-timer-free! (shim-procedure "chez_uv_count_timer_free" () void))
  (define live-timer        (shim-procedure "chez_uv_live_timer" () long))

  (define count-write-req-new!
    (shim-procedure "chez_uv_count_write_req_new" () void))
  (define count-write-req-free!
    (shim-procedure "chez_uv_count_write_req_free" () void))
  (define live-write-req (shim-procedure "chez_uv_live_write_req" () long))

  (define count-connect-req-new!
    (shim-procedure "chez_uv_count_connect_req_new" () void))
  (define count-connect-req-free!
    (shim-procedure "chez_uv_count_connect_req_free" () void))
  (define live-connect-req
    (shim-procedure "chez_uv_live_connect_req" () long))

  (define count-getaddrinfo-req-new!
    (shim-procedure "chez_uv_count_getaddrinfo_req_new" () void))
  (define count-getaddrinfo-req-free!
    (shim-procedure "chez_uv_count_getaddrinfo_req_free" () void))
  (define live-getaddrinfo-req
    (shim-procedure "chez_uv_live_getaddrinfo_req" () long))

  (define count-getnameinfo-req-new!
    (shim-procedure "chez_uv_count_getnameinfo_req_new" () void))
  (define count-getnameinfo-req-free!
    (shim-procedure "chez_uv_count_getnameinfo_req_free" () void))
  (define live-getnameinfo-req
    (shim-procedure "chez_uv_live_getnameinfo_req" () long))

  (define count-read-buffer-new!
    (shim-procedure "chez_uv_count_read_buffer_new" () void))
  (define count-read-buffer-free!
    (shim-procedure "chez_uv_count_read_buffer_free" () void))
  (define live-read-buffer
    (shim-procedure "chez_uv_live_read_buffer" () long))

  (define count-pipe-new!  (shim-procedure "chez_uv_count_pipe_new" () void))
  (define count-pipe-free! (shim-procedure "chez_uv_count_pipe_free" () void))
  (define live-pipe        (shim-procedure "chez_uv_live_pipe" () long))

  (define count-process-new!
    (shim-procedure "chez_uv_count_process_new" () void))
  (define count-process-free!
    (shim-procedure "chez_uv_count_process_free" () void))
  (define live-process (shim-procedure "chez_uv_live_process" () long))

  (define count-spawn-options-new!
    (shim-procedure "chez_uv_count_spawn_options_new" () void))
  (define count-spawn-options-free!
    (shim-procedure "chez_uv_count_spawn_options_free" () void))
  (define live-spawn-options
    (shim-procedure "chez_uv_live_spawn_options" () long))

  (define count-signal-new!
    (shim-procedure "chez_uv_count_signal_new" () void))
  (define count-signal-free!
    (shim-procedure "chez_uv_count_signal_free" () void))
  (define live-signal (shim-procedure "chez_uv_live_signal" () long))

  (define count-async-new!
    (shim-procedure "chez_uv_count_async_new" () void))
  (define count-async-free!
    (shim-procedure "chez_uv_count_async_free" () void))
  (define live-async (shim-procedure "chez_uv_live_async" () long))

  (define uv-version (foreign-procedure "uv_version" () int))

  ;; Borrowed strings cross as pointers and are copied immediately.
  (define raw-version-string
    (foreign-procedure "uv_version_string" () uptr))

  ;; Use caller-buffer _r forms; libuv's older static-buffer forms are unsafe
  ;; under concurrent or re-entrant calls.
  (define raw-strerror-r
    (foreign-procedure "uv_strerror_r" (int u8* size_t) uptr))
  (define raw-err-name-r
    (foreign-procedure "uv_err_name_r" (int u8* size_t) uptr))

  (define uv-loop-size   (foreign-procedure "uv_loop_size" () size_t))
  (define uv-handle-size (foreign-procedure "uv_handle_size" (int) size_t))
  (define uv-req-size    (foreign-procedure "uv_req_size" (int) size_t))

  ;; uv_run's integer is an activity result, not an errno. uv_loop_close's is.
  (define uv-loop-init  (foreign-procedure "uv_loop_init"  (uptr) int))
  ;; __collect_safe (#19): a thread blocked here is deactivated, so it does not
  ;; hold Chez's collect interlock and other Scheme threads can GC. This forces
  ;; every callable uv_run can invoke to be __collect_safe too (CSUG §4.3/4.8) —
  ;; every trampoline below carries the attribute but `walk`, which fires only
  ;; from the plain, synchronous uv_walk, never from here. libuv's alloc
  ;; callback, the shim's, needs none: it never enters Scheme.
  (define uv-loop-run   (foreign-procedure __collect_safe "uv_run" (uptr int) int))
  (define uv-loop-stop  (foreign-procedure "uv_stop"       (uptr) void))
  (define uv-loop-alive (foreign-procedure "uv_loop_alive" (uptr) int))
  (define uv-loop-now   (foreign-procedure "uv_now"        (uptr) unsigned-64))
  ;; Plain, not __collect_safe: it reads the clock and returns, never blocks.
  (define uv-loop-update-time
    (foreign-procedure "uv_update_time" (uptr) void))
  (define uv-loop-close (foreign-procedure "uv_loop_close" (uptr) int))

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

  ;; libuv chooses get or set based on whether the caller's int cell is zero.
  (define uv-send-buffer-size-native
    (foreign-procedure "uv_send_buffer_size" (uptr uptr) int))
  (define uv-recv-buffer-size-native
    (foreign-procedure "uv_recv_buffer_size" (uptr uptr) int))

  (define uv-tcp-init
    (foreign-procedure "uv_tcp_init" (uptr uptr) int))
  (define uv-tcp-bind
    (foreign-procedure "uv_tcp_bind" (uptr uptr unsigned-int) int))
  (define uv-tcp-getsockname
    (foreign-procedure "uv_tcp_getsockname" (uptr uptr uptr) int))
  ;; The length argument is an in/out pointer for caller-owned sockaddr storage.
  (define uv-tcp-getpeername-native
    (foreign-procedure "uv_tcp_getpeername" (uptr uptr uptr) int))
  (define uv-tcp-nodelay
    (foreign-procedure "uv_tcp_nodelay" (uptr int) int))
  ;; idle delay is an unsigned seconds count; libuv ignores it when on is 0.
  (define uv-tcp-keepalive
    (foreign-procedure "uv_tcp_keepalive" (uptr int unsigned-int) int))
  (define uv-accept
    (foreign-procedure "uv_accept" (uptr uptr) int))
  ;; The address is u8*, not string: Chez's string argument encodes the
  ;; caller's string during the call, and an engine's handler or another
  ;; thread can change it after validation (tests/test-address.sps). Plain,
  ;; not __collect_safe, so no collection moves the bytes during the call.
  (define raw-ip4-addr
    (foreign-procedure "uv_ip4_addr" (u8* int uptr) int))
  (define raw-ip6-addr
    (foreign-procedure "uv_ip6_addr" (u8* int uptr) int))

  (define raw-listen
    (foreign-procedure "uv_listen" (uptr int uptr) int))
  (define raw-tcp-connect
    (foreign-procedure "uv_tcp_connect" (uptr uptr uptr uptr) int))
  (define raw-write
    (foreign-procedure "uv_write" (uptr uptr uptr unsigned-int uptr) int))
  (define raw-shutdown
    (foreign-procedure "uv_shutdown" (uptr uptr uptr) int))

  ;; uv_read_start takes paired alloc and read callbacks.
  (define raw-read-start
    (foreign-procedure "uv_read_start" (uptr uptr uptr) int))
  (define uv-read-stop
    (foreign-procedure "uv_read_stop" (uptr) int))

  ;; libuv never reads or writes a handle's data. The read path owns it: it
  ;; points at the stream's descriptor in its handle block, which
  ;; alloc-cb-entry answers, and has one writer (tests/test-source-rules.sps).
  (define uv-handle-set-data
    (foreign-procedure "uv_handle_set_data" (uptr uptr) void))

  ;; size_t is required: this field cannot be negative and has no error channel.
  (define uv-stream-get-write-queue-size-native
    (foreign-procedure "uv_stream_get_write_queue_size" (uptr) size_t))

  ;; libuv copies node, service, and sockaddr inputs before these calls return.
  ;; Node and service are u8*, not string: Chez's string argument encodes
  ;; the caller's string during the call, and an engine's handler or another
  ;; thread can change it after validation (tests/test-dns.sps). Plain, not
  ;; __collect_safe, so no collection moves the bytes during the call.
  (define raw-getaddrinfo
    (foreign-procedure "uv_getaddrinfo"
                       (uptr uptr uptr u8* u8* uptr) int))

  (define raw-getnameinfo
    (foreign-procedure "uv_getnameinfo" (uptr uptr uptr uptr int) int))

  ;; Cancellation policy interprets EBUSY, so this raw errno is not uv-checked.
  (define uv-cancel (foreign-procedure "uv_cancel" (uptr) int))

  ;; Valid only for libuv-owned getaddrinfo chains; NULL is accepted.
  (define uv-freeaddrinfo
    (foreign-procedure "uv_freeaddrinfo" (uptr) void))

  ;; uv_ip_name dereferences its pointer, so only the zero-checking wrapper is
  ;; exported from this layer.
  (define raw-ip-name
    (foreign-procedure "uv_ip_name" (uptr u8* size_t) int))

  (define address-scratch-size 64)

  ;; sockaddr->address-string : uptr -> (or string #f)
  ;; Allocate scratch per call so nested callbacks cannot share mutable storage.
  (define (sockaddr->address-string addr)
    (if (zero? addr)
        #f
        (let ((bv (make-bytevector address-scratch-size 0)))
          (if (zero? (raw-ip-name addr bv address-scratch-size))
              (scratch->string bv address-scratch-size)
              #f))))

  ;; This is the POSIX uv_buf_t layout. Initialization compares its size,
  ;; offsets, and field widths with the C shim and fails closed on mismatch.
  (define-ftype uv-buf (struct (base uptr) (len size_t)))

  ;; uv-buf-set! : uptr exact-nonnegative-integer exact-nonnegative-integer
  ;;               -> unspecified
  ;; Checked like the other setters. Its callers write a write request's
  ;; buffers and a stream's read descriptor, inside steps that must not
  ;; raise, so each passes values it has already checked.
  (define (uv-buf-set! addr base len)
    (unless (and (integer? addr) (exact? addr) (positive? addr))
      (raise (make-uv-invalid-argument 'uv-buf-set! 'null-or-invalid-destination)))
    (unless (and (integer? base) (exact? base) (>= base 0)
                 (integer? len) (exact? len) (>= len 0))
      (raise (make-uv-invalid-argument 'uv-buf-set! 'value-out-of-range)))
    (let ((p (make-ftype-pointer uv-buf addr)))
      (ftype-set! uv-buf (base) p base)
      (ftype-set! uv-buf (len) p len)))

  (define (uv-buf-base addr)
    (ftype-ref uv-buf (base) (make-ftype-pointer uv-buf addr)))

  (define (uv-buf-len addr)
    (ftype-ref uv-buf (len) (make-ftype-pointer uv-buf addr)))

  ;; Measure field widths by observing writes, not by repeating type assumptions.
  (define (uv-buf-ftype-layout)
    (let* ((size (ftype-sizeof uv-buf))
           (addr (foreign-alloc size))
           (p    (make-ftype-pointer uv-buf addr)))
      (define (offset-of getter) (- (ftype-pointer-address (getter p)) addr))
      (define (fill! v)
        (let loop ((i 0))
          (when (< i size) (foreign-set! 'unsigned-8 addr i v) (loop (+ i 1)))))
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

  ;; c-string->string : uptr -> (or string #f)
  ;; Copy borrowed UTF-8 immediately; preserve NULL as #f rather than "".
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

  ;; zero-out!, copy-in! and copy-out each move their span in one shim call,
  ;; never a Scheme loop (#35; test-native.sps holds each within a small
  ;; factor of libc). The checks stay here, before the call: the shim trusts
  ;; its arguments. A foreign extent cannot be checked, so every caller passes
  ;; a live block of at least len bytes.

  ;; zero-out! : uptr exact-nonnegative-integer -> unspecified
  (define (zero-out! addr len)
    (unless (and (integer? addr) (exact? addr) (positive? addr))
      (raise (make-uv-invalid-argument 'uv-zero-out! 'null-or-invalid-destination)))
    (unless (and (integer? len) (exact? len) (>= len 0))
      (raise (make-uv-invalid-argument 'uv-zero-out! 'length-out-of-range)))
    (raw-zero addr len))

  ;; alloc-block, free-block! and copy-in-unchecked! are the forms a verb
  ;; uses inside an interrupt-free step, where nothing may raise (stream.sls).
  ;; Each is total: it answers or ignores what it cannot use, so no argument
  ;; can make it raise. alloc-zeroed and free! check their arguments and
  ;; raise; everything else allocates and frees through them.

  ;; alloc-block : object -> uptr
  ;; A zeroed block of N bytes, or 0 when N is not a positive fixnum or the
  ;; allocator refuses.
  (define (alloc-block n)
    (if (and (fixnum? n) (fx>? n 0))
        (raw-alloc n)
        0))

  ;; free-block! : object -> unspecified
  ;; Frees a block alloc-block answered. Anything that cannot be an address
  ;; is ignored, 0 included.
  (define (free-block! addr)
    (when (and (integer? addr) (exact? addr) (< 0 addr 18446744073709551616))
      (raw-free addr)))

  ;; copy-in-unchecked! : uptr bytevector exact-nonnegative-integer
  ;;                      exact-nonnegative-integer -> unspecified
  ;; copy-in!'s copy without its checks, for a step that has checked the span
  ;; against the bytevector itself: with interrupts disabled since, no
  ;; handler on this thread can truncate it in between.
  (define (copy-in-unchecked! dst bv start len)
    (raw-copy-in dst bv start len))

  ;; alloc-zeroed : exact-positive-integer -> uptr
  ;; A block the allocator refuses is &uv-errno-error ENOMEM, as libuv
  ;; reports its own.
  (define (alloc-zeroed n)
    (unless (and (integer? n) (exact? n) (positive? n))
      (raise (make-uv-invalid-argument 'uv-alloc-zeroed 'size-must-be-positive)))
    (let ((addr (alloc-block n)))
      (when (zero? addr)
        (raise (uv-errno-condition (errno-symbol->value 'ENOMEM) 'uv-alloc-zeroed)))
      addr))

  ;; free! : uptr -> unspecified
  ;; Reject zero because stored pointers are cleared immediately after free,
  ;; and anything past the address space, which free-block! would ignore.
  (define (free! addr)
    (unless (and (integer? addr) (exact? addr) (< 0 addr 18446744073709551616))
      (raise (make-uv-invalid-argument 'uv-free! 'null-or-invalid-pointer)))
    (free-block! addr))

  ;; try-copy-in! : uptr bytevector exact-nonnegative-integer
  ;;                exact-nonnegative-integer -> (or 'copied 'span-out-of-range)
  ;; The span is checked against the bytevector's length in the same
  ;; interrupt-free step as the copy. Otherwise an interrupt handler run
  ;; between the two (an engine's timer, say) could truncate the bytevector
  ;; and memcpy would read the heap past its new end (test-native.sps's
  ;; truncation scan). Another thread truncating it mid-copy is that
  ;; program's own race; nothing here can order it.
  ;;
  ;; A span that no longer fits is answered, not raised: no check a caller
  ;; makes beforehand can rule it out, since the bytevector can shrink after
  ;; it, and a caller holding a block it has not yet handed on must free
  ;; that block first (the write verbs, stream.sls). The other refusals are
  ;; the caller's own mistakes and raise.
  (define (try-copy-in! dst bv start len)
    (unless (and (integer? dst) (exact? dst) (positive? dst))
      (raise (make-uv-invalid-argument 'uv-copy-in! 'null-or-invalid-destination)))
    (unless (bytevector? bv)
      (raise (make-uv-invalid-argument 'uv-copy-in! 'source-not-a-bytevector)))
    (unless (and (integer? start) (exact? start) (>= start 0)
                 (integer? len) (exact? len) (>= len 0))
      (raise (make-uv-invalid-argument 'uv-copy-in! 'span-out-of-range)))
    (with-interrupts-disabled
      (if (<= (+ start len) (bytevector-length bv))
          (begin (raw-copy-in dst bv start len) 'copied)
          'span-out-of-range)))

  ;; copy-in! : uptr bytevector exact-nonnegative-integer
  ;;            exact-nonnegative-integer -> unspecified
  ;; try-copy-in!, raising when the span does not fit.
  (define (copy-in! dst bv start len)
    (unless (eq? (try-copy-in! dst bv start len) 'copied)
      (raise (make-uv-invalid-argument 'uv-copy-in! 'span-out-of-range))))

  (define (c-int-size) (foreign-sizeof 'int))

  (define (c-int-ref addr)
    (unless (and (integer? addr) (exact? addr) (positive? addr))
      (raise (make-uv-invalid-argument 'uv-c-int-ref 'null-or-invalid-source)))
    (foreign-ref 'int addr 0))

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

  (define (c-uptr-size) (foreign-sizeof 'uptr))

  (define (c-uptr-set! addr value)
    (unless (and (integer? addr) (exact? addr) (positive? addr))
      (raise (make-uv-invalid-argument 'uv-c-uptr-set! 'null-or-invalid-destination)))
    (unless (and (integer? value) (exact? value) (>= value 0))
      (raise (make-uv-invalid-argument 'uv-c-uptr-set! 'value-not-a-pointer)))
    (foreign-set! 'uptr addr 0 value))

  (define (c-u32-set! addr value)
    (unless (and (integer? addr) (exact? addr) (positive? addr))
      (raise (make-uv-invalid-argument 'uv-c-u32-set! 'null-or-invalid-destination)))
    (unless (and (integer? value) (exact? value) (>= value 0)
                 (< value 4294967296))
      (raise (make-uv-invalid-argument 'uv-c-u32-set! 'value-out-of-range)))
    (foreign-set! 'unsigned-32 addr 0 value))

  ;; read-net-u16 : uptr exact-nonnegative-integer -> exact-nonnegative-integer
  ;; Read bytes explicitly so network order is independent of host endianness.
  (define (read-net-u16 addr offset)
    (unless (and (integer? addr) (exact? addr) (positive? addr))
      (raise (make-uv-invalid-argument 'uv-read-net-u16 'null-or-invalid-source)))
    (unless (and (integer? offset) (exact? offset) (>= offset 0))
      (raise (make-uv-invalid-argument 'uv-read-net-u16 'offset-out-of-range)))
    (+ (* 256 (foreign-ref 'unsigned-8 addr offset))
       (foreign-ref 'unsigned-8 addr (+ offset 1))))

  ;; copy-out : uptr exact-nonnegative-integer -> bytevector
  (define (copy-out src len)
    (unless (and (integer? src) (exact? src) (positive? src))
      (raise (make-uv-invalid-argument 'uv-copy-out 'null-or-invalid-source)))
    (unless (and (integer? len) (exact? len) (>= len 0))
      (raise (make-uv-invalid-argument 'uv-copy-out 'length-out-of-range)))
    (let ((bv (make-bytevector len)))
      (raw-copy-out bv src len)
      bv))

  ;; fill-sockaddr! : uptr bytevector exact-nonnegative-integer symbol
  ;;                  -> unspecified
  ;; Parse IP, the bytes validate-address answered, into ADDR: IPv4, then
  ;; IPv6, both from the same bytes. libuv reads them as a C string, so they
  ;; must be one: a bytevector whose only NUL is its last byte. Neither
  ;; parser retains them.
  (define (fill-sockaddr! addr ip port who)
    (unless (c-string? ip)
      (raise (make-uv-invalid-argument 'uv-fill-sockaddr! 'not-a-c-string)))
    (unless (or (zero? (raw-ip4-addr ip port addr))
                (zero? (raw-ip6-addr ip port addr)))
      (raise (make-uv-invalid-argument who 'bad-address))))

  ;; align-16 : exact-nonnegative-integer -> exact-nonnegative-integer
  (define (align-16 n) (* 16 (div (+ n 15) 16)))

  ;; validate-address : object symbol -> bytevector
  ;; IP as the bytes libuv parses (c-string-bytes): a refusal unless it is a
  ;; string holding no NUL, which C would read as its end. The address verbs
  ;; hand libuv only these bytes, so the caller's string is read once, here,
  ;; and a change to it during the call reaches nothing. Parsing is
  ;; fill-sockaddr!'s job.
  (define (validate-address ip who)
    (unless (string? ip)
      (raise (make-uv-invalid-argument who 'address-not-a-string)))
    (c-string-bytes ip who 'address-contains-nul))

  (define (require-port port who)
    (unless (and (integer? port) (exact? port) (>= port 0) (<= port 65535))
      (raise (make-uv-invalid-argument who 'port-out-of-range))))

  ;; fold-flags : object symbol symbol (object -> exact-integer)
  ;;              -> exact-integer
  ;; The bitwise-ior of (BIT flag) over a caller's flag list, which is read
  ;; once: its length from proper-length, #f for an improper or circular list
  ;; and then the refusal (WHO, REASON), then at most that many pairs, each
  ;; checked as it is read. A list changed during the walk is refused, or
  ;; read as each pair stood when the walk reached it, and never walked
  ;; forever. Asking list? first would leave a gap an engine's handler can
  ;; change the list in, and fold-left walks a list made circular there
  ;; forever (tests/test-address.sps's flags sweeps). Nothing here
  ;; allocates (tests/test-native.sps).
  (define (fold-flags flags who reason bit)
    (let ((n (proper-length flags)))
      (unless n
        (raise (make-uv-invalid-argument who reason)))
      (let walk ((rest flags) (left n) (bits 0))
        (cond ((zero? left) bits)
              ((not (pair? rest))
               (raise (make-uv-invalid-argument who reason)))
              (else
               (walk (cdr rest) (- left 1) (bitwise-ior bits (bit (car rest)))))))))

  ;; proper-length : object -> (or exact-nonnegative-integer #f)
  ;; X's length when it is a proper list, else #f. A tortoise-and-hare walk:
  ;; it ends at the list's end, at a pair whose cdr is not a pair or '(), or
  ;; where the hare meets the tortoise in a cycle, so it raises nothing and
  ;; allocates nothing, where length raises and a guard around it allocates.
  (define (proper-length x)
    (let walk ((hare x) (tortoise x) (n 0))
      (cond ((null? hare) n)
            ((not (pair? hare)) #f)
            ((null? (cdr hare)) (+ n 1))
            ((not (pair? (cdr hare))) #f)
            (else
             (let ((hare (cddr hare)) (tortoise (cdr tortoise)))
               (if (eq? hare tortoise)
                   #f
                   (walk hare tortoise (+ n 2))))))))

  (define (require-callback proc who reason)
    (unless (procedure? proc)
      (raise (make-uv-invalid-argument who reason))))

  ;; current-thread-id : -> exact-integer
  ;; The identity per-loop affinity (#20) compares against. The binding needs
  ;; a threaded Chez (#41), so this is always the real thread id.
  (define (current-thread-id)
    (get-thread-id))

  ;; signal-symbol->int : (or symbol 0) symbol -> exact-integer
  ;; Accept only the closed symbolic vocabulary plus kill(pid, 0).
  (define (signal-symbol->int sig who)
    (cond
      ((eqv? sig 0) 0)
      ((symbol? sig)
       (case sig
         ((sigterm) (sig-term)) ((sigkill) (sig-kill)) ((sigint) (sig-int))
         ((sighup) (sig-hup)) ((sigquit) (sig-quit))
         ((sigusr1) (sig-usr1)) ((sigusr2) (sig-usr2))
         ((sigcont) (sig-cont)) ((sigstop) (sig-stop))
         (else (raise (make-uv-invalid-argument who 'signal-unknown)))))
      (else (raise (make-uv-invalid-argument who 'signal-unknown)))))

  ;; term-signal->value : exact-integer -> (or symbol exact-integer #f)
  ;; Preserve an unknown signal as its raw integer.
  (define (term-signal->value n)
    (cond ((zero? n) #f)
          ((= n (sig-term)) 'sigterm)
          ((= n (sig-kill)) 'sigkill)
          ((= n (sig-int))  'sigint)
          ((= n (sig-hup))  'sighup)
          ((= n (sig-quit)) 'sigquit)
          ((= n (sig-usr1)) 'sigusr1)
          ((= n (sig-usr2)) 'sigusr2)
          ((= n (sig-cont)) 'sigcont)
          ((= n (sig-stop)) 'sigstop)
          (else n)))

  ;; Error conversion uses fresh per-call storage for callback re-entrancy.
  (define scratch-size 256)

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

  (define (errno->symbol code) (string->symbol (r-call raw-err-name-r code)))

  (define (errno->message code) (r-call raw-strerror-r code))

  ;; uv-check : exact-integer symbol -> exact-integer
  ;; Only zero succeeds; testing truthiness would accept every integer in Scheme.
  (define (uv-check rc who)
    (if (zero? rc) rc (raise (uv-errno-condition rc who))))

  ;; uv-errno-condition : exact-integer symbol -> condition
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
          (cons 'signal        (live-signal))
          (cons 'async         (live-async))
          (cons 'block         (live-block))))

  ;; One process-global slot and locked trampoline per callback type that
  ;; crosses into Scheme. libuv's alloc callback does not: the shim answers
  ;; it (alloc-cb-entry).
  (define dispatcher-names
    '(read connection write-done close timer shutdown connect
      getaddrinfo getnameinfo exit walk signal async))

  (define dispatchers (make-eq-hashtable))
  (define dispatchers-installed #f)

  (define (dispatchers-installed?) dispatchers-installed)

  (define (uninstalled-dispatcher name)
    (lambda args
      (raise (condition
              (make-uv-error)
              (make-who-condition name)
              (make-message-condition
               "callback dispatchers have not been installed")))))

  ;; Definitions perform ordering-sensitive library initialization legally.
  (define dispatchers-seeded
    (for-each (lambda (name)
                (hashtable-set! dispatchers name (uninstalled-dispatcher name)))
              dispatcher-names))

  ;; Look up at fire time; capturing now would retain the seeded stub forever.
  (define (dispatcher-ref name)
    (let ((proc (hashtable-ref dispatchers name #f)))
      (or proc
          (raise (make-uv-invalid-argument 'uv-dispatcher-ref
                                           'unknown-dispatcher)))))

  ;; Validate the complete set before a once-only atomic installation.
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
    (for-each (lambda (name)
                (hashtable-set! dispatchers name (cdr (assq name alist))))
              dispatcher-names)
    (set! dispatchers-installed #t))

  ;; Callback signatures mirror libuv exactly; notably nread is ssize_t.
  (define read-callable
    (foreign-callable __collect_safe (lambda (stream nread buf)
                        ((dispatcher-ref 'read) stream nread buf))
                      (uptr ssize_t uptr) void))

  (define connection-callable
    (foreign-callable __collect_safe (lambda (server status)
                        ((dispatcher-ref 'connection) server status))
                      (uptr int) void))

  (define write-done-callable
    (foreign-callable __collect_safe (lambda (req status)
                        ((dispatcher-ref 'write-done) req status))
                      (uptr int) void))

  (define close-callable
    (foreign-callable __collect_safe (lambda (handle) ((dispatcher-ref 'close) handle))
                      (uptr) void))

  (define timer-callable
    (foreign-callable __collect_safe (lambda (handle) ((dispatcher-ref 'timer) handle))
                      (uptr) void))

  (define shutdown-callable
    (foreign-callable __collect_safe (lambda (req status)
                        ((dispatcher-ref 'shutdown) req status))
                      (uptr int) void))

  (define connect-callable
    (foreign-callable __collect_safe (lambda (req status)
                        ((dispatcher-ref 'connect) req status))
                      (uptr int) void))

  ;; DNS string pointers are borrowed and may be NULL; policy copies them later.
  (define getaddrinfo-callable
    (foreign-callable __collect_safe (lambda (req status res)
                        ((dispatcher-ref 'getaddrinfo) req status res))
                      (uptr int uptr) void))

  (define getnameinfo-callable
    (foreign-callable __collect_safe (lambda (req status hostname service)
                        ((dispatcher-ref 'getnameinfo)
                         req status hostname service))
                      (uptr int uptr uptr) void))

  (define exit-callable
    (foreign-callable __collect_safe (lambda (handle exit-status term-signal)
                        ((dispatcher-ref 'exit) handle exit-status term-signal))
                      (uptr integer-64 int) void))

  ;; NOT __collect_safe, deliberately: walk fires only from uv_walk (raw-walk
  ;; below), a plain synchronous foreign call on an ACTIVE thread — never from
  ;; the collect-safe uv_run. CSUG §4.3/4.8 is "if and only if": a collect-safe
  ;; callable entered from an active thread is a mismatch, so walk stays plain
  ;; exactly as long as uv_walk does.
  (define walk-callable
    (foreign-callable (lambda (handle arg)
                        ((dispatcher-ref 'walk) handle arg))
                      (uptr uptr) void))

  (define signal-callable
    (foreign-callable __collect_safe (lambda (handle signum)
                        ((dispatcher-ref 'signal) handle signum))
                      (uptr int) void))

  ;; uv_async_cb (uv_async_t*) -> void. Same arity as close/timer, distinct
  ;; callback TYPE, so its own locked slot (ADR-0008's per-type rule). It fires
  ;; from uv_run, so it is __collect_safe like the rest.
  (define async-callable
    (foreign-callable __collect_safe (lambda (handle) ((dispatcher-ref 'async) handle))
                      (uptr) void))

  (define raw-walk
    (foreign-procedure "uv_walk" (uptr uptr uptr) void))

  (define (uv-walk-native loop-ptr arg)
    (raw-walk loop-ptr walk-cb-entry arg))

  ;; libuv retains these addresses, so lock the fixed set for process lifetime.
  (define trampolines-locked
    (for-each lock-object
              (list read-callable connection-callable
                    write-done-callable close-callable timer-callable
                    shutdown-callable connect-callable
                    getaddrinfo-callable getnameinfo-callable
                    exit-callable walk-callable signal-callable
                    async-callable)))

  ;; Entry-point addresses leave only through the wrappers below, except the
  ;; shim's alloc-cb-entry, which tests/test-tcp.sps calls as libuv does.
  (define close-cb-entry      (foreign-callable-entry-point close-callable))
  (define timer-cb-entry      (foreign-callable-entry-point timer-callable))
  (define connection-cb-entry (foreign-callable-entry-point connection-callable))
  (define write-cb-entry      (foreign-callable-entry-point write-done-callable))
  (define connect-cb-entry    (foreign-callable-entry-point connect-callable))
  (define shutdown-cb-entry   (foreign-callable-entry-point shutdown-callable))
  (define read-cb-entry       (foreign-callable-entry-point read-callable))
  (define getaddrinfo-cb-entry
    (foreign-callable-entry-point getaddrinfo-callable))
  (define getnameinfo-cb-entry
    (foreign-callable-entry-point getnameinfo-callable))
  (define exit-cb-entry (foreign-callable-entry-point exit-callable))
  (define walk-cb-entry (foreign-callable-entry-point walk-callable))
  (define signal-cb-entry (foreign-callable-entry-point signal-callable))
  (define async-cb-entry  (foreign-callable-entry-point async-callable))

  ;; uv-timer-start-native : uptr exact-nonnegative-integer
  ;;                         exact-nonnegative-integer -> exact-integer
  (define (uv-timer-start-native timer-ptr timeout repeat)
    (raw-timer-start timer-ptr timer-cb-entry timeout repeat))

  ;; uv-close-native : uptr -> unspecified
  ;; This only schedules close; the callback owns the eventual free.
  (define (uv-close-native handle-ptr)
    (raw-close handle-ptr close-cb-entry))

  ;; Each wrapper bakes the matching callback address into the raw call.
  (define (uv-listen-native server-ptr backlog)
    (raw-listen server-ptr backlog connection-cb-entry))

  (define (uv-tcp-connect-native req-ptr handle-ptr addr-ptr)
    (raw-tcp-connect req-ptr handle-ptr addr-ptr connect-cb-entry))

  (define (uv-write-native req-ptr stream-ptr bufs-ptr nbufs)
    (raw-write req-ptr stream-ptr bufs-ptr nbufs write-cb-entry))

  (define (uv-shutdown-native req-ptr stream-ptr)
    (raw-shutdown req-ptr stream-ptr shutdown-cb-entry))

  ;; libuv's alloc callback is the shim's and its read callback the
  ;; trampoline's, paired in this one wrapper.
  (define (uv-read-start-native stream-ptr)
    (raw-read-start stream-ptr alloc-cb-entry read-cb-entry))

  ;; uv-getaddrinfo-native : uptr uptr (or bytevector #f) (or bytevector #f)
  ;;                         uptr -> exact-integer
  ;; libuv reads node and service as C strings, so each must be one: a
  ;; bytevector whose only NUL is its last byte. #f crosses as NULL.
  (define (uv-getaddrinfo-native loop-ptr req-ptr node service hints-ptr)
    (unless (and (c-string-or-false? node) (c-string-or-false? service))
      (raise (make-uv-invalid-argument 'uv-getaddrinfo-native 'not-a-c-string)))
    (raw-getaddrinfo loop-ptr req-ptr getaddrinfo-cb-entry
                     node service hints-ptr))

  (define (c-string-or-false? x)
    (or (not x) (c-string? x)))

  ;; uv-getnameinfo-native : uptr uptr uptr exact-integer -> exact-integer
  (define (uv-getnameinfo-native loop-ptr req-ptr addr-ptr flags)
    (raw-getnameinfo loop-ptr req-ptr getnameinfo-cb-entry addr-ptr flags))

  (define raw-spawn
    (foreign-procedure "uv_spawn" (uptr uptr uptr) int))

  ;; uv-spawn-native : uptr uptr uptr -> exact-integer
  ;; The exit callback lives inside the options struct, never as a raw argument.
  (define (uv-spawn-native loop-ptr handle-ptr options-ptr)
    (foreign-set! 'uptr options-ptr
                  (offsetof-uv-process-options-t-exit-cb) exit-cb-entry)
    (raw-spawn loop-ptr handle-ptr options-ptr))

  (define uv-process-kill
    (foreign-procedure "uv_process_kill" (uptr int) int))
  (define uv-kill
    (foreign-procedure "uv_kill" (int int) int))
  (define uv-process-get-pid
    (foreign-procedure "uv_process_get_pid" (uptr) int))
  (define uv-pipe-init
    (foreign-procedure "uv_pipe_init" (uptr uptr int) int))

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

  (define uv-os-getpid-native
    (foreign-procedure "uv_os_getpid" () int))

  ;; uv_async_init bakes the wake callback at init time (unlike timer/signal,
  ;; which take it at start). uv_async_send is libuv's ONE thread-safe call.
  (define raw-async-init
    (foreign-procedure "uv_async_init" (uptr uptr uptr) int))
  (define uv-async-send
    (foreign-procedure "uv_async_send" (uptr) int))

  ;; uv-async-init-native : uptr uptr -> exact-integer
  (define (uv-async-init-native loop-ptr handle-ptr)
    (raw-async-init loop-ptr handle-ptr async-cb-entry))

  ;; version-supported? : exact-integer -> boolean
  (define (version-supported? v)
    (let ((lo (car uv-supported-version-range))
          (hi (cdr uv-supported-version-range)))
      (and (>= v lo) (<= v hi))))

  ;; version-compatible? : exact-integer exact-integer -> boolean
  ;; Both versions must be in range; patch-level equality is not required.
  (define (version-compatible? compiled runtime)
    (and (version-supported? compiled)
         (version-supported? runtime)))

  ;; check-version-compatible! : exact-integer exact-integer -> exact-integer
  (define (check-version-compatible! compiled runtime)
    (if (version-compatible? compiled runtime)
        runtime
        (raise (make-uv-version-incompatible compiled runtime))))

  ;; lookup-constant : string -> (or exact-integer #f)
  ;; Size the out-parameter as C long rather than assuming pointer width.
  (define (lookup-constant name)
    (let* ((out (foreign-alloc (foreign-sizeof 'long)))
           (found (guard (e (#t (foreign-free out) (raise e)))
                    (raw-constant name out)))
           (value (if (zero? found) #f (foreign-ref 'long out 0))))
      (foreign-free out)
      value))

  (define (errno-name-at i) (c-string->string (raw-errno-name i)))

  ;; Initialization is process-global and serialized in Scheme for portability.
  (define init-mutex (make-mutex))
  (define initialized? #f)
  (define init-count 0)

  (define (native-initialized?) initialized?)

  (define (native-init-count) init-count)

  ;; Compare the Scheme ftype with independently compiled size, offsets, and
  ;; field widths before any handle can exist.
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
                   (= (+ base-off base-width) len-off)
                   (= (+ len-off len-width) size))
        (raise (make-uv-shim-unavailable resolved-shim-path)))))

  ;; ensure-native-loaded! : -> unspecified
  ;; Idempotently validate versions, constants, and uv_buf_t layout.
  (define (ensure-native-loaded!)
    (with-mutex init-mutex
      (unless initialized?
        (check-version-compatible! (shim-compiled-version) (uv-version))
        (constants-init! lookup-constant raw-errno-count
                         errno-name-at raw-errno-value)
        (validate-uv-buf-layout!)
        (set! init-count (+ init-count 1))
        (set! initialized? #t)))))
