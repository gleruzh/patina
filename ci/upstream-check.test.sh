#!/usr/bin/env bash
#
# ci/upstream-check.test.sh: offline tests of the "watch" and "report" parts of ci/upstream-check.sh
# that look at hbb_common, client releases and watched pull requests. Everything upstream is a
# fixture: local git repositories (HBB_REPO_OVERRIDE) and JSON files standing in for the GitHub API
# (API_FIXTURES); report runs with DRY_RUN=1. Needs git and jq, no network, no Docker.
# Run it: ci/upstream-check.test.sh   Exit code 0 = all passed. ci.yml runs it with the lint job.

set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/upstream-check.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# No signing, no hooks, no user config: the fixtures are plain throwaway repositories.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

failures=0
pass() { echo "ok:   $1"; }
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

# expect_in NAME TEXT PATTERN / expect_not_in: fixed-string search in TEXT.
expect_in() { if grep -qF -- "$3" <<< "$2"; then pass "$1"; else fail "$1 (missing: $3)"; fi; }
expect_not_in() { if grep -qF -- "$3" <<< "$2"; then fail "$1 (unexpected: $3)"; else pass "$1"; fi; }

expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got $2, want $3)"; fi; }

# ---- fixture: a fake hbb_common whose main is five commits past the pin
hbb="${tmp}/hbb_common"
git init -q -b main "${hbb}"
mkdir "${hbb}/protos"
echo 'syntax = "proto3";' > "${hbb}/protos/message.proto"
git -C "${hbb}" add protos && git -C "${hbb}" commit -q -m 'initial'
pin="$(git -C "${hbb}" rev-parse HEAD)"
echo a > "${hbb}/a.txt"
git -C "${hbb}" add a.txt && git -C "${hbb}" commit -q -m 'update docs'
echo b > "${hbb}/b.txt"
git -C "${hbb}" add b.txt && git -C "${hbb}" commit -q -m 'fix integer overflow' -m 'CVE-2026-0001'
git -C "${hbb}" rm -q protos/message.proto
mkdir -p "${hbb}/protos/new" && echo 'syntax = "proto3";' > "${hbb}/protos/new/rendezvous.proto"
git -C "${hbb}" add protos && git -C "${hbb}" commit -q -m 'move protos'
git -C "${hbb}" switch -q -c side
echo c > "${hbb}/protos/side.proto"
git -C "${hbb}" add protos && git -C "${hbb}" commit -q -m 'side proto'
git -C "${hbb}" switch -q main
git -C "${hbb}" merge -q --no-ff side -m 'merge side'
head="$(git -C "${hbb}" rev-parse HEAD)"

# ---- fixture: our repository, with the submodule pin and UPSTREAM
repo="${tmp}/ours"
git init -q -b master "${repo}"
printf 'repo=https://github.com/rustdesk/rustdesk-server\ncommit=%s\n' "$(printf '0%.0s' {1..40})" > "${repo}/UPSTREAM"
git -C "${repo}" add UPSTREAM
git -C "${repo}" update-index --add --cacheinfo "160000,${pin},libs/hbb_common"
git -C "${repo}" commit -q -m 'ours'

# ---- fixture: API answers and the watched list
api="${tmp}/api"
mkdir "${api}"
cat > "${api}/releases.json" <<'JSON'
[
  {"tag_name": "1.5.2", "draft": true,  "prerelease": false, "published_at": "2026-11-02T00:00:00Z"},
  {"tag_name": "1.5.1", "draft": false, "prerelease": false, "published_at": "2026-11-01T16:13:27Z"},
  {"tag_name": "1.5.0", "draft": false, "prerelease": false, "published_at": "2026-09-30T16:11:03Z"},
  {"tag_name": "nightly", "draft": false, "prerelease": true, "published_at": "2026-11-02T05:02:29Z"},
  {"tag_name": "1.5.0-rc1", "draft": false, "prerelease": false, "published_at": "2026-09-01T00:00:00Z"},
  {"tag_name": "1.4.9", "draft": false, "prerelease": false, "published_at": "2026-07-06T10:02:30Z"}
]
JSON
echo '{"state": "closed", "merged_at": "2026-11-02T00:00:00Z", "title": "Key exchange v1"}' > "${api}/pr-734.json"
echo '{"state": "open", "merged_at": null, "title": "still open"}' > "${api}/pr-744.json"
echo '{"state": "closed", "merged_at": null, "title": "closed unmerged"}' > "${api}/pr-706.json"
printf '# a comment\n734  # merged\n744\n\n706 # closed\n728' > "${tmp}/watched-prs"

echo '{"state": "closed", "merged_at": "2026-11-02T00:00:00Z", "title": "dep refresh"}' > "${api}/pr-728.json"

# ---- watch
out="${tmp}/out"
in="${tmp}/in"
cd "${repo}"
# run_watch OUTDIR [HBB_REPO] [WATCHED_FILE]: watch with the fixtures; log in OUTDIR.log.
run_watch() {
  env RETRY_SLEEP=0 OUT="$1" HBB_REPO_OVERRIDE="${2:-${hbb}}" API_FIXTURES="${api}" WATCHED_PRS="${3:-${tmp}/watched-prs}" \
    UPSTREAM_FILE=UPSTREAM "${script}" watch > "$1.log" 2>&1
}
# load_in OUTDIR: make OUTDIR the downloaded watch artifact.
load_in() { rm -rf "${in}"; mkdir -p "${in}"; cp -R "$1" "${in}/upstream-watch-extra"; }

