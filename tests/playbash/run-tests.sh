#!/usr/bin/env bash
# run-tests.sh — playbash's inventory (the `all` group, group arithmetic, and the refusal
# of every name the inventory does not list), put and get on @self, host-local
# additions (playbash_local and doctor's check), and Ctrl-C (the section trap, the
# wrapper's SIGUSR1, the board's choice of host, and the run without a terminal).
#
# Installs the source copies of playbash into an isolated HOME with its own inventory and
# ssh config, and puts a stub ssh first on PATH that logs every call, so a refused host is
# proven never to be contacted.
#
# Exit 0 on all-green, 1 on any failure.

set -euCo pipefail

source_dir="$(readlink -f "$(dirname "$(readlink -f "$0")")/../..")"
work=$(mktemp -d)
trap 'cd / && command rm -rf "$work"' EXIT

export HOME="$work/home"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/playbash" "$HOME/.config/playbash" "$HOME/.ssh" "$work/bin"
cp "$source_dir/private_dot_local/bin/executable_playbash" "$HOME/.local/bin/playbash"
cp "$source_dir"/private_dot_local/private_share/playbash/* "$HOME/.local/share/playbash/"
chmod +x "$HOME/.local/bin/playbash"
printf '#!/bin/sh\necho "$*" >>"%s/ssh.log"\nexit 1\n' "$work" >"$work/bin/ssh"
chmod +x "$work/bin/ssh"
export PATH="$work/bin:$PATH"
printf 'Host a\nHost b\nHost cloud\n  User ec2-user\nHost other\n' >"$HOME/.ssh/config"
self_name=$(node -p 'require("os").hostname()')

inventory() { printf '%s\n' "$1" >|"$HOME/.config/playbash/inventory.json"; }
playbash() { "$HOME/.local/bin/playbash" "$@" 2>|"$work/stderr" | sed 's/\x1b\[[0-9;]*m//g'; }
js() {
  node --input-type=module -e "
    import {loadInventory, resolveTargets} from '$HOME/.local/share/playbash/inventory.js';
    const inv = loadInventory();
    $1
  " 2>|"$work/stderr"
}
resolve() { js "console.log(resolveTargets('$1', inv).map(t => t.name).join(','));"; }
addresses() { js "console.log(resolveTargets('$1', inv).map(t => t.address).join(','));"; }
fleet() { js "console.log([...inv.fleet].join(','));"; }
complete_targets() {
  PATH="$HOME/.local/bin:$PATH" bash -c \
    'source "$1"; __playbash_complete_targets "$2"; printf "%s\n" "${COMPREPLY[@]}"' \
    _ "$HOME/.local/share/playbash/completion.bash" "$1"
}

pass=0
fail=0
check() {
  local label=$1
  shift
  if "$@"; then
    printf '  ok   %s\n' "$label"
    pass=$((pass + 1))
  else
    printf '  FAIL %s\n' "$label"
    fail=$((fail + 1))
  fi
}
fails() { if "$@" >/dev/null; then return 1; fi; }
has_line() { grep -qxF -- "$2" <<<"$1"; }
lacks_line() { ! grep -qxF -- "$2" <<<"$1"; }
matches() { grep -qE -- "$2" <<<"$1"; }
said() { grep -qF -- "$1" "$work/stderr"; }
not_said() { ! grep -qF -- "$1" "$work/stderr"; }
no_ssh() { [[ ! -e $work/ssh.log ]]; }
section() { awk -v head="$2" '$0 == head { on = 1; next } /^[^ ]/ { on = 0 } on' <<<"$1"; }
# GNU timeout is missing on a Mac without coreutils; there the run goes unguarded.
time_limit() { if command -v timeout >/dev/null; then timeout 60 "$@"; else "$@"; fi; }

printf '=== the all group ===\n'
inventory '{"linux": ["a", "b"], "mac": ["m"], "all": ["linux", "mac"], "proj": ["p1", "p2"], "a": "a.example"}'
check 'all expands its groups in order' test "$(resolve all)" = a,b,m
check 'the fleet is all, without the project hosts' test "$(fleet)" = a,b,m
check 'a group outside all resolves when named' test "$(resolve proj)" = p1,p2
check 'a host entry sets the address, a bare name is its own' test "$(addresses a,b)" = a.example,b

printf '=== arithmetic ===\n'
inventory '{"all": ["a", "b", "c"], "first": ["-b", "all"], "last": ["all", "-b"]}'
check 'a removal applies wherever it stands' test "$(resolve first)" = a,c
check 'the same at the end' test "$(resolve last)" = a,c
check 'the command line removes the same way' test "$(resolve all,-b)" = a,c
inventory '{"later": ["all", "-odd"], "all": ["odd", "even"], "odd": ["a", "c"], "even": ["b"]}'
check 'a group refers to groups in any file order' test "$(resolve later)" = b
check 'removing a group removes its hosts' test "$(resolve all,-odd)" = b
inventory '{"all": ["x"], "x": ["y"], "y": ["x"]}'
check 'a cycle is an error' fails fleet
check 'the error names the cycle' said 'cycle: x → y → x'
inventory '{"all": ["a", "-zz"]}'
check 'removing an unknown name is an error' fails fleet
check 'the error names it' said 'group "all" removes "zz", which is neither a host nor a group'

printf '=== inventory rules ===\n'
inventory '{"linux": ["a"]}'
check 'hosts without an all group are an error' fails fleet
check 'the error asks for all' said 'has no "all" group'
inventory '{"all": ["a"], "cloud": {"address": "cloud", "managed": false}}'
check '"managed" is an error' fails fleet
check 'the error says why' said 'has "managed", which playbash no longer reads'
inventory '{"all": ["a", "@self"]}'
check '@self in a group is an error' fails fleet
check 'the error says where @self works' said '@self works on the command line only'
inventory '{"all": ["a"], "b": {"address": "b.example"}}'
check 'the object form of a host entry still works' test "$(addresses b)" = b.example

printf '=== names outside the inventory ===\n'
inventory '{"linux": ["a", "b"], "all": ["linux"]}'
check 'exec on an ssh alias is refused' fails playbash exec cloud true
check 'the refusal names the inventory' said '"cloud" is not in the inventory'
check 'put on one is refused' fails playbash put other /etc/hostname
check 'for the same reason' said '"other" is not in the inventory'
check 'removing an unknown name is refused' fails playbash exec all,-zz true
check 'by name' said '"zz" is not in the inventory'
check 'nothing was contacted' no_ssh

printf '=== self ===\n'
inventory "{\"all\": [\"a\", \"$self_name\"]}"
check '@self is this machine by hostname' test "$(resolve @self)" = "$self_name"
check 'its address is localhost even when all lists it' test "$(addresses all,@self)" = a,localhost
check 'without @self the listed address stays' test "$(addresses all)" = "a,$self_name"
check '-@self removes it again' test "$(resolve all,@self,-@self)" = a
check '--self is refused' fails playbash exec all --self true
check 'the error points at @self' said 'add @self to the target list'

printf '=== hosts and completion ===\n'
inventory '{"linux": ["a", "b"], "all": ["linux"], "proj": ["p1"]}'
out=$(playbash hosts)
check 'the fleet comes first' matches "$(head -1 <<<"$out")" '^a +a *$'
check 'hosts outside all have their own section' matches "$(section "$out" 'not in all:')" '^  p1 +p1 *$'
check 'a group shows its hosts when they differ' matches "$(section "$out" 'groups:')" '^  all +linux  → a, b$'
check 'ssh aliases are not listed' bash -c '! grep -q "ssh aliases" <<<"$1"' _ "$out"
out=$(playbash __complete-targets)
check 'completion lists @self, the groups, and every host' \
  bash -c 'for n in @self all linux proj a b p1; do grep -qxF -- "$n" <<<"$1" || exit 1; done' _ "$out"
check 'completion leaves ssh aliases out' lacks_line "$out" other
check 'tab after a comma completes an addition' test "$(complete_targets linux,pr)" = linux,proj
check 'tab after a - completes a removal' test "$(complete_targets all,-li)" = all,-linux

printf '=== put and get on @self ===\n'
inventory '{"all": ["a"]}'
command rm -f "$work/ssh.log"
mkdir -p "$work/src/sub"
printf 'one\n' >"$work/src/f.txt"
chmod 640 "$work/src/f.txt"
printf 'two\n' >"$work/src/sub/g.txt"
mode_of() { command ls -ln "$1" 2>/dev/null | cut -c1-10; }
playbash put @self "$work/src/f.txt" "$work/out/put/f.txt" >/dev/null || true
check 'put to @self writes the file' cmp -s "$work/src/f.txt" "$work/out/put/f.txt"
check 'with its mode' test "$(mode_of "$work/out/put/f.txt")" = -rw-r-----
playbash put @self "$work/src" "$work/out/put-dir" >/dev/null || true
check 'and a directory' cmp -s "$work/src/sub/g.txt" "$work/out/put-dir/sub/g.txt"
playbash get @self "$work/src/f.txt" "$work/out/got.txt" >/dev/null || true
check 'get from @self reads the file' cmp -s "$work/src/f.txt" "$work/out/got.txt"
playbash get @self "$work/src" "$work/out/got-dir" >/dev/null || true
check 'and a directory' cmp -s "$work/src/sub/g.txt" "$work/out/got-dir/sub/g.txt"
check 'none of it went over ssh' no_ssh
playbash put a,@self "$work/src/f.txt" "$work/out/fan.txt" >/dev/null || true
check 'in a fan-out @self is written too' cmp -s "$work/src/f.txt" "$work/out/fan.txt"
check 'and only the other host goes over ssh' bash -c 'grep -q " a " "$1" && ! grep -q localhost "$1"' _ "$work/ssh.log"
# --sudo reads its password from /dev/tty, so drive the transfer module directly; the stub
# sudo wants -k (no cached ticket skipping the read) and takes the password line itself.
printf '#!/bin/sh\n[ "$1" = -k ] && [ "$2" = -S ] || { echo "stub sudo: $*" >&2; exit 2; }\nshift 2\nIFS= read -r pw\necho "$pw" >>"%s/sudo.log"\nexec "$@"\n' "$work" >"$work/bin/sudo"
chmod +x "$work/bin/sudo"
transfer() {
  node --input-type=module -e "
    import {cmdGet, cmdPut} from '$HOME/.local/share/playbash/transfer.js';
    const validated = {targets: [{name: 'me', address: 'localhost', isSelf: true}],
      offlineNames: new Set(), offlineReasons: new Map(), parallelLimit: 1};
    $1
  " 2>|"$work/stderr"
}
transfer "await cmdPut(validated, '$work/src/f.txt', '$work/out/sudo/f.txt', 'pw');" || true
check 'put --sudo to @self writes the file intact' cmp -s "$work/src/f.txt" "$work/out/sudo/f.txt"
transfer "await cmdGet(validated, '$work/src/f.txt', '$work/out/sudo-got.txt', 'pw');" || true
check 'get --sudo from @self reads it intact' cmp -s "$work/src/f.txt" "$work/out/sudo-got.txt"
check 'sudo took the password each time' test "$(command paste -sd, "$work/sudo.log" 2>/dev/null)" = pw,pw,pw

printf '=== host-local additions ===\n'
# A playbook in the fleet's shape, run directly against the source playbash.sh; each step
# appends its name to steps.log, and the run's events go to report.jsonl.
local_dir="$HOME/.config/playbash/local"
mkdir -p "$work/pb" "$local_dir"
make_playbook() {
  printf '%s\n' '#!/usr/bin/env bash' 'set -euCo pipefail' \
    'source "$PLAYBASH_LIBS/playbash.sh"' \
    'playbash_section first sh -c "echo first >>\"$STEPS\""' \
    "playbash_local ${2-}" \
    'playbash_section last sh -c "echo last >>\"$STEPS\""' \
    'playbash_section_report' >|"$work/pb/$1"
  chmod +x "$work/pb/$1"
}
run_playbook() {
  command rm -f "$work/steps.log" "$work/report.jsonl"
  local rc=0
  PLAYBASH_LIBS="$source_dir/private_dot_local/libs" STEPS="$work/steps.log" \
    PLAYBASH_REPORT="$work/report.jsonl" "$work/pb/$1" 2>/dev/null || rc=$?
  echo "$rc"
}
steps() { command paste -sd, "$work/steps.log" 2>/dev/null; }
event() { grep -qF -- "$1" "$work/report.jsonl" 2>/dev/null; }
make_playbook playbash-daily
check 'without a local file the playbook runs as is' test "$(run_playbook playbash-daily)" = 0
check 'first and last only' test "$(steps)" = first,last
check 'and no local event' bash -c '! grep -q "local additions" "$1" 2>/dev/null' _ "$work/report.jsonl"
printf '%s\n' 'playbash_section extra sh -c "echo extra >>\"$STEPS\""' >|"$local_dir/daily.sh"
check 'daily.sh joins playbash-daily' test "$(run_playbook playbash-daily)" = 0
check 'at the point the playbook calls it' test "$(steps)" = first,extra,last
check 'and the run names the file' event "\"target\":\"$local_dir/daily.sh\""
printf '%s\n' 'playbash_section extra false' >|"$local_dir/daily.sh"
check 'a failed section in it fails the run' test "$(run_playbook playbash-daily)" = 1
check 'after the rest ran' test "$(steps)" = first,last
check 'under its own section name' event 'section failures: extra'
printf '%s\n' 'if then fi (' >|"$local_dir/daily.sh"
check 'a file that does not parse fails the run' test "$(run_playbook playbash-daily)" = 1
check 'without stopping it' test "$(steps)" = first,last
check 'and says why' event 'local additions skipped: syntax error'
printf '%s\n' 'false' 'echo after >>"$STEPS"' 'false' >|"$local_dir/daily.sh"
check 'a bare failing command does not stop the playbook' test "$(run_playbook playbash-daily)" = 1
check 'nor the file' test "$(steps)" = first,after,last
check 'and counts as the section local' event 'section failures: local'
printf '%s\n' 'playbash_section extra sh -c "echo extra >>\"$STEPS\""' >|"$local_dir/check-disk.sh"
make_playbook check-disk.sh
run_playbook check-disk.sh >/dev/null
check 'a pushed check-disk.sh finds check-disk.sh' test "$(steps)" = first,extra,last
make_playbook main.sh weekly
command mv "$local_dir/check-disk.sh" "$local_dir/weekly.sh"
run_playbook main.sh >/dev/null
check 'a directory playbook passes its name' test "$(steps)" = first,extra,last
inventory '{"all": ["a"]}'
command rm -f "$local_dir"/*.sh
printf '%s\n' 'true' >|"$local_dir/daily.sh"
printf '%s\n' 'true' >|"$local_dir/weekly.sh"
out=$(playbash doctor || true)
check 'doctor lists the local additions' matches "$out" '✓ local additions +daily\.sh, weekly\.sh$'
printf '%s\n' 'if then fi (' >|"$local_dir/broken.sh"
out=$(playbash doctor || true)
check 'and fails one that does not parse' matches "$out" '✗ local additions +does not parse: broken\.sh$'
command rm -f "$local_dir"/*.sh
out=$(playbash doctor || true)
check 'with none it says so' matches "$out" '✓ local additions +none \('

printf '=== playbooks outside all ===\n'
inventory '{"linux": ["a"], "all": ["linux"], "proj": ["p1"]}'
playbash run p1 daily -N >/dev/null || true
check 'a host outside all gets the playbook pushed' said 'p1 not in all — pushing playbook'
playbash run a daily -N >/dev/null || true
check 'a fleet host does not' not_said 'pushing playbook'
time_limit "$HOME/.local/bin/playbash" run a,p1 daily -N >/dev/null 2>|"$work/stderr" || true
check 'a fan-out names only the hosts outside all' said 'pushing playbook to p1 (not in all)'

printf '=== Ctrl-C ===\n'
# A terminal's Ctrl-C reaches a process group whose SIGINT is at its default; a background
# job of this script would start with SIGINT ignored, which bash cannot trap. So each run
# gets its own group with SIGINT restored, and a press is a SIGINT to that group. The
# wrapper starts the same way, as sshd starts it: an ignored SIGINT would reach its playbook.
own_group='import os, signal, sys; os.setpgid(0, 0); signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])'
wait_step() {
  local i
  for ((i = 0; i < 100; ++i)); do
    grep -qxF -- "$1" "$work/steps.log" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}
printf '%s\n' '#!/usr/bin/env bash' 'set -euCo pipefail' \
  'source "$PLAYBASH_LIBS/playbash.sh"' \
  'step() { echo "$1" >>"$STEPS"; sleep "$2"; }' \
  'playbash_section one step one 30' \
  'playbash_section two step two "${SLOW_TWO:-0}"' \
  'playbash_section three step three 0' \
  'playbash_section_report' >|"$work/pb/playbash-ctrlc"
chmod +x "$work/pb/playbash-ctrlc"
# Runs the playbook in its own group, presses Ctrl-C once per step named, each time that
# step has started, and prints the playbook's exit code.
press_at() {
  command rm -f "$work/steps.log" "$work/report.jsonl"
  PLAYBASH_LIBS="$source_dir/private_dot_local/libs" STEPS="$work/steps.log" \
    PLAYBASH_REPORT="$work/report.jsonl" python3 -c "$own_group" "$work/pb/playbash-ctrlc" 2>/dev/null &
  local pid=$! step rc=0
  for step; do wait_step "$step" && kill -INT -- "-$pid"; done
  wait "$pid" || rc=$?
  echo "$rc"
}
check 'one press fails only the running section' test "$(press_at one)" = 1
check 'and the rest of the playbook runs' test "$(steps)" = one,two,three
check 'the section is reported as interrupted' event '"msg":"section interrupted","target":"one"'
check 'and counts as a failure' event 'section failures: one'
check 'a second press within 2 s ends a direct run' test "$(SLOW_TWO=30 press_at one two)" = 143
check 'before the next section' test "$(steps)" = one,two
check 'under the runner each press interrupts one section' \
  test "$(PLAYBASH_HOST=h SLOW_TWO=30 press_at one two)" = 1
check 'and the playbook goes on' test "$(steps)" = one,two,three
check 'both are counted' event 'section failures: one two'

wrapper="$source_dir/private_dot_local/libs/playbash-wrap.py"
check 'without a request the wrapper announces only its pid' \
  matches "$(python3 -u "$wrapper" true 2>&1 | head -1)" '^__playbash_wrap_pid [0-9]+$'
check 'asked for int it names the feature' \
  matches "$(PLAYBASH_WRAP_FEATURES='int other' python3 -u "$wrapper" true 2>&1 | head -1)" '^__playbash_wrap_pid [0-9]+ int$'
check 'and the playbook does not see the request' \
  matches "$(PLAYBASH_WRAP_FEATURES=int python3 -u "$wrapper" sh -c 'echo "[${PLAYBASH_WRAP_FEATURES-unset}]"' 2>&1)" '\[unset\]'
command rm -f "$work/steps.log" "$work/report.jsonl"
PLAYBASH_LIBS="$source_dir/private_dot_local/libs" STEPS="$work/steps.log" PLAYBASH_HOST=h \
  PLAYBASH_REPORT="$work/report.jsonl" PLAYBASH_WRAP_FEATURES=int \
  python3 -c "$own_group" python3 -u "$wrapper" "$work/pb/playbash-ctrlc" >|"$work/wrap.out" 2>&1 &
wrap_pid=$!
rc=0
wait_step one && kill -USR1 "$wrap_pid"
wait "$wrap_pid" || rc=$?
check 'SIGUSR1 to the wrapper interrupts the running section' test "$rc" = 1
check 'the playbook reports it' event '"msg":"section interrupted","target":"one"'
check 'and goes on' test "$(steps)" = one,two,three
check 'the pid line came first' test "$(head -1 "$work/wrap.out")" = "__playbash_wrap_pid $wrap_pid int"

focus() {
  node --input-type=module -e "
    import {HostSlot, StatusBoard} from '$HOME/.local/share/playbash/render.js';
    let now = 1000;
    Date.now = () => now;
    const board = new StatusBoard(['a', 'b'].map(n => new HostSlot(n, n, 5)), {playbook: 'p', rectHeight: 5});
    board.hostStarted('a');
    board.hostStarted('b');
    now = 2000;
    board.hostChunk('b', 'x\n');
    $1
  " 2>|"$work/stderr"
}
check 'focus moves to a host that prints while the focused one is quiet' \
  test "$(focus 'console.log(board.focusName)')" = b
check 'a press targets the host on screen a second before it' \
  test "$(focus 'console.log(board.focusAt(1500), board.focusAt(2500))')" = 'a b'
check 'a pinned host keeps the screen while another prints' \
  test "$(focus "board.pinFocus('a', 3000); now = 2700; board.hostChunk('b', 'y\n'); console.log(board.focusName)")" = a
check 'until the pin runs out' \
  test "$(focus "board.pinFocus('a', 3000); now = 5100; board.hostChunk('b', 'y\n'); console.log(board.focusName)")" = b

inventory '{"all": ["a"]}'
cp "$work/pb/playbash-ctrlc" "$HOME/.local/bin/playbash-ctrlc"
command rm -f "$work/steps.log"
PLAYBASH_LIBS="$source_dir/private_dot_local/libs" STEPS="$work/steps.log" \
  python3 -c "$own_group" "$HOME/.local/bin/playbash" run @self ctrlc >/dev/null 2>|"$work/stderr" &
runner_pid=$!
rc=0
wait_step one && kill -INT -- "-$runner_pid"
wait "$runner_pid" || rc=$?
check 'without a terminal one press cancels the run' test "$rc" = 130
check 'and says so' said 'SIGINT received, terminating 1 local child(ren)'
check 'no later section ran' test "$(steps)" = one

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
