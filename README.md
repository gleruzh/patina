English | [Русский](README.ru.md)

# Patina

Patina is a small fork of the open-source rendezvous/relay server
[`rustdesk/rustdesk-server`](https://github.com/rustdesk/rustdesk-server)
(`hbbs` and `hbbr`). It lets a stock RustDesk client (1.4.0 or newer, tested
against 1.5.0) with **Use WebSocket** turned on act as a controlled device when
it can reach the server only through `wss://<domain>:443`, for example behind an
nginx reverse proxy. The device needs no UDP 21116 and no direct TCP
21115–21119.

The client is not modified. Only `hbbs` is patched; `hbbr` is upstream code.

> [!NOTE]
> Patina is an independent project. It is not affiliated with or endorsed by
> the RustDesk project or its owners. "RustDesk" is used here only to name the
> software Patina is compatible with.

## Why this fork exists

The upstream open-source `hbbs` registers devices only over UDP 21116. Over
TCP or WebSocket it answers `RegisterPk` with `NOT_SUPPORT` and closes the
socket, so a device that can only use WebSocket never becomes ready. Upstream
treats WebSocket registration as a Pro feature and closed the pull request that
added it ([rustdesk-server#657](https://github.com/rustdesk/rustdesk-server/pull/657)).
Related issues: [#677](https://github.com/rustdesk/rustdesk-server/issues/677)
(fails with UDP blocked) and
[#704](https://github.com/rustdesk/rustdesk-server/issues/704) (WebSocket
dropped after 30 s idle).

The client side already works because RustDesk Server Pro supports it. Patina
adds the missing server side and keeps the diff against upstream small.

## How it differs from upstream

Device registration over WebSocket is off by default. With the default
`WS_REGISTER=N`, Patina speaks upstream's protocol, with two exceptions that
always apply: proxy headers are trusted only from `TRUSTED_PROXY_CIDRS`, and
WebSocket connections get a 10 s handshake timeout, a 64 KiB message cap and
the `MAX_WS_CONN_PER_IP` limit. An upstream setup that relied on `hbbs`
trusting `X-Real-IP` from any peer needs `TRUSTED_PROXY_CIDRS` after switching
to Patina.

Also independent of `WS_REGISTER`: `hbbs` does not phone home. Upstream `hbbs`
sends a version check with a fingerprint of the host to `api.rustdesk.com` at
start and then daily. Patina does this only with `SOFTWARE_UPDATE_CHECK=Y`.

| Area | Upstream `hbbs` | Patina `hbbs` with `WS_REGISTER=Y` |
| --- | --- | --- |
| Device registration over WebSocket | `RegisterPk` → `NOT_SUPPORT`, socket closed | Same checks as the UDP path, then `RegisterPkResponse{OK}`; the connection stays open |
| Idle WebSocket connections | Dropped after about 30 s | The server sends an empty binary frame every 12 s (`WS_KEEPALIVE_SECS`); the client's echo refreshes the device's registration |
| PunchHole, RequestRelay, FetchLocalAddr to a WebSocket device | Sent over UDP, never arrive | Pushed down the device's WebSocket connection |
| Online status (`OnlineRequest`) on `/ws/id` | Not answered, devices always show offline | Answered; a live WebSocket device shows online |
| Two controllers behind one NAT | Both rewritten to `X-Real-IP:0`, which collide | Each gets a unique address from `X-Real-Port` or the connection id |
| `X-Real-IP` / `X-Forwarded-For` | Trusted from any peer | Trusted only from `TRUSTED_PROXY_CIDRS` (default: loopback); the last hop of `X-Forwarded-For` is used |
| Limits | — | Cap on registered WebSocket devices (`MAX_WS_PEERS`, default 10000) and on concurrent WebSocket connections per IP (`MAX_WS_CONN_PER_IP`, default 64) |

Unchanged:

- UDP registration and the TCP 21115–21117 paths for existing clients.
- Every upstream security fix up to
  [`873230e`](https://github.com/rustdesk/rustdesk-server/commit/873230e35a8805de7fd057e7eb763c46f7a174ef),
  including the bounded `PUNCH_REQS`, the 253-byte id cap and the 0600 key
  file. UDP `PunchHoleRequest` stays disabled, as upstream decided.
- `hbbr` and the relay protocol.

## Known limitations

- WebSocket devices are reached through the relay only. Direct (P2P)
  connections and WebRTC are not supported for them.
- A client that has UDP disabled but does not use WebSocket (plain TCP) is
  still unsupported. It needs a server-side key exchange that Patina does not
  implement.
- Patina is not RustDesk Server Pro. It has no web console, address book,
  user accounts or other Pro features.

## Documentation

| Document | Contents |
| --- | --- |
| [docs/ws-registration.md](docs/ws-registration.md) | Design, environment variables, reverse proxy requirements, client settings, threat model, limitations |
| [deploy/client-settings.md](deploy/client-settings.md) | Client setup for owners of WebSocket devices |
| [deploy/swag/patina.subdomain.conf](deploy/swag/patina.subdomain.conf) | nginx (SWAG) proxy config for a dedicated subdomain |
| [deploy/docker-compose.example.yml](deploy/docker-compose.example.yml) | Docker Compose example for `hbbs` and `hbbr` |
| [PATCHES.md](PATCHES.md) | The patch set and how to rebase it onto a new upstream tag |
| [tests/e2e/](tests/e2e/) | End-to-end tests and the test report |
| [docs/environment-variables.md](docs/environment-variables.md) | Upstream configuration reference (flags, env vars, config files) |
| [docs/glossary.md](docs/glossary.md) | English ↔ Russian glossary for the docs |

Each of these documents has a Russian version next to it with a `.ru.md`
suffix, except `docs/environment-variables.md`, which is upstream text.

## Building

```bash
cargo build --release
```

This produces three executables in `target/release`:

- `hbbs`: ID/rendezvous server (patched)
- `hbbr`: relay server (upstream)
- `rustdesk-utils`: CLI utilities (upstream)

The multi-stage [`Dockerfile`](Dockerfile) builds the same binaries inside
Docker. It produces one minimal image for both servers that runs as non-root
with a read-only root filesystem and no capabilities:

```bash
git submodule update --init libs/hbb_common
docker build -t patina:local .
```

Select the server with the container command (`hbbs …` or `hbbr …`). See
[deploy/docker-compose.example.yml](deploy/docker-compose.example.yml).

## Configuration

Upstream flags, environment variables and config files work unchanged; see
[docs/environment-variables.md](docs/environment-variables.md). Patina adds
the following environment variables to `hbbs`:

| Env var | Default | Purpose |
| --- | --- | --- |
| `WS_REGISTER` | `N` | `Y` enables device registration over WebSocket |
| `TRUSTED_PROXY_CIDRS` | loopback only | Peers allowed to set `X-Real-IP` / `X-Forwarded-For`. Add your Docker network CIDR when the proxy runs in another container |
| `MAX_WS_PEERS` | `10000` | Maximum registered WebSocket devices. Above it, new registrations get `SERVER_ERROR` |
| `MAX_WS_CONN_PER_IP` | `64` | Maximum concurrent WebSocket connections from one client IP |
| `WS_KEEPALIVE_SECS` | `12` | Interval of the empty keepalive frame, 5–20 s. The server tells the client a `keep_alive` of three times this value |
| `SOFTWARE_UPDATE_CHECK` | `N` | `Y` restores upstream's daily version check, which posts a fingerprint of the host to `api.rustdesk.com` |

Details are in [docs/ws-registration.md](docs/ws-registration.md).

Run `hbbs` with `-r <domain>`. Controllers are then sent to the relay through
the same domain. For WebSocket devices `-r` is required: `hbbs` forwards a
`RequestRelay` to a WebSocket device only if the relay it names is listed in
`-r`.

## Security

The devices that register with a Patina server often belong to other people.
Patina applies the same id, uuid and key ownership checks to WebSocket
registration as upstream applies to UDP, and binds an id only to the connection
that registered it. See the threat model in
[docs/ws-registration.md](docs/ws-registration.md).

By default neither server contacts a third party: there is no version check
and no telemetry. `hbbs` only resolves the `-r` names, and it health-checks
the relays when `-r` lists more than one. `hbbr` opens nothing. The audit and
a packet-capture check ([tests/egress-check.sh](tests/egress-check.sh)) are in
[Outbound connections](docs/ws-registration.md#outbound-connections).

Device owners should also turn on two-factor authentication, click-to-approve
and an ID whitelist in the client. [deploy/client-settings.md](deploy/client-settings.md)
explains how.

## License and source code

Patina is licensed under the GNU Affero General Public License v3.0, the same
license as upstream. See [LICENSE](LICENSE). Upstream copyright notices are
kept.

Section 13 of the AGPL requires that users who interact with a modified version
over a network are offered its Corresponding Source. The source of Patina is
published at <https://github.com/gleruzh/patina>. If you run Patina:

- run an unmodified tagged version, or publish your own changes under the
  AGPL-3.0 in the same way;
- give the people whose devices connect to your server a link to the source
  you run, for example together with the client settings you send them.

## Attribution

- [`rustdesk/rustdesk-server`](https://github.com/rustdesk/rustdesk-server):
  the upstream code, © open-trade / the RustDesk developers, AGPL-3.0. Patina is
  based on upstream commit `873230e35a8805de7fd057e7eb763c46f7a174ef`.
- [`ymg2006/rustdesk-server`](https://github.com/ymg2006/rustdesk-server)
  (AGPL-3.0): the design of WebSocket sinks keyed by peer id and connection id
  (newest wins, owner-checked cleanup), routing PunchHole, FetchLocalAddr and
  RequestRelay to the WebSocket sink, and `TRUSTED_PROXY_CIDRS`.
- [`bropines/rustdesk-server`](https://github.com/bropines/rustdesk-server/tree/rdpanel),
  branch `rdpanel` (AGPL-3.0): the keepalive design, an empty binary frame
  every ~12 s with the registration time refreshed on each echo.

Patina takes ideas from these forks; no code was copied from them.
[PATCHES.md](PATCHES.md#attribution) lists what was deliberately not taken.
