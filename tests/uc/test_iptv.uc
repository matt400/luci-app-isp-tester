'use strict';

/* IPTV module: decoder DHCP (lib/iptv.uc) */

import { eq, ok, done } from './t.uc';
import { iptv_init, iptv_update, iptv, dhcp_seen, dhl, igmp, tsq, chn_now, chn_learn, min_note, svc_stream, ZAP_MAX } from '../../root/usr/share/isp-tester/lib/iptv.uc';

let log = [], evs = [];
const CFG = { interval: 10, iptv: { dhcp: true, dec_labels: {}, channels: {}, min_kbps: 500, stall_after: 2, idle_after: 60,
	off_after: 15, dip_pct: 40, svc_kbps: 3000, igmp: false, vlan: null, sample_interval: 1 } };
iptv_init({
	cfg: CFG,
	emit: (lvl, area, src, type, d, ts) => { push(log, type); push(evs, { ts: ts ?? time(), lvl, area, src, type, d: d ?? {} }); },
	recent_level: () => 'ok', events: () => evs, save_events: () => null, querier_none: () => false, querier_query: () => null, querier_router: () => false
});

const MAC = 'aa:bb:cc:dd:ee:01', T0 = 1700000000, LEASE = 3600;
function ack(t) { dhcp_seen({ t, type: 5, mac: MAC, ip: '10.0.0.5', lease: LEASE }, 'vlan'); }
function offer(t) { dhcp_seen({ t, type: 2, mac: MAC }, 'vlan'); }

/* first lease */
offer(T0); ack(T0 + 1);
eq('first lease logged', log, [ 'dhcp_lease' ]);

/* the decoder lets the lease run out and asks anew, on the hour: no restart */
for (let i = 1; i <= 3; i++) { offer(T0 + 1 + i * LEASE); ack(T0 + 2 + i * LEASE); }
eq('hourly DISCOVER at the lease end is a renewal, not dhcp_new', log, [ 'dhcp_lease' ]);
eq('counted as renewals', dhl.mac[MAC].renew, 3);
ok('no boot proof for it', dhl.mac[MAC].boot_t == T0);

/* a real restart in the middle of the lease */
let t = T0 + 2 + 3 * LEASE + 1200;
offer(t); ack(t + 1);
eq('a DISCOVER off the schedule is a start', log, [ 'dhcp_lease', 'dhcp_new' ]);
ok('with boot proof', dhl.mac[MAC].boot_t >= t && dhl.mac[MAC].boot_t <= t + 1);

/* ---- the decoders' nightly data fetch (~04:27): 1.5-2.4 Mbit/s with pauses */
function feed(seq) {
	let w0 = time() - 2000;
	for (let i = 0; i < length(seq); i++)
		iptv_update(seq[i], i + 1, w0 + i + 1, i, w0 + i);
}
let night = [];
for (let r = 0; r < 4; r++) {
	for (let i = 0; i < 25; i++) push(night, 1500 + (i % 5) * 200);
	for (let i = 0; i < 8; i++) push(night, 10);
}
log = [];
feed(night);
eq('data fetch: no freeze, logged as one start', filter(log, (x) => x != 'stream_dip'), [ 'stream_start' ]);
ok('data fetch: no dip warning', index(log, 'stream_dip') < 0);
ok('data fetch: never "stalled"', iptv.state != 'stalled');

/* a TV channel (11 Mbit/s) that stops is still a freeze */
iptv.state = 'idle'; iptv.svc_until = 0; iptv.svc_end = null;
let tv = [];
for (let i = 0; i < 40; i++) push(tv, 11400);
for (let i = 0; i < 8; i++) push(tv, 10);
for (let i = 0; i < 10; i++) push(tv, 11400);
log = [];
feed(tv);
eq('TV channel: freeze logged', log, [ 'stream_start', 'stream_stall', 'stream_resume' ]);

/* ---- the channel in events and the CSV (chn_now calls chn_current) */
igmp.groups = [ '239.1.1.1' ];
CFG.iptv.channels = { '239.1.1.1': 'Test TV' };
eq('the only joined group is the channel', chn_now(), 'Test TV (239.1.1.1)');
igmp.groups = [];
eq('nobody watches: no channel', chn_now(), null);


/* ---- channel changes (real export 26.11: zapping TVN -> CANAL+ -> ... -> FightBox) */
const A = '239.9.0.1', B = '239.9.0.2', S = '224.9.9.9', X = '239.9.0.3';
CFG.iptv.channels = { [A]: 'Food', [B]: 'HBO' };
CFG.iptv.igmp = true;

function reset() {
	iptv.state = 'idle'; iptv.svc_until = 0; iptv.svc_end = null; iptv.svc_t1 = null; iptv.svc_q = false;
	iptv.watch = null; iptv.zap = false; iptv.stall_zap = false; iptv.typ = null; iptv.sess_named = false;
	igmp.hist = []; igmp.groups = [ A, S ]; igmp.joined = { [A]: 0, [S]: 0 }; igmp.seen = true;
	tsq.flow = null; tsq.proc = null;
	log = []; evs = [];
}
/* steps: [ kbps, fn(i, w) ] - fn changes IGMP / what flows before the step */
function run(steps) {
	let w0 = time() - 4000;
	for (let i = 0; i < length(steps); i++) {
		let w = w0 + i + 1;
		if (steps[i][1]) steps[i][1](i, w);
		iptv_update(steps[i][0], i + 1, w, i, w - 1);
	}
}
function flows(g, kbps) { tsq.flow = { ts: time(), groups: g ? [ { grp: g, kbps, idle: 0 } ] : [] }; }
function zap_to(to, from) {
	return (i, w) => {
		push(igmp.hist, { ts: w, before: igmp.groups, after: sort([ to, S ]) });
		igmp.groups = sort([ to, S ]); igmp.joined[to] = w; delete igmp.joined[from];
		flows(null);
	};
}

