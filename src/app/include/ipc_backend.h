#pragma once

#include "common.h"   // defines fd_msg_t

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ipc_handle ipc_handle_t;

ipc_handle_t* ipc_create(const char* participant_name);
void          ipc_destroy(ipc_handle_t*);

int ipc_send_request(ipc_handle_t*, const fd_msg_t*);
int ipc_send_reply  (ipc_handle_t*, const fd_msg_t*);

int ipc_take_request(ipc_handle_t*, fd_msg_t*, int timeout_ms);
int ipc_take_reply  (ipc_handle_t*, fd_msg_t*, int timeout_ms);

#ifdef __cplusplus
}
#endif
