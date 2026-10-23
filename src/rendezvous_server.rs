// NOTICE: This file is part of rustdesk-server (AGPL-3.0) and was modified
// by Patina contributors in 2026. See PATCHES.md for the list of changes.

use crate::common::*;
use crate::peer::*;
use crate::ws_peers::{self, Insert, Route, WsConn, WsPeers, WsSettings, WsTx};
use hbb_common::{
    allow_err, bail,
    bytes::{Bytes, BytesMut},
    bytes_codec::BytesCodec,
    config,
    futures::future::join_all,
    futures_util::{
        sink::SinkExt,
        stream::{SplitSink, StreamExt},
    },
    log,
    protobuf::{Message as _, MessageField},
    rendezvous_proto::{
        register_pk_response::Result::{TOO_FREQUENT, UUID_MISMATCH},
        *,
    },
    tcp::FramedStream,
    timeout,
    tokio::{
        self,
        io::{AsyncReadExt, AsyncWriteExt},
        net::{TcpListener, TcpStream},
        sync::{mpsc, Mutex},
        time::{interval, Duration},
    },
    tokio_util::codec::Framed,
    try_into_v4,
    udp::FramedSocket,
    AddrMangle, ResultType,
};
use ipnetwork::Ipv4Network;
use sodiumoxide::crypto::sign;
use std::{
    collections::{HashMap, VecDeque},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::atomic::{AtomicBool, AtomicUsize, Ordering},
    sync::Arc,
    time::Instant,
};

#[derive(Clone, Debug)]
enum Data {
    Msg(Box<RendezvousMessage>, SocketAddr),
    RelayServers0(String),
    RelayServers(RelayServers),
}

const REG_TIMEOUT: i64 = 30_000;
type TcpStreamSink = SplitSink<Framed<TcpStream, BytesCodec>, Bytes>;
enum Sink {
    TcpStream(TcpStreamSink),
    // WebSocket connections are written by their own task, see ws_peers
    Chan(WsTx),
}
type Sender = mpsc::UnboundedSender<Data>;
type Receiver = mpsc::UnboundedReceiver<Data>;
static ROTATION_RELAY_SERVER: AtomicUsize = AtomicUsize::new(0);
type RelayServers = Vec<String>;
const CHECK_RELAY_TIMEOUT: u64 = 3_000;
static ALWAYS_USE_RELAY: AtomicBool = AtomicBool::new(false);

// Store punch hole requests
use once_cell::sync::Lazy;
use tokio::sync::Mutex as TokioMutex; // differentiate if needed
#[derive(Clone)]
struct PunchReqEntry { tm: Instant, from_ip: String, to_ip: String, to_id: String }
static PUNCH_REQS: Lazy<TokioMutex<VecDeque<PunchReqEntry>>> = Lazy::new(|| TokioMutex::new(VecDeque::new()));
const PUNCH_REQ_DEDUPE_SEC: u64 = 60;
static PUNCH_REQ_MAX: Lazy<usize> =
    Lazy::new(|| get_arg("MAX_PUNCH_REQUESTS").parse().unwrap_or(100_000));

async fn record_punch_req(from_ip: String, to_ip: String, to_id: String) {
    let max = *PUNCH_REQ_MAX;
    if max == 0 { return; }
    let mut lock = PUNCH_REQS.lock().await;
    let mut dup = false;
    for e in lock.iter().rev().take(30) { // only check recent tail subset for speed
        if e.from_ip == from_ip && e.to_id == to_id {
            if e.tm.elapsed().as_secs() < PUNCH_REQ_DEDUPE_SEC { dup = true; }
            break;
        }
    }
    if !dup {
        if lock.len() >= max { lock.pop_front(); }
        lock.push_back(PunchReqEntry { tm: Instant::now(), from_ip, to_ip, to_id });
    }
}

#[derive(Clone)]
struct Inner {
    serial: i32,
    version: String,
    software_url: String,
    mask: Option<Ipv4Network>,
    local_ip: String,
    sk: Option<sign::SecretKey>,
}

#[derive(Clone)]
pub struct RendezvousServer {
    tcp_punch: Arc<Mutex<HashMap<SocketAddr, Sink>>>,
    pm: PeerMap,
    tx: Sender,
    relay_servers: Arc<RelayServers>,
    relay_servers0: Arc<RelayServers>,
    rendezvous_servers: Arc<Vec<String>>,
    inner: Arc<Inner>,
    ws_peers: WsPeers,
}

enum LoopFailure {
    UdpSocket,
    Listener3,
    Listener2,
    Listener,
    ConsoleListener,
}

impl RendezvousServer {
    pub fn start(port: i32, serial: i32, key: &str, rmem: usize) -> ResultType<()> {
        Self::start_with_bind(None, port, serial, key, rmem)
    }

    #[tokio::main(flavor = "multi_thread")]
    pub async fn start_with_bind(
        bind_addr: Option<IpAddr>,
        port: i32,
        serial: i32,
        key: &str,
        rmem: usize,
    ) -> ResultType<()> {
        let (key, sk) = Self::get_server_sk(key)?;
        let nat_port = port - 1;
        let ws_port = port + 2;
        let pm = PeerMap::new().await?;
        log::info!("serial={}", serial);
        let rendezvous_servers = get_servers(&get_arg("rendezvous-servers"), "rendezvous-servers");
        let mut socket = create_udp_listener(bind_addr, port, rmem).await?;
        let (tx, mut rx) = mpsc::unbounded_channel::<Data>();
        let software_url = get_arg("software-url");
        let version = hbb_common::get_version_from_url(&software_url);
        if !version.is_empty() {
            log::info!("software_url: {}, version: {}", software_url, version);
        }
        let mask = get_arg("mask").parse().ok();
        let local_ip = if mask.is_none() {
            "".to_owned()
        } else {
            get_arg_or(
                "local-ip",
                local_ip_address::local_ip()
                    .map(|x| x.to_string())
                    .unwrap_or_default(),
            )
        };
        let mut rs = Self {
            tcp_punch: Arc::new(Mutex::new(HashMap::new())),
            pm,
            tx: tx.clone(),
            relay_servers: Default::default(),
            relay_servers0: Default::default(),
            rendezvous_servers: Arc::new(rendezvous_servers),
            inner: Arc::new(Inner {
                serial,
                version,
                software_url,
                sk,
                mask,
                local_ip,
            }),
            ws_peers: WsPeers::new(WsSettings::from_env()),
        };
        rs.ws_peers.settings.log();
        log::info!("mask: {:?}", rs.inner.mask);
        log::info!("local-ip: {:?}", rs.inner.local_ip);
        std::env::set_var("PORT_FOR_API", port.to_string());
        rs.parse_relay_servers(&get_arg("relay-servers"));
        let mut listener = create_tcp_listener(bind_addr, port).await?;
        let mut listener2 = create_tcp_listener(bind_addr, nat_port).await?;
        let mut listener3 = create_tcp_listener(bind_addr, ws_port).await?;
        let mut listener_console = listen_console(bind_addr, nat_port as _).await?;
        log::info!("Listening on tcp/udp {}", listener.local_addr()?);
        log::info!(
            "Listening on tcp {}, extra port for NAT test",
            listener2.local_addr()?
        );
        log::info!("Listening on websocket {}", listener3.local_addr()?);
        let test_addr = get_arg("TEST_HBBS");
        if get_arg("ALWAYS_USE_RELAY").to_uppercase() == "Y" {
            ALWAYS_USE_RELAY.store(true, Ordering::SeqCst);
        }
        log::info!(
            "ALWAYS_USE_RELAY={}",
            if ALWAYS_USE_RELAY.load(Ordering::SeqCst) {
                "Y"
            } else {
                "N"
            }
        );
        if test_addr.to_lowercase() != "no" {
            let test_addr = if test_addr.is_empty() {
                listener.local_addr()?
            } else {
                test_addr.parse()?
            };
            tokio::spawn(async move {
                if let Err(err) = test_hbbs(test_addr).await {
                    if test_addr.is_ipv6() && test_addr.ip().is_unspecified() {
                        let mut test_addr = test_addr;
                        test_addr.set_ip(IpAddr::V4(Ipv4Addr::UNSPECIFIED));
                        if let Err(err) = test_hbbs(test_addr).await {
                            log::error!("Failed to run hbbs test with {test_addr}: {err}");
                            std::process::exit(1);
                        }
                    } else {
                        log::error!("Failed to run hbbs test with {test_addr}: {err}");
                        std::process::exit(1);
                    }
                }
            });
        };
        let main_task = async move {
            loop {
                log::info!("Start");
                match rs
                    .io_loop(
                        &mut rx,
                        &mut listener,
                        &mut listener2,
                        &mut listener3,
                        &mut listener_console,
                        &mut socket,
                        &key,
                    )
                    .await
                {
                    LoopFailure::UdpSocket => {
                        drop(socket);
                        socket = create_udp_listener(bind_addr, port, rmem).await?;
                    }
                    LoopFailure::Listener => {
                        drop(listener);
                        listener = create_tcp_listener(bind_addr, port).await?;
                    }
                    LoopFailure::Listener2 => {
                        drop(listener2);
                        listener2 = create_tcp_listener(bind_addr, nat_port).await?;
                    }
                    LoopFailure::ConsoleListener => {
                        drop(listener_console.take());
                        listener_console = listen_console(bind_addr, nat_port as _).await?;
                    }
                    LoopFailure::Listener3 => {
                        drop(listener3);
                        listener3 = create_tcp_listener(bind_addr, ws_port).await?;
                    }
                }
            }
        };
        let listen_signal = listen_signal();
        tokio::select!(
            res = main_task => res,
            res = listen_signal => res,
        )
    }

