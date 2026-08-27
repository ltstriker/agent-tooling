#!/usr/bin/env bash
# Tests for .agents/hooks/preflight-verdict-check.sh (the Stop-stage verdict gate).
#
# The hook is DETECTION-TRIGGERED, with finding-driven loops only:
#   - no dossier + the turn asserts a verdict ("root cause is X",
#     "tests pass", "prod looks healthy", "done")      -> block: audit it
#   - no dossier + chat / question / no transcript     -> allow
#   - present PASS/IN_PROGRESS, fresh + matching       -> allow (consumed)
#   - present FAIL, fresh + matching                   -> block with findings
#     (the ONE legitimate loop: persists until re-audited clean)
#   - present but stale / mismatched binding           -> DISCARD, re-detect
#     (bookkeeping never blocks — that was the meaningless-loop class)
# Each case builds a throwaway git repo with an optional fake transcript and
# dossier, runs the hook there (cwd + CLAUDE_PROJECT_DIR pointed at it), and
# asserts allow vs block.
#
# Stop contract: block = stdout {"decision":"block"}; allow = exit 0 with either
# empty stdout or {"continue":true, systemMessage:...} — the systemMessage is the
# human-only triage announcement (the model never sees it; documented hook
# contract). decide() treats any non-block output as allow.
#
# Run with:  bash .agents/hooks/preflight-verdict-check.test.sh
# Exits non-zero on any failure.
set -uo pipefail

# Hermetic baseline: drop any ambient VERDICT_GATE_HARD_BLOCK so absence is the
# starting point regardless of the caller's environment. Absent now means HARD, so
# every case that wants soft mode sets VERDICT_GATE_HARD_BLOCK=0 explicitly rather
# than relying on the unset — see the unset⇒block case below, which pins that.
unset VERDICT_GATE_HARD_BLOCK

# Hermetic triage: force the classifier into UNKNOWN (command fails) so every case
# below exercises the deterministic regex fallback unless a case overrides the stub.
# Without this, a machine with the `claude` CLI would call a live model mid-suite.
export VERDICT_CLASSIFIER_CMD='false'
# Its matched seam. Left ambient it replaces the text every case asserts on, so the
# suite grades a transcript it never wrote — 29/25 with `true`, 46/8 with `cat`.
unset VERDICT_EXTRACTOR_CMD

# Resolve from THIS script's location, not the caller's cwd. `git rev-parse
# --show-toplevel` returns whichever checkout the shell sits in, so running this
# suite from another worktree silently tests THAT checkout's copy instead of the
# one shipped beside these tests, and a two-side check reports a false pass.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/.agents/hooks/preflight-verdict-check.sh"
CANCEL_HOOK="$REPO_ROOT/.agents/hooks/cancel-verdict-audit.sh"

pass=0
fail=0

kill_test_pids() {  # signal pid...
  local signal="$1" pid; shift
  for pid in "$@"; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill "-$signal" "$pid" 2>/dev/null || true
  done
}

dependency_bin="$(mktemp -d)"
ln -s "$(command -v bash)" "$dependency_bin/bash"
ln -s "$(command -v jq)" "$dependency_bin/jq"
missing_perl_err="$(PATH="$dependency_bin" bash "$HOOK" </dev/null 2>&1)"
missing_perl_rc=$?
if [[ "$missing_perl_rc" == 2 \
   && "$missing_perl_err" == *"required dependency not found: perl"* ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "missing Perl fails closed with an actionable Stop-hook error"
else
  fail=$((fail+1)); printf '  FAIL  %s  (rc=%s err=%s)\n' \
    "missing Perl silently bypassed the verdict gate" "$missing_perl_rc" "$missing_perl_err"
fi
rm -rf "$dependency_bin"

# Fresh git repo with one committed production file.
setup() {
  local d; d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.test
  git -C "$d" config user.name tester
  mkdir -p "$d/src"
  printf 'pub fn base() {}\n' > "$d/src/lib.rs"
  # Mirror the real repo, which ignores the whole state dir: gate-written state must
  # never enter the working-tree hash, or `git add -A` folds it into the very hash the
  # dossier is keyed to and self-invalidates a just-passed audit. Ignoring the
  # directory (not one file) keeps this true for every marker the gates write —
  # last-verdict.prev.json, verdict-last-uuid, verdict-decisions.log.
  printf '.agents/state/\n' > "$d/.gitignore"
  git -C "$d" add -A
  git -C "$d" commit -qm base
  printf '%s' "$d"
}

# Same content-addressed tree hash the hook computes (keep in sync).
tree_hash_of() {
  local repo="$1" idx; idx="$(mktemp)"
  GIT_INDEX_FILE="$idx" git -C "$repo" read-tree HEAD >/dev/null 2>&1
  GIT_INDEX_FILE="$idx" git -C "$repo" add -A >/dev/null 2>&1
  GIT_INDEX_FILE="$idx" git -C "$repo" write-tree 2>/dev/null
  rm -f "$idx"
}

# Fake session transcript whose LAST assistant message is $2 (prior assistant
# messages may follow as $3..; they are written first). Mirrors the real JSONL
# shape: {"type":"assistant","uuid":..., "message":{"content":[{"type":"text",...}]}}.
# The last message gets uuid "uuid-last", earlier ones "uuid-<n>".
write_transcript() {
  local repo="$1" last="$2"; shift 2
  : > "$repo/transcript.jsonl"
  local earlier n=0
  for earlier in "$@"; do
    n=$((n+1))
    jq -nc --arg t "$earlier" --arg u "uuid-$n" \
      '{type:"assistant", uuid:$u, message:{content:[{type:"text",text:$t}]}}' >> "$repo/transcript.jsonl"
  done
  jq -nc --arg t "$last" --arg u "uuid-last" \
    '{type:"assistant", uuid:$u, message:{content:[{type:"text",text:$t}]}}' >> "$repo/transcript.jsonl"
}

# Codex-format transcript (rollout JSONL): response_item / payload.role=assistant /
# content[].output_text, no per-record id. Same last-message-wins semantics.
write_codex_transcript() {
  local repo="$1" last="$2"
  jq -nc --arg t "$last" \
    '{type:"response_item", payload:{type:"message", role:"assistant", content:[{type:"output_text", text:$t}]}}' \
    > "$repo/transcript.jsonl"
}

# An INVENTED schema no harness uses today — proves new agents work with zero hook
# changes as long as they follow the conventions (role=assistant somewhere, text
# under `text` keys in *text-typed blocks, JSONL).
write_future_agent_transcript() {
  local repo="$1" last="$2"
  jq -nc --arg t "$last" \
    '{kind:"turn", actor:{role:"assistant"}, output:{parts:[{type:"rich_text", text:$t}]}}' \
    > "$repo/transcript.jsonl"
}

# The content-derived message identity the hook records (keep formula in sync).
cksum_of() { printf 'cksum-%s' "$(printf '%s' "$1" | cksum | tr ' \t' '--')"; }

# Append records to an existing fixture transcript: a REAL user message (turn
# boundary) or a further assistant text (same turn as its neighbors).
append_user() {
  jq -nc --arg t "$2" '{type:"user", message:{content:[{type:"text",text:$t}]}}' >> "$1/transcript.jsonl"
}
append_assistant() {
  jq -nc --arg t "$2" '{type:"assistant", message:{content:[{type:"text",text:$t}]}}' >> "$1/transcript.jsonl"
}
# Tool results ride user-role records. The array shape (produced by Read, Agent,
# ToolSearch, MCP tools) nests text-typed blocks INSIDE the tool_result — it must
# NOT read as a turn boundary.
append_tool_result_array() {
  jq -nc --arg t "$2" \
    '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:"tu1", content:[{type:"text", text:$t}]}]}}' \
    >> "$1/transcript.jsonl"
}
append_tool_result_string() {
  jq -nc --arg t "$2" \
    '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:"tu1", content:$t}]}}' \
    >> "$1/transcript.jsonl"
}

# Write a dossier; tree_hash defaults to the repo's current working-tree hash.
write_verdict() {
  local repo="$1" verdict="$2" findings="$3" tree="${4:-$(tree_hash_of "$1")}"
  local br hd; br="$(git -C "$repo" branch --show-current)"; hd="$(git -C "$repo" rev-parse HEAD)"
  mkdir -p "$repo/.agents/state"
  jq -nc --arg b "$br" --arg h "$hd" --arg t "$tree" --arg v "$verdict" --argjson f "$findings" \
    '{branch:$b, head:$h, tree_hash:$t, verdict:$v, proof:[], findings:$f}' \
    > "$repo/.agents/state/last-verdict.json"
}

# Run the hook inside repo for an exact Stop payload.
run_payload_hook() {
  local repo="$1" payload="$2"
  # Decision-logic cases run in HARD mode so a block condition is observable as
  # decision:block. Soft mode is covered in its own section below.
  printf '%s' "$payload" \
    | ( cd "$repo" && CLAUDE_PROJECT_DIR="$repo" VERDICT_GATE_HARD_BLOCK=1 bash "$HOOK" ) \
      2>/dev/null
}

decision_from_output() {
  local out="$1" d
  if [[ -z "$out" ]]; then
    printf 'allow'
  else
    d="$(printf '%s' "$out" | jq -r '.decision // "allow"' 2>/dev/null || echo parse_error)"
    [[ "$d" == "block" ]] && printf 'block' || printf 'allow'
  fi
}

decide_payload() {
  local repo="$1" payload="$2" out
  out="$(run_payload_hook "$repo" "$payload")"
  decision_from_output "$out"
}

# Uses the repo's fake transcript when present, /dev/null otherwise.
decide() {
  local repo="$1" tp="/dev/null" payload
  [[ -f "$repo/transcript.jsonl" ]] && tp="$repo/transcript.jsonl"
  payload="$(jq -nc --arg p "$tp" '{transcript_path:$p, hook_event_name:"Stop"}')"
  decide_payload "$repo" "$payload"
}

check() {  # desc  repo  expect
  local desc="$1" repo="$2" expect="$3" got
  got="$(decide "$repo")"
  if [[ "$got" == "$expect" ]]; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  FAIL  %s  (got=%s expected=%s)\n' "$desc" "$got" "$expect"
  fi
}

# Assert the dossier file is gone (consumed on allow, or discarded on mismatch).
check_gone() {  # desc  repo
  local desc="$1" repo="$2"
  if [[ ! -e "$repo/.agents/state/last-verdict.json" ]]; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  FAIL  %s  (dossier still present)\n' "$desc"
  fi
}

# A classifier stub that RECORDS its own invocation. Tiers A and B are latency work,
# so what has to be asserted is that the 5-10s round-trip was genuinely SKIPPED — not
# merely that its answer agreed. The stub also answers the OPPOSITE of the tier under
# test, so a run without the tier reaches the model and lands on the wrong decision.
# (Same property the in-flight rung needs: it sits ahead of triage.)
cls_stub()      { printf "cat >/dev/null; touch '%s/CLASSIFIER_RAN'; echo %s" "$1" "$2"; }
classifier_ran() { [[ -e "$1/CLASSIFIER_RAN" ]] && echo yes || echo no; }
run_hook() {  # repo  classifier-answer
  jq -nc --arg p "$1/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
    | ( cd "$1" && CLAUDE_PROJECT_DIR="$1" VERDICT_GATE_HARD_BLOCK=1 \
        VERDICT_CLASSIFIER_CMD="$(cls_stub "$1" "$2")" bash "$HOOK" ) 2>/dev/null
}

# Session-aware runtime state uses an opaque Git object hash, independently reproduced
# here so these tests do not grade the path helper with itself.
session_scope_of() {  # repo session
  printf 'git-%s' "$(printf '%s' "$2" | git -C "$1" hash-object --stdin)"
}
session_state_path() {  # repo basename session
  printf '%s/.agents/state/%s.%s' "$1" "$2" "$(session_scope_of "$1" "$3")"
}
write_session_request() {  # repo session generation final-id
  local path; path="$(session_state_path "$1" verdict-request "$2")"
  mkdir -p "$(dirname "$path")"
  printf '%s %s %s\n' "$3" "$(( $(date +%s) + 600 ))" "$4" > "$path"
}
run_session_hook() {  # repo session classifier-answer
  jq -nc --arg p "$1/transcript.jsonl" --arg s "$2" \
    '{transcript_path:$p, hook_event_name:"Stop", session_id:$s}' \
    | ( cd "$1" && CLAUDE_PROJECT_DIR="$1" VERDICT_GATE_HARD_BLOCK=1 \
        VERDICT_CLASSIFIER_CMD="$(cls_stub "$1" "$3")" bash "$HOOK" ) 2>/dev/null
}

prompt_hook() {  # repo session turn
  jq -nc --arg s "$2" --arg t "$3" --arg p "new user input" \
    '{hook_event_name:"UserPromptSubmit",session_id:$s,turn_id:$t,prompt:$p}' \
    | ( cd "$1" && CLAUDE_PROJECT_DIR="$1" bash "$CANCEL_HOOK" )
}

write_quarantine_barrier_env() {  # repo
  cat > "$1/.agents/state/quarantine-barrier-env.sh" <<'QUARANTINE_BARRIER_ENV'
if [[ -z "${VERDICT_QUARANTINE_OWNER_PID:-}" ]]; then
  export VERDICT_QUARANTINE_OWNER_PID="$$"
  verdict_quarantine_debug() {
    [[ "$$" == "$VERDICT_QUARANTINE_OWNER_PID" ]] || return 0
    if [[ "$BASH_COMMAND" == dossier_file_snapshot=* \
       && -n "${dossier_quarantine:-}" \
       && ! -e "$CLAUDE_PROJECT_DIR/.agents/state/quarantine-ready" ]]; then
      trap - DEBUG
      printf '%s\n' "${decision_lease_pid:-0}" \
        > "$CLAUDE_PROJECT_DIR/.agents/state/quarantine-decision-holder-pid"
      touch "$CLAUDE_PROJECT_DIR/.agents/state/quarantine-ready"
      while [[ ! -e "$CLAUDE_PROJECT_DIR/.agents/state/quarantine-release" ]]; do
        sleep 0.01
      done
    fi
  }
  set -T
  trap verdict_quarantine_debug DEBUG
fi
QUARANTINE_BARRIER_ENV
}

write_epoch_barrier_env() {  # repo
  mkdir -p "$1/.agents/state"
  cat > "$1/.agents/state/epoch-barrier-env.sh" <<'EPOCH_BARRIER_ENV'
if [[ -z "${VERDICT_EPOCH_BARRIER_OWNER_PID:-}" ]]; then
  export VERDICT_EPOCH_BARRIER_OWNER_PID="$$"
  verdict_epoch_barrier_debug() {
    [[ "$$" == "$VERDICT_EPOCH_BARRIER_OWNER_PID" ]] || return 0
    local should_pause=false
    case "${VERDICT_EPOCH_BARRIER_MODE:-}" in
      live-fail)
        [[ "${v_verdict:-}" == FAIL \
           && "${verdict_json:-}" == *"epoch live finding"* \
           && -n "${dossier_quarantine:-}" \
           && -e "$dossier_quarantine" ]] && should_pause=true
        ;;
      stale-fail)
        [[ "$BASH_COMMAND" == prompt_epoch_is_current \
           && "${v_verdict:-}" == FAIL \
           && -n "${verdict_request_file:-}" \
           && ! -e "$verdict_request_file" ]] && should_pause=true
        ;;
      prev-restore)
        [[ "$BASH_COMMAND" == prompt_epoch_is_current \
           && -n "${parked_quarantine:-}" \
           && -e "$parked_quarantine" ]] && should_pause=true
        ;;
      prev-replacement)
        [[ "$BASH_COMMAND" == 'rm -f "$parked_quarantine"' \
           && -n "${parked_quarantine:-}" \
           && -e "$parked_quarantine" ]] && should_pause=true
        ;;
      last-uuid-post-write)
        [[ "$BASH_COMMAND" == *prompt_epoch_is_current* \
           && -n "${last_uuid_file:-}" \
           && "${had_prior:-false}" == true \
           && -e "$last_uuid_file" ]] && should_pause=true
        ;;
      invalid-request-select)
        [[ "$BASH_COMMAND" == verdict_audit_rename_exact* \
           && -n "${invalid_request:-}" ]] && should_pause=true
        ;;
      discard-dossier-select)
        [[ "$BASH_COMMAND" == verdict_audit_rename_exact* \
           && "${quarantine:-}" == *.discard-* ]] && should_pause=true
        ;;
      prev-select)
        [[ "$BASH_COMMAND" == verdict_audit_rename_exact* \
           && -n "${parked_quarantine:-}" ]] && should_pause=true
        ;;
      dossier-select)
        [[ "$BASH_COMMAND" == verdict_audit_rename_exact* \
           && "${dossier_quarantine:-}" == *.inspect-* ]] && should_pause=true
        ;;
      park-publish)
        [[ "$BASH_COMMAND" == *verdict_audit_link_no_clobber* \
           && "${dossier_quarantine:-}" == *.inspect-* \
           && -n "${prev_verdict_file:-}" ]] && should_pause=true
        ;;
    esac
    [[ "$should_pause" == true ]] || return 0
    trap - DEBUG
    touch "$CLAUDE_PROJECT_DIR/.agents/state/epoch-barrier-ready"
    if [[ "${VERDICT_EPOCH_BARRIER_MODE:-}" == prev-replacement ]]; then
      printf '%s\n' '{"verdict":"FAIL","findings":["fresh replacement finding"]}' \
        > "$prev_verdict_file"
      return 0
    fi
    while [[ ! -e "$CLAUDE_PROJECT_DIR/.agents/state/epoch-barrier-release" ]]; do
      sleep 0.01
    done
  }
  set -T
  trap verdict_epoch_barrier_debug DEBUG
fi
EPOCH_BARRIER_ENV
}

