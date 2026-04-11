# Playbash refactor plan — P0-1 + P0-2

> **Status: closed 2026-04-11.** All five phases shipped, every follow-up (P0-3, P1-1 through P1-6, `die()` consolidation, 3.0.5 audit polish) completed. Moved to `dev-docs/done/` as a historical record. Any further work is tracked in [`../playbash-polish-plan.md`](../playbash-polish-plan.md) — a post-refactor audit turned up three shell-quoting bugs and two small polish items. Do not add new follow-ups here.

A focused plan to split `private_dot_local/bin/executable_playbash` (currently 1798 lines) into the entry point + three modules, then dedupe the ~150 lines of overlap between `runRemote` and `runFanout`. Based on the code review captured in conversation 2026-04-11.

## Background

The runner has been growing one feature at a time and is now at 1798 lines, doing three jobs in one file:

- **Arg parsing + dispatch** — what the entry point should be (~200 lines).
- **Runner machinery** — `runHost`, `runHostSingle`, `runRemote`, `runLocally`, `runFanout`, `probeConnectivity`, `buildRemoteCommand`, `buildExecCommand`, the stuck-on-input detector, `ACTIVE_CHILDREN` registry, and the SIGINT/SIGTERM/SIGHUP handlers (~900 lines).
- **Subcommand implementations** — `cmdList`, `cmdHosts`, `cmdLog`, `cmdCompleteTargets`, `cmdBashCompletion`, `cmdPut`, `cmdGet`, `runTransferSingle`, `putOne`, `getOne`, `latestLogUnder` (~400 lines).

In addition, `runRemote` (lines 731–808) and `runFanout`'s `launchOne` (lines 940–1092) duplicate ~150 lines of "build the wrapperPath/playbookPath/libs and either spawn ssh or spawn locally" logic. Same for `runLocally` vs `runFanout`'s self branch.

## Goals

1. Move the runner machinery, the small commands, and the put/get transfer logic into three new modules under `private_dot_local/private_share/playbash/`.
2. After the move, dedupe `runRemote` / `runLocally` / `runFanout`'s shared paths via small extracted helpers.
3. Zero behavior change. Every smoke-testable subcommand produces identical output before and after.
4. Final entry point is ~250 lines: arg parsing + dispatch + USAGE.

Non-goal: do not change any user-visible behavior, command-line surface, output format, exit codes, or sidecar protocol. This is a pure structural refactor.

## Out of scope

The following items from the code review are intentionally **not** part of this plan. They can be picked up later as separate small changes:

- **P0-3** — redundant validation in `runRemote`/`runFanout`. The split refactor will probably reorganize the validation paths anyway, so we'll revisit this after the dust settles.
- **P1-1** — single-host detection bug in `dispatch()` (uses `resolved.length` instead of `targets.length`).
- **P1-2** — `cmdHosts` early-returns on missing inventory and never shows the ssh-only section.
- **P1-3** — `sshRun` subprocesses not registered in `ACTIVE_CHILDREN`.
- **P1-4** — hoist doctor.js's `run()` helper to a shared `subprocess.js`.
- **P1-6** — further internal split of the new `runFanout` (still likely to be the biggest function in the new runner.js).
- All P2 items.
- Bug fixes B-1 through B-6.

Mixing structural and behavioral changes makes refactor mistakes hard to bisect. We do structure first; bug fixes follow.

## Plan

The work is broken into five phases. **Each phase ends with a syntax check, `chezmoi apply`, and the smoke test listed for that phase.** A phase that doesn't pass its smoke test does not move on to the next phase.

### Phase 1 — `paths.js` (foundation)

New file `private_share/playbash/paths.js` exporting the constants currently scattered across the runner, `staging.js`, and `doctor.js`:

