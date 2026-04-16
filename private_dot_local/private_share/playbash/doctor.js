// share/playbash/doctor.js — `playbash doctor` diagnostic subcommand.
//
// Validates the operator environment and per-host connectivity before
// the user hits a cryptic ssh error mid-run. Two sections:
//
//   1. Environment checks (operator-side, run sequentially):
//        - ~/.ssh/config exists
//        - ssh effective options: ControlMaster, ControlPersist, ControlPath
//          (queried via `ssh -G dummyhost` so Match/Host * blocks apply)
//        - private key files present in ~/.ssh
//        - ssh-agent has at least one key loaded (best-effort: macOS
//          keychain may bypass this)
//        - inventory file present and parseable
//        - ~/.local/bin/playbash-* are executable
//        - playbash.sh and playbash-wrap.py exist locally
//        - python3 on PATH (needed for the wrapper on the operator side
//          when running --self)
//
//   2. Host checks (per inventory host, in parallel):
//        - reachable: ssh -o BatchMode=yes -o ConnectTimeout=5 host true
//          (failures are classified from stderr: timeout, refused, auth,
//          unknown host, host key, other)
//        - ssh-config alias presence: warn if the inventory name has no
//          literal Host entry in ~/.ssh/config or any Include'd file
//          (the user is relying on DNS resolution; usually intentional
//          but worth surfacing)
//        - self hosts are skipped with a "(self)" tag, no ssh probe
//
// Output: green ✓ / orange ⚠ / red ✗ glyphs, optional hints under
// failures and warnings, summary line at the bottom. Exit code 0 if no
// failures (warns are OK), 1 otherwise.

import {existsSync, readdirSync, statSync} from 'node:fs';
import {homedir} from 'node:os';
import {join} from 'node:path';

import {COLOR} from './render.js';
import {INVENTORY_PATH, isSelfAddress, loadInventory} from './inventory.js';
import {HELPER_LIB, LOG_DIR, PLAYBOOK_DIR, PLAYBOOK_PREFIX, PTY_WRAPPER} from './paths.js';
import {parseHostNames} from './ssh-config.js';
import {run} from './subprocess.js';

const SSH_DIR      = join(homedir(), '.ssh');
const SSH_CONFIG   = join(SSH_DIR, 'config');
const PRIVATE_KEYS = ['id_ed25519', 'id_rsa', 'id_ecdsa', 'id_dsa'];

// --- result helper ---

function result(name, status, message, hint) {
  return {name, status, message, hint};
}

// --- subprocess helpers ---

// Parse `ssh -G <host>` output into a Map of lowercased option name → value.
async function sshEffectiveOptions(host) {
  const r = await run('ssh', ['-G', host], {timeoutMs: 5000});
  const map = new Map();
  if (r.code !== 0) return map;
  for (const line of r.stdout.split('\n')) {
    const t = line.trim();
    if (!t) continue;
    const idx = t.indexOf(' ');
    if (idx < 0) continue;
    map.set(t.slice(0, idx).toLowerCase(), t.slice(idx + 1));
  }
  return map;
}

// --- ssh error classification ---

function classifySshError(stderr, timedOut) {
  if (timedOut) {
    return {category: 'timeout', hint: 'host offline or firewall blocking the connection'};
  }
  const s = stderr.toLowerCase();
  if (s.includes('permission denied')) {
    return {category: 'auth', hint: 'run `ssh-copy-id <host>` to install your public key'};
  }
  if (s.includes('connection timed out')) {
    return {category: 'timeout', hint: 'host offline or firewall blocking the connection'};
  }
  if (s.includes('connection refused')) {
    return {category: 'refused', hint: 'sshd not running on the target, or wrong port'};
  }
  if (s.includes('no route to host')) {
    return {category: 'no route', hint: 'network unreachable from this machine'};
  }
  if (s.includes('could not resolve hostname') || s.includes('name or service not known')) {
    return {
      category: 'unknown host',
      hint: 'host not resolving — fix DNS / /etc/hosts, or set `HostName` in the matching ~/.ssh/config Host entry',
    };
  }
  if (s.includes('host key verification failed')) {
    return {category: 'host key', hint: 'review ~/.ssh/known_hosts; consider `ssh-keygen -R <host>`'};
  }
  if (s.includes('kex_exchange_identification')) {
    return {category: 'connection drop', hint: 'sshd dropped the connection — check remote logs'};
  }
  // Generic fallback. Trim noisy first-line.
  const firstLine = stderr.split('\n').find(l => l.trim()) || 'ssh failed';
  return {category: firstLine.trim().slice(0, 60), hint: undefined};
}

