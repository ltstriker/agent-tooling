#!/usr/bin/env bash
# Contract tests for the auditor escalation and prompt-scoped override control plane.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTROL="$REPO_ROOT/.agents/hooks/auditor-control.sh"
STATE_LIB="$REPO_ROOT/.agents/lib/auditor-override-state.sh"
VERDICT_STATE_LIB="$REPO_ROOT/.agents/lib/verdict-audit-state.sh"
VERDICT_GATE="$REPO_ROOT/.agents/hooks/preflight-verdict-check.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got=$2 want=$3)"; fi
}

setup() {
  local repo
  repo="$(mktemp -d)"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.test
  git -C "$repo" config user.name tester
  printf 'x\n' > "$repo/f"
  printf '.agents/state/\n' > "$repo/.gitignore"
  git -C "$repo" add -A
  git -C "$repo" commit -qm base
  mkdir -p "$repo/.agents/state"
  printf '%s' "$repo"
}

scope_of() {
  printf 'git-%s' "$(printf '%s' "$2" | git -C "$1" hash-object --stdin)"
}

hook() {
  local repo="$1" payload="$2"
  printf '%s' "$payload" | (
    cd "$repo" && CLAUDE_PROJECT_DIR="$repo" AUDITOR_PROMPT_AFTER_SECONDS=0 bash "$CONTROL"
  )
}

write_codex_subagent_transcript() {  # path, parent session, agent id, agent path
  jq -nc --arg parent "$2" --arg id "$3" --arg path "$4" \
    '{type:"session_meta",payload:{id:$id,session_id:$parent,thread_source:"subagent",
      source:{subagent:{thread_spawn:{parent_thread_id:$parent,depth:1,
        agent_path:$path,agent_nickname:"test",agent_role:null}}}}}' > "$1"
  jq -nc '{type:"event_msg",payload:{type:"task_started"}}' >> "$1"
}

R="$(setup)"
session="session-a"
scope="$(scope_of "$R" "$session")"
epoch_file="$R/.agents/state/verdict-prompt-epoch.$scope"
printf '101-102-3\n' > "$epoch_file"

echo "## Escalation opens once and terminal state closes it"
start_payload="$(jq -nc --arg s "$session" --arg id audit-1 \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"verdict-auditor"}')"
start_out="$(hook "$R" "$start_payload")"; start_rc=$?
prompt_file="$R/.agents/state/auditor-control/prompt.$scope.verdict-auditor.audit-1.json"
event_file="$R/.agents/state/auditor-control/events.$scope.jsonl"
start_state="rc=$start_rc open=$(jq -r '.state' "$prompt_file" 2>/dev/null) choices=$(jq -r '.choices | join(",")' "$prompt_file" 2>/dev/null) note=$(printf '%s' "$start_out" | jq -r 'has("systemMessage")' 2>/dev/null)"
check_eq "a verdict auditor opens the three-choice prompt after the threshold" "$start_state" \
  "rc=0 open=open choices=keep_waiting,override_all,cancel_task note=true"

hook "$R" "$start_payload" >/dev/null
open_count="$(jq -r 'select(.event == "opened") | .generation' "$event_file" 2>/dev/null | wc -l | tr -d ' ')"
check_eq "one audit generation opens at most one prompt" "$open_count" 1

stop_payload="$(jq -nc --arg s "$session" --arg id audit-1 \
  '{hook_event_name:"SubagentStop",session_id:$s,agent_id:$id,agent_type:"verdict-auditor",last_assistant_message:"PASS"}')"
hook "$R" "$stop_payload" >/dev/null
check_eq "a terminal PASS closes the prompt without manufacturing a dossier" \
  "$(jq -r '.state + ":" + .terminal' "$prompt_file") dossier=$([[ -e "$R/.agents/state/last-verdict.json.$scope" ]] && echo yes || echo no)" \
  "closed:PASS dossier=no"

