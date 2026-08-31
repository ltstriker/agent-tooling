#!/usr/bin/env bash
# Tests for .agents/hooks/preflight-pr-review.sh
#
# Covers:
#   1. Command matcher: gh pr create / edit / ready vs. unrelated bash,
#      chained invocations, draft exclusion.
#   2. Gate logic: missing / mismatched / stale / malformed-message /
#      consumed marker paths.
#
# Supported shell boundary: direct simple commands, the literal command/exec/env
# wrappers, and literal eval or bash/sh -c payloads are inspectable. Compound or
# repeated execution, dynamic executable structure, and mutable body-file chains
# are rejected conservatively; this suite does not claim to implement Bash.
#
# Run with:  bash .agents/hooks/preflight-pr-review.test.sh
# Exits non-zero on any failure.
set -uo pipefail

# Resolve from THIS script's location, not the caller's cwd. `git rev-parse
# --show-toplevel` returns whichever checkout the shell sits in, so running this
# suite from another worktree silently tests THAT checkout's copy instead of the
# one shipped beside these tests, and a two-side check reports a false pass.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/.agents/hooks/preflight-pr-review.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CLAUDE_PROJECT_DIR="$TMP"
mkdir -p "$TMP/.agents/state"

# The hook resolves its repo from the AMBIENT cwd, while the marker below is
# keyed to REPO_ROOT's branch and HEAD. Invoked from anywhere else the two
# disagree, every marker looks stale, and the suite reports 42/12 instead of
# 54/0 — green-looking from here, wrong from there. Pin cwd so they match.
cd "$REPO_ROOT" || exit 1
BRANCH="$(git -C "$REPO_ROOT" branch --show-current)"
HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"

pass=0
fail=0

run() {
  local desc="$1" cmd="$2" expect="$3" out decision
  out=$(printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' | "$HOOK")
  if [[ -z "$out" ]]; then
    decision="passthrough"
  else
    decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null || echo "parse_error")
  fi
  if [[ "$decision" == "$expect" ]]; then
    pass=$((pass + 1))
    printf '  PASS  %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf '  FAIL  %s  (got=%s expected=%s)\n' "$desc" "$decision" "$expect"
  fi
}

write_marker() {
  local message="$1"
  jq -nc --arg b "$BRANCH" --arg h "$HEAD_SHA" --arg m "$message" \
        '{branch:$b, head:$h, message:$m}' \
        > "$TMP/.agents/state/pr-reviewed.json"
}

reason_for() {
  printf '%s' "$1" | jq -Rs '{tool_input:{command:.}}' | "$HOOK" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'
}

reason_for_repo() { # repo, project state root, command
  local repo="$1" state_root="$2" cmd="$3"
  printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' \
    | (cd "$repo" && CLAUDE_PROJECT_DIR="$state_root" "$HOOK") \
    | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'
}

assert_reason_budget() {
  local desc="$1" reason="$2" bytes
  bytes="$(LC_ALL=C printf '%s' "$reason" | wc -c | tr -d ' ')"
  if (( bytes <= 1200 )); then
    pass=$((pass + 1)); printf '  PASS  %s (%s bytes)\n' "$desc" "$bytes"
  else
    fail=$((fail + 1)); printf '  FAIL  %s (%s bytes; max 1200)\n' "$desc" "$bytes"
  fi
}

assert_reason_contains() {
  local desc="$1" reason="$2" needle="$3"
  case "$reason" in
    *"$needle"*) pass=$((pass + 1)); printf '  PASS  %s\n' "$desc" ;;
    *) fail=$((fail + 1)); printf '  FAIL  %s (missing: %s)\n' "$desc" "$needle" ;;
  esac
}

echo "## Matcher: should pass through (not a gated gh pr invocation)"
rm -f "$TMP/.agents/state/pr-reviewed.json"
run "ls"                                "ls"                                "passthrough"
run "gh pr list (different subcmd)"     "gh pr list"                        "passthrough"
run "gh pr view (different subcmd)"     "gh pr view 123"                    "passthrough"
run "gh issue create (different verb)"  "gh issue create -t foo"            "passthrough"
run "echo literal mention"              "echo 'gh pr create'"               "passthrough"
run "git push (other hook's domain)"    "git push origin main"              "passthrough"
run "heredoc body mentions trigger"     $'git commit -m "$(cat <<\'EOF\'\nbody mentions `gh pr create`\nEOF\n)"' "passthrough"
run "quoted heredoc substitution stays literal" \
  $'cat <<\'EOF\'\n$(gh pr ready 42)\nEOF'                              "passthrough"
run "backslash-quoted heredoc substitution stays literal" \
  $'cat <<\\EOF\n$(gh pr ready 42)\nEOF'                              "passthrough"
run "multiline w/ backtick trigger"     $'git commit -m "fix bug"\n# `gh pr create`' "passthrough"

echo
echo "## Matcher: draft exclusion (only on create)"
run "gh pr create --draft"              "gh pr create --draft -t wip"       "passthrough"
run "gh pr create -d short flag"        "gh pr create -d -t wip"            "passthrough"
run "-d inside a title is not a draft flag" \
  'gh pr create --title "feat(cli): document the -d option"'               "deny"
run "draft create cannot exempt a later ready command" \
  "gh pr create --draft && gh pr ready 42"                                 "deny"
run "draft create cannot exempt a later non-draft create" \
  'gh pr create --draft; gh pr create --title "not conventional"'          "deny"

