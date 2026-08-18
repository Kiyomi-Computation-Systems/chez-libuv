#!r6rs
;;; SRFI-64 suite for the (libuv) facade -- design spec S3's module layout
;;; ("src/libuv.sls  # (libuv) facade: re-exports + uv-version(-compatible?)").
;;;
;;; This suite imports (libuv) and NOTHING ELSE from this project that could
;;; supply one of the facade's own names, and that is its whole point: every
;;; name it uses has to be re-exported by the facade itself. A test that also
;;; imported (libuv loop) or (libuv private conditions) would keep passing
;;; after an export was dropped from src/libuv.sls, because Chez would
;;; resolve the name from the other import -- so the export list would be
;;; guarded by nothing at all.
;;;
;;; The ONE exception is renamed on the way in: `libuv-packed-version` is
;;; (libuv private native)'s uv_version(), and it exists here only so the
;;; facade's uv-version string can be checked against a SECOND source rather
;;; than against itself. It is renamed precisely so it cannot stand in for a
;;; facade export that went missing.
;;;
;;; The failure is at EXPAND time (an unbound identifier), which is a suite
;;; that fails outright rather than an assertion that fails by name. That is
;;; the strongest check available for a re-export list, and it is why the
;;; facade's own procedures (uv-version, uv-version-compatible?) get ordinary
;;; assertions below while the re-exports get exercised instead.
;;;
;;; NOT pure: the facade reaches (libuv private native). Never add this to
;;; the Makefile's PURE_TESTS.
(import (rnrs)
        (srfi :64)
        (libuv)
        (rename (only (libuv private native) uv-version)
                (uv-version libuv-packed-version)))

(define runner (test-runner-simple))
(test-runner-current runner)

(test-begin "facade")

;; --- uv-version ---------------------------------------------------------
(define version (uv-version))

(test-equal "uv-version returns a non-empty string"
  'non-empty-string
  (if (and (string? version) (positive? (string-length version)))
      'non-empty-string
      'not-a-version-string))

;; Cross-check against uv_version()'s packed integer -- a different libuv
;; entry point, reached without going through the facade -- so this is two
;; sources agreeing rather than one source restating itself: a facade that
;; returned a hard-coded or stale string fails here. The comparison is on the
;; "major.minor." prefix, because uv_version_string may carry a pre-release
;; suffix that uv_version()'s patch byte does not describe.
(define packed (libuv-packed-version))

(define expected-prefix
  (string-append (number->string (div packed 65536)) "."
                 (number->string (mod (div packed 256) 256)) "."))

(test-equal "uv-version's string agrees with uv_version()'s major.minor"
  expected-prefix
  (if (>= (string-length version) (string-length expected-prefix))
      (substring version 0 (string-length expected-prefix))
      'string-too-short))

(test-equal "uv_version() reports a version inside libuv's 1.x series"
  1 (div packed 65536))

(test-equal "this shim and this libuv are reported compatible"
  'compatible (if (uv-version-compatible?) 'compatible 'incompatible))

;; --- the re-exported loop surface, driven through the facade alone ------
(define l (make-uv-loop))

(test-equal "a loop made through the facade is open"
  'open (if (uv-loop-open? l) 'open 'not-open))

(test-equal "uv-loop? is re-exported and accepts the loop"
  'a-loop (if (uv-loop? l) 'a-loop 'not-a-loop))

(test-equal "uv-run is re-exported and reports no work on an empty loop"
  'no-work (if (uv-run l 'nowait) 'work 'no-work))

(test-equal "uv-loop-alive? is re-exported"
  'not-alive (if (uv-loop-alive? l) 'alive 'not-alive))

(test-equal "uv-now is re-exported and answers with a positive timestamp"
  'positive (if (positive? (uv-now l)) 'positive 'not-positive))

(test-equal "uv-loop-live-handles is re-exported"
  '() (uv-loop-live-handles l))

(test-equal "uv-loop-deferred-errors is re-exported"
  '() (uv-loop-deferred-errors l))

(test-equal "uv-stop! is re-exported"
  'stopped
  (guard (e (#t (list 'raised e)))
    (uv-stop! l)
    'stopped))

(uv-loop-teardown! l)

(test-equal "uv-loop-teardown! is re-exported and closes the loop"
  'not-open (if (uv-loop-open? l) 'open 'not-open))

;; --- the re-exported condition hierarchy --------------------------------
;; Predicates and accessors both, on a condition the facade's own procedures
;; raise: the type, its predicate, and its field accessors all have to come
;; through the facade for this to expand and pass.
(test-equal "a closed loop raises the re-exported &uv-handle-closed, kind 'loop"
  'loop
  (guard (e ((uv-handle-closed? e) (uv-handle-closed-kind e))
            (#t 'wrong-condition))
    (uv-run l 'nowait)
    'no-raise))

(test-equal "the re-exported uv-error? catches the whole family"
  'uv-error
  (guard (e ((uv-error? e) 'uv-error) (#t 'wrong-condition))
    (uv-now l)
    'no-raise))

(test-equal "uv-invalid-argument?, its who and its reason are re-exported"
  '(uv-run not-a-uv-loop)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-run 'not-a-loop 'nowait)
    'no-raise))

;; Constructors and the remaining accessors, exercised directly -- these are
;; the ones a caller needs in order to build the conditions this binding
;; hands to asynchronous callbacks (design spec S9).
(test-equal "the re-exported condition constructors and accessors round-trip"
  '(ECONNRESET -104 "connection reset by peer" tcp "/nope" 1 2 uv-write! bad-span)
  (let ((errno-e (make-uv-errno-error 'ECONNRESET -104 "connection reset by peer"))
        (closed-e (make-uv-handle-closed 'tcp))
        (shim-e (make-uv-shim-unavailable "/nope"))
        (version-e (make-uv-version-incompatible 1 2))
        (arg-e (make-uv-invalid-argument 'uv-write! 'bad-span)))
    (list (uv-errno-error-errno errno-e)
          (uv-errno-error-code errno-e)
          (uv-errno-error-message errno-e)
          (uv-handle-closed-kind closed-e)
          (uv-shim-unavailable-path shim-e)
          (uv-version-incompatible-compiled version-e)
          (uv-version-incompatible-runtime version-e)
          (uv-invalid-argument-who arg-e)
          (uv-invalid-argument-reason arg-e))))

(test-equal "&uv-callback-error and &uv-constant-unavailable are re-exported"
  '(the-cause UV_NOPE)
  (let ((cb (make-uv-callback-error 'the-cause))
        (cu (make-uv-constant-unavailable 'UV_NOPE)))
    (list (if (uv-callback-error? cb) (uv-callback-error-cause cb) 'not-a-callback-error)
          (if (uv-constant-unavailable? cu)
              (uv-constant-unavailable-name cu)
              'not-a-constant-unavailable))))

;; --- call-with-uv-loop, through the facade ------------------------------
(test-equal "call-with-uv-loop is re-exported and returns the body's value"
  'body-value
  (call-with-uv-loop (lambda (loop) (uv-run loop 'nowait) 'body-value)))

(test-end "facade")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
