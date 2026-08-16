#include "glassdock_ping_gateway.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define ST_HEADER_CAPACITY (16U * 1024U)
#define ST_PROXY_CAPACITY (64U * 1024U)
#define ST_DEFAULT_MAX_CONNECTIONS 1024U
#define ST_DEFAULT_HEADER_TIMEOUT_MS 5000U
#define ST_FAST_DRAIN_TIMEOUT_MS 1000U
#define ST_EVENT_BATCH 256

typedef enum {
    ST_READING_HEADER,
    ST_FAST_RESPONSE,
    ST_FAST_DRAIN,
    ST_CONNECTING_BACKEND,
    ST_PROXYING,
} st_connection_state_t;

typedef enum {
    ST_CLIENT,
    ST_BACKEND,
} st_endpoint_side_t;

typedef struct st_connection st_connection_t;

typedef struct {
    st_connection_t *connection;
    st_endpoint_side_t side;
} st_endpoint_t;

typedef struct {
    unsigned char bytes[ST_PROXY_CAPACITY];
    size_t start;
    size_t length;
} st_buffer_t;

struct st_connection {
    struct glassdock_ping_gateway *gateway;
    st_connection_t *next;
    st_connection_t *reap_next;
    st_endpoint_t client_endpoint;
    st_endpoint_t backend_endpoint;
    int client_fd;
    int backend_fd;
    st_connection_state_t state;
    uint64_t accepted_milliseconds;
    bool closing;
    bool client_read_eof;
    bool backend_read_eof;
    bool client_write_closed;
    bool backend_write_closed;
    unsigned char header[ST_HEADER_CAPACITY];
    size_t header_length;
    const char *fast_response;
    size_t fast_response_length;
    size_t fast_response_sent;
    st_buffer_t client_to_backend;
    st_buffer_t backend_to_client;
};

struct glassdock_ping_gateway {
    int listener_fd;
    int kqueue_fd;
    int control_read_fd;
    int control_write_fd;
    pthread_t thread;
    bool thread_started;
    bool public_socket_bound;
    atomic_bool stopping;
    char public_socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    char backend_socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    char *get_response;
    size_t get_response_length;
    char *head_response;
    size_t head_response_length;
    uint32_t max_connections;
    uint32_t header_timeout_milliseconds;
    uint32_t connection_count;
    st_connection_t *connections;
    st_connection_t *reap;
};

static void st_handle_fast_write(st_connection_t *connection);

static void st_set_error(char *buffer, size_t size, const char *message) {
    if (buffer == NULL || size == 0) {
        return;
    }
    (void)snprintf(buffer, size, "%s", message);
}

static void st_set_errno_error(char *buffer, size_t size, const char *operation) {
    if (buffer == NULL || size == 0) {
        return;
    }
    (void)snprintf(buffer, size, "%s: %s", operation, strerror(errno));
}

static uint64_t st_now_milliseconds(void) {
    struct timespec value;
    (void)clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * 1000U + (uint64_t)value.tv_nsec / 1000000U;
}

static bool st_copy_socket_path(char *destination, size_t capacity, const char *source) {
    if (source == NULL) {
        return false;
    }
    size_t length = strlen(source);
    if (length == 0 || length >= capacity) {
        return false;
    }
    memcpy(destination, source, length + 1);
    return true;
}

static int st_make_nonblocking_socket(void) {
    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor < 0) {
        return -1;
    }
    int one = 1;
    if (setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) < 0 ||
        fcntl(descriptor, F_SETFL, O_NONBLOCK) < 0 ||
        fcntl(descriptor, F_SETFD, FD_CLOEXEC) < 0) {
        int saved_errno = errno;
        close(descriptor);
        errno = saved_errno;
        return -1;
    }
    return descriptor;
}

static bool st_set_event(
    glassdock_ping_gateway_t *gateway,
    int descriptor,
    int16_t filter,
    uint16_t flags,
    void *user_data
) {
    struct kevent change;
    EV_SET(&change, descriptor, filter, flags, 0, 0, user_data);
    return kevent(gateway->kqueue_fd, &change, 1, NULL, 0, NULL) == 0;
}

