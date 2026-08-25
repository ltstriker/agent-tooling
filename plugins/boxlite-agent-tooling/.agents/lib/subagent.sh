#!/usr/bin/env bash
# Shared: tell WHICHEVER coding agent is running to spawn an independent subagent with
# its OWN built-in, instead of detecting the host and shelling out to a vendor CLI.
#
# Source it, don't run it:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/subagent.sh"
#
# Why this emits TEXT rather than invoking anything
# -------------------------------------------------
# A hook is a bash process. It cannot call Task(...) or collaboration.spawn_agent(...)
# — only the agent can. So the hook's whole job here is to NAME the routes and let the
# agent take the one it actually has. Both hosts ship a built-in for this:
#
#   Claude Code   Task(subagent_type=<plugin>:<agent>, ...)  scoped plugin name
#   Codex         collaboration.spawn_agent(task_name, message)   no spec parameter
#
# Shelling out to `claude -p` or `codex exec` from inside a live agent spawns a whole
# second process to do what the built-in does in-session, and it needs a second auth
# and a second sandbox decision. That path still exists for genuinely agent-less
# callers (git hooks, CI) — pass it as --headless — but it is the exception now, not
# the Codex route.
#
# Why there is no host detection here, and must not be
# ----------------------------------------------------
# Printing every route and letting the agent self-select is not a shortcut around
# detecting the host — it is the fix. The gate that DID sniff an env var to choose a
# route (`CODEX_SANDBOX` in preflight-commit-push.sh) picked wrong on every host,
# because the wiring that launched it forced that variable non-empty and the variable
# reports which sandbox is active rather than which agent is running. Capability is
# something the agent knows about itself and the environment cannot lie about, so
# routing on it makes that whole class of bug unreachable rather than patched.
#
# Spec delivery differs by host, so it is referenced rather than inlined
# ---------------------------------------------------------------------
# Claude Code registers plugin agents as <plugin>:<frontmatter-name>. Codex takes no
# spec parameter, so the procedure has to travel in `message`, and its task_name must
# use underscores rather than the spec filename's hyphens. The specs run to ~100-150
# lines and this text is injected on EVERY blocked attempt, so the Codex route cites
# the spec path and has the subagent read it. One canonical spec file, a short message,
# and no second copy in TOML to drift out of sync.
#
# A missing spec file is a packaging bug, not a runtime branch: this still emits the
# instruction, and subagent.test.sh asserts every referenced spec exists.

# Strip a spec's YAML frontmatter. The frontmatter is registration metadata — name,
# description, the tool allowlist, the model the Task path launches with. None of it
# is instruction, so none of it may reach a model as part of the procedure.
subagent_strip_frontmatter() {  # $1 = spec file
  awk 'BEGIN{fm=0} NR==1 && /^---$/{fm=1; next} fm==1 && /^---$/{fm=2; next} fm!=1' "$1"
}

# Where a named subagent's canonical spec lives. One location for both hosts: the
# .claude/ path is the storage location, not a statement about which agent may use it.
subagent_spec_path() {  # $1 = agent name, $2 = tooling root
  printf '%s/.claude/agents/%s.md\n' "$2" "$1"
}

