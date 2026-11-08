.PHONY: setup check shots worktree update

setup: ## One-time: enable the git hooks in .githooks/
	git config core.hooksPath .githooks

check: ## The gate: run before every push
	swift test

shots: ## Before/after PNGs of every screen: make shots out=<dir outside the repo>
	@test -n "$(out)" || { echo "usage: make shots out=<dir>"; exit 2; }
	scripts/shots.sh "$(out)"

worktree: ## New worktree: make worktree name=<slug> branch=<type/slug> [base=origin/<stacked-on>]
	@test -n "$(name)" -a -n "$(branch)" || { echo "usage: make worktree name=<slug> branch=<type/slug> [base=origin/<branch>]"; exit 2; }
	scripts/worktree.sh "$(name)" "$(branch)" $(base)

update: ## In a worktree: merge origin/main (or the stacked base) into this branch
	scripts/update.sh