echo "## Codex default agent types resolve through bound transcript metadata"
printf '111-112-4\n' > "$epoch_file"
codex_id=codex-audit-1
codex_transcript="$R/codex-subagent.jsonl"
write_codex_subagent_transcript "$codex_transcript" "$session" "$codex_id" \
  /root/verdict_auditor_live_test
codex_start="$(jq -nc --arg s "$session" --arg id "$codex_id" --arg transcript "$codex_transcript" \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"default",
    transcript_path:$transcript}')"
codex_start_out="$(hook "$R" "$codex_start")"; codex_start_rc=$?
codex_prompt="$R/.agents/state/auditor-control/prompt.$scope.verdict-auditor.$codex_id.json"
check_eq "a real Codex default-type verdict auditor opens the prompt" \
  "rc=$codex_start_rc state=$(jq -r '.state // "missing"' "$codex_prompt" 2>/dev/null) note=$(printf '%s' "$codex_start_out" | jq -r 'has("systemMessage")' 2>/dev/null)" \
  "rc=0 state=open note=true"

codex_stop="$(jq -nc --arg s "$session" --arg id "$codex_id" --arg transcript "$codex_transcript" \
  '{hook_event_name:"SubagentStop",session_id:$s,agent_id:$id,agent_type:"default",
    agent_transcript_path:$transcript,last_assistant_message:"PASS"}')"
hook "$R" "$codex_stop" >/dev/null
check_eq "the matching Codex terminal event closes that prompt" \
  "$(jq -r '.state + ":" + .terminal' "$codex_prompt" 2>/dev/null)" "closed:PASS"

mismatch_transcript="$R/codex-subagent-mismatch.jsonl"
write_codex_subagent_transcript "$mismatch_transcript" "$session" some-other-agent \
  /root/verdict_auditor_mismatch
mismatch_payload="$(jq -nc --arg s "$session" --arg id mismatch-1 --arg transcript "$mismatch_transcript" \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"default",
    transcript_path:$transcript}')"
hook "$R" "$mismatch_payload" >/dev/null 2>&1; mismatch_rc=$?
check_eq "transcript metadata must bind to the hook agent id" "$mismatch_rc" 2

echo "## Typed override is exact, prompt-scoped, and race-safe"
start_two="$(jq -nc --arg s "$session" --arg id audit-2 \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"commit-push-auditor"}')"
hook "$R" "$start_two" >/dev/null

mention_payload="$(jq -nc --arg s "$session" --arg p 'please discuss force-pass-auditors: because it is slow' \
  '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:$p}')"
mention_out="$(printf '%s' "$mention_payload" | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$CONTROL" handle-prompt 101-102-3 201-202-4))"
grant_file="$R/.agents/state/auditor-control/grant.$scope.json"
check_eq "an ordinary mention does not activate the override" \
  "grant=$([[ -e "$grant_file" ]] && echo yes || echo no) output=${mention_out:-}" \
  "grant=no output="

# The normal prompt above intentionally revokes the prior generation. Open a fresh one
# in the new prompt epoch before testing the exact directive.
printf '201-202-4\n' > "$epoch_file"
start_three="$(jq -nc --arg s "$session" --arg id audit-3 \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"commit-push-auditor"}')"
hook "$R" "$start_three" >/dev/null
override_payload="$(jq -nc --arg s "$session" --arg p $'\nforce-pass-auditors: release is time-critical\nextra context' \
  '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:$p}')"
override_out="$(printf '%s' "$override_payload" | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$CONTROL" handle-prompt 201-202-4 301-302-5))"
printf '301-302-5\n' > "$epoch_file"
# shellcheck source=../lib/verdict-audit-state.sh
source "$VERDICT_STATE_LIB"
# shellcheck source=../lib/auditor-override-state.sh
source "$STATE_LIB"
if auditor_override_load_valid_grant "$R" "$scope" "301-302-5"; then grant_valid=yes; else grant_valid=no; fi
grant_state="valid=$grant_valid result=$(printf '%s' "$override_out" | jq -r '.hookSpecificOutput.additionalContext | startswith("OVERRIDDEN BY USER")' 2>/dev/null) token_leaked=$(printf '%s' "$override_out" | grep -Eq '[0-9a-f]{32,}' && echo yes || echo no)"
check_eq "the exact first non-empty directive activates a nonce-hashed grant without leaking its bearer" \
  "$grant_state" "valid=yes result=true token_leaked=no"

