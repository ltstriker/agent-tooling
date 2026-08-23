#!/usr/bin/env bash
# Opportunistic synchronization the Git lifecycle hooks run. Two duties:
#
#   1. A broken or superseded installation (record missing, hold not adopted,
#      hooksPath astray) is repaired in the FOREGROUND via the consumer's committed
#      install.sh — the state is wrong right now and the very next commit would be
#      rejected, so waiting is worse than blocking.
#   2. A healthy installation gets a BACKGROUND refresh attempt, throttled by the
#      last-check stamp, so the recorded revision follows tooling.ref without ever
#      putting a network wait inside a checkout, merge, or rebase. The refresh's own
#      lock keeps concurrent lifecycle events from piling up.
#
# Every failure path exits 0: synchronization is opportunistic, and the fail-closed
# enforcement lives in the commit and push gates, not here.
set -uo pipefail

[[ "${AGENT_TOOLING_SYNC_ACTIVE:-}" != "1" ]] || exit 0

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || exit 0
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

spawn_refresh() {
  [[ "${AGENT_TOOLING_REFRESH:-1}" != "0" ]] || return 0
  [[ ! -e "$repo_root/.agent-tooling/hold" ]] || return 0
  local common cache minutes
  common="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  cache="$common/agent-tooling"
  [[ -d "$cache" ]] || return 0
  minutes="${AGENT_TOOLING_REFRESH_MINUTES:-15}"
  [[ -z "$(find "$cache" -maxdepth 1 -name last-check -mmin "-$minutes" 2>/dev/null)" ]] || return 0
  # nohup + disown, not setsid: macOS ships no setsid. Redirecting both streams to a
  # file keeps git from waiting on an inherited pipe (same pattern as arm_pr_watch).
  nohup bash "$plugin_root/scripts/refresh-installation.sh" "$repo_root" \
    >> "$cache/refresh.log" 2>&1 &
  disown 2>/dev/null || true
}

if "$plugin_root/scripts/verify-installation.sh" "$repo_root" >/dev/null 2>&1; then
  spawn_refresh
  exit 0
fi

installer="$repo_root/.agent-tooling/install.sh"
if [[ ! -x "$installer" ]]; then
  printf 'agent-tooling: automatic synchronization skipped; run ./.agent-tooling/install.sh\n' >&2
  exit 0
fi

if AGENT_TOOLING_SYNC_ACTIVE=1 "$installer"; then
  printf 'agent-tooling: synchronized the recorded tooling revision\n' >&2
else
  status=$?
  printf 'agent-tooling: automatic synchronization failed (exit %s); run ./.agent-tooling/install.sh\n' "$status" >&2
fi

exit 0
