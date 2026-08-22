;;; spike/process/07-spawn-failure.ss — SQ1: what a FAILED uv_spawn leaves
;;; behind, and which cleanup strategy is correct.
;;;
;;; Usage:
;;;   chez --script spike/process/07-spawn-failure.ss \
;;;        build/vendor/libuv.dylib [iterations] [all|a|b]
;;;
;;; The third argument selects which cleanup ENGINE runs (see `mode` below);
;;; it exists so the Linux valgrind leg can run strategy A and strategy B in
;;; separate processes and attribute the difference.
;;;
;;; The design spec (v0.3 process, §10) asks:
;;;
;;;   "SQ1 — spawn failure cleanup. Drive 'ENOENT spawns under valgrind +
;;;    debug counters with both cleanup strategies (close-through-protocol
;;;    vs direct foreign-free); also assert (pipe …)-spec pipes remain
;;;    consistently unconnected and closeable after a failed spawn.
;;;    Evidence decides ADR-0015's failure path."
;;;
;;; What this script measures, in order — every part prints, none asserts
;;; silently:
;;;
;;;   Part 1  Anatomy of an EXEC failure (file that does not exist).
;;;           Is the handle still in the loop's handle_queue after the
;;;           failed uv_spawn (measured with uv_walk, not by reading
;;;           source)? Is it active? Does uv_loop_close see it?
;;;   Part 2  Anatomy of a STDIO-SETUP failure (UV_INHERIT_FD with fd -1),
;;;           which is a DIFFERENT error path in libuv, and whether
;;;           close-through-protocol is safe on it (a sentinel handle in the
;;;           same loop detects handle_queue corruption).
;;;   Part 2b The discriminating arrangement for that second class: a handle
;;;           registered AFTER the failure, closed BEFORE it — does the
;;;           close splice the live handle out of loop->handle_queue?
;;;   Part 2c The other half of the 2x2: direct free after a stdio failure.
;;;   Part 3  Strategy A (close-through-protocol) x N, (collect) each round.
;;;   Part 4  Pipes named by (pipe …) specs across a failed spawn: are they
;;;           left untouched, or connected? Are they closeable? Do their fds
;;;           leak if the caller does not close them (Part 4b)?
;;;   Part 5  Strategy B (direct foreign-free) x N, (collect) each round.
;;;           LAST, because it is the strategy expected to corrupt the loop:
;;;           everything above has already printed by the time it runs.
;;;
;;; SPIKE-ONLY CONSTANTS: every (define NAME <int>) below comes from
;;; ./spike/process/probe-process (Darwin arm64 values as committed);
;;; spike/dns/apply-probe-constants.sh rewrites them with runner-correct
;;; values for the Linux CI leg. Hardcoding is legal IN THE SPIKE ONLY —
;;; production snapshots these in the shim (ADR-0005).

(import (chezscheme))

(define argv (command-line-arguments))

(define lib-path
  (if (null? argv)
      (begin (display "usage: 07-spawn-failure.ss <libuv shared object> [iterations]\n")
             (exit 2))
      (car argv)))

(define iterations
  (if (or (null? argv) (null? (cdr argv)))
      1000
      (string->number (cadr argv))))

;; Which cleanup strategy's ENGINE runs: "all" (default), "a"
;; (close-through-protocol only) or "b" (direct-free only). Everything else —
;; the single-shot anatomy parts and the pipe accounting — runs in every mode,
;; because all of it is memory-safe. The split exists so the Linux valgrind
;; leg can attribute an Invalid read/write to strategy B specifically: mode
;; "a" and mode "b" differ by exactly Part 5's engine.
(define mode
  (if (> (length argv) 2) (list-ref argv 2) "all"))
(define run-a? (or (string=? mode "all") (string=? mode "a")))
(define run-b? (or (string=? mode "all") (string=? mode "b")))
(define a-iters (if run-a? iterations 0))
(define b-iters (if run-b? iterations 0))

;;; --- probe-supplied constants (spike/process/probe-process) -----------------
(define UV_PROCESS                  10)
(define UV_NAMED_PIPE                7)
(define UV_TCP                      12)
(define SIZEOF_UV_PROCESS_OPTIONS   64)
(define OFFSETOF_OPT_EXIT_CB         0)
(define OFFSETOF_OPT_FILE            8)
(define OFFSETOF_OPT_ARGS           16)
(define OFFSETOF_OPT_ENV            24)
(define OFFSETOF_OPT_CWD            32)
(define OFFSETOF_OPT_FLAGS          40)
(define OFFSETOF_OPT_STDIO_COUNT    44)
(define OFFSETOF_OPT_STDIO          48)
(define OFFSETOF_OPT_UID            56)
(define OFFSETOF_OPT_GID            60)
(define SIZEOF_UV_STDIO_CONTAINER   16)
(define OFFSETOF_CONTAINER_FLAGS     0)
(define OFFSETOF_CONTAINER_DATA      8)
(define UV_IGNORE                    0)
(define UV_CREATE_PIPE               1)
(define UV_INHERIT_FD                2)
(define UV_INHERIT_STREAM            4)
(define UV_READABLE_PIPE            16)
(define UV_WRITABLE_PIPE            32)
(define UV_RUN_DEFAULT               0)
(define UV_RUN_ONCE                  1)
(define UV_RUN_NOWAIT                2)
(define OFFSETOF_PROCESS_PID       104)
(define UV_ENOENT                   -2)
(define UV_EINVAL                  -22)
(define UV_EBUSY                   -16)
(define UV_EBADF                    -9)

