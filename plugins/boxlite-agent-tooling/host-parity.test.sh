#!/usr/bin/env bash
# One plugin, three hosts — and nothing that keeps them equal except this file.
#
# Claude Code discovers assets by CONVENTION (skills/, agents/, hooks/hooks.json at
# the plugin root), Codex by DECLARATION (.codex-plugin/plugin.json keys), Copilot by
# the generic plugin.json. Those are three independent resolution paths onto what must
# be one asset set, so every parity failure here is silent by construction: each host
# loads whatever its own path finds and has no way to notice the others found more.
# That already happened once — 2b56fc0 shipped 0.1.3 manifests while both versioned
# marketplaces kept advertising 0.1.2, and nothing said so.
#
# What is pinned, and why:
#
#   - The three plugin manifests agree on name/version/description, and the
#     marketplaces advertise the version that actually ships. Versions here are not
#     cosmetic: consumers pin installations by them.
#   - Codex's declared skills/hooks paths resolve to the SAME files Claude Code's
#     conventions discover, through the symlinks AGENTS.md prescribes
#     (skills -> .agents/skills, agents -> .claude/agents).
#   - hooks/hooks.json stays inside the schema BOTH hosts accept. Since 2b56fc0 the
#     stricter parser reads this file too: Codex rejects an unknown key at any depth
#     by loading no hooks at all, without logging a parse error — the whole gate set
#     vanishes on one host and the suite that exercises the scripts directly stays
#     green. Same lesson templates/prompt-rules.test.sh pins for the consumer copies.
#   - Every wired command resolves the plugin root as ${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}
#     — Codex exports the first name, Claude Code the second. A bare single-host
#     variable expands empty on the other host and the hook runs /nonexistent.
#   - Agent specs resolve on every route: Claude Code prefixes the frontmatter `name`
#     with the plugin name, while Codex gets a schema-safe task name plus the exact
#     spec path (subagent.sh doctrine). A rename can strand either host silently.
#   - .codex-plugin/plugin.json declares NO agents key — deliberately. Codex's
#     collaboration.spawn_agent takes no spec parameter; the spec travels by path in
#     the message. Adding the key to "fix the asymmetry" hands a strictly-validating
#     parser an unknown key, and this repository has already paid to learn how that
#     ends. If Codex ever grows agent registration, update this pin consciously.
#
# Run with:  bash plugins/boxlite-agent-tooling/host-parity.test.sh
# Exits non-zero on any failure.
set -uo pipefail

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$PLUGIN/../.." && pwd)"
GENERIC="$PLUGIN/plugin.json"
CLAUDE="$PLUGIN/.claude-plugin/plugin.json"
CODEX="$PLUGIN/.codex-plugin/plugin.json"
HOOKS="$PLUGIN/hooks/hooks.json"
CLAUDE_MKT="$REPO_ROOT/.claude-plugin/marketplace.json"
CODEX_MKT="$REPO_ROOT/.agents/plugins/marketplace.json"
COPILOT_MKT="$REPO_ROOT/.github/plugin/marketplace.json"
CLAUDE_SETTINGS="$REPO_ROOT/.claude/settings.json"
COPILOT_SETTINGS="$REPO_ROOT/.github/copilot/settings.json"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { printf 'jq is required to run these tests\n' >&2; exit 2; }

# Directories resolved through `cd`, not realpath -m: a dangling symlink or a typo'd
# path must FAIL here, never normalise into a plausible-looking string.
resolve_dir() { (cd "$1" 2>/dev/null && pwd -P); }
resolve_file() {
  local dir base
  dir="$(dirname "$1")"; base="$(basename "$1")"
  dir="$(resolve_dir "$dir")" || return 1
  [ -f "$dir/$base" ] || return 1
  printf '%s/%s\n' "$dir" "$base"
}

