'use strict';

/* luci-app-isp-tester: WAN side (ping targets, path snapshot, bufferbloat, SFP, WAN session,
 * IPv6, DNS) - see ../collector.uc. init(ctx) gives it cfg, emit, ubus(), ubus_drop(),
 * ubus_objects(re) */

import * as fs from 'fs';
import * as uloop from 'uloop';
import { RUNDIR, VARDIR, NO_UBUS, LOGREAD, MTR, TRACEROUTE, TRACEROUTE6, ETHTOOL, now, mono, round, valid_dev, valid_host, write_atomic, kill_pids, worst } from './common.uc';
import { trace_parse_mtr, trace_parse_tr, trace_judge, median, sfp_median, uniq_list } from './parsers.uc';
import { default_gateway, sfp_read, cd_unixsock, cd_rrd, dnsmasq_pids } from './sysinfo.uc';

let C = null;

function wan_init(ctx) { C = ctx; }

let targets = {};       /* collectd ping host -> { host, label, state, since, res, last_ts, active } */
let source = { type: null, error: null };
let wansess = { up: null, uptime: null, seen: null, ip: null, since: now(), reconnects: 0 };
/* IPv6 of the WAN (see v6_session): found = a DHCPv6 interface exists */
let v6s = { iface: null, found: false, up: null, since: now(), prefixes: null, addr: null, route: null,
	pd_seen: false, route_seen: false, pd_lost: null, route_lost: null, nr_logged: false, reconnects: 0 };
let wanst = { down: null, v6_down: null };   /* since when: all IPv4 targets lost / IPv6 alone lost */

/* ------------------------------------------------------------------- WAN */

/* why a target is not ok: 'loss', 'rtt', 'jitter' or null */
function target_why(r) {
	if (r.loss >= C.cfg.wan.loss_warn) return 'loss';
	if (r.rtt != null && C.cfg.wan.rtt_warn > 0 && r.rtt >= C.cfg.wan.rtt_warn) return 'rtt';
	if (r.jitter != null && C.cfg.wan.jitter_warn > 0 && r.jitter >= C.cfg.wan.jitter_warn) return 'jitter';
	return null;
}

function target_level(r) {
	if (r.loss >= C.cfg.wan.loss_fail) return 'fail';
	return target_why(r) ? 'warn' : 'ok';
}

/* ------------------------------------------------------ path snapshot */

/*
 * When a loss starts (a target goes to loss, or the whole WAN is down) one
 * traceroute is run - mtr -r (10 rounds) when installed, else busybox
 * traceroute -  so the timeline shows at which hop the loss starts: proof for
 * the ISP. Loss at a hop that does not carry on to the destination is just
 * a router that answers ICMP slowly, so only loss that continues to the
 * end counts. One at a time, at most every trace_cooldown seconds.
 */
let trace = { proc: null, last: 0, timer: null, n: 0 };

function trace_file() { return `${VARDIR}/trace.out`; }

function trace_request(host, label, trig, trig_ts) {
	if (!C.cfg.wan.trace || trace.proc || (!MTR && !TRACEROUTE)) return;
	if (now() - trace.last < C.cfg.wan.trace_cooldown) return;
	if (!valid_host(host) || substr(host, 0, 1) == '-') return;
	/* IPv6: mtr handles it; busybox traceroute only as traceroute6 */
	let v6 = index(host, ':') >= 0;
	if (v6 && !MTR && !TRACEROUTE6) return;
	let tool = MTR ? 'mtr' : 'traceroute';
	/* valid_host() keeps the host free of shell characters */
	let cmd = MTR ? `exec ${MTR} -n -r -c 10 -i 0.5 ${host}`
		: `exec ${v6 ? TRACEROUTE6 : TRACEROUTE} -n -q 3 -w 1 -m 20 ${host}`;
	let t0 = now();
	trace.last = t0;
	trace.n++;
	let p;
	p = uloop.process('/bin/sh', [ '-c', `${cmd} > ${trace_file()} 2>&1` ], null, (code) => {
		if (trace.proc != p) return;
		trace.proc = null;
		trace.timer?.cancel();
		trace.timer = null;
		let txt = fs.readfile(trace_file()) ?? '';
		fs.unlink(trace_file());
		let hops = slice((tool == 'mtr') ? trace_parse_mtr(txt) : trace_parse_tr(txt), 0, 30);
		if (!length(hops)) {
			C.emit('info', 'wan', label, 'trace', { host, tool, trig, err: substr(trim(txt), 0, 120) || `exit ${code}`, hops: [] }, t0);
			return;
		}
		let j = trace_judge(hops);
		C.emit(j.first_bad ? 'warn' : 'info', 'wan', label, 'trace',
			{ host, tool, trig, hops, ...j, dur: now() - t0, after: (trig_ts != null) ? t0 - trig_ts : null }, t0);
	});
	if (!p) return;
	trace.proc = p;
	/* never let a stuck trace block the next one */
	trace.timer = uloop.timer(60000, () => {
		trace.timer = null;
		/* the tool runs under "exec", so its pid is the process' pid; its
		 * exit callback then clears trace.proc */
		if (trace.proc == p) kill_pids('TERM', [ p.pid() ]);
	});
}

/* the target to trace: the gateway itself shows nothing beyond hop 1, so a
 * far target (of the same address family) is traced when the gateway (or
 * everything) loses */
