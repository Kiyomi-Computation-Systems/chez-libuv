#!r6rs
;;; Public facade. Raw pointers and private bindings do not cross this boundary.
(library (libuv)
  (export ;; event loop
          make-uv-loop uv-loop? uv-loop-open?
          uv-run uv-stop! uv-loop-alive? uv-now uv-update-time!
          uv-loop-live-handles uv-loop-deferred-errors
          uv-loop-close! uv-loop-teardown! call-with-uv-loop

          ;; handles
          uv-handle? uv-timer? uv-tcp? uv-pipe? uv-process? uv-signal? uv-async?
          uv-handle-open? uv-handle-closing? uv-handle-state
          uv-handle-loop uv-close!
          uv-send-buffer-size uv-send-buffer-size!
          uv-recv-buffer-size uv-recv-buffer-size!

          ;; timers
          make-uv-timer
          uv-timer-start! uv-timer-stop! uv-timer-again!
          uv-timer-repeat uv-timer-set-repeat!

          ;; TCP and streams
          make-uv-tcp
          uv-tcp-bind! uv-tcp-getsockname-port
          uv-tcp-sockname-address uv-tcp-peer-address
          uv-listen! uv-accept! uv-tcp-connect!
          uv-write! uv-write*! uv-shutdown! uv-tcp-nodelay! uv-tcp-keepalive!
          uv-read-start! uv-read-stop!
          uv-stream-write-queue-size

          ;; DNS
          uv-getaddrinfo! uv-getnameinfo! uv-cancel! uv-dns-request?
          make-uv-addrinfo uv-addrinfo?
          uv-addrinfo-family uv-addrinfo-socktype uv-addrinfo-protocol
          uv-addrinfo-address uv-addrinfo-port uv-addrinfo-canonname

          ;; pipes and processes
          make-uv-pipe

          uv-spawn! uv-process-kill! uv-kill! uv-process-pid uv-os-getpid

          ;; signals
          make-uv-signal
          uv-signal-start! uv-signal-start-oneshot! uv-signal-stop!

          ;; async (cross-thread wakeup)
          make-uv-async uv-async-send!

          ;; version
          uv-version uv-version-compatible?

          ;; conditions
          &uv-error make-uv-error uv-error?

          &uv-errno-error make-uv-errno-error uv-errno-error?
          uv-errno-error-errno uv-errno-error-code uv-errno-error-message

          &uv-handle-closed make-uv-handle-closed uv-handle-closed?
          uv-handle-closed-kind

          &uv-shim-unavailable make-uv-shim-unavailable uv-shim-unavailable?
          uv-shim-unavailable-path
          &uv-libuv-unavailable make-uv-libuv-unavailable
          uv-libuv-unavailable?

          &uv-version-incompatible make-uv-version-incompatible
          uv-version-incompatible? uv-version-incompatible-compiled
          uv-version-incompatible-runtime

          &uv-constant-unavailable make-uv-constant-unavailable
          uv-constant-unavailable? uv-constant-unavailable-name

          &uv-invalid-argument make-uv-invalid-argument uv-invalid-argument?
          uv-invalid-argument-who uv-invalid-argument-reason

          &uv-callback-error make-uv-callback-error uv-callback-error?
          uv-callback-error-cause

          &uv-wrong-thread make-uv-wrong-thread uv-wrong-thread?
          uv-wrong-thread-who uv-wrong-thread-expected uv-wrong-thread-actual)
  (import (rnrs)
          (libuv loop)
          (libuv handle)
          (libuv timer)
          (libuv tcp)
          (libuv stream)
          (libuv pipe)
          (libuv process)
          (libuv signal)
          (libuv async)
          (libuv dns)
          (libuv private conditions)
          (rename (only (libuv private native)
                        ensure-native-loaded! uv-version uv-version-string
                        shim-compiled-version version-compatible?)
                  (uv-version raw-uv-version)))

  ;; uv-version : -> string
  (define (uv-version)
    (ensure-native-loaded!)
    (uv-version-string))

  ;; uv-version-compatible? : -> boolean
  (define (uv-version-compatible?)
    (ensure-native-loaded!)
    (version-compatible? (shim-compiled-version) (raw-uv-version))))
