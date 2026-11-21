'use strict';

/* luci-app-isp-tester: clock / NTP tracking (see ../collector.uc); init(ctx) gives it
 * events(), history(), history_min(), agg_shift(by), shift_started(by), reset_alive(),
 * emit, save_events, uptime_s */

import * as fs from 'fs';
import { RUNDIR, PROC, VARDIR, now, mono, round, absf, write_atomic } from './common.uc';

let C = null;

function clock_init(ctx) { C = ctx; }

let clk = { on: false, off: null, steps: 0, last: null, run_hist: 0, run_min: 0, m0: 0 };
let ntp = { state: 'unknown', client: null, checked: null, sync_ts: null, stratum: null, offset: null, poll: null, action: null };

function clk_fields(typ, d) {
	/* a gap found while running (a late tick) lies wholly in this run; one
	 * found at start begins in an earlier run, whose times are its own */
	if (typ == 'data_gap') return (d?.why == 'stall') ? [ 'ts', 'd.from', 'd.to' ] : [ 'd.to' ];
	if (typ == 'router_reboot') return [ 'ts', 'd.boot' ];
	return [ 'ts' ];
}


/* ------------------------------------------------------- the clock (2/2) */

function clk_shift_hist(h, n, by) {
	let len = length(h.t);
	for (let i = max(0, len - n); i < len; i++) h.t[i] += by;
}

/* points dated after `t` (the clock was set back while it was trusted, so
 * they were not moved): dropped, the charts expect the times in order and
 * would draw a line back across the hour. The events stay (kept in order by
 * store_event); only the chart points go. */
function clk_trim_hist(h, t) {
	let n = length(h.t), i = n;
	while (i > 0 && h.t[i - 1] > t) i--;
	if (i == n) return 0;
	h.t = slice(h.t, 0, i);
	for (let k, arr in h.s) h.s[k] = slice(arr, 0, i);
	return n - i;
}

/* back into time order after some events were moved (stable: events of the
 * same second keep their order; the list is nearly sorted, so this is quick) */
function ev_resort(a) {
	for (let i = 1; i < length(a); i++) {
		let e = a[i], j = i;
		while (j > 0 && a[j - 1].ts > e.ts) { a[j] = a[j - 1]; j--; }
		a[j] = e;
	}
}

/* the clock was stepped by `by` seconds: move what this run logged before */
function clk_fix(by) {
	let n = 0;
	for (let e in C.events()) {
		if (!e._fix) continue;
		for (let k in e._fix) {
			if (k == 'ts') e.ts += by;
			else { let f = substr(k, 2); if (type(e.d[f]) == 'int') e.d[f] += by; }
		}
		if (e.type == 'data_gap') e.d.len = e.d.to - (e.d.from ?? e.d.to);
		e.d.clock_fixed = by;
		delete e._fix;
		n++;
	}
	if (n) ev_resort(C.events());
	clk_shift_hist(C.history(), clk.run_hist, by);
	clk_shift_hist(C.history_min(), clk.run_min, by);
	C.agg_shift(by);
	C.shift_started(by);
	C.reset_alive();
	return n;
}

/* stop marking: what was held back is final now */
function clk_release() {
	for (let e in C.events()) delete e._fix;
	clk.on = false;
	C.save_events();
	write_atomic(`${RUNDIR}/history.json`, sprintf('%J', C.history_min()));
}

/* every tick, before anything is measured */
function clk_check() {
	let off = time() - mono();
	if (clk.off != null && absf(off - clk.off) >= 2.5) {
		let by = int(round(off - clk.off, 0));
		let n = clk.on ? clk_fix(by) : 0;
		if (!clk.on && by < 0) {
			let t = now();
			clk_trim_hist(C.history(), t);
			if (clk_trim_hist(C.history_min(), t))
				write_atomic(`${RUNDIR}/history.json`, sprintf('%J', C.history_min()));
		}
		clk.steps++;
		clk.last = { ts: now(), by };
		if (clk.on) clk_release();
		C.emit(absf(by) >= 60 ? 'warn' : 'info', 'system', 'clock', 'clock_step', { by, fixed: n, ntp: ntp.state });
	}
	clk.off = off;
	if (clk.on && mono() - clk.m0 > 3600) clk_release();
}