function trace_target(t, fam) {
	if (t && t.label != 'gateway') return t;
	fam ??= t?.fam ?? 4;
	for (let k, x in targets)
		if (x.active && x.label != 'gateway' && x.fam == fam) return x;
	return t;
}

/* ---------------------------------------------------------- bufferbloat */

/*
 * "Lags only when the link is full": collectd's ping (one average per its
 * interval) is matched with the WAN traffic of the same interval, read
 * from the WAN device's counters every tick. The line's speed is the
 * highest 30 s rate seen (slowly forgotten, kept in RUNDIR) unless set in
 * the settings. Ping at low load (< 20 %) is the base; ping at a load of
 * bloat_load % or more that is bloat_ms above the base, twice in a row,
 * is bufferbloat: the own traffic fills a buffer (modem, ISP) - not an
 * outage, and fixable at home with SQM. No own speed test.
 */
const BLOAT_IDLE = 0.2;
let bloat = { ring: [], peak_rx: 0, peak_tx: 0, peak_saved: 0, idle: [], seen: {},
	active: false, since: null, bad_n: 0, ok_n: 0, max_add: 0, first: null,
	stat: { idle_n: 0, idle_sum: 0, load_n: 0, load_sum: 0, bloat_n: 0 }, last: null };

function bloat_load_peak() {
	let j;
	try { j = json(fs.readfile(`${RUNDIR}/wanpeak.json`) || 'null'); } catch (e) { j = null; }
	if (type(j) == 'object') {
		bloat.peak_rx = +j.rx || 0;
		bloat.peak_tx = +j.tx || 0;
	}
}

/* the target whose ping is used: the gateway (the first buffer on the way),
 * else an IPv4 one (IPv6 may be broken on its own) */
function bloat_target() {
	let best = null;
	for (let k, t in targets) {
		if (!t.active || !t.res) continue;
		if (t.label == 'gateway') return t;
		if (best == null || (best.fam == 6 && t.fam == 4)) best = t;
	}
	return best;
}

/* every tick: WAN traffic in bit/s; checks a new collectd value when there is one */
function bloat_tick(t, rx, tx) {
	if (!C.cfg.wan.bloat || rx == null) return;
	push(bloat.ring, [ t, rx, tx ]);
	while (length(bloat.ring) && bloat.ring[0][0] < t - 900) shift(bloat.ring);

	/* line speed: a 30 s rate, so a burst or an uneven tick does not count; forgotten by ~8 %/day */
	let n = length(bloat.ring), w = 0, sr = 0, stx = 0;
	for (let i = n - 1; i >= 0 && bloat.ring[i][0] > t - 30; i--) { sr += bloat.ring[i][1]; stx += bloat.ring[i][2]; w++; }
	let dec = 0.999999 ** C.cfg.interval;
	bloat.peak_rx = max(bloat.peak_rx * dec, w ? sr / w : 0);
	bloat.peak_tx = max(bloat.peak_tx * dec, w ? stx / w : 0);
	if (t - bloat.peak_saved >= 600) {
		bloat.peak_saved = t;
		write_atomic(`${RUNDIR}/wanpeak.json`, sprintf('%J', { rx: round(bloat.peak_rx, 0), tx: round(bloat.peak_tx, 0), ts: t }));
	}

	let tg = bloat_target();
	if (!tg) return;
	let ts = tg.res.ts, prev = bloat.seen[tg.host];
	if (ts == prev) return;
	bloat.seen[tg.host] = ts;
	if (prev == null || tg.res.rtt == null || tg.res.loss >= 100) return;

	/* average traffic over the same interval as the ping value */
	let cr = 0, ct = 0, m = 0;
	for (let x in bloat.ring)
		if (x[0] > prev && x[0] <= ts + 1) { cr += x[1]; ct += x[2]; m++; }
	if (!m) return;
	cr /= m;
	ct /= m;
	let cap_rx = C.cfg.wan.down_mbit > 0 ? C.cfg.wan.down_mbit * 1e6 : bloat.peak_rx;
	let cap_tx = C.cfg.wan.up_mbit > 0 ? C.cfg.wan.up_mbit * 1e6 : bloat.peak_tx;
	/* a speed that was never seen above 1 Mbit/s cannot tell what "full" is */
	let lr = cap_rx >= 1e6 ? cr / cap_rx : 0, lt = cap_tx >= 1e6 ? ct / cap_tx : 0;
	let load = max(lr, lt), dir = (lt > lr) ? 'up' : 'down';
	let rtt = tg.res.rtt;

	bloat.last = { ts, rtt, load: round(min(load, 1) * 100, 0), dir, rx: round(cr / 1000, 0), tx: round(ct / 1000, 0) };
	if (load < BLOAT_IDLE) {
		push(bloat.idle, rtt);
		if (length(bloat.idle) > 60) shift(bloat.idle);
		bloat.stat.idle_n++;
		bloat.stat.idle_sum += rtt;
	}
	let base = (length(bloat.idle) >= 5) ? median(bloat.idle) : null;
	let full = load * 100 >= C.cfg.wan.bloat_load;
	let add = (base != null) ? rtt - base : null;
	let bad = full && add != null && add >= C.cfg.wan.bloat_ms;
	if (full && base != null) {
		bloat.stat.load_n++;
		bloat.stat.load_sum += rtt;
		if (bad) bloat.stat.bloat_n++;
	}

	if (bad) {
		bloat.ok_n = 0;
		bloat.bad_n++;
		bloat.first ??= { ts: prev, rtt, add, load: bloat.last.load, dir };
		if (bloat.active) bloat.max_add = max(bloat.max_add, add);
		else if (bloat.bad_n >= 2) {
			bloat.active = true;
			bloat.since = bloat.first.ts;
			bloat.max_add = max(add, bloat.first.add);
			C.emit('warn', 'wan', tg.label, 'bufferbloat', { host: tg.host, base: round(base, 1), rtt: round(rtt, 1),
				add: round(add, 0), load: bloat.last.load, dir, rx_mbit: round(cr / 1e6, 1), tx_mbit: round(ct / 1e6, 1),
				cap_rx_mbit: round(cap_rx / 1e6, 1), cap_tx_mbit: round(cap_tx / 1e6, 1),
				learned: !(C.cfg.wan.down_mbit > 0 && C.cfg.wan.up_mbit > 0) }, bloat.since);
		}
	}
	else {
		bloat.bad_n = 0;
		bloat.first = null;
		if (bloat.active && ++bloat.ok_n >= 2) {
			bloat.active = false;
			C.emit('info', 'wan', tg.label, 'bufferbloat_ok', { host: tg.host, dur: ts - bloat.since, max_add: round(bloat.max_add, 0) });
		}
	}
}

