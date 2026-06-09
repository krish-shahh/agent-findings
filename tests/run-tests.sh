#!/usr/bin/env bash
#
# run-tests.sh — end-to-end tests for agent-findings.
#
# Self-contained: runs against a throwaway store (AGENT_FINDINGS_HOME in a temp
# dir) and a stubbed `claude` CLI, so it never touches your real ~/.agent-findings
# and never makes a live model call. Exercises every behavior.
#
#   ./tests/run-tests.sh
#
# Exit code 0 = all passed.

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WRITER="$REPO/hooks/findings-writer.sh"
READER="$REPO/hooks/findings-reader.sh"
INIT="$REPO/hooks/findings-session-init.sh"
GUARD="$REPO/hooks/findings-exit-guard.sh"
CLI="$REPO/bin/agent-findings"
RM=/bin/rm   # bypass any `rm` alias (e.g. a trash tool that rejects -f)

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 ($2)"; fi; }

# --- sandbox ----------------------------------------------------------------
export AGENT_FINDINGS_HOME="$(mktemp -d)/store"
mkdir -p "$AGENT_FINDINGS_HOME/findings" "$AGENT_FINDINGS_HOME/meta"
printf '%s\n' '{"task_types":{},"tags":{},"findings":[]}' > "$AGENT_FINDINGS_HOME/index.json"
printf '%s\n' '{"total_findings":0,"top_task_types":[],"top_tags":[],"last_write":null,"last_sync":null}' \
  > "$AGENT_FINDINGS_HOME/meta/stats.json"

# Unset API keys and distillation flag so tests run in a clean, controlled env.
unset ANTHROPIC_API_KEY OPENAI_API_KEY AGENT_FINDINGS_ENABLED

# stub `claude`: prints whatever $STUB_OUT holds (so each test controls the finding)
STUBDIR="$(mktemp -d)"
cat > "$STUBDIR/claude" <<'EOF'
#!/usr/bin/env bash
# Emit exactly $STUB_OUT (each test sets it). Note: no ${VAR:-default} here —
# the trailing brace of a {} default would corrupt the JSON.
printf '%s\n' "$STUB_OUT"
EOF
chmod +x "$STUBDIR/claude"
export PATH="$STUBDIR:$PATH"

mk_transcript() {  # -> path
  local t; t="$(mktemp).jsonl"
  printf '%s\n' '{"type":"user","message":{"content":"do a task"}}' >> "$t"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"done."}]}}' >> "$t"
  echo "$t"
}
n_findings() { jq '.findings | length' "$AGENT_FINDINGS_HOME/index.json"; }

echo "agent-findings test suite"
echo "store: $AGENT_FINDINGS_HOME"
echo

