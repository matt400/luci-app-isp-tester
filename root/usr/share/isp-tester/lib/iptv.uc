'use strict';

/* luci-app-isp-tester: IPTV (bitrate, stream state machine, bridged VLAN, IGMP, decoders,
 * decoder DHCP, channel names, picture quality via tsmon) - see ../collector.uc.
 * init(ctx) gives it cfg, emit, recent_level, events() */

import * as fs from 'fs';
import * as uloop from 'uloop';
import { RUNDIR, VARDIR, PROC, SYSNET, BRIDGE, PROXIES, TSMON, LEVEL, now, mono, num, round, valid_dev, valid_group, mc_ignored, write_atomic, kill_pids, worst } from './common.uc';
import { median } from './parsers.uc';
import { rd, base, is_uplink, bridge_json, bridge_mdb } from './sysinfo.uc';

let C = null;

function iptv_init(ctx) { C = ctx; }

let iptv = {
	state: 'idle', since: now(), kbps: 0, pps: 0, avg: null, dip: false,
	stall_since: null, stall_m: null,       /* wall / monotonic start of the current stall */
	watch: null,                            /* group being watched while it played */
	low_w: null, low_m: null,               /* start of a below-threshold run not yet long enough */
	held: false, hold_def: 0,               /* stop while nobody is subscribed: decoder off or freeze? */
	wd_m: null, wd_w: null,                 /* first whole tick below the threshold while playing (watchdog) */
	prev: null, prev_m: null, prev_w: null, /* last counter reading (fast sampler) */
	acc: null                               /* per-tick aggregate of the fast samples */
};
/* bridged IPTV VLAN (see vlan_sample) */
let vl = { bridge: null, upstream: null, ports: [], stats: null, mdb: null, error: null, cnt: null,
	key: null, topo_m: null };       /* port list the topology was worked out for, and when */
/* joined = group -> when it was joined (0 = already there at start) */
let igmp = { groups: null, joined: {}, hist: [], proxy: null, proxy_seen: false, proxy_since: now() };
/* picture quality (see tsm_poll): proc/args = the running helper and its
 * arguments, fails/next = restart backoff, seen = last counters per group
 * ("<pid>:<id>"), drops = the helper's socket drop counter, flow = groups
 * carrying TS in the last read, win = errors of the last TSQ_WIN s,
 * pend/last_ev/last_lvl = per group, errors whose event is held back by the
 * cooldown, cc_acc = errors since the last tick (history chart),
 * dropped/drop_ts = packets the router could not count */
const IGQ_RING = 8;
let igq = { on: false, pid: null, gen: 0, total: 0, last_ts: null, ivals: [], src: null, ver: null, qqic: null,
	max_resp: null, since: null, silent: false, silent_ref: 0, silent_router: false, ever: false };

/* declared here, before their first use: ucode does not hoist functions */
function igmpq_expected() {
	let e = (length(igq.ivals) >= 3) ? median(igq.ivals) : (igq.qqic > 0 ? igq.qqic : 125);
	return max(10, round(e, 0));
}
function igmpq_limit() {
	/* max_resp is in 1/10 s: / 10.0, two ints are divided as integers (2.5 s -> 2) */
	return 2 * igmpq_expected() + ((igq.max_resp > 0) ? igq.max_resp / 10.0 : 10);
}

let tsq = { proc: null, args: null, started: 0, fails: 0, next: 0, err: null, seen: {}, drops: null, flow: null,
	win: [], last: null, pend: {}, last_ev: {}, last_lvl: {}, cc_acc: null, dropped: 0, drop_ts: 0 };
/* channel names: db = group -> { name, provider, sid, ts } learned from the
 * streams (or { name: null, why, ts } when a stream carries none) */
let chn = { db: {}, err: null };

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
		if (mc_ignored(ip)) continue;   /* link-local, SSDP, SLP */
		push(out.groups, ip);
	}
	return out;
}

/* an MDB entry that stands for a home device watching a channel: learned
 * (not static) on a port toward the home. Entries on the ISP-side port
 * (reports seen from the operator's side, its router port), the bridge's
 * own joins (port = the bridge) and static ones say nothing about the
 * decoders - counted, a switched-off decoder was "still subscribed" */
function mdb_downstream(e) {
	return valid_dev(e?.port) && e.port != vl.upstream && e.port != vl.bridge &&
		e.state != 'permanent' && e.state != 'static' && index(vl.ports, e.port) >= 0;
}

/* channels subscribed on one port (decoders behind it) */
function port_groups(port) {
	let out = [];
	for (let e in (vl.mdb ?? []))
		if (e.port == port && mdb_downstream(e) && index(out, e.grp) < 0) push(out, e.grp);
	return out;
}

