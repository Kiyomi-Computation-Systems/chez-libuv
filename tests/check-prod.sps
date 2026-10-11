#!r6rs
;; check-prod.sps: fail if the shim that survived to the end of `make prod`
;; still carries -DCHEZ_LIBUV_DEBUG_COUNTERS.
;;
;; WHY THIS EXISTS. `prod` and `build` write the SAME artifact path
;; ($(SHIM)), and the only difference between them is which CFLAGS the last
;; link used. Unguarded, that makes the release artifact a function of
;; command history rather than of the command run: `make prod && make test
;; && package` would package a DEV shim, because `test` depends on `build`
;; and `build` relinks. The Makefile stamps the flavor (build/.flavor-dev vs
;; build/.flavor-prod) so a flip forces a relink, and this program is the
;; behavioural half of that guard -- a check rather than a comment, and one
;; that reads the artifact instead of trusting the stamp.
;;
;; THE OBSERVABLE. src/libuv-shim.c compiles chez_uv_live_* two ways: with
;; -DCHEZ_LIBUV_DEBUG_COUNTERS they report the live count of each
;; allocation class, and without it every one of them is a `return 0`. So a
;; prod shim answers all-zero counters even while a loop and a TCP handle are
;; demonstrably alive, and a dev shim cannot: it has at least one live loop
;; and one live tcp at that instant. This is tests/test-lifecycle.sps's "seed:
;; an open tcp handle is live in the counters" pointed the other way -- that
;; assertion gates the dev artifact, this program gates the prod one.
;;
;; THE SCOPE HAS TO BE PROVABLY LIVE, or all-zero counters would also be what
;; a probe that never allocated anything reports: a pass must rest on values
;; only success can produce. Two witnesses that do not go through the
;; counters at all establish it, both from the PUBLIC API: the handle answers
;; a real ephemeral port through uv_tcp_getsockname, and the loop's own
;; live-handle snapshot holds it. A failure before either of those is
;; reported as a failure, never as a pass.
;;
;; Deliberately named OUTSIDE the tests/test-*.sps wildcard: `make test` must
;; not run it, because it demands the opposite artifact from the dev suites'
;; counter rows.
(import (rnrs)
        (libuv)
        ;; The counters are private and dev-only by design; this program
        ;; exists precisely to observe that a release build does NOT report
        ;; them, so it is the one caller that reads them from outside the
        ;; test suites.
        (only (libuv private native) live-counts))

(define (say . parts)
  (for-each (lambda (p) (if (string? p) (display p) (write p))) parts)
  (newline))

(define (fail . parts)
  (apply say "check-prod: FAIL: " parts)
  (exit 1))

;; 'unset is what a probe whose body never ran leaves behind; no successful
;; path can produce it.
(define during 'unset)
(define port 'unset)
(define live 'unset)

(guard (e (#t (say "check-prod: FAIL: the probe raised before it could observe the counters:")
              (write e)
              (newline)
              (exit 1)))
  (let* ((loop (make-uv-loop))
         (tcp (make-uv-tcp loop)))
    (uv-tcp-bind! tcp "127.0.0.1" 0)
    (set! port (uv-tcp-getsockname-port tcp))
    (set! live (length (uv-loop-live-handles loop)))
    (set! during (live-counts))
    (uv-loop-teardown! loop)))

(cond
  ((not (and (integer? port) (positive? port)))
   (fail "the probe never had a live scope -- no ephemeral port was bound: " port))
  ((not (and (integer? live) (positive? live)))
   (fail "the probe never had a live scope -- the loop held no live handle: " live))
  ((not (pair? during))
   (fail "the probe body never ran; nothing was observed: " during))
  ((for-all (lambda (p) (zero? (cdr p))) during)
   (say "check-prod: PASS: every counter read 0 while a bound tcp handle "
        "(port " port ") was live on the loop; the shim is a prod "
        "(counters-free) build")
   (exit 0))
  (else
   (say "check-prod: FAIL: the counters moved while the probe's scope was live: "
        during)
   (say "The shim was linked with dev flags (-DCHEZ_LIBUV_DEBUG_COUNTERS).")
   (say "Run `make prod` -- or `make build FLAVOR=prod` -- and try again.")
   (exit 1)))
