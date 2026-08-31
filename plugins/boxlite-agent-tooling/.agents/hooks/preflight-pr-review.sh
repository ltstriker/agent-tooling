#!/usr/bin/env bash
# PreToolUse hook: gate `gh pr create` / `gh pr edit` / `gh pr ready` on a
# user-TYPED acknowledgment that they have reviewed the PR.
#
# `gh pr create --draft` (and `-d`) is intentionally excluded — draft PRs are
# not yet requesting review, so no ack is required.
#
# Flow on a denied attempt:
#   1. Hook denies the gh tool call.
#   2. Reason text instructs the parent agent to obtain a TYPED confirmation
#      from the human (not a yes/no click) and persist it verbatim to
#      .agents/state/pr-reviewed.json bound to current branch + HEAD.
#   3. Parent retries -> hook validates the marker and allows on match.
#
# Wired in .claude/settings.json under hooks.PreToolUse with matcher "Bash".
#
# Design notes
# ------------
# * Matcher scope: same reason as preflight-commit-push.sh — PreToolUse matchers
#   are tool-name-only. This script does the actual `gh pr <subcmd>` filtering
#   and exits 0 immediately on unrelated bash calls.
#
# * Draft detection is conservative: only a draft flag immediately after
#   `gh pr create` is exempt. Later flag-like text may be title/body data, so an
#   ambiguous command stays gated rather than bypassing acknowledgment.
#
# * Two deterministic content checks run before the ack gate — a Conventional-
#   Commit `--title`, and a `--body` carrying the before/after call graph
#   (CONTRIBUTING.md #commit--pr-messages). Both only fire when the flag is
#   actually present and inspectable; neither consumes the ack marker.
#
# * One-shot consumption: the marker file is `rm -f`'d on the allow path so
#   each successive gh pr command forces a fresh ack, even at the same HEAD.
#   Mirrors the trade-off in preflight-commit-push.sh.
#
# Tests: bash .agents/hooks/preflight-pr-review.test.sh
set -euo pipefail

payload="$(cat)"
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"

# Parse simple commands without `eval`. Keeping quotes as lexical state makes a
# separator inside title/body data inert, while every real `&&`, `;`, newline,
# grouping boundary, or command substitution gets its own argv. Bash 3.2 has no
# associative arrays, so the small parallel arrays below are intentionally plain.
protected_count=0
protected_subcmds=()
protected_drafts=()
protected_title_count=0
protected_title_commands=()
protected_titles=()
protected_title_dynamics=()
protected_body_count=0
protected_body_commands=()
protected_body_kinds=()
protected_body_values=()
opaque_protected_count=0
parsed_simple_count=0
ambiguous_execution_context=0
has_redirection_syntax=0
recursive_scan_depth=0
literal_assignment_count=0
literal_assignment_names=()
literal_assignment_values=()
literal_assignment_dynamics=()
record_title() {
  protected_title_commands[$protected_title_count]="$1"
  protected_titles[$protected_title_count]="$2"
  protected_title_dynamics[$protected_title_count]="$3"
  protected_title_count=$((protected_title_count + 1))
}

record_body() {
  protected_body_commands[$protected_body_count]="$1"
  protected_body_kinds[$protected_body_count]="$2"
  protected_body_values[$protected_body_count]="$3"
  protected_body_count=$((protected_body_count + 1))
}

record_literal_assignment() {
  local assignment_word="$1" assignment_dynamic="$2"
  literal_assignment_names[$literal_assignment_count]="${assignment_word%%=*}"
  literal_assignment_values[$literal_assignment_count]="${assignment_word#*=}"
  literal_assignment_dynamics[$literal_assignment_count]="$assignment_dynamic"
  literal_assignment_count=$((literal_assignment_count + 1))
}

# Resolve only an already-literal word or an exact $name/${name} reference to
# the latest literal assignment seen in this shell source. This intentionally
# does not evaluate parameter operators, arrays, indirect expansion, or Bash
# scope; any richer spelling remains opaque.
resolved_shell_word=""
resolve_shell_word() { # argv index
  local word_index="$1" token variable_name="" assignment_index
  resolved_shell_word=""
  if (( shell_word_dynamics[$word_index] == 0 )); then
    resolved_shell_word="${shell_words[$word_index]}"
    return 0
  fi
  token="${shell_words[$word_index]}"
  if [[ "$token" =~ ^\$([A-Za-z_][A-Za-z0-9_]*)$ ]]; then
    variable_name="${BASH_REMATCH[1]}"
  elif [[ "$token" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
    variable_name="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  assignment_index=$((literal_assignment_count - 1))
  while (( assignment_index >= 0 )); do
    if [[ "${literal_assignment_names[$assignment_index]}" == "$variable_name" ]]; then
      (( literal_assignment_dynamics[$assignment_index] == 0 )) || return 1
      resolved_shell_word="${literal_assignment_values[$assignment_index]}"
      return 0
    fi
    assignment_index=$((assignment_index - 1))
  done
  return 1
}

resolved_protected_operation() { # argv start index
  local word_count="${#shell_words[@]}" word_index="$1" token
  (( word_index < word_count )) || return 1
  resolve_shell_word "$word_index" || return 1
  case "$resolved_shell_word" in
    gh|*/gh) ;;
    *) return 1 ;;
  esac
  word_index=$((word_index + 1))
  while (( word_index < word_count )); do
    resolve_shell_word "$word_index" || return 1
    token="$resolved_shell_word"
    case "$token" in
      --repo|--hostname|-R) word_index=$((word_index + 2)); continue ;;
      --repo=*|--hostname=*|-R?*) word_index=$((word_index + 1)); continue ;;
      --) word_index=$((word_index + 1)); break ;;
      *) break ;;
    esac
  done
  (( word_index + 1 < word_count )) || return 1
  resolve_shell_word "$word_index" || return 1
  [[ "$resolved_shell_word" == pr ]] || return 1
  resolve_shell_word "$((word_index + 1))" || return 1
  [[ "$resolved_shell_word" == create \
     || "$resolved_shell_word" == edit \
     || "$resolved_shell_word" == ready ]]
}