// --- log stats ---

function logStats(dir) {
  let files = 0, bytes = 0;
  const walk = d => {
    let entries;
    try { entries = readdirSync(d, {withFileTypes: true}); } catch { return; }
    for (const e of entries) {
      const p = join(d, e.name);
      if (e.isDirectory()) { walk(p); continue; }
      try { bytes += statSync(p).size; files++; } catch {}
    }
  };
  walk(dir);
  return {files, bytes};
}

function humanSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GiB`;
}

// --- environment checks ---

async function checkEnv() {
  const checks = [];

  // ~/.ssh/config exists
  if (existsSync(SSH_CONFIG)) {
    checks.push(result('ssh config', 'ok', `${SSH_CONFIG}`));
  } else {
    checks.push(result(
      'ssh config', 'fail', `${SSH_CONFIG} missing`,
      'create ~/.ssh/config (chezmoi-managed in this repo)',
    ));
  }

  // Effective ssh options via `ssh -G`. We use a non-routable hostname so
  // the call is fast and any Match/Host * blocks still apply.
  const opts = await sshEffectiveOptions('nonexistent.example.invalid');
  const cm = opts.get('controlmaster') || '';
  if (cm.toLowerCase() === 'auto') {
    checks.push(result('ControlMaster', 'ok', 'auto'));
  } else {
    checks.push(result(
      'ControlMaster', 'warn', cm ? `set to "${cm}" (not auto)` : 'not set',
      'add `ControlMaster auto` to ~/.ssh/config Host * for warm masters',
    ));
  }

  const cpersist = opts.get('controlpersist') || '';
  // ssh -G prints `controlpersist 0` when not set; any positive integer or
  // a duration string like `5m` is fine.
  if (cpersist && cpersist !== '0' && cpersist !== 'no') {
    checks.push(result('ControlPersist', 'ok', cpersist));
  } else {
    checks.push(result(
      'ControlPersist', 'warn', 'not set',
      'add `ControlPersist 5m` to ~/.ssh/config Host *',
    ));
  }

  const cpath = opts.get('controlpath') || '';
  if (cpath && cpath !== 'none') {
    checks.push(result('ControlPath', 'ok', cpath));
  } else {
    checks.push(result(
      'ControlPath', 'warn', 'not set',
      'add `ControlPath ~/.ssh/sockets/%r@%h-%p` and `mkdir ~/.ssh/sockets`',
    ));
  }

  // Private keys
  const foundKeys = PRIVATE_KEYS.filter(k => existsSync(join(SSH_DIR, k)));
  if (foundKeys.length > 0) {
    checks.push(result('private key', 'ok', foundKeys.join(', ')));
  } else {
    checks.push(result(
      'private key', 'fail', `none of ${PRIVATE_KEYS.join(', ')} found in ~/.ssh`,
      'run `ssh-keygen -t ed25519` to create one',
    ));
  }

  // ssh-agent (best-effort: macOS keychain may bypass this)
  const sa = await run('ssh-add', ['-L'], {timeoutMs: 3000});
  if (sa.code === 0 && sa.stdout.trim()) {
    const n = sa.stdout.trim().split('\n').length;
    checks.push(result('ssh-agent', 'ok', `${n} key${n === 1 ? '' : 's'} loaded`));
  } else if (sa.code === 1) {
    checks.push(result(
      'ssh-agent', 'warn', 'agent has no identities',
      `run \`ssh-add ~/.ssh/${foundKeys[0] || 'id_ed25519'}\``,
    ));
  } else {
    checks.push(result(
      'ssh-agent', 'warn', 'cannot connect to agent',
      'check `systemctl --user status ssh-agent` on Linux; macOS keychain is fine',
    ));
  }

  // Inventory
  const inv = loadInventory();
  if (!inv.present) {
    checks.push(result(
      'inventory', 'warn', `no inventory at ${INVENTORY_PATH}`,
      'create ~/.config/playbash/inventory.json (optional but recommended)',
    ));
  } else {
    const nh = inv.hosts.size;
    const ng = inv.groups.size;
    checks.push(result('inventory', 'ok', `${nh} host${nh === 1 ? '' : 's'}, ${ng} group${ng === 1 ? '' : 's'}`));
  }

  // Local playbooks
  let entries = [];
  try { entries = readdirSync(PLAYBOOK_DIR); } catch {}
  const playbooks = entries.filter(f => f.startsWith(PLAYBOOK_PREFIX) && !f.endsWith('.js'));
  const nonExec = [];
  for (const f of playbooks) {
    try {
      const st = statSync(join(PLAYBOOK_DIR, f));
      if (!st.isFile() || (st.mode & 0o111) === 0) nonExec.push(f);
    } catch {
      nonExec.push(f);
    }
  }
  if (playbooks.length === 0) {
    checks.push(result(
      'playbooks', 'warn', `no playbooks under ${PLAYBOOK_DIR}/${PLAYBOOK_PREFIX}*`,
      'run `chezmoi apply` to deploy the in-tree playbooks',
    ));
  } else if (nonExec.length > 0) {
    checks.push(result(
      'playbooks', 'fail',
      `${nonExec.length} not executable: ${nonExec.join(', ')}`,
      `run \`chmod +x ${nonExec.map(f => join(PLAYBOOK_DIR, f)).join(' ')}\``,
    ));
  } else {
    checks.push(result('playbooks', 'ok', `${playbooks.length} found, all executable`));
  }

  // playbash.sh helper library
  if (existsSync(HELPER_LIB)) {
    checks.push(result('playbash.sh', 'ok', HELPER_LIB));
  } else {
    checks.push(result(
      'playbash.sh', 'fail', `${HELPER_LIB} missing`,
      'run `chezmoi apply` to deploy the helper library',
    ));
  }

  // PTY wrapper
  if (existsSync(PTY_WRAPPER)) {
    checks.push(result('PTY wrapper', 'ok', PTY_WRAPPER));
  } else {
    checks.push(result(
      'PTY wrapper', 'fail', `${PTY_WRAPPER} missing`,
      'run `chezmoi apply` to deploy the PTY wrapper',
    ));
  }

  // python3 on PATH (operator side; needed for --self runs)
  const py = await run('python3', ['--version'], {timeoutMs: 3000});
  if (py.code === 0) {
    const v = (py.stdout || py.stderr).trim();
    checks.push(result('python3', 'ok', v));
  } else {
    checks.push(result(
      'python3', 'fail', 'not on PATH',
      'install python3 (`apt install python3` / `brew install python3`)',
    ));
  }

  // Run logs
  const stats = logStats(LOG_DIR);
  if (stats.files > 0) {
    checks.push(result('run logs', 'ok', `${stats.files} file${stats.files === 1 ? '' : 's'}, ${humanSize(stats.bytes)} in ${LOG_DIR}`));
  } else {
    checks.push(result('run logs', 'ok', `empty (${LOG_DIR})`));
  }

  return {checks, inventory: inv};
}

