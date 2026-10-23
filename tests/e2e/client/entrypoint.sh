#!/bin/bash
# Entrypoint for the stock RustDesk 1.5.0 desktop container.
#
# Environment:
#   RD_ROLE       device | controller            (default device)
#   RD_NET_MODE   ws | udp                       ws => allow-websocket=Y
#   RD_FIREWALL   ws-only | none                 ws-only => drop all UDP and all
#                                                TCP except PROXY_IP:443
#   RD_DOMAIN     TLS name of the proxy           (e.g. rd.e2e.test)
#   RD_SERVER     rendezvous host used in config  (domain for ws, hbbs IP/name for udp)
#   RD_KEY        hbbs public key (base64)
#   RD_PASSWORD   permanent password for the device
#   PROXY_IP      IP of nginx for the firewall allow rule
#   RD_GATEWAY    optional default route (NAT router) for the lan devices
#   RD_BG         solid desktop colour; lets a controller screenshot prove it
#                 is showing this device's screen
set -euo pipefail

RD_ROLE=${RD_ROLE:-device}
RD_NET_MODE=${RD_NET_MODE:-ws}
RD_FIREWALL=${RD_FIREWALL:-none}
RD_PASSWORD=${RD_PASSWORD:-}
log() { echo "[entrypoint $(hostname)] $*"; }

# The client derives its uuid from the machine id; give every container its
# own (kept across `docker restart`, like a real machine).
[ -s /etc/machine-id ] || dbus-uuidgen >/etc/machine-id
mkdir -p /var/lib/dbus && ln -sf /etc/machine-id /var/lib/dbus/machine-id

# Local test CA => system trust store (rustls platform verifier reads it).
if [ -f /ca/ca.crt ]; then
    cp /ca/ca.crt /usr/local/share/ca-certificates/patina-e2e-ca.crt
    update-ca-certificates >/dev/null 2>&1
fi

if [ -n "${RD_GATEWAY:-}" ]; then
    ip route replace default via "$RD_GATEWAY"
    log "default route via $RD_GATEWAY"
fi

if [ "$RD_FIREWALL" = "ws-only" ]; then
    : "${PROXY_IP:?PROXY_IP required for ws-only firewall}"
    iptables -F OUTPUT
    iptables -P OUTPUT DROP
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -p tcp -j ACCEPT
    # The bench networks are IPv4-only; still close IPv6 egress if it exists.
    if ip6tables -P OUTPUT DROP 2>/dev/null; then
        ip6tables -F OUTPUT && ip6tables -A OUTPUT -o lo -j ACCEPT
    fi
    iptables -A OUTPUT -p tcp -d "$PROXY_IP" --dport 443 -j ACCEPT
    iptables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
    # Everything else (all UDP, ICMP, other TCP) hits the DROP policy.
    log "firewall: OUTPUT DROP except lo and tcp ${PROXY_IP}:443"
    iptables -S OUTPUT
fi

home=/home/rd
cfgdir=$home/.config/rustdesk
mkdir -p "$cfgdir" /artifacts
chown -R rd:rd "$home" /artifacts

# RustDesk2.toml holds options; only seed it on first start so a container
# restart keeps whatever the client wrote (the restart tests rely on that).
if [ ! -f "$cfgdir/RustDesk2.toml" ]; then
    {
        echo "rendezvous_server = '${RD_SERVER}:21116'"
        echo "nat_type = 1"
        echo "serial = 0"
        echo
        echo "[options]"
        echo "custom-rendezvous-server = '${RD_SERVER}'"
        echo "relay-server = '${RD_SERVER}'"
        echo "key = '${RD_KEY}'"
        if [ "$RD_NET_MODE" = "ws" ]; then
            echo "allow-websocket = 'Y'"
            echo "api-server = 'https://${RD_DOMAIN}'"
        fi
        # Unattended access with a permanent password, no click-to-approve.
        echo "verification-method = 'use-permanent-password'"
        echo "approve-mode = 'password'"
        echo "enable-file-transfer = 'Y'"
    } >"$cfgdir/RustDesk2.toml"
    if [ -n "$RD_PASSWORD" ]; then
        # Plain value; the client encrypts it on first save.
        printf "password = '%s'\n" "$RD_PASSWORD" >"$cfgdir/RustDesk.toml"
    fi
    chown rd:rd "$cfgdir"/*.toml
    log "seeded config ($RD_ROLE, $RD_NET_MODE)"
fi

# Headless X11 desktop.
export DISPLAY=:0
rm -f /tmp/.X0-lock
su rd -c "Xvfb :0 -screen 0 1280x800x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &"
for _ in $(seq 50); do xdpyinfo -display :0 >/dev/null 2>&1 && break; sleep 0.2; done
su rd -c "DISPLAY=:0 openbox >/tmp/openbox.log 2>&1 &"
sleep 1
# Unique solid colour per container (openbox resets the root, so set it after).
su rd -c "DISPLAY=:0 xsetroot -solid '${RD_BG:-#2e7d32}'"

if [ "$RD_ROLE" = "device" ]; then
    # --server is what the systemd service would spawn inside the user
    # session: rendezvous registration + incoming connections. The GUI is
    # not started here: it keeps its own copy of RustDesk.toml and can
    # overwrite what --server writes; rd_gui starts it for screenshots.
    su rd -c "DISPLAY=:0 rustdesk --server >/tmp/rustdesk-server.out 2>&1 &"
else
    su rd -c "DISPLAY=:0 rustdesk >/tmp/rustdesk-gui.out 2>&1 &"
fi

log "started; tailing"
exec tail -F /tmp/rustdesk-server.out /tmp/rustdesk-gui.out 2>/dev/null
