'use strict';
'require view';
'require rpc';
'require poll';
'require fs';
'require ui';
'require dom';
'require isp_tester.diagnose as diagnose';

/*
 * Text children of E() become text nodes. LuCI's dom.append() puts a plain
 * string child in with innerHTML; here strings carry what came from outside:
 * channel names read from the IPTV stream (DVB SDT), lines of the system
 * log, notes, names reported by the second router. No child in this view is
 * meant as markup (the charts set innerHTML themselves).
 */
var E = (function(E0) {
	var txt = function(c) { return (typeof c === 'string' || typeof c === 'number') ? [ '' + c ] : c; };
	return function(type, attr, data) {
		if (arguments.length < 3 && (attr == null || typeof attr !== 'object' || Array.isArray(attr) || attr instanceof Node))
			return E0(type, txt(attr));
		return E0(type, attr, txt(data));
	};
})(window.E);

/* seconds the router's clock is ahead of this browser's: "for 5 min",
 * "updated 10 s ago" and the stale check are measured on the router's clock
 * (the times in the data are its own); a PC or router clock that is off by
 * a minute showed "MONITOR IS NOT WORKING" before */
var SKEW = 0;

function rnow() {
	return Date.now() / 1000 + SKEW;
}

var callStatusRpc = rpc.declare({
	object: 'luci.isp_tester',
	method: 'status',
	expect: { '': {} }
});

function callStatus() {
	return callStatusRpc().then(function(r) {
		if (r && typeof r.now === 'number') SKEW = r.now - Date.now() / 1000;
		return r;
	});
}

var callEvents = rpc.declare({
	object: 'luci.isp_tester',
	method: 'events',
	params: [ 'limit', 'area' ],
	expect: { '': {} }
});

var callClear = rpc.declare({
	object: 'luci.isp_tester',
	method: 'clear',
	expect: { result: false }
});

var callMark = rpc.declare({
	object: 'luci.isp_tester',
	method: 'mark',
	params: [ 'what', 'note', 'ago' ],
	expect: { '': {} }
});

var callMaint = rpc.declare({
	object: 'luci.isp_tester',
	method: 'maint',
	params: [ 'minutes', 'note' ],
	expect: { '': {} }
});

var callSetEnabled = rpc.declare({
	object: 'luci.isp_tester',
	method: 'set_enabled',
	params: [ 'enabled' ],
	expect: { '': {} }
});

var CSS = [
	'.ispt-banner{display:flex;align-items:center;gap:1em;padding:1em 1.2em;border-radius:8px;margin-bottom:1em;border:1px solid rgba(128,128,128,.25)}',
	'.ispt-banner .big{font-size:1.5em;font-weight:bold}',
	'.ispt-banner .sub{opacity:.8;margin-top:.2em}',
	'.ispt-banner .meta{margin-left:auto;text-align:right;font-size:.9em;opacity:.8}',
	'.ispt-bg-ok{background:rgba(46,157,79,.12);border-color:rgba(46,157,79,.5)}',
	'.ispt-bg-warn{background:rgba(224,161,0,.14);border-color:rgba(224,161,0,.6)}',
	'.ispt-bg-fail{background:rgba(214,69,65,.14);border-color:rgba(214,69,65,.6)}',
	'.ispt-bg-unknown{background:rgba(128,128,128,.1)}',
	'.ispt-dot{display:inline-block;width:.8em;height:.8em;border-radius:50%;vertical-align:middle;margin-right:.35em;flex:none}',
	'.ispt-dot.big{width:2em;height:2em;margin:0}',
	'.ispt-ok{background:#2e9d4f}.ispt-warn{background:#e0a100}.ispt-fail{background:#d64541}.ispt-unknown{background:#999}',
	'.ispt-dot.ispt-ok{background:url(data:image/svg+xml,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%20viewBox=%220%200%2024%2024%22%3E%3Cpath%20d=%22M4%2012.5l5%205L20%206.5%22%20fill=%22none%22%20stroke=%22%232e9d4f%22%20stroke-width=%223.5%22%20stroke-linecap=%22round%22%20stroke-linejoin=%22round%22/%3E%3C/svg%3E) center/contain no-repeat;border-radius:0}',
	'.ispt-dot.ispt-fail{background:url(data:image/svg+xml,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%20viewBox=%220%200%2024%2024%22%3E%3Cpath%20d=%22M6%206l12%2012M18%206L6%2018%22%20fill=%22none%22%20stroke=%22%23d64541%22%20stroke-width=%223.5%22%20stroke-linecap=%22round%22/%3E%3C/svg%3E) center/contain no-repeat;border-radius:0}',
	'.ispt-dot.ispt-warn{background:url(data:image/svg+xml,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%20viewBox=%220%200%2024%2024%22%3E%3Cpath%20d=%22M12%202.8L22.6%2021H1.4Z%22%20fill=%22%23e0a100%22%20stroke=%22%23e0a100%22%20stroke-width=%221.5%22%20stroke-linejoin=%22round%22/%3E%3Cpath%20d=%22M12%209.2v5.6%22%20stroke=%22%23fff%22%20stroke-width=%222.6%22%20stroke-linecap=%22round%22/%3E%3Ccircle%20cx=%2212%22%20cy=%2217.9%22%20r=%221.5%22%20fill=%22%23fff%22/%3E%3C/svg%3E) center/contain no-repeat;border-radius:0}',
	'.ispt-pulse{animation:ispt-pulse 1.2s ease-in-out infinite}',
	'@keyframes ispt-pulse{0%,100%{opacity:1}50%{opacity:.35}}',
	'.ispt-cards{display:flex;flex-wrap:wrap;gap:1em;margin-bottom:1em}',
	'.ispt-card{flex:1 1 300px;min-width:280px;border:1px solid rgba(128,128,128,.25);border-left-width:6px;border-radius:8px;padding:.8em 1em}',
	'.ispt-card.l-ok{border-left-color:#2e9d4f}.ispt-card.l-warn{border-left-color:#e0a100}.ispt-card.l-fail{border-left-color:#d64541}.ispt-card.l-unknown{border-left-color:#999}',
	'.ispt-card h3{margin:0 0 .5em 0;display:flex;align-items:center;gap:.4em;font-size:1.15em;border:0;padding:0}',
	'.ispt-card h3 .chip{margin-left:auto;font-size:.75em;padding:.15em .6em;border-radius:1em;color:#fff}',
	/* cards: status and the key numbers first, details below (folded) */
	'.ispt-card{display:flex;flex-direction:column;line-height:1.45}',
	'.ispt-kv{display:grid;grid-template-columns:minmax(7.5em,max-content) 1fr;gap:.35em 1em;font-size:.93em;align-items:baseline}',
	'.ispt-kv .k{opacity:.65}',
	'.ispt-kv>span:nth-child(2n){overflow-wrap:anywhere}',
	'.ispt-kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(5.6em,1fr));gap:.5em;margin:.1em 0 .8em 0}',
	'.ispt-kpi{border-radius:6px;padding:.4em .6em;background:rgba(128,128,128,.08);border-top:3px solid transparent;min-width:0}',
	'.ispt-kpi.l-warn{border-top-color:#e0a100}.ispt-kpi.l-fail{border-top-color:#d64541;background:rgba(214,69,65,.08)}',
	'.ispt-kpi .l{font-size:.75em;opacity:.7;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
	'.ispt-kpi .v{font-size:1.3em;font-weight:600;font-variant-numeric:tabular-nums;line-height:1.25;white-space:nowrap}',
	'.ispt-kpi .u{font-size:.65em;font-weight:normal;opacity:.7;margin-left:.2em}',
	'.ispt-sec{font-size:.8em;font-weight:600;opacity:.6;margin:.9em 0 .35em 0;padding-top:.5em;border-top:1px solid rgba(128,128,128,.18)}',
	'.ispt-more{margin-top:.6em}',
	'.ispt-more>summary{cursor:pointer;font-size:.9em;opacity:.8;padding:.2em 0;user-select:none}',
	'.ispt-more>summary:hover{opacity:1}',
	'.ispt-big{font-size:1.6em;font-weight:bold}',
	'.ispt-reasons{margin:0 0 .7em 0;padding:.4em .7em;list-style:none;font-size:.92em;border-radius:6px;background:rgba(214,69,65,.08);border:1px solid rgba(214,69,65,.3)}',
	'.ispt-reasons li{padding:.15em 0}',
	'.ispt-mini{width:100%;border-collapse:collapse;font-size:.92em}',
	'.ispt-mini td,.ispt-mini th{padding:.3em .35em;text-align:left;border-bottom:1px solid rgba(128,128,128,.15)}',
	'.ispt-mini th{opacity:.65;font-weight:normal;font-size:.9em;white-space:nowrap}',
	'.ispt-mini .n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}',
	'.ispt-mini .zero{opacity:.4}',
	'.ispt-mini .bad{color:#d64541;font-weight:600}',
	'.ispt-chart{margin:.3em 0 1em 0}',
	'.ispt-chart svg{width:100%;height:auto;display:block}',
	'.ispt-svgwrap{position:relative}',
	'.ispt-tip{position:absolute;top:4px;z-index:5;pointer-events:none;background:rgba(30,30,30,.92);color:#fff;padding:.35em .6em;border-radius:5px;font-size:.82em;white-space:nowrap;line-height:1.4}',
	'.ispt-nav{display:flex;flex-wrap:wrap;align-items:center;gap:.4em;margin-bottom:.6em}',
	'.ispt-nav .cbi-button.active{font-weight:bold;outline:2px solid currentColor}',
	'.ispt-nav .win{margin-left:.6em;font-weight:bold}',
	'.ispt-diag{display:flex;flex-wrap:wrap;gap:1em;border:1px solid rgba(128,128,128,.25);border-radius:8px;padding:.8em 1em;margin-bottom:1em}',
	'.ispt-diag .head{flex:0 0 260px}',
	'.ispt-diag .verdict{font-size:1.2em;font-weight:bold;margin:.2em 0}',
	'.ispt-diag .list{flex:1 1 380px;margin:0;padding:0;list-style:none}',
	'.ispt-diag .list li{display:flex;gap:.5em;align-items:baseline;padding:.25em 0;border-bottom:1px solid rgba(128,128,128,.12)}',
	'.ispt-side{flex:none;font-size:.75em;padding:.1em .5em;border-radius:1em;color:#fff;white-space:nowrap}',
	'.ispt-side.isp{background:#c0563b}.ispt-side.home{background:#3b6fc0}.ispt-side.edge{background:#8a6d3b}.ispt-side.info{background:#888}',
	'.ispt-scale{display:flex;height:.6em;border-radius:.3em;overflow:hidden;margin:.5em 0 .2em 0;background:rgba(128,128,128,.15)}',
	'.ispt-scale-lbl{display:flex;justify-content:space-between;font-size:.8em;opacity:.8}',
	'.ispt-tl tr.click{cursor:pointer}',
	'.ispt-tl tr.click:hover td{background:rgba(128,128,128,.08)}',
	'.ispt-chart .title{font-size:.9em;opacity:.8;margin-bottom:.2em}',
	'.ispt-legend{font-size:.85em;opacity:.85}',
	'.ispt-legend span{margin-right:1em;white-space:nowrap}',
	'.ispt-legend i{display:inline-block;width:1em;height:.25em;vertical-align:middle;margin-right:.3em}',
	'.ispt-filter{display:flex;gap:.4em;flex-wrap:wrap;margin-bottom:.6em}',
	'.ispt-filter .cbi-button.active{font-weight:bold;outline:2px solid currentColor}',
	'.ispt-tl{width:100%;border-collapse:collapse}',
	'.ispt-tl td{padding:.35em .5em;border-bottom:1px solid rgba(128,128,128,.15);vertical-align:top}',
	'.ispt-tl tr.lvl-err td:first-child{border-left:4px solid #d64541}',
	'.ispt-tl tr.lvl-warn td:first-child{border-left:4px solid #e0a100}',
	'.ispt-tl tr.lvl-info td:first-child{border-left:4px solid #6a8caf}',
	'.ispt-tl .when{white-space:nowrap;opacity:.8;font-size:.92em}',
	'.ispt-tl .area{white-space:nowrap;font-size:.85em;opacity:.75}',
	'.ispt-actions{display:flex;gap:.5em;flex-wrap:wrap;margin:1em 0}',
	'.ispt-muted{opacity:.6}',
	'.ispt-hours{display:flex;align-items:flex-end;gap:2px;height:90px;margin:.4em 0 .2em 0}',
	'.ispt-hours div{flex:1;background:#d4774a;min-height:1px;border-radius:2px 2px 0 0}',
	'.ispt-hours div.zero{background:rgba(128,128,128,.2)}',
	'.ispt-hours-lbl{display:flex;gap:2px;font-size:.75em;opacity:.7}',
	'.ispt-hours-lbl span{flex:1;text-align:center}',
	'.ispt-markbtn{font-weight:bold}',
	'.ispt-choices{display:flex;flex-wrap:wrap;gap:.5em;margin:.6em 0}',
	'.ispt-groups{font-family:monospace;font-size:.9em}',
	'.ispt-warn-text{color:#d64541;font-weight:bold}',
	'.ispt-host{display:inline-block;font-size:.8em;padding:0 .45em;margin-right:.35em;border-radius:1em;background:rgba(59,111,192,.18);white-space:nowrap}',
	'.ispt-bg-maint{background:rgba(59,130,196,.12);border-color:rgba(59,130,196,.5)}',
	'.ispt-tl tr.maint td{opacity:.55}',
	'.ispt-mtag{display:inline-block;font-size:.75em;padding:0 .45em;margin-left:.4em;border-radius:1em;background:rgba(59,130,196,.2);white-space:nowrap}'
].join('\n');

var COLORS = [ '#3b82c4', '#d4774a', '#7a59c0', '#2e9d8f', '#c44b8a', '#8a9a2e' ];

/* ------------------------------------------------------------ formatting */

function lvl(l) {
	return (l === 'ok' || l === 'warn' || l === 'fail') ? l : 'unknown';
}

function levelText(l) {
	switch (lvl(l)) {
	case 'ok':   return _('OK');
	case 'warn': return _('Warning');
	case 'fail': return _('Fault');
	default:     return _('No data');
	}
}

function dot(l, big) {
	return E('span', { 'class': 'ispt-dot ispt-' + lvl(l) + (big ? ' big' : '') + (l === 'fail' ? ' ispt-pulse' : '') });
}

function chip(l) {
	return E('span', { 'class': 'chip ispt-' + lvl(l) }, levelText(l));
}

function fmtDur(s) {
	s = Math.max(0, Math.round(s || 0));
	var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60), sec = s % 60;
	if (d > 0) return _('%d d %d h').format(d, h);
	if (h > 0) return _('%d h %d min').format(h, m);
	if (m > 0) return _('%d min %d s').format(m, sec);
	return _('%d s').format(sec);
}

/* the language set in LuCI (System → Language), which the theme writes into
 * <html lang>; dates and numbers follow it, not the browser's own language */
var LOCALE = (function() {
	var l = (document.documentElement.getAttribute('lang') || '').replace(/_/g, '-');
	if (!l || l === 'auto') return undefined;
	try { Intl.DateTimeFormat.supportedLocalesOf([ l ]); return l; } catch (e) { return undefined; }
})();

/* number with a fixed count of decimals, in the LuCI language (1,5 in Polish) */
function num(v, dec) {
	return Number(v).toLocaleString(LOCALE, { minimumFractionDigits: dec || 0, maximumFractionDigits: dec || 0 });
}

/* "2026-11-21 18:29:03": for CSV files and file names (machine-readable) */
function isoTime(ts) {
	var d = new Date(ts * 1000);
	var pad = function(n) { return (n < 10 ? '0' : '') + n; };
	return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' +
		pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
}

