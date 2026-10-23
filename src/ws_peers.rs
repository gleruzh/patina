// Patina: WebSocket device registration for hbbs.
//
// Copyright (C) 2026 Patina contributors.
// Based on rustdesk-server, Copyright (C) Purslane Ltd. and contributors.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by the
// Free Software Foundation, version 3 of the License. See LICENSE.
//
// Design credits (ideas, not code): the per-connection-id ownership of WS
// routes and TRUSTED_PROXY_CIDRS follow ymg2006/rustdesk-server; the empty
// binary keepalive frame that the client echoes follows bropines/rustdesk-server
// (branch rdpanel). See docs/ws-registration.md.

//! State and helpers for devices that register over the WebSocket port.
//!
//! A WebSocket connection gets a writer task that owns the sink. Everything
//! else talks to the connection through a bounded channel ([`WsTx`]), so no
//! lock is ever held while a frame is written. A device that registered with
//! `RegisterPk` on a connection is stored in [`WsPeers`] under its id, together
//! with the connection id; the newest connection wins and only the owner may
//! remove the entry.

use crate::common::get_arg;
use hbb_common::{
    futures::{Sink, SinkExt},
    log,
    protobuf::Message as _,
    rendezvous_proto::RendezvousMessage,
    tokio::{
        self,
        net::TcpStream,
        sync::mpsc,
        time::{interval_at, Duration, Instant, MissedTickBehavior},
    },
    ResultType,
};
use ipnetwork::IpNetwork;
use std::{
    collections::HashMap,
    net::{IpAddr, SocketAddr},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
};
use tokio_tungstenite::WebSocketStream;
use tungstenite::{
    handshake::server::{Request, Response},
    http::HeaderMap,
    protocol::WebSocketConfig,
    Message as WsMessage,
};

/// Frames queued for one connection before new ones are dropped.
const CHANNEL_CAP: usize = 32;
/// Rendezvous messages are small; the largest is an OnlineRequest listing peers.
const MAX_WS_MESSAGE: usize = 64 * 1024;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const SEND_TIMEOUT: Duration = Duration::from_secs(10);
const UNTRUSTED_HEADER_LOG_EVERY: Duration = Duration::from_secs(60);

static NEXT_CONN_ID: AtomicU64 = AtomicU64::new(1);

/// Runtime settings, read once from the environment (or `.env` / `-c` file).
#[derive(Debug, Clone)]
pub(crate) struct WsSettings {
    /// `WS_REGISTER=Y` turns on registration, heartbeats and online status
    /// over WebSocket. Off by default, so the protocol stays upstream's.
    pub(crate) register: bool,
    /// Interval of the empty keepalive frame (`WS_KEEPALIVE_SECS`, 5..=20).
    pub(crate) keepalive: Duration,
    /// `MAX_WS_PEERS`: devices registered over WebSocket at once.
    pub(crate) max_peers: usize,
    /// `MAX_WS_CONN_PER_IP`: concurrent WebSocket connections per client IP.
    pub(crate) max_conn_per_ip: usize,
    /// `TRUSTED_PROXY_CIDRS`: peers whose X-Real-IP/X-Forwarded-For are used.
    pub(crate) trusted: TrustedProxies,
}

impl WsSettings {
    pub(crate) fn from_env() -> Self {
        let keepalive = get_arg("WS_KEEPALIVE_SECS")
            .parse::<u64>()
            .unwrap_or(12)
            .clamp(5, 20);
        Self {
            register: get_arg("WS_REGISTER").to_uppercase() == "Y",
            keepalive: Duration::from_secs(keepalive),
            max_peers: get_arg("MAX_WS_PEERS").parse().unwrap_or(10_000),
            max_conn_per_ip: get_arg("MAX_WS_CONN_PER_IP").parse().unwrap_or(64),
            trusted: TrustedProxies::parse(&get_arg("TRUSTED_PROXY_CIDRS")),
        }
    }

    /// `RegisterPkResponse.keep_alive`, in seconds. The client reconnects when
    /// nothing arrived for 1.5 times this, so three keepalives fit in.
    pub(crate) fn client_keep_alive(&self) -> i32 {
        (self.keepalive.as_secs() * 3) as i32
    }

