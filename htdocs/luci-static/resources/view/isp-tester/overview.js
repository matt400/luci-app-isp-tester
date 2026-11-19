'use strict';
'require view';
'require rpc';
'require poll';
'require fs';
'require ui';
'require dom';
'require isp_tester.diagnose as diagnose';

var callStatus = rpc.declare({
	object: 'luci.isp_tester',
	method: 'status',
	expect: { '': {} }
});

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
	params: [ 'what', 'note' ],
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
	'.ispt-pulse{animation:ispt-pulse 1.2s ease-in-out infinite}',
	'@keyframes ispt-pulse{0%,100%{opacity:1}50%{opacity:.35}}',
	'.ispt-cards{display:flex;flex-wrap:wrap;gap:1em;margin-bottom:1em}',
	'.ispt-card{flex:1 1 300px;min-width:280px;border:1px solid rgba(128,128,128,.25);border-left-width:6px;border-radius:8px;padding:.8em 1em}',
	'.ispt-card.l-ok{border-left-color:#2e9d4f}.ispt-card.l-warn{border-left-color:#e0a100}.ispt-card.l-fail{border-left-color:#d64541}.ispt-card.l-unknown{border-left-color:#999}',
	'.ispt-card h3{margin:0 0 .5em 0;display:flex;align-items:center;gap:.4em;font-size:1.15em;border:0;padding:0}',
	'.ispt-card h3 .chip{margin-left:auto;font-size:.75em;padding:.15em .6em;border-radius:1em;color:#fff}',
	'.ispt-kv{display:grid;grid-template-columns:auto 1fr;gap:.2em 1em;font-size:.95em}',
	'.ispt-kv .k{opacity:.7}',
	'.ispt-big{font-size:1.6em;font-weight:bold}',
	'.ispt-reasons{margin:.5em 0 0 0;padding:0;list-style:none;font-size:.9em}',
	'.ispt-reasons li{padding:.15em 0}',
	'.ispt-mini{width:100%;border-collapse:collapse;font-size:.92em}',
	'.ispt-mini td,.ispt-mini th{padding:.2em .3em;text-align:left;border-bottom:1px solid rgba(128,128,128,.15)}',
	'.ispt-mini th{opacity:.7;font-weight:normal}',
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
	'.ispt-warn-text{color:#d64541;font-weight:bold}'
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

function fmtTime(ts) {
	var d = new Date(ts * 1000);
	var pad = function(n) { return (n < 10 ? '0' : '') + n; };
	return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' +
		pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
}

function fmtRate(kbps) {
	if (kbps == null) return '–';
	if (kbps >= 1000) return '%.1f Mbit/s'.format(kbps / 1000);
	return '%d kbit/s'.format(kbps);
}

function fmtMs(v) {
	return (v == null) ? '–' : '%.1f ms'.format(v);
}

