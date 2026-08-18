#!r6rs
;;; Structured conditions for chez-libuv.
;;;
;;; Every failure this binding can produce -- whether raised synchronously
;;; from a procedure that fails immediately, or delivered as a plain object
;;; to an asynchronous callback (`on-error`, `on-complete`'s `err` argument,
;;; design spec S8) -- is one of these, so callers never see a raw FFI
;;; integer or a bare libuv errno. All of them derive from &uv-error, which
;;; lets a caller catch the whole family or discriminate precisely; &uv-error
;;; itself is the only one that derives from &error directly (design spec
;;; S9).
;;;
;;; This library imports (rnrs) ONLY, and must never import
;;; (libuv private native) or anything that loads the shim -- it has to
;;; stay loadable with no shim present, since `make check-purity` runs
;;; tests/test-conditions.sps with CHEZ_LIBUV_SHIM poisoned to prove exactly
;;; that (Makefile, PURE_TESTS).
(library (libuv private conditions)
  (export &uv-error make-uv-error uv-error?

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
  (import (rnrs))

  (define-condition-type &uv-error &error
    make-uv-error uv-error?)

  ;; --- &uv-errno-error ---------------------------------------------------
  ;; errno is the portable symbol from uv_err_name_r ('ECONNRESET, ...) --
  ;; the discriminant callers are expected to branch on (ADR-0006). code is
  ;; the raw platform int, preserved only for logging/diagnostics, never as
  ;; the primary discriminant. message is uv_strerror_r's human-readable
  ;; text. errno lives here, not on &uv-error itself: a root-level field
  ;; meaningful for some subtypes and absent or meaningless for others is
  ;; exactly the truthiness trap AGENTS.md documents for accessor results in
  ;; general (design spec S9).
  (define-condition-type &uv-errno-error &uv-error
    make-uv-errno-error uv-errno-error?
    (errno   uv-errno-error-errno)
    (code    uv-errno-error-code)
    (message uv-errno-error-message))

  ;; --- &uv-handle-closed -------------------------------------------------
  ;; kind is a symbol: 'tcp, 'timer, 'loop -- the handle family whose
  ;; already-closed state was touched.
  (define-condition-type &uv-handle-closed &uv-error
    make-uv-handle-closed uv-handle-closed?
    (kind uv-handle-closed-kind))

  ;; --- &uv-shim-unavailable ----------------------------------------------
  ;; Raised when the native shim cannot be loaded at the configured path
  ;; (config.sls's shim-path).
  (define-condition-type &uv-shim-unavailable &uv-error
    make-uv-shim-unavailable uv-shim-unavailable?
    (path uv-shim-unavailable-path))

  ;; --- &uv-version-incompatible ------------------------------------------
  ;; Raised at initialisation when the shim's compile-time version and the
  ;; runtime libuv disagree beyond the supported range (design spec S9,
  ;; Makefile's UV_RANGE_LO/UV_RANGE_HI). Both fields are packed version
  ;; ints in the same encoding config.sls uses.
  (define-condition-type &uv-version-incompatible &uv-error
    make-uv-version-incompatible uv-version-incompatible?
    (compiled uv-version-incompatible-compiled)
    (runtime  uv-version-incompatible-runtime))

  ;; --- &uv-constant-unavailable ------------------------------------------
  ;; name is a symbol naming the requested constant (e.g. 'UV_TCP_IPV6ONLY)
  ;; that the running libuv does not define. Constants are never
  ;; transcribed (ADR-0005), so a missing one is discovered at lookup time,
  ;; not compile time.
  (define-condition-type &uv-constant-unavailable &uv-error
    make-uv-constant-unavailable uv-constant-unavailable?
    (name uv-constant-unavailable-name))

  ;; --- &uv-invalid-argument ----------------------------------------------
  ;; who is a symbol naming the procedure that rejected its argument (e.g.
  ;; 'uv-loop-close!); reason is a symbol describing why (e.g.
  ;; 'loop-running-from-callback -- design spec S8, "Illegal from inside a
  ;; callback").
  (define-condition-type &uv-invalid-argument &uv-error
    make-uv-invalid-argument uv-invalid-argument?
    (who    uv-invalid-argument-who)
    (reason uv-invalid-argument-reason))

  ;; --- &uv-callback-error ------------------------------------------------
  ;; Raised on the way out of uv-run when a callback stored a pending error
  ;; (design spec S8, "store-and-reraise"). cause is the original condition
  ;; caught inside the callback. Callers construct the re-raised condition
  ;; with `(condition (make-uv-callback-error cause) cause)` so the compound
  ;; condition still satisfies a guard written against cause's own type --
  ;; this composition is load-bearing for the store-and-reraise policy, and
  ;; is exactly what R6RS's `condition` combinator is for: it is not a
  ;; behaviour this library implements itself.
  (define-condition-type &uv-callback-error &uv-error
    make-uv-callback-error uv-callback-error?
    (cause uv-callback-error-cause)))
