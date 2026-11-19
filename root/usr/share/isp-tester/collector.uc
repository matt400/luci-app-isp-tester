#!/usr/bin/ucode
/*
 * luci-app-isp-tester - collector daemon
 *
 * Periodically samples:
 *   - interface counters / link state of configured devices (ports, WAN, IPTV)
 *   - ping loss / latency to the ISP gateway and configured targets
 *   - IPTV bitrate on the configured device (on its own fast timer, default
 *     every second, so freezes of a few seconds are not averaged away)
 *   - ping jitter, DNS resolution time, WAN session restarts (PPPoE/DHCP)
 *   - IGMP group membership, multicast proxy process, bridge MDB
 *   - router load (CPU per core, softirq, RAM, conntrack table)
 *   - "problem now" marks set by the user from the web UI
 *
 * and turns state changes into events. Everything is kept in RAM (/tmp):
 *   state.json   - current health + short history for charts (read by rpcd)
 *   events.json  - event timeline (ring buffer)
 *   samples.csv  - one row per tick (ring buffer, for export)
 * Optionally copied to persistent storage (USB) and forwarded to syslog /
 * push notifications (ntfy, Telegram, webhook).
 *
 * Environment overrides (used for testing off-device):
 *   ISP_TESTER_RUNDIR, ISP_TESTER_SYSNET, ISP_TESTER_CONFIG (JSON file instead of UCI),
 *   ISP_TESTER_PING (ping binary), ISP_TESTER_ROUTE (/proc/net/route path),
 *   ISP_TESTER_PROC (/proc), ISP_TESTER_NSLOOKUP, ISP_TESTER_LOGGER, ISP_TESTER_FETCH
 */
'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';

const RUNDIR = getenv('ISP_TESTER_RUNDIR') || '/tmp/isp-tester';
const SYSNET = getenv('ISP_TESTER_SYSNET') || '/sys/class/net';
const PING = getenv('ISP_TESTER_PING') || 'ping';
const ROUTE = getenv('ISP_TESTER_ROUTE') || '/proc/net/route';
const PROC = getenv('ISP_TESTER_PROC') || '/proc';
const NSLOOKUP = getenv('ISP_TESTER_NSLOOKUP') || 'nslookup';

function find_bin(env, names) {
	let e = getenv(env);
	if (e) return e;
	for (let n in names)
		if (fs.stat(n)) return n;
	return null;
}

