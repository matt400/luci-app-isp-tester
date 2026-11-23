#!/usr/bin/ucode
/*
 * luci-app-isp-tester - collector daemon
 *
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
import { RUNDIR, NO_UBUS, VARDIR, PROC, LOGREAD, MTR, TRACEROUTE, LEVEL, now, mono, num, write_atomic, round, worst } from './lib/common.uc';
import { parse_log_line } from './lib/parsers.uc';
import { read_dev, pid_usage, read_cpus, meminfo } from './lib/sysinfo.uc';
import { load_config } from './lib/config.uc';
import { tstamp } from './lib/messages.uc';
import { iptv_init, iptv_shift, vl, tsq, dec, igmp_poll, sample_proxy, dhcp_log_line, dhcp_tick, dec_poll, iptv_on, iptv_fast, chn_load, chn_now, handle_chn_forget, iptv_fast_sample, sample_iptv, tsm_poll } from './lib/iptv.uc';
import { wan_init, wan_shift, targets, source, wansess, wanst, trace, bloat, sfp, target_why, target_level, bloat_load_peak, bloat_tick, bloat_out, sample_sfp, sfp_out, gateway_ip, sample_pings, v6_out, dns_log_line, dns_judge_servers, sample_dns, refresh_wan6, refresh_wan_device } from './lib/wan.uc';
import { clock_init, clk, clk_fields, clk_check, ntp_poll, ntp_out, clk_init } from './lib/clock.uc';
import { peer_init, peer_queue, peer_start, peer_hb, peer_tick, peer_out, peer_shift } from './lib/peer.uc';
import { querier_init, querier_tick, querier_out, querier_shift, querier_none, querier_query, querier_router } from './lib/querier.uc';
import { RECOVERY, notify_init, notify_queue, notify_flush, notify_test, notify_status } from './lib/notify.uc';

/* ------------------------------------------------------------------ state */

let cfg = load_config();
let events = [];
let history = { t: [], s: {} };
let history_min = { t: [], s: {} };
let devstate = {};      /* dev -> { prev, link, since, err_acc, drop_acc, last_err_ev, ... } */
let csv_rows = 0;
let ubus_conn = null;     /* one ubus connection, (re)opened on demand */

/* names of the ubus objects matching re; list() with a pattern would return
 * their method signatures, not their names */
let ubus_list = { ts: null, names: null, conn: null };
function ubus_objects(re) {
	/* the list of all objects is asked once a minute (and again on a new
	 * connection), not on every tick for the few dnsmasq objects in it */
	let m = mono();
	if (ubus_list.names == null || ubus_list.conn != ubus_conn || m - ubus_list.ts >= 60) {
		let l = ubus_conn?.list();
		ubus_list = { ts: m, names: (type(l) == 'array') ? l : [], conn: ubus_conn };
	}
	return filter(ubus_list.names, (n) => type(n) == 'string' && match(n, re) != null);
}
/* a cooldown since `last` is over; also when the clock was set back
 * before `last`, which would otherwise keep the events away until the
 * clock catches up (an hour back = an hour without events) */
function due(t, last, cd) {
	return t - last >= cd || t < last;
}
let csv_header = null;
let last_mono = null;
let started = now();
let sys = { prev: null, cpu_n: 0, cpu: false, mem: false, ct: false, cpu_since: 0, mem_since: 0, ct_since: 0 };
/* tail = the last lines of the previous read (where it ended), null before
 * the first read; min_ts = with nothing to anchor on, older lines are skipped */
let logst = { tail: null, min_ts: null, kinds: {} };
const HOSTNAME = trim(fs.readfile(`${PROC}/sys/kernel/hostname`) ?? '') || 'OpenWrt';
notify_init({ cfg, hostname: HOSTNAME });

/* ----------------------------------------------------------------- events */

/* The whole list is rewritten, so a burst of events (or many in one tick)
 * would rewrite it again and again - on a USB stick that is flash wear.
 * Once the loop runs, the write is postponed by half a second and done once;
 * before that (the first events at start) it is immediate. */
