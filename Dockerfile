# syntax=docker/dockerfile:1
#
# Patina: hbbs (ID/rendezvous) + hbbr (relay), built from this source tree.
#
# Build (the libs/hbb_common submodule must be checked out first):
#   git submodule update --init libs/hbb_common
#   docker build -t patina:local .
#   docker build --platform linux/amd64 -t patina:local-amd64 .   # for an x86_64 host
#
# Run: one image, two services. Select the binary with the command, e.g.
#   command: ["hbbs", "-r", "patina.example.com", "-k", "_"]
#   command: ["hbbr", "-k", "_"]
# Both write their state (id_ed25519, id_ed25519.pub, db_v2.sqlite3*) to the
# working directory /data, which must be a writable volume owned by 1000:1000.
# The root filesystem can be read-only; no capabilities are needed (all ports
# are > 1024). See deploy/ for a compose example.

# Base images are pinned by manifest-list digest (multi-arch). To bump: run
#   docker buildx imagetools inspect <image>:<tag>
# and replace both the tag and the digest.
ARG RUST_IMAGE=rust:1.99.1-slim-trixie@sha256:4df2ae8cfdfebdfc13a65da7f253b73d68983dc0339f2719bc17a279c913b13d
ARG RUNTIME_IMAGE=gcr.io/distroless/cc-debian13:nonroot@sha256:83b9b50586253821cf63ffcec87d3d94265a093ad30da232039af962dd8f4edf

FROM ${RUST_IMAGE} AS builder
ARG TARGETARCH

# make: libsodium-sys builds the bundled libsodium. libssl-dev: native-tls is
# pulled in on Linux by transitive deps (the runtime image ships libssl3).
RUN apt-get update \
 && apt-get install -y --no-install-recommends make pkg-config libssl-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

# Fail early with a clear message instead of a confusing cargo error.
RUN test -f libs/hbb_common/Cargo.toml || { \
      echo "libs/hbb_common is empty: run 'git submodule update --init libs/hbb_common' before building" >&2; \
      exit 1; }

# sqlx query! macros are checked at compile time against db_v2.sqlite3 via .env
# (DATABASE_URL), so both must stay in the build context.
RUN --mount=type=cache,id=patina-cargo-registry,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,id=patina-cargo-git,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,id=patina-target-$TARGETARCH,target=/src/target,sharing=locked \
    cargo build --release --locked --bin hbbs --bin hbbr --bin rustdesk-utils \
 && mkdir -p /out/bin /out/data \
 && cp target/release/hbbs target/release/hbbr target/release/rustdesk-utils /out/bin/

FROM ${RUNTIME_IMAGE}

LABEL org.opencontainers.image.title="patina" \
      org.opencontainers.image.description="hbbs/hbbr with WebSocket device registration (fork of rustdesk-server)" \
      org.opencontainers.image.licenses="AGPL-3.0"

COPY --from=builder /out/bin/ /usr/local/bin/
# Empty state dir owned by the runtime user, so a fresh named volume mounted
# here inherits 1000:1000. Bind mounts must be chowned on the host instead.
COPY --from=builder --chown=1000:1000 /out/data /data

USER 1000:1000
WORKDIR /data
VOLUME ["/data"]

# 21115 NAT test, 21116 tcp+udp rendezvous, 21117 relay, 21118 hbbs ws, 21119 hbbr ws
EXPOSE 21115 21116 21116/udp 21117 21118 21119

CMD ["hbbs"]
