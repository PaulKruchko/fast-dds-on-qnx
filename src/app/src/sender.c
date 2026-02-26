#include "ipc_backend.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void make_payload(msg_t* m, uint32_t c)
{
    m->counter = c;
    m->t_send_ns = now_monotonic_ns();
    memset(m->text, 0, sizeof(m->text));
    strcpy(m->text, "deadbeef");
}

int main(int argc, char** argv)
{
    (void)argc; (void)argv;

    ipc_handle_t* h = ipc_create("sender");
    if (!h) { puts("ipc_create failed"); return 1; }

    // CSV header
    puts("iter,counter,rtt_ns,oneway_ns_est,wall_ns,cpu_ns,cpu_pct");

    const int warmup = 100;
    const int iters  = 2000;

    uint64_t wall0 = now_monotonic_ns();
    uint64_t cpu0  = cpu_time_ns();

    msg_t req, rep;
    uint32_t c = 0;

    // warmup (don’t record)
    for (int i = 0; i < warmup; ++i)
    {
        make_payload(&req, ++c);
        if (ipc_send_request(h, &req) != 0) { puts("send failed"); goto out; }
        (void)ipc_take_reply(h, &rep, 2000);
        usleep(1000);
    }

    // measure
    for (int i = 0; i < iters; ++i)
    {
        make_payload(&req, ++c);
        uint64_t t0 = req.t_send_ns;

        if (ipc_send_request(h, &req) != 0) { puts("send failed"); break; }

        int rc = ipc_take_reply(h, &rep, 2000);
        uint64_t t2 = now_monotonic_ns();

        if (rc != 1)
        {
            fprintf(stderr, "timeout/error at iter %d rc=%d\n", i, rc);
            continue;
        }

        uint64_t rtt = t2 - t0;
        uint64_t oneway = rtt / 2;

        uint64_t wall_now = t2 - wall0;
        uint64_t cpu_now  = cpu_time_ns() - cpu0;
        double cpu_pct = (wall_now > 0) ? (100.0 * (double)cpu_now / (double)wall_now) : 0.0;

        printf("%d,%u,%llu,%llu,%llu,%llu,%.3f\n",
               i, rep.counter,
               (unsigned long long)rtt,
               (unsigned long long)oneway,
               (unsigned long long)wall_now,
               (unsigned long long)cpu_now,
               cpu_pct);

        usleep(1000); // throttle a bit (adjust as needed)
    }

out:
    ipc_destroy(h);
    return 0;
}

