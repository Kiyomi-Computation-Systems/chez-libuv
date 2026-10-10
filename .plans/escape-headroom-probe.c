/* #94 prototype for .plans/escape-headroom-probe.sps: where this thread's C
   stack is, and where it ends. Not part of the shim. */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdint.h>

/* The address of this call's own frame: within a few hundred bytes of
   the caller's foreign-call frame. */
__attribute__((noinline)) uintptr_t probe_sp(void) {
  return (uintptr_t)__builtin_frame_address(0);
}

/* The lowest usable address of this thread's stack. */
uintptr_t probe_stack_low(void) {
#if defined(__APPLE__)
  pthread_t self = pthread_self();
  return (uintptr_t)pthread_get_stackaddr_np(self) - pthread_get_stacksize_np(self);
#else
  pthread_attr_t a; void *addr = 0; size_t size = 0;
  if (pthread_getattr_np(pthread_self(), &a) != 0) return 0;
  pthread_attr_getstack(&a, &addr, &size);
  pthread_attr_destroy(&a);
  return (uintptr_t)addr;
#endif
}

uintptr_t probe_stack_size(void) {
#if defined(__APPLE__)
  return pthread_get_stacksize_np(pthread_self());
#else
  pthread_attr_t a; void *addr = 0; size_t size = 0;
  if (pthread_getattr_np(pthread_self(), &a) != 0) return 0;
  pthread_attr_getstack(&a, &addr, &size);
  pthread_attr_destroy(&a);
  return size;
#endif
}

/* Headroom with the low bound cached per thread. */
static __thread uintptr_t cached_low;
uintptr_t probe_headroom(void) {
  if (!cached_low) cached_low = probe_stack_low();
  return (uintptr_t)__builtin_frame_address(0) - cached_low;
}
