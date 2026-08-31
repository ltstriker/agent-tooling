---
name: adversarial-iteration
description: Iterate recurring or design review findings through reflection, repro, fix, and fresh review.
---

# Adversarial Iteration

Use this after implementation when review exposes a design failure rather than an
isolated typo. It is especially useful for two or more findings, recurring siblings of
an earlier fix, or “why did I miss this?” requests.

## Loop

```text
implement → [fresh agent: review → REFLECT → reproducer → fix → verify → handoff]
              ↑                                                   |
              └──────── next round until ZERO_FINDINGS ──────────┘
```

- Run review/fix rounds autonomously inside `/loop`; do not pause for
  `AskUserQuestion` or `ExitPlanMode`. When choices are comparable, mark one
  “Recommended,” choose it, and continue. The user may interrupt at any time.
- Do not commit during the loop. Accumulate changes and commit once after termination.
- Use a fresh general-purpose agent each round so it re-reads the changed files. If
  agents are unavailable, re-read every changed file and run the round inline.

## REFLECT before fixing

For each finding, state:

1. what was wrong;
2. which assumption went unverified and why it was missed;
3. which repository rule was violated;
4. which cheap check would have caught it.

Then name the shared failure class. Common classes include solving the named symptom
instead of the invariant, yes-manning a design, leaking ownership across layers,
assuming a generic fits every variant, and missing lifecycle cooperation.

Run all four checks before changing production code:

1. **Timeline:** draw interleavings for concurrent state and find check/act gaps.
2. **Upstream contract:** read the producer; do not infer semantics from a type name.
3. **Lifecycle:** trace initialization through teardown, including in-flight work and
   stop order.
4. **Variants:** enumerate every covered type’s destructor, serializer, and contract.

## Reproduce, plan, verify

- Write a system-level reproducer before the fix and observe it fail on unfixed code.
  A passing or helper-only test is not a reproducer.
- Plan from the REFLECT class, reproducer assertion, decisive cheap check, smallest
  satisfying primitive, and adjacent contracts needing coverage.
- Restore the full fix, observe the reproducer turn green, and run adjacent-contract
  tests. A recurring sibling means REFLECT was too shallow; return to it.

## Round handoff

Before another round:

1. Audit changed files for round narrative and scaffolding:
   `grep -rn 'round\|TODO.*round\|HACK\|FIXME\|debugging\|TEMP' <changed-files>`.
2. Return a compact summary containing findings, root-cause class, fixes, files,
   tests, and residual risk.
3. Read [references/round-agent-prompt.md](references/round-agent-prompt.md) completely,
   populate it with the round number, all prior summaries, and all changed files, then
   spawn a fresh **general-purpose** agent. Do not use `codex:rescue`; the round needs
   read/write/edit/shell capability.

## Termination

Stop only when all three hold:

1. the fresh round reports `ZERO_FINDINGS` after re-reading every changed file;
2. every finding has a green reproducer;
3. every adjacent-contract test identified by REFLECT passes.

Do not accept residual design risk merely because the fix became expensive; plan the
required architectural change as the next round.

Project commands: adversarial review `/codex:adversarial-review`; loop runner `/loop`
with dynamic pacing and no interval. Conversation history is the iteration audit trail.
