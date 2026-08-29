---
name: shell-engineering
description: Design, refactor, review, or test Bash hook and gate scripts where modularity, explicit failure semantics, concurrency, safe state files, or cross-host behavior matter. Do not use for a trivial one-line shell command.
---

# Shell Engineering

Write shell as a small program, not as a command transcript. Preserve the host hook's
stdin, stdout, stderr, and exit-code contract before changing its structure.

## Design

- Keep an executable as a composition root: dependency checks, library loading, input
  parsing, and one command/event dispatch.
- Put cohesive reusable behavior in `.agents/lib/`. A sourced library has no top-level
  mutation, process exit, stdin read, or output.
- Namespace every exported function and module variable with the domain prefix. Shell
  has one global function table; the prefix is its namespace.
- Prefer a facade with one or two public operations. Keep parsing, validation,
  persistence, rendering, and orchestration in separate private helpers.
- Model lifecycle changes as named transitions under one serialization owner. Do not
  encode a state machine as cooperating booleans or let callers assemble lock order.
- Pass values explicitly when they cross modules. If a module needs shared context,
  expose one initializer and keep its variables namespaced.
- Do not introduce class-like dispatch, dynamic function names, `eval`, or inheritance
  emulation. In Bash, modules plus prefixed functions are the readable class boundary.

## Boundaries and failures

- Validate untrusted JSON, paths, identifiers, enum values, and numeric limits once at
  entry. Internal functions may rely on the validated shape.
- Reuse `verdict-audit-state.sh` for bounded reads, atomic writes, inode checks, and
  state-path derivation. Do not recreate security-sensitive file primitives locally.
- Use `printf`, not `echo`, for machine-facing output. Keep data out of executable shell
  text; use positional arguments or an authenticated encoding when a host requires a
  copyable command.
- Quote expansions unless deliberate splitting or pattern matching is documented.
- Make failure propagation explicit. Do not add `set -e` to an existing hook without
  auditing every conditional, pipeline, command substitution, and expected nonzero
  branch. Preserve intentional `set -uo pipefail` behavior.
- Check required external commands at the executable boundary. Libraries declare their
  assumptions in comments and do not repeat checks on every call.
- Keep cleanup recoverable and narrowly scoped. Never recursively delete runtime state.

## Concurrency review

Before editing a serialized lifecycle, draw start, escalation, selection, completion,
new-prompt, and teardown as an interleaved timeline. Identify the owner of each state
file and the exact lock covering every check-and-write pair. Bound locks, reads, waits,
receipt counts, and leases. Treat regular files, symlinks, FIFOs, directories, stale
records, malformed records, replacement generations, and replayed notifications as
separate input variants.

## Verification

1. Add a focused behavioral test at the public script boundary. Structure-only checks
   may supplement behavior but never replace it.
2. For a bug fix, demonstrate the test red with every production change reverted, then
   green with the full change restored.
3. Run `bash -n` on every changed shell file.
4. Run `shellcheck -x` on executables and sourced libraries when ShellCheck is present;
   every dynamic source needs a nearby `# shellcheck source=` directive.
5. Run the focused hook suite, host parity, then every plugin `*.test.sh` suite.
6. Run `scripts/sync-guidance.sh --check` and `git diff --check`.

## References

- [GNU Bash reference](https://www.gnu.org/software/bash/manual/bash.html)
- [ShellCheck source-loading contract](https://github.com/koalaman/shellcheck/blob/master/shellcheck.1.md)
- [nvm namespaced-function and multi-shell practice](https://github.com/nvm-sh/nvm/blob/master/AGENTS.md)
- [Bash Coding Standard and agent inventory](https://github.com/Open-Technology-Foundation/bash-coding-standard)
- [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
