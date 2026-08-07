#ifndef SOCKTAINER_FILTERED_STREAM_H
#define SOCKTAINER_FILTERED_STREAM_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef struct socktainer_filtered_stream socktainer_filtered_stream;

enum socktainer_filtered_stream_codec {
    SOCKTAINER_FILTER_GZIP = 1,
    SOCKTAINER_FILTER_BZIP2 = 2,
    SOCKTAINER_FILTER_XZ = 3,
};

enum socktainer_filtered_stream_error {
    SOCKTAINER_FILTERED_STREAM_ERROR_NONE = 0,
    SOCKTAINER_FILTERED_STREAM_ERROR_DECODER = 1,
    SOCKTAINER_FILTERED_STREAM_ERROR_MEMORY_LIMIT = 2,
};

/// Opens a duplicate of `source_fd` as a raw, decompressed byte stream. The
/// caller retains ownership of `source_fd`; the returned stream owns its dup.
socktainer_filtered_stream *socktainer_filtered_stream_open(
    int source_fd,
    enum socktainer_filtered_stream_codec codec,
    uint64_t maximum_decoder_memory_bytes
);

/// Returns decompressed bytes, 0 at end of stream, or -1 on decoder/read error.
/// Call `socktainer_filtered_stream_last_error` after -1 to distinguish an
/// invalid stream from a decoder-memory-limit rejection.
ssize_t socktainer_filtered_stream_read(
    socktainer_filtered_stream *stream,
    void *buffer,
    size_t capacity
);

enum socktainer_filtered_stream_error socktainer_filtered_stream_last_error(
    const socktainer_filtered_stream *stream
);

void socktainer_filtered_stream_close(socktainer_filtered_stream *stream);

#endif
