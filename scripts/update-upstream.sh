#!/bin/sh
set -e
cd "$(dirname "$0")/.."

git remote get-url upstream >/dev/null 2>&1 ||
	git remote add upstream https://github.com/pbs05/ponwrt.git

if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
	git fetch --unshallow upstream || true
fi

git fetch upstream master
git rebase upstream/master
echo "rebased onto $(git rev-parse --short upstream/master)"
