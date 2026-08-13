# Parse BusyBox dd's C-locale summary and report binary MiB per second.
# Expected input resembles:
#   536870912 bytes (512.0MB) copied, 0.250000 seconds, 2.0GB/s

/^[[:space:]]*[0-9]+ bytes .* copied,[[:space:]]*[0-9.]+ (s|sec|secs|second|seconds),/ {
    bytes = $1
    summary = $0
    sub(/^.* copied,[[:space:]]*/, "", summary)
    split(summary, fields, /[[:space:]]+/)
    elapsed = fields[1]
    duration_unit = fields[2]
    sub(/,$/, "", duration_unit)

    if (bytes !~ /^[0-9]+$/ || elapsed !~ /^[0-9]+([.][0-9]+)?$/ || elapsed <= 0) {
        next
    }
    if (duration_unit !~ /^(s|sec|secs|second|seconds)$/) {
        next
    }
    printf "%.6f\n", bytes / 1048576 / elapsed
    found = 1
    exit
}

END {
    if (!found) {
        exit 1
    }
}
