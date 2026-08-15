#ifndef GLASSDOCK_FILTERED_STREAM_H
#define GLASSDOCK_FILTERED_STREAM_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef struct glassdock_filtered_stream glassdock_filtered_stream;

enum glassdock_filtered_stream_codec {
    GLASSDOCK_FILTER_GZIP = 1,
    GLASSDOCK_FILTER_BZIP2 = 2,
    GLASSDOCK_FILTER_XZ = 3,
};

enum glassdock_filtered_stream_error {
    GLASSDOCK_FILTERED_STREAM_ERROR_NONE = 0,
    GLASSDOCK_FILTERED_STREAM_ERROR_DECODER = 1,
    GLASSDOCK_FILTERED_STREAM_ERROR_MEMORY_LIMIT = 2,
};

/// Opens a duplicate of `source_fd` as a raw, decompressed byte stream. The
/// caller retains ownership of `source_fd`; the returned stream owns its dup.
glassdock_filtered_stream *glassdock_filtered_stream_open(
    int source_fd,
    enum glassdock_filtered_stream_codec codec,
    uint64_t maximum_decoder_memory_bytes
);

/// Returns decompressed bytes, 0 at end of stream, or -1 on decoder/read error.
/// Call `glassdock_filtered_stream_last_error` after -1 to distinguish an
/// invalid stream from a decoder-memory-limit rejection.
ssize_t glassdock_filtered_stream_read(
    glassdock_filtered_stream *stream,
    void *buffer,
    size_t capacity
);

enum glassdock_filtered_stream_error glassdock_filtered_stream_last_error(
    const glassdock_filtered_stream *stream
);

void glassdock_filtered_stream_close(glassdock_filtered_stream *stream);

#endif
