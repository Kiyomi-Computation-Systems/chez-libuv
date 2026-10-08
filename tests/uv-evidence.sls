#!r6rs
;;; What a row keeps as evidence, shared by the suites: one debug counter by
;;; kind, a printable account of whatever a guard caught, and whether a
;;; memory tool runs this process.
;;;
;;; NOT pure: the counters and the blocks come from (libuv private native).
;;; Nothing here reaches (libuv private handles), so tests/test-native.sps,
;;; whose process must keep the dispatcher slots empty, can import it. The
;;; pure suites (PURE_TESTS) cannot; they import `describe` from the pure
;;; (uv-describe), which this library re-exports. tests/test-echo.sps keeps
;;; its own `live-count`, over a counter query renamed at the facade's
;;; boundary.
(library (uv-evidence)
  (export live-count describe print-actual-on-failure!
          exact-block-sizes? under-memory-tool? under-asan?)
  (import (rnrs)
          (srfi :64)
          ;; describe, re-exported: one copy for every suite.
          (uv-describe)
          (only (libuv private native) live-counts alloc-block free-block!)
          (only (chezscheme) getenv foreign-entry? foreign-procedure))

  ;; print-actual-on-failure! : test-runner -> unspecified
  ;; The simple runner prints only a failing row's title. A row that returns
  ;; its evidence when it fails needs that printed too: without it, a
  ;; one-off failure leaves nothing to diagnose (test-threading-stress's
  ;; careless pool, 2026-10-06).
  (define (print-actual-on-failure! runner)
    (let ((simple-end (test-runner-on-test-end runner)))
      (test-runner-on-test-end! runner
        (lambda (r)
          (simple-end r)
          (when (eq? (test-result-kind r) 'fail)
            (display "  actual: ")
            (write (test-result-ref r 'actual-value))
            (newline))))))

  ;; live-count : symbol -> exact-integer
  ;; One debug counter by kind. Constant 0 against a prod shim.
  (define (live-count kind) (cdr (assq kind (live-counts))))

  ;; A memory tool never hands a freed block back: Memcheck's freelist and
  ;; ASan's quarantine hold it, so a row whose seed is a block the allocator
  ;; hands back asks less under one. The memory gates say so in the
  ;; environment (CHEZ_LIBUV_UNDER_VALGRIND on Linux, ASAN_OPTIONS on
  ;; macOS), but a plain run can inherit ASAN_OPTIONS from a shell, and
  ;; would then ask less for nothing: test-process's squatter row, asking
  ;; it, failed a correct build that way. So the allocator is asked as
  ;; well: both tools report a block's size as requested, where a plain
  ;; allocator rounds it up. A 288 B block from the shim read 288 under ASan
  ;; and Valgrind, 320 on macOS and 296 on glibc 2.36 and 2.39 (#75's
  ;; measurements, tests/test-process-steps.sps). getenv answers "" for a
  ;; variable set empty.
  (define (env-set? name)
    (let ((v (getenv name))) (and v (not (string=? v "")))))

  ;; The allocator's size of a block: malloc_size on macOS,
  ;; malloc_usable_size on glibc. (libuv private native) has loaded libuv,
  ;; and libc with it.
  (define allocation-size
    (cond ((foreign-entry? "malloc_size")
           (foreign-procedure "malloc_size" (uptr) size_t))
          ((foreign-entry? "malloc_usable_size")
           (foreign-procedure "malloc_usable_size" (uptr) size_t))
          (else #f)))

  ;; exact-block-sizes? : boolean
  ;; Whether the allocator reports a 288 B block from the shim as 288 B.
  (define exact-block-sizes?
    (let* ((block (alloc-block 288))
           (size (and allocation-size (allocation-size block))))
      (free-block! block)
      (eqv? size 288)))

  ;; under-memory-tool? : boolean
  ;; Whether a memory gate runs this process: its variable is set, and the
  ;; allocator agrees.
  (define under-memory-tool?
    (and (or (env-set? "CHEZ_LIBUV_UNDER_VALGRIND") (env-set? "ASAN_OPTIONS"))
         exact-block-sizes?))

  ;; under-asan? : boolean
  ;; Whether the macOS memory gate, ASan, runs this process: ASAN_OPTIONS is
  ;; set, and the allocator agrees.
  (define under-asan?
    (and (env-set? "ASAN_OPTIONS") exact-block-sizes?)))
