#!r6rs
;;; uv-spawn!'s list reads against another thread, for
;;; tests/test-process.sps, and its lists malformed from the start, which
;;; tests/spawn-level-3-child.sps also runs at --optimize-level 3.
;;;
;;; uv-spawn! reads its lists in one interrupt-free step, which holds engines
;;; off but not other threads. In each race a flipper thread turns one field
;;; of a pair a call is given, a cdr or a car, between a cut and its whole
;;; value, while this thread calls uv-spawn! with it list-race-rounds times
;;; or more.
;;; Every call is refused before anything is allocated, and for one of two
;;; reasons: read whole, for something the list holds after the flipped
;;; pair; read cut, for the list itself, or the value the cut stands for.
;;;
;;; A read that takes the list's length after list? raises length's own
;;; condition when the flip lands between the two. A read that stops at the
;;; cut, or walks as many pairs as it counted without requiring the end,
;;; reads a list without its last element, so the call goes on, and is
;;; refused because its pipe is on another loop. A pipe spec's pair read
;;; twice gives Chez's own cddr or cadr condition. A key or a kind read
;;; twice reads a value as some other key's, but the entry-key and
;;; spec-kind races catch that only sometimes: the two reads are a few
;;; instructions apart, and the flipper's store rarely lands between them
;;; unless this thread is descheduled there. With the read doubled, run
;;; alone 30 times at a load near 3, each race caught it in 1 or 2 runs;
;;; inside the full suite at a load of 4 to 10, in at least 1 run of 2.
;;; In the args-circular race the cut makes the list circular: a read can
;;; then go around the cycle more than once, but every walk to the list's
;;; end passes its last string, so the same two reasons hold.
;;;
;;; Each call names a file that does not exist, so a read that loses the
;;; pipe on another loop, the one thing between a wrong read and a spawn,
;;; reaches uv_spawn and is refused there with ENOENT, leaving no child; with
;;; a real program, every such call would leave one, and nothing would reap
;;; them. A race stops at the first outcome that reached uv_spawn, since
;;; each failed spawn leaves a closing handle that the next one's cleanup
;;; walks past; it counts every other wrong outcome and goes on.
;;;
;;; A flipper that never ran, or stopped, would leave every race passing.
;;; So before the first call and after the last, each race waits to see its
;;; flipper cut the field and make it whole again, watching the pair through
;;; the argument the calls are given (tests/uv-race.sls). And a flipper that
;;; flipped only around those two watches would leave every call reading the
;;; list whole, so a race calls on past list-race-rounds until a call has
;;; been refused for the cut, up to list-race-cap calls. Each race stops its
;;; flipper and joins it on every exit, a raise included: a flipper left
;;; running would make the suite's last (collect) raise.
;;;
;;; NOT pure: it spawns through (libuv process).
(library (spawn-list-races)
  (export list-race-rounds defined-list-races list-races list-race-verdicts
          list-race-liveness malformed-refusals)
  (import (rnrs)
          (rnrs mutable-pairs)
          (libuv loop)
          (libuv pipe)
          (libuv process)
          (libuv private conditions)
          (only (uv-evidence) describe)
          (only (uv-race) watch-change)
          (only (chezscheme) fork-thread thread-join last-pair))

  (define list-race-rounds 100000)
  (define list-race-cap (* 10 list-race-rounds))

  ;; The file every call names: none, so a call that gets as far as
  ;; uv_spawn is refused with ENOENT and forks nothing.
  (define no-such-file "/nonexistent/sh")

  ;; stdio-to : uv-pipe -> list
  ;; A stdio list naming PIPE, which is on another loop than the calls'.
  (define (stdio-to pipe) (list (list 'pipe pipe 'from-child)))

  (define (a-cut) (vector 'not 'a 'pair))

  ;; refusal-of : (-> any) -> object
  ;; The reason THUNK's call was refused for (&uv-invalid-argument), or what
  ;; else came of it: (spawn-failed errno) for a call refused by uv_spawn,
  ;; (raised text) for any other condition, 'not-refused for a call that
  ;; returned.
  (define (refusal-of thunk)
    (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e))
              ((uv-errno-error? e) (list 'spawn-failed (uv-errno-error-errno e)))
              (#t (list 'raised (describe e))))
      (thunk)
      'not-refused))

  ;; reached-spawn? : object -> boolean
  ;; Whether an outcome of refusal-of got as far as uv_spawn.
  (define (reached-spawn? outcome)
    (or (eq? outcome 'not-refused)
        (and (pair? outcome) (eq? (car outcome) 'spawn-failed))))

  ;; Each variant: its name, the reason a call is refused for with the field
  ;; whole, the reason with it cut, and how to make its race. MAKE takes the
  ;; pipe and answers (list args options pair field cut watched): the
  ;; call's arguments, the pair whose FIELD (car or cdr) the flipper turns,
  ;; what it turns that field to, and a thunk that finds the same pair again
  ;; through the call's arguments.
  (define (args-variant name cut-of)
    (list name 'embedded-nul 'args-not-a-string-list
          (lambda (pipe)
            (let ((args (list "sh" "a" "b" "c" "d" "e" "x\x0;y")))
              (list args (list (cons 'stdio (stdio-to pipe)))
                    (list-tail args 2) 'cdr (cut-of args)
                    (lambda () (list-tail args 2)))))))

  (define variants
    (list
     (args-variant 'args (lambda (args) (a-cut)))
     (args-variant 'args-circular (lambda (args) args))
     (list 'env 'embedded-nul 'env-not-a-string-list
           (lambda (pipe)
             (let ((options (list (cons 'env (list "A=1" "B=2" "C=3" "D=4" "E=\x0;"))
                                  (cons 'stdio (stdio-to pipe)))))
               (list '("sh") options (list-tail (cdar options) 2) 'cdr (a-cut)
                     (lambda () (list-tail (cdr (assq 'env options)) 2))))))
     (list 'options 'uid-out-of-range 'option-unknown
           (lambda (pipe)
             (let ((options (list (cons 'stdio (stdio-to pipe)) (cons 'cwd "/")
                                  (cons 'detached #f) (cons 'gid 0)
                                  (cons 'env (list "A=1")) (cons 'uid -1))))
               (list '("sh") options (list-tail options 2) 'cdr (a-cut)
                     (lambda () (list-tail options 2))))))
     (list 'stdio 'stdio-fd-not-an-fd 'stdio-not-a-list
           (lambda (pipe)
             (let ((options (list (cons 'stdio (append (stdio-to pipe)
                                                       (list 'ignore 'ignore 'ignore 'ignore
                                                             (cons 'inherit-fd -1)))))))
               (list '("sh") options (list-tail (cdar options) 2) 'cdr (a-cut)
                     (lambda () (list-tail (cdr (assq 'stdio options)) 2))))))
     ;; The pipe spec (pipe the-pipe from-child): the cdr of its second
     ;; pair, the one that holds the direction.
     (list 'pipe-spec 'pipe-wrong-loop 'stdio-spec-unknown
           (lambda (pipe)
             (let ((options (list (cons 'stdio (stdio-to pipe)))))
               (list '("sh") options (cdr (car (cdar options))) 'cdr 0
                     (lambda () (cdr (cadr (assq 'stdio options))))))))
     ;; The same spec's first pair, whose cdr holds the pipe and direction.
     (list 'pipe-spec-head 'pipe-wrong-loop 'stdio-spec-unknown
           (lambda (pipe)
             (let ((options (list (cons 'stdio (stdio-to pipe)))))
               (list '("sh") options (car (cdar options)) 'cdr 0
                     (lambda () (cadr (assq 'stdio options)))))))
     ;; An options entry's key, turned between env and cwd: as cwd, its value
     ;; is no string.
     (list 'entry-key 'pipe-wrong-loop 'cwd-not-a-string
           (lambda (pipe)
             (let ((options (list (cons 'env (list "A=1")) (cons 'stdio (stdio-to pipe)))))
               (list '("sh") options (car options) 'car 'cwd
                     (lambda () (car options))))))
     ;; A stdio spec's kind, turned between pipe and inherit-fd: as
     ;; inherit-fd, its value is no fd.
     (list 'spec-kind 'pipe-wrong-loop 'stdio-fd-not-an-fd
           (lambda (pipe)
             (let ((options (list (cons 'stdio (stdio-to pipe)))))
               (list '("sh") options (car (cdar options)) 'car 'inherit-fd
                     (lambda () (cadr (assq 'stdio options)))))))))

  ;; defined-list-races : -> (list-of symbol)
  ;; The name of every race defined here, in order.
  (define (defined-list-races) (map car variants))

  ;; list-race : variant uv-loop uv-pipe
  ;;             -> (list name calls bad first-bad cuts before after)
  ;; BAD counts the calls refused for neither reason, or not refused, and
  ;; FIRST-BAD names the first; the race stops at one that reached uv_spawn.
  ;; CUTS counts the calls refused for the cut.
  (define (list-race variant loop pipe)
    (let* ((whole-reason (cadr variant))
           (cut-reason (caddr variant))
           (made ((cadddr variant) pipe))
           (args (list-ref made 0))
           (options (list-ref made 1))
           (p (list-ref made 2))
           (field (list-ref made 3))
           (cut (list-ref made 4))
           (watched (list-ref made 5))
           (get (if (eq? field 'car) car cdr))
           (set (if (eq? field 'car) set-car! set-cdr!))
           (whole (get p))
           (call (lambda () (uv-spawn! loop no-such-file args options #f)))
           (stop #f)
           (flipper #f))
      (dynamic-wind
       (lambda ()
         (set! flipper
               (fork-thread
                (lambda ()
                  (let flip ()
                    (unless stop
                      (set p cut)
                      (set p whole)
                      (flip)))))))
       (lambda ()
         (let* ((watch (lambda () (watch-change (lambda () (get (watched))) cut whole)))
                (before (watch))
                (result
                 (let round ((r 0) (bad 0) (first-bad #f) (cuts 0))
                   (if (or (and (>= r list-race-rounds) (positive? cuts))
                           (= r list-race-cap))
                       (list r bad first-bad cuts)
                       (let ((outcome (refusal-of call)))
                         (cond ((eq? outcome whole-reason)
                                (round (+ r 1) bad first-bad cuts))
                               ((eq? outcome cut-reason)
                                (round (+ r 1) bad first-bad (+ cuts 1)))
                               ((reached-spawn? outcome)
                                (list (+ r 1) (+ bad 1) (or first-bad (list r outcome)) cuts))
                               (else
                                (round (+ r 1) (+ bad 1)
                                       (or first-bad (list r outcome)) cuts)))))))
                (after (watch)))
           (cons (car variant) (append result (list before after)))))
       (lambda ()
         (set! stop #t)
         (thread-join flipper)))))

  ;; with-race-loops : (uv-loop uv-pipe -> object) -> object
  ;; BODY's answer, given a loop made for its calls and a pipe on another.
  ;; Both loops are torn down after it, whether it answers or raises
  ;; (call-with-uv-loop), and a refused call leaves them holding only that
  ;; pipe, which the teardown closes.
  (define (with-race-loops body)
    (call-with-uv-loop
     (lambda (other)
       (let ((pipe (make-uv-pipe other)))
         (call-with-uv-loop (lambda (loop) (body loop pipe)))))))

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
  ;; for that; one that took it for () reaches uv_spawn and is refused
  ;; ENOENT. At --optimize-level 3 a list counted with Chez's length, which
  ;; checks nothing there, is walked forever when it is circular.
  (define (malformed-refusals)
    (with-race-loops
     (lambda (loop pipe)
       (define (outcome args options)
         (refusal-of (lambda () (uv-spawn! loop no-such-file args options #f))))
       ;; A rest list is fresh on every call, so it can be made circular.
       (define (circular . elements)
         (set-cdr! (last-pair elements) elements)
         elements)
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

  ;; race-of : object symbol -> (or race-result #f)
  ;; NAME's race in RACES, the answer of list-races or whatever stood in for
  ;; it; total, so that a row reading it cannot raise.
  (define (race-of races name)
    (let ((race (and (list? races)
                     (for-all pair? races)
                     (assq name races))))
      (and race (list? race) (= (length race) 7) race)))

  ;; list-race-verdicts : object (list-of symbol) -> list
  ;; Each named race's (name bad first-bad), or what stood in its way.
  (define (list-race-verdicts races names)
    (map (lambda (name)
           (let ((race (race-of races name)))
             (if race
                 (list name (list-ref race 2) (list-ref race 3))
                 (list name 'no-race races))))
         names))

  ;; list-race-liveness : object (list-of symbol) -> list
  ;; Each named race's (name before after cut-seen): its two watches, and
  ;; 'cut-seen once a call was refused for the cut, or (no-cut-in calls).
  (define (list-race-liveness races names)
    (map (lambda (name)
           (let ((race (race-of races name)))
             (if race
                 (list name (list-ref race 5) (list-ref race 6)
                       (if (positive? (list-ref race 4))
                           'cut-seen
                           (list 'no-cut-in (list-ref race 1))))
                 (list name 'no-race races))))
         names)))
