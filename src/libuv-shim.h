/* chez-libuv constants-only shim.
 *
 * Deliberately thin (ADR-0002): no uv_* call is ever wrapped here. Its jobs
 * are version reporting, exposing values C can compute that Scheme cannot
 * obtain any other way -- struct sizes and offsets, the errno enumeration
 * built from libuv's own UV_ERRNO_MAP X-macro (ADR-0005) -- and counting
 * live allocations in debug builds.
 */
#ifndef CHEZ_LIBUV_SHIM_H
#define CHEZ_LIBUV_SHIM_H

/* A struct tag first named in a prototype's parameter-type-list has
 * prototype scope only (C99 6.2.1p7): it would not extend past that one
 * prototype to any later use in this file. Forward-declared here at file
 * scope so any future prototype naming it stays consistent with the .c
 * file's own <uv.h>-derived definition, the same discipline
 * cmark-gfm-shim.h applies to `struct cmark_node` (AGENTS.md's named
 * trap). Currently unused: none of this shim's exported entry points takes
 * a libuv struct pointer, since the shim never wraps a uv_* call.
 */
struct uv_handle_s;

/* Version the shim was COMPILED against, from the installed header
 * (UV_VERSION_HEX). */
int chez_uv_shim_compiled_version(void);

/* Name-keyed constant lookup (ADR-0005). Writes *out and returns 1 if name
 * is present in the table; returns 0 and leaves *out untouched otherwise.
 * A missing name is never a default value -- it is the caller's job to
 * raise a structured error, not this function's job to paper over. */
int chez_uv_constant(const char *name, long *out);

/* Errno enumeration, built from libuv's own UV_ERRNO_MAP X-macro so the
 * name list tracks the pinned libuv header automatically rather than being
 * copied out by hand. Names are the bare UV_ERRNO_MAP token ("EOF",
 * "ECONNRESET", ...), never prefixed with UV_. */
int chez_uv_errno_count(void);
const char *chez_uv_errno_name(int i);
int chez_uv_errno_value(int i);

/* Debug allocation counters. Compiled to no-ops unless
 * CHEZ_LIBUV_DEBUG_COUNTERS is defined; the live queries then always
 * return 0. Single-threaded test use only. */
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

#endif /* CHEZ_LIBUV_SHIM_H */
