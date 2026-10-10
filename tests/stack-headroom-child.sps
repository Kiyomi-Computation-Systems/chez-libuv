#!r6rs
;;; Child program for tests/test-stack-headroom.sps (#94). Each mode fills a
;;; thread's C stack on purpose, and a binding that let a run through too
;;; deep would crash this process with SIGSEGV, or on macOS hang it (#95),
;;; so it runs in a process of its own, under tests/uv-level-3.sls's
;;; deadline. Its work runs on a thread made with fork-thread: 512 KiB on
;;; macOS, 8 MiB on Linux, made after the main thread has run a loop.
;;;
;;; It prints one datum, an alist, for the suite's rows:
;;;   floors   runs and teardowns at a depth between the two floors, and at
;;;            one under the teardown floor, reached by nesting libc qsort
;;;            comparator callbacks, all of which then return
;;;   escapes  what one escape from a timer callback and one from an async
;;;            callback cost, then escapes from async callbacks until uv-run
;;;            refuses, and how many of the loops made meanwhile are open
(import (rnrs)
        (libuv loop)
        (libuv timer)
        (libuv async)
        (uv-describe)
        (only (libuv private native) stack-headroom)
        (only (libuv private handles) run-stack-floor teardown-stack-floor)
        (only (libuv private conditions)
              uv-stack-exhausted? uv-stack-exhausted-who
              uv-stack-exhausted-headroom uv-stack-exhausted-floor)
        (only (chezscheme)
              fork-thread make-mutex make-condition with-mutex
              condition-wait condition-signal collect
              load-shared-object foreign-procedure foreign-callable
              foreign-callable-entry-point lock-object unlock-object
              foreign-alloc foreign-free))

(define mode (string->symbol (cadr (command-line))))

;; libc, for qsort. The binding loads libuv only when one of its libraries
;; is first used, so qsort's entry cannot be counted on being there yet.
(let load ((names '("libc.so.6" "libc.dylib" "libc.so")))
  (guard (e ((pair? (cdr names)) (load (cdr names))))
    (load-shared-object (car names))))

(define qsort (foreign-procedure "qsort" (uptr size_t size_t uptr) void))

;; at-headroom : exact-integer (-> object) -> object
;; THUNK's value, called with this thread's headroom just under BELOW:
;; from inside nested qsort comparator callbacks, each a few hundred bytes
;; of C stack. Every callback returns once THUNK has, and none escapes, so
;; nothing is left on the stack. A comparator called again after THUNK has
;; run returns at once.
(define (at-headroom below thunk)
  (let ((buf (foreign-alloc 16)) (result #f) (callable #f))
    (define (nest)
      (cond (result 'done)
            ((< (stack-headroom) below) (set! result (list (thunk))))
            (else (qsort buf 2 8 (foreign-callable-entry-point callable)))))
    (set! callable (foreign-callable (lambda (a b) (nest) 0) (uptr uptr) int))
    (lock-object callable)
    (nest)
    (unlock-object callable)
    (foreign-free buf)
    (car result)))

;; refusal : condition -> list
(define (refusal e)
  (list 'refused (uv-stack-exhausted-who e) (uv-stack-exhausted-floor e)
        (uv-stack-exhausted-headroom e)))

;; try-run : uv-loop -> (or list 'ran)
(define (try-run loop)
  (guard (e ((uv-stack-exhausted? e) (refusal e)))
    (uv-run loop)
    'ran))

;; try-teardown : uv-loop -> (or list 'torn-down)
(define (try-teardown loop)
  (guard (e ((uv-stack-exhausted? e) (refusal e)))
    (uv-loop-teardown! loop)
    'torn-down))

;; A loop with a timer started on it, so that a run of it has work.
(define (loop-with-work)
  (let ((loop (make-uv-loop)))
    (uv-timer-start! (make-uv-timer loop) (lambda (t) #f) 0 0)
    loop))

;; Halfway between the floors, and halfway between the deepest path a run
;; was measured to need (35.8 KiB, macOS, a collection in an I/O
;; callback) and the teardown floor.
(define between-floors (div (+ run-stack-floor teardown-stack-floor) 2))
(define under-teardown-floor 49152)

(define (floors)
  (let* ((between
          (at-headroom between-floors
                       (lambda ()
                         (let* ((loop (loop-with-work))
                                (run (try-run loop))
                                (teardown (try-teardown loop)))
                           (list run teardown (uv-loop-open? loop))))))
         (deep-loop (loop-with-work))
         (under
          (at-headroom under-teardown-floor
                       (lambda ()
                         (let* ((run (try-run deep-loop))
                                (teardown (try-teardown deep-loop)))
                           (list run teardown)))))
         (after (try-teardown deep-loop)))
    (list (cons 'between between)
          (cons 'under under)
          (cons 'after-return (list after (uv-loop-open? deep-loop))))))

;; escape-once : (uv-loop -> unspecified) (uv-loop -> unspecified)
;;               -> (or 'escaped list)
;; One call-with-uv-loop body that arms a callback with ARM, whose
;; callback leaves by a continuation captured outside the body, or the
;; refusal its run raised. NOTE is handed each loop made.
(define (escape-once arm note)
  (guard (e ((uv-stack-exhausted? e) (refusal e)))
    (call/cc
     (lambda (k)
       (call-with-uv-loop
        (lambda (loop)
          (note loop)
          (arm loop (lambda () (k 'escaped)))
          (uv-run loop)
          'returned))))))

(define (arm-timer loop leave)
  (uv-timer-start! (make-uv-timer loop) (lambda (t) (leave)) 0 0))

(define (arm-async loop leave)
  (uv-async-send! (make-uv-async loop (lambda (a) (leave)))))

;; More escapes than any 8 MiB stack holds from async callbacks.
(define escape-cap 2000)

(define (escapes)
  (let* ((loops '())
         (note (lambda (loop) (set! loops (cons loop loops))))
         (h0 (stack-headroom))
         (first-timer (escape-once arm-timer note))
         (h1 (stack-headroom))
         (first-async (escape-once arm-async note))
         (h2 (stack-headroom)))
    (let more ((n 0))
      (let ((answer (escape-once arm-async note)))
        (cond
         ((and (eq? answer 'escaped) (< n escape-cap)) (more (+ n 1)))
         (else
          (collect)
          (list (cons 'first (list first-timer first-async))
                (cons 'timer-strand (- h0 h1))
                (cons 'async-strand (- h1 h2))
                (cons 'escapes n)
                (cons 'last answer)
                (cons 'open-loops
                      (length (filter uv-loop-open? loops))))))))))

;; on-thread : (-> object) -> object
(define (on-thread thunk)
  (let ((m (make-mutex)) (c (make-condition)) (done #f))
    (fork-thread
     (lambda ()
       (let ((r (guard (e (#t (list 'raised (describe e)))) (thunk))))
         (with-mutex m (set! done (list r)) (condition-signal c)))))
    (with-mutex m
      (let wait () (unless done (condition-wait c m) (wait))))
    (car done)))

;; The main thread runs a loop first, so it has read its own stack bottom,
;; and the thread made next starts with that cached: a thread that measured
;; against it would never be refused.
(call-with-uv-loop (lambda (loop) (uv-run loop 'nowait)))

(write (on-thread (case mode
                    ((floors) floors)
                    ((escapes) escapes)
                    (else (lambda () (list 'unknown-mode mode))))))
(newline)
