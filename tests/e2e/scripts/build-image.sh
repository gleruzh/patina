#!/bin/bash
# Build an hbbs/hbbr image from an exact commit, without checking anything out:
# the context is `git archive <commit>` plus the hbb_common submodule at the
# commit it pins, unpacked into a temp dir outside the repo.
#
#   scripts/build-image.sh <src-commit> [--dockerfile <commit>:<path>] [--tag <tag>]
#
# Default Dockerfile: tests/e2e/server/Dockerfile.stock from this worktree.
# Default tag: patina-e2e-hbbs:<sha7>.
# Example (patched hbbs with the repo Dockerfile):
#   scripts/build-image.sh master --dockerfile master:Dockerfile
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
src=${1:?usage: build-image.sh <src-commit> [--dockerfile <commit>:<path>] [--tag <tag>]}
shift
dockerfile_ref="" tag=""
while [ $# -gt 0 ]; do
    case $1 in
        --dockerfile) dockerfile_ref=$2; shift 2 ;;
        --tag) tag=$2; shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
sha=$(git -C "$repo" rev-parse --verify "$src^{commit}")
tag=${tag:-patina-e2e-hbbs:${sha:0:7}}

ctx=$(mktemp -d "${TMPDIR:-/tmp}/patina-e2e-build.XXXXXX")
trap 'rm -rf "$ctx"' EXIT
git -C "$repo" archive "$sha" | tar -x -C "$ctx"
sub=$(git -C "$repo" ls-tree "$sha" libs/hbb_common | awk '{print $3}')
[ -d "$repo/libs/hbb_common/.git" ] || [ -f "$repo/libs/hbb_common/.git" ] \
    || git -C "$repo" submodule update --init libs/hbb_common
git -C "$repo/libs/hbb_common" cat-file -e "$sub^{commit}" 2>/dev/null \
    || git -C "$repo/libs/hbb_common" fetch -q origin "$sub"
git -C "$repo/libs/hbb_common" archive --prefix=libs/hbb_common/ "$sub" | tar -x -C "$ctx"

if [ -n "$dockerfile_ref" ]; then
    df_commit=$(git -C "$repo" rev-parse --verify "${dockerfile_ref%%:*}^{commit}")
    git -C "$repo" show "$df_commit:${dockerfile_ref#*:}" >"$ctx/Dockerfile.e2e"
    # Its .dockerignore travels with it (the context root is the src tree).
    df_dir=$(dirname "${dockerfile_ref#*:}")
    ign=.dockerignore; [ "$df_dir" = . ] || ign="$df_dir/.dockerignore"
    if git -C "$repo" cat-file -e "$df_commit:$ign" 2>/dev/null; then
        git -C "$repo" show "$df_commit:$ign" >"$ctx/.dockerignore"
    fi
    df_label="$df_commit:${dockerfile_ref#*:}"
else
    cp "$here/server/Dockerfile.stock" "$ctx/Dockerfile.e2e"
    df_label="tests/e2e/server/Dockerfile.stock"
fi
echo "building $tag from $sha (hbb_common $sub), Dockerfile $df_label"
docker build --label patina-e2e.source="$sha" --label patina-e2e.dockerfile="$df_label" \
    -t "$tag" -f "$ctx/Dockerfile.e2e" "$ctx"
