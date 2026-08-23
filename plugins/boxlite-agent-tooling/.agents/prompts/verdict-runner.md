---
name: verdict-runner
used-by: .agents/hooks/run-verdict-audit.sh
placeholders: verdict_file, transcript_path
description: >
  Fed on stdin to the headless verdict auditor — the runner used when no agent
  runtime is present to spawn a subagent. Same standard of proof as verdict-task.md,
  plus the write target, because nothing else tells a bare CLI where the dossier goes.
---

Audit the final turn in the session transcript — every assistant message since the
last real user message, not just the closing one.

Each claim the turn presents as established must have concrete, direct proof in the
evidence: the working-tree diff, the commands and their output in the transcript, or
cited files and logs. A claim backed only by guessing or indirect inference is NOT
proven. A turn that asserts nothing verifiable is a PASS.

Follow your procedure and write the dossier to {{verdict_file}}.

transcript_path: {{transcript_path}}