const LOGGER = find_bin('ISP_TESTER_LOGGER', [ '/usr/bin/logger', '/bin/logger' ]);
const FETCH = find_bin('ISP_TESTER_FETCH', [ '/bin/uclient-fetch', '/usr/bin/uclient-fetch', '/usr/bin/wget', '/bin/wget' ]);
const TIMEOUT = fs.stat('/usr/bin/timeout') ? '/usr/bin/timeout' : (fs.stat('/bin/timeout') ? '/bin/timeout' : null);
const BRIDGE = find_bin('ISP_TESTER_BRIDGE', [ '/usr/sbin/bridge', '/sbin/bridge' ]);
const PROXIES = [ 'igmpproxy', 'mcproxy', 'omcproxy', 'improxy' ];

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
		persist_dir: '',
		persist_interval: 900,
		syslog: false,
		wan: {
			enabled: true, interface: 'wan', device: '', ping_gateway: true,
			targets: [ '1.1.1.1', '8.8.8.8' ], count: 3,
			loss_warn: 1, loss_fail: 50, rtt_warn: 80, jitter_warn: 0,
			dns: true, dns_host: 'openwrt.org', dns_server: '', dns_warn: 500
		},
		iptv: {
			enabled: true, device: '', direction: 'rx', bridge: '',
			min_kbps: 500, idle_after: 60, dip_pct: 40,
			sample_interval: 1, stall_after: 2,
			igmp: true, igmp_device: ''
		},
		system: {
			enabled: true, cpu_warn: 90, mem_warn: 10, conntrack_warn: 90
		},
		notify: {
			enabled: false, service: 'ntfy', url: '', token: '', chat_id: '',
			min_level: 'err', cooldown: 300, lang: 'en'
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
		let y = cur.get_all('isp_tester', 'system') || {};
		let n = cur.get_all('isp_tester', 'notify') || {};

		c.persist_dir = g.persist_dir ?? '';
		c.persist_interval = num(g.persist_interval, c.persist_interval);
		c.syslog      = bool(g.syslog, false);

		c.wan.jitter_warn = num(w.jitter_warn, c.wan.jitter_warn);
		c.wan.dns        = bool(w.dns, true);
		c.wan.dns_host   = w.dns_host ?? c.wan.dns_host;
		c.wan.dns_server = w.dns_server ?? '';
		c.wan.dns_warn   = num(w.dns_warn, c.wan.dns_warn);

		c.iptv.igmp        = bool(t.igmp, true);
		c.iptv.igmp_device = t.igmp_device ?? '';

		c.system.enabled        = bool(y.enabled, true);
		c.system.cpu_warn       = num(y.cpu_warn, c.system.cpu_warn);
		c.system.mem_warn       = num(y.mem_warn, c.system.mem_warn);
		c.system.conntrack_warn = num(y.conntrack_warn, c.system.conntrack_warn);

		c.notify.enabled   = bool(n.enabled, false);
		c.notify.service   = n.service ?? c.notify.service;
		c.notify.url       = n.url ?? '';
		c.notify.token     = n.token ?? '';
		c.notify.chat_id   = n.chat_id ?? '';
		c.notify.min_level = (n.min_level == 'warn') ? 'warn' : 'err';
		c.notify.cooldown  = num(n.cooldown, c.notify.cooldown);
		c.notify.lang      = (n.lang == 'pl') ? 'pl' : 'en';

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
		c.iptv.sample_interval = num(t.sample_interval, c.iptv.sample_interval);
		c.iptv.stall_after = num(t.stall_after, c.iptv.stall_after);

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
	/* 0 (or >= interval) = sample IPTV only on the main tick, like before */
	if (c.iptv.sample_interval < 0) c.iptv.sample_interval = 0;
	if (c.iptv.sample_interval > 0 && c.iptv.sample_interval < 0.5) c.iptv.sample_interval = 0.5;
	if (c.iptv.sample_interval >= c.interval) c.iptv.sample_interval = 0;
	if (c.iptv.stall_after < 0) c.iptv.stall_after = 0;
	if (c.iptv.igmp_device && !valid_dev(c.iptv.igmp_device)) c.iptv.igmp_device = '';
	/* IGMP memberships are joined by the multicast proxy on its upstream, which
	 * is the IPTV VLAN when the bitrate is measured there */
	c.iptv.igmp_dev = c.iptv.igmp_device || (c.iptv.direction == 'rx' ? c.iptv.device : '');
	if (!valid_host(c.wan.dns_host)) c.wan.dns = false;
	if (c.wan.dns_server && !valid_host(c.wan.dns_server)) c.wan.dns_server = '';
	if (c.persist_interval < 60) c.persist_interval = 60;
	if (c.notify.cooldown < 30) c.notify.cooldown = 30;
	if (type(c.persist_dir) != 'string' || !match(c.persist_dir, /^\/[A-Za-z0-9._\/-]+$/) || match(c.persist_dir, /^\/(tmp|var)(\/|$)/) || index(c.persist_dir, '..') >= 0)
		c.persist_dir = '';

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
let iptv = {
	state: 'idle', since: now(), kbps: 0, pps: 0, avg: null, dip: false,
	stall_since: null, stall_m: null,       /* wall / monotonic start of the current stall */
	low_w: null, low_m: null,               /* start of a below-threshold run not yet long enough */
	prev: null, prev_m: null, prev_w: null, /* last counter reading (fast sampler) */
	acc: null                               /* per-tick aggregate of the fast samples */
};
let csv_rows = 0;
let csv_header = null;
let last_mono = null;
let started = now();
let dns = { busy: false, state: 'ok', since: now(), res: null, t0: null };
let wansess = { up: null, uptime: null, seen: null, ip: null, since: now(), reconnects: 0 };
let igmp = { groups: null, hist: [], proxy: null, proxy_seen: false, proxy_since: now() };
let sys = { prev: null, cpu_n: 0, cpu: false, mem: false, ct: false, cpu_since: 0, mem_since: 0, ct_since: 0 };
let notif = { pending: [], last: 0, busy: false, last_ok: null, last_fail: null, last_err: null };
let persist_last = now();
const HOSTNAME = trim(fs.readfile(`${PROC}/sys/kernel/hostname`) ?? '') || 'OpenWrt';

function tstamp(t) {
	let lt = localtime(t);
	return sprintf('%04d-%02d-%02d %02d:%02d:%02d', lt.year, lt.mon, lt.mday, lt.hour, lt.min, lt.sec);
}

/* ------------------------------------------------------- event messages */

/* short plain-text messages for syslog and push notifications (the web UI
 * has its own translated texts) */
const MSG = {
	en: {
		link_down: '%s: link DOWN', link_up: '%s: link up again after %s', link_flap: '%s: link flapped',
		speed_change: '%s: link speed %s -> %s Mbit/s', errors: '%s: %d errors, %d CRC errors', drops: '%s: %d dropped packets',
		dev_missing: 'Device %s disappeared', dev_present: 'Device %s is back',
		target_degraded: '%s: degraded (loss %d%%, ping %s ms, jitter %s ms)', target_fail: '%s: not responding', target_ok: '%s: OK again after %s',
		wan_down: 'INTERNET DOWN - no target responds', wan_up: 'Internet back after %s',
		wan_if_down: 'WAN interface %s went down', wan_if_up: 'WAN interface %s up again after %s', wan_reconnect: 'WAN session restarted (was up %s)',
		wan_ip_change: 'WAN address changed %s -> %s',
		dns_fail: 'DNS lookup of %s failed', dns_slow: 'DNS lookup slow: %d ms', dns_ok: 'DNS OK again after %s',
		stream_stall: 'IPTV STREAM STOPPED', stream_resume: 'IPTV stream resumed after %s', stream_lost: 'IPTV stream did not come back within %s',
		stream_dip: 'IPTV bitrate dropped to %d kbit/s',
		proxy_down: 'Multicast proxy %s is not running', proxy_up: 'Multicast proxy %s running again',
		cpu_high: 'Router CPU busy: %d%% (softirq %d%%)', mem_low: 'Router RAM low: %d%% free', conntrack_full: 'Connection table %d%% full',
		user_mark: 'Problem reported by user: %s', test: 'Test message - notifications work.'
	},
	pl: {
		link_down: '%s: BRAK ŁĄCZA', link_up: '%s: łącze wróciło po %s', link_flap: '%s: łącze mrugnęło',
		speed_change: '%s: prędkość łącza %s -> %s Mbit/s', errors: '%s: %d błędów, %d błędów CRC', drops: '%s: %d odrzuconych pakietów',
		dev_missing: 'Urządzenie %s zniknęło', dev_present: 'Urządzenie %s wróciło',
		target_degraded: '%s: problemy (straty %d%%, ping %s ms, jitter %s ms)', target_fail: '%s: nie odpowiada', target_ok: '%s: znów OK po %s',
		wan_down: 'BRAK INTERNETU - żaden cel nie odpowiada', wan_up: 'Internet wrócił po %s',
		wan_if_down: 'Interfejs WAN %s rozłączony', wan_if_up: 'Interfejs WAN %s znów działa po %s', wan_reconnect: 'Sesja WAN zestawiona od nowa (trwała %s)',
		wan_ip_change: 'Zmiana adresu WAN %s -> %s',
		dns_fail: 'Błąd DNS dla %s', dns_slow: 'Wolny DNS: %d ms', dns_ok: 'DNS znów OK po %s',
		stream_stall: 'STRUMIEŃ IPTV ZATRZYMANY', stream_resume: 'Strumień IPTV wrócił po %s', stream_lost: 'Strumień IPTV nie wrócił w ciągu %s',
		stream_dip: 'Bitrate IPTV spadł do %d kbit/s',
		proxy_down: 'Proxy multicast %s nie działa', proxy_up: 'Proxy multicast %s znów działa',
		cpu_high: 'Router przeciążony: CPU %d%% (softirq %d%%)', mem_low: 'Mało RAM: wolne %d%%', conntrack_full: 'Tablica połączeń zajęta w %d%%',
		user_mark: 'Problem zgłoszony ręcznie: %s', test: 'Wiadomość testowa - powiadomienia działają.'
	}
};

function dur_txt(s) {
	s = int(s ?? 0);
	if (s >= 3600) return sprintf('%dh%02dm', s / 3600, (s % 3600) / 60);
	if (s >= 60) return sprintf('%dm%02ds', s / 60, s % 60);
	return sprintf('%ds', s);
}

function event_msg(e, lang) {
	let m = MSG[lang] ?? MSG.en, d = e.d ?? {}, f = m[e.type];
	if (!f) return e.type;
	switch (e.type) {
	case 'link_down': case 'link_flap': return sprintf(f, d.dev);
	case 'link_up': return sprintf(f, d.dev, dur_txt(d.dur));
	case 'speed_change': return sprintf(f, d.dev, d.from, d.to);
	case 'errors': return sprintf(f, d.dev, d.err, d.crc);
	case 'drops': return sprintf(f, d.dev, d.n);
	case 'dev_missing': case 'dev_present': return sprintf(f, d.dev);
	case 'target_degraded': return sprintf(f, e.src, d.loss, d.rtt ?? '-', d.jitter ?? '-');
	case 'target_fail': return sprintf(f, e.src);
	case 'target_ok': return sprintf(f, e.src, dur_txt(d.dur));
	case 'wan_up': case 'stream_resume': case 'stream_lost': case 'dns_ok': return sprintf(f, dur_txt(d.dur));
	case 'wan_if_down': return sprintf(f, d.iface);
	case 'wan_if_up': return sprintf(f, d.iface, dur_txt(d.dur));
	case 'wan_reconnect': return sprintf(f, dur_txt(d.prev));
	case 'wan_ip_change': return sprintf(f, d.from, d.to);
	case 'dns_fail': return sprintf(f, d.host);
	case 'dns_slow': return sprintf(f, d.ms);
	case 'stream_dip': return sprintf(f, d.kbps);
	case 'proxy_down': case 'proxy_up': return sprintf(f, d.name);
	case 'cpu_high': return sprintf(f, d.cpu, d.sirq);
	case 'mem_low': return sprintf(f, d.pct);
	case 'conntrack_full': return sprintf(f, d.pct);
	case 'user_mark': return sprintf(f, d.note || '-');
	default: return f;
	}
}

/* ------------------------------------------------------- syslog / notify */

/* recoveries are sent too, so a "down" message is always followed by "back" */
const RECOVERY = { wan_up: true, stream_resume: true, link_up: true, wan_if_up: true, proxy_up: true, dns_ok: true };

function to_syslog(e) {
	if (!cfg.syslog || !LOGGER || e.lvl == 'info') return;
	uloop.process(LOGGER, [ '-t', 'isp-tester', '-p', e.lvl == 'err' ? 'daemon.err' : 'daemon.warn', event_msg(e, 'en') ], null, () => {});
}

function urlenc(s) {
	let out = '';
	for (let i = 0; i < length(s); i++) {
		let c = ord(s, i);
		if ((c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 46 || c == 95 || c == 126)
			out += chr(c);
		else
			out += sprintf('%%%02X', c);
	}
	return out;
}

function notify_queue(e) {
	let n = cfg.notify;
	if (!n.enabled || e.area == 'system' && e.lvl == 'info') return;
	let want = (e.lvl == 'err') || (e.lvl == 'warn' && (n.min_level == 'warn' || RECOVERY[e.type]));
	if (!want) return;
	push(notif.pending, `${substr(tstamp(e.ts), 11)} ${event_msg(e, n.lang)}`);
	if (length(notif.pending) > 25)
		notif.pending = slice(notif.pending, length(notif.pending) - 25);
}

function notify_flush(force) {
	let n = cfg.notify;
	if (!n.enabled || notif.busy || !length(notif.pending) || !FETCH) return;
	if (!force && now() - notif.last < n.cooldown) return;

	let count = length(notif.pending);
	let text = `ISP Tester (${HOSTNAME})\n` + join('\n', notif.pending);
	let url, body;

	if (n.service == 'telegram') {
		if (!n.token || !n.chat_id) return;
		url = `https://api.telegram.org/bot${n.token}/sendMessage`;
		body = `chat_id=${urlenc(n.chat_id)}&text=${urlenc(text)}`;
	}
	else if (n.service == 'webhook') {
		url = n.url;
		body = sprintf('%J', { text, host: HOSTNAME, events: notif.pending });
	}
	else {
		url = n.url;
		body = text;
	}
	if (!match(url ?? '', /^https?:\/\/[^ \t\n]+$/)) return;

	notif.busy = true;
	notif.last = now();
	let proc = uloop.process(FETCH, [ '-q', '-T', '15', '-O', '/dev/null', `--post-data=${body}`, url ], null, (code) => {
		notif.busy = false;
		if (code == 0) {
			notif.pending = slice(notif.pending, count);
			notif.last_ok = now();
		}
		else {
			notif.last_fail = now();
			notif.last_err = code;
			/* no Internet (the usual reason): retry in a minute */
			notif.last = now() - n.cooldown + 60;
		}
	});
	if (!proc) notif.busy = false;
}

/* ----------------------------------------------------------------- events */

function save_events() {
	write_atomic(`${RUNDIR}/events.json`, sprintf('%J', events));
}

function emit(lvl, area, src, typ, data, ts) {
	let e = { ts: ts ?? now(), lvl, area, src, type: typ, d: data ?? {} };
	push(events, e);
	if (length(events) > cfg.max_events)
		events = slice(events, length(events) - cfg.max_events);
	save_events();
	to_syslog(e);
	notify_queue(e);
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
const AGG_MODE = { rtt: 'avg', rttmax: 'max', loss: 'max', jit: 'max', dns: 'max', cpu: 'max', sirq: 'max',
	'iptv:kbps': 'avg', 'iptv:min': 'min', err: 'sum', drop: 'sum', lvl: 'max' };

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
		/* netifd knows the gateway (and the PPPoE peer, which is not in the routing
		 * table); /proc/net/route is the fallback when ubus is not available */
		let gw = cfg.wan.gw ?? default_gateway(cfg.wan.device) ?? default_gateway(null);
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
	/* jitter: mean difference between consecutive replies (RFC 3550 style) */
	let times = match(out, /time=([0-9.]+)/g);
	if (times && length(times) >= 2) {
		let sum = 0;
		for (let i = 1; i < length(times); i++) {
			let d = +times[i][1] - +times[i - 1][1];
			sum += (d < 0) ? -d : d;
		}
		r.jitter = round(sum / (length(times) - 1), 1);
	}
	return r;
}

/* why a target is not ok: 'loss', 'rtt', 'jitter' or null */
function target_why(r) {
	if (r.loss >= cfg.wan.loss_warn) return 'loss';
	if (r.rtt != null && cfg.wan.rtt_warn > 0 && r.rtt >= cfg.wan.rtt_warn) return 'rtt';
	if (r.jitter != null && cfg.wan.jitter_warn > 0 && r.jitter >= cfg.wan.jitter_warn) return 'jitter';
	return null;
}

function target_level(r) {
	if (r.loss >= cfg.wan.loss_fail) return 'fail';
	return target_why(r) ? 'warn' : 'ok';
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
				{ host: t.host, loss: r.loss, rtt: r.rtt, rtt_max: r.rtt_max, jitter: r.jitter, why: target_why(r) });
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
		/* not -q: the per-reply times are needed for the jitter */
		let cmd = sprintf('exec %s -c %d -W 1 -w %d %s > %s 2>&1', PING, n, n + 1, tg.host, t.file);
		t.busy = true;
		let label = tg.label;
		let proc = uloop.process('/bin/sh', [ '-c', cmd ], null, () => on_ping_done(label));
		if (!proc) t.busy = false;
	}

	for (let k, t in targets)
		if (!active[k]) t.active = false;
}

