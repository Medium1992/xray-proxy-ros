#!/bin/sh
# check-fork-parity.sh <xray-git-dir> <upstream-ref> <fork-ref>
#
# Builds the Xray tree Dockerfile-release builds, running its patch steps
# with their hook checks (upstream-ref plus every series in patches/, the
# REALITY and uTLS module copies included), and
# compares its sources with fork-ref, the Medium1992/Xray-core-fork release
# branch built on the same upstream commit. The two are meant to carry the
# same changes; a file that differs outside the expected list fails the
# check. This is how a stale third_party/reality copy in the fork was found.
#
# The build does not need the fork: patches/ is complete on its own. This
# check is only useful while the fork exists.
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
# Run each patch step of Dockerfile-release as it is, hook checks included,
# so a check that no longer matches its patch fails here as in the build.
step() {
  cmd=$(awk -v start="^COPY patches/$1 " '$0 ~ start {f=1; next} f && /^RUN / {sub(/^RUN /, ""); c=1} c {print; if ($0 !~ /\\$/) exit}' "$here/Dockerfile-release" \
    | sed "s#/patches/$1#$here/patches/$1#g")
  [ -n "$cmd" ] || { echo "no Dockerfile-release step for patches/$1" >&2; exit 1; }
  env XHTTP_FLOW=required XHTTP_MUX=required REALITY_X25519=required UTLS=required \
    SNIFF=required HALF_CLOSE=required BACKUP_CONNECT=required sh -c "$cmd" >/dev/null \
    || { echo "the Dockerfile-release step for patches/$1 fails" >&2; exit 1; }
}
for series in xhttp-flow xhttp-mux reality utls sniff close connect; do
  step "$series"
done

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
