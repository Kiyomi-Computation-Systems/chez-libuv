;;; spike/process/09-pipe-stdio-gc.ss — SQ3: pipe stdio under GC pressure,
;;; and the observed ordering of stdout-EOF vs process-exit.
;;;
;;; Usage:
;;;   chez --script spike/process/09-pipe-stdio-gc.ss \
;;;        build/vendor/libuv.dylib [round-trips] [runs] [short-runs] [early-exit-runs]
;;;
;;; The design spec (v0.3 process, §10) asks:
;;;
;;;   "SQ3 — pipe stdio under GC pressure. The echo loop (stdin pipe → cat →
;;;    stdout pipe) for 10k round-trips with (collect) in every callback;
;;;    record observed EOF/exit orderings (expect both); assert no delivery is
;;;    lost and counters balance. Justifies the wait-both-independently test
;;;    discipline with measured evidence."
;;;
;;; Harness shape:
;;;   * /bin/cat is spawned with stdio
;;;       0: CREATE_PIPE|READABLE_PIPE  -> the parent-write pipe
;;;       1: CREATE_PIPE|WRITABLE_PIPE  -> the parent-read pipe
;;;       2: IGNORE
;;;   * one 64-byte seeded payload is written per round trip and compared
;;;     byte-for-byte on the way back; the next write is issued FROM INSIDE
;;;     the read callback (re-entrancy, the v0.2 Q1 pattern);
;;;   * (collect) runs in EVERY callback — alloc, read, write, shutdown, exit,
;;;     close — so a full Chez collection happens with libuv's C frames live
;;;     below;
;;;   * read buffers are foreign-alloc'd fresh in alloc_cb and freed in
;;;     read_cb, and each write's req + uv_buf_t + payload are ONE block freed
;;;     in write_cb — allocation churn on every delivery, deliberately;
;;;   * after the last round trip the write side is uv_shutdown'd, which is
;;;     what makes cat see EOF and exit. The ORDER in which the two resulting
;;;     events arrive — our stdout read seeing UV_EOF, and the process
;;;     exit_cb — is recorded per run with a monotonic sequence number. That
;;;     ordering is the finding: a test that waits for one and assumes the
;;;     other has happened is a flake generator.
;;;   * a repeating libuv timer guarantees every `uv_run ONCE` returns; the
;;;     drive loop caps on ITERATIONS, never on wall clock (AGENTS.md).
;;;
;;; SPIKE-ONLY CONSTANTS: every (define NAME <int>) below comes from
;;; ./spike/process/probe-process; spike/dns/apply-probe-constants.sh
;;; rewrites them for the Linux CI leg. Legal IN THE SPIKE ONLY (ADR-0005).

(import (chezscheme))

(define argv (command-line-arguments))

(define lib-path
  (if (null? argv)
      (begin (display "usage: 09-pipe-stdio-gc.ss <libuv shared object> [round-trips] [runs]\n")
             (exit 2))
      (car argv)))

(define (arg n default)
  (if (> (length argv) n) (string->number (list-ref argv n)) default))

(define target-trips (arg 1 10000))
(define target-runs  (arg 2 20))
;; Second sweep: many SHORT runs, so the shutdown->exit window is sampled in a
;; different timing regime from the long ones. Ordering is the only thing this
;; sweep is for.
(define short-runs   (arg 3 50))
;; Third sweep: the echo is done by a GRANDCHILD. `sh -c 'exec 3<&0; cat <&3 & exit 0'`
;; backgrounds cat (which inherits both pipes) and exits immediately, so the
;; watched process is gone long before the stdout pipe closes. It exists to
;; answer, by measurement, whether the EOF/exit order is a property of libuv
;; or a property of the child's process structure.
(define early-exit-runs (arg 4 50))
;; Mutable because the two sweeps use different lengths; read from the read
;; callback, set by the driver.
(define trips-target target-trips)

