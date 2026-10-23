"""Protocol-level probe for the hbbs WebSocket rendezvous endpoint.

Speaks the same messages the stock client sends on /ws/id (RegisterPk,
OnlineRequest) so the bench can check server behaviour without a GUI.
Prints one JSON object per command on stdout.
"""
import argparse
import json
import os
import shutil
import sqlite3
import ssl
import sys
import tempfile
import time
import uuid

from websockets.sync.client import connect

import rendezvous_pb2 as pb


def ws_connect(url, headers):
    ctx = None
    if url.startswith("wss://"):
        ctx = ssl.create_default_context(cafile="/ca/ca.crt")
    hdrs = []
    for h in headers or []:
        k, _, v = h.partition(":")
        hdrs.append((k.strip(), v.strip()))
    return connect(url, ssl=ctx, additional_headers=hdrs, open_timeout=10,
                   max_size=1 << 20)


def recv_msg(ws, timeout):
    """Return (kind, payload): ('empty', None) | ('msg', RendezvousMessage) |
    ('timeout', None) | ('closed', reason)."""
    try:
        data = ws.recv(timeout=timeout)
    except TimeoutError:
        return "timeout", None
    except Exception as e:  # connection closed
        return "closed", repr(e)
    if isinstance(data, str):
        return "text", data
    if len(data) == 0:
        return "empty", None
    m = pb.RendezvousMessage()
    m.ParseFromString(data)
    return "msg", m


def cmd_register(a):
    out = {"cmd": "register", "url": a.url, "id": a.id, "headers": a.header}
    ws = ws_connect(a.url, a.header)
    out["local_ip"] = ws.socket.getsockname()[0]
    m = pb.RendezvousMessage()
    m.register_pk.id = a.id
    m.register_pk.uuid = (a.uuid or str(uuid.uuid4())).encode()
    m.register_pk.pk = os.urandom(32) if not a.pk else bytes.fromhex(a.pk)
    ws.send(m.SerializeToString())
    t0 = time.monotonic()
    out["result"] = None
    empties = []
    deadline = t0 + max(a.hold, 10)
    while time.monotonic() < deadline:
        kind, msg = recv_msg(ws, timeout=max(0.1, deadline - time.monotonic()))
        if kind == "msg" and msg.WhichOneof("union") == "register_pk_response":
            r = msg.register_pk_response
            out["result"] = pb.RegisterPkResponse.Result.Name(r.result)
            out["keep_alive"] = r.keep_alive
            out["result_after_s"] = round(time.monotonic() - t0, 2)
            if a.hold == 0:
                break
        elif kind == "empty":
            empties.append(round(time.monotonic() - t0, 1))
            ws.send(b"")  # echo, like the client does
        elif kind == "msg":
            out.setdefault("other", []).append(msg.WhichOneof("union"))
        elif kind == "closed":
            out["closed_after_s"] = round(time.monotonic() - t0, 1)
            out["closed"] = msg
            break
        elif kind == "timeout":
            if out["result"] is None and a.hold == 0:
                break
    out["empty_frames_at_s"] = empties
    out["open_at_end"] = "closed" not in out
    try:
        ws.close()
    except Exception:
        pass
    print(json.dumps(out))


def cmd_online(a):
    peers = [p for p in a.peers.split(",") if p]
    out = {"cmd": "online", "url": a.url, "peers": peers}
    ws = ws_connect(a.url, a.header)
    m = pb.RendezvousMessage()
    m.online_request.id = a.self_id
    m.online_request.peers.extend(peers)
    ws.send(m.SerializeToString())
    deadline = time.monotonic() + a.timeout
    out["response"] = None
    while time.monotonic() < deadline:
        kind, msg = recv_msg(ws, timeout=max(0.1, deadline - time.monotonic()))
        if kind == "msg" and msg.WhichOneof("union") == "online_response":
            states = msg.online_response.states
            res = {}
            for i, p in enumerate(peers):
                byte = states[i // 8] if i // 8 < len(states) else 0
                res[p] = bool(byte & (0x01 << (7 - i % 8)))
            out["response"] = res
            break
        if kind in ("closed", "timeout"):
            out["ended"] = kind
            break
    try:
        ws.close()
    except Exception:
        pass
    if a.brief:
        r = out["response"]
        print("no_response" if r is None else
              " ".join(str(v).lower() for v in r.values()))
    else:
        print(json.dumps(out))


def cmd_dbinfo(a):
    """Read the peer row hbbs stored for an id (copy first: db may be in WAL)."""
    tmp = tempfile.mkdtemp()
    for suffix in ("", "-wal", "-shm"):
        src = "/hbbs-data/db_v2.sqlite3" + suffix
        if os.path.exists(src):
            shutil.copy(src, os.path.join(tmp, "db" + suffix))
    con = sqlite3.connect(os.path.join(tmp, "db"))
    row = con.execute("select id, uuid, info, created_at from peer where id = ?",
                      (a.id,)).fetchone()
    out = {"cmd": "dbinfo", "id": a.id, "found": row is not None}
    if row:
        out["info"] = row[2]
        out["created_at"] = row[3]
        try:
            out["ip"] = json.loads(row[2]).get("ip")
        except (TypeError, ValueError, AttributeError):
            out["ip"] = None
    print(json.dumps(out))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("register")
    r.add_argument("url")
    r.add_argument("--id", required=True)
    r.add_argument("--uuid")
    r.add_argument("--pk", help="hex")
    r.add_argument("--header", action="append", default=[])
    r.add_argument("--hold", type=int, default=0,
                   help="keep the connection open N seconds, echoing heartbeats")
    r.set_defaults(fn=cmd_register)
    o = sub.add_parser("online")
    o.add_argument("url")
    o.add_argument("--peers", required=True)
    o.add_argument("--self-id", default="e2eprobe")
    o.add_argument("--header", action="append", default=[])
    o.add_argument("--timeout", type=float, default=8)
    o.add_argument("--brief", action="store_true",
                   help="print only true/false per peer, or no_response")
    o.set_defaults(fn=cmd_online)
    d = sub.add_parser("dbinfo")
    d.add_argument("--id", required=True)
    d.set_defaults(fn=cmd_dbinfo)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
