# test_capabilities.sh — Section 2 probes that don't touch the network.
# Stubs detect::_which / _run / _user / path overrides to isolate logic.

load_lib

# Fixture dir for filesystem-dependent probes.
tmpd=$(mktemp -d /tmp/detect-caps.XXXXXX)
trap 'rm -rf "$tmpd"' EXIT

# ---------- has_cmd ----------

detect::_which() { case "$1" in foo-tool|bar-tool) return 0 ;; *) return 1 ;; esac; }
assert::ok   "has_cmd foo-tool"     detect::has_cmd foo-tool
assert::ok   "has_cmd bar-tool"     detect::has_cmd bar-tool
assert::fail "has_cmd missing"      detect::has_cmd missing

# Memoization: swap _which; cached result should hold.
detect::_which() { return 1; }
assert::ok   "has_cmd foo-tool cached (returns 0 despite new _which=no)"  detect::has_cmd foo-tool
assert::fail "has_cmd missing cached"                                     detect::has_cmd missing

# Reset clears memoization.
detect::reset
detect::_which() { return 1; }
assert::fail "has_cmd foo-tool after reset"  detect::has_cmd foo-tool

# ---------- arch / uname_s ----------

detect::reset
detect::_run() {
  case "$*" in
    "uname -m") echo x86_64 ;;
    "uname -s") echo Linux ;;
    *) return 1 ;;
  esac
}
assert::eq "$(detect::arch)"    "x86_64"  "arch=x86_64"
assert::eq "$(detect::uname_s)" "Linux"   "uname_s=Linux"

# ---------- init_system ----------

detect::reset
detect::_run() { case "$*" in "uname -s") echo Darwin ;; esac; }
detect::_which() { return 1; }
assert::eq "$(detect::init_system)" "launchd"  "init_system: Darwin → launchd"

detect::reset
detect::_run() { case "$*" in "uname -s") echo Linux ;; esac; }
detect::_which() { return 1; }
DETECT_SYSTEMD_RUN="$tmpd/systemd-run"
mkdir -p "$DETECT_SYSTEMD_RUN"
DETECT_OPENRC_SOFTLEVEL="$tmpd/nope-openrc"
assert::eq "$(detect::init_system)" "systemd"  "init_system: /run/systemd/system → systemd"

detect::reset
DETECT_SYSTEMD_RUN="$tmpd/no-systemd"
touch "$tmpd/openrc-softlevel"
DETECT_OPENRC_SOFTLEVEL="$tmpd/openrc-softlevel"
assert::eq "$(detect::init_system)" "openrc"  "init_system: openrc softlevel file → openrc"

detect::reset
DETECT_SYSTEMD_RUN="$tmpd/no-systemd"
DETECT_OPENRC_SOFTLEVEL="$tmpd/no-openrc"
detect::_which() { [[ $1 == runit-init ]]; }
assert::eq "$(detect::init_system)" "runit"  "init_system: runit-init on PATH → runit"

detect::reset
detect::_which() { [[ $1 == s6-svscan ]]; }
assert::eq "$(detect::init_system)" "s6"  "init_system: s6-svscan on PATH → s6"

detect::reset
detect::_which() { return 1; }
assert::eq "$(detect::init_system)" "unknown"  "init_system: no signals → unknown"

# ---------- is_immutable ----------

detect::reset
detect::_which() { return 1; }
DETECT_OSTREE_BOOTED="$tmpd/no-ostree"
assert::fail "is_immutable: mutable FS"  detect::is_immutable

detect::reset
detect::_which() { [[ $1 == rpm-ostree ]]; }
assert::ok "is_immutable: rpm-ostree present"  detect::is_immutable

detect::reset
detect::_which() { [[ $1 == transactional-update ]]; }
assert::ok "is_immutable: transactional-update present"  detect::is_immutable

detect::reset
detect::_which() { return 1; }
touch "$tmpd/ostree-booted"
DETECT_OSTREE_BOOTED="$tmpd/ostree-booted"
assert::ok "is_immutable: /run/ostree-booted present"  detect::is_immutable

# ---------- is_container ----------

