'use strict';

/* tiny test helper for the ucode tests: eq(), ok(), done() */

let failed = 0, passed = 0;

function show(v) { return sprintf('%J', v); }

/* deep equality; 0 and 0.0 are equal (ucode keeps int and double apart) */
function same(a, b) {
	let ta = type(a), tb = type(b);
	if ((ta == 'int' || ta == 'double') && (tb == 'int' || tb == 'double'))
		return a == b || (a - b < 1e-9 && b - a < 1e-9);
	if (ta != tb) return false;
	if (ta == 'array') {
		if (length(a) != length(b)) return false;
		for (let i = 0; i < length(a); i++) if (!same(a[i], b[i])) return false;
		return true;
	}
	if (ta == 'object') {
		if (length(keys(a)) != length(keys(b))) return false;
		for (let k in a) if (!(k in b) || !same(a[k], b[k])) return false;
		return true;
	}
	return a === b;
}

function eq(name, got, want) {
	if (same(got, want)) { passed++; return true; }
	failed++;
	warn(`FAIL ${name}\n  got:  ${show(got)}\n  want: ${show(want)}\n`);
	return false;
}

function ok(name, cond) { return eq(name, !!cond, true); }

function done(file) {
	print(`${file}: ${passed} passed, ${failed} failed\n`);
	exit(failed ? 1 : 0);
}

export { eq, ok, done };
