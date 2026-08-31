---
name: boxlite-diagrams
description: Create source-grounded BoxLite architecture, sequence, or call-graph diagrams and validate them.
---

# BoxLite Diagrams

Produce the smallest source-grounded view set that answers the question. Evidence and
visual composition are separate gates; pass both.

## Route the request

1. Resolve the repository root, revision(s), subject, reader, and requested output
   location.
2. Search maintained diagrams before drawing:
   ```bash
   rg -n '^## .*Architecture|^```mermaid|flowchart|sequenceDiagram' \
     README.md apps docs .github
   ```
   Reuse the nearest useful composition, but verify drift-prone content against current
   source and IaC.
3. Choose only views that answer distinct questions:

   | Need | Default |
   | --- | --- |
   | deployment, topology, boundaries, overview, rendered picture | architecture |
   | order, retries, concurrency, callbacks, failure | sequence |
   | source mechanics or function path | ASCII call graph; add sequence only if time matters |
   | issue or before/after change | smallest unambiguous set |
   | named views | exactly those views |

4. For architecture, deployment, topology, overview, or rendered-picture work, read
   [references/architecture-composition.md](references/architecture-composition.md)
   completely before authoring.
5. Before writing any artifact, read
   [references/output-contract.md](references/output-contract.md) completely. Treat
   [references/evidence.schema.json](references/evidence.schema.json) and the validator
   as the format authority; they cover IDs, document sections, boundaries, source
   fields, evidence, membership, annotations, and allowed Mermaid syntax.
6. If an issue or PR is named, read it with `gh` and resolve its base/head revisions.

Do not edit production code for a diagram-only request. Save artifacts in the
repository only when the user explicitly asks.

## Build and prove

1. Select evidence-backed states:
   - overview: `Current`;
   - unimplemented issue: `Current`, `Expected (proposed)`;
   - PR, commit, branch, or working-tree change: `Before`, `After`.
2. Read only the source, IaC, tests, and docs needed at the selected altitude. Cite the
   exact revision, repository-relative path, inclusive lines, symbol, and narrow tokens.
   A deleted hop uses the base revision; an added hop uses the head. Never infer calls
   from compatible names or invent future symbols; proposed behavior uses issue
   evidence and stops at the last real boundary.
3. Create `diagram.md` and `evidence.json` in a temporary task directory. Declare the
   selected `views`, stable lowercase snake-case IDs, every parsed node/edge, immediate
   boundary membership, and architecture-zone `scope`. Reuse IDs across views/states.
4. Attach annotations to the exact affected node or edge: `ISSUE`, `BUG`, `FIX`,
   `PROPOSED`, `ADDED`, `CHANGED`, or `REMOVED`. A faulty call-graph hop carries
   `← BUG: <description>` in `Current` or `Before`; bug-fix output ends with
   `Fixes #<number>`.
5. Run the bundled validator. Read `validation.json` and correct failures, but stop
   after three failed attempts and return the report rather than an unverified diagram.
6. Open every generated PNG at normal fit-to-page size. Fix clipped labels, overlaps,
   false containment or direction, broken routing, scattered groups, poor contrast, or
   unreadable density, then validate and render again. Source inspection is not visual
   QA; explicitly state that the rendered image was inspected.
7. Use the repository’s verdict-auditor workflow before presenting architectural
   conclusions.

## Architecture invariants

For hosted cloud, start from `apps/infra/docs/deployment.md#architecture`. “Entire
deployment” means complete coverage at one altitude: users/SDKs, external dependencies,
ingress, ownership/trust boundaries, compute and box execution, durable state, telemetry,
and the main request/control/data/image paths—not every cloud resource.

Model ownership with nested boundaries, not arrows. When current source confirms it,
preserve:

`Runner fleet → EC2 instance × N → Runner daemon → embedded BoxLite runtime → box microVMs`

Declare every immediate membership in `evidence.json`. Assign each architecture node to
one contiguous `external`, `edge`, `compute`, `execution`, `state`, or `observability`
zone. A zone boundary declares matching `scope` evidence and the exact `scope_` house
palette class; nodes and purely physical boundaries stay unstyled. Meaning remains in
text, and the palette must remain legible on light/dark hosts. The architecture
composition reference owns the complete placement, palette, layout, and QA rules.

## Validate

```bash
python3 .agents/skills/boxlite-diagrams/scripts/validate_diagrams.py \
  --repo "$(git rev-parse --show-toplevel)" \
  --document "$TASK_DIR/diagram.md" \
  --evidence "$TASK_DIR/evidence.json" \
  --report "$TASK_DIR/validation.json"
```

Exit `0` means deterministic checks passed, `1` means invalid input, and `2` means a
required tool is unavailable. The validator emits `.mmd`, `.svg`, and `.png` using the
pinned Mermaid renderer. Mechanical success proves renderability and traceability, not
composition or architectural completeness.

## Respond

Lead with the requested view or rendered picture. Keep `Before` and `After` adjacent.
For code paths, show the ASCII call graph and one `Key:` line first. End with a compact
evidence summary, visual-QA statement, and passing report path when files were requested.
