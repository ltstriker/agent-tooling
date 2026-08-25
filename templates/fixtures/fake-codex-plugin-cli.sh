#!/usr/bin/env bash
set -euo pipefail

state="${FAKE_CODEX_STATE:?}"
printf '%s\n' "$*" >> "$state/commands"

if [[ "$*" == "plugin marketplace list --json" ]]; then
  if [[ -e "$state/marketplace" ]]; then
    jq -nc \
      --arg root "${FAKE_CODEX_MARKETPLACE_ROOT:?}" \
      --arg source_type "${FAKE_CODEX_MARKETPLACE_SOURCE_TYPE:-git}" \
      --arg source "${FAKE_CODEX_MARKETPLACE_SOURCE:-https://github.com/boxlite-ai/agent-tooling.git}" '{
      marketplaces: [{
        name: "boxlite-agent-tooling",
        root: $root,
        marketplaceSource: {
          sourceType: $source_type,
          source: $source
        }
      }]
    }'
  else
    printf '{"marketplaces":[]}\n'
  fi
elif [[ "$1 $2 $3" == "plugin marketplace add" ]]; then
  [[ "$4" == "https://github.com/boxlite-ai/agent-tooling.git" ]]
  [[ "$5" == "--ref" && "$6" == "main" && "$7" == "--json" ]]
  [[ "${FAKE_CODEX_FAIL_MARKETPLACE_ADD:-0}" != 1 ]] || {
    printf 'fixture marketplace failure\n' >&2
    exit 1
  }
  if [[ -e "$state/marketplace" &&
        "${FAKE_CODEX_MARKETPLACE_SOURCE_TYPE:-git}" == "git" &&
        "${FAKE_CODEX_MARKETPLACE_SOURCE:-https://github.com/boxlite-ai/agent-tooling.git}" == "$4" ]]; then
    if [[ "${FAKE_CODEX_MARKETPLACE_REF:-main}" != "$6" ]]; then
      printf 'marketplace already added from a different source\n' >&2
      exit 1
    fi
    printf '{"name":"boxlite-agent-tooling","alreadyAdded":true}\n'
    exit 0
  fi
  [[ -e "$state/marketplace" ]] || printf 'added\n' >> "$state/marketplace-additions"
  touch "$state/marketplace"
  printf '%s\n' "${FAKE_CODEX_MARKETPLACE_VERSION:-0.1.4}" > "$state/marketplace-version"
  printf '{"name":"boxlite-agent-tooling","alreadyAdded":false}\n'
elif [[ "$*" == "plugin marketplace upgrade boxlite-agent-tooling --json" ]]; then
  [[ "${FAKE_CODEX_FAIL_MARKETPLACE_UPGRADE:-0}" != 1 ]] || {
    printf 'fixture marketplace upgrade failure\n' >&2
    exit 1
  }
  version="${FAKE_CODEX_MARKETPLACE_VERSION:-0.1.4}"
  printf '%s\n' "$version" > "$state/marketplace-version"
  if [[ "${FAKE_CODEX_FALSE_SUCCESS_MARKETPLACE_UPGRADE:-0}" != 1 && -e "$state/plugin-installed" ]]; then
    printf '%s\n' "$version" > "$state/plugin-version"
  fi
  jq -nc '{
    selectedMarketplaces: ["boxlite-agent-tooling"],
    upgradedRoots: ["/plugin-marketplaces/boxlite-agent-tooling"],
    errors: []
  }'
elif [[ "$1 $2" == "plugin list" ]]; then
  [[ -e "$state/marketplace" ]] || {
    printf 'marketplace missing\n' >&2
    exit 1
  }
  installed=false
  enabled=false
  [[ ! -e "$state/plugin-installed" ]] || installed=true
  [[ ! -e "$state/plugin-enabled" ]] || enabled=true
  if [[ "$installed" == true ]]; then
    version="$(head -n1 "$state/plugin-version" 2>/dev/null || printf '0.1.4')"
    source_json='{"source":"local","path":"/plugin-cache/boxlite-agent-tooling"}'
  else
    version="$(head -n1 "$state/marketplace-version" 2>/dev/null || printf '0.1.4')"
    source_json='{"source":"git-subdir","url":"https://github.com/boxlite-ai/agent-tooling.git","ref":"main","path":"./plugins/boxlite-agent-tooling"}'
  fi
  jq -nc \
    --argjson installed "$installed" \
    --argjson enabled "$enabled" \
    --argjson source "$source_json" \
    --arg version "$version" \
    '{plugin: {
      pluginId: "boxlite-agent-tooling@boxlite-agent-tooling",
      name: "boxlite-agent-tooling",
      version: $version,
      marketplaceName: "boxlite-agent-tooling",
      installed: $installed,
      enabled: $enabled,
      source: $source,
      installPolicy: "INSTALLED_BY_DEFAULT",
      authPolicy: "ON_INSTALL"
    }} |
    if $installed then
      {installed: [.plugin], available: []}
    else
      {installed: [], available: [.plugin]}
    end'
elif [[ "$1 $2" == "plugin add" ]]; then
  [[ "$3" == "boxlite-agent-tooling@boxlite-agent-tooling" && "$4" == "--json" ]]
  [[ "${FAKE_CODEX_FAIL_PLUGIN_ADD:-0}" != 1 ]] || {
    printf 'fixture plugin failure\n' >&2
    exit 1
  }
  touch "$state/plugin-installed" "$state/plugin-enabled"
  head -n1 "$state/marketplace-version" > "$state/plugin-version"
  printf '{"pluginId":"boxlite-agent-tooling@boxlite-agent-tooling","installed":true,"enabled":true}\n'
else
  printf 'unexpected codex command: %s\n' "$*" >&2
  exit 64
fi