function bloat_out() {
	if (!C.cfg.wan.bloat) return null;
	let s = bloat.stat, base = median(bloat.idle);
	return {
		active: bloat.active, since: bloat.since, base: round(base, 1),
		idle_avg: s.idle_n ? round(s.idle_sum / s.idle_n, 1) : null,
		load_avg: s.load_n ? round(s.load_sum / s.load_n, 1) : null,
		idle_n: s.idle_n, load_n: s.load_n, bloat_n: s.bloat_n,
		cap_rx: round((C.cfg.wan.down_mbit > 0 ? C.cfg.wan.down_mbit * 1e6 : bloat.peak_rx) / 1000, 0),
		cap_tx: round((C.cfg.wan.up_mbit > 0 ? C.cfg.wan.up_mbit * 1e6 : bloat.peak_tx) / 1000, 0),
		learned: !(C.cfg.wan.down_mbit > 0 && C.cfg.wan.up_mbit > 0),
		last: bloat.last, ms: C.cfg.wan.bloat_ms, load_pct: C.cfg.wan.bloat_load
	};
}

/* ----------------------------------------------- optical signal (SFP / ONT) */

const SFP_RING = 20;         /* readings behind "its usual level" */
const SFP_NOLIGHT = -40;     /* dBm: at or below it there is no light */
let sfp = { dev: null, ok: null, err: null, next: 0, last: null, ts: null, ring: [], fails: 0,
	los: false, los_since: 0, los_n: 0, drop: false, drop_since: 0, drop_n: 0, drop_min: null, base: null,
	alarm: false, alarm_since: 0, gone: false, gone_since: 0, min_rx: null, max_temp: null };

function sfp_device() {
	let d = C.cfg.wan.sfp_device || wansess.phys;
	return valid_dev(d) ? d : null;
}

