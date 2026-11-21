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
 * The IPTV bitrate is one own measurement: read from the interface
 * counters every second, which nothing in OpenWrt does. The other is the
 * picture quality (lost MPEG-TS packets), counted continuously by the small
 * helper isp-tester-tsmon (C, separate package). When the IPTV VLAN
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
/* testing with a JSON config: no ubus unless ISP_TESTER_UBUS is set */
const NO_UBUS = !!getenv('ISP_TESTER_CONFIG') && !getenv('ISP_TESTER_UBUS');
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
/* picture quality and channel names: the helper of package isp-tester-tsmon */
const TSMON = find_bin('ISP_TESTER_TSMON', [ '/usr/sbin/isp-tester-tsmon' ]);
/* snapshot of the path at a loss: mtr when installed, else busybox traceroute */
const MTR = find_bin('ISP_TESTER_MTR', [ '/usr/sbin/mtr', '/usr/bin/mtr' ]);
const TRACEROUTE = find_bin('ISP_TESTER_TRACEROUTE', [ '/usr/bin/traceroute', '/bin/traceroute', '/usr/sbin/traceroute' ]);
const TRACEROUTE6 = find_bin('ISP_TESTER_TRACEROUTE6', [ '/usr/bin/traceroute6', '/bin/traceroute6', '/usr/sbin/traceroute6' ]);

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

/* plain IPv4 address (no names: nothing to resolve at boot) */
function valid_ip(a) {
	let m = match(`${a ?? ''}`, /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/);
	return !!m && +m[1] <= 255 && +m[2] <= 255 && +m[3] <= 255 && +m[4] <= 255;
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

function absf(v) { return (v < 0) ? -v : v; }

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
		/* days kept in RUNDIR/archive when RUNDIR is on USB (data_dir); 0 = off */
		archive_days: 30,
		warn_window: 900,
		logread: true,
		wan: {
			enabled: true, interface: 'wan', device: '', gateway: '',
			loss_warn: 1, loss_fail: 50, rtt_warn: 80, jitter_warn: 0,
			collectd_socket: '', rrd_dir: '',
			/* one traceroute/mtr when a loss starts, at most every trace_cooldown s */
			trace: true, trace_cooldown: 600,
			/* bufferbloat: ping vs. WAN load; down/up_mbit 0 = learn the line's speed */
			bloat: true, bloat_ms: 30, bloat_load: 70, down_mbit: 0, up_mbit: 0,
			/* IPv6: netifd status of the DHCPv6 interface (odhcp6c), '' = wan6 / <wan>_6 */
			ipv6: true, interface6: '', ra_after: 60
		},
		iptv: {
			enabled: true, vlan: 0, upstream: '', device: '', direction: 'rx', bridge: '',
			min_kbps: 500, idle_after: 60, off_after: 15, dip_pct: 40,
			sample_interval: 1, stall_after: 2,
			igmp: true, igmp_device: '',
			quality: false, q_warn: 1, q_fail: 30, q_gap: 500,
			names: true, channels: {},
			/* decoder restarts: bridge MAC table (bridged VLAN) + port link; decoders = { mac: label } */
			decoders: true, dec_silence: 40, dec_off: 600, dec_labels: {},
			/* DHCP of the decoders: the operator's replies seen by tsmon */
			dhcp: true
		},
		system: {
			enabled: true, cpu_warn: 90, mem_warn: 10, conntrack_warn: 90
		},
		/* DNS of the router (dnsmasq): ubus metrics every tick, per-server
		 * statistics from its SIGUSR1 dump in the system log every dump s */
		dns: { enabled: true, warn_pct: 10, min_queries: 5, dump: 300 },
		notify: {
			enabled: false, service: 'ntfy', url: '', token: '', chat_id: '',
			min_level: 'err', cooldown: 300, lang: 'en'
		},
		/* Wi-Fi clients from hostapd (ubus): stations = { mac: label } */
		wifi: { enabled: true, signal_warn: -75, reconnect_s: 60, stations: {} },
		/* second router: 'send' its events to the one that 'receive's them */
		peer: { role: 'off', host: '', port: 51477, key: '' },
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
		let pr = cur.get_all('isp_tester', 'peer') || {};
		let wf = cur.get_all('isp_tester', 'wifi') || {};
		let dn = cur.get_all('isp_tester', 'dns') || {};

		c.dns.enabled     = bool(dn.enabled, true);
		c.dns.warn_pct    = num(dn.warn_pct, c.dns.warn_pct);
		c.dns.min_queries = num(dn.min_queries, c.dns.min_queries);
		c.dns.dump        = num(dn.dump, c.dns.dump);

		c.wifi.enabled     = bool(wf.enabled, true);
		c.wifi.signal_warn = num(wf.signal_warn, c.wifi.signal_warn);
		c.wifi.reconnect_s = num(wf.reconnect_s, c.wifi.reconnect_s);
		cur.foreach('isp_tester', 'station', (s) => {
			if (s.mac && bool(s.enabled, true)) c.wifi.stations[lc(trim(s.mac))] = s.label ?? '';
		});

		c.peer.role = (pr.role == 'send' || pr.role == 'receive') ? pr.role : 'off';
		c.peer.host = trim(pr.host ?? '');
		c.peer.port = num(pr.port, c.peer.port);
		c.peer.key  = pr.key ?? '';

		c.logread     = bool(g.logread, true);

		c.wan.jitter_warn = num(w.jitter_warn, c.wan.jitter_warn);
		c.wan.gateway     = w.gateway ?? '';
		c.wan.trace          = bool(w.trace, true);
		c.wan.trace_cooldown = num(w.trace_cooldown, c.wan.trace_cooldown);
		c.wan.bloat          = bool(w.bloat, true);
		c.wan.bloat_ms       = num(w.bloat_ms, c.wan.bloat_ms);
		c.wan.bloat_load     = num(w.bloat_load, c.wan.bloat_load);
		c.wan.down_mbit      = num(w.down_mbit, c.wan.down_mbit);
		c.wan.up_mbit        = num(w.up_mbit, c.wan.up_mbit);
		c.wan.ipv6           = bool(w.ipv6, true);
		c.wan.interface6     = w.interface6 ?? '';
		c.wan.ra_after       = num(w.ra_after, c.wan.ra_after);

		/* where luci-app-statistics keeps collectd's data */
		let us = cur.get_all('luci_statistics', 'collectd_unixsock') || {};
		let rr = cur.get_all('luci_statistics', 'collectd_rrdtool') || {};
		let pg = cur.get_all('luci_statistics', 'collectd_ping') || {};
		c.wan.collectd_socket = w.collectd_socket || (bool(us.enable, false) ? (us.SocketFile ?? '') : '');
		c.wan.rrd_dir = w.rrd_dir || rr.DataDir || '/tmp/rrd';
		c.wan.ping_plugin = bool(pg.enable, false);
		c.wan.ping_hosts = aslist(pg.Hosts);

		c.iptv.decoders    = bool(t.decoders, true);
		c.iptv.dhcp        = bool(t.dhcp, true);
		c.iptv.dec_silence = num(t.dec_silence, c.iptv.dec_silence);
		c.iptv.dec_off     = num(t.dec_off, c.iptv.dec_off);
		cur.foreach('isp_tester', 'decoder', (s) => {
			if (s.mac) c.iptv.dec_labels[lc(trim(s.mac))] = s.label ?? '';
		});
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
		c.archive_days = num(g.archive_days, c.archive_days);
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
	/* picture quality: thresholds are lost-packet gaps per minute */
	c.iptv.q_gap = int(c.iptv.q_gap);
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

	let sta = {};
	for (let mac, l in (type(c.wifi.stations) == 'object' ? c.wifi.stations : {})) {
		mac = lc(mac);
		if (match(mac, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/)) sta[mac] = substr(trim(replace(`${l ?? ''}`, /[[:cntrl:]]+/g, ' ')), 0, 32);
	}
	c.wifi.stations = sta;
	if (c.wifi.signal_warn > -30 || c.wifi.signal_warn < -100) c.wifi.signal_warn = -75;
	if (c.wifi.reconnect_s < 5) c.wifi.reconnect_s = 5;

	if (c.wan.trace_cooldown < 60) c.wan.trace_cooldown = 60;
	if (c.wan.interface6 && !match(c.wan.interface6, /^[A-Za-z0-9_]{1,15}$/)) c.wan.interface6 = '';
	if (c.wan.ra_after < 10) c.wan.ra_after = 10;
	if (c.dns.warn_pct < 1 || c.dns.warn_pct > 100) c.dns.warn_pct = 10;
	if (c.dns.min_queries < 1) c.dns.min_queries = 1;
	c.dns.dump = int(c.dns.dump);
	if (c.dns.dump != 0 && c.dns.dump < 60) c.dns.dump = 60;
	let dl = {};
	for (let mac, l in (type(c.iptv.dec_labels) == 'object' ? c.iptv.dec_labels : {})) {
		mac = lc(mac);
		if (match(mac, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/)) dl[mac] = substr(trim(replace(`${l ?? ''}`, /[[:cntrl:]]+/g, ' ')), 0, 32);
	}
	c.iptv.dec_labels = dl;
	if (c.iptv.dec_silence < 15) c.iptv.dec_silence = 15;
	if (c.iptv.dec_off < c.iptv.dec_silence + 30) c.iptv.dec_off = c.iptv.dec_silence + 30;
	c.archive_days = int(c.archive_days);
	if (c.archive_days < 0) c.archive_days = 0;
	if (c.archive_days > 366) c.archive_days = 366;
	if (c.wan.bloat_ms < 5) c.wan.bloat_ms = 5;
	if (c.wan.bloat_load < 30 || c.wan.bloat_load > 100) c.wan.bloat_load = 70;
	if (!(c.wan.down_mbit >= 0)) c.wan.down_mbit = 0;
	if (!(c.wan.up_mbit >= 0)) c.wan.up_mbit = 0;

	c.peer.port = int(c.peer.port);
	if (c.peer.port < 1 || c.peer.port > 65535) c.peer.port = 51477;
	c.peer.err = null;
	if (c.peer.role != 'off' && length(c.peer.key ?? '') < 8) c.peer.err = 'no_key';
	else if (c.peer.role == 'send' && !valid_ip(c.peer.host)) c.peer.err = 'bad_host';

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
let ubus_conn = null;     /* one ubus connection, (re)opened on demand */

/* names of the ubus objects matching re; list() with a pattern would return
 * their method signatures, not their names */
function ubus_objects(re) {
	return filter(ubus_conn?.list() ?? [], (n) => type(n) == 'string' && match(n, re) != null);
}
let csv_header = null;
let last_mono = null;
let started = now();
let wansess = { up: null, uptime: null, seen: null, ip: null, since: now(), reconnects: 0 };
/* IPv6 of the WAN (see v6_session): found = a DHCPv6 interface exists */
let v6s = { iface: null, found: false, up: null, since: now(), prefixes: null, addr: null, route: null,
	pd_seen: false, route_seen: false, pd_lost: null, route_lost: null, nr_logged: false, reconnects: 0 };
/* bridged IPTV VLAN (see vlan_sample) */
let vl = { bridge: null, upstream: null, ports: [], stats: null, mdb: null, error: null, cnt: null };
/* joined = group -> when it was joined (0 = already there at start) */
let igmp = { groups: null, joined: {}, hist: [], proxy: null, proxy_seen: false, proxy_since: now() };
/* picture quality (see tsm_poll): proc/args = the running helper and its
 * arguments, fails/next = restart backoff, seen = last counters per group
 * ("<pid>:<id>"), drops = the helper's socket drop counter, flow = groups
 * carrying TS in the last read, win = errors of the last TSQ_WIN s,
 * pend/last_ev/last_lvl = per group, errors whose event is held back by the
 * cooldown, cc_acc = errors since the last tick (history chart),
 * dropped/drop_ts = packets the router could not count */
let tsq = { proc: null, args: null, started: 0, fails: 0, next: 0, err: null, seen: {}, drops: null, flow: null,
	win: [], last: null, pend: {}, last_ev: {}, last_lvl: {}, cc_acc: null, dropped: 0, drop_ts: 0 };
/* channel names: db = group -> { name, provider, sid, ts } learned from the
 * streams (or { name: null, why, ts } when a stream carries none) */
let chn = { db: {}, err: null };
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
		user_mark: 'Problem reported by user: %s', test: 'Test message - notifications work.',
		peer_lost: 'Router %s does not report any more', peer_back: 'Router %s reports again after %s',
		trace: 'Traceroute to %s: %s',
		decoder_restart: 'Decoder %s restarted (gone %s, %s)', decoder_off: 'Decoder %s switched off or unplugged (%s)',
		decoder_on: 'Decoder %s is back after %s',
		bufferbloat: 'Bufferbloat: ping +%s ms with the link %d%% full (%s)', bufferbloat_ok: 'Bufferbloat over after %s (up to +%s ms)',
		wifi_reconnect: 'Wi-Fi: %s dropped and reconnected after %s (%s)', wifi_leave: 'Wi-Fi: %s disconnected (%s)',
		wifi_join: 'Wi-Fi: %s connected again after %s', wifi_roam: 'Wi-Fi: %s moved %s -> %s', wifi_weak: 'Wi-Fi: %s weak signal %d dBm', wifi_weak_ok: 'Wi-Fi: %s signal OK again after %s',
		v6_down: 'IPv6 DOWN - no IPv6 target responds (IPv4 works)', v6_up: 'IPv6 back after %s',
		v6_if_down: 'IPv6 interface %s went down', v6_if_up: 'IPv6 interface %s up again after %s',
		v6_pd_lost: 'IPv6 prefix lost (%s)', v6_pd_back: 'IPv6 prefix back after %s: %s', v6_pd_change: 'IPv6 prefix changed %s -> %s',
		v6_no_route: 'No IPv6 default route (no router advertisement) on %s', v6_route_back: 'IPv6 default route back after %s',
		dns_fail: 'DNS: %d%% of the queries sent upstream unanswered (%d of %d in %ss)', dns_ok: 'DNS OK again after %s (at worst %d%% unanswered)',
		dns_server_bad: 'DNS server %s: %d of %d queries retried or failed in %s', dns_server_ok: 'DNS server %s OK again',
		router_reboot: 'Router restarted (up since %s)', data_gap: 'No measurements from %s to %s (%s): %s',
		collector_restart: 'Monitor restarted after it %s',
		ntp_sync: 'Clock synchronized (NTP stratum %s)', ntp_unsync: 'Clock NOT synchronized - times in the log may be wrong',
		ntp_off: 'No NTP client running - times in the log may be wrong', clock_step: 'Clock set by %ss',
		maint_start: 'Maintenance until %s: not counted, no notifications (%s)', maint_end: 'Maintenance over after %s',
		dhcp_lease: 'Decoder %s: address %s from the operator (lease %s)', dhcp_new: 'Decoder %s asked for an address anew: %s',
		dhcp_ip_change: 'Decoder %s: address CHANGED %s -> %s', dhcp_nak: 'Decoder %s: operator REFUSED the lease (DHCPNAK)',
		dhcp_expired: 'Decoder %s: lease of %s expired without renewal', dhcp_late: 'Decoder %s renewed its lease %s too late'
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
		user_mark: 'Problem zgłoszony ręcznie: %s', test: 'Wiadomość testowa - powiadomienia działają.',
		peer_lost: 'Router %s przestał się zgłaszać', peer_back: 'Router %s znów się zgłasza po %s',
		trace: 'Traceroute do %s: %s',
		decoder_restart: 'Dekoder %s zrestartował się (nie było go %s, %s)', decoder_off: 'Dekoder %s wyłączony lub odłączony (%s)',
		decoder_on: 'Dekoder %s wrócił po %s',
		bufferbloat: 'Bufferbloat: ping +%s ms przy łączu zajętym w %d%% (%s)', bufferbloat_ok: 'Bufferbloat minął po %s (do +%s ms)',
		wifi_reconnect: 'Wi-Fi: %s rozłączył się i wrócił po %s (%s)', wifi_leave: 'Wi-Fi: %s rozłączony (%s)',
		wifi_join: 'Wi-Fi: %s znów połączony po %s', wifi_roam: 'Wi-Fi: %s przeszedł %s -> %s', wifi_weak: 'Wi-Fi: %s słaby sygnał %d dBm', wifi_weak_ok: 'Wi-Fi: %s sygnał znów OK po %s',
		v6_down: 'IPv6 NIE DZIAŁA - żaden cel IPv6 nie odpowiada (IPv4 działa)', v6_up: 'IPv6 wróciło po %s',
		v6_if_down: 'Interfejs IPv6 %s rozłączony', v6_if_up: 'Interfejs IPv6 %s znów działa po %s',
		v6_pd_lost: 'Utrata prefiksu IPv6 (%s)', v6_pd_back: 'Prefiks IPv6 wrócił po %s: %s', v6_pd_change: 'Zmiana prefiksu IPv6 %s -> %s',
		v6_no_route: 'Brak domyślnej trasy IPv6 (brak RA) na %s', v6_route_back: 'Domyślna trasa IPv6 wróciła po %s',
		dns_fail: 'DNS: %d%% zapytań wysłanych dalej bez odpowiedzi (%d z %d w %ss)', dns_ok: 'DNS znów OK po %s (najgorzej %d%% bez odpowiedzi)',
		dns_server_bad: 'Serwer DNS %s: %d z %d zapytań ponowionych lub nieudanych w %s', dns_server_ok: 'Serwer DNS %s znów OK',
		router_reboot: 'Router uruchomiony ponownie (działa od %s)', data_gap: 'Brak pomiarów od %s do %s (%s): %s',
		collector_restart: 'Monitor uruchomiony ponownie, bo %s',
		ntp_sync: 'Zegar zsynchronizowany (NTP stratum %s)', ntp_unsync: 'Zegar NIE jest zsynchronizowany - czasy w logu mogą być błędne',
		ntp_off: 'Brak klienta NTP - czasy w logu mogą być błędne', clock_step: 'Zegar przestawiony o %ss',
		maint_start: 'Prace serwisowe do %s: bez liczenia i powiadomień (%s)', maint_end: 'Prace serwisowe zakończone po %s',
		dhcp_lease: 'Dekoder %s: adres %s od operatora (dzierżawa %s)', dhcp_new: 'Dekoder %s poprosił o adres od nowa: %s',
		dhcp_ip_change: 'Dekoder %s: ZMIANA adresu %s -> %s', dhcp_nak: 'Dekoder %s: operator ODMÓWIŁ dzierżawy (DHCPNAK)',
		dhcp_expired: 'Dekoder %s: dzierżawa %s wygasła bez odnowienia', dhcp_late: 'Dekoder %s odnowił dzierżawę %s za późno'
	}
};

