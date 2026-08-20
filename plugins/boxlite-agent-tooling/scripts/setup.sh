#!/usr/bin/env bash
set -euo pipefail

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$repo_root" ]] || { printf 'agent-tooling: run inside a Git repository or pass its root\n' >&2; exit 2; }

PLUGIN_ROOT="$plugin_root" "$plugin_root/scripts/validate-profile.sh" "$repo_root"

for hook in pre-commit commit-msg pre-push; do
  [[ -x "$plugin_root/.githooks/$hook" ]] || {
    printf 'agent-tooling: required Git hook is not executable: %s\n' "$plugin_root/.githooks/$hook" >&2
    exit 1
  }
done

git -C "$repo_root" config core.hooksPath "$plugin_root/.githooks"
configured="$(git -C "$repo_root" config --get core.hooksPath || true)"
[[ "$configured" == "$plugin_root/.githooks" ]] || {
  printf 'agent-tooling: failed to configure core.hooksPath\n' >&2
  exit 1
}

printf 'agent-tooling: configured %s\n' "$repo_root"
printf 'agent-tooling: core.hooksPath=%s\n' "$configured"