function fmtSpeed(mbit) {
	if (mbit == null || mbit < 0) return '–';
	return (mbit >= 1000) ? (mbit / 1000) + ' Gbit/s' : mbit + ' Mbit/s';
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
	case 'link_down':       return _('%s: link down for %s').format(r.dev, fmtDur(Date.now() / 1000 - r.since));
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
	case 'wan_down':        return _('Internet unreachable for %s').format(fmtDur(Date.now() / 1000 - r.since));
	case 'wan_if_down':     return _('WAN interface %s is down (no PPPoE/DHCP session) for %s').format(r.iface, fmtDur(Date.now() / 1000 - r.since));
	case 'dns_fail':        return _('DNS does not answer (for %s)').format(fmtDur(Date.now() / 1000 - r.since));
	case 'dns_slow':        return _('DNS is slow (%s)').format(fmtMs(r.ms));
	case 'proxy_down':      return _('Multicast proxy %s is not running').format(r.name || '');
	case 'cpu_high':        return (r.cpu == null) ? _('Router CPU busy') : _('Router CPU busy: %d%% (%s)').format(r.cpu, r.core || 'cpu');
	case 'mem_low':         return _('Router is low on RAM: %d%% free').format(r.pct);
	case 'conntrack_full':  return _('Connection table %d%% full').format(r.pct);
	case 'stream_stalled':  return _('Stream stopped %s ago').format(fmtDur(Date.now() / 1000 - r.since));
	case 'stream_dip':      return _('Bitrate is much lower than usual');
	default:                return r.c;
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
		: _('%s: high latency %s (max %s)').format(targetName(e.src, d.host), fmtMs(d.rtt), fmtMs(d.rtt_max));
	case 'target_fail':     return _('%s: not responding (%d%% loss)').format(targetName(e.src, d.host), d.loss);
	case 'target_ok':       return _('%s: OK again after %s (%s)').format(targetName(e.src, d.host), fmtDur(d.dur), fmtMs(d.rtt));
	case 'wan_down':        return _('INTERNET DOWN – no target responds');
	case 'wan_up':          return _('Internet back after %s').format(fmtDur(d.dur));
	case 'stream_start':    return _('IPTV stream started (%s)').format(fmtRate(d.kbps));
	case 'stream_stall':    return _('IPTV STREAM STOPPED (was %s)').format(fmtRate(d.avg));
	case 'stream_resume':   return _('IPTV stream resumed after %s').format(fmtDur(d.dur)) + igmpNote(d.igmp);
	case 'stream_lost':     return _('IPTV stream did not come back within %s (decoder off or outage)').format(fmtDur(d.dur));
	case 'stream_dip':      return _('IPTV bitrate dropped to %s (usual %s)').format(fmtRate(d.kbps), fmtRate(d.avg));
	case 'wan_if_down':     return _('WAN interface %s DOWN (PPPoE/DHCP session lost)').format(d.iface);
	case 'wan_if_up':       return _('WAN interface %s up again after %s').format(d.iface, fmtDur(d.dur)) + (d.ip ? ' · ' + d.ip : '');
	case 'wan_reconnect':   return _('WAN session restarted (previous one lasted %s)').format(fmtDur(d.prev));
	case 'wan_ip_change':   return _('WAN address changed %s → %s').format(d.from, d.to);
	case 'dns_fail':        return d.server ? _('DNS: %s could not be resolved via %s').format(d.host, d.server) : _('DNS: %s could not be resolved').format(d.host);
	case 'dns_slow':        return _('DNS: slow answer %s').format(fmtMs(d.ms));
	case 'dns_ok':          return _('DNS OK again after %s (%s)').format(fmtDur(d.dur), fmtMs(d.ms));
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
	case 'restored':        return _('Logs restored from %s after a restart').format(d.dir);
	default:                return e.type;
	}
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

function igmpNote(ig) {
	switch (ig) {
	case 'zap':    return ' · ' + _('channel change');
	case 'left':   return ' · ' + _('IGMP membership was dropped');
	case 'joined': return ' · ' + _('still subscribed, data stopped');
	default:       return '';
	}
}

