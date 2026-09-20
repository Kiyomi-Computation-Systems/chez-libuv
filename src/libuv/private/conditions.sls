#!r6rs
;;; Structured error vocabulary. Synchronous raises and asynchronous error
;;; values share these types, all rooted at &uv-error.
(library (libuv private conditions)
  (export &uv-error make-uv-error uv-error?

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
  (import (rnrs))

  (define-condition-type &uv-error &error
    make-uv-error uv-error?)

  ;; &uv-errno-error fields: symbol exact-integer string
  (define-condition-type &uv-errno-error &uv-error
    make-uv-errno-error uv-errno-error?
    (errno   uv-errno-error-errno)
    (code    uv-errno-error-code)
    (message uv-errno-error-message))

  ;; &uv-handle-closed field: symbol
  (define-condition-type &uv-handle-closed &uv-error
    make-uv-handle-closed uv-handle-closed?
    (kind uv-handle-closed-kind))

  ;; &uv-shim-unavailable field: string
  (define-condition-type &uv-shim-unavailable &uv-error
    make-uv-shim-unavailable uv-shim-unavailable?
    (path uv-shim-unavailable-path))

  (define-condition-type &uv-libuv-unavailable &uv-shim-unavailable
    make-uv-libuv-unavailable uv-libuv-unavailable?)

  ;; &uv-version-incompatible fields: exact-integer exact-integer
  (define-condition-type &uv-version-incompatible &uv-error
    make-uv-version-incompatible uv-version-incompatible?
    (compiled uv-version-incompatible-compiled)
    (runtime  uv-version-incompatible-runtime))

  ;; &uv-constant-unavailable field: symbol
  (define-condition-type &uv-constant-unavailable &uv-error
    make-uv-constant-unavailable uv-constant-unavailable?
    (name uv-constant-unavailable-name))

  ;; &uv-invalid-argument fields: symbol symbol
  (define-condition-type &uv-invalid-argument &uv-error
    make-uv-invalid-argument uv-invalid-argument?
    (who    uv-invalid-argument-who)
    (reason uv-invalid-argument-reason))

  ;; &uv-callback-error field: object
  (define-condition-type &uv-callback-error &uv-error
    make-uv-callback-error uv-callback-error?
    (cause uv-callback-error-cause))

  ;; &uv-wrong-thread fields: symbol exact-integer exact-integer
  ;; Raised when a loop/handle verb runs off the loop's owning thread (#20).
  ;; who is the verb; expected is the owner thread id; actual is the caller's.
  (define-condition-type &uv-wrong-thread &uv-error
    make-uv-wrong-thread uv-wrong-thread?
    (who      uv-wrong-thread-who)
    (expected uv-wrong-thread-expected)
    (actual   uv-wrong-thread-actual)))