static void st_buffer_compact(st_buffer_t *buffer) {
    if (buffer->length == 0) {
        buffer->start = 0;
    } else if (buffer->start > 0) {
        memmove(buffer->bytes, buffer->bytes + buffer->start, buffer->length);
        buffer->start = 0;
    }
}

static bool st_ascii_equal_case_insensitive(const unsigned char *bytes, size_t length, const char *text) {
    size_t text_length = strlen(text);
    if (length != text_length) {
        return false;
    }
    for (size_t index = 0; index < length; index++) {
        unsigned char left = bytes[index];
        unsigned char right = (unsigned char)text[index];
        if (left >= 'A' && left <= 'Z') {
            left = (unsigned char)(left + ('a' - 'A'));
        }
        if (right >= 'A' && right <= 'Z') {
            right = (unsigned char)(right + ('a' - 'A'));
        }
        if (left != right) {
            return false;
        }
    }
    return true;
}

static bool st_header_value_has_close(const unsigned char *bytes, size_t length) {
    size_t index = 0;
    while (index < length) {
        while (index < length && (bytes[index] == ' ' || bytes[index] == '\t' || bytes[index] == ',')) {
            index++;
        }
        size_t start = index;
        while (index < length && bytes[index] != ',') {
            index++;
        }
        size_t end = index;
        while (end > start && (bytes[end - 1] == ' ' || bytes[end - 1] == '\t')) {
            end--;
        }
        if (st_ascii_equal_case_insensitive(bytes + start, end - start, "close")) {
            return true;
        }
    }
    return false;
}

static bool st_valid_ping_target(const unsigned char *bytes, size_t length) {
    if (length == 6 && memcmp(bytes, "/_ping", 6) == 0) {
        return true;
    }
    if (length < 11 || bytes[0] != '/' || bytes[1] != 'v') {
        return false;
    }
    size_t index = 2;
    size_t major_start = index;
    while (index < length && bytes[index] >= '0' && bytes[index] <= '9') {
        index++;
    }
    if (index == major_start || index >= length || bytes[index++] != '.') {
        return false;
    }
    size_t minor_start = index;
    while (index < length && bytes[index] >= '0' && bytes[index] <= '9') {
        index++;
    }
    return index > minor_start && length - index == 6 && memcmp(bytes + index, "/_ping", 6) == 0;
}

static const unsigned char *st_find_crlf(const unsigned char *bytes, size_t length) {
    if (length < 2) {
        return NULL;
    }
    for (size_t index = 0; index + 1 < length; index++) {
        if (bytes[index] == '\r' && bytes[index + 1] == '\n') {
            return bytes + index;
        }
    }
    return NULL;
}

static size_t st_complete_header_length(const unsigned char *bytes, size_t length) {
    if (length < 4) {
        return 0;
    }
    for (size_t index = 0; index + 3 < length; index++) {
        if (bytes[index] == '\r' && bytes[index + 1] == '\n' &&
            bytes[index + 2] == '\r' && bytes[index + 3] == '\n') {
            return index + 4;
        }
    }
    return 0;
}

