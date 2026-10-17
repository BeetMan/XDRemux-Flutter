#ifndef XDREMUX_TRANSFER_H
#define XDREMUX_TRANSFER_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ABI 1.0; status: 0 ok, 1 invalid input, 2 invalid handle, 3 busy,
 * 4 closed, 5 output too small, 6 internal error. Input JSON is UTF-8,
 * length-delimited (no NUL required). Caller owns readable input and writable,
 * aligned out pointers for the duration of the call. They must not overlap.
 * All payload I/O is performed by the background runtime. */
uint32_t xdremux_transfer_abi_version(void);
int32_t xdremux_transfer_create(const uint8_t *json, size_t len, uint64_t *handle);
int32_t xdremux_transfer_submit(uint64_t handle, const uint8_t *json, size_t len, uint64_t *operation);
int32_t xdremux_transfer_poll(uint64_t handle, uint32_t max_events, uint32_t max_bytes, char **json);
int32_t xdremux_transfer_stop(uint64_t handle);
int32_t xdremux_transfer_release(uint64_t handle);
int32_t xdremux_transfer_free_string(char *json);
#ifdef __cplusplus
}
#endif
#endif
