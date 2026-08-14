// Copyright 2026 Socktainer contributors
// SPDX-License-Identifier: Apache-2.0

#ifndef SOCKTAINER_GVPROXY_PROCESS_H
#define SOCKTAINER_GVPROXY_PROCESS_H

#include <limits.h>
#include <sys/types.h>

struct socktainer_gvproxy {
    pid_t pid;
    char datapath_socket[PATH_MAX];
    char api_socket[PATH_MAX];
};

/*
 * Starts the generation-scoped userspace network and waits until both of its
 * sockets are ready. Any later gvproxy exit terminates the VMM process.
 */
int socktainer_gvproxy_start(const char *program, const char *console_log,
    struct socktainer_gvproxy *gvproxy);
int socktainer_gvproxy_watch_parent(pid_t parent_pid);
void socktainer_gvproxy_stop(struct socktainer_gvproxy *gvproxy);

#endif