    async fn io_loop(
        &mut self,
        rx: &mut Receiver,
        listener: &mut TcpListener,
        listener2: &mut TcpListener,
        listener3: &mut TcpListener,
        listener_console: &mut Option<TcpListener>,
        socket: &mut FramedSocket,
        key: &str,
    ) -> LoopFailure {
        let mut timer_check_relay = interval(Duration::from_millis(CHECK_RELAY_TIMEOUT));
        loop {
            tokio::select! {
                _ = timer_check_relay.tick() => {
                    if self.relay_servers0.len() > 1 {
                        let rs = self.relay_servers0.clone();
                        let tx = self.tx.clone();
                        tokio::spawn(async move {
                            check_relay_servers(rs, tx).await;
                        });
                    }
                }
                Some(data) = rx.recv() => {
                    match data {
                        Data::Msg(msg, addr) => { allow_err!(socket.send(msg.as_ref(), addr).await); }
                        Data::RelayServers0(rs) => { self.parse_relay_servers(&rs); }
                        Data::RelayServers(rs) => { self.relay_servers = Arc::new(rs); }
                    }
                }
                res = socket.next() => {
                    match res {
                        Some(Ok((bytes, addr))) => {
                            if let Err(err) = self.handle_udp(&bytes, addr.into(), socket, key).await {
                                log::error!("udp failure: {}", err);
                                return LoopFailure::UdpSocket;
                            }
                        }
                        Some(Err(err)) => {
                            log::error!("udp failure: {}", err);
                            return LoopFailure::UdpSocket;
                        }
                        None => {
                            // unreachable!() ?
                        }
                    }
                }
                res = listener2.accept() => {
                    match res {
                        Ok((stream, addr))  => {
                            stream.set_nodelay(true).ok();
                            self.handle_listener2(stream, addr).await;
                        }
                        Err(err) => {
                           log::error!("listener2.accept failed: {}", err);
                           return LoopFailure::Listener2;
                        }
                    }
                }
                res = accept_or_pending(listener_console.as_ref()) => {
                    match res {
                        Ok((stream, addr))  => {
                            stream.set_nodelay(true).ok();
                            self.handle_listener2(stream, addr).await;
                        }
                        Err(err) => {
                           log::error!("console listener.accept failed: {}", err);
                           return LoopFailure::ConsoleListener;
                        }
                    }
                }
                res = listener3.accept() => {
                    match res {
                        Ok((stream, addr))  => {
                            stream.set_nodelay(true).ok();
                            self.handle_listener(stream, addr, key, true).await;
                        }
                        Err(err) => {
                           log::error!("listener3.accept failed: {}", err);
                           return LoopFailure::Listener3;
                        }
                    }
                }
                res = listener.accept() => {
                    match res {
                        Ok((stream, addr)) => {
                            stream.set_nodelay(true).ok();
                            self.handle_listener(stream, addr, key, false).await;
                        }
                       Err(err) => {
                           log::error!("listener.accept failed: {}", err);
                           return LoopFailure::Listener;
                       }
                    }
                }
            }
        }
    }

    #[inline]
    async fn handle_udp(
        &mut self,
        bytes: &BytesMut,
        addr: SocketAddr,
        socket: &mut FramedSocket,
        key: &str,
    ) -> ResultType<()> {
        if let Ok(msg_in) = RendezvousMessage::parse_from_bytes(bytes) {
            match msg_in.union {
                Some(rendezvous_message::Union::RegisterPeer(rp)) => {
                    // B registered
                    if !rp.id.is_empty() && rp.id.len() <= MAX_PEER_ID_LEN {
                        log::trace!("New peer registered: {:?} {:?}", &rp.id, &addr);
                        self.update_addr(rp.id, addr, socket).await?;
                        if self.inner.serial > rp.serial {
                            let mut msg_out = RendezvousMessage::new();
                            msg_out.set_configure_update(ConfigUpdate {
                                serial: self.inner.serial,
                                rendezvous_servers: (*self.rendezvous_servers).clone(),
                                ..Default::default()
                            });
                            socket.send(&msg_out, addr).await?;
                        }
                    }
                }
                Some(rendezvous_message::Union::RegisterPk(rk)) => {
                    if let Some(res) = self.register_pk(rk, addr).await {
                        return send_rk_res(socket, addr, res).await;
                    }
                }
                Some(rendezvous_message::Union::PunchHoleRequest(ph)) => {
                    // UDP PunchHoleRequest is intentionally unsupported.
                    // The supported client path sends PunchHoleRequest over TCP/WS.
                }
                Some(rendezvous_message::Union::PunchHoleSent(phs)) => {
                    // UDP PunchHoleSent is intentionally unsupported to avoid UDP reflection/amplification
                }
                Some(rendezvous_message::Union::LocalAddr(la)) => {
                    // UDP LocalAddr is intentionally unsupported to avoid UDP reflection/amplification
                }
                Some(rendezvous_message::Union::ConfigureUpdate(mut cu)) => {
                    if try_into_v4(addr).ip().is_loopback() && cu.serial > self.inner.serial {
                        let mut inner: Inner = (*self.inner).clone();
                        inner.serial = cu.serial;
                        self.inner = Arc::new(inner);
                        self.rendezvous_servers = Arc::new(
                            cu.rendezvous_servers
                                .drain(..)
                                .filter(|x| {
                                    !x.is_empty()
                                        && test_if_valid_server(x, "rendezvous-server").is_ok()
                                })
                                .collect(),
                        );
                        log::info!(
                            "configure updated: serial={} rendezvous-servers={:?}",
                            self.inner.serial,
                            self.rendezvous_servers
                        );
                    }
                }
                Some(rendezvous_message::Union::SoftwareUpdate(su)) => {
                    if !self.inner.version.is_empty() && su.url != self.inner.version {
                        let mut msg_out = RendezvousMessage::new();
                        msg_out.set_software_update(SoftwareUpdate {
                            url: self.inner.software_url.clone(),
                            ..Default::default()
                        });
                        socket.send(&msg_out, addr).await?;
                    }
                }
                _ => {}
            }
        }
        Ok(())
    }

    /// The RegisterPk checks, shared by UDP and WebSocket so both apply the
    /// same id, IP-blocker, uuid/pk ownership and throttle rules. None means
    /// the request is ignored without a reply.
    async fn register_pk(
        &mut self,
        rk: RegisterPk,
        addr: SocketAddr,
    ) -> Option<register_pk_response::Result> {
        if rk.uuid.is_empty() || rk.pk.is_empty() {
            return None;
        }
        let id = rk.id;
        let ip = addr.ip().to_string();
        if id.len() < 6 || id.len() > MAX_PEER_ID_LEN {
            return Some(UUID_MISMATCH);
        } else if !self.check_ip_blocker(&ip, &id).await {
            return Some(TOO_FREQUENT);
        }
        let peer = self.pm.get_or(&id).await;
        let (changed, ip_changed) = {
            let peer = peer.read().await;
            if peer.uuid.is_empty() {
                (true, false)
            } else {
                if peer.uuid == rk.uuid {
                    if peer.info.ip != ip && peer.pk != rk.pk {
                        log::warn!(
                            "Peer {} ip/pk mismatch: {}/{:?} vs {}/{:?}",
                            id,
                            ip,
                            rk.pk,
                            peer.info.ip,
                            peer.pk,
                        );
                        return Some(UUID_MISMATCH);
                    }
                } else {
                    log::warn!(
                        "Peer {} uuid mismatch: {:?} vs {:?}",
                        id,
                        rk.uuid,
                        peer.uuid
                    );
                    return Some(UUID_MISMATCH);
                }
                let ip_changed = peer.info.ip != ip;
                (
                    peer.uuid != rk.uuid || peer.pk != rk.pk || ip_changed,
                    ip_changed,
                )
            }
        };
        let mut req_pk = peer.read().await.reg_pk;
        if req_pk.1.elapsed().as_secs() > 6 {
            req_pk.0 = 0;
        } else if req_pk.0 > 2 {
            return Some(TOO_FREQUENT);
        }
        req_pk.0 += 1;
        req_pk.1 = Instant::now();
        peer.write().await.reg_pk = req_pk;
        if ip_changed {
            let mut lock = IP_CHANGES.lock().await;
            if let Some((tm, ips)) = lock.get_mut(&id) {
                if tm.elapsed().as_secs() > IP_CHANGE_DUR {
                    *tm = Instant::now();
                    ips.clear();
                    ips.insert(ip.clone(), 1);
                } else if let Some(v) = ips.get_mut(&ip) {
                    *v += 1;
                } else {
                    ips.insert(ip.clone(), 1);
                }
            } else {
                lock.insert(
                    id.clone(),
                    (Instant::now(), HashMap::from([(ip.clone(), 1)])),
                );
            }
        }
        if changed {
            self.pm.update_pk(id, peer, addr, rk.uuid, rk.pk, ip).await;
        }
        Some(register_pk_response::Result::OK)
    }

