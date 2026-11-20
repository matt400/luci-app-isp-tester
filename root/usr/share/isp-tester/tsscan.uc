#!/usr/bin/ucode
/*
 * luci-app-isp-tester - MPEG-TS quality scanner
 *
 * Usage: ucode tsscan.uc <capture.pcap> <result.json>
 *
 * Reads a short tcpdump capture of the IPTV multicast stream and counts what
 * a viewer sees as pixelation and freezes, without decoding any video (works
 * on scrambled streams too):
 *   - continuity counter (CC) errors per PID: a gap means lost packets
 *   - lost TS packets (estimated from the CC jump), transport error flags
 *   - RTP sequence gaps, when the stream is RTP-wrapped
 *   - the longest pause between two datagrams of the stream
 * Datagrams that do not carry MPEG-TS (EPG / service groups) are ignored, so
 * the channel being watched is the group that carries TS.
 *
 * Handles untagged and 802.1Q frames, both pcap byte orders, IPv4 only.
 * Runs as a short-lived process started by the collector, so a long parse
 * never blocks it.
 */
'use strict';

import * as fs from 'fs';

let file = ARGV[0], outfile = ARGV[1];
if (!file || !outfile) {
	warn('usage: tsscan.uc <capture.pcap> <result.json>\n');
	exit(2);
}

function finish(res) {
	fs.writefile(outfile, sprintf('%J', res));
	fs.unlink(file);
	exit(0);
}

let buf = fs.readfile(file);
let n = buf ? length(buf) : 0;
if (n < 24)
	finish({ dur: 0, groups: [], other: 0, error: 'empty' });

/* pcap byte order and time resolution from the magic number */
let m0 = ord(buf, 0), m1 = ord(buf, 1), m2 = ord(buf, 2), m3 = ord(buf, 3);
let le, tdiv = 1000000.0;
if (m0 == 0xd4 && m1 == 0xc3 && m2 == 0xb2 && m3 == 0xa1) le = true;
else if (m0 == 0xa1 && m1 == 0xb2 && m2 == 0xc3 && m3 == 0xd4) le = false;
else if (m0 == 0x4d && m1 == 0x3c && m2 == 0xb2 && m3 == 0xa1) { le = true; tdiv = 1000000000.0; }
else if (m0 == 0xa1 && m1 == 0xb2 && m2 == 0x3c && m3 == 0x4d) { le = false; tdiv = 1000000000.0; }
else
	finish({ dur: 0, groups: [], other: 0, error: 'not_pcap' });

function u32(p) {
	let a = ord(buf, p), b = ord(buf, p + 1), c = ord(buf, p + 2), d = ord(buf, p + 3);
	return le ? (a | (b << 8) | (c << 16) | (d << 24))
	          : ((a << 24) | (b << 16) | (c << 8) | d);
}

/* only Ethernet frames */
let linktype = u32(20);
if (linktype != 1)
	finish({ dur: 0, groups: [], other: 0, error: 'linktype' });

let groups = {};
let other = 0, trunc = 0;
let last_key = null, last_g = null;
let t_min = null, t_max = null;

function new_group(key, grp) {
	let last = [], dup = [];
	for (let i = 0; i < 8192; i++) { push(last, -1); push(dup, 0); }
	return { grp, key, pkts: 0, ts_pkts: 0, bytes: 0, cc_err: 0, lost: 0, tei: 0, sync_err: 0,
		t_first: null, t_last: null, max_gap: 0, rtp: false, rtp_seq: -1, rtp_lost: 0, last, dup };
}

