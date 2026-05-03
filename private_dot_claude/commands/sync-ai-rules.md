---
description: Sync .windsurfrules / .cursorrules / .clinerules to match AGENTS.md
---

# Sync AI Rules Files

Ensure all AI agent rules files are identical copies of the canonical
`AGENTS.md`.

## Steps

1. **Read `AGENTS.md`** — canonical source for all AI agent rules.
2. **Update `.windsurfrules`**, **`.cursorrules`**, **`.clinerules`** with the
   same content. Each may carry an optional one-line header comment:
   `<!-- Canonical source: AGENTS.md — keep this file in sync -->`
3. **Verify the three files are identical** (modulo the header comment).
4. **Run tests** to confirm nothing regressed (use the project's test runner).

## When to Run

- After updating `AGENTS.md` with new rules or conventions.
- Before releasing a new version (see `/release-check`).
- When adding support for a new AI agent that consumes a `*rules` file.
