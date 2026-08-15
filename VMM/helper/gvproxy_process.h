// Copyright 2026 Socktainer contributors
// SPDX-License-Identifier: Apache-2.0

#ifndef GLASSDOCK_GVPROXY_PROCESS_H
#define GLASSDOCK_GVPROXY_PROCESS_H

#include <limits.h>
#include <sys/types.h>

struct glassdock_gvproxy {
    pid_t pid;
    char datapath_socket[PATH_MAX];
    char api_socket[PATH_MAX];
};

/*
 * Starts the generation-scoped userspace network and waits until both of its
 * sockets are ready. Any later gvproxy exit terminates the VMM process.
 */
int glassdock_gvproxy_start(const char *program, const char *console_log,
    struct glassdock_gvproxy *gvproxy);
int glassdock_gvproxy_watch_parent(pid_t parent_pid);
void glassdock_gvproxy_stop(struct glassdock_gvproxy *gvproxy);

#endif
