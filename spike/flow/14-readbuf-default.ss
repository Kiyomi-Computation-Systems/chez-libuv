#!chezscheme
;;; Q1 — what should default-read-buffer-size be?
;;;
;;; v0.5 design spec §10 Q1. v0.5 deliberately did NOT change the default: an
;;; early draft proposed 65536 -> 16384 on memory grounds alone, and that was
;;; wrong on its own terms, because a smaller buffer proportionally multiplies
;;; `on-data` deliveries and every delivery allocates a fresh bytevector
;;; (handles.sls, copy-out). The tradeoff is three-way -- foreign memory
;;; against Scheme GC churn against read(2) count -- and nobody had measured
;;; any of it. The milestone shipped the lever, the documentation and a pin on
;;; the current value instead, so the change could be made later on evidence.
;;;
;;; This is that evidence. It does not choose the default; it produces the
;;; numbers a later milestone chooses from, with its own ADR.
;;;
;;; THE TERM THE FIRST DRAFT OMITTED is Leg B's GC column, and measuring it
;;; sharpened the claim. `copy-out` allocates a bytevector of exactly `nread`
;;; bytes per delivery, so the total BYTES allocated for a given transfer are
;;; INVARIANT in the buffer size -- 16 MiB moved is 16 MiB of bytevectors at
;;; every size. What the buffer size changes is the OBJECT COUNT: 4096 bytes
;;; per delivery means sixteen times as many allocations as 65536 for the same
;;; payload. So the draft's "quadruples Scheme allocation churn" was
;;; directionally right and imprecisely stated -- the pressure is in the
;;; number of objects, not the volume -- and gc-count is what measures it.
;;;
;;; (`bytes-allocated` is NOT that measure and was tried first: it reports
;;; bytes currently LIVE, so a collection inside the window makes the delta
;;; negative. An early run of this script reported -1460 KiB.)
(import (rnrs)
        (libuv loop) (libuv handle) (libuv tcp) (libuv stream)
        (uv-testing)
        (only (libuv private native) live-counts)
        (only (chezscheme) real-time cpu-time format
              statistics sstats-gc-count sstats-gc-cpu
              time-second time-nanosecond
              open-input-file close-input-port))

