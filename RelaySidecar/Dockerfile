FROM docker.io/library/rust:1-alpine3.24@sha256:3c38f3f82c2f3d73da3b38e18d279393a04cb43ddded0e35088a8c3324d40900 AS builder
RUN apk add --no-cache musl-dev
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --target aarch64-unknown-linux-musl

FROM scratch
COPY --from=builder /build/target/aarch64-unknown-linux-musl/release/socktainer-port-relay /socktainer-port-relay
ENTRYPOINT ["/socktainer-port-relay"]
