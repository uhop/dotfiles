# Playbash — roadmap

Status checklist for `playbash`, the multi-host bash playbook runner that replaced our ansible-based maintenance stack. For technical rationale and protocol details see [`playbash-design.md`](./playbash-design.md). For the original motivation see [`ansible-replacement.md`](./ansible-replacement.md).

## Status

- **v1 (proof of concept)** — ✅ done
- **v2 (production polish + dogfooding)** — ✅ done
- **v3 (portability to vanilla hosts)** — in progress; first two prep milestones done

`playbash` has fully replaced the previous ansible setup. Daily and weekly cron runs across the fleet go through `playbash run daily all` / `playbash run weekly all`. Mac targets are supported end-to-end (verified during the milestone-10/11 PTY work).

## Done — v1

1. **Walking skeleton.** ✅ `playbash run echo localhost` against a hardcoded inline `echo` over ssh, then a real preinstalled `playbash-hello` script invoked via `ssh host -- ~/.local/bin/playbash-hello`. Per-run log file, status line, exit-code propagation.
2. **Helpers + sidecar.** ✅ `playbash.sh` with `playbash_info`/`warn`/`error`/`action`/`reboot`/`step`. JSON-lines sidecar at a randomly-named `/tmp` path on the remote, fetched in one extra ssh round trip after the playbook exits. Per-host summary grouped by level. Pretty-print fallback to stderr when `$PLAYBASH_REPORT` is unset (manual debugging).
3. **PTY rectangle renderer.** ✅ Last-N-lines live view with `-n LINES` (default 5, `-n 0` disables). Full uncut byte stream on disk.
4. **Inventory + CLI polish.** ✅ Subcommand dispatcher (`run`, `debug`, `list`, `hosts`). JSON inventory at `~/.config/playbash/inventory.json` with string/object/array shorthand. `playbash list` globs `~/.local/bin/playbash-*`. `playbash hosts` aligned columns. Sub-milestone 4.5 added self detection by IP (`os.networkInterfaces()` + `dns.lookup`) and the `--self` flag for local execution as a child process.
5. **Port one real playbook and dogfood it.** ✅ `playbash-daily` and `playbash-weekly` ported (orchestrate `chezmoi update`, `dcms`, `upd -y`/`upd -cy`). Three real bugs found and fixed during dogfooding: switched from `ssh -tt` to remote `script(1)` to eliminate OSC/CPR query echo-back, added a sanitizer that strips terminal-hostile escapes (keeping SGR colors), and fixed `Rectangle.feed` to treat `\r\n` as a single line ending. Added `playbash log [path]` for safely viewing log files.

## Done — v2