echo "## One plugin, three manifests — same identity"
for f in "$GENERIC" "$CLAUDE" "$CODEX"; do
  jq -e . "$f" >/dev/null 2>&1 && ok "valid JSON: ${f#"$PLUGIN"/}" \
                                || bad "valid JSON: ${f#"$PLUGIN"/}"
done
for key in name version description; do
  g="$(jq -r ".$key" "$GENERIC")"
  c="$(jq -r ".$key" "$CLAUDE")"
  x="$(jq -r ".$key" "$CODEX")"
  if [ "$g" = "$c" ] && [ "$g" = "$x" ] && [ -n "$g" ] && [ "$g" != "null" ]; then
    ok "same $key everywhere ($g)"
  else
    bad "same $key everywhere (generic: $g, claude: $c, codex: $x)"
  fi
done
VERSION="$(jq -r .version "$GENERIC")"

echo
echo "## Marketplaces advertise the plugin that actually ships"
# The Codex marketplace pins no version, so only the other two can drift — and both
# fields have moved in lockstep with the manifests on every release so far.
check_versioned_marketplace() {  # <label> <file>
  local label="$1" file="$2" v
  for path in '.metadata.version' '.plugins[0].version'; do
    v="$(jq -r "$path" "$file")"
    [ "$v" = "$VERSION" ] && ok "$label: $path is $VERSION" \
                          || bad "$label: $path is $VERSION (got: $v)"
  done
  v="$(jq -r '.plugins[0].name' "$file")"
  [ "$v" = "$(jq -r .name "$GENERIC")" ] && ok "$label: entry names the plugin" \
                                         || bad "$label: entry names the plugin (got: $v)"
  v="$(jq -r '.plugins[0].description' "$file")"
  [ "$v" = "$(jq -r .description "$GENERIC")" ] && ok "$label: entry description matches the manifest" \
                                                || bad "$label: entry description matches the manifest"
  v="$(resolve_dir "$REPO_ROOT/$(jq -r '.plugins[0].source' "$file")")"
  [ "$v" = "$PLUGIN" ] && ok "$label: source resolves to the plugin" \
                       || bad "$label: source resolves to the plugin (got: $v)"
}
check_versioned_marketplace "claude"  "$CLAUDE_MKT"
check_versioned_marketplace "copilot" "$COPILOT_MKT"
v="$(jq -r '.plugins[0].name' "$CODEX_MKT")"
[ "$v" = "$(jq -r .name "$GENERIC")" ] && ok "codex: entry names the plugin" \
                                       || bad "codex: entry names the plugin (got: $v)"
jq -e '
  .plugins[0].source.source == "git-subdir" and
  .plugins[0].source.url == "https://github.com/boxlite-ai/agent-tooling.git" and
  .plugins[0].source.ref == "main" and
  .plugins[0].source.path == "./plugins/boxlite-agent-tooling" and
  .plugins[0].policy.installation == "INSTALLED_BY_DEFAULT" and
  .plugins[0].policy.authentication == "ON_INSTALL" and
  .plugins[0].category == "Developer Tools"
' "$CODEX_MKT" >/dev/null 2>&1 \
  && ok "codex: typed Git source and required install metadata" \
  || bad "codex: typed Git source and required install metadata"
v="$(resolve_dir "$REPO_ROOT/$(jq -r '.plugins[0].source.path' "$CODEX_MKT")")"
[ "$v" = "$PLUGIN" ] && ok "codex: source resolves to the plugin" \
                     || bad "codex: source resolves to the plugin (got: $v)"

echo
echo "## Consumer activation settings use typed GitHub marketplace sources"
for pair in "claude:$CLAUDE_SETTINGS" "copilot:$COPILOT_SETTINGS"; do
  label="${pair%%:*}"; settings="${pair#*:}"
  jq -e '
    .extraKnownMarketplaces["boxlite-agent-tooling"].source.source == "github" and
    .extraKnownMarketplaces["boxlite-agent-tooling"].source.repo == "boxlite-ai/agent-tooling" and
    .extraKnownMarketplaces["boxlite-agent-tooling"].source.ref == "main" and
    .enabledPlugins["boxlite-agent-tooling@boxlite-agent-tooling"] == true
  ' "$settings" >/dev/null 2>&1 \
    && ok "$label: typed GitHub activation source" \
    || bad "$label: typed GitHub activation source"
