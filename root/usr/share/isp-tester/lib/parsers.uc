'use strict';

/* luci-app-isp-tester: part of the collector (see ../collector.uc) */

import { num, round } from './common.uc';

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
		push(hops, { n: +m[1], ip: ip ? ip[1] : null, loss: round(stars * 100.0 / sent, 0),
			avg: length(rtts) ? round(sum / (length(rtts) * 1.0), 1) : null });
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

function median(a) {
	if (!length(a)) return null;
	let s = sort([ ...a ], (x, y) => x - y), n = length(s);
	/* / 2.0: two ints would be divided as integers in ucode */
	return (n % 2) ? s[n >> 1] : (s[n / 2 - 1] + s[n / 2]) / 2.0;
}

/* "0.5412 mW / -2.67 dBm" -> -2.67; "-inf dBm" -> null */
function sfp_dbm(v) {
	let m = match(v, /(-?[0-9.]+|-?inf)\s*dBm/);
	return (m && m[1] != '-inf' && m[1] != 'inf') ? num(m[1], null) : null;
}

function sfp_num(v) {
	let m = match(v, /^(-?[0-9.]+)/);
	return m ? num(m[1], null) : null;
}

function sfp_parse(txt) {
	let r = { rx: null, tx: null, temp: null, vcc: null, bias: null, has_rx: false, flags: [] };
	for (let l in split(txt, '\n')) {
		let k = index(l, ':');
		if (k < 0) continue;
		let key = trim(substr(l, 0, k)), val = trim(substr(l, k + 1));
		if (key == 'Laser output power') r.tx = sfp_dbm(val);
		else if (match(key, /^Receiver signal (average optical power|OMA)$/)) { r.rx = sfp_dbm(val); r.has_rx = true; }
		else if (key == 'Module temperature') r.temp = sfp_num(val);
		else if (key == 'Module voltage') r.vcc = sfp_num(val);
		else if (key == 'Laser bias current') r.bias = sfp_num(val);
		else if (match(key, /(alarm|warning)$/) && val == 'On') push(r.flags, key);
	}
	return r;
}

function sfp_median(a) {
	let m = median(a);
	return (m == null) ? null : round(m, 2);
}

function cd_parse_val(v) {
	v = trim(v ?? '');
	if (v == '' || match(v, /^-?nan$/i) || v == 'U') return null;
	let n = +v;
	return (n != n) ? null : n;
}

const MONTHS = { Jan: 1, Feb: 2, Mar: 3, Apr: 4, May: 5, Jun: 6, Jul: 7, Aug: 8, Sep: 9, Oct: 10, Nov: 11, Dec: 12 };

/* "Thu Nov 19 16:41:01 2026 daemon.notice pppd[1234]: message" */
function parse_log_line(line) {
	let m = match(line, /^[A-Z][a-z][a-z] ([A-Z][a-z][a-z]) +([0-9]+) ([0-9]+):([0-9]+):([0-9]+) ([0-9]+) ([a-z0-9]+)\.([a-z]+) ([^ :]+): (.*)$/);
	if (!m || !MONTHS[m[1]]) return null;
	let prog = replace(m[9], /\[[0-9]+\]$/, '');
	/* the pid tells instances of one program apart (several dnsmasq) */
	let pm = match(m[9], /\[([0-9]+)\]$/);
	let ts = timelocal({ year: +m[6], mon: MONTHS[m[1]], mday: +m[2], hour: +m[3], min: +m[4], sec: +m[5] });
	/* kernel lines start with the uptime stamp: "[12345.678901] " */
	return { ts, prio: m[8], prog, pid: pm ? int(pm[1]) : null, msg: replace(m[10], /^\[ *[0-9.]+\] /, '') };
}

function uniq_list(a) {
	let out = [];
	for (let x in a) if (x != null && index(out, x) < 0) push(out, x);
	return out;
}

export { urlenc, trace_parse_mtr, trace_parse_tr, trace_judge, median, sfp_dbm, sfp_num, sfp_parse, sfp_median, cd_parse_val, MONTHS, parse_log_line, uniq_list };
