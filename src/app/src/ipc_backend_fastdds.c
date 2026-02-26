#include "ipc_backend.h"
#include "../shim/include/fastdds_ipc.h"
#include <stdlib.h>
#include <string.h>

struct ipc_handle {
    fd_ipc_handle_t* h;
};

static void to_fd(const msg_t* in, fd_msg_t* out)
{
    out->counter = in->counter;
    out->t_send_ns = in->t_send_ns;
    memset(out->text, 0, sizeof(out->text));
    strncpy(out->text, in->text, sizeof(out->text)-1);
}

static void from_fd(const fd_msg_t* in, msg_t* out)
{
    out->counter = in->counter;
    out->t_send_ns = in->t_send_ns;
    memset(out->text, 0, sizeof(out->text));
    strncpy(out->text, in->text, sizeof(out->text)-1);
}

ipc_handle_t* ipc_create(const char* name)
{
    ipc_handle_t* x = (ipc_handle_t*)calloc(1, sizeof(*x));
    if (!x) return NULL;
    x->h = fd_ipc_create(name);
    if (!x->h) { free(x); return NULL; }
    return x;
}

int ipc_send_request(ipc_handle_t* x, const msg_t* m)
{
    if (!x || !m) return -1;
    fd_msg_t fm; to_fd(m, &fm);
    return fd_ipc_send_request(x->h, &fm);
}

int ipc_send_reply(ipc_handle_t* x, const msg_t* m)
{
    if (!x || !m) return -1;
    fd_msg_t fm; to_fd(m, &fm);
    return fd_ipc_send_reply(x->h, &fm);
}

int ipc_take_request(ipc_handle_t* x, msg_t* out, int timeout_ms)
{
    if (!x || !out) return -1;
    fd_msg_t fm;
    int rc = fd_ipc_take_request(x->h, &fm, timeout_ms);
    if (rc == 1) from_fd(&fm, out);
    return rc;
}

int ipc_take_reply(ipc_handle_t* x, msg_t* out, int timeout_ms)
{
    if (!x || !out) return -1;
    fd_msg_t fm;
    int rc = fd_ipc_take_reply(x->h, &fm, timeout_ms);
    if (rc == 1) from_fd(&fm, out);
    return rc;
}

void ipc_destroy(ipc_handle_t* x)
{
    if (!x) return;
    fd_ipc_destroy(x->h);
    free(x);
}