function sample_sfp() {
	if (!C.cfg.wan.enabled || !C.cfg.wan.sfp || !ETHTOOL) return;
	let t = mono(), dev = sfp_device();
	if (!dev) return;
	if (dev != sfp.dev) { sfp.dev = dev; sfp.next = 0; sfp.ok = null; }
	if (t < sfp.next) return;

	let r = sfp_read(dev), tn = now();
	if (r.err) {
		sfp.err = r.err;
		sfp.fails++;
		/* a module that was there stopped answering; one without any is asked again later */
		if (sfp.ok) {
			if (sfp.fails >= 2 && !sfp.gone) {
				sfp.gone = true;
				sfp.gone_since = tn;
				C.emit('warn', 'wan', 'sfp', 'sfp_gone', { dev });
			}
			sfp.next = t + C.cfg.wan.sfp_interval;
		}
		else
			sfp.next = t + 600;
		return;
	}
	sfp.next = t + C.cfg.wan.sfp_interval;
	sfp.fails = 0;
	sfp.err = null;
	if (sfp.gone) {
		sfp.gone = false;
		C.emit('info', 'wan', 'sfp', 'sfp_gone_ok', { dev, dur: tn - sfp.gone_since });
	}
	sfp.ok = true;
	sfp.last = r;
	sfp.ts = tn;
	if (r.temp != null && (sfp.max_temp == null || r.temp > sfp.max_temp)) sfp.max_temp = r.temp;

	/* no light */
	let nolight = (r.rx == null) || r.rx <= SFP_NOLIGHT;
	if (nolight) sfp.los_n++; else sfp.los_n = 0;
	if (!sfp.los && sfp.los_n >= 2) {
		sfp.los = true;
		sfp.los_since = tn - C.cfg.wan.sfp_interval;
		C.emit('err', 'wan', 'sfp', 'sfp_los', { dev, tx: r.tx }, sfp.los_since);
	}
	else if (sfp.los && !nolight) {
		sfp.los = false;
		C.emit('info', 'wan', 'sfp', 'sfp_los_ok', { dev, dur: tn - sfp.los_since, rx: r.rx });
	}

	/* weaker light: against its usual level (median of the last readings, frozen during a drop) */
	if (!nolight) {
		let base = (length(sfp.ring) >= 5) ? sfp_median(sfp.ring) : null;
		let low = false, why = null;
		if (base != null && r.rx <= base - C.cfg.wan.sfp_drop_db) { low = true; why = 'drop'; }
		else if (C.cfg.wan.sfp_rx_min != null && r.rx < C.cfg.wan.sfp_rx_min) { low = true; why = 'min'; }
		else for (let fl in r.flags) if (match(fl, /rx power low/i)) { low = true; why = 'module'; }
		let recovered = !low && (base == null || r.rx > base - C.cfg.wan.sfp_drop_db / 2);

		if (low) sfp.drop_n++; else sfp.drop_n = 0;
		if (sfp.drop && (sfp.drop_min == null || r.rx < sfp.drop_min)) sfp.drop_min = r.rx;
		if (!sfp.drop && sfp.drop_n >= 2) {
			sfp.drop = true;
			sfp.drop_since = tn - C.cfg.wan.sfp_interval;
			sfp.drop_min = r.rx;
			sfp.base = base ?? sfp.base;
			C.emit('warn', 'wan', 'sfp', 'sfp_rx_drop', { dev, rx: r.rx, base: sfp.base, why, tx: r.tx }, sfp.drop_since);
		}
		else if (sfp.drop && recovered) {
			sfp.drop = false;
			C.emit('info', 'wan', 'sfp', 'sfp_rx_drop_ok', { dev, dur: tn - sfp.drop_since, min: sfp.drop_min, rx: r.rx });
			sfp.drop_min = null;
			sfp.ring = [];
		}
		if (!sfp.drop && !low) {
			push(sfp.ring, r.rx);
			if (length(sfp.ring) > SFP_RING) shift(sfp.ring);
			sfp.base = sfp_median(sfp.ring);
		}
		if (sfp.min_rx == null || r.rx < sfp.min_rx) sfp.min_rx = r.rx;
	}

	/* other alarms of the module (temperature, laser current, voltage, TX power, RX too strong) */
	let other = filter(r.flags, (fl) => !match(fl, /rx power low/i));
	if (!sfp.alarm && length(other)) {
		sfp.alarm = true;
		sfp.alarm_since = tn;
		C.emit('warn', 'wan', 'sfp', 'sfp_alarm', { dev, flags: other, temp: r.temp, rx: r.rx, tx: r.tx });
	}
	else if (sfp.alarm && !length(other)) {
		sfp.alarm = false;
		C.emit('info', 'wan', 'sfp', 'sfp_alarm_ok', { dev, dur: tn - sfp.alarm_since });
	}
}

function sfp_out() {
	if (!C.cfg.wan.sfp) return null;
	/* nothing to show without a module (most routers have none), unless a device was set by hand */
	if (!sfp.ok && !C.cfg.wan.sfp_device) return null;
	let r = sfp.last ?? {};
	return { dev: sfp.dev, ok: sfp.ok && !sfp.gone, err: sfp.err, ethtool: !!ETHTOOL, ts: sfp.ts,
		rx: r.rx, tx: r.tx, temp: r.temp, vcc: r.vcc, bias: r.bias, flags: r.flags,
		base: sfp.base, drop: sfp.drop, los: sfp.los, alarm: sfp.alarm, min_rx: sfp.min_rx, max_temp: sfp.max_temp,
		drop_db: C.cfg.wan.sfp_drop_db };
}

/* responding / all targets of one address family */
function fam_count(fam) {
	let all = 0, failed = 0;
	for (let k, t in targets) {
		if (!t.active || t.res == null || t.fam != fam) continue;
		all++;
		if (t.res.loss >= 100) failed++;
	}
	return { all, failed };
}

/*
 * Internet down = every IPv4 target lost (only IPv6 targets: those). IPv6
 * is judged on its own: all IPv6 targets lost while IPv4 still answers is
 * "IPv6 down" - the case where pages load slowly because the browser tries
 * IPv6 first and falls back after a delay.
 */

function check_wan_down() {
	let c4 = fam_count(4), c6 = fam_count(6);
	let c = c4.all ? c4 : c6;
	if (c.all) {
		if (c.failed == c.all && wanst.down == null) {
			wanst.down = now();
			C.emit('err', 'wan', 'wan', 'wan_down', {});
			let tt = trace_target(null, c4.all ? 4 : 6);
			if (tt) trace_request(tt.host, tt.label, 'wan_down', wanst.down);
		}
		else if (c.failed < c.all && wanst.down != null) {
			C.emit('warn', 'wan', 'wan', 'wan_up', { dur: now() - wanst.down });
			wanst.down = null;
		}
	}

	/* IPv6 alone: needs IPv4 targets that still answer */
	let v6bad = C.cfg.wan.ipv6 && c6.all > 0 && c6.failed == c6.all && c4.all > 0 && c4.failed < c4.all;
	if (v6bad && wanst.v6_down == null) {
		wanst.v6_down = now();
		C.emit('err', 'wan', 'ipv6', 'v6_down', { n: c6.all, pd: v6s.prefixes, route: v6s.route != null });
		let tt = trace_target(null, 6);
		if (tt) trace_request(tt.host, tt.label, 'v6_down', wanst.v6_down);
	}
	else if (!v6bad && wanst.v6_down != null && (c6.failed < c6.all || !c6.all)) {
		C.emit('warn', 'wan', 'ipv6', 'v6_up', { dur: now() - wanst.v6_down });
		wanst.v6_down = null;
	}
	else if (!v6bad && wanst.v6_down != null && c4.failed == c4.all) {
		/* now everything is down: that is the Internet outage, not IPv6 */
		wanst.v6_down = null;
	}
}

