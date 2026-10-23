#!/bin/bash
# Run the end-to-end matrix against $HBBS_IMAGE.
#   scripts/run-matrix.sh [test...]     default: all except idle
#   scripts/run-matrix.sh all           everything including the 11 min idle test
# Tests: ready desktop filetransfer online keepalive replace restart_hbbs restart_nginx
#        restart_device udp_to_ws ws_to_udp nat spoof idle
# Results: $E2E_STATE/out/results.tsv, logs and screenshots in $E2E_STATE/out.
set -uo pipefail
. "$(dirname "$0")/env.sh"
. "$E2E_DIR/scripts/checks.sh"

READY_TIMEOUT=${READY_TIMEOUT:-90}
IDLE_SECONDS=${IDLE_SECONDS:-660}
# The device colour exists nowhere on the controller's own screen, so a few
# percent means a remote view of that device is being rendered.
MIN_SHARE=${MIN_SHARE:-5}
WS_DEV=patina-e2e-ws-device
WS_CTL=patina-e2e-ws-controller
UDP_DEV=patina-e2e-udp-device
UDP_CTL=patina-e2e-udp-controller
NAT_A=patina-e2e-nat-device-a
NAT_B=patina-e2e-nat-device-b
BG_WS=#2e7d32 BG_UDP=#1565c0 BG_NAT_A=#6a1b9a BG_NAT_B=#ef6c00

