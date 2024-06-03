import {compareNumbers, compareStrings} from './comp-utils.js';

const isNumber = /^\d+$/;

export const compareVersions = (a, b) => {
	const result = compareNumbers(a.major, b.major) || compareNumbers(a.minor, b.minor) || compareNumbers(a.patch, b.patch);
	if (result) return result;

	// compare pre-release

	if (a.prerelease === undefined) return b.prerelease === undefined ? 0 : 1;
	if (b.prerelease === undefined) return -1;

	const x = a.prerelease.split('.'),
		y = b.prerelease.split('.'),
		n = Math.min(x.length, y.length);
	for (let i = 0; i < n; ++i) {
		const a = x[i], b = y[i];

		if (isNumber.test(a)) {
			if (isNumber.test(b)) {
				const result = compareNumbers(parseInt(a), parseInt(b));
				if (result) return result;
				continue;
			}
			return -1;
		}
		if (isNumber.test(y)) return 1;

		const result = compareStrings(a, b);
		if (result) return result;
	}

	if (n < y.length) return -1;
	if (n < x.length) return 1;
	return 0;
}

export const toVersionString = version => version.major + '.' + version.minor + '.' + version.patch +
	(version.prerelease === undefined ? '' : '-' + version.prerelease) +
	(version.build === undefined ? '' : '+' + version.build);

export const getVersionComponents = /^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-(?<prerelease>[\w\.]+))?(?:\+(?<build>[\w\.]+))?$/;
export const getVersion = versionString => getVersionComponents.exec(versionString)?.groups;
