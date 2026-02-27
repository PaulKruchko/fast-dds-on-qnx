#include "ipc_backend.h"
#include "common.h"

#include <stdio.h>
#include <string.h>

static void flip_halves(char s[64])
{
    // Example: "deadbeef" -> "beefdead"
    const size_t n = strnlen(s, 63);
    if (n < 2) return;

    size_t half = (n == 8) ? 4 : (n / 2);

    char tmp[64] = {0};
    memcpy(tmp, s + half, n - half);
    memcpy(tmp + (n - half), s, half);
    tmp[n] = '\0';

    memset(s, 0, 64);
    strncpy(s, tmp, 63);
}

int main(int argc, char** argv)
{
    const char* name = (argc > 1) ? argv[1] : "receiver";

    ipc_handle_t* h = ipc_create(name);
    if (!h)
    {
        perror("ipc_create");
        return 1;
    }

    fd_msg_t req, rep;
    memset(&req, 0, sizeof(req));
    memset(&rep, 0, sizeof(rep));

    while (1)
    {
        int rc = ipc_take_request(h, &req, 2000);
        if (rc > 0)
        {
            rep = req;
            rep.counter = req.counter + 1;
            flip_halves(rep.text);

            if (ipc_send_reply(h, &rep) != 0)
            {
                puts("send reply failed");
            }
        }
        else if (rc == 0)
        {
            continue; // timeout
        }
        else
        {
            puts("take request error");
            break;
        }
    }

    ipc_destroy(h);
    return 0;
}
