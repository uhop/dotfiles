#! /usr/bin/env bun

import {adaptReverse} from './comp-utils.js';
import {compareVersions} from './semver-utils.js';
import {getNodeVersions, runNvm} from './nvm-utils.js';

const main = async () => {
	const versions = await getNodeVersions();

	if (!versions.length) {
		console.log('No Node versions were found.');
		return;
	}

	versions.sort(adaptReverse(compareVersions));

	const majorVersions = versions.
		filter((version, index, versions) => !index || version.major !== versions[index - 1].major).
		sort(compareVersions);

	for (const version of majorVersions) {
		await runNvm(`install ${version.major}`).nothrow();
	}
};

await main().then(() => console.log('Done.'), error => console.error('ERROR:', error));