echo
echo "## Matcher: should gate"
run "gh pr create direct"               "gh pr create -t foo"               "deny"
run "gh pr edit direct"                 "gh pr edit 42 --body foo"          "deny"
run "gh pr ready direct"                "gh pr ready 42"                    "deny"
run "chained with &&"                   "cd x && gh pr create -t foo"       "deny"
run "chained with ;"                    "echo done; gh pr create -t foo"    "deny"
run "command substitution"              "out=\$(gh pr create -t foo)"       "deny"
run "double-quoted command substitution" 'echo "$(gh pr ready 42)"'          "deny"
run "double-quoted backtick substitution" 'echo "```gh pr ready 42```"'       "deny"
run "unquoted heredoc command substitution" \
  $'cat <<EOF\n$(gh pr ready 42)\nEOF'                                  "deny"
run "line-continuation does not quote heredoc delimiter" \
  $'cat <<\\\nEOF\n$(gh pr ready 42)\nEOF'                               "deny"
run "unquoted heredoc backtick substitution" \
  $'cat <<EOF\n`gh pr ready 42`\nEOF'                                  "deny"
run "escaped substitution stays literal" 'echo "\$(gh pr ready 42)"'         "passthrough"
run "escaped backticks stay literal"      'echo "\`\`\`gh pr ready 42\`\`\`"' "passthrough"
run "command wrapper"                    "command gh pr ready 42"            "deny"
run "absolute gh executable path"         "/opt/homebrew/bin/gh pr ready 42"  "deny"
run "relative gh executable path"         "./tools/gh pr ready 42"            "deny"
run "command-wrapped gh executable path"  "command /opt/bin/gh pr ready 42"   "deny"
run "exec wrapper"                       "exec gh pr ready 42"               "deny"
run "env wrapper"                        "env gh pr ready 42"                "deny"
run "literal bash -c payload"             "bash -c 'gh pr ready 42'"           "deny"
run "literal bash combined -lc payload"   "bash -lc 'gh pr ready 42'"          "deny"
run "literal sh combined -lc payload"     "sh -lc 'gh pr ready 42'"            "deny"
run "literal eval payload"                "eval 'gh pr ready 42'"              "deny"
run "literal heredoc executed by bash" \
  $'bash <<\'EOF\'\ngh pr ready 42\nEOF'                              "deny"
run "expanding heredoc executed by bash" \
  $'bash <<EOF\ngh pr ready 42\nEOF'                                  "deny"
run "dynamic bash -c payload"             'bash -c "$PR_SCRIPT"'               "deny"
run "dynamic eval payload"                'eval "$PR_SCRIPT"'                  "deny"
run "exec combined flags wrapper"         "exec -cl gh pr ready 42"            "deny"
run "builtin eval wrapper"                "builtin eval 'gh pr ready 42'"       "deny"
run "builtin exec wrapper"                "builtin exec gh pr ready 42"         "deny"
run "literal assignments assemble protected argv" \
  'cmd=gh; noun=pr; verb=ready; "$cmd" "$noun" "$verb" 42'                    "deny"
run "literal alias payload"               "alias ship='gh pr ready 42'; ship"   "deny"
run "control-flow prefix"                "if true; then gh pr ready 42; fi"   "deny"
run "time reserved-word prefix"           "time -p gh pr ready 42"             "deny"
run "gh global --repo option"            "gh --repo boxlite-ai/tooling pr ready 42" "deny"
run "dynamic executable word"            '$(printf gh) pr ready 42'            "deny"
run "dynamic executable path"            '"/opt/$GH_DIR/gh" pr ready 42'       "deny"
run "dynamic pr noun"                    'gh $(printf pr) ready 42'            "deny"
run "dynamic protected subcommand"        'gh pr $(printf ready) 42'            "deny"
run "ANSI-C executable word"              "\$'gh' pr ready 42"                 "deny"
run "ANSI-C pr noun"                      "gh \$'pr' ready 42"                 "deny"
run "ANSI-C protected subcommand"          "gh pr \$'ready' 42"                 "deny"
run "env var prefix"                    "FOO=bar gh pr create -t foo"       "deny"
# Newline-before-verb: multi-line Bash with the gh invocation on line 2. Before the
# newline-as-separator fix this SILENTLY PASSED THROUGH (the bypass); must deny now.
run "newline before pr create"          $'cd x\ngh pr create -t foo'         "deny"
run "escaped newline cannot split gh spelling" \
  $'g\\\nh pr ready 42'                                                       "deny"
run "quoted chain text is not a command segment" \
  'echo "documentation: && gh pr ready 42"'                                "passthrough"
run "gh-suffixed executable lookalike"     "/opt/bin/gh-helper pr ready 42"    "passthrough"
run "gh path with trailing component"      "/opt/bin/gh/tool pr ready 42"      "passthrough"

echo
echo "## Gate logic: marker file states"

run_hard_deny() { # description command
  local desc="$1" cmd="$2" out decision marker_state
  write_marker "reviewed: hard deny must preserve this marker"
  out="$(printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' | "$HOOK")"
  decision="$(printf '%s' "$out" \
    | jq -r '.hookSpecificOutput.permissionDecision // "passthrough"' 2>/dev/null \
    || echo parse_error)"
  [[ -f "$TMP/.agents/state/pr-reviewed.json" ]] \
    && marker_state=kept || marker_state=gone
  if [[ "$decision" == deny && "$marker_state" == kept ]]; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  FAIL  %s (decision=%s marker=%s)\n' \
      "$desc" "$decision" "$marker_state"
  fi
}

run_allow_consumes() { # description command
  local desc="$1" cmd="$2" out decision marker_state
  write_marker "reviewed: one literal wrapped operation"
  out="$(printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' | "$HOOK")"
  [[ -z "$out" ]] && decision=passthrough || decision=deny
  [[ -f "$TMP/.agents/state/pr-reviewed.json" ]] \
    && marker_state=kept || marker_state=gone
  if [[ "$decision" == passthrough && "$marker_state" == gone ]]; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  FAIL  %s (decision=%s marker=%s)\n' \
      "$desc" "$decision" "$marker_state"
  fi
}

