;;; spike/02-raise.ss — Q2: what a Scheme `raise` inside a libuv callback does
;;; when it tries to unwind across libuv's C stack frames.
;;;
;;; Usage:
;;;   chez --script spike/02-raise.ss <libuv.dylib> <scenario>
;;; where <scenario> is one of:
;;;   bare    — callback raises; NO guard anywhere. Baseline: what does an
;;;             unhandled raise inside a foreign-callable do to the process?
;;;   escape  — callback raises; a `guard` wraps the blocking `uv_run` call.
;;;             Does the condition reach that guard across the C frames?
;;;   store   — the design spec §8 policy: the trampoline guards the user
;;;             callback, STORES the condition, calls `uv_stop`, and the
;;;             condition is re-raised from Scheme after `uv_run` returns.
;;;
;;; In every scenario the timer fires up to 6 times and raises on fire 3.
;;; After the scenario resolves, the script interrogates the loop: is it still
;;; alive, can it be run again, does teardown return 0? That is the part that
;;; decides whether ADR-0008's store-and-reraise is a necessity or a taste.
;;;
;;; Constants come from spike/probe.

(import (chezscheme))

(define argv (command-line-arguments))

(define (usage)
  (display "usage: 02-raise.ss <libuv.dylib> <bare|escape|store>\n")
  (exit 2))

(define lib-path  (if (null? argv) (usage) (car argv)))
(define scenario  (if (or (null? argv) (null? (cdr argv))) (usage) (cadr argv)))

