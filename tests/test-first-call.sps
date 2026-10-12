#!r6rs
;;; SRFI-64 suite for what rule 13 of tests/test-source-rules.sps cannot
;;; read from the source: the order. Importing (libuv) loads the shim but
;;; checks no version and reads no constant; ensure-native-loaded! does
;;; both, and every constructor calls it. A verb that takes no loop, handle
;;; or request has had nothing run before it, so it loads for itself, and
;;; must do so before its first native call: as a process's first call,
;;; uv-kill! once raised 'constants-not-initialized in place of kill(2)'s
;;; errno. A verb that takes a record must refuse anything else before it
;;; reads a constant or calls libuv.
;;;
;;; tests/first-call-child.sps makes each call in a process of its own,
;;; through child-run, and prints what it saw. Rule 13 holds
;;; first-call-verbs to the verbs it calls `loads`, and the child's sweep to
;;; the verbs it calls `record`.
;;;
;;; Not pure: the children load the shim (check-purity's poisoned
;;; CHEZ_LIBUV_SHIM reaches them).
(import (rnrs)
        (srfi :64)
        (only (uv-child) child-run child-entry)
        (only (chezscheme) getenv))

;; SRFI-64 sets no exit status; the runner's fail count drives it.
(define runner (test-runner-simple))
(test-runner-current runner)

;; The simple runner prints only a failing row's title. The rows return
;; their evidence when they fail, so print that too.
(let ((simple-end (test-runner-on-test-end runner)))
  (test-runner-on-test-end! runner
    (lambda (r)
      (simple-end r)
      (when (eq? (test-result-kind r) 'fail)
        (display "  actual: ")
        (write (test-result-ref r 'actual-value))
        (newline)))))

(test-begin "first-call")

(define chez (getenv "CHEZ_LIBUV_TEST_CHEZ"))

;; Each verb of (libuv) that takes no loop, handle or request, with the
;; child's tokens for it and what each call answers when it works.
;; uv-kill!'s sends go to a pid no system hands out: with signal 0 it reads
;; no constant before kill(2), with 'sigterm it reads one first.
(define first-call-verbs
  '((uv-kill! (kill0 . refused-as-missing) (killterm . refused-as-missing))
    (make-uv-loop (loop . a-loop))
    (call-with-uv-loop (withloop . body-ran))
    (uv-os-getpid (getpid . a-pid))
    (uv-version (version . a-string))
    (uv-version-compatible? (compatible . compatible))))

;; first-call : symbol -> (or alist list)
(define (first-call token)
  (child-run chez '() "tests/first-call-child.sps" (list token)))

;; sentinel : object -> object
;; A call's value as the child printed it, with kill(2)'s refusal of a pid
;; no process has made 'refused-as-missing: ESRCH, or EPERM if the pid were
;; another user's.
(define (sentinel value)
  (if (and (pair? value) (eq? (car value) 'errno) (pair? (cdr value))
           (memq (cadr value) '(ESRCH EPERM)))
      'refused-as-missing
      value))

;; not-a-refusal? : object -> boolean
;; Whether OUTCOME is other than an &uv-invalid-argument whose reason
;; names the record the verb wanted: not-a-uv-loop, not-a-uv-handle,
;; not-a-cancellable-request and the like.
(define (not-a-refusal? outcome)
  (not (and (pair? outcome) (eq? (car outcome) 'invalid-argument)
            (pair? (cdr outcome)) (symbol? (cadr outcome))
            (let ((s (symbol->string (cadr outcome))))
              (and (>= (string-length s) 6)
                   (string=? (substring s 0 6) "not-a-"))))))

(if (not chez)
    (test-equal "first-call rows SKIPPED: CHEZ_LIBUV_TEST_CHEZ unset (run via make test)"
      'skipped 'skipped)
    (begin
      (for-each
       (lambda (entry)
         (for-each
          (lambda (call)
            (let ((report (first-call (car call))))
              (test-equal (string-append
                           (symbol->string (car entry))
                           " as a process's first call (" (symbol->string (car call))
                           "): nothing loaded before it, its answer, and the library loaded after")
                (list 'not-loaded (cdr call) 'loaded)
                (list (child-entry report 'before)
                      (sentinel (child-entry report 'value))
                      (child-entry report 'after)))))
          (cdr entry)))
       first-call-verbs)

      (let* ((report (first-call 'records))
             (unloading (child-entry report 'unloading))
             (loading (child-entry report 'loading)))
        (test-equal "seed: the record sweep's child had nothing loaded before its first call"
          'not-loaded (child-entry report 'before))
        (test-equal "seed: the record sweep reached uv-run first and uv-async-send! last"
          '(uv-run uv-async-send!)
          (if (and (list? unloading) (pair? unloading))
              (list (car (car unloading)) (car (list-ref unloading (- (length unloading) 1))))
              unloading))
        (test-equal "every verb that takes a loop, handle or request refuses a symbol in its place by name, and loads nothing first"
          '()
          (if (list? unloading)
              (filter (lambda (row)
                        (or (not-a-refusal? (cadr row)) (not (eq? (caddr row) 'not-loaded))))
                      unloading)
              unloading))
        (test-equal "a constructor or uv-spawn! given a symbol for its loop refuses it by name"
          '()
          (if (list? loading)
              (filter (lambda (row) (not-a-refusal? (cadr row))) loading)
              loading)))))

(test-end "first-call")

(exit (if (zero? (test-runner-fail-count runner)) 0 1))
