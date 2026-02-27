#pragma once
#include <stdint.h>
#include <time.h>

typedef struct fd_msg_t {
    uint32_t counter;
    uint64_t t_send_ns;
    char     text[64]; // null-terminated
} fd_msg_t;

static inline uint64_t now_monotonic_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static inline uint64_t cpu_time_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
