# Patina: RustDesk server (hbbs, hbbr) with WebSocket device registration

Patina is a small fork of [`rustdesk/rustdesk-server`](https://github.com/rustdesk/rustdesk-server) (`hbbs` and `hbbr`). It lets a stock RustDesk client (1.4.0 or newer) with **Use WebSocket** turned on act as a controlled device when it can reach the server only through `wss://<domain>:443`, for example behind an nginx reverse proxy. The client is not modified. Only `hbbs` is patched; `hbbr` is upstream code.

Patina is an independent project. It is not affiliated with or endorsed by the RustDesk project or its owners.

**The full documentation is on GitHub: [README.md](README.md).** This page is only a short summary.

## Source and licence

Licensed under the GNU Affero General Public License v3.0 (AGPL-3.0-only), see [LICENSE](LICENSE). The complete corresponding source of every image, including the patches to the upstream code, is at <https://github.com/gleruzh/patina>. The image's `org.opencontainers.image.revision` label names the exact commit it was built from, and `io.patina.upstream.commit` the rustdesk-server commit it is based on. If you use Patina over a network, this is the source offer required by section 13 of the AGPL.

## Platforms

`linux/amd64` and `linux/arm64`. The images are built on native runners, one image for both servers; select the server with the container command (`hbbs ...` or `hbbr ...`). The container runs as a non-root user and works with a read-only root filesystem and no capabilities.

## Tags

| Tag | Meaning |
|---|---|
| `X.Y.Z` | A release, for example `0.1.0` |
| `X.Y` | The newest release of that minor version |
| `latest` | The newest release |
| `edge` | A manual build of the `master` branch (not a release) |
| `sha-<short>` | The build of one commit |

For production, pin the image by digest: `<namespace>/patina:X.Y.Z@sha256:...`. The digest is the same on Docker Hub and on `ghcr.io/gleruzh/patina`.

## Running

Follow [deploy/docker-compose.example.yml](https://github.com/gleruzh/patina/blob/master/deploy/docker-compose.example.yml), which runs `hbbs` and `hbbr` behind an nginx (SWAG) reverse proxy. The shape of it, with `patina.example.com` replaced by your domain:

```yaml
services:
    hbbs:
        image: <namespace>/patina:X.Y.Z
        command: hbbs -r patina.example.com
        user: "1000:1000"
        environment:
            - WS_REGISTER=Y
            - TRUSTED_PROXY_CIDRS=172.30.21.10/32   # the address of your reverse proxy
        ports:
            - 21115:21115
            - 21116:21116
            - 21116:21116/udp
        volumes:
            - ./rustdesk:/data   # keys and database; writable by 1000:1000
        read_only: true
        cap_drop: [ALL]
    hbbr:
        image: <namespace>/patina:X.Y.Z
        command: hbbr -k _
        user: "1000:1000"
        ports:
            - 21117:21117
        volumes:
            - ./rustdesk:/data
        read_only: true
        cap_drop: [ALL]
```

`<namespace>` is the Docker Hub account name in the address of this page. Ports 21118 and 21119 (WebSocket) are never published: only the reverse proxy reaches them. `-r` is required for WebSocket devices.

Environment variables of `hbbs` that Patina adds:

| Variable | Default | Purpose |
|---|---|---|
| `WS_REGISTER` | `N` | `Y` enables device registration over WebSocket |
| `TRUSTED_PROXY_CIDRS` | loopback only | Peers allowed to set `X-Real-IP` and `X-Forwarded-For` |
| `MAX_WS_PEERS` | `10000` | Maximum registered WebSocket devices |
| `MAX_WS_CONN_PER_IP` | `64` | Maximum concurrent WebSocket connections from one client IP |
| `WS_KEEPALIVE_SECS` | `12` | Interval of the keepalive frame, 5 to 20 seconds |
| `SOFTWARE_UPDATE_CHECK` | `N` | `Y` restores upstream's daily version check, which sends a host fingerprint to `api.rustdesk.com` |

Upstream flags and variables work unchanged. Details: [docs/ws-registration.md](https://github.com/gleruzh/patina/blob/master/docs/ws-registration.md), [docs/environment-variables.md](https://github.com/gleruzh/patina/blob/master/docs/environment-variables.md) and [deploy/client-settings.md](https://github.com/gleruzh/patina/blob/master/deploy/client-settings.md) for the client side.

## Verify the image

Every release digest is signed with cosign (keyless) and carries a build provenance attestation:

```shell
cosign verify <namespace>/patina@sha256:<digest> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/gleruzh/patina/\.github/workflows/publish\.yml@refs/(heads/master|tags/v[0-9]+\.[0-9]+\.[0-9]+)$'

gh attestation verify oci://ghcr.io/gleruzh/patina@sha256:<digest> --repo gleruzh/patina
```

## Credits

Patina builds on [RustDesk](https://github.com/rustdesk/rustdesk-server) by the RustDesk team, AGPL-3.0.
