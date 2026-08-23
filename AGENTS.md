# Agent Tooling Development

- Keep reusable implementation in `plugins/boxlite-agent-tooling/`.
- Keep consumer manifests declarative and free of secrets.
- Preserve fail-closed validation: invalid profiles and missing dependencies
  must write a clear error to stderr and exit nonzero.
- Pin consumer installations to a full commit SHA and update pins by pull
  request.
- Validate every manifest before release. Three marketplaces —
  `.agents/plugins/marketplace.json` (Codex), `.claude-plugin/marketplace.json`,
  `.github/plugin/marketplace.json` (Copilot) — and three plugin manifests:
  `plugin.json` (generic), `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`.
  Copilot ships a marketplace but no host-specific plugin manifest, so it has only the
  generic `plugin.json` to resolve. That path is unverified against a real Copilot
  install; treat Copilot support as untested until it is.
- Host-specific assets reach the generic layout through symlinks: `skills` ->
  `.agents/skills` and `agents` -> `.claude/agents`. Add a host by pointing a manifest
  at those names, not by copying the trees.
