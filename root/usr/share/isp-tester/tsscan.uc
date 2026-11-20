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
 *   - the channel name, from the stream's PAT and SDT tables (in the clear
 *     on scrambled channels too)
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

/* ISO 8859-n, bytes 0xA0-0xFF as 4-digit hex code points (0000 = undefined) */
const L8859 = {
	'1': '00a000a100a200a300a400a500a600a700a800a900aa00ab00ac00ad00ae00af00b000b100b200b300b400b500b600b700b800b900ba00bb00bc00bd00be00bf00c000c100c200c300c400c500c600c700c800c900ca00cb00cc00cd00ce00cf00d000d100d200d300d400d500d600d700d800d900da00db00dc00dd00de00df00e000e100e200e300e400e500e600e700e800e900ea00eb00ec00ed00ee00ef00f000f100f200f300f400f500f600f700f800f900fa00fb00fc00fd00fe00ff',
	'2': '00a0010402d8014100a4013d015a00a700a80160015e0164017900ad017d017b00b0010502db014200b4013e015b02c700b80161015f0165017a02dd017e017c015400c100c2010200c40139010600c7010c00c9011800cb011a00cd00ce010e01100143014700d300d4015000d600d70158016e00da017000dc00dd016200df015500e100e2010300e4013a010700e7010d00e9011900eb011b00ed00ee010f01110144014800f300f4015100f600f70159016f00fa017100fc00fd016302d9',
	'3': '00a0012602d800a300a40000012400a700a80130015e011e013400ad0000017b00b0012700b200b300b400b5012500b700b80131015f011f013500bd0000017c00c000c100c2000000c4010a010800c700c800c900ca00cb00cc00cd00ce00cf000000d100d200d300d4012000d600d7011c00d900da00db00dc016c015c00df00e000e100e2000000e4010b010900e700e800e900ea00eb00ec00ed00ee00ef000000f100f200f300f4012100f600f7011d00f900fa00fb00fc016d015d02d9',
	'4': '00a001040138015600a40128013b00a700a8016001120122016600ad017d00af00b0010502db015700b40129013c02c700b80161011301230167014a017e014b010000c100c200c300c400c500c6012e010c00c9011800cb011600cd00ce012a01100145014c013600d400d500d600d700d8017200da00db00dc0168016a00df010100e100e200e300e400e500e6012f010d00e9011900eb011700ed00ee012b01110146014d013700f400f500f600f700f8017300fa00fb00fc0169016b02d9',
	'5': '00a0040104020403040404050406040704080409040a040b040c00ad040e040f0410041104120413041404150416041704180419041a041b041c041d041e041f0420042104220423042404250426042704280429042a042b042c042d042e042f0430043104320433043404350436043704380439043a043b043c043d043e043f0440044104420443044404450446044704480449044a044b044c044d044e044f2116045104520453045404550456045704580459045a045b045c00a7045e045f',
	'6': '00a000000000000000a40000000000000000000000000000060c00ad0000000000000000000000000000000000000000000000000000061b000000000000061f0000062106220623062406250626062706280629062a062b062c062d062e062f0630063106320633063406350636063706380639063a000000000000000000000640064106420643064406450646064706480649064a064b064c064d064e064f0650065106520000000000000000000000000000000000000000000000000000',
	'7': '00a02018201900a320ac20af00a600a700a800a9037a00ab00ac00ad0000201500b000b100b200b303840385038600b703880389038a00bb038c00bd038e038f0390039103920393039403950396039703980399039a039b039c039d039e039f03a003a1000003a303a403a503a603a703a803a903aa03ab03ac03ad03ae03af03b003b103b203b303b403b503b603b703b803b903ba03bb03bc03bd03be03bf03c003c103c203c303c403c503c603c703c803c903ca03cb03cc03cd03ce0000',
	'8': '00a0000000a200a300a400a500a600a700a800a900d700ab00ac00ad00ae00af00b000b100b200b300b400b500b600b700b800b900f700bb00bc00bd00be00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000201705d005d105d205d305d405d505d605d705d805d905da05db05dc05dd05de05df05e005e105e205e305e405e505e605e705e805e905ea00000000200e200f0000',
	'9': '00a000a100a200a300a400a500a600a700a800a900aa00ab00ac00ad00ae00af00b000b100b200b300b400b500b600b700b800b900ba00bb00bc00bd00be00bf00c000c100c200c300c400c500c600c700c800c900ca00cb00cc00cd00ce00cf011e00d100d200d300d400d500d600d700d800d900da00db00dc0130015e00df00e000e100e200e300e400e500e600e700e800e900ea00eb00ec00ed00ee00ef011f00f100f200f300f400f500f600f700f800f900fa00fb00fc0131015f00ff',
	'10': '00a0010401120122012a0128013600a7013b011001600166017d00ad016a014a00b0010501130123012b0129013700b7013c011101610167017e2015016b014b010000c100c200c300c400c500c6012e010c00c9011800cb011600cd00ce00cf00d00145014c00d300d400d500d6016800d8017200da00db00dc00dd00de00df010100e100e200e300e400e500e6012f010d00e9011900eb011700ed00ee00ef00f00146014d00f300f400f500f6016900f8017300fa00fb00fc00fd00fe0138',
	'11': '00a00e010e020e030e040e050e060e070e080e090e0a0e0b0e0c0e0d0e0e0e0f0e100e110e120e130e140e150e160e170e180e190e1a0e1b0e1c0e1d0e1e0e1f0e200e210e220e230e240e250e260e270e280e290e2a0e2b0e2c0e2d0e2e0e2f0e300e310e320e330e340e350e360e370e380e390e3a00000000000000000e3f0e400e410e420e430e440e450e460e470e480e490e4a0e4b0e4c0e4d0e4e0e4f0e500e510e520e530e540e550e560e570e580e590e5a0e5b0000000000000000',
	'13': '00a0201d00a200a300a4201e00a600a700d800a9015600ab00ac00ad00ae00c600b000b100b200b3201c00b500b600b700f800b9015700bb00bc00bd00be00e60104012e0100010600c400c501180112010c00c90179011601220136012a013b01600143014500d3014c00d500d600d701720141015a016a00dc017b017d00df0105012f0101010700e400e501190113010d00e9017a011701230137012b013c01610144014600f3014d00f500f600f701730142015b016b00fc017c017e2019',
	'14': '00a01e021e0300a3010a010b1e0a00a71e8000a91e821e0b1ef200ad00ae01781e1e1e1f012001211e401e4100b61e561e811e571e831e601ef31e841e851e6100c000c100c200c300c400c500c600c700c800c900ca00cb00cc00cd00ce00cf017400d100d200d300d400d500d61e6a00d800d900da00db00dc00dd017600df00e000e100e200e300e400e500e600e700e800e900ea00eb00ec00ed00ee00ef017500f100f200f300f400f500f61e6b00f800f900fa00fb00fc00fd017700ff',
	'15': '00a000a100a200a320ac00a5016000a7016100a900aa00ab00ac00ad00ae00af00b000b100b200b3017d00b500b600b7017e00b900ba00bb01520153017800bf00c000c100c200c300c400c500c600c700c800c900ca00cb00cc00cd00ce00cf00d000d100d200d300d400d500d600d700d800d900da00db00dc00dd00de00df00e000e100e200e300e400e500e600e700e800e900ea00eb00ec00ed00ee00ef00f000f100f200f300f400f500f600f700f800f900fa00fb00fc00fd00fe00ff',
	'16': '00a001040105014120ac201e016000a7016100a9021800ab017900ad017a017b00b000b1010c0142017d201d00b600b7017e010d021900bb015201530178017c00c000c100c2010200c4010600c600c700c800c900ca00cb00cc00cd00ce00cf0110014300d200d300d4015000d6015a017000d900da00db00dc0118021a00df00e000e100e2010300e4010700e600e700e800e900ea00eb00ec00ed00ee00ef0111014400f200f300f4015100f6015b017100f900fa00fb00fc0119021b00ff',
};
/* ISO/IEC 6937 (DVB default table), bytes 0xA0-0xFF; 0xC1-0xCF are accents */
const L6937 = '00a000a100a200a3002400a5002300a700a42018201c00ab219021912192219300b000b100b200b300d700b500b600b700f72019201d00bb00bc00bd00be00bf0000000000000000000000000000000000000000000000000000000000000000201500b900ae00a92122266a00ac00a60000000000000000215b215c215d215e212600c6011000aa012600000132013f014100d8015200ba00de0166014a0149013800e6011100f00127013101330140014200f8015300df00fe0167014b00ad';
/* accent byte -> letters it combines with, each letter followed by 4-digit hex code point */
const A6937 = {
	'193': 'A00c0E00c8I00ccN01f8O00d2U00d9W1e80Y1ef2a00e0e00e8i00ecn01f9o00f2u00f9w1e81y1ef3',
	'194': 'A00c1C0106E00c9G01f4I00cdK1e30L0139M1e3eN0143O00d3P1e54R0154S015aU00daW1e82Y00ddZ0179a00e1c0107e00e9g01f5i00edk1e31l013am1e3fn0144o00f3p1e55r0155s015bu00faw1e83y00fdz017a',
	'195': 'A00c2C0108E00caG011cH0124I00ceJ0134O00d4S015cU00dbW0174Y0176Z1e90a00e2c0109e00eag011dh0125i00eej0135o00f4s015du00fbw0175y0177z1e91',
	'196': 'A00c3E1ebcI0128N00d1O00d5U0168V1e7cY1ef8a00e3e1ebdi0129n00f1o00f5u0169v1e7dy1ef9',
	'197': 'A0100E0112G1e20I012aO014cU016aY0232a0101e0113g1e21i012bo014du016by0233',
	'198': 'A0102E0114G011eI012cO014eU016ca0103e0115g011fi012do014fu016d',
	'199': 'A0226B1e02C010aD1e0aE0116F1e1eG0120H1e22I0130M1e40N1e44O022eP1e56R1e58S1e60T1e6aW1e86X1e8aY1e8eZ017ba0227b1e03c010bd1e0be0117f1e1fg0121h1e23m1e41n1e45o022fp1e57r1e59s1e61t1e6bw1e87x1e8by1e8fz017c',
	'200': 'A00c4E00cbH1e26I00cfO00d6U00dcW1e84X1e8cY0178a00e4e00ebh1e27i00efo00f6t1e97u00fcw1e85x1e8dy00ff',
	'202': 'A00c5U016ea00e5u016fw1e98y1e99',
	'203': 'C00c7D1e10E0228G0122H1e28K0136L013bN0145R0156S015eT0162c00e7d1e11e0229g0123h1e29k0137l013cn0146r0157s015ft0163',
	'205': 'O0150U0170o0151u0171',
	'206': 'A0104E0118I012eO01eaU0172a0105e0119i012fo01ebu0173',
	'207': 'A01cdC010cD010eE011aG01e6H021eI01cfK01e8L013dN0147O01d1R0158S0160T0164U01d3Z017da01cec010dd010fe011bg01e7h021fi01d0j01f0k01e9l013en0148o01d2r0159s0161t0165u01d4z017e',
};
/* ------------------------------------------------------- channel names */