;;; --- load, THEN bind --------------------------------------------------------
(load-shared-object lib-path)

(define uv-loop-size    (foreign-procedure "uv_loop_size"    ()               size_t))
(define uv-handle-size  (foreign-procedure "uv_handle_size"  (int)            size_t))
(define uv-loop-init    (foreign-procedure "uv_loop_init"    (uptr)           int))
(define uv-loop-close   (foreign-procedure "uv_loop_close"   (uptr)           int))
(define uv-loop-alive   (foreign-procedure "uv_loop_alive"   (uptr)           int))
(define uv-run          (foreign-procedure "uv_run"          (uptr int)       int))
(define uv-spawn        (foreign-procedure "uv_spawn"        (uptr uptr uptr) int))
(define uv-close        (foreign-procedure "uv_close"        (uptr uptr)      void))
(define uv-is-active    (foreign-procedure "uv_is_active"    (uptr)           int))
(define uv-is-closing   (foreign-procedure "uv_is_closing"   (uptr)           int))
(define uv-is-readable  (foreign-procedure "uv_is_readable"  (uptr)           int))
(define uv-is-writable  (foreign-procedure "uv_is_writable"  (uptr)           int))
(define uv-pipe-init    (foreign-procedure "uv_pipe_init"    (uptr uptr int)  int))
(define uv-fileno       (foreign-procedure "uv_fileno"       (uptr uptr)      int))
(define uv-walk         (foreign-procedure "uv_walk"         (uptr uptr uptr) void))
(define uv-handle-type  (foreign-procedure "uv_handle_get_type" (uptr)        int))
(define uv-err-name     (foreign-procedure "uv_err_name"     (int)            uptr))