/* ------------------------------------------------------------------- DNS */

function on_dns_done() {
	dns.busy = false;
	let ms = round((mono() - dns.t0) * 1000, 0);
	let out = fs.readfile(dns.file) ?? '';
	fs.unlink(dns.file);

	/* busybox and bind nslookup both print "Name: x" followed by "Address: y" */
	let ok = match(out, /Name:[^\n]*\n[ \t]*Address[^\n]*[0-9]/) != null;
	dns.res = { ok, ms: ok ? ms : null };

	let lvl = !ok ? 'fail' : (cfg.wan.dns_warn > 0 && ms >= cfg.wan.dns_warn) ? 'slow' : 'ok';
	if (lvl != dns.state) {
		if (lvl == 'ok')
			emit('info', 'wan', 'dns', 'dns_ok', { dur: now() - dns.since, ms });
		else if (lvl == 'fail')
			emit('warn', 'wan', 'dns', 'dns_fail', { host: cfg.wan.dns_host, server: cfg.wan.dns_server });
		else
			emit('warn', 'wan', 'dns', 'dns_slow', { host: cfg.wan.dns_host, ms });
		dns.state = lvl;
		dns.since = now();
	}
}

function start_dns() {
	if (!cfg.wan.enabled || !cfg.wan.dns || dns.busy) return;
	dns.file = `${RUNDIR}/dns.out`;
	/* host and server are validated (valid_host), so they are safe in a shell line */
	let cmd = sprintf('exec %s%s %s %s > %s 2>&1', TIMEOUT ? TIMEOUT + ' 5 ' : '', NSLOOKUP,
		cfg.wan.dns_host, cfg.wan.dns_server, dns.file);
	dns.busy = true;
	dns.t0 = mono();
	if (!uloop.process('/bin/sh', [ '-c', cmd ], null, () => on_dns_done()))
		dns.busy = false;
}

