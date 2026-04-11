// share/playbash/errors.js — shared error-exit helper.
//
// `die(msg, code = 2)` writes a prefixed message to stderr and exits the
// process. Every playbash module used to define its own local copy (the
// runner, the dispatcher, transfer.js, commands.js, inventory.js) — all
// byte-identical. They now import this one.

export function die(msg, code = 2) {
  // Coerce non-string inputs at the boundary so an accidentally-passed
  // Error object or other value prints something meaningful instead of
  // `[object Object]`. All current callers pass strings; this is a safety
  // net for future maintenance.
  const text = typeof msg === 'string' ? msg : String(msg);
  process.stderr.write(`playbash: ${text}\n`);
  process.exit(code);
}