;;; --- small helpers -----------------------------------------------------------
(define (c-string->string addr)
  (if (= addr 0)
      #f
      (let loop ((i 0) (acc '()))
        (let ((b (foreign-ref 'unsigned-8 addr i)))
          (if (= b 0)
              (utf8->string (u8-list->bytevector (reverse acc)))
              (loop (+ i 1) (cons b acc)))))))

(define (rc-name rc) (if (zero? rc) "0" (c-string->string (uv-err-name rc))))

(define (alloc-zeroed n)
  (let ((p (foreign-alloc n)))
    (do ((i 0 (+ i 1))) ((= i n) p)
      (foreign-set! 'unsigned-8 p i 0))))

;; A NUL-terminated C string in foreign memory. Freed by the caller.
(define (c-string s)
  (let* ((bv (string->utf8 s))
         (n  (bytevector-length bv))
         (p  (foreign-alloc (+ n 1))))
    (do ((i 0 (+ i 1))) ((= i n))
      (foreign-set! 'unsigned-8 p i (bytevector-u8-ref bv i)))
    (foreign-set! 'unsigned-8 p n 0)
    p))

;; A NULL-terminated char** built from a list of Scheme strings. Returns
;; (values array-ptr list-of-blocks-to-free).
(define (c-string-array strs)
  (let* ((ptrs (map c-string strs))
         (n    (length ptrs))
         (arr  (foreign-alloc (* 8 (+ n 1)))))
    (let loop ((i 0) (ps ptrs))
      (if (null? ps)
          (foreign-set! 'unsigned-64 arr (* 8 i) 0)
          (begin (foreign-set! 'unsigned-64 arr (* 8 i) (car ps))
                 (loop (+ i 1) (cdr ps)))))
    (values arr (cons arr ptrs))))

(define (free-all! blocks) (for-each foreign-free blocks))

;; Build a uv_process_options_t. stdio is a list of (flags . data-ptr).
;; Returns (values options-ptr blocks-to-free).
(define (make-options file args exit-cb-ptr stdio)
  (let*-values (((argv-arr argv-blocks) (c-string-array args)))
    (let* ((opts     (alloc-zeroed SIZEOF_UV_PROCESS_OPTIONS))
           (file-ptr (c-string file))
           (n        (length stdio))
           (stdio-arr (if (zero? n)
                          0
                          (alloc-zeroed (* SIZEOF_UV_STDIO_CONTAINER n)))))
      (let loop ((i 0) (ss stdio))
        (unless (null? ss)
          (let ((base (* i SIZEOF_UV_STDIO_CONTAINER)))
            (foreign-set! 'int stdio-arr (+ base OFFSETOF_CONTAINER_FLAGS) (caar ss))
            ;; The union is one word: a stream POINTER for CREATE_PIPE /
            ;; INHERIT_STREAM, and a 32-bit fd for INHERIT_FD. A negative
            ;; value can only be an fd, so it is written as an int.
            (if (negative? (cdar ss))
                (foreign-set! 'int stdio-arr (+ base OFFSETOF_CONTAINER_DATA) (cdar ss))
                (foreign-set! 'unsigned-64 stdio-arr (+ base OFFSETOF_CONTAINER_DATA) (cdar ss))))
          (loop (+ i 1) (cdr ss))))
      (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_EXIT_CB exit-cb-ptr)
      (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_FILE file-ptr)
      (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_ARGS argv-arr)
      (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_ENV 0)
      (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_CWD 0)
      (foreign-set! 'unsigned-32 opts OFFSETOF_OPT_FLAGS 0)
      (foreign-set! 'int opts OFFSETOF_OPT_STDIO_COUNT n)
      (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_STDIO stdio-arr)
      (values opts
              (append (list opts file-ptr)
                      (if (zero? n) '() (list stdio-arr))
                      argv-blocks)))))

;;; --- callables ---------------------------------------------------------------
(define exit-fires 0)
(define last-exit 'none)          ; sentinel: no path produces 'none
(define exit-callable
  (foreign-callable
   (lambda (h status signal)
     (set! exit-fires (+ exit-fires 1))
     (set! last-exit (list h status signal)))
   (uptr integer-64 int) void))
(lock-object exit-callable)
(define exit-cb-ptr (foreign-callable-entry-point exit-callable))

(define close-fires 0)
(define close-callable
  (foreign-callable
   (lambda (h) (set! close-fires (+ close-fires 1)))
   (uptr) void))
(lock-object close-callable)
(define close-cb-ptr (foreign-callable-entry-point close-callable))

;; close_cb that ALSO frees the handle block — the production shape.
(define close-free-fires 0)
(define close-free-callable
  (foreign-callable
   (lambda (h)
     (set! close-free-fires (+ close-free-fires 1))
     (foreign-free h))
   (uptr) void))
(lock-object close-free-callable)
(define close-free-cb-ptr (foreign-callable-entry-point close-free-callable))

(define walk-acc '())
(define walk-callable
  (foreign-callable
   (lambda (h arg) (set! walk-acc (cons (cons h (uv-handle-type h)) walk-acc)))
   (uptr uptr) void))
(lock-object walk-callable)
(define walk-cb-ptr (foreign-callable-entry-point walk-callable))

(define (walk-handles loop)
  (set! walk-acc '())
  (uv-walk loop walk-cb-ptr 0)
  (reverse walk-acc))

;; Capped stepping — iteration cap, never wall-clock (AGENTS.md).
(define (step-until! loop done? cap)
  (let loop* ((i 0))
    (cond ((done?) i)
          ((>= i cap) i)
          (else (uv-run loop UV_RUN_ONCE) (loop* (+ i 1))))))

(define (new-loop)
  (let ((p (alloc-zeroed (uv-loop-size))))
    (let ((rc (uv-loop-init p)))
      (unless (zero? rc)
        (printf "FATAL: uv_loop_init = ~a\n" (rc-name rc))
        (exit 3)))
    p))

(define MISSING "/nonexistent/definitely-missing")
(define (say . args) (apply printf args) (flush-output-port (current-output-port)))

(define handle-size (uv-handle-size UV_PROCESS))
(define pipe-size   (uv-handle-size UV_NAMED_PIPE))

(say "spike/process/07-spawn-failure — SQ1\n")
(say "libuv object            = ~a\n" lib-path)
(say "uv_handle_size(PROCESS) = ~d\n" handle-size)
(say "uv_handle_size(PIPE)    = ~d\n" pipe-size)
(say "iterations per strategy = ~d (mode ~s: A ~d, B ~d)\n" iterations mode a-iters b-iters)

;;; ===========================================================================
;;; Part 1 — anatomy of an EXEC failure
;;; ===========================================================================
(say "\n=== Part 1: anatomy of an exec failure (file does not exist) ===\n")

(define p1-loop (new-loop))
(define p1-baseline (length (walk-handles p1-loop)))
(define p1-handle (alloc-zeroed handle-size))
(define-values (p1-opts p1-blocks)
  (make-options MISSING (list MISSING) exit-cb-ptr '()))
(define p1-rc (uv-spawn p1-loop p1-handle p1-opts))
(free-all! p1-blocks)   ; V1: options are consumed synchronously

(define p1-walk (walk-handles p1-loop))
(define p1-in-queue? (and (assv p1-handle p1-walk) #t))
(say "uv_spawn rc                        = ~a (~d)\n" (rc-name p1-rc) p1-rc)
(say "handles in loop handle_queue       = ~d (baseline ~d)\n"
     (length p1-walk) p1-baseline)
(say "OUR handle still in handle_queue?  = ~s\n" p1-in-queue?)
(say "  (uv_walk visits loop->handle_queue; this is a MEASUREMENT of whether\n")
(say "   uv_spawn's error path removed the handle, not a reading of source)\n")
(say "uv_is_active(handle)               = ~d\n" (uv-is-active p1-handle))
(say "uv_is_closing(handle)              = ~d\n" (uv-is-closing p1-handle))
(say "uv_loop_alive(loop)                = ~d\n" (uv-loop-alive p1-loop))
(say "handle->pid field                  = ~d (probe offset ~d)\n"
     (foreign-ref 'int p1-handle OFFSETOF_PROCESS_PID) OFFSETOF_PROCESS_PID)
(define p1-loop-close-before (uv-loop-close p1-loop))
(say "uv_loop_close BEFORE any cleanup   = ~a  (EBUSY => the loop still owns it)\n"
     (rc-name p1-loop-close-before))
(define p1-exit-before-close exit-fires)
(define p1-run-before-close (uv-run p1-loop UV_RUN_NOWAIT))
(say "uv_run(NOWAIT) before cleanup      = ~d ; exit_cb fires so far = ~d\n"
     p1-run-before-close exit-fires)

;; now close through the protocol
(define p1-close-before close-fires)
(uv-close p1-handle close-cb-ptr)
(define p1-steps (step-until! p1-loop (lambda () (> close-fires p1-close-before)) 100))
(say "uv_close -> close_cb fired?        = ~s (after ~d capped 'once steps)\n"
     (> close-fires p1-close-before) p1-steps)
(define p1-walk-after (walk-handles p1-loop))
(say "handles in handle_queue after close= ~d\n" (length p1-walk-after))
(say "stray exit_cb fires (expect 0)     = ~d\n" (- exit-fires p1-exit-before-close))
(define p1-loop-close-after (uv-loop-close p1-loop))
(say "uv_loop_close AFTER close protocol = ~a\n" (rc-name p1-loop-close-after))
(foreign-free p1-handle)
(foreign-free p1-loop)

;;; ===========================================================================
;;; Part 2 — anatomy of a STDIO-SETUP failure (a different libuv error path)
;;; ===========================================================================
;;; uv_spawn has two exits: it returns the child's exec errno by falling off
;;; the end (exec failures), and it returns setup errors through an `error:`
;;; label that ALSO unlinks the handle from the loop. Those two classes may
;;; want different cleanup — which is exactly the ADR-0015 question, so the
;;; spike measures both instead of assuming the ENOENT case generalises.
;;; UV_INHERIT_FD with fd = -1 is the cheapest reachable setup failure.
;;; A sentinel pipe handle lives in the same loop the whole time: if closing
;;; the failed handle corrupts loop->handle_queue, the sentinel stops being
;;; visible to uv_walk (or the walk never terminates and the cap fires).
(say "\n=== Part 2: anatomy of a stdio-setup failure (INHERIT_FD, fd = -1) ===\n")

(define p2-loop (new-loop))
(define p2-sentinel (alloc-zeroed pipe-size))
(uv-pipe-init p2-loop p2-sentinel 0)
(define p2-handle (alloc-zeroed handle-size))
(define-values (p2-opts p2-blocks)
  (make-options MISSING (list MISSING) exit-cb-ptr
                (list (cons UV_INHERIT_FD -1))))
(define p2-rc (uv-spawn p2-loop p2-handle p2-opts))
(free-all! p2-blocks)
(define p2-walk (walk-handles p2-loop))
(say "uv_spawn rc                        = ~a (~d)\n" (rc-name p2-rc) p2-rc)
(say "handles in handle_queue            = ~d (1 = sentinel only, 2 = ours too)\n"
     (length p2-walk))
(say "OUR handle still in handle_queue?  = ~s\n" (and (assv p2-handle p2-walk) #t))
(say "sentinel still visible?            = ~s\n" (and (assv p2-sentinel p2-walk) #t))

(define p2-close-before close-fires)
(say "closing the failed handle through the protocol anyway...\n")
(uv-close p2-handle close-cb-ptr)
(define p2-steps (step-until! p2-loop (lambda () (> close-fires p2-close-before)) 100))
(say "close_cb fired?                    = ~s (after ~d steps)\n"
     (> close-fires p2-close-before) p2-steps)
(define p2-walk-after (walk-handles p2-loop))
(say "handles in handle_queue after      = ~d\n" (length p2-walk-after))
(say "sentinel STILL visible after?      = ~s  (#f => handle_queue corrupted)\n"
     (and (assv p2-sentinel p2-walk-after) #t))
(define p2-sentinel-close-before close-fires)
(uv-close p2-sentinel close-cb-ptr)
(step-until! p2-loop (lambda () (> close-fires p2-sentinel-close-before)) 100)
(say "sentinel closed cleanly?           = ~s\n" (> close-fires p2-sentinel-close-before))
(say "uv_loop_close                      = ~a\n" (rc-name (uv-loop-close p2-loop)))
(foreign-free p2-handle)
(foreign-free p2-sentinel)
(foreign-free p2-loop)

;;; Part 2b — the discriminating arrangement. libuv's `error:` path unlinks
;;; the handle but leaves its own handle_queue node pointing at its old
;;; neighbours; uv__finish_close later unlinks it AGAIN. That second unlink
;;; is harmless only while the neighbours are unchanged. Here a SECOND
;;; sentinel is registered AFTER the failed spawn (so it becomes the queue
;;; tail the stale node's next pointer no longer describes) and BEFORE the
;;; close: if the double-unlink can splice out a live handle, this is the
;;; arrangement that shows it.
(say "\n--- Part 2b: does close-after-stdio-failure splice out a LATER handle? ---\n")
(define p2b-loop (new-loop))
(define p2b-first (alloc-zeroed pipe-size))
(uv-pipe-init p2b-loop p2b-first 0)
(define p2b-handle (alloc-zeroed handle-size))
(define-values (p2b-opts p2b-blocks)
  (make-options MISSING (list MISSING) exit-cb-ptr (list (cons UV_INHERIT_FD -1))))
(define p2b-rc (uv-spawn p2b-loop p2b-handle p2b-opts))
(free-all! p2b-blocks)
(define p2b-late (alloc-zeroed pipe-size))
(uv-pipe-init p2b-loop p2b-late 0)          ; registered AFTER the failure
(define p2b-walk-before (walk-handles p2b-loop))
(say "uv_spawn rc                        = ~a\n" (rc-name p2b-rc))
(say "handles before close (expect 2)    = ~d\n" (length p2b-walk-before))
(define p2b-close-before close-fires)
(uv-close p2b-handle close-cb-ptr)
(step-until! p2b-loop (lambda () (> close-fires p2b-close-before)) 100)
(define p2b-walk-after (walk-handles p2b-loop))
(define p2b-first-ok (and (assv p2b-first p2b-walk-after) #t))
(define p2b-late-ok  (and (assv p2b-late p2b-walk-after) #t))
(say "handles after close (expect 2)     = ~d\n" (length p2b-walk-after))
(say "first sentinel still visible?      = ~s\n" p2b-first-ok)
(say "LATE sentinel still visible?       = ~s  (#f => the double-unlink ate it)\n"
     p2b-late-ok)
(define p2b-sweep-before close-fires)
(for-each (lambda (h.k) (uv-close (car h.k) close-cb-ptr)) p2b-walk-after)
(step-until! p2b-loop
             (lambda () (>= close-fires (+ p2b-sweep-before (length p2b-walk-after))))
             200)
(define p2b-loop-close (uv-loop-close p2b-loop))
(say "uv_loop_close after sweep          = ~a\n" (rc-name p2b-loop-close))
(foreign-free p2b-handle) (foreign-free p2b-first) (foreign-free p2b-late)
(foreign-free p2b-loop)

;;; Part 2c — the other half of the 2x2: strategy B (direct free) applied to
;;; the stdio-setup-failure class, in the same discriminating arrangement.
(say "\n--- Part 2c: direct free after a stdio-setup failure ---\n")
(define p2c-loop (new-loop))
(define p2c-first (alloc-zeroed pipe-size))
(uv-pipe-init p2c-loop p2c-first 0)
(define p2c-handle (alloc-zeroed handle-size))
(define-values (p2c-opts p2c-blocks)
  (make-options MISSING (list MISSING) exit-cb-ptr (list (cons UV_INHERIT_FD -1))))
(define p2c-rc (uv-spawn p2c-loop p2c-handle p2c-opts))
(free-all! p2c-blocks)
(foreign-free p2c-handle)                    ; STRATEGY B, no uv_close
(define p2c-late (alloc-zeroed pipe-size))
(uv-pipe-init p2c-loop p2c-late 0)
(define p2c-walk (walk-handles p2c-loop))
(define p2c-first-ok (and (assv p2c-first p2c-walk) #t))
(define p2c-late-ok  (and (assv p2c-late p2c-walk) #t))
(say "uv_spawn rc                        = ~a\n" (rc-name p2c-rc))
(say "handles visible after direct free  = ~d (expect 2)\n" (length p2c-walk))
(say "first / late sentinel visible?     = ~s / ~s\n" p2c-first-ok p2c-late-ok)
(define p2c-sweep-before close-fires)
(for-each (lambda (h.k) (uv-close (car h.k) close-cb-ptr)) p2c-walk)
(step-until! p2c-loop
             (lambda () (>= close-fires (+ p2c-sweep-before (length p2c-walk))))
             200)
(define p2c-loop-close (uv-loop-close p2c-loop))
(say "uv_loop_close after sweep          = ~a\n" (rc-name p2c-loop-close))
(foreign-free p2c-first) (foreign-free p2c-late) (foreign-free p2c-loop)

;;; ===========================================================================
;;; Part 3 — Strategy A (close through the protocol) x iterations
;;; ===========================================================================
(say "\n=== Part 3: strategy A (close-through-protocol) x ~d ===\n" a-iters)

(define a-loop (new-loop))
(define a-rc-not-enoent 0)
(define a-close-misses 0)
(define a-exit-before exit-fires)
(define a-start close-free-fires)

(let loop ((i 0))
  (when (< i a-iters)
    (let ((h (alloc-zeroed handle-size)))
      (let-values (((opts blocks) (make-options MISSING (list MISSING) exit-cb-ptr '())))
        (let ((rc (uv-spawn a-loop h opts)))
          (free-all! blocks)
          (unless (= rc UV_ENOENT) (set! a-rc-not-enoent (+ a-rc-not-enoent 1)))
          (let ((before close-free-fires))
            (uv-close h close-free-cb-ptr)     ; frees h inside close_cb
            (step-until! a-loop (lambda () (> close-free-fires before)) 100)
            (unless (> close-free-fires before)
              (set! a-close-misses (+ a-close-misses 1)))))))
    (collect)
    (when (zero? (modulo (+ i 1) 250))
      (say "  ... strategy A iteration ~d (close_cb fires so far ~d)\n"
           (+ i 1) (- close-free-fires a-start)))
    (loop (+ i 1))))

(define a-walk (walk-handles a-loop))
(define a-delivered (- close-free-fires a-start))
(say "close_cb fires                     = ~d / ~d\n" a-delivered a-iters)
(say "spawns whose rc was not ENOENT     = ~d\n" a-rc-not-enoent)
(say "close_cb misses                    = ~d\n" a-close-misses)
(say "stray exit_cb fires (expect 0)     = ~d\n" (- exit-fires a-exit-before))
(say "handles left in handle_queue       = ~d\n" (length a-walk))
(say "uv_loop_alive                      = ~d\n" (uv-loop-alive a-loop))
(define a-loop-close (uv-loop-close a-loop))
(say "uv_loop_close                      = ~a\n" (rc-name a-loop-close))
(foreign-free a-loop)

;;; ===========================================================================
;;; Part 4 — (pipe …)-spec pipes across a failed spawn
;;; ===========================================================================
(say "\n=== Part 4: pipes named by stdio specs, across a FAILED spawn ===\n")

(define fdbuf (foreign-alloc 4))
(define (fileno-of h)
  (foreign-set! 'int fdbuf 0 -12345)
  (let ((rc (uv-fileno h fdbuf)))
    (cons rc (foreign-ref 'int fdbuf 0))))

(define p4-loop (new-loop))
(define p4-in  (alloc-zeroed pipe-size))
(define p4-out (alloc-zeroed pipe-size))
(say "uv_pipe_init(in)                   = ~a\n" (rc-name (uv-pipe-init p4-loop p4-in 0)))
(say "uv_pipe_init(out)                  = ~a\n" (rc-name (uv-pipe-init p4-loop p4-out 0)))
(define p4-in-before (fileno-of p4-in))
(define p4-out-before (fileno-of p4-out))
(say "uv_fileno(in)  BEFORE spawn        = rc ~a, fd ~d\n"
     (rc-name (car p4-in-before)) (cdr p4-in-before))
(say "uv_fileno(out) BEFORE spawn        = rc ~a, fd ~d\n"
     (rc-name (car p4-out-before)) (cdr p4-out-before))

(define p4-handle (alloc-zeroed handle-size))
(define-values (p4-opts p4-blocks)
  (make-options MISSING (list MISSING) exit-cb-ptr
                (list (cons (bitwise-ior UV_CREATE_PIPE UV_READABLE_PIPE) p4-in)
                      (cons (bitwise-ior UV_CREATE_PIPE UV_WRITABLE_PIPE) p4-out))))
(define p4-rc (uv-spawn p4-loop p4-handle p4-opts))
(free-all! p4-blocks)
(define p4-in-after (fileno-of p4-in))
(define p4-out-after (fileno-of p4-out))
(say "uv_spawn rc                        = ~a\n" (rc-name p4-rc))
(say "uv_fileno(in)  AFTER failed spawn  = rc ~a, fd ~d\n"
     (rc-name (car p4-in-after)) (cdr p4-in-after))
(say "uv_fileno(out) AFTER failed spawn  = rc ~a, fd ~d\n"
     (rc-name (car p4-out-after)) (cdr p4-out-after))
(say "  (EBADF both = pipes untouched; rc 0 with a real fd = libuv CONNECTED\n")
(say "   the parent end even though the spawn failed)\n")
(say "uv_is_readable(in) / writable(in)  = ~d / ~d\n"
     (uv-is-readable p4-in) (uv-is-writable p4-in))
(say "uv_is_readable(out)/ writable(out) = ~d / ~d\n"
     (uv-is-readable p4-out) (uv-is-writable p4-out))
(say "uv_is_active(in) / (out)           = ~d / ~d\n"
     (uv-is-active p4-in) (uv-is-active p4-out))

(define p4-close-before close-fires)
(uv-close p4-handle close-cb-ptr)
(uv-close p4-in close-cb-ptr)
(uv-close p4-out close-cb-ptr)
(define p4-steps (step-until! p4-loop (lambda () (>= close-fires (+ p4-close-before 3))) 200))
(say "all three close_cbs fired?         = ~s (after ~d steps, ~d fires)\n"
     (>= close-fires (+ p4-close-before 3)) p4-steps (- close-fires p4-close-before))
(say "uv_loop_close                      = ~a\n" (rc-name (uv-loop-close p4-loop)))
(foreign-free p4-handle) (foreign-free p4-in) (foreign-free p4-out) (foreign-free p4-loop)

;;; Part 4b — the fd cost. Repeat the failed spawn many times, closing
;;; everything each round: if the parent ends are real fds and we close them,
;;; the rc must stay ENOENT forever (no EMFILE). Then repeat WITHOUT closing
;;; the pipes, and record how many rounds it takes to run out of fds — which
;;; is the measured cost of treating a failed spawn's pipes as "untouched".
(define (failed-spawn-round! loop close-pipes?)
  (let ((h  (alloc-zeroed handle-size))
        (pi (alloc-zeroed pipe-size))
        (po (alloc-zeroed pipe-size)))
    (uv-pipe-init loop pi 0)
    (uv-pipe-init loop po 0)
    (let-values (((opts blocks)
                  (make-options MISSING (list MISSING) exit-cb-ptr
                                (list (cons (bitwise-ior UV_CREATE_PIPE UV_READABLE_PIPE) pi)
                                      (cons (bitwise-ior UV_CREATE_PIPE UV_WRITABLE_PIPE) po)))))
      (let* ((rc (uv-spawn loop h opts))
             (fd (cdr (fileno-of pi))))   ; the parent end this round consumed
        (free-all! blocks)
        (let ((before close-free-fires)
              (n (if close-pipes? 3 1)))
          (uv-close h close-free-cb-ptr)
          (when close-pipes?
            (uv-close pi close-free-cb-ptr)
            (uv-close po close-free-cb-ptr))
          (step-until! loop (lambda () (>= close-free-fires (+ before n))) 200))
        (cons rc fd)))))

(say "\n--- Part 4b: fd accounting over repeated failed spawns ---\n")
(define p4b-loop (new-loop))
(define p4b-rounds (max 5 (min 300 iterations)))
(define p4b-bad 0)
(define p4b-first-bad 'none)
(define p4b-first-fd 'none)
(define p4b-last-fd 'none)
(let loop ((i 0))
  (when (< i p4b-rounds)
    (let* ((r  (failed-spawn-round! p4b-loop #t))
           (rc (car r)))
      (when (eq? p4b-first-fd 'none) (set! p4b-first-fd (cdr r)))
      (set! p4b-last-fd (cdr r))
      (unless (= rc UV_ENOENT)
        (set! p4b-bad (+ p4b-bad 1))
        (when (eq? p4b-first-bad 'none) (set! p4b-first-bad (cons i (rc-name rc))))))
    (loop (+ i 1))))
(say "closing the pipes: ~d rounds, non-ENOENT rcs = ~d, first = ~s\n"
     p4b-rounds p4b-bad p4b-first-bad)
(say "  parent-end fd on round 0 / last  = ~s / ~s  (stable => fds recycled)\n"
     p4b-first-fd p4b-last-fd)
(say "uv_loop_close                      = ~a\n" (rc-name (uv-loop-close p4b-loop)))
(foreign-free p4b-loop)

(define p4c-loop (new-loop))
(define p4c-leaked 0)
(define p4c-stop 'never)
(define p4c-first-fd 'none)
(define p4c-last-fd 'none)
(let loop ((i 0))
  (when (and (< i p4b-rounds) (eq? p4c-stop 'never))
    (let* ((r  (failed-spawn-round! p4c-loop #f))   ; pipes deliberately NOT closed
           (rc (car r)))
      (when (eq? p4c-first-fd 'none) (set! p4c-first-fd (cdr r)))
      (set! p4c-last-fd (cdr r))
      (set! p4c-leaked (+ p4c-leaked 1))
      (unless (= rc UV_ENOENT) (set! p4c-stop (cons i (rc-name rc)))))
    (loop (+ i 1))))
(say "NOT closing the pipes: rounds completed = ~d, first non-ENOENT = ~s\n"
     p4c-leaked p4c-stop)
(say "  parent-end fd on round 0 / last  = ~s / ~s  (climbing => fds LEAKED)\n"
     p4c-first-fd p4c-last-fd)
;; tidy up the leaked pipe handles through uv_walk so the loop can close
(define p4c-open (walk-handles p4c-loop))
(say "handles left open in that loop     = ~d\n" (length p4c-open))
(define p4c-close-before close-free-fires)
(for-each (lambda (h.k) (uv-close (car h.k) close-free-cb-ptr)) p4c-open)
(step-until! p4c-loop
             (lambda () (>= close-free-fires (+ p4c-close-before (length p4c-open))))
             2000)
(say "swept them closed                  = ~d\n" (- close-free-fires p4c-close-before))
(say "uv_loop_close after sweep          = ~a\n" (rc-name (uv-loop-close p4c-loop)))
(foreign-free p4c-loop)
(foreign-free fdbuf)

;;; ===========================================================================
;;; Part 5 — Strategy B (direct foreign-free), LAST because it is the one
;;; expected to corrupt the loop.
;;; ===========================================================================
(say "\n=== Part 5: strategy B (direct foreign-free, no uv_close) x ~d ===\n" b-iters)
;; NOTE: this banner deliberately avoids valgrind's own marker words
;; (the "Inval1d read/write" spellings below are broken on purpose): the CI
;; gate greps the captured stdout+stderr for those markers, and prose that
;; spells them exactly would make the script fail its own gate.
(say "If uv_spawn's exec-failure path leaves the handle linked into\n")
(say "loop->handle_queue, freeing the block makes the NEXT uv__handle_init\n")
(say "write through a dangling tail pointer. That is a use-after-free even\n")
(say "when it does not crash — valgrind's inval1d-access reports are the\n")
(say "Linux leg's discriminator; this leg records whether it survives at all.\n")

(define b-loop (new-loop))
(define b-rc-not-enoent 0)
(define b-completed 0)
(define b-exit-before exit-fires)

(let loop ((i 0))
  (when (< i b-iters)
    (let ((h (alloc-zeroed handle-size)))
      (let-values (((opts blocks) (make-options MISSING (list MISSING) exit-cb-ptr '())))
        (let ((rc (uv-spawn b-loop h opts)))
          (free-all! blocks)
          (unless (= rc UV_ENOENT) (set! b-rc-not-enoent (+ b-rc-not-enoent 1)))
          (foreign-free h)                       ; STRATEGY B: no uv_close
          (do ((k 0 (+ k 1))) ((= k 100))
            (uv-run b-loop UV_RUN_NOWAIT)))))
    (set! b-completed (+ b-completed 1))
    (collect)
    (when (zero? (modulo (+ i 1) 250))
      (say "  ... strategy B iteration ~d survived\n" (+ i 1)))
    (loop (+ i 1))))

(say "iterations survived                = ~d / ~d\n" b-completed b-iters)
(say "spawns whose rc was not ENOENT     = ~d\n" b-rc-not-enoent)
(say "stray exit_cb fires (expect 0)     = ~d\n" (- exit-fires b-exit-before))
(say "about to uv_walk the strategy-B loop (walks the corrupted queue)...\n")
(define b-walk (walk-handles b-loop))
(say "uv_walk returned, handles seen     = ~d\n" (length b-walk))
(say "about to uv_loop_close the strategy-B loop...\n")
(define b-loop-close (uv-loop-close b-loop))
(say "uv_loop_close                      = ~a  (EBUSY = the freed handles are\n"
     (rc-name b-loop-close))
(say "                                     still linked into handle_queue)\n")
(foreign-free b-loop)

;;; ===========================================================================
;;; Summary
;;; ===========================================================================
(say "\n=== SQ1 summary (observations, not assertions) ===\n")
(say "exec-failure rc                        : ~a\n" (rc-name p1-rc))
(say "exec-failure leaves handle in queue    : ~s\n" p1-in-queue?)
(say "uv_loop_close before cleanup           : ~a\n" (rc-name p1-loop-close-before))
(say "strategy A close_cb delivery           : ~d / ~d\n" a-delivered a-iters)
(say "strategy A final uv_loop_close         : ~a\n" (rc-name a-loop-close))
(say "strategy B iterations survived         : ~d / ~d\n" b-completed b-iters)
(say "strategy B final uv_loop_close         : ~a\n" (rc-name b-loop-close))
(say "stdio-setup-failure rc                 : ~a\n" (rc-name p2-rc))
(say "stdio-setup-failure leaves in queue    : ~s\n" (and (assv p2-handle p2-walk) #t))
(say "\nthe 2x2 (failure class x cleanup strategy):\n")
(say "  exec failure  + uv_close    : close_cb ~s, loop_close ~a~a\n"
     (> close-fires 0) (rc-name p1-loop-close-after)
     (if run-a? "" "   [engine not run in this mode]"))
(say "  exec failure  + direct free : loop_close ~a~a\n" (rc-name b-loop-close)
     (if run-b? "" "   [engine not run in this mode]"))
(say "  stdio failure + uv_close    : late handle survived ~s, loop_close ~a\n"
     p2b-late-ok (rc-name p2b-loop-close))
(say "  stdio failure + direct free : late handle survived ~s, loop_close ~a\n"
     p2c-late-ok (rc-name p2c-loop-close))
(say "pipe fd before / after failed spawn    : ~a / ~a\n"
     (rc-name (car p4-in-before)) (rc-name (car p4-in-after)))
(say "total exit_cb fires across whole run   : ~d (expect 0 — nothing ever execed)\n"
     exit-fires)
(say "last exit_cb payload                   : ~s\n" last-exit)
(exit 0)