// Returns 1 for GET, 2 for HEAD, and 0 for all requests that must use Vapor.
static int st_classify_ping(const unsigned char *bytes, size_t length) {
    size_t header_length = st_complete_header_length(bytes, length);
    if (header_length == 0 || header_length != length) {
        return 0;
    }
    const unsigned char *line_end = st_find_crlf(bytes, length);
    if (line_end == NULL) {
        return 0;
    }
    size_t request_line_length = (size_t)(line_end - bytes);
    const unsigned char *first_space = memchr(bytes, ' ', request_line_length);
    if (first_space == NULL) {
        return 0;
    }
    const unsigned char *second_space = memchr(
        first_space + 1,
        ' ',
        request_line_length - (size_t)(first_space + 1 - bytes)
    );
    if (second_space == NULL || memchr(second_space + 1, ' ', (size_t)(line_end - second_space - 1)) != NULL) {
        return 0;
    }
    int method = 0;
    size_t method_length = (size_t)(first_space - bytes);
    if (method_length == 3 && memcmp(bytes, "GET", 3) == 0) {
        method = 1;
    } else if (method_length == 4 && memcmp(bytes, "HEAD", 4) == 0) {
        method = 2;
    } else {
        return 0;
    }
    if (!st_valid_ping_target(first_space + 1, (size_t)(second_space - first_space - 1))) {
        return 0;
    }
    size_t version_length = (size_t)(line_end - second_space - 1);
    bool http_1_1 = version_length == 8 && memcmp(second_space + 1, "HTTP/1.1", 8) == 0;
    if (!((version_length == 8 && memcmp(second_space + 1, "HTTP/1.0", 8) == 0) || http_1_1)) {
        return 0;
    }

    bool has_close = false;
    size_t host_count = 0;
    const unsigned char *cursor = line_end + 2;
    const unsigned char *header_end = bytes + header_length - 2;
    while (cursor < header_end) {
        const unsigned char *end = st_find_crlf(cursor, (size_t)(header_end - cursor));
        if (end == NULL || end == cursor || cursor[0] == ' ' || cursor[0] == '\t') {
            return 0;
        }
        const unsigned char *colon = memchr(cursor, ':', (size_t)(end - cursor));
        if (colon == NULL || colon == cursor) {
            return 0;
        }
        for (const unsigned char *name = cursor; name < colon; name++) {
            unsigned char value = *name;
            bool valid = (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') ||
                         (value >= '0' && value <= '9') || value == '-' || value == '_';
            if (!valid) {
                return 0;
            }
        }
        const unsigned char *value = colon + 1;
        while (value < end && (*value == ' ' || *value == '\t')) {
            value++;
        }
        const unsigned char *value_end = end;
        while (value_end > value && (value_end[-1] == ' ' || value_end[-1] == '\t')) {
            value_end--;
        }
        for (const unsigned char *item = value; item < value_end; item++) {
            if ((*item < 0x20 && *item != '\t') || *item == 0x7f) {
                return 0;
            }
        }
        size_t name_length = (size_t)(colon - cursor);
        if (st_ascii_equal_case_insensitive(cursor, name_length, "content-length") ||
            st_ascii_equal_case_insensitive(cursor, name_length, "transfer-encoding") ||
            st_ascii_equal_case_insensitive(cursor, name_length, "expect") ||
            st_ascii_equal_case_insensitive(cursor, name_length, "upgrade")) {
            return 0;
        }
        if (st_ascii_equal_case_insensitive(cursor, name_length, "connection") &&
            st_header_value_has_close(value, (size_t)(value_end - value))) {
            has_close = true;
        }
        if (st_ascii_equal_case_insensitive(cursor, name_length, "host")) {
            if (value == value_end) {
                return 0;
            }
            host_count++;
        }
        cursor = end + 2;
    }
    return has_close && (!http_1_1 || host_count == 1) ? method : 0;
}

static void st_unlink_connection(st_connection_t *connection) {
    glassdock_ping_gateway_t *gateway = connection->gateway;
    st_connection_t **cursor = &gateway->connections;
    while (*cursor != NULL && *cursor != connection) {
        cursor = &(*cursor)->next;
    }
    if (*cursor == connection) {
        *cursor = connection->next;
    }
}

static void st_close_connection(st_connection_t *connection) {
    if (connection->closing) {
        return;
    }
    connection->closing = true;
    if (connection->client_fd >= 0) {
        close(connection->client_fd);
        connection->client_fd = -1;
    }
    if (connection->backend_fd >= 0) {
        close(connection->backend_fd);
        connection->backend_fd = -1;
    }
    st_unlink_connection(connection);
    if (connection->gateway->connection_count > 0) {
        connection->gateway->connection_count--;
    }
    if (connection->gateway->connection_count + 1 == connection->gateway->max_connections) {
        (void)st_set_event(
            connection->gateway,
            connection->gateway->listener_fd,
            EVFILT_READ,
            EV_ENABLE,
            NULL
        );
    }
    connection->reap_next = connection->gateway->reap;
    connection->gateway->reap = connection;
}

static void st_reap_connections(glassdock_ping_gateway_t *gateway) {
    st_connection_t *connection = gateway->reap;
    gateway->reap = NULL;
    while (connection != NULL) {
        st_connection_t *next = connection->reap_next;
        free(connection);
        connection = next;
    }
}

static void st_update_proxy_events(st_connection_t *connection) {
    if (connection->closing || connection->state != ST_PROXYING) {
        return;
    }
    bool read_client = !connection->client_read_eof &&
                       connection->client_to_backend.length < ST_PROXY_CAPACITY;
    bool write_client = connection->backend_to_client.length > 0;
    bool read_backend = !connection->backend_read_eof &&
                        connection->backend_to_client.length < ST_PROXY_CAPACITY;
    bool write_backend = connection->client_to_backend.length > 0;
    bool registered =
        st_set_event(
            connection->gateway,
            connection->client_fd,
            EVFILT_READ,
            EV_ADD | (read_client ? EV_ENABLE : EV_DISABLE),
            &connection->client_endpoint
        ) &&
        st_set_event(
            connection->gateway,
            connection->client_fd,
            EVFILT_WRITE,
            EV_ADD | (write_client ? EV_ENABLE : EV_DISABLE),
            &connection->client_endpoint
        ) &&
        st_set_event(
            connection->gateway,
            connection->backend_fd,
            EVFILT_READ,
            EV_ADD | (read_backend ? EV_ENABLE : EV_DISABLE),
            &connection->backend_endpoint
        ) &&
        st_set_event(
            connection->gateway,
            connection->backend_fd,
            EVFILT_WRITE,
            EV_ADD | (write_backend ? EV_ENABLE : EV_DISABLE),
            &connection->backend_endpoint
        );
    if (!registered) {
        st_close_connection(connection);
    }
}

static void st_finish_half_closes(st_connection_t *connection) {
    if (connection->closing || connection->state != ST_PROXYING) {
        return;
    }
    if (connection->client_read_eof && connection->client_to_backend.length == 0 &&
        !connection->backend_write_closed) {
        (void)shutdown(connection->backend_fd, SHUT_WR);
        connection->backend_write_closed = true;
    }
    if (connection->backend_read_eof && connection->backend_to_client.length == 0 &&
        !connection->client_write_closed) {
        (void)shutdown(connection->client_fd, SHUT_WR);
        connection->client_write_closed = true;
    }
    if (connection->client_read_eof && connection->backend_read_eof &&
        connection->client_to_backend.length == 0 && connection->backend_to_client.length == 0) {
        st_close_connection(connection);
    }
}

static void st_read_into_buffer(st_connection_t *connection, int descriptor, st_buffer_t *buffer, bool *eof) {
    st_buffer_compact(buffer);
    while (buffer->length < ST_PROXY_CAPACITY) {
        ssize_t count = recv(
            descriptor,
            buffer->bytes + buffer->start + buffer->length,
            ST_PROXY_CAPACITY - buffer->start - buffer->length,
            0
        );
        if (count > 0) {
            buffer->length += (size_t)count;
            continue;
        }
        if (count == 0) {
            *eof = true;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            st_close_connection(connection);
        }
        return;
    }
}

static void st_write_from_buffer(st_connection_t *connection, int descriptor, st_buffer_t *buffer) {
    while (buffer->length > 0) {
        ssize_t count = send(descriptor, buffer->bytes + buffer->start, buffer->length, 0);
        if (count > 0) {
            buffer->start += (size_t)count;
            buffer->length -= (size_t)count;
            if (buffer->length == 0) {
                buffer->start = 0;
            }
            continue;
        }
        if (count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
            st_close_connection(connection);
        }
        return;
    }
}

static bool st_start_backend(st_connection_t *connection) {
    glassdock_ping_gateway_t *gateway = connection->gateway;
    int descriptor = st_make_nonblocking_socket();
    if (descriptor < 0) {
        return false;
    }
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, gateway->backend_socket_path, strlen(gateway->backend_socket_path) + 1);
    int result = connect(descriptor, (struct sockaddr *)&address, sizeof(address));
    if (result < 0 && errno != EINPROGRESS) {
        close(descriptor);
        return false;
    }
    connection->backend_fd = descriptor;
    connection->backend_endpoint.connection = connection;
    connection->backend_endpoint.side = ST_BACKEND;
    if (connection->header_length > ST_PROXY_CAPACITY) {
        close(descriptor);
        connection->backend_fd = -1;
        return false;
    }
    memcpy(connection->client_to_backend.bytes, connection->header, connection->header_length);
    connection->client_to_backend.length = connection->header_length;
    connection->state = result == 0 ? ST_PROXYING : ST_CONNECTING_BACKEND;
    (void)st_set_event(gateway, connection->client_fd, EVFILT_READ, EV_DISABLE, &connection->client_endpoint);
    if (connection->state == ST_CONNECTING_BACKEND) {
        return st_set_event(
            gateway,
            descriptor,
            EVFILT_WRITE,
            EV_ADD | EV_ENABLE,
            &connection->backend_endpoint
        );
    }
    st_update_proxy_events(connection);
    return true;
}

