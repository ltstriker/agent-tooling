---
name: commit-push-task
used-by: .agents/hooks/preflight-commit-push.sh
placeholders: kind, branch
description: >
  Handed to the commit-push-auditor subagent when the gate denies a git commit or
  push. Short by design — the auditor's full procedure lives in
  .claude/agents/commit-push-auditor.md, and this only says which command to judge.
---

Audit the exact blocked Bash tool_input.command for this git {{kind}} on branch
{{branch}}. Copy the command from the tool input verbatim — do not paraphrase it,
reconstruct it from memory, or judge a cleaned-up version of it. A commit message
audited in paraphrase is not the message that gets committed.
