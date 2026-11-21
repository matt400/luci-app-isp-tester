'use strict';

/* luci-app-isp-tester: second router (see ../collector.uc); init(ctx) gives it
 * cfg, hostname, started(), maint_on(), maint_until(), store_event, save_events, emit */

import * as uloop from 'uloop';
import * as fs from 'fs';
import { VARDIR, LEVEL, now, write_atomic, worst } from './common.uc';

let C = null;

function peer_init(ctx) { C = ctx; }

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
 *                        lo: lowest sequence number still kept,
 *                        ev: [ { q: sequence number, e: event } ], hb: status }
 *   receiver -> sender { v, ack: highest sequence number stored, ep, to, now }
 * Unacknowledged events are sent again every interval, so a short outage of
 * the receiver (or of the cable between the routers) loses nothing; the
 * receiver drops what it has already stored (q <= last) and takes the events
 * only in order (q = last + 1): when the first of several datagrams of one
 * send is lost and a later one arrives, its events wait for the resend
 * instead of moving `last` past the lost ones (the ack would then tell the
 * sender to forget them). Events the sender itself had to drop (full outbox)
 * are skipped by `lo`. Every interval the
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
	if (C.cfg.peer.role != 'send' || C.cfg.peer.err || e.host) return;
	push(peer.out, { q: ++peer.seq, e });
	if (length(peer.out) > PEER_OUTBOX) {
		peer.dropped += length(peer.out) - PEER_OUTBOX;
		peer.out = slice(peer.out, length(peer.out) - PEER_OUTBOX);
	}
	if (peer_flush_fn && !peer.kick)
		peer.kick = uloop.timer(300, () => { peer.kick = null; peer_flush_fn(null); });
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
	if (!peer.sk || C.cfg.peer.role != 'send') return;
	let dst = { address: C.cfg.peer.host, port: C.cfg.peer.port };
	let base = { v: PEER_VER, h: C.hostname, ep: peer.ep, now: now(), iv: C.cfg.interval,
		lo: length(peer.out) ? peer.out[0].q : peer.seq + 1 };
	let i = 0, pkts = 0;
	while (pkts < 8) {
		let o = { ...base, ev: [] };
		if (hb && pkts == 0) o.hb = hb;
		/* the size is added up per event (its JSON plus ", ") instead of
		 * printing the whole packet again after each one */
		let size = length(sprintf('%J', o));
		while (i < length(peer.out)) {
			let x = peer_fit(peer.out[i]), xl = length(sprintf('%J', x)) + 2;
			if (length(o.ev) && size + xl > PEER_MAXPKT) break;
			push(o.ev, x);
			size += xl;
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
	if (o.ep != peer.ep || o.to != C.hostname) return;
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

/* written on a change of what a restart needs (epoch, last stored event,
 * online), else at most every 20 s for "seen" - not on every datagram, of
 * which there are several per tick */
let peer_saved = { key: null, ts: 0 };

function peer_save(force) {
	let o = {};
	for (let n, p in peer.peers) o[n] = { ep: p.ep, last: p.last, seen: p.seen, lost_at: p.lost_at, online: p.online };
	let key = join(',', map(sort(keys(o)), (n) => `${n}:${o[n].ep}:${o[n].last}:${o[n].online}`)), t = now();
	if (!force && key == peer_saved.key && t - peer_saved.ts < 20 && t >= peer_saved.ts) return;
	peer_saved = { key, ts: t };
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
	if (!match(name, /^[A-Za-z0-9._-]{1,32}$/) || name == C.hostname) return;
	let t = now();
	let p = peer.peers[name] ??= { name, ep: 0, last: 0, seen: 0, online: false, hb: null };
	let ep = int(+o.ep || 0);
	/* An older run of the sender (replayed) - unless the sender is offline: its
	 * epoch is the start time of its collector, and a router without a clock
	 * that reboots starts from an older time than its previous run. */
	if (ep < p.ep && p.online) return;
	if (ep != p.ep) { p.ep = ep; p.last = 0; }

	let off = (type(o.now) == 'int') ? t - o.now : 0;
	if (off >= -5 && off <= 5) off = 0;
	if (!p.online && p.lost_at)
		C.emit('info', 'system', name, 'peer_back', { dur: t - p.lost_at, addr: addr?.address });
	p.online = true;
	p.lost_at = null;
	p.seen = t;
	p.off = off;
	p.iv = (type(o.iv) == 'int' && o.iv > 0) ? o.iv : 10;
	p.addr = addr?.address;
	if (o.hb) p.hb = peer_hb_clean(o.hb);

	let added = 0;
	/* what the sender no longer has (dropped from a full outbox) is not waited for */
	let lo = (type(o.lo) == 'int') ? o.lo : null;
	if (lo != null && lo > p.last + 1) p.last = lo - 1;
	for (let x in (type(o.ev) == 'array' ? o.ev : [])) {
		let q = int(+x?.q || 0);
		if (q <= p.last) continue;
		/* a gap: an earlier datagram was lost, wait for the resend (a sender
		 * without `lo` - older version - is taken as before) */
		if (lo != null && q != p.last + 1) break;
		let e = peer_event(x.e, name, off);
		p.last = q;
		if (!e) continue;
		C.store_event(e);
		added++;
	}
	if (added) C.save_events();

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
		if (C.cfg.peer.role == 'send') { if (o.ack != null) peer_acked(o); }
		else if (o.ack == null) peer_ingest(o, addr);
	}
}

/* open the socket (after uloop.init) */
function peer_start() {
	if (C.cfg.peer.role == 'off' || C.cfg.peer.err) return;
	if (!hmac_init(C.cfg.peer.key)) { C.cfg.peer.err = 'no_digest'; return; }
	let socket;
	try { socket = require('socket'); } catch (e) { C.cfg.peer.err = 'no_socket_module'; return; }
	let sk = socket.create(socket.AF_INET, socket.SOCK_DGRAM);
	if (!sk) { C.cfg.peer.err = 'socket'; return; }
	if (C.cfg.peer.role == 'receive') {
		try { sk.setopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); } catch (e) {}
		if (!sk.bind({ family: socket.AF_INET, address: '0.0.0.0', port: C.cfg.peer.port })) {
			sk.close();
			C.cfg.peer.err = 'bind';
			return;
		}
		peer_load();
	}
	peer.sk = sk;
	peer.socket = socket;
	peer.ep = C.started();
	peer.h = uloop.handle(sk, () => {
		try { peer_recv(); }
		catch (e) { warn(`isp-tester: peer receive failed: ${e}\n`); }
	}, uloop.ULOOP_READ);
	peer_flush_fn = peer_flush;
}

