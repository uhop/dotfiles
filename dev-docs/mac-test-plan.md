# macOS test plan

What to verify on a macOS machine after the recent refactor (`osFamily`/`pkgManager`
variables, sudoers.d support, doas opt-in, RHEL support, etc.).

## Prerequisites

- A Mac (Intel or Apple Silicon — both should work, brew path differs)
- Admin user (member of `admin` group; check with `groups`)
- Xcode Command Line Tools installed (`xcode-select --install`)
- The dotfiles repo at `~/.local/share/chezmoi/` (cloned via chezmoi or manually)

## 1. Template variable computation

```bash
chezmoi execute-template --init --promptBool hasGui=true \
  --promptString name="Test" --promptString email="t@t.com" \
  --promptString githubUsername="uhop" < ~/.local/share/chezmoi/.chezmoi.toml.tmpl
```

**Expected:**
- `osId = "darwin"`
- `osIdLike = "darwin"`
- `osFamily = "darwin"`
- `pkgManager = "brew-only"`

## 2. Sudoers.d template rendering

After running `chezmoi init`, check what the sudoers script would render:

```bash
chezmoi execute-template < ~/.local/share/chezmoi/run_onchange_after_install-sudoers.sh.tmpl | grep -E '%admin'
```

**Expected:**
- A single rule: `%admin ALL=(ALL) NOPASSWD: /usr/sbin/softwareupdate`
- No apt/dnf/snap rules
- No systemctl/ping rules (those are Linux-only)

## 3. Sudoers.d install path

After `chezmoi apply`, verify the file was installed:

```bash
ls -la /etc/sudoers.d/chezmoi
sudo cat /etc/sudoers.d/chezmoi
```

**Expected:**
- File exists at `/etc/sudoers.d/chezmoi`
- Permissions `0440` (`-r--r-----`)
- Owner `root`, group `wheel` (note: macOS uses `wheel`, not `root`)
- Contains the `%admin ... softwareupdate` rule

**Critical:** macOS sudo silently ignores files in `/etc/sudoers.d/` with the wrong
owner/group/perms. If `sudo -n /usr/sbin/softwareupdate -l` still asks for a password,
run `sudo visudo -cf /etc/sudoers.d/chezmoi` and check ownership.

## 4. Verify passwordless `softwareupdate`

```bash
sudo -n /usr/sbin/softwareupdate -l
echo "exit: $?"
```

**Expected:** Lists available updates without asking for password, exit code 0.

If it fails: check that the user is in the `admin` group (`groups`), and that the
sudoers file has the right perms.

## 5. Verify other commands still need password

```bash
sudo -n cat /etc/master.passwd 2>&1
```

**Expected:** `sudo: a password is required` — confirms we only granted what we
intended to grant.

## 6. `upd` command

```bash
upd
```

**Expected:**
- Runs `softwareupdate -i -a` without sudo (we removed the sudo wrapper earlier)
- Runs `mas upgrade` if `mas` is installed (runtime check)
- Runs `brew update` and `brew upgrade`
- Does NOT try to call `apt`, `dnf`, `snap`, or `flatpak`
- Does NOT use any `osIdLike == "darwin"` or `pkgManager == "brew-only"` checks
  (verify by reading `~/.local/bin/upd` after deploy)

## 7. `cln` command

```bash
cln -y
```

**Expected:**
- Does NOT call `apt autoremove` or `dnf autoremove`
- Runs `brew autoremove` and `brew cleanup`
- Runs `flatpak uninstall --unused` only if flatpak is installed (it shouldn't be on macOS)
- Runs `docker system prune` only if docker is installed

## 8. `.bashrc` brew path detection

Open a new interactive shell and verify brew is initialized:

```bash
echo $HOMEBREW_PREFIX
which brew
```

**Expected:**
- Apple Silicon: `/opt/homebrew`
- Intel: `/usr/local`
- The `.bashrc` should source `brew shellenv` from the right location.

## 9. `.bash_aliases` runtime checks

Run these in an interactive shell and verify no errors:

```bash
type rm        # should NOT have --preserve-root on macOS
type chown     # should NOT be aliased on macOS
type psr psm   # should use BSD ps flags (-r, -m), not GNU --sort=
type psmem     # should NOT exist on macOS (Linux-only)
type dirty     # should NOT exist on macOS (Linux-only)
```

## 10. Git alias completions

```bash
complete -p gst gco gcob gcm gbr grs gpull gpush gsw gme
```

**Expected:** All 10 aliases show `__git_wrap_*` completion functions registered.

## 11. doas (should NOT be installed by default)

```bash
command -v doas
# expected: no output (doas not installed)
```

If you want doas on macOS for some reason, install it manually:
```bash
brew install doas
sudo cp /opt/homebrew/etc/doas.conf.example /etc/doas.conf
# edit as needed
```

The `run_onchange_after_install-doas.sh.tmpl` script will then manage `/etc/doas.conf`
on subsequent `chezmoi apply` runs. Both sudoers and doas rules coexist safely.

## 12. Bash shell version

```bash
echo $BASH_VERSION
```

**Expected:** 5.x (the brew-installed bash, not the system 3.x). The `bootstrap-dotfiles`
script switches the default shell to `$(brew --prefix)/bin/bash` automatically.

## 13. fastfetch on shell open

Open a new terminal and verify fastfetch shows up.

## 14. Terminal UI sizes

If you use Alacritty/Kitty/Ghostty, verify font size is 16 (the macOS default in our templates).

```bash
grep -E '(size|font_size|font-size)' ~/.config/alacritty/alacritty.toml ~/.config/kitty/kitty.conf ~/.config/ghostty/config 2>/dev/null
```

## Edge cases to think about

- **Apple Silicon vs Intel:** brew install path differs. The `.bashrc` checks both, but
  worth verifying on whichever you have.
- **non-admin user:** if a user isn't in the `admin` group, `hasSudo` is 0 and the
  sudoers script skips itself. Test by `chezmoi apply` as a non-admin user.
- **Existing sudoers.d files:** if `/etc/sudoers.d/chezmoi` exists from a previous
  install with different content, the script should overwrite it. Verify with
  `sudo cat` before and after.
- **macOS sudo behavior:** `softwareupdate -l` (list) should also be passwordless
  with our rule because the rule allows `/usr/sbin/softwareupdate` with any args.
  If not, the rule might need to be split.

## Things NOT to test on Mac

These are tested on Linux containers and don't need re-testing on Mac:
- apt/dnf package installation
- snap, flatpak, EPEL, etckeeper (Linux-only)
- LXC/lxd usage
- bash-completion's `__git_complete` (works the same way)
