#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: validate-profile.sh <repository-root>\n' >&2
  exit 2
}

repo_root="${1:-}"
[[ -n "$repo_root" ]] || usage
[[ -d "$repo_root" ]] || { printf 'agent-tooling: repository root does not exist: %s\n' "$repo_root" >&2; exit 1; }

profile_file="$repo_root/.agent-tooling/profile.json"
[[ -r "$profile_file" ]] || { printf 'agent-tooling: missing profile manifest: %s\n' "$profile_file" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'agent-tooling: jq is required\n' >&2; exit 1; }
command -v git >/dev/null 2>&1 || { printf 'agent-tooling: git is required\n' >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { printf 'agent-tooling: perl is required\n' >&2; exit 1; }

profile="$(jq -er '.profile | select(type == "string" and length > 0)' "$profile_file")" || {
  printf 'agent-tooling: profile must be a non-empty string in %s\n' "$profile_file" >&2
  exit 1
}
declared_repo="$(jq -er '.repository | select(type == "string" and length > 0)' "$profile_file")" || {
  printf 'agent-tooling: repository must be a non-empty string in %s\n' "$profile_file" >&2
  exit 1
}

tooling_repo="$(jq -er '.tooling.repository | select(type == "string" and length > 0)' "$profile_file")" || {
  printf 'agent-tooling: tooling.repository must be a non-empty string in %s\n' "$profile_file" >&2
  exit 1
}
tooling_ref="$(jq -er '.tooling.ref | select(type == "string" and length > 0)' "$profile_file")" || {
  printf 'agent-tooling: tooling.ref must name the branch to float on in %s\n' "$profile_file" >&2
  exit 1
}
[[ ! "$tooling_ref" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'agent-tooling: tooling.ref names a branch; to freeze a revision write it to .agent-tooling/hold\n' >&2
  exit 1
}
# check-ref-format allows a leading dash (it is legal REF syntax); refuse it anyway
# so the ref can never read as an option to anything downstream.
if [[ "$tooling_ref" == -* ]] || ! git check-ref-format "refs/heads/$tooling_ref" >/dev/null 2>&1; then
  printf 'agent-tooling: tooling.ref is not a valid branch name: %s\n' "$tooling_ref" >&2
  exit 1
fi
[[ "$tooling_repo" == "boxlite-ai/agent-tooling" ]] || {
  printf 'agent-tooling: unsupported tooling repository: %s\n' "$tooling_repo" >&2
  exit 1
}
# The emergency brake is validated wherever the profile is: a hold that cannot be
# obeyed must fail the installation, never let it quietly keep floating.
hold_file="$repo_root/.agent-tooling/hold"
if [[ -e "$hold_file" ]]; then
  hold_sha="$(tr -d '\n' < "$hold_file")"
  { [[ "$hold_sha" =~ ^[0-9a-f]{40}$ ]] && [[ "$(wc -c < "$hold_file")" -le 41 ]]; } || {
    printf 'agent-tooling: %s must contain exactly one full lowercase commit SHA\n' "$hold_file" >&2
    exit 1
  }
fi
# The repository a consumer declares is checked against the remote it actually has,
# not against a list shipped here. Git is the authority on which repository this is,
# and a central roster would have to name private repositories inside a public plugin
# to say anything at all. An absent origin still passes: a local-only clone is a
# legitimate setup, and there is nothing to contradict.
origin="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
case "$origin" in
  *"github.com"*"${declared_repo}"*|"") ;;
  *) printf 'agent-tooling: origin does not match declared repository %s: %s\n' "$declared_repo" "$origin" >&2; exit 1 ;;
esac

# Verdict state is session-scoped with opaque suffixes, and new runtime files may be
# added as the gates evolve. Fixed filename checks cannot cover that namespace. Requiring
# the directory itself to be ignored keeps every current and future state file out of
# tree hashes and commits.
git -C "$repo_root" check-ignore -q .agents/state/ || {
  printf 'agent-tooling: runtime state directory must be gitignored: .agents/state/\n' >&2
  exit 1
}

for state_path in \
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

# Every host floats on the SAME ref the git gates float on. This is a weaker
# agreement than the old same-revision pin — hosts re-resolve the ref on their own
# schedules — but same-ref is the strongest property a floating fleet can declare.
for settings_file in "$repo_root/.claude/settings.json" "$repo_root/.github/copilot/settings.json"; do
  [[ -r "$settings_file" ]] || { printf 'agent-tooling: missing activation settings: %s\n' "$settings_file" >&2; exit 1; }
  jq -e --arg ref "$tooling_ref" '
    .extraKnownMarketplaces["boxlite-agent-tooling"].source.source == "github" and
    .extraKnownMarketplaces["boxlite-agent-tooling"].source.repo == "boxlite-ai/agent-tooling" and
    .extraKnownMarketplaces["boxlite-agent-tooling"].source.ref == $ref and
    .enabledPlugins["boxlite-agent-tooling@boxlite-agent-tooling"] == true
  ' "$settings_file" >/dev/null || {
    printf 'agent-tooling: activation settings must use source.source "github" and float on tooling.ref: %s\n' "$settings_file" >&2
    exit 1
  }
done

codex_marketplace="$repo_root/.agents/plugins/marketplace.json"
[[ -r "$codex_marketplace" ]] || { printf 'agent-tooling: missing Codex marketplace: %s\n' "$codex_marketplace" >&2; exit 1; }
jq -e --arg ref "$tooling_ref" '
  any(.plugins[];
    .name == "boxlite-agent-tooling" and
    .source.source == "git-subdir" and
    .source.url == "https://github.com/boxlite-ai/agent-tooling.git" and
    .source.ref == $ref and
    .source.path == "./plugins/boxlite-agent-tooling" and
    .policy.installation == "INSTALLED_BY_DEFAULT" and
    .policy.authentication == "ON_INSTALL" and
    .category == "Developer Tools")
' "$codex_marketplace" >/dev/null || {
  printf 'agent-tooling: Codex marketplace must declare the git-subdir source, tooling.ref, install policy, authentication, and category: %s\n' "$codex_marketplace" >&2
  exit 1
}

printf 'agent-tooling: profile %s is valid for %s\n' "$profile" "$declared_repo"
