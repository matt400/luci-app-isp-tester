'use strict';

/*
 * luci-app-isp-tester: the IGMP querier of the bridged IPTV VLAN (see
 * ../collector.uc); init(ctx) gives it cfg, emit and the IPTV module's
 * bridge / upstream port (vl).
 *
 * Who asks? The decoders keep their channels only while somebody sends IGMP
 * general queries on the VLAN: the operator, or this router's bridge. Of
 * several queriers the bridge elects one (the lowest address; its own
 * queries go out from 0.0.0.0, so the operator always wins) and stays
 * silent while the elected one keeps asking. When the operator stops, the
 * bridge waits its "other querier present" interval (255 s by default)
 * before it asks itself - and the operator may have let the memberships
 * expire meanwhile: the stream stops for up to a minute although every
 * decoder still watches. The elected querier is read from the kernel
 * (bridge vlan global show: mcast_querier_state_ipv4) every tick; every
 * change is a timeline event, so a freeze can be matched to a hand-over.
 *
 * Set up by the system, not here: Settings -> IPTV -> IGMP querier writes a
 * hotplug script (querier-gen.uc, run by the init script), which stays when
 * the package is removed. This module only compares the bridge with the
 * chosen mode: the VLAN's snooping and querier on and the port towards the
 * ISP a multicast router port (backup / router), the nft filter of the ISP's
 * queries in place (router) - and how many it dropped. When the ISP is still
 * the elected querier well after the filter was seen (more than the 255 s
 * the bridge keeps a querier it heard), the rule does not catch its queries.
 * isp-tester-tsmon keeps seeing the dropped queries (its packet socket sees
 * the frame before the bridge does), so "ISP IGMP queries" stays measured.
 */

import * as fs from 'fs';
import { VARDIR, SYSNET, BRIDGE, IPCMD, NFT, now, mono, num, valid_dev, round } from './common.uc';
import { rd, bridge_json } from './sysinfo.uc';

let C = null;

const TABLE = 'isp_tester';
const RULE_TAG = 'isp-tester-q';
/* the router's own queries kept from the ISP (querier-gen.uc) */
const OUT_TAG = 'isp-tester-o';
/* "no querier at all" only after it lasted this long (the router's own
 * querier starts a few seconds after the bridge comes up) */
const NONE_AFTER = 20;

let q = {
	who: null, addr: null, port: null, since: null,      /* elected querier (isp / other / router / none) */
	none_from: null, none_open: false, none_since: null, /* "no querier" pending / logged */
	conf: null,                                          /* the VLAN's own settings, as the kernel has them */
	vsnoop: null, vsnoop_m: null,                        /* per-VLAN snooping of the bridge (ip link), null = unknown */
	br: null, vlan: null, up: null,
	script: null, script_m: null, diff: null,            /* the hotplug script's outcome, what differs from the mode */
	nft_m: null, nft_ok: false, nft_since: null, drops: null, drop_ts: null,
	ifn: {}                                              /* ifindex -> name */
};

function querier_init(ctx) { C = ctx; }

function json_of(cmd) {
	let f = fs.popen(`${cmd} 2>/dev/null`, 'r');
	if (!f) return null;
	let out = f.read('all');
	f.close();
	try { return json(out || 'null'); } catch (e) { return null; }
}

function ifname(idx) {
	idx = int(idx);
	if (!(idx > 0)) return null;
	if (q.ifn[idx] && rd(q.ifn[idx], 'ifindex') == `${idx}`) return q.ifn[idx];
	for (let n in (fs.lsdir(SYSNET) ?? []))
		if (rd(n, 'ifindex') == `${idx}`) { q.ifn[idx] = n; return n; }
	return `#${idx}`;
}

/* kernel timers come as centiseconds (clock_t) */
function cs(v) { v = num(v, null); return (v == null) ? null : round(v / 100.0, 0); }

/* per-VLAN multicast snooping of the bridge: an option of the bridge itself
 * (ip link), asked once a minute. null = cannot tell (an ip without JSON) */