inspect_simple_command() {
  local word_count="${#shell_words[@]}" command_index=0 index token subcmd executable
  local command_slot draft=0 first_arg="" next_value="" next_quoted=0 next_dynamic=0
  local payload="" payload_index=0 payload_dynamic=0 wrapper="" option_flags=""
  local option_index=0 option_char="" option_needs_value=0
  (( word_count > 0 )) || return 0
  parsed_simple_count=$((parsed_simple_count + 1))

  # This is deliberately a narrow recognizer, not a Bash interpreter. A single
  # literal command may use assignment prefixes and command/exec/env. Reserved
  # control words are scanned far enough to find a protected operation, but the
  # surrounding execution context is never considered authorizable.
  while (( command_index < word_count )); do
    if [[ "${shell_words[$command_index]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      record_literal_assignment "${shell_words[$command_index]}" \
        "${shell_word_dynamics[$command_index]}"
      command_index=$((command_index + 1))
      continue
    fi
    if (( shell_word_quotes[$command_index] == 0 )); then
      case "${shell_words[$command_index]}" in
        if|then|elif|else|while|until|do|'!')
          ambiguous_execution_context=1
          command_index=$((command_index + 1))
          continue
          ;;
        for|select|case|function|done|fi|'esac')
          ambiguous_execution_context=1
          return 0
          ;;
        time)
          ambiguous_execution_context=1
          command_index=$((command_index + 1))
          while (( command_index < word_count )) \
             && [[ "${shell_words[$command_index]}" == -p ]]; do
            command_index=$((command_index + 1))
          done
          if (( command_index < word_count )) \
             && [[ "${shell_words[$command_index]}" == -- ]]; then
            command_index=$((command_index + 1))
          fi
          continue
          ;;
      esac
    fi
    break
  done

  (( command_index < word_count )) || return 0
  if (( shell_word_dynamics[$command_index] )); then
    if resolved_protected_operation "$command_index"; then
      opaque_protected_count=$((opaque_protected_count + 1))
    elif (( recursive_scan_depth > 0 )); then
      opaque_protected_count=$((opaque_protected_count + 1))
    elif (( command_index + 2 < word_count )) \
       && [[ "${shell_words[$((command_index + 1))]}" == pr ]] \
       && { [[ "${shell_words[$((command_index + 2))]}" == create \
              || "${shell_words[$((command_index + 2))]}" == edit \
              || "${shell_words[$((command_index + 2))]}" == ready ]] \
            || (( shell_word_dynamics[$((command_index + 2))] )); }; then
      opaque_protected_count=$((opaque_protected_count + 1))
    fi
    return 0
  fi

  # `builtin` can expose eval/exec/command without changing their literal argv
  # spelling. Inspect those targets, but never authorize the extra wrapper: it
  # stays an execution-ambiguous context even when the nested argv is literal.
  if [[ "${shell_words[$command_index]}" == builtin ]]; then
    ambiguous_execution_context=1
    wrapper="builtin"
    command_index=$((command_index + 1))
    (( command_index < word_count )) || return 0
    if (( shell_word_dynamics[$command_index] )); then
      opaque_protected_count=$((opaque_protected_count + 1))
      return 0
    fi
    case "${shell_words[$command_index]}" in
      eval|exec|command) ;;
      *) return 0 ;;
    esac
  fi

  # `alias name='...'` does not execute its payload at definition time, but a
  # later expansion can. Inspect literal definitions to discover the protected
  # site, then reject the compound alias context before selecting an ack.
  if [[ "${shell_words[$command_index]}" == alias ]]; then
    ambiguous_execution_context=1
    payload_index=$((command_index + 1))
    while (( payload_index < word_count )); do
      token="${shell_words[$payload_index]}"
      if [[ "$token" == *=* && ${shell_word_dynamics[$payload_index]} == 0 ]]; then
        payload="${token#*=}"
        recursive_scan_depth=$((recursive_scan_depth + 1))
        scan_command_fragment "$payload"
        recursive_scan_depth=$((recursive_scan_depth - 1))
      elif (( shell_word_dynamics[$payload_index] )); then
        opaque_protected_count=$((opaque_protected_count + 1))
      fi
      payload_index=$((payload_index + 1))
    done
    return 0
  fi

  # Literal eval and shell -c payloads are recursively recognized so a hidden
  # protected operation cannot pass through. They remain outside the supported
  # one-simple-command boundary and are denied if such an operation is found.
  if [[ "${shell_words[$command_index]}" == eval ]]; then
    ambiguous_execution_context=1
    payload_index=$((command_index + 1))
    while (( payload_index < word_count )); do
      (( shell_word_dynamics[$payload_index] == 0 )) || payload_dynamic=1
      [[ -z "$payload" ]] || payload+=" "
      payload+="${shell_words[$payload_index]}"
      payload_index=$((payload_index + 1))
    done
    if (( payload_dynamic )); then
      opaque_protected_count=$((opaque_protected_count + 1))
    elif [[ -n "$payload" ]]; then
      recursive_scan_depth=$((recursive_scan_depth + 1))
      scan_command_fragment "$payload"
      recursive_scan_depth=$((recursive_scan_depth - 1))
    fi
    return 0
  fi

  # Normalize only the direct, literal wrappers whose argv cardinality is
  # knowable without evaluating shell source.
  if [[ "${shell_words[$command_index]}" == command ]]; then
    wrapper="command"
    command_index=$((command_index + 1))
    while (( command_index < word_count )) \
       && [[ "${shell_words[$command_index]}" == -p ]]; do
      command_index=$((command_index + 1))
    done
    if (( command_index < word_count )) \
       && [[ "${shell_words[$command_index]}" == -- ]]; then
      command_index=$((command_index + 1))
    fi
  fi

  if (( command_index < word_count )) \
     && [[ "${shell_words[$command_index]}" == exec ]]; then
    wrapper="exec"
    command_index=$((command_index + 1))
    while (( command_index < word_count )); do
      token="${shell_words[$command_index]}"
      case "$token" in
        --) command_index=$((command_index + 1)); break ;;
        -?*)
          option_flags="${token#-}"
          [[ "$option_flags" =~ ^[cla]+$ ]] || break
          option_needs_value=0
          option_index=0
          while (( option_index < ${#option_flags} )); do
            option_char="${option_flags:$option_index:1}"
            [[ "$option_char" != a ]] || option_needs_value=1
            option_index=$((option_index + 1))
          done
          # Separate one-letter flags are the direct wrapper contract. A
          # cluster is recognized to expose the protected argv, then rejected
          # as outside that narrow authorization boundary.
          (( ${#option_flags} == 1 )) || ambiguous_execution_context=1
          command_index=$((command_index + 1))
          if (( option_needs_value )); then
            (( command_index < word_count )) || return 0
            command_index=$((command_index + 1))
          fi
          ;;
        *) break ;;
      esac
    done
  elif (( command_index < word_count )) \
       && [[ "${shell_words[$command_index]}" == env ]]; then
    wrapper="env"
    command_index=$((command_index + 1))
    while (( command_index < word_count )); do
      token="${shell_words[$command_index]}"
      if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        command_index=$((command_index + 1))
        continue
      fi
      case "$token" in
        --) command_index=$((command_index + 1)); break ;;
        -i|--ignore-environment) command_index=$((command_index + 1)) ;;
        -u|-C|-P|--unset|--chdir)
          (( command_index + 1 < word_count )) || return 0
          command_index=$((command_index + 2))
          ;;
        --unset=*|--chdir=*) command_index=$((command_index + 1)) ;;
        -S|--split-string|--split-string=*)
          opaque_protected_count=$((opaque_protected_count + 1))
          return 0
          ;;
        -*)
          # Unknown env options can change where argv begins. If the remaining
          # source names a protected command, fail closed instead of guessing.
          payload=""
          payload_index="$command_index"
          while (( payload_index < word_count )); do
            payload+=" ${shell_words[$payload_index]}"
            payload_index=$((payload_index + 1))
          done
          if [[ "$payload" == *" gh pr create"* \
             || "$payload" == *" gh pr edit"* \
             || "$payload" == *" gh pr ready"* ]]; then
            opaque_protected_count=$((opaque_protected_count + 1))
          fi
          return 0
          ;;
        *) break ;;
      esac
    done
  fi

  (( command_index < word_count )) || return 0
  if (( shell_word_dynamics[$command_index] )); then
    if resolved_protected_operation "$command_index"; then
      opaque_protected_count=$((opaque_protected_count + 1))
    elif [[ -n "$wrapper" ]] || (( recursive_scan_depth > 0 )); then
      opaque_protected_count=$((opaque_protected_count + 1))
    elif (( command_index + 2 < word_count )) \
       && [[ "${shell_words[$((command_index + 1))]}" == pr ]] \
       && { [[ "${shell_words[$((command_index + 2))]}" == create \
              || "${shell_words[$((command_index + 2))]}" == edit \
              || "${shell_words[$((command_index + 2))]}" == ready ]] \
            || (( shell_word_dynamics[$((command_index + 2))] )); }; then
      opaque_protected_count=$((opaque_protected_count + 1))
    fi
    return 0
  fi

  executable="${shell_words[$command_index]}"
  case "${executable##*/}" in
    bash|sh)
      if [[ -n "$pending_heredoc_delimiter" ]]; then
        pending_heredoc_executes_body=1
        ambiguous_execution_context=1
      fi
      payload_index=$((command_index + 1))
      while (( payload_index < word_count )); do
        token="${shell_words[$payload_index]}"
        case "$token" in
          --) return 0 ;;
          --rcfile|--init-file)
            payload_index=$((payload_index + 2))
            ;;
          --*) payload_index=$((payload_index + 1)) ;;
          -O|-o)
            payload_index=$((payload_index + 2))
            ;;
          -?*)
            option_flags="${token#-}"
            if [[ "$option_flags" == *c* ]]; then
              ambiguous_execution_context=1
              payload_index=$((payload_index + 1))
              if (( payload_index >= word_count \
                 || shell_word_dynamics[$payload_index] )); then
                opaque_protected_count=$((opaque_protected_count + 1))
              else
                payload="${shell_words[$payload_index]}"
                recursive_scan_depth=$((recursive_scan_depth + 1))
                scan_command_fragment "$payload"
                recursive_scan_depth=$((recursive_scan_depth - 1))
              fi
              return 0
            fi
            payload_index=$((payload_index + 1))
            ;;
          *) return 0 ;;
        esac
      done
      return 0
      ;;
  esac

  # A literal path selects the same executable boundary by its exact basename.
  # Do not broaden this to prefixes/suffixes: gh-helper and gh/tool are distinct
  # commands, while dynamic path construction was rejected above.
  case "$executable" in
    gh|*/gh) ;;
    *) return 0 ;;
  esac
  index=$((command_index + 1))
  while (( index < word_count )); do
    token="${shell_words[$index]}"
    case "$token" in
      --repo|--hostname|-R) index=$((index + 2)); continue ;;
      --repo=*|--hostname=*|-R?*) index=$((index + 1)); continue ;;
      --) index=$((index + 1)); break ;;
      *) break ;;
    esac
  done
  (( index < word_count )) || return 0
  if (( shell_word_dynamics[$index] )); then
    opaque_protected_count=$((opaque_protected_count + 1))
    return 0
  fi
  (( index + 1 < word_count )) || return 0
  [[ "${shell_words[$index]}" == pr ]] || return 0
  if (( shell_word_dynamics[$((index + 1))] )); then
    opaque_protected_count=$((opaque_protected_count + 1))
    return 0
  fi
  subcmd="${shell_words[$((index + 1))]}"
  [[ "$subcmd" == create || "$subcmd" == edit || "$subcmd" == ready ]] \
    || return 0

  command_slot="$protected_count"
  index=$((index + 2))
  (( index < word_count )) && first_arg="${shell_words[$index]}"
  if [[ "$subcmd" == create \
     && ( "$first_arg" == --draft || "$first_arg" == -d ) ]]; then
    draft=1
  fi
  protected_subcmds[$command_slot]="$subcmd"
  protected_drafts[$command_slot]="$draft"
  protected_count=$((protected_count + 1))
  (( draft == 0 )) || return 0

  while (( index < word_count )); do
    token="${shell_words[$index]}"
    next_value=""
    next_quoted=0
    if (( index + 1 < word_count )); then
      next_value="${shell_words[$((index + 1))]}"
      next_quoted="${shell_word_quotes[$((index + 1))]}"
      next_dynamic="${shell_word_dynamics[$((index + 1))]}"
    fi
    case "$token" in
      --title)
        # Preserve the existing inspectable-title contract: quoted long-form
        # values are deterministic; editor/short/unquoted forms stay with the
        # human acknowledgment.
        (( next_quoted == 0 )) \
          || record_title "$command_slot" "$next_value" "$next_dynamic"
        index=$((index + 2))
        continue
        ;;
      --title=*)
        (( ${shell_word_quotes[$index]} == 0 )) \
          || record_title "$command_slot" "${token#--title=}" \
            "${shell_word_dynamics[$index]}"
        ;;
      --body-file|-F)
        if (( next_dynamic )); then
          record_body "$command_slot" opaque ""
        else
          record_body "$command_slot" file "$next_value"
        fi
        index=$((index + 2))
        continue
        ;;
      --body-file=*)
        if (( shell_word_dynamics[$index] )); then
          record_body "$command_slot" opaque ""
        else
          record_body "$command_slot" file "${token#--body-file=}"
        fi
        ;;
      -F?*)
        if (( shell_word_dynamics[$index] )); then
          record_body "$command_slot" opaque ""
        else
          record_body "$command_slot" file "${token#-F}"
        fi
        ;;
      --body|-b)
        if (( next_quoted && next_dynamic == 0 )); then
          record_body "$command_slot" text "$next_value"
        else
          record_body "$command_slot" opaque ""
        fi
        index=$((index + 2))
        continue
        ;;
      --body=*)
        if (( ${shell_word_quotes[$index]} \
           && ${shell_word_dynamics[$index]} == 0 )); then
          record_body "$command_slot" text "${token#--body=}"
        else
          record_body "$command_slot" opaque ""
        fi
        ;;
      -b?*)
        if (( ${shell_word_quotes[$index]} \
           && ${shell_word_dynamics[$index]} == 0 )); then
          record_body "$command_slot" text "${token#-b}"
        else
          record_body "$command_slot" opaque ""
        fi
        ;;
      --fill|--fill-first|--fill-verbose|-f)
        record_body "$command_slot" opaque ""
        ;;
    esac
    index=$((index + 1))
  done
}

