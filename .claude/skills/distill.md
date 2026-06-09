# /distill

Distill this session into a reusable finding and save it to the agent-findings store. This runs entirely in the current session — no separate model call, no extra billing.

## Steps

**1. Get session context**

Run this first to resolve the store path and session ID:

```bash
STORE="${AGENT_FINDINGS_HOME:-$HOME/.agent-findings}"
SESSION_ID=$(cat "$STORE/meta/current-session" 2>/dev/null || echo "unknown")
CWD="$PWD"
echo "store=$STORE  session=$SESSION_ID  cwd=$CWD"
```

**2. Reflect on this session**

Based on the full conversation so far, extract:

- `task_type` — the problem category in kebab-case (e.g. `debugging`, `refactor`, `api-integration`, `build-config`, `feature-implementation`, `test-writing`, `data-migration`, `general`)
- `language` — primary language or ecosystem in kebab-case, or `none`
- `what_worked` — the concrete approach or insight that actually solved it; actionable for a future agent
- `what_failed` — dead ends and wrong assumptions that wasted time (empty string if none)
- `better_exit_condition` — the signal that should have said "done" or "stuck" sooner (empty string if the one used was already right)
- `tags` — 3–8 kebab-case retrieval keywords
- `confidence` — 0..1: how generalizable is this lesson to future agents on similar tasks?

Confidence guide:
- Below 0.5: discard — session was trivial, purely conversational, or lesson is too repo-specific to be useful elsewhere
- 0.5–0.7: useful but narrow
- 0.7+: clearly transferable lesson with a concrete cause and fix

**3a. If confidence ≥ 0.5 — write the finding**

Run:
```bash
UUID=$(uuidgen | tr 'A-Z' 'a-z')
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STORE="${AGENT_FINDINGS_HOME:-$HOME/.agent-findings}"
SESSION_ID=$(cat "$STORE/meta/current-session" 2>/dev/null || echo "unknown")
TASK_TYPE="<replace-with-actual-task-type>"
mkdir -p "$STORE/findings/$TASK_TYPE"
echo "uuid=$UUID  ts=$TS"
```

Then use the **Write tool** to create `$STORE/findings/$TASK_TYPE/$UUID.json` with:

```json
{
  "schema_version": "1.0",
  "id": "<UUID from above>",
  "task_type": "<task_type>",
  "language": "<language>",
  "what_worked": "<what_worked>",
  "what_failed": "<what_failed>",
  "better_exit_condition": "<better_exit_condition>",
  "tags": ["<tag1>", "<tag2>"],
  "confidence": <confidence>,
  "timestamp": "<TS from above>",
  "source": {
    "agent": "claude-code",
    "session_id": "<SESSION_ID from above>",
    "cwd": "<CWD from above>"
  }
}
```

Then rebuild the index and mark the session as distilled:
```bash
agent-findings reindex
touch "${AGENT_FINDINGS_HOME:-$HOME/.agent-findings}/meta/distilled-$SESSION_ID"
```

Tell the user: finding saved (show task_type + confidence), and they can now type `/exit`.

**3b. If confidence < 0.5 — skip but still unblock exit**

Don't write a finding. Still create the sentinel so `/exit` works:
```bash
STORE="${AGENT_FINDINGS_HOME:-$HOME/.agent-findings}"
SESSION_ID=$(cat "$STORE/meta/current-session" 2>/dev/null || echo "unknown")
touch "$STORE/meta/distilled-$SESSION_ID"
```

Tell the user why the session wasn't worth distilling, and that they can now type `/exit`.

## Schema rules

- `task_type` and `language`: kebab-case only — lowercase, hyphens, no spaces or slashes
- `tags`: array of unique kebab-case strings
- All string fields present (use `""` for optional ones when empty, not `null`)
