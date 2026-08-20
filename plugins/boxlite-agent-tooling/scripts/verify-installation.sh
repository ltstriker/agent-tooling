#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$repo_root" ]] || { printf 'agent-tooling: run inside a Git repository or pass its root\n' >&2; exit 2; }
profile_file="$repo_root/.agent-tooling/profile.json"
[[ -r "$profile_file" ]] || { printf 'agent-tooling: missing %s\n' "$profile_file" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'agent-tooling: jq is required\n' >&2; exit 1; }

desired_sha="$(jq -er '.tooling.sha | select(test("^[0-9a-f]{40}$"))' "$profile_file")" || {
  printf 'agent-tooling: tooling.sha must be a full 40-character lowercase commit SHA\n' >&2
  exit 1
}
common_git_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)"
expected_plugin="$common_git_dir/agent-tooling/$desired_sha/plugins/boxlite-agent-tooling"
running_plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
running_checkout="$(cd "$running_plugin/../.." && pwd -P)"
configured="$(git -C "$repo_root" config --worktree --get core.hooksPath 2>/dev/null || true)"

[[ "$configured" == /* ]] || {
  printf 'agent-tooling: worktree core.hooksPath is not an absolute shared-tooling path\n' >&2
  exit 1
}
configured="$(cd "$configured" 2>/dev/null && pwd -P)" || {
  printf 'agent-tooling: configured hooks path does not exist: %s\n' "$configured" >&2
  exit 1
}
expected_hooks="$(cd "$expected_plugin/.githooks" 2>/dev/null && pwd -P)" || {
  printf 'agent-tooling: pinned tooling checkout is not installed: %s\n' "$expected_plugin" >&2
  exit 1
}
running_head="$(git --git-dir="$running_checkout/.git" rev-parse HEAD 2>/dev/null || true)"

[[ "$running_head" == "$desired_sha" ]] || {
  printf 'agent-tooling: running revision %s does not match pinned revision %s\n' "${running_head:-unknown}" "$desired_sha" >&2
  exit 1
}
[[ "$configured" == "$expected_hooks" && "$configured" == "$running_plugin/.githooks" ]] || {
  printf 'agent-tooling: configured hooks do not match pinned revision %s\n' "$desired_sha" >&2
  exit 1
}
