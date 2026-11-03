use async_speed_limit::Limiter;
use async_trait::async_trait;
use hbb_common::{
    allow_err, bail,
    bytes::{Bytes, BytesMut},
    futures_util::{sink::SinkExt, stream::StreamExt},
    log,
    protobuf::Message as _,
    rendezvous_proto::*,
    sleep,
    tcp::FramedStream,
    timeout,
    tokio::{
        self,
        io::{AsyncReadExt, AsyncWriteExt},
        net::{TcpListener, TcpStream},
        sync::{Mutex, RwLock},
        time::{interval, Duration, Instant},
    },
    ResultType,
};
use sodiumoxide::crypto::sign;
use std::{
    collections::{HashMap, HashSet},
    io::prelude::*,
    io::Error,
    net::{IpAddr, SocketAddr},
    sync::atomic::{AtomicUsize, Ordering},
};

type Usage = (usize, usize, usize, usize);

lazy_static::lazy_static! {
    static ref PEERS: Mutex<HashMap<String, Box<dyn StreamTrait>>> = Default::default();
    static ref USAGE: RwLock<HashMap<String, Usage>> = Default::default();
    static ref BLACKLIST: RwLock<HashSet<String>> = Default::default();
    static ref BLOCKLIST: RwLock<HashSet<String>> = Default::default();
}

static DOWNGRADE_THRESHOLD_100: AtomicUsize = AtomicUsize::new(66); // 0.66
static DOWNGRADE_START_CHECK: AtomicUsize = AtomicUsize::new(1_800_000); // in ms
static LIMIT_SPEED: AtomicUsize = AtomicUsize::new(32 * 1024 * 1024); // in bit/s
static TOTAL_BANDWIDTH: AtomicUsize = AtomicUsize::new(1024 * 1024 * 1024); // in bit/s
static SINGLE_BANDWIDTH: AtomicUsize = AtomicUsize::new(128 * 1024 * 1024); // in bit/s
const BLACKLIST_FILE: &str = "blacklist.txt";
const BLOCKLIST_FILE: &str = "blocklist.txt";

#[tokio::main(flavor = "multi_thread")]
pub async fn start_with_bind(
    bind_addr: Option<IpAddr>,
    port: &str,
    key: &str,
) -> ResultType<()> {
    let key = get_server_sk(key)?;
    if let Ok(mut file) = std::fs::File::open(BLACKLIST_FILE) {
        let mut contents = String::new();
        if file.read_to_string(&mut contents).is_ok() {
            for x in contents.split('\n') {
                if let Some(ip) = x.trim().split(' ').next() {
                    BLACKLIST.write().await.insert(ip.to_owned());
                }
            }
        }
    }
    log::info!(
        "#blacklist({}): {}",
        BLACKLIST_FILE,
        BLACKLIST.read().await.len()
    );
    if let Ok(mut file) = std::fs::File::open(BLOCKLIST_FILE) {
        let mut contents = String::new();
        if file.read_to_string(&mut contents).is_ok() {
            for x in contents.split('\n') {
                if let Some(ip) = x.trim().split(' ').next() {
                    BLOCKLIST.write().await.insert(ip.to_owned());
                }
            }
        }
    }
    log::info!(
        "#blocklist({}): {}",
        BLOCKLIST_FILE,
        BLOCKLIST.read().await.len()
    );
    let port: u16 = port.parse()?;
    log::info!("Listening on tcp :{}", port);
    let port2 = port + 2;
    log::info!("Listening on websocket :{}", port2);
    let main_task = async move {
        loop {
            log::info!("Start");
            io_loop(
                crate::common::listen_tcp(bind_addr, port).await?,
                crate::common::listen_tcp(bind_addr, port2).await?,
                crate::common::listen_console(bind_addr, port).await?,
                &key,
            )
            .await;
        }
    };
    let listen_signal = crate::common::listen_signal();
    tokio::select!(
        res = main_task => res,
        res = listen_signal => res,
    )
}

