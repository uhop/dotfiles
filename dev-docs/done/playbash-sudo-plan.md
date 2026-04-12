# Playbash — sudo password support plan

Design and implementation plan for letting playbash playbooks use `sudo` commands that require a password, instead of aborting with `needs sudo`.

## Progress

| Phase | Status | Notes |
|---|---|---|
| 0 — local PoC | ✅ | All 4 experiments pass. Bare `pty.fork` injection works (0a). Current wrapper blocks (0b, expected). Patched wrapper with stdin relay works (0c). Wrong password correctly detected (0c-wrong). |
| 1 — remote PoC | ✅ | Mock-sudo over ssh (1b, 1c) and real sudo-rs (1-real) all pass. Password not echoed. Prompt matches existing regex. |
| 2 — wrapper patch | ✅ | Production `playbash-wrap.py` patched with stdin relay. Deployed to nuke + mini. All backward-compat tests pass (exec, run, debug, fan-out). |
| 3 — runner integration | ✅ | `--sudo` flag, `promptPassword()`, stdin pipe spawn, prompt-count-based injection, wrong-password detection via `WRONG_PASSWORD_RE` + second-prompt count. Two bugs found and fixed during testing: (1) clearing `recentBuf` after injection dropped the error message when it arrived in the same chunk — fixed by counting prompts instead; (2) `killChild` sent SIGTERM but the ssh ControlMaster kept pipes open, preventing the `close` event — fixed by destroying stdio streams after SIGTERM. |
| 4 — completion/USAGE | ✅ | `--sudo` in USAGE lines for run/push/debug/exec, Options section, and bash completion. VERSION bumped to 3.2.0. |
| 5 — verification | ✅ | Full test matrix: correct password single-host (0.4s), correct password fan-out nuke+mini (1.3s, asked once), wrong password (2.9s, `wrong password`), no-`--sudo` with sudo command (0.4s, `needs sudo`), full regression sweep (exec, run, list, hosts). |

### Phase 0 findings

- Writing to the PTY master from the parent delivers bytes to the child's terminal input — confirmed.
- The wrapper's stdin relay is a ~20-line addition to the poll loop. When stdin is `/dev/null` (the non-sudo case), `os.read(0, ...)` returns EOF immediately; the wrapper unregisters fd 0 and proceeds with zero overhead.
- Wrong-password detection via `Sorry, try again` works. The mock-sudo echoes the password because its `stty -echo` only applies to the child's tty, not the PTY master. Real `sudo` calls `tcsetattr` on its stdin (which IS the PTY slave fd), so it properly disables echo — the password won't leak into the output stream with real sudo. Still, the runner should treat any bytes it injects as invisible and not log them.
- `sudo-rs` is the actual sudo on both local and remote hosts (Rust reimplementation). Need to verify the prompt format matches `STDIN_PROMPT_RE` during Phase 1.

### Phase 1 findings

- Mock-sudo over ssh to nuke: full pipeline works (exp 1b). Wrong password detected (exp 1c).
- `sudo-rs` prompt format is `[sudo: authenticate] Password:` — matches existing `STDIN_PROMPT_RE` (the `\[sudo[^\]]*\]\s*[Pp]assword` branch).
- `sudo-rs` wrong-password message is `sudo: Authentication failed, try again.` — does NOT match the existing `Sorry, try again` pattern. **Action for Phase 3:** add `Authentication failed` to the wrong-password detection regex.
- Real-sudo test (`exp1-real-sudo.mjs`): **SUCCESS**. `sudo-rs` properly disables TTY echo via `tcsetattr` on the PTY slave — password does not appear in the output stream. The `\r\n` after injection is sudo's own newline after accepting input, not the password. Full pipeline verified: Node stdin pipe → ssh → sshd → wrapper stdin relay → PTY master → sudo reads from PTY slave.

## Status quo

Playbash today **refuses** to handle password prompts. The runner spawns ssh with `stdio: ['ignore', 'pipe', 'pipe']` — stdin is not connected. A regex detector watches the PTY output for known password prompts (`[sudo] password`, `doas ... password:`, etc.) and kills the process on match, surfacing a `needs sudo` status. The operator is expected to pre-configure passwordless sudo (`/etc/sudoers.d/` NOPASSWD rules or `doas permit nopass`).

