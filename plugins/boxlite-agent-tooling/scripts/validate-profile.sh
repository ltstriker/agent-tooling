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
[[ "$declared_repo" == "$expected_repo" ]] || {
  printf 'agent-tooling: profile %s expects %s, got %s\n' "$profile" "$expected_repo" "$declared_repo" >&2
  exit 1
}

origin="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
case "$origin" in
  *"github.com"*"${expected_repo}"*|"") ;;
  *) printf 'agent-tooling: origin does not match profile repository %s: %s\n' "$expected_repo" "$origin" >&2; exit 1 ;;
esac

jq -e '
  .schemaVersion == 1 and
  (.checks | type == "array") and
  (.checks | length > 0) and
  all(.checks[]; (.name | type == "string" and length > 0) and (.command | type == "string" and length > 0))
' "$profile_file" >/dev/null || {
  printf 'agent-tooling: checks must be a non-empty array of name/command objects in %s\n' "$profile_file" >&2
  exit 1
}

printf 'agent-tooling: profile %s is valid for %s\n' "$profile" "$expected_repo"