run_hard_deny "loop body cannot spend one marker repeatedly" \
  'for item in one two; do gh pr ready 42; done'
run_hard_deny "conditional branch cannot spend an execution-ambiguous marker" \
  'if true; then gh pr ready 42; fi'
run_hard_deny "repeated function calls cannot reuse one lexical protected site" \
  'open_pr() { gh pr ready 42; }; open_pr; open_pr'
run_hard_deny "dynamic bash payload cannot spend a marker" \
  'bash -c "$PR_SCRIPT"'
run_hard_deny "dynamic eval payload cannot spend a marker" \
  'eval "$PR_SCRIPT"'
run_hard_deny "bash combined flags cannot spend a marker" \
  "bash -lc 'gh pr ready 42'"
run_hard_deny "sh combined flags cannot spend a marker" \
  "sh -lc 'gh pr ready 42'"
run_hard_deny "exec combined flags cannot spend a marker" \
  'exec -cl gh pr ready 42'
run_hard_deny "builtin eval cannot spend a marker" \
  "builtin eval 'gh pr ready 42'"
run_hard_deny "builtin exec cannot spend a marker" \
  'builtin exec gh pr ready 42'
run_hard_deny "literal assignments cannot assemble and spend a marker" \
  'cmd=gh; noun=pr; verb=ready; "$cmd" "$noun" "$verb" 42'
run_hard_deny "dynamic gh executable path cannot spend a marker" \
  '"/opt/$GH_DIR/gh" pr ready 42'
run_hard_deny "ANSI-C executable structure cannot spend a marker" \
  "\$'gh' pr ready 42"
run_hard_deny "literal alias expansion cannot spend a marker" \
  "alias ship='gh pr ready 42'; ship"
run_allow_consumes "direct exec wrapper spends exactly one marker" \
  'exec gh pr ready 42'
run_allow_consumes "direct env wrapper spends exactly one marker" \
  'env gh pr ready 42'
run_allow_consumes "absolute gh path spends exactly one marker" \
  '/opt/homebrew/bin/gh pr ready 42'
run_allow_consumes "command-wrapped gh path spends exactly one marker" \
  'command ./tools/gh pr ready 42'

write_marker "reviewed: refactor auth middleware"
run "valid marker → allow"              "gh pr create -t foo"               "passthrough"
run "marker consumed on allow"          "gh pr create -t foo"               "deny"

write_marker "reviewed: exactly one protected operation"
multi_pr_out="$(printf '%s' 'gh pr ready 41 && gh pr ready 42' \
  | jq -Rs '{tool_input:{command:.}}' | "$HOOK")"
multi_pr_decision="$(printf '%s' "$multi_pr_out" \
  | jq -r '.hookSpecificOutput.permissionDecision // "passthrough"' 2>/dev/null \
  || echo parse_error)"
if [[ "$multi_pr_decision" == deny \
   && -f "$TMP/.agents/state/pr-reviewed.json" ]]; then
  pass=$((pass + 1)); printf '  PASS  multiple protected operations deny atomically without consuming one marker\n'
else
  fail=$((fail + 1)); printf '  FAIL  multiple protected operations deny atomically without consuming one marker (decision=%s marker=%s)\n' \
    "$multi_pr_decision" "$([[ -f "$TMP/.agents/state/pr-reviewed.json" ]] && echo kept || echo gone)"
fi
run "preserved marker authorizes one retried operation" \
  "gh pr ready 42" "passthrough"

# Both hooks select the same inode before either reaches the consume step. Stable
# selection is not authorization: exactly one atomic consume may spend the marker.
write_marker "reviewed: concurrent marker"
CONCURRENT_PR_BARRIER="$TMP/concurrent-pr-barrier"
CONCURRENT_PR_DATE="$TMP/concurrent-pr-date"
mkdir -p "$CONCURRENT_PR_BARRIER" "$CONCURRENT_PR_DATE"
CONCURRENT_PR_REAL_DATE="$(command -v date)"
printf '%s\n' '#!/usr/bin/env bash' \
  ': > "$TEST_BARRIER/$$"' \
  'deadline=$((SECONDS + 5))' \
  'while (( $(find "$TEST_BARRIER" -type f | wc -l) < 2 )); do' \
  '  (( SECONDS < deadline )) || exit 124' \
  'done' \
  'exec "$TEST_REAL_DATE" "$@"' > "$CONCURRENT_PR_DATE/date"
chmod +x "$CONCURRENT_PR_DATE/date"
concurrent_pr_pids=()
for concurrent_pr_index in 1 2; do
  (printf '%s' 'gh pr ready 42' | jq -Rs '{tool_input:{command:.}}' \
    | PATH="$CONCURRENT_PR_DATE:$PATH" \
        TEST_BARRIER="$CONCURRENT_PR_BARRIER" \
        TEST_REAL_DATE="$CONCURRENT_PR_REAL_DATE" "$HOOK" \
        > "$TMP/concurrent-pr-$concurrent_pr_index.out") &
  concurrent_pr_pids+=("$!")
done
concurrent_pr_wait_status=0
for concurrent_pr_pid in "${concurrent_pr_pids[@]}"; do
  wait "$concurrent_pr_pid" || concurrent_pr_wait_status=$?
done
concurrent_pr_allows=0
concurrent_pr_denies=0
for concurrent_pr_index in 1 2; do
  concurrent_pr_out="$(<"$TMP/concurrent-pr-$concurrent_pr_index.out")"
  if [[ -z "$concurrent_pr_out" ]]; then
    concurrent_pr_allows=$((concurrent_pr_allows + 1))
  elif [[ "$(printf '%s' "$concurrent_pr_out" \
      | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)" == deny ]]; then
    concurrent_pr_denies=$((concurrent_pr_denies + 1))
  fi
