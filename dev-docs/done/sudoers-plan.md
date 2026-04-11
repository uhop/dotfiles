# Passwordless sudo via sudoers.d

**Status:** Plan

## Problem

Non-interactive tools (`playbash`, `upd -y`, `cln -y`) need passwordless privilege
escalation for system package management. Currently this is solved by `doas` with
passwordless rules in `/etc/doas.conf`, but:

- `doas` is only available on Debian via `opendoas`
- Not packaged for RHEL/Fedora or macOS
- RHEL and macOS are stuck prompting for passwords, breaking playbash automation

## Solution

Drop a file into `/etc/sudoers.d/` with `NOPASSWD` rules for the specific commands
that `upd`, `cln`, and related scripts need. `sudoers.d` is a standard sudo feature
that works on all three platforms (Debian, RHEL, macOS).

## Relationship to doas

- **doas stays.** If the user has installed and configured doas, it is aliased
  as `sudo` in `.bash_aliases` and `bootstrap.sh`.
- **Both are always installed.** sudoers.d rules cover all contexts (cron,
  non-interactive shells) while doas handles interactive shells via the alias.
- The doas install script (`run_onchange_after_install-doas.sh.tmpl`) continues to
  manage `/etc/doas.conf` when doas is present. The two don't conflict — doas rules
  are evaluated by `doas`, sudoers rules by `sudo`, and only one is active at a time
  because of the alias.
- **Long-term:** doas could be phased out since sudoers.d covers all platforms.
  But no rush — both can coexist indefinitely.

## Per-platform rules

### Group name

| Platform | Sudo group | Syntax |
|---|---|---|
| Debian/Ubuntu | `sudo` | `%sudo` |
| RHEL/Fedora | `wheel` | `%wheel` |
| macOS | `admin` | `%admin` |

Chezmoi template selects the right group based on `osFamily` + `osIdLike`.

### Command paths

Commands require full paths in sudoers. These differ by platform.

**Debian (apt):**
```
%sudo ALL=(ALL) NOPASSWD: /usr/bin/apt update
%sudo ALL=(ALL) NOPASSWD: /usr/bin/apt upgrade *
%sudo ALL=(ALL) NOPASSWD: /usr/bin/apt -y upgrade
%sudo ALL=(ALL) NOPASSWD: /usr/bin/apt autoremove *
%sudo ALL=(ALL) NOPASSWD: /usr/bin/apt -y autoremove
%sudo ALL=(ALL) NOPASSWD: /usr/bin/apt autoclean *
%sudo ALL=(ALL) NOPASSWD: /usr/bin/apt -y autoclean
%sudo ALL=(ALL) NOPASSWD: /usr/bin/snap refresh
%sudo ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart docker
%sudo ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart containerd
%sudo ALL=(ALL) NOPASSWD: /usr/bin/aa-remove-unknown
%sudo ALL=(ALL) NOPASSWD: /usr/bin/ping
%sudo ALL=(ALL) NOPASSWD: /usr/bin/prettyping *
```

**RHEL/Fedora (dnf):**
```
%wheel ALL=(ALL) NOPASSWD: /usr/bin/dnf upgrade *
%wheel ALL=(ALL) NOPASSWD: /usr/bin/dnf -y upgrade
%wheel ALL=(ALL) NOPASSWD: /usr/bin/dnf autoremove *
%wheel ALL=(ALL) NOPASSWD: /usr/bin/dnf -y autoremove
%wheel ALL=(ALL) NOPASSWD: /usr/bin/dnf clean *
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart docker
%wheel ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart containerd
%wheel ALL=(ALL) NOPASSWD: /usr/bin/ping
```

**macOS (brew-only):**
```
%admin ALL=(ALL) NOPASSWD: /usr/sbin/softwareupdate *
```

Note: `brew` itself doesn't need sudo. `mas` doesn't need sudo.
macOS has fewer rules because most updates are user-level.

## Implementation

### New file: `run_onchange_after_install-sudoers.sh.tmpl`

A `run_onchange_after_` script (re-runs when rules change). Structure:

1. **Guard:** skip if user has no sudo access (`hasSudo != 0`)
2. **Render rules:** select the platform-appropriate block
3. **Validate:** write to temp file, run `visudo -cf <tmpfile>` to validate syntax
4. **Install:** `sudo install -m 0440 -o root -g root <tmpfile> /etc/sudoers.d/chezmoi`
   (macOS: `-g wheel` instead of `-g root`)
5. **Idempotent:** compare rendered rules with existing file, skip write if identical

### Template structure

```
{{ if eq .osFamily "linux" -}}
{{   if eq .pkgManager "apt" -}}
{{     $sudoGroup := "sudo" }}
...apt rules with $sudoGroup...
{{   else if eq .pkgManager "dnf" -}}
{{     $sudoGroup := "wheel" }}
...dnf rules with $sudoGroup...
{{   end -}}
{{ else if eq .osFamily "darwin" -}}
{{   $sudoGroup := "admin" }}
...macOS rules with $sudoGroup...
{{ end -}}
```

### File permissions

sudoers.d files must be:
- Owned by `root:root` (Linux) or `root:wheel` (macOS)
- Mode `0440` (read-only for owner+group, no world access)
- No `.` or `~` in filename (sudo ignores them)

### Validation

`visudo -cf /path/to/file` checks syntax without modifying anything. If it fails,
refuse to install (same pattern as `doas -C` in the doas script).

## Changes to existing scripts

### `upd.tmpl` / `cln.tmpl`

No changes needed. They already use `sudo` (or the doas alias). The sudoers rules
make those `sudo` calls passwordless — the scripts don't need to know how.

### `install-doas.sh.tmpl`

No changes. It stays as-is — manages doas when doas is present.

### `install-packages.sh.tmpl`

Already installs `opendoas` on Debian. Could optionally skip `opendoas` from the
apt install list if we decide sudoers.d replaces doas long-term. Not urgent.

## Rollback

If the user wants to remove the sudoers rules:
```bash
sudo rm /etc/sudoers.d/chezmoi
```

## Open questions

1. ~~**Should we skip sudoers when doas is active?**~~ **Resolved:** No. Both
   coexist safely. The sudoers rules serve as a fallback for contexts where
   the doas alias isn't active (cron, non-interactive shells).
2. **Phase out doas?** Not yet. Some users prefer doas for its simplicity and
   auditability. Keep both paths for now.
3. **Should non-privileged users get sudoers rules?** No — `hasSudo` guard
   skips the script entirely if the user can't sudo. An admin installs once,
   all sudo-group members benefit.
