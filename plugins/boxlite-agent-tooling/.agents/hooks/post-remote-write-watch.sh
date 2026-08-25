#!/usr/bin/env bash
# PostToolUse hook: after a successful remote write, tell WHICHEVER agent is
# running to attach a consumer to the pr-watch event stream.
#
# This is the in-session *consumer* of the watch. The producer is universal —
# .githooks/pre-push starts .agents/watch/pr-watch.sh for every agent and every
# human. This hook bridges that stream into whichever session ran the remote
# write. Humans keep reading the log directly.
#
# Registered from hooks/hooks.json (PostToolUse, matcher "Bash") — Claude Code
# resolves it through the generic plugin.json, Codex through
# .codex-plugin/plugin.json: the vendor manifests register, .agents/ implements.
#
# The context names one attach route PER capability — Monitor for Claude Code, a
# background shell for Codex, a plain drain for anything else — and the agent
# self-selects. It deliberately does NOT sniff the host to emit only "its" route:
# the one gate that did (CODEX_SANDBOX) picked wrong on every host, because env
# vars report sandbox state, not which agent is running. See the post-mortem in
# .agents/lib/subagent.sh.
#
# Design notes
# ------------
# * Advisory, not `decision: "block"`. The push has already happened, so a block
#   cannot undo it — it can only nag. Worse, the auto-fix loop this arms itself
#   ends in a push, so a hard block here would deadlock that loop.
#
# * Matcher scope: PreToolUse/PostToolUse matchers are tool-name-only, so this
#   registers on the broad `Bash` matcher and does its own filtering, exiting 0
#   immediately on unrelated commands. Same shape as
#   .agents/hooks/preflight-commit-push.sh:55 and preflight-pr-review.sh:52 —
#   segment-anchored so `echo "git push"` does not match, newline-normalized so
#   a verb on line 2 does.
#
# * `git push` is matched, but so are the `gh pr` writes. The pre-push arm
#   already covers PR creation transitively (a push always precedes it), so the
#   gh cases exist to re-attach a Monitor in a session that pushed earlier, or
#   where the push happened outside this session.
#
# Tests: bash .agents/hooks/post-remote-write-watch.test.sh
set -euo pipefail

payload="$(cat)"
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"

