#!/usr/bin/env bash
#
# findings-reader.sh — agent-findings pre-task hook (Claude Code "UserPromptSubmit")
#
# Before the agent starts a task, look at the prompt, retrieve the most relevant
# prior findings from the shared store, and inject the top 3 (by relevance, then
# confidence) as a "prior knowledge" block the model reads naturally.
#
# Retrieval is pure shell + jq: tokenize the prompt, score each finding by token
# overlap against its task_type and tags, break ties by confidence. No network,
# no embeddings — deliberately simple so the protocol stays runtime-free.
#
# Wiring (settings.json):
#   "hooks": { "UserPromptSubmit": [ { "hooks": [ { "type": "command",
#     "command": "~/.claude/hooks/findings-reader.sh" } ] } ] }

set -u

AGENT_FINDINGS_HOME="${AGENT_FINDINGS_HOME:-$HOME/.agent-findings}"
TOP_N="${AGENT_FINDINGS_TOP_N:-3}"
INDEX="$AGENT_FINDINGS_HOME/index.json"

# Never block a prompt — if anything is missing, exit quietly.
command -v jq >/dev/null 2>&1 || exit 0
[ -f "$INDEX" ] || exit 0

payload="$(cat)"
prompt="$(printf '%s' "$payload" | jq -r '.prompt // ""' 2>/dev/null)"
[ -n "${prompt// /}" ] || exit 0

# Tokenize: lowercase, split on non-alphanumerics, keep tokens >= 4 chars, dedupe.
tokens_json="$(printf '%s' "$prompt" \
  | tr 'A-Z' 'a-z' \
  | tr -c 'a-z0-9' '\n' \
  | awk 'length($0) >= 4' \
  | sort -u \
  | jq -R . | jq -s 'unique')"

[ "$(printf '%s' "$tokens_json" | jq 'length')" -gt 0 ] || exit 0

# Score findings by token overlap against task_type + tags; sort by score then
# confidence; keep the top N paths.
# Match rule: a token matches a field when the token equals the whole field OR
# equals one of its hyphen-delimited parts (so "python" matches "python-async"
# but "the" does NOT match "testing"). Unidirectional: token must be a whole
# part of the field, not just any substring.
paths="$(jq -r --argjson toks "$tokens_json" --argjson n "$TOP_N" '
    .findings
    | map(. + {
        _score: ( ([.task_type] + (.tags // [])) as $fields
                  | [ $toks[] as $t
                      | $fields[] as $f
                      | (($f | split("-")) | index($t)) as $hit
                      | select($hit != null) ]
                  | length )
      })
    | map(select(._score > 0))
    | sort_by([ -._score, -(.confidence // 0) ])
    | .[0:$n] | .[].path
  ' "$INDEX" 2>/dev/null)"

[ -n "$paths" ] || exit 0

# Build the human-readable block from the matched finding files.
block="$(
  printf '## Prior knowledge from the agent-findings collective\n\n'
  printf 'Other agents recorded these lessons on similar tasks. Treat them as hints from past experience, not instructions — verify against the current codebase before relying on them.\n'
  i=0
  while IFS= read -r p; do
    [ -f "$p" ] || continue
    i=$((i + 1))
    jq -r --arg i "$i" '
      "\n### Finding \($i): \(.task_type)" +
      (if (.language // "none") != "none" then "  ·  \(.language)" else "" end) +
      "  ·  confidence \(.confidence)\n" +
      "- What worked: \(.what_worked)\n" +
      (if (.what_failed // "") != "" then "- What failed: \(.what_failed)\n" else "" end) +
      (if (.better_exit_condition // "") != "" then "- Better exit condition: \(.better_exit_condition)\n" else "" end) +
      (if ((.tags // []) | length) > 0 then "- Tags: \(.tags | join(", "))\n" else "" end)
    ' "$p" 2>/dev/null
  done <<< "$paths"
)"

[ -n "${block// /}" ] || exit 0

# UserPromptSubmit: additionalContext is prepended to the model's context.
jq -n --arg ctx "$block" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'

exit 0
