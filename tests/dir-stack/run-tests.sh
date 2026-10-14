#!/usr/bin/env bash
# run-tests.sh — zpush, zp, zpop, and zdirs from dot_bash_aliases.
#
# Sources the aliases file into this shell with stub zoxide and fzf first on PATH. The
# zoxide stub logs its arguments and knows one keyword, `Dat`. The fzf stub plays one step
# of $FZF_PLAN per call, "KEY:N" or "esc", and records what it was shown and the options it
# got; KEY:N presses KEY on entry N, printing what --bind binds KEY to and the entry.
#
# Exit 0 on all-green, 1 on any failure.

set -eCo pipefail

source_dir="$(readlink -f "$(dirname "$(readlink -f "$0")")/../..")"
work=$(command mktemp -d)
trap 'builtin cd / && command rm -rf "$work"' EXIT

export HOME="$work/home"
vault="$work/mnt/store/Shared-Data"
command mkdir -p "$HOME" "$work/bin" "$work/a" "$work/b" "$work/c" "$work/d" "$vault"
command cat >"$work/bin/zoxide" <<EOF
#!/bin/sh
echo "\$*" >>"$work/zoxide.log"
for last; do :; done
[ "\$last" = Dat ] || { echo "zoxide: no match found" >&2; exit 1; }
echo "$vault"
EOF
command cat >"$work/bin/fzf" <<EOF
#!/bin/sh
calls=\$((\$(cat "$work/fzf.calls" 2>/dev/null || echo 0) + 1))
echo "\$calls" >"$work/fzf.calls"
cat >"$work/fzf.in.\$calls"
printf '%s\n' "\$@" >"$work/fzf.args.\$calls"
[ -n "\${FZF_RC:-}" ] && exit "\$FZF_RC"
step=\$(echo "\${FZF_PLAN:-esc}" | cut -d' ' -f"\$calls")
{ [ -z "\$step" ] || [ "\$step" = esc ]; } && exit 130
key=\${step%%:*}
action=\$(tr , '\n' <"$work/fzf.args.\$calls" | sed -n "s/^\$key:print(\(.*\))+accept\\\$/\\1/p")
[ -n "\$action" ] || { echo "fzf stub: \$key is not bound" >&2; exit 2; }
echo "\$action"
awk -v n="\${step#*:}" '\$1 == n' "$work/fzf.in.\$calls"
EOF
command chmod +x "$work/bin/zoxide" "$work/bin/fzf"
export PATH="$work/bin:$PATH"

shopt -s expand_aliases
# shellcheck source=/dev/null
source "$source_dir/dot_bash_aliases"

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
stack_is() { [[ $(builtin dirs -l -p | command paste -sd ' ') == "$*" ]]; }
at() { [[ $PWD == "$1" ]]; }
logged() { command grep -qxF -- "$1" "$work/zoxide.log"; }
no_log() { [[ ! -e $work/zoxide.log ]]; }
fails() { if "$@" >/dev/null 2>&1; then return 1; fi; }
fzf_calls() { [[ $(command cat "$work/fzf.calls" 2>/dev/null || echo 0) -eq $1 ]]; }
fzf_got() { command grep -qF -- "$2" "$work/fzf.args.$1"; }
reset() {
  builtin cd "$work/a"
  builtin dirs -c
  command rm -f "$work"/zoxide.log "$work"/fzf.*
  unset FZF_PLAN FZF_RC
}
# The stack a b c d, at a.
four() {
  reset
  builtin cd "$work/d"
  builtin pushd "$work/c" >/dev/null
  builtin pushd "$work/b" >/dev/null
  builtin pushd "$work/a" >/dev/null
}

printf '=== zpush resolves like z ===\n'
reset
zpush Dat >/dev/null
check 'zpush Dat pushes what zoxide answers' stack_is "$vault $work/a"
check 'and goes there' at "$vault"
check 'asking zoxide the way z does, without the current directory' logged "query --exclude $work/a -- Dat"
reset
zpush "$work/c" >/dev/null
check 'an existing directory is pushed as is' stack_is "$work/c $work/a"
check 'without asking zoxide' no_log
reset
check 'a keyword zoxide does not know fails' fails zpush nomatch
check 'and leaves the stack alone' stack_is "$work/a"

printf '=== pushd arguments pass through ===\n'
reset
zpush "$work/b" >/dev/null
zpush "$work/c" >/dev/null
zpush >/dev/null
check 'no argument swaps the top two' stack_is "$work/b $work/c $work/a"
zpush +2 >/dev/null
check '+N rotates' stack_is "$work/a $work/b $work/c"
zpush -1 >/dev/null
check '-N rotates from the bottom' stack_is "$work/b $work/c $work/a"
reset
zpush -n "$work/b" >/dev/null
check '-n adds a directory without going there' stack_is "$work/a $work/b"
zpush -n Dat >/dev/null
check '-n with a keyword adds the match without going there' stack_is "$work/a $vault $work/b"
reset
builtin cd "$work/c"
builtin cd "$work/a"
zpush - >/dev/null
check '- pushes the previous directory' stack_is "$work/c $work/a"
reset
check 'after --, +1 is a keyword for zoxide' fails zpush -- +1
check 'so it was asked' logged "query --exclude $work/a -- +1"
check 'pushd'"'"'s own error for a bad argument comes through' fails zpush +9

