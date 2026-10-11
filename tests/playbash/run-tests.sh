#!/usr/bin/env bash
# run-tests.sh — playbash's inventory: the `all` group, group arithmetic, and the refusal
# of every name the inventory does not list.
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

printf '=== playbooks outside all ===\n'
inventory '{"linux": ["a"], "all": ["linux"], "proj": ["p1"]}'
playbash run p1 daily -N >/dev/null || true
check 'a host outside all gets the playbook pushed' said 'p1 not in all — pushing playbook'
playbash run a daily -N >/dev/null || true
check 'a fleet host does not' not_said 'pushing playbook'
timeout 60 "$HOME/.local/bin/playbash" run a,p1 daily -N >/dev/null 2>|"$work/stderr" || true
check 'a fan-out names only the hosts outside all' said 'pushing playbook to p1 (not in all)'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
