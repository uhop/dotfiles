# TTY Simulation for Piped Commands

## Problem Statement

Some utilities check if stdout or stderr is a TTY using `isatty()` and change their behavior accordingly (e.g., disable colors, progress bars, or formatting). When piping to `tee`, these commands detect a non-TTY and change behavior, but the user wants both:
1. TTY-like behavior (colors/formatting) from the command
2. The output captured to a file while still displaying on terminal

## Solution: The `script` Command

The `script` command is the only widely-available solution that requires no third-party tools. It creates a pseudoterminal (PTY) that tricks commands into thinking they have a TTY.

**Availability**: Pre-installed on Linux (util-linux package) and macOS/BSD (base system).

## Implementation

### Linux (util-linux ≥ 2.36)

**With pipe to tee:**
```bash
script -q -c "your_command" /dev/null | tee output.log
```

**Without pipe (script logs directly):**
```bash
# Logs to typescript file, output still shown on terminal
script -q -c "your_command" output.log
```

Note: The log file contains raw terminal output including ANSI escape sequences.

**Flags:**
- `-q` : Quiet mode (suppresses "Script started..." messages)
- `-c "cmd"` : Execute command directly instead of interactive shell
- `/dev/null` : Log file for `script` itself (discarded, since we capture output via pipe)

### macOS / BSD

**With pipe to tee:**
```bash
script -q /dev/null your_command | tee output.log
```

**Without pipe (script logs directly):**
```bash
# Logs to typescript file, output still shown on terminal
script -q output.log your_command
```

Note: The log file contains raw terminal output including ANSI escape sequences.

### Cross-Platform Detection

```bash
#!/bin/bash

# Detect which script version we have
if script -V 2>/dev/null | grep -q util-linux; then
    SCRIPT_VERSION="util-linux"
else
    SCRIPT_VERSION="bsd"
fi

run_with_tty() {
    local cmd="$1"
    shift
    local logfile="${1:-output.log}"

    if [[ "$SCRIPT_VERSION" == "util-linux" ]]; then
        script -q -c "$cmd $*" /dev/null | tee "$logfile"
    else
        script -q /dev/null "$cmd" "$@" | tee "$logfile"
    fi
}
```

## Can `script` Replace `script | tee`?

**Yes**, with caveats. The `script` command by default:
1. Displays output on the terminal (via the PTY)
2. Logs all output to a file (the "typescript")

**Comparison:**

| Approach | Pros | Cons |
|----------|------|------|
| `script -c "cmd" /dev/null \| tee log` | Clean text file, no escape sequences | Requires pipe, stdout becomes non-TTY after pipe |
| `script -c "cmd" log` | No pipe needed, simpler | File contains ANSI escape sequences, terminal control chars |

**Important:** When using `script` without pipe, the command's stdout is a TTY (good), but the resulting log file includes raw terminal sequences. If you need clean text output, use the pipe-to-tee approach or post-process with `col -b`:

```bash
# Post-process to strip escape sequences
col -b < typescript > clean_output.txt
```

### 1. Exit Code Handling

| Platform | Exit Code Behavior |
|----------|-------------------|
| util-linux ≥ 2.36 | Returns child's exit code |
| util-linux < 2.36 | Always returns 0 |
| macOS/BSD | Always returns 0 |

**Workaround for older systems:**
```bash
# Capture exit code through a side channel
script -q -c "your_command; echo \"EXITCODE:\$?\"" /dev/null | tee output.log | tail -1
```

## Stderr TTY Simulation

### How `script` Handles Stderr

**Good news:** `script` creates a PTY where **both stdout and stderr are TTYs** by default. The entire PTY (master/slave pair) presents as a TTY to the child process.

```python
#!/usr/bin/env python3
import sys
print(f"stdout isatty: {sys.stdout.isatty()}")      # True
print(f"stderr isatty: {sys.stderr.isatty()}")      # True
```

Both will return `True` when run inside `script`.

### Controlling Stderr Routing

Since `script` captures both streams together, you have options:

```bash
# Default: both stdout and stderr are TTYs, both logged
script -q -c "your_command" /dev/null | tee output.log

# Keep stderr as TTY but bypass logging (goes directly to real terminal)
script -q -c "your_command 2>/dev/tty" /dev/null | tee output.log

# Combine stderr with stdout, both go through PTY and get logged
script -q -c "your_command 2>&1" /dev/null | tee output.log

# Separate handling: stdout to tee, stderr direct to terminal
script -q -c "your_command 2>/dev/tty" /dev/null | tee stdout.log
```

### Verifying TTY Status

Test both streams:

```bash
script -q -c 'python3 -c "import sys; print(f\"out:{sys.stdout.isatty()}\", file=sys.stdout); print(f\"err:{sys.stderr.isatty()}\", file=sys.stderr)"' /dev/null
```

**Output:**
```
out:True
err:True
```

## Separating Stdout and Stderr to Different Files

**The challenge:** In a PTY, stdout and stderr are interleaved at the terminal level (like a real terminal). Once combined, they cannot be separated after the fact.

**The solution:** Capture them separately *before* they reach the PTY output.

### Method 1: Process Substitution (Bash)

Uses bash process substitution to tee stderr separately while keeping it as TTY:

