# CI auto-fix escalation policy

The watcher reports events; this policy decides what an agent may change without
asking a human.
Notification is separate: report every comment and review, including bots.

## Auto-fix limits

- At most **2 auto-fix attempts per PR head**. After the second failed push,
  stop and report.
- **Never weaken** a test/assertion, add a skip, or widen an allow-list to pass CI.
- Never push automatically to `main`.
- Read the real failure first: `gh run view <run-id> --log-failed`.
- Reproduce with the smallest relevant local target before pushing.

## Escalate instead of acting

Ask the human if any condition holds:

1. There is no code signal: runner OOM, network/cache failure, timeout, or a job
   that never started. Report the run; do not edit or rerun it.
2. The fix touches a file **not already in this PR's diff**
   (`git diff --name-only origin/main...HEAD`).
3. The failing job is `e2e-local` or `e2e-cloud`.
4. The fix touches `.githooks/`, `.claude/`, `.codex/`, or `.agents/`.
5. A review asks for design/spec changes or depends on product intent.
6. Two attempts have already run on this PR head.
7. The same check returns a **different error** after a fix.

Otherwise fix, push, and report what changed and why.

## Review findings

First compare against the merge base and identify findings this PR introduced.
Fix introduced findings in this PR. Leave pre-existing findings unchanged and say
so in the PR. Never resolve an unfixed finding without explaining why. Treat bot
findings as claims: reproduce them before fixing or dismissing them.
