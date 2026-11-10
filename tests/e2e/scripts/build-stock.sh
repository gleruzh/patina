#!/bin/bash
# Stock upstream baseline: hbbs/hbbr from 680b603 -> patina-e2e-hbbs:stock-680b603
set -euo pipefail
commit=${1:-680b60395ecf99a76f74a1d934e453bb6e5e0aa2}
exec "$(dirname "$0")/build-image.sh" "$commit" --tag "patina-e2e-hbbs:stock-${commit:0:7}"
