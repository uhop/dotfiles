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
8. Update release history. Check **both** locations and update each one that
   exists. They serve different audiences and carry different densities — see
   the cross-project rule at [[topics/two-tier-release-notes]] in the vault.
   - `README.md` — **cliff-notes**: the 1–2–3 most memorable items for users,
     comma-separated. Optional `Thx [Contributor](https://github.com/handle)`
     credit when the release responds to a specific issue or PR. No internal
     changes, no devDep bumps, no test counts, no CI moves. **One footer line
     at the bottom of the section, after the bullet list** (separated by a
     blank line, once per section, not per release). Exact wording is flexible
     (`The full release notes are in the wiki: [Release notes](...)`,
     `For more info consult full [release notes](...)`, etc. — all in use
     across the fleet); the placement is the rule. **If the project has no
     wiki Release-notes page, omit the footer line entirely** — don't link
     to something that doesn't exist.
   - `wiki/Release-notes.md` — the canonical longer-form history. A paragraph
     per substantive release with **bold** feature names; cover internal
     changes, calibration notes, related wiki / repo updates, and credits.
     Per-release date in the heading (use `git for-each-ref --sort=-creatordate
     --format='%(refname:short) %(creatordate:short)' refs/tags`).
     The wiki is usually a git submodule — it gets its own commit + parent-pointer bump.
   If the project doesn't yet have a wiki Release-notes page, create one,
   start the long-form convention with the *current* release, and reproduce
   the older README entries as-is in an "Earlier releases" section at the
   bottom (don't backfill detail you don't have). Then trim the README's
   current entry to cliff-notes density and add the section footer link.
   Don't update only the README — readers who follow the "for more info"
   link land on a stale page if you do.
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
