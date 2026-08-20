#!/usr/bin/env bash
set -uo pipefail

[[ "${AGENT_TOOLING_SYNC_ACTIVE:-}" != "1" ]] || exit 0

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || exit 0
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

if "$plugin_root/scripts/verify-installation.sh" "$repo_root" >/dev/null 2>&1; then
  exit 0
fi

installer="$repo_root/.agent-tooling/install.sh"
if [[ ! -x "$installer" ]]; then
  printf 'agent-tooling: automatic synchronization skipped; run ./.agent-tooling/install.sh\n' >&2
  exit 0
fi

if AGENT_TOOLING_SYNC_ACTIVE=1 "$installer"; then
  printf 'agent-tooling: synchronized the pinned tooling revision\n' >&2
else
  status=$?
  printf 'agent-tooling: automatic synchronization failed (exit %s); run ./.agent-tooling/install.sh\n' "$status" >&2
fi

exit 0