stop_out="$(jq -nc --arg s "$session" \
  '{hook_event_name:"Stop",session_id:$s,last_assistant_message:"tests pass",stop_hook_active:false}' \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$VERDICT_GATE"))"
check_eq "Stop records an override outcome without writing a PASS dossier" \
  "note=$(printf '%s' "$stop_out" | jq -r '.systemMessage | contains("OVERRIDDEN BY USER")') dossier=$([[ -e "$R/.agents/state/last-verdict.json.$scope" ]] && echo yes || echo no)" \
  "note=true dossier=no"

normal_payload="$(jq -nc --arg s "$session" --arg p 'next request' \
  '{hook_event_name:"UserPromptSubmit",session_id:$s,prompt:$p}')"
printf '%s' "$normal_payload" | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$CONTROL" handle-prompt 301-302-5 401-402-6) >/dev/null
check_eq "the next real prompt revokes the grant" \
  "$([[ -e "$grant_file" ]] && echo present || echo absent)" absent

printf '401-402-6\n' > "$epoch_file"
start_four="$(jq -nc --arg s "$session" --arg id audit-4 \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"verdict-auditor"}')"
hook "$R" "$start_four" >/dev/null
stop_four="$(jq -nc --arg s "$session" --arg id audit-4 \
  '{hook_event_name:"SubagentStop",session_id:$s,agent_id:$id,agent_type:"verdict-auditor",last_assistant_message:"FAIL"}')"
hook "$R" "$stop_four" >/dev/null
late_out="$(printf '%s' "$override_payload" | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$CONTROL" handle-prompt 401-402-6 501-502-7))"
check_eq "an override arriving after terminal completion is ignored" \
  "grant=$([[ -e "$grant_file" ]] && echo yes || echo no) ignored=$(printf '%s' "$late_out" | jq -r '.systemMessage | contains("ignored")' 2>/dev/null)" \
  "grant=no ignored=true"

echo "## Host card selections use the same race-checked state"
printf '601-602-8\n' > "$epoch_file"
start_five="$(jq -nc --arg s "$session" --arg id audit-5 \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"verdict-auditor"}')"
hook "$R" "$start_five" >/dev/null
keep_out="$(jq -nc --arg s "$session" \
  '{session_id:$s,choice:"keep_waiting"}' \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$CONTROL" select))"
keep_prompt="$R/.agents/state/auditor-control/prompt.$scope.verdict-auditor.audit-5.json"
keep_active="$R/.agents/state/auditor-control/active.$scope.verdict-auditor.json"
check_eq "Keep waiting closes the one-shot card but leaves the auditor active" \
  "accepted=$(printf '%s' "$keep_out" | jq -r '.accepted') prompt=$(jq -r '.terminal' "$keep_prompt") active=$([[ -e "$keep_active" ]] && echo yes || echo no)" \
  "accepted=true prompt=keep-waiting active=yes"
stop_five="$(jq -nc --arg s "$session" --arg id audit-5 \
  '{hook_event_name:"SubagentStop",session_id:$s,agent_id:$id,agent_type:"verdict-auditor",last_assistant_message:"PASS"}')"
hook "$R" "$stop_five" >/dev/null

start_six="$(jq -nc --arg s "$session" --arg id audit-6 \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"verdict-auditor"}')"
hook "$R" "$start_six" >/dev/null
cancel_out="$(jq -nc --arg s "$session" \
  '{session_id:$s,choice:"cancel_task"}' \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$CONTROL" select))"
