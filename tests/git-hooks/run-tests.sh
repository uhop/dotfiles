#!/usr/bin/env bash
# run-tests.sh — the global pre-commit secret scan (dot_config/git/hooks/executable_pre-commit).
#
# Runs git with an isolated HOME whose global config carries dot_gitconfig.tmpl's own
# hooksPath line, so the tilde expansion is tested with the hook. Fake secrets are built
# at run time, so this file never matches the scan itself.
#
# Exit 0 on all-green, 1 on any failure.

set -euCo pipefail

source_dir="$(readlink -f "$(dirname "$(readlink -f "$0")")/../..")"
work=$(mktemp -d)
trap 'cd / && command rm -rf "$work"' EXIT

export HOME="$work/home"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME/.config/git/hooks"
cp "$source_dir/dot_config/git/hooks/executable_pre-commit" "$HOME/.config/git/hooks/pre-commit"
chmod +x "$HOME/.config/git/hooks/pre-commit"
{
  printf '[user]\n\tname = test\n\temail = test@example.com\n[init]\n\tdefaultBranch = main\n[core]\n'
  grep -E '^[[:space:]]*hooksPath = ' "$source_dir/dot_gitconfig.tmpl"
} >"$GIT_CONFIG_GLOBAL"

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

n=0
fresh_repo() {
  n=$((n + 1))
  repo="$work/repo-$n"
  git init -q "$repo"
  cd "$repo"
}
commit() { git commit -q -m test "$@" 2>|"$work/stderr"; }
stopped() { ! commit "$@"; }
said() { grep -qF -- "$1" "$work/stderr"; }
kept_quiet() { ! grep -qE -- "$1" "$work/stderr"; }

begin='-----BEGIN'
private_key="$begin OPENSSH PRIVATE KEY-----"
aws_id="AKIA$(printf 'Q%.0s' {1..16})"
github_token="ghp_$(printf 'a%.0s' {1..36})"

printf '=== the hook comes from the template'"'"'s hooksPath line ===\n'
fresh_repo
check 'core.hooksPath expands to the installed hook' test -x "$(git config --path core.hooksPath)/pre-commit"

printf '=== clean changes commit ===\n'
fresh_repo
printf 'hello\n' >a.txt
git add a.txt
check 'a clean file commits' commit

printf '=== secrets stop the commit ===\n'
fresh_repo
printf 'one\ntwo\n%s\nbody\n' "$private_key" >key.txt
git add key.txt
check 'a private key header stops it' stopped
check 'the report names the file and line' said 'key.txt:3'
check 'the report leaves the secret out' kept_quiet 'PRIVATE KEY'

fresh_repo
printf 'id = %s\n' "$aws_id" >'my config.txt'
git add 'my config.txt'
check 'an AWS access key id stops it' stopped
check 'a path with a space is reported whole' said 'my config.txt:1'

fresh_repo
printf 'plain\n' >t.txt
git add t.txt
commit
printf 'token=%s\n' "$github_token" >>t.txt
check 'a GitHub token added by commit -a stops it' stopped -a
check 'the line number counts from the hunk' said 't.txt:2'

printf '=== what passes on purpose ===\n'
fresh_repo
printf '%s\n' "$aws_id" >fixture.txt
git add fixture.txt
check 'git commit --no-verify passes a deliberate fake' commit --no-verify
printf 'x\n' >|fixture.txt
git add fixture.txt
check 'removing a secret line commits' commit

printf '=== the repository'"'"'s own pre-commit ===\n'
fresh_repo
printf '#!/bin/sh\ntouch "%s/own-ran"\n' "$work" >.git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
printf 'hello\n' >a.txt
git add a.txt
commit
check 'it runs after a clean scan' test -e "$work/own-ran"
printf '#!/bin/sh\nexit 1\n' >|.git/hooks/pre-commit
printf 'more\n' >>a.txt
git add a.txt
check 'its failure stops the commit' stopped

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
