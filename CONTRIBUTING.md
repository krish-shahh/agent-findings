# Contributing to agent-findings

Two things matter more than anything else:

1. **Other producers and consumers** — a finding is just a JSON file conforming to `schema/finding.schema.json`. Write the same shape from Cursor, Aider, a CI job, your own agent, and it drops straight into any store. New language? Port the two hooks; keep the schema byte-for-byte identical.

2. **Schema evolution** — propose changes as PRs against `schema/finding.schema.json`. Fields under `source` are open for extension without a version bump. Changing or removing any top-level field requires a `schema_version` bump; consumers must tolerate unknown minor versions.

## House rules

- Keep the core runtime-free: shell + `jq`, no pip, no npm, no compiled binaries required.
- Keep findings immutable and append-only. Never edit a finding in place; write a new one with a new UUID.
- Never let a hook block a session. The writer must stay detached; the reader must exit 0 on any error.
- Bash scripts must pass `bash -n` and run on macOS (bash 3.2, POSIX `find`/`awk`/`sed`) without GNU extensions.

## What to contribute

| Area | What's wanted |
|---|---|
| **New producers** | Hook scripts or library integrations for Cursor, Aider, Windsurf, CI, etc. |
| **Sync backend** | Implement `agent-findings sync pull/push` against a git remote — see the stub in `bin/agent-findings` and the design in `README.md`. |
| **Schema proposals** | New optional fields (add to `source` freely; propose top-level fields with a use-case). |
| **Bug reports** | Real-world failure cases with minimal reproduction steps. |
| **Findings dumps** | Anonymized finding collections as seed data for new installs. |

## Running the tests

```bash
./tests/run-tests.sh
```

Self-contained: uses a temp store and a stubbed `claude` CLI — no model call, no side effects on your real `~/.agent-findings`.

## Pull request checklist

- [ ] `bash -n` passes on all changed scripts
- [ ] `./tests/run-tests.sh` exits 0
- [ ] New behavior is covered by a test in `run-tests.sh`
- [ ] Schema changes include an updated `examples/example-finding.json`
- [ ] No new runtime dependencies added without discussion