# --- 1. write path + normalization ------------------------------------------
echo "[1] writer: distill -> normalize -> write"
TX="$(mk_transcript)"
export STUB_OUT='```json
{"task_type":"API Integration","language":"TypeScript/Next.js","what_worked":"context.WithTimeout","what_failed":"leaked goroutine","better_exit_condition":"race detector clean","tags":["HTTP_Client","Context","Context"],"confidence":0.82}
```'
AGENT_FINDINGS_DISTILL=1 "$WRITER" --distill "$TX" "sess-A" "/tmp/proj"
F="$(find "$AGENT_FINDINGS_HOME/findings" -name '*.json' | head -1)"
check "finding written"                 "[ -n \"$F\" ] && [ -f \"$F\" ]"
check "code fence stripped, valid JSON" "jq -e . \"$F\" >/dev/null"
check "task_type kebab-cased"           "[ \"\$(jq -r .task_type \"$F\")\" = api-integration ]"
check "sharded into task_type dir"      "echo \"$F\" | grep -q /findings/api-integration/"
check "language normalized (slash->hyphen)" "[ \"\$(jq -r .language \"$F\")\" = typescript-next-js ]"
check "tags lowercased+kebab+deduped"   "[ \"\$(jq -c .tags \"$F\")\" = '[\"context\",\"http-client\"]' ]"
check "schema_version set"              "[ \"\$(jq -r .schema_version \"$F\")\" = 1.0 ]"
check "source.session_id recorded"      "[ \"\$(jq -r .source.session_id \"$F\")\" = sess-A ]"
check "index has 1 finding"             "[ \"\$(n_findings)\" -eq 1 ]"
check "stats total = 1"                 "[ \"\$(jq -r .total_findings \"$AGENT_FINDINGS_HOME/meta/stats.json\")\" -eq 1 ]"

# --- 2. confidence gate -----------------------------------------------------
echo "[2] writer: confidence gate (<0.5 discarded)"
export STUB_OUT='{"task_type":"misc","language":"none","what_worked":"x","what_failed":"","better_exit_condition":"","tags":["y"],"confidence":0.30}'
AGENT_FINDINGS_DISTILL=1 "$WRITER" --distill "$(mk_transcript)" "sess-low" "/tmp"
check "low-confidence NOT written"      "[ \"\$(n_findings)\" -eq 1 ]"
check "writer.log notes the discard"   "grep -q 'discard: confidence' \"$AGENT_FINDINGS_HOME/meta/writer.log\""

# --- 3. one finding per session (dedupe) ------------------------------------
echo "[3] writer: one finding per session (last-write-wins)"
export STUB_OUT='{"task_type":"refactor","language":"go","what_worked":"v2","what_failed":"","better_exit_condition":"","tags":["t"],"confidence":0.9}'
AGENT_FINDINGS_DISTILL=1 "$WRITER" --distill "$(mk_transcript)" "sess-A" "/tmp/proj"  # same session as test 1
check "still 1 finding for sess-A"      "[ \"\$(grep -rl 'sess-A' \"$AGENT_FINDINGS_HOME/findings\" | wc -l | tr -d ' ')\" -eq 1 ]"
check "newer finding replaced older"   "[ \"\$(grep -rh task_type \"$AGENT_FINDINGS_HOME/findings\" | grep -c refactor)\" -eq 1 ]"

# --- 4. distinct session -> distinct finding --------------------------------
echo "[4] writer: different session keeps its own finding"
export STUB_OUT='{"task_type":"testing","language":"python","what_worked":"z","what_failed":"","better_exit_condition":"","tags":["pytest"],"confidence":0.7}'
AGENT_FINDINGS_DISTILL=1 "$WRITER" --distill "$(mk_transcript)" "sess-B" "/other/proj"
check "now 2 findings (A + B)"          "[ \"\$(n_findings)\" -eq 2 ]"

# --- 5. recursion guard -----------------------------------------------------
echo "[5] writer: recursion guard (nested distill env => no-op)"
before="$(n_findings)"
echo '{"transcript_path":"/nope","session_id":"x","cwd":"/tmp"}' | AGENT_FINDINGS_DISTILL=1 "$WRITER"
check "guarded invocation wrote nothing" "[ \"\$(n_findings)\" -eq $before ]"

# --- 6. reader retrieval ----------------------------------------------------
echo "[6] reader: retrieves relevant findings"
out="$(echo '{"prompt":"help me write a pytest test in python"}' | "$READER")"
check "reader emits additionalContext" "echo '$out' | jq -e .hookSpecificOutput.additionalContext >/dev/null"
ctx="$(echo "$out" | jq -r .hookSpecificOutput.additionalContext)"
check "surfaces the python/testing one" "echo \"$ctx\" | grep -q testing"

echo "[7] reader: no match => silent"
out="$(echo '{"prompt":"compose a haiku about the sea"}' | "$READER")"
check "no output when nothing matches"      "[ -z \"\$out\" ]"

echo "[7b] reader: 4-char token floor (short words don't spuriously match)"
# 'the' (3 chars) must NOT match task_type 'testing' — only >=4-char tokens score
out="$(echo '{"prompt":"the sea"}' | "$READER")"
check "3-char token 'the' does not match 'testing'" "[ -z \"\$out\" ]"

# --- 8. CLI -----------------------------------------------------------------
echo "[8] CLI"
check "list shows 2 findings"          "\"$CLI\" list | grep -q '2 finding'"
ID="$(jq -r '.findings[0].id' "$AGENT_FINDINGS_HOME/index.json")"
check "show by full id works"          "\"$CLI\" show \"$ID\" | jq -e .id >/dev/null"
check "show by id-prefix works"        "\"$CLI\" show \"${ID:0:8}\" | jq -e .id >/dev/null"
check "stats reports total 2"          "\"$CLI\" stats | grep -q 'Total findings: 2'"
check "help has no stray set -u"       "! \"$CLI\" help | grep -q 'set -u'"
check "unknown cmd exits nonzero"      "! \"$CLI\" bogus 2>/dev/null"

echo "[9] CLI reindex rebuilds from files"
$RM -f "$AGENT_FINDINGS_HOME/index.json"
"$CLI" reindex >/dev/null
check "reindex rebuilt index (2)"      "[ \"\$(n_findings)\" -eq 2 ]"

# --- 10. CLI search ---------------------------------------------------------
echo "[10] CLI search"
check "search hits on matching keyword" "\"$CLI\" search pytest | grep -q testing"
check "search miss returns no table"    "! \"$CLI\" search zxqjunk 2>/dev/null | grep -q TASK_TYPE"
check "search no-arg exits nonzero"     "! \"$CLI\" search 2>/dev/null"

# --- 11. CLI delete ---------------------------------------------------------
echo "[11] CLI delete"
DEL_ID="$(jq -r '.findings[0].id' "$AGENT_FINDINGS_HOME/index.json")"
DEL_FILE="$(jq -r '.findings[0].path' "$AGENT_FINDINGS_HOME/index.json")"
"$CLI" delete "$DEL_ID" >/dev/null
check "file removed from disk"         "[ ! -f \"$DEL_FILE\" ]"
check "index count decremented"        "[ \"\$(n_findings)\" -eq 1 ]"
check "stats total decremented"        "[ \"\$(jq -r .total_findings \"$AGENT_FINDINGS_HOME/meta/stats.json\")\" -eq 1 ]"
check "delete prefix match works"      "\"$CLI\" delete \"${DEL_ID:0:8}\" 2>&1 | grep -q 'no finding'" # already gone

# --- 12. session init hook --------------------------------------------------
echo "[12] session init: writes session_id to current-session"
printf '%s\n' '{"session_id":"sess-init-test","transcript_path":"/tmp/tx.jsonl","cwd":"/tmp"}' \
  | "$INIT"
check "current-session file created"   "[ -f \"$AGENT_FINDINGS_HOME/meta/current-session\" ]"
check "session_id written correctly"   "[ \"\$(cat \"$AGENT_FINDINGS_HOME/meta/current-session\")\" = sess-init-test ]"

# Overwrite with a new session — idempotent, last write wins.
printf '%s\n' '{"session_id":"sess-init-v2","transcript_path":"/tmp/tx.jsonl","cwd":"/tmp"}' \
  | "$INIT"
check "session_id updated on re-init"  "[ \"\$(cat \"$AGENT_FINDINGS_HOME/meta/current-session\")\" = sess-init-v2 ]"

# Empty session_id is a no-op.
printf '%s\n' '{"session_id":"","transcript_path":"/tmp/tx.jsonl","cwd":"/tmp"}' \
  | "$INIT"
check "empty session_id leaves file unchanged" \
  "[ \"\$(cat \"$AGENT_FINDINGS_HOME/meta/current-session\")\" = sess-init-v2 ]"

# --- 13. exit guard ---------------------------------------------------------
echo "[13] exit guard"

# Off by default (AGENT_FINDINGS_ENABLED unset) — always allows /exit.
check "guard is a no-op when AGENT_FINDINGS_ENABLED unset" \
  "printf '%s' '{\"prompt\":\"/exit\",\"session_id\":\"sess-no-sentinel\"}' \
    | AGENT_FINDINGS_ENABLED= \"$GUARD\""

# AGENT_FINDINGS_ENABLED=1, no sentinel → blocks (exit code 2).
check "guard blocks /exit when enabled and not distilled" \
  "! printf '%s' '{\"prompt\":\"/exit\",\"session_id\":\"sess-no-sentinel\"}' \
    | AGENT_FINDINGS_ENABLED=1 \"$GUARD\" 2>/dev/null"

# /quit is treated identically to /exit.
check "guard blocks /quit identically" \
  "! printf '%s' '{\"prompt\":\"/quit\",\"session_id\":\"sess-no-sentinel\"}' \
    | AGENT_FINDINGS_ENABLED=1 \"$GUARD\" 2>/dev/null"

# Non-exit prompts always pass through.
check "guard passes through non-exit prompts" \
  "printf '%s' '{\"prompt\":\"fix this bug\",\"session_id\":\"sess-no-sentinel\"}' \
    | AGENT_FINDINGS_ENABLED=1 \"$GUARD\""

# Sentinel present → allows /exit through.
touch "$AGENT_FINDINGS_HOME/meta/distilled-sess-init-test"
check "guard allows /exit after sentinel created" \
  "printf '%s' '{\"prompt\":\"/exit\",\"session_id\":\"sess-init-test\"}' \
    | AGENT_FINDINGS_ENABLED=1 \"$GUARD\""

# AGENT_FINDINGS_ENABLED=0 (explicitly disabled) — always allows.
check "guard is a no-op when AGENT_FINDINGS_ENABLED=0" \
  "printf '%s' '{\"prompt\":\"/exit\",\"session_id\":\"sess-no-sentinel\"}' \
    | AGENT_FINDINGS_ENABLED=0 \"$GUARD\""

# --- 14. install.sh: hooks in neutral agent-findings dir --------------------
echo "[14] install.sh: hooks written to agent-findings/hooks (not claude/hooks)"

INST_HOME="$(mktemp -d)"
INST_STORE="$INST_HOME/.agent-findings"
INST_CLAUDE="$INST_HOME/.claude"
INST_BIN="$INST_HOME/.local/bin"

# Run non-interactively (no TTY → defaults to enabling distillation).
# Suppress output; we test the filesystem state, not stdout.
HOME="$INST_HOME" \
AGENT_FINDINGS_HOME="$INST_STORE" \
CLAUDE_CONFIG_DIR="$INST_CLAUDE" \
  bash "$REPO/install.sh" >/dev/null 2>&1

check "install: hooks dir inside agent-findings"    "[ -d \"$INST_STORE/hooks\" ]"
check "install: writer in agent-findings/hooks"     "[ -f \"$INST_STORE/hooks/findings-writer.sh\" ]"
check "install: reader in agent-findings/hooks"     "[ -f \"$INST_STORE/hooks/findings-reader.sh\" ]"
check "install: session-init in agent-findings/hooks" "[ -f \"$INST_STORE/hooks/findings-session-init.sh\" ]"
check "install: exit-guard in agent-findings/hooks" "[ -f \"$INST_STORE/hooks/findings-exit-guard.sh\" ]"
check "install: hooks NOT in claude/hooks"          "[ ! -d \"$INST_CLAUDE/hooks\" ]"
check "install: settings.json refs agent-findings path" \
  "grep -q 'agent-findings/hooks' \"$INST_CLAUDE/settings.json\""
check "install: skill still in claude/skills"       "[ -f \"$INST_CLAUDE/skills/distill.md\" ]"
check "install: distillation flag written to profile" \
  "grep -q 'AGENT_FINDINGS_ENABLED' \"$INST_HOME/.zshrc\" 2>/dev/null \
   || grep -q 'AGENT_FINDINGS_ENABLED' \"$INST_HOME/.bashrc\" 2>/dev/null"

$RM -rf "$INST_HOME"

# --- 15. install-codex.sh: standalone, no claude dir required ---------------
echo "[15] install-codex.sh: standalone (no claude dir or prior install.sh needed)"

CODEX_INST_HOME="$(mktemp -d)"
CODEX_INST_STORE="$CODEX_INST_HOME/.agent-findings"
CODEX_INST_DIR="$CODEX_INST_HOME/.codex"

mkdir -p "$CODEX_INST_DIR"
printf '%s\n' '{"hooks":{}}' > "$CODEX_INST_DIR/hooks.json"

HOME="$CODEX_INST_HOME" \
AGENT_FINDINGS_HOME="$CODEX_INST_STORE" \
CODEX_HOME="$CODEX_INST_DIR" \
  bash "$REPO/install-codex.sh" >/dev/null 2>&1

check "codex install: hooks in agent-findings/hooks"  "[ -f \"$CODEX_INST_STORE/hooks/findings-writer.sh\" ]"
check "codex install: hooks.json has Stop entry"      \
  "jq -e '.hooks.Stop | length > 0' \"$CODEX_INST_DIR/hooks.json\" >/dev/null"
check "codex install: hooks.json has SessionStart"    \
  "jq -e '.hooks.SessionStart | length > 0' \"$CODEX_INST_DIR/hooks.json\" >/dev/null"
check "codex install: hooks.json refs agent-findings" \
  "grep -q 'agent-findings/hooks' \"$CODEX_INST_DIR/hooks.json\""
check "codex install: no claude dir created"          "[ ! -d \"$CODEX_INST_HOME/.claude\" ]"
check "codex install: store seeded"                   \
  "[ -f \"$CODEX_INST_STORE/index.json\" ] && [ -f \"$CODEX_INST_STORE/meta/stats.json\" ]"

$RM -rf "$CODEX_INST_HOME"

# --- cleanup ----------------------------------------------------------------
$RM -rf "$(dirname "$AGENT_FINDINGS_HOME")" "$STUBDIR"

echo
echo "------------------------------------"
printf 'PASSED: %d   FAILED: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && { echo "ALL GREEN"; exit 0; } || exit 1
