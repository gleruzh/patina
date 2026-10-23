#!/bin/bash
# Local test CA + server certificate for rd.e2e.test (idempotent).
set -euo pipefail
. "$(dirname "$0")/env.sh"
d=$E2E_STATE/certs
mkdir -p "$d"
[ -f "$d/server.crt" ] && { log "certs exist in $d"; exit 0; }
cat >"$d/server.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = rd.e2e.test
[ext]
subjectAltName = DNS:rd.e2e.test
extendedKeyUsage = serverAuth
basicConstraints = CA:FALSE
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=patina-e2e test CA" \
    -keyout "$d/ca.key" -out "$d/ca.crt" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$d/server.key" -out "$d/server.csr" \
    -config "$d/server.cnf" 2>/dev/null
openssl x509 -req -in "$d/server.csr" -CA "$d/ca.crt" -CAkey "$d/ca.key" -CAcreateserial \
    -days 30 -extfile "$d/server.cnf" -extensions ext -out "$d/server.crt" 2>/dev/null
chmod 0644 "$d/server.key"   # read by nginx in the container; test-only key
log "generated CA and server cert in $d"
