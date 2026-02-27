#pragma once

#include <stdint.h>
#include "common.h"   // fd_msg_t

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fd_ipc_handle fd_ipc_handle_t;

fd_ipc_handle_t* fd_ipc_create(const char* participant_name);
void             fd_ipc_destroy(fd_ipc_handle_t*);

int fd_ipc_send_request(fd_ipc_handle_t*, const fd_msg_t*);
int fd_ipc_send_reply  (fd_ipc_handle_t*, const fd_msg_t*);

int fd_ipc_take_request(fd_ipc_handle_t*, fd_msg_t*, int timeout_ms);
int fd_ipc_take_reply  (fd_ipc_handle_t*, fd_msg_t*, int timeout_ms);

#ifdef __cplusplus
}
#endif