function ntp_apply(j, quiet) {
	if (type(j) != 'object' || !match(`${j.action ?? ''}`, /^(stratum|step|unsync|periodic)$/)) return;
	let was = ntp.state;
	ntp.action = j.action;
	if (j.action == 'unsync' || j.stratum == 16) {
		ntp.state = 'unsynced';
		if (!quiet && was == 'synced') C.emit('warn', 'system', 'clock', 'ntp_unsync', { stratum: j.stratum });
		return;
	}
	ntp.state = 'synced';
	ntp.sync_ts = (type(j.ts) == 'int') ? j.ts : now();
	ntp.stratum = j.stratum;
	ntp.offset = j.offset;
	ntp.poll = j.poll;
	if (!quiet && was != 'synced')
		C.emit('info', 'system', 'clock', 'ntp_sync', { stratum: j.stratum, offset: j.offset, after: int(C.uptime_s() ?? 0) });
	/* confirmed without a step: the times were right */
	if (clk.on) clk_release();
}

function ntp_lines(text, quiet) {
	for (let l in split(trim(text ?? ''), '\n')) {
		let j;
		try { j = json(l); } catch (e) { continue; }
		ntp_apply(j, quiet);
	}
}

/* is there an NTP client at all (once a minute) */
function ntp_client() {
	/* monotonic: after the clock was set back it would not look for an hour */
	let t = mono();
	if (ntp.checked != null && t - ntp.checked < 60) return;
	ntp.checked = t;
	let c = null;
	for (let pid in (fs.lsdir(PROC) ?? [])) {
		if (!match(pid, /^[0-9]+$/)) continue;
		let n = trim(fs.readfile(`${PROC}/${pid}/comm`) ?? '');
		if (n == 'ntpd' || n == 'chronyd') { c = n; break; }
	}
	let was = ntp.client;
	ntp.client = c;
	if (!c && was !== null && !getenv('ISP_TESTER_CONFIG')) {
		if (ntp.state != 'off') C.emit('warn', 'system', 'clock', 'ntp_off', {});
		ntp.state = 'off';
	}
	else if (c && ntp.state == 'off') ntp.state = 'unknown';
}

function ntp_poll() {
	let f = `${VARDIR}/ntp.pending`, w = `${VARDIR}/ntp.work`;
	if (fs.stat(f) && fs.rename(f, w)) {
		ntp_lines(fs.readfile(w), false);
		fs.unlink(w);
	}
	ntp_client();
}

function ntp_out() {
	let up = C.uptime_s() ?? 0;
	let st = ntp.state;
	/* nothing heard since boot, shortly after a reboot: not confirmed */
	if (st == 'unknown' && up < 1800 && mono() - clk.m0 > 300) st = 'unsynced';
	return { state: st, raw: ntp.state, client: ntp.client, sync_ts: ntp.sync_ts, stratum: ntp.stratum, offset: ntp.offset,
		poll: ntp.poll, untrusted: clk.on, steps: clk.steps, last_step: clk.last, uptime: int(up) };
}

/* at start: what the NTP client reported this boot (RAM) */
function clk_init() {
	clk.m0 = mono();
	clk.off = time() - mono();
	ntp_lines(fs.readfile(`${VARDIR}/ntp.last`), true);
	fs.unlink(`${VARDIR}/ntp.pending`);
	ntp.checked = null;
	ntp_client();
	let up = C.uptime_s();
	/* shortly after boot and not confirmed yet: the clock may still be set */
	clk.on = ntp.state != 'synced' && up != null && up < 3600 && !getenv('ISP_TESTER_CONFIG') ||
		getenv('ISP_TESTER_CLOCKFIX') == '1';
}


export { clock_init, clk, ntp, clk_fields, clk_check, ntp_poll, ntp_out, clk_init };
