---
name: docs-review
description: Review and improve English in documentation files for brevity and clarity. Use when asked to review docs, improve documentation writing, or edit prose for clarity.
---

# Documentation English Review

Review markdown documentation files for brevity and clarity.

## Steps

1. List all markdown files in the target directory (e.g., `wiki/`, `docs/`) and note `README.md`.
2. For each file, read the full contents.
3. Edit prose for brevity and clarity:
   - Remove verbose preambles (e.g., "The module provides..." → direct description).
   - Replace "The following members are available:" → "Members:" or similar.
   - Shorten descriptions while preserving technical accuracy.
   - Fix typos and grammar issues.
4. **Do NOT change:**
   - Code examples or code blocks.
   - Markdown tables (content or formatting).
   - Technical terms, function signatures, or parameter names.
   - Comments in code blocks.
   - Links or image references.
5. After editing each file, move to the next. Track progress with the todo list.
6. When all files are done, provide a summary of changes.

## Wiki page naming conventions

See `dev-docs/wiki-conventions.md` in any project for the full rationale. Summary:

### Modules

- **Named modules**: wiki page matches the import name (e.g., `parser.js` → `parser.md`).
- **Dashes in names**: use Unicode hyphen U+2010 (`‐`) instead of ASCII dash so GitHub wiki doesn't treat it as a space (e.g., `as‐objects.md`).
- **Subdirectory modules**: join folder + file with a dash: `utils/with-parser.js` → `utils‐with‐parser.md`.
- **Unnamed modules** (`index.js`): use a descriptive name (e.g., `Main-module.md`).
- **Unnamed modules in folders**: use the folder name: `utils/index.js` → `utils.md`.

### Components

- Use the exported name as-is: `ClassName.md`, `CONSTANT_NAME.md`.
- For functions, add trailing parens: `functionName().md`.

### Previous versions

- Old version docs are renamed with a version prefix: `V1-`, `V2-`, etc.
- Update all internal and external references when renaming.
- These conventions do not apply to prefixed legacy pages.

### Other pages

- Technical (`Home.md`) and descriptive pages (`Performance.md`, `Migrating-from-v1-to-v2.md`) use descriptive names.

### General rules

- Every module page documents all its exports. Compact components stay in their module's page.
- Each page should have at least one import + usage example.
- Goals: brevity, clarity, simplicity.

### Behavior

- If existing wiki pages violate these conventions, **ask the user once** whether to fix them — legacy pages may need to stay.
- Apply conventions automatically to **new pages** or when **explicitly asked**.
- When renaming, update all references in other wiki pages and `README.md`.
