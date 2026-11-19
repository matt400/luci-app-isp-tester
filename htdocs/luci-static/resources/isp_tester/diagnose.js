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
	list.forEach(function(e) { var k = e[key] != null ? e[key] : (e.d && e.d[key]); if (!seen[k]) { seen[k] = true; out.push(k); } });
	return out;
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
	/* allow for the sampling interval jitter */
	return (sd / mean < 0.2 || sd <= 12) ? Math.round(mean) : null;
}

return baseclass.extend({
	/*
	 * events: [{ ts, lvl, area, src, type, d }]
	 * ctx: { wan_device, iptv_direction, bridge: { name, snooping, querier } }
	 */
	analyze: function(events, from, to, ctx) {
		ctx = ctx || {};
		var ev = events.filter(function(e) { return e.ts >= from && e.ts <= to; });
		var by = function(f) { return ev.filter(f); };

		var wanDev = ctx.wan_device;
		var isLoss = function(e) { return e.area === 'wan' && (e.type === 'target_degraded' || e.type === 'target_fail'); };

		var wanLinkDown = by(function(e) { return e.type === 'link_down' && (e.area === 'wan' || e.src === wanDev); });
		var wanDown     = by(function(e) { return e.type === 'wan_down'; });
		var gwLoss      = by(function(e) { return isLoss(e) && e.src === 'gateway'; });
		var farLoss     = by(function(e) { return isLoss(e) && e.src !== 'gateway'; });
		var anyWan      = gwLoss.concat(farLoss, wanDown, wanLinkDown);

		var portLink    = by(function(e) { return e.area === 'ports' && (e.type === 'link_down' || e.type === 'link_flap'); });
		var portSpeed   = by(function(e) { return e.area === 'ports' && e.type === 'speed_change' && e.d && e.d.to < e.d.from; });
		var portErr     = by(function(e) { return e.area === 'ports' && (e.type === 'errors' || e.type === 'drops'); });
		var portMissing = by(function(e) { return e.type === 'dev_missing'; });
		var wanErr      = by(function(e) { return e.area === 'wan' && e.type === 'errors'; });
		var iptvDevErr  = by(function(e) { return e.area === 'iptv' && (e.type === 'errors' || e.type === 'drops' || e.type === 'link_down'); });
		var anyPort     = portLink.concat(portSpeed, portErr);

		var stalls      = by(function(e) { return e.type === 'stream_stall'; });
		var dips        = by(function(e) { return e.type === 'stream_dip'; });

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

		var farOnly = farLoss.filter(function(e) { return !near(gwLoss, e.ts) && !near(wanDown, e.ts); });
		var farHosts = uniq(farOnly, 'src');
		if (farHosts.length >= 2)
			add('isp', 1, 'far_loss', farOnly);
		else
			add('info', 0, 'one_target', farOnly, { host: farHosts[0] });

		add('edge', 1, 'wan_errors', wanErr, { dev: wanDev });

		/* ---- IPTV: classify every stall by what happened at the same time */
		var withWan = [], withPort = [], withDev = [], lonely = [];
		stalls.forEach(function(s) {
			if (near(anyWan, s.ts)) withWan.push(s);
			else if (near(anyPort, s.ts)) withPort.push(s);
			else if (near(iptvDevErr, s.ts)) withDev.push(s);
			else lonely.push(s);
		});

		add('isp', 2, 'stall_with_wan', withWan, { total: stalls.length });
		add('home', 2, 'stall_with_port', withPort, { total: stalls.length, devs: uniq(anyPort, 'src').join(', ') });
		add('edge', 1.5, 'stall_with_dev', withDev, { total: stalls.length });

		var period = periodicity(lonely);
		if (period)
			add('home', 3, 'stall_periodic', lonely, { period: period, total: stalls.length });
		else if (ctx.iptv_direction === 'tx')
			add('home', 1, 'stall_router', lonely, { total: stalls.length });
		else
			add('isp', 1, 'stall_upstream', lonely, { total: stalls.length });

		if (stalls.length && ctx.bridge && ctx.bridge.snooping === '1' && ctx.bridge.querier !== '1')
			findings.push({ side: 'home', code: 'no_querier', n: 1, last: 0, weight: 1, args: { bridge: ctx.bridge.name } });

		add(ctx.iptv_direction === 'tx' ? 'info' : 'isp', 0.5, 'stream_dip', dips);

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
			problems: ev.filter(function(e) { return e.lvl !== 'info'; }).length,
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
		case 'far_loss':        return _('Loss only beyond the gateway (%d×) – ISP backbone / peering.').format(f.n);
		case 'one_target':      return _('Only %s had loss (%d×) – most likely that server, not your connection.').format(a.host, f.n);
		case 'wan_errors':      return _('Errors on the WAN port (%d×) – cable to the ONT/modem or its port.').format(f.n);
		case 'stall_with_wan':  return _('%d of %d IPTV freezes happened together with Internet problems – shared cause on the ISP line.').format(f.n, a.total);
		case 'stall_with_port': return _('%d of %d IPTV freezes coincided with port problems (%s) – cable or switch at home.').format(f.n, a.total, a.devs);
		case 'stall_with_dev':  return _('%d of %d IPTV freezes came with errors on the IPTV device – cable/port on the IPTV path.').format(f.n, a.total);
		case 'stall_periodic':  return _('IPTV freezes repeat every ~%d s – typical IGMP membership timeout: check the IGMP querier / snooping / proxy on the router.').format(a.period);
		case 'stall_router':    return _('%d of %d IPTV freezes: the router stopped sending to the decoder while everything else was fine – IGMP snooping/querier on the router.').format(f.n, a.total);
		case 'stall_upstream':  return _('%d of %d IPTV freezes: multicast stopped arriving from the ISP while Internet and ports were fine – ISP IPTV/multicast side (less often an IGMP issue on the router).').format(f.n, a.total);
		case 'no_querier':      return _('IGMP snooping is on but the querier is off on %s – streams can time out on the switch.').format(a.bridge);
		case 'stream_dip':      return _('IPTV bitrate dropped sharply %d× – unstable stream from the ISP.').format(f.n);
		case 'port_speed':      return _('Link renegotiated to a lower speed (%s, %d×) – damaged cable or connector (e.g. only 2 pairs working).').format(a.devs, f.n);
		case 'port_link':       return _('Link drops on %s (%d×) – cable, connector, power of the connected device, or switch.').format(a.devs, f.n);
		case 'port_errors':     return _('Errors/drops on %s (%d×) – cable or connector.').format(a.devs, f.n);
		case 'dev_missing':     return _('Network device %s disappeared (%d×) – driver, configuration or reboot.').format(a.devs, f.n);
		default:                return f.code;
		}
	}
});
