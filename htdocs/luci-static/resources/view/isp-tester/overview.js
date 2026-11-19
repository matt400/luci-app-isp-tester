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
	case 'system': return _('System');
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
		: _('%s: high latency %s').format(targetName(r.t), fmtMs(r.rtt));
	case 'wan_down':        return _('Internet unreachable for %s').format(fmtDur(Date.now() / 1000 - r.since));
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
		: _('%s: high latency %s (max %s)').format(targetName(e.src, d.host), fmtMs(d.rtt), fmtMs(d.rtt_max));
	case 'target_fail':     return _('%s: not responding (%d%% loss)').format(targetName(e.src, d.host), d.loss);
	case 'target_ok':       return _('%s: OK again after %s (%s)').format(targetName(e.src, d.host), fmtDur(d.dur), fmtMs(d.rtt));
	case 'wan_down':        return _('INTERNET DOWN – no target responds');
	case 'wan_up':          return _('Internet back after %s').format(fmtDur(d.dur));
	case 'stream_start':    return _('IPTV stream started (%s)').format(fmtRate(d.kbps));
	case 'stream_stall':    return _('IPTV STREAM STOPPED (was %s)').format(fmtRate(d.avg));
	case 'stream_resume':   return _('IPTV stream resumed after %s').format(fmtDur(d.dur));
	case 'stream_lost':     return _('IPTV stream did not come back within %s (decoder off or outage)').format(fmtDur(d.dur));
	case 'stream_dip':      return _('IPTV bitrate dropped to %s (usual %s)').format(fmtRate(d.kbps), fmtRate(d.avg));
	default:                return e.type;
	}
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
		var r = diagnose.analyze(this.events(), w.from, w.to, {
			wan_device: st.wan && st.wan.device,
			iptv_direction: st.iptv && st.iptv.direction,
			bridge: st.iptv && st.iptv.bridge
		});

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
					diagnose.confidenceText(r.confidence) + ' · ' + _('%d problems, %d IPTV freezes').format(r.problems, r.stalls))
			]) : E('div', { 'class': 'ispt-muted', 'style': 'font-size:.9em' }, _('Nothing was logged that points at a fault.'))
		]);

		var items = r.findings.slice(0, 6).map(function(f) {
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
		[ [ 'wan', st.wan ], [ 'iptv', st.iptv ], [ 'ports', st.ports ] ].forEach(function(a) {
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
					_('Updated %s ago · running for %s').format(fmtDur(age), fmtDur(st.ts - st.started)))
			])
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
				E('td', {}, fmtMs(t.rtt))
			]);
		});

		return E('div', { 'class': 'ispt-card l-' + lvl(w.level) }, [
			E('h3', {}, [ _('Internet'), chip(w.level) ]),
			E('table', { 'class': 'ispt-mini' }, [
				E('tr', {}, [ E('th', {}, _('Target')), E('th', {}, _('Loss')), E('th', {}, _('Ping')) ])
			].concat(rows.length ? rows : [ E('tr', {}, E('td', { colspan: 3, 'class': 'ispt-muted' }, _('Waiting for ping results…'))) ])),
			E('div', { 'class': 'ispt-kv', 'style': 'margin-top:.5em' }, [
				E('span', { 'class': 'k' }, _('WAN device')), E('span', {}, w.device || '–'),
				E('span', { 'class': 'k' }, _('Traffic ↓ / ↑')), E('span', {}, fmtRate(w.rx_kbps) + ' / ' + fmtRate(w.tx_kbps))
			]),
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
				series.push({ name: targetName(label, tg && tg.host), color: COLORS[i % COLORS.length], data: s['rtt:' + label] || t.map(function() { return null; }), loss: loss,
					fmt: (function(l) { return function(v, k) { return fmtMs(v) + (l[k] > 0 ? ' · ' + _('loss %d%%').format(l[k]) : ''); }; })(loss) });
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

	/* ---- timeline */
	renderTimeline: function(w) {
		var self = this;
		var list = this.events().filter(function(e) { return e.ts >= w.from && e.ts <= w.to + 1; });
		if (this.filter)
			list = list.filter(function(e) { return e.area === self.filter; });

		var buttons = [ [ '', _('All') ], [ 'wan', _('Internet') ], [ 'iptv', _('IPTV') ], [ 'ports', _('Ports') ], [ 'system', _('System') ] ]
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
			parts.push(E('div', { 'class': 'ispt-cards' }, [ this.renderWan(st), this.renderIptv(st), this.renderPorts(st) ]));
			parts.push(this.renderCharts(st, w));
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
