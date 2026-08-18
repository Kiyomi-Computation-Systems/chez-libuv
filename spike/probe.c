/* spike/probe.c — Stage 0 throwaway probe.
 *
 * Prints every libuv/platform constant, struct size, and struct offset the
 * Stage 0 spike scripts need, so that no enum value or offsetof number is
 * ever transcribed from memory into a .ss file (ADR-0005's rule, applied to
 * the spike itself).
 *
 * Build and run:
 *   cc -I/opt/homebrew/opt/libuv/include -o spike/probe spike/probe.c \
 *      -L/opt/homebrew/opt/libuv/lib -luv
 *   ./spike/probe
 *
 * This is spike-only scaffolding. It is committed as evidence, not as a
 * component of the library; the real constants shim (ADR-0002) is Stage 1.
 */

#include <stdio.h>
#include <stddef.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <uv.h>

#define P_INT(name)   printf("%-34s %d\n",  #name, (int)(name))
#define P_HEX(name)   printf("%-34s 0x%06X\n", #name, (unsigned)(name))
#define P_SIZE(name)  printf("%-34s %zu\n", #name, (size_t)(name))

int main(void) {
  printf("== versions ==\n");
  P_HEX(UV_VERSION_HEX);
  P_INT(UV_VERSION_MAJOR);
  P_INT(UV_VERSION_MINOR);
  P_INT(UV_VERSION_PATCH);
  P_HEX(uv_version());
  printf("%-34s %s\n", "uv_version_string()", uv_version_string());

  printf("\n== uv_handle_type enum values ==\n");
  P_INT(UV_UNKNOWN_HANDLE);
  P_INT(UV_ASYNC);
  P_INT(UV_TCP);
  P_INT(UV_TIMER);
  P_INT(UV_HANDLE_TYPE_MAX);

  printf("\n== uv_req_type enum values ==\n");
  P_INT(UV_UNKNOWN_REQ);
  P_INT(UV_REQ);
  P_INT(UV_CONNECT);
  P_INT(UV_WRITE);
  P_INT(UV_SHUTDOWN);
  P_INT(UV_REQ_TYPE_MAX);

  printf("\n== uv_run_mode enum values ==\n");
  P_INT(UV_RUN_DEFAULT);
  P_INT(UV_RUN_ONCE);
  P_INT(UV_RUN_NOWAIT);

  printf("\n== errno constants used by the spike ==\n");
  P_INT(UV_EOF);
  P_INT(UV_ECANCELED);
  P_INT(UV_EAGAIN);

  printf("\n== runtime sizes (libuv accessors) ==\n");
  P_SIZE(uv_loop_size());
  P_SIZE(uv_handle_size(UV_TCP));
  P_SIZE(uv_handle_size(UV_TIMER));
  P_SIZE(uv_req_size(UV_CONNECT));
  P_SIZE(uv_req_size(UV_WRITE));
  P_SIZE(uv_req_size(UV_SHUTDOWN));

  printf("\n== compile-time sizes ==\n");
  P_SIZE(sizeof(uv_loop_t));
  P_SIZE(sizeof(uv_tcp_t));
  P_SIZE(sizeof(uv_timer_t));
  P_SIZE(sizeof(uv_connect_t));
  P_SIZE(sizeof(uv_write_t));
  P_SIZE(sizeof(uv_buf_t));
  P_SIZE(sizeof(struct sockaddr));
  P_SIZE(sizeof(struct sockaddr_in));
  P_SIZE(sizeof(struct sockaddr_storage));
  P_SIZE(sizeof(size_t));
  P_SIZE(sizeof(ssize_t));
  P_SIZE(sizeof(int));
  P_SIZE(sizeof(void *));

  printf("\n== uv_buf_t layout ==\n");
  P_SIZE(offsetof(uv_buf_t, base));
  P_SIZE(sizeof(((uv_buf_t *)0)->base));
  P_SIZE(offsetof(uv_buf_t, len));
  P_SIZE(sizeof(((uv_buf_t *)0)->len));

  printf("\n== struct sockaddr_in layout ==\n");
  P_SIZE(offsetof(struct sockaddr_in, sin_family));
  P_SIZE(sizeof(((struct sockaddr_in *)0)->sin_family));
  P_SIZE(offsetof(struct sockaddr_in, sin_port));
  P_SIZE(sizeof(((struct sockaddr_in *)0)->sin_port));
  P_SIZE(offsetof(struct sockaddr_in, sin_addr));
  P_SIZE(sizeof(((struct sockaddr_in *)0)->sin_addr));
  P_INT(AF_INET);

  printf("\n== uv_handle_t common-field layout (for uv_handle_get_type) ==\n");
  P_SIZE(offsetof(uv_handle_t, data));
  P_SIZE(offsetof(uv_handle_t, loop));
  P_SIZE(offsetof(uv_handle_t, type));
  P_SIZE(sizeof(((uv_handle_t *)0)->type));

  return 0;
}