/* a channel change with 3 s of no data: no freeze at all */
reset();
let st = [];
for (let i = 0; i < 20; i++) push(st, [ 10000, i == 0 ? () => flows(A, 10000) : null ]);
push(st, [ 10, zap_to(B, A) ]);
for (let i = 0; i < 2; i++) push(st, [ 10 ]);
for (let i = 0; i < 10; i++) push(st, [ 8000, i == 0 ? () => flows(B, 8000) : null ]);
run(st);
eq('zap: no stall, no resume', log, [ 'stream_start' ]);
eq('zap: still playing', iptv.state, 'playing');
eq('zap: the channel watched is the new one', iptv.watch, B);
eq('zap: the start names the channel', evs[0].d.ch, 'Food (' + A + ')');

/* the new channel does not start within ZAP_MAX: a stall, yellow, of the old channel */
reset();
st = [];
for (let i = 0; i < 20; i++) push(st, [ 10000, i == 0 ? () => flows(A, 10000) : null ]);
push(st, [ 10, zap_to(X, A) ]);
for (let i = 0; i < ZAP_MAX + 3; i++) push(st, [ 10 ]);
for (let i = 0; i < 5; i++) push(st, [ 8000, i == 0 ? () => flows(X, 8000) : null ]);
run(st);
eq('slow zap: stall and resume', log, [ 'stream_start', 'stream_stall', 'stream_resume' ]);
let stall = filter(evs, (e) => e.type == 'stream_stall')[0];
eq('slow zap: a warning, not an error', stall?.lvl, 'warn');
ok('slow zap: marked as such', stall?.d.zap == 1);
eq('slow zap: the channel that stopped', stall?.d.grp, A);

/* the same stop without a channel change: an error, as before */
reset();
st = [];
for (let i = 0; i < 20; i++) push(st, [ 10000, i == 0 ? () => flows(A, 10000) : null ]);
for (let i = 0; i < 8; i++) push(st, [ 10, i == 0 ? () => flows(null) : null ]);
for (let i = 0; i < 5; i++) push(st, [ 10000, i == 0 ? () => flows(A, 10000) : null ]);
run(st);
eq('freeze: stall and resume', log, [ 'stream_start', 'stream_stall', 'stream_resume' ]);
eq('freeze: an error', filter(evs, (e) => e.type == 'stream_stall')[0]?.lvl, 'err');
eq('freeze: named after the channel that stopped', filter(evs, (e) => e.type == 'stream_stall')[0]?.d.ch, 'Food (' + A + ')');

/* a named channel is no data fetch, also at a low bitrate (ramp-up, SD) */
reset();
iptv.state = 'playing'; iptv.sess_avg = 2000; iptv.watch = X; iptv.sess_named = true;
ok('named stream: not a data fetch', !svc_stream());
iptv.sess_named = false;
ok('unnamed low stream: a data fetch', svc_stream());

/* the fetch's entry has its own length when a channel starts right after it */
reset();
igmp.groups = [ S ]; igmp.joined = { [S]: 0 };
let night2 = [];
for (let r = 0; r < 2; r++) {
	for (let i = 0; i < 25; i++) push(night2, [ 1500 + (i % 5) * 200 ]);
	for (let i = 0; i < 20; i++) push(night2, [ 10, i == 0 ? (i2, w) => { igmp.hist = []; igmp.groups = []; } : null ]);
}
push(night2, [ 9000, (i, w) => { igmp.groups = [ A, S ]; igmp.joined[A] = w; flows(A, 9000); } ]);
run(night2);
let off = filter(evs, (e) => e.type == 'stream_off');
eq('fetch, then a channel: one fetch entry and the start', map(filter(evs, (e) => e.type != 'stream_dip'), (e) => e.type), [ 'stream_start', 'stream_off', 'stream_start' ]);
ok('fetch entry: its length, not 1 s', off[0]?.d.dur >= 60);

/* the minimum counts only seconds the stream played */
reset();
iptv.state = 'idle'; iptv.low_m = null; iptv.tmin = null;
let a = { min: null };
min_note(a, 14);
eq('idle seconds are no minimum', a.min, null);
iptv.state = 'playing';
min_note(a, 3000);
eq('playing seconds are', a.min, 3000);
iptv.low_m = 5; min_note(a, 9);
eq('a stop not decided yet waits', a.min, 3000);

/* a name learned after the event (SDT 1-3 s after the switch) goes into it */
reset();
evs = [ { ts: time(), area: 'iptv', type: 'stream_resume', d: { grp: X, ch: X } } ];
chn_learn([ { grp: X, svc: { name: 'TVP Sport HD', sid: 1 } } ]);
eq('the event gets the name', evs[0].d.ch, 'TVP Sport HD (' + X + ')');

done('test_iptv');
