#!/usr/bin/env bash
# scripts/shots.sh <out-dir>      (make shots out=<dir>)
#
# Renders every screen (`Perch --snapshot`, sample data) twice into <out-dir>: before-<screen>.png
# from origin/<base> (main, or the branch this one is stacked on) and after-<screen>.png from this
# checkout, uncommitted edits included. The base is built in a throwaway worktree in <out-dir>, so
# every run builds it from scratch.
# Nothing here diffs the two: identical code still renders some screens differently (timers, the
# cursor), so pick the screens the change touches by looking at them.
set -euo pipefail
out=${1:?usage: scripts/shots.sh <out-dir>}
mkdir -p "$out"
out=$(cd "$out" && pwd)
cd "$(git rev-parse --show-toplevel)"

branch=$(git branch --show-current)
base=main
[ -z "$branch" ] || base=$(git config --default main --get "branch.$branch.updateBase")
git fetch -q origin
rm -f "$out"/before-*.png "$out"/after-*.png
trap 'git worktree remove --force "$out/.base" 2>/dev/null || true' EXIT
git worktree add -q --detach "$out/.base" "origin/$base"

render() { # <checkout> <prefix>
  (cd "$1" && swift build -q --product Perch && "$(swift build --show-bin-path)/Perch" --snapshot "$out/.$2")
  for f in "$out/.$2"/*.png; do mv "$f" "$out/$2-$(basename "$f")"; done
  rmdir "$out/.$2"
}
render "$out/.base" before
render . after
echo "✓ $out: before-*.png (origin/$base), after-*.png (this checkout)"
