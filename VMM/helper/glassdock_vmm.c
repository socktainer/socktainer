// Copyright 2026 Socktainer contributors
// SPDX-License-Identifier: Apache-2.0

#include "libkrun.h"
#include "gvproxy_process.h"

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct configuration {
    pid_t parent_pid;
    const char *kernel;
    const char *root_disk;
    const char *data_disk;
    const char *bind_source;
    const char *excluded_bind_source;
    const char *control_socket;
    const char *console_log;
    uint8_t cpus;
    uint32_t memory_mib;
};

static void usage(const char *program) {
    fprintf(stderr,
        "usage: %s --kernel PATH --root-disk PATH --data-disk PATH "
        "--bind-source PATH --excluded-bind-source PATH --control-socket PATH "
        "--console-log PATH --parent-pid PID [--cpus COUNT] [--memory-mib SIZE]\n",
        program);
}

static void fail_krun(const char *operation, int32_t result) {
    if (result >= 0) {
        return;
    }
    fprintf(stderr, "glassdock-vmm: %s failed: %s (%d)\n", operation,
        strerror(-result), result);
    exit(125);
}

static uint32_t parse_uint32(const char *name, const char *value, uint32_t minimum,
    uint32_t maximum) {
    char *end = NULL;
    errno = 0;
    unsigned long parsed = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed < minimum || parsed > maximum) {
        fprintf(stderr, "glassdock-vmm: invalid %s: %s\n", name, value);
        exit(2);
    }
    return (uint32_t)parsed;
}

static void require_absolute(const char *name, const char *path) {
    if (path == NULL || path[0] != '/') {
        fprintf(stderr, "glassdock-vmm: %s must be an absolute path\n", name);
        exit(2);
    }
}

