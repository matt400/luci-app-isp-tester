#!/usr/bin/ucode
/*
 * luci-app-isp-tester - collector daemon
 *
 * Periodically samples:
 *   - interface counters / link state of configured devices (ports, WAN, IPTV)
 *   - ping loss / latency to the ISP gateway and configured targets
 *   - IPTV bitrate on the configured device
 *
 * and turns state changes into events. Everything is kept in RAM (/tmp):
 *   state.json   - current health + short history for charts (read by rpcd)
 *   events.json  - event timeline (ring buffer)
 *   samples.csv  - one row per tick (ring buffer, for export)
 *
 * Environment overrides (used for testing off-device):
 *   ISP_TESTER_RUNDIR, ISP_TESTER_SYSNET, ISP_TESTER_CONFIG (JSON file instead of UCI),
 *   ISP_TESTER_PING (ping binary), ISP_TESTER_ROUTE (/proc/net/route path)
 */
'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';

const RUNDIR = getenv('ISP_TESTER_RUNDIR') || '/tmp/isp-tester';
const SYSNET = getenv('ISP_TESTER_SYSNET') || '/sys/class/net';
const PING = getenv('ISP_TESTER_PING') || 'ping';
const ROUTE = getenv('ISP_TESTER_ROUTE') || '/proc/net/route';

const STAT_KEYS = [
	'rx_bytes', 'tx_bytes', 'rx_packets', 'tx_packets',
	'rx_errors', 'tx_errors', 'rx_dropped', 'tx_dropped',
	'rx_crc_errors', 'rx_frame_errors', 'rx_fifo_errors', 'rx_missed_errors',
	'multicast', 'collisions'
];

const LEVEL = { ok: 0, info: 0, warn: 1, err: 2, fail: 2 };

/* ------------------------------------------------------------------ utils */

function now() { return time(); }

function mono() {
	let c = clock(true);
	return c ? c[0] + c[1] / 1e9 : time();
}

function num(v, dflt) {
	let n = +v;
	return (v == null || v == '' || n != n) ? dflt : n;
}

function bool(v, dflt) {
	if (v == null || v == '') return dflt;
	return (v == '1' || v == 'on' || v == 'true' || v == 'yes' || v === true || v === 1);
}

function aslist(v) {
	if (v == null) return [];
	return (type(v) == 'array') ? v : [ v ];
}

function valid_host(h) {
	return type(h) == 'string' && length(h) > 0 && length(h) < 254 && match(h, /^[A-Za-z0-9.:_-]+$/) != null;
}

function valid_dev(d) {
	return type(d) == 'string' && length(d) > 0 && length(d) < 32 && match(d, /^[A-Za-z0-9._@-]+$/) != null;
}

function write_atomic(path, data) {
	let tmp = path + '.tmp';
	if (fs.writefile(tmp, data) == null) return false;
	return fs.rename(tmp, path);
}

function round(v, digits) {
	if (v == null) return null;
	let m = 10 ** (digits ?? 0);
	return int(v * m + (v >= 0 ? 0.5 : -0.5)) / (m * 1.0);
}

function worst(a, b) {
	return (LEVEL[b] > LEVEL[a]) ? b : a;
}

/* ----------------------------------------------------------------- config */

function default_config() {
	return {
		interval: 10,
		max_samples: 8640,
		max_events: 1000,
		history: 360,
		long_history: 1440,
		warn_window: 900,
		wan: {
			enabled: true, interface: 'wan', device: '', ping_gateway: true,
			targets: [ '1.1.1.1', '8.8.8.8' ], count: 3,
			loss_warn: 1, loss_fail: 50, rtt_warn: 80
		},
		iptv: {
			enabled: true, device: '', direction: 'rx', bridge: '',
			min_kbps: 500, idle_after: 60, dip_pct: 40
		},
		ports: [],
		err_cooldown: 60,
		drop_warn: 50
	};
}