/* sender: short status of this router for the receiver's view */
function peer_hb(overall, iptv_res, ports) {
	let hb = { lvl: overall, up: C.started() };
	if (C.maint_on()) hb.maint = C.maint_until();
	if (iptv_res) hb.iptv = { state: iptv_res.state, kbps: iptv_res.kbps, lvl: iptv_res.level,
		dec: map(slice(iptv_res.decoders ?? [], 0, 4), (x) => ({ label: x.label || x.mac, port: x.port, up: x.present })) };
	hb.ports = map(slice(ports, 0, 8), (x) => ({ dev: x.dev, label: substr(x.label ?? '', 0, 24), up: x.up, speed: x.speed, lvl: x.level }));
	return hb;
}

/* every tick: send (sender), notice a silent second router (receiver) */
function peer_tick(hb) {
	if (!peer.sk) return null;
	if (C.cfg.peer.role == 'send') {
		peer_flush(hb);
		return null;
	}
	let t = now(), list = [], level = 'ok', reasons = [], changed = false;
	for (let n, p in peer.peers) {
		if (p.online && t - p.seen > max(60, p.iv * 4)) {
			p.online = false;
			p.lost_at = p.seen;
			changed = true;
			C.emit('warn', 'system', n, 'peer_lost', { last: p.seen, addr: p.addr });
		}
		if (!p.seen) continue;
		/* a router that did not report for an hour is shown, but not judged */
		let pl = p.online ? (p.hb?.lvl ?? 'unknown') : (t - p.seen < 3600 ? 'warn' : 'unknown');
		if (!p.online && pl == 'warn') push(reasons, { c: 'peer_offline', name: n, since: p.seen });
		else if (pl == 'warn' || pl == 'fail') push(reasons, { c: 'peer_level', name: n, lvl: pl });
		if (LEVEL[pl] != null) level = worst(level, pl == 'fail' ? 'fail' : pl);
		push(list, { name: n, addr: p.addr, online: p.online, seen: p.seen, off: p.off, iv: p.iv, level: pl, hb: p.online ? p.hb : null });
	}
	if (changed) peer_save(true);
	return { level, reasons, list };
}

function peer_out() {
	if (C.cfg.peer.role == 'off') return null;
	let o = { role: C.cfg.peer.role, port: C.cfg.peer.port, err: C.cfg.peer.err, bad: peer.bad, bad_addr: peer.bad_addr, bad_ts: peer.bad_ts };
	if (C.cfg.peer.role == 'send') {
		o.host = C.cfg.peer.host;
		o.last_ack = peer.last_ack;
		o.pending = length(peer.out);
		o.dropped = peer.dropped;
		/* nothing acknowledged for a while: receiver down, wrong address or key */
		if (!o.err && peer.sk && now() - (peer.last_ack ?? C.started()) > max(60, C.cfg.interval * 6)) o.err = 'no_ack';
	}
	return o;
}

/* the clock was stepped while not trusted (see clock.uc clk_fix): without
 * this a step forward made every second router look silent (a false
 * peer_lost and peer_back) and the sender show "no answer" */
function peer_shift(by) {
	let mv = (o, ks) => { for (let k in ks) if (type(o[k]) == 'int' || type(o[k]) == 'double') o[k] += by; };
	mv(peer, [ 'last_send', 'last_ack', 'bad_ts', 'send_err' ]);
	for (let n, p in peer.peers) mv(p, [ 'seen', 'lost_at' ]);
	peer_saved.ts = 0;
}

export { peer_shift, peer_init, peer_queue, peer_start, peer_hb, peer_tick, peer_out };