# Load a prompt from .agents/prompts/<name>.md and fill in its {{placeholders}}.
#
#   subagent_prompt verdict-audit-task "$root" transcript_path="$p" branch="$b"
#
# Prompts live as Markdown rather than as shell string literals because that is what
# they are: documents someone edits, reviews in a diff, and reasons about without
# reading bash quoting around them. A prompt buried in a heredoc also silently inherits
# shell expansion rules — `$(...)` inside one is a command substitution, not text.
#
# Substitution is plain bash string replacement over an explicit key list. No eval and
# no envsubst: the values are branch names, file paths, and commit text, and a prompt
# is the last place to let an unreviewed `$(...)` become executable.
#
# Exit 3 when the template names a placeholder the caller supplied no value for. That
# is the failure worth catching loudly — a model handed the literal text "{{branch}}"
# will cheerfully treat it as a value and answer confidently about nothing.
subagent_prompt() {  # $1 = prompt name, $2 = tooling root, then key=value pairs
  local name="${1:-}" root="${2:-}"
  if [[ -z "$name" || -z "$root" ]]; then
    printf 'subagent_prompt: name and root are required\n' >&2
    return 2
  fi
  shift 2

  local file="$root/.agents/prompts/$name.md"
  if [[ ! -r "$file" ]]; then
    printf 'subagent_prompt: no such prompt: %s\n' "$file" >&2
    return 2
  fi

  local text pair key value supplied="" needed missing=""
  text="$(subagent_strip_frontmatter "$file")"

  for pair in "$@"; do
    supplied="$supplied ${pair%%=*}"
  done

  # Checked against the TEMPLATE, before any value is substituted in. Scanning the
  # finished text instead would read a {{ }} occurring inside a VALUE as an unfilled
  # placeholder — and one of these values is sanitized diff text, so any repository
  # with a Vue, Handlebars, Jinja, Mustache, or Go template in its change set would
  # fail its own commit audit citing a placeholder nobody wrote.
  needed="$(printf '%s' "$text" | grep -o '{{[A-Za-z_][A-Za-z0-9_]*}}' | tr -d '{}' | sort -u)"
  for key in $needed; do
    case " $supplied " in
      *" $key "*) ;;
      *) missing="$missing {{$key}}" ;;
    esac
  done
  if [[ -n "$missing" ]]; then
    printf 'subagent_prompt: no value supplied for placeholder(s) in %s:%s\n' "$name" "$missing" >&2
    return 3
  fi

  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    text="${text//\{\{$key\}\}/$value}"
  done

  printf '%s\n' "$text"
}

# Print the block a gate puts in its deny reason.
#
#   subagent_instruction --agent commit-push-auditor --root "$tooling_root" \
#                        --task "$task" [--description D] [--artifact F] [--headless CMD]
#
# Exit 2 on a usage error, so a miswired caller fails loudly in tests rather than
# silently emitting an instruction that names nothing.
subagent_instruction() {
  local agent="" root="" task="" description="" artifact="" headless=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)       agent="${2:-}";       shift 2 ;;
      --root)        root="${2:-}";        shift 2 ;;
      --task)        task="${2:-}";        shift 2 ;;
      --description) description="${2:-}"; shift 2 ;;
      --artifact)    artifact="${2:-}";    shift 2 ;;
      --headless)    headless="${2:-}";    shift 2 ;;
      *) printf 'subagent_instruction: unknown option: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  if [[ -z "$agent" || -z "$root" || -z "$task" ]]; then
    printf 'subagent_instruction: --agent, --root and --task are required\n' >&2
    return 2
  fi
  [[ -n "$description" ]] || description="$agent"

  local spec claude_agent codex_task_name
  spec="$(subagent_spec_path "$agent" "$root")"
  claude_agent="boxlite-agent-tooling:$agent"
  codex_task_name="${agent//-/_}"

  # SYNCHRONOUSLY is load-bearing and stated in both routes: a backgrounded audit's
  # completion event is what produced the #892 re-block loop, because the turn ended
  # before the artifact landed and the gate fired again on the way out.
  printf 'Spawn the %s subagent now, SYNCHRONOUSLY — its result must exist before you\ncontinue. Use WHICHEVER of these your harness provides:\n\n' "$agent"

  printf '  Claude Code\n'
  printf "    Task(subagent_type='%s',\n" "$claude_agent"
  printf "         description='%s',\n" "$description"
  printf "         prompt='%s')\n" "$task"
  printf '    run_in_background: false\n\n'

  printf '  Codex\n'
  printf '    collaboration.spawn_agent(\n'
  printf "      task_name='%s',\n" "$codex_task_name"
  printf "      message='Read %s and follow that procedure\n" "$spec"
  printf "               exactly. Then: %s')\n\n" "$task"

  if [[ -n "$headless" ]]; then
    printf '  No agent runtime (git hook, CI, plain shell)\n'
    printf '    %s\n\n' "$headless"
  fi

  if [[ -n "$artifact" ]]; then
    printf 'The SUBAGENT — not you — writes %s. Do not write or hand-edit it\n' "$artifact"
    printf 'yourself; a verdict you wrote about your own work proves nothing.\n'
  fi
}