// --- per-host checks ---

async function checkHost(name, address, configHostNames) {
  const out = {name, address, status: 'ok', items: []};
  const isSelf = await isSelfAddress(address);
  if (isSelf) {
    out.items.push({status: 'ok', label: '(self) — skipped'});
    return out;
  }

  // ssh-config alias presence. Only meaningful for short names — FQDNs
  // and IP addresses resolve directly via DNS, no Host alias needed. We
  // skip the check when the address contains a dot (FQDN, IPv4) or a
  // colon (IPv6).
  const looksShort = !/[.:]/.test(address);
  if (looksShort && !configHostNames.has(name) && !configHostNames.has(address)) {
    out.items.push({
      status: 'warn',
      label: 'short name with no ssh-config Host entry',
      hint: `add \`Host ${name}\` to ~/.ssh/config (or ~/.ssh/config.d/) so user/port/identity are explicit`,
    });
  }

  // Connectivity probe
  const start = Date.now();
  const r = await run('ssh', [
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=5',
    address, '--', 'true',
  ], {timeoutMs: 8000});
  const elapsed = ((Date.now() - start) / 1000).toFixed(1);

  if (r.code === 0) {
    out.items.push({status: 'ok', label: `reachable in ${elapsed}s`});
  } else {
    const {category, hint} = classifySshError(r.stderr, r.timedOut);
    out.items.push({status: 'fail', label: category, hint});
  }

  // Aggregate worst status across items
  for (const it of out.items) {
    if (it.status === 'fail') { out.status = 'fail'; break; }
    if (it.status === 'warn' && out.status !== 'fail') out.status = 'warn';
  }
  return out;
}

