#!/usr/bin/env bash
#
# uninstall.sh — remove agent-findings hooks, CLI, and settings entries.
# Leaves your collected findings in ~/.agent-findings untouched (delete that
# directory by hand if you want them gone).

set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOKS_DIR="$CLAUDE_DIR/hooks"
BIN="$HOME/.local/bin/agent-findings"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required." >&2; exit 1; }

WRITER_CMD="~/.claude/hooks/findings-writer.sh"
READER_CMD="~/.claude/hooks/findings-reader.sh"

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak.$(date -u +%Y%m%d%H%M%S)"
  tmp="$SETTINGS.tmp.$$"
  jq --arg writer "$WRITER_CMD" --arg reader "$READER_CMD" '
    if .hooks.Stop then
      .hooks.Stop |= map(select((.hooks // []) | all(.command != $writer)))
    else . end
    | if .hooks.UserPromptSubmit then
        .hooks.UserPromptSubmit |= map(select((.hooks // []) | all(.command != $reader)))
      else . end
  ' "$SETTINGS" >"$tmp" && mv "$tmp" "$SETTINGS"
  echo "settings: removed hook entries"
fi

rm -f "$HOOKS_DIR/findings-writer.sh" "$HOOKS_DIR/findings-reader.sh" && echo "hooks: removed"
rm -f "$BIN" && echo "cli: removed"
echo "Done. Your findings remain at ~/.agent-findings."