normalized="${command//$'\n'/;}"
work="${normalized#"${normalized%%[![:space:]]*}"}"
if [[ "$work" =~ (^|[[:space:]]*(\&\&|\|\||\;|\||\&|\$\(|\(|\`)[[:space:]]*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*git[[:space:]]+push([[:space:]]|$) ]]; then
  :
elif [[ "$work" =~ (^|[[:space:]]*(\&\&|\|\||\;|\||\&|\$\(|\(|\`)[[:space:]]*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*gh[[:space:]]+pr[[:space:]]+(create|edit|ready|comment|review)([[:space:]]|$) ]]; then
  :
else
  exit 0
fi

[[ "${BOXLITE_PR_WATCH:-1}" == "0" ]] && exit 0

# tool_response is a string for some tools and an object for Bash; accept both
# rather than assuming a shape.
response="$(printf '%s' "$payload" \
  | jq -r 'if (.tool_response | type) == "string"
           then .tool_response
           else ((.tool_response.stdout // "") + "\n" + (.tool_response.stderr // ""))
           end' 2>/dev/null || echo '')"

# A failed push leaves nothing new to watch. PostToolUse never sees the exit
# code, so the decision has to come from git's own output.
#
# Match the whole `error:`/`fatal:` class, not a list of specific messages. A
# local pre-push hook that exits non-zero — this repo's own audit gate — prints
# ONLY `error: failed to push some refs`: no `fatal:`, no `[rejected]`. An
# earlier version enumerated messages, missed that one, and announced a blocked
# push as a successful remote write.
#
# Fails closed: over-matching costs an un-armed watch, under-matching reports a
# push that never happened.
failure_re='(^|[[:space:]])(fatal|error):|\[(remote )?rejected\]|Everything up-to-date|Permission denied'
if [[ "$response" =~ $failure_re ]]; then
  exit 0
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# The stream script and the escalation policy live in the TOOLING tree (this
# script's own plugin), never at the consumer's repo root — an installed
# consumer carries only .agent-tooling/ and the pinned cache under .git/. An
# earlier version addressed both as ${repo_root}/.agents/… , which exists in
# neither layout; the tests missed it by asserting bare filenames.
tooling_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || echo '')"
[[ -z "$branch" ]] && exit 0

slug="$(git -C "$repo_root" remote get-url origin 2>/dev/null \
        | sed -e 's#^git@[^:]*:##' -e 's#^[a-z+]*://[^/]*/##' -e 's#\.git$##')"

# Prefer the PR the command just produced; fall back to the branch's open PR.
pr_number="$(printf '%s' "$response" \
  | sed -n 's#.*/pull/\([0-9][0-9]*\).*#\1#p' | head -1)"
if [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
  pr_number="$(gh pr list --repo "$slug" --head "$branch" --state open \
                --json number --jq '.[0].number // empty' 2>/dev/null || echo '')"
fi

state_dir="$(git -C "$repo_root" rev-parse --git-path pr-watch 2>/dev/null || echo '')"
[[ -z "$state_dir" ]] && exit 0
[[ "$state_dir" != /* ]] && state_dir="$repo_root/$state_dir"
event_log="$state_dir/${branch//\//-}.jsonl"

pr_line="No open PR for '${branch}' yet — the watcher polls until one appears."
if [[ "$pr_number" =~ ^[0-9]+$ ]]; then
  pr_line="Watching PR #${pr_number} — https://github.com/${slug}/pull/${pr_number}"
fi

context="A remote write just succeeded on branch '${branch}'.
${pr_line}

.githooks/pre-push has armed the watcher. It appends one JSON event per line to
  ${event_log}
Kinds: check (one per check as it concludes), checks_done, conflict, comment,
review, review_comment, watch_start, watch_end. The stream ends itself at
watch_end.

Attach ONE consumer to it now, using WHICHEVER of these your harness provides —
do not attach a second one for this branch, and do not poll \`gh pr checks\` by
hand while it runs:

  Claude Code
    Monitor({
      command: 'bash ${tooling_root}/.agents/watch/pr-watch-stream.sh \"${event_log}\"',
      description: 'CI checks + PR activity on ${branch}',
      persistent: true,
    })

  Codex (any harness with background shells)
    Start in a BACKGROUND shell, and read its new output at every natural pause:
      bash ${tooling_root}/.agents/watch/pr-watch-stream.sh '${event_log}'
    It replays history, follows new events, and exits by itself at watch_end.

  No background primitive at all
    Drain what has landed so far before you end each turn:
      cat '${event_log}'

When an event arrives:
  * bucket 'fail' or 'cancel' -> read the real failure with
      gh run view <run-id> --log-failed
    then follow ${tooling_root}/.agents/watch/escalation-policy.md, which decides
    what you may fix unattended and what needs the human. Read it before editing.
  * kind 'conflict'           -> alert the human to the confirmed merge conflict,
    inspect both compared revisions, then follow the same escalation policy
    before changing history or resolving files.
  * a new comment or review    -> summarize it for the user; apply the same
    policy before acting on it.
  * alert the human — PushNotification on Claude Code, otherwise the FIRST line
    of your next reply — for a failing required check ('Lint (conclusion)',
    'Test (conclusion)'), every confirmed merge conflict, AND for every new
    comment,
    review, or inline review thread — bots included. Reviewers are why the
    watch exists; an unread bot finding is the failure mode it is meant to
    prevent. Routine passing checks stay silent.

If the user asked you not to watch this one, skip the consumer and say so."

jq -nc --arg c "$context" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $c
  }
}'
exit 0
