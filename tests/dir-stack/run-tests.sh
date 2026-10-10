#!/usr/bin/env bash
# run-tests.sh — zpush, zp, zpop, and zdirs from dot_bash_aliases.
#
# Sources the aliases file into this shell with stub zoxide and fzf first on PATH: the
# zoxide stub logs its arguments and knows one keyword, `Dat`; the fzf stub records what
# it was shown and answers with $FZF_PICK's line, or exits like Esc when it is unset.
#
# Exit 0 on all-green, 1 on any failure.

set -eCo pipefail

source_dir="$(readlink -f "$(dirname "$(readlink -f "$0")")/../..")"
work=$(command mktemp -d)
trap 'builtin cd / && command rm -rf "$work"' EXIT

export HOME="$work/home"
vault="$work/media/raid/Vault-Data"
command mkdir -p "$HOME" "$work/bin" "$work/a" "$work/b" "$work/c" "$vault"
printf '#!/bin/sh\necho "$*" >>"%s/zoxide.log"\nfor last; do :; done\n[ "$last" = Dat ] || { echo "zoxide: no match found" >&2; exit 1; }\necho "%s"\n' \
  "$work" "$vault" >"$work/bin/zoxide"
printf '#!/bin/sh\ncat >"%s/fzf.in"\n[ -n "${FZF_RC:-}" ] && exit "$FZF_RC"\n[ -n "${FZF_PICK:-}" ] || exit 130\nawk -v n="$FZF_PICK" '"'"'$1 == n'"'"' "%s/fzf.in"\n' \
  "$work" "$work" >"$work/bin/fzf"
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
stack_is() { [[ $(builtin dirs -l -p | paste -sd ' ') == "$*" ]]; }
at() { [[ $PWD == "$1" ]]; }
logged() { grep -qxF -- "$1" "$work/zoxide.log"; }
no_log() { [[ ! -e $work/zoxide.log ]]; }
fails() { if "$@" >/dev/null 2>&1; then return 1; fi; }
reset() {
  builtin cd "$work/a"
  builtin dirs -c
  command rm -f "$work/zoxide.log" "$work/fzf.in"
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

printf '=== zp and zpop ===\n'
reset
zp Dat >/dev/null
check 'zp is zpush' stack_is "$vault $work/a"
zpop >/dev/null
check 'zpop is popd' stack_is "$work/a"

printf '=== zdirs ===\n'
reset
zpush "$work/b" >/dev/null
zpush "$work/c" >/dev/null
unset FZF_PICK FZF_RC
check 'Esc closes it without an error' zdirs
check 'and changes nothing' stack_is "$work/c $work/b $work/a"
check 'fzf was shown the stack as dirs -v prints it' bash -c '[[ $(<"$1") == "$2" ]]' _ "$work/fzf.in" "$(builtin dirs -v)"
FZF_PICK=2 zdirs >/dev/null
check 'Enter goes to the picked directory' at "$work/a"
check 'rotating the stack, nothing dropped' stack_is "$work/a $work/c $work/b"
command rm -f "$work/fzf.in"
check 'with arguments it is dirs' bash -c '[[ $1 == "$2" ]]' _ "$(zdirs -v -l)" "$(builtin dirs -v -l)"
check 'and fzf stays closed' test ! -e "$work/fzf.in"
check 'an fzf failure is reported' bash -c 'FZF_RC=2; export FZF_RC; source "$1"; zdirs; (($? == 2))' _ "$source_dir/dot_bash_aliases"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
