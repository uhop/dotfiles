#! /usr/bin/env bun

import {adaptReverse} from '../share/utils/comp.js';
import {compareVersions, toVersionString} from '../share/utils/semver.js';
import {getNodeVersions, runNvm} from '../share/utils/nvm.js';

const main = async () => {
  const versions = await getNodeVersions();

  if (!versions.length) {
    console.log('No Node versions were found.');
    return;
  }

  versions.sort(adaptReverse(compareVersions));

  console.log('MAJOR:', toVersionString(versions[0]));
  for (let i = 1; i < versions.length; ++i) {
    const version = versions[i],
      versionString = toVersionString(version);
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

await main().then(
  () => console.log('Done.'),
  error => console.error('ERROR:', error)
);