    #[inline]
    async fn handle_tcp(
        &mut self,
        bytes: &[u8],
        sink: &mut Option<Sink>,
        addr: SocketAddr,
        key: &str,
        ws: bool,
        ws_conn: Option<&mut WsConn>,
    ) -> bool {
        if let Ok(msg_in) = RendezvousMessage::parse_from_bytes(bytes) {
            match msg_in.union {
                Some(rendezvous_message::Union::PunchHoleRequest(ph)) => {
                    // there maybe several attempt, so sink can be none
                    if let Some(sink) = sink.take() {
                        self.tcp_punch.lock().await.insert(try_into_v4(addr), sink);
                    }
                    allow_err!(self.handle_tcp_punch_hole_request(addr, ph, key, ws).await);
                    return true;
                }
                Some(rendezvous_message::Union::RequestRelay(mut rf)) => {
                    // there maybe several attempt, so sink can be none
                    if let Some(sink) = sink.take() {
                        self.tcp_punch.lock().await.insert(try_into_v4(addr), sink);
                    }
                    if let Some(peer) = self.pm.get_in_memory(&rf.id).await {
                        let id = rf.id.clone();
                        if !self.ws_relay_allowed(&id, &rf.relay_server) {
                            return true;
                        }
                        let mut msg_out = RendezvousMessage::new();
                        rf.socket_addr = AddrMangle::encode(addr).into();
                        msg_out.set_request_relay(rf);
                        if self.ws_peers.route(&id, &msg_out) == Route::NotWsPeer {
                            let peer_addr = peer.read().await.socket_addr;
                            self.tx.send(Data::Msg(msg_out.into(), peer_addr)).ok();
                        }
                    }
                    return true;
                }
                Some(rendezvous_message::Union::RelayResponse(mut rr)) => {
                    let addr_b = AddrMangle::decode(&rr.socket_addr);
                    rr.socket_addr = Default::default();
                    let id = rr.id();
                    if !id.is_empty() {
                        let pk = self.get_pk(&rr.version, id.to_owned()).await;
                        rr.set_pk(pk);
                    }
                    let mut msg_out = RendezvousMessage::new();
                    if !rr.relay_server.is_empty() {
                        if self.is_lan(addr_b) {
                            // https://github.com/rustdesk/rustdesk-server/issues/24
                            rr.relay_server = self.inner.local_ip.clone();
                        } else if rr.relay_server == self.inner.local_ip {
                            rr.relay_server = self.get_relay_server(addr.ip(), addr_b.ip());
                        }
                    }
                    msg_out.set_relay_response(rr);
                    allow_err!(self.send_to_tcp_sync(msg_out, addr_b).await);
                }
                Some(rendezvous_message::Union::PunchHoleSent(phs)) => {
                    allow_err!(self.handle_hole_sent(phs, addr, None).await);
                }
                Some(rendezvous_message::Union::LocalAddr(la)) => {
                    allow_err!(self.handle_local_addr(la, addr, None).await);
                }
                Some(rendezvous_message::Union::TestNatRequest(tar)) => {
                    let mut msg_out = RendezvousMessage::new();
                    let mut res = TestNatResponse {
                        port: addr.port() as _,
                        ..Default::default()
                    };
                    if self.inner.serial > tar.serial {
                        let mut cu = ConfigUpdate::new();
                        cu.serial = self.inner.serial;
                        cu.rendezvous_servers = (*self.rendezvous_servers).clone();
                        res.cu = MessageField::from_option(Some(cu));
                    }
                    msg_out.set_test_nat_response(res);
                    Self::send_to_sink(sink, msg_out).await;
                }
                Some(rendezvous_message::Union::RegisterPk(rk)) => {
                    if let Some(conn) = ws_conn {
                        return self.handle_ws_register_pk(rk, addr, conn).await;
                    }
                    let res = register_pk_response::Result::NOT_SUPPORT;
                    let mut msg_out = RendezvousMessage::new();
                    msg_out.set_register_pk_response(RegisterPkResponse {
                        result: res.into(),
                        ..Default::default()
                    });
                    Self::send_to_sink(sink, msg_out).await;
                }
                Some(rendezvous_message::Union::RegisterPeer(rp)) if ws_conn.is_some() => {
                    if let Some(conn) = ws_conn {
                        return self.handle_ws_register_peer(rp, conn).await;
                    }
                }
                Some(rendezvous_message::Union::OnlineRequest(or)) if ws_conn.is_some() => {
                    let mut msg_out = RendezvousMessage::new();
                    msg_out.set_online_response(OnlineResponse {
                        states: self.online_states(&or.peers).await.into(),
                        ..Default::default()
                    });
                    Self::send_to_sink(sink, msg_out).await;
                }
                _ => {}
            }
        }
        false
    }

    /// RegisterPk on a WebSocket connection (WS_REGISTER=Y). On OK the
    /// connection becomes the route to the device and stays open. Returns
    /// false to close the connection.
    async fn handle_ws_register_pk(
        &mut self,
        rk: RegisterPk,
        addr: SocketAddr,
        conn: &mut WsConn,
    ) -> bool {
        let id = rk.id.clone();
        if let Some(bound) = conn.id.as_deref() {
            if bound != id {
                log::warn!(
                    "WebSocket {} registered as {} and then asked for {}, closing",
                    addr,
                    bound,
                    id
                );
                return false;
            }
            // newest wins: a superseded connection must not take the id back
            if !self.ws_peers.is_owner(bound, conn.conn_id) {
                log::info!(
                    "WebSocket {} lost {} to a newer connection, closing",
                    addr,
                    bound
                );
                return false;
            }
        }
        if !self.ws_peers.has_room_for(&id) {
            log::warn!("MAX_WS_PEERS reached, refusing {} from {}", id, addr);
            Self::send_ws_rk_res(conn, register_pk_response::Result::SERVER_ERROR, 0);
            return false;
        }
        let res = match self.register_pk(rk, addr).await {
            Some(res) => res,
            None => return true,
        };
        if res != register_pk_response::Result::OK {
            Self::send_ws_rk_res(conn, res, 0);
            return true;
        }
        if self.ws_peers.insert(&id, conn.conn_id, conn.tx.clone()) == Insert::Full {
            log::warn!("MAX_WS_PEERS reached, refusing {} from {}", id, addr);
            Self::send_ws_rk_res(conn, register_pk_response::Result::SERVER_ERROR, 0);
            return false;
        }
        if let Some(peer) = self.pm.get_in_memory(&id).await {
            let mut peer = peer.write().await;
            peer.socket_addr = addr;
            peer.last_reg_time = Instant::now();
        }
        if conn.id.is_none() {
            log::info!("WebSocket peer {} registered from {}", id, addr);
        }
        conn.id = Some(id);
        conn.keepalive.store(true, Ordering::Relaxed);
        let keep_alive = self.ws_peers.settings.client_keep_alive();
        Self::send_ws_rk_res(conn, register_pk_response::Result::OK, keep_alive);
        true
    }

    /// RegisterPeer on a WebSocket is only a refresh for the id this
    /// connection already registered with RegisterPk; it never binds an id.
    async fn handle_ws_register_peer(&mut self, rp: RegisterPeer, conn: &WsConn) -> bool {
        let owned = conn.id.as_deref() == Some(rp.id.as_str())
            && self.ws_peers.is_owner(&rp.id, conn.conn_id);
        if owned {
            self.touch_ws_peer(&rp.id).await;
        }
        let mut msg_out = RendezvousMessage::new();
        msg_out.set_register_peer_response(RegisterPeerResponse {
            request_pk: !owned,
            ..Default::default()
        });
        conn.tx.send_msg(&msg_out);
        true
    }

    /// An empty frame from a registered WebSocket is the device's heartbeat
    /// (the echo of our keepalive). Returns false if the connection lost its
    /// id to a newer one.
    async fn handle_ws_heartbeat(&mut self, conn: &WsConn) -> bool {
        match conn.id.as_deref() {
            Some(id) if self.ws_peers.is_owner(id, conn.conn_id) => {
                self.touch_ws_peer(id).await;
                true
            }
            _ => false,
        }
    }

    async fn touch_ws_peer(&self, id: &str) {
        if let Some(peer) = self.pm.get_in_memory(id).await {
            peer.write().await.last_reg_time = Instant::now();
        }
    }

    /// Reader exit: drop the route if this connection still owns it, and mark
    /// the device offline at once instead of after REG_TIMEOUT.
    async fn handle_ws_closed(&mut self, conn: &WsConn) {
        let Some(id) = conn.id.as_deref() else {
            return;
        };
        if !self.ws_peers.remove_if_owner(id, conn.conn_id) {
            return;
        }
        log::info!("WebSocket peer {} disconnected", id);
        if let Some(peer) = self.pm.get_in_memory(id).await {
            let mut peer = peer.write().await;
            // a newer connection may have registered meanwhile
            if !self.ws_peers.contains(id) {
                peer.last_reg_time = get_expired_time();
            }
        }
    }

    /// RequestRelay names its relay server itself and carries no licence key.
    /// For a device on WebSocket only relays from -r are allowed (none if -r
    /// is not set), so nobody can point the device at a host of their
    /// choosing and learn its address. A WS device answers PunchHole with a
    /// relay on its own and does not need RequestRelay.
    fn ws_relay_allowed(&self, id: &str, relay_server: &str) -> bool {
        if !self.ws_peers.contains(id) {
            return true;
        }
        let host = |s: &str| {
            let s = s.trim();
            match s.rsplit_once(':') {
                Some((h, p)) if !h.contains(':') && p.parse::<u16>().is_ok() => h.to_owned(),
                _ => s.to_owned(),
            }
            .to_lowercase()
        };
        let wanted = host(relay_server);
        let ok = !wanted.is_empty() && self.relay_servers0.iter().any(|r| host(r) == wanted);
        if !ok {
            log::warn!(
                "RequestRelay for WebSocket peer {} names relay {:?}, not in relay-servers; dropped",
                id,
                relay_server
            );
        }
        ok
    }

    fn send_ws_rk_res(conn: &WsConn, res: register_pk_response::Result, keep_alive: i32) {
        let mut msg_out = RendezvousMessage::new();
        msg_out.set_register_pk_response(RegisterPkResponse {
            result: res.into(),
            keep_alive,
            ..Default::default()
        });
        conn.tx.send_msg(&msg_out);
    }

