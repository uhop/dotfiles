#!/usr/bin/env bash
# run-tests.sh — playbash's "managed": false inventory entries.
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
printf 'Host a\nHost b\nHost pc\n  User ec2-user\nHost other\n' >"$HOME/.ssh/config"

inventory() { printf '%s\n' "$1" >|"$HOME/.config/playbash/inventory.json"; }
playbash() { "$HOME/.local/bin/playbash" "$@" 2>|"$work/stderr" | sed 's/\x1b\[[0-9;]*m//g'; }
resolve() {
  node --input-type=module -e "
    import {loadInventory, resolveTargets} from '$HOME/.local/share/playbash/inventory.js';
    console.log(resolveTargets('$1', loadInventory()).map(t => t.name).join(','));
  " 2>|"$work/stderr"
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
has_line() { grep -qxF -- "$2" <<<"$1"; }
lacks_line() { ! grep -qxF -- "$2" <<<"$1"; }
said() { grep -qF -- "$1" "$work/stderr"; }
no_ssh() { [[ ! -e $work/ssh.log ]]; }
section() { awk -v head="$2" '$0 == head { on = 1; next } /^[^ ]/ { on = 0 } on' <<<"$1"; }

inventory '{"a": "a", "b": "b", "pc": {"address": "pc", "managed": false}, "linux": ["a", "b"]}'

printf '=== playbash hosts ===\n'
out=$(playbash hosts)
unmanaged=$(section "$out" 'not managed by playbash:')
aliases=$(section "$out" 'ssh aliases (not in inventory):')
check 'pc is listed as not managed, with its address' grep -qE '^  pc +pc$' <<<"$unmanaged"
check 'pc is not listed as an ssh alias' lacks_line "$aliases" '  pc'
check 'other ssh aliases are still listed' has_line "$aliases" '  other'

printf '=== tab completion ===\n'
out=$(playbash __complete-targets)
check 'completion leaves pc out' lacks_line "$out" pc
check 'completion keeps the fleet, groups, all, and other aliases' \
  bash -c 'for n in a b linux all other; do grep -qxF "$n" <<<"$1" || exit 1; done' _ "$out"

printf '=== targets ===\n'
check 'all expands to the fleet only' test "$(resolve all)" = a,b
check 'exec on pc is refused' bash -c '! "$HOME/.local/bin/playbash" exec pc true 2>"$1/stderr"' _ "$work"
check 'the refusal names the reason' said 'is not managed by playbash'
check 'put on pc is refused' bash -c '! "$HOME/.local/bin/playbash" put pc /etc/hostname 2>"$1/stderr"' _ "$work"
check 'for the same reason' said 'is not managed by playbash'
check 'pc was never contacted' no_ssh

inventory '{"a": "a", "pc": {"address": "pc", "managed": false}, "bad": ["a", "pc"]}'
check 'a group naming pc is refused' bash -c '! "$HOME/.local/bin/playbash" exec bad true 2>"$1/stderr"' _ "$work"
check 'the refusal names the group and the field' said 'group "bad" references "pc"'
check 'still nothing contacted' no_ssh

printf '=== the field itself ===\n'
inventory '{"a": "a", "pc": {"address": "pc", "managed": true}}'
check '"managed": true is an ordinary fleet host' test "$(resolve all)" = a,pc
inventory '{"a": "a", "pc": {"address": "pc", "managed": "no"}}'
check 'a non-boolean "managed" is an error' bash -c '! "$HOME/.local/bin/playbash" hosts >/dev/null 2>"$1/stderr"' _ "$work"
check 'the error names the entry' said 'inventory entry "pc" has a non-boolean "managed"'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
