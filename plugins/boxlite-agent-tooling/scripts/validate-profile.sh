#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: validate-profile.sh <repository-root>\n' >&2
  exit 2
}

repo_root="${1:-}"
[[ -n "$repo_root" ]] || usage
[[ -d "$repo_root" ]] || { printf 'agent-tooling: repository root does not exist: %s\n' "$repo_root" >&2; exit 1; }
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

profile_file="$repo_root/.agent-tooling/profile.json"
[[ -r "$profile_file" ]] || { printf 'agent-tooling: missing profile manifest: %s\n' "$profile_file" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'agent-tooling: jq is required\n' >&2; exit 1; }
command -v git >/dev/null 2>&1 || { printf 'agent-tooling: git is required\n' >&2; exit 1; }

profile="$(jq -er '.profile | select(type == "string" and length > 0)' "$profile_file")" || {
  printf 'agent-tooling: profile must be a non-empty string in %s\n' "$profile_file" >&2
  exit 1
}
expected_repo="$(jq -er --arg profile "$profile" '.profiles[$profile].repository // empty' "$plugin_root/profiles/catalog.json" || true)"
[[ -n "$expected_repo" ]] || { printf 'agent-tooling: unknown profile: %s\n' "$profile" >&2; exit 1; }

declared_repo="$(jq -er '.repository | select(type == "string" and length > 0)' "$profile_file")" || {
  printf 'agent-tooling: repository must be a non-empty string in %s\n' "$profile_file" >&2
  exit 1
}

tooling_repo="$(jq -er '.tooling.repository | select(type == "string" and length > 0)' "$profile_file")" || {
  printf 'agent-tooling: tooling.repository must be a non-empty string in %s\n' "$profile_file" >&2
  exit 1
}
tooling_sha="$(jq -er '.tooling.sha | select(test("^[0-9a-f]{40}$"))' "$profile_file")" || {
  printf 'agent-tooling: tooling.sha must be a full lowercase commit SHA in %s\n' "$profile_file" >&2
  exit 1
}
[[ "$tooling_repo" == "boxlite-ai/agent-tooling" ]] || {
  printf 'agent-tooling: unsupported tooling repository: %s\n' "$tooling_repo" >&2
  exit 1
}
[[ "$declared_repo" == "$expected_repo" ]] || {
  printf 'agent-tooling: profile %s expects %s, got %s\n' "$profile" "$expected_repo" "$declared_repo" >&2
  exit 1
}

origin="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
case "$origin" in
  *"github.com"*"${expected_repo}"*|"") ;;
  *) printf 'agent-tooling: origin does not match profile repository %s: %s\n' "$expected_repo" "$origin" >&2; exit 1 ;;
esac

for state_path in \
  .agents/state/last-audit.json \
  .agents/state/last-verdict.json \
  .agents/state/last-verdict.prev.json \
  .agents/state/pr-reviewed.json \
  .agents/state/verdict-last-uuid \
  .agents/state/verdict-audit.lock \
  .agents/state/verdict-decisions.log \
  .claude/.last-audit.json \
  .claude/.last-audit-handoff.json \
  .claude/.last-verdict.json \
  .claude/.pr-reviewed.json \
  .claude/.verdict-last-uuid \
  .claude/.verdict-decisions.log; do
  git -C "$repo_root" check-ignore -q "$state_path" || {
    printf 'agent-tooling: runtime state path must be gitignored: %s\n' "$state_path" >&2
    exit 1
  }
done

jq -e '
  .schemaVersion == 1 and
  (.checks | type == "array") and
  (.checks | length > 0) and
  all(.checks[]; (.name | type == "string" and length > 0) and (.command | type == "string" and length > 0))
' "$profile_file" >/dev/null || {
  printf 'agent-tooling: checks must be a non-empty array of name/command objects in %s\n' "$profile_file" >&2
  exit 1
}

for settings_file in "$repo_root/.claude/settings.json" "$repo_root/.github/copilot/settings.json"; do
  [[ -r "$settings_file" ]] || { printf 'agent-tooling: missing activation settings: %s\n' "$settings_file" >&2; exit 1; }
  jq -e --arg sha "$tooling_sha" '
    .extraKnownMarketplaces["boxlite-agent-tooling"].source.repo == "boxlite-ai/agent-tooling" and
    .extraKnownMarketplaces["boxlite-agent-tooling"].source.ref == $sha and
    .enabledPlugins["boxlite-agent-tooling@boxlite-agent-tooling"] == true
  ' "$settings_file" >/dev/null || {
    printf 'agent-tooling: activation settings do not match the pinned tooling revision: %s\n' "$settings_file" >&2
    exit 1
  }
done

codex_marketplace="$repo_root/.agents/plugins/marketplace.json"
[[ -r "$codex_marketplace" ]] || { printf 'agent-tooling: missing Codex marketplace: %s\n' "$codex_marketplace" >&2; exit 1; }
jq -e --arg sha "$tooling_sha" '
  any(.plugins[];
    .name == "boxlite-agent-tooling" and
    .source.url == "https://github.com/boxlite-ai/agent-tooling.git" and
    .source.sha == $sha and
    .source.path == "./plugins/boxlite-agent-tooling" and
    .policy.installation == "INSTALLED_BY_DEFAULT")
' "$codex_marketplace" >/dev/null || {
  printf 'agent-tooling: Codex marketplace does not match the pinned tooling revision: %s\n' "$codex_marketplace" >&2
  exit 1
}

printf 'agent-tooling: profile %s is valid for %s\n' "$profile" "$expected_repo"
