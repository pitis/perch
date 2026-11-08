#!/usr/bin/env bash
# Run inside a worktree: merge origin/<base> into the current branch. <base> is the branch this one
# is stacked on (branch.<branch>.updateBase, else its open PR's base) until that branch's PR is
# merged or its branch is gone, then main. When the base was squash-merged and this branch already
# has all of it, the squash commit is first recorded as merged without changing any file, so main's
# copy of the base's changes doesn't conflict with this branch's. On a conflict no merge is made;
# the conflicted files and the command to run by hand are printed.
set -euo pipefail
branch=$(git branch --show-current)
[ -n "$branch" ] || { echo "✗ detached HEAD: check out a branch first" >&2; exit 1; }
git fetch -q --prune origin
base=$(git config --get "branch.$branch.updateBase" ||
  gh pr list --head "$branch" --state open --json baseRefName --jq '.[0].baseRefName // "main"')
if [ "$base" != main ]; then
  merged=$(gh pr list --head "$base" --state merged --json headRefOid,mergeCommit \
    --jq '.[0] | select(.) | "\(.headRefOid) \(.mergeCommit.oid)"')
  if [ -n "$merged" ] || ! git show-ref --verify -q "refs/remotes/origin/$base"; then
    echo "stacked base $base is merged or gone → following main"
    if [ -n "$merged" ]; then
      read -r base_head squash <<<"$merged"
      if git merge-base --is-ancestor "$base_head" HEAD; then
        git merge -q -s ours --no-edit -m "Record the squash merge of $base, which this branch already contains" "$squash"
      else
        echo "  $base changed after this branch last merged it, so main may conflict with it below" >&2
      fi
    fi
    git config "branch.$branch.updateBase" main
    base=main
  fi
fi
set +e
conflicts=$(git merge-tree --write-tree --name-only --no-messages HEAD "origin/$base")
rc=$?
set -e
case $rc in
  0) ;;
  1)
    echo "✗ conflicts with origin/$base in:" >&2
    tail -n +2 <<<"$conflicts" | sed 's/^/    /' >&2
    echo "  No merge made. Resolve by hand: git merge origin/$base" >&2
    exit 1 ;;
  *) echo "✗ git merge-tree failed (exit $rc); see the error above" >&2; exit "$rc" ;;
esac
git merge -q --no-edit "origin/$base"
echo "✓ $branch is up to date with origin/$base"
