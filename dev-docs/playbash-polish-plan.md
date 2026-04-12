# Playbash polish plan — 2026-04-11 audit

A targeted plan for the issues surfaced by a post-refactor audit of `playbash`. Three phases:

- **Phase 1 — polish** (ships as `3.0.6`): fix two small sharp edges in `errors.js` and `libs/playbash.sh`. ✅ shipped, commit `2083fcc`.
- **Phase 2 — shell quoting** (ships as `3.1.0`): introduce a `shellQuote()` helper and apply it to every site where operator-supplied paths are interpolated into shell command lines. This fixes three real bugs where paths containing spaces, quotes, or shell metacharacters misbehave on the remote side. ✅ shipped, commit `a2807c0`.
- **Phase 3 — UX polish** (ships as `3.1.1`): small user-visible improvements surfaced by a second-pass UX audit. 9 items bundled as one commit. ⏳ pending implementation.

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

**Call-site updates** — 8 total (the 8th — `runner.js` `buildRemoteCommand` — was discovered during positive testing when `playbash push nuke '/tmp/space test.sh'` failed with `FileNotFoundError` from the remote `execvp` even after the transfer.js/staging.js fixes were in place):

| File | Line(s) | Before | After |
|---|---|---|---|
| `transfer.js` | 58 | `mkdir -p ${remotePath} && tar xf - -C ${remotePath}` | `const qRemote = shellQuotePath(remotePath)` hoisted; `mkdir -p ${qRemote} && tar xf - -C ${qRemote}` |
| `transfer.js` | 68 | `${mkdirCmd}cat > ${remotePath}` | `${mkdirCmd}cat > ${qRemote}` with `mkdirCmd` now using `shellQuotePath(remoteDir)` |
| `transfer.js` | 78 | `tar cf - -C ${remotePath} .` | `tar cf - -C ${qRemote} .` |
| `transfer.js` | 93 | `cat ${remotePath}` | `cat ${qRemote}` |
| `transfer.js` | 208 | `test -d ${rp} && echo d || echo f` | `test -d ${shellQuotePath(rp)} && echo d || echo f` |
| `staging.js` | 126 | `python3 -c '${pyScript}' ${remotePaths.join(' ')}` | Refactored `probeRemoteShas` to take `fileNames` (not full paths) and construct `${STAGING_DIR}/${shellQuote(n)}` internally. Clearer trust boundary: STAGING_DIR trusted, basename quoted. |
| `staging.js` | 153-154 | `cat > ${STAGING_DIR}/${name}` (+ chmod variant) | `const qName = shellQuote(name)` hoisted; `cat > ${STAGING_DIR}/${qName}` (STAGING_DIR stays unquoted so tilde expands) |
| `runner.js` | 247 | `exec python3 -u ${wrapperPath} ${playbookPath}` (in `buildRemoteCommand`) | `exec python3 -u ${wrapperPath} ${shellQuotePath(playbookPath)}`. Expanded the function's docstring to document the trust split: `reportPath`/`hostName`/`libs`/`wrapperPath` are trusted (constants or validated); only `playbookPath` can carry operator-supplied bytes for push of single-file custom playbooks. |

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

### Phase 3 — UX polish (ships as `3.1.1`)

After Phases 1 and 2 shipped, a second-pass audit (Option C) was run focused on **user-visible text quality**, not correctness. Two parallel Explore agents (UX polish + CLI surface) plus direct verification against actual code and runtime behavior (some claims about rectangle rendering required a TTY-preserving `script -qc` test to verify).

The verdict: **the user-facing surface is in reasonable shape**. Five U2 items (worth fixing — real UX paper cuts) and four U3 items (nice-to-haves, fixable for very little effort). Three agent claims were invalidated on verification — documented below so future audits don't re-report them.

Naming convention: `U-n` = UX-audit finding. Distinct from `A-n` (audit bugs, fixed in Phase 2) and `P-n` (polish, fixed in Phase 1).

#### Findings

