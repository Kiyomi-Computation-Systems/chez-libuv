#!r6rs
;;; Caller lists, read once.
;;;
;;; A list the caller can still reach can change while a verb reads it: an
;;; engine's handler runs between any two trap checks, and another thread
;;; between any two instructions. Chez's own list procedures assume nothing
;;; changes. map measures a list and then walks it unchecked, and at
;;; --optimize-level 3 length walks it with no check at all, so a list made
;;; circular is walked forever (#64, #66). These read a caller's list once,
;;; check each pair before reading through it, and always end. Pure: no
;;; native code (tests/test-addrinfo.sps, under make check-purity).
(library (libuv private lists)
  (export proper-length read-proper-list fold-flags)
  (import (rnrs)
          (only (libuv private conditions) make-uv-invalid-argument))

  ;; proper-length : object -> (or exact-nonnegative-integer #f)
  ;; X's length when it is a proper list, else #f. One walk, which ends at
  ;; the list's end, at a non-pair, or back at the pair it last marked. The
  ;; mark moves to the pair the walk stands on each time the count reaches a
  ;; power of two (Brent's check), so a cycle of any length is found within
  ;; twice its length. It raises nothing and allocates nothing, where length
  ;; raises and a guard around it allocates.
  ;;
  ;; The list can change during the count, from an engine's handler or
  ;; another thread. The walk takes each cdr once, of a value it has just
  ;; found to be a pair, and only compares the mark with eq?, so no change
  ;; makes it read through a non-pair, and once the changes stop it ends.
  ;; #61's count walked a tortoise behind its hare along the list's links:
  ;; one change could cut the tortoise's way, and two could leave the two on
  ;; separate cycles, where the count never ended (#64 and its review).
  ;;
  ;; A count can be stale all the same: by the time it returns, the list may
  ;; be improper, circular or of another length. So a caller walks at most
  ;; that many pairs, checking each one, as fold-flags does, and where a
  ;; list read twice would matter requires the list's end after them, as
  ;; read-proper-list does.
  (define (proper-length x)
    (let walk ((p x) (n 0) (mark #f) (lap 1))
      (cond ((null? p) n)
            ((or (not (pair? p)) (eq? p mark)) #f)
            ((= n lap) (walk (cdr p) (+ n 1) p (* 2 lap)))
            (else (walk (cdr p) (+ n 1) mark lap)))))

  ;; read-proper-list : object (object -> object) -> (or list #f)
  ;; A fresh list of (READ e) for each element e of X, or #f when X is not a
  ;; proper list as this read finds it. X is counted with proper-length, at
  ;; most that many pairs are walked, each checked before it is read through,
  ;; and X's end is required after them. READ sees each element once, in
  ;; order, as its pair stood when the walk reached it, and may raise.
  ;;
  ;; A list changed once during the read answers as it was before the change
  ;; or after it, or #f. Without the end, a tail spliced in during the read
  ;; would be read only as far as the stale count, and the answer would end
  ;; where the list did not (tests/test-native.sps's spliced-longer sweep).
  ;; A list changed more than once can answer a mix of its versions. One
  ;; made circular and whole again during the count, and again during the
  ;; walk, is counted and then walked once around its cycle: its elements in
  ;; an order it never held them in (tests/test-native.sps's cycle race).
  ;; No read that takes no lock can rule that out. A read inside one
  ;; interrupt-free step, as uv-spawn!'s is, sees no engine's handler, so
  ;; only another thread can do it. Nothing is allocated but the answer, and
  ;; what READ allocates.
  (define (read-proper-list x read)
    (let ((n (proper-length x)))
      (and n
           (let walk ((p x) (left n))
             (cond ((zero? left) (and (null? p) '()))
                   ((pair? p)
                    (let* ((element (read (car p)))
                           (rest (walk (cdr p) (- left 1))))
                      (and rest (cons element rest))))
                   (else #f))))))

  ;; fold-flags : object symbol symbol (object -> exact-integer)
  ;;              -> exact-integer
  ;; The bitwise-ior of (BIT flag) over a caller's flag list, which is read
  ;; once: its length from proper-length, #f for an improper or circular list
  ;; and then the refusal (WHO, REASON), then at most that many pairs, each
  ;; checked as it is read. A list changed during the walk is refused, or
  ;; read as each pair stood when the walk reached it, and never walked
  ;; forever. Asking list? first would leave a gap an engine's handler can
  ;; change the list in, and fold-left walks a list made circular there
  ;; forever (tests/test-address.sps's flags sweeps). Nothing here
  ;; allocates (tests/test-native.sps).
  (define (fold-flags flags who reason bit)
    (let ((n (proper-length flags)))
      (unless n
        (raise (make-uv-invalid-argument who reason)))
      (let walk ((rest flags) (left n) (bits 0))
        (cond ((zero? left) bits)
              ((not (pair? rest))
               (raise (make-uv-invalid-argument who reason)))
              (else
               (walk (cdr rest) (- left 1) (bitwise-ior bits (bit (car rest))))))))))
