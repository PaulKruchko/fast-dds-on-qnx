#include "ipc_backend.h"
#include "common.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

static void make_payload(fd_msg_t* m, uint32_t c)
{
    memset(m, 0, sizeof(*m));
    m->counter = c;
    m->t_send_ns = now_monotonic_ns();
    // default payload
    strncpy(m->text, "deadbeef", sizeof(m->text) - 1);
}

int main(int argc, char** argv)
{
    const char* name = (argc > 1) ? argv[1] : "sender";

    ipc_handle_t* h = ipc_create(name);
    if (!h)
    {
        perror("ipc_create");
        return 1;
    }

    fd_msg_t req, rep;
    uint32_t c = 0;

    // Warm-up
    for (int i = 0; i < 5; ++i)
    {
        make_payload(&req, ++c);
        if (ipc_send_request(h, &req) != 0)
        {
            puts("send failed");
            ipc_destroy(h);
            return 1;
        }
        (void)ipc_take_reply(h, &rep, 2000);
    }

    // Timed loop
    for (int i = 0; i < 1000; ++i)
    {
        make_payload(&req, ++c);

        const uint64_t t0 = req.t_send_ns;
        if (ipc_send_request(h, &req) != 0)
        {
            puts("send failed");
            break;
        }

        int rc = ipc_take_reply(h, &rep, 2000);
        const uint64_t t1 = now_monotonic_ns();

        if (rc > 0)
        {
            const uint64_t rtt = (t1 - t0);
            printf("i=%d counter=%" PRIu32 " rtt_ns=%" PRIu64 " text='%s'\n",
                   i, rep.counter, rtt, rep.text);
        }
        else if (rc == 0)
        {
            printf("i=%d timeout\n", i);
        }
        else
        {
            printf("i=%d error\n", i);
        }
    }

    ipc_destroy(h);
    return 0;
}