# ── Real-repo invariant: every gate-written .agents/state/ file is gitignored ──
# compute_tree_hash() folds the whole working tree into the dossier binding via
# `git add -A`, which SKIPS gitignored paths. So every file the gates write under
# .agents/state/ MUST be gitignored — otherwise writing it perturbs the very tree
# hash the dossier is keyed to and self-invalidates a just-passed audit (the
# class of bug that hit pr-reviewed.json: a fresh PASS discarded as "stale" the
# instant the PR-review ack was written). setup() emulates this per synthetic
# repo (only last-verdict.json); this case guards the REAL .gitignore for the
# whole class, so a new marker added without a matching ignore line fails here.
echo "## Invariant: gate state files are gitignored (never enter the tree hash)"
for f in \
  .agents/state/last-audit.json \
  .agents/state/last-verdict.json \
  .agents/state/last-verdict.prev.json \
  .agents/state/pr-reviewed.json \
  .agents/state/verdict-last-uuid \
  .agents/state/verdict-stop-message.jsonl \
  .agents/state/verdict-prompt-epoch \
  .agents/state/verdict-audit.lock \
  .agents/state/verdict-audit.lock.mutex \
  .agents/state/verdict-request.publish.mutex \
  .agents/state/verdict-decisions.log; do
  if git -C "$REPO_ROOT" check-ignore -q "$f"; then
    pass=$((pass + 1)); printf '  PASS  %s gitignored\n' "$f"
  else
    fail=$((fail + 1)); printf '  FAIL  %s NOT gitignored → would perturb compute_tree_hash\n' "$f"
  fi
done

echo
echo "## Detection: no dossier → the turn text decides"
R="$(setup)"; write_transcript "$R" "The root cause is a race between gvproxy startup and the socket bind."
check "'root cause is X' → block (verdict asserted, unaudited)"   "$R" "block"; rm -rf "$R"

# Native Task/spawn-agent audits have no headless request monitor. The parent that owns
# their handle must cancel them when a REAL user steers the turn, then reject any artifact
# the abandoned auditor managed to publish.
R="$(setup)"; write_transcript "$R" "The root cause is the stale socket path."
payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p, hook_event_name:"Stop", session_id:"session-a", turn_id:"turn-a"}')"
out="$(run_payload_hook "$R" "$payload")"
native_cancel_contract=no
native_reason="$(printf '%s' "$out" | jq -r '.reason // ""')"
native_request_path="$(session_state_path "$R" verdict-request session-a)"
native_generation="$(awk '{print $1}' "$native_request_path" 2>/dev/null || echo MISSING)"
# The hook canonicalizes the repository root with pwd -P; macOS exposes /var as a
# symlink to /private/var, so compare against the same physical path it emits.
native_physical_root="$(cd "$R" && pwd -P)"
native_output_path="$(session_state_path "$native_physical_root" last-verdict.json session-a).audit-${native_generation}"
native_task_name="$(printf '%s' "$native_reason" \
  | sed -nE 's/.*task_name="(verdict_auditor_[0-9]+_[0-9]+_[0-9]+)".*/\1/p' \
  | head -n1)"
if [[ "$(decision_from_output "$out")" == "block" \
   && -n "$native_task_name" \
   && "$native_reason" == *"REAL user message"* \
   && "$native_reason" == *"collaboration.interrupt_agent(target='$native_task_name')"* \
   && "$native_reason" == *"verdict_file: ${native_output_path}"* \
   && "$native_reason" == *"discard"*"dossier"* ]]; then
  native_cancel_contract=yes
fi
if [[ "$native_cancel_contract" == "yes" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "native verdict instruction owns a fresh cancelable handle"
else
  fail=$((fail+1)); printf '  FAIL  %s\n' "native verdict instruction lacks a fresh cancelable handle"
fi
rm -rf "$R"

# Native auditors publish to generation-owned paths. Even if canceled generation A
# finishes after generation B has already written PASS, A cannot overwrite B's proof.
R="$(setup)"; claim="The root cause is the stale socket path."; write_transcript "$R" "$claim"
payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:"session-a",turn_id:"turn-a"}')"
first_native_out="$(run_payload_hook "$R" "$payload")"
request_path="$(session_state_path "$R" verdict-request session-a)"
first_generation="$(awk '{print $1}' "$request_path" 2>/dev/null || echo MISSING)"
prompt_hook "$R" session-a turn-b >/dev/null 2>&1
second_native_out="$(run_payload_hook "$R" "$payload")"
second_generation="$(awk '{print $1}' "$request_path" 2>/dev/null || echo MISSING)"
first_output="$(session_state_path "$R" last-verdict.json session-a).audit-${first_generation}"
second_output="$(session_state_path "$R" last-verdict.json session-a).audit-${second_generation}"
branch="$(git -C "$R" branch --show-current)"; head="$(git -C "$R" rev-parse HEAD)"
tree="$(tree_hash_of "$R")"
jq -nc --arg b "$branch" --arg h "$head" --arg t "$tree" --arg g "$second_generation" \
  '{branch:$b,head:$h,tree_hash:$t,generation:$g,verdict:"PASS",proof:[],findings:[]}' \
  > "$second_output"
jq -nc --arg b "$branch" --arg h "$head" --arg t "$tree" --arg g "$first_generation" \
  '{branch:$b,head:$h,tree_hash:$t,generation:$g,verdict:"FAIL",proof:[],findings:["late old finding"]}' \
  > "$first_output"
late_native_result="$(run_session_hook "$R" session-a YES)"
late_native_state="first=$first_generation second=$second_generation decision=$(decision_from_output "$late_native_result")"
late_native_state="$late_native_state current=$([[ -e "$second_output" ]] && echo present || echo consumed) old=$([[ -e "$first_output" ]] && echo isolated || echo gone)"
if [[ "$first_generation" != MISSING && "$second_generation" != MISSING \
   && "$first_generation" != "$second_generation" \
   && "$late_native_state" == *"decision=allow current=consumed old=isolated" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "late canceled native output cannot overwrite the current generation"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s first_decision=%s second_decision=%s)\n' \
    "native generations still share a clobberable dossier" "$late_native_state" \
    "$(decision_from_output "$first_native_out")" "$(decision_from_output "$second_native_out")"
fi
rm -rf "$R"

# Parse one hook event once. A present-but-invalid session id or a concatenated JSON
# stream must fail before selecting the legacy state paths; neither may consume a global
# dossier as though the session field were absent.
for malformed_payload_kind in numeric-session multiple-documents; do
  R="$(setup)"; write_transcript "$R" "The fix works and 12/12 tests pass."
  write_verdict "$R" PASS '[]'
  case "$malformed_payload_kind" in
    numeric-session)
      malformed_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
        '{transcript_path:$p,hook_event_name:"Stop",session_id:7}')"
      ;;
    *)
      malformed_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
        '{transcript_path:$p,hook_event_name:"Stop"}')$(jq -nc '{hook_event_name:"Stop"}')"
      ;;
  esac
  printf '%s' "$malformed_payload" \
    | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 bash "$HOOK" ) \
      >"$R/malformed-payload.out" 2>"$R/malformed-payload.err"
  malformed_payload_rc=$?
  malformed_payload_state="rc=$malformed_payload_rc dossier=$([[ -e "$R/.agents/state/last-verdict.json" ]] && echo present || echo gone)"
  if [[ "$malformed_payload_state" == "rc=1 dossier=present" ]]; then
    pass=$((pass+1)); printf '  PASS  %s\n' "$malformed_payload_kind fails before state selection"
  else
    fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
      "$malformed_payload_kind aliased legacy state" "$malformed_payload_state"
  fi
  rm -rf "$R"
done

# A native auditor can return or error without writing a dossier. The current request
# remains generation G, so the next Stop must reuse G's retained handle instead of
# attempting a second spawn under an already-occupied name (or inventing a concurrent
# sibling that can race the same authoritative output path).
R="$(setup)"; claim="The root cause is the stale socket path."; write_transcript "$R" "$claim"
generation="301-302-4"
write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
write_verdict "$R" FAIL '["proof missing"]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json" \
  > "$session_dossier"
rm -f "$R/.agents/state/last-verdict.json"
retry_out_one="$(run_session_hook "$R" session-a YES)"
retry_out_two="$(run_session_hook "$R" session-a YES)"
retry_reason_one="$(printf '%s' "$retry_out_one" | jq -r '.reason // ""')"
retry_reason_two="$(printf '%s' "$retry_out_two" | jq -r '.reason // ""')"
retry_name_one="$(printf '%s' "$retry_reason_one" \
  | sed -nE 's/.*task_name="(verdict_auditor_[0-9]+_[0-9]+_[0-9]+)".*/\1/p' \
  | head -n1)"
retry_name_two="$(printf '%s' "$retry_reason_two" \
  | sed -nE 's/.*task_name="(verdict_auditor_[0-9]+_[0-9]+_[0-9]+)".*/\1/p' \
  | head -n1)"
retry_contract="decisions=$(decision_from_output "$retry_out_one"),$(decision_from_output "$retry_out_two")"
retry_contract="$retry_contract names=$retry_name_one,$retry_name_two"
if [[ "$retry_contract" == \
      "decisions=block,block names=verdict_auditor_301_302_4,verdict_auditor_301_302_4" \
   && "$retry_reason_two" == *"collaboration.followup_task("* \
   && "$retry_reason_two" == *"target='verdict_auditor_301_302_4'"* \
   && "$retry_reason_two" == *"already running"* \
   && "$retry_reason_two" == *"Do not create a sibling task name"* ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "native retry reuses or waits on the exact generation handle"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "native retry can collide with its retained Codex handle" "$retry_contract"
fi
rm -rf "$R"

# A cancellation marker cannot be consumed before its exact request is retired. Force the
# first request rename to fail: the marker must remain visible, and ensure() must reject the
# canceled generation rather than handing its native handle back to the agent.
R="$(setup)"; claim="The root cause is the stale socket path."; write_transcript "$R" "$claim"
canceled_generation="303-304-5"
write_session_request "$R" session-a "$canceled_generation" "$(cksum_of "$claim")"
canceled_request_path="$(session_state_path "$R" verdict-request session-a)"
canceled_marker="$(session_state_path "$R" verdict-canceled session-a).$canceled_generation"
printf 'canceled\n' > "$canceled_marker"
cat > "$R/canceled-consume-env.sh" <<'CANCELED_CONSUME_ENV'
if [[ -z "${VERDICT_CANCELED_CONSUME_OWNER_PID:-}" ]]; then
  export VERDICT_CANCELED_CONSUME_OWNER_PID="$$"
  verdict_canceled_consume_debug() {
    [[ "$$" == "$VERDICT_CANCELED_CONSUME_OWNER_PID" ]] || return 0
    [[ "${VERDICT_CANCELED_CONSUME_SEEN:-false}" == false ]] || return 0
    case "$BASH_COMMAND" in
      *'verdict_audit_rename_exact "$record_path" "$quarantine"'*)
        [[ "$record_path" == *verdict-request* ]] || return 0
        VERDICT_CANCELED_CONSUME_SEEN=true
        mkdir "$quarantine"
        touch "$quarantine/block"
        touch "$CLAUDE_PROJECT_DIR/canceled-consume-gap"
        ;;
    esac
  }
  set -T
  trap verdict_canceled_consume_debug DEBUG
fi
CANCELED_CONSUME_ENV
payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:"session-a",turn_id:"turn-a"}')"
canceled_consume_out="$(printf '%s' "$payload" \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" BASH_ENV="$R/canceled-consume-env.sh" \
      VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD=false bash "$HOOK" ) 2>/dev/null)"
replacement_generation="$(awk '{print $1}' "$canceled_request_path" 2>/dev/null || echo MISSING)"
canceled_consume_state="decision=$(decision_from_output "$canceled_consume_out")"
canceled_consume_state="$canceled_consume_state barrier=$([[ -e "$R/canceled-consume-gap" ]] && echo hit || echo missed)"
canceled_consume_state="$canceled_consume_state marker=$([[ -e "$canceled_marker" ]] && echo present || echo gone)"
if [[ "$replacement_generation" != "$canceled_generation" \
   && "$replacement_generation" != MISSING ]]; then
  canceled_consume_state="$canceled_consume_state generation=fresh"
else
  canceled_consume_state="$canceled_consume_state generation=stale"
fi
if [[ "$canceled_consume_state" == \
      "decision=block barrier=hit marker=present generation=fresh" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "failed request retirement keeps cancellation authoritative"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "failed request retirement resurrected a canceled generation" "$canceled_consume_state"
fi
rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Rolled the canary back; prod looks healthy again, error rate is flat."
check "'prod looks healthy' → block"                              "$R" "block"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "All tests pass: 23/23 on the hook suite."
check "'tests pass' → block"                                      "$R" "block"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Done."
check "bare 'Done.' → block"                                      "$R" "block"; rm -rf "$R"

# Sentence-initial assertion without a helper verb — caught a live false negative
# in the transcript sweep ("Confirmed reachable from the open internet.").
R="$(setup)"; write_transcript "$R" "Confirmed reachable from the open internet."
check "sentence-initial 'Confirmed <adj>' → block"                "$R" "block"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Which of the two layouts do you prefer for the config module?"
check "question → allow"                                          "$R" "allow"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Here are three options for the retry policy, with trade-offs for each."
check "neutral discussion → allow"                                "$R" "allow"; rm -rf "$R"

# Detection reads only the FINAL TURN — a verdict in a PREVIOUS turn (separated
# by a real user message) must not retrigger on a later chat turn.
R="$(setup)"; write_transcript "$R" "The root cause is the stale cache."
append_user "$R" "thanks — and what should I look at next?"
append_assistant "$R" "What to look at next depends on the retry budget you want."
check "previous-turn verdict, new chat turn → allow"              "$R" "allow"; rm -rf "$R"

# A cited file:line is EVIDENCE, and the triage question now asks whether evidence is
# shown — so stripping single-token spans deleted the very thing being asked about, and
# a turn that cited its sources was judged more harshly than one that did not. The stub
# answers NO; what this pins is that the citation still reaches the classifier, checked
# through the regex fallback (which sees the same stripped text) rather than the model.
# Keeping a span's TEXT drops its delimiters, which can pull the token to the start of a
# line and complete a pattern that was never meant to match. Feeding the citation-keeping
# text to tier A let an assertion out through harness-noise with no model call. Both
# static tiers get their own case; the stub answers NO so a tier that wrongly fires is
# the only thing that can produce the wrong decision.
# The span must lead the LINE — harness_patterns is ^-anchored, so "The `API` Error…"
# does not reproduce and would pass either way.
R="$(setup)"; write_transcript "$R" '`API` Error handling is fixed and all tests pass.'
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "citation at line start does not disguise a claim as harness noise"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "tier A swallowed an assertion" "$out"
fi; rm -rf "$R"

# Tier B's only \$-anchored pattern: a trailing citation must not defeat it. Classifier
# forced UNKNOWN so tier B is what decides, not the model.
R="$(setup)"; write_transcript "$R" 'Done. `#1161`'
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD=false bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "trailing citation does not defeat the done. assertion"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "tier B anchor broken by a citation" "$out"
fi; rm -rf "$R"

# The mirror of the leading-token case: a model that reasons first and answers last was
# readable under the old tail -n1 parse and must not regress to UNKNOWN.
R="$(setup)"; write_transcript "$R" "Noted, I'll wait for your call on the API shape."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
      VERDICT_CLASSIFIER_CMD='cat >/dev/null; printf "Let me think about this.\nYES\n"' \
      bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "trailing classifier answer still read"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "answer-last shape became UNKNOWN" "$out"
fi; rm -rf "$R"

# Assert on what the classifier RECEIVES, not on the decision: a stub that answers NO
# allows either way, so a decision-level assertion here would pass without the change.
# The stub captures its stdin — the exact post-strip text — and the two cases pin the
# opposite halves of the rule from one input.
R="$(setup)"
write_transcript "$R" 'Root cause is the stale socket path, at `src/proxy.rs:412`, per `tests pass` in the docs.'
jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
      VERDICT_CLASSIFIER_CMD="cat > '$R/seen.txt'; echo NO" bash "$HOOK" ) >/dev/null 2>&1
seen="$(cat "$R/seen.txt" 2>/dev/null || echo MISSING)"
kept="no";      printf '%s' "$seen" | grep -q 'src/proxy.rs:412' && kept="yes"
dropped="no";   printf '%s' "$seen" | grep -q 'tests pass'       || dropped="yes"
for probe in "single-token citation reaches the classifier:$kept" \
             "multi-word quoted prose does not:$dropped"; do
  if [[ "${probe##*:}" == "yes" ]]; then
    pass=$((pass+1)); printf '  PASS  %s\n' "${probe%:*}"
  else
    fail=$((fail+1)); printf '  FAIL  %s  (post-strip text=%s)\n' "${probe%:*}" "$seen"
  fi
done
rm -rf "$R"

# An explanatory classifier answer must not silently become UNKNOWN. The stub rambles
# but leads with the word; a `tail -n1 | tr -dc` parse mangles it into nonsense, drops
# to the regex fallback, and the turn's real triage answer is lost.
R="$(setup)"; write_transcript "$R" "Noted, I'll wait for your call on the API shape."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
      VERDICT_CLASSIFIER_CMD='cat >/dev/null; printf "YES\nbecause the turn declares the fix works\n"' \
      bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "explanatory classifier answer still read as YES"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "rambling answer silently became UNKNOWN" "$out"
fi; rm -rf "$R"

# Verdict phrasing quoted inside code spans/fences is documentation, not a claim.
R="$(setup)"; write_transcript "$R" 'The matcher looks for phrases like `tests pass` and `root cause is` in prose:
```
detector: "tests pass" -> block
```
Nothing is asserted here.'
check "verdict phrases only inside code → allow"                  "$R" "allow"; rm -rf "$R"

R="$(setup)"  # no transcript at all (payload points at /dev/null)
check "no transcript → allow (fail-open)"                         "$R" "allow"; rm -rf "$R"

# Codex explicitly permits a null transcript_path and provides the stable
# last_assistant_message field on Stop. Ignoring that field turns every such event
# into an empty allow even when the message is an obvious verdict.
R="$(setup)"
payload="$(jq -nc '{transcript_path:null, hook_event_name:"Stop", stop_hook_active:false,
  last_assistant_message:"All tests pass."}')"
