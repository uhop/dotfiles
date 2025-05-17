import {$} from 'bun';
import {getVersion} from './semver-utils.js';

export const runNvm = args => $`bash -l -c "nvm ${args}"`;

const extractVersion = /^\s*(->)?\s*v([^\s]+)/;

export const getNodeVersions = async silent => {
  const lines = runNvm('ls --no-colors').lines(),
    versions = [];

  for await (const line of lines) {
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