finish_shell_word() {
  local completed_word completed_quoted completed_escaped
  (( shell_word_started )) || return 0
  completed_word="$shell_word"
  completed_quoted="$shell_word_quoted"
  completed_escaped="$shell_word_escaped"
  shell_words[${#shell_words[@]}]="$shell_word"
  shell_word_quotes[${#shell_word_quotes[@]}]="$shell_word_quoted"
  shell_word_dynamics[${#shell_word_dynamics[@]}]="$shell_word_dynamic"
  shell_word=""
  shell_word_started=0
  shell_word_quoted=0
  shell_word_dynamic=0
  shell_word_escaped=0
  if (( heredoc_expect )); then
    pending_heredoc_delimiter="$completed_word"
    pending_heredoc_expands=$(( completed_quoted == 0 && completed_escaped == 0 ))
    heredoc_expect=0
  elif [[ "$completed_word" =~ ^[0-9]*\<\<(-?)(.*)$ \
       && "${BASH_REMATCH[2]}" != \<* ]]; then
    heredoc_strip_tabs=0
    [[ "${BASH_REMATCH[1]}" != - ]] || heredoc_strip_tabs=1
    if [[ -n "${BASH_REMATCH[2]}" ]]; then
      pending_heredoc_delimiter="${BASH_REMATCH[2]}"
      pending_heredoc_expands=$(( completed_quoted == 0 && completed_escaped == 0 ))
    else
      heredoc_expect=1
    fi
  fi
}

finish_simple_command() {
  finish_shell_word
  inspect_simple_command
  shell_words=()
  shell_word_quotes=()
  shell_word_dynamics=()
}

# `$()` source is executable even when its surrounding word is double quoted.
# Extract it without executing, mark the outer word uninspectable, and scan the
# nested source as its own command fragment. Single quotes and escaped dollars
# never call this path, so literal examples remain inert.
scan_dollar_substitution() {
  local sub_start=$((scan_index + 2)) sub_index="$((scan_index + 2))"
  local sub_depth=1 sub_quote="" sub_escaped=0 sub_comment=0 sub_char=""
  local sub_source=""
  while (( sub_index < scan_length )); do
    sub_char="${command_fragment:$sub_index:1}"
    if (( sub_comment )); then
      [[ "$sub_char" == $'\n' ]] && sub_comment=0
    elif (( sub_escaped )); then
      sub_escaped=0
    elif [[ "$sub_quote" == "'" ]]; then
      [[ "$sub_char" == "'" ]] && sub_quote=""
    elif [[ "$sub_quote" == '"' ]]; then
      case "$sub_char" in
        '"') sub_quote="" ;;
        \\)
          if (( sub_index + 1 < scan_length )); then
            case "${command_fragment:$((sub_index + 1)):1}" in
              '$'|'`'|'"'|\\|$'\n') sub_escaped=1 ;;
            esac
          fi
          ;;
      esac
    else
      case "$sub_char" in
        \\) sub_escaped=1 ;;
        "'"|'"') sub_quote="$sub_char" ;;
        '#') sub_comment=1 ;;
        '(') sub_depth=$((sub_depth + 1)) ;;
        ')')
          sub_depth=$((sub_depth - 1))
          (( sub_depth > 0 )) || break
          ;;
      esac
    fi
    sub_index=$((sub_index + 1))
  done
  sub_source="${command_fragment:$sub_start:$((sub_index - sub_start))}"
  shell_word_started=1
  shell_word_dynamic=1
  scan_command_fragment "$sub_source"
  if (( sub_index < scan_length )); then
    scan_index="$sub_index"
  else
    scan_index=$((scan_length - 1))
  fi
}

