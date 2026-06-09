#!/usr/bin/env bash
#
# findings-session-init.sh — agent-findings SessionStart hook
#
# Runs once when a Claude Code session opens. Records the session_id to a
# known file so the /distill skill can read it without needing env vars.
#
# Wiring (settings.json):
#   "hooks": { "SessionStart": [ { "hooks": [ { "type": "command",
#     "command": "~/.claude/hooks/findings-session-init.sh" } ] } ] }

set -u

command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat)"
session="$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null)"
[ -n "$session" ] || exit 0

STORE="${AGENT_FINDINGS_HOME:-$HOME/.agent-findings}"
mkdir -p "$STORE/meta"
printf '%s\n' "$session" > "$STORE/meta/current-session"

exit 0