out="$(run_payload_hook "$R" "$payload")"
got="$(decision_from_output "$out")"
expected_id="$(cksum_of "All tests pass.")"
recorded_id="$(cat "$R/.agents/state/verdict-last-uuid" 2>/dev/null || echo MISSING)"
fallback_transcript="$R/.agents/state/verdict-stop-message.jsonl"
fallback_transcript="$(cd "$R" && pwd -P)/.agents/state/verdict-stop-message.jsonl"
fallback_text="$(jq -r '.message.content[0].text // ""' "$fallback_transcript" 2>/dev/null || echo MISSING)"
if [[ "$got" == "block" && "$recorded_id" == "$expected_id" \
   && "$fallback_text" == "All tests pass." \
   && "$out" == *"transcript_path: ${fallback_transcript}"* ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' \
    "null transcript + Stop message → block with content identity and auditable handoff"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s id=%s expected=%s fallback=%s handed-off=%s)\n' \
    "null transcript fallback" "$got" "$recorded_id" "$expected_id" "$fallback_text" \
    "$([[ "$out" == *"transcript_path: ${fallback_transcript}"* ]] && echo yes || echo no)"
fi

# A recursive Stop for the message just judged is stale, but only when Codex marks
# the hook active. It must avoid the transcript flush wait because there is no
# transcript to flush; otherwise every blocked Stop adds two seconds of dead time.
payload="$(jq -nc '{transcript_path:null, hook_event_name:"Stop", stop_hook_active:true,
  last_assistant_message:"All tests pass."}')"
started=$SECONDS
got="$(decide_payload "$R" "$payload")"
elapsed=$((SECONDS - started))
if [[ "$got" == "allow" && "$elapsed" -lt 2 ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "same active Stop payload → immediate stale allow"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s elapsed=%ss)\n' \
    "payload recursion guard" "$got" "$elapsed"
fi

# The same text without the recursion signal may be a new user turn and must be
# judged again. Conversely, stop_hook_active never exempts changed text.
payload="$(jq -nc '{transcript_path:null, hook_event_name:"Stop", stop_hook_active:false,
  last_assistant_message:"All tests pass."}')"
got_same_fresh="$(decide_payload "$R" "$payload")"
payload="$(jq -nc '{transcript_path:null, hook_event_name:"Stop", stop_hook_active:true,
  last_assistant_message:"All 7/7 tests pass."}')"
got_changed_active="$(decide_payload "$R" "$payload")"
if [[ "$got_same_fresh" == "block" && "$got_changed_active" == "block" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "payload guard skips only an identical active recursion"
else
  fail=$((fail+1)); printf '  FAIL  %s  (same-fresh=%s changed-active=%s)\n' \
    "payload recursion scope" "$got_same_fresh" "$got_changed_active"
fi; rm -rf "$R"

R="$(setup)"
payload="$(jq -nc --arg p "$R/missing.jsonl" \
  '{transcript_path:$p, hook_event_name:"Stop", stop_hook_active:false,
    last_assistant_message:"Root cause is the stale index."}')"
got_missing="$(decide_payload "$R" "$payload")"
payload="$(jq -nc '{transcript_path:null, hook_event_name:"Stop", stop_hook_active:false,
  last_assistant_message:"Should I run the focused suite?"}')"
got_question="$(decide_payload "$R" "$payload")"
payload="$(jq -nc '{transcript_path:null, hook_event_name:"Stop", stop_hook_active:false,
  last_assistant_message:null}')"
got_empty="$(decide_payload "$R" "$payload")"
if [[ "$got_missing" == "block" && "$got_question" == "allow" && "$got_empty" == "allow" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "payload fallback distinguishes verdict, question, and empty input"
else
  fail=$((fail+1)); printf '  FAIL  %s  (missing=%s question=%s empty=%s)\n' \
    "payload fallback decisions" "$got_missing" "$got_question" "$got_empty"
fi; rm -rf "$R"

# A readable transcript remains authoritative because it contains the whole turn.
# The latest payload fragment must not hide a verdict asserted earlier in that turn.
R="$(setup)"; write_transcript "$R" "Root cause is the stale index."
payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p, hook_event_name:"Stop", stop_hook_active:false,
    last_assistant_message:"Anything else?"}')"
got="$(decide_payload "$R" "$payload")"
if [[ "$got" == "block" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "whole-turn transcript takes precedence over payload fragment"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' "transcript precedence" "$got"
fi; rm -rf "$R"

# A nonempty transcript with no assistant record may simply be ahead of its flush.
# Do not fall back to a benign latest fragment until the bounded transcript wait has
# had a chance to recover the whole turn.
R="$(setup)"
jq -nc '{type:"user", message:{content:[{type:"text",text:"go"}]}}' > "$R/transcript.jsonl"
( sleep 0.6
  jq -nc '{type:"assistant", message:{content:[{type:"text",
    text:"Root cause is the stale index; all tests pass."}]}}' >> "$R/transcript.jsonl" ) &
late_writer=$!
payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p, hook_event_name:"Stop", stop_hook_active:false,
    last_assistant_message:"Anything else?"}')"
got="$(decide_payload "$R" "$payload")"
wait "$late_writer" 2>/dev/null
if [[ "$got" == "block" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "transcript flush wins before payload fallback"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s — payload fragment bypassed flush wait)\n' \
    "payload fallback ordering" "$got"
fi; rm -rf "$R"

# ── The gate must never end a turn it could not SEE ──────────────────────────
# A zero-byte/absent transcript is genuinely nothing to judge → allow at once, and the
# rung must say `empty` so it stays distinguishable from being blind.
R="$(setup)"
decide "$R" >/dev/null
if grep -q ' extract empty-allow$' "$R/.agents/state/verdict-decisions.log" 2>/dev/null; then
  pass=$((pass+1)); printf '  PASS  %s\n' "no transcript → allow logged as empty (not blind)"
else
  fail=$((fail+1)); printf '  FAIL  %s  (log=%s)\n' "no-transcript rung" \
    "$(cat "$R/.agents/state/verdict-decisions.log" 2>/dev/null || echo MISSING)"
fi; rm -rf "$R"

# THE REPRODUCER. A transcript WITH content but no assistant text means the hook read
# the file before the harness flushed the turn — the text lands moments later and the
# turn must still be judged on it. Observed live at 06:06:18Z: the text record's own
# timestamp was 0.1s after the hook's read, the turn logged `extract empty-allow`, and
# a verdict-shaped turn ended completely untriaged.
R="$(setup)"
jq -nc '{type:"user", message:{content:[{type:"text",text:"go"}]}}' > "$R/transcript.jsonl"
( sleep 0.6
  jq -nc '{type:"assistant", uuid:"uuid-last", message:{content:[{type:"text",
     text:"Root cause is the stale index; 12/12 tests pass."}]}}' >> "$R/transcript.jsonl" ) &
late_writer=$!
got="$(decide "$R")"
wait "$late_writer" 2>/dev/null
if [[ "$got" == "block" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "text flushed mid-wait → turn is judged, not skipped"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s — the turn ended unjudged)\n' "late-flush turn judged" "$got"
fi; rm -rf "$R"

# Content present but the turn genuinely never produces assistant text: still fail open
# (never trap on absent state), but under a rung that ADMITS the gate was blind.
R="$(setup)"
jq -nc '{type:"user", message:{content:[{type:"text",text:"go"}]}}' > "$R/transcript.jsonl"
got="$(decide "$R")"
if [[ "$got" == "allow" ]] && grep -q ' extract blind-allow$' "$R/.agents/state/verdict-decisions.log" 2>/dev/null; then
  pass=$((pass+1)); printf '  PASS  %s\n' "still no assistant text after the wait → allow, logged blind"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s log=%s)\n' "blind rung" "$got" \
    "$(cat "$R/.agents/state/verdict-decisions.log" 2>/dev/null || echo MISSING)"
fi; rm -rf "$R"

echo
echo "## Present dossier, fresh + matching → the verdict decides"
R="$(setup)"; write_transcript "$R" "Fix verified; tests pass."; write_verdict "$R" "PASS" "[]"
check "PASS → allow"                                              "$R" "allow"
check_gone "PASS dossier consumed on allow"                       "$R"; rm -rf "$R"

# `git branch --show-current` is legitimately empty on detached HEAD (including this
# development worktree). Snapshot transport must preserve that leading empty field rather
# than shifting head/tree/verdict left as tab-delimited Bash `read` does.
R="$(setup)"; git -C "$R" checkout --detach -q
write_transcript "$R" "Fix verified; tests pass."; write_verdict "$R" "PASS" "[]"
check "detached-HEAD PASS with an empty branch → allow"            "$R" "allow"
check_gone "detached-HEAD dossier consumed on allow"               "$R"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Root cause confirmed; pausing here."; write_verdict "$R" "IN_PROGRESS" '["push pending"]'
check "IN_PROGRESS → allow"                                       "$R" "allow"
check_gone "IN_PROGRESS dossier consumed on allow"                "$R"; rm -rf "$R"

# Requirement: the gate MAY loop on real findings — FAIL persists until re-audited.
R="$(setup)"; write_transcript "$R" "The fix works."; write_verdict "$R" "FAIL" '["Test: no reproducer for the claimed fix"]'
check "FAIL → block (finding-driven loop)"                        "$R" "block"
check "FAIL again (unaddressed) → still block"                    "$R" "block"; rm -rf "$R"

# A carried FAIL is handled before normal message extraction. Its retry instruction
# still needs an auditable source when Codex supplies only the stable Stop message.
R="$(setup)"; write_verdict "$R" "FAIL" '["Test: re-run the focused reproducer"]'
payload="$(jq -nc '{transcript_path:null, hook_event_name:"Stop", stop_hook_active:false,
  last_assistant_message:"The focused fix is ready."}')"
out="$(run_payload_hook "$R" "$payload")"
fallback_transcript="$R/.agents/state/verdict-stop-message.jsonl"
fallback_transcript="$(cd "$R" && pwd -P)/.agents/state/verdict-stop-message.jsonl"
fallback_text="$(jq -r '.message.content[0].text // ""' "$fallback_transcript" 2>/dev/null || echo MISSING)"
if [[ "$(decision_from_output "$out")" == "block" \
   && "$fallback_text" == "The focused fix is ready." \
   && "$out" == *"transcript_path: ${fallback_transcript}"* ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "FAIL retry with null transcript keeps an auditable handoff"
else
  fail=$((fail+1)); printf '  FAIL  %s  (fallback=%s handed-off=%s)\n' \
    "FAIL retry payload handoff" "$fallback_text" \
    "$([[ "$out" == *"transcript_path: ${fallback_transcript}"* ]] && echo yes || echo no)"
fi; rm -rf "$R"

echo
echo "## Audit in flight → allow (the gate must not busy-wait on its own remedy)"
# Regression: 108 blocks in one session, 39 in a 512s window, while the audit the gate
# demanded was still running. Each conjunct gets its own case — the rung must suppress
# only the window where no verdict provably exists yet.
lock_path() { printf '%s/.agents/state/verdict-audit.lock' "$1"; }
# $2 = body VERBATIM; cases write malformed and legacy bodies too, so this must not
# encode the format. See take_audit_lock() in run-verdict-audit.sh.
take_lock()  { mkdir -p "$1/.agents/state"; printf '%s' "$2" > "$(lock_path "$1")"; }
hold_lock_mutex() {  # lock-metadata-path
  local metadata_path="$1" ready="${1}.mutex-ready"
  perl -MFcntl=:flock -e '
    my ($path, $ready, $state_dir) = @ARGV;
    open(my $fh, ">>", "$path.mutex") or exit 2;
    flock($fh, LOCK_EX) or exit 2;
    open(my $signal, ">", $ready) or exit 2;
    close($signal);
    select(undef, undef, undef, 0.02) while -d $state_dir;
  ' "$metadata_path" "$ready" "$(dirname "$metadata_path")" &
  for (( poll_index=0; poll_index<100; poll_index++ )); do [[ -e "$ready" ]] && return 0; sleep 0.01; done
  return 1
}
now_epoch()  { date +%s; }
overflow_epoch() {  # seconds-from-now, encoded as 2^64 + target
  perl -MMath::BigInt -e '
    my $delta = shift;
    print Math::BigInt->new("18446744073709551616")->badd(time + $delta);
  ' "$1"
}
# BSD `date -r` / GNU `date -d @`. The suite's other backdating uses a fixed 2020 stamp,
# useless here because the deadline ceiling is anchored TO the mtime.
backdate() {  # file  seconds-ago
  local target=$(( $(date +%s) - $2 )) stamp
  stamp="$(date -r "$target" +%Y%m%d%H%M.%S 2>/dev/null \
        || date -d "@$target" +%Y%m%d%H%M.%S 2>/dev/null)"
  [[ -n "$stamp" ]] && touch -t "$stamp" "$1"
}
futuredate() {  # file  seconds-ahead
  local target=$(( $(date +%s) + $2 )) stamp
  stamp="$(date -r "$target" +%Y%m%d%H%M.%S 2>/dev/null \
        || date -d "@$target" +%Y%m%d%H%M.%S 2>/dev/null)"
  [[ -n "$stamp" ]] && touch -t "$stamp" "$1"
}

sleep 300 & LIVE_PID=$!            # stands in for a running run-verdict-audit.sh

# The rung sits ahead of triage, so the 5-10s model round-trip must be skipped too —
# the stub answers YES, which is what a hook WITHOUT the rung would block on.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID"
hold_lock_mutex "$(lock_path "$R")"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '(.decision // "") != "block"' >/dev/null 2>&1 \
   && grep -q ' audit inflight-allow$' "$R/.agents/state/verdict-decisions.log" 2>/dev/null \
   && [[ ! -e "$R/CLASSIFIER_RAN" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "audit running, no verdict yet → allow (classifier skipped)"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s ran=%s log=%s)\n' "in-flight rung" "$out" \
    "$(classifier_ran "$R")" "$(cat "$R/.agents/state/verdict-decisions.log" 2>/dev/null || echo MISSING)"
fi; rm -rf "$R"

# A live PID plus plausible metadata is not ownership. Without the kernel lease, a stale
# file surviving SIGKILL/PID reuse must not suppress triage.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "live PID without the kernel lease → block"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "metadata without ownership bought silence" "$out"
fi; rm -rf "$R"

# A busy flock is authoritative only on the single-link inode at the exact runtime path.
# Locking an outside file and hardlinking it into state must not buy inflight-allow.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID"
outside_mutex="$R/outside-owned-mutex"
printf 'outside\n' > "$outside_mutex"
ln "$outside_mutex" "$(lock_path "$R").mutex"
perl -MFcntl=:flock -e '
  my ($path, $ready, $state_dir) = @ARGV;
  open(my $fh, ">>", $path) or exit 2;
  flock($fh, LOCK_EX) or exit 2;
  open(my $mark, ">", $ready) or exit 2;
  close($mark);
  select(undef, undef, undef, 0.02) while -d $state_dir;
' "$outside_mutex" "$R/hardlink-mutex-ready" "$R/.agents/state" & hardlink_mutex_holder=$!
for (( poll_index=0; poll_index<100; poll_index++ )); do
  [[ -e "$R/hardlink-mutex-ready" ]] && break
  sleep 0.01
done
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "hardlinked busy mutex cannot authorize inflight allow"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "outside hardlink bought inflight authority" "$out"
fi
rm -rf "$R"; wait "$hardlink_mutex_holder" 2>/dev/null || true

# Lease inspection itself must be bounded. Perl `open >>path` blocks before `flock` when
# the gitignored mutex is a FIFO/symlink; an outer alarm makes that old behavior a fast
# failure while the hook is expected to reject the malformed lease and triage normally.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID"
rm -f "$(lock_path "$R").mutex"
mkfifo "$R/audit-mutex-fifo"
ln -s "$R/audit-mutex-fifo" "$(lock_path "$R").mutex"
fifo_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p,hook_event_name:"Stop"}')"
fifo_out="$(printf '%s' "$fifo_payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
  VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD='false' \
  perl -e 'alarm 2; exec @ARGV' bash "$HOOK" ) 2>/dev/null)"; fifo_rc=$?
