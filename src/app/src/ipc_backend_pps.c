// src/app/src/ipc_backend_pps.c
#include "ipc_backend.h"
#include "common.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sys/stat.h>   // mkdir

// QNX PPS
#include <sys/pps.h>

#ifndef PPS_DIR
#define PPS_DIR "/pps/ipcbench"
#endif

#define REQ_PATH PPS_DIR "/req"
#define REP_PATH PPS_DIR "/rep"

// Store message as PPS key/value fields:
//   counter::123
//   t_send_ns::456
//   text::deadbeef
static int write_msg(int fd, const fd_msg_t* m)
{
    char buf[256];

    int n = snprintf(buf, sizeof(buf),
        "counter::%u\n"
        "t_send_ns::%llu\n"
        "text::%s\n",
        (unsigned)m->counter,
        (unsigned long long)m->t_send_ns,
        m->text);

    if (n <= 0 || n >= (int)sizeof(buf))
    {
        errno = EOVERFLOW;
        return -1;
    }

    if (lseek(fd, 0, SEEK_SET) < 0) return -1;
    (void)ftruncate(fd, 0);

    ssize_t wr = write(fd, buf, (size_t)n);
    return (wr == (ssize_t)n) ? 0 : -1;
}

static int parse_line(const char* s, const char* key, char* out, size_t out_sz)
{
    size_t klen = strlen(key);
    if (strncmp(s, key, klen) != 0) return 0;
    if (s[klen] != ':' || s[klen + 1] != ':') return 0;

    const char* v = s + klen + 2;
    size_t i = 0;
    while (v[i] && v[i] != '\n' && i + 1 < out_sz)
    {
        out[i] = v[i];
        i++;
    }
    out[i] = '\0';
    return 1;
}

static int read_msg(int fd, fd_msg_t* out)
{
    char buf[512];
    if (lseek(fd, 0, SEEK_SET) < 0) return -1;

    ssize_t rd = read(fd, buf, sizeof(buf) - 1);
    if (rd <= 0) return -1;
    buf[rd] = '\0';

    memset(out, 0, sizeof(*out));

    char tmp[128];
    const char* p = buf;

    while (*p)
    {
        const char* eol = strchr(p, '\n');
        size_t len = eol ? (size_t)(eol - p + 1) : strlen(p);

        char line[256];
        if (len >= sizeof(line)) len = sizeof(line) - 1;
        memcpy(line, p, len);
        line[len] = '\0';

        if (parse_line(line, "counter", tmp, sizeof(tmp)))
        {
            out->counter = (uint32_t)strtoul(tmp, NULL, 10);
        }
        else if (parse_line(line, "t_send_ns", tmp, sizeof(tmp)))
        {
            out->t_send_ns = (uint64_t)strtoull(tmp, NULL, 10);
        }
        else if (parse_line(line, "text", tmp, sizeof(tmp)))
        {
            strncpy(out->text, tmp, sizeof(out->text) - 1);
        }

        if (!eol) break;
        p = eol + 1;
    }

    return 0;
}

// IMPORTANT: matches ipc_backend.h (forward-declared struct ipc_handle)
struct ipc_handle
{
    int req_fd;
    int rep_fd;
};

ipc_handle_t* ipc_create(const char* participant_name)
{
    (void)participant_name;

    if (mkdir(PPS_DIR, 0777) < 0 && errno != EEXIST)
    {
        perror("mkdir " PPS_DIR);
        return NULL;
    }

    // Use O_RDWR so we can read + write from same handle.
    int req_fd = open(REQ_PATH, O_CREAT | O_RDWR, 0666);
    if (req_fd < 0) { perror("open " REQ_PATH); return NULL; }

    int rep_fd = open(REP_PATH, O_CREAT | O_RDWR, 0666);
    if (rep_fd < 0) { perror("open " REP_PATH); close(req_fd); return NULL; }

    ipc_handle_t* h = (ipc_handle_t*)calloc(1, sizeof(*h));
    if (!h)
    {
        close(req_fd);
        close(rep_fd);
        return NULL;
    }

    h->req_fd = req_fd;
    h->rep_fd = rep_fd;
    return h;
}

void ipc_destroy(ipc_handle_t* h)
{
    if (!h) return;
    if (h->req_fd >= 0) close(h->req_fd);
    if (h->rep_fd >= 0) close(h->rep_fd);
    free(h);
}

int ipc_send_request(ipc_handle_t* h, const fd_msg_t* m)
{
    if (!h || !m) return -1;
    return write_msg(h->req_fd, m);
}

int ipc_send_reply(ipc_handle_t* h, const fd_msg_t* m)
{
    if (!h || !m) return -1;
    return write_msg(h->rep_fd, m);
}

// Simple polling take (easy first step).
// Upgrade later to PPS event-driven notifications once basic flow works.
static int take_poll(int fd, fd_msg_t* out, int timeout_ms)
{
    const int step_ms = 5;
    int waited = 0;

    while (timeout_ms < 0 || waited <= timeout_ms)
    {
        if (read_msg(fd, out) == 0)
        {
            // Heuristic “has data”
            if (out->counter != 0 || out->t_send_ns != 0 || out->text[0] != '\0')
            {
                return 1;
            }
        }

        if (timeout_ms == 0) return 0;

        usleep(step_ms * 1000);
        waited += step_ms;
    }

    return 0;
}

int ipc_take_request(ipc_handle_t* h, fd_msg_t* out, int timeout_ms)
{
    if (!h || !out) return -1;
    return take_poll(h->req_fd, out, timeout_ms);
}

int ipc_take_reply(ipc_handle_t* h, fd_msg_t* out, int timeout_ms)
{
    if (!h || !out) return -1;
    return take_poll(h->rep_fd, out, timeout_ms);
}