done
if [[ "$concurrent_pr_wait_status" -eq 0 \
   && "$concurrent_pr_allows" -eq 1 && "$concurrent_pr_denies" -eq 1 ]]; then
  pass=$((pass + 1)); printf '  PASS  one PR acknowledgment authorizes exactly one concurrent command\n'
else
  fail=$((fail + 1)); printf '  FAIL  one PR acknowledgment authorizes exactly one concurrent command (allows=%s denies=%s wait=%s)\n' \
    "$concurrent_pr_allows" "$concurrent_pr_denies" "$concurrent_pr_wait_status"
fi

# Compose the two races above: both hooks select the old marker, then a newer marker
# replaces the canonical path before either consume. A replacement is not proof that
# either selector spent the old one, so it must never let both commands through.
write_marker "reviewed: concurrent selected marker"
jq -nc --arg b "$BRANCH" --arg h "$HEAD_SHA" \
  '{branch:$b,head:$h,message:"reviewed: concurrent replacement marker"}' \
  > "$TMP/concurrent-replacement-pr-reviewed.json"
CONCURRENT_REPLACEMENT_BARRIER="$TMP/concurrent-replacement-pr-barrier"
CONCURRENT_REPLACEMENT_DATE="$TMP/concurrent-replacement-pr-date"
CONCURRENT_REPLACEMENT_LEADER="$TMP/concurrent-replacement-pr-leader"
mkdir -p "$CONCURRENT_REPLACEMENT_BARRIER" "$CONCURRENT_REPLACEMENT_DATE"
printf '%s\n' '#!/usr/bin/env bash' \
  ': > "$TEST_BARRIER/$$"' \
  'deadline=$((SECONDS + 5))' \
  'while (( $(find "$TEST_BARRIER" -type f | wc -l) < 2 )); do' \
  '  (( SECONDS < deadline )) || exit 124' \
  'done' \
  'if mkdir "$TEST_LEADER" 2>/dev/null; then' \
  '  mv "$TEST_REPLACEMENT" "$TEST_MARKER"' \
  'else' \
  '  sleep 1' \
  'fi' \
  'exec "$TEST_REAL_DATE" "$@"' > "$CONCURRENT_REPLACEMENT_DATE/date"
chmod +x "$CONCURRENT_REPLACEMENT_DATE/date"
concurrent_replacement_pids=()
for concurrent_replacement_index in 1 2; do
  (printf '%s' 'gh pr ready 42' | jq -Rs '{tool_input:{command:.}}' \
    | PATH="$CONCURRENT_REPLACEMENT_DATE:$PATH" \
        TEST_BARRIER="$CONCURRENT_REPLACEMENT_BARRIER" \
        TEST_LEADER="$CONCURRENT_REPLACEMENT_LEADER" \
        TEST_REPLACEMENT="$TMP/concurrent-replacement-pr-reviewed.json" \
        TEST_MARKER="$TMP/.agents/state/pr-reviewed.json" \
        TEST_REAL_DATE="$CONCURRENT_PR_REAL_DATE" "$HOOK" \
        > "$TMP/concurrent-replacement-pr-$concurrent_replacement_index.out") &
  concurrent_replacement_pids+=("$!")
done
concurrent_replacement_wait_status=0
for concurrent_replacement_pid in "${concurrent_replacement_pids[@]}"; do
  wait "$concurrent_replacement_pid" || concurrent_replacement_wait_status=$?
done
concurrent_replacement_allows=0
concurrent_replacement_denies=0
for concurrent_replacement_index in 1 2; do
  concurrent_replacement_out="$(<"$TMP/concurrent-replacement-pr-$concurrent_replacement_index.out")"
  if [[ -z "$concurrent_replacement_out" ]]; then
    concurrent_replacement_allows=$((concurrent_replacement_allows + 1))
  elif [[ "$(printf '%s' "$concurrent_replacement_out" \
      | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)" == deny ]]; then
    concurrent_replacement_denies=$((concurrent_replacement_denies + 1))
  fi
done
concurrent_replacement_message="$(jq -r '.message // "missing"' \
  "$TMP/.agents/state/pr-reviewed.json" 2>/dev/null || echo missing)"
if [[ "$concurrent_replacement_wait_status" -eq 0 \
   && "$concurrent_replacement_allows" -le 1 \
   && "$concurrent_replacement_denies" -ge 1 \
   && "$concurrent_replacement_message" == "reviewed: concurrent replacement marker" ]]; then
  pass=$((pass + 1)); printf '  PASS  concurrent replacement cannot double-spend one PR acknowledgment\n'
else
  fail=$((fail + 1)); printf '  FAIL  concurrent replacement cannot double-spend one PR acknowledgment (allows=%s denies=%s wait=%s marker=%s)\n' \
    "$concurrent_replacement_allows" "$concurrent_replacement_denies" \
    "$concurrent_replacement_wait_status" "$concurrent_replacement_message"
fi
rm -rf "$CONCURRENT_REPLACEMENT_LEADER"
rm -f "$TMP/.agents/state/pr-reviewed.json" "$TMP/concurrent-replacement-pr-reviewed.json"

write_marker "reviewed: edit body fix"
run "valid marker for edit → allow"     "gh pr edit 42"                     "passthrough"

write_marker "yes"
run "malformed message → deny"          "gh pr create -t foo"               "deny"

write_marker ""
run "empty message → deny"              "gh pr create -t foo"               "deny"

write_marker "reviewed: stale"
jq --arg h "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" '.head=$h' \
   "$TMP/.agents/state/pr-reviewed.json" > "$TMP/.agents/state/x.json" \
   && mv "$TMP/.agents/state/x.json" "$TMP/.agents/state/pr-reviewed.json"
run "HEAD mismatch → deny"              "gh pr create -t foo"               "deny"

