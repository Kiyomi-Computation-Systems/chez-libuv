#!r6rs
;;; Stream operations shared by TCP and pipe handles. Each verb validates its
;;; arguments, then makes its native call in one interrupt-free step
;;; (one-step): the step checks again that this thread owns the stream's
;;; loop and that the stream is open (owned-handle-ptr), reads its pointer,
;;; checks again what it reads of the caller's data, allocates, registers
;;; and counts the request, and calls libuv. An engine can then suspend or
;;; drop a verb only before its step, when it holds nothing, or after, when
;;; libuv holds what it was given (test-stream.sps's engine sweeps). Nothing
;;; in a step raises: it answers a status, and the verb raises after the
;;; step (step-refusal). When libuv refuses a start, the step takes its
;;; request back itself rather than through a guard around the native call,
;;; which would allocate ~300 B on every write.
(library (libuv stream)
  (export uv-write! uv-write*! uv-shutdown! uv-read-start! uv-read-stop!
          uv-stream-write-queue-size)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (only (libuv private c-types) c-unsigned-int? c-size?)
          (only (libuv private lists) read-proper-list let-fixed-list)
          (libuv private handles))

  ;; require-open-stream : object symbol -> uv-stream
  ;; Passing a non-stream handle to libuv stream functions is undefined.
  (define (require-open-stream stream who)
    (unless (uv-stream-record? stream)
      (raise (make-uv-invalid-argument who 'not-a-uv-stream)))
    (require-open-handle stream who)
    stream)

  ;; start-write! : uv-stream uptr uptr uptr exact-positive-integer procedure
  ;;                -> (or uv-request symbol exact-integer)
  ;; Inside a write's step, once its payload and uv_buf_t[] are in BLOCK:
  ;; registers and counts the request and starts it on the stream at PTR.
  ;; Answers the request, or a status with BLOCK freed and nothing left
  ;; registered or counted.
  (define (start-write! stream ptr block bufs nbufs on-complete)
    (let* ((req (%make-uv-req-record block 'write stream on-complete))
           (registered (registry-add! block 'write-req (handle-loop stream) req)))
      (if (eq? registered 'registered)
          (begin
            (count-write-req-new!)
            (let ((rc (uv-write-native block ptr bufs nbufs)))
              (if (zero? rc)
                  req
                  (begin (registry-remove! block)
                         (count-write-req-free!)
                         (free-block! block)
                         (set-req-ptr! req 0)
                         rc))))
          (begin (free-block! block) registered))))

  ;; uv-write! : uv-stream bytevector procedure -> uv-request
  ;; uv-write! : uv-stream bytevector exact-nonnegative-integer
  ;;             exact-nonnegative-integer procedure -> uv-request
  ;; The [start, end) payload is copied into request-owned foreign memory.
  ;; The span is checked again in the step: the bytevector can be truncated
  ;; while the verb is suspended, and the step allocates nothing for a span
  ;; that runs past the bytevector's end.
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
       (unless (and (c-size? start) (c-size? end)
                    (<= start end) (<= end (bytevector-length bv)))
         (raise (make-uv-invalid-argument 'uv-write! 'span-out-of-range)))
       (let* ((len (- end start))
              (buf-offset (align-16 (uv-req-size (uv-write-req-type))))
              (payload-offset (+ buf-offset (sizeof-uv-buf-t)))
              ;; Empty writes still need an address inside the owned block.
              (size (+ payload-offset (max len 1)))
              (started
               (one-step
                (let ((ptr (owned-handle-ptr stream)))
                  (cond ((refused? ptr) ptr)
                        ((> end (bytevector-length bv)) 'span-out-of-range)
                        (else
                         (let ((block (alloc-block size)))
                           (if (zero? block)
                               'no-memory
                               (let ((buf (+ block buf-offset))
                                     (payload (+ block payload-offset)))
                                 (copy-in-unchecked! payload bv start len)
                                 (uv-buf-set! buf payload len)
                                 (start-write! stream ptr block buf 1
                                               on-complete))))))))))
         (if (uv-req? started)
             started
             (raise (step-refusal started 'uv-write! stream)))))))

  (define (refuse-segments reason)
    (raise (make-uv-invalid-argument 'uv-write*! reason)))

  ;; A spec is one segment as parse-write-segment read it, in the verb's own
  ;; pairs: (bv . len) for a span from 0, else (bv start . len). Every spec
  ;; stays live while the walk reads the rest of the list, so a spec is one
  ;; pair where it can be: as a list of three, a million segments cost a
  ;; write a dozen collections.
  (define (make-spec bv start len)
    (if (zero? start) (cons bv len) (cons bv (cons start len))))
  (define (spec-bv spec) (car spec))
  (define (spec-start spec) (let ((r (cdr spec))) (if (pair? r) (car r) 0)))
  (define (spec-len spec) (let ((r (cdr spec))) (if (pair? r) (cdr r) r)))

  ;; parse-write-segment : segment -> spec
  ;; A whole bytevector is the span [0, len); an explicit (bv start end) span
  ;; is range-checked exactly as uv-write! checks its own. Anything else is a
  ;; malformed segment, named before the caller's list is copied anywhere.
  ;; A span is read once with let-fixed-list, each pair checked as it is
  ;; read: asking list? and length first would leave a gap in which an
  ;; engine's handler could change the span, and length would then raise a
  ;; condition of its own.
  (define (parse-write-segment seg)
    (if (bytevector? seg)
        (make-spec seg 0 (bytevector-length seg))
        (let-fixed-list (bv start end) seg
          (refuse-segments 'segment-not-a-bytevector)
          (unless (bytevector? bv)
            (refuse-segments 'segment-not-a-bytevector))
          (unless (and (integer? start) (exact? start)
                       (integer? end) (exact? end)
                       (<= 0 start) (<= start end)
                       (<= end (bytevector-length bv)))
            (refuse-segments 'segment-span-out-of-range))
          (make-spec bv start (- end start)))))

  ;; spans-fit? : (listof spec) -> boolean
  ;; Whether every span still lies inside its bytevector, which can have been
  ;; truncated since parse-write-segment checked it.
  (define (spans-fit? specs)
    (or (null? specs)
        (let ((spec (car specs)))
          (and (<= (+ (spec-start spec) (spec-len spec))
                   (bytevector-length (spec-bv spec)))
               (spans-fit? (cdr specs))))))

  ;; place-spans! : (listof spec) uptr uptr -> unspecified
  ;; Inside the write's step: copies each span in and fills its uv_buf_t in
  ;; the array at BUFS. Packs non-empty spans consecutively from the payload
  ;; region's start, and points every empty span's base at that same start
  ;; (always valid, the region is >= 1 byte) so no base lands
  ;; one-past-the-end of the block.
  (define (place-spans! specs bufs payload-base)
    (let place ((specs specs) (buf bufs) (running 0))
      (when (pair? specs)
        (let* ((spec (car specs))
               (bv (spec-bv spec)) (start (spec-start spec)) (len (spec-len spec))
               (base (if (zero? len) payload-base (+ payload-base running))))
          (when (positive? len) (copy-in-unchecked! base bv start len))
          (uv-buf-set! buf base len)
          (place (cdr specs) (+ buf (sizeof-uv-buf-t)) (+ running len))))))

  ;; uv-write*! : uv-stream (listof segment) procedure -> uv-request
  ;;   segment = bytevector | (bytevector start end)
  ;; The scatter-gather counterpart of uv-write!. Each segment's [start, end)
  ;; span is copied into request-owned foreign memory; one block holds the N
  ;; copied spans and an N-entry uv_buf_t[], and uv_write is issued with
  ;; nbufs = N. Completion and the free-before-on-complete discipline are
  ;; uv-write!'s: the block is freed as a unit by the shared write-done
  ;; dispatcher. libuv rejects nbufs < 1, so an empty segment list is
  ;; refused here rather than forwarded as a platform EINVAL.
  (define (uv-write*! stream segments on-complete)
    (require-open-stream stream 'uv-write*!)
    (require-callback on-complete 'uv-write*! 'on-complete-not-a-procedure)
    ;; Normalize and range-check every segment before the step, so a
    ;; malformed list is refused before anything is allocated. The step
    ;; checks every span again, against the bytevectors as they are then.
    ;; read-proper-list reads the list once, each pair checked: a list an
    ;; engine's handler or another thread changes during the read is refused,
    ;; or written as it was or as the change left it, and never read through
    ;; a non-pair or walked forever. Chez's map would read through a
    ;; non-pair put in its way. A single count and walk, with no second
    ;; count when the walk contradicts the first, would refuse a list
    ;; changed in between into another proper list.
    (let* ((specs (or (read-proper-list segments parse-write-segment)
                      (refuse-segments 'segments-not-a-list)))
           (n (if (null? specs)
                  (refuse-segments 'empty-segment-list)
                  (length specs)))
           ;; uv_write takes the count as an unsigned int.
           (n (if (c-unsigned-int? n) n (refuse-segments 'too-many-segments)))
           (total (fold-left (lambda (acc s) (+ acc (spec-len s))) 0 specs))
           (bufs-offset (align-16 (uv-req-size (uv-write-req-type))))
           (payload-offset (+ bufs-offset (* n (sizeof-uv-buf-t))))
           ;; (max total 1) keeps the payload region addressable even when every
           ;; span is empty, so no uv_buf_t base is ever a null or dangling one.
           (size (+ payload-offset (max total 1)))
           (started
            (one-step
             (let ((ptr (owned-handle-ptr stream)))
               (cond ((refused? ptr) ptr)
                     ((not (spans-fit? specs)) 'segment-span-out-of-range)
                     (else
                      (let ((block (alloc-block size)))
                        (if (zero? block)
                            'no-memory
                            (let ((bufs (+ block bufs-offset)))
                              (place-spans! specs bufs (+ block payload-offset))
                              (start-write! stream ptr block bufs n
                                            on-complete))))))))))
      (if (uv-req? started)
          started
          (raise (step-refusal started 'uv-write*! stream)))))

  ;; uv-shutdown! : uv-stream procedure -> uv-request
  (define (uv-shutdown! stream on-shutdown)
    (require-open-stream stream 'uv-shutdown!)
    (require-callback on-shutdown 'uv-shutdown! 'on-shutdown-not-a-procedure)
    (let* ((size (uv-req-size (uv-shutdown-req-type)))
           (started
            (one-step
             (let ((ptr (owned-handle-ptr stream)))
               (if (refused? ptr)
                   ptr
                   (let ((block (alloc-block size)))
                     (if (zero? block)
                         'no-memory
                         (let* ((req (%make-uv-req-record block 'shutdown stream
                                                          on-shutdown))
                                (registered (registry-add! block 'shutdown-req
                                                           (handle-loop stream)
                                                           req)))
                           (if (eq? registered 'registered)
                               (let ((rc (uv-shutdown-native block ptr)))
                                 (if (zero? rc)
                                     req
                                     (begin (registry-remove! block)
                                            (free-block! block)
                                            (set-req-ptr! req 0)
                                            rc)))
                               (begin (free-block! block) registered))))))))))
      (if (uv-req? started)
          started
          (raise (step-refusal started 'uv-shutdown! stream)))))

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

  ;; start-reading! : uv-stream procedure procedure procedure
  ;;                  (or exact-positive-integer #f) -> unspecified
  ;; The callbacks are stored only once libuv accepts the start, and in the
  ;; same step, so no read can be delivered between the two.
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
    (let ((started
           (one-step
            (let ((ptr (owned-handle-ptr stream)))
              (if (refused? ptr)
                  ptr
                  (let ((buffer (ensure-read-buffer! stream buffer-size)))
                    (if (not (eq? buffer 'ready))
                        buffer
                        (let ((rc (uv-read-start-native ptr)))
                          (when (zero? rc)
                            (set-stream-on-data! stream on-data)
                            (set-stream-on-eof! stream on-eof)
                            (set-stream-on-error! stream on-error)
                            (set-stream-reading! stream #t))
                          rc))))))))
      (unless (eqv? started 0)
        (raise (step-refusal started 'uv-read-start! stream)))))

  ;; ensure-read-buffer! : uv-stream (or exact-positive-integer #f)
  ;;                       -> (or 'ready 'buffer-size-fixed symbol)
  ;; Inside the read start's step. The first start fixes one reusable buffer
  ;; until close, installed with the descriptor libuv's alloc callback
  ;; answers (install-read-buffer!, whose refusal it answers: 'no-memory, as
  ;; the step has found the stream open and without a buffer). A stopped read
  ;; may restart without specifying a size, but may not resize the existing
  ;; buffer.
  (define (ensure-read-buffer! stream buffer-size)
    (if (zero? (stream-read-buf stream))
        (let ((installed (install-read-buffer!
                          stream (or buffer-size default-read-buffer-size))))
          (if (eq? installed 'installed) 'ready installed))
        (if (and buffer-size (not (= buffer-size (stream-read-buf-len stream))))
            'buffer-size-fixed
            'ready)))

  ;; uv-read-stop! : uv-stream -> unspecified
  ;; Stop retains callbacks and the buffer so it can implement backpressure.
  (define (uv-read-stop! stream)
    (require-open-stream stream 'uv-read-stop!)
    (let ((stopped
           (one-step
            (let ((ptr (owned-handle-ptr stream)))
              (if (refused? ptr)
                  ptr
                  (let ((rc (uv-read-stop ptr)))
                    (when (zero? rc) (set-stream-reading! stream #f))
                    rc))))))
      (unless (eqv? stopped 0)
        (raise (step-refusal stopped 'uv-read-stop! stream)))))

  ;; uv-stream-write-queue-size : uv-stream -> exact-nonnegative-integer
  ;; This platform-dependent value is a congestion signal, not a memory gauge.
  (define (uv-stream-write-queue-size stream)
    (require-open-stream stream 'uv-stream-write-queue-size)
    (let ((size (one-step
                 (let ((ptr (owned-handle-ptr stream)))
                   (if (refused? ptr)
                       ptr
                       (uv-stream-get-write-queue-size-native ptr))))))
      (if (refused? size)
          (raise (step-refusal size 'uv-stream-write-queue-size stream))
          size))))
