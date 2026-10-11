#!r6rs
;;; Immutable init-time snapshot of compiler-derived constants, sizes, offsets,
;;; and libuv's errno table. This library stays independent of the FFI layer.
(library (libuv private constants)
  (export constants-init! constants-init-count constants-initialized?
          constant-ref

          uv-run-default uv-run-once uv-run-nowait
          uv-eof af-inet af-unspec af-inet6 uv-tcp-type uv-timer-type
          uv-write-req-type uv-connect-req-type uv-shutdown-req-type
          uv-getaddrinfo-req-type uv-getnameinfo-req-type

          sizeof-uv-loop-t sizeof-uv-tcp-t sizeof-uv-timer-t
          sizeof-uv-write-t sizeof-uv-connect-t sizeof-uv-shutdown-t
          sizeof-uv-buf-t sizeof-sockaddr-in sizeof-sockaddr-storage
          sizeof-uv-getaddrinfo-t sizeof-uv-getnameinfo-t
          sizeof-addrinfo sizeof-sockaddr-in6

          offsetof-uv-buf-t-base offsetof-uv-buf-t-len
          offsetof-sockaddr-in-sin-port offsetof-sockaddr-in-sin-family
          offsetof-addrinfo-ai-flags offsetof-addrinfo-ai-family
          offsetof-addrinfo-ai-socktype offsetof-addrinfo-ai-protocol
          offsetof-addrinfo-ai-addrlen offsetof-addrinfo-ai-addr
          offsetof-addrinfo-ai-canonname offsetof-addrinfo-ai-next
          offsetof-sockaddr-in6-sin6-port

          sock-stream sock-dgram sock-raw
          ipproto-tcp ipproto-udp
          uv-tcp-reuseport
          ai-passive ai-canonname ai-numerichost ai-numericserv
          ni-numerichost ni-numericserv ni-namereqd ni-dgram

          uv-process-type uv-named-pipe-type uv-signal-type uv-async-type
          sizeof-uv-process-options-t
          offsetof-uv-process-options-t-exit-cb
          offsetof-uv-process-options-t-file
          offsetof-uv-process-options-t-args
          offsetof-uv-process-options-t-env
          offsetof-uv-process-options-t-cwd
          offsetof-uv-process-options-t-flags
          offsetof-uv-process-options-t-stdio-count
          offsetof-uv-process-options-t-stdio
          offsetof-uv-process-options-t-uid
          offsetof-uv-process-options-t-gid
          sizeof-uv-stdio-container-t
          offsetof-uv-stdio-container-t-flags
          offsetof-uv-stdio-container-t-data
          uv-process-setuid-flag uv-process-setgid-flag uv-process-detached-flag
          uv-stdio-ignore
          uv-stdio-create-pipe uv-stdio-inherit-fd
          uv-stdio-inherit-stream
          uv-stdio-readable-pipe uv-stdio-writable-pipe
          sig-term sig-kill sig-int sig-hup sig-quit
          sig-usr1 sig-usr2 sig-cont sig-stop

          errno-count errno-symbols errno-value->symbol errno-symbol->value)
  (import (rnrs)
          (libuv private conditions))

  ;; snapshot, lookup and the errno tables stay #f, and errno-name-list
  ;; '(), until constants-init! commits a complete snapshot, which it does
  ;; at most once; init-count counts the commits.
  (define snapshot #f)
  (define lookup   #f)
  (define init-count 0)

  (define errno-value-table  #f)
  (define errno-symbol-table #f)
  (define errno-name-list    '())

  (define snapshot-names
    '(UV_RUN_DEFAULT UV_RUN_ONCE UV_RUN_NOWAIT
      UV_EOF AF_INET AF_UNSPEC AF_INET6 UV_TCP UV_TIMER
      UV_WRITE UV_CONNECT UV_SHUTDOWN UV_GETADDRINFO UV_GETNAMEINFO
      SIZEOF_UV_LOOP_T SIZEOF_UV_TCP_T SIZEOF_UV_TIMER_T
      SIZEOF_UV_WRITE_T SIZEOF_UV_CONNECT_T SIZEOF_UV_SHUTDOWN_T
      SIZEOF_UV_GETADDRINFO_T SIZEOF_UV_GETNAMEINFO_T
      SIZEOF_UV_BUF_T SIZEOF_SOCKADDR_IN SIZEOF_SOCKADDR_STORAGE
      SIZEOF_ADDRINFO SIZEOF_SOCKADDR_IN6
      OFFSETOF_UV_BUF_T_BASE OFFSETOF_UV_BUF_T_LEN
      OFFSETOF_SOCKADDR_IN_SIN_PORT OFFSETOF_SOCKADDR_IN_SIN_FAMILY
      OFFSETOF_ADDRINFO_AI_FLAGS OFFSETOF_ADDRINFO_AI_FAMILY
      OFFSETOF_ADDRINFO_AI_SOCKTYPE OFFSETOF_ADDRINFO_AI_PROTOCOL
      OFFSETOF_ADDRINFO_AI_ADDRLEN OFFSETOF_ADDRINFO_AI_ADDR
      OFFSETOF_ADDRINFO_AI_CANONNAME OFFSETOF_ADDRINFO_AI_NEXT
      OFFSETOF_SOCKADDR_IN6_SIN6_PORT
      SOCK_STREAM SOCK_DGRAM SOCK_RAW
      IPPROTO_TCP IPPROTO_UDP
      AI_PASSIVE AI_CANONNAME AI_NUMERICHOST AI_NUMERICSERV
      NI_NUMERICHOST NI_NUMERICSERV NI_NAMEREQD NI_DGRAM
      UV_PROCESS UV_NAMED_PIPE
      SIZEOF_UV_PROCESS_OPTIONS_T
      OFFSETOF_UV_PROCESS_OPTIONS_T_EXIT_CB
      OFFSETOF_UV_PROCESS_OPTIONS_T_FILE
      OFFSETOF_UV_PROCESS_OPTIONS_T_ARGS
      OFFSETOF_UV_PROCESS_OPTIONS_T_ENV
      OFFSETOF_UV_PROCESS_OPTIONS_T_CWD
      OFFSETOF_UV_PROCESS_OPTIONS_T_FLAGS
      OFFSETOF_UV_PROCESS_OPTIONS_T_STDIO_COUNT
      OFFSETOF_UV_PROCESS_OPTIONS_T_STDIO
      OFFSETOF_UV_PROCESS_OPTIONS_T_UID
      OFFSETOF_UV_PROCESS_OPTIONS_T_GID
      SIZEOF_UV_STDIO_CONTAINER_T
      OFFSETOF_UV_STDIO_CONTAINER_T_FLAGS
      OFFSETOF_UV_STDIO_CONTAINER_T_DATA
      UV_PROCESS_SETUID UV_PROCESS_SETGID UV_PROCESS_DETACHED
      UV_IGNORE
      UV_CREATE_PIPE UV_INHERIT_FD UV_INHERIT_STREAM
      UV_READABLE_PIPE UV_WRITABLE_PIPE
      SIGTERM SIGKILL SIGINT SIGHUP SIGQUIT
      SIGUSR1 SIGUSR2 SIGCONT SIGSTOP
      UV_SIGNAL UV_ASYNC))

  (define unknown-errno-symbol 'UV_UNKNOWN)

  (define (constants-initialized?) (and snapshot #t))
  (define (constants-init-count) init-count)

  (define (require-initialized who)
    (unless snapshot
      (raise (make-uv-invalid-argument who 'constants-not-initialized))))

  ;; constant-ref : symbol -> exact-integer
  (define (constant-ref name)
    (require-initialized 'uv-constant-ref)
    (let ((cached (hashtable-ref snapshot name 'absent)))
      (if (eq? cached 'absent)
          (or (lookup (symbol->string name))
              (raise (make-uv-constant-unavailable name)))
          cached)))

  (define (snapshot-ref name)
    (require-initialized 'uv-constant-snapshot-ref)
    (let ((v (hashtable-ref snapshot name 'absent)))
      (if (eq? v 'absent)
          (raise (make-uv-constant-unavailable name))
          v)))

  ;; constants-init! : procedure procedure procedure procedure -> unspecified
  ;; Build into locals and publish the immutable snapshot last, so failure
  ;; cannot expose partial initialization.
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
          (set! snapshot (hashtable-copy table))
          (set! init-count (+ init-count 1))))))

  ;; build-errno-tables : procedure procedure procedure
  ;;                      -> (values (listof symbol) hashtable hashtable)
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

  ;; errno-symbols : -> (listof symbol)
  ;; Return a fresh list so callers cannot mutate the stored enumeration.
  (define (errno-symbols)
    (require-initialized 'uv-errno-symbols)
    (map values errno-name-list))

  ;; errno-value->symbol : exact-integer -> symbol
  ;; Unknown numeric errors retain a stable UV_UNKNOWN discriminant.
  (define (errno-value->symbol n)
    (require-initialized 'uv-errno-value->symbol)
    (hashtable-ref errno-value-table n unknown-errno-symbol))

  (define (errno-symbol->value sym)
    (require-initialized 'uv-errno-symbol->value)
    (let ((v (hashtable-ref errno-symbol-table sym 'absent)))
      (if (eq? v 'absent)
          (raise (make-uv-constant-unavailable sym))
          v)))

  (define (uv-run-default) (snapshot-ref 'UV_RUN_DEFAULT))
  (define (uv-run-once)    (snapshot-ref 'UV_RUN_ONCE))
  (define (uv-run-nowait)  (snapshot-ref 'UV_RUN_NOWAIT))

  (define (uv-eof)         (snapshot-ref 'UV_EOF))
  (define (af-inet)        (snapshot-ref 'AF_INET))
  (define (af-unspec)      (snapshot-ref 'AF_UNSPEC))
  (define (af-inet6)       (snapshot-ref 'AF_INET6))
  (define (uv-tcp-type)    (snapshot-ref 'UV_TCP))
  (define (uv-timer-type)  (snapshot-ref 'UV_TIMER))

  (define (uv-write-req-type)    (snapshot-ref 'UV_WRITE))
  (define (uv-connect-req-type)  (snapshot-ref 'UV_CONNECT))
  (define (uv-shutdown-req-type) (snapshot-ref 'UV_SHUTDOWN))
  (define (uv-getaddrinfo-req-type) (snapshot-ref 'UV_GETADDRINFO))
  (define (uv-getnameinfo-req-type) (snapshot-ref 'UV_GETNAMEINFO))

  (define (sizeof-uv-loop-t)     (snapshot-ref 'SIZEOF_UV_LOOP_T))
  (define (sizeof-uv-tcp-t)      (snapshot-ref 'SIZEOF_UV_TCP_T))
  (define (sizeof-uv-timer-t)    (snapshot-ref 'SIZEOF_UV_TIMER_T))
  (define (sizeof-uv-write-t)    (snapshot-ref 'SIZEOF_UV_WRITE_T))
  (define (sizeof-uv-connect-t)  (snapshot-ref 'SIZEOF_UV_CONNECT_T))
  (define (sizeof-uv-shutdown-t) (snapshot-ref 'SIZEOF_UV_SHUTDOWN_T))
  (define (sizeof-uv-buf-t)      (snapshot-ref 'SIZEOF_UV_BUF_T))
  (define (sizeof-sockaddr-in)      (snapshot-ref 'SIZEOF_SOCKADDR_IN))
  (define (sizeof-sockaddr-storage) (snapshot-ref 'SIZEOF_SOCKADDR_STORAGE))
  (define (sizeof-uv-getaddrinfo-t) (snapshot-ref 'SIZEOF_UV_GETADDRINFO_T))
  (define (sizeof-uv-getnameinfo-t) (snapshot-ref 'SIZEOF_UV_GETNAMEINFO_T))
  (define (sizeof-addrinfo)         (snapshot-ref 'SIZEOF_ADDRINFO))
  (define (sizeof-sockaddr-in6)     (snapshot-ref 'SIZEOF_SOCKADDR_IN6))

  (define (offsetof-uv-buf-t-base) (snapshot-ref 'OFFSETOF_UV_BUF_T_BASE))
  (define (offsetof-uv-buf-t-len)  (snapshot-ref 'OFFSETOF_UV_BUF_T_LEN))
  (define (offsetof-sockaddr-in-sin-port)
    (snapshot-ref 'OFFSETOF_SOCKADDR_IN_SIN_PORT))
  (define (offsetof-sockaddr-in-sin-family)
    (snapshot-ref 'OFFSETOF_SOCKADDR_IN_SIN_FAMILY))

  ;; addrinfo field order differs across supported platforms.
  (define (offsetof-addrinfo-ai-flags)
    (snapshot-ref 'OFFSETOF_ADDRINFO_AI_FLAGS))
  (define (offsetof-addrinfo-ai-family)
    (snapshot-ref 'OFFSETOF_ADDRINFO_AI_FAMILY))
  (define (offsetof-addrinfo-ai-socktype)
    (snapshot-ref 'OFFSETOF_ADDRINFO_AI_SOCKTYPE))
  (define (offsetof-addrinfo-ai-protocol)
    (snapshot-ref 'OFFSETOF_ADDRINFO_AI_PROTOCOL))
  (define (offsetof-addrinfo-ai-addrlen)
    (snapshot-ref 'OFFSETOF_ADDRINFO_AI_ADDRLEN))
  (define (offsetof-addrinfo-ai-addr)
    (snapshot-ref 'OFFSETOF_ADDRINFO_AI_ADDR))
  (define (offsetof-addrinfo-ai-canonname)
    (snapshot-ref 'OFFSETOF_ADDRINFO_AI_CANONNAME))
  (define (offsetof-addrinfo-ai-next)
    (snapshot-ref 'OFFSETOF_ADDRINFO_AI_NEXT))
  (define (offsetof-sockaddr-in6-sin6-port)
    (snapshot-ref 'OFFSETOF_SOCKADDR_IN6_SIN6_PORT))

  (define (sock-stream) (snapshot-ref 'SOCK_STREAM))
  (define (sock-dgram)  (snapshot-ref 'SOCK_DGRAM))
  (define (sock-raw)    (snapshot-ref 'SOCK_RAW))

  (define (ipproto-tcp) (snapshot-ref 'IPPROTO_TCP))
  (define (ipproto-udp) (snapshot-ref 'IPPROTO_UDP))

  ;; uv-tcp-reuseport : -> exact-integer
  ;; The UV_TCP_REUSEPORT bind flag. Looked up LAZILY via constant-ref rather
  ;; than the eager snapshot, and deliberately absent from snapshot-names: a
  ;; libuv older than 1.49.0 supports the rest of this binding but lacks the
  ;; flag, and putting it in the snapshot would fail the whole init there. This
  ;; way that libuv works normally and only a caller who actually asks for
  ;; reuseport gets &uv-constant-unavailable naming UV_TCP_REUSEPORT.
  (define (uv-tcp-reuseport) (constant-ref 'UV_TCP_REUSEPORT))

  (define (ai-passive)     (snapshot-ref 'AI_PASSIVE))
  (define (ai-canonname)   (snapshot-ref 'AI_CANONNAME))
  (define (ai-numerichost) (snapshot-ref 'AI_NUMERICHOST))
  (define (ai-numericserv) (snapshot-ref 'AI_NUMERICSERV))

  (define (ni-numerichost) (snapshot-ref 'NI_NUMERICHOST))
  (define (ni-numericserv) (snapshot-ref 'NI_NUMERICSERV))
  (define (ni-namereqd)    (snapshot-ref 'NI_NAMEREQD))
  (define (ni-dgram)       (snapshot-ref 'NI_DGRAM))

  (define (uv-process-type)    (snapshot-ref 'UV_PROCESS))
  (define (uv-named-pipe-type) (snapshot-ref 'UV_NAMED_PIPE))

  (define (uv-signal-type) (snapshot-ref 'UV_SIGNAL))
  (define (uv-async-type)  (snapshot-ref 'UV_ASYNC))

  (define (sizeof-uv-process-options-t) (snapshot-ref 'SIZEOF_UV_PROCESS_OPTIONS_T))

  (define (offsetof-uv-process-options-t-exit-cb)
    (snapshot-ref 'OFFSETOF_UV_PROCESS_OPTIONS_T_EXIT_CB))
  (define (offsetof-uv-process-options-t-file)
    (snapshot-ref 'OFFSETOF_UV_PROCESS_OPTIONS_T_FILE))
  (define (offsetof-uv-process-options-t-args)
    (snapshot-ref 'OFFSETOF_UV_PROCESS_OPTIONS_T_ARGS))
  (define (offsetof-uv-process-options-t-env)
    (snapshot-ref 'OFFSETOF_UV_PROCESS_OPTIONS_T_ENV))
  (define (offsetof-uv-process-options-t-cwd)
    (snapshot-ref 'OFFSETOF_UV_PROCESS_OPTIONS_T_CWD))
  (define (offsetof-uv-process-options-t-flags)
    (snapshot-ref 'OFFSETOF_UV_PROCESS_OPTIONS_T_FLAGS))
  (define (offsetof-uv-process-options-t-stdio-count)
    (snapshot-ref 'OFFSETOF_UV_PROCESS_OPTIONS_T_STDIO_COUNT))
  (define (offsetof-uv-process-options-t-stdio)
    (snapshot-ref 'OFFSETOF_UV_PROCESS_OPTIONS_T_STDIO))
  (define (offsetof-uv-process-options-t-uid)
    (snapshot-ref 'OFFSETOF_UV_PROCESS_OPTIONS_T_UID))
  (define (offsetof-uv-process-options-t-gid)
    (snapshot-ref 'OFFSETOF_UV_PROCESS_OPTIONS_T_GID))

  (define (sizeof-uv-stdio-container-t) (snapshot-ref 'SIZEOF_UV_STDIO_CONTAINER_T))

  (define (offsetof-uv-stdio-container-t-flags)
    (snapshot-ref 'OFFSETOF_UV_STDIO_CONTAINER_T_FLAGS))
  (define (offsetof-uv-stdio-container-t-data)
    (snapshot-ref 'OFFSETOF_UV_STDIO_CONTAINER_T_DATA))

  (define (uv-process-setuid-flag)   (snapshot-ref 'UV_PROCESS_SETUID))
  (define (uv-process-setgid-flag)   (snapshot-ref 'UV_PROCESS_SETGID))
  (define (uv-process-detached-flag) (snapshot-ref 'UV_PROCESS_DETACHED))

  (define (uv-stdio-ignore)        (snapshot-ref 'UV_IGNORE))
  (define (uv-stdio-create-pipe)   (snapshot-ref 'UV_CREATE_PIPE))
  (define (uv-stdio-inherit-fd)    (snapshot-ref 'UV_INHERIT_FD))
  (define (uv-stdio-inherit-stream) (snapshot-ref 'UV_INHERIT_STREAM))
  (define (uv-stdio-readable-pipe) (snapshot-ref 'UV_READABLE_PIPE))
  (define (uv-stdio-writable-pipe) (snapshot-ref 'UV_WRITABLE_PIPE))

  (define (sig-term) (snapshot-ref 'SIGTERM))
  (define (sig-kill) (snapshot-ref 'SIGKILL))
  (define (sig-int)  (snapshot-ref 'SIGINT))
  (define (sig-hup)  (snapshot-ref 'SIGHUP))
  (define (sig-quit) (snapshot-ref 'SIGQUIT))
  (define (sig-usr1) (snapshot-ref 'SIGUSR1))
  (define (sig-usr2) (snapshot-ref 'SIGUSR2))
  (define (sig-cont) (snapshot-ref 'SIGCONT))
  (define (sig-stop) (snapshot-ref 'SIGSTOP)))
