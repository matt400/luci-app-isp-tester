'use strict';
'require baseclass';

/*
 * Heuristic fault attribution: looks at the events of a time window and
 * decides whether problems most likely come from the ISP or from the home
 * side (router, cables, switch, decoder).
 *
 * Every finding has a side:
 *   isp  - ISP line / access network / backbone / multicast source
 *   home - router configuration, LAN cabling, switch, devices
 *   edge - the boundary (WAN cable, ONT/modem) - counts half for both
 *   info - context only, no weight
 */

var NEAR = 30;          /* seconds for "happened at the same time" */
var CAP = 5;            /* max occurrences counted per finding */

function near(list, ts, win) {
	win = win || NEAR;
	for (var i = 0; i < list.length; i++)
		if (Math.abs(list[i].ts - ts) <= win) return true;
	return false;
}

function lastTs(list) {
	var m = 0;
	list.forEach(function(e) { if (e.ts > m) m = e.ts; });
	return m;
}

function uniq(list, key) {
	var seen = {}, out = [];
	list.forEach(function(e) {
		var k = e[key] != null ? e[key] : (e.d && e.d[key]);
		/* a port of the second router: "M477S:lan1" */
		if (key === 'src' && e.host) k = e.host + ':' + k;
		if (!seen[k]) { seen[k] = true; out.push(k); }
	});
	return out;
}

/* first event after ts (sorted list) matching pred */
function nextOf(sorted, ts, pred) {
	for (var i = 0; i < sorted.length; i++)
		if (sorted[i].ts >= ts && pred(sorted[i])) return sorted[i];
	return null;
}

/* [from, to] periods between a start event (e.g. cpu_high) and its "_ok" end */
function periods(sorted, types, until) {
	var out = [], open = {};
	sorted.forEach(function(e) {
		if (types.indexOf(e.type) >= 0) {
			if (open[e.type] == null) open[e.type] = e.ts;
		}
		else if (/_ok$/.test(e.type)) {
			var k = e.type.replace(/_ok$/, '');
			if (types.indexOf(k) >= 0 && open[k] != null) { out.push({ from: open[k], to: e.ts }); open[k] = null; }
		}
		else if (e.type === 'monitor_start') {
			Object.keys(open).forEach(function(k) { if (open[k] != null) { out.push({ from: open[k], to: e.ts }); open[k] = null; } });
		}
	});
	Object.keys(open).forEach(function(k) { if (open[k] != null) out.push({ from: open[k], to: until }); });
	return out;
}

function inPeriods(list, ts, slack) {
	for (var i = 0; i < list.length; i++)
		if (ts >= list[i].from - slack && ts <= list[i].to + slack) return true;
	return false;
}

/* regular spacing of stalls -> IGMP membership/query timeout */
function periodicity(list) {
	if (list.length < 4) return null;
	var ts = list.map(function(e) { return e.ts; }).sort(function(a, b) { return a - b; });
	var gaps = [];
	for (var i = 1; i < ts.length; i++) gaps.push(ts[i] - ts[i - 1]);
	var mean = gaps.reduce(function(a, b) { return a + b; }, 0) / gaps.length;
	if (mean <= 0) return null;
	var sd = Math.sqrt(gaps.reduce(function(a, g) { return a + (g - mean) * (g - mean); }, 0) / gaps.length);
	/* IGMP timers are minutes, not seconds: dense random freezes are not periodic.
	 * The absolute tolerance covers the sampling interval jitter. */
	if (mean < 60) return null;
	return (sd / mean < 0.2 || sd <= 12) ? Math.round(mean) : null;
}