scan_backtick_substitution() {
  local sub_start=$((scan_index + 1)) sub_index=$((scan_index + 1))
  local sub_escaped=0 sub_char="" sub_source=""
  while (( sub_index < scan_length )); do
    sub_char="${command_fragment:$sub_index:1}"
    if (( sub_escaped )); then
      sub_escaped=0
    elif [[ "$sub_char" == \\ ]]; then
      sub_escaped=1
    elif [[ "$sub_char" == '`' ]]; then
      break
    fi
    sub_index=$((sub_index + 1))
  done
  sub_source="${command_fragment:$sub_start:$((sub_index - sub_start))}"
  shell_word_started=1
  shell_word_dynamic=1
  scan_command_fragment "$sub_source"
  if (( sub_index < scan_length )); then
    scan_index="$sub_index"
  else
    scan_index=$((scan_length - 1))
  fi
}

scan_heredoc_expansions() {
  local command_fragment="$1"
  local scan_index=0 scan_length="${#command_fragment}" scan_escaped=0
  local scan_char="" scan_next="" shell_word_started=0 shell_word_dynamic=0
  while (( scan_index < scan_length )); do
    scan_char="${command_fragment:$scan_index:1}"
    scan_next=""
    (( scan_index + 1 >= scan_length )) \
      || scan_next="${command_fragment:$((scan_index + 1)):1}"
    if (( scan_escaped )); then
      scan_escaped=0
    else
      case "$scan_char" in
        \\) scan_escaped=1 ;;
        '$')
          [[ "$scan_next" != '(' ]] || scan_dollar_substitution
          ;;
        '`') scan_backtick_substitution ;;
      esac
    fi
    scan_index=$((scan_index + 1))
  done
}

