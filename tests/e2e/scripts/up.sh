#!/bin/bash
# Start the server side (edge, hbbs, hbbr, nginx), then the requested profiles.
#   scripts/up.sh [profile...]      profiles: ws udp nat
set -euo pipefail
. "$(dirname "$0")/env.sh"
"$E2E_DIR/scripts/gen-certs.sh"
mkdir -p "$E2E_STATE/out"
log "hbbs image: $HBBS_IMAGE ($(docker image inspect -f '{{.Id}}' "$HBBS_IMAGE" | cut -c1-19))"
"${DC[@]}" up -d edge hbbs hbbr nginx
for _ in $(seq 30); do
    key=$(read_key) && [ -n "$key" ] && break
    sleep 1
done
[ -n "${key:-}" ] || { log "hbbs did not write its key"; exit 1; }
export RD_KEY=$key
echo "$key" >"$E2E_STATE/hbbs.pub"
log "hbbs key: $key"
if [ $# -gt 0 ]; then
    args=()
    for p in "$@"; do args+=(--profile "$p"); done
    "${DC[@]}" "${args[@]}" up -d
fi