/* ------------------------------------------------- ping data from collectd */

/*
 * The collectd ping plugin (luci-app-statistics) pings the configured hosts
 * once a second and reports per collectd interval: average RTT (ping),
 * lost fraction (ping_droprate) and RTT standard deviation (ping_stddev).
 * Live values come from the unixsock plugin; without it the RRD files are
 * read, which lag behind by the rrdtool cache time.
 */

function collectd_ping() {
	let w = C.cfg.wan;
	if (w.collectd_socket && fs.stat(w.collectd_socket)) {
		let r = cd_unixsock(w.collectd_socket);
		if (!r.error) return { type: 'unixsock', hosts: r.hosts };
		source.sock_error = r.error;
	}
	if (fs.stat(w.rrd_dir)?.type == 'directory') {
		let r = cd_rrd(w.rrd_dir);
		return r.error ? { type: null, error: r.error } : { type: 'rrd', hosts: r.hosts };
	}
	return { type: null, error: 'no_collectd' };
}

function gateway_ip() {
	return C.cfg.wan.gateway || C.cfg.wan.gw || default_gateway(C.cfg.wan.device) || default_gateway(null);
}

function sample_pings() {
	if (!C.cfg.wan.enabled) return;
	let r = collectd_ping();
	source.type = r.type;
	source.error = r.error;
	source.ping_plugin = C.cfg.wan.ping_plugin;
	if (!r.hosts) {
		for (let k, t in targets) t.active = false;
		return;
	}

	let gw = gateway_ip(), t_now = now();
	let seen = {};
	for (let host, v in r.hosts) {
		if (!valid_host(host)) continue;
		seen[host] = true;
		let t = targets[host] ??= { host, state: 'ok', since: t_now, res: null, last_ts: null,
			fam: (index(host, ':') >= 0) ? 6 : 4 };
		t.active = true;
		t.label = (host == gw) ? 'gateway' : host;

		/* collectd reports once per its interval: only new values count */
		if (v.ts == t.last_ts) {
			/* no new value for a long time: collectd stopped or the host vanished */
			if (t.res && t_now - v.ts > 300) t.res = null;
			continue;
		}
		t.last_ts = v.ts;
		let loss = (v.ping_droprate != null) ? round(v.ping_droprate * 100, 0) : null;
		if (loss == null && v.ping == null) continue;
		let res = { loss: loss ?? 0, rtt: round(v.ping, 1), jitter: round(v.ping_stddev, 1), ts: v.ts };
		t.res = res;

		let lvl = target_level(res);
		if (lvl != t.state) {
			let fam = (t.fam == 6) ? 6 : null;
			if (lvl == 'ok')
				C.emit('info', 'wan', t.label, 'target_ok', { host, dur: t_now - t.since, loss: res.loss, rtt: res.rtt, fam });
			else
				C.emit(lvl == 'fail' ? 'err' : 'warn', 'wan', t.label, lvl == 'fail' ? 'target_fail' : 'target_degraded',
					{ host, loss: res.loss, rtt: res.rtt, jitter: res.jitter, why: target_why(res), fam }, v.ts);
			/* a loss started: one snapshot of the path */
			if (lvl != 'ok' && target_why(res) == 'loss') {
				let tt = trace_target(t);
				trace_request(tt.host, tt.label, lvl == 'fail' ? 'target_fail' : 'target_degraded', v.ts);
			}
			t.state = lvl;
			t.since = t_now;
		}
	}
	for (let k, t in targets)
		if (!seen[k]) t.active = false;

	check_wan_down();
}

/* ----------------------------------------------------------- WAN session */

/* netifd status of the WAN interface: up/down, session uptime, address */
function wan_session(st) {
	let up = st.up === true;
	let upt = (type(st.uptime) == 'int' || type(st.uptime) == 'double') ? st.uptime : null;
	let ip = st['ipv4-address']?.[0]?.address;
	let iface = C.cfg.wan.interface, t = now();

	if (wansess.up != null) {
		if (wansess.up && !up) {
			C.emit('err', 'wan', 'netifd', 'wan_if_down', { iface, prev: wansess.uptime });
		}
		else if (!wansess.up && up) {
			wansess.reconnects++;
			C.emit('warn', 'wan', 'netifd', 'wan_if_up', { iface, dur: t - wansess.since, ip });
		}
		else if (up && upt != null && wansess.uptime != null && upt < wansess.uptime) {
			/* went down and up again between two checks (PPPoE / DHCP session restart) */
			wansess.reconnects++;
			C.emit('warn', 'wan', 'netifd', 'wan_reconnect', { iface, prev: wansess.uptime, ip });
		}
		if (up && ip && wansess.ip && ip != wansess.ip)
			C.emit('info', 'wan', 'netifd', 'wan_ip_change', { iface, from: wansess.ip, to: ip });
	}

	if (up != wansess.up) wansess.since = t;
	wansess.up = up;
	wansess.uptime = up ? upt : null;
	wansess.proto = st.proto;
	if (ip) wansess.ip = ip;
}


