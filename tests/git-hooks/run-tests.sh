#!/usr/bin/env bash
# run-tests.sh — the global secret scan (dot_config/git/hooks/executable_pre-commit), as
# pre-commit and through its symlinks as pre-applypatch (git am) and pre-merge-commit
# (git merge).
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

unset VAULT_API_TOKEN PROGRAM_CLERK_KEY
export HOME="$work/home"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME/.config/git/hooks"
cp "$source_dir/dot_config/git/hooks/executable_pre-commit" "$HOME/.config/git/hooks/pre-commit"
chmod +x "$HOME/.config/git/hooks/pre-commit"
for link in "$source_dir"/dot_config/git/hooks/symlink_*; do
  [[ -e $link ]] || continue
  ln -s "$(<"$link")" "$HOME/.config/git/hooks/${link##*/symlink_}"
done
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
named_key="vsk_$(printf 'A%.0s' {1..43})"
account_key="pck_$(printf 'a%.0s' {1..8})_$(printf 'b%.0s' {1..30})"
operator_token=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')

printf '=== the hook comes from the template'"'"'s hooksPath line ===\n'
fresh_repo
check 'core.hooksPath expands to the installed hook' test -x "$(git config --path core.hooksPath)/pre-commit"
check 'it is linked as pre-applypatch' test -x "$(git config --path core.hooksPath)/pre-applypatch"
check 'and as pre-merge-commit' test -x "$(git config --path core.hooksPath)/pre-merge-commit"

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

printf '=== our own keys ===\n'
fresh_repo
printf 'key: %s\n' "$named_key" >named.txt
git add named.txt
check 'a Program Clerk named key stops it' stopped
fresh_repo
printf 'key: %s\n' "$account_key" >account.txt
git add account.txt
check 'an account-system key stops it' stopped

fresh_repo
export VAULT_API_TOKEN="$operator_token"
printf 'curl -H "Authorization: Bearer %s"\n' "$operator_token" >call.sh
git add call.sh
check 'the operator token, by its exact value, stops it' stopped
check 'the report names the file and line' said 'call.sh:1'
check 'the report leaves the value out' kept_quiet "$operator_token"
unset VAULT_API_TOKEN

fresh_repo
export PROGRAM_CLERK_KEY=short123
printf 'short123\n' >short.txt
git add short.txt
check 'a value under 16 characters stops nothing' commit
export PROGRAM_CLERK_KEY=
printf 'anything\n' >|short.txt
git add short.txt
check 'an empty value stops nothing' commit
unset PROGRAM_CLERK_KEY

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

head_is() { [[ $(git rev-parse HEAD) == "$1" ]]; }
am() { git am -q "$@" >/dev/null 2>|"$work/stderr"; }
am_stopped() { ! am "$@"; }
merge() { git merge -q --no-edit "$@" >/dev/null 2>|"$work/stderr"; }
merge_stopped() { ! merge "$@"; }
# A patch of one commit on top of the repository's first commit, made without the scan.
make_patch() {
  local out=$1 file=$2 line=$3
  git checkout -q -b patch-src
  printf '%s\n' "$line" >>"$file"
  git add "$file"
  git commit -q -m "add to $file" --no-verify
  git format-patch -q -1 --stdout >"$out"
  git checkout -q main
  git branch -q -D patch-src
}

printf '=== git am ===\n'
fresh_repo
printf 'base\n' >a.txt
git add a.txt
commit
base=$(git rev-parse HEAD)
make_patch "$work/key.patch" a.txt "keep"$'\n'"id = $aws_id"
make_patch "$work/clean.patch" b.txt 'hello'
check 'a patch that adds a secret is stopped' am_stopped "$work/key.patch"
check 'the report names the hook' said 'pre-applypatch: stopped'
check 'and the file and line' said 'a.txt:3'
check 'and points at git am --no-verify' said 'goes through with git am --no-verify'
check 'nothing was committed' head_is "$base"
printf 'base\nkeep\n' >|a.txt
git add a.txt
check 'git am --continue after taking it out commits the rest of the patch' am --continue
check 'without the line' bash -c '! grep -q AKIA a.txt'
git am --abort 2>/dev/null || true
git reset -q --hard "$base"
check 'git am --no-verify applies a deliberate fake' am --no-verify "$work/key.patch"
git reset -q --hard "$base"
check 'a clean patch applies' am "$work/clean.patch"

fresh_repo
printf 'base\n' >a.txt
git add a.txt
commit
base=$(git rev-parse HEAD)
printf '#!/bin/sh\ntouch "%s/own-am-ran"\n' "$work" >.git/hooks/pre-applypatch
chmod +x .git/hooks/pre-applypatch
check 'the repository'"'"'s own pre-applypatch runs after a clean scan' \
  bash -c 'git am -q "$1" >/dev/null 2>&1 && test -e "$2"' _ "$work/clean.patch" "$work/own-am-ran"
git reset -q --hard "$base"
printf '#!/bin/sh\nexit 1\n' >|.git/hooks/pre-applypatch
check 'its failure stops git am' am_stopped "$work/clean.patch"
git am --abort 2>/dev/null || true

printf '=== git merge ===\n'
fresh_repo
printf 'base\n' >a.txt
git add a.txt
commit
git checkout -q -b side
printf 'token=%s\n' "$github_token" >side.txt
git add side.txt
git commit -q -m side --no-verify
git checkout -q -b clean main
printf 'clean\n' >clean.txt
git add clean.txt
commit
git checkout -q main
printf 'main\n' >m.txt
git add m.txt
commit
before=$(git rev-parse HEAD)
check 'a merge that brings in a secret is stopped' merge_stopped side
check 'the report names the hook' said 'pre-merge-commit: stopped'
check 'and the file and line' said 'side.txt:1'
check 'and points at git merge --no-verify' said 'goes through with git merge --no-verify'
check 'no merge commit was made' head_is "$before"
printf 'token=\n' >|side.txt
git add side.txt
check 'taking it out, git commit makes the merge commit' commit --no-edit
check 'with both parents' test "$(git rev-list --parents -n 1 HEAD | wc -w)" -eq 3
git reset -q --hard "$before"
merge side || true
check 'git merge --abort is open' bash -c 'git merge --abort 2>/dev/null'
check 'git merge --no-verify merges a deliberate fake' merge --no-verify side
git reset -q --hard "$before"
check 'a clean merge commits' merge clean
git reset -q --hard "$before"
printf '#!/bin/sh\nexit 1\n' >.git/hooks/pre-merge-commit
chmod +x .git/hooks/pre-merge-commit
check 'the repository'"'"'s own pre-merge-commit still runs and can stop it' merge_stopped clean

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
