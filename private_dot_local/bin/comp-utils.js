export const adaptLess = lessFn => (a, b) => lessFn(a, b) ? -1 : lessFn(b, a) ? 1 : 0;
export const compareNumbers = (a, b) => a - b;
export const compareStrings = adaptLess((a, b) => a < b);
export const adaptReverse = compare => (a, b) => compare(b, a);
