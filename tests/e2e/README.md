English | [Русский](README.ru.md)

# End-to-end bench: stock RustDesk 1.5.0 client as a WebSocket-only device

A disposable Docker bench that runs the **unmodified** RustDesk 1.5.0 Linux
client against hbbs/hbbr behind nginx TLS, with the device firewalled so the
only thing it can reach is `tcp/443` on the proxy. The hbbs image is a
parameter (`HBBS_IMAGE`). The same matrix runs against stock upstream (the
baseline, where the bug should show) and against the patched build.

Everything is named `patina-e2e-*` and removed by name (`scripts/down.sh`).
Nothing is pruned, and nothing is installed on the host. The scripts need only
`docker` (with compose v2), `bash`, `openssl` and `git`.

## Topology

```text
              wan 10.231.1.0/24                     ctl 10.231.2.0/24
 ws-device .21 ──┐ (iptables: only tcp→.10:443)    ┌── ws-controller .21 (only tcp→.10:443)
 udp-device .22 ─┤                                 ├── udp-controller .22
 nat-router .30 ─┤  nginx .10  (TLS, rd.e2e.test)  │
   │ MASQUERADE  ├─ edge  .11  ← hbbs + hbbr share ┤
   │             │      │      this netns           │
   │             │  proxy 10.231.4.0/24: nginx .10 ─ edge .11 only
   │             │  (nginx → hbbs:21118 / hbbr:21119; TRUSTED_PROXY_CIDRS)
 lan 10.231.3.0/24 (default route via nat-router)
   nat-device-a .21, nat-device-b .22  (WS-only, default route via router)
```

* **edge** owns the server IP. hbbs and hbbr run in its network namespace, so
  one address serves 21115–21119, like the production host, and hbbs can
  restart without affecting hbbr.
* nginx reaches hbbs and hbbr only over the `proxy` network (10.231.4.0/24,
  nginx and edge only), so hbbs sees every proxied connection as coming from
  10.231.4.10. This mirrors a reverse proxy joining `rustdesk-net` in production. A
  direct connection to edge:21118 from wan or ctl is not from a trusted proxy.
* WS clients resolve `rd.e2e.test` to nginx: `/ws/id` goes to hbbs:21118 and
  `/ws/relay` goes to hbbr:21119. `/api/` and everything else return 404.
  UDP-mode clients resolve the same name to edge directly, which is how the
  production host looks to a classic client.
* TLS uses a throwaway local CA. The client trusts it through the system store
  (`update-ca-certificates`), and `allow-insecure-tls-fallback` stays **off**.
* Client settings come from the spec: `custom-rendezvous-server` and
  `relay-server` are set to `rd.e2e.test`, `key` to the hbbs public key,
  `api-server=https://rd.e2e.test` and `allow-websocket=Y`. Unattended access
  uses a permanent password.
* hbbs runs `-r rd.e2e.test -k _` with `read_only`, `cap_drop: [ALL]`,
  `no-new-privileges` and uid 1000. hbbr is always the stock image, `-k _`.
  The bench sets `WS_REGISTER=Y` and
  `TRUSTED_PROXY_CIDRS=10.231.4.0/24`, a `proxy` network that holds only
  nginx and edge, the same way a reverse proxy joins `rustdesk-net` in production. Stock
  hbbs ignores both.

## Client container

* Base: `debian:bookworm-slim`, pinned by digest. The client is the official
  `rustdesk-1.5.0-<arch>.deb`, checked against its sha256. arm64 runs natively
  on Apple Silicon and amd64 is supported too.
* Display: Xvfb + openbox, run as the unprivileged user `rd`. Screen capture
  and input go through X11, so no uinput or privileged mode is needed.
  `NET_ADMIN` is used only by the entrypoint, to install the egress firewall
  and the NAT route.
* Devices run `rustdesk --server`, the process the systemd service would start
  in the user session. The main window is started only for the final
  screenshots: it keeps its own copy of `RustDesk.toml` and can overwrite what
  `--server` wrote.
* Containers have no systemd-logind, so a test-only `/usr/local/bin/loginctl`
  shim reports one active X11 seat0 session for `rd`, which is what a
  logged-in desktop looks like. The client reads it to fill
  `PeerInfo.username`. Without it, the stock controller refuses file transfer
  with "No active console user logged on". The RustDesk binary is unmodified.
* Each container gets its own `/etc/machine-id`, which is what the client
  derives its uuid from. The id persists across `docker restart`, like a real
  machine. Recreating a container is a new machine, so do not use that in
  restart tests.
* Each container paints a unique solid desktop colour. A controller screenshot
  that contains a large area of the device's colour proves the remote desktop
  is rendering that device.

## Usage

```bash
cd tests/e2e
scripts/build-stock.sh                       # stock hbbs/hbbr from 873230e (git archive, ~10 min)
# patched build from exact commits, no checkout (context = git archive + hbb_common at its pin):
scripts/build-image.sh <hbbs-commit> --dockerfile <packaging-commit>:Dockerfile   # -> patina-e2e-hbbs:<sha7>
docker build -t patina-e2e-client:1.5.0 client
docker build -t patina-e2e-probe:latest --build-context protos=../../libs/hbb_common/protos probe

scripts/run-matrix.sh                        # baseline: HBBS_IMAGE defaults to the stock build
HBBS_IMAGE=patina-e2e-hbbs:<sha7> scripts/run-matrix.sh all    # patched, including the 11 min idle test
scripts/down.sh                              # remove containers, networks, volumes
scripts/down.sh --images                     # ...and the patina-e2e-* images
```