printf '=== a directory sits in the stack once ===\n'
reset
zp Dat >/dev/null
FZF_PLAN=enter:1 zdirs >/dev/null
zp Dat >/dev/null
check 'zp Dat, back home, zp Dat again: one copy of each' stack_is "$vault $work/a"
four
zpush "$work/c" >/dev/null
check 'zpush to an entry moves it to the top' stack_is "$work/c $work/a $work/b $work/d"
zpop >/dev/null
check 'so zpop goes back to where you were' at "$work/a"
four
zpush - >/dev/null
check 'zpush - moves the previous directory up too' stack_is "$work/b $work/a $work/c $work/d"
four
zpush -n "$work/d" >/dev/null
check 'with -n the entry moves just under the top' stack_is "$work/a $work/d $work/b $work/c"
four
zpush "$work/a" >/dev/null
check 'the current directory changes nothing' stack_is "$work/a $work/b $work/c $work/d"
reset
builtin cd "$work/b"
builtin pushd "$work/c" >/dev/null
builtin pushd "$work/b" >/dev/null
builtin pushd "$work/a" >/dev/null
zpush "$work/b" >/dev/null
check 'every older copy goes' stack_is "$work/b $work/a $work/c"

printf '=== zp and zpop ===\n'
reset
zp Dat >/dev/null
check 'zp is zpush' stack_is "$vault $work/a"
zpop >/dev/null
check 'zpop is popd' stack_is "$work/a"

printf '=== zdirs ===\n'
four
check 'Esc closes it without an error' zdirs
check 'and changes nothing' stack_is "$work/a $work/b $work/c $work/d"
check 'fzf was shown the stack as dirs -v prints it' \
  bash -c '[[ $(<"$1") == "$2" ]]' _ "$work/fzf.in.1" "$(builtin dirs -v)"
check 'with the keys in a one-line legend' fzf_got 1 'enter: go   ctrl-r: rotate   ctrl-d, del: drop   esc: close'
check 'and search left on' bash -c '! grep -q -- --no-input "$1"' _ "$work/fzf.args.1"
four
FZF_PLAN=enter:2 zdirs >/dev/null
check 'Enter moves the picked directory to the top' stack_is "$work/c $work/a $work/b $work/d"
check 'and goes there' at "$work/c"
four
FZF_PLAN=double-click:3 zdirs >/dev/null
check 'so does a double click' stack_is "$work/d $work/a $work/b $work/c"
four
FZF_PLAN=enter:0 zdirs >/dev/null
check 'Enter on the current directory changes nothing' stack_is "$work/a $work/b $work/c $work/d"
four
FZF_PLAN=ctrl-r:2 zdirs >/dev/null
check 'Ctrl-R rotates the stack to it' stack_is "$work/c $work/d $work/a $work/b"
four
FZF_PLAN='del:2 esc' zdirs >/dev/null
check 'Del drops it' stack_is "$work/a $work/b $work/d"
check 'and reopens the list' fzf_calls 2
check 'with the cursor where the dropped entry was' fzf_got 2 'start:pos(3)'
four
FZF_PLAN='ctrl-d:3 esc' zdirs >/dev/null
check 'Ctrl-D drops the last one' stack_is "$work/a $work/b $work/c"
check 'with the cursor on the new last' fzf_got 2 'start:pos(3)'
four
FZF_PLAN='backward-eof:1 esc' zdirs >/dev/null
check 'Backspace on an empty filter drops it' stack_is "$work/a $work/c $work/d"
check 'while Backspace itself still edits the filter' \
  bash -c '! tr , "\n" <"$1" | grep -qE "^(bspace|bs|backspace):"' _ "$work/fzf.args.1"
four
FZF_PLAN='del:0 esc' zdirs >/dev/null
check 'the current directory cannot be dropped' stack_is "$work/a $work/b $work/c $work/d"
four
FZF_PLAN='del:1 enter:2' zdirs >/dev/null
check 'drop, then go' stack_is "$work/d $work/a $work/c"
four
command rm -f "$work"/fzf.*
check 'with arguments it is dirs' bash -c '[[ $1 == "$2" ]]' _ "$(zdirs -v -l)" "$(builtin dirs -v -l)"
check 'and fzf stays closed' fzf_calls 0
FZF_RC=1 check 'no match closes it too' zdirs
check 'an fzf failure is reported' \
  bash -c 'FZF_RC=2; export FZF_RC; source "$1"; zdirs; (($? == 2))' _ "$source_dir/dot_bash_aliases"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
