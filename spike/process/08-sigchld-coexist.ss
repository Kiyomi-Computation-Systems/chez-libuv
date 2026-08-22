;;; spike/process/08-sigchld-coexist.ss — SQ2: does libuv's child reaping
;;; coexist with Chez Scheme's OWN subprocess machinery in one process?
;;;
;;; Usage:
;;;   chez --script spike/process/08-sigchld-coexist.ss \
;;;        build/vendor/libuv.dylib [iterations]
;;;
;;; The design spec (v0.3 process, §10) asks:
;;;
;;;   "SQ2 — SIGCHLD coexistence (Linux). In one process, interleave libuv
;;;    spawns with Chez's own subprocess machinery (open-process-ports,
;;;    system): assert libuv's exit_cb still fires and Chez still gets its
;;;    statuses, in both orderings, repeatedly. macOS's kqueue path is
;;;    structurally unaffected — one smoke run anyway. If they conflict, the
;;;    finding becomes a documented mutual-exclusion rule in the README."
;;;
;;; WHY THIS CAN FAIL, precisely (so a green run is read correctly): on any
;;; platform without kqueue, libuv reaps children from a SIGCHLD handler and
;;; calls waitpid(pid, …, WNOHANG) per registered process. Its loop over
;;; loop->process_handles contains this branch, verbatim from
;;; vendor/libuv/src/unix/process.c:
;;;
;;;     if (pid == -1) {
;;;       if (errno != ECHILD) abort();
;;;       /* The child died, and we missed it. This probably means someone
;;;          else stole the waitpid from us. Handle this by not handling it
;;;          at all. */
;;;       continue;
;;;     }
;;;
;;; i.e. a stolen status is a SILENTLY DROPPED exit_cb and a process handle
;;; that stays active forever — a hang, not an error. Two ways a host runtime
;;; can steal it: waitpid(-1)/wait() reaping somebody else's child, or
;;; installing its own SIGCHLD disposition (sigaction/SIG_IGN) over libuv's.
;;; Both are ordering-sensitive, so this script measures four orderings.
;;;
;;; The four phases:
;;;   Phase 1  Chez FIRST — Chez's subprocess calls before libuv has ever
;;;            spawned (i.e. before libuv installs any SIGCHLD handling).
;;;   Phase 2  Alternating — libuv spawn driven to completion, then Chez.
;;;   Phase 3  Interleaved — libuv spawn registered, Chez's calls run BEFORE
;;;            the loop is stepped at all, then the loop is stepped.
;;;   Phase 4  Race window — a libuv child that sleeps, with Chez `system`
;;;            calls running while it is alive, so the child's SIGCHLD lands
;;;            inside Chez's own wait window.
;;;
;;; A repeating libuv timer acts as a wake-up watchdog so every `uv_run ONCE`
;;; returns; the waits themselves are ITERATION-capped, never wall-clock
;;; (AGENTS.md). A dropped exit_cb therefore shows up as a capped-out wait
;;; with a tally, not as a hang.
;;;
;;; SPIKE-ONLY CONSTANTS: every (define NAME <int>) below comes from
;;; ./spike/process/probe-process; spike/dns/apply-probe-constants.sh
;;; rewrites them for the Linux CI leg. Legal IN THE SPIKE ONLY (ADR-0005).

(import (chezscheme))

(define argv (command-line-arguments))

(define lib-path
  (if (null? argv)
      (begin (display "usage: 08-sigchld-coexist.ss <libuv shared object> [iterations]\n")
             (exit 2))
      (car argv)))

(define iterations
  (if (or (null? argv) (null? (cdr argv)))
      50
      (string->number (cadr argv))))