static void st_handle_header_read(st_connection_t *connection) {
    while (connection->header_length < ST_HEADER_CAPACITY) {
        ssize_t count = recv(
            connection->client_fd,
            connection->header + connection->header_length,
            ST_HEADER_CAPACITY - connection->header_length,
            0
        );
        if (count > 0) {
            connection->header_length += (size_t)count;
            size_t complete = st_complete_header_length(connection->header, connection->header_length);
            if (complete == 0) {
                continue;
            }
            int ping = st_classify_ping(connection->header, connection->header_length);
            if (ping != 0) {
                connection->state = ST_FAST_RESPONSE;
                connection->fast_response = ping == 1 ? connection->gateway->get_response
                                                       : connection->gateway->head_response;
                connection->fast_response_length = ping == 1 ? connection->gateway->get_response_length
                                                              : connection->gateway->head_response_length;
                st_handle_fast_write(connection);
            } else if (!st_start_backend(connection)) {
                st_close_connection(connection);
            }
            return;
        }
        if (count == 0) {
            st_close_connection(connection);
        } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            st_close_connection(connection);
        }
        return;
    }
    if (!st_start_backend(connection)) {
        st_close_connection(connection);
    }
}

static void st_handle_fast_write(st_connection_t *connection) {
    while (connection->fast_response_sent < connection->fast_response_length) {
        ssize_t count = send(
            connection->client_fd,
            connection->fast_response + connection->fast_response_sent,
            connection->fast_response_length - connection->fast_response_sent,
            0
        );
        if (count > 0) {
            connection->fast_response_sent += (size_t)count;
            continue;
        }
        if (count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
            st_close_connection(connection);
        } else if (count < 0 && !st_set_event(
                                    connection->gateway,
                                    connection->client_fd,
                                    EVFILT_WRITE,
                                    EV_ADD | EV_ENABLE,
                                    &connection->client_endpoint
                                )) {
            st_close_connection(connection);
        }
        return;
    }
    if (shutdown(connection->client_fd, SHUT_WR) < 0) {
        st_close_connection(connection);
        return;
    }
    connection->state = ST_FAST_DRAIN;
    connection->accepted_milliseconds = st_now_milliseconds();
    (void)st_set_event(
        connection->gateway,
        connection->client_fd,
        EVFILT_WRITE,
        EV_DISABLE,
        &connection->client_endpoint
    );
    if (!st_set_event(
            connection->gateway,
            connection->client_fd,
            EVFILT_READ,
            EV_ENABLE,
            &connection->client_endpoint
        )) {
        st_close_connection(connection);
    }
}

