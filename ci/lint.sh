#!/usr/bin/env bash
#
# ci/lint.sh: static checks for what this repository owns in CI: actionlint (which also checks
# the run: blocks of the workflows with shellcheck), the scripts in ci/, hadolint for the
# Dockerfile, that every "uses:" is pinned to a full commit SHA with a version comment, and that
# VERSION is a semantic version. Each linter runs from PATH if installed, else as the pinned
# container below, so the result does not depend on the host. Exit code 0 means clean.
#
# The pins are tag and manifest-list digest. To bump one:
#   docker buildx imagetools inspect <image>:<tag>
# and replace both. (Dependabot does not read this file.)

set -euo pipefail

cd "$(dirname "$0")/.."

readonly ACTIONLINT_IMAGE='rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667'
readonly SHELLCHECK_IMAGE='koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d'
readonly HADOLINT_IMAGE='hadolint/hadolint:v2.15.1@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d'

status=0
fail() { echo "lint: $*" >&2; status=1; }

# tool NAME IMAGE ARGS...: run NAME from PATH, else IMAGE (repository mounted read-only at /repo).
tool() {
    local name="$1" image="$2"
    shift 2
    if command -v "${name}" >/dev/null 2>&1; then
        "${name}" "$@"
    else
        # --entrypoint: the images differ in what their entrypoint is; always call the tool by name.
        docker run --rm --entrypoint "${name}" -v "${PWD}:/repo:ro" -w /repo "${image}" "$@"
    fi
}

echo "actionlint .github/workflows"
tool actionlint "${ACTIONLINT_IMAGE}" || status=1

echo "shellcheck ci/*.sh"
tool shellcheck "${SHELLCHECK_IMAGE}" ci/*.sh || status=1

# DL3008 (pin apt versions) is ignored: the packages are installed in the builder stage only, which
# is not shipped; the runtime image is distroless and pinned by digest.
echo "hadolint Dockerfile"
tool hadolint "${HADOLINT_IMAGE}" --no-color --ignore DL3008 Dockerfile || status=1

# Every action is pinned to a 40-character commit SHA and says which release it is. Local actions
# (./) are not pinned; docker:// references must carry a digest.
echo "every uses: is pinned to a commit SHA"
while IFS= read -r hit; do
    line="${hit#*:*:}"
    ref="$(sed -E 's/^[[:space:]-]*uses:[[:space:]]*//; s/[[:space:]]*#.*$//' <<<"${line}")"
    case "${ref}" in
        ./*) ;;
        docker://*@sha256:*) ;;
        *@*)
            [[ "${ref#*@}" =~ ^[0-9a-f]{40}$ ]] || fail "not a full commit SHA: ${hit}"
            [[ "${line}" =~ \#[[:space:]]*v[0-9]+(\.[0-9]+)*[[:space:]]*$ ]] || fail "no '# vX.Y.Z' comment: ${hit}"
            ;;
        *) fail "no @ref: ${hit}" ;;
    esac
done < <(grep -rnE '^[[:space:]-]*uses:' .github/workflows .github/actions 2>/dev/null || true)

echo "VERSION is a semantic version"
version="$(cat VERSION 2>/dev/null || true)"
if [[ ! "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    fail "VERSION must be X.Y.Z (no v prefix, no suffix), got '${version}'"
fi
if [[ "$(wc -l < VERSION)" -ne 1 ]]; then
    fail "VERSION must be exactly one line"
fi

((status == 0)) && echo "lint: ok"
exit "${status}"
