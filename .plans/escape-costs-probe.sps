;;; #94 probes, run from the repository root:
;;;   CHEZSCHEMELIBDIRS=src:tests scheme --program .plans/escape-costs-probe.sps MODE N [thread]
;;; .plans/escape-costs-mutation-log.md records what each mode measured.
(import (chezscheme) (libuv loop) (libuv timer) (libuv handle))

(define mode (string->symbol (cadr (command-line))))
(define n (string->number (caddr (command-line))))
(define on-thread? (and (> (length (command-line)) 3)
                        (string=? (cadddr (command-line)) "thread")))

(define (vmstk)
  (call-with-input-file "/proc/self/status"
    (lambda (p)
      (let loop ()
        (let ((l (get-line p)))
          (cond ((eof-object? l) "?")
                ((and (>= (string-length l) 6) (string=? (substring l 0 6) "VmStk:")) l)
                (else (loop))))))))

;; One escape: a call-with-uv-loop body left from a timer callback.
(define (escape-once)
  (guard (e (#t #f))
    (call/cc
     (lambda (k)
       (call-with-uv-loop
        (lambda (loop)
          (uv-timer-start! (make-uv-timer loop) (lambda (t) (k 'escaped)) 0 0)
          (uv-run loop 'default)))))))

;; One raise from a timer callback, caught outside the run.
(define (raise-once)
  (guard (e (#t 'caught))
    (call-with-uv-loop
     (lambda (loop)
       (uv-timer-start! (make-uv-timer loop) (lambda (t) (raise 'boom)) 0 0)
       (uv-run loop 'default)))))

;; An engine that runs a raw loop whose timer callback blocks the engine,
;; so it expires inside the callback. Answers the engine's continuation.
(define (suspend-in-callback tag)
  (let* ((loop (make-uv-loop))
         (eng (make-engine
               (lambda ()
                 (let ((t (make-uv-timer loop)))
                   (uv-timer-start! t (lambda (h) (engine-block) (uv-close! h)) 0 0)
                   (uv-run loop 'default)
                   (uv-loop-close! loop)
                   tag)))))
    (eng 1000000
         (lambda (fuel v) (error 'probe "engine finished without expiring" v))
         (lambda (k) k))))

(define (resume k)
  (k 1000000 (lambda (fuel v) v) (lambda (k2) (error 'probe "expired again"))))

(define (report what)
  (printf "~a ~a done; ~a\n" mode what (vmstk)))

(define (run)
  (case mode
    ((escape)
     (let lp ((i 0)) (when (< i n) (escape-once) (lp (+ i 1))))
     (report n))
    ((raise)
     (let lp ((i 0)) (when (< i n) (raise-once) (lp (+ i 1))))
     (report n))
    ((engine-resume)
     ;; suspend inside a callback, then resume to the end, n times
     (let lp ((i 0))
       (when (< i n) (resume (suspend-in-callback i)) (lp (+ i 1))))
     (report n))
    ((engine-drop)
     (let lp ((i 0))
       (when (< i n) (suspend-in-callback i) (lp (+ i 1))))
     (report n))
    ((lifo fifo)
     ;; two engines suspended inside callbacks on one thread, resumed in order
     (let* ((a (suspend-in-callback 'a))
            (b (suspend-in-callback 'b))
            (order (if (eq? mode 'lifo) (list b a) (list a b))))
       (for-each
        (lambda (k)
          (printf "~a resume -> ~s\n" mode
                  (guard (e (#t (list 'raised
                                      (if (message-condition? e) (condition-message e) e))))
                    (resume k))))
        order)))
    ((reclaim)
     ;; n escapes in batches of 1000, each batch above an engine suspended
     ;; inside a callback and resumed after the batch
     (let lp ((done 0))
       (when (< done n)
         (let ((k (suspend-in-callback done)))
           (let b ((i 0)) (when (< i 1000) (escape-once) (b (+ i 1))))
           (resume k))
         (lp (+ done 1000))))
     (report n))
    (else (error 'probe "unknown mode" mode))))

(if on-thread?
    (let ((m (make-mutex)) (c (make-condition)) (fin #f))
      (fork-thread (lambda () (run) (with-mutex m (set! fin #t) (condition-signal c))))
      (with-mutex m (let w () (unless fin (condition-wait c m) (w))))
      (printf "thread survived\n"))
    (run))
