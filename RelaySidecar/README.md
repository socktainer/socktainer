# Socktainer reverse published-port relay

This directory is the auditable source for the static Linux/arm64 relay image
embedded in Socktainer.

The guest sidecar listens on one Unix-domain socket which Apple Container publishes to
the host with `publishedSockets`. Socktainer connects only to that local host socket;
it never opens a connection to a guest IP. Accepted localhost TCP connections and UDP
datagrams are multiplexed over this stream. The sidecar opens the final connection to
the target container from inside the custom network.

Each accepted host connection starts with a fixed 26-byte `SKTR` v1 preface: transport,
address family, reserved zero byte, network-order target port, and a 16-byte address.
TCP becomes a raw full-duplex byte stream after the preface and preserves half-close.
UDP carries each datagram as a network-order `u16` length followed by its bytes. The
published host socket must live in Socktainer's `0700` runtime directory and its
`PublishSocket.permissions` must be explicitly set to `0600` (the Apple CLI default
observed in testing was broader and must not be relied on).

Environment:

- `SOCKTAINER_RELAY_SOCKET`: absolute guest Unix-domain socket path
- `SOCKTAINER_RELAY_CIDRS`: comma-separated custom-network CIDRs; destinations outside them are rejected
- `SOCKTAINER_RELAY_MAX_SESSIONS`: concurrent published-socket connections (default 1024)

Run native protocol tests with `cargo test`. Build the static Linux arm64 scratch OCI
image with `container build --platform linux/arm64 -t socktainer-port-relay:prototype .`.
