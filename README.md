# BoxLite Agent Tooling

Canonical, versioned coding-agent resources shared by BoxLite repositories.

The repository packages one `boxlite-agent-tooling` plugin for Codex, Claude
Code, and GitHub Copilot. It owns reusable skills, audit agents, lifecycle
hooks, Git gates, and PR watchers. Consumer repositories keep only thin
activation settings, the branch they float on (`tooling.ref`), and a private
profile manifest; the adopted revision is recorded locally in
`.git/agent-tooling/current`.

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

This wiring is deliberately independent of the installation. It never reads
`.git/agent-tooling/`, needs no bootstrap, and works in a repository that has
never installed the plugin — the consumer's `rule-recency.sh` is a committed snapshot.

The cost is drift: the plugin floats on `tooling.ref`, but this copy does **not**
follow it, and nothing detects the gap, because the copies are invisible from this
repository. Refresh one by re-running the `cp` above and committing the result. Weigh
that against the audit gates, where staleness is a correctness problem rather than a
wording one.

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
bash plugins/boxlite-agent-tooling/host-parity.test.sh
```

The parity suite is the cross-host check the two host validators cannot make: it
asserts Claude Code's conventional discovery, Codex's declared paths, and the generic
manifest all resolve to the same skills, agent specs, and hooks file, that every wired
command resolves its root on both hosts, and that the marketplaces advertise the
version the manifests actually carry.

After installation, configure repository Git hooks explicitly:

```sh
plugins/boxlite-agent-tooling/scripts/setup.sh /path/to/consumer
```

## Floating updates

Consumers copy `templates/install.sh` to `.agent-tooling/install.sh` and declare the
branch they float on in `.agent-tooling/profile.json` (`tooling.ref`, normally
`main`). The bootstrap resolves the branch tip, fetches that exact revision under the
repository's common Git directory, validates the private profile, configures
worktree-local shared Git hooks, and only then records the revision in
`.git/agent-tooling/current` — so a tip that fails validation is fetched, rejected,
and never adopted.

Commits and pushes verify against that record with a pure local check: offline work
keeps running on the last adopted revision, and only the very first installation
needs the network. Checkouts, merge-based pulls, rebases, and amended commits repair
a broken installation in the foreground and otherwise spawn a throttled background
refresh (`scripts/refresh-installation.sh`) that adopts a moved tip. Set
`AGENT_TOOLING_REFRESH=0` to disable the polling, `AGENT_TOOLING_REFRESH_MINUTES` to
retune the throttle. Every adoption appends `<epoch> <source> <sha>` to
`.git/agent-tooling/history.log`, which is what answers "which tooling was active
here" now that the revision no longer lives in repository history.

To freeze the fleet — a bad tip landed, or a revision must be kept for a bisect —
write one full lowercase commit SHA to `.agent-tooling/hold` (commit it to freeze
every clone, keep it local to freeze one machine). While a hold exists nothing is
resolved, the gates stay closed until the held revision is adopted, and a malformed
hold fails the installation rather than letting it float on. Delete the file to
resume floating.

Host plugin activations (`.claude/settings.json`, the Copilot settings, the Codex
marketplace) float on the same `tooling.ref` — the profile validation enforces it —
but each host re-resolves the ref on its own schedule, so the cross-host agreement is
same-ref, not same-revision. `templates/install.test.sh` pins all of this against a
local fixture remote.
