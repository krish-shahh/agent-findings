#!/usr/bin/env bash
#
# install-codex.sh — register agent-findings hooks with Codex
#
# Standalone: does not require install.sh to have been run first.
# Copies hook scripts to ~/.agent-findings/hooks/ (the same neutral location
# used by the Claude Code installer) and registers them in ~/.codex/hooks.json.
#
# Idempotent: re-running will not add duplicate entries or overwrite findings.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_FINDINGS_HOME="${AGENT_FINDINGS_HOME:-$HOME/.agent-findings}"
CODEX_HOOKS="${CODEX_HOME:-$HOME/.codex}/hooks.json"

say() { printf '  %s\n' "$*"; }

# ── preflight ──────────────────────────────────────────────────────────────────

command -v jq >/dev/null 2>&1 || { echo "error: jq is required (brew install jq)"; exit 1; }
[ -f "$CODEX_HOOKS" ] || { echo "error: $CODEX_HOOKS not found — is Codex installed?"; exit 1; }

echo "agent-findings installer (Codex)"

# ── store ─────────────────────────────────────────────────────────────────────

say "store        -> $AGENT_FINDINGS_HOME"
mkdir -p "$AGENT_FINDINGS_HOME/hooks" "$AGENT_FINDINGS_HOME/findings" "$AGENT_FINDINGS_HOME/meta"
[ -f "$AGENT_FINDINGS_HOME/index.json" ] || \
  printf '%s\n' '{"task_types":{},"tags":{},"findings":[]}' >"$AGENT_FINDINGS_HOME/index.json"
[ -f "$AGENT_FINDINGS_HOME/meta/stats.json" ] || \
  printf '%s\n' '{"total_findings":0,"top_task_types":[],"top_tags":[],"last_write":null,"last_sync":null}' \
  >"$AGENT_FINDINGS_HOME/meta/stats.json"

# ── hooks → neutral store location ───────────────────────────────────────────

say "hooks        -> $AGENT_FINDINGS_HOME/hooks"
install -m 0755 "$REPO_DIR/hooks/findings-writer.sh"       "$AGENT_FINDINGS_HOME/hooks/findings-writer.sh"
install -m 0755 "$REPO_DIR/hooks/findings-reader.sh"       "$AGENT_FINDINGS_HOME/hooks/findings-reader.sh"
install -m 0755 "$REPO_DIR/hooks/findings-session-init.sh" "$AGENT_FINDINGS_HOME/hooks/findings-session-init.sh"

WRITER="$AGENT_FINDINGS_HOME/hooks/findings-writer.sh"
READER="$AGENT_FINDINGS_HOME/hooks/findings-reader.sh"
INIT="$AGENT_FINDINGS_HOME/hooks/findings-session-init.sh"

# ── merge into codex hooks.json (idempotent) ──────────────────────────────────

say "codex hooks  -> $CODEX_HOOKS"
backup="${CODEX_HOOKS}.bak.$(date +%Y%m%dT%H%M%S)"
cp "$CODEX_HOOKS" "$backup"
say "backup       -> $backup"

tmp="$(mktemp)"
jq --arg writer "$WRITER" --arg reader "$READER" --arg init "$INIT" '
  # SessionStart: record session_id for cross-agent store consistency
  ( .hooks.SessionStart //= [] )
  | if (.hooks.SessionStart | map(.hooks[]?.command? // "") | any(. == $init)) then .
    else .hooks.SessionStart += [{"hooks":[{"type":"command","command":$init,"timeout":5}]}]
    end

  # Stop: distillation writer
  | ( .hooks.Stop //= [] )
  | if (.hooks.Stop | map(.hooks[]?.command? // "") | any(. == $writer)) then .
    else .hooks.Stop += [{"hooks":[{"type":"command","command":$writer,"timeout":30}]}]
    end

  # UserPromptSubmit: findings reader
  | ( .hooks.UserPromptSubmit //= [] )
  | if (.hooks.UserPromptSubmit | map(.hooks[]?.command? // "") | any(. == $reader)) then .
    else .hooks.UserPromptSubmit += [{"hooks":[{"type":"command","command":$reader,"timeout":10}]}]
    end
' "$CODEX_HOOKS" >"$tmp" && mv "$tmp" "$CODEX_HOOKS"

# ── distillation note ─────────────────────────────────────────────────────────
# Codex distillation uses `codex exec -` (headless mode) triggered by the Stop
# hook when AGENT_FINDINGS_ENABLED=1. No /distill skill on Codex — distillation
# runs automatically in the background after each session.

echo
echo "─────────────────────────────────────────────────────────────"
echo "To enable distillation, add this to your shell profile:"
echo "  export AGENT_FINDINGS_ENABLED=1"
echo
echo "When enabled, the Stop hook calls \`codex exec -\` after each"
echo "session to extract and save a finding. Uses your existing Codex"
echo "subscription — no separate API key needed."
echo "─────────────────────────────────────────────────────────────"
echo
echo "Done."
echo "  SessionStart     -> $INIT"
echo "  Stop             -> $WRITER"
echo "  UserPromptSubmit -> $READER"
echo
echo "Restart Codex. On first run it will prompt you to approve the"
echo "new hooks — click 'Trust' for all three."
