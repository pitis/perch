#!/usr/bin/env bash
# scripts/worktree.sh <name> <branch> [base]      (make worktree name=… branch=… [base=origin/…])
#
# Creates worktrees/<number>--<name> (gitignored) on <branch>:
#   - an existing local branch: checked out as is;
#   - a branch only on origin: a new local branch tracking origin/<branch>;
#   - otherwise a new branch from [base] (default origin/main).
# The branch's stacked base is recorded in `git config branch.<branch>.updateBase` (read by
# `make update` and `make shots`): [base] when given, else what was recorded before, else the base of
# the branch's open PR, else main.
# <number> is the branch's PR if it has one, otherwise one more than the highest issue/PR number or
# local worktree number. That's a guess, and the folder keeps it even if the PR gets another number.
# It also fast-forwards the main checkout's main, since sessions started there read its AGENTS.md.
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: scripts/worktree.sh <name> <branch> [origin/<base>]" >&2; exit 2; }
name=$1 branch=$2 base=${3:-}
if [ -n "$base" ] && [[ $base != origin/* ]]; then
  echo "✗ base must be a remote branch like origin/feat/x (got: $base)" >&2; exit 2
fi
root="$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
cd "$root"
mkdir -p worktrees
git fetch -q --prune origin
if [ -n "$base" ] && ! git show-ref --verify -q "refs/remotes/$base"; then
  echo "✗ $base doesn't exist" >&2; exit 2
fi

current=$(git branch --show-current)
if [ "$current" = main ]; then
  git merge -q --ff-only origin/main || echo "  the main checkout's main wasn't fast-forwarded (see above)" >&2
else
  echo "  the main checkout is on ${current:-a detached HEAD}, not main: switch it back when nothing there is in progress" >&2
fi

number=$(gh pr list --head "$branch" --state all --json number --jq '.[0].number // empty')
if [ -z "$number" ]; then
  last=$(gh api "repos/{owner}/{repo}/issues?state=all&per_page=1&sort=created&direction=desc" --jq '.[0].number // 0')
  local_max=0
  for d in worktrees/*--*; do
    [ -d "$d" ] || continue
    n=${d#worktrees/}; n=${n%%--*}
    [[ $n =~ ^[0-9]+$ ]] && [ "$n" -gt "$local_max" ] && local_max=$n
  done
  number=$(( (last > local_max ? last : local_max) + 1 ))
fi
dir="worktrees/$number--$name"

# Settled before the worktree exists, so a failing gh leaves nothing half made.
if [ -z "$base" ]; then
  base=origin/$(git config --get "branch.$branch.updateBase" ||
    gh pr list --head "$branch" --state open --json baseRefName --jq '.[0].baseRefName // "main"')
fi

if git show-ref --verify -q "refs/heads/$branch"; then
  git worktree add -q "$dir" "$branch"
elif git show-ref --verify -q "refs/remotes/origin/$branch"; then
  git worktree add -q --track -b "$branch" "$dir" "origin/$branch"
else
  git worktree add -q --no-track -b "$branch" "$dir" "$base"
fi
git config "branch.$branch.updateBase" "${base#origin/}"
echo "✓ $dir on $branch (updates from $base)"
