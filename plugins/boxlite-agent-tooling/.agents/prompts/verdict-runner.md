---
name: verdict-runner
used-by: .agents/hooks/run-verdict-audit.sh
placeholders: verdict_file, previous_verdict_file, audit_generation, transcript_path
description: >
  Fed on stdin to the synchronous verdict auditor owned by the Stop hook. It carries
  the proof standard and explicit generation-scoped dossier path needed by a bare CLI.
---

Audit the final turn in the session transcript — every assistant message since the
last real user message, not just the closing one.

Each claim the turn presents as established must have concrete, direct proof in the
evidence: the working-tree diff, the commands and their output in the transcript, or
cited files and logs. A claim backed only by guessing or indirect inference is NOT
proven. A turn that asserts nothing verifiable is a PASS.

Follow your procedure and write the dossier to {{verdict_file}}. Include
`"generation":"{{audit_generation}}"` exactly; the runner rejects any other generation.

transcript_path: {{transcript_path}}
previous_verdict_file: {{previous_verdict_file}}
audit_generation: {{audit_generation}}
