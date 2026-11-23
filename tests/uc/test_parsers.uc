'use strict';

/* parsers of command output and log lines (lib/parsers.uc) */

import { eq, ok, done } from './t.uc';
import { urlenc, trace_parse_mtr, trace_parse_tr, trace_judge, median, sfp_dbm, sfp_parse, sfp_median,
	cd_parse_val, parse_log_line, uniq_list } from '../../root/usr/share/isp-tester/lib/parsers.uc';

/* ---- urlenc */
eq('urlenc plain', urlenc('abc-XYZ_09.~'), 'abc-XYZ_09.~');
eq('urlenc space/specials', urlenc('a b&c=d/ł'), 'a%20b%26c%3Dd%2F%C5%82');
eq('urlenc empty', urlenc(''), '');

/* ---- mtr -r */
let mtr = `Start: 2026-11-23T10:00:00+0100
HOST: router                      Loss%   Snt   Last   Avg  Best  Wrst StDev
  1.|-- 192.0.2.1                 0.0%    10    1.1   1.2   1.0   1.5   0.1
  2.|-- ???                      100.0    10    0.0   0.0   0.0   0.0   0.0
  3.|-- 198.51.100.7             30.0%    10    9.9  10.4   9.1  12.0   0.8
  4.|-- 203.0.113.9              30.0%    10   15.1  15.3  14.9  16.0   0.3
`;
let hops = trace_parse_mtr(mtr);
eq('mtr hop count', length(hops), 4);
eq('mtr hop 1', hops[0], { n: 1, ip: '192.0.2.1', loss: 0, avg: 1.2 });
eq('mtr unknown hop', hops[1], { n: 2, ip: null, loss: 100, avg: null });
eq('mtr hop 3', hops[2], { n: 3, ip: '198.51.100.7', loss: 30, avg: 10.4 });
eq('mtr null input', trace_parse_mtr(null), []);

/* ---- busybox traceroute */
let tr = ` 1  192.0.2.1  0.912 ms  0.801 ms  0.790 ms
 2  * * *
 3  198.51.100.7  10.1 ms  *  10.3 ms
traceroute: some note
`;
hops = trace_parse_tr(tr);
eq('tr hop count', length(hops), 3);
eq('tr hop 1', hops[0], { n: 1, ip: '192.0.2.1', loss: 0, avg: 0.8 });
eq('tr silent hop', hops[1], { n: 2, ip: null, loss: 100, avg: null });
eq('tr hop 3 one lost', hops[2], { n: 3, ip: '198.51.100.7', loss: 33, avg: 10.2 });
eq('tr ipv6 hop', trace_parse_tr(' 1  2001:db8::1  1.0 ms  1.0 ms  1.0 ms')[0].ip, '2001:db8::1');

/* ---- where the loss starts */
eq('judge empty', trace_judge([]).first_bad, null);
let j = trace_judge([
	{ n: 1, ip: '192.0.2.1', loss: 0 },
	{ n: 2, ip: null, loss: 100 },
	{ n: 3, ip: '198.51.100.7', loss: 30 },
	{ n: 4, ip: '203.0.113.9', loss: 30 }
]);
eq('judge first bad skips the silent hop', [ j.first_bad, j.bad_ip ], [ 3, '198.51.100.7' ]);
eq('judge last good', [ j.last_good, j.good_ip ], [ 1, '192.0.2.1' ]);
eq('judge dest loss', j.dest_loss, 30);
j = trace_judge([ { n: 1, ip: '192.0.2.1', loss: 0 }, { n: 2, ip: '198.51.100.7', loss: 60 }, { n: 3, ip: '203.0.113.9', loss: 0 } ]);
eq('judge loss over at the end: nothing to blame', j.first_bad, null);
j = trace_judge([ { n: 1, ip: '192.0.2.1', loss: 50 }, { n: 2, ip: '203.0.113.9', loss: 50 } ]);
eq('judge loss from the first hop', [ j.first_bad, j.last_good ], [ 1, null ]);

/* ---- median */
eq('median empty', median([]), null);
eq('median odd', median([ 3, 1, 2 ]), 2);
eq('median even is not integer division', median([ 1, 2 ]), 1.5);
let a = [ 3, 1, 2 ];
median(a);
eq('median does not sort the input', a, [ 3, 1, 2 ]);
eq('sfp_median rounds', sfp_median([ -2.6666, -2.3333 ]), -2.5);

/* ---- ethtool -m */
eq('dbm', sfp_dbm('0.5412 mW / -2.67 dBm'), -2.67);
eq('dbm -inf', sfp_dbm('0.0000 mW / -inf dBm'), null);
let s = sfp_parse(`	Identifier                                : 0x03 (SFP)
	Laser output power                        : 1.1220 mW / 0.50 dBm
	Receiver signal average optical power     : 0.0501 mW / -13.00 dBm
	Module temperature                        : 45.50 degrees C / 113.90 degrees F
	Module voltage                            : 3.2800 V
	Laser bias current                        : 12.300 mA
	Laser rx power low alarm                  : Off
	Laser rx power low warning                : On
`);
eq('sfp values', [ s.tx, s.rx, s.temp, s.vcc, s.bias, s.has_rx ], [ 0.5, -13, 45.5, 3.28, 12.3, true ]);
eq('sfp flags only On', s.flags, [ 'Laser rx power low warning' ]);
eq('sfp no module data', sfp_parse('Cannot get module EEPROM information').has_rx, false);

/* ---- collectd values */
eq('cd number', cd_parse_val(' 12.5 '), 12.5);
eq('cd nan', cd_parse_val('nan'), null);
eq('cd -nan', cd_parse_val('-NaN'), null);
eq('cd U', cd_parse_val('U'), null);
eq('cd empty', cd_parse_val(null), null);
eq('cd garbage', cd_parse_val('abc'), null);

/* ---- logread lines (TZ=UTC in run.sh) */
let l = parse_log_line('Thu Nov 19 16:41:01 2026 daemon.notice pppd[1234]: PPP session is 7');
eq('log prog/pid/prio', [ l?.prog, l?.pid, l?.prio, l?.msg ], [ 'pppd', 1234, 'notice', 'PPP session is 7' ]);
eq('log ts', l?.ts, 1795106461);
l = parse_log_line('Mon Nov 23 09:05:07 2026 kern.warn kernel: [ 1234.567890] br-lan: port 2(lan2) entered disabled state');
eq('log kernel stamp removed', [ l?.prog, l?.pid, l?.msg ], [ 'kernel', null, 'br-lan: port 2(lan2) entered disabled state' ]);
l = parse_log_line('Mon Nov  2 09:05:07 2026 daemon.info dnsmasq-dhcp[3]: DHCPACK(br-lan)');
eq('log single-digit day', l?.prog, 'dnsmasq-dhcp');
eq('log not a log line', parse_log_line('garbage'), null);
eq('log bad month', parse_log_line('Mon Foo 23 09:05:07 2026 daemon.info x: y'), null);

/* ---- uniq_list */
eq('uniq keeps order, drops null', uniq_list([ 'b', 'a', null, 'b', 'c', 'a' ]), [ 'b', 'a', 'c' ]);

done('test_parsers');
