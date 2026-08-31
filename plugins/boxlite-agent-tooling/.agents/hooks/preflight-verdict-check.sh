#!/usr/bin/env bash
# Stop hook: gate the end of a turn on an audited verdict
# (see .claude/agents/verdict-auditor.md).
#
# DETECTION-TRIGGERED, finding-driven loops only. The trigger is the WHOLE FINAL
# TURN — every assistant text since the last real user message, read deterministically
# from the transcript: if it draws a conclusion the reader must take on TRUST — one
# whose evidence is not shown in the turn itself — the turn must end with a fresh
# session-scoped dossier under .agents/state/ (written by the verdict-auditor
# subagent). Chat, questions, and in-progress narration end freely.
# Turn-level, not last-fragment: findings asserted mid-turn cannot hide behind a
# closing "let me check X" (that miss shipped once, caught by a sibling session's
# decision log).
#
# Flow:
#   1. Dossier present, binding fresh + matching:
#        PASS         -> allow (consumed)
#        IN_PROGRESS  -> allow with note (consumed)
#        FAIL         -> block with the findings — THE one legitimate loop: it
#                        persists until the findings are addressed and a re-audit
#                        passes. A loop driven by real findings is the point.
#   1b. No dossier, but run-verdict-audit.sh is RUNNING — audit_in_flight() decides,
#        on the lock's presence, its PID's liveness AND its freshness bound:
#        allow — the answer is being computed and no amount of re-blocking speeds it
#        up. Its verdict gates the NEXT turn end.
#   2. Dossier present but stale / mismatched (branch, HEAD, tree, age):
#        DISCARD it and fall through to detection. Never block on bookkeeping —
#        "the binding moved" is not a finding, and blocking on it was the
#        meaningless-loop class (e.g. a commit moving HEAD out from under a
#        dossier written seconds earlier).
#   3. No dossier: TRIAGE the turn text through a three-tier cascade, cheapest first,
#      so the 5-10s model round-trip is spent only where it actually decides anything:
#        A. harness noise (0ms)  — the assistant slot holds only text the HARNESS
#           wrote (API errors, quota notices, interruption markers). No model produced
#           it, so it cannot be a claim -> allow. 14.4% of real turns.
#        B. assertion-only (0ms) — a high-precision SUBSET of the fallback list below,
#           limited to forms that report an observation ("173/173 tests pass", a
#           whole-line "done.", a line-initial "Verified …") -> block. 10.7% of turns.
#        C. the model (5-10s)    — everything else. "Is this a conclusion the reader
#           must take on trust, with nothing shown that produced it?" A
#           fast model (haiku) answers YES/NO; when no model is reachable the static
#           pattern list below decides (deterministic fallback, e.g. sessions without
#           a model CLI). YES -> block with the audit instruction; NO -> allow
#           (announced to the human via systemMessage, invisible to the model).
#      No transcript (absent / unreadable / zero bytes) -> allow; nothing to judge.
#      A transcript WITH content but no assistant text is NOT that case — the hook
#      could not SEE the turn (unflushed final message, or a torn write jq could not
#      parse). It waits up to 2s for the text, then fails open under a `blind-allow`
#      rung so the log distinguishes "quiet session" from "gate never looked".
#
#      Tiers A and B are latency work ONLY — neither loosens the gate. A stays sound by
#      requiring EVERY non-empty line to be harness text, so a turn that errored and
#      retried still reaches B/C. B stays sound by leaving every prose-ambiguous
#      phrasing ("tests pass", "root cause is", "deploy is healthy") to the model:
#      removing the static false positives is the whole reason the model is primary,
#      and a turn merely DISCUSSING verdict phrasing must still be allowed.
#   4. Flush-race guard: the harness can fire Stop before appending the turn's final
#      message, leaving the PREVIOUS (already-gated) message last in the transcript.
#      The hook records the uuid it judged; if the newest uuid equals it, the hook
#      waits briefly for the fresh message and, failing that, allows — a message is
#      never judged twice.
#
# Wired in .claude/settings.json under hooks.Stop (no matcher — fires every turn end).
#
# Design notes
# ------------
# * Triage is the auditor's applicability judgment, extracted: the full verdict-auditor
#   already begins by deciding whether the message asserts anything verifiable. The
#   hook runs that ONE question on a small fast model (~seconds, message-only context)
#   so the expensive audit is spawned only when the answer is YES. Any classifier
#   failure — CLI absent, timeout, garbage output — degrades to the static pattern
#   list, and a pattern miss degrades further to the agent's CLAUDE.md duty: every
#   failure moves toward #915's honor system, never toward a trap. A false positive
#   costs ONE synchronous audit that trivially PASSes — a tax, not a loop. Fenced
#   blocks and multi-word code spans are stripped before triage so documentation ABOUT
#   verdicts does not trigger. The CLASSIFIER additionally keeps single-token spans,
#   because they are citations and its question turns on them; the pattern tiers keep
#   the old text, since anchoring on a token pulled to line start loosened them.
#   VERDICT_CLASSIFIER_CMD overrides the classifier (tests use stubs; set it to
#   `false` to force the regex path).
#
# * KNOWN TRAP, unfixed: "never toward a trap" covers CLASSIFIER failure only. When the
#   AUDITOR is unreachable, run-verdict-audit.sh exits 1 with no dossier and no rung
#   tells that apart from "no audit attempted", so the turn cannot end until the API
#   recovers. Needs the runner to signal unavailability.
#
# * Why no loop can form: validation runs BEFORE detection, binding mismatches discard,
#   and audit_in_flight() allows while the bash runner works. FAIL-with-findings is the
#   only repeating block, which is the requirement. A Task-launched auditor leaves no
#   process to observe and so still re-blocks. Do NOT re-derive this from "the audit is
#   synchronous" — that instructs the model, and the harness ignores it.
#
# * Tree-hash binding: at stop time the work is usually UNCOMMITTED (HEAD has not
#   moved), so HEAD alone can't tell "audited" from "changed since audit". The dossier
#   binds to a content-addressed hash of the full working tree via a throwaway index +
#   `git write-tree` (deterministic; no timestamps; never touches the real index). The
#   verdict-auditor computes it the SAME way. On mismatch the dossier is discarded and
#   the CURRENT message re-detected — so a real verdict still demands a fresh audit,
#   while a chat ending after the tree moved is not trapped.
#
# * One-shot consumption: the dossier is `rm -f`'d on every exit path except a
#   fresh+matching FAIL (kept so the finding-driven block persists across attempts
#   to end without addressing it).
#
# * Soft mode is NOT enforcement: the Stop hook's systemMessage is shown to the HUMAN
#   only — the model never sees it (documented hook contract; only a block's `reason`
#   reaches the model). Soft mode exists as telemetry / emergency rollback (flip
#   VERDICT_GATE_HARD_BLOCK=0 in settings env; it propagates mid-session). Default: hard.
#
# Threat model & accepted limitations (this gate catches HONEST mistakes, not a malicious
# parent — the parent and the auditor share one filesystem + toolset):
#   - NOT forge-resistant: the parent can write the dossier itself. Real tamper-evidence
#     needs a signer the parent cannot impersonate (a harness-level capability) — a shell
#     hook cannot provide it. Out of scope by design.
#   - NOT evasion-resistant: a verdict worded outside the pattern list is not detected.
#     The patterns are a curated, tunable list (below) targeting how claims are actually
#     phrased; misses degrade to #915's self-declared behavior, never to a trap.
#
# Tests: bash .agents/hooks/preflight-verdict-check.test.sh
set -uo pipefail

for required_command in jq perl; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'preflight-verdict-check: required dependency not found: %s\n' \
      "$required_command" >&2
    exit 2
  fi
done

raw_payload="$(cat)"
payload="$(printf '%s' "$raw_payload" | jq -ecs '
  if length == 1 and (.[0] | type) == "object" then .[0] else empty end
' 2>/dev/null || true)"
if [[ -z "$payload" ]]; then
  printf 'preflight-verdict-check: expected exactly one JSON hook object.\n' >&2
  exit 1
fi
transcript_path="$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null || echo '')"
session_id="$(printf '%s' "$payload" | jq -r '
  if (.session_id | type) == "string" then .session_id else "" end
' 2>/dev/null || echo '')"
session_field_state="$(printf '%s' "$payload" | jq -r '
  if has("session_id") | not then "absent"
  elif (.session_id | type) == "string" and (.session_id | length) > 0 then "valid"
  else "invalid"
  end
' 2>/dev/null || echo 'invalid')"
if [[ "$session_field_state" == invalid ]]; then
  printf 'preflight-verdict-check: session_id must be a non-empty string when present.\n' >&2
  exit 1
fi
has_session_id=false
[[ "$session_field_state" == valid ]] && has_session_id=true
last_assistant_message="$(printf '%s' "$payload" | jq -r '
  if (.last_assistant_message | type) == "string" then .last_assistant_message else "" end
' 2>/dev/null || echo '')"
stop_hook_active="$(printf '%s' "$payload" | jq -r '
  if .stop_hook_active == true then "true" else "false" end
' 2>/dev/null || echo 'false')"

project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
if ! repo_root="$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null)"; then
  printf 'preflight-verdict-check: project directory is not a Git repository: %s\n' \
    "$project_dir" >&2
  exit 1
