#!/usr/bin/env bash
# Host-neutral auditor escalation state plus Codex/Claude hook fallback output.
set -uo pipefail

tooling_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verdict_state_lib="$tooling_root/.agents/lib/verdict-audit-state.sh"
override_state_lib="$tooling_root/.agents/lib/auditor-override-state.sh"
for required in jq perl git shasum; do
  command -v "$required" >/dev/null 2>&1 || {
    printf 'auditor-control.sh: required dependency not found: %s\n' "$required" >&2
    exit 2
  }
done
[[ -r "$verdict_state_lib" && -r "$override_state_lib" ]] || {
  printf 'auditor-control.sh: shared state libraries are unavailable.\n' >&2
  exit 2
}
# shellcheck source=../lib/verdict-audit-state.sh
source "$verdict_state_lib"
# shellcheck source=../lib/auditor-override-state.sh
source "$override_state_lib"

known_auditors() {
  printf '%s\n' commit-push-auditor verdict-auditor
}

canonical_auditor() {  # host agent type/name
  case "$1" in
    *commit-push-auditor*|*commit_push_auditor*) printf 'commit-push-auditor' ;;
    *verdict-auditor*|*verdict_auditor*) printf 'verdict-auditor' ;;
    *) return 1 ;;
  esac
}

read_first_transcript_record() {  # transcript path
  perl -MFcntl=:DEFAULT -e '
    my ($path, $max) = @ARGV;
    $SIG{ALRM} = sub { exit 1 };
    alarm 1;
    exit 1 if lstat($path) && -l _;
    my $flags = O_RDONLY | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 1 unless @opened && @named && -f $fh
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    my $record = "";
    while (index($record, "\n") < 0 && length($record) <= $max) {
      my $chunk = "";
      my $count = sysread($fh, $chunk, 4096);
      exit 1 unless defined $count;
      last if $count == 0;
      $record .= $chunk;
    }
    my $newline = index($record, "\n");
    $record = substr($record, 0, $newline) if $newline >= 0;
    my @named_after = lstat($path);
    exit 1 unless @named_after
      && $opened[0] == $named_after[0] && $opened[1] == $named_after[1];
    alarm 0;
    exit 1 if $record eq "" || length($record) > $max || $record =~ /[\0\r]/;
    print $record;
  ' "$1" 65536
}

auditor_from_payload() {  # hook payload, event
  local payload="$1" event="$2" agent_type transcript_path session_meta agent_path
  agent_type="$(printf '%s' "$payload" | jq -r '.agent_type // ""')"
  if canonical_auditor "$agent_type"; then
    return 0
  fi
  case "$event" in
    SubagentStart)
      transcript_path="$(printf '%s' "$payload" | jq -r \
        'if (.transcript_path|type)=="string" then .transcript_path else "" end')"
      ;;
    SubagentStop)
      transcript_path="$(printf '%s' "$payload" | jq -r '
        if (.agent_transcript_path|type)=="string" then .agent_transcript_path
        elif (.transcript_path|type)=="string" then .transcript_path
        else "" end')"
      ;;
    *) return 1 ;;
  esac
  [[ -n "$transcript_path" ]] || return 1
  session_meta="$(read_first_transcript_record "$transcript_path" 2>/dev/null)" || return 2
  agent_path="$(printf '%s' "$session_meta" | jq -er \
    --arg session "$(printf '%s' "$payload" | jq -r '.session_id')" \
    --arg agent "$(printf '%s' "$payload" | jq -r '.agent_id // ""')" '
      if .type == "session_meta"
         and .payload.id == $agent
         and .payload.session_id == $session
         and .payload.thread_source == "subagent"
         and .payload.source.subagent.thread_spawn.parent_thread_id == $session
         and (.payload.source.subagent.thread_spawn.agent_path | type) == "string"
      then .payload.source.subagent.thread_spawn.agent_path
      else empty end
    ' 2>/dev/null)" || return 2
  canonical_auditor "$agent_path"
}

project_repo() {
  local start="${CLAUDE_PROJECT_DIR:-$PWD}" root
  root="$(git -C "$start" rev-parse --show-toplevel 2>/dev/null)" || return 1
  (cd "$root" && pwd -P)
}