function read_vsnoop(br) {
	if (!IPCMD) return null;
	let j = json_of(`${IPCMD} -d -j link show dev ${br}`);
	let d = (type(j) == 'array') ? j[0]?.linkinfo?.info_data : null;
	if (type(d) != 'object') return null;
	if (d.mcast_vlan_snooping == null) return (d.mcast_snooping != null) ? false : null;
	return !!d.mcast_vlan_snooping;
}

/* the VLAN's entry of `bridge -d vlan global show` (ranges: vlan..vlanEnd) */
function vlan_global(br, vid) {
	let j = bridge_json(`-d vlan global show dev ${br}`);
	if (j == null) return null;
	let mine = null, all = [];
	for (let e in j) {
		if (e?.ifname != br) continue;
		for (let v in (e.vlans ?? [])) {
			let lo = int(v.vlan), hi = int(v.vlanEnd ?? v.vlan);
			push(all, { lo, hi, snooping: v.mcast_snooping });
			if (vid >= lo && vid <= hi) mine = v;
		}
	}
	return { mine, all };
}

/* elected querier out of a kernel querier state (mcast_querier_state_ipv4):
 * the port and the "other querier present" timer are there only while
 * another querier is elected; the address alone = this bridge's own */
function elected(st, own_on, up) {
	let s = (type(st) == 'object') ? st : {};
	let addr = s.mcast_querier_ipv4_addr ?? null;
	if (s.mcast_querier_ipv4_other_timer != null || s.mcast_querier_ipv4_port != null) {
		let port = ifname(s.mcast_querier_ipv4_port);
		return { who: (!up || !port || port == up) ? 'isp' : 'other', addr, port };
	}
	if (own_on) return { who: 'router', addr, port: null };
	return { who: 'none', addr: null, port: null };
}

/* without per-VLAN snooping the bridge has one querier for all VLANs */
function bridge_wide(br) {
	if (!IPCMD) return null;
	let j = json_of(`${IPCMD} -d -j link show dev ${br}`);
	let d = (type(j) == 'array') ? j[0]?.linkinfo?.info_data : null;
	if (type(d) != 'object') return null;
	return {
		conf: { snooping: d.mcast_snooping, querier: d.mcast_querier, version: d.mcast_igmp_version,
			membership: cs(d.mcast_membership_intvl), query: cs(d.mcast_query_intvl), querier_after: cs(d.mcast_querier_intvl) },
		st: d.mcast_querier_state_ipv4
	};
}

/* ---------------------------------------------------- the chosen mode */

const SCRIPT_STATUS = `${VARDIR}/querier-script.json`;

/* the filter's state: packets dropped by its rules (the ISP's queries
 * coming in, the router's own going out), null = no table */
function nft_read() {
	if (!NFT) return null;
	let j = json_of(`${NFT} -j list table bridge ${TABLE}`);
	if (type(j?.nftables) != 'array') return null;
	let n = 0, pk = 0, out = null;
	for (let o in j.nftables) {
		let r = o?.rule, c = r?.comment ?? '';
		if (type(r) != 'object') continue;
		let isin = substr(c, 0, length(RULE_TAG)) == RULE_TAG, isout = substr(c, 0, length(OUT_TAG)) == OUT_TAG;
		if (!isin && !isout) continue;
		let p = 0;
		for (let x in (r.expr ?? []))
			if (x?.counter) p += int(x.counter.packets ?? 0);
		if (isin) { n++; pk += p; }
		else out = (out ?? 0) + p;
	}
	return { rules: n, packets: pk, out };
}

function nft_check(t) {
	let cur = nft_read();
	q.nft_ok = cur != null && cur.rules > 0;
	if (!q.nft_ok) { q.nft_since = null; q.drops = null; q.out = null; return; }
	q.nft_since ??= t;
	/* the counter starts again when the table is set again (the script with "apply") */
	if (q.drops != null && cur.packets > q.drops) q.drop_ts = t;
	q.drops = cur.packets;
	q.out = cur.out;
}