    pub(crate) fn log(&self) {
        log::info!(
            "WS_REGISTER={} WS_KEEPALIVE_SECS={} MAX_WS_PEERS={} MAX_WS_CONN_PER_IP={} TRUSTED_PROXY_CIDRS={}",
            if self.register { "Y" } else { "N" },
            self.keepalive.as_secs(),
            self.max_peers,
            self.max_conn_per_ip,
            self.trusted
        );
    }
}

/// Proxies allowed to set the client address. Loopback is always trusted.
#[derive(Debug, Clone, Default)]
pub(crate) struct TrustedProxies(Vec<IpNetwork>);

impl TrustedProxies {
    pub(crate) fn parse(s: &str) -> Self {
        let mut nets = Vec::new();
        for entry in s.split(|c: char| c == ',' || c.is_whitespace()) {
            let entry = entry.trim();
            if entry.is_empty() {
                continue;
            }
            match entry.parse::<IpNetwork>() {
                Ok(net) => nets.push(net),
                Err(err) => log::error!("Ignoring invalid TRUSTED_PROXY_CIDRS entry {entry:?}: {err}"),
            }
        }
        Self(nets)
    }

    pub(crate) fn contains(&self, ip: IpAddr) -> bool {
        let ip = normalize_ip(ip);
        ip.is_loopback() || self.0.iter().any(|net| net.contains(ip))
    }
}

impl std::fmt::Display for TrustedProxies {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("loopback")?;
        for net in &self.0 {
            write!(f, ",{net}")?;
        }
        Ok(())
    }
}

pub(crate) fn normalize_ip(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(ip),
        ip => ip,
    }
}

fn parse_ip(s: &str) -> Option<IpAddr> {
    let s = s.trim();
    if let Ok(ip) = s.parse::<IpAddr>() {
        return Some(normalize_ip(ip));
    }
    // "1.2.3.4:5678" or "[::1]:5678"
    s.parse::<SocketAddr>().ok().map(|a| normalize_ip(a.ip()))
}

/// Outcome of looking at the proxy headers of a WebSocket handshake.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum ClientAddr {
    /// No proxy headers; the TCP peer is the client.
    Direct(SocketAddr),
    /// A trusted proxy named the client.
    Proxied(SocketAddr),
    /// Proxy headers from a peer that is not trusted; they were ignored.
    Untrusted(SocketAddr),
    /// A trusted proxy sent headers that are unparsable, repeated or
    /// disagree; the proxy address is used (fail closed).
    Conflicting(SocketAddr),
}

impl ClientAddr {
    pub(crate) fn addr(&self) -> SocketAddr {
        match self {
            Self::Direct(a) | Self::Proxied(a) | Self::Untrusted(a) | Self::Conflicting(a) => *a,
        }
    }
}

/// Work out the client address of a WebSocket connection.
///
/// The headers are used only when the TCP peer is a trusted proxy, and only
/// when they are unambiguous: a single `X-Real-IP`, the last hop of the last
/// `X-Forwarded-For` line, and if both are present they must agree. A proxy
/// that overwrites both (see deploy/swag) always passes; a client that adds
/// the header its proxy does not manage gets the proxy address instead of
/// the IP it chose. The port is `X-Real-Port` when the proxy sends it, else
/// one derived from the connection id, so two clients behind one NAT never
/// share a key in `tcp_punch`. Clients only use the IP.
pub(crate) fn client_addr(
    peer: SocketAddr,
    headers: &HeaderMap,
    trusted: &TrustedProxies,
    conn_id: u64,
) -> ClientAddr {
    let peer = SocketAddr::new(normalize_ip(peer.ip()), peer.port());
    let all = |name: &str| -> Vec<&str> {
        headers
            .get_all(name)
            .iter()
            .map(|v| v.to_str().unwrap_or(""))
            .collect()
    };
    let real_ip = all("X-Real-IP");
    let forwarded = all("X-Forwarded-For");
    if real_ip.is_empty() && forwarded.is_empty() {
        return ClientAddr::Direct(peer);
    }
    if !trusted.contains(peer.ip()) {
        return ClientAddr::Untrusted(peer);
    }
    // None: absent; Some(None): present but unusable
    let real_ip = match real_ip.as_slice() {
        [] => None,
        [one] => Some(parse_ip(one)),
        _ => Some(None),
    };
    let last_hop = forwarded
        .last()
        .map(|line| line.rsplit(',').next().and_then(parse_ip));
    let ip = match (real_ip, last_hop) {
        (Some(Some(a)), Some(Some(b))) if a == b => a,
        (Some(Some(a)), None) | (None, Some(Some(a))) => a,
        _ => return ClientAddr::Conflicting(peer),
    };
    let port = match all("X-Real-Port").as_slice() {
        [one] => one.trim().parse::<u16>().ok().filter(|p| *p != 0),
        _ => None,
    }
    .unwrap_or_else(|| synthetic_port(conn_id));
    ClientAddr::Proxied(SocketAddr::new(ip, port))
}