fn check_params() {
    let tmp = crate::common::get_arg("DOWNGRADE_THRESHOLD")
        .parse::<f64>()
        .unwrap_or(0.);
    if tmp > 0. {
        DOWNGRADE_THRESHOLD_100.store((tmp * 100.) as _, Ordering::SeqCst);
    }
    log::info!(
        "DOWNGRADE_THRESHOLD: {}",
        DOWNGRADE_THRESHOLD_100.load(Ordering::SeqCst) as f64 / 100.
    );
    let tmp = crate::common::get_arg("DOWNGRADE_START_CHECK")
        .parse::<usize>()
        .unwrap_or(0);
    if tmp > 0 {
        DOWNGRADE_START_CHECK.store(tmp * 1000, Ordering::SeqCst);
    }
    log::info!(
        "DOWNGRADE_START_CHECK: {}s",
        DOWNGRADE_START_CHECK.load(Ordering::SeqCst) / 1000
    );
    let tmp = crate::common::get_arg("LIMIT_SPEED")
        .parse::<f64>()
        .unwrap_or(0.);
    if tmp > 0. {
        LIMIT_SPEED.store((tmp * 1024. * 1024.) as usize, Ordering::SeqCst);
    }
    log::info!(
        "LIMIT_SPEED: {}Mb/s",
        LIMIT_SPEED.load(Ordering::SeqCst) as f64 / 1024. / 1024.
    );
    let tmp = crate::common::get_arg("TOTAL_BANDWIDTH")
        .parse::<f64>()
        .unwrap_or(0.);
    if tmp > 0. {
        TOTAL_BANDWIDTH.store((tmp * 1024. * 1024.) as usize, Ordering::SeqCst);
    }

    log::info!(
        "TOTAL_BANDWIDTH: {}Mb/s",
        TOTAL_BANDWIDTH.load(Ordering::SeqCst) as f64 / 1024. / 1024.
    );
    let tmp = crate::common::get_arg("SINGLE_BANDWIDTH")
        .parse::<f64>()
        .unwrap_or(0.);
    if tmp > 0. {
        SINGLE_BANDWIDTH.store((tmp * 1024. * 1024.) as usize, Ordering::SeqCst);
    }
    log::info!(
        "SINGLE_BANDWIDTH: {}Mb/s",
        SINGLE_BANDWIDTH.load(Ordering::SeqCst) as f64 / 1024. / 1024.
    )
}

async fn check_cmd(cmd: &str, limiter: Limiter) -> String {
    use std::fmt::Write;

    let mut res = "".to_owned();
    let mut fds = cmd.trim().split(' ');
    match fds.next() {
        Some("h") => {
            res = format!(
                "{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n",
                "blacklist-add(ba) <ip>",
                "blacklist-remove(br) <ip>",
                "blacklist(b) <ip>",
                "blocklist-add(Ba) <ip>",
                "blocklist-remove(Br) <ip>",
                "blocklist(B) <ip>",
                "downgrade-threshold(dt) [value]",
                "downgrade-start-check(t) [value(second)]",
                "limit-speed(ls) [value(Mb/s)]",
                "total-bandwidth(tb) [value(Mb/s)]",
                "single-bandwidth(sb) [value(Mb/s)]",
                "usage(u)"
            )
        }
        Some("blacklist-add" | "ba") => {
            if let Some(ip) = fds.next() {
                for ip in ip.split('|') {
                    BLACKLIST.write().await.insert(ip.to_owned());
                }
            }
        }
        Some("blacklist-remove" | "br") => {
            if let Some(ip) = fds.next() {
                if ip == "all" {
                    BLACKLIST.write().await.clear();
                } else {
                    for ip in ip.split('|') {
                        BLACKLIST.write().await.remove(ip);
                    }
                }
            }
        }
        Some("blacklist" | "b") => {
            if let Some(ip) = fds.next() {
                res = format!("{}\n", BLACKLIST.read().await.get(ip).is_some());
            } else {
                for ip in BLACKLIST.read().await.clone().into_iter() {
                    let _ = writeln!(res, "{ip}");
                }
            }
        }
        Some("blocklist-add" | "Ba") => {
            if let Some(ip) = fds.next() {
                for ip in ip.split('|') {
                    BLOCKLIST.write().await.insert(ip.to_owned());
                }
            }
        }
        Some("blocklist-remove" | "Br") => {
            if let Some(ip) = fds.next() {
                if ip == "all" {
                    BLOCKLIST.write().await.clear();
                } else {
                    for ip in ip.split('|') {
                        BLOCKLIST.write().await.remove(ip);
                    }
                }
            }
        }
        Some("blocklist" | "B") => {
            if let Some(ip) = fds.next() {
                res = format!("{}\n", BLOCKLIST.read().await.get(ip).is_some());
            } else {
                for ip in BLOCKLIST.read().await.clone().into_iter() {
                    let _ = writeln!(res, "{ip}");
                }
            }
        }
        Some("downgrade-threshold" | "dt") => {
            if let Some(v) = fds.next() {
                if let Ok(v) = v.parse::<f64>() {
                    if v > 0. {
                        DOWNGRADE_THRESHOLD_100.store((v * 100.) as _, Ordering::SeqCst);
                    }
                }
            } else {
                res = format!(
                    "{}\n",
                    DOWNGRADE_THRESHOLD_100.load(Ordering::SeqCst) as f64 / 100.
                );
            }
        }
        Some("downgrade-start-check" | "t") => {
            if let Some(v) = fds.next() {
                if let Ok(v) = v.parse::<usize>() {
                    if v > 0 {
                        DOWNGRADE_START_CHECK.store(v * 1000, Ordering::SeqCst);
                    }
                }
            } else {
                res = format!("{}s\n", DOWNGRADE_START_CHECK.load(Ordering::SeqCst) / 1000);
            }
        }
        Some("limit-speed" | "ls") => {
            if let Some(v) = fds.next() {
                if let Ok(v) = v.parse::<f64>() {
                    if v > 0. {
                        LIMIT_SPEED.store((v * 1024. * 1024.) as _, Ordering::SeqCst);
                    }
                }
            } else {
                res = format!(
                    "{}Mb/s\n",
                    LIMIT_SPEED.load(Ordering::SeqCst) as f64 / 1024. / 1024.
                );
            }
        }
        Some("total-bandwidth" | "tb") => {
            if let Some(v) = fds.next() {
                if let Ok(v) = v.parse::<f64>() {
                    if v > 0. {
                        TOTAL_BANDWIDTH.store((v * 1024. * 1024.) as _, Ordering::SeqCst);
                        limiter.set_speed_limit(TOTAL_BANDWIDTH.load(Ordering::SeqCst) as _);
                    }
                }
            } else {
                res = format!(
                    "{}Mb/s\n",
                    TOTAL_BANDWIDTH.load(Ordering::SeqCst) as f64 / 1024. / 1024.
                );
            }
        }
        Some("single-bandwidth" | "sb") => {
            if let Some(v) = fds.next() {
                if let Ok(v) = v.parse::<f64>() {
                    if v > 0. {
                        SINGLE_BANDWIDTH.store((v * 1024. * 1024.) as _, Ordering::SeqCst);
                    }
                }
            } else {
                res = format!(
                    "{}Mb/s\n",
                    SINGLE_BANDWIDTH.load(Ordering::SeqCst) as f64 / 1024. / 1024.
                );
            }
        }
        Some("usage" | "u") => {
            let mut tmp: Vec<(String, Usage)> = USAGE
                .read()
                .await
                .iter()
                .map(|x| (x.0.clone(), *x.1))
                .collect();
            tmp.sort_by(|a, b| ((b.1).1).partial_cmp(&(a.1).1).unwrap());
            for (ip, (elapsed, total, highest, speed)) in tmp {
                if elapsed == 0 {
                    continue;
                }
                let _ = writeln!(
                    res,
                    "{}: {}s {:.2}MB {}kb/s {}kb/s {}kb/s",
                    ip,
                    elapsed / 1000,
                    total as f64 / 1024. / 1024. / 8.,
                    highest,
                    total / elapsed,
                    speed
                );
            }
        }
        _ => {}
    }
    res
}

