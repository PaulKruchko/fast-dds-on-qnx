#include "ipc_backend.h"
#include <stdio.h>
#include <string.h>

static void flip_halves(char* s)
{
    size_t n = strlen(s);
    if (n < 2) return;
    size_t half = n / 2;

    char tmp[64] = {0};
    strncpy(tmp, s + half, sizeof(tmp) - 1);
    strncat(tmp, s, half);
    strncpy(s, tmp, 63);
    s[63] = 0;
}

int main(void)
{
    ipc_handle_t* h = ipc_create("receiver");
    if (!h) { puts("ipc_create failed"); return 1; }

    msg_t req, rep;
    for (;;)
    {
        int rc = ipc_take_request(h, &req, 2000);
        if (rc == 1)
        {
            // ACK receipt
            // (keep prints minimal if benchmarking heavily)
            // printf("[RECEIVER] ACK counter=%u text=%s\n", req.counter, req.text);

            rep = req;
            rep.counter = req.counter + 1;
            flip_halves(rep.text);

            // preserve original sender timestamp so sender can compute RTT
            if (ipc_send_reply(h, &rep) != 0)
            {
                puts("reply send failed");
                break;
            }
        }
        else if (rc == 0)
        {
            // timeout/no data
        }
        else
        {
            puts("take error");
            break;
        }
    }

    ipc_destroy(h);
    return 0;
}
