# CI and publishing

Two workflows build, test and publish the image; a third (`upstream-watch.yml`, documented with the
upstream sync) keeps the fork current. The same files work in any fork unchanged: the image is
published as `ghcr.io/<repository owner, lowercase>/patina`. The only secrets are the optional Docker
Hub ones ([Enabling Docker Hub](#enabling-docker-hub)); everything else uses each job's own
`GITHUB_TOKEN`.

| Workflow | Runs on | What it does |
|---|---|---|
| [`ci.yml`](../.github/workflows/ci.yml) | every pull request, weekly (Mondays), manual | `ci/lint.sh`; `ci/test.sh` (`cargo test --locked`) and an image build + start of `hbbs`/`hbbr`, on a native amd64 and a native arm64 runner (no QEMU); a gitleaks scan of the pull request's commits; a Trivy scan of the built image. The check to require is **CI result**. |
| [`publish.yml`](../.github/workflows/publish.yml) | on request only: a pushed tag `vX.Y.Z`, or manual "Run workflow" (master or a tag only) | Builds each architecture natively, pushes it to GHCR by digest, smoke-tests the pushed digest (`hbbs --help`, `hbbr --help`, and both start and stay up), merges the two into one manifest list (`linux/amd64`, `linux/arm64` only), tags it, signs it with cosign and attests its provenance. On a tag it also creates the GitHub Release. When the Docker Hub secrets are set, it then copies the same digest to Docker Hub with the same tags, signs it there and replaces the Docker Hub description with [`docs/dockerhub.md`](dockerhub.md). |

## Scripts

- `ci/test.sh`: the one entry point for tests, used by CI and `upstream-watch.yml`. Runs
  `cargo test --locked` in the builder image named by `ARG RUST_IMAGE=` in the Dockerfile, with the
  repository mounted read-only and copied to a scratch directory in the container. Exit code = test
  result. Run it locally the same way.
- `ci/lint.sh`: actionlint (with shellcheck on the `run:` blocks), shellcheck for `ci/*.sh`, hadolint
  for the Dockerfile, every `uses:` pinned to a full commit SHA with a `# vX.Y.Z` comment, and
  `VERSION` is `X.Y.Z`. Linters run from `PATH` if installed, else as the pinned containers named in
  the script.
- `ci/upstream-check.test.sh`: offline tests of the hbb_common, client-release and pull-request
  parts of `ci/upstream-check.sh` (fixture git repositories and JSON files instead of the network).
  Needs `git` and `jq`; `ci.yml` runs it in the lint job.

## Upstream watch

`upstream-watch.yml` runs daily and only reports: it opens issues labelled `upstream` and never
opens a pull request or pushes. Its logic is `ci/upstream-check.sh` (`DRY_RUN=1 ci/upstream-check.sh
report` prints instead of calling the issues API). One issue is opened per finding; a run looks for
an existing issue by its title, so a daily run never opens a duplicate (`force` on a manual run
reports again).

| Source | Reported when | Issue title |
|---|---|---|
| rustdesk-server `master` | commits past the `UPSTREAM` commit; also a trial merge and `ci/test.sh` | `upstream: rustdesk-server <sha> — <state>` |
| hbb_common `main` | commits past the `libs/hbb_common` pin; `*` marks a security-looking message, `P` a commit that touches `protos/` | `upstream: hbb_common main past pin <pin sha>` |
| RustDesk client releases | a stable `X.Y.Z` release newer than the newest one with an issue (`nightly`, drafts and pre-releases ignored; with no earlier issue only the newest release) | `upstream: rustdesk client <tag>` |
| watched upstream pull requests | a pull request listed in `ci/watched-prs` is merged or closed | `upstream: PR rustdesk-server#<number> <merged\|closed>` |

Notes:

- The hbb_common branch is `main`, not `master`. Upstream deleted `protos/message.proto` and moved
  modules after our pin, so a bump is not a plain pin change; the issue says so and the workflow
  never tries to build the new hbb_common. There is one issue per pin, not per upstream commit:
  while `main` moves, the open issue gets a comment with only the commits it does not list yet
  (each comment carries a hidden `hbb-head` marker, so a rerun adds nothing), and a closed issue is
  left alone. Only text written by the Actions bot is read back: the REST author must be of type
  `Bot` with the login `github-actions[bot]`, so a marker or commit sha in a stranger's comment
  cannot suppress a report. This relies on the comments being written with `GITHUB_TOKEN`; if the
  workflow is switched to a personal access token or an App token, its comments are no longer
  recognised and the watcher would comment again on every run. After a bump the new pin gets a new
  issue (none when nothing is past it) and the issues of
  older pins are closed on every run, so a close that failed is retried the next day. The same
  holds for the issues of older rustdesk-server master commits: the `report` job gets the newest
  commit from `check` and, whenever an issue for it exists, closes the open issues of older commits,
  with or without a trial that day. So an issue that someone reopens is closed again on the next run.
  Older issues are closed only on a run of the default branch: a manual "Run workflow" on another
  branch reports as usual but closes nothing, so dispatch the watcher on the default branch.
  Lists are cut to the newest 100 commits; if more than 100 land between two
  runs, the older ones are not listed in the comment (the compare link has them).
- Which server issue is "older" is judged by the issue's creation time, not by commit ancestry: the
  report job has no clone of upstream. Only issues created before the issue of the newest commit are
  closed, so a newer issue stays open when an older sha is handed in. The default branch comes from
  the workflow (`github.event.repository.default_branch`), else from the API; when neither is
  known the run warns ("default branch unknown") and closes nothing. `ci/lint.sh` checks that the
  workflow still passes `UPSTREAM_SHA` and `DEFAULT_BRANCH` and that `check` exposes `sha`. A final
  step of `report` fails when `trial`, `availability` or `watch` succeeded but their result was not
  downloaded; `availability` writes a completion marker (`meta.env`) because an empty `missing.txt`
  may not survive the artifact upload.
- The client drives protocol changes the server must follow (1.5.0 brought key exchange v1 and
  WebRTC fields), so a new release is a prompt to read its notes, not a failure.
- `ci/watched-prs` is a plain file: one pull request number per line, `#` starts a comment. Remove a
  line when it is dealt with.
- Failures are loud: each API call is tried 3 times. A watched pull request that cannot be read, a
  404 (deleted or renumbered) included, fails the `watch` job and the log names the line in
  `ci/watched-prs`; so does a failing releases call. The three sources are collected independently,
  so one failure does not hide the others: each finished source writes `hbb_done=1`, `client_done=1`
  or `prs_done=1`, `report` handles only the sources with their marker, and the job turns red at the
  end. `report` runs when `watch` failed too (and when `check` failed), uses what was marked, and
  a missing artifact is tolerated. Each result is downloaded by name into `in/<artifact name>/`
  (not with `pattern:`: a single match is unpacked straight into `in/`, which hid the data from
  `report` when `trial` was skipped). A failed download is retried once, after its directory is
  removed (it can leave partial files) and a short pause. The step "Remove the results that did not
  download" runs before `report` and removes the directory of a download whose retry failed too, so
  `report` reads only intact data and one lost artifact does not hide the other sources. The step
  "Check that the results arrived" runs after `report` and fails the job when a job that succeeded
  has no result. A failing section of `report` (for example `gh issue create`) does not skip the
  later ones; the job fails at the end.
- A hbb_common pin that is not in the history of upstream `main` (a rewritten history, or a pin from
  another branch) opens one issue per pin, `upstream: hbb_common pin <sha> not on main`; no commits
  are listed then; the issue is closed when the pin moves. The weekly `availability` job separately
  covers a pin that cannot be fetched.
- Duplicate checks read the plain list of `upstream` issues (open and closed, up to 1000) and match
  titles locally; a search is not used, because its index lags and a miss would open a duplicate.
  At 1000 issues the run warns that older ones may be missing.
- Deliberate limits: client releases are reported only when newer than the highest tag already
  reported, so a late back-port on an older line is ignored, and `force` does not report clients
  again. The first run on a repository can open several issues at once (the hbb_common head, the
  newest client release, every watched pull request already merged or closed). The security mark is a
  hint only: it matches `security`, `cve`, `vuln` and the words `fix`, `fixes`, `fixed`.
- The `watch` job only reads git objects and API answers of public repositories (`contents: read`).
  Upstream code is merged and run only in the job `trial`, as before; the job `report` still holds
  the only write permission and treats everything from the other jobs as data.

## Trust boundaries

- `ci.yml` triggers on `pull_request`, never `pull_request_target`: code from a fork runs with a
  read-only token and no secrets. Its jobs hold `contents: read`; only the scheduled `security-tab`
  job holds `security-events: write`, and it runs no code from the repository.
- `publish.yml` never runs for a pull request. A manual run from another branch fails in the first
  job; a tag must equal `v` + `VERSION` and be a commit of `master`. Write permissions are per job:
  `packages: write` (build, merge), `id-token: write` and `attestations: write` (merge only),
  `contents: write` (the release job only). The Docker Hub job holds `packages: read` and
  `id-token: write`; the Docker Hub secrets are visible only to it, to the description job and, as a
  boolean "are both set", to `prepare`. The token goes only into `with:` of the login and description
  actions, never into a `run:` script or a step's `env:` (`ci/lint.sh` checks this).
- Every action is pinned to a commit SHA and every tool image to a digest; the workflows have
  `permissions: {}` at the top. Dependabot bumps the action SHAs and the Dockerfile base images.
  The tool images in `ci/lint.sh` and `ci.yml` (actionlint, shellcheck, hadolint, Trivy, gitleaks)
  are bumped by hand: `docker buildx imagetools inspect <image>:<tag>`, replace tag and digest.
- Images are pushed by digest first and get tags only after the smoke test passed on both
  architectures.

## Tags and versioning

Patina has its own semver in `VERSION`; the package version in `Cargo.toml` stays upstream's.
`Cargo.toml`, `Cargo.lock` and `src/relay_server.rs` carry Patina changes, see
[PATCHES.md](../PATCHES.md). The upstream base is visible in the image labels
`io.patina.upstream.repo` and `io.patina.upstream.commit` (from the `UPSTREAM` file), and in every
release's notes ("based on rustdesk-server `<commit>`, hbb_common `<sha>`").

The development repository is the maintainers' private working repository; its changes reach
`master` only through a reviewed sync pull request. The three files above come from it, and edits
made directly to them on this repository's `master` are overwritten by the next sync (forks are
unaffected). Propose changes as pull requests here; the maintainers carry them into the
development repository.

| Event | Tags |
|---|---|
| "Run workflow" on `master` (manual only; merges publish nothing) | `edge`, `sha-<short>` |
| tag `vX.Y.Z` | `X.Y.Z`, `X.Y`, `latest`, `sha-<short>` |

Standard OCI labels are set too: title `patina`, source, revision, version, licenses `AGPL-3.0-only`.
The manifest list also carries BuildKit's SBOM and provenance attestations (shown as
`unknown/unknown` entries); the platforms are exactly `linux/amd64` and `linux/arm64`.