skip_pending_heredoc() {
  local line_start=$((scan_index + 1)) line_end line heredoc_body=""
  [[ -n "$pending_heredoc_delimiter" ]] || return 0
  while (( line_start <= scan_length )); do
    line_end="$line_start"
    while (( line_end < scan_length )) \
       && [[ "${command_fragment:$line_end:1}" != $'\n' ]]; do
      line_end=$((line_end + 1))
    done
    line="${command_fragment:$line_start:$((line_end - line_start))}"
    [[ "$line" != *$'\r' ]] || line="${line%$'\r'}"
    if (( heredoc_strip_tabs )); then
      line="${line#"${line%%[!$'\t']*}"}"
    fi
    if [[ "$line" == "$pending_heredoc_delimiter" ]]; then
      if (( pending_heredoc_executes_body )); then
        ambiguous_execution_context=1
        recursive_scan_depth=$((recursive_scan_depth + 1))
        scan_command_fragment "$heredoc_body"
        recursive_scan_depth=$((recursive_scan_depth - 1))
      elif (( pending_heredoc_expands )); then
        scan_heredoc_expansions "$heredoc_body"
      fi
      pending_heredoc_delimiter=""
      pending_heredoc_expands=0
      pending_heredoc_executes_body=0
      scan_index="$line_end"
      return 0
    fi
    heredoc_body+="$line"$'\n'
    (( line_end < scan_length )) || break
    line_start=$((line_end + 1))
  done
  if (( pending_heredoc_executes_body )); then
    ambiguous_execution_context=1
    recursive_scan_depth=$((recursive_scan_depth + 1))
    scan_command_fragment "$heredoc_body"
    recursive_scan_depth=$((recursive_scan_depth - 1))
  elif (( pending_heredoc_expands )); then
    scan_heredoc_expansions "$heredoc_body"
  fi
  scan_index=$((scan_length - 1))
}

scan_command_fragment() {
  local command_fragment="$1"
  local -a shell_words=() shell_word_quotes=() shell_word_dynamics=()
  local shell_word="" shell_word_started=0 shell_word_quoted=0 shell_word_dynamic=0
  local shell_word_escaped=0
  local scan_index=0 scan_length="${#command_fragment}" scan_quote=""
  local scan_escaped=0 scan_comment=0 scan_char="" scan_next=""
  local pending_heredoc_delimiter="" pending_heredoc_expands=0
  local pending_heredoc_executes_body=0
  local heredoc_expect=0 heredoc_strip_tabs=0
  while (( scan_index < scan_length )); do
    scan_char="${command_fragment:$scan_index:1}"
    scan_next=""
    (( scan_index + 1 >= scan_length )) \
      || scan_next="${command_fragment:$((scan_index + 1)):1}"
    if (( scan_comment )); then
      if [[ "$scan_char" == $'\n' ]]; then
        scan_comment=0
        finish_simple_command
        skip_pending_heredoc
      fi
      scan_index=$((scan_index + 1))
      continue
    fi
    if (( scan_escaped )); then
      # Bash removes an escaped physical newline before tokenization.
      if [[ "$scan_char" != $'\n' ]]; then
        shell_word+="$scan_char"
        shell_word_started=1
        shell_word_escaped=1
      fi
      scan_escaped=0
      scan_index=$((scan_index + 1))
      continue
    fi
    if [[ "$scan_quote" == "'" ]]; then
      if [[ "$scan_char" == "'" ]]; then
        scan_quote=""
      else
        shell_word+="$scan_char"
      fi
      shell_word_started=1
      scan_index=$((scan_index + 1))
      continue
    fi
    if [[ "$scan_quote" == ansi ]]; then
      if (( scan_escaped )); then
        shell_word+="$scan_char"
        scan_escaped=0
      elif [[ "$scan_char" == \\ ]]; then
        shell_word+="$scan_char"
        scan_escaped=1
      elif [[ "$scan_char" == "'" ]]; then
        scan_quote=""
      else
        shell_word+="$scan_char"
      fi
      shell_word_started=1
      scan_index=$((scan_index + 1))
      continue
    fi
    if [[ "$scan_quote" == '"' ]]; then
      case "$scan_char" in
        '"') scan_quote="" ;;
        \\)
          # Bash keeps a double-quoted backslash unless it precedes $, `, ",
          # backslash, or a physical newline. Preserve the resulting argv.
          case "$scan_next" in
            '$'|'`'|'"'|\\|$'\n') scan_escaped=1 ;;
            *) shell_word+=\\ ;;
          esac
          ;;
        '$')
          if [[ "$scan_next" == '(' ]]; then
            ambiguous_execution_context=1
            scan_dollar_substitution
          else
            shell_word+="$scan_char"
            [[ "$scan_next" =~ [A-Za-z0-9_\{\*@#\?\$!\-] ]] \
              && shell_word_dynamic=1
          fi
          ;;
        '`') ambiguous_execution_context=1; scan_backtick_substitution ;;
        *) shell_word+="$scan_char" ;;
      esac
      shell_word_started=1
      scan_index=$((scan_index + 1))
      continue
    fi
    case "$scan_char" in
      \\) scan_escaped=1 ;;
      '$')
        if [[ "$scan_next" == "'" ]]; then
          scan_quote=ansi
          shell_word_started=1
          shell_word_quoted=1
          shell_word_dynamic=1
          scan_index=$((scan_index + 2))
          continue
        elif [[ "$scan_next" == '(' ]]; then
          ambiguous_execution_context=1
          scan_dollar_substitution
        else
          shell_word+="$scan_char"
          shell_word_started=1
          [[ "$scan_next" =~ [A-Za-z0-9_\{\*@#\?\$!\-] ]] \
            && shell_word_dynamic=1
        fi
        ;;
      "'"|'"') scan_quote="$scan_char"; shell_word_started=1; shell_word_quoted=1 ;;
      '#')
        if (( shell_word_started == 0 )); then
          scan_comment=1
        else
          shell_word+="$scan_char"
        fi
        ;;
      ' '|$'\t'|$'\r') finish_shell_word ;;
      $'\n') finish_simple_command; skip_pending_heredoc ;;
      ';'|'&'|'|'|'('|')'|'{'|'}')
        ambiguous_execution_context=1
        finish_simple_command
        ;;
      '<'|'>')
        has_redirection_syntax=1
        shell_word+="$scan_char"
        shell_word_started=1
        ;;
      '`') ambiguous_execution_context=1; scan_backtick_substitution ;;
      *) shell_word+="$scan_char"; shell_word_started=1 ;;
    esac
    scan_index=$((scan_index + 1))
  done
  finish_simple_command
}