prompt_epoch_for() {  # repo scope
  local path value
  [[ "$2" != "-" ]] || { printf '-'; return; }
  path="$1/.agents/state/verdict-prompt-epoch.$2"
  if [[ ! -e "$path" && ! -L "$path" ]]; then printf '-'; return; fi
  value="$(verdict_audit_read_single_record "$path" 2>/dev/null)" || return 1
  [[ "$value" =~ ^[1-9][0-9]*-[1-9][0-9]*-[0-9]+$ ]] || return 1
  printf '%s' "$value"
}

safe_generation() {  # agent id
  if [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    printf '%s' "$1"
  else
    printf 'git-%s' "$(printf '%s' "$1" | git -C "$repo" hash-object --stdin)"
  fi
}

write_json_atomic() {  # path; JSON on stdin
  mkdir -p "$(dirname "$1")" 2>/dev/null || return 1
  verdict_audit_write_atomic "$1"
}

append_event() {  # JSON line
  verdict_audit_append_log_line "$events_file" "$1" 2>/dev/null || true
}

with_control_lock() {  # internal arguments...
  mkdir -p "$control_dir" 2>/dev/null || return 1
  # The parent retains the selected mutex inode while its child performs the state
  # transition. Perl marks descriptors close-on-exec, so directly execing the child
  # would silently drop the flock before the critical section began.
  perl -MFcntl=:DEFAULT,:flock -e '
    my ($lock, @command) = @ARGV;
    my $child = 0;
    $SIG{ALRM} = sub {
      kill("TERM", $child) if $child;
      waitpid($child, 0) if $child;
      exit 2;
    };
    alarm 3;
    exit 2 if lstat($lock) && -l _;
    my $flags = O_RDWR | O_CREAT | O_APPEND | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $lock, $flags, 0600) or exit 2;
    my @opened = stat($fh);
    my @named = lstat($lock);
    exit 2 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    flock($fh, LOCK_EX) or exit 2;
    @opened = stat($fh);
    @named = lstat($lock);
    exit 2 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    $child = fork();
    exit 2 unless defined $child;
    if ($child == 0) {
      exec @command;
      exit 2;
    }
    waitpid($child, 0) == $child or exit 2;
    my $status = $?;
    alarm 0;
    exit 2 if $status == -1;
    exit(128 + ($status & 127)) if $status & 127;
    exit($status >> 8);
  ' "$mutex_file" /usr/bin/env bash "$0" "$@"
}

close_scope_state() {  # terminal, removes active records and closes open prompts
  local terminal="$1" path json generation auditor
  for path in "$control_dir"/prompt."$scope".*.json; do
    [[ -e "$path" ]] || continue
    json="$(cat "$path" 2>/dev/null)" || continue
    prompt_state="$(printf '%s' "$json" | jq -r '.state // ""')"
    [[ "$prompt_state" == open || "$prompt_state" == selecting ]] || continue
    generation="$(printf '%s' "$json" | jq -r '.generation // ""')"
    auditor="$(printf '%s' "$json" | jq -r '.auditor // ""')"
    printf '%s' "$json" | jq -c --arg terminal "$terminal" --argjson now "$(date +%s)" \
      '.state="closed" | .terminal=$terminal | .closed_at=$now' \
      | write_json_atomic "$path" || continue
    append_event "$(jq -nc --arg event closed --arg auditor "$auditor" \
      --arg generation "$generation" --arg terminal "$terminal" \
      '{event:$event,auditor:$auditor,generation:$generation,terminal:$terminal}')"
  done
  rm -f "$control_dir"/active."$scope".*.json 2>/dev/null || true
  rm -f "$control_dir/selection.$scope.json" 2>/dev/null || true
}

open_prompt_exists() {  # expected epoch
  local expected_epoch="$1" path
  for path in "$control_dir"/prompt."$scope".*.json; do
    [[ -r "$path" ]] || continue
    [[ "$(jq -r '.state // ""' "$path" 2>/dev/null)" == open \
       && "$(jq -r '.prompt_epoch // ""' "$path" 2>/dev/null)" == "$expected_epoch" ]] \
      && return 0
  done
  return 1
}

