'use strict';

/* luci-app-isp-tester: notifications (see ../collector.uc); init(ctx) gives it cfg and the host name */

import * as uloop from 'uloop';
import { FETCH, VARDIR, now } from './common.uc';
import { urlenc } from './parsers.uc';
import { tstamp, MSG, event_msg } from './messages.uc';
import * as fs from 'fs';

let C = null;
let notif = { pending: [], cut: 0, last: 0, busy: false, last_ok: null, last_fail: null, last_err: null, open: {} };

function notify_init(ctx) { C = ctx; }

/* recoveries are sent too, so a "down" message is always followed by "back";
 * only when the fault itself was sent (same area + source), so e.g. a decoder
 * port coming up or a target recovering from an unsent warning stays quiet.
 * Each recovery lists the faults it ends: several faults share one source
 * (IPv6: the session, the prefix, the route and the ping; the SFP module:
 * no light, weak, alarm, gone), and one "open" flag per source let the end
 * of an unsent one ("IPv6 interface up again") take the place of the end of
 * the one that was sent ("IPv6 back"), which then never came. */
const RECOVERY = { wan_up: [ 'wan_down' ], stream_resume: [ 'stream_stall' ], stream_lost: [ 'stream_stall' ],
	stream_off: [ 'stream_stall' ], link_up: [ 'link_down' ], wan_if_up: [ 'wan_if_down' ], proxy_up: [ 'proxy_down' ],
	target_ok: [ 'target_fail', 'target_degraded' ], dev_present: [ 'dev_missing' ], peer_back: [ 'peer_lost' ],
	bufferbloat_ok: [ 'bufferbloat' ], v6_up: [ 'v6_down' ], v6_if_up: [ 'v6_if_down' ], v6_pd_back: [ 'v6_pd_lost' ],
	v6_route_back: [ 'v6_no_route' ], dns_ok: [ 'dns_fail' ], dns_server_ok: [ 'dns_server_bad' ],
	igmp_noquery_ok: [ 'igmp_noquery' ], sfp_los_ok: [ 'sfp_los' ], sfp_rx_drop_ok: [ 'sfp_rx_drop' ],
	sfp_alarm_ok: [ 'sfp_alarm' ], sfp_gone_ok: [ 'sfp_gone' ], cpu_high_ok: [ 'cpu_high' ], mem_low_ok: [ 'mem_low' ],
	conntrack_full_ok: [ 'conntrack_full' ], ntp_sync: [ 'ntp_unsync', 'ntp_off' ] };

function notify_queue(e) {
	let n = C.cfg.notify;
	if (!n.enabled) return;
	let key = `${e.host ?? ''}|${e.area}|${e.src}`;
	let ends = RECOVERY[e.type], want = false;
	if (ends) {
		for (let t in ends) {
			if (notif.open[`${key}|${t}`]) want = true;
			/* also during maintenance: the fault is over, so a later, unrelated
			 * recovery of the same source does not send a stray "back" */
			delete notif.open[`${key}|${t}`];
		}
	}
	/* during maintenance (the user works on the network): nothing is sent */
	if (e.m) return;
	if (!ends) {
		want = (e.lvl == 'err') || (e.lvl == 'warn' && n.min_level == 'warn');
		if (want) notif.open[`${key}|${e.type}`] = true;
	}
	if (!want) return;
	push(notif.pending, `${substr(tstamp(e.ts), 11)} ${event_msg(e, n.lang)}`);
	if (length(notif.pending) > 25) {
		/* the oldest are dropped; counted, so a send in progress removes the right ones */
		let cut = length(notif.pending) - 25;
		notif.pending = slice(notif.pending, cut);
		notif.cut += cut;
	}
}

function notify_flush(force) {
	let n = C.cfg.notify;
	if (!n.enabled || notif.busy || !length(notif.pending) || !FETCH) return;
	if (!force && now() - notif.last < n.cooldown && now() >= notif.last) return;

	let count = length(notif.pending);
	let text = `ISP Tester (${C.hostname})\n` + join('\n', notif.pending);
	let url, body, extra = [];

	if (n.service == 'telegram') {
		if (!n.token || !n.chat_id) return;
		url = `https://api.telegram.org/bot${n.token}/sendMessage`;
		body = `chat_id=${urlenc(n.chat_id)}&text=${urlenc(text)}`;
	}
	else if (n.service == 'webhook') {
		url = n.url;
		body = sprintf('%J', { text, host: C.hostname, events: notif.pending });
		/* without it the receiver gets the JSON as a form-encoded body */
		push(extra, '--header=Content-Type: application/json');
	}
	else {
		url = n.url;
		body = text;
	}
	if (!match(url ?? '', /^https?:\/\/[^ \t\n]+$/)) return;

	notif.busy = true;
	notif.last = now();
	let cut0 = notif.cut;
	let proc = uloop.process(FETCH, [ '-q', '-T', '15', '-O', '/dev/null', ...extra, `--post-data=${body}`, url ], null, (code) => {
		notif.busy = false;
		if (code == 0) {
			notif.pending = slice(notif.pending, max(0, count - (notif.cut - cut0)));
			notif.last_ok = now();
		}
		else {
			notif.last_fail = now();
			notif.last_err = code;
			/* no Internet (the usual reason): retry in a minute (or after the
			 * cooldown, when it is shorter; a time "in the future" would let
			 * the next tick send at once) */
			notif.last = now() - max(0, n.cooldown - 60);
		}
	});
	if (!proc) notif.busy = false;
}

/* request from the web UI: send a test message */
function notify_test() {
	let f = `${VARDIR}/notify_test`;
	if (!fs.stat(f)) return;
	fs.unlink(f);
	/* notifications off: do not leave a test message queued for later */
	if (!C.cfg.notify.enabled) return;
	push(notif.pending, (MSG[C.cfg.notify.lang] ?? MSG.en).test);
	notify_flush(true);
}

/* for state.json */
function notify_status() {
	let n = C.cfg.notify;
	return n.enabled ? { service: n.service, pending: length(notif.pending),
		last_ok: notif.last_ok, last_fail: notif.last_fail, last_err: notif.last_err, fetch: FETCH != null } : null;
}

export { RECOVERY, notify_init, notify_queue, notify_flush, notify_test, notify_status };
