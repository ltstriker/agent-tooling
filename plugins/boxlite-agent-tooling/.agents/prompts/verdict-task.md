---
name: verdict-task
used-by: .agents/hooks/preflight-verdict-check.sh
placeholders: transcript_path
description: >
  Handed to the verdict-auditor subagent when a turn asserts a conclusion the reader
  would have to take on trust. The auditor's full procedure lives in
  .claude/agents/verdict-auditor.md; this states the scope and the standard of proof.
---

Audit my final turn — every assistant message since the last real user message, not
just the closing one. A finding asserted mid-turn cannot hide behind a later "let me
check X".

Each claim the turn presents as established must have concrete, direct proof in the
evidence: the working-tree diff, the commands and their output in the transcript, or
cited files and logs. A claim backed only by guessing or by indirect inference is NOT
proven — plausibility is not evidence, and neither is a claim that merely went
unchallenged.

A turn that asserts nothing verifiable is a PASS. Questions, narration of work in
progress, and plain conversation are not claims.

transcript_path: {{transcript_path}}
