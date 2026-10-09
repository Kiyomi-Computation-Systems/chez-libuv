# Draft: upstream issue for cisco/ChezScheme

Not filed. Drafted 2026-10-09 from chez-libuv #94's measurements
(`.plans/escape-costs-mutation-log.md`). It needs the maintainer's OK
before it goes to https://github.com/cisco/ChezScheme/issues. The repro and
every number below were run on Chez 10.4.1, x86-64 Linux, glibc 2.41,
Valgrind 3.27.0. The proposed patch has **not** been built or tested.

---

**Title:** `S_call_help`'s normal return never frees the `jmp_buf`s of the C contexts it discards

**Body:**

When a callable returns to a C context that is not the newest in
`CCHAIN` (an older one, because newer callables were left by a continuation
or an engine), the newer contexts are dropped from the chain but their
`jmp_buf`s are never freed, and the code objects locked for them are never
unlocked.

`c/schlib.c`, `S_call_help`, the normal-return case:

```c
case 1: { /* normal return */
    ptr yp = FRAME(tc, 1);
    CCHAIN(tc) = yp;
    {
      /* unlock code objects that we're escaping past */
      ptr xp;
      for (xp = CCHAIN(tc); ; xp = Scdr(xp)) {
        ptr p = CDAR(xp);
        S_mobilize_object(Scar(p));
        if (Scdr(p) != Sfalse) S_mobilize_object(Scdr(p));
        if (xp == yp) break;
        FREEJMPBUF(TO_VOIDP(CAAR(xp)));
      }
    }
    FREEJMPBUF(TO_VOIDP(CAAR(yp)));
    CCHAIN(tc) = Scdr(yp);
    break;
}
```

`CCHAIN(tc) = yp` runs before the walk, so the walk starts at `yp` and
stops on its first step. The comment says the walk is meant to cover the
contexts "we're escaping past", and `S_return`'s comment says the same:
"return handling at setjmp will release frames not in the `yp` sublist".
`S_return` leaves `CCHAIN` whole before its `longjmp`, so removing the early
assignment looks like enough:

```diff
         case 1: { /* normal return */
             ptr yp = FRAME(tc, 1);
-            CCHAIN(tc) = yp;
             {
```

**Repro.** No C to compile. libc's `qsort` is the C caller, and its
comparator is a `foreign-callable`:

```scheme
(load-shared-object "libc.so.6")
(define qsort (foreign-procedure "qsort" (uptr size_t size_t uptr) void))
(define (call-from-c proc)
  ;; qsort on two ints calls the comparator once
  (let ((code (foreign-callable (lambda (a b) (proc) 0) (uptr uptr) int))
        (buf (foreign-alloc 8)))
    (lock-object code)
    (qsort buf 2 4 (foreign-callable-entry-point code))
    (foreign-free buf)
    (unlock-object code)
    'returned))
(define (stop-inside-c)
  ((make-engine (lambda () (call-from-c engine-block)))
   1000 (lambda (fuel v) (error 'repro "no stop")) (lambda (k) k)))
(define (resume k)
  (guard (e (#t (if (message-condition? e) (condition-message e) e)))
    (k 1000000 (lambda (fuel v) v) (lambda (k2) 'stopped-again))))
(define (escape-from-c)
  (call/cc (lambda (k) (call-from-c (lambda () (k 'escaped))))))
(case (string->symbol (car (command-line-arguments)))
  ((leak)
   (let ((a (stop-inside-c)))
     (escape-from-c) (escape-from-c) (escape-from-c)
     (printf "resume a: ~s\n" (resume a))))
  ((control)
   (printf "resume a: ~s\n" (resume (stop-inside-c))))
  ((escapes)
   (escape-from-c) (escape-from-c) (escape-from-c))
  ((order)
   (let* ((a (stop-inside-c)) (b (stop-inside-c)))
     (printf "resume a: ~s\n" (resume a))
     (printf "resume b: ~s\n" (resume b)))))
```

Run as `scheme --script repro.ss MODE` under
`valgrind --leak-check=full --show-leak-kinds=all`, and count the 200 B
blocks allocated by `malloc` from `S_call_help` still in use at exit:

| Mode | What it does | Blocks |
|---|---|---|
| `control` | an engine stops inside a comparator and is resumed | 0 |
| `escapes` | three continuations escape three comparators | 3 |
| `leak` | an engine stops inside a comparator, three continuations escape three others, then the engine is resumed | 3 |
| `order` | two engines stop inside comparators; the earlier is resumed first | 1 |

`escapes` is expected: those contexts are still in the chain. In `leak`
the engine's return drops all three from the chain, and the stack under
them is reused, but their blocks stay allocated. With the patch, `leak`
should show 0 and `order` 0. The patch is untested.

The stack does come back. In chez-libuv, 24,000 escapes overflowed an 8 MB
stack. The same 40,000 escapes, run in batches of 1,000 above an engine
resumed after each batch, never needed more than one batch's stack.

**A related question, not a bug report.** Each continuation that escapes a
callable leaves its C frames on the thread's stack until an older context
returns. That is about 400 B a time for a libuv run, so a thread that does
it as a habit overflows its stack: at 16,000-24,000 escapes on an 8 MB
stack on Linux. On macOS, a `fork-thread` thread hung at about 2,000, with
no message. Is there a supported way to have a callable reset the C stack
on such an escape? Or is "return from callables; escape only on a thread
you can end" the intended contract? Either way, a sentence in CSUG's
section on continuations and foreign calls would help.

`order` also prints `attempt to return to stale foreign context` for the
second resume. That is `S_return`'s check working as designed, so it is
context here, not part of the report.
