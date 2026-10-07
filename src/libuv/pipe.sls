#!r6rs
;;; Anonymous pipes for process stdio. A pipe is open but unconnected until
;;; uv-spawn! consumes it; stream operations apply after connection.
(library (libuv pipe)
  (export make-uv-pipe)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))

  ;; make-uv-pipe : uv-loop -> uv-pipe
  ;; The block holds libuv's handle and the stream's read descriptor.
  (define (make-uv-pipe loop)
    (ensure-native-loaded!)
    (require-open-loop loop 'make-uv-pipe)
    (let ((handle-size (uv-handle-size (uv-named-pipe-type))))
      (construct-handle 'make-uv-pipe loop (stream-block-size handle-size)
                        init-pipe
                        (lambda (ptr) (%make-uv-pipe-record ptr loop handle-size))
                        count-pipe-new!)))

  ;; No IPC: these pipes carry bytes, never handles.
  (define (init-pipe loop-ptr ptr) (uv-pipe-init loop-ptr ptr 0)))
