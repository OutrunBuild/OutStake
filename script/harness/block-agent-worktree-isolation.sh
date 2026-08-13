#!/usr/bin/env bash
set -euo pipefail

hook_json=$(cat)
isolation=$(jq -r '.tool_input.isolation // empty' <<<"$hook_json")

if [[ "$isolation" == "worktree" ]]; then
  reason='OutStakeV2 forbids Agent(isolation:"worktree") because AI coding tools (Claude Code, etc.) auto-create tool-specific isolated worktree directories (e.g. .claude/worktrees/*). For isolated writes, first manually run `git worktree add` into .worktrees/<name>, then have the subagent cd into that absolute path; read-only Agents must not set isolation.'
  # stdout: Claude Code reads {continue:false, stopReason} as a block.
  jq -n --arg stopReason "$reason" '{continue: false, stopReason: $stopReason}'
  # stderr + exit 2: ZCode's PreToolUse block contract (exit 2 = deny); also
  # gives Claude Code a fallback reason when it reads stderr on a code-2 exit.
  printf '%s\n' "$reason" >&2
  exit 2
fi