function load_config() {
	let c = default_config();
	let path = getenv('ISP_TESTER_CONFIG');

	if (path) {
		let j = json(fs.readfile(path) || '{}');
		for (let k, v in j) {
			if (type(v) == 'object' && type(c[k]) == 'object')
				for (let k2, v2 in v) c[k][k2] = v2;
			else
				c[k] = v;
		}
	}
	else {
		let uci = require('uci');
		let cur = uci.cursor();
		let g = cur.get_all('isp_tester', 'general') || {};
		let w = cur.get_all('isp_tester', 'wan') || {};
		let t = cur.get_all('isp_tester', 'iptv') || {};

		c.interval    = num(g.interval, c.interval);
		c.max_samples = num(g.max_samples, c.max_samples);
		c.max_events  = num(g.max_events, c.max_events);
		c.history     = num(g.history, c.history);
		c.long_history = num(g.long_history, c.long_history);
		c.warn_window = num(g.warn_window, c.warn_window);
		c.err_cooldown = num(g.err_cooldown, c.err_cooldown);
		c.drop_warn   = num(g.drop_warn, c.drop_warn);

		c.wan.enabled      = bool(w.enabled, true);
		c.wan.interface    = w.interface ?? c.wan.interface;
		c.wan.device       = w.device ?? '';
		c.wan.ping_gateway = bool(w.ping_gateway, true);
		if (w.target != null) c.wan.targets = aslist(w.target);
		c.wan.count     = num(w.count, c.wan.count);
		c.wan.loss_warn = num(w.loss_warn, c.wan.loss_warn);
		c.wan.loss_fail = num(w.loss_fail, c.wan.loss_fail);
		c.wan.rtt_warn  = num(w.rtt_warn, c.wan.rtt_warn);

		c.iptv.enabled    = bool(t.enabled, true);
		c.iptv.device     = t.device ?? '';
		c.iptv.direction  = (t.direction == 'tx') ? 'tx' : 'rx';
		c.iptv.bridge     = t.bridge ?? '';
		c.iptv.min_kbps   = num(t.min_kbps, c.iptv.min_kbps);
		c.iptv.idle_after = num(t.idle_after, c.iptv.idle_after);
		c.iptv.dip_pct    = num(t.dip_pct, c.iptv.dip_pct);

		cur.foreach('isp_tester', 'port', (s) => {
			if (bool(s.enabled, true) && s.device)
				push(c.ports, { device: s.device, label: s.label ?? '', expect_up: bool(s.expect_up, true) });
		});

		/* WAN L3 device is resolved via ubus on every tick unless set explicitly */
		c.wan.auto_device = !c.wan.device && !!c.wan.interface;
	}

	if (c.interval < 2) c.interval = 2;
	if (c.wan.count < 1) c.wan.count = 1;
	if (c.wan.count > 10) c.wan.count = 10;
	c.wan.targets = filter(c.wan.targets, valid_host);
	c.ports = filter(c.ports, (p) => valid_dev(p.device));
	if (c.wan.device && !valid_dev(c.wan.device)) c.wan.device = '';
	if (c.iptv.device && !valid_dev(c.iptv.device)) c.iptv.device = '';
	if (c.iptv.bridge && !valid_dev(c.iptv.bridge)) c.iptv.bridge = '';

	return c;
}

/* ------------------------------------------------------------------ state */

let cfg = load_config();
let events = [];
let history = { t: [], s: {} };
let history_min = { t: [], s: {} };
let devstate = {};      /* dev -> { prev, link, since, err_acc, drop_acc, last_err_ev, ... } */
let targets = {};       /* label -> { host, state, since, loss, rtt, rtt_max, sent, recv, busy } */
let wan_down_since = null;
let iptv = { state: 'idle', since: now(), kbps: 0, pps: 0, avg: null, dip: false, prev: null, prev_t: null };
let csv_rows = 0;
let csv_header = null;
let last_mono = null;
let started = now();

/* ----------------------------------------------------------------- events */

function save_events() {
	write_atomic(`${RUNDIR}/events.json`, sprintf('%J', events));
}

function emit(lvl, area, src, typ, data) {
	push(events, { ts: now(), lvl, area, src, type: typ, d: data ?? {} });
	if (length(events) > cfg.max_events)
		events = slice(events, length(events) - cfg.max_events);
	save_events();
}

function recent_level(area, src) {
	let lvl = 'ok', cutoff = now() - cfg.warn_window;
	for (let i = length(events) - 1; i >= 0; i--) {
		let e = events[i];
		if (e.ts < cutoff) break;
		if (e.area != area || (src != null && e.src != src)) continue;
		if (e.lvl == 'warn' || e.lvl == 'err') lvl = 'warn';
	}
	return lvl;
}

function count_events(since) {
	let n = { warn: 0, err: 0 };
	for (let i = length(events) - 1; i >= 0; i--) {
		let e = events[i];
		if (e.ts < since) break;
		if (e.lvl == 'warn') n.warn++;
		else if (e.lvl == 'err') n.err++;
	}
	return n;
}

/* ---------------------------------------------------------------- history */

