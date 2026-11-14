#!/bin/sh
# check-fork-parity.sh <xray-git-dir> <upstream-ref> <fork-ref>
#
# Builds the Xray tree Dockerfile-release builds (upstream-ref plus every
# series in patches/, the REALITY and uTLS module copies included) and
# compares its sources with fork-ref, the Medium1992/Xray-core-fork release
# branch built on the same upstream commit. The two are meant to carry the
# same changes; a file that differs outside the expected list fails the
# check. This is how a stale third_party/reality copy in the fork was found.
#
# Expected differences:
#   core/core.go, features/policy/policy.go   version suffix and buffer size,
#                                              set by Dockerfile-release args
#   third_party/utls                           ROS patches a module copy, the
#                                              fork replaces the module
#   go.mod, go.sum                             the utls replace above
#   *_test.go, testing/, .github/              tests and CI live on one side
set -eu
xray=$1 upstream=$2 fork=$3
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'git -C "$xray" worktree remove --force "$work/ros" >/dev/null 2>&1 || true; git -C "$xray" worktree remove --force "$work/fork" >/dev/null 2>&1 || true; rm -r "$work"' EXIT

git -C "$xray" worktree add -q --detach "$work/ros" "$upstream"
git -C "$xray" worktree add -q --detach "$work/fork" "$fork"
cd "$work/ros"
apply() { for p in "$@"; do git apply "$p" || { echo "patch $(basename "$p") does not apply" >&2; exit 1; }; done; }
apply "$here"/patches/xhttp-flow/*.patch "$here"/patches/xhttp-mux/*.patch
mkdir -p third_party
cp -r "$(go list -m -f '{{.Dir}}' github.com/xtls/reality)" third_party/reality
chmod -R u+w third_party/reality
apply "$here"/patches/reality/*.patch
cp -r "$(go list -m -f '{{.Dir}}' github.com/refraction-networking/utls)" third_party/utls
chmod -R u+w third_party/utls
apply "$here"/patches/utls/*.patch "$here"/patches/sniff/*.patch "$here"/patches/close/*.patch "$here"/patches/connect/*.patch

unexpected=$(diff -rq "$work/ros" "$work/fork" -x .git -x resources 2>&1 \
  | sed -e "s#$work/ros/##g" -e "s#$work/fork/##g" \
  | grep -v -e '_test\.go' -e 'testing/' -e '\.github' -e 'third_party/utls' -e 'third_party: utls' \
            -e 'go\.mod' -e 'go\.sum' -e 'core/core\.go' -e 'features/policy/policy\.go' \
            -e 'testdata' || true)
if [ -n "$unexpected" ]; then
  echo "ROS patches and $fork differ outside the expected files:"
  echo "$unexpected"
  exit 1
fi
echo "ROS patches on $upstream match $fork"
