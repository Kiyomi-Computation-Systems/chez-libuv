#!r6rs
;;; uv-spawn!'s list reads against another thread (#66 items 2 and 3), shared
;;; by tests/test-process.sps, which runs them at the default optimize level,
;;; and tests/spawn-level-3-child.sps, which runs them at level 3.
;;;
;;; uv-spawn! reads its lists in one interrupt-free step, which holds engines
;;; off but not other threads. In each race a flipper thread turns one cdr of
;;; a list a call is given between a cut and the rest of the list, while this
;;; thread calls uv-spawn! with it list-race-rounds times. Every call is
;;; refused before anything is allocated, and for one of two reasons: read
;;; whole, for something the list holds after the flipped pair; read cut, for
;;; the list itself. A read that took the list's length after list? raised
;;; length's own condition when the flip landed between the two, and at
;;; --optimize-level 3, where length checks nothing, read through the cut or
;;; walked a list made circular forever. A read that stopped at the cut, or
;;; walked as many pairs as it counted without requiring the end, read a list
;;; without its last element, so the call went on, and was refused because
;;; its pipe is on another loop. A pipe spec's second pair, read twice, gave
;;; Chez's own cddr condition. In the args-circular race the cut makes the
;;; list circular: a read can then walk around the cycle more than once, but
;;; every walk to the list's end passes its last string, so the same two
;;; reasons hold.
;;;
;;; A flipper that never ran, or stopped, would leave every race passing. So
;;; before the first call and after the last, each race waits up to
;;; race-wait-cap steps to see its flipper cut the list and make it whole
;;; again, watching the pair through the argument the calls are given, as
;;; tests/test-native.sps's races do.
;;;
;;; NOT pure: it spawns through (libuv process).
(library (spawn-list-races)
  (export list-race-rounds list-races list-race-verdicts list-race-liveness
          malformed-refusals)
  (import (rnrs)
          (rnrs mutable-pairs)
          (libuv loop)
          (libuv handle)
          (libuv pipe)
          (libuv process)
          (libuv private conditions)
          (uv-testing)
          (only (uv-evidence) describe)
          (only (chezscheme) fork-thread thread-join))

  (define list-race-rounds 100000)
  (define race-wait-cap 100000000)

  ;; watch-flipper : pair object object -> (or 'flipping 'not-flipping)
  ;; Whether P's cdr was seen to be CUT and then WHOLE again within
  ;; race-wait-cap steps.
  (define (watch-flipper p cut whole)
    (let wait ((k 0) (seen-cut #f))
      (cond ((= k race-wait-cap) 'not-flipping)
            ((eq? (cdr p) cut) (wait (+ k 1) #t))
            ((and seen-cut (eq? (cdr p) whole)) 'flipping)
            (else (wait (+ k 1) seen-cut)))))

  ;; stdio-to : uv-pipe -> list
  ;; A stdio list naming PIPE, which is on another loop than the calls'.
  (define (stdio-to pipe) (list (list 'pipe pipe 'from-child)))

  (define (a-cut) (vector 'not 'a 'pair))

  ;; Each variant: its name, the reason a call is refused for with the list
  ;; whole, the reason with it cut, and how to make its race. MAKE takes the
  ;; calls' loop and the pipe, and answers (list call flipped cut watched):
  ;; the call, the pair the flipper turns, what it turns that pair's cdr to,
  ;; and a thunk that finds the same pair again through the call's argument.
  (define variants
    (list
     (list 'args 'embedded-nul 'args-not-a-string-list
           (lambda (loop pipe)
             (let ((args (list "sh" "a" "b" "c" "d" "e" "x\x0;y")))
               (list (lambda ()
                       (uv-spawn! loop "/bin/sh" args (list (cons 'stdio (stdio-to pipe))) #f))
                     (list-tail args 2)
                     (a-cut)
                     (lambda () (list-tail args 2))))))
     (list 'args-circular 'embedded-nul 'args-not-a-string-list
           (lambda (loop pipe)
             (let ((args (list "sh" "a" "b" "c" "d" "e" "x\x0;y")))
               (list (lambda ()
                       (uv-spawn! loop "/bin/sh" args (list (cons 'stdio (stdio-to pipe))) #f))
                     (list-tail args 2)
                     args
                     (lambda () (list-tail args 2))))))
     (list 'env 'embedded-nul 'env-not-a-string-list
           (lambda (loop pipe)
             (let ((options (list (cons 'env (list "A=1" "B=2" "C=3" "D=4" "E=\x0;"))
                                  (cons 'stdio (stdio-to pipe)))))
               (list (lambda () (uv-spawn! loop "/bin/sh" '("sh") options #f))
                     (list-tail (cdar options) 2)
                     (a-cut)
                     (lambda () (list-tail (cdr (assq 'env options)) 2))))))
     (list 'options 'uid-out-of-range 'option-unknown
           (lambda (loop pipe)
             (let ((options (list (cons 'stdio (stdio-to pipe)) (cons 'cwd "/")
                                  (cons 'detached #f) (cons 'gid 0)
                                  (cons 'env (list "A=1")) (cons 'uid -1))))
               (list (lambda () (uv-spawn! loop "/bin/sh" '("sh") options #f))
                     (list-tail options 2)
                     (a-cut)
                     (lambda () (list-tail options 2))))))
     (list 'stdio 'stdio-fd-not-an-fd 'stdio-not-a-list
           (lambda (loop pipe)
             (let ((options (list (cons 'stdio (append (stdio-to pipe)
                                                       (list 'ignore 'ignore 'ignore 'ignore
                                                             (cons 'inherit-fd -1)))))))
               (list (lambda () (uv-spawn! loop "/bin/sh" '("sh") options #f))
                     (list-tail (cdar options) 2)
                     (a-cut)
                     (lambda () (list-tail (cdr (assq 'stdio options)) 2))))))
     ;; The flipper turns the second pair of (pipe the-pipe from-child).
     (list 'pipe-spec 'pipe-wrong-loop 'stdio-spec-unknown
           (lambda (loop pipe)
             (let ((options (list (cons 'stdio (stdio-to pipe)))))
               (list (lambda () (uv-spawn! loop "/bin/sh" '("sh") options #f))
                     (cdr (car (cdar options)))
                     0
                     (lambda () (cdr (cadr (assq 'stdio options))))))))))

  ;; list-race : variant uv-loop uv-pipe
  ;;             -> (list name rounds bad first-bad cut before after)
  ;; BAD counts the calls refused for neither reason, or not refused; CUT the
  ;; calls refused for the list cut. It stops the flipper and joins it before
  ;; it answers.
  (define (list-race variant loop pipe)
    (let* ((whole-reason (cadr variant))
           (cut-reason (caddr variant))
           (made ((cadddr variant) loop pipe))
           (call (car made))
           (p (cadr made))
           (cut (caddr made))
           (watched (cadddr made))
           (rest (cdr p))
           (stop #f)
           (flipper
            (fork-thread
             (lambda ()
               (let flip ()
                 (unless stop
                   (set-cdr! p cut)
                   (set-cdr! p rest)
                   (flip))))))
           (before (watch-flipper (watched) cut rest)))
      (let ((result
             (let round ((r 0) (bad 0) (first-bad #f) (cuts 0))
               (if (= r list-race-rounds)
                   (list r bad first-bad cuts)
                   (let ((outcome
                          (guard (e ((uv-invalid-argument? e)
                                     (uv-invalid-argument-reason e))
                                    (#t (list 'raised (describe e))))
                            (call)
                            'not-refused)))
                     (cond ((eq? outcome whole-reason)
                            (round (+ r 1) bad first-bad cuts))
                           ((eq? outcome cut-reason)
                            (round (+ r 1) bad first-bad (+ cuts 1)))
                           (else
                            (round (+ r 1) (+ bad 1)
                                   (or first-bad (list r outcome)) cuts))))))))
        (let ((after (watch-flipper (watched) cut rest)))
          (set! stop #t)
          (thread-join flipper)
          (cons (car variant) (append result (list before after)))))))

  ;; with-race-loops : (uv-loop uv-pipe -> object) -> object
  ;; BODY's answer, given a loop made for its calls and a pipe on another.
  ;; Both loops are torn down after it, and a refused call leaves them
  ;; holding only that pipe.
  (define (with-race-loops body)
    (let* ((loop (make-uv-loop))
           (other (make-uv-loop))
           (pipe (make-uv-pipe other))
           (answer (body loop pipe)))
      (uv-close! pipe)
      (run-until other (lambda () (eq? 'closed (uv-handle-state pipe))) 64)
      (uv-loop-teardown! other)
      (uv-loop-teardown! loop)
      answer))

  ;; list-races : (list-of symbol) -> (list-of race-result)
  ;; The races NAMES names, in that order.
  (define (list-races names)
    (with-race-loops
     (lambda (loop pipe)
       (let next ((names names))
         (if (null? names)
             '()
             (let ((race (list-race (assq (car names) variants) loop pipe)))
               (cons race (next (cdr names)))))))))

  ;; malformed-refusals : -> (list-of (symbol . object))
  ;; What uv-spawn! does with each of its lists improper or circular from
  ;; the start, no thread needed: the reason it is refused for, or what
  ;; else came of it. Each call also names the pipe on another loop, so a
  ;; read that took a malformed list for a shorter proper one is refused
  ;; for that, never spawns. At --optimize-level 3 a list counted with
  ;; Chez's length, which checks nothing there, is walked forever when it
  ;; is circular, as #66 found checked-flags walking a flag list.
  (define (malformed-refusals)
    (with-race-loops
     (lambda (loop pipe)
       (define (outcome args options)
         (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e))
                   (#t (list 'raised (describe e))))
           (uv-spawn! loop "/bin/sh" args options #f)
           'not-refused))
       (define (circular . elements)
         (let ((l (list-copy elements)))
           (set-cdr! (last-pair* l) l)
           l))
       (define stdio (cons 'stdio (stdio-to pipe)))
       (list
        (cons 'improper-args (outcome (cons "sh" "x") (list stdio)))
        (cons 'circular-args (outcome (circular "sh" "x") (list stdio)))
        (cons 'improper-env
              (outcome '("sh") (list (cons 'env (cons "A=1" "B=2")) stdio)))
        (cons 'circular-env
              (outcome '("sh") (list (cons 'env (circular "A=1" "B=2")) stdio)))
        (cons 'improper-options (outcome '("sh") (cons stdio 'tail)))
        (cons 'circular-options (outcome '("sh") (circular stdio (cons 'cwd "/"))))
        (cons 'improper-stdio
              (outcome '("sh") (list (cons 'stdio (cons (car (stdio-to pipe)) 'ignore)))))
        (cons 'circular-stdio
              (outcome '("sh") (list (cons 'stdio (circular (car (stdio-to pipe)) 'ignore)))))))))

  (define (list-copy l) (if (pair? l) (cons (car l) (list-copy (cdr l))) l))

  (define (last-pair* l) (if (pair? (cdr l)) (last-pair* (cdr l)) l))

  ;; race-of : object symbol -> (or race-result #f)
  ;; NAME's race in RACES, the answer of list-races or whatever stood in for
  ;; it; total, so that a row reading it cannot raise.
  (define (race-of races name)
    (let ((race (and (list? races)
                     (for-all pair? races)
                     (assq name races))))
      (and race (list? race) (= (length race) 7) race)))

  ;; list-race-verdicts : object (list-of symbol) -> list
  ;; Each named race's (name rounds bad first-bad), or what stood in its way.
  (define (list-race-verdicts races names)
    (map (lambda (name)
           (let ((race (race-of races name)))
             (if race (list-head* race 4) (list name 'no-race races))))
         names))

  ;; list-race-liveness : object (list-of symbol) -> list
  ;; Each named race's (name before after), or what stood in its way.
  (define (list-race-liveness races names)
    (map (lambda (name)
           (let ((race (race-of races name)))
             (if race
                 (list name (list-ref race 5) (list-ref race 6))
                 (list name 'no-race races))))
         names))

  (define (list-head* l n)
    (if (zero? n) '() (cons (car l) (list-head* (cdr l) (- n 1))))))