fifo_gate_state="rc=$fifo_rc decision=$(decision_from_output "$fifo_out")"
if [[ "$fifo_gate_state" == "rc=0 decision=block" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "FIFO audit mutex → bounded rejection"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "FIFO audit mutex blocked lease inspection" "$fifo_gate_state"
fi; rm -rf "$R"

# A dead runner must not buy silence: the EXIT trap misses SIGKILL, so an interrupted
# session orphans the lock.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
sleep 0 & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null
take_lock "$R" "$DEAD_PID"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "lock held by a DEAD pid → block (no bypass)"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "dead-runner lock bought silence" "$out"
fi; rm -rf "$R"

# A bare-PID body has no deadline, so it takes the max_age_seconds fallback — not the
# general rule; a body carrying a deadline gets the wider bound (see the 800s case).
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID"; touch -t 202001010000 "$(lock_path "$R")"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "lock older than max_age → block (pid reuse bounded)"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "aged lock bought silence" "$out"
fi; rm -rf "$R"

# A future mtime is not fresh metadata; it is an invalid clock observation. Both legacy
# and deadline-bearing lock formats must reject it instead of extending a stale lease.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID"
hold_lock_mutex "$(lock_path "$R")"
futuredate "$(lock_path "$R")" 600
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "future-mtime legacy lock → block"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "future legacy lock bought silence" "$out"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID $(( $(now_epoch) + 800 )) 123 cksum-session owner-token legacy"
hold_lock_mutex "$(lock_path "$R")"
futuredate "$(lock_path "$R")" 600
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "future-mtime deadline lock → block"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "future deadline lock bought silence" "$out"
fi; rm -rf "$R"

# THE soundness case. The runner removes the dossier before auditing, so a present one
# means this run already answered (the auditor writes mid-run). A held lock must not
# mute it, or a real FAIL is skippable for the runner's whole tail.
R="$(setup)"; write_transcript "$R" "The fix works."
write_verdict "$R" "FAIL" '["Test: no reproducer for the claimed fix"]'
take_lock "$R" "$LIVE_PID"
check "verdict already written → FAIL blocks despite the held lock"  "$R" "block"; rm -rf "$R"

# Untrusted input: anything that is not a PID says nothing about liveness. "0" is the
# dangerous one — `kill -0 0` hits the caller's own process group and SUCCEEDS, so a
# bare numeric check would let it past the liveness conjunct.
for junk in "" "0" "not-a-pid" "12x34" "-1"; do
  R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
  take_lock "$R" "$junk"
  out="$(run_hook "$R" YES)"
  if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    pass=$((pass+1)); printf '  PASS  %s\n' "lock content '${junk:-<empty>}' is not a live pid → block"
  else
    fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "non-pid lock content '${junk:-<empty>}' bought silence" "$out"
  fi; rm -rf "$R"
done

# Models a long run partway through: the lock is ALREADY older than max_age_seconds, so
# a hook that ignores the deadline and falls back to the mtime bound fails here.
# Backdated 700s, not to 2020, because the ceiling is anchored to the mtime.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
# New runners append process-group/session/owner fields. The gate still owns only the
# first two fields; `read pid deadline` accidentally folds every remaining field into
# deadline and silently falls back to the shorter legacy mtime window.
take_lock "$R" "$LIVE_PID $(( $(now_epoch) + 800 )) 123 cksum-session owner-token"
hold_lock_mutex "$(lock_path "$R")"
backdate "$(lock_path "$R")" 700
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '(.decision // "") != "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "deadline beyond max_age_seconds → still allow (long audits covered)"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "lock expired mid-run despite its deadline" "$out"
fi; rm -rf "$R"

# Field parsing is not record parsing: `read` accepts a valid first line and silently
# ignores later records. A forged suffix must invalidate the whole persisted lease.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID $(( $(now_epoch) + 800 )) 123 cksum-session owner-token legacy
ignored second record"
hold_lock_mutex "$(lock_path "$R")"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "a valid lock prefix cannot hide a second persisted record"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' \
    "multiline lock metadata bought silence" "$out"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
mkdir -p "$R/.agents/state"
printf '%s\n\n' \
  "$LIVE_PID $(( $(now_epoch) + 800 )) 123 cksum-session owner-token legacy" \
  > "$(lock_path "$R")"
hold_lock_mutex "$(lock_path "$R")"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "a trailing blank record invalidates lock metadata"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' \
    "blank lock record bought silence" "$out"
fi; rm -rf "$R"

# The metadata path itself is workspace state. It must be opened nonblocking and
# rejected when it is not a regular file, before the in-flight rung can buy silence.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
mkdir -p "$R/.agents/state"; mkfifo "$(lock_path "$R")"
fifo_payload="$(jq -nc --arg p "$R/transcript.jsonl" \
  '{transcript_path:$p,hook_event_name:"Stop"}')"
fifo_out="$(printf '%s' "$fifo_payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
  VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD='false' \
  perl -e 'alarm 2; exec @ARGV' bash "$HOOK" ) 2>/dev/null)"; fifo_rc=$?