check_eq "Cancel task closes the card and revokes active auditor state without a grant" \
  "outcome=$(printf '%s' "$cancel_out" | jq -r '.outcome') active=$([[ -e "$keep_active" ]] && echo yes || echo no) grant=$([[ -e "$grant_file" ]] && echo yes || echo no)" \
  "outcome=cancel-task active=no grant=no"

echo "## Concurrent terminal state and unsafe mutexes fail closed"
race_mixed=no
for race_index in $(seq 1 40); do
  race_epoch="$((700 + race_index))-800-$race_index"
  printf '%s\n' "$race_epoch" > "$epoch_file"
  rm -f "$grant_file"
  race_id="race-$race_index"
  race_start="$(jq -nc --arg s "$session" --arg id "$race_id" \
    '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"verdict-auditor"}')"
  hook "$R" "$race_start" >/dev/null
  race_stop="$(jq -nc --arg s "$session" --arg id "$race_id" \
    '{hook_event_name:"SubagentStop",session_id:$s,agent_id:$id,agent_type:"verdict-auditor",last_assistant_message:"PASS"}')"
  race_select="$(jq -nc --arg s "$session" \
    '{session_id:$s,choice:"override_all",reason:"race test"}')"
  hook "$R" "$race_stop" >/dev/null & race_stop_pid=$!
  printf '%s' "$race_select" \
    | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$CONTROL" select) >/dev/null & race_select_pid=$!
  wait "$race_stop_pid"; wait "$race_select_pid"
  race_prompt="$R/.agents/state/auditor-control/prompt.$scope.verdict-auditor.$race_id.json"
  if [[ "$(jq -r '.terminal // ""' "$race_prompt" 2>/dev/null)" == PASS \
        && -e "$grant_file" ]]; then
    race_mixed=yes
    break
  fi
done
check_eq "terminal and override cannot publish a mixed PASS-plus-grant outcome" \
  "$race_mixed" no

printf '850-851-41\n' > "$epoch_file"
rm -f "$grant_file"
priority_start="$(jq -nc --arg s "$session" --arg id terminal-priority \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"verdict-auditor"}')"
hook "$R" "$priority_start" >/dev/null
priority_select="$(jq -nc --arg s "$session" \
  '{session_id:$s,choice:"override_all",reason:"terminal priority test"}')"
printf '%s' "$priority_select" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" AUDITOR_TERMINAL_GRACE_MILLISECONDS=250 \
      bash "$CONTROL" select) > "$R/priority-select.out" & priority_select_pid=$!
perl -e 'select(undef,undef,undef,0.05)'
priority_stop="$(jq -nc --arg s "$session" --arg id terminal-priority \
  '{hook_event_name:"SubagentStop",session_id:$s,agent_id:$id,agent_type:"verdict-auditor",last_assistant_message:"PASS"}')"
hook "$R" "$priority_stop" >/dev/null
wait "$priority_select_pid"
priority_prompt="$R/.agents/state/auditor-control/prompt.$scope.verdict-auditor.terminal-priority.json"
priority_state="terminal=$(jq -r '.terminal // ""' "$priority_prompt") grant=$([[ -e "$grant_file" ]] && echo yes || echo no) outcome=$(jq -r '.outcome // ""' "$R/priority-select.out")"
check_eq "a terminal result arriving during card selection wins the race" \
  "$priority_state" "terminal=PASS grant=no outcome=ignored-terminal-race"

rm -f "$grant_file"
printf '901-902-9\n' > "$epoch_file"
unsafe_mutex="$R/.agents/state/auditor-control/control.$scope.mutex"
rm -f "$unsafe_mutex"
mkfifo "$R/control-fifo"
ln -s "$R/control-fifo" "$unsafe_mutex"
unsafe_payload="$(jq -nc --arg s "$session" --arg id unsafe-1 \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"verdict-auditor"}')"
printf '%s' "$unsafe_payload" \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" AUDITOR_PROMPT_AFTER_SECONDS=0 bash "$CONTROL") \
      >/dev/null 2>&1 & unsafe_pid=$!
