'use strict';

/* validators and helpers (lib/common.uc) and the messages (lib/messages.uc) */

import { eq, ok, done } from './t.uc';
import { num, bool, aslist, valid_host, valid_dev, valid_group, valid_ip, mc_ignored, round, worst }
	from '../../root/usr/share/isp-tester/lib/common.uc';
import { MSG, GAP_WHY_EN, GAP_WHY_PL, MARK_EN, MARK_PL, dur_txt, event_text }
	from '../../root/usr/share/isp-tester/lib/messages.uc';

/* ---- num / bool / aslist */
eq('num', num('12.5', 0), 12.5);
eq('num empty -> default', num('', 7), 7);
eq('num null -> default', num(null, 7), 7);
eq('num garbage -> default', num('x', 7), 7);
eq('num zero is a value', num('0', 7), 0);
eq('bool 1/on/true/yes', [ bool('1'), bool('on'), bool('true'), bool('yes'), bool(true), bool(1) ], [ true, true, true, true, true, true ]);
eq('bool 0/off', [ bool('0'), bool('off'), bool('no') ], [ false, false, false ]);
eq('bool empty -> default', bool('', true), true);
eq('aslist', [ aslist(null), aslist('a'), aslist([ 'a', 'b' ]) ], [ [], [ 'a' ], [ 'a', 'b' ] ]);

/* ---- what may go into a command line */
ok('host name', valid_host('example.com'));
ok('host ipv6', valid_host('2001:db8::1'));
ok('host no shell chars', !valid_host('a.com;reboot'));
ok('host no spaces', !valid_host('a b'));
ok('host not empty', !valid_host(''));
ok('host not a number', !valid_host(5));
ok('dev', valid_dev('lan1') && valid_dev('br-lan.236') && valid_dev('eth0@if3'));
ok('dev no slash', !valid_dev('../etc'));
ok('dev no $()', !valid_dev('$(id)'));
ok('dev length', !valid_dev('a' + sprintf('%032d', 0)));
ok('group', valid_group('239.1.1.1') && valid_group('224.0.0.1'));
ok('group not unicast', !valid_group('192.0.2.1'));
ok('group not 240+', !valid_group('240.0.0.1'));
ok('group octets', !valid_group('239.256.1.1'));
ok('group no suffix', !valid_group('239.1.1.1 or 1'));
ok('ip', valid_ip('192.0.2.1'));
ok('ip octets', !valid_ip('192.0.2.256'));
ok('ip no names', !valid_ip('router.lan'));

/* ---- groups that are no channel */
ok('ignored link-local', mc_ignored('224.0.0.22'));
ok('ignored ssdp', mc_ignored('239.255.255.250'));
ok('ignored slp', mc_ignored('239.255.255.253'));
ok('ignored ipv6 link', mc_ignored('ff02::fb'));
ok('ignored empty', mc_ignored(null));
ok('channel kept', !mc_ignored('239.1.1.1'));

/* ---- round / worst */
eq('round', round(2.345, 2), 2.35);
eq('round negative', round(-2.5, 0), -3);
eq('round null', round(null, 1), null);
eq('worst', [ worst('ok', 'warn'), worst('err', 'warn'), worst('info', 'ok') ], [ 'warn', 'err', 'info' ]);

/* ---- messages: both languages say the same things */
function specs(f) {
	let out = [];
	for (let m in (match(f, /%[-+ 0#]*[0-9]*(\.[0-9]+)?[dsfJ%]/g) ?? [])) push(out, m[0]);
	return out;
}
let en = MSG.en, pl = MSG.pl;
eq('MSG pl has every en key', filter(keys(en), (k) => !(k in pl)), []);
eq('MSG en has every pl key', filter(keys(pl), (k) => !(k in en)), []);
let bad = [];
for (let k in en)
	if (k in pl && sprintf('%J', specs(en[k])) != sprintf('%J', specs(pl[k])))
		push(bad, `${k}: ${join(' ', specs(en[k]))} / ${join(' ', specs(pl[k]))}`);
eq('MSG same format specifiers in en and pl', bad, []);
eq('GAP_WHY keys', sort(keys(GAP_WHY_PL)), sort(keys(GAP_WHY_EN)));
eq('MARK keys', sort(keys(MARK_PL)), sort(keys(MARK_EN)));

/* every message can be built from an event without data (no crash, no "%s" left) */
let broken = [];
for (let lang in [ 'en', 'pl' ])
	for (let k in MSG[lang]) {
		let s;
		try { s = event_text({ type: k, area: 'wan', src: 'x', d: {} }, lang); }
		catch (e) { push(broken, `${lang}.${k}: ${e}`); continue; }
		if (type(s) != 'string' || s == '') push(broken, `${lang}.${k}: empty`);
	}
eq('event_text works for every type', broken, []);

/* ---- durations */
eq('dur s', dur_txt(59), '59s');
eq('dur m', dur_txt(61), '1m01s');
eq('dur h', dur_txt(3725), '1h02m');
eq('dur null', dur_txt(null), '0s');

done('test_common');
