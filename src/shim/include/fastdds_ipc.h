#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fd_ipc_handle fd_ipc_handle_t;

typedef struct {
    uint32_t counter;
    char text[64];
} fd_msg_t;

fd_ipc_handle_t* fd_ipc_create(const char* participant_name);

int fd_ipc_send_request(fd_ipc_handle_t* h, const fd_msg_t* msg);
int fd_ipc_send_reply  (fd_ipc_handle_t* h, const fd_msg_t* msg);

// Return values for take_*:
//  1 = got a sample
//  0 = timeout / no data
// -1 = error
int fd_ipc_take_request(fd_ipc_handle_t* h, fd_msg_t* out, int timeout_ms);
int fd_ipc_take_reply  (fd_ipc_handle_t* h, fd_msg_t* out, int timeout_ms);

void fd_ipc_destroy(fd_ipc_handle_t* h);

#ifdef __cplusplus
}
#endif