/* append one point; keeps all series aligned with h.t (missing -> null) */
function hist_add(h, t, vals, max) {
	push(h.t, t);
	let n = length(h.t);

	for (let k, v in vals)
		if (v != null && h.s[k] == null) {
			h.s[k] = [];
			for (let i = 0; i < n - 1; i++) push(h.s[k], null);
		}

	for (let k, arr in h.s)
		push(arr, vals[k]);

	if (n > max) {
		let cut = n - max;
		h.t = slice(h.t, cut);
		for (let k, arr in h.s) {
			h.s[k] = slice(arr, cut);
			if (length(filter(h.s[k], (v) => v != null)) == 0)
				delete h.s[k];
		}
	}
}

/* 1-minute aggregates for the long (24 h) history */
const AGG_MODE = { rtt: 'avg', rttmax: 'max', loss: 'max', 'iptv:kbps': 'avg', 'iptv:min': 'min', err: 'sum', drop: 'sum', lvl: 'max' };

let agg = null;

function agg_mode(k) {
	return AGG_MODE[k] ?? AGG_MODE[split(k, ':')[0]] ?? 'avg';
}

function agg_flush() {
	if (!agg) return;
	let vals = {};
	for (let k, a in agg.v) {
		switch (agg_mode(k)) {
		case 'max': vals[k] = a.max; break;
		case 'min': vals[k] = a.min; break;
		case 'sum': vals[k] = a.sum; break;
		default:    vals[k] = round(a.sum / a.n, 1);
		}
	}
	hist_add(history_min, agg.t, vals, cfg.long_history);
	write_atomic(`${RUNDIR}/history.json`, sprintf('%J', history_min));
	agg = null;
}

function agg_add(t, vals) {
	let m = t - t % 60;
	if (agg && agg.t != m) agg_flush();
	agg ??= { t: m, v: {} };
	for (let k, v in vals) {
		if (v == null) continue;
		let a = agg.v[k] ??= { sum: 0, n: 0, min: v, max: v };
		a.sum += v;
		a.n++;
		if (v < a.min) a.min = v;
		if (v > a.max) a.max = v;
	}
}

/* --------------------------------------------------------------- devices */

function rd(dev, f) {
	let v = fs.readfile(`${SYSNET}/${dev}/${f}`);
	return (v == null) ? null : trim(v);
}

function read_dev(dev) {
	if (!fs.stat(`${SYSNET}/${dev}`))
		return null;

	let s = {};
	for (let k in STAT_KEYS)
		s[k] = num(rd(dev, `statistics/${k}`), 0);

	s.operstate = rd(dev, 'operstate') ?? 'unknown';
	s.carrier = rd(dev, 'carrier') == '1';
	s.carrier_changes = num(rd(dev, 'carrier_changes'), 0);
	s.speed = num(rd(dev, 'speed'), -1);
	s.duplex = rd(dev, 'duplex');
	s.up = s.carrier && (s.operstate == 'up' || s.operstate == 'unknown');
	return s;
}

/* list of monitored devices: { dev, area, label, expect_up } */
function monitored_devices() {
	let list = [], seen = {};
	let add = (dev, area, label, expect) => {
		if (!dev || seen[dev]) return;
		seen[dev] = true;
		push(list, { dev, area, label: label ?? '', expect_up: expect });
	};

	for (let p in cfg.ports)
		add(p.device, 'ports', p.label, p.expect_up);
	if (cfg.wan.enabled)
		add(cfg.wan.device, 'wan', 'WAN', true);
	if (cfg.iptv.enabled)
		add(cfg.iptv.device, 'iptv', 'IPTV', true);

	return list;
}

