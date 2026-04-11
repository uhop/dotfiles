// share/playbash/errors.js — shared error-exit helper.
//
// `die(msg, code = 2)` writes a prefixed message to stderr and exits the
// process. Every playbash module used to define its own local copy (the
// runner, the dispatcher, transfer.js, commands.js, inventory.js) — all
// byte-identical. They now import this one.

export function die(msg, code = 2) {
  process.stderr.write(`playbash: ${msg}\n`);
  process.exit(code);
}