Verify a pulled image:

```shell
gh attestation verify oci://ghcr.io/<owner>/patina@sha256:<digest> --repo <owner>/patina
cosign verify ghcr.io/<owner>/patina@sha256:<digest> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/<owner>/patina/\.github/workflows/publish\.yml@refs/(heads/master|tags/v.*)$'
```

## Cutting a release

1. Open a pull request that changes `VERSION` (for example `0.1.0` to `0.2.0`); merge it once
   **CI result** is green. The merge publishes nothing by itself.
2. Tag that commit on `master` and push the tag (signed tags are preferred):
   `git tag -s v0.2.0 && git push origin v0.2.0`.
3. `publish.yml` fails if the tag differs from `VERSION` or is not on `master`. Otherwise it
   publishes `0.2.0`, `0.2`, `latest` and `sha-<short>` and creates the GitHub Release.

## Enabling Docker Hub

Optional; without the secrets the run logs "Docker Hub skipped" and publishes to GHCR only.

1. Create the repository on Docker Hub (for example `<account>/patina`), or let the first push
   create it.
2. Create a personal access token (Docker Hub > Account settings > Personal access tokens) with
   scope **Read, Write, Delete** (the description update needs Delete).
3. Add the repository secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`. If the Docker Hub
   repository is not `<DOCKERHUB_USERNAME>/patina`, add the variable `DOCKERHUB_IMAGE` (for example
   `myorg/patina`, without `docker.io/`).
4. Run a publish (a tag, or "Run workflow" on `master`).

What happens: the `dockerhub` job, after the image is merged, tagged and signed in GHCR, runs
`docker buildx imagetools create` from `ghcr.io/.../patina@<digest>` to
`docker.io/<repository>:<tag>` for every tag of that run. This copies the manifest list as it is, so
Docker Hub has the identical digest (checked tag by tag), and the job signs and verifies that
reference with cosign. Then the `dockerhub-description` job replaces the Docker Hub page with
`docs/dockerhub.md`: a short page (Docker Hub cuts a description at 25,000 bytes, and the action
truncates without an error; the short description is limited to 100 characters). Links in it are
relative to the repository root and the action completes them. Keep it in sync with `README.md`
by hand. The description is updated by every publish and by nothing else: there is no push trigger,
so a change to `docs/dockerhub.md` reaches Docker Hub with the next publish.

| Name | Kind | Meaning |
|---|---|---|
| `DOCKERHUB_USERNAME` | secret | Docker Hub account that pushes the image and edits its description |
| `DOCKERHUB_TOKEN` | secret | Access token of that account, scope Read, Write, Delete |
| `DOCKERHUB_IMAGE` | variable, optional | Repository on Docker Hub, default `<DOCKERHUB_USERNAME>/patina` |

## Required repository settings

- Settings > Actions > General > Workflow permissions: **Read repository contents and packages
  permissions** (read-only default token). Do not allow Actions to create pull requests unless
  `upstream-watch.yml` needs it.
- Branch protection (or a ruleset) on `master`: require a pull request, require the status check
  **CI result**, require signed commits, block force pushes and deletion. Consider a tag ruleset for
  `v*` restricting who can create tags.
- Packages: after the first publish, make the `patina` GHCR package **public** and link it to the
  repository (the `org.opencontainers.image.source` annotation does this).
- Code scanning (Security tab) is free for public repositories; the weekly Trivy upload needs nothing
  else.

## No scheduled rebuild

There is intentionally no scheduled rebuild workflow. The runtime image is distroless (no package
manager, no shell), so an unchanged tree does not pick up OS fixes by rebuilding. Dependabot bumps
the pinned base-image digests in the Dockerfile; merging that pull request changes the Dockerfile,
which triggers `publish.yml`. The weekly Trivy scan only reports.