/* date and time for people, in the LuCI language */
function fmtTime(ts) {
	return new Date(ts * 1000).toLocaleString(LOCALE, { year: 'numeric', month: '2-digit', day: '2-digit',
		hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

/* shorter: day, month and time (with the year only when asked) */
function fmtShort(ts, year) {
	var o = { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' };
	if (year) o.year = 'numeric';
	return new Date(ts * 1000).toLocaleString(LOCALE, o);
}

/* time only today, day and time before */
function fmtWhen(ts) {
	var d = new Date(ts * 1000), n = new Date();
	return (d.toDateString() === n.toDateString()) ? hhmm(ts) : fmtShort(ts);
}

function fmtRate(kbps) {
	if (kbps == null) return '–';
	if (kbps >= 1000) return num(kbps / 1000, 1) + ' Mbit/s';
	return num(kbps) + ' kbit/s';
}

function fmtMs(v) {
	return (v == null) ? '–' : num(v, 1) + ' ms';
}

function fmtSpeed(mbit) {
	if (mbit == null || mbit < 0) return '–';
	return (mbit >= 1000) ? num(mbit / 1000, mbit % 1000 ? 1 : 0) + ' Gbit/s' : num(mbit) + ' Mbit/s';
}

/* [number, unit] of a bitrate, for the big numbers on the cards */
function rateParts(kbps) {
	if (kbps == null) return [ '–', '' ];
	return (kbps >= 1000) ? [ num(kbps / 1000, kbps >= 100000 ? 0 : 1), 'Mbit/s' ] : [ num(kbps), 'kbit/s' ];
}

/* one key number on a card: label, value, unit; level colours its top edge */
function kpi(label, value, unit, level, title) {
	return E('div', { 'class': 'ispt-kpi l-' + (level || 'ok'), 'title': title || label }, [
		E('div', { 'class': 'l' }, label),
		E('div', { 'class': 'v' }, [ value, unit ? E('span', { 'class': 'u' }, unit) : '' ])
	]);
}

/* a numeric table cell: right-aligned, a zero is greyed, a non-zero problem count is red */
function numCell(v, badIfNonZero) {
	if (v == null) return E('td', { 'class': 'n zero' }, '–');
	return E('td', { 'class': 'n' + (v === 0 ? ' zero' : (badIfNonZero ? ' bad' : '')) }, num(v));
}

/* does a key/value row show a problem? (such rows are never folded away) */
function isAlert(node) {
	if (!node || !node.nodeType) return false;
	if (node.classList && node.classList.contains('ispt-warn-text')) return true;
	return !!(node.querySelector && node.querySelector('.ispt-warn-text, .ispt-dot.ispt-fail, .ispt-dot.ispt-warn'));
}

function targetName(label, host) {
	if (label === 'gateway')
		return host ? _('ISP gateway (%s)').format(host) : _('ISP gateway');
	return label;
}

function areaName(a) {
	switch (a) {
	case 'wan':    return _('Internet');
	case 'iptv':   return _('IPTV');
	case 'ports':  return _('Ports');
	case 'system': return _('Router');
	case 'user':   return _('Your reports');
	default:       return a;
	}
}

function reasonText(r) {
	switch (r.c) {
	case 'dev_missing':     return _('Device %s does not exist').format(r.dev);
	case 'link_down':       return _('%s: link down for %s').format(r.dev, fmtDur(rnow() - r.since));
	case 'errors_now':      return _('%s: receiving errors right now').format(r.dev);
	case 'recent_events':   return r.dev
		? _('%s: problems in the last minutes (see timeline)').format(r.dev)
		: _('Problems in the last minutes (see timeline)');
	case 'target_fail':     return _('%s: no response (%d%% loss)').format(targetName(r.t), r.loss);
	case 'target_degraded': return (r.loss > 0)
		? _('%s: %d%% packet loss').format(targetName(r.t), r.loss)
		: (r.why === 'jitter')
		? _('%s: high jitter %s').format(targetName(r.t), fmtMs(r.jitter))
		: _('%s: high latency %s').format(targetName(r.t), fmtMs(r.rtt));
	case 'wan_down':        return _('Internet unreachable for %s').format(fmtDur(rnow() - r.since));
	case 'wan_if_down':     return _('WAN interface %s is down (no PPPoE/DHCP session) for %s').format(r.iface, fmtDur(rnow() - r.since));
	case 'no_ping_source':  return _('No ping data: enable the Ping plugin of luci-app-statistics (collectd) and add the ISP gateway and far hosts there.');
	case 'proxy_down':      return _('Multicast proxy %s is not running').format(r.name || '');
	case 'igmp_noquery':    return _('The operator has stopped sending IGMP queries');
	case 'querier_script_err': return _('The IGMP querier script cannot be written: %s (Settings → IPTV → IGMP querier)').format(r.err);
	case 'querier_diff':    return _('The bridge does not match the IGMP querier setting (%s) – a network restart without the script, or the script was changed by hand').format((r.what || []).join(', '));
	case 'querier_block_fail': return _('The ISP (%s) is still the IGMP querier although its queries should be blocked – the filter does not catch them').format(r.addr || '?');
	case 'querier_none':    return _('No IGMP querier on VLAN %d for %s – the channels expire').format(r.vlan, fmtDur(rnow() - r.since));
	case 'stream_stalled':  return _('Stream stopped %s ago').format(fmtDur(rnow() - r.since));
	case 'stream_dip':      return _('Bitrate is much lower than usual');
	case 'ts_errors':       return _('Picture errors in the incoming IPTV stream (see timeline)');
	case 'ts_no_helper':    return _('Picture quality needs the isp-tester-tsmon package: install it (see README).');
	case 'ts_helper_failed':
	case 'ts_helper_stalled': return _('Picture quality: the measuring helper (isp-tester-tsmon) stopped, it is restarted automatically – see the system log.');
	case 'ts_no_target':    return _('Picture quality: no IPTV interface to listen on (check the VLAN or device in Settings).');
	case 'ts_drops':        return _('The router was too busy to count every IPTV packet in the last minutes, so some errors may be its own (see the IPTV card).');
	case 'dec_fdb_failed':  return _('Decoders: cannot read the bridge MAC table (bridge fdb)');
	case 'bufferbloat_now': return _('Ping is up by %d ms while the link is %d%% full (%s) – bufferbloat, not an outage').format(r.add, r.load, r.dir === 'up' ? _('upload') : _('download'));
	case 'peer_offline':    return _('Router %s has not reported for %s (switched off, rebooting or the cable between the routers)').format(r.name, fmtDur(rnow() - r.since));
	case 'peer_level':      return _('Router %s reports: %s').format(r.name, levelText(r.lvl === 'fail' ? 'fail' : 'warn').toLowerCase());
	case 'vlan_vlan_not_found': return _('VLAN %d is not on any bridge port – check the VLAN number in Settings.').format(r.vlan);
	case 'vlan_no_bridge_tool': return _('The bridge command is missing: install ip-bridge.');
	case 'vlan_bridge_failed':
	case 'vlan_no_stats':   return _('Cannot read the counters of VLAN %d from the bridge.').format(r.vlan);
	case 'v6_down':         return _('IPv6 does not work for %s while IPv4 does – pages load slowly (the browser tries IPv6 first)').format(fmtDur(rnow() - r.since));
	case 'v6_if_down':      return _('IPv6 interface %s is down for %s').format(r.iface, fmtDur(rnow() - r.since));
	case 'v6_pd_lost':      return _('No IPv6 prefix from the ISP for %s – the home network has no IPv6').format(fmtDur(rnow() - r.since));
	case 'v6_no_route':     return _('No IPv6 default route for %s – the ISP stopped sending router advertisements').format(fmtDur(rnow() - r.since));
	case 'dns_fail_now':    return _('DNS: %d%% of the queries get no answer from the upstream server (for %s)').format(r.pct, fmtDur(rnow() - r.since));
	case 'dns_server_bad':  return _('DNS server %s retries or fails many queries').format(r.server);
	case 'sfp_los':         return _('No light from the line (SFP RX) for %s – the fibre, the connector or the ISP\'s side').format(fmtDur(rnow() - r.since));
	case 'sfp_weak':        return _('Optical signal weaker: RX %s dBm, usually %s dBm').format(r.rx, r.base != null ? r.base : '?');
	case 'sfp_alarm':       return _('SFP module alarm: %s').format((r.flags || []).join(', '));
	default:                return r.c;
	}
}

/* who asks on the IPTV VLAN (igmp_querier events) */
function querierName(who, addr, port) {
	switch (who) {
	case 'isp':    return _('the ISP') + (addr ? ' (' + addr + ')' : '');
	case 'other':  return _('another device') + ' (' + (addr || '?') + (port ? ', ' + port : '') + ')';
	case 'router': return _('this router');
	case 'wire':   return _('an unelected querier') + ' (' + (addr || '0.0.0.0') + ')';
	case 'off':    return _('snooping off');
	default:       return _('nobody');
	}
}

function eventText(e) {
	var d = e.d || {};
	switch (e.type) {
	case 'monitor_start':   return _('Monitoring started (every %d s)').format(d.interval);
	case 'cleared':         return _('Logs cleared');
	case 'dev_missing':     return _('Device %s disappeared').format(d.dev);
	case 'dev_present':     return _('Device %s is back').format(d.dev);
	case 'link_down':       return _('%s: link DOWN').format(d.dev);
	case 'link_up':         return _('%s: link up again at %s after %s').format(d.dev, fmtSpeed(d.speed), fmtDur(d.dur));
	case 'link_flap':       return _('%s: link flapped %d× between samples').format(d.dev, d.n);
	case 'speed_change':    return _('%s: link speed changed %s → %s').format(d.dev, fmtSpeed(d.from), fmtSpeed(d.to));
	case 'errors':          return _('%s: %d errors, %d CRC/frame errors').format(d.dev, d.err, d.crc);
	case 'drops':           return _('%s: %d dropped packets').format(d.dev, d.n);
	case 'target_degraded': return (d.loss > 0)
		? _('%s: %d%% packet loss (avg %s)').format(targetName(e.src, d.host), d.loss, fmtMs(d.rtt))
		: (d.why === 'jitter')
		? _('%s: high jitter %s (ping %s)').format(targetName(e.src, d.host), fmtMs(d.jitter), fmtMs(d.rtt))
		: _('%s: high latency %s').format(targetName(e.src, d.host), fmtMs(d.rtt));
	case 'target_fail':     return _('%s: not responding (%d%% loss)').format(targetName(e.src, d.host), d.loss);
	case 'target_ok':       return _('%s: OK again after %s (%s)').format(targetName(e.src, d.host), fmtDur(d.dur), fmtMs(d.rtt));
	case 'wan_down':        return _('INTERNET DOWN – no target responds');
	case 'wan_up':          return _('Internet back after %s').format(fmtDur(d.dur));
	case 'stream_start':    return _('IPTV stream started (%s)').format(fmtRate(d.kbps)) + chNote(d.ch);
	case 'stream_stall':    return _('IPTV STREAM STOPPED (was %s)').format(fmtRate(d.avg)) + chNote(d.ch);
	case 'stream_resume':   return _('IPTV stream resumed after %s').format(fmtDur(d.dur)) + igmpNote(d.igmp) + chNote(d.ch);
	case 'stream_off':      return _('IPTV stream ended: decoder switched off (no channel subscribed)');
	case 'stream_lost':     return ((d.groups > 0 && !d.left)
		? _('IPTV stream did not come back within %s (channel still subscribed: outage)').format(fmtDur(d.dur))
		: _('IPTV stream did not come back within %s (decoder off or outage)').format(fmtDur(d.dur))) + chNote(d.ch);
	case 'stream_dip':      return _('IPTV bitrate dropped to %s (usual %s)').format(fmtRate(d.kbps), fmtRate(d.avg)) + chNote(d.ch);
	case 'ts_errors':       return _('IPTV picture errors: %d lost-packet gaps (~%d packets) within %s, channel %s').format(d.cc + (d.tei || 0), d.lost, fmtDur(d.win),
			d.ch ? '%s (%s)'.format(d.ch, d.grp) : (d.grp || '?')) +
		(d.gap >= 100 ? ' · ' + _('longest pause %d ms').format(d.gap) : '');
	case 'wan_if_down':     return _('WAN interface %s DOWN (PPPoE/DHCP session lost)').format(d.iface);
	case 'wan_if_up':       return _('WAN interface %s up again after %s').format(d.iface, fmtDur(d.dur)) + (d.ip ? ' · ' + d.ip : '');
	case 'wan_reconnect':   return _('WAN session restarted (previous one lasted %s)').format(fmtDur(d.prev));
	case 'wan_ip_change':   return _('WAN address changed %s → %s').format(d.from, d.to);
	case 'igmp_noquery':    return _('No IGMP query from the operator for %s (usually every %s)').format(fmtDur(d.silent), fmtDur(d.expected)) +
		(d.router ? ' – ' + _('the router asks the decoders itself, the channels are not affected') : '');
	case 'igmp_noquery_ok': return _('IGMP queries from the operator again after %s').format(fmtDur(d.dur));
	case 'igmp_querier':    return _('IGMP querier of VLAN %s: %s → %s').format(d.vlan || '?', querierName(d.from, d.prev_addr, d.prev_port), querierName(d.to, d.addr, d.port)) +
		(d.from === 'isp' && d.to === 'router' && d.after ? ' · ' + _('no query from the ISP for %s').format(fmtDur(d.after)) : '') +
		(d.held ? ' · ' + _('the previous one asked for %s').format(fmtDur(d.held)) : '') +
		((d.to === 'isp' || d.to === 'other') && d.blocked ? ' · ' + _('its queries should be blocked: the filter does not catch them') : '');
	case 'igmp_no_querier': return _('NO IGMP querier on VLAN %s – the channels will expire').format(d.vlan || '?');
	case 'igmp_no_querier_ok': return d.to === 'off'
		? _('IGMP snooping switched off on VLAN %s – no querier needed (after %s)').format(d.vlan || '?', fmtDur(d.dur))
		: _('IGMP querier on VLAN %s again after %s: %s').format(d.vlan || '?', fmtDur(d.dur), querierName(d.to, d.addr, d.port));
	case 'proxy_down':      return _('Multicast proxy %s STOPPED').format(d.name);
	case 'proxy_up':        return _('Multicast proxy %s running again after %s').format(d.name, fmtDur(d.dur));
	case 'proxy_restart':   return _('Multicast proxy %s restarted').format(d.name);
	case 'cpu_high':        return _('Router CPU busy: %d%% on %s (softirq %d%%)').format(d.cpu, d.core || 'cpu', d.sirq);
	case 'cpu_high_ok':     return _('Router CPU load normal again after %s').format(fmtDur(d.dur));
	case 'mem_low':         return _('Router is low on RAM: %d%% free').format(d.pct);
	case 'mem_low_ok':      return _('Router RAM OK again after %s').format(fmtDur(d.dur));
	case 'conntrack_full':  return _('Connection table %d%% full (%d of %d)').format(d.pct, d.n, d.max);
	case 'conntrack_full_ok': return _('Connection table OK again after %s').format(fmtDur(d.dur));
	case 'user_mark':       return _('You reported: %s').format(markText(d.what)) + (d.note ? ' – „' + d.note + '”' : '');
	case 'log':             return logText(d.kind) + ' – ' + d.prog + ': „' + d.msg + '”' + (d.n > 1 ? ' (%d×)'.format(d.n) : '');
	case 'trace':           return traceText(e);
	case 'sfp_rx_drop':     return _('OPTICAL SIGNAL WEAKER: RX %s dBm, usually %s dBm (%s dB less) on %s').format(d.rx, d.base != null ? d.base : '?',
		d.base != null ? num(d.base - d.rx, 1) : '?', d.dev) + (d.why === 'module' ? ' · ' + _('the module itself warns') : d.why === 'min' ? ' · ' + _('below the set limit') : '');
	case 'sfp_rx_drop_ok':  return _('Optical signal back to %s dBm after %s (weakest %s dBm)').format(d.rx, fmtDur(d.dur), d.min);
	case 'sfp_los':         return _('NO LIGHT from the line on %s (SFP RX) – the fibre, the connector or the ISP\'s side').format(d.dev);
	case 'sfp_los_ok':      return _('Light is back after %s (RX %s dBm)').format(fmtDur(d.dur), d.rx != null ? d.rx : '?');
	case 'sfp_alarm':       return _('SFP module alarm: %s').format((d.flags || []).join(', ')) + (d.temp != null ? ' · %s °C'.format(d.temp) : '');
	case 'sfp_alarm_ok':    return _('SFP module alarm over after %s').format(fmtDur(d.dur));
	case 'sfp_gone':        return _('SFP module on %s does not answer any more (taken out, or it hung)').format(d.dev);
	case 'sfp_gone_ok':     return _('SFP module on %s answers again after %s').format(d.dev, fmtDur(d.dur));
	case 'decoder_restart': return _('Decoder %s RESTARTED – away for %s on %s (%s)').format(e.src, fmtDur(d.dur), d.port,
		{ link: _('port link went down'), fdb: _('vanished from the MAC table'), quiet: _('silent while the stream stopped') }[d.via] || d.via) +
		(d.stream ? ' – ' + _('the stream stopped because of it, not at the ISP') : '');
	case 'decoder_off':     return _('Decoder %s switched off or unplugged (%s)').format(e.src, d.port);
	case 'decoder_on':      return _('Decoder %s is back after %s').format(e.src, fmtDur(d.dur));
	case 'bufferbloat':     return _('BUFFERBLOAT: ping %s → %s (+%d ms) with the link %d%% full (%s %s of %s Mbit/s)').format(
		fmtMs(d.base), fmtMs(d.rtt), d.add, d.load, d.dir === 'up' ? _('upload') : _('download'),
		d.dir === 'up' ? d.tx_mbit : d.rx_mbit, d.dir === 'up' ? d.cap_tx_mbit : d.cap_rx_mbit);
	case 'bufferbloat_ok':  return _('Bufferbloat over after %s (at most +%d ms)').format(fmtDur(d.dur), d.max_add);
	case 'peer_lost':       return _('Router %s stopped reporting').format(e.src);
	case 'peer_back':       return _('Router %s reports again after %s').format(e.src, fmtDur(d.dur));
	case 'v6_down':         return _('IPv6 DOWN – no IPv6 target responds while IPv4 works (pages load slowly)');
	case 'v6_up':           return _('IPv6 works again after %s').format(fmtDur(d.dur));
	case 'v6_if_down':      return _('IPv6 interface %s DOWN (DHCPv6 session lost)').format(d.iface);
	case 'v6_if_up':        return _('IPv6 interface %s up again after %s').format(d.iface, fmtDur(d.dur));
	case 'v6_pd_lost':      return _('IPv6 prefix LOST (%s) – the home network has no IPv6').format((d.prev || []).join(', ') || '–');
	case 'v6_pd_back':      return _('IPv6 prefix back after %s: %s').format(fmtDur(d.dur), (d.prefix || []).join(', ')) + (d.same === false ? ' · ' + _('a different one') : '');
	case 'v6_pd_change':    return _('IPv6 prefix CHANGED %s → %s – devices at home renumber, IPv6 connections break').format((d.from || []).join(', '), (d.to || []).join(', '));
	case 'v6_no_route':     return _('No IPv6 default route on %s – no router advertisement from the ISP for %s').format(d.iface, fmtDur(d.after));
	case 'v6_route_back':   return _('IPv6 default route back after %s').format(fmtDur(d.dur));
	case 'dns_fail':        return _('DNS FAILING: %d%% of the queries sent upstream got no answer (%d of %d within %s)').format(d.pct, d.unans, d.fwd, fmtDur(d.win));
	case 'dns_ok':          return _('DNS answers again after %s (at worst %d%% unanswered)').format(fmtDur(d.dur), d.max_pct);
	case 'dns_server_bad':  return _('DNS server %s: %d of %d queries retried or failed within %s (%d retried = no answer in time, %d failed = SERVFAIL/REFUSED)').format(e.src, d.bad, d.sent, fmtDur(d.win), d.retried, d.failed) +
		(d.lat != null ? ' · ' + _('average %d ms').format(d.lat) : '');
	case 'dns_server_ok':   return d.no_data
		? _('DNS server %s: no statistics any more (removed from the DNS settings, or the statistics are off)').format(e.src)
		: _('DNS server %s answers normally again').format(e.src);
	case 'router_reboot':   return _('ROUTER RESTARTED – up since %s').format(d.boot ? fmtTime(d.boot) : '?') + (d.ram ? ' · ' + _('earlier data was in RAM and is lost') : '');
	case 'collector_restart': return (d.why === 'hung'
		? _('Monitor restarted by the watchdog: it hung (last report %s before)')
		: _('Monitor restarted after it stopped unexpectedly (last report %s before)')).format(fmtDur(d.after));
	case 'data_gap':        return _('NOT MEASURED from %s to %s (%s): %s').format(d.from ? fmtTime(d.from) : '?', fmtTime(d.to), fmtDur(d.len), gapWhy(d.why));
	case 'ntp_sync':        return _('Clock synchronized by NTP (stratum %s)').format(d.stratum != null ? d.stratum : '?') + (d.after != null && d.after < 3600 ? ' · ' + _('%s after boot').format(fmtDur(d.after)) : '');
	case 'ntp_unsync':      return _('Clock NOT synchronized any more (NTP lost its servers) – times may drift');
	case 'ntp_off':         return _('No NTP client running – the times in the log cannot be trusted');
	case 'maint_start':     return (d.extend ? _('Maintenance extended until %s') : _('MAINTENANCE until %s: what happens meanwhile is not counted and not notified')).format(hhmm(d.until)) + (d.note ? ' – „' + d.note + '”' : '');
	case 'maint_end':       return _('Maintenance over after %s').format(fmtDur(d.dur)) + (d.early ? ' (' + _('ended by hand') + ')' : '');
	case 'dhcp_lease':      return _('Decoder %s: address %s from the operator').format(e.src, d.ip) + (d.lease ? ' · ' + _('lease %s').format(fmtDur(d.lease)) : '') + (d.server ? ' · ' + _('server %s').format(d.server) : '');
	case 'dhcp_new':        return _('Decoder %s asked for an address from scratch (restarted or lost its lease): %s').format(e.src, d.ip);
	case 'dhcp_ip_change':  return _('Decoder %s: address CHANGED %s → %s – the operator gave it a new one, the picture may stop for a moment').format(e.src, d.from, d.to);
	case 'dhcp_nak':        return _('Decoder %s: the operator REFUSED its lease (DHCPNAK)').format(e.src);
	case 'dhcp_expired':    return _('Decoder %s: lease of %s ran out without a renewal').format(e.src, d.ip);
	case 'dhcp_late':       return _('Decoder %s renewed its lease %s after it had run out').format(e.src, fmtDur(d.late));
	case 'clock_step':      return _('Clock set by %s%s').format(d.by > 0 ? '+' : '−', fmtDur(Math.abs(d.by))) +
		(d.fixed ? ' · ' + _('%d earlier entries of this boot moved to the right time').format(d.fixed) : '');
	default:                return e.type;
	}
}

function fmtPct(v) {
	return v == null ? '–' : num(v, v < 1 ? 2 : 1);
}

function fmtKB(kb) {
	return kb == null ? '–' : (kb >= 1024 ? _('%s MB').format(num(kb / 1024, 1)) : _('%s kB').format(num(kb)));
}

/* what the tester itself uses: proof that it does not load the router */
function selfTitle(s) {
	var t = _('Share of the router\'s whole CPU (%d cores) used by the tester:').format(s.ncpu || 1) + '\n' +
		_('collector (with logread, bridge, rrdtool it runs): now %s%%, average %s%%, at most %s%%, RAM %s').format(fmtPct(s.cpu), fmtPct(s.avg), fmtPct(s.max), fmtKB(s.rss));
	if (s.tsmon) t += '\n' + _('tsmon (IPTV picture): now %s%%, at most %s%%, RAM %s').format(fmtPct(s.tsmon.cpu), fmtPct(s.tsmon.max), fmtKB(s.tsmon.rss));
	return t;
}

function gapWhy(w) {
	switch (w) {
	case 'reboot':  return _('the router restarted');
	case 'stopped': return _('monitoring was turned off');
	case 'crash':   return _('the collector stopped unexpectedly');
	case 'hung':    return _('the collector hung and was restarted by the watchdog');
	case 'stall':   return _('the collector was blocked');
	default:        return w || '?';
	}
}

/* maintenance periods [{ from, to, note }] (this router) that touch [from, to] */
function maintIn(events, from, to, nowTs) {
	var out = [], open = null;
	events.filter(function(e) { return !e.host && (e.type === 'maint_start' || e.type === 'maint_end'); })
		.sort(function(a, b) { return a.ts - b.ts; }).forEach(function(e) {
			if (e.type === 'maint_start') {
				if (open) open.until = e.d.until;
				else open = { from: e.ts, until: e.d.until, note: e.d.note };
			}
			else if (open) { out.push({ from: open.from, to: e.ts, note: open.note }); open = null; }
		});
	if (open) out.push({ from: open.from, to: Math.min(open.until, nowTs), note: open.note });
	return out.filter(function(p) { return p.to >= from && p.from <= to; });
}

/* periods without measurements [{ from, to, why }] that touch [from, to] */
function gapsIn(events, from, to) {
	return events.filter(function(e) { return e.type === 'data_gap' && !e.host && e.d && e.d.to >= from && (e.d.from || e.d.to) <= to; })
		.map(function(e) { return { from: e.d.from || e.d.to, to: e.d.to, why: e.d.why }; })
		.sort(function(a, b) { return a.from - b.from; });
}

var MARKS = [
	[ 'tv_freeze', _('TV froze') ],
	[ 'tv_pixel', _('TV picture breaks up') ],
	[ 'net_slow', _('Internet is slow') ],
	[ 'net_down', _('Internet does not work') ],
	[ 'other', _('Something else') ]
];

function markText(w) {
	for (var i = 0; i < MARKS.length; i++)
		if (MARKS[i][0] === w) return MARKS[i][1];
	return _('Something else');
}

function logText(k) {
	switch (k) {
	case 'ppp_echo':       return _('PPPoE: the ISP stopped answering LCP echo');
	case 'ppp_auth':       return _('PPPoE: authentication failed');
	case 'ppp_discovery':  return _('PPPoE: no answer from the ISP access server');
	case 'ppp_down':       return _('PPPoE: connection terminated');
	case 'dhcp_fail':      return _('DHCP: no lease from the ISP');
	case 'dhcp6_fail':     return _('DHCPv6: no answer or no prefix from the ISP');
	case 'proxy_log':      return _('Multicast proxy error');
	case 'nic_timeout':    return _('Network driver / switch chip hang');
	case 'conntrack_drop': return _('Connection table full, packets dropped');
	case 'oom':            return _('Router ran out of memory');
	case 'dns_limit':      return _('DNS server overloaded (query limit)');
	default:               return _('System log');
	}
}

/* "lags only when the link is full?" from the collector's ping/load statistics */
function bloatText(b) {
	if (b.idle_avg == null) return _('measuring…');
	if (!b.load_n) return _('%s at low load; the link has not been full yet').format(fmtMs(b.idle_avg));
	var add = b.load_avg - (b.base != null ? b.base : b.idle_avg);
	var share = b.bloat_n / b.load_n;
	return '%s / %s (+%s) – '.format(fmtMs(b.base != null ? b.base : b.idle_avg), fmtMs(b.load_avg), fmtMs(add)) +
		(share >= 0.5 ? _('lags only when the link is full (bufferbloat)')
			: share > 0 ? _('sometimes higher at full link')
			: _('no extra delay at full link'));
}

/* the result of a traceroute/mtr snapshot, in one line */
function traceText(e) {
	var d = e.d || {}, tool = d.tool === 'mtr' ? 'mtr' : 'traceroute';
	var head = _('Path snapshot (%s) to %s').format(tool, d.host) + (d.after != null && d.after > 2 ? ' ' + _('(%s after the loss started)').format(fmtDur(d.after)) : '') + ': ';
	if (d.err || !(d.hops || []).length) return head + _('no result') + (d.err ? ' (' + d.err + ')' : '');
	if (!d.first_bad) return head + _('no loss to the destination any more – the loss was over, or only ICMP replies of a router on the way were slow');
	return head + (d.first_bad === 1
		? _('loss from the first hop (%s) to the destination – the access line or the ISP\'s first router').format(d.bad_ip || '?')
		: _('loss starts at hop %d (%s) and carries on to the destination (%d%%); up to hop %s (%s) it was fine').format(
			d.first_bad, d.bad_ip || '?', d.dest_loss, d.last_good != null ? d.last_good : '?', d.good_ip || '?'));
}

/* the hops of a snapshot, as a table (timeline and report) */
function traceTable(d) {
	return E('table', { 'class': 'ispt-mini', 'style': 'margin:.3em 0;max-width:36em' }, [
		E('tr', {}, [ E('th', {}, _('Hop')), E('th', {}, _('Address')), E('th', {}, _('Loss')), E('th', {}, _('Ping')) ])
	].concat((d.hops || []).map(function(h) {
		var bad = d.first_bad != null && h.n >= d.first_bad;
		return E('tr', { 'class': bad ? 'ispt-warn-text' : '' }, [
			E('td', {}, String(h.n)), E('td', {}, h.ip || '???'), E('td', {}, '%d%%'.format(h.loss)),
			E('td', {}, h.avg != null ? fmtMs(h.avg) : '–')
		]);
	})));
}

/* events received from the second router carry its host name */
function hostBadge(e) {
	return e.host ? E('span', { 'class': 'ispt-host', 'title': _('Logged by router %s').format(e.host) }, e.host) : '';
}

/* the channel(s) being watched, stored with the event */
function chNote(ch) {
	return ch ? ' · ' + _('channel %s').format(ch) : '';
}

/* channel name of a multicast group, from the status (null = not known) */
function chName(t, grp) {
	var n = t && t.channels && t.channels.names && t.channels.names[grp];
	return (n && n.name) ? n.name : null;
}

/* "TVP 1 (239.0.0.1)", or just the group */
function chLabel(t, grp) {
	var n = chName(t, grp);
	return n ? '%s (%s)'.format(n, grp) : grp;
}

/* "lan1: TVP 1 (239.0.0.1), 239.0.0.2 · lan2: …" – one entry per decoder port */
function groupsByPort(mdb, t) {
	var by = {}, order = [];
	mdb.forEach(function(m) {
		if (!by[m.port]) { by[m.port] = []; order.push(m.port); }
		if (by[m.port].indexOf(m.grp) < 0) by[m.port].push(m.grp);
	});
	return order.sort().map(function(p) {
		return p + ': ' + by[p].map(function(g) { return chLabel(t, g); }).join(', ');
	}).join(' · ');
}

/* the one channel being watched now: its name, or "unknown" when the
 * channel or its name cannot be told (all joined groups are listed under
 * Bridge groups / Channels joined) */
function watching(t) {
	var c = t.channels;
	if (!c || !c.enabled || !t.igmp || !(t.igmp.groups || []).length) return null;
	var g = t.igmp.current, n = g && c.names && c.names[g];
	if (!n || !n.name) return E('em', {}, _('unknown'));
	return [ E('strong', {}, n.name), ' ', E('span', { 'class': 'ispt-groups' }, g),
		n.src === 'manual' ? ' · ' + _('name set by hand') : (n.provider ? ' · ' + n.provider : '') ];
}

function igmpNote(ig) {
	switch (ig) {
	case 'zap':    return ' · ' + _('channel change');
	case 'left':   return ' · ' + _('IGMP membership was dropped');
	case 'joined': return ' · ' + _('still subscribed, data stopped');
	default:       return '';
	}
}

/* hours of the day { from: 0..23, to: 1..24 }, "to" not included; from >= to
 * goes over midnight (22–2). null = the whole day */
function inHours(ts, hr) {
	if (!hr) return true;
	var h = new Date(ts * 1000).getHours();
	return hr.from < hr.to ? (h >= hr.from && h < hr.to) : (h >= hr.from || h < hr.to);
}

/* seconds of [a, b] within the hours (local time, day by day) */
function clipLen(a, b, hr) {
	if (!(b > a)) return 0;
	if (!hr) return b - a;
	var total = 0, d0 = new Date(a * 1000);
	var ranges = hr.from < hr.to ? [ [ hr.from, hr.to ] ] : [ [ 0, hr.to ], [ hr.from, 24 ] ];
	for (var d = new Date(d0.getFullYear(), d0.getMonth(), d0.getDate()); d.getTime() / 1000 < b; d = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1))
		ranges.forEach(function(r) {
			var s = new Date(d.getFullYear(), d.getMonth(), d.getDate(), r[0]).getTime() / 1000;
			var e = new Date(d.getFullYear(), d.getMonth(), d.getDate(), r[1]).getTime() / 1000;
			total += Math.max(0, Math.min(b, e) - Math.max(a, s));
		});
	return total;
}

function hoursText(hr) {
	return hr ? _('%02d:00–%02d:59 every day').format(hr.from, (hr.to + 23) % 24) : _('the whole day');
}

/* "2026-11-21" of a local day, for <input type="date"> */
function dayStr(ts) {
	return isoTime(ts).substr(0, 10);
}

/* local midnight of "2026-11-21" */
function dayTs(s) {
	var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s || '');
	return m ? new Date(+m[1], +m[2] - 1, +m[3]).getTime() / 1000 : null;
}

/* problems per hour of day, to spot e.g. evening congestion */
function hourHistogram(events, from, to) {
	var h = [];
	for (var i = 0; i < 24; i++) h.push(0);
	events.forEach(function(e) {
		if (e.ts < from || e.ts > to || e.lvl === 'info' || e.type === 'trace' || e.m) return;
		/* the end of a problem is not one of its own (as in the analysis:
		 * "stream did not come back" was counted as a second problem) */
		if (diagnose.recovery[e.type]) return;

		h[new Date(e.ts * 1000).getHours()]++;
	});
	return h;
}

/* ---------------------------------------------------------------- charts */

function esc(s) {
	return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
}

/* typical spacing of samples, used to detect gaps (collector stopped, reboot) */
function medianStep(t) {
	if (t.length < 3) return 60;
	var d = [];
	for (var i = 1; i < t.length; i++) d.push(t[i] - t[i - 1]);
	d.sort(function(a, b) { return a - b; });
	return d[Math.floor(d.length / 2)] || 60;
}

function hhmm(ts, secs) {
	var o = { hour: '2-digit', minute: '2-digit' };
	if (secs) o.second = '2-digit';
	return new Date(ts * 1000).toLocaleTimeString(LOCALE, o);
}

/* attach a crosshair + tooltip to an svg chart */
function attachTooltip(wrap, svgEl, geo, t, lines) {
	var tip = E('div', { 'class': 'ispt-tip', 'style': 'display:none' });
	var cross = document.createElementNS('http://www.w3.org/2000/svg', 'line');
	cross.setAttribute('y1', geo.T); cross.setAttribute('y2', geo.H - geo.B);
	cross.setAttribute('stroke', 'currentColor'); cross.setAttribute('opacity', '0.5');
	cross.setAttribute('stroke-dasharray', '3 3'); cross.style.display = 'none';
	svgEl.appendChild(cross);
	wrap.appendChild(tip);

	svgEl.addEventListener('mousemove', function(ev) {
		var r = svgEl.getBoundingClientRect();
		var px = (ev.clientX - r.left) / r.width * geo.W;
		if (px < geo.L || px > geo.W - geo.R) { tip.style.display = 'none'; cross.style.display = 'none'; return; }
		var ts = geo.t0 + (px - geo.L) / (geo.W - geo.L - geo.R) * geo.span;

		var lo = 0, hi = t.length - 1;
		while (hi - lo > 1) { var mid = (lo + hi) >> 1; if (t[mid] < ts) lo = mid; else hi = mid; }
		var k = (Math.abs(t[lo] - ts) <= Math.abs(t[hi] - ts)) ? lo : hi;
		if (Math.abs(t[k] - ts) > geo.step * 2) { tip.style.display = 'none'; cross.style.display = 'none'; return; }

		var xx = geo.x(t[k]);
		cross.setAttribute('x1', xx); cross.setAttribute('x2', xx); cross.style.display = '';
		dom.content(tip, [ E('strong', {}, fmtTime(t[k])) ].concat(lines(k).map(function(l) { return E('div', {}, l); })));
		tip.style.display = '';
		var left = (xx / geo.W) * r.width;
		tip.style.left = (left > r.width * 0.6 ? left - tip.offsetWidth - 12 : left + 12) + 'px';
	});
	svgEl.addEventListener('mouseleave', function() { tip.style.display = 'none'; cross.style.display = 'none'; });
}

/*
 * series: [{ name, color, data: [v|null], fmt }], t: [ts]
 * opts: { from, to, title, bands, fmt (axis), min_max, legend, height }
 */
function lineChart(t, series, opts) {
	opts = opts || {};
	var W = 800, H = opts.height || 140, L = 46, R = 8, T = 8, B = 20;
	var n = t.length;

	if (n < 2)
		return E('div', { 'class': 'ispt-muted' }, _('Collecting data…'));

	var max = opts.min_max || 1;
	series.forEach(function(s) { s.data.forEach(function(v) { if (v != null && v > max) max = v; }); });
	var lead = max / Math.pow(10, Math.floor(Math.log10(max)));
	max = niceMax(max);
	var divs = (Math.round(max / Math.pow(10, Math.floor(Math.log10(max)))) === 5 || lead > 5) ? 5 : 4;

	var t0 = (opts.from != null) ? opts.from : t[0];
	var t1 = (opts.to != null) ? opts.to : t[n - 1];
	var span = Math.max(1, t1 - t0);
	var step = medianStep(t);
	var x = function(ts) { return L + (ts - t0) / span * (W - L - R); };
	var y = function(v) { return T + (1 - Math.max(0, Math.min(v, max)) / max) * (H - T - B); };

	var svg = '<svg viewBox="0 0 ' + W + ' ' + H + '" xmlns="http://www.w3.org/2000/svg" font-size="11" fill="currentColor">';

	/* highlighted bands (e.g. loss / stall) */
	(opts.bands || []).forEach(function(b) {
		svg += '<rect x="' + x(b.from) + '" y="' + T + '" width="' + Math.max(2, x(b.to) - x(b.from)) +
			'" height="' + (H - T - B) + '" fill="' + b.color + '" opacity="0.25"><title>' + esc(b.title || '') + '</title></rect>';
	});

	for (var i = 0; i <= divs; i++) {
		var v = max * i / divs, yy = y(v);
		svg += '<line x1="' + L + '" x2="' + (W - R) + '" y1="' + yy + '" y2="' + yy + '" stroke="currentColor" opacity="0.12"/>';
		svg += '<text x="' + (L - 4) + '" y="' + (yy + 4) + '" text-anchor="end" opacity="0.7">' + esc(opts.fmt ? opts.fmt(v) : Math.round(v)) + '</text>';
	}

	var ticks = 4;
	for (var j = 0; j <= ticks; j++) {
		var ts = t0 + span * j / ticks;
		svg += '<text x="' + x(ts) + '" y="' + (H - 5) + '" text-anchor="' + (j === 0 ? 'start' : j === ticks ? 'end' : 'middle') + '" opacity="0.7">' +
			hhmm(ts, span < 600) + '</text>';
	}

	series.forEach(function(s) {
		var path = '', pen = false;
		for (var k = 0; k < n; k++) {
			var val = s.data[k];
			if (val == null || (k > 0 && t[k] - t[k - 1] > step * 3)) pen = false;
			if (val == null || t[k] < t0 || t[k] > t1) { pen = false; continue; }
			path += (pen ? 'L' : 'M') + x(t[k]).toFixed(1) + ' ' + y(val).toFixed(1);
			pen = true;
		}
		if (path)
			svg += '<path d="' + path + '" fill="none" stroke="' + s.color + '" stroke-width="1.6" stroke-linejoin="round"/>';
	});

	svg += '</svg>';

	var div = E('div', { 'class': 'ispt-svgwrap' });
	div.innerHTML = svg;

	attachTooltip(div, div.firstChild, { W: W, H: H, L: L, R: R, T: T, B: B, t0: t0, span: span, step: step, x: x }, t, function(k) {
		return series.map(function(s) {
			var v = s.data[k];
			return s.name + ': ' + (v == null ? (s.loss && s.loss[k] >= 100 ? _('no response') : '–') : (s.fmt ? s.fmt(v, k) : String(v)));
		});
	});

	var legend = E('div', { 'class': 'ispt-legend' }, series.map(function(s) {
		return E('span', {}, [ E('i', { 'style': 'background:' + s.color }), s.name ]);
	}));

	return E('div', { 'class': 'ispt-chart' }, [
		opts.title ? E('div', { 'class': 'title' }, opts.title) : '',
		div,
		series.length > 1 || opts.legend ? legend : ''
	]);
}

/* thin green/yellow/red strip showing overall health over time; grey
 * hatched = not measured (router off, monitoring off) */
function statusRibbon(t, lvls, from, to, gaps, maints) {
	var W = 800, H = 22, L = 46, R = 8;
	var span = Math.max(1, to - from), step = medianStep(t);
	var x = function(ts) { return L + (ts - from) / span * (W - L - R); };
	var col = [ '#2e9d4f', '#e0a100', '#d64541' ];

	var svg = '<svg viewBox="0 0 ' + W + ' ' + H + '" xmlns="http://www.w3.org/2000/svg" font-size="11" fill="currentColor">' +
		'<rect x="' + L + '" y="4" width="' + (W - L - R) + '" height="14" fill="currentColor" opacity="0.08"/>';

	for (var k = 0; k < t.length; k++) {
		var v = lvls[k];
		if (v == null || t[k] < from - step || t[k] > to) continue;
		var x0 = Math.max(L, x(t[k] - step)), x1 = Math.min(W - R, x(t[k]));
		svg += '<rect x="' + x0.toFixed(1) + '" y="4" width="' + Math.max(0.8, x1 - x0).toFixed(1) + '" height="14" fill="' + (col[v] || '#999') + '"/>';
	}
	svg += '<defs><pattern id="ispt-hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">' +
		'<rect width="3" height="6" fill="#888" opacity="0.55"/></pattern></defs>';
	(maints || []).forEach(function(g) {
		var x0 = Math.max(L, x(g.from)), x1 = Math.min(W - R, x(g.to));
		if (x1 <= x0) return;
		svg += '<rect x="' + x0.toFixed(1) + '" y="4" width="' + Math.max(0.8, x1 - x0).toFixed(1) + '" height="14" fill="#3b82c4" opacity="0.75">' +
			'<title>' + esc(_('Maintenance (not counted)') + (g.note ? ': ' + g.note : '')) + '</title></rect>';
	});
	(gaps || []).forEach(function(g) {
		var x0 = Math.max(L, x(g.from)), x1 = Math.min(W - R, x(g.to));
		if (x1 <= x0) return;
		svg += '<rect x="' + x0.toFixed(1) + '" y="4" width="' + Math.max(0.8, x1 - x0).toFixed(1) + '" height="14" fill="url(#ispt-hatch)">' +
			'<title>' + esc(_('Not measured: %s').format(gapWhy(g.why))) + '</title></rect>';
	});
	svg += '<text x="' + (L - 4) + '" y="15" text-anchor="end" opacity="0.7">' + esc(_('State')) + '</text></svg>';

	var div = E('div', { 'class': 'ispt-svgwrap' });
	div.innerHTML = svg;
	attachTooltip(div, div.firstChild, { W: W, H: H, L: L, R: R, T: 4, B: 4, t0: from, span: span, step: step, x: x }, t, function(k) {
		return [ levelText([ 'ok', 'warn', 'fail' ][lvls[k]]) ];
	});
	return E('div', { 'class': 'ispt-chart' }, div);
}

function niceMax(v) {
	var p = Math.pow(10, Math.floor(Math.log10(v)));
	var f = v / p;
	return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * p;
}

/* contiguous ranges where pred(i) is true -> bands */
function bandsFor(t, pred, color, title) {
	var out = [], start = null;
	for (var i = 0; i < t.length; i++) {
		if (pred(i)) { if (start == null) start = i; }
		else if (start != null) { out.push({ from: t[start], to: t[i], color: color, title: title }); start = null; }
	}
	if (start != null) out.push({ from: t[start], to: t[t.length - 1], color: color, title: title });
	return out;
}

/* -------------------------------------------------------------- download */

function download(name, text, mime) {
	var blob = new Blob([ text ], { type: mime || 'text/csv' });
	var a = E('a', { href: URL.createObjectURL(blob), download: name, style: 'display:none' });
	document.body.appendChild(a);
	a.click();
	setTimeout(function() { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}

function stamp() {
	return isoTime(rnow()).replace(/[: ]/g, '-');
}

function csvCell(v) {
	v = (v == null) ? '' : String(v);
	/* channel names come from the stream, notes from whoever clicked: a
	 * leading = + - @ would be run as a formula by a spreadsheet (the
	 * collector's own CSV guards against it the same way) */
	if (/^[=+\-@\t\r]/.test(v)) v = "'" + v;
	return /[",\r\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
}

/* ------------------------------------------------------------------ view */

var RANGES = [ [ 3600, _('1 h') ], [ 6 * 3600, _('6 h') ], [ 24 * 3600, _('24 h') ] ];

function readJson(path) {
	return fs.read_direct(path).then(function(t) {
		try { return JSON.parse(t); } catch (e) { return null; }
	}).catch(function() { return null; });
}

/* the details too: picture errors of two channels in one tick (both from
 * source "quality") had the same time, type and source, and the second one
 * vanished from the timeline, the charts and the report */
function evKey(e) {
	return e.ts + '|' + e.type + '|' + e.src + '|' + (e.host || '') + '|' + JSON.stringify(e.d || null);
}

/* recent: the newest events (rpcd, every 5 s), base: the whole timeline
 * file. They overlap only from the oldest recent event on, so only that part
 * is compared: every event of the file was turned into a JSON key on every
 * poll (thousands of them, every 5 s) */
function mergeEvents(recent, base) {
	var lo = Infinity, seen = {}, out = [];
	recent.forEach(function(e) { if (e.ts < lo) lo = e.ts; });
	base.forEach(function(e) {
		if (e.ts >= lo) seen[evKey(e)] = true;
		out.push(e);
	});
	recent.forEach(function(e) {
		var k = evKey(e);
		if (!seen[k]) { seen[k] = true; out.push(e); }
	});
	return out.sort(function(x, y) { return y.ts - x.ts; });
}

return view.extend({
	filter: '',
	range: 24 * 3600,     /* visible window length */
	end: null,            /* window end (null = live / now) */
	allEvents: [],
	minHist: null,
	evCache: null,

	load: function() {
		return Promise.all([ callStatus(), callEvents(200, ''), readJson('/tmp/isp-tester/events.json'), readJson('/tmp/isp-tester/history.json') ]);
	},

	/* ---- time window */
	now: function() {
		var st = this.last && this.last[0] && this.last[0].state;
		return Math.max(rnow(), st ? st.ts : 0);
	},

	win: function() {
		var to = (this.end == null) ? this.now() : this.end;
		return { from: to - this.range, to: to, live: this.end == null };
	},

	setWindow: function(range, end) {
		this.range = range;
		this.end = (end == null || end >= this.now() - 5) ? null : end;
		this.redraw();
	},

	/* the merged timeline is asked for about ten times per redraw (cards,
	 * charts, analysis, timeline): the same inputs give the same list, so it
	 * is merged and sorted once. Callers must not change the returned array. */
	events: function() {
		var recent = (this.last && this.last[1] && this.last[1].events) || [];
		var base = this.allEvents || [];
		var c = this.evCache;
		if (c && c.recent === recent && c.base === base) return c.out;
		var out = mergeEvents(recent, base);
		this.evCache = { recent: recent, base: base, out: out };
		return out;
	},

	/* this router's events, oldest first, for the chart bands (each chart
	 * filtered and sorted the whole timeline again on every 5 s redraw) */
	ownAsc: function() {
		var all = this.events(), c = this.ascCache;
		if (c && c.all === all) return c.out;
		var out = all.filter(function(e) { return !e.host; }).reverse();
		this.ascCache = { all: all, out: out };
		return out;
	},

	rangeName: function(range) {
		var r = RANGES.filter(function(x) { return x[0] === range; })[0];
		return r ? r[1] : fmtDur(range);
	},

	/* chart data for the window: fine 10 s data when live and it covers the window, 1-minute aggregates otherwise */
	chartData: function(st, w) {
		var fine = st.history || { t: [], s: {} };
		if (w.live && fine.t.length && fine.t[0] <= w.from + (st.interval || 10) * 2)
			return { h: fine, fine: true };
		if (w.live && this.range <= 3600 && !(this.minHist && this.minHist.t.length))
			return { h: fine, fine: true };
		return { h: this.minHist || { t: [], s: {} }, fine: false };
	},

	renderNav: function() {
		var self = this, w = this.win();
		var btn = function(label, active, fn, title) {
			return E('button', { 'class': 'cbi-button' + (active ? ' active' : ''), 'title': title || '', 'click': fn }, label);
		};
		var winText = w.live
			? _('last %s (live)').format(this.rangeName(this.range))
			: fmtShort(w.from) + ' – ' + fmtShort(w.to);

		return E('div', { 'class': 'ispt-nav' }, RANGES.map(function(r) {
			return btn(r[1], self.range === r[0], function() { self.setWindow(r[0], self.end); });
		}).concat([
			btn('◀', false, function() { var x = self.win(); self.setWindow(self.range, x.to - self.range / 2); }, _('Earlier')),
			btn('▶', false, function() { var x = self.win(); if (!x.live) self.setWindow(self.range, x.to + self.range / 2); }, _('Later')),
			btn(_('Now'), w.live, function() { self.setWindow(self.range, null); }),
			E('span', { 'class': 'win' }, winText)
		]));
	},

	/* ---- probable cause */
	renderDiagnosis: function(st, w) {
		var r = this.analyze(st, w);

		var total = r.isp + r.home;
		var ispPct = total ? Math.round(r.isp * 100 / total) : 0;

		var head = E('div', { 'class': 'head' }, [
			E('div', { 'class': 'ispt-muted' }, _('Probable cause (%s)').format(w.live ? _('last %s').format(this.rangeName(this.range)) : _('selected period'))),
			E('div', { 'class': 'verdict' }, [ dot(r.verdict === 'none' || r.verdict === 'minor' ? 'ok' : r.verdict === 'mixed' ? 'warn' : 'fail'), diagnose.verdictText(r.verdict) ]),
			total ? E('div', {}, [
				E('div', { 'class': 'ispt-scale' }, [
					E('div', { 'style': 'width:' + ispPct + '%;background:#c0563b' }),
					E('div', { 'style': 'width:' + (100 - ispPct) + '%;background:#3b6fc0' })
				]),
				E('div', { 'class': 'ispt-scale-lbl' }, [
					E('span', {}, _('ISP %d%%').format(ispPct)),
					E('span', {}, _('Router / home %d%%').format(100 - ispPct))
				]),
				E('div', { 'class': 'ispt-muted', 'style': 'font-size:.85em;margin-top:.3em' },
					diagnose.confidenceText(r.confidence) + ' · ' + _('%d problems, %d IPTV freezes').format(r.problems, r.stalls) +
					(r.zaps ? ' · ' + _('%d channel changes ignored').format(r.zaps) : '') +
					(r.decoder_stalls ? ' · ' + _('%d during decoder restarts').format(r.decoder_stalls) : ''))
			]) : E('div', { 'class': 'ispt-muted', 'style': 'font-size:.9em' }, _('Nothing was logged that points at a fault.'))
		]);

		/* the 8 that weigh most (the verdict rests on them), shown by time:
		 * the latest first, findings without a moment (notes) at the end */
		var items = r.findings.slice(0, 8).sort(function(a, b) {
			return (b.last || 0) - (a.last || 0);
		}).map(function(f) {
			return E('li', {}, [
				E('span', { 'class': 'ispt-side ' + f.side }, diagnose.sideText(f.side)),
				E('span', {}, diagnose.findingText(f)),
				f.last ? E('span', { 'class': 'ispt-muted', 'style': 'margin-left:auto;white-space:nowrap;font-size:.85em;font-variant-numeric:tabular-nums',
					'title': fmtTime(f.last) }, _('last %s').format(fmtWhen(f.last))) : ''
			]);
		});

		return E('div', { 'class': 'ispt-diag' }, [
			head,
			items.length ? E('ul', { 'class': 'list' }, items) : '',
			E('div', { 'class': 'ispt-muted', 'style': 'flex-basis:100%;font-size:.8em' },
				_('Heuristic based on what happened at the same time; treat it as a hint, not proof. The timeline below is the evidence.'))
		]);
	},

	analyze: function(st, w, hr) {
		var br = st.iptv && st.iptv.bridge;
		return diagnose.analyze(this.events(), w.from, w.to, {
			/* only these hours of every day (report), null = all */
			inHours: hr ? function(ts) { return inHours(ts, hr); } : null,
			wan_device: st.wan && st.wan.device,
			iptv_direction: st.iptv && st.iptv.direction,
			bridge: br,
			membership_interval: br && br.membership_interval,
			query_interval: br && br.query_interval,
			igmp: st.iptv && st.iptv.igmp,
			igmpq: st.iptv && st.iptv.igmpq,
			querier: st.iptv && st.iptv.querier,
			iptv_on: !!st.iptv
		});
	},

	/* ---- banner */
	renderBanner: function(res) {
		var st = res.state;

		if (!res.enabled) {
			return E('div', { 'class': 'ispt-banner ispt-bg-unknown' }, [
				dot('unknown', true),
				E('div', {}, [
					E('div', { 'class': 'big' }, _('Monitoring is turned off')),
					E('div', { 'class': 'sub' }, _('Nothing is measured or logged. The data collected so far stays available until reboot.'))
				]),
				E('div', { 'class': 'meta' }, E('button', {
					'class': 'cbi-button cbi-button-positive',
					'click': ui.createHandlerFn(this, 'toggleEnabled', true)
				}, _('Turn on')))
			]);
		}

		if (!res.running) {
			return E('div', { 'class': 'ispt-banner ispt-bg-fail' }, [
				dot('fail', true),
				E('div', {}, [
					E('div', { 'class': 'big' }, _('Monitoring is not running')),
					E('div', { 'class': 'sub' }, _('It is turned on but the collector is not running – see the system log (logread -e isp-tester).'))
				]),
				E('div', { 'class': 'meta' }, E('button', {
					'class': 'cbi-button cbi-button-positive',
					'click': ui.createHandlerFn(this, 'toggleEnabled', true)
				}, _('Restart')))
			]);
		}

		if (!st) {
			return E('div', { 'class': 'ispt-banner ispt-bg-unknown' }, [
				dot('unknown', true),
				E('div', { 'class': 'big' }, _('Waiting for the first measurement…'))
			]);
		}

		/* running, but the state is not updated: hung (procd's watchdog restarts it) */
		var stale = rnow() - st.ts;
		var wdt = (st.watchdog && st.watchdog.timeout) || Math.max(60, st.interval * 6);
		if (stale > Math.max(st.interval * 3, 30)) {
			return E('div', { 'class': 'ispt-banner ispt-bg-fail' }, [
				dot('fail', true),
				E('div', {}, [
					E('div', { 'class': 'big' }, _('MONITOR IS NOT WORKING')),
					E('div', { 'class': 'sub' }, (stale < wdt + 30
						? _('The collector has not reported for %s – it seems to hang. The watchdog restarts it automatically after %s.')
						: _('The collector has not reported for %s, and the watchdog (%s) did not restart it – see the system log (logread -e isp-tester).')).format(fmtDur(stale), fmtDur(wdt)) +
						' ' + _('Nothing is measured meanwhile; the gap will be in the report.'))
				]),
				E('div', { 'class': 'meta' }, E('button', {
					'class': 'cbi-button cbi-button-positive',
					'click': ui.createHandlerFn(this, 'toggleEnabled', true)
				}, _('Restart')))
			]);
		}

		var o = lvl(st.overall);
		var problems = [];
		[ [ 'wan', st.wan ], [ 'iptv', st.iptv ], [ 'ports', st.ports ] ].forEach(function(a) {
			if (a[1] && a[1].level && a[1].level !== 'ok' && a[1].level !== 'unknown')
				problems.push(areaName(a[0]) + ': ' + levelText(a[1].level).toLowerCase());
		});
		((st.peers && st.peers.list) || []).forEach(function(p) {
			if (!p.online && p.level === 'warn') problems.push(_('%s: not reporting').format(p.name));
			else if (p.level === 'warn' || p.level === 'fail') problems.push(p.name + ': ' + levelText(p.level).toLowerCase());
		});

		var headline = (o === 'ok') ? _('Everything works')
			: (o === 'warn') ? _('Works, but there were problems')
			: _('Fault right now');

		var c1 = st.counts && st.counts.h1 || { warn: 0, err: 0 };
		var c24 = st.counts && st.counts.h24 || { warn: 0, err: 0 };

		return E('div', { 'class': 'ispt-banner ispt-bg-' + o }, [
			dot(o, true),
			E('div', {}, [
				E('div', { 'class': 'big' }, headline),
				E('div', { 'class': 'sub' }, problems.length ? problems.join(' · ') : _('Internet, IPTV and ports look healthy.'))
			]),
			E('div', { 'class': 'meta' }, [
				E('div', {}, _('Last hour: %d errors, %d warnings').format(c1.err, c1.warn)),
				E('div', {}, _('Last 24 h: %d errors, %d warnings').format(c24.err, c24.warn)),
				E('div', { 'class': stale > st.interval * 3 ? 'ispt-warn-text' : '' },
					_('Updated %s ago · running for %s').format(fmtDur(stale), fmtDur(st.ts - st.started))),
				st.self && st.self.cpu != null ? E('div', { 'class': 'ispt-muted', 'style': 'font-size:.85em',
					'title': selfTitle(st.self) }, _('Tester itself: CPU %s%% · RAM %s').format(fmtPct(st.self.total), fmtKB(st.self.rss_total))) : '',
				E('button', { 'class': 'cbi-button cbi-button-action ispt-markbtn', 'style': 'margin-top:.4em',
					'title': _('Click the moment you notice a problem (TV freezes, Internet slow). It is logged and compared with the measurements.'),
					'click': ui.createHandlerFn(this, 'showMark') }, _('⚑ Problem now')),
				E('button', { 'class': 'cbi-button', 'style': 'margin-top:.4em;margin-left:.4em',
					'title': _('You are about to re-plug cables or change settings: the next minutes are not counted as faults and send no notifications.'),
					'click': ui.createHandlerFn(this, 'showMaint') }, _('🔧 Working on the network'))
			])
		]);
	},

	showMark: function() {
		var self = this, clicked = Date.now();
		var note = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%', 'maxlength': 200,
			'placeholder': _('Optional note, e.g. channel, room, what you saw') });
		var send = function(what) {
			ui.hideModal();
			/* the time of the click counts, not of the choice: the router dates
			 * the mark back by the seconds spent in this dialog (it used the
			 * moment of the choice, and only said how late that was) */
			var late = Math.max(0, Math.round((Date.now() - clicked) / 1000));
			return callMark(what, note.value || '', late).then(function(r) {
				ui.addNotification(null, E('p', r && r.result
					? _('Logged. It will appear in the timeline within one interval.')
					: _('Could not log the report.')), r && r.result ? 'info' : 'error');
				setTimeout(function() { self.refreshSlow().then(function() { self.redraw(); }); }, 12000);
			});
		};
		ui.showModal(_('What is wrong right now?'), [
			E('p', _('This puts a mark on the timeline. The analysis then checks whether the router measured something at that moment.')),
			E('div', { 'class': 'ispt-choices' }, MARKS.map(function(m) {
				return E('button', { 'class': 'cbi-button cbi-button-action', 'click': function() { send(m[0]); } }, m[1]);
			})),
			note,
			E('div', { 'class': 'right', 'style': 'margin-top:.8em' }, E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')))
		]);
	},

	/* the collector keeps restarting: say so, the measurements have holes */
	renderRestarts: function(st) {
		var t = rnow();
		var n = this.events().filter(function(e) { return !e.host && e.type === 'collector_restart' && e.ts > t - 3600; }).length;
		if (n < 2) return '';
		return E('div', { 'class': 'ispt-banner ispt-bg-warn', 'style': 'padding:.5em 1em' }, [
			dot('warn'), E('div', {}, [ E('strong', {}, _('The monitor restarted %d× in the last hour').format(n)), ' – ',
				_('it crashes or hangs; see the system log (logread -e isp-tester) and report it. Measurements have short gaps.') ])
		]);
	},

	/* ---- maintenance: "I am working on the network" */
	showMaint: function() {
		var self = this;
		var note = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%', 'maxlength': 120,
			'placeholder': _('Optional note, e.g. replacing the switch') });
		var go = function(min) {
			ui.hideModal();
			return callMaint(min, note.value || '').then(function(r) {
				/* a request the router refused is not "not running" */
				var ok = r && r.result && r.running;
				ui.addNotification(null, E('p', ok
					? (min ? _('Maintenance starts within one interval.') : _('Maintenance ends within one interval.'))
					: (r && r.result) ? _('Monitoring is not running.') : _('Could not start the maintenance.')), ok ? 'info' : 'warning');
				setTimeout(function() { callStatus().then(function(st) { self.last = [ st, self.last[1] ]; self.redraw(); }); }, 11000);
			});
		};
		ui.showModal(_('Working on the network'), [
			E('p', _('While you re-plug cables, restart the switch or change settings, what happens is still logged, but it is not counted as a fault: it is left out of the analysis and the report, the cards do not stay yellow afterwards, and no notifications are sent.')),
			E('div', { 'class': 'ispt-choices' }, [ 15, 30, 60, 120 ].map(function(m) {
				return E('button', { 'class': 'cbi-button cbi-button-action', 'click': function() { go(m); } }, _('%d min').format(m));
			})),
			note,
			E('div', { 'class': 'right', 'style': 'margin-top:.8em' }, E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')))
		]);
	},

	renderMaint: function(st) {
		var m = st.maint, self = this;
		if (!m || !m.active) return '';
		return E('div', { 'class': 'ispt-banner ispt-bg-maint', 'style': 'padding:.5em 1em' }, [
			E('span', { 'style': 'font-size:1.4em' }, '🔧'),
			E('div', {}, [ E('strong', {}, _('Maintenance until %s').format(hhmm(m.until))), ' – ',
				_('not counted as faults, no notifications (for %s so far)').format(fmtDur(rnow() - m.since)) + (m.note ? ' · „' + m.note + '”' : '') ]),
			E('div', { 'class': 'meta' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.createHandlerFn(this, function() {
					/* at most a day (the router refuses more): +30 near the limit did nothing */
					return callMaint(Math.min(1440, Math.max(1, Math.round((m.until - rnow()) / 60)) + 30), m.note || '').then(function() { setTimeout(function() { self.refreshNow(); }, 11000); });
				}) }, _('+30 min')), ' ',
				E('button', { 'class': 'cbi-button cbi-button-negative', 'click': ui.createHandlerFn(this, function() {
					return callMaint(0, '').then(function() { setTimeout(function() { self.refreshNow(); }, 11000); });
				}) }, _('End now'))
			])
		]);
	},

	refreshNow: function() {
		var self = this;
		return Promise.all([ callStatus(), callEvents(200, '') ]).then(function(d) { self.last = [ d[0], d[1] ]; self.redraw(); });
	},

	/* ---- clock: times are only worth something when it is synchronized */
	renderClock: function(st) {
		var n = st.ntp;
		if (!n || (n.state === 'synced' && !n.untrusted) || n.state === 'unknown') return '';
		var text = n.state === 'off' ? _('No NTP client is running on the router (System → System → Time synchronization). The times in the log and in the report cannot be trusted.')
			: n.untrusted ? _('The clock has not been confirmed by NTP since the router started (%s ago). Times logged until then are corrected automatically when NTP sets the clock.').format(fmtDur(n.uptime))
			: _('The clock is not synchronized (NTP reports no server). The times in the log may be wrong – check the Internet connection and System → System → Time synchronization.');
		return E('div', { 'class': 'ispt-banner ispt-bg-warn', 'style': 'padding:.5em 1em' }, [
			dot('warn'), E('div', {}, [ E('strong', {}, _('Clock not synchronized')), ' – ', text ])
		]);
	},

	/* ---- cards */
	renderWan: function(st) {
		var w = st.wan;
		if (!w)
			return this.disabledCard(_('Internet'));

		var targets = w.targets || [];
		var rows = targets.map(function(t) {
			return E('tr', {}, [
				E('td', {}, [ dot(t.level), targetName(t.label, t.host) ]),
				E('td', { 'class': 'n' + (t.loss ? ' bad' : (t.loss === 0 ? ' zero' : '')) }, (t.loss == null) ? '–' : num(t.loss) + ' %'),
				E('td', { 'class': 'n' }, fmtMs(t.rtt)),
				E('td', { 'class': 'n' }, fmtMs(t.jitter))
			]);
		});

		/* the key numbers: the worst loss, the ping of the gateway (else of the
		 * first target), the traffic */
		var gw = targets.filter(function(t) { return t.label === 'gateway'; })[0] || targets[0];
		var worst = null, worstLvl = 'ok';
		targets.forEach(function(t) {
			if (t.loss != null && (worst == null || t.loss > worst)) worst = t.loss;
			if (t.level === 'fail' || (t.level === 'warn' && worstLvl !== 'fail')) worstLvl = t.level;
		});
		var rx = rateParts(w.rx_kbps), tx = rateParts(w.tx_kbps);
		var kpis = E('div', { 'class': 'ispt-kpis' }, [
			kpi(_('Packet loss'), worst == null ? '–' : num(worst), worst == null ? '' : '%', worst ? worstLvl : 'ok', _('The highest loss of all targets')),
			kpi(_('Ping'), gw && gw.rtt != null ? num(gw.rtt, 1) : '–', gw && gw.rtt != null ? 'ms' : '', gw ? lvl(gw.level) : 'ok', gw ? targetName(gw.label, gw.host) : ''),
			kpi(_('Download'), rx[0], rx[1]),
			kpi(_('Upload'), tx[0], tx[1])
		]);

		/* details, by topic */
		var conn = [], kv = [];
		conn.push(E('span', { 'class': 'k' }, _('WAN device')), E('span', {}, w.device || '–'));
		if (w.source)
			conn.push(E('span', { 'class': 'k' }, _('Ping data')), E('span', { 'class': w.source.type ? '' : 'ispt-warn-text' },
				w.source.type === 'unixsock' ? _('collectd (live)')
				: w.source.type === 'rrd' ? _('collectd RRD files (delayed; enable the UnixSock plugin for live values)')
				: _('none')));
		var head = [];
		if (w.session) {
			var ss = w.session;
			head.push(E('span', { 'class': 'k' }, _('Session')), E('span', { 'class': ss.up ? '' : 'ispt-warn-text' },
				ss.up ? _('%s, up for %s').format((ss.proto || '').toUpperCase() || 'WAN', fmtDur(ss.uptime)) : _('DOWN')));
			head.push(E('span', { 'class': 'k' }, _('Address')), E('span', {}, (ss.ip || '–') +
				(ss.reconnects ? ' · ' + _('%d reconnects since start').format(ss.reconnects) : '')));
		}
		var v6kv = [], dnskv = [], linekv = [];
		if (w.v6) {
			var v6 = w.v6, v6t = [];
			if (!v6.found) v6t.push(_('no DHCPv6 interface (wan6)'));
			else if (!v6.up) v6t.push(E('span', { 'class': v6.pd_seen ? 'ispt-warn-text' : '' }, _('%s down').format(v6.iface)));
			else {
				v6t.push(v6.prefixes && v6.prefixes.length ? _('prefix %s').format(v6.prefixes.join(', '))
					: E('span', { 'class': v6.pd_seen ? 'ispt-warn-text' : '' }, v6.pd_seen ? _('prefix lost') : _('no prefix from the ISP')));
				v6t.push(v6.route ? _('RA OK') : E('span', { 'class': v6.route_seen ? 'ispt-warn-text' : '' }, _('no default route')));
			}
			if (v6.targets)
				v6t.push(E('span', { 'class': v6.down ? 'ispt-warn-text' : '' }, _('ping %d/%d').format(v6.targets_ok, v6.targets)));
			else if (v6.found && v6.up)
				v6t.push(E('span', { 'class': 'ispt-muted', 'title': _('Add an IPv6 host (e.g. 2606:4700:4700::1111) to the collectd Ping plugin') }, _('no IPv6 ping target')));
			var v6p = [];
			v6t.forEach(function(x, i) { if (i) v6p.push(' · '); v6p.push(x); });
			v6kv.push(E('span', { 'class': 'k' }, 'IPv6'), E('span', {}, v6p));
		}
		if (w.dns) {
			var dn = w.dns, dl = dn.last || {}, dt = [];
			if (dn.err) dt.push(E('span', { 'class': 'ispt-muted' }, _('no statistics from dnsmasq (ubus)')));
			else {
				dt.push(_('%s queries/min').format(num(dl.q || 0)));
				if (dl.q) dt.push(_('%d%% from the cache').format(Math.round(dl.local * 100 / dl.q)));
				if (dn.unans) dt.push(E('span', { 'class': dn.bad ? 'ispt-warn-text' : '' }, _('%d%% unanswered').format(dl.pct || 0)));
			}
			(dn.servers || []).forEach(function(x) {
				var d = x.d || {};
				dt.push(E('span', { 'class': x.bad ? 'ispt-warn-text' : '', 'title': _('Since the previous statistics: %d sent, %d retried, %d failed').format(d.sent || 0, d.retried || 0, d.failed || 0) },
					x.server + (x.lat != null ? ' ' + num(x.lat) + ' ms' : '') + (d.sent ? ' ' + _('%d%% bad').format(Math.round((d.bad || 0) * 100 / d.sent)) : '')));
			});
			if (dn.logqueries && !dn.err)
				dt.push(E('span', { 'class': 'ispt-muted', 'title': _('dnsmasq logs every query, so it is not asked for its per-server statistics (it would also write its whole cache to the log).') },
					_('no per-server statistics')));
			var dp = [];
			dt.forEach(function(x, i) { if (i) dp.push(' · '); dp.push(x); });
			dnskv.push(E('span', { 'class': 'k', 'title': _('DNS of the router, from dnsmasq\'s own statistics') }, _('DNS')), E('span', {}, dp));
		}
		if (w.bloat) {
			var b = w.bloat;
			linekv.push(E('span', { 'class': 'k' }, _('Line speed')), E('span', {},
				(b.cap_rx >= 1000 ? '↓ %s / ↑ %s'.format(fmtRate(b.cap_rx), fmtRate(b.cap_tx)) : '–') + ' (' + (b.learned ? _('highest seen') : _('set')) + ')'));
			linekv.push(E('span', { 'class': 'k', 'title': _('Ping of the gateway at low load and with the link full, from collectd and the WAN traffic of the same interval') }, _('Ping idle / full link')),
				E('span', { 'class': b.active ? 'ispt-warn-text' : '' }, bloatText(b)));
		}

		if (w.sfp) {
			var sp = w.sfp, sv = [];
			if (!sp.ok)
				sv.push(E('span', { 'class': 'ispt-warn-text' }, sp.ethtool ? (sp.err ? _('no answer from the module on %s (%s)').format(sp.dev || '?', sp.err) : _('no module on %s').format(sp.dev || '?')) : _('install ethtool')));
			else {
				var bad = sp.los || sp.drop;
				sv.push(E('span', { 'class': bad ? 'ispt-warn-text' : '', 'title': _('Received power; usually %s dBm, a fall of %s dB counts as a fault').format(sp.base != null ? sp.base : '?', sp.drop_db) },
					sp.rx != null ? 'RX ' + num(+sp.rx, 1) + ' dBm' : _('RX no light')));
				if (sp.tx != null) sv.push(' · TX ' + num(+sp.tx, 1) + ' dBm');
				if (sp.temp != null) sv.push(' · ' + num(+sp.temp) + ' °C');
				if (sp.alarm) sv.push(E('span', { 'class': 'ispt-warn-text' }, ' · ' + (sp.flags || []).join(', ')));
			}
			linekv.push(E('span', { 'class': 'k', 'title': _('From the SFP module itself (ethtool -m %s)').format(sp.dev || '') }, _('Optical signal')), E('span', {}, sv));
		}

		return E('div', { 'class': 'ispt-card l-' + lvl(w.level) }, [
			E('h3', {}, [ _('Internet'), chip(w.level) ]),
			this.reasons(w.reasons),
			kpis,
			E('table', { 'class': 'ispt-mini' }, [
				E('tr', {}, [ E('th', {}, _('Target')), E('th', { 'class': 'n' }, _('Loss')), E('th', { 'class': 'n' }, _('Ping')),
					E('th', { 'class': 'n', 'title': _('Standard deviation of the ping time (collectd)') }, _('Jitter')) ])
			].concat(rows.length ? rows : [ E('tr', {}, E('td', { colspan: 4, 'class': 'ispt-muted' }, _('Waiting for ping results…'))) ])),
			this.details('wan', head, [
				[ _('Connection'), conn ], [ 'IPv6', v6kv ], [ 'DNS', dnskv ], [ _('Line'), linekv ]
			])
		]);
	},

	renderIptv: function(st) {
		var t = st.iptv;
		if (!t)
			return this.disabledCard(_('IPTV'), _('Set the IPTV VLAN (or device) in Settings.'));

		var stateText = {
			playing: _('Stream running'),
			stalled: _('STREAM STOPPED'),
			idle: _('No stream (decoder off?)')
		}[t.state] || t.state;

		var v = t.vlan;
		var where = v ? [
			E('span', { 'class': 'k' }, _('Measured on')), E('span', {}, _('VLAN %d on %s').format(v.id, v.bridge || '?')),
			E('span', { 'class': 'k' }, _('Ports')), E('span', {}, (v.upstream ? v.upstream + ' (' + _('ISP') + ') → ' : '') +
				(v.ports || []).filter(function(p) { return p !== v.upstream; }).join(', '))
		] : [
			E('span', { 'class': 'k' }, _('Device')), E('span', {}, '%s (%s)'.format(t.device, t.direction === 'tx' ? _('outgoing') : _('incoming')))
		];

		/* the key numbers: state, bitrate now and usually, packets */
		var stLvl = t.state === 'stalled' ? 'fail' : t.state === 'playing' ? 'ok' : 'unknown';
		var now = rateParts(t.kbps), avg = rateParts(t.avg || null);
		var kpis = E('div', { 'class': 'ispt-kpis' }, [
			kpi(_('Stream'), { playing: _('running'), stalled: _('STOPPED'), idle: _('none') }[t.state] || t.state || '–', '', stLvl,
				stateText + ' · ' + _('for %s').format(fmtDur(rnow() - t.since))),
			kpi(_('Bitrate'), now[0], now[1], t.kbps && t.avg && t.kbps < t.avg / 2 ? 'warn' : 'ok'),
			kpi(_('Usual'), avg[0], avg[1]),
			kpi(_('Packets/s'), t.pps != null ? num(t.pps) : '–', '')
		]);

		var head = [
			E('span', { 'class': 'k' }, _('State')), E('span', { 'class': t.state === 'stalled' ? 'ispt-warn-text' : '' },
				stateText + ' · ' + _('for %s').format(fmtDur(rnow() - t.since)))
		];
		var kv = [], decs = [], igmp = [];

		var wv = watching(t);
		if (wv)
			head.push(E('span', { 'class': 'k' }, _('Watching')), E('span', {}, wv));

		/* decoders found in the bridge MAC table of the IPTV VLAN */
		(t.decoders || []).forEach(function(x) {
			decs.push(E('span', { 'class': 'k' }, _('Decoder %s').format(x.label || x.mac)), E('span', { 'class': (x.present || x.off) ? '' : 'ispt-warn-text' },
				(x.present && !x.off)
					? [ dot(x.quiet ? 'warn' : 'ok'), _('on %s, for %s').format(x.port, fmtDur(rnow() - x.since)) +
						(x.quiet ? ' · ' + _('silent for %s').format(fmtDur(rnow() - x.active)) : '') +
						/* its own IGMP reports (isp-tester-tsmon): told apart from another decoder on the same port */
						((x.groups || []).length ? ' · ' + (x.igmp ? _('reports %s') : _('channels on its port: %s')).format(
							x.groups.map(function(g) { return chLabel(t, g); }).join(', ')) : '') ]
					: [ dot(x.off ? 'unknown' : 'fail'), (x.off ? _('off / unplugged since %s') : _('not visible for %s')).format(
						x.off ? hhmm(x.since) : fmtDur(rnow() - x.since)) + ' (' + x.port + ')' ]));
		});

		/* the decoders' DHCP lease from the operator */
		(t.dhcp || []).forEach(function(x) {
			var bits = [ x.ip || '–' ];
			if (x.lease) bits.push(_('lease %s').format(fmtDur(x.lease)));
			if (x.last_ack) bits.push(_('renewed %s ago').format(fmtDur(rnow() - x.last_ack)));
			bits.push(_('%d renewals').format(x.renew));
			var bad = [];
			if (x.changes) bad.push(_('IP changed %d×').format(x.changes));
			if (x.naks) bad.push(_('refused %d×').format(x.naks));
			if (x.expired) bad.push(_('lease expired'));
			decs.push(E('span', { 'class': 'k', 'title': _('Seen from the operator\'s DHCP replies (%s)').format(x.via === 'dnsmasq' ? 'dnsmasq' : _('in the IPTV VLAN')) },
				_('DHCP %s').format(x.label || x.mac)),
				E('span', { 'class': bad.length ? 'ispt-warn-text' : '' }, bits.join(' · ') + (bad.length ? ' · ' + bad.join(' · ') : '')));
		});

		if (t.quality) {
			var q = t.quality, qe = {
				no_helper: _('needs the isp-tester-tsmon package'),
				no_target: _('no interface to listen on'),
				helper_failed: _('the measuring helper stopped, restarting'),
				helper_stalled: _('the measuring helper does not respond')
			}[q.error], qv;

			if (qe)
				qv = [ dot('warn'), ' ', qe ];
			else if (!q.last)
				qv = _('starting…');
			else if (!q.last.groups || !q.last.groups.length)
				qv = _('no stream right now');
			else
				qv = q.last.groups.map(function(g) {
					var bad = g.cc + g.tei;
					return E('div', {}, [ dot(g.lvl === 'err' ? 'fail' : g.lvl), ' ', chLabel(t, g.grp), ': ',
						bad ? _('%d lost-packet gaps (~%d packets) in the last minute').format(bad, g.lost) : _('no errors in the last minute'),
						g.gap >= 100 ? ' · ' + _('longest pause %d ms').format(g.gap) : '',
						g.total ? ' · ' + _('%d since the channel started').format(g.total) : '' ]);
				});

			head.push(E('span', { 'class': 'k' }, _('Picture quality')), E('span', {}, qv));
			if (q.running && q.since && !qe)
				kv.push(E('span', { 'class': 'k' }, _('Measuring')),
					E('span', {}, _('continuously, every packet, for %s').format(fmtDur(rnow() - q.since))));
			if (q.drop_ts && rnow() - q.drop_ts < 600)
				kv.push(E('span', { 'class': 'k' }, _('Not counted')),
					E('span', {}, [ dot('warn'), ' ', _('%d packets the router was too busy to count (last %s ago) – errors at that time are not logged').format(q.dropped, fmtDur(rnow() - q.drop_ts)) ]));
			if (q.zap_skip)
				kv.push(E('span', { 'class': 'k' }, _('Channel changes')),
					E('span', {}, _('%d errors right after a channel change not counted (zapping away and back restarts the stream at the operator)').format(q.zap_skip)));
		}

		if (t.bridge) {
			igmp.push(E('span', { 'class': 'k' }, t.bridge.per_vlan && t.vlan
					? _('IGMP snooping (%s, VLAN %d)').format(t.bridge.name, t.vlan.id) : _('IGMP snooping (%s)').format(t.bridge.name)),
				E('span', {}, t.bridge.snooping == null ? '–' : (t.bridge.snooping === '1' ? _('on') : _('off'))));
			igmp.push(E('span', { 'class': 'k', 'title': _('Whether this router\'s own querier is switched on. It asks only while no other querier (the ISP) is elected.') }, _('Router\'s querier')),
				E('span', {}, t.bridge.querier == null ? '–' : (t.bridge.querier === '1' ? _('on') : _('off'))));
		}
		if (t.querier && t.querier.who && t.querier.who !== 'off') {
			var qr = t.querier, qwho, qlvl = 'ok';
			switch (qr.who) {
			case 'isp':    qwho = _('the ISP') + (qr.addr ? ' · ' + qr.addr : '') + (qr.port ? ' (' + qr.port + ')' : ''); break;
			case 'other':  qwho = _('another device') + ' · ' + (qr.addr || '?') + (qr.port ? ' (' + qr.port + ')' : ''); qlvl = 'warn'; break;
			case 'router': qwho = _('this router'); break;
			case 'wire':   qwho = _('an unelected querier') + ' · ' + (qr.addr || '0.0.0.0'); break;
			default:       qwho = _('nobody – the channels will expire'); qlvl = 'fail';
			}
			if ((qr.reasons || []).some(function(r) { return r.c === 'querier_block_fail'; })) qlvl = 'warn';
			var qv = [ dot(qlvl), qwho ];
			if (qr.since) qv.push(' · ' + _('since %s').format(fmtWhen(qr.since)));
			igmp.push(E('span', { 'class': 'k', 'title': _('Who sends the IGMP queries on the IPTV VLAN right now, as elected by the bridge. Every change is in the timeline.') }, _('Asks now')),
				E('span', {}, qv));
			if (qr.mode && qr.mode !== 'unmanaged') {
				var modeTxt = { off: _('the ISP alone'), backup: _('the ISP, the router as a backup'), router: _('only the router') }[qr.mode] || qr.mode;
				var bad = (qr.diff && qr.diff.length) || (qr.script && qr.script.err);
				var mv = [ dot(bad ? 'warn' : 'ok'), _('set: %s').format(modeTxt) ];
				if (qr.diff && qr.diff.length) mv.push(' · ' + _('the bridge differs (%s)').format(qr.diff.join(', ')));
				if (qr.nft && qr.nft.ok) mv.push(' · ' + _('ISP queries blocked: %d').format(qr.nft.drops || 0) +
					(qr.nft.last ? ' (' + _('last %s ago').format(fmtDur(rnow() - qr.nft.last)) + ')' : ''));
				if (qr.nft && qr.nft.ok && qr.nft.out != null) mv.push(' · ' + _('own queries kept from the ISP: %d').format(qr.nft.out));
				igmp.push(E('span', { 'class': 'k', 'title': _('Settings → IPTV → IGMP querier, kept in the system script /etc/hotplug.d/iface/99-iptv-querier.') }, _('Querier setup')), E('span', {}, mv));
			}
		}

		if (t.igmpq) {
			var iq = t.igmpq, qs;
			if (iq.gen > 0)
				qs = [ dot(iq.silent ? 'fail' : 'ok'), _('last query %s ago').format(fmtDur(iq.age)) + ' · ' + _('every ~%s').format(fmtDur(iq.expected)) +
					(iq.src ? ' · ' + iq.src : '') + (iq.ver ? ' (IGMPv' + iq.ver + ')' : '') + (iq.silent ? ' · ' + _('SILENT, memberships can expire') : '') ];
			else
				qs = [ dot(iq.never ? 'warn' : 'ok'), iq.never ? _('none seen in %s').format(fmtDur(iq.seen_for)) : _('waiting for the first query') ];
			igmp.push(E('span', { 'class': 'k', 'title': _('General IGMP queries sent by the operator on the IPTV VLAN, seen by the router. Without them the memberships time out.') },
				_('ISP IGMP queries')), E('span', {}, qs));
		}
		if (t.bridge && t.bridge.membership_interval)
			igmp.push(E('span', { 'class': 'k', 'title': _('Settings of this router\'s bridge, not what the operator sends – see "ISP IGMP queries".') }, _('IGMP timers')), E('span', {},
				_('membership %d s, query %d s').format(t.bridge.membership_interval, t.bridge.query_interval || 0)));
		if (t.bridge && t.bridge.mdb)
			igmp.push(E('span', { 'class': 'k' }, _('Bridge groups')), E('span', { 'class': 'ispt-groups' },
				t.bridge.mdb.length ? groupsByPort(t.bridge.mdb, t) : _('none')));
		if (t.igmp) {
			var ig = t.igmp;
			if (!v || ig.proxy_seen) igmp.push(E('span', { 'class': 'k' }, _('Multicast proxy')), E('span', {},
				ig.proxy_running ? [ dot('ok'), ig.proxy ] : ig.proxy_seen ? [ dot('fail'), _('%s not running').format(ig.proxy) ] : _('none found')));
			if (ig.dev && !v)
				igmp.push(E('span', { 'class': 'k' }, _('Channels joined (%s)').format(ig.dev)), E('span', { 'class': 'ispt-groups' },
					!ig.found ? _('device not in IGMP table') :
					(ig.groups && ig.groups.length ? ig.groups.map(function(g) { return chLabel(t, g); }).join(', ') : _('none')) + (ig.version ? ' · IGMP' + ig.version.replace('V', 'v') : '') +
					(ig.last_change ? ' · ' + _('changed %s ago').format(fmtDur(rnow() - ig.last_change)) : '')));
		}

		return E('div', { 'class': 'ispt-card l-' + lvl(t.level) }, [
			E('h3', {}, [ _('IPTV'), chip(t.level) ]),
			this.reasons(t.reasons),
			kpis,
			this.details('iptv', head, [
				[ _('Where it is measured'), where ], [ _('Picture quality'), kv ], [ _('Decoders'), decs ], [ 'IGMP / multicast', igmp ]
			])
		]);
	},

	renderPorts: function(st) {
		var p = st.ports;
		if (!p || !p.list || !p.list.length)
			return this.disabledCard(_('Ports'), _('Add ports to watch in Settings.'));

		var up = 0, errs = 0, drops = 0, flaps = 0;
		var rows = p.list.map(function(x) {
			var link = !x.present ? E('span', { 'class': 'ispt-warn-text' }, _('missing'))
				: x.up ? fmtSpeed(x.speed) + (x.duplex && x.duplex !== 'full' ? ' ' + x.duplex : '')
				: E('span', { 'class': x.level === 'fail' ? 'ispt-warn-text' : 'ispt-muted' }, _('down'));
			var tot = x.totals || {};
			var e = (tot.rx_errors || 0) + (tot.tx_errors || 0), d = (tot.rx_dropped || 0) + (tot.tx_dropped || 0);
			if (x.up) up++;
			errs += e; drops += d; flaps += tot.carrier_changes || 0;
			return E('tr', { 'title': (x.reasons || []).map(reasonText).join('\n') }, [
				E('td', {}, [ dot(x.level), x.label ? E('span', {}, [ x.label, ' ', E('span', { 'class': 'ispt-muted' }, x.dev) ]) : x.dev ]),
				E('td', { 'style': 'white-space:nowrap' }, link),
				E('td', { 'class': 'n' }, x.up ? fmtDur(rnow() - x.since) : '–'),
				numCell(e, true),
				numCell(d, false),
				numCell(tot.carrier_changes, false)
			]);
		});

		var reasons = [];
		p.list.forEach(function(x) { (x.reasons || []).forEach(function(r) { reasons.push(r); }); });

		var n = p.list.length;
		var kpis = E('div', { 'class': 'ispt-kpis' }, [
			kpi(_('Links up'), num(up) + ' / ' + num(n), '', up < n ? lvl(p.level) : 'ok'),
			kpi(_('Errors'), num(errs), '', errs ? 'warn' : 'ok', _('Total errors since boot')),
			kpi(_('Dropped'), num(drops), '', 'ok', _('Total dropped packets since boot')),
			kpi(_('Flaps'), num(flaps), '', 'ok', _('Link state changes since boot'))
		]);

		return E('div', { 'class': 'ispt-card l-' + lvl(p.level) }, [
			E('h3', {}, [ _('Ports'), chip(p.level) ]),
			this.reasons(reasons),
			kpis,
			E('table', { 'class': 'ispt-mini' }, [
				E('tr', {}, [ E('th', {}, _('Port')), E('th', {}, _('Link')), E('th', { 'class': 'n' }, _('Up for')),
					E('th', { 'class': 'n', 'title': _('Total errors since boot') }, _('Err')),
					E('th', { 'class': 'n', 'title': _('Total dropped packets since boot') }, _('Drop')),
					E('th', { 'class': 'n', 'title': _('Link state changes since boot') }, _('Flaps')) ])
			].concat(rows)),
			E('div', { 'class': 'ispt-muted', 'style': 'font-size:.8em;margin-top:.4em' }, _('Counters since the router started.'))
		]);
	},

	renderPeers: function(st) {
		var pl = (st.peers && st.peers.list) || [];
		return pl.map(function(p) {
			var hb = p.hb || {}, kv = [];
			kv.push(E('span', { 'class': 'k' }, _('Reports')), E('span', { 'class': p.online ? '' : 'ispt-warn-text' },
				p.online ? _('%s ago from %s').format(fmtDur(rnow() - p.seen), p.addr || '?')
					: _('nothing for %s (last from %s)').format(fmtDur(rnow() - p.seen), p.addr || '?')));
			if (p.online && hb.up)
				kv.push(E('span', { 'class': 'k' }, _('Monitoring for')), E('span', {}, fmtDur(rnow() - hb.up)));
			if (p.off)
				kv.push(E('span', { 'class': 'k' }, _('Clock')), E('span', { 'class': 'ispt-warn-text' },
					_('off by %d s – its events are moved to this router\'s time').format(p.off)));
			if (hb.iptv)
				kv.push(E('span', { 'class': 'k' }, _('IPTV')), E('span', {}, [ dot(hb.iptv.lvl),
					({ playing: _('Stream running'), stalled: _('STREAM STOPPED'), idle: _('No stream (decoder off?)') }[hb.iptv.state] || hb.iptv.state) +
					(hb.iptv.kbps ? ' · ' + fmtRate(hb.iptv.kbps) : '') ]));
			((hb.iptv && hb.iptv.dec) || []).forEach(function(x) {
				kv.push(E('span', { 'class': 'k' }, _('Decoder %s').format(x.label)), E('span', {}, [ dot(x.up ? 'ok' : 'fail'),
					x.up ? _('on %s').format(x.port) : _('not visible (%s)').format(x.port) ]));
			});
			(hb.ports || []).forEach(function(x) {
				kv.push(E('span', { 'class': 'k' }, x.label ? '%s (%s)'.format(x.label, x.dev) : x.dev),
					E('span', {}, [ dot(x.lvl), x.up ? fmtSpeed(x.speed) : _('down') ]));
			});
			return E('div', { 'class': 'ispt-card l-' + lvl(p.level) }, [
				E('h3', {}, [ _('Router %s').format(p.name), chip(p.level) ]),
				E('div', { 'class': 'ispt-kv' }, kv),
				E('div', { 'class': 'ispt-muted', 'style': 'font-size:.85em;margin-top:.4em' },
					_('Its events are on the timeline below, marked with its name.'))
			]);
		});
	},

	disabledCard: function(title, hint) {
		return E('div', { 'class': 'ispt-card l-unknown' }, [
			E('h3', {}, [ title, chip('unknown') ]),
			E('div', { 'class': 'ispt-muted' }, hint || _('Disabled in Settings.'))
		]);
	},

	reasons: function(list) {
		if (!list || !list.length) return '';
		return E('ul', { 'class': 'ispt-reasons', 'role': 'alert' }, list.map(function(r) {
			return E('li', {}, '⚠ ' + reasonText(r));
		}));
	},

	/* the rows of a card: 'head' always shown, the sections folded under
	 * "More details" - except rows that show a problem, which stay visible.
	 * The folded state is kept over the 5 s refresh. */
	details: function(key, head, sections) {
		var self = this, shown = head.slice(), more = [];
		this.opened = this.opened || {};

		sections.forEach(function(sec) {
			var kv = sec[1], rest = [];
			for (var i = 0; i + 1 < kv.length; i += 2) {
				if (isAlert(kv[i + 1])) shown.push(kv[i], kv[i + 1]);
				else rest.push(kv[i], kv[i + 1]);
			}
			if (rest.length) more.push(E('div', { 'class': 'ispt-sec' }, sec[0]), E('div', { 'class': 'ispt-kv' }, rest));
		});

		return E([], [
			shown.length ? E('div', { 'class': 'ispt-kv', 'style': 'margin-top:.6em' }, shown) : '',
			more.length ? E('details', {
				'class': 'ispt-more',
				'open': this.opened[key] ? '' : null,
				'toggle': function(ev) { self.opened[key] = ev.target.open; }
			}, [ E('summary', {}, _('More details')) ].concat(more)) : ''
		]);
	},

	/* ---- charts */
	renderCharts: function(st, w) {
		var cd = this.chartData(st, w);
		var h = cd.h, t = h.t || [], s = h.s || {};
		var out = [];
		var lossMax = function(data) { return data.some(function(v) { return v >= 100; }); };

		if (s.lvl)
			out.push(statusRibbon(t, s.lvl, w.from, w.to, gapsIn(this.events(), w.from, w.to), maintIn(this.events(), w.from, w.to, this.now())));

		var targets = (st.wan && st.wan.targets) || [];
		/* a target that never answers has only a loss series (rtt is always null) */
		var labels = [];
		Object.keys(s).forEach(function(k) {
			var m = /^(rtt|loss):(.*)$/.exec(k);
			if (m && labels.indexOf(m[2]) < 0) labels.push(m[2]);
		});
		if (labels.length) {
			var series = [], lossBands = [];
			labels.forEach(function(label, i) {
				var tg = targets.filter(function(x) { return x.label === label; })[0];
				var loss = s['loss:' + label] || [];
				var jit = s['jit:' + label] || [];
				series.push({ name: targetName(label, tg && tg.host), color: COLORS[i % COLORS.length], data: s['rtt:' + label] || t.map(function() { return null; }), loss: loss,
					fmt: (function(l, j) { return function(v, k) {
						return fmtMs(v) + (j[k] != null ? ' · ' + _('jitter %s').format(fmtMs(j[k])) : '') + (l[k] > 0 ? ' · ' + _('loss %d%%').format(l[k]) : '');
					}; })(loss, jit) });
				lossBands = lossBands.concat(bandsFor(t, function(k) { return loss[k] > 0; }, lossMax(loss) ? '#d64541' : '#e0a100', _('Packet loss')));
			});
			out.push(lineChart(t, series, { from: w.from, to: w.to, title: _('Ping (ms) – red/yellow background = packet loss'), bands: lossBands, min_max: 20, legend: true }));
		}

		if (s['iptv:kbps']) {
			var kb = s['iptv:kbps'];
			/* stall periods come from the events: an idle decoder (0 kbit/s) is not a fault */
			/* this router's stream only (the second router measures its own) */
			var evs = this.ownAsc();
			var stallBands = [];
			evs.forEach(function(e, i) {
				if (e.type !== 'stream_stall') return;
				var end = null;
				for (var j = i + 1; j < evs.length; j++)
					if (evs[j].type === 'stream_resume' || evs[j].type === 'stream_lost' || evs[j].type === 'monitor_start' || evs[j].type === 'data_gap') { end = evs[j].ts; break; }
				if (end == null) end = (st.iptv && st.iptv.state === 'stalled') ? st.ts : e.ts + (st.interval || 10);
				if (end >= w.from && e.ts <= w.to)
					stallBands.push({ from: e.ts, to: end, color: '#d64541', title: _('Stream stopped for %s').format(fmtDur(end - e.ts)) });
			});
			var ibr = [ {
				name: cd.fine ? _('IPTV bitrate') : _('IPTV bitrate (1 min average)'), color: '#7a59c0',
				data: kb.map(function(v) { return v == null ? null : v / 1000; }),
				fmt: function(v) { return fmtRate(v * 1000); }
			} ];
			/* lowest 1 s value per point: shows freezes shorter than the chart step */
			if (s['iptv:min'] && s['iptv:min'].some(function(v, k) { return v != null && kb[k] != null && v < kb[k] * 0.8; }))
				ibr.push({
					name: _('Lowest 1 s bitrate'), color: '#d64541',
					data: s['iptv:min'].map(function(v) { return v == null ? null : v / 1000; }),
					fmt: function(v) { return fmtRate(v * 1000); }
				});
			out.push(lineChart(t, ibr, {
				legend: ibr.length > 1,
				from: w.from, to: w.to,
				title: _('IPTV bitrate (Mbit/s) – red = stream stopped while watching'),
				bands: stallBands,
				fmt: function(v) { return num(v, 1); },
				min_max: 1
			}));
		}

		if (s['wan:rx']) {
			var evs2 = this.ownAsc();
			var bloatBands = [];
			evs2.forEach(function(e, i) {
				if (e.type !== 'bufferbloat') return;
				var end = null;
				for (var j = i + 1; j < evs2.length; j++)
					if (evs2[j].type === 'bufferbloat_ok' || evs2[j].type === 'monitor_start' || evs2[j].type === 'data_gap') { end = evs2[j].ts; break; }
				if (end == null) end = (st.wan && st.wan.bloat && st.wan.bloat.active) ? st.ts : e.ts + 60;
				if (end >= w.from && e.ts <= w.to)
					bloatBands.push({ from: e.ts, to: end, color: '#e0a100', title: _('Bufferbloat: ping +%d ms').format(e.d.add) });
			});
			var mb = function(v) { return v == null ? null : v / 1000; };
			out.push(lineChart(t, [
				{ name: _('Download'), color: '#3b6fc0', data: s['wan:rx'].map(mb), fmt: function(v) { return fmtRate(v * 1000); } },
				{ name: _('Upload'), color: '#2a9d5b', data: (s['wan:tx'] || []).map(mb), fmt: function(v) { return fmtRate(v * 1000); } }
			], { from: w.from, to: w.to, title: _('WAN traffic (Mbit/s) – yellow = bufferbloat (ping up while the link is full)'),
				bands: bloatBands, fmt: function(v) { return num(v, v < 10 ? 1 : 0); }, min_max: 1, legend: true }));
		}

		if (s['sfp:rx'] && s['sfp:rx'].some(function(v) { return v != null; })) {
			/* dBm are negative and the chart starts at 0: shifted by 40, the axis labels shift back */
			var evs3 = this.ownAsc();
			var sfpBands = [];
			evs3.forEach(function(e, i) {
				if (e.type !== 'sfp_rx_drop' && e.type !== 'sfp_los') return;
				var okt = e.type + '_ok', end = null;
				for (var j = i + 1; j < evs3.length; j++)
					if (evs3[j].type === okt || evs3[j].type === 'monitor_start' || evs3[j].type === 'data_gap') { end = evs3[j].ts; break; }
				if (end == null) end = st.ts;
				if (end >= w.from && e.ts <= w.to)
					sfpBands.push({ from: e.ts, to: end, color: '#d64541', title: e.type === 'sfp_los' ? _('No light') : _('Weaker signal') });
			});
			var dbm = function(v) { return v == null ? null : v + 40; };
			var sser = [ { name: _('RX power'), color: '#2a9d5b', data: s['sfp:rx'].map(dbm), fmt: function(v) { return num(v - 40, 1) + ' dBm'; } } ];
			if (s['sfp:tx'] && s['sfp:tx'].some(function(v) { return v != null; }))
				sser.push({ name: _('TX power'), color: '#7a59c0', data: s['sfp:tx'].map(dbm), fmt: function(v) { return num(v - 40, 1) + ' dBm'; } });
			out.push(lineChart(t, sser, { from: w.from, to: w.to, bands: sfpBands, legend: true, min_max: 40,
				title: _('Optical power of the SFP module (dBm) – red background = signal weaker / no light'),
				fmt: function(v) { return Math.round(v - 40); } }));
		}

		var errSeries = [], ci = 0;
		Object.keys(s).forEach(function(k) {
			if (k.indexOf('err:') !== 0) return;
			var data = s[k];
			if (!data.some(function(v, i) { return v > 0 && t[i] >= w.from && t[i] <= w.to; })) return;
			errSeries.push({ name: k.substr(4), color: COLORS[ci++ % COLORS.length], data: data });
		});
		if (errSeries.length)
			out.push(lineChart(t, errSeries, { from: w.from, to: w.to, title: cd.fine ? _('Interface errors per interval') : _('Interface errors per minute'), min_max: 1, legend: true }));

		var hasData = t.some(function(ts) { return ts >= w.from && ts <= w.to; });

		/* dom.append does not flatten nested arrays: an array child would be stringified to "[object HTMLDivElement],…" */
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('History')),
			this.renderNav()
		].concat(hasData ? out : [ E('div', { 'class': 'ispt-muted' },
			t.length ? _('No data for this period (data is kept in RAM for up to 24 h and is lost on reboot).') : _('Collecting data…')) ]));
	},

	/* ---- when do problems happen */
	renderHours: function(w) {
		var from = w.live && this.range < 24 * 3600 ? this.now() - 24 * 3600 : w.from;
		var h = hourHistogram(this.events(), from, w.to);
		var max = Math.max.apply(null, h);
		if (!max) return '';
		var lbl = [];
		for (var i = 0; i < 24; i++) lbl.push(E('span', {}, (i % 3 === 0) ? String(i) : ''));
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('When do problems happen')),
			E('div', { 'class': 'ispt-muted', 'style': 'font-size:.9em' },
				_('Problems per hour of the day (%s). A peak in the evening points at an overloaded ISP network.').format(
					fmtShort(from) + ' – ' + fmtShort(w.to))),
			E('div', { 'class': 'ispt-hours' }, h.map(function(n, i) {
				return E('div', { 'class': n ? '' : 'zero', 'style': 'height:' + Math.max(1, Math.round(n * 100 / max)) + '%',
					'title': _('%02d:00–%02d:59: %d problems').format(i, i, n) });
			})),
			E('div', { 'class': 'ispt-hours-lbl' }, lbl)
		]);
	},

	/* ---- printable report for the ISP */
	/* which days and hours the report (or the timeline CSV) covers */
	reportDialog: function() {
		var self = this, w = this.win(), nowTs = this.now();
		var oldest = nowTs - 86400;
		var mode = 'window';
		var dFrom = E('input', { 'type': 'date', 'class': 'cbi-input-text', 'value': dayStr(Math.max(oldest, nowTs - 6 * 86400)),
			'min': dayStr(oldest), 'max': dayStr(nowTs) });
		var dTo = E('input', { 'type': 'date', 'class': 'cbi-input-text', 'value': dayStr(nowTs), 'min': dayStr(oldest), 'max': dayStr(nowTs) });
		var hsel = function(v, max) {
			var s = E('select', { 'class': 'cbi-input-select' });
			for (var i = (max === 24 ? 1 : 0); i <= max; i++) s.appendChild(E('option', { 'value': i, 'selected': i === v ? '' : null }, '%02d:00'.format(i % 24)));
			return s;
		};
		var hFrom = hsel(18, 23), hTo = hsel(24, 24);
		var allDay = E('input', { 'type': 'checkbox', 'checked': '' });
		var setHours = function(f, t) { if (f == null) { allDay.checked = true; } else { allDay.checked = false; hFrom.value = f; hTo.value = t; } sync(); };
		var radio = function(v, label) {
			return E('label', { 'style': 'display:block;margin:.3em 0' }, [ E('input', { 'type': 'radio', 'name': 'ispt-rp', 'value': v, 'checked': v === mode ? '' : null,
				'change': function() { mode = v; sync(); } }), ' ', label ]);
		};
		var days = E('div', { 'style': 'margin:.2em 0 .4em 1.6em;display:flex;gap:.5em;align-items:center;flex-wrap:wrap' }, [ _('from'), dFrom, _('to'), dTo ]);
		var hours = E('div', { 'style': 'display:flex;gap:.5em;align-items:center;flex-wrap:wrap' }, [ _('from'), hFrom, _('to'), hTo ]);
		var sync = function() {
			days.style.opacity = mode === 'days' ? 1 : .45;
			dFrom.disabled = dTo.disabled = mode !== 'days';
			hours.style.opacity = allDay.checked ? .45 : 1;
			hFrom.disabled = hTo.disabled = allDay.checked;
		};
		allDay.addEventListener('change', sync);

		var pick = function() {
			var pw = w;
			if (mode === 'days') {
				var f = dayTs(dFrom.value), t = dayTs(dTo.value);
				if (f == null || t == null) return null;
				if (t < f) { var x = f; f = t; t = x; }
				var e = new Date((t + 43200) * 1000);
				pw = { from: f, to: Math.min(nowTs, new Date(e.getFullYear(), e.getMonth(), e.getDate() + 1).getTime() / 1000 - 1), live: false };
			}
			var hr = allDay.checked ? null : { from: +hFrom.value, to: +hTo.value };
			if (hr && hr.from === hr.to % 24) hr = null;
			return { w: pw, hr: hr };
		};

		var btn = function(cls, label, fn) {
			return E('button', { 'class': 'cbi-button ' + cls, 'click': function() { var p = pick(); if (!p) return; ui.hideModal(); fn(p); } }, label);
		};

		ui.showModal(_('Report for the ISP'), [
			E('p', {}, _('Choose the period and, if the problem shows only at certain times (e.g. in the evening when you watch TV), the hours of the day. Everything – the summary, the assessment, the event list and the measurement coverage – then counts only those hours.')),
			E('h4', {}, _('Days')),
			radio('window', _('The period shown in the charts: %s').format(fmtShort(w.from, true) + ' – ' + fmtShort(w.to, true))),
			radio('days', _('Chosen days')), days,
			E('div', { 'class': 'ispt-muted', 'style': 'font-size:.85em' }, _('Only the last 24 h of measurements and the timeline kept on the router are available here. Older files are on the device the data is sent to (Settings → Send data to another device).')),
			E('h4', {}, _('Hours of the day')),
			E('label', { 'style': 'display:block;margin:.3em 0' }, [ allDay, ' ', _('The whole day') ]),
			hours,
			E('div', { 'style': 'margin:.4em 0;display:flex;gap:.4em;flex-wrap:wrap' }, [
				E('button', { 'class': 'cbi-button', 'click': function() { setHours(18, 24); } }, _('Evening 18–24')),
				E('button', { 'class': 'cbi-button', 'click': function() { setHours(18, 23); } }, _('18–23')),
				E('button', { 'class': 'cbi-button', 'click': function() { setHours(6, 18); } }, _('Daytime 6–18')),
				E('button', { 'class': 'cbi-button', 'click': function() { setHours(null); } }, _('Whole day'))
			]),
			E('div', { 'class': 'right', 'style': 'margin-top:1em' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
				btn('cbi-button-action', _('Download timeline (CSV)'), function(p) { self.exportRange(p.w, p.hr); }), ' ',
				btn('cbi-button-positive', _('Open report'), function(p) { self.openReport(p.w, p.hr); })
			])
		]);
		sync();
	},

	openReport: function(w, hr) {
		var self = this;
		w = w || this.win();
		if (!(this.last && this.last[0] && this.last[0].state)) return Promise.resolve();
		var win = window.open('', '_blank');
		if (win) win.document.write('<p style="font:14px sans-serif">' + esc(_('Preparing the report…')) + '</p>');
		self.writeReport(w, win, hr);
		return Promise.resolve();
	},

	/* the timeline of any period and hours, from what is loaded */
	exportRange: function(w, hr) {
		var list = this.events().filter(function(e) { return e.ts >= w.from && e.ts <= w.to && inHours(e.ts, hr); }).reverse();
		var lines = [ 'time,level,router,area,source,event,message' ];
		list.forEach(function(e) {
			lines.push([ isoTime(e.ts), e.lvl, e.host || '', e.area, e.src, e.type, eventText(e) ].map(csvCell).join(','));
		});
		download('isp-tester-events-' + dayStr(w.from) + '_' + dayStr(w.to) + (hr ? '_%02d-%02d'.format(hr.from, hr.to) : '') + '.csv', lines.join('\n') + '\n');
	},

	writeReport: function(w, win, hr) {
		var res = this.last && this.last[0], st = res && res.state;
		var r = this.analyze(st, w, hr);
		var inWin = this.events().filter(function(e) { return e.ts >= w.from && e.ts <= w.to; }).sort(function(a, b) { return a.ts - b.ts; });
		/* events of the chosen hours; start/end pairs below use all of them */
		/* what happened during maintenance is not counted (e.m) */
		var evs = inWin.filter(function(e) { return inHours(e.ts, hr) && !e.m; });
		var ownAll = inWin.filter(function(e) { return !e.host; });
		var own = evs.filter(function(e) { return !e.host; });

		/* a freeze while a decoder restarted (on either router) is not the ISP's */
		var decR = inWin.filter(function(e) { return e.type === 'decoder_restart'; });
		/* (as in the analysis) not while the operator sent no IGMP queries: a
		 * decoder that only watches is silent then and looks restarted */
		var noQ = [], qOpen = null;
		ownAll.forEach(function(e) {
			if ((e.type === 'igmp_noquery' || e.type === 'igmp_noquery_ok') && e.d && e.d.router) { /* the router asked: no effect */ }
			else if (e.type === 'igmp_noquery') { if (qOpen == null) qOpen = e.ts; }
			else if (qOpen != null && (e.type === 'igmp_noquery_ok' || e.type === 'monitor_start' || e.type === 'data_gap')) { noQ.push([ qOpen, e.ts ]); qOpen = null; }
		});
		if (qOpen != null) noQ.push([ qOpen, w.to ]);
		var byDecoder = function(s) {
			if (noQ.some(function(p) { return s.ts >= p[0] - 30 && s.ts <= p[1] + 30; })) return false;
			return decR.some(function(r) { return !(r.d && r.d.alone === false) && s.ts >= r.ts - 15 && s.ts <= r.ts + ((r.d && r.d.dur) || 0) + 10; });
		};

		/* outage / freeze durations from start/end pairs (this router's
		 * measurements); with hours chosen: those that overlap them, the total
		 * counting only the time within them */
		var sum = function(startType, endTypes) {
			var n = 0, total = 0, longest = 0;
			ownAll.forEach(function(e, i) {
				if (e.type !== startType || e.m) return;
				if (startType === 'stream_stall' && byDecoder(e)) return;
				var d = null;
				for (var j = i + 1; j < ownAll.length; j++)
					if (endTypes.indexOf(ownAll[j].type) >= 0 || ownAll[j].type === 'data_gap' || ownAll[j].type === 'monitor_start') {
						/* a channel change is not a freeze */
						if (ownAll[j].d && ownAll[j].d.igmp === 'zap') return;
						/* not measured any more: it lasted at least until then */
						var cut = ownAll[j].type === 'data_gap' || ownAll[j].type === 'monitor_start';
						d = (!cut && ownAll[j].d && ownAll[j].d.dur) || (ownAll[j].ts - e.ts);
						break;
					}
				/* still going at the end of the period */
				if (d == null) d = Math.max(0, w.to - e.ts);
				var inside = clipLen(e.ts, e.ts + Math.max(d, 1), hr);
				if (hr && !inside) return;
				total += hr ? inside : d;
				if (d > longest) longest = d;
				n++;
			});
			return { n: n, total: total, longest: longest };
		};
		var net = sum('wan_down', [ 'wan_up', 'monitor_start' ]);
		var tv = sum('stream_stall', [ 'stream_resume', 'stream_lost', 'monitor_start' ]);
		var count = function(f) { return own.filter(f).length; };
		var hostArea = function(e) { return (e.host ? e.host + ' · ' : '') + areaName(e.area); };
		var peerNames = ((st.peers && st.peers.list) || []).map(function(p) { return p.name; }).join(', ');

		/* times without measurements, and how much of the period was measured */
		var allEv = this.events();
		var gaps = gapsIn(allEv, w.from, w.to);
		var firstTs = allEv.reduce(function(m, e) { return (!e.host && e.ts < m) ? e.ts : m; }, Infinity);
		if (firstTs > w.from + 60 && firstTs < w.to)
			gaps.unshift({ from: w.from, to: firstTs, why: 'before' });
		var unmeasured = 0;
		gaps = gaps.filter(function(g) { return clipLen(Math.max(g.from, w.from), Math.min(g.to, w.to), hr) > 0; });
		gaps.forEach(function(g) { unmeasured += clipLen(Math.max(g.from, w.from), Math.min(g.to, w.to), hr); });
		var coverage = Math.max(0, 100 - unmeasured * 100 / Math.max(1, clipLen(w.from, w.to, hr)));

		var x = function(v) { return String(v == null ? '' : v).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); };
		var row = function(k, v) { return '<tr><th>' + x(k) + '</th><td>' + x(v) + '</td></tr>'; };
		var h = hourHistogram(evs, w.from, w.to), hmax = Math.max.apply(null, h) || 1;
		var targets = ((st.wan && st.wan.targets) || []).map(function(t) { return targetName(t.label, t.host); }).join(', ');

		var html = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>' + x(_('Connection fault report')) + '</title><style>' +
			'body{font:14px/1.45 sans-serif;margin:2em;color:#222}h1{font-size:1.5em;margin:0}h2{font-size:1.15em;margin:1.4em 0 .4em;border-bottom:1px solid #ccc}' +
			'table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:.25em .5em;border-bottom:1px solid #eee;vertical-align:top}th{width:35%;font-weight:600}' +
			'.ev td:first-child{white-space:nowrap;width:11em}.err td{color:#b02a26}.hours{display:flex;align-items:flex-end;gap:2px;height:80px}' +
			'.hours div{flex:1;background:#d4774a}.hl{display:flex;gap:2px;font-size:.75em}.hl span{flex:1;text-align:center}' +
			'.muted{color:#777;font-size:.9em}@media print{button{display:none}}</style></head><body>' +
			'<button onclick="window.print()" style="float:right">' + x(_('Print / save as PDF')) + '</button>' +
			'<h1>' + x(_('Connection fault report')) + '</h1>' +
			'<p class="muted">' + x(_('Period: %s – %s · generated %s by luci-app-isp-tester').format(fmtTime(w.from), fmtTime(w.to), fmtTime(rnow()))) + '</p>' +
			(hr ? '<p><b>' + x(_('Only the hours %s are counted in this report.').format(hoursText(hr))) + '</b></p>' : '') +
			'<h2>' + x(_('Measurement coverage')) + '</h2><table>' +
			row(_('Measured'), _('%s%% of the period').format(num(coverage, coverage >= 99.95 ? 0 : 1)) +
				(gaps.length ? ' · ' + _('not measured: %s in %d periods (listed below)').format(fmtDur(unmeasured), gaps.length) : ' · ' + _('without interruption'))) +
			row(_('Router restarts'), _('%d×').format(allEv.filter(function(e) { return e.type === 'router_reboot' && !e.host && e.ts >= w.from && e.ts <= w.to; }).length)) +
			row(_('Monitor restarts (crash / watchdog)'), _('%d×').format(allEv.filter(function(e) { return e.type === 'collector_restart' && !e.host && e.ts >= w.from && e.ts <= w.to; }).length)) +
			(st.self && st.self.avg != null ? row(_('Load of the tester itself'), _('average %s%%, at most %s%% of the router\'s CPU, RAM %s (since %s) – the measurement does not load the router').format(
				fmtPct((st.self.avg || 0) + (st.self.tsmon ? st.self.tsmon.cpu || 0 : 0)), fmtPct(st.self.max + (st.self.tsmon ? st.self.tsmon.max || 0 : 0)),
				fmtKB(st.self.rss_total), fmtTime(st.started))) : '') +
			(function() {
				var ms = maintIn(allEv, w.from, w.to, rnow()), len = 0;
				ms.forEach(function(m) { len += clipLen(Math.max(m.from, w.from), Math.min(m.to, w.to), hr); });
				if (!ms.length) return '';
				return row(_('Maintenance (excluded)'), _('%d×, %s – the user worked on the network: %s').format(ms.length, fmtDur(len),
					ms.map(function(m) { return fmtShort(m.from) + '–' + hhmm(m.to) + (m.note ? ' (' + m.note + ')' : ''); }).join(', ')));
			})() +
			row(_('Router clock'), (function() {
				var n = st.ntp || {};
				var s = n.state === 'synced' ? _('synchronized by NTP') + (n.stratum != null ? ' (' + _('stratum %s').format(n.stratum) + ')' : '')
					: n.state === 'off' ? _('NO NTP client – times not reliable')
					: n.state === 'unsynced' ? _('NOT synchronized now – times may be off')
					: _('NTP running, no report since boot yet');
				var steps = allEv.filter(function(e) { return e.type === 'clock_step' && !e.host && e.ts >= w.from && e.ts <= w.to; });
				return s + (steps.length ? ' · ' + _('set %d× in the period (entries logged before were corrected)').format(steps.length) : '');
			})()) +
			'</table>' +
			(gaps.length ? '<p class="muted">' + x(_('The router did not measure at these times; nothing in this report covers them:')) + '</p><table class="ev">' +
				gaps.map(function(g) {
					return '<tr><td>' + x(fmtTime(Math.max(g.from, w.from))) + ' – ' + x(fmtTime(Math.min(g.to, w.to))) + '</td><td>' + x(fmtDur(Math.min(g.to, w.to) - Math.max(g.from, w.from))) +
						'</td><td>' + x(g.why === 'before' ? _('monitoring had not started yet (or older data was deleted)') : gapWhy(g.why)) + '</td></tr>';
				}).join('') + '</table>' : '') +
			'<h2>' + x(_('Connection')) + '</h2><table>' +
			row(_('WAN interface / device'), (st.wan ? st.wan.interface + ' / ' + st.wan.device : '–')) +
			(st.wan && st.wan.session ? row(_('Session'), (st.wan.session.proto || '') + ' · ' + (st.wan.session.ip || '')) : '') +
			row(_('Ping targets'), targets || '–') +
			(peerNames ? row(_('Second router'), _('%s (its events are included, marked with its name)').format(peerNames)) : '') +
			(st.iptv ? row(_('IPTV measured on'), st.iptv.vlan ? _('VLAN %d on %s').format(st.iptv.vlan.id, st.iptv.vlan.bridge || '?') : st.iptv.device + ' (' + (st.iptv.direction === 'tx' ? _('outgoing') : _('incoming')) + ')') : '') +
			'</table><h2>' + x(_('Summary')) + '</h2><table>' +
			row(_('Internet outages'), _('%d, total %s, longest %s').format(net.n, fmtDur(net.total), fmtDur(net.longest))) +
			row(_('Packet loss at the ISP gateway'), _('%d×').format(count(function(e) { return e.src === 'gateway' && (e.type === 'target_degraded' || e.type === 'target_fail') && e.d && e.d.loss > 0; }))) +
			row(_('Packet loss to far targets'), _('%d×').format(count(function(e) { return e.area === 'wan' && e.src !== 'gateway' && e.src !== 'dns' && e.src !== 'netifd' && !(e.d && e.d.fam === 6) && (e.type === 'target_degraded' || e.type === 'target_fail') && e.d && e.d.loss > 0; }))) +
			row(_('WAN session drops (PPPoE/DHCP)'), _('%d×').format(count(function(e) { return e.type === 'wan_reconnect' || e.type === 'wan_if_down'; }))) +
			row(_('WAN port link drops'), _('%d×').format(count(function(e) { return e.type === 'link_down' && e.area === 'wan'; }))) +
			(st.wan && st.wan.v6 && st.wan.v6.found ? row(_('IPv6 outages (IPv4 working)'), (function() { var v = sum('v6_down', [ 'v6_up', 'monitor_start' ]); return _('%d, total %s, longest %s').format(v.n, fmtDur(v.total), fmtDur(v.longest)); })()) +
				row(_('IPv6 prefix lost / changed'), _('%d× / %d×').format(count(function(e) { return e.type === 'v6_pd_lost'; }), count(function(e) { return e.type === 'v6_pd_change'; }))) +
				row(_('No IPv6 router advertisement'), _('%d×').format(count(function(e) { return e.type === 'v6_no_route'; }))) : '') +
			row(_('Related messages in the system log'), _('%d×').format(count(function(e) { return e.type === 'log'; }))) +
			(st.iptv && st.iptv.dhcp && st.iptv.dhcp.length ? row(_('Decoder DHCP: address changes / refused / expired'), _('%d× / %d× / %d×').format(
				count(function(e) { return e.type === 'dhcp_ip_change'; }), count(function(e) { return e.type === 'dhcp_nak'; }),
				count(function(e) { return (e.type === 'dhcp_expired' || e.type === 'dhcp_late') && !(e.d && e.d.unk); }))) : '') +
			row(_('DNS failing (no answer from the upstream server)'), (function() { var v = sum('dns_fail', [ 'dns_ok', 'monitor_start' ]); return _('%d, total %s, longest %s').format(v.n, fmtDur(v.total), fmtDur(v.longest)); })() +
				(count(function(e) { return e.type === 'dns_server_bad'; }) ? ' · ' + _('servers with many failed queries: %s').format(own.filter(function(e) { return e.type === 'dns_server_bad'; }).map(function(e) { return e.src; }).filter(function(v, i, a) { return a.indexOf(v) === i; }).join(', ')) : '')) +
			row(_('IPTV freezes'), _('%d, total %s, longest %s').format(tv.n, fmtDur(tv.total), fmtDur(tv.longest)) + (r.zaps ? ' · ' + _('%d channel changes not counted').format(r.zaps) : '')) +
			row(_('Decoder restarts'), _('%d×').format(evs.filter(function(e) { return e.type === 'decoder_restart'; }).length)) +
			row(_('Router overloaded'), _('%d×').format(count(function(e) { return e.type === 'cpu_high' || e.type === 'mem_low' || e.type === 'conntrack_full'; }))) +
			(st.wan && st.wan.sfp && st.wan.sfp.ok ? row(_('Optical signal (SFP)'), _('weaker %d×, no light %d×').format(count(function(e) { return e.type === 'sfp_rx_drop'; }), count(function(e) { return e.type === 'sfp_los'; })) +
				(st.wan.sfp.rx != null ? ' · ' + _('now RX %s dBm, usually %s dBm, weakest %s dBm since start').format(st.wan.sfp.rx, st.wan.sfp.base != null ? st.wan.sfp.base : '?', st.wan.sfp.min_rx != null ? st.wan.sfp.min_rx : '?') : '')) : '') +
			row(_('Problems reported by the user'), _('%d×').format(count(function(e) { return e.type === 'user_mark'; }))) +
			'</table><h2>' + x(_('Assessment')) + '</h2><p><b>' + x(diagnose.verdictText(r.verdict)) + '</b> (' + x(diagnose.confidenceText(r.confidence)) + ')</p><ul>' +
			r.findings.slice().sort(function(a, b) { return (b.last || 0) - (a.last || 0); }).map(function(f) {
				return '<li>[' + x(diagnose.sideText(f.side)) + '] ' + x(diagnose.findingText(f)) + (f.last ? ' <span class="muted">(' + x(_('last %s').format(fmtShort(f.last))) + ')</span>' : '') + '</li>';
			}).join('') +
			'</ul><h2>' + x(_('Problems by hour of day')) + '</h2><div class="hours">' +
			h.map(function(n) { return '<div style="height:' + Math.max(1, Math.round(n * 100 / hmax)) + '%" title="' + n + '"></div>'; }).join('') +
			'</div><div class="hl">' + h.map(function(n, i) { return '<span>' + i + '</span>'; }).join('') + '</div>' +
			(function() {
				var tr = own.filter(function(e) { return e.type === 'trace' && e.d && (e.d.hops || []).length; });
				if (!tr.length) return '';
				return '<h2>' + x(_('Path snapshots at the moment of a loss')) + '</h2><p class="muted">' +
					x(_('Taken automatically when a loss started. Loss that starts at a hop and carries on to the destination shows where packets are lost; loss at a single hop only is a router that answers pings slowly.')) + '</p>' +
					tr.map(function(e) {
						return '<p><b>' + x(fmtTime(e.ts)) + '</b> – ' + x(traceText(e)) + '</p><table class="ev"><tr><th>' + x(_('Hop')) + '</th><th>' +
							x(_('Address')) + '</th><th>' + x(_('Loss')) + '</th><th>' + x(_('Ping')) + '</th></tr>' +
							e.d.hops.map(function(h) {
								return '<tr class="' + (e.d.first_bad != null && h.n >= e.d.first_bad ? 'err' : '') + '"><td>' + h.n + '</td><td>' + x(h.ip || '???') +
									'</td><td>' + h.loss + '%</td><td>' + (h.avg != null ? h.avg + ' ms' : '–') + '</td></tr>';
							}).join('') + '</table>';
					}).join('');
			})() +
			'<h2>' + x(_('Event log (problems only)')) + '</h2><table class="ev">' +
			evs.filter(function(e) { return e.lvl !== 'info'; }).map(function(e) {
				return '<tr class="' + (e.lvl === 'err' ? 'err' : '') + '"><td>' + x(fmtTime(e.ts)) + '</td><td>' + x(hostArea(e)) + '</td><td>' + x(eventText(e)) + '</td></tr>';
			}).join('') + '</table>' +
			'<p class="muted">' + x(_('Measured continuously on the customer\'s router. Times are local router time.')) + '</p></body></html>';

		if (!win) {
			download('isp-tester-report-' + stamp() + '.html', html, 'text/html');
			return;
		}
		win.document.open();
		win.document.write(html);
		win.document.close();
	},

	/* ---- timeline */
	renderTimeline: function(w) {
		var self = this;
		var list = this.events().filter(function(e) { return e.ts >= w.from && e.ts <= w.to + 1; });
		if (this.filter)
			list = list.filter(function(e) { return e.area === self.filter; });
		/* events of the second router: '' = all routers, '-' = this one */
		var hosts = [];
		this.events().forEach(function(e) { if (e.host && hosts.indexOf(e.host) < 0) hosts.push(e.host); });
		if (this.hostFilter)
			list = list.filter(function(e) { return self.hostFilter === '-' ? !e.host : e.host === self.hostFilter; });

		var buttons = [ [ '', _('All') ], [ 'wan', _('Internet') ], [ 'iptv', _('IPTV') ], [ 'ports', _('Ports') ], [ 'system', _('Router') ], [ 'user', _('Your reports') ] ]
			.map(function(f) {
				return E('button', {
					'class': 'cbi-button' + (self.filter === f[0] ? ' active' : ''),
					'click': function() { self.filter = f[0]; self.redraw(); }
				}, f[1]);
			});

		if (hosts.length)
			buttons.push(E('span', { 'style': 'margin-left:.6em;display:flex;gap:.4em;flex-wrap:wrap' },
				[ [ '', _('All routers') ], [ '-', _('This router') ] ].concat(hosts.sort().map(function(h) { return [ h, h ]; })).map(function(f) {
					return E('button', {
						'class': 'cbi-button' + ((self.hostFilter || '') === f[0] ? ' active' : ''),
						'click': function() { self.hostFilter = f[0]; self.redraw(); }
					}, f[1]);
				})));

		var onlyProblems = E('label', { 'style': 'margin-left:auto' }, [
			E('input', {
				'type': 'checkbox', 'checked': this.onlyProblems ? '' : null,
				'change': function(e) { self.onlyProblems = e.target.checked; self.redraw(); }
			}), ' ', _('Only problems')
		]);
		if (this.onlyProblems)
			list = list.filter(function(e) { return e.lvl !== 'info'; });

		var rows = list.slice(0, 200).map(function(e) {
			/* a path snapshot: the hops fold out (clicks there do not move the charts) */
			var text = (e.type === 'trace' && e.d && (e.d.hops || []).length)
				? E('details', { 'click': function(ev) { ev.stopPropagation(); } }, [ E('summary', {}, eventText(e)), traceTable(e.d) ])
				: eventText(e);
			return E('tr', { 'class': 'click lvl-' + e.lvl + (e.m ? ' maint' : ''), 'title': e.m ? _('During maintenance – not counted') : _('Show this moment in the charts'),
				'click': function() { self.setWindow(self.range > 3600 ? 3600 : self.range, e.ts + Math.min(self.range, 3600) / 2); } }, [
				E('td', { 'class': 'when' }, fmtTime(e.ts)),
				E('td', { 'class': 'area' }, [ hostBadge(e), areaName(e.area) ]),
				E('td', {}, [ text, e.m ? E('span', { 'class': 'ispt-mtag' }, _('maintenance')) : '' ])
			]);
		});

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, w.live ? _('Timeline') : _('Timeline – selected period')),
			E('div', { 'class': 'ispt-filter' }, buttons.concat([ onlyProblems ])),
			rows.length
				? E('table', { 'class': 'ispt-tl' }, rows)
				: E('div', { 'class': 'ispt-muted' }, _('No events yet.'))
		]);
	},

	/* ---- actions */
	renderActions: function() {
		var self = this;
		return E('div', { 'class': 'ispt-actions' }, [
			E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'exportSamples') }, _('Download measurements (CSV)')),
			E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, 'exportEvents') }, _('Download timeline (CSV)')),
			E('button', { 'class': 'cbi-button cbi-button-action', 'title': _('Summary of the selected period for your ISP; print it or save it as PDF.'),
				'click': function() { self.reportDialog(); } }, _('Report for the ISP')),
			E('button', { 'class': 'cbi-button cbi-button-negative', 'click': function() { self.confirmClear(); } }, _('Clear logs')),
			(this.last && this.last[0] && this.last[0].enabled)
				? E('button', { 'class': 'cbi-button', 'style': 'margin-left:auto', 'click': ui.createHandlerFn(this, 'toggleEnabled', false) }, _('Turn monitoring off'))
				: ''
		]);
	},

	renderFooter: function(st) {
		var bits = [];
		bits.push(st.data && st.data.link ? _('Data kept in %s (survives a reboot)').format(st.data.link) : _('Data kept in RAM (lost on reboot)'));
		if (st.wan && st.wan.trace)
			bits.push(st.wan.trace.tool ? _('path snapshot at a loss: %s%s').format(st.wan.trace.tool,
				st.wan.trace.running ? ' (' + _('running now') + ')' : '')
				: E('span', { 'class': 'ispt-warn-text' }, _('path snapshot at a loss: no traceroute / mtr on the router')));
		if (st.peer) {
			var pe = st.peer, perr = {
				no_key: _('no key set (at least 8 characters)'),
				bad_host: _('the address of the main router is not a valid IPv4 address'),
				no_digest: _('the ucode-mod-digest package is missing'),
				no_socket_module: _('the ucode-mod-socket package is missing'),
				socket: _('cannot open a socket'),
				bind: _('UDP port %d is in use').format(pe.port),
				no_ack: _('no answer – check the address, the key and that the main router receives')
			}[pe.err];
			if (pe.role === 'send')
				bits.push(E('span', { 'class': perr ? 'ispt-warn-text' : '' }, perr ? _('sending events to %s: %s').format(pe.host, perr)
					: !pe.last_ack ? _('sending events to %s (waiting for the first confirmation)').format(pe.host)
					: _('sending events to %s (last confirmed %s ago%s)').format(pe.host, fmtDur(rnow() - pe.last_ack),
						pe.pending ? ', ' + _('%d waiting').format(pe.pending) : '')));
			else
				bits.push(E('span', { 'class': perr ? 'ispt-warn-text' : '' }, perr ? _('receiving events: %s').format(perr)
					: _('receiving events of the second router on UDP port %d').format(pe.port)));
			if (pe.bad && pe.bad_ts && rnow() - pe.bad_ts < 3600)
				bits.push(E('span', { 'class': 'ispt-warn-text' }, _('%d messages with a wrong key (last from %s)').format(pe.bad, pe.bad_addr || '?')));
		}
		if (st.notify) {
			var n = st.notify, failed = n.last_fail > (n.last_ok || 0);
			bits.push(!n.fetch ? _('notifications: uclient-fetch / wget missing')
				: failed ? _('notifications: last attempt failed %s ago (%d waiting)').format(fmtDur(rnow() - n.last_fail), n.pending)
				: n.last_ok ? _('notifications: last sent %s ago').format(fmtDur(rnow() - n.last_ok))
				: _('notifications: nothing sent yet'));
		}
		var parts = [];
		bits.forEach(function(b, i) { if (i) parts.push(' · '); parts.push(b); });
		return E('div', { 'class': 'ispt-muted', 'style': 'font-size:.85em' }, parts);
	},

	exportSamples: function() {
		return fs.read_direct('/tmp/isp-tester/samples.csv').then(function(data) {
			download('isp-tester-samples-' + stamp() + '.csv', data);
			/* the measurements from before the columns last changed (a ping target
			 * or a port added) are kept in their own file: offered too, it was
			 * readable by nobody but the data push */
			return fs.read_direct('/tmp/isp-tester/samples.prev.csv').then(function(prev) {
				if (prev && prev.indexOf('\n') > 0 && prev.indexOf('\n') < prev.length - 1)
					download('isp-tester-samples-' + stamp() + '-previous.csv', prev);
			}).catch(function() {});
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('Unable to read measurements: %s').format(e.message)), 'error');
		});
	},

	/* the whole timeline, read as a file: over ubus (rpcd "events" with no
	 * limit) a long one (up to 20000 entries, megabytes) is larger than a ubus
	 * message may be, and the download failed without a word */
	exportEvents: function() {
		var self = this;
		return this.refreshSlow().then(function() {
			var lines = [ 'time,level,router,area,source,event,message' ];
			self.events().slice().reverse().forEach(function(e) {
				lines.push([ isoTime(e.ts), e.lvl, e.host || '', e.area, e.src, e.type, eventText(e) ].map(csvCell).join(','));
			});
			download('isp-tester-events-' + stamp() + '.csv', lines.join('\n') + '\n');
		});
	},

	toggleEnabled: function(on) {
		var self = this;
		return callSetEnabled(on).then(function() {
			return callStatus().then(function(st) {
				self.last = [ st, self.last[1] ];
				self.redraw();
			});
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('Unable to change monitoring state: %s').format(e.message)), 'error');
		});
	},

	confirmClear: function() {
		var self = this;
		ui.showModal(_('Clear logs'), [
			E('p', _('This deletes the timeline, charts and CSV measurements. Download them first if you need them for your ISP.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'cbi-button cbi-button-negative', 'click': function() {
					ui.hideModal();
					return callClear().then(function() {
						/* drop the cached full timeline / 24 h history so old entries do not linger */
						self.allEvents = [];
						self.minHist = null;
						ui.addNotification(null, E('p', _('Logs will be cleared within one interval.')), 'info');
					});
				} }, _('Clear'))
			])
		]);
	},

	/* ---- assembly */
	redraw: function() {
		if (!this.root || !this.last) return;
		var self = this;
		var res = this.last[0];
		var st = res.state;
		var w = this.win();

		var parts = [ this.renderBanner(res) ];
		if (st) parts.push(this.renderMaint(st), this.renderClock(st), this.renderRestarts(st));

		if (st) {
			parts.push(this.renderDiagnosis(st, w));
			parts.push(E('div', { 'class': 'ispt-cards' }, [ this.renderWan(st), this.renderIptv(st), this.renderPorts(st) ].concat(this.renderPeers(st))));
			parts.push(this.renderCharts(st, w));
			parts.push(this.renderHours(w));
		}
		parts.push(this.renderTimeline(w));
		parts.push(this.renderActions());
		if (st) parts.push(this.renderFooter(st));

		dom.content(this.root, parts);
	},

	refreshSlow: function() {
		var self = this;
		return Promise.all([ readJson('/tmp/isp-tester/events.json'), readJson('/tmp/isp-tester/history.json') ]).then(function(d) {
			if (Array.isArray(d[0])) self.allEvents = d[0];
			if (d[1] && d[1].t) self.minHist = d[1];
		});
	},

	render: function(data) {
		var self = this, ticks = 0;
		this.last = [ data[0], data[1] ];
		if (Array.isArray(data[2])) this.allEvents = data[2];
		if (data[3] && data[3].t) this.minHist = data[3];
		this.root = E('div');

		this.redraw();

		poll.add(function() {
			var slow = (++ticks % 6 === 0) ? self.refreshSlow() : Promise.resolve();
			return Promise.all([ callStatus(), callEvents(200, ''), slow ]).then(function(d) {
				self.last = [ d[0], d[1] ];
				/* do not re-render while the user hovers a chart (tooltip would jump) */
				if (self.root.querySelector('.ispt-tip:not([style*="none"])')) return;
				self.redraw();
			});
		}, 5);

		return E([], [
			E('style', {}, CSS),
			E('h2', {}, _('ISP Tester')),
			E('div', { 'class': 'cbi-map-descr' }, _('Watches the Internet connection, IPTV stream and switch ports, and records every problem with a timestamp – so you have proof when you call your ISP.')),
			this.root
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
