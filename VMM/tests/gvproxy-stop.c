// Copyright 2026 Socktainer contributors
// SPDX-License-Identifier: Apache-2.0

#include "gvproxy_process.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static double elapsed_seconds(struct timespec start, struct timespec end) {
    return (double)(end.tv_sec - start.tv_sec) +
        (double)(end.tv_nsec - start.tv_nsec) / 1000000000.0;
}

int main(void) {
    const pid_t child = fork();
    if (child < 0) {
        perror("fork");
        return 1;
    }
    if (child == 0) {
        struct sigaction ignore = {.sa_handler = SIG_IGN};
        sigemptyset(&ignore.sa_mask);
        if (sigaction(SIGTERM, &ignore, NULL) != 0) {
            _exit(2);
        }
        for (;;) {
            pause();
        }
    }

    // Let the child install its handler before stop sends SIGTERM.
    struct timespec settle = {.tv_nsec = 100000000};
    nanosleep(&settle, NULL);
    struct glassdock_gvproxy gvproxy = {.pid = child};
    struct timespec start;
    struct timespec end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    glassdock_gvproxy_stop(&gvproxy);
    clock_gettime(CLOCK_MONOTONIC, &end);

    if (gvproxy.pid != -1) {
        fprintf(stderr, "stop did not clear the child PID\n");
        return 1;
    }
    if (elapsed_seconds(start, end) > 3.0) {
        fprintf(stderr, "stop did not enforce its shutdown deadline\n");
        return 1;
    }
    int status = 0;
    if (waitpid(child, &status, WNOHANG) >= 0) {
        fprintf(stderr, "stop did not reap the child\n");
        return 1;
    }
    return 0;
}
