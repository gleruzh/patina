#!/usr/bin/env bash
# Helper of .github/workflows/upstream-watch.yml. Subcommands:
#   check         newest upstream master commit, and whether it still needs a report (job "check")
#   trial         trial merge of that commit and ci/test.sh (job "trial"; runs upstream code)
#   availability  are the pinned source commits still fetchable upstream (job "availability")
#   report        open / close issues from the data of the jobs above (job "report")
#
# Environment (all optional unless noted):
#   UPSTREAM_FILE  file with repo= and commit= lines (default UPSTREAM)
#   OUT            output directory of trial / availability (default ${RUNNER_TEMP:-/tmp}/upstream-out)
#   IN             directory with the downloaded artifacts for report
#   TARGET_SHA     upstream master commit to work on (trial; set by "check")
#   FORCE=true     report a commit again although an issue for it exists
#   DRY_RUN=1      report: print what would be sent to the GitHub API, send nothing
#   DRY_RUN_ISSUES JSON file standing in for `gh issue list` in a dry run (default [])
#   UPSTREAM_REPO_OVERRIDE  test only: use this URL/path instead of the repo= line
set -euo pipefail

UPSTREAM_FILE="${UPSTREAM_FILE:-UPSTREAM}"
OUT="${OUT:-${RUNNER_TEMP:-/tmp}/upstream-out}"
HBB_URL='https://github.com/rustdesk/hbb_common'
SUBMODULE='libs/hbb_common'
TITLE_PREFIX='upstream: rustdesk-server '
LABEL='upstream'

die() { echo "::error::$*" >&2; exit 1; }

# set_output NAME VALUE
set_output() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/stdout}"; }

