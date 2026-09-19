;;; spike/threading/01-collect-safe-reentry.ss — T1: re-open THE GATE
;;; (spike/FINDINGS.md Q1) under `__collect_safe`.
;;;
;;; Usage:
;;;   chez --script spike/threading/01-collect-safe-reentry.ss \
;;;        /opt/homebrew/opt/libuv/lib/libuv.dylib [target-fires]
;;;
;;; WHY THIS EXISTS. Issue #19 wants uv_run rebound `__collect_safe` so a loop
;;; thread blocked in it stops freezing GC for every other Scheme thread. CSUG
;;; §4.3/4.8: a `__collect_safe` foreign procedure that can invoke callables
;;; requires EACH such callable to be `__collect_safe` too. So #19 converts the
;;; WHOLE callback layer, and the original Q1 proof (spike/01-callback-gc.ss:
;;; 10k re-entries, (collect) on every fire, clean teardown) ran PLAIN — it does
;;; NOT cover the collect-safe regime. This script is that proof redone with
;;; `__collect_safe` on uv_run AND on both callables, single-threaded, so any
;;; failure is attributable to the attribute and nothing else.
;;;
;;; A collect-safe foreign-callable runs with the calling thread reactivated for
;;; the callback's duration (Chez deactivates it for the surrounding collect-safe
;;; foreign call). The adversarial part is unchanged: allocate garbage and force
;;; (collect) on EVERY fire, so the heap moves under a live C stack frame
;;; (uv_run -> uv__run_timers -> this callable) — now with the collect interlock
;;; released around the enclosing uv_run.
;;;
;;; Constants are probe-supplied (ADR-0005 applied to the spike), matching
;;; spike/01-callback-gc.ss.

(import (chezscheme))

(define argv (command-line-arguments))
(define lib-path
  (if (null? argv)
      (begin (display "usage: 01-collect-safe-reentry.ss <libuv.dylib> [target]\n") (exit 2))
      (car argv)))
(define target-fires
  (if (or (null? argv) (null? (cdr argv))) 10000 (string->number (cadr argv))))

(define UV_TIMER       13)
(define UV_RUN_DEFAULT 0)

(load-shared-object lib-path)

;; THE difference from spike/01-callback-gc.ss: uv_run is __collect_safe.
(define uv-run          (foreign-procedure __collect_safe "uv_run" (uptr int) int))

(define uv-loop-size    (foreign-procedure "uv_loop_size"   ()          size_t))
(define uv-handle-size  (foreign-procedure "uv_handle_size" (int)       size_t))
(define uv-loop-init    (foreign-procedure "uv_loop_init"   (uptr)      int))
(define uv-loop-close   (foreign-procedure "uv_loop_close"  (uptr)      int))
(define uv-loop-alive   (foreign-procedure "uv_loop_alive"  (uptr)      int))
(define uv-timer-init   (foreign-procedure "uv_timer_init"  (uptr uptr) int))
(define uv-timer-start  (foreign-procedure "uv_timer_start"
                                           (uptr uptr unsigned-64 unsigned-64) int))
(define uv-timer-stop   (foreign-procedure "uv_timer_stop"  (uptr)      int))
(define uv-stop         (foreign-procedure "uv_stop"        (uptr)      void))
(define uv-close        (foreign-procedure "uv_close"       (uptr uptr) void))
(define uv-is-closing   (foreign-procedure "uv_is_closing"  (uptr)      int))
(define uv-strerror     (foreign-procedure "uv_strerror"    (int)       uptr))

