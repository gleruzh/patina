#!/usr/bin/env bash
# Helper of .github/workflows/upstream-watch.yml. Subcommands:
#   check         newest upstream master commit, and whether it still needs a report (job "check")
#   trial         trial merge of that commit and ci/test.sh (job "trial"; runs upstream code)
#   availability  are the pinned source commits still fetchable upstream (job "availability")
#   watch         hbb_common main past our pin, new client releases, watched upstream pull requests
#                 (job "watch"; reads git data and the GitHub API only, runs no upstream code)
#   report        open / close issues from the data of the jobs above (job "report")
#
# Environment (all optional unless noted):
#   UPSTREAM_FILE  file with repo= and commit= lines (default UPSTREAM)
#   OUT            output directory of trial / availability (default ${RUNNER_TEMP:-/tmp}/upstream-out)
#   IN             directory with the downloaded artifacts for report
#   TARGET_SHA     upstream master commit to work on (trial; set by "check")
#   UPSTREAM_SHA   newest upstream master commit as found by "check" (report: closes older server issues)
#   DEFAULT_BRANCH default branch of the repository; older issues are closed only on a run of this
#                  branch (GITHUB_REF is refs/heads/<it>), so a dispatch from another branch closes nothing
#   FORCE=true     report a commit again although an issue for it exists
#   DRY_RUN=1      report: print what would be sent to the GitHub API, send nothing
#   DRY_RUN_ISSUES JSON file standing in for `gh issue list` in a dry run (default [])
#   DRY_RUN_ISSUE_JSON  file standing in for `gh issue view --json author,body,comments` in a dry run (default empty)
#   RETRY_SLEEP    seconds to wait between the 3 tries of an API call in watch (default 3)
#   WATCHED_PRS    file with the upstream rustdesk-server pull requests to follow (default ci/watched-prs)
#   UPSTREAM_REPO_OVERRIDE  test only: use this URL/path instead of the repo= line
#   HBB_REPO_OVERRIDE       test only: use this URL/path instead of rustdesk/hbb_common
#   API_FIXTURES            test only: directory with releases.json and pr-<number>.json standing in
#                           for the GitHub API in watch
set -euo pipefail

UPSTREAM_FILE="${UPSTREAM_FILE:-UPSTREAM}"
OUT="${OUT:-${RUNNER_TEMP:-/tmp}/upstream-out}"
HBB_URL="${HBB_REPO_OVERRIDE:-https://github.com/rustdesk/hbb_common}"
HBB_BRANCH='main'
CLIENT_REPO='rustdesk/rustdesk'
WATCHED_PRS="${WATCHED_PRS:-ci/watched-prs}"
SUBMODULE='libs/hbb_common'
TITLE_PREFIX='upstream: rustdesk-server '
# The titles of the other issues must not start with TITLE_PREFIX: report_trial closes open issues
# that do when a newer master commit is reported.
HBB_PREFIX='upstream: hbb_common '
# One issue per pin; it is updated with comments while main moves. The pin sha follows.
HBB_MAIN_PREFIX='upstream: hbb_common main past pin '
CLIENT_PREFIX='upstream: rustdesk client '
PR_PREFIX='upstream: PR rustdesk-server#'
LABEL='upstream'

# looks_security: stdin mentions security, a CVE, a vulnerability or a fix (the word fix, fixes, fixed,
# fixing, hotfix or bugfix, so "prefix" and "suffix" do not count). Only a hint for a person; the
# commit is not judged further.
looks_security() {
  grep -qiE 'security|cve|vuln|(^|[^[:alnum:]_])(hot|bug)?fix(e[sd]|ing)?($|[^[:alnum:]_])'
}

die() { echo "::error::$*" >&2; exit 1; }

# set_output NAME VALUE
set_output() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/stdout}"; }