fi
repo_root="$(cd "$repo_root" && pwd -P)"
project_dir="$repo_root"
tooling_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
audit_state_lib="$tooling_root/.agents/lib/verdict-audit-state.sh"
override_state_lib="$tooling_root/.agents/lib/auditor-override-state.sh"
if [[ ! -r "$audit_state_lib" || ! -r "$override_state_lib" ]]; then
  printf 'preflight-verdict-check: shared audit state libraries are unavailable.\n' >&2
  exit 1
fi
# shellcheck source=../lib/verdict-audit-state.sh
source "$audit_state_lib"
# shellcheck source=../lib/auditor-override-state.sh
source "$override_state_lib"
if [[ "$has_session_id" == "true" ]]; then
  if ! session_scope="$(verdict_audit_scope_from_hook_payload \
      "$payload" "$project_dir" 2>/dev/null)"; then
    printf 'preflight-verdict-check: could not derive the session audit scope.\n' >&2
    exit 1
  fi
else
  session_scope="-"
fi
branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || echo '?')"
head="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo '?')"
state_dir="$project_dir/.agents/state"
stable_verdict_file="$(verdict_audit_state_path "$state_dir/last-verdict.json" "$session_scope")"
verdict_file="$stable_verdict_file"
auditor_verdict_file="$stable_verdict_file"
verdict_request_file="$(verdict_audit_state_path "$state_dir/verdict-request" "$session_scope")"
audit_decision_mutex_file="${verdict_request_file}.decision.mutex"
decision_lease_pid=0
decision_lease_status_file=""
# A FAILed dossier is parked here when the agent's fix moves the tree and invalidates
# the binding, so the next audit re-checks known findings instead of starting cold.
prev_verdict_file="$(verdict_audit_state_path "$state_dir/last-verdict.prev.json" "$session_scope")"
last_uuid_file="$(verdict_audit_state_path "$state_dir/verdict-last-uuid" "$session_scope")"
decision_log="$(verdict_audit_state_path "$state_dir/verdict-decisions.log" "$session_scope")"
# When Codex has no transcript, preserve its stable Stop message in the transcript
# shape the independent auditor already consumes. This is gitignored runtime state,
# not evidence invented by the gate: the text is copied byte-for-byte from the event.
payload_transcript_file="$(verdict_audit_state_path "$state_dir/verdict-stop-message.jsonl" "$session_scope")"
prompt_epoch_file="$(verdict_audit_state_path "$state_dir/verdict-prompt-epoch" "$session_scope")"
# Published by run-verdict-audit.sh while it holds the adjacent kernel lease. The first
# two fields are runner PID + deadline; later fields bind session, owner, and generation.
# Together they tell "the agent ignored the findings" from "the answer is coming".
audit_lock_file="$(verdict_audit_state_path "$state_dir/verdict-audit.lock" "$session_scope")"
audit_mutex_file="${audit_lock_file}.mutex"
# Ceiling on a lock's self-declared deadline. NOT max_age_seconds — dossier staleness
# and "how long may an audit run" are different questions. Shared with the runner so a
# configured timeout cannot publish a lease this gate immediately rejects.
# shellcheck disable=SC2154 # Assigned by verdict-audit-state.sh above.
audit_lock_max_seconds="$verdict_audit_lock_max_seconds"
max_age_seconds=600
classifier_timeout_seconds=20

# UserPromptSubmit atomically advances this session epoch before it waits for any gate
# mutex. This Stop invocation may trust authority only while the entry snapshot remains
# current. A missing marker is the initial epoch; malformed state fails closed.
read_prompt_epoch() {
  [[ "$session_scope" != "-" ]] || { printf '-'; return 0; }
  if [[ ! -e "$prompt_epoch_file" && ! -L "$prompt_epoch_file" ]]; then
    printf '-'
    return 0
  fi
  local epoch
  epoch="$(verdict_audit_read_single_record "$prompt_epoch_file" 2>/dev/null)" || return 1
  [[ "$epoch" =~ ^[1-9][0-9]*-[1-9][0-9]*-[0-9]+$ ]] || return 1
  printf '%s' "$epoch"
}
entry_prompt_epoch="$(read_prompt_epoch 2>/dev/null)" || entry_prompt_epoch=""
prompt_epoch_is_current() {
  [[ "$session_scope" == "-" ]] && return 0
  [[ -n "$entry_prompt_epoch" ]] || return 1
  local current_epoch
  current_epoch="$(read_prompt_epoch 2>/dev/null)" || return 1
  [[ "$current_epoch" == "$entry_prompt_epoch" ]]
}

# One line per Stop decision (gitignored): timestamp, message identity, deciding
# rung, outcome — so "why did/didn't the gate fire?" is answerable with tail
# instead of fixture reconstruction. Best-effort: logging must never fail the
# hook. Rotated in place to stay bounded.
log_decision() {  # rung outcome
  local line
  mkdir -p "$(dirname "$decision_log")" 2>/dev/null || return 0
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) ${FINAL_ID:--} $1 $2"
  verdict_audit_append_log_line "$decision_log" "$line" 2>/dev/null || true
}

# UserPromptSubmit and dossier consumption share this short-lived session mutex. The
# prompt hook takes it before revocation; the Stop gate takes it before hiding a dossier
# under a quarantine name. That gives the two events one linear order and prevents an old
# generation from being restored or parked after cancellation already returned.
stop_decision_lease() {
  if [[ "$decision_lease_pid" =~ ^[1-9][0-9]*$ ]]; then
    kill -TERM "$decision_lease_pid" 2>/dev/null || true
    wait "$decision_lease_pid" 2>/dev/null || true
  fi
  decision_lease_pid=0
  [[ -z "$decision_lease_status_file" ]] || rm -f "$decision_lease_status_file"
  decision_lease_status_file=""
}

start_decision_lease() {
  [[ "$session_scope" != "-" ]] || return 0
  local status="" i=0 parent="$$"
  decision_lease_status_file="${audit_decision_mutex_file}.status-$$-${RANDOM:-0}"
  rm -f "$decision_lease_status_file"
  perl -MFcntl=:DEFAULT,:flock -e '
    my ($mutex_path, $status_path, $parent) = @ARGV;
    sub report {
      my ($value) = @_;
      sysopen(my $status, $status_path, O_WRONLY | O_CREAT | O_EXCL, 0600)
        or exit 2;
      print {$status} $value;
      close($status);
    }
    $SIG{ALRM} = sub { report("error") if !-e $status_path; exit 2 };
    alarm 2;
    exit 2 if lstat($mutex_path) && -l _;
    my $flags = O_RDWR | O_CREAT | O_APPEND | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $mutex, $mutex_path, $flags, 0600) or do { report("error"); exit 2 };
    my @opened = stat($mutex);
    my @named = lstat($mutex_path);
    if (!@opened || !@named || !-f $mutex || $opened[3] != 1
        || $opened[0] != $named[0] || $opened[1] != $named[1]) {
      report("error");
      exit 2;
    }
    flock($mutex, LOCK_EX) or do { report("error"); exit 2 };
    @opened = stat($mutex);
    @named = lstat($mutex_path);
    if (!@opened || !@named || !-f $mutex || $opened[3] != 1
        || $opened[0] != $named[0] || $opened[1] != $named[1]) {
      report("error");
      exit 2;
    }
    alarm 0;
    report("ok");
    select(undef, undef, undef, 0.05) while getppid() == $parent;
  ' "$audit_decision_mutex_file" "$decision_lease_status_file" "$parent" &
  decision_lease_pid=$!
  while (( i < 250 )); do
    if status="$(verdict_audit_read_single_record \
        "$decision_lease_status_file" 2>/dev/null)"; then
      break
    fi
    kill -0 "$decision_lease_pid" 2>/dev/null || break
    sleep 0.01
    (( i += 1 ))
  done
  rm -f "$decision_lease_status_file"
  decision_lease_status_file=""
  if [[ "$status" == ok ]]; then
    return 0
  fi
  stop_decision_lease
  return 1
}

trap stop_decision_lease EXIT

allow()           { exit 0; }                                              # let the turn end, silently
# User-visible, model-invisible allow: a Stop hook systemMessage is shown to the
# HUMAN in the terminal only — the model never sees it (documented hook contract).
# Announcing triage results this way keeps the agent's context clean and the gate
# loop-inert while the human still sees every decision live.
allow_with_note() { jq -nc --arg m "$1" '{continue:true, systemMessage:$m}'; exit 0; }
# Hard mode (default, set in settings.json env): block conditions block. Soft mode
# (VERDICT_GATE_HARD_BLOCK=0) demotes them to a user-visible nudge the MODEL never
# sees — rollback/telemetry only, see design notes.
block() {
  # A prompt can arrive while a classifier or instruction renderer is still running.
  # Revalidate at the final output boundary so a superseded Stop can never publish a
  # late block even when every earlier branch check observed the old epoch.
  prompt_epoch_is_current || allow
  # Default HARD, matching the two doc sites above. Defaulting to soft meant only
  # Claude Code was gated: it is the sole caller that sets this, via settings.json
  # env, so the Codex registration in .codex/hooks.json and any direct invocation
  # got a non-blocking note instead. Set VERDICT_GATE_HARD_BLOCK=0 to roll back.
  if [[ "${VERDICT_GATE_HARD_BLOCK:-1}" != "0" ]]; then
    # The host still feeds reason back to the model, but must not render that
    # control prompt as Hook feedback in the user's main transcript.
    jq -nc --arg r "$1" '{decision:"block", reason:$r, suppressOutput:true}'
  else
    jq -nc --arg r "$1" '{continue:true, systemMessage:("[verdict-gate] " + $r)}'
  fi
  exit 0
}