scan_command_fragment "$command"

(( protected_count > 0 || opaque_protected_count > 0 )) || exit 0
subcmd=""
protected_ack_count=0
protected_index=0
while (( protected_index < protected_count )); do
  if (( protected_drafts[$protected_index] == 0 )); then
    [[ -n "$subcmd" ]] || subcmd="${protected_subcmds[$protected_index]}"
    protected_ack_count=$((protected_ack_count + 1))
  fi
  protected_index=$((protected_index + 1))
done
# A draft exemption belongs only to that create segment. If every protected
# segment is a draft create there is nothing left to acknowledge.
if [[ -z "$subcmd" ]]; then
  (( opaque_protected_count > 0 )) || exit 0
  subcmd="operation"
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
project_dir="${CLAUDE_PROJECT_DIR:-$repo_root}"
tooling_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || echo '?')"
head="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo '?')"
marker_file="$project_dir/.agents/state/pr-reviewed.json"
max_age_seconds=600
state_lib="$tooling_root/.agents/lib/verdict-audit-state.sh"
if [[ ! -r "$state_lib" ]]; then
  printf 'preflight-pr-review: shared audit state library is unavailable.\n' >&2
  exit 2
fi
# shellcheck source=../lib/verdict-audit-state.sh
source "$state_lib"
marker_selection=""
marker_selected_identity=""

# If caller-controlled path/ref length pushes a diagnostic over the context budget,
# retain a complete recovery protocol without echoing those values again. A generic
# "read CONTRIBUTING" denial is fail-closed but unsatisfiable: neither host can infer
# the typed acknowledgment or marker shape needed for the retry.
bounded_ack_recovery="PR-review acknowledgment required; the detailed diagnostic exceeded 1200 bytes.
Use AskUserQuestion on Claude or request_user_input on Codex. Ask the human to choose
Other and type:
  reviewed: <one-line summary in their own words of what this PR changes>
