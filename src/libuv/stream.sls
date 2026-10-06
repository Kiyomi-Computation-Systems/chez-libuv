#!r6rs
;;; Stream operations shared by TCP and pipe handles. Validate arguments before
;;; allocation; native start failures must leave no registered request behind.
;;; When libuv refuses a start, the verb takes its request back itself, by
;;; checking the status rather than guarding the native call: the guard
;;; allocated ~300 B on every write (#45). So the stream's pointer, whose
;;; check can raise, is resolved before the request exists.
;;;
;;; One check can still fail once a write's block exists: the payload can
;;; shrink between the verb's span check and the copy (an engine's timer
;;; handler can truncate it, or another thread). The copy answers that as a
;;; status, and the verb frees the block before it raises its own refusal
;;; (test-stream.sps's shrinking-payload sweep).
(library (libuv stream)
  (export uv-write! uv-write*! uv-shutdown! uv-read-start! uv-read-stop!
          uv-stream-write-queue-size)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))

  ;; Passing a non-stream handle to libuv stream functions is undefined.
  (define (require-open-stream stream who)
    (unless (uv-stream-record? stream)
      (raise (make-uv-invalid-argument who 'not-a-uv-stream)))
    (require-open-handle stream who)
    stream)

  ;; uv-write! : uv-stream bytevector procedure -> uv-request
  ;; uv-write! : uv-stream bytevector exact-nonnegative-integer
  ;;             exact-nonnegative-integer procedure -> uv-request
  ;; The [start, end) payload is copied into request-owned foreign memory.
  (define uv-write!
    (case-lambda
      ((stream bv on-complete)
       (require-open-stream stream 'uv-write!)
       (unless (bytevector? bv)
         (raise (make-uv-invalid-argument 'uv-write! 'source-not-a-bytevector)))
       (uv-write! stream bv 0 (bytevector-length bv) on-complete))
      ((stream bv start end on-complete)
       (require-open-stream stream 'uv-write!)
       (unless (bytevector? bv)
         (raise (make-uv-invalid-argument 'uv-write! 'source-not-a-bytevector)))
       (require-callback on-complete 'uv-write! 'on-complete-not-a-procedure)
       (unless (and (integer? start) (exact? start)
                    (integer? end) (exact? end)
                    (<= 0 start) (<= start end)
                    (<= end (bytevector-length bv)))
         (raise (make-uv-invalid-argument 'uv-write! 'span-out-of-range)))
       (let* ((len (- end start))
              (stream-ptr (handle-pointer stream 'uv-write!))
              (buf-offset (align-16 (uv-req-size (uv-write-req-type))))
              (payload-offset (+ buf-offset (sizeof-uv-buf-t)))
              ;; Empty writes still need an address inside the owned block.
              (block (alloc-zeroed (+ payload-offset (max len 1))))
              (payload (+ block payload-offset)))
         (unless (eq? (try-copy-in! payload bv start len) 'copied)
           (free! block)
           (raise (make-uv-invalid-argument 'uv-write! 'span-out-of-range)))
         (uv-buf-set! (+ block buf-offset) payload len)
         (let ((req (%make-uv-req-record block 'write stream on-complete)))
           (registry-register! block 'write-req (handle-loop stream) req)
           (count-write-req-new!)
           (let ((status (uv-write-native block stream-ptr (+ block buf-offset) 1)))
             (unless (zero? status)
               (abandon-request! req)
               (count-write-req-free!)
               (raise (uv-errno-condition status 'uv-write!))))
           req)))))

  ;; parse-write-segment : segment -> (list bytevector start len)
  ;; A whole bytevector is the span [0, len); an explicit (bv start end) span
  ;; is range-checked exactly as uv-write! checks its own. Anything else is a
  ;; malformed segment, named before the caller's list is copied anywhere.
  (define (parse-write-segment seg)
    (cond
      ((bytevector? seg) (list seg 0 (bytevector-length seg)))
      ((and (list? seg) (= 3 (length seg)) (bytevector? (car seg)))
       (let ((bv (car seg)) (start (cadr seg)) (end (caddr seg)))
         (unless (and (integer? start) (exact? start)
                      (integer? end) (exact? end)
                      (<= 0 start) (<= start end)
                      (<= end (bytevector-length bv)))
           (raise (make-uv-invalid-argument 'uv-write*! 'segment-span-out-of-range)))
         (list bv start (- end start))))
      (else
       (raise (make-uv-invalid-argument 'uv-write*! 'segment-not-a-bytevector)))))

  ;; uv-write*! : uv-stream (listof segment) procedure -> uv-request
  ;;   segment = bytevector | (bytevector start end)
  ;; The scatter-gather write ADR-0009 reserved this name for. Each segment's
  ;; [start, end) span is copied into request-owned foreign memory; one block
  ;; holds the N copied spans and an N-entry uv_buf_t[], and uv_write is issued
  ;; with nbufs = N. Completion and the free-before-on-complete discipline are
  ;; uv-write!'s, unchanged: the block is freed as a unit by the shared
  ;; write-done dispatcher. libuv rejects nbufs < 1, so an empty segment list
  ;; is refused here rather than forwarded as a platform EINVAL.
  (define (uv-write*! stream segments on-complete)
    (require-open-stream stream 'uv-write*!)
    (require-callback on-complete 'uv-write*! 'on-complete-not-a-procedure)
    (unless (list? segments)
      (raise (make-uv-invalid-argument 'uv-write*! 'segments-not-a-list)))
    (when (null? segments)
      (raise (make-uv-invalid-argument 'uv-write*! 'empty-segment-list)))
    ;; Normalize and range-check every segment before anything is allocated, so
    ;; a malformed list leaves no block and no registration behind.
    (let* ((specs (map parse-write-segment segments))
           (stream-ptr (handle-pointer stream 'uv-write*!))
           (n (length specs))
           (total (fold-left (lambda (acc s) (+ acc (caddr s))) 0 specs))
           (bufs-offset (align-16 (uv-req-size (uv-write-req-type))))
           (payload-offset (+ bufs-offset (* n (sizeof-uv-buf-t))))
           ;; (max total 1) keeps the payload region addressable even when every
           ;; span is empty, so no uv_buf_t base is ever a null or dangling one.
           (block (alloc-zeroed (+ payload-offset (max total 1))))
           (payload-base (+ block payload-offset)))
      ;; Pack non-empty spans consecutively from the region start; point every
      ;; empty span's base at that same start (always valid, region >= 1) so no
      ;; base lands one-past-the-end of the block.
      (let place ((specs specs) (i 0) (running 0))
        (when (pair? specs)
          (let* ((spec (car specs))
                 (bv (car spec)) (start (cadr spec)) (len (caddr spec))
                 (buf (+ block bufs-offset (* i (sizeof-uv-buf-t))))
                 (base (if (zero? len) payload-base (+ payload-base running))))
            (unless (or (zero? len)
                        (eq? (try-copy-in! base bv start len) 'copied))
              (free! block)
              (raise (make-uv-invalid-argument 'uv-write*!
                                               'segment-span-out-of-range)))
            (uv-buf-set! buf base len)
            (place (cdr specs) (+ i 1) (+ running len)))))
      (let ((req (%make-uv-req-record block 'write stream on-complete)))
        (registry-register! block 'write-req (handle-loop stream) req)
        (count-write-req-new!)
        (let ((status (uv-write-native block stream-ptr (+ block bufs-offset) n)))
          (unless (zero? status)
            (abandon-request! req)
            (count-write-req-free!)
            (raise (uv-errno-condition status 'uv-write*!))))
        req)))

  ;; uv-shutdown! : uv-stream procedure -> uv-request
  (define (uv-shutdown! stream on-shutdown)
    (require-open-stream stream 'uv-shutdown!)
    (require-callback on-shutdown 'uv-shutdown! 'on-shutdown-not-a-procedure)
    (let* ((stream-ptr (handle-pointer stream 'uv-shutdown!))
           (block (alloc-zeroed (uv-req-size (uv-shutdown-req-type))))
           (req (%make-uv-req-record block 'shutdown stream on-shutdown)))
      (registry-register! block 'shutdown-req (handle-loop stream) req)
      (let ((status (uv-shutdown-native block stream-ptr)))
        (unless (zero? status)
          (abandon-request! req)
          (raise (uv-errno-condition status 'uv-shutdown!))))
      req))

  (define default-read-buffer-size 65536)

  ;; uv-read-start! : uv-stream procedure procedure procedure
  ;;                  [exact-positive-integer] -> unspecified
  ;; on-data receives (bytevector start end); EOF and errors have distinct
  ;; callbacks, and read errors never close the handle automatically.
  (define uv-read-start!
    (case-lambda
      ((stream on-data on-eof on-error)
       (start-reading! stream on-data on-eof on-error #f))
      ((stream on-data on-eof on-error buffer-size)
       (start-reading! stream on-data on-eof on-error buffer-size))))

  ;; Store callbacks only after libuv accepts the read start.
  (define (start-reading! stream on-data on-eof on-error buffer-size)
    (require-open-stream stream 'uv-read-start!)
    (require-callback on-data 'uv-read-start! 'on-data-not-a-procedure)
    (require-callback on-eof 'uv-read-start! 'on-eof-not-a-procedure)
    (require-callback on-error 'uv-read-start! 'on-error-not-a-procedure)
    (when buffer-size
      (unless (and (integer? buffer-size) (exact? buffer-size)
                   (positive? buffer-size))
        (raise (make-uv-invalid-argument 'uv-read-start!
                                         'buffer-size-out-of-range))))
    (ensure-read-buffer! stream buffer-size)
    (uv-check (uv-read-start-native (handle-pointer stream 'uv-read-start!))
              'uv-read-start!)
    (set-stream-on-data! stream on-data)
    (set-stream-on-eof! stream on-eof)
    (set-stream-on-error! stream on-error)
    (set-stream-reading! stream #t))

  ;; The first start fixes one reusable buffer until close. A stopped read may
  ;; restart without specifying a size, but may not resize the existing buffer.
  (define (ensure-read-buffer! stream buffer-size)
    (if (zero? (stream-read-buf stream))
        (install-read-buffer! stream (or buffer-size default-read-buffer-size))
        (when (and buffer-size (not (= buffer-size (stream-read-buf-len stream))))
          (raise (make-uv-invalid-argument 'uv-read-start!
                                           'buffer-size-fixed)))))

  ;; uv-read-stop! : uv-stream -> unspecified
  ;; Stop retains callbacks and the buffer so it can implement backpressure.
  (define (uv-read-stop! stream)
    (require-open-stream stream 'uv-read-stop!)
    (uv-check (uv-read-stop (handle-pointer stream 'uv-read-stop!))
              'uv-read-stop!)
    (set-stream-reading! stream #f))

  ;; uv-stream-write-queue-size : uv-stream -> exact-nonnegative-integer
  ;; This platform-dependent value is a congestion signal, not a memory gauge.
  (define (uv-stream-write-queue-size stream)
    (require-open-stream stream 'uv-stream-write-queue-size)
    (uv-stream-get-write-queue-size-native
     (handle-pointer stream 'uv-stream-write-queue-size))))
