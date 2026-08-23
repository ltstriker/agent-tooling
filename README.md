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
templates/install.sh                    Thin consumer bootstrap
templates/codex-hooks.json              Scoped Codex prompt-rule wiring
templates/claude-settings.json          Scoped Claude Code prompt-rule wiring
```

## Scoped prompt rules

A full plugin installation brings the audit, PR-review, and verdict gates with it. A
repository that wants only the reply-shape and workflow reminders can commit the prompt
hook on its own. Both hosts run the same committed script:

```sh
mkdir -p "$consumer/.agent-tooling"
cp plugins/boxlite-agent-tooling/.agents/hooks/rule-recency.sh \
   "$consumer/.agent-tooling/rule-recency.sh"
```

Codex takes the whole file, because `.codex/hooks.json` holds nothing else:

```sh
mkdir -p "$consumer/.codex"
cp templates/codex-hooks.json "$consumer/.codex/hooks.json"
```

Claude Code needs a **merge**, not a copy — `.claude/settings.json` also carries keys
such as `env`, and overwriting it would drop them:

```sh
mkdir -p "$consumer/.claude"
if [ -f "$consumer/.claude/settings.json" ]; then
  jq -s '.[0] * .[1]' "$consumer/.claude/settings.json" templates/claude-settings.json \
    > "$consumer/.claude/settings.json.new" &&
    mv "$consumer/.claude/settings.json.new" "$consumer/.claude/settings.json"
else
  cp templates/claude-settings.json "$consumer/.claude/settings.json"
fi
```

A fresh consumer has neither the file nor its parent directory, and `jq -s` on a
missing path fails rather than treating it as empty.

The two wirings differ in exactly one respect: Claude Code exports
`$CLAUDE_PROJECT_DIR`, while Codex has no project-root variable and substitutes
`$(git rev-parse --show-toplevel)` instead. `templates/prompt-rules.test.sh` asserts
they stay otherwise identical, so neither host quietly gains a rule the other lacks.

This wiring is deliberately independent of the pin. It never reads
`.git/agent-tooling/<sha>/`, needs no bootstrap, and works in a repository that has
never installed the plugin — the consumer's `rule-recency.sh` is a committed snapshot.

The cost is drift: bumping `tooling.sha` does **not** update that copy, and nothing
detects the gap, because the copies are invisible from this repository. Refresh one by
re-running the `cp` above and committing the result. Weigh that against the audit gates,
where staleness is a correctness problem rather than a wording one.

Four things about these files are load-bearing, and each one fails silently when it is
wrong:

- The **nested `hooks` array** inside each event entry is required:
  `UserPromptSubmit[] -> .hooks[] -> {type, command}`. Command objects placed directly
  in the event array are the obvious wrong guess and register nothing.
- Event names are **PascalCase** (`UserPromptSubmit`). Codex records hook trust under
  snake_case keys, which makes the wrong casing look plausible.
- **No comment keys.** Both hosts validate strictly and reject an unknown key at any
  depth by loading no hooks at all; Codex does it without logging a parse error.
- For Codex the project must be **trusted**. Codex grants trust on first run in a
  directory, so the hook starts firing on the run after that one.

`templates/prompt-rules.test.sh` pins all four for both hosts, because nothing
downstream reports them. It also checks that `rule-recency.sh` still runs with nothing
else installed, which is the assumption the committed copy rests on.

Hooks themselves need no opt-in: `codex features list` reports `hooks` as `stable`,
enabled by default.

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
configures worktree-local shared Git hooks. Run the bootstrap once for an
ordinary clone. Later checkouts, merge-based pulls, rebases, and amended commits
opportunistically install a changed pin; commits and pushes reject a stale
installation until the bootstrap succeeds.