    #[inline]
    async fn update_addr(
        &mut self,
        id: String,
        socket_addr: SocketAddr,
        socket: &mut FramedSocket,
    ) -> ResultType<()> {
        let (request_pk, ip_change) = if let Some(old) = self.pm.get_in_memory(&id).await {
            let mut old = old.write().await;
            let ip = socket_addr.ip();
            let ip_change = if old.socket_addr.port() != 0 {
                ip != old.socket_addr.ip()
            } else {
                ip.to_string() != old.info.ip
            } && !ip.is_loopback();
            let request_pk = old.pk.is_empty() || ip_change;
            if !request_pk {
                old.socket_addr = socket_addr;
                old.last_reg_time = Instant::now();
            }
            let ip_change = if ip_change && old.reg_pk.0 <= 2 {
                Some(if old.socket_addr.port() == 0 {
                    old.info.ip.clone()
                } else {
                    old.socket_addr.to_string()
                })
            } else {
                None
            };
            (request_pk, ip_change)
        } else {
            (true, None)
        };
        if let Some(old) = ip_change {
            log::info!("IP change of {} from {} to {}", id, old, socket_addr);
        }
        let mut msg_out = RendezvousMessage::new();
        msg_out.set_register_peer_response(RegisterPeerResponse {
            request_pk,
            ..Default::default()
        });
        socket.send(&msg_out, socket_addr).await
    }