/* ------------------------------------------------------------ IPv6 (WAN) */

/*
 * odhcp6c reports to netifd, so the DHCPv6 interface (wan6, or wan_6 when
 * IPv6 is set to "auto" on wan) shows what it got: the delegated prefix
 * (ipv6-prefix, what the LAN addresses come from) and the default route,
 * which comes from the ISP's router advertisement. Logged:
 *   v6_if_down / v6_if_up   - the interface (DHCPv6 session) went down
 *   v6_pd_lost / v6_pd_back - the delegated prefix vanished (LAN has no IPv6)
 *   v6_pd_change            - a new prefix: LAN devices renumber, open
 *                             connections over IPv6 break
 *   v6_no_route / v6_route_back - no default route for ra_after s: the
 *                             ISP's router advertisements stopped
 * Only what was seen once is missed: an ISP without IPv6 is not a fault.
 */

function v6_prefixes(st) {
	let out = [];
	for (let p in (st['ipv6-prefix'] ?? []))
		if (p?.address && p.mask != null) push(out, `${p.address}/${p.mask}`);
	return sort(out);
}

function v6_session(st) {
	let t = now(), iface = v6s.iface;
	let up = st.up === true;
	let pd = up ? v6_prefixes(st) : [];
	let addr = st['ipv6-address']?.[0];
	let gw = null;
	for (let r in (st.route ?? []))
		if ((r.target == '::' || r.target == '::/0') && r.mask == 0) { gw = r.nexthop ?? '::'; break; }

	if (v6s.up != null) {
		if (v6s.up && !up) {
			C.emit('warn', 'wan', 'ipv6', 'v6_if_down', { iface, prev: v6s.prefixes });
		}
		else if (!v6s.up && up) {
			v6s.reconnects++;
			C.emit('info', 'wan', 'ipv6', 'v6_if_up', { iface, dur: t - v6s.since });
		}
	}
	if (up != v6s.up) v6s.since = t;

	if (up && v6s.up != null) {
		let had = v6s.prefixes ?? [];
		if (length(pd) && length(had) && join(' ', pd) != join(' ', had))
			C.emit('warn', 'wan', 'ipv6', 'v6_pd_change', { iface, from: had, to: pd });
		else if (!length(pd) && length(had) && v6s.pd_lost == null) {
			v6s.pd_lost = t;
			v6s.pd_prev = had;
			C.emit('warn', 'wan', 'ipv6', 'v6_pd_lost', { iface, prev: had });
		}
		if (length(pd) && v6s.pd_lost != null) {
			C.emit('info', 'wan', 'ipv6', 'v6_pd_back', { iface, dur: t - v6s.pd_lost, prefix: pd,
				same: join(' ', pd) == join(' ', v6s.pd_prev ?? []) });
			v6s.pd_lost = null;
		}
	}
	if (length(pd)) { v6s.pd_seen = true; v6s.prefixes = pd; }
	else if (!up) v6s.pd_lost = null;
	else if (v6s.pd_lost == null) v6s.prefixes = pd;

	/* default route from the router advertisement */
	if (up && v6s.route_seen && gw == null) {
		v6s.route_lost ??= t;
		if (!v6s.nr_logged && t - v6s.route_lost >= C.cfg.wan.ra_after) {
			v6s.nr_logged = true;
			C.emit('warn', 'wan', 'ipv6', 'v6_no_route', { iface, after: t - v6s.route_lost }, v6s.route_lost);
		}
	}
	if (gw != null) {
		if (v6s.nr_logged) C.emit('info', 'wan', 'ipv6', 'v6_route_back', { iface, dur: t - v6s.route_lost, gw });
		v6s.route_lost = null;
		v6s.nr_logged = false;
		v6s.route_seen = true;
	}
	if (!up) { v6s.route_lost = null; v6s.nr_logged = false; }

	v6s.up = up;
	v6s.route = gw;
	v6s.addr = addr ? `${addr.address}/${addr.mask}` : null;
	v6s.proto = st.proto;
	v6s.uptime = up ? st.uptime : null;
}

function v6_out() {
	if (!C.cfg.wan.ipv6) return null;
	let c6 = fam_count(6), c4 = fam_count(4);
	let o = { iface: v6s.iface, found: v6s.found, up: v6s.up, since: v6s.since, uptime: v6s.uptime, proto: v6s.proto,
		prefixes: v6s.prefixes, addr: v6s.addr, route: v6s.route, pd_seen: v6s.pd_seen, route_seen: v6s.route_seen,
		pd_lost: v6s.pd_lost, route_lost: v6s.nr_logged ? v6s.route_lost : null, down: wanst.v6_down,
		targets: c6.all, targets_ok: c6.all - c6.failed, v4_targets: c4.all, reasons: [] };
	if (wanst.v6_down != null) push(o.reasons, { c: 'v6_down', since: wanst.v6_down });
	if (v6s.found && v6s.up === false && v6s.pd_seen) push(o.reasons, { c: 'v6_if_down', iface: v6s.iface, since: v6s.since });
	if (v6s.pd_lost != null) push(o.reasons, { c: 'v6_pd_lost', since: v6s.pd_lost });
	if (v6s.nr_logged) push(o.reasons, { c: 'v6_no_route', since: v6s.route_lost });
	return o;
}


