#!/usr/bin/env bash
#
# install.sh — set up agent-findings globally for Claude Code.
#
# Idempotent. Safe to re-run. It:
#   1. creates the store at ~/.agent-findings with a seeded index/stats
#   2. installs the two hooks into ~/.claude/hooks
#   3. installs the `agent-findings` CLI into ~/.local/bin
#   4. registers both hooks in ~/.claude/settings.json (preserving everything
#      already there; a timestamped backup is written first)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_FINDINGS_HOME="${AGENT_FINDINGS_HOME:-$HOME/.agent-findings}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
BIN_DIR="$HOME/.local/bin"

say() { printf '  %s\n' "$*"; }

command -v jq >/dev/null 2>&1 || { echo "error: jq is required. Install it (brew install jq) and re-run." >&2; exit 1; }

echo "agent-findings installer"

# 1. Store --------------------------------------------------------------------
say "store        -> $AGENT_FINDINGS_HOME"
mkdir -p "$AGENT_FINDINGS_HOME/findings" "$AGENT_FINDINGS_HOME/meta"
[ -f "$AGENT_FINDINGS_HOME/index.json" ] || \
  printf '%s\n' '{"task_types":{},"tags":{},"findings":[]}' >"$AGENT_FINDINGS_HOME/index.json"
[ -f "$AGENT_FINDINGS_HOME/meta/stats.json" ] || \
  printf '%s\n' '{"total_findings":0,"top_task_types":[],"top_tags":[],"last_write":null,"last_sync":null}' \
  >"$AGENT_FINDINGS_HOME/meta/stats.json"

# 2. Hooks --------------------------------------------------------------------
say "hooks        -> $HOOKS_DIR"
mkdir -p "$HOOKS_DIR"
install -m 0755 "$REPO_DIR/hooks/findings-writer.sh"       "$HOOKS_DIR/findings-writer.sh"
install -m 0755 "$REPO_DIR/hooks/findings-reader.sh"       "$HOOKS_DIR/findings-reader.sh"
install -m 0755 "$REPO_DIR/hooks/findings-session-init.sh" "$HOOKS_DIR/findings-session-init.sh"
install -m 0755 "$REPO_DIR/hooks/findings-exit-guard.sh"   "$HOOKS_DIR/findings-exit-guard.sh"

# 2b. Skill -------------------------------------------------------------------
SKILLS_DIR="$CLAUDE_DIR/skills"
say "skill        -> $SKILLS_DIR/distill.md"
mkdir -p "$SKILLS_DIR"
install -m 0644 "$REPO_DIR/.claude/skills/distill.md" "$SKILLS_DIR/distill.md"

# 3. CLI ----------------------------------------------------------------------
say "cli          -> $BIN_DIR/agent-findings"
mkdir -p "$BIN_DIR"
install -m 0755 "$REPO_DIR/bin/agent-findings" "$BIN_DIR/agent-findings"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "note: $BIN_DIR is not on your PATH. Add: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# 4. settings.json ------------------------------------------------------------
say "settings     -> $SETTINGS"
mkdir -p "$CLAUDE_DIR"
[ -f "$SETTINGS" ] || printf '%s\n' '{}' >"$SETTINGS"

backup="$SETTINGS.bak.$(date -u +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$backup"
say "backup       -> $backup"

WRITER_CMD="~/.claude/hooks/findings-writer.sh"
READER_CMD="~/.claude/hooks/findings-reader.sh"
INIT_CMD="~/.claude/hooks/findings-session-init.sh"
GUARD_CMD="~/.claude/hooks/findings-exit-guard.sh"

tmp="$SETTINGS.tmp.$$"
jq \
  --arg writer "$WRITER_CMD" \
  --arg reader "$READER_CMD" \
  --arg init   "$INIT_CMD" \
  --arg guard  "$GUARD_CMD" '
  # Ensure .hooks and all event arrays exist.
  .hooks = (.hooks // {})
  | .hooks.Stop             = (.hooks.Stop             // [])
  | .hooks.UserPromptSubmit = (.hooks.UserPromptSubmit // [])
  | .hooks.SessionStart     = (.hooks.SessionStart     // [])

  # Stop: writer
  | ( [ .hooks.Stop[]?.hooks[]?.command ] | index($writer) ) as $hasWriter
  | (if $hasWriter == null
       then .hooks.Stop += [ { "hooks": [ { "type": "command", "command": $writer } ] } ]
       else . end)

  # UserPromptSubmit: reader
  | ( [ .hooks.UserPromptSubmit[]?.hooks[]?.command ] | index($reader) ) as $hasReader
  | (if $hasReader == null
       then .hooks.UserPromptSubmit += [ { "hooks": [ { "type": "command", "command": $reader } ] } ]
       else . end)

  # UserPromptSubmit: exit guard
  | ( [ .hooks.UserPromptSubmit[]?.hooks[]?.command ] | index($guard) ) as $hasGuard
  | (if $hasGuard == null
       then .hooks.UserPromptSubmit += [ { "hooks": [ { "type": "command", "command": $guard } ] } ]
       else . end)

  # SessionStart: session init
  | ( [ .hooks.SessionStart[]?.hooks[]?.command ] | index($init) ) as $hasInit
  | (if $hasInit == null
       then .hooks.SessionStart += [ { "hooks": [ { "type": "command", "command": $init } ] } ]
       else . end)
' "$SETTINGS" >"$tmp" && mv "$tmp" "$SETTINGS"

echo
echo "Done. Restart any running Claude Code sessions to load the hooks."
echo "Try:  agent-findings stats"
