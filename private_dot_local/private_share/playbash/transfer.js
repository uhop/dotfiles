// share/playbash/transfer.js — `playbash put` / `playbash get` file transfer.
//
// User-facing single-file and tar-based directory transfer with the same
// fan-out, status-board, and offline-detection UX as the playbook commands.
// Both subcommands take a pre-validated target list (computed by the
// dispatcher's resolveAndValidate) as their first argument, so this module
// has no dependency on parseArgs / CLI globals.
//
// Internal helpers (runTransferSingle, putOne, getOne, normalizeRemotePath)
// are not exported — they're implementation details of cmdPut/cmdGet.

import {existsSync, mkdirSync, readFileSync, statSync, writeFileSync} from 'node:fs';
import {homedir} from 'node:os';
import {basename, dirname} from 'node:path';
import {spawn} from 'node:child_process';

import {COLOR, buildStatusLine, truncateStatus} from './render.js';
import {die} from './errors.js';
import {expandTemplate, runFanout} from './runner.js';
import {shellQuote, shellQuotePath} from './shell-escape.js';
import {sshRun} from './staging.js';

// Bash expands `~` and `~user` on the command line BEFORE playbash sees the
// argument, so `playbash put all foo ~/.config/bar` arrives as
// `... /home/eugene/.config/bar`. That literal absolute path then fails on
// any host where the operator's local home prefix doesn't exist (macOS uses
// /Users/<name>; mini2 in our fleet was the trigger). Detect the operator's
// local home prefix and rewrite to a literal `~`, so the remote shell
// expands it per-target. The remote path resolution belongs on the remote.
//
// Only intended for the user-supplied remote path argument of put/get.
// Local paths and chezmoi-managed remote paths (which already use literal
// `~/...`) are unaffected.
function normalizeRemotePath(path) {
  const home = homedir();
  if (path === home) return '~';
  if (path.startsWith(home + '/')) return '~' + path.slice(home.length);
  return path;
}

// When sudoPassword is set, wrap a remote command for `sudo -S` and return
// the password bytes to prepend to stdin. `sudo -S` reads one line (the
// password) from stdin, then the remainder flows to the wrapped command.
function sudoWrap(cmd, sudoPassword) {
  if (!sudoPassword) return {cmd, inputPrefix: null};
  return {
    cmd: `sudo -S sh -c ${shellQuote(cmd)}`,
    inputPrefix: Buffer.from(sudoPassword + '\n')
  };
}

// After a sudo-wrapped sshRun, check stderr for wrong-password indicators
// and throw a clear error instead of the raw sudo output.
function checkSudoError(r, sudoPassword) {
  if (sudoPassword && r.code !== 0 &&
      /sorry, try again|authentication failed/i.test(r.stderr)) {
    throw new Error('wrong password');
  }
}

// Transfer a single file or directory to a remote host. `remotePath` is
// operator-supplied and may contain spaces, quotes, or `~` — quoted via
// shellQuotePath so the remote shell interprets it as one word while
// preserving leading `~` home expansion.
async function putOne(address, localPath, remotePath, isDir, sudoPassword) {
  const qRemote = shellQuotePath(remotePath);
  if (isDir) {
    const tarBuf = await new Promise((resolve, reject) => {
      const ch = [];
      const p = spawn('tar', ['cf', '-', '-C', localPath, '.'], {
        stdio: ['ignore', 'pipe', 'pipe']
      });
      p.stdout.on('data', c => ch.push(c));
      p.on('error', reject);
      p.on('close', code =>
        code === 0
          ? resolve(Buffer.concat(ch))
          : reject(new Error(`tar exit ${code}`))
      );
    });
    const {cmd, inputPrefix} = sudoWrap(
      `mkdir -p ${qRemote} && tar xf - -C ${qRemote}`,
      sudoPassword
    );
    const input = inputPrefix ? Buffer.concat([inputPrefix, tarBuf]) : tarBuf;
    const r = await sshRun(address, cmd, {input});
    checkSudoError(r, sudoPassword);
    if (r.code !== 0) throw new Error(r.stderr.trim() || `exit ${r.code}`);
  } else {
    const content = readFileSync(localPath);
    const remoteDir = remotePath.includes('/')
      ? remotePath.substring(0, remotePath.lastIndexOf('/'))
      : '';
    const mkdirCmd = remoteDir ? `mkdir -p ${shellQuotePath(remoteDir)} && ` : '';
    const {cmd, inputPrefix} = sudoWrap(`${mkdirCmd}cat > ${qRemote}`, sudoPassword);
    const input = inputPrefix ? Buffer.concat([inputPrefix, content]) : content;
    const r = await sshRun(address, cmd, {input});
    checkSudoError(r, sudoPassword);
    if (r.code !== 0) throw new Error(r.stderr.trim() || `exit ${r.code}`);
  }
}