done

echo
echo "## Every host reaches the same skills tree"
# AGENTS.md: hosts point manifests at the symlink names, never at copies.
[ "$(readlink "$PLUGIN/skills")" = ".agents/skills" ] \
  && ok "skills is a symlink to .agents/skills" \
  || bad "skills is a symlink to .agents/skills (got: $(readlink "$PLUGIN/skills" || echo 'not a symlink'))"
canonical_skills="$(resolve_dir "$PLUGIN/.agents/skills")"
for pair in "generic:$(jq -r .skills "$GENERIC")" "codex:$(jq -r .skills "$CODEX")"; do
  label="${pair%%:*}"; declared="${pair#*:}"
  got="$(resolve_dir "$PLUGIN/$declared")"
  [ "$got" = "$canonical_skills" ] && ok "$label manifest skills resolve to .agents/skills" \
                                   || bad "$label manifest skills resolve to .agents/skills (got: ${got:-unresolvable})"
done
# Claude Code takes the conventional root directory the symlink provides.
[ "$(resolve_dir "$PLUGIN/skills")" = "$canonical_skills" ] \
  && ok "claude convention skills/ resolves to .agents/skills" \
  || bad "claude convention skills/ resolves to .agents/skills"
found=0
for skill_dir in "$PLUGIN"/.agents/skills/*/; do
  [ -d "$skill_dir" ] || continue
  found=$((found + 1))
  [ -f "$skill_dir/SKILL.md" ] && ok "skill has SKILL.md: $(basename "$skill_dir")" \
                               || bad "skill has SKILL.md: $(basename "$skill_dir")"
done
[ "$found" -gt 0 ] && ok "skills tree is not empty ($found skills)" \
                   || bad "skills tree is not empty"

echo
echo "## Every host reaches the same agent specs"
[ "$(readlink "$PLUGIN/agents")" = ".claude/agents" ] \
  && ok "agents is a symlink to .claude/agents" \
  || bad "agents is a symlink to .claude/agents (got: $(readlink "$PLUGIN/agents" || echo 'not a symlink'))"
canonical_agents="$(resolve_dir "$PLUGIN/.claude/agents")"
got="$(resolve_dir "$PLUGIN/$(jq -r .agents "$GENERIC")")"
[ "$got" = "$canonical_agents" ] && ok "generic manifest agents resolve to .claude/agents" \
                                 || bad "generic manifest agents resolve to .claude/agents (got: ${got:-unresolvable})"
found=0
for spec in "$PLUGIN"/.claude/agents/*.md; do
  [ -f "$spec" ] || continue
  found=$((found + 1))
  stem="$(basename "$spec" .md)"
  fm_name="$(awk 'BEGIN{fm=0} NR==1 && /^---$/{fm=1; next} fm==1 && /^---$/{exit} fm==1 && /^name:/{sub(/^name:[[:space:]]*/, ""); print; exit}' "$spec")"
  [ "$fm_name" = "$stem" ] && ok "spec name matches filename: $stem" \
                           || bad "spec name matches filename: $stem (frontmatter says: ${fm_name:-nothing})"
done
[ "$found" -gt 0 ] && ok "agent specs exist ($found specs)" \
                   || bad "agent specs exist"
# The deliberate asymmetry, pinned so nobody "fixes" it into a silent Codex failure.
jq -e 'has("agents") | not' "$CODEX" >/dev/null 2>&1 \
  && ok "codex manifest declares no agents key (specs travel by path — see header)" \
  || bad "codex manifest declares no agents key (specs travel by path — see header)"

