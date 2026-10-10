# Draft: upstream issue for cisco/ChezScheme

Not filed. Drafted 2026-10-09 from chez-libuv #95
(`.plans/macos-thread-overflow-log.md`). It needs the maintainer's OK
before it goes to https://github.com/cisco/ChezScheme/issues. Run on Chez
10.4.1, macOS 26.6.2 arm64 and Linux arm64. The patch below was built from
the v10.4.1 tag and run against the repro on macOS only, with the same
tree built without it as the control; Chez's own test suite was not run
on it.

---

**Title:** A fault inside a `__collect_safe` foreign call leaves the thread deactivated, and the next collection deadlocks

**Body:**

When a `__collect_safe` foreign call faults, the `SIGSEGV` handler turns
the fault into an "invalid memory reference" error (`S_error_reset` →
`do_error`), which `longjmp`s back into Scheme. The thread was deactivated
for the call, and nothing on that path reactivates it. Scheme code then
runs with `ACTIVE(tc)` = 0 and `$active-threads` one short. If a
collection is requested before the next `__collect_safe` call returns
(which reactivates it), `$collect-rendezvous` waits on `$collect-cond` for
`$active-threads` to reach 1, and never wakes: the process hangs with no
CPU use and no message. With one thread, `$active-threads` is 0.

**Repro.** No C to compile; `strlen` on address 8 is the fault.

```scheme
(import (chezscheme))
(load-shared-object (if (memq (machine-type) '(tarm64osx ta6osx)) "libc.dylib" "libc.so.6"))
(define strlen (foreign-procedure __collect_safe "strlen" (uptr) size_t))
(define keep #f)
(let loop ((i 0))
  (when (< i 1000)
    (guard (e (#t #f)) (strlen 8))
    (set! keep (make-bytevector 1000000))
    (loop (+ i 1))))
(display "finished\n")
```

It hangs on macOS arm64 and Linux arm64. Without `__collect_safe` it
prints `finished`. Reading `(#%$top-level-value '$active-threads)` in the
guard's handler shows 0, and 1 before the call.

The same happens with the fault inside a callable that a `__collect_safe`
call entered, and after a callable was left by a continuation. A real case:
a thread whose stack ran out inside a `__collect_safe` call to libuv's
`uv_run` (macOS probes large frames, so the fault comes with room for the
handler), caught the error and went on, and hung at the next collection.

**Proposed fix.** In `do_error` (c/schsig.c), after the mutex releases:

```diff
     while (S_mutex_is_owner(&S_tc_mutex) && (S_tc_mutex_depth > 0)) {
       S_tc_mutex_depth -= 1;
       S_mutex_release(&S_tc_mutex);
     }
+    if (tc != (ptr)0 && !ACTIVE(tc)) reactivate_thread(tc);
 #endif /* PTHREADS */
```

Built from the v10.4.1 tag with and without this line, everything
else equal: without it the repro hangs, and with it the repro prints
`finished`, and so do the nested and escaped variants.