;;; --- probe-supplied constants (spike/process/probe-process) -----------------
(define UV_PROCESS                  10)
(define UV_TIMER                    13)
(define SIZEOF_UV_PROCESS_OPTIONS   64)
(define OFFSETOF_OPT_EXIT_CB         0)
(define OFFSETOF_OPT_FILE            8)
(define OFFSETOF_OPT_ARGS           16)
(define OFFSETOF_OPT_ENV            24)
(define OFFSETOF_OPT_CWD            32)
(define OFFSETOF_OPT_FLAGS          40)
(define OFFSETOF_OPT_STDIO_COUNT    44)
(define OFFSETOF_OPT_STDIO          48)
(define OFFSETOF_PROCESS_PID       104)
(define UV_RUN_ONCE                  1)
(define UV_RUN_NOWAIT                2)

;;; --- load, THEN bind --------------------------------------------------------
(load-shared-object lib-path)

(define uv-loop-size    (foreign-procedure "uv_loop_size"    ()                        size_t))
(define uv-handle-size  (foreign-procedure "uv_handle_size"  (int)                     size_t))
(define uv-loop-init    (foreign-procedure "uv_loop_init"    (uptr)                    int))
(define uv-loop-close   (foreign-procedure "uv_loop_close"   (uptr)                    int))
(define uv-run          (foreign-procedure "uv_run"          (uptr int)                int))
(define uv-spawn        (foreign-procedure "uv_spawn"        (uptr uptr uptr)          int))
(define uv-close        (foreign-procedure "uv_close"        (uptr uptr)               void))
(define uv-is-active    (foreign-procedure "uv_is_active"    (uptr)                    int))
(define uv-timer-init   (foreign-procedure "uv_timer_init"   (uptr uptr)               int))
(define uv-timer-start  (foreign-procedure "uv_timer_start"
                                           (uptr uptr unsigned-64 unsigned-64)         int))
(define uv-err-name     (foreign-procedure "uv_err_name"     (int)                     uptr))

;;; --- helpers ----------------------------------------------------------------
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