/* problems per hour of day, to spot e.g. evening congestion */
function hourHistogram(events, from, to) {
	var h = [];
	for (var i = 0; i < 24; i++) h.push(0);
	events.forEach(function(e) {
		if (e.ts < from || e.ts > to || e.lvl === 'info' || e.area === 'system' && e.type !== 'cpu_high') return;
		if (e.type === 'stream_resume' || e.type === 'wan_up' || e.type === 'link_up' || e.type === 'wan_if_up' || e.type === 'proxy_up') return;
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
	var d = new Date(ts * 1000);
	return ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2) +
		(secs ? ':' + ('0' + d.getSeconds()).slice(-2) : '');
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
	var y = function(v) { return T + (1 - Math.min(v, max) / max) * (H - T - B); };

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

/* thin green/yellow/red strip showing overall health over time */
function statusRibbon(t, lvls, from, to) {
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
	return fmtTime(Date.now() / 1000).replace(/[: ]/g, '-');
}

function csvCell(v) {
	v = (v == null) ? '' : String(v);
	return /[",\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
}

/* ------------------------------------------------------------------ view */

var RANGES = [ [ 3600, _('1 h') ], [ 6 * 3600, _('6 h') ], [ 24 * 3600, _('24 h') ] ];

function readJson(path) {
	return fs.read_direct(path).then(function(t) {
		try { return JSON.parse(t); } catch (e) { return null; }
	}).catch(function() { return null; });
}

function mergeEvents(a, b) {
	var seen = {}, out = [];
	a.concat(b).forEach(function(e) {
		var k = e.ts + '|' + e.type + '|' + e.src;
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

	load: function() {
		return Promise.all([ callStatus(), callEvents(200, ''), readJson('/tmp/isp-tester/events.json'), readJson('/tmp/isp-tester/history.json') ]);
	},

	/* ---- time window */
	now: function() {
		var st = this.last && this.last[0] && this.last[0].state;
		return Math.max(Date.now() / 1000, st ? st.ts : 0);
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

	events: function() {
		var recent = (this.last && this.last[1] && this.last[1].events) || [];
		return mergeEvents(recent, this.allEvents || []);
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
			? _('last %s (live)').format(RANGES.filter(function(r) { return r[0] === self.range; })[0][1])
			: fmtTime(w.from).substr(5, 11) + ' – ' + fmtTime(w.to).substr(5, 11);

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
			E('div', { 'class': 'ispt-muted' }, _('Probable cause (%s)').format(w.live ? _('last %s').format(RANGES.filter(function(x) { return x[0] === this.range; }, this)[0][1]) : _('selected period'))),
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
					(r.zaps ? ' · ' + _('%d channel changes ignored').format(r.zaps) : ''))
			]) : E('div', { 'class': 'ispt-muted', 'style': 'font-size:.9em' }, _('Nothing was logged that points at a fault.'))
		]);

		var items = r.findings.slice(0, 8).map(function(f) {
			return E('li', {}, [
				E('span', { 'class': 'ispt-side ' + f.side }, diagnose.sideText(f.side)),
				E('span', {}, diagnose.findingText(f)),
				f.last ? E('span', { 'class': 'ispt-muted', 'style': 'margin-left:auto;white-space:nowrap;font-size:.85em' }, _('last %s').format(hhmm(f.last))) : ''
			]);
		});

		return E('div', { 'class': 'ispt-diag' }, [
			head,
			items.length ? E('ul', { 'class': 'list' }, items) : '',
			E('div', { 'class': 'ispt-muted', 'style': 'flex-basis:100%;font-size:.8em' },
				_('Heuristic based on what happened at the same time; treat it as a hint, not proof. The timeline below is the evidence.'))
		]);
	},

	analyze: function(st, w) {
		var br = st.iptv && st.iptv.bridge;
		return diagnose.analyze(this.events(), w.from, w.to, {
			wan_device: st.wan && st.wan.device,
			iptv_direction: st.iptv && st.iptv.direction,
			bridge: br,
			membership_interval: br && br.membership_interval,
			query_interval: br && br.query_interval,
			igmp: st.iptv && st.iptv.igmp,
			dns_server: st.wan && st.wan.dns && st.wan.dns.server
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

		var o = lvl(st.overall);
		var problems = [];
		[ [ 'wan', st.wan ], [ 'iptv', st.iptv ], [ 'ports', st.ports ], [ 'system', st.system ] ].forEach(function(a) {
			if (a[1] && a[1].level && a[1].level !== 'ok')
				problems.push(areaName(a[0]) + ': ' + levelText(a[1].level).toLowerCase());
		});

		var headline = (o === 'ok') ? _('Everything works')
			: (o === 'warn') ? _('Works, but there were problems')
			: _('Fault right now');

		var age = Date.now() / 1000 - st.ts;
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
				E('div', { 'class': age > st.interval * 3 ? 'ispt-warn-text' : '' },
					_('Updated %s ago · running for %s').format(fmtDur(age), fmtDur(st.ts - st.started))),
				E('button', { 'class': 'cbi-button cbi-button-action ispt-markbtn', 'style': 'margin-top:.4em',
					'title': _('Click the moment you notice a problem (TV freezes, Internet slow). It is logged and compared with the measurements.'),
					'click': ui.createHandlerFn(this, 'showMark') }, _('⚑ Problem now'))
			])
		]);
	},

	showMark: function() {
		var self = this, clicked = Date.now();
		var note = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%', 'maxlength': 200,
			'placeholder': _('Optional note, e.g. channel, room, what you saw') });
		var send = function(what) {
			ui.hideModal();
			/* the time of the click counts, not of the choice */
			return callMark(what, note.value || '').then(function(r) {
				var late = Math.round((Date.now() - clicked) / 1000);
				ui.addNotification(null, E('p', r && r.result
					? _('Logged. It will appear in the timeline within one interval.') + (late > 20 ? ' ' + _('(logged %d s after you clicked)').format(late) : '')
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

	/* ---- cards */
	renderWan: function(st) {
		var w = st.wan;
		if (!w)
			return this.disabledCard(_('Internet'));

		var rows = (w.targets || []).map(function(t) {
			return E('tr', {}, [
				E('td', {}, [ dot(t.level), targetName(t.label, t.host) ]),
				E('td', {}, (t.loss == null) ? '–' : t.loss + '%'),
				E('td', {}, fmtMs(t.rtt)),
				E('td', {}, fmtMs(t.jitter))
			]);
		});
		var kv = [
			E('span', { 'class': 'k' }, _('WAN device')), E('span', {}, w.device || '–'),
			E('span', { 'class': 'k' }, _('Traffic ↓ / ↑')), E('span', {}, fmtRate(w.rx_kbps) + ' / ' + fmtRate(w.tx_kbps))
		];
		if (w.dns)
			kv.push(E('span', { 'class': 'k' }, _('DNS')), E('span', {}, [
				dot(w.dns.state === 'ok' ? 'ok' : w.dns.state === 'slow' ? 'warn' : (w.dns.ok == null ? 'unknown' : 'fail')),
				w.dns.ok === false ? _('no answer') : fmtMs(w.dns.ms),
				E('span', { 'class': 'ispt-muted' }, ' · ' + w.dns.host + (w.dns.server ? ' @ ' + w.dns.server : ''))
			]));
		if (w.session) {
			var ss = w.session;
			kv.push(E('span', { 'class': 'k' }, _('Session')), E('span', {},
				ss.up ? _('%s, up for %s').format((ss.proto || '').toUpperCase() || 'WAN', fmtDur(ss.uptime)) : _('DOWN')));
			kv.push(E('span', { 'class': 'k' }, _('Address')), E('span', {}, (ss.ip || '–') +
				(ss.reconnects ? ' · ' + _('%d reconnects since start').format(ss.reconnects) : '')));
		}

		return E('div', { 'class': 'ispt-card l-' + lvl(w.level) }, [
			E('h3', {}, [ _('Internet'), chip(w.level) ]),
			E('table', { 'class': 'ispt-mini' }, [
				E('tr', {}, [ E('th', {}, _('Target')), E('th', {}, _('Loss')), E('th', {}, _('Ping')),
					E('th', { 'title': _('Mean difference between consecutive replies') }, _('Jitter')) ])
			].concat(rows.length ? rows : [ E('tr', {}, E('td', { colspan: 4, 'class': 'ispt-muted' }, _('Waiting for ping results…'))) ])),
			E('div', { 'class': 'ispt-kv', 'style': 'margin-top:.5em' }, kv),
			this.reasons(w.reasons)
		]);
	},

	renderIptv: function(st) {
		var t = st.iptv;
		if (!t)
			return this.disabledCard(_('IPTV'), _('Set the IPTV device in Settings.'));

		var stateText = {
			playing: _('Stream running'),
			stalled: _('STREAM STOPPED'),
			idle: _('No stream (decoder off?)')
		}[t.state] || t.state;

		var kv = [
			E('span', { 'class': 'k' }, _('Device')), E('span', {}, '%s (%s)'.format(t.device, t.direction === 'tx' ? _('outgoing') : _('incoming'))),
			E('span', { 'class': 'k' }, _('State')), E('span', {}, stateText + ' · ' + _('for %s').format(fmtDur(Date.now() / 1000 - t.since))),
			E('span', { 'class': 'k' }, _('Usual bitrate')), E('span', {}, t.avg ? fmtRate(t.avg) : '–'),
			E('span', { 'class': 'k' }, _('Packets/s')), E('span', {}, t.pps != null ? String(t.pps) : '–')
		];

		if (t.bridge) {
			kv.push(E('span', { 'class': 'k' }, _('IGMP snooping (%s)').format(t.bridge.name)),
				E('span', {}, t.bridge.snooping == null ? '–' : (t.bridge.snooping === '1' ? _('on') : _('off'))));
			kv.push(E('span', { 'class': 'k' }, _('IGMP querier')),
				E('span', {}, t.bridge.querier == null ? '–' : (t.bridge.querier === '1' ? _('on') : _('off'))));
		}

		if (t.bridge && t.bridge.membership_interval)
			kv.push(E('span', { 'class': 'k' }, _('IGMP timers')), E('span', {},
				_('membership %d s, query %d s').format(t.bridge.membership_interval, t.bridge.query_interval || 0)));
		if (t.bridge && t.bridge.mdb)
			kv.push(E('span', { 'class': 'k' }, _('Bridge groups')), E('span', { 'class': 'ispt-groups' },
				t.bridge.mdb.length ? t.bridge.mdb.map(function(m) { return m.grp + ' → ' + m.port; }).join(', ') : _('none')));
		if (t.igmp) {
			var ig = t.igmp;
			kv.push(E('span', { 'class': 'k' }, _('Multicast proxy')), E('span', {},
				ig.proxy_running ? [ dot('ok'), ig.proxy ] : ig.proxy_seen ? [ dot('fail'), _('%s not running').format(ig.proxy) ] : _('none found')));
			if (ig.dev)
				kv.push(E('span', { 'class': 'k' }, _('Channels joined (%s)').format(ig.dev)), E('span', { 'class': 'ispt-groups' },
					!ig.found ? _('device not in IGMP table') :
					(ig.groups && ig.groups.length ? ig.groups.join(', ') : _('none')) + (ig.version ? ' · IGMP' + ig.version.replace('V', 'v') : '') +
					(ig.last_change ? ' · ' + _('changed %s ago').format(fmtDur(Date.now() / 1000 - ig.last_change)) : '')));
		}

		return E('div', { 'class': 'ispt-card l-' + lvl(t.level) }, [
			E('h3', {}, [ _('IPTV'), chip(t.level) ]),
			E('div', { 'class': 'ispt-big' }, fmtRate(t.kbps)),
			E('div', { 'class': 'ispt-kv' }, kv),
			this.reasons(t.reasons)
		]);
	},

	renderPorts: function(st) {
		var p = st.ports;
		if (!p || !p.list || !p.list.length)
			return this.disabledCard(_('Ports'), _('Add ports to watch in Settings.'));

		var rows = p.list.map(function(x) {
			var link = !x.present ? _('missing') : x.up ? fmtSpeed(x.speed) + (x.duplex && x.duplex !== 'full' ? ' ' + x.duplex : '') : _('down');
			var tot = x.totals || {};
			return E('tr', { 'title': (x.reasons || []).map(reasonText).join('\n') }, [
				E('td', {}, [ dot(x.level), x.label ? '%s (%s)'.format(x.label, x.dev) : x.dev ]),
				E('td', {}, link),
				E('td', {}, x.up ? fmtDur(Date.now() / 1000 - x.since) : '–'),
				E('td', {}, '%d / %d'.format((tot.rx_errors || 0) + (tot.tx_errors || 0), (tot.rx_dropped || 0) + (tot.tx_dropped || 0))),
				E('td', {}, String(tot.carrier_changes != null ? tot.carrier_changes : '–'))
			]);
		});

		var reasons = [];
		p.list.forEach(function(x) { (x.reasons || []).forEach(function(r) { reasons.push(r); }); });

		return E('div', { 'class': 'ispt-card l-' + lvl(p.level) }, [
			E('h3', {}, [ _('Ports'), chip(p.level) ]),
			E('table', { 'class': 'ispt-mini' }, [
				E('tr', {}, [ E('th', {}, _('Port')), E('th', {}, _('Link')), E('th', {}, _('Up for')),
					E('th', { 'title': _('Total errors / dropped packets since boot') }, _('Err / drop')),
					E('th', { 'title': _('Link state changes since boot') }, _('Flaps')) ])
			].concat(rows)),
			this.reasons(reasons)
		]);
	},

	renderSystem: function(st) {
		var y = st.system;
		if (!y) return '';
		var pct = function(v) { return (v == null) ? '–' : v + '%'; };
		var kv = [
			E('span', { 'class': 'k' }, _('CPU')), E('span', {}, y.cpu == null ? '–' :
				_('%d%% overall, busiest core %d%% (softirq %d%%)').format(y.cpu, y.cpu_max, y.sirq_max)),
			E('span', { 'class': 'k' }, _('Load')), E('span', {}, y.load == null ? '–' : String(y.load) + (y.cores ? ' / ' + _('%d cores').format(y.cores) : '')),
			E('span', { 'class': 'k' }, _('Free RAM')), E('span', {}, pct(y.mem_pct) + (y.mem_total ? ' ' + _('of %d MB').format(Math.round(y.mem_total / 1024)) : '')),
			E('span', { 'class': 'k' }, _('Connections')), E('span', {}, y.ct == null ? '–' : '%d / %d (%d%%)'.format(y.ct, y.ct_max, y.ct_pct))
		];
		if (st.persist)
			kv.push(E('span', { 'class': 'k' }, _('Logs kept on')), E('span', { 'class': st.persist.ok ? '' : 'ispt-warn-text' },
				st.persist.ok ? _('%s (copied %s ago)').format(st.persist.dir, fmtDur(Date.now() / 1000 - st.persist.last)) : _('%s – not mounted!').format(st.persist.dir)));
		if (st.notify) {
			var n = st.notify;
			kv.push(E('span', { 'class': 'k' }, _('Notifications')), E('span', { 'class': (n.last_fail > (n.last_ok || 0)) || !n.fetch ? 'ispt-warn-text' : '' },
				!n.fetch ? _('uclient-fetch / wget missing') :
				(n.last_fail > (n.last_ok || 0)) ? _('last attempt failed %s ago (%d waiting)').format(fmtDur(Date.now() / 1000 - n.last_fail), n.pending) :
				n.last_ok ? _('last sent %s ago').format(fmtDur(Date.now() / 1000 - n.last_ok)) : _('nothing sent yet')));
		}

		return E('div', { 'class': 'ispt-card l-' + lvl(y.level) }, [
			E('h3', {}, [ _('Router'), chip(y.level) ]),
			E('div', { 'class': 'ispt-kv' }, kv),
			this.reasons(y.reasons)
		]);
	},

	disabledCard: function(title, hint) {
		return E('div', { 'class': 'ispt-card l-unknown' }, [
			E('h3', {}, [ title, chip('unknown') ]),
			E('div', { 'class': 'ispt-muted' }, hint || _('Disabled in Settings.'))
		]);
	},

	reasons: function(list) {
		if (!list || !list.length) return '';
		return E('ul', { 'class': 'ispt-reasons' }, list.map(function(r) {
			return E('li', {}, '⚠ ' + reasonText(r));
		}));
	},

	/* ---- charts */
	renderCharts: function(st, w) {
		var cd = this.chartData(st, w);
		var h = cd.h, t = h.t || [], s = h.s || {};
		var out = [];
		var lossMax = function(data) { return data.some(function(v) { return v >= 100; }); };

		if (s.lvl)
			out.push(statusRibbon(t, s.lvl, w.from, w.to));

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
			var evs = this.events().slice().sort(function(a, b) { return a.ts - b.ts; });
			var stallBands = [];
			evs.forEach(function(e, i) {
				if (e.type !== 'stream_stall') return;
				var end = null;
				for (var j = i + 1; j < evs.length; j++)
					if (evs[j].type === 'stream_resume' || evs[j].type === 'stream_lost' || evs[j].type === 'monitor_start') { end = evs[j].ts; break; }
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
				fmt: function(v) { return v.toFixed(1); },
				min_max: 1
			}));
		}

		if (s.dns && s.dns.some(function(v, i) { return v != null && t[i] >= w.from && t[i] <= w.to; })) {
			out.push(lineChart(t, [ { name: _('DNS'), color: '#2e9d8f', data: s.dns, fmt: fmtMs } ], {
				from: w.from, to: w.to, title: cd.fine ? _('DNS lookup time (ms)') : _('DNS lookup time (ms, worst per minute)'),
				min_max: 20, height: 100
			}));
		}

		if (s.cpu && s.cpu.some(function(v, i) { return v != null && t[i] >= w.from && t[i] <= w.to; })) {
			out.push(lineChart(t, [
				{ name: _('Busiest CPU core'), color: '#c44b8a', data: s.cpu, fmt: function(v) { return Math.round(v) + '%'; } },
				{ name: _('of it softirq (packet processing)'), color: '#8a9a2e', data: s.sirq || [], fmt: function(v) { return Math.round(v) + '%'; } }
			], { from: w.from, to: w.to, title: _('Router CPU (%)'), min_max: 100, height: 100, legend: true,
				fmt: function(v) { return Math.round(v) + '%'; } }));
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

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('History')),
			this.renderNav(),
			hasData ? out : E('div', { 'class': 'ispt-muted' },
				t.length ? _('No data for this period (data is kept in RAM for up to 24 h and is lost on reboot).') : _('Collecting data…'))
		]);
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
					fmtTime(from).substr(5, 11) + ' – ' + fmtTime(w.to).substr(5, 11))),
			E('div', { 'class': 'ispt-hours' }, h.map(function(n, i) {
				return E('div', { 'class': n ? '' : 'zero', 'style': 'height:' + Math.max(1, Math.round(n * 100 / max)) + '%',
					'title': _('%02d:00–%02d:59: %d problems').format(i, i, n) });
			})),
			E('div', { 'class': 'ispt-hours-lbl' }, lbl)
		]);
	},

	/* ---- printable report for the ISP */
	openReport: function() {
		var res = this.last && this.last[0], st = res && res.state;
		if (!st) return;
		var w = this.win();
		var r = this.analyze(st, w);
		var evs = this.events().filter(function(e) { return e.ts >= w.from && e.ts <= w.to; }).sort(function(a, b) { return a.ts - b.ts; });

		/* outage / freeze durations from start/end pairs */
		var sum = function(startType, endTypes) {
			var n = 0, total = 0, longest = 0;
			evs.forEach(function(e, i) {
				if (e.type !== startType) return;
				for (var j = i + 1; j < evs.length; j++)
					if (endTypes.indexOf(evs[j].type) >= 0) {
						/* a channel change is not a freeze */
						if (evs[j].d && evs[j].d.igmp === 'zap') return;
						var d = (evs[j].d && evs[j].d.dur) || (evs[j].ts - e.ts);
						total += d;
						if (d > longest) longest = d;
						break;
					}
				n++;
			});
			return { n: n, total: total, longest: longest };
		};
		var net = sum('wan_down', [ 'wan_up', 'monitor_start' ]);
		var tv = sum('stream_stall', [ 'stream_resume', 'stream_lost', 'monitor_start' ]);
		var count = function(f) { return evs.filter(f).length; };

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
			'<p class="muted">' + x(_('Period: %s – %s · generated %s by luci-app-isp-tester').format(fmtTime(w.from), fmtTime(w.to), fmtTime(Date.now() / 1000))) + '</p>' +
			'<h2>' + x(_('Connection')) + '</h2><table>' +
			row(_('WAN interface / device'), (st.wan ? st.wan.interface + ' / ' + st.wan.device : '–')) +
			(st.wan && st.wan.session ? row(_('Session'), (st.wan.session.proto || '') + ' · ' + (st.wan.session.ip || '')) : '') +
			row(_('Ping targets'), targets || '–') +
			(st.iptv ? row(_('IPTV measured on'), st.iptv.device + ' (' + (st.iptv.direction === 'tx' ? _('outgoing') : _('incoming')) + ')') : '') +
			'</table><h2>' + x(_('Summary')) + '</h2><table>' +
			row(_('Internet outages'), _('%d, total %s, longest %s').format(net.n, fmtDur(net.total), fmtDur(net.longest))) +
			row(_('Packet loss at the ISP gateway'), _('%d×').format(count(function(e) { return e.src === 'gateway' && (e.type === 'target_degraded' || e.type === 'target_fail') && e.d && e.d.loss > 0; }))) +
			row(_('Packet loss to far targets'), _('%d×').format(count(function(e) { return e.area === 'wan' && e.src !== 'gateway' && e.src !== 'dns' && e.src !== 'netifd' && (e.type === 'target_degraded' || e.type === 'target_fail') && e.d && e.d.loss > 0; }))) +
			row(_('WAN session drops (PPPoE/DHCP)'), _('%d×').format(count(function(e) { return e.type === 'wan_reconnect' || e.type === 'wan_if_down'; }))) +
			row(_('WAN port link drops'), _('%d×').format(count(function(e) { return e.type === 'link_down' && e.area === 'wan'; }))) +
			row(_('DNS failures'), _('%d×').format(count(function(e) { return e.type === 'dns_fail'; }))) +
			row(_('IPTV freezes'), _('%d, total %s, longest %s').format(tv.n, fmtDur(tv.total), fmtDur(tv.longest)) + (r.zaps ? ' · ' + _('%d channel changes not counted').format(r.zaps) : '')) +
			row(_('Router overloaded'), _('%d×').format(count(function(e) { return e.type === 'cpu_high' || e.type === 'mem_low' || e.type === 'conntrack_full'; }))) +
			row(_('Problems reported by the user'), _('%d×').format(count(function(e) { return e.type === 'user_mark'; }))) +
			'</table><h2>' + x(_('Assessment')) + '</h2><p><b>' + x(diagnose.verdictText(r.verdict)) + '</b> (' + x(diagnose.confidenceText(r.confidence)) + ')</p><ul>' +
			r.findings.map(function(f) { return '<li>[' + x(diagnose.sideText(f.side)) + '] ' + x(diagnose.findingText(f)) + '</li>'; }).join('') +
			'</ul><h2>' + x(_('Problems by hour of day')) + '</h2><div class="hours">' +
			h.map(function(n) { return '<div style="height:' + Math.max(1, Math.round(n * 100 / hmax)) + '%" title="' + n + '"></div>'; }).join('') +
			'</div><div class="hl">' + h.map(function(n, i) { return '<span>' + i + '</span>'; }).join('') + '</div>' +
			'<h2>' + x(_('Event log (problems only)')) + '</h2><table class="ev">' +
			evs.filter(function(e) { return e.lvl !== 'info'; }).map(function(e) {
				return '<tr class="' + (e.lvl === 'err' ? 'err' : '') + '"><td>' + x(fmtTime(e.ts)) + '</td><td>' + x(areaName(e.area)) + '</td><td>' + x(eventText(e)) + '</td></tr>';
			}).join('') + '</table>' +
			'<p class="muted">' + x(_('Measured continuously on the customer\'s router. Times are local router time.')) + '</p></body></html>';

		var win = window.open('', '_blank');
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

		var buttons = [ [ '', _('All') ], [ 'wan', _('Internet') ], [ 'iptv', _('IPTV') ], [ 'ports', _('Ports') ], [ 'system', _('Router') ], [ 'user', _('Your reports') ] ]
			.map(function(f) {
				return E('button', {
					'class': 'cbi-button' + (self.filter === f[0] ? ' active' : ''),
					'click': function() { self.filter = f[0]; self.redraw(); }
				}, f[1]);
			});

		var onlyProblems = E('label', { 'style': 'margin-left:auto' }, [
			E('input', {
				'type': 'checkbox', 'checked': this.onlyProblems ? '' : null,
				'change': function(e) { self.onlyProblems = e.target.checked; self.redraw(); }
			}), ' ', _('Only problems')
		]);
		if (this.onlyProblems)
			list = list.filter(function(e) { return e.lvl !== 'info'; });

		var rows = list.slice(0, 200).map(function(e) {
			return E('tr', { 'class': 'click lvl-' + e.lvl, 'title': _('Show this moment in the charts'),
				'click': function() { self.setWindow(self.range > 3600 ? 3600 : self.range, e.ts + Math.min(self.range, 3600) / 2); } }, [
				E('td', { 'class': 'when' }, fmtTime(e.ts)),
				E('td', { 'class': 'area' }, areaName(e.area)),
				E('td', {}, eventText(e))
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
				'click': function() { self.openReport(); } }, _('Report for the ISP')),
			E('button', { 'class': 'cbi-button cbi-button-negative', 'click': function() { self.confirmClear(); } }, _('Clear logs')),
			(this.last && this.last[0] && this.last[0].enabled)
				? E('button', { 'class': 'cbi-button', 'style': 'margin-left:auto', 'click': ui.createHandlerFn(this, 'toggleEnabled', false) }, _('Turn monitoring off'))
				: ''
		]);
	},

	exportSamples: function() {
		return fs.read_direct('/tmp/isp-tester/samples.csv').then(function(data) {
			download('isp-tester-samples-' + stamp() + '.csv', data);
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('Unable to read measurements: %s').format(e.message)), 'error');
		});
	},

	exportEvents: function() {
		return callEvents(0, '').then(function(res) {
			var lines = [ 'time,level,area,source,event,message' ];
			(res.events || []).slice().reverse().forEach(function(e) {
				lines.push([ fmtTime(e.ts), e.lvl, e.area, e.src, e.type, eventText(e) ].map(csvCell).join(','));
			});
			download('isp-tester-events-' + stamp() + '.csv', lines.join('\n') + '\n');
		});
	},

	toggleEnabled: function(on) {
		var self = this;
		return callSetEnabled(on).then(function(r) {
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
		var res = this.last[0];
		var st = res.state;
		var w = this.win();

		var parts = [ this.renderBanner(res) ];
		if (st) {
			parts.push(this.renderDiagnosis(st, w));
			parts.push(E('div', { 'class': 'ispt-cards' }, [ this.renderWan(st), this.renderIptv(st), this.renderPorts(st), this.renderSystem(st) ]));
			parts.push(this.renderCharts(st, w));
			parts.push(this.renderHours(w));
		}
		parts.push(this.renderTimeline(w));
		parts.push(this.renderActions());

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