(unless (member scenario '("bare" "escape" "store")) (usage))

;;; --- probe-supplied constants ----------------------------------------------
(define UV_TIMER       13)
(define UV_RUN_DEFAULT 0)

(define raise-on-fire 3)
(define max-fires     6)

;;; --- load, THEN bind --------------------------------------------------------
(load-shared-object lib-path)

(define uv-loop-size   (foreign-procedure "uv_loop_size"   ()          size_t))
(define uv-handle-size (foreign-procedure "uv_handle_size" (int)       size_t))
(define uv-loop-init   (foreign-procedure "uv_loop_init"   (uptr)      int))
(define uv-loop-close  (foreign-procedure "uv_loop_close"  (uptr)      int))
(define uv-loop-alive  (foreign-procedure "uv_loop_alive"  (uptr)      int))
(define uv-timer-init  (foreign-procedure "uv_timer_init"  (uptr uptr) int))
(define uv-timer-start (foreign-procedure "uv_timer_start"
                                          (uptr uptr unsigned-64 unsigned-64) int))
(define uv-timer-stop  (foreign-procedure "uv_timer_stop"  (uptr)      int))
(define uv-run         (foreign-procedure "uv_run"         (uptr int)  int))
(define uv-stop        (foreign-procedure "uv_stop"        (uptr)      void))
(define uv-close       (foreign-procedure "uv_close"       (uptr uptr) void))
(define uv-strerror    (foreign-procedure "uv_strerror"    (int)       uptr))

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

;;; --- a condition type nothing else in the process can produce --------------
(define-condition-type &spike-raise &error
  make-spike-raise spike-raise?
  (fire spike-raise-fire))

;;; --- state ------------------------------------------------------------------
(define fire-count     0)
(define already-raised #f)
(define pending-error  'no-pending-error)   ; sentinel; no success path yields it
(define guard-saw      'guard-never-fired)  ; sentinel
(define second-run-fires 0)

;; Distinguishes "the handler ran in place, on top of the still-live C frame"
;; from "the continuation was invoked and the C frames were abandoned".
;; `dynamic-wind`'s after-thunk runs on BOTH a normal return and an escape, so
;; the two are counted separately; only an escape leaves `completed` false.
(define unwind-normal-returns 0)
(define unwind-escapes        0)

;;; --- the user callback, identical in all three scenarios -------------------
(define (user-callback handle)
  (set! fire-count (+ fire-count 1))
  (printf "  [cb] fire ~d\n" fire-count)
  (let ((completed #f))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (when (and (= fire-count raise-on-fire) (not already-raised))
          (set! already-raised #t)
          (printf "  [cb] raising on fire ~d\n" fire-count)
          (raise (condition (make-spike-raise fire-count)
                            (make-message-condition
                             "spike raise from inside a libuv callback"))))
        (set! completed #t))
      (lambda ()
        (if completed
            (set! unwind-normal-returns (+ unwind-normal-returns 1))
            (begin
              (set! unwind-escapes (+ unwind-escapes 1))
              (printf "  [dw] after-thunk ran WITHOUT normal completion -> a real escape\n")))))))

;;; --- the trampoline: the only thing that differs between scenarios ---------
(define (trampoline handle)
  (if (string=? scenario "store")
      ;; design spec §8: guard, store, uv_stop. Nothing unwinds into C.
      (guard (e (#t (set! pending-error e)
                    (printf "  [tr] caught inside callback; storing + uv_stop\n")
                    (uv-stop loop-ptr)))
        (user-callback handle))
      ;; bare / escape: let it fly straight at libuv's C frame.
      (user-callback handle))
  (when (>= fire-count max-fires)
    (printf "  [tr] reached max fires; uv_stop\n")
    (uv-stop loop-ptr)))

(define timer-callable (foreign-callable trampoline (uptr) void))
(lock-object timer-callable)
(define timer-cb-ptr (foreign-callable-entry-point timer-callable))

(define close-callable
  (foreign-callable (lambda (h) (set! close-count (+ close-count 1))) (uptr) void))
(define close-count 0)
(lock-object close-callable)
(define close-cb-ptr (foreign-callable-entry-point close-callable))

;;; --- set up -----------------------------------------------------------------
(define loop-ptr  (alloc-zeroed (uv-loop-size)))
(define timer-ptr (alloc-zeroed (uv-handle-size UV_TIMER)))

(printf "scenario = ~a\n" scenario)
(printf "uv_loop_init  = ~a\n" (rc-name (uv-loop-init loop-ptr)))
(printf "uv_timer_init = ~a\n" (rc-name (uv-timer-init loop-ptr timer-ptr)))
(printf "uv_timer_start= ~a\n" (rc-name (uv-timer-start timer-ptr timer-cb-ptr 1 1)))

;;; --- the experiment ---------------------------------------------------------
(display "MARKER: about to enter blocking uv_run\n")
(flush-output-port (current-output-port))

(define rc-run
  (if (string=? scenario "bare")
      ;; No guard at all. If this line does not return, the output simply stops
      ;; after the MARKER above and the exit code tells the rest of the story.
      (uv-run loop-ptr UV_RUN_DEFAULT)
      (guard (e (#t (set! guard-saw e)
                    (printf "MARKER: guard around uv_run FIRED\n")
                    'guard-fired))
        (uv-run loop-ptr UV_RUN_DEFAULT))))

(display "MARKER: uv_run returned normally to Scheme\n")
(printf "uv_run result = ~s\n" rc-run)
(printf "fire count    = ~d\n" fire-count)
(printf "guard around uv_run received: ~a\n"
        (cond ((eq? guard-saw 'guard-never-fired) "NOTHING (sentinel intact)")
              ((spike-raise? guard-saw)
               (format "the spike condition, fire=~d" (spike-raise-fire guard-saw)))
              (else (format "something else: ~s" guard-saw))))
(printf "stored pending-error: ~a\n"
        (cond ((eq? pending-error 'no-pending-error) "NOTHING (sentinel intact)")
              ((spike-raise? pending-error)
               (format "the spike condition, fire=~d" (spike-raise-fire pending-error)))
              (else (format "something else: ~s" pending-error))))
(printf "dynamic-wind after-thunk: ~d normal returns, ~d escapes\n"
        unwind-normal-returns unwind-escapes)

;;; --- store-and-reraise: the deliberate escape path of design spec §8 -------
(when (string=? scenario "store")
  (display "MARKER: re-raising the stored condition from Scheme\n")
  (let ((caught
         (guard (e (#t e))
           (raise (condition (make-error)
                             (make-message-condition "uv-run: callback raised")
                             pending-error))
           'reraise-did-not-raise)))
    (printf "re-raise caught outside uv_run: ~a\n"
            (if (spike-raise? caught)
                (format "original condition still matches, fire=~d"
                        (spike-raise-fire caught))
                (format "UNEXPECTED: ~s" caught)))))

;;; --- is the loop still usable? ---------------------------------------------
(printf "uv_loop_alive after the scenario = ~d\n" (uv-loop-alive loop-ptr))

(display "MARKER: attempting a SECOND uv_run on the same loop\n")
(flush-output-port (current-output-port))
(set! second-run-fires fire-count)
(define rc-run2
  (guard (e (#t (printf "MARKER: guard around SECOND uv_run FIRED\n") 'guard-fired))
    (uv-run loop-ptr UV_RUN_DEFAULT)))
(printf "second uv_run result = ~s\n" rc-run2)
(printf "fires during second uv_run = ~d\n" (- fire-count second-run-fires))

;;; --- teardown ---------------------------------------------------------------
(define rc-timer-stop (uv-timer-stop timer-ptr))
(printf "uv_timer_stop = ~a\n" (rc-name rc-timer-stop))
(uv-close timer-ptr close-cb-ptr)
(define rc-drain (uv-run loop-ptr UV_RUN_DEFAULT))
(printf "uv_run (drain)= ~d\n" rc-drain)
(printf "close_cb fired= ~d\n" close-count)
(define alive-after-drain (uv-loop-alive loop-ptr))
(printf "uv_loop_alive after drain = ~d\n" alive-after-drain)
(define rc-loop-close (uv-loop-close loop-ptr))
(printf "uv_loop_close = ~a\n" (rc-name rc-loop-close))
(foreign-free timer-ptr)
(foreign-free loop-ptr)
(display "MARKER: teardown complete, exiting 0\n")
(exit 0)