// Transfer a single file or directory from a remote host. See putOne for
// the shellQuotePath rationale.
async function getOne(address, remotePath, localPath, isRemoteDir, sudoPassword) {
  const qRemote = shellQuotePath(remotePath);
  if (isRemoteDir) {
    const {cmd, inputPrefix} = sudoWrap(`tar cf - -C ${qRemote} .`, sudoPassword);
    const r = await sshRun(address, cmd, {raw: true, ...(inputPrefix && {input: inputPrefix})});
    checkSudoError(r, sudoPassword);
    if (r.code !== 0) throw new Error(r.stderr.trim() || `exit ${r.code}`);
    mkdirSync(localPath, {recursive: true});
    await new Promise((resolve, reject) => {
      const p = spawn('tar', ['xf', '-', '-C', localPath], {
        stdio: ['pipe', 'ignore', 'pipe']
      });
      p.stdin.write(r.stdout);
      p.stdin.end();
      p.on('error', reject);
      p.on('close', code =>
        code === 0 ? resolve() : reject(new Error(`tar extract exit ${code}`))
      );
    });
  } else {
    const {cmd, inputPrefix} = sudoWrap(`cat ${qRemote}`, sudoPassword);
    const r = await sshRun(address, cmd, {raw: true, ...(inputPrefix && {input: inputPrefix})});
    checkSudoError(r, sudoPassword);
    if (r.code !== 0) throw new Error(r.stderr.trim() || `exit ${r.code}`);
    const localDir = dirname(localPath);
    if (localDir) mkdirSync(localDir, {recursive: true});
    writeFileSync(localPath, r.stdout);
  }
}

// Single-host transfer wrapper (shared by put/get). Prints status line and
// exits the process on failure (the only fast path that doesn't go through
// the StatusBoard, since one target doesn't need a board).
async function runTransferSingle(target, mode, transferFn) {
  try {
    const start = Date.now();
    const msg = await transferFn(target.name, target.address);
    const elapsed = ((Date.now() - start) / 1000).toFixed(1);
    process.stderr.write(
      buildStatusLine({
        ok: true,
        hostName: target.name,
        playbook: mode,
        label: null,
        status: '',
        elapsed
      }) + '\n'
    );
    if (msg) process.stderr.write(`  ${COLOR.dim}${msg}${COLOR.reset}\n`);
  } catch (err) {
    process.stderr.write(
      buildStatusLine({
        ok: false,
        hostName: target.name,
        playbook: mode,
        label: null,
        status: truncateStatus(err.message),
        elapsed: '0.0'
      }) + '\n'
    );
    process.exit(1);
  }
}

// Upload a file or directory to one or more targets.
//
// `validated` is the {targets, offlineNames, parallelLimit, ...} bundle
// produced by the dispatcher's resolveAndValidate — having the dispatcher
// pre-validate keeps this module free of CLI-global dependencies.
export async function cmdPut(validated, localPathTemplate, remotePathArg, sudoPassword) {
  // Normalize the operator-side home prefix so the remote shell does the
  // home resolution per-target (see normalizeRemotePath). Local path is
  // operator-side and is left untouched.
  const remoteTemplate = normalizeRemotePath(
    remotePathArg || localPathTemplate
  );
  const hasLocalTemplate = localPathTemplate.includes('{host}');
  if (!hasLocalTemplate && !existsSync(localPathTemplate))
    die(`local path not found: ${localPathTemplate}`);
  const {targets, offlineNames, offlineReasons, parallelLimit} = validated;

  const doPut = async (hostName, address) => {
    const lp = expandTemplate(localPathTemplate, {host: hostName});
    if (!existsSync(lp)) {
      if (hasLocalTemplate) return null;
      throw new Error(`not found: ${lp}`);
    }
    const isDir = statSync(lp).isDirectory();
    const rp = expandTemplate(
      remoteTemplate.endsWith('/') && !isDir
        ? remoteTemplate + basename(lp)
        : remoteTemplate,
      {host: hostName}
    );
    await putOne(address, lp, rp, isDir, sudoPassword);
    return `${lp} → ${rp}`;
  };

  if (targets.length === 1 && !offlineNames.has(targets[0].name)) {
    await runTransferSingle(targets[0], 'put', doPut);
  } else {
    await runFanout({
      targets,
      parallelLimit,
      offlineNames,
      offlineReasons,
      transfer: {
        label: 'put',
        fn: async (hostName, address) => {
          const msg = await doPut(hostName, address);
          return msg === null ? 'skipped (file not found)' : msg;
        }
      }
    });
  }
}

// Download a file or directory from one or more targets.
export async function cmdGet(validated, remoteTemplateArg, localPathArg, sudoPassword) {
  // Normalize the operator-side home prefix so the remote shell does the
  // home resolution per-target (see normalizeRemotePath).
  const remoteTemplate = normalizeRemotePath(remoteTemplateArg);
  const {targets, offlineNames, offlineReasons, parallelLimit} = validated;
  const remoteBase = basename(remoteTemplate);
  const defaultLocal =
    targets.length === 1 ? remoteBase : `{host}-${remoteBase}`;
  const localTemplate = localPathArg || defaultLocal;
  if (targets.length > 1 && !localTemplate.includes('{host}')) {
    die(
      `multiple targets require {host} in the local path to avoid overwrites`
    );
  }

  const doGet = async (hostName, address) => {
    const rp = expandTemplate(remoteTemplate, {host: hostName});
    const lp = expandTemplate(localTemplate, {host: hostName});
    const {cmd: probeCmd, inputPrefix} = sudoWrap(
      `test -d ${shellQuotePath(rp)} && echo d || echo f`,
      sudoPassword
    );
    const probeResult = await sshRun(
      address, probeCmd, inputPrefix ? {input: inputPrefix} : undefined
    );
    checkSudoError(probeResult, sudoPassword);
    const isDir = probeResult.stdout.trim() === 'd';
    await getOne(address, rp, lp, isDir, sudoPassword);
    return `${rp} → ${lp}`;
  };

  if (targets.length === 1 && !offlineNames.has(targets[0].name)) {
    await runTransferSingle(targets[0], 'get', doGet);
  } else {
    await runFanout({
      targets,
      parallelLimit,
      offlineNames,
      offlineReasons,
      transfer: {label: 'get', fn: doGet}
    });
  }
}