/*
 * The channel name comes from the stream itself: the DVB Service Description
 * Table (SDT, PID 0x11) names each service, the PAT (PID 0) says which
 * service this stream carries. Both are sent in the clear every second or
 * two, also on scrambled channels. DVB text uses its own character tables
 * (EN 300 468 annex A), converted to UTF-8 here.
 */

function u8(cp) {
	if (cp < 0x80) return chr(cp);
	if (cp < 0x800) return chr(0xc0 | (cp >> 6), 0x80 | (cp & 63));
	return chr(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
}

function tcp(tbl, i) {
	return hex(substr(tbl, i * 4, 4)) || null;
}

/* text that is already UTF-8: keep only well-formed sequences */
function utf8_clean(s, p) {
	let out = '', n = length(s);
	while (p < n) {
		let c = ord(s, p), k = 0;
		if (c < 0x80) { if (c >= 0x20 && c != 0x7f) out += chr(c); p++; continue; }
		if (c >= 0xc2 && c <= 0xdf) k = 1;
		else if (c >= 0xe0 && c <= 0xef) k = 2;
		else if (c >= 0xf0 && c <= 0xf4) k = 3;
		else { p++; continue; }
		let ok = true;
		for (let j = 1; j <= k; j++)
			if (p + j >= n || (ord(s, p + j) & 0xc0) != 0x80) { ok = false; break; }
		if (!ok) { p++; continue; }
		/* DVB control codes in UTF-8 text are U+E080..U+E09F */
		let cp = (k == 2) ? ((c & 15) << 12) | ((ord(s, p + 1) & 63) << 6) | (ord(s, p + 2) & 63) : 0;
		if (!(cp >= 0xe080 && cp <= 0xe09f))
			out += substr(s, p, k + 1);
		p += k + 1;
	}
	return out;
}

function dvb_text(s) {
	let n = length(s ?? '');
	if (!n) return '';
	let b = ord(s, 0), p = 0, tbl = null, out = '';

	if (b >= 0x20) tbl = '6937';
	else if (b >= 0x01 && b <= 0x0b) { tbl = `${b + 4}`; p = 1; }
	else if (b == 0x10 && n >= 3) { tbl = `${ord(s, 2)}`; p = 3; }
	else if (b == 0x15) return utf8_clean(s, 1);
	else if (b == 0x11) {
		/* UCS-2, big-endian */
		for (p = 1; p + 1 < n; p += 2) {
			let cp = (ord(s, p) << 8) | ord(s, p + 1);
			if (cp >= 0x20 && !(cp >= 0x7f && cp <= 0x9f) && !(cp >= 0xd800 && cp <= 0xdfff) && !(cp >= 0xe080 && cp <= 0xe09f))
				out += u8(cp);
		}
		return out;
	}
	else { tbl = 'ascii'; p = 1; }   /* GB2312, Big5, KSC: only the ASCII part */

	let latin = L8859[tbl];
	while (p < n) {
		let c = ord(s, p++);
		if (c < 0x20 || c == 0x7f) continue;
		if (c < 0x80) { out += chr(c); continue; }
		if (c < 0xa0) {
			/* control codes: 0x8a is a line break, the rest is emphasis on/off */
			if (c == 0x8a) out += ' ';
			continue;
		}
		let cp = null;
		if (tbl == '6937') {
			let acc = A6937[`${c}`];
			if (acc != null) {
				if (p >= n) break;
				let l = substr(s, p++, 1);
				/* accent with a letter it does not combine with: keep the letter */
				cp = ord(l);
				for (let i = 0; i < length(acc); i += 5)
					if (substr(acc, i, 1) == l) { cp = hex(substr(acc, i + 1, 4)); break; }
			}
			else
				cp = tcp(L6937, c - 0xa0);
		}
		else if (latin)
			cp = tcp(latin, c - 0xa0);
		if (cp) out += u8(cp);
	}
	return out;
}

function clean_name(s) {
	s = trim(replace(s ?? '', /[ \t\n]+/g, ' '));
	return (length(s) > 64) ? substr(s, 0, 64) : s;
}

/* CRC-32/MPEG-2 over a whole section (including its CRC): 0 when intact */
let crc_tab = null;
function crc32_ok(s) {
	if (!crc_tab) {
		crc_tab = [];
		for (let i = 0; i < 256; i++) {
			let c = i << 24;
			for (let j = 0; j < 8; j++)
				c = (c & 0x80000000) ? ((c << 1) ^ 0x04c11db7) & 0xffffffff : (c << 1) & 0xffffffff;
			push(crc_tab, c);
		}
	}
	let crc = 0xffffffff, n = length(s);
	for (let i = 0; i < n; i++)
		crc = ((crc << 8) & 0xffffffff) ^ crc_tab[((crc >> 24) ^ ord(s, i)) & 255];
	return crc == 0;
}

function parse_section(g, s) {
	let tid = ord(s, 0), n = length(s);
	if (n < 12 || !(ord(s, 1) & 0x80) || !crc32_ok(s)) return;
	/* current_next_indicator: ignore tables that are not in force yet */
	if (!(ord(s, 5) & 1)) return;

	if (tid == 0x00) {
		let progs = [];
		for (let p = 8; p + 4 <= n - 4; p += 4) {
			let pn = (ord(s, p) << 8) | ord(s, p + 1);
			if (pn) push(progs, pn);
		}
		g.pat = progs;
	}
	else if (tid == 0x42) {
		/* SDT of this transport stream (0x46 = other streams: skip) */
		let p = 11;
		while (p + 5 <= n - 4) {
			let sid = (ord(s, p) << 8) | ord(s, p + 1);
			let dl = ((ord(s, p + 3) & 0x0f) << 8) | ord(s, p + 4);
			let d = p + 5, dend = d + dl;
			if (dend > n - 4) break;
			while (d + 2 <= dend) {
				let tag = ord(s, d), len = ord(s, d + 1);
				if (d + 2 + len > dend) break;
				if (tag == 0x48 && len >= 3) {
					let st = ord(s, d + 2), pl = ord(s, d + 3);
					let nl = (4 + pl < len + 2) ? ord(s, d + 4 + pl) : 0;
					if (5 + pl + nl <= len + 2) {
						let name = clean_name(dvb_text(substr(s, d + 5 + pl, nl)));
						if (name != '')
							g.svc[`${sid}`] = { sid, type: st, name,
								provider: clean_name(dvb_text(substr(s, d + 4, pl))) || null };
					}
				}
				d += 2 + len;
			}
			p = dend;
		}
	}
	if (g.pat != null && length(g.svc)) {
		for (let pn in g.pat)
			if (g.svc[`${pn}`]) { g.psi_done = true; break; }
	}
}

function psi_drain(g, st) {
	while (st.buf != null && length(st.buf) >= 3) {
		if (ord(st.buf, 0) == 0xff) { st.buf = null; break; }
		let sl = (((ord(st.buf, 1) & 0x0f) << 8) | ord(st.buf, 2)) + 3;
		if (sl > 4096) { st.buf = null; break; }
		if (length(st.buf) < sl) break;
		parse_section(g, substr(st.buf, 0, sl));
		st.buf = (length(st.buf) > sl) ? substr(st.buf, sl) : null;
	}
}

/* collect PSI sections of PID 0 / 0x11 from one TS packet at q */
function psi_packet(g, pid, q, x1, afc) {
	let st = g.psi[pid] ??= { buf: null };
	let off = q + 4;
	if (afc & 2) off += 1 + ord(buf, q + 4);
	let end = q + 188;
	if (off >= end) return;

	if (x1 & 0x40) {
		let ptr = ord(buf, off++);
		if (st.buf != null && off + ptr <= end)
			st.buf += substr(buf, off, ptr);
		psi_drain(g, st);
		off += ptr;
		st.buf = (off < end) ? substr(buf, off, end - off) : null;
	}
	else if (st.buf != null)
		st.buf += substr(buf, off, end - off);
	else
		return;
	psi_drain(g, st);
}

/* the service this stream carries: the one the PAT names, else the only one */
function group_service(g) {
	for (let pn in (g.pat ?? []))
		if (g.svc[`${pn}`]) return g.svc[`${pn}`];
	let all = values(g.svc);
	return (length(all) == 1) ? all[0] : null;
}

/* --------------------------------------------------------- capture */

let groups = {};
let other = 0, trunc = 0;
let last_key = null, last_g = null;
let t_min = null, t_max = null;

function new_group(key, grp) {
	let last = [], dup = [];
	for (let i = 0; i < 8192; i++) { push(last, -1); push(dup, 0); }
	return { grp, key, pkts: 0, ts_pkts: 0, bytes: 0, cc_err: 0, lost: 0, tei: 0, sync_err: 0,
		t_first: null, t_last: null, max_gap: 0, rtp: false, rtp_seq: -1, rtp_lost: 0, last, dup,
		psi: {}, pat: null, svc: {}, psi_done: false };
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
		/* PAT / SDT for the channel name, until the service is known */
		if (!g.psi_done && (pid == 0 || pid == 0x11) && (afc & 1) && !(x1 & 0x80))
			psi_packet(g, pid, q, x1, afc);
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
	let sv = group_service(g);
	push(list, {
		grp: g.grp, pkts: g.pkts, ts_pkts: g.ts_pkts,
		pps: gd > 0.2 ? int(g.pkts / gd) : null,
		kbps: gd > 0.2 ? int(g.bytes * 8 / gd / 1000) : null,
		cc_err: g.cc_err, lost: g.lost, tei: g.tei, sync_err: g.sync_err,
		max_gap_ms: int(g.max_gap * 1000),
		rtp: g.rtp, rtp_lost: g.rtp_lost,
		svc: sv ? { name: sv.name, provider: sv.provider, sid: sv.sid, type: sv.type } : null,
		psi: { pat: g.pat != null, sdt: length(g.svc) > 0 }
	});
}
sort(list, (a, b) => b.pkts - a.pkts);
if (length(list) > 4) list = slice(list, 0, 4);

finish({ dur: int(dur * 10) / 10.0, groups: list, other, trunc });
