# agent-findings

**A cross-session collective-learning layer for Claude Code agents.**

Every agent starts with amnesia. It solves something, the session ends, and the lesson evaporates. The next agent relearns it from scratch.

agent-findings fixes that: after every task an agent writes down what it learned, before every task it reads back what past runs figured out.

> **Blog post:** [i gave my coding agents a shared memory](https://krish-shah.vercel.app/blog/2026-06-08-i-gave-my-agents-a-shared-memory)

---

## Install

Requires `jq` and the `claude` CLI. On macOS: `brew install jq`.

```bash
curl -fsSL https://raw.githubusercontent.com/krish-shahh/agent-findings/main/install.sh | bash
```

Restart any running Claude Code sessions. That's it — both hooks register automatically.

<details>
<summary>Manual / clone install</summary>

```bash
git clone https://github.com/krish-shahh/agent-findings.git
cd agent-findings
./install.sh
```

To uninstall (findings are kept): `./uninstall.sh`
</details>

---

## How it works

```mermaid
sequenceDiagram
    participant P as user prompt
    participant R as findings-reader.sh
    participant S as ~/.agent-findings
    participant C as claude
    participant W as findings-writer.sh

    P->>R: UserPromptSubmit hook
    R->>S: score index by tags + task_type
    S-->>R: top 3 findings
    R-->>C: inject prior knowledge block
    P-->>C: original prompt
    Note over C: executes task
    C->>W: Stop hook
    W-->>W: distill session (claude -p, detached)
    W->>S: write {uuid}.json · reindex
```

- **`findings-reader.sh`** — before every prompt, scores the store by keyword overlap against `task_type` and `tags`, injects the top 3 as a prior-knowledge block. Pure shell + `jq`, nothing slow.
- **`findings-writer.sh`** — after every session, detaches a background worker that distills the transcript via `claude -p`, confidence-gates the result (< 0.5 is discarded), and writes one finding per session.

---

## The finding

One JSON file. One reusable lesson. The schema is the protocol — anything that writes this shape interoperates.

```jsonc
{
  "schema_version": "1.0",
  "id": "7c2a1e90-4b3d-4f1a-9c2e-0a1b2c3d4e5f",
  "task_type": "debugging",          // kebab-case — the retrieval key
  "language": "python",
  "what_worked": "the flaky test was a clock dependency. injecting a clock made it deterministic.",
  "what_failed": "spent 20 min adding retries assuming a network race — re-running 'until green' hid the non-determinism.",
  "better_exit_condition": "a test that passes on retry but fails in isolation means non-determinism in the code, not the harness.",
  "tags": ["flaky-test", "pytest", "non-determinism"],
  "confidence": 0.86,                // below 0.5 is never stored
  "timestamp": "2026-06-08T22:00:00Z",
  "source": { "agent": "claude-code", "session_id": "…", "cwd": "…" }
}
```

Full schema: [`schema/finding.schema.json`](schema/finding.schema.json) · Example: [`examples/`](examples/example-finding.json)

**Protocol rules:** one finding per file, immutable, append-only, confidence-gated. `index.json` and `stats.json` are caches — `agent-findings reindex` rebuilds them from the files at any time. Because findings are UUID-addressed and immutable, **merging two stores is a set union** — no conflicts, ever.

---

## Store layout

```
~/.agent-findings/
├── index.json              # tag index + finding summaries (cache)
├── findings/
│   └── {task_type}/
│       └── {uuid}.json     # source of truth
└── meta/
    ├── stats.json
    └── writer.log
```

---

## CLI

```bash
agent-findings list [N]        # recent findings (default 10)
agent-findings show <id>       # full finding by id or prefix
agent-findings search <query>  # find by keyword
agent-findings delete <id>     # remove a finding
agent-findings stats           # totals, top task types, top tags
agent-findings reindex         # rebuild index from files
agent-findings sync            # push/pull with a shared remote (stub)
```

---

## Sync

The data model is built for sharing. Findings are immutable and UUID-addressed, so merging two stores is a set union of `{uuid}.json` files — no conflicts.

`agent-findings sync` is a documented stub. You can DIY today:

```bash
git -C ~/.agent-findings init
git -C ~/.agent-findings add findings
git -C ~/.agent-findings commit -m "findings"
git -C ~/.agent-findings remote add origin <url> && git -C ~/.agent-findings push -u origin main
```

Planned: `agent-findings sync push/pull` against a shared git remote.

---

## Configuration

| Variable | Default | Effect |
|---|---|---|
| `AGENT_FINDINGS_HOME` | `~/.agent-findings` | Store location |
| `AGENT_FINDINGS_TOP_N` | `3` | Findings injected per prompt |
| `AGENT_FINDINGS_TRANSCRIPT_BYTES` | `60000` | Transcript cap for distiller |

---

## Contributing

A finding is just a JSON file. Write the same shape from Cursor, Aider, a CI job, or your own agent and it drops straight into any store. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