fn synthetic_port(conn_id: u64) -> u16 {
    (conn_id % 65535) as u16 + 1
}

/// At most one warning per minute per kind, with a count of the rest.
struct LogThrottle {
    last: Mutex<Option<Instant>>,
    suppressed: AtomicU64,
}

impl LogThrottle {
    const fn new() -> Self {
        Self {
            last: Mutex::new(None),
            suppressed: AtomicU64::new(0),
        }
    }

    fn warn(&self, msg: impl FnOnce(u64) -> String) {
        let mut last = self.last.lock().unwrap_or_else(|e| e.into_inner());
        if last.map_or(true, |t| t.elapsed() >= UNTRUSTED_HEADER_LOG_EVERY) {
            *last = Some(Instant::now());
            let n = self.suppressed.swap(0, Ordering::Relaxed);
            log::warn!("{}", msg(n));
        } else {
            self.suppressed.fetch_add(1, Ordering::Relaxed);
        }
    }
}

fn log_proxy_headers(client: &ClientAddr) {
    static UNTRUSTED: LogThrottle = LogThrottle::new();
    static CONFLICTING: LogThrottle = LogThrottle::new();
    match client {
        ClientAddr::Untrusted(peer) => UNTRUSTED.warn(|n| format!(
            "Ignoring X-Real-IP/X-Forwarded-For from untrusted peer {peer} ({n} more since last warning); add the proxy to TRUSTED_PROXY_CIDRS if it is yours"
        )),
        ClientAddr::Conflicting(peer) => CONFLICTING.warn(|n| format!(
            "Unusable, repeated or disagreeing X-Real-IP/X-Forwarded-For from proxy {peer} ({n} more since last warning); using the proxy address. The proxy must overwrite both headers"
        )),
        _ => {}
    }
}

/// What the writer task is asked to do.
#[derive(Debug)]
pub(crate) enum Out {
    Frame(Vec<u8>),
    Close,
}

/// Handle to the writer task of one WebSocket connection.
#[derive(Clone, Debug)]
pub(crate) struct WsTx(mpsc::Sender<Out>);

impl WsTx {
    pub(crate) fn channel() -> (Self, mpsc::Receiver<Out>) {
        let (tx, rx) = mpsc::channel(CHANNEL_CAP);
        (Self(tx), rx)
    }

    /// Queue a frame; false if the queue is full or the writer is gone.
    pub(crate) fn send(&self, bytes: Vec<u8>) -> bool {
        match self.0.try_send(Out::Frame(bytes)) {
            Ok(()) => true,
            Err(mpsc::error::TrySendError::Full(_)) => {
                log::warn!("WebSocket send queue full, frame dropped");
                false
            }
            Err(mpsc::error::TrySendError::Closed(_)) => false,
        }
    }

    pub(crate) fn send_msg(&self, msg: &RendezvousMessage) -> bool {
        match msg.write_to_bytes() {
            Ok(bytes) => self.send(bytes),
            Err(_) => false,
        }
    }

    pub(crate) fn close(&self) {
        self.0.try_send(Out::Close).ok();
    }

    /// Resolves when the writer task has stopped.
    pub(crate) async fn closed(&self) {
        self.0.closed().await
    }
}

/// Run the writer of one connection: frames from the channel, plus an empty
/// binary frame every `period` once `keepalive` is set. The client echoes the
/// empty frame, which is the device's heartbeat; WS ping/pong does not reset
/// the client's timer.
pub(crate) fn spawn_writer<S>(
    sink: S,
    rx: mpsc::Receiver<Out>,
    keepalive: Arc<AtomicBool>,
    period: Duration,
) -> tokio::task::JoinHandle<()>
where
    S: Sink<WsMessage> + Unpin + Send + 'static,
{
    tokio::spawn(writer(sink, rx, keepalive, period))
}

