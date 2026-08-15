// Copyright 2026 Socktainer contributors
// SPDX-License-Identifier: Apache-2.0

#include "gvproxy_process.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/event.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static _Atomic pid_t supervised_pid = -1;
static _Atomic bool stopping = false;
static int termination_pipe[2] = {-1, -1};

static bool copy_parent_directory(const char *path, char destination[PATH_MAX]) {
    const char *separator = strrchr(path, '/');
    if (separator == NULL || separator == path ||
        (size_t)(separator - path) >= PATH_MAX) {
        return false;
    }
    const size_t length = (size_t)(separator - path);
    memcpy(destination, path, length);
    destination[length] = '\0';
    return true;
}

static bool make_path(char destination[PATH_MAX], const char *directory,
    const char *name) {
    const int length = snprintf(destination, PATH_MAX, "%s/%s", directory, name);
    return length > 0 && length < PATH_MAX;
}

static bool is_socket(const char *path) {
    struct stat status;
    return stat(path, &status) == 0 && S_ISSOCK(status.st_mode);
}

static void request_termination(int signal_number) {
    const uint8_t value = (uint8_t)signal_number;
    if (termination_pipe[1] >= 0) {
        (void)write(termination_pipe[1], &value, sizeof(value));
    }
}

static void *terminate_with_child(void *context) {
    (void)context;
    uint8_t signal_number = SIGTERM;
    while (read(termination_pipe[0], &signal_number, sizeof(signal_number)) < 0) {
        if (errno != EINTR) {
            signal_number = SIGTERM;
            break;
        }
    }
    const pid_t pid = atomic_load_explicit(&supervised_pid, memory_order_acquire);
    if (pid > 0) {
        (void)kill(pid, SIGTERM);
    }
    _exit(128 + signal_number);
}

static void *watch_gvproxy(void *context) {
    const pid_t pid = (pid_t)(intptr_t)context;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            break;
        }
    }
    if (!atomic_load_explicit(&stopping, memory_order_acquire)) {
        fprintf(stderr, "glassdock-vmm: gvproxy exited; failing VM generation\n");
        _exit(125);
    }
    return NULL;
}

