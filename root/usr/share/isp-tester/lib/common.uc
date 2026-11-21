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

/*
 * "Is the light from the line weaker?": when the WAN goes through an SFP
 * module (or an ONT in an SFP cage) the router can read the module's own
 * measurements - `ethtool -m <port>`: RX / TX power (dBm), temperature,
 * voltage, laser current and the module's alarm flags. A fall in the received
 * power is a hard proof of a fault in the line (fibre, connector, splitter,
 * the ISP's side) that no ping can give. Read every sfp_interval s (the
 * EEPROM is slow); without a module (ethtool says so) it is asked again
 * every 10 minutes and nothing is shown. Only reads.
 *   no light (RX at the noise floor)            -> sfp_los
 *   RX sfp_drop_db below its usual level, or below the module's low-power
 *   warning / sfp_rx_min                         -> sfp_rx_drop
 *   any other alarm/warning flag of the module  -> sfp_alarm
 *   the module stopped answering                 -> sfp_gone
 */
const ETHTOOL = find_bin('ISP_TESTER_ETHTOOL', [ '/usr/sbin/ethtool', '/sbin/ethtool', '/usr/bin/ethtool' ]);

export { RUNDIR, NO_UBUS, VARDIR, SYSNET, ROUTE, PROC, find_bin, FETCH, LOGREAD, RRDTOOL, BRIDGE, PROXIES, TSMON, MTR, TRACEROUTE, TRACEROUTE6, TIMEOUT, STAT_KEYS, LEVEL, now, mono, num, bool, aslist, valid_host, valid_dev, valid_group, valid_ip, write_atomic, round, absf, kill_pids, worst, ETHTOOL };