async fn writer<S>(
    mut sink: S,
    mut rx: mpsc::Receiver<Out>,
    keepalive: Arc<AtomicBool>,
    period: Duration,
) where
    S: Sink<WsMessage> + Unpin,
{
    let mut ticker = interval_at(Instant::now() + period, period);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        let frame = tokio::select! {
            out = rx.recv() => match out {
                Some(Out::Frame(bytes)) => WsMessage::Binary(bytes),
                Some(Out::Close) | None => break,
            },
            _ = ticker.tick() => {
                if !keepalive.load(Ordering::Relaxed) {
                    continue;
                }
                WsMessage::Binary(Vec::new())
            }
        };
        match tokio::time::timeout(SEND_TIMEOUT, sink.send(frame)).await {
            Ok(Ok(())) => {}
            _ => break,
        }
    }
    tokio::time::timeout(SEND_TIMEOUT, sink.close()).await.ok();
}

struct Entry {
    conn_id: u64,
    tx: WsTx,
}

#[derive(Default)]
struct Registry {
    peers: HashMap<String, Entry>,
    conns_per_ip: HashMap<IpAddr, usize>,
}

/// Where a message for a peer went.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Route {
    /// Queued on the peer's WebSocket.
    Sent,
    /// The peer is on WebSocket but its queue is full or closing; not sent.
    Dropped,
    /// The peer is not registered over WebSocket; use upstream's UDP path.
    NotWsPeer,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Insert {
    /// Stored; `replaced` is true when an older connection lost the id.
    Stored { replaced: bool },
    /// `MAX_WS_PEERS` reached.
    Full,
}

/// Devices registered over WebSocket, keyed by peer id.
///
/// Uses a std mutex on purpose: it is never held across an `.await`, and the
/// compiler rejects a guard that would be, since the futures are spawned.
#[derive(Clone)]
pub(crate) struct WsPeers {
    reg: Arc<Mutex<Registry>>,
    pub(crate) settings: Arc<WsSettings>,
}

