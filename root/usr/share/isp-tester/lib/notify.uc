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
 * port coming up or a target recovering from an unsent warning stays quiet */
const RECOVERY = { wan_up: true, stream_resume: true, stream_lost: true, stream_off: true, link_up: true,
	wan_if_up: true, proxy_up: true, target_ok: true, dev_present: true, peer_back: true,
	bufferbloat_ok: true, v6_up: true, v6_if_up: true, v6_pd_back: true, v6_route_back: true, dns_ok: true, dns_server_ok: true,
	igmp_noquery_ok: true, sfp_los_ok: true, sfp_rx_drop_ok: true, sfp_alarm_ok: true, sfp_gone_ok: true,
	cpu_high_ok: true, mem_low_ok: true, conntrack_full_ok: true };

function notify_queue(e) {
	let n = C.cfg.notify;
	if (!n.enabled) return;
	/* during maintenance (the user works on the network): nothing */
	if (e.m) return;
	let key = `${e.host ?? ''}|${e.area}|${e.src}`;
	let want;
	if (RECOVERY[e.type]) {
		want = notif.open[key] == true;
		delete notif.open[key];
	}
	else {
		want = (e.lvl == 'err') || (e.lvl == 'warn' && n.min_level == 'warn');
		if (want) notif.open[key] = true;
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

export { notify_init, notify_queue, notify_flush, notify_test, notify_status };
