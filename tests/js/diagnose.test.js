// Tests of the probable-cause analysis (htdocs/.../isp_tester/diagnose.js).
// Run: node --test tests/js/
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const SRC = path.join(__dirname, '../../htdocs/luci-static/resources/isp_tester/diagnose.js');
const src = fs.readFileSync(SRC, 'utf8');

/* LuCI's sprintf-like String.format, enough for %d / %s / %.Nf */
if (!String.prototype.format)
	String.prototype.format = function() {
		let i = 0; const a = arguments;
		return this.replace(/%(\.\d+)?[dsf%]/g, (m) => m === '%%' ? '%' : String(a[i++]));
	};

/* the file is a LuCI module: 'require' lines and a top-level return */
const diagnose = new Function('baseclass', '_', src)({ extend: (o) => o }, (s) => s);

const T0 = 1764000000;   /* any fixed time */
const H = 3600;

function ev(dt, area, type, extra) {
	return Object.assign({ ts: T0 + dt, lvl: 'warn', area, src: '', type, d: {} }, extra || {});
}

function codes(r) { return r.findings.map((f) => f.code); }

test('no events: nothing to blame', () => {
	const r = diagnose.analyze([], T0, T0 + H, {});
	assert.equal(r.verdict, 'none');
	assert.equal(r.problems, 0);
	assert.deepEqual(r.findings, []);
});

test('repeated loss at the ISP gateway points at the ISP', () => {
	const e = [];
	for (let i = 0; i < 6; i++)
		e.push(ev(i * 300, 'wan', 'target_degraded', { src: 'gateway', d: { loss: 20 } }));
	const r = diagnose.analyze(e, T0, T0 + H, { wan_device: 'wan' });
	assert.equal(r.verdict, 'isp');
	assert.ok(codes(r).includes('gw_loss'), codes(r).join());
});

test('LAN port flapping points at the home side', () => {
	const e = [];
	for (let i = 0; i < 5; i++)
		e.push(ev(i * 400, 'ports', 'link_flap', { src: 'lan2' }));
	const r = diagnose.analyze(e, T0, T0 + H, { wan_device: 'wan' });
	assert.equal(r.verdict, 'home');
	assert.ok(codes(r).includes('port_link'));
});

test('a port that may be unplugged (info level) is not a fault', () => {
	const e = [ ev(10, 'ports', 'link_down', { src: 'lan2', lvl: 'info' }) ];
	const r = diagnose.analyze(e, T0, T0 + H, {});
	assert.ok(!codes(r).includes('port_link'));
});

test('events logged during maintenance are left out', () => {
	const e = [];
	for (let i = 0; i < 6; i++)
		e.push(ev(i * 300, 'wan', 'target_degraded', { src: 'gateway', d: { loss: 50 }, m: 1 }));
	const r = diagnose.analyze(e, T0, T0 + H, {});
	assert.equal(r.verdict, 'none');
});

test('events outside the window are left out', () => {
	const e = [ ev(-2 * H, 'wan', 'wan_down'), ev(3 * H, 'wan', 'wan_down') ];
	const r = diagnose.analyze(e, T0, T0 + H, {});
	assert.equal(r.problems, 0);
});

test('the end of a problem is not a problem of its own', () => {
	const e = [ ev(0, 'wan', 'wan_down'), ev(60, 'wan', 'wan_up') ];
	const r = diagnose.analyze(e, T0, T0 + H, {});
	assert.equal(r.problems, 1);
});

test('the second router\'s events are not counted twice for the stream', () => {
	const mine = ev(100, 'iptv', 'stream_stall', { d: { grp: '239.1.1.1', len: 5 } });
	const theirs = Object.assign({}, mine, { host: 'second' });
	const one = diagnose.analyze([ mine ], T0, T0 + H, {});
	const both = diagnose.analyze([ mine, theirs ], T0, T0 + H, {});
	assert.equal(both.stalls, one.stalls);
});

test('the verdict is the same whatever order the events come in', () => {
	const e = [
		ev(0, 'wan', 'target_degraded', { src: 'gateway', d: { loss: 30 } }),
		ev(500, 'ports', 'link_flap', { src: 'lan1' }),
		ev(900, 'wan', 'wan_down'),
		ev(960, 'wan', 'wan_up'),
		ev(1200, 'iptv', 'ts_errors', { d: { cc: 4 } })
	];
	const a = diagnose.analyze(e, T0, T0 + H, {});
	const b = diagnose.analyze(e.slice().reverse(), T0, T0 + H, {});
	assert.equal(a.verdict, b.verdict);
	assert.deepEqual(codes(a).sort(), codes(b).sort());
});

test('every finding the analysis can produce has its own text', () => {
	/* the codes given to add(side, weight, CODE, ...) */
	const found = new Set();
	for (const call of src.matchAll(/\badd\(([^,]+),\s*[0-9.]+,\s*([^,]+),/g))
		for (const m of call[2].matchAll(/'([a-z][a-z0-9_]+)'/g)) found.add(m[1]);
	assert.ok(found.size > 20, 'found only ' + found.size + ' codes');
	const missing = [ ...found ].filter((c) => diagnose.findingText({ code: c, n: 1, args: {} }) === c);
	assert.deepEqual(missing, []);
});

test('a short burst right after the stream ended with nobody subscribed is not an ISP freeze', () => {
	const e = [
		ev(0, 'iptv', 'stream_start', { lvl: 'info', d: { kbps: 2600 } }),
		ev(43, 'iptv', 'stream_off', { lvl: 'info', d: { avg: 1500 } }),
		ev(90, 'iptv', 'stream_start', { lvl: 'info', d: { kbps: 788 } }),
		ev(103, 'iptv', 'stream_stall', { lvl: 'err', d: { kbps: 9, avg: 1500, groups: 3 } }),
		ev(163, 'iptv', 'stream_lost', { d: { dur: 60, groups: 3 } })
	];
	const r = diagnose.analyze(e, T0, T0 + H, { iptv_on: true });
	assert.ok(!codes(r).some((c) => /^stall_upstream/.test(c)), codes(r).join());
});

test('a freeze after the decoder came back is still counted', () => {
	const e = [
		ev(43, 'iptv', 'stream_off', { lvl: 'info', d: { avg: 1500 } }),
		ev(60, 'iptv', 'decoder_on', { lvl: 'info', src: 'aa:bb:cc:dd:ee:ff', d: { dur: 17 } }),
		ev(103, 'iptv', 'stream_stall', { lvl: 'err', d: { kbps: 9, avg: 11400, groups: 3 } }),
		ev(163, 'iptv', 'stream_lost', { d: { dur: 60, groups: 3 } })
	];
	const r = diagnose.analyze(e, T0, T0 + H, { iptv_on: true });
	assert.ok(codes(r).some((c) => /^stall_upstream/.test(c)), codes(r).join());
});
