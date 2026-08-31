#!/usr/bin/env bash
# Standalone UserPromptSubmit text hook. Full plugin manifests intentionally do not
# wire it; consumers opt in through templates/{codex-hooks,claude-settings}.json.
# Bare acknowledgements are silent. Every substantive prompt gets the same compact
# reminder. No counter, session state, model call, plugin path, or sibling file.
# Best effort: this hook never blocks a prompt and always exits zero.

payload="$(cat)"
prompt="$(printf '%s' "$payload" \
  | sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)"
ack="$(printf '%s' "$prompt" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -d '[:punct:]' \
  | tr -s '[:space:]' ' ' \
  | sed 's/^ //;s/ $//')"

prompt_has_escaped_quote=false
[[ "$payload" == *'\"'* ]] && prompt_has_escaped_quote=true

if [[ "$prompt_has_escaped_quote" == false ]]; then
  case " $ack " in
  " ok "|" okay "|" k "|" kk "|" yes "|" yep "|" yeah "|" ya "|" yup "| \
  " no "|" nope "|" sure "|" cool "|" nice "|" got it "|" thanks "| \
  " thank you "|" ty "|" thx "|" proceed "|" continue "|" go "| \
  " go ahead "|" go on "|" done "|" next "|" stop "|" nvm ")
    exit 0
    ;;
  esac
fi

cat <<'EOF'
REPLY SHAPE:
- <=80 prose words. Exempt code, diagrams, tables, paths, uncertainty, risk, and failing tests.
- No preamble, recap, praise, or closing offer.
- Draw any relationship or 3+ entities; code hops: `fn (Type, file:LOC) - role`, then one Key line.
- Render only fenced ASCII or narrow tables; no Mermaid, images, or task boxes.
- Explicit depth requests lift the cap; bare why does not.
- For non-trivial work follow the repository Workflow and research prior art before design.
EOF
exit 0