6. **Output polish.** ✅ Per-host summary uses minimal color (green ✓, bold-white-on-red ✗ block, magenta ⏵ for actions, orange ⚠ for warnings — orange chosen for dark/light terminal compatibility). No section headers (each event has its own glyph), log path printed only on failure. `NO_COLOR` and `PLAYBASH_NO_COLOR` env overrides honored.
7. **Groups + parallel fan-out.** ✅ Comma-separated CLI lists, group expansion (no recursion), implicit `all`, self-exclusion with notice (`--self` flips it). Single resolved target uses the live rectangle; multiple targets switch to a `StatusBoard` with parallel runs (default unlimited, `-p N` to cap). Sticky most-recently-active focused-host rectangle. Per-host summaries in input order, cross-host aggregation at the end. Continue-on-failure, exit code 1 if any host failed.
8. **File split + reorg.** ✅ Runner split into entry + three modules (`render.js`, `inventory.js`, `sidecar.js`) under `private_share/playbash/` (deployed private). General-purpose helpers (`comp.js`, `semver.js`, `nvm.js`) moved to `private_share/utils/`.
9. **`upd`/`cln` refactor.** ✅ New `~/.local/libs/maintenance.sh` providing `report_reboot`, `report_warn`, `report_action`. Inlined JSON writer; no `playbash.sh` dependency. `maintenance::snapshot_apt` + `maintenance::check_apt_since` snapshot the apt history-log byte position before each script's apt operations and scan the diff after, detecting docker-related upgrades, AppArmor upgrades (with eager `aa-remove-unknown` + recovery-marker file), and `/run/reboot-required`. Both `upd` and `cln` source the helper and call `cleanup_apparmor_if_marked` at startup as the recovery path for interrupted runs. Per-host renderer dedupe and per-host aggregator dedupe collapse identical events from multiple sources into one user-visible line.
10. **Interactive input detection.** ✅ Stdin-watch regex over the captured PTY stream catches `sudo`/`doas`/`Password:`/`Sorry, try again.`/`[Y/n]` etc., with `LC_ALL=C` forced on the remote side so prompts are predictable; on match the runner kills the local ssh process group and reports `needs sudo` as a distinct per-host status. Idle-output watchdog default 90s. The Linux-only `/proc/$pid/wchan` precise path was deferred — the regex was sufficient for every prompt encountered in dogfooding.
11. **Cross-platform PTY wrapper (Mac target support).** ✅ Replaced the Linux-only `script(1)` wrap with `~/.local/libs/playbash-wrap.py`, a small Python PTY wrapper deployed to every chezmoi-managed host. Same wrapper runs unmodified on Linux and Mac targets. Two Mac-specific bugs had to be fixed before the kill path propagated end-to-end: a 1-second `os.write(1, b"")` probe to compensate for `select.poll()` not delivering `POLLHUP` on Darwin, and `os.close(fd)` on the PTY master before `waitpid` to avoid a kernel-level deadlock where bash got stuck in `?Es` mid-exit while the controlling terminal couldn't be revoked. The Linux→Mac sudo-prompt path is now verified end-to-end. See [playbash-design.md § PTY allocation](./playbash-design.md#pty-allocation) and [playbash-debugging.md](./playbash-debugging.md) for the rationale and the full debugging trail.
12. **`upd --restart-services` flag.** ✅ When set AND a docker-related upgrade is detected, `maintenance::restart_docker_services` runs `sudo systemctl restart containerd && sudo systemctl restart docker` to recover without a full reboot, falling back to `report_reboot` if either restart fails. The doas whitelist entries for these commands are in `run_onchange_before_install-packages.sh.tmpl:213-214`; existing hosts may need a manual `/etc/doas.conf` update.

## Done — v3 prep

13. **`PLAYBASH_LIBS` env override.** ✅ `playbash.sh` and the in-tree playbooks honor `"${PLAYBASH_LIBS:-$HOME/.local/libs}"` instead of hard-coding `~/.local/libs`. Zero behavior change for chezmoi-managed hosts (the default expands to the same path). Prerequisite for milestone 16 (upload mode): when the runner stages helpers into a scratch dir, the playbook needs to find them there.

## Next — v3 priority order

Goal: run playbash against any Linux/Mac host with `bash`, `ssh`, and `python3` (≥ 3.9) without requiring chezmoi or any pre-deployment. Heterogeneous fleets (mix of chezmoi-managed and vanilla hosts) are first-class.

**ssh authentication requirement.** All ssh invocations from the runner are non-interactive: the spawn uses `stdio: ['ignore', 'pipe', 'pipe']` AND `detached: true` (which calls `setsid(2)`, leaving the child without a controlling terminal). ssh therefore has nowhere to prompt for a key passphrase or remote password. **Passwordless ssh is a hard requirement** (same as ansible / pyinfra / fabric): the operator must have either ssh-agent running with the key loaded, or public-key auth pre-configured per host. As of v3 every ssh spawn passes `-o BatchMode=yes` so any auth that would require interaction fails immediately with a clear error message. Bootstrapping a vanilla host's `~/.ssh/authorized_keys` is an interactive setup step done outside the runner (see [Future](#future)).