(define sizes '(4096 16384 65536))
(define conns 200)                       ; Leg A: the memory floor
(define transfer (* 16 1024 1024))       ; Leg B: 16 MiB through one socket
(define mib (* 1024 1024))

;; Resident set, in KiB, from /proc/self/status. Linux only; 0 elsewhere, and
;; the caller reports the leg as unavailable rather than printing a fake zero.
(define (vm-rss-kib)
  (if (not (file-exists? "/proc/self/status"))
      0
      (let ((p (open-input-file "/proc/self/status")))
        (let loop ()
          (let ((line (get-line p)))
            (cond ((eof-object? line) (close-input-port p) 0)
                  ((and (> (string-length line) 6)
                        (string=? (substring line 0 6) "VmRSS:"))
                   (close-input-port p)
                   (let ((n (string->number
                             (list->string
                              (filter char-numeric? (string->list line))))))
                     (or n 0)))
                  (else (loop))))))))

(define (live-read-buffers)
  (let ((e (assq 'read-buffer (live-counts))))
    (if e (cdr e) 'no-counter)))

;; --- Leg A: what does N read-started connections cost in memory? ----------
(define (leg-a size)
  (let* ((rss0 (vm-rss-kib))
         (loop (make-uv-loop))
         (server (make-uv-tcp loop))
         (port (bind-loopback! server))
         (peers '()) (clients '()))
    (uv-listen! server 1024
                (lambda (err)
                  (when (not err)
                    (set! peers (cons (uv-accept! server) peers)))))
    (let b ((i 0))
      (when (< i conns)
        (let ((c (make-uv-tcp loop)))
          (set! clients (cons c clients))
          (connect-loopback! c port (lambda (e) #f))
          (b (+ i 1)))))
    (run-until/ticking loop (lambda () (= (length peers) conns)) 200000)
    ;; The buffer is allocated by the FIRST read-start and its size fixed
    ;; there, so this is the moment the floor is paid.
    (for-each (lambda (p)
                (uv-read-start! p (lambda (bv s e) #f) (lambda () #f)
                                (lambda (c) #f) size))
              peers)
    (let ((rss1 (vm-rss-kib))
          (live (live-read-buffers)))
      (format #t "  A: ~a live buffers, expected foreign ~a KiB, RSS delta ~a KiB~%"
              live
              (div (* conns size) 1024)
              (- rss1 rss0)))
    (uv-loop-teardown! loop)
    (uv-loop-close! loop)))

;; --- Leg B: deliveries, Scheme allocation and time for a fixed transfer ---
;; ONE connection, a fixed number of bytes, everything else held constant.
;; Deliveries is the read(2)-count proxy; bytes-allocated is the GC-pressure
;; term; real/cpu time is the throughput term.
(define (leg-b size)
  (let* ((loop (make-uv-loop))
         (server (make-uv-tcp loop))
         (port (bind-loopback! server))
         (peer 'none) (got 0) (deliveries 0)
         (chunk (seeded-bytes 65536 11)))
    (uv-listen! server 4
                (lambda (err)
                  (when (and (not err) (eq? peer 'none))
                    (set! peer (uv-accept! server)))))
    (let ((client (make-uv-tcp loop)))
      (connect-loopback! client port (lambda (e) #f))
      (run-until/ticking loop (lambda () (not (eq? peer 'none))) 20000)
      (uv-read-start! peer
                      (lambda (bv s e)
                        (set! deliveries (+ deliveries 1))
                        (set! got (+ got (- e s))))
                      (lambda () #f) (lambda (c) #f)
                      size)
      (let* ((st0 (statistics))
             (rt0 (real-time)) (ct0 (cpu-time)))
        (let pump ((sent 0))
          (when (< sent transfer)
            (uv-write! client chunk (lambda (e) #f))
            (run-until/ticking loop (lambda () #f) 2)
            (pump (+ sent 65536))))
        (run-until/ticking loop (lambda () (>= got transfer)) 400000)
        (let* ((st1 (statistics))
               (rt1 (real-time)) (ct1 (cpu-time))
               (mibs (div transfer mib))
               (gcs (- (sstats-gc-count st1) (sstats-gc-count st0)))
               (gc-ns (lambda (s) (+ (* 1000000000 (time-second (sstats-gc-cpu s)))
                                     (time-nanosecond (sstats-gc-cpu s)))))
               (gc-us (div (- (gc-ns st1) (gc-ns st0)) 1000)))
          (format #t "  B: ~a deliveries (~a/MiB) = ~a bytevector allocs; ~a GCs, ~a us GC cpu; real ~a ms, cpu ~a ms~%"
                  deliveries (div deliveries mibs) deliveries
                  gcs gc-us
                  (- rt1 rt0) (- ct1 ct0))
          (when (< got transfer)
            (format #t "     SURPRISE: only ~a of ~a bytes arrived~%" got transfer)))))
    (uv-loop-teardown! loop)
    (uv-loop-close! loop)))

;; --- main -----------------------------------------------------------------
(format #t "Q1 -- read-buffer default. conns=~a for Leg A, ~a MiB for Leg B.~%"
        conns (div transfer mib))
(when (zero? (vm-rss-kib))
  (display "  (no /proc/self/status: Leg A's RSS column is unavailable here)")
  (newline))
(for-each
 (lambda (size)
   (format #t "~%size = ~a bytes~%" size)
   (leg-a size)
   (leg-b size))
 sizes)
(newline)
(display "Leg A is the floor you pay for existing; Leg B is what you pay per byte.")
(newline)
(display "A smaller buffer trades the first against the second and third.")
(newline)
