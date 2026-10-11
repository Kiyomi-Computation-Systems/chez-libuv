#!r6rs
;;; Caller lists, read once.
;;;
;;; A list the caller can still reach can change while a verb reads it: an
;;; engine's handler runs between any two trap checks, and another thread
;;; between any two instructions. Chez's own list procedures assume nothing
;;; changes. map measures a list and then walks it unchecked, and at
;;; --optimize-level 3 length walks it with no check at all, so a list made
;;; circular is walked forever. These check each pair before reading
;;; through it, and every walk is bounded. A list of any length is counted
;;; first and walked no further than its count (read-proper-list,
;;; fold-flags), and its walk ends once the list stops changing. A list of
;;; a fixed length is walked no further than that length (let-fixed-list).
;;; Pure: no native code (tests/test-addrinfo.sps, under make check-purity).
(library (libuv private lists)
  (export proper-length read-proper-list fold-flags let-fixed-list)
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
  ;; A count that walks a tortoise behind its hare along the list's links
  ;; (Floyd's check) has no such guarantee: one change can cut the
  ;; tortoise's way, and two can leave the two on separate cycles, where the
  ;; count never ends.
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
  ;; and X's end is required after them. READ sees the elements in order, as
  ;; each pair stood when the walk reached it, and may raise.
  ;;
  ;; A walk that contradicts its count, meeting a non-pair before the count
  ;; runs out or no end after it, means the list changed after it was
  ;; counted, and the read counts and walks it once more; READ then sees the
  ;; elements of the abandoned walk again. So a list changed once during the
  ;; read answers as it was before the change or after it, or #f when that
  ;; version is no proper list. Without the second read, one change between
  ;; the count and the walk would make a list that was proper before and
  ;; after it answer #f (tests/test-native.sps's one-change race). Without
  ;; the end, a tail spliced in during the read would be read only as far as
  ;; the stale count, and the answer would end where the list did not (the
  ;; spliced-longer sweep there).
  ;;
  ;; A list changed more than once can answer a mix of its versions, or #f
  ;; though every version was a proper list. One made circular and whole
  ;; again during the count, and again during the walk, is counted and then
  ;; walked once around its cycle: its elements in an order it never held
  ;; them in (tests/test-native.sps's cycle race). No read that takes no lock
  ;; can rule that out. A read inside one interrupt-free step, as uv-spawn!'s
  ;; is, sees no engine's handler, so only another thread can do it. Nothing
  ;; is allocated but the answer, and what READ allocates.
  (define (read-proper-list x read)
    (walk-counted x read-counted read))

  ;; (walk-counted x-expr walk arg ...) -> (or answer #f)
  ;; (WALK x n ARG ...) for X's count N, or #f when X is not a proper list.
  ;; A walk that answers #f has found X contradicting its count, and X is
  ;; counted and walked once more. read-proper-list and fold-flags both read
  ;; this way, so a list changed once during either read answers as it was
  ;; before the change or after it. A macro, so that fold-flags hands its
  ;; walk BIT without a closure: it allocates nothing. Each ARG is evaluated
  ;; once a walk, so it is a variable.
  (define-syntax walk-counted
    (syntax-rules ()
      ((_ x-expr walk arg ...)
       (let* ((x x-expr) (n (proper-length x)))
         (and n
              (or (walk x n arg ...)
                  (let ((n (proper-length x)))
                    (and n (walk x n arg ...)))))))))

  ;; read-counted : object exact-nonnegative-integer (object -> object)
  ;;                -> (or list #f)
  ;; The fresh list of (READ e) for the first N pairs of X, each checked
  ;; before it is read through, when X's end follows them; #f otherwise.
  (define (read-counted x n read)
    (let walk ((p x) (left n))
      (cond ((zero? left) (and (null? p) '()))
            ((pair? p)
             (let* ((element (read (car p)))
                    (rest (walk (cdr p) (- left 1))))
               (and rest (cons element rest))))
            (else #f))))

  ;; fold-flags : object symbol symbol (object -> exact-integer)
  ;;              -> exact-integer
  ;; The bitwise-ior of (BIT flag) over a caller's flag list, which is read
  ;; once, as read-proper-list reads: counted with proper-length, at most
  ;; that many pairs walked, each checked as it is read, and the list's end
  ;; required after them. A walk the list contradicts counts and walks it
  ;; once more (walk-counted), so a list changed once during the walk is
  ;; folded as it was or as the change left it; a list that is improper or
  ;; circular as read is refused (WHO, REASON), and none is walked forever.
  ;; Without the end, a tail spliced in during the walk would be folded as
  ;; far as the stale count, into flags the caller never held: (a b) made
  ;; (a c d) would fold a and c; without the second walk, a list proper
  ;; before and after the splice would be refused (tests/test-native.sps's
  ;; fold-flags splice sweep). Asking list? first would leave a gap an
  ;; engine's handler can change the list in, and fold-left walks a list
  ;; made circular there forever (tests/test-address.sps's flags sweeps).
  ;; Nothing here allocates (tests/test-native.sps).
  (define (fold-flags flags who reason bit)
    (or (walk-counted flags fold-counted bit)
        (raise (make-uv-invalid-argument who reason))))

  ;; fold-counted : object exact-nonnegative-integer (object -> exact-integer)
  ;;                -> (or exact-integer #f)
  ;; The bitwise-ior of (BIT e) for the first N pairs of X, each checked
  ;; before it is read through, when X's end follows them; #f otherwise.
  (define (fold-counted x n bit)
    (let walk ((p x) (left n) (bits 0))
      (cond ((zero? left) (and (null? p) bits))
            ((pair? p) (walk (cdr p) (- left 1) (bitwise-ior bits (bit (car p)))))
            (else #f))))

  ;; let-fixed-list : (let-fixed-list (name ...) list-expr mismatch body ...)
  ;; BODY with each NAME bound to the matching element of LIST-EXPR's value
  ;; when that is a proper list exactly as long as the NAMEs; MISMATCH
  ;; otherwise, evaluated once and only then. The list is walked once, each
  ;; pair checked before its car and cdr are read, and its end required after
  ;; the last NAME, so a list another thread changes during the read binds
  ;; each element as its pair stood when the walk reached it, or mismatches,
  ;; and is never read through a non-pair. Checking a shape first and reading
  ;; its fields after, as cadr does, reads each pair twice, and a cut made
  ;; in between raises Chez's own condition, or at --optimize-level 3 is
  ;; read through. Nothing is allocated (tests/test-native.sps).
  (define-syntax let-fixed-list
    (syntax-rules ()
      ((_ (name ...) list-expr mismatch body0 body ...)
       (let ((on-mismatch (lambda () mismatch)))
         (walk-fixed (name ...) list-expr (on-mismatch)
                     (let () body0 body ...))))))

  ;; (walk-fixed (name ...) p-expr fail done)
  ;; let-fixed-list's walk, one NAME a pair.
  (define-syntax walk-fixed
    (syntax-rules ()
      ((_ () p-expr fail done)
       (if (null? p-expr) done fail))
      ((_ (name more ...) p-expr fail done)
       (let ((p p-expr))
         (if (pair? p)
             (let ((name (car p)) (rest (cdr p)))
               (walk-fixed (more ...) rest fail done))
             fail))))))
