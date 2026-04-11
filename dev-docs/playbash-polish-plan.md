# Playbash polish plan — 2026-04-11 audit

A targeted plan for the issues surfaced by a post-refactor audit of `playbash`. Two phases:

- **Phase 1 — polish** (ships as `3.0.6`): fix two small sharp edges in `errors.js` and `libs/playbash.sh`.
- **Phase 2 — shell quoting** (ships as `3.1.0`): introduce a `shellQuote()` helper and apply it to every site where operator-supplied paths are interpolated into shell command lines. This fixes three real bugs where paths containing spaces, quotes, or shell metacharacters misbehave on the remote side.

Each phase ships as its own commit per the versioning policy in [`playbash-design.md § Versioning`](./playbash-design.md#versioning).

## Background

The [refactor plan](./done/playbash-refactor-plan.md) was closed out on 2026-04-11 with every item struck through. A fresh post-refactor audit was then run (four parallel Explore agents + direct verification) to see what else was worth doing. The audit cross-checked every finding against actual code — the previous agent-driven audit (behind the 3.0.5 polish) had a ~47% false-positive rate, so skepticism was warranted.

The verdict: **the codebase is in good shape**. Three real bugs and two minor polish items, all listed below. Most initial agent findings were invalidated on verification.

## Findings

Naming: `A-n` = audit-identified bug, `P-n` = audit-identified polish. Keeping the `A`/`P` prefix distinct from the refactor plan's `P0/P1/P2` so future readers can tell them apart.

### A-1 — `transfer.js`: `remotePath` unquoted in 5 shell commands

Lines 58, 68, 78, 93, 208 of `private_dot_local/private_share/playbash/transfer.js`:

```js
mkdir -p ${remotePath} && tar xf - -C ${remotePath}   // putOne dir
${mkdirCmd}cat > ${remotePath}                         // putOne file
tar cf - -C ${remotePath} .                            // getOne dir
cat ${remotePath}                                      // getOne file
test -d ${rp} && echo d || echo f                      // cmdGet dir-detect
```

`remotePath` comes from the operator's `put`/`get` arguments, passed through `expandTemplate` and `normalizeRemotePath`. Neither quotes nor validates shell-unsafe characters.

**Impact today:**
- Paths with **spaces**: `playbash put host '~/my docs/report.pdf' ./file` silently lands in the wrong remote location. The remote shell splits on whitespace and `cat > ~/my docs/report.pdf` becomes `cat > ~/my` with `docs/report.pdf` as a bogus argument.
- Paths with **shell metacharacters**: `playbash put host '/tmp/$(whoami)/foo' ./file` executes `whoami` on the remote.
- Paths with **semicolons**: `/tmp/a;rm -rf /x` is interpreted as two commands.

**Threat model:** not adversarial RCE — playbash is an operator tool trusted by its user. The real issue is that `put`/`get` are user-facing commands where paths with spaces and other legitimate Unix characters are realistic, and today they silently misbehave.

### A-2 — `staging.js:126`: `remotePaths.join(' ')` in SHA probe command

```js
const r = await sshRun(address, `python3 -c '${pyScript}' ${remotePaths.join(' ')}`);
```

`remotePaths` is built in `uploadStagedFiles` as `files.map(f => \`${STAGING_DIR}/${f.name}\`)`. For custom single-file playbooks, `f.name` comes from `pathBasename(customLocalPath)` without validation (see A-3). For managed playbooks and library files, `f.name` is `playbash-${playbookName}`, `playbash-wrap.py`, or `playbash.sh` — all safe.

**Impact today:** A custom playbook at `/tmp/my script.sh` yields a remote path `~/.cache/playbash-staging/my script.sh`. That shell-splits into two argv words. Python tries to open `.../my` and `script.sh` — both fail (ENOENT) silently, and the upload-probe logic interprets them as "missing" and re-uploads every run. Silent perf regression.

For metacharacters, the impact is the same as A-3 since both share the same trusted basename.

### A-3 — `staging.js:153-154`: `${name}` from unvalidated `pathBasename(customLocalPath)` in upload command

```js
const cmd = executable
  ? `mkdir -p ${STAGING_DIR} && cat > ${STAGING_DIR}/${name} && chmod +x ${STAGING_DIR}/${name}`
  : `mkdir -p ${STAGING_DIR} && cat > ${STAGING_DIR}/${name}`;
```

Directory playbooks already go through `SAFE_DIR_NAME_RE` in `stagePlaybookDir` (good — that path is safe). But **single-file custom playbooks** set `name = pathBasename(customLocalPath)` in `stagePlaybookFiles:189` with no validation.

**Impact:** `playbash run host '/tmp/name; touch /tmp/pwned.sh'` → `pathBasename` returns `name; touch /tmp/pwned.sh` → the remote shell interprets `cat > ~/.cache/playbash-staging/name; touch /tmp/pwned.sh` as two commands. The `touch` runs.

A-1, A-2, and A-3 all have the same root cause: **the shell-command-line-construction pattern treats operator-supplied strings as pre-trusted**. A single consolidated fix (a `shellQuote` helper applied at all call sites) solves all three.

### P-1 — `playbash.sh:101`: `$data` parameter interpolated raw into JSON

```bash
[ -n "$data" ] && line+=',"data":'"$data"
```

The other fields (`msg`, `kind`, `target`, `step`) all go through `_playbash_json_escape`. The `$data` field does not — it's treated as a pre-formed JSON value.

**Impact today:** zero callers use `--data` (verified via grep across the entire repo). Latent sharp edge for future callers: a message like `--data '{"foo":"bar\"baz"}'` passed in unescaped would emit `,"data":{"foo":"bar\"baz"}` which is invalid JSON.

**Fix options:**
1. Escape via `_playbash_json_escape` and wrap in quotes, same as the other fields.
2. Document as "must be pre-formed JSON".
3. Drop the unused feature.

I'll pick **option 2** (document it). The bash helper is deployed to every managed host, so removing a feature (even an unused one) means any host that still has a stale copy of the old helper might break. Documenting is cheaper and honest about the contract.

### P-2 — `errors.js:8`: `die()` doesn't coerce non-string messages

```js
export function die(msg, code = 2) {
  process.stderr.write(`playbash: ${msg}\n`);
  process.exit(code);
}
```

If a caller passes an Error object instead of `err.message`, the template literal's implicit `.toString()` produces `[object Object]` unless the Error has a custom `toString` (it does — Error's default `toString` returns `"Error: <message>"`, so this is less bad than expected). Still, the canonical form is the message string; normalizing at the boundary prevents weird output on edge cases.