    #[inline]
    async fn handle_hole_sent<'a>(
        &mut self,
        phs: PunchHoleSent,
        addr: SocketAddr,
        socket: Option<&'a mut FramedSocket>,
    ) -> ResultType<()> {
        // punch hole sent from B, tell A that B is ready to be connected
        let addr_a = AddrMangle::decode(&phs.socket_addr);
        log::debug!(
            "{} punch hole response to {:?} from {:?}",
            if socket.is_none() { "TCP" } else { "UDP" },
            &addr_a,
            &addr
        );
        let mut msg_out = RendezvousMessage::new();
        let mut p = PunchHoleResponse {
            socket_addr: AddrMangle::encode(addr).into(),
            pk: self.get_pk(&phs.version, phs.id).await,
            relay_server: phs.relay_server.clone(),
            ..Default::default()
        };
        if let Ok(t) = phs.nat_type.enum_value() {
            p.set_nat_type(t);
        }
        msg_out.set_punch_hole_response(p);
        if let Some(socket) = socket {
            socket.send(&msg_out, addr_a).await?;
        } else {
            self.send_to_tcp(msg_out, addr_a).await;
        }
        Ok(())
    }

    #[inline]
    async fn handle_local_addr<'a>(
        &mut self,
        la: LocalAddr,
        addr: SocketAddr,
        socket: Option<&'a mut FramedSocket>,
    ) -> ResultType<()> {
        // relay local addrs of B to A
        let addr_a = AddrMangle::decode(&la.socket_addr);
        log::debug!(
            "{} local addrs response to {:?} from {:?}",
            if socket.is_none() { "TCP" } else { "UDP" },
            &addr_a,
            &addr
        );
        let mut msg_out = RendezvousMessage::new();
        let mut p = PunchHoleResponse {
            socket_addr: la.local_addr.clone(),
            pk: self.get_pk(&la.version, la.id).await,
            relay_server: la.relay_server,
            ..Default::default()
        };
        p.set_is_local(true);
        msg_out.set_punch_hole_response(p);
        if let Some(socket) = socket {
            socket.send(&msg_out, addr_a).await?;
        } else {
            self.send_to_tcp(msg_out, addr_a).await;
        }
        Ok(())
    }

    #[inline]
    async fn handle_punch_hole_request(
        &mut self,
        addr: SocketAddr,
        ph: PunchHoleRequest,
        key: &str,
        ws: bool,
    ) -> ResultType<(RendezvousMessage, Option<SocketAddr>)> {
        let mut ph = ph;
        if !key.is_empty() && ph.licence_key != key {
            log::warn!("Authentication failed from {} for peer {} - invalid key", addr, ph.id);
            let mut msg_out = RendezvousMessage::new();
            msg_out.set_punch_hole_response(PunchHoleResponse {
                failure: punch_hole_response::Failure::LICENSE_MISMATCH.into(),
                ..Default::default()
            });
            return Ok((msg_out, None));
        }
        let id = ph.id;
        // punch hole request from A, relay to B,
        // check if in same intranet first,
        // fetch local addrs if in same intranet.
        // because punch hole won't work if in the same intranet,
        // all routers will drop such self-connections.
        if let Some(peer) = self.pm.get(&id).await {
            let (elapsed, peer_addr) = {
                let r = peer.read().await;
                (r.last_reg_time.elapsed().as_millis() as i64, r.socket_addr)
            };
            if elapsed >= REG_TIMEOUT {
                let mut msg_out = RendezvousMessage::new();
                msg_out.set_punch_hole_response(PunchHoleResponse {
                    failure: punch_hole_response::Failure::OFFLINE.into(),
                    ..Default::default()
                });
                return Ok((msg_out, None));
            }
            
            // record punch hole request (from addr -> peer id/peer_addr)
            record_punch_req(
                try_into_v4(addr).ip().to_string(),
                try_into_v4(peer_addr).ip().to_string(),
                id.clone(),
            )
            .await;

            let mut msg_out = RendezvousMessage::new();
            let peer_is_lan = self.is_lan(peer_addr);
            let is_lan = self.is_lan(addr);
            let mut relay_server = self.get_relay_server(addr.ip(), peer_addr.ip());
            if ALWAYS_USE_RELAY.load(Ordering::SeqCst) || (peer_is_lan ^ is_lan) {
                if peer_is_lan {
                    // https://github.com/rustdesk/rustdesk-server/issues/24
                    relay_server = self.inner.local_ip.clone()
                }
                ph.nat_type = NatType::SYMMETRIC.into(); // will force relay
            }
            let same_intranet: bool = !ws
                && (peer_is_lan && is_lan || {
                    match (peer_addr, addr) {
                        (SocketAddr::V4(a), SocketAddr::V4(b)) => a.ip() == b.ip(),
                        (SocketAddr::V6(a), SocketAddr::V6(b)) => a.ip() == b.ip(),
                        _ => false,
                    }
                });
            let socket_addr = AddrMangle::encode(addr).into();
            if same_intranet {
                log::debug!(
                    "Fetch local addr {:?} {:?} request from {:?}",
                    id,
                    peer_addr,
                    addr
                );
                msg_out.set_fetch_local_addr(FetchLocalAddr {
                    socket_addr,
                    relay_server,
                    ..Default::default()
                });
            } else {
                log::debug!(
                    "Punch hole {:?} {:?} request from {:?}",
                    id,
                    peer_addr,
                    addr
                );
                msg_out.set_punch_hole(PunchHole {
                    socket_addr,
                    nat_type: ph.nat_type,
                    relay_server,
                    ..Default::default()
                });
            }
            Ok((msg_out, Some(peer_addr)))
        } else {
            let mut msg_out = RendezvousMessage::new();
            msg_out.set_punch_hole_response(PunchHoleResponse {
                failure: punch_hole_response::Failure::ID_NOT_EXIST.into(),
                ..Default::default()
            });
            Ok((msg_out, None))
        }
    }

    #[inline]
    async fn handle_online_request(
        &mut self,
        stream: &mut FramedStream,
        peers: Vec<String>,
    ) -> ResultType<()> {
        let mut msg_out = RendezvousMessage::new();
        msg_out.set_online_response(OnlineResponse {
            states: self.online_states(&peers).await.into(),
            ..Default::default()
        });
        stream.send(&msg_out).await?;

        Ok(())
    }

    // A device on WebSocket refreshes last_reg_time with every heartbeat and
    // expires it when its connection closes, so the same test covers it.
    async fn online_states(&self, peers: &[String]) -> BytesMut {
        let mut states = BytesMut::zeroed((peers.len() + 7) / 8);
        for (i, peer_id) in peers.iter().enumerate() {
            if let Some(peer) = self.pm.get_in_memory(peer_id).await {
                let elapsed = peer.read().await.last_reg_time.elapsed().as_millis() as i64;
                // bytes index from left to right
                let states_idx = i / 8;
                let bit_idx = 7 - i % 8;
                if elapsed < REG_TIMEOUT {
                    states[states_idx] |= 0x01 << bit_idx;
                }
            }
        }
        states
    }

    #[inline]
    async fn send_to_tcp(&mut self, msg: RendezvousMessage, addr: SocketAddr) {
        let mut tcp = self.tcp_punch.lock().await.remove(&try_into_v4(addr));
        tokio::spawn(async move {
            Self::send_to_sink(&mut tcp, msg).await;
        });
    }

    #[inline]
    async fn send_to_sink(sink: &mut Option<Sink>, msg: RendezvousMessage) {
        if let Some(sink) = sink.as_mut() {
            if let Ok(bytes) = msg.write_to_bytes() {
                match sink {
                    Sink::TcpStream(s) => {
                        allow_err!(s.send(Bytes::from(bytes)).await);
                    }
                    Sink::Chan(tx) => {
                        tx.send(bytes);
                    }
                }
            }
        }
    }

    #[inline]
    async fn send_to_tcp_sync(
        &mut self,
        msg: RendezvousMessage,
        addr: SocketAddr,
    ) -> ResultType<()> {
        let mut sink = self.tcp_punch.lock().await.remove(&try_into_v4(addr));
        Self::send_to_sink(&mut sink, msg).await;
        Ok(())
    }

    #[inline]
    async fn handle_tcp_punch_hole_request(
        &mut self,
        addr: SocketAddr,
        ph: PunchHoleRequest,
        key: &str,
        ws: bool,
    ) -> ResultType<()> {
        let id = ph.id.clone();
        let (msg, to_addr) = self.handle_punch_hole_request(addr, ph, key, ws).await?;
        if let Some(addr) = to_addr {
            // PunchHole / FetchLocalAddr go down the device's WebSocket if it has one
            if self.ws_peers.route(&id, &msg) == Route::NotWsPeer {
                self.tx.send(Data::Msg(msg.into(), addr))?;
            }
        } else {
            self.send_to_tcp_sync(msg, addr).await?;
        }
        Ok(())
    }

    #[inline]
    async fn handle_udp_punch_hole_request(
        &mut self,
        addr: SocketAddr,
        ph: PunchHoleRequest,
        key: &str,
    ) -> ResultType<()> {
        let (msg, to_addr) = self.handle_punch_hole_request(addr, ph, key, false).await?;
        self.tx.send(Data::Msg(
            msg.into(),
            match to_addr {
                Some(addr) => addr,
                None => addr,
            },
        ))?;
        Ok(())
    }

    async fn check_ip_blocker(&self, ip: &str, id: &str) -> bool {
        let mut lock = IP_BLOCKER.lock().await;
        let now = Instant::now();
        if let Some(old) = lock.get_mut(ip) {
            let counter = &mut old.0;
            if counter.1.elapsed().as_secs() > IP_BLOCK_DUR {
                counter.0 = 0;
            } else if counter.0 > 30 {
                return false;
            }
            counter.0 += 1;
            counter.1 = now;

            let counter = &mut old.1;
            let is_new = counter.0.get(id).is_none();
            if counter.1.elapsed().as_secs() > DAY_SECONDS {
                counter.0.clear();
            } else if counter.0.len() > 300 {
                return !is_new;
            }
            if is_new {
                counter.0.insert(id.to_owned());
            }
            counter.1 = now;
        } else {
            lock.insert(ip.to_owned(), ((0, now), (Default::default(), now)));
        }
        true
    }

    fn parse_relay_servers(&mut self, relay_servers: &str) {
        let rs = get_servers(relay_servers, "relay-servers");
        self.relay_servers0 = Arc::new(rs);
        self.relay_servers = self.relay_servers0.clone();
    }

    fn get_relay_server(&self, _pa: IpAddr, _pb: IpAddr) -> String {
        if self.relay_servers.is_empty() {
            return "".to_owned();
        } else if self.relay_servers.len() == 1 {
            return self.relay_servers[0].clone();
        }
        let i = ROTATION_RELAY_SERVER.fetch_add(1, Ordering::SeqCst) % self.relay_servers.len();
        self.relay_servers[i].clone()
    }

    async fn check_cmd(&self, cmd: &str) -> String {
        use std::fmt::Write as _;

        let mut res = "".to_owned();
        let mut fds = cmd.trim().split(' ');
        match fds.next() {
            Some("h") => {
                res = format!(
                    "{}\n{}\n{}\n{}\n{}\n{}\n{}\n",
                    "relay-servers(rs) <separated by ,>",
                    "reload-geo(rg)",
                    "ip-blocker(ib) [<ip>|<number>] [-]",
                    "ip-changes(ic) [<id>|<number>] [-]",
                    "punch-requests(pr) [<number>] [-]",
                    "always-use-relay(aur)",
                    "test-geo(tg) <ip1> <ip2>"
                )
            }
            Some("relay-servers" | "rs") => {
                if let Some(rs) = fds.next() {
                    self.tx.send(Data::RelayServers0(rs.to_owned())).ok();
                } else {
                    for ip in self.relay_servers.iter() {
                        let _ = writeln!(res, "{ip}");
                    }
                }
            }
            Some("ip-blocker" | "ib") => {
                let mut lock = IP_BLOCKER.lock().await;
                lock.retain(|&_, (a, b)| {
                    a.1.elapsed().as_secs() <= IP_BLOCK_DUR
                        || b.1.elapsed().as_secs() <= DAY_SECONDS
                });
                res = format!("{}\n", lock.len());
                let ip = fds.next();
                let mut start = ip.map(|x| x.parse::<i32>().unwrap_or(-1)).unwrap_or(-1);
                if start < 0 {
                    if let Some(ip) = ip {
                        if let Some((a, b)) = lock.get(ip) {
                            let _ = writeln!(
                                res,
                                "{}/{}s {}/{}s",
                                a.0,
                                a.1.elapsed().as_secs(),
                                b.0.len(),
                                b.1.elapsed().as_secs()
                            );
                        }
                        if fds.next() == Some("-") {
                            lock.remove(ip);
                        }
                    } else {
                        start = 0;
                    }
                }
                if start >= 0 {
                    let mut it = lock.iter();
                    for i in 0..(start + 10) {
                        let x = it.next();
                        if x.is_none() {
                            break;
                        }
                        if i < start {
                            continue;
                        }
                        if let Some((ip, (a, b))) = x {
                            let _ = writeln!(
                                res,
                                "{}: {}/{}s {}/{}s",
                                ip,
                                a.0,
                                a.1.elapsed().as_secs(),
                                b.0.len(),
                                b.1.elapsed().as_secs()
                            );
                        }
                    }
                }
            }
            Some("ip-changes" | "ic") => {
                let mut lock = IP_CHANGES.lock().await;
                lock.retain(|&_, v| v.0.elapsed().as_secs() < IP_CHANGE_DUR_X2 && v.1.len() > 1);
                res = format!("{}\n", lock.len());
                let id = fds.next();
                let mut start = id.map(|x| x.parse::<i32>().unwrap_or(-1)).unwrap_or(-1);
                if !(0..=10_000_000).contains(&start) {
                    if let Some(id) = id {
                        if let Some((tm, ips)) = lock.get(id) {
                            let _ = writeln!(res, "{}s {:?}", tm.elapsed().as_secs(), ips);
                        }
                        if fds.next() == Some("-") {
                            lock.remove(id);
                        }
                    } else {
                        start = 0;
                    }
                }
                if start >= 0 {
                    let mut it = lock.iter();
                    for i in 0..(start + 10) {
                        let x = it.next();
                        if x.is_none() {
                            break;
                        }
                        if i < start {
                            continue;
                        }
                        if let Some((id, (tm, ips))) = x {
                            let _ = writeln!(res, "{}: {}s {:?}", id, tm.elapsed().as_secs(), ips,);
                        }
                    }
                }
            }
            Some("punch-requests" | "pr") => {
                use std::fmt::Write as _;
                let mut lock = PUNCH_REQS.lock().await;
                let arg = fds.next();
                if let Some("-") = arg { lock.clear(); }
                else {
                    let mut start = arg.and_then(|x| x.parse::<usize>().ok()).unwrap_or(0);
                    let mut page_size = fds.next().and_then(|x| x.parse::<usize>().ok()).unwrap_or(10);
                    if page_size == 0 { page_size = 10; }
                    for (_, e) in lock.iter().enumerate().skip(start).take(page_size) {
                        let age = e.tm.elapsed();
                        let event_system = std::time::SystemTime::now() - age;
                        let event_iso = chrono::DateTime::<chrono::Utc>::from(event_system)
                            .to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
                        let _ = writeln!(res, "{} {} -> {}@{}", event_iso, e.from_ip, e.to_id, e.to_ip);
                    }
                }
            }
            Some("always-use-relay" | "aur") => {
                if let Some(rs) = fds.next() {
                    if rs.to_uppercase() == "Y" {
                        ALWAYS_USE_RELAY.store(true, Ordering::SeqCst);
                    } else {
                        ALWAYS_USE_RELAY.store(false, Ordering::SeqCst);
                    }
                    self.tx.send(Data::RelayServers0(rs.to_owned())).ok();
                } else {
                    let _ = writeln!(
                        res,
                        "ALWAYS_USE_RELAY: {:?}",
                        ALWAYS_USE_RELAY.load(Ordering::SeqCst)
                    );
                }
            }
            Some("test-geo" | "tg") => {
                if let Some(rs) = fds.next() {
                    if let Ok(a) = rs.parse::<IpAddr>() {
                        if let Some(rs) = fds.next() {
                            if let Ok(b) = rs.parse::<IpAddr>() {
                                res = format!("{:?}", self.get_relay_server(a, b));
                            }
                        } else {
                            res = format!("{:?}", self.get_relay_server(a, a));
                        }
                    }
                }
            }
            _ => {}
        }
        res
    }

    async fn handle_listener2(&self, stream: TcpStream, addr: SocketAddr) {
        let mut rs = self.clone();
        let ip = try_into_v4(addr).ip();
        if ip.is_loopback() {
            tokio::spawn(async move {
                let mut stream = stream;
                let mut buffer = [0; 1024];
                if let Ok(Ok(n)) = timeout(1000, stream.read(&mut buffer[..])).await {
                    if let Ok(data) = std::str::from_utf8(&buffer[..n]) {
                        let res = rs.check_cmd(data).await;
                        stream.write(res.as_bytes()).await.ok();
                    }
                }
            });
            return;
        }
        let stream = FramedStream::from(stream, addr);
        tokio::spawn(async move {
            let mut stream = stream;
            if let Some(Ok(bytes)) = stream.next_timeout(30_000).await {
                if let Ok(msg_in) = RendezvousMessage::parse_from_bytes(&bytes) {
                    match msg_in.union {
                        Some(rendezvous_message::Union::TestNatRequest(_)) => {
                            let mut msg_out = RendezvousMessage::new();
                            msg_out.set_test_nat_response(TestNatResponse {
                                port: addr.port() as _,
                                ..Default::default()
                            });
                            stream.send(&msg_out).await.ok();
                        }
                        Some(rendezvous_message::Union::OnlineRequest(or)) => {
                            allow_err!(rs.handle_online_request(&mut stream, or.peers).await);
                        }
                        _ => {}
                    }
                }
            }
        });
    }

    async fn handle_listener(&self, stream: TcpStream, addr: SocketAddr, key: &str, ws: bool) {
        log::debug!("Tcp connection from {:?}, ws: {}", addr, ws);
        let mut rs = self.clone();
        let key = key.to_owned();
        tokio::spawn(async move {
            allow_err!(rs.handle_listener_inner(stream, addr, &key, ws).await);
        });
    }

    #[inline]
    async fn handle_listener_inner(
        &mut self,
        stream: TcpStream,
        mut addr: SocketAddr,
        key: &str,
        ws: bool,
    ) -> ResultType<()> {
        let mut sink;
        if ws {
            let (ws_stream, client, mut conn, rx) =
                ws_peers::accept(stream, addr, &self.ws_peers).await?;
            addr = client;
            let (a, mut b) = ws_stream.split();
            ws_peers::spawn_writer(
                a,
                rx,
                conn.keepalive.clone(),
                self.ws_peers.settings.keepalive,
            );
            let register = self.ws_peers.settings.register;
            sink = Some(Sink::Chan(conn.tx.clone()));
            loop {
                let msg = tokio::select! {
                    msg = timeout(30_000, b.next()) => msg,
                    // the writer stopped: send failed or a newer connection took the id
                    _ = conn.tx.closed() => break,
                };
                let Ok(Some(Ok(msg))) = msg else {
                    break;
                };
                if let tungstenite::Message::Binary(bytes) = msg {
                    if register && bytes.is_empty() && conn.id.is_some() {
                        if self.handle_ws_heartbeat(&conn).await {
                            continue;
                        }
                        break;
                    }
                    let conn = if register { Some(&mut conn) } else { None };
                    if !self.handle_tcp(&bytes, &mut sink, addr, key, ws, conn).await {
                        break;
                    }
                }
            }
            self.handle_ws_closed(&conn).await;
        } else {
            let (a, mut b) = Framed::new(stream, BytesCodec::new()).split();
            sink = Some(Sink::TcpStream(a));
            while let Ok(Some(Ok(bytes))) = timeout(30_000, b.next()).await {
                if !self.handle_tcp(&bytes, &mut sink, addr, key, ws, None).await {
                    break;
                }
            }
        }
        if sink.is_none() {
            self.tcp_punch.lock().await.remove(&try_into_v4(addr));
        }
        log::debug!("Tcp connection from {:?} closed", addr);
        Ok(())
    }

    #[inline]
    async fn get_pk(&mut self, version: &str, id: String) -> Bytes {
        if version.is_empty() || self.inner.sk.is_none() {
            Bytes::new()
        } else {
            match self.pm.get(&id).await {
                Some(peer) => {
                    let pk = peer.read().await.pk.clone();
                    sign::sign(
                        &hbb_common::message_proto::IdPk {
                            id,
                            pk,
                            ..Default::default()
                        }
                        .write_to_bytes()
                        .unwrap_or_default(),
                        self.inner.sk.as_ref().unwrap(),
                    )
                    .into()
                }
                _ => Bytes::new(),
            }
        }
    }

    #[inline]
    fn get_server_sk(key: &str) -> ResultType<(String, Option<sign::SecretKey>)> {
        let mut out_sk = None;
        let mut key = key.to_owned();
        if let Ok(sk) = base64::decode(&key) {
            if sk.len() == sign::SECRETKEYBYTES {
                log::info!("The key is a crypto private key");
                key = base64::encode(&sk[(sign::SECRETKEYBYTES / 2)..]);
                let mut tmp = [0u8; sign::SECRETKEYBYTES];
                tmp[..].copy_from_slice(&sk);
                out_sk = Some(sign::SecretKey(tmp));
            }
        }

        if key.is_empty() || key == "-" || key == "_" {
            let (pk, sk) = crate::common::gen_sk(0)?;
            out_sk = sk;
            if !key.is_empty() {
                key = pk;
            }
        }

        if !key.is_empty() {
            log::info!("Key: {}", key);
        }
        Ok((key, out_sk))
    }

    #[inline]
    fn is_lan(&self, addr: SocketAddr) -> bool {
        if let Some(network) = &self.inner.mask {
            match addr {
                SocketAddr::V4(v4_socket_addr) => {
                    return network.contains(*v4_socket_addr.ip());
                }

                SocketAddr::V6(v6_socket_addr) => {
                    if let Some(v4_addr) = v6_socket_addr.ip().to_ipv4() {
                        return network.contains(v4_addr);
                    }
                }
            }
        }
        false
    }
}