/* ----------------------------------------------------------- WAN session */

/* netifd status of the WAN interface: up/down, session uptime, address */
function wan_session(st) {
	let up = st.up === true;
	let upt = (type(st.uptime) == 'int' || type(st.uptime) == 'double') ? st.uptime : null;
	let ip = st['ipv4-address']?.[0]?.address;
	let iface = cfg.wan.interface, t = now();

	if (wansess.up != null) {
		if (wansess.up && !up) {
			emit('err', 'wan', 'netifd', 'wan_if_down', { iface, prev: wansess.uptime });
		}
		else if (!wansess.up && up) {
			wansess.reconnects++;
			emit('warn', 'wan', 'netifd', 'wan_if_up', { iface, dur: t - wansess.since, ip });
		}
		else if (up && upt != null && wansess.uptime != null && upt < wansess.uptime) {
			/* went down and up again between two checks (PPPoE / DHCP session restart) */
			wansess.reconnects++;
			emit('warn', 'wan', 'netifd', 'wan_reconnect', { iface, prev: wansess.uptime, ip });
		}
		if (up && ip && wansess.ip && ip != wansess.ip)
			emit('info', 'wan', 'netifd', 'wan_ip_change', { iface, from: wansess.ip, to: ip });
	}

	if (up != wansess.up) wansess.since = t;
	wansess.up = up;
	wansess.uptime = up ? upt : null;
	wansess.proto = st.proto;
	if (ip) wansess.ip = ip;
}

/* ------------------------------------------------------------------ IGMP */

/* multicast groups joined on dev, from /proc/net/igmp (the proxy joins the
 * groups the decoders asked for on its upstream interface) */
function igmp_groups(dev) {
	let data = fs.readfile(`${PROC}/net/igmp`);
	if (data == null) return null;

	let cur = null, out = { found: false, ver: null, groups: [] };
	for (let line in split(data, '\n')) {
		let f = split(trim(line), /\s+/);
		if (!length(f) || f[0] == '' || f[0] == 'Idx') continue;
		if (match(f[0], /^[0-9]+$/) && length(f) >= 2) {
			cur = f[1];
			if (cur == dev) {
				out.found = true;
				let v = f[length(f) - 1];
				out.ver = match(v, /^V[123]$/) ? v : null;
			}
			continue;
		}
		if (cur != dev || !match(f[0], /^[0-9A-Fa-f]{8}$/)) continue;

		/* the address is printed in host byte order: reversed on little-endian */
		let g = hex(f[0]), le = g & 255;
		let ip = (le >= 224 && le <= 239)
			? sprintf('%d.%d.%d.%d', le, (g >> 8) & 255, (g >> 16) & 255, (g >> 24) & 255)
			: sprintf('%d.%d.%d.%d', (g >> 24) & 255, (g >> 16) & 255, (g >> 8) & 255, g & 255);
		if (match(ip, /^224\.0\.0\./) || ip == '239.255.255.250') continue;   /* link-local, SSDP */
		push(out.groups, ip);
	}
	return out;
}

function igmp_poll() {
	if (!cfg.iptv.enabled || !cfg.iptv.igmp || !cfg.iptv.igmp_dev) return;
	let g = igmp_groups(cfg.iptv.igmp_dev);
	if (!g) return;

	igmp.found = g.found;
	igmp.version = g.ver;
	let cur = sort(g.groups);
	if (igmp.groups != null && join(',', cur) != join(',', igmp.groups)) {
		igmp.last_change = now();
		push(igmp.hist, { ts: now(), before: igmp.groups, after: cur });
		if (length(igmp.hist) > 20) igmp.hist = slice(igmp.hist, -20);
	}
	igmp.groups = cur;
}

/*
 * What IGMP did around a freeze that started at `from` (called when the
 * stream comes back):
 *   zap    - other groups after than before: a channel change, not a fault
 *   left   - the membership was dropped (and joined again): IGMP timeout
 *   joined - subscribed the whole time: the data just stopped coming
 */
