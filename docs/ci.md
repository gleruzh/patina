# CI and publishing

Two workflows build, test and publish the image; a third (`upstream-watch.yml`, documented with the
upstream sync) keeps the fork current. The same files work in any fork unchanged: the image is
published as `ghcr.io/<repository owner, lowercase>/patina`. No secret is used anywhere except each
job's own `GITHUB_TOKEN`.

| Workflow | Runs on | What it does |
|---|---|---|
| [`ci.yml`](../.github/workflows/ci.yml) | every pull request, weekly (Mondays), manual | `ci/lint.sh`; `ci/test.sh` (`cargo test --locked`) and an image build + start of `hbbs`/`hbbr`, on a native amd64 and a native arm64 runner (no QEMU); a gitleaks scan of the pull request's commits; a Trivy scan of the built image. The check to require is **CI result**. |
| [`publish.yml`](../.github/workflows/publish.yml) | push to `master` touching `src/**`, `libs/**`, `Cargo.*`, `build.rs`, `Dockerfile`, `.dockerignore` or `VERSION`; tags `vX.Y.Z`; manual (master or a tag only) | Builds each architecture natively, pushes it to GHCR by digest, smoke-tests the pushed digest (`hbbs --help`, `hbbr --help`, and both start and stay up), merges the two into one manifest list (`linux/amd64`, `linux/arm64` only), tags it, signs it with cosign and attests its provenance. On a tag it also creates the GitHub Release. |

## Scripts

- `ci/test.sh`: the one entry point for tests, used by CI and `upstream-watch.yml`. Runs
  `cargo test --locked` in the builder image named by `ARG RUST_IMAGE=` in the Dockerfile, with the
  repository mounted read-only and copied to a scratch directory in the container. Exit code = test
  result. Run it locally the same way.
- `ci/lint.sh`: actionlint (with shellcheck on the `run:` blocks), shellcheck for `ci/*.sh`, hadolint
  for the Dockerfile, every `uses:` pinned to a full commit SHA with a `# vX.Y.Z` comment, and
  `VERSION` is `X.Y.Z`. Linters run from `PATH` if installed, else as the pinned containers named in
  the script.

## Trust boundaries

- `ci.yml` triggers on `pull_request`, never `pull_request_target`: code from a fork runs with a
  read-only token and no secrets. Its jobs hold `contents: read`; only the scheduled `security-tab`
  job holds `security-events: write`, and it runs no code from the repository.
- `publish.yml` never runs for a pull request. A manual run from another branch fails in the first
  job; a tag must equal `v` + `VERSION` and be a commit of `master`. Write permissions are per job:
  `packages: write` (build, merge), `id-token: write` and `attestations: write` (merge only),
  `contents: write` (the release job only).
- Every action is pinned to a commit SHA and every tool image to a digest; the workflows have
  `permissions: {}` at the top. Dependabot bumps the action SHAs and the Dockerfile base images.
  The tool images in `ci/lint.sh` and `ci.yml` (actionlint, shellcheck, hadolint, Trivy, gitleaks)
  are bumped by hand: `docker buildx imagetools inspect <image>:<tag>`, replace tag and digest.
- Images are pushed by digest first and get tags only after the smoke test passed on both
  architectures.

## Tags and versioning

Patina has its own semver in `VERSION` (`Cargo.toml` keeps upstream's version). The upstream base is
visible in the image labels `io.patina.upstream.repo` and `io.patina.upstream.commit` (from the
`UPSTREAM` file), and in every release's notes ("based on rustdesk-server `<commit>`, hbb_common
`<sha>`").

| Event | Tags |
|---|---|
| push to `master` (code/build paths) | `edge`, `sha-<short>` |
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
   **CI result** is green. The merge also publishes `edge`.
2. Tag that commit on `master` and push the tag (signed tags are preferred):
   `git tag -s v0.2.0 && git push origin v0.2.0`.
3. `publish.yml` fails if the tag differs from `VERSION` or is not on `master`. Otherwise it
   publishes `0.2.0`, `0.2`, `latest` and `sha-<short>` and creates the GitHub Release.

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
