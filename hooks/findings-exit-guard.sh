#!/usr/bin/env bash
#
# findings-exit-guard.sh — agent-findings UserPromptSubmit hook
#
# Intercepts /exit and /quit when AGENT_FINDINGS_ENABLED=1 and the current
# session has not been distilled yet. Blocks the command and nudges the user
# to run /distill first. After /distill creates the sentinel file, the next
# /exit goes through unblocked.
#
# Wiring (settings.json):
#   "hooks": { "UserPromptSubmit": [ { "hooks": [ { "type": "command",
#     "command": "~/.claude/hooks/findings-exit-guard.sh" } ] } ] }

set -u

# Only active when distillation is opted in.
[ "${AGENT_FINDINGS_ENABLED:-}" = "1" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat)"
prompt="$(printf '%s' "$payload" | jq -r '.prompt // ""' 2>/dev/null)"

# Strip whitespace and check for exit commands only.
case "$(printf '%s' "$prompt" | tr -d '[:space:]')" in
  /exit|/quit) ;;
  *) exit 0 ;;
esac

STORE="${AGENT_FINDINGS_HOME:-$HOME/.agent-findings}"
session="$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null)"
[ -n "$session" ] || exit 0

# If this session was already distilled, let /exit through.
[ -f "$STORE/meta/distilled-$session" ] && exit 0

# Block and tell the user what to do.
printf 'agent-findings: session not yet distilled.\nRun /distill to save what you learned, then /exit again.\n(To skip: set AGENT_FINDINGS_ENABLED=0)\n'
exit 2