static void *watch_parent(void *context) {
    const pid_t parent_pid = (pid_t)(intptr_t)context;
    const int queue = kqueue();
    if (queue < 0) {
        _exit(125);
    }
    struct kevent change;
    EV_SET(&change, (uintptr_t)parent_pid, EVFILT_PROC,
        EV_ADD | EV_ENABLE | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (kevent(queue, &change, 1, NULL, 0, NULL) != 0 || getppid() != parent_pid) {
        (void)close(queue);
        request_termination(SIGTERM);
        return NULL;
    }
    struct kevent event;
    while (kevent(queue, NULL, 0, &event, 1, NULL) < 0) {
        if (errno != EINTR) {
            (void)close(queue);
            request_termination(SIGTERM);
            return NULL;
        }
    }
    (void)close(queue);
    request_termination(SIGTERM);
    return NULL;
}

int glassdock_gvproxy_watch_parent(pid_t parent_pid) {
    if (parent_pid <= 1 || getppid() != parent_pid) {
        errno = ESRCH;
        return -1;
    }
    pthread_t watcher;
    const int result = pthread_create(
        &watcher, NULL, watch_parent, (void *)(intptr_t)parent_pid);
    if (result != 0) {
        errno = result;
        return -1;
    }
    (void)pthread_detach(watcher);
    return 0;
}

static void stop_supervised_child(void) {
    atomic_store_explicit(&stopping, true, memory_order_release);
    const pid_t pid = atomic_load_explicit(&supervised_pid, memory_order_acquire);
    if (pid > 0) {
        (void)kill(pid, SIGTERM);
    }
}

static int install_signal_handlers(void) {
    if (pipe(termination_pipe) != 0 ||
        fcntl(termination_pipe[0], F_SETFD, FD_CLOEXEC) != 0 ||
        fcntl(termination_pipe[1], F_SETFD, FD_CLOEXEC) != 0) {
        return -1;
    }
    pthread_t terminator;
    const int thread_result = pthread_create(
        &terminator, NULL, terminate_with_child, NULL);
    if (thread_result != 0) {
        errno = thread_result;
        return -1;
    }
    (void)pthread_detach(terminator);
    struct sigaction action = {
        .sa_handler = request_termination,
    };
    sigemptyset(&action.sa_mask);
    return sigaction(SIGINT, &action, NULL) == 0 &&
        sigaction(SIGTERM, &action, NULL) == 0 ? 0 : -1;
}

static int launch_gvproxy(const char *executable, const char *datapath_socket,
    const char *api_socket, const char *log_path, pid_t *pid) {
    char datapath_uri[PATH_MAX + 16];
    char api_uri[PATH_MAX + 16];
    if (snprintf(datapath_uri, sizeof(datapath_uri), "unixgram://%s", datapath_socket) >=
            (int)sizeof(datapath_uri) ||
        snprintf(api_uri, sizeof(api_uri), "unix://%s", api_socket) >=
            (int)sizeof(api_uri)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    const pid_t child = fork();
    if (child < 0) {
        return -1;
    }
    if (child == 0) {
        const int null_descriptor = open("/dev/null", O_RDWR);
        if (null_descriptor >= 0) {
            (void)dup2(null_descriptor, STDIN_FILENO);
            (void)dup2(null_descriptor, STDOUT_FILENO);
            (void)dup2(null_descriptor, STDERR_FILENO);
            if (null_descriptor > STDERR_FILENO) {
                (void)close(null_descriptor);
            }
        }
        char *const arguments[] = {
            (char *)executable,
            "-mtu", "1500",
            "-listen-vfkit", datapath_uri,
            "-listen", api_uri,
            "-ssh-port", "-1",
            "-log-file", (char *)log_path,
            NULL,
        };
        execv(executable, arguments);
        _exit(127);
    }
    *pid = child;
    return 0;
}

static int wait_until_ready(struct glassdock_gvproxy *gvproxy) {
    const struct timespec interval = {.tv_nsec = 1000000};
    for (unsigned int attempt = 0; attempt < 10000; attempt++) {
        int status = 0;
        const pid_t result = waitpid(gvproxy->pid, &status, WNOHANG);
        if (result == gvproxy->pid) {
            errno = ECHILD;
            return -1;
        }
        if (result < 0 && errno != EINTR) {
            return -1;
        }
        if (is_socket(gvproxy->datapath_socket) && is_socket(gvproxy->api_socket)) {
            return 0;
        }
        (void)nanosleep(&interval, NULL);
    }
    errno = ETIMEDOUT;
    return -1;
}

int glassdock_gvproxy_start(const char *program, const char *console_log,
    struct glassdock_gvproxy *gvproxy) {
    char runtime_directory[PATH_MAX];
    char network_directory[PATH_MAX];
    char program_path[PATH_MAX];
    char executable_directory[PATH_MAX];
    char executable[PATH_MAX];
    char log_path[PATH_MAX];
    if (!copy_parent_directory(console_log, runtime_directory) ||
        !make_path(network_directory, runtime_directory, "network") ||
        realpath(program, program_path) == NULL ||
        !copy_parent_directory(program_path, executable_directory) ||
        !make_path(executable, executable_directory, "gvproxy") ||
        !make_path(gvproxy->datapath_socket, network_directory, "d.sock") ||
        !make_path(gvproxy->api_socket, network_directory, "a.sock") ||
        !make_path(log_path, network_directory, "gvproxy.log")) {
        errno = ENAMETOOLONG;
        return -1;
    }
    if ((mkdir(network_directory, 0700) != 0 && errno != EEXIST) ||
        chmod(network_directory, 0700) != 0 || access(executable, X_OK) != 0) {
        return -1;
    }
    (void)unlink(gvproxy->datapath_socket);
    (void)unlink(gvproxy->api_socket);
    if (launch_gvproxy(executable, gvproxy->datapath_socket, gvproxy->api_socket,
            log_path, &gvproxy->pid) != 0) {
        return -1;
    }
    atomic_store_explicit(&supervised_pid, gvproxy->pid, memory_order_release);
    atomic_store_explicit(&stopping, false, memory_order_release);
    if (atexit(stop_supervised_child) != 0) {
        glassdock_gvproxy_stop(gvproxy);
        return -1;
    }
    if (install_signal_handlers() != 0 || wait_until_ready(gvproxy) != 0) {
        glassdock_gvproxy_stop(gvproxy);
        return -1;
    }
    pthread_t watcher;
    const int thread_result = pthread_create(
        &watcher, NULL, watch_gvproxy, (void *)(intptr_t)gvproxy->pid);
    if (thread_result != 0) {
        errno = thread_result;
        glassdock_gvproxy_stop(gvproxy);
        return -1;
    }
    (void)pthread_detach(watcher);
    return 0;
}

void glassdock_gvproxy_stop(struct glassdock_gvproxy *gvproxy) {
    if (gvproxy->pid <= 0) {
        return;
    }
    const pid_t pid = gvproxy->pid;
    gvproxy->pid = -1;
    atomic_store_explicit(&stopping, true, memory_order_release);
    atomic_store_explicit(&supervised_pid, -1, memory_order_release);
    (void)kill(pid, SIGTERM);
    const struct timespec interval = {.tv_nsec = 10000000};
    struct timespec start;
    (void)clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        const pid_t result = waitpid(pid, NULL, WNOHANG);
        if (result == pid || (result < 0 && errno == ECHILD)) {
            break;
        }
        if (result < 0 && errno != EINTR) {
            break;
        }
        struct timespec now;
        (void)clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec >= 2) {
            (void)kill(pid, SIGKILL);
            while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
            break;
        }
        (void)nanosleep(&interval, NULL);
    }
    (void)unlink(gvproxy->datapath_socket);
    (void)unlink(gvproxy->api_socket);
}
