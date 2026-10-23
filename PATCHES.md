English | [Русский](PATCHES.ru.md)

# Patches on top of upstream

Patina is upstream [rustdesk/rustdesk-server](https://github.com/rustdesk/rustdesk-server)
plus a short series of commits. Keep it that way: no reformatting, no
unrelated changes, new code in new files.

Base: upstream `master` at `873230e35a8805de7fd057e7eb763c46f7a174ef`
("fix: key file perm (#705)", 1.1.17-dev), with `libs/hbb_common` at
`69cea8d`.

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
  * the tests module (new tests, and a lock in `punch_reqs_bounded`).
* `src/lib.rs`: `mod ws_peers;`.
* `src/common.rs`: the `SOFTWARE_UPDATE_CHECK` gate at the top of
  `check_software_update()`, and a test at the end of the tests module.

`src/ws_peers.rs` and `tests/ws_registration.rs` are new and do not
conflict. They do depend on hbb_common's `rendezvous_proto`,
`tokio-tungstenite` / `tungstenite` 0.17 and `ipnetwork` 0.20 (all from
upstream's `Cargo.toml`). A bump of any of these can break them at compile
time.

## Rebasing onto a new upstream tag

```bash
git fetch https://github.com/rustdesk/rustdesk-server --tags
# the old base is the upstream commit the series currently sits on
OLD_BASE=873230e35a8805de7fd057e7eb763c46f7a174ef
NEW_BASE=<upstream tag or commit>
git switch -c rebase-$NEW_BASE <current patina branch>
git rebase --onto "$NEW_BASE" "$OLD_BASE"
git submodule update --init        # hbb_common at the new upstream pin
```

Then, before anything else:

1. **Read upstream's changes to the functions listed above**, not just the
   conflicts: `git diff $OLD_BASE $NEW_BASE -- src/rendezvous_server.rs
   src/peer.rs src/common.rs`. In particular:
   * any change to the UDP `RegisterPk` checks must be applied inside
     `register_pk()`, which now serves both transports;
   * new message arms in `handle_tcp` must decide whether they apply to
     WebSocket devices (`ws_conn`);
   * changes to `tcp_punch` keys or to how `addr` is derived for WS (upstream
     rewrote it to `IP:0`) must keep addresses unique per connection;
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
7. Update the base commit at the top of this file.

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
