'use strict';

/* luci-app-isp-tester: notifications (see ../collector.uc); init(ctx) gives it cfg and the host name */

import * as uloop from 'uloop';
import { FETCH, VARDIR, now } from './common.uc';
import { urlenc } from './parsers.uc';
import { tstamp, MSG, event_msg } from './messages.uc';
import * as fs from 'fs';

let C = null;
let notif = { pending: [], cut: 0, last: 0, busy: false, force: false, last_ok: null, last_fail: null, last_err: null, open: {} };

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

/*
 * The address holds the secret (the Telegram bot token, the ntfy topic):
 * given to uclient-fetch it stood in its command line, which every process
 * on the router can read (ps, /proc/<pid>/cmdline). With the uclient module
 * of ucode (ucode-mod-uclient) the request is made inside the collector,
 * so it appears nowhere. Without the module - or when it does not work as
 * expected (an HTTP error from the server on its first try, an exception) -
 * uclient-fetch is used as before, with the body in a file (--post-file).
 */
const CA_FILE = '/etc/ssl/certs/ca-certificates.crt';
let ucl = { mod: null, off: !!getenv('ISP_TESTER_CONFIG'), proven: false };

function ucl_mod() {
	if (ucl.off) return null;
	if (ucl.mod == null) {
		try { ucl.mod = require('uclient'); }
		catch (e) { ucl.off = true; return null; }
	}
	return ucl.mod;
}

/* POST over the uclient module; done(ok, err) once. false: not started */
function post_ucl(url, body, ctype, done) {
	let U = ucl_mod();
	if (!U) return false;
	let cl = null, timer = null, status = null, over = false;
	let end = (ok, err) => {
		if (over) return;
		over = true;
		timer?.cancel();
		/* freed outside its own callback */
		ucl.free_t = uloop.timer(1, () => { ucl.free_t = null; try { cl?.free(); } catch (e) {} });
		done(ok, err, status);
	};
	try {
		cl = U.new(url, null, {
			header_done: () => { try { status = cl.status()?.status; } catch (e) {} },
			/* the answer is not needed, but it must be read */
			data_read: () => {
				try { for (let i = 0; i < 64; i++) if (!length(cl.read() ?? '')) break; }
				catch (e) {}
			},
			data_eof: () => end(status >= 200 && status < 300, status),
			/* the module passes the callback object first, then the value */
			error: (cb, code) => end(false, `uclient ${code}`)
		});
		if (!cl) return false;
		if (substr(url, 0, 6) == 'https:' &&
		    !cl.ssl_init({ ca_files: [ CA_FILE ], verify: true })) { cl.free(); return false; }
		cl.set_timeout(15000);
		if (!cl.connect() || !cl.request('POST', { headers: { 'Content-Type': ctype }, post_data: body })) {
			cl.free();
			return false;
		}
	}
	catch (e) {
		try { cl?.free(); } catch (e2) {}
		ucl.off = true;
		return false;
	}
	timer = uloop.timer(30000, () => end(false, 'timeout'));
	return true;
}

/* POST with uclient-fetch; the body (chat id, messages) in a file, not in
 * the command line */
function post_fetch(url, body, ctype, done) {
	if (!FETCH) return false;
	let f = `${VARDIR}/notify.body`;
	if (fs.writefile(f, body) == null) return false;
	/* (only root may read it; chmod is missing in older ucode builds) */
	try { fs.chmod(f, 0600); } catch (e) {}
	let args = [ '-q', '-T', '15', '-O', '/dev/null', `--post-file=${f}`, url ];
	/* without it the receiver gets JSON as a form-encoded body */
	if (ctype != 'application/x-www-form-urlencoded') splice(args, 5, 0, `--header=Content-Type: ${ctype}`);
	let proc = uloop.process(FETCH, args, null, (code) => {
		fs.unlink(f);
		done(code == 0, code, null);
	});
	if (!proc) { fs.unlink(f); return false; }
	return true;
}

function notify_flush(force) {
	let n = C.cfg.notify;
	/* a test asked for while another message was on its way: sent as soon
	 * as that one is done, not after the whole cooldown (5 min by default,
	 * while the settings page said "within one interval") */
	force = force || notif.force;
	if (!n.enabled || notif.busy || !length(notif.pending) || (!FETCH && !ucl_mod())) return;
	if (!force && now() - notif.last < n.cooldown && now() >= notif.last) return;

	let count = length(notif.pending);
	let text = `ISP Tester (${C.hostname})\n` + join('\n', notif.pending);
	let url, body, ctype = 'application/x-www-form-urlencoded';

	if (n.service == 'telegram') {
		if (!n.token || !n.chat_id) return;
		url = `https://api.telegram.org/bot${n.token}/sendMessage`;
		body = `chat_id=${urlenc(n.chat_id)}&text=${urlenc(text)}`;
	}
	else if (n.service == 'webhook') {
		url = n.url;
		body = sprintf('%J', { text, host: C.hostname, events: notif.pending });
		ctype = 'application/json';
	}
	else {
		/* ntfy takes the body as the message, whatever its type: the form
		 * type uclient-fetch sends anyway, so no --header is needed */
		url = n.url;
		body = text;
	}
	if (!match(url ?? '', /^https?:\/\/[^ \t\n]+$/)) return;

	notif.busy = true;
	notif.force = false;
	notif.last = now();
	let cut0 = notif.cut, via = null;
	/* declared first: the function passes itself on (retry with
	 * uclient-fetch), and ucode refuses a declaration used inside its own
	 * initializer - the whole collector did not compile */
	let done;
	done = (ok, err, status) => {
		/* the module answered, but the server refused what it sent (an
		 * older module without post_data sends no body): uclient-fetch
		 * from now on, and at once */
		if (!ok && via == 'uclient' && !ucl.proven && status >= 400 && status < 500 && FETCH) {
			ucl.off = true;
			via = 'fetch';
			if (post_fetch(url, body, ctype, done)) return;
		}
		notif.busy = false;
		if (ok) {
			if (via == 'uclient') ucl.proven = true;
			notif.pending = slice(notif.pending, max(0, count - (notif.cut - cut0)));
			notif.last_ok = now();
			notif.via = via;
		}
		else {
			notif.last_fail = now();
			notif.last_err = err;
			/* no Internet (the usual reason): retry in a minute (or after the
			 * cooldown, when it is shorter; a time "in the future" would let
			 * the next tick send at once) */
			notif.last = now() - max(0, n.cooldown - 60);
		}
	};
	via = 'uclient';
	if (post_ucl(url, body, ctype, done)) return;
	via = 'fetch';
	if (post_fetch(url, body, ctype, done)) return;
	notif.busy = false;
}

/* request from the web UI: send a test message */
function notify_test() {
	let f = `${VARDIR}/notify_test`;
	if (!fs.stat(f)) return;
	fs.unlink(f);
	/* notifications off: do not leave a test message queued for later */
	if (!C.cfg.notify.enabled) return;
	push(notif.pending, (MSG[C.cfg.notify.lang] ?? MSG.en).test);
	notif.force = true;
	notify_flush(true);
}

/* for state.json */
function notify_status() {
	let n = C.cfg.notify;
	return n.enabled ? { service: n.service, pending: length(notif.pending),
		last_ok: notif.last_ok, last_fail: notif.last_fail, last_err: notif.last_err, via: notif.via,
		fetch: FETCH != null || ucl_mod() != null } : null;
}

export { RECOVERY, notify_init, notify_queue, notify_flush, notify_test, notify_status };