async fn check_relay_servers(rs0: Arc<RelayServers>, tx: Sender) {
    let mut futs = Vec::new();
    let rs = Arc::new(Mutex::new(Vec::new()));
    for x in rs0.iter() {
        let mut host = x.to_owned();
        if !host.contains(':') {
            host = format!("{}:{}", host, config::RELAY_PORT);
        }
        let rs = rs.clone();
        let x = x.clone();
        futs.push(tokio::spawn(async move {
            if FramedStream::new(&host, None, CHECK_RELAY_TIMEOUT)
                .await
                .is_ok()
            {
                rs.lock().await.push(x);
            }
        }));
    }
    join_all(futs).await;
    log::debug!("check_relay_servers");
    let rs = std::mem::take(&mut *rs.lock().await);
    if !rs.is_empty() {
        tx.send(Data::RelayServers(rs)).ok();
    }
}

// temp solution to solve udp socket failure
async fn test_hbbs(addr: SocketAddr) -> ResultType<()> {
    let mut addr = addr;
    if addr.ip().is_unspecified() {
        addr.set_ip(if addr.is_ipv4() {
            IpAddr::V4(Ipv4Addr::LOCALHOST)
        } else {
            IpAddr::V6(Ipv6Addr::LOCALHOST)
        });
    }

    let mut socket = FramedSocket::new(config::Config::get_any_listen_addr(addr.is_ipv4())).await?;
    let mut msg_out = RendezvousMessage::new();
    msg_out.set_register_peer(RegisterPeer {
        id: "(:test_hbbs:)".to_owned(),
        ..Default::default()
    });
    let mut last_time_recv = Instant::now();

    let mut timer = interval(Duration::from_secs(1));
    loop {
        tokio::select! {
          _ = timer.tick() => {
              if last_time_recv.elapsed().as_secs() > 12 {
                  bail!("Timeout of test_hbbs");
              }
              socket.send(&msg_out, addr).await?;
          }
          Some(Ok((bytes, _))) = socket.next() => {
              if let Ok(msg_in) = RendezvousMessage::parse_from_bytes(&bytes) {
                 log::trace!("Recv {:?} of test_hbbs", msg_in);
                 last_time_recv = Instant::now();
              }
          }
        }
    }
}

#[inline]
async fn send_rk_res(
    socket: &mut FramedSocket,
    addr: SocketAddr,
    res: register_pk_response::Result,
) -> ResultType<()> {
    let mut msg_out = RendezvousMessage::new();
    msg_out.set_register_pk_response(RegisterPkResponse {
        result: res.into(),
        ..Default::default()
    });
    socket.send(&msg_out, addr).await
}

async fn create_udp_listener(
    bind_addr: Option<IpAddr>,
    port: i32,
    rmem: usize,
) -> ResultType<FramedSocket> {
    if let Some(bind_addr) = bind_addr {
        let addr = SocketAddr::new(bind_addr, port as _);
        return FramedSocket::new_reuse(&addr, true, rmem).await;
    }
    let addr = SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), port as _);
    if let Ok(s) = FramedSocket::new_reuse(&addr, true, rmem).await {
        log::debug!("listen on udp {:?}", s.local_addr());
        return Ok(s);
    }
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), port as _);
    let s = FramedSocket::new_reuse(&addr, true, rmem).await?;
    log::debug!("listen on udp {:?}", s.local_addr());
    Ok(s)
}

