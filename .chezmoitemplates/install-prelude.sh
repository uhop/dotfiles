# install-prelude.sh — shared header for run_*_install-*.sh chezmoi scripts.
#
# Inlined into each install script via {{`{{ template "install-prelude.sh" . }}`}}
# at template-render time. Provides:
#
#   - bash strict mode
#   - sudo/doas alias detection
#   - $hasSudo (0 = user is in sudo/admin/wheel group, 1 = otherwise)
#   - ANSI color macros via tput: $WARN, $PROMPT, $RESET
#
# Lives under .chezmoitemplates/ — files there are template snippets, not
# deployed to ~/. Edit here and every install script picks up the change
# on next chezmoi apply (via the run_onchange_/run_once_ hash).

set -euCo pipefail
shopt -s expand_aliases

command -v doas &>/dev/null && [ -f /etc/doas.conf ] && alias sudo='doas' || true

groups "$(id -un)" | grep -qE '\b(sudo|admin|wheel)\b'
hasSudo=$?

CYAN="$(tput setaf 6 2>/dev/null || true)"
BRIGHT_WHITE="$(tput setaf 15 2>/dev/null || true)"
BG_BLUE="$(tput setab 4 2>/dev/null || true)"
BOLD="$(tput bold 2>/dev/null || true)"
RESET="$(tput op 2>/dev/null || true)$(tput sgr0 2>/dev/null || true)"

WARN="$BOLD$BRIGHT_WHITE$BG_BLUE"
PROMPT="$BOLD$CYAN"