read_upstream() {
  [[ -f "${UPSTREAM_FILE}" ]] || die "${UPSTREAM_FILE} not found"
  UP_REPO="$(sed -n 's/^repo=//p' "${UPSTREAM_FILE}" | head -n 1)"
  UP_COMMIT="$(sed -n 's/^commit=//p' "${UPSTREAM_FILE}" | head -n 1)"
  [[ "${UP_REPO}" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "bad repo= line in ${UPSTREAM_FILE}"
  [[ "${UP_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "bad commit= line in ${UPSTREAM_FILE}"
  UP_REPO="${UPSTREAM_REPO_OVERRIDE:-${UP_REPO}}"
}

pin_of() { git ls-tree "$1" "${SUBMODULE}" | awk '$2 == "commit" {print $3}'; }

fetch_upstream() {
  git fetch --quiet --no-tags --no-recurse-submodules "${UP_REPO}" \
    '+refs/heads/master:refs/upstream/master' '+refs/tags/*:refs/upstream-tags/*'
}

# ---------------------------------------------------------------- check
issues_json() {
  if [[ -n "${DRY_RUN:-}" ]]; then
    if [[ -n "${DRY_RUN_ISSUES:-}" ]]; then cat "${DRY_RUN_ISSUES}"; else echo '[]'; fi
  else
    gh issue list --repo "${GITHUB_REPOSITORY}" --label "${LABEL}" --state all --limit 300 \
      --json number,title,state,url
  fi
}

cmd_check() {
  read_upstream
  fetch_upstream
  local sha count short run=false
  sha="$(git rev-parse --verify refs/upstream/master)"
  short="${sha:0:7}"
  count="$(git rev-list --count "${UP_COMMIT}..${sha}")"
  echo "UPSTREAM pins ${UP_COMMIT:0:7}; upstream master is ${short}, ${count} new commit(s)."
  if [[ "${count}" == 0 ]]; then
    echo "Nothing new upstream."
  elif [[ "$(issues_json | jq --arg t "${TITLE_PREFIX}${short} " '[.[] | select(.title | startswith($t))] | length')" != 0 && "${FORCE:-}" != true ]]; then
    echo "An issue for ${short} exists already; nothing to do (run with force to report it again)."
  else
    run=true
  fi
  set_output sha "${sha}"
  set_output run_trial "${run}"
  # Weekly pin-availability check: Mondays (UTC) and manual runs.
  if [[ "${EVENT_NAME:-}" == workflow_dispatch || "$(date -u +%u)" == 1 ]]; then
    set_output weekly true
  else
    set_output weekly false
  fi
}

# ---------------------------------------------------------------- trial
run_tests() { if command -v timeout > /dev/null; then timeout 3300 bash ci/test.sh; else bash ci/test.sh; fi; }

cmd_trial() {
  read_upstream
  local sha="${TARGET_SHA:?TARGET_SHA is required}"
  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || die "bad TARGET_SHA"
  fetch_upstream
  git cat-file -e "${sha}^{commit}" || die "${sha} is not in the fetched upstream history"
  mkdir -p "${OUT}"
  : > "${OUT}/commits.txt"; : > "${OUT}/tags.txt"; : > "${OUT}/conflicts.txt"; : > "${OUT}/testlog.txt"

  # --- what changed upstream
  local total=0 flagged=0 rev subject body flag
  while read -r rev; do
    total=$((total + 1))
    subject="$(git log -1 --format=%s "${rev}")"
    body="$(git log -1 --format=%b "${rev}")"
    flag=' '
    if printf '%s\n%s\n' "${subject}" "${body}" | grep -qiE 'security|cve|vuln|fix'; then
      flag='*'; flagged=$((flagged + 1))
    fi
    if ((total <= 100)); then printf '%s %s %s\n' "${flag}" "${rev:0:7}" "${subject}" >> "${OUT}/commits.txt"; fi
  done < <(git rev-list "${UP_COMMIT}..${sha}")

  local ref tag
  while read -r ref; do
    tag="${ref#refs/upstream-tags/}"
    if ! git merge-base --is-ancestor "$(git rev-parse "${ref}^{commit}")" "${UP_COMMIT}"; then
      echo "${tag}" >> "${OUT}/tags.txt"
    fi
  done < <(git for-each-ref --sort=-creatordate --count=50 --format='%(refname)' refs/upstream-tags)

  local pin_base pin_new pin_ours
  pin_base="$(pin_of "${UP_COMMIT}")"
  pin_new="$(pin_of "${sha}")"
  pin_ours="$(pin_of HEAD)"

  # --- trial merge on a throwaway branch; nothing is committed or pushed
  git config user.name 'upstream-watch'
  git config user.email 'upstream-watch@users.noreply.github.com'
  git switch --quiet -C upstream-trial
  local state test_exit=
  if git merge --no-commit --no-ff "${sha}" > "${OUT}/merge.log" 2>&1; then
    echo "Merge is clean; running ci/test.sh"
    set +e
    {
      git submodule update --init --recursive \
        && { [[ -f ci/test.sh ]] || { echo "ci/test.sh is missing"; false; }; } \
        && run_tests
    } 2>&1 | tee "${OUT}/testlog.full"
    test_exit="${PIPESTATUS[0]}"
    set -e
    tail -n 100 "${OUT}/testlog.full" > "${OUT}/testlog.txt"
    if [[ "${test_exit}" == 0 ]]; then state=clean; else state=tests-failing; fi
  else
    state=conflict
    git diff --name-only --diff-filter=U | head -n 200 > "${OUT}/conflicts.txt"
    tail -n 30 "${OUT}/merge.log" > "${OUT}/testlog.txt"
    echo "Merge failed; conflicted files:"; cat "${OUT}/conflicts.txt"
  fi
  rm -f "${OUT}/testlog.full" "${OUT}/merge.log"
  {
    echo "state=${state}"
    echo "sha=${sha}"
    echo "base=${UP_COMMIT}"
    echo "total=${total}"
    echo "flagged=${flagged}"
    echo "pin_base=${pin_base}"
    echo "pin_new=${pin_new}"
    echo "pin_ours=${pin_ours}"
    echo "test_exit=${test_exit}"
  } > "${OUT}/meta.env"
  echo "Result: ${state}"
}

# ---------------------------------------------------------------- availability
fetchable() { # URL SHA
  local d i
  d="$(mktemp -d)"
  git -C "${d}" init --quiet
  for i in 1 2 3; do
    if git -C "${d}" fetch --quiet --depth=1 "$1" "$2" 2>/dev/null; then rm -rf "${d}"; return 0; fi
    sleep $((i * 5))
  done
  rm -rf "${d}"; return 1
}

cmd_availability() {
  read_upstream
  mkdir -p "${OUT}"
  : > "${OUT}/missing.txt"
  local pin
  pin="$(pin_of HEAD)"
  [[ "${pin}" =~ ^[0-9a-f]{40}$ ]] || die "no ${SUBMODULE} pin in HEAD"
  local url which sha
  for item in "hbb_common ${HBB_URL} ${pin}" "rustdesk-server ${UP_REPO} ${UP_COMMIT}"; do
    read -r which url sha <<< "${item}"
    # A host that does not answer at all is a failed run, not "the commit is gone".
    git ls-remote --quiet "${url}" HEAD > /dev/null || die "${url} is unreachable; cannot judge ${which} ${sha}"
    if fetchable "${url}" "${sha}"; then
      echo "ok: ${which} ${sha} is fetchable from ${url}"
    else
      echo "::warning::${which} ${sha} is NOT fetchable from ${url}"
      echo "${which} ${sha}" >> "${OUT}/missing.txt"
    fi
  done
}

# ---------------------------------------------------------------- report
# Everything read from the trial job is data: validated or cut down before it goes anywhere.
sanitize() { # MAX_LINES MAX_BYTES
  iconv -c -f UTF-8 -t UTF-8 2> /dev/null | LC_ALL=C tr -d '\000-\010\013-\037\177' \
    | LC_ALL=C cut -c1-300 | head -n "$1" | head -c "$2"
}

# fenced FILE: a code block whose fence is longer than any run of backticks inside.
fenced() {
  local fence='```'
  while grep -qF -- "${fence}" "$1"; do fence+='`'; done
  echo "${fence}"
  cat "$1"
  echo
  echo "${fence}"
}

meta() { sed -n "s/^$2=//p" "$1/meta.env" | head -n 1; }

gh_write() {
  if [[ -n "${DRY_RUN:-}" ]]; then echo "DRY-RUN: gh $*" >&2; else gh "$@"; fi
}

ensure_labels() {
  gh_write label create "${LABEL}" --repo "${GITHUB_REPOSITORY}" --color 5319e7 \
    --description 'Upstream rustdesk-server watch' > /dev/null 2>&1 || true
  gh_write label create source-availability --repo "${GITHUB_REPOSITORY}" --color d93f0b \
    --description 'Pinned upstream source no longer fetchable' > /dev/null 2>&1 || true
}

create_issue() { # TITLE BODYFILE LABEL...
  local title="$1" bodyfile="$2" args=() l
  shift 2
  for l in "$@"; do args+=(--label "${l}"); done
  if [[ -n "${DRY_RUN:-}" ]]; then
    echo "DRY-RUN: gh issue create --title '${title}' ${args[*]}" >&2
    echo "----- body -----" >&2; cat "${bodyfile}" >&2; echo "----- end -----" >&2
    echo "https://github.com/${GITHUB_REPOSITORY:-owner/repo}/issues/0"
  else
    gh issue create --repo "${GITHUB_REPOSITORY}" --title "${title}" --body-file "${bodyfile}" "${args[@]}"
  fi
}

report_trial() {
  local d="$1" state sha base total flagged pin_base pin_new pin_ours test_exit short
  state="$(meta "${d}" state)"; sha="$(meta "${d}" sha)"; base="$(meta "${d}" base)"
  total="$(meta "${d}" total)"; flagged="$(meta "${d}" flagged)"
  pin_base="$(meta "${d}" pin_base)"; pin_new="$(meta "${d}" pin_new)"; pin_ours="$(meta "${d}" pin_ours)"
  test_exit="$(meta "${d}" test_exit)"
  [[ "${state}" =~ ^(clean|conflict|tests-failing)$ ]] || { echo "::warning::bad state in trial data; skipping"; return 0; }
  local h; for h in "${sha}" "${base}"; do [[ "${h}" =~ ^[0-9a-f]{40}$ ]] || { echo "::warning::bad sha in trial data; skipping"; return 0; }; done
  for h in "${pin_base}" "${pin_new}" "${pin_ours}"; do [[ -z "${h}" || "${h}" =~ ^[0-9a-f]{40}$ ]] || { echo "::warning::bad pin in trial data; skipping"; return 0; }; done
  [[ "${total}" =~ ^[0-9]{1,7}$ && "${flagged}" =~ ^[0-9]{1,7}$ ]] || { echo "::warning::bad counts in trial data; skipping"; return 0; }
  [[ -z "${test_exit}" || "${test_exit}" =~ ^[0-9]{1,3}$ ]] || test_exit=255
  short="${sha:0:7}"

  local label_state="${state/-/ }" issues
  issues="$(issues_json)"
  if [[ "$(jq --arg t "${TITLE_PREFIX}${short} " '[.[] | select(.title | startswith($t))] | length' <<< "${issues}")" != 0 && "${FORCE:-}" != true ]]; then
    echo "An issue for ${short} exists already; nothing to do."
    return 0
  fi

  local w; w="$(mktemp -d)"
  sanitize 100 12000 < "${d}/commits.txt" > "${w}/commits"
  sanitize 50 2000 < "${d}/tags.txt" | grep -E '^[A-Za-z0-9._+-]{1,64}$' > "${w}/tags" || true
  sanitize 200 10000 < "${d}/conflicts.txt" > "${w}/conflicts"
  sanitize 100 12000 < "${d}/testlog.txt" > "${w}/log"

  {
    echo "Upstream rustdesk-server master moved: \`${base:0:7}\` -> \`${sha:0:7}\` (${total} new commit(s), ${flagged} marked \`*\` because the message mentions security / CVE / fix / vuln)."
    echo
    echo "Compare: ${UPSTREAM_URL:-https://github.com/rustdesk/rustdesk-server}/compare/${base}...${sha}"
    echo
    echo "Trial merge into the branch the workflow ran on (a throwaway local branch, nothing pushed), run by the upstream-watch workflow (${RUN_URL:-no run url}): **${label_state}**."
    echo
    echo "## New upstream commits"
    echo
    if [[ -s "${w}/commits" ]]; then fenced "${w}/commits"; else echo "None listed."; fi
    ((total <= 100)) || echo "(first 100 of ${total})"
    echo
    echo "## New upstream tags"
    echo
    # shellcheck disable=SC2016  # the backticks are Markdown
    if [[ -s "${w}/tags" ]]; then sed 's/^/- `/; s/$/`/' "${w}/tags"; else echo "None."; fi
    echo
    echo "## hbb_common pin (\`${SUBMODULE}\`)"
    echo
    if [[ "${pin_base}" == "${pin_new}" ]]; then
      echo "Upstream did not move it (still \`${pin_base:0:12}\`). Ours: \`${pin_ours:0:12}\`."
    else
      echo "Upstream moved it: \`${pin_base:0:12}\` -> \`${pin_new:0:12}\`. Ours: \`${pin_ours:0:12}\`."
    fi
    echo
    echo "## Merge and tests"
    echo
    case "${state}" in
      conflict)
        echo "The trial merge has conflicts in:"
        echo
        if [[ -s "${w}/conflicts" ]]; then fenced "${w}/conflicts"; else echo "(file list unavailable)"; fi
        echo
        echo "Merge output (tail):"; echo
        fenced "${w}/log" ;;
      tests-failing)
        echo "The merge is clean, but \`ci/test.sh\` failed (exit ${test_exit:-?}). Log tail:"
        echo
        fenced "${w}/log" ;;
      clean)
        echo "The merge is clean and \`ci/test.sh\` passed." ;;
    esac
    echo
    echo "## What to do"
    echo
    echo "Integration is done in the development repository and synced to master through a pull request. This workflow opens no pull request and pushes nothing, by design: the flow stays one-way and a person reviews every upstream change. Review the commits above (those marked \`*\` first), integrate, and the \`UPSTREAM\` file moves to the new commit with that pull request."
  } > "${w}/body"

  ensure_labels
  local url title="${TITLE_PREFIX}${short} — ${label_state}"
  url="$(create_issue "${title}" "${w}/body" "${LABEL}")"
  echo "Opened: ${url}"

  # Close open issues of older upstream commits, pointing to the new one.
  local n
  while read -r n; do
    [[ "${n}" =~ ^[0-9]+$ ]] || continue
    gh_write issue close "${n}" --repo "${GITHUB_REPOSITORY}" --reason 'not planned' \
      --comment "Superseded by a newer upstream master commit: ${url}"
  done < <(jq -r --arg p "${TITLE_PREFIX}" --arg t "${TITLE_PREFIX}${short} " \
    '.[] | select(.state == "OPEN" and (.title | startswith($p)) and (.title | startswith($t) | not)) | .number' <<< "${issues}")
  rm -rf "${w}"
}

report_availability() {
  local d="$1" which sha w
  [[ -s "${d}/missing.txt" ]] || { echo "All pinned sources are available."; return 0; }
  local issues; issues="$(issues_json)"
  while read -r which sha; do
    [[ "${which}" =~ ^(hbb_common|rustdesk-server)$ && "${sha}" =~ ^[0-9a-f]{40}$ ]] || continue
    local title="source availability: ${which} ${sha} no longer available upstream"
    if [[ "$(jq --arg t "${title}" '[.[] | select(.title == $t and .state == "OPEN")] | length' <<< "${issues}")" != 0 ]]; then
      echo "Issue for ${which} ${sha} is open already."; continue
    fi
    w="$(mktemp)"
    {
      echo "The workflow could not fetch \`${sha}\` of **${which}** from its upstream repository any more."
      echo
      echo "Patina is licensed under the AGPL-3.0: the corresponding source of what we ship must stay available. This commit is part of it (\`${which}\` is $([[ "${which}" == hbb_common ]] && echo "the \`${SUBMODULE}\` submodule pin" || echo "the base recorded in \`UPSTREAM\`"))."
      echo
      echo "Maintainer: publish a backup of the commit (for example a mirror repository or a tag in this repository containing it), point \`.gitmodules\` / \`UPSTREAM\` at it if needed, then close this issue. Run: ${RUN_URL:-no run url}"
    } > "${w}"
    ensure_labels
    create_issue "${title}" "${w}" "${LABEL}" source-availability > /dev/null
    rm -f "${w}"
  done < "${d}/missing.txt"
}

cmd_report() {
  local in="${IN:?IN is required}" d
  d="${in}/upstream-watch-trial"
  if [[ -f "${d}/meta.env" ]]; then report_trial "${d}"; else echo "No trial data."; fi
  d="${in}/upstream-watch-availability"
  if [[ -f "${d}/missing.txt" ]]; then report_availability "${d}"; else echo "No availability data."; fi
}

case "${1:-}" in
  check) cmd_check ;;
  trial) cmd_trial ;;
  availability) cmd_availability ;;
  report) cmd_report ;;
  *) echo "usage: $0 check|trial|availability|report" >&2; exit 2 ;;
esac
