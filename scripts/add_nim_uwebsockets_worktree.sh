#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <branch> [base-ref]" >&2
  exit 1
fi

branch="$1"
base_ref="${2:-main}"

repo_root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
target_root="$repo_root/nim_usockets/.worktree"
target_path="$target_root/$branch"

mkdir -p "$target_root"

if [ -e "$target_path" ]; then
  echo "worktree path already exists: $target_path" >&2
  exit 1
fi

if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch"; then
  exec git -C "$repo_root" worktree add "$target_path" "$branch"
else
  exec git -C "$repo_root" worktree add "$target_path" -b "$branch" "$base_ref"
fi
