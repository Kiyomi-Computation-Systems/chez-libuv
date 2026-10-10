/* Thin ABI shim for compiler-derived constants, layouts, errnos, optional
 * allocation counters, bulk byte moves, libuv's alloc callback for reads,
 * and where the calling thread's stack is. It does not wrap uv_*
 * operations. */
#ifndef CHEZ_LIBUV_SHIM_H
#define CHEZ_LIBUV_SHIM_H

#include <stddef.h>
#include <stdint.h>

/* A struct tag introduced only in a prototype has prototype scope. */
struct uv_handle_s;
struct uv_buf_t;

/* Version from the header used to compile the shim. */
int chez_uv_shim_compiled_version(void);

/* Writes *out and returns 1 when found; otherwise returns 0 without writing. */
int chez_uv_constant(const char *name, long *out);

/* Errno names are bare UV_ERRNO_MAP tokens such as "ECONNRESET". */
int chez_uv_errno_count(void);
const char *chez_uv_errno_name(int i);
int chez_uv_errno_value(int i);

/* Bulk byte moves for copy-at-the-boundary (ADR-0009; ADR-0002 as amended for
 * issue #35): one memcpy or memset where Scheme can only move a byte at a
 * time. The Scheme callers check types and signs, and copy-in!'s span against
 * its bytevector; a foreign extent cannot be checked, so each caller passes a
 * live block of at least len bytes. These trust all of it. An unsigned char
 * pointer here is a bytevector's own storage. */
void chez_uv_copy_in(void *dst, const unsigned char *src, size_t start,
                     size_t len);
void chez_uv_copy_out(unsigned char *dst, const void *src, size_t len);
void chez_uv_zero(void *dst, size_t len);

/* libuv's alloc callback for every read (ADR-0002 as amended for issue #45),
 * which uv_read_start is given in place of a Scheme trampoline. A stream's
 * data field points at a uv_buf_t descriptor in its handle block, and the
 * answer is a copy of that descriptor, whatever libuv suggests: the read
 * buffer once one is installed, the empty buffer before. With data NULL the
 * answer is the empty buffer too. libuv reports an empty buffer to the read
 * callback as UV_ENOBUFS. It calls nothing, in libuv or in Scheme. */
void chez_uv_alloc_cb(struct uv_handle_s *handle, size_t suggested_size,
                      struct uv_buf_t *buf);

/* The calling thread's C stack (ADR-0002 as amended for issue #94): where
 * this call's frame is, and the stack's lowest address, 0 where the system
 * gives no way to read it. Every uv_run the binding makes first measures
 * the distance between the two, and is refused below a floor, because each
 * continuation that escapes a callback leaves its uv_run's frames on the
 * stack for the thread's life. Scheme keeps each thread's bottom, so the
 * shim keeps no state. Neither calls anything in libuv or in Scheme. */
uintptr_t chez_uv_stack_pointer(void);
uintptr_t chez_uv_stack_bottom(void);

/* The binding's own foreign blocks: handles, requests, read buffers and
 * scratch. chez_uv_alloc answers n zeroed bytes, or NULL when the allocator
 * refuses; it never aborts. Neither call can fail in Scheme for a size or an
 * address in range, so a verb may make them inside an interrupt-free step,
 * where nothing may raise (stream.sls). Every block from chez_uv_alloc goes
 * back through chez_uv_free, so the debug build counts the blocks alive. */
void *chez_uv_alloc(size_t n);
void chez_uv_free(void *p);

/* Counters are diagnostics that every loop's thread may update at once, so
 * each update is atomic (count_add in libuv-shim.c). Without
 * CHEZ_LIBUV_DEBUG_COUNTERS, updates are no-ops and live queries return
 * zero. */
void chez_uv_count_loop_new(void);
void chez_uv_count_loop_free(void);
long chez_uv_live_loop(void);

void chez_uv_count_tcp_new(void);
void chez_uv_count_tcp_free(void);
long chez_uv_live_tcp(void);

void chez_uv_count_timer_new(void);
void chez_uv_count_timer_free(void);
long chez_uv_live_timer(void);

void chez_uv_count_write_req_new(void);
void chez_uv_count_write_req_free(void);
long chez_uv_live_write_req(void);

void chez_uv_count_connect_req_new(void);
void chez_uv_count_connect_req_free(void);
long chez_uv_live_connect_req(void);

void chez_uv_count_getaddrinfo_req_new(void);
void chez_uv_count_getaddrinfo_req_free(void);
long chez_uv_live_getaddrinfo_req(void);

void chez_uv_count_getnameinfo_req_new(void);
void chez_uv_count_getnameinfo_req_free(void);
long chez_uv_live_getnameinfo_req(void);

void chez_uv_count_read_buffer_new(void);
void chez_uv_count_read_buffer_free(void);
long chez_uv_live_read_buffer(void);

void chez_uv_count_pipe_new(void);
void chez_uv_count_pipe_free(void);
long chez_uv_live_pipe(void);

void chez_uv_count_process_new(void);
void chez_uv_count_process_free(void);
long chez_uv_live_process(void);

void chez_uv_count_spawn_options_new(void);
void chez_uv_count_spawn_options_free(void);
long chez_uv_live_spawn_options(void);

void chez_uv_count_signal_new(void);
void chez_uv_count_signal_free(void);
long chez_uv_live_signal(void);

void chez_uv_count_async_new(void);
void chez_uv_count_async_free(void);
long chez_uv_live_async(void);

/* Counted by chez_uv_alloc and chez_uv_free themselves, not by a pair of
 * count entries. */
long chez_uv_live_block(void);

#endif /* CHEZ_LIBUV_SHIM_H */