selection_is_pending() {  # expected epoch choice
  local selection_file="$control_dir/selection.$scope.json" snapshot json
  snapshot="$(verdict_audit_read_json_snapshot "$selection_file" 2>/dev/null)" || return 1
  [[ "$snapshot" == *$'\n'* ]] || return 1
  json="${snapshot#*$'\n'}"
  [[ "$(printf '%s' "$json" | jq -r '.state // ""')" == pending \
     && "$(printf '%s' "$json" | jq -r '.prompt_epoch // ""')" == "$1" \
     && "$(printf '%s' "$json" | jq -r '.choice // ""')" == "$2" ]]
}

write_override_grant() {  # scope epoch reason-hash
  local grant_file now expires nonce_hash repo_hash
  grant_file="$(auditor_override_grant_path "$repo" "$1")"
  now="$(date +%s)"; expires="$((now + 3600))"
  nonce_hash="$(perl -e 'open(my $f,"<","/dev/urandom") or exit 1; read($f,my $b,32)==32 or exit 1; print unpack("H*",$b)' \
    | shasum -a 256 | awk '{print $1}')" || return 1
  repo_hash="$(auditor_override_repo_identity "$repo")" || return 1
  jq -nc --arg repo_hash "$repo_hash" --arg scope "$1" --arg epoch "$2" \
    --arg nonce_hash "$nonce_hash" --arg reason_hash "$3" \
    --argjson created "$now" --argjson expires "$expires" \
    '{repo_hash:$repo_hash,session_scope:$scope,prompt_epoch:$epoch,created_at:$created,
      expires_at:$expires,nonce_hash:$nonce_hash,reason_hash:$reason_hash}' \
    | write_json_atomic "$grant_file"
}

if [[ "${1:-}" == --known-auditors ]]; then
  known_auditors
  exit 0
fi

repo="$(project_repo)" || {
  printf 'auditor-control.sh: project directory is not a Git repository.\n' >&2
  exit 1
}
control_dir="$(auditor_override_control_dir "$repo")"

