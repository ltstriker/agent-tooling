# Agent Tooling Development

- Keep reusable implementation in `plugins/boxlite-agent-tooling/`.
- Keep consumer manifests declarative and free of secrets.
- Preserve fail-closed validation: invalid profiles and missing dependencies
  must write a clear error to stderr and exit nonzero.
- Consumers float: `tooling.ref` in the profile names the branch, and the adopted
  revision lives only in `.git/agent-tooling/current`, written after
  validate-before-adopt — a tip that fails validation is never adopted. Gates verify
  against that record with a pure local check; only the bootstrap and
  `scripts/refresh-installation.sh` touch the network. `.agent-tooling/hold` (one
  full lowercase commit SHA) freezes a fleet or a machine, and a malformed hold
  fails closed.
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
- `plugins/boxlite-agent-tooling/host-parity.test.sh` pins the cross-host contract:
  same identity in every manifest, marketplaces advertising the shipped version, one
  skills tree, one agent-spec set, one hooks file inside the schema both hosts parse.
  Run it after touching any manifest, marketplace, symlink, or hooks.json.
