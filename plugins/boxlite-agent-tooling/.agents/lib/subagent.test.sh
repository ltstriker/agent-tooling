#!/usr/bin/env bash
# Tests for .agents/lib/subagent.sh
#
# The library's whole contract is the text it prints, because a hook cannot invoke a
# built-in — only name it. So the tests are mostly about what the emitted block does
# and does not say:
#
#   1. Both hosts are always offered. The moment one route can go missing, the gate is
#      back to deciding which host it is on, which is the bug this replaced.
#   2. NOTHING in here reads the environment to choose. A grep guards that directly,
#      because the regression would be silent — a host-sniffing branch still emits a
#      perfectly plausible-looking instruction, just the wrong one.
#   3. Every agent name the gates reference resolves to a real spec file. The Codex
#      route cites that path for the subagent to read, so a rename upstream turns into
#      an instruction pointing at nothing, and only a test can see it from here.
#
# Run with:  bash .agents/lib/subagent.test.sh
# Exits non-zero on any failure.
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$LIB_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/subagent.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
check()    { has "$2" "$3" && ok "$1" || bad "$1 (missing: $2)"; }
check_no() { has "$2" "$3" && bad "$1 (present: $2)" || ok "$1"; }

echo "## Both hosts are always offered"
out="$(subagent_instruction --agent verdict-auditor --root "$PLUGIN_ROOT" --task 'audit my turn')"
check    "names the Claude Code route"  "Claude Code"                 "$out"
check    "names the Codex route"        "Codex"                       "$out"
check    "uses Task() for Claude"       "Task(subagent_type='verdict-auditor'" "$out"
check    "uses spawn_agent for Codex"   "collaboration.spawn_agent("  "$out"
check    "carries the task text"        "audit my turn"               "$out"
# A backgrounded audit lets the turn end before the artifact lands, and the gate fires
# again on the way out — the re-block loop this wording exists to prevent.
check    "demands a synchronous run"    "SYNCHRONOUSLY"               "$out"
check    "spells out run_in_background" "run_in_background: false"    "$out"

echo
echo "## The Codex route points the subagent at the real spec"
# Codex has no spec parameter, so the procedure travels by path. If it pointed at a
# file that does not exist, the subagent would improvise a procedure and still write
# something confident.
check "cites the spec path" "$PLUGIN_ROOT/.claude/agents/verdict-auditor.md" "$out"
# ...and it must be cited, not pasted: these specs are 100+ lines and this block is
# injected on every blocked attempt.
lines="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
[ "$lines" -lt 30 ] && ok "block stays compact ($lines lines, spec referenced not inlined)" \
                    || bad "block stays compact ($lines lines — is the spec being inlined?)"

echo
echo "## Optional sections appear only when asked for"
check_no "no headless route unless requested" "git hook, CI"  "$out"
check_no "no artifact clause unless requested" "not you — writes" "$out"

full="$(subagent_instruction --agent commit-push-auditor --root "$PLUGIN_ROOT" \
          --task 'audit this commit' --description 'CLAUDE.md audit' \
          --artifact '.agents/state/last-audit.json' \
          --headless "bash '$PLUGIN_ROOT/.agents/hooks/run-commit-push-audit.sh' commit '<cmd>'")"
check "headless route appears"        "git hook, CI"                     "$full"
check "headless command appears"      "run-commit-push-audit.sh"         "$full"
check "artifact clause appears"       ".agents/state/last-audit.json"    "$full"
check "description reaches Task()"    "description='CLAUDE.md audit'"    "$full"
# The anti-cheating line is the reason the artifact clause exists at all.
check "forbids self-written verdicts" "Do not write or hand-edit"        "$full"

echo
echo "## Usage errors fail loudly rather than emitting a half-instruction"
# A gate that miswires this must break in tests, not ship an instruction naming nothing.
for args in "--agent a --root b" "--agent a --task t" "--root b --task t"; do
  # shellcheck disable=SC2086
  out_err="$(subagent_instruction $args 2>/dev/null)"; rc=$?
  [ "$rc" = "2" ] && [ -z "$out_err" ] && ok "rejects incomplete args: $args" \
                                       || bad "rejects incomplete args: $args (rc=$rc)"
done
out_err="$(subagent_instruction --agent a --root b --task t --bogus x 2>/dev/null)"; rc=$?
[ "$rc" = "2" ] && ok "rejects an unknown option" || bad "rejects an unknown option (rc=$rc)"