static bool write_network_state(const char *console_log) {
    char directory[PATH_MAX];
    const char *separator = strrchr(console_log, '/');
    if (separator == NULL || separator == console_log ||
        (size_t)(separator - console_log) >= sizeof(directory)) {
        return false;
    }
    const size_t directory_length = (size_t)(separator - console_log);
    memcpy(directory, console_log, directory_length);
    directory[directory_length] = '\0';
    char state_path[PATH_MAX];
    char staging_path[PATH_MAX];
    if (snprintf(state_path, sizeof(state_path), "%s/network.json", directory) >=
            (int)sizeof(state_path) ||
        snprintf(staging_path, sizeof(staging_path), "%s/.network.%d.tmp", directory,
            getpid()) >= (int)sizeof(staging_path)) {
        return false;
    }
    char contents[256];
    const int contents_length = snprintf(contents, sizeof(contents),
        "{\"guestAddress\":\"192.168.127.2/24\",\"gateway\":\"192.168.127.1\","
        "\"dns\":\"192.168.127.1\",\"mtu\":1500}\n");
    if (contents_length <= 0 || contents_length >= (int)sizeof(contents)) {
        return false;
    }
    const int descriptor = open(staging_path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (descriptor < 0) {
        return false;
    }
    size_t offset = 0;
    while (offset < (size_t)contents_length) {
        const ssize_t count = write(descriptor, contents + offset,
            (size_t)contents_length - offset);
        if (count > 0) {
            offset += (size_t)count;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    const bool complete = offset == (size_t)contents_length && fsync(descriptor) == 0;
    const int close_result = close(descriptor);
    if (!complete || close_result != 0 || rename(staging_path, state_path) != 0) {
        unlink(staging_path);
        return false;
    }
    return true;
}

static struct configuration parse_configuration(int argc, char **argv) {
    struct configuration configuration = {.cpus = 6, .memory_mib = 1024};
    static const struct option options[] = {
        {"kernel", required_argument, NULL, 'k'},
        {"parent-pid", required_argument, NULL, 'p'},
        {"root-disk", required_argument, NULL, 'r'},
        {"data-disk", required_argument, NULL, 'd'},
        {"bind-source", required_argument, NULL, 'b'},
        {"excluded-bind-source", required_argument, NULL, 'x'},
        {"control-socket", required_argument, NULL, 'c'},
        {"console-log", required_argument, NULL, 'l'},
        {"cpus", required_argument, NULL, 'C'},
        {"memory-mib", required_argument, NULL, 'm'},
        {NULL, 0, NULL, 0},
    };
    int option;
    while ((option = getopt_long(argc, argv, "", options, NULL)) != -1) {
        switch (option) {
        case 'p': configuration.parent_pid = (pid_t)parse_uint32(
            "parent PID", optarg, 2, INT_MAX); break;
        case 'k': configuration.kernel = optarg; break;
        case 'r': configuration.root_disk = optarg; break;
        case 'd': configuration.data_disk = optarg; break;
        case 'b': configuration.bind_source = optarg; break;
        case 'x': configuration.excluded_bind_source = optarg; break;
        case 'c': configuration.control_socket = optarg; break;
        case 'l': configuration.console_log = optarg; break;
        case 'C': configuration.cpus = (uint8_t)parse_uint32("CPU count", optarg, 1, 64); break;
        case 'm': configuration.memory_mib = parse_uint32("memory size", optarg, 96, 65536); break;
        default: usage(argv[0]); exit(2);
        }
    }
    if (optind != argc) {
        usage(argv[0]);
        exit(2);
    }
    require_absolute("kernel", configuration.kernel);
    require_absolute("root disk", configuration.root_disk);
    require_absolute("data disk", configuration.data_disk);
    require_absolute("bind source", configuration.bind_source);
    require_absolute("excluded bind source", configuration.excluded_bind_source);
    require_absolute("control socket", configuration.control_socket);
    require_absolute("console log", configuration.console_log);
    if (configuration.parent_pid <= 1 || getppid() != configuration.parent_pid) {
        fprintf(stderr, "glassdock-vmm: parent process is not alive\n");
        exit(125);
    }
    if (access(configuration.kernel, R_OK) != 0 || access(configuration.root_disk, R_OK) != 0 ||
        access(configuration.data_disk, R_OK | W_OK) != 0 ||
        access(configuration.bind_source, R_OK | X_OK) != 0) {
        fprintf(stderr, "glassdock-vmm: a required artifact or directory is inaccessible: %s\n",
            strerror(errno));
        exit(125);
    }
    return configuration;
}

int main(int argc, char **argv) {
    const struct configuration configuration = parse_configuration(argc, argv);
    if (setpgid(0, 0) != 0) {
        fprintf(stderr, "glassdock-vmm: create process group failed: %s\n", strerror(errno));
        return 125;
    }
    struct glassdock_gvproxy gvproxy = {.pid = -1};
    if (glassdock_gvproxy_start(argv[0], configuration.console_log, &gvproxy) != 0) {
        fprintf(stderr, "glassdock-vmm: start gvproxy failed: %s\n", strerror(errno));
        return 125;
    }
    if (glassdock_gvproxy_watch_parent(configuration.parent_pid) != 0) {
        fprintf(stderr, "glassdock-vmm: supervise parent failed: %s\n", strerror(errno));
        glassdock_gvproxy_stop(&gvproxy);
        return 125;
    }
    if (!write_network_state(configuration.console_log)) {
        fprintf(stderr, "glassdock-vmm: publish network state failed: %s\n",
            strerror(errno));
        glassdock_gvproxy_stop(&gvproxy);
        return 125;
    }
    const int32_t context = krun_create_ctx();
    fail_krun("create context", context);
    fail_krun("configure machine",
        krun_set_vm_config((uint32_t)context, configuration.cpus, configuration.memory_mib));
    fail_krun("configure kernel", krun_set_kernel((uint32_t)context, configuration.kernel,
        KRUN_KERNEL_FORMAT_RAW, NULL,
        "reboot=k panic=-1 panic_print=0 nomodule console=hvc0 rootfstype=virtiofs "
        "root=/dev/root ro init=/init.krun"));
    fail_krun("configure root disk", krun_add_disk3((uint32_t)context, "root",
        configuration.root_disk, KRUN_DISK_FORMAT_RAW, true, false, KRUN_SYNC_FULL));
    fail_krun("configure data disk", krun_add_disk3((uint32_t)context, "data",
        configuration.data_disk, KRUN_DISK_FORMAT_RAW, false, false, KRUN_SYNC_RELAXED));
    fail_krun("configure block root", krun_set_root_disk_remount((uint32_t)context,
        "/dev/vda", "ext4", "ro"));
    fail_krun("configure bind filesystem", krun_add_virtiofs4((uint32_t)context,
        "glassdock-home", configuration.bind_source, 0, false,
        KRUN_SEMANTICS_LINUX_SIMPLIFIED));
    fail_krun("configure control port", krun_add_vsock_port2((uint32_t)context, 1025,
        configuration.control_socket, true));
    uint8_t network_mac[6] = {0x5a, 0x94, 0xef, 0xe4, 0x0c, 0xee};
    fail_krun("configure network", krun_add_net_unixgram((uint32_t)context,
        gvproxy.datapath_socket, -1, network_mac, 0, NET_FLAG_VFKIT));
    fail_krun("disable implicit vsock", krun_disable_implicit_vsock((uint32_t)context));
    fail_krun("configure vsock", krun_add_vsock((uint32_t)context, 0));
    fail_krun("configure console", krun_set_console_output((uint32_t)context,
        configuration.console_log));

    const char *guest_arguments[] = {
        "/sbin/init",
        "--host-bind-source", configuration.bind_source,
        "--excluded-host-bind-source", configuration.excluded_bind_source,
        NULL,
    };
    const char *guest_environment[] = {
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        NULL,
        NULL,
        "GLASSDOCK_GUEST_DNS=192.168.127.1",
        NULL,
    };
    char guest_address_environment[64];
    char guest_gateway_environment[64];
    snprintf(guest_address_environment, sizeof(guest_address_environment),
        "GLASSDOCK_GUEST_ADDRESS=192.168.127.2/24");
    snprintf(guest_gateway_environment, sizeof(guest_gateway_environment),
        "GLASSDOCK_GUEST_GATEWAY=192.168.127.1");
    guest_environment[1] = guest_address_environment;
    guest_environment[2] = guest_gateway_environment;
    fail_krun("configure guest", krun_set_exec((uint32_t)context, "/sbin/init",
        guest_arguments, guest_environment));
    const int result = krun_start_enter((uint32_t)context);
    glassdock_gvproxy_stop(&gvproxy);
    return result;
}
