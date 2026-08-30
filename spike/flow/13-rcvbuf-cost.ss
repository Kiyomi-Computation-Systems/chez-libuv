#!chezscheme
;;; Q2 — what does the OS receive buffer actually cost per connection?
;;;
;;; v0.5 design spec §10 Q2. This question exists because its answer ALREADY
;;; SHIPPED, unmeasured: docs/api.md's three-buffers table and
;;; src/libuv/handle.sls's comment both told readers the Linux receive buffer
;;; "can substantially exceed" the per-handle read buffer at high connection
;;; counts. The spec said in as many words that the assertion was "currently
;;; arithmetic, not measurement" and scheduled this leg to settle it. The leg
;;; was dropped; the arithmetic shipped anyway.
;;;
;;; LINUX ONLY, and deliberately so. SO_RCVBUF autotuning, /proc/sys/net/ipv4
;;; and /proc/net/sockstat are all Linux concepts, and the claim under test is
;;; explicitly a claim about Linux. On any other platform this script reports
;;; SKIPPED rather than inventing a number.
;;;
;;; TWO LEGS, because the honest answer differs between them and the shipped
;;; claim conflates them:
;;;
;;;   IDLE   — N accepted connections, nothing written. What does the kernel
;;;            actually hold? SO_RCVBUF says one thing; sockstat says another.
;;;   UNREAD — the same connections with data pushed in and NEVER read. This
;;;            is what a consumer with no backpressure discipline produces,
;;;            and it is the case the shipped claim is closest to describing.
;;;
;;; Sampling /proc/net/sockstat's TCP `mem` column is the discriminating
;;; measurement. SO_RCVBUF is a CEILING the kernel may grow to; sockstat
;;; reports pages actually charged. Reading only the former is how a
;;; per-connection "cost" gets asserted that the kernel never pays.
(import (rnrs)
        (libuv loop) (libuv handle) (libuv tcp) (libuv stream)
        (uv-testing)
        (only (chezscheme) system format))

(define page-bytes 4096)

(define (linux?)
  (file-exists? "/proc/net/sockstat"))

;; The TCP `mem` column, in pages. Written to a temp file rather than parsed
;; from a pipe because this spike wants one number, not a formatting contract
;; with awk.
(define (tcp-mem-pages)
  (let ((tmp "/tmp/.sockstat-mem"))
    (system (string-append
             "awk '/^TCP:/{print $11}' /proc/net/sockstat > " tmp))
    (let* ((p (open-input-file tmp))
           (v (read p)))
      (close-input-port p)
      (if (number? v) v 'unreadable))))

(define (report tag pages n)
  (format #t "  ~a: TCP mem = ~a pages (~a MiB total, ~a KiB/conn)~%"
          tag pages
          (div (* pages page-bytes) (* 1024 1024))
          (if (positive? n) (div (* pages page-bytes) (* n 1024)) 0)))

(define (sysctl-line path)
  (system (string-append "printf '  %-28s ' " path
                         " 2>/dev/null; cat " path " 2>/dev/null || true")))

;; --- the measurement ------------------------------------------------------
;; Both ends live in THIS process, so kernel memory charged below covers the
;; client's send queues as well as the peer's receive queues. That is stated
;; rather than corrected for: a real server has only one end, so treat the
;; per-connection figures as an upper bound on the receive side alone.
(define (measure n writes-per-client)
  (let* ((loop   (make-uv-loop))
         (server (make-uv-tcp loop))
         (port   (bind-loopback! server))
         (chunk  (seeded-bytes 65536 7))
         (peers '()) (clients '()))
    (uv-listen! server 1024
                (lambda (err)
                  (when (not err)
                    (set! peers (cons (uv-accept! server) peers)))))
    (let build ((i 0))
      (when (< i n)
        (let ((c (make-uv-tcp loop)))
          (set! clients (cons c clients))
          (connect-loopback! c port (lambda (e) #f))
          (build (+ i 1)))))
    (let ((r (run-until/ticking loop (lambda () (= (length peers) n)) 200000)))
      (unless (eq? r 'satisfied)
        (format #t "  SURPRISE: only ~a of ~a accepted (~a)~%" (length peers) n r)))

    (format #t "~%N = ~a~%" n)
    (format #t "  SO_RCVBUF reported per accepted socket: ~a bytes~%"
            (uv-recv-buffer-size (car peers)))
    (format #t "  chez-libuv read buffer, if read-started:  65536 bytes~%")
    (report "idle  " (tcp-mem-pages) n)

    ;; Nothing on the peer side ever calls uv-read-start!, so every byte
    ;; written stays in kernel queues.
    (let w ((r 0))
      (when (< r writes-per-client)
        (for-each (lambda (c) (uv-write! c chunk (lambda (e) #f))) clients)
        (run-until/ticking loop (lambda () #f) 300)
        (w (+ r 1))))
    (report "unread" (tcp-mem-pages) n)
    (format #t "  (~a KiB written per client, never read)~%"
            (div (* writes-per-client 65536) 1024))

    (uv-loop-teardown! loop)
    (uv-loop-close! loop)))

;; --- main -----------------------------------------------------------------
(if (not (linux?))
    (begin
      (display "13-rcvbuf-cost: SKIPPED -- Linux only.") (newline)
      (display "  SO_RCVBUF autotuning and /proc/net/sockstat are Linux concepts,") (newline)
      (display "  and the claim under test is explicitly about Linux.") (newline))
    (begin
      (display "=== kernel defaults on this host ===") (newline)
      (sysctl-line "/proc/sys/net/ipv4/tcp_rmem")
      (sysctl-line "/proc/sys/net/core/rmem_max")
      (sysctl-line "/proc/sys/net/ipv4/tcp_wmem")
      (display "=== measurements ===") (newline)
      (measure 100 8)
      (measure 200 8)
      (newline)
      (display "Read SO_RCVBUF as a CEILING, sockstat as what is CHARGED.") (newline)
      (display "The gap between them is the whole finding.") (newline)))