function sample_device(m, dt) {
	let ds = devstate[m.dev] ??= { prev: null, link: null, since: now(), err_acc: null, drop_acc: null, last_err_ev: 0, last_drop_ev: 0, missing: false };
	let cur = read_dev(m.dev);
	let out = { dev: m.dev, area: m.area, label: m.label, expect_up: m.expect_up, present: cur != null };

	if (!cur) {
		if (!ds.missing) {
			ds.missing = true;
			emit('err', m.area, m.dev, 'dev_missing', { dev: m.dev });
		}
		out.level = 'fail';
		out.reasons = [ { c: 'dev_missing', dev: m.dev } ];
		ds.prev = null;
		/* forget the link state, so a device that comes back with link down
		 * is reported as such and "since" restarts */
		ds.link = null;
		ds.err_acc = null;
		ds.drop_acc = null;
		return out;
	}

	if (ds.missing) {
		ds.missing = false;
		emit('info', m.area, m.dev, 'dev_present', { dev: m.dev });
	}

	let p = ds.prev;
	let d = { err: 0, drop: 0, crc: 0, rx_bps: 0, tx_bps: 0 };

	if (p && dt > 0) {
		let delta = (k) => { let v = cur[k] - p[k]; return v < 0 ? 0 : v; };   /* counter reset */
		d.err  = delta('rx_errors') + delta('tx_errors');
		d.crc  = delta('rx_crc_errors') + delta('rx_frame_errors');
		d.drop = delta('rx_dropped') + delta('tx_dropped');
		d.rx_bps = delta('rx_bytes') * 8 / dt;
		d.tx_bps = delta('tx_bytes') * 8 / dt;
		d.rx_pps = delta('rx_packets') / dt;
		d.tx_pps = delta('tx_packets') / dt;
		d.mcast_pps = delta('multicast') / dt;

		/* link state transitions */
		if (ds.link != null && cur.up != ds.link) {
			if (cur.up)
				emit('warn', m.area, m.dev, 'link_up', { dev: m.dev, speed: cur.speed, dur: now() - ds.since });
			else
				emit(m.expect_up ? 'err' : 'info', m.area, m.dev, 'link_down', { dev: m.dev });
			ds.since = now();
		}
		else if (cur.carrier_changes - p.carrier_changes >= 2) {
			/* went down and up again between two samples */
			emit('warn', m.area, m.dev, 'link_flap', { dev: m.dev, n: int((cur.carrier_changes - p.carrier_changes) / 2) });
		}

		if (cur.up && p.up && p.speed > 0 && cur.speed > 0 && cur.speed != p.speed)
			emit('warn', m.area, m.dev, 'speed_change', { dev: m.dev, from: p.speed, to: cur.speed });

		/* errors: aggregated, at most one event per cooldown */
		let t = now();
		if (d.err > 0 || d.crc > 0) {
			ds.err_acc ??= { err: 0, crc: 0, from: t };
			ds.err_acc.err += d.err;
			ds.err_acc.crc += d.crc;
		}
		if (ds.err_acc && t - ds.last_err_ev >= cfg.err_cooldown) {
			emit('warn', m.area, m.dev, 'errors', { dev: m.dev, err: ds.err_acc.err, crc: ds.err_acc.crc, from: ds.err_acc.from });
			ds.err_acc = null;
			ds.last_err_ev = t;
		}

		if (d.drop >= cfg.drop_warn) {
			ds.drop_acc ??= { n: 0, from: t };
			ds.drop_acc.n += d.drop;
		}
		if (ds.drop_acc && t - ds.last_drop_ev >= cfg.err_cooldown) {
			emit('warn', m.area, m.dev, 'drops', { dev: m.dev, n: ds.drop_acc.n, from: ds.drop_acc.from });
			ds.drop_acc = null;
			ds.last_drop_ev = t;
		}
	}
	else if (ds.link == null && !cur.up && m.expect_up) {
		emit('err', m.area, m.dev, 'link_down', { dev: m.dev });
	}

	if (ds.link != cur.up && ds.link == null) ds.since = now();
	ds.link = cur.up;
	ds.prev = cur;

	let level = 'ok', reasons = [];
	if (!cur.up && m.expect_up) {
		level = 'fail';
		push(reasons, { c: 'link_down', dev: m.dev, since: ds.since });
	}
	if (ds.err_acc) { level = worst(level, 'warn'); push(reasons, { c: 'errors_now', dev: m.dev }); }
	let rl = recent_level(m.area, m.dev);
	if (rl != 'ok' && level == 'ok') { level = 'warn'; push(reasons, { c: 'recent_events', dev: m.dev }); }

	out.level = level;
	out.reasons = reasons;
	out.up = cur.up;
	out.speed = cur.speed;
	out.duplex = cur.duplex;
	out.operstate = cur.operstate;
	out.since = ds.since;
	out.delta = (p && dt > 0) ? d : null;
	out.totals = {
		rx_errors: cur.rx_errors, tx_errors: cur.tx_errors,
		rx_dropped: cur.rx_dropped, tx_dropped: cur.tx_dropped,
		rx_crc_errors: cur.rx_crc_errors, carrier_changes: cur.carrier_changes
	};
	out.cur = cur;
	return out;
}

/* ------------------------------------------------------------------- WAN */

function default_gateway(dev) {
	let data = fs.readfile(ROUTE);
	if (!data) return null;

	for (let line in split(data, '\n')) {
		let f = split(trim(line), /\s+/);
		if (length(f) < 4 || f[1] != '00000000' || f[0] == 'Iface') continue;
		if (length(f) >= 8 && f[7] != '00000000') continue;     /* not a default route */
		if (dev && f[0] != dev) continue;
		let g = hex(f[2]);
		if (!g) continue;
		/* little-endian hex */
		return sprintf('%d.%d.%d.%d', g & 255, (g >> 8) & 255, (g >> 16) & 255, (g >> 24) & 255);
	}
	return null;
}

