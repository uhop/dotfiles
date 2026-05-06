import {spawn} from 'node:child_process';
import {getVersion} from './semver.js';

const nvmRun = (args, capture) =>
  new Promise(resolve => {
    const child = spawn('bash', ['-l', '-c', `nvm ${args}`], {
      stdio: ['ignore', capture ? 'pipe' : 'inherit', 'inherit']
    });
    let stdout = '';
    if (capture) {
      child.stdout.setEncoding('utf8');
      child.stdout.on('data', d => (stdout += d));
    }
    child.on('close', exitCode => resolve({exitCode, stdout}));
  });

export const runNvm = args => nvmRun(args, false);

const extractVersion = /^\s*(->)?\s*v([^\s]+)/;

export const getNodeVersions = async silent => {
  const {stdout} = await nvmRun('ls --no-colors', true);
  const versions = [];
  for (const line of stdout.split('\n')) {
    const result = extractVersion.exec(line);
    if (!result) continue;
    const version = getVersion(result[2]);
    if (!version) {
      !silent && console.log('Bad version:', result[2]);
      continue;
    }
    if (result[1]) version.current = true;
    versions.push(version);
  }
  return versions;
};
