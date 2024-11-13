#! /usr/bin/env bun

import {adaptReverse} from './comp-utils.js';
import {compareVersions, toVersionString} from './semver-utils.js';
import {getNodeVersions, runNvm} from './nvm-utils.js';

const main = async () => {
	const versions = await getNodeVersions();

	if (!versions.length) {
		console.log('No Node versions were found.');
		return;
	}

	versions.sort(adaptReverse(compareVersions));

	console.log('MAJOR:', toVersionString(versions[0]));
	for (let i = 1; i < versions.length; ++i) {
		const version = versions[i], versionString = toVersionString(version);
		if (version.major === versions[i - 1].major) {
		  if (version.current) {
		    await runNvm(`use ${version.major}`).nothrow();
		  }
			await runNvm(`uninstall ${versionString}`).nothrow();
		} else {
			console.log('MAJOR:', versionString);
		}
	}
};

await main().then(() => console.log('Done.'), error => console.error('ERROR:', error));