async fn io_loop(
    listener: TcpListener,
    listener2: TcpListener,
    listener_console: Option<TcpListener>,
    key: &str,
) {
    check_params();
    let limiter = <Limiter>::new(TOTAL_BANDWIDTH.load(Ordering::SeqCst) as _);
    loop {
        tokio::select! {
            res = listener.accept() => {
                match res {
                    Ok((stream, addr))  => {
                        stream.set_nodelay(true).ok();
                        handle_connection(stream, addr, &limiter, key, false).await;
                    }
                    Err(err) => {
                       log::error!("listener.accept failed: {}", err);
                       break;
                    }
                }
            }
            res = listener2.accept() => {
                match res {
                    Ok((stream, addr))  => {
                        stream.set_nodelay(true).ok();
                        handle_connection(stream, addr, &limiter, key, true).await;
                    }
                    Err(err) => {
                       log::error!("listener2.accept failed: {}", err);
                       break;
                    }
                }
            }
            res = crate::common::accept_or_pending(listener_console.as_ref()) => {
                match res {
                    Ok((stream, addr))  => {
                        stream.set_nodelay(true).ok();
                        handle_connection(stream, addr, &limiter, key, false).await;
                    }
                    Err(err) => {
                       log::error!("console listener.accept failed: {}", err);
                       break;
                    }
                }
            }
        }
    }
}

async fn handle_connection(
    stream: TcpStream,
    addr: SocketAddr,
    limiter: &Limiter,
    key: &str,
    ws: bool,
) {
    let ip = hbb_common::try_into_v4(addr).ip();
    if !ws && ip.is_loopback() {
        let limiter = limiter.clone();
        tokio::spawn(async move {
            let mut stream = stream;
            let mut buffer = [0; 1024];
            if let Ok(Ok(n)) = timeout(1000, stream.read(&mut buffer[..])).await {
                if let Ok(data) = std::str::from_utf8(&buffer[..n]) {
                    let res = check_cmd(data, limiter).await;
                    stream.write(res.as_bytes()).await.ok();
                }
            }
        });
        return;
    }
    let ip = ip.to_string();
    if BLOCKLIST.read().await.get(&ip).is_some() {
        log::info!("{} blocked", ip);
        return;
    }
    let key = key.to_owned();
    let limiter = limiter.clone();
    tokio::spawn(async move {
        allow_err!(make_pair(stream, addr, &key, limiter, ws).await);
    });
}