let events_timer = null, loop_up = false;

/* the overview asks for the newest events every 5 s: rpcd parsed the whole
 * timeline for it (up to max_events, megabytes with a long one) each time.
 * The newest ones are written aside too, to RAM (VARDIR: no flash wear) */
const RECENT_N = 200;

function flush_events() {
	if (events_timer) { events_timer.cancel(); events_timer = null; }
	write_atomic(`${RUNDIR}/events.json`, sprintf('%J', events));
	let n = length(events);
	write_atomic(`${VARDIR}/events.recent.json`, sprintf('%J',
		{ total: n, events: (n > RECENT_N) ? slice(events, n - RECENT_N) : events }));
}

function save_events() {
	if (!loop_up) return flush_events();
	events_timer ??= uloop.timer(500, () => { events_timer = null; flush_events(); });
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

/* store one event (own or received from the second router). The list is
 * kept in time order: events dated back (data_gap, router_reboot, a stall
 * dated to when the data stopped, a user mark, the second router's) go to
 * their place, so the readers that stop at the first old event
 * (recent_level, count_events, dec_stream_hit, rpcd "newest first") see
 * everything that is newer. */
function store_event(e) {
	if (maint_on() && e.type != 'maint_start' && e.type != 'maint_end') e.m = 1;
	let n = length(events), i = n;
	while (i > 0 && events[i - 1].ts > e.ts) i--;
	if (i == n) push(events, e);
	else splice(events, i, 0, e);
	if (length(events) > cfg.max_events)
		events = slice(events, length(events) - cfg.max_events);
	notify_queue(e);
}

function emit(lvl, area, src, typ, data, ts) {
	let e = { ts: ts ?? now(), lvl, area, src, type: typ, d: data ?? {} };
	if (clk.on) e._fix = clk_fields(typ, e.d);
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
	/* a state without a time (damaged, half written by an older version) is
	 * no sign of life: t - null was taken as "silent since 1970" ('hung') */
	if (type(st?.ts) != 'int') st = null;
	let stop = num(trim(fs.readfile(STOPPED) ?? ''), null);
	fs.unlink(STOPPED);

	/* last sign of life: alive.json, the state of the same boot, own events */
	let last = (type(a?.ts) == 'int') ? a.ts : null;
	if (st && (last == null || st.ts > last)) last = st.ts;
	for (let i = length(events) - 1; i >= 0 && i >= length(events) - 50; i--)
		if (!events[i].host && events[i].ts <= t && (last == null || events[i].ts > last)) last = events[i].ts;

	let boot = (up != null) ? int(t - up) : null;
	let rebooted = (a?.boot_id && BOOT_ID) ? a.boot_id != BOOT_ID : (up != null && up < 900 && st == null);

	if (rebooted) {
		/* a run of an earlier boot that ended before its clock was confirmed
		 * left its events marked (_fix): a step of this boot's clock says
		 * nothing about them, they must not be moved by it */
		for (let e in events) delete e._fix;
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
		/* no answer: the connection may be dead (ubusd restarted) - it does
		 * not throw then, so without this every later ubus call (WAN status,
		 * dnsmasq) failed too until procd's watchdog killed the collector */
		if (r == null) ubus_conn = null;
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
		/* the list is in time order: stop at the first old one, also when it
		 * is the second router's or from a maintenance (those used to be
		 * skipped before the check, so a long run of them was scanned to
		 * the start of the list) */
		if (e.ts < cutoff) break;
		if (e.host || e.m) continue;
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
		/* a recovery (link up, Internet back, stream resumed) ends a problem
		 * already counted: one outage is one problem, not two. A path
		 * snapshot (trace) is evidence for the loss it was taken for, not a
		 * problem of its own (as in the analysis and the per-hour chart) */
		if (e.host || e.m || RECOVERY[e.type] || e.type == 'trace') continue;
		if (e.lvl == 'warn') n.warn++;
		else if (e.lvl == 'err') n.err++;
	}
	return n;
}

/* (after count_events: ucode does not hoist functions - called before
 * its declaration it was an undeclared variable, every tick failed and
 * state.json was never written)
 * the 24 h count walks most of the list (up to max_events, 20000 at most)
 * on every tick: it is counted again only when the list changed or a minute
 * went by (old events leave the window) */
let counts24 = { key: null, n: null };

function count_events24(t) {
	let n = length(events);
	let key = `${n}|${n ? events[n - 1].ts : 0}|${n ? events[0].ts : 0}|${int(t / 60)}`;
	if (key != counts24.key) counts24 = { key, n: count_events(t - 86400) };
	return counts24.n;
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
		let empty = [];
		for (let k in keys(h.s)) {
			let arr = h.s[k] = slice(h.s[k], cut);
			/* a series with no value left is dropped; searched from the end,
			 * where a live series has its values, so it stops at once */
			let i = length(arr) - 1;
			while (i >= 0 && arr[i] == null) i--;
			if (i < 0) push(empty, k);
		}
		/* deleted after the loop, not from the object being iterated */
		for (let k in empty) delete h.s[k];
	}
}