**Impact today:** zero broken callers, but this is a safety net for future maintainers.

**Fix:** `const text = typeof msg === 'string' ? msg : String(msg);` then `process.stderr.write(\`playbash: ${text}\n\`)`.

## Verified-safe areas (do not re-report in future audits)

These items were flagged by audit agents but verified as false alarms or deliberately-correct behavior. Listed here so the next audit doesn't re-burn cycles on them.

- **`Math.max` "empty array crash"** in `commands.js:126,141`, `doctor.js:326,338-339`, `render.js:261` — all sites are either guarded by `length > 0` or reached only from callers that guarantee non-empty input. Verified:
  - `commands.js:126,141` — guarded by `if (hostNames.length > 0)` / `if (groupNames.length > 0)`.
  - `doctor.js:326` — `checks` is built from a fixed-count list, never empty.
  - `doctor.js:338-339` — guarded by `if (hosts.length === 0) return;` on line 336.
  - `render.js:261` — `StatusBoard` is constructed only from `runFanout`, which runs only when `targets.length >= 2` (dispatch catches `targets.length === 1` first).
- **`cleanupAndExit` "unhandled rejection"** — `killRemoteWrapper` is designed to never throw, and `process.exit(130)` fires unconditionally afterwards.
- **`idleTimer`/`killTimer` "resource leak"** in `runHost` — cleanup is double-guarded (both in the close handler and the catch block).
- **`runHost` timer cleanup on early `makeChild` throw** — timers are set after the child is created, so an early throw can't leak them.
- **`REMOTE_KILLABLE` null-PID race** — intentional design. Entries with null `remotePid` still get killed via the local `killAllChildren('SIGTERM')` fallback. The fresh-channel kill is skipped only when the preamble never arrived, which means the wrapper crashed before `pty.fork` — at which point the remote kill is moot.
- **Signal handler double-install on re-entry** — ESM module top-level code runs exactly once per process, and the `cleaningUp` flag gates re-entry inside the handler.
- **`render.js`** CR/LF handling, StatusBoard focus/resize, `sanitizeForRect` escape filtering — all verified correct.
- **`sidecar.js`** null-byte separator keys — JSON strings can't contain literal `\x00`, so the separator is collision-safe.
- **`inventory.js`** DNS cache absence — intentional, one-shot at startup, conservative failure (unresolved → treated as remote).
- **`ssh-config.js`** Include cycle protection — present, via a `visited` set.
- **PTY wrapper (`playbash-wrap.py`)** — `__playbash_wrap_pid` preamble emits before `pty.fork`, exit-code propagation is portable, fd close/waitpid order is Mac-safe, signal handlers cover SIGTERM/SIGHUP/SIGINT/SIGPIPE.
- **`playbash.sh`** — `_playbash_json_escape` handles all required escapes; `>>` append is atomic for `<4KB` writes; `"$@"` pass-through preserves argument boundaries.
- **`completion.bash`** — no bash-4+ features; works on bash 3.2 (Mac default).