write_marker "reviewed: branch test"
jq --arg b "some-other-branch" '.branch=$b' \
   "$TMP/.agents/state/pr-reviewed.json" > "$TMP/.agents/state/x.json" \
   && mv "$TMP/.agents/state/x.json" "$TMP/.agents/state/pr-reviewed.json"
run "branch mismatch → deny"            "gh pr create -t foo"               "deny"

write_marker "reviewed: old"
touch -t 202001010000 "$TMP/.agents/state/pr-reviewed.json"
run "stale mtime (>max_age) → deny"     "gh pr create -t foo"               "deny"

echo
echo "## PR state paths are bounded stable regular files"

# A valid marker reached through a symlink is still attacker-selected state. The hook
# must reject it instead of following the link and consuming the pathname.
write_marker "reviewed: symlink marker"
mv "$TMP/.agents/state/pr-reviewed.json" "$TMP/outside-pr-reviewed.json"
ln -s "$TMP/outside-pr-reviewed.json" "$TMP/.agents/state/pr-reviewed.json"
run "symlink acknowledgment marker → deny" "gh pr ready 42" "deny"
rm -f "$TMP/.agents/state/pr-reviewed.json" "$TMP/outside-pr-reviewed.json"

# FIFOs are readable according to `test -r`, but opening one without a writer blocks.
# Exercise the real hook under an alarm so the failure is an observable result, not a
# suite hang.
mkfifo "$TMP/.agents/state/pr-reviewed.json"
fifo_marker_out="$(printf '%s' 'gh pr ready 42' | jq -Rs '{tool_input:{command:.}}' \
  | perl -e '$SIG{ALRM}=sub{exit 124}; alarm 2; exec @ARGV' "$HOOK" 2>/dev/null)"
fifo_marker_rc=$?
fifo_marker_decision="$(printf '%s' "$fifo_marker_out" \
  | jq -r '.hookSpecificOutput.permissionDecision // "parse_error"' 2>/dev/null \
  || echo parse_error)"
if [[ "$fifo_marker_rc" == 0 && "$fifo_marker_decision" == deny ]]; then
  pass=$((pass + 1)); printf '  PASS  FIFO acknowledgment marker fails closed without blocking\n'
else
  fail=$((fail + 1)); printf '  FAIL  FIFO acknowledgment marker fails closed without blocking (rc=%s decision=%s)\n' \
    "$fifo_marker_rc" "$fifo_marker_decision"
fi
rm -f "$TMP/.agents/state/pr-reviewed.json"

# Replace the canonical marker after its content/freshness was selected but before the
# allow path consumes it. The newer marker must survive, and the old selection must not
# authorize because the gate could not atomically spend it at the canonical name.
write_marker "reviewed: selected marker"
jq -nc --arg b "$BRANCH" --arg h "$HEAD_SHA" \
  '{branch:$b,head:$h,message:"reviewed: replacement marker"}' \
  > "$TMP/replacement-pr-reviewed.json"
DATE_WRAP="$TMP/date-wrap"
mkdir -p "$DATE_WRAP"
REAL_DATE="$(command -v date)"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [[ "${1:-}" == "+%s" && -e "$TEST_REPLACEMENT" ]]; then' \
  '  mv "$TEST_REPLACEMENT" "$TEST_MARKER"' \
  'fi' \
  'exec "$TEST_REAL_DATE" "$@"' > "$DATE_WRAP/date"
chmod +x "$DATE_WRAP/date"
replacement_out="$(printf '%s' 'gh pr ready 42' | jq -Rs '{tool_input:{command:.}}' \
  | PATH="$DATE_WRAP:$PATH" TEST_REAL_DATE="$REAL_DATE" \
      TEST_REPLACEMENT="$TMP/replacement-pr-reviewed.json" \
      TEST_MARKER="$TMP/.agents/state/pr-reviewed.json" "$HOOK")"
if [[ -z "$replacement_out" ]]; then
  replacement_decision=passthrough
else
  replacement_decision="$(printf '%s' "$replacement_out" \
    | jq -r '.hookSpecificOutput.permissionDecision // "parse_error"' 2>/dev/null \
    || echo parse_error)"
fi
replacement_message="$(jq -r '.message // "missing"' \
  "$TMP/.agents/state/pr-reviewed.json" 2>/dev/null || echo missing)"
if [[ "$replacement_decision" == deny \
   && "$replacement_message" == "reviewed: replacement marker" ]]; then
  pass=$((pass + 1)); printf '  PASS  marker replacement survives and forces a safe retry\n'
else
  fail=$((fail + 1)); printf '  FAIL  marker replacement survives and forces a safe retry (decision=%s marker=%s)\n' \
    "$replacement_decision" "$replacement_message"
fi
rm -f "$TMP/.agents/state/pr-reviewed.json" "$TMP/replacement-pr-reviewed.json"

echo
echo "## Title check: quoted --title must be a Conventional-Commit subject <=72"
write_marker "reviewed: title cases"
run "bad --title (no type prefix) → deny"  'gh pr create --title "add a cool thing" --body x'  "deny"
run "over-72 --title → deny"               'gh pr create --title "feat(api): this title is far too long and clearly exceeds the seventy-two character ceiling"'  "deny"
run "good --title + valid marker → allow"  'gh pr create --title "feat(api): add a cool thing"'  "passthrough"
run "marker consumed after allow → deny"   'gh pr create --title "feat(api): add a cool thing"'  "deny"

