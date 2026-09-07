#!r6rs
;;; Stream operations shared by TCP and pipe handles. Validate arguments before
;;; allocation; native start failures must leave no registered request behind.
(library (libuv stream)
  (export uv-write! uv-shutdown! uv-read-start! uv-read-stop!
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
              (buf-offset (align-16 (uv-req-size (uv-write-req-type))))
              (payload-offset (+ buf-offset (sizeof-uv-buf-t)))
              ;; Empty writes still need an address inside the owned block.
              (block (alloc-zeroed (+ payload-offset (max len 1))))
              (payload (+ block payload-offset)))
         (copy-in! payload bv start len)
         (uv-buf-set! (+ block buf-offset) payload len)
         (let ((req (%make-uv-req-record block 'write stream on-complete)))
           (registry-register! block 'write-req (handle-loop stream) req)
           (count-write-req-new!)
           (guard (e (#t (abandon-request! req) (count-write-req-free!)
                         (raise e)))
             (uv-check (uv-write-native block
                                        (handle-pointer stream 'uv-write!)
                                        (+ block buf-offset)
                                        1)
                       'uv-write!))
           req)))))

  ;; uv-shutdown! : uv-stream procedure -> uv-request
  (define (uv-shutdown! stream on-shutdown)
    (require-open-stream stream 'uv-shutdown!)
    (require-callback on-shutdown 'uv-shutdown! 'on-shutdown-not-a-procedure)
    (let* ((block (alloc-zeroed (uv-req-size (uv-shutdown-req-type))))
           (req (%make-uv-req-record block 'shutdown stream on-shutdown)))
      (registry-register! block 'shutdown-req (handle-loop stream) req)
      (guard (e (#t (abandon-request! req) (raise e)))
        (uv-check (uv-shutdown-native block (handle-pointer stream 'uv-shutdown!))
                  'uv-shutdown!))
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
        (let ((size (or buffer-size default-read-buffer-size)))
          (set-stream-read-buf! stream (alloc-zeroed size))
          (set-stream-read-buf-len! stream size)
          (count-read-buffer-new!))
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