case "${1:-}" in
  external-start)
    auditor="$2"; generation="$3"; scope="$4"; epoch="$5"
    canonical_auditor "$auditor" >/dev/null 2>&1 || exit 1
    mutex_file="$control_dir/control.$scope.mutex"
    with_control_lock --locked-start "$scope" "$auditor" "$generation" "$epoch" || exit $?
    threshold="${AUDITOR_PROMPT_AFTER_SECONDS:-30}"
    [[ "$threshold" =~ ^[0-9]+$ && ${#threshold} -le 4 ]] || threshold=30
    nohup /usr/bin/env bash "$0" --external-wait \
      "$auditor" "$generation" "$scope" "$epoch" "$threshold" \
      </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
    exit 0
    ;;
  --external-wait)
    auditor="$2"; generation="$3"; scope="$4"; epoch="$5"; threshold="$6"
    mutex_file="$control_dir/control.$scope.mutex"
    perl -e 'select(undef,undef,undef,$ARGV[0])' "$threshold"
    with_control_lock --locked-escalate "$scope" "$auditor" "$generation" "$epoch" \
      >/dev/null 2>&1 || true
    exit 0
    ;;
  external-stop)
    auditor="$2"; generation="$3"; scope="$4"; terminal="$5"
    mutex_file="$control_dir/control.$scope.mutex"
    with_control_lock --locked-stop "$scope" "$auditor" "$generation" "$terminal" || exit $?
    exit 0
    ;;
  --locked-start)
    scope="$2"; auditor="$3"; generation="$4"; epoch="$5"
    events_file="$control_dir/events.$scope.jsonl"
    active_file="$control_dir/active.$scope.$auditor.json"
    prompt_file="$control_dir/prompt.$scope.$auditor.$generation.json"
    if [[ -r "$prompt_file" ]] || { [[ -r "$active_file" ]] \
      && [[ "$(jq -r '.generation // ""' "$active_file" 2>/dev/null)" == "$generation" ]]; }; then
      exit 0
    fi
    jq -nc --arg auditor "$auditor" --arg generation "$generation" \
      --arg scope "$scope" --arg epoch "$epoch" --argjson now "$(date +%s)" \
      '{auditor:$auditor,generation:$generation,session_scope:$scope,prompt_epoch:$epoch,started_at:$now,state:"running"}' \
      | write_json_atomic "$active_file" || exit 1
    exit 0
    ;;
  --locked-escalate)
    scope="$2"; auditor="$3"; generation="$4"; epoch="$5"
    events_file="$control_dir/events.$scope.jsonl"
    active_file="$control_dir/active.$scope.$auditor.json"
    prompt_file="$control_dir/prompt.$scope.$auditor.$generation.json"
    [[ -r "$active_file" \
       && "$(jq -r '.generation // ""' "$active_file" 2>/dev/null)" == "$generation" \
       && "$(jq -r '.prompt_epoch // ""' "$active_file" 2>/dev/null)" == "$epoch" ]] || exit 3
    [[ ! -e "$prompt_file" ]] || exit 4
    jq -nc --arg auditor "$auditor" --arg generation "$generation" \
      --arg scope "$scope" --arg epoch "$epoch" --argjson now "$(date +%s)" \
      '{auditor:$auditor,generation:$generation,session_scope:$scope,prompt_epoch:$epoch,
        state:"open",opened_at:$now,choices:["keep_waiting","override_all","cancel_task"]}' \
      | write_json_atomic "$prompt_file" || exit 1
    append_event "$(jq -nc --arg event opened --arg auditor "$auditor" \
      --arg generation "$generation" '{event:$event,auditor:$auditor,generation:$generation}')"
    exit 0
    ;;
  --locked-stop)
    scope="$2"; auditor="$3"; generation="$4"; terminal="$5"
    events_file="$control_dir/events.$scope.jsonl"
    active_file="$control_dir/active.$scope.$auditor.json"
    prompt_file="$control_dir/prompt.$scope.$auditor.$generation.json"
    [[ -r "$active_file" \
       && "$(jq -r '.generation // ""' "$active_file" 2>/dev/null)" == "$generation" ]] || exit 0
    rm -f "$active_file"
    rm -f "$control_dir/selection.$scope.json"
    prompt_state="$(jq -r '.state // ""' "$prompt_file" 2>/dev/null)"
    if [[ -r "$prompt_file" && ( "$prompt_state" == open || "$prompt_state" == selecting ) ]]; then
      jq -c --arg terminal "$terminal" --argjson now "$(date +%s)" \
        '.state="closed" | .terminal=$terminal | .closed_at=$now' "$prompt_file" \
        | write_json_atomic "$prompt_file" || exit 1
      append_event "$(jq -nc --arg event closed --arg auditor "$auditor" \
        --arg generation "$generation" --arg terminal "$terminal" \
        '{event:$event,auditor:$auditor,generation:$generation,terminal:$terminal}')"
    fi
    exit 0
    ;;
  --locked-begin-select)
    scope="$2"; epoch="$3"; choice="$4"
    events_file="$control_dir/events.$scope.jsonl"
    selection_file="$control_dir/selection.$scope.json"
    if ! open_prompt_exists "$epoch"; then
      jq -nc '{accepted:false,outcome:"ignored-terminal-race"}'
      exit 0
    fi
    for prompt_file in "$control_dir"/prompt."$scope".*.json; do
      [[ -r "$prompt_file" ]] || continue
      [[ "$(jq -r '.state // ""' "$prompt_file" 2>/dev/null)" == open \
         && "$(jq -r '.prompt_epoch // ""' "$prompt_file" 2>/dev/null)" == "$epoch" ]] \
        || continue
      jq -c --arg choice "$choice" --argjson now "$(date +%s)" \
        '.state="selecting" | .selection=$choice | .selection_started_at=$now' \
        "$prompt_file" | write_json_atomic "$prompt_file" || exit 1
    done
    jq -nc --arg epoch "$epoch" --arg choice "$choice" --argjson now "$(date +%s)" \
      '{state:"pending",prompt_epoch:$epoch,choice:$choice,started_at:$now}' \
      | write_json_atomic "$selection_file" || exit 1
    jq -nc '{pending:true}'
    exit 0
    ;;
  --locked-handle-prompt)
    scope="$2"; old_epoch="$3"; new_epoch="$4"; directive="$5"; reason_hash="$6"
    events_file="$control_dir/events.$scope.jsonl"
    grant_file="$(auditor_override_grant_path "$repo" "$scope")"
    rm -f "$grant_file"
    if [[ "$directive" != override ]]; then
      close_scope_state new-prompt
      exit 0
    fi
    if ! open_prompt_exists "$old_epoch"; then
      jq -nc '{continue:true,systemMessage:"[auditor-control] override ignored: the audit generation already completed or no 30-second prompt is open"}'
      exit 0
    fi
    write_override_grant "$scope" "$new_epoch" "$reason_hash" || exit 1
    close_scope_state overridden-by-user
    rm -f "$repo/.agents/state/last-audit.json" "$repo/.agents/state/last-audit-handoff.json" \
      "$repo/.claude/.last-audit.json" "$repo/.claude/.last-audit-handoff.json"
    append_event "$(jq -nc --arg event overridden --arg epoch "$new_epoch" \
      '{event:$event,prompt_epoch:$epoch,outcome:"OVERRIDDEN BY USER"}')"
    jq -nc '{continue:true,hookSpecificOutput:{hookEventName:"UserPromptSubmit",
      additionalContext:"OVERRIDDEN BY USER: all auditor gates are bypassed for this prompt only. Preserve installation, guidance, PR-review, chained-hook, and remote protections. Never describe an auditor as PASS."}}'
    exit 0
    ;;
  --locked-select)
    scope="$2"; epoch="$3"; choice="$4"; reason_hash="$5"
    events_file="$control_dir/events.$scope.jsonl"
    if ! selection_is_pending "$epoch" "$choice"; then
      jq -nc '{accepted:false,outcome:"ignored-terminal-race"}'
      exit 0
    fi
    case "$choice" in
      keep_waiting)
        # The prompt is one-shot, but the auditor remains active and may still close
        # through SubagentStop without another escalation for this generation.
        for prompt_file in "$control_dir"/prompt."$scope".*.json; do
          [[ -r "$prompt_file" ]] || continue
          [[ "$(jq -r '.state // ""' "$prompt_file" 2>/dev/null)" == selecting ]] || continue
          jq -c --argjson now "$(date +%s)" \
            '.state="closed" | .terminal="keep-waiting" | .closed_at=$now' "$prompt_file" \
            | write_json_atomic "$prompt_file" || exit 1
        done
        rm -f "$control_dir/selection.$scope.json"
        jq -nc '{accepted:true,outcome:"keep-waiting"}'
        ;;
      cancel_task)
        close_scope_state canceled-by-user
        jq -nc '{accepted:true,outcome:"cancel-task"}'
        ;;
      override_all)
        [[ "$reason_hash" =~ ^[0-9a-f]{64}$ ]] || exit 1
        write_override_grant "$scope" "$epoch" "$reason_hash" || exit 1
        close_scope_state overridden-by-user
        rm -f "$repo/.agents/state/last-audit.json" "$repo/.agents/state/last-audit-handoff.json" \
          "$repo/.claude/.last-audit.json" "$repo/.claude/.last-audit-handoff.json"
        append_event "$(jq -nc --arg event overridden --arg epoch "$epoch" \
          '{event:$event,prompt_epoch:$epoch,outcome:"OVERRIDDEN BY USER"}')"
        jq -nc '{accepted:true,outcome:"OVERRIDDEN BY USER"}'
        ;;
    esac
    exit 0
    ;;