Results go to `$E2E_STATE/out` (default `$TMPDIR/patina-e2e-state/out`):
`results.tsv`, `run-info.txt` (image digests), screenshots, and every
container's docker log plus RustDesk client logs. You can run a subset of
tests: `scripts/run-matrix.sh ready desktop spoof`.

Docker's build cache is not removed by `down.sh`. Clearing it would need a
prune command, which this bench never runs.

## Tests and how each is decided

| test | automated check |
|------|-----------------|
| `ready` | The WS-only device has `key_confirmed = true` plus the per-host flag in `RustDesk.toml`. The client sets these only after `RegisterPkResponse.OK`, and the GUI "Ready" line reads the same flags. |
| `firewall` | The device cannot open tcp/21116 on edge. The iptables dump is saved. |
| `desktop` | The WS controller runs `rustdesk --connect <id> --password …`. The device's colour must cover more than `MIN_SHARE`% (default 5) of the controller screen. |
| `filetransfer` | The device writes a random token to `~/PATINA_E2E_MARKER.txt`. The controller runs `rustdesk --file-transfer <id> --password …`, then xdotool selects the file in the remote pane and presses Receive (fixed 1280x800 layout). The controller's copy must contain the token. |
| `online` / `offline` | The probe sends the client's `OnlineRequest` over `wss /ws/id`. The device must be online, and offline 5 s after it is stopped. A controller peer-list screenshot is saved for a visual check of the dot (MANUAL). |
| `idle` | A ready device plus an open remote session are left alone for `IDLE_SECONDS` (default 660). Pass needs no new `start tcp:` reconnect in the client log, still online, and the session still rendering. |
| `restart_hbbs` / `restart_nginx` / `restart_device` | After `docker restart`, the client must log a new `start tcp:` reconnect. Then hbbs must report the device online again (`OnlineRequest`, polled every 3 s, up to `RESTART_TIMEOUT`=150 s) with the same ID and no new `UUID_MISMATCH`. The recovery time and hbbs's count of `peer <id> registered` log lines are recorded. The client's on-disk `key_confirmed` survives restarts, so it is not used as evidence here. |
| `udp_to_ws` (+`_filetransfer`) | A UDP-mode controller opens the WS device's desktop and copies the marker. |
| `ws_to_udp` (+`_filetransfer`) | A WS controller opens a UDP-mode device's desktop and copies the marker. This is a regression check and passes on stock. |
| `nat` | Two WS devices behind one MASQUERADE router are both ready and online, and the controller opens each one's desktop. |
| `keepalive` | The probe registers through nginx and holds the connection for 45 s, echoing frames. It needs RegisterPk OK, a `keep_alive` value in the response, empty binary frames from the server with every gap shorter than `keep_alive`, and the connection still open at the end. |
| `replace` | Replace-on-reconnect and hijack, through nginx. Probe A registers id X. Probe B registers X with the same uuid and pk, as a reconnecting device would. Probe C tries X with a different uuid. Pass needs: A OK and then closed by the server, B OK and still open with keepalives, C `UUID_MISMATCH`, X online while B holds it, and an hbbs `replaces` log line. |
| `spoof` | The probe connects **directly** to edge:21118, which is not a trusted proxy, with forged `X-Real-IP`/`X-Forwarded-For`, and registers a fresh id. The IP hbbs stores in its peer row must be the probe's real address, never the forged one. On stock hbbs, WS RegisterPk is NOT_SUPPORT, so nothing is stored and the result is SKIP. |
| `trusted_proxy` | Positive control: the same registration through nginx (trusted) must store the probe's address taken from `X-Real-IP`, not nginx's own address on the proxy network (10.231.4.10), which is the peer hbbs actually sees. |
| `gui_status` | Screenshots of each device's main window (MANUAL: the status line should read Ready). |

## Probe

`probe/probe.py` is a raw WebSocket client built on protobuf classes generated
from the pinned `hbb_common` `rendezvous.proto`:

```bash
docker compose -p patina-e2e -f compose.yaml --profile probe run --rm probe \
    register ws://10.231.1.11:21118/ws/id --id test123 --header 'X-Real-IP: 1.2.3.4' --hold 60
... probe online wss://rd.e2e.test/ws/id --peers 123456789 --brief
... probe dbinfo --id test123
```

`register --hold N` also echoes the server's empty keepalive frames and
records when they arrived, which gives you the keepalive cadence.

## Limits of this bench

* The controller is the stock GUI client, driven from the command line plus
  xdotool for the file copy. Remote keyboard and mouse input to the device is
  not exercised.
* GUI online dots are not verified. In this setup, sessions opened with
  `--connect` don't appear in the stock GUI's Recent or Favorites lists, so
  there is no peer card to look at. The protocol-level `OnlineRequest` the
  GUI uses for the dot is automated.
* One machine and one Docker VM: no real WAN latency, MTU or packet loss.
