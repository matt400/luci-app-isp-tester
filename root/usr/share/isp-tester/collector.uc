#!/usr/bin/ucode
/*
 * luci-app-isp-tester - collector daemon
 *
 * Periodically samples:
 * Takes its data from what OpenWrt already provides and does not measure
 * anything itself that the system measures already:
 *   - ping loss / latency / jitter: collectd ping plugin (luci-app-statistics),
 *     live through the unixsock plugin or from the RRD files
 *   - WAN session: netifd (ubus network.interface.<wan> status)
 *   - interface counters / link state: /sys/class/net
 *   - IGMP groups: /proc/net/igmp, multicast proxy from /proc, bridge MDB
 *   - router load: /proc (only to explain problems, no graphs)
 *   - system log (logread): pppd, udhcpc, igmpproxy, kernel, dnsmasq messages
 * The IPTV bitrate is the one own measurement: read from the interface
 * counters every second, which nothing in OpenWrt does. When the IPTV VLAN
 * is only bridged (no eth1.236 / br-lan.236 device on the router), it is read
 * from the bridge's per-VLAN counters instead (`bridge -s vlan`), and the
 * channels from the bridge's multicast database (`bridge mdb`).
 *
 * It turns state changes into events:
 *   <RUNDIR>/events.json   - event timeline (ring buffer)
 *   <RUNDIR>/history.json  - 24 h of 1-minute aggregates
 *   <RUNDIR>/samples.csv   - one row per tick (ring buffer, for export)
 *   <RUNDIR>/channels.json - IPTV channel names found in the streams (SDT)
 *   <VARDIR>/state.json    - current health + last hour for the charts (rpcd)
 * RUNDIR is in RAM unless the init script links it to a folder on USB.
 *
 * Environment overrides (used for testing off-device):
 *   ISP_TESTER_RUNDIR, ISP_TESTER_VARDIR, ISP_TESTER_SYSNET, ISP_TESTER_CONFIG
 *   (JSON file instead of UCI), ISP_TESTER_ROUTE (/proc/net/route path),
 *   ISP_TESTER_PROC (/proc), ISP_TESTER_WANSTATUS, ISP_TESTER_LOGREAD,
 *   ISP_TESTER_FETCH, ISP_TESTER_BRIDGE, ISP_TESTER_RRDTOOL
 */
'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';

const RUNDIR = getenv('ISP_TESTER_RUNDIR') || '/tmp/isp-tester';
const VARDIR = getenv('ISP_TESTER_VARDIR') || '/var/run/isp-tester';
const SYSNET = getenv('ISP_TESTER_SYSNET') || '/sys/class/net';
const ROUTE = getenv('ISP_TESTER_ROUTE') || '/proc/net/route';
const PROC = getenv('ISP_TESTER_PROC') || '/proc';

function find_bin(env, names) {
	let e = getenv(env);
	if (e) return e;
	for (let n in names)
		if (fs.stat(n)) return n;
	return null;
}

const FETCH = find_bin('ISP_TESTER_FETCH', [ '/bin/uclient-fetch', '/usr/bin/uclient-fetch', '/usr/bin/wget', '/bin/wget' ]);
const LOGREAD = find_bin('ISP_TESTER_LOGREAD', [ '/sbin/logread', '/usr/sbin/logread' ]);
const RRDTOOL = find_bin('ISP_TESTER_RRDTOOL', [ '/usr/bin/rrdtool' ]);
const BRIDGE = find_bin('ISP_TESTER_BRIDGE', [ '/usr/sbin/bridge', '/sbin/bridge' ]);
const PROXIES = [ 'igmpproxy', 'mcproxy', 'omcproxy', 'improxy' ];
/* picture quality scan (optional, needs tcpdump): capture + tsscan.uc */
const TCPDUMP = find_bin('ISP_TESTER_TCPDUMP', [ '/usr/sbin/tcpdump', '/usr/bin/tcpdump' ]);
const UCODE = find_bin('ISP_TESTER_UCODE', [ '/usr/bin/ucode' ]);
const TSSCAN = getenv('ISP_TESTER_TSSCAN') || '/usr/share/isp-tester/tsscan.uc';

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

/* IPv4 multicast group (224-239.x.x.x), safe to put into a capture filter */
function valid_group(g) {
	let m = match(`${g ?? ''}`, /^(22[4-9]|23[0-9])\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/);
	return !!m && +m[2] <= 255 && +m[3] <= 255 && +m[4] <= 255;
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
		logread: true,
		wan: {
			enabled: true, interface: 'wan', device: '', gateway: '',
			loss_warn: 1, loss_fail: 50, rtt_warn: 80, jitter_warn: 0,
			collectd_socket: '', rrd_dir: ''
		},
		iptv: {
			enabled: true, vlan: 0, upstream: '', device: '', direction: 'rx', bridge: '',
			min_kbps: 500, idle_after: 60, off_after: 15, dip_pct: 40,
			sample_interval: 1, stall_after: 2,
			igmp: true, igmp_device: '',
			quality: false, q_window: 5, q_interval: 60, q_warn: 1, q_fail: 30, q_gap: 500,
			names: true, channels: {}
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

		c.logread     = bool(g.logread, true);

		c.wan.jitter_warn = num(w.jitter_warn, c.wan.jitter_warn);
		c.wan.gateway     = w.gateway ?? '';

		/* where luci-app-statistics keeps collectd's data */
		let us = cur.get_all('luci_statistics', 'collectd_unixsock') || {};
		let rr = cur.get_all('luci_statistics', 'collectd_rrdtool') || {};
		let pg = cur.get_all('luci_statistics', 'collectd_ping') || {};
		c.wan.collectd_socket = w.collectd_socket || (bool(us.enable, false) ? (us.SocketFile ?? '') : '');
		c.wan.rrd_dir = w.rrd_dir || rr.DataDir || '/tmp/rrd';
		c.wan.ping_plugin = bool(pg.enable, false);
		c.wan.ping_hosts = aslist(pg.Hosts);

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
		c.wan.loss_warn = num(w.loss_warn, c.wan.loss_warn);
		c.wan.loss_fail = num(w.loss_fail, c.wan.loss_fail);
		c.wan.rtt_warn  = num(w.rtt_warn, c.wan.rtt_warn);

		c.iptv.enabled    = bool(t.enabled, true);
		c.iptv.vlan       = num(t.vlan, 0);
		c.iptv.upstream   = t.upstream ?? '';
		c.iptv.device     = t.device ?? '';
		c.iptv.direction  = (t.direction == 'tx') ? 'tx' : 'rx';
		c.iptv.bridge     = t.bridge ?? '';
		c.iptv.min_kbps   = num(t.min_kbps, c.iptv.min_kbps);
		c.iptv.idle_after = num(t.idle_after, c.iptv.idle_after);
		c.iptv.off_after  = num(t.off_after, c.iptv.off_after);
		c.iptv.dip_pct    = num(t.dip_pct, c.iptv.dip_pct);
		c.iptv.sample_interval = num(t.sample_interval, c.iptv.sample_interval);
		c.iptv.stall_after = num(t.stall_after, c.iptv.stall_after);
		c.iptv.quality    = bool(t.quality, false);
		c.iptv.q_window   = num(t.q_window, c.iptv.q_window);
		c.iptv.q_interval = num(t.q_interval, c.iptv.q_interval);
		c.iptv.q_warn     = num(t.q_warn, c.iptv.q_warn);
		c.iptv.q_fail     = num(t.q_fail, c.iptv.q_fail);
		c.iptv.q_gap      = num(t.q_gap, c.iptv.q_gap);
		c.iptv.names      = bool(t.names, true);

		/* channel names set by hand (they win over the names in the stream) */
		cur.foreach('isp_tester', 'channel', (s) => {
			if (s.group && s.name) c.iptv.channels[trim(s.group)] = s.name;
		});

		cur.foreach('isp_tester', 'port', (s) => {
			if (bool(s.enabled, true) && s.device)
				push(c.ports, { device: s.device, label: s.label ?? '', expect_up: bool(s.expect_up, true) });
		});

	}

	if (c.interval < 2) c.interval = 2;
	if (c.wan.gateway && !valid_host(c.wan.gateway)) c.wan.gateway = '';
	if (!match(c.wan.collectd_socket ?? '', /^\/[A-Za-z0-9._\/-]+$/)) c.wan.collectd_socket = '';
	if (!match(c.wan.rrd_dir ?? '', /^\/[A-Za-z0-9._\/-]+$/)) c.wan.rrd_dir = '/tmp/rrd';
	c.ports = filter(c.ports, (p) => valid_dev(p.device));
	if (c.wan.device && !valid_dev(c.wan.device)) c.wan.device = '';
	/* WAN L3 device is resolved via ubus on every tick unless set explicitly */
	c.wan.auto_device = !c.wan.device && !!c.wan.interface;
	if (c.iptv.device && !valid_dev(c.iptv.device)) c.iptv.device = '';
	if (c.iptv.bridge && !valid_dev(c.iptv.bridge)) c.iptv.bridge = '';
	if (c.iptv.upstream && !valid_dev(c.iptv.upstream)) c.iptv.upstream = '';
	c.iptv.vlan = int(c.iptv.vlan);
	if (c.iptv.vlan < 1 || c.iptv.vlan > 4094) c.iptv.vlan = 0;
	/* VLAN mode: the VLAN number replaces the device; the counters come from
	 * the bridge, read on the fast timer only */
	if (c.iptv.vlan) {
		c.iptv.device = '';
		c.iptv.direction = 'rx';
		c.iptv.igmp_device = '';
		if (!(c.iptv.sample_interval > 0)) c.iptv.sample_interval = 1;
	}
	/* 0 (or >= interval) = sample IPTV only on the main tick, like before */
	if (c.iptv.sample_interval < 0) c.iptv.sample_interval = 0;
	if (c.iptv.sample_interval > 0 && c.iptv.sample_interval < 0.5) c.iptv.sample_interval = 0.5;
	if (c.iptv.sample_interval >= c.interval)
		/* VLAN mode has no per-tick fallback: the counters are read by the fast timer only */
		c.iptv.sample_interval = c.iptv.vlan ? c.interval / 2 : 0;
	if (c.iptv.stall_after < 0) c.iptv.stall_after = 0;
	/* picture quality scan: short captures, so keep them short and rare */
	c.iptv.q_window = int(c.iptv.q_window);
	if (c.iptv.q_window < 2) c.iptv.q_window = 2;
	if (c.iptv.q_window > 15) c.iptv.q_window = 15;
	c.iptv.q_interval = int(c.iptv.q_interval);
	if (c.iptv.q_interval < c.iptv.q_window + 10) c.iptv.q_interval = c.iptv.q_window + 10;
	if (c.iptv.q_interval > 3600) c.iptv.q_interval = 3600;
	if (c.iptv.q_warn < 1) c.iptv.q_warn = 1;
	if (c.iptv.q_fail < c.iptv.q_warn) c.iptv.q_fail = c.iptv.q_warn;
	if (c.iptv.q_gap < 0) c.iptv.q_gap = 0;
	if (c.iptv.igmp_device && !valid_dev(c.iptv.igmp_device)) c.iptv.igmp_device = '';
	let chs = {};
	for (let g, n in (type(c.iptv.channels) == 'object' ? c.iptv.channels : {})) {
		n = trim(replace(`${n}`, /[[:cntrl:]]+/g, ' '));
		if (valid_group(g) && n != '') chs[g] = substr(n, 0, 64);
	}
	c.iptv.channels = chs;
	/* IGMP memberships are joined by the multicast proxy on its upstream, which
	 * is the IPTV VLAN when the bitrate is measured there */
	c.iptv.igmp_dev = c.iptv.igmp_device || (c.iptv.direction == 'rx' ? c.iptv.device : '');
	if (c.notify.cooldown < 30) c.notify.cooldown = 30;

	return c;
}