const GAP_WHY_EN = { reboot: 'router restarted', stopped: 'monitoring was off', crash: 'the collector stopped unexpectedly',
	hung: 'the collector hung (restarted by the watchdog)', stall: 'the collector was blocked' };
const GAP_WHY_PL = { reboot: 'restart routera', stopped: 'monitorowanie wyłączone', crash: 'collector nieoczekiwanie się zatrzymał',
	hung: 'collector się zawiesił (zrestartowany przez watchdog)', stall: 'collector był zablokowany' };

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
	case 'ts_errors': return sprintf(f, d.cc + (d.tei ?? 0), d.lost, d.win, d.ch ? `${d.ch} (${d.grp})` : (d.grp ?? '?'));
	case 'proxy_down': case 'proxy_up': case 'proxy_restart': return sprintf(f, d.name);
	case 'cpu_high': return sprintf(f, d.cpu, d.sirq);
	case 'mem_low': return sprintf(f, d.pct);
	case 'conntrack_full': return sprintf(f, d.pct);
	case 'user_mark': return sprintf(f, d.note || '-');
	case 'peer_lost': return sprintf(f, e.src);
	case 'peer_back': return sprintf(f, e.src, dur_txt(d.dur));
	case 'trace': return sprintf(f, d.host, d.first_bad
		? sprintf(lang == 'pl' ? 'straty od hopa %d (%s)' : 'loss starts at hop %d (%s)', d.first_bad, d.bad_ip ?? '?')
		: (lang == 'pl' ? 'bez strat do celu' : 'no loss to the destination'));
	case 'decoder_restart': return sprintf(f, e.src, dur_txt(d.dur), d.port ?? '?');
	case 'decoder_off': return sprintf(f, e.src, d.port ?? '?');
	case 'decoder_on': return sprintf(f, e.src, dur_txt(d.dur));
	case 'bufferbloat': return sprintf(f, d.add, d.load, d.dir == 'up' ? (lang == 'pl' ? 'wysyłanie' : 'upload') : (lang == 'pl' ? 'pobieranie' : 'download'));
	case 'bufferbloat_ok': return sprintf(f, dur_txt(d.dur), d.max_add);
	case 'wifi_reconnect': return sprintf(f, e.src, dur_txt(d.away), d.iface ?? '?');
	case 'wifi_leave': return sprintf(f, e.src, d.iface ?? '?');
	case 'wifi_join': return sprintf(f, e.src, dur_txt(d.away));
	case 'wifi_roam': return sprintf(f, e.src, d.from ?? '?', d.iface ?? '?');
	case 'wifi_weak': return sprintf(f, e.src, d.signal);
	case 'wifi_weak_ok': return sprintf(f, e.src, dur_txt(d.dur));
	case 'v6_up': case 'v6_route_back': return sprintf(f, dur_txt(d.dur));
	case 'v6_if_down': case 'v6_no_route': return sprintf(f, d.iface);
	case 'v6_if_up': return sprintf(f, d.iface, dur_txt(d.dur));
	case 'v6_pd_lost': return sprintf(f, join(' ', d.prev ?? []) || '-');
	case 'v6_pd_back': return sprintf(f, dur_txt(d.dur), join(' ', d.prefix ?? []));
	case 'v6_pd_change': return sprintf(f, join(' ', d.from ?? []), join(' ', d.to ?? []));
	case 'dns_fail': return sprintf(f, d.pct, d.unans, d.fwd, d.win);
	case 'dns_ok': return sprintf(f, dur_txt(d.dur), d.max_pct);
	case 'dns_server_bad': return sprintf(f, e.src, d.bad, d.sent, dur_txt(d.win));
	case 'dns_server_ok': return sprintf(f, e.src);
	case 'router_reboot': return sprintf(f, tstamp(d.boot));
	case 'collector_restart': return sprintf(f, d.why == 'hung'
		? (lang == 'pl' ? 'się zawiesił (watchdog)' : 'hung (watchdog)')
		: (lang == 'pl' ? 'nieoczekiwanie się zatrzymał' : 'stopped unexpectedly'));
	case 'ntp_sync': return sprintf(f, d.stratum ?? '?');
	case 'clock_step': return sprintf(f, (d.by > 0 ? '+' : '') + d.by);
	case 'maint_start': return sprintf(f, substr(tstamp(d.until), 11, 5), d.note || '-');
	case 'maint_end': return sprintf(f, dur_txt(d.dur));
	case 'dhcp_lease': return sprintf(f, e.src, d.ip, d.lease ? dur_txt(d.lease) : '?');
	case 'dhcp_new': return sprintf(f, e.src, d.ip);
	case 'dhcp_ip_change': return sprintf(f, e.src, d.from, d.to);
	case 'dhcp_nak': return sprintf(f, e.src);
	case 'dhcp_expired': return sprintf(f, e.src, d.ip);
	case 'dhcp_late': return sprintf(f, e.src, dur_txt(d.late));
	case 'data_gap': return sprintf(f, d.from ? tstamp(d.from) : '?', tstamp(d.to), dur_txt(d.len),
		(lang == 'pl' ? GAP_WHY_PL : GAP_WHY_EN)[d.why] ?? d.why);
	default: return f;
	}
}

function event_msg(e, lang) {
	let s = event_text(e, lang), d = e.d ?? {};
	/* the channel(s) being watched, when known */
	if (e.area == 'iptv' && d.ch && e.type != 'ts_errors') s += ` [${d.ch}]`;
	/* received from the second router */
	if (e.host) s = `[${e.host}] ${s}`;
	return s;
}

/* ------------------------------------------------------------------ notify */

/* recoveries are sent too, so a "down" message is always followed by "back";
 * only when the fault itself was sent (same area + source), so e.g. a decoder
 * port coming up or a target recovering from an unsent warning stays quiet */
const RECOVERY = { wan_up: true, stream_resume: true, stream_lost: true, stream_off: true, link_up: true,
	wan_if_up: true, proxy_up: true, target_ok: true, dev_present: true, peer_back: true, wifi_weak_ok: true,
	bufferbloat_ok: true, v6_up: true, v6_if_up: true, v6_pd_back: true, v6_route_back: true, dns_ok: true, dns_server_ok: true };

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
	/* during maintenance (the user works on the network): nothing */
	if (e.m) return;
	let key = `${e.host ?? ''}|${e.area}|${e.src}`;
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

/* --------------------------------------------------------- second router */

/*
 * Two routers, one timeline: the router behind the main one (role "send")
 * sends every event it logs to the main router (role "receive"), which puts
 * them on its own timeline marked with the sender's host name, so a decoder
 * or phone behind the second router shows up in one view.
 *
 * UDP, one JSON message per datagram, signed with HMAC-SHA256 of a shared
 * key (wire format: 64 hex characters of the MAC, then the JSON):
 *   sender -> receiver { v, h: host, ep: start time of the sender, now, iv,
 *                        ev: [ { q: sequence number, e: event } ], hb: status }
 *   receiver -> sender { v, ack: highest sequence number stored, ep, to, now }
 * Unacknowledged events are sent again every interval, so a short outage of
 * the receiver (or of the cable between the routers) loses nothing; the
 * receiver drops what it has already stored (q <= last). Every interval the
 * sender also sends a short status (heartbeat), so the receiver notices when
 * the second router stops reporting. Clocks: when the sender's clock is off
 * by more than 5 s, the receiver moves the events to its own time.
 */
const PEER_VER = 1;
const PEER_MAXPKT = 1350;       /* bytes of one datagram, below the usual MTU */
const PEER_OUTBOX = 300;        /* events kept for sending */

let peer = { sk: null, socket: null, h: null, err: null, ipad: null, opad: null, bad: 0, bad_addr: null, bad_ts: null,
	/* sender */ out: [], seq: 0, ep: 0, dropped: 0, last_send: 0, last_ack: null, kick: null,
	/* receiver */ peers: {} };
let peer_flush_fn = null;       /* set once uloop runs (see peer_start) */
let digest = null;

function unhex(h) {
	let out = '';
	for (let i = 0; i + 1 < length(h); i += 2) out += chr(hex(substr(h, i, 2)));
	return out;
}

/* HMAC-SHA256 (RFC 2104); the module returns hex, the inner hash is used raw */
function hmac_init(key) {
	try { digest ??= require('digest'); } catch (e) { return false; }
	if (length(key) > 64) key = unhex(digest.sha256(key));
	let ip = '', op = '';
	for (let i = 0; i < 64; i++) {
		let c = (i < length(key)) ? ord(key, i) : 0;
		ip += chr(c ^ 0x36);
		op += chr(c ^ 0x5c);
	}
	peer.ipad = ip;
	peer.opad = op;
	return true;
}

function hmac(msg) {
	return digest.sha256(peer.opad + unhex(digest.sha256(peer.ipad + msg)));
}

/* sender: an own event goes into the outbox, sent within a moment */
function peer_queue(e) {
	if (cfg.peer.role != 'send' || cfg.peer.err || e.host) return;
	push(peer.out, { q: ++peer.seq, e });
	if (length(peer.out) > PEER_OUTBOX) {
		peer.dropped += length(peer.out) - PEER_OUTBOX;
		peer.out = slice(peer.out, length(peer.out) - PEER_OUTBOX);
	}
	if (peer_flush_fn && !peer.kick)
		peer.kick = uloop.timer(300, () => { peer.kick = null; peer_flush_fn(null); });
}

/* ----------------------------------------------------------------- events */

function save_events() {
	write_atomic(`${RUNDIR}/events.json`, sprintf('%J', events));
}

/* ---------------------------------------------------------------- archive */