/* 1-minute aggregates for the long (24 h) history */
const AGG_MODE = { rtt: 'avg', rttmax: 'max', loss: 'max', jit: 'max',
	'iptv:kbps': 'avg', 'iptv:min': 'min', 'iptv:cc': 'sum', err: 'sum', drop: 'sum', lvl: 'max', maint: 'max', 'self:cpu': 'max',
	'sfp:rx': 'min', 'sfp:tx': 'min', 'sfp:temp': 'max' };

let agg = null;

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
		default:    vals[k] = round(x.sum / (x.n * 1.0), 1);   /* int / int truncates in ucode */
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
	/* a clock set back (not by clk_fix: the clock was trusted) would flush
	 * the open minute with a time after the new one: it is dropped */
	if (agg && agg.t > m) agg = null;
	if (agg && agg.t != m) agg_flush();
	agg ??= { t: m, v: {} };
	agg_put(agg, vals);
}

/* --------------------------------------------------------------- devices */

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
			emit(m.expect_up ? 'warn' : 'info', m.area, m.dev, 'link_flap', { dev: m.dev, n: int((cur.carrier_changes - p.carrier_changes) / 2) });
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
		if (ds.err_acc && due(t, ds.last_err_ev, cfg.err_cooldown)) {
			emit('warn', m.area, m.dev, 'errors', { dev: m.dev, err: ds.err_acc.err, crc: ds.err_acc.crc, from: ds.err_acc.from });
			ds.err_acc = null;
			ds.last_err_ev = t;
		}

		if (d.drop >= cfg.drop_warn) {
			ds.drop_acc ??= { n: 0, from: t };
			ds.drop_acc.n += d.drop;
		}
		if (ds.drop_acc && due(t, ds.last_drop_ev, cfg.err_cooldown)) {
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

/* ------------------------------------------------- the tester's own load */

/*
 * Proof that measuring does not load the router (and is not what breaks
 * IPTV): CPU and RAM of the collector (with the commands it runs: logread,
 * bridge, rrdtool... - their time is added to it when they end) and of
 * tsmon, from /proc/<pid>/stat and status. CPU in % of the whole router
 * (all cores); USER_HZ is 100 on Linux.
 */
let selfu = { prev: null, tsm: null, start: null, cpu: null, max: 0, ncpu: null };

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

/* ---------------------------------------------------------- router load */

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
	let o = {};

	let c = read_cpus();
	if (c && sys.prev) {
		let best = null, cores = 0;
		for (let k, v in c) {
			let p = sys.prev[k];
			if (!p) continue;
			let dt = v.total - p.total;
			if (dt <= 0) continue;
			let busy = 100 - (v.idle - p.idle) * 100.0 / dt, si = (v.sirq - p.sirq) * 100.0 / dt;
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
	if (ctn != null && ctm > 0) { o.ct = ctn; o.ct_max = ctm; o.ct_pct = round(ctn * 100.0 / ctm, 0); }

	let y = cfg.system;
	if (o.cpu_max != null && y.cpu_warn > 0) {
		/* two intervals in a row, so a single busy moment (e.g. opkg) does not
		 * count: the run is counted only above the limit (it was kept between
		 * limit - 10 and the limit, so two busy moments an hour apart counted
		 * as "two in a row"); it ends 10 below the limit (hysteresis) */
		if (o.cpu_max >= y.cpu_warn) sys.cpu_n++;
		else sys.cpu_n = 0;
		load_flag('cpu', sys.cpu_n >= 2, o.cpu_max < y.cpu_warn - 10, 'cpu_high', { cpu: o.cpu_max, sirq: o.sirq_max, core: o.core });
	}
	if (o.mem_pct != null && y.mem_warn > 0)
		load_flag('mem', o.mem_pct < y.mem_warn, o.mem_pct >= y.mem_warn + 5, 'mem_low', { pct: o.mem_pct });
	if (o.ct_pct != null && y.conntrack_warn > 0)
		load_flag('ct', o.ct_pct >= y.conntrack_warn, o.ct_pct < y.conntrack_warn - 5, 'conntrack_full', { pct: o.ct_pct, n: o.ct, max: o.ct_max });

	/* no card of its own (only events for the analysis): no level or
	 * reasons to work out, no scan of the timeline for them */
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
		/* a time that is no number (a hand-made or damaged line) made int()
		 * NaN: an event without a valid time, which every reader that stops
		 * at the first old event treated as older than everything */
		let ts = (type(m.ts) == 'int') ? m.ts : t;
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
	/* taken away first (as the marks): a request written while this one is
	 * read is not deleted unread */
	let f = `${VARDIR}/maint.pending`, work = `${VARDIR}/maint.work`;
	if (!fs.stat(f) || !fs.rename(f, work)) return;
	let r;
	try { r = json(fs.readfile(work) || 'null'); } catch (e) { r = null; }
	fs.unlink(work);
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

function log_emit(k) {
	let st = logst.kinds[k];
	emit(st.lvl, st.area, k, 'log', { kind: k, prog: st.prog, msg: substr(st.msg, 0, 160), n: st.n }, st.ts);
	st.n = 0;
	st.last = now();
}

const LOG_TAIL = 5;

/* the lines after the end of the previous read. Found by the text of its
 * last lines, not by the time stamps: after the clock is set back (NTP after
 * a boot with a wrong time) every new line looks "older" than the last one
 * seen, and the time stamps would hide the log until the clock caught up.
 * Not found: more than the whole buffer was logged in one tick, or logd
 * restarted with an empty buffer - either way all of it is new. */
function log_new_lines(lines) {
	let tl = logst.tail, k = length(tl);
	if (!k) return lines;
	for (let i = length(lines) - 1; i >= k - 1; i--) {
		let j = 0;
		while (j < k && lines[i - j] == tl[k - 1 - j]) j++;
		if (j == k) return slice(lines, i + 1);
	}
	return lines;
}

function read_log() {
	if (!cfg.logread || !LOGREAD) return;
	let f = fs.popen(`${LOGREAD} -l 300 2>/dev/null`, 'r');
	if (!f) return;
	let data = f.read('all') ?? '';
	f.close();

	let lines = filter(split(data, '\n'), (l) => l != '');
	let first = (logst.tail == null);
	let fresh = first ? [] : log_new_lines(lines), min_ts = logst.min_ts;
	/* on start only remember where the log ends; old lines are history.
	 * Nothing readable then (logd not up yet): later only lines from now on */
	if (length(lines)) { logst.tail = slice(lines, -LOG_TAIL); logst.min_ts = null; }
	else if (first) { logst.tail = []; logst.min_ts = now(); }

	/* only the new lines are parsed (the regex and timelocal were the
	 * costly part, done for all 300 lines every tick) */
	for (let line in fresh) {
		let l = parse_log_line(line);
		if (!l) continue;
		if (min_ts != null && l.ts < min_ts - 1) continue;

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
			if (due(now(), st.last, cfg.err_cooldown)) log_emit(k);
			break;
		}
	}

	for (let k, st in logst.kinds)
		if (st.n > 0 && due(now(), st.last, cfg.err_cooldown)) log_emit(k);
}

/* ------------------------------------------------------------------- CSV */

/* ping targets with a column in the CSV. Kept when a target goes quiet
 * (collectd restarted, one tick without values): a header change moves
 * samples.csv to samples.prev.csv, and two of them in a row (the targets
 * gone, then back) overwrote the previous 24 h with a file of one row. A
 * target that is not measured just has empty cells; only a new one changes
 * the header. Seeded from the file's own header at start, so a restart with
 * collectd not answering yet does not start a new file either. */
let csv_tl = null;
/* the same for the devices: the WAN device is known only once the WAN is up
 * (at boot the collector starts before PPPoE / DHCP), a VLAN port can be
 * missing from one reading of the bridge. Their columns came and went: at
 * every reboot the header changed twice (without the WAN, then with it), and
 * with the data on USB the second change moved the few rows from before the
 * WAN was up over samples.prev.csv - the 24 h before the reboot were lost.
 * A device that is not watched now has empty cells. */
let csv_dl = null;

/* the header of samples.csv as it is (seeds the two lists at start) */
function csv_file_cols() {
	let f = fs.open(`${RUNDIR}/samples.csv`, 'r');
	let first = f ? (f.read('line') ?? '') : '';
	if (f) f.close();
	return split(trim(first), ',');
}

function csv_devices(devs) {
	if (csv_dl == null) {
		csv_dl = [];
		for (let c in csv_file_cols()) {
			let m = match(c, /^(.+)_link$/);
			if (m) push(csv_dl, m[1]);
		}
	}
	for (let d in devs)
		if (index(csv_dl, d.dev) < 0) push(csv_dl, d.dev);
	return csv_dl;
}

/* by host, not by label: the gateway is called "gateway" only once netifd
 * names it (WAN up), so at boot its column was first ping_<address>_* and
 * then ping_gateway_* - another header change of the kind above. (A file
 * from before, with ping_gateway_*, starts once more.) */
function csv_targets() {
	if (csv_tl == null) {
		csv_tl = [];
		for (let c in csv_file_cols()) {
			let m = match(c, /^ping_(.+)_loss$/);
			if (m && m[1] != 'gateway') push(csv_tl, m[1]);
		}
	}
	for (let k, x in targets)
		if (x.active && index(csv_tl, x.host) < 0) push(csv_tl, x.host);
	let by = {};
	for (let k, x in targets)
		if (x.active) by[x.host] = x;
	return map(csv_tl, (h) => ({ label: h, t: by[h] }));
}

function csv_columns(dlist, tlist) {
	let cols = [ 'time', 'overall' ];
	for (let t in tlist) push(cols, `ping_${t.label}_loss`, `ping_${t.label}_rtt`, `ping_${t.label}_jitter`);
	if (iptv_on()) push(cols, 'iptv_state', 'iptv_kbps', 'iptv_min_kbps', 'iptv_stall_s', 'iptv_pps', 'iptv_channel');
	for (let d in dlist) push(cols, `${d}_link`, `${d}_speed`, `${d}_err`, `${d}_crc`, `${d}_drop`, `${d}_rx_kbps`, `${d}_tx_kbps`);
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
		let data = fs.readfile(path);
		/* deleted or unreadable meanwhile (stick pulled): start it again */
		if (data == null) { csv_header = null; return; }
		let lines = split(trim(data), '\n');
		let keep = slice(lines, max(1, length(lines) - cfg.max_samples));
		write_atomic(path, csv_header + '\n' + join('\n', keep) + '\n');
		csv_rows = length(keep);
	}
}

/* ------------------------------------------------------------ data push */

/*
 * Sends the timeline, history and CSV to another device over SSH (push.sh,
 * dropbear's dbclient) every push.interval_h hours, so the long history is
 * kept there and not on this router. The script writes push.json; a failed
 * try is repeated after 30 minutes at the earliest.
 */
const PUSH_SH = '/usr/share/isp-tester/push.sh';
/* monotonic time of the last start: a send that cannot write push.json
 * (busy with an older one, VARDIR full) would otherwise be started again on
 * every tick */
let push_m = null;

function push_tick() {
	if (!cfg.push.enabled || now() - started < 120) return;
	if (push_m != null && mono() - push_m < 300) return;
	let st;
	try { st = json(fs.readfile(`${VARDIR}/push.json`) || 'null'); } catch (e) { st = null; }
	let wait = cfg.push.interval_h * 3600;
	/* a "running" left behind by a send that was killed (dbclient itself
	 * gives up after 300 s) counts as failed, not as sent */
	if (st && !st.ok && (st.state != 'running' || now() - (st.ts ?? 0) > 900)) wait = min(wait, 1800);
	/* (a try "in the future" after the clock was set back counts as over) */
	if (st?.ts && now() - st.ts < wait && now() >= st.ts) return;
	push_m = mono();
	system(`/bin/sh ${PUSH_SH} send >/dev/null 2>&1 &`);
}

/* ------------------------------------------------------------------ tick */

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
	/* started again on the next tick, with the columns of the ping targets
	 * measured now (a target removed from collectd keeps its column until then) */
	fs.unlink(`${RUNDIR}/samples.csv`);
	csv_header = null;
	csv_tl = [];
	csv_dl = [];
	csv_rows = 0;
	emit('info', 'system', 'collector', 'cleared', {});
}

