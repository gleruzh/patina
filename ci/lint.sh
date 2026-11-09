#!/usr/bin/env bash
#
# ci/lint.sh: static checks for what this repository owns in CI: actionlint (which also checks
# the run: blocks of the workflows with shellcheck), the scripts in ci/, hadolint for the
# Dockerfile, the publish.yml invariants (on request only, no cache, no Docker Hub token in env or
# run:), the Docker Hub page limits, that every "uses:" is pinned to a full commit SHA with a version
# comment, and that VERSION is a semantic version. Each linter runs from PATH if installed, else as the pinned
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

# publish.yml publishes on request only, never uses the Actions cache, never cancels a run halfway,
# and keeps the Docker Hub token out of env: and run: (it may only be an input of an action).
echo "publish.yml invariants"
wf=.github/workflows/publish.yml
if grep -nE '^[[:space:]]+(branches|branches-ignore|paths|paths-ignore|schedule|pull_request|pull_request_target|workflow_run):' "${wf}"; then
    fail "${wf}: publishing is on request only (tag or workflow_dispatch), no other trigger"
fi
if grep -nE 'cache-(from|to):|type=gha' "${wf}" | grep -vE '^[0-9]+:[[:space:]]*#'; then
    fail "${wf}: no Actions cache in a publish"
fi
if grep -n 'cancel-in-progress: true' "${wf}"; then fail "${wf}: a publish must never be cancelled halfway"; fi
if grep -nE '^[[:space:]]+[A-Za-z_]+:[[:space:]]*\$\{\{[[:space:]]*secrets\.DOCKERHUB_TOKEN' "${wf}" | grep -vE '^[0-9]+:[[:space:]]+password:'; then
    fail "${wf}: DOCKERHUB_TOKEN may only be the password: input of an action"
fi
if grep -nE '^[[:space:]]+[A-Z_]+:[[:space:]]*\$\{\{[[:space:]]*secrets\.DOCKERHUB_(USERNAME|TOKEN)[[:space:]]*\}\}' "${wf}" \
    | grep -vE 'DOCKERHUB_USER: '; then
    fail "${wf}: a Docker Hub secret in a step's env (only DOCKERHUB_USER for the repository name is allowed)"
fi
# Inside a run: block (lines indented deeper than the run: key) no ${{ secrets.* }}.
if awk '
    /^[[:space:]]*(- )?run:/ { match($0, /^[[:space:]]*/); base = RLENGTH; inrun = 1; next }
    inrun { match($0, /^[[:space:]]*/); if ($0 !~ /^[[:space:]]*$/ && RLENGTH <= base) inrun = 0 }
    inrun && /\$\{\{[^}]*secrets\./ { print FILENAME ":" NR ": " $0; found = 1 }
    END { exit !found }
' "${wf}"; then
    fail "${wf}: a secret interpolated into a run: script; pass it through env"
fi

# Closing older upstream issues needs these three lines of upstream-watch.yml; a rename must not
# silently turn the closing off.
echo "upstream-watch.yml hands report what it needs to close older issues"
uw=.github/workflows/upstream-watch.yml
grep -qE '^[[:space:]]+sha:[[:space:]]*\$\{\{[[:space:]]*steps\.check\.outputs\.sha[[:space:]]*\}\}' "${uw}" \
    || fail "${uw}: the job check must expose outputs.sha"
grep -qE '^[[:space:]]+UPSTREAM_SHA:[[:space:]]*\$\{\{[[:space:]]*needs\.check\.outputs\.sha[[:space:]]*\}\}' "${uw}" \
    || fail "${uw}: the report step must set UPSTREAM_SHA from needs.check.outputs.sha"
grep -qE '^[[:space:]]+DEFAULT_BRANCH:[[:space:]]*\$\{\{[[:space:]]*github\.event\.repository\.default_branch[[:space:]]*\}\}' "${uw}" \
    || fail "${uw}: the report step must set DEFAULT_BRANCH from github.event.repository.default_branch"

# report reads IN/<artifact name>/; download-artifact with a pattern unpacks there only when two or
# more artifacts match, so download by name; drop failed downloads before report, check after it.
echo "upstream-watch.yml downloads results by name, cleans up before and checks after reporting"
if grep -qE '^[[:space:]]+pattern:' "${uw}"; then
    fail "${uw}: download results by name (one step per artifact), not by pattern"
fi
for n in trial availability extra; do
    grep -qE "^[[:space:]]+path:[[:space:]]*\\$\{\{[[:space:]]*runner\.temp[[:space:]]*\}\}/in/upstream-watch-${n}\$" "${uw}" \
        || fail "${uw}: no download step with path runner.temp/in/upstream-watch-${n}"
    # the download and its retry, and the producing job's upload, all use the same name
    [[ "$(grep -cE "^[[:space:]]+name:[[:space:]]*upstream-watch-${n}\$" "${uw}")" -ge 3 ]] \
        || fail "${uw}: name: upstream-watch-${n} must appear in the upload, the download and its retry"
done
cln="$(grep -n 'name: Remove the results that did not download' "${uw}" | head -n 1 | cut -d: -f1)"
rep="$(grep -n 'name: Open the issue, close older ones' "${uw}" | head -n 1 | cut -d: -f1)"
chk="$(grep -n 'name: Check that the results arrived' "${uw}" | head -n 1 | cut -d: -f1)"
[[ -n "${cln}" && -n "${rep}" && "${cln}" -lt "${rep}" ]] \
    || fail "${uw}: 'Remove the results that did not download' must come before 'Open the issue, close older ones'"
[[ -n "${chk}" && -n "${rep}" && "${rep}" -lt "${chk}" ]] \
    || fail "${uw}: 'Check that the results arrived' must come after 'Open the issue, close older ones'"

# The Docker Hub page: at most 25,000 bytes (a longer one is cut silently), the short description at
# most 100 characters, and the cosign identity it shows is the one publish.yml verifies.
echo "docs/dockerhub.md limits"
[[ "$(wc -c < docs/dockerhub.md)" -le 25000 ]] || fail "docs/dockerhub.md is over 25,000 bytes"
short="$(sed -n 's/^[[:space:]]*short-description:[[:space:]]*//p' "${wf}")"
[[ -n "${short}" && "${#short}" -le 100 ]] || fail "short-description missing or over 100 characters (${#short})"
grep -qF 'publish\.yml@refs/(heads/master|tags/v[0-9]+\.[0-9]+\.[0-9]+)$' docs/dockerhub.md \
    || fail "docs/dockerhub.md: cosign identity regexp differs from publish.yml"

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