## Deliberately out of scope (prior decisions)

- **`launchOne` closure size (97 lines, 4 branches)** — flagged and declined in Phase 5 of the refactor. Splitting would require plumbing ~8 closure variables through new function signatures; net not worth it.
- **`staging.js ↔ runner.js` cyclic import** — chosen deliberately in P1-3 as the simpler alternative to extracting a `child-registry.js`. Works fine in ESM because `registerChild` is only accessed at call time, never at module load.
- **Sidecar event `filter(g => g.hosts.length >= 2)`** in `aggregateEvents` — correct per the comment; single-host events already appear in the per-host block.
- **`aggregateEvents` null-byte separator** in dedup keys — verified safe, not changing.

## Plan

### Phase 1 — Polish (ships as `3.0.6`)

Fix P-1 and P-2 together. Small, low-risk, independent of the A-items.

1. **`errors.js:8`** — coerce `msg` to string via `typeof msg === 'string' ? msg : String(msg)`.
2. **`libs/playbash.sh:101`** — add a comment above the `--data` branch documenting that `$data` must be a pre-formed JSON value (caller's responsibility), since none of the built-in emit functions use this feature.
3. Bump `VERSION` in `executable_playbash` to `3.0.6`.

**Verification:**
- `node --check` on `errors.js`.
- `bash -n libs/playbash.sh` (syntax check).
- `chezmoi apply`.
- `playbash --version` → `3.0.6`.
- Regression: `playbash list`, `playbash hosts`, `playbash exec nuke 'echo hi'`.

### Phase 2 — Shell quoting (ships as `3.1.0`)

Introduce `shellQuote()` and apply it at every call site where operator-supplied strings are interpolated into shell command lines.

**The helper** — a new tiny module or addition to an existing one. Placement decision: `staging.js` is where most of the call sites are, and `transfer.js` already imports from `staging.js` for `sshRun`. But `shellQuote` is conceptually a reusable utility, not staging-specific. I'll add it to a **new module** `share/playbash/shell-escape.js` with one export and a header comment. This keeps the module graph clean and gives future code a well-named home for any more shell-escaping helpers.

```js
// share/playbash/shell-escape.js
//
// POSIX single-quote shell escaping for strings interpolated into remote
// shell command lines (sshRun body, python3 -c argv, tar/cat pipelines).
// Wraps the string in single quotes and escapes any existing single quotes
// via the idiomatic `'\''` pattern. Safe for any byte sequence; no
// whitelist validation (which would reject legitimate spaces/unicode).

export function shellQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}
```

**Call-site updates** — 7 total:

| File | Line | Before | After |
|---|---|---|---|
| `transfer.js` | 58 | `mkdir -p ${remotePath} && tar xf - -C ${remotePath}` | quote `remotePath` (use a local `const q = shellQuote(remotePath)`) |
| `transfer.js` | 68 | `${mkdirCmd}cat > ${remotePath}` | quote `remotePath`; adjust `mkdirCmd` to use `shellQuote(remoteDir)` |
| `transfer.js` | 78 | `tar cf - -C ${remotePath} .` | quote `remotePath` |
| `transfer.js` | 93 | `cat ${remotePath}` | quote `remotePath` |
| `transfer.js` | 208 | `test -d ${rp} && echo d || echo f` | quote `rp` |
| `staging.js` | 126 | `python3 -c '${pyScript}' ${remotePaths.join(' ')}` | map each path through `shellQuote`, then `.join(' ')` |
| `staging.js` | 153-154 | `cat > ${STAGING_DIR}/${name}` (+ chmod variant) | quote the full remote path `shellQuote(\`${STAGING_DIR}/${name}\`)` |

Note: `STAGING_DIR` is `~/.cache/playbash-staging` (literal `~`). Wrapping the whole `${STAGING_DIR}/${name}` in single quotes would quote the `~` and prevent expansion. Instead, quote just the filename portion: `${STAGING_DIR}/${shellQuote(name)}`. Same trick for the paths in `transfer.js` that use `~/...` — except that `remotePath` there is operator-supplied, so we need to preserve `~` expansion too. Decision: quote the path with a sed-style split: prefix `~` stays unquoted, the rest is quoted. Or simpler: **always concatenate quoted segments** — `'` + escaped + `'`, and if a user wants `~` expansion, they pass `~/foo` which normalizes to `'~/foo'` which... won't expand.

Hmm. The `~` expansion is load-bearing here. Let me think.

**Tilde-expansion decision (revised):** The remote shell expands `~` only at the *start* of a word or after `:` or `=`. `'~/foo'` is a quoted literal — no expansion. That breaks `normalizeRemotePath`'s whole purpose, which is to convert `/home/eugene/foo` → `~/foo` so the remote shell expands per-target.

Solution: split the path. If a path starts with `~/`, emit `~/` unquoted and `shellQuote(path.slice(2))`. If it's `~username/...`, same trick. Otherwise shell-quote the whole thing. This preserves tilde expansion and quotes everything else.

Helper:

```js
// Quote a remote path for shell interpolation, preserving a leading `~`
// or `~user` tilde-expansion segment. Paths without a leading tilde are
// quoted in full.
export function shellQuotePath(p) {
  const tildeMatch = /^~([^/]*\/)/.exec(p);
  if (tildeMatch) {
    return '~' + tildeMatch[1].slice(1) + shellQuote(p.slice(tildeMatch[0].length));
  }
  if (p === '~' || /^~[^/]*$/.test(p)) return p; // bare ~ or ~user — leave unquoted
  return shellQuote(p);
}
```

Wait — this is getting hairy. Let me simplify: **only `transfer.js`'s `remotePath` needs the tilde handling**; `staging.js`'s paths all start with `${STAGING_DIR}` which is `~/.cache/playbash-staging/<name>`. For staging paths, I control the prefix — I can emit `${STAGING_DIR}/${shellQuote(name)}` directly. For `transfer.js` operator paths, I do need the tilde-aware version.

Final plan:
- `shell-escape.js` exports **two** helpers: `shellQuote(s)` (simple POSIX single-quote) and `shellQuotePath(p)` (tilde-aware wrapper).
- `transfer.js` uses `shellQuotePath` for all `remotePath` interpolations.
- `staging.js`'s `stagePlaybookFiles` uses `shellQuote(name)` (the name is the only operator-tainted part; `${STAGING_DIR}` is trusted).
- `staging.js`'s `probeRemoteShas` maps each full path through a helper. Since those paths are `${STAGING_DIR}/${name}`, the tilde is at the start and `shellQuotePath` handles it.

**Verification for Phase 2:**
- `node --check` on `shell-escape.js`, `transfer.js`, `staging.js`.
- `chezmoi apply`.
- `playbash --version` → `3.1.0`.
- **Regression smoke tests** (paths without special characters should still work):
  - `playbash push nuke /tmp/test.sh` (custom single-file playbook)
  - `playbash put nuke /tmp/test.sh '~/test.sh'` (user-facing put)
  - `playbash get nuke '~/test.sh' /tmp/test-back.sh`
  - `playbash run nuke hello` (managed playbook)
- **Positive tests** (paths WITH special characters that previously broke):
  - `playbash put nuke /tmp/space test.sh '~/space test.sh'` — path with a space
  - Verify via `ssh nuke 'ls -la ~/space\ test.sh'` that the file landed correctly
  - Cleanup after test.
- Bump `VERSION` → `3.1.0`.

## Risks

- **Phase 2 changes the wire format** — the exact bytes sent over ssh are different (`/tmp/foo` → `'/tmp/foo'`). For any path that previously worked, the quoted form MUST still work. POSIX shell quotes are universal, so this should be safe. The tilde-aware helper adds the only sharp edge: a path like `~/foo bar` must stay expandable. Verified via positive test.
- **Phase 1 `libs/playbash.sh` edit touches a file deployed via chezmoi.** The file lives at `~/.local/libs/playbash.sh` on every managed host. Rolling out the fix requires `chezmoi update` on each host. Since the P-1 change is a comment-only edit, there's no actual behavior change — the fix is purely documentary. No rollout urgency.
- **Phase 1 `errors.js` edit** is local to the operator. No rollout needed.
- **No breaking change** for scripts parsing playbash output — the two phases preserve stderr/stdout contracts.

## Status

(filled in as phases ship)

| Phase | Status | Version | Commit | Notes |
|---|---|---|---|---|
| 1 — polish | ✅ | `3.0.6` | (pending commit) | P-1: `errors.js` coerces non-string `msg` via `String(msg)`. P-2: `libs/playbash.sh` documents the `--data` contract (pre-formed JSON, caller's responsibility). Verified: `die(new Error('test'))` now prints `playbash: Error: test` instead of `[object Object]`; all regression smoke tests pass. |
| 2 — shell quoting | ⏳ | `3.1.0` | — | A-1 + A-2 + A-3 via `shellQuote` / `shellQuotePath` |

## Follow-up (Option C)

After both phases ship, run a **second-pass audit** focused on UX polish — consistent error messages, hint quality, help text, subcommand surface inconsistencies. Different scope from this audit (which focused on correctness). Will generate a separate plan doc or append to this one as `playbash-polish-plan.md § UX`.