tests=("$@")
[ ${#tests[@]} -eq 0 ] && tests=(ready desktop filetransfer online keepalive replace restart_hbbs restart_nginx restart_device udp_to_ws ws_to_udp nat spoof)
[ "${tests[0]}" = all ] && tests=(ready desktop filetransfer online keepalive replace idle restart_hbbs restart_nginx restart_device udp_to_ws ws_to_udp nat spoof)

mkdir -p "$OUT"
: >"$RESULTS"
{
    echo "date: $(date -u +%FT%TZ)"
    echo "hbbs image: $HBBS_IMAGE $(docker image inspect -f '{{.Id}}' "$HBBS_IMAGE")"
    echo "hbbr image: $HBBR_IMAGE $(docker image inspect -f '{{.Id}}' "$HBBR_IMAGE")"
    echo "client image: $CLIENT_IMAGE $(docker image inspect -f '{{.Id}}' "$CLIENT_IMAGE")"
    echo "tests: ${tests[*]}"
} | tee "$OUT/run-info.txt" >&2

"$E2E_DIR/scripts/up.sh" ws udp nat || { log "bench failed to start"; exit 2; }
export RD_KEY=$(cat "$E2E_STATE/hbbs.pub")

# Remote desktop: controller opens a session, screenshot must be dominated by
# the device's desktop colour (each device paints a unique solid colour).
desktop_check() { # desktop_check <name> <controller> <device> <colour>
    local name=$1 ctl=$2 dev=$3 bg=$4 id share
    id=$(device_id "$dev")
    [ -n "$id" ] || { result FAIL "$name" "no id on $dev"; return; }
    close_gui_sessions "$ctl"
    connect_gui "$ctl" "$id"
    for _ in $(seq 15); do
        sleep 4
        shot "$ctl" "$name" >/dev/null
        share=$(colour_share "$ctl" "$name" "$bg")
        awk -v s="$share" -v MIN="$MIN_SHARE" 'BEGIN{exit !(s > MIN)}' && break
    done
    local png; png=$(shot "$ctl" "$name")
    if awk -v s="$share" -v MIN="$MIN_SHARE" 'BEGIN{exit !(s > MIN)}'; then
        result PASS "$name" "controller shows $dev desktop ($bg covers ${share}% of screen); id=$id; $png"
    else
        result FAIL "$name" "device colour $bg covers only ${share}% of controller screen; id=$id; $png"
    fi
}

t_ready() {
    if wait_ready "$WS_DEV" "$READY_TIMEOUT"; then
        result PASS ready "ws-only device $(device_id $WS_DEV) has key_confirmed (RegisterPkResponse OK over wss)"
    else
        result FAIL ready "ws-only device not ready after ${READY_TIMEOUT}s; wss connects: $(count_log $WS_DEV 'start tcp:'), 'unknown RegisterPkResponse' (NOT_SUPPORT etc): $(count_log $WS_DEV 'unknown RegisterPkResponse')"
    fi
    # Firewall sanity: proves the device really is WS-only.
    cexec "$WS_DEV" 'iptables -S OUTPUT; iptables -L OUTPUT -v -n' >"$OUT/ws-device-iptables.txt" 2>&1
    if cexec "$WS_DEV" 'timeout 3 bash -c "</dev/tcp/10.231.1.11/21116"' 2>/dev/null; then
        result FAIL firewall "ws-device can reach hbbs tcp/21116 directly"
    else
        result PASS firewall "ws-device cannot reach hbbs tcp/21116; OUTPUT policy DROP (see ws-device-iptables.txt)"
    fi
}

t_desktop() { desktop_check desktop "$WS_CTL" "$WS_DEV" "$BG_WS"; close_gui_sessions "$WS_CTL"; }

# File transfer: open the stock file manager, select the marker in the remote
# pane and press Receive (xdotool, fixed 1280x800 layout), then compare the
# copied file's content on the controller with the random token.
filetransfer_check() { # filetransfer_check <name> <controller> <device>
    local name=$1 ctl=$2 dev=$3 id token got png
    id=$(device_id "$dev")
    token="patina-e2e-$RANDOM$RANDOM"
    cexec "$dev" "echo $token >/home/rd/PATINA_E2E_MARKER.txt; chown rd:rd /home/rd/PATINA_E2E_MARKER.txt"
    docker exec "$ctl" rm -f /home/rd/PATINA_E2E_MARKER.txt
    close_gui_sessions "$ctl"
    connect_gui "$ctl" "$id" --file-transfer
    sleep 20
    shot "$ctl" "$name-listing" >/dev/null
    docker exec "$ctl" bash -c 'DISPLAY=:0 xdotool mousemove 600 294 click 1; sleep 1; DISPLAY=:0 xdotool mousemove 568 232 click 1'
    for _ in $(seq 10); do
        sleep 2
        got=$(docker exec "$ctl" cat /home/rd/PATINA_E2E_MARKER.txt 2>/dev/null)
        [ -n "$got" ] && break
    done
    png=$(shot "$ctl" "$name")
    if [ "$got" = "$token" ]; then
        result PASS "$name" "copied PATINA_E2E_MARKER.txt from $dev ($id) to the controller over the relay, content matches $token; $png"
    else
        result FAIL "$name" "marker not copied (controller has '${got}', expected $token); listing: ${png%.png}-listing.png"
    fi
    close_gui_sessions "$ctl"
}

t_filetransfer() { filetransfer_check filetransfer "$WS_CTL" "$WS_DEV"; }

t_online() {
    local id st; id=$(device_id "$WS_DEV")
    st=$(online_state "$id")
    if [ "$st" = true ]; then
        result PASS online "OnlineRequest over wss /ws/id reports $id online"
    else
        result FAIL online "OnlineRequest over wss /ws/id for $id -> $st"
    fi
    # Offline must show promptly after the device goes away.
    docker stop -t 5 "$WS_DEV" >/dev/null
    sleep 5
    st=$(online_state "$id")
    docker start "$WS_DEV" >/dev/null
    if [ "$st" = false ]; then
        result PASS offline "5s after stopping the device OnlineRequest reports $id offline"
    else
        result FAIL offline "5s after stopping the device OnlineRequest -> $st"
    fi
    wait_ready "$WS_DEV" "$READY_TIMEOUT" || true
    # Controller GUI peer list (visual check of the dot).
    shot "$WS_CTL" online >/dev/null
    result MANUAL online_gui "controller peer-card dot: see ws-controller-online.png"
}

t_idle() {
    local id starts0 starts1 t0
    id=$(device_id "$WS_DEV")
    wait_ready "$WS_DEV" "$READY_TIMEOUT" || { result FAIL idle "device not ready before idle test"; return; }
    starts0=$(count_log "$WS_DEV" 'start tcp:')
    close_gui_sessions "$WS_CTL"
    connect_gui "$WS_CTL" "$id"
    sleep 20
    t0=$(date +%s)
    log "idle: waiting ${IDLE_SECONDS}s (rendezvous ws + an open remote session)"
    sleep "$IDLE_SECONDS"
    starts1=$(count_log "$WS_DEV" 'start tcp:')
    local st; st=$(online_state "$id")
    shot "$WS_CTL" idle-end >/dev/null
    local share; share=$(colour_share "$WS_CTL" idle-end "$BG_WS")
    if [ "$starts1" -eq "$starts0" ] && [ "$st" = true ] && device_ready "$WS_DEV"; then
        result PASS idle "$(( $(date +%s) - t0 ))s idle: no rendezvous reconnect (start tcp count $starts0 -> $starts1), still online"
    else
        result FAIL idle "after $(( $(date +%s) - t0 ))s: start tcp $starts0 -> $starts1, online=$st"
    fi
    if awk -v s="$share" -v MIN="$MIN_SHARE" 'BEGIN{exit !(s > MIN)}'; then
        result PASS idle_session "remote session still showing device desktop after idle (${share}%)"
    else
        result FAIL idle_session "remote session not showing device desktop after idle (${share}%); ws-controller-idle-end.png"
    fi
    close_gui_sessions "$WS_CTL"
}

# Restart recovery is judged from hbbs's side: after the restart the device
# must log a new rendezvous connect, then hbbs must report it online again
# (OnlineRequest) within RESTART_TIMEOUT with the same ID. The client's
# on-disk key_confirmed survives restarts, so it alone proves nothing.
restart_check() { # restart_check <name> <container to restart> <device>
    local name=$1 target=$2 dev=$3
    local id0 id1 st="" t0 secs n starts0 reg0 reg1 mm0
    id0=$(device_id "$dev")
    mm0=$(count_log "$dev" 'UUID_MISMATCH')
    starts0=$(count_log "$dev" 'start tcp:')
    reg0=$(docker logs patina-e2e-hbbs 2>&1 | grep -c "peer $id0 registered" || true)
    t0=$(date +%s)
    docker restart -t 5 "$target" >/dev/null
    for _ in $(seq 40); do
        n=$(count_log "$dev" 'start tcp:')
        [ "$n" -gt "$starts0" ] && break
        sleep 3
    done
    if [ "$n" -le "$starts0" ]; then
        result FAIL "$name" "${dev#patina-e2e-} never reconnected after restarting ${target#patina-e2e-}"
        return
    fi
    while [ $(( $(date +%s) - t0 )) -lt "${RESTART_TIMEOUT:-150}" ]; do
        st=$(online_state "$id0")
        [ "$st" = true ] && device_ready "$dev" && break
        sleep 3
    done
    secs=$(( $(date +%s) - t0 ))
    id1=$(device_id "$dev")
    reg1=$(docker logs patina-e2e-hbbs 2>&1 | grep -c "peer $id0 registered" || true)
    local detail="restarted ${target#patina-e2e-}; online=$st after ${secs}s; id $id0 -> $id1; hbbs 'peer $id0 registered' log lines $reg0 -> $reg1; UUID_MISMATCH $mm0 -> $(count_log "$dev" UUID_MISMATCH)"
    if [ "$st" = true ] && [ "$id1" = "$id0" ] && [ "$(count_log "$dev" UUID_MISMATCH)" = "$mm0" ]; then
        result PASS "$name" "$detail"
    else
        result FAIL "$name" "$detail"
    fi
}

# Server keepalive as seen through nginx: RegisterPk OK, keep_alive in the
# response, and empty binary frames at a steady cadence (echoed back).
t_keepalive() {
    local id="e2ekeep$RANDOM$RANDOM" out res ka frames
    out=$(probe register "$WSS_ID" --id "$id" --hold "${KEEPALIVE_HOLD:-45}")
    echo "$out" >"$OUT/keepalive-register.json"
    res=$(sed -n 's/.*"result": "\{0,1\}\([A-Z_a-z]*\).*/\1/p' <<<"$out")
    ka=$(sed -n 's/.*"keep_alive": \([0-9]*\).*/\1/p' <<<"$out")
    frames=$(sed -n 's/.*"empty_frames_at_s": \[\([^]]*\)\].*/\1/p' <<<"$out")
    local gaps; gaps=$(awk -F', *' '{p=0; for (i=1;i<=NF;i++) if ($i!="") {printf "%s%.1f", (i>1?" ":""), $i-p; p=$i}}' <<<"$frames")
    local maxgap; maxgap=$(tr ' ' '\n' <<<"$gaps" | sort -n | tail -1)
    if [ "$res" = OK ] && [ "${ka:-0}" -gt 0 ] && [ -n "$frames" ] && grep -q '"open_at_end": true' <<<"$out" \
        && awk -v m="${maxgap:-999}" -v k="$ka" 'BEGIN{exit !(m < k)}'; then
        result PASS keepalive "RegisterPk OK, keep_alive=${ka}s; empty frames at [$frames]s (gaps $gaps), connection open after ${KEEPALIVE_HOLD:-45}s"
    else
        result FAIL keepalive "result=$res keep_alive=$ka frames=[$frames] gaps=[$gaps]; see keepalive-register.json"
    fi
}

# Replace-on-reconnect and id hijack, end to end through nginx:
# A registers id X; B registers X with the same uuid/pk (a reconnect) and must
# take over while the server closes A; C tries X with another uuid and must get
# UUID_MISMATCH without disturbing B. X stays online throughout.
t_replace() {
    local id="e2erepl$RANDOM$RANDOM" uuid="e2e-uuid-$RANDOM$RANDOM" pk
    pk=$(openssl rand -hex 32)
    local fa="$OUT/replace-a.json" fb="$OUT/replace-b.json" fc="$OUT/replace-c.json"
    local rep0; rep0=$(docker logs patina-e2e-hbbs 2>&1 | grep -c "WebSocket peer $id: connection .* replaces" || true)
    probe register "$WSS_ID" --id "$id" --uuid "$uuid" --pk "$pk" --hold 30 >"$fa" &
    local pa=$!
    sleep 7
    probe register "$WSS_ID" --id "$id" --uuid "$uuid" --pk "$pk" --hold 25 >"$fb" &
    local pb=$!
    sleep 7
    probe register "$WSS_ID" --id "$id" --uuid "other-$uuid" --pk "$(openssl rand -hex 32)" >"$fc"
    local on; on=$(online_state "$id")
    wait "$pa" "$pb"
    local rep1; rep1=$(docker logs patina-e2e-hbbs 2>&1 | grep -c "WebSocket peer $id: connection .* replaces" || true)
    local ra rb rc
    ra=$(sed -n 's/.*"result": "\{0,1\}\([A-Z_a-z]*\).*/\1/p' "$fa")
    rb=$(sed -n 's/.*"result": "\{0,1\}\([A-Z_a-z]*\).*/\1/p' "$fb")
    rc=$(sed -n 's/.*"result": "\{0,1\}\([A-Z_a-z]*\).*/\1/p' "$fc")
    local a_closed b_open
    a_closed=$(sed -n 's/.*"closed_after_s": \([0-9.]*\).*/\1/p' "$fa")
    grep -q '"open_at_end": true' "$fb" && b_open=yes || b_open=no
    local detail="A=$ra closed_after=${a_closed:-never}s; B=$rb open_at_end=$b_open; C(other uuid)=$rc; online during B=$on; hbbs 'replaces' lines $rep0 -> $rep1"
    if [ "$ra" = OK ] && [ -n "$a_closed" ] && [ "$rb" = OK ] && [ "$b_open" = yes ] \
        && [ "$rc" = UUID_MISMATCH ] && [ "$on" = true ] && [ "$rep1" -gt "$rep0" ]; then
        result PASS replace "$detail"
    else
        result FAIL replace "$detail; see replace-[abc].json"
    fi
}

t_restart_hbbs() { restart_check restart_hbbs patina-e2e-hbbs "$WS_DEV"; }
t_restart_nginx() { restart_check restart_nginx patina-e2e-nginx "$WS_DEV"; }
t_restart_device() { restart_check restart_device "$WS_DEV" "$WS_DEV"; }

t_udp_to_ws() {
    wait_ready "$WS_DEV" "$READY_TIMEOUT" || true
    desktop_check udp_to_ws "$UDP_CTL" "$WS_DEV" "$BG_WS"
    filetransfer_check udp_to_ws_filetransfer "$UDP_CTL" "$WS_DEV"
}

t_ws_to_udp() {
    if wait_ready "$UDP_DEV" "$READY_TIMEOUT"; then
        result PASS udp_device_ready "UDP-mode device $(device_id $UDP_DEV) registered"
    else
        result FAIL udp_device_ready "UDP-mode device not registered"
    fi
    desktop_check ws_to_udp "$WS_CTL" "$UDP_DEV" "$BG_UDP"
    filetransfer_check ws_to_udp_filetransfer "$WS_CTL" "$UDP_DEV"
}

t_nat() {
    local a b
    wait_ready "$NAT_A" "$READY_TIMEOUT" && a=ok || a=no
    wait_ready "$NAT_B" "$READY_TIMEOUT" && b=ok || b=no
    local ida idb; ida=$(device_id "$NAT_A"); idb=$(device_id "$NAT_B")
    local on; on=$(probe online "$WSS_ID" --peers "$ida,$idb" --brief)
    if [ $a = ok ] && [ $b = ok ] && [ "$on" = "true true" ]; then
        result PASS nat_ready "both devices behind one NAT ready and online ($ida, $idb)"
    else
        result FAIL nat_ready "nat-device-a ready=$a nat-device-b ready=$b online='$on' ($ida, $idb)"
    fi
    # Both devices must reach nginx as the router's single address.
    local via; via=$(docker logs patina-e2e-nginx 2>/dev/null | grep -c '^10\.231\.1\.30 .*"GET /ws/id')
    if [ "$via" -gt 0 ]; then
        result PASS nat_path "nginx saw $via /ws/id requests from the NAT router address 10.231.1.30"
    else
        result FAIL nat_path "no /ws/id requests from 10.231.1.30 in the nginx log: the NAT path is broken"
    fi
    desktop_check nat_a "$WS_CTL" "$NAT_A" "$BG_NAT_A"
    desktop_check nat_b "$WS_CTL" "$NAT_B" "$BG_NAT_B"
    close_gui_sessions "$WS_CTL"
}

# stored_ip <probe-json-of-dbinfo>  -> the ip hbbs stored for the peer
stored_ip() { sed -n 's/.*"ip": "\([^"]*\)".*/\1/p' <<<"$1"; }

t_spoof() {
    local id="e2espoof$RANDOM$RANDOM" out res db ip me
    # 1) Direct to hbbs:21118 from an untrusted container with forged headers.
    out=$(probe register ws://10.231.1.11:21118/ws/id --id "$id" \
        --header 'X-Real-IP: 203.0.113.77' --header 'X-Forwarded-For: 203.0.113.78')
    echo "$out" >"$OUT/spoof-register.json"
    res=$(sed -n 's/.*"result": "\{0,1\}\([A-Z_a-z]*\).*/\1/p' <<<"$out")
    me=$(sed -n 's/.*"local_ip": "\([^"]*\)".*/\1/p' <<<"$out")
    db=$(probe dbinfo --id "$id")
    echo "$db" >"$OUT/spoof-dbinfo.json"
    ip=$(stored_ip "$db")
    docker logs patina-e2e-hbbs 2>&1 | grep -iE 'untrusted|x-real-ip|forwarded|trusted' | tail -5 >"$OUT/spoof-hbbs-log.txt"
    if grep -q '203\.0\.113\.' <<<"$db"; then
        result FAIL spoof "hbbs stored the forged IP: $db"
    elif grep -q '"found": true' <<<"$db"; then
        if [[ "$ip" == *"$me"* ]]; then
            result PASS spoof "direct 21118 + forged X-Real-IP/XFF: RegisterPk $res, stored ip '$ip' = real peer $me; hbbs log: $(head -c 300 "$OUT/spoof-hbbs-log.txt" | tr '\n' ' ')"
        else
            result FAIL spoof "stored ip '$ip' is neither forged nor the real peer $me: $db"
        fi
    else
        result SKIP spoof "direct WS RegisterPk -> ${res:-no response}; nothing stored, so header handling not observable this way (expected on stock hbbs)"
    fi
    # 2) Positive control: through nginx (trusted) the real client IP must be
    #    taken from X-Real-IP, i.e. the probe, not nginx 10.231.1.10.
    id="e2etrust$RANDOM$RANDOM"
    out=$(probe register "$WSS_ID" --id "$id")
    echo "$out" >"$OUT/trusted-register.json"
    me=$(sed -n 's/.*"local_ip": "\([^"]*\)".*/\1/p' <<<"$out")
    db=$(probe dbinfo --id "$id"); ip=$(stored_ip "$db")
    if ! grep -q '"found": true' <<<"$db"; then
        result SKIP trusted_proxy "RegisterPk via nginx stored nothing ($(sed -n 's/.*"result": "\{0,1\}\([A-Z_a-z]*\).*/\1/p' <<<"$out"))"
    elif [[ "$ip" == *"$me"* ]]; then
        result PASS trusted_proxy "via nginx: stored ip '$ip' = real client $me (X-Real-IP honoured from the trusted proxy)"
    else
        result FAIL trusted_proxy "via nginx: stored ip '$ip', expected client $me (nginx is 10.231.1.10)"
    fi
}

for t in "${tests[@]}"; do
    log "=== $t"
    "t_$t"
done

log "device GUI screenshots (status line should read Ready)"
for c in "$WS_DEV" "$UDP_DEV" "$NAT_A" "$NAT_B"; do cexec "$c" rd_gui >/dev/null 2>&1; done
sleep 15
for c in "$WS_DEV" "$UDP_DEV" "$NAT_A" "$NAT_B"; do shot "$c" gui-status >/dev/null; done
result MANUAL gui_status "device main windows: *-gui-status.png (status line Ready vs Connecting)"

log "collecting logs"
for c in $(docker ps -a --format '{{.Names}}' | grep '^patina-e2e-'); do
    docker logs "$c" >"$OUT/$c.docker.log" 2>&1
    case $c in *device*|*controller*)
        server_log "$c" >"$OUT/$c.rustdesk-server.log" 2>/dev/null
        cexec "$c" 'cat /home/rd/.local/share/logs/RustDesk/rustdesk_r*.log 2>/dev/null' >"$OUT/$c.rustdesk-gui.log" 2>/dev/null ;;
    esac
done
echo >&2
column -t -s $'\t' "$RESULTS" >&2 || cat "$RESULTS" >&2
