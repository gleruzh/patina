#!/usr/bin/env bash
#
# ci/test.sh: the single entry point for the test suite (cargo test --locked). Used by ci.yml and by
# upstream-watch.yml; run it locally the same way: ci/test.sh
#
# The tests run in the builder image named by "ARG RUST_IMAGE=" in the Dockerfile, so the toolchain
# is exactly the one that builds the published image. The repository is mounted read-only and
# copied to a scratch directory inside the container: the working tree is never written to (no
# target/ directory, no touched db_v2.sqlite3), and the container is removed afterwards.
# The exit code is the result of cargo test. Needs Docker and network access (apt, crates.io).
#
# Optional: PATINA_CI_CACHE=1 keeps the cargo registry in the named volume patina-ci-cargo, which
# speeds up repeated local runs. CI leaves it unset.

set -euo pipefail

cd "$(dirname "$0")/.."
root="${PWD}"

rust_image="$(sed -n 's/^ARG RUST_IMAGE=//p' Dockerfile | head -n 1)"
if [[ -z "${rust_image}" ]]; then
    echo "ci/test.sh: no 'ARG RUST_IMAGE=' line in the Dockerfile" >&2
    exit 2
fi

# The libs/hbb_common submodule must be checked out. Only initialise it when it is missing, so a
# deliberate local checkout of another commit is left alone.
if [[ ! -f libs/hbb_common/Cargo.toml ]]; then
    echo "ci/test.sh: initialising the libs/hbb_common submodule"
    git submodule update --init libs/hbb_common
fi

args=(--rm --name "patina-ci-test-$$" -v "${root}:/src:ro")
if [[ "${PATINA_CI_CACHE:-}" == 1 ]]; then
    args+=(-v patina-ci-cargo:/usr/local/cargo/registry)
fi

echo "ci/test.sh: cargo test --locked in ${rust_image}"
# The script runs inside the container; its variables are expanded there, not here.
# shellcheck disable=SC2016
exec docker run "${args[@]}" "${rust_image}" bash -euo pipefail -c '
    # The same packages as the builder stage of the Dockerfile.
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends make pkg-config libssl-dev >/dev/null
    mkdir /work
    tar -C /src --exclude=./target --exclude=.git -cf - . | tar -C /work -xf -
    cd /work
    cargo test --locked
'