/*
 * Longer history (7 / 30 days) when RUNDIR is on USB (data_dir): one file
 * per UTC day in RUNDIR/archive, appended to and never rewritten (easy on
 * the flash), read by the web page directly:
 *   ev-YYYYMMDD.jsonl  every event, one JSON object per line
 *   h-YYYYMMDD.jsonl   10-minute aggregates { t, s: { key: value } }
 * In RAM it stays off: 30 days would not fit. Files older than
 * archive_days are deleted once an hour.
 */
const ARCH = `${RUNDIR}/archive`;
let arch = { on: false, checked: 0, info: null };

function arch_day(ts) {
	let g = gmtime(ts);
	return sprintf('%04d%02d%02d', g.year, g.mon, g.mday);
}

function arch_append(kind, ts, obj) {
	if (!arch.on) return;
	let fh = fs.open(`${ARCH}/${kind}-${arch_day(ts)}.jsonl`, 'a');
	if (!fh) return;
	fh.write(sprintf('%J\n', obj));
	fh.close();
}

/* once an hour: on USB?, delete old days, sizes for the status */
function arch_check() {
	let t = now();
	if (arch.checked && t - arch.checked < 3600) return;
	arch.checked = t;
	arch.on = cfg.archive_days > 0 && fs.lstat(RUNDIR)?.type == 'link';
	if (!arch.on) { arch.info = null; return; }
	if (!fs.stat(ARCH)) fs.mkdir(ARCH);
	let keep = arch_day(t - cfg.archive_days * 86400), days = {}, size = 0, oldest = null;
	for (let n in (fs.lsdir(ARCH) ?? [])) {
		let m = match(n, /^(ev|h)-([0-9]{8})\.jsonl$/);
		if (!m) continue;
		if (m[2] < keep) { fs.unlink(`${ARCH}/${n}`); continue; }
		days[m[2]] = true;
		size += fs.stat(`${ARCH}/${n}`)?.size ?? 0;
		if (oldest == null || m[2] < oldest) oldest = m[2];
	}
	arch.info = { days: cfg.archive_days, have: length(keys(days)), oldest, size };
}

/* ------------------------------------------------------------- the clock */

/*
 * Times in the log are only worth something with a synchronized clock.
 * After a reboot the router starts with the time of its newest file
 * (sysfixtime) until NTP sets it, so the first events of a boot can carry
 * a wrong time. Two sources:
 *   - the NTP client's own reports: /etc/hotplug.d/ntp/90-isp-tester notes
 *     every hotplug "ntp" event (busybox ntpd: stratum / step / unsync /
 *     periodic, chrony: stratum) in VARDIR/ntp.last and ntp.pending
 *   - a step of the clock itself: wall time minus monotonic time changes
 * Events logged by this run while the clock was not confirmed (shortly
 * after boot) are marked (_fix); when the clock is stepped they are moved by
 * the step, with the charts' points of this run, and only then written to
 * the archive. After an hour without a step they are kept as they are.
 */
let clk = { on: false, off: null, steps: 0, last: null, hold: [], run_hist: 0, run_min: 0, m0: 0 };
let ntp = { state: 'unknown', client: null, checked: 0, sync_ts: null, stratum: null, offset: null, poll: null, action: null };

function clk_fields(typ) {
	if (typ == 'data_gap') return [ 'd.to' ];
	if (typ == 'router_reboot') return [ 'ts', 'd.boot' ];
	return [ 'ts' ];
}

/*
 * Maintenance ("I am working on the network for 30 min"): events logged
 * meanwhile are kept but flagged (m: 1) - left out of the analysis, the
 * report's counts, the cards' "problems in the last minutes" and the
 * notifications, so re-plugging cables is not an outage. Kept in VARDIR, so
 * a collector restart (saving settings) does not end it.
 */
let maint = { until: null, since: null, note: '' };

function maint_on() {
	return maint.until != null && now() < maint.until;
}

/* store one event (own or received from the second router) */
function store_event(e) {
	if (maint_on() && e.type != 'maint_start' && e.type != 'maint_end') e.m = 1;
	if (e._fix) push(clk.hold, e);
	else arch_append('ev', e.ts, e);
	push(events, e);
	if (length(events) > cfg.max_events)
		events = slice(events, length(events) - cfg.max_events);
	notify_queue(e);
}

function emit(lvl, area, src, typ, data, ts) {
	let e = { ts: ts ?? now(), lvl, area, src, type: typ, d: data ?? {} };
	if (clk.on) e._fix = clk_fields(typ);
	store_event(e);

	save_events();
	peer_queue(e);
}

/* ----------------------------------------------------- reboots and gaps */

/*
 * "The router did not measure from X to Y": without it the ISP can say the
 * report is incomplete. The collector notes that it is alive once a minute
 * (alive.json in RUNDIR, so on USB it survives a reboot) with the kernel's
 * boot id. At start:
 *   - another boot id: the router restarted -> router_reboot (boot time from
 *     /proc/uptime) and data_gap from the last sign of life to now
 *   - same boot, a gap longer than a few intervals -> data_gap: monitoring
 *     was off (the init script marks a clean stop), or the collector died
 *   - data in RAM after a reboot: nothing survived, only router_reboot
 * While running: a tick that came far too late (blocked) -> data_gap.
 */
const ALIVE = `${RUNDIR}/alive.json`;
const STOPPED = `${VARDIR}/stopped`;
const BOOT_ID = trim(fs.readfile(`${PROC}/sys/kernel/random/boot_id`) ?? '') || null;
/* procd's watchdog timeout (set by the init script) */
const WATCHDOG = num(getenv('ISP_TESTER_WATCHDOG'), 60);
let alive_ts = 0;

function uptime_s() {
	return num(split(trim(fs.readfile(`${PROC}/uptime`) ?? ''), ' ')[0], null);
}

function alive_save(t) {
	alive_ts = t;
	write_atomic(ALIVE, sprintf('%J', { ts: t, boot_id: BOOT_ID, started, host: HOSTNAME }));
}

function gap_check() {
	let t = now(), up = uptime_s(), a;
	try { a = json(fs.readfile(ALIVE) || 'null'); } catch (e) { a = null; }
	let st;
	try { st = json(fs.readfile(`${VARDIR}/state.json`) || 'null'); } catch (e) { st = null; }
	let stop = num(trim(fs.readfile(STOPPED) ?? ''), null);
	fs.unlink(STOPPED);

	/* last sign of life: alive.json, the state of the same boot, own events */
	let last = (type(a?.ts) == 'int') ? a.ts : null;
	if (type(st?.ts) == 'int' && (last == null || st.ts > last)) last = st.ts;
	for (let i = length(events) - 1; i >= 0 && i >= length(events) - 50; i--)
		if (!events[i].host && events[i].ts <= t && (last == null || events[i].ts > last)) last = events[i].ts;

	let boot = (up != null) ? int(t - up) : null;
	let rebooted = (a?.boot_id && BOOT_ID) ? a.boot_id != BOOT_ID : (up != null && up < 900 && st == null);

	if (rebooted) {
		emit('warn', 'system', 'router', 'router_reboot', { boot, uptime: int(up ?? 0), last, ram: a == null }, boot ?? t);
		if (last != null)
			emit('info', 'system', 'collector', 'data_gap', { from: last, to: t, len: t - last, why: 'reboot', boot }, last);
	}
	else if (last != null) {
		/* same boot: stopped cleanly, or ended by itself / by the watchdog */
		let clean = stop != null && stop >= last - 5;
		/* the watchdog kills it WATCHDOG s after its last report */
		let why = clean ? 'stopped' : (st != null && t - st.ts >= WATCHDOG * 0.8) ? 'hung' : 'crash';
		if (!clean && st != null)
			emit('warn', 'system', 'collector', 'collector_restart', { why, last: st.ts, after: t - st.ts });
		if (t - last > cfg.interval * 3 + 30)
			emit('info', 'system', 'collector', 'data_gap', { from: last, to: t, len: t - last, why }, last);
	}
	alive_save(t);
}

/* procd's instance watchdog: report every tick; when the reports stop
 * (hung in a command), procd kills the collector and starts it again */
let wd = { err: null, last: 0, mode: null };

function watchdog_ping() {
	if (NO_UBUS || !getenv('ISP_TESTER_WATCHDOG')) return;
	try {
		ubus_conn ??= require('ubus').connect();
		let r = ubus_conn?.call('service', 'watchdog', { name: 'isp_tester', instance: 'instance1' });
		wd.mode = r?.mode;
		wd.last = now();
		wd.err = (r == null) ? 'no_answer' : null;
	}
	catch (e) {
		ubus_conn = null;
		wd.err = 'ubus';
	}
}

/* the cards show this router only: events of the second router (e.host)
 * are skipped; they may also be a bit older than the newest own event */