/* ------------------------------------------------------------------ state */

let cfg = load_config();
let events = [];
let history = { t: [], s: {} };
let history_min = { t: [], s: {} };
let devstate = {};      /* dev -> { prev, link, since, err_acc, drop_acc, last_err_ev, ... } */
let targets = {};       /* collectd ping host -> { host, label, state, since, res, last_ts, active } */
let source = { type: null, error: null };
let wan_down_since = null;
let iptv = {
	state: 'idle', since: now(), kbps: 0, pps: 0, avg: null, dip: false,
	stall_since: null, stall_m: null,       /* wall / monotonic start of the current stall */
	low_w: null, low_m: null,               /* start of a below-threshold run not yet long enough */
	held: false, hold_def: 0,               /* stop while nobody is subscribed: decoder off or freeze? */
	prev: null, prev_m: null, prev_w: null, /* last counter reading (fast sampler) */
	acc: null                               /* per-tick aggregate of the fast samples */
};
let csv_rows = 0;
let csv_header = null;
let last_mono = null;
let started = now();
let wansess = { up: null, uptime: null, seen: null, ip: null, since: now(), reconnects: 0 };
/* bridged IPTV VLAN (see vlan_sample) */
let vl = { bridge: null, upstream: null, ports: [], stats: null, mdb: null, error: null, cnt: null };
/* joined = group -> when it was joined (0 = already there at start) */
let igmp = { groups: null, joined: {}, hist: [], proxy: null, proxy_seen: false, proxy_since: now() };
/* picture quality scan: proc = running capture, next = earliest next start,
 * boost = windows still to run back-to-back after errors, pend = errors from
 * windows whose event was held back by the cooldown, cc_acc = errors since
 * the last tick (for the history chart) */
let tsq = { proc: null, wd: null, next: 0, boost: 0, last: null, recent: [], err: null,
	pend: null, last_ev: 0, cc_acc: null, windows: 0 };
/* channel names: db = group -> { name, provider, sid, ts } learned from the
 * streams (or { name: null, tries, last_try } while not found), proc = a
 * running name capture, grp = the group it is for */
let chn = { db: {}, proc: null, wd: null, grp: null, next: 0, err: null };
let sys = { prev: null, cpu_n: 0, cpu: false, mem: false, ct: false, cpu_since: 0, mem_since: 0, ct_since: 0 };
let notif = { pending: [], last: 0, busy: false, last_ok: null, last_fail: null, last_err: null, open: {} };
let logst = { last_ts: null, last_lines: {}, kinds: {} };
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
		log: '%s: %s',
		stream_stall: 'IPTV STREAM STOPPED', stream_resume: 'IPTV stream resumed after %s', stream_lost: 'IPTV stream did not come back within %s', stream_off: 'IPTV stream ended: decoder switched off (no channel subscribed)',
		stream_dip: 'IPTV bitrate dropped to %d kbit/s',
		ts_errors: 'IPTV picture errors: %d lost-packet gaps (~%d packets) in %ss, channel %s',
		proxy_down: 'Multicast proxy %s is not running', proxy_up: 'Multicast proxy %s running again', proxy_restart: 'Multicast proxy %s restarted',
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
		log: '%s: %s',
		stream_stall: 'STRUMIEŃ IPTV ZATRZYMANY', stream_resume: 'Strumień IPTV wrócił po %s', stream_lost: 'Strumień IPTV nie wrócił w ciągu %s', stream_off: 'Strumień IPTV zakończony: dekoder wyłączony (brak subskrybowanego kanału)',
		stream_dip: 'Bitrate IPTV spadł do %d kbit/s',
		ts_errors: 'Błędy obrazu IPTV: %d przerw w pakietach (~%d pakietów) w %ss, kanał %s',
		proxy_down: 'Proxy multicast %s nie działa', proxy_up: 'Proxy multicast %s znów działa', proxy_restart: 'Proxy multicast %s zrestartowany',
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

function event_text(e, lang) {
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
	case 'wan_up': case 'stream_resume': case 'stream_lost': return sprintf(f, dur_txt(d.dur));
	case 'wan_if_down': return sprintf(f, d.iface);
	case 'wan_if_up': return sprintf(f, d.iface, dur_txt(d.dur));
	case 'wan_reconnect': return sprintf(f, dur_txt(d.prev));
	case 'wan_ip_change': return sprintf(f, d.from, d.to);
	case 'log': return sprintf(f, d.prog, d.msg) + ((d.n > 1) ? ` (${d.n}x)` : '');
	case 'stream_dip': return sprintf(f, d.kbps);
	case 'ts_errors': return sprintf(f, d.cc, d.lost, d.win, d.ch ? `${d.ch} (${d.grp})` : (d.grp ?? '?'));
	case 'proxy_down': case 'proxy_up': case 'proxy_restart': return sprintf(f, d.name);
	case 'cpu_high': return sprintf(f, d.cpu, d.sirq);
	case 'mem_low': return sprintf(f, d.pct);
	case 'conntrack_full': return sprintf(f, d.pct);
	case 'user_mark': return sprintf(f, d.note || '-');
	default: return f;
	}
}

