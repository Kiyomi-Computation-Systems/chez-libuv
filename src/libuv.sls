#!r6rs
;;; (libuv) -- the facade a consumer imports. Design spec S3:
;;; "src/libuv.sls  # (libuv) facade: re-exports + uv-version(-compatible?)".
;;;
;;; Everything here is either a re-export of a public library's binding or
;;; one of the two version queries below. No pointer, no raw uv_* symbol, and
;;; no private binding crosses this line: (libuv private native),
;;; (libuv private handles), and (libuv private constants) are imported only
;;; so that the version queries can be expressed, and only the four names
;;; they need are taken from them.
;;;
;;; (libuv handle) and (libuv timer) landed with Stage 3; (libuv tcp)'s write
;;; path landed with Stage 4 and its read path with Stage 5; (libuv dns)
;;; landed with the v0.2 milestone. The list is
;;; deliberately written out by name rather than re-exported wholesale: a
;;; facade that exported whatever its imports happened to have would leak a
;;; private binding the day someone added one.
(library (libuv)
  (export ;; --- the event loop, from (libuv loop) ---
          make-uv-loop uv-loop? uv-loop-open?
          uv-run uv-stop! uv-loop-alive? uv-now
          uv-loop-live-handles uv-loop-deferred-errors
          uv-loop-close! uv-loop-teardown! call-with-uv-loop

          ;; --- handles, from (libuv handle) ---
          ;; There is no uv-handle-closed? state predicate: that name belongs
          ;; to &uv-handle-closed's condition predicate, four lines below.
          ;; (libuv handle) explains the split; the third state is read with
          ;; uv-handle-state. uv-pipe? and uv-process? live in (libuv handle)
          ;; beside uv-tcp?.
          uv-handle? uv-timer? uv-tcp? uv-pipe? uv-process?
          uv-handle-open? uv-handle-closing? uv-handle-state
          uv-handle-loop uv-close!

          ;; --- timers, from (libuv timer) ---
          make-uv-timer
          uv-timer-start! uv-timer-stop! uv-timer-again!
          uv-timer-repeat uv-timer-set-repeat!

          ;; --- TCP, from (libuv tcp) ---
          ;; Both halves: the write path of design spec S7 and the read path
          ;; of S6. uv-tcp? and uv-close! are already above, in the handle
          ;; block: they are generic over handle types by design, and a
          ;; second TCP-specific spelling of either would be a second thing
          ;; to keep in step. The four stream verbs below originate in
          ;; (libuv stream) and are re-exported by (libuv tcp).
          make-uv-tcp
          uv-tcp-bind! uv-tcp-getsockname-port
          uv-listen! uv-accept! uv-tcp-connect!
          uv-write! uv-shutdown! uv-tcp-nodelay!
          uv-read-start! uv-read-stop!

          ;; --- DNS, from (libuv dns) ---
          ;; The v0.2 surface (design spec v0.2 S4.6): both start calls,
          ;; the cancel verb, its domain predicate, and the uv-addrinfo
          ;; record -- constructor included, for the same reason the
          ;; condition constructors below are public: the record is pure
          ;; data, and a caller's test double is legitimate. (libuv dns)
          ;; already re-exports the record API from (libuv private
          ;; addrinfo), so no private library is imported for this block.
          ;; addrinfo-chain->list is (libuv dns)'s test seam and
          ;; deliberately does NOT cross this line.
          uv-getaddrinfo! uv-getnameinfo! uv-cancel! uv-dns-request?
          make-uv-addrinfo uv-addrinfo?
          uv-addrinfo-family uv-addrinfo-socktype uv-addrinfo-protocol
          uv-addrinfo-address uv-addrinfo-port uv-addrinfo-canonname

          ;; --- Pipe, from (libuv pipe) ---
          ;; Minimal by design (v0.3): a pipe exists to be consumed by
          ;; uv-spawn!'s (pipe p dir) stdio spec. Stream verbs above accept
          ;; it once connected; uv-close! is the generic one.
          make-uv-pipe

          ;; --- Process, from (libuv process) ---
          ;; uv-spawn! options/stdio vocabulary: THE SPEC §4.2-§4.3.
          ;; EXIT IS NOT CLOSE: on-exit fires, the handle still needs
          ;; uv-close! (ADR-0007). Killed-by-signal arrives as (0 'sig...).
          uv-spawn! uv-process-kill! uv-kill! uv-process-pid uv-os-getpid

          ;; --- version queries (this library's own) ---
          ;; Exactly the two design spec S3 scopes this facade to
          ;; ("re-exports + uv-version(-compatible?)"). The packed integer
          ;; uv_version() returns stays private: a public packed-version API
          ;; is a deliberate addition to make when something asks for it, not
          ;; a by-product of needing it for a test.
          uv-version uv-version-compatible?

          ;; --- the condition hierarchy, from (libuv private conditions) ---
          ;; Callers need the predicates to discriminate, the accessors to
          ;; read the fields, and the constructors because these same records
          ;; are what a caller's own on-error callback may want to build or
          ;; re-raise (design spec S9).
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
          uv-callback-error-cause)
  (import (rnrs)
          (libuv loop)
          (libuv handle)
          (libuv timer)
          (libuv tcp)
          (libuv stream)
          (libuv pipe)
          (libuv process)
          (libuv dns)
          (libuv private conditions)
          ;; uv-version is renamed on the way in purely to resolve a name
          ;; clash: this library exports a procedure of the same name with a
          ;; different contract (the version STRING, not the packed int).
          ;; The packed int itself is NOT re-exported -- see the export list
          ;; above, which says why.
          (rename (only (libuv private native)
                        ensure-native-loaded! uv-version uv-version-string
                        shim-compiled-version version-compatible?)
                  (uv-version raw-uv-version)))

  ;; Every one of these forces the init gate first: a caller may reasonably
  ;; ask what libuv is present before creating anything, and the gate is what
  ;; guarantees the answer comes from a library this binding has validated
  ;; (design spec S4).

  ;; The running libuv's own version string, copied at the boundary
  ;; (ADR-0009) -- "1.52.1". The string, not libuv's packed integer, because
  ;; this is the human-facing answer: it can carry a pre-release suffix the
  ;; packed form has no room for. A caller comparing against a floor wants
  ;; the integer instead, and can have it when something actually needs it.
  (define (uv-version)
    (ensure-native-loaded!)
    (uv-version-string))

  ;; Whether the shim's compile-time libuv and the runtime libuv both fall
  ;; inside the range this build declares supported. Not an equality test:
  ;; libuv guarantees ABI stability across 1.x, so a patch upgrade under an
  ;; unchanged shim is compatible by design (native.sls's version gate).
  ;;
  ;; ensure-native-loaded! would already have RAISED
  ;; &uv-version-incompatible on an unsupported pair, so a caller reaching
  ;; this procedure normally gets #t; it exists so a caller can ASK, under
  ;; their own guard, rather than discovering it by having a handle
  ;; constructor fail.
  (define (uv-version-compatible?)
    (ensure-native-loaded!)
    (version-compatible? (shim-compiled-version) (raw-uv-version))))
