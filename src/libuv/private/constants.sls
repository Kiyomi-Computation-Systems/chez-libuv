#!r6rs
;;; Init-time snapshot of the shim's constant table and errno enumeration
;;; (ADR-0005: constants are never transcribed).
;;;
;;; Every value this library serves was computed by a C compiler from a real
;;; macro, enum member, `sizeof`, or `offsetof` in src/libuv-shim.c, looked
;;; up BY NAME at initialisation. Nothing here is a literal, and a name the
;;; shim does not define is not a zero, a #f, or a default -- it is
;;; &uv-constant-unavailable carrying the missing name, raised before any
;;; handle can exist.
;;;
;;; DEPENDENCY DIRECTION. This library imports (rnrs) and
;;; (libuv private conditions) only -- deliberately NOT
;;; (libuv private native). The FFI primitives arrive as arguments to
;;; `constants-init!`, which (libuv private native) calls from
;;; `ensure-native-loaded!`. That keeps the import graph acyclic (native ->
;;; constants, never the reverse), keeps `foreign-procedure` confined to the
;;; one library design spec S3 permits it in, and makes this module's whole
;;; decision surface -- name resolution, the errno tables, the missing-name
;;; failure -- exercisable against a synthetic lookup with no shim present.
;;;
;;; Accessors are nullary procedures rather than plain variables because the
;;; values are not known until init; the snapshot behind them is an
;;; IMMUTABLE hashtable keyed by the shim's own constant name, so there is no
;;; positional contract between this file and src/libuv-shim.c that could
;;; drift silently (the failure mode a value-ordered record would have).
(library (libuv private constants)
  (export constants-init! constants-init-count constants-initialized?
          constant-ref

          uv-run-default uv-run-once uv-run-nowait
          uv-eof af-inet af-unspec uv-tcp-type uv-timer-type
          uv-write-req-type uv-connect-req-type uv-shutdown-req-type

          sizeof-uv-loop-t sizeof-uv-tcp-t sizeof-uv-timer-t
          sizeof-uv-write-t sizeof-uv-connect-t sizeof-uv-shutdown-t
          sizeof-uv-buf-t sizeof-sockaddr-in sizeof-sockaddr-storage

          offsetof-uv-buf-t-base offsetof-uv-buf-t-len
          offsetof-sockaddr-in-sin-port offsetof-sockaddr-in-sin-family

          errno-count errno-symbols errno-value->symbol errno-symbol->value)
  (import (rnrs)
          (libuv private conditions))

  ;; --- the snapshot -----------------------------------------------------
  ;; snapshot: an immutable eq-hashtable, symbol -> exact integer.
  ;; lookup:   the shim's chez_uv_constant wrapper, string -> integer or #f.
  ;; Both are #f until constants-init! runs.
  (define snapshot #f)
  (define lookup   #f)
  (define init-count 0)

  ;; errno tables, both immutable after init:
  ;;   value->symbol : eqv-hashtable, exact integer -> symbol
  ;;   symbol->value : eq-hashtable,  symbol -> exact integer
  (define errno-value-table  #f)
  (define errno-symbol-table #f)
  (define errno-name-list    '())

  ;; The names this binding snapshots. The list is the single place a new
  ;; constant is declared; init walks it, so adding one here is the whole
  ;; change on the Scheme side (the C side gets one table entry).
  (define snapshot-names
    '(UV_RUN_DEFAULT UV_RUN_ONCE UV_RUN_NOWAIT
      UV_EOF AF_INET AF_UNSPEC UV_TCP UV_TIMER
      UV_WRITE UV_CONNECT UV_SHUTDOWN
      SIZEOF_UV_LOOP_T SIZEOF_UV_TCP_T SIZEOF_UV_TIMER_T
      SIZEOF_UV_WRITE_T SIZEOF_UV_CONNECT_T SIZEOF_UV_SHUTDOWN_T
      SIZEOF_UV_BUF_T SIZEOF_SOCKADDR_IN SIZEOF_SOCKADDR_STORAGE
      OFFSETOF_UV_BUF_T_BASE OFFSETOF_UV_BUF_T_LEN
      OFFSETOF_SOCKADDR_IN_SIN_PORT OFFSETOF_SOCKADDR_IN_SIN_FAMILY))

  ;; The fallback errno symbol. It cannot collide with a real name: libuv's
  ;; UV_ERRNO_MAP tokens are the bare codes ("EOF", "ECONNRESET"), never
  ;; UV_-prefixed, and the shim exports them unprefixed on purpose.
  (define unknown-errno-symbol 'UV_UNKNOWN)

  (define (constants-initialized?) (and snapshot #t))
  (define (constants-init-count) init-count)

  (define (require-initialized who)
    (unless snapshot
      (raise (make-uv-invalid-argument who 'constants-not-initialized))))

  ;; Resolve any name the shim's table might carry, at any time after init.
  ;; This is the primitive `constants-init!` itself uses, exported so a name
  ;; the shim does not define can be probed directly -- ADR-0005's
  ;; mutation-testability claim rests on that failure being observable and
  ;; specific.
  (define (constant-ref name)
    (require-initialized 'uv-constant-ref)
    (let ((cached (hashtable-ref snapshot name 'absent)))
      (if (eq? cached 'absent)
          (or (lookup (symbol->string name))
              (raise (make-uv-constant-unavailable name)))
          cached)))

  ;; Reader for a snapshotted name. Distinct from constant-ref only in that
  ;; it never falls through to the shim: everything in snapshot-names is
  ;; resolved once, at init, and served from memory afterwards.
  (define (snapshot-ref name)
    (require-initialized 'uv-constant-snapshot-ref)
    (let ((v (hashtable-ref snapshot name 'absent)))
      (if (eq? v 'absent)
          (raise (make-uv-constant-unavailable name))
          v)))

  ;; --- init -------------------------------------------------------------
  ;; lookup-proc     : string -> exact integer or #f
  ;; errno-count-proc: -> exact integer
  ;; errno-name-proc : index -> string or #f
  ;; errno-value-proc: index -> exact integer
  ;;
  ;; Idempotent by an explicit guard, not by accident: a second call is a
  ;; no-op and leaves init-count alone, which is what tests/test-native.sps
  ;; asserts (removing the guard makes the count climb).
  ;; Everything is built into locals and committed together, at the end: a
  ;; lookup that raises part way through must leave the library UNinitialised
  ;; rather than half-initialised, since `require-initialized` tests one flag
  ;; on behalf of all of them.
  (define (constants-init! lookup-proc errno-count-proc
                           errno-name-proc errno-value-proc)
    (unless snapshot
      (let ((table (make-eq-hashtable)))
        (for-each
         (lambda (name)
           (let ((v (lookup-proc (symbol->string name))))
             (unless v (raise (make-uv-constant-unavailable name)))
             (hashtable-set! table name v)))
         snapshot-names)
        (let-values (((names by-value by-symbol)
                      (build-errno-tables errno-count-proc
                                          errno-name-proc
                                          errno-value-proc)))
          (set! lookup lookup-proc)
          (set! errno-name-list names)
          (set! errno-value-table by-value)
          (set! errno-symbol-table by-symbol)
          ;; hashtable-copy with no mutability argument yields an IMMUTABLE
          ;; copy (R6RS), so the snapshot cannot be edited after init -- the
          ;; "immutable record" the design spec asks for, enforced rather
          ;; than promised. Assigning `snapshot` last makes it the commit
          ;; point every accessor's initialised-check keys on.
          (set! snapshot (hashtable-copy table))
          (set! init-count (+ init-count 1))))))

  ;; The errno enumeration is walked by index over the shim's X-macro
  ;; expansion of libuv's own UV_ERRNO_MAP, so the name list tracks the
  ;; pinned header rather than being copied out by hand (ADR-0005). A NULL
  ;; name at an index below the reported count means the shim's count and
  ;; its table have come apart -- fail closed, naming the index.
  ;; Returns three values: the symbol list in enumeration order, the
  ;; immutable value->symbol table, and the immutable symbol->value table.
  (define (build-errno-tables count-proc name-proc value-proc)
    (let ((n (count-proc))
          (by-value  (make-eqv-hashtable))
          (by-symbol (make-eq-hashtable)))
      (let loop ((i 0) (names '()))
        (if (= i n)
            (values (reverse names)
                    (hashtable-copy by-value)
                    (hashtable-copy by-symbol))
            (let ((name (name-proc i)))
              (unless (string? name)
                (raise (make-uv-constant-unavailable
                        (string->symbol
                         (string-append "UV_ERRNO_INDEX_"
                                        (number->string i))))))
              (let ((sym (string->symbol name))
                    (val (value-proc i)))
                (hashtable-set! by-value val sym)
                (hashtable-set! by-symbol sym val)
                (loop (+ i 1) (cons sym names))))))))

  (define (errno-count)
    (require-initialized 'uv-errno-count)
    (length errno-name-list))

  ;; A fresh list each call: the caller must not be able to mutate the
  ;; snapshot's own view of the enumeration.
  (define (errno-symbols)
    (require-initialized 'uv-errno-symbols)
    (map values errno-name-list))

  ;; ADR-0006: a code libuv does not name is not an error to raise on here --
  ;; the raw int stays reachable through &uv-errno-error's `code` field, so
  ;; nothing is lost -- but it must never come back as #f or as some other
  ;; code's symbol.
  (define (errno-value->symbol n)
    (require-initialized 'uv-errno-value->symbol)
    (hashtable-ref errno-value-table n unknown-errno-symbol))

  (define (errno-symbol->value sym)
    (require-initialized 'uv-errno-symbol->value)
    (let ((v (hashtable-ref errno-symbol-table sym 'absent)))
      (if (eq? v 'absent)
          (raise (make-uv-constant-unavailable sym))
          v)))

  ;; --- named accessors --------------------------------------------------
  ;; One per snapshotted constant. Each names its own key, so there is no
  ;; way for an accessor and a value to drift apart.
  (define (uv-run-default) (snapshot-ref 'UV_RUN_DEFAULT))
  (define (uv-run-once)    (snapshot-ref 'UV_RUN_ONCE))
  (define (uv-run-nowait)  (snapshot-ref 'UV_RUN_NOWAIT))

  (define (uv-eof)         (snapshot-ref 'UV_EOF))
  (define (af-inet)        (snapshot-ref 'AF_INET))
  (define (af-unspec)      (snapshot-ref 'AF_UNSPEC))
  (define (uv-tcp-type)    (snapshot-ref 'UV_TCP))
  (define (uv-timer-type)  (snapshot-ref 'UV_TIMER))

  ;; uv_req_type tags, for uv_req_size(). Named *-req-type rather than
  ;; uv-write/uv-connect so they cannot be mistaken for the operations of
  ;; the same name that Tasks 4 and 5 of the milestone sequence add.
  (define (uv-write-req-type)    (snapshot-ref 'UV_WRITE))
  (define (uv-connect-req-type)  (snapshot-ref 'UV_CONNECT))
  (define (uv-shutdown-req-type) (snapshot-ref 'UV_SHUTDOWN))

  (define (sizeof-uv-loop-t)     (snapshot-ref 'SIZEOF_UV_LOOP_T))
  (define (sizeof-uv-tcp-t)      (snapshot-ref 'SIZEOF_UV_TCP_T))
  (define (sizeof-uv-timer-t)    (snapshot-ref 'SIZEOF_UV_TIMER_T))
  (define (sizeof-uv-write-t)    (snapshot-ref 'SIZEOF_UV_WRITE_T))
  (define (sizeof-uv-connect-t)  (snapshot-ref 'SIZEOF_UV_CONNECT_T))
  (define (sizeof-uv-shutdown-t) (snapshot-ref 'SIZEOF_UV_SHUTDOWN_T))
  (define (sizeof-uv-buf-t)      (snapshot-ref 'SIZEOF_UV_BUF_T))
  (define (sizeof-sockaddr-in)      (snapshot-ref 'SIZEOF_SOCKADDR_IN))
  (define (sizeof-sockaddr-storage) (snapshot-ref 'SIZEOF_SOCKADDR_STORAGE))

  (define (offsetof-uv-buf-t-base) (snapshot-ref 'OFFSETOF_UV_BUF_T_BASE))
  (define (offsetof-uv-buf-t-len)  (snapshot-ref 'OFFSETOF_UV_BUF_T_LEN))
  (define (offsetof-sockaddr-in-sin-port)
    (snapshot-ref 'OFFSETOF_SOCKADDR_IN_SIN_PORT))
  (define (offsetof-sockaddr-in-sin-family)
    (snapshot-ref 'OFFSETOF_SOCKADDR_IN_SIN_FAMILY)))