Read the free-form Other text (Claude calls it notes). If it starts with 'reviewed: ',
write it verbatim to .agents/state/pr-reviewed.json under the project root as:
  { \"branch\": \"<current branch>\", \"head\": \"<current HEAD>\",
    \"message\": \"<verbatim Other text>\" }
Then retry the same gh command. Abort means no write or retry; Show me the diff means
show the current diff/log and re-ask. Invalid text means re-ask without writing.
Never infer the acknowledgment. Never fabricate, paraphrase, or pre-fill it."

cleanup_marker_selection() {
  if [[ -n "$marker_selection" && -n "$marker_selected_identity" ]]; then
    verdict_audit_unlink_if_identity \
      "$marker_selection" "$marker_selected_identity" 2>/dev/null || true
  fi
  marker_selection=""
  marker_selected_identity=""
}

deny() {
  local reason="$1" reason_bytes
  cleanup_marker_selection
  reason_bytes="$(LC_ALL=C printf '%s' "$reason" | wc -c | tr -d ' ')"
  if (( reason_bytes > 1200 )); then
    # Fail closed without feeding an unbounded command, branch, path, or marker
    # value back into the model context.
    reason="$bounded_ack_recovery"
  fi
  jq -nc --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# An expansion in the executable, `pr`, or protected-subcommand position can
# change the operation after static inspection. Never spend an acknowledgment
# on source whose runtime argv cannot be bound to the reviewed operation.
if (( opaque_protected_count > 0 )); then
  deny "A possible gh pr create/edit/ready operation is built dynamically in an executable position.
Use literal gh, pr, and subcommand words so the review gate can inspect and bind the exact operation."
fi

# One typed marker is a one-operation capability. A shell tool call containing
# multiple review-affecting operations cannot spend that capability atomically,
# so require separate calls before inspecting or consuming the marker.
if (( protected_ack_count > 1 )); then
  deny "Multiple non-draft gh pr operations were found in one shell command.
Run each create/edit/ready operation as a separate command so each consumes its
own typed PR-review acknowledgment. Nothing from this command was authorized."
fi

# Supported authorization boundary: exactly one top-level simple command with
# literal argv, optionally normalized through command/exec/env. Recursive shell
# source, control flow, aliases/functions, substitutions, and compound commands
# can change execution count or ordering; recognizing their protected site is
# only grounds to deny, never grounds to consume a marker.
if (( ambiguous_execution_context || parsed_simple_count != 1 )); then
  deny "A protected gh pr operation appears in compound, recursive, or execution-ambiguous shell source.
Run one direct literal gh pr create/edit/ready command per tool call (command,
exec, or env wrappers are supported). Nothing from this command was authorized."
fi

# A body-file check is a pre-execution snapshot. Redirection in the same shell
# command can truncate or replace that path after inspection but before gh reads
# it, so body-file operations with mutation-capable syntax are not authorizable.
body_index=0
while (( body_index < protected_body_count )); do
  if [[ "${protected_body_kinds[$body_index]}" == file ]] \
     && (( has_redirection_syntax )); then
    deny "A gh pr body file cannot be authorized from a command containing shell redirection.
Prepare the file in a separate tool call, then run one direct gh pr command that
only reads --body-file. Nothing from this command was authorized."
  fi
  body_index=$((body_index + 1))
done

# Deterministic title check: when a quoted --title is given, require a
# Conventional-Commit subject <=72 chars. (Short `-t` / unquoted forms aren't
# inspected; body quality / no-narrative is confirmed in the ack below.)
protected_fix_flags=()
protected_index=0
while (( protected_index < protected_count )); do
  protected_fix_flags[$protected_index]=0
  protected_index=$((protected_index + 1))
done
title_re='^(feat|fix|docs|refactor|test|chore|perf|ci|build)(\([^)]+\))?!?:[[:space:]].+'
title_index=0
while (( title_index < protected_title_count )); do
  pr_title="${protected_titles[$title_index]}"
  title_command="${protected_title_commands[$title_index]}"
  title_dynamic="${protected_title_dynamics[$title_index]}"
  if (( title_dynamic )) \
     || [[ -z "$pr_title" || ! "$pr_title" =~ $title_re ]] \
     || (( ${#pr_title} > 72 )); then
    deny "PR title must be a Conventional-Commit subject <=72 characters (got ${#pr_title}).
Use type(scope): summary; types: feat fix docs refactor test chore perf ci build.
Fix --title and retry. See CONTRIBUTING.md #commit--pr-messages."
  fi
  if [[ "$pr_title" =~ ^fix(\([^\)]+\))?!?: ]]; then
    protected_fix_flags[$title_command]=1
  fi
  title_index=$((title_index + 1))
done

# Deterministic body check: a supplied PR body must carry the before/after
# end-to-end call graph mandated by CONTRIBUTING.md #commit--pr-messages.
#
# Only inspected when its command segment actually supplies a body. `gh pr ready` and
# editor-driven `gh pr create` carry nothing to read, and the editor path opens
# .github/pull_request_template.md, which already holds the section.
body_index=0
while (( body_index < protected_body_count )); do
  body_command="${protected_body_commands[$body_index]}"
  body_kind="${protected_body_kinds[$body_index]}"
  body_value="${protected_body_values[$body_index]}"
  pr_body=""
  pr_title=""
  (( protected_fix_flags[$body_command] == 0 )) || pr_title="fix: inspected"
  if [[ "$body_kind" == file ]]; then
    body_snapshot="$(verdict_audit_read_regular_state \
      "$body_value" 65536 json 2>/dev/null)" || body_snapshot=""
    [[ "$body_snapshot" == *$'\n'* ]] && pr_body="${body_snapshot#*$'\n'}"
  elif [[ "$body_kind" == text ]]; then
    pr_body="$body_value"
  fi

  # Line-start anchors below: an extracted body begins mid-line, glued to the flag.
  pr_body=$'\n'"$pr_body"
  body_lc="$(tr '[:upper:]' '[:lower:]' <<<"$pr_body")"
  # Herestrings, not pipes: `grep -q` exits on first match and would SIGPIPE the
  # writer, which `set -o pipefail` would then read as a failed check.
  has_line() { grep -qE "$1" <<<"$body_lc"; }
  missing=""

  has_line '^[[:space:]]*#{2,}[[:space:]]*call[[:space:]]+graph[[:space:]]*$' \
    || missing+="
  - a '## Call graph' section"
  # Shared with the section extractor below, so the header shape can never
  # drift between "is there a Before label" and "where does Before end".
  before_re='^[[:space:]]*before([[:space:]]|:|$)'
  after_re='^[[:space:]]*after([[:space:]]|:|$)'
  has_line "$before_re" \
    || missing+="
  - a 'Before' graph"
  has_line "$after_re" \
    || missing+="
  - an 'After' graph"

  # Lines strictly between a graph's header and whichever comes first: the
  # other graph's header, or the next markdown heading. Rule order is
  # load-bearing: reset on a stop, then print, then set on the header — that
  # sequence is what keeps the header lines themselves out of the section, so a
  # marker on the `Before` line marks no hop.
  #
  # Only the heading stop is fence-aware. Graphs get drawn inside a ``` fence,
  # where a `## entry` line is drawing rather than structure, and honouring it
  # stranded every hop that followed. The graph labels are honoured fenced or
  # not, because CONTRIBUTING.md's own example wraps both labels and all their
  # hops in a single fence — gating the labels the same way left that example
  # extracting to nothing and denied for having no hops at all.
  section() {
    awk -v start_re="$1" -v stop_re="$2" '
      /^[[:space:]]*```/                        { fenced = !fenced }
      $0 ~ stop_re && in_section                { in_section = 0 }
      !fenced && /^[[:space:]]*##/ && in_section { in_section = 0 }
      in_section                                { print }
      $0 ~ start_re                             { in_section = 1 }
    ' <<<"$body_lc"
  }
  before_graph="$(section "$before_re" "$after_re")"
  after_graph="$(section "$after_re" "$before_re")"

  # Each graph needs a hop of its own, shaped like the documented
  # `fn_name (Type · path/file.ext:LOC)`. Matching a bare `file.ext:LOC` was
  # too loose — one occurs mid-sentence — so a paragraph mentioning a file in
  # passing counted as a graph.
  #
  # What it actually requires: a `(` to the left of the reference and a `)` to
  # the right. Not a balanced group, and neither side is stricter than the
  # other. Being permissive is deliberate — a Type half carries its own
  # parentheses in `(fn(u32) -> u32 · src/x.rs:5)`, and refusing to cross them
  # denied a hop conforming to CONTRIBUTING.md's documented shape. The cost is
  # that an unrelated parenthetical straddling the reference also satisfies it.
  #
  # So this only reaches "shaped like a hop". It cannot tell a real graph from
  # a fabricated one, and no pattern here could — that judgment is left to the
  # human on the typed `reviewed:` ack below.
  #
  # Per graph, not body-wide: a body-wide count lets a prose-only After ride
  # along on Before's hops, which is not an end-to-end before/after graph. It
  # is also what an unfilled template cannot fake — its labels are literal
  # text, but its hop lines are HTML comments.
  hop_re='\(.*[A-Za-z0-9_./-]+\.[A-Za-z]+:[0-9]+.*\)'
  before_hops="$(grep -cE "$hop_re" <<<"$before_graph" || true)"
  after_hops="$(grep -cE "$hop_re" <<<"$after_graph" || true)"
  # Reports what is checked — a parenthesised reference — rather than naming
  # parts (`fn_name`, `Type`) the pattern does not require; the canonical shape
  # is printed in full below.
  (( before_hops >= 1 && after_hops >= 1 )) \
    || missing+="
  - a hop line with a parenthesised 'path/file.ext:LOC' in each graph, shaped as below (found ${before_hops} in Before, ${after_hops} in After)"

  # Bug-fix extras — only decidable when --title was inspectable above.
  if [[ "$pr_title" =~ ^fix(\([^\)]+\))?!?: ]]; then
    # "Mark the faulty hop" is literal: the marker has to sit on a hop line
    # inside the Before graph. A `BUG:` loose in prose, or down in After, marks
    # nothing. The arrow is deliberately not required — `←`, `<-` and a bare
    # `BUG:` all read the same, and mandating one Unicode glyph is typing
    # friction, not signal. The word boundary keeps `debug:` from qualifying.
    marker_re='(^|[^[:alnum:]_])bug:'
    # Same line, either order: `hop … ← BUG: why` or `← BUG: why … hop`.
    marked_hop() {
      grep -qE "${hop_re}.*${marker_re}" <<<"$before_graph" ||
        grep -qE "${marker_re}.*${hop_re}" <<<"$before_graph"
    }
    marked_hop \
      || missing+="
  - fix: PR — '← BUG: <what goes wrong>' on a hop line inside the Before graph"
    has_line '(fixes|closes|resolves)[[:space:]]+#[0-9]+' \
      || missing+="
  - fix: PR — an issue link, 'Fixes #<n>'"
  fi

  if [[ -n "$missing" ]]; then
    deny "PR description needs the mandated before/after call graph.
Missing:${missing}

Required shape; one real changed hop per line:
  Before
    fn_name (Type, path/file.ext:LOC) <- BUG: what fails
  After
    fn_name (Type, path/file.ext:LOC) - new behavior
For fix titles, mark the faulty Before hop and add Fixes #<n>.
Use real symbols and current line numbers. Rewrite and retry; see CONTRIBUTING.md #commit--pr-messages."
  fi
  body_index=$((body_index + 1))
done

# The acknowledgment UX is repeated on every missing/stale/malformed-marker
# denial. Keep the typed `reviewed:` shape, Other/notes transport, marker binding,
# abort/diff branches, and anti-fabrication rule inside the 1200-byte reason cap.
# Do not interpolate the raw command or marker contents; either can be unbounded.
REQUIRED_MESSAGE_RE='^reviewed:[[:space:]]+[^[:space:]]'

ack_instruction="PR-review acknowledgment required for gh pr ${subcmd}; bind ${branch}@${head}.
Use the host's native input tool (AskUserQuestion on Claude; request_user_input on
Codex). Ask the human to confirm the PR template has no internal/AI narrative,
pasted logs, or secrets; they must choose 'Other' and type:
  reviewed: <one-line summary in their own words of what this PR changes>
Options: 'Abort' and 'Show me the diff'.
Read the free-form Other text from the tool result (Claude calls it notes); never
infer it from chat or an option selection.

If that text matches ${REQUIRED_MESSAGE_RE}, write it verbatim to
.agents/state/pr-reviewed.json under the project root as:
  { \"branch\": \"<bound branch>\", \"head\": \"<bound HEAD>\",
    \"message\": \"<verbatim notes>\" }
Then retry the same gh command. Abort means no write/retry. Show me the diff: run
git diff main...HEAD --stat and git log main..HEAD --oneline, then re-ask. Invalid
text: re-ask without writing/retrying.
Never infer the acknowledgment. Never fabricate, paraphrase, or pre-fill it."
# ─────────────────────────────────────────────────────────────────────────────

marker_selection="${marker_file}.inspect-$$-${RANDOM:-0}"
marker_selected_identity="$(verdict_audit_link_no_clobber_identity \
  "$marker_file" "$marker_selection" 2>/dev/null)" || marker_selected_identity=""
if [[ -z "$marker_selected_identity" ]]; then
  marker_selection=""
  deny "No current PR-review acknowledgment is on file.

${ack_instruction}"
fi

marker_snapshot="$(verdict_audit_read_regular_state \
  "$marker_selection" 8192 json 2>/dev/null)" || marker_snapshot=""
marker_mtime=""
marker_json=""
if [[ "$marker_snapshot" == *$'\n'* ]]; then
  marker_mtime="${marker_snapshot%%$'\n'*}"
  marker_json="${marker_snapshot#*$'\n'}"
fi
marker_document="$(printf '%s' "$marker_json" | jq -ecs '
  def exact_keys($wanted): (keys | sort) == ($wanted | sort);
  def bounded_line($bytes):
    type == "string" and utf8bytelength <= $bytes
    and (explode | all(. != 0 and . != 10 and . != 13));
  if length == 1 and (.[0] | type) == "object"
     and (.[0] | exact_keys(["branch", "head", "message"]))
     and (.[0].branch | bounded_line(4096))
     and (.[0].head | type == "string"
          and test("^[0-9a-f]{40}([0-9a-f]{24})?$|^\\?$"))
     and (.[0].message | bounded_line(1024))
  then .[0] else empty end
' 2>/dev/null || true)"
if [[ -z "$marker_document" || ! "$marker_mtime" =~ ^[0-9]+$ ]]; then
  deny "PR-review acknowledgment is malformed or exceeds its safety limits.
${ack_instruction}"
fi
marker_branch="$(printf '%s' "$marker_document" | jq -r '.branch')"
marker_head="$(printf '%s' "$marker_document" | jq -r '.head')"
marker_message="$(printf '%s' "$marker_document" | jq -r '.message')"

now_epoch="$(date +%s)"
age=$(( now_epoch - marker_mtime ))

if [[ "$marker_branch" != "$branch" ]] || \
   [[ "$marker_head" != "$head" ]] || \
   (( age < 0 || age > max_age_seconds )); then
  deny "PR-review acknowledgment is stale or not bound to current branch+HEAD (max age ${max_age_seconds}s).
${ack_instruction}"
fi

if [[ ! "$marker_message" =~ $REQUIRED_MESSAGE_RE ]]; then
  deny "PR-review acknowledgment is malformed; it must start with 'reviewed: '.
${ack_instruction}"
fi

# Marker is valid for this exact branch+HEAD. Consume it so the next
# gh pr create/edit/ready forces a fresh ack.
consume_status=0
verdict_audit_unlink_if_identity \
  "$marker_file" "$marker_selected_identity" 2>/dev/null || consume_status=$?
if (( consume_status != 0 )); then
  deny "The matching PR-review acknowledgment could not be consumed safely.
${ack_instruction}"
fi
cleanup_marker_selection
exit 0
