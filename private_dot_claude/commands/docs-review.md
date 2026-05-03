Review and improve English in documentation files for brevity and clarity.

Target: $ARGUMENTS (defaults to wiki/ and README.md if not specified)

## Steps

1. List all markdown files in the target directory.
2. Read each file in full.
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
5. After editing each file, move to the next.
6. Provide a summary of changes when done.

## Wiki page naming conventions

### Modules

- **Named modules**: wiki page matches the export name sans extension (e.g., `parser.js` → `parser.md`).
- **Subdirectory modules**: replace `/` separators with **ASCII dashes** (`-`) so GitHub wiki renders them as spaces: `a/b/abc.js` → `a-b-abc.md`.
- **Literal dashes inside a name**: use Unicode hyphen U+2010 (`‐`) instead of ASCII dash so the wiki renders an actual dash, not a space. Applies to **both file and folder names** (e.g., `abc-def.js` → `abc‐def.md`, `utils/with-parser.js` → `utils-with‐parser.md`, `my-utils/parser.js` → `my‐utils-parser.md`).
- **Unnamed modules** (`index.js`): use a descriptive name (e.g., `Main-module.md`).
- **Unnamed modules in folders**: use the folder name: `utils/index.js` → `utils.md`.

### Components

- Use the exported name as-is: `ClassName.md`, `CONSTANT_NAME.md`.
- For functions, add trailing parens: `functionName().md`.

### Previous versions

- Old version docs are renamed with a version prefix: `V1-`, `V2-`, etc.
- Update all internal and external references when renaming.

### Content rules

- Every module page documents all its exports.
- Compact components are documented in the module that exports them.
- Each page should have at least one import + usage example.
- Goals: brevity, clarity, simplicity.

### Behavior

- If existing wiki pages violate naming conventions, **ask the user once** whether to fix them — legacy pages may need to stay.
- Apply conventions automatically to **new pages** or when **explicitly asked**.
- When renaming, update all references in other wiki pages and `README.md`.