/* what the bridge shows differs from the chosen mode: [ what, ... ] */
function mismatch(mode, conf) {
	let out = [];
	if (mode != 'backup' && mode != 'router') return out;
	if (!conf) return [ 'unreadable' ];
	if (conf.per_vlan === false) push(out, 'vlan_snooping');
	if (conf.snooping !== 1) push(out, 'snooping');
	if (conf.querier !== 1) push(out, 'querier');
	if (conf.version != null && conf.version != C.cfg.querier.igmp_version) push(out, 'version');
	if (q.up && conf.routers != null && index(conf.routers, q.up) < 0) push(out, 'router_port');
	if (mode == 'router' && !q.nft_ok) push(out, 'filter');
	return out;
}

/* ------------------------------------------------------------- events */

function take(t, el) { q.who = el.who; q.addr = el.addr; q.port = el.port; q.since = t; }

function note(t, el) {
	let Q = C.cfg.querier;
	if (q.who == null) {
		/* the first reading: what it is, no event */
		take(t, el);
		q.none_from = (el.who == 'none') ? t : null;
		return;
	}

	/* no querier at all: logged only when it lasts (the previous one stays shown meanwhile) */
	if (el.who == 'none') {
		q.none_from ??= t;
		if (!q.none_open && t - q.none_from >= NONE_AFTER) {
			q.none_open = true;
			q.none_since = q.none_from;
			C.emit('warn', 'iptv', 'igmp', 'igmp_no_querier', { vlan: q.vlan, bridge: q.br, prev: q.who, prev_addr: q.addr }, q.none_from);
			take(q.none_from, el);
		}
		return;
	}
	q.none_from = null;
	if (q.none_open) {
		q.none_open = false;
		C.emit('info', 'iptv', 'igmp', 'igmp_no_querier_ok', { dur: t - q.none_since, to: el.who, addr: el.addr, port: el.port, vlan: q.vlan }, t);
		take(t, el);
		return;
	}

	if (el.who == q.who && (el.who == 'router' || el.addr == q.addr)) {
		if (el.addr) q.addr = el.addr;
		return;
	}
	/* from a state that was never logged (none at the start, snooping off): quietly */
	if (q.who == 'none' || q.who == 'off') { take(t, el); return; }

	/* the ISP elected again while its queries should be dropped: the filter does not catch them */
	let blocked = q.nft_ok;
	let lvl = (blocked && (el.who == 'isp' || el.who == 'other') && t - (q.nft_since ?? t) > (q.conf?.querier_after ?? 255) + 30) ? 'warn' : 'info';
	C.emit(lvl, 'iptv', 'igmp', 'igmp_querier', { from: q.who, to: el.who, addr: el.addr, port: el.port,
		prev_addr: q.addr, prev_port: q.port, after: q.conf?.querier_after, held: t - (q.since ?? t), vlan: q.vlan,
		blocked: blocked ? 1 : 0 }, t);
	take(t, el);
}

/* ---------------------------------------------------------------- tick */

