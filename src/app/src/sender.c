#include "ipc_backend.h"
#include "common.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static inline double ns_to_ms(uint64_t ns)
{
    return (double)ns / 1000000.0;
}

static void make_payload(fd_msg_t* m, uint32_t c)
{
    memset(m, 0, sizeof(*m));
    m->counter = c;
    m->t_send_ns = now_monotonic_ns();
    strncpy(m->text, "deadbeef", sizeof(m->text) - 1);
}

static const char* env_or(const char* k, const char* dflt)
{
    const char* v = getenv(k);
    return (v && *v) ? v : dflt;
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

    // Keep backend label consistent between Fast-DDS and PPS runs.
    // Your run scripts set IPCBENCH_BACKEND=fastdds or IPCBENCH_BACKEND=pps
    const char* backend = env_or("IPCBENCH_BACKEND", "unknown");

    // CSV header (verbose names + ms units)
    // NOTE: no commas in quoted strings; we quote text to be safe.
    printf("backend,role,iteration number,counter,request time send [ms],reply time receive [ms],round trip time [ms],process cpu time [ms],result,text\n");

    fd_msg_t req, rep;
    uint32_t c = 0;

    // Warm-up (not emitted as CSV rows)
    for (int i = 0; i < 5; ++i)
    {
        make_payload(&req, ++c);
        if (ipc_send_request(h, &req) != 0)
        {
            fprintf(stderr, "send failed during warm-up\n");
            ipc_destroy(h);
            return 1;
        }
        (void)ipc_take_reply(h, &rep, 2000);
    }

    // Timed loop
    for (int i = 0; i < 1000; ++i)
    {
        make_payload(&req, ++c);

        const uint64_t t0_ns = req.t_send_ns;
        const uint64_t cpu0_ns = cpu_time_ns();

        int send_rc = ipc_send_request(h, &req);
        if (send_rc != 0)
        {
            // Emit a CSV row marking failure
            printf("%s,%s,%d,%" PRIu32 ",%.6f,%.6f,%.6f,%.6f,%s,\"%s\"\n",
                   backend, "sender", i, req.counter,
                   ns_to_ms(t0_ns), 0.0, 0.0, 0.0,
                   "send_error", req.text);
            break;
        }

        int rc = ipc_take_reply(h, &rep, 2000);
        const uint64_t t1_ns = now_monotonic_ns();
        const uint64_t cpu1_ns = cpu_time_ns();

        const double t0_ms = ns_to_ms(t0_ns);
        const double t1_ms = ns_to_ms(t1_ns);
        const double rtt_ms = ns_to_ms((t1_ns > t0_ns) ? (t1_ns - t0_ns) : 0);
        const double cpu_ms = ns_to_ms((cpu1_ns > cpu0_ns) ? (cpu1_ns - cpu0_ns) : 0);

        if (rc > 0)
        {
            // Success
            printf("%s,%s,%d,%" PRIu32 ",%.6f,%.6f,%.6f,%.6f,%s,\"%s\"\n",
                   backend, "sender", i, rep.counter,
                   t0_ms, t1_ms, rtt_ms, cpu_ms,
                   "ok", rep.text);
        }
        else if (rc == 0)
        {
            // Timeout
            printf("%s,%s,%d,%" PRIu32 ",%.6f,%.6f,%.6f,%.6f,%s,\"%s\"\n",
                   backend, "sender", i, req.counter,
                   t0_ms, t1_ms, rtt_ms, cpu_ms,
                   "timeout", req.text);
        }
        else
        {
            // Error
            printf("%s,%s,%d,%" PRIu32 ",%.6f,%.6f,%.6f,%.6f,%s,\"%s\"\n",
                   backend, "sender", i, req.counter,
                   t0_ms, t1_ms, rtt_ms, cpu_ms,
                   "error", req.text);
        }
    }

    ipc_destroy(h);
    return 0;
}
