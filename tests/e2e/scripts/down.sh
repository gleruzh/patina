#!/bin/bash
# Remove every bench resource by name. Never prunes anything.
#   scripts/down.sh [--images]   also remove the patina-e2e-* images built here
set -uo pipefail
. "$(dirname "$0")/env.sh"
"${DC[@]}" --profile ws --profile udp --profile nat --profile probe down --remove-orphans --volumes 2>/dev/null
for c in $(docker ps -a --format '{{.Names}}' | grep '^patina-e2e-'); do docker rm -f "$c"; done
for n in patina-e2e-wan patina-e2e-ctl patina-e2e-lan patina-e2e-proxy; do docker network rm "$n" 2>/dev/null; done
for v in patina-e2e-hbbs-data patina-e2e-ws-device-home; do docker volume rm "$v" 2>/dev/null; done
if [ "${1:-}" = "--images" ]; then
    for i in $(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^patina-e2e-'); do docker rmi "$i"; done
fi
log "removed patina-e2e-* containers, networks and volumes"