detect::reset
DETECT_DOCKERENV="$tmpd/no-docker"
unset container
detect::_which() { return 1; }
assert::fail "is_container: no signals"  detect::is_container

detect::reset
touch "$tmpd/.dockerenv"
DETECT_DOCKERENV="$tmpd/.dockerenv"
assert::ok "is_container: /.dockerenv"  detect::is_container

detect::reset
DETECT_DOCKERENV="$tmpd/no-docker"
container=lxc
assert::ok 'is_container: $container=lxc'  detect::is_container
unset container

detect::reset
detect::_which() { [[ $1 == systemd-detect-virt ]]; }
detect::_run() {
  case "$*" in
    "systemd-detect-virt -c") echo docker; return 0 ;;
    *) return 1 ;;
  esac
}
assert::ok "is_container: systemd-detect-virt -c exit 0"  detect::is_container

# systemd-detect-virt prints "none" AND exits nonzero outside a container.
# Signal is the exit code — output is supplementary.
detect::reset
detect::_which() { [[ $1 == systemd-detect-virt ]]; }
detect::_run() {
  case "$*" in
    "systemd-detect-virt -c") echo none; return 1 ;;
    *) return 1 ;;
  esac
}
assert::fail "is_container: systemd-detect-virt prints 'none', exits 1"  detect::is_container

detect::reset
detect::_which() { [[ $1 == systemd-detect-virt ]]; }
detect::_run() { return 1; }
assert::fail "is_container: systemd-detect-virt absent / nonzero"  detect::is_container

# ---------- is_wsl ----------

detect::reset
unset WSL_DISTRO_NAME WSL_INTEROP
DETECT_WSL_BINFMT="$tmpd/no-wsl"
assert::fail "is_wsl: no signals"  detect::is_wsl

detect::reset
WSL_DISTRO_NAME=Ubuntu
assert::ok "is_wsl: WSL_DISTRO_NAME set"  detect::is_wsl
unset WSL_DISTRO_NAME

detect::reset
WSL_INTEROP=/run/WSL/1_interop
assert::ok "is_wsl: WSL_INTEROP set"  detect::is_wsl
unset WSL_INTEROP

detect::reset
touch "$tmpd/wsl-interop-binfmt"
DETECT_WSL_BINFMT="$tmpd/wsl-interop-binfmt"
assert::ok "is_wsl: binfmt entry exists"  detect::is_wsl

# ---------- sudo_group / can_sudo_nopasswd ----------

detect::reset
DETECT_USER_OVERRIDE=tester
detect::_run() {
  case "$*" in
    "id -nG tester") echo "tester users sudo" ;;
    "sudo -n true")  return 0 ;;
    *) return 1 ;;
  esac
}
detect::_which() { [[ $1 == sudo ]]; }
assert::eq "$(detect::sudo_group)" "sudo" "sudo_group: user in sudo"
assert::ok "can_sudo_nopasswd: yes"  detect::can_sudo_nopasswd

detect::reset
DETECT_USER_OVERRIDE=wheeluser
detect::_run() {
  case "$*" in
    "id -nG wheeluser") echo "wheeluser wheel" ;;
    *) return 1 ;;
  esac
}
detect::_which() { return 1; }
assert::eq "$(detect::sudo_group)" "wheel" "sudo_group: user in wheel"
assert::fail "can_sudo_nopasswd: no sudo binary"  detect::can_sudo_nopasswd

detect::reset
DETECT_USER_OVERRIDE=macuser
detect::_run() {
  case "$*" in
    "id -nG macuser") echo "macuser admin staff" ;;
    *) return 1 ;;
  esac
}
assert::eq "$(detect::sudo_group)" "admin" "sudo_group: user in admin (macOS)"

detect::reset
DETECT_USER_OVERRIDE=plain
detect::_run() {
  case "$*" in
    "id -nG plain") echo "plain users" ;;
    *) return 1 ;;
  esac
}
assert::eq "$(detect::sudo_group)" "" "sudo_group: user in no sudo group"