fn ws_relay_config() -> tungstenite::protocol::WebSocketConfig {
    tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(MAX_WS_RELAY_MESSAGE))
        .max_frame_size(Some(MAX_WS_RELAY_FRAME))
}

async fn make_pair(
    stream: TcpStream,
    mut addr: SocketAddr,
    key: &str,
    limiter: Limiter,
    ws: bool,
) -> ResultType<()> {
    if ws {
        use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
        let callback = |req: &Request, response: Response| {
            let headers = req.headers();
            // X-Real-IP / X-Forwarded-For are trusted as-is so that the real
            // client IP is preserved when the WebSocket port runs behind a
            // reverse proxy (WSS). They are NOT validated: anyone who can reach
            // this port directly can spoof an arbitrary IP, bypassing IP-based
            // rate limiting / blocking and corrupting logged IPs. Do not expose
            // the WebSocket port directly to untrusted networks; only the
            // reverse proxy, which overwrites these headers, should be able to
            // connect to it.
            // https://github.com/rustdesk/rustdesk-server/issues/634
            let real_ip = headers
                .get("X-Real-IP")
                .or_else(|| headers.get("X-Forwarded-For"))
                .and_then(|header_value| header_value.to_str().ok());
            if let Some(ip) = real_ip {
                if ip.contains('.') {
                    addr = format!("{ip}:0").parse().unwrap_or(addr);
                } else {
                    addr = format!("[{ip}]:0").parse().unwrap_or(addr);
                }
            }
            Ok(response)
        };
        let ws_stream = accept_relay_ws(stream, callback).await?;
        make_pair_(ws_stream, addr, key, limiter).await;
    } else {
        let mut stream = FramedStream::from(stream, addr);
        // Before pairing only the small RequestRelay message is expected; the
        // codec default is unbounded. Pairing lifts the limit (see make_pair_).
        stream.set_max_packet_length(MAX_PREPAIR_PACKET);
        make_pair_(stream, addr, key, limiter).await;
    }
    Ok(())
}

async fn make_pair_(stream: impl StreamTrait, addr: SocketAddr, key: &str, limiter: Limiter) {
    let mut stream = stream;
    if let Ok(Some(Ok(bytes))) = timeout(RELAY_TIMEOUT_MS, stream.recv()).await {
        if let Ok(msg_in) = RendezvousMessage::parse_from_bytes(&bytes) {
            if let Some(rendezvous_message::Union::RequestRelay(rf)) = msg_in.union {
                if !key.is_empty() && rf.licence_key != key {
                    log::warn!("Relay authentication failed from {} - invalid key", addr);
                    return;
                }
                if !rf.uuid.is_empty() {
                    let mut peer = PEERS.lock().await.remove(&rf.uuid);
                    if let Some(peer) = peer.as_mut() {
                        log::info!("Relayrequest {} from {} got paired", rf.uuid, addr);
                        let id = format!("{}:{}", addr.ip(), addr.port());
                        USAGE.write().await.insert(id.clone(), Default::default());
                        if prepare_paired(&mut stream, peer) {
                            log::info!("Both are raw");
                        }
                        if let Err(err) = relay(addr, &mut stream, peer, limiter, id.clone()).await
                        {
                            log::info!("Relay of {} closed: {}", addr, err);
                        } else {
                            log::info!("Relay of {} closed", addr);
                        }
                        USAGE.write().await.remove(&id);
                    } else {
                        log::info!("New relay request {} from {}", rf.uuid, addr);
                        PEERS.lock().await.insert(rf.uuid.clone(), Box::new(stream));
                        sleep(30.).await;
                        PEERS.lock().await.remove(&rf.uuid);
                    }
                }
            }
        }
    }
}

/// Switches a freshly paired relay to its steady-state mode. Returns true when
/// both sides are TCP and were set raw. Otherwise a length-prefixed TCP side
/// stays framed for the whole relay, so its pre-pair packet limit is lifted to
/// what the WS side may send.
fn prepare_paired(stream: &mut impl StreamTrait, peer: &mut Box<dyn StreamTrait>) -> bool {
    if !stream.is_ws() && !peer.is_ws() {
        peer.set_raw();
        stream.set_raw();
        true
    } else {
        if !stream.is_ws() || !peer.is_ws() {
            log::debug!(
                "raised packet limit to {} for mixed TCP-WS pair",
                MAX_WS_RELAY_MESSAGE
            );
        }
        peer.set_max_packet_length(MAX_WS_RELAY_MESSAGE);
        stream.set_max_packet_length(MAX_WS_RELAY_MESSAGE);
        false
    }
}

