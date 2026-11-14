#!/bin/sh
# regen-patches.sh <xray-git-dir> <upstream-ref>
#
# Rewrites every series in patches/ as one patch taken from upstream-ref.
# The series are applied in the order Dockerfile-release applies them, the
# REALITY and uTLS module copies included, and each series is then written
# out as the one diff it makes to the tree it is applied to. A change to a
# series is made on such a tree and written out the same way, so the
# patches never pile up on earlier ones.
#
# git apply --3way lets the series follow a new upstream as long as their
# hunks still merge; a series that does not stops the script, and is fixed
# on the tree it leaves in place.
set -eu
xray=$1 upstream=$2
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
tree=$work/tree
git -C "$xray" worktree add -q --detach "$tree" "$upstream"
cd "$tree"
git config user.name regen-patches
git config user.email regen-patches@localhost

commit() { git add -A -f . && git commit -q --allow-empty -m "$1"; }
module_copy() {
  mkdir -p third_party
  cp -r "$(go list -m -f '{{.Dir}}' "$1")" "third_party/$2"
  chmod -R u+w "third_party/$2"
  go mod edit -replace "$1=./third_party/$2"
}

for series in xhttp-flow xhttp-mux reality utls sniff close connect; do
  case $series in
    reality) module_copy github.com/xtls/reality reality ;;
    utls) module_copy github.com/refraction-networking/utls utls ;;
  esac
  commit "base of $series"
  for p in "$here/patches/$series"/*.patch; do
    git apply --3way "$p" || {
      echo "patches/$series/$(basename "$p") does not apply on $upstream; the tree is left at $tree" >&2
      exit 1
    }
  done
  out=$work/$series.patch
  {
    echo "patches/$series as one diff on XTLS/Xray-core $upstream ($(git rev-parse --short "$upstream"))"
    echo "after the series before it in Dockerfile-release. Written by regen-patches.sh."
    echo
    git diff --binary HEAD
  } > "$out"
  commit "$series"
done

for series in xhttp-flow xhttp-mux reality utls sniff close connect; do
  rm "$here/patches/$series"/*.patch
  cp "$work/$series.patch" "$here/patches/$series/0001-$series.patch"
done
git -C "$xray" worktree remove --force "$tree"
rm -r "$work"
echo "patches/ rewritten as one patch per series on $upstream"
