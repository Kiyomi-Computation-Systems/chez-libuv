#!r6rs
;;; (libuv stream) -- the four stream verbs (design spec S6, S7), extracted
;;; from (libuv tcp) so a second stream kind can use them without a second
;;; copy (ADR-0014). Every signature, callback contract and copy/free
;;; discipline below is IDENTICAL to v0.1/v0.2's tcp-only versions -- this
;;; is a move, not a rewrite. The one thing that changed is the GATE:
;;; require-open-tcp's uv-tcp-record? check widens to uv-stream-record?, so
;;; a pipe passes it too, once uv-spawn! (Task 10) has connected one.
;;;
;;; NO PROCEDURE HERE TAKES OR RETURNS A POINTER, for the same reason as
;;; (libuv tcp): a stream handle is an opaque record, and the request
;;; records these verbs answer with are opaque too.
;;;
;;; TWO RULES RUN THROUGH EVERY PROCEDURE BELOW, unchanged from tcp.sls and
;;; still design spec requirements rather than style:
;;;
;;;   * EVERY ARGUMENT IS VALIDATED BEFORE THE FIRST ALLOCATION. Not merely
;;;     before the native call: a span check that runs after the block has
;;;     been foreign-alloc'd leaks it on the failure path, and the leak is
;;;     invisible to everything except Valgrind. tests/test-tcp.sps asserts
;;;     the allocation counters are unchanged across a refused write.
;;;   * A FAILED NATIVE CALL LEAVES NOTHING HALF-BUILT. Every path that has
;;;     allocated, registered or counted something undoes exactly that much
;;;     before the condition escapes (design spec S5, S7).
(library (libuv stream)
  (export uv-write! uv-shutdown! uv-read-start! uv-read-stop!)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))

  ;; --- argument predicates ------------------------------------------------
  ;; A STREAM handle (tcp or pipe), and open. Kind check first, state check
  ;; second, different conditions -- the require-open-tcp split (tcp.sls:44-54),
  ;; widened to the record hierarchy ADR-0014 introduces. uv_write/uv_read
  ;; on a non-stream handle is undefined behaviour, not an errno; a closed
  ;; stream still answers &uv-handle-closed with ITS kind.
  (define (require-open-stream stream who)
    (unless (uv-stream-record? stream)
      (raise (make-uv-invalid-argument who 'not-a-uv-stream)))
    (require-open-handle stream who)
    stream)

  ;; --- writing ------------------------------------------------------------
  ;; (uv-write! stream bv on-complete)
  ;; (uv-write! stream bv start end on-complete)
  ;;
  ;; ONE foreign-alloc: [uv_write_t | pad to 16 | uv_buf_t | payload copy]
  ;; (design spec S7). One block means one free, in one place -- the
  ;; write-done dispatcher -- and one debug counter for the whole thing.
  ;;
  ;; The payload is COPIED (ADR-0009). The caller's bytevector is free to be
  ;; mutated or collected the instant this returns: nothing libuv holds
  ;; points into the Scheme heap, so there is no pinning, no lock-object, and
  ;; no window in which a moving collector could invalidate an in-flight
  ;; write.
  ;;
  ;; The span is `[start, end)`, matching bytevector-copy! and every other
  ;; R6RS range. An empty span is legal and is passed to libuv as a
  ;; zero-length buffer.
  (define uv-write!
    (case-lambda
      ((stream bv on-complete)
       ;; The implicit span is computed from the bytevector, so both checks
       ;; have to happen HERE too rather than waiting for the general clause
       ;; -- and in the same order, so which condition a caller gets does not
       ;; depend on which arity they used.
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
       ;; EVERY CHECK ABOVE, THE FIRST ALLOCATION BELOW. Moving one of them
       ;; the other way leaks the block on the failure path.
       (let* ((len (- end start))
              (buf-offset (align-16 (uv-req-size (uv-write-req-type))))
              (payload-offset (+ buf-offset (sizeof-uv-buf-t)))
              ;; max 1: an empty write still needs its payload pointer to
              ;; address memory this block actually owns, rather than one
              ;; byte past its end.
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

  ;; --- shutting down the write side ---------------------------------------
  ;; A plain request block: uv_shutdown_t and nothing else. Same pattern as
  ;; the other two, and the same single freeing site.
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

  ;; --- reading (design spec S6) -------------------------------------------
  ;; (uv-read-start! stream on-data on-eof on-error [buffer-size])
  ;;
  ;;   on-data  (bv start end) -- a FRESH bytevector per delivery, handed as a
  ;;            SPAN so a future zero-copy variant can answer a sub-range of a
  ;;            larger buffer without changing the call shape (ADR-0009).
  ;;   on-eof   () -- the end of the stream, which is NOT an error and is
  ;;            never wrapped in a condition (design spec S6, ADR-0006).
  ;;   on-error (condition) -- a plain object, never raised across the
  ;;            callback boundary (design spec S8). The handle is not closed:
  ;;            what to do about a read error is the caller's decision.
  ;;
  ;; All three are REQUIRED. There is no "just give me the data" arity,
  ;; because a stream whose end and whose failure both go unnoticed is not a
  ;; simplification -- it is the two bugs this split exists to prevent.
  (define default-read-buffer-size 65536)

  (define uv-read-start!
    (case-lambda
      ;; #f, not the default size: "the caller did not ask for a size" and
      ;; "the caller asked for 65536" are different questions to the
      ;; buffer-size rule below, and collapsing them here would make a
      ;; re-start with the size omitted fail against any handle whose buffer
      ;; was fixed at anything else.
      ((stream on-data on-eof on-error)
       (start-reading! stream on-data on-eof on-error #f))
      ((stream on-data on-eof on-error buffer-size)
       (start-reading! stream on-data on-eof on-error buffer-size))))

  ;; EVERY CHECK FIRST, THE ALLOCATION AFTER THEM, the native call after
  ;; that, and the record updated only once libuv has said yes -- the same
  ;; order, and for the same reasons, as uv-write!.
  ;;
  ;; The callbacks are stored AFTER the native call, unlike uv-listen!'s: a
  ;; uv_read_start that libuv refuses (UV_EALREADY on a handle that is
  ;; already reading, UV_ENOTCONN on one that is not connected) must not
  ;; leave this handle's stored callbacks swapped for a read that never
  ;; started. Nothing can be delivered in the window either way, since libuv
  ;; only ever calls read_cb from inside uv_run.
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

  ;; The per-handle buffer of design spec S6, allocated by the FIRST
  ;; uv-read-start! and never again -- which is what lets the alloc dispatcher
  ;; be infallible: it has an already-allocated pointer to hand back on every
  ;; read and never allocates on the hot path.
  ;;
  ;; ITS SIZE IS FIXED BY THAT FIRST CALL, and a later call asking for a
  ;; different explicit size is REFUSED rather than honoured. Honouring it
  ;; would mean freeing the old buffer here, and design spec S6 makes the
  ;; close dispatcher the only place that buffer may ever be freed -- so that
  ;; a read completion queued against it (Windows' overlapped model) cannot
  ;; outlive it. A caller who wants a different size closes the handle.
  ;;
  ;; A call that omits the size is not asking for anything, so it is always
  ;; allowed. That is what makes re-starting after a stop the cheap operation
  ;; backpressure needs it to be.
  ;;
  ;; NOTHING FREES THE BUFFER ON A FAILURE PATH, including one where
  ;; uv_read_start goes on to fail: the buffer belongs to the HANDLE, not to
  ;; the read, and the close dispatcher will free it exactly once.
  (define (ensure-read-buffer! stream buffer-size)
    (if (zero? (stream-read-buf stream))
        (let ((size (or buffer-size default-read-buffer-size)))
          (set-stream-read-buf! stream (alloc-zeroed size))
          (set-stream-read-buf-len! stream size)
          (count-read-buffer-new!))
        (when (and buffer-size (not (= buffer-size (stream-read-buf-len stream))))
          (raise (make-uv-invalid-argument 'uv-read-start!
                                           'buffer-size-fixed)))))

  ;; Stopping a stream that is not reading is rc 0 at the libuv level, so this
  ;; is idempotent without a state test of its own. The stored callbacks and
  ;; the buffer are left alone on purpose: a stop is backpressure, not a
  ;; teardown, and the next uv-read-start! is meant to be able to pass the
  ;; same callbacks against the same buffer (design spec S6).
  (define (uv-read-stop! stream)
    (require-open-stream stream 'uv-read-stop!)
    (uv-check (uv-read-stop (handle-pointer stream 'uv-read-stop!))
              'uv-read-stop!)
    (set-stream-reading! stream #f)))
