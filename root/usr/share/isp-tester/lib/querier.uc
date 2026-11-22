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
 * Managed (option querier.enabled): the collector keeps the VLAN's IGMP
 * snooping and querier on, the port towards the ISP a permanent multicast
 * router port (the decoders' reports go to the operator) and, optionally,
 * snooping off in the bridge's other VLANs - what was a hotplug script
 * (99-iptv-querier) before. Checked once a minute and right away when the
 * kernel shows something else (netifd recreated the bridge): only what
 * differs is not worked out, all settings are sent again; the kernel takes a
 * setting that does not change as a no-op. With block_isp the ISP's general
 * queries (to 224.0.0.1) arriving on the upstream port are dropped before
 * the bridge sees them (nft, bridge family, prerouting): the router stays
 * the only querier and asks every 125 s. The reports still go to the ISP.
 * isp-tester-tsmon keeps seeing the dropped queries (its packet socket sees
 * the frame before the bridge does), so "ISP IGMP queries" stays measured.
 * The rule matches by offsets from the Ethernet header: with the VLAN tag
 * taken off by the network card or kept in the frame alike (nft puts an
 * offloaded tag back into the link-layer view), where the network and
 * transport header offsets would point at the tag.
 */

import * as fs from 'fs';
import { VARDIR, SYSNET, BRIDGE, IPCMD, NFT, now, mono, num, valid_dev, round } from './common.uc';
import { rd, bridge_json } from './sysinfo.uc';

let C = null;

const TABLE = 'isp_tester';
const RULE_TAG = 'isp-tester-q';
/* checks of the settings / the filter, s */
const ENSURE_EVERY = 60;
const ENSURE_MIN = 10;
/* "no querier at all" only after it lasted this long (the router's own
 * querier starts a few seconds after the bridge comes up) */
const NONE_AFTER = 20;

let q = {
	who: null, addr: null, port: null, since: null,      /* elected querier (isp / other / router / none) */
	none_from: null, none_open: false, none_since: null, /* "no querier" pending / logged */
	conf: null,                                          /* the VLAN's own settings, as the kernel has them */
	vsnoop: null, vsnoop_m: null,                        /* per-VLAN snooping of the bridge (ip link), null = unknown */
	br: null, vlan: null, up: null,
	ensure_m: null, ensure_err: null, ensured: null,     /* managed: last check, its error, when settings were (re)sent */
	nft_m: null, nft_err: null, nft_ok: false, nft_since: null, drops: null, drop_ts: null,
	ifn: {}                                              /* ifindex -> name */
};

function querier_init(ctx) { C = ctx; }

function run(cmd) {
	let f = fs.popen(`${cmd} 2>&1`, 'r');
	if (!f) return { out: '', code: -1 };
	let out = f.read('all') ?? '';
	let code = f.close();
	return { out: trim(out), code };
}

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

/* ------------------------------------------------------------ managed */

function nft_rules(up, vid, untagged) {
	/* @ll offsets from the Ethernet header: with a tag, IP starts at 18
	 * (protocol +9 = 27, destination +16 = 34), without one at 14 */
	let r = `\t\tiifname "${up}" ether type 8021q vlan id ${vid} @ll,216,8 2 @ll,272,32 0xe0000001 counter drop comment "${RULE_TAG} ${up}/${vid}"\n`;
	if (untagged)
		r += `\t\tiifname "${up}" ether type ip @ll,184,8 2 @ll,240,32 0xe0000001 counter drop comment "${RULE_TAG} ${up}/${vid}/untagged"\n`;
	return `table bridge ${TABLE}\ndelete table bridge ${TABLE}\ntable bridge ${TABLE} {\n` +
		`\tchain isp_queries {\n\t\ttype filter hook prerouting priority -300; policy accept;\n${r}\t}\n}\n`;
}

/* is vid the untagged (PVID) VLAN of port up? Then the ISP's frames have no tag */
function pvid_of(up, vid) {
	let j = bridge_json(`vlan show dev ${up}`);
	for (let e in (j ?? []))
		for (let v in (e?.vlans ?? []))
			if (int(v.vlan) == vid && index(v.flags ?? [], 'PVID') >= 0) return true;
	return false;
}

/* the filter's state: { sig, packets } of the rules found, null = no table */
function nft_read() {
	let j = json_of(`${NFT} -j list table bridge ${TABLE}`);
	if (type(j?.nftables) != 'array') return null;
	let sig = [], pk = 0;
	for (let o in j.nftables) {
		let r = o?.rule;
		if (type(r) != 'object' || substr(r.comment ?? '', 0, length(RULE_TAG)) != RULE_TAG) continue;
		push(sig, substr(r.comment, length(RULE_TAG) + 1));
		for (let x in (r.expr ?? []))
			if (x?.counter) pk += int(x.counter.packets ?? 0);
	}
	return { sig: join(',', sort(sig)), packets: pk };
}

function nft_remove() {
	if (!NFT) return;
	if (nft_read() != null) run(`${NFT} delete table bridge ${TABLE}`);
	q.nft_ok = false;
	q.nft_since = null;
	q.drops = null;
}

function nft_ensure(t, m) {
	if (!NFT) { q.nft_err = 'no_nft'; q.nft_ok = false; return; }
	let untagged = pvid_of(q.up, q.vlan);
	let want = join(',', sort(untagged ? [ `${q.up}/${q.vlan}`, `${q.up}/${q.vlan}/untagged` ] : [ `${q.up}/${q.vlan}` ]));
	let cur = nft_read();
	if (cur == null || cur.sig != want) {
		let path = `${VARDIR}/querier.nft`;
		fs.writefile(path, nft_rules(q.up, q.vlan, untagged));
		let r = run(`${NFT} -f ${path}`);
		if (r.code != 0) {
			/* "No such file or directory" on the bridge family = kmod-nft-bridge missing */
			q.nft_since = null;
		q.nft_err = match(r.out, /No such file|not supported|Operation not supported/i) ? 'no_bridge_family' : (substr(split(r.out, '\n')[0] ?? '', 0, 120) || 'failed');
			q.nft_ok = false;
			return;
		}
		cur = nft_read();
		q.drops = null;
	}
	q.nft_err = null;
	q.nft_ok = (cur != null);
	if (!q.nft_ok) q.nft_since = null;
	else q.nft_since ??= t;
	if (cur) {
		if (q.drops != null && cur.packets > q.drops) q.drop_ts = t;
		q.drops = cur.packets;
	}
}

/* send all settings of the VLAN's querier again (no-ops where nothing changes) */
function settings_ensure(gl) {
	let Q = C.cfg.querier, br = q.br, vid = q.vlan;
	let cmds = [
		`${IPCMD} link set dev ${br} type bridge mcast_snooping 1 mcast_vlan_snooping 1`,
		`${BRIDGE} vlan global set vid ${vid} dev ${br} mcast_snooping 1 mcast_querier 1 mcast_igmp_version ${Q.igmp_version}`,
		`${BRIDGE} vlan set vid ${vid} dev ${q.up} mcast_router 2`
	];
	if (Q.others_off)
		for (let v in (gl?.all ?? [])) {
			if (v.snooping === 0) continue;
			/* the IPTV VLAN cut out of a range */
			let parts = [];
			if (vid >= v.lo && vid <= v.hi) {
				if (v.lo < vid) push(parts, [ v.lo, vid - 1 ]);
				if (vid < v.hi) push(parts, [ vid + 1, v.hi ]);
			}
			else push(parts, [ v.lo, v.hi ]);
			for (let p in parts)
				push(cmds, `${BRIDGE} vlan global set vid ${p[0] == p[1] ? p[0] : p[0] + '-' + p[1]} dev ${br} mcast_snooping 0`);
		}
	let err = null;
	for (let c in cmds) {
		let r = run(c);
		if (r.code != 0 && !err) err = substr(split(r.out, '\n')[0] ?? '', 0, 120) || 'failed';
	}
	q.ensure_err = err;
	q.ensured = now();
	q.vsnoop_m = null;   /* asked again on the next tick */
}

/* what the kernel shows differs from what is wanted: right away, not in a minute */
function drifted(conf, gl) {
	let Q = C.cfg.querier;
	if (q.vsnoop === false || !conf?.per_vlan) return true;
	if (conf.snooping !== 1 || conf.querier !== 1 || (conf.version != null && conf.version != Q.igmp_version)) return true;
	if (index(conf.routers ?? [], q.up) < 0) return true;
	/* another VLAN (or the rest of a range with the IPTV VLAN in it) still snooped */
	if (Q.others_off)
		for (let v in (gl?.all ?? []))
			if (v.snooping === 1 && !(v.lo == q.vlan && v.hi == q.vlan)) return true;
	return false;
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
	let blocked = Q.block_isp && q.nft_ok;
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

	/* ---- managed */
	if (Q.enabled && vid && q.up && valid_dev(q.up) && IPCMD) {
		let due = q.ensure_m == null || m - q.ensure_m >= ENSURE_EVERY ||
			(m - q.ensure_m >= ENSURE_MIN && (q.conf == null || drifted(q.conf, gl)));
		if (due) {
			q.ensure_m = m;
			settings_ensure(gl);
		}
		if (Q.block_isp && (q.nft_m == null || m - q.nft_m >= ENSURE_EVERY || due)) {
			q.nft_m = m;
			nft_ensure(t, m);
		}
	}
	else if (Q.enabled) {
		q.ensure_err = !vid ? 'no_vlan' : !IPCMD ? 'no_ip' : 'no_upstream';
	}
	/* filter off (or not managed): a table left from before is removed, once */
	if (!Q.block_isp && q.nft_m == null) {
		q.nft_m = m;
		nft_remove();
	}
}

/* the filter is in place, yet the ISP is (still) the elected querier. Right
 * after the filter was set the bridge keeps the ISP for its "other querier
 * present" interval (255 s): only after that it means the rule misses them */
function filter_failing(t) {
	return C.cfg.querier.block_isp && q.nft_ok && (q.who == 'isp' || q.who == 'other') &&
		t - (q.nft_since ?? t) > (q.conf?.querier_after ?? 255) + 30;
}

function querier_out() {
	if (!q.br) return null;
	let Q = C.cfg.querier, t = now();
	let o = { bridge: q.br, vlan: q.vlan || null, upstream: q.up, per_vlan: q.conf?.per_vlan ?? null,
		who: q.who, addr: q.addr, port: q.port, since: q.since, conf: q.conf };
	if (Q.enabled)
		o.managed = { block: Q.block_isp, version: Q.igmp_version, others_off: Q.others_off,
			err: q.ensure_err, ensured: q.ensured,
			nft: Q.block_isp ? { ok: q.nft_ok, err: q.nft_err, drops: q.drops, last: q.drop_ts } : null };
	let reasons = [];
	if (Q.enabled && q.ensure_err) push(reasons, { c: 'querier_err', err: q.ensure_err });
	if (Q.block_isp && q.nft_err) push(reasons, { c: 'querier_nft_err', err: q.nft_err });
	if (filter_failing(t)) push(reasons, { c: 'querier_block_fail', addr: q.addr, port: q.port });
	if (q.none_open) push(reasons, { c: 'querier_none', since: q.none_since, vlan: q.vlan });
	o.reasons = reasons;
	return o;
}

/* the clock was stepped (clock.uc): times noted by this run move with it */
function querier_shift(by) {
	for (let k in [ 'since', 'none_from', 'none_since', 'ensured', 'drop_ts', 'nft_since' ])
		if (q[k] != null) q[k] += by;
}

export { querier_init, querier_tick, querier_out, querier_shift };
