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
        (only (chezscheme) getenv system current-directory
              path-parent path-last load-shared-object foreign-entry?))

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
;; exit code, captured stdout, captured stderr. The libdirs are a parameter
;; so the libuv-leg cases below can resolve a synthetic
;; (libuv private config) AHEAD of the generated one.
(define (run-probe-with-libdirs libdirs shim-override)
  (let* ((prefix
          (string-append
           "unset CHEZ_LIBUV_SHIM; "
           "CHEZSCHEMELIBDIRS=" (shell-quote libdirs) " "
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

(define (run-probe shim-override)
  (run-probe-with-libdirs chez-libdirs shim-override))

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

;; A real shared library that loads cleanly but lacks the shim's exports --
;; libuv's own, here -- stands in for a shim built from older sources. Such a
;; shim used to fail the whole import with a bare "no entry for ..."
;; assertion (review of #36); every shim binding now checks its entry first.
(check-rejected "a loadable library without the shim's exports"
                (car uv-library-paths))

;; --- a shim built from older sources ---------------------------------------
;; The library above lacks every export, so it is refused at the first. A
;; consumer who upgrades without rebuilding has a shim that lacks only the
;; newest, libuv's alloc callback (#45). The Makefile's STALE_SHIM is that
;; shim: this one's source with chez_uv_alloc_cb renamed away.
(define stale-shim
  (string-append (path-parent (path-parent shim-path))
                 "/stale-shim/" (path-last shim-path)))

;; Control: the stale shim loads, and has the callback under another name
;; only. A fixture that failed to load would be refused for that reason too,
;; and would prove nothing about the missing entry.
(test-equal "control: the stale shim loads, with the alloc callback renamed away"
  '(loaded copy-in alloc-cb-absent alloc-cb-withheld)
  (guard (e (#t (list 'raised (if (message-condition? e) (condition-message e) e))))
    (for-each load-shared-object uv-library-paths)
    (load-shared-object stale-shim)
    (list 'loaded
          (if (foreign-entry? "chez_uv_copy_in") 'copy-in 'no-copy-in)
          (if (foreign-entry? "chez_uv_alloc_cb") 'alloc-cb-present 'alloc-cb-absent)
          (if (foreign-entry? "chez_uv_alloc_cb_withheld")
              'alloc-cb-withheld
              'no-withheld-alloc-cb))))

(check-rejected "a shim built before libuv's alloc callback was added" stale-shim)

(let-values (((code out err) (run-probe stale-shim)))
  (test-equal "...and the refusal names that shim"
    #t (contains? err stale-shim)))

;; --- the libuv leg, distinguished from the shim leg ----------------------
;; A synthetic (libuv private config), resolved AHEAD of the generated one
;; via CHEZSCHEMELIBDIRS, is the only seam to uv-library-paths -- there is
;; deliberately no environment override for the libuv paths. Writing one
;; whose uv-library-paths names a path that cannot exist drives the REAL
;; uv-loaded definition down its failure arm in a fresh process, which must
;; fail closed with &uv-libuv-unavailable: the SUBTYPE, whose stderr name
;; no shim-leg failure above can print (their name is the plain
;; "uv-shim-unavailable", which is not a substring of it and vice versa).
(define fake-config-dir "tests/tmp/libuv-leg-config")
(define fake-config-path
  (string-append fake-config-dir "/libuv/private/config.sls"))

(system (string-append "mkdir -p "
                       (shell-quote (string-append fake-config-dir
                                                   "/libuv/private"))))

(define (write-fake-config! libuv-paths)
  (when (file-exists? fake-config-path) (delete-file fake-config-path))
  (call-with-output-file fake-config-path
    (lambda (p)
      (write `(library (libuv private config)
                (export shim-path uv-library-paths
                        uv-supported-version-range)
                (import (rnrs))
                (define shim-path ,shim-path)
                (define uv-library-paths (quote ,libuv-paths))
                (define uv-supported-version-range
                  (quote ,uv-supported-version-range)))
             p))))

(define fake-libdirs (string-append fake-config-dir ":" chez-libdirs))

;; Positive control FIRST: the synthetic config carrying the REAL values
;; must still load and initialise. Without this, the failure rows below
;; could pass because the shadowing machinery itself is broken -- a
;; malformed library also exits non-zero.
(write-fake-config! uv-library-paths)
(let-values (((code out err) (run-probe-with-libdirs fake-libdirs #f)))
  (test-equal "control: a synthetic config with the real libuv paths still initialises (exit 0)"
    0 code)
  (test-equal "control: the probe reached the end of its body through the synthetic config"
    #t (contains? out "PROBE-OK: native loaded and initialised")))

(write-fake-config! '("/no/such/libuv-for-this-probe.so"))
(let-values (((code out err) (run-probe-with-libdirs fake-libdirs #f)))
  (test-equal "a bad libuv path: fails closed (non-zero exit)"
    #t (not (zero? code)))
  (test-equal "a bad libuv path: raises uv-libuv-unavailable, the subtype, not the shim's own type"
    #t (contains? err "uv-libuv-unavailable"))
  (test-equal "a bad libuv path: never reached the end of the probe body"
    #t (not (contains? out "PROBE-OK: native loaded and initialised"))))

(test-end "shim-loading")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
