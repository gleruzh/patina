English | [Русский](client-settings.ru.md)

# Client settings for WebSocket-only devices

These settings let a stock RustDesk client (1.4.0 or newer, checked against
1.5.0) register with and be controlled through Patina when it can reach the
server only over `wss://<domain>:443`. The examples use `patina.example.com`;
replace it with your own domain.

Option names and UI labels below come from the 1.5.0 client source
(`flutter/lib/consts.dart`, `desktop_setting_page.dart`, the mobile
`settings_page.dart` and `server_page.dart`, `src/server/connection.rs`, and
`hbb_common/src/websocket.rs`).

> **Warning: API server must be `https://<domain>`.** The client uses
> encrypted `wss://` only when the API server starts with `https`. If you leave
> it empty or set it to `http://…`, the client tries unencrypted
> `ws://<domain>/ws/id` on port 80 instead. The proxy redirects that to HTTPS,
> the WebSocket handshake fails, and the device never comes online. If you
> enter an IP address instead of the domain as the ID server, the client goes
> straight to `ws://IP:21118`, which is not published, so that never connects
> either. Always use the domain for the ID server and `https://<domain>` for
> the API server.

## Required

Settings → Network → **ID/Relay server**:

| Field | Value | Option key |
|---|---|---|
| ID server | `patina.example.com` | `custom-rendezvous-server` |
| Relay server | `patina.example.com` | `relay-server` |
| API server | `https://patina.example.com` | `api-server` |
| Key | the server public key (below) | `key` |

Settings → Network → **Use WebSocket**: on (`allow-websocket=Y`).

On Android, open the **Settings** tab, then **ID/Relay Server** for the four
fields and the **Use WebSocket** switch in the same section.

Each field matters for a specific reason:

- **ID server and relay server**: enter the bare domain, with no port and no
  scheme. In WebSocket mode the client maps rendezvous traffic to
  `<host>/ws/id` and relay traffic to `<host>/ws/relay` (`check_ws`). An IP
  address here produces plain `ws://IP:21118`, which bypasses the proxy and TLS,
  so always use the domain. hbbs runs with `-r patina.example.com`, so the relay
  address the server hands out also resolves to `wss://patina.example.com/ws/relay`.
- **API server**: the client uses `wss://` only if `api-server` starts with
  `https`. Otherwise it connects with unencrypted `ws://`. No API server runs
  behind this URL: the proxy answers every `/api/` request with `{}`. Leave it
  that way. The heartbeat reply from `/api/heartbeat` can push config options
  (`strategy`) and disconnect sessions (`disconnect`) on every device that uses
  this server.
- **Key**: the contents of `id_ed25519.pub` in hbbs' data volume (one base64
  line). The server rejects clients without the key: hbbr runs with `-k _`,
  and hbbs enforces the key by default.
  The controller also uses the key to check the device's signed public key in
  the relay response. WebSocket mode skips the client-server KeyExchange and
  relies on TLS for the client-server leg, so the key and a valid certificate
  are both needed.
- **Use WebSocket**: when this is on, the device opens a persistent
  `wss://…/ws/id` connection, registers over it, and answers incoming sessions
  over `wss://…/ws/relay`. The client shows "NOTE: RustDesk server OSS doesn't
  include this feature." Patina does support it. With WebSocket on, only relay
  connections work (no direct P2P, no WebRTC).

The certificate must be valid for the domain and trusted by the device (SWAG's
Let's Encrypt certificate is). `allow-insecure-tls-fallback` is for test
setups only. Never set it on real devices.

### Scripted setup

On an installed client, run as root or Administrator. The option keys are the
same on every OS:

```sh
rustdesk --option custom-rendezvous-server patina.example.com
rustdesk --option relay-server patina.example.com
rustdesk --option api-server https://patina.example.com
rustdesk --option key '<contents of id_ed25519.pub>'
rustdesk --option allow-websocket Y
```

`rustdesk --option <key>` with no value prints the current value. On Windows,
use `rustdesk.exe` from the install directory.

## Recommended hardening

These devices belong to third parties, so add these on top of the password.

### Two-factor authentication

Settings → Security → **2FA** → Enable two-factor authentication. The device
owner scans the TOTP QR code. Every new incoming session then needs a code in
addition to the password. "Enable trusted devices" skips 2FA for controllers
that have already passed it. Leave it off unless the same controller connects
often.

You have to enroll 2FA in the GUI. There is no `--option` for it. On Android,
use the **2FA** section of the **Settings** tab.

### Click to approve

Settings → Security → **Password** → "Accept sessions via click"
(`approve-mode=click`). The person at the device has to accept each session in
the connection manager, so nobody can connect to an unattended machine.
"Accept sessions via both" (`approve-mode` empty) also accepts a password, so
that mode suits unattended machines. Use click-only wherever someone is at the
device.

```sh
rustdesk --option approve-mode click
```

On Android, open the **Share screen** tab, tap the ⋮ menu at the top right,
and choose "Accept sessions via click".

### ID whitelist

Settings → Security → **Use ID whitelisting** ("Only whitelisted IDs can access
me", option `id-whitelist`). Enter a comma-separated list of the controller IDs
allowed to connect. `*` wildcards work.

```sh
rustdesk --option id-whitelist '123456789,987654321'
```

On Android: **Settings** tab → **Share screen** section → **Use ID
whitelisting**.

The client checks this against the ID the controller reports about itself
(`check_id_whitelist`), so it does not replace authentication. It narrows the
set of IDs that may try a password, and failed attempts are rate-limited per
source address. Use it together with 2FA or click-to-approve, not instead of
them.

The older **Use IP Whitelisting** (`whitelist`) checks the controller's IP
address. For a WebSocket device every session comes through the relay, so that
address is whatever hbbs recorded for the controller. Controllers on dynamic or
shared addresses make it hard to keep accurate, so the ID whitelist is usually
the more practical of the two.

## What stays the same

- Clients that do not use WebSocket keep working unchanged over UDP 21116 and
  TCP 21115-21117. A UDP-mode controller can reach a WebSocket device, and a
  WebSocket controller can reach a UDP device, both through the relay.
- Online status in the address book works for WebSocket devices (hbbs answers
  `OnlineRequest` on `/ws/id`).

## Troubleshooting

- **Device never shows as online or ready.**
  - Check that the API server is exactly `https://<domain>` and that Use
    WebSocket is on.
  - Check that the ID server is the domain, not an IP address.
  - On the server, `docker logs rustdesk-hbbs` should list
    `patina.example.com` in `relay-servers=[...]`, and the proxy access log should
    show `GET /ws/id` with status 101.
- **TLS or certificate errors.** The device must trust the certificate for
  `<domain>`. Check the device clock and that SWAG's certificate includes the
  subdomain. Don't work around this with `allow-insecure-tls-fallback`.
- **"Key mismatch" or the connection is refused right after it starts.** The
  Key field must exactly match the contents of `id_ed25519.pub` on the server,
  with no extra spaces or line breaks.
- **Connection works but is slow.** WebSocket devices always go through the
  relay. That is expected. Direct P2P and WebRTC are not available in this
  mode.
- **The device ID changed.** The client generates a new ID only when the
  server answers `UUID_MISMATCH`, which happens when a different machine has
  already registered that ID. Restarting the server, the proxy or the device
  does not change the ID.
- **"Your ID is blocked by the peer."** The controller's ID is not in the
  device's ID whitelist.

## Server source code

The server is Patina, a modified version of rustdesk-server licensed under the
GNU AGPL v3. As AGPL §13 requires, the complete source code of the server you
are connecting to is available at <https://github.com/gleruzh/patina>.
