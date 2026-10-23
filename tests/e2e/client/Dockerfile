# Stock RustDesk client 1.5.0 on a headless X11 desktop (Xvfb + openbox).
# Used as the WS-only target device, the UDP-mode device and the controller.
# The client binary is the unmodified upstream release .deb, verified by sha256.
FROM debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251

ARG TARGETARCH
ARG RUSTDESK_VERSION=1.5.0
ARG RUSTDESK_SHA256_arm64=1f2fc9be8321c10347aa33cb13198c6a956aec272c5e58ac81f4c0ef04037df3
ARG RUSTDESK_SHA256_amd64=4e2b9701d25a7ef373f3d09bda584a37d6902f97a6ab15f2e86d4a5783e2a0ec

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xvfb openbox x11-utils x11-xserver-utils xdotool \
        imagemagick iptables iproute2 procps dbus-x11 netcat-openbsd \
        libayatana-appindicator3-1 libegl1 libgl1 at-spi2-core \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "$TARGETARCH" in \
      arm64) deb_arch=aarch64; sha="$RUSTDESK_SHA256_arm64" ;; \
      amd64) deb_arch=x86_64;  sha="$RUSTDESK_SHA256_amd64" ;; \
      *) echo "unsupported arch $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/rustdesk.deb \
      "https://github.com/rustdesk/rustdesk/releases/download/${RUSTDESK_VERSION}/rustdesk-${RUSTDESK_VERSION}-${deb_arch}.deb"; \
    echo "${sha}  /tmp/rustdesk.deb" | sha256sum -c -; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/rustdesk.deb; \
    rm -rf /var/lib/apt/lists/* /tmp/rustdesk.deb

# The desktop runs as an unprivileged user; root is only used by the
# entrypoint to install the egress firewall before dropping privileges.
RUN useradd -m -u 1000 -s /bin/bash rd \
    && rm -f /etc/machine-id /var/lib/dbus/machine-id
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY lib.sh /usr/local/bin/rd-lib.sh
# Test-only logind stand-in, see the comment in the file.
COPY loginctl /usr/local/bin/loginctl
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/loginctl
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
