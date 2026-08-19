#!r6rs
;;; SRFI-64 suite for the real CHEZ_LIBUV_SHIM wiring in
;;; (libuv private native) -- design spec S4 rule 1 ("path resolution is
;;; validated, never searched").
;;;
;;; Why subprocesses. native.sls's shim-file / uv-loaded / shim-loaded
;;; top-level definitions run exactly once per process, while the library
;;; body is evaluated, and Chez defers that until the first use of one of its
;;; bindings -- at which point a `guard` around that first use is already too
;;; late (the raise happens before the guard's dynamic extent begins; see
;;; tests/shim-load-probe.sps). There is therefore no way to exercise a
;;; second, different CHEZ_LIBUV_SHIM value in this process, so each scenario
;;; gets a fresh `chez --program` child.
;;;
;;; What an exit code alone CANNOT show: whether a failure was the structured
;;; &uv-shim-unavailable condition design spec S4 requires, or a raw dlopen
;;; error escaping uncaught -- both exit non-zero through Chez's default
;;; handler. So every failing case also greps the child's captured stderr for
;;; the condition type's own name, which Chez's default condition report
;;; prints for a record-based condition. tests/test-native.sps additionally
;;; calls resolve-shim-path and load-shim directly, which is the precise way
;;; to check condition types; this suite exists to confirm the actual
;;; default-path/override wiring uses them, end to end, in a genuinely fresh
;;; process.
;;;
;;; Deliberately POSIX-shell-dependent (uses /bin/sh via `system`, env-var
;;; prefixes, and redirection), on the same footing as `make test-memory`'s
;;; Valgrind/DYLD_INSERT_LIBRARIES machinery. Windows is already deferred
;;; beyond v0.1 (ADR-0004); revisit if that changes.
(import (rnrs)
        (srfi :64)
        (libuv private config)   ; shim-path: a known-good absolute path
        (only (chezscheme) getenv system current-directory))

;; SRFI-64's default runner does not set a process exit code, so a failing
;; suite would still exit 0 and `make test` would report success. Hold the
;; runner so its fail count can drive the exit status (AGENTS.md).
(define runner (test-runner-simple))
(test-runner-current runner)

;; --- subprocess plumbing -------------------------------------------------
(define chez-executable (or (getenv "CHEZ") "chez"))
;; Duplicates the Makefile's CHEZ_LIBDIRS so this suite also works when run
;; directly, not only via `make test` (which already exports it).
(define chez-libdirs
  (or (getenv "CHEZSCHEMELIBDIRS") "src:tests:build/scheme-libs"))
(define probe-script "tests/shim-load-probe.sps")
(define stdout-capture "tests/tmp/shim-load-probe-stdout.txt")
(define stderr-capture "tests/tmp/shim-load-probe-stderr.txt")

(system "mkdir -p tests/tmp")

(define (shell-quote s) (string-append "\"" s "\""))

(define (read-whole-file path)
  (call-with-port (open-file-input-port path)
    (lambda (p)
      (let ((bv (get-bytevector-all p)))
        (if (eof-object? bv) "" (utf8->string bv))))))

(define (contains? haystack needle)
  (let ((hlen (string-length haystack)) (nlen (string-length needle)))
    (let loop ((i 0))
      (cond
        ((> (+ i nlen) hlen) #f)
        ((string=? (substring haystack i (+ i nlen)) needle) #t)
        (else (loop (+ i 1)))))))

;; Runs the probe in a fresh subprocess with CHEZ_LIBUV_SHIM bound to
;; shim-override, or explicitly unset when shim-override is #f -- never left
;; to whatever the ambient environment happens to hold. Returns three values:
;; exit code, captured stdout, captured stderr.
(define (run-probe shim-override)
  (let* ((prefix
          (string-append
           "unset CHEZ_LIBUV_SHIM; "
           "CHEZSCHEMELIBDIRS=" (shell-quote chez-libdirs) " "
           (if shim-override
               (string-append "CHEZ_LIBUV_SHIM=" (shell-quote shim-override) " ")
               "")))
         (cmd (string-append prefix chez-executable
                             " --program " (shell-quote probe-script)
                             " >" (shell-quote stdout-capture)
                             " 2>" (shell-quote stderr-capture))))
    (let ((code (system cmd)))
      (values code (read-whole-file stdout-capture)
                   (read-whole-file stderr-capture)))))

(test-begin "shim-loading")

;; --- positive controls, first -------------------------------------------
;; Everything below asserts a FAILURE. Without these two, a probe that could
;; never load anything at all -- or a run-probe that always failed to spawn
;; -- would satisfy the whole rest of the suite.
(let-values (((code out err) (run-probe #f)))
  (test-equal "no override: the generated config.sls path loads and initialises (exit 0)"
    0 code)
  ;; The marker proves the probe ran to completion, not merely that something
  ;; exited 0. A sentinel no failure path produces (AGENTS.md).
  (test-equal "no override: the probe reached the end of its body"
    #t (contains? out "PROBE-OK: native loaded and initialised")))

(let-values (((code out err) (run-probe shim-path)))
  (test-equal "a valid absolute override loads and initialises (exit 0)"
    0 code)
  (test-equal "a valid absolute override reached the end of the probe body"
    #t (contains? out "PROBE-OK: native loaded and initialised")))

;; --- the failure matrix --------------------------------------------------
;; Each case asserts BOTH that the child failed and that it failed with the
;; structured condition. Checking only the exit code would pass against a
;; raw dlopen error escaping uncaught, which is precisely the regression
;; design spec S4 rule 1 forbids.
(define (check-rejected label override)
  (let-values (((code out err) (run-probe override)))
    (test-equal (string-append label ": fails closed (non-zero exit)")
      #t (not (zero? code)))
    (test-equal (string-append label ": raises uv-shim-unavailable, not a raw dlopen error")
      #t (contains? err "uv-shim-unavailable"))
    (test-equal (string-append label ": never reached the end of the probe body")
      #t (not (contains? out "PROBE-OK: native loaded and initialised")))))

(check-rejected "a nonexistent override" "/no/such/path/libchezlibuv.dylib")
(check-rejected "a non-absolute override" "relative/path.dylib")
(check-rejected "a directory override" (current-directory))
(check-rejected "a non-library regular-file override"
                (string-append (current-directory) "/Makefile"))
(check-rejected "an empty override" "")

(test-end "shim-loading")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
