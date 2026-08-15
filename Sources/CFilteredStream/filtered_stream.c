#include "filtered_stream.h"

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// The macOS libarchive API is ABI-stable but its headers are not shipped in
// the SDK. ContainerizationArchive carries the same declarations privately;
// keep this compatibility surface to the small opaque/raw-reader subset we
// need instead of copying that package's entire vendored header.
struct archive;
struct archive_entry;

struct archive *archive_read_new(void);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_filter_bzip2(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_open_fd(struct archive *, int, size_t);
int archive_read_next_header(
    struct archive *,
    struct archive_entry **
);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_free(struct archive *);

#define GLASSDOCK_ARCHIVE_OK 0
#define GLASSDOCK_INPUT_BUFFER_SIZE (64 * 1024)
#define GLASSDOCK_LZMA_CONCATENATED UINT32_C(0x08)

// liblzma is part of the macOS SDK, but Apple ships only its ABI stub and not
// its public headers. Keep the compatibility declaration to the stable stream
// ABI used by lzma_stream_decoder(3). These fields and enum values are the
// public liblzma ABI, not implementation-private state.
typedef enum {
    GLASSDOCK_LZMA_RESERVED_ENUM = 0,
} glassdock_lzma_reserved_enum;

typedef enum {
    GLASSDOCK_LZMA_OK = 0,
    GLASSDOCK_LZMA_STREAM_END = 1,
    GLASSDOCK_LZMA_MEMLIMIT_ERROR = 6,
} glassdock_lzma_ret;

typedef enum {
    GLASSDOCK_LZMA_RUN = 0,
    GLASSDOCK_LZMA_FINISH = 3,
} glassdock_lzma_action;

typedef struct glassdock_lzma_allocator glassdock_lzma_allocator;
typedef struct glassdock_lzma_internal glassdock_lzma_internal;

typedef struct {
    const uint8_t *next_in;
    size_t avail_in;
    uint64_t total_in;
    uint8_t *next_out;
    size_t avail_out;
    uint64_t total_out;
    const glassdock_lzma_allocator *allocator;
    glassdock_lzma_internal *internal;
    void *reserved_ptr1;
    void *reserved_ptr2;
    void *reserved_ptr3;
    void *reserved_ptr4;
    uint64_t seek_pos;
    uint64_t reserved_int2;
    size_t reserved_int3;
    size_t reserved_int4;
    glassdock_lzma_reserved_enum reserved_enum1;
    glassdock_lzma_reserved_enum reserved_enum2;
} glassdock_lzma_stream;

glassdock_lzma_ret lzma_stream_decoder(
    glassdock_lzma_stream *,
    uint64_t,
    uint32_t
);
glassdock_lzma_ret lzma_code(
    glassdock_lzma_stream *,
    glassdock_lzma_action
);
void lzma_end(glassdock_lzma_stream *);

enum glassdock_filtered_stream_backend {
    GLASSDOCK_BACKEND_LIBARCHIVE,
    GLASSDOCK_BACKEND_LIBLZMA,
};

struct glassdock_filtered_stream {
    enum glassdock_filtered_stream_backend backend;
    enum glassdock_filtered_stream_error last_error;
    struct archive *archive;
    int source_fd;
    glassdock_lzma_stream xz;
    uint8_t input_buffer[GLASSDOCK_INPUT_BUFFER_SIZE];
    int source_eof;
    int stream_finished;
};

static void glassdock_filtered_stream_destroy(
    glassdock_filtered_stream *stream
) {
    if (stream == NULL) {
        return;
    }
    if (stream->backend == GLASSDOCK_BACKEND_LIBLZMA) {
        lzma_end(&stream->xz);
    } else if (stream->archive != NULL) {
        archive_read_free(stream->archive);
    }
    if (stream->source_fd >= 0) {
        close(stream->source_fd);
    }
    free(stream);
}

static glassdock_filtered_stream *glassdock_xz_stream_open(
    int owned_fd,
    uint64_t maximum_decoder_memory_bytes
) {
    if (maximum_decoder_memory_bytes == 0) {
        close(owned_fd);
        return NULL;
    }

    glassdock_filtered_stream *stream = calloc(1, sizeof(*stream));
    if (stream == NULL) {
        close(owned_fd);
        return NULL;
    }
    stream->backend = GLASSDOCK_BACKEND_LIBLZMA;
    stream->source_fd = owned_fd;

    glassdock_lzma_ret result = lzma_stream_decoder(
        &stream->xz,
        maximum_decoder_memory_bytes,
        GLASSDOCK_LZMA_CONCATENATED
    );
    if (result != GLASSDOCK_LZMA_OK) {
        glassdock_filtered_stream_destroy(stream);
        return NULL;
    }
    return stream;
}

static glassdock_filtered_stream *glassdock_archive_stream_open(
    int owned_fd,
    enum glassdock_filtered_stream_codec codec
) {
    struct archive *archive = archive_read_new();
    if (archive == NULL) {
        close(owned_fd);
        return NULL;
    }

    int filter_result;
    switch (codec) {
    case GLASSDOCK_FILTER_GZIP:
        filter_result = archive_read_support_filter_gzip(archive);
        break;
    case GLASSDOCK_FILTER_BZIP2:
        filter_result = archive_read_support_filter_bzip2(archive);
        break;
    default:
        archive_read_free(archive);
        close(owned_fd);
        return NULL;
    }

    if (filter_result != GLASSDOCK_ARCHIVE_OK
        || archive_read_support_format_raw(archive) != GLASSDOCK_ARCHIVE_OK
        || archive_read_open_fd(archive, owned_fd, GLASSDOCK_INPUT_BUFFER_SIZE)
            != GLASSDOCK_ARCHIVE_OK) {
        archive_read_free(archive);
        close(owned_fd);
        return NULL;
    }

    struct archive_entry *entry = NULL;
    if (archive_read_next_header(archive, &entry) != GLASSDOCK_ARCHIVE_OK) {
        archive_read_free(archive);
        close(owned_fd);
        return NULL;
    }

    glassdock_filtered_stream *stream = calloc(1, sizeof(*stream));
    if (stream == NULL) {
        archive_read_free(archive);
        close(owned_fd);
        return NULL;
    }
    stream->backend = GLASSDOCK_BACKEND_LIBARCHIVE;
    stream->archive = archive;
    stream->source_fd = owned_fd;
    return stream;
}

glassdock_filtered_stream *glassdock_filtered_stream_open(
    int source_fd,
    enum glassdock_filtered_stream_codec codec,
    uint64_t maximum_decoder_memory_bytes
) {
    int owned_fd = dup(source_fd);
    if (owned_fd < 0) {
        return NULL;
    }

    switch (codec) {
    case GLASSDOCK_FILTER_XZ:
        return glassdock_xz_stream_open(
            owned_fd,
            maximum_decoder_memory_bytes
        );
    case GLASSDOCK_FILTER_GZIP:
    case GLASSDOCK_FILTER_BZIP2:
        return glassdock_archive_stream_open(owned_fd, codec);
    default:
        close(owned_fd);
        return NULL;
    }
}

static ssize_t glassdock_xz_stream_read(
    glassdock_filtered_stream *stream,
    void *buffer,
    size_t capacity
) {
    if (stream->stream_finished) {
        return 0;
    }

    stream->xz.next_out = buffer;
    stream->xz.avail_out = capacity;
    while (stream->xz.avail_out > 0 && !stream->stream_finished) {
        if (stream->xz.avail_in == 0 && !stream->source_eof) {
            ssize_t bytes_read;
            do {
                bytes_read = read(
                    stream->source_fd,
                    stream->input_buffer,
                    sizeof(stream->input_buffer)
                );
            } while (bytes_read < 0 && errno == EINTR);

            if (bytes_read < 0) {
                stream->last_error = GLASSDOCK_FILTERED_STREAM_ERROR_DECODER;
                return -1;
            }
            if (bytes_read == 0) {
                stream->source_eof = 1;
            } else {
                stream->xz.next_in = stream->input_buffer;
                stream->xz.avail_in = (size_t)bytes_read;
            }
        }

        size_t input_before = stream->xz.avail_in;
        size_t output_before = stream->xz.avail_out;
        glassdock_lzma_ret result = lzma_code(
            &stream->xz,
            stream->source_eof
                ? GLASSDOCK_LZMA_FINISH
                : GLASSDOCK_LZMA_RUN
        );
        if (result == GLASSDOCK_LZMA_STREAM_END) {
            stream->stream_finished = 1;
            break;
        }
        if (result == GLASSDOCK_LZMA_MEMLIMIT_ERROR) {
            stream->last_error =
                GLASSDOCK_FILTERED_STREAM_ERROR_MEMORY_LIMIT;
            return -1;
        }
        if (result != GLASSDOCK_LZMA_OK) {
            stream->last_error = GLASSDOCK_FILTERED_STREAM_ERROR_DECODER;
            return -1;
        }

        if (input_before == stream->xz.avail_in
            && output_before == stream->xz.avail_out) {
            stream->last_error = GLASSDOCK_FILTERED_STREAM_ERROR_DECODER;
            return -1;
        }
    }

    return (ssize_t)(capacity - stream->xz.avail_out);
}

ssize_t glassdock_filtered_stream_read(
    glassdock_filtered_stream *stream,
    void *buffer,
    size_t capacity
) {
    if (stream == NULL || buffer == NULL || capacity == 0) {
        return -1;
    }
    stream->last_error = GLASSDOCK_FILTERED_STREAM_ERROR_NONE;
    if (stream->backend == GLASSDOCK_BACKEND_LIBLZMA) {
        return glassdock_xz_stream_read(stream, buffer, capacity);
    }
    ssize_t result = archive_read_data(stream->archive, buffer, capacity);
    if (result < 0) {
        stream->last_error = GLASSDOCK_FILTERED_STREAM_ERROR_DECODER;
    }
    return result;
}

enum glassdock_filtered_stream_error glassdock_filtered_stream_last_error(
    const glassdock_filtered_stream *stream
) {
    if (stream == NULL) {
        return GLASSDOCK_FILTERED_STREAM_ERROR_DECODER;
    }
    return stream->last_error;
}

void glassdock_filtered_stream_close(glassdock_filtered_stream *stream) {
    if (stream == NULL) {
        return;
    }
    glassdock_filtered_stream_destroy(stream);
}
