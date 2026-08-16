#ifndef GLASSDOCK_PING_GATEWAY_H
#define GLASSDOCK_PING_GATEWAY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct glassdock_ping_gateway glassdock_ping_gateway_t;

typedef struct {
    const char *public_socket_path;
    const char *backend_socket_path;
    const char *api_version;
    const char *builder_version;
    bool experimental;
    uint32_t max_connections;
    uint32_t header_timeout_milliseconds;
} glassdock_ping_gateway_config_t;

// Starts a bounded kqueue gateway. The returned handle owns the public socket.
// On failure, this function writes a nul-terminated message to error_buffer.
glassdock_ping_gateway_t *glassdock_ping_gateway_start(
    const glassdock_ping_gateway_config_t *config,
    char *error_buffer,
    size_t error_buffer_size
);

// Stops the event thread, closes all accepted sockets, removes the public
// socket, and releases the handle. Passing NULL is valid.
void glassdock_ping_gateway_stop(glassdock_ping_gateway_t *gateway);

#endif
