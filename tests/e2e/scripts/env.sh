# Sourced by the bench scripts. Override any of these from the environment.
E2E_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export E2E_STATE=${E2E_STATE:-${TMPDIR:-/tmp}/patina-e2e-state}
export E2E_STATE=${E2E_STATE%/}
export HBBS_IMAGE=${HBBS_IMAGE:-patina-e2e-hbbs:stock-873230e}
# hbbr is stock in every run (no hbbr changes are expected).
export HBBR_IMAGE=${HBBR_IMAGE:-patina-e2e-hbbs:stock-873230e}
export CLIENT_IMAGE=${CLIENT_IMAGE:-patina-e2e-client:1.5.0}
export PROBE_IMAGE=${PROBE_IMAGE:-patina-e2e-probe:latest}
export RD_PASSWORD=${RD_PASSWORD:-E2e-Pass-4821}
DC=(docker compose -f "$E2E_DIR/compose.yaml" -p patina-e2e)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# The hbbs public key lives in the shared volume; read it with a throwaway
# container because the server image may have no shell.
read_key() {
    docker run --rm -v patina-e2e-hbbs-data:/d:ro --entrypoint cat "$CLIENT_IMAGE" /d/id_ed25519.pub 2>/dev/null
}
