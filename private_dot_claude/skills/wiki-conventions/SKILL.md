---
name: wiki-conventions
description: Apply wiki page naming conventions when creating, renaming, or reviewing wiki pages. Use when working with wiki documentation.
---

# Wiki Page Naming Conventions

Apply consistent naming to wiki pages. See `dev-docs/wiki-conventions.md` in any project for the full rationale.

## Naming rules

### Modules

- **Named modules**: wiki page matches the export name sans extension (e.g., `parser.js` → `parser.md`).
- **Subdirectory modules**: replace `/` separators with **ASCII dashes** (`-`) so GitHub wiki renders them as spaces: `a/b/abc.js` → `a-b-abc.md`.
- **Literal dashes inside a name**: use Unicode hyphen U+2010 (`‐`) instead of ASCII dash so the wiki renders an actual dash, not a space. This applies to **both file and folder names** (e.g., `abc-def.js` → `abc‐def.md`, `utils/with-parser.js` → `utils-with‐parser.md`, `my-utils/parser.js` → `my‐utils-parser.md`).
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

## Content rules

- Every module page documents all its exports.
- Compact components are documented in the module that exports them.
- Each page should have at least one import + usage example.
- Goals: brevity, clarity, simplicity.

## Steps

1. Identify which wiki pages need to be created, renamed, or reviewed.
2. Check each page name against the naming rules above.
3. If existing pages violate conventions, **ask the user once** whether to fix them — legacy pages may need to stay.
4. Apply conventions automatically to **new pages** or when **explicitly asked**.
5. When renaming, update all references in other wiki pages and `README.md`.
6. Verify all cross-references are consistent after changes.
