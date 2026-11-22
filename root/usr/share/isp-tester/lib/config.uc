'use strict';

/* luci-app-isp-tester: part of the collector (see ../collector.uc) */

import * as fs from 'fs';
import { num, bool, aslist, valid_host, valid_dev, valid_group, valid_ip } from './common.uc';

/* language of the notifications: 'en' / 'pl' as set, otherwise ('auto') the
 * language of LuCI (System -> Language, uci luci.main.lang). When LuCI itself
 * follows the browser ('auto'), the router cannot see it: then Polish if the
 * Polish translation of this package is installed. */
function notify_lang(v, cur) {
	if (v == 'pl' || v == 'en') return v;
	let l = lc(cur.get('luci', 'main', 'lang') ?? 'auto');
	if (substr(l, 0, 2) == 'pl') return 'pl';
	if (l != 'auto') return 'en';
	return fs.stat('/usr/lib/lua/luci/i18n/isp-tester.pl.lmo') ? 'pl' : 'en';
}

/* with "log queries" on, dnsmasq answers SIGUSR1 with a dump of its whole
 * cache too (thousands of lines): it would push the server statistics and
 * every other message out of what read_log sees. Asked again before every
 * dump: the setting is dnsmasq's, saving it does not restart the collector */
function dnsmasq_logqueries(cur) {
	if (getenv('ISP_TESTER_CONFIG')) return false;
	let on = false;
	try {
		cur ??= require('uci').cursor();
		cur.foreach('dhcp', 'dnsmasq', (s) => {
			if (bool(s.logqueries, false)) on = true;
		});
	}
	catch (e) {}
	return on;
}

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
			collectd_socket: '', rrd_dir: '',
			/* one traceroute/mtr when a loss starts, at most every trace_cooldown s */
			trace: true, trace_cooldown: 600,
			/* bufferbloat: ping vs. WAN load; down/up_mbit 0 = learn the line's speed */
			bloat: true, bloat_ms: 30, bloat_load: 70, down_mbit: 0, up_mbit: 0,
			/* optical signal of the SFP / ONT module (ethtool -m), when the WAN goes through one:
			 * device '' = the WAN's physical port; drop_db below the usual level = a fault; rx_min dBm, '' = the module's own warning */
			sfp: true, sfp_device: '', sfp_interval: 30, sfp_drop_db: 3, sfp_rx_min: null,
			/* IPv6: netifd status of the DHCPv6 interface (odhcp6c), '' = wan6 / <wan>_6 */
			ipv6: true, interface6: '', ra_after: 60
		},
		iptv: {
			enabled: true, vlan: 0, upstream: '', device: '', direction: 'rx', bridge: '',
			min_kbps: 500, idle_after: 60, off_after: 15, dip_pct: 40,
			sample_interval: 1, stall_after: 2,
			igmp: true, igmp_device: '',
			/* the operator's IGMP queries on the IPTV VLAN (needs isp-tester-tsmon) */
			igmp_query: true,
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
		dns: { enabled: true, warn_pct: 10, min_queries: 5, dump: 300, logqueries: false },
		notify: {
			enabled: false, service: 'ntfy', url: '', token: '', chat_id: '',
			min_level: 'err', cooldown: 300, lang: 'auto'
		},
		/* data pushed over SSH (dropbear's dbclient) to another device, by push.sh */
		push: { enabled: false, interval_h: 24 },
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
		let ps = cur.get_all('isp_tester', 'push') || {};
		let dn = cur.get_all('isp_tester', 'dns') || {};

		c.dns.enabled     = bool(dn.enabled, true);
		c.dns.warn_pct    = num(dn.warn_pct, c.dns.warn_pct);
		c.dns.min_queries = num(dn.min_queries, c.dns.min_queries);
		c.dns.dump        = num(dn.dump, c.dns.dump);
		c.dns.logqueries  = dnsmasq_logqueries(cur);

		c.push.enabled    = bool(ps.enabled, false);
		c.push.interval_h = num(ps.interval_h, c.push.interval_h);

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
		c.wan.sfp            = bool(w.sfp, true);
		c.wan.sfp_device     = w.sfp_device ?? '';
		c.wan.sfp_interval   = num(w.sfp_interval, c.wan.sfp_interval);
		c.wan.sfp_drop_db    = num(w.sfp_drop_db, c.wan.sfp_drop_db);
		c.wan.sfp_rx_min     = num(w.sfp_rx_min, null);
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
		c.iptv.igmp_query  = bool(t.igmp_query, true);
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
		c.notify.lang      = notify_lang(n.lang, cur);

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

	c.interval = int(c.interval);
	if (c.interval < 2) c.interval = 2;
	/* sizes and times that would empty the lists or keep nothing on screen
	 * (0 events kept, a 0 s warning window) or rewrite a file on every tick */
	let at_least = (k, lo, dflt) => { let v = int(c[k]); c[k] = (v != v) ? dflt : max(v, lo); };
	at_least('max_events', 50, 1000);
	at_least('max_samples', 60, 8640);
	at_least('history', 30, 360);
	at_least('long_history', 60, 1440);
	at_least('warn_window', 60, 900);
	at_least('err_cooldown', 10, 60);
	at_least('drop_warn', 1, 50);
	/* a loss limit of 0 would make every target "degraded" on every value
	 * (loss >= 0), and a fail limit below the warning one would skip yellow */
	if (!(c.wan.loss_warn >= 1)) c.wan.loss_warn = 1;
	if (!(c.wan.loss_fail >= c.wan.loss_warn)) c.wan.loss_fail = max(c.wan.loss_warn, 50);
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
		c.iptv.sample_interval = c.iptv.vlan ? c.interval / 2.0 : 0;
	if (c.iptv.stall_after < 0) c.iptv.stall_after = 0;
	/* 0 kbit/s: every reading is "playing" (kbps >= 0), a freeze was never logged */
	if (!(c.iptv.min_kbps >= 1)) c.iptv.min_kbps = 500;
	if (!(c.iptv.dip_pct >= 0 && c.iptv.dip_pct <= 100)) c.iptv.dip_pct = 40;
	/* "stream ended" before the freeze is even reported made every freeze a stream_lost */
	if (!(c.iptv.idle_after >= c.iptv.stall_after + 5)) c.iptv.idle_after = max(c.iptv.stall_after + 5, 60);
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

	c.push.interval_h = int(c.push.interval_h);
	if (c.push.interval_h < 1) c.push.interval_h = 1;
	if (c.push.interval_h > 168) c.push.interval_h = 168;

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
	if (c.wan.bloat_ms < 5) c.wan.bloat_ms = 5;
	if (c.wan.bloat_load < 30 || c.wan.bloat_load > 100) c.wan.bloat_load = 70;
	if (!(c.wan.down_mbit >= 0)) c.wan.down_mbit = 0;
	if (!(c.wan.up_mbit >= 0)) c.wan.up_mbit = 0;
	if (c.wan.sfp_device && !valid_dev(c.wan.sfp_device)) c.wan.sfp_device = '';
	if (c.wan.sfp_interval < 10) c.wan.sfp_interval = 10;
	if (!(c.wan.sfp_drop_db >= 1)) c.wan.sfp_drop_db = 3;
	if (c.wan.sfp_rx_min != null && !(c.wan.sfp_rx_min < 0 && c.wan.sfp_rx_min > -50)) c.wan.sfp_rx_min = null;

	c.peer.port = int(c.peer.port);
	if (c.peer.port < 1 || c.peer.port > 65535) c.peer.port = 51477;
	c.peer.err = null;
	if (c.peer.role != 'off' && length(c.peer.key ?? '') < 8) c.peer.err = 'no_key';
	else if (c.peer.role == 'send' && !valid_ip(c.peer.host)) c.peer.err = 'bad_host';

	return c;
}

export { default_config, load_config, dnsmasq_logqueries };