;;; --- probe-supplied constants (spike/process/probe-process) -----------------
(define UV_PROCESS                  10)
(define UV_NAMED_PIPE                7)
(define UV_TIMER                    13)
(define UV_WRITE                     3)
(define UV_SHUTDOWN                  4)
(define SIZEOF_UV_PROCESS_OPTIONS   64)
(define OFFSETOF_OPT_EXIT_CB         0)
(define OFFSETOF_OPT_FILE            8)
(define OFFSETOF_OPT_ARGS           16)
(define OFFSETOF_OPT_ENV            24)
(define OFFSETOF_OPT_CWD            32)
(define OFFSETOF_OPT_FLAGS          40)
(define OFFSETOF_OPT_STDIO_COUNT    44)
(define OFFSETOF_OPT_STDIO          48)
(define SIZEOF_UV_STDIO_CONTAINER   16)
(define OFFSETOF_CONTAINER_FLAGS     0)
(define OFFSETOF_CONTAINER_DATA      8)
(define UV_IGNORE                    0)
(define UV_CREATE_PIPE               1)
(define UV_READABLE_PIPE            16)
(define UV_WRITABLE_PIPE            32)
(define SIZEOF_UV_BUF_T             16)
(define OFFSETOF_BUF_BASE            0)
(define OFFSETOF_BUF_LEN             8)
(define UV_RUN_ONCE                  1)
(define UV_RUN_NOWAIT                2)
(define UV_EOF                   -4095)

;;; --- load, THEN bind --------------------------------------------------------
(load-shared-object lib-path)

(define uv-loop-size    (foreign-procedure "uv_loop_size"    ()                       size_t))
(define uv-handle-size  (foreign-procedure "uv_handle_size"  (int)                    size_t))
(define uv-req-size     (foreign-procedure "uv_req_size"     (int)                    size_t))
(define uv-loop-init    (foreign-procedure "uv_loop_init"    (uptr)                   int))
(define uv-loop-close   (foreign-procedure "uv_loop_close"   (uptr)                   int))
(define uv-loop-alive   (foreign-procedure "uv_loop_alive"   (uptr)                   int))
(define uv-run          (foreign-procedure "uv_run"          (uptr int)               int))
(define uv-spawn        (foreign-procedure "uv_spawn"        (uptr uptr uptr)         int))
(define uv-close        (foreign-procedure "uv_close"        (uptr uptr)              void))
(define uv-pipe-init    (foreign-procedure "uv_pipe_init"    (uptr uptr int)          int))
(define uv-read-start   (foreign-procedure "uv_read_start"   (uptr uptr uptr)         int))
(define uv-read-stop    (foreign-procedure "uv_read_stop"    (uptr)                   int))
(define uv-write        (foreign-procedure "uv_write"        (uptr uptr uptr unsigned-int uptr) int))
(define uv-shutdown     (foreign-procedure "uv_shutdown"     (uptr uptr uptr)         int))
(define uv-timer-init   (foreign-procedure "uv_timer_init"   (uptr uptr)              int))
(define uv-timer-start  (foreign-procedure "uv_timer_start"
                                           (uptr uptr unsigned-64 unsigned-64)        int))
(define uv-err-name     (foreign-procedure "uv_err_name"     (int)                    uptr))

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

(define (say . args) (apply printf args) (flush-output-port (current-output-port)))

(define PAYLOAD 64)
(define (payload-byte r i j) (modulo (+ (* 131 r) (* 31 i) (* 7 j) 13) 256))