14. **Wrapper staging primitive.** Internal helper that ensures the python wrapper is present on a remote host before a run. For chezmoi-managed hosts, no-op — the wrapper is already at `~/.local/libs/playbash-wrap.py`. For vanilla hosts, `mktemp -d` once per host, push the wrapper (probably via `cat <wrapper> | ssh host 'cat > <staging>/playbash-wrap.py'` since the wrapper is small and this avoids depending on `scp`/`rsync`), return the staging dir path. Result cached locally under `~/.cache/playbash/staging/<hostkey>/` keyed by the wrapper's sha so a `chezmoi apply` that updates the wrapper naturally invalidates all per-host staging dirs. No user-visible CLI surface — substrate consumed by milestones 15, 16, and 17.

    **Detection strategy is a design decision.** Two reasonable shapes: (a) probe-and-cache — try the chezmoi path first, fall back on `python3: No such file or directory`; or (b) explicit inventory marker — new `chezmoi: false` (or `vanilla: true`) field on the host entry that opts in to upload mode deterministically. (a) is more invisible, (b) is more predictable. Probably ship both — probe by default, marker as an override.

    **`BatchMode=yes` rolled in.** Every ssh invocation introduced by this milestone — *and* the existing `runRemote()` / `runFanout()` ssh spawns, updated in the same patch — passes `-o BatchMode=yes`. Auth failures become fast and deterministic instead of confusing: ssh exits immediately with `Permission denied (publickey,password)` rather than failing to open `/dev/tty` after a delay.

15. **`playbash exec <host> <command...>`.** One-shot command execution through the same wrapper / sidecar / rectangle pipeline as `playbash run`, without a playbook script. The wrapper invokes `bash -c '<command>'` instead of `exec <script>`. No `playbash.sh` dependency on the remote, so the only thing staged is the wrapper itself (via milestone 14). Same fan-out shape as `run`: groups, parallel, per-host status board, per-host log file. Sidecar is empty for exec (or could be repurposed for a stdout/stderr split — decide during implementation). Useful for "run this on every server right now" without authoring a playbook script first.

16. **Upload mode for `playbash run`.** Extends milestone 14 to also stage `playbash.sh` and the resolved playbook script (`~/.local/bin/playbash-<name>` on the operator) into the same scratch dir. Sets `PLAYBASH_LIBS=<scratch>` so the playbook's `source` directive picks up the staged copy (uses the env override from milestone 13). New `runRemoteUpload()` mirrors `runRemote()`; `dispatchRun()` picks between them based on per-host capability detection from milestone 14, transparently from the user's point of view.

    **Caveat documented prominently in `playbash --help` and the user-facing milestone description:** only *self-contained* playbooks work on vanilla hosts — `playbash-hello`, `playbash-sample`, and any custom one-off that depends on nothing beyond `playbash.sh`. Orchestration playbooks (`playbash-daily`, `playbash-weekly`) won't, because they invoke `upd`/`cln`/`dcms`/`chezmoi` which are themselves chezmoi-managed scripts not bundled by upload mode. Bundling transitive shell-script dependencies is a separate, much larger problem that does **not** belong in v3.

17. **`playbash put` / `playbash get`.** User-facing file staging primitives built on the same transfer machinery as milestone 14. `playbash put <local-path> <hosts>:<remote-path>` and `playbash get <hosts>:<remote-path> <local-path>`. Same fan-out, parallel, group expansion, and per-host status board as `run`. Useful for "ship this config file everywhere" or "fetch yesterday's log from every host" workflows. Implementation note: mostly a thin wrapper around `scp` (or `rsync` when available, falling back to `scp`) with the playbash UX on top.

18. **Offline host detection.** Pre-flight check before any ssh work, so an offline host fails fast with a distinct status instead of clogging the fan-out for 30+ seconds while ssh times out. Implementation: `ssh -o ConnectTimeout=2 -o BatchMode=yes <host> true` once per target at the start of the run, parallelized across the target list. Uses the actual ssh path so jump hosts, port overrides, and key selection from `~/.ssh/config` apply for free. Surface offline hosts as a distinct status in the StatusBoard (e.g. `· web2 offline`) and the post-run summary; exclude them from success/failure counts. Add a `--no-precheck` escape hatch. Independent of the rest of v3 — could land before milestone 14 if convenient.