function igmp_poll() {
	if (!C.cfg.iptv.enabled || !C.cfg.iptv.igmp) return;
	let g;
	if (C.cfg.iptv.vlan) {
		/* bridged VLAN: the channels are the groups the bridge forwards on it */
		if (vl.mdb == null) return;
		let seen = {};
		g = { found: true, ver: null, groups: [] };
		for (let e in vl.mdb)
			if (mdb_downstream(e) && !seen[e.grp]) { seen[e.grp] = true; push(g.groups, e.grp); }
	}
	else {
		if (!C.cfg.iptv.igmp_dev) return;
		g = igmp_groups(C.cfg.iptv.igmp_dev);
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
 *   left   - the membership was dropped when the data stopped (and joined
 *            again): IGMP timeout
 *   joined - subscribed when the data stopped (also when the decoder left
 *            and joined the same channel later, retrying): the data just
 *            stopped coming
 */
function igmp_classify(from) {
	if (!C.cfg.iptv.igmp || !(C.cfg.iptv.igmp_dev || C.cfg.iptv.vlan) || igmp.groups == null) return null;
	/* the group change that causes a freeze comes within a sample or two of it */
	let rel = filter(igmp.hist, (h) => h.ts >= from - 3);
	if (!length(rel))
		return length(igmp.groups) ? 'joined' : null;

	let before = rel[0].before, after = igmp.groups;
	/* dropped when the data stopped (a timeout comes with the stop), not
	 * seconds later: many decoders leave and join the same channel again
	 * when no data comes - an operator-side stop was "IGMP timeout at home"
	 * (stall_igmp_left, weight 3 for the home side) */
	/* h.ts is when the change was read, up to one sample after it happened
	 * (sample_interval with the fast sampler, else the main interval) */
	/* (iptv_fast() is declared further down: ucode does not hoist it) */
	let step = (C.cfg.iptv.sample_interval > 0) ? C.cfg.iptv.sample_interval : C.cfg.interval;
	let lim = from + C.cfg.iptv.stall_after + step + 2;
	let emptied = length(filter(rel, (h) => !length(h.after) && h.ts <= lim)) > 0;
	if (length(before) && length(after) && join(',', before) != join(',', after)) return 'zap';
	if (emptied || !length(before)) return 'left';
	/* left and joined again later: subscribed when the data stopped */
	return length(after) ? 'joined' : null;
}

function proxy_process() {
	/* the proxy found last time is still running: no scan of all of /proc */
	if (igmp.proxy != null && igmp.pid != null &&
	    trim(fs.readfile(`${PROC}/${igmp.pid}/comm`) ?? '') == igmp.proxy)
		return { name: igmp.proxy, pid: igmp.pid };
	/* no proxy seen since the start (bridged IPTV needs none): look once a
	 * minute only; nothing is reported until one has been seen */
	/* monotonic: after the clock was set back it would not look for an hour */
	let t = mono();
	if (!igmp.proxy_seen && igmp.scan_ts != null && t - igmp.scan_ts < 60) return null;
	igmp.scan_ts = t;
	for (let pid in (fs.lsdir(PROC) ?? [])) {
		if (!match(pid, /^[0-9]+$/)) continue;
		let c = trim(fs.readfile(`${PROC}/${pid}/comm`) ?? '');
		if (index(PROXIES, c) >= 0) return { name: c, pid };
	}
	return null;
}

function sample_proxy() {
	if (!C.cfg.iptv.enabled || !C.cfg.iptv.igmp) return;
	let p = proxy_process();
	let t = now();

	if (p && igmp.proxy == null && igmp.proxy_seen)
		C.emit('warn', 'iptv', 'proxy', 'proxy_up', { name: p.name, dur: t - igmp.proxy_since });
	else if (p && igmp.proxy != null && p.pid != igmp.pid)
		C.emit('warn', 'iptv', 'proxy', 'proxy_restart', { name: p.name });
	else if (!p && igmp.proxy != null) {
		C.emit('err', 'iptv', 'proxy', 'proxy_down', { name: igmp.proxy });
		igmp.proxy_since = t;
	}

	if (p) {
		igmp.proxy_seen = true;
		igmp.last_name = p.name;
		igmp.pid = p.pid;
	}
	igmp.proxy = p?.name;
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
let dec = { list: {}, err: null, t: 0, shared: {}, t0: null };

function dhcp_src(mac) {
	return C.cfg.iptv.dec_labels[mac] || mac;
}

function dhcp_seen(x, via) {
	let mac = lc(`${x.mac ?? ''}`);
	if (!match(mac, /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/)) return;
	let t = (type(x.t) == 'int' && x.t > 0) ? x.t : now();
	let s = dhl.mac[mac] ??= { mac, ip: null, acks: 0, renew: 0, changes: 0, naks: 0, offer_t: null, last_ack: null,
		lease: null, server: null, expired: false, via };
	let src = dhcp_src(mac);
	s.via = via;
	/* an OFFER answers a DISCOVER: the decoder asks from scratch (booted) */
	if (x.type == 2) { s.offer_t = t; s.boot_t = t; return; }
	if (x.type == 6) {
		s.naks++;
		C.emit('warn', 'iptv', src, 'dhcp_nak', { mac, ip: s.ip, server: x.server, via });
		return;
	}
	if (x.type != 5 || !match(`${x.ip ?? ''}`, /^[0-9.]+$/) || x.ip == '0.0.0.0') return;
	/* an ACK off the renewal schedule (before T1: the server's option 58,
	 * else half the lease) is a
	 * decoder that booted and asked for its old address (INIT-REBOOT, no
	 * OFFER). A renewal is not: it was taken for a restart proof, and every
	 * renewal at the end of the normal silence between two IGMP reports
	 * with a stall in it was logged as a restart */
	/* (with a T1 shorter than half the lease every renewal was a "boot") */
	let ren = (s.t1 > 0 && s.t1 < (s.lease ?? 0)) ? s.t1 : (s.lease ?? 0) * 0.5;
	/* tsmon tells it from the ACK itself (ciaddr): a renewal has it set, a
	 * start not. Trusted only once a renewal of this decoder came with it
	 * set - a server that never copies it would make every ACK a start.
	 * Without it (dnsmasq log, an older helper) by the schedule above */
	if (x.renew === true) s.ci_ok = true;
	let start = (s.ci_ok && x.renew === false) ? true : (s.ci_ok && x.renew === true) ? false : null;
	if (start === true ||
	    (start == null && s.last_ack != null && s.lease && t - s.last_ack > 30 && t - s.last_ack < ren * 0.9))
		s.boot_t = t;
	let fresh = s.offer_t != null && t - s.offer_t <= 15;
	s.offer_t = null;
	if (s.ip == null)
		C.emit('info', 'iptv', src, 'dhcp_lease', { mac, ip: x.ip, lease: x.lease, server: x.server, router: x.router, via });
	else if (x.ip != s.ip) {
		s.changes++;
		C.emit('warn', 'iptv', src, 'dhcp_ip_change', { mac, from: s.ip, to: x.ip, lease: x.lease, server: x.server, via });
	}
	/* an OFFER before it: the decoder started from scratch - after a night
	 * switched off its lease ran out, and every such morning start was a
	 * "renewed too late" (warning, counted against the operator) */
	else if (fresh)
		C.emit('info', 'iptv', src, 'dhcp_new', { mac, ip: x.ip, lease: x.lease, via });
	/* nor a start with INIT-REBOOT (asks for its old address, no OFFER):
	 * seen by ciaddr, else by it being switched off meanwhile or on again
	 * only shortly ago (without membership data "on" comes with its first
	 * frame, before the ACK) */
	else if (s.lease && s.last_ack != null && t - s.last_ack > s.lease + 5 && start !== true &&
	         !dec.list[mac]?.off && !(dec.list[mac]?.on_t != null && t - dec.list[mac].on_t <= 120)) {
		s.renew++;
		/* not known to have been on the whole time (no decoder data: routed
		 * IPTV, decoder detection off) and no ciaddr proof of a renewal: it
		 * may just have been switched off overnight - noted only (unk), not
		 * counted against the operator (every morning start was a warning) */
		let unk = start !== false && dec.list[mac] == null;
		C.emit(unk ? 'info' : 'warn', 'iptv', src, 'dhcp_late', { mac, ip: x.ip, late: t - s.last_ack - s.lease, lease: s.lease, via,
			unk: unk ? 1 : null });
	}
	else s.renew++;
	s.acks++;
	s.ip = x.ip;
	s.last_ack = t;
	s.lease = (x.lease > 0) ? x.lease : null;
	s.t1 = (x.t1 > 0) ? x.t1 : null;
	s.server = x.server ?? s.server;
	s.expired = false;
}

/* new entries of tsmon's DHCP ring (numbered per helper process) */
function dhcp_ingest(r) {
	if (!C.cfg.iptv.dhcp || type(r?.dhcp) != 'array') return;
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
	if (C.cfg.iptv.dec_labels[mac] == null) return true;
	dhcp_seen({ t: l.ts, type: m[1] == 'ACK' ? 5 : 6, mac, ip: m[2] }, 'dnsmasq');
	return true;
}

function dhcp_tick() {
	if (!C.cfg.iptv.dhcp) return null;
	let t = now(), out = [];
	for (let mac, s in dhl.mac) {
		let d = dec.list[mac];
		/* not for a decoder switched off: in standby (still in the MAC table
		 * by its stray frames) it may well not renew - that is no fault of the
		 * operator's DHCP (it was a dhcp_bad against the operator) */
		if (s.lease && s.last_ack != null && !s.expired && t - s.last_ack > s.lease + 30 && d?.present !== false && !d?.off) {
			s.expired = true;
			/* without decoder data it cannot be told from a decoder switched
			 * off for the night: noted only (unk), not counted against the operator */
			C.emit(d == null ? 'info' : 'warn', 'iptv', dhcp_src(mac), 'dhcp_expired', { mac, ip: s.ip, lease: s.lease, last: s.last_ack,
				unk: d == null ? 1 : null });
		}
		push(out, { mac, label: C.cfg.iptv.dec_labels[mac] ?? '', ip: s.ip, lease: s.lease, server: s.server, last_ack: s.last_ack,
			acks: s.acks, renew: s.renew, changes: s.changes, naks: s.naks, expired: s.expired, via: s.via });
	}
	return out;
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

function vlan_sample() {
	let vid = C.cfg.iptv.vlan;
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

	/* which bridge and which port leads to the ISP: worked out again only
	 * when the ports of the VLAN change, else once a minute (this runs every
	 * second; the sysfs reads per port were most of its work) */
	let key = join(',', ports), mt = mono();
	if (key != vl.key || mt - (vl.topo_m ?? 0) >= 60) {
		vl.key = key;
		vl.topo_m = mt;
		/* the bridge itself is listed when it is a member too (br.236 exists) */
		let br = C.cfg.iptv.bridge || null;
		if (!br)
			for (let p in ports) {
				let m = base(fs.readlink(`${SYSNET}/${p}/master`));
				/* the name goes into bridge commands run by a shell: kernel
				 * names may hold characters the shell would act on */
				if (valid_dev(m)) { br = m; break; }
			}
		vl.bridge = br;
		vl.ports = filter(ports, (p) => p != br);
		/* routers where every port is a switch (DSA) port: the one named "wan" */
		vl.upstream = C.cfg.iptv.upstream || filter(vl.ports, is_uplink)[0] ||
			filter(vl.ports, (p) => match(p, /^wan/))[0] || null;

		if (br) {
			let on = rd(br, 'bridge/vlan_stats_enabled');
			if (on == '0') {
				fs.writefile(`${SYSNET}/${br}/bridge/vlan_stats_enabled`, '1');
				on = rd(br, 'bridge/vlan_stats_enabled');
			}
			vl.stats = on;
		}
	}
	let br = vl.bridge;

	if (!length(vl.ports)) { vl.error = 'vlan_not_found'; vl.cnt = null; return; }

	/* upstream port's RX (equals the VLAN-wide counter unless per-port) */
	let s = vl.upstream ? st[vl.upstream] : null;
	if (!s || s.rx_bytes == null)
		for (let p in vl.ports)
			if (st[p]?.rx_bytes != null && (!s || st[p].rx_bytes > s.rx_bytes)) s = st[p];

	if (s?.rx_bytes == null) { vl.error = 'no_stats'; vl.cnt = null; }
	else { vl.error = (vl.stats == '0') ? 'stats_off' : null; vl.cnt = { b: s.rx_bytes, p: s.rx_packets ?? 0 }; }

	vl.mdb = (br && C.cfg.iptv.igmp)
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
 *           and a trace of its start (its DHCP, see dec_quiet_proof)
 * Back within dec_off s: decoder_restart; longer: decoder_off / decoder_on.
 */

/* s: a decoder directly on a port whose link is down that long is off */
const DEC_LINK_OFF = 120;

/* does the bridge tool take "vlan" in fdb show: null = not known yet */
let fdb_vlan = null;

/* MAC -> { port, age } of the decoders in the IPTV VLAN */
function dec_fdb() {
	/* only the IPTV VLAN: when it is part of the LAN bridge (br-lan / br-all)
	 * the whole table is every phone and PC at home, read and parsed every
	 * interval for the few decoders in it */
	let j = (fdb_vlan !== false) ? bridge_json(`-s fdb show br ${vl.bridge} vlan ${int(C.cfg.iptv.vlan)}`) : null;
	if (j == null && fdb_vlan !== true) {
		j = bridge_json(`-s fdb show br ${vl.bridge}`);
		/* the whole table answers, the filtered one did not: no filter from now on */
		if (j != null && fdb_vlan == null) fdb_vlan = false;
	}
	else if (j != null) fdb_vlan = true;
	if (j == null) return null;
	let out = {};
	for (let e in j) {
		let mac = lc(`${e?.mac ?? ''}`);
		if (!match(mac, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/)) continue;
		/* multicast / local entries, other VLANs, the ISP side */
		if (hex(substr(mac, 0, 2)) & 1) continue;
		if (e.state == 'permanent' || e.state == 'static' || index(e.flags ?? [], 'self') >= 0) continue;
		if (e.master && e.master != vl.bridge) continue;
		if (e.vlan != null && e.vlan != C.cfg.iptv.vlan) continue;
		if (!valid_dev(e.ifname) || e.ifname == vl.upstream || index(vl.ports, e.ifname) < 0) continue;
		out[mac] = { port: e.ifname, age: (type(e.updated) == 'int') ? e.updated : null };
	}
	return out;
}

/*
 * MACs the bridge also has in another VLAN: the switch, a router or an AP on
 * that port (a managed switch sends its loop-detection frames in every VLAN
 * it carries, so its own MAC turns up in the IPTV VLAN every few minutes).
 * They were taken for a decoder that was switched off and on all day. Kept
 * for a day after the last sighting (the entry ages out in between). A MAC
 * named in the settings or that got its address from the operator stays a
 * decoder.
 */
let dec_other = { t: 0, seen: {} };
function dec_other_vlans(t) {
	if (t - dec_other.t >= 300) {
		dec_other.t = t;
		let j = bridge_json(`-s fdb show br ${vl.bridge}`);
		for (let e in (j ?? [])) {
			let mac = lc(`${e?.mac ?? ''}`);
			if (e?.vlan != null && e.vlan != C.cfg.iptv.vlan && e.ifname != vl.upstream && index(vl.ports, e.ifname) >= 0)
				dec_other.seen[mac] = t;
		}
		for (let mac, ts in dec_other.seen) if (t - ts > 86400) delete dec_other.seen[mac];
	}
	return dec_other.seen;
}

function dec_not_decoder(mac, other) {
	return other[mac] != null && C.cfg.iptv.dec_labels[mac] == null && !(dhl.mac[mac]?.acks > 0);
}

/* did the stream stop (freeze, lost, off) between from and to? */
function dec_stream_hit(from, to) {
	let evs = C.events();
	for (let i = length(evs) - 1; i >= 0; i--) {
		let e = evs[i];
		if (e.ts < from - 60) break;
		if (e.host) continue;
		if (e.area == 'iptv' && e.ts >= from - 10 && e.ts <= to + 5 &&
		    (e.type == 'stream_stall' || e.type == 'stream_off' || e.type == 'stream_lost')) return true;
	}
	return false;
}

/* were the operator's IGMP queries missing between from and now? A decoder
 * that only receives sends nothing but its IGMP reports, which answer the
 * queries: without them it goes silent and the bridge forgets it, and when it
 * speaks again (the queries are back, or a channel change) that is no
 * restart - taken for one, the freezes of the silence (the operator's fault)
 * were put down to the decoder and left out of the analysis */
function dec_noquery_hit(from) {
	/* nobody asks on the VLAN (the router's querier in mode router / backup
	 * is the one the decoders answer, not the operator): the same silence */
	if (C.querier_none()) return true;
	/* the router's own querier keeps the decoders talking: the operator's
	 * queries pausing (dropped anyway in mode router) silences nobody.
	 * Judged by who asked when the pause began, not now: in mode backup the
	 * router takes over only after the memberships expired, and the
	 * decoders' silence before that was the operator's pause */
	if (igq.silent && !igq.silent_router) return true;
	let evs = C.events();
	for (let i = length(evs) - 1; i >= 0; i--) {
		let e = evs[i];
		if (e.ts < from - 5) break;
		if (e.d?.router && (e.type == 'igmp_noquery' || e.type == 'igmp_noquery_ok')) continue;
		if (!e.host && (e.type == 'igmp_noquery' || e.type == 'igmp_noquery_ok' ||
		    e.type == 'igmp_no_querier' || e.type == 'igmp_no_querier_ok')) return true;
	}
	return false;
}

/* a "quiet" restart (silence, stream stopped, frames again) needs more than
 * that: a decoder that only watches speaks just when it answers the operator's
 * IGMP query (every ~125 s, plus up to max_resp), so a silence of a minute
 * or two is its normal rhythm, and any stall of the stream in it was taken for
 * a restart. A real restart asks for its address on the way up: a DHCP OFFER /
 * ACK of this decoder between the last frame before the silence and the first
 * one after it. Where the DHCP of this decoder is not seen at all, the silence
 * must be longer than the decoder takes to answer a query. */
function dec_quiet_proof(mac, from, to) {
	let s = dhl.mac[mac];
	/* its DHCP is seen: only a boot of it (OFFER, ACK off the renewal
	 * schedule) in the silence proves a restart */
	if (s != null && (s.last_ack != null || s.boot_t != null))
		return s.boot_t != null && s.boot_t >= from - 5 && s.boot_t <= to + 15;
	/* the decoder answers the querier it hears: the router's own when it is
	 * the one (its interval may differ from the operator's) */
	return to - from > (C.querier_query() ?? igmpq_expected()) + ((igq.max_resp > 0) ? igq.max_resp / 10.0 : 10) + 15;
}

/* more than the decoders behind the port (any VLAN: a PC, the switch's own
 * address): a switch. Its link going down is the switch or its cable, not a
 * decoder restart. Read once a minute until known, then every 10 min (a
 * laptop plugged in once made the port a "switch" for good; back to "the
 * decoder alone" after an hour without other devices). An empty
 * table (the link is down, the port flushed) keeps what was known.
 * An unmanaged switch with only the decoder behind it sends nothing of its
 * own: it cannot be told from the decoder directly on the port. */
function dec_port_shared(port) {
	let p = dec.shared[port] ??= { m: null, v: false };
	if (p.m != null && mono() - p.m < (p.v ? 600 : 60)) return p.v;
	p.m = mono();
	let j = bridge_json(`fdb show br ${vl.bridge} brport ${port}`);
	/* the table could not be read: keep what was known (a switch turned
	 * into a decoder on the port for a minute) */
	if (j == null) return p.v;
	let macs = {}, n = 0;
	for (let e in j) {
		let mac = lc(`${e?.mac ?? ''}`);
		if (!match(mac, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/) || (hex(substr(mac, 0, 2)) & 1)) continue;
		if (e.state == 'permanent' || e.state == 'static' || index(e.flags ?? [], 'self') >= 0) continue;
		if (!macs[mac]) { macs[mac] = true; n++; }
	}
	if (!n) return p.v;
	let decs = 0;
	for (let mac, d in dec.list) if (d.port == port) decs++;
	let v = n > max(1, decs);
	/* a switch becomes "the decoder alone" only after an hour without other
	 * devices: a PC or laptop behind it asleep for a while ages out of the
	 * table, and the switch losing power then was logged as the decoder off */
	if (v || !p.v) { p.v = v; p.no = null; }
	else if ((p.no ??= p.m) != null && p.m - p.no >= 3600) { p.v = false; p.no = null; }
	return p.v;
}

/* was this decoder the only one watching? Another port with a channel, or
 * another decoder on its own port that is on: then a freeze while it
 * restarted is the stream's (the bitrate is the whole VLAN's - below
 * min_kbps the others' channels stopped too), not the restart's */
function dec_alone(mac, port) {
	for (let p in vl.ports)
		if (p != port && length(port_groups(p))) return false;
	for (let m, o in dec.list)
		if (m != mac && o.port == port && o.present && !o.off) return false;
	return true;
}

/* the last on/off event of this decoder in the log is "off" */
function dec_off_logged(mac) {
	let evs = C.events();
	for (let i = length(evs) - 1; i >= 0; i--) {
		let e = evs[i];
		if (e.d?.mac != mac) continue;
		if (e.type == 'decoder_off') return true;
		if (e.type == 'decoder_on' || e.type == 'decoder_restart') return false;
	}
	return false;
}

function dec_poll() {
	if (!C.cfg.iptv.decoders || !C.cfg.iptv.vlan || !vl.bridge || !BRIDGE) { dec.err = null; return null; }
	let fdb = dec_fdb(), t = now();
	if (fdb == null) { dec.err = 'fdb_failed'; return null; }
	dec.err = null;
	/* the first reading of this run: a decoder silent since before it was off then already */
	dec.t0 ??= t;

	let other = dec_other_vlans(t);
	for (let mac in keys(fdb))
		if (dec_not_decoder(mac, other)) {
			delete fdb[mac];
			delete dec.list[mac];
		}
	for (let mac in keys(dec.list))
		if (dec_not_decoder(mac, other)) delete dec.list[mac];

	for (let mac, x in fdb) {
		let d = dec.list[mac] ??= { mac, present: true, since: t, port: x.port, gone_at: null, quiet_from: null, off: false };
		d.port = x.port;
		d.seen = t;
	}
	/* working membership data: a decoder that watches has a group on its port */
	let mdb_ok = vl.mdb != null && (igmp.seen || rd(vl.bridge, 'bridge/multicast_snooping') == '1');

	for (let mac, d in dec.list) {
		let x = fdb[mac], src = C.cfg.iptv.dec_labels[mac] || mac;
		let link = rd(d.port, 'carrier'), cc = rd(d.port, 'carrier_changes');
		let here = x != null && link != '0';
		let active = here ? t - (x.age ?? 0) : null;

		if (!here) {
			if (d.present) {
				d.present = false;
				/* the port's link went down, also only for less than a tick
				 * (the bridge flushed the port's entries, carrier is up again) */
				let lk = link == '0' || (cc != null && d.cc != null && cc != d.cc);
				/* the last frame, not the moment the entry vanished. Already
				 * off: the time it was switched off stays (a stray frame in
				 * standby moved it, and "back after" was the time since it) */
				if (!d.off) d.gone_at = (link == '0') ? t : (d.last_active ?? t);
				/* behind a switch the link is the switch's or its cable's;
				 * otherwise the entry aged out (300 s of silence: a decoder
				 * that only watches sends nothing between its IGMP reports) or
				 * the bridge flushed it - neither is a restart by itself: judged
				 * as "quiet" when it is back (it was logged as one, "fdb") */
				d.via = (lk && !dec_port_shared(d.port)) ? 'link' : lk ? 'port' : 'aged';
			}
			/* its own link down (decoder directly on the port): a restart takes
			 * the link down only for seconds, so after DEC_LINK_OFF it is off
			 * (unplugged, power) - not shown "not visible" for dec_off */
			let lim = (d.via == 'link' && link == '0') ? min(DEC_LINK_OFF, C.cfg.iptv.dec_off) : C.cfg.iptv.dec_off;
			if (!d.off && t - d.gone_at > lim) {
				d.off = true;
				C.emit('info', 'iptv', src, 'decoder_off', { mac, port: d.port, via: (d.via == 'port') ? 'link' : d.via }, d.gone_at);
			}
		}
		else {
			if (!d.present) {
				let dur = max(1, t - d.gone_at);
				d.present = true;
				if (d.off) {
					/* in the table again by a stray frame in standby (DHCP, ARP,
					 * NTP - every few minutes): still off. It was logged as on,
					 * and off again by "leave" below a tick later, with the same
					 * time - a pair for every such frame. Without membership data
					 * the frame is all there is */
					if (!mdb_ok || length(port_groups(x.port))) {
						C.emit('info', 'iptv', src, 'decoder_on', { mac, port: x.port, dur });
						d.off = false;
						d.on_t = t;
						d.since = t;
					}
				}
				else if (d.via == 'aged') {
					/* back after a silence: a restart only as by "quiet" below
					 * (it was logged as one after every silence of 5 min, with
					 * the whole silence as its time) */
					let from = d.quiet_from ?? d.gone_at, qd = active - from;
					if (qd >= C.cfg.iptv.dec_silence && qd <= C.cfg.iptv.dec_off && dec_stream_hit(from, active) && !dec_noquery_hit(from) &&
					    dec_quiet_proof(mac, from, active))
						C.emit('info', 'iptv', src, 'decoder_restart', { mac, port: x.port, dur: qd, via: 'quiet', stream: true,
							alone: dec_alone(mac, x.port) }, from);
					d.since = t;
				}
				/* the switch it is behind lost its link: not the decoder */
				else if (d.via == 'port') d.since = t;
				else {
					C.emit('info', 'iptv', src, 'decoder_restart', { mac, port: x.port, dur, via: d.via,
						stream: dec_stream_hit(d.gone_at, t), alone: dec_alone(mac, x.port) }, d.gone_at);
					d.since = t;
				}
				d.quiet_from = null;
			}
			/* switched off by its channel being left (below): on again when
			 * it talks and watches again - not by a stray frame in standby */
			else if (d.off) {
				if (x.age != null && x.age < C.cfg.iptv.dec_silence && (!mdb_ok || length(port_groups(d.port)))) {
					C.emit('info', 'iptv', src, 'decoder_on', { mac, port: x.port, dur: max(1, t - d.gone_at) });
					d.off = false;
					d.on_t = t;
					d.since = t;
					d.quiet_from = null;
				}
			}
			/* quiet: a restart behind a switch, only when the stream stopped meanwhile */
			else if (x.age != null) {
				if (x.age >= C.cfg.iptv.dec_silence) d.quiet_from ??= active;
				else if (d.quiet_from != null) {
					let dur = active - d.quiet_from;
					if (dur >= C.cfg.iptv.dec_silence && dur <= C.cfg.iptv.dec_off && dec_stream_hit(d.quiet_from, active) &&
					    !dec_noquery_hit(d.quiet_from) && dec_quiet_proof(mac, d.quiet_from, active))
						C.emit('info', 'iptv', src, 'decoder_restart', { mac, port: x.port, dur, via: 'quiet', stream: true,
							alone: dec_alone(mac, x.port) }, d.quiet_from);
					d.quiet_from = null;
				}
			}
			d.last_active = active;
			d.cc = cc;
			/* known before its link goes down (that flushes the port's entries) */
			dec_port_shared(d.port);
		}

		/* switched off (standby, power): in the table, silent and no channel
		 * subscribed on its port. The MAC table alone tells it only after
		 * ageing_time (300 s) plus dec_off - until then it was shown "not
		 * visible" (red) while it was off, also when it was off already at
		 * the start. A decoder that watches answers every query, so its group
		 * stays in the MDB (a hard restart sends no leave: still a restart).
		 * Only with working membership data (snooping on), not while another
		 * decoder watches on the same port, nor while nobody asks (the
		 * operator's queries missing, no querier on the VLAN: then the groups
		 * expire by themselves). Only while it is in the table: gone (link
		 * down, aged out) is judged by dec_off above - a restart with the
		 * link down for more than dec_silence was logged as off and on */
		if (!d.off && here && mdb_ok && !length(port_groups(d.port))) {
			let last = active;
			if (last != null && t - last >= C.cfg.iptv.dec_silence && !dec_noquery_hit(last)) {
				d.off = true;
				d.gone_at = last;
				d.quiet_from = null;
				/* off already and logged by the run before (it was logged again
				 * after every restart of the collector - each Save & Apply - dated
				 * before monitor_start). Judged by the log, not by the start time:
				 * switched off less than dec_silence before a restart it was never
				 * logged by either run */
				if (last >= dec.t0 - 5 || !dec_off_logged(mac))
					C.emit('info', 'iptv', src, 'decoder_off', { mac, port: d.port, via: 'leave' }, last);
			}
		}
		/* auto-found and gone for a day: forget it */
		if (!here && C.cfg.iptv.dec_labels[mac] == null && t - (d.seen ?? t) > 86400) delete dec.list[mac];
	}

	let out = [];
	for (let mac, d in dec.list) {
		let chs = port_groups(d.port);
		push(out, { mac, label: C.cfg.iptv.dec_labels[mac] ?? '', port: d.port, present: d.present, off: d.off,
			since: (d.present && !d.off) ? d.since : d.gone_at, active: d.last_active, quiet: d.quiet_from != null,
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
		window: TSQ_WIN, warn: C.cfg.iptv.q_warn, fail: C.cfg.iptv.q_fail, last: tsq.last,
		dropped: tsq.dropped, drop_ts: tsq.drop_ts || null };
}

function iptv_on() {
	return C.cfg.iptv.enabled && (C.cfg.iptv.device || C.cfg.iptv.vlan);
}

function iptv_fast() {
	return iptv_on() && C.cfg.iptv.sample_interval > 0;
}

/* ------------------------------------------------- IPTV channel names */

/* where the helper listens: the ISP-side port of the IPTV VLAN, or the
 * configured device (the decoder port is measured outgoing) */
function tsq_target() {
	if (C.cfg.iptv.vlan) {
		if (!valid_dev(vl.upstream)) return null;
		return { dev: vl.upstream, vid: C.cfg.iptv.vlan, dir: 'in' };
	}
	if (!valid_dev(C.cfg.iptv.device)) return null;
	return { dev: C.cfg.iptv.device, vid: 0, dir: C.cfg.iptv.direction == 'tx' ? 'out' : 'in' };
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
	return C.cfg.iptv.channels[grp] ?? chn.db[grp]?.name ?? null;
}

/* names (or groups, when not known) of the channels joined now, for C.events()
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
		let man = C.cfg.iptv.channels[g], e = chn.db[g];
		if (man) names[g] = { name: man, src: 'manual' };
		else if (e?.name) names[g] = { name: e.name, provider: e.provider, src: 'sdt' };
		else if (e) names[g] = { name: null, why: e.why };
	}
	return { enabled: C.cfg.iptv.names, error: chn.err, names };
}

/* request from the web UI: forget the learned names */
function handle_chn_forget() {
	let f = `${VARDIR}/channels_forget`;
	if (!fs.stat(f)) return;
	fs.unlink(f);
	chn.db = {};
	chn_save();
}

/* -------------------------------------- IGMP queries of the operator */

/*
 * "Does the operator still ask?": the operator's router keeps the IPTV
 * memberships alive by sending an IGMP general query (to 224.0.0.1) about
 * every 125 s and the decoders (through the router's proxy) answer it.
 * When the queries stop, the memberships time out after about two intervals
 * - 260 s with the defaults - and the stream stops, again and again every
 * few minutes: the freezes look random but are an operator-side fault.
 * The helper (isp-tester-tsmon -Q) sees the queries on the port towards the
 * ISP and reports how many came and how long ago the last general one was.
 * The bridge's own "IGMP timers" (sysfs) are only this router's settings:
 * they say nothing about what the operator actually sends. Silence is judged
 * against the interval seen (the median of the last gaps, else the query's
 * own interval, else 125 s): more than two of them (plus the response time)
 * without a general query = the memberships can expire. Only when queries
 * were seen before, so an operator that never sends any is not reported as
 * "stopped" but shown as "none seen".
 */

function igmpq_ingest(m, t, pid) {
	if (type(m) != 'object') { igq.on = false; return; }
	igq.on = true;
	if (igq.pid != pid) {
		/* a new helper counts from zero; time without it is unknown, not silence */
		igq.pid = pid;
		igq.gen = 0;
		igq.since = t;
		/* the queries the old one saw may have been missed in between:
		 * the gap to its last one is no interval */
		igq.fresh = true;
		/* a silence in progress stays open (and ends with igmp_noquery_ok at
		 * the next query): reset quietly, it never ended on the timeline and
		 * the analysis counted every later freeze as "no queries" */
	}
	let gen = m.gen ?? 0;
	if (gen > igq.gen) {
		/* whole seconds: the helper's age has a decimal, and a time like
		 * 1763793600.7 was the timestamp of igmp_noquery(_ok) and the "since"
		 * in it - a fraction that the clock fix (which moves int fields only)
		 * left behind on a clock step */
		let ts = int(t - ((m.gen_age ?? -1) >= 0 ? m.gen_age : 0) + 0.5);
		if (gen - igq.gen == 1 && !igq.fresh && igq.last_ts != null && ts > igq.last_ts) {
			push(igq.ivals, round(ts - igq.last_ts, 0));
			if (length(igq.ivals) > IGQ_RING) shift(igq.ivals);
		}
		if (igq.silent) {
			igq.silent = false;
			C.emit('info', 'iptv', 'igmp', 'igmp_noquery_ok', { dur: round(ts - igq.silent_ref, 0), src: m.src,
				router: igq.silent_router ? 1 : null }, ts);
			igq.silent_router = false;
		}
		igq.total += gen - igq.gen;
		igq.gen = gen;
		igq.last_ts = ts;
		igq.fresh = false;
		igq.ever = true;
	}
	if (m.src) igq.src = m.src;
	igq.ver = m.ver || igq.ver;
	igq.qqic = (m.qqic > 0) ? m.qqic : igq.qqic;
	igq.max_resp = (m.max_resp > 0) ? m.max_resp : igq.max_resp;
}

/* the interval between the operator's general queries, in s */

/* silence longer than this lets the memberships expire (s) */

function igmpq_check(t) {
	if (!igq.on || !igq.ever || igq.silent) return;
	let ref = max(igq.last_ts ?? 0, igq.since ?? t);
	let sil = t - ref;
	if (sil > igmpq_limit()) {
		igq.silent = true;
		igq.silent_ref = ref;
		/* the router asks the decoders itself (mode router: the operator's
		 * queries are dropped; backup: it took over): no membership expires,
		 * so the pause is only noted - it was a warning, it kept the card
		 * yellow and every freeze and switch-off in it went to the operator */
		igq.silent_router = C.querier_router();
		/* dated from when the memberships began to expire, so a freeze at that moment falls inside the period */
		C.emit(igq.silent_router ? 'info' : 'warn', 'iptv', 'igmp', 'igmp_noquery', { silent: round(sil, 0), expected: igmpq_expected(), src: igq.src,
			ver: igq.ver, since: ref, router: igq.silent_router ? 1 : null }, min(t, ref + 2 * igmpq_expected()));
	}
}

/* the operator has been silent long enough for the memberships to expire.
 * Then the groups vanish (from the bridge's table, which is not refreshed
 * without the queries) and the stream stops - exactly what a decoder being
 * switched off looks like: the freeze was logged as "decoder switched off"
 * (info), not counted, while it is the operator-side fault this is about.
 * Worked out here, not from igq.silent: that is set on the main tick, up to
 * an interval after the expiry the 1 s sampler sees first. */
function igq_expired(t) {
	if (!C.cfg.iptv.igmp_query || !igq.on || !igq.ever || C.querier_router()) return false;
	return igq.silent || t - max(igq.last_ts ?? 0, igq.since ?? t) > igmpq_limit() - 5;
}

function igmpq_out() {
	if (!C.cfg.iptv.igmp_query || !igq.on) return null;
	let t = now(), seen_for = t - (igq.since ?? t);
	return { gen: igq.total, last: igq.last_ts, age: igq.last_ts != null ? round(t - igq.last_ts, 0) : null,
		expected: igmpq_expected(), limit: igmpq_limit(), silent: igq.silent, router: igq.silent ? igq.silent_router : null, since: igq.silent ? igq.silent_ref : null,
		src: igq.src, ver: igq.ver, qqic: igq.qqic, max_resp: igq.max_resp, seen_for: round(seen_for, 0),
		/* nothing at all in more than the time the memberships last */
		never: !igq.ever && seen_for > igmpq_limit() + 60 };
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
	if (level == 'ok' && C.recent_level('iptv', 'stream') != 'ok') {
		level = 'warn';
		push(reasons, { c: 'recent_events' });
	}

	/* picture quality: yellow for a while after errors, or when it cannot run */
	if (C.cfg.iptv.quality) {
		if (tsq.err) {
			level = worst(level, 'warn');
			push(reasons, { c: 'ts_' + tsq.err });
		}
		else if (C.recent_level('iptv', 'quality') != 'ok') {
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
		device: C.cfg.iptv.vlan ? sprintf('VLAN %d', C.cfg.iptv.vlan) : C.cfg.iptv.device,
		direction: C.cfg.iptv.direction, min_kbps: C.cfg.iptv.min_kbps,
		sample_interval: iptv_fast() ? C.cfg.iptv.sample_interval : C.cfg.interval,
		min: iptv.tick?.min, stall_s: iptv.tick?.stall_s
	};
	if (C.cfg.iptv.quality) o.quality = tsq_out();

	if (C.cfg.iptv.vlan) {
		o.vlan = { id: C.cfg.iptv.vlan, bridge: vl.bridge, upstream: vl.upstream, ports: vl.ports, error: vl.error };
		if (vl.error && vl.error != 'stats_off') {
			level = worst(level, 'warn');
			push(reasons, { c: 'vlan_' + vl.error, vlan: C.cfg.iptv.vlan });
			o.level = level;
		}
	}

	let brname = C.cfg.iptv.bridge || (C.cfg.iptv.vlan ? vl.bridge : null);
	if (brname) {
		let b = `${brname}`;
		/* (/ 100.0: as integers 25999 cs were 259 s, not rounded to 260) */
		let cs = (f) => { let v = num(rd(b, `bridge/${f}`), null); return (v == null) ? null : round(v / 100.0, 0); };
		o.bridge = {
			name: b,
			snooping: rd(b, 'bridge/multicast_snooping'),
			querier: rd(b, 'bridge/multicast_querier'),
			igmp_version: rd(b, 'bridge/multicast_igmp_version'),
			/* kernel timers are in centiseconds */
			membership_interval: cs('multicast_membership_interval'),
			query_interval: cs('multicast_query_interval'),
			mdb: C.cfg.iptv.vlan ? vl.mdb : bridge_mdb(b)
		};
	}

	if (C.cfg.iptv.igmp) {
		o.igmp = {
			dev: C.cfg.iptv.igmp_dev || null,
			found: igmp.found, version: igmp.version,
			groups: igmp.groups, current: chn_current(), last_change: igmp.last_change,
			proxy: igmp.proxy ?? igmp.last_name, proxy_running: igmp.proxy != null, proxy_seen: igmp.proxy_seen
		};
		if (igmp.proxy == null && igmp.proxy_seen) {
			level = worst(level, 'warn');
			push(reasons, { c: 'proxy_down', name: igmp.last_name });
			o.level = level;
		}
		o.igmpq = igmpq_out();
		if (o.igmpq?.silent && !o.igmpq.router) {
			level = worst(level, 'warn');
			push(reasons, { c: 'igmp_noquery', since: o.igmpq.since });
			o.level = level;
		}
	}
	o.channels = chn_out(o);
	return o;
}

/* the channel watched while the stream played is no longer subscribed, and
 * no other one was joined since the data stopped (that is a channel change) */
function watch_left() {
	if (iptv.watch == null || igmp.groups == null || index(igmp.groups, iptv.watch) >= 0) return false;
	let from = iptv.low_w ?? iptv.stall_since;
	if (from != null)
		for (let g in igmp.groups)
			if ((igmp.joined[g] ?? 0) > 0 && igmp.joined[g] >= from - 5) return false;
	return true;
}

/* true when the membership data works (groups were seen before) and
 * nobody is subscribed to any channel right now: a decoder that is switched
 * off leaves its groups, a freeze with the decoder on does not (or the
 * decoder joins again within seconds) */
let ns_err = null;
function nobody_subscribed() {
	/* an error here left a stop undecided for good (asked every second
	 * until the stream came back): then it is judged a freeze */
	try {
		if (!C.cfg.iptv.igmp || !(C.cfg.iptv.off_after > 0) || !igmp.seen || igmp.groups == null || igq_expired(now()))
			return false;
		/* nothing subscribed, or the channel that was being watched was left
		 * (another decoder or a service group may keep other groups joined) */
		return length(igmp.groups) == 0 || watch_left();
	}
	catch (e) {
		if (ns_err != `${e}`) {
			ns_err = `${e}`;
			warn(`isp-tester: iptv: membership check failed: ${e}\n${e.stacktrace?.[0]?.context ?? ''}\n`);
		}
		return false;
	}
}

/* the decoder was switched off: the stream stopped with nobody subscribed */
function iptv_mark_off(w) {
	C.emit('info', 'iptv', 'stream', 'stream_off', { avg: round(iptv.avg, 0) }, iptv.low_w);
	iptv.state = 'idle';
	iptv.since = w;
	/* (a dip noticed while it was going off kept the card yellow -
	 * "bitrate much lower than usual" - for as long as it stayed off) */
	iptv.dip = false;
	iptv.low_m = iptv.low_w = null;
	iptv.held = false;
	iptv.hold_def = 0;
}

/* log the start of a stall (ts = moment the data stopped) */
function iptv_flag_stall(kbps) {
	C.emit('err', 'iptv', 'stream', 'stream_stall', { kbps, avg: round(iptv.avg, 0),
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

/*
 * Stream state machine, fed with one bitrate measurement covering the time
 * from iptv.prev_m/prev_w to m/w. Runs every second with the fast sampler
 * (or once per tick when it is off). A stall is logged when the bitrate stays
 * below min_kbps for at least stall_after seconds; its timestamp is the
 * moment the data stopped, not the moment it was noticed.
 */
function iptv_update(kbps, m, w, from_m, from_w) {
	kbps = round(kbps, 0);
	let active = kbps >= C.cfg.iptv.min_kbps;
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
			/* still no channel after the grace time: the decoder was switched
			 * off (a start lost on the way is no reason to wait for ever) */
			if (iptv.low_m == null || !(m - iptv.low_m < C.cfg.iptv.off_after)) {
				iptv_mark_off(w);
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
			C.emit('info', 'iptv', 'stream', 'stream_start', { kbps, ch: chn_now() });
			iptv.state = 'playing';
			iptv.since = w;
			iptv.avg = kbps;
			iptv.dip = false;
			iptv.watch = chn_current();
		}
		break;

	case 'playing':
		if (active) {
			iptv.low_m = iptv.low_w = null;
			/* the channel being watched, for telling "switched off" from a freeze */
			let cur = chn_current();
			if (cur != null || !length(igmp.groups ?? [])) iptv.watch = cur;
			break;
		}
		if (iptv.low_m == null) {
			iptv.low_m = from_m;
			iptv.low_w = from_w;
			/* the freeze probably began inside the previous interval */
			iptv.missing = prev_def;
		}
		iptv.missing += def;
		if (m - iptv.low_m >= C.cfg.iptv.stall_after - 0.05) {
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
			C.emit('warn', 'iptv', 'stream', 'stream_resume', { dur: dur < 1 ? 1 : dur, kbps,
				igmp: igmp_classify(iptv.stall_since), ch: chn_now() });
			iptv.state = 'playing';
			iptv.dip = false;
		}
		else {
			iptv.missing += def;
		}
		if (iptv.state == 'stalled' && m - iptv.stall_m >= C.cfg.iptv.idle_after) {
			C.emit('warn', 'iptv', 'stream', 'stream_lost', { dur: round(m - iptv.stall_m, 0),
				groups: igmp.groups != null ? length(igmp.groups) : null, left: watch_left() || null, ch: chn_now() });
			iptv.state = 'idle';
			iptv.since = w;
			iptv.dip = false;
		}
		break;
	}

	if (iptv.acc && !off && (was_low || iptv.state == 'stalled' || iptv.low_m != null)) {
		if (iptv.held) iptv.hold_def += def;
		else iptv.acc.stall_s += def;
	}
}

function iptv_counters() {
	if (C.cfg.iptv.vlan) return vl.cnt;
	let dev = C.cfg.iptv.device, tx = C.cfg.iptv.direction == 'tx';
	if (!fs.stat(`${SYSNET}/${dev}`)) return null;
	let b = num(rd(dev, `statistics/${tx ? 'tx' : 'rx'}_bytes`), null);
	let p = num(rd(dev, `statistics/${tx ? 'tx' : 'rx'}_packets`), null);
	return (b == null || p == null) ? null : { b, p };
}

/* fast sampler: one counter reading per sample_interval */
function iptv_fast_sample() {
	if (C.cfg.iptv.vlan) vlan_sample();
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
			kbps = ((C.cfg.iptv.direction == 'tx') ? d.tx_bps : d.rx_bps) / 1000;
			pps = (C.cfg.iptv.direction == 'tx') ? d.tx_pps : d.rx_pps;
			ok = devres.present;
		}
		iptv.tick = null;
		if (ok) {
			let m = mono(), w = now();
			iptv.acc = { stall_s: 0, stalls: 0 };
			iptv_update(kbps, m, w, iptv.prev_m ?? m - C.cfg.interval, iptv.prev_w ?? w - C.cfg.interval);
			iptv.tick = { min: round(kbps, 0), stall_s: round(iptv.acc.stall_s, 0), stalls: iptv.acc.stalls };
			iptv.acc = null;
			iptv.prev_m = m;
			iptv.prev_w = w;
		}
	}

	/*
	 * A stop that was never decided: on one router the stream fell to
	 * 50 kbit/s when the decoder was switched off and the state stayed
	 * "playing" for an hour - no freeze, no switch-off logged, and the other
	 * router's freeze at that moment was put down to the cable between them.
	 * Every stop ends in a freeze or a switch-off within off_after + a tick;
	 * past that it is decided here, and the system log says it happened.
	 */
	/* judged on whole ticks below the threshold, not on low_m: a lost
	 * start of the stop is exactly what would leave it undecided */
	if (ok && iptv.state == 'playing' && kbps < C.cfg.iptv.min_kbps) {
		let m = mono(), lim = max(C.cfg.iptv.off_after, C.cfg.iptv.stall_after) + C.cfg.interval * 2 + 5;
		iptv.wd_m ??= m - (iptv.tick ? C.cfg.interval : 0);
		iptv.wd_w ??= now() - (iptv.tick ? C.cfg.interval : 0);
		if (m - iptv.wd_m > lim) {
			warn(`isp-tester: iptv: a stop was not decided after ${round(m - iptv.wd_m, 0)} s (held: ${iptv.held}, start known: ${iptv.low_m != null}), deciding now\n`);
			iptv.low_w ??= iptv.wd_w;
			iptv.low_m ??= iptv.wd_m;
			if (iptv.held) iptv_mark_off(now());
			else iptv_flag_stall(round(kbps, 0));
			iptv.wd_m = iptv.wd_w = null;
		}
	}
	else iptv.wd_m = iptv.wd_w = null;

	kbps = round(kbps ?? 0, 0);
	iptv.kbps = kbps;
	iptv.pps = round(pps ?? 0, 0);

	/* bitrate dip relative to the running average; only on whole ticks
	 * without a stall, so normal VBR jitter and freezes don't count */
	/* not while a stop with nobody subscribed is being decided (held): its
	 * seconds go to hold_def, not stall_s, so the tick in which a decoder was
	 * switched off looked like a whole tick at a third of the usual rate - a
	 * stream_dip at every switch-off, and that tick lowered the average */
	if (ok && iptv.state == 'playing' && !iptv.held && !(iptv.tick?.stall_s > 0) && kbps >= C.cfg.iptv.min_kbps) {
		/* another channel has its own bitrate: from an HD channel (8 Mbit/s)
		 * to an SD one (3) was a "dip", and as the average is held during a
		 * dip, the card stayed yellow for as long as the SD channel played */
		let chans = join(',', igmp.groups ?? []);
		if (iptv.avg_ch != null && chans != iptv.avg_ch) {
			iptv.avg = kbps;
			iptv.dip = false;
		}
		iptv.avg_ch = chans;
		if (C.cfg.iptv.dip_pct > 0 && iptv.avg > 0) {
			let ratio = kbps * 100 / iptv.avg;
			if (!iptv.dip && ratio < C.cfg.iptv.dip_pct) {
				iptv.dip = true;
				iptv.dip_m = mono();
				C.emit('warn', 'iptv', 'stream', 'stream_dip', { kbps, avg: round(iptv.avg, 0), ch: chn_now() });
			}
			else if (iptv.dip && ratio >= C.cfg.iptv.dip_pct + 10) {
				iptv.dip = false;
			}
			/* a lower rate that lasts (without IGMP, or the same group with a
			 * new bitrate): logged once, then it is the usual one */
			else if (iptv.dip && mono() - iptv.dip_m >= 300) {
				iptv.dip = false;
				iptv.avg = kbps;
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

/* the IPTV streams themselves are looked at only for the picture quality, the channel names and the decoders' DHCP */
function tsm_stream() {
	return C.cfg.iptv.quality || C.cfg.iptv.names || (C.cfg.iptv.dhcp && C.cfg.iptv.vlan);
}

/* the operator's queries come in on the port towards the ISP, not on a decoder's port */
function igq_want() {
	return C.cfg.iptv.igmp_query && C.cfg.iptv.igmp && tsq_target()?.dir == 'in';
}

function tsm_want() {
	return iptv_on() && (tsm_stream() || igq_want());
}

function tsm_args(tg) {
	let a = [ '-i', tg.dev, '-d', tg.dir, '-g', `${max(0, C.cfg.iptv.q_gap)}`, '-o', TSQ_STATE ];
	if (tg.vid) push(a, '-v', `${int(tg.vid)}`);
	if (C.cfg.iptv.dhcp && tsm_stream()) push(a, '-D');
	if (igq_want()) push(a, '-Q');
	if (!tsm_stream()) push(a, '-I');
	return join(' ', a);
}

function tsm_stop() {
	let p = tsq.proc;
	tsq.proc = null;
	tsq.args = null;
	tsq.seen = {};
	tsq.drops = null;
	tsq.flow = null;
	igq.on = false;
	igq.pid = null;
	if (p) kill_pids('TERM', [ p.pid() ]);
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
		tsq.next = mono() + wait;
		warn(`isp-tester: ${TSMON} ended (exit ${code}), starting again in ${wait} s\n`);
	});
	if (!p) {
		tsq.err = 'helper_failed';
		tsq.next = mono() + 60;
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
	if (bad >= C.cfg.iptv.q_fail) return 'err';
	if (bad >= C.cfg.iptv.q_warn || (C.cfg.iptv.q_gap > 0 && s.gaps > 0)) return 'warn';
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
		tsq.next = mono() + 10;
		return;
	}
	if (age > 30) tsq.err = 'helper_stalled';
	if (!ours || age > 30) return;
	tsq.err = null;
	if (t - tsq.started > 120) tsq.fails = 0;
	dhcp_ingest(r);
	igmpq_ingest(r.igmp, t, r.pid);

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

	let seen = {}, list = [], fresh = [], named = [];
	/* (an entry "from the future" after the clock was set back is dropped too) */
	tsq.win = filter(tsq.win, (e) => t - e.ts < TSQ_WIN && e.ts <= t);
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

		if (C.cfg.iptv.names) {
			/* learned together below: channels.json is written once, not once per group */
			if (g.svc?.name) push(named, g);
			else if ((g.age ?? 0) >= 15) chn_missing(g.grp, g.psi?.sdt ? 'no_service' : 'no_sdt');
		}
		if (!C.cfg.iptv.quality) continue;

		push(list, g);
		if (ddrop == 0 && (d.cc + d.tei + (C.cfg.iptv.q_gap > 0 ? d.gaps : 0)) > 0) {
			push(tsq.win, { ts: t, grp: g.grp, cc: d.cc, tei: d.tei, lost: d.lost, gaps: d.gaps,
				gap: d.gaps ? (g.gap_last_ms ?? 0) : 0 });
			push(fresh, { g, d });
			tsq.cc_acc = (tsq.cc_acc ?? 0) + d.cc + d.tei;
		}
	}
	tsq.seen = seen;
	if (length(named)) chn_learn(named);
	if (!C.cfg.iptv.quality) return;

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

	/* C.events(): new errors join the group's pending event; it is written when
	 * the cooldown allows it, or at once when the level gets worse */
	for (let x in fresh) {
		let g = x.g, d = x.d, s = sum[g.grp];
		let lvl = tsq_level(s);
		if (lvl == 'ok') continue;
		let p = tsq.pend[g.grp] ??= { cc: 0, lost: 0, tei: 0, gaps: 0, gap: 0, since: t - C.cfg.interval, lvl: 'ok' };
		p.cc += d.cc;
		p.tei += d.tei;
		p.lost += d.lost;
		p.gaps += d.gaps;
		if (s.gap > p.gap) p.gap = s.gap;
		p.lvl = worst(p.lvl, lvl);
		p.kbps = g.kbps;
	}
	for (let grp, p in tsq.pend) {
		let le = tsq.last_ev[grp] ?? 0;
		if (t - le < C.cfg.err_cooldown && t >= le && LEVEL[p.lvl] <= LEVEL[tsq.last_lvl[grp] ?? 'ok'])
			continue;
		/* the event's own level comes from what it reports (the minute's
		 * level only decides when it is written) */
		C.emit(worst('warn', tsq_level(p)), 'iptv', 'quality', 'ts_errors', { grp, ch: chn_name(grp), cc: p.cc, lost: p.lost, tei: p.tei,
			gap: p.gap, win: round(t - p.since, 0), kbps: p.kbps }, t);
		tsq.last_ev[grp] = t;
		tsq.last_lvl[grp] = p.lvl;
		delete tsq.pend[grp];
	}
	/* a level reached long ago does not hold back the next event */
	for (let grp in keys(tsq.last_lvl))
		if (t - tsq.last_ev[grp] >= C.cfg.err_cooldown || t < tsq.last_ev[grp]) { delete tsq.last_lvl[grp]; delete tsq.last_ev[grp]; }
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
		/* monotonic: a clock set back must not hold the restart for an hour */
		if (mono() >= tsq.next) tsm_start(tg);
		chn.err = (tsq.err == 'helper_failed') ? tsq.err : null;
		return;
	}
	tsm_read();
	igmpq_check(now());
	chn.err = tsq.err;
}

/* the clock was stepped while not trusted (see clock.uc clk_fix): the wall
 * times noted since the start move with it, so durations stay right */
function iptv_shift(by) {
	let mv = (o, ks) => { for (let k in ks) if (type(o[k]) == 'int' || type(o[k]) == 'double') o[k] += by; };
	mv(iptv, [ 'since', 'stall_since', 'low_w', 'prev_w', 'wd_w' ]);
	mv(igmp, [ 'proxy_since', 'last_change' ]);
	mv(tsq, [ 'started', 'drop_ts' ]);
	for (let g, t in igmp.joined) if (t > 0) igmp.joined[g] = t + by;
	for (let h in igmp.hist) h.ts += by;
	for (let mac, d in dec.list) mv(d, [ 'since', 'gone_at', 'seen', 'last_active', 'quiet_from', 'on_t' ]);
	mv(dec, [ 't0' ]);
	/* the operator's queries: a step forward would look like a long silence
	 * (a false igmp_noquery), the decoders' leases like expired ones */
	mv(igq, [ 'last_ts', 'since', 'silent_ref' ]);
	for (let mac, s in dhl.mac) mv(s, [ 'offer_t', 'last_ack', 'boot_t' ]);
	for (let e in tsq.win) e.ts += by;
	for (let g, t in tsq.last_ev) tsq.last_ev[g] = t + by;
	for (let g, p in tsq.pend) mv(p, [ 'since' ]);
	if (tsq.flow) mv(tsq.flow, [ 'ts' ]);
}

export { iptv_init, iptv_shift, iptv, vl, igmp, igq, tsq, chn, dhl, dec, IGQ_RING, TSQ_STATE, TSQ_WIN, TSQ_DROP_SHOW, CHN_MAX, igmp_groups, igmp_poll, igmp_classify, proxy_process, sample_proxy, dhcp_src, dhcp_seen, dhcp_ingest, dhcp_log_line, dhcp_tick, vlan_sample, dec_fdb, dec_stream_hit, dec_poll, tsq_out, iptv_on, iptv_fast, tsq_target, chn_load, chn_save, chn_name, chn_now, chn_current, chn_learn, chn_missing, chn_out, handle_chn_forget, igmpq_ingest, igmpq_expected, igmpq_limit, igmpq_check, igmpq_out, iptv_out, nobody_subscribed, iptv_flag_stall, iptv_update, iptv_counters, iptv_fast_sample, sample_iptv, tsm_stream, igq_want, tsm_want, tsm_args, tsm_stop, tsm_start, tsq_level, tsm_read, tsm_poll };