function event_msg(e, lang) {
	let s = event_text(e, lang), d = e.d ?? {};
	/* the channel(s) being watched, when known */
	if (e.area == 'iptv' && d.ch && e.type != 'ts_errors') s += ` [${d.ch}]`;
	return s;
}

/* ------------------------------------------------------------------ notify */

/* recoveries are sent too, so a "down" message is always followed by "back";
 * only when the fault itself was sent (same area + source), so e.g. a decoder
 * port coming up or a target recovering from an unsent warning stays quiet */
const RECOVERY = { wan_up: true, stream_resume: true, stream_lost: true, stream_off: true, link_up: true,
	wan_if_up: true, proxy_up: true, target_ok: true, dev_present: true };

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
	if (!n.enabled) return;
	let key = `${e.area}|${e.src}`;
	let want;
	if (RECOVERY[e.type]) {
		want = notif.open[key] == true;
		delete notif.open[key];
	}
	else {
		want = (e.lvl == 'err') || (e.lvl == 'warn' && n.min_level == 'warn');
		if (want) notif.open[key] = true;
	}
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
	let url, body, extra = [];

	if (n.service == 'telegram') {
		if (!n.token || !n.chat_id) return;
		url = `https://api.telegram.org/bot${n.token}/sendMessage`;
		body = `chat_id=${urlenc(n.chat_id)}&text=${urlenc(text)}`;
	}
	else if (n.service == 'webhook') {
		url = n.url;
		body = sprintf('%J', { text, host: HOSTNAME, events: notif.pending });
		/* without it the receiver gets the JSON as a form-encoded body */
		push(extra, '--header=Content-Type: application/json');
	}
	else {
		url = n.url;
		body = text;
	}
	if (!match(url ?? '', /^https?:\/\/[^ \t\n]+$/)) return;

	notif.busy = true;
	notif.last = now();
	let proc = uloop.process(FETCH, [ '-q', '-T', '15', '-O', '/dev/null', ...extra, `--post-data=${body}`, url ], null, (code) => {
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
const AGG_MODE = { rtt: 'avg', rttmax: 'max', loss: 'max', jit: 'max',
	'iptv:kbps': 'avg', 'iptv:min': 'min', 'iptv:cc': 'sum', err: 'sum', drop: 'sum', lvl: 'max' };

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
	if (cfg.iptv.enabled && cfg.iptv.vlan) {
		/* the bridge ports of the IPTV VLAN: upstream must be up, the
		 * decoder-side ports are reported but may be unplugged */
		add(vl.upstream, 'iptv', sprintf('IPTV %d (ISP)', cfg.iptv.vlan), true);
		for (let p in vl.ports)
			if (p != vl.upstream) add(p, 'iptv', sprintf('IPTV %d', cfg.iptv.vlan), false);
	}

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
			/* a port that may be unplugged (decoder switched on) coming up is not a problem */
			if (cur.up)
				emit(m.expect_up ? 'warn' : 'info', m.area, m.dev, 'link_up', { dev: m.dev, speed: cur.speed, dur: now() - ds.since });
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

/* ------------------------------------------------- ping data from collectd */

/*
 * The collectd ping plugin (luci-app-statistics) pings the configured hosts
 * once a second and reports per collectd interval: average RTT (ping),
 * lost fraction (ping_droprate) and RTT standard deviation (ping_stddev).
 * Live values come from the unixsock plugin; without it the RRD files are
 * read, which lag behind by the rrdtool cache time.
 */

function cd_parse_val(v) {
	v = trim(v ?? '');
	if (v == '' || match(v, /^-?nan$/i) || v == 'U') return null;
	let n = +v;
	return (n != n) ? null : n;
}

function cd_unixsock(path) {
	let socket;
	try { socket = require('socket'); } catch (e) { return { error: 'no_socket_module' }; }

	let sk = socket.create(socket.AF_UNIX, socket.SOCK_STREAM);
	if (!sk) return { error: 'socket' };
	try { sk.setopt(socket.SOL_SOCKET, socket.SO_RCVTIMEO, { tv_sec: 2, tv_usec: 0 }); } catch (e) {}
	if (!sk.connect({ family: socket.AF_UNIX, path })) {
		sk.close();
		return { error: 'connect' };
	}

	let buf = '';
	/* one command, answer: "<n> <text>\n" followed by n lines */
	let query = (cmd) => {
		sk.send(cmd + '\n');
		let lines = null, need = null;
		for (let tries = 0; tries < 200; tries++) {
			let nl = index(buf, '\n');
			while (nl >= 0) {
				let line = substr(buf, 0, nl);
				buf = substr(buf, nl + 1);
				if (lines == null) {
					need = +split(line, ' ')[0];
					lines = [];
					if (!(need > 0)) return [];
				}
				else push(lines, line);
				if (length(lines) >= need) return lines;
				nl = index(buf, '\n');
			}
			let chunk = sk.recv(4096);
			if (chunk == null || chunk == '') return lines ?? [];
			buf += chunk;
		}
		return lines ?? [];
	};

	let out = {};
	for (let line in query('LISTVAL')) {
		/* "<time> <host>/ping/ping_droprate-1.1.1.1" */
		let m = match(line, /^([0-9.]+) [^\/]+\/ping\/(ping|ping_droprate|ping_stddev)-(.+)$/);
		if (!m) continue;
		let ident = substr(line, index(line, ' ') + 1);
		let val = null;
		for (let r in query(`GETVAL "${ident}"`)) {
			let v = match(r, /^value=(.*)$/);
			if (v) val = cd_parse_val(v[1]);
		}
		let h = out[m[3]] ??= { ts: 0 };
		h[m[2]] = val;
		if (+m[1] > h.ts) h.ts = int(+m[1]);
	}
	sk.close();
	return { hosts: out };
}

function rrd_last(file) {
	let f = fs.popen(`${RRDTOOL} lastupdate '${file}' 2>/dev/null`, 'r');
	if (!f) return null;
	let out = f.read('all');
	f.close();
	let m = match(out ?? '', /([0-9]+): *([^ \n]+)[ \n]*$/);
	return m ? { ts: +m[1], v: cd_parse_val(m[2]) } : null;
}

function cd_rrd(dir) {
	if (!RRDTOOL) return { error: 'no_rrdtool' };
	let out = {};
	for (let host in (fs.lsdir(dir) ?? [])) {
		if (!valid_host(host)) continue;     /* the path goes into a shell command */
		let pdir = `${dir}/${host}/ping`;
		for (let f in (fs.lsdir(pdir) ?? [])) {
			let m = match(f, /^(ping|ping_droprate|ping_stddev)-(.+)\.rrd$/);
			if (!m || !match(m[2], /^[A-Za-z0-9.:_-]+$/)) continue;
			let r = rrd_last(`${pdir}/${f}`);
			if (!r) continue;
			let h = out[m[2]] ??= { ts: 0 };
			h[m[1]] = r.v;
			if (r.ts > h.ts) h.ts = r.ts;
		}
	}
	return { hosts: out };
}

function collectd_ping() {
	let w = cfg.wan;
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
	return cfg.wan.gateway || cfg.wan.gw || default_gateway(cfg.wan.device) || default_gateway(null);
}

function sample_pings() {
	if (!cfg.wan.enabled) return;
	let r = collectd_ping();
	source.type = r.type;
	source.error = r.error;
	source.ping_plugin = cfg.wan.ping_plugin;
	if (!r.hosts) {
		for (let k, t in targets) t.active = false;
		return;
	}

	let gw = gateway_ip(), t_now = now();
	let seen = {};
	for (let host, v in r.hosts) {
		if (!valid_host(host)) continue;
		seen[host] = true;
		let t = targets[host] ??= { host, state: 'ok', since: t_now, res: null, last_ts: null };
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
			if (lvl == 'ok')
				emit('info', 'wan', t.label, 'target_ok', { host, dur: t_now - t.since, loss: res.loss, rtt: res.rtt });
			else
				emit(lvl == 'fail' ? 'err' : 'warn', 'wan', t.label, lvl == 'fail' ? 'target_fail' : 'target_degraded',
					{ host, loss: res.loss, rtt: res.rtt, jitter: res.jitter, why: target_why(res) }, v.ts);
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

	/* the address is printed in host byte order. Every IGMP device has joined
	 * 224.0.0.1 (all hosts), which tells little-endian (010000E0) from
	 * big-endian (E0000001, e.g. ath79) */
	let le = null;
	if (match(data, /[ \t]010000E0[ \t]/)) le = true;
	else if (match(data, /[ \t]E0000001[ \t]/)) le = false;

	let cur = null, out = { found: false, ver: null, groups: [] };
	for (let line in split(data, '\n')) {
		let f = split(trim(line), /\s+/);
		if (!length(f) || f[0] == '' || f[0] == 'Idx') continue;
		if (match(f[0], /^[0-9]+$/) && length(f) >= 2) {
			/* "%-10s:" - a name of 10+ characters (br-lan.236) has the colon attached */
			cur = replace(f[1], /:$/, '');
			if (cur == dev) {
				out.found = true;
				let v = f[length(f) - 1];
				out.ver = match(v, /^V[123]$/) ? v : null;
			}
			continue;
		}
		if (cur != dev || !match(f[0], /^[0-9A-Fa-f]{8}$/)) continue;

		let g = hex(f[0]), lo = g & 255;
		let rev = (le != null) ? le : (lo >= 224 && lo <= 239);
		let ip = rev
			? sprintf('%d.%d.%d.%d', lo, (g >> 8) & 255, (g >> 16) & 255, (g >> 24) & 255)
			: sprintf('%d.%d.%d.%d', (g >> 24) & 255, (g >> 16) & 255, (g >> 8) & 255, g & 255);
		if (match(ip, /^224\.0\.0\./) || ip == '239.255.255.250') continue;   /* link-local, SSDP */
		push(out.groups, ip);
	}
	return out;
}

function igmp_poll() {
	if (!cfg.iptv.enabled || !cfg.iptv.igmp) return;
	let g;
	if (cfg.iptv.vlan) {
		/* bridged VLAN: the channels are the groups the bridge forwards on it */
		if (vl.mdb == null) return;
		let seen = {};
		g = { found: true, ver: null, groups: [] };
		for (let e in vl.mdb)
			if (!seen[e.grp]) { seen[e.grp] = true; push(g.groups, e.grp); }
	}
	else {
		if (!cfg.iptv.igmp_dev) return;
		g = igmp_groups(cfg.iptv.igmp_dev);
	}
	if (!g) return;

	igmp.found = g.found;
	igmp.version = g.ver;
	let cur = sort(g.groups);
	if (igmp.groups != null && join(',', cur) != join(',', igmp.groups)) {
		igmp.last_change = now();
		push(igmp.hist, { ts: now(), before: igmp.groups, after: cur });
		if (length(igmp.hist) > 20) igmp.hist = slice(igmp.hist, -20);
	}
	if (length(cur)) igmp.seen = true;
	let j = {};
	for (let x in cur) j[x] = igmp.joined[x] ?? (igmp.groups == null ? 0 : now());
	igmp.joined = j;
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
	if (!cfg.iptv.igmp || !(cfg.iptv.igmp_dev || cfg.iptv.vlan) || igmp.groups == null) return null;
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
			push(list, { grp: e.grp, port: e.port, state: e.state, vid: e.vid });
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

/* ------------------------------------------------------------ user marks */

/* "problem now" reports from the web UI (appended by rpcd) */
function handle_marks() {
	let f = `${VARDIR}/marks.pending`, work = `${VARDIR}/marks.work`;
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
	let f = `${VARDIR}/notify_test`;
	if (!fs.stat(f)) return;
	fs.unlink(f);
	/* notifications off: do not leave a test message queued for later */
	if (!cfg.notify.enabled) return;
	push(notif.pending, (MSG[cfg.notify.lang] ?? MSG.en).test);
	notify_flush(true);
}

/* ------------------------------------------------------------ system log */

/*
 * Messages from other OpenWrt services that explain a fault. Each entry:
 * program regex, message regex, kind, level, area.
 */
const LOG_RULES = [
	[ /^pppd$/, /No response to [0-9]+ echo-requests|Serial link appears to be disconnected/, 'ppp_echo', 'warn', 'wan' ],
	[ /^pppd$/, /authentication failed/i, 'ppp_auth', 'err', 'wan' ],
	[ /^pppd$/, /Timeout waiting for PAD[OS]|Unable to complete PPPoE Discovery/, 'ppp_discovery', 'err', 'wan' ],
	[ /^pppd$/, /LCP terminated by peer|Modem hangup|Connection terminated/, 'ppp_down', 'warn', 'wan' ],
	[ /^udhcpc$/, /no lease, failing|lease lost/, 'dhcp_fail', 'warn', 'wan' ],
	[ /^odhcp6c$/, /Failed to send|timed out/, 'dhcp_fail', 'warn', 'wan' ],
	[ /^(igmpproxy|mcproxy|omcproxy|improxy)$/, /(error|fail|cannot|unable|invalid)/i, 'proxy_log', 'warn', 'iptv' ],
	[ /^kernel$/, /NETDEV WATCHDOG|transmit queue [0-9]+ timed out|[Tt][Xx] timeout/, 'nic_timeout', 'err', 'system' ],
	[ /^kernel$/, /nf_conntrack: table full/, 'conntrack_drop', 'warn', 'system' ],
	[ /^kernel$/, /Out of memory|oom-kill|invoked oom-killer/, 'oom', 'err', 'system' ],
	[ /^dnsmasq$/, /Maximum number of concurrent DNS queries reached/, 'dns_limit', 'warn', 'system' ]
];

const MONTHS = { Jan: 1, Feb: 2, Mar: 3, Apr: 4, May: 5, Jun: 6, Jul: 7, Aug: 8, Sep: 9, Oct: 10, Nov: 11, Dec: 12 };

/* "Thu Nov 19 16:41:01 2026 daemon.notice pppd[1234]: message" */
function parse_log_line(line) {
	let m = match(line, /^[A-Z][a-z][a-z] ([A-Z][a-z][a-z]) +([0-9]+) ([0-9]+):([0-9]+):([0-9]+) ([0-9]+) ([a-z0-9]+)\.([a-z]+) ([^ :]+): (.*)$/);
	if (!m || !MONTHS[m[1]]) return null;
	let prog = replace(m[9], /\[[0-9]+\]$/, '');
	let ts = timelocal({ year: +m[6], mon: MONTHS[m[1]], mday: +m[2], hour: +m[3], min: +m[4], sec: +m[5] });
	/* kernel lines start with the uptime stamp: "[12345.678901] " */
	return { ts, prio: m[8], prog, msg: replace(m[10], /^\[ *[0-9.]+\] /, '') };
}

function log_emit(k) {
	let st = logst.kinds[k];
	emit(st.lvl, st.area, k, 'log', { kind: k, prog: st.prog, msg: substr(st.msg, 0, 160), n: st.n }, st.ts);
	st.n = 0;
	st.last = now();
}

function read_log() {
	if (!cfg.logread || !LOGREAD) return;
	let f = fs.popen(`${LOGREAD} -l 300 2>/dev/null`, 'r');
	if (!f) return;
	let data = f.read('all') ?? '';
	f.close();

	let first = (logst.last_ts == null);
	let prev_ts = logst.last_ts ?? 0, prev_lines = logst.last_lines;
	let max_ts = prev_ts, last_lines = {};
	if (first) last_lines = {};
	else for (let k in keys(prev_lines)) last_lines[k] = true;

	for (let line in split(data, '\n')) {
		let l = parse_log_line(line);
		if (!l) continue;
		/* skip lines already seen: older seconds, or the same text in the last second */
		if (!first && (l.ts < prev_ts || (l.ts == prev_ts && prev_lines[line]))) continue;
		if (l.ts > max_ts) { max_ts = l.ts; last_lines = {}; }
		if (l.ts == max_ts) last_lines[line] = true;
		/* on start only remember where the log ends; old lines are history */
		if (first) continue;

		for (let r in LOG_RULES) {
			if (!match(l.prog, r[0]) || !match(l.msg, r[1])) continue;
			let k = r[2];
			let st = logst.kinds[k] ??= { n: 0, last: 0 };
			if (st.n == 0) {
				st.ts = l.ts;
				st.msg = l.msg;
				st.prog = l.prog;
				st.lvl = r[3];
				st.area = r[4];
			}
			st.n++;
			/* repeated messages: at most one event per cooldown, with a count */
			if (now() - st.last >= cfg.err_cooldown) log_emit(k);
			break;
		}
	}
	/* nothing readable at start (logd not up yet): only lines from now on are
	 * new, otherwise the next read would replay the whole buffer */
	if (first && max_ts == 0) max_ts = now();
	logst.last_ts = max_ts;
	logst.last_lines = last_lines;

	for (let k, st in logst.kinds)
		if (st.n > 0 && now() - st.last >= cfg.err_cooldown) log_emit(k);
}

/* ------------------------------------------------------------ IPTV VLAN */

/*
 * IPTV VLAN that is only bridged (eth1 -> br -> lan ports, the decoders get
 * their address from the ISP): there is no network device carrying only IPTV,
 * so the bitrate comes from the bridge's per-VLAN counters. The kernel keeps
 * them off by default; they are switched on here (bridge vlan_stats_enabled,
 * the same as `ip link set <br> type bridge vlan_stats_enabled 1`).
 * Unless vlan_stats_per_port is on, all ports show the same, VLAN-wide
 * counter: its RX is what entered the VLAN, i.e. the stream from the ISP.
 */

function base(path) {
	let p = split(path ?? '', '/');
	return p[length(p) - 1] || null;
}

/* the port the ISP is on: not a switch (DSA) port, not wireless */
function is_uplink(p) {
	return rd(p, 'ifindex') == rd(p, 'iflink') &&
		!fs.stat(`${SYSNET}/${p}/wireless`) && !fs.stat(`${SYSNET}/${p}/phy80211`);
}

function bridge_json(args) {
	let f = fs.popen(`${BRIDGE} -j ${args} 2>/dev/null`, 'r');
	if (!f) return null;
	let out = f.read('all');
	f.close();
	let j;
	try { j = json(out || 'null'); } catch (e) { return null; }
	return (type(j) == 'array') ? j : null;
}

function vlan_sample() {
	let vid = cfg.iptv.vlan;
	if (!BRIDGE) { vl.error = 'no_bridge_tool'; vl.cnt = null; return; }

	let j = bridge_json(`-s vlan show vid ${vid}`);
	if (j == null) { vl.error = 'bridge_failed'; vl.cnt = null; return; }

	let ports = [], st = {};
	for (let e in j) {
		if (!valid_dev(e?.ifname)) continue;
		for (let v in (e.vlans ?? [])) {
			/* with -s the VLAN is "vid", without it "vlan" (+ "vlanEnd") */
			let lo = v.vid ?? v.vlan, hi = v.vlanEnd ?? lo;
			if (vid < lo || vid > hi) continue;
			push(ports, e.ifname);
			st[e.ifname] = v;
		}
	}

	/* the bridge itself is listed when it is a member too (br.236 exists) */
	let br = cfg.iptv.bridge || null;
	if (!br)
		for (let p in ports) {
			let m = base(fs.readlink(`${SYSNET}/${p}/master`));
			if (m) { br = m; break; }
		}
	vl.bridge = br;
	vl.ports = filter(ports, (p) => p != br);
	/* routers where every port is a switch (DSA) port: the one named "wan" */
	vl.upstream = cfg.iptv.upstream || filter(vl.ports, is_uplink)[0] ||
		filter(vl.ports, (p) => match(p, /^wan/))[0] || null;

	if (!length(vl.ports)) { vl.error = 'vlan_not_found'; vl.cnt = null; return; }

	if (br) {
		let on = rd(br, 'bridge/vlan_stats_enabled');
		if (on == '0') {
			fs.writefile(`${SYSNET}/${br}/bridge/vlan_stats_enabled`, '1');
			on = rd(br, 'bridge/vlan_stats_enabled');
		}
		vl.stats = on;
	}

	/* upstream port's RX (equals the VLAN-wide counter unless per-port) */
	let s = vl.upstream ? st[vl.upstream] : null;
	if (!s || s.rx_bytes == null)
		for (let p in vl.ports)
			if (st[p]?.rx_bytes != null && (!s || st[p].rx_bytes > s.rx_bytes)) s = st[p];

	if (s?.rx_bytes == null) { vl.error = 'no_stats'; vl.cnt = null; }
	else { vl.error = (vl.stats == '0') ? 'stats_off' : null; vl.cnt = { b: s.rx_bytes, p: s.rx_packets ?? 0 }; }

	vl.mdb = (br && cfg.iptv.igmp)
		? filter(bridge_mdb(br) ?? [], (e) => e.vid == null || e.vid == vid)
		: null;
}

/* ------------------------------------------------------------------ IPTV */

/* state of the picture quality scan, for the status page (see tsq_poll) */
function tsq_out() {
	return { error: tsq.err, running: tsq.proc != null, window: cfg.iptv.q_window, interval: cfg.iptv.q_interval,
		warn: cfg.iptv.q_warn, fail: cfg.iptv.q_fail, windows: tsq.windows, last: tsq.last, recent: tsq.recent };
}

function iptv_on() {
	return cfg.iptv.enabled && (cfg.iptv.device || cfg.iptv.vlan);
}

function iptv_fast() {
	return iptv_on() && cfg.iptv.sample_interval > 0;
}

/* ------------------------------------------------- IPTV channel names */

/* where the IPTV multicast can be captured (also used by the quality scan) */
function tsq_target() {
	if (cfg.iptv.vlan) {
		if (!vl.upstream) return null;
		return { dev: vl.upstream,
			filter: `vlan ${cfg.iptv.vlan} and udp and ip multicast and not net 224.0.0.0/24` };
	}
	if (!cfg.iptv.device) return null;
	return { dev: cfg.iptv.device, filter: 'udp and ip multicast and not net 224.0.0.0/24' };
}

/*
 * The name of each channel is in the stream itself (DVB SDT table, read by
 * tsscan.uc). When a decoder joins a group whose name is not known yet, a
 * short capture of just that group is taken once (CHN_WIN s, same tcpdump +
 * tsscan.uc as the quality scan, never both at a time). The quality scan
 * refreshes the names too, for free. Names set by hand in the settings win.
 * Learned names are kept in RUNDIR, so with data_dir they survive a reboot.
 */
const CHN_WIN = 3;          /* SDT is repeated at least every 2 s */
const CHN_TRIES = 3;        /* captures without a name before giving up on a group */
const CHN_RETRY = 1800;     /* ... and the wait between them (s) */
const CHN_MAX = 500;        /* groups remembered */

function chn_load() {
	let j;
	try { j = json(fs.readfile(`${RUNDIR}/channels.json`) || '{}'); } catch (e) { j = null; }
	chn.db = {};
	if (type(j) == 'object')
		for (let g, e in j)
			if (valid_group(g) && type(e) == 'object') chn.db[g] = e;
}

function chn_save() {
	let ks = keys(chn.db);
	if (length(ks) > CHN_MAX) {
		/* forget the groups seen longest ago */
		sort(ks, (a, b) => (chn.db[a].ts ?? chn.db[a].last_try ?? 0) - (chn.db[b].ts ?? chn.db[b].last_try ?? 0));
		for (let i = 0; i < length(ks) - CHN_MAX; i++) delete chn.db[ks[i]];
	}
	write_atomic(`${RUNDIR}/channels.json`, sprintf('%J', chn.db));
}

function chn_name(grp) {
	return cfg.iptv.channels[grp] ?? chn.db[grp]?.name ?? null;
}

/* names (or groups, when not known) of the channels joined now, for events
 * and the CSV; null when nobody watches or IGMP is not followed */
function chn_now() {
	if (!length(igmp.groups ?? [])) return null;
	let out = [];
	for (let g in igmp.groups) {
		if (length(out) == 3) { push(out, '…'); break; }
		push(out, chn_name(g) ?? g);
	}
	return join(', ', out);
}

/*
 * The one channel being watched now (a group), null when it cannot be told.
 * Without an IGMP querier left groups stay joined for minutes, so the list
 * of joined groups is not the answer:
 *   1. a group joined after the last quality scan: the newest zap
 *   2. the group that carried the stream in a recent quality scan
 *   3. the newest join seen since the collector started
 *   4. the only joined group that may be a channel
 * Groups known to carry no TS (EPG / service data) are never picked.
 */
function chn_current() {
	let gs = igmp.groups ?? [];
	if (!length(gs)) return null;
	let notch = (g) => !cfg.iptv.channels[g] && !chn.db[g]?.name && chn.db[g]?.why == 'no_data';
	let newest = (after) => {
		let best = null;
		for (let g in gs) {
			let t = igmp.joined[g] ?? 0;
			if (t > after && !notch(g) && (best == null || t > igmp.joined[best])) best = g;
		}
		return best;
	};

	let last = tsq.last;
	let g = newest(last?.ts ?? 0);
	if (g) return g;

	if (last && now() - last.ts <= cfg.iptv.q_interval * 2 + 60) {
		let best = null;
		for (let e in (last.groups ?? []))
			if (index(gs, e.grp) >= 0 && (best == null || e.kbps > best.kbps)) best = e;
		if (best) return best.grp;
	}

	g = newest(0);
	if (g) return g;

	let c = filter(gs, (x) => !notch(x));
	return length(c) == 1 ? c[0] : null;
}

/* names found by a capture (tsscan.uc result groups) */
function chn_learn(groups) {
	let changed = false, t = now();
	for (let g in (groups ?? [])) {
		if (!valid_group(g?.grp) || !g.svc?.name) continue;
		let o = chn.db[g.grp], n = substr(`${g.svc.name}`, 0, 64);
		if (o?.name != n || o?.sid != g.svc.sid || t - (o?.ts ?? 0) > 3600) {
			chn.db[g.grp] = { name: n, provider: g.svc.provider ? substr(`${g.svc.provider}`, 0, 64) : null,
				sid: g.svc.sid, ts: t };
			changed = true;
		}
	}
	if (changed) chn_save();
}

/* next joined group that needs its name looked up */
function chn_pending() {
	let t = now();
	for (let g in (igmp.groups ?? [])) {
		if (!valid_group(g) || cfg.iptv.channels[g]) continue;
		let e = chn.db[g];
		if (!e) return g;
		if (e.name == null && (e.tries ?? 0) < CHN_TRIES && t - (e.last_try ?? 0) >= CHN_RETRY) return g;
	}
	return null;
}

function chn_done(grp, resfile) {
	chn.wd?.cancel();
	chn.wd = null;
	chn.proc = null;
	chn.grp = null;

	let r;
	try { r = json(fs.readfile(resfile) || 'null'); } catch (e) { r = null; }
	fs.unlink(resfile);
	let t = now();
	chn.next = t + 5;
	if (type(r?.groups) != 'array') { chn.err = 'scan_failed'; return; }
	chn.err = null;

	chn_learn(r.groups);
	if (chn.db[grp]?.name == null) {
		let g = filter(r.groups, (x) => x.grp == grp)[0];
		let o = chn.db[grp] ?? {};
		/* no data at all = not playing during the capture (e.g. zapped
		 * away): does not count, try again in a minute */
		chn.db[grp] = { name: null, tries: (o.tries ?? 0) + (g ? 1 : 0), last_try: g ? t : t - CHN_RETRY + 60,
			why: !g ? 'no_data' : (g.psi?.sdt ? 'no_service' : 'no_sdt') };
		chn_save();
	}
}

function chn_poll() {
	if (!cfg.iptv.names || !cfg.iptv.igmp || !iptv_on() || chn.proc || tsq.proc) return;
	if (!TCPDUMP) { chn.err = 'no_tcpdump'; return; }
	if (!UCODE || !fs.stat(TSSCAN)) { chn.err = 'no_scanner'; return; }
	if (iptv.state != 'playing' || iptv.held || iptv.kbps < cfg.iptv.min_kbps) return;
	if (now() < chn.next) return;
	let grp = chn_pending();
	if (!grp) return;
	let tg = tsq_target();
	if (!tg) return;

	let pcap = `${VARDIR}/chn.pcap`, res = `${VARDIR}/chn.json`;
	fs.unlink(res);
	fs.unlink(pcap);
	/* valid_group() keeps the filter free of shell characters */
	let cmd = `N=; command -v nice >/dev/null 2>&1 && N='nice -n 10'; ` +
		`$N ${TCPDUMP} -i ${tg.dev} -nn -q -s 0 -c ${CHN_WIN * 4000} -w ${pcap} '${tg.filter} and dst host ${grp}' 2>/dev/null & p=$!; ` +
		`sleep ${CHN_WIN}; kill $p 2>/dev/null; wait $p 2>/dev/null; ` +
		`exec $N ${UCODE} ${TSSCAN} ${pcap} ${res}`;

	chn.grp = grp;
	chn.proc = uloop.process('/bin/sh', [ '-c', cmd ], null, (code) => {
		try {
			chn_done(grp, res);
		}
		catch (e) {
			warn(`isp-tester: channel name lookup failed: ${e}\n`);
			chn.proc = null;
			chn.grp = null;
			chn.next = now() + 60;
		}
	});
	if (!chn.proc) { chn.grp = null; chn.next = now() + 60; return; }

	let pid = chn.proc.pid();
	chn.wd = uloop.timer((CHN_WIN + 30) * 1000, () => {
		if (chn.proc != null && chn.proc.pid() == pid)
			system([ '/bin/sh', '-c', `kill ${int(pid)} 2>/dev/null` ]);
	});
}

/* names for the groups shown on the status page */
function chn_out(o) {
	let want = {};
	for (let g in (igmp.groups ?? [])) want[g] = true;
	for (let e in (o.bridge?.mdb ?? [])) want[e.grp] = true;
	for (let e in (tsq.last?.groups ?? [])) want[e.grp] = true;
	let names = {};
	for (let g in want) {
		let man = cfg.iptv.channels[g], e = chn.db[g];
		if (man) names[g] = { name: man, src: 'manual' };
		else if (e?.name) names[g] = { name: e.name, provider: e.provider, src: 'sdt' };
		else if (e) names[g] = { name: null, why: e.why, tries: e.tries };
	}
	return { enabled: cfg.iptv.names && cfg.iptv.igmp, error: chn.err, busy: chn.grp, names };
}

/* request from the web UI: forget the learned names */
function handle_chn_forget() {
	let f = `${VARDIR}/channels_forget`;
	if (!fs.stat(f)) return;
	fs.unlink(f);
	chn.db = {};
	chn_save();
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

	/* picture quality scan: yellow for a while after errors, or when it cannot run */
	if (cfg.iptv.quality) {
		if (tsq.err == 'no_tcpdump' || tsq.err == 'no_scanner' || tsq.err == 'no_target') {
			level = worst(level, 'warn');
			push(reasons, { c: 'ts_' + tsq.err });
		}
		else if (recent_level('iptv', 'quality') != 'ok') {
			level = worst(level, 'warn');
			push(reasons, { c: 'ts_errors' });
		}
	}

	let o = {
		level, reasons, state: iptv.state, since: iptv.state == 'stalled' ? iptv.stall_since : iptv.since,
		kbps: iptv.kbps, pps: iptv.pps, avg: round(iptv.avg, 0),
		device: cfg.iptv.vlan ? sprintf('VLAN %d', cfg.iptv.vlan) : cfg.iptv.device,
		direction: cfg.iptv.direction, min_kbps: cfg.iptv.min_kbps,
		sample_interval: iptv_fast() ? cfg.iptv.sample_interval : cfg.interval,
		min: iptv.tick?.min, stall_s: iptv.tick?.stall_s
	};
	if (cfg.iptv.quality) o.quality = tsq_out();

	if (cfg.iptv.vlan) {
		o.vlan = { id: cfg.iptv.vlan, bridge: vl.bridge, upstream: vl.upstream, ports: vl.ports, error: vl.error };
		if (vl.error && vl.error != 'stats_off') {
			level = worst(level, 'warn');
			push(reasons, { c: 'vlan_' + vl.error, vlan: cfg.iptv.vlan });
			o.level = level;
		}
	}

	let brname = cfg.iptv.bridge || (cfg.iptv.vlan ? vl.bridge : null);
	if (brname) {
		let b = `${brname}`;
		let cs = (f) => { let v = num(rd(b, `bridge/${f}`), null); return (v == null) ? null : round(v / 100, 0); };
		o.bridge = {
			name: b,
			snooping: rd(b, 'bridge/multicast_snooping'),
			querier: rd(b, 'bridge/multicast_querier'),
			igmp_version: rd(b, 'bridge/multicast_igmp_version'),
			/* kernel timers are in centiseconds */
			membership_interval: cs('multicast_membership_interval'),
			query_interval: cs('multicast_query_interval'),
			mdb: cfg.iptv.vlan ? vl.mdb : bridge_mdb(b)
		};
	}

	if (cfg.iptv.igmp) {
		o.igmp = {
			dev: cfg.iptv.igmp_dev || null,
			found: igmp.found, version: igmp.version,
			groups: igmp.groups, current: chn_current(), last_change: igmp.last_change,
			proxy: igmp.proxy ?? igmp.last_name, proxy_running: igmp.proxy != null, proxy_seen: igmp.proxy_seen
		};
		o.channels = chn_out(o);
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
/* true when the membership data works (groups were seen before) and
 * nobody is subscribed to any channel right now: a decoder that is switched
 * off leaves its groups, a freeze with the decoder on does not (or the
 * decoder joins again within seconds) */
function nobody_subscribed() {
	return cfg.iptv.igmp && cfg.iptv.off_after > 0 && igmp.seen && igmp.groups != null && length(igmp.groups) == 0;
}

/* log the start of a stall (ts = moment the data stopped) */
function iptv_flag_stall(kbps) {
	emit('err', 'iptv', 'stream', 'stream_stall', { kbps, avg: round(iptv.avg, 0),
		groups: igmp.groups != null ? length(igmp.groups) : null, ch: chn_now() }, iptv.low_w);
	iptv.state = 'stalled';
	iptv.stall_since = iptv.low_w;
	iptv.stall_m = iptv.low_m;
	iptv.low_m = iptv.low_w = null;
	iptv.held = false;
	if (iptv.acc) iptv.acc.stalls++;
	if (iptv.acc) iptv.acc.stall_s += iptv.hold_def;
	iptv.hold_def = 0;
}

function iptv_update(kbps, m, w, from_m, from_w) {
	kbps = round(kbps, 0);
	let active = kbps >= cfg.iptv.min_kbps;
	let off = false;

	/* seconds of data missing in this interval, judged against the usual
	 * bitrate; summed over a freeze it gives its length more exactly than
	 * the sample boundaries do (a gap rarely starts on a sample edge) */
	let def = (iptv.avg > 0) ? (m - from_m) * (1 - kbps / iptv.avg) : (active ? 0 : m - from_m);
	if (def < 0) def = 0;
	let prev_def = iptv.last_def ?? 0;
	iptv.last_def = def;
	let was_low = iptv.state == 'stalled' || iptv.low_m != null;

	/* a stop with nobody subscribed was not reported yet (see below): decide */
	if (iptv.state == 'playing' && iptv.held) {
		if (!active && nobody_subscribed()) {
			if (m - iptv.low_m >= cfg.iptv.off_after) {
				/* still no channel after the grace time: the decoder was switched off */
				emit('info', 'iptv', 'stream', 'stream_off', { avg: round(iptv.avg, 0) }, iptv.low_w);
				iptv.state = 'idle';
				iptv.since = w;
				iptv.low_m = iptv.low_w = null;
				iptv.held = false;
				iptv.hold_def = 0;
				off = true;
			}
		}
		else {
			/* data is back or the decoder subscribed again: it was a freeze */
			iptv_flag_stall(kbps);
		}
	}

	switch (iptv.state) {
	case 'idle':
		if (active) {
			emit('info', 'iptv', 'stream', 'stream_start', { kbps, ch: chn_now() });
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
			/* nobody subscribed: wait before calling it a fault, it may be
			 * the decoder being switched off */
			if (!iptv.held && nobody_subscribed()) iptv.held = true;
			if (!iptv.held) iptv_flag_stall(kbps);
		}
		break;

	case 'stalled':
		if (active) {
			/* data came back somewhere inside the last interval */
			let dur = round(iptv.missing + def, 0);
			emit('warn', 'iptv', 'stream', 'stream_resume', { dur: dur < 1 ? 1 : dur, kbps,
				igmp: igmp_classify(iptv.stall_since), ch: chn_now() });
			iptv.state = 'playing';
			iptv.dip = false;
		}
		else {
			iptv.missing += def;
		}
		if (iptv.state == 'stalled' && m - iptv.stall_m >= cfg.iptv.idle_after) {
			emit('warn', 'iptv', 'stream', 'stream_lost', { dur: round(m - iptv.stall_m, 0),
				groups: igmp.groups != null ? length(igmp.groups) : null, ch: chn_now() });
			iptv.state = 'idle';
			iptv.since = w;
		}
		break;
	}

	if (iptv.acc && !off && (was_low || iptv.state == 'stalled' || iptv.low_m != null)) {
		if (iptv.held) iptv.hold_def += def;
		else iptv.acc.stall_s += def;
	}
}

function iptv_counters() {
	if (cfg.iptv.vlan) return vl.cnt;
	let dev = cfg.iptv.device, tx = cfg.iptv.direction == 'tx';
	if (!fs.stat(`${SYSNET}/${dev}`)) return null;
	let b = num(rd(dev, `statistics/${tx ? 'tx' : 'rx'}_bytes`), null);
	let p = num(rd(dev, `statistics/${tx ? 'tx' : 'rx'}_packets`), null);
	return (b == null || p == null) ? null : { b, p };
}

/* fast sampler: one counter reading per sample_interval */
function iptv_fast_sample() {
	if (cfg.iptv.vlan) vlan_sample();
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
	/* a new channel gets its name within seconds, not at the next tick */
	chn_poll();

	iptv.prev = c;
	iptv.prev_m = m;
	iptv.prev_w = w;
}

/* called once per main tick: summary of the fast samples, dip detection */
function sample_iptv(devres) {
	if (!iptv_on()) return null;

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
				emit('warn', 'iptv', 'stream', 'stream_dip', { kbps, avg: round(iptv.avg, 0), ch: chn_now() });
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

/* ----------------------------------------------- IPTV picture quality */

/*
 * MPEG-TS continuity errors: what a viewer sees as pixelation. Nothing in
 * OpenWrt counts them, so this is the second own measurement. A short capture
 * (q_window s, every q_interval s, only while the stream plays) is taken by
 * tcpdump with the kernel doing the filtering, and counted by tsscan.uc in a
 * separate low-priority process, so the collector itself never parses
 * packets. After an error the next windows run back-to-back for a while.
 * The measured channel is whichever group carries TS in the capture, i.e. the
 * one being watched; no group is picked from IGMP.
 */

function tsq_done(resfile) {
	tsq.wd?.cancel();
	tsq.wd = null;
	tsq.proc = null;

	let r;
	try { r = json(fs.readfile(resfile) || 'null'); } catch (e) { r = null; }
	fs.unlink(resfile);

	let t = now();
	if (type(r?.groups) != 'array') {
		tsq.err = 'scan_failed';
		tsq.boost = 0;
		tsq.next = t + cfg.iptv.q_interval;
		return;
	}
	tsq.err = null;
	tsq.windows++;
	chn_learn(r.groups);

	/* only groups that carry a real stream (EPG / service data is not TS) */
	let w = { ts: t, dur: r.dur, groups: [], lvl: 'ok', cc: 0 };
	let main = null;
	for (let g in r.groups) {
		if ((g.kbps ?? 0) < cfg.iptv.min_kbps) continue;
		let bad = g.cc_err + g.tei;
		let lvl = 'ok';
		if (bad >= cfg.iptv.q_fail) lvl = 'err';
		else if (bad >= cfg.iptv.q_warn || (cfg.iptv.q_gap > 0 && g.max_gap_ms >= cfg.iptv.q_gap)) lvl = 'warn';
		let o = { grp: g.grp, ch: chn_name(g.grp), kbps: g.kbps, pps: g.pps, cc: g.cc_err, lost: g.lost, tei: g.tei,
			gap: g.max_gap_ms, rtp_lost: g.rtp ? g.rtp_lost : null, lvl };
		push(w.groups, o);
		w.cc += bad;
		w.lvl = worst(w.lvl, lvl);
		if (lvl != 'ok' && (!main || bad > main.cc + main.tei)) main = o;
	}

	tsq.last = w;
	push(tsq.recent, { ts: t, cc: w.cc, lvl: w.lvl });
	if (length(tsq.recent) > 30) tsq.recent = slice(tsq.recent, -30);
	tsq.cc_acc = (tsq.cc_acc ?? 0) + w.cc;

	if (main) {
		/* events are limited by the cooldown; what a held-back window found
		 * is added to the next event of the same fault */
		let p = tsq.pend ??= { cc: 0, lost: 0, win: 0 };
		p.cc += main.cc;
		p.lost += main.lost;
		p.win += r.dur ?? cfg.iptv.q_window;
		if (t - tsq.last_ev >= cfg.err_cooldown || LEVEL[w.lvl] > LEVEL[tsq.last_lvl ?? 'ok']) {
			emit(w.lvl, 'iptv', 'quality', 'ts_errors', { grp: main.grp, ch: main.ch, cc: p.cc, lost: p.lost,
				tei: main.tei, gap: main.gap, win: round(p.win, 0), kbps: main.kbps }, t);
			tsq.pend = null;
			tsq.last_ev = t;
			tsq.last_lvl = w.lvl;
		}
		tsq.boost = 5;
	}
	else {
		tsq.pend = null;
		if (tsq.boost > 0) tsq.boost--;
	}
	tsq.next = t + (tsq.boost > 0 ? 1 : cfg.iptv.q_interval);
}

function tsq_start(tg) {
	let pcap = `${VARDIR}/ts.pcap`, res = `${VARDIR}/ts.json`;
	let win = cfg.iptv.q_window;
	fs.unlink(res);
	fs.unlink(pcap);

	/* tcpdump stops after win seconds (or a packet cap as a safety net),
	 * then tsscan.uc takes over the same process (exec) */
	let cmd = `N=; command -v nice >/dev/null 2>&1 && N='nice -n 10'; ` +
		`$N ${TCPDUMP} -i ${tg.dev} -nn -q -s 0 -c ${win * 8000} -w ${pcap} '${tg.filter}' 2>/dev/null & p=$!; ` +
		`sleep ${win}; kill $p 2>/dev/null; wait $p 2>/dev/null; ` +
		`exec $N ${UCODE} ${TSSCAN} ${pcap} ${res}`;

	tsq.proc = uloop.process('/bin/sh', [ '-c', cmd ], null, (code) => {
		try {
			tsq_done(res);
		}
		catch (e) {
			warn(`isp-tester: quality scan failed: ${e}\n`);
			tsq.proc = null;
			tsq.next = now() + cfg.iptv.q_interval;
		}
	});

	if (!tsq.proc) {
		tsq.err = 'scan_failed';
		tsq.next = now() + cfg.iptv.q_interval;
		return;
	}

	/* a stuck scan must not block the next ones; the capture itself ends on
	 * its own, this only frees a hung parser */
	let pid = tsq.proc.pid();
	tsq.wd = uloop.timer((win + 30) * 1000, () => {
		if (tsq.proc != null && tsq.proc.pid() == pid)
			system([ '/bin/sh', '-c', `kill ${int(pid)} 2>/dev/null` ]);
	});
}

function tsq_poll() {
	if (!cfg.iptv.quality || !iptv_on() || tsq.proc || chn.proc) return;
	if (!TCPDUMP) { tsq.err = 'no_tcpdump'; return; }
	if (!UCODE || !fs.stat(TSSCAN)) { tsq.err = 'no_scanner'; return; }
	/* only while a stream is really flowing */
	if (iptv.state != 'playing' || iptv.held || iptv.kbps < cfg.iptv.min_kbps) return;
	if (now() < tsq.next) return;
	let tg = tsq_target();
	if (!tg) { tsq.err = 'no_target'; return; }
	if (tsq.err == 'no_tcpdump' || tsq.err == 'no_scanner' || tsq.err == 'no_target') tsq.err = null;
	tsq_start(tg);
}

/* ------------------------------------------------------------------- CSV */

function csv_columns(devs, tlist) {
	let cols = [ 'time', 'overall' ];
	for (let t in tlist) push(cols, `ping_${t.label}_loss`, `ping_${t.label}_rtt`, `ping_${t.label}_jitter`);
	if (iptv_on()) push(cols, 'iptv_state', 'iptv_kbps', 'iptv_min_kbps', 'iptv_stall_s', 'iptv_pps', 'iptv_channel');
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

	if (st.up === false) return;      /* keep last known device / gateway while WAN is down */
	let dev = st.l3_device ?? st.device ?? '';
	if (cfg.wan.auto_device && valid_dev(dev)) cfg.wan.device = dev;

	/* the gateway is wanted with a device override too */
	let gw = null;
	for (let r in (st.route ?? []))
		if (r.target == '0.0.0.0' && r.mask == 0 && r.nexthop && r.nexthop != '0.0.0.0') { gw = r.nexthop; break; }
	gw ??= st['ipv4-address']?.[0]?.ptpaddress;
	cfg.wan.gw = valid_host(gw) ? gw : null;
}

function handle_clear_request() {
	let flag = `${VARDIR}/clear`;
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
	handle_marks();
	handle_notify_test();
	handle_chn_forget();
	refresh_wan_device();
	sample_proxy();
	if (!iptv_fast()) igmp_poll();
	sample_system();
	read_log();
	sample_pings();

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
				label: t.label, host: t.host, level: r ? target_level(r) : 'unknown',
				loss: r?.loss, rtt: r?.rtt, jitter: r?.jitter, since: t.since
			});
			if (!r) continue;
			n_active++;
			let lv = target_level(r);
			if (lv == 'fail') n_fail++;
			if (lv != 'ok') push(reasons, { c: lv == 'fail' ? 'target_fail' : 'target_degraded', t: t.label, loss: r.loss, rtt: r.rtt, jitter: r.jitter, why: target_why(r) });
			level = worst(level, lv == 'fail' ? 'warn' : lv);
		}
		if (n_active > 0 && n_fail == n_active) level = 'fail';
		if (wan_down_since != null) push(reasons, { c: 'wan_down', since: wan_down_since });
		if (wansess.up === false) {
			level = 'fail';
			push(reasons, { c: 'wan_if_down', iface: cfg.wan.interface, since: wansess.since });
		}
		if (!source.type)
			push(reasons, { c: 'no_ping_source', error: source.error, plugin: source.ping_plugin });

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
			source: { type: source.type, error: source.error, sock_error: source.sock_error, ping_plugin: source.ping_plugin, gateway: gateway_ip() },
			session: (wansess.up != null) ? { up: wansess.up, uptime: wansess.uptime, ip: wansess.ip, proto: wansess.proto, reconnects: wansess.reconnects, since: wansess.since } : null };
	}

	/* ---- IPTV */
	let iptv_dev = cfg.iptv.vlan ? vl.upstream : cfg.iptv.device;
	let iptv_res = sample_iptv(iptv_dev ? res[iptv_dev] : null);
	tsq_poll();
	chn_poll();

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
			hv[`jit:${x.label}`] = x.jitter;
		}
		if (iptv_res) {
			hv['iptv:kbps'] = iptv_res.kbps;
			/* lowest 1 s bitrate in this interval, so short freezes show on the chart */
			if (iptv_res.min != null) hv['iptv:min'] = iptv_res.min;
			/* picture errors found by the quality scan since the last tick */
			if (cfg.iptv.quality) {
				hv['iptv:cc'] = tsq.cc_acc;
				tsq.cc_acc = null;
			}
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
		let tlist = [];
		for (let k, x in targets)
			if (x.active) push(tlist, { label: x.label, t: x });
		let cols = csv_columns(devs, tlist);
		if (join(',', cols) != csv_header) csv_open(cols);

		let row = [ tstamp(t), overall ];
		for (let x in tlist) push(row, x.t.res?.loss, x.t.res?.rtt, x.t.res?.jitter);
		if (iptv_on()) {
			/* no quoting in this CSV: commas and quotes in names become spaces */
			let ch = chn_now();
			push(row, iptv_res?.state, iptv_res?.kbps, iptv_res?.min, iptv_res?.stall_s, iptv_res?.pps,
				ch ? replace(replace(ch, ', ', ' | '), /[,"\r\n]/g, ' ') : null);
		}
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
		csv_rows,
		data: { dir: RUNDIR, link: (fs.lstat(RUNDIR)?.type == 'link') ? fs.readlink(RUNDIR) : null },
		notify: cfg.notify.enabled ? { service: cfg.notify.service, pending: length(notif.pending),
			last_ok: notif.last_ok, last_fail: notif.last_fail, last_err: notif.last_err, fetch: FETCH != null } : null
	};
	write_atomic(`${VARDIR}/state.json`, sprintf('%J', state));

	notify_flush(false);
}

/* ------------------------------------------------------------------ main */

fs.mkdir(RUNDIR);
fs.mkdir(VARDIR);

let old;
try { old = json(fs.readfile(`${RUNDIR}/events.json`) || '[]'); } catch (e) { old = null; }
if (type(old) == 'array') events = old;

/* keep chart history across collector restarts (e.g. after saving settings) */
let load_hist = (name, max) => {
	let h;
	try { h = json(fs.readfile(`${name == 'state.json' ? VARDIR : RUNDIR}/${name}`) || 'null'); } catch (e) { h = null; }
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
chn_load();
history_min = load_hist('history.json', cfg.long_history);

emit('info', 'system', 'collector', 'monitor_start', { interval: cfg.interval, iptv_interval: iptv_fast() ? cfg.iptv.sample_interval : null });

uloop.init();
refresh_wan_device();
/* the log so far is history: only remember where it ends */
read_log();

let timer;
timer = uloop.timer(1000, () => {
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
