#!/bin/sh
# Patina: check that hbbs and hbbr open no outbound connection on their own.
#
# Copyright (C) 2026 Patina contributors. AGPL-3.0, see LICENSE.
#
# Usage: tests/egress-check.sh <image built from ./Dockerfile> [seconds]
#
# Each server runs in a network namespace on an --internal docker network
# (no route out), with tcpdump capturing every packet in that namespace.
# api.rustdesk.com is pointed at a sink container on the same network, so a
# version check shows up as a SYN to the sink and never reaches the internet.
#
#   1. hbbs with defaults:        no TCP/UDP packet may leave the namespace.
#   2. hbbr with defaults:        no TCP/UDP packet may leave the namespace.
#   3. hbbs SOFTWARE_UPDATE_CHECK=Y (positive control): a SYN to the sink
#      must be captured, which proves the capture would have seen it.
#
# The servers run with --cap-drop ALL, so without CAP_NET_RAW they can only
# send TCP and UDP; the capture is limited to those, which leaves out the
# kernel's own IPv6 neighbour discovery, MLD and IGMP on interface bring-up.
# Loopback traffic of hbbs's own UDP self-test (test_hbbs, port 21116) is
# excluded too. Everything this script creates is named patina-test-egress-*
# and removed on exit.
set -eu

IMG=${1:?usage: $0 <image> [seconds]}
SECS=${2:-20}
P=patina-test-egress
NET=172.31.254
SINK=$NET.99
FILTER="(tcp or udp) and not (udp port 21116 and (host 127.0.0.1 or host ::1))"

cleanup() {
    docker rm -f $P-srv $P-dump $P-ns $P-sink >/dev/null 2>&1 || true
    docker network rm $P-net >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

docker build -q -t $P-tcpdump:local - >/dev/null <<'EOF'
FROM alpine:3
RUN apk add --no-cache tcpdump
EOF
docker network create --internal --subnet $NET.0/24 $P-net >/dev/null
docker run -d --name $P-sink --network $P-net --ip $SINK alpine:3 sleep 3600 >/dev/null

# capture <name> <server args...>: prints the packets the server sent or got
capture() {
    name=$1
    shift
    docker rm -f $P-srv $P-dump $P-ns >/dev/null 2>&1 || true
    docker run -d --name $P-ns --network $P-net --ip $NET.10 \
        --add-host api.rustdesk.com:$SINK --add-host relay.patina.test:$NET.98 \
        alpine:3 sleep 3600 >/dev/null
    docker run -d --name $P-dump --network container:$P-ns \
        --cap-add NET_RAW --cap-add NET_ADMIN \
        $P-tcpdump:local tcpdump -i any -nn -l -U "$FILTER" >/dev/null
    sleep 2
    docker run -d --name $P-srv --network container:$P-ns \
        --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 1000:1000 --tmpfs /data:rw,mode=1777 "$@" >/dev/null
    sleep "$SECS"
    echo "--- $name: $(docker logs $P-srv 2>&1 | grep -c .) log lines, version check:" >&2
    docker logs $P-srv 2>&1 | grep -i 'SOFTWARE_UPDATE_CHECK\|machine uid\|new version' >&2 || echo "(no mention)" >&2
    docker logs $P-dump 2>/dev/null | grep -v '^tcpdump\|^listening' || true
}

fail=0

out=$(capture "hbbs, defaults" "$IMG" hbbs -r relay.patina.test)
if [ -n "$out" ]; then
    echo "FAIL: hbbs sent packets with default settings:"; echo "$out"; fail=1
else
    echo "ok: hbbs with defaults sent nothing in ${SECS}s"
fi

out=$(capture "hbbr, defaults" "$IMG" hbbr -k _)
if [ -n "$out" ]; then
    echo "FAIL: hbbr sent packets with default settings:"; echo "$out"; fail=1
else
    echo "ok: hbbr with defaults sent nothing in ${SECS}s"
fi

out=$(capture "hbbs, SOFTWARE_UPDATE_CHECK=Y" -e SOFTWARE_UPDATE_CHECK=Y "$IMG" hbbs -r relay.patina.test)
if echo "$out" | grep -q "> $SINK.443: Flags \[S\]"; then
    echo "ok: positive control, SOFTWARE_UPDATE_CHECK=Y tried api.rustdesk.com ($SINK:443)"
else
    echo "FAIL: positive control saw no SYN to $SINK:443, the capture proves nothing:"
    echo "$out"; fail=1
fi

exit $fail
