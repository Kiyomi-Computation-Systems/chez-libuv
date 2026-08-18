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
;;; Tasks 7-9 extend the export list with (libuv handle), (libuv timer), and
;;; (libuv tcp) as those libraries land. The list is deliberately written out
;;; by name rather than re-exported wholesale: a facade that exported
;;; whatever its imports happened to have would leak a private binding the
;;; day someone added one.
(library (libuv)
  (export ;; --- the event loop, from (libuv loop) ---
          make-uv-loop uv-loop? uv-loop-open?
          uv-run uv-stop! uv-loop-alive? uv-now
          uv-loop-live-handles uv-loop-deferred-errors
          uv-loop-close! uv-loop-teardown! call-with-uv-loop

          ;; --- version queries (this library's own) ---
          uv-version uv-version-packed uv-version-compatible?

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
          (libuv private conditions)
          ;; uv-version is renamed on the way in: this library exports a
          ;; procedure of the same name with a different contract (the
          ;; version STRING, not the packed int), and the packed int is
          ;; re-exported below under a name that says which it is.
          (rename (only (libuv private native)
                        ensure-native-loaded! uv-version uv-version-string
                        shim-compiled-version version-compatible?)
                  (uv-version raw-uv-version)))

  ;; Every one of these forces the init gate first: a caller may reasonably
  ;; ask what libuv is present before creating anything, and the gate is what
  ;; guarantees the answer comes from a library this binding has validated
  ;; (design spec S4).

  ;; The running libuv's own version string, copied at the boundary
  ;; (ADR-0009) -- "1.52.1". Distinct from uv-version-packed: the string is
  ;; what a human-facing log wants, and it may carry a pre-release suffix
  ;; that the packed integer has no room for.
  (define (uv-version)
    (ensure-native-loaded!)
    (uv-version-string))

  ;; The same version as libuv's packed integer, (major << 16 | minor << 8 |
  ;; patch) -- what a caller comparing against a floor wants, since string
  ;; comparison on dotted versions is wrong at every ten-boundary.
  (define (uv-version-packed)
    (ensure-native-loaded!)
    (raw-uv-version))

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
