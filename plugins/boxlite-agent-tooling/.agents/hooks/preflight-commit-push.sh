#!/usr/bin/env bash
# PreToolUse hook: gate `git commit` / `git push` on a fresh audit verdict.
#
# The verdict comes from the commit-push-auditor spec
# (.claude/agents/commit-push-auditor.md), spawned by whichever built-in the running
# agent has. This gate never produces it.
#
# Flow on a denied attempt:
#   1. Hook denies the git tool call.
#   2. Reason text names every route to an auditor; the agent takes the one it has.
#   3. That auditor writes .agents/state/last-audit.json.
#   4. Parent retries -> hook reads the artifact and allows on PASS.
#
# Wired in .claude/settings.json under hooks.PreToolUse with matcher "Bash".
#
# Design notes
# ------------
# * Matcher scope: settings.json registers this hook on the broad `Bash`
#   matcher, not a narrower `Bash:git*` pattern, because Claude Code's
#   PreToolUse matchers are tool-name-only — there's no built-in way to filter
#   on the bash command itself. The script does the actual filtering via the
#   case match below and exits 0 immediately on non-target commands, so the
#   per-invocation cost on unrelated bash calls is one jq parse + one regex.
#
# * One-shot consumption: the audit file is `rm -f`'d on the allow path
#   (intentional, see end of script). This forces a fresh audit on every
#   subsequent git commit/push — even at the same HEAD — so re-staged content
#   between commits can't ride on the previous audit. The cost is that
#   commit-then-push of the same HEAD must re-audit; the user has accepted
#   this trade-off to avoid stale-audit-passes-new-content failure modes.
#
# Tests: bash .agents/hooks/preflight-commit-push.test.sh
set -euo pipefail

payload="$(cat)"
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"