/* once per main tick, after the IPTV sample (vl knows the bridge and the port) */
function querier_tick(vl) {
	let t = now(), m = mono(), Q = C.cfg.querier;
	let br = C.cfg.iptv.bridge || vl?.bridge || null;
	let vid = C.cfg.iptv.vlan || 0;
	q.up = (vid && vl?.upstream) ? vl.upstream : null;
	if (!C.cfg.iptv.enabled || !br || !valid_dev(br) || !BRIDGE) { q.br = null; return; }
	if (q.br != br || q.vlan != vid) {
		/* other bridge / VLAN (first tick): start over */
		q.who = null; q.none_open = false; q.none_from = null; q.vsnoop_m = null;
	}
	q.br = br; q.vlan = vid;

	if (q.vsnoop_m == null || m - q.vsnoop_m >= 60) {
		q.vsnoop = read_vsnoop(br);
		q.vsnoop_m = m;
	}

	let el = null, gl = null;
	if (vid && q.vsnoop !== false) {
		gl = vlan_global(br, vid);
		let v = gl?.mine;
		if (v) {
			q.conf = { snooping: v.mcast_snooping, querier: v.mcast_querier, version: v.mcast_igmp_version,
				membership: cs(v.mcast_membership_interval), query: cs(v.mcast_query_interval),
				querier_after: cs(v.mcast_querier_interval), routers: map(v.router_ports ?? [], (p) => p?.port),
				per_vlan: true };
			el = elected(v.mcast_querier_state_ipv4, v.mcast_snooping === 1 && v.mcast_querier === 1, q.up);
		}
		else q.conf = null;
	}
	else {
		let b = bridge_wide(br);
		if (b) {
			q.conf = { ...b.conf, per_vlan: false };
			el = elected(b.st, b.conf.snooping === 1 && b.conf.querier === 1, q.up);
		}
		else q.conf = null;
	}
	if (el && q.conf?.snooping === 1) note(t, el);
	else {
		/* snooping off: nobody needs a querier; unreadable: start over when it can be read */
		q.who = (q.conf?.snooping === 0) ? 'off' : null;
		q.none_from = null;
		if (q.none_open && q.who == 'off') {
			/* snooping switched off: with flooding no querier is needed any more */
			q.none_open = false;
			C.emit('info', 'iptv', 'igmp', 'igmp_no_querier_ok', { dur: t - q.none_since, to: 'off', vlan: q.vlan }, t);
		}
	}

	/* ---- the chosen mode: the script's outcome (querier-gen.uc) and the filter */
	if (q.script_m == null || m - q.script_m >= 60) {
		q.script_m = m;
		try { q.script = json(fs.readfile(SCRIPT_STATUS) || 'null'); } catch (e) { q.script = null; }
	}
	if (q.nft_m == null || m - q.nft_m >= 60) {
		q.nft_m = m;
		nft_check(t);
	}
	q.diff = mismatch(Q.mode, q.conf);
}

/* the filter is in place, yet the ISP is (still) the elected querier. Right
 * after the filter was set the bridge keeps the ISP for its "other querier
 * present" interval (255 s): only after that it means the rule misses them */
function filter_failing(t) {
	return q.nft_ok && (q.who == 'isp' || q.who == 'other') &&
		t - (q.nft_since ?? t) > (q.conf?.querier_after ?? 255) + 30;
}

function querier_out() {
	if (!q.br) return null;
	let Q = C.cfg.querier, t = now();
	let o = { bridge: q.br, vlan: q.vlan || null, upstream: q.up, per_vlan: q.conf?.per_vlan ?? null,
		who: q.who, addr: q.addr, port: q.port, since: q.since, conf: q.conf };
	o.mode = Q.mode;
	o.version = Q.igmp_version;
	o.script = q.script;
	o.diff = q.diff;
	if (q.nft_ok || Q.mode == 'router') o.nft = { ok: q.nft_ok, drops: q.drops, last: q.drop_ts, out: q.out };
	let reasons = [];
	if (q.script?.err && Q.mode != 'unmanaged') push(reasons, { c: 'querier_script_err', err: q.script.err });
	if (length(q.diff ?? [])) push(reasons, { c: 'querier_diff', what: q.diff, mode: Q.mode });
	if (filter_failing(t)) push(reasons, { c: 'querier_block_fail', addr: q.addr, port: q.port });
	if (q.none_open) push(reasons, { c: 'querier_none', since: q.none_since, vlan: q.vlan });
	o.reasons = reasons;
	return o;
}

/* the clock was stepped (clock.uc): times noted by this run move with it */
function querier_shift(by) {
	for (let k in [ 'since', 'none_from', 'none_since', 'drop_ts', 'nft_since' ])
		if (q[k] != null) q[k] += by;
}

export { querier_init, querier_tick, querier_out, querier_shift };
