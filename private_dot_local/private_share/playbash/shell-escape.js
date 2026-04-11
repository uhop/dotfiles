// share/playbash/shell-escape.js — POSIX shell-quoting helpers.
//
// playbash constructs remote shell command lines by template-literal
// interpolation: `sshRun(address, \`mkdir -p ${p} && cat > ${p}\`)`. When
// `p` is an operator-supplied path (put/get/push), interpolating it raw
// means a path containing spaces, quotes, `$()`, backticks, `;`, or `|`
// either silently misbehaves (word-splitting) or executes the embedded
// metacharacters on the remote side. Not adversarial RCE — playbash is
// operator-trusted — but a real correctness bug for legitimate paths with
// spaces in them ("~/my docs/report.pdf").
//
// `shellQuote(s)` does POSIX single-quote escaping: wraps in '...' and
// replaces any ' with '\'' (close-quote, escaped quote, re-open). Safe
// for any byte sequence and shell-standard across bash/dash/zsh/ksh.
// No whitelist validation — rejecting paths by character set would
// refuse legitimate Unix names.
//
// `shellQuotePath(p)` is a tilde-aware variant. Shell tilde expansion
// (~/... or ~user/...) only fires when the `~` is unquoted at the start
// of a word, so `shellQuote('~/foo')` returns "'~/foo'" which the shell
// treats as a literal. That breaks `normalizeRemotePath` in transfer.js,
// whose whole purpose is to emit `~/…` so the remote shell does per-host
// home expansion. `shellQuotePath` keeps a leading `~/` or `~user/` raw
// and quotes only the suffix. Inputs that don't start with `~` go
// through shellQuote unchanged.

export function shellQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

export function shellQuotePath(p) {
  // `~/...` or `~user/...` — keep the tilde-prefix segment raw so the
  // remote shell expands it, quote the rest.
  const tildeMatch = /^(~[^/]*\/)/.exec(p);
  if (tildeMatch) {
    const prefix = tildeMatch[1];
    return prefix + shellQuote(p.slice(prefix.length));
  }
  // Bare `~` or `~user` (no trailing slash) — pure home reference, no
  // remainder to quote. Leave as-is so the shell expands it.
  if (p === '~' || /^~[^/]+$/.test(p)) return p;
  return shellQuote(p);
}