function wan_targets() {
	let list = [];
	if (cfg.wan.ping_gateway) {
		/* PPPoE has no gateway in the routing table (0.0.0.0), use the peer from netifd */
		let gw = default_gateway(cfg.wan.device) ?? cfg.wan.gw ?? default_gateway(null);
		if (gw) push(list, { label: 'gateway', host: gw });
	}
	for (let t in cfg.wan.targets)
		push(list, { label: t, host: t });
	return list;
}

function parse_ping(out) {
	let r = { sent: 0, recv: 0, loss: 100, rtt: null, rtt_min: null, rtt_max: null };
	if (!out) return r;
	let m = match(out, /(\d+) packets transmitted, (\d+) (packets )?received/);
	if (m) {
		r.sent = +m[1];
		r.recv = +m[2];
		r.loss = r.sent > 0 ? round((r.sent - r.recv) * 100 / r.sent, 0) : 100;
	}
	let rt = match(out, /= ([0-9.]+)\/([0-9.]+)\/([0-9.]+)/);
	if (rt) {
		r.rtt_min = +rt[1];
		r.rtt = +rt[2];
		r.rtt_max = +rt[3];
	}
	return r;
}

function target_level(r) {
	if (r.loss >= cfg.wan.loss_fail) return 'fail';
	if (r.loss >= cfg.wan.loss_warn) return 'warn';
	if (r.rtt != null && cfg.wan.rtt_warn > 0 && r.rtt >= cfg.wan.rtt_warn) return 'warn';
	return 'ok';
}

function check_wan_down() {
	let all = 0, failed = 0;
	for (let k, t in targets) {
		if (!t.active || t.res == null) continue;
		all++;
		if (t.res.loss >= 100) failed++;
	}
	if (all == 0) return;

	if (failed == all && wan_down_since == null) {
		wan_down_since = now();
		emit('err', 'wan', 'wan', 'wan_down', {});
	}
	else if (failed < all && wan_down_since != null) {
		emit('warn', 'wan', 'wan', 'wan_up', { dur: now() - wan_down_since });
		wan_down_since = null;
	}
}

function on_ping_done(label) {
	let t = targets[label];
	t.busy = false;
	let r = parse_ping(fs.readfile(t.file));
	fs.unlink(t.file);
	t.res = r;

	let lvl = target_level(r);
	if (lvl != t.state) {
		if (lvl == 'ok')
			emit('info', 'wan', label, 'target_ok', { host: t.host, dur: now() - t.since, loss: r.loss, rtt: r.rtt });
		else
			emit(lvl == 'fail' ? 'err' : 'warn', 'wan', label, lvl == 'fail' ? 'target_fail' : 'target_degraded',
				{ host: t.host, loss: r.loss, rtt: r.rtt, rtt_max: r.rtt_max });
		t.state = lvl;
		t.since = now();
	}

	check_wan_down();
}

function start_pings() {
	if (!cfg.wan.enabled) return;

	let list = wan_targets();
	let active = {};

	for (let i, tg in list) {
		active[tg.label] = true;
		let t = targets[tg.label] ??= { state: 'ok', since: now(), res: null, busy: false };
		t.active = true;
		/* a running ping keeps its host and output file; the list order may change
		 * (gateway appearing/disappearing), so never derive the file from the index */
		if (t.busy) continue;
		t.host = tg.host;
		t.file = `${RUNDIR}/ping.${replace(tg.label, /[^A-Za-z0-9._-]/g, '_')}`;

		let n = cfg.wan.count;
		let cmd = sprintf('exec %s -q -c %d -W 1 -w %d %s > %s 2>&1', PING, n, n + 1, tg.host, t.file);
		t.busy = true;
		let label = tg.label;
		let proc = uloop.process('/bin/sh', [ '-c', cmd ], null, () => on_ping_done(label));
		if (!proc) t.busy = false;
	}

	for (let k, t in targets)
		if (!active[k]) t.active = false;
}

/* ------------------------------------------------------------------ IPTV */

function iptv_out(devres) {
	let level = 'ok', reasons = [];

	if (iptv.state == 'stalled') {
		level = 'fail';
		push(reasons, { c: 'stream_stalled', since: iptv.stall_since });
	}
	else if (iptv.dip) {
		level = 'warn';
		push(reasons, { c: 'stream_dip' });
	}

	if (devres && devres.level != 'ok') {
		level = worst(level, devres.level);
		for (let r in devres.reasons) push(reasons, r);
	}
	if (level == 'ok' && recent_level('iptv', 'stream') != 'ok') {
		level = 'warn';
		push(reasons, { c: 'recent_events' });
	}

	let o = {
		level, reasons, state: iptv.state, since: iptv.state == 'stalled' ? iptv.stall_since : iptv.since,
		kbps: iptv.kbps, pps: iptv.pps, avg: round(iptv.avg, 0), device: cfg.iptv.device,
		direction: cfg.iptv.direction, min_kbps: cfg.iptv.min_kbps
	};

	if (cfg.iptv.bridge) {
		let b = `${cfg.iptv.bridge}`;
		o.bridge = {
			name: b,
			snooping: rd(b, 'bridge/multicast_snooping'),
			querier: rd(b, 'bridge/multicast_querier')
		};
	}
	return o;
}