echo
echo "## Frontmatter never reaches the model as procedure"
# name/description/tools/model are registration metadata. Fed to a model as if it were
# instruction, the tool list reads like permission to use exactly those tools.
printf -- '---\nname: x\ntools: Read, Bash\n---\nREAL PROCEDURE\n' > "$TMP/spec.md"
stripped="$(subagent_strip_frontmatter "$TMP/spec.md")"
check    "keeps the body"        "REAL PROCEDURE" "$stripped"
check_no "drops the name field"  "name: x"        "$stripped"
check_no "drops the tools field" "tools: Read"    "$stripped"
# A spec with no frontmatter must survive intact rather than losing its first lines.
printf 'JUST A BODY\nsecond line\n' > "$TMP/plain.md"
plain="$(subagent_strip_frontmatter "$TMP/plain.md")"
check "passes a frontmatter-less spec through" "JUST A BODY" "$plain"
check "keeps its later lines too"              "second line" "$plain"

echo
echo "## No host detection anywhere in the library"
# The regression this guards is silent: a host-sniffing branch still emits a plausible
# instruction, just the wrong one on one of the two hosts.
code_only="$(sed 's/#.*//' "$LIB_DIR/subagent.sh")"
if printf '%s' "$code_only" | grep -qE 'CODEX_SANDBOX|CLAUDECODE|CLAUDE_PLUGIN_ROOT|PLUGIN_ROOT=|command -v (claude|codex)'; then
  bad "library never sniffs the host"
  printf '%s' "$code_only" | grep -nE 'CODEX_SANDBOX|CLAUDECODE|CLAUDE_PLUGIN_ROOT|PLUGIN_ROOT=|command -v (claude|codex)' | sed 's/^/        offending: /'
else
  ok "library never sniffs the host"
fi

echo
echo "## Every referenced spec exists on disk"
for agent in verdict-auditor commit-push-auditor; do
  spec="$(subagent_spec_path "$agent" "$PLUGIN_ROOT")"
  [ -r "$spec" ] && ok "spec exists: $agent" || bad "spec exists: $agent ($spec)"
done

echo
echo "## Prompts load from disk and fill their placeholders"
mkdir -p "$TMP/.agents/prompts"
printf -- '---\nname: t\nplaceholders: who\n---\nHello {{who}}, twice: {{who}}.\n' \
  > "$TMP/.agents/prompts/t.md"
out="$(subagent_prompt t "$TMP" "who=world")"
check    "substitutes a placeholder"        "Hello world"  "$out"
check    "substitutes every occurrence"     "twice: world" "$out"
check_no "frontmatter never reaches output" "placeholders:" "$out"

# Values are branch names, paths and commit text. sed would choke on & and \1; bash
# string replacement does not, and nothing here is ever eval'd.
out="$(subagent_prompt t "$TMP" 'who=a&b\1$(touch '"$TMP"'/PWNED)')"
check "passes shell/sed metacharacters through as text" 'a&b\1$(touch' "$out"
[ -e "$TMP/PWNED" ] && bad "a substituted value cannot execute" || ok "a substituted value cannot execute"

# A substituted VALUE may legitimately contain {{ }}: one of them is sanitized diff
# text, so any repository with a Vue, Handlebars, Jinja, Mustache, or Go template in
# its change set puts template syntax straight into the prompt. Validating after
# substitution read that as an unfilled placeholder and failed the commit audit citing
# a placeholder nobody wrote — a repo blocked from committing by its own frontend.
out="$(subagent_prompt t "$TMP" 'who=<div>{{ user.name }}</div>')"; rc=$?
[ "$rc" = "0" ] && ok "a value containing {{ }} is not mistaken for a placeholder" \
                || bad "a value containing {{ }} is not mistaken for a placeholder (rc=$rc)"
check "the templated value survives verbatim" "{{ user.name }}" "$out"

echo
echo "## An unfilled placeholder is an error, not a literal handed to a model"
# The failure this prevents is quiet: a model given the text "{{branch}}" treats it as
# a value and answers confidently about nothing.
out="$(subagent_prompt t "$TMP" 2>/dev/null)"; rc=$?
[ "$rc" = "3" ] && [ -z "$out" ] && ok "missing value exits 3 and prints nothing" \
                                 || bad "missing value exits 3 and prints nothing (rc=$rc)"