async fn accept_relay_ws<C>(
    stream: TcpStream,
    callback: C,
) -> ResultType<tokio_tungstenite::WebSocketStream<TcpStream>>
where
    C: tokio_tungstenite::tungstenite::handshake::server::Callback + Unpin,
{
    // Bound what a peer can make us buffer and forward. Relayed WS frames
    // carry RustDesk video (keyframes of a few MiB at most), clipboard
    // images and file blocks (<= 128 KiB), so 32 MiB per message / 16 MiB
    // per frame is generous but finite (tungstenite defaults: 64/16 MiB).
    Ok(tokio_tungstenite::accept_hdr_async_with_config(
        stream,
        callback,
        Some(ws_relay_config()),
    )
    .await?)
}

// Base timeout (ms) shared by the relay: inactivity on reads and the floor of
// every write deadline. The inactivity timer in `relay` does not cover a write
// that never completes, so each write is bounded separately.
const RELAY_TIMEOUT_MS: u64 = 30_000;
// Largest WS message / frame accepted on the relay port.
const MAX_WS_RELAY_MESSAGE: usize = 32 << 20;
const MAX_WS_RELAY_FRAME: usize = 16 << 20;
// Largest packet read from a TCP relay connection before it is paired.
const MAX_PREPAIR_PACKET: usize = 1 << 20;
// A write may take longer by len / this rate, so a large frame on a slow but
// live link is not killed while a peer that stops reading still is.
const RELAY_MIN_WRITE_RATE_BYTES_PER_S: u64 = 16 * 1024;
// Frame length that counts towards the scaled part of a write deadline. Trade-off:
// a larger cap tolerates big keyframes (4-8 MiB) on slow but live links; a smaller
// one bounds how long a peer that stops reading can pin a pair. 1 MiB gives a
// maximum deadline of RELAY_TIMEOUT_MS + 64s (94s) however large the frame is.
const MAX_SCALED_WRITE_BYTES: usize = 1024 * 1024;

fn write_deadline_ms(len: usize) -> u64 {
    RELAY_TIMEOUT_MS
        + len.min(MAX_SCALED_WRITE_BYTES) as u64 * 1000 / RELAY_MIN_WRITE_RATE_BYTES_PER_S
}

async fn send_bounded(
    to: &mut (impl StreamTrait + ?Sized),
    bytes: Bytes,
    side: &str,
    addr: SocketAddr,
) -> ResultType<()> {
    let ms = write_deadline_ms(bytes.len());
    match timeout(ms, to.send_raw(bytes)).await {
        Ok(res) => res,
        Err(_) => bail!(
            "relay write to {} (paired via {}) timed out after {}ms",
            side,
            addr,
            ms
        ),
    }
}