function sample_iptv(devres) {
	if (!cfg.iptv.enabled || !cfg.iptv.device) return null;

	let d = devres?.delta;
	let bps = 0, pps = 0;
	if (d) {
		bps = (cfg.iptv.direction == 'tx') ? d.tx_bps : d.rx_bps;
		pps = (cfg.iptv.direction == 'tx') ? d.tx_pps : d.rx_pps;
	}
	let kbps = round((bps ?? 0) / 1000, 0);
	iptv.kbps = kbps;
	iptv.pps = round(pps ?? 0, 0);

	if (!devres?.present || devres.delta == null)
		return iptv_out(devres);

	let t = now();
	let active = kbps >= cfg.iptv.min_kbps;

	switch (iptv.state) {
	case 'idle':
		if (active) {
			emit('info', 'iptv', 'stream', 'stream_start', { kbps });
			iptv.state = 'playing';
			iptv.since = t;
			iptv.avg = kbps;
		}
		break;

	case 'playing':
		if (!active) {
			emit('err', 'iptv', 'stream', 'stream_stall', { kbps, avg: round(iptv.avg, 0) });
			iptv.state = 'stalled';
			iptv.stall_since = t;
		}
		else {
			/* bitrate dip relative to running average */
			if (cfg.iptv.dip_pct > 0 && iptv.avg > 0) {
				let ratio = kbps * 100 / iptv.avg;
				if (!iptv.dip && ratio < cfg.iptv.dip_pct) {
					iptv.dip = true;
					emit('warn', 'iptv', 'stream', 'stream_dip', { kbps, avg: round(iptv.avg, 0) });
				}
				else if (iptv.dip && ratio >= cfg.iptv.dip_pct + 10) {
					iptv.dip = false;
				}
			}
			if (!iptv.dip)
				iptv.avg = iptv.avg * 0.9 + kbps * 0.1;
		}
		break;

	case 'stalled':
		if (active) {
			emit('warn', 'iptv', 'stream', 'stream_resume', { dur: t - iptv.stall_since, kbps });
			iptv.state = 'playing';
			iptv.dip = false;
		}
		else if (t - iptv.stall_since >= cfg.iptv.idle_after) {
			emit('warn', 'iptv', 'stream', 'stream_lost', { dur: t - iptv.stall_since });
			iptv.state = 'idle';
			iptv.since = t;
		}
		break;
	}

	return iptv_out(devres);
}

/* ------------------------------------------------------------------- CSV */

function csv_columns(devs, tlist) {
	let cols = [ 'time', 'overall' ];
	for (let t in tlist) push(cols, `ping_${t.label}_loss`, `ping_${t.label}_rtt`);
	if (cfg.iptv.enabled && cfg.iptv.device) push(cols, 'iptv_state', 'iptv_kbps', 'iptv_pps');
	for (let m in devs) push(cols, `${m.dev}_link`, `${m.dev}_speed`, `${m.dev}_err`, `${m.dev}_crc`, `${m.dev}_drop`, `${m.dev}_rx_kbps`, `${m.dev}_tx_kbps`);
	return cols;
}

function csv_open(cols) {
	let header = join(',', cols);
	let path = `${RUNDIR}/samples.csv`;
	let existing = fs.readfile(path);

	if (existing != null) {
		let nl = index(existing, '\n');
		let first = (nl >= 0) ? substr(existing, 0, nl) : existing;
		if (first == header) {
			csv_rows = length(split(trim(existing), '\n')) - 1;
			csv_header = header;
			return;
		}
		fs.rename(path, `${RUNDIR}/samples.prev.csv`);
	}

	fs.writefile(path, header + '\n');
	csv_rows = 0;
	csv_header = header;
}