- `PLAYBOOK_DIR` = `~/.local/bin`
- `PLAYBOOK_PREFIX` = `playbash-`
- `LIBS_DIR` = `~/.local/libs`
- `HELPER_LIB` = `LIBS_DIR/playbash.sh`
- `PTY_WRAPPER` = `LIBS_DIR/playbash-wrap.py`
- `LOG_DIR` = `~/.cache/playbash/runs`
- `WRAPPER_MANAGED` = `~/.local/libs/playbash-wrap.py` (re-export from staging convention)
- `STAGING_DIR` = `~/.cache/playbash-staging` (re-export from staging convention)

No call sites are updated in this phase. The file just exists. This decouples constants migration from the bigger module moves.

**Verification:** `node --check paths.js`. Nothing to smoke-test yet.

### Phase 2 — `runner.js` (the big move)

New file `private_share/playbash/runner.js`. Moves wholesale from the runner:

- `ACTIVE_CHILDREN` registry, `registerChild`, `killAllChildren`, the SIGINT/SIGTERM/SIGHUP installer.
- `probeConnectivity`.
- `buildRemoteCommand`, `buildExecCommand`.
- The stuck-on-input detector (`STDIN_PROMPT_RE`, `STDIN_RECENT_BUF_MAX`, `STDIN_KILL_GRACE_MS`, `TAIL_MAX_LINES`, `stdinWatchTimeoutMs`).
- `runHost`, `runHostSingle`, `runRemote`, `runLocally`, `runFanout`.
- `renderFailureTail`.

The signal handler installation is a side effect of importing `runner.js` — the file's top-level code installs the handlers, exactly as today. As long as `executable_playbash` imports something from `runner.js` during normal startup, the handlers go in.

`executable_playbash` adds an `import { runRemote, runLocally, runFanout, runHostSingle } from '../share/playbash/runner.js'`. The local definitions are deleted.

