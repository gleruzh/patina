English | [Русский](PATCHES.ru.md)

# Patches on top of upstream

Patina is upstream [rustdesk/rustdesk-server](https://github.com/rustdesk/rustdesk-server)
plus a short series of commits. Keep it that way: no reformatting, no
unrelated changes, new code in new files.

Base: upstream `master` at `680b60395ecf99a76f74a1d934e453bb6e5e0aa2`
("fix(hbbr): match IPv4 clients against the relay lists in their IPv4 form (#748)", 1.1.17-dev), with `libs/hbb_common` at
`69cea8d`.

## Differences from upstream

Everything below is read from `git diff upstream/master HEAD`; re-check it after every
merge. Patina-owned files: `src/ws_peers.rs`, `tests/ws_registration.rs`,
`tests/egress-check.sh` (new); patched upstream files: `src/rendezvous_server.rs`,
`src/relay_server.rs`, `src/common.rs`, `src/lib.rs`, `Cargo.toml` and `Cargo.lock` (the
`tokio` `test-util` dev-dependency). Everything else under `deploy/`, `tests/e2e/`,
`docs/` and the top-level docs is Patina's own and does not touch upstream code.

Limits and timeouts that differ:

| What | Patina | Upstream | Why |
| --- | --- | --- | --- |
| `hbbs` WebSocket handshake timeout (all WS connections, also with `WS_REGISTER=N`) | 10 s (`ws_peers::HANDSHAKE_TIMEOUT`) | 30 s (474fbc7) | A silent connection should not hold a slot for 30 s; the per-IP limit counts it. |
| `hbbs` WebSocket write deadline | 10 s per message (`ws_peers::SEND_TIMEOUT`, writer task) | none (Patina's writer task has no upstream counterpart) | A device that stops reading must not block the writer or pile up queued frames. |
| `hbbs` WebSocket message and frame bound | `MAX_MESSAGE_KB` (default 64 KiB, cap 64 MiB); frame at most 16 MiB; 8 KiB read/write buffers | same, from upstream's `MAX_MESSAGE` and `WS_BUFFER_SIZE` | Not a difference since 0415b0e; `ws_peers::accept` reuses upstream's values so registration is bounded like upstream's own WS path. |
| `hbbs` proxy headers (`X-Real-IP`, `X-Real-Port`, `X-Forwarded-For`) | used only from `TRUSTED_PROXY_CIDRS` (default loopback); repeated, unparsable or disagreeing values fall back to the proxy address; port from `X-Real-Port` or per connection, never `:0` | trusted from any peer (port preserved since e5c0a42) | Header spoofing; unique addresses per connection. |
| `hbbs` WebSocket connections | `MAX_WS_CONN_PER_IP` (default 64), `MAX_WS_PEERS` (default 10000, WebSocket registration only) | no limit | Memory and connection exhaustion. |
| `hbbr` relay write deadline, both directions | 30 s + min(len, 1 MiB) / 16 KiB/s, at most 94 s | flat 30 s (1bd3938) | A large frame on a slow but live link must not be killed; a peer that stops reading still is. |
| `hbbr` 30 s inactivity check | a completed write also counts as activity | only a received frame counts | A long write must not trip the check. |
| `hbbr` message bound after pairing, for a leg that stays framed or WebSocket (mixed TCP-WS pairs, WS-WS) | 32 MiB per message, 16 MiB per frame (`MAX_WS_RELAY_MESSAGE`) | `usize::MAX` for the framed leg, tungstenite's 64 MiB / 16 MiB for WebSocket | A bound on what one peer can make the relay buffer. |
| `hbbr` relay request bound before pairing, first-message timeout | 128 KiB, 30 s | same (0415b0e) | Not a difference. |
| Outbound calls | none by default; the version check to `api.rustdesk.com` runs only with `SOFTWARE_UPDATE_CHECK=Y` | daily, unconditional | No phone-home. |
| WebSocket device registration, online status, push of `PunchHole` / `RequestRelay` / `FetchLocalAddr` | with `WS_REGISTER=Y` | `NOT_SUPPORT`, not answered | The point of the fork. |

Taken from upstream and no longer Patina patches (upstream did the same, so the
Patina copy was dropped in the 680b603 merge):

* relay UUID validation: 44de977, 08cd442;
* relay waiter expiry after pair id reuse: 134008e;
* message-size bounds on hbbs and hbbr: 0415b0e (this also moved the workspace to
  tungstenite 0.29 through the `rustdesk-org` `tokio-tungstenite` git fork and its
  `[patch.crates-io]`; Patina's own 0.26 bump is gone);
* WebSocket handshake bound and forwarded-port fix on upstream's own path: 474fbc7,
  e5c0a42 (Patina's `ws_peers` path has its own equivalents, see the table);
* write deadlines on the hbbs console replies and complete console writes: 98ffcee,
  36a0996;
* IPv4 clients matched against the relay lists in IPv4 form: 680b603 (#748);
* the flat 30 s relay write timeout: 1bd3938 (Patina now only scales it).

## The series

| Commit | Touches | What |
| --- | --- | --- |
| refactor(hbbs): share the RegisterPk checks | `src/rendezvous_server.rs` | Move the UDP `RegisterPk` body into `register_pk()`; UDP behaviour unchanged. |
| feat(hbbs): add ws_peers, state for WebSocket device registration | `src/ws_peers.rs` (new), `src/lib.rs` | Writer task, `WsTx`, `WsPeers`, trusted proxies, limits, with unit tests. |
| feat(hbbs): WebSocket writer task, trusted proxies, connection limits | `src/rendezvous_server.rs` | `Sink::Ws` becomes `Sink::Chan`. The WS branch of `handle_listener_inner` uses `ws_peers::accept` and the writer task. |
| feat(hbbs): register devices over WebSocket (WS_REGISTER=Y) | `src/rendezvous_server.rs` | `handle_tcp` gets `ws_conn`, plus the `handle_ws_*` functions. Routing in `handle_tcp_punch_hole_request` and the `RequestRelay` arm. `online_states()`. Unit tests. |
| test(hbbs): in-process WebSocket registration integration test | `tests/ws_registration.rs` (new) | In-process hbbs + tokio-tungstenite. |
| fix(hbbs): fail closed on ambiguous proxy headers | `src/ws_peers.rs` | Repeated, unparsable or disagreeing `X-Real-IP` / `X-Forwarded-For` fall back to the proxy address. |
| fix(hbbs): refuse RequestRelay to WS devices unless the relay is in -r | `src/rendezvous_server.rs` | `ws_relay_allowed()`. |
| fix(hbbs): a superseded WebSocket cannot take its id back | `src/rendezvous_server.rs` | `RegisterPk` on a connection that lost its id to a newer one closes it. |
| fix(hbbs): no version check to api.rustdesk.com unless SOFTWARE_UPDATE_CHECK=Y | `src/common.rs` | `software_update_check_enabled()` gates `check_software_update()`, plus a unit test. |
| test: egress check, hbbs and hbbr send nothing on their own | `tests/egress-check.sh` (new) | A tcpdump check in Docker, with a positive control. |
| fix(hbbr): scale relay write deadlines, bound paired legs | `src/relay_server.rs` | Upstream (1bd3938, 0415b0e) now bounds relay writes with a flat 30 s and bounds message sizes (128 KiB for the relay request before pairing, tungstenite's 64 MiB / 16 MiB after). Patina keeps only the differences: the write deadline is 30 s plus len / 16 KiB/s (the scaled part counts at most 1 MiB, so at most 94 s); a completed write counts as activity for the 30 s inactivity check; a leg that stays framed or WebSocket after pairing (mixed TCP-WS pairs, WS-WS) is bounded to 32 MiB per message (frames 16 MiB) instead of unbounded / 64 MiB. |
| deps: tokio `test-util` dev-dependency; lock with refreshed registry crates | `Cargo.toml`, `Cargo.lock` | The dev-dependency is needed by the virtual-time tests in `src/relay_server.rs`. The `tungstenite` / `tokio-tungstenite` bump is no longer a Patina patch: upstream moved to 0.29 (0415b0e). `src/ws_peers.rs` and `tests/ws_registration.rs` build against it. |
| fix(hbbs): WebSocket registration honours MAX_MESSAGE_KB | `src/ws_peers.rs`, `src/rendezvous_server.rs` | `ws_peers::accept` uses upstream's `MAX_MESSAGE` (default 64 KiB) for its message and frame bound. Its own 10 s handshake timeout and trusted-proxy address handling (`X-Real-Port` or a per-connection port, never `:0`) cover upstream's 474fbc7 / e5c0a42 for this path. |
| docs commits | `docs/ws-registration.md`, `PATCHES.md` (new) | |
| build, deploy, e2e and README commits | `Dockerfile`, `.dockerignore`, `deploy/`, `tests/e2e/`, `README.md`, `*.ru.md`, `docs/glossary.md` | New files, apart from `README.md`. Keep them out of the code commits so the code commits rebase on their own. |

Upstream code touched, which is where conflicts will show up:

* `src/rendezvous_server.rs`
  * imports, `enum Sink`, `struct RendezvousServer` (field `ws_peers`) and
    its construction in `start_with_bind`;
  * `handle_udp`: the `RegisterPk` arm (now a call to `register_pk`);
  * `handle_tcp`: signature (`ws_conn`), the `RequestRelay` and `RegisterPk`
    arms, new `RegisterPeer` / `OnlineRequest` arms with a `ws_conn.is_some()`
    guard;
  * `handle_online_request` (body moved into `online_states`);
  * `send_to_sink` (`Sink::Chan` arm);
  * `handle_tcp_punch_hole_request` (route via `ws_peers` first);
  * `handle_listener_inner` (the `if ws` branch);
  * `MAX_MESSAGE`, `WS_BUFFER_SIZE` and `WS_DEFAULT_MAX_FRAME_SIZE` are
    `pub(crate)`, for `ws_peers`;
  * the tests module: Patina's WS tests are appended after upstream's, and the
    only edit to an upstream test is a lock in `punch_reqs_bounded`.
* `src/relay_server.rs`: the relay write path (`send_bounded`, `write_deadline_ms`), the
  `last_recv_time` update after a completed write, the `MAX_WS_RELAY_MESSAGE` bound in
  `make_pair_`, and the constants next to them.
* `Cargo.toml` and `Cargo.lock`: `Cargo.toml` differs from upstream only by the tokio
  `test-util` dev-dependency. `Cargo.lock` is upstream's lock with the registry crates
  refreshed by `cargo update`, so it carries newer registry versions than upstream's; the
  git dependencies (reqwest, tokio-socks, async-speed-limit, confy, default_net,
  machine-uid, sysinfo, tungstenite, tokio-tungstenite) stay at upstream's revs. Both files
  are Patina-owned: they come from the development repository. At a rebase, take upstream's
  lock, re-add Patina's dev-dependency, run `cargo update`, then re-pin every git
  dependency that moved to upstream's rev with
  `cargo update -p <pkg>@<version> --precise <full-rev>` (take `<version>` from the
  `cargo update` output and `<rev>` from `git show upstream/master:Cargo.lock`; cargo has
  no switch that updates registry crates only). Check that the git sources in
  `Cargo.lock` equal upstream's, and do not keep upstream's older lock.
* `src/lib.rs`: `mod ws_peers;`.
* `src/common.rs`: the `SOFTWARE_UPDATE_CHECK` gate at the top of
  `check_software_update()`, and a test at the end of the tests module.

`src/ws_peers.rs` and `tests/ws_registration.rs` are new and do not
conflict. They do depend on hbb_common's `rendezvous_proto`,
`tokio-tungstenite` / `tungstenite` 0.29 (upstream's pin) and
`ipnetwork` 0.20 (from upstream's `Cargo.toml`). A bump of any of these can
break them at compile time.

## Rebasing onto a new upstream tag

```bash
git fetch https://github.com/rustdesk/rustdesk-server --tags
# the old base is the upstream commit the series currently sits on
OLD_BASE=680b60395ecf99a76f74a1d934e453bb6e5e0aa2
NEW_BASE=<upstream tag or commit>
git switch -c rebase-$NEW_BASE <current patina branch>
git rebase --onto "$NEW_BASE" "$OLD_BASE"
git submodule update --init        # hbb_common at the new upstream pin
```

Then, before anything else:

1. **Read upstream's changes to the functions listed above**, not just the
   conflicts: `git diff $OLD_BASE $NEW_BASE -- src/rendezvous_server.rs
   src/peer.rs src/common.rs src/relay_server.rs Cargo.toml Cargo.lock`.
   In particular:
   * upstream changes to the relay in `src/relay_server.rs` must keep the
     scaled write deadline (`send_bounded` replaces upstream's flat 30 s
     `timeout` around `send_raw`, so only one deadline applies) and the
     32 MiB paired-leg bound (`MAX_WS_RELAY_MESSAGE`, in place of
     upstream's `usize::MAX`); upstream's 128 KiB pre-pair bound stays;
   * if upstream's `Cargo.toml` changes `tungstenite` / `tokio-tungstenite`,
     take upstream's version (it is no longer a Patina patch) and fix
     `src/ws_peers.rs` and `tests/ws_registration.rs` if they stop compiling;
   * any change to the UDP `RegisterPk` checks must be applied inside
     `register_pk()`, which now serves both transports;
   * new message arms in `handle_tcp` must decide whether they apply to
     WebSocket devices (`ws_conn`);
   * changes to `tcp_punch` keys or to how `addr` is derived for WS (upstream
     rewrote it to `IP:0` before e5c0a42, and has kept the proxy connection's
     port since) must keep addresses unique per connection;
   * new upstream security fixes (rate limits, id caps, reflection fixes)
     must stay intact. Never re-enable UDP `PunchHoleRequest`;
   * any new outbound call (HTTP, telemetry, update or licence checks, a
     changed `version_check_request`) must be gated off by default like the
     version check. Look for `reqwest`, `hyper`, `connect`, `send_to` and
     `lookup_host` in `src/` and in the hbb_common code the server reaches.
     Update the table in
     [docs/ws-registration.md](docs/ws-registration.md#outbound-connections).
2. If upstream bumps `libs/hbb_common`, check `protos/rendezvous.proto` for
   changes to `RegisterPk`, `RegisterPkResponse.keep_alive`,
   `OnlineRequest` and `RelayResponse`.
3. Check the client side has not changed what it expects. Read
   `rustdesk/rustdesk` `src/rendezvous_mediator.rs` (`start_tcp`,
   `handle_resp`, `create_relay`, `register_pk`) and `hbb_common`
   `src/websocket.rs` (`check_ws`) for the current client release: the
   empty-frame echo, the `keep_alive` × 1.5 timeout, `/ws/id` and
   `/ws/relay`, the `api-server` https rule.
4. Run the tests in Docker (no host toolchain needed). Use the Rust image
   that the `Dockerfile` pins:

   ```bash
   docker run --rm -v "$PWD":/src -w /src -e CARGO_TARGET_DIR=/tmp/target \
     rust:1.99.1-slim-trixie sh -c \
     'apt-get update -qq &&
      apt-get install -y -qq --no-install-recommends make pkg-config libssl-dev &&
      cargo test --locked &&
      cargo test --locked --test ws_registration -- --ignored'
   ```

   The second run is the idle soak: a registered connection must survive
   more than 5 minutes. It takes about 5.5 minutes.

5. Build the image and run `tests/egress-check.sh <image>`. It must print
   three `ok` lines.
6. Run the end-to-end test with the stock client (see `tests/e2e/`) and
   compare the result with the last test report.
7. Update the base commit at the top of this file, and the "Differences from upstream" tables (a limit upstream now enforces itself moves to the "no longer Patina patches" list with its commit).

If upstream ever ships WebSocket registration itself, compare it with this
series and prefer upstream's, keeping whichever hardening it lacks
(trusted proxies, owner-checked cleanup, no binding via `RegisterPeer`).

## Attribution

Ideas, not code, were taken from two other AGPL-3.0 forks:

* [ymg2006/rustdesk-server](https://github.com/ymg2006/rustdesk-server):
  WebSocket routes keyed by peer id plus connection id (newest wins,
  owner-checked cleanup), routing `PunchHole` / `FetchLocalAddr` /
  `RequestRelay` to the WebSocket, and `TRUSTED_PROXY_CIDRS`. Not taken:
  its revert of upstream 80d3a50 (UDP `PunchHoleRequest`), its JWT /
  `MUST_LOGIN` bundle, and its `RegisterPeer` over TCP/WebSocket, which
  updates the address and `last_reg_time` of any id seen from the same IP
  without checking that the connection registered it.
* [bropines/rustdesk-server](https://github.com/bropines/rustdesk-server)
  branch `rdpanel`: the `TCP_KEEPALIVE` idea, an empty binary frame about
  every 12 s that the client echoes, refreshing `last_reg_time`. Not taken:
  `IP:0` keys, a WS map that is never cleaned up, a lock held across
  `send().await`, and unconditional trust of `X-Forwarded-For`.

## License

AGPL-3.0, as upstream. On every rebase, keep `LICENSE` and upstream's
copyright notices unchanged. Keep the headers of the new files
(`src/ws_peers.rs`, `tests/ws_registration.rs`, `tests/egress-check.sh`) and
the attribution above.
AGPL §13 applies: users who reach the server over the network must be able to
get the source of the version that runs. `deploy/client-settings.md` links to
it.