**U-1 — `debug` silently ignores `-n`**
- Location: `private_dot_local/bin/executable_playbash:362` — `const rectHeight = command === 'debug' ? 0 : (linesFlag ?? 5);`
- Impact: A user typing `playbash debug nuke daily -n 20` expects 20 lines of live output; they get the same silent rect-disabled behavior as `playbash debug nuke daily`. The flag is parsed (it's a top-level option) but discarded for the `debug` case.
- Fix: reject `-n` loudly in the `debug` branch so the user knows their input was ignored. Concrete: `if (command === 'debug' && linesFlag != null) die('debug does not accept -n — use "run <targets> <playbook> -n N" for a rectangle');`. The whole point of `debug` is "the no-rectangle variant of `run`"; the flag is meaningless there.
- Priority: **U2**

**U-2 — `put`/`get` accept `--self` but USAGE doesn't document it**
- Location: `private_dot_local/bin/executable_playbash:50-51` USAGE shows `playbash put <targets> <local-path> [<remote-path>] [-p N] [-N]` and `playbash get <targets> <remote-path> [<local-path>] [-p N] [-N]` — no `[--self]`.
- Impact: The handlers at lines 413/420 call `resolveAndValidate(rest[0])` which reads `values.self` globally. `completion.bash:45,73` also offer `--self`. Three sources of truth disagree: USAGE (no), completion (yes), handler (yes). A user who doesn't tab-complete never discovers it.
- Fix: add `[--self]` to both USAGE lines so they match the other fan-out-capable subcommands.
- Priority: **U2**

**U-3 — `exec` USAGE line says `[options]` instead of enumerating them**
- Location: `private_dot_local/bin/executable_playbash:49` — `playbash exec <targets> [--] <command...> [options]`
- Impact: Every other fan-out-capable subcommand lists its options explicitly: `run` shows `[-n LINES] [-p N] [--self]`, `push` the same. `exec` is the only one that's vague. Worse, the `[options]` placeholder tells the user that options exist but not which ones — they must tab-complete or read the code.
- Fix: replace with `[-n LINES] [-p N] [--self] [-N]` to match the other subcommands.
- Priority: **U2**

**U-4 — Transfer failures in fan-out drop most of the error message**
- Location: `private_dot_local/private_share/playbash/runner.js` — the `transfer` branch of `launchOne`'s catch (around line 965). It sets `statusWord: truncateStatus(err.message)` → max 60 chars. No `slot.tail`, no `slot.logPath`, so `renderFanoutSummary`'s `showCapturedOutput` branch has nothing to render for a failed transfer beyond the 60-char status word.
- Impact: For a put/get failure — say, "permission denied" followed by a long path with the real cause — the user sees the first 60 chars and loses the rest. Transfers never write a log file (there's nothing to log; they're one-shot), so `playbash log` doesn't help either.
- Fix: capture the full `err.message` (and/or `err.stderr` from `sshRun` if present) into a new `slot.transferError` field; in `renderFanoutSummary`, after the status line, render it wrapped under the failed host's block in the `showCapturedOutput === true` branch. One minor rendering tweak — ~10 lines of change.
- Priority: **U2**

**U-5 — `-n` default description doesn't mention per-subcommand differences**
- Location: `private_dot_local/bin/executable_playbash:60` USAGE says `-n, --lines N   height of the live output rectangle (default 5)`.
- Impact: Reality is more nuanced: `run`/`push` default to 5; `debug` ignores `-n` (forced to 0, see U-1); `exec` defaults to 0 but honors `-n` when passed. A user reading the help text thinks `playbash exec host cmd` will show a 5-line rectangle by default. It won't.
- Fix (lands alongside U-1): update the line to `-n, --lines N   height of the live output rectangle for run/push (default 5). exec defaults to 0; pass -n N to enable.`. The fix for U-1 means debug is no longer a special case — it rejects `-n` loudly, so doesn't need to be mentioned in this doc line.
- Priority: **U2**

**U-6 — `list`/`hosts`/`doctor` don't tab-complete `-h`/`--help`**
- Location: `private_dot_local/private_share/playbash/completion.bash:33-35` early-returns for these three subcommands with no flag completion offered.
- Impact: Tab-completing `playbash list -<Tab>` yields nothing even though `playbash list -h` works at runtime. Minor discoverability issue.
- Fix: replace the `return` with a short branch that offers `-h --help` when `$cur` starts with `-`. One-line change per the pattern used elsewhere in the file (e.g., line 24-28 for the top-level).
- Priority: **U3**

**U-7 — `empty target list` error has no hint about valid inputs**
- Location: `private_dot_local/private_share/playbash/inventory.js:78` — `die('empty target list')` when the user passes `""` or `,,,` or similar.
- Impact: The user sees a terse error with no remediation hint. Narrow case (the error path only fires on empty or comma-only input), but the fix is trivial.
- Fix: `die('empty target list (pass a host name, group name, or "all")')`.
- Priority: **U3**

**U-8 — `list` with zero playbooks could hint at `playbash doctor`**
- Location: `private_dot_local/private_share/playbash/commands.js` — around line 97, in `cmdList`: `no playbooks found in ${PLAYBOOK_DIR} (looking for ${PLAYBOOK_PREFIX}*)`.
- Impact: A user on a fresh install sees this and has no next step. `playbash doctor` is the right tool to diagnose missing playbooks (doctor verifies the environment including the playbook dir).
- Fix: append `— run 'playbash doctor' to diagnose.` to the message.
- Priority: **U3**

**U-9 — `parseSidecar` malformed-line warning doesn't identify the host**
- Location: `private_dot_local/private_share/playbash/sidecar.js:16` — `process.stderr.write('playbash: ignoring malformed sidecar line: ${line}\n')`.
- Impact: When fan-out runs across 20 hosts and one has a corrupt sidecar, the warning surfaces during rendering without telling the user which host produced it. Hard to diagnose blind.
- Fix: thread `hostName` through `parseSidecar(text, hostName)` and include it in the warning. One function-signature change and call-site updates in the two places `parseSidecar` is called (search `parseSidecar(` in `runner.js`). Low blast radius.
- Priority: **U3**

#### Items considered and deliberately skipped

- **Log-directory-aware completion for `playbash log`** — agent 2 suggested replacing the generic `compgen -f` in `completion.bash` for the `log` subcommand with a walker that reads `~/.cache/playbash/runs/<host>/<command>/` and offers host names at pos 0 and command names at pos 1. Real UX win but ~15 lines of custom bash logic. Deferred as a separate focused change if it ever feels annoying enough in real use. Not in Phase 3's 9-item scope.
- **Doctor check name casing** — agent 1 flagged `ssh config` vs `ControlMaster` vs `ssh-agent` as inconsistent. On verification, the mix is intentional: `ssh config` / `ssh-agent` / `private key` / `playbooks` / `playbash.sh` / `python3` are *descriptions*, and `ControlMaster` / `ControlPersist` / `ControlPath` are *literal config-option names*. The styles are different because they refer to different kinds of things. **Verified clean.**
- **Subcommand naming (run/push/debug/exec)** — any rename is a breaking change; not worth it.
- **Exit code semantics** — agent 2 claimed inconsistency but on verification `runFanout` exits `failCount > 0 ? 1 : 0`, `runTransferSingle` exits 1 on catch, `die` exits 2. All three are consistent with Unix conventions. **Verified clean.**
- **`put`/`get` argument order** — agent 2 flagged as potentially inconsistent with Unix conventions, then self-corrected in the same finding. `put local remote` and `get remote local` match `scp` direction conventions. **Verified clean.**

#### Agent claims invalidated on verification (do not re-report)

These are false alarms that the audit agents reported but I verified don't hold up. Listed here so future audits don't re-burn cycles.

- **"`exec` silently ignores `-n`"** — WRONG. Verified via `script -qc "playbash exec nuke -n 3 '...'" /dev/null` which preserved the TTY; the raw output contains ANSI cursor-up (`[3A`) and erase-line (`[2K`) sequences; the 3-line rectangle renders correctly. Line 400 (`const rectHeight = linesFlag ?? 0`) correctly honors the flag. The agent was probably confused by redirection (`2>&1 | head`) breaking the TTY, which correctly disables the rectangle per `Rectangle.active = process.stdout.isTTY && height > 0`. The real issue (U-5) is that USAGE doesn't document the different defaults, not that exec ignores `-n`.
- **"`err.message.slice(0, 60)` still present in some call site"** — WRONG. Grep confirms zero occurrences across the playbash tree. All three were refactored to `truncateStatus()` in the 3.0.5 polish (see Phase 1 of this plan).
- **"Exit codes inconsistent: multi-host fan-out exits 0 even on failure"** — WRONG. `runFanout` ends with `if (!cleaningUp) process.exit(failCount > 0 ? 1 : 0);` (runner.js, last line). `runTransferSingle` has `process.exit(1)` in its catch handler. `die()` exits 2. All three are consistent: 0 = all ok, 1 = some failed, 2 = user error.
- **"`Rectangle.active` uses stdout while `StatusBoard.active` uses stderr — inconsistent"** — Initially suspicious, but correct on reflection: Rectangle tees chunks to stdout (so stdout redirection correctly disables it and falls through to raw stream output); StatusBoard paints its display to stderr. Intentional split, not a bug.

#### Plan — one bundled commit as `3.1.1`

Ship the 9 items above as one commit. Small blast radius, ~50-80 lines of source total, all one logical unit ("UX polish from second-pass audit"). Patch bump since nothing changes the subcommand *surface area* (no new commands, no new flags, just better errors/hints/docs + one bug fix for U-1 and a small feature for U-4).

**Implementation order** (fixed to avoid cross-file churn):

1. **U-1 + U-5** (`executable_playbash`, two changes in the same file): reject `-n` in debug, update USAGE line 60 description.
2. **U-2 + U-3** (`executable_playbash`, USAGE text only, three changes): add `[--self]` to put/get USAGE, replace `[options]` with explicit flags for exec USAGE.
3. **U-4** (`runner.js` + `render.js` maybe): capture full transfer error message on `slot`, render it in `renderFanoutSummary`'s transfer branch. This is the largest single change in Phase 3 — probably 15-25 lines.
4. **U-6** (`completion.bash`): replace the `list|hosts|doctor) return` branch with a flag-completion fall-through.
5. **U-7** (`inventory.js`): one-line error message edit.
6. **U-8** (`commands.js`): one-line error message edit.
7. **U-9** (`sidecar.js` + `runner.js`): thread hostName through parseSidecar.
8. Bump `VERSION` → `3.1.1` in `executable_playbash`.

**Verification:**
- `node --check` on every modified file.
- `chezmoi apply`.
- `playbash --version` → `3.1.1`.
- **U-1** regression: `playbash debug nuke daily -n 5` should fail loudly with the new error message (not silently run). `playbash debug nuke daily` should still work as before.
- **U-2/U-3** regression: `playbash --help | grep -- --self` should now include put/get lines; `playbash --help | grep exec` should show the enumerated options.
- **U-4** positive test: force a put failure (e.g., `playbash put nuke /tmp/nonexistent '~/x.sh'`) in fan-out mode (`playbash put nuke,uhop /tmp/nonexistent '~/x.sh'`) and verify the full error is visible under the failed host, not just a 60-char prefix.
- **U-6** regression: `eval "$(playbash --bash-completion)"; playbash list -<Tab>` should offer `-h --help`.
- **U-7** regression: `playbash run '' daily 2>&1` should show the new hint.
- **U-8** regression: temporarily rename `~/.local/bin/playbash-*` and run `playbash list`; expect the hint about `playbash doctor`.
- **U-9** regression: manufacture a corrupt sidecar (requires a playbook that writes `notjson\n` to `$PLAYBASH_REPORT`) or temporarily patch the file post-run; verify the warning includes the host name.
- Full regression sweep: `playbash list`, `playbash hosts`, `playbash exec nuke 'echo hi'`, `playbash run nuke hello`, `playbash doctor` — all should behave identically.

## Risks

- **Phase 2 changes the wire format** — the exact bytes sent over ssh are different (`/tmp/foo` → `'/tmp/foo'`). For any path that previously worked, the quoted form MUST still work. POSIX shell quotes are universal, so this should be safe. The tilde-aware helper adds the only sharp edge: a path like `~/foo bar` must stay expandable. Verified via positive test.
- **Phase 1 `libs/playbash.sh` edit touches a file deployed via chezmoi.** The file lives at `~/.local/libs/playbash.sh` on every managed host. Rolling out the fix requires `chezmoi update` on each host. Since the P-1 change is a comment-only edit, there's no actual behavior change — the fix is purely documentary. No rollout urgency.
- **Phase 1 `errors.js` edit** is local to the operator. No rollout needed.
- **Phase 3 U-1 is a small breaking change** for users who pass `-n` to `debug` and expect it to be silently accepted. Previously the flag was accepted and ignored; after U-1 it dies with an error. Unlikely to affect anyone in practice — passing `-n` to `debug` never did anything useful — but technically behavior-changing. This is why U-1 is a bundled fix alongside the USAGE cleanup (U-5), so the user sees the rejection message and the clarified doc line in the same release.
- **Phase 3 U-4** changes the post-failure output for fan-out transfers, adding more text per failed host. Scripts parsing fan-out output for transfers are unlikely (transfers are usually interactive) but the line count per failed host grows from 1 to up to ~5. If anyone parses this, mention it in the release note.
- **No breaking change otherwise** — all three phases preserve exit codes, stdout/stderr discipline, and all successful-path output.

## Status

| Phase | Status | Version | Commit | Notes |
|---|---|---|---|---|
| 1 — polish | ✅ | `3.0.6` | `2083fcc` | P-1: `errors.js` coerces non-string `msg` via `String(msg)`. P-2: `libs/playbash.sh` documents the `--data` contract (pre-formed JSON, caller's responsibility). Verified: `die(new Error('test'))` now prints `playbash: Error: test` instead of `[object Object]`; all regression smoke tests pass. |
| 2 — shell quoting | ✅ | `3.1.0` | `a2807c0` | A-1 + A-2 + A-3 via `shellQuote` / `shellQuotePath`. New module `share/playbash/shell-escape.js` (43 lines) with two exports. **8 call sites fixed** — the plan listed 7; an 8th surfaced when the positive test exposed `buildRemoteCommand` in `runner.js` also interpolating `playbookPath` raw. Full test matrix verified on `nuke`: plain-path put/get roundtrip byte-identical; put+get+push all work with `/tmp/space test.sh`; fan-out exec, managed `run`, doctor, list, hosts all pass regression. |
| 3 — UX polish | ✅ | `3.1.1` | — | U-1 through U-9 implemented. U-1: debug rejects `-n` loudly. U-2/U-3: USAGE shows `[--self]` on put/get, enumerates exec flags. U-4: transfer failures now show full error under each failed host. U-5: USAGE line clarifies per-subcommand `-n` defaults. U-6: list/hosts/doctor tab-complete `-h --help`. U-7: empty target list includes hint. U-8: no-playbooks message suggests `playbash doctor`. U-9: malformed sidecar warning includes host name. All syntax checks pass, full regression suite verified. |

## Audit history

- **Phase 1/2 audit (correctness + shell quoting)** — four parallel Explore agents + direct verification, 2026-04-11. Produced the A-1..A-3 and P-1..P-2 findings.
- **Phase 3 audit (UX polish, Option C)** — two parallel Explore agents + direct verification (including a TTY-preserving `script -qc` test to verify rectangle rendering), 2026-04-11. Produced U-1..U-9 findings plus the list of invalidated claims documented in the Phase 3 plan.

Both audits had a substantial false-positive rate from the agents (~47% in the first audit, similar in the second — the rectangle-rendering claim was the most significant). The verified-safe and invalidated-claims lists throughout this doc are there to keep future audits from wasting cycles on the same false trails.