run_watch "${out}" || { cat "${out}.log" >&2; fail "watch exits 0"; }

meta="$(cat "${out}/meta.env")"
expect_in "hbb: head" "${meta}" "hbb_head=${head}"
expect_in "hbb: pin from the gitlink" "${meta}" "hbb_pin=${pin}"
expect_in "hbb: five commits" "${meta}" 'hbb_total=5'
expect_in "hbb: one security-looking" "${meta}" 'hbb_flagged=1'
expect_in "hbb: message.proto at the pin" "${meta}" 'hbb_proto_pin=yes'
expect_in "hbb: message.proto gone at main" "${meta}" 'hbb_proto_head=no'
short_of() { git -C "${hbb}" rev-list -1 --grep "$1" main | cut -c1-7; }
commits="$(cat "${out}/hbb-commits.txt")"
expect_in "hbb: plain commit unmarked" "${commits}" '   '"$(short_of 'update docs')"' update docs'
expect_in "hbb: security-looking commit marked *" "${commits}" '*  '"$(short_of 'fix integer')"' fix integer overflow'
expect_in "hbb: merge commit bringing protos/ marked P" "${commits}" ' P '"$(short_of 'merge side')"' merge side'
expect_in "hbb: protos/ commit marked P" "${commits}" ' P '"$(short_of 'move protos')"' move protos'

releases="$(cat "${out}/releases.txt")"
expect_in "client: stable release listed" "${releases}" '1.5.1 2026-11-01T16:13:27Z'
expect_not_in "client: nightly ignored" "${releases}" 'nightly'
expect_not_in "client: draft ignored" "${releases}" '1.5.2'
expect_not_in "client: pre-release tag ignored" "${releases}" 'rc1'

prs="$(cat "${out}/prs.tsv")"
expect_in "prs: merged" "${prs}" $'734\tmerged\t'
expect_in "prs: open" "${prs}" $'744\topen\t'
expect_in "prs: closed without merge" "${prs}" $'706\tclosed\t'
expect_in "watch: all three sections marked done" "${meta}" 'prs_done=1'
expect_in "prs: last line without a newline read" "${prs}" $'728\tmerged\t'

# ---- report
load_in "${out}"

run_report() { # ISSUES_JSON_OR_EMPTY [FORCE]
  local issues="${tmp}/issues.json"
  echo "${1:-[]}" > "${issues}"
  env IN="${in}" DRY_RUN=1 DRY_RUN_ISSUES="${issues}" DRY_RUN_ISSUE_JSON="${ISSUE_JSON:-}" GITHUB_REPOSITORY=owner/repo FORCE="${2:-}" \
    DEFAULT_BRANCH="${DEFAULT_BRANCH_T-master}" GITHUB_REF="${GITHUB_REF_T-refs/heads/master}" UPSTREAM_SHA="${UPSTREAM_SHA_T:-}" API_FIXTURES="${API_FIXTURES_R:-}" \
    UPSTREAM_FILE=UPSTREAM "${script}" report 2>&1
}

r="$(run_report)"
expect_in "report: hbb issue" "${r}" "--title 'upstream: hbb_common main past pin ${pin}'"
expect_in "report: hbb body carries the head marker" "${r}" "hbb-head:${head}"
expect_in "report: hbb body mentions the moved protos" "${r}" 'a bump is not a trivial pin change'
expect_in "report: hbb body shows the P mark" "${r}" 'move protos'
expect_in "report: hbb body lists an unmarked commit" "${r}" "$(short_of 'update docs') update docs"
expect_in "report: newest client release only on a first run" "${r}" "--title 'upstream: rustdesk client 1.5.1'"
expect_not_in "report: no history flood" "${r}" 'upstream: rustdesk client 1.5.0'"'"
expect_in "report: merged PR" "${r}" "--title 'upstream: PR rustdesk-server#734 merged'"
expect_in "report: closed PR" "${r}" "--title 'upstream: PR rustdesk-server#706 closed'"
expect_not_in "report: open PR not reported" "${r}" '#744'
expect_in "report: PR title is in a code block" "${r}" 'Key exchange v1'
expect_in "report: nothing from the trial" "${r}" 'No trial data.'