function tick() {
	watchdog_ping();
	clk_check();
	ntp_poll();
	/* with due(): after the clock was set back it would not be written
	 * again until the clock caught up, and a reboot meanwhile would date the
	 * data gap from the old time */
	if (due(now(), alive_ts, 60)) alive_save(now());
	handle_clear_request();
	push_tick();
	handle_marks();
	handle_maint();
	notify_test();
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
		/* only while there is ping data: with collectd stopped (or its values
		 * older than 5 min) an outage in progress cannot end, and the card
		 * showed "Internet unreachable" for good; it is ended (wan_up) by
		 * the first values again, so no second outage is logged */
		if (wanst.down != null && n_active > 0) push(reasons, { c: 'wan_down', since: wanst.down });
		if (wansess.up === false) {
			level = 'fail';
			push(reasons, { c: 'wan_if_down', iface: cfg.wan.interface, since: wansess.since });
		}
		/* also with collectd running but no ping host configured: nothing is measured */
		if (!source.type || !length(tl))
			push(reasons, { c: 'no_ping_source', error: source.error, plugin: source.ping_plugin });

		let wdev = cfg.wan.device ? res[cfg.wan.device] : null;
		/* also without counters (WAN device gone): a bufferbloat in progress must be able to end */
		bloat_tick(now(), wdev?.delta?.rx_bps, wdev?.delta?.tx_bps);
		sample_sfp();
		let sfp_res = sfp_out();
		if (sfp_res?.los) { level = worst(level, 'warn'); push(reasons, { c: 'sfp_los', since: sfp.los_since }); }
		else if (sfp_res?.drop) { level = worst(level, 'warn'); push(reasons, { c: 'sfp_weak', rx: sfp_res.rx, base: sfp_res.base }); }
		if (sfp_res?.alarm) { level = worst(level, 'warn'); push(reasons, { c: 'sfp_alarm', flags: sfp_res.flags }); }
		if (bloat.active) {
			level = worst(level, 'warn');
			push(reasons, { c: 'bufferbloat_now', add: bloat.max_add, load: bloat.last?.load, dir: bloat.last?.dir });
		}
		if (wdev && wdev.level != 'ok') {
			level = worst(level, wdev.level);
			for (let r in wdev.reasons) push(reasons, r);
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
			sfp: sfp_res,
			v6,
			dns: dns_res,
			rx_kbps: wdev?.delta ? round(wdev.delta.rx_bps / 1000, 0) : null,
			tx_kbps: wdev?.delta ? round(wdev.delta.tx_bps / 1000, 0) : null,
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
	/* who sends the IGMP queries on the IPTV VLAN (and, when managed, keep the router's querier on) */
	if (iptv_res) {
		querier_tick(vl, iptv_res.igmpq);
		let qo = querier_out();
		if (qo) {
			iptv_res.querier = qo;
			for (let r in qo.reasons) {
				iptv_res.level = worst(iptv_res.level, 'warn');
				push(iptv_res.reasons, r);
			}
			/* with per-VLAN snooping the bridge-wide snooping / querier / timers
			 * (sysfs) are not what the IPTV VLAN uses: the "querier off" hint was
			 * shown while the VLAN's own querier asked every 125 s */
			if (iptv_res.bridge && qo.conf?.per_vlan) {
				let c = qo.conf;
				iptv_res.bridge.snooping = (c.snooping != null) ? `${c.snooping}` : iptv_res.bridge.snooping;
				iptv_res.bridge.querier = (c.querier != null) ? `${c.querier}` : iptv_res.bridge.querier;
				if (c.version != null) iptv_res.bridge.igmp_version = `${c.version}`;
				if (c.membership) iptv_res.bridge.membership_interval = c.membership;
				if (c.query) iptv_res.bridge.query_interval = c.query;
				iptv_res.bridge.per_vlan = c.snooping != null;
			}
			if (iptv_res.bridge) iptv_res.bridge.elected = qo.who;
		}
	}

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
	/* this router's own state, before the second router's is added */
	let own = overall;

	/* ---- second router */
	let peers = peer_tick(cfg.peer.role == 'send' ? peer_hb(own, iptv_res, ports) : null);
	if (peers && length(peers.list)) overall = worst(overall, peers.level);

	/* ---- history (skip the baseline tick without deltas) */
	let t = now();
	let me = sample_self();
	if (dt > 0) {
		let hv = { lvl: LEVEL[overall] };
		if (maint_on()) hv.maint = 1;
		if (me.cpu != null) hv['self:cpu'] = me.total;
		if (wan?.sfp?.ok) {
			if (wan.sfp.rx != null) hv['sfp:rx'] = wan.sfp.rx;
			if (wan.sfp.tx != null) hv['sfp:tx'] = wan.sfp.tx;
			if (wan.sfp.temp != null) hv['sfp:temp'] = wan.sfp.temp;
		}
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
			/* rx_errors already includes the CRC / frame errors: the larger of the two, not the sum */
			hv[`err:${d.dev}`] = r.delta ? max(r.delta.err, r.delta.crc) : null;
			hv[`drop:${d.dev}`] = r.delta ? r.delta.drop : null;
		}
		hist_add(history, t, hv, cfg.history);
		if (clk.on) clk.run_hist++;

		let mv = { ...hv };
		for (let x in (wan?.targets ?? [])) mv[`rttmax:${x.label}`] = x.rtt;
		if (iptv_res) mv['iptv:min'] = iptv_res.min ?? iptv_res.kbps;
		agg_add(t, mv);

		/* ---- CSV */
		let tlist = csv_targets(), dlist = csv_devices(devs);
		let cols = csv_columns(dlist, tlist);
		/* also when the file is gone (deleted, the USB stick re-mounted):
		 * appending would make a file without the header line */
		if (join(',', cols) != csv_header || !fs.stat(`${RUNDIR}/samples.csv`)) csv_open(cols);

		let row = [ tstamp(t), overall ];
		for (let x in tlist) push(row, x.t?.res?.loss, x.t?.res?.rtt, x.t?.res?.jitter);
		if (iptv_on()) {
			/* no quoting in this CSV: commas and quotes in names become spaces */
			let ch = chn_now();
			/* the name comes from the stream: a leading = + - @ would be a formula in a spreadsheet */
			if (ch && match(ch, /^[=+\-@\t]/)) ch = `'${ch}`;
			push(row, iptv_res?.state, iptv_res?.kbps, iptv_res?.min, iptv_res?.stall_s, iptv_res?.pps,
				ch ? replace(replace(ch, ', ', ' | '), /[,"\r\n]/g, ' ') : null);
		}
		for (let d in dlist) {
			let r = res[d];
			if (!r) { push(row, null, null, null, null, null, null, null); continue; }
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
		own,
		peer: peer_out(),
		peers: peers ? peers : null,
		counts: { h1: count_events(t - 3600), h24: count_events24(t) },
		history,
		csv_rows,
		data: { dir: RUNDIR, link: (fs.lstat(RUNDIR)?.type == 'link') ? fs.readlink(RUNDIR) : null },
		ntp: ntp_out(),
		self: me,
		watchdog: { timeout: WATCHDOG, mode: wd.mode, last: wd.last || null, err: wd.err },
		maint: maint.until != null ? { until: maint.until, since: maint.since, note: maint.note, active: maint_on() } : null,
		notify: notify_status()
	};
	write_atomic(`${VARDIR}/state.json`, sprintf('%J', state));

	notify_flush(false);
}

/* the clock was stepped while not trusted (clk_fix): the wall times this
 * run noted are moved too, or durations (link up "after 3 days", the load
 * flags' "normal again after") would carry the step */
function shift_run(by) {
	started += by;
	for (let d, ds in devstate) if (type(ds.since) == 'int') ds.since += by;
	for (let k in [ 'cpu_since', 'mem_since', 'ct_since' ]) if (sys[k]) sys[k] += by;
	if (logst.min_ts != null) logst.min_ts += by;
	/* a maintenance started before the step would end at once (step forward)
	 * or last for as long as the step (step back) */
	if (maint.until != null) { maint.until += by; maint.since += by; maint_save(); }
	peer_shift(by);
	wan_shift(by);
	iptv_shift(by);
	querier_shift(by);
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
iptv_init({ cfg, emit, recent_level, events: () => events, querier_none, querier_query, querier_router });
querier_init({ cfg, emit });
wan_init({ cfg, emit, ubus: () => (ubus_conn ??= require('ubus').connect()), ubus_drop: () => { ubus_conn = null; }, ubus_objects });
clock_init({ events: () => events, history: () => history, history_min: () => history_min,
	agg_shift: (by) => { if (agg) agg.t += by; }, shift_started: shift_run,
	reset_alive: () => { alive_ts = 0; }, emit, save_events, uptime_s });
peer_init({ cfg, hostname: HOSTNAME, started: () => started, maint_on, maint_until: () => maint.until,
	store_event, save_events, emit });
maint_load();
history = load_hist('state.json', cfg.history);
chn_load();
history_min = load_hist('history.json', cfg.long_history);

clk_init();
gap_check();

emit('info', 'system', 'collector', 'monitor_start', { interval: cfg.interval, iptv_interval: iptv_fast() ? cfg.iptv.sample_interval : null,
	uptime: int(uptime_s() ?? 0) });

uloop.init();
loop_up = true;
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
			warn(`isp-tester: iptv sample failed: ${e}\n${e.stacktrace?.[0]?.context ?? ''}\n`);
		}
	});
}

uloop.run();

/* uloop ends on SIGTERM / SIGINT (procd's stop, a restart after saving the
 * settings): what is still waiting is written, so the last half second of
 * events is not lost */
try { flush_events(); } catch (e) {}