// --- renderer ---

const GLYPH = {
  ok:   () => `${COLOR.green}✓${COLOR.reset}`,
  warn: () => `${COLOR.orange}⚠${COLOR.reset}`,
  fail: () => `${COLOR.fail}✗${COLOR.reset}`,
};

function printHint(hint) {
  if (hint) {
    process.stdout.write(`      ${COLOR.dim}→ ${hint}${COLOR.reset}\n`);
  }
}

function renderEnv(checks) {
  process.stdout.write('environment:\n');
  const nameWidth = Math.max(...checks.map(c => c.name.length));
  for (const c of checks) {
    process.stdout.write(
      `  ${GLYPH[c.status]()} ${c.name.padEnd(nameWidth)}  ${c.message}\n`,
    );
    if (c.status !== 'ok') printHint(c.hint);
  }
}

function renderHosts(hosts) {
  if (hosts.length === 0) return;
  process.stdout.write('\nhosts:\n');
  const nameWidth = Math.max(...hosts.map(h => h.name.length));
  const addrWidth = Math.max(...hosts.map(h => h.address.length));
  for (const h of hosts) {
    // The host's overall status drives the lead glyph; per-item details go
    // on the same row when there's just one item, otherwise stacked.
    const lead = GLYPH[h.status]();
    if (h.items.length === 1) {
      const it = h.items[0];
      process.stdout.write(
        `  ${lead} ${h.name.padEnd(nameWidth)}  ${h.address.padEnd(addrWidth)}  ${it.label}\n`,
      );
      if (it.status !== 'ok') printHint(it.hint);
    } else {
      process.stdout.write(`  ${lead} ${h.name.padEnd(nameWidth)}  ${h.address}\n`);
      for (const it of h.items) {
        const g = GLYPH[it.status]();
        process.stdout.write(`      ${g} ${it.label}\n`);
        if (it.status !== 'ok') printHint(it.hint);
      }
    }
  }
}

function renderSummary(allChecks) {
  let ok = 0, warn = 0, fail = 0;
  for (const c of allChecks) {
    if (c.status === 'ok') ok++;
    else if (c.status === 'warn') warn++;
    else if (c.status === 'fail') fail++;
  }
  process.stdout.write(
    `\n${ok} ok · ${warn} warn · ${fail} fail\n`,
  );
  return fail;
}

// --- public entry point ---

export async function runDoctor() {
  process.stdout.write(`${COLOR.bold}playbash doctor${COLOR.reset}\n\n`);

  const {checks: envChecks, inventory} = await checkEnv();
  renderEnv(envChecks);

  // Per-host checks (parallel). Skip when no inventory.
  let hostResults = [];
  if (inventory.present && inventory.hosts.size > 0) {
    const configHostNames = parseHostNames();
    const hostNames = [...inventory.hosts.keys()].sort();
    hostResults = await Promise.all(
      hostNames.map(name => checkHost(name, inventory.hosts.get(name).address, configHostNames)),
    );
    renderHosts(hostResults);
  }

  const failCount = renderSummary([...envChecks, ...hostResults]);
  process.exit(failCount > 0 ? 1 : 0);
}