```bash
# stdout -> stdout.log via tee, stderr -> stderr.log via tee, both displayed on terminal
script -q -c 'your_command 2> >(tee stderr.log) | tee stdout.log' /dev/null
```

**How it works:**
- `2> >(tee stderr.log)` redirects stderr to a process substitution that tees to file AND to its stdout
- That stdout goes to the PTY (and thus to terminal)
- `| tee stdout.log` pipes stdout through tee

**Problem:** This makes stderr a **pipe** (not TTY) because `tee` runs outside the PTY's view of stderr.

**Verification:**
```bash
script -q -c 'python3 -c "import sys; print(f\"stdout isatty: {sys.stdout.isatty()}\", file=sys.stdout); print(f\"stderr isatty: {sys.stderr.isatty()}\", file=sys.stderr)" 2> >(tee stderr.log) | tee stdout.log' /dev/null
```

Output shows: `stdout isatty: True`, `stderr isatty: False`

### Method 2: File Descriptor Redirection (Preserves TTY for Both)

Redirect stderr to a separate file but also copy to terminal:

```bash
# Not possible with pure shell redirection alone - stderr either goes to file OR terminal
```

**The core problem:** Once you redirect stderr to a file with `2>file`, it leaves the PTY entirely. You can't both:
1. Keep stderr as a TTY (for isatty detection), AND
2. Capture it to a separate file

This is a fundamental limitation of Unix terminal design.

### Method 3: Separate Script Sessions (Complex)

Run two separate script sessions - one capturing stdout, one capturing stderr. This requires the command to support splitting streams externally, which most don't.

### Practical Compromise: Terminal + Combined Log + Annotated Streams

If you need both TTY behavior AND separate files, the practical approach is annotation:

```bash
# Tag each line with its source, then separate later
script -q -c 'your_command 2> >(sed "s/^/[ERR] /" >&2) 1> >(sed "s/^/[OUT] /")' /dev/null | tee combined.log

# Later, split the file
grep "^\\[OUT\\] " combined.log | sed 's/^\[OUT\] //' > stdout.log
grep "^\\[ERR\\] " combined.log | sed 's/^\[ERR\] //' > stderr.log
```

**Trade-offs:**

| Method | stdout TTY | stderr TTY | Separate Files | Terminal Display | Complexity |
|--------|-----------|-----------|----------------|------------------|------------|
| `script` default | Yes | Yes | No (combined) | Yes | Simple |
| `2>file` | Yes | No (file) | Yes | No (stderr) | Simple |
| Process substitution | Yes | No (pipe) | Yes | Yes | Medium |
| Annotation | Yes | No (pipe) | Yes (post-process) | Yes (tagged) | Complex |

### Recommendation

**Use Method 1 (process substitution)** if:
- You only need stdout as TTY (stderr can be non-TTY)
- Separate files are important
- You can tolerate the `>(...)` bash syntax

**Use `script` default with `2>&1`** if:
- Both streams need TTY behavior
- Combined logging is acceptable
- Order/interleaving matters for debugging

### 2. Terminal Size

PTY created by `script` defaults to 24x80. Some commands may check terminal dimensions. Override with:

```bash
# Inside the script command
stty rows 50 cols 120
```

### 3. Buffering Differences

PTY uses line buffering which may differ from pipe buffering. For line-oriented tools this is usually fine, but may affect real-time progress indicators.

### 4. TERM Environment Variable

Some commands check `TERM` in addition to `isatty()`. Ensure it's set:

```bash
export TERM=xterm-256color
```

## Alternative Approaches (Not Recommended)

| Approach | Availability | Drawbacks |
|----------|-------------|-----------|
| `unbuffer` (expect package) | Requires install | Third-party dependency |
| `stdbuf` | coreutils | Only changes buffering, doesn't fake TTY |
| `socat` | Requires install | Complex, external tool |
| LD_PRELOAD shim | Manual compilation | Complex, fragile |

## Testing TTY Detection

Create a test script to verify behavior:

```python
#!/usr/bin/env python3
import sys
import os

print(f"stdout isatty: {sys.stdout.isatty()}")
print(f"stderr isatty: {sys.stderr.isatty()}")
print(f"TERM: {os.environ.get('TERM', 'not set')}")
```

**Test the solution:**
```bash
# Without TTY simulation (should show isatty: False)
python3 test_tty.py | cat

# With TTY simulation (should show isatty: True)
script -q -c "python3 test_tty.py" /dev/null | cat
```

## Full Working Example

```bash
#!/bin/bash
# tty_tee.sh - Run a command with TTY semantics while tee-ing output

set -euo pipefail

COMMAND="${1:-}"
LOGFILE="${2:-output.log}"

if [[ -z "$COMMAND" ]]; then
    echo "Usage: $0 <command> [logfile]"
    exit 1
fi

# Detect script version
if script -V 2>/dev/null | grep -q util-linux 2>/dev/null; then
    SCRIPT_FLAGS="-q -c"
    LOG_ARG="/dev/null"

    script $SCRIPT_FLAGS "$COMMAND" $LOG_ARG | tee "$LOGFILE"
else
    # BSD/macOS version
    script -q /dev/null bash -c "$COMMAND" | tee "$LOGFILE"
fi
```

## References

- `man script` on target systems for version-specific behavior
- util-linux changelog for exit code propagation (v2.36)