function igmp_classify(from) {
	if (!cfg.iptv.igmp || !cfg.iptv.igmp_dev || igmp.groups == null) return null;
	/* the group change that causes a freeze comes within a sample or two of it */
	let rel = filter(igmp.hist, (h) => h.ts >= from - 3);
	if (!length(rel))
		return length(igmp.groups) ? 'joined' : null;

	let before = rel[0].before, after = igmp.groups;
	let emptied = length(filter(rel, (h) => !length(h.after))) > 0;
	if (length(before) && length(after) && join(',', before) != join(',', after)) return 'zap';
	if (emptied || !length(before)) return 'left';
	return null;
}

function proxy_process() {
	for (let pid in (fs.lsdir(PROC) ?? [])) {
		if (!match(pid, /^[0-9]+$/)) continue;
		let c = trim(fs.readfile(`${PROC}/${pid}/comm`) ?? '');
		if (index(PROXIES, c) >= 0) return { name: c, pid };
	}
	return null;
}

function sample_proxy() {
	if (!cfg.iptv.enabled || !cfg.iptv.igmp) return;
	let p = proxy_process();
	let t = now();

	if (p && igmp.proxy == null && igmp.proxy_seen)
		emit('warn', 'iptv', 'proxy', 'proxy_up', { name: p.name, dur: t - igmp.proxy_since });
	else if (p && igmp.proxy != null && p.pid != igmp.pid)
		emit('warn', 'iptv', 'proxy', 'proxy_restart', { name: p.name });
	else if (!p && igmp.proxy != null) {
		emit('err', 'iptv', 'proxy', 'proxy_down', { name: igmp.proxy });
		igmp.proxy_since = t;
	}

	if (p) {
		igmp.proxy_seen = true;
		igmp.last_name = p.name;
		igmp.pid = p.pid;
	}
	igmp.proxy = p?.name;
}

/* bridge multicast database: which group goes to which port */
function bridge_mdb(br) {
	if (!BRIDGE) return null;
	let f = fs.popen(`${BRIDGE} -j mdb show dev ${br} 2>/dev/null`, 'r');
	if (!f) return null;
	let out = f.read('all');
	f.close();
	let j;
	try { j = json(out || '[]'); } catch (e) { return null; }

	let list = [];
	for (let blk in (type(j) == 'array' ? j : []))
		for (let e in (blk?.mdb ?? [])) {
			if (!e?.grp || match(e.grp, /^(224\.0\.0\.|ff0[0-9a-f]:)/)) continue;
			push(list, { grp: e.grp, port: e.port, state: e.state });
		}
	return list;
}

/* ---------------------------------------------------------- router load */

function read_cpus() {
	let data = fs.readfile(`${PROC}/stat`);
	if (!data) return null;
	let out = {};
	for (let line in split(data, '\n')) {
		if (substr(line, 0, 3) != 'cpu') continue;
		let f = split(trim(line), /\s+/);
		let v = map(slice(f, 1, 9), (x) => num(x, 0));
		let total = 0;
		for (let x in v) total += x;
		/* user nice system idle iowait irq softirq steal */
		out[f[0]] = { total, idle: (v[3] ?? 0) + (v[4] ?? 0), sirq: v[6] ?? 0 };
	}
	return out;
}

function meminfo() {
	let data = fs.readfile(`${PROC}/meminfo`);
	if (!data) return null;
	let m = {};
	for (let line in split(data, '\n')) {
		let r = match(line, /^(\w+):\s+(\d+)/);
		if (r) m[r[1]] = +r[2];
	}
	let avail = m.MemAvailable ?? ((m.MemFree ?? 0) + (m.Cached ?? 0) + (m.Buffers ?? 0));
	return m.MemTotal ? { total: m.MemTotal, avail, pct: round(avail * 100 / m.MemTotal, 0) } : null;
}

/* raise/clear a load condition with hysteresis */
function load_flag(key, on, off, typ, data) {
	if (!sys[key] && on) {
		sys[key] = true;
		sys[key + '_since'] = now();
		emit('warn', 'system', 'router', typ, data);
	}
	else if (sys[key] && off) {
		sys[key] = false;
		emit('info', 'system', 'router', typ + '_ok', { dur: now() - sys[key + '_since'] });
	}
}

function sample_system() {
	if (!cfg.system.enabled) return null;
	let o = { level: 'ok', reasons: [] };

	let c = read_cpus();
	if (c && sys.prev) {
		let best = null, cores = 0;
		for (let k, v in c) {
			let p = sys.prev[k];
			if (!p) continue;
			let dt = v.total - p.total;
			if (dt <= 0) continue;
			let busy = 100 - (v.idle - p.idle) * 100 / dt, si = (v.sirq - p.sirq) * 100 / dt;
			if (k == 'cpu') {
				o.cpu = round(busy, 0);
				o.sirq = round(si, 0);
			}
			else {
				cores++;
				if (best == null || busy > best.busy) best = { core: k, busy, si };
			}
		}
		/* packet forwarding often saturates a single core: judge by the busiest */
		o.cores = cores;
		o.cpu_max = best ? round(best.busy, 0) : o.cpu;
		o.sirq_max = best ? round(best.si, 0) : o.sirq;
		o.core = best?.core;
	}
	sys.prev = c;

	let la = split(trim(fs.readfile(`${PROC}/loadavg`) ?? ''), ' ');
	o.load = num(la[0], null);

	let mem = meminfo();
	if (mem) { o.mem_pct = mem.pct; o.mem_total = mem.total; }

	let ctn = num(trim(fs.readfile(`${PROC}/sys/net/netfilter/nf_conntrack_count`) ?? ''), null);
	let ctm = num(trim(fs.readfile(`${PROC}/sys/net/netfilter/nf_conntrack_max`) ?? ''), null);
	if (ctn != null && ctm > 0) { o.ct = ctn; o.ct_max = ctm; o.ct_pct = round(ctn * 100 / ctm, 0); }

	let y = cfg.system;
	if (o.cpu_max != null && y.cpu_warn > 0) {
		if (o.cpu_max >= y.cpu_warn) sys.cpu_n++;
		else if (o.cpu_max < y.cpu_warn - 10) sys.cpu_n = 0;
		/* two intervals in a row, so a single busy moment (e.g. opkg) does not count */
		load_flag('cpu', sys.cpu_n >= 2, sys.cpu_n == 0, 'cpu_high', { cpu: o.cpu_max, sirq: o.sirq_max, core: o.core });
	}
	if (o.mem_pct != null && y.mem_warn > 0)
		load_flag('mem', o.mem_pct < y.mem_warn, o.mem_pct >= y.mem_warn + 5, 'mem_low', { pct: o.mem_pct });
	if (o.ct_pct != null && y.conntrack_warn > 0)
		load_flag('ct', o.ct_pct >= y.conntrack_warn, o.ct_pct < y.conntrack_warn - 5, 'conntrack_full', { pct: o.ct_pct, n: o.ct, max: o.ct_max });

	if (sys.cpu) push(o.reasons, { c: 'cpu_high', cpu: o.cpu_max, core: o.core });
	if (sys.mem) push(o.reasons, { c: 'mem_low', pct: o.mem_pct });
	if (sys.ct)  push(o.reasons, { c: 'conntrack_full', pct: o.ct_pct });
	if (length(o.reasons)) o.level = 'warn';
	else if (recent_level('system', 'router') != 'ok') {
		o.level = 'warn';
		push(o.reasons, { c: 'recent_events' });
	}
	return o;
}

