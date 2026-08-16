#!/usr/bin/env bash
# gsd-worktree-setup.sh — make a linked git worktree buildable for faBolus.
#
# Idempotent and machine-independent: all targets are derived from the main
# repo's location, so there are no hardcoded absolute paths. Safe to run any
# number of times, and a no-op when run from the main checkout.
#
# Two things break inside a fresh git worktree in this repo:
#   1. `.planning` is an UNTRACKED symlink -> the private faBolus-internal
#      planning repo. A fresh worktree has no `.planning`, so GSD executors
#      can't read their PLAN/STATE/PROJECT files.
#   2. `project.yml` references the pump BLE package by the RELATIVE path
#      `../TandemKit`. From a worktree that resolves to the wrong place and
#      `xcodegen` fails with `Invalid local package "TandemKit"`.
#
# Fix — create (only what's missing):
#   <worktree>/.planning         -> <real planning dir>
#   <worktree-parent>/TandemKit  -> <real TandemKit dir>   (shared by all
#                                    worktrees living in that parent dir)
#
# Symlinks live at/above the worktree root and are never tracked, so they
# never show in `git status` and are never committed. On worktree removal only
# the link is deleted; the real dirs are untouched.
set -euo pipefail

# When invoked as a Claude Code hook (SubagentStart/SessionStart), the worktree
# path arrives as `.cwd` on stdin (JSON). cd into it so the git resolution below
# targets the worktree, not wherever the hook process happened to start. When run
# manually (tty on stdin), skip this and use the current directory.
if [ ! -t 0 ]; then
  _HOOK_CWD=$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).cwd||""))}catch(e){}})' 2>/dev/null || true)
  if [ -n "${_HOOK_CWD:-}" ] && [ -d "$_HOOK_CWD" ]; then cd "$_HOOK_CWD" || true; fi
fi

WT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Act ONLY inside a linked worktree (.git is a file); no-op in the main checkout (.git is a dir).
[ -f "$WT_ROOT/.git" ] || exit 0

# Main repo root = parent of the shared git common dir.
COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null) || exit 0
case "$COMMON_DIR" in
  /*) : ;;                                  # already absolute
  *)  COMMON_DIR="$WT_ROOT/$COMMON_DIR" ;;  # relative -> anchor to worktree
esac
MAIN_ROOT=$(cd "$(dirname "$COMMON_DIR")" && pwd -P) || exit 0

changed=0

# 1. .planning (per-worktree) -> real planning dir (follows the main-tree symlink).
if [ -e "$MAIN_ROOT/.planning" ]; then
  PLANNING_TARGET=$(cd "$MAIN_ROOT/.planning" && pwd -P)
  if [ "$(readlink "$WT_ROOT/.planning" 2>/dev/null)" != "$PLANNING_TARGET" ]; then
    ln -sfn "$PLANNING_TARGET" "$WT_ROOT/.planning"
    changed=1
  fi
fi

# 2. TandemKit (shared, in the worktree's PARENT) so `../TandemKit` resolves.
if [ -d "$MAIN_ROOT/../TandemKit" ]; then
  TANDEMKIT_TARGET=$(cd "$MAIN_ROOT/../TandemKit" && pwd -P)
  WT_PARENT=$(dirname "$WT_ROOT")
  if [ "$(readlink "$WT_PARENT/TandemKit" 2>/dev/null)" != "$TANDEMKIT_TARGET" ]; then
    ln -sfn "$TANDEMKIT_TARGET" "$WT_PARENT/TandemKit"
    changed=1
  fi
fi

if [ "$changed" = 1 ]; then
  echo "gsd-worktree-setup: linked .planning + TandemKit for worktree $WT_ROOT" >&2
fi
exit 0
