#!r6rs
;;; SRFI-64 suite for (libuv private conditions) -- design spec S9.
;;;
;;; This is the first PURE suite in the repo: it imports no native code, so
;;; `make check-purity` runs it with CHEZ_LIBUV_SHIM poisoned to prove the
;;; &uv-* hierarchy never reaches (libuv private native).
(import (rnrs)
        (srfi :64)
        (libuv private conditions))

;; SRFI-64's default runner does not set a process exit code, so a failing
;; suite would still exit 0 and `make test` would report success. Hold the
;; runner so its fail count can drive the exit status (AGENTS.md).
(define runner (test-runner-simple))
(test-runner-current runner)

(test-begin "conditions")

;; --- &uv-error (root) ---------------------------------------------------
;; No fields; the whole point of this type is that every other &uv-* type
;; is also caught by its predicate (subtype-relationship tests, below) and
;; that it is itself an R6RS &error, not merely condition-shaped.

(test-equal "uv-error predicate accepts its own instance"
  #t
  (guard (e ((uv-error? e) #t) (#t 'wrong-condition))
    (raise (make-uv-error))
    'no-raise))

(test-equal "uv-error is an R6RS &error"
  #t
  (guard (e ((error? e) #t) (#t 'wrong-condition))
    (raise (make-uv-error))
    'no-raise))

;; --- &uv-errno-error (errno code message) -------------------------------
;; errno is the portable uv_err_name_r symbol; code is the raw platform
;; int (diagnostics only, per ADR-0006); message is uv_strerror_r's text.
;; Three distinct-typed sentinels so a field swap cannot hide behind two
;; fields sharing a type.

(test-equal "errno-error predicate accepts its own instance"
  #t
  (guard (e ((uv-errno-error? e) #t) (#t 'wrong-condition))
    (raise (make-uv-errno-error 'ESENTINEL42 424242 "sentinel-errno-message-9f3a"))
    'no-raise))

(test-equal "errno-error carries the errno symbol"
  'ESENTINEL42
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e)) (#t 'wrong-condition))
    (raise (make-uv-errno-error 'ESENTINEL42 424242 "sentinel-errno-message-9f3a"))
    'no-raise))

(test-equal "errno-error carries the raw code"
  424242
  (guard (e ((uv-errno-error? e) (uv-errno-error-code e)) (#t 'wrong-condition))
    (raise (make-uv-errno-error 'ESENTINEL42 424242 "sentinel-errno-message-9f3a"))
    'no-raise))

(test-equal "errno-error carries the message"
  "sentinel-errno-message-9f3a"
  (guard (e ((uv-errno-error? e) (uv-errno-error-message e)) (#t 'wrong-condition))
    (raise (make-uv-errno-error 'ESENTINEL42 424242 "sentinel-errno-message-9f3a"))
    'no-raise))

(test-equal "errno-error is a uv-error"
  #t
  (guard (e ((uv-error? e) #t) (#t 'wrong-condition))
    (raise (make-uv-errno-error 'ESENTINEL42 424242 "sentinel-errno-message-9f3a"))
    'no-raise))

;; --- &uv-handle-closed (kind) --------------------------------------------
;; kind is one of 'tcp | 'timer | 'loop; 'timer exercises the closed set.

(test-equal "handle-closed predicate accepts its own instance"
  #t
  (guard (e ((uv-handle-closed? e) #t) (#t 'wrong-condition))
    (raise (make-uv-handle-closed 'timer))
    'no-raise))

(test-equal "handle-closed carries the kind"
  'timer
  (guard (e ((uv-handle-closed? e) (uv-handle-closed-kind e)) (#t 'wrong-condition))
    (raise (make-uv-handle-closed 'timer))
    'no-raise))

(test-equal "handle-closed is a uv-error"
  #t
  (guard (e ((uv-error? e) #t) (#t 'wrong-condition))
    (raise (make-uv-handle-closed 'timer))
    'no-raise))

;; --- &uv-shim-unavailable (path) ------------------------------------------

(test-equal "shim-unavailable predicate accepts its own instance"
  #t
  (guard (e ((uv-shim-unavailable? e) #t) (#t 'wrong-condition))
    (raise (make-uv-shim-unavailable "/sentinel/shim/path-7c2e"))
    'no-raise))

(test-equal "shim-unavailable carries the attempted path"
  "/sentinel/shim/path-7c2e"
  (guard (e ((uv-shim-unavailable? e) (uv-shim-unavailable-path e)) (#t 'wrong-condition))
    (raise (make-uv-shim-unavailable "/sentinel/shim/path-7c2e"))
    'no-raise))

(test-equal "shim-unavailable is a uv-error"
  #t
  (guard (e ((uv-error? e) #t) (#t 'wrong-condition))
    (raise (make-uv-shim-unavailable "/sentinel/shim/path-7c2e"))
    'no-raise))

;; --- &uv-libuv-unavailable: a SUBTYPE of &uv-shim-unavailable --------------
;; The libuv shared object failing to load is a different failure from the
;; shim failing to load, but v0.1 raised both as &uv-shim-unavailable with
;; the path field as the only discriminant (README.org's condition table
;; promised a subtype consideration). The subtype keeps the old contract --
;; every uv-shim-unavailable? guard still matches -- while letting a caller
;; ask the sharper question. Deliberately NOT in the sibling matrix below:
;; it is a subtype, not a sibling, and the matrix's "own predicate only"
;; rule does not apply to it.

(test-equal "libuv-unavailable predicate accepts its own instance"
  #t
  (guard (e ((uv-libuv-unavailable? e) #t) (#t 'wrong-condition))
    (raise (make-uv-libuv-unavailable "/sentinel/libuv/path-9e4a"))
    'no-raise))

(test-equal "libuv-unavailable carries the attempted path through the inherited accessor"
  "/sentinel/libuv/path-9e4a"
  (guard (e ((uv-libuv-unavailable? e) (uv-shim-unavailable-path e))
            (#t 'wrong-condition))
    (raise (make-uv-libuv-unavailable "/sentinel/libuv/path-9e4a"))
    'no-raise))

(test-equal "libuv-unavailable IS a shim-unavailable: existing guards keep matching"
  #t
  (guard (e ((uv-shim-unavailable? e) #t) (#t 'wrong-condition))
    (raise (make-uv-libuv-unavailable "/sentinel/libuv/path-9e4a"))
    'no-raise))

(test-equal "libuv-unavailable is a uv-error"
  #t
  (guard (e ((uv-error? e) #t) (#t 'wrong-condition))
    (raise (make-uv-libuv-unavailable "/sentinel/libuv/path-9e4a"))
    'no-raise))

;; The direction that must NOT hold: a plain shim failure is not a libuv
;; failure, or the sharper predicate would be no discrimination at all.
(test-equal "a plain shim-unavailable is NOT a libuv-unavailable"
  'not-libuv
  (if (uv-libuv-unavailable? (make-uv-shim-unavailable "/sentinel/shim/path-7c2e"))
      'libuv
      'not-libuv))

;; --- &uv-version-incompatible (compiled runtime) --------------------------
;; Both fields are ints; distinct nonzero sentinels so a compiled/runtime
;; swap cannot hide behind two same-typed fields.

(test-equal "version-incompatible predicate accepts its own instance"
  #t
  (guard (e ((uv-version-incompatible? e) #t) (#t 'wrong-condition))
    (raise (make-uv-version-incompatible 730001 730002))
    'no-raise))

(test-equal "version-incompatible carries the compiled version"
  730001
  (guard (e ((uv-version-incompatible? e) (uv-version-incompatible-compiled e))
            (#t 'wrong-condition))
    (raise (make-uv-version-incompatible 730001 730002))
    'no-raise))

(test-equal "version-incompatible carries the runtime version"
  730002
  (guard (e ((uv-version-incompatible? e) (uv-version-incompatible-runtime e))
            (#t 'wrong-condition))
    (raise (make-uv-version-incompatible 730001 730002))
    'no-raise))

(test-equal "version-incompatible is a uv-error"
  #t
  (guard (e ((uv-error? e) #t) (#t 'wrong-condition))
    (raise (make-uv-version-incompatible 730001 730002))
    'no-raise))

;; --- &uv-constant-unavailable (name) --------------------------------------

(test-equal "constant-unavailable predicate accepts its own instance"
  #t
  (guard (e ((uv-constant-unavailable? e) #t) (#t 'wrong-condition))
    (raise (make-uv-constant-unavailable 'UV_SENTINEL_CONSTANT_88))
    'no-raise))

(test-equal "constant-unavailable carries the constant name"
  'UV_SENTINEL_CONSTANT_88
  (guard (e ((uv-constant-unavailable? e) (uv-constant-unavailable-name e))
            (#t 'wrong-condition))
    (raise (make-uv-constant-unavailable 'UV_SENTINEL_CONSTANT_88))
    'no-raise))

(test-equal "constant-unavailable is a uv-error"
  #t
  (guard (e ((uv-error? e) #t) (#t 'wrong-condition))
    (raise (make-uv-constant-unavailable 'UV_SENTINEL_CONSTANT_88))
    'no-raise))

;; --- &uv-invalid-argument (who reason) -------------------------------------
;; Both fields are symbols; distinct sentinels so a who/reason swap cannot
;; hide behind two same-typed fields.

(test-equal "invalid-argument predicate accepts its own instance"
  #t
  (guard (e ((uv-invalid-argument? e) #t) (#t 'wrong-condition))
    (raise (make-uv-invalid-argument 'sentinel-who-fn 'sentinel-reason-xyz))
    'no-raise))

(test-equal "invalid-argument carries who rejected the call"
  'sentinel-who-fn
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-who e))
            (#t 'wrong-condition))
    (raise (make-uv-invalid-argument 'sentinel-who-fn 'sentinel-reason-xyz))
    'no-raise))

(test-equal "invalid-argument carries the reason"
  'sentinel-reason-xyz
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e))
            (#t 'wrong-condition))
    (raise (make-uv-invalid-argument 'sentinel-who-fn 'sentinel-reason-xyz))
    'no-raise))

(test-equal "invalid-argument is a uv-error"
  #t
  (guard (e ((uv-error? e) #t) (#t 'wrong-condition))
    (raise (make-uv-invalid-argument 'sentinel-who-fn 'sentinel-reason-xyz))
    'no-raise))

;; --- &uv-callback-error (cause) --------------------------------------------
;; Standalone round-trip first, with an arbitrary sentinel cause (design
;; spec S8 never requires cause to itself be a condition -- composition
;; with a real condition is covered separately, below).

(test-equal "callback-error predicate accepts its own instance"
  #t
  (guard (e ((uv-callback-error? e) #t) (#t 'wrong-condition))
    (raise (make-uv-callback-error 'sentinel-cause-object))
    'no-raise))

(test-equal "callback-error carries its cause"
  'sentinel-cause-object
  (guard (e ((uv-callback-error? e) (uv-callback-error-cause e))
            (#t 'wrong-condition))
    (raise (make-uv-callback-error 'sentinel-cause-object))
    'no-raise))

(test-equal "callback-error is a uv-error"
  #t
  (guard (e ((uv-error? e) #t) (#t 'wrong-condition))
    (raise (make-uv-callback-error 'sentinel-cause-object))
    'no-raise))

;; A bare (non-composed) callback-error must NOT satisfy uv-errno-error?.
;; Without this, a mutation that made &uv-callback-error's cause field
;; itself count as an embedded condition component would go unnoticed, and
;; the composed-condition tests below would prove nothing distinctive.
(test-equal "a bare callback-error does not satisfy uv-errno-error?"
  #f
  (guard (e ((uv-errno-error? e) #t)
            ((uv-callback-error? e) #f)
            (#t 'wrong-condition))
    (raise (make-uv-callback-error 'sentinel-cause-object))
    'no-raise))

;; --- &uv-wrong-thread (who expected actual) --------------------------------
;; #20 (threading arc): raised when a loop/handle verb runs off the loop's
;; owning thread. who is the verb symbol; expected is the owner thread id;
;; actual is the caller's. expected and actual are both integers, so distinct
;; nonzero sentinels catch an expected/actual swap that a type check cannot.

(test-equal "wrong-thread predicate accepts its own instance"
  #t
  (guard (e ((uv-wrong-thread? e) #t) (#t 'wrong-condition))
    (raise (make-uv-wrong-thread 'sentinel-who-wt 515151 626262))
    'no-raise))

(test-equal "wrong-thread carries who was called off-thread"
  'sentinel-who-wt
  (guard (e ((uv-wrong-thread? e) (uv-wrong-thread-who e)) (#t 'wrong-condition))
    (raise (make-uv-wrong-thread 'sentinel-who-wt 515151 626262))
    'no-raise))

(test-equal "wrong-thread carries the expected (owner) thread id"
  515151
  (guard (e ((uv-wrong-thread? e) (uv-wrong-thread-expected e)) (#t 'wrong-condition))
    (raise (make-uv-wrong-thread 'sentinel-who-wt 515151 626262))
    'no-raise))

(test-equal "wrong-thread carries the actual (calling) thread id"
  626262
  (guard (e ((uv-wrong-thread? e) (uv-wrong-thread-actual e)) (#t 'wrong-condition))
    (raise (make-uv-wrong-thread 'sentinel-who-wt 515151 626262))
    'no-raise))

(test-equal "wrong-thread is a uv-error"
  #t
  (guard (e ((uv-error? e) #t) (#t 'wrong-condition))
    (raise (make-uv-wrong-thread 'sentinel-who-wt 515151 626262))
    'no-raise))

;; --- Subtype + sibling discrimination matrix -------------------------------
;; Every &uv-* type (other than the root) must satisfy uv-error? AND its own
;; predicate, and must NOT satisfy any sibling's predicate. Looping over the
;; full instances x predicates matrix covers every pair, not just the one
;; example the brief names (handle-closed vs errno-error).
;;
;; &uv-libuv-unavailable is deliberately ABSENT from this catalog: it is a
;; subtype of &uv-shim-unavailable, not a sibling, so the matrix's "own
;; predicate only" rule does not describe it. Its cross-type behaviour --
;; parent predicate matches, sharper predicate does not match the parent --
;; is asserted in its own section above.

(define sibling-catalog
  (list (list 'uv-errno-error
              (make-uv-errno-error 'EMATRIXSENTINEL 111111 "matrix-sentinel-message")
              uv-errno-error?)
        (list 'uv-handle-closed
              (make-uv-handle-closed 'loop)
              uv-handle-closed?)
        (list 'uv-shim-unavailable
              (make-uv-shim-unavailable "/matrix/sentinel/path")
              uv-shim-unavailable?)
        (list 'uv-version-incompatible
              (make-uv-version-incompatible 810001 810002)
              uv-version-incompatible?)
        (list 'uv-constant-unavailable
              (make-uv-constant-unavailable 'UV_MATRIX_SENTINEL)
              uv-constant-unavailable?)
        (list 'uv-invalid-argument
              (make-uv-invalid-argument 'matrix-who 'matrix-reason)
              uv-invalid-argument?)
        (list 'uv-callback-error
              (make-uv-callback-error 'matrix-cause)
              uv-callback-error?)
        (list 'uv-wrong-thread
              (make-uv-wrong-thread 'matrix-who 909090 818181)
              uv-wrong-thread?)))

;; Every instance must satisfy uv-error?, the family-wide predicate.
(for-each
  (lambda (entry)
    (let ((type-name (car entry))
          (instance  (cadr entry)))
      (test-equal
        (string-append "subtype relationship: " (symbol->string type-name)
                        " instance satisfies uv-error?")
        #t
        (uv-error? instance))))
  sibling-catalog)

;; Full instances x predicates matrix: a predicate returns #t only for the
;; instance of its own type, #f for every sibling's instance.
(for-each
  (lambda (inst-entry)
    (let ((inst-name (car inst-entry))
          (instance  (cadr inst-entry)))
      (for-each
        (lambda (pred-entry)
          (let* ((pred-name (car pred-entry))
                 (pred      (caddr pred-entry))
                 (expected  (eq? inst-name pred-name)))
            (test-equal
              (string-append "sibling discrimination: " (symbol->string inst-name)
                              " instance under " (symbol->string pred-name) "?")
              expected
              (pred instance))))
        sibling-catalog)))
  sibling-catalog)

;; --- Composed conditions (design spec S8, store-and-reraise) ---------------
;; `uv-run` re-raises a stored callback error wrapped as &uv-callback-error
;; *composed* with the original condition via `(condition (make-uv-callback-error
;; cause) cause)`, so a guard written against the original condition type
;; still matches. This is load-bearing for the event loop's error policy.

(test-equal "composed callback-error+errno-error satisfies uv-callback-error?"
  #t
  (guard (e ((uv-callback-error? e) #t) (#t 'wrong-condition))
    (let ((cause (make-uv-errno-error 'ECOMPOSEDSENTINEL 313131
                                       "composed-sentinel-message")))
      (raise (condition (make-uv-callback-error cause) cause)))
    'no-raise))

(test-equal "composed callback-error+errno-error also satisfies uv-errno-error?"
  #t
  (guard (e ((uv-errno-error? e) #t) (#t 'wrong-condition))
    (let ((cause (make-uv-errno-error 'ECOMPOSEDSENTINEL 313131
                                       "composed-sentinel-message")))
      (raise (condition (make-uv-callback-error cause) cause)))
    'no-raise))

(test-equal "composed condition still exposes the errno field directly"
  'ECOMPOSEDSENTINEL
  (guard (e ((uv-errno-error? e) (uv-errno-error-errno e)) (#t 'wrong-condition))
    (let ((cause (make-uv-errno-error 'ECOMPOSEDSENTINEL 313131
                                       "composed-sentinel-message")))
      (raise (condition (make-uv-callback-error cause) cause)))
    'no-raise))

(test-equal "composed condition's callback-error-cause is the original errno-error"
  'ECOMPOSEDSENTINEL
  (guard (e ((uv-callback-error? e)
             (uv-errno-error-errno (uv-callback-error-cause e)))
            (#t 'wrong-condition))
    (let ((cause (make-uv-errno-error 'ECOMPOSEDSENTINEL 313131
                                       "composed-sentinel-message")))
      (raise (condition (make-uv-callback-error cause) cause)))
    'no-raise))

(test-equal "composed condition also satisfies the family-wide uv-error?"
  #t
  (guard (e ((uv-error? e) #t) (#t 'wrong-condition))
    (let ((cause (make-uv-errno-error 'ECOMPOSEDSENTINEL 313131
                                       "composed-sentinel-message")))
      (raise (condition (make-uv-callback-error cause) cause)))
    'no-raise))

(test-end "conditions")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
