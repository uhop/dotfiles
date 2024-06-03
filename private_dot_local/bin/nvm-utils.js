import {$} from 'bun';
import {getVersion} from './semver-utils.js'

export const runNvm = args => $`bash -l -c "nvm ${args}"`

const extractVersion = /^(?:->)?\s*v([^\s]+)/;

export const getNodeVersions = async (silent) => {
	const lines = await runNvm('ls --no-colors').lines(),
		versions = [];

	for await (const line of lines) {
		const result = extractVersion.exec(line);
		if (!result) continue;
		const version = getVersion(result[1]);
		if (!version) {
			!silent && console.log('Bad version:', result[1]);
			continue;
		}
		versions.push(version);
	}

	return versions;
};