static void st_handle_fast_drain(st_connection_t *connection) {
    unsigned char discard[4096];
    while (true) {
        ssize_t count = recv(connection->client_fd, discard, sizeof(discard), 0);
        if (count > 0) {
            continue;
        }
        if (count == 0) {
            st_close_connection(connection);
        } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            st_close_connection(connection);
        }
        return;
    }
}

static void st_finish_backend_connect(st_connection_t *connection) {
    int socket_error = 0;
    socklen_t length = sizeof(socket_error);
    if (getsockopt(connection->backend_fd, SOL_SOCKET, SO_ERROR, &socket_error, &length) < 0 ||
        socket_error != 0) {
        st_close_connection(connection);
        return;
    }
    connection->state = ST_PROXYING;
    st_update_proxy_events(connection);
}

static void st_handle_proxy_event(st_connection_t *connection, st_endpoint_side_t side, int16_t filter) {
    if (filter == EVFILT_READ) {
        if (side == ST_CLIENT) {
            st_read_into_buffer(
                connection,
                connection->client_fd,
                &connection->client_to_backend,
                &connection->client_read_eof
            );
        } else {
            st_read_into_buffer(
                connection,
                connection->backend_fd,
                &connection->backend_to_client,
                &connection->backend_read_eof
            );
        }
    } else if (filter == EVFILT_WRITE) {
        if (side == ST_CLIENT) {
            st_write_from_buffer(connection, connection->client_fd, &connection->backend_to_client);
        } else {
            st_write_from_buffer(connection, connection->backend_fd, &connection->client_to_backend);
        }
    }
    st_finish_half_closes(connection);
    st_update_proxy_events(connection);
}

