#!/usr/bin/env bash
#
# install-codex.sh — register agent-findings hooks with Codex
#
# Merges the Stop (writer) and UserPromptSubmit (reader) hooks into
# ~/.codex/hooks.json. Idempotent: re-running will not add duplicate entries.
#
# Prerequisites: install.sh must have been run first (hooks live in ~/.claude/hooks/).

set -euo pipefail

HOOKS_SRC="$(cd "$(dirname "$0")/hooks" && pwd)"
CODEX_HOOKS="${CODEX_HOME:-$HOME/.codex}/hooks.json"
CLAUDE_HOOKS_DIR="${HOME}/.claude/hooks"

WRITER="${CLAUDE_HOOKS_DIR}/findings-writer.sh"
READER="${CLAUDE_HOOKS_DIR}/findings-reader.sh"
INIT="${CLAUDE_HOOKS_DIR}/findings-session-init.sh"

# ── preflight ─────────────────────────────────────────────────────────────────

command -v jq >/dev/null 2>&1 || { echo "error: jq is required (brew install jq)"; exit 1; }

[ -f "$CODEX_HOOKS" ] || { echo "error: $CODEX_HOOKS not found — is Codex installed?"; exit 1; }
[ -f "$WRITER" ]      || { echo "error: $WRITER not found — run ./install.sh first"; exit 1; }
[ -f "$READER" ]      || { echo "error: $READER not found — run ./install.sh first"; exit 1; }
[ -f "$INIT" ]        || { echo "error: $INIT not found — run ./install.sh first"; exit 1; }

# ── merge hooks (idempotent) ──────────────────────────────────────────────────

backup="${CODEX_HOOKS}.bak.$(date +%Y%m%dT%H%M%S)"
cp "$CODEX_HOOKS" "$backup"

tmp="$(mktemp)"

jq --arg writer "$WRITER" --arg reader "$READER" --arg init "$INIT" '
  # Add SessionStart hook if not already present (records session_id for cross-agent use)
  ( .hooks.SessionStart //= [] )
  | if (.hooks.SessionStart | map(.hooks[]?.command? // "") | any(. == $init)) then .
    else .hooks.SessionStart += [{"hooks":[{"type":"command","command":$init,"timeout":5}]}]
    end

  # Add Stop hook if not already present
  | ( .hooks.Stop //= [] )
  | if (.hooks.Stop | map(.hooks[]?.command? // "") | any(. == $writer)) then .
    else .hooks.Stop += [{"hooks":[{"type":"command","command":$writer,"timeout":30}]}]
    end

  # Add UserPromptSubmit hook if not already present
  | ( .hooks.UserPromptSubmit //= [] )
  | if (.hooks.UserPromptSubmit | map(.hooks[]?.command? // "") | any(. == $reader)) then .
    else .hooks.UserPromptSubmit += [{"hooks":[{"type":"command","command":$reader,"timeout":10}]}]
    end
' "$CODEX_HOOKS" >"$tmp" && mv "$tmp" "$CODEX_HOOKS"

# ── trust the new hook entries ────────────────────────────────────────────────
# Codex requires trusted_hash entries in config.toml for each hook command.
# Print a reminder — the user must approve the hooks in the Codex UI on first run.

echo ""
echo "agent-findings hooks registered in $CODEX_HOOKS"
echo "  SessionStart     → $INIT"
echo "  Stop             → $WRITER"
echo "  UserPromptSubmit → $READER"
echo ""
echo "Backup saved to $backup"
echo ""
echo "Next: restart Codex. On first session start Codex will prompt you to"
echo "approve the new hooks — click 'Trust' for all three."
