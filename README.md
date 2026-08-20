# BoxLite Agent Tooling

Canonical, versioned coding-agent resources shared by BoxLite repositories.

The repository packages one `boxlite-agent-tooling` plugin for Codex, Claude
Code, and GitHub Copilot. It owns reusable skills, audit agents, lifecycle
hooks, Git gates, and PR watchers. Consumer repositories keep only thin
activation settings, a pinned commit SHA, and a private profile manifest.

## Layout

```text
.agents/plugins/marketplace.json        Codex repository marketplace
.claude-plugin/marketplace.json         Claude-compatible marketplace
.github/plugin/marketplace.json         Copilot marketplace
plugins/boxlite-agent-tooling/          Shared multi-host plugin
profiles/catalog.json                   Public profile identities only
templates/install.sh                    Thin consumer bootstrap
```

Private Commerce and Backoffice commands remain in their private consumer
profile manifests. This public repository contains no private deployment,
authentication, or infrastructure configuration.

## Validate

```sh
python3 /path/to/plugin-creator/scripts/validate_plugin.py \
  plugins/boxlite-agent-tooling
claude plugin validate plugins/boxlite-agent-tooling
```

After installation, configure repository Git hooks explicitly:

```sh
plugins/boxlite-agent-tooling/scripts/setup.sh /path/to/consumer
```

Consumers copy `templates/install.sh` to `.agent-tooling/install.sh`. The
bootstrap reads the consumer's pinned SHA, checks out that exact revision under
the repository's common Git directory, validates the private profile, and then
configures the shared Git hooks.
