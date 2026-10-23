English | [Русский](ws-registration.ru.md)

# WebSocket device registration

Patina is a small fork of the open-source RustDesk server
([rustdesk/rustdesk-server](https://github.com/rustdesk/rustdesk-server),
AGPL-3.0). Its main change is in `hbbs`: a **stock client with "Use
WebSocket" enabled can be the controlled device** while the only path it has
to the server is `wss://<domain>:443` through a reverse proxy. It needs no
UDP 21116 and no direct TCP 21115-21119. Patina also turns off upstream's
version check to `api.rustdesk.com` (see
[Outbound connections](#outbound-connections)).

Nothing changes on the client. The stock client (1.4.0 or newer, checked
against the 1.5.0 source) already speaks this protocol, because the Pro server
supports it. `hbbr` is unchanged
too, since it already accepts WebSocket.

Upstream's OSS `hbbs` registers devices only over UDP. Over TCP/WebSocket it
answers `RegisterPk` with `NOT_SUPPORT` and closes the socket, so a
WebSocket-only device never becomes "ready" (see rustdesk-server#657, #677
and #704).

## How it works

All of this is active only with `WS_REGISTER=Y`. With the default `N`, hbbs
speaks upstream's protocol, apart from the proxy-header hardening described
under [Addresses behind a proxy](#addresses-behind-a-proxy).

```text
device (WS mode)             nginx :443            hbbs :21118
  | wss /ws/id  RegisterPk{id,uuid,pk} ------------------> | same checks as UDP RegisterPk
  | <---------------------- RegisterPkResponse{OK,keep_alive=36}
  |                          (connection stays open, ws_peers[id] = this conn)
  | <---------------------------------- empty binary frame  every 12 s
  | empty binary frame (echo) --------------------------> | last_reg_time = now
  ...
controller  PunchHoleRequest{id, licence_key} ---------> |
  | <------------------------------------------ PunchHole  (pushed on the device's stream)
device: new wss /ws/id   RelayResponse{socket_addr,uuid,relay,id} --> | signs IdPk with the server key
controller <-------------------------------- RelayResponse{pk = signed IdPk}
device and controller ----> hbbr (wss /ws/relay, or tcp 21117)  paired by uuid
```

* **Writer task.** After the WebSocket handshake each connection gets a
  task that owns the sink. Everything else sends through a bounded channel
  (32 frames, `try_send`; a frame is dropped when the channel is full), so no
  lock is ever held while a frame is written. Once the connection has
  registered, the task sends an empty binary frame every `WS_KEEPALIVE_SECS`.
* **Registration.** `RegisterPk` goes through the same function as over UDP:
  id length, IP blocker, uuid/pk ownership and `UUID_MISMATCH` rules, the
  `reg_pk` throttle, `IP_CHANGES` and `update_pk`. On `OK` the connection
  becomes the device's route, `socket_addr` and `last_reg_time` are set, and
  the reply carries `keep_alive` (3 × the keepalive interval, 36 s by
  default). The client reconnects after 1.5 × `keep_alive` with nothing
  received, which is 54 s. Other results are sent as over UDP and the
  connection stays open, because the client retries every 15 s and, after
  `UUID_MISMATCH`, regenerates its id and retries.
* **One id per connection.** After `OK`, a `RegisterPk` for a different id
  closes the connection. A newer connection that registers the same id (and
  passes the uuid/pk checks) replaces the old one, and the old one is closed.
  A replaced connection cannot take the id back: until its reader stops, its
  `RegisterPk` closes it, and its heartbeats and `RegisterPeer` do nothing.
* **Heartbeat.** An empty frame from the connection that owns the id
  refreshes `last_reg_time`. hbbs's 30 s read timeout stays, and the 12 s
  echo satisfies it. A silent device is dropped after 30 s.
* **`RegisterPeer`** is accepted only as a refresh for the id this
  connection registered with `RegisterPk`. It never binds an id: an unbound
  `RegisterPeer` gets `request_pk=true` and changes nothing. (Some forks let
  `RegisterPeer` bind any id to a connection, which is an id hijack.)
* **Routing.** `PunchHole` and `FetchLocalAddr` (built by
  `handle_punch_hole_request`) and `RequestRelay` go down the device's
  WebSocket when it has one. Otherwise hbbs uses UDP as upstream does. A WS
  device whose queue is full is not tried over UDP. In WebSocket mode the
  device always answers by opening a new `/ws/id` connection that sends
  `RelayResponse`, then connects to hbbr over `wss://<domain>/ws/relay`.
* **`RequestRelay` to a WS device** names its own relay server and carries
  no licence key. It is forwarded only if that relay is one of `-r`, and
  refused when `-r` is not set. Otherwise anybody who knows a device id could
  make the device connect to a host of their choosing and learn its address.
  A WS device never needs `RequestRelay`, because it relays on `PunchHole`.
* **Online status.** The client sends `OnlineRequest` to `/ws/id` in WS mode,
  and hbbs answers it there (upstream answers it only on 21115, so all dots
  showed offline). A WS device counts as online when its `last_reg_time` is
  fresh, so it is also online for queries on 21115.
* **Cleanup.** When the reader of a registered connection ends, the route is
  removed if this connection still owns it, and `last_reg_time` is expired
  so the device shows offline at once rather than after 30 s.
* Unchanged: `ALWAYS_USE_RELAY`, the licence-key check on
  `PunchHoleRequest`, the disabled UDP `PunchHoleRequest`/`PunchHoleSent`/
  `LocalAddr` (upstream's anti-reflection fixes), `MAX_PUNCH_REQUESTS`, and
  the 253-byte id cap.

The new code lives in `src/ws_peers.rs`; `src/rendezvous_server.rs` only
calls into it (see [PATCHES.md](../PATCHES.md)).

### Addresses behind a proxy

Upstream trusted `X-Real-IP` / `X-Forwarded-For` from anyone who could reach
21118, and rewrote the address to `IP:0`. That let a direct client choose its
IP (and dodge the IP blocker), and it made two controllers behind one NAT
collide in `tcp_punch`, so one of them got the other's answer.

Now:

* The headers are used only when the TCP peer is in `TRUSTED_PROXY_CIDRS`
  (loopback is always trusted). From anyone else they are ignored and logged
  (at most one warning a minute, with a count).
* `X-Real-IP` must appear once; from `X-Forwarded-For` only the last hop of
  the last line counts. When both are present they must agree. Anything
  unusable or contradictory falls back to the proxy's own address (fail
  closed) and is logged. So a client cannot pick its IP by adding the one
  header its proxy does not manage.
* The port is `X-Real-Port` (nginx `$remote_port`) when present, else one
  derived from the connection id. It is only a per-connection key; clients
  use just the IP.

## Configuration

Environment variables (also read from `.env` or the `-c` file, like
upstream's):

| Variable | Default | Meaning |
| --- | --- | --- |
| `WS_REGISTER` | `N` | `Y` enables registration, heartbeat and online status over WebSocket |
| `TRUSTED_PROXY_CIDRS` | (loopback only) | Comma/space separated CIDRs or IPs whose `X-Real-IP` / `X-Forwarded-For` / `X-Real-Port` are used. **Set this to the docker network of the proxy**, e.g. `172.20.0.0/16`, or every client looks like the proxy. Invalid entries are logged and skipped. |
| `WS_KEEPALIVE_SECS` | `12` | Interval of the empty keepalive frame, clamped to 5..20. `keep_alive` sent to the client is 3 × this. |
| `MAX_WS_PEERS` | `10000` | Devices registered over WebSocket at once. Above it, `RegisterPk` gets `SERVER_ERROR` and the connection is closed (an id that is already registered can still move to a new connection). |
| `MAX_WS_CONN_PER_IP` | `64` | Concurrent WebSocket connections per client IP (after proxy resolution). Raise it if many devices share one public IP. |
| `SOFTWARE_UPDATE_CHECK` | `N` | `Y` restores upstream's daily version check, a POST to `https://api.rustdesk.com/version/latest` with a fingerprint of the host. Independent of `WS_REGISTER`. See [Outbound connections](#outbound-connections). |

Other settings that matter here:

* `-r <domain>` (`RELAY_SERVERS`): the relay that devices and controllers are
  told to use. Set it to the public name, e.g. `-r patina.example.com`. hbbs
  drops names it cannot resolve at start, so the name must resolve inside the
  container. It is also the allow-list for `RequestRelay` to WS devices.
* Key: keep it enforced (`-k _` on hbbr; hbbs enforces its key by default).
* hbbs's WebSocket port is `port + 2` (21118) and hbbr's is 21119. **Do not
  publish them**: only the proxy should reach them.

The connection limits also apply when `WS_REGISTER=N`: the 10 s handshake
timeout, the 64 KiB message cap, and `MAX_WS_CONN_PER_IP`. So does the proxy
header rule. An upstream setup that relied on hbbs trusting `X-Real-IP` from
any peer needs `TRUSTED_PROXY_CIDRS` after switching to Patina.

If `TRUSTED_PROXY_CIDRS` does not cover the proxy, hbbs logs `Ignoring
X-Real-IP/X-Forwarded-For from untrusted peer ...` and every WebSocket client
appears to come from the proxy's address. Then all devices share one IP
budget:

* `MAX_WS_CONN_PER_IP` (64 connections);
* upstream's IP blocker, which answers `TOO_FREQUENT` once one address
  registers too often or too many different ids;
* the `IP_CHANGES` bookkeeping.

Fix the setting rather than raising the limits.

## Reverse proxy

The proxy configuration is
[`deploy/swag/patina.subdomain.conf`](../deploy/swag/patina.subdomain.conf), a
linuxserver/SWAG proxy-conf for a dedicated subdomain. Use it as the nginx
snippet for other setups too. hbbs depends on these parts of it:

* `location = /ws/id` goes to `hbbs:21118` and `location = /ws/relay` goes to
  `hbbr:21119`, with the Upgrade headers.
* `X-Real-IP $remote_addr`, `X-Real-Port $remote_port` and
  `X-Forwarded-For $remote_addr` **overwrite** what the client sent. Never
  append the client's value. If the proxy only appends to `X-Forwarded-For`
  and leaves `X-Real-IP` alone, a client can add an `X-Real-IP` that disagrees
  with the last hop. hbbs then falls back to the proxy address (see
  [Addresses behind a proxy](#addresses-behind-a-proxy)).
* `proxy_read_timeout 240`. That is far above the 12 s keepalive, so the
  timeout only fires when the peer is dead. nginx's default of 60 s would also
  work, but leaves little margin.
* `location /api/` answers `{}`. The client needs `api-server=https://...`
  only to choose `wss://`. No API runs behind it.
* Everything else gets 404.

The proxy must reach hbbs and hbbr on their docker network. For SWAG, join it
to that network. Set `TRUSTED_PROXY_CIDRS` on hbbs to that network's subnet.
[`deploy/docker-compose.example.yml`](../deploy/docker-compose.example.yml)
shows the whole setup.

## Client settings (WebSocket devices)

[`deploy/client-settings.md`](../deploy/client-settings.md) has the full
settings, the scripted setup, the recommended hardening and troubleshooting.
In short:

* ID server = relay server = `<domain>`, never an IP address. An IP address
  gives plain `ws://IP:21118`, which bypasses the proxy and TLS.
* Set API server to `https://<domain>`. The client uses `wss://` only when the
  API server starts with `https`.
* Key = the server public key (`id_ed25519.pub`).
* Use WebSocket = on (`allow-websocket=Y`).
* Leave `allow-insecure-tls-fallback` off. In WebSocket mode the client skips
  the rendezvous key exchange and relies on TLS for that hop.
* These are third parties' machines, so also turn on 2FA, click-to-approve
  (`approve-mode=click`) and the ID whitelist (`id-whitelist`, new in 1.5.0).

An IP whitelist on the device checks the controller address that hbbs put
into the `PunchHole` (for a WebSocket controller, the address that resolved
through the proxy headers). It does not check hbbr's address. So it is only
as reliable as `TRUSTED_PROXY_CIDRS`.

Controllers can use either mode. A WebSocket controller works through the
same proxy. A classic UDP/TCP controller works through the published
21115-21117 ports.

## Threat model

What is protected: which connection receives traffic for a device id (and
with it the ability to receive connection attempts for that device); the IP
addresses of the devices; and availability of the rendezvous service. Remote
sessions themselves are end-to-end encrypted between the peers, and the
controller checks the device key signed by the server key. A compromised
rendezvous path can deny service, but it cannot read sessions.

| Threat | Mitigation |
| --- | --- |
| Take over a registered id over WebSocket | The same uuid/pk ownership rules as UDP: a different uuid gets `UUID_MISMATCH` and the owner keeps the route; the uuid is never sent to controllers. Registration over WS is exactly as strong as upstream's UDP registration, and not stronger: a first registration of an unknown id is first come, first served, as upstream. |
| Bind an id with `RegisterPeer` | Impossible: `RegisterPeer` is only a refresh for the id the same connection already registered with `RegisterPk`. |
| Keep someone else's id "online" | Heartbeats count only from the connection that owns the id. |
| Kick a device off by reconnecting | Replacing the route needs a `RegisterPk` that passes the uuid/pk checks, as above. |
| Spoof the client IP (to evade the IP blocker or pollute logs) | Proxy headers only from `TRUSTED_PROXY_CIDRS`; repeated, unparsable or disagreeing headers fail closed to the proxy address. 21118/21119 must not be published. |
| Learn a WS device's IP | WS devices always relay, so controllers see only hbbr. `RequestRelay` to a WS device must name a relay from `-r`. `FetchLocalAddr` is answered with a relay as well. |
| Exhaust memory / connections | Bounded per-connection channel; `MAX_WS_PEERS`; `MAX_WS_CONN_PER_IP`; 10 s handshake timeout; 64 KiB message cap; 30 s read timeout for silent connections; upstream's IP blocker and `reg_pk` throttle on `RegisterPk`. No map lock is held across `.await`. |
| Identify or track the server host from outside | hbbs does not phone home. Upstream's version check, which sends a host fingerprint to `api.rustdesk.com` at start and then daily, runs only with `SOFTWARE_UPDATE_CHECK=Y`. See [Outbound connections](#outbound-connections). |
| Intercept the rendezvous hop | TLS to the proxy (the client skips KeyExchange in WS mode). The proxy-to-hbbs hop is plain HTTP on the docker network. A MITM without the server key cannot forge the signed device key, but can see metadata and deny service. |

Accepted risks:

* `RegisterPk` is not gated by the server key, on UDP or WS, as upstream.
  Anyone can register a new id; the key gates connection requests
  (`PunchHoleRequest`).
* `RequestRelay` carries no licence key, as upstream, so it cannot be
  authenticated. For WS devices it is restricted to `-r` relays; for UDP
  devices it is upstream's behaviour.
* Loopback is always a trusted proxy, so a process inside the hbbs container
  could set the headers.
* hbbr is unchanged and still trusts `X-Real-IP` from whoever reaches 21119.
  Keep 21119 unpublished.
* hbbs logs device ids and client IPs, as upstream does.
* Whoever sends a `RelayResponse` or `PunchHoleSent` over TCP/WebSocket picks
  the controller it goes to by address, as upstream. Patina makes these
  addresses unique per connection (`X-Real-Port` or the connection id instead
  of `IP:0`). That stops two controllers behind one NAT from getting each
  other's answers. The addresses are still not secret. A forged answer can
  point a waiting controller at another relay. It cannot impersonate the
  device, because the controller checks the device key signed by the server
  key.

## Outbound connections

These are the connections hbbs and hbbr open on their own, as opposed to
replies on a socket a client opened. The list comes from reading `src/` and the
hbb_common code that the server path reaches (`tcp.rs`, `lib.rs`,
`fingerprint.rs`, `config.rs`).

| What | When | Verdict |
| --- | --- | --- |
| **Version check**: HTTPS POST to `api.rustdesk.com/version/latest` (`common::check_software_update` → `hbb_common::version_check_request`). The body has the OS distribution and version (sysinfo), the arch, `typ=rustdesk-server` and `device_id`. `device_id` is a keyed SHA-512 over the CPU brand and core counts, total memory, OS, arch, the RustDesk ID from hbb_common's client `Config` (`Config::get_id()`, generated from the MAC address when none is stored) and the MAC address. The machine uid is not hashed; it only decrypts the stored `Config`. | hbbs start, then every 24 h | **Off by default.** Only with `SOFTWARE_UPDATE_CHECK=Y`. Upstream ran it unconditionally, so it identified the host to a third party, and all it gave back was an info log line about a newer release. Errors are logged only at debug level. |
| DNS lookup of the `-r` relay names (and of the deprecated `-R` rendezvous names) via the system resolver | hbbs start; when the loopback console runs `relay-servers`; on a `ConfigureUpdate` from loopback | Expected: operator configuration. A name that does not resolve is dropped. |
| TCP connect to each `-r` relay on 21117, with a DNS lookup each time (`check_relay_servers`, a health check) | every 3 s, **only if `-r` lists more than one relay** | Expected: operator-chosen hosts. With a single `-r`, as in deploy/, it never runs. |
| UDP `RegisterPeer` to hbbs's own UDP port on loopback (`test_hbbs`) | every second, unless `TEST_HBBS=no` | Local only. It never leaves the host. |
| UDP datagrams to a registered device's address: `PunchHole`, `RequestRelay`, `FetchLocalAddr` forwarded to UDP devices; register replies | when a client asks | Protocol traffic. It goes to addresses that clients registered, as upstream. WebSocket devices get these on their own connection instead. |
| TCP/WebSocket messages to controllers | when a client asks | Only on connections the clients opened (`tcp_punch`). hbbs never dials a client. |
| `local_ip_address::local_ip()` | hbbs start, only with `--mask` | Reads the interface list from the kernel. No packet. |
| hbb_common `Config` | hbbs and hbbr | With defaults, only `get_any_listen_addr` (a constant) and, on Windows, `icon_path`. No config file is loaded and no proxy is used. With `SOFTWARE_UPDATE_CHECK=Y` the fingerprint calls `Config::get_id()`. That loads the client `Config`, decrypted with the machine uid, and if it holds no id it generates one and saves it. This is local only and sends no packet. |
| hbbr | — | Opens nothing. It only accepts on 21117/21119 and pairs those connections. It never called the version check. |
| `rustdesk-utils` (the third binary in the image) | only when run by hand | Its `doctor` command does DNS lookups and TCP connects to the server you name. Neither server runs it. |

[`tests/egress-check.sh`](../tests/egress-check.sh) checks this from outside.
It runs the image on an `--internal` docker network with tcpdump in the
server's network namespace, and points `api.rustdesk.com` at a local sink.
With defaults, hbbs (`-r` set to one relay) and hbbr send no TCP or UDP
packet. With `SOFTWARE_UPDATE_CHECK=Y` the capture shows the SYN to the sink,
which proves the check would have caught it. Without this change hbbs sent
that SYN at start.

## Limitations

* **Relay only** for WS devices: no hole punching, no direct or LAN
  connections. The client forces relay in WS mode anyway.
* **No WebRTC/ICE**: hbbs does not forward offers, answers or candidates
  (upstream OSS does not either).
* **Plain TCP clients with UDP disabled (not WS) are still unsupported**:
  they need the server's rendezvous `KeyExchange`, which OSS hbbs does not
  implement.
* Registration state is in memory in a single hbbs. After a restart, devices
  reconnect and register again (same id, same key; see the test report).
* No Pro features: the API server, address book, device groups and so on
  are not provided.

## Credits and license

Patina is licensed under the GNU AGPL v3, like upstream (see
[LICENSE](../LICENSE)). Upstream's copyright notices are kept. The new files
carry their own headers.

Two other AGPL-3.0 forks supplied the design ideas. No code was copied from
them:

* [ymg2006/rustdesk-server](https://github.com/ymg2006/rustdesk-server):
  WebSocket routes keyed by peer id plus connection id (newest wins,
  owner-checked cleanup), routing `PunchHole` / `FetchLocalAddr` /
  `RequestRelay` to the WebSocket, and `TRUSTED_PROXY_CIDRS`.
* [bropines/rustdesk-server](https://github.com/bropines/rustdesk-server),
  branch `rdpanel`: the empty binary keepalive frame that the client echoes,
  which refreshes `last_reg_time`.

[PATCHES.md](../PATCHES.md#attribution) lists what was deliberately not
taken from them.