(define (c-string->string addr)
  (if (= addr 0) #f
      (let loop ((i 0) (acc '()))
        (let ((b (foreign-ref 'unsigned-8 addr i)))
          (if (= b 0)
              (utf8->string (u8-list->bytevector (reverse acc)))
              (loop (+ i 1) (cons b acc)))))))
(define (alloc-zeroed n)
  (let ((p (foreign-alloc n)))
    (do ((i 0 (+ i 1))) ((= i n) p) (foreign-set! 'unsigned-8 p i 0))))
(define (rc-name rc) (if (zero? rc) "0" (c-string->string (uv-strerror rc))))

(define fire-count 0)
(define close-count 0)
(define handle-arg-seen 'none)
(define last-garbage-length 0)

;; Both callables __collect_safe, as the #19 conversion requires.
(define timer-callable
  (foreign-callable __collect_safe
   (lambda (handle)
     (set! fire-count (+ fire-count 1))
     (when (eq? handle-arg-seen 'none) (set! handle-arg-seen handle))
     (let loop ((i 0) (acc '()))
       (if (< i 1000)
           (loop (+ i 1) (cons i acc))
           (set! last-garbage-length (length acc))))
     (collect)
     (when (>= fire-count target-fires) (uv-stop loop-ptr)))
   (uptr) void))

(define close-callable
  (foreign-callable __collect_safe
   (lambda (handle) (set! close-count (+ close-count 1)))
   (uptr) void))

(lock-object timer-callable)
(lock-object close-callable)
(define timer-cb-ptr (foreign-callable-entry-point timer-callable))
(define close-cb-ptr (foreign-callable-entry-point close-callable))

(define timer-cb-ptr-before timer-cb-ptr)
(collect (collect-maximum-generation))
(define timer-cb-ptr-after (foreign-callable-entry-point timer-callable))

(define loop-size (uv-loop-size))
(define timer-size (uv-handle-size UV_TIMER))
(define loop-ptr (alloc-zeroed loop-size))
(define timer-ptr (alloc-zeroed timer-size))

(printf "target fires                    = ~d\n" target-fires)
(printf "locked entry stable across GC?  = ~s\n" (= timer-cb-ptr-before timer-cb-ptr-after))

(define rc-loop-init (uv-loop-init loop-ptr))
(define rc-timer-init (uv-timer-init loop-ptr timer-ptr))
(define rc-timer-start (uv-timer-start timer-ptr timer-cb-ptr 0 1))
(printf "uv_loop_init / timer_init/start = ~a / ~a / ~a\n"
        (rc-name rc-loop-init) (rc-name rc-timer-init) (rc-name rc-timer-start))

;; THE GATE, collect-safe: one blocking uv_run, target-fires re-entries.
(define rc-run (uv-run loop-ptr UV_RUN_DEFAULT))
(printf "uv_run(DEFAULT) collect-safe    = ~d (nonzero expected after uv_stop)\n" rc-run)
(printf "fire count after uv_run         = ~d\n" fire-count)

(define rc-timer-stop (uv-timer-stop timer-ptr))
(uv-close timer-ptr close-cb-ptr)
(define rc-drain (uv-run loop-ptr UV_RUN_DEFAULT))
(define alive-after-drain (uv-loop-alive loop-ptr))
(define rc-loop-close (uv-loop-close loop-ptr))
(foreign-free timer-ptr)
(foreign-free loop-ptr)
(collect (collect-maximum-generation))

(define (check name expected actual)
  (printf "~a: expected=~s actual=~s ~a\n"
          name expected actual (if (equal? expected actual) "OK" "MISMATCH")))
(display "\n--- checks ---\n")
(check "fire count exact"            target-fires fire-count)
(check "close_cb fired exactly once" 1            close-count)
(check "uv_loop_close rc"            0            rc-loop-close)
(check "uv_loop_alive after drain"   0            alive-after-drain)
(check "entry point stable"          #t           (= timer-cb-ptr-before timer-cb-ptr-after))
(check "handle arg round-tripped"    #t           (eqv? handle-arg-seen timer-ptr))
(check "garbage really was built"    1000         last-garbage-length)

(define ok?
  (and (= fire-count target-fires) (= close-count 1)
       (zero? rc-loop-init) (zero? rc-timer-init) (zero? rc-timer-start)
       (zero? rc-timer-stop) (zero? rc-loop-close) (zero? alive-after-drain)
       (= timer-cb-ptr-before timer-cb-ptr-after)
       (eqv? handle-arg-seen timer-ptr) (= last-garbage-length 1000)))
(printf "\nRESULT: ~a\n" (if ok? "PASS" "FAIL"))
(exit (if ok? 0 1))
