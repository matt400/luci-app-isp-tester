'use strict';

/* IPTV module: decoder DHCP (lib/iptv.uc) */

import { eq, ok, done } from './t.uc';
import { iptv_init, iptv_update, iptv, dhcp_seen, dhl } from '../../root/usr/share/isp-tester/lib/iptv.uc';

let log = [];
const CFG = { interval: 10, iptv: { dhcp: true, dec_labels: {}, channels: {}, min_kbps: 500, stall_after: 2, idle_after: 60,
	off_after: 15, dip_pct: 40, svc_kbps: 3000, igmp: false, vlan: null, sample_interval: 1 } };
iptv_init({
	cfg: CFG,
	emit: (lvl, area, src, type, d) => push(log, type),
	recent_level: () => 'ok', events: () => [], querier_none: () => false, querier_query: () => null, querier_router: () => false
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

done('test_iptv');
