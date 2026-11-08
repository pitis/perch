.PHONY: setup check shots icon dmg worktree update

setup: ## One-time: enable the git hooks in .githooks/
	git config core.hooksPath .githooks

check: ## The gate: run before every push
	swift test

shots: ## Before/after PNGs of every screen: make shots out=<dir outside the repo>
	@test -n "$(out)" || { echo "usage: make shots out=<dir>"; exit 2; }
	scripts/shots.sh "$(out)"

icon: ## Rebuild scripts/AppIcon.icns and docs/images/icon.png from the bird in Sources/Perch/Views/AppMark.swift
	scripts/icon.sh

dmg: ## Build dist/Perch-<version>.dmg for a release, from a clean checkout
	scripts/dmg.sh

worktree: ## New worktree: make worktree name=<slug> branch=<type/slug> [base=origin/<stacked-on>]
	@test -n "$(name)" -a -n "$(branch)" || { echo "usage: make worktree name=<slug> branch=<type/slug> [base=origin/<branch>]"; exit 2; }
	scripts/worktree.sh "$(name)" "$(branch)" $(base)

update: ## In a worktree: merge origin/main (or the stacked base) into this branch
	scripts/update.sh