# Content-addressed hash of the full working tree (tracked + untracked, full
# content), via a throwaway index. Deterministic and read-only w.r.t. the real
# index/tree. Keep IDENTICAL to the snippet in verdict-auditor.md.
compute_tree_hash() {
  local idx; idx="$(mktemp)"
  GIT_INDEX_FILE="$idx" git -C "$repo_root" read-tree HEAD >/dev/null 2>&1
  GIT_INDEX_FILE="$idx" git -C "$repo_root" add -A >/dev/null 2>&1
  GIT_INDEX_FILE="$idx" git -C "$repo_root" write-tree 2>/dev/null
  rm -f "$idx"
}

# A prompt-scoped user decision is a gate outcome, never an auditor verdict. It is
# checked before dossier consumption so a valid override can release a retained FAIL,
# but it writes only an OVERRIDDEN use record and never changes the dossier schema.
if [[ "$session_scope" != "-" ]] \
   && auditor_override_load_valid_grant \
        "$repo_root" "$session_scope" "$entry_prompt_epoch"; then
  override_tree_hash="$(compute_tree_hash)"
  override_context_hash="$(printf '%s\n%s\n%s\n' "$branch" "$head" "$override_tree_hash" \
    | shasum -a 256 | awk '{print $1}')"
  if ! auditor_override_log_use "$repo_root" "$session_scope" stop \
      "$override_context_hash" >/dev/null 2>&1; then
    block "Auditor override evidence could not be recorded; the verdict gate remains closed."
  fi
  log_decision override overridden-allow
  allow_with_note "[verdict-gate] OVERRIDDEN BY USER for this prompt; auditor PASS was not asserted"
fi

