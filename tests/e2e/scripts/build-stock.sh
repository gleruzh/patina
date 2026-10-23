#!/bin/bash
# Stock upstream baseline: hbbs/hbbr from 873230e -> patina-e2e-hbbs:stock-873230e
set -euo pipefail
commit=${1:-873230e35a8805de7fd057e7eb763c46f7a174ef}
exec "$(dirname "$0")/build-image.sh" "$commit" --tag "patina-e2e-hbbs:stock-${commit:0:7}"
