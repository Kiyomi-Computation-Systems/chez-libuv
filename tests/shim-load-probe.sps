#!r6rs
;;; Helper for tests/test-shim-loading.sps -- deliberately NOT itself a test
;;; suite: the filename does not match tests/test-*.sps, so `make test`'s
;;; wildcard never runs it directly, and `make check-purity`'s PURE_TESTS
;;; wildcard never sees it either.
;;;
;;; (libuv private native) resolves and loads libuv plus the shim exactly
;;; once per process, while its library body is evaluated -- which is the
;;; whole point of design spec S4 rule 3 (load-shared-object is a definition
;;; placed ahead of every foreign-procedure binding, because Chez resolves an
;;; entry point when the defining expression is EVALUATED). Chez defers that
;;; instantiation until the first use of one of the library's bindings, and a
;;; `guard` wrapped around that first use does not catch a resolution failure:
;;; the exception is raised before the guard's dynamic extent begins. So a
;;; second, different CHEZ_LIBUV_SHIM value cannot be exercised inside a
;;; process that has already resolved one; this file is spawned fresh, once
;;; per value under test, by tests/test-shim-loading.sps.
;;;
;;; Exit 0 means the shim resolved, loaded, and the full init gate
;;; (version range + constants snapshot + uv_buf_t layout validation) passed.
;;; Any non-zero exit means it did not; the parent also inspects this
;;; process's stderr to confirm a bad path fails with the structured
;;; &uv-shim-unavailable condition rather than a raw dlopen error leaking
;;; through.
;;;
;;; The marker on stdout distinguishes "reached the end successfully" from
;;; "exited 0 without ever running" -- a sentinel no failure path produces.
(import (rnrs) (libuv private native))
(ensure-native-loaded!)
(display "PROBE-OK: native loaded and initialised")
(newline)
(exit 0)