This works well for the managed fleet where chezmoi deploys sudoers rules. It breaks down for:
- Vanilla hosts where the operator cannot (or hasn't yet) configured passwordless sudo.
- One-off `exec` commands that need root: `playbash exec newhost 'sudo apt update'`.
- `put` to root-owned paths: `playbash put host /etc/nginx/nginx.conf /etc/nginx/nginx.conf` (a future feature gated on sudo support, per the roadmap).

## Research summary

### Mechanisms evaluated

| Mechanism | How | Security | Playbash fit |
|---|---|---|---|
| **PTY stdin injection** | Connect stdin to ssh child as a pipe; write password bytes when prompt is detected | Password in Node process memory only; never on disk; never in logs if filtered. Same model as expect/pexpect. | Best general fit — works with any program, not just sudo |
| `sudo -S` (stdin) | `echo pw \| sudo -S cmd` | Password visible in `ps`, shell history, /proc | Bad — password leaks to process table |
| `sudo -A` / `SUDO_ASKPASS` | Askpass program echoes password to stdout | Requires an askpass script staged on remote with password inside it (on disk, even if temporary) | Viable for sudo-only, but password on remote disk is a downgrade |
| `doas` equivalent | No `-A`/askpass mechanism. Only `doas -S` (same as `sudo -S`) | Same as `sudo -S` | Bad |
| `pam_ssh_agent_auth` | PAM module verifies sudo via ssh-agent challenge/response | Excellent — no password at all | Excellent security but requires PAM config on every host; heavy deployment burden |
| expect/pexpect | Spawn with PTY, match output, send input | Password in process memory | This is essentially what PTY stdin injection is |

### Winner: PTY stdin injection

The runner already allocates a PTY (via `playbash-wrap.py`) and already detects password prompts (via `STDIN_PROMPT_RE`). The only missing piece is: instead of killing on match, **pause and ask the operator, then write the password to the ssh child's stdin pipe**. This is the `expect` model, implemented at the runner level.

Why this wins over the alternatives:
- **No password on remote disk** — the password travels through the ssh pipe into the PTY, exactly as if the operator typed it. `sudo` reads from its controlling terminal (the PTY). No file, no askpass script, no environment variable.
- **Works with `doas` too** — doas also reads from its controlling terminal. No `-A` equivalent needed.
- **Generalizes to any prompt** — the same mechanism can answer `[Y/n]` prompts, `read -p` prompts, or any interactive program. The sudo case is the first use; general prompts are a natural extension.
- **No playbook changes** — existing playbooks that call `sudo` or `doas` work unchanged. No `playbash_sudo` wrapper needed.

### Security assessment of the chosen approach

- **Password in Node process memory**: unavoidable with any approach. Node strings are GC'd, not securable-zeroed. Acceptable — the operator's terminal emulator holds the same string.
- **Password traverses ssh**: encrypted in transit (same as typing it manually over ssh).
- **Password in PTY stream**: sudo disables terminal echo before reading, so the password does NOT appear in the PTY output that the runner captures. The runner should still suppress any bytes it writes to stdin from the log/rectangle/tail as a defense-in-depth measure.
- **Password in the log file**: never — the log captures PTY *output*, and sudo's echo-off prevents it from appearing there. The injected bytes go to *stdin*, which flows the other direction.
- **Fan-out**: password asked once, cached in memory for the session, injected to each host as it hits the prompt. Cleared when the runner exits (process death = memory freed).

### The `playbash_sudo` alternative (evaluated and set aside)

A `playbash_sudo` bash helper in `playbash.sh` was considered:

```bash
playbash_sudo() {
  if [ -n "${PLAYBASH_SUDO_ASKPASS:-}" ]; then
    SUDO_ASKPASS="$PLAYBASH_SUDO_ASKPASS" sudo -A "$@"
  else
    sudo "$@"
  fi
}
```

The runner would stage an askpass script on the remote containing the password. This was set aside because:
- Password ends up on remote disk (even temporarily, even mode-700).
- Requires playbook changes (replace `sudo` with `playbash_sudo`).
- Does not work with `doas` (no askpass mechanism).
- Does not generalize to non-sudo prompts.
- More complex staging (one more file to upload, clean up, handle crash recovery for).

This is listed as the fallback if PTY stdin injection proves unworkable for some unforeseen reason.

## UX design

### CLI surface

```
playbash run   <targets> <playbook> [--sudo] [-n LINES] [-p N] [--self]
playbash exec  <targets> [--] <command...> [--sudo] [...]
playbash push  <targets> <script-path> [--sudo] [...]
playbash debug <targets> <playbook> [--sudo] [--self]
```

`--sudo` enables password-prompt handling for the run. Without it, the existing detect-and-kill behavior is unchanged.

The flag is opt-in because:
- Most runs don't need sudo passwords (managed fleet has NOPASSWD rules).
- Prompting for a password changes the security model; the operator should consciously choose it.
- It's impossible to distinguish a "legitimate sudo prompt I should answer" from a "rogue program printing `Password:`" without the operator's intent signal.

### Prompt workflow

**Single-host run:**

```
$ playbash run newhost daily --sudo
Password for newhost:          ← runner prompts on stderr, no echo
· running daily on newhost
┌─────────────────────────────┐
│ [sudo] password for eugene: │  ← runner sees this, injects password
│ Hit:1 http://...            │  ← sudo succeeded, apt is running
│ ...                         │
└─────────────────────────────┘
✓ newhost daily in 45.2s
```

1. Runner detects `--sudo`, prompts operator for password **before** starting the run. One prompt, one read from the operator's TTY with echo disabled.
2. Run proceeds. When the regex matches a sudo/doas prompt in the PTY output, the runner writes `<password>\n` to the ssh child's stdin pipe.
3. If the password is wrong (regex matches `Sorry, try again`), the runner reports `wrong password` and kills the process — no retry loop (the operator can re-run with the correct password).

**Fan-out run:**

```
$ playbash run web,db daily --sudo
Password:                      ← asked once, before any host starts
running daily on 2 hosts

  web  [sudo] password for... → injected
  db   [sudo] password for... → injected

✓ web  daily in 38.1s
✓ db   daily in 41.7s
```

1. Password prompted once, before the fan-out starts.
2. Each host's prompt is answered independently (different hosts hit sudo at different times).
3. The password is the same for all hosts — this is a reasonable assumption since the operator has the same account name everywhere (chezmoi-managed fleet). If a host has a different password, it fails with `wrong password` and the operator deals with it.

### When NOT to prompt

- ~~`put`/`get` don't use `--sudo`~~ — **Shipped in v3.3.0.** `put`/`get` now accept `--sudo`, wrapping remote commands with `sudo -S sh -c '...'` and prepending the password to stdin. See `transfer.js` for the implementation.
- `doctor` never prompts — it's a read-only diagnostic.
- `list`/`hosts`/`log` — no remote execution.

### Password handling rules

1. **Ask before the run, not during.** Asking mid-run while a rectangle is active would require pausing rendering, which is complex. Asking up front is simpler and covers the common case (one password for all hosts).
2. **No caching across runs.** Each `playbash --sudo` invocation asks fresh. No keychain, no credential store. The password exists only for the lifetime of the process.
3. **No echo.** Read from the operator's TTY with echo disabled (raw mode read or Node's `readline` with `terminal: false` on a direct TTY fd).
4. **No retry.** Wrong password → kill the host's run, report `wrong password`. Re-run to try again. This avoids infinite retry loops and the complexity of re-prompting mid-run.
5. **Filter from output.** The injected `<password>\n` bytes written to stdin must never appear in the rectangle, log file, tail buffer, or stuck-input detector. Since they go to *stdin* (not stdout), this happens automatically — but if sudo echoes anything (it shouldn't, but belt-and-braces), the runner should strip it.

## Implementation plan

### Phase 0 — Local PTY stdin injection proof-of-concept

**Goal:** verify that writing to a PTY child's stdin actually delivers the password to `sudo`. Pure local, no ssh, no playbash.

**Experiment 0a — bare Python pty.fork + sudo:**

Write a ~30-line Python script:
1. `pty.fork()` a child that runs `sudo -k && sudo echo "authenticated"` (the `-k` invalidates any cached credential so the prompt always appears).
2. Parent polls the PTY master for output.
3. When output matches `[sudo] password`, write `<password>\n` to the PTY master fd.
4. Verify the child prints `authenticated` and exits 0.

Key question answered: does writing to the PTY master deliver bytes to the child's stdin? (Yes — that's how terminals work, but let's verify it in the specific `pty.fork` + `sudo` combination.)

**Experiment 0b — Node spawn with PTY (via the Python wrapper):**

Write a ~40-line Node script:
1. `spawn('python3', ['-u', 'playbash-wrap.py', 'bash', '-c', 'sudo -k && sudo echo authenticated'])` with `stdio: ['pipe', 'pipe', 'pipe']` — stdin as a pipe this time.
2. Read stdout, match the prompt regex.
3. Write `<password>\n` to `child.stdin`.
4. Verify `authenticated` appears in stdout.

Key question answered: does stdin piped into the wrapper → PTY master → child's terminal input? The wrapper currently doesn't read stdin at all (it only reads from the PTY master and writes to stdout). **This experiment will fail**, revealing the gap: the wrapper needs to relay stdin to the PTY master.

**Experiment 0c — wrapper with stdin relay:**

Patch `playbash-wrap.py` to also poll stdin (fd 0) and relay any bytes read to the PTY master fd. Re-run experiment 0b. Verify it works.

Key question answered: is the stdin→PTY relay in the wrapper sufficient? Are there timing issues (password written before sudo is ready to read)?

### Phase 1 — Remote PTY stdin injection

**Goal:** verify the same mechanism works over ssh.

**Experiment 1a — direct ssh with wrapper:**

```bash
# Terminal A: start the wrapper over ssh with stdin connected
ssh nuke -- 'python3 -u ~/.local/libs/playbash-wrap.py bash -c "sudo -k && sudo echo authenticated"'
# Type password when prompted
```

This should already work (ssh connects stdin to the remote's stdin, the patched wrapper relays it to the PTY). Verify.

**Experiment 1b — Node spawn of ssh with stdin pipe:**

Write a ~50-line Node script:
1. `spawn('ssh', [..., 'nuke', '--', 'python3 -u ... playbash-wrap.py bash -c "sudo -k && sudo echo authenticated"'])` with `stdio: ['pipe', 'pipe', 'pipe']`.
2. Match prompt in stdout, write password to `child.stdin`.
3. Verify `authenticated` appears.

This mimics what the runner will do. If the wrapper's stdin relay works from Phase 0c, this should work too.

**Experiment 1c — wrong password handling:**

Same as 1b but send the wrong password. Verify:
- sudo prints `Sorry, try again` (matched by existing regex).
- The script detects it and kills the child.
- Exit code is non-zero.

### Phase 2 — Wrapper stdin relay (production patch)

**Goal:** modify `playbash-wrap.py` to relay stdin→PTY, with minimal blast radius.

The change to the wrapper:
1. Register fd 0 (stdin) with the `select.poll` instance alongside the PTY master fd.
2. In the event loop, when fd 0 is readable, `os.read(0, 4096)` and `os.write(fd, data)` (write to PTY master, which delivers to child's terminal input).
3. When fd 0 hits EOF (POLLHUP), unregister it (no more input to relay). This is normal — stdin may close before the playbook finishes.

**Backward compatibility:** when stdin is `'ignore'` (the current runner behavior), fd 0 is `/dev/null`, which returns EOF immediately. The wrapper unregisters it on the first poll and behaves exactly as before. Zero change for non-`--sudo` runs.

**Testing:**
- Existing smoke tests (run, exec, push, debug, put, get, doctor, list, hosts) all pass unchanged.
- Experiment 1b passes.
- Mac target verification: run experiment 1b against `mini2`. The zero-byte stdout probe and the `os.close(fd)` before `waitpid` fix must coexist with the new stdin relay.

**Deployment note:** the wrapper is deployed via chezmoi to every managed host. Rolling out this change requires `chezmoi update` on each host. Old wrappers (without stdin relay) will silently ignore any stdin bytes the runner sends — the bytes arrive at sshd's stdin pipe for the channel, but if nobody reads them, they buffer harmlessly until the channel closes. No breakage, just no sudo support on stale hosts.

### Phase 3 — Runner integration

**Goal:** wire `--sudo` into the runner's spawn + prompt-detection pipeline.

#### 3a — Parse `--sudo` flag

Add `--sudo` to `parseArgs` in `executable_playbash`. Thread it through `dispatch()` to `runRemote`, `runLocally`, and `runFanout`.

#### 3b — Password prompt

When `--sudo` is set, before starting any ssh work:
1. Open `/dev/tty` directly (not process.stdin — that may be a pipe if the user is scripting).
2. Write `Password: ` to stderr.
3. Read one line with echo disabled.
4. Close `/dev/tty`.
5. Store the password string in a local variable.

If `/dev/tty` is unavailable (non-interactive context), die with a clear error: `--sudo requires an interactive terminal`.

#### 3c — Spawn with stdin pipe

When `--sudo` is active, change `CHILD_SPAWN_OPTS` for this run from `stdio: ['ignore', 'pipe', 'pipe']` to `stdio: ['pipe', 'pipe', 'pipe']`. The ssh child now has a writable stdin.

#### 3d — Prompt detection → inject instead of kill

The `stdinWatch` logic in `runHost` currently does:
1. Match `STDIN_PROMPT_RE` against the sliding window.
2. On match: SIGTERM the child, set `stuckReason = 'needs sudo'`.

With `--sudo` active, change step 2:
1. On first match of a password prompt: write `<password>\n` to `child.stdin`.
2. Reset the sliding window (so the same prompt text doesn't re-trigger).
3. Set a flag `passwordInjected = true`.
4. If `Sorry, try again` is subsequently matched: this means wrong password. SIGTERM the child, set `stuckReason = 'wrong password'`.
5. If a second password prompt is matched after injection (without `Sorry, try again` first): also treat as wrong password. SIGTERM.

Without `--sudo`, the existing kill-on-match behavior is unchanged.

#### 3e — Fan-out threading

In `runFanout`, the password is captured once (in 3b) and passed to each `launchOne` call. Each host's `runHost` invocation gets its own `child.stdin` pipe and performs injection independently — hosts hit sudo at different times, and each needs the password written to its own pipe.

#### 3f — `--self` path

For `--self` runs (local child, no ssh), the child is spawned via `spawn(childCmd, childArgs, ...)`. Same change: `stdio[0]` becomes `'pipe'` when `--sudo` is active. Password injection works identically — the password goes to the local bash child's stdin, which the PTY delivers to sudo.

### Phase 4 — Completion and USAGE

1. Add `[--sudo]` to USAGE lines for `run`, `push`, `debug`, `exec`.
2. Add `--sudo` to bash completion for those subcommands.
3. Add a line to the Options section: `--sudo  prompt for a password and inject it when sudo/doas asks`.

### Phase 5 — Verification

Follow the plan's testing matrix:

- **Smoke (no --sudo):** `playbash run nuke hello`, `playbash exec nuke 'echo hi'`, `playbash debug nuke daily`, `playbash push nuke /tmp/test.sh`, `playbash list`, `playbash hosts`, `playbash doctor`. All must behave identically to pre-change.
- **Single-host sudo:** `playbash exec nuke --sudo 'sudo -k && sudo echo authenticated'` — prompts, injects, prints `authenticated`.
- **Single-host wrong password:** same but type wrong password — prints `wrong password`, exits non-zero.
- **Fan-out sudo:** `playbash exec nuke,mini --sudo 'sudo -k && sudo echo authenticated'` — prompts once, both hosts succeed.
- **Fan-out mixed:** one host needs sudo, another doesn't (pre-configure NOPASSWD on one). Both should succeed — the password is injected only when the prompt appears; the other host never prompts.
- **Debug + sudo:** `playbash debug nuke daily --sudo` — verbose output, password injected, no rectangle.
- **Mac target:** `playbash exec mini2 --sudo 'sudo -k && sudo echo authenticated'` — verify the wrapper's macOS PTY quirks don't interfere with stdin relay.
- **No --sudo, sudo prompt:** `playbash exec nuke 'sudo -k && sudo echo hi'` (no `--sudo` flag) — must still kill with `needs sudo`, unchanged behavior.
- **Stale wrapper:** temporarily revert the wrapper on one host (remove stdin relay). Run `--sudo` against it. Expected: password is written to ssh stdin, nobody reads it, sudo prompt hangs, idle timeout fires, host reports `stuck (idle)`. Acceptable degradation.

### Phase 6 (optional) — General prompt routing

**Goal:** let the operator answer arbitrary interactive prompts, not just sudo passwords.

This is a natural extension of Phase 3 but changes the UX significantly:

- Instead of asking for the password up front, the runner would detect *any* prompt and forward it to the operator's terminal in real time.
- The operator types a response, which is relayed to the remote.
- This is essentially an interactive ssh session tunneled through the runner's rendering pipeline.

**Design sketch (not for immediate implementation):**

1. New flag: `--interactive` (or `-i`). Mutually exclusive with `--sudo` in fan-out (can't type into multiple hosts at once).
2. When a prompt is detected (via a more general regex or an idle-output heuristic), the rectangle pauses and the runner switches to "passthrough mode" — stdin from the operator's TTY flows directly to the child's stdin.
3. When the prompt is answered (output resumes), the runner switches back to rectangle mode.
4. Only works for single-host runs (fan-out with interactive prompts is a UX nightmare).

This is a separate feature with its own design conversation. Mentioning it here because the PTY stdin relay (Phase 2) is the enabling primitive — once the wrapper can relay stdin, both `--sudo` and `--interactive` are possible.

## Wrapper change detail

The wrapper change is the smallest and most critical piece. Here is the exact diff:

```python
# Current: only polls the PTY master
p = select.poll()
p.register(fd, select.POLLIN | select.POLLHUP | select.POLLERR)

# New: also poll stdin for relay
p = select.poll()
p.register(fd, select.POLLIN | select.POLLHUP | select.POLLERR)
stdin_open = True
try:
    p.register(0, select.POLLIN | select.POLLHUP | select.POLLERR)
except Exception:
    stdin_open = False  # stdin may be /dev/null or closed

# In the event loop, add a branch for fd 0:
for efd, ev in events:
    if efd == 0 and stdin_open:
        if ev & select.POLLIN:
            try:
                d = os.read(0, 4096)
            except OSError:
                p.unregister(0)
                stdin_open = False
                continue
            if not d:
                p.unregister(0)
                stdin_open = False
                continue
            try:
                os.write(fd, d)  # relay to PTY master → child's stdin
            except OSError:
                pass
        elif ev & (select.POLLHUP | select.POLLERR):
            p.unregister(0)
            stdin_open = False
    elif efd == fd:
        # ... existing PTY master handling unchanged ...
```

When stdin is `'ignore'` (no `--sudo`), fd 0 is `/dev/null`. `os.read(0, ...)` returns `b""` (EOF) immediately. The wrapper unregisters fd 0 and proceeds as before. Zero overhead for the common path.

## Risks

- **Wrapper deployment dependency.** The wrapper must be updated on every host before `--sudo` works there. Stale wrappers degrade gracefully (idle timeout, not a crash), but the operator sees `stuck (idle)` instead of `wrong password` or `needs sudo`. The `playbash doctor` output could be extended to show the wrapper version on each host — but that's a separate enhancement.
- **Password echo edge case.** If sudo's terminal configuration fails and it echoes the password, the password appears in the PTY output stream → rectangle → log. Defense-in-depth: the runner could suppress the first line of output that appears immediately after password injection (within ~100ms). But this is speculative — sudo has disabled echo since forever. Don't over-engineer for it.
- **macOS `waitpid` interaction.** The existing `os.close(fd)` before `waitpid` fix is load-bearing for macOS sudo. The stdin relay adds fd 0 to the poll set, but since we unregister and stop reading from it before the finally block, it should not interact with the PTY master close. Verify on `mini2`.
- **Timing.** The runner writes the password to ssh's stdin pipe. The bytes travel: ssh stdin → sshd channel → wrapper stdin → wrapper reads → writes to PTY master → sudo reads from PTY slave. There may be a small delay. If the runner writes too early (before sudo is ready to read), the bytes sit in the PTY's input buffer, which is fine — terminals buffer input. If the runner writes too late... it can't, because the prompt has already appeared, which means sudo is already waiting.
- **Multiple sudo calls in one playbook.** A playbook might call sudo multiple times. Each call may or may not prompt (sudo caches credentials for ~5 minutes by default). The runner should inject the password on *each* prompt match, not just the first. The "one injection, then kill on retry" logic should track per-prompt, not globally.

## Version

Ships as `3.2.0` — new user-visible flag (`--sudo`), changed wrapper behavior (stdin relay).