return baseclass.extend({
	/*
	 * events: [{ ts, lvl, area, src, type, d }]
	 * ctx: { wan_device, iptv_direction, bridge: { name, snooping, querier } }
	 */
	analyze: function(events, from, to, ctx) {
		ctx = ctx || {};
		var evAll = events.filter(function(e) { return e.ts >= from && e.ts <= to; });
		/*
		 * Events of the second router (e.host) are evidence for the home side
		 * only (its ports, Wi-Fi, decoders, your reports there); Internet and
		 * IPTV stream analysis uses what this router measured, so the same
		 * freeze seen by both routers is not counted twice.
		 */
		var ev = evAll.filter(function(e) { return !e.host; });
		var remote = evAll.filter(function(e) { return !!e.host; });
		var by = function(f) { return ev.filter(f); };
		var byAll = function(f) { return evAll.filter(f); };
		/* resume / "_ok" events can come after the window end; look a bit further */
		var sorted = events.filter(function(e) { return !e.host && e.ts >= from - 3600 && e.ts <= to + 3600; })
			.sort(function(a, b) { return a.ts - b.ts; });

		var wanDev = ctx.wan_device;
		var isJitter = function(e) { return e.type === 'target_degraded' && e.d && e.d.why === 'jitter'; };
		var isLoss = function(e) { return e.area === 'wan' && (e.type === 'target_degraded' || e.type === 'target_fail') && !isJitter(e); };
		var gwJitter = by(function(e) { return e.area === 'wan' && e.src === 'gateway' && isJitter(e); });

		var wanLinkDown = by(function(e) { return e.type === 'link_down' && (e.area === 'wan' || e.src === wanDev); });
		var wanDown     = by(function(e) { return e.type === 'wan_down'; });
		var gwLoss      = by(function(e) { return isLoss(e) && e.src === 'gateway'; });
		var farLoss     = by(function(e) { return isLoss(e) && e.src !== 'gateway'; });
		/* the WAN L3 device vanishing (e.g. pppoe-wan when the PPP session drops) is a WAN problem */
		var wanDevGone  = by(function(e) { return e.type === 'dev_missing' && (e.area === 'wan' || e.src === wanDev); });
		var wanSess     = by(function(e) { return e.type === 'wan_reconnect' || e.type === 'wan_if_down'; });
		var logOf       = function(kinds) { return by(function(e) { return e.type === 'log' && e.d && kinds.indexOf(e.d.kind) >= 0; }); };
		var pppEcho     = logOf([ 'ppp_echo' ]);
		var pppIsp      = logOf([ 'ppp_auth', 'ppp_discovery', 'dhcp_fail' ]);
		var pppDown     = logOf([ 'ppp_down' ]);
		var anyWan      = gwLoss.concat(farLoss, wanDown, wanLinkDown, wanDevGone, wanSess, pppEcho, pppIsp, pppDown);

		/* ports of both routers (a port of the second router is never the WAN of this one) */
		var portLink    = byAll(function(e) { return e.area === 'ports' && (e.type === 'link_down' || e.type === 'link_flap'); });
		var portSpeed   = byAll(function(e) { return e.area === 'ports' && e.type === 'speed_change' && e.d && e.d.to < e.d.from; });
		var portErr     = byAll(function(e) { return e.area === 'ports' && (e.type === 'errors' || e.type === 'drops'); });
		var portMissing = byAll(function(e) { return e.type === 'dev_missing' && (e.host || (e.area !== 'wan' && e.src !== wanDev)); });
		var devName     = function(e) { return e.host ? e.host + ':' + e.src : e.src; };
		var wanErr      = by(function(e) { return e.area === 'wan' && e.type === 'errors'; });
		var iptvDevErr  = by(function(e) { return e.area === 'iptv' && (e.type === 'errors' || e.type === 'drops' || e.type === 'link_down'); });
		var anyPort     = portLink.concat(portSpeed, portErr);

		var allStalls   = by(function(e) { return e.type === 'stream_stall'; });
		var dips        = by(function(e) { return e.type === 'stream_dip'; });
		var tsErr       = by(function(e) { return e.type === 'ts_errors'; });
		var proxyBad    = by(function(e) { return e.type === 'proxy_down' || e.type === 'proxy_restart' ||
			(e.type === 'log' && e.d && e.d.kind === 'proxy_log'); });
		var marks       = byAll(function(e) { return e.type === 'user_mark'; });
		/* Wi-Fi of the watched devices (phone, TV), on both routers */
		var wifiDrop    = byAll(function(e) { return e.type === 'wifi_reconnect' && e.lvl !== 'info'; });
		var wifiWeak    = byAll(function(e) { return e.type === 'wifi_weak'; });
		var wifiBad     = wifiDrop.concat(wifiWeak);
		/* traceroute/mtr snapshots that found where the loss starts */
		var traces      = by(function(e) { return e.type === 'trace' && e.d && e.d.first_bad; });
		/* the second router: freezes seen only there, times it did not report */
		var remoteStalls = remote.filter(function(e) { return e.type === 'stream_stall'; });
		var peerLost    = by(function(e) { return e.type === 'peer_lost'; });
		var busy        = periods(sorted, [ 'cpu_high', 'mem_low', 'conntrack_full' ], to);
		/* single moments from the system log count as short overload periods */
		logOf([ 'conntrack_drop', 'oom', 'dns_limit' ]).forEach(function(e) { busy.push({ from: e.ts, to: e.ts }); });
		var nicHang     = logOf([ 'nic_timeout' ]);

		/* what IGMP did during each freeze is stored on the matching resume event */
		var igmpOf = function(s) {
			var r = nextOf(sorted, s.ts, function(e) { return e.type === 'stream_resume' || e.type === 'stream_lost' || e.type === 'monitor_start'; });
			return (r && r.type === 'stream_resume' && r.d) ? r.d.igmp : null;
		};
		var zaps = [], stalls = [], igmpLeft = [], igmpJoined = [];
		allStalls.forEach(function(s) {
			var ig = igmpOf(s);
			if (ig === 'zap') { zaps.push(s); return; }
			stalls.push(s);
			if (ig === 'left') igmpLeft.push(s);
			else if (ig === 'joined') igmpJoined.push(s);
		});

		var findings = [];
		var add = function(side, base, code, list, args) {
			if (!list.length) return;
			findings.push({
				side: side, code: code, n: list.length, last: lastTs(list), args: args || {},
				weight: side === 'info' ? 0 : base * Math.min(list.length, CAP)
			});
		};

		/* ---- WAN */
		add('edge', 3, 'wan_link', wanLinkDown, { dev: wanDev });

		add('isp', 3, 'wan_down', wanDown.filter(function(e) { return !near(wanLinkDown, e.ts); }));

		var gwOnly = gwLoss.filter(function(e) { return !near(wanDown, e.ts) && !near(wanLinkDown, e.ts); });
		var gwLat  = gwOnly.filter(function(e) { return e.d && !(e.d.loss > 0); });
		add('isp', 2, 'gw_loss', gwOnly.filter(function(e) { return e.d && e.d.loss > 0; }));
		add('isp', 0.5, 'gw_latency', gwLat);
		add('isp', 0.5, 'gw_jitter', gwJitter.filter(function(e) { return !near(wanDown, e.ts) && !near(wanLinkDown, e.ts); }));

		var farOnly = farLoss.filter(function(e) { return !near(gwLoss, e.ts) && !near(wanDown, e.ts); });
		var farHosts = uniq(farOnly, 'src');
		if (farHosts.length >= 2)
			add('isp', 1, 'far_loss', farOnly);
		else
			add('info', 0, 'one_target', farOnly, { host: farHosts[0] });

		add('edge', 1, 'wan_errors', wanErr, { dev: wanDev });

		/* PPPoE/DHCP session dropped while the cable link stayed up */
		add('isp', 2, 'wan_session', wanSess.filter(function(e) { return !near(wanLinkDown, e.ts, 60); }));

		/* what pppd / udhcpc wrote to the system log */
		add('isp', 2, 'log_ppp_echo', pppEcho.filter(function(e) { return !near(wanLinkDown, e.ts, 60); }));
		add('isp', 3, 'log_isp_auth', pppIsp.filter(function(e) { return !near(wanLinkDown, e.ts, 60); }));
		add('info', 0, 'log_ppp_down', pppDown);
		add('home', 3, 'log_nic', nicHang);

		/* ---- router overloaded at the time of the problems */
		var problemsAll = anyWan.concat(allStalls, by(function(e) { return e.area === 'ports' && e.lvl !== 'info'; }))
			.filter(function(e) { return e.type !== 'log'; });
		var duringBusy = problemsAll.filter(function(e) { return inPeriods(busy, e.ts, 20); });
		if (duringBusy.length)
			add('home', 2, 'router_busy', duringBusy);
		else
			add('info', 0, 'router_load', by(function(e) { return e.type === 'cpu_high' || e.type === 'mem_low' || e.type === 'conntrack_full' ||
				(e.type === 'log' && e.d && [ 'conntrack_drop', 'oom', 'dns_limit' ].indexOf(e.d.kind) >= 0); }));

		/* ---- IPTV: classify every stall by what happened at the same time */
		var withWan = [], withPort = [], withDev = [], withProxy = [], lonely = [];
		stalls.forEach(function(s) {
			if (near(proxyBad, s.ts, 60)) withProxy.push(s);
			else if (near(anyWan, s.ts)) withWan.push(s);
			else if (near(anyPort, s.ts)) withPort.push(s);
			else if (near(iptvDevErr, s.ts)) withDev.push(s);
			else lonely.push(s);
		});
		/* lonely freezes where the membership was dropped: IGMP timeout */
		var left = lonely.filter(function(s) { return igmpLeft.indexOf(s) >= 0; });
		lonely = lonely.filter(function(s) { return igmpLeft.indexOf(s) < 0; });

		add('info', 0, 'stall_zap', zaps, { total: allStalls.length });
		var proxyStop = proxyBad.filter(function(e) { return e.type !== 'log'; });
		add('home', 3, 'proxy_down', proxyStop, { name: proxyStop[0] && proxyStop[0].d && proxyStop[0].d.name });
		add('home', 1, 'log_proxy', proxyBad.filter(function(e) { return e.type === 'log'; }));
		add('home', 2, 'stall_with_proxy', withProxy, { total: stalls.length });
		add('isp', 2, 'stall_with_wan', withWan, { total: stalls.length });
		add('home', 2, 'stall_with_port', withPort, { total: stalls.length, devs: uniq(anyPort, 'src').join(', ') });
		add('edge', 1.5, 'stall_with_dev', withDev, { total: stalls.length });

		var period = periodicity(lonely.concat(left));
		var timer = null;
		if (period) {
			[ [ 'membership', ctx.membership_interval ], [ 'query', ctx.query_interval ] ].forEach(function(x) {
				if (!timer && x[1] > 0 && Math.abs(period - x[1]) <= Math.max(15, x[1] * 0.15)) timer = x;
			});
			add('home', timer ? 4 : 3, 'stall_periodic', lonely.concat(left), { period: period, total: stalls.length, timer: timer && timer[0], timer_s: timer && timer[1] });
		}
		else {
			add('home', 3, 'stall_igmp_left', left, { total: stalls.length });
			if (ctx.iptv_direction === 'tx')
				add('home', 1, 'stall_router', lonely, { total: stalls.length });
			else {
				/* still subscribed while the data stopped: stronger hint at the ISP */
				var joined = lonely.filter(function(s) { return igmpJoined.indexOf(s) >= 0; });
				add('isp', 1.5, 'stall_upstream_joined', joined, { total: stalls.length });
				add('isp', 1, 'stall_upstream', lonely.filter(function(s) { return joined.indexOf(s) < 0; }), { total: stalls.length });
			}
		}

		if (stalls.length && ctx.bridge && ctx.bridge.snooping === '1' && ctx.bridge.querier !== '1')
			findings.push({ side: 'home', code: 'no_querier', n: 1, last: 0, weight: 1, args: { bridge: ctx.bridge.name } });
		if (stalls.length && ctx.igmp && ctx.igmp.dev && ctx.igmp.proxy_seen === false && ctx.iptv_direction !== 'tx')
			findings.push({ side: 'info', code: 'no_proxy', n: 1, last: 0, weight: 0, args: {} });

		/* the second router saw a freeze that this router (nearer the ISP) did not:
		 * the stream got lost between the routers or on the second one */
		if (ctx.iptv_on) {
			var onlyThere = remoteStalls.filter(function(e) { return !near(allStalls, e.ts); });
			add('home', 2, 'stall_remote_only', onlyThere, { total: remoteStalls.length, hosts: uniq(onlyThere, 'host').join(', ') });
		}
		add('home', 1, 'peer_lost', peerLost, { hosts: uniq(peerLost, 'src').join(', ') });

		/* ---- path snapshots: the most common hop where the loss started */
		if (traces.length) {
			var hopN = {};
			traces.forEach(function(e) { var k = e.d.first_bad + '|' + (e.d.bad_ip || '?'); hopN[k] = (hopN[k] || 0) + 1; });
			var top = Object.keys(hopN).sort(function(a, b) { return hopN[b] - hopN[a]; })[0].split('|');
			add('isp', 1, +top[0] === 1 ? 'trace_first_hop' : 'trace_hop', traces, { hop: +top[0], ip: top[1], same: hopN[top.join('|')] });
		}

		add(ctx.iptv_direction === 'tx' ? 'info' : 'isp', 0.5, 'stream_dip', dips);
		/* counted on the stream as it arrives, before the router: lost packets are upstream */
		add(ctx.iptv_direction === 'tx' ? 'info' : 'isp', 1.5, 'ts_errors', tsErr);

		/* ---- the user's own reports: was anything measured at that moment? */
		var measured = evAll.filter(function(e) { return e.lvl !== 'info' && e.area !== 'user' && e.area !== 'system' && e.area !== 'wifi'; });
		var seen = [], unseen = [], onWifi = [];
		/* people notice a problem a little after it starts */
		var around = function(list, m) { return list.some(function(e) { return e.ts >= m.ts - 120 && e.ts <= m.ts + 30; }); };
		marks.forEach(function(m) {
			if (around(measured, m)) seen.push(m);
			else if (around(wifiBad, m)) onWifi.push(m);
			else unseen.push(m);
		});
		add('info', 0, 'marks_seen', seen, { total: marks.length });
		/* nothing on the line, but the watched device's Wi-Fi dropped or was weak: that is the proof */
		add('home', 1.5, 'marks_wifi', onWifi, { total: marks.length, devs: uniq(wifiBad.filter(function(e) {
			return onWifi.some(function(m) { return e.ts >= m.ts - 120 && e.ts <= m.ts + 30; }); }), 'src').join(', ') });
		add('info', 0, ctx.wifi_watched ? 'marks_unseen_wifi_ok' : 'marks_unseen', unseen, { total: marks.length });

		/* ---- Wi-Fi */
		add('home', 1, 'wifi_drops', wifiDrop, { devs: uniq(wifiDrop, 'src').join(', ') });
		add('home', 0.5, 'wifi_weak', wifiWeak, { devs: uniq(wifiWeak, 'src').join(', ') });

		/* ---- home network */
		add('home', 2, 'port_speed', portSpeed, { devs: uniq(portSpeed, 'src').join(', ') });
		add('home', 1.5, 'port_link', portLink, { devs: uniq(portLink, 'src').join(', ') });
		add('home', 1, 'port_errors', portErr, { devs: uniq(portErr, 'src').join(', ') });
		add('home', 2, 'dev_missing', portMissing, { devs: uniq(portMissing, 'src').join(', ') });

		/* ---- verdict */
		var isp = 0, home = 0;
		findings.forEach(function(f) {
			if (f.side === 'isp') isp += f.weight;
			else if (f.side === 'home') home += f.weight;
			else if (f.side === 'edge') { isp += f.weight / 2; home += f.weight / 2; }
		});

		var total = isp + home;
		var verdict = (total === 0) ? (findings.length ? 'minor' : 'none')
			: (isp >= home * 2) ? 'isp'
			: (home >= isp * 2) ? 'home'
			: 'mixed';

		var confidence = (total >= 8) ? 'high' : (total >= 3) ? 'medium' : 'low';

		findings.sort(function(a, b) { return b.weight - a.weight || b.last - a.last; });

		return {
			verdict: verdict,
			confidence: confidence,
			isp: isp,
			home: home,
			stalls: stalls.length,
			zaps: zaps.length,
			marks: marks.length,
			problems: evAll.filter(function(e) { return e.lvl !== 'info' && e.type !== 'trace'; }).length,
			findings: findings
		};
	},

	sideText: function(side) {
		switch (side) {
		case 'isp':  return _('ISP');
		case 'home': return _('Router / home');
		case 'edge': return _('Line / ONT');
		default:     return _('Note');
		}
	},

	verdictText: function(v) {
		switch (v) {
		case 'isp':   return _('Most likely an ISP problem');
		case 'home':  return _('Most likely on your side (router / home network)');
		case 'mixed': return _('Mixed – problems on both sides');
		case 'minor': return _('Nothing serious found');
		default:      return _('No problems in this period');
		}
	},

	confidenceText: function(c) {
		switch (c) {
		case 'high':   return _('high confidence');
		case 'medium': return _('medium confidence');
		default:       return _('low confidence – little data');
		}
	},

	findingText: function(f) {
		var a = f.args || {};
		switch (f.code) {
		case 'wan_link':        return _('WAN port lost link %d× – cable to the ONT/modem, or the ONT itself (power, fault).').format(f.n);
		case 'wan_down':        return _('Internet completely down %d× while the WAN link stayed up – outage in the ISP network.').format(f.n);
		case 'gw_loss':         return _('Packet loss already at the ISP gateway (%d×) – problem on the line / ISP access network.').format(f.n);
		case 'gw_latency':      return _('High latency to the ISP gateway (%d×) – congestion at the ISP (or a busy router).').format(f.n);
		case 'gw_jitter':       return _('High jitter to the ISP gateway (%d×) – unstable line or congestion at the ISP (or a busy router).').format(f.n);
		case 'far_loss':        return _('Loss only beyond the gateway (%d×) – ISP backbone / peering.').format(f.n);
		case 'one_target':      return _('Only %s had loss (%d×) – most likely that server, not your connection.').format(a.host, f.n);
		case 'wan_errors':      return _('Errors on the WAN port (%d×) – cable to the ONT/modem or its port.').format(f.n);
		case 'stall_with_wan':  return _('%d of %d IPTV freezes happened together with Internet problems – shared cause on the ISP line.').format(f.n, a.total);
		case 'stall_with_port': return _('%d of %d IPTV freezes coincided with port problems (%s) – cable or switch at home.').format(f.n, a.total, a.devs);
		case 'stall_with_dev':  return _('%d of %d IPTV freezes came with errors on the IPTV device – cable/port on the IPTV path.').format(f.n, a.total);
		case 'stall_periodic':  return a.timer
			? _('IPTV freezes repeat every ~%d s – the same as the bridge\'s IGMP %s interval (%d s): the membership times out. Enable the IGMP querier on the bridge or fix the proxy.').format(a.period, a.timer === 'membership' ? _('membership') : _('query'), a.timer_s)
			: _('IPTV freezes repeat every ~%d s – typical IGMP membership timeout: check the IGMP querier / snooping / proxy on the router.').format(a.period);
		case 'stall_igmp_left': return _('%d of %d IPTV freezes started when the IGMP membership was dropped, then the decoder joined again – IGMP timeout on the router/switch (querier, snooping, proxy).').format(f.n, a.total);
		case 'stall_upstream_joined': return _('%d of %d IPTV freezes: the router stayed subscribed to the channel but the ISP stopped sending – ISP multicast side.').format(f.n, a.total);
		case 'stall_zap':       return _('%d IPTV interruptions were channel changes – ignored.').format(f.n);
		case 'stall_with_proxy': return _('%d of %d IPTV freezes happened when the multicast proxy stopped or restarted.').format(f.n, a.total);
		case 'proxy_down':      return _('Multicast proxy %s stopped or restarted (%d×) – router: check its configuration and the system log.').format(a.name || '', f.n);
		case 'no_proxy':        return _('No multicast proxy (igmpproxy / mcproxy) is running – fine if the IPTV VLAN is bridged, otherwise IPTV cannot work reliably.');
		case 'wan_session':     return _('WAN session dropped/restarted %d× (PPPoE/DHCP) while the cable link stayed up – ISP side (authentication, BRAS, DHCP server).').format(f.n);
		case 'log_ppp_echo':    return _('pppd: the ISP stopped answering LCP echo requests (%d×) – line or ISP access network.').format(f.n);
		case 'log_isp_auth':    return _('pppd/udhcpc: no PPPoE access server, failed authentication or no DHCP lease (%d×) – ISP side.').format(f.n);
		case 'log_ppp_down':    return _('pppd: connection terminated %d× (see the timeline for the reason).').format(f.n);
		case 'log_proxy':       return _('The multicast proxy logged errors (%d×) – check its configuration (upstream / downstream interfaces).').format(f.n);
		case 'log_nic':         return _('Network driver / switch chip hung (%d×, kernel "transmit timed out") – router hardware or driver.').format(f.n);
		case 'router_busy':     return _('%d problems happened while the router was overloaded (CPU / RAM / connection table) – the router itself may be dropping packets.').format(f.n);
		case 'router_load':     return _('The router was overloaded %d× (no problems at those moments).').format(f.n);
		case 'marks_seen':      return _('%d of %d of your reports match a measured problem.').format(f.n, a.total);
		case 'marks_unseen':    return _('%d of %d of your reports have nothing measured around them – the problem is not visible on this router: check the IPTV device setting, or the cause is the decoder, the TV or Wi-Fi.').format(f.n, a.total);
		case 'trace_hop':       return _('Path snapshots (%d): the loss started at hop %d (%s) and carried on to the destination (%d× there) – inside the ISP\'s network or beyond; the hops before it were fine. Show this to the ISP.').format(f.n, a.hop, a.ip, a.same);
		case 'trace_first_hop': return _('Path snapshots (%d): the loss started already at the first hop (%s) – the access line or the ISP\'s first router.').format(f.n, a.ip);
		case 'marks_wifi':      return _('%d of %d of your reports came with a Wi-Fi drop or weak signal of %s, and nothing on the line – the cause is Wi-Fi.').format(f.n, a.total, a.devs);
		case 'marks_unseen_wifi_ok': return _('%d of %d of your reports have nothing measured around them, and the Wi-Fi of the watched devices was fine too – the cause is probably the decoder or the TV (or a device that is not watched).').format(f.n, a.total);
		case 'wifi_drops':      return _('Wi-Fi of %s dropped and reconnected %d× – range, interference or the device\'s power saving.').format(a.devs, f.n);
		case 'wifi_weak':       return _('Weak Wi-Fi signal of %s (%d×) – move the access point or the device, or use a cable.').format(a.devs, f.n);
		case 'stall_router':    return _('%d of %d IPTV freezes: the router stopped sending to the decoder while everything else was fine – IGMP snooping/querier on the router.').format(f.n, a.total);
		case 'stall_upstream':  return _('%d of %d IPTV freezes: multicast stopped arriving from the ISP while Internet and ports were fine – ISP IPTV/multicast side (less often an IGMP issue on the router).').format(f.n, a.total);
		case 'no_querier':      return _('IGMP snooping is on but the querier is off on %s – streams can time out on the switch.').format(a.bridge);
		case 'stream_dip':      return _('IPTV bitrate dropped sharply %d× – unstable stream from the ISP.').format(f.n);
		case 'stall_remote_only': return _('%d of %d IPTV freezes seen by %s did not happen here – the stream is lost between the routers (cable, the second router, its Wi-Fi or switch), not at the ISP.').format(f.n, a.total, a.hosts);
		case 'peer_lost':       return _('Router %s stopped reporting %d× – switched off, rebooted or the cable between the routers.').format(a.hosts, f.n);
		case 'ts_errors':       return _('Lost packets were counted in the IPTV stream (%d×) – the picture glitches come with the stream itself: ISP IPTV/multicast side, not your home network.').format(f.n);
		case 'port_speed':      return _('Link renegotiated to a lower speed (%s, %d×) – damaged cable or connector (e.g. only 2 pairs working).').format(a.devs, f.n);
		case 'port_link':       return _('Link drops on %s (%d×) – cable, connector, power of the connected device, or switch.').format(a.devs, f.n);
		case 'port_errors':     return _('Errors/drops on %s (%d×) – cable or connector.').format(a.devs, f.n);
		case 'dev_missing':     return _('Network device %s disappeared (%d×) – driver, configuration or reboot.').format(a.devs, f.n);
		default:                return f.code;
		}
	}
});
