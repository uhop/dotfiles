---
description: Pre-release verification checklist for AI-doc-style projects (AGENTS.md, llms.txt, etc.)
---

# Release Check

Run through this checklist before publishing a new version of any project that
follows the AGENTS.md / llms.txt convention.

## Steps

1. Check that `ARCHITECTURE.md` reflects any structural changes (if present).
2. Check that `AGENTS.md` is up to date with any rule or workflow changes.
3. Check that `.windsurfrules`, `.clinerules`, `.cursorrules` are in sync with
   `AGENTS.md` (run `/sync-ai-rules` if not).
4. Check that `llms.txt` and `llms-full.txt` are up to date with any API changes
   (run `/ai-docs-update` if not).
5. Verify `package.json`:
   - `files` array includes all necessary entries (e.g. `src`, `llms.txt`,
     `llms-full.txt`).
   - `exports` map is correct.
   - `description` and `keywords` are current.
6. Check that the copyright year in `LICENSE` includes the current year.
7. Bump `version` in `package.json` (semver based on the nature of changes
   since the last tag — `git log <last-tag>..HEAD`).
8. Update release history in `README.md` if the project keeps one.
9. **Sweep dependencies for staleness.** Run `npm outdated` and bump anything
   with a newer major or minor available. For libraries this is non-negotiable —
   stale ranges generate user complaints when consumers run a different version
   of the same dep. See [[dep-version-freshness]] in the vault for the full
   rationale and the "when adding" half of the rule.
10. Run `npm install` (or `npm install --package-lock-only`) to regenerate
    `package-lock.json` after any bumps from step 9.
11. Run the full test suite: `npm test`.
12. Dry-run publish to verify package contents: `npm pack --dry-run`.
13. Stop and report — do **not** commit, tag, or publish without explicit
    confirmation from the user.