impl WsPeers {
    pub(crate) fn new(settings: WsSettings) -> Self {
        Self {
            reg: Default::default(),
            settings: Arc::new(settings),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Registry> {
        self.reg.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Count one connection against its client IP; None when over the cap.
    pub(crate) fn acquire_ip(&self, ip: IpAddr) -> Option<IpGuard> {
        let mut reg = self.lock();
        let n = reg.conns_per_ip.entry(ip).or_insert(0);
        if *n >= self.settings.max_conn_per_ip {
            return None;
        }
        *n += 1;
        Some(IpGuard {
            reg: self.reg.clone(),
            ip,
        })
    }

    pub(crate) fn has_room_for(&self, id: &str) -> bool {
        let reg = self.lock();
        reg.peers.contains_key(id) || reg.peers.len() < self.settings.max_peers
    }

    /// Bind `id` to a connection. A previous owner is told to close.
    pub(crate) fn insert(&self, id: &str, conn_id: u64, tx: WsTx) -> Insert {
        let mut reg = self.lock();
        if !reg.peers.contains_key(id) && reg.peers.len() >= self.settings.max_peers {
            return Insert::Full;
        }
        let old = reg.peers.insert(id.to_owned(), Entry { conn_id, tx });
        drop(reg);
        match old {
            Some(old) if old.conn_id != conn_id => {
                log::info!(
                    "WebSocket peer {id}: connection {conn_id} replaces {}",
                    old.conn_id
                );
                old.tx.close();
                Insert::Stored { replaced: true }
            }
            _ => Insert::Stored { replaced: false },
        }
    }

    pub(crate) fn is_owner(&self, id: &str, conn_id: u64) -> bool {
        self.lock()
            .peers
            .get(id)
            .is_some_and(|e| e.conn_id == conn_id)
    }

    /// Remove `id` only if `conn_id` still owns it.
    pub(crate) fn remove_if_owner(&self, id: &str, conn_id: u64) -> bool {
        let mut reg = self.lock();
        if reg.peers.get(id).is_some_and(|e| e.conn_id == conn_id) {
            reg.peers.remove(id);
            true
        } else {
            false
        }
    }

    pub(crate) fn contains(&self, id: &str) -> bool {
        self.lock().peers.contains_key(id)
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.lock().peers.len()
    }

    /// Send `msg` to `id` if it is registered over WebSocket.
    pub(crate) fn route(&self, id: &str, msg: &RendezvousMessage) -> Route {
        let tx = match self.lock().peers.get(id) {
            Some(e) => e.tx.clone(),
            None => return Route::NotWsPeer,
        };
        if tx.send_msg(msg) {
            Route::Sent
        } else {
            log::warn!("WebSocket peer {id} unreachable, message dropped");
            Route::Dropped
        }
    }
}

/// Releases a per-IP connection slot on drop.
pub(crate) struct IpGuard {
    reg: Arc<Mutex<Registry>>,
    ip: IpAddr,
}

impl Drop for IpGuard {
    fn drop(&mut self) {
        let mut reg = self.reg.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(n) = reg.conns_per_ip.get_mut(&self.ip) {
            *n = n.saturating_sub(1);
            if *n == 0 {
                reg.conns_per_ip.remove(&self.ip);
            }
        }
    }
}

/// Per-connection state of a WebSocket rendezvous connection.
pub(crate) struct WsConn {
    pub(crate) conn_id: u64,
    pub(crate) tx: WsTx,
    /// The id this connection registered with `RegisterPk`, once accepted.
    pub(crate) id: Option<String>,
    /// Tells the writer to start sending keepalive frames.
    pub(crate) keepalive: Arc<AtomicBool>,
    _ip: IpGuard,
}

/// Accept a WebSocket handshake. Returns the stream, the client address to
/// use (see [`client_addr`]), the connection state and the writer's receiver.
pub(crate) async fn accept(
    stream: TcpStream,
    peer: SocketAddr,
    peers: &WsPeers,
) -> ResultType<(
    WebSocketStream<TcpStream>,
    SocketAddr,
    WsConn,
    mpsc::Receiver<Out>,
)> {
    let conn_id = NEXT_CONN_ID.fetch_add(1, Ordering::Relaxed);
    let mut client = ClientAddr::Direct(peer);
    let callback = |req: &Request, response: Response| {
        client = client_addr(peer, req.headers(), &peers.settings.trusted, conn_id);
        Ok(response)
    };
    let config = WebSocketConfig {
        max_message_size: Some(MAX_WS_MESSAGE),
        max_frame_size: Some(MAX_WS_MESSAGE),
        ..Default::default()
    };
    let ws = tokio::time::timeout(
        HANDSHAKE_TIMEOUT,
        tokio_tungstenite::accept_hdr_async_with_config(stream, callback, Some(config)),
    )
    .await??;
    log_proxy_headers(&client);
    let addr = client.addr();
    let Some(guard) = peers.acquire_ip(addr.ip()) else {
        hbb_common::bail!("too many WebSocket connections from {}", addr.ip());
    };
    let (tx, rx) = WsTx::channel();
    let conn = WsConn {
        conn_id,
        tx,
        id: None,
        keepalive: Default::default(),
        _ip: guard,
    };
    Ok((ws, addr, conn, rx))
}

#[cfg(test)]
impl WsConn {
    pub(crate) fn for_test(peers: &WsPeers, ip: IpAddr) -> (Self, mpsc::Receiver<Out>) {
        let (tx, rx) = WsTx::channel();
        let conn = Self {
            conn_id: NEXT_CONN_ID.fetch_add(1, Ordering::Relaxed),
            tx,
            id: None,
            keepalive: Default::default(),
            _ip: peers.acquire_ip(ip).expect("ip slot"),
        };
        (conn, rx)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use hbb_common::futures::{channel::mpsc as fmpsc, StreamExt};
    use hbb_common::rendezvous_proto::PunchHole;

    pub(crate) fn settings() -> WsSettings {
        WsSettings {
            register: true,
            keepalive: Duration::from_secs(12),
            max_peers: 3,
            max_conn_per_ip: 2,
            trusted: TrustedProxies::parse("172.18.0.0/16"),
        }
    }

    fn headers(pairs: &[(&'static str, &str)]) -> HeaderMap {
        let mut h = HeaderMap::new();
        for (k, v) in pairs {
            h.insert(*k, v.parse().unwrap());
        }
        h
    }

    fn sa(s: &str) -> SocketAddr {
        s.parse().unwrap()
    }

    #[test]
    fn proxy_headers_need_a_trusted_peer() {
        let t = TrustedProxies::parse("172.18.0.0/16, 10.1.2.3");
        let h = headers(&[("X-Real-IP", "203.0.113.7"), ("X-Real-Port", "40001")]);
        assert_eq!(
            client_addr(sa("172.18.0.5:5555"), &h, &t, 1),
            ClientAddr::Proxied(sa("203.0.113.7:40001"))
        );
        assert_eq!(
            client_addr(sa("10.1.2.3:5555"), &h, &t, 1),
            ClientAddr::Proxied(sa("203.0.113.7:40001"))
        );
        // loopback is always trusted, v4-mapped addresses are normalized
        assert_eq!(
            client_addr(sa("[::ffff:127.0.0.1]:5555"), &h, &t, 1),
            ClientAddr::Proxied(sa("203.0.113.7:40001"))
        );
        // spoofed headers sent straight to the port are ignored
        assert_eq!(
            client_addr(sa("198.51.100.9:6000"), &h, &t, 1),
            ClientAddr::Untrusted(sa("198.51.100.9:6000"))
        );
        assert_eq!(
            client_addr(sa("198.51.100.9:6000"), &HeaderMap::new(), &t, 1),
            ClientAddr::Direct(sa("198.51.100.9:6000"))
        );
        // default is loopback only
        let d = TrustedProxies::parse("");
        assert_eq!(
            client_addr(sa("172.18.0.5:5555"), &h, &d, 1),
            ClientAddr::Untrusted(sa("172.18.0.5:5555"))
        );
    }

    #[test]
    fn forwarded_for_uses_the_last_hop() {
        let t = TrustedProxies::default();
        let h = headers(&[("X-Forwarded-For", "6.6.6.6, 203.0.113.7")]);
        assert_eq!(
            client_addr(sa("127.0.0.1:1"), &h, &t, 41).addr(),
            sa("203.0.113.7:42")
        );
        // IPv6 with X-Real-Port
        let h = headers(&[("X-Real-IP", "2001:db8::1"), ("X-Real-Port", "443")]);
        assert_eq!(
            client_addr(sa("127.0.0.1:1"), &h, &t, 1).addr(),
            sa("[2001:db8::1]:443")
        );
        // ip:port form in XFF
        let h = headers(&[("X-Forwarded-For", "[2001:db8::2]:999")]);
        assert_eq!(
            client_addr(sa("127.0.0.1:1"), &h, &t, 1).addr().ip(),
            sa("[2001:db8::2]:1").ip()
        );
        // garbage from a trusted proxy falls back to the proxy address
        let h = headers(&[("X-Real-IP", "not-an-ip")]);
        assert_eq!(
            client_addr(sa("127.0.0.1:7"), &h, &t, 1),
            ClientAddr::Conflicting(sa("127.0.0.1:7"))
        );
    }

    #[test]
    fn ambiguous_proxy_headers_fail_closed() {
        let t = TrustedProxies::default();
        let proxy = sa("127.0.0.1:7");
        // both headers, agreeing (what the sample nginx conf sends)
        let h = headers(&[("X-Real-IP", "203.0.113.7"), ("X-Forwarded-For", "203.0.113.7")]);
        assert_eq!(client_addr(proxy, &h, &t, 1).addr().ip(), sa("203.0.113.7:1").ip());
        // an appending proxy: the client's own XFF entries come first
        let h = headers(&[
            ("X-Real-IP", "203.0.113.7"),
            ("X-Forwarded-For", "6.6.6.6, 203.0.113.7"),
        ]);
        assert_eq!(client_addr(proxy, &h, &t, 1).addr().ip(), sa("203.0.113.7:1").ip());
        // the proxy manages only XFF, the client adds X-Real-IP
        let h = headers(&[("X-Real-IP", "6.6.6.6"), ("X-Forwarded-For", "203.0.113.7")]);
        assert_eq!(client_addr(proxy, &h, &t, 1), ClientAddr::Conflicting(proxy));
        // the proxy manages only X-Real-IP, the client adds XFF
        let h = headers(&[("X-Real-IP", "203.0.113.7"), ("X-Forwarded-For", "6.6.6.6")]);
        assert_eq!(client_addr(proxy, &h, &t, 1), ClientAddr::Conflicting(proxy));
        // a repeated X-Real-IP
        let mut h = HeaderMap::new();
        h.append("X-Real-IP", "6.6.6.6".parse().unwrap());
        h.append("X-Real-IP", "203.0.113.7".parse().unwrap());
        assert_eq!(client_addr(proxy, &h, &t, 1), ClientAddr::Conflicting(proxy));
        // XFF on several lines: the last hop of the last line
        let mut h = HeaderMap::new();
        h.append("X-Forwarded-For", "6.6.6.6".parse().unwrap());
        h.append("X-Forwarded-For", "7.7.7.7, 203.0.113.7".parse().unwrap());
        assert_eq!(client_addr(proxy, &h, &t, 1).addr().ip(), sa("203.0.113.7:1").ip());
        // a repeated X-Real-Port is not used
        let mut h = headers(&[("X-Real-IP", "203.0.113.7")]);
        h.append("X-Real-Port", "1111".parse().unwrap());
        h.append("X-Real-Port", "2222".parse().unwrap());
        let port = client_addr(proxy, &h, &t, 5).addr().port();
        assert_eq!(port, synthetic_port(5));
    }

    #[test]
    fn clients_behind_one_nat_get_distinct_ports() {
        let t = TrustedProxies::default();
        let h = headers(&[("X-Real-IP", "203.0.113.7")]);
        let a = client_addr(sa("127.0.0.1:1"), &h, &t, 1).addr();
        let b = client_addr(sa("127.0.0.1:1"), &h, &t, 2).addr();
        assert_eq!(a.ip(), b.ip());
        assert_ne!(a, b);
        assert_ne!(a.port(), 0);
        assert_ne!(synthetic_port(65534), 0);
        assert_ne!(synthetic_port(65535), 0);
        // X-Real-Port 0 is not a port
        let h = headers(&[("X-Real-IP", "203.0.113.7"), ("X-Real-Port", "0")]);
        assert_ne!(client_addr(sa("127.0.0.1:1"), &h, &t, 9).addr().port(), 0);
    }

    #[test]
    fn invalid_cidrs_are_skipped() {
        let t = TrustedProxies::parse("bogus,10.0.0.0/8 192.168.1.1/33");
        assert!(t.contains("10.9.9.9".parse().unwrap()));
        assert!(!t.contains("192.168.1.1".parse().unwrap()));
        assert!(t.contains("::1".parse().unwrap()));
    }

    fn punch() -> RendezvousMessage {
        let mut m = RendezvousMessage::new();
        m.set_punch_hole(PunchHole::default());
        m
    }

    #[test]
    fn routes_only_registered_ids() {
        let peers = WsPeers::new(settings());
        let (tx, mut rx) = WsTx::channel();
        assert_eq!(peers.route("dev1", &punch()), Route::NotWsPeer);
        assert_eq!(
            peers.insert("dev1", 1, tx),
            Insert::Stored { replaced: false }
        );
        assert_eq!(peers.route("dev1", &punch()), Route::Sent);
        assert_eq!(peers.route("dev2", &punch()), Route::NotWsPeer);
        match rx.try_recv() {
            Ok(Out::Frame(b)) => assert!(RendezvousMessage::parse_from_bytes(&b)
                .unwrap()
                .has_punch_hole()),
            other => panic!("unexpected {other:?}"),
        }
        drop(rx);
        // a registered peer whose writer is gone is not sent over UDP instead
        assert_eq!(peers.route("dev1", &punch()), Route::Dropped);
    }

    #[test]
    fn full_queue_drops() {
        let peers = WsPeers::new(settings());
        let (tx, _rx) = WsTx::channel();
        peers.insert("dev1", 1, tx);
        for _ in 0..CHANNEL_CAP {
            assert_eq!(peers.route("dev1", &punch()), Route::Sent);
        }
        assert_eq!(peers.route("dev1", &punch()), Route::Dropped);
    }

    #[test]
    fn newest_connection_wins_and_cleanup_is_owner_checked() {
        let peers = WsPeers::new(settings());
        let (tx1, mut rx1) = WsTx::channel();
        let (tx2, mut rx2) = WsTx::channel();
        peers.insert("dev1", 1, tx1);
        assert_eq!(
            peers.insert("dev1", 2, tx2),
            Insert::Stored { replaced: true }
        );
        // the old connection is told to close
        assert!(matches!(rx1.try_recv(), Ok(Out::Close)));
        assert!(!peers.is_owner("dev1", 1));
        assert!(peers.is_owner("dev1", 2));
        // the old connection going away must not remove the new entry
        assert!(!peers.remove_if_owner("dev1", 1));
        assert_eq!(peers.route("dev1", &punch()), Route::Sent);
        assert!(matches!(rx2.try_recv(), Ok(Out::Frame(_))));
        assert!(peers.remove_if_owner("dev1", 2));
        assert!(!peers.contains("dev1"));
        // re-registering on the same connection replaces nothing
        let (tx3, _rx3) = WsTx::channel();
        peers.insert("dev1", 3, tx3.clone());
        assert_eq!(
            peers.insert("dev1", 3, tx3),
            Insert::Stored { replaced: false }
        );
    }

    #[test]
    fn max_peers_is_enforced() {
        let peers = WsPeers::new(settings());
        for i in 0..3 {
            let (tx, _) = WsTx::channel();
            assert_eq!(
                peers.insert(&format!("dev{i}"), i, tx),
                Insert::Stored { replaced: false }
            );
        }
        assert!(!peers.has_room_for("dev9"));
        assert!(peers.has_room_for("dev0"));
        let (tx, _) = WsTx::channel();
        assert_eq!(peers.insert("dev9", 9, tx), Insert::Full);
        // an existing id can still move to a new connection when full
        let (tx, _) = WsTx::channel();
        assert_eq!(
            peers.insert("dev0", 10, tx),
            Insert::Stored { replaced: true }
        );
        assert_eq!(peers.len(), 3);
    }

    #[test]
    fn per_ip_cap() {
        let peers = WsPeers::new(settings());
        let ip: IpAddr = "203.0.113.7".parse().unwrap();
        let a = peers.acquire_ip(ip).unwrap();
        let _b = peers.acquire_ip(ip).unwrap();
        assert!(peers.acquire_ip(ip).is_none());
        assert!(peers.acquire_ip("203.0.113.8".parse().unwrap()).is_some());
        drop(a);
        assert!(peers.acquire_ip(ip).is_some());
    }

    #[hbb_common::tokio::test]
    async fn writer_sends_keepalive_only_when_registered() {
        let (sink, mut out) = fmpsc::unbounded::<WsMessage>();
        let (tx, rx) = WsTx::channel();
        let ka = Arc::new(AtomicBool::new(false));
        let period = Duration::from_millis(200);
        let task = spawn_writer(sink.sink_map_err(|_| ()), rx, ka.clone(), period);
        tokio::time::sleep(period * 3 + period / 2).await;
        assert!(out.try_recv().is_err(), "no keepalive before registration");
        ka.store(true, Ordering::Relaxed);
        assert!(tx.send(b"x".to_vec()));
        assert_eq!(out.next().await, Some(WsMessage::Binary(b"x".to_vec())));
        let start = Instant::now();
        for _ in 0..3 {
            assert_eq!(out.next().await, Some(WsMessage::Binary(Vec::new())));
        }
        let took = start.elapsed();
        assert!(
            took >= period * 2 && took <= period * 3 + Duration::from_millis(150),
            "{took:?}"
        );
        tx.close();
        task.await.unwrap();
    }

    #[hbb_common::tokio::test]
    async fn writer_stops_when_all_senders_are_gone() {
        let (sink, _out) = fmpsc::unbounded::<WsMessage>();
        let (tx, rx) = WsTx::channel();
        let task = spawn_writer(
            sink.sink_map_err(|_| ()),
            rx,
            Default::default(),
            Duration::from_secs(12),
        );
        let probe = tx.clone();
        drop(tx);
        // a sender still exists, so the writer is running
        assert!(probe.send(vec![1]));
        drop(probe);
        task.await.unwrap();
    }
}