/* -------------------------------------------------------------------- DNS */

/*
 * DNS of the router, from dnsmasq itself - no own resolver test:
 *   - ubus "dnsmasq metrics" every tick: queries forwarded upstream,
 *     answered from the cache / locally, and dns_unanswered (forwarded,
 *     but no server answered: timeout). A share of unanswered queries of
 *     warn_pct % or more within a minute (at least min_queries forwarded)
 *     is "DNS failing"; it ends when the share stays below half of it.
 *   - per upstream server: SIGUSR1 makes dnsmasq write its statistics to
 *     the system log ("server 1.1.1.1#53: queries sent 120, retried 3,
 *     failed 0, nxdomain replies 4, avg. latency 18ms"); sent every dump s
 *     (5 lines or so in the log), read by read_log. Retried = no answer in
 *     time, failed = SERVFAIL / REFUSED.
 */
const DNS_WIN = 60;
let dns = { ok: null, err: null, prev: null, win: [], bad: false, since: null, max_pct: 0, last: null,
	srv: {}, srv_prev: {}, srv_bad: {}, dump_ts: 0, dump_got: null, pids: [] };

function dnsmasq_metrics() {
	let f = getenv('ISP_TESTER_DNSMASQ');
	if (f) {
		let j;
		try { j = json(fs.readfile(f) || 'null'); } catch (e) { j = null; }
		return (type(j) == 'object') ? j : null;
	}
	if (NO_UBUS) return null;
	try {
		let ubus_conn = C.ubus();
		let sum = null;
		/* one object per dnsmasq instance */
		for (let o in C.ubus_objects(/^dnsmasq(\.|$)/)) {
			let r = ubus_conn.call(o, 'metrics');
			r = r?.metrics ?? r;
			if (type(r) != 'object') continue;
			sum ??= {};
			for (let k, v in r) if (type(v) == 'int') sum[k] = (sum[k] ?? 0) + v;
		}
		return sum;
	}
	catch (e) {
		return null;
	}
}