# Everything already reported: no duplicates.
done_issues="[
  {\"number\": 5, \"state\": \"OPEN\",   \"title\": \"upstream: hbb_common main past pin ${pin}\"},
  {\"number\": 4, \"state\": \"CLOSED\", \"title\": \"upstream: rustdesk client 1.5.1\"},
  {\"number\": 3, \"state\": \"CLOSED\", \"title\": \"upstream: PR rustdesk-server#734 merged\"},
  {\"number\": 9, \"state\": \"OPEN\",   \"title\": \"upstream: PR rustdesk-server#728 merged\"},
  {\"number\": 2, \"state\": \"OPEN\",   \"title\": \"upstream: PR rustdesk-server#706 closed\"}
]"
# The open hbb_common issue already covers this head (the marker is in its text).
# issue_json FILE LOGIN TYPE BOT_TEXT [FOREIGN_TEXT]: the REST shape {user, body, comments: [{user, body}]}
# of an issue whose comment BOT_TEXT is written by LOGIN of TYPE, optionally with a stranger's comment.
issue_json() {
  jq -n --arg login "$2" --arg type "$3" --arg bot "$4" --arg foreign "${5:-}" '{
    user: {login: "github-actions[bot]", type: "Bot"}, body: "plain body",
    comments: ([{user: {login: $login, type: $type}, body: $bot}]
      + (if $foreign == "" then [] else [{user: {login: "stranger", type: "User"}, body: $foreign}] end))}' > "$1"
}
ISSUE_JSON="${tmp}/issue.json"
issue_json "${ISSUE_JSON}" "github-actions[bot]" Bot "$(printf 'x\n<!-- hbb-head:%s -->' "${head}")"
r="$(run_report "${done_issues}")"
expect_not_in "dedupe: no issue created on a second run" "${r}" 'gh issue create'
expect_not_in "dedupe: no comment on a second run" "${r}" 'gh issue comment'
expect_in "dedupe: hbb" "${r}" 'already covers hbb_common'
expect_in "dedupe: client" "${r}" 'No new client release (latest reported: 1.5.1)'

# --force reports the hbb_common head and the PRs again.
r="$(run_report "${done_issues}" true)"
expect_in "force: hbb commented again" "${r}" 'gh issue comment 5'
unset ISSUE_JSON
expect_in "force: PR again" "${r}" "--title 'upstream: PR rustdesk-server#734 merged'"

# Only 1.4.9 reported so far: both newer releases are reported, oldest first.
r="$(run_report '[{"number": 1, "state": "CLOSED", "title": "upstream: rustdesk client 1.4.9"}]')"
expect_in "client: newer than the last reported (1.5.0)" "${r}" "--title 'upstream: rustdesk client 1.5.0'"
expect_in "client: newer than the last reported (1.5.1)" "${r}" "--title 'upstream: rustdesk client 1.5.1'"
expect_not_in "client: already reported one skipped" "${r}" "--title 'upstream: rustdesk client 1.4.9'"

# Main moved since the issue was last updated: one comment with only the commits it does not list,
# no new issue, nothing closed.
bot_state="$(printf '   %s update docs\n<!-- hbb-head:%s -->' "$(short_of 'update docs')" "$(git -C "${hbb}" rev-parse HEAD~3)")"
issue_json "${tmp}/issue.json" "github-actions[bot]" Bot "${bot_state}"
r="$(ISSUE_JSON="${tmp}/issue.json" run_report "[{\"number\": 5, \"state\": \"OPEN\", \"title\": \"upstream: hbb_common main past pin ${pin}\"}]")"
expect_in "moved: comment on the pin issue" "${r}" 'gh issue comment 5'
expect_not_in "moved: no new issue" "${r}" "--title 'upstream: hbb_common"
expect_in "moved: new commit listed" "${r}" 'move protos'
expect_not_in "moved: listed commit not repeated" "${r}" "$(short_of 'update docs') update docs"
# Unmarked commits (two blank mark columns) are parsed too: only "move protos" is listed already, so
# the plain "update docs" and the other new commits must be in the comment.
bot_state="$(printf ' P %s move protos\n<!-- hbb-head:%s -->' "$(short_of 'move protos')" "$(git -C "${hbb}" rev-parse HEAD~3)")"
issue_json "${tmp}/issue.json" "github-actions[bot]" Bot "${bot_state}"
r="$(ISSUE_JSON="${tmp}/issue.json" run_report "[{\"number\": 5, \"state\": \"OPEN\", \"title\": \"upstream: hbb_common main past pin ${pin}\"}]")"
expect_in "unmarked commit listed in the comment" "${r}" "$(short_of 'update docs') update docs"
expect_in "marked commit listed in the comment" "${r}" "$(short_of 'fix integer') fix integer overflow"
expect_not_in "listed commit not repeated (unmarked run)" "${r}" "$(short_of 'move protos') move protos"
# Authorship is login AND type: a user named like the bot, or another bot, is not trusted.
for who in 'github-actions[bot]:User' 'other[bot]:Bot' 'github-actions:Bot'; do
  issue_json "${tmp}/issue.json" "${who%%:*}" "${who##*:}" "<!-- hbb-head:${head} -->"
  r="$(ISSUE_JSON="${tmp}/issue.json" run_report "[{\"number\": 5, \"state\": \"OPEN\", \"title\": \"upstream: hbb_common main past pin ${pin}\"}]")"
  expect_in "untrusted author ${who}: still commented" "${r}" 'gh issue comment 5'
done
# A stranger's comment with the marker and every sha must not suppress the report.
allshas="$(cat "${in}/upstream-watch-extra/hbb-commits.txt")"
issue_json "${tmp}/issue.json" "github-actions[bot]" Bot "$(printf '   %s update docs\n<!-- hbb-head:%s -->' "$(short_of 'update docs')" "$(git -C "${hbb}" rev-parse HEAD~3)")" \
  "$(printf '%s\n<!-- hbb-head:%s -->' "${allshas}" "${head}")"
r="$(ISSUE_JSON="${tmp}/issue.json" run_report "[{\"number\": 5, \"state\": \"OPEN\", \"title\": \"upstream: hbb_common main past pin ${pin}\"}]")"
expect_in "foreign comment: new commits still commented" "${r}" 'gh issue comment 5'
expect_in "foreign comment: new commit listed" "${r}" 'move protos'
# A stranger as the author of the issue body does not count either.
jq '.user = {login: "stranger", type: "User"} | .body = "<!-- hbb-head:'"${head}"' -->"' "${tmp}/issue.json" > "${tmp}/issue2.json"
jq '.comments = []' "${tmp}/issue2.json" > "${tmp}/issue3.json"
r="$(ISSUE_JSON="${tmp}/issue3.json" run_report "[{\"number\": 5, \"state\": \"OPEN\", \"title\": \"upstream: hbb_common main past pin ${pin}\"}]")"
expect_in "foreign body: still commented" "${r}" 'gh issue comment 5'
# A closed issue for the pin is left alone.
r="$(run_report "[{\"number\": 5, \"state\": \"CLOSED\", \"title\": \"upstream: hbb_common main past pin ${pin}\"}]")"
expect_not_in "closed pin issue: no comment" "${r}" 'gh issue comment'
expect_not_in "closed pin issue: no new issue" "${r}" "--title 'upstream: hbb_common"

# A new pin gets a new issue and the open issue of the old pin is closed; server issues stay.
r="$(run_report '[
  {"number": 7, "state": "OPEN", "title": "upstream: hbb_common main past pin 1234567890123456789012345678901234567890"},
  {"number": 8, "state": "OPEN", "title": "upstream: rustdesk-server abcdef0 — clean"}
]')"
expect_in "new pin: new issue" "${r}" "--title 'upstream: hbb_common main past pin ${pin}'"
expect_in "close older: hbb issue 7" "${r}" 'gh issue close 7'
expect_not_in "close older: server issue 8 untouched" "${r}" 'gh issue close 8'

# Hostile data from the watch job: bad sha is refused, nothing is opened.
sed -i.bak 's/^hbb_head=.*/hbb_head=not-a-sha/' "${in}/upstream-watch-extra/meta.env"
r="$(run_report)"
expect_in "untrusted: bad sha refused" "${r}" 'bad sha in hbb data'
expect_not_in "untrusted: no hbb issue" "${r}" 'upstream: hbb_common'

# One section missing its marker: only that section is skipped.
reset_in() { load_in "${out}"; }
reset_in
sed -i.bak '/^client_done=1$/d' "${in}/upstream-watch-extra/meta.env"
r="$(run_report)"
expect_in "markers: client section skipped" "${r}" 'No client release data.'
expect_not_in "markers: no client issue" "${r}" "upstream: rustdesk client"
expect_in "markers: hbb still reported" "${r}" "--title 'upstream: hbb_common"
expect_in "markers: prs still reported" "${r}" "upstream: PR rustdesk-server#734 merged"
reset_in
sed -i.bak '/^hbb_done=1$/d; /^prs_done=1$/d' "${in}/upstream-watch-extra/meta.env"
r="$(run_report)"
expect_in "markers: hbb skipped" "${r}" 'No hbb_common watch data.'
expect_in "markers: prs skipped" "${r}" 'No pull request data.'
expect_in "markers: client reported" "${r}" "--title 'upstream: rustdesk client 1.5.1'"

# An API error fails the job, but the other sources are still collected and marked.
echo '{"message": "API rate limit exceeded"}' > "${api}/pr-744.json"
touch "${api}/pr-744.fail"
if run_watch "${tmp}/o2"; then fail "api error: watch must fail"; else
  pass "api error: watch fails"
  expect_in "api error: named" "$(cat "${tmp}/o2.log")" '::error::could not read pull request #744'
  expect_in "api error: hbb still done" "$(cat "${tmp}/o2/meta.env")" 'hbb_done=1'
  expect_in "api error: client still done" "$(cat "${tmp}/o2/meta.env")" 'client_done=1'
  expect_not_in "api error: prs not marked" "$(cat "${tmp}/o2/meta.env")" 'prs_done'
fi
rm "${api}/pr-744.fail"

# A 200 answer of the wrong shape fails too.
echo '{"message": "oops"}' > "${api}/pr-744.json"
if run_watch "${tmp}/o3"; then fail "bad answer: watch must fail"; else
  pass "bad answer: watch fails"
  expect_in "bad answer: reason" "$(cat "${tmp}/o3.log")" '::error::unexpected answer for pull request #744'
  expect_not_in "bad answer: prs not marked" "$(cat "${tmp}/o3/meta.env")" 'prs_done'
fi
echo '{"state": "open", "merged_at": null, "title": "still open"}' > "${api}/pr-744.json"

# A watched pull request that is gone (404) is a failure that names the line.
printf '734\n999\n' > "${tmp}/watched-404"
if run_watch "${tmp}/o4" "${hbb}" "${tmp}/watched-404"; then fail "404: watch must fail"; else
  pass "404: watch fails"
  expect_in "404: names the line" "$(cat "${tmp}/o4.log")" 'pull request #999 (line 2 of'
fi

# The releases API fails: the job is red, the other sections are collected and reported.
mv "${api}/releases.json" "${api}/releases.json.keep"
echo '{"message": "Server Error"}' > "${api}/releases.json"
touch "${api}/releases.fail"
if run_watch "${tmp}/o5"; then fail "releases error: watch must fail"; else
  pass "releases error: watch fails"
  expect_not_in "releases error: client not marked" "$(cat "${tmp}/o5/meta.env")" 'client_done'
  expect_in "releases error: hbb marked" "$(cat "${tmp}/o5/meta.env")" 'hbb_done=1'
  expect_in "releases error: prs marked" "$(cat "${tmp}/o5/meta.env")" 'prs_done=1'
  load_in "${tmp}/o5"
  r="$(run_report)"
  expect_in "releases error: report skips client" "${r}" 'No client release data.'
  expect_in "releases error: report still opens hbb" "${r}" "--title 'upstream: hbb_common"
  expect_in "releases error: report still opens PR" "${r}" "upstream: PR rustdesk-server#734 merged"
fi
rm "${api}/releases.fail"; mv "${api}/releases.json.keep" "${api}/releases.json"

# new_ours NAME PIN: a repository like ours whose libs/hbb_common is pinned to PIN.
new_ours() {
  git init -q -b master "${tmp}/$1"
  cp "${repo}/UPSTREAM" "${tmp}/$1/UPSTREAM"
  git -C "${tmp}/$1" add UPSTREAM
  git -C "${tmp}/$1" update-index --add --cacheinfo "160000,$2,libs/hbb_common"
  git -C "${tmp}/$1" commit -q -m 'ours'
}

# Our pin is not on main: one deduped issue per pin, none for commits.
nopin="$(printf 'a%.0s' {1..40})"
new_ours ours2 "${nopin}"
cd "${tmp}/ours2"
if run_watch "${tmp}/o6"; then
  expect_in "pin-missing: state" "$(cat "${tmp}/o6/meta.env")" 'hbb_state=pin-missing'
  load_in "${tmp}/o6"
  r="$(run_report)"
  expect_in "pin-missing: issue" "${r}" "--title 'upstream: hbb_common pin ${nopin} not on main'"
  r="$(run_report "[{\"number\": 3, \"state\": \"OPEN\", \"title\": \"upstream: hbb_common pin ${nopin} not on main\"}]")"
  expect_not_in "pin-missing: deduped" "${r}" "--title 'upstream: hbb_common pin"
else
  fail "pin-missing: watch exits 0"
fi

# Nothing past the pin (pin == main): no issue.
new_ours ours3 "${head}"
cd "${tmp}/ours3"
if run_watch "${tmp}/o7"; then
  expect_in "total=0: counted" "$(cat "${tmp}/o7/meta.env")" 'hbb_total=0'
  load_in "${tmp}/o7"
  r="$(run_report)"
  expect_in "total=0: nothing to report" "${r}" 'nothing past our pin'
  expect_not_in "total=0: no hbb issue" "${r}" "--title 'upstream: hbb_common"
else
  fail "total=0: watch exits 0"
fi

# The security hint is the word fix, not prefix / suffix.
sec_repo="${tmp}/sec"
git init -q -b main "${sec_repo}"
git -C "${sec_repo}" commit -q --allow-empty -m 'base'
sec_pin="$(git -C "${sec_repo}" rev-parse HEAD)"
git -C "${sec_repo}" commit -q --allow-empty -m 'add a prefix and a suffix'
git -C "${sec_repo}" commit -q --allow-empty -m 'Fixes a crash'
git -C "${sec_repo}" commit -q --allow-empty -m 'hotfix: x'
new_ours ours4 "${sec_pin}"
cd "${tmp}/ours4"
if run_watch "${tmp}/o8" "${sec_repo}"; then
  expect_in "security hint: fix, fixes, hotfix but not prefix / suffix" "$(cat "${tmp}/o8/meta.env")" 'hbb_flagged=2'
else
  fail "security hint: watch exits 0"
fi
cd "${repo}"

# Two issues of older pins and a missing-pin issue are open when the new pin is reported: both
# older pins' issues and the missing-pin issue are closed.
reset_in
r="$(run_report '[
  {"number": 7, "state": "OPEN", "title": "upstream: hbb_common main past pin 1234567890123456789012345678901234567890"},
  {"number": 10, "state": "OPEN", "title": "upstream: hbb_common main past pin 7654321098765432109876543210987654321098"},
  {"number": 11, "state": "OPEN", "title": "upstream: hbb_common pin bbbb not on main"}
]')"
expect_in "close two: issue 7" "${r}" 'gh issue close 7 '
expect_in "close two: issue 10" "${r}" 'gh issue close 10 '
expect_in "close two: the stale missing-pin issue is closed too" "${r}" 'gh issue close 11 '

# A nonexistent hbb_common repository: the hbb source fails and is not marked; the others are.
if run_watch "${tmp}/o9" "${tmp}/does-not-exist"; then fail "no hbb repo: watch must fail"; else
  pass "no hbb repo: watch fails"
  expect_not_in "no hbb repo: hbb not marked" "$(cat "${tmp}/o9/meta.env")" 'hbb_done'
  expect_in "no hbb repo: client marked" "$(cat "${tmp}/o9/meta.env")" 'client_done=1'
fi

# A releases answer that is not a list: the client source fails and is not marked.
mv "${api}/releases.json" "${api}/releases.json.keep"
echo '{"message": "not a list"}' > "${api}/releases.json"
if run_watch "${tmp}/o10"; then fail "non-array releases: watch must fail"; else
  pass "non-array releases: watch fails"
  expect_not_in "non-array releases: client not marked" "$(cat "${tmp}/o10/meta.env")" 'client_done'
  expect_in "non-array releases: reason" "$(cat "${tmp}/o10.log")" 'not a list'
fi
mv "${api}/releases.json.keep" "${api}/releases.json"

# Retries: fails once then succeeds = 2 calls; a 404 = 1 call; a persistent failure = 3 calls.
printf '734\n' > "${tmp}/watched-one"
calls_of() { grep -cx "$1" "${api}/calls" || true; }
touch "${api}/pr-734.fail-once"; : > "${api}/calls"
if run_watch "${tmp}/o11" "${hbb}" "${tmp}/watched-one"; then
  pass "retry: succeeds on the second try"
  expect_eq "retry: two calls" "$(calls_of pr-734)" 2
else fail "retry: watch exits 0"; fi
printf '999\n' > "${tmp}/watched-gone"; : > "${api}/calls"
run_watch "${tmp}/o12" "${hbb}" "${tmp}/watched-gone" || true
expect_eq "retry: a 404 is tried once" "$(calls_of pr-999)" 1
touch "${api}/pr-734.fail"; : > "${api}/calls"
run_watch "${tmp}/o13" "${hbb}" "${tmp}/watched-one" || true
expect_eq "retry: a persistent failure is tried 3 times" "$(calls_of pr-734)" 3
rm "${api}/pr-734.fail"

# A failed gh issue create in one section does not stop the later ones; the job fails at the end.
fakebin="${tmp}/fakebin"
mkdir "${fakebin}"
cat > "${fakebin}/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_GH_LOG}"
if [[ "$1" == api ]]; then
  # The REST path of issue_text: the issue, and the comments (several pages are several JSON arrays).
  case "${*: -1}" in
    */comments\?per_page=100) if [[ "${FAKE_GH_API_FAIL:-}" == comments ]]; then echo "boom" >&2; exit 1; fi; cat "${FAKE_GH_API_DIR}/comments.json" ;;
    *) cat "${FAKE_GH_API_DIR}/issue.json" ;;
  esac
  exit 0
fi
case "$1 $2" in
  "issue list") echo "${FAKE_GH_ISSUES:-[]}" ;;
  "issue close") if [[ -n "${FAKE_CLOSE_FAIL:-}" ]]; then echo "boom" >&2; exit 1; fi ;;
  "issue create") case "$*" in *hbb_common*) echo "boom" >&2; exit 1 ;; *) echo "https://example.invalid/issues/1" ;; esac ;;
esac
SH
chmod +x "${fakebin}/gh"
reset_in
: > "${tmp}/gh.log"
if r="$(env PATH="${fakebin}:${PATH}" FAKE_GH_LOG="${tmp}/gh.log" IN="${in}" GITHUB_REPOSITORY=owner/repo UPSTREAM_FILE=UPSTREAM "${script}" report 2>&1)"; then
  fail "failed create: report must fail"
else
  pass "failed create: report fails"
  expect_in "failed create: section named" "${r}" '::error::report section hbb_common failed'
  expect_in "failed create: client still opened" "$(cat "${tmp}/gh.log")" 'rustdesk client 1.5.1'
  expect_in "failed create: PR still opened" "$(cat "${tmp}/gh.log")" 'rustdesk-server#734 merged'
fi

# Closing the issue of an older pin does not depend on opening a new issue: with the pin bumped to
# exactly main (nothing past it) the old issue is closed; a failed close is retried on the next run.
new_ours ours5 "${head}"
cd "${tmp}/ours5"
run_watch "${tmp}/o14" || fail "bump to main: watch exits 0"
load_in "${tmp}/o14"
old_issue='[{"number": 21, "state": "OPEN", "title": "upstream: hbb_common main past pin 1234567890123456789012345678901234567890"}]'
r="$(run_report "${old_issue}")"
expect_in "bump to main: old pin issue closed" "${r}" 'gh issue close 21 '
expect_not_in "bump to main: no hbb issue opened" "${r}" "--title 'upstream: hbb_common"
: > "${tmp}/gh.log"
if env PATH="${fakebin}:${PATH}" DEFAULT_BRANCH=master GITHUB_REF=refs/heads/master FAKE_GH_LOG="${tmp}/gh.log" FAKE_GH_ISSUES="${old_issue}" FAKE_CLOSE_FAIL=1 IN="${in}" GITHUB_REPOSITORY=owner/repo UPSTREAM_FILE=UPSTREAM "${script}" report > "${tmp}/close.log" 2>&1; then
  fail "failed close: report must fail"
else
  pass "failed close: report fails"
fi
if env PATH="${fakebin}:${PATH}" DEFAULT_BRANCH=master GITHUB_REF=refs/heads/master FAKE_GH_LOG="${tmp}/gh.log" FAKE_GH_ISSUES="${old_issue}" IN="${in}" GITHUB_REPOSITORY=owner/repo UPSTREAM_FILE=UPSTREAM "${script}" report > "${tmp}/close2.log" 2>&1; then
  pass "failed close: the next run succeeds"
  expect_eq "failed close: close tried on both runs" "$(grep -c 'issue close 21' "${tmp}/gh.log")" 2
else
  fail "failed close: next run exits 0"
fi
# The missing-pin case closes older pins' issues too, and stale "pin not on main" issues of other pins.
cd "${tmp}/ours2"
load_in "${tmp}/o6"
r="$(run_report "${old_issue}")"
expect_in "pin-missing: older pin issue closed" "${r}" 'gh issue close 21 '
stale_pins="[
  {\"number\": 31, \"state\": \"OPEN\", \"title\": \"upstream: hbb_common pin $(printf 'b%.0s' {1..40}) not on main\"},
  {\"number\": 32, \"state\": \"OPEN\", \"title\": \"upstream: hbb_common pin ${nopin} not on main\"},
  {\"number\": 33, \"state\": \"OPEN\", \"title\": \"upstream: hbb_common pin ${head} not on main\"}]"
r="$(run_report "${stale_pins}")"
expect_in "pin-missing: stale missing-pin issue of another pin closed" "${r}" 'gh issue close 31 '
expect_not_in "pin-missing: the current pin's issue kept" "${r}" 'gh issue close 32'
# The pin is fine now (bump to main): the stale missing-pin issue is closed as well.
cd "${tmp}/ours5"
load_in "${tmp}/o14"
r="$(run_report "${stale_pins}")"
expect_in "pin moved: both stale missing-pin issues closed" "${r}" 'gh issue close 31 '
expect_in "pin moved: the other one too" "${r}" 'gh issue close 32 '
expect_in "pin reachable again: its own not-on-main issue closed" "${r}" 'gh issue close 33 '

# The REST path of issue_text, with the real gh calls replaced by a fake: comments on two pages are
# merged, and an API failure fails the section without a comment being posted.
cd "${repo}"
load_in "${out}"
apid="${tmp}/apidir"; mkdir "${apid}"
echo '{"user": {"login": "github-actions[bot]", "type": "Bot"}, "body": "plain"}' > "${apid}/issue.json"
pin_issue="[{\"number\": 5, \"state\": \"OPEN\", \"title\": \"upstream: hbb_common main past pin ${pin}\"}]"
rest_report() { # prints the output; the gh log is ${tmp}/gh.log
  : > "${tmp}/gh.log"
  env PATH="${fakebin}:${PATH}" DEFAULT_BRANCH=master GITHUB_REF=refs/heads/master FAKE_GH_LOG="${tmp}/gh.log" FAKE_GH_ISSUES="${pin_issue}" \
    FAKE_GH_API_DIR="${apid}" FAKE_GH_API_FAIL="${1:-}" IN="${in}" GITHUB_REPOSITORY=owner/repo UPSTREAM_FILE=UPSTREAM "${script}" report 2>&1
}
# Page 1: a stranger; page 2: the bot's state for the current head.
jq -n --arg m "<!-- hbb-head:${head} -->" '[[{user: {login: "stranger", type: "User"}, body: "hi"}], [{user: {login: "github-actions[bot]", type: "Bot"}, body: $m}]]' \
  | jq -c '.[]' > "${apid}/comments.json"
if r="$(rest_report)"; then
  expect_in "rest: bot state on page 2 honoured" "${r}" 'already covers hbb_common'
  expect_not_in "rest: no comment posted" "$(cat "${tmp}/gh.log")" 'issue comment'
  expect_in "rest: comments asked with per_page=100" "$(cat "${tmp}/gh.log")" 'comments?per_page=100'
else fail "rest: report exits 0 ($r)"; fi
# One page, only an older marker: the new commits are commented.
jq -n '[{user: {login: "github-actions[bot]", type: "Bot"}, body: "<!-- hbb-head:0000000000000000000000000000000000000000 -->"}]' > "${apid}/comments.json"
if r="$(rest_report)"; then
  expect_in "rest: one page, new head commented" "$(cat "${tmp}/gh.log")" 'issue comment 5'
else fail "rest: one page report exits 0 ($r)"; fi
# The comments call fails: the section fails and nothing is posted.
if r="$(rest_report comments)"; then fail "rest failure: report must fail"; else
  pass "rest failure: report fails"
  expect_in "rest failure: section named" "${r}" '::error::report section hbb_common failed'
  expect_not_in "rest failure: no comment posted" "$(cat "${tmp}/gh.log")" 'issue comment'
fi

# Availability: the completion marker, not a possibly dropped empty missing.txt, decides.
avail="${tmp}/avail"; rm -rf "${avail}"; mkdir -p "${avail}/upstream-watch-availability"
printf 'hbb_common %s\n' "${pin}" > "${avail}/upstream-watch-availability/missing.txt"
rm -rf "${in}"; mkdir -p "${in}"; cp -R "${avail}/upstream-watch-availability" "${in}/"
r="$(run_report)"
expect_in "availability: no marker, no report" "${r}" 'No availability data.'
echo 'availability_done=1' > "${in}/upstream-watch-availability/meta.env"
r="$(run_report)"
expect_in "availability: marked data reported" "${r}" "--title 'source availability: hbb_common ${pin} no longer available upstream'"
: > "${in}/upstream-watch-availability/missing.txt"
r="$(run_report)"
expect_in "availability: nothing missing" "${r}" 'All pinned sources are available.'
rm "${in}/upstream-watch-availability/missing.txt"
r="$(run_report)"
expect_in "availability: a dropped empty missing.txt still counts" "${r}" 'All pinned sources are available.'

# The server issue of an older master commit is closed on every run from the check's newest sha,
# with no trial data at all (after day 1 "check" skips the trial).
rm -rf "${in}"; mkdir -p "${in}"
nsha="$(printf 'c%.0s' {1..40})"
server_issues="[
  {\"number\": 30, \"state\": \"OPEN\", \"createdAt\": \"2026-11-03T00:00:00Z\", \"url\": \"https://example.invalid/30\", \"title\": \"upstream: rustdesk-server ${nsha:0:7} — clean\"},
  {\"number\": 29, \"state\": \"OPEN\", \"createdAt\": \"2026-11-01T00:00:00Z\", \"url\": \"https://example.invalid/29\", \"title\": \"upstream: rustdesk-server 1111111 — clean\"},
  {\"number\": 27, \"state\": \"OPEN\", \"createdAt\": \"2026-10-01T00:00:00Z\", \"url\": \"https://example.invalid/27\", \"title\": \"upstream: rustdesk-server 0999999 — clean\"},
  {\"number\": 28, \"state\": \"OPEN\", \"url\": \"https://example.invalid/28\", \"title\": \"upstream: rustdesk-server 0888888 — clean\"}]"
r="$(UPSTREAM_SHA_T="${nsha}" run_report "${server_issues}")"
expect_in "server close: older issue closed without trial data" "${r}" 'gh issue close 29 '
expect_in "server close: oldest issue closed too" "${r}" 'gh issue close 27 '
expect_not_in "server close: an issue without createdAt stays open" "${r}" 'gh issue close 28'
expect_in "server close: points at the newest issue" "${r}" 'https://example.invalid/30'
expect_not_in "server close: current issue kept" "${r}" 'gh issue close 30'
r="$(UPSTREAM_SHA_T="not-a-sha" run_report "${server_issues}")"
expect_not_in "server close: bad sha ignored" "${r}" 'gh issue close'
r="$(UPSTREAM_SHA_T="$(printf 'e%.0s' {1..40})" run_report "${server_issues}")"
expect_not_in "server close: nothing closed without an issue for the sha" "${r}" 'gh issue close'

# Not the default branch (a manual dispatch elsewhere): no older issue is closed, hbb or server.
cd "${tmp}/ours5"
load_in "${tmp}/o14"
r="$(GITHUB_REF_T=refs/heads/feature UPSTREAM_SHA_T="${nsha}" run_report "${old_issue%]}, ${server_issues#[}")"
expect_not_in "other branch: nothing closed" "${r}" 'gh issue close'
expect_in "other branch: said so" "${r}" 'Not a run of the default branch'
# An older sha handed in (the issue of 1111111 exists, but was created before 30): the newer issue stays.
r="$(UPSTREAM_SHA_T="$(printf '1%.0s' {1..7})$(printf '0%.0s' {1..33})" run_report "${server_issues}")"
expect_not_in "ancestry: newer issue not closed by an older sha" "${r}" 'gh issue close 30'
expect_in "ancestry: an issue older than the sha's issue is closed" "${r}" 'gh issue close 27 '
expect_not_in "ancestry: the sha's own issue is kept" "${r}" 'gh issue close 29'
expect_not_in "ancestry: no createdAt, kept" "${r}" 'gh issue close 28'
# No DEFAULT_BRANCH from the workflow: it is looked up (fixture "repo"), or nothing is closed.
dfx="${tmp}/dfx"; mkdir "${dfx}"
r="$(DEFAULT_BRANCH_T='' API_FIXTURES_R="${dfx}" UPSTREAM_SHA_T="${nsha}" run_report "${old_issue%]}, ${server_issues#[}")"
expect_in "default branch unknown: warned" "${r}" '::warning::default branch unknown; not closing older issues'
expect_in "default branch unknown: the lookup failed for its reason" "${r}" 'Could not look up the default branch: {"message": "Not Found"'
if grep -qx repo "${dfx}/calls"; then pass "default branch unknown: the lookup was attempted"; else fail "default branch unknown: the lookup was attempted"; fi
expect_not_in "default branch unknown: nothing closed" "${r}" 'gh issue close'
expect_not_in "default branch unknown: not the other message" "${r}" 'Not a run of the default branch'
echo '{"default_branch": "master"}' > "${dfx}/repo.json"
r="$(DEFAULT_BRANCH_T='' API_FIXTURES_R="${dfx}" UPSTREAM_SHA_T="${nsha}" run_report "${old_issue%]}, ${server_issues#[}")"
expect_in "default branch looked up: hbb close" "${r}" 'gh issue close 21 '
expect_in "default branch looked up: server close" "${r}" 'gh issue close 29 '
echo '{"default_branch": "trunk"}' > "${dfx}/repo.json"
r="$(DEFAULT_BRANCH_T='' API_FIXTURES_R="${dfx}" UPSTREAM_SHA_T="${nsha}" run_report "${old_issue%]}, ${server_issues#[}")"
expect_in "default branch looked up: other branch" "${r}" 'Not a run of the default branch'
expect_not_in "default branch looked up: other branch closes nothing" "${r}" 'gh issue close'
r="$(UPSTREAM_SHA_T="${nsha}" run_report "${old_issue%]}, ${server_issues#[}")"
expect_in "default branch: hbb close" "${r}" 'gh issue close 21 '
expect_in "default branch: server close" "${r}" 'gh issue close 29 '
cd "${repo}"

if ((failures > 0)); then echo "upstream-check tests: ${failures} failed" >&2; exit 1; fi
echo "upstream-check tests: all passed"