# Flags belonging to an earlier simple command or protected segment must not be
# reused as evidence for a later malformed create. These cases carry a valid
# marker so only segment-local title/body parsing can make them deny.
GRAPH_DECOY=$'## Call graph\n\nBefore\n  old_path (Gate · src/gate.sh:10)\n\nAfter\n  new_path (Gate · src/gate.sh:20)'
printf '%s\n' "$GRAPH_DECOY" > "$TMP/decoy-body.md"
write_marker "reviewed: reject unprotected decoys"
run "earlier unprotected flags cannot validate a later malformed create" \
  "echo --title \"feat(api): decoy\" -F $TMP/decoy-body.md && gh pr create --title \"not conventional\" --body \"prose\"" \
  "deny"
write_marker "reviewed: reject chained decoys"
run "earlier protected flags cannot validate a later malformed create" \
  "gh pr edit 7 --title \"feat(api): decoy\" -F $TMP/decoy-body.md && gh pr create --title \"not conventional\" --body \"prose\"" \
  "deny"

echo
echo "## Body check: a supplied --body must carry the before/after call graph"

GRAPH=$'## Call graph\n\nBefore\n  exec_box (BoxHandle · src/portal/exec.rs:88)\n    open_console (Jailer · src/jailer/console.rs:41)\n\nAfter\n  exec_box (BoxHandle · src/portal/exec.rs:88)\n    open_console (Jailer · src/jailer/console.rs:41)'
FIX_GRAPH=$'## Call graph\n\nBefore\n  exec_box (BoxHandle · src/portal/exec.rs:88)\n    open_console (Jailer · src/jailer/console.rs:41)  ← BUG: returns before the socket binds\n\nAfter\n  exec_box (BoxHandle · src/portal/exec.rs:88)\n    open_console (Jailer · src/jailer/console.rs:41)\n\nFixes #1042'
# The arrow glyph is not part of the contract — ASCII `<-`, or none at all, reads
# the same. What is enforced is the marker's position: on a hop line, in Before.
FIX_ASCII="${FIX_GRAPH/← BUG:/<- BUG:}"
FIX_BARE="${FIX_GRAPH/← BUG:/BUG:}"
FIX_MARK_IN_AFTER=$'## Call graph\n\nBefore\n  exec_box (BoxHandle · src/portal/exec.rs:88)\n    open_console (Jailer · src/jailer/console.rs:41)\n\nAfter\n  exec_box (BoxHandle · src/portal/exec.rs:88)\n    open_console (Jailer · src/jailer/console.rs:41)  ← BUG: returns before the socket binds\n\nFixes #1042'
FIX_MARK_OFF_HOP=$'## Call graph\n\nBefore\n  ← BUG: open_console returns too early\n  exec_box (BoxHandle · src/portal/exec.rs:88)\n    open_console (Jailer · src/jailer/console.rs:41)\n\nAfter\n  exec_box (BoxHandle · src/portal/exec.rs:88)\n    open_console (Jailer · src/jailer/console.rs:41)\n\nFixes #1042'
FIX_DEBUG_ONLY=$'## Call graph\n\nBefore\n  exec_box (BoxHandle · src/portal/exec.rs:88)\n    open_console (Jailer · src/jailer/console.rs:41)  debug: enabled\n\nAfter\n  exec_box (BoxHandle · src/portal/exec.rs:88)\n    open_console (Jailer · src/jailer/console.rs:41)\n\nFixes #1042'
# Each graph needs a hop of its own — one section cannot borrow the other's.
AFTER_PROSE=$'## Call graph\n\nBefore\n  exec_box (BoxHandle · src/portal/exec.rs:88)\n    open_console (Jailer · src/jailer/console.rs:41)\n\nAfter\n  the same hops, but the socket is awaited first'
BEFORE_PROSE=$'## Call graph\n\nBefore\n  exec_box calls open_console, which returns early\n\nAfter\n  exec_box (BoxHandle · src/portal/exec.rs:88)\n    open_console (Jailer · src/jailer/console.rs:41)'
# Free-form prose that happens to name a file and line. A bare `file.ext:NN`
# occurs mid-sentence all the time; only the parenthesised hop shape counts.
PROSE_WITH_LOC=$'## Call graph\n\nBefore\nThis refactor touches exec_box.rs:88 and improves things...\n\nAfter\nThis refactor touches open_console.rs:41 and improves things...'
# A Type half carrying its own parens is ordinary Rust, not a malformed hop.
PARENS_IN_TYPE=$'## Call graph\n\nBefore\n  on_ready (fn(u32) -> u32 · src/portal/exec.rs:88)\n\nAfter\n  on_ready (fn(u32) -> Result<u32> · src/portal/exec.rs:91)'
# Hops sit past the graphs, in a later section — neither graph gets credit.
HOPS_OUTSIDE=$'## Call graph\n\nBefore\n  exec_box calls open_console\n\nAfter\n  exec_box awaits open_console\n\n## Changes\n- exec_box (BoxHandle · src/portal/exec.rs:88)\n- open_console (Jailer · src/jailer/console.rs:41)'
# Graphs drawn in ``` fences, with `##` and `after` lines as graph content:
# inside a fence they are drawing, not markdown structure, so neither may end
# a section early and strand its hops.
FENCED=$'## Call graph\n\nBefore\n\n```text\n## entry\n  exec_box (BoxHandle · src/portal/exec.rs:88)\n    open_console (Jailer · src/jailer/console.rs:41)\n```\n\nAfter\n\n```text\n## entry\n  exec_box (BoxHandle · src/portal/exec.rs:88)\n    open_console (Jailer · src/jailer/console.rs:41)\n```'
# The repo's own worked example must clear the gate it documents — including
# its shape, which wraps both labels AND their hops in one fence. Lifted from
# CONTRIBUTING.md at run time so the doc and the hook cannot drift apart.
CONTRIB_FENCE="$(awk '/^```text$/ {i=1; print; next} i && /^```$/ {print; exit} i {print}' "$REPO_ROOT/CONTRIBUTING.md")"
CONTRIB_BODY="## Call graph"$'\n\n'"$CONTRIB_FENCE"
FEAT='--title "feat(api): add a cool thing"'
FIX='--title "fix(portal): await console bind"'
DOUBLE_QUOTE_BACKSLASH_TITLE='feat(api): \q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q'
DOUBLE_QUOTE_BACKSLASH_BODY=$'## Call Gr\\aph\n\nBefore\n  exec_box (BoxHandle · src/portal/exec.rs:88)\n\nAfter\n  exec_box (BoxHandle · src/portal/exec.rs:91)'