# ALL assistant text of the FINAL TURN — every text block emitted since the last
# real user message — from the session transcript (JSONL). Turn-level, not
# last-fragment: a finding asserted mid-turn ("no auto-start in the proxy")
# followed by closing narration ("let me check X") must still reach triage;
# judging only the trailing fragment let exactly that class slip (observed live
# in a sibling session's decision log).
#
# HARNESS-AGNOSTIC by convention, not by schema list: an assistant record is one
# where ANY object inside has role/type=="assistant"; a REAL user record (turn
# boundary) is one with role/type=="user" carrying actual text — tool results
# riding user-role records do not end a turn. Text is every string under a
# `text` key inside blocks whose type mentions "text" (Claude Code `text`,
# Codex `output_text`, any future agent following the conventions), falling
# back to all `text`-key strings if that yields nothing. New coding agents need
# ZERO code here — at most set VERDICT_EXTRACTOR_CMD in their own hook wiring
# for a truly alien format (invoked with the transcript path as $1; stdout =
# the turn text to judge).
# Turn identity is a checksum of the joined text — content-derived, no
# per-harness ids — used by the never-judge-twice race guard.
# Empty transcript text is retried when the file has content: the hook can run before
# the harness flushes the final assistant record. Only after that bounded wait does
# the caller fall back to Codex Stop.last_assistant_message. Empty text after both
# sources means detection cannot run → allow (fail-open, never trap on absent state).
FINAL_ID=""
FINAL_TEXT=""
FINAL_SOURCE=""
identify_final_message() {
  FINAL_ID="cksum-$(printf '%s' "$FINAL_TEXT" | cksum | tr ' \t' '--')"
}
extract_final_message() {
  FINAL_ID=""; FINAL_TEXT=""; FINAL_SOURCE=""
  if [[ -n "$transcript_path" && -r "$transcript_path" ]]; then
    if [[ -n "${VERDICT_EXTRACTOR_CMD:-}" ]]; then
      FINAL_TEXT="$(bash -c "$VERDICT_EXTRACTOR_CMD \"\$1\"" _ "$transcript_path" 2>/dev/null || true)"
    else
      FINAL_TEXT="$(jq -rs '
      def is_assistant: [.. | objects | select((.role? == "assistant") or (.type? == "assistant"))] | length > 0;
      def is_real_user:
        # A REAL user record carries a text-typed block at the TOP LEVEL of the
        # role-object own content (or plain string content). Tool results ride
        # user-role records with text nested INSIDE a tool_result block —
        # recursing into them (an earlier version did) turned every Read/Agent/
        # MCP result into a fake turn boundary and mid-turn findings escaped.
        ((.type? == "user") and
          ((.message.content? | type) == "string"
           or ([.message.content[]? | select((.type? // "") == "text")] | length) > 0))
        or ([.. | objects | select((.role? // "") == "user")
             | [.content[]? | select((.type? // "" | tostring) | test("text"))] | length]
            | any(. > 0));
      . as $r
      | ([$r[] | is_real_user] | rindex(true)) as $lastu
      | $r[(if $lastu == null then 0 else $lastu + 1 end):]
      | [.[] | select(is_assistant) | (
          ([.. | objects | select((.type? // "" | tostring) | test("text")) | .text? // empty | strings] | join("\n")) as $typed
          | (if ($typed | length) > 0 then $typed
             else ([.. | objects | .text? // empty | strings] | join("\n")) end)
        ) | select(length > 0)]
      | join("\n\n")' "$transcript_path" 2>/dev/null || true)"
    fi
  fi
  [[ -n "$FINAL_TEXT" ]] || return 0
  FINAL_SOURCE="transcript"
  identify_final_message
}
use_payload_message() {
  [[ -n "$last_assistant_message" ]] || return 0
  FINAL_TEXT="$last_assistant_message"
  FINAL_SOURCE="payload"
  identify_final_message
}

# Resolve the current audited message before looking at any dossier. Session ownership
# alone is insufficient: a real steer stays in the same session, so the request must
# also bind the exact assistant turn text that the auditor was asked to judge.
transcript_had_content=false
resolve_final_message() {
  extract_final_message
  transcript_had_content=false
  [[ -n "$transcript_path" && -s "$transcript_path" ]] && transcript_had_content=true
  if [[ -z "$FINAL_TEXT" && "$transcript_had_content" == true ]]; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      sleep 0.2
      extract_final_message
      [[ -n "$FINAL_TEXT" ]] && break
    done
  fi
  # Codex permits a null transcript_path and supplies this stable Stop field. Apply it
  # only after the transcript flush window so one trailing fragment cannot hide an
  # earlier verdict from the same turn.
  [[ -z "$FINAL_TEXT" ]] && use_payload_message
}

# Fenced blocks go entirely: verdict phrasing quoted inside one is documentation, not a
# claim. Inline spans are split by whether they contain whitespace, because the two
# kinds do opposite things to triage:
#   * multi-word (`tests pass`, `root cause is`) — quoted prose. Stripped, same reason.
#   * single-token (`preflight-verdict-check.sh:262`, `audit_in_flight`) — a citation.
# Stripping BOTH deleted exactly the evidence the triage question asks about, so a turn
# that carefully cited its sources reached the classifier as fragments and got judged
# more harshly than one that asserted the same thing vaguely. Single tokens keep their
# text and lose their backticks so they read as ordinary words.
# TWO strippings, because the tiers want opposite things and a single one silently
# loosened tier A. Keeping a span's text drops its delimiters, which can pull the token
# to the START of a line: `API` Error handling is fixed → "API Error handling is fixed",
# which harness_patterns anchors on, so an assertion left through the top of the cascade
# with no model call. `Request` was aborted and `Credit` balance is too low do the same,
# and `Done. #1161` defeats the $-anchored done. assertion.
#   * static  — every span removed. What harness_patterns, assertion_patterns and
#               verdict_patterns were written against; they match multi-word PROSE, so
#               removing citations costs them nothing and keeps their anchors honest.
#   * cited   — single-token spans kept. Only the classifier sees this, because only its
#               question ("is the evidence shown?") depends on citations surviving.
strip_code_static() {
  awk 'BEGIN{fence=0} /^[[:space:]]*```/{fence=!fence; next} !fence' | sed -E 's/`[^`]*`//g'
}

# Spans are split by ALTERNATION, not by a regex over backticks: ``…`` are ambiguous
# delimiters, so `[^`]*[[:space:]][^`]*` happily matches the GAP BETWEEN two spans
# (dropping the prose between a citation and a quote) instead of the span itself.
strip_code_cited() {
  awk '
    BEGIN { fence = 0 }
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    {
      n = split($0, p, "`")
      ends_tick = ($0 ~ /`$/)
      out = p[1]
      for (i = 2; i <= n; i++) {
        inside = (i % 2 == 0)
        # A trailing unterminated span is ordinary text, not a span.
        if (inside && i == n && !ends_tick) inside = 0
        if (inside) { if (p[i] !~ /[[:space:]]/) out = out p[i] }
        else out = out p[i]
      }
      print out
    }'
}

# ── Tier A: harness text sitting in the assistant slot ───────────────────────
# The assistant slot also carries text the HARNESS wrote, not the model: API errors,
# quota notices, interruption markers. It asserts nothing — no model produced it — so
# it can never be a verdict, and spending a 5-10s model round-trip to learn that is
# pure latency. Measured on this repo's transcripts: 81 of 563 real turns (14.4%) are
# exactly this, led by "API Error: 400 Your input exceeds the context window" (x43)
# and "No response requested." (x15).
#
# EVERY non-empty line must match — that is the soundness property, and it is why
# this is not a heuristic about content. Anchoring only the FIRST line would leak a
# real verdict whenever the model hit a transient error and then retried inside the
# same turn ("API Error: Overloaded" followed by "Root cause is X. All 53 tests
# pass."). Both variants catch the same 81 turns, so the strict one costs nothing.
harness_patterns='^[[:space:]]*(API Error'
harness_patterns+='|No response requested\.'
harness_patterns+='|Your organization has disabled'
harness_patterns+="|You've hit your (weekly|usage) limit"
harness_patterns+='|Credit balance is too low'
harness_patterns+='|Claude Code is unable'
harness_patterns+='|\[?Request (was )?(aborted|interrupted)'
harness_patterns+=')'
is_harness_noise() {  # $1 = stripped turn text
  local total matched
  total="$(printf '%s\n' "$1" | grep -c '[^[:space:]]' 2>/dev/null || true)"
  [[ "${total:-0}" -gt 0 ]] || return 1
  matched="$(printf '%s\n' "$1" | grep -Eic "$harness_patterns" 2>/dev/null || true)"
  [[ "${matched:-0}" -eq "$total" ]]
}

# ── Tier B: assertion-only claims, decidable without the model ───────────────
# A deliberately SMALL subset of the fallback list below: forms that REPORT an
# observation rather than name one — a concrete count ("173/173 tests pass"), a
# whole-line "done.", a line-initial "Verified …". Prose that merely DISCUSSES
# verdict phrasing ("people write things like tests pass or root cause is X") cannot
# take these shapes, so promoting them ahead of the classifier does not resurrect the
# static false positives the classifier exists to remove — which is why the ambiguous
# majority ("tests pass", "root cause is", "deploy is healthy") stays with the model.
# "deploy is healthy" is in the ambiguous group on purpose: "once the deploy is
# healthy, we proceed" is discussion, not a claim.
# Measured: 60/563 turns (10.7%), zero false blocks across 21 model-labelled hits.
assertion_patterns='[0-9]+ */ *[0-9]+ +(tests?|checks?|suites?|cases?)? *(pass(ed|ing|es)?|green)'
assertion_patterns+='|^[[:space:]]*done[.! ]*$'
assertion_patterns+='|^[[:space:]]*(verified|confirmed)[[:space:]]+[a-z]'

# Triage: ask a small fast model whether the turn draws a conclusion the reader has to
# take on TRUST. Not "does it state facts" — nearly all engineering status does, and
# that question blocked 18 of 22 sampled real turns while the 14 audits that actually
# completed in the same window produced zero findings. The cost of a false YES is
# minutes of blocked author; the cost of a false NO is one unaudited claim in a system
# whose own threat model is honest mistakes. Asking about EVIDENCE rather than facts
# took the same 22 turns to 3 YES with no turn newly blocking.
# Echoes YES / NO / UNKNOWN. UNKNOWN (no CLI, timeout, garbage) → regex fallback.
# VERDICT_CLASSIFIER_CMD overrides the whole classifier invocation (stdin = turn
# text, stdout = YES/NO); tests stub it, `false` forces UNKNOWN.
triage_prompt='Reply with exactly one word: YES or NO. Do not explain.

Below is the assistant text of a just-ended turn. An independent audit costs minutes
and blocks the author, so it should run only where it changes the odds that something
wrong ships.

NO: narration, plans, questions, corrections, status — or any claim whose evidence is
in the text itself (quoted output, counts shown as produced, a cited file:line, a
named commit).

YES: a conclusion the reader must take on trust — a fix declared to work, a root
cause, "no issues", a done/ready claim — with nothing shown that produced it.

One word: YES or NO.'
# The old parse was `tail -n1 | tr -dc 'A-Za-z'`, which turns any explanatory answer
# into a nonsense token — silently UNKNOWN, silently the regex fallback. That fired on
# real turns under the previous prompt too. Prefer the first token (a compliant model
# leads with it); accept a whole-output match; otherwise UNKNOWN. Deliberately NOT a
# scan for a bare "no" anywhere in the text: prose says "no" constantly, and reading an
# explanation as an allow would loosen the gate by accident.
classifier_answer() {  # stdin = raw model output; echoes YES/NO/UNKNOWN
  local raw first whole
  raw="$(cat)"
  first="$(printf '%s' "$raw" | awk 'NF{print toupper($1); exit}' | tr -dc 'A-Za-z')"
  # A model that reasons first and answers last ("Let me think.\nNO") was readable under
  # the old tail -n1 and must not regress to UNKNOWN. Whole LINE only — a prose line
  # ending in "no" is not an answer, and treating it as one would loosen the gate.
  last="$(printf '%s' "$raw" | awk 'NF{l=$0} END{print toupper(l)}' | tr -dc 'A-Za-z')"
  whole="$(printf '%s' "$raw" | tr -dc 'A-Za-z' | tr '[:lower:]' '[:upper:]')"
  case "$first" in YES|NO) printf '%s' "$first"; return ;; esac
  case "$last"  in YES|NO) printf '%s' "$last";  return ;; esac
  case "$whole" in YES|NO) printf '%s' "$whole"; return ;; esac
  printf 'UNKNOWN'
}
should_audit() {  # stdin-less; uses $1 as the stripped message; echoes YES/NO/UNKNOWN
  local msg="$1" out=""
  if [[ -n "${VERDICT_CLASSIFIER_CMD:-}" ]]; then
    out="$(printf '%s' "$msg" | bash -c "$VERDICT_CLASSIFIER_CMD" 2>/dev/null | classifier_answer)"
  elif command -v claude >/dev/null 2>&1; then
    # perl alarm = portable timeout (macOS has no coreutils `timeout`).
    # disableAllHooks guards nested-hook recursion from inside a hook.
    out="$(printf '%s\n\n<message>\n%s\n</message>\n' "$triage_prompt" "$msg" \
      | perl -e 'alarm shift; exec @ARGV' "$classifier_timeout_seconds" \
          claude -p --model claude-haiku-4-5-20251001 --settings '{"disableAllHooks":true}' 2>/dev/null \
      | classifier_answer)"
  fi
  case "$out" in
    YES) echo YES ;;
    NO)  echo NO ;;
    *)   echo UNKNOWN ;;
  esac
}

# Fallback claim patterns (ERE, matched case-insensitively) for when the classifier
# is unreachable. Targets how verdicts are actually phrased; tune here. A miss
# degrades to self-declared, a spurious hit costs one trivial-PASS audit.
verdict_patterns='root cause (is|was|confirmed|:)'
verdict_patterns+='|(all |the )?(tests?|suites?|checks?|builds?) (now |all |still )?(pass(es|ed|ing)?|green)'
verdict_patterns+='|[0-9]+/[0-9]+ (tests? )?(pass|passing|green)'
verdict_patterns+='|no (issues|bugs|problems|errors|regressions)'
verdict_patterns+='|(is|are|looks?) (now )?(fixed|resolved|working|correct|healthy|stable|live|green|complete|done|verified)'
verdict_patterns+='|works (as expected|correctly|now|fine|end.to.end)'
verdict_patterns+='|(fix|change|patch|refactor|migration) (works|is in place)'
verdict_patterns+='|(verified|confirmed)([;,.!]| that| the| it| locally| e2e| end)'
verdict_patterns+='|^[[:space:]]*(verified|confirmed) [a-z]'
verdict_patterns+='|deploy(ment|ed)? (is |looks? )?(healthy|live|successful|stable)'
verdict_patterns+='|^[[:space:]]*done[.! ]*$'
# Chinese claim phrasings (conservative set — the classifier handles languages the
# list never will; these keep the FALLBACK useful in bilingual sessions).
verdict_patterns+='|根因(是|为|：|:)'
verdict_patterns+='|(测试|用例)(全部|都|均)?(通过|绿)'
verdict_patterns+='|没有(问题|异常|回归)'
verdict_patterns+='|已(修复|解决|完成|验证)'
verdict_patterns+='|(部署|服务|线上)(正常|健康|稳定)'

# ── Shared re-audit instruction (used by every block path) ───────────────────
# The block `reason`s below are the gate's UX + anti-cheating contract — what Claude
# reads when a verdict is detected unaudited, or a declared verdict FAILed. Invariants:
#   • Direct Claude to invoke the verdict-auditor subagent SYNCHRONOUSLY (Task with
#     run_in_background: false) — a background audit's completion event is what
#     created the #892 loop; a synchronous audit keeps audit and verdict in one turn.
#   • The AUDITOR — not Claude — writes ${verdict_file}. Claude must not write or
#     hand-edit the dossier (that is grading its own homework / confabulating proof).
#   • Offer the honest exits: IN_PROGRESS if not actually done; a `blocked` proof
#     entry (with residual risk) if proof genuinely can't be produced in this env.
#   • After the auditor reports, deliver the intended user-facing answer again. PASS
#     repeats the blocked text so its checksum stays bound; FAIL revises and re-audits.
#     Hook feedback and audit metadata are control-plane output, not the conclusion.
#
#   • When a prior audit FAILED on this same work, hand its findings to the auditor so
#     round N+1 re-checks them against the delta instead of re-deriving every claim
#     from cold. A function, not a string, so the prior-dossier note reflects state as
#     it is at BLOCK time rather than at definition time.
#
# Variables available: ${transcript_path} ${branch} ${head} ${verdict_file}
#                      ${prev_verdict_file} ${audit_generation}
audit_generation="legacy"
request_is_current=false
verdict_request_body=""

load_verdict_request() {
  if [[ "$session_scope" == "-" ]]; then
    audit_generation="legacy"
    request_is_current=true
    return 0
  fi
  local body generation deadline message_id extra now allow_canceled="${1:-false}"
  [[ -r "$verdict_request_file" ]] || return 1
  body="$(verdict_audit_read_single_record "$verdict_request_file" 2>/dev/null)" || return 1
  read -r generation deadline message_id extra <<< "$body"
  now="$(date +%s)"
  verdict_audit_epoch_is_bounded "$deadline" || return 1
  [[ "$generation" =~ ^[1-9][0-9]*-[0-9]+-[0-9]+$ \
     && "$message_id" =~ ^cksum-[0-9]+-[0-9]+$ \
     && -z "$extra" \
     && "$message_id" == "$FINAL_ID" ]] || return 1
  (( now <= deadline && deadline <= now + audit_lock_max_seconds )) || return 1
  audit_generation="$generation"
  audit_cancellation_file="$(verdict_audit_cancellation_path \
    "$state_dir" "$session_scope" "$audit_generation")"
  if [[ "$allow_canceled" != true ]] \
     && verdict_audit_cancellation_exists "$audit_cancellation_file"; then
    return 1
  fi
  if [[ "$session_scope" != "-" ]]; then
    auditor_verdict_file="${stable_verdict_file}.audit-${audit_generation}"
    if [[ -e "$auditor_verdict_file" || -L "$auditor_verdict_file" ]]; then
      verdict_file="$auditor_verdict_file"
    else
      verdict_file="$stable_verdict_file"
    fi
  fi
  verdict_request_body="$body"
  request_is_current=true
  return 0
}

consume_current_verdict_request() {
  [[ "$session_scope" != "-" ]] || return 0
  [[ -n "$verdict_request_body" ]] || return 1
  prompt_epoch_is_current || return 1
  verdict_audit_remove_record_if_matches \
    "$verdict_request_file" "$verdict_request_body" >/dev/null 2>&1 || return 1
  prompt_epoch_is_current
}

current_verdict_request_matches() {
  [[ "$session_scope" != "-" ]] || return 0
  [[ -n "$verdict_request_body" ]] || return 1
  local current_body
  current_body="$(verdict_audit_read_single_record \
    "$verdict_request_file" 2>/dev/null)" || return 1
  [[ "$current_body" == "$verdict_request_body" ]]
}

current_verdict_authority_matches() {
  prompt_epoch_is_current || return 1
  current_verdict_request_matches || return 1
  [[ "$session_scope" == "-" ]] && return 0
  [[ -n "${audit_cancellation_file:-}" ]] || return 1
  ! verdict_audit_cancellation_exists "$audit_cancellation_file"
}

discard_path_for_current_epoch() {  # stable-path
  local stable_path="$1"
  prompt_epoch_is_current || return 1
  [[ -e "$stable_path" || -L "$stable_path" ]] || return 0
  local quarantine="${stable_path}.discard-$$-${RANDOM:-0}" selected_identity
  selected_identity="$(verdict_audit_path_identity "$stable_path" 2>/dev/null)" \
    || return 1
  prompt_epoch_is_current || return 1
  verdict_audit_rename_exact "$stable_path" "$quarantine" 2>/dev/null || return 1
  if ! verdict_audit_selected_identity_matches \
      "$quarantine" "$selected_identity" 2>/dev/null; then
    verdict_audit_restore_no_clobber \
      "$quarantine" "$stable_path" 2>/dev/null || true
    return 1
  fi
  rm -f "$quarantine"
  rmdir "$quarantine" 2>/dev/null || true
}

# Replace a small session record without ever overwriting a pathname that a newer prompt
# or Stop may have published. A staged hardlink retains inode identity through the final
# epoch check, so rollback can retract only this invocation's write.
publish_record_for_current_epoch() {  # record-path body-without-LF
  local record_path="$1" record_body="$2"
  local staged="${record_path}.stage-$$-${RANDOM:-0}"
  local prior="${record_path}.prior-$$-${RANDOM:-0}" had_prior=false prior_identity=""
  prompt_epoch_is_current || return 1
  if ! printf '%s\n' "$record_body" \
      | verdict_audit_write_exclusive_regular "$staged" 2>/dev/null; then
    return 1
  fi
  if ! prompt_epoch_is_current; then
    rm -f "$staged"
    return 1
  fi
  if [[ -e "$record_path" || -L "$record_path" ]]; then
    prior_identity="$(verdict_audit_path_identity "$record_path" 2>/dev/null)" || {
      rm -f "$staged"
      return 1
    }
    prompt_epoch_is_current || {
      rm -f "$staged"
      return 1
    }
    verdict_audit_rename_exact "$record_path" "$prior" 2>/dev/null || {
      rm -f "$staged"
      return 1
    }
    had_prior=true
    if ! verdict_audit_selected_identity_matches \
        "$prior" "$prior_identity" 2>/dev/null; then
      verdict_audit_restore_no_clobber "$prior" "$record_path" 2>/dev/null || true
      rm -f "$staged"
      return 1
    fi
    if ! prompt_epoch_is_current; then
      rm -f "$prior" 2>/dev/null || true
      rmdir "$prior" 2>/dev/null || true
      rm -f "$staged"
      return 1
    fi
  fi
  if ! verdict_audit_link_no_clobber "$staged" "$record_path" 2>/dev/null; then
    if [[ "$had_prior" == true ]]; then
      verdict_audit_restore_no_clobber "$prior" "$record_path" 2>/dev/null || true
    fi
    rm -f "$staged"
    return 1
  fi
  if ! prompt_epoch_is_current; then
    verdict_audit_unlink_if_same_inode "$record_path" "$staged" 2>/dev/null || true
    if [[ "$had_prior" == true ]]; then
      rm -f "$prior" 2>/dev/null || true
      rmdir "$prior" 2>/dev/null || true
    fi
    rm -f "$staged"
    return 1
  fi
  rm -f "$staged"
  if [[ "$had_prior" == true ]]; then
    rm -f "$prior" 2>/dev/null || true
    rmdir "$prior" 2>/dev/null || true
  fi
  return 0
}

discard_matching_json_generation() {  # json-path expected-generation
  local json_path="$1" expected="$2" quarantine snapshot json generation
  [[ -e "$json_path" || -L "$json_path" ]] || return 0
  quarantine="${json_path}.discard-$$-${RANDOM:-0}"
  verdict_audit_rename_exact "$json_path" "$quarantine" 2>/dev/null || return 1
  snapshot="$(verdict_audit_read_json_snapshot "$quarantine" 2>/dev/null)" \
    || snapshot=""
  json=""
  [[ "$snapshot" == *$'\n'* ]] && json="${snapshot#*$'\n'}"
  generation="$(printf '%s' "$json" | jq -rs '
    if length == 1 and (.[0] | type == "object")
       and (.[0].generation | type == "string")
    then .[0].generation else "" end
  ' 2>/dev/null || echo '')"
  if [[ "$generation" == "$expected" ]]; then
    rm -f "$quarantine"
    return 0
  fi
  verdict_audit_restore_no_clobber "$quarantine" "$json_path" 2>/dev/null || return 2
  return 1
}

ensure_verdict_request() {
  prompt_epoch_is_current || return 1
  if load_verdict_request; then
    if prompt_epoch_is_current; then
      return 0
    fi
    request_is_current=false
    return 1
  fi
  [[ "$session_scope" != "-" && -n "$FINAL_ID" ]] || return 0
  local deadline new_request_body existing_request_body invalid_identity
  audit_generation="$$-$(date +%s)-${RANDOM:-0}"
  auditor_verdict_file="${stable_verdict_file}.audit-${audit_generation}"
  verdict_file="$stable_verdict_file"
  deadline="$(( $(date +%s) + audit_lock_max_seconds ))"
  mkdir -p "$(dirname "$verdict_request_file")" 2>/dev/null || return 1
  prompt_epoch_is_current || return 1
  discard_path_for_current_epoch "$verdict_file" >/dev/null 2>&1 || true
  prompt_epoch_is_current || return 1
  if [[ -e "$verdict_request_file" || -L "$verdict_request_file" ]]; then
    if existing_request_body="$(verdict_audit_read_single_record \
        "$verdict_request_file" 2>/dev/null)"; then
      verdict_audit_remove_record_if_matches \
        "$verdict_request_file" "$existing_request_body" >/dev/null 2>&1 || return 1
    else
      # Invalid/FIFO/directory state cannot permanently suppress audit recovery. Rename
      # one exact pathname out of the publication slot, then remove only that selected
      # entry when it is a file/symlink or an empty directory.
      local invalid_request="${verdict_request_file}.invalid-$$-${RANDOM:-0}"
      invalid_identity="$(verdict_audit_path_identity \
        "$verdict_request_file" 2>/dev/null)" || return 1
      prompt_epoch_is_current || return 1
      verdict_audit_rename_exact \
        "$verdict_request_file" "$invalid_request" 2>/dev/null || return 1
      if ! verdict_audit_selected_identity_matches \
          "$invalid_request" "$invalid_identity" 2>/dev/null; then
        verdict_audit_restore_no_clobber \
          "$invalid_request" "$verdict_request_file" 2>/dev/null || true
        return 1
      fi
      rm -f "$invalid_request" 2>/dev/null || true
      rmdir "$invalid_request" 2>/dev/null || true
    fi
  fi
  prompt_epoch_is_current || return 1
  new_request_body="$audit_generation $deadline $FINAL_ID"
  if ! printf '%s\n' "$new_request_body" \
      | verdict_audit_write_exclusive_regular "$verdict_request_file" 2>/dev/null; then
    return 1
  fi
  verdict_request_body="$new_request_body"
  if ! prompt_epoch_is_current; then
    verdict_audit_remove_record_if_matches \
      "$verdict_request_file" "$verdict_request_body" >/dev/null 2>&1 || true
    request_is_current=false
    return 1
  fi
  request_is_current=true
}

write_payload_transcript() {
  local payload_body
  prompt_epoch_is_current || return 1
  mkdir -p "$(dirname "$payload_transcript_file")" 2>/dev/null || return 1
  payload_body="$(jq -nc --arg text "$last_assistant_message" \
    '{type:"assistant", source:"codex-stop-payload",
      message:{content:[{type:"text", text:$text}]}}')" || return 1
  publish_record_for_current_epoch "$payload_transcript_file" "$payload_body"
}

verdict_instruction() {
  local prior="" audit_transcript_path="$transcript_path" codex_auditor_task
  if ! ensure_verdict_request; then
    printf 'Verdict audit request could not be recorded at %s. Fix that state-write error before auditing.\n' \
      "$verdict_request_file"
    return 0
  fi
  if [[ "$FINAL_SOURCE" == "payload" \
     || ( -n "$last_assistant_message" \
          && ( -z "$transcript_path" || ! -r "$transcript_path" || ! -s "$transcript_path" ) ) ]]; then
    if write_payload_transcript; then
      audit_transcript_path="$payload_transcript_file"
    else
      printf 'preflight-verdict-check: could not persist the Stop payload for audit: %s\n' \
        "$payload_transcript_file" >&2
    fi
  fi
  [[ -r "$prev_verdict_file" ]] && prior="

A PRIOR audit of this same work FAILED; its findings are in ${prev_verdict_file}.
Re-check THOSE findings against what changed and carry forward the proof entries
whose evidence still holds, rather than re-deriving every claim from scratch. Still
read the WHOLE turn — narrowing applies to re-verification only, never to finding
claims, so anything the fix newly asserts is still caught."
  # The route list comes from .agents/lib/subagent.sh so this gate and the commit-push
  # gate cannot drift apart on how an auditor is spawned. Each host uses its own
  # built-in — Task() or collaboration.spawn_agent — and the headless runner is offered
  # only for callers with no agent runtime at all.
  #
  # Degrades rather than blocks when the library is missing. Unlike the commit-push
  # gate, this is a Stop hook: refusing here would deny turn-end forever with no usable
  # instruction attached, which is the meaningless-loop class this file's header exists
  # to eliminate. A turn that ends unaudited with a loud notice is recoverable; an agent
  # that can never finish a turn is not.
  # %q, not hand-placed quotes: transcript_path arrives from the hook payload, and a
  # path containing a quote would otherwise re-tokenize the command an agent is being
  # told to run. This hook never executes it — the reader might.
  local headless_command
  printf -v headless_command 'bash %q %q %q %q %q' \
    "$tooling_root/.agents/hooks/run-verdict-audit.sh" "$audit_transcript_path" \
    "$session_id" "$audit_generation" "$session_scope"
  codex_auditor_task="verdict_auditor_${audit_generation//-/_}"

  local lib="$tooling_root/.agents/lib/subagent.sh"
  if [[ -r "$lib" ]]; then
    # shellcheck source=../lib/subagent.sh
    source "$lib"
    subagent_instruction \
      --agent verdict-auditor \
      --root "$tooling_root" \
      --description 'verdict proof check' \
      --codex-task-name "$codex_auditor_task" \
      --codex-retry-existing \
      --artifact "$auditor_verdict_file" \
      --task "$(subagent_prompt verdict-task "$tooling_root" \
                  "transcript_path=${audit_transcript_path}" \
                  "verdict_file=${auditor_verdict_file}" \
                  "previous_verdict_file=${prev_verdict_file}" \
                  "audit_generation=${audit_generation}")" \
      --headless "$headless_command"
  else
    printf 'preflight-verdict-check: missing %s — emitting the headless route only\n' "$lib" >&2
    cat <<EOF
Audit before ending — run the audit SYNCHRONOUSLY (the dossier must exist before you
end):

  ${headless_command}

The AUDITOR — not you — writes ${auditor_verdict_file}; do not write it yourself.
EOF
  fi

  cat <<EOF

While waiting, retain the native auditor's handle. If a REAL user message is steered in
before it returns, cancel it immediately, revoke generation
${audit_generation}, discard any dossier from that abandoned audit, and handle the new
message. In Codex use
collaboration.interrupt_agent(target='${codex_auditor_task}'); in Claude Code cancel the
active Task. Do not wait for an audit whose question the user just superseded.

If you are pausing or asking the user something, have the auditor record IN_PROGRESS
with what remains; if a claim genuinely cannot be proven here, it can mark that proof
'blocked' with the residual risk. After the audit completes, deliver the user-facing answer again.
If the audit PASSes, repeat the blocked answer verbatim. If it FAILs, revise the answer to address the findings; the revised answer must be re-audited.
Do not substitute audit status or dossier metadata for that answer. Then end your turn again.${prior}
EOF
}

block_with_verdict_instruction() {  # reason-without-instruction
  local reason="$1" instruction
  prompt_epoch_is_current || allow
  instruction="$(verdict_instruction)"
  prompt_epoch_is_current || allow
  block "${reason}
${instruction}"
}
# ─────────────────────────────────────────────────────────────────────────────

# A parked FAIL is only useful to the NEXT audit of the SAME round. If nobody ever
# claimed it — the round was abandoned, the user changed topic, no re-audit ran — it must
# not be handed to an auditor judging unrelated work. That is the identical hazard the
# park-side age gate closes, one site over: gating only the write bounds staleness at
# park time, while this file is read on every later block. Left unexpired it manufactures
# findings about dead work, and since the auditor is told "a finding you cannot confirm as
# addressed stays a finding", those become a FAIL — re-entering the meaningless-loop class
# item 2 of this header exists to eliminate.
expire_stale_prev() {
  prompt_epoch_is_current || return 0
  [[ -e "$prev_verdict_file" || -L "$prev_verdict_file" ]] || return 0
  local parked_quarantine="${prev_verdict_file}.expire-$$-${RANDOM:-0}"
  local parked_identity=""
  local parked_snapshot="" parked_mtime="" parked_age=0
  parked_identity="$(verdict_audit_path_identity "$prev_verdict_file" 2>/dev/null)" \
    || return 0
  prompt_epoch_is_current || return 0
  verdict_audit_rename_exact \
    "$prev_verdict_file" "$parked_quarantine" 2>/dev/null || return 0
  if ! verdict_audit_selected_identity_matches \
      "$parked_quarantine" "$parked_identity" 2>/dev/null; then
    verdict_audit_restore_no_clobber \
      "$parked_quarantine" "$prev_verdict_file" 2>/dev/null || true
    return 0
  fi
  if ! prompt_epoch_is_current; then
    rm -f "$parked_quarantine" 2>/dev/null || true
    rmdir "$parked_quarantine" 2>/dev/null || true
    return 0
  fi
  if parked_snapshot="$(verdict_audit_read_json_snapshot \
      "$parked_quarantine" 2>/dev/null)" \
     && [[ "$parked_snapshot" == *$'\n'* ]]; then
    parked_mtime="${parked_snapshot%%$'\n'*}"
  fi
  if [[ "$parked_mtime" =~ ^[0-9]+$ ]]; then
    parked_age=$(( $(date +%s) - parked_mtime ))
  else
    parked_age=$(( max_age_seconds + 1 ))
  fi
  if (( parked_age >= 0 && parked_age <= max_age_seconds )) \
     && prompt_epoch_is_current; then
    # A concurrent gate may already have parked a newer FAIL at the stable name. In
    # that case the newer inode wins and only this selected older inode is discarded.
    if verdict_audit_link_no_clobber \
        "$parked_quarantine" "$prev_verdict_file" 2>/dev/null; then
      if prompt_epoch_is_current; then
        rm -f "$parked_quarantine"
        return 0
      fi
      verdict_audit_unlink_if_same_inode \
        "$prev_verdict_file" "$parked_quarantine" 2>/dev/null || true
    fi
  fi
  rm -f "$parked_quarantine"
  rmdir "$parked_quarantine" 2>/dev/null || true
  return 0
}
expire_stale_prev

# Resolve the exact turn before accepting any runtime artifact. A user steer may retain
# the harness turn id, while the content-derived FINAL_ID necessarily changes.
resolve_final_message
if [[ -z "$FINAL_TEXT" ]]; then
  if [[ "$transcript_had_content" == true ]]; then
    log_decision extract blind-allow
    allow_with_note "[verdict-gate] transcript has content but no assistant text after 2s → allowing UNJUDGED"
  else
    log_decision extract empty-allow
    allow
  fi
fi

# A session dossier has authority only while its request still names this exact turn and
# that generation has not been canceled. UserPromptSubmit revokes the request directly;
# INT/TERM has no prompt hook, so the runner publishes a generation-named tombstone. The
# Stop gate consumes that marker by retiring the exact request and dossier before issuing
# a fresh generation. Removing authority before the marker makes any later writer harmless.
request_is_current=false
if load_verdict_request true; then
  if [[ "$session_scope" != "-" ]]; then
    if verdict_audit_cancellation_exists "$audit_cancellation_file"; then
      log_decision cancellation discard-generation
      if consume_current_verdict_request >/dev/null 2>&1; then
        discard_matching_json_generation \
          "$verdict_file" "$audit_generation" >/dev/null 2>&1 || true
        discard_path_for_current_epoch "$last_uuid_file" >/dev/null 2>&1 || true
        discard_path_for_current_epoch "$payload_transcript_file" >/dev/null 2>&1 || true
        verdict_audit_clear_cancellation_records \
          "$audit_cancellation_file" >/dev/null 2>&1 || true
      fi
      request_is_current=false
    fi
  fi
elif [[ "$session_scope" != "-" ]]; then
  # Re-check before replacement in ensure_verdict_request(). A concurrent newer Stop
  # may have installed valid authority after this failed snapshot.
  :
fi

# ── Present dossier → validate the binding, then the verdict decides ─────────
# Rename first: every later consume/park/restore operation owns this exact inode. A
# canceled native auditor may publish a newer dossier at the stable path while the gate
# is deciding; that newer pathname is never opened, moved, or deleted by this decision.
dossier_observed_identity=""
if [[ "$request_is_current" == true \
   && ( -e "$verdict_file" || -L "$verdict_file" ) ]]; then
  dossier_observed_identity="$(verdict_audit_path_identity \
    "$verdict_file" 2>/dev/null)" || dossier_observed_identity=""
fi
if [[ "$request_is_current" == true && -n "$dossier_observed_identity" ]] \
   && start_decision_lease \
   && current_verdict_authority_matches; then
  dossier_quarantine="${verdict_file}.inspect-$$-${RANDOM:-0}"
  if verdict_audit_rename_exact "$verdict_file" "$dossier_quarantine" 2>/dev/null; then
    if ! verdict_audit_selected_identity_matches \
        "$dossier_quarantine" "$dossier_observed_identity" 2>/dev/null; then
      verdict_audit_restore_no_clobber \
        "$dossier_quarantine" "$verdict_file" 2>/dev/null || true
    else
    dossier_file_snapshot=""
    verdict_json=""
    v_mtime=0
    if dossier_file_snapshot="$(verdict_audit_read_json_snapshot \
        "$dossier_quarantine" 2>/dev/null)" \
       && [[ "$dossier_file_snapshot" == *$'\n'* ]]; then
      v_mtime="${dossier_file_snapshot%%$'\n'*}"
      verdict_json="${dossier_file_snapshot#*$'\n'}"
    fi
    verdict_document="$(printf '%s' "$verdict_json" \
      | verdict_audit_normalize_dossier 2>/dev/null || true)"
    verdict_snapshot="$verdict_document"
    verdict_json="$verdict_document"
    # Parse the immutable in-memory JSON snapshot. JSON preserves an empty detached-HEAD
    # branch; Bash IFS whitespace transport does not.
    v_branch="$(printf '%s' "$verdict_snapshot" | jq -r '.branch // ""' 2>/dev/null || true)"
    v_head="$(printf '%s' "$verdict_snapshot" | jq -r '.head // ""' 2>/dev/null || true)"
    v_tree="$(printf '%s' "$verdict_snapshot" | jq -r '.tree_hash // ""' 2>/dev/null || true)"
    v_verdict="$(printf '%s' "$verdict_snapshot" | jq -r '.verdict // ""' 2>/dev/null || true)"
    v_generation="$(printf '%s' "$verdict_snapshot" | jq -r '.generation // ""' 2>/dev/null || true)"
    now_epoch="$(date +%s)"
    [[ "$v_mtime" =~ ^[0-9]+$ ]] || v_mtime=0
    age=$(( now_epoch - v_mtime ))
    cur_tree="$(compute_tree_hash)"

    generation_matches=false
    if [[ "$session_scope" == "-" ]]; then
      [[ -z "$v_generation" || "$v_generation" == "legacy" ]] && generation_matches=true
    elif [[ "$v_generation" == "$audit_generation" ]]; then
      generation_matches=true
    fi

    if [[ "$generation_matches" != true ]]; then
      log_decision dossier discard-generation
      rm -f "$dossier_quarantine"
      rmdir "$dossier_quarantine" 2>/dev/null || true
    elif [[ "$v_branch" != "$branch" ]] || \
       [[ "$v_head" != "$head" ]] || \
       [[ "$v_tree" != "$cur_tree" ]] || \
       (( age < 0 || age > max_age_seconds )); then
      log_decision dossier discard-stale
      if ! consume_current_verdict_request; then
        rm -f "$dossier_quarantine"
        rmdir "$dossier_quarantine" 2>/dev/null || true
        [[ "$session_scope" == "-" ]] || request_is_current=false
      elif [[ "$v_verdict" == "FAIL" ]] \
         && prompt_epoch_is_current \
         && (( age >= 0 && age <= max_age_seconds )); then
        # Exact rename cannot reinterpret a directory destination. Retain the dossier's
        # original freshness timestamp: refreshing it here would let an old result gain a
        # second authority window. On failure preserve the quarantine and fail closed.
        if verdict_audit_link_no_clobber \
            "$dossier_quarantine" "$prev_verdict_file" 2>/dev/null; then
          if prompt_epoch_is_current; then
            rm -f "$dossier_quarantine"
          else
            verdict_audit_unlink_if_same_inode \
              "$prev_verdict_file" "$dossier_quarantine" 2>/dev/null || true
            rm -f "$dossier_quarantine"
          fi
        else
          rm -f "$dossier_quarantine"
        fi
        [[ "$session_scope" == "-" ]] || request_is_current=false
      else
        rm -f "$dossier_quarantine"
        rmdir "$dossier_quarantine" 2>/dev/null || true
        [[ "$session_scope" == "-" ]] || request_is_current=false
      fi
    else
      case "$v_verdict" in
        PASS)
          if consume_current_verdict_request; then
            log_decision dossier PASS-allow
            rm -f "$dossier_quarantine"
            discard_path_for_current_epoch "$prev_verdict_file" >/dev/null 2>&1 || true
            discard_path_for_current_epoch "$payload_transcript_file" >/dev/null 2>&1 || true
            rmdir "$dossier_quarantine" 2>/dev/null || true
            allow_with_note "[verdict-gate] dossier PASS → consumed, turn ends"
          fi
          log_decision dossier discard-revoked
          rm -f "$dossier_quarantine"
          rmdir "$dossier_quarantine" 2>/dev/null || true
          [[ "$session_scope" == "-" ]] || request_is_current=false
          ;;
        IN_PROGRESS)
          remaining="$(printf '%s' "$verdict_json" \
            | jq -r '.findings[]? | "  - " + .' 2>/dev/null || echo '')"
          if consume_current_verdict_request; then
            log_decision dossier IN_PROGRESS-allow
            rm -f "$dossier_quarantine"
            discard_path_for_current_epoch "$prev_verdict_file" >/dev/null 2>&1 || true
            discard_path_for_current_epoch "$payload_transcript_file" >/dev/null 2>&1 || true
            rmdir "$dossier_quarantine" 2>/dev/null || true
            allow_with_note "Verdict: IN_PROGRESS — proof deferred, work not yet complete:
${remaining}"
          fi
          log_decision dossier discard-revoked
          rm -f "$dossier_quarantine"
          rmdir "$dossier_quarantine" 2>/dev/null || true
          [[ "$session_scope" == "-" ]] || request_is_current=false
          ;;
        *)
          if current_verdict_authority_matches; then
            log_decision dossier FAIL-block
            findings="$(printf '%s' "$verdict_json" \
              | jq -r '.findings[]? | "  - " + .' 2>/dev/null || echo '')"
            if ! prompt_epoch_is_current; then
              :
            elif ! verdict_audit_restore_no_clobber \
                "$dossier_quarantine" "$verdict_file" 2>/dev/null; then
              printf 'preflight-verdict-check: retained FAIL could not be restored from %s\n' \
                "$dossier_quarantine" >&2
            elif prompt_epoch_is_current; then
              block_with_verdict_instruction "Verdict proof check FAILED on branch '${branch}':

${findings}

Address each finding, then re-audit. This block persists until a re-audit passes."
            else
              discard_matching_json_generation \
                "$verdict_file" "$audit_generation" >/dev/null 2>&1 || true
            fi
          fi
          log_decision dossier discard-revoked
          rm -f "$dossier_quarantine"
          rmdir "$dossier_quarantine" 2>/dev/null || true
          request_is_current=false
          ;;
      esac
    fi
    fi
  fi
fi
stop_decision_lease

# ── An audit is RUNNING and has not answered yet → allow, don't busy-wait ────
# Level-triggered gate, edge-triggered remedy: an audit takes minutes, a re-block cycle
# ~3s, so without this rung the agent is re-blocked for the whole duration of the fix
# the gate demanded. Observed: 108 blocks in one session, 39 in a 512s window.
# Only the bash runner takes the lock; a Task-launched auditor leaves nothing to observe
# and keeps today's behaviour.
audit_in_flight() {
  # Dossier absence is the runner's own proof it has not answered (it removes the file
  # before auditing). Redundant with the call site below the dossier branch, kept so the
  # predicate survives being hoisted.
  [[ "$request_is_current" == true && -r "$audit_lock_file" && ! -e "$verdict_file" ]] \
    || return 1
  local record_snapshot body pid deadline lock_pgid lock_scope owner_token lock_generation
  local lock_start_token extra actual_start_token
  local lock_mtime now
  audit_in_flight_pid=""
  record_snapshot="$(verdict_audit_read_single_record_snapshot \
    "$audit_lock_file" 2>/dev/null)" || return 1
  [[ "$record_snapshot" == *$'\n'* ]] || return 1
  lock_mtime="${record_snapshot%%$'\n'*}"
  body="${record_snapshot#*$'\n'}"
  # Here-string, not `read < file`: the body has no trailing newline, so `read` assigns
  # and still exits 1 at EOF, which with `|| return 1` silently disables this rung.
  read -r pid deadline lock_pgid lock_scope owner_token lock_generation \
    lock_start_token extra <<< "$body"
  # `0` excluded: `kill -0 0` signals the caller's own process group and succeeds, so a
  # truncated write would buy a blanket allow. $$ is never 0.
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  if [[ "$session_scope" != "-" ]]; then
    [[ "$lock_pgid" =~ ^(0|[1-9][0-9]*)$ \
       && "$lock_scope" == "$session_scope" \
       && "$owner_token" =~ ^[1-9][0-9]*-[0-9]+-[0-9]+$ \
       && "$lock_generation" == "$audit_generation" \
       && ( -z "$lock_start_token" \
            || "$lock_start_token" =~ ^cksum-[0-9]+-[0-9]+$ ) \
       && -z "$extra" ]] || return 1
  fi
  # Metadata and PID liveness are observations, not ownership: SIGKILL can strand the
  # former and PID reuse can satisfy the latter. The runner's stable kernel lease is the
  # authoritative proof. If Perl/flock is unavailable or errors, fail closed to triage.
  [[ -e "$audit_mutex_file" ]] || return 1
  command -v perl >/dev/null 2>&1 || return 1
  perl -MFcntl=:DEFAULT,:flock -MErrno=EAGAIN,EWOULDBLOCK -e '
    my $path = shift;
    $SIG{ALRM} = sub { exit 2 };
    alarm 1;
    exit 2 if lstat($path) && -l _;
    my $flags = O_RDWR | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags) or exit 2;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 2 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    my $locked = flock($fh, LOCK_EX | LOCK_NB);
    my $lock_errno = 0 + $!;
    @opened = stat($fh);
    @named = lstat($path);
    exit 2 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    exit 1 if $locked;
    alarm 0;
    $! = $lock_errno;
    exit(($!{EAGAIN} || $!{EWOULDBLOCK}) ? 0 : 2);
  ' "$audit_mutex_file" || return 1
  # A lock file alone proves nothing: the trap misses SIGKILL, orphaning the lock.
  kill -0 "$pid" 2>/dev/null || return 1
  if [[ -n "$lock_start_token" ]]; then
    actual_start_token="$(verdict_audit_process_start_token "$pid" 2>/dev/null)" \
      || return 1
    [[ "$actual_start_token" == "$lock_start_token" ]] || return 1
  fi
  now="$(date +%s)"
  [[ "$lock_mtime" =~ ^[0-9]+$ ]] || return 1
  (( lock_mtime <= now )) || return 1
  # Only the runner knows VERDICT_AUDITOR_TIMEOUT, so it writes the deadline; bounding
  # by max_age_seconds (dossier staleness) would expire the lock mid-run. Past the
  # ceiling is rejected, not capped — that lock is not what we think it is.
  if [[ -z "$deadline" ]]; then
    # No deadline field: a lock from an older runner. Fall back to the conservative
    # dossier-age bound rather than trusting an unbounded lease.
    (( now - lock_mtime >= 0 && now - lock_mtime <= max_age_seconds )) || return 1
  elif verdict_audit_epoch_is_bounded "$deadline"; then
    (( now <= deadline && deadline <= lock_mtime + audit_lock_max_seconds )) || return 1
  else
    # A present but malformed field is not legacy metadata. Fail closed before Bash can
    # wrap it or reinterpret a torn/hostile lease as a plausible live deadline.
    return 1
  fi
  audit_in_flight_pid="$pid"
  return 0
}
if audit_in_flight; then
  log_decision audit inflight-allow
  allow_with_note "[verdict-gate] audit in flight (pid ${audit_in_flight_pid}) → allow; its verdict gates the next turn"
fi

# ── No (usable) dossier → triage: does the turn assert a verdict? ───────────
# Flush-race guard: if the newest transcript message is the one already judged, the
# harness fired Stop before appending this turn's final text. Wait briefly for the
# fresh message; if none arrives there is nothing new to judge → allow. A message
# is never judged twice. A payload-only message has nothing to flush: only Codex's
# active-hook signal plus an identical content identity proves that call is recursive.
recorded_id="$(verdict_audit_read_single_record "$last_uuid_file" 2>/dev/null || echo '')"
if [[ -n "$FINAL_ID" && -n "$recorded_id" && "$FINAL_ID" == "$recorded_id" ]]; then
  if [[ "$FINAL_SOURCE" == "payload" && "$stop_hook_active" == "true" ]]; then
    log_decision race stale-allow
    allow_with_note "[verdict-gate] Stop payload unchanged during active hook → allow"
  fi
  if [[ "$FINAL_SOURCE" == "transcript" ]]; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      sleep 0.2
      extract_final_message
      [[ "$FINAL_ID" != "$recorded_id" ]] && break
    done
    [[ -z "$FINAL_TEXT" ]] && use_payload_message
    if [[ -z "$FINAL_TEXT" || "$FINAL_ID" == "$recorded_id" ]]; then
      log_decision race stale-allow
      allow_with_note "[verdict-gate] transcript unchanged since last judgment → allow"
    fi
  fi
fi

# `stripped` stays the pattern tiers' text; only the classifier gets citations.
stripped="$(printf '%s\n' "$FINAL_TEXT" | strip_code_static)"
stripped_cited="$(printf '%s\n' "$FINAL_TEXT" | strip_code_cited)"
prompt_epoch_is_current || allow
mkdir -p "$(dirname "$last_uuid_file")" 2>/dev/null || true
publish_record_for_current_epoch "$last_uuid_file" "$FINAL_ID" || allow # judged now

# ── Tier A (0ms): harness text asserts nothing → allow without a model call ──
# Placed AFTER the identity write so this allow path records what it judged, exactly
# like every other one.
if is_harness_noise "$stripped"; then
  log_decision harness noise-allow
  allow_with_note "[verdict-gate] harness/API text only, no assistant claim → allow"
fi

# ── Tier B (0ms): assertion-only claim → block without a model call ──────────
# Only the forms that report an observation (see assertion_patterns). Everything the
# classifier is better at judging falls through to tier C untouched.
asserted="$(printf '%s\n' "$stripped" | grep -Eio "$assertion_patterns" 2>/dev/null | head -n1 || true)"
if [[ -n "$asserted" ]]; then
  log_decision assertion match-block
  block_with_verdict_instruction "This turn asserts a verdict (\"${asserted}\") but no audited
dossier backs it. A claim stated as established needs proof attached."
fi

triage="$(should_audit "$stripped_cited")"
prompt_epoch_is_current || allow
if [[ "$triage" == "NO" ]]; then
  log_decision triage NO-allow
  allow_with_note "[verdict-gate] triage: NO — nothing taken on trust → allow"
fi
if [[ "$triage" == "YES" ]]; then
  log_decision triage YES-block
  block_with_verdict_instruction "This turn asserts a verdict (triage: YES) but no audited
dossier backs it. A claim stated as established needs proof attached."
fi

# Triage UNKNOWN (no model reachable) → deterministic pattern fallback.
matched="$(printf '%s\n' "$stripped" | grep -Eio "$verdict_patterns" 2>/dev/null | head -n1 || true)"
if [[ -z "$matched" ]]; then
  log_decision regex none-allow
  allow_with_note "[verdict-gate] triage unavailable, fallback patterns: no match → allow"
fi

log_decision regex match-block
block_with_verdict_instruction "This turn asserts a verdict (matched: \"${matched}\") but no audited
dossier backs it. A claim stated as established needs proof attached."