**Verification:**
- `node --check` on both files
- `chezmoi apply ~/.local/bin/playbash ~/.local/share/playbash/runner.js`
- Smoke tests:
  - `playbash exec nuke 'echo hi'` (single-host remote)
  - `playbash exec all 'true'` (multi-host fanout, hits offline detection + status board)
  - `playbash debug nuke daily` would be too noisy — use a small playbook instead. Actually `playbash run nuke hello` or similar safe playbook. (Need to check what's available; `hello` and `sample` should exist.)
  - Ctrl+C during a long exec: verify signal handler still cleans up children.

### Phase 3 — `commands.js`

New file `private_share/playbash/commands.js`. Moves from the runner:

- `cmdList`
- `cmdHosts` (this one calls `parseHostNames` from `ssh-config.js` already, no new dep)
- `cmdLog` + `latestLogUnder`
- `cmdCompleteTargets`
- `cmdBashCompletion`

`executable_playbash` adds an `import { cmdList, cmdHosts, cmdLog, cmdCompleteTargets, cmdBashCompletion } from '../share/playbash/commands.js'`. The local definitions are deleted.

**Verification:**
- `playbash list`
- `playbash hosts` (verify three sections still render)
- `playbash log` (verify the latest log file is found)
- `playbash __complete-targets` (verify the inventory + ssh-config union)
- `playbash --bash-completion | head` (verify the script is emitted)

### Phase 4 — `transfer.js`

New file `private_share/playbash/transfer.js`. Moves from the runner:

- `cmdPut`, `cmdGet`
- `runTransferSingle`
- `putOne`, `getOne`
- `expandTemplate`, `normalizeRemotePath`
- `validateCustomPlaybookPath` (used by both transfer and run/push paths — could go in `runner.js` too; final placement decided in execution)

`executable_playbash` adds an `import { cmdPut, cmdGet } from '../share/playbash/transfer.js'`. The local definitions are deleted. The `run`/`debug`/`push` dispatch in the switch needs to import `validateCustomPlaybookPath` from wherever it lands.

**Verification:**
- `playbash put nuke /tmp/playbash-refactor-test '~/playbash-refactor-test'` then verify on `nuke`, then `playbash get nuke '~/playbash-refactor-test' /tmp/playbash-refactor-roundtrip`. Cleanup both ends after.
- `playbash run nuke /tmp/<sample-dir>` (directory playbook smoke test, exercising `validateCustomPlaybookPath`)
- `playbash push nuke /tmp/<sample-file.sh>` (single file push)

### Phase 5 — Dedupe (P0-2)

Inside the new `runner.js`, extract:

- `prepareRemoteJob({playbook, customPath, hostName, address, push, inventory})` — returns `{wrapperPath, playbookPath, libs}` or throws. Encapsulates the managed/staged-file/staged-dir branching.
- `prepareLocalJob({playbook, command, hostName})` — returns `{childCmd, childArgs, env, reportPath, getSidecarText}`. Encapsulates the local-child setup.
- `makeRemoteChild(address, wrappedCommand)` — wraps `spawn('ssh', [...SSH_BASE_ARGS, address, '--', wrapped], CHILD_SPAWN_OPTS)`.
- `makeLocalChild(childCmd, childArgs, env)` — wraps `spawn(...)` with the same `detached: true` options.

`runRemote`, `runLocally`, and `runFanout`'s `launchOne` all call these. Expected savings: ~150 lines net.

**Verification:** repeat the Phase 2 + Phase 3 + Phase 4 smoke tests as a regression check. If anything regresses, the dedup is wrong.

## Risks

- **Signal handler timing.** The SIGINT/SIGTERM/SIGHUP handlers are installed at file load. If the runner is split such that `executable_playbash` doesn't transitively import `runner.js` until after some long startup work, signals received during that window are unhandled. Mitigation: import `runner.js` at the top of `executable_playbash`, before anything else.

- **`ACTIVE_CHILDREN` cross-module access.** Today the registry is a module-private `Set` accessed via `registerChild`. After the split, if `transfer.js` or other modules need to register children, they have to import `registerChild` from `runner.js`. Verified scope: only `runner.js` spawns long-lived children today. `transfer.js`'s `putOne`/`getOne` use `sshRun` (from `staging.js`), which already does NOT register children (separate P1-3 bug). This refactor does not change that.

- **`process.exit()` in the wrong place.** Several call sites do `process.exit()` directly. After the move, exit-from-module is preserved exactly. We do not change exit behavior.

- **Stuck-detector state.** The detector has per-`runHost` local state (not module-global), so the move is mechanical — no state hoisting needed.

- **Test coverage is limited.** There is no test suite. Verification is manual smoke tests. The phases are sized so each one's smoke test is small and targeted, making bisection easy if something breaks.

## Verification protocol per phase

After each phase:

1. `node --check` every modified `.js` file.
2. `chezmoi apply` the changed files.
3. Run the phase-specific smoke tests listed above.
4. If any test fails: stop, diagnose, do not proceed to the next phase.

After Phase 5: run the **full** smoke test (every subcommand) against `nuke` and `mini2` to confirm no regression vs the pre-refactor baseline.

## Success criteria

- `wc -l private_dot_local/bin/executable_playbash` shows roughly **250 lines** (down from 1798).
- `wc -l private_dot_local/private_share/playbash/runner.js` shows roughly **650–800 lines** (post-dedup).
- `commands.js` ≈ 250 lines, `transfer.js` ≈ 250 lines, `paths.js` ≈ 30 lines.
- Total LOC across the touched files is **slightly less than** the pre-refactor total (the dedup is the only net reduction).
- Every smoke test in the verification protocol passes against `nuke` and `mini2`.
- `git diff --stat` on the chezmoi source tree shows modifications only to the files we explicitly touched.

## Status — ✅ complete

All five phases shipped in one session, in plan order, no rollbacks. Every smoke test passed against `nuke` (Linux) and `mini2` (Mac).

| Phase | Status | LOC delta | Notes |
|---|---|---|---|
| 1 — `paths.js` | ✅ | new file, 30 lines | `PLAYBOOK_DIR`, `PLAYBOOK_PREFIX`, `LIBS_DIR`, `HELPER_LIB`, `PTY_WRAPPER`, `LOG_DIR`, `WRAPPER_MANAGED`, `STAGING_DIR`. No call-site updates yet. |
| 2 — `runner.js` | ✅ | new file, 1044 lines (post-Phase-5: 948) | Moved registry + signal handlers + `probeConnectivity` + `buildRemoteCommand` + `buildExecCommand` + stuck detector + `runHost` + `runHostSingle` + `runRemote` + `runLocally` + `runFanout` + `validateCustomPlaybookPath` + `expandTemplate`. `executable_playbash` dropped from 1798 → 1320 lines. |
| 3 — `commands.js` | ✅ | new file, 206 lines | Moved `cmdList`, `cmdHosts`, `cmdLog`, `latestLogUnder`, `cmdCompleteTargets`, `cmdBashCompletion`. `executable_playbash` dropped from 1320 → 614 lines. |
| 4 — `transfer.js` | ✅ | new file, 228 lines | Moved `cmdPut`, `cmdGet`, `runTransferSingle`, `putOne`, `getOne`, `normalizeRemotePath`. **Deviation from plan:** to keep `transfer.js` free of CLI-global dependencies, `cmdPut` / `cmdGet` now take a pre-validated `{targets, offlineNames, parallelLimit, …}` bundle as their first argument; the `case 'put'` / `case 'get'` branches in `executable_playbash` call `resolveAndValidate` first, then dispatch. `executable_playbash` dropped from 614 → 416 lines. |
| 5 — dedupe (P0-2) | ✅ | runner.js: 1044 → 948 lines (–96) | Extracted six helpers in `runner.js`: `prepareRemoteJob`, `prepareLocalJob`, `makeRemoteChild`, `makeRemoteSidecarFetcher`, `makeLocalSidecarFetcher`, `makeReportPath`. Plus constants `SSH_BASE_ARGS` and `CHILD_SPAWN_OPTS`. `runRemote` is now ~30 lines (was ~80), `runLocally` is ~12 lines (was ~55), `runFanout`'s self/remote branches inside `launchOne` shrank from ~150 lines to ~50 lines combined. |
| Final smoke test | ✅ |  | Verified `list`, `hosts`, `doctor`, `log`, `exec` (single + fanout), `debug` (managed playbook with sidecar events), `push` (file + dir), `put` (single + fanout), `get` (single), `--help`, `--bash-completion`, `__complete-targets`. Sidecar events still flow. Self detection still works. Offline detection still works. Dir-playbook validation hint still fires. Verified on `nuke` (Linux) and `mini2` (Mac). |

## Final LOC

Pre-refactor: **3514 lines** total across the playbash files.
Post-refactor (phases 1–5): **3299 lines** total, net **–215 lines**.
After subsequent kill-bug fix (commit 5b59093, +130 in runner.js): **3429 lines**.
After `die()` consolidation into `errors.js` (follow-up, –13 lines): **3416 lines**.
After `--version` flag (commit c7e1756, ≈+10 lines in executable_playbash): **~3426 lines**.
After P1-4 subprocess hoist (runner.js −19, doctor.js −30, subprocess.js +44): **3422 lines**.
After P1-6 renderFanoutSummary extraction (runner.js +18): **3440 lines**.
After P0-3 customPathKind short-circuit (executable_playbash +2, runner.js +4): **3446 lines**.
After P1-1/P1-2/P1-3 bug fixes (executable_playbash +1, commands.js +6, staging.js +8): **3461 lines**.
After 3.0.5 audit polish (render.js +12, runner.js +5, staging.js –1): **3477 lines**.

Per-file breakdown (current):

```
   426  bin/executable_playbash       (was 1798, –1372, –76%)
  1077  share/playbash/runner.js      (new; 948 post-Phase-5, +130 kill-bug, –9 errors.js, –19 subprocess.js, +18 renderFanoutSummary, +4 customPathKind, +5 paths dedupe + truncateStatus)
   208  share/playbash/commands.js    (new; +6 P1-2)
   224  share/playbash/transfer.js    (new)
    30  share/playbash/paths.js       (new)
    11  share/playbash/errors.js      (new; shared die() helper)
    44  share/playbash/subprocess.js  (new; shared run() helper)
   436  share/playbash/render.js      (+12: STATUS_WORD_MAX_LEN + truncateStatus)
   166  share/playbash/inventory.js   (–3 after errors.js)
   109  share/playbash/sidecar.js     (unchanged)
   270  share/playbash/staging.js     (+8 P1-3: registerChild; –1 paths dedupe)
   395  share/playbash/doctor.js      (–30 after subprocess.js)
    81  share/playbash/ssh-config.js  (unchanged)
  3477  total
```

The success criterion was "executable_playbash ≈ 250 lines, runner.js 650–800 post-dedup." Actual at end of Phase 5: 416 / 948. Current: 412 / 1069 — runner.js is larger than the post-Phase-5 snapshot because of the orphan-remote-wrapper cleanup infrastructure added later (`REMOTE_KILLABLE` registry, `killRemoteWrapper`, `trackRemoteWrapper`, `recordRemoteWrapperPid`, plus the extended signal handler in `cleanupAndExit`). That's a correctness fix, not refactor regression. The runner is bigger than estimated because `runFanout` is still a sizeable function on its own — the dedup inside `launchOne` was real but the surrounding fan-out loop, per-host summary printing, and aggregation footer are still all there. The entry point is bigger than estimated because the dispatcher (`dispatch`, `resolveAndValidate`, the `switch` statement, USAGE) is more verbose than I had in my head. Both are well within "single screen of one responsibility" so the goal is met in spirit.

## Notes / surprises

- **The dedup paid off less in runner.js LOC than I expected** — only ~96 lines saved instead of ~150. The reason is that runRemote and runLocally were already short; the big duplication was inside `launchOne` (runFanout), which lost more lines. The savings show up in *cognitive* footprint (one prepareRemoteJob call instead of two ~60-line blocks of branching) more than in raw line count.
- **`expandTemplate` and `validateCustomPlaybookPath` ended up exported from `runner.js`** because they're used by both the runner internals AND the dispatcher in `executable_playbash`. This isn't perfect — `expandTemplate` is conceptually a string utility and could live in its own module — but it's only one helper and I didn't want to create a `util.js` for one function. P2.
- **`resolveAndValidate` stayed in `executable_playbash`** because it depends on `parseArgs` results (`values.self`, `values['no-precheck']`, `values.parallel`). Could be parameterized and hoisted to `runner.js` if more callers need it; for now the dispatcher-only ownership is fine.
- **`die()` was originally defined in four places** (`executable_playbash`, `runner.js`, `transfer.js`, `inventory.js`) and a fifth appeared in `commands.js` when Phase 3 landed. All five were byte-identical. **Consolidated** into `share/playbash/errors.js` as a follow-up — now every module imports the one copy. Net –13 lines (20 removed from duplicated bodies, 7 added back as imports + new file header).
- **Dependency direction is clean**: `executable_playbash` → {`runner.js`, `commands.js`, `transfer.js`, `doctor.js`, `errors.js`}. `transfer.js` → `runner.js`. `runner.js` → {`render.js`, `inventory.js`, `sidecar.js`, `staging.js`, `paths.js`, `errors.js`, `subprocess.js`}. No cycles. `commands.js` → {`render.js`, `inventory.js`, `ssh-config.js`, `paths.js`, `errors.js`}. `doctor.js` → {`render.js`, `inventory.js`, `ssh-config.js`, `subprocess.js`}. `staging.js`, `inventory.js` (→ `errors.js`), `render.js`, `sidecar.js`, `ssh-config.js`, `paths.js`, `errors.js`, and `subprocess.js` are leaves.

## Follow-ups (not part of this refactor)

These were explicitly out of scope; ship as separate small changes when convenient:

- ~~**P0-3** — redundant validation in `runRemote`/`runFanout` for non-templated paths. After the dedup, `validateCustomPlaybookPath` runs both in dispatch (early die) and inside `prepareRemoteJob` (per-host). Could short-circuit when `customPath` is non-templated.~~ **Done** — dispatcher captures `kind` once (the `run`/`debug` case already did; the `push` case now captures instead of discarding) and forwards it via the job as `customPathKind`. `runRemote`, `runFanout`, and `prepareRemoteJob` destructure it; `prepareRemoteJob` uses `kind = customPathKind ?? validateCustomPlaybookPath(resolvedPath)` so non-templated paths trust the dispatcher's classification and templated paths (where `customPathKind` is null) still validate per host with the expanded path. Net +6 lines in source (not a LOC win — the forward-plumbing costs slightly more than the eliminated redundant call), but eliminates N-1 fs validations per fan-out on N hosts, and the validation is now authoritative in one place per invocation. Bumped `VERSION` to `3.0.3`.
- ~~**P1-1** — `dispatch()` uses `resolved.length === 1` instead of `targets.length === 1` to pick single-host vs fan-out. Two-host call where one is self drops to fan-out with one effective host.~~ **Fixed** — now uses `targets.length === 1`; `resolved` dropped from the destructuring. The self-filtered single-host case now uses the single-host pipeline (live rectangle) instead of the status board. The `isSelf && !values.self` sub-branch was dead code (filterSelf plus `resolveAndValidate`'s "all targets resolved to self" error already handled that case upstream) and was removed. Verified with `playbash exec think,nuke 'echo hi'`: before the fix the output showed the `running exec on 1 hosts` header and `done in Xs · 1 ok` footer (status-board signature); after the fix only the live stream and a single status line appear.
- ~~**P1-2** — `cmdHosts` early-returns on missing inventory and never shows the ssh-only section.~~ **Fixed** — `cmdHosts` no longer short-circuits. "no inventory" / "inventory is empty" notices still go to stderr, but the ssh-config Host alias section is now always attempted afterwards. Separator-newline logic was corrected so the ssh-only section doesn't emit a leading blank line when there's nothing above it. Verified by temporarily renaming `~/.config/playbash/inventory.json`: `playbash hosts` now prints `no inventory at ...` to stderr AND the `ssh aliases (not in inventory):` section to stdout listing all 6 ssh-config Hosts.
- ~~**P1-3** — `sshRun` subprocesses (in `staging.js`) are not registered with `ACTIVE_CHILDREN` for SIGINT cleanup. Now that `registerChild` is exported from `runner.js`, `staging.js` could import and use it.~~ **Fixed** — `staging.js` now imports `registerChild` from `runner.js` and calls it on every `sshRun` spawn. Creates a cyclic import (runner.js → staging.js → runner.js), which is safe in ESM because `registerChild` is only accessed at call time, never at module-load time; verified by `import('./staging.js')` resolving cleanly with all expected exports. The non-detached ssh children fall through `killAllChildren`'s process-group-kill fallback to `child.kill()`, which is the correct behavior for short-lived ssh clients. Verified by a `playbash push nuke /tmp/test.sh` round trip — sshRun is called multiple times (SHA probe + upload + cleanup) and each call registers its child.
- ~~**P1-4** — hoist `doctor.js`'s `run()` helper to a shared `subprocess.js`.~~ **Done** — `share/playbash/subprocess.js` exports the single `run(cmd, args, {timeoutMs})` primitive; `doctor.js` imports it (was a 28-line private helper), and `runner.js`'s `probeConnectivity` drops its hand-rolled `spawn` + `new Promise` + error-handling in favor of the same helper. Net delta: runner.js −19, doctor.js −30, subprocess.js +44 = ~−5 lines — small raw-LOC win, but the real payoff is one place for "run a short-lived subprocess and capture its output". Bumped `VERSION` to `3.0.1`.
- ~~**P1-6** — split `runFanout` further (the fan-out loop, per-host summary printing, and aggregation footer could become `runConcurrent`, `renderFanoutSummary`).~~ **Partially done** — `renderFanoutSummary` extracted. `runFanout` shrank from 211 → 147 lines (−30%); `renderFanoutSummary` is a 75-line self-contained helper that takes `(slots, {logLabel, verbose, showCapturedOutput})` and returns `{failCount}`. The `runConcurrent` extraction was **intentionally dropped** — grep confirmed zero other callers in the codebase, making it a premature one-caller hoist with no consolidation payoff. Net runner.js delta: +18 lines (cognitive win, not LOC win — the split boundary has its own header comment cost). Bumped `VERSION` to `3.0.2`.
- ~~**`die()` consolidation** — move to a shared `errors.js` so the four copies become one.~~ **Done** — `share/playbash/errors.js` exports the sole copy; `executable_playbash`, `runner.js`, `transfer.js`, `commands.js`, and `inventory.js` all import it. Net –13 lines.
- ~~All P2 items from the code review.~~ The original list was captured in a prior conversation and isn't in any dev-docs file or memory. A fresh audit was run (via the Explore agent + manual cross-checking) as a substitute. Verified-and-fixed items landed in version `3.0.5`:
  - **`STAGING_DIR` / `WRAPPER_MANAGED` duplicated** between `paths.js` and `staging.js` — leftover from Phase 1 (`paths.js` was created but `staging.js`'s originals were never removed). Both files exported the same literal; `runner.js` imported them from `staging.js` rather than the authoritative `paths.js`. Fixed by removing the duplicates from `staging.js`, having `staging.js` import `STAGING_DIR` from `paths.js` for internal use, and updating `runner.js` to import both constants from `paths.js`.
  - **Magic number `60` for `statusWord` truncation** in three call sites (`runner.js:965`, `runner.js:1006`, `transfer.js:127`) — plus silent truncation: a long error message got cut off with no indication. Fixed by exporting `STATUS_WORD_MAX_LEN = 60` from `render.js` plus a `truncateStatus(msg)` helper that appends `…` when truncation occurs. All three call sites now use the helper. The `doctor.js:106` `.slice(0, 60)` is a separate semantic context (ssh error classification) and was left alone.
  - **`subprocess.js:21`** — local `timed` variable returned as `timedOut: timed`. Minor naming drift from the Phase-P1-4 hoist. Renamed `timed` → `timedOut` throughout so the closure matches the returned field name.

  Invalidated findings (false alarms from the audit, documented so they don't get re-reported):
  - `Math.max(...arr)` "empty array crash" in `commands.js:126,141` — both sites are guarded by `if (arr.length > 0)`.
  - Same in `doctor.js:326` (checks built from a fixed list, never empty) and `doctor.js:338-339` (guarded by `if (hosts.length === 0) return`).
  - Same in `render.js:261` (`StatusBoard` constructed only from `runFanout`, which runs only when `targets.length >= 2` because `dispatch` catches `targets.length === 1` first).
  - `cleanupAndExit` "unhandled rejection" — `killRemoteWrapper` is documented as never-throwing and `process.exit(130)` fires unconditionally afterwards.
  - `idleTimer/killTimer` "resource leak" — the agent itself noted "No actual leak" in the finding.
- ~~Bug fixes B-1 through B-6 from the code review.~~ Not accessible. Covered by the fresh audit above; three real items found and fixed (listed under P2 above). The remaining agent-reported items were invalidated when cross-checked against actual code.
