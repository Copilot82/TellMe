FROM rust:1.97.1-bookworm@sha256:77fac8b98f9f46062bb680b6d25d5bcaabfc400143952ebc572e924bcbedc3fa AS builder

WORKDIR /workspace/backend-rust

COPY backend-rust/Cargo.toml backend-rust/Cargo.lock ./
COPY backend-rust/crates ./crates
COPY docker/init-scripts ../docker/init-scripts

RUN cargo build --release --locked --bin tellme-server

FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171

WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates wget \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /workspace/backend-rust/target/release/tellme-server /usr/local/bin/tellme-server

ENV TELLME_RUST_BIND_ADDR=0.0.0.0:3100

ENTRYPOINT []
EXPOSE 3100

CMD ["tellme-server"]
