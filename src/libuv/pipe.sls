#!r6rs
;;; (libuv pipe) -- deliberately minimal in v0.3 (THE SPEC §4.6): a pipe
;;; exists to be consumed by uv-spawn! in a (pipe p dir) stdio spec, where
;;; uv_spawn creates the socketpair and connects the parent end into it
;;; (vendor fact V3). No bind/connect/listen (named-pipe IPC is a future
;;; milestone), no ipc=1 fd passing. Stream verbs come from (libuv stream)
;;; and work on a pipe once it is connected; closing is (libuv handle)'s
;;; generic uv-close!.
;;;
;;; VOCABULARY (§4.3): "open/closed" is handle state; "connected/
;;; unconnected" is the spawn-consumption state tracked by the record's
;;; connected? flag. A fresh pipe is open AND unconnected.
(library (libuv pipe)
  (export make-uv-pipe)
  (import (rnrs)
          (libuv private conditions)
          (libuv private constants)
          (libuv private native)
          (libuv private handles))

  ;; The make-uv-tcp shape verbatim: size from the RUNNING library via
  ;; uv_handle_size, type tag from the shim (ADR-0005); a failed init frees
  ;; the block before the condition escapes, and nothing is registered or
  ;; counted yet. ipc is 0 ALWAYS in v0.3 (§1).
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