;;; --- per-run mutable state ---------------------------------------------------
(define run-index      0)
(define trips          0)
(define fill           0)
(define acc            (make-bytevector PAYLOAD 0))
(define verify-fails   0)
(define first-bad-trip 'none)      ; sentinel: no path produces 'none
(define bytes-in       0)
(define bytes-out      0)
(define write-fires    0)
(define write-errors   0)
(define alloc-fires    0)
(define read-fires     0)
(define read-zero      0)
(define read-errors    0)
(define close-fires    0)
(define shutdown-fires 0)
(define shutdown-status 'none)
(define seq            0)
(define eof-seq        'none)
(define exit-seq       'none)
(define exit-status    'none)
(define exit-signal    'none)
(define ticks          0)

;; The child this run spawns: (file . args). Set by the driver per sweep.
(define child-file "/bin/cat")
(define child-args '("/bin/cat"))

(define loop-ptr       0)
(define pipe-in        0)          ; parent writes -> child stdin
(define pipe-out       0)          ; child stdout  -> parent reads
(define proc-handle    0)
(define write-req-size (uv-req-size UV_WRITE))
(define shutdown-req-size (uv-req-size UV_SHUTDOWN))

(define (next-seq!) (set! seq (+ seq 1)) seq)

;;; --- write: one block holds [uv_write_t][uv_buf_t][payload] ------------------
(define (write-trip! i)
  (let* ((total (+ write-req-size SIZEOF_UV_BUF_T PAYLOAD))
         (blk   (foreign-alloc total))
         (bufp  (+ blk write-req-size))
         (datap (+ blk write-req-size SIZEOF_UV_BUF_T)))
    (do ((j 0 (+ j 1))) ((= j PAYLOAD))
      (foreign-set! 'unsigned-8 datap j (payload-byte run-index i j)))
    (foreign-set! 'unsigned-64 bufp OFFSETOF_BUF_BASE datap)
    (foreign-set! 'unsigned-64 bufp OFFSETOF_BUF_LEN PAYLOAD)
    (let ((rc (uv-write blk pipe-in bufp 1 write-cb-ptr)))
      (if (zero? rc)
          (set! bytes-out (+ bytes-out PAYLOAD))
          (begin (set! write-errors (+ write-errors 1))
                 (foreign-free blk)))
      rc)))

(define (shutdown-writes!)
  (let ((req (alloc-zeroed shutdown-req-size)))
    (let ((rc (uv-shutdown req pipe-in shutdown-cb-ptr)))
      (unless (zero? rc)
        (set! shutdown-status (cons 'submit rc))
        (foreign-free req))
      rc)))

(define (verify-trip! i)
  (let loop ((j 0))
    (cond ((= j PAYLOAD) #t)
          ((= (bytevector-u8-ref acc j) (payload-byte run-index i j)) (loop (+ j 1)))
          (else
           (set! verify-fails (+ verify-fails 1))
           (when (eq? first-bad-trip 'none)
             (set! first-bad-trip (list run-index i j (bytevector-u8-ref acc j))))
           #f))))

;;; --- callables (created ONCE, locked ONCE, reused across all runs) -----------
(define alloc-callable
  (foreign-callable
   (lambda (h suggested buf)
     (set! alloc-fires (+ alloc-fires 1))
     (collect)
     (let* ((n (if (> suggested 65536) 65536 (if (< suggested 1) 1 suggested)))
            (p (foreign-alloc n)))
       (foreign-set! 'unsigned-64 buf OFFSETOF_BUF_BASE p)
       (foreign-set! 'unsigned-64 buf OFFSETOF_BUF_LEN n)))
   (uptr size_t uptr) void))
(lock-object alloc-callable)
(define alloc-cb-ptr (foreign-callable-entry-point alloc-callable))

(define read-callable
  (foreign-callable
   (lambda (stream nread buf)
     (set! read-fires (+ read-fires 1))
     (collect)
     (let ((base (if (zero? buf) 0 (foreign-ref 'unsigned-64 buf OFFSETOF_BUF_BASE))))
       (cond
         ((> nread 0)
          (set! bytes-in (+ bytes-in nread))
          (do ((k 0 (+ k 1))) ((= k nread))
            (bytevector-u8-set! acc fill (foreign-ref 'unsigned-8 base k))
            (set! fill (+ fill 1))
            (when (= fill PAYLOAD)
              (set! fill 0)
              (verify-trip! trips)
              (set! trips (+ trips 1))
              (if (< trips trips-target)
                  (write-trip! trips)
                  (shutdown-writes!)))))
         ((= nread UV_EOF)
          (set! eof-seq (next-seq!))
          (uv-read-stop stream)
          (uv-close stream close-cb-ptr))
         ((< nread 0)
          (set! read-errors (+ read-errors 1)))
         (else (set! read-zero (+ read-zero 1))))
       (unless (zero? base) (foreign-free base))))
   (uptr integer-64 uptr) void))
(lock-object read-callable)
(define read-cb-ptr (foreign-callable-entry-point read-callable))

(define write-callable
  (foreign-callable
   (lambda (req status)
     (set! write-fires (+ write-fires 1))
     (collect)
     (unless (zero? status) (set! write-errors (+ write-errors 1)))
     (foreign-free req))            ; the one block: req + buf + payload
   (uptr int) void))
(lock-object write-callable)
(define write-cb-ptr (foreign-callable-entry-point write-callable))

(define shutdown-callable
  (foreign-callable
   (lambda (req status)
     (set! shutdown-fires (+ shutdown-fires 1))
     (collect)
     (set! shutdown-status status)
     (foreign-free req)
     (uv-close pipe-in close-cb-ptr))
   (uptr int) void))
(lock-object shutdown-callable)
(define shutdown-cb-ptr (foreign-callable-entry-point shutdown-callable))

(define exit-callable
  (foreign-callable
   (lambda (h status signal)
     (set! exit-seq (next-seq!))
     (set! exit-status status)
     (set! exit-signal signal)
     (collect)
     (uv-close h close-cb-ptr))
   (uptr integer-64 int) void))
(lock-object exit-callable)
(define exit-cb-ptr (foreign-callable-entry-point exit-callable))

(define close-callable
  (foreign-callable
   (lambda (h) (set! close-fires (+ close-fires 1)) (collect))
   (uptr) void))
(lock-object close-callable)
(define close-cb-ptr (foreign-callable-entry-point close-callable))

(define timer-callable
  (foreign-callable
   (lambda (h) (set! ticks (+ ticks 1)))
   (uptr) void))
(lock-object timer-callable)
(define timer-cb-ptr (foreign-callable-entry-point timer-callable))

;;; --- entry-point stability (the v0.1 Q1 check, on the new shapes) ------------
(define ptrs-before
  (list alloc-cb-ptr read-cb-ptr write-cb-ptr shutdown-cb-ptr exit-cb-ptr close-cb-ptr))
(collect (collect-maximum-generation))
(define ptrs-warm
  (list (foreign-callable-entry-point alloc-callable)
        (foreign-callable-entry-point read-callable)
        (foreign-callable-entry-point write-callable)
        (foreign-callable-entry-point shutdown-callable)
        (foreign-callable-entry-point exit-callable)
        (foreign-callable-entry-point close-callable)))

(say "spike/process/09-pipe-stdio-gc — SQ3\n")
(say "machine-type            = ~s\n" (machine-type))
(say "libuv object            = ~a\n" lib-path)
(say "round trips per run     = ~d\n" target-trips)
(say "runs                    = ~d\n" target-runs)
(say "uv_req_size(UV_WRITE)   = ~d\n" write-req-size)
(say "uv_req_size(UV_SHUTDOWN)= ~d\n" shutdown-req-size)
(say "entry points stable across (collect)? ~s\n" (equal? ptrs-before ptrs-warm))

;;; --- one run ------------------------------------------------------------------
;; Returns an association list of this run's observations.
(define (do-run! r)
  (set! run-index r)
  (set! trips 0) (set! fill 0)
  (set! bytes-in 0) (set! bytes-out 0)
  (set! write-fires 0) (set! write-errors 0)
  (set! alloc-fires 0) (set! read-fires 0) (set! read-zero 0) (set! read-errors 0)
  (set! close-fires 0) (set! shutdown-fires 0) (set! shutdown-status 'none)
  (set! seq 0) (set! eof-seq 'none) (set! exit-seq 'none)
  (set! exit-status 'none) (set! exit-signal 'none)

  (set! loop-ptr (alloc-zeroed (uv-loop-size)))
  (let ((rc (uv-loop-init loop-ptr)))
    (unless (zero? rc) (say "FATAL uv_loop_init = ~a\n" (rc-name rc)) (exit 3)))

  (let ((watchdog (alloc-zeroed (uv-handle-size UV_TIMER))))
    (uv-timer-init loop-ptr watchdog)
    (uv-timer-start watchdog timer-cb-ptr 50 50)

    (set! pipe-in    (alloc-zeroed (uv-handle-size UV_NAMED_PIPE)))
    (set! pipe-out   (alloc-zeroed (uv-handle-size UV_NAMED_PIPE)))
    (set! proc-handle (alloc-zeroed (uv-handle-size UV_PROCESS)))
    (uv-pipe-init loop-ptr pipe-in 0)
    (uv-pipe-init loop-ptr pipe-out 0)

    (let*-values (((argv-arr argv-blocks) (c-string-array child-args)))
      (let* ((opts     (alloc-zeroed SIZEOF_UV_PROCESS_OPTIONS))
             (file-ptr (c-string child-file))
             (stdio    (alloc-zeroed (* 3 SIZEOF_UV_STDIO_CONTAINER))))
        (foreign-set! 'int stdio (+ (* 0 SIZEOF_UV_STDIO_CONTAINER) OFFSETOF_CONTAINER_FLAGS)
                      (bitwise-ior UV_CREATE_PIPE UV_READABLE_PIPE))
        (foreign-set! 'unsigned-64 stdio (+ (* 0 SIZEOF_UV_STDIO_CONTAINER) OFFSETOF_CONTAINER_DATA)
                      pipe-in)
        (foreign-set! 'int stdio (+ (* 1 SIZEOF_UV_STDIO_CONTAINER) OFFSETOF_CONTAINER_FLAGS)
                      (bitwise-ior UV_CREATE_PIPE UV_WRITABLE_PIPE))
        (foreign-set! 'unsigned-64 stdio (+ (* 1 SIZEOF_UV_STDIO_CONTAINER) OFFSETOF_CONTAINER_DATA)
                      pipe-out)
        (foreign-set! 'int stdio (+ (* 2 SIZEOF_UV_STDIO_CONTAINER) OFFSETOF_CONTAINER_FLAGS)
                      UV_IGNORE)
        (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_EXIT_CB exit-cb-ptr)
        (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_FILE file-ptr)
        (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_ARGS argv-arr)
        (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_ENV 0)
        (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_CWD 0)
        (foreign-set! 'unsigned-32 opts OFFSETOF_OPT_FLAGS 0)
        (foreign-set! 'int opts OFFSETOF_OPT_STDIO_COUNT 3)
        (foreign-set! 'unsigned-64 opts OFFSETOF_OPT_STDIO stdio)

        (let ((rc-spawn (uv-spawn loop-ptr proc-handle opts)))
          (free-all! (append (list opts file-ptr stdio) argv-blocks))
          (when (not (zero? rc-spawn))
            (say "FATAL uv_spawn(~a) = ~a\n" child-file (rc-name rc-spawn))
            (exit 4))

          (let ((rc-read (uv-read-start pipe-out alloc-cb-ptr read-cb-ptr)))
            (unless (zero? rc-read) (say "uv_read_start = ~a\n" (rc-name rc-read))))
          (write-trip! 0)

          ;; Drive: capped ITERATION count, watchdog guarantees each 'once
          ;; returns. Done when both pipes and the process handle are closed.
          ;; A SECOND cap counts watchdog ticks: a run that stops making
          ;; progress blocks 50ms per step, so the iteration cap alone would
          ;; take hours to expire. Neither cap is an assertion — a run that
          ;; hits one says so in the log and is counted as 'incomplete.
          (let ((cap (+ 200000 (* 8 trips-target)))
                ;; 50ms per tick; short runs get ~2s, a 10k-trip run ~12s.
                (tick-cap (+ ticks 40 (quotient trips-target 50))))
            (let drive ((i 0))
              (cond ((>= close-fires 3) i)
                    ((>= i cap) (say "  !! run ~d hit the ~d-step cap\n" r cap) i)
                    ((> ticks tick-cap)
                     (say "  !! run ~d hit the watchdog-tick cap (no progress)\n" r) i)
                    (else (uv-run loop-ptr UV_RUN_ONCE) (drive (+ i 1))))))

          ;; drain the watchdog and close the loop
          (uv-close watchdog close-cb-ptr)
          (let drain ((i 0))
            (when (and (< i 200) (< close-fires 4))
              (uv-run loop-ptr UV_RUN_NOWAIT)
              (drain (+ i 1))))
          (let ((rc-lc (uv-loop-close loop-ptr))
                (alive (uv-loop-alive loop-ptr)))
            (foreign-free watchdog)
            (foreign-free pipe-in) (foreign-free pipe-out) (foreign-free proc-handle)
            (foreign-free loop-ptr)
            (collect (collect-maximum-generation))
            (list (cons 'run r)
                  (cons 'trips trips)
                  (cons 'bytes-out bytes-out)
                  (cons 'bytes-in bytes-in)
                  (cons 'verify-fails verify-fails)
                  (cons 'write-fires write-fires)
                  (cons 'write-errors write-errors)
                  (cons 'alloc-fires alloc-fires)
                  (cons 'read-fires read-fires)
                  (cons 'read-zero read-zero)
                  (cons 'read-errors read-errors)
                  (cons 'shutdown-fires shutdown-fires)
                  (cons 'shutdown-status shutdown-status)
                  (cons 'eof-seq eof-seq)
                  (cons 'exit-seq exit-seq)
                  (cons 'exit-status exit-status)
                  (cons 'exit-signal exit-signal)
                  (cons 'close-fires close-fires)
                  (cons 'order (cond ((or (eq? eof-seq 'none) (eq? exit-seq 'none)) 'incomplete)
                                     ((< eof-seq exit-seq) 'eof-first)
                                     ((> eof-seq exit-seq) 'exit-first)
                                     (else 'same)))
                  (cons 'loop-alive alive)
                  (cons 'loop-close rc-lc))))))))

;;; --- the runs --------------------------------------------------------------------
(define (sweep! label n per-run verbose? file args)
  (set! trips-target per-run)
  (set! child-file file)
  (set! child-args args)
  (say "\n=== ~a: ~d runs x ~d round trips, (collect) in every callback ===\n"
       label n per-run)
  (let loop ((r 0) (acc '()))
    (if (>= r n)
        (reverse acc)
        (let ((res (do-run! r)))
          (if verbose?
              (say "run ~2d: trips ~d/~d, bytes ~d/~d, verify-fails ~d, writes ~d, reads ~d (zero ~d, err ~d), order ~s (eof ~s exit ~s), exit (~s . ~s), loop_close ~a\n"
                   r
                   (cdr (assq 'trips res)) per-run
                   (cdr (assq 'bytes-in res)) (cdr (assq 'bytes-out res))
                   (cdr (assq 'verify-fails res))
                   (cdr (assq 'write-fires res))
                   (cdr (assq 'read-fires res))
                   (cdr (assq 'read-zero res))
                   (cdr (assq 'read-errors res))
                   (cdr (assq 'order res))
                   (cdr (assq 'eof-seq res)) (cdr (assq 'exit-seq res))
                   (cdr (assq 'exit-status res)) (cdr (assq 'exit-signal res))
                   (rc-name (cdr (assq 'loop-close res))))
              (say "~a" (case (cdr (assq 'order res))
                          ((eof-first) "E") ((exit-first) "X")
                          ((same) "=") (else "?"))))
          (loop (+ r 1) (cons res acc))))))

(define CAT-FILE "/bin/cat")
(define CAT-ARGS '("/bin/cat"))
(define SH-FILE "/bin/sh")
;; The echo runs in a grandchild that inherits both pipes; `exit 0` retires
;; the watched process immediately.
;;
;; The `exec 3<&0` dance is REQUIRED and the obvious spellings do not work.
;; POSIX assigns an asynchronous list's stdin to /dev/null "before any
;; explicit redirections", so plain `cat &` echoes nothing (measured). The
;; tempting fix `cat 0<&0 &` is portable in theory but not in practice: dash
;; (Ubuntu's /bin/sh) opens /dev/null on fd 0 in forkchild() BEFORE the
;; command's own redirections are applied, so `0<&0` dups the already
;; replaced fd onto itself — measured as a hung Linux CI leg. Saving the real
;; stdin on fd 3 in the PARENT shell first, then redirecting fd 0 from fd 3
;; in the async command, works on both.
(define SH-ARGS '("/bin/sh" "-c" "exec 3<&0; cat <&3 & exit 0"))

(define results-long (sweep! "long sweep (child = /bin/cat)"
                             target-runs target-trips #t CAT-FILE CAT-ARGS))
(define results-short (sweep! "short sweep, ordering sample (child = /bin/cat)"
                              short-runs 1 #f CAT-FILE CAT-ARGS))
(say "\n  (E = EOF first, X = exit first, ? = one never arrived)\n")
(define results-shared (sweep! "early-exit sweep, ordering sample (child = sh -c 'exec 3<&0; cat <&3 & exit 0')"
                               early-exit-runs 1 #f SH-FILE SH-ARGS))
(say "\n  (E = EOF first, X = exit first, ? = one never arrived)\n")
(define results (append results-long results-short results-shared))

;;; --- aggregate ---------------------------------------------------------------------
(define (count-in rs pred) (length (filter pred rs)))
(define (order-is k) (lambda (r) (eq? (cdr (assq 'order r)) k)))
(define (count-where pred) (count-in results pred))
(define (sum-of key) (fold-left (lambda (a r) (+ a (cdr (assq key r)))) 0 results))

(define eof-first  (count-where (order-is 'eof-first)))
(define exit-first (count-where (order-is 'exit-first)))
(define incomplete (count-where (order-is 'incomplete)))
(define long-eof   (count-in results-long (order-is 'eof-first)))
(define long-exit  (count-in results-long (order-is 'exit-first)))
(define short-eof  (count-in results-short (order-is 'eof-first)))
(define short-exit (count-in results-short (order-is 'exit-first)))
(define shared-eof  (count-in results-shared (order-is 'eof-first)))
(define shared-exit (count-in results-shared (order-is 'exit-first)))

(define ptrs-after
  (list (foreign-callable-entry-point alloc-callable)
        (foreign-callable-entry-point read-callable)
        (foreign-callable-entry-point write-callable)
        (foreign-callable-entry-point shutdown-callable)
        (foreign-callable-entry-point exit-callable)
        (foreign-callable-entry-point close-callable)))

(say "\n=== SQ3 summary (observations, not assertions) ===\n")
(say "machine-type                          : ~s\n" (machine-type))
(say "runs                                  : ~d x ~d + ~d x 1 (cat) + ~d x 1 (sh -c 'exec 3<&0; cat <&3 & exit 0')\n"
     target-runs target-trips short-runs early-exit-runs)
(say "round trips completed (total)         : ~d / ~d\n"
     (sum-of 'trips) (+ (* target-runs target-trips) short-runs early-exit-runs))
(say "bytes written / bytes read back       : ~d / ~d\n" (sum-of 'bytes-out) (sum-of 'bytes-in))
(say "payload verification failures         : ~d\n" (sum-of 'verify-fails))
(say "first bad byte                        : ~s\n" first-bad-trip)
(say "write callbacks / write errors        : ~d / ~d\n"
     (sum-of 'write-fires) (sum-of 'write-errors))
(say "alloc callbacks / read callbacks      : ~d / ~d\n"
     (sum-of 'alloc-fires) (sum-of 'read-fires))
(say "read callbacks with nread == 0        : ~d\n" (sum-of 'read-zero))
(say "read errors (other than UV_EOF)       : ~d\n" (sum-of 'read-errors))
(say "shutdown callbacks                    : ~d\n" (sum-of 'shutdown-fires))
(say "close callbacks (3 handles + watchdog): ~d\n" (sum-of 'close-fires))
(say "ORDERING: EOF before exit             : ~d run(s)  (long ~d / short ~d / early-exit ~d)\n"
     eof-first long-eof short-eof shared-eof)
(say "ORDERING: exit before EOF             : ~d run(s)  (long ~d / short ~d / early-exit ~d)\n"
     exit-first long-exit short-exit shared-exit)
(say "ORDERING: incomplete (one never came) : ~d run(s)\n" incomplete)
(say "distinct exit payloads seen           : ~s\n"
     (fold-left (lambda (a p) (if (member p a) a (append a (list p)))) '()
                (map (lambda (r) (cons (cdr (assq 'exit-status r))
                                       (cdr (assq 'exit-signal r))))
                     results)))
(say "distinct uv_loop_close rcs            : ~s\n"
     (fold-left (lambda (a p) (if (member p a) a (append a (list p)))) '()
                (map (lambda (r) (rc-name (cdr (assq 'loop-close r)))) results)))
(say "callable entry points stable          : ~s\n" (equal? ptrs-before ptrs-after))
(say "VERDICT: ~a\n"
     (if (and (= (sum-of 'trips) (+ (* target-runs target-trips) short-runs early-exit-runs))
              (= (sum-of 'bytes-in) (sum-of 'bytes-out))
              (zero? (sum-of 'verify-fails))
              (zero? (sum-of 'read-errors))
              (zero? (sum-of 'write-errors))
              (zero? incomplete)
              (equal? ptrs-before ptrs-after))
         "all deliveries accounted for, no corruption"
         "SOMETHING WAS LOST — see the per-run lines above"))
(exit 0)
