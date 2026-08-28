#!/usr/bin/env bash
# Shared validation and logging for prompt-scoped auditor overrides.
# Source this file; it performs no work on load.

auditor_override_repo_identity() {  # canonical-repo
  local canonical
  canonical="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  printf '%s' "$canonical" | git -C "$canonical" hash-object --stdin
}

auditor_override_control_dir() {  # repo
  printf '%s/.agents/state/auditor-control' "$1"
}

auditor_override_grant_path() {  # repo session-scope
  printf '%s/grant.%s.json' "$(auditor_override_control_dir "$1")" "$2"
}

auditor_override_load_valid_grant() {  # repo session-scope prompt-epoch
  local repo="$1" scope="$2" epoch="$3" grant snapshot json now repo_id
  local created expires record_scope record_epoch record_repo nonce_hash reason_hash current_epoch
  grant="$(auditor_override_grant_path "$repo" "$scope")"
  [[ -r "$grant" && "$scope" != "-" && -n "$epoch" ]] || return 1

  # Reuse the verdict state reader when available: it rejects symlinks, FIFOs,
  # replacements, oversized files, and NUL before jq sees shared runtime state.
  if declare -F verdict_audit_read_json_snapshot >/dev/null 2>&1; then
    snapshot="$(verdict_audit_read_json_snapshot "$grant" 2>/dev/null)" || return 1
    [[ "$snapshot" == *$'\n'* ]] || return 1
    json="${snapshot#*$'\n'}"
  else
    [[ ! -L "$grant" && -f "$grant" ]] || return 1
    json="$(cat "$grant")" || return 1
  fi

  created="$(printf '%s' "$json" | jq -r '.created_at // ""' 2>/dev/null)"
  expires="$(printf '%s' "$json" | jq -r '.expires_at // ""' 2>/dev/null)"
  record_scope="$(printf '%s' "$json" | jq -r '.session_scope // ""' 2>/dev/null)"
  record_epoch="$(printf '%s' "$json" | jq -r '.prompt_epoch // ""' 2>/dev/null)"
  record_repo="$(printf '%s' "$json" | jq -r '.repo_hash // ""' 2>/dev/null)"
  nonce_hash="$(printf '%s' "$json" | jq -r '.nonce_hash // ""' 2>/dev/null)"
  reason_hash="$(printf '%s' "$json" | jq -r '.reason_hash // ""' 2>/dev/null)"
  repo_id="$(auditor_override_repo_identity "$repo" 2>/dev/null)" || return 1
  current_epoch="$(verdict_audit_read_single_record \
    "$repo/.agents/state/verdict-prompt-epoch.$scope" 2>/dev/null)" || return 1
  now="$(date +%s)"

  [[ "$created" =~ ^[1-9][0-9]*$ && "$expires" =~ ^[1-9][0-9]*$ \
     && "$record_scope" == "$scope" && "$record_epoch" == "$epoch" \
     && "$current_epoch" == "$epoch" \
     && "$record_repo" == "$repo_id" \
     && "$nonce_hash" =~ ^[0-9a-f]{64}$ && "$reason_hash" =~ ^[0-9a-f]{64}$ ]] \
    || return 1
  (( created <= now && now <= expires && expires <= created + 3600 )) || return 1

  auditor_override_nonce_hash="$nonce_hash"
  auditor_override_reason_hash="$reason_hash"
  return 0
}

auditor_override_log_use() {  # repo scope boundary context-hash [subject-hash]
  local repo="$1" scope="$2" boundary="$3" context_hash="$4" subject_hash="${5:--}"
  local log line
  [[ "$boundary" =~ ^[a-z0-9-]+$ \
     && "$context_hash" =~ ^[0-9a-f]{64}$ \
     && ( "$subject_hash" == "-" || "$subject_hash" =~ ^[0-9a-f]{64}$ ) ]] || return 1
  log="$(auditor_override_control_dir "$repo")/uses.$scope.log"
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 1
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) OVERRIDDEN boundary=$boundary context=$context_hash subject=$subject_hash nonce=${auditor_override_nonce_hash:-unknown} reason=${auditor_override_reason_hash:-unknown}"
  if declare -F verdict_audit_append_log_line >/dev/null 2>&1; then
    verdict_audit_append_log_line "$log" "$line"
  else
    printf '%s\n' "$line" >> "$log"
  fi
}
