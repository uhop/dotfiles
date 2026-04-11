// share/playbash/paths.js — shared filesystem path constants.
//
// One source of truth for the paths and prefixes that several playbash
// modules need to refer to. Before this file existed, the runner,
// staging.js, and doctor.js each defined their own near-duplicate
// versions, which would have drifted the moment any path moved.

import {homedir} from 'node:os';
import {join} from 'node:path';

// Where the runner and the chezmoi-managed playbooks live on disk.
export const PLAYBOOK_DIR    = join(homedir(), '.local', 'bin');
export const PLAYBOOK_PREFIX = 'playbash-';

// Helper libraries deployed alongside the runner on every managed host.
export const LIBS_DIR        = join(homedir(), '.local', 'libs');
export const HELPER_LIB      = join(LIBS_DIR, 'playbash.sh');
export const PTY_WRAPPER     = join(LIBS_DIR, 'playbash-wrap.py');

// Per-run logs (one file per host/command/timestamp).
export const LOG_DIR         = join(homedir(), '.cache', 'playbash', 'runs');

// The wrapper path used on the *remote* side of a managed run, expressed
// as a literal `~`-prefixed string so the remote shell expands it.
// Distinct from PTY_WRAPPER, which is the operator-side absolute path.
export const WRAPPER_MANAGED = '~/.local/libs/playbash-wrap.py';

// Staging directory used on the *remote* side for vanilla / push runs,
// expressed as a literal `~`-prefixed string for the same reason.
export const STAGING_DIR     = '~/.cache/playbash-staging';
