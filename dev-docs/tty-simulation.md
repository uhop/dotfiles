# TTY Simulation for Piped Commands

## Problem Statement

Some utilities check if stdout is a TTY using `isatty()` and change their behavior accordingly (e.g., disable colors, progress bars, or formatting). When piping to `tee`, these commands detect a non-TTY and change behavior, but the user wants both:
1. TTY-like behavior (colors/formatting) from the command
2. The output captured via pipe to `tee` (which writes to both terminal and file)

## Solution: The `script` Command

The `script` command is the only widely-available solution that requires no third-party tools. It creates a pseudoterminal (PTY) that tricks commands into thinking they have a TTY.

**Availability**: Pre-installed on Linux (util-linux package) and macOS/BSD (base system).

## Implementation

### Linux (util-linux ≥ 2.36)

```bash
script -q -c "your_command" /dev/null | tee output.log
```

**Flags:**
- `-q` : Quiet mode (suppresses "Script started..." messages)
- `-c "cmd"` : Execute command directly instead of interactive shell
- `/dev/null` : Log file for `script` itself (discarded, since we capture output via pipe)

### macOS / BSD

```bash
script -q /dev/null your_command | tee output.log
```

**Note**: BSD `script` has different syntax - command follows the log file argument.

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

## Caveats and Edge Cases

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

### 2. Stderr Handling

By default, `script` captures **both** stdout and stderr to the PTY. To separate them:

```bash
# Only stdout through PTY (and thus to tee), stderr straight to terminal
script -q -c "your_command 2>/dev/tty" /dev/null | tee output.log

# Both stdout and stderr through tee (combine first)
script -q -c "your_command 2>&1" /dev/null | tee output.log
```

### 3. Terminal Size

PTY created by `script` defaults to 24x80. Some commands may check terminal dimensions. Override with:

```bash
# Inside the script command
stty rows 50 cols 120
```

### 4. Buffering Differences

PTY uses line buffering which may differ from pipe buffering. For line-oriented tools this is usually fine, but may affect real-time progress indicators.

### 5. TERM Environment Variable

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