printf '%s' "$GRAPH" > "$TMP/body.md"
printf 'Adds a thing. Tested locally.\n' > "$TMP/prose.md"

# A fresh marker before EVERY case: the allow path consumes it, so without one
# a later case would deny for want of an ack and look like a body-check pass.
run_body() {
  write_marker "reviewed: body cases"
  run "$@"
}

run_body "prose body, no graph → deny"        "gh pr create $FEAT --body \"Adds a thing. Tested locally.\"" "deny"
run_body "double-quote backslashes count in the runtime title" \
  "gh pr create --title \"$DOUBLE_QUOTE_BACKSLASH_TITLE\""                              "deny"
run_body "double-quote backslashes cannot repair an invalid runtime body" \
  "gh pr create $FEAT --body \"$DOUBLE_QUOTE_BACKSLASH_BODY\""                         "deny"
# Shell source can contain a valid-looking graph that a command substitution
# suppresses at runtime. The hook must not validate the source spelling as the
# body GitHub would receive.
DYNAMIC_BODY_COMMAND="gh pr create $FEAT --body \"\$(printf prose"$'\n'": '"$'\n'"$GRAPH"$'\n'"')\""
run_body "dynamic body cannot borrow a graph from non-output substitution source" \
  "$DYNAMIC_BODY_COMMAND"                                                                    "deny"
run_body "graph missing After → deny"         "gh pr create $FEAT --body \"${GRAPH%%$'\n\n'After*}\""       "deny"
run_body "labels but no file:LOC → deny"      "gh pr create $FEAT --body \"## Call graph

Before
  exec_box calls open_console

After
  exec_box awaits open_console\""                                                                           "deny"
run_body "prose-only After → deny"            "gh pr create $FEAT --body \"$AFTER_PROSE\""                  "deny"
run_body "prose-only Before → deny"           "gh pr create $FEAT --body \"$BEFORE_PROSE\""                 "deny"
run_body "hops outside both graphs → deny"    "gh pr create $FEAT --body \"$HOPS_OUTSIDE\""                 "deny"
run_body "prose w/ incidental file:LOC → deny" "gh pr create $FEAT --body \"$PROSE_WITH_LOC\""              "deny"
run_body "unfilled template → deny"           "gh pr create $FEAT --body-file $REPO_ROOT/.github/pull_request_template.md" "deny"
run_body "--fill (no body of its own) → deny" "gh pr create $FEAT --fill"                                   "deny"
run_body "fix: graph w/o BUG marker → deny"   "gh pr create $FIX --body \"$GRAPH\""                         "deny"
run_body "fix: BUG but no issue link → deny"  "gh pr create $FIX --body \"${FIX_GRAPH%%$'\n\n'Fixes*}\""    "deny"
run_body "fix: BUG marked in After → deny"    "gh pr create $FIX --body \"$FIX_MARK_IN_AFTER\""             "deny"
run_body "fix: BUG off any hop line → deny"   "gh pr create $FIX --body \"$FIX_MARK_OFF_HOP\""              "deny"
run_body "fix: 'debug:' is not a marker → deny" "gh pr create $FIX --body \"$FIX_DEBUG_ONLY\""              "deny"
run_body "--body-file prose → deny"           "gh pr create $FEAT --body-file $TMP/prose.md"                "deny"
run_body "--body-file=prose → deny"           "gh pr create $FEAT --body-file=$TMP/prose.md"                "deny"
run_body "-Fprose → deny"                     "gh pr create $FEAT -F$TMP/prose.md"                          "deny"

mv "$TMP/body.md" "$TMP/outside-body.md"
ln -s "$TMP/outside-body.md" "$TMP/body.md"
run_body "symlink --body-file → deny"          "gh pr create $FEAT --body-file $TMP/body.md"                 "deny"
rm -f "$TMP/body.md" "$TMP/outside-body.md"

mkfifo "$TMP/body.md"
write_marker "reviewed: FIFO body"
fifo_body_out="$(printf '%s' "gh pr create $FEAT --body-file $TMP/body.md" \
  | jq -Rs '{tool_input:{command:.}}' \
  | perl -e '$SIG{ALRM}=sub{exit 124}; alarm 2; exec @ARGV' "$HOOK" 2>/dev/null)"
fifo_body_rc=$?
fifo_body_decision="$(printf '%s' "$fifo_body_out" \
  | jq -r '.hookSpecificOutput.permissionDecision // "parse_error"' 2>/dev/null \
  || echo parse_error)"
if [[ "$fifo_body_rc" == 0 && "$fifo_body_decision" == deny ]]; then
  pass=$((pass + 1)); printf '  PASS  FIFO body file fails closed without blocking\n'
else
  fail=$((fail + 1)); printf '  FAIL  FIFO body file fails closed without blocking (rc=%s decision=%s)\n' \
    "$fifo_body_rc" "$fifo_body_decision"
fi
rm -f "$TMP/body.md" "$TMP/.agents/state/pr-reviewed.json"

printf '%s\n' "$GRAPH" > "$TMP/body.md"
awk 'BEGIN { for (i = 0; i < 1100000; i++) printf "x" }' >> "$TMP/body.md"
run_body "oversized --body-file → deny"        "gh pr create $FEAT --body-file $TMP/body.md"                 "deny"
printf '%s' "$GRAPH" > "$TMP/body.md"

