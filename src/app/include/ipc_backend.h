#pragma once
#include "common.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ipc_handle ipc_handle_t;

ipc_handle_t* ipc_create(const char* name);

int ipc_send_request(ipc_handle_t*, const msg_t*);
int ipc_send_reply  (ipc_handle_t*, const msg_t*);

// 1=got sample, 0=timeout/no data, -1=error
int ipc_take_request(ipc_handle_t*, msg_t*, int timeout_ms);
int ipc_take_reply  (ipc_handle_t*, msg_t*, int timeout_ms);

void ipc_destroy(ipc_handle_t*);

#ifdef __cplusplus
}
#endif
