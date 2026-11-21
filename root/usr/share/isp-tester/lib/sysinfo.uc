'use strict';

/* luci-app-isp-tester: part of the collector (see ../collector.uc) */

import * as fs from 'fs';
import { ROUTE, PROC, RRDTOOL, BRIDGE, STAT_KEYS, mono, num, valid_host, round } from './common.uc';
import { sfp_parse, cd_parse_val } from './parsers.uc';

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

function sfp_read(dev) {
	let f = fs.popen(`${TIMEOUT ? TIMEOUT + ' 5 ' : ''}${ETHTOOL} -m ${dev} 2>&1`, 'r');
	if (!f) return { err: 'run' };
	let out = f.read('all') ?? '';
	f.close();
	let r = sfp_parse(out);
	if (!r.has_rx) {
		/* "Cannot get module EEPROM information: Operation not supported" - no module, or none with diagnostics */
		let first = trim(split(out, '\n')[0] ?? '');
		return { err: (first != '' && !match(first, /^Identifier/)) ? substr(first, 0, 80) : 'no_diag' };
	}
	return r;
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

function dnsmasq_pids() {
	let out = [];
	for (let pid in (fs.lsdir(PROC) ?? []))
		if (match(pid, /^[0-9]+$/) && trim(fs.readfile(`${PROC}/${pid}/comm`) ?? '') == 'dnsmasq') push(out, int(pid));
	return out;
}

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

export { rd, read_dev, default_gateway, sfp_read, cd_unixsock, rrd_last, cd_rrd, pid_usage, bridge_mdb, read_cpus, meminfo, dnsmasq_pids, base, is_uplink, bridge_json };
