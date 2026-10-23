// Patina: in-process integration test of WebSocket device registration.
//
// Copyright (C) 2026 Patina contributors. AGPL-3.0, see LICENSE.
//
// Starts a real hbbs (WS_REGISTER=Y) on loopback and talks to its WebSocket
// port the way a stock client in WebSocket mode does: the device registers
// with RegisterPk and then only echoes the server's empty frames; the
// controller sends PunchHoleRequest on its own connection; the device answers
// a pushed PunchHole with RelayResponse on a new connection.

use hbb_common::{
    futures::{SinkExt, StreamExt},
    message_proto::IdPk,
    protobuf::Message as _,
    rendezvous_proto::*,
    tokio::{
        self,
        net::TcpStream,
        time::{timeout, Duration, Instant},
    },
    AddrMangle,
};
use sodiumoxide::crypto::sign;
use std::sync::OnceLock;
use tokio_tungstenite::{
    connect_async, tungstenite::client::IntoClientRequest, MaybeTlsStream, WebSocketStream,
};
use tungstenite::Message as WsMessage;

type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

const KEEPALIVE: Duration = Duration::from_secs(12);

struct Server {
    ws_port: u16,
    licence_key: String,
    pk: sign::PublicKey,
}

fn server() -> &'static Server {
    static SERVER: OnceLock<Server> = OnceLock::new();
    SERVER.get_or_init(|| {
        let (pk, sk) = sign::gen_keypair();
        let dir = std::env::temp_dir().join(format!("patina-it-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::env::set_var("DB_URL", dir.join("db.sqlite3"));
        std::env::set_var("WS_REGISTER", "Y");
        std::env::set_var("TEST_HBBS", "no");
        std::env::set_var("RELAY_SERVERS", "127.0.0.1");
        let port = free_port_triple();
        let key = base64::encode(&sk.0[..]);
        std::thread::spawn(move || {
            hbbs::RendezvousServer::start_with_bind(
                Some("127.0.0.1".parse().unwrap()),
                port as i32,
                0,
                &key,
                0,
            )
            .unwrap();
        });
        let ws_port = port + 2;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
        while std::net::TcpStream::connect(("127.0.0.1", ws_port)).is_err() {
            assert!(std::time::Instant::now() < deadline, "hbbs did not start");
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        Server {
            ws_port,
            licence_key: base64::encode(pk.0),
            pk,
        }
    })
}

/// A port p such that p-1, p and p+2 are free (hbbs uses all three).
fn free_port_triple() -> u16 {
    for _ in 0..200 {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let p = l.local_addr().unwrap().port();
        drop(l);
        if p < 2000 || p > 65000 {
            continue;
        }
        let ok = [p - 1, p, p + 2].iter().all(|q| {
            std::net::TcpListener::bind(("127.0.0.1", *q)).is_ok()
                && std::net::UdpSocket::bind(("127.0.0.1", *q)).is_ok()
        });
        if ok {
            return p;
        }
    }
    panic!("no free ports");
}

async fn connect(headers: &[(&'static str, &str)]) -> Ws {
    let mut req = format!("ws://127.0.0.1:{}/ws/id", server().ws_port)
        .into_client_request()
        .unwrap();
    for (k, v) in headers {
        req.headers_mut().insert(*k, v.parse().unwrap());
    }
    connect_async(req).await.unwrap().0
}

async fn send(ws: &mut Ws, m: &RendezvousMessage) {
    ws.send(WsMessage::Binary(m.write_to_bytes().unwrap()))
        .await
        .unwrap();
}

/// Next non-empty rendezvous message; empty frames (keepalives) are echoed
/// like the client does.
async fn recv(ws: &mut Ws, within: Duration) -> RendezvousMessage {
    let deadline = Instant::now() + within;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let msg = timeout(left, ws.next())
            .await
            .expect("timed out waiting for a message")
            .expect("connection closed")
            .unwrap();
        if let WsMessage::Binary(b) = msg {
            if b.is_empty() {
                ws.send(WsMessage::Binary(Vec::new())).await.unwrap();
                continue;
            }
            return RendezvousMessage::parse_from_bytes(&b).unwrap();
        }
    }
}

struct Device {
    id: String,
    ws: Ws,
    pk: sign::PublicKey,
}

async fn register(id: &str) -> Device {
    let (pk, _sk) = sign::gen_keypair();
    let mut ws = connect(&[]).await;
    let mut m = RendezvousMessage::new();
    m.set_register_pk(RegisterPk {
        id: id.to_owned(),
        uuid: format!("uuid-{id}").into_bytes().into(),
        pk: pk.0.to_vec().into(),
        ..Default::default()
    });
    send(&mut ws, &m).await;
    let res = recv(&mut ws, Duration::from_secs(5)).await;
    let res = res.register_pk_response();
    assert_eq!(
        res.result.enum_value().unwrap(),
        register_pk_response::Result::OK
    );
    assert_eq!(res.keep_alive, (KEEPALIVE.as_secs() * 3) as i32);
    Device {
        id: id.to_owned(),
        ws,
        pk,
    }
}

fn punch_request(id: &str) -> RendezvousMessage {
    let mut m = RendezvousMessage::new();
    m.set_punch_hole_request(PunchHoleRequest {
        id: id.to_owned(),
        licence_key: server().licence_key.clone(),
        nat_type: NatType::SYMMETRIC.into(),
        force_relay: true,
        version: "1.5.0".to_owned(),
        ..Default::default()
    });
    m
}

/// Device side of a pushed PunchHole in WebSocket mode: a new connection
/// that sends RelayResponse (what create_relay does with initiate=true).
async fn answer_punch_hole(dev: &mut Device, uuid: &str) -> PunchHole {
    let ph = recv(&mut dev.ws, Duration::from_secs(5)).await;
    assert!(ph.has_punch_hole(), "{ph:?}");
    let ph = ph.punch_hole().clone();
    let mut ws = connect(&[]).await;
    let mut m = RendezvousMessage::new();
    let mut rr = RelayResponse {
        socket_addr: ph.socket_addr.clone(),
        version: "1.5.0".to_owned(),
        uuid: uuid.to_owned(),
        relay_server: ph.relay_server.clone(),
        ..Default::default()
    };
    rr.set_id(dev.id.clone());
    m.set_relay_response(rr);
    send(&mut ws, &m).await;
    ph
}

fn check_relay_response(m: &RendezvousMessage, dev: &Device, uuid: &str) {
    assert!(m.has_relay_response(), "{m:?}");
    let rr = m.relay_response();
    assert_eq!(rr.uuid, uuid);
    assert_eq!(rr.relay_server, "127.0.0.1");
    // the device's pk, signed by the server key
    let signed = sign::verify(rr.pk(), &server().pk).expect("signed by hbbs");
    let idpk = IdPk::parse_from_bytes(&signed).unwrap();
    assert_eq!(idpk.id, dev.id);
    assert_eq!(&idpk.pk[..], &dev.pk.0[..]);
}

async fn online(ids: &[&str]) -> Vec<u8> {
    let mut ws = connect(&[]).await;
    let mut m = RendezvousMessage::new();
    m.set_online_request(OnlineRequest {
        id: "asker".to_owned(),
        peers: ids.iter().map(|s| s.to_string()).collect(),
        ..Default::default()
    });
    send(&mut ws, &m).await;
    recv(&mut ws, Duration::from_secs(5))
        .await
        .online_response()
        .states
        .to_vec()
}

#[tokio::test(flavor = "multi_thread")]
async fn punch_hole_reaches_ws_device_and_relay_response_returns_signed() {
    let mut dev = register("itdev001").await;
    assert_eq!(online(&["itdev001", "nobody"]).await, vec![0b1000_0000]);

    let mut ctl = connect(&[]).await;
    send(&mut ctl, &punch_request("itdev001")).await;
    let ph = answer_punch_hole(&mut dev, "uuid-1").await;
    assert_eq!(ph.relay_server, "127.0.0.1");
    let rr = recv(&mut ctl, Duration::from_secs(5)).await;
    check_relay_response(&rr, &dev, "uuid-1");
}

#[tokio::test(flavor = "multi_thread")]
async fn two_controllers_behind_one_nat_get_their_own_answers() {
    let mut dev = register("itdev002").await;
    // proxied from loopback (trusted by default) with the same public IP and
    // no X-Real-Port: upstream keyed both as 203.0.113.9:0
    let h = [("X-Real-IP", "203.0.113.9")];
    let mut a = connect(&h).await;
    let mut b = connect(&h).await;
    send(&mut a, &punch_request("itdev002")).await;
    let pa = answer_punch_hole(&mut dev, "uuid-a").await;
    send(&mut b, &punch_request("itdev002")).await;
    let pb = answer_punch_hole(&mut dev, "uuid-b").await;
    let (aa, ab) = (
        AddrMangle::decode(&pa.socket_addr),
        AddrMangle::decode(&pb.socket_addr),
    );
    assert_eq!(aa.ip().to_string(), "203.0.113.9");
    assert_eq!(ab.ip(), aa.ip());
    assert_ne!(aa.port(), ab.port());
    check_relay_response(&recv(&mut a, Duration::from_secs(5)).await, &dev, "uuid-a");
    check_relay_response(&recv(&mut b, Duration::from_secs(5)).await, &dev, "uuid-b");

    // with X-Real-Port the proxy's view of the port is used
    let mut c = connect(&[("X-Real-IP", "203.0.113.9"), ("X-Real-Port", "40404")]).await;
    send(&mut c, &punch_request("itdev002")).await;
    let pc = answer_punch_hole(&mut dev, "uuid-c").await;
    assert_eq!(
        AddrMangle::decode(&pc.socket_addr).to_string(),
        "203.0.113.9:40404"
    );
    check_relay_response(&recv(&mut c, Duration::from_secs(5)).await, &dev, "uuid-c");
}

#[tokio::test(flavor = "multi_thread")]
async fn keepalive_cadence() {
    let mut dev = register("itdev003").await;
    let start = Instant::now();
    let mut arrivals = Vec::new();
    while arrivals.len() < 3 {
        let msg = timeout(KEEPALIVE * 2, dev.ws.next())
            .await
            .expect("no keepalive")
            .unwrap()
            .unwrap();
        if msg == WsMessage::Binary(Vec::new()) {
            arrivals.push(start.elapsed());
            dev.ws.send(WsMessage::Binary(Vec::new())).await.unwrap();
        }
    }
    println!("keepalive arrivals: {arrivals:?}");
    for (i, t) in arrivals.iter().enumerate() {
        let want = KEEPALIVE * (i as u32 + 1);
        assert!(
            *t + Duration::from_millis(1500) >= want && *t <= want + Duration::from_millis(1500),
            "keepalive {i} at {t:?}, want ~{want:?}"
        );
    }
    assert_eq!(online(&["itdev003"]).await, vec![0b1000_0000]);
}

#[tokio::test(flavor = "multi_thread")]
async fn silent_device_is_dropped_and_shown_offline() {
    let mut dev = register("itdev004").await;
    // do not echo keepalives: hbbs's 30 s read timeout closes the connection
    let start = Instant::now();
    loop {
        match timeout(Duration::from_secs(45), dev.ws.next()).await {
            Ok(Some(Ok(WsMessage::Binary(_)))) => continue,
            Ok(Some(Ok(WsMessage::Close(_)))) | Ok(None) | Ok(Some(Err(_))) => break,
            Ok(Some(Ok(_))) => continue,
            Err(_) => panic!("server kept a silent connection open"),
        }
    }
    let took = start.elapsed();
    assert!(
        took >= Duration::from_secs(29) && took <= Duration::from_secs(35),
        "{took:?}"
    );
    assert_eq!(online(&["itdev004"]).await, vec![0]);
    let mut ctl = connect(&[]).await;
    send(&mut ctl, &punch_request("itdev004")).await;
    let r = recv(&mut ctl, Duration::from_secs(5)).await;
    assert_eq!(
        r.punch_hole_response().failure.enum_value().unwrap(),
        punch_hole_response::Failure::OFFLINE
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn reconnect_replaces_old_connection() {
    let mut old = register("itdev005").await;
    let mut new = register("itdev005").await;
    // the old connection is closed by the server
    loop {
        match timeout(Duration::from_secs(5), old.ws.next()).await {
            Ok(Some(Ok(WsMessage::Close(_)))) | Ok(None) | Ok(Some(Err(_))) => break,
            Ok(Some(Ok(_))) => continue,
            Err(_) => panic!("old connection not closed"),
        }
    }
    let mut ctl = connect(&[]).await;
    send(&mut ctl, &punch_request("itdev005")).await;
    // same uuid, so the newer key is now the device's
    let _ = answer_punch_hole(&mut new, "uuid-r").await;
    check_relay_response(&recv(&mut ctl, Duration::from_secs(5)).await, &new, "uuid-r");
}

/// Real-time soak: an idle registered device (echoing keepalives, as the
/// client does) stays connected and reachable for over five minutes.
/// `cargo test --test ws_registration -- --ignored idle`
#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn idle_connection_survives_five_minutes() {
    let mut dev = register("itdev006").await;
    let soak = Duration::from_secs(5 * 60 + 30);
    let start = Instant::now();
    let mut keepalives = 0;
    while start.elapsed() < soak {
        let msg = timeout(KEEPALIVE * 2, dev.ws.next())
            .await
            .expect("keepalive missing")
            .expect("connection closed")
            .unwrap();
        if msg == WsMessage::Binary(Vec::new()) {
            keepalives += 1;
            dev.ws.send(WsMessage::Binary(Vec::new())).await.unwrap();
        } else {
            panic!("unexpected {msg:?}");
        }
    }
    println!("idle for {:?}, {keepalives} keepalives", start.elapsed());
    assert!(keepalives >= 27);
    assert_eq!(online(&["itdev006"]).await, vec![0b1000_0000]);
    let mut ctl = connect(&[]).await;
    send(&mut ctl, &punch_request("itdev006")).await;
    let _ = answer_punch_hole(&mut dev, "uuid-idle").await;
    check_relay_response(&recv(&mut ctl, Duration::from_secs(5)).await, &dev, "uuid-idle");
}
