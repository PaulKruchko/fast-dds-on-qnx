#include "ipc_backend.h"
#include "fastdds_ipc.h"
#include <stdlib.h>
#include <string.h>

struct ipc_handle
{
    fd_ipc_handle_t* h;
};

static inline void to_fd(const fd_msg_t* in, fd_msg_t* out)
{
    // same type, but keep as a helper in case we later add app-only fields
    *out = *in;
    out->text[sizeof(out->text) - 1] = '\0';
}

static inline void from_fd(const fd_msg_t* in, fd_msg_t* out)
{
    *out = *in;
    out->text[sizeof(out->text) - 1] = '\0';
}

ipc_handle_t* ipc_create(const char* participant_name)
{
    ipc_handle_t* x = (ipc_handle_t*)calloc(1, sizeof(*x));
    if (!x) return NULL;

    x->h = fd_ipc_create(participant_name);
    if (!x->h)
    {
        free(x);
        return NULL;
    }
    return x;
}

void ipc_destroy(ipc_handle_t* x)
{
    if (!x) return;
    if (x->h) fd_ipc_destroy(x->h);
    free(x);
}

int ipc_send_request(ipc_handle_t* x, const fd_msg_t* m)
{
    if (!x || !x->h || !m) return -1;
    fd_msg_t tmp;
    to_fd(m, &tmp);
    return fd_ipc_send_request(x->h, &tmp);
}

int ipc_send_reply(ipc_handle_t* x, const fd_msg_t* m)
{
    if (!x || !x->h || !m) return -1;
    fd_msg_t tmp;
    to_fd(m, &tmp);
    return fd_ipc_send_reply(x->h, &tmp);
}

int ipc_take_request(ipc_handle_t* x, fd_msg_t* out, int timeout_ms)
{
    if (!x || !x->h || !out) return -1;
    fd_msg_t tmp;
    int rc = fd_ipc_take_request(x->h, &tmp, timeout_ms);
    if (rc > 0) from_fd(&tmp, out);
    return rc;
}

int ipc_take_reply(ipc_handle_t* x, fd_msg_t* out, int timeout_ms)
{
    if (!x || !x->h || !out) return -1;
    fd_msg_t tmp;
    int rc = fd_ipc_take_reply(x->h, &tmp, timeout_ms);
    if (rc > 0) from_fd(&tmp, out);
    return rc;
}