function csv_append(row) {
	let path = `${RUNDIR}/samples.csv`;
	let f = fs.open(path, 'a');
	if (!f) return;
	f.write(join(',', map(row, (v) => (v == null) ? '' : `${v}`)) + '\n');
	f.close();
	csv_rows++;

	/* trim with 10% slack to avoid rewriting the file on every tick */
	if (csv_rows > cfg.max_samples + int(cfg.max_samples / 10) + 1) {
		let lines = split(trim(fs.readfile(path)), '\n');
		let keep = slice(lines, length(lines) - cfg.max_samples);
		write_atomic(path, csv_header + '\n' + join('\n', keep) + '\n');
		csv_rows = length(keep);
	}
}

function tstamp(t) {
	let lt = localtime(t);
	return sprintf('%04d-%02d-%02d %02d:%02d:%02d', lt.year, lt.mon, lt.mday, lt.hour, lt.min, lt.sec);
}

/* ------------------------------------------------------------------ tick */

let ubus_conn = null;

function refresh_wan_device() {
	if (!cfg.wan.enabled || !cfg.wan.auto_device) return;
	try {
		ubus_conn ??= require('ubus').connect();
		let st = ubus_conn?.call(`network.interface.${cfg.wan.interface}`, 'status');
		let dev = st?.l3_device ?? st?.device ?? '';
		if (st?.up === false) return;      /* keep last known device while WAN is down */
		if (valid_dev(dev)) cfg.wan.device = dev;

		let gw = null;
		for (let r in (st?.route ?? []))
			if (r.target == '0.0.0.0' && r.mask == 0 && r.nexthop && r.nexthop != '0.0.0.0') { gw = r.nexthop; break; }
		gw ??= st?.['ipv4-address']?.[0]?.ptpaddress;
		cfg.wan.gw = valid_host(gw) ? gw : null;
	}
	catch (e) {
		ubus_conn = null;
	}
}

function handle_clear_request() {
	let flag = `${RUNDIR}/clear`;
	if (!fs.stat(flag)) return;
	fs.unlink(flag);
	events = [];
	history = { t: [], s: {} };
	history_min = { t: [], s: {} };
	agg = null;
	fs.unlink(`${RUNDIR}/history.json`);
	fs.unlink(`${RUNDIR}/samples.prev.csv`);
	if (csv_header != null)
		fs.writefile(`${RUNDIR}/samples.csv`, csv_header + '\n');
	else
		fs.unlink(`${RUNDIR}/samples.csv`);
	csv_rows = 0;
	emit('info', 'system', 'collector', 'cleared', {});
}

