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
		else if (e.type === 'monitor_start' || e.type === 'data_gap') {
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
/* "1 h 5 min" without the view's helpers (this module has none) */
function fmtSec(s) {
	s = Math.max(0, Math.round(s || 0));
	var h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60);
	if (h) return _('%d h %d min').format(h, m);
	if (m) return _('%d min %d s').format(m, s % 60);
	return _('%d s').format(s);
}

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
		/* ctx.inHours: only these hours of every day count (report) */
		/* e.m: logged during maintenance (the user worked on the network) */
		var evAll = events.filter(function(e) { return e.ts >= from && e.ts <= to && !e.m && (!ctx.inHours || ctx.inHours(e.ts)); });
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
		/* bufferbloat periods: high ping there is the own traffic, not the ISP */
		var bloats      = by(function(e) { return e.type === 'bufferbloat'; });
		var inBloat = function(ts) {
			return bloats.some(function(b) {
				var end = b.ts + 3600;
				for (var i = 0; i < sorted.length; i++)
					if (sorted[i].ts > b.ts && (sorted[i].type === 'bufferbloat_ok' || sorted[i].type === 'monitor_start' || sorted[i].type === 'data_gap')) { end = sorted[i].ts; break; }
				return ts >= b.ts - 60 && ts <= end + 60;
			});
		};
		/* a high ping / jitter (no loss) while the link was full belongs to the bufferbloat finding */
		var bloatLag = function(e) { return e.type === 'target_degraded' && e.d && !(e.d.loss > 0) && inBloat(e.ts); };
		/* IPv6 targets are judged on their own (IPv6 can break while IPv4 works) */
		var isV6 = function(e) { return !!(e.d && e.d.fam === 6); };
		var isLoss = function(e) { return e.area === 'wan' && (e.type === 'target_degraded' || e.type === 'target_fail') && !isJitter(e) && !bloatLag(e) && !isV6(e); };
		var gwJitter = by(function(e) { return e.area === 'wan' && e.src === 'gateway' && isJitter(e) && !bloatLag(e); });

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
		/* IPv6 */
		var v6Down      = by(function(e) { return e.type === 'v6_down'; });
		var v6Pd        = by(function(e) { return e.type === 'v6_pd_lost' || e.type === 'v6_pd_change'; });
		var v6Route     = by(function(e) { return e.type === 'v6_no_route'; });
		var v6If        = by(function(e) { return e.type === 'v6_if_down'; });
		var v6Log       = logOf([ 'dhcp6_fail' ]);
		var v6Loss      = by(function(e) { return e.area === 'wan' && e.type === 'target_degraded' && isV6(e) && e.d.loss > 0; });

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
			var r = nextOf(sorted, s.ts, function(e) { return e.type === 'stream_resume' || e.type === 'stream_lost' || e.type === 'monitor_start' || e.type === 'data_gap'; });
			return (r && r.type === 'stream_resume' && r.d) ? r.d.igmp : null;
		};
		/* decoder restarts (both routers): a freeze while a decoder was away is the decoder, not the stream */
		var decRestarts = byAll(function(e) { return e.type === 'decoder_restart'; });
		var duringRestart = function(s) {
			return decRestarts.some(function(r) { return s.ts >= r.ts - 15 && s.ts <= r.ts + ((r.d && r.d.dur) || 0) + 10; });
		};
		var zaps = [], stalls = [], igmpLeft = [], igmpJoined = [], decStalls = [];
		allStalls.forEach(function(s) {
			var ig = igmpOf(s);
			if (ig === 'zap') { zaps.push(s); return; }
			if (duringRestart(s)) { decStalls.push(s); return; }
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
		/* the optical signal: hard evidence of the line, no ping can say that */
		var sfpLos   = by(function(e) { return e.type === 'sfp_los'; });
		var sfpDrop  = by(function(e) { return e.type === 'sfp_rx_drop'; });
		var sfpAlarm = by(function(e) { return e.type === 'sfp_alarm'; });
		var sfpGone  = by(function(e) { return e.type === 'sfp_gone'; });
		var sfpPer   = periods(sorted, [ 'sfp_los', 'sfp_rx_drop' ], to);
		var maxFall = 0, minRx = null;
		sfpDrop.forEach(function(e) {
			if (e.d && e.d.base != null && e.d.rx != null) maxFall = Math.max(maxFall, e.d.base - e.d.rx);
			if (e.d && e.d.rx != null && (minRx == null || e.d.rx < minRx)) minRx = e.d.rx;
		});
		add('isp', 5, 'sfp_los', sfpLos);
		add('isp', 4, 'sfp_drop', sfpDrop, { fall: Math.round(maxFall * 10) / 10, rx: minRx });
		add('edge', 1, 'sfp_alarm', sfpAlarm, { flags: uniq(sfpAlarm.map(function(e) { return { d: { f: (e.d.flags || []).join(', ') } }; }), 'f').join('; ') });
		add('home', 1.5, 'sfp_gone', sfpGone);
		add('edge', 3, 'wan_link', wanLinkDown, { dev: wanDev });

		var duringSfp = wanDown.concat(wanLinkDown, gwLoss, farLoss, wanSess, pppEcho).filter(function(e) { return inPeriods(sfpPer, e.ts, 30); });
		add('isp', 3, 'sfp_with_wan', duringSfp);

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

		/* IPv6 broken while IPv4 works: browsers try IPv6 first, so pages hang
		 * for a while before falling back - "the Internet is slow" */
		var v6Total = 0, v6Long = 0;
		v6Down.forEach(function(e) {
			var r = nextOf(sorted, e.ts + 1, function(x) { return x.type === 'v6_up' || x.type === 'monitor_start' || x.type === 'data_gap'; });
			var d = (r && r.type === 'v6_up' && r.d) ? r.d.dur : 0;
			v6Total += d; if (d > v6Long) v6Long = d;
		});
		add('isp', 2, 'v6_down', v6Down.filter(function(e) { return !near(wanDown, e.ts, 60); }), { total: v6Total, longest: v6Long });
		add('isp', 1.5, 'v6_prefix', v6Pd, { lost: v6Pd.filter(function(e) { return e.type === 'v6_pd_lost'; }).length,
			changed: v6Pd.filter(function(e) { return e.type === 'v6_pd_change'; }).length });
		add('isp', 1, 'v6_no_ra', v6Route);
		add('isp', 1, 'v6_session', v6If.filter(function(e) { return !near(wanLinkDown, e.ts, 60) && !near(wanSess, e.ts, 60); }));
		add('isp', 1, 'log_dhcp6', v6Log.filter(function(e) { return !near(wanLinkDown, e.ts, 60); }));
		add('isp', 0.5, 'v6_loss', v6Loss.filter(function(e) { return !near(v6Down, e.ts); }));

		/* DNS failing while the line works: the upstream DNS server; during an
		 * outage it is just part of it */
		var dnsFail = by(function(e) { return e.type === 'dns_fail' && !near(anyWan, e.ts, 60); });
		var dnsSrv  = by(function(e) { return e.type === 'dns_server_bad' && !near(anyWan, e.ts, 300); });
		add('isp', 1.5, 'dns_fail', dnsFail);
		add('isp', 1, 'dns_server', dnsSrv, { servers: uniq(dnsSrv, 'src').join(', ') });

		/* who filled the link (nlbwmon / conntrack): the host that was the heaviest most often */
		var hogEv = by(function(e) { return e.type === 'link_hogs' && e.d && e.d.hosts && e.d.hosts.length; });
		var hogTop = null, hogN = {}, hogShare = {};
		hogEv.forEach(function(e) {
			var h = e.d.hosts[0], k = h.name || h.id;
			hogN[k] = (hogN[k] || 0) + 1;
			hogShare[k] = Math.max(hogShare[k] || 0, h.share || 0);
		});
		Object.keys(hogN).forEach(function(k) { if (hogTop == null || hogN[k] > hogN[hogTop]) hogTop = k; });
		add('info', 0, 'link_hogs', hogEv, { host: hogTop, n: hogTop ? hogN[hogTop] : 0, share: hogTop ? Math.round(hogShare[hogTop]) : 0 });

		/* lags only with the link full: own traffic fills a buffer; SQM at home fixes it */
		if (bloats.length) {
			var maxAdd = 0, dirs = {};
			bloats.forEach(function(e) { maxAdd = Math.max(maxAdd, e.d.add || 0); dirs[e.d.dir || 'down'] = true; });
			add('home', 1, 'bufferbloat', bloats, { add: maxAdd, dir: Object.keys(dirs).join('+'),
				lags: by(bloatLag).length, who: hogTop });
		}

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
		/* overheated / throttled: a hot SoC slows the CPU down, so packets are lost */
		var hotPer = periods(sorted, [ 'temp_high', 'throttle' ], to);
		var hotEv  = by(function(e) { return e.type === 'temp_high' || e.type === 'throttle'; });
		var maxTemp = 0, throttled = false;
		hotEv.forEach(function(e) {
			if (e.d && e.d.temp > maxTemp) maxTemp = e.d.temp;
			if (e.type === 'throttle') throttled = true;
		});
		var duringHot = problemsAll.filter(function(e) { return inPeriods(hotPer, e.ts, 20); });
		var duringBusy = problemsAll.filter(function(e) { return inPeriods(busy, e.ts, 20) && duringHot.indexOf(e) < 0; });
		if (duringHot.length)
			add('home', 2.5, 'router_hot', duringHot, { temp: maxTemp, throttled: throttled, events: hotEv.length });
		else
			add('info', 0, 'router_temp', hotEv, { temp: maxTemp, throttled: throttled });
		if (duringBusy.length)
			add('home', 2, 'router_busy', duringBusy);
		else
			add('info', 0, 'router_load', by(function(e) { return e.type === 'cpu_high' || e.type === 'mem_low' || e.type === 'conntrack_full' ||
				(e.type === 'log' && e.d && [ 'conntrack_drop', 'oom', 'dns_limit' ].indexOf(e.d.kind) >= 0); }));

		/* ---- IPTV: classify every stall by what happened at the same time */
		var withWan = [], withPort = [], withDev = [], withProxy = [], withNoQuery = [], lonely = [];
		/* the operator stopped sending IGMP queries: from the first silent moment until they were back */
		var noQuery = periods(sorted, [ 'igmp_noquery' ], to);
		stalls.forEach(function(s) {
			if (near(proxyBad, s.ts, 60)) withProxy.push(s);
			else if (near(anyWan, s.ts)) withWan.push(s);
			else if (near(anyPort, s.ts)) withPort.push(s);
			else if (near(iptvDevErr, s.ts)) withDev.push(s);
			else if (inPeriods(noQuery, s.ts, 30)) withNoQuery.push(s);
			else lonely.push(s);
		});
		/* lonely freezes where the membership was dropped: IGMP timeout */
		var left = lonely.filter(function(s) { return igmpLeft.indexOf(s) >= 0; });
		lonely = lonely.filter(function(s) { return igmpLeft.indexOf(s) < 0; });

		add('info', 0, 'stall_zap', zaps, { total: allStalls.length });
		add('info', 0, 'stall_decoder', decStalls, { total: allStalls.length,
			devs: uniq(decRestarts.filter(function(r) { return decStalls.some(function(s) { return s.ts >= r.ts - 15 && s.ts <= r.ts + ((r.d && r.d.dur) || 0) + 10; }); }), 'src').join(', ') });
		/* a decoder that restarts by itself: power supply, firmware, overheating */
		add('home', 1, 'decoder_restarts', decRestarts, { devs: uniq(decRestarts, 'src').join(', ') });

		/* the decoders' lease at the operator */
		var dhChange = by(function(e) { return e.type === 'dhcp_ip_change'; });
		var dhBad = by(function(e) { return e.type === 'dhcp_nak' || e.type === 'dhcp_expired' || e.type === 'dhcp_late'; });
		add('isp', 1.5, 'dhcp_change', dhChange, { devs: uniq(dhChange, 'src').join(', ') });
		add('isp', 1.5, 'dhcp_bad', dhBad, { devs: uniq(dhBad, 'src').join(', ') });
		var proxyStop = proxyBad.filter(function(e) { return e.type !== 'log'; });
		add('home', 3, 'proxy_down', proxyStop, { name: proxyStop[0] && proxyStop[0].d && proxyStop[0].d.name });
		add('home', 1, 'log_proxy', proxyBad.filter(function(e) { return e.type === 'log'; }));
		add('home', 2, 'stall_with_proxy', withProxy, { total: stalls.length });
		add('isp', 2, 'stall_with_wan', withWan, { total: stalls.length });
		add('home', 2, 'stall_with_port', withPort, { total: stalls.length, devs: uniq(anyPort, 'src').join(', ') });
		add('edge', 1.5, 'stall_with_dev', withDev, { total: stalls.length });
		/* the memberships expired because the operator's queries stopped: not the router's timers */
		add('isp', 3, 'stall_no_query', withNoQuery, { total: stalls.length });
		add('info', 0, 'igmp_noquery', by(function(e) { return e.type === 'igmp_noquery'; }).filter(function(e) { return withNoQuery.length === 0; }));
		/* the operator never asked at all while the freezes went on */
		var iq = ctx.igmpq;
		if (stalls.length && iq && iq.gen === 0 && iq.never)
			findings.push({ side: 'isp', code: 'isp_no_queries', n: 1, last: 0, weight: 2, args: { mins: Math.round((iq.seen_for || 0) / 60) } });

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

		/* ---- what is not known: the router was off or did not measure */
		var reboots = by(function(e) { return e.type === 'router_reboot'; });
		add('home', 1, 'router_reboot', reboots);
		var gapLen = 0, gaps = by(function(e) { return e.type === 'data_gap'; });
		gaps.forEach(function(e) { gapLen += Math.max(0, Math.min(e.d.to, to) - Math.max(e.d.from || e.d.to, from)); });
		add('info', 0, 'not_measured', gaps, { len: gapLen });

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
			decoder_stalls: decStalls.length,
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
		case 'v6_down':         return _('IPv6 did not work while IPv4 did (%d×, %s in total, longest %s) – browsers try IPv6 first, so pages load slowly or hang. ISP IPv6 (prefix, routing) – ask them to check it, or switch IPv6 off as a workaround.').format(f.n, fmtSec(a.total), fmtSec(a.longest));
		case 'v6_prefix':       return _('IPv6 prefix from the ISP lost %d× / changed %d× – devices at home lose or change their IPv6 addresses, open connections break. ISP DHCPv6 (prefix delegation).').format(a.lost, a.changed);
		case 'v6_no_ra':        return _('No IPv6 router advertisement from the ISP (%d×) – the IPv6 default route vanished. ISP side (less often the router\'s firewall dropping ICMPv6).').format(f.n);
		case 'v6_session':      return _('IPv6 (DHCPv6) session dropped %d× while IPv4 stayed up – ISP DHCPv6.').format(f.n);
		case 'log_dhcp6':       return _('odhcp6c: no answer or no prefix from the ISP\'s DHCPv6 server (%d×).').format(f.n);
		case 'v6_loss':         return _('Packet loss over IPv6 only (%d×) – ISP IPv6 routing.').format(f.n);
		case 'dns_fail':        return _('DNS failed %d× while ping worked – pages do not open although the line is fine. The upstream DNS server (the ISP\'s, or the one set in the router) does not answer: try another one.').format(f.n);
		case 'dns_server':      return _('DNS server %s retried or failed many queries (%d×) – slow or overloaded; consider another server.').format(a.servers, f.n);

		case 'stall_with_wan':  return _('%d of %d IPTV freezes happened together with Internet problems – shared cause on the ISP line.').format(f.n, a.total);
		case 'stall_with_port': return _('%d of %d IPTV freezes coincided with port problems (%s) – cable or switch at home.').format(f.n, a.total, a.devs);
		case 'stall_with_dev':  return _('%d of %d IPTV freezes came with errors on the IPTV device – cable/port on the IPTV path.').format(f.n, a.total);
		case 'stall_periodic':  return a.timer
			? _('IPTV freezes repeat every ~%d s – the same as the bridge\'s IGMP %s interval (%d s): the membership times out. Enable the IGMP querier on the bridge or fix the proxy.').format(a.period, a.timer === 'membership' ? _('membership') : _('query'), a.timer_s)
			: _('IPTV freezes repeat every ~%d s – typical IGMP membership timeout: check the IGMP querier / snooping / proxy on the router.').format(a.period);
		case 'stall_no_query':  return _('%d of %d IPTV freezes happened while the operator sent no IGMP queries – the memberships expire without them: ISP multicast side, not the router.').format(f.n, a.total);
		case 'igmp_noquery':    return _('The operator\'s IGMP queries stopped %d× (see the timeline).').format(f.n);
		case 'isp_no_queries':  return _('No IGMP query from the operator was seen in %d min although IPTV freezes occurred – the ISP side does not keep the memberships alive (check that the capture port faces the ISP).').format(a.mins);
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
		case 'link_hogs':       return _('The link was full %d× – %s was the heaviest user in %d of them (up to %d%% of the traffic then). That traffic is your own, not an ISP fault.').format(f.n, a.host, a.n, a.share);
		case 'sfp_los':         return _('No light came from the line (SFP RX at the noise floor, %d×) – the fibre is broken or unplugged, a connector is dirty or loose, or the ISP\'s equipment is down. Hard evidence of a fault in the line, not in the router: clean and re-seat the connector first, then show this to the ISP.').format(f.n);
		case 'sfp_drop':        return _('The received optical power fell %d× (by up to %s dB, down to %s dBm) – a fault in the line: fibre bent or damaged, a dirty or loose connector, a splitter or the ISP\'s side. Hard evidence, no ping can show it.').format(f.n, a.fall, a.rx != null ? a.rx : '?');
		case 'sfp_with_wan':    return _('%d Internet problems happened while the optical signal was weak or gone – they have the same cause, in the line.').format(f.n);
		case 'sfp_alarm':       return _('The SFP module raised an alarm (%d×: %s) – overheating, laser current or voltage; the module may be failing.').format(f.n, a.flags);
		case 'sfp_gone':        return _('The SFP module stopped answering %d× – taken out, or it hung (power, a faulty module).').format(f.n);
		case 'router_hot':      return (a.throttled
			? _('%d problems happened while the router was overheated and its CPU slowed down (up to %s °C) – the router itself loses packets; check ventilation, the heatsink, the case.')
			: _('%d problems happened while the router was overheated (up to %s °C) – the router itself may lose packets; check ventilation, the heatsink, the case.')).format(f.n, a.temp);
		case 'router_temp':     return (a.throttled
			? _('The router overheated and throttled its CPU (up to %s °C, %d×) – no problems at those moments.')
			: _('The router was overheated (up to %s °C, %d×) – no problems at those moments.')).format(a.temp, f.n);
		case 'router_load':     return _('The router was overloaded %d× (no problems at those moments).').format(f.n);
		case 'marks_seen':      return _('%d of %d of your reports match a measured problem.').format(f.n, a.total);
		case 'marks_unseen':    return _('%d of %d of your reports have nothing measured around them – the problem is not visible on this router: check the IPTV device setting, or the cause is the decoder, the TV or Wi-Fi.').format(f.n, a.total);
		case 'bufferbloat':     return _('Bufferbloat %d×: the ping went up by as much as %d ms only while the link was full (%s) – your own traffic fills a buffer in the modem or at the ISP. Not an outage and not the ISP\'s fault: SQM (luci-app-sqm, cake) set a bit below the line speed fixes it.').format(f.n, a.add,
			a.dir === 'up' ? _('upload') : a.dir === 'down' ? _('download') : _('download and upload')) +
			(a.who ? ' ' + _('Heaviest at those times: %s.').format(a.who) : '') +
			(a.lags ? ' ' + _('%d high-ping warnings at those times are not counted against the ISP.').format(a.lags) : '');
		case 'stall_decoder':   return _('%d of %d IPTV freezes happened while a decoder (%s) restarted – the decoder, not a lost stream; not counted against the ISP.').format(f.n, a.total, a.devs);
		case 'decoder_restarts': return _('Decoder %s restarted %d× – power supply, firmware update or overheating (or someone switched it off and on).').format(a.devs, f.n);
		case 'dhcp_change':     return _('The operator gave decoder %s a different address %d× – each change interrupts the picture; the operator\'s DHCP (address pool, lease).').format(a.devs, f.n);
		case 'dhcp_bad':        return _('Decoder %s: lease refused or not renewed in time (%d×) – the operator\'s DHCP server.').format(a.devs, f.n);
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
		case 'router_reboot':   return _('The router restarted %d× – a power cut, a crash or on purpose. Problems at those moments are not the ISP\'s.').format(f.n);
		case 'not_measured':    return _('Not measured for %s in this period (%d×: router off, monitoring off) – nothing is known about that time.').format(fmtSec(a.len), f.n);

		default:                return f.code;
		}
	}
});