static void st_accept_connections(glassdock_ping_gateway_t *gateway) {
    while (gateway->connection_count < gateway->max_connections) {
        int descriptor = accept(gateway->listener_fd, NULL, NULL);
        if (descriptor < 0) {
            return;
        }
        int one = 1;
        if (setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) < 0 ||
            fcntl(descriptor, F_SETFL, O_NONBLOCK) < 0 ||
            fcntl(descriptor, F_SETFD, FD_CLOEXEC) < 0) {
            close(descriptor);
            continue;
        }
        st_connection_t *connection = calloc(1, sizeof(*connection));
        if (connection == NULL) {
            close(descriptor);
            continue;
        }
        connection->gateway = gateway;
        connection->client_fd = descriptor;
        connection->backend_fd = -1;
        connection->state = ST_READING_HEADER;
        connection->accepted_milliseconds = st_now_milliseconds();
        connection->client_endpoint.connection = connection;
        connection->client_endpoint.side = ST_CLIENT;
        connection->next = gateway->connections;
        gateway->connections = connection;
        gateway->connection_count++;
        if (!st_set_event(
                gateway,
                descriptor,
                EVFILT_READ,
                EV_ADD | EV_ENABLE,
                &connection->client_endpoint
            )) {
            st_close_connection(connection);
        }
    }
    if (gateway->connection_count >= gateway->max_connections) {
        (void)st_set_event(gateway, gateway->listener_fd, EVFILT_READ, EV_DISABLE, NULL);
    }
}

static void st_expire_headers(glassdock_ping_gateway_t *gateway) {
    uint64_t now = st_now_milliseconds();
    st_connection_t *connection = gateway->connections;
    while (connection != NULL) {
        st_connection_t *next = connection->next;
        uint64_t age = now - connection->accepted_milliseconds;
        bool header_expired =
            (connection->state == ST_READING_HEADER || connection->state == ST_CONNECTING_BACKEND) &&
            age > gateway->header_timeout_milliseconds;
        bool fast_drain_expired =
            connection->state == ST_FAST_DRAIN && age > ST_FAST_DRAIN_TIMEOUT_MS;
        if (header_expired || fast_drain_expired) {
            st_close_connection(connection);
        }
        connection = next;
    }
}

static void st_close_all_connections(glassdock_ping_gateway_t *gateway) {
    while (gateway->connections != NULL) {
        st_close_connection(gateway->connections);
    }
    st_reap_connections(gateway);
}

static void *st_event_loop(void *context) {
    glassdock_ping_gateway_t *gateway = context;
    struct kevent events[ST_EVENT_BATCH];
    while (!atomic_load_explicit(&gateway->stopping, memory_order_acquire)) {
        int count = kevent(gateway->kqueue_fd, NULL, 0, events, ST_EVENT_BATCH, NULL);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        for (int index = 0; index < count; index++) {
            struct kevent *event = &events[index];
            if (event->filter == EVFILT_TIMER) {
                st_expire_headers(gateway);
                continue;
            }
            if ((int)event->ident == gateway->control_read_fd) {
                atomic_store_explicit(&gateway->stopping, true, memory_order_release);
                break;
            }
            if ((int)event->ident == gateway->listener_fd) {
                st_accept_connections(gateway);
                continue;
            }
            st_endpoint_t *endpoint = event->udata;
            if (endpoint == NULL || endpoint->connection == NULL || endpoint->connection->closing) {
                continue;
            }
            st_connection_t *connection = endpoint->connection;
            if ((event->flags & EV_ERROR) != 0 && event->data != 0) {
                st_close_connection(connection);
                continue;
            }
            if (connection->state == ST_READING_HEADER && endpoint->side == ST_CLIENT &&
                event->filter == EVFILT_READ) {
                st_handle_header_read(connection);
            } else if (connection->state == ST_FAST_RESPONSE && endpoint->side == ST_CLIENT &&
                       event->filter == EVFILT_WRITE) {
                st_handle_fast_write(connection);
            } else if (connection->state == ST_FAST_DRAIN && endpoint->side == ST_CLIENT &&
                       event->filter == EVFILT_READ) {
                st_handle_fast_drain(connection);
            } else if (connection->state == ST_CONNECTING_BACKEND && endpoint->side == ST_BACKEND &&
                       event->filter == EVFILT_WRITE) {
                st_finish_backend_connect(connection);
            } else if (connection->state == ST_PROXYING) {
                st_handle_proxy_event(connection, endpoint->side, event->filter);
            }
        }
        st_reap_connections(gateway);
    }
    st_close_all_connections(gateway);
    return NULL;
}