19. **Bash completions.** Subcommands (`run`, `debug`, `list`, `hosts`, `log`, plus the new v3 ones), playbook names (glob `~/.local/bin/playbash-*`), host names and group names (read from `~/.config/playbash/inventory.json`), `--self` / `-n` / `-p` / `--no-precheck`. Match the `--bash-completion` convention used by other CLIs in this repo: `playbash --bash-completion` prints a completion script to stdout. Big DX win — host name and playbook name completion alone makes the tool dramatically faster to drive interactively. Independent of the portability work — slot in whenever convenient.

### Open questions for v3

Decide during implementation, not before.

- **Python version floor.** The wrapper currently uses `os.waitstatus_to_exitcode` (Python 3.9+). Vanilla hosts on older distros (RHEL 7, Ubuntu 18.04, etc.) ship 3.6. Either bump the minimum with a clear pre-flight error, or replace the call with portable bit-shift logic (`os.WEXITSTATUS` / `os.WTERMSIG` / `os.WIFSIGNALED` / `os.WIFEXITED`). The latter is ~5 lines and eliminates the floor entirely — probably do that during milestone 14 since it's a one-time wrapper edit.
- **Transfer mechanism.** scp is universal but deprecated upstream. rsync is faster for repeats and handles partial transfers, but requires the binary on both ends. `cat <local> | ssh host 'cat > <remote>'` is the most portable (no extra binary needed) and fine for small files like the wrapper. Probably `cat | ssh` for the wrapper itself, and scp/rsync for `playbash put`/`get` where users may transfer large files. Decide per call site.
- **Staging cleanup lifecycle.** When does a stale staging dir on a remote get removed? Three options: never (fine in principle — they're under `mktemp` and harmless), explicit `playbash clean <host>`, or automatic on next contact when the local cache invalidates. Probably ship "explicit clean command" + "automatic-on-cache-invalidation"; skip "never" because vanilla hosts may not have `tmpwatch` cron.
- **Inventory schema bump.** If the explicit `vanilla: true` (or `chezmoi: false`) marker lands as part of milestone 14, the inventory loader needs to accept the new field without breaking older inventories. Default-false keeps backward compatibility.

## Future

Beyond v3. These are real wants flagged by the user and worth their own design conversations before coding.

- **`playbash bootstrap <host>`.** Interactive setup helper for vanilla hosts: runs `ssh-copy-id` (or its equivalent) to push the operator's public key into `~/.ssh/authorized_keys` on the target, then verifies that subsequent non-interactive ssh works. Explicitly NOT in v3 because it's interactive — runs against the v3 runner's "no stdin to remote, no `/dev/tty`, `BatchMode=yes`" architecture and needs its own UX. Pairs with the "sudo support" item below as the second "interactive setup" thing that needs its own design conversation. Until this lands, the documented workflow for a new vanilla host is "run `ssh-copy-id host` once by hand, then use playbash."
- **`sudo` support.** The unsolved problem from [ansible-replacement.md § Unsolved: sudo password](./ansible-replacement.md#unsolved-sudo-password). Currently scripts are assumed to never ask, and milestone 10's "needs sudo" detection lets the runner abort cleanly when a prompt appears. Actually *answering* the prompt is a different problem. The right shape is unclear and worth a real design conversation before any code — the trade-offs around password handling, certificate-based sudo, sidecar-driven elevation, and detect-and-abort all need to be on the table together.

## Wiki sync followup

When v3 ships, re-audit the four `external_wiki/` files that mention playbash. Vanilla-host workflow + `playbash exec`/`put`/`get`/`bootstrap` will reshape the user-facing surface significantly.

- `Playbash-Server-Management.md` — primary doc; will need the most edits.
- `Utilities.md` — likely a one-line entry; spot-check.
- `Home.md` — index page; check the playbash blurb / link.
- `Application-Notes.md` — usage notes; spot-check anything that touches playbook authoring or `upd` flags.