/* ------------------------------------------------- user marks, persistence */

/* "problem now" reports from the web UI (appended by rpcd) */
function handle_marks() {
	let f = `${RUNDIR}/marks.pending`, work = `${RUNDIR}/marks.work`;
	if (!fs.stat(f) || !fs.rename(f, work)) return;
	let data = fs.readfile(work) ?? '';
	fs.unlink(work);

	let t = now();
	for (let line in split(trim(data), '\n')) {
		let m;
		try { m = json(line); } catch (e) { continue; }
		if (type(m) != 'object') continue;
		let ts = int(m.ts ?? t);
		if (ts > t || ts < t - 3600) ts = t;
		let what = match(`${m.what ?? ''}`, /^[a-z_]{1,20}$/) ? m.what : 'other';
		emit('warn', 'user', 'user', 'user_mark', { what, note: substr(`${m.note ?? ''}`, 0, 200) }, ts);
	}
}

function handle_notify_test() {
	let f = `${RUNDIR}/notify_test`;
	if (!fs.stat(f)) return;
	fs.unlink(f);
	push(notif.pending, (MSG[cfg.notify.lang] ?? MSG.en).test);
	notify_flush(true);
}

const PERSIST_FILES = [ 'events.json', 'history.json', 'samples.csv' ];

function persist_path() {
	if (!cfg.persist_dir || fs.stat(cfg.persist_dir)?.type != 'directory') return null;
	let p = `${cfg.persist_dir}/isp-tester`;
	fs.mkdir(p);
	return (fs.stat(p)?.type == 'directory') ? p : null;
}

function persist_save() {
	persist_last = now();
	let p = persist_path();
	if (!p) return false;
	for (let f in PERSIST_FILES) {
		let data = fs.readfile(`${RUNDIR}/${f}`);
		if (data != null) write_atomic(`${p}/${f}`, data);
	}
	return true;
}

/* after a reboot /tmp is empty: bring back the copy from persistent storage */
function persist_restore() {
	let p = persist_path();
	if (!p || fs.stat(`${RUNDIR}/events.json`)) return false;
	let n = 0;
	for (let f in PERSIST_FILES) {
		let data = fs.readfile(`${p}/${f}`);
		if (data != null && fs.writefile(`${RUNDIR}/${f}`, data) != null) n++;
	}
	return n > 0;
}

/* ------------------------------------------------------------------ IPTV */

function iptv_fast() {
	return cfg.iptv.enabled && cfg.iptv.device && cfg.iptv.sample_interval > 0;
}

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
		direction: cfg.iptv.direction, min_kbps: cfg.iptv.min_kbps,
		sample_interval: iptv_fast() ? cfg.iptv.sample_interval : cfg.interval,
		min: iptv.tick?.min, stall_s: iptv.tick?.stall_s
	};

	if (cfg.iptv.bridge) {
		let b = `${cfg.iptv.bridge}`;
		let cs = (f) => { let v = num(rd(b, `bridge/${f}`), null); return (v == null) ? null : round(v / 100, 0); };
		o.bridge = {
			name: b,
			snooping: rd(b, 'bridge/multicast_snooping'),
			querier: rd(b, 'bridge/multicast_querier'),
			igmp_version: rd(b, 'bridge/multicast_igmp_version'),
			/* kernel timers are in centiseconds */
			membership_interval: cs('multicast_membership_interval'),
			query_interval: cs('multicast_query_interval'),
			mdb: bridge_mdb(b)
		};
	}

	if (cfg.iptv.igmp) {
		o.igmp = {
			dev: cfg.iptv.igmp_dev || null,
			found: igmp.found, version: igmp.version,
			groups: igmp.groups, last_change: igmp.last_change,
			proxy: igmp.proxy ?? igmp.last_name, proxy_running: igmp.proxy != null, proxy_seen: igmp.proxy_seen
		};
		if (igmp.proxy == null && igmp.proxy_seen) {
			level = worst(level, 'warn');
			push(reasons, { c: 'proxy_down', name: igmp.last_name });
			o.level = level;
		}
	}
	return o;
}

/*
 * Stream state machine, fed with one bitrate measurement covering the time
 * from iptv.prev_m/prev_w to m/w. Runs every second with the fast sampler
 * (or once per tick when it is off). A stall is logged when the bitrate stays
 * below min_kbps for at least stall_after seconds; its timestamp is the
 * moment the data stopped, not the moment it was noticed.
 */
function iptv_update(kbps, m, w, from_m, from_w) {
	kbps = round(kbps, 0);
	let active = kbps >= cfg.iptv.min_kbps;

	/* seconds of data missing in this interval, judged against the usual
	 * bitrate; summed over a freeze it gives its length more exactly than
	 * the sample boundaries do (a gap rarely starts on a sample edge) */
	let def = (iptv.avg > 0) ? (m - from_m) * (1 - kbps / iptv.avg) : (active ? 0 : m - from_m);
	if (def < 0) def = 0;
	let prev_def = iptv.last_def ?? 0;
	iptv.last_def = def;
	let was_low = iptv.state == 'stalled' || iptv.low_m != null;

	switch (iptv.state) {
	case 'idle':
		if (active) {
			emit('info', 'iptv', 'stream', 'stream_start', { kbps });
			iptv.state = 'playing';
			iptv.since = w;
			iptv.avg = kbps;
			iptv.dip = false;
		}
		break;

	case 'playing':
		if (active) {
			iptv.low_m = iptv.low_w = null;
			break;
		}
		if (iptv.low_m == null) {
			iptv.low_m = from_m;
			iptv.low_w = from_w;
			/* the freeze probably began inside the previous interval */
			iptv.missing = prev_def;
		}
		iptv.missing += def;
		if (m - iptv.low_m >= cfg.iptv.stall_after - 0.05) {
			emit('err', 'iptv', 'stream', 'stream_stall', { kbps, avg: round(iptv.avg, 0),
				groups: igmp.groups != null ? length(igmp.groups) : null }, iptv.low_w);
			iptv.state = 'stalled';
			iptv.stall_since = iptv.low_w;
			iptv.stall_m = iptv.low_m;
			iptv.low_m = iptv.low_w = null;
			if (iptv.acc) iptv.acc.stalls++;
		}
		break;

	case 'stalled':
		if (active) {
			/* data came back somewhere inside the last interval */
			let dur = round(iptv.missing + def, 0);
			emit('warn', 'iptv', 'stream', 'stream_resume', { dur: dur < 1 ? 1 : dur, kbps,
				igmp: igmp_classify(iptv.stall_since) });
			iptv.state = 'playing';
			iptv.dip = false;
		}
		else {
			iptv.missing += def;
		}
		if (iptv.state == 'stalled' && m - iptv.stall_m >= cfg.iptv.idle_after) {
			emit('warn', 'iptv', 'stream', 'stream_lost', { dur: round(m - iptv.stall_m, 0) });
			iptv.state = 'idle';
			iptv.since = w;
		}
		break;
	}

	if (iptv.acc && (was_low || iptv.state == 'stalled' || iptv.low_m != null))
		iptv.acc.stall_s += def;
}