err="$(subagent_prompt t "$TMP" 2>&1 >/dev/null)"
check "names the placeholder it could not fill" "{{who}}" "$err"
# Named from the TEMPLATE, so the message stays accurate no matter what the values hold.
check "says a value was not supplied"          "no value supplied"  "$err"

out="$(subagent_prompt nope "$TMP" 2>/dev/null)"; rc=$?
[ "$rc" = "2" ] && ok "a missing prompt document exits 2" || bad "a missing prompt document exits 2 (rc=$rc)"

echo
echo "## Every shipped prompt is loadable and fully declared"
# A prompt whose {{placeholders}} the caller does not supply fails at RUN time, inside
# a gate, in whatever session happened to trigger it. Declaring them in frontmatter and
# checking the two agree moves that failure here.
shopt -s nullglob
for p in "$PLUGIN_ROOT"/.agents/prompts/*.md; do
  name="$(basename "$p" .md)"
  # Read the placeholders key line-by-line and stop at the next unindented key. An
  # earlier version flattened the whole frontmatter first, which glued `description`
  # onto the final placeholder and made all four prompts look mismatched.
  declared="$(awk '
      NR==1 && /^---$/            {f=1; next}
      f==1 && /^---$/             {exit}
      f==1 && /^placeholders:/    {cap=1; sub(/^placeholders:[[:space:]]*/, ""); print; next}
      f==1 && cap==1 && /^[[:space:]]/ {print; next}
      f==1 && cap==1              {cap=0}
    ' "$p" | tr ',' '\n' | tr -d ' ' | grep -v '^$' | sort -u)"
  used="$(subagent_strip_frontmatter "$p" | grep -o '{{[A-Za-z_][A-Za-z0-9_]*}}' \
          | tr -d '{}' | sort -u)"
  if [ "$declared" = "$used" ]; then
    ok "$name: declared placeholders match the body"
  else
    bad "$name: declared placeholders match the body
        declared: $(printf '%s' "$declared" | tr '\n' ' ')
        used:     $(printf '%s' "$used" | tr '\n' ' ')"
  fi
  # Frontmatter must name where it is consumed, or an orphaned prompt is invisible.
  grep -q '^used-by:' "$p" && ok "$name: declares its call site" \
                           || bad "$name: declares its call site"
done
shopt -u nullglob

echo
echo "## The gates no longer carry prompts as shell string literals"
# The point of the extraction: a prompt in a heredoc inherits shell expansion rules and
# cannot be reviewed without reading bash quoting around it.
for hook in preflight-commit-push preflight-verdict-check; do
  inline="$(grep -c -- "--task \"Audit" "$PLUGIN_ROOT/.agents/hooks/$hook.sh" || true)"
  [ "$inline" = "0" ] && ok "$hook.sh loads its task from a document" \
                      || bad "$hook.sh loads its task from a document ($inline inline)"
done

echo
echo "## No script keeps a second copy of a prompt"
# This is the regression the extraction exists to prevent, and it is not theoretical:
# a "safety" fallback copy of verdict-runner.md lived in run-verdict-audit.sh for
# exactly one commit and had ALREADY drifted from the document — the document gained a
# clarification the copy did not. A stale prompt is the worst shape of failure here,
# because it never announces itself: the audit runs, returns confidently, and grades
# against a standard that was superseded.
#
# Matching on distinctive opening phrases rather than whole bodies, so reflowing a
# document does not fail this while a genuine re-paste still does.
for probe in \
  "You are the headless equivalent" \
  "Audit the final turn in the session" \
  "each claim it presents as established" \
  "advisories NEVER make a verdict FAIL"; do
  hits="$(grep -rl -- "$probe" "$PLUGIN_ROOT/.agents/hooks/" 2>/dev/null | grep -v '\.test\.sh$' || true)"
  if [ -z "$hits" ]; then
    ok "no script inlines: \"${probe:0:34}...\""
  else
    bad "no script inlines: \"${probe:0:34}...\"
        found in: $(printf '%s' "$hits" | xargs -n1 basename | tr '\n' ' ')"
  fi
done

# And the text must still exist SOMEWHERE — a probe passing because the prompt was
# deleted outright would be a silent hole, not a pass.
for probe in "You are the headless equivalent" "Audit the final turn in the session"; do
  grep -rq -- "$probe" "$PLUGIN_ROOT/.agents/prompts/" 2>/dev/null \
    && ok "still present in .agents/prompts/: \"${probe:0:30}...\"" \
    || bad "still present in .agents/prompts/: \"${probe:0:30}...\""
done

echo
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