#[inline]
async fn create_tcp_listener(bind_addr: Option<IpAddr>, port: i32) -> ResultType<TcpListener> {
    let s = listen_tcp(bind_addr, port as _).await?;
    log::debug!("listen on tcp {:?}", s.local_addr());
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[hbb_common::tokio::test]
    async fn udp_listener_uses_bind_address() {
        let bind_addr = IpAddr::V4(Ipv4Addr::LOCALHOST);
        let socket = create_udp_listener(Some(bind_addr), 0, 0).await.unwrap();
        assert_eq!(socket.local_addr().unwrap().ip(), bind_addr);
    }

    // tests that make punch requests must not run beside punch_reqs_bounded
    static PUNCH_TEST_LOCK: Lazy<TokioMutex<()>> = Lazy::new(|| TokioMutex::new(()));

    #[hbb_common::tokio::test]
    async fn punch_reqs_bounded() {
        let _punch = PUNCH_TEST_LOCK.lock().await;
        let max = *PUNCH_REQ_MAX;
        // 31 ids keep every request just outside the 30-entry dedupe window;
        // one request at least, so MAX_PUNCH_REQUESTS=0 is exercised too
        for i in 0..(max * 2).max(1) {
            record_punch_req(
                "1.2.3.4".to_owned(),
                "5.6.7.8".to_owned(),
                format!("peer{}", i % 31),
            )
            .await;
        }
        let lock = PUNCH_REQS.lock().await;
        assert_eq!(lock.len(), max);
        if max > 0 {
            // the oldest half is evicted and the newest kept
            assert_eq!(lock.front().unwrap().to_id, format!("peer{}", max % 31));
            assert_eq!(lock.back().unwrap().to_id, format!("peer{}", (max * 2 - 1) % 31));
        }
    }

    // ---- WebSocket registration (ws_peers) ----

    use crate::ws_peers::{tests::settings as ws_settings, Out};
    use hbb_common::tokio::sync::mpsc as tmpsc;

    static DB_LOCK: Lazy<TokioMutex<u32>> = Lazy::new(|| TokioMutex::new(0));

    async fn test_server(relay: &str) -> (RendezvousServer, Receiver, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let pm = {
            // PeerMap::new reads DB_URL from the environment
            let _guard = DB_LOCK.lock().await;
            std::env::set_var("DB_URL", dir.path().join("db.sqlite3"));
            PeerMap::new().await.unwrap()
        };
        let (tx, rx) = mpsc::unbounded_channel::<Data>();
        let mut rs = RendezvousServer {
            tcp_punch: Default::default(),
            pm,
            tx,
            relay_servers: Default::default(),
            relay_servers0: Default::default(),
            rendezvous_servers: Default::default(),
            inner: Arc::new(Inner {
                serial: 0,
                version: String::new(),
                software_url: String::new(),
                mask: None,
                local_ip: String::new(),
                sk: None,
            }),
            ws_peers: WsPeers::new(ws_settings()),
        };
        // set directly: parse_relay_servers drops names that do not resolve
        let relays: Vec<String> = relay.split(',').filter(|r| !r.is_empty()).map(String::from).collect();
        rs.relay_servers0 = Arc::new(relays);
        rs.relay_servers = rs.relay_servers0.clone();
        (rs, rx, dir)
    }

    fn register_pk(id: &str, uuid: &str, pk: &str) -> Vec<u8> {
        let mut m = RendezvousMessage::new();
        m.set_register_pk(RegisterPk {
            id: id.to_owned(),
            uuid: uuid.as_bytes().to_vec().into(),
            pk: pk.as_bytes().to_vec().into(),
            ..Default::default()
        });
        m.write_to_bytes().unwrap()
    }

    fn punch_request(id: &str) -> Vec<u8> {
        let mut m = RendezvousMessage::new();
        m.set_punch_hole_request(PunchHoleRequest {
            id: id.to_owned(),
            nat_type: NatType::SYMMETRIC.into(),
            force_relay: true,
            ..Default::default()
        });
        m.write_to_bytes().unwrap()
    }

    fn next_msg(rx: &mut tmpsc::Receiver<Out>) -> RendezvousMessage {
        match rx.try_recv() {
            Ok(Out::Frame(b)) => RendezvousMessage::parse_from_bytes(&b).unwrap(),
            other => panic!("expected a frame, got {other:?}"),
        }
    }

    fn rk_result(m: &RendezvousMessage) -> register_pk_response::Result {
        assert!(m.has_register_pk_response(), "{m:?}");
        m.register_pk_response().result.enum_value().unwrap()
    }

    fn sa(s: &str) -> SocketAddr {
        s.parse().unwrap()
    }

    /// One WebSocket connection: sink + per-connection state + writer queue.
    struct TestConn {
        sink: Option<Sink>,
        conn: WsConn,
        rx: tmpsc::Receiver<Out>,
        addr: SocketAddr,
    }

    impl TestConn {
        fn new(rs: &RendezvousServer, addr: &str) -> Self {
            let addr = sa(addr);
            let (conn, rx) = WsConn::for_test(&rs.ws_peers, addr.ip());
            Self {
                sink: Some(Sink::Chan(conn.tx.clone())),
                conn,
                rx,
                addr,
            }
        }

        async fn send(&mut self, rs: &mut RendezvousServer, bytes: &[u8]) -> bool {
            rs.handle_tcp(bytes, &mut self.sink, self.addr, "", true, Some(&mut self.conn))
                .await
        }
    }

    async fn is_online(rs: &RendezvousServer, id: &str) -> bool {
        rs.online_states(&[id.to_owned()]).await[0] & 0x80 != 0
    }

    #[hbb_common::tokio::test]
    async fn ws_register_and_route_punch_hole() {
        let _punch = PUNCH_TEST_LOCK.lock().await;
        let (mut rs, mut udp_rx, _db) = test_server("relay.example.com").await;
        let mut dev = TestConn::new(&rs, "203.0.113.1:40001");
        assert!(dev.send(&mut rs, &register_pk("wsdev01", "u1", "pk1")).await);
        let res = next_msg(&mut dev.rx);
        assert_eq!(rk_result(&res), register_pk_response::Result::OK);
        assert_eq!(res.register_pk_response().keep_alive, 36);
        assert!(dev.conn.keepalive.load(Ordering::Relaxed));
        assert_eq!(dev.conn.id.as_deref(), Some("wsdev01"));
        assert!(is_online(&rs, "wsdev01").await);

        // a controller asks for the WS device: PunchHole goes down the WebSocket
        let mut ctl = TestConn::new(&rs, "198.51.100.2:50000");
        assert!(ctl.send(&mut rs, &punch_request("wsdev01")).await);
        let ph = next_msg(&mut dev.rx);
        assert!(ph.has_punch_hole(), "{ph:?}");
        assert_eq!(
            AddrMangle::decode(&ph.punch_hole().socket_addr),
            sa("198.51.100.2:50000")
        );
        assert_eq!(ph.punch_hole().relay_server, "relay.example.com");
        assert!(udp_rx.try_recv().is_err(), "nothing may go out over UDP");
        // the controller's sink waits in tcp_punch for the RelayResponse
        assert!(rs.tcp_punch.lock().await.contains_key(&sa("198.51.100.2:50000")));

        // same intranet: FetchLocalAddr goes down the WebSocket as well
        let mut udp_ctl_sink: Option<Sink> = None;
        rs.handle_tcp_punch_hole_request(
            sa("203.0.113.1:1234"),
            PunchHoleRequest {
                id: "wsdev01".to_owned(),
                ..Default::default()
            },
            "",
            false,
        )
        .await
        .unwrap();
        let fla = next_msg(&mut dev.rx);
        assert!(fla.has_fetch_local_addr(), "{fla:?}");
        assert!(udp_rx.try_recv().is_err());
        drop(udp_ctl_sink.take());

        // RequestRelay goes down the WebSocket too
        let mut m = RendezvousMessage::new();
        m.set_request_relay(RequestRelay {
            id: "wsdev01".to_owned(),
            relay_server: "relay.example.com:21117".to_owned(),
            uuid: "x".to_owned(),
            ..Default::default()
        });
        let mut ctl2 = TestConn::new(&rs, "198.51.100.3:50000");
        assert!(ctl2.send(&mut rs, &m.write_to_bytes().unwrap()).await);
        assert!(next_msg(&mut dev.rx).has_request_relay());
        assert!(udp_rx.try_recv().is_err());
    }

    #[hbb_common::tokio::test]
    async fn udp_target_still_goes_over_udp() {
        let _punch = PUNCH_TEST_LOCK.lock().await;
        let (mut rs, mut udp_rx, _db) = test_server("").await;
        {
            let peer = rs.pm.get_or("udpdev1").await;
            let mut p = peer.write().await;
            p.socket_addr = sa("192.0.2.10:21116");
            p.uuid = Bytes::from_static(b"u");
            p.pk = Bytes::from_static(b"pk");
            p.last_reg_time = Instant::now();
        }
        let mut ctl = TestConn::new(&rs, "198.51.100.4:50000");
        assert!(ctl.send(&mut rs, &punch_request("udpdev1")).await);
        match udp_rx.try_recv() {
            Ok(Data::Msg(m, addr)) => {
                assert!(m.has_punch_hole());
                assert_eq!(addr, sa("192.0.2.10:21116"));
            }
            _ => panic!("expected a UDP PunchHole"),
        }
        // unknown id: the controller gets ID_NOT_EXIST on its own socket
        assert!(ctl.send(&mut rs, &punch_request("nobody1")).await);
        assert!(udp_rx.try_recv().is_err());
    }

    #[hbb_common::tokio::test]
    async fn ws_hijack_with_other_uuid_is_rejected() {
        let (mut rs, _udp_rx, _db) = test_server("").await;
        let mut dev = TestConn::new(&rs, "203.0.113.11:40001");
        assert!(dev.send(&mut rs, &register_pk("victim1", "uuid-a", "pk-a")).await);
        assert_eq!(rk_result(&next_msg(&mut dev.rx)), register_pk_response::Result::OK);

        // a second connection, other uuid, same id: UUID_MISMATCH as over UDP
        let mut evil = TestConn::new(&rs, "198.51.100.66:40002");
        assert!(evil.send(&mut rs, &register_pk("victim1", "uuid-b", "pk-b")).await);
        assert_eq!(
            rk_result(&next_msg(&mut evil.rx)),
            register_pk_response::Result::UUID_MISMATCH
        );
        assert!(evil.conn.id.is_none());
        assert!(!evil.conn.keepalive.load(Ordering::Relaxed));
        assert!(rs.ws_peers.is_owner("victim1", dev.conn.conn_id));
        assert!(dev.rx.try_recv().is_err(), "the owner is not disturbed");
        let peer = rs.pm.get_in_memory("victim1").await.unwrap();
        assert_eq!(&peer.read().await.uuid[..], b"uuid-a");
        assert_eq!(peer.read().await.socket_addr, sa("203.0.113.11:40001"));

        // RegisterPeer never binds an id to a connection
        let mut m = RendezvousMessage::new();
        m.set_register_peer(RegisterPeer {
            id: "victim1".to_owned(),
            ..Default::default()
        });
        assert!(evil.send(&mut rs, &m.write_to_bytes().unwrap()).await);
        let r = next_msg(&mut evil.rx);
        assert!(r.register_peer_response().request_pk);
        assert!(evil.conn.id.is_none());
        assert!(rs.ws_peers.is_owner("victim1", dev.conn.conn_id));
        // and an empty frame from an unregistered connection refreshes nothing
        assert!(!rs.handle_ws_heartbeat(&evil.conn).await);

        // closing the rejected connection leaves the device online
        rs.handle_ws_closed(&evil.conn).await;
        assert!(rs.ws_peers.is_owner("victim1", dev.conn.conn_id));
        assert!(is_online(&rs, "victim1").await);

        // RegisterPeer from the owner is a refresh
        assert!(dev.send(&mut rs, &m.write_to_bytes().unwrap()).await);
        assert!(!next_msg(&mut dev.rx).register_peer_response().request_pk);
    }

    #[hbb_common::tokio::test]
    async fn ws_reconnect_replaces_and_cleanup_is_owner_checked() {
        let (mut rs, _udp_rx, _db) = test_server("").await;
        let mut c1 = TestConn::new(&rs, "203.0.113.21:40001");
        assert!(c1.send(&mut rs, &register_pk("roam001", "u", "pk")).await);
        assert_eq!(rk_result(&next_msg(&mut c1.rx)), register_pk_response::Result::OK);

        let mut c2 = TestConn::new(&rs, "203.0.113.21:40002");
        assert!(c2.send(&mut rs, &register_pk("roam001", "u", "pk")).await);
        assert_eq!(rk_result(&next_msg(&mut c2.rx)), register_pk_response::Result::OK);
        // the older connection is told to close and no longer owns the id
        assert!(matches!(c1.rx.try_recv(), Ok(Out::Close)));
        assert!(rs.ws_peers.is_owner("roam001", c2.conn.conn_id));
        assert!(!rs.handle_ws_heartbeat(&c1.conn).await);
        // nor can it take the id back before its reader notices the close
        assert!(!c1.send(&mut rs, &register_pk("roam001", "u", "pk")).await);
        assert!(c1.rx.try_recv().is_err());
        assert!(rs.ws_peers.is_owner("roam001", c2.conn.conn_id));
        assert!(c2.rx.try_recv().is_err(), "the new owner is not closed");
        let peer = rs.pm.get_in_memory("roam001").await.unwrap();
        assert_eq!(peer.read().await.socket_addr, sa("203.0.113.21:40002"));

        // the old reader exiting must not take the new route down
        rs.handle_ws_closed(&c1.conn).await;
        assert!(rs.ws_peers.contains("roam001"));
        assert!(is_online(&rs, "roam001").await);

        // heartbeats keep the device online
        peer.write().await.last_reg_time = get_expired_time();
        assert!(!is_online(&rs, "roam001").await);
        assert!(rs.handle_ws_heartbeat(&c2.conn).await);
        assert!(is_online(&rs, "roam001").await);

        // the owner going away removes the route and shows offline at once
        rs.handle_ws_closed(&c2.conn).await;
        assert!(!rs.ws_peers.contains("roam001"));
        assert!(!is_online(&rs, "roam001").await);
    }

    #[hbb_common::tokio::test]
    async fn ws_one_id_per_connection() {
        let (mut rs, _udp_rx, _db) = test_server("").await;
        let mut c = TestConn::new(&rs, "203.0.113.31:40001");
        assert!(c.send(&mut rs, &register_pk("first01", "u1", "pk1")).await);
        assert_eq!(rk_result(&next_msg(&mut c.rx)), register_pk_response::Result::OK);
        assert!(!c.send(&mut rs, &register_pk("second1", "u2", "pk2")).await);
        assert!(!rs.ws_peers.contains("second1"));
        assert!(rs.pm.get_in_memory("second1").await.is_none());

        // before the first OK the id may change (the client regenerates its
        // id after UUID_MISMATCH and retries on the same connection)
        let mut d = TestConn::new(&rs, "203.0.113.32:40001");
        assert!(d.send(&mut rs, &register_pk("first01", "other", "pk9")).await);
        assert_eq!(
            rk_result(&next_msg(&mut d.rx)),
            register_pk_response::Result::UUID_MISMATCH
        );
        assert!(d.send(&mut rs, &register_pk("fresh01", "other", "pk9")).await);
        assert_eq!(rk_result(&next_msg(&mut d.rx)), register_pk_response::Result::OK);
        assert_eq!(d.conn.id.as_deref(), Some("fresh01"));
    }

    #[hbb_common::tokio::test]
    async fn ws_register_checks_match_udp() {
        let (mut rs, _udp_rx, _db) = test_server("").await;
        let mut c = TestConn::new(&rs, "203.0.113.41:40001");
        // too short an id
        assert!(c.send(&mut rs, &register_pk("abc", "u", "pk")).await);
        assert_eq!(
            rk_result(&next_msg(&mut c.rx)),
            register_pk_response::Result::UUID_MISMATCH
        );
        // empty uuid: ignored without a reply, as over UDP
        assert!(c.send(&mut rs, &register_pk("abcdef1", "", "pk")).await);
        assert!(c.rx.try_recv().is_err());
        assert!(c.conn.id.is_none());
        // the reg_pk throttle: three in a row are fine, the fourth is not
        for _ in 0..3 {
            assert!(c.send(&mut rs, &register_pk("thrott1", "u", "pk")).await);
            assert_eq!(rk_result(&next_msg(&mut c.rx)), register_pk_response::Result::OK);
        }
        assert!(c.send(&mut rs, &register_pk("thrott1", "u", "pk")).await);
        assert_eq!(
            rk_result(&next_msg(&mut c.rx)),
            register_pk_response::Result::TOO_FREQUENT
        );
        // still registered, the throttle does not drop the route
        assert!(rs.ws_peers.is_owner("thrott1", c.conn.conn_id));
    }

    #[hbb_common::tokio::test]
    async fn ws_max_peers() {
        let (mut rs, _udp_rx, _db) = test_server("").await;
        // ws_settings() allows 3 peers and 2 connections per IP
        for i in 0..3 {
            let mut c = TestConn::new(&rs, &format!("203.0.113.5{i}:40001"));
            assert!(c.send(&mut rs, &register_pk(&format!("full00{i}"), "u", "pk")).await);
            assert_eq!(rk_result(&next_msg(&mut c.rx)), register_pk_response::Result::OK);
            std::mem::forget(c); // keep the connection "open"
        }
        let mut c = TestConn::new(&rs, "203.0.113.59:40001");
        assert!(!c.send(&mut rs, &register_pk("full009", "u", "pk")).await);
        assert_eq!(
            rk_result(&next_msg(&mut c.rx)),
            register_pk_response::Result::SERVER_ERROR
        );
        assert!(rs.pm.get_in_memory("full009").await.is_none(), "no DB record either");
        assert_eq!(rs.ws_peers.len(), 3);
    }

    #[hbb_common::tokio::test]
    async fn ws_register_off_keeps_upstream_behaviour() {
        let (mut rs, _udp_rx, _db) = test_server("").await;
        let mut c = TestConn::new(&rs, "203.0.113.61:40001");
        // what handle_listener_inner passes with WS_REGISTER=N
        assert!(
            !rs.handle_tcp(&register_pk("plain01", "u", "pk"), &mut c.sink, c.addr, "", true, None)
                .await
        );
        assert_eq!(
            rk_result(&next_msg(&mut c.rx)),
            register_pk_response::Result::NOT_SUPPORT
        );
        assert!(!rs.ws_peers.contains("plain01"));
    }

    #[hbb_common::tokio::test]
    async fn ws_online_request() {
        let (mut rs, _udp_rx, _db) = test_server("").await;
        let mut dev = TestConn::new(&rs, "203.0.113.71:40001");
        assert!(dev.send(&mut rs, &register_pk("online1", "u", "pk")).await);
        next_msg(&mut dev.rx);
        let mut m = RendezvousMessage::new();
        m.set_online_request(OnlineRequest {
            id: "asker01".to_owned(),
            peers: vec!["nobody9".to_owned(), "online1".to_owned()],
            ..Default::default()
        });
        let mut q = TestConn::new(&rs, "198.51.100.71:40001");
        // answered, then the connection closes as on 21115
        assert!(!q.send(&mut rs, &m.write_to_bytes().unwrap()).await);
        let r = next_msg(&mut q.rx);
        assert_eq!(&r.online_response().states[..], &[0b0100_0000]);
    }

    #[hbb_common::tokio::test]
    async fn ws_request_relay_must_name_a_known_relay() {
        let (mut rs, _udp_rx, _db) = test_server("rd.example.com").await;
        let mut dev = TestConn::new(&rs, "203.0.113.81:40001");
        assert!(dev.send(&mut rs, &register_pk("relay01", "u", "pk")).await);
        next_msg(&mut dev.rx);
        assert!(rs.ws_relay_allowed("relay01", "rd.example.com"));
        assert!(rs.ws_relay_allowed("relay01", "RD.example.com:21117"));
        assert!(!rs.ws_relay_allowed("relay01", ""));
        assert!(!rs.ws_relay_allowed("relay01", "evil.example.net:21117"));
        // UDP peers keep upstream's behaviour
        assert!(rs.ws_relay_allowed("udponly", "evil.example.net"));

        let mut m = RendezvousMessage::new();
        m.set_request_relay(RequestRelay {
            id: "relay01".to_owned(),
            relay_server: "evil.example.net".to_owned(),
            ..Default::default()
        });
        let mut ctl = TestConn::new(&rs, "198.51.100.81:40001");
        assert!(ctl.send(&mut rs, &m.write_to_bytes().unwrap()).await);
        assert!(dev.rx.try_recv().is_err(), "not forwarded");

        // without -r there is nothing to check against: refused
        let (mut rs, _udp_rx, _db) = test_server("").await;
        let mut dev = TestConn::new(&rs, "203.0.113.82:40001");
        assert!(dev.send(&mut rs, &register_pk("relay02", "u", "pk")).await);
        next_msg(&mut dev.rx);
        assert!(!rs.ws_relay_allowed("relay02", "rd.example.com"));
        assert!(rs.ws_relay_allowed("udponly", "rd.example.com"));
    }
}