unsafe_state=running
for _ in $(seq 1 20); do
  if ! kill -0 "$unsafe_pid" 2>/dev/null; then unsafe_state=finished; break; fi
  perl -e 'select(undef,undef,undef,0.05)'
done
if [[ "$unsafe_state" == running ]]; then
  kill "$unsafe_pid" 2>/dev/null || true
  wait "$unsafe_pid" 2>/dev/null || true
  unsafe_result=hung
else
  wait "$unsafe_pid"; unsafe_rc=$?
  unsafe_result="rc=$unsafe_rc"
fi
check_eq "a symlink-to-FIFO control mutex is rejected without blocking" \
  "$unsafe_result" "rc=2"
rm -f "$unsafe_mutex" "$R/control-fifo"

printf '951-952-10\n' > "$epoch_file"
unsafe_stop_start="$(jq -nc --arg s "$session" --arg id unsafe-stop \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"verdict-auditor"}')"
hook "$R" "$unsafe_stop_start" >/dev/null
unsafe_stop_prompt="$R/.agents/state/auditor-control/prompt.$scope.verdict-auditor.unsafe-stop.json"
unsafe_stop_active="$R/.agents/state/auditor-control/active.$scope.verdict-auditor.json"
rm -f "$unsafe_mutex"
mkfifo "$R/stop-fifo"
ln -s "$R/stop-fifo" "$unsafe_mutex"
CLAUDE_PROJECT_DIR="$R" bash "$CONTROL" external-stop verdict-auditor unsafe-stop \
  "$scope" PASS >/dev/null 2>&1
unsafe_external_stop_rc=$?
check_eq "external terminal cleanup reports an unsafe mutex to its caller" \
  "rc=$unsafe_external_stop_rc prompt=$(jq -r '.state' "$unsafe_stop_prompt") active=$([[ -e "$unsafe_stop_active" ]] && echo yes || echo no)" \
  "rc=2 prompt=open active=yes"

unsafe_stop_payload="$(jq -nc --arg s "$session" --arg id unsafe-stop \
  '{hook_event_name:"SubagentStop",session_id:$s,agent_id:$id,agent_type:"verdict-auditor",
    last_assistant_message:"PASS"}')"
hook "$R" "$unsafe_stop_payload" >/dev/null 2>&1
unsafe_native_stop_rc=$?
check_eq "native terminal cleanup also reports an unsafe mutex" "$unsafe_native_stop_rc" 2
rm -f "$unsafe_mutex" "$R/stop-fifo"
hook "$R" "$unsafe_stop_payload" >/dev/null

printf '1001-1002-10\n' > "$epoch_file"
log_start="$(jq -nc --arg s "$session" --arg id log-1 \
  '{hook_event_name:"SubagentStart",session_id:$s,agent_id:$id,agent_type:"verdict-auditor"}')"
hook "$R" "$log_start" >/dev/null
jq -nc --arg s "$session" '{session_id:$s,choice:"override_all",reason:"log test"}' \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$CONTROL" select) >/dev/null
uses_log="$R/.agents/state/auditor-control/uses.$scope.log"
rm -f "$uses_log"
ln -s "$R/outside-use-log" "$uses_log"
printf 'outside\n' > "$R/outside-use-log"
log_gate_out="$(jq -nc --arg s "$session" \
  '{hook_event_name:"Stop",session_id:$s,last_assistant_message:"tests pass",stop_hook_active:false}' \
  | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$VERDICT_GATE"))"
check_eq "Stop blocks when OVERRIDDEN use evidence cannot be recorded" \
  "$(printf '%s' "$log_gate_out" | jq -r '.decision // "allow"')" block
rm -f "$uses_log" "$R/outside-use-log"

echo "## Every shipped auditor is registered"
known="$($CONTROL --known-auditors 2>/dev/null | sort)"
specs="$(find "$REPO_ROOT/.claude/agents" -name '*-auditor.md' -maxdepth 1 -exec basename {} .md \; | sort)"
check_eq "the control plane maps every shipped auditor spec" "$known" "$specs"

rm -rf "$R"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