(define (c-string s)
  (let* ((bv (string->utf8 s))
         (n  (bytevector-length bv))
         (p  (foreign-alloc (+ n 1))))
    (do ((i 0 (+ i 1))) ((= i n))
      (foreign-set! 'unsigned-8 p i (bytevector-u8-ref bv i)))
    (foreign-set! 'unsigned-8 p n 0)
    p))

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

(define (make-options file args exit-cb-ptr)
  (let-values (((argv-arr argv-blocks) (c-string-array args)))
    (let ((opts     (alloc-zeroed SIZEOF_UV_PROCESS_OPTIONS))
          (file-ptr (c-string file)))
      (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_EXIT_CB exit-cb-ptr)
      (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_FILE file-ptr)
      (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_ARGS argv-arr)
      (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_ENV 0)
      (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_CWD 0)
      (foreign-set! 'unsigned-32 opts OFFSETOF_OPT_FLAGS 0)
      (foreign-set! 'int opts OFFSETOF_OPT_STDIO_COUNT 0)
      (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_STDIO 0)
      (values opts (append (list opts file-ptr) argv-blocks)))))

(define (say . args) (apply printf args) (flush-output-port (current-output-port)))

;;; --- callables ---------------------------------------------------------------
(define exit-fires 0)
(define last-exit 'none)          ; sentinel: no code path produces 'none
(define exit-callable
  (foreign-callable
   (lambda (h status signal)
     (set! exit-fires (+ exit-fires 1))
     (set! last-exit (cons status signal))
     (collect))
   (uptr integer-64 int) void))
(lock-object exit-callable)
(define exit-cb-ptr (foreign-callable-entry-point exit-callable))

(define close-fires 0)
(define close-callable
  (foreign-callable
   (lambda (h) (set! close-fires (+ close-fires 1)) (foreign-free h))
   (uptr) void))
(lock-object close-callable)
(define close-cb-ptr (foreign-callable-entry-point close-callable))

(define watchdog-ticks 0)
(define timer-callable
  (foreign-callable
   (lambda (h) (set! watchdog-ticks (+ watchdog-ticks 1)))
   (uptr) void))
(lock-object timer-callable)
(define timer-cb-ptr (foreign-callable-entry-point timer-callable))

;;; --- the loop and its watchdog ----------------------------------------------
(define loop-ptr (alloc-zeroed (uv-loop-size)))
(define rc-loop-init (uv-loop-init loop-ptr))
(define handle-size (uv-handle-size UV_PROCESS))

;; A repeating timer so that every `uv_run ONCE` is guaranteed to return even
;; when no child status ever arrives. It bounds the WAKE-UP, not the test:
;; the waits below cap on ITERATIONS.
(define watchdog (alloc-zeroed (uv-handle-size UV_TIMER)))
(uv-timer-init loop-ptr watchdog)
(uv-timer-start watchdog timer-cb-ptr 20 20)

(define STEP-CAP 400)   ; capped 'once steps per wait (watchdog ticks every 20ms)

(say "spike/process/08-sigchld-coexist — SQ2\n")
(say "machine-type            = ~s\n" (machine-type))
(say "libuv object            = ~a\n" lib-path)
(say "uv_loop_init            = ~a\n" (rc-name rc-loop-init))
(say "iterations per phase    = ~d\n" iterations)
(say "step cap per wait       = ~d 'once steps (20ms watchdog)\n" STEP-CAP)

;;; --- the two sides -----------------------------------------------------------
;; libuv side: /bin/sh -c 'exit 7' — exists on both platforms; 7 is a
;; discriminating status (a stolen/garbled status is not silently plausible).
(define (libuv-spawn!)
  (let ((h (alloc-zeroed handle-size)))
    (let-values (((opts blocks) (make-options "/bin/sh" '("/bin/sh" "-c" "exit 7") exit-cb-ptr)))
      (let ((rc (uv-spawn loop-ptr h opts)))
        (free-all! blocks)
        (if (zero? rc)
            (cons h rc)
            (begin (uv-close h close-cb-ptr) (cons #f rc)))))))

(define (libuv-spawn-sleeper!)
  (let ((h (alloc-zeroed handle-size)))
    (let-values (((opts blocks)
                  (make-options "/bin/sh" '("/bin/sh" "-c" "sleep 0.2; exit 7") exit-cb-ptr)))
      (let ((rc (uv-spawn loop-ptr h opts)))
        (free-all! blocks)
        (if (zero? rc)
            (cons h rc)
            (begin (uv-close h close-cb-ptr) (cons #f rc)))))))

;; Wait for one more exit_cb than we had, capped by ITERATIONS. Returns the
;; number of steps taken, or #f if the cap was reached without delivery.
(define (wait-for-exit! before)
  (let loop ((i 0))
    (cond ((> exit-fires before) i)
          ((>= i STEP-CAP) #f)
          (else (uv-run loop-ptr UV_RUN_ONCE) (loop (+ i 1))))))

(define (close-and-drain! h)
  (let ((before close-fires))
    (uv-close h close-cb-ptr)
    (let loop ((i 0))
      (cond ((> close-fires before) #t)
            ((>= i 100) #f)
            (else (uv-run loop-ptr UV_RUN_NOWAIT) (loop (+ i 1)))))))

;; Chez side. `(system "exit 7")` is used rather than "/bin/true", which does
;; not exist on macOS (it is /usr/bin/true there); a shell builtin still
;; forks a child, which is the part that matters.
(define chez-system-ok 0)
(define chez-system-bad 0)
(define chez-system-first-bad 'none)
(define (chez-system! tag)
  (let ((r (system "exit 7")))
    (if (eqv? r 7)
        (set! chez-system-ok (+ chez-system-ok 1))
        (begin (set! chez-system-bad (+ chez-system-bad 1))
               (when (eq? chez-system-first-bad 'none)
                 (set! chez-system-first-bad (cons tag r)))))
    r))

(define chez-ports-ok 0)
(define chez-ports-bad 0)
(define chez-ports-first-bad 'none)
(define (chez-ports! tag)
  (let ((want (format "sq2-sentinel-~a" tag)))
    (let-values (((to from err pid)
                  (open-process-ports (string-append "/bin/echo " want)
                                      'block (native-transcoder))))
      (let ((got (get-line from)))
        (close-port to) (close-port from) (close-port err)
        (if (equal? got want)
            (set! chez-ports-ok (+ chez-ports-ok 1))
            (begin (set! chez-ports-bad (+ chez-ports-bad 1))
                   (when (eq? chez-ports-first-bad 'none)
                     (set! chez-ports-first-bad (list tag got want)))))
        pid))))

;;; --- per-phase tallies --------------------------------------------------------
(define (make-tally) (vector 0 0 0 0 '()))   ; fired, correct, dropped, spawn-fail, notes
(define (tally-fired! t)  (vector-set! t 0 (+ (vector-ref t 0) 1)))
(define (tally-right! t)  (vector-set! t 1 (+ (vector-ref t 1) 1)))
(define (tally-drop! t i) (vector-set! t 2 (+ (vector-ref t 2) 1))
                          (vector-set! t 4 (cons i (vector-ref t 4))))
(define (tally-sfail! t)  (vector-set! t 3 (+ (vector-ref t 3) 1)))
(define (report-tally name t n)
  (say "~a: exit_cb fired ~d/~d, payload (7,0) ~d, DROPPED ~d, spawn failures ~d\n"
       name (vector-ref t 0) n (vector-ref t 1) (vector-ref t 2) (vector-ref t 3))
  (unless (null? (vector-ref t 4))
    (say "  dropped at iterations: ~s\n" (reverse (vector-ref t 4)))))

;; One libuv round: spawn, wait, check payload, close.
(define (libuv-round! t i spawner)
  (let* ((before exit-fires)
         (hr (spawner))
         (h  (car hr)))
    (if (not h)
        (tally-sfail! t)
        (let ((steps (wait-for-exit! before)))
          (if steps
              (begin (tally-fired! t)
                     (when (equal? last-exit '(7 . 0)) (tally-right! t)))
              (tally-drop! t i))
          (close-and-drain! h)))))

;;; ===========================================================================
;;; Phase 1 — Chez FIRST (before libuv has spawned anything at all)
;;; ===========================================================================
(say "\n=== Phase 1: Chez subprocess calls BEFORE libuv's first spawn ===\n")
(let loop ((i 0))
  (when (< i 5)
    (chez-system! (format "p1-~d" i))
    (chez-ports! (format "p1-~d" i))
    (loop (+ i 1))))
(say "chez system ok/bad      = ~d / ~d\n" chez-system-ok chez-system-bad)
(say "chez ports  ok/bad      = ~d / ~d\n" chez-ports-ok chez-ports-bad)

;;; ===========================================================================
;;; Phase 2 — alternating: libuv driven to completion, then Chez
;;; ===========================================================================
(say "\n=== Phase 2: alternating libuv spawn / Chez subprocess x ~d ===\n" iterations)
(define t2 (make-tally))
(let loop ((i 0))
  (when (< i iterations)
    (libuv-round! t2 i libuv-spawn!)
    (chez-system! (format "p2-~d" i))
    (chez-ports! (format "p2-~d" i))
    (collect)
    (loop (+ i 1))))
(report-tally "phase 2" t2 iterations)

;;; ===========================================================================
;;; Phase 3 — interleaved: Chez's calls run inside libuv's unreaped window
;;; ===========================================================================
(say "\n=== Phase 3: libuv spawn registered, Chez runs BEFORE any stepping x ~d ===\n"
     iterations)
(define t3 (make-tally))
(let loop ((i 0))
  (when (< i iterations)
    (let* ((before exit-fires)
           (hr (libuv-spawn!))
           (h  (car hr)))
      (if (not h)
          (tally-sfail! t3)
          (begin
            ;; no uv_run yet: the child may exit while Chez is in its own wait
            (chez-system! (format "p3-~d" i))
            (chez-ports! (format "p3-~d" i))
            (let ((steps (wait-for-exit! before)))
              (if steps
                  (begin (tally-fired! t3)
                         (when (equal? last-exit '(7 . 0)) (tally-right! t3)))
                  (tally-drop! t3 i)))
            (close-and-drain! h))))
    (collect)
    (loop (+ i 1))))
(report-tally "phase 3" t3 iterations)

;;; ===========================================================================
;;; Phase 4 — race window: SIGCHLD lands while Chez is waiting on its own child
;;; ===========================================================================
(say "\n=== Phase 4: sleeping libuv child, Chez system() calls during its life ===\n")
(define phase4-n (max 5 (quotient iterations 5)))
(define t4 (make-tally))
(let loop ((i 0))
  (when (< i phase4-n)
    (let* ((before exit-fires)
           (hr (libuv-spawn-sleeper!))
           (h  (car hr)))
      (if (not h)
          (tally-sfail! t4)
          (begin
            ;; Hammer Chez's own subprocess machinery while the libuv child is
            ;; alive; step the loop a little between calls so libuv is in a
            ;; realistic state (some steps taken, child not yet exited).
            (do ((k 0 (+ k 1))) ((= k 8))
              (chez-system! (format "p4-~d-~d" i k))
              (uv-run loop-ptr UV_RUN_NOWAIT))
            (chez-ports! (format "p4-~d" i))
            (let ((steps (wait-for-exit! before)))
              (if steps
                  (begin (tally-fired! t4)
                         (when (equal? last-exit '(7 . 0)) (tally-right! t4)))
                  (tally-drop! t4 i)))
            (close-and-drain! h))))
    (collect)
    (loop (+ i 1))))
(report-tally "phase 4" t4 phase4-n)

;;; --- teardown -----------------------------------------------------------------
(uv-close watchdog close-cb-ptr)
(let loop ((i 0))
  (when (and (< i 100) (zero? (uv-run loop-ptr UV_RUN_NOWAIT)))
    (loop (+ i 1))))
(define rc-loop-close (uv-loop-close loop-ptr))
(say "\nuv_loop_close           = ~a\n" (rc-name rc-loop-close))
(foreign-free loop-ptr)

;;; --- summary -------------------------------------------------------------------
(define total-rounds (+ iterations iterations phase4-n))
(define total-fired (+ (vector-ref t2 0) (vector-ref t3 0) (vector-ref t4 0)))
(define total-right (+ (vector-ref t2 1) (vector-ref t3 1) (vector-ref t4 1)))
(define total-dropped (+ (vector-ref t2 2) (vector-ref t3 2) (vector-ref t4 2)))
(define total-sfail (+ (vector-ref t2 3) (vector-ref t3 3) (vector-ref t4 3)))

(say "\n=== SQ2 summary (observations, not assertions) ===\n")
(say "platform (machine-type)            : ~s\n" (machine-type))
(say "libuv exit_cb delivered            : ~d / ~d rounds\n" total-fired total-rounds)
(say "  payload exactly (7 . 0)          : ~d\n" total-right)
(say "  DROPPED (capped out, no exit_cb) : ~d\n" total-dropped)
(say "  spawn failures                   : ~d\n" total-sfail)
(say "Chez (system \"exit 7\") -> 7        : ~d ok / ~d wrong, first wrong ~s\n"
     chez-system-ok chez-system-bad chez-system-first-bad)
(say "Chez open-process-ports echo       : ~d ok / ~d wrong, first wrong ~s\n"
     chez-ports-ok chez-ports-bad chez-ports-first-bad)
(say "watchdog timer ticks               : ~d\n" watchdog-ticks)
(say "uv_loop_close                      : ~a\n" (rc-name rc-loop-close))
(say "VERDICT: ~a\n"
     (if (and (= total-fired total-rounds)
              (= total-right total-rounds)
              (zero? total-dropped)
              (zero? chez-system-bad)
              (zero? chez-ports-bad))
         "NO CONFLICT OBSERVED on this platform"
         "CONFLICT OBSERVED — see the per-phase tallies above"))
(exit 0)