static char *st_make_response(
    const char *api_version,
    const char *builder_version,
    bool experimental,
    bool include_body,
    size_t *length
) {
    const char *format =
        "HTTP/1.1 200 OK\r\n"
        "Api-Version: %s\r\n"
        "Builder-Version: %s\r\n"
        "Docker-Experimental: %s\r\n"
        "Cache-Control: no-cache, no-store, must-revalidate\r\n"
        "Pragma: no-cache\r\n"
        "Content-Type: text/plain; charset=utf-8\r\n"
        "Content-Length: %u\r\n"
        "Connection: close\r\n"
        "\r\n%s";
    const char *body = include_body ? "OK" : "";
    unsigned int body_length = include_body ? 2U : 0U;
    int required = snprintf(
        NULL,
        0,
        format,
        api_version,
        builder_version,
        experimental ? "true" : "false",
        body_length,
        body
    );
    if (required < 0) {
        return NULL;
    }
    char *response = malloc((size_t)required + 1);
    if (response == NULL) {
        return NULL;
    }
    (void)snprintf(
        response,
        (size_t)required + 1,
        format,
        api_version,
        builder_version,
        experimental ? "true" : "false",
        body_length,
        body
    );
    *length = (size_t)required;
    return response;
}

static bool st_valid_header_value(const char *value) {
    return value != NULL && strchr(value, '\r') == NULL && strchr(value, '\n') == NULL;
}

static void st_cleanup_gateway(glassdock_ping_gateway_t *gateway) {
    if (gateway == NULL) {
        return;
    }
    if (gateway->listener_fd >= 0) {
        close(gateway->listener_fd);
    }
    if (gateway->kqueue_fd >= 0) {
        close(gateway->kqueue_fd);
    }
    if (gateway->control_read_fd >= 0) {
        close(gateway->control_read_fd);
    }
    if (gateway->control_write_fd >= 0) {
        close(gateway->control_write_fd);
    }
    if (gateway->public_socket_bound) {
        unlink(gateway->public_socket_path);
    }
    free(gateway->get_response);
    free(gateway->head_response);
    free(gateway);
}