esac

raw_payload="$(cat)"
payload="$(printf '%s' "$raw_payload" | jq -ecs 'if length == 1 and (.[0]|type)=="object" then .[0] else empty end' 2>/dev/null)"
[[ -n "$payload" ]] || { printf 'auditor-control.sh: expected one JSON hook object.\n' >&2; exit 1; }
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // ""')"
session_state="$(printf '%s' "$payload" | jq -r 'if (.session_id|type)=="string" and (.session_id|length)>0 then "valid" else "invalid" end')"
[[ "$session_state" == valid ]] || exit 0
scope="$(verdict_audit_scope_from_hook_payload "$payload" "$repo" 2>/dev/null)" || exit 1
mutex_file="$control_dir/control.$scope.mutex"

if [[ "${1:-}" == select ]]; then
  choice="$(printf '%s' "$payload" | jq -r '.choice // ""')"
  [[ "$choice" == keep_waiting || "$choice" == override_all || "$choice" == cancel_task ]] \
    || { printf 'auditor-control.sh: invalid prompt choice.\n' >&2; exit 1; }
  epoch="$(prompt_epoch_for "$repo" "$scope" 2>/dev/null)" || exit 1
  reason_hash=-
  if [[ "$choice" == override_all ]]; then
    reason="$(printf '%s' "$payload" | jq -r '.reason // ""')"
    [[ "$reason" =~ [^[:space:]] ]] \
      || { printf 'auditor-control.sh: override requires a reason.\n' >&2; exit 1; }
    reason_hash="$(printf '%s' "$reason" | shasum -a 256 | awk '{print $1}')"
  fi
  begin_output="$(with_control_lock --locked-begin-select \
    "$scope" "$epoch" "$choice")" || exit $?
  if [[ "$(printf '%s' "$begin_output" | jq -r '.pending // false')" != true ]]; then
    printf '%s\n' "$begin_output"
    exit 0
  fi
  grace_milliseconds="${AUDITOR_TERMINAL_GRACE_MILLISECONDS:-200}"
  [[ "$grace_milliseconds" =~ ^[0-9]+$ && ${#grace_milliseconds} -le 4 \
     && "$grace_milliseconds" -le 1000 ]] || grace_milliseconds=200
  perl -e 'select(undef,undef,undef,$ARGV[0] / 1000)' "$grace_milliseconds"
  with_control_lock --locked-select "$scope" "$epoch" "$choice" "$reason_hash"
  exit $?
fi

if [[ "$event" == UserPromptSubmit && "${1:-}" == handle-prompt ]]; then
  old_epoch="${2:-}"; new_epoch="${3:-}"
  first_line="$(printf '%s' "$payload" | jq -r '
    (.prompt // "") | gsub("\r";"") | split("\n") | map(select(test("[^[:space:]]"))) | .[0] // ""
  ')"
  directive=normal; reason_hash=-
  if [[ "$first_line" =~ ^force-pass-auditors:[[:space:]]+([^[:space:]].*)$ ]]; then
    directive=override
    reason_hash="$(printf '%s' "${BASH_REMATCH[1]}" | shasum -a 256 | awk '{print $1}')"
  fi
  with_control_lock --locked-handle-prompt "$scope" "$old_epoch" "$new_epoch" "$directive" "$reason_hash"
  exit $?
fi

agent_id="$(printf '%s' "$payload" | jq -r '.agent_id // ""')"
[[ -n "$agent_id" ]] || exit 0
auditor="$(auditor_from_payload "$payload" "$event")"; auditor_status=$?
if (( auditor_status != 0 )); then
  if (( auditor_status == 1 )); then
    [[ "$event" == SubagentStop ]] && printf '{}\n'
    exit 0
  fi
  printf 'auditor-control.sh: could not safely identify the subagent transcript.\n' >&2
  exit 2
fi
generation="$(safe_generation "$agent_id")"
epoch="$(prompt_epoch_for "$repo" "$scope" 2>/dev/null)" || exit 1

case "$event" in
  SubagentStart)
    with_control_lock --locked-start "$scope" "$auditor" "$generation" "$epoch" || exit $?
    threshold="${AUDITOR_PROMPT_AFTER_SECONDS:-30}"
    [[ "$threshold" =~ ^[0-9]+$ && ${#threshold} -le 4 ]] || threshold=30
    perl -e 'select(undef,undef,undef,$ARGV[0])' "$threshold"
    if with_control_lock --locked-escalate "$scope" "$auditor" "$generation" "$epoch"; then
      jq -nc --arg auditor "$auditor" '{continue:true,
        systemMessage:("[auditor-control] " + $auditor + " is still running after 30s. Keep waiting (recommended), Override all auditors for this prompt, or Cancel task. If you do nothing, the audit continues and its terminal result closes this prompt. Portable override: submit `force-pass-auditors: <required reason>` as the first non-empty line.")}'
    fi
    ;;
  SubagentStop)
    message="$(printf '%s' "$payload" | jq -r '.last_assistant_message // ""')"
    case "$message" in
      PASS*) terminal=PASS ;;
      FAIL*) terminal=FAIL ;;
      IN_PROGRESS*) terminal=IN_PROGRESS ;;
      *) terminal=unavailable ;;
    esac
    with_control_lock --locked-stop "$scope" "$auditor" "$generation" "$terminal" || exit $?
    printf '{}\n'
    ;;
esac
