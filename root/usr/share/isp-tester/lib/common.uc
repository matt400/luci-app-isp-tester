'use strict';

/* luci-app-isp-tester: part of the collector (see ../collector.uc) */

import * as fs from 'fs';

const RUNDIR = getenv('ISP_TESTER_RUNDIR') || '/tmp/isp-tester';

/* testing with a JSON config: no ubus unless ISP_TESTER_UBUS is set */
const NO_UBUS = !!getenv('ISP_TESTER_CONFIG') && !getenv('ISP_TESTER_UBUS');

const VARDIR = getenv('ISP_TESTER_VARDIR') || '/var/run/isp-tester';

const SYSNET = getenv('ISP_TESTER_SYSNET') || '/sys/class/net';

const ROUTE = getenv('ISP_TESTER_ROUTE') || '/proc/net/route';

const PROC = getenv('ISP_TESTER_PROC') || '/proc';

function find_bin(env, names) {
	let e = getenv(env);
	if (e) return e;
	for (let n in names)
		if (fs.stat(n)) return n;
	return null;
}

const FETCH = find_bin('ISP_TESTER_FETCH', [ '/bin/uclient-fetch', '/usr/bin/uclient-fetch', '/usr/bin/wget', '/bin/wget' ]);

const LOGREAD = find_bin('ISP_TESTER_LOGREAD', [ '/sbin/logread', '/usr/sbin/logread' ]);

const RRDTOOL = find_bin('ISP_TESTER_RRDTOOL', [ '/usr/bin/rrdtool' ]);

const BRIDGE = find_bin('ISP_TESTER_BRIDGE', [ '/usr/sbin/bridge', '/sbin/bridge' ]);

const PROXIES = [ 'igmpproxy', 'mcproxy', 'omcproxy', 'improxy' ];

/* picture quality and channel names: the helper of package isp-tester-tsmon */
const TSMON = find_bin('ISP_TESTER_TSMON', [ '/usr/sbin/isp-tester-tsmon' ]);

/* snapshot of the path at a loss: mtr when installed, else busybox traceroute */
const MTR = find_bin('ISP_TESTER_MTR', [ '/usr/sbin/mtr', '/usr/bin/mtr' ]);

const TRACEROUTE = find_bin('ISP_TESTER_TRACEROUTE', [ '/usr/bin/traceroute', '/bin/traceroute', '/usr/sbin/traceroute' ]);

const TRACEROUTE6 = find_bin('ISP_TESTER_TRACEROUTE6', [ '/usr/bin/traceroute6', '/bin/traceroute6', '/usr/sbin/traceroute6' ]);

const TIMEOUT = find_bin('ISP_TESTER_TIMEOUT', [ '/usr/bin/timeout', '/bin/timeout' ]);

/* the SFP / ONT module's own measurements (ethtool -m), see wan.uc */
const ETHTOOL = find_bin('ISP_TESTER_ETHTOOL', [ '/usr/sbin/ethtool', '/sbin/ethtool', '/usr/bin/ethtool' ]);

const STAT_KEYS = [
	'rx_bytes', 'tx_bytes', 'rx_packets', 'tx_packets',
	'rx_errors', 'tx_errors', 'rx_dropped', 'tx_dropped',
	'rx_crc_errors', 'rx_frame_errors', 'rx_fifo_errors', 'rx_missed_errors',
	'multicast', 'collisions'
];

const LEVEL = { ok: 0, info: 0, warn: 1, err: 2, fail: 2 };

function now() { return time(); }

function mono() {
	let c = clock(true);
	return c ? c[0] + c[1] / 1e9 : time();
}

function num(v, dflt) {
	let n = +v;
	return (v == null || v == '' || n != n) ? dflt : n;
}

function bool(v, dflt) {
	if (v == null || v == '') return dflt;
	return (v == '1' || v == 'on' || v == 'true' || v == 'yes' || v === true || v === 1);
}

function aslist(v) {
	if (v == null) return [];
	return (type(v) == 'array') ? v : [ v ];
}

function valid_host(h) {
	return type(h) == 'string' && length(h) > 0 && length(h) < 254 && match(h, /^[A-Za-z0-9.:_-]+$/) != null;
}

function valid_dev(d) {
	return type(d) == 'string' && length(d) > 0 && length(d) < 32 && match(d, /^[A-Za-z0-9._@-]+$/) != null;
}

/* IPv4 multicast group (224-239.x.x.x), safe to put into a capture filter */
function valid_group(g) {
	let m = match(`${g ?? ''}`, /^(22[4-9]|23[0-9])\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/);
	return !!m && +m[2] <= 255 && +m[3] <= 255 && +m[4] <= 255;
}

/* multicast groups that are no TV channel: link-local (224.0.0.x, IPv6
 * ff0X::), SSDP / UPnP (239.255.255.250, which decoders and TVs join on
 * their own, also in standby) and SLP (239.255.255.253). The bridge's
 * multicast table (VLAN mode) lists them like channels: a decoder put in
 * standby still "watched" one, so its switch-off was logged as a freeze, and
 * the current channel / channel change were wrong. */
function mc_ignored(g) {
	g = `${g ?? ''}`;
	return g == '' || match(g, /^(224\.0\.0\.|ff0[0-9a-f]:)/i) != null || g == '239.255.255.250' || g == '239.255.255.253';
}

/* plain IPv4 address (no names: nothing to resolve at boot) */
function valid_ip(a) {
	let m = match(`${a ?? ''}`, /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/);
	return !!m && +m[1] <= 255 && +m[2] <= 255 && +m[3] <= 255 && +m[4] <= 255;
}

function write_atomic(path, data) {
	let tmp = path + '.tmp';
	if (fs.writefile(tmp, data) == null) return false;
	return fs.rename(tmp, path);
}

function round(v, digits) {
	if (v == null) return null;
	let m = 10 ** (digits ?? 0);
	return int(v * m + (v >= 0 ? 0.5 : -0.5)) / (m * 1.0);
}

function absf(v) { return (v < 0) ? -v : v; }

/* send a signal to processes; one shell for all of them. uloop.process()
 * handles have no kill() (only pid() and delete()), so this is the way to
 * stop a child */
function kill_pids(sig, pids) {
	let l = filter(map(pids ?? [], (p) => int(p)), (p) => p > 1);
	if (length(l))
		system([ '/bin/sh', '-c', `kill -${sig} ${join(' ', l)} 2>/dev/null` ]);
}

function worst(a, b) {
	return (LEVEL[b] > LEVEL[a]) ? b : a;
}

export { RUNDIR, NO_UBUS, VARDIR, SYSNET, ROUTE, PROC, find_bin, FETCH, LOGREAD, RRDTOOL, BRIDGE, PROXIES, TSMON, MTR, TRACEROUTE, TRACEROUTE6, TIMEOUT, STAT_KEYS, LEVEL, now, mono, num, bool, aslist, valid_host, valid_dev, valid_group, valid_ip, mc_ignored, write_atomic, round, absf, kill_pids, worst, ETHTOOL };