function iptv_counters() {
	let dev = cfg.iptv.device, tx = cfg.iptv.direction == 'tx';
	if (!fs.stat(`${SYSNET}/${dev}`)) return null;
	let b = num(rd(dev, `statistics/${tx ? 'tx' : 'rx'}_bytes`), null);
	let p = num(rd(dev, `statistics/${tx ? 'tx' : 'rx'}_packets`), null);
	return (b == null || p == null) ? null : { b, p };
}

/* fast sampler: one counter reading per sample_interval */
function iptv_fast_sample() {
	igmp_poll();
	let c = iptv_counters(), m = mono(), w = now();
	if (!c) {
		iptv.prev = null;
		return;
	}

	let p = iptv.prev, dt = p ? m - iptv.prev_m : 0;
	if (p && dt > 0.2 && c.b >= p.b && c.p >= p.p) {
		let kbps = (c.b - p.b) * 8 / dt / 1000;
		let a = iptv.acc ??= { bytes: 0, pkts: 0, dt: 0, min: null, stall_s: 0, stalls: 0, n: 0 };
		a.bytes += c.b - p.b;
		a.pkts += c.p - p.p;
		a.dt += dt;
		a.n++;
		if (a.min == null || kbps < a.min) a.min = kbps;
		iptv_update(kbps, m, w, iptv.prev_m, iptv.prev_w);
	}

	iptv.prev = c;
	iptv.prev_m = m;
	iptv.prev_w = w;
}

/* called once per main tick: summary of the fast samples, dip detection */
function sample_iptv(devres) {
	if (!cfg.iptv.enabled || !cfg.iptv.device) return null;

	let kbps = 0, pps = 0, ok = false;
	let fast = iptv_fast();

	if (fast) {
		let a = iptv.acc;
		iptv.acc = null;
		if (a && a.dt > 0) {
			kbps = a.bytes * 8 / a.dt / 1000;
			pps = a.pkts / a.dt;
			ok = true;
		}
		iptv.tick = a ? { min: round(a.min, 0), stall_s: round(a.stall_s, 0), stalls: a.stalls } : null;
	}
	else {
		let d = devres?.delta;
		if (d) {
			kbps = ((cfg.iptv.direction == 'tx') ? d.tx_bps : d.rx_bps) / 1000;
			pps = (cfg.iptv.direction == 'tx') ? d.tx_pps : d.rx_pps;
			ok = devres.present;
		}
		iptv.tick = null;
		if (ok) {
			let m = mono(), w = now();
			iptv.acc = { stall_s: 0, stalls: 0 };
			iptv_update(kbps, m, w, iptv.prev_m ?? m - cfg.interval, iptv.prev_w ?? w - cfg.interval);
			iptv.tick = { min: round(kbps, 0), stall_s: round(iptv.acc.stall_s, 0), stalls: iptv.acc.stalls };
			iptv.acc = null;
			iptv.prev_m = m;
			iptv.prev_w = w;
		}
	}

	kbps = round(kbps ?? 0, 0);
	iptv.kbps = kbps;
	iptv.pps = round(pps ?? 0, 0);

	/* bitrate dip relative to the running average; only on whole ticks
	 * without a stall, so normal VBR jitter and freezes don't count */
	if (ok && iptv.state == 'playing' && !(iptv.tick?.stall_s > 0) && kbps >= cfg.iptv.min_kbps) {
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
			iptv.avg = (iptv.avg ?? kbps) * 0.9 + kbps * 0.1;
	}

	return iptv_out(devres);
}

/* ------------------------------------------------------------------- CSV */