# Match when the command actually IS a `git commit` / `git push` invocation —
# at the start of the command OR at the start of any chain segment (after &&,
# ||, ;, |, &, $(, (, `, or a NEWLINE). This catches the chained-command case
# (`cat foo && git commit ...`) AND the multi-line case (`cd foo\ngit commit ...`)
# that an anchor-only matcher misses, while still rejecting literal mentions of
# "git commit" inside string arguments (e.g. `echo "git commit"`), which don't sit
# at the start of a chain segment.
#
# Newline handling: a verb at the start of a physical line runs as a real top-level
# command, exactly like `;`/`&&`. Normalizing newlines to `;` makes the existing
# separator logic catch it. Without this the verb on its own line slips past the
# matcher unaudited (fails OPEN — a silent bypass). Cost: a `git commit`/`git push`
# token on its own line inside a heredoc/message body may falsely match (fails
# CLOSED — a spurious re-audit, never a bypass). Closed-over-open is the right trade.
normalized="${command//$'\n'/;}"
work="${normalized#"${normalized%%[![:space:]]*}"}"
if [[ "$work" =~ (^|[[:space:]]*(\&\&|\|\||;|\||\&|\$\(|\(|\`)[[:space:]]*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*git[[:space:]]+(commit|push)([[:space:]]|$) ]]; then
  case "${BASH_REMATCH[4]}" in
    commit) kind="commit" ;;
    push)   kind="push"   ;;
    *)      exit 0 ;;
  esac
else
  exit 0
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
project_dir="${CLAUDE_PROJECT_DIR:-$repo_root}"
tooling_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
audit_file="$project_dir/.agents/state/last-audit.json"
handoff_file="$project_dir/.agents/state/last-audit-handoff.json"
verdict_state_lib="$tooling_root/.agents/lib/verdict-audit-state.sh"
override_state_lib="$tooling_root/.agents/lib/auditor-override-state.sh"
if [[ ! -r "$verdict_state_lib" || ! -r "$override_state_lib" ]]; then
  printf 'preflight-commit-push: shared audit state libraries are unavailable.\n' >&2
  exit 2
fi
# shellcheck source=../lib/verdict-audit-state.sh
source "$verdict_state_lib"
# shellcheck source=../lib/auditor-override-state.sh
source "$override_state_lib"
# Assigned by auditor_override_load_valid_grant; initialize the sourced public output
# explicitly so `set -u` and static analysis share the same boundary contract.
auditor_override_nonce_hash=""
# Transition mirrors. Where core.hooksPath is configured absolute rather than the
# relative value `make setup` sets, one installed hook serves every worktree, so a
# commit-msg from BEFORE this move can be the one that runs while this gate —
# reached through the .claude/hooks symlink — is the one that writes. That hook
# reads the legacy paths and cannot be taught the new ones, so this gate leaves
# a copy where it will look. Remove both mirrors and this block once every
# checkout is past the move.
legacy_audit_file="$project_dir/.claude/.last-audit.json"
legacy_handoff_file="$project_dir/.claude/.last-audit-handoff.json"

# Returns 0 only when dest now holds a copy of src, so a caller that wants to
# hand the marker over can safely delete the original.
mirror_to_legacy() {
  local src="$1" dest="$2"
  [[ -r "$src" ]] || return 1
  mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
  cp -f "$src" "$dest" 2>/dev/null || return 1
}
branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || echo '?')"
head="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo '?')"
max_age_seconds=600

file_mtime_epoch() {
  local path="$1" mtime
  if mtime="$(stat -c '%Y' "$path" 2>/dev/null)" && [[ "$mtime" =~ ^[0-9]+$ ]]; then
    printf '%s' "$mtime"
    return
  fi
  if mtime="$(stat -f '%m' "$path" 2>/dev/null)" && [[ "$mtime" =~ ^[0-9]+$ ]]; then
    printf '%s' "$mtime"
    return
  fi
  printf '0'
}

hash_stdin() {
  shasum -a 256 | awk '{print $1}'
}

command_field() {
  local key="$1"
  printf '%s' "$command" | sed -n "s/.* ${key}=\\([0-9a-f][0-9a-f]*\\).*/\\1/p" | head -1
}

push_diff_hash_from_command=""
if [[ "$kind" == "push" ]]; then
  push_diff_hash_from_command="$(command_field pushed_diff_sha256)"
fi

current_diff_hash() {
  case "$kind" in
    commit)
      git -C "$repo_root" diff --cached --no-ext-diff | hash_stdin
      ;;
    push)
      if [[ "$push_diff_hash_from_command" =~ ^[0-9a-f]{64}$ ]]; then
        printf '%s' "$push_diff_hash_from_command"
        return
      fi
      {
        git -C "$repo_root" diff --no-ext-diff origin/main...HEAD 2>/dev/null ||
          git -C "$repo_root" diff --no-ext-diff HEAD~1...HEAD 2>/dev/null ||
          true
      } | hash_stdin
      ;;
    *)
      printf 'unknown' | hash_stdin
      ;;
  esac
}

diff_hash="$(current_diff_hash)"
command_hash="$(printf '%s' "$command" | hash_stdin)"
override_active=false
override_scope=""
override_epoch=""
hook_session_scope=""
hook_prompt_epoch=""
handoff_owner_pid=""
handoff_owner_start_token=""

read_override_epoch() {  # session scope
  local epoch_path="$project_dir/.agents/state/verdict-prompt-epoch.$1" epoch
  epoch="$(verdict_audit_read_single_record "$epoch_path" 2>/dev/null)" || return 1
  [[ "$epoch" =~ ^[1-9][0-9]*-[1-9][0-9]*-[0-9]+$ ]] || return 1
  printf '%s' "$epoch"
}

load_session_override() {
  local session_state session_scope epoch
  session_state="$(printf '%s' "$payload" | jq -r '
    if (.session_id | type) == "string" and (.session_id | length) > 0
    then "valid" else "absent" end
  ' 2>/dev/null || echo absent)"
  [[ "$session_state" == valid ]] || return 1
  session_scope="$(verdict_audit_scope_from_hook_payload \
    "$payload" "$repo_root" 2>/dev/null)" || return 1
  epoch="$(read_override_epoch "$session_scope" 2>/dev/null)" || return 1
  hook_session_scope="$session_scope"
  hook_prompt_epoch="$epoch"
  auditor_override_load_valid_grant "$repo_root" "$session_scope" "$epoch" || return 1
  override_scope="$session_scope"
  override_epoch="$epoch"
  override_active=true
}

load_handoff_owner() {
  local owner_pid owner_token
  [[ -r "$handoff_file" ]] || return 1
  owner_pid="$(jq -r '.owner.pid // ""' "$handoff_file" 2>/dev/null)"
  owner_token="$(jq -r '.owner.start_token // ""' "$handoff_file" 2>/dev/null)"
  verdict_audit_process_has_ancestor "$owner_pid" "$owner_token" || return 1
  handoff_owner_pid="$owner_pid"
  handoff_owner_start_token="$owner_token"
}

load_handoff_override() {
  local handoff_scope handoff_epoch handoff_nonce handoff_branch handoff_head handoff_kind
  load_handoff_owner || return 1
  [[ -r "$handoff_file" ]] || return 1
  handoff_scope="$(jq -r '.override.session_scope // ""' "$handoff_file" 2>/dev/null)"
  handoff_epoch="$(jq -r '.override.prompt_epoch // ""' "$handoff_file" 2>/dev/null)"
  handoff_nonce="$(jq -r '.override.nonce_hash // ""' "$handoff_file" 2>/dev/null)"
  handoff_branch="$(jq -r '.branch // ""' "$handoff_file" 2>/dev/null)"
  handoff_head="$(jq -r '.head // ""' "$handoff_file" 2>/dev/null)"
  handoff_kind="$(jq -r '.command_kind // ""' "$handoff_file" 2>/dev/null)"
  [[ "$handoff_branch" == "$branch" && "$handoff_head" == "$head" \
     && "$handoff_kind" == "$kind" && "$handoff_nonce" =~ ^[0-9a-f]{64}$ ]] || return 1
  auditor_override_load_valid_grant \
    "$repo_root" "$handoff_scope" "$handoff_epoch" || return 1
  [[ "$auditor_override_nonce_hash" == "$handoff_nonce" ]] || return 1
  override_scope="$handoff_scope"
  override_epoch="$handoff_epoch"
  override_active=true
}

load_handoff_lifecycle() {
  local handoff_scope handoff_epoch handoff_branch handoff_head handoff_kind current_epoch
  load_handoff_owner || return 1
  [[ -r "$handoff_file" ]] || return 1
  handoff_scope="$(jq -r '.lifecycle.session_scope // ""' "$handoff_file" 2>/dev/null)"
  handoff_epoch="$(jq -r '.lifecycle.prompt_epoch // ""' "$handoff_file" 2>/dev/null)"
  handoff_branch="$(jq -r '.branch // ""' "$handoff_file" 2>/dev/null)"
  handoff_head="$(jq -r '.head // ""' "$handoff_file" 2>/dev/null)"
  handoff_kind="$(jq -r '.command_kind // ""' "$handoff_file" 2>/dev/null)"
  [[ "$handoff_scope" =~ ^git-[0-9a-f]{40}([0-9a-f]{24})?$ \
     && "$handoff_epoch" =~ ^[1-9][0-9]*-[1-9][0-9]*-[0-9]+$ \
     && "$handoff_branch" == "$branch" && "$handoff_head" == "$head" \
     && "$handoff_kind" == "$kind" ]] || return 1
  current_epoch="$(read_override_epoch "$handoff_scope" 2>/dev/null)" || return 1
  [[ "$current_epoch" == "$handoff_epoch" ]] || return 1
  hook_session_scope="$handoff_scope"
  hook_prompt_epoch="$handoff_epoch"
}

if [[ -n "${GITHOOK_DELEGATED:-}" ]]; then
  load_handoff_lifecycle 2>/dev/null || true
  load_handoff_override 2>/dev/null || true
else
  # Hook commands run in a short-lived launcher child. The launcher disappears before
  # git starts, while its parent is the task runner shared by both command trees.
  handoff_owner_pid="$(ps -p "$PPID" -o ppid= 2>/dev/null)"
  handoff_owner_pid="${handoff_owner_pid//[[:space:]]/}"
  [[ "$handoff_owner_pid" =~ ^[1-9][0-9]*$ ]] || handoff_owner_pid="$PPID"
  handoff_owner_start_token="$(verdict_audit_process_start_token "$handoff_owner_pid" 2>/dev/null)" \
    || { printf 'preflight-commit-push: could not bind git handoff ownership.\n' >&2; exit 2; }
  load_session_override 2>/dev/null || true
fi

# Derive lifecycle ownership even when no override grant exists yet. The denied
# attempt records this context in the handoff; native SubagentStart or the headless
# runner starts the 30-second clock only when the actual auditor begins.
if [[ -z "$hook_session_scope" && -z "${GITHOOK_DELEGATED:-}" ]]; then
  hook_session_scope="$(verdict_audit_scope_from_hook_payload \
    "$payload" "$repo_root" 2>/dev/null)" || hook_session_scope=""
  if [[ -n "$hook_session_scope" ]]; then
    hook_prompt_epoch="$(read_override_epoch "$hook_session_scope" 2>/dev/null)" \
      || hook_prompt_epoch=""
  fi
fi

deny() {
  jq -nc --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

write_command_handoff() {
  # The state dir is gitignored, so it does not exist in a fresh clone and the
  # redirect below would fail before jq ever ran.
  mkdir -p "$(dirname "$handoff_file")" 2>/dev/null || true
  local override_json='null' lifecycle_json='null'
  [[ "$handoff_owner_pid" =~ ^[1-9][0-9]*$ \
     && "$handoff_owner_start_token" =~ ^cksum-[0-9]+-[0-9]+$ ]] || return 1
  if [[ "$override_active" == true ]]; then
    override_json="$(jq -nc --arg scope "$override_scope" --arg epoch "$override_epoch" \
      --arg nonce "$auditor_override_nonce_hash" \
      '{session_scope:$scope,prompt_epoch:$epoch,nonce_hash:$nonce}')"
  fi
  if [[ -n "$hook_session_scope" && -n "$hook_prompt_epoch" ]]; then
    lifecycle_json="$(jq -nc --arg scope "$hook_session_scope" \
      --arg epoch "$hook_prompt_epoch" \
      '{session_scope:$scope,prompt_epoch:$epoch}')"
  fi
  jq -nc \
    --arg branch "$branch" \
    --arg head "$head" \
    --arg command_kind "$kind" \
    --arg diff_hash "$diff_hash" \
    --arg command_hash "$command_hash" \
    --argjson owner_pid "$handoff_owner_pid" \
    --arg owner_start_token "$handoff_owner_start_token" \
    --argjson override "$override_json" \
    --argjson lifecycle "$lifecycle_json" \
    '{branch:$branch, head:$head, command_kind:$command_kind, diff_hash:$diff_hash,
      command_hash:$command_hash,
      owner:{pid:$owner_pid,start_token:$owner_start_token},
      override:$override, lifecycle:$lifecycle}' \
    > "$handoff_file"
  # `|| true` is load-bearing: this is the last command in the function, and the
  # defer path calls the function unguarded under `set -e`. Without it a mirror
  # that cannot be written makes the whole hook exit 1 instead of 0. The mirror
  # is a transition convenience — never a reason to fail the gate.
  mirror_to_legacy "$handoff_file" "$legacy_handoff_file" || true
}

allow_override() {
  local boundary="${kind}-pretool"
  [[ -n "${GITHOOK_DELEGATED:-}" ]] && boundary="${kind}-preflight"
  if ! auditor_override_log_use "$repo_root" "$override_scope" "$boundary" \
      "$diff_hash" >/dev/null 2>&1; then
    deny "Auditor override evidence could not be recorded; git ${kind} remains gated."
  fi
  jq -nc --arg kind "$kind" '{hookSpecificOutput:{hookEventName:"PreToolUse",
    additionalContext:("OVERRIDDEN BY USER: " + $kind + " auditor skipped for this prompt; no PASS verdict was created.")}}'
  exit 0
}

valid_handoff_command_hash() {
  [[ -r "$handoff_file" ]] || return 1
  load_handoff_owner || return 1

  local handoff_branch handoff_head handoff_kind handoff_diff_hash handoff_command_hash handoff_mtime now_epoch handoff_age
  handoff_branch="$(jq -r '.branch // ""' "$handoff_file" 2>/dev/null || echo '')"
  handoff_head="$(jq -r '.head // ""' "$handoff_file" 2>/dev/null || echo '')"
  handoff_kind="$(jq -r '.command_kind // ""' "$handoff_file" 2>/dev/null || echo '')"
  handoff_diff_hash="$(jq -r '.diff_hash // ""' "$handoff_file" 2>/dev/null || echo '')"
  handoff_command_hash="$(jq -r '.command_hash // ""' "$handoff_file" 2>/dev/null || echo '')"
  handoff_mtime="$(file_mtime_epoch "$handoff_file")"
  now_epoch="$(date +%s)"
  handoff_age=$(( now_epoch - handoff_mtime ))

  if [[ "$handoff_branch" == "$branch" ]] && \
     [[ "$handoff_head" == "$head" ]] && \
     [[ "$handoff_kind" == "$kind" ]] && \
     [[ "$handoff_diff_hash" == "$diff_hash" ]] && \
     [[ -n "$handoff_command_hash" ]] && \
     (( handoff_age <= max_age_seconds )); then
    printf '%s' "$handoff_command_hash"
    return 0
  fi

  return 1
}

# ── Re-audit instruction ─────────────────────────────────────────────────────
# Sourced HERE rather than at the top of the file so the two early exits above still
# apply: a missing library must not turn every unrelated Bash call into an error, only
# the git commands this gate actually guards.
#
# And it exits 2 rather than continuing without the library. A PreToolUse hook that
# merely crashes is reported and stepped over, which on a DENY gate means the commit
# proceeds unaudited — the one outcome worse than a noisy failure. Exit 2 blocks.
subagent_lib="$tooling_root/.agents/lib/subagent.sh"
if [[ ! -r "$subagent_lib" ]]; then
  printf 'preflight-commit-push: missing %s — refusing to gate without it\n' "$subagent_lib" >&2
  exit 2
fi
# shellcheck source=../lib/subagent.sh
source "$subagent_lib"

# One instruction, naming every route. Nothing here inspects the environment to choose
# between hosts: capability is something the agent knows about itself, while an
# environment variable can be set by whatever launched the hook.
invoke_instruction="$(subagent_instruction \
  --agent commit-push-auditor \
  --root "$tooling_root" \
  --description 'CLAUDE.md audit' \
  --artifact '.agents/state/last-audit.json' \
  --task "$(subagent_prompt commit-push-task "$tooling_root" "kind=${kind}" "branch=${branch}")" \
  --headless "AUDITOR_SESSION_SCOPE='${hook_session_scope}' AUDITOR_PROMPT_EPOCH='${hook_prompt_epoch}' CODEX_COMMIT_PUSH_AUDIT_MODE=agentic bash '${tooling_root}/.agents/hooks/run-commit-push-audit.sh' ${kind} '<target command>'
    (set CODEX_BIN if the default codex command is not usable)")

Retry the same git command after the verdict reports PASS."

validate_audit() {
  local consume_on_pass="${1:-consume}"

  if [[ ! -r "$audit_file" ]]; then
    deny "No CLAUDE.md audit found for this change.

${invoke_instruction}"
  fi

  local audit_branch audit_head audit_kind audit_diff_hash audit_command_hash audit_commit_subject_hash audit_verdict audit_mtime now_epoch age advisories
  audit_branch="$(jq -r '.branch // ""' "$audit_file" 2>/dev/null || echo '')"
  audit_head="$(jq -r '.head // ""' "$audit_file" 2>/dev/null || echo '')"
  audit_kind="$(jq -r '.command_kind // ""' "$audit_file" 2>/dev/null || echo '')"
  audit_diff_hash="$(jq -r '.diff_hash // ""' "$audit_file" 2>/dev/null || echo '')"
  audit_command_hash="$(jq -r '.command_hash // ""' "$audit_file" 2>/dev/null || echo '')"
  audit_commit_subject_hash="$(jq -r '.commit_subject_hash // ""' "$audit_file" 2>/dev/null || echo '')"
  audit_verdict="$(jq -r '.verdict // ""' "$audit_file" 2>/dev/null || echo '')"
  if [[ "$kind" == "push" && ! "$push_diff_hash_from_command" =~ ^[0-9a-f]{64}$ ]]; then
    deny "Push audits must be bound to git pre-push ref-update stdin via pushed_diff_sha256.

Retry the push through the git-level pre-push gate so it can produce the exact ref-update audit command."
  fi

  # Keep failed platform probes from contaminating the successful command's output.
  audit_mtime="$(file_mtime_epoch "$audit_file")"
  now_epoch="$(date +%s)"
  age=$(( now_epoch - audit_mtime ))

  local command_bound=0 handoff_command_hash=""
  if [[ "$audit_command_hash" == "$command_hash" ]]; then
    command_bound=1
  elif [[ -n "${GITHOOK_DELEGATED:-}" && "$kind" == "commit" ]]; then
    # Only commits may bridge from the PreToolUse command to git's later hooks:
    # commit-msg verifies the final subject before consuming the audit. Pushes
    # must bind to the detailed pre-push command, including ref-update stdin.
    handoff_command_hash="$(valid_handoff_command_hash 2>/dev/null || true)"
    if [[ -n "$handoff_command_hash" && "$audit_command_hash" == "$handoff_command_hash" ]]; then
      command_bound=1
    elif [[ "$kind" == "commit" && -n "$audit_commit_subject_hash" ]]; then
      # Git exposes the real commit message later. The commit-msg hook compares
      # this audited subject hash against the message file before consuming.
      command_bound=1
    fi
  fi

  if [[ "$audit_branch" != "$branch" ]] || \
     [[ "$audit_head" != "$head" ]] || \
     [[ "$audit_kind" != "$kind" ]] || \
     [[ "$audit_diff_hash" != "$diff_hash" ]] || \
     [[ "$command_bound" != 1 ]] || \
     (( age > max_age_seconds )); then
    deny "Existing audit does not match current state:
  audit.branch=${audit_branch}  current=${branch}
  audit.head=${audit_head}      current=${head}
  audit.command_kind=${audit_kind}  current=${kind}
  audit.diff_hash=${audit_diff_hash}  current=${diff_hash}
  audit.command_hash=${audit_command_hash}  current=${command_hash}
  handoff.command_hash=${handoff_command_hash:-none}
  audit age: ${age}s (max ${max_age_seconds}s)

Re-audit is required.
${invoke_instruction}"
  fi

  # `findings` blocks, `advisories` never does. Two arrays rather than a per-finding
  # severity so the split FAILS CLOSED: a producer that omits advisories blocks on
  # everything, whereas a severity field would need a default and a wrong default
  # downgrades real findings. Same effect as eslint's two counters (lib/cli.js ~496-521,
  # where errorCount drives the exit code and warningCount only does under
  # --max-warnings), reached without a defaulting rule.
  advisories="$(jq -r '.advisories[]? | "  ~ " + .' "$audit_file" 2>/dev/null || echo '')"

  if [[ "$audit_verdict" != "PASS" ]]; then
    findings="$(jq -r '.findings[]? | "  - " + .' "$audit_file" 2>/dev/null || echo '')"
    deny "CLAUDE.md audit FAILED on branch '${branch}':

${findings}
${advisories:+
Advisories (NOT blocking — do not re-audit for these alone):
${advisories}
}
Address each finding, then re-run the audit producer before retrying git ${kind}."
  fi

  # Surface without touching the permission decision, as post-remote-write-watch.sh
  # does. Deliberately NOT permissionDecision:"allow", which would auto-approve a
  # command the user might otherwise be asked about.
  if [[ -n "$advisories" ]]; then
    jq -nc --arg c "Audit PASSED with advisories (non-blocking, no re-audit needed):
${advisories}" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        additionalContext: $c
      }
    }'
  fi

  if [[ "$consume_on_pass" == "consume" ]]; then
    rm -f "$audit_file" "$handoff_file" "$legacy_audit_file" "$legacy_handoff_file"
  else
    # Kept for a later stage to consume — possibly a commit-msg from before the
    # move, which reads only the legacy path. Copy rather than hand over: more
    # than one stage takes the keep path (the Codex PreToolUse route validates
    # and keeps before git's pre-commit does), and moving would leave the second
    # one with nothing.
    #
    # Residual, deliberate: a pre-move commit-msg consumes only the legacy copy,
    # so this location survives that commit and stays valid for the rest of the
    # 600s TTL. It cannot land unaudited content — the audit is still bound to
    # branch, HEAD, diff and subject, so any of those changing rejects it — but
    # it does relax one-shot consumption to that one hook/tree combination.
    # It disappears with the mirrors once every checkout is past the move.
    mirror_to_legacy "$audit_file" "$legacy_audit_file" || true
  fi
}

# This gate never produces the audit itself. It denies, names every way to spawn an
# auditor, and the agent uses whichever its runtime provides — Task() under Claude
# Code, collaboration.spawn_agent under Codex, the headless producer when neither
# exists. One path for every host, and no environment sniffing to get it wrong.

# Delegate to the git-level gate when installed: with core.hooksPath pointing at
# .githooks, the same contract is enforced by .githooks/pre-commit|pre-push for
# EVERY process (any agent, any harness — and humans stay exempt there), so this
# PreToolUse layer steps aside to keep the audit artifact single-consumer.
# GITHOOK_DELEGATED marks the call coming FROM that git-level gate — the one
# caller that must not be deferred, or the two layers would defer to each other
# and everything would silently pass.
# Defer ONLY when the delegate hook actually exists at this checkout: git skips
# missing hooks silently, so hooksPath-configured + delegate-absent (old ref,
# broken install) would otherwise stand BOTH layers down — a silent bypass.
# Closed-over-open: when in doubt, gate here.
if [[ -z "${GITHOOK_DELEGATED:-}" ]]; then
  hooks_path="$(git config core.hooksPath 2>/dev/null || true)"
  if [[ "$hooks_path" == *".githooks" ]]; then
    [[ "$hooks_path" != /* ]] && hooks_path="$repo_root/$hooks_path"
    if [[ -x "$hooks_path/pre-$kind" ]]; then
      # No validation here: the git-level gate runs this same script with
      # GITHOOK_DELEGATED set, and that pass is the single consumer of the artifact.
      write_command_handoff
      exit 0
    fi
  fi
fi

# Installation/guidance/framework checks remain owned by the git hooks above this
# delegated call. This branch skips only the auditor verdict and deliberately returns
# context (not permissionDecision:"allow"), so host approval policy is unchanged.
if [[ "$override_active" == true ]]; then
  allow_override
fi

# A push audit can only be produced HERE. validate_audit refuses any push dossier not
# bound to pushed_diff_sha256, and that hash comes from the ref-update stdin git hands
# the pre-push hook — input that exists for the duration of this call and cannot be
# reconstructed on a retry. Denying and asking the agent to audit afterwards would ask
# it to bind to data that no longer exists, so the producer runs at the one moment the
# exact ref update is known.
if [[ -n "${CODEX_SANDBOX:-}" && -n "${GITHOOK_DELEGATED:-}" && "$kind" == "push" ]]; then
  headless_auditor="$tooling_root/.agents/hooks/run-commit-push-audit.sh"
  if [[ -r "$headless_auditor" ]]; then
    AUDITOR_SESSION_SCOPE="$hook_session_scope" \
      AUDITOR_PROMPT_EPOCH="$hook_prompt_epoch" \
      bash "$headless_auditor" "$kind" "$command" >/dev/null 2>&1 || true
  fi
fi

# Verdict is PASS, recent, and matches current state — let the git command run.
# Consume the audit file so the next commit/push always re-audits, even if HEAD
# hasn't changed (e.g., user re-stages different content before the next commit).
if [[ -n "${GITHOOK_KEEP_AUDIT:-}" ]]; then
  validate_audit keep
else
  validate_audit consume
fi
exit 0
