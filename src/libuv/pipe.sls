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
  (define (make-uv-pipe loop)
    (ensure-native-loaded!)
    (require-open-loop loop 'make-uv-pipe)
    (let ((ptr (alloc-zeroed (uv-handle-size (uv-named-pipe-type)))))
      (guard (e (#t (free! ptr) (raise e)))
        (uv-check (uv-pipe-init (loop-pointer loop 'make-uv-pipe) ptr 0)
                  'make-uv-pipe))
      (let ((pipe (%make-uv-pipe-record ptr loop)))
        (registry-register! ptr 'pipe loop pipe)
        (count-pipe-new!)
        pipe))))
