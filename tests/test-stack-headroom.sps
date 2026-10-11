#!r6rs
;;; The C stack headroom check (#94;
;;; .plans/2026-10-09-escape-headroom-check-design.md). A continuation that
;;; escapes a callback leaves its uv_run's C frames on the thread's stack
;;; for the thread's life, and enough of them overflow it: SIGSEGV, or on
;;; macOS a hang (#95). So every uv_run the binding makes first measures the
;;; thread's headroom: uv-run is refused under run-stack-floor, and a
;;; teardown's drain under teardown-stack-floor, with &uv-stack-exhausted.
;;;
;;; Every row that fills a stack does it in tests/stack-headroom-child.sps,
;;; a process of its own under tests/uv-level-3.sls's deadline, on a thread
;;; made with fork-thread: a binding that lets a run through too deep
;;; crashes or hangs that process, and the rows then fail carrying how it
;;; ended. The child runs natively under the memory gates, since neither
;;; tool follows a child, and nothing in this process escapes a callback.
(import (rnrs)
        (srfi :64)
        (uv-level-3)
        (only (libuv private handles) run-stack-floor teardown-stack-floor)
        (only (chezscheme) getenv))

;; SRFI-64's default runner does not set a process exit code (AGENTS.md).
(define runner (test-runner-simple))
(test-runner-current runner)

(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

(test-begin "stack-headroom")

;; A crash leaves no datum, and a macOS hang lasts until the deadline, so a
;; broken build costs this much a child.
(define child-deadline-seconds 30)

(define chez (getenv "CHEZ_LIBUV_TEST_CHEZ"))

(define (child mode)
  (level-3-run chez "tests/stack-headroom-child.sps" (list mode)
               child-deadline-seconds))

;; refusal-shape : object -> object
;; A refusal the child reported, as (refused who floor), its headroom
;; dropped; anything else as it came.
(define (refusal-shape x)
  (if (and (list? x) (= (length x) 4) (eq? (car x) 'refused))
      (list 'refused (cadr x) (caddr x))
      x))

;; refusal-headroom : object -> (or exact-integer #f)
(define (refusal-headroom x)
  (and (list? x) (= (length x) 4) (eq? (car x) 'refused) (cadddr x)))

(if (not chez)
    (test-equal "stack headroom rows SKIPPED: CHEZ_LIBUV_TEST_CHEZ unset (run via make test)"
      'skipped 'skipped)
    (let ((floors (child 'floors))
          (escapes (child 'escapes)))

      ;; --- the floors, at depths reached without escaping -------------------
      ;; The child nests libc qsort comparator callbacks until its headroom
      ;; is under each depth, and every callback returns afterwards.

      (test-equal "between the floors, uv-run is refused naming the run floor, and the loop still tears down"
        (list (list 'refused 'uv-run run-stack-floor) 'torn-down #f)
        (let ((between (level-3-entry floors 'between)))
          (if (and (list? between) (= (length between) 3))
              (list (refusal-shape (car between)) (cadr between) (caddr between))
              between)))

      (test-equal "a run refused between the floors was refused at a headroom between them"
        'between
        (let* ((between (level-3-entry floors 'between))
               (h (and (pair? between) (refusal-headroom (car between)))))
          (if (and h (<= teardown-stack-floor h) (< h run-stack-floor))
              'between
              (list 'outside h between))))

      (test-equal "under the teardown floor, the teardown is refused too, naming the teardown floor"
        (list (list 'refused 'uv-run run-stack-floor)
              (list 'refused 'uv-loop-teardown! teardown-stack-floor))
        (let ((under (level-3-entry floors 'under)))
          (if (and (list? under) (= (length under) 2))
              (map refusal-shape under)
              under)))

      (test-equal "a loop whose teardown was refused deep tears down once the callbacks have returned"
        '(torn-down #f)
        (level-3-entry floors 'after-return))

      ;; --- escapes from I/O callbacks until the run floor ------------------

      (test-equal "escapes from async callbacks end in uv-run's refusal at the run floor, not a crash or a hang"
        (list 'refused 'uv-run run-stack-floor)
        (let ((last (level-3-entry escapes 'last)))
          (if (refusal-headroom last) (refusal-shape last) (list last escapes))))

      (test-equal "every loop made up to the refusal was torn down, the refused run's own included"
        0
        (level-3-entry escapes 'open-loops))

      ;; What one escape strands is measured on the platform running the
      ;; suite, so the floors are checked against numbers nobody measured by
      ;; hand: CI's x86-64 runner, for one.
      (test-equal "seed: an escape from an async callback strands more than one from a timer callback, by at least the poll's event array"
        'measured
        (let ((timer (level-3-entry escapes 'timer-strand))
              (async (level-3-entry escapes 'async-strand)))
          (if (and (equal? (level-3-entry escapes 'first) '(escaped escaped))
                   (integer? timer) (integer? async)
                   (< 0 timer 4096) (>= async (+ timer 8192)))
              'measured
              (list 'strands timer async escapes))))

      (test-equal "the gap between the floors holds one escape from an async callback, so a refused run leaves room for its teardown"
        'fits
        (let ((async (level-3-entry escapes 'async-strand)))
          (if (and (integer? async) (>= (- run-stack-floor teardown-stack-floor) async))
              'fits
              (list 'gap (- run-stack-floor teardown-stack-floor) 'strand async))))

      (test-equal "the teardown floor holds one escape from an async callback and 16 KiB more, the deepest path a teardown takes"
        'fits
        (let ((async (level-3-entry escapes 'async-strand)))
          (if (and (integer? async) (>= teardown-stack-floor (+ async 16384)))
              'fits
              (list 'floor teardown-stack-floor 'strand async))))))

(test-end "stack-headroom")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
