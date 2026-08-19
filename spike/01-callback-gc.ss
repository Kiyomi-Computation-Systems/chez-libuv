;;; spike/01-callback-gc.ss — Q1 (THE GATE): C -> Scheme re-entry from inside a
;;; blocking uv_run, under GC pressure on every single fire.
;;;
;;; Usage:
;;;   chez --script spike/01-callback-gc.ss \
;;;        /opt/homebrew/opt/libuv/lib/libuv.dylib [target-fires]
;;;
;;; What this proves (or refutes):
;;;   libuv, from inside a blocking `uv_run`, can re-enter a locked
;;;   `foreign-callable` 10,000 times; the callback may allocate and force a
;;;   full `(collect)` on every fire; the counter is exact; teardown is clean;
;;;   the process exits 0. This is the assumption ADR-0002 (direct FFI) and
;;;   ADR-0008 (eight static locked trampolines) rest on.
;;;
;;; Also answers: does `foreign-callable-entry-point` of a LOCKED callable stay
;;; at the same address across `(collect)`? (libuv retains the pointer for the
;;; whole life of the handle, so a moving entry point would be fatal.)
;;;
;;; uv_run is bound PLAIN — no `__collect_safe`. The interaction between
;;; `__collect_safe` and callback re-entry is deliberately NOT tested here:
;;; v0.1 is single-threaded (ADR-0008), and mixing the two axes would make a
;;; failure un-attributable. Deferred, on purpose, and recorded in FINDINGS.md.
;;;
;;; Every constant below (UV_TIMER, UV_RUN_DEFAULT, struct sizes) comes from
;;; spike/probe, never from memory (ADR-0005's rule applied to the spike).

(import (chezscheme))

(define argv (command-line-arguments))

(define lib-path
  (if (null? argv)
      (begin (display "usage: 01-callback-gc.ss <libuv.dylib> [target]\n") (exit 2))
      (car argv)))

(define target-fires
  (if (or (null? argv) (null? (cdr argv)))
      10000
      (string->number (cadr argv))))

;;; --- probe-supplied constants (spike/probe output) --------------------------
(define UV_TIMER       13)
(define UV_RUN_DEFAULT 0)

;;; --- load, THEN bind (Q0's trap) -------------------------------------------
(load-shared-object lib-path)

(define uv-loop-size    (foreign-procedure "uv_loop_size"    ()             size_t))
(define uv-handle-size  (foreign-procedure "uv_handle_size"  (int)          size_t))
(define uv-loop-init    (foreign-procedure "uv_loop_init"    (uptr)         int))
(define uv-loop-close   (foreign-procedure "uv_loop_close"   (uptr)         int))
(define uv-loop-alive   (foreign-procedure "uv_loop_alive"   (uptr)         int))
(define uv-timer-init   (foreign-procedure "uv_timer_init"   (uptr uptr)    int))
(define uv-timer-start  (foreign-procedure "uv_timer_start"
                                           (uptr uptr unsigned-64 unsigned-64) int))
(define uv-timer-stop   (foreign-procedure "uv_timer_stop"   (uptr)         int))
(define uv-run          (foreign-procedure "uv_run"          (uptr int)     int))
(define uv-stop         (foreign-procedure "uv_stop"         (uptr)         void))
(define uv-close        (foreign-procedure "uv_close"        (uptr uptr)    void))
(define uv-is-closing   (foreign-procedure "uv_is_closing"   (uptr)         int))
(define uv-strerror     (foreign-procedure "uv_strerror"     (int)          uptr))

(define (c-string->string addr)
  (if (= addr 0)
      #f
      (let loop ((i 0) (acc '()))
        (let ((b (foreign-ref 'unsigned-8 addr i)))
          (if (= b 0)
              (utf8->string (u8-list->bytevector (reverse acc)))
              (loop (+ i 1) (cons b acc)))))))

(define (alloc-zeroed n)
  (let ((p (foreign-alloc n)))
    (do ((i 0 (+ i 1))) ((= i n) p)
      (foreign-set! 'unsigned-8 p i 0))))

(define (rc-name rc) (if (zero? rc) "0" (c-string->string (uv-strerror rc))))

;;; --- state -----------------------------------------------------------------
(define fire-count 0)
(define close-count 0)
(define handle-arg-seen 'none)   ; sentinel: no success path produces 'none

;;; --- the callbacks: created once, locked once ------------------------------
;;; Signature check: uv_timer_cb is  void (*)(uv_timer_t *handle)
;;;                  uv_close_cb is  void (*)(uv_handle_t *handle)
;;; Both take exactly one pointer and return nothing.

(define timer-callable
  (foreign-callable
   (lambda (handle)
     (set! fire-count (+ fire-count 1))
     (when (eq? handle-arg-seen 'none) (set! handle-arg-seen handle))
     ;; Allocate garbage, then force a collection, on EVERY fire. This is the
     ;; adversarial part: the Scheme heap moves under a live C stack frame
     ;; (uv_run -> uv__run_timers -> this callable) 10,000 times.
     (let loop ((i 0) (acc '()))
       (if (< i 1000)
           (loop (+ i 1) (cons i acc))
           (set! last-garbage-length (length acc))))
     (collect)
     (when (>= fire-count target-fires)
       (uv-stop loop-ptr)))
   (uptr) void))

(define last-garbage-length 0)

(define close-callable
  (foreign-callable
   (lambda (handle)
     (set! close-count (+ close-count 1)))
   (uptr) void))

(lock-object timer-callable)
(lock-object close-callable)

(define timer-cb-ptr (foreign-callable-entry-point timer-callable))
(define close-cb-ptr (foreign-callable-entry-point close-callable))

;;; --- entry-point stability across (collect) --------------------------------
(define timer-cb-ptr-before timer-cb-ptr)
(define close-cb-ptr-before close-cb-ptr)
(collect)
(collect (collect-maximum-generation))
(define timer-cb-ptr-after (foreign-callable-entry-point timer-callable))
(define close-cb-ptr-after (foreign-callable-entry-point close-callable))

;; Raw addresses go to stderr: they are ASLR/heap dependent and would make
;; stdout non-reproducible. The stable/moved VERDICT goes to stdout.
(fprintf (current-error-port)
         "addresses: timer ~x -> ~x ; close ~x -> ~x\n"
         timer-cb-ptr-before timer-cb-ptr-after
         close-cb-ptr-before close-cb-ptr-after)

;;; --- allocate the loop and the timer ---------------------------------------
(define loop-size (uv-loop-size))
(define timer-size (uv-handle-size UV_TIMER))
(define loop-ptr (alloc-zeroed loop-size))
(define timer-ptr (alloc-zeroed timer-size))

(printf "uv_loop_size()             = ~d\n" loop-size)
(printf "uv_handle_size(UV_TIMER)   = ~d\n" timer-size)
(printf "locked timer entry point stable across (collect)? ~s\n"
        (= timer-cb-ptr-before timer-cb-ptr-after))
(printf "locked close entry point stable across (collect)? ~s\n"
        (= close-cb-ptr-before close-cb-ptr-after))
(printf "target fires               = ~d\n" target-fires)

(define rc-loop-init (uv-loop-init loop-ptr))
(printf "uv_loop_init               = ~a\n" (rc-name rc-loop-init))

(define rc-timer-init (uv-timer-init loop-ptr timer-ptr))
(printf "uv_timer_init              = ~a\n" (rc-name rc-timer-init))

;; timeout 0, repeat 1ms, repeating mode.
(define rc-timer-start (uv-timer-start timer-ptr timer-cb-ptr 0 1))
(printf "uv_timer_start(0,1,repeat) = ~a\n" (rc-name rc-timer-start))

;;; --- THE GATE: one blocking uv_run, 10,000 re-entries ----------------------
(define rc-run (uv-run loop-ptr UV_RUN_DEFAULT))
(printf "uv_run(UV_RUN_DEFAULT)     = ~d  (nonzero = handles still active, expected after uv_stop)\n"
        rc-run)
(printf "fire count after uv_run    = ~d\n" fire-count)

;;; --- teardown: stop, close (with close_cb), drain, close loop, free --------
(define rc-timer-stop (uv-timer-stop timer-ptr))
(printf "uv_timer_stop              = ~a\n" (rc-name rc-timer-stop))

(uv-close timer-ptr close-cb-ptr)
(printf "uv_is_closing after close  = ~d\n" (uv-is-closing timer-ptr))
(printf "close_cb fired before drain= ~d\n" close-count)

;; Drain: run the loop until nothing is alive. close_cb fires here.
(define rc-drain (uv-run loop-ptr UV_RUN_DEFAULT))
(printf "uv_run (drain)             = ~d\n" rc-drain)
(printf "close_cb fired after drain = ~d\n" close-count)

;; Captured BEFORE uv_loop_close + foreign-free. Reading it afterwards is a
;; use-after-free; the first draft of this script did exactly that and got a
;; plausible-looking wrong answer back (see FINDINGS.md Q1, "surprises").
(define alive-after-drain (uv-loop-alive loop-ptr))
(printf "uv_loop_alive after drain  = ~d\n" alive-after-drain)

(define rc-loop-close (uv-loop-close loop-ptr))
(printf "uv_loop_close              = ~a\n" (rc-name rc-loop-close))

(foreign-free timer-ptr)
(foreign-free loop-ptr)
(display "foreign-free               = done\n")

;; Opt-in reproduction of the surprise recorded in FINDINGS.md Q1: calling a
;; uv_* accessor on a freed loop pointer does NOT fault and does NOT return 0 —
;; it returns a plausible-looking wrong answer. Off by default because the
;; value it prints is, by definition, whatever the allocator left behind.
;; Goes to stderr so the default stdout stays byte-reproducible.
(when (and (pair? argv) (pair? (cdr argv)) (pair? (cddr argv))
           (string=? (caddr argv) "uaf-demo"))
  (fprintf (current-error-port)
           "UAF DEMO: uv_loop_alive(freed loop-ptr) = ~d  (correct answer is 0)\n"
           (uv-loop-alive loop-ptr)))

;; One more full collection after every C pointer is gone, to shake out any
;; GC interaction the teardown might have left behind.
(collect (collect-maximum-generation))
(display "post-teardown collect      = done\n")

;;; --- assertions ------------------------------------------------------------
(define (check name expected actual)
  (printf "~a: expected=~s actual=~s ~a\n"
          name expected actual (if (equal? expected actual) "OK" "MISMATCH")))

(display "\n--- checks ---\n")
(check "fire count exact"            target-fires fire-count)
(check "close_cb fired exactly once" 1            close-count)
(check "uv_loop_init rc"             0            rc-loop-init)
(check "uv_timer_init rc"            0            rc-timer-init)
(check "uv_timer_start rc"           0            rc-timer-start)
(check "uv_timer_stop rc"            0            rc-timer-stop)
(check "uv_loop_close rc"            0            rc-loop-close)
(check "uv_loop_alive after drain"   0            alive-after-drain)
(check "timer entry point stable"    #t           (= timer-cb-ptr-before timer-cb-ptr-after))
(check "close entry point stable"    #t           (= close-cb-ptr-before close-cb-ptr-after))
;; Sentinel: 'none is what a callback that NEVER RAN would leave behind, and it
;; is `eqv?` to no pointer, so it cannot satisfy this check by accident. The
;; comparison, not the addresses, is printed to stdout — raw addresses vary per
;; run and would make stdout non-reproducible; they go to stderr instead.
(fprintf (current-error-port) "handle arg: allocated ~x, callback saw ~a\n"
         timer-ptr
         (if (symbol? handle-arg-seen)
             handle-arg-seen
             (number->string handle-arg-seen 16)))
(check "handle arg round-tripped"    #t   (eqv? handle-arg-seen timer-ptr))
(check "garbage really was built"    1000         last-garbage-length)

(define ok?
  (and (= fire-count target-fires)
       (= close-count 1)
       (zero? rc-loop-init) (zero? rc-timer-init) (zero? rc-timer-start)
       (zero? rc-timer-stop) (zero? rc-loop-close)
       (zero? alive-after-drain)
       (= timer-cb-ptr-before timer-cb-ptr-after)
       (= close-cb-ptr-before close-cb-ptr-after)
       (eqv? handle-arg-seen timer-ptr)
       (= last-garbage-length 1000)))

(printf "\nRESULT: ~a\n" (if ok? "PASS" "FAIL"))
(exit (if ok? 0 1))
