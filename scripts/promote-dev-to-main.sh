#!/usr/bin/env bash
set -euo pipefail

# Promote dev -> main for the parent and both submodules.
#
# The parent main merge deliberately stages the submodule main tips, so the
# usual submodule-pointer conflicts are resolved in the merge commit itself.
#
# Run from a clean tree. This script pushes. It never force-pushes.
# Real (non-submodule) merge conflicts stop the script for manual resolution.

if [ -z "${PROMOTE_DEV_TO_MAIN_ROOT:-}" ]; then
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  temp="$(mktemp "${TMPDIR:-/tmp}/promote-dev-to-main.XXXXXX")"
  cp "${BASH_SOURCE[0]}" "$temp"
  chmod +x "$temp"
  PROMOTE_DEV_TO_MAIN_ROOT="$root" PROMOTE_DEV_TO_MAIN_TEMP="$temp" exec "$temp" "$@"
fi

ROOT="$PROMOTE_DEV_TO_MAIN_ROOT"
cd "$ROOT"
trap 'rm -f "${PROMOTE_DEV_TO_MAIN_TEMP:-}"' EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  fail "a merge is already in progress; resolve or abort it first."
fi

dirty="$(git status --porcelain --untracked-files=no | grep -vE '^.. apps/(web|bot)$' || true)"
[ -z "$dirty" ] || fail "parent has uncommitted changes: $dirty"

for module in apps/web apps/bot; do
  dirty="$(git -C "$module" status --porcelain --untracked-files=no)"
  [ -z "$dirty" ] || fail "$module has uncommitted changes: $dirty"
done

echo "==> Syncing submodule dev branches"
for module in apps/web apps/bot; do
  git -C "$module" switch dev
  git -C "$module" pull --ff-only origin dev
  git -C "$module" push origin dev
done

echo "==> Aligning parent dev submodule pointers"
git switch dev
git pull --ff-only origin dev
./scripts/checkout-submodules.sh
git add apps/web apps/bot
if ! git diff --cached --quiet; then
  git commit -m "chore(submodules): pin dev submodule tips"
fi
git push origin dev

for module in apps/web apps/bot; do
  echo "==> Promoting $module dev -> main"
  git -C "$module" switch main
  git -C "$module" pull --ff-only origin main
  git -C "$module" merge --no-edit dev
  git -C "$module" push origin main
done

echo "==> Merging parent dev -> main"
git switch main
git pull --ff-only origin main

set +e
git merge --no-commit --no-ff dev
merge_status=$?
set -e

git -C apps/web switch main
git -C apps/bot switch main
git add apps/web apps/bot

unresolved="$(git diff --name-only --diff-filter=U)"
if [ -n "$unresolved" ]; then
  echo "Unresolved conflicts:" >&2
  echo "$unresolved" >&2
  fail "resolve the remaining conflicts and commit the merge manually."
fi

if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  git commit -m "Merge branch 'dev' into main"
elif [ "$merge_status" -ne 0 ]; then
  fail "merge failed without leaving a merge in progress."
elif ! git diff --cached --quiet; then
  git commit -m "chore(submodules): pin main submodule tips"
fi

./scripts/checkout-submodules.sh
git push origin main
echo "==> Done: dev promoted to main."