glassdock_ping_gateway_t *glassdock_ping_gateway_start(
    const glassdock_ping_gateway_config_t *config,
    char *error_buffer,
    size_t error_buffer_size
) {
    if (config == NULL || !st_valid_header_value(config->api_version) ||
        config->api_version[0] == '\0' ||
        !st_valid_header_value(config->builder_version)) {
        st_set_error(error_buffer, error_buffer_size, "Invalid gateway configuration");
        return NULL;
    }
    glassdock_ping_gateway_t *gateway = calloc(1, sizeof(*gateway));
    if (gateway == NULL) {
        st_set_errno_error(error_buffer, error_buffer_size, "Allocate gateway");
        return NULL;
    }
    gateway->listener_fd = -1;
    gateway->kqueue_fd = -1;
    gateway->control_read_fd = -1;
    gateway->control_write_fd = -1;
    atomic_init(&gateway->stopping, false);
    if (!st_copy_socket_path(
            gateway->public_socket_path,
            sizeof(gateway->public_socket_path),
            config->public_socket_path
        ) ||
        !st_copy_socket_path(
            gateway->backend_socket_path,
            sizeof(gateway->backend_socket_path),
            config->backend_socket_path
        )) {
        st_set_error(error_buffer, error_buffer_size, "Unix socket path is empty or too long");
        st_cleanup_gateway(gateway);
        return NULL;
    }
    gateway->max_connections = config->max_connections == 0 ? ST_DEFAULT_MAX_CONNECTIONS
                                                             : config->max_connections;
    if (gateway->max_connections > 4096U ||
        strcmp(gateway->public_socket_path, gateway->backend_socket_path) == 0) {
        st_set_error(error_buffer, error_buffer_size, "Invalid gateway socket paths or connection limit");
        st_cleanup_gateway(gateway);
        return NULL;
    }
    gateway->header_timeout_milliseconds =
        config->header_timeout_milliseconds == 0 ? ST_DEFAULT_HEADER_TIMEOUT_MS
                                                 : config->header_timeout_milliseconds;
    gateway->get_response = st_make_response(
        config->api_version,
        config->builder_version,
        config->experimental,
        true,
        &gateway->get_response_length
    );
    gateway->head_response = st_make_response(
        config->api_version,
        config->builder_version,
        config->experimental,
        false,
        &gateway->head_response_length
    );
    if (gateway->get_response == NULL || gateway->head_response == NULL) {
        st_set_error(error_buffer, error_buffer_size, "Create ping response");
        st_cleanup_gateway(gateway);
        return NULL;
    }

    gateway->listener_fd = st_make_nonblocking_socket();
    if (gateway->listener_fd < 0) {
        st_set_errno_error(error_buffer, error_buffer_size, "Create public socket");
        st_cleanup_gateway(gateway);
        return NULL;
    }
    (void)unlink(gateway->public_socket_path);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, gateway->public_socket_path, strlen(gateway->public_socket_path) + 1);
    if (bind(gateway->listener_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        st_set_errno_error(error_buffer, error_buffer_size, "Bind public socket");
        st_cleanup_gateway(gateway);
        return NULL;
    }
    gateway->public_socket_bound = true;
    if (listen(gateway->listener_fd, SOMAXCONN) < 0) {
        st_set_errno_error(error_buffer, error_buffer_size, "Listen on public socket");
        st_cleanup_gateway(gateway);
        return NULL;
    }

    gateway->kqueue_fd = kqueue();
    int control[2];
    if (gateway->kqueue_fd < 0 || pipe(control) < 0) {
        st_set_errno_error(error_buffer, error_buffer_size, "Create gateway event queue");
        st_cleanup_gateway(gateway);
        return NULL;
    }
    gateway->control_read_fd = control[0];
    gateway->control_write_fd = control[1];
    (void)fcntl(gateway->control_read_fd, F_SETFD, FD_CLOEXEC);
    (void)fcntl(gateway->control_write_fd, F_SETFD, FD_CLOEXEC);
    if (!st_set_event(gateway, gateway->listener_fd, EVFILT_READ, EV_ADD | EV_ENABLE, NULL) ||
        !st_set_event(gateway, gateway->control_read_fd, EVFILT_READ, EV_ADD | EV_ENABLE, NULL)) {
        st_set_errno_error(error_buffer, error_buffer_size, "Register gateway sockets");
        st_cleanup_gateway(gateway);
        return NULL;
    }
    struct kevent timer;
    EV_SET(&timer, 1, EVFILT_TIMER, EV_ADD | EV_ENABLE, 0, 1000, NULL);
    if (kevent(gateway->kqueue_fd, &timer, 1, NULL, 0, NULL) < 0) {
        st_set_errno_error(error_buffer, error_buffer_size, "Register gateway timer");
        st_cleanup_gateway(gateway);
        return NULL;
    }
    int thread_error = pthread_create(&gateway->thread, NULL, st_event_loop, gateway);
    if (thread_error != 0) {
        errno = thread_error;
        st_set_errno_error(error_buffer, error_buffer_size, "Start gateway event thread");
        st_cleanup_gateway(gateway);
        return NULL;
    }
    gateway->thread_started = true;
    return gateway;
}

void glassdock_ping_gateway_stop(glassdock_ping_gateway_t *gateway) {
    if (gateway == NULL) {
        return;
    }
    bool was_stopping = atomic_exchange_explicit(&gateway->stopping, true, memory_order_acq_rel);
    if (!was_stopping && gateway->control_write_fd >= 0) {
        unsigned char byte = 1;
        (void)write(gateway->control_write_fd, &byte, sizeof(byte));
    }
    if (gateway->thread_started) {
        (void)pthread_join(gateway->thread, NULL);
        gateway->thread_started = false;
    }
    st_cleanup_gateway(gateway);
}