fifo_lock_state="rc=$fifo_rc decision=$(decision_from_output "$fifo_out")"
if [[ "$fifo_lock_state" == "rc=0 decision=block" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "FIFO lock metadata → bounded rejection"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "FIFO lock metadata blocked record inspection" "$fifo_lock_state"
fi; rm -rf "$R"

# ...but the deadline is file content, not a promise. Past it, the run is over however
# alive the PID looks.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID $(( $(now_epoch) - 30 ))"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "deadline already passed → block"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "expired deadline bought silence" "$out"
fi; rm -rf "$R"

# A lock cannot buy itself unbounded silence by claiming a deadline years out.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID $(( $(now_epoch) + 86400 ))"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "deadline past the hard ceiling → block (rejected, not capped)"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "an unbounded deadline was honoured" "$out"
fi; rm -rf "$R"

# Decimal width is part of validation, not presentation. Bash 3 wraps 2^64 + (now+800)
# into a plausible live deadline; an overflowing persisted lease must not buy silence.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
take_lock "$R" "$LIVE_PID $(overflow_epoch 800)"
hold_lock_mutex "$(lock_path "$R")"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "overflowing lock deadline → block before arithmetic"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "overflowing lock deadline bought silence" "$out"
fi; rm -rf "$R"

# Composition with the discard path, which is how a re-audit round actually looks: the
# agent fixed the findings (tree moved), the old dossier is discarded as mismatched, and
# a runner is already recomputing the verdict. The dossier branch must not consume its
# way past this rung, and the discarded dossier must not resurrect as a block.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
write_verdict "$R" "FAIL" '["Test: no reproducer for the claimed fix"]'
printf 'moved\n' >> "$R/src/lib.rs"            # invalidates the binding
take_lock "$R" "$LIVE_PID $(( $(now_epoch) + 800 ))"
hold_lock_mutex "$(lock_path "$R")"
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '(.decision // "") != "block"' >/dev/null 2>&1 \
   && [[ ! -e "$R/.agents/state/last-verdict.json" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "stale dossier discarded + audit in flight → allow"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s dossier=%s)\n' "discard→in-flight composition" "$out" \
    "$([[ -e "$R/.agents/state/last-verdict.json" ]] && echo present || echo gone)"
fi; rm -rf "$R"

# A worktree can host more than one task. Session A's live audit must suppress only A's
# repeated Stop; otherwise session B can use A's expensive proof work as an unaudited
# bypass. Write both the legacy global lock and the intended scoped lock so this is red
# against the pre-fix gate and remains a direct boundary test after migration.
R="$(setup)"; claim="Root cause is the stale socket path; 12/12 tests pass."
write_transcript "$R" "$claim"
generation="901-902-3"; scope_a="$(session_scope_of "$R" session-a)"
write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
lock_body="$LIVE_PID $(( $(now_epoch) + 800 )) 123 $scope_a 901-902-4 $generation"
take_lock "$R" "$lock_body"
printf '%s' "$lock_body" > "$(session_state_path "$R" verdict-audit.lock session-a)"
hold_lock_mutex "$(session_state_path "$R" verdict-audit.lock session-a)"
out_a="$(run_session_hook "$R" session-a YES)"
out_b="$(run_session_hook "$R" session-b YES)"
pair="a=$(decision_from_output "$out_a") b=$(decision_from_output "$out_b")"
if [[ "$pair" == "a=allow b=block" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "in-flight allowance is owned by one session"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' "another session used the live-audit bypass" "$pair"
fi; rm -rf "$R"

# A canceled native auditor can finish its write after the next generation is already
# running. Its stable-path dossier is garbage, but the CURRENT request and lock are not:
# deleting all three together turns a harmless late write into a needless third audit.
R="$(setup)"; claim="Root cause is the stale socket path; 12/12 tests pass."
write_transcript "$R" "$claim"
current_generation="921-922-6"; late_generation="911-912-5"
scope_a="$(session_scope_of "$R" session-a)"
request_path="$(session_state_path "$R" verdict-request session-a)"
dossier_path="$(session_state_path "$R" last-verdict.json session-a)"
write_session_request "$R" session-a "$current_generation" "$(cksum_of "$claim")"
lock_body="$LIVE_PID $(( $(now_epoch) + 800 )) 123 $scope_a 921-922-7 $current_generation"
printf '%s' "$lock_body" > "$(session_state_path "$R" verdict-audit.lock session-a)"
hold_lock_mutex "$(session_state_path "$R" verdict-audit.lock session-a)"
write_verdict "$R" PASS '[]'
jq --arg g "$late_generation" '.generation=$g' "$R/.agents/state/last-verdict.json" > "$dossier_path"
rm -f "$R/.agents/state/last-verdict.json"
out="$(run_session_hook "$R" session-a YES)"
request_generation="$(awk '{print $1}' "$request_path" 2>/dev/null || echo MISSING)"
late_dossier_gone=no; [[ ! -e "$dossier_path" ]] && late_dossier_gone=yes
late_pair="decision=$(decision_from_output "$out") request=$request_generation dossier_gone=$late_dossier_gone"
if [[ "$late_pair" == "decision=allow request=$current_generation dossier_gone=yes" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "late generation cannot revoke the current in-flight audit"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' "late dossier displaced the current generation" "$late_pair"
fi; rm -rf "$R"

# A completed PASS is equally session- and generation-bound. Running B first is
# deliberate: the old global gate consumes A's dossier, then has nothing left for A.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="911-912-5"
write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
write_verdict "$R" PASS '[]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json" > "$session_dossier"
out_b="$(run_session_hook "$R" session-b YES)"
out_a="$(run_session_hook "$R" session-a YES)"
pair="a=$(decision_from_output "$out_a") b=$(decision_from_output "$out_b")"
if [[ "$pair" == "a=allow b=block" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "completed dossier is bound to its session and audit generation"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' "a completed dossier crossed session/generation" "$pair"
fi; rm -rf "$R"

# Hosts may invoke an absolute hook from outside the consumer while providing the
# repository through CLAUDE_PROJECT_DIR. Every binding input must come from that same
# consumer root, matching the headless runner and auditor.
R="$(setup)"; outside_repo="$(mktemp -d)"
claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="912-913-6"; write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
write_verdict "$R" PASS '[]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json" \
  > "$session_dossier"
rm -f "$R/.agents/state/last-verdict.json"
outside_payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
outside_out="$(printf '%s' "$outside_payload" | ( cd "$outside_repo" \
  && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 \
     VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" bash "$HOOK" ) 2>/dev/null)"
outside_gate_state="decision=$(decision_from_output "$outside_out")"
outside_gate_state="$outside_gate_state dossier=$([[ -e "$session_dossier" ]] && echo present || echo gone)"
if [[ "$outside_gate_state" == "decision=allow dossier=gone" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "out-of-repo Stop gate binds the consumer repository"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "out-of-repo Stop gate inspected the caller cwd" "$outside_gate_state"
fi; rm -rf "$R" "$outside_repo"

# UserPromptSubmit can revoke a native audit after the Stop gate has atomically selected
# its dossier. Selection hides the inode from the prompt hook, so the gate must re-check
# the exact request before trusting PASS and cancellation must clean any state published
# while it waits for the decision mutex.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="913-914-6"; write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
write_verdict "$R" PASS '[]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json" \
  > "$session_dossier"
rm -f "$R/.agents/state/last-verdict.json"
write_quarantine_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" \
    BASH_ENV="$R/.agents/state/quarantine-barrier-env.sh" bash "$HOOK" ) \
    > "$R/quarantine-pass.out" 2>/dev/null ) & quarantined_gate_job=$!
for (( poll_index=0; poll_index<200; poll_index++ )); do
  [[ -e "$R/.agents/state/quarantine-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-b >/dev/null 2>&1 ) & prompt_job=$!
( sleep 5; touch "$R/quarantine-watchdog-hit"; \
  kill -KILL "$quarantined_gate_job" "$prompt_job" 2>/dev/null || true ) & race_watchdog=$!
request_path="$(session_state_path "$R" verdict-request session-a)"
sleep 0.1
prompt_waiting=$(kill -0 "$prompt_job" 2>/dev/null && echo yes || echo no)
touch "$R/.agents/state/quarantine-release"
wait "$quarantined_gate_job" 2>/dev/null; quarantined_gate_rc=$?
wait "$prompt_job" 2>/dev/null; prompt_rc=$?
kill "$race_watchdog" 2>/dev/null || true; wait "$race_watchdog" 2>/dev/null || true
quarantine_pass_out="$(cat "$R/quarantine-pass.out" 2>/dev/null || true)"
quarantine_pass_state="barrier=$([[ -e "$R/.agents/state/quarantine-ready" ]] && echo hit || echo missed)"
quarantine_pass_state="$quarantine_pass_state waiting=$prompt_waiting decision=$(decision_from_output "$quarantine_pass_out")"
quarantine_pass_state="$quarantine_pass_state gate_rc=$quarantined_gate_rc"
quarantine_pass_state="$quarantine_pass_state prompt_rc=$prompt_rc"
quarantine_pass_state="$quarantine_pass_state watchdog=$([[ -e "$R/quarantine-watchdog-hit" ]] && echo hit || echo quiet)"
[[ -e "$session_dossier" ]] && quarantine_pass_state="$quarantine_pass_state dossier=present" \
                               || quarantine_pass_state="$quarantine_pass_state dossier=gone"
[[ -e "$request_path" ]] && quarantine_pass_state="$quarantine_pass_state request=present" \
                            || quarantine_pass_state="$quarantine_pass_state request=gone"
if [[ "$quarantine_pass_state" == "barrier=hit waiting=yes decision=allow gate_rc=0 prompt_rc=0 watchdog=quiet dossier=gone request=gone" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "post-quarantine prompt revokes PASS, then cleans the decision window"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "quarantined PASS survived prompt cancellation" "$quarantine_pass_state"
fi; rm -rf "$R"

# FAIL is not special authority: after the same revocation it must neither be restored
# to the stable path nor block the superseded turn on an abandoned finding.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="914-915-7"; write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
write_verdict "$R" FAIL '["abandoned generation finding"]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json" \
  > "$session_dossier"
rm -f "$R/.agents/state/last-verdict.json"
write_quarantine_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" \
    BASH_ENV="$R/.agents/state/quarantine-barrier-env.sh" bash "$HOOK" ) \
    > "$R/quarantine-fail.out" 2>/dev/null ) & quarantined_gate_job=$!
for (( poll_index=0; poll_index<200; poll_index++ )); do
  [[ -e "$R/.agents/state/quarantine-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-c >/dev/null 2>&1 ) & prompt_job=$!
( sleep 5; touch "$R/quarantine-watchdog-hit"; \
  kill -KILL "$quarantined_gate_job" "$prompt_job" 2>/dev/null || true ) & race_watchdog=$!
request_path="$(session_state_path "$R" verdict-request session-a)"
sleep 0.1
prompt_waiting=$(kill -0 "$prompt_job" 2>/dev/null && echo yes || echo no)
touch "$R/.agents/state/quarantine-release"
wait "$quarantined_gate_job" 2>/dev/null; quarantined_gate_rc=$?
wait "$prompt_job" 2>/dev/null; prompt_rc=$?
kill "$race_watchdog" 2>/dev/null || true; wait "$race_watchdog" 2>/dev/null || true
quarantine_fail_out="$(cat "$R/quarantine-fail.out" 2>/dev/null || true)"
quarantine_fail_state="barrier=$([[ -e "$R/.agents/state/quarantine-ready" ]] && echo hit || echo missed)"
quarantine_fail_state="$quarantine_fail_state waiting=$prompt_waiting decision=$(decision_from_output "$quarantine_fail_out")"
quarantine_fail_state="$quarantine_fail_state gate_rc=$quarantined_gate_rc old_finding=$([[ "$quarantine_fail_out" == *"abandoned generation finding"* ]] && echo leaked || echo gone)"
quarantine_fail_state="$quarantine_fail_state prompt_rc=$prompt_rc"
quarantine_fail_state="$quarantine_fail_state watchdog=$([[ -e "$R/quarantine-watchdog-hit" ]] && echo hit || echo quiet)"
[[ -e "$session_dossier" ]] && quarantine_fail_state="$quarantine_fail_state dossier=present" \
                               || quarantine_fail_state="$quarantine_fail_state dossier=gone"
if [[ "$quarantine_fail_state" == "barrier=hit waiting=yes decision=allow gate_rc=0 old_finding=gone prompt_rc=0 watchdog=quiet dossier=gone" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "post-quarantine prompt revokes and retires FAIL"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "quarantined FAIL survived prompt cancellation" "$quarantine_fail_state"
fi; rm -rf "$R"

# A stale FAIL takes the park path instead of the live FAIL path. Cancellation in the
# same hidden-inode window must not let that old generation reappear as `.prev`.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="915-916-8"; write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
write_verdict "$R" FAIL '["abandoned stale finding"]' deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
session_prev="$(session_state_path "$R" last-verdict.prev.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json" \
  > "$session_dossier"
rm -f "$R/.agents/state/last-verdict.json"
write_quarantine_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" \
    BASH_ENV="$R/.agents/state/quarantine-barrier-env.sh" bash "$HOOK" ) \
    > "$R/quarantine-stale-fail.out" 2>/dev/null ) & quarantined_gate_job=$!
for (( poll_index=0; poll_index<200; poll_index++ )); do
  [[ -e "$R/.agents/state/quarantine-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-d >/dev/null 2>&1 ) & prompt_job=$!
( sleep 5; touch "$R/quarantine-watchdog-hit"; \
  kill -KILL "$quarantined_gate_job" "$prompt_job" 2>/dev/null || true ) & race_watchdog=$!
request_path="$(session_state_path "$R" verdict-request session-a)"
sleep 0.1
prompt_waiting=$(kill -0 "$prompt_job" 2>/dev/null && echo yes || echo no)
touch "$R/.agents/state/quarantine-release"
wait "$quarantined_gate_job" 2>/dev/null; quarantined_gate_rc=$?
wait "$prompt_job" 2>/dev/null; prompt_rc=$?
kill "$race_watchdog" 2>/dev/null || true; wait "$race_watchdog" 2>/dev/null || true
quarantine_park_state="barrier=$([[ -e "$R/.agents/state/quarantine-ready" ]] && echo hit || echo missed)"
quarantine_park_out="$(cat "$R/quarantine-stale-fail.out" 2>/dev/null || true)"
quarantine_park_state="$quarantine_park_state waiting=$prompt_waiting decision=$(decision_from_output "$quarantine_park_out")"
quarantine_park_state="$quarantine_park_state gate_rc=$quarantined_gate_rc prev=$([[ -e "$session_prev" ]] && echo present || echo gone)"
quarantine_park_state="$quarantine_park_state prompt_rc=$prompt_rc"
quarantine_park_state="$quarantine_park_state watchdog=$([[ -e "$R/quarantine-watchdog-hit" ]] && echo hit || echo quiet)"
quarantine_park_state="$quarantine_park_state dossier=$([[ -e "$session_dossier" ]] && echo present || echo gone)"
if [[ "$quarantine_park_state" == "barrier=hit waiting=yes decision=allow gate_rc=0 prev=gone prompt_rc=0 watchdog=quiet dossier=gone" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "prompt revocation cannot resurrect a stale FAIL park"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "canceled stale FAIL was republished" "$quarantine_park_state"
fi; rm -rf "$R"

# The prompt hook deliberately returns after three seconds if a Stop gate is wedged. A
# persistent epoch, not the mutex wait, must prevent both post-authority FAIL restore and
# post-consume stale-FAIL parking after that return boundary.
for epoch_race_mode in live-fail stale-fail; do
  R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
  generation="925-926-9"
  write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
  if [[ "$epoch_race_mode" == live-fail ]]; then
    write_verdict "$R" FAIL '["epoch live finding"]'
  else
    write_verdict "$R" FAIL '["epoch stale finding"]' deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  fi
  session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
  session_prev="$(session_state_path "$R" last-verdict.prev.json session-a)"
  request_path="$(session_state_path "$R" verdict-request session-a)"
  jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json" \
    > "$session_dossier"
  rm -f "$R/.agents/state/last-verdict.json"
  write_epoch_barrier_env "$R"
  payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
    '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
  ( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
      VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" \
      VERDICT_EPOCH_BARRIER_MODE="$epoch_race_mode" \
      BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) \
      > "$R/epoch-race.out" 2>/dev/null ) & epoch_gate_job=$!
  for (( poll_index=0; poll_index<250; poll_index++ )); do
    [[ -e "$R/.agents/state/epoch-barrier-ready" ]] && break
    sleep 0.01
  done
  ( prompt_hook "$R" session-a turn-epoch >/dev/null 2>&1 ) & epoch_prompt_job=$!
  ( sleep 8
    for doomed_pid in "$epoch_gate_job" "$epoch_prompt_job"; do
      [[ "$doomed_pid" =~ ^[1-9][0-9]*$ ]] && kill -KILL "$doomed_pid" 2>/dev/null || true
    done
  ) & epoch_watchdog=$!
  wait "$epoch_prompt_job" 2>/dev/null; epoch_prompt_rc=$?
  epoch_gate_live_after_prompt=no
  kill -0 "$epoch_gate_job" 2>/dev/null && epoch_gate_live_after_prompt=yes
  touch "$R/.agents/state/epoch-barrier-release"
  wait "$epoch_gate_job" 2>/dev/null; epoch_gate_rc=$?
  kill "$epoch_watchdog" 2>/dev/null || true; wait "$epoch_watchdog" 2>/dev/null || true
  epoch_gate_out="$(cat "$R/epoch-race.out" 2>/dev/null || true)"
  epoch_race_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
  epoch_race_state="$epoch_race_state prompt_rc=$epoch_prompt_rc gate_live=$epoch_gate_live_after_prompt"
  epoch_race_state="$epoch_race_state gate_rc=$epoch_gate_rc decision=$(decision_from_output "$epoch_gate_out")"
  epoch_race_state="$epoch_race_state request=$([[ -e "$request_path" ]] && echo present || echo gone)"
  epoch_race_state="$epoch_race_state dossier=$([[ -e "$session_dossier" ]] && echo present || echo gone)"
  epoch_race_state="$epoch_race_state prev=$([[ -e "$session_prev" ]] && echo present || echo gone)"
  if [[ "$epoch_race_state" == "barrier=hit prompt_rc=0 gate_live=yes gate_rc=0 decision=allow request=gone dossier=gone prev=gone" ]]; then
    pass=$((pass+1)); printf '  PASS  %s\n' "$epoch_race_mode cannot publish after bounded prompt return"
  else
    fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
      "$epoch_race_mode published after prompt cancellation" "$epoch_race_state"
  fi
  rm -rf "$R"
done

# The classifier can occupy nearly the whole Stop-hook timeout. A prompt arriving while
# it is blocked must make that old Stop allow at the final decision boundary, without
# recreating an audit request after the cancellation hook has returned.
for classifier_epoch_mode in regular unsafe-epoch-path; do
  R="$(setup)"; write_transcript "$R" "The deployment behaves correctly in this scenario."
  request_path="$(session_state_path "$R" verdict-request session-a)"
  epoch_path="$(session_state_path "$R" verdict-prompt-epoch session-a)"
  cat > "$R/classifier-barrier.sh" <<'CLASSIFIER_BARRIER'
#!/usr/bin/env bash
cat >/dev/null
touch "$CLAUDE_PROJECT_DIR/.agents/state/classifier-barrier-ready"
while [[ ! -e "$CLAUDE_PROJECT_DIR/.agents/state/classifier-barrier-release" ]]; do
  sleep 0.01
done
echo YES
CLASSIFIER_BARRIER
  chmod +x "$R/classifier-barrier.sh"
  payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
    '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
  ( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
      VERDICT_GATE_HARD_BLOCK=1 \
      VERDICT_CLASSIFIER_CMD="bash '$R/classifier-barrier.sh'" bash "$HOOK" ) \
      > "$R/classifier-epoch.out" 2>/dev/null ) & classifier_gate_job=$!
  for (( poll_index=0; poll_index<250; poll_index++ )); do
    [[ -e "$R/.agents/state/classifier-barrier-ready" ]] && break
    sleep 0.01
  done
  if [[ "$classifier_epoch_mode" == unsafe-epoch-path ]]; then
    mkdir "$epoch_path"
    printf 'preserve\n' > "$epoch_path/sentinel"
  fi
  ( prompt_hook "$R" session-a turn-classifier >/dev/null 2>&1 ) \
    & classifier_prompt_job=$!
  ( sleep 8; kill_test_pids KILL "$classifier_gate_job" "$classifier_prompt_job" ) \
    & classifier_watchdog=$!
  wait "$classifier_prompt_job" 2>/dev/null; classifier_prompt_rc=$?
  classifier_gate_live=no
  kill -0 "$classifier_gate_job" 2>/dev/null && classifier_gate_live=yes
  touch "$R/.agents/state/classifier-barrier-release"
  wait "$classifier_gate_job" 2>/dev/null; classifier_gate_rc=$?
  kill "$classifier_watchdog" 2>/dev/null || true
  wait "$classifier_watchdog" 2>/dev/null || true
  classifier_epoch_out="$(cat "$R/classifier-epoch.out" 2>/dev/null || true)"
  classifier_epoch_state="barrier=$([[ -e "$R/.agents/state/classifier-barrier-ready" ]] && echo hit || echo missed)"
  classifier_epoch_state="$classifier_epoch_state prompt_rc=$classifier_prompt_rc gate_live=$classifier_gate_live"
  classifier_epoch_state="$classifier_epoch_state gate_rc=$classifier_gate_rc decision=$(decision_from_output "$classifier_epoch_out")"
  classifier_epoch_state="$classifier_epoch_state request=$([[ -e "$request_path" ]] && echo present || echo gone)"
  classifier_epoch_state="$classifier_epoch_state epoch=$([[ -f "$epoch_path" && ! -L "$epoch_path" ]] && echo regular || echo unsafe)"
  if [[ "$classifier_epoch_state" == "barrier=hit prompt_rc=0 gate_live=yes gate_rc=0 decision=allow request=gone epoch=regular" ]]; then
    pass=$((pass+1)); printf '  PASS  %s\n' "$classifier_epoch_mode chime invalidates a classifier-delayed block"
  else
    fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
      "$classifier_epoch_mode classifier published after chime" "$classifier_epoch_state"
  fi
  rm -rf "$R"
done

# Recording the judged message is itself a publication edge. Pause immediately after
# that write, steer the session, and prove the old Stop retracts only its own UUID before
# it can reach triage or create a replacement request.
R="$(setup)"; write_transcript "$R" "The deployment behaves correctly in this scenario."
request_path="$(session_state_path "$R" verdict-request session-a)"
last_uuid_path="$(session_state_path "$R" verdict-last-uuid session-a)"
write_epoch_barrier_env "$R"
printf 'cksum-old-1\n' > "$last_uuid_path"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" \
    VERDICT_EPOCH_BARRIER_MODE=last-uuid-post-write \
    BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) \
    > "$R/last-uuid-epoch.out" 2>/dev/null ) & last_uuid_gate_job=$!
for (( poll_index=0; poll_index<250; poll_index++ )); do
  [[ -e "$R/.agents/state/epoch-barrier-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-last-uuid >/dev/null 2>&1 ) & last_uuid_prompt_job=$!
( sleep 8; kill_test_pids KILL "$last_uuid_gate_job" "$last_uuid_prompt_job" ) \
  & last_uuid_watchdog=$!
wait "$last_uuid_prompt_job" 2>/dev/null; last_uuid_prompt_rc=$?
last_uuid_gate_live=no; kill -0 "$last_uuid_gate_job" 2>/dev/null && last_uuid_gate_live=yes
touch "$R/.agents/state/epoch-barrier-release"
wait "$last_uuid_gate_job" 2>/dev/null; last_uuid_gate_rc=$?
kill "$last_uuid_watchdog" 2>/dev/null || true; wait "$last_uuid_watchdog" 2>/dev/null || true
last_uuid_out="$(cat "$R/last-uuid-epoch.out" 2>/dev/null || true)"
last_uuid_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
last_uuid_state="$last_uuid_state prompt_rc=$last_uuid_prompt_rc gate_live=$last_uuid_gate_live"
last_uuid_state="$last_uuid_state gate_rc=$last_uuid_gate_rc decision=$(decision_from_output "$last_uuid_out")"
last_uuid_state="$last_uuid_state uuid=$([[ -e "$last_uuid_path" ]] && echo present || echo gone)"
last_uuid_state="$last_uuid_state request=$([[ -e "$request_path" ]] && echo present || echo gone)"
if [[ "$last_uuid_state" == "barrier=hit prompt_rc=0 gate_live=yes gate_rc=0 decision=allow uuid=gone request=gone" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "chime retracts an old Stop's post-write UUID"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "old Stop retained its judged UUID after chime" "$last_uuid_state"
fi; rm -rf "$R"

# An invalid request read is only an observation. If a prompt and newer Stop replace that
# pathname before the old gate selects it, the old gate must restore—not delete—the valid
# replacement it accidentally selected.
R="$(setup)"; claim="The root cause is the stale index."; write_transcript "$R" "$claim"
request_path="$(session_state_path "$R" verdict-request session-a)"
mkdir -p "$(dirname "$request_path")"
printf '\n\n' > "$request_path"
write_epoch_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD=false \
    VERDICT_EPOCH_BARRIER_MODE=invalid-request-select \
    BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) \
    > "$R/invalid-request-race.out" 2>/dev/null ) & invalid_request_gate_job=$!
for (( poll_index=0; poll_index<250; poll_index++ )); do
  [[ -e "$R/.agents/state/epoch-barrier-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-invalid-request >/dev/null 2>&1 ) \
  & invalid_request_prompt_job=$!
( sleep 8; kill_test_pids KILL "$invalid_request_gate_job" "$invalid_request_prompt_job" ) \
  & invalid_request_watchdog=$!
wait "$invalid_request_prompt_job" 2>/dev/null; invalid_request_prompt_rc=$?
new_request_body="991-992-11 $(( $(date +%s) + 600 )) $(cksum_of "$claim")"
printf '%s\n' "$new_request_body" > "$request_path"
touch "$R/.agents/state/epoch-barrier-release"
wait "$invalid_request_gate_job" 2>/dev/null; invalid_request_gate_rc=$?
kill "$invalid_request_watchdog" 2>/dev/null || true
wait "$invalid_request_watchdog" 2>/dev/null || true
invalid_request_out="$(cat "$R/invalid-request-race.out" 2>/dev/null || true)"
preserved_request_body="$(cat "$request_path" 2>/dev/null || echo MISSING)"
invalid_request_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
invalid_request_state="$invalid_request_state prompt_rc=$invalid_request_prompt_rc gate_rc=$invalid_request_gate_rc"
invalid_request_state="$invalid_request_state decision=$(decision_from_output "$invalid_request_out") preserved=$([[ "$preserved_request_body" == "$new_request_body" ]] && echo yes || echo no)"
if [[ "$invalid_request_state" == "barrier=hit prompt_rc=0 gate_rc=0 decision=allow preserved=yes" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "invalid-request recovery preserves a post-chime replacement"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s body=%s)\n' \
    "old invalid-request cleanup deleted new authority" "$invalid_request_state" "$preserved_request_body"
fi; rm -rf "$R"

# The same select-then-check rule applies to the stale dossier removed while opening a
# fresh audit round. A native/newer writer may occupy the stable pathname after chime-in.
R="$(setup)"; claim="The root cause is the stale index."; write_transcript "$R" "$claim"
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
mkdir -p "$(dirname "$session_dossier")"
printf 'old dossier\n' > "$session_dossier"
write_epoch_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD=false \
    VERDICT_EPOCH_BARRIER_MODE=discard-dossier-select \
    BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) \
    > "$R/discard-dossier-race.out" 2>/dev/null ) & discard_dossier_gate_job=$!
for (( poll_index=0; poll_index<250; poll_index++ )); do
  [[ -e "$R/.agents/state/epoch-barrier-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-discard-dossier >/dev/null 2>&1 ) \
  & discard_dossier_prompt_job=$!
( sleep 8; kill_test_pids KILL "$discard_dossier_gate_job" "$discard_dossier_prompt_job" ) \
  & discard_dossier_watchdog=$!
wait "$discard_dossier_prompt_job" 2>/dev/null; discard_dossier_prompt_rc=$?
printf 'fresh dossier\n' > "$session_dossier"
touch "$R/.agents/state/epoch-barrier-release"
wait "$discard_dossier_gate_job" 2>/dev/null; discard_dossier_gate_rc=$?
kill "$discard_dossier_watchdog" 2>/dev/null || true
wait "$discard_dossier_watchdog" 2>/dev/null || true
discard_dossier_out="$(cat "$R/discard-dossier-race.out" 2>/dev/null || true)"
discard_dossier_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
discard_dossier_state="$discard_dossier_state prompt_rc=$discard_dossier_prompt_rc gate_rc=$discard_dossier_gate_rc"
discard_dossier_state="$discard_dossier_state decision=$(decision_from_output "$discard_dossier_out") dossier=$(cat "$session_dossier" 2>/dev/null || echo MISSING)"
if [[ "$discard_dossier_state" == "barrier=hit prompt_rc=0 gate_rc=0 decision=allow dossier=fresh dossier" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "audit-round cleanup preserves a post-chime dossier"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "old audit-round cleanup deleted a new dossier" "$discard_dossier_state"
fi; rm -rf "$R"

# Previous-FAIL expiry starts before the decision mutex. If the prompt wins before exact
# selection and a newer gate parks replacement findings, the old expiry pass restores the
# selected new inode after seeing its stale epoch.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
session_prev="$(session_state_path "$R" last-verdict.prev.json session-a)"
mkdir -p "$(dirname "$session_prev")"
printf '%s\n' '{"verdict":"FAIL","findings":["old finding"]}' > "$session_prev"
write_epoch_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD=false \
    VERDICT_EPOCH_BARRIER_MODE=prev-select \
    BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) \
    > "$R/prev-select-race.out" 2>/dev/null ) & prev_select_gate_job=$!
for (( poll_index=0; poll_index<250; poll_index++ )); do
  [[ -e "$R/.agents/state/epoch-barrier-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-prev-select >/dev/null 2>&1 ) & prev_select_prompt_job=$!
( sleep 8; kill_test_pids KILL "$prev_select_gate_job" "$prev_select_prompt_job" ) \
  & prev_select_watchdog=$!
wait "$prev_select_prompt_job" 2>/dev/null; prev_select_prompt_rc=$?
printf '%s\n' '{"verdict":"FAIL","findings":["fresh replacement finding"]}' > "$session_prev"
touch "$R/.agents/state/epoch-barrier-release"
wait "$prev_select_gate_job" 2>/dev/null; prev_select_gate_rc=$?
kill "$prev_select_watchdog" 2>/dev/null || true; wait "$prev_select_watchdog" 2>/dev/null || true
prev_select_out="$(cat "$R/prev-select-race.out" 2>/dev/null || true)"
prev_select_finding="$(jq -r '.findings[0] // "MISSING"' "$session_prev" 2>/dev/null || echo MISSING)"
prev_select_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
prev_select_state="$prev_select_state prompt_rc=$prev_select_prompt_rc gate_rc=$prev_select_gate_rc"
prev_select_state="$prev_select_state decision=$(decision_from_output "$prev_select_out") finding=$prev_select_finding"
if [[ "$prev_select_state" == "barrier=hit prompt_rc=0 gate_rc=0 decision=allow finding=fresh replacement finding" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "previous-FAIL expiry preserves a post-chime replacement"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "old previous-FAIL expiry deleted new findings" "$prev_select_state"
fi; rm -rf "$R"

# Dossier inspection pins the inode observed before the authority check. If prompt
# cancellation returns after its bounded mutex wait and a new generation publishes at
# the stable compatibility path, the old gate restores that replacement untouched.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="993-994-12"; write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
write_verdict "$R" PASS '[]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json" \
  > "$session_dossier"
rm -f "$R/.agents/state/last-verdict.json"
write_epoch_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD=false \
    VERDICT_EPOCH_BARRIER_MODE=dossier-select \
    BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) \
    > "$R/dossier-select-race.out" 2>/dev/null ) & dossier_select_gate_job=$!
for (( poll_index=0; poll_index<250; poll_index++ )); do
  [[ -e "$R/.agents/state/epoch-barrier-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-dossier-select >/dev/null 2>&1 ) \
  & dossier_select_prompt_job=$!
( sleep 10; kill_test_pids KILL "$dossier_select_gate_job" "$dossier_select_prompt_job" ) \
  & dossier_select_watchdog=$!
wait "$dossier_select_prompt_job" 2>/dev/null; dossier_select_prompt_rc=$?
new_generation="995-996-13"
write_session_request "$R" session-a "$new_generation" "$(cksum_of "$claim")"
branch="$(git -C "$R" branch --show-current)"; head="$(git -C "$R" rev-parse HEAD)"
tree="$(tree_hash_of "$R")"
jq -nc --arg b "$branch" --arg h "$head" --arg t "$tree" --arg g "$new_generation" \
  '{branch:$b,head:$h,tree_hash:$t,generation:$g,verdict:"PASS",proof:[],findings:[]}' \
  > "$session_dossier"
touch "$R/.agents/state/epoch-barrier-release"
wait "$dossier_select_gate_job" 2>/dev/null; dossier_select_gate_rc=$?
kill "$dossier_select_watchdog" 2>/dev/null || true
wait "$dossier_select_watchdog" 2>/dev/null || true
dossier_select_out="$(cat "$R/dossier-select-race.out" 2>/dev/null || true)"
dossier_select_generation="$(jq -r '.generation // "MISSING"' "$session_dossier" 2>/dev/null || echo MISSING)"
dossier_select_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
dossier_select_state="$dossier_select_state prompt_rc=$dossier_select_prompt_rc gate_rc=$dossier_select_gate_rc"
dossier_select_state="$dossier_select_state decision=$(decision_from_output "$dossier_select_out") generation=$dossier_select_generation"
if [[ "$dossier_select_state" == "barrier=hit prompt_rc=0 gate_rc=0 decision=allow generation=$new_generation" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "dossier selection preserves a post-timeout native replacement"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "old dossier inspection deleted a new generation" "$dossier_select_state"
fi; rm -rf "$R"

# Parking a stale FAIL preserves its original mtime through a hardlink, but publishing
# that link is no-clobber. A new turn's already-parked findings always win the stable name.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="997-998-14"; write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
write_verdict "$R" FAIL '["old stale finding"]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
session_prev="$(session_state_path "$R" last-verdict.prev.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json" \
  > "$session_dossier"
rm -f "$R/.agents/state/last-verdict.json"
printf 'pub fn changed() {}\n' >> "$R/src/lib.rs"
write_epoch_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD=false \
    VERDICT_EPOCH_BARRIER_MODE=park-publish \
    BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) \
    > "$R/park-publish-race.out" 2>/dev/null ) & park_publish_gate_job=$!
for (( poll_index=0; poll_index<250; poll_index++ )); do
  [[ -e "$R/.agents/state/epoch-barrier-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-park-publish >/dev/null 2>&1 ) \
  & park_publish_prompt_job=$!
( sleep 10; kill_test_pids KILL "$park_publish_gate_job" "$park_publish_prompt_job" ) \
  & park_publish_watchdog=$!
wait "$park_publish_prompt_job" 2>/dev/null; park_publish_prompt_rc=$?
printf '%s\n' '{"verdict":"FAIL","findings":["new parked finding"]}' > "$session_prev"
touch "$R/.agents/state/epoch-barrier-release"
wait "$park_publish_gate_job" 2>/dev/null; park_publish_gate_rc=$?
kill "$park_publish_watchdog" 2>/dev/null || true; wait "$park_publish_watchdog" 2>/dev/null || true
park_publish_out="$(cat "$R/park-publish-race.out" 2>/dev/null || true)"
park_publish_finding="$(jq -r '.findings[0] // "MISSING"' "$session_prev" 2>/dev/null || echo MISSING)"
park_publish_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
park_publish_state="$park_publish_state prompt_rc=$park_publish_prompt_rc gate_rc=$park_publish_gate_rc"
park_publish_state="$park_publish_state decision=$(decision_from_output "$park_publish_out") finding=$park_publish_finding"
if [[ "$park_publish_state" == "barrier=hit prompt_rc=0 gate_rc=0 decision=allow finding=new parked finding" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "stale-FAIL parking cannot clobber new-turn findings"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "old stale-FAIL park replaced new findings" "$park_publish_state"
fi; rm -rf "$R"

# Killing the delegated decision-lock holder must not let a prompt return and then allow
# the lockless gate to restore its hidden FAIL. The epoch remains authoritative even when
# that cooperative lock owner disappears.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="927-928-10"; write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
write_verdict "$R" FAIL '["decision holder finding"]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
session_prev="$(session_state_path "$R" last-verdict.prev.json session-a)"
request_path="$(session_state_path "$R" verdict-request session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json" \
  > "$session_dossier"
rm -f "$R/.agents/state/last-verdict.json"
write_quarantine_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" \
    BASH_ENV="$R/.agents/state/quarantine-barrier-env.sh" bash "$HOOK" ) \
    > "$R/decision-holder-loss.out" 2>/dev/null ) & holder_loss_gate_job=$!
for (( poll_index=0; poll_index<250; poll_index++ )); do
  [[ -s "$R/.agents/state/quarantine-decision-holder-pid" ]] && break
  sleep 0.01
done
decision_holder_pid="$(cat "$R/.agents/state/quarantine-decision-holder-pid" 2>/dev/null || echo 0)"
decision_holder_setup=invalid
if [[ "$decision_holder_pid" =~ ^[1-9][0-9]*$ ]]; then
  decision_holder_setup=valid
  kill -KILL "$decision_holder_pid" 2>/dev/null || true
fi
( prompt_hook "$R" session-a turn-holder-loss >/dev/null 2>&1 ) & holder_loss_prompt_job=$!
( sleep 8; kill_test_pids KILL "$holder_loss_gate_job" "$holder_loss_prompt_job" ) \
  & holder_loss_watchdog=$!
wait "$holder_loss_prompt_job" 2>/dev/null; holder_loss_prompt_rc=$?
touch "$R/.agents/state/quarantine-release"
wait "$holder_loss_gate_job" 2>/dev/null; holder_loss_gate_rc=$?
kill "$holder_loss_watchdog" 2>/dev/null || true; wait "$holder_loss_watchdog" 2>/dev/null || true
holder_loss_out="$(cat "$R/decision-holder-loss.out" 2>/dev/null || true)"
holder_loss_state="setup=$decision_holder_setup prompt_rc=$holder_loss_prompt_rc gate_rc=$holder_loss_gate_rc"
holder_loss_state="$holder_loss_state decision=$(decision_from_output "$holder_loss_out")"
holder_loss_state="$holder_loss_state request=$([[ -e "$request_path" ]] && echo present || echo gone)"
holder_loss_state="$holder_loss_state dossier=$([[ -e "$session_dossier" ]] && echo present || echo gone)"
holder_loss_state="$holder_loss_state prev=$([[ -e "$session_prev" ]] && echo present || echo gone)"
if [[ "$holder_loss_state" == "setup=valid prompt_rc=0 gate_rc=0 decision=allow request=gone dossier=gone prev=gone" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "decision-holder loss cannot bypass prompt revocation"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "lockless gate published after decision-holder loss" "$holder_loss_state"
fi; rm -rf "$R"

# `.prev` expiry happens before the decision mutex. Hold the selected inode for longer
# than the prompt hook's wait budget; after the chime-in returns, the old Stop must discard
# it rather than restore findings for the abandoned turn.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
session_prev="$(session_state_path "$R" last-verdict.prev.json session-a)"
mkdir -p "$(dirname "$session_prev")"
printf '%s\n' '{"verdict":"FAIL","findings":["fresh old-turn finding"]}' > "$session_prev"
write_epoch_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
( printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
    VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" \
    VERDICT_EPOCH_BARRIER_MODE=prev-restore \
    BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) \
    > "$R/prev-epoch.out" 2>/dev/null ) & prev_epoch_gate_job=$!
for (( poll_index=0; poll_index<250; poll_index++ )); do
  [[ -e "$R/.agents/state/epoch-barrier-ready" ]] && break
  sleep 0.01
done
( prompt_hook "$R" session-a turn-prev >/dev/null 2>&1 ) & prev_epoch_prompt_job=$!
( sleep 10; kill_test_pids KILL "$prev_epoch_gate_job" "$prev_epoch_prompt_job" ) \
  & prev_epoch_watchdog=$!
wait "$prev_epoch_prompt_job" 2>/dev/null; prev_epoch_prompt_rc=$?
sleep 3.2
prev_epoch_gate_live=no; kill -0 "$prev_epoch_gate_job" 2>/dev/null && prev_epoch_gate_live=yes
touch "$R/.agents/state/epoch-barrier-release"
wait "$prev_epoch_gate_job" 2>/dev/null; prev_epoch_gate_rc=$?
kill "$prev_epoch_watchdog" 2>/dev/null || true; wait "$prev_epoch_watchdog" 2>/dev/null || true
prev_epoch_out="$(cat "$R/prev-epoch.out" 2>/dev/null || true)"
prev_epoch_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
prev_epoch_state="$prev_epoch_state prompt_rc=$prev_epoch_prompt_rc gate_live=$prev_epoch_gate_live"
prev_epoch_state="$prev_epoch_state gate_rc=$prev_epoch_gate_rc decision=$(decision_from_output "$prev_epoch_out")"
prev_epoch_state="$prev_epoch_state prev=$([[ -e "$session_prev" ]] && echo present || echo gone)"
if [[ "$prev_epoch_state" == "barrier=hit prompt_rc=0 gate_live=yes gate_rc=0 decision=allow prev=gone" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "prompt epoch prevents delayed previous-FAIL restore"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "previous FAIL returned after prompt cancellation" "$prev_epoch_state"
fi; rm -rf "$R"

# Expiry selects one exact inode. If another gate parks a fresh replacement after that
# selection, stale cleanup may delete only the selected old inode, never the new pathname.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
session_prev="$(session_state_path "$R" last-verdict.prev.json session-a)"
mkdir -p "$(dirname "$session_prev")"
printf '%s\n' '{"verdict":"FAIL","findings":["old stale finding"]}' > "$session_prev"
touch -t 202001010000 "$session_prev"
write_epoch_barrier_env "$R"
payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
replacement_out="$(printf '%s' "$payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
  VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$(cls_stub "$R" YES)" \
  VERDICT_EPOCH_BARRIER_MODE=prev-replacement \
  BASH_ENV="$R/.agents/state/epoch-barrier-env.sh" bash "$HOOK" ) 2>/dev/null)"
replacement_finding="$(jq -r '.findings[0] // "MISSING"' "$session_prev" 2>/dev/null || echo MISSING)"
replacement_state="barrier=$([[ -e "$R/.agents/state/epoch-barrier-ready" ]] && echo hit || echo missed)"
replacement_state="$replacement_state finding=$replacement_finding decision=$(decision_from_output "$replacement_out")"
if [[ "$replacement_state" == "barrier=hit finding=fresh replacement finding decision=block" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "previous-FAIL expiry preserves a concurrent replacement inode"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "previous-FAIL expiry deleted a replacement" "$replacement_state"
fi; rm -rf "$R"

# jq accepts a stream of top-level values. A valid PASS followed by an object whose
# fields normalize to trailing blanks must not collapse back into the first object's
# authority through command substitution.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="916-917-6"
write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
branch="$(git -C "$R" branch --show-current)"; head="$(git -C "$R" rev-parse HEAD)"
tree="$(tree_hash_of "$R")"
jq -nc --arg b "$branch" --arg h "$head" --arg t "$tree" --arg g "$generation" \
  '{branch:$b,head:$h,tree_hash:$t,generation:$g,verdict:"PASS",proof:[],findings:[]}' \
  > "$session_dossier"
jq -nc '{branch:"",head:"",tree_hash:"",generation:null,verdict:"",proof:[],findings:[]}' \
  >> "$session_dossier"
multi_value_out="$(run_session_hook "$R" session-a YES)"
if [[ "$(decision_from_output "$multi_value_out")" == block ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "multiple top-level dossier values cannot authorize PASS"
else
  fail=$((fail+1)); printf '  FAIL  %s\n' "multiple dossier values collapsed into an authorized PASS"
fi; rm -rf "$R"

for malformed_schema_kind in \
    extra-field malformed-proof pass-findings fail-empty-findings \
    progress-empty-findings fail-blank-finding empty-claim empty-evidence \
    nul-claim nul-finding; do
  R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
  generation="917-918-7"
  write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
  session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
  branch="$(git -C "$R" branch --show-current)"; head="$(git -C "$R" rev-parse HEAD)"
  tree="$(tree_hash_of "$R")"
  jq -nc --arg b "$branch" --arg h "$head" --arg t "$tree" \
    --arg g "$generation" --arg k "$malformed_schema_kind" '
      def proof:
        {claim:"claim",kind:"other",evidence:"evidence",method:"structural",
         status:"verified",blocker:null};
      {branch:$b,head:$h,tree_hash:$t,generation:$g,verdict:"PASS",proof:[],findings:[]}
      | if $k == "extra-field" then .unexpected = true
        elif $k == "malformed-proof" then .proof = [null]
        elif $k == "pass-findings" then .findings = ["contradiction"]
        elif $k == "fail-empty-findings" then .verdict = "FAIL"
        elif $k == "progress-empty-findings" then .verdict = "IN_PROGRESS"
        elif $k == "fail-blank-finding" then .verdict = "FAIL" | .findings = [""]
        elif $k == "empty-claim" then .proof = [(proof | .claim = "")]
        elif $k == "empty-evidence" then .proof = [(proof | .evidence = "")]
        elif $k == "nul-claim" then .proof = [(proof | .claim = "\u0000")]
        elif $k == "nul-finding" then .verdict = "FAIL" | .findings = ["\u0000"]
        else . end
    ' > "$session_dossier"
  malformed_schema_out="$(run_session_hook "$R" session-a YES)"
  if [[ "$(decision_from_output "$malformed_schema_out")" == block ]]; then
    pass=$((pass+1)); printf '  PASS  %s\n' "$malformed_schema_kind cannot authorize a gate PASS"
  else
    fail=$((fail+1)); printf '  FAIL  %s\n' "$malformed_schema_kind authorized a gate PASS"
  fi
  rm -rf "$R"
done


R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="918-919-8"
write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
branch="$(git -C "$R" branch --show-current)"; head="$(git -C "$R" rev-parse HEAD)"
tree="$(tree_hash_of "$R")"
jq -nc --arg b "$branch" --arg h "$head" --arg t "$tree" --arg g "$generation" '
  {branch:$b,head:$h,tree_hash:$t,generation:$g,verdict:"PASS",
   proof:[
     {claim:"focused test passes",kind:"tests-pass",evidence:"bash test.sh: 2 passed",
      method:"rerun",status:"verified",blocker:null},
     {claim:"native host delivery",kind:"other",evidence:"host path unavailable here",
      method:"structural",status:"blocked",blocker:"native host E2E not available"}
   ],findings:[]}
' > "$session_dossier"
valid_proof_out="$(run_session_hook "$R" session-a YES)"
if [[ "$(decision_from_output "$valid_proof_out")" == allow \
   && ! -e "$session_dossier" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "verified and blocked proof entries authorize a valid gate PASS"
else
  fail=$((fail+1)); printf '  FAIL  %s\n' "valid non-empty proof was rejected"
fi; rm -rf "$R"

# The request's deadline is equally untrusted. With no width bound, Bash arithmetic wraps
# 2^64 + (now+600) and a canceled/forged request can authorize an otherwise valid PASS.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="931-932-7"; request_path="$(session_state_path "$R" verdict-request session-a)"
mkdir -p "$(dirname "$request_path")"
printf '%s %s %s\n' "$generation" "$(overflow_epoch 600)" "$(cksum_of "$claim")" \
  > "$request_path"
write_verdict "$R" PASS '[]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json" \
  > "$session_dossier"
out="$(run_session_hook "$R" session-a YES)"
fresh_generation="$(awk '{print $1}' "$request_path" 2>/dev/null || echo MISSING)"
overflow_request_state="decision=$(decision_from_output "$out")"
[[ "$fresh_generation" != "$generation" && "$fresh_generation" != MISSING ]] \
  && overflow_request_state="$overflow_request_state request=fresh" \
  || overflow_request_state="$overflow_request_state request=stale"
if [[ "$overflow_request_state" == "decision=block request=fresh" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "overflowing request deadline cannot authorize PASS"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "overflowing request deadline authorized a dossier" "$overflow_request_state"
fi; rm -rf "$R"

# The request is the authority linking a Stop message to one generation. A valid first
# line plus any second record is malformed and must not authorize a matching PASS.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="936-937-8"; request_path="$(session_state_path "$R" verdict-request session-a)"
mkdir -p "$(dirname "$request_path")"
printf '%s %s %s\nignored second record\n' \
  "$generation" "$(( $(date +%s) + 600 ))" "$(cksum_of "$claim")" > "$request_path"
write_verdict "$R" PASS '[]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json" \
  > "$session_dossier"
out="$(run_session_hook "$R" session-a YES)"
fresh_generation="$(awk '{print $1}' "$request_path" 2>/dev/null || echo MISSING)"
multiline_request_state="decision=$(decision_from_output "$out")"
[[ "$fresh_generation" != "$generation" && "$fresh_generation" != MISSING ]] \
  && multiline_request_state="$multiline_request_state request=fresh" \
  || multiline_request_state="$multiline_request_state request=stale"
if [[ "$multiline_request_state" == "decision=block request=fresh" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "a valid request prefix cannot hide a second persisted record"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "multiline request authorized a dossier" "$multiline_request_state"
fi; rm -rf "$R"

R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="938-939-9"; request_path="$(session_state_path "$R" verdict-request session-a)"
mkdir -p "$(dirname "$request_path")"
printf '%s %s %s\n\n' \
  "$generation" "$(( $(date +%s) + 600 ))" "$(cksum_of "$claim")" > "$request_path"
write_verdict "$R" PASS '[]'
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
jq --arg g "$generation" '.generation=$g' "$R/.agents/state/last-verdict.json" \
  > "$session_dossier"
out="$(run_session_hook "$R" session-a YES)"
fresh_generation="$(awk '{print $1}' "$request_path" 2>/dev/null || echo MISSING)"
blank_request_state="decision=$(decision_from_output "$out")"
[[ "$fresh_generation" != "$generation" && "$fresh_generation" != MISSING ]] \
  && blank_request_state="$blank_request_state request=fresh" \
  || blank_request_state="$blank_request_state request=stale"
if [[ "$blank_request_state" == "decision=block request=fresh" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "a trailing blank record invalidates the request"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "blank request record authorized a dossier" "$blank_request_state"
fi; rm -rf "$R"

R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
request_path="$(session_state_path "$R" verdict-request session-a)"
mkdir -p "$(dirname "$request_path")"; mkfifo "$request_path"
fifo_payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
fifo_out="$(printf '%s' "$fifo_payload" | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" \
  VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD='false' \
  perl -e 'alarm 2; exec @ARGV' bash "$HOOK" ) 2>/dev/null)"; fifo_rc=$?
fresh_generation=MISSING
[[ -f "$request_path" ]] \
  && fresh_generation="$(awk '{print $1}' "$request_path" 2>/dev/null || echo MISSING)"
fifo_request_state="rc=$fifo_rc decision=$(decision_from_output "$fifo_out")"
[[ "$fresh_generation" != MISSING ]] \
  && fifo_request_state="$fifo_request_state request=fresh" \
  || fifo_request_state="$fifo_request_state request=missing"
if [[ "$fifo_request_state" == "rc=0 decision=block request=fresh" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "FIFO request metadata → bounded replacement"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "FIFO request metadata blocked record inspection" "$fifo_request_state"
fi; rm -rf "$R"

# Dossier paths are auditor-controlled. A FIFO must be rejected as malformed without
# letting jq block the Stop hook outside any cancellable process group.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
generation="939-940-10"
write_session_request "$R" session-a "$generation" "$(cksum_of "$claim")"
dossier_path="$(session_state_path "$R" last-verdict.json session-a)"
mkfifo "$dossier_path"
( run_session_hook "$R" session-a YES > "$R/fifo-dossier.out" ) & fifo_dossier_job=$!
fifo_dossier_bounded=yes
for (( poll_index=0; poll_index<50; poll_index++ )); do kill -0 "$fifo_dossier_job" 2>/dev/null || break; sleep 0.02; done
if kill -0 "$fifo_dossier_job" 2>/dev/null; then
  fifo_dossier_bounded=no
  ( [[ -p "$dossier_path" ]] && printf '{}\n' > "$dossier_path" ) \
    & fifo_dossier_unblock_job=$!
else
  fifo_dossier_unblock_job=0
fi
( sleep 3; kill -KILL "$fifo_dossier_job" 2>/dev/null || true ) & watchdog=$!
wait "$fifo_dossier_job" 2>/dev/null; fifo_dossier_rc=$?
[[ "$fifo_dossier_unblock_job" =~ ^[1-9][0-9]*$ ]] \
  && kill -TERM "$fifo_dossier_unblock_job" 2>/dev/null || true
[[ "$fifo_dossier_unblock_job" =~ ^[1-9][0-9]*$ ]] \
  && wait "$fifo_dossier_unblock_job" 2>/dev/null || true
kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
fifo_dossier_out="$(cat "$R/fifo-dossier.out" 2>/dev/null || true)"
fifo_dossier_state="rc=$fifo_dossier_rc bounded=$fifo_dossier_bounded"
fifo_dossier_state="$fifo_dossier_state decision=$(decision_from_output "$fifo_dossier_out")"
if [[ "$fifo_dossier_state" == "rc=0 bounded=yes decision=block" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "FIFO dossier → bounded rejection"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "FIFO dossier blocked verdict inspection" "$fifo_dossier_state"
fi; rm -rf "$R"

# All authority-bearing fields must come from ONE file open. A late canceled writer can
# atomically replace the shared path between reads. The old implementation read verdict
# before generation, so old PASS + new current generation became a fabricated PASS that
# consumed the real current FAIL.
R="$(setup)"; claim="The fix works and 12/12 tests pass."; write_transcript "$R" "$claim"
old_generation="941-942-8"; current_generation="951-952-9"
write_session_request "$R" session-a "$current_generation" "$(cksum_of "$claim")"
session_dossier="$(session_state_path "$R" last-verdict.json session-a)"
branch="$(git -C "$R" branch --show-current)"; head="$(git -C "$R" rev-parse HEAD)"
tree="$(tree_hash_of "$R")"
jq -nc --arg b "$branch" --arg h "$head" --arg t "$tree" --arg g "$old_generation" \
  '{branch:$b,head:$h,tree_hash:$t,generation:$g,verdict:"PASS",proof:[],findings:[]}' \
  > "$session_dossier"
jq -nc --arg b "$branch" --arg h "$head" --arg t "$tree" --arg g "$current_generation" \
  '{branch:$b,head:$h,tree_hash:$t,generation:$g,verdict:"FAIL",proof:[],findings:["new generation failure"]}' \
  > "$R/.agents/state/current-generation-dossier"
cat > "$R/.agents/state/dossier-snapshot-env.sh" <<'DOSSIER_SNAPSHOT_ENV'
if [[ -z "${VERDICT_SNAPSHOT_OWNER_PID:-}" ]]; then
  export VERDICT_SNAPSHOT_OWNER_PID="$$"
  verdict_snapshot_debug() {
    [[ "$$" == "$VERDICT_SNAPSHOT_OWNER_PID" ]] || return 0
    if [[ "$BASH_COMMAND" == *'verdict_audit_read_json_snapshot'* \
       && "$BASH_COMMAND" == *'$dossier_quarantine'* ]]; then
      trap - DEBUG
      mv "$VERDICT_SNAPSHOT_REPLACEMENT" "$VERDICT_SNAPSHOT_TARGET"
      touch "$CLAUDE_PROJECT_DIR/.agents/state/dossier-snapshot-swapped"
    fi
  }
  set -T
  trap verdict_snapshot_debug DEBUG
fi
DOSSIER_SNAPSHOT_ENV
snapshot_payload="$(jq -nc --arg p "$R/transcript.jsonl" --arg s session-a \
  '{transcript_path:$p,hook_event_name:"Stop",session_id:$s}')"
snapshot_out="$(printf '%s' "$snapshot_payload" | ( cd "$R" \
  && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD='false' \
     BASH_ENV="$R/.agents/state/dossier-snapshot-env.sh" \
     VERDICT_SNAPSHOT_REPLACEMENT="$R/.agents/state/current-generation-dossier" \
     VERDICT_SNAPSHOT_TARGET="$session_dossier" bash "$HOOK" ) 2>/dev/null)"
snapshot_generation="$(jq -r '.generation // "MISSING"' \
  "$session_dossier" 2>/dev/null || echo MISSING)"
snapshot_state="decision=$(decision_from_output "$snapshot_out") barrier=$([[ -e "$R/.agents/state/dossier-snapshot-swapped" ]] && echo hit || echo missed)"
snapshot_state="$snapshot_state stable=$snapshot_generation spliced=no"
[[ "$snapshot_out" == *"new generation failure"* ]] \
  && snapshot_state="${snapshot_state/spliced=no/spliced=yes}"
if [[ "$snapshot_state" == \
    "decision=block barrier=hit stable=$current_generation spliced=no" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "dossier selection preserves a concurrent replacement"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s)\n' \
    "selected dossier state crossed inode boundaries" "$snapshot_state"
fi; rm -rf "$R"

kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null

echo
echo "## Present dossier, stale/mismatched binding → DISCARD + re-detect (never a bookkeeping block)"
# Tree moved after the audit, but the turn ends on a chat message → the old
# dossier is discarded and the turn ends freely. Under #915 this BLOCKED — that
# was the meaningless re-audit class.
R="$(setup)"; write_transcript "$R" "Noted — I'll wait for your call on the API shape."
write_verdict "$R" "PASS" "[]"; printf 'more\n' >> "$R/src/lib.rs"
check "tree moved + chat ending → allow"                          "$R" "allow"
check_gone "mismatched dossier discarded"                         "$R"; rm -rf "$R"

# Tree moved after the audit AND the turn still asserts a verdict → the discard
# falls through to detection, which demands a FRESH audit of the current claim.
R="$(setup)"; write_transcript "$R" "Applied the follow-up; the fix works and tests pass."
write_verdict "$R" "PASS" "[]"; printf 'more\n' >> "$R/src/lib.rs"
check "tree moved + verdict ending → block (fresh audit)"         "$R" "block"
check_gone "mismatched dossier discarded before re-detect"        "$R"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Thanks, ending here."; write_verdict "$R" "FAIL" '["x"]'
jq '.head="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"' "$R/.agents/state/last-verdict.json" > "$R/.agents/state/x" \
  && mv "$R/.agents/state/x" "$R/.agents/state/last-verdict.json"
check "HEAD-mismatched FAIL + chat ending → allow (discarded)"    "$R" "allow"
check_gone "HEAD-mismatched dossier discarded"                    "$R"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Deploy is healthy."; write_verdict "$R" "PASS" "[]"
touch -t 202001010000 "$R/.agents/state/last-verdict.json"
check "stale-mtime PASS + verdict ending → block (re-detect)"     "$R" "block"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Deploy is healthy."; write_verdict "$R" "PASS" "[]"
futuredate "$R/.agents/state/last-verdict.json" 600
check "future-mtime PASS + verdict ending → block (re-detect)"    "$R" "block"; rm -rf "$R"

echo
echo "## Tier A: harness text in the assistant slot decides without a model call"
# The assistant slot also carries text the HARNESS wrote — API errors, quota notices,
# interruption markers. No model produced it, so it asserts nothing and can never be a
# verdict. 81 of 563 real turns in this repo's transcripts (14.4%) are exactly this,
# and each one used to buy a 5-10s classifier round-trip to be told "NO".
R="$(setup)"; write_transcript "$R" "API Error: 400 Your input exceeds the context window of this model."
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '(.decision // "") != "block"' >/dev/null 2>&1 && [[ ! -e "$R/CLASSIFIER_RAN" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "harness API error only → allow, classifier never invoked"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s classifier_ran=%s)\n' "tier A skips the model" "$out" "$(classifier_ran "$R")"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "No response requested."
out="$(run_hook "$R" YES)"
if printf '%s' "$out" | jq -e '(.decision // "") != "block"' >/dev/null 2>&1 && [[ ! -e "$R/CLASSIFIER_RAN" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "harness 'No response requested.' → allow, classifier never invoked"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s classifier_ran=%s)\n' "tier A on quota//status text" "$out" "$(classifier_ran "$R")"
fi; rm -rf "$R"

# SOUNDNESS — why EVERY non-empty line must match, not just the first. A turn that did
# real work and then hit an error still owes proof... The stub says NO, so a tier A that
# wrongly swallowed these would allow, and so would a hook with no tiers at all.
R="$(setup)"; write_transcript "$R" "Root cause is the stale socket path; 12/12 tests pass."
append_assistant "$R" "API Error: Overloaded"
out="$(run_hook "$R" NO)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "real verdict THEN harness error → block (not swallowed)"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "trailing harness error swallowed the verdict" "$out"
fi; rm -rf "$R"

# ...and so does the reverse order, which is exactly what a first-line-only anchor
# leaks: a transient error, then a retry that states the verdict in the same turn.
R="$(setup)"; write_transcript "$R" "API Error: Overloaded"
append_assistant "$R" "Root cause is the stale socket path; 12/12 tests pass."
out="$(run_hook "$R" NO)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "harness error THEN real verdict → block (not swallowed)"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "leading harness error swallowed the verdict" "$out"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "API Error: Overloaded"
decide "$R" >/dev/null
if grep -q ' harness noise-allow$' "$R/.agents/state/verdict-decisions.log" 2>/dev/null; then
  pass=$((pass+1)); printf '  PASS  %s\n' "tier A decision logged (rung + outcome)"
else
  fail=$((fail+1)); printf '  FAIL  %s  (log=%s)\n' "tier A logged" "$(cat "$R/.agents/state/verdict-decisions.log" 2>/dev/null || echo MISSING)"
fi; rm -rf "$R"

echo
echo "## Tier B: assertion-only claims block without consulting the model"
# Stub answers NO throughout, so a hook without tier B reaches the model and allows.
R="$(setup)"; write_transcript "$R" "Reran the suite: 173/173 tests pass on the hook harness."
out="$(run_hook "$R" NO)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 && [[ ! -e "$R/CLASSIFIER_RAN" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "'173/173 tests pass' → block, classifier never invoked"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s classifier_ran=%s)\n' "tier B skips the model" \
    "$out" "$([[ -e "$R/CLASSIFIER_RAN" ]] && echo yes || echo no)"
fi; rm -rf "$R"

# PRECISION — the entire reason the promoted set is a small subset. A turn merely
# DISCUSSING verdict wording must still reach the classifier and be allowed; that is
# what the ambiguous majority ("tests pass", "root cause is", "deploy is healthy")
# stays behind the model for. Reaching the stub proves tier B declined.
R="$(setup)"; write_transcript "$R" "In prose people write things like tests pass or root cause is X or deploy is healthy."
out="$(run_hook "$R" NO)"
if printf '%s' "$out" | jq -e '(.decision // "") != "block"' >/dev/null 2>&1 && [[ -e "$R/CLASSIFIER_RAN" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "discussion of verdict wording → reaches the model, allowed"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s classifier_ran=%s)\n' "tier B precision" \
    "$out" "$(classifier_ran "$R")"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Verified the socket path resolves under the jailer."
out="$(run_hook "$R" NO)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 && [[ ! -e "$R/CLASSIFIER_RAN" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "line-initial 'Verified …' → block, classifier never invoked"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s classifier_ran=%s)\n' "tier B line-initial form" \
    "$out" "$(classifier_ran "$R")"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "26/26 tests pass."
decide "$R" >/dev/null
if grep -q ' assertion match-block$' "$R/.agents/state/verdict-decisions.log" 2>/dev/null; then
  pass=$((pass+1)); printf '  PASS  %s\n' "tier B decision logged (rung + outcome)"
else
  fail=$((fail+1)); printf '  FAIL  %s  (log=%s)\n' "tier B logged" "$(cat "$R/.agents/state/verdict-decisions.log" 2>/dev/null || echo MISSING)"
fi; rm -rf "$R"

echo
echo "## Slow path: a FAILed dossier survives the fix that invalidates its binding"
# Observed cycle before this: FAIL-block → agent fixes → tree moves → discard-stale →
# re-detect → block → a full COLD re-audit, every round. Parking the FAIL lets round
# N+1 re-check known findings against the delta instead of re-deriving everything.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
write_verdict "$R" "FAIL" '["tests-pass: no re-runnable command named"]' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
decide "$R" >/dev/null
if jq -e '.verdict == "FAIL"' "$R/.agents/state/last-verdict.prev.json" >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "FAIL dossier parked as prev when the binding goes stale"
else
  fail=$((fail+1)); printf '  FAIL  %s  (prev=%s)\n' "FAIL parked as prev" \
    "$(cat "$R/.agents/state/last-verdict.prev.json" 2>/dev/null || echo MISSING)"
fi
check_gone "…live dossier still discarded (re-detect, never block on bookkeeping)" "$R"; rm -rf "$R"

# An AGED-OUT FAIL means nobody acted on those findings and the round is over. Parking
# it would hand the next audit findings about unrelated work — observed live, a FAIL
# from 04:46 still being offered at 05:37 to an auditor judging a different task.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
write_verdict "$R" "FAIL" '["tests-pass: no re-runnable command named"]'
touch -t 202001010000 "$R/.agents/state/last-verdict.json"
decide "$R" >/dev/null
if [[ ! -e "$R/.agents/state/last-verdict.prev.json" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "aged-out FAIL is dropped, not parked"
else
  fail=$((fail+1)); printf '  FAIL  %s  (prev=%s)\n' "aged-out FAIL wrongly parked" \
    "$(cat "$R/.agents/state/last-verdict.prev.json" 2>/dev/null)"
fi; rm -rf "$R"

# A PASS/IN_PROGRESS that merely aged out carries nothing to re-check — it must not
# masquerade as a failed round.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
write_verdict "$R" "PASS" '[]' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
decide "$R" >/dev/null
if [[ ! -e "$R/.agents/state/last-verdict.prev.json" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "stale PASS is dropped, not parked"
else
  fail=$((fail+1)); printf '  FAIL  %s\n' "stale PASS wrongly parked as a failed round"
fi; rm -rf "$R"

# Parking is inert unless the findings actually reach the auditor.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
mkdir -p "$R/.agents/state"
printf '{"verdict":"FAIL","findings":["tests-pass: no command named"]}' > "$R/.agents/state/last-verdict.prev.json"
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.reason | test("A PRIOR audit")' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "block instruction hands the prior findings to the auditor"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "prior findings reach the auditor" "$out"
fi; rm -rf "$R"

# An UNCLAIMED park expires too. Age-gating only the write bounds staleness at park time,
# but this file is read on every later block — so an abandoned round (user changed topic,
# no re-audit ever ran) would keep feeding dead findings to an auditor judging unrelated
# work, and "a finding you cannot confirm as addressed stays a finding" turns those into a
# manufactured FAIL.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
mkdir -p "$R/.agents/state"
printf '{"verdict":"FAIL","findings":["stale round, never claimed"]}' > "$R/.agents/state/last-verdict.prev.json"
touch -t 202001010000 "$R/.agents/state/last-verdict.prev.json"
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 bash "$HOOK" ) 2>/dev/null)"
if ! printf '%s' "$out" | jq -e '.reason | test("A PRIOR audit")' >/dev/null 2>&1 \
   && [[ ! -e "$R/.agents/state/last-verdict.prev.json" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "unclaimed parked FAIL expires, never reaches the next audit"
else
  fail=$((fail+1)); printf '  FAIL  %s  (prev_still_there=%s)\n' "stale park expired" \
    "$([[ -e "$R/.agents/state/last-verdict.prev.json" ]] && echo yes || echo no)"
fi; rm -rf "$R"

# Future dating is equally invalid: a negative age must not preserve abandoned findings
# indefinitely or seed an unrelated audit with proof from a clock-skewed round.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
mkdir -p "$R/.agents/state"
printf '{"verdict":"FAIL","findings":["future-dated abandoned round"]}' \
  > "$R/.agents/state/last-verdict.prev.json"
futuredate "$R/.agents/state/last-verdict.prev.json" 600
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 bash "$HOOK" ) 2>/dev/null)"
if ! printf '%s' "$out" | jq -e '.reason | test("A PRIOR audit")' >/dev/null 2>&1 \
   && [[ ! -e "$R/.agents/state/last-verdict.prev.json" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "future-dated parked FAIL expires"
else
  fail=$((fail+1)); printf '  FAIL  %s  (prev_still_there=%s)\n' \
    "future park reached the next audit" \
    "$([[ -e "$R/.agents/state/last-verdict.prev.json" ]] && echo yes || echo no)"
fi; rm -rf "$R"

# ...but a freshly parked one is still offered, so expiry cannot swallow the live case.
# The second turn must carry DIFFERENT text: a real round writes a new turn after the fix,
# and reusing the first one trips the flush-race guard instead of reaching the park.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
write_verdict "$R" "FAIL" '["tests-pass: no re-runnable command named"]' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
decide "$R" >/dev/null                       # parks it
write_transcript "$R" "Reworked the index guard; the root cause is addressed."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.reason | test("A PRIOR audit")' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "a just-parked FAIL still reaches the next audit"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "fresh park survives expiry" "$out"
fi; rm -rf "$R"

# The cycle ended clean: a surviving prev would aim the next audit at resolved findings.
R="$(setup)"; write_transcript "$R" "Fix verified; tests pass."
mkdir -p "$R/.agents/state"
printf '{"verdict":"FAIL","findings":["x"]}' > "$R/.agents/state/last-verdict.prev.json"
write_verdict "$R" "PASS" "[]"
decide "$R" >/dev/null
if [[ ! -e "$R/.agents/state/last-verdict.prev.json" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "PASS consumption clears the parked FAIL"
else
  fail=$((fail+1)); printf '  FAIL  %s\n' "parked FAIL outlives the PASS that resolved it"
fi; rm -rf "$R"

echo
echo "## Triage (intelligent trigger): classifier decides; regex is the fallback"
# The classifier stub receives the stripped message on stdin and answers YES/NO.
# YES on a message the regex would MISS → the intelligence adds recall.
R="$(setup)"; write_transcript "$R" "The culprit was the stale socket path all along."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD='cat >/dev/null; echo YES' bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "classifier YES on regex-miss phrasing → block"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "classifier YES → block" "$out"
fi; rm -rf "$R"

# NO on a message the regex would HIT (quoting/discussion) → intelligence removes
# the static false positive.
R="$(setup)"; write_transcript "$R" "In prose people write things like tests pass or root cause is X when they conclude."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD='cat >/dev/null; echo NO' bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '(.decision // "") != "block" and .continue == true and (.systemMessage | test("triage: NO"))' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "classifier NO → allow, announced to the human only"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "classifier NO → announced allow" "$out"
fi; rm -rf "$R"

# Classifier unavailable / garbage → UNKNOWN → deterministic regex fallback still gates.
R="$(setup)"; write_transcript "$R" "All tests pass: 23/23 on the hook suite."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD='cat >/dev/null; echo MAYBE' bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "classifier garbage → regex fallback → block"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "garbage → regex fallback" "$out"
fi; rm -rf "$R"

echo
echo "## Flush-race guard: never judge a message that was already judged"
# The harness may fire Stop before appending the turn's final message; the last
# transcript entry is then the PREVIOUS turn's (already gated) message. The hook
# records the identity it judged (checksum of the text — harness-agnostic);
# seeing the same identity again → allow, never re-block.
R="$(setup)"; write_transcript "$R" "Fix verified; tests pass."   # verdict-shaped
mkdir -p "$R/.agents/state"; cksum_of "Fix verified; tests pass." > "$R/.agents/state/verdict-last-uuid"
check "stale transcript (identity already judged) → allow"       "$R" "allow"; rm -rf "$R"

# Normal path records the judged identity so the NEXT stale sighting is recognized.
R="$(setup)"; write_transcript "$R" "Deploy is healthy."
got="$(decide "$R")"
recorded="$(cat "$R/.agents/state/verdict-last-uuid" 2>/dev/null || echo MISSING)"
if [[ "$got" == "block" && "$recorded" == "$(cksum_of "Deploy is healthy.")" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "detection block records the judged identity"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s recorded=%s)\n' "identity recorded on block" "$got" "$recorded"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Anything else to adjust?"
got="$(decide "$R")"
recorded="$(cat "$R/.agents/state/verdict-last-uuid" 2>/dev/null || echo MISSING)"
if [[ "$got" == "allow" && "$recorded" == "$(cksum_of "Anything else to adjust?")" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "detection allow records the judged identity"
else
  fail=$((fail+1)); printf '  FAIL  %s  (got=%s recorded=%s)\n' "identity recorded on allow" "$got" "$recorded"
fi; rm -rf "$R"

echo
echo "## Turn-level extraction: mid-turn findings cannot hide behind closing narration"
# The classifier stub greps its stdin for the finding — proving the JOINED turn
# text (not just the trailing fragment) is what triage judges. This is the class
# a sibling session's decision log caught escaping: finding asserted mid-turn,
# turn ends on "let me check X".
GREP_STUB='text="$(cat)"; printf "%s" "$text" | grep -q "1:1 port" && echo YES || echo NO'

R="$(setup)"; write_transcript "$R" "The activity service is a 1:1 port of upstream; there is no auto-start in the proxy."
append_assistant "$R" "Let me check what the standalone proxy serves next."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$GREP_STUB" bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "mid-turn finding + closing narration → block (joined text judged)"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "mid-turn finding → block" "$out"
fi; rm -rf "$R"

# The dominant real-transcript shape: a tool call sits between the finding and
# the closing narration. ARRAY-shaped tool_results nest text blocks inside the
# tool_result — they must not split the turn (that miss shipped once).
R="$(setup)"; write_transcript "$R" "The activity service is a 1:1 port of upstream; there is no auto-start in the proxy."
append_tool_result_array "$R" "src/proxy.go: 200 lines, no timer, no activity import"
append_assistant "$R" "Let me check what the standalone proxy serves next."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$GREP_STUB" bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "array tool_result mid-turn does not split the turn → block"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "array tool_result mid-turn" "$out"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "The activity service is a 1:1 port of upstream; there is no auto-start in the proxy."
append_tool_result_string "$R" "ok"
append_assistant "$R" "Let me check what the standalone proxy serves next."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$GREP_STUB" bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "string tool_result mid-turn does not split the turn → block"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "string tool_result mid-turn" "$out"
fi; rm -rf "$R"

# Same finding but in a PREVIOUS turn (real user message between): the final
# turn is narration only — must not retrigger.
R="$(setup)"; write_transcript "$R" "The activity service is a 1:1 port of upstream; there is no auto-start in the proxy."
append_user "$R" "ok — check the proxy then"
append_assistant "$R" "Let me check what the standalone proxy serves next."
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$GREP_STUB" bash "$HOOK" ) 2>/dev/null)"
if ! printf '%s' "$out" | jq -e '(.decision // "") == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "same finding in a previous turn → allow (turn boundary respected)"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "previous-turn finding → allow" "$out"
fi; rm -rf "$R"

# Codex rollout shape, same semantics: user boundary + two assistant texts join.
R="$(setup)"
jq -nc '{type:"response_item", payload:{type:"message", role:"user", content:[{type:"input_text", text:"compare with upstream"}]}}' > "$R/transcript.jsonl"
jq -nc '{type:"response_item", payload:{type:"message", role:"assistant", content:[{type:"output_text", text:"The activity service is a 1:1 port of upstream."}]}}' >> "$R/transcript.jsonl"
jq -nc '{type:"response_item", payload:{type:"message", role:"assistant", content:[{type:"output_text", text:"Let me check the proxy next."}]}}' >> "$R/transcript.jsonl"
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_CLASSIFIER_CMD="$GREP_STUB" bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "codex shape: mid-turn finding joined across records → block"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "codex turn-level" "$out"
fi; rm -rf "$R"

echo
echo "## Harness-agnostic extraction: conventions, not schema lists"
R="$(setup)"; write_codex_transcript "$R" "Root cause is the missing bind mount; all tests pass now."
check "codex rollout schema, verdict → block"                    "$R" "block"
recorded="$(cat "$R/.agents/state/verdict-last-uuid" 2>/dev/null || echo MISSING)"
if [[ "$recorded" == cksum-* ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "codex record (no id) → checksum identity recorded"
else
  fail=$((fail+1)); printf '  FAIL  %s  (recorded=%s)\n' "checksum identity" "$recorded"
fi; rm -rf "$R"

R="$(setup)"; write_codex_transcript "$R" "Which retry policy do you prefer here?"
check "codex rollout schema, chat → allow"                       "$R" "allow"; rm -rf "$R"

# Race guard on content identity: same text → same checksum → stale.
R="$(setup)"; write_codex_transcript "$R" "Deploy is healthy."
mkdir -p "$R/.agents/state"; cksum_of "Deploy is healthy." > "$R/.agents/state/verdict-last-uuid"
check "codex stale (identity already judged) → allow"            "$R" "allow"; rm -rf "$R"

# The acceptance test for "all kinds of coding agents": a schema NO harness uses
# today must work with ZERO hook changes.
R="$(setup)"; write_future_agent_transcript "$R" "Root cause is the stale DNS cache; fix verified."
check "invented future-agent schema, verdict → block"            "$R" "block"; rm -rf "$R"

R="$(setup)"; write_future_agent_transcript "$R" "Want me to sketch the two options first?"
check "invented future-agent schema, chat → allow"               "$R" "allow"; rm -rf "$R"

# VERDICT_EXTRACTOR_CMD: the escape hatch for a truly alien (non-JSONL) format.
R="$(setup)"; printf 'PLAIN TEXT LOG. verdict: tests pass\n' > "$R/transcript.jsonl"
out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=1 VERDICT_EXTRACTOR_CMD='tail -n1' bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass+1)); printf '  PASS  %s\n' "custom extractor (non-JSONL format) → block"
else
  fail=$((fail+1)); printf '  FAIL  %s  (out=%s)\n' "custom extractor" "$out"
fi; rm -rf "$R"

echo
echo "## Chinese fallback patterns"
R="$(setup)"; write_transcript "$R" "排查结束：根因是 gvproxy 套接字路径冲突，已修复。"
check "中文 verdict (根因是/已修复) → block"                       "$R" "block"; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "接下来你想先看哪个模块？我可以先画个调用图。"
check "中文 chat → allow"                                         "$R" "allow"; rm -rf "$R"

echo
echo "## Decision log: every Stop decision leaves one greppable line"
R="$(setup)"; write_transcript "$R" "Deploy is healthy."
decide "$R" >/dev/null
if grep -q ' regex match-block$' "$R/.agents/state/verdict-decisions.log" 2>/dev/null; then
  pass=$((pass+1)); printf '  PASS  %s\n' "block decision logged (rung + outcome)"
else
  fail=$((fail+1)); printf '  FAIL  %s  (log=%s)\n' "block logged" "$(cat "$R/.agents/state/verdict-decisions.log" 2>/dev/null || echo MISSING)"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Anything else to adjust?"
decide "$R" >/dev/null
if grep -q ' regex none-allow$' "$R/.agents/state/verdict-decisions.log" 2>/dev/null; then
  pass=$((pass+1)); printf '  PASS  %s\n' "allow decision logged"
else
  fail=$((fail+1)); printf '  FAIL  %s  (log=%s)\n' "allow logged" "$(cat "$R/.agents/state/verdict-decisions.log" 2>/dev/null || echo MISSING)"
fi; rm -rf "$R"

# In-place rotation must not follow a hard link and truncate a file outside runtime
# state. Logging is best-effort, so a multiply linked inode is rejected unchanged.
R="$(setup)"; write_transcript "$R" "Deploy is healthy."
outside_log="$R/outside-owned.log"
decision_log_path="$R/.agents/state/verdict-decisions.log"
mkdir -p "$(dirname "$decision_log_path")"
printf 'outside sentinel\n' > "$outside_log"
ln "$outside_log" "$decision_log_path"
decide "$R" >/dev/null
hardlink_log_state="$(cat "$outside_log" 2>/dev/null || echo MISSING)"
if [[ "$hardlink_log_state" == "outside sentinel" ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "decision logging rejects a multiply linked inode"
else
  fail=$((fail+1)); printf '  FAIL  %s  (outside=%s)\n' \
    "decision logging rewrote a hard-linked file" "$hardlink_log_state"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Deploy is healthy."
decision_log_path="$R/.agents/state/verdict-decisions.log"
mkdir -p "$(dirname "$decision_log_path")"
perl -MFcntl=:flock -e '
  my ($path, $ready) = @ARGV;
  open(my $fh, ">>", $path) or exit 2;
  flock($fh, LOCK_EX) or exit 2;
  open(my $mark, ">", $ready) or exit 2;
  close($mark);
  sleep 30;
' "$decision_log_path" "$R/log-lock-ready" & log_holder_pid=$!
for (( poll_index=0; poll_index<100; poll_index++ )); do
  [[ -e "$R/log-lock-ready" ]] && break
  sleep 0.01
done
log_started="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
log_lock_decision="$(decide "$R")"
log_finished="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
kill -TERM "$log_holder_pid" 2>/dev/null || true; wait "$log_holder_pid" 2>/dev/null || true
log_elapsed_ok="$(perl -e 'print(($ARGV[1] - $ARGV[0]) < 1.5 ? "yes" : "no")' \
  "$log_started" "$log_finished")"
if [[ "$log_elapsed_ok" == yes && "$log_lock_decision" == block ]]; then
  pass=$((pass+1)); printf '  PASS  %s\n' "a held decision-log flock cannot delay the Stop decision"
else
  fail=$((fail+1)); printf '  FAIL  %s  (bounded=%s decision=%s)\n' \
    "decision logging waited on another writer" "$log_elapsed_ok" "$log_lock_decision"
fi; rm -rf "$R"

R="$(setup)"; write_transcript "$R" "Fix verified; tests pass."; write_verdict "$R" "PASS" "[]"
decide "$R" >/dev/null
if grep -q ' dossier PASS-allow$' "$R/.agents/state/verdict-decisions.log" 2>/dev/null; then
  pass=$((pass+1)); printf '  PASS  %s\n' "dossier consumption logged"
else
  fail=$((fail+1)); printf '  FAIL  %s  (log=%s)\n' "dossier logged" "$(cat "$R/.agents/state/verdict-decisions.log" 2>/dev/null || echo MISSING)"
fi; rm -rf "$R"

echo
echo "## Soft mode (VERDICT_GATE_HARD_BLOCK=0 ONLY): block conditions become nudges"
# Soft is an EXPLICIT opt-out, not the default. It used to be reached by leaving the
# variable unset, which meant only Claude Code — the sole caller that sets it, via
# settings.json env — was ever gated; the Codex registration and any direct
# invocation silently got a nudge. The unset case is asserted to BLOCK below.
R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
soft_out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK=0 bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$soft_out" | jq -e '(.decision // "") != "block" and .continue == true and (.systemMessage | type) == "string"' >/dev/null 2>&1; then
  pass=$((pass + 1)); printf '  PASS  %s\n' "detected verdict → nudge in soft mode, not block"
else
  fail=$((fail + 1)); printf '  FAIL  %s  (out=%s)\n' "soft-mode detection nudge" "$soft_out"
fi
rm -rf "$R"

R="$(setup)"; write_transcript "$R" "The root cause is the stale index."
unset_out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
  | ( cd "$R" && env -u VERDICT_GATE_HARD_BLOCK CLAUDE_PROJECT_DIR="$R" bash "$HOOK" ) 2>/dev/null)"
if printf '%s' "$unset_out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass=$((pass + 1)); printf '  PASS  %s\n' "unset VERDICT_GATE_HARD_BLOCK blocks (documented default is hard)"
else
  fail=$((fail + 1)); printf '  FAIL  %s  (out=%.120s)\n' "unset VERDICT_GATE_HARD_BLOCK blocks (documented default is hard)" "$unset_out"
fi
rm -rf "$R"

# One repo per mode. Both calls used to share one, and the first writes
# verdict-last-uuid, so the second returned "transcript unchanged since last
# judgment" without ever consulting its mode — this case named two modes and
# exercised one. Rejecting that short-circuit is part of the assertion: it is an
# allow like any other, so "neither blocked" alone would still pass on it.
chat_ok=yes
chat_detail=""
for chat_mode in 0 1; do
  R="$(setup)"; write_transcript "$R" "Anything else you want changed?"
  chat_out="$(jq -nc --arg p "$R/transcript.jsonl" '{transcript_path:$p, hook_event_name:"Stop"}' \
    | ( cd "$R" && CLAUDE_PROJECT_DIR="$R" VERDICT_GATE_HARD_BLOCK="$chat_mode" bash "$HOOK" ) 2>/dev/null)"
  if [[ -n "$chat_out" ]] && printf '%s' "$chat_out" | jq -e '(.decision // "") == "block"' >/dev/null 2>&1; then
    chat_ok=no
  fi
  printf '%s' "$chat_out" | grep -q 'transcript unchanged' && chat_ok=no
  chat_detail="$chat_detail mode=$chat_mode:$(printf '%.60s' "$chat_out")"
  rm -rf "$R"
done
if [[ "$chat_ok" == "yes" ]]; then
  pass=$((pass + 1)); printf '  PASS  %s\n' "chat turn → allow via triage in soft AND hard"
else
  fail=$((fail + 1)); printf '  FAIL  %s (%s)\n' "chat turn → allow via triage in soft AND hard" "$chat_detail"
fi

echo
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