async fn relay(
    addr: SocketAddr,
    stream: &mut impl StreamTrait,
    peer: &mut Box<dyn StreamTrait>,
    total_limiter: Limiter,
    id: String,
) -> ResultType<()> {
    let ip = addr.ip().to_string();
    let mut tm = Instant::now();
    let mut elapsed = 0;
    let mut total = 0;
    let mut total_s = 0;
    let mut highest_s = 0;
    let mut downgrade: bool = false;
    let mut blacked: bool = false;
    let sb = SINGLE_BANDWIDTH.load(Ordering::SeqCst) as f64;
    let limiter = <Limiter>::new(sb);
    let blacklist_limiter = <Limiter>::new(LIMIT_SPEED.load(Ordering::SeqCst) as _);
    let downgrade_threshold =
        (sb * DOWNGRADE_THRESHOLD_100.load(Ordering::SeqCst) as f64 / 100. / 1000.) as usize; // in bit/ms
    let mut timer = interval(Duration::from_secs(3));
    let mut last_recv_time = Instant::now();
    loop {
        tokio::select! {
            res = peer.recv() => {
                if let Some(Ok(bytes)) = res {
                    last_recv_time = Instant::now();
                    let nb = bytes.len() * 8;
                    if blacked || downgrade {
                        blacklist_limiter.consume(nb).await;
                    } else {
                        limiter.consume(nb).await;
                    }
                    total_limiter.consume(nb).await;
                    total += nb;
                    total_s += nb;
                    if !bytes.is_empty() {
                        send_bounded(stream, bytes.into(), "stream", addr).await?;
                        last_recv_time = Instant::now(); // a completed write is activity
                    }
                } else {
                    if let Some(Err(e)) = res {
                        log::info!("Relay of {} read from peer failed: {}", addr, e);
                    }
                    break;
                }
            },
            res = stream.recv() => {
                if let Some(Ok(bytes)) = res {
                    last_recv_time = Instant::now();
                    let nb = bytes.len() * 8;
                    if blacked || downgrade {
                        blacklist_limiter.consume(nb).await;
                    } else {
                        limiter.consume(nb).await;
                    }
                    total_limiter.consume(nb).await;
                    total += nb;
                    total_s += nb;
                    if !bytes.is_empty() {
                        send_bounded(&mut **peer, bytes.into(), "peer", addr).await?;
                        last_recv_time = Instant::now(); // a completed write is activity
                    }
                } else {
                    if let Some(Err(e)) = res {
                        log::info!("Relay of {} read from stream failed: {}", addr, e);
                    }
                    break;
                }
            },
            _ = timer.tick() => {
                if last_recv_time.elapsed() > Duration::from_millis(RELAY_TIMEOUT_MS) {
                    bail!("Timeout");
                }
            }
        }

        let n = tm.elapsed().as_millis() as usize;
        if n >= 1_000 {
            if BLOCKLIST.read().await.get(&ip).is_some() {
                log::info!("{} blocked", ip);
                break;
            }
            blacked = BLACKLIST.read().await.get(&ip).is_some();
            tm = Instant::now();
            let speed = total_s / n;
            if speed > highest_s {
                highest_s = speed;
            }
            elapsed += n;
            USAGE.write().await.insert(
                id.clone(),
                (elapsed as _, total as _, highest_s as _, speed as _),
            );
            total_s = 0;
            if elapsed > DOWNGRADE_START_CHECK.load(Ordering::SeqCst)
                && !downgrade
                && total > elapsed * downgrade_threshold
            {
                downgrade = true;
                log::info!(
                    "Downgrade {}, exceed downgrade threshold {}bit/ms in {}ms",
                    id,
                    downgrade_threshold,
                    elapsed
                );
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestStream {
        data: Option<BytesMut>,
        blocked: bool,
    }

    #[async_trait]
    impl StreamTrait for TestStream {
        async fn recv(&mut self) -> Option<Result<BytesMut, Error>> {
            match self.data.take() {
                Some(data) => Some(Ok(data)),
                None => std::future::pending().await,
            }
        }

        async fn send_raw(&mut self, _: Bytes) -> ResultType<()> {
            if self.blocked {
                std::future::pending().await
            } else {
                Ok(())
            }
        }

        fn is_ws(&self) -> bool {
            false
        }

        fn set_raw(&mut self) {}
        fn set_max_packet_length(&mut self, _: usize) {}
    }

    /// Returns the (virtual) time a blocked write of `len` bytes took to fail.
    async fn check_blocked_send(from_peer: bool, len: usize) -> Duration {
        let frame = || BytesMut::from(&vec![b'x'; len][..]);
        let mut stream = TestStream {
            data: if from_peer { None } else { Some(frame()) },
            blocked: from_peer,
        };
        let mut peer: Box<dyn StreamTrait> = Box::new(TestStream {
            data: if from_peer { Some(frame()) } else { None },
            blocked: !from_peer,
        });
        let start = tokio::time::Instant::now();
        let result = timeout(
            write_deadline_ms(len) + 5_000,
            relay(
                "127.0.0.1:1".parse().unwrap(),
                &mut stream,
                &mut peer,
                Limiter::new(1e12),
                "blocked-send-test".to_owned(),
            ),
        )
        .await
        .expect("a blocked relay write must finish within its deadline");
        let err = result.expect_err("the blocked write must fail");
        let side = if from_peer { "stream" } else { "peer" };
        let msg = err.to_string();
        assert!(
            msg.contains(&format!("relay write to {} (paired via 127.0.0.1:1) timed out", side)),
            "unexpected error: {err}"
        );
        start.elapsed()
    }

    #[tokio::test(start_paused = true)]
    async fn blocked_writes_in_both_directions_time_out() {
        let (a, b) = tokio::join!(check_blocked_send(false, 1), check_blocked_send(true, 1));
        for t in [a, b] {
            assert!(t >= Duration::from_millis(RELAY_TIMEOUT_MS), "{t:?}");
        }
    }

    #[tokio::test(start_paused = true)]
    async fn large_frames_get_a_longer_write_deadline() {
        let small = check_blocked_send(false, 1).await;
        let large = check_blocked_send(false, 1024 * 1024).await;
        // 1 MiB at 16 KiB/s adds 64 s.
        assert!(large >= small + Duration::from_secs(10), "{small:?} vs {large:?}");
        assert!(large <= Duration::from_millis(write_deadline_ms(1024 * 1024) + 1_000));
    }

    #[test]
    fn write_deadline_is_capped() {
        let cap = RELAY_TIMEOUT_MS + 64_000;
        assert_eq!(write_deadline_ms(0), RELAY_TIMEOUT_MS);
        assert_eq!(write_deadline_ms(64 << 20), cap);
        assert_eq!(write_deadline_ms(usize::MAX), cap);
    }

    async fn oversize_rejected(len: usize) -> bool {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        let client = tokio::spawn(async move {
            let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}"))
                .await
                .unwrap();
            ws.send(tungstenite::Message::Binary(vec![0u8; len].into())).await.ok();
            // keep the socket open until the server has decided
            std::future::pending::<()>().await;
        });
        let (s, _) = l.accept().await.unwrap();
        let mut ws = accept_relay_ws(
            s,
            |_: &tokio_tungstenite::tungstenite::handshake::server::Request,
             r: tokio_tungstenite::tungstenite::handshake::server::Response| Ok(r),
        )
        .await
        .unwrap();
        let res = StreamTrait::recv(&mut ws).await;
        client.abort();
        matches!(res, Some(Err(_)))
    }

    #[tokio::test]
    async fn oversize_ws_messages_are_rejected_and_normal_ones_pass() {
        assert!(oversize_rejected(MAX_WS_RELAY_MESSAGE + 1).await);
        assert!(!oversize_rejected(4 << 20).await);
    }

    /// A loopback TCP connection: (server-side FramedStream, client-side FramedStream).
    async fn framed_pair() -> (FramedStream, FramedStream) {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = l.local_addr().unwrap();
        let c = tokio::spawn(async move { TcpStream::connect(addr).await.unwrap() });
        let (s, _) = l.accept().await.unwrap();
        let c = c.await.unwrap();
        (
            FramedStream::from(s, "127.0.0.1:1".parse().unwrap()),
            FramedStream::from(c, addr),
        )
    }

    #[tokio::test]
    async fn prepair_packet_limit_rejects_big_first_packet() {
        let (mut server, mut client) = framed_pair().await;
        server.set_max_packet_length(MAX_PREPAIR_PACKET);
        let sender = tokio::spawn(async move {
            client.send_bytes(vec![0u8; MAX_PREPAIR_PACKET + 1].into()).await.ok();
            client
        });
        assert!(matches!(StreamTrait::recv(&mut server).await, Some(Err(_))));
        sender.abort();
    }

    struct Capture(std::sync::Arc<std::sync::atomic::AtomicUsize>);

    #[async_trait]
    impl StreamTrait for Capture {
        async fn recv(&mut self) -> Option<Result<BytesMut, Error>> {
            std::future::pending().await
        }
        async fn send_raw(&mut self, b: Bytes) -> ResultType<()> {
            self.0.store(b.len(), Ordering::SeqCst);
            Ok(())
        }
        fn is_ws(&self) -> bool {
            true
        }
        fn set_raw(&mut self) {}
        fn set_max_packet_length(&mut self, _: usize) {}
    }

    // TCP <-> WS keeps the TCP side framed: a 2 MiB packet (> pre-pair limit) must pass.
    #[tokio::test]
    async fn mixed_pair_relays_frames_above_prepair_limit() {
        let (mut server, mut client) = framed_pair().await;
        server.set_max_packet_length(MAX_PREPAIR_PACKET);
        let got = std::sync::Arc::new(AtomicUsize::new(0));
        let mut peer: Box<dyn StreamTrait> = Box::new(Capture(got.clone()));
        assert!(!prepare_paired(&mut server, &mut peer));
        let len = 2 << 20;
        // Sent concurrently: the loopback socket buffers can be smaller than the frame.
        let sender = tokio::spawn(async move {
            client.send_bytes(vec![7u8; len].into()).await.unwrap();
            client
        });
        let r = timeout(
            1_000,
            relay(
                "127.0.0.1:1".parse().unwrap(),
                &mut server,
                &mut peer,
                Limiter::new(1e12),
                "mixed-test".to_owned(),
            ),
        )
        .await;
        assert!(r.is_err(), "relay must still be running, got {r:?}");
        assert_eq!(got.load(Ordering::SeqCst), len);
        drop(sender);
    }

    // The parked side of a mixed pair is a real FramedStream created with the
    // pre-pair limit; pairing must raise it so a 2 MiB frame from it passes.
    #[tokio::test]
    async fn parked_framed_peer_limit_is_raised_by_pairing() {
        let (mut parked, mut client) = framed_pair().await;
        parked.set_max_packet_length(MAX_PREPAIR_PACKET);
        let mut peer: Box<dyn StreamTrait> = Box::new(parked);
        let got = std::sync::Arc::new(AtomicUsize::new(0));
        let mut stream = Capture(got.clone());
        assert!(!prepare_paired(&mut stream, &mut peer));
        let len = 2 << 20;
        let sender = tokio::spawn(async move {
            client.send_bytes(vec![7u8; len].into()).await.unwrap();
            client
        });
        let r = timeout(
            1_000,
            relay(
                "127.0.0.1:1".parse().unwrap(),
                &mut stream,
                &mut peer,
                Limiter::new(1e12),
                "parked-test".to_owned(),
            ),
        )
        .await;
        assert!(r.is_err(), "relay must still be running, got {r:?}");
        assert_eq!(got.load(Ordering::SeqCst), len);
        drop(sender);
    }

    struct SlowWrite;

    #[async_trait]
    impl StreamTrait for SlowWrite {
        async fn recv(&mut self) -> Option<Result<BytesMut, Error>> {
            std::future::pending().await
        }
        async fn send_raw(&mut self, _: Bytes) -> ResultType<()> {
            tokio::time::sleep(Duration::from_secs(40)).await;
            Ok(())
        }
        fn is_ws(&self) -> bool {
            false
        }
        fn set_raw(&mut self) {}
        fn set_max_packet_length(&mut self, _: usize) {}
    }

    // A write that succeeds after >30s must not trip the inactivity check.
    #[tokio::test(start_paused = true)]
    async fn slow_successful_write_is_not_inactivity() {
        let mut stream = TestStream {
            data: Some(BytesMut::from(&vec![b'x'; MAX_SCALED_WRITE_BYTES][..])),
            blocked: false,
        };
        let mut peer: Box<dyn StreamTrait> = Box::new(SlowWrite);
        let res = timeout(
            55_000,
            relay(
                "127.0.0.1:1".parse().unwrap(),
                &mut stream,
                &mut peer,
                Limiter::new(1e12),
                "slow-write-test".to_owned(),
            ),
        )
        .await;
        // still running at 55s (inactivity restarts after the write at 40s)
        assert!(res.is_err(), "relay ended early: {res:?}");
    }
}

fn get_server_sk(key: &str) -> ResultType<String> {
    let mut key = key.to_owned();
    if let Ok(sk) = base64::decode(&key) {
        if sk.len() == sign::SECRETKEYBYTES {
            log::info!("The key is a crypto private key");
            key = base64::encode(&sk[(sign::SECRETKEYBYTES / 2)..]);
        }
    }

    if key == "-" || key == "_" {
        let (pk, _) = crate::common::gen_sk(300)?;
        key = pk;
    }

    if !key.is_empty() {
        log::info!("Key: {}", key);
    }

    Ok(key)
}

#[async_trait]
trait StreamTrait: Send + Sync + 'static {
    async fn recv(&mut self) -> Option<Result<BytesMut, Error>>;
    async fn send_raw(&mut self, bytes: Bytes) -> ResultType<()>;
    fn is_ws(&self) -> bool;
    fn set_raw(&mut self);
    /// Limits the size of a length-prefixed packet read from this stream.
    fn set_max_packet_length(&mut self, n: usize);
}

#[async_trait]
impl StreamTrait for FramedStream {
    async fn recv(&mut self) -> Option<Result<BytesMut, Error>> {
        self.next().await
    }

    async fn send_raw(&mut self, bytes: Bytes) -> ResultType<()> {
        self.send_bytes(bytes).await
    }

    fn is_ws(&self) -> bool {
        false
    }

    fn set_raw(&mut self) {
        self.set_raw();
    }

    fn set_max_packet_length(&mut self, n: usize) {
        self.0.codec_mut().set_max_packet_length(n);
    }
}

#[async_trait]
impl StreamTrait for tokio_tungstenite::WebSocketStream<TcpStream> {
    async fn recv(&mut self) -> Option<Result<BytesMut, Error>> {
        if let Some(msg) = self.next().await {
            match msg {
                Ok(msg) => {
                    match msg {
                        tungstenite::Message::Binary(bytes) => {
                            Some(Ok(bytes[..].into())) // to-do: poor performance
                        }
                        _ => Some(Ok(BytesMut::new())),
                    }
                }
                Err(err) => Some(Err(Error::new(std::io::ErrorKind::Other, err.to_string()))),
            }
        } else {
            None
        }
    }

    async fn send_raw(&mut self, bytes: Bytes) -> ResultType<()> {
        Ok(self
            .send(tungstenite::Message::Binary(bytes))
            .await?)
    }

    fn is_ws(&self) -> bool {
        true
    }

    fn set_raw(&mut self) {}
    fn set_max_packet_length(&mut self, _: usize) {}
}