function tick() {
	handle_clear_request();
	refresh_wan_device();

	let m = mono();
	let dt = (last_mono != null) ? m - last_mono : 0;
	last_mono = m;

	let devs = monitored_devices();
	let res = {};
	for (let d in devs)
		res[d.dev] = sample_device(d, dt);

	/* ---- WAN */
	let wan = null;
	if (cfg.wan.enabled) {
		let level = 'ok', reasons = [], tl = [];
		let n_active = 0, n_fail = 0;

		for (let k, t in targets) {
			if (!t.active) continue;
			let r = t.res;
			push(tl, {
				label: k, host: t.host, level: r ? target_level(r) : 'unknown',
				loss: r?.loss, rtt: r?.rtt, rtt_max: r?.rtt_max, since: t.since
			});
			if (!r) continue;
			n_active++;
			let lv = target_level(r);
			if (lv == 'fail') n_fail++;
			if (lv != 'ok') push(reasons, { c: lv == 'fail' ? 'target_fail' : 'target_degraded', t: k, loss: r.loss, rtt: r.rtt });
			level = worst(level, lv == 'fail' ? 'warn' : lv);
		}
		if (n_active > 0 && n_fail == n_active) level = 'fail';
		if (wan_down_since != null) push(reasons, { c: 'wan_down', since: wan_down_since });

		let wd = cfg.wan.device ? res[cfg.wan.device] : null;
		if (wd && wd.level != 'ok') {
			level = worst(level, wd.level);
			for (let r in wd.reasons) push(reasons, r);
		}
		if (level == 'ok' && recent_level('wan') != 'ok') {
			level = 'warn';
			push(reasons, { c: 'recent_events' });
		}

		wan = { level, reasons, targets: tl, device: cfg.wan.device, interface: cfg.wan.interface,
			rx_kbps: wd?.delta ? round(wd.delta.rx_bps / 1000, 0) : null,
			tx_kbps: wd?.delta ? round(wd.delta.tx_bps / 1000, 0) : null };
	}

	/* ---- IPTV */
	let iptv_res = sample_iptv(cfg.iptv.device ? res[cfg.iptv.device] : null);

	/* ---- ports */
	let ports = [];
	let ports_level = 'ok';
	for (let d in devs) {
		if (d.area != 'ports') continue;
		let r = res[d.dev];
		ports_level = worst(ports_level, r.level);
		push(ports, {
			dev: r.dev, label: r.label, level: r.level, reasons: r.reasons, present: r.present,
			up: r.up, speed: r.speed, duplex: r.duplex, since: r.since, expect_up: r.expect_up,
			err: r.delta?.err, crc: r.delta?.crc, drop: r.delta?.drop,
			rx_kbps: r.delta ? round(r.delta.rx_bps / 1000, 0) : null,
			tx_kbps: r.delta ? round(r.delta.tx_bps / 1000, 0) : null,
			totals: r.totals
		});
	}

	let overall = 'ok';
	if (wan) overall = worst(overall, wan.level);
	if (iptv_res) overall = worst(overall, iptv_res.level);
	overall = worst(overall, ports_level);

	/* ---- history (skip the baseline tick without deltas) */
	let t = now();
	if (dt > 0) {
		let hv = { lvl: LEVEL[overall] };
		for (let x in (wan?.targets ?? [])) {
			hv[`rtt:${x.label}`] = x.rtt;
			hv[`loss:${x.label}`] = x.loss;
		}
		if (iptv_res) hv['iptv:kbps'] = iptv_res.kbps;
		for (let d in devs) {
			let r = res[d.dev];
			hv[`err:${d.dev}`] = r.delta ? (r.delta.err + r.delta.crc) : null;
			hv[`drop:${d.dev}`] = r.delta ? r.delta.drop : null;
		}
		hist_add(history, t, hv, cfg.history);

		let mv = { ...hv };
		for (let x in (wan?.targets ?? [])) mv[`rttmax:${x.label}`] = x.rtt;
		if (iptv_res) mv['iptv:min'] = iptv_res.kbps;
		agg_add(t, mv);

		/* ---- CSV */
		let tlist = cfg.wan.enabled ? map(wan_targets(), (x) => ({ label: x.label, t: targets[x.label] ?? {} })) : [];
		let cols = csv_columns(devs, tlist);
		if (join(',', cols) != csv_header) csv_open(cols);

		let row = [ tstamp(t), overall ];
		for (let x in tlist) push(row, x.t.res?.loss, x.t.res?.rtt);
		if (cfg.iptv.enabled && cfg.iptv.device) push(row, iptv_res?.state, iptv_res?.kbps, iptv_res?.pps);
		for (let d in devs) {
			let r = res[d.dev];
			push(row, r.present ? (r.up ? 'up' : 'down') : 'missing', r.speed,
				r.delta?.err, r.delta?.crc, r.delta?.drop,
				r.delta ? round(r.delta.rx_bps / 1000, 0) : null,
				r.delta ? round(r.delta.tx_bps / 1000, 0) : null);
		}
		csv_append(row);
	}

	let state = {
		ts: t,
		started: started,
		interval: cfg.interval,
		overall,
		wan,
		iptv: iptv_res,
		ports: { level: ports_level, list: ports },
		counts: { h1: count_events(t - 3600), h24: count_events(t - 86400) },
		history,
		csv_rows
	};
	write_atomic(`${RUNDIR}/state.json`, sprintf('%J', state));

	/* kick off pings for the next tick (results are used asynchronously) */
	start_pings();
}

/* ------------------------------------------------------------------ main */

fs.mkdir(RUNDIR);

let old = json(fs.readfile(`${RUNDIR}/events.json`) || '[]');
if (type(old) == 'array') events = old;

/* keep chart history across collector restarts (e.g. after saving settings) */
let load_hist = (name, max) => {
	let h;
	try { h = json(fs.readfile(`${RUNDIR}/${name}`) || 'null'); } catch (e) { h = null; }
	if (name == 'state.json') h = h?.history;
	if (type(h?.t) != 'array' || type(h?.s) != 'object') return { t: [], s: {} };
	let n = length(h.t);
	for (let k, arr in h.s)
		if (type(arr) != 'array' || length(arr) != n) return { t: [], s: {} };
	if (n > max) {
		h.t = slice(h.t, n - max);
		for (let k, arr in h.s) h.s[k] = slice(arr, n - max);
	}
	return h;
};
history = load_hist('state.json', cfg.history);
history_min = load_hist('history.json', cfg.long_history);

emit('info', 'system', 'collector', 'monitor_start', { interval: cfg.interval });

uloop.init();
refresh_wan_device();
start_pings();

let timer;
timer = uloop.timer(cfg.wan.enabled ? (cfg.wan.count + 2) * 1000 : 10, () => {
	timer.set(cfg.interval * 1000);
	try {
		tick();
	}
	catch (e) {
		warn(`isp-tester: tick failed: ${e}\n${e.stacktrace?.[0]?.context ?? ''}\n`);
	}
});

uloop.run();