read_upstream() {
  [[ -f "${UPSTREAM_FILE}" ]] || die "${UPSTREAM_FILE} not found"
  UP_REPO="$(sed -n 's/^repo=//p' "${UPSTREAM_FILE}" | head -n 1)"
  UP_COMMIT="$(sed -n 's/^commit=//p' "${UPSTREAM_FILE}" | head -n 1)"
  [[ "${UP_REPO}" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "bad repo= line in ${UPSTREAM_FILE}"
  [[ "${UP_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "bad commit= line in ${UPSTREAM_FILE}"
  UP_SLUG="${UP_REPO#https://github.com/}"
  UP_REPO="${UPSTREAM_REPO_OVERRIDE:-${UP_REPO}}"
}

pin_of() { git ls-tree "$1" "${SUBMODULE}" | awk '$2 == "commit" {print $3}'; }

fetch_upstream() {
  git fetch --quiet --no-tags --no-recurse-submodules "${UP_REPO}" \
    '+refs/heads/master:refs/upstream/master' '+refs/tags/*:refs/upstream-tags/*'
}

# ---------------------------------------------------------------- check
# All issues with the label, open and closed, filtered locally by the callers (exact title or
# prefix). A plain list, not a search: the search index lags behind and fails open, a miss there
# would open a duplicate. gh pages through the API up to the limit.
issues_json() {
  local all
  if [[ -n "${DRY_RUN:-}" ]]; then
    if [[ -n "${DRY_RUN_ISSUES:-}" ]]; then all="$(cat "${DRY_RUN_ISSUES}")"; else all='[]'; fi
  else
    all="$(gh issue list --repo "${GITHUB_REPOSITORY}" --label "${LABEL}" --state all --limit 1000 \
      --json number,title,state,url,createdAt)" || return 1
  fi
  if [[ "$(jq length <<< "${all}")" -ge 1000 ]]; then
    echo "::warning::1000 issues with the label ${LABEL}: older ones may be missing from the duplicate check" >&2
  fi
  printf '%s\n' "${all}"
}

# issues_by_prefix PREFIX: the issues whose title starts with PREFIX.
issues_by_prefix() {
  issues_json | jq --arg p "$1" '[.[] | select(.title | startswith($p))]'
}

# prefix_reported ISSUES_JSON PREFIX: an issue (open or closed) whose title starts with PREFIX exists
# and FORCE is not set.
prefix_reported() {
  [[ "$(jq --arg t "$2" '[.[] | select(.title | startswith($t))] | length' <<< "$1")" != 0 && "${FORCE:-}" != true ]]
}

cmd_check() {
  read_upstream
  fetch_upstream
  local sha count short run=false issues
  sha="$(git rev-parse --verify refs/upstream/master)"
  short="${sha:0:7}"
  count="$(git rev-list --count "${UP_COMMIT}..${sha}")"
  echo "UPSTREAM pins ${UP_COMMIT:0:7}; upstream master is ${short}, ${count} new commit(s)."
  if [[ "${count}" == 0 ]]; then
    echo "Nothing new upstream."
  elif issues="$(issues_json)" || die "could not list the issues"; prefix_reported "${issues}" "${TITLE_PREFIX}${short} "; then
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
    if looks_security <<< "${subject}"$'\n'"${body}"; then
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
  # Written last. An empty missing.txt may not survive the artifact upload, so report relies on this.
  echo 'availability_done=1' > "${OUT}/meta.env"
}

# ---------------------------------------------------------------- watch
# Collects what moved upstream besides rustdesk-server master. Only git objects and API answers are
# read; nothing fetched here is built or run. The report job decides what is new.

# api_get KEY PATH: the API answer for PATH (a file of API_FIXTURES in tests).
# A fixture without a file is a 404; KEY.fail next to a fixture makes it an error (body and exit 1),
# KEY.fail-once only the first call. Every call is logged to the file "calls" in API_FIXTURES.
api_get() {
  if [[ -z "${API_FIXTURES:-}" ]]; then gh api "$2" < /dev/null; return; fi
  echo "$1" >> "${API_FIXTURES}/calls"
  if [[ -f "${API_FIXTURES}/$1.json" ]]; then
    cat "${API_FIXTURES}/$1.json"
    if [[ -f "${API_FIXTURES}/$1.fail-once" ]]; then rm -f "${API_FIXTURES}/$1.fail-once"; return 1; fi
    [[ ! -f "${API_FIXTURES}/$1.fail" ]]
  else
    echo '{"message": "Not Found", "status": "404"}'; return 1
  fi
}

# api_try KEY PATH: api_get, up to 3 tries with a short sleep. A 404 is not retried. The answer goes
# to stdout, stderr to the file ERRF.
api_try() {
  local i out
  for i in 1 2 3; do
    if out="$(api_get "$1" "$2" 2> "${ERRF}")"; then printf '%s\n' "${out}"; return 0; fi
    if grep -qE 'Not Found|HTTP 404|"status": ?"404"' <<< "${out}$(cat "${ERRF}")"; then break; fi
    ((i == 3)) || sleep "$((i * ${RETRY_SLEEP:-3}))"
  done
  printf '%s\n' "${out}"; return 1
}

# hbb_common main beyond our submodule pin. Flags per commit: first column "*" when the message
# looks security-looking (the same test as for server commits), second column "P" when the commit
# touches protos/ (the wire protocol).
watch_hbb() {
  local pin head total=0 flagged=0 rev subject body flag proto state=ok revs
  local proto_pin=no proto_head=no
  pin="$(pin_of HEAD)"
  [[ "${pin}" =~ ^[0-9a-f]{40}$ ]] || die "no ${SUBMODULE} pin in HEAD"
  git fetch --quiet --no-tags --no-recurse-submodules "${HBB_URL}" \
    "+refs/heads/${HBB_BRANCH}:refs/upstream-hbb/${HBB_BRANCH}" || return 1
  head="$(git rev-parse --verify "refs/upstream-hbb/${HBB_BRANCH}")" || return 1
  : > "${OUT}/hbb-commits.txt"
  if ! git cat-file -e "${pin}^{commit}" 2> /dev/null; then
    state='pin-missing'
  else
    git cat-file -e "${pin}:protos/message.proto" 2> /dev/null && proto_pin=yes
    git cat-file -e "${head}:protos/message.proto" 2> /dev/null && proto_head=yes
    revs="$(git rev-list "${pin}..${head}")" || return 1
    while read -r rev; do
      [[ -n "${rev}" ]] || continue
      total=$((total + 1))
      subject="$(git log -1 --format=%s "${rev}")" || return 1
      body="$(git log -1 --format=%b "${rev}")" || return 1
      flag='*'
      looks_security <<< "${subject}"$'\n'"${body}" && flagged=$((flagged + 1)) || flag=' '
      proto=' '
      # Against the first parent, so a merge commit that brings in protos/ changes is marked too.
      if [[ -n "$(git diff-tree --no-commit-id --name-only -r "${rev}^1" "${rev}" -- protos/ 2> /dev/null \
        || git diff-tree --no-commit-id --name-only -r --root "${rev}" -- protos/)" ]]; then proto=P; fi
      if ((total <= 100)); then printf '%s%s %s %s\n' "${flag}" "${proto}" "${rev:0:7}" "${subject}" >> "${OUT}/hbb-commits.txt"; fi
    done <<< "${revs}"
  fi
  {
    echo "hbb_state=${state}"
    echo "hbb_head=${head}"
    echo "hbb_pin=${pin}"
    echo "hbb_total=${total}"
    echo "hbb_flagged=${flagged}"
    echo "hbb_proto_pin=${proto_pin}"
    echo "hbb_proto_head=${proto_head}"
  } >> "${OUT}/meta.env"
  echo "hbb_common ${HBB_BRANCH} is ${head:0:7}; our pin ${pin:0:7} is ${total} commit(s) behind (${state})."
}

# Stable client releases, newest first: "TAG PUBLISHED_AT". Drafts, pre-releases and the rolling
# nightly tag are left out; only X.Y.Z tags count.
watch_client() {
  local answer
  answer="$(api_try releases "repos/${CLIENT_REPO}/releases?per_page=30")" \
    || { echo "::error::could not read the ${CLIENT_REPO} releases: $(head -c 300 <<< "${answer}$(cat "${ERRF}")")"; return 1; }
  jq -e 'type == "array"' > /dev/null <<< "${answer}" \
    || { echo "::error::unexpected answer for the ${CLIENT_REPO} releases (not a list)"; return 1; }
  jq -r '.[] | select(.draft == false and .prerelease == false)
        | select(.tag_name | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
        | "\(.tag_name) \(.published_at)"' <<< "${answer}" > "${OUT}/releases.txt" || return 1
  echo "Client: $(wc -l < "${OUT}/releases.txt" | tr -d ' ') stable release(s) listed."
}

# The watched pull requests: "NUMBER STATE TITLE" with STATE open, merged or closed (tab separated).
watch_prs() {
  : > "${OUT}/prs.tsv"
  [[ -f "${WATCHED_PRS}" ]] || { echo "No ${WATCHED_PRS}; no pull requests to watch."; return 0; }
  local n line answer failed=0 lineno=0
  while read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    n="${line%%#*}"; n="${n//[[:space:]]/}"
    [[ -n "${n}" ]] || continue
    [[ "${n}" =~ ^[0-9]{1,6}$ ]] || die "bad line ${lineno} in ${WATCHED_PRS}: ${line}"
    # Any failure fails the job (a pull request that is gone included: the list needs a person), so
    # an unreadable one is never mistaken for "still open".
    if ! answer="$(api_try "pr-${n}" "repos/${UP_SLUG}/pulls/${n}")"; then
      echo "::error::could not read pull request #${n} (line ${lineno} of ${WATCHED_PRS}): $(head -c 300 <<< "${answer}$(cat "${ERRF}")")"
      failed=$((failed + 1)); continue
    fi
    if ! jq -e '.state | type == "string"' > /dev/null <<< "${answer}"; then
      echo "::error::unexpected answer for pull request #${n} (line ${lineno} of ${WATCHED_PRS})"
      failed=$((failed + 1)); continue
    fi
    jq -r --arg n "${n}" '[$n, (if .merged_at != null then "merged" elif .state == "closed" then "closed" else "open" end), .title] | @tsv' \
      <<< "${answer}" >> "${OUT}/prs.tsv"
  done < "${WATCHED_PRS}"
  ((failed == 0)) || die "${failed} watched pull request(s) could not be read"
  echo "Pull requests: $(wc -l < "${OUT}/prs.tsv" | tr -d ' ') of $(grep -cE '^[[:space:]]*[0-9]' "${WATCHED_PRS}") read."
}

# collect NAME: run watch_NAME on its own, so one failing source does not hide the others, and mark
# it done (NAME_done=1 in meta.env) only when it finished. report reads only the marked sections.
# Called with set -e off (see cmd_watch); the subshell turns it on for the collector itself.
collect() {
  local rc
  ( set -e; "watch_$1" )
  rc=$?
  if ((rc == 0)); then echo "$1_done=1" >> "${OUT}/meta.env"; else echo "::error::watch $1 failed"; fi
  return "${rc}"
}

cmd_watch() {
  read_upstream
  mkdir -p "${OUT}"
  : > "${OUT}/meta.env"
  ERRF="$(mktemp)"
  local -a names=(hbb client prs)
  local failed=0 name rc
  # Not in a || or if context: that would switch set -e off inside the collectors.
  for name in "${names[@]}"; do
    set +e
    collect "${name}"
    rc=$?
    set -e
    ((rc == 0)) || failed=$((failed + 1))
  done
  rm -f "${ERRF}"
  ((failed == 0)) || die "${failed} of ${#names[@]} watch sources failed; the others are reported anyway"
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
  if [[ -n "${DRY_RUN:-}" ]]; then
    echo "DRY-RUN: gh $*" >&2
    # A comment body is printed too, like the body of an issue.
    local prev="" a
    for a in "$@"; do
      if [[ "${prev}" == --body-file ]]; then cat "${a}" >&2; fi
      prev="${a}"
    done
  else
    gh "$@" < /dev/null
  fi
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
    gh issue create --repo "${GITHUB_REPOSITORY}" --title "${title}" --body-file "${bodyfile}" "${args[@]}" < /dev/null
  fi
}

# title_reported ISSUES_JSON TITLE: an issue (open or closed) with exactly this title exists and
# FORCE is not set.
title_reported() {
  [[ "$(jq --arg t "$2" '[.[] | select(.title == $t)] | length' <<< "$1")" != 0 && "${FORCE:-}" != true ]]
}

# close_older ISSUES_JSON PREFIX KEEP_PREFIX MESSAGE: close the open issues whose title starts with
# PREFIX but not with KEEP_PREFIX (the issue just opened), with MESSAGE as the comment.
close_older() {
  local n nums
  nums="$(jq -r --arg p "$2" --arg k "$3" \
    '.[] | select(.state == "OPEN" and (.title | startswith($p)) and (.title | startswith($k) | not)) | .number' <<< "$1")"
  while read -r n; do
    [[ "${n}" =~ ^[0-9]+$ ]] || continue
    gh_write issue close "${n}" --repo "${GITHUB_REPOSITORY:-owner/repo}" --reason 'not planned' --comment "$4"
  done <<< "${nums}"
}

# close_older_if_default ISSUES_JSON PREFIX KEEP_PREFIX MESSAGE: close_older, but only on a run of the
# default branch. A manual dispatch on another branch (whose UPSTREAM / pin differ) must not close the
# default branch's issues; the open issues stay for the next run there.
close_older_if_default() {
  local def="${DEFAULT_BRANCH:-}"
  if [[ -z "${def}" && "${DEFAULT_BRANCH_LOOKED_UP:-}" != 1 ]]; then def="$(lookup_default_branch)"; fi
  if [[ -z "${def}" ]]; then
    # Said once per section (report_hbb looks it up once and sets DEFAULT_BRANCH_WARNED).
    if [[ "${DEFAULT_BRANCH_WARNED:-}" != 1 ]]; then
      echo "::warning::default branch unknown; not closing older issues"
      DEFAULT_BRANCH_WARNED=1
    fi
  elif [[ "${GITHUB_REF:-}" == "refs/heads/${def}" ]]; then
    close_older "$@"
  else
    echo "Not a run of the default branch; older issues are left open."
  fi
}

# lookup_default_branch: the default branch from the API, for when the workflow did not pass it.
# Prints nothing when it cannot be found.
lookup_default_branch() {
  local answer
  ERRF="$(mktemp)"
  answer="$(api_try repo "repos/${GITHUB_REPOSITORY:-}")" \
    || { echo "Could not look up the default branch: $(head -c 200 <<< "${answer}$(cat "${ERRF}")")" >&2; rm -f "${ERRF}"; return 0; }
  rm -f "${ERRF}"
  jq -r '.default_branch // empty' <<< "${answer}" 2> /dev/null || true
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
  if prefix_reported "${issues}" "${TITLE_PREFIX}${short} "; then
    # "check" sets run_trial=false for a commit with an issue, so this is reached only by a rerun in
    # between; cmd_report closes the older issues on every run (close_superseded_server).
    echo "An issue for ${short} exists already; nothing new to open."
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
    echo "Compare: ${UPSTREAM_URL:-https://github.com/${UP_SLUG}}/compare/${base}...${sha}"
    echo
    echo "Trial merge into the branch the workflow ran on (a throwaway local branch, nothing pushed), run by the upstream-watch workflow (${RUN_URL:-no run url}): **${label_state}**."
    echo
    echo "## New upstream commits"
    echo
    if [[ -s "${w}/commits" ]]; then fenced "${w}/commits"; else echo "None listed."; fi
    ((total <= 100)) || echo "(newest 100 of ${total})"
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
  close_older_if_default "${issues}" "${TITLE_PREFIX}" "${TITLE_PREFIX}${short} " "Superseded by a newer upstream master commit: ${url}"
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

# issue_text NUMBER: the text of an issue and its comments that the workflow wrote itself. Anyone can
# comment on a public repository, so a marker or a commit sha in a stranger's comment must never
# decide anything. Read through the REST API, where the author is a user object, and keep only text
# whose user is type "Bot" with the login "github-actions[bot]" (what GITHUB_TOKEN writes as).
# DRY_RUN_ISSUE_JSON (an object like {user, body, comments: [{user, body}]}) stands in for it in tests.
issue_text() {
  local json='' issue comments
  if [[ -n "${DRY_RUN:-}" ]]; then
    if [[ -n "${DRY_RUN_ISSUE_JSON:-}" ]]; then json="$(cat "${DRY_RUN_ISSUE_JSON}")"; fi
  else
    issue="$(gh api "repos/${GITHUB_REPOSITORY}/issues/$1" < /dev/null)" || return 1
    comments="$(gh api --paginate "repos/${GITHUB_REPOSITORY}/issues/$1/comments?per_page=100" < /dev/null | jq -s 'add // []')" || return 1
    json="$(jq --argjson c "${comments}" '{user, body, comments: $c}' <<< "${issue}")" || return 1
  fi
  [[ -n "${json}" ]] || return 0
  jq -r 'def bot: (.user.type // "") == "Bot" and (.user.login // "") == "github-actions[bot]";
    ([select(bot) | .body // ""] + [.comments[] | select(bot) | .body // ""]) | join("\n")' <<< "${json}"
}

# One issue per hbb_common pin (title HBB_MAIN_PREFIX + pin sha), kept current with comments.
report_hbb() {
  local d="$1" state head pin total flagged proto_pin proto_head short h
  state="$(meta "${d}" hbb_state)"; head="$(meta "${d}" hbb_head)"; pin="$(meta "${d}" hbb_pin)"
  total="$(meta "${d}" hbb_total)"; flagged="$(meta "${d}" hbb_flagged)"
  proto_pin="$(meta "${d}" hbb_proto_pin)"; proto_head="$(meta "${d}" hbb_proto_head)"
  [[ "${state}" =~ ^(ok|pin-missing)$ ]] || { echo "::warning::bad hbb state in watch data; skipping"; return 0; }
  for h in "${head}" "${pin}"; do [[ "${h}" =~ ^[0-9a-f]{40}$ ]] || { echo "::warning::bad sha in hbb data; skipping"; return 0; }; done
  [[ "${total}" =~ ^[0-9]{1,7}$ && "${flagged}" =~ ^[0-9]{1,7}$ ]] || { echo "::warning::bad counts in hbb data; skipping"; return 0; }
  [[ "${proto_pin}" =~ ^(yes|no)$ && "${proto_head}" =~ ^(yes|no)$ ]] || { echo "::warning::bad flags in hbb data; skipping"; return 0; }
  short="${head:0:7}"
  local issues w title="${HBB_MAIN_PREFIX}${pin}"
  issues="$(issues_by_prefix "${HBB_PREFIX}")"
  # Look the default branch up once for the closes below (this runs in its own subshell).
  if [[ -z "${DEFAULT_BRANCH:-}" ]]; then DEFAULT_BRANCH="$(lookup_default_branch)"; DEFAULT_BRANCH_LOOKED_UP=1; fi
  # Issues of older pins are closed on every run, whatever else happens below (a failed close is
  # retried the next day; a bump to exactly main, with nothing past the pin, still closes the old one).
  close_older_if_default "${issues}" "${HBB_MAIN_PREFIX}" "${title}" "The ${SUBMODULE} pin moved to \`${pin:0:12}\`; this issue was about an older pin. Anything past the new pin is tracked in the issue titled \`${title}\`."
  # The same for issues about a pin that was not on main, once the pin is another one.
  close_older_if_default "${issues}" "${HBB_PREFIX}pin " "${HBB_PREFIX}pin ${pin} " "The ${SUBMODULE} pin moved to \`${pin:0:12}\`; this issue was about an older pin."
  if [[ "${state}" == ok ]]; then
    # The pin is reachable from main again: a "not on main" issue for this very pin is obsolete.
    close_older_if_default "${issues}" "${HBB_PREFIX}pin ${pin} " "${HBB_PREFIX}pin none" "The ${SUBMODULE} pin \`${pin:0:12}\` is on \`${HBB_BRANCH}\` again."
  fi
  if [[ "${state}" == pin-missing ]]; then
    # Not on main: a rewritten history, or a pin from another branch. One issue per pin.
    local ptitle="${HBB_PREFIX}pin ${pin} not on ${HBB_BRANCH}"
    if title_reported "${issues}" "${ptitle}"; then echo "Issue for the missing pin ${pin:0:12} exists already."; return 0; fi
    w="$(mktemp)"
    {
      echo "Our \`${SUBMODULE}\` pin \`${pin}\` is not in the history of upstream hbb_common \`${HBB_BRANCH}\` (now \`${head:0:12}\`), so the commits past it cannot be listed."
      echo
      echo "Likely upstream rewrote its history, or the pin comes from another branch. Check that the pin is still fetchable (the weekly source-availability check opens its own issue when it is not) and choose a new base by hand. Run: ${RUN_URL:-no run url}"
    } > "${w}"
    ensure_labels
    create_issue "${ptitle}" "${w}" "${LABEL}" > /dev/null
    rm -f "${w}"
    return 0
  fi
  if ((total == 0)); then echo "hbb_common ${HBB_BRANCH} has nothing past our pin."; return 0; fi

  # One issue per pin. While main moves, an open issue gets a comment with the commits it does not
  # list yet; a closed one is left alone. A new pin (after a bump) gets a new issue (the issues of
  # older pins were closed above).
  local mark="<!-- hbb-head:${head} -->" existing num istate text
  existing="$(jq -r --arg t "${title}" '[.[] | select(.title == $t)] | first // empty | "\(.number) \(.state)"' <<< "${issues}")"
  w="$(mktemp -d)"
  sanitize 100 12000 < "${d}/hbb-commits.txt" > "${w}/commits"
  if [[ -n "${existing}" ]]; then
    read -r num istate <<< "${existing}"
    if [[ "${istate}" != OPEN || ! "${num}" =~ ^[0-9]+$ ]]; then
      echo "The hbb_common issue for this pin is closed; nothing to do."; rm -rf "${w}"; return 0
    fi
    text="$(issue_text "${num}")"
    if [[ "${FORCE:-}" != true ]] && grep -qF -- "hbb-head:${head}" <<< "${text}"; then
      echo "Issue #${num} already covers hbb_common ${short}; nothing to do."; rm -rf "${w}"; return 0
    fi
    # Only the commits the issue and its comments do not mention yet.
    : > "${w}/new"
    local line sha7
    while IFS= read -r line; do
      # Fixed columns, as written by watch_hbb: security mark, proto mark, space, 7-hex sha, space.
      sha7="${line:3:7}"
      [[ "${sha7}" =~ ^[0-9a-f]{7}$ ]] || continue
      if [[ "${FORCE:-}" == true ]] || ! grep -qF -- " ${sha7} " <<< "${text}"; then echo "${line}" >> "${w}/new"; fi
    done < "${w}/commits"
    {
      echo "hbb_common \`${HBB_BRANCH}\` moved to \`${head:0:12}\`: ${total} commit(s) past the pin, ${flagged} marked \`*\` (security-looking)."
      echo
      if [[ -s "${w}/new" ]]; then
        echo "Commits not listed above yet (\`*\` = security-looking, \`P\` = touches protos/):"; echo
        fenced "${w}/new"
      else
        echo "No commit beyond those already listed (the list is cut at 100)."
      fi
      echo
      echo "Compare: ${HBB_COMPARE_URL:-https://github.com/rustdesk/hbb_common}/compare/${pin}...${head}"
      echo "${mark}"
    } > "${w}/comment"
    gh_write issue comment "${num}" --repo "${GITHUB_REPOSITORY:-owner/repo}" --body-file "${w}/comment"
    echo "Commented on #${num}."
    rm -rf "${w}"
    return 0
  fi

  {
    echo "Upstream hbb_common \`${HBB_BRANCH}\` is ${total} commit(s) past our \`${SUBMODULE}\` pin: \`${pin:0:12}\` -> \`${head:0:12}\`. ${flagged} marked \`*\` because the message mentions security / CVE / fix / vuln. Commits marked \`P\` touch \`protos/\` (the wire protocol)."
    echo
    echo "Compare: ${HBB_COMPARE_URL:-https://github.com/rustdesk/hbb_common}/compare/${pin}...${head}"
    echo
    echo "## New hbb_common commits (\`*\` = security-looking, \`P\` = touches protos/)"
    echo
    if [[ -s "${w}/commits" ]]; then fenced "${w}/commits"; else echo "None listed."; fi
    ((total <= 100)) || echo "(newest 100 of ${total})"
    echo
    echo "## Layout"
    echo
    if [[ "${proto_pin}" == yes && "${proto_head}" == no ]]; then
      echo "\`protos/message.proto\` exists at our pin but not at \`${HBB_BRANCH}\`: upstream moved or removed it, so a bump is not a trivial pin change and needs a port of Patina's changes. This workflow only reports; it never tries to build the new hbb_common."
    else
      echo "\`protos/message.proto\` is present at our pin: ${proto_pin}, at \`${HBB_BRANCH}\`: ${proto_head}. This workflow only reports; it never tries to build the new hbb_common."
    fi
    echo
    echo "## What to do"
    echo
    echo "Review the commits above (those marked \`*\` or \`P\` first). New upstream commits are added to this issue as comments until the pin moves. A bump is done in the development repository and synced through a pull request; this workflow pushes nothing. Run: ${RUN_URL:-no run url}"
    echo
    echo "${mark}"
  } > "${w}/body"

  ensure_labels
  local url
  url="$(create_issue "${title}" "${w}/body" "${LABEL}")"
  echo "Opened: ${url}"
  rm -rf "${w}"
}

# One issue per client release newer than the newest one an issue exists for (open or closed). With
# no earlier issue only the newest release is reported, so the first run does not list history.
report_client() {
  local d="$1" issues last="" tag published w url t sorted
  local -a fresh=()
  issues="$(issues_by_prefix "${CLIENT_PREFIX}")"
  last="$(jq -r --arg p "${CLIENT_PREFIX}" '.[].title[($p | length):] | split(" ")[0]' <<< "${issues}" \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)"
  sorted="$(sort -V -r "${d}/releases.txt")"
  while read -r tag published; do
    [[ "${tag}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "${published}" =~ ^[0-9T:Z-]{1,30}$ ]] || continue
    if [[ -n "${last}" ]]; then
      [[ "${tag}" != "${last}" && "$(printf '%s\n%s\n' "${tag}" "${last}" | sort -V | tail -n 1)" == "${tag}" ]] || continue
    fi
    if title_reported "${issues}" "${CLIENT_PREFIX}${tag}"; then continue; fi
    fresh+=("${tag} ${published}")
  done <<< "${sorted}"
  if [[ -z "${last}" && ${#fresh[@]} -gt 1 ]]; then fresh=("${fresh[0]}"); fi
  if ((${#fresh[@]} == 0)); then echo "No new client release (latest reported: ${last:-none})."; return 0; fi
  ensure_labels
  # Oldest first, so the issue numbers follow the release order.
  sorted="$(printf '%s\n' "${fresh[@]}" | sort -V)"
  while read -r t published; do
    w="$(mktemp)"
    {
      echo "RustDesk client **${t}** was released (${published})."
      echo
      echo "Release notes: https://github.com/${CLIENT_REPO}/releases/tag/${t}"
      echo
      echo "The client drives protocol changes the server has to follow (1.5.0, for example, introduced key exchange v1 and WebRTC fields). Read the notes and the hbb_common changes since the previous release, and decide whether hbbs / hbbr / the WebSocket registration need a change. Run: ${RUN_URL:-no run url}"
    } > "${w}"
    url="$(create_issue "${CLIENT_PREFIX}${t}" "${w}" "${LABEL}")"
    echo "Opened: ${url}"
    rm -f "${w}"
  done <<< "${sorted}"
}

# One issue per watched pull request and final state (merged / closed); open ones are not reported.
report_prs() {
  local d="$1" issues n state title w url t
  issues="$(issues_by_prefix "${PR_PREFIX}")"
  while IFS=$'\t' read -r n state title; do
    [[ "${n}" =~ ^[0-9]{1,6}$ && "${state}" =~ ^(open|merged|closed)$ ]] || continue
    [[ "${state}" != open ]] || continue
    t="${PR_PREFIX}${n} ${state}"
    if title_reported "${issues}" "${t}"; then
      echo "Issue for pull request #${n} ${state} exists already."; continue
    fi
    w="$(mktemp -d)"
    printf '%s\n' "${title}" | sanitize 1 300 > "${w}/title"
    {
      echo "Upstream rustdesk-server pull request #${n} is now **${state}**: ${UPSTREAM_URL:-https://github.com/${UP_SLUG}}/pull/${n}"
      echo
      echo "Title (as written upstream):"
      echo
      fenced "${w}/title"
      echo
      echo "It is on the watched list (\`${WATCHED_PRS}\`) because it matters for Patina. Decide what the new state means for us (take the change, drop our workaround, or stop watching it and remove the line). Run: ${RUN_URL:-no run url}"
    } > "${w}/body"
    ensure_labels
    url="$(create_issue "${t}" "${w}/body" "${LABEL}")"
    echo "Opened: ${url}"
    rm -rf "${w}"
  done < "${d}/prs.tsv"
}

# guarded NAME COMMAND...: run one report section with set -e on, count a failure and go on, so a
# failed API call in one section does not skip the others. cmd_report fails at the end.
guarded() {
  local rc
  set +e
  ( set -e; "${@:2}" )
  rc=$?
  set -e
  if ((rc != 0)); then echo "::error::report section $1 failed"; REPORT_FAILED=$((REPORT_FAILED + 1)); fi
  return 0
}

# close_superseded_server: close the open issues of older upstream master commits whenever an issue
# for the newest commit (UPSTREAM_SHA, from the job "check") exists, even on a day when "check" found
# nothing to trial. So a close that failed on the day the issue was opened is retried, and an issue
# someone reopened is closed again.
close_superseded_server() {
  local sha="${UPSTREAM_SHA:-}" issues cur older
  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || { echo "No upstream sha given; not closing superseded server issues."; return 0; }
  issues="$(issues_json)"
  cur="$(jq -r --arg t "${TITLE_PREFIX}${sha:0:7} " '[.[] | select(.title | startswith($t))] | first | .url // empty' <<< "${issues}")"
  [[ -n "${cur}" ]] || { echo "No issue for upstream ${sha:0:7} yet; nothing to supersede."; return 0; }
  # The report job has no clone of upstream, so "older" cannot be judged by commit ancestry. An issue
  # is closed only when it was created before the issue of UPSTREAM_SHA (createdAt), which also keeps a
  # newer issue open when the sha handed in is an older one. An issue without a createdAt stays open.
  older="$(jq --arg p "${TITLE_PREFIX}" --arg t "${TITLE_PREFIX}${sha:0:7} " '
    (first(.[] | select(.title | startswith($t))) | .createdAt // null) as $c
    | [.[] | select((.title | startswith($p)) and $c != null and .createdAt != null and .createdAt < $c)]' <<< "${issues}")"
  close_older_if_default "${older}" "${TITLE_PREFIX}" "${TITLE_PREFIX}${sha:0:7} " "Superseded by a newer upstream master commit: ${cur}"
}

cmd_report() {
  local in="${IN:?IN is required}" d
  REPORT_FAILED=0
  read_upstream
  d="${in}/upstream-watch-trial"
  if [[ -f "${d}/meta.env" ]]; then guarded trial report_trial "${d}"; else echo "No trial data."; fi
  guarded superseded close_superseded_server
  d="${in}/upstream-watch-availability"
  if [[ -f "${d}/meta.env" && "$(meta "${d}" availability_done)" == 1 ]]; then guarded availability report_availability "${d}"; else echo "No availability data."; fi
  d="${in}/upstream-watch-extra"
  # Each source is reported only when its own collector finished.
  if [[ -f "${d}/meta.env" ]]; then
    if [[ "$(meta "${d}" hbb_done)" == 1 ]]; then guarded hbb_common report_hbb "${d}"; else echo "No hbb_common watch data."; fi
    if [[ "$(meta "${d}" client_done)" == 1 ]]; then guarded client report_client "${d}"; else echo "No client release data."; fi
    if [[ "$(meta "${d}" prs_done)" == 1 ]]; then guarded prs report_prs "${d}"; else echo "No pull request data."; fi
  else
    echo "No watch data."
  fi
  ((REPORT_FAILED == 0)) || die "${REPORT_FAILED} report section(s) failed"
}

case "${1:-}" in
  check) cmd_check ;;
  trial) cmd_trial ;;
  availability) cmd_availability ;;
  watch) cmd_watch ;;
  report) cmd_report ;;
  *) echo "usage: $0 check|trial|availability|watch|report" >&2; exit 2 ;;
esac