function csv_columns(devs, tlist) {
	let cols = [ 'time', 'overall' ];
	for (let t in tlist) push(cols, `ping_${t.label}_loss`, `ping_${t.label}_rtt`, `ping_${t.label}_jitter`);
	if (cfg.wan.enabled && cfg.wan.dns) push(cols, 'dns_ms');
	if (cfg.system.enabled) push(cols, 'cpu', 'cpu_busiest_core', 'softirq_busiest_core', 'mem_free_pct', 'conntrack');
	if (cfg.iptv.enabled && cfg.iptv.device) push(cols, 'iptv_state', 'iptv_kbps', 'iptv_min_kbps', 'iptv_stall_s', 'iptv_pps');
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

/* ------------------------------------------------------------------ tick */

let ubus_conn = null;

function wan_status() {
	let f = getenv('ISP_TESTER_WANSTATUS');      /* testing: JSON file instead of ubus */
	if (f) {
		try { return json(fs.readfile(f) || 'null'); } catch (e) { return null; }
	}
	if (getenv('ISP_TESTER_CONFIG')) return null;
	try {
		ubus_conn ??= require('ubus').connect();
		return ubus_conn?.call(`network.interface.${cfg.wan.interface}`, 'status');
	}
	catch (e) {
		ubus_conn = null;
		return null;
	}
}

function refresh_wan_device() {
	if (!cfg.wan.enabled || !cfg.wan.interface) return;
	let st = wan_status();
	if (type(st) != 'object') return;

	wan_session(st);

	if (!cfg.wan.auto_device) return;
	let dev = st.l3_device ?? st.device ?? '';
	if (st.up === false) return;      /* keep last known device while WAN is down */
	if (valid_dev(dev)) cfg.wan.device = dev;

	let gw = null;
	for (let r in (st.route ?? []))
		if (r.target == '0.0.0.0' && r.mask == 0 && r.nexthop && r.nexthop != '0.0.0.0') { gw = r.nexthop; break; }
	gw ??= st['ipv4-address']?.[0]?.ptpaddress;
	cfg.wan.gw = valid_host(gw) ? gw : null;
}

function handle_clear_request() {
	let flag = `${RUNDIR}/clear`;
	if (!fs.stat(flag)) return;
	fs.unlink(flag);
	let p = persist_path();
	if (p)
		for (let f in PERSIST_FILES) fs.unlink(`${p}/${f}`);
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
	handle_marks();
	handle_notify_test();
	refresh_wan_device();
	sample_proxy();
	if (!iptv_fast()) igmp_poll();
	let sysres = sample_system();

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
				loss: r?.loss, rtt: r?.rtt, rtt_max: r?.rtt_max, jitter: r?.jitter, since: t.since
			});
			if (!r) continue;
			n_active++;
			let lv = target_level(r);
			if (lv == 'fail') n_fail++;
			if (lv != 'ok') push(reasons, { c: lv == 'fail' ? 'target_fail' : 'target_degraded', t: k, loss: r.loss, rtt: r.rtt, jitter: r.jitter, why: target_why(r) });
			level = worst(level, lv == 'fail' ? 'warn' : lv);
		}
		if (n_active > 0 && n_fail == n_active) level = 'fail';
		if (wan_down_since != null) push(reasons, { c: 'wan_down', since: wan_down_since });
		if (wansess.up === false) {
			level = 'fail';
			push(reasons, { c: 'wan_if_down', iface: cfg.wan.interface, since: wansess.since });
		}
		/* a DNS failure while pings work is worth a warning, during an outage it is noise */
		if (cfg.wan.dns && dns.state != 'ok' && wan_down_since == null) {
			level = worst(level, 'warn');
			push(reasons, { c: dns.state == 'fail' ? 'dns_fail' : 'dns_slow', ms: dns.res?.ms, since: dns.since });
		}

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
			tx_kbps: wd?.delta ? round(wd.delta.tx_bps / 1000, 0) : null,
			dns: cfg.wan.dns ? { host: cfg.wan.dns_host, server: cfg.wan.dns_server, state: dns.state, ok: dns.res?.ok, ms: dns.res?.ms } : null,
			session: (wansess.up != null) ? { up: wansess.up, uptime: wansess.uptime, ip: wansess.ip, proto: wansess.proto, reconnects: wansess.reconnects, since: wansess.since } : null };
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
	/* router load is a cause, not a fault of the connection: never red */
	if (sysres && sysres.level != 'ok') overall = worst(overall, 'warn');

	/* ---- history (skip the baseline tick without deltas) */
	let t = now();
	if (dt > 0) {
		let hv = { lvl: LEVEL[overall] };
		for (let x in (wan?.targets ?? [])) {
			hv[`rtt:${x.label}`] = x.rtt;
			hv[`loss:${x.label}`] = x.loss;
			hv[`jit:${x.label}`] = x.jitter;
		}
		if (wan?.dns) hv.dns = wan.dns.ms;
		if (sysres) {
			hv.cpu = sysres.cpu_max;
			hv.sirq = sysres.sirq_max;
		}
		if (iptv_res) {
			hv['iptv:kbps'] = iptv_res.kbps;
			/* lowest 1 s bitrate in this interval, so short freezes show on the chart */
			if (iptv_res.min != null) hv['iptv:min'] = iptv_res.min;
		}
		for (let d in devs) {
			let r = res[d.dev];
			hv[`err:${d.dev}`] = r.delta ? (r.delta.err + r.delta.crc) : null;
			hv[`drop:${d.dev}`] = r.delta ? r.delta.drop : null;
		}
		hist_add(history, t, hv, cfg.history);

		let mv = { ...hv };
		for (let x in (wan?.targets ?? [])) mv[`rttmax:${x.label}`] = x.rtt;
		if (iptv_res) mv['iptv:min'] = iptv_res.min ?? iptv_res.kbps;
		agg_add(t, mv);

		/* ---- CSV */
		let tlist = cfg.wan.enabled ? map(wan_targets(), (x) => ({ label: x.label, t: targets[x.label] ?? {} })) : [];
		let cols = csv_columns(devs, tlist);
		if (join(',', cols) != csv_header) csv_open(cols);

		let row = [ tstamp(t), overall ];
		for (let x in tlist) push(row, x.t.res?.loss, x.t.res?.rtt, x.t.res?.jitter);
		if (cfg.wan.enabled && cfg.wan.dns) push(row, dns.res?.ms);
		if (sysres) push(row, sysres.cpu, sysres.cpu_max, sysres.sirq_max, sysres.mem_pct, sysres.ct);
		if (cfg.iptv.enabled && cfg.iptv.device) push(row, iptv_res?.state, iptv_res?.kbps, iptv_res?.min, iptv_res?.stall_s, iptv_res?.pps);
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
		system: sysres,
		counts: { h1: count_events(t - 3600), h24: count_events(t - 86400) },
		history,
		csv_rows,
		persist: cfg.persist_dir ? { dir: cfg.persist_dir, ok: persist_path() != null, last: persist_last } : null,
		notify: cfg.notify.enabled ? { service: cfg.notify.service, pending: length(notif.pending),
			last_ok: notif.last_ok, last_fail: notif.last_fail, last_err: notif.last_err, fetch: FETCH != null } : null
	};
	write_atomic(`${RUNDIR}/state.json`, sprintf('%J', state));

	if (cfg.persist_dir && t - persist_last >= cfg.persist_interval)
		persist_save();
	notify_flush(false);

	/* kick off pings for the next tick (results are used asynchronously) */
	start_pings();
	start_dns();
}

/* ------------------------------------------------------------------ main */

fs.mkdir(RUNDIR);
let restored = persist_restore();

let old;
try { old = json(fs.readfile(`${RUNDIR}/events.json`) || '[]'); } catch (e) { old = null; }
if (type(old) == 'array') events = old;
if (restored) emit('info', 'system', 'collector', 'restored', { dir: cfg.persist_dir, n: length(events) });

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

emit('info', 'system', 'collector', 'monitor_start', { interval: cfg.interval, iptv_interval: iptv_fast() ? cfg.iptv.sample_interval : null });

uloop.init();
refresh_wan_device();
start_pings();
start_dns();

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

let iptv_timer;
if (iptv_fast()) {
	iptv_fast_sample();
	iptv_timer = uloop.timer(int(cfg.iptv.sample_interval * 1000), () => {
		iptv_timer.set(int(cfg.iptv.sample_interval * 1000));
		try {
			iptv_fast_sample();
		}
		catch (e) {
			warn(`isp-tester: iptv sample failed: ${e}\n`);
		}
	});
}

uloop.run();
