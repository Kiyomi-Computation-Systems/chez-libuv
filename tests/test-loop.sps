#!r6rs
;;; SRFI-64 suite for (libuv loop) and the registry core of
;;; (libuv private handles) -- design spec S5 (loop operations, the registry
;;; as GC root), S8 (the store-and-reraise callback error policy), S10 (debug
;;; counters), S11 (testing strategy), and ADR-0008 (eight dispatcher slots).
;;;
;;; This suite is NOT pure: (libuv loop) reaches (libuv private native),
;;; which loads libuv and the shim at library instantiation. It must never
;;; appear in the Makefile's PURE_TESTS.
;;;
;;; Tests import the private libraries directly and on purpose. The loop
;;; record's raw fields (loop-ptr, loop-state, loop-pending-error, ...) are
;;; where several design-spec decisions actually live -- "the freeing site
;;; zeroes the stored uptr immediately" (S10) is a statement about a field,
;;; and an assertion on the public surface alone cannot see it.
;;;
;;; ORDER IS LOAD-BEARING in two places, both marked below: the callback
;;; dispatcher slots and the close-handle! hook are process-global and
;;; install-once, so their "not installed yet" assertions have to run before
;;; the installs that the sweep test needs.
(import (rnrs)
        (srfi :64)
        (libuv loop)
        (libuv private handles)
        (libuv private conditions)
        ;; `only` rather than a plain import: (libuv private native) exports
        ;; uv-version, which the (libuv) facade also exports under the same
        ;; name as a different binding. Nothing here needs it -- the facade's
        ;; own surface is tests/test-facade.sps's job.
        (only (libuv private native)
              native-initialized? live-counts uv-loop-size
              dispatcher-names dispatcher-ref dispatchers-installed?
              install-callback-dispatchers!)
        (only (chezscheme) collect))

;; SRFI-64's default runner does not set a process exit code (AGENTS.md).
(define runner (test-runner-simple))
(test-runner-current runner)

;; Captured BEFORE anything in this suite creates a loop, so the seeds below
;; are real observations rather than restatements of the current state.
(define native-initialized-at-start (native-initialized?))
(define registry-count-at-start (registry-count))

(define (live-count kind) (cdr (assq kind (live-counts))))

(test-begin "loop")