# Priority: wheel beats sudo beats admin when multiple are present.
detect::reset
DETECT_USER_OVERRIDE=multi
detect::_run() {
  case "$*" in
    "id -nG multi") echo "multi wheel sudo admin" ;;
    *) return 1 ;;
  esac
}
assert::eq "$(detect::sudo_group)" "wheel" "sudo_group: wheel wins over sudo+admin"

# ---------- desktop ----------

detect::reset
detect::_run() { case "$*" in "uname -s") echo Darwin ;; esac; }
detect::_which() { return 1; }
unset XDG_CURRENT_DESKTOP DESKTOP_SESSION DISPLAY WAYLAND_DISPLAY
assert::eq "$(detect::desktop)" "aqua" "desktop: Darwin → aqua"

detect::reset
detect::_run() { case "$*" in "uname -s") echo Linux ;; esac; }
detect::_which() { return 1; }
XDG_CURRENT_DESKTOP="GNOME"; unset DESKTOP_SESSION DISPLAY WAYLAND_DISPLAY
assert::eq "$(detect::desktop)" "gnome" "desktop: XDG=GNOME"

detect::reset
XDG_CURRENT_DESKTOP="ubuntu:GNOME"
assert::eq "$(detect::desktop)" "gnome" "desktop: XDG=ubuntu:GNOME → gnome"

detect::reset
XDG_CURRENT_DESKTOP="KDE"
assert::eq "$(detect::desktop)" "kde" "desktop: XDG=KDE"

detect::reset
XDG_CURRENT_DESKTOP="Budgie:GNOME"
assert::eq "$(detect::desktop)" "budgie" "desktop: Budgie:GNOME → budgie (first match wins)"

detect::reset
XDG_CURRENT_DESKTOP="X-Cinnamon"
assert::eq "$(detect::desktop)" "cinnamon" "desktop: X-Cinnamon → cinnamon"

detect::reset
XDG_CURRENT_DESKTOP="Hyprland"
assert::eq "$(detect::desktop)" "hyprland" "desktop: Hyprland → hyprland"

detect::reset
unset XDG_CURRENT_DESKTOP
DESKTOP_SESSION="xfce"
assert::eq "$(detect::desktop)" "xfce" "desktop: falls through to DESKTOP_SESSION"

detect::reset
unset XDG_CURRENT_DESKTOP DESKTOP_SESSION
detect::_which() { case "$1" in gnome-shell) return 0 ;; *) return 1 ;; esac; }
assert::eq "$(detect::desktop)" "gnome" "desktop: binary-presence fallback → gnome-shell"

detect::reset
detect::_which() { return 1; }
DISPLAY=":0"
assert::eq "$(detect::desktop)" "unknown" "desktop: GUI env present but no known DE"

detect::reset
unset DISPLAY WAYLAND_DISPLAY
assert::eq "$(detect::desktop)" "headless" "desktop: no GUI markers → headless"

# ---------- has_grd / has_sunshine / has_xrdp ----------

# Point DETECT_GRD_DAEMON_PATHS at a nonexistent path so the has_grd
# daemon-fallback doesn't hit the real filesystem on the test host.
DETECT_GRD_DAEMON_PATHS="$tmpd/grd-daemon-nonexistent"

detect::reset
detect::_which() { case "$1" in grdctl) return 0 ;; *) return 1 ;; esac; }
assert::ok   "has_grd: grdctl present"      detect::has_grd
assert::fail "has_sunshine: absent"          detect::has_sunshine
assert::fail "has_xrdp: absent"              detect::has_xrdp

detect::reset
detect::_which() { case "$1" in sunshine|xrdp) return 0 ;; *) return 1 ;; esac; }
assert::fail "has_grd: grdctl absent and no binary"  detect::has_grd
assert::ok   "has_sunshine: sunshine binary present" detect::has_sunshine
assert::ok   "has_xrdp: xrdp binary present"         detect::has_xrdp

# has_grd: grdctl absent, daemon binary present at a custom path
detect::reset
detect::_which() { return 1; }
command touch "$tmpd/grd-daemon" && command chmod +x "$tmpd/grd-daemon"
DETECT_GRD_DAEMON_PATHS="$tmpd/grd-daemon"
assert::ok   "has_grd: daemon binary at overridden path" detect::has_grd