/* the dump in the log, one line per upstream server (read_log) */
function dns_log_line(l) {
	let m = match(l.msg, /^server ([0-9A-Fa-f.:]+)#([0-9]+): queries sent ([0-9]+), retried ([0-9]+), failed ([0-9]+)(, nxdomain replies ([0-9]+))?(, avg\. latency ([0-9]+)ms)?/);
	let old = m ? null : match(l.msg, /^server ([0-9A-Fa-f.:]+)#([0-9]+): queries sent ([0-9]+), retried or failed ([0-9]+)/);
	if (!m && !old) return false;
	let k = (m ?? old)[1];
	dns.srv[k] = m
		? { sent: +m[3], retried: +m[4], failed: +m[5], nx: m[7] != null ? +m[7] : null, lat: m[9] != null ? +m[9] : null, ts: l.ts }
		: { sent: +old[3], retried: +old[4], failed: 0, nx: null, lat: null, ts: l.ts };
	dns.dump_got = now();
	return true;
}

/* after a dump: what each server did since the previous one */
function dns_judge_servers() {
	if (dns.dump_got == null) return;
	dns.dump_got = null;
	for (let k, s in dns.srv) {
		let p = dns.srv_prev[k];
		dns.srv_prev[k] = s;
		if (!p || s.sent < p.sent) continue;          /* first dump, or dnsmasq restarted */
		let sent = s.sent - p.sent, bad = max(0, s.retried - p.retried) + max(0, s.failed - p.failed);
		s.d = { sent, bad, retried: max(0, s.retried - p.retried), failed: max(0, s.failed - p.failed), win: s.ts - p.ts };
		let worse = sent >= 10 && bad * 100 >= sent * C.cfg.dns.warn_pct;
		if (worse && !dns.srv_bad[k]) {
			dns.srv_bad[k] = true;
			C.emit('warn', 'wan', k, 'dns_server_bad', { server: k, ...s.d, lat: s.lat });
		}
		else if (!worse && dns.srv_bad[k] && sent >= 5) {
			delete dns.srv_bad[k];
			C.emit('info', 'wan', k, 'dns_server_ok', { server: k, ...s.d, lat: s.lat });
		}
	}
}

function sample_dns() {
	if (!C.cfg.dns.enabled) return null;
	let t = now(), m = dnsmasq_metrics();
	if (m == null) {
		dns.err = 'no_metrics';
		dns.prev = null;
	}
	else {
		dns.err = null;
		let cur = { fwd: m.dns_queries_forwarded ?? 0, local: (m.dns_local_answered ?? 0) + (m.dns_auth_answered ?? 0),
			stale: m.dns_stale_answered ?? 0, unans: m.dns_unanswered, cache: m.dns_cache_inserted ?? 0 };
		let p = dns.prev;
		if (p && cur.fwd >= p.fwd && cur.local >= p.local)
			push(dns.win, { ts: t, fwd: cur.fwd - p.fwd, local: cur.local - p.local, stale: max(0, cur.stale - p.stale),
				unans: (cur.unans != null && p.unans != null) ? max(0, cur.unans - p.unans) : null });
		dns.prev = cur;
		dns.has_unans = cur.unans != null;
	}
	dns.win = filter(dns.win, (x) => t - x.ts < DNS_WIN);

	let s = { fwd: 0, local: 0, stale: 0, unans: 0, n: length(dns.win) };
	for (let x in dns.win) { s.fwd += x.fwd; s.local += x.local; s.stale += x.stale; s.unans += x.unans ?? 0; }
	let pct = (s.fwd > 0) ? round(s.unans * 100 / s.fwd, 0) : 0;
	dns.last = { ...s, pct, q: s.fwd + s.local };

	if (dns.has_unans && s.n) {
		if (!dns.bad && s.fwd >= C.cfg.dns.min_queries && pct >= C.cfg.dns.warn_pct) {
			dns.bad = true;
			/* from the first interval with unanswered queries */
			dns.since = (filter(dns.win, (x) => x.unans > 0)[0] ?? dns.win[0]).ts - C.cfg.interval;

			dns.max_pct = pct;
			C.emit('warn', 'wan', 'dns', 'dns_fail', { pct, fwd: s.fwd, unans: s.unans, win: DNS_WIN }, dns.since);
		}
		else if (dns.bad) {
			if (pct > dns.max_pct) dns.max_pct = pct;
			if (pct * 2 < C.cfg.dns.warn_pct || s.fwd == 0) {
				dns.bad = false;
				C.emit('info', 'wan', 'dns', 'dns_ok', { dur: t - dns.since, max_pct: dns.max_pct });
			}
		}
	}

	/* the per-server dump: needs the system log */
	if (C.cfg.logread && LOGREAD && C.cfg.dns.dump > 0 && t - dns.dump_ts >= C.cfg.dns.dump) {
		dns.dump_ts = t;
		dns.pids = dnsmasq_pids();
		kill_pids('USR1', dns.pids);
	}

	let srv = [];
	for (let k, x in dns.srv)
		push(srv, { server: k, sent: x.sent, retried: x.retried, failed: x.failed, lat: x.lat, ts: x.ts, d: x.d, bad: !!dns.srv_bad[k] });
	return { err: dns.err, unans: dns.has_unans, bad: dns.bad, since: dns.since, last: dns.last, servers: srv,
		dump: (C.cfg.logread && LOGREAD) ? C.cfg.dns.dump : 0, warn_pct: C.cfg.dns.warn_pct };
}


/* netifd status of a logical interface (testing: a JSON file in env) */
function iface_status(name, env) {
	let f = getenv(env);
	if (f) {
		try { return json(fs.readfile(f) || 'null'); } catch (e) { return null; }
	}
	if (NO_UBUS) return null;
	try {
		let ubus_conn = C.ubus();
		return ubus_conn?.call(`network.interface.${name}`, 'status');
	}
	catch (e) {
		C.ubus_drop();
		return null;
	}
}

function wan_status() {
	return iface_status(C.cfg.wan.interface, 'ISP_TESTER_WANSTATUS');
}

/* the DHCPv6 interface: as set, else wan6 or <wan>_6 (IPv6 "auto" on wan) */
function refresh_wan6() {
	if (!C.cfg.wan.enabled || !C.cfg.wan.ipv6) return;
	let names = C.cfg.wan.interface6 ? [ C.cfg.wan.interface6 ] : uniq_list([ v6s.iface, 'wan6', `${C.cfg.wan.interface}_6` ]);
	for (let n in names) {
		if (!n) continue;
		let st = iface_status(n, 'ISP_TESTER_WAN6STATUS');
		if (type(st) != 'object') continue;
		v6s.iface = n;
		v6s.found = true;
		v6_session(st);
		return;
	}
	v6s.found = false;
}

function refresh_wan_device() {
	if (!C.cfg.wan.enabled || !C.cfg.wan.interface) return;
	let st = wan_status();
	if (type(st) != 'object') return;

	wan_session(st);

	/* the physical port (for ethtool -m): without the VLAN, not pppoe-* */
	if (valid_dev(st.device)) wansess.phys = replace(st.device, /\.[0-9]+$/, '');

	if (st.up === false) return;      /* keep last known device / gateway while WAN is down */
	let dev = st.l3_device ?? st.device ?? '';
	if (C.cfg.wan.auto_device && valid_dev(dev)) C.cfg.wan.device = dev;

	/* the gateway is wanted with a device override too */
	let gw = null;
	for (let r in (st.route ?? []))
		if (r.target == '0.0.0.0' && r.mask == 0 && r.nexthop && r.nexthop != '0.0.0.0') { gw = r.nexthop; break; }
	gw ??= st['ipv4-address']?.[0]?.ptpaddress;
	C.cfg.wan.gw = valid_host(gw) ? gw : null;
}


export { wan_init, targets, source, wansess, v6s, wanst, trace, bloat, sfp, dns, target_why, target_level, trace_file, trace_request, trace_target, bloat_load_peak, bloat_target, bloat_tick, bloat_out, sfp_device, sample_sfp, sfp_out, fam_count, check_wan_down, collectd_ping, gateway_ip, sample_pings, wan_session, v6_prefixes, v6_session, v6_out, dnsmasq_metrics, dns_log_line, dns_judge_servers, sample_dns, iface_status, wan_status, refresh_wan6, refresh_wan_device };