;; --- seeds --------------------------------------------------------------
;; Every counter assertion in this suite requires the DEV shim (the
;; Makefile's CFLAGS_DEV, -DCHEZ_LIBUV_DEBUG_COUNTERS). Against a production
;; shim the live queries always answer 0, so the "moved" assertions would
;; fail while pointing at cross-wiring that is not there. Name that
;; precondition first, the way tests/test-native.sps does.
(test-equal "seed: no loop is live before this suite creates one"
  0 (live-count 'loop))

(test-equal "seed: the handle registry is empty before this suite registers anything"
  0 registry-count-at-start)

(test-equal "seed: the native layer is not initialised before the first make-uv-loop"
  #t (not native-initialized-at-start))

;; --- make-uv-loop -------------------------------------------------------
(define l0 (make-uv-loop))

(test-equal "make-uv-loop initialises the native layer itself"
  #t (native-initialized?))

(test-equal "make-uv-loop returns a uv-loop record"
  'a-loop (if (uv-loop? l0) 'a-loop 'not-a-loop))

(test-equal "a fresh loop is open"
  'open (if (uv-loop-open? l0) 'open 'not-open))

(test-equal "a fresh loop's state field reads 'open"
  'open (loop-state l0))

;; A real foreign-alloc'd block: positive, and exactly one loop-sized block
;; is what make-uv-loop was asked for. `positive?` is the discriminating
;; part -- 0 is what a zeroed (freed) slot holds.
(test-equal "make-uv-loop stores a non-null loop pointer"
  'positive
  (if (and (integer? (loop-ptr l0)) (exact? (loop-ptr l0)) (positive? (loop-ptr l0)))
      'positive
      'null-or-not-a-pointer))

(test-equal "seed: creating a loop moves the live loop counter"
  1 (live-count 'loop))

(test-equal "make-uv-loop registers the loop in the handle registry"
  1 (- (registry-count) registry-count-at-start))

(test-equal "the registry entry resolves the loop pointer back to the loop record"
  'same (if (eq? l0 (registry-ref (loop-ptr l0))) 'same 'different))

;; The loop is registered, but it is NOT one of its own live handles: the
;; snapshot filters on the entry kind, and a loop that swept itself would
;; hand its own record to close-handle! during teardown.
(test-equal "a fresh loop reports no live handles (and never itself)"
  '() (uv-loop-live-handles l0))

(test-equal "a fresh loop has no deferred errors"
  '() (uv-loop-deferred-errors l0))

(test-equal "a fresh loop is not marked running"
  'not-running (if (loop-running? l0) 'running 'not-running))

;; --- uv-run over an empty loop ------------------------------------------
;; Asserted as 'no-work / 'work rather than #f / #t: SRFI-64 turns a raise in
;; the actual expression into #f, so an expected-#f assertion would pass if
;; uv-run blew up, and in Scheme every value except #f is true, so
;; test-assert would pass on the raw int a truthiness-confused uv-run
;; returned (AGENTS.md).
(test-equal "uv-run 'default on an empty loop reports no work remaining"
  'no-work (if (uv-run l0 'default) 'work 'no-work))

(test-equal "uv-run 'once on an empty loop reports no work remaining"
  'no-work (if (uv-run l0 'once) 'work 'no-work))

(test-equal "uv-run 'nowait on an empty loop reports no work remaining"
  'no-work (if (uv-run l0 'nowait) 'work 'no-work))

;; Also proves the running? flag is cleared on the way out: a uv-run that
;; left it set would make every subsequent uv-run raise 'loop-running.
(test-equal "uv-run defaults to 'default when no mode is given"
  'no-work (if (uv-run l0) 'work 'no-work))

(test-equal "uv-run leaves the running flag clear after it returns"
  'not-running (if (loop-running? l0) 'running 'not-running))

(test-equal "uv-run rejects an unknown mode, naming who and why"
  '(uv-run unknown-run-mode)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-run l0 'sideways)
    'no-raise))

(test-equal "uv-run rejects a non-loop argument, naming who and why"
  '(uv-run not-a-uv-loop)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-run 'not-a-loop 'nowait)
    'no-raise))

;; --- uv-loop-alive? -----------------------------------------------------
;; An empty loop is not alive before or after a run; the TRANSITION needs a
;; handle to hold the loop alive, which arrives with Task 7's timers. See
;; .plans/stage-2-mutation-log.md, "deferred coverage".
(test-equal "an empty loop is not alive"
  'not-alive (if (uv-loop-alive? l0) 'alive 'not-alive))

(test-equal "an empty loop is still not alive after a run"
  'not-alive
  (begin (uv-run l0 'nowait)
         (if (uv-loop-alive? l0) 'alive 'not-alive)))

;; --- uv-now -------------------------------------------------------------
(define now-before (uv-now l0))
(define now-run-result (uv-run l0 'nowait))
(define now-after (uv-now l0))

(test-equal "uv-now returns a positive exact integer (libuv's cached millisecond clock)"
  'positive-exact
  (if (and (integer? now-before) (exact? now-before) (positive? now-before))
      'positive-exact
      'not-a-timestamp))

(test-equal "uv-now does not go backwards across a run"
  'monotone (if (>= now-after now-before) 'monotone 'went-backwards))

;; --- the eight callback dispatcher slots (ADR-0008) ---------------------
;; ORDER IS LOAD-BEARING: the slots are process-global and install-once, so
;; every "not installed yet" assertion has to run before the install below.
(test-equal "dispatcher-names names the eight callback types the design commits to"
  '(alloc read connection write-done close timer shutdown connect)
  dispatcher-names)

(test-equal "before installation, dispatchers-installed? is false"
  'not-installed (if (dispatchers-installed?) 'installed 'not-installed))

(for-each
 (lambda (name)
   (test-equal (string-append "an uninstalled " (symbol->string name)
                              " dispatcher raises &uv-error when invoked")
     'uv-error
     (guard (e ((uv-error? e) 'uv-error) (#t 'wrong-condition))
       ((dispatcher-ref name) 0)
       'no-raise)))
 dispatcher-names)

(test-equal "dispatcher-ref rejects a name that is not one of the eight"
  '(uv-dispatcher-ref unknown-dispatcher)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (dispatcher-ref 'not-a-callback-type)
    'no-raise))

;; A partial install must be refused OUTRIGHT, leaving nothing installed --
;; a half-installed dispatcher table would hand libuv a trampoline that
;; raises from inside a C frame.
(test-equal "an install missing one of the eight is refused, naming who and why"
  '(uv-install-callback-dispatchers! incomplete-dispatcher-set)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (install-callback-dispatchers! (list (cons 'timer (lambda args 'partial))))
    'no-raise))

(test-equal "the refused install left the slots uninstalled"
  'not-installed (if (dispatchers-installed?) 'installed 'not-installed))

;; The stub procedures are Task 6's stand-in for Task 7's real dispatchers;
;; each answers with its own name so a cross-wired slot is visible.
(install-callback-dispatchers!
 (map (lambda (name) (cons name (lambda args (list 'stub name args))))
      dispatcher-names))

(test-equal "after installation, dispatchers-installed? is true"
  'installed (if (dispatchers-installed?) 'installed 'not-installed))

(for-each
 (lambda (name)
   (test-equal (string-append "the " (symbol->string name)
                              " slot now answers with the procedure installed for it")
     (list 'stub name '(7))
     ((dispatcher-ref name) 7)))
 dispatcher-names)

(test-equal "a second install is refused, naming who and why"
  '(uv-install-callback-dispatchers! dispatchers-already-installed)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (install-callback-dispatchers!
     (map (lambda (name) (cons name (lambda args 'second))) dispatcher-names))
    'no-raise))

(test-equal "the refused second install did not rebind a slot"
  (list 'stub 'timer '(7))
  ((dispatcher-ref 'timer) 7))

;; --- the close-handle! hook (Task 7 fills it) ---------------------------
;; ORDER IS LOAD-BEARING for the same reason as the dispatcher slots.
(test-equal "close-handle! raises &uv-error until Task 7 installs a real one"
  'uv-error
  (guard (e ((uv-error? e) 'uv-error) (#t 'wrong-condition))
    (close-handle! '(0 . not-a-handle))
    'no-raise))

;; The probe stands in for Task 7's uv-close!: it records what it was handed
;; and drops the entry from the registry, which is what makes the teardown
;; sweep below observable.
(define closed-handles '())

(install-close-handle!
 (lambda (handle)
   (set! closed-handles (cons handle closed-handles))
   (registry-deregister! (car handle))))

(test-equal "close-handle! now routes to the installed procedure"
  'routed
  (let ((probe (cons 987654321 'probe-handle)))
    (registry-register! (car probe) 'timer l0 probe)
    (close-handle! probe)
    (set! closed-handles (cdr closed-handles))   ; not part of the sweep test
    (if (registry-ref (car probe)) 'still-registered 'routed)))

(test-equal "a second close-handle! install is refused, naming who and why"
  '(uv-install-close-handle! close-handle-already-installed)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (install-close-handle! (lambda (handle) 'second))
    'no-raise))

;; --- the registry, directly ---------------------------------------------
(define other-loop (make-uv-loop))
(define fake-handle (cons 4242 'fake-timer))
(define registry-count-before-fake (registry-count))

(registry-register! (car fake-handle) 'timer l0 fake-handle)

(test-equal "registry-register! makes the entry retrievable by its pointer"
  'same (if (eq? fake-handle (registry-ref (car fake-handle))) 'same 'different))

(test-equal "registry-register! moves the registry count"
  1 (- (registry-count) registry-count-before-fake))

(test-equal "a registered handle appears in its own loop's live-handle snapshot"
  'listed
  (if (memq fake-handle (uv-loop-live-handles l0)) 'listed 'missing))

(test-equal "it does not appear in another loop's snapshot"
  '() (uv-loop-live-handles other-loop))

(test-equal "registering the same pointer twice is refused, naming who and why"
  '(uv-registry-register! pointer-already-registered)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (registry-register! (car fake-handle) 'timer l0 fake-handle)
    'no-raise))

(test-equal "registry-register! rejects a null pointer, naming who and why"
  '(uv-registry-register! null-or-invalid-pointer)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (registry-register! 0 'timer l0 fake-handle)
    'no-raise))

(registry-deregister! (car fake-handle))

(test-equal "registry-deregister! removes the entry"
  'absent (if (registry-ref (car fake-handle)) 'present 'absent))

(test-equal "registry-deregister! returns the count to where it was"
  0 (- (registry-count) registry-count-before-fake))

(test-equal "deregistering an unregistered pointer is refused, naming who and why"
  '(uv-registry-deregister! pointer-not-registered)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (registry-deregister! (car fake-handle))
    'no-raise))

;; --- the callback error policy (design spec S8) -------------------------
;; The dispatcher guard that CALLS loop-record-error! arrives with Task 7;
;; the recording policy itself is exercised here by direct calls, which is
;; also the only way to reach the "second and later errors" arm without a
;; callback that raises twice.
(define policy-loop (make-uv-loop))
(define err-1 (make-uv-errno-error 'ECONNRESET -104 "connection reset by peer"))
(define err-2 (make-uv-errno-error 'EPIPE -32 "broken pipe"))
(define err-3 (make-uv-invalid-argument 'on-timer 'third-error))

(loop-record-error! policy-loop err-1)

(test-equal "the first callback error becomes the loop's pending error"
  'stored (if (eq? err-1 (loop-pending-error policy-loop)) 'stored 'not-stored))

(test-equal "the first callback error is not put on the deferred list"
  '() (uv-loop-deferred-errors policy-loop))

(loop-record-error! policy-loop err-2)

(test-equal "a second callback error leaves the pending error alone"
  'first-still-pending
  (if (eq? err-1 (loop-pending-error policy-loop))
      'first-still-pending
      'overwritten))

(test-equal "a second callback error is appended to the deferred list"
  'second-deferred
  (let ((d (uv-loop-deferred-errors policy-loop)))
    (if (and (= 1 (length d)) (eq? err-2 (car d))) 'second-deferred 'unexpected)))

(loop-record-error! policy-loop err-3)

(test-equal "deferred errors read back in occurrence order"
  'in-order
  (let ((d (uv-loop-deferred-errors policy-loop)))
    (if (and (= 2 (length d)) (eq? err-2 (car d)) (eq? err-3 (cadr d)))
        'in-order
        'out-of-order)))

;; uv-run's re-raise. The compound is the load-bearing part of S8: a guard
;; written against the ORIGINAL condition type still has to match.
(define raised-by-run
  (guard (e (#t e))
    (uv-run policy-loop 'nowait)
    'no-raise))

(test-equal "uv-run re-raises the pending callback error on the way out"
  'raised (if (condition? raised-by-run) 'raised 'no-raise))

(test-equal "the re-raised condition satisfies uv-callback-error?"
  'callback-error
  (if (uv-callback-error? raised-by-run) 'callback-error 'not-callback-error))

(test-equal "the re-raised condition ALSO satisfies the original condition's own predicate"
  'errno-error
  (if (uv-errno-error? raised-by-run) 'errno-error 'not-errno-error))

(test-equal "the compound still answers the original condition's field accessors"
  'ECONNRESET (uv-errno-error-errno raised-by-run))

(test-equal "the callback-error's cause is the original condition object"
  'same (if (eq? err-1 (uv-callback-error-cause raised-by-run)) 'same 'different))

(test-equal "the pending error is consumed by the re-raise (the loop stays usable)"
  'no-pending
  (if (loop-has-pending-error? policy-loop) 'still-pending 'no-pending))

;; WHAT THIS SEQUENCE CAN AND CANNOT SHOW. With real callbacks the order is:
;; the raises happen DURING run N, the caller reads them once run N has
;; returned (or re-raised), and run N+1 clears them. Without callbacks the
;; errors can only be recorded BEFORE a run, so the run that re-raises is
;; also the run whose start-clear discards the deferred list. The
;; readable-until-the-next-run half is what the three order assertions above
;; check, against a loop with no run in between; the clearing half is what
;; this one checks. The full end-to-end shape needs Task 7's timer callbacks
;; -- recorded under "deferred coverage" in .plans/stage-2-mutation-log.md.
(test-equal "uv-run clears the deferred list at the START of a run"
  '() (uv-loop-deferred-errors policy-loop))

(test-equal "the loop runs normally after the re-raise"
  'no-work (if (uv-run policy-loop 'nowait) 'work 'no-work))

;; A callback may raise a non-condition object (R6RS `raise` accepts any
;; value); the compound combinator does not apply to those, so they are
;; wrapped alone.
(loop-record-error! policy-loop 'a-bare-symbol)

(define raised-bare
  (guard (e (#t e))
    (uv-run policy-loop 'nowait)
    'no-raise))

(test-equal "a non-condition callback raise is wrapped in &uv-callback-error alone"
  'callback-error
  (if (uv-callback-error? raised-bare) 'callback-error 'not-callback-error))

(test-equal "its cause is the raised object itself"
  'a-bare-symbol (uv-callback-error-cause raised-bare))

;; ...and #f is one of those objects. This is the case that makes the loop
;; record's empty-pending marker a private sentinel rather than #f: a
;; callback's own (raise #f) must be recorded, must be re-raised, and must not
;; make the NEXT error look like the first one. With #f as the marker all
;; three go wrong silently -- the error is stored but read back as "none", so
;; uv_stop fires with nothing to show for it and uv-run drops the error.
(define false-loop (make-uv-loop))
(define after-false (make-uv-errno-error 'EPIPE -32 "broken pipe"))

(loop-record-error! false-loop #f)

(test-equal "a callback that raised #f leaves the loop holding a pending error"
  'has-pending
  (if (loop-has-pending-error? false-loop) 'has-pending 'looks-empty))

(test-equal "the pending slot holds the #f the callback raised"
  'false-is-pending
  (if (eq? #f (loop-pending-error false-loop)) 'false-is-pending 'something-else))

(loop-record-error! false-loop after-false)

(test-equal "the error after a #f is DEFERRED, not mistaken for the first one"
  'deferred
  (let ((d (uv-loop-deferred-errors false-loop)))
    (if (and (= 1 (length d)) (eq? after-false (car d))) 'deferred 'unexpected)))

(test-equal "the #f is still the pending error, not overwritten by the second"
  'false-still-pending
  (if (eq? #f (loop-pending-error false-loop))
      'false-still-pending
      'overwritten))

(define raised-false
  (guard (e (#t e))
    (uv-run false-loop 'nowait)
    'no-raise))

(test-equal "uv-run re-raises a #f callback error instead of dropping it silently"
  'callback-error
  (if (uv-callback-error? raised-false) 'callback-error 'not-callback-error))

(test-equal "the re-raised condition's cause is the #f the callback raised"
  'cause-is-false
  (if (eq? #f (uv-callback-error-cause raised-false))
      'cause-is-false
      'cause-is-something-else))

(test-equal "the loop is usable again after a #f callback error"
  'no-work (if (uv-run false-loop 'nowait) 'work 'no-work))

;; --- uv-stop! -----------------------------------------------------------
;; uv_stop's effect is only observable from inside a running loop, which
;; needs a callback (Task 7). What is asserted here is that it is accepted on
;; an open loop and refused on a closed one (below, in the use-after-close
;; matrix).
(test-equal "uv-stop! on an open loop returns without raising"
  'stopped
  (guard (e (#t (list 'raised e)))
    (uv-stop! policy-loop)
    'stopped))

;; --- uv-loop-close! -----------------------------------------------------
(define close-loop (make-uv-loop))
(define close-loop-ptr (loop-ptr close-loop))
(define registry-count-before-close (registry-count))
(define live-loops-before-close (live-count 'loop))

(test-equal "seed: the live loop counter is non-zero before the close under test"
  #t (positive? live-loops-before-close))

(test-equal "closing an open, empty loop returns without raising"
  'first-close-ok
  (guard (e (#t (list 'raised e)))
    (uv-loop-close! close-loop)
    'first-close-ok))

(test-equal "a closed loop's state field reads 'closed"
  'closed (loop-state close-loop))

(test-equal "uv-loop-open? is false for a closed loop"
  'not-open (if (uv-loop-open? close-loop) 'open 'not-open))

;; Design spec S10: "each allocation kind is freed in exactly one place, and
;; the freeing site zeroes the stored uptr immediately". This is the
;; assertion that guards the zeroing -- the free! itself is guarded only by
;; Valgrind/ASan (make test-memory), recorded honestly in the mutation log.
(test-equal "closing zeroes the stored loop pointer"
  0 (loop-ptr close-loop))

(test-equal "closing deregisters the loop from the registry"
  -1 (- (registry-count) registry-count-before-close))

(test-equal "the registry no longer resolves the closed loop's pointer"
  'absent (if (registry-ref close-loop-ptr) 'present 'absent))

(test-equal "closing decrements the live loop counter"
  -1 (- (live-count 'loop) live-loops-before-close))

(test-equal "closing an already-closed loop is a no-op, not an error"
  'second-close-ok
  (guard (e (#t (list 'raised e)))
    (uv-loop-close! close-loop)
    'second-close-ok))

(test-equal "the second close did not move the live loop counter again"
  -1 (- (live-count 'loop) live-loops-before-close))

(test-equal "uv-loop-close! rejects a non-loop argument, naming who and why"
  '(uv-loop-close! not-a-uv-loop)
  (guard (e ((uv-invalid-argument? e)
             (list (uv-invalid-argument-who e) (uv-invalid-argument-reason e)))
            (#t 'wrong-condition))
    (uv-loop-close! 'not-a-loop)
    'no-raise))

;; --- use after close ----------------------------------------------------
;; Every public loop operation, one row each. The KIND field value is what is
;; asserted, not merely that something was raised: 'loop is the discriminant
;; a caller branches on, and 'no-raise / 'wrong-condition are sentinels no
;; success path can produce.
(define dead-loop (make-uv-loop))
(uv-loop-close! dead-loop)

(define (closed-op-kind thunk)
  (guard (e ((uv-handle-closed? e) (uv-handle-closed-kind e))
            (#t 'wrong-condition))
    (thunk)
    'no-raise))

(for-each
 (lambda (entry)
   (test-equal (string-append "use after close: " (car entry)
                              " raises &uv-handle-closed with kind 'loop")
     'loop (closed-op-kind (cdr entry))))
 (list (cons "uv-run"                  (lambda () (uv-run dead-loop 'nowait)))
       (cons "uv-stop!"                (lambda () (uv-stop! dead-loop)))
       (cons "uv-loop-alive?"          (lambda () (uv-loop-alive? dead-loop)))
       (cons "uv-now"                  (lambda () (uv-now dead-loop)))
       (cons "uv-loop-live-handles"    (lambda () (uv-loop-live-handles dead-loop)))
       (cons "uv-loop-deferred-errors" (lambda () (uv-loop-deferred-errors dead-loop)))))

;; --- uv-loop-teardown! --------------------------------------------------
;; The sweep is exercised with a REGISTERED (fake) handle rather than over an
;; empty registry: an empty sweep passes whether the sweep loop is there or
;; not. Task 7 replaces the probe with the real uv-close!.
(define td-loop (make-uv-loop))
(define td-handle (cons 31337 'fake-timer))
(define td-live-before (live-count 'loop))

(registry-register! (car td-handle) 'timer td-loop td-handle)
(set! closed-handles '())

(test-equal "seed: the fake handle is listed as a live handle of its loop"
  'listed (if (memq td-handle (uv-loop-live-handles td-loop)) 'listed 'missing))

(test-equal "uv-loop-teardown! on an open loop returns without raising"
  'torn-down
  (guard (e (#t (list 'raised e)))
    (uv-loop-teardown! td-loop)
    'torn-down))

(test-equal "teardown swept the loop's registered handles through close-handle!"
  'swept
  (if (and (= 1 (length closed-handles)) (eq? td-handle (car closed-handles)))
      'swept
      'not-swept))

(test-equal "teardown closed the loop after the sweep"
  'closed (loop-state td-loop))

(test-equal "teardown returned the live loop counter to its pre-teardown value"
  -1 (- (live-count 'loop) td-live-before))

(test-equal "teardown is idempotent on an already-torn-down loop"
  'second-teardown-ok
  (guard (e (#t (list 'raised e)))
    (uv-loop-teardown! td-loop)
    'second-teardown-ok))

;; --- call-with-uv-loop --------------------------------------------------
(define cwl-live-before (live-count 'loop))
(define cwl-seen-inside 'body-never-ran)

(define cwl-result
  (call-with-uv-loop
   (lambda (l)
     (set! cwl-seen-inside (if (uv-loop-open? l) (live-count 'loop) 'not-open))
     (uv-run l 'nowait)
     'body-value)))

(test-equal "call-with-uv-loop returns the body's value"
  'body-value cwl-result)

(test-equal "seed: the loop was open and live inside the body"
  (+ cwl-live-before 1) cwl-seen-inside)

(test-equal "call-with-uv-loop tears the loop down on a normal return"
  cwl-live-before (live-count 'loop))

(define cwl-raise-reason
  (guard (e ((uv-invalid-argument? e) (uv-invalid-argument-reason e))
            (#t 'wrong-condition))
    (call-with-uv-loop
     (lambda (l)
       (raise (make-uv-invalid-argument 'test-body 'deliberate))))
    'no-raise))

(test-equal "a raise from the body propagates out of call-with-uv-loop"
  'deliberate cwl-raise-reason)

(test-equal "the loop is torn down even when the body raises"
  cwl-live-before (live-count 'loop))

;; The re-entry guard of design spec S5 ("dynamic-wind is valid here, unlike
;; around an individual handle"), written in the shape the sibling
;; chez-cmark-gfm project's test-lifecycle uses for its own re-entry ADR --
;; this repo's ADR-0006 is about error codes being symbols and has nothing to
;; do with it. A continuation captured INSIDE the extent is invoked after the
;; extent has been left (and the loop torn down). dynamic-wind's before-thunk runs on
;; the way back in and must refuse, because the loop it would hand the body
;; is gone. `body-entries` is the sentinel: a re-entry that got past the
;; guard would run the body a second time.
(define resume-k #f)
(define body-entries 0)

(define reentry-outcome
  (call-with-current-continuation
   (lambda (done)
     (guard (e ((uv-handle-closed? e) (done (uv-handle-closed-kind e)))
               (#t (done 'wrong-condition)))
       (call-with-current-continuation
        (lambda (escape)
          (call-with-uv-loop
           (lambda (l)
             (set! body-entries (+ body-entries 1))
             (call-with-current-continuation
              (lambda (k) (set! resume-k k) (escape 'left-the-extent)))
             (done 'body-resumed-without-raising)))))
       (resume-k 'go-back-in)
       (done 'resume-returned-normally)))))

(test-equal "seed: the body ran exactly once before the escape"
  1 body-entries)

(test-equal "re-entering a torn-down call-with-uv-loop raises &uv-handle-closed with kind 'loop"
  'loop reentry-outcome)

(test-equal "the refused re-entry did not run the body a second time"
  1 body-entries)

(test-equal "the refused re-entry left no live loop behind"
  cwl-live-before (live-count 'loop))

;; --- balance ------------------------------------------------------------
;; l0, other-loop, policy-loop and false-loop are still open at this point;
;; close them and confirm the whole suite balances.
(uv-loop-close! l0)
(uv-loop-close! other-loop)
(uv-loop-close! policy-loop)
(uv-loop-close! false-loop)

(test-equal "every loop this suite created has been freed"
  0 (live-count 'loop))

(test-equal "the registry is back to its starting size"
  registry-count-at-start (registry-count))

(collect)

(test-equal "a full collection after teardown changes nothing"
  0 (live-count 'loop))

(test-end "loop")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
