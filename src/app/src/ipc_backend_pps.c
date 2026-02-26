#include "ipc_backend.h"

#if !defined(__QNXNTO__)
#error "PPS backend is QNX-only"
#endif

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PPS_REQ "/pps/ipcbench/request"
#define PPS_REP "/pps/ipcbench/reply"

struct ipc_handle {
    int req_rd;  // receiver reads requests; sender can ignore
    int req_wr;  // sender writes requests; receiver can ignore
    int rep_rd;  // sender reads replies; receiver can ignore
    int rep_wr;  // receiver writes replies; sender can ignore
};

static int open_rd(const char* path)
{
    int fd = open(path, O_RDONLY);
    return fd;
}

static int open_wr(const char* path)
{
    // PPS objects can be created by opening for write with O_CREAT
    int fd = open(path, O_WRONLY | O_CREAT, 0666);
    return fd;
}

static int poll_readable(int fd, int timeout_ms)
{
    struct pollfd pfd;
    memset(&pfd, 0, sizeof(pfd));
    pfd.fd = fd;
    pfd.events = POLLIN;
    int rc = poll(&pfd, 1, timeout_ms);
    if (rc == 0) return 0;
    if (rc < 0) return -1;
    return (pfd.revents & POLLIN) ? 1 : -1;
}

static int read_all(int fd, char* buf, size_t cap)
{
    // PPS reads are typically non-blocking by default; poll first.
    // Read until EOF-ish for this update.
    ssize_t n = read(fd, buf, cap - 1);
    if (n < 0) return -1;
    buf[n] = 0;
    return (int)n;
}

static void parse_kv(const char* text, msg_t* out)
{
    // Expected lines:
    // counter::123
    // t_send_ns::...
    // text::deadbeef
    // Very small/simple parser.
    out->counter = 0;
    out->t_send_ns = 0;
    memset(out->text, 0, sizeof(out->text));

    const char* p = text;
    while (*p)
    {
        const char* eol = strchr(p, '\n');
        size_t len = eol ? (size_t)(eol - p) : strlen(p);

        if (len > 0)
        {
            if (strncmp(p, "counter::", 9) == 0)
            {
                out->counter = (uint32_t)strtoul(p + 9, NULL, 10);
            }
            else if (strncmp(p, "t_send_ns::", 11) == 0)
            {
                out->t_send_ns = (uint64_t)strtoull(p + 11, NULL, 10);
            }
            else if (strncmp(p, "text::", 6) == 0)
            {
                size_t copy = len - 6;
                if (copy > 63) copy = 63;
                memcpy(out->text, p + 6, copy);
                out->text[copy] = 0;
            }
        }

        if (!eol) break;
        p = eol + 1;
    }
}

static int write_msg(int fd, const msg_t* m)
{
    char buf[256];
    int n = snprintf(buf, sizeof(buf),
                     "counter::%u\n"
                     "t_send_ns::%llu\n"
                     "text::%s\n",
                     m->counter,
                     (unsigned long long)m->t_send_ns,
                     m->text);
    if (n <= 0) return -1;
    ssize_t wr = write(fd, buf, (size_t)n);
    return (wr == (ssize_t)n) ? 0 : -1;
}

ipc_handle_t* ipc_create(const char* name)
{
    (void)name;

    ipc_handle_t* h = (ipc_handle_t*)calloc(1, sizeof(*h));
    if (!h) return NULL;

    // Open everything; unused fds remain -1
    h->req_rd = -1; h->req_wr = -1; h->rep_rd = -1; h->rep_wr = -1;

    // We’ll open both directions so sender/receiver can share binary.
    h->req_wr = open_wr(PPS_REQ);
    h->rep_wr = open_wr(PPS_REP);
    h->req_rd = open_rd(PPS_REQ);
    h->rep_rd = open_rd(PPS_REP);

    if (h->req_wr < 0 || h->rep_wr < 0 || h->req_rd < 0 || h->rep_rd < 0)
    {
        ipc_destroy(h);
        return NULL;
    }
    return h;
}

int ipc_send_request(ipc_handle_t* h, const msg_t* m)
{
    if (!h || !m) return -1;
    return write_msg(h->req_wr, m);
}

int ipc_send_reply(ipc_handle_t* h, const msg_t* m)
{
    if (!h || !m) return -1;
    return write_msg(h->rep_wr, m);
}

int ipc_take_request(ipc_handle_t* h, msg_t* out, int timeout_ms)
{
    if (!h || !out) return -1;

    int pr = poll_readable(h->req_rd, timeout_ms);
    if (pr <= 0) return pr; // 0 timeout, -1 error

    char buf[512];
    int n = read_all(h->req_rd, buf, sizeof(buf));
    if (n < 0) return -1;

    parse_kv(buf, out);
    return 1;
}

int ipc_take_reply(ipc_handle_t* h, msg_t* out, int timeout_ms)
{
    if (!h || !out) return -1;

    int pr = poll_readable(h->rep_rd, timeout_ms);
    if (pr <= 0) return pr;

    char buf[512];
    int n = read_all(h->rep_rd, buf, sizeof(buf));
    if (n < 0) return -1;

    parse_kv(buf, out);
    return 1;
}

void ipc_destroy(ipc_handle_t* h)
{
    if (!h) return;
    if (h->req_rd >= 0) close(h->req_rd);
    if (h->req_wr >= 0) close(h->req_wr);
    if (h->rep_rd >= 0) close(h->rep_rd);
    if (h->rep_wr >= 0) close(h->rep_wr);
    free(h);
}