plugin_name="$(jq -r .name "$CLAUDE")"
routing="$(
  # shellcheck source=/dev/null
  source "$PLUGIN/.agents/lib/subagent.sh"
  subagent_instruction --agent verdict-auditor --root "$PLUGIN" --task audit
)"
case "$routing" in
  *"Task(subagent_type='$plugin_name:verdict-auditor'"*)
    ok "claude route scopes the agent with the manifest name" ;;
  *) bad "claude route scopes the agent with the manifest name" ;;
esac
case "$routing" in
  *"task_name='verdict_auditor'"*"$PLUGIN/.claude/agents/verdict-auditor.md"*)
    ok "codex route normalizes task_name but preserves the spec path" ;;
  *) bad "codex route normalizes task_name but preserves the spec path" ;;
esac

echo
echo "## hooks/hooks.json — one file, both hosts, both parsers"
hooks_file="$(resolve_file "$HOOKS")"
[ -n "$hooks_file" ] && ok "conventional hooks/hooks.json exists (claude discovery)" \
                     || bad "conventional hooks/hooks.json exists (claude discovery)"
for pair in "generic:$(jq -r .hooks "$GENERIC")" "codex:$(jq -r .hooks "$CODEX")"; do
  label="${pair%%:*}"; declared="${pair#*:}"
  got="$(resolve_file "$PLUGIN/$declared")"
  [ "$got" = "$hooks_file" ] && ok "$label manifest hooks resolve to hooks/hooks.json" \
                             || bad "$label manifest hooks resolve to hooks/hooks.json (got: ${got:-unresolvable})"
done
jq -e . "$HOOKS" >/dev/null 2>&1 && ok "valid JSON" || bad "valid JSON"
# Unknown keys at ANY depth: the silent-rejection schema shared with the templates,
# minus `env` — that allowance exists for .claude/settings.json, not for a plugin file.
unknown="$(jq -r '
  [ (keys_unsorted[] | select(. != "hooks")),
    (.hooks | keys_unsorted[] | select(test("^[A-Z][A-Za-z]*$") | not)),
    (.hooks[][] | keys_unsorted[] | select(IN("hooks","matcher") | not)),
    (.hooks[][].hooks[] | keys_unsorted[]
       | select(IN("type","command","statusMessage","timeout") | not))
  ] | join(",")' "$HOOKS" 2>/dev/null)"
[ -z "$unknown" ] && ok "no unknown keys at any depth" \
                  || bad "no unknown keys at any depth (found: $unknown)"
flattened="$(jq -r '[.hooks[][] | select((.hooks | type) != "array" or (.hooks | length) == 0)] | length' "$HOOKS")"
[ "$flattened" = "0" ] && ok "every event entry nests a non-empty hooks array" \
                       || bad "every event entry nests a non-empty hooks array ($flattened flat entries)"
nontype="$(jq -r '[.hooks[][].hooks[] | select(.type != "command")] | length' "$HOOKS")"
[ "$nontype" = "0" ] && ok "every hook object is type command" \
                     || bad "every hook object is type command ($nontype are not)"

echo
echo "## Every wired command runs on either host"
ROOT_EXPR='${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}'
while IFS= read -r cmd; do
  short="$(printf '%s' "$cmd" | sed -n 's/.*\/\.agents\/hooks\///p' | tr -d '"')"
  case "$cmd" in
    *"$ROOT_EXPR"*) ok "resolves the root for both hosts: ${short:-$cmd}" ;;
    *)              bad "resolves the root for both hosts (got: $cmd)"; continue ;;
  esac
  resolved="${cmd/"$ROOT_EXPR"/$PLUGIN}"
  if [[ "$resolved" =~ \"([^\"]+)\" ]]; then
    script="${BASH_REMATCH[1]}"
    [ -r "$script" ] && ok "wired script exists: ${script#"$PLUGIN"/}" \
                     || bad "wired script exists: ${script#"$PLUGIN"/}"
  else
    bad "command quotes its script path (got: $cmd)"
  fi
done < <(jq -r '.hooks[][].hooks[].command' "$HOOKS")

echo
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
