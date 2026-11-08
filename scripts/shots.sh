#!/usr/bin/env bash
# scripts/shots.sh <out-dir>      (make shots out=<dir outside the repo>)
#
# Renders every screen (`Perch --snapshot`, sample data) twice into <out-dir>: before-<screen>.png
# from the commit where this branch forked from origin/<base> (main, or the branch it's stacked on,
# as `make update` recorded it), and after-<screen>.png from this checkout, uncommitted edits
# included. So the two sets differ only by this branch, like the PR's diff. The base is built in a
# throwaway worktree in <out-dir>, so every run builds it from scratch.
# Nothing here diffs the two: identical code still renders some screens differently (timers, the
# cursor), so pick the screens the change touches by looking at them.
set -euo pipefail
out=${1:?usage: scripts/shots.sh <out-dir>}
mkdir -p "$out"
out=$(cd "$out" && pwd -P)
root=$(git rev-parse --show-toplevel)
case "$out/" in
  "$(cd "$root" && pwd -P)"/*) echo "✗ $out is inside the repo; pick a folder outside it" >&2; exit 2 ;;
esac
cd "$root"

branch=$(git branch --show-current)
base=main
[ -z "$branch" ] || base=$(git config --default main --get "branch.$branch.updateBase")
git fetch -q --prune origin
if ! git show-ref -q --verify "refs/remotes/origin/$base"; then
  echo "• origin/$base is gone, so comparing with main. If it was merged, run make update first." >&2
  base=main
fi
rm -rf "$out"/before-*.png "$out"/after-*.png "$out/.before" "$out/.after"
# A killed run can leave its .base behind; the trap clears this run's.
git worktree remove --force "$out/.base" 2>/dev/null || true
trap 'git worktree remove --force "$out/.base" 2>/dev/null || true' EXIT
git worktree add -q --detach "$out/.base" "$(git merge-base HEAD "origin/$base")"

render() { # <checkout> <prefix>
  (cd "$1" && swift build -q --product Perch && "$(swift build --show-bin-path)/Perch" --snapshot "$out/.$2")
  for f in "$out/.$2"/*.png; do mv "$f" "$out/$2-$(basename "$f")"; done
  rmdir "$out/.$2"
}
render "$out/.base" before
render . after
echo "✓ $out: before-*.png (where this branch forked from origin/$base), after-*.png (this checkout)"