run_hard_deny "compound mutation cannot invalidate an inspected body file" \
  "printf prose > $TMP/body.md; gh pr create $FEAT --body-file $TMP/body.md"
run_hard_deny "same-command redirection cannot truncate an inspected body file" \
  "gh pr create $FEAT --body-file $TMP/body.md > $TMP/body.md"

run_body "gh pr ready (no body flag) → allow" "gh pr ready 42"                                              "passthrough"
run_body "valid graph body → allow"           "gh pr create $FEAT --body \"$GRAPH\""                        "passthrough"
run_body "fenced graphs w/ '##' inside → allow" "gh pr create $FEAT --body '$FENCED'"                     "passthrough"
run_body "CONTRIBUTING.md's own example → allow" "gh pr create $FIX --body '$CONTRIB_BODY'"                "passthrough"
run_body "parens inside the Type half → allow" "gh pr create $FEAT --body \"$PARENS_IN_TYPE\""              "passthrough"
run_body "--body-file with graph → allow"     "gh pr create $FEAT --body-file $TMP/body.md"                 "passthrough"
run_body "fix: graph + BUG + issue → allow"   "gh pr create $FIX --body \"$FIX_GRAPH\""                     "passthrough"
run_body "fix: ASCII '<- BUG:' → allow"       "gh pr create $FIX --body \"$FIX_ASCII\""                     "passthrough"
run_body "fix: bare 'BUG:' (no arrow) → allow" "gh pr create $FIX --body \"$FIX_BARE\""                     "passthrough"

echo
echo "## Denial reasons are compact but preserve the typed-ack contract"
rm -f "$TMP/.agents/state/pr-reviewed.json"
long_tail="$(printf '%04096d' 0 | tr 0 x)"
ack_reason="$(reason_for "gh pr create -t foo $long_tail")"
assert_reason_budget "missing-ack reason stays bounded even for a long command" "$ack_reason"
for contract in "AskUserQuestion" "request_user_input" "free-form Other text" \
                "Claude calls it notes" "reviewed:" \
                ".agents/state/pr-reviewed.json" '"branch"' '"head"' '"message"' \
                "Abort" "Show me the diff" "Never infer" "Never fabricate"; do
  assert_reason_contains "ack reason keeps '$contract'" "$ack_reason" "$contract"
done

# A long but valid ref used to push the rendered reason over its cap. The generic
# fallback then removed the only instructions capable of satisfying the gate.
long_segment="$(printf '%0180d' 0 | tr 0 b)"
long_branch="$long_segment/$long_segment/$long_segment/$long_segment"
LONG_REPO="$TMP/long-branch-repo"
LONG_STATE="$TMP/long-branch-state"
git init -q -b "$long_branch" "$LONG_REPO"
git -C "$LONG_REPO" -c user.email=t@t -c user.name=t \
  commit -q --allow-empty -m init
mkdir -p "$LONG_STATE/.agents/state"
long_reason="$(reason_for_repo "$LONG_REPO" "$LONG_STATE" 'gh pr ready 42')"
assert_reason_budget "long-ref fallback stays bounded" "$long_reason"
for contract in "AskUserQuestion" "request_user_input" "reviewed:" \
                ".agents/state/pr-reviewed.json" '"branch"' '"head"' '"message"' \
                "Then retry" "Never infer" "Never fabricate"; do
  assert_reason_contains "long-ref fallback keeps '$contract'" "$long_reason" "$contract"
done
long_head="$(git -C "$LONG_REPO" rev-parse HEAD)"
jq -nc --arg branch "$long_branch" --arg head "$long_head" \
  '{branch:$branch,head:$head,message:"reviewed: long branch protocol"}' \
  > "$LONG_STATE/.agents/state/pr-reviewed.json"
long_retry="$(printf '%s' 'gh pr ready 42' | jq -Rs '{tool_input:{command:.}}' \
  | (cd "$LONG_REPO" && CLAUDE_PROJECT_DIR="$LONG_STATE" "$HOOK"))"
if [[ -z "$long_retry" && ! -e "$LONG_STATE/.agents/state/pr-reviewed.json" ]]; then
  pass=$((pass + 1)); printf '  PASS  long-ref fallback protocol reaches a successful retry\n'
else
  fail=$((fail + 1)); printf '  FAIL  long-ref fallback protocol reaches a successful retry\n'
fi

write_marker "reviewed: stale head"
jq '.head="deadbeef"' "$TMP/.agents/state/pr-reviewed.json" \
  > "$TMP/.agents/state/pr-reviewed.next.json"
mv "$TMP/.agents/state/pr-reviewed.next.json" "$TMP/.agents/state/pr-reviewed.json"
stale_reason="$(reason_for 'gh pr create -t foo')"
assert_reason_budget "state-mismatch reason stays bounded" "$stale_reason"
assert_reason_contains "state-mismatch keeps native input route" \
  "$stale_reason" "request_user_input"
assert_reason_contains "state-mismatch keeps typed format" "$stale_reason" "reviewed:"

write_marker "yes"
malformed_reason="$(reason_for 'gh pr create -t foo')"
assert_reason_budget "malformed-marker reason stays bounded" "$malformed_reason"
assert_reason_contains "malformed-marker keeps native input route" \
  "$malformed_reason" "AskUserQuestion"
assert_reason_contains "malformed-marker keeps typed format" "$malformed_reason" "reviewed:"

assert_reason_budget "title denial stays bounded" \
  "$(reason_for 'gh pr create --title "add a cool thing"')"

write_marker "reviewed: graph body"
assert_reason_budget "graph denial stays bounded" \
  "$(reason_for 'gh pr create --title "feat(api): add thing" --body "prose"')"

echo
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