let p = 24;
while (p + 16 <= n) {
	let sec = u32(p), frac = u32(p + 4), incl = u32(p + 8), orig = u32(p + 12);
	p += 16;
	let end = p + incl;
	if (end > n) break;
	let t = sec + frac / tdiv;
	let f = p;
	p = end;

	if (incl < 46) continue;

	let et = (ord(buf, f + 12) << 8) | ord(buf, f + 13);
	let ip = f + 14;
	if (et == 0x8100 || et == 0x88a8) {
		et = (ord(buf, f + 16) << 8) | ord(buf, f + 17);
		ip = f + 18;
	}
	if (et != 0x0800) continue;

	let vihl = ord(buf, ip);
	if ((vihl >> 4) != 4 || ord(buf, ip + 9) != 17) continue;
	let ihl = (vihl & 15) * 4;
	/* fragments cannot be parsed without reassembly */
	if ((ord(buf, ip + 6) & 0x3f) || ord(buf, ip + 7) || (ord(buf, ip + 6) & 0x20)) { other++; continue; }

	let key = u32(ip + 16);
	if (key != last_key) {
		let gn = sprintf('%d.%d.%d.%d', ord(buf, ip + 16), ord(buf, ip + 17), ord(buf, ip + 18), ord(buf, ip + 19));
		last_g = groups[gn] ??= new_group(key, gn);
		last_key = key;
	}
	let g = last_g;

	let plen = ((ord(buf, ip + 2) << 8) | ord(buf, ip + 3)) - ihl - 8;
	let pl = ip + ihl + 8;
	if (pl + plen > end) { plen = end - pl; trunc++; }
	if (plen < 188) { other++; continue; }

	/* raw TS, or RTP (version 2) carrying TS */
	let ts = pl, tlen = plen;
	let b0 = ord(buf, pl);
	if (b0 != 0x47) {
		if ((b0 >> 6) != 2) { other++; continue; }
		let hdr = 12 + 4 * (b0 & 15);
		if (b0 & 0x10) hdr += 4 + 4 * ((ord(buf, pl + hdr + 2) << 8) | ord(buf, pl + hdr + 3));
		if (plen <= hdr || ord(buf, pl + hdr) != 0x47) { other++; continue; }
		ts = pl + hdr;
		tlen = plen - hdr;
		let seq = (ord(buf, pl + 2) << 8) | ord(buf, pl + 3);
		g.rtp = true;
		if (g.rtp_seq >= 0) {
			let d = (seq - g.rtp_seq) & 0xffff;
			/* repeated or reordered packet: not a loss */
			if (d == 0 || d > 0x8000) continue;
			g.rtp_lost += d - 1;
		}
		g.rtp_seq = seq;
	}

	/* datagram timing */
	if (g.t_last != null && t - g.t_last > g.max_gap) g.max_gap = t - g.t_last;
	g.t_last = t;
	g.t_first ??= t;
	if (t_min == null || t < t_min) t_min = t;
	if (t_max == null || t > t_max) t_max = t;
	g.pkts++;
	g.bytes += orig;

	let last = g.last, dup = g.dup;
	for (let q = ts; q + 188 <= ts + tlen; q += 188) {
		if (ord(buf, q) != 0x47) { g.sync_err++; break; }
		let x1 = ord(buf, q + 1), x2 = ord(buf, q + 2), x3 = ord(buf, q + 3);
		g.ts_pkts++;
		let pid = ((x1 & 0x1f) << 8) | x2;
		if (pid == 0x1fff) continue;
		if (x1 & 0x80) g.tei++;
		let afc = (x3 >> 4) & 3;
		if (afc == 0) continue;
		let cc = x3 & 15;
		if (afc & 2) {
			/* discontinuity indicator: the counter may jump here */
			if (ord(buf, q + 4) > 0 && (ord(buf, q + 5) & 0x80)) {
				last[pid] = (afc & 1) ? cc : -1;
				dup[pid] = 0;
				continue;
			}
		}
		/* packets without payload do not advance the counter */
		if (!(afc & 1)) continue;

		let lc = last[pid];
		if (lc >= 0) {
			let exp = (lc + 1) & 15;
			if (cc == exp) {
				dup[pid] = 0;
			}
			else if (cc == lc && !dup[pid]) {
				/* one duplicate packet in a row is allowed by the standard */
				dup[pid] = 1;
				continue;
			}
			else {
				g.cc_err++;
				g.lost += (cc - exp) & 15;
				dup[pid] = 0;
			}
		}
		last[pid] = cc;
	}
}

let dur = (t_min != null) ? t_max - t_min : 0;
let list = [];
for (let k, g in groups) {
	if (!g.ts_pkts) continue;
	let gd = (g.t_first != null) ? g.t_last - g.t_first : 0;
	push(list, {
		grp: g.grp, pkts: g.pkts, ts_pkts: g.ts_pkts,
		pps: gd > 0.2 ? int(g.pkts / gd) : null,
		kbps: gd > 0.2 ? int(g.bytes * 8 / gd / 1000) : null,
		cc_err: g.cc_err, lost: g.lost, tei: g.tei, sync_err: g.sync_err,
		max_gap_ms: int(g.max_gap * 1000),
		rtp: g.rtp, rtp_lost: g.rtp_lost
	});
}
sort(list, (a, b) => b.pkts - a.pkts);
if (length(list) > 4) list = slice(list, 0, 4);

finish({ dur: int(dur * 10) / 10.0, groups: list, other, trunc });