function recent_level(area, src) {
	let lvl = 'ok', cutoff = now() - cfg.warn_window;
	for (let i = length(events) - 1; i >= 0; i--) {
		let e = events[i];
		if (e.host || e.m) continue;
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
		if (e.host || e.m) continue;
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
	'iptv:kbps': 'avg', 'iptv:min': 'min', 'iptv:cc': 'sum', err: 'sum', drop: 'sum', lvl: 'max', maint: 'max', 'self:cpu': 'max' };

let agg = null;
let agg10 = null;     /* 10-minute aggregates for the archive */

function agg_mode(k) {
	return AGG_MODE[k] ?? AGG_MODE[split(k, ':')[0]] ?? 'avg';
}

function agg_vals(a) {
	let vals = {};
	for (let k, x in a.v) {
		switch (agg_mode(k)) {
		case 'max': vals[k] = x.max; break;
		case 'min': vals[k] = x.min; break;
		case 'sum': vals[k] = x.sum; break;
		default:    vals[k] = round(x.sum / x.n, 1);
		}
	}
	return vals;
}

function agg_put(a, vals) {
	for (let k, v in vals) {
		if (v == null) continue;
		let x = a.v[k] ??= { sum: 0, n: 0, min: v, max: v };
		x.sum += v;
		x.n++;
		if (v < x.min) x.min = v;
		if (v > x.max) x.max = v;
	}
}

function agg_flush() {
	if (!agg) return;
	if (clk.on) clk.run_min++;
	hist_add(history_min, agg.t, agg_vals(agg), cfg.long_history);
	write_atomic(`${RUNDIR}/history.json`, sprintf('%J', history_min));
	agg = null;
}

function agg_add(t, vals) {
	let m = t - t % 60;
	if (agg && agg.t != m) agg_flush();
	agg ??= { t: m, v: {} };
	agg_put(agg, vals);

	if (!arch.on) { agg10 = null; return; }
	let m10 = t - t % 600;
	if (agg10 && agg10.t != m10) {
		arch_append('h', agg10.t, { t: agg10.t, s: agg_vals(agg10) });
		agg10 = null;
	}
	agg10 ??= { t: m10, v: {} };
	agg_put(agg10, vals);
}

/* ------------------------------------------------------- the clock (2/2) */

function clk_shift_hist(h, n, by) {
	let len = length(h.t);
	for (let i = max(0, len - n); i < len; i++) h.t[i] += by;
}

/* the clock was stepped by `by` seconds: move what this run logged before */
function clk_fix(by) {
	let n = 0;
	for (let e in events) {
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
	clk_shift_hist(history, clk.run_hist, by);
	clk_shift_hist(history_min, clk.run_min, by);
	if (agg) agg.t += by;
	agg10 = null;
	started += by;
	alive_ts = 0;
	return n;
}

/* stop marking: write what was held back to the archive */
function clk_release() {
	for (let e in events) delete e._fix;
	for (let e in clk.hold) arch_append('ev', e.ts, e);
	clk.hold = [];
	clk.on = false;
	save_events();
	write_atomic(`${RUNDIR}/history.json`, sprintf('%J', history_min));
}

/* every tick, before anything is measured */
function clk_check() {
	let off = time() - mono();
	if (clk.off != null && absf(off - clk.off) >= 2.5) {
		let by = int(round(off - clk.off, 0));
		let n = clk.on ? clk_fix(by) : 0;
		clk.steps++;
		clk.last = { ts: now(), by };
		if (clk.on) clk_release();
		emit(absf(by) >= 60 ? 'warn' : 'info', 'system', 'clock', 'clock_step', { by, fixed: n, ntp: ntp.state });
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
		if (!quiet && was == 'synced') emit('warn', 'system', 'clock', 'ntp_unsync', { stratum: j.stratum });
		return;
	}
	ntp.state = 'synced';
	ntp.sync_ts = (type(j.ts) == 'int') ? j.ts : now();
	ntp.stratum = j.stratum;
	ntp.offset = j.offset;
	ntp.poll = j.poll;
	if (!quiet && was != 'synced')
		emit('info', 'system', 'clock', 'ntp_sync', { stratum: j.stratum, offset: j.offset, after: int(uptime_s() ?? 0) });
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
	let t = now();
	if (t - ntp.checked < 60) return;
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
		if (ntp.state != 'off') emit('warn', 'system', 'clock', 'ntp_off', {});
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
	let up = uptime_s() ?? 0;
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
	ntp.checked = 0;
	ntp_client();
	let up = uptime_s();
	/* shortly after boot and not confirmed yet: the clock may still be set */
	clk.on = ntp.state != 'synced' && up != null && up < 3600 && !getenv('ISP_TESTER_CONFIG') ||
		getenv('ISP_TESTER_CLOCKFIX') == '1';
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

/* mtr -r:  "  3.|-- 81.2.3.4   20.0%    10    5.1   5.3   4.9   6.0   0.3" */
function trace_parse_mtr(txt) {
	let hops = [];
	for (let l in split(txt ?? '', '\n')) {
		let m = match(l, /^ *([0-9]+)\.\|-- +([^ ]+) +([0-9.]+)%? +[0-9]+ +[0-9.]+ +([0-9.]+)/);
		if (!m) continue;
		let ip = (m[2] == '???') ? null : m[2];
		push(hops, { n: +m[1], ip, loss: round(+m[3], 0), avg: ip ? round(+m[4], 1) : null });
	}
	return hops;
}

/* traceroute -q 3: " 4  10.0.0.1  5.123 ms  *  5.301 ms" / " 5  * * *" */
function trace_parse_tr(txt) {
	let hops = [];
	for (let l in split(txt ?? '', '\n')) {
		let m = match(l, /^ *([0-9]+) +(.*)$/);
		if (!m) continue;
		let rest = m[2], ip = match(rest, /([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|[0-9A-Fa-f]*:[0-9A-Fa-f:]+)/);
		let stars = length(match(rest, /\*/g) ?? []), rtts = [];
		for (let x in (match(rest, /([0-9.]+) ms/g) ?? [])) push(rtts, +x[1]);
		let sent = stars + length(rtts);
		if (!sent) continue;
		let sum = 0;
		for (let r in rtts) sum += r;
		push(hops, { n: +m[1], ip: ip ? ip[1] : null, loss: round(stars * 100 / sent, 0),
			avg: length(rtts) ? round(sum / length(rtts), 1) : null });
	}
	return hops;
}

/* the first hop from which the loss carries on to the end */
function trace_judge(hops) {
	let r = { first_bad: null, bad_ip: null, last_good: null, good_ip: null, dest_loss: null };
	if (!length(hops)) return r;
	let last = hops[length(hops) - 1];
	r.dest_loss = last.loss;
	if (last.loss < 20) return r;          /* nothing lost to the end: the loss was over */
	let i = length(hops) - 1;
	while (i > 0 && hops[i - 1].loss >= 20) i--;
	/* a hop that never answers (???, * * *) is not where it starts: the next one that does */
	while (i < length(hops) - 1 && !hops[i].ip) i++;
	r.first_bad = hops[i].n;
	r.bad_ip = hops[i].ip;
	for (let j = i - 1; j >= 0; j--)
		if (hops[j].ip && hops[j].loss < 20) { r.last_good = hops[j].n; r.good_ip = hops[j].ip; break; }
	return r;
}

function trace_request(host, label, trig, trig_ts) {
	if (!cfg.wan.trace || trace.proc || (!MTR && !TRACEROUTE)) return;
	if (now() - trace.last < cfg.wan.trace_cooldown) return;
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
			emit('info', 'wan', label, 'trace', { host, tool, trig, err: substr(trim(txt), 0, 120) || `exit ${code}`, hops: [] }, t0);
			return;
		}
		let j = trace_judge(hops);
		emit(j.first_bad ? 'warn' : 'info', 'wan', label, 'trace',
			{ host, tool, trig, hops, ...j, dur: now() - t0, after: (trig_ts != null) ? t0 - trig_ts : null }, t0);
	});
	if (!p) return;
	trace.proc = p;
	/* never let a stuck trace block the next one */
	trace.timer = uloop.timer(60000, () => {
		trace.timer = null;
		if (trace.proc == p) { try { p.kill(); } catch (e) {} }
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

function median(a) {
	if (!length(a)) return null;
	let s = sort([ ...a ], (x, y) => x - y), n = length(s);
	return (n % 2) ? s[n >> 1] : (s[n / 2 - 1] + s[n / 2]) / 2;
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
	if (!cfg.wan.bloat || rx == null) return;
	push(bloat.ring, [ t, rx, tx ]);
	while (length(bloat.ring) && bloat.ring[0][0] < t - 900) shift(bloat.ring);

	/* line speed: a 30 s rate, so a burst or an uneven tick does not count; forgotten by ~8 %/day */
	let n = length(bloat.ring), w = 0, sr = 0, stx = 0;
	for (let i = n - 1; i >= 0 && bloat.ring[i][0] > t - 30; i--) { sr += bloat.ring[i][1]; stx += bloat.ring[i][2]; w++; }
	let dec = 0.99999 ** cfg.interval;
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
	let cap_rx = cfg.wan.down_mbit > 0 ? cfg.wan.down_mbit * 1e6 : bloat.peak_rx;
	let cap_tx = cfg.wan.up_mbit > 0 ? cfg.wan.up_mbit * 1e6 : bloat.peak_tx;
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
	let full = load * 100 >= cfg.wan.bloat_load;
	let add = (base != null) ? rtt - base : null;
	let bad = full && add != null && add >= cfg.wan.bloat_ms;
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
			emit('warn', 'wan', tg.label, 'bufferbloat', { host: tg.host, base: round(base, 1), rtt: round(rtt, 1),
				add: round(add, 0), load: bloat.last.load, dir, rx_mbit: round(cr / 1e6, 1), tx_mbit: round(ct / 1e6, 1),
				cap_rx_mbit: round(cap_rx / 1e6, 1), cap_tx_mbit: round(cap_tx / 1e6, 1),
				learned: !(cfg.wan.down_mbit > 0 && cfg.wan.up_mbit > 0) }, bloat.since);
		}
	}
	else {
		bloat.bad_n = 0;
		bloat.first = null;
		if (bloat.active && ++bloat.ok_n >= 2) {
			bloat.active = false;
			emit('info', 'wan', tg.label, 'bufferbloat_ok', { host: tg.host, dur: ts - bloat.since, max_add: round(bloat.max_add, 0) });
		}
	}
}

function bloat_out() {
	if (!cfg.wan.bloat) return null;
	let s = bloat.stat, base = median(bloat.idle);
	return {
		active: bloat.active, since: bloat.since, base: round(base, 1),
		idle_avg: s.idle_n ? round(s.idle_sum / s.idle_n, 1) : null,
		load_avg: s.load_n ? round(s.load_sum / s.load_n, 1) : null,
		idle_n: s.idle_n, load_n: s.load_n, bloat_n: s.bloat_n,
		cap_rx: round((cfg.wan.down_mbit > 0 ? cfg.wan.down_mbit * 1e6 : bloat.peak_rx) / 1000, 0),
		cap_tx: round((cfg.wan.up_mbit > 0 ? cfg.wan.up_mbit * 1e6 : bloat.peak_tx) / 1000, 0),
		learned: !(cfg.wan.down_mbit > 0 && cfg.wan.up_mbit > 0),
		last: bloat.last, ms: cfg.wan.bloat_ms, load_pct: cfg.wan.bloat_load
	};
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
let v6_down_since = null;

function check_wan_down() {
	let c4 = fam_count(4), c6 = fam_count(6);
	let c = c4.all ? c4 : c6;
	if (c.all) {
		if (c.failed == c.all && wan_down_since == null) {
			wan_down_since = now();
			emit('err', 'wan', 'wan', 'wan_down', {});
			let tt = trace_target(null, c4.all ? 4 : 6);
			if (tt) trace_request(tt.host, tt.label, 'wan_down', wan_down_since);
		}
		else if (c.failed < c.all && wan_down_since != null) {
			emit('warn', 'wan', 'wan', 'wan_up', { dur: now() - wan_down_since });
			wan_down_since = null;
		}
	}

	/* IPv6 alone: needs IPv4 targets that still answer */
	let v6bad = cfg.wan.ipv6 && c6.all > 0 && c6.failed == c6.all && c4.all > 0 && c4.failed < c4.all;
	if (v6bad && v6_down_since == null) {
		v6_down_since = now();
		emit('err', 'wan', 'ipv6', 'v6_down', { n: c6.all, pd: v6s.prefixes, route: v6s.route != null });
		let tt = trace_target(null, 6);
		if (tt) trace_request(tt.host, tt.label, 'v6_down', v6_down_since);
	}
	else if (!v6bad && v6_down_since != null && (c6.failed < c6.all || !c6.all)) {
		emit('warn', 'wan', 'ipv6', 'v6_up', { dur: now() - v6_down_since });
		v6_down_since = null;
	}
	else if (!v6bad && v6_down_since != null && c4.failed == c4.all) {
		/* now everything is down: that is the Internet outage, not IPv6 */
		v6_down_since = null;
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
				emit('info', 'wan', t.label, 'target_ok', { host, dur: t_now - t.since, loss: res.loss, rtt: res.rtt, fam });
			else
				emit(lvl == 'fail' ? 'err' : 'warn', 'wan', t.label, lvl == 'fail' ? 'target_fail' : 'target_degraded',
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

/* ------------------------------------------------- the tester's own load */

/*
 * Proof that measuring does not load the router (and is not what breaks
 * IPTV): CPU and RAM of the collector (with the commands it runs: logread,
 * bridge, rrdtool... - their time is added to it when they end) and of
 * tsmon, from /proc/<pid>/stat and status. CPU in % of the whole router
 * (all cores); USER_HZ is 100 on Linux.
 */
let selfu = { prev: null, tsm: null, start: null, cpu: null, max: 0, ncpu: null };

function pid_usage(pid, children) {
	let st = fs.readfile(`${PROC}/${pid}/stat`);
	if (!st) return null;
	let f = split(trim(substr(st, rindex(st, ')') + 2)), ' ');
	let ticks = int(f[11]) + int(f[12]) + (children ? int(f[13]) + int(f[14]) : 0);
	let rss = null;
	for (let l in split(fs.readfile(`${PROC}/${pid}/status`) ?? '', '\n')) {
		let m = match(l, /^VmRSS:\s+([0-9]+) kB/);
		if (m) { rss = int(m[1]); break; }
	}
	return { ticks, rss, m: mono() };
}

function cpu_pct(cur, prev) {
	if (!cur || !prev || cur.m <= prev.m || cur.ticks < prev.ticks) return null;
	return round((cur.ticks - prev.ticks) / (cur.m - prev.m) / (selfu.ncpu || 1), 2);
}

function sample_self() {
	if (selfu.ncpu == null) {
		let n = 0;
		for (let l in split(fs.readfile(`${PROC}/stat`) ?? '', '\n'))
			if (match(l, /^cpu[0-9]+ /)) n++;
		selfu.ncpu = n || 1;
	}
	let me = pid_usage('self', true);
	let c = cpu_pct(me, selfu.prev);
	selfu.prev = me;
	selfu.start ??= me;
	if (c != null) { selfu.cpu = c; if (c > selfu.max) selfu.max = c; }

	let tsm = null;
	if (tsq.proc) {
		let pid = int(tsq.proc.pid());
		let u = pid_usage(pid, false);
		if (u) {
			let p = (selfu.tsm?.pid == pid) ? selfu.tsm : null;
			let tc = cpu_pct(u, p);
			selfu.tsm = { ...u, pid, cpu: tc ?? p?.cpu, max: max(p?.max ?? 0, tc ?? 0) };
			tsm = { cpu: selfu.tsm.cpu, max: selfu.tsm.max, rss: u.rss };
		}
	}
	else selfu.tsm = null;

	let avg = cpu_pct(me, selfu.start);
	let total = (selfu.cpu ?? 0) + (tsm?.cpu ?? 0);
	return { cpu: selfu.cpu, avg, max: selfu.max, rss: me?.rss, tsmon: tsm, total: round(total, 2),
		rss_total: (me?.rss ?? 0) + (tsm?.rss ?? 0), ncpu: selfu.ncpu };
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
			emit('warn', 'wan', 'ipv6', 'v6_if_down', { iface, prev: v6s.prefixes });
		}
		else if (!v6s.up && up) {
			v6s.reconnects++;
			emit('info', 'wan', 'ipv6', 'v6_if_up', { iface, dur: t - v6s.since });
		}
	}
	if (up != v6s.up) v6s.since = t;

	if (up && v6s.up != null) {
		let had = v6s.prefixes ?? [];
		if (length(pd) && length(had) && join(' ', pd) != join(' ', had))
			emit('warn', 'wan', 'ipv6', 'v6_pd_change', { iface, from: had, to: pd });
		else if (!length(pd) && length(had) && v6s.pd_lost == null) {
			v6s.pd_lost = t;
			v6s.pd_prev = had;
			emit('warn', 'wan', 'ipv6', 'v6_pd_lost', { iface, prev: had });
		}
		if (length(pd) && v6s.pd_lost != null) {
			emit('info', 'wan', 'ipv6', 'v6_pd_back', { iface, dur: t - v6s.pd_lost, prefix: pd,
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
		if (!v6s.nr_logged && t - v6s.route_lost >= cfg.wan.ra_after) {
			v6s.nr_logged = true;
			emit('warn', 'wan', 'ipv6', 'v6_no_route', { iface, after: t - v6s.route_lost }, v6s.route_lost);
		}
	}
	if (gw != null) {
		if (v6s.nr_logged) emit('info', 'wan', 'ipv6', 'v6_route_back', { iface, dur: t - v6s.route_lost, gw });
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
	if (!cfg.wan.ipv6) return null;
	let c6 = fam_count(6), c4 = fam_count(4);
	let o = { iface: v6s.iface, found: v6s.found, up: v6s.up, since: v6s.since, uptime: v6s.uptime, proto: v6s.proto,
		prefixes: v6s.prefixes, addr: v6s.addr, route: v6s.route, pd_seen: v6s.pd_seen, route_seen: v6s.route_seen,
		pd_lost: v6s.pd_lost, route_lost: v6s.nr_logged ? v6s.route_lost : null, down: v6_down_since,
		targets: c6.all, targets_ok: c6.all - c6.failed, v4_targets: c4.all, reasons: [] };
	if (v6_down_since != null) push(o.reasons, { c: 'v6_down', since: v6_down_since });
	if (v6s.found && v6s.up === false && v6s.pd_seen) push(o.reasons, { c: 'v6_if_down', iface: v6s.iface, since: v6s.since });
	if (v6s.pd_lost != null) push(o.reasons, { c: 'v6_pd_lost', since: v6s.pd_lost });
	if (v6s.nr_logged) push(o.reasons, { c: 'v6_no_route', since: v6s.route_lost });
	return o;
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
		ubus_conn ??= require('ubus').connect();
		let sum = null;
		/* one object per dnsmasq instance */
		for (let o in ubus_objects(/^dnsmasq(\.|$)/)) {
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

function dnsmasq_pids() {
	let out = [];
	for (let pid in (fs.lsdir(PROC) ?? []))
		if (match(pid, /^[0-9]+$/) && trim(fs.readfile(`${PROC}/${pid}/comm`) ?? '') == 'dnsmasq') push(out, int(pid));
	return out;
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
		let worse = sent >= 10 && bad * 100 >= sent * cfg.dns.warn_pct;
		if (worse && !dns.srv_bad[k]) {
			dns.srv_bad[k] = true;
			emit('warn', 'wan', k, 'dns_server_bad', { server: k, ...s.d, lat: s.lat });
		}
		else if (!worse && dns.srv_bad[k] && sent >= 5) {
			delete dns.srv_bad[k];
			emit('info', 'wan', k, 'dns_server_ok', { server: k, ...s.d, lat: s.lat });
		}
	}
}

function sample_dns() {
	if (!cfg.dns.enabled) return null;
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
		if (!dns.bad && s.fwd >= cfg.dns.min_queries && pct >= cfg.dns.warn_pct) {
			dns.bad = true;
			/* from the first interval with unanswered queries */
			dns.since = (filter(dns.win, (x) => x.unans > 0)[0] ?? dns.win[0]).ts - cfg.interval;

			dns.max_pct = pct;
			emit('warn', 'wan', 'dns', 'dns_fail', { pct, fwd: s.fwd, unans: s.unans, win: DNS_WIN }, dns.since);
		}
		else if (dns.bad) {
			if (pct > dns.max_pct) dns.max_pct = pct;
			if (pct * 2 < cfg.dns.warn_pct || s.fwd == 0) {
				dns.bad = false;
				emit('info', 'wan', 'dns', 'dns_ok', { dur: t - dns.since, max_pct: dns.max_pct });
			}
		}
	}

	/* the per-server dump: needs the system log */
	if (cfg.logread && LOGREAD && cfg.dns.dump > 0 && t - dns.dump_ts >= cfg.dns.dump) {
		dns.dump_ts = t;
		dns.pids = dnsmasq_pids();
		for (let pid in dns.pids)
			system([ '/bin/sh', '-c', `kill -USR1 ${pid} 2>/dev/null` ]);
	}

	let srv = [];
	for (let k, x in dns.srv)
		push(srv, { server: k, sent: x.sent, retried: x.retried, failed: x.failed, lat: x.lat, ts: x.ts, d: x.d, bad: !!dns.srv_bad[k] });
	return { err: dns.err, unans: dns.has_unans, bad: dns.bad, since: dns.since, last: dns.last, servers: srv,
		dump: (cfg.logread && LOGREAD) ? cfg.dns.dump : 0, warn_pct: cfg.dns.warn_pct };
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

function maint_save() {
	write_atomic(`${VARDIR}/maint.json`, sprintf('%J', maint));
}

/* request from the web UI: start, extend or end the maintenance */
function handle_maint() {
	let t = now();
	if (maint.until != null && t >= maint.until) {
		emit('info', 'system', 'user', 'maint_end', { dur: maint.until - maint.since, note: maint.note });
		maint = { until: null, since: null, note: '' };
		maint_save();
	}
	let f = `${VARDIR}/maint.pending`;
	if (!fs.stat(f)) return;
	let r;
	try { r = json(fs.readfile(f) || 'null'); } catch (e) { r = null; }
	fs.unlink(f);
	if (type(r) != 'object') return;
	let min = int(+r.minutes || 0), note = substr(replace(`${r.note ?? ''}`, /[[:cntrl:]]+/g, ' '), 0, 120);
	if (min <= 0) {
		if (maint.until != null)
			emit('info', 'system', 'user', 'maint_end', { dur: t - maint.since, note: maint.note, early: true });
		maint = { until: null, since: null, note: '' };
	}
	else if (maint.until != null) {
		maint.until = t + min * 60;
		if (note) maint.note = note;
		emit('info', 'system', 'user', 'maint_start', { until: maint.until, note: maint.note, min, extend: true });
	}
	else {
		maint = { until: t + min * 60, since: t, note };
		emit('info', 'system', 'user', 'maint_start', { until: maint.until, note, min });
	}
	maint_save();
}

function maint_load() {
	let j;
	try { j = json(fs.readfile(`${VARDIR}/maint.json`) || 'null'); } catch (e) { j = null; }
	if (type(j?.until) == 'int' && type(j?.since) == 'int') maint = { until: j.until, since: j.since, note: `${j.note ?? ''}` };
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

/* ------------------------------------------------------- decoder DHCP */

/*
 * The decoders get their address from the operator: in the IPTV VLAN the
 * router only bridges, so their lease is nowhere in the router (no dnsmasq
 * lease, nothing in the system log). tsmon, which listens on that VLAN
 * anyway, notes the operator's DHCP replies (-D: OFFER, ACK, NAK; ACK with
 * the address, lease time, server). When the router itself gives the
 * decoders their address (routed IPTV), dnsmasq-dhcp's DHCPACK / DHCPNAK
 * lines in the system log are used for the decoders named in the settings.
 *   dhcp_lease      first lease seen (info)
 *   (renewal)       counted, not logged
 *   dhcp_new        an OFFER before the ACK: the decoder asked for an address
 *                   from scratch (restarted, or lost its lease)
 *   dhcp_ip_change  another address than before (warn)
 *   dhcp_nak        the server refused (warn)
 *   dhcp_late       renewed after the lease had run out (warn)
 *   dhcp_expired    lease ran out, no renewal seen, decoder still there (warn)
 */
let dhl = { pid: null, seq: 0, mac: {} };
/* decoders seen in the IPTV VLAN (see dec_poll) */
let dec = { list: {}, err: null, t: 0 };

function dhcp_src(mac) {
	return cfg.iptv.dec_labels[mac] || mac;
}

function dhcp_seen(x, via) {
	let mac = lc(`${x.mac ?? ''}`);
	if (!match(mac, /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/)) return;
	let t = (type(x.t) == 'int' && x.t > 0) ? x.t : now();
	let s = dhl.mac[mac] ??= { mac, ip: null, acks: 0, renew: 0, changes: 0, naks: 0, offer_t: null, last_ack: null,
		lease: null, server: null, expired: false, via };
	let src = dhcp_src(mac);
	s.via = via;
	if (x.type == 2) { s.offer_t = t; return; }
	if (x.type == 6) {
		s.naks++;
		emit('warn', 'iptv', src, 'dhcp_nak', { mac, ip: s.ip, server: x.server, via });
		return;
	}
	if (x.type != 5 || !match(`${x.ip ?? ''}`, /^[0-9.]+$/) || x.ip == '0.0.0.0') return;
	let fresh = s.offer_t != null && t - s.offer_t <= 15;
	s.offer_t = null;
	if (s.ip == null)
		emit('info', 'iptv', src, 'dhcp_lease', { mac, ip: x.ip, lease: x.lease, server: x.server, router: x.router, via });
	else if (x.ip != s.ip) {
		s.changes++;
		emit('warn', 'iptv', src, 'dhcp_ip_change', { mac, from: s.ip, to: x.ip, lease: x.lease, server: x.server, via });
	}
	else if (s.lease && s.last_ack != null && t - s.last_ack > s.lease + 5) {
		s.renew++;
		emit('warn', 'iptv', src, 'dhcp_late', { mac, ip: x.ip, late: t - s.last_ack - s.lease, lease: s.lease, via });
	}
	else if (fresh)
		emit('info', 'iptv', src, 'dhcp_new', { mac, ip: x.ip, lease: x.lease, via });
	else s.renew++;
	s.acks++;
	s.ip = x.ip;
	s.last_ack = t;
	s.lease = (x.lease > 0) ? x.lease : null;
	s.server = x.server ?? s.server;
	s.expired = false;
}

/* new entries of tsmon's DHCP ring (numbered per helper process) */
function dhcp_ingest(r) {
	if (!cfg.iptv.dhcp || type(r?.dhcp) != 'array') return;
	if (r.pid != dhl.pid) { dhl.pid = r.pid; dhl.seq = 0; }
	for (let x in r.dhcp) {
		if (type(x?.seq) != 'int' || x.seq <= dhl.seq) continue;
		dhl.seq = x.seq;
		dhcp_seen(x, 'vlan');
	}
}

/* routed IPTV: "DHCPACK(br-iptv) 10.1.2.3 aa:bb:cc:dd:ee:ff name" */
function dhcp_log_line(l) {
	let m = match(l.msg, /^DHCP(ACK|NAK)\([^)]*\) ([0-9.]+) ([0-9a-fA-F:]{17})/);
	if (!m) return false;
	let mac = lc(m[3]);
	if (cfg.iptv.dec_labels[mac] == null) return true;
	dhcp_seen({ t: l.ts, type: m[1] == 'ACK' ? 5 : 6, mac, ip: m[2] }, 'dnsmasq');
	return true;
}

function dhcp_tick() {
	if (!cfg.iptv.dhcp) return null;
	let t = now(), out = [];
	for (let mac, s in dhl.mac) {
		let d = dec.list[mac];
		if (s.lease && s.last_ack != null && !s.expired && t - s.last_ack > s.lease + 30 && d?.present !== false) {
			s.expired = true;
			emit('warn', 'iptv', dhcp_src(mac), 'dhcp_expired', { mac, ip: s.ip, lease: s.lease, last: s.last_ack });
		}
		push(out, { mac, label: cfg.iptv.dec_labels[mac] ?? '', ip: s.ip, lease: s.lease, server: s.server, last_ack: s.last_ack,
			acks: s.acks, renew: s.renew, changes: s.changes, naks: s.naks, expired: s.expired, via: s.via });
	}
	return out;
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
	[ /^odhcp6c$/, /Failed to send|timed out|[Nn]o (prefix|address)|NoPrefixAvail|NoAddrsAvail/, 'dhcp6_fail', 'warn', 'wan' ],
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

		if (l.prog == 'dnsmasq' && cfg.dns.enabled && dns_log_line(l)) continue;
		if (l.prog == 'dnsmasq-dhcp' && cfg.iptv.dhcp && dhcp_log_line(l)) continue;
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

/* ------------------------------------------------------------- decoders */

/*
 * Decoder restarts, so "the decoder restarted" is not taken for "the
 * stream vanished". In a bridged IPTV VLAN the decoders get their address
 * from the ISP, so the router has no neighbour entry for them; what it has
 * is the bridge's MAC table (bridge -s fdb: which MAC is behind which port,
 * and how many seconds ago a frame came from it). Every MAC learned in the
 * IPTV VLAN on a port other than the one to the ISP is a decoder; names
 * come from the settings. Signals, strongest first:
 *   link  - the port it is on went down (decoder directly on the port)
 *   fdb   - its entry vanished from the table and came back
 *   quiet - nothing from it for dec_silence s while the stream it watched
 *           stopped, then frames again (behind a switch the port stays up)
 * Back within dec_off s: decoder_restart; longer: decoder_off / decoder_on.
 */

/* MAC -> { port, age } of the decoders in the IPTV VLAN */
function dec_fdb() {
	let j = bridge_json(`-s fdb show br ${vl.bridge}`);
	if (j == null) return null;
	let out = {};
	for (let e in j) {
		let mac = lc(`${e?.mac ?? ''}`);
		if (!match(mac, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/)) continue;
		/* multicast / local entries, other VLANs, the ISP side */
		if (hex(substr(mac, 0, 2)) & 1) continue;
		if (e.state == 'permanent' || e.state == 'static' || index(e.flags ?? [], 'self') >= 0) continue;
		if (e.master && e.master != vl.bridge) continue;
		if (e.vlan != null && e.vlan != cfg.iptv.vlan) continue;
		if (!valid_dev(e.ifname) || e.ifname == vl.upstream || index(vl.ports, e.ifname) < 0) continue;
		out[mac] = { port: e.ifname, age: (type(e.updated) == 'int') ? e.updated : null };
	}
	return out;
}

/* did the stream stop (freeze, lost, off) between from and to? */
function dec_stream_hit(from, to) {
	for (let i = length(events) - 1; i >= 0; i--) {
		let e = events[i];
		if (e.host) continue;
		if (e.ts < from - 60) break;
		if (e.area == 'iptv' && e.ts >= from - 10 && e.ts <= to + 5 &&
		    (e.type == 'stream_stall' || e.type == 'stream_off' || e.type == 'stream_lost')) return true;
	}
	return false;
}

function dec_poll() {
	if (!cfg.iptv.decoders || !cfg.iptv.vlan || !vl.bridge || !BRIDGE) { dec.err = null; return null; }
	let fdb = dec_fdb(), t = now();
	if (fdb == null) { dec.err = 'fdb_failed'; return null; }
	dec.err = null;

	for (let mac, x in fdb) {
		let d = dec.list[mac] ??= { mac, present: true, since: t, port: x.port, gone_at: null, quiet_from: null, off: false };
		d.port = x.port;
		d.seen = t;
	}
	for (let mac, d in dec.list) {
		let x = fdb[mac], src = cfg.iptv.dec_labels[mac] || mac;
		let link = rd(d.port, 'carrier');
		let here = x != null && link != '0';
		let active = here ? t - (x.age ?? 0) : null;

		if (!here) {
			if (d.present) {
				d.present = false;
				/* the last frame, not the moment the entry aged out */
				d.gone_at = (link == '0') ? t : (d.last_active ?? t);
				d.via = (link == '0') ? 'link' : 'fdb';
			}
			if (!d.off && t - d.gone_at > cfg.iptv.dec_off) {
				d.off = true;
				emit('info', 'iptv', src, 'decoder_off', { mac, port: d.port, via: d.via }, d.gone_at);
			}
		}
		else {
			if (!d.present) {
				let dur = max(1, t - d.gone_at);
				if (d.off) emit('info', 'iptv', src, 'decoder_on', { mac, port: x.port, dur });
				else emit('info', 'iptv', src, 'decoder_restart', { mac, port: x.port, dur, via: d.via,
					stream: dec_stream_hit(d.gone_at, t) }, d.gone_at);
				d.present = true;
				d.off = false;
				d.since = t;
				d.quiet_from = null;
			}
			/* quiet: a restart behind a switch, only when the stream stopped meanwhile */
			else if (x.age != null) {
				if (x.age >= cfg.iptv.dec_silence) d.quiet_from ??= active;
				else if (d.quiet_from != null) {
					let dur = active - d.quiet_from;
					if (dur >= cfg.iptv.dec_silence && dur <= cfg.iptv.dec_off && dec_stream_hit(d.quiet_from, active))
						emit('info', 'iptv', src, 'decoder_restart', { mac, port: x.port, dur, via: 'quiet', stream: true }, d.quiet_from);
					d.quiet_from = null;
				}
			}
			d.last_active = active;
		}
		/* auto-found and gone for a day: forget it */
		if (!here && cfg.iptv.dec_labels[mac] == null && t - (d.seen ?? t) > 86400) delete dec.list[mac];
	}

	let out = [];
	for (let mac, d in dec.list) {
		let chs = [];
		for (let m in (vl.mdb ?? [])) if (m.port == d.port && index(chs, m.grp) < 0) push(chs, m.grp);
		push(out, { mac, label: cfg.iptv.dec_labels[mac] ?? '', port: d.port, present: d.present, off: d.off,
			since: d.present ? d.since : d.gone_at, active: d.last_active, quiet: d.quiet_from != null,
			groups: slice(chs, 0, 4) });
	}
	return sort(out, (a, b) => (a.port < b.port) ? -1 : (a.port > b.port) ? 1 : 0);
}

/* ------------------------------------------------------------------ IPTV */

const TSQ_STATE = `${VARDIR}/tsmon.json`;
const TSQ_WIN = 60;          /* s: thresholds count the errors of the last minute */
const TSQ_DROP_SHOW = 600;   /* s: how long packets the router dropped are shown */

/* state of the picture quality measurement, for the status page */
function tsq_out() {
	return { error: tsq.err, running: tsq.proc != null, since: tsq.proc ? tsq.started : null,
		window: TSQ_WIN, warn: cfg.iptv.q_warn, fail: cfg.iptv.q_fail, last: tsq.last,
		dropped: tsq.dropped, drop_ts: tsq.drop_ts || null };
}

function iptv_on() {
	return cfg.iptv.enabled && (cfg.iptv.device || cfg.iptv.vlan);
}

function iptv_fast() {
	return iptv_on() && cfg.iptv.sample_interval > 0;
}

/* ------------------------------------------------- IPTV channel names */

/* where the helper listens: the ISP-side port of the IPTV VLAN, or the
 * configured device (the decoder port is measured outgoing) */
function tsq_target() {
	if (cfg.iptv.vlan) {
		if (!valid_dev(vl.upstream)) return null;
		return { dev: vl.upstream, vid: cfg.iptv.vlan, dir: 'in' };
	}
	if (!valid_dev(cfg.iptv.device)) return null;
	return { dev: cfg.iptv.device, vid: 0, dir: cfg.iptv.direction == 'tx' ? 'out' : 'in' };
}

/*
 * The name of each channel is in the stream itself (DVB SDT table, read by
 * the helper for every group that flows, see tsm_poll). Names set by hand in
 * the settings win. Learned names are kept in RUNDIR, so with data_dir they
 * survive a reboot.
 */
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
		sort(ks, (a, b) => (chn.db[a].ts ?? 0) - (chn.db[b].ts ?? 0));
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
 *   1. the joined group the helper sees carrying the stream right now (the
 *      busiest one, when two decoders watch)
 *   2. without the helper: the newest join seen since the collector started
 *   3. the only joined group
 */
function chn_current() {
	let gs = igmp.groups ?? [];
	if (!length(gs)) return null;

	let f = tsq.flow;
	if (f && now() - f.ts <= 30) {
		let best = null;
		for (let e in f.groups)
			if ((e.idle ?? 0) <= 5 && index(gs, e.grp) >= 0 && (best == null || (e.kbps ?? 0) > (best.kbps ?? 0))) best = e;
		if (best) return best.grp;
	}

	let best = null;
	for (let g in gs) {
		let t = igmp.joined[g] ?? 0;
		if (t > 0 && (best == null || t > igmp.joined[best])) best = g;
	}
	if (best) return best;
	return length(gs) == 1 ? gs[0] : null;
}

/* names found in the streams (helper groups with .svc) */
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

/* a stream that has played a while without a name: remember why */
function chn_missing(grp, why) {
	let e = chn.db[grp];
	if (e?.name || e?.why == why) return;
	chn.db[grp] = { name: null, why, ts: now() };
	chn_save();
}

/* names for the groups shown on the status page */
function chn_out(o) {
	let want = {};
	for (let g in (igmp.groups ?? [])) want[g] = true;
	for (let e in (o.bridge?.mdb ?? [])) want[e.grp] = true;
	for (let e in (tsq.flow?.groups ?? [])) want[e.grp] = true;
	let names = {};
	for (let g in want) {
		let man = cfg.iptv.channels[g], e = chn.db[g];
		if (man) names[g] = { name: man, src: 'manual' };
		else if (e?.name) names[g] = { name: e.name, provider: e.provider, src: 'sdt' };
		else if (e) names[g] = { name: null, why: e.why };
	}
	return { enabled: cfg.iptv.names, error: chn.err, names };
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

	/* picture quality: yellow for a while after errors, or when it cannot run */
	if (cfg.iptv.quality) {
		if (tsq.err) {
			level = worst(level, 'warn');
			push(reasons, { c: 'ts_' + tsq.err });
		}
		else if (recent_level('iptv', 'quality') != 'ok') {
			level = worst(level, 'warn');
			push(reasons, { c: 'ts_errors' });
		}
		if (tsq.drop_ts && now() - tsq.drop_ts < TSQ_DROP_SHOW) {
			level = worst(level, 'warn');
			push(reasons, { c: 'ts_drops' });
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
		if (igmp.proxy == null && igmp.proxy_seen) {
			level = worst(level, 'warn');
			push(reasons, { c: 'proxy_down', name: igmp.last_name });
			o.level = level;
		}
	}
	o.channels = chn_out(o);
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
 * OpenWrt counts them, so this is the second own measurement. The helper
 * isp-tester-tsmon (C) listens on the IPTV port all the time, with a kernel
 * filter that passes only the IPTV multicast, counts every packet as it
 * arrives and writes cumulative counters per group to TSQ_STATE once a
 * second. Here the counters are read every tick: what changed since the last
 * read are the new errors, the thresholds count those of the last minute.
 * The measured channel is whichever group carries TS, i.e. the one being
 * watched; no group is picked from IGMP. The same helper reads the channel
 * names (DVB SDT) of every group that flows.
 * Packets the router itself dropped before the helper saw them (busy CPU) are
 * reported separately and never counted as errors of the ISP.
 */

function tsm_want() {
	return iptv_on() && (cfg.iptv.quality || cfg.iptv.names || (cfg.iptv.dhcp && cfg.iptv.vlan));
}

function tsm_args(tg) {
	let a = [ '-i', tg.dev, '-d', tg.dir, '-g', `${max(0, cfg.iptv.q_gap)}`, '-o', TSQ_STATE ];
	if (tg.vid) push(a, '-v', `${int(tg.vid)}`);
	if (cfg.iptv.dhcp) push(a, '-D');
	return join(' ', a);
}

function tsm_stop() {
	let p = tsq.proc;
	tsq.proc = null;
	tsq.args = null;
	tsq.seen = {};
	tsq.drops = null;
	tsq.flow = null;
	if (p) system([ '/bin/sh', '-c', `kill ${int(p.pid())} 2>/dev/null` ]);
	fs.unlink(TSQ_STATE);
}

function tsm_start(tg) {
	let args = tsm_args(tg);
	fs.unlink(TSQ_STATE);
	/* valid_dev() keeps the arguments free of shell characters; the helper
	 * ends by itself when the collector ends */
	let cmd = `N=; command -v nice >/dev/null 2>&1 && N='nice -n 5'; exec $N ${TSMON} ${args}`;
	let p;
	p = uloop.process('/bin/sh', [ '-c', cmd ], null, (code) => {
		if (tsq.proc != p) return;
		tsq.proc = null;
		tsq.args = null;
		tsq.seen = {};
		tsq.drops = null;
		tsq.fails++;
		tsq.err = 'helper_failed';
		/* 10 s, 20 s, 40 s ... at most 5 min between restarts */
		let wait = min(300, 10 * (2 ** min(tsq.fails - 1, 5)));
		tsq.next = now() + wait;
		warn(`isp-tester: ${TSMON} ended (exit ${code}), starting again in ${wait} s\n`);
	});
	if (!p) {
		tsq.err = 'helper_failed';
		tsq.next = now() + 60;
		return;
	}
	tsq.proc = p;
	tsq.args = args;
	tsq.started = now();
	tsq.drops = 0;
}

/* level of one group from its errors in the last minute */
function tsq_level(s) {
	let bad = s.cc + s.tei;
	if (bad >= cfg.iptv.q_fail) return 'err';
	if (bad >= cfg.iptv.q_warn || (cfg.iptv.q_gap > 0 && s.gaps > 0)) return 'warn';
	return 'ok';
}

function tsm_read() {
	let r;
	try { r = json(fs.readfile(TSQ_STATE) || 'null'); } catch (e) { r = null; }
	let t = now();
	/* not written yet, by an old helper, or not updated any more: a hung
	 * helper is stopped and started again */
	let ours = type(r?.groups) == 'array' && r.pid == tsq.proc.pid();
	let age = t - max(ours ? (r.ts ?? 0) : 0, tsq.started);
	if (age > 90) {
		warn(`isp-tester: ${TSMON} does not update ${TSQ_STATE}, restarting it\n`);
		tsm_stop();
		tsq.err = 'helper_stalled';
		tsq.next = t + 10;
		return;
	}
	if (age > 30) tsq.err = 'helper_stalled';
	if (!ours || age > 30) return;
	tsq.err = null;
	if (t - tsq.started > 120) tsq.fails = 0;
	dhcp_ingest(r);

	/* the socket overflowed: this router could not keep up, so lost packets
	 * in this interval may be its own, not the ISP's */
	let ddrop = (tsq.drops != null && r.drops >= tsq.drops) ? r.drops - tsq.drops : 0;
	tsq.drops = r.drops;
	if (ddrop > 0) {
		tsq.dropped += ddrop;
		tsq.drop_ts = t;
	}

	/* what flows now, for the current channel (also without the quality) */
	tsq.flow = { ts: t, groups: map(filter(r.groups, (g) => valid_group(g?.grp)),
		(g) => ({ grp: g.grp, kbps: g.kbps, idle: g.idle })) };

	let seen = {}, list = [], fresh = [];
	tsq.win = filter(tsq.win, (e) => t - e.ts < TSQ_WIN);
	for (let g in r.groups) {
		if (!valid_group(g?.grp)) continue;
		let key = `${r.pid}:${g.id}`;
		let p = tsq.seen[key] ?? { cc: 0, lost: 0, tei: 0, gaps: 0, rtp_lost: 0 };
		let d = {}, c = {};
		for (let k in [ 'cc', 'lost', 'tei', 'gaps', 'rtp_lost' ]) {
			c[k] = g[k] ?? 0;
			d[k] = max(0, c[k] - p[k]);
		}
		seen[key] = c;

		if (cfg.iptv.names) {
			if (g.svc?.name) chn_learn([ g ]);
			else if ((g.age ?? 0) >= 15) chn_missing(g.grp, g.psi?.sdt ? 'no_service' : 'no_sdt');
		}
		if (!cfg.iptv.quality) continue;

		push(list, g);
		if (ddrop == 0 && (d.cc + d.tei + (cfg.iptv.q_gap > 0 ? d.gaps : 0)) > 0) {
			push(tsq.win, { ts: t, grp: g.grp, cc: d.cc, tei: d.tei, lost: d.lost, gaps: d.gaps,
				gap: d.gaps ? (g.gap_last_ms ?? 0) : 0 });
			push(fresh, { g, d });
			tsq.cc_acc = (tsq.cc_acc ?? 0) + d.cc + d.tei;
		}
	}
	tsq.seen = seen;
	if (!cfg.iptv.quality) return;

	/* the last minute per group */
	let sum = {};
	for (let e in tsq.win) {
		let s = sum[e.grp] ??= { cc: 0, tei: 0, lost: 0, gaps: 0, gap: 0 };
		s.cc += e.cc; s.tei += e.tei; s.lost += e.lost; s.gaps += e.gaps;
		if (e.gap > s.gap) s.gap = e.gap;
	}

	let out = [];
	for (let g in list) {
		let s = sum[g.grp] ?? { cc: 0, tei: 0, lost: 0, gaps: 0, gap: 0 };
		/* streams that stopped (zapped away) are only kept while they have errors */
		if ((g.idle ?? 0) > 5 && !(s.cc + s.tei + s.gaps)) continue;
		push(out, { grp: g.grp, ch: chn_name(g.grp), kbps: g.kbps, pps: g.pps, cc: s.cc, tei: s.tei, lost: s.lost,
			gap: s.gap, gap_max: g.gap_max_ms, rtp_lost: g.rtp ? g.rtp_lost : null, total: (g.cc ?? 0) + (g.tei ?? 0),
			age: g.age, lvl: tsq_level(s) });
	}
	tsq.last = { ts: t, up: r.up, groups: out };

	/* events: new errors join the group's pending event; it is written when
	 * the cooldown allows it, or at once when the level gets worse */
	for (let x in fresh) {
		let g = x.g, d = x.d, s = sum[g.grp];
		let lvl = tsq_level(s);
		if (lvl == 'ok') continue;
		let p = tsq.pend[g.grp] ??= { cc: 0, lost: 0, tei: 0, gaps: 0, gap: 0, since: t - cfg.interval, lvl: 'ok' };
		p.cc += d.cc;
		p.tei += d.tei;
		p.lost += d.lost;
		p.gaps += d.gaps;
		if (s.gap > p.gap) p.gap = s.gap;
		p.lvl = worst(p.lvl, lvl);
		p.kbps = g.kbps;
	}
	for (let grp, p in tsq.pend) {
		if (t - (tsq.last_ev[grp] ?? 0) < cfg.err_cooldown && LEVEL[p.lvl] <= LEVEL[tsq.last_lvl[grp] ?? 'ok'])
			continue;
		/* the event's own level comes from what it reports (the minute's
		 * level only decides when it is written) */
		emit(worst('warn', tsq_level(p)), 'iptv', 'quality', 'ts_errors', { grp, ch: chn_name(grp), cc: p.cc, lost: p.lost, tei: p.tei,
			gap: p.gap, win: round(t - p.since, 0), kbps: p.kbps }, t);
		tsq.last_ev[grp] = t;
		tsq.last_lvl[grp] = p.lvl;
		delete tsq.pend[grp];
	}
	/* a level reached long ago does not hold back the next event */
	for (let grp in keys(tsq.last_lvl))
		if (t - tsq.last_ev[grp] >= cfg.err_cooldown) { delete tsq.last_lvl[grp]; delete tsq.last_ev[grp]; }
}

/* every tick: keep the helper running where it should, and read it */
function tsm_poll() {
	if (!tsm_want()) {
		if (tsq.proc) tsm_stop();
		tsq.err = chn.err = null;
		return;
	}
	if (!TSMON) {
		tsq.err = chn.err = 'no_helper';
		return;
	}
	let tg = tsq_target();
	if (!tg) {
		if (tsq.proc) tsm_stop();
		tsq.err = chn.err = 'no_target';
		return;
	}
	/* the ISP-side port of the VLAN changed */
	if (tsq.proc && tsq.args != tsm_args(tg)) tsm_stop();
	if (!tsq.proc) {
		if (now() >= tsq.next) tsm_start(tg);
		chn.err = (tsq.err == 'helper_failed') ? tsq.err : null;
		return;
	}
	tsm_read();
	chn.err = tsq.err;
}

/* ------------------------------------------------- second router (2/2) */

function peer_pack(o) {
	let j = sprintf('%J', o);
	return hmac(j) + j;
}

/* null unless signed with our key */
function peer_unpack(data) {
	if (type(data) != 'string' || length(data) < 66) return null;
	let j = substr(data, 64);
	if (hmac(j) != substr(data, 0, 64)) return null;
	let o;
	try { o = json(j); } catch (e) { return null; }
	return (type(o) == 'object' && o.v == PEER_VER) ? o : null;
}

/* an event small enough for one datagram (traceroute hops are cut) */
function peer_fit(x) {
	if (length(sprintf('%J', x)) <= PEER_MAXPKT - 250) return x;
	let d = {};
	for (let k, v in x.e.d) {
		if (type(v) == 'string') d[k] = substr(v, 0, 120);
		else if (type(v) == 'array') d[k] = slice(v, 0, 8);
		else if (type(v) != 'object') d[k] = v;
	}
	let e = { ...x.e, d };
	if (length(sprintf('%J', e)) > PEER_MAXPKT - 250) e.d = { cut: true };
	return { q: x.q, e };
}

/* sender: everything not acknowledged yet (and the status, once per tick) */
function peer_flush(hb) {
	if (!peer.sk || cfg.peer.role != 'send') return;
	let dst = { address: cfg.peer.host, port: cfg.peer.port };
	let base = { v: PEER_VER, h: HOSTNAME, ep: peer.ep, now: now(), iv: cfg.interval };
	let i = 0, pkts = 0;
	while (pkts < 8) {
		let o = { ...base, ev: [] };
		if (hb && pkts == 0) o.hb = hb;
		while (i < length(peer.out)) {
			push(o.ev, peer_fit(peer.out[i]));
			if (length(o.ev) > 1 && length(sprintf('%J', o)) > PEER_MAXPKT) { pop(o.ev); break; }
			i++;
		}
		if (!length(o.ev) && !o.hb) break;
		if (peer.sk.send(peer_pack(o), 0, dst) == null) peer.send_err = now();
		pkts++;
		if (i >= length(peer.out)) break;
	}
	peer.last_send = now();
}

/* sender: the receiver stored everything up to o.ack */
function peer_acked(o) {
	if (o.ep != peer.ep || o.to != HOSTNAME) return;
	let q = int(o.ack);
	peer.out = filter(peer.out, (x) => x.q > q);
	peer.last_ack = now();
	peer.send_err = null;
}

/* receiver: what the sender reports about itself, size-limited */
function peer_hb_clean(hb) {
	if (type(hb) != 'object' || length(sprintf('%J', hb)) > 1200) return null;
	return { ...hb, lvl: (LEVEL[hb.lvl] != null) ? hb.lvl : 'unknown' };
}

/* receiver: an event as received, made safe to store */
function peer_event(x, host, off) {
	if (type(x) != 'object') return null;
	let lvl = `${x.lvl}`, area = `${x.area}`, typ = `${x.type}`;
	if (LEVEL[lvl] == null || !match(area, /^[a-z]{1,12}$/) || !match(typ, /^[a-z_]{1,32}$/)) return null;
	let d = (type(x.d) == 'object' && length(sprintf('%J', x.d)) <= PEER_MAXPKT) ? x.d : {};
	let e = { ts: int(+x.ts || now()) + off, lvl, area, src: substr(`${x.src ?? ''}`, 0, 64), type: typ, d, host };
	if (off) e.skew = off;
	/* logged during maintenance on the second router */
	if (x.m) e.m = 1;
	return e;
}

function peer_save() {
	let o = {};
	for (let n, p in peer.peers) o[n] = { ep: p.ep, last: p.last, seen: p.seen, lost_at: p.lost_at, online: p.online };
	write_atomic(`${VARDIR}/peers.json`, sprintf('%J', o));
}

function peer_load() {
	let j;
	try { j = json(fs.readfile(`${VARDIR}/peers.json`) || '{}'); } catch (e) { j = null; }
	for (let n, p in (type(j) == 'object' ? j : {}))
		if (type(p) == 'object')
			peer.peers[n] = { name: n, ep: int(p.ep ?? 0), last: int(p.last ?? 0), seen: p.seen ?? 0,
				lost_at: p.lost_at, online: !!p.online, hb: null };
}

/* receiver: one datagram from the second router */
function peer_ingest(o, addr) {
	let name = `${o.h ?? ''}`;
	if (!match(name, /^[A-Za-z0-9._-]{1,32}$/) || name == HOSTNAME) return;
	let t = now();
	let p = peer.peers[name] ??= { name, ep: 0, last: 0, seen: 0, online: false, hb: null };
	let ep = int(+o.ep || 0);
	if (ep < p.ep) return;              /* an older run of the sender (replayed) */
	if (ep != p.ep) { p.ep = ep; p.last = 0; }

	let off = (type(o.now) == 'int') ? t - o.now : 0;
	if (off >= -5 && off <= 5) off = 0;
	if (!p.online && p.lost_at)
		emit('info', 'system', name, 'peer_back', { dur: t - p.lost_at, addr: addr?.address });
	p.online = true;
	p.lost_at = null;
	p.seen = t;
	p.off = off;
	p.iv = (type(o.iv) == 'int' && o.iv > 0) ? o.iv : 10;
	p.addr = addr?.address;
	if (o.hb) p.hb = peer_hb_clean(o.hb);

	let added = 0;
	for (let x in (type(o.ev) == 'array' ? o.ev : [])) {
		let q = int(+x?.q || 0);
		if (q <= p.last) continue;
		let e = peer_event(x.e, name, off);
		p.last = q;
		if (!e) continue;
		store_event(e);
		added++;
	}
	if (added) save_events();

	if (addr?.address && addr?.port)
		peer.sk.send(peer_pack({ v: PEER_VER, ack: p.last, ep: p.ep, to: name, now: t }), 0,
			{ address: addr.address, port: addr.port });
	peer_save();
}

function peer_recv() {
	for (let i = 0; i < 64; i++) {
		let addr = {};
		let data = peer.sk.recv(4096, peer.socket.MSG_DONTWAIT, addr);
		if (data == null || data == '') break;
		let o = peer_unpack(data);
		if (!o) {
			/* wrong key, or not ours */
			peer.bad++;
			peer.bad_addr = addr.address;
			peer.bad_ts = now();
			continue;
		}
		if (cfg.peer.role == 'send') { if (o.ack != null) peer_acked(o); }
		else if (o.ack == null) peer_ingest(o, addr);
	}
}

/* open the socket (after uloop.init) */
function peer_start() {
	if (cfg.peer.role == 'off' || cfg.peer.err) return;
	if (!hmac_init(cfg.peer.key)) { cfg.peer.err = 'no_digest'; return; }
	let socket;
	try { socket = require('socket'); } catch (e) { cfg.peer.err = 'no_socket_module'; return; }
	let sk = socket.create(socket.AF_INET, socket.SOCK_DGRAM);
	if (!sk) { cfg.peer.err = 'socket'; return; }
	if (cfg.peer.role == 'receive') {
		try { sk.setopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); } catch (e) {}
		if (!sk.bind({ family: socket.AF_INET, address: '0.0.0.0', port: cfg.peer.port })) {
			sk.close();
			cfg.peer.err = 'bind';
			return;
		}
		peer_load();
	}
	peer.sk = sk;
	peer.socket = socket;
	peer.ep = started;
	peer.h = uloop.handle(sk, () => {
		try { peer_recv(); }
		catch (e) { warn(`isp-tester: peer receive failed: ${e}\n`); }
	}, uloop.ULOOP_READ);
	peer_flush_fn = peer_flush;
}

/* sender: short status of this router for the receiver's view */
function peer_hb(overall, iptv_res, ports, wifi_res) {
	let hb = { lvl: overall, up: started };
	if (maint_on()) hb.maint = maint.until;
	if (iptv_res) hb.iptv = { state: iptv_res.state, kbps: iptv_res.kbps, lvl: iptv_res.level,
		dec: map(slice(iptv_res.decoders ?? [], 0, 4), (x) => ({ label: x.label || x.mac, port: x.port, up: x.present })) };
	hb.ports = map(slice(ports, 0, 8), (x) => ({ dev: x.dev, label: substr(x.label ?? '', 0, 24), up: x.up, speed: x.speed, lvl: x.level }));
	if (wifi_res)
		hb.wifi = { n: wifi_res.total, sta: map(slice(wifi_res.stations, 0, 6), (x) => ({ label: x.label || x.mac, up: x.connected,
			iface: x.iface, signal: x.signal, lvl: x.level })) };
	return hb;
}

/* every tick: send (sender), notice a silent second router (receiver) */
function peer_tick(hb) {
	if (!peer.sk) return null;
	if (cfg.peer.role == 'send') {
		peer_flush(hb);
		return null;
	}
	let t = now(), list = [], level = 'ok', reasons = [], changed = false;
	for (let n, p in peer.peers) {
		if (p.online && t - p.seen > max(60, p.iv * 4)) {
			p.online = false;
			p.lost_at = p.seen;
			changed = true;
			emit('warn', 'system', n, 'peer_lost', { last: p.seen, addr: p.addr });
		}
		if (!p.seen) continue;
		/* a router that did not report for an hour is shown, but not judged */
		let pl = p.online ? (p.hb?.lvl ?? 'unknown') : (t - p.seen < 3600 ? 'warn' : 'unknown');
		if (!p.online && pl == 'warn') push(reasons, { c: 'peer_offline', name: n, since: p.seen });
		else if (pl == 'warn' || pl == 'fail') push(reasons, { c: 'peer_level', name: n, lvl: pl });
		if (LEVEL[pl] != null) level = worst(level, pl == 'fail' ? 'fail' : pl);
		push(list, { name: n, addr: p.addr, online: p.online, seen: p.seen, off: p.off, iv: p.iv, level: pl, hb: p.online ? p.hb : null });
	}
	if (changed) peer_save();
	return { level, reasons, list };
}

function peer_out() {
	if (cfg.peer.role == 'off') return null;
	let o = { role: cfg.peer.role, port: cfg.peer.port, err: cfg.peer.err, bad: peer.bad, bad_addr: peer.bad_addr, bad_ts: peer.bad_ts };
	if (cfg.peer.role == 'send') {
		o.host = cfg.peer.host;
		o.last_ack = peer.last_ack;
		o.pending = length(peer.out);
		o.dropped = peer.dropped;
		/* nothing acknowledged for a while: receiver down, wrong address or key */
		if (!o.err && peer.sk && now() - (peer.last_ack ?? started) > max(60, cfg.interval * 6)) o.err = 'no_ack';
	}
	return o;
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

/* netifd status of a logical interface (testing: a JSON file in env) */
function iface_status(name, env) {
	let f = getenv(env);
	if (f) {
		try { return json(fs.readfile(f) || 'null'); } catch (e) { return null; }
	}
	if (NO_UBUS) return null;
	try {
		ubus_conn ??= require('ubus').connect();
		return ubus_conn?.call(`network.interface.${name}`, 'status');
	}
	catch (e) {
		ubus_conn = null;
		return null;
	}
}

function wan_status() {
	return iface_status(cfg.wan.interface, 'ISP_TESTER_WANSTATUS');
}

function uniq_list(a) {
	let out = [];
	for (let x in a) if (x != null && index(out, x) < 0) push(out, x);
	return out;
}

/* the DHCPv6 interface: as set, else wan6 or <wan>_6 (IPv6 "auto" on wan) */
function refresh_wan6() {
	if (!cfg.wan.enabled || !cfg.wan.ipv6) return;
	let names = cfg.wan.interface6 ? [ cfg.wan.interface6 ] : uniq_list([ v6s.iface, 'wan6', `${cfg.wan.interface}_6` ]);
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

/* ------------------------------------------------------------------ Wi-Fi */

/*
 * Wi-Fi clients, from hostapd over ubus (hostapd.<iface> get_clients, every
 * interval) plus its notifications (disassoc / deauth / assoc), so a client
 * that drops and comes back between two checks is caught too. Only the
 * stations listed in the settings are logged (phone, TV); the others are
 * counted. A drop that comes back within reconnect_s is a fault (warn); a
 * client that stays away just left (info). Signal: hostapd's own value, or
 * iwinfo's (rpcd-mod-iwinfo) when hostapd gives none.
 */
let wifi = { sta: {}, subs: {}, sub: null, err: null, clients: [] };

function wifi_label(mac) {
	return cfg.wifi.stations[mac] || mac;
}

/* hostapd objects -> get_clients results (testing: ISP_TESTER_HOSTAPD, a JSON file) */
function hostapd_read() {
	let f = getenv('ISP_TESTER_HOSTAPD');
	if (f) {
		let j;
		try { j = json(fs.readfile(f) || 'null'); } catch (e) { j = null; }
		return (type(j) == 'object') ? j : null;
	}
	if (NO_UBUS) return null;
	try {
		ubus_conn ??= require('ubus').connect();
		let out = {};
		for (let o in ubus_objects(/^hostapd\./)) {
			let r = ubus_conn.call(o, 'get_clients');
			if (type(r) == 'object') out[o] = r;
		}
		return out;
	}
	catch (e) {
		ubus_conn = null;
		return null;
	}
}

/* signal from iwinfo for an interface (only when hostapd has none) */
function iwinfo_signals(ifn) {
	let out = {};
	if (NO_UBUS || !ubus_conn) return out;
	try {
		let r = ubus_conn.call('iwinfo', 'assoclist', { device: ifn });
		for (let x in (r?.results ?? []))
			if (x?.mac) out[lc(x.mac)] = x.signal;
	}
	catch (e) {}
	return out;
}

/* a watched station left or was dropped (notification or poll) */
function wifi_gone(st, t, why) {
	if (st.left_at == null) {
		st.left_at = t;
		st.left_why = why;
		st.left_signal = st.signal;
		st.left_iface = st.iface;
		st.left_weak = st.weak;
	}
}

/* hostapd notifications: catch a drop that is back before the next check */
function wifi_notify(ev) {
	let mac = lc(`${ev?.data?.address ?? ''}`);
	if (cfg.wifi.stations[mac] == null) return;
	let st = wifi.sta[mac];
	if (!st) return;
	if (ev.type == 'disassoc' || ev.type == 'deauth') {
		wifi_gone(st, now(), ev.type);
		if (ev.data.reason != null) st.left_reason = ev.data.reason;
	}
	else if (ev.type == 'assoc' && st.left_at != null) {
		st.back_at = now();
	}
}

function wifi_subscribe(objs) {
	if (NO_UBUS || !ubus_conn || !length(cfg.wifi.stations)) return;
	try {
		wifi.sub ??= ubus_conn.subscriber((ev) => {
			try { wifi_notify(ev); } catch (e) {}
		}, (id) => {
			/* hostapd restarted (wifi reload): subscribe again on the next check */
			wifi.subs = {};
		});
		for (let o in objs)
			if (!wifi.subs[o] && wifi.sub?.subscribe(o)) wifi.subs[o] = true;
	}
	catch (e) {
		wifi.sub = null;
	}
}

function wifi_poll() {
	if (!cfg.wifi.enabled) return null;
	let objs = hostapd_read(), t = now();
	if (objs == null) {
		wifi.err = 'no_ubus';
		return length(cfg.wifi.stations)
			? { level: 'unknown', reasons: [ { c: 'wifi_no_ubus' } ], err: wifi.err, stations: [], ifaces: [], signal_warn: cfg.wifi.signal_warn }
			: null;
	}
	wifi.err = length(objs) ? null : 'no_hostapd';
	/* a router without an access point and nothing to watch: no card */
	if (wifi.err && !length(cfg.wifi.stations)) return null;

	let seen = {}, ifaces = [], total = 0, clients = [];
	for (let o, r in objs) {
		let ifn = replace(o, /^hostapd\./, ''), n = 0;
		let cl = (type(r?.clients) == 'object') ? r.clients : {};
		let sig = null;
		for (let mac, c in cl) {
			mac = lc(mac);
			if (type(c) != 'object' || c.assoc === false) continue;
			n++;
			let s = c.signal;
			if (s == null && cfg.wifi.stations[mac] != null) {
				sig ??= iwinfo_signals(ifn);
				s = sig[mac];
			}
			seen[mac] = { iface: ifn, signal: (type(s) == 'int' && s < 0) ? s : null,
				rx: c.rate?.rx, tx: c.rate?.tx, freq: r.freq };
			if (length(clients) < 64) push(clients, { mac, iface: ifn, signal: seen[mac].signal });
		}
		total += n;
		push(ifaces, { iface: ifn, freq: r.freq, n });
	}
	wifi.clients = clients;
	wifi_subscribe(keys(objs));

	let level = 'ok', reasons = [], list = [];
	for (let mac, label in cfg.wifi.stations) {
		let src = label || mac;
		let st = wifi.sta[mac] ??= { connected: null, since: t, weak: false, weak_n: 0, ok_n: 0 };
		let cur = seen[mac];

		if (cur) {
			let back = st.left_at != null;
			if (st.connected === false || back) {
				let away = (st.back_at ?? t) - (st.left_at ?? t);
				if (st.left_at != null && !st.left_logged) {
					/* back within the limit: a drop the user notices; on another
					 * band/AP of this router it was steered over (info) */
					let roam = st.left_iface && st.left_iface != cur.iface;
					emit(roam ? 'info' : 'warn', 'wifi', src, 'wifi_reconnect', { mac, iface: cur.iface, from: st.left_iface,
						away: max(1, away), signal: st.left_signal, weak: st.left_weak, why: st.left_why, reason: st.left_reason, roam }, st.left_at);
				}
				else if (st.left_logged)
					emit('info', 'wifi', src, 'wifi_join', { mac, iface: cur.iface, away: t - st.left_at, signal: cur.signal });
				st.since = st.back_at ?? t;
			}
			else if (st.connected == null) st.since = t;
			else if (st.iface && st.iface != cur.iface)
				/* moved to another band / interface without a gap seen */
				emit('info', 'wifi', src, 'wifi_roam', { mac, from: st.iface, iface: cur.iface, signal: cur.signal });
			st.connected = true;
			st.iface = cur.iface;
			st.signal = cur.signal;
			st.rx = cur.rx;
			st.tx = cur.tx;
			st.left_at = st.back_at = st.left_reason = st.left_why = null;
			st.left_logged = false;

			/* weak signal: two checks in a row, back with 5 dB hysteresis */
			if (cur.signal != null) {
				if (cur.signal < cfg.wifi.signal_warn) { st.weak_n++; st.ok_n = 0; }
				else if (cur.signal >= cfg.wifi.signal_warn + 5) { st.ok_n++; st.weak_n = 0; }
				if (!st.weak && st.weak_n >= 2) {
					st.weak = true;
					st.weak_since = t;
					st.weak_min = cur.signal;
					emit('warn', 'wifi', src, 'wifi_weak', { mac, iface: cur.iface, signal: cur.signal });
				}
				else if (st.weak && st.ok_n >= 2) {
					st.weak = false;
					emit('info', 'wifi', src, 'wifi_weak_ok', { mac, iface: cur.iface, signal: cur.signal, min: st.weak_min, dur: t - st.weak_since });
				}
				if (st.weak && cur.signal < st.weak_min) st.weak_min = cur.signal;
			}
		}
		else {
			if (st.connected === true) wifi_gone(st, t, 'gone');
			/* away longer than the limit: it left (phone out of the house) */
			if (st.left_at != null && !st.left_logged && t - st.left_at > cfg.wifi.reconnect_s) {
				emit('info', 'wifi', src, 'wifi_leave', { mac, iface: st.left_iface, signal: st.left_signal, weak: st.left_weak,
					why: st.left_why, reason: st.left_reason }, st.left_at);
				st.left_logged = true;
			}
			if (st.connected !== false) st.since = st.left_at ?? t;
			st.connected = false;
			st.weak = false;
			st.weak_n = st.ok_n = 0;
		}

		let sl = 'ok';
		if (st.weak) { sl = 'warn'; push(reasons, { c: 'wifi_weak_now', name: src, signal: st.signal }); }
		else if (recent_level('wifi', src) != 'ok') { sl = 'warn'; push(reasons, { c: 'recent_events', dev: src }); }
		level = worst(level, sl);
		push(list, { mac, label, connected: st.connected, iface: st.iface, signal: st.signal, rx: st.rx, tx: st.tx,
			since: st.since, weak: st.weak, level: st.connected ? sl : 'unknown' });
	}
	/* no access point running: nothing to judge (a note, not a warning) */
	if (wifi.err) { level = 'unknown'; push(reasons, { c: 'wifi_' + wifi.err }); }

	return { level, reasons, err: wifi.err, total, ifaces, stations: list, signal_warn: cfg.wifi.signal_warn,
		subscribed: length(keys(wifi.subs)) > 0 };
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
	agg10 = null;
	for (let n in (fs.lsdir(ARCH) ?? []))
		if (match(n, /^(ev|h)-[0-9]{8}\.jsonl$/)) fs.unlink(`${ARCH}/${n}`);
	arch.checked = 0;
	emit('info', 'system', 'collector', 'cleared', {});
}

function tick() {
	watchdog_ping();
	clk_check();
	ntp_poll();
	if (now() - alive_ts >= 60) alive_save(now());
	arch_check();
	handle_clear_request();
	handle_marks();
	handle_maint();
	handle_notify_test();
	handle_chn_forget();
	refresh_wan_device();
	refresh_wan6();
	sample_proxy();
	if (!iptv_fast()) igmp_poll();
	sample_system();
	read_log();
	dns_judge_servers();
	let dns_res = sample_dns();
	sample_pings();

	let m = mono();
	let dt = (last_mono != null) ? m - last_mono : 0;
	last_mono = m;
	/* this tick came far too late: nothing was measured in between */
	if (dt > cfg.interval * 3 + 10)
		emit('info', 'system', 'collector', 'data_gap', { from: int(now() - dt), to: now(), len: int(dt), why: 'stall' }, int(now() - dt));

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
		if (wd?.delta) bloat_tick(now(), wd.delta.rx_bps, wd.delta.tx_bps);
		if (bloat.active) {
			level = worst(level, 'warn');
			push(reasons, { c: 'bufferbloat_now', add: bloat.max_add, load: bloat.last?.load, dir: bloat.last?.dir });
		}
		if (wd && wd.level != 'ok') {
			level = worst(level, wd.level);
			for (let r in wd.reasons) push(reasons, r);
		}
		/* IPv6 trouble while IPv4 works: yellow (pages are slow, not gone) */
		if (dns_res?.bad) {
			level = worst(level, 'warn');
			push(reasons, { c: 'dns_fail_now', pct: dns_res.last?.pct, since: dns_res.since });
		}
		for (let x in (dns_res?.servers ?? []))
			if (x.bad) { level = worst(level, 'warn'); push(reasons, { c: 'dns_server_bad', server: x.server }); }
		let v6 = v6_out();
		if (v6 && length(v6.reasons)) {
			level = worst(level, 'warn');
			for (let r in v6.reasons) push(reasons, r);
		}
		if (level == 'ok' && recent_level('wan') != 'ok') {
			level = 'warn';
			push(reasons, { c: 'recent_events' });
		}

		wan = { level, reasons, targets: tl, device: cfg.wan.device, interface: cfg.wan.interface,
			trace: cfg.wan.trace ? { tool: MTR ? 'mtr' : (TRACEROUTE ? 'traceroute' : null), running: !!trace.proc, last: trace.last || null,
				n: trace.n, cooldown: cfg.wan.trace_cooldown } : null,
			bloat: bloat_out(),
			v6,
			dns: dns_res,
			rx_kbps: wd?.delta ? round(wd.delta.rx_bps / 1000, 0) : null,
			tx_kbps: wd?.delta ? round(wd.delta.tx_bps / 1000, 0) : null,
			source: { type: source.type, error: source.error, sock_error: source.sock_error, ping_plugin: source.ping_plugin, gateway: gateway_ip() },
			session: (wansess.up != null) ? { up: wansess.up, uptime: wansess.uptime, ip: wansess.ip, proto: wansess.proto, reconnects: wansess.reconnects, since: wansess.since } : null };
	}

	/* ---- IPTV */
	let iptv_dev = cfg.iptv.vlan ? vl.upstream : cfg.iptv.device;
	let iptv_res = sample_iptv(iptv_dev ? res[iptv_dev] : null);
	tsm_poll();
	let dhcp_res = dhcp_tick();
	if (iptv_res && dhcp_res != null) iptv_res.dhcp = dhcp_res;
	let decs = dec_poll();
	if (iptv_res && decs != null) {
		iptv_res.decoders = decs;
		if (dec.err) push(iptv_res.reasons, { c: 'dec_' + dec.err });
	}

	/* ---- Wi-Fi */
	let wifi_res = wifi_poll();

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
	if (wifi_res && wifi_res.level != 'unknown') overall = worst(overall, wifi_res.level);
	/* this router's own state, before the second router's is added */
	let own = overall;

	/* ---- second router */
	let peers = peer_tick(cfg.peer.role == 'send' ? peer_hb(own, iptv_res, ports, wifi_res) : null);
	if (peers && length(peers.list)) overall = worst(overall, peers.level);

	/* ---- history (skip the baseline tick without deltas) */
	let t = now();
	let me = sample_self();
	if (dt > 0) {
		let hv = { lvl: LEVEL[overall] };
		if (maint_on()) hv.maint = 1;
		if (me.cpu != null) hv['self:cpu'] = me.total;
		if (wan?.rx_kbps != null) {
			hv['wan:rx'] = wan.rx_kbps;
			hv['wan:tx'] = wan.tx_kbps;
		}
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
		if (clk.on) clk.run_hist++;

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
		wifi: wifi_res,
		wifi_clients: cfg.wifi.enabled ? wifi.clients : null,
		own,
		peer: peer_out(),
		peers: peers ? peers : null,
		counts: { h1: count_events(t - 3600), h24: count_events(t - 86400) },
		history,
		csv_rows,
		data: { dir: RUNDIR, link: (fs.lstat(RUNDIR)?.type == 'link') ? fs.readlink(RUNDIR) : null, archive: arch.info },
		ntp: ntp_out(),
		self: me,
		watchdog: { timeout: WATCHDOG, mode: wd.mode, last: wd.last || null, err: wd.err },
		maint: maint.until != null ? { until: maint.until, since: maint.since, note: maint.note, active: maint_on() } : null,
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
maint_load();
history = load_hist('state.json', cfg.history);
chn_load();
history_min = load_hist('history.json', cfg.long_history);

arch_check();
clk_init();
gap_check();

emit('info', 'system', 'collector', 'monitor_start', { interval: cfg.interval, iptv_interval: iptv_fast() ? cfg.iptv.sample_interval : null,
	uptime: int(uptime_s() ?? 0) });

uloop.init();
peer_start();
bloat_load_peak();
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
