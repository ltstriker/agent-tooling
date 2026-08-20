# Agent Tooling Development

- Keep reusable implementation in `plugins/boxlite-agent-tooling/`.
- Keep consumer manifests declarative and free of secrets.
- Preserve fail-closed validation: invalid profiles and missing dependencies
  must write a clear error to stderr and exit nonzero.
- Pin consumer installations to a full commit SHA and update pins by pull
  request.
- Validate the Codex, Claude, and Copilot manifests before release.
