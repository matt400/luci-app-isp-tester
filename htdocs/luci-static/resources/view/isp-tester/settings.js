'use strict';
'require view';
'require form';
'require tools.widgets as widgets';
'require rpc';
'require ui';
'require dom';
'require fs';

var callTestNotify = rpc.declare({
	object: 'luci.isp_tester',
	method: 'test_notify',
	expect: { '': {} }
});

var callStatus = rpc.declare({
	object: 'luci.isp_tester',
	method: 'status',
	expect: { '': {} }
});

var callChannels = rpc.declare({
	object: 'luci.isp_tester',
	method: 'channels',
	expect: { channels: {} }
});

var callChannelsForget = rpc.declare({
	object: 'luci.isp_tester',
	method: 'channels_forget',
	expect: { '': {} }
});

/* sort "239.1.1.10" after "239.1.1.9" */
function ipKey(g) {
	return (g || '').split('.').map(function(x) { return ('00' + x).slice(-3); }).join('.');
}

/* table of the names learned from the streams, with a button to forget them */
function renderLearned(db) {
	var groups = Object.keys(db || {}).sort(function(a, b) { return ipKey(a) < ipKey(b) ? -1 : 1; });
	var box = E('div', {});
	if (!groups.length) {
		box.appendChild(E('em', {}, _('No names found yet. They appear after a channel has been watched for a few seconds.')));
		return box;
	}
	var rows = groups.map(function(g) {
		var e = db[g];
		return E('tr', { 'class': 'tr' }, [
			/* name and provider come from the stream itself: text nodes, a
			 * plain string child would be put in as HTML */
			E('td', { 'class': 'td', 'style': 'font-family:monospace' }, [ g ]),
			E('td', { 'class': 'td' }, e.name ? [ e.name ] : E('em', {},
				e.why === 'no_sdt' ? _('no name in the stream') : _('not found'))),
			E('td', { 'class': 'td' }, [ e.provider || '' ]),
			E('td', { 'class': 'td' }, e.sid != null ? String(e.sid) : '')
		]);
	});
	box.appendChild(E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Group')), E('th', { 'class': 'th' }, _('Name')),
			E('th', { 'class': 'th' }, _('Provider')), E('th', { 'class': 'th' }, _('Service ID'))
		])
	].concat(rows)));
	box.appendChild(E('button', { 'class': 'cbi-button cbi-button-reset', 'click': ui.createHandlerFn(null, function() {
		return callChannelsForget().then(function(r) {
			ui.addNotification(null, E('p', r && r.running
				? _('Learned names will be forgotten within one interval and read again from the streams.')
				: _('Monitoring is not running.')), 'info');
		});
	}) }, _('Forget learned names')));
	return box;
}

var callPushStatus = rpc.declare({
	object: 'luci.isp_tester',
	method: 'push_status',
	expect: { '': {} }
});

var callPushPubkey = rpc.declare({
	object: 'luci.isp_tester',
	method: 'push_pubkey',
	expect: { '': {} }
});

var callPushTest = rpc.declare({
	object: 'luci.isp_tester',
	method: 'push_test',
	expect: { '': {} }
});

var callPushNow = rpc.declare({
	object: 'luci.isp_tester',
	method: 'push_now',
	expect: { '': {} }
});

var PUSH_ERR = {
	no_target: _('Set the address and the user first, then Save & Apply.'),
	bad_host: _('The address is not valid.'),
	bad_user: _('The user name is not valid.'),
	bad_port: _('The port is not valid.'),
	bad_dir: _('The folder is not valid (letters, digits and . _ / ~ - only, no “..”).'),
	bad_key: _('The key path is not valid.'),
	no_dbclient: _('dbclient (package dropbear) is not installed.'),
	no_dropbearkey: _('dropbearkey (package dropbear) is not installed.'),
	keygen: _('The key could not be made.'),
	no_pubkey: _('The public key could not be read.'),
	login: _('Login failed. Add the public key to ~/.ssh/authorized_keys of that user on the other device.'),
	timeout: _('No answer from the other device – check the address, the port and that its SSH server is running.'),
	rpc: _('The router did not answer the request.'),
	send: _('Sending failed.'),
	busy: _('A transfer is running already.'),
	no_data: _('There is no data to send yet.'),
	tar: _('The files could not be packed.')
};

function pushError(r) {
	var t = (r && PUSH_ERR[r.error]) || _('Failed: %s').format((r && (r.error || r.out)) || '?');
	return (r && r.out && r.error !== 'script') ? t + ' (' + r.out + ')' : t;
}

function pushStatusText(st) {
	var l = st && st.last;
	if (!l) return _('Nothing sent yet.');
	if (l.state === 'running') return _('Sending…');
	var when = new Date((l.done || l.ts) * 1000).toLocaleString(LOCALE);
	if (l.ok)
		return _('Last sent: %s – %s (%d kB) to %s.').format(when, l.name, Math.round((l.size || 0) / 1024), l.host || '?');
	return _('Last try failed (%s): %s').format(when, pushError({ error: l.err, out: l.out }));
}

/* the language set in LuCI (System → Language), for dates and numbers */
var LOCALE = (function() {
	var l = (document.documentElement.getAttribute('lang') || '').replace(/_/g, '-');
	if (!l || l === 'auto') return undefined;
	try { Intl.DateTimeFormat.supportedLocalesOf([ l ]); return l; } catch (e) { return undefined; }
})();

/* ask push_status every 2 s until done() says so or the time is up */
function waitPush(done, secs) {
	var until = Date.now() + secs * 1000;
	return new Promise(function(resolve) {
		var step = function() {
			callPushStatus().then(function(st) {
				if (done(st) || Date.now() > until) resolve(st);
				else window.setTimeout(step, 2000);
			}, function() {
				if (Date.now() > until) resolve(null);
				else window.setTimeout(step, 2000);
			});
		};
		window.setTimeout(step, 1500);
	});
}

/* public key, test and "send now"; they use the saved settings */
function renderPush() {
	var status = E('div', { 'style': 'margin:.4em 0' }, _('Loading…'));
	/* the result of "Test the login" stays here, not only in a notification */
	var test = E('div', { 'style': 'margin:.4em 0;font-weight:bold' });
	var key = E('textarea', { 'readonly': 'readonly', 'rows': 3, 'style': 'width:100%;font-family:monospace;display:none' });
	var refresh = function() {
		return callPushStatus().then(function(st) { status.textContent = pushStatusText(st); },
			function() { status.textContent = _('No answer from the router.'); });
	};
	/* the text may hold what the other device's SSH answered: a text node */
	var note = function(text, cls) { ui.addNotification(null, E('p', {}, [ text ]), cls); };

	refresh();

	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, _('Key and transfer')),
		E('div', { 'class': 'cbi-value-field' }, [
			E('div', { 'class': 'cbi-value-description' }, _('Save & Apply the settings first, then add the public key to <code>~/.ssh/authorized_keys</code> of the user on the other device. The first login also trusts that device\'s host key; a changed one is refused.')),
			E('div', { 'style': 'display:flex;gap:.5em;flex-wrap:wrap;margin:.4em 0' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.createHandlerFn(this, function() {
					return callPushPubkey().then(function(r) {
						if (r && r.result) { key.value = r.pubkey; key.style.display = ''; key.select(); }
						else note(pushError(r), 'danger');
					}, function(e) { note(pushError({ error: 'rpc', out: e && e.message }), 'danger'); });
				}) }, _('Show the public key')),
				E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(this, function() {
					test.textContent = _('Logging in to the other device…');
					test.style.color = '';
					return callPushTest().then(function(r) {
						if (!r || !r.result) { test.textContent = ''; note(pushError(r), 'danger'); return; }
						var t0 = r.ts || 0;
						return waitPush(function(st) {
							return st && st.test && st.test.ts >= t0 && st.test.state !== 'running';
						}, 40).then(function(st) {
							var res = st && st.test && st.test.ts >= t0 && st.test.state !== 'running' ? st.test : { result: false, error: 'timeout' };
							test.textContent = res.result ? _('Login works.') : pushError(res);
							test.style.color = res.result ? '#2e9d4f' : '#d64541';
							note(test.textContent, res.result ? 'info' : 'danger');
						});
					}, function(e) {
						test.textContent = '';
						note(pushError({ error: 'rpc', out: e && e.message }), 'danger');
					});
				}) }, _('Test the login')),
				E('button', { 'class': 'cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, function() {
					return callPushNow().then(function() {
						status.textContent = _('Sending…');
						return waitPush(function(st) { return st && st.last && st.last.state !== 'running'; }, 300).then(function(st) {
							if (st) status.textContent = pushStatusText(st);
						});
					}, function(e) { note(pushError({ error: 'rpc', out: e && e.message }), 'danger'); });
				}) }, _('Send now'))
			]),
			test,
			key,
			status
		])
	]);
}

/* tabs of the settings page, in this order; sections are put into them by place() */
var TABS = [
	[ 'general',  _('General') ],
	[ 'wan',      _('Internet (WAN)') ],
	[ 'iptv',     _('IPTV') ],
	[ 'channels', _('Channel names') ],
	[ 'decoders', _('Decoders') ],
	[ 'ports',    _('Ports') ],
	[ 'system',   _('Router load') ],
	[ 'dns',      _('DNS') ],
	[ 'notify',   _('Notifications') ],
	[ 'peer',     _('Second router') ],
	[ 'push',     _('Send data') ]
];

/* put a section into a tab; the tab name replaces the section title unless keepTitle */
function place(s, tab, keepTitle) {
	s.isptab = tab;
	if (!keepTitle) s.hidetitle = true;
	return s;
}

/*
 * Map that groups its sections into tabs (by s.isptab). The panes are built
 * here, before LuCI initialises the tab groups, so the nested IPTV
 * Basic/Advanced tabs and the last open tab are kept after Save & Apply.
 */
var TabbedMap = form.Map.extend({
	renderChildren: function(tab_name) {
		return this.super('renderChildren', arguments).then(L.bind(function(nodes) {
			if (tab_name != null) return nodes;

			var kids = this.children.filter(function(c) { return !c.disable; });
			var panes = {};

			nodes.forEach(function(node, i) {
				var t = (kids[i] && kids[i].isptab) || TABS[0][0];
				(panes[t] = panes[t] || []).push(node);
			});

			return [ E('div', { 'class': 'cbi-map-tabbed' }, TABS.filter(function(t) {
				return panes[t[0]];
			}).map(function(t) {
				return E('div', { 'data-tab': t[0], 'data-tab-title': t[1] }, panes[t[0]]);
			})) ];
		}, this));
	}
});

return view.extend({
	load: function() {
		return Promise.all([
			callChannels().catch(function() { return {}; }),
			callStatus().catch(function() { return {}; })
		]);
	},

	render: function(data) {
		var m, s, o;
		var learned = data[0];
		var state = (data[1] && data[1].state) || {};

		m = new TabbedMap('isp_tester', _('ISP Tester – Settings'),
			_('Changes are applied immediately after “Save & Apply”; the collector restarts, keeping the timeline (charts start over).'));

		/* ---- general */
		s = m.section(form.NamedSection, 'general', 'general', _('General'));
		place(s, 'general');

		o = s.option(form.Flag, 'enabled', _('Enable monitoring'),
			_('Turns the whole package on or off, including start at boot. Can also be switched on the overview page.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'interval', _('Sampling interval'), _('Seconds between measurements.'));
		o.datatype = 'range(2,300)';
		o.placeholder = '10';

		o = s.option(form.Value, 'max_samples', _('Measurements kept'),
			_('Rows kept in the CSV (in RAM). 8640 rows × 10 s = 24 h.'));
		o.datatype = 'range(100,100000)';
		o.placeholder = '8640';

		o = s.option(form.Value, 'max_events', _('Timeline entries kept'));
		o.datatype = 'range(50,20000)';
		o.placeholder = '1000';

		o = s.option(form.Value, 'history', _('Chart points'), _('360 points × 10 s = last hour.'));
		o.datatype = 'range(30,2000)';
		o.placeholder = '360';

		o = s.option(form.Value, 'warn_window', _('Stay yellow for'),
			_('Seconds an area stays marked as “Warning” after a problem was logged.'));
		o.datatype = 'uinteger';
		o.placeholder = '900';

		o = s.option(form.Value, 'drop_warn', _('Dropped packets threshold'),
			_('Dropped packets per interval needed to log an entry. Some drops are normal (unknown protocols).'));
		o.datatype = 'uinteger';
		o.placeholder = '50';

		o = s.option(form.Value, 'data_dir', _('Keep data on'),
			_('Optional folder on a USB stick (e.g. <code>/mnt/sda1</code>, mounted via System → Mount Points). <code>/tmp/isp-tester</code> becomes a link to it, so the timeline, history and CSV survive a reboot. Written: every event, the history once a minute, one CSV line per interval. Do not use the internal flash. Empty = RAM.'));
		o.placeholder = '/mnt/sda1';
		o.optional = true;

		o = s.option(form.Flag, 'logread', _('Read the system log'),
			_('Turns messages of other services into timeline events: pppd (LCP echo timeouts, authentication, PPPoE discovery), udhcpc (lease lost), igmpproxy/mcproxy errors, kernel (network driver hang, connection table full, out of memory), dnsmasq (query limit).'));
		o.default = '1';
		o.rmempty = false;

		/* ---- WAN */
		s = m.section(form.NamedSection, 'wan', 'wan', _('Internet (WAN)'),
			_('Ping is not measured here but taken from collectd: install <code>luci-app-statistics</code> and <code>collectd-mod-ping</code>, enable the Ping plugin and add the ISP gateway and one or two far hosts (e.g. 1.1.1.1, 8.8.8.8). Enable the UnixSock plugin (<code>collectd-mod-unixsock</code>) for live values; without it the values are read from the RRD files and lag behind by the cache time.'));
		place(s, 'wan');

		o = s.option(form.Flag, 'enabled', _('Monitor Internet'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(widgets.NetworkSelect, 'interface', _('WAN interface'),
			_('Used to find the WAN device and the ISP gateway.'));
		o.nocreate = true;
		o.default = 'wan';

		o = s.option(widgets.DeviceSelect, 'device', _('WAN device (override)'),
			_('Leave empty to detect it from the interface.'));
		o.noaliases = true;
		o.optional = true;

		o = s.option(form.Value, 'gateway', _('ISP gateway host'),
			_('Which of the collectd ping hosts is the ISP gateway. Empty = the gateway netifd reports for the WAN interface. Loss to the gateway points at the line / ISP access network; loss only to far hosts points at the ISP backbone.'));
		o.datatype = 'host';
		o.optional = true;

		o = s.option(form.Value, 'loss_warn', _('Loss for warning (%)'));
		o.datatype = 'range(1,100)';
		o.placeholder = '1';

		o = s.option(form.Value, 'loss_fail', _('Loss for fault (%)'));
		o.datatype = 'range(1,100)';
		o.placeholder = '50';

		o = s.option(form.Value, 'rtt_warn', _('High latency (ms)'), _('0 disables the latency warning.'));
		o.datatype = 'uinteger';
		o.placeholder = '80';

		o = s.option(form.Value, 'jitter_warn', _('High jitter (ms)'),
			_('Standard deviation of the ping time as reported by collectd. Matters for calls, games and IPTV over unicast. 0 = no warning.'));
		o.datatype = 'uinteger';
		o.placeholder = '0';

		o = s.option(form.Flag, 'ipv6', _('Watch IPv6'),
			_('Often IPv4 works and only IPv6 breaks – then pages hang for a while, because the browser tries IPv6 first. Logged from what odhcp6c reports to netifd: the DHCPv6 session, the delegated prefix (lost or changed) and the default route from the ISP\'s router advertisement. For the ping over IPv6 add one or two IPv6 hosts (e.g. <code>2606:4700:4700::1111</code>, <code>2001:4860:4860::8888</code>) to the collectd Ping plugin: when all of them fail while IPv4 targets answer, “IPv6 down” is logged.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(widgets.NetworkSelect, 'interface6', _('IPv6 interface'),
			_('The DHCPv6 interface. Empty = <code>wan6</code>, or <code>wan_6</code> when IPv6 is set to automatic on the WAN interface.'));
		o.nocreate = true;
		o.optional = true;
		o.depends('ipv6', '1');

		o = s.option(form.Value, 'ra_after', _('No router advertisement after (s)'),
			_('How long the IPv6 default route may be missing before it is logged.'));
		o.datatype = 'range(10,3600)';
		o.placeholder = '60';
		o.depends('ipv6', '1');

		o = s.option(form.Flag, 'trace', _('Path snapshot at a loss'),
			_('When a loss starts (or the connection is down), one traceroute is run to a far target – <code>mtr</code> when installed (10 rounds, more precise), otherwise the busybox <code>traceroute</code>. The timeline then shows at which hop the loss starts and carries on to the destination: concrete proof for the ISP. Takes a few seconds, at most once per the time below.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'trace_cooldown', _('At most every (s)'));
		o.datatype = 'range(60,86400)';
		o.placeholder = '600';
		o.depends('trace', '1');

		o = s.option(form.Flag, 'bloat', _('Detect bufferbloat'),
			_('Compares the ping from collectd with the WAN traffic of the same interval: when the ping goes up only while the link is full, the lag is your own traffic filling a buffer (modem, ISP) – not an outage, and SQM fixes it. No speed test is run: the line speed is the highest rate seen, or the values below.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'bloat_ms', _('Ping increase (ms)'), _('Above the ping at low load, twice in a row.'));
		o.datatype = 'range(5,1000)';
		o.placeholder = '30';
		o.depends('bloat', '1');

		o = s.option(form.Value, 'bloat_load', _('Link full from (%)'));
		o.datatype = 'range(30,100)';
		o.placeholder = '70';
		o.depends('bloat', '1');

		o = s.option(form.Flag, 'sfp', _('Optical signal (SFP / ONT)'),
			_('When the WAN goes through an SFP module or an ONT in an SFP cage, read its RX / TX power and temperature (ethtool -m). A fall of the received power is a hard proof of a fault in the line. Shown only when the module answers; needs the ethtool package.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(widgets.DeviceSelect, 'sfp_device', _('SFP port (override)'),
			_('Empty = the physical port of the WAN interface.'));
		o.noaliases = true;
		o.optional = true;
		o.depends('sfp', '1');

		o = s.option(form.Value, 'sfp_drop_db', _('Weaker signal from (dB)'),
			_('A fall of the received power below its usual level by this much, two readings in a row.'));
		o.datatype = 'ufloat';
		o.placeholder = '3';
		o.depends('sfp', '1');

		o = s.option(form.Value, 'sfp_rx_min', _('Received power below (dBm)'),
			_('Also a fault below this level. Empty = the module\'s own low-power warning only.'));
		o.datatype = 'range(-50,-1)';
		o.optional = true;
		o.placeholder = '-27';
		o.depends('sfp', '1');

		o = s.option(form.Value, 'down_mbit', _('Download speed (Mbit/s)'), _('Of your plan. Empty = the highest rate seen.'));
		o.datatype = 'ufloat';
		o.optional = true;
		o.depends('bloat', '1');

		o = s.option(form.Value, 'up_mbit', _('Upload speed (Mbit/s)'), _('Of your plan. Empty = the highest rate seen.'));
		o.datatype = 'ufloat';
		o.optional = true;
		o.depends('bloat', '1');

		/* ---- IPTV */
		s = m.section(form.NamedSection, 'iptv', 'iptv', _('IPTV'),
			_('Usually it is enough to enter the IPTV VLAN of your ISP. The bridge, the port towards the ISP and the decoder ports are then found automatically.'));
		place(s, 'iptv');
		s.tab('basic', _('Basic'));
		s.tab('advanced', _('Advanced'));

		o = s.taboption('basic', form.Flag, 'enabled', _('Monitor IPTV'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'vlan', _('IPTV VLAN'),
			_('VLAN number of the IPTV service (e.g. <code>236</code>). For a VLAN that is only bridged to the decoders – no <code>eth1.236</code> or <code>br-lan.236</code> device on the router – the bitrate is read from the bridge\'s per-VLAN counters (they are switched on automatically) and the channels from the bridge\'s multicast table, separately for each decoder port. Leave empty to choose a device under “Advanced”.'));
		o.datatype = 'range(1,4094)';
		o.placeholder = '236';
		o.optional = true;

		o = s.taboption('advanced', widgets.DeviceSelect, 'upstream', _('Port towards the ISP'),
			_('VLAN mode only. Empty = detected (the bridge port of the VLAN that is not a switch or Wi-Fi port, e.g. <code>eth1</code>).'));
		o.noaliases = true;
		o.optional = true;

		o = s.taboption('advanced', widgets.DeviceSelect, 'device', _('IPTV device'),
			_('Only when no VLAN is set: a device that carries only IPTV traffic (e.g. <code>eth1.236</code>) or the port the decoder is connected to. Watch TV and check that the bitrate on the overview matches.'));
		o.noaliases = true;
		o.optional = true;
		o.depends('vlan', '');

		o = s.taboption('advanced', form.ListValue, 'direction', _('Measure'));
		o.value('rx', _('Incoming traffic (VLAN from the ISP)'));
		o.value('tx', _('Outgoing traffic (port towards the decoder)'));
		o.default = 'rx';
		o.depends('vlan', '');

		o = s.taboption('advanced', widgets.DeviceSelect, 'bridge', _('Bridge for IGMP status'),
			_('Shows whether IGMP snooping and the querier are active on this bridge. In VLAN mode it is detected automatically.'));
		o.noaliases = true;
		o.optional = true;

		o = s.taboption('basic', form.Value, 'min_kbps', _('Stream threshold (kbit/s)'),
			_('Below this the stream counts as stopped. An HD channel usually uses 4000–12000 kbit/s.'));
		o.datatype = 'uinteger';
		o.placeholder = '500';

		o = s.taboption('advanced', form.Value, 'sample_interval', _('IPTV sampling interval (s)'),
			_('How often the IPTV bitrate is measured, independent of the main interval. 1 s catches freezes of a few seconds; 0 measures only once per main interval.'));
		o.datatype = 'or(0,range(0.5,10))';
		o.placeholder = '1';

		o = s.taboption('basic', form.Value, 'stall_after', _('Freeze after (s)'),
			_('How long the bitrate must stay below the threshold to log a freeze. 2 s ignores single short gaps the decoder buffer hides.'));
		o.datatype = 'range(0,60)';
		o.placeholder = '2';

		o = s.taboption('advanced', form.Value, 'idle_after', _('Decoder off after (s)'),
			_('If the stream does not come back within this time, it is logged as “ended” instead of an ongoing outage.'));
		o.datatype = 'range(5,3600)';
		o.placeholder = '60';

		o = s.taboption('advanced', form.Value, 'off_after', _('Decoder switched off after (s)'),
			_('If the stream stops and no channel is subscribed any more (IGMP), for this long, it is logged as the decoder being switched off, not as a fault. 0 disables. Needs IGMP watching.'));
		o.datatype = 'range(0,300)';
		o.placeholder = '15';

		o = s.taboption('advanced', form.Value, 'dip_pct', _('Bitrate dip warning (%)'),
			_('Warn when the bitrate falls below this percentage of its usual value. 0 disables.'));
		o.datatype = 'range(0,100)';
		o.placeholder = '40';

		o = s.taboption('basic', form.Flag, 'quality', _('Picture quality'),
			_('Counts lost packets (MPEG-TS continuity errors) in the IPTV stream – what a viewer sees as pixelation – continuously, every packet of the channel being watched. Needs the isp-tester-tsmon package.'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('advanced', form.Value, 'q_warn', _('Warn from (errors per minute)'),
			_('Lost-packet gaps within one minute that turn the status yellow and are logged.'));
		o.datatype = 'min(1)';
		o.placeholder = '1';
		o.depends({ quality: '1' });

		o = s.taboption('advanced', form.Value, 'q_fail', _('Fault from (errors per minute)'),
			_('Lost-packet gaps within one minute that are logged as a fault.'));
		o.datatype = 'min(1)';
		o.placeholder = '30';
		o.depends({ quality: '1' });

		o = s.taboption('advanced', form.Value, 'q_gap', _('Pause warning (ms)'),
			_('Also warn when the stream pauses this long, even without lost packets (delivery in bursts). 0 disables.'));
		o.datatype = 'range(0,5000)';
		o.placeholder = '500';
		o.depends({ quality: '1' });

		o = s.taboption('basic', form.Flag, 'igmp', _('Watch IGMP'),
			_('Tracks which multicast groups (channels) are joined and whether the multicast proxy (igmpproxy, mcproxy) is running. This tells a channel change from a freeze, and an IGMP timeout from the ISP not sending.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('basic', form.Flag, 'igmp_query', _('Watch the operator\'s IGMP queries'),
			_('Shows how long ago the operator sent its last IGMP general query and warns when they stop: without them the memberships expire after about two intervals and the stream freezes. Works on the port facing the ISP (incoming traffic). Needs the isp-tester-tsmon package.'));
		o.default = '1';
		o.rmempty = false;
		o.depends('igmp', '1');

		o = s.taboption('basic', form.Flag, 'names', _('Identify channel names'),
			_('Reads the name of each channel from the stream itself (DVB service table, sent in the clear also on encrypted channels), by the same helper as the picture quality. Names are shown on the status page, in the timeline, the CSV and notifications. Needs the isp-tester-tsmon package.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('advanced', widgets.DeviceSelect, 'igmp_device', _('IGMP upstream device'),
			_('Where the proxy joins the groups (its upstream, usually the IPTV VLAN). Empty = the IPTV device when measuring incoming traffic.'));
		o.noaliases = true;
		o.optional = true;
		o.depends({ igmp: '1', vlan: '' });

		/* ---- router load */
		s = m.section(form.NamedSection, 'system', 'system', _('Router load'),
			_('An overloaded router drops packets too. Only read from /proc to explain problems in the timeline; for graphs use Status → Realtime Graphs or luci-app-statistics.'));
		place(s, 'system');

		o = s.option(form.Flag, 'enabled', _('Watch router load'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'cpu_warn', _('CPU busy (%)'),
			_('Busiest core, two intervals in a row. Routing often saturates a single core. 0 disables.'));
		o.datatype = 'range(0,100)';
		o.placeholder = '90';

		o = s.option(form.Value, 'mem_warn', _('Free RAM below (%)'), _('0 disables.'));
		o.datatype = 'range(0,100)';
		o.placeholder = '10';

		o = s.option(form.Value, 'conntrack_warn', _('Connection table full (%)'),
			_('When the table is full, new connections fail. 0 disables.'));
		o.datatype = 'range(0,100)';
		o.placeholder = '90';

		/* ---- DNS */
		s = m.section(form.NamedSection, 'dns', 'dns', _('DNS'),
			_('Pages that do not open while ping works are often DNS. No own test: dnsmasq\'s statistics are read – over ubus every interval (queries sent upstream, answered from the cache, unanswered), and per upstream server from the statistics dnsmasq writes to the system log on SIGUSR1 (queries sent, retried = no answer in time, failed = SERVFAIL/REFUSED, average latency).'));
		place(s, 'dns');

		o = s.option(form.Flag, 'enabled', _('Watch DNS'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'warn_pct', _('Unanswered for a warning (%)'),
			_('Share of the queries sent upstream within a minute that get no answer, and of retried/failed queries per server.'));
		o.datatype = 'range(1,100)';
		o.placeholder = '10';
		o.depends('enabled', '1');

		o = s.option(form.Value, 'min_queries', _('At least (queries per minute)'),
			_('Fewer queries sent upstream within a minute are not judged.'));
		o.datatype = 'range(1,10000)';
		o.placeholder = '5';
		o.depends('enabled', '1');

		o = s.option(form.ListValue, 'dump', _('Per-server statistics'),
			_('How often dnsmasq is asked (SIGUSR1) to write its per-server statistics to the system log; each time adds a few lines to the log. Needs “Read the system log”.'));
		o.value('0', _('Off'));
		o.value('300', _('every 5 min'));
		o.value('900', _('every 15 min'));
		o.value('3600', _('every hour'));
		o.default = '300';
		o.depends('enabled', '1');

		/* ---- decoders */

		s = m.section(form.NamedSection, 'iptv', 'iptv', _('Decoders'),
			_('Tells “the decoder restarted” from “the stream vanished”. In a bridged IPTV VLAN the decoders get their address from the ISP, so the router has no neighbour entry for them; it uses the bridge\'s MAC table instead: every device in the IPTV VLAN on a port other than the one to the ISP is a decoder. A restart is seen when the port\'s link goes down (decoder directly on the port), when it vanishes from the MAC table and comes back, or when it is silent while the stream stops. Behind a switch the port stays up – install the package on the router the decoder is plugged into and let it send its events here. Needs the IPTV VLAN set above and the <code>ip-bridge</code> package.'));
		place(s, 'decoders');

		o = s.option(form.Flag, 'decoders', _('Detect decoder restarts'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'dec_silence', _('Silent for (s)'),
			_('No frame from the decoder for this long while the stream stopped counts as a restart.'));
		o.datatype = 'range(15,600)';
		o.placeholder = '40';
		o.depends('decoders', '1');

		o = s.option(form.Flag, 'dhcp', _('DHCP of the decoders'),
			_('Lease renewals and address changes from the operator. In a bridged IPTV VLAN the lease is not in the router, so the measuring helper (isp-tester-tsmon) also notes the operator\'s DHCP replies on that VLAN; when the router gives the decoders their address, dnsmasq\'s messages in the system log are used for the decoders named below.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'dec_off', _('Switched off after (s)'),
			_('Away longer than this: switched off or unplugged, not a restart.'));
		o.datatype = 'range(60,86400)';
		o.placeholder = '600';
		o.depends('decoders', '1');

		s = m.section(form.GridSection, 'decoder', _('Decoder names'),
			_('Optional: a name per decoder MAC address, shown instead of the address. The decoders found now are offered in the list.'));
		place(s, 'decoders', true);
		s.addremove = true;
		s.anonymous = true;

		o = s.option(form.Value, 'mac', _('MAC address'));
		o.datatype = 'macaddr';
		o.rmempty = false;
		((state.iptv && state.iptv.decoders) || []).forEach(function(d) {
			o.value(d.mac, '%s (%s)'.format(d.mac, d.port));
		});

		o = s.option(form.Value, 'label', _('Name'));
		o.placeholder = _('e.g. Living room');

		/* ---- second router */
		s = m.section(form.NamedSection, 'peer', 'peer', _('Second router'),
			_('Two routers, one timeline: a router behind this one (e.g. an access point with a decoder, a phone or the TV behind it) sends every event it logs to the main router, which shows them on its timeline marked with the sender\'s name and uses them in the analysis. Install the package on both, choose “Send” on the second one and “Receive” on the main one, with the same key. Over UDP, signed with the key (HMAC-SHA256); events that cannot be delivered are sent again.'));
		place(s, 'peer');

		o = s.option(form.ListValue, 'role', _('This router'));
		o.value('off', _('Works alone'));
		o.value('send', _('Sends its events to the main router'));
		o.value('receive', _('Receives the events of a second router'));
		o.default = 'off';

		o = s.option(form.Value, 'host', _('Address of the main router'),
			_('IPv4 address of the router that receives, e.g. <code>192.168.1.1</code>.'));
		o.datatype = 'ip4addr("nomask")';
		o.depends('role', 'send');

		o = s.option(form.Value, 'port', _('UDP port'),
			_('The same on both routers. The receiver listens on it; the LAN zone of the firewall accepts it by default (input ACCEPT).'));
		o.datatype = 'port';
		o.placeholder = '51477';
		o.depends('role', 'send');
		o.depends('role', 'receive');

		o = s.option(form.Value, 'key', _('Key'),
			_('The same secret on both routers, at least 8 characters. Messages signed with another key are ignored.'));
		o.password = true;
		o.datatype = 'minlength(8)';
		o.depends('role', 'send');
		o.depends('role', 'receive');

		/* ---- data push */
		s = m.section(form.NamedSection, 'push', 'push', _('Send data to another device'),
			_('Sends the timeline, history and CSV as one .tar.gz over SSH (dropbear\'s own client, no extra package) to another device in your network, e.g. a PC or a NAS with an SSH server. That device keeps the files, so the long history lives there and not on this router.'));
		place(s, 'push');

		o = s.option(form.Flag, 'enabled', _('Send regularly'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'host', _('Address'),
			_('IP address or name of the other device.'));
		o.datatype = 'or(ipaddr("nomask"),hostname)';
		o.placeholder = '192.168.1.10';

		o = s.option(form.Value, 'port', _('SSH port'));
		o.datatype = 'port';
		o.placeholder = '22';

		o = s.option(form.Value, 'user', _('User'));
		o.datatype = 'maxlength(32)';

		o = s.option(form.Value, 'dir', _('Folder on that device'),
			_('A relative path is in the user\'s home. It is created when missing.'));
		o.placeholder = 'isp-tester';

		o = s.option(form.ListValue, 'interval_h', _('Send every'),
			_('A failed try is repeated after 30 minutes.'));
		o.value('1', _('hour'));
		o.value('6', _('6 hours'));
		o.value('24', _('day'));
		o.value('168', _('week'));
		o.default = '24';

		o = s.option(form.Value, 'key', _('Private key'),
			_('Made on first use. Empty = <code>/etc/dropbear/isp_tester_push_key</code> (kept over a firmware upgrade).'));
		o.placeholder = '/etc/dropbear/isp_tester_push_key';
		o.optional = true;

		o = s.option(form.DummyValue, '_push');
		o.rawhtml = true;
		o.cfgvalue = function() { return null; };
		o.render = function() { return renderPush(); };

		/* ---- notifications */
		s = m.section(form.NamedSection, 'notify', 'notify', _('Notifications'),
			_('Push a message to your phone when something breaks. Messages that cannot be sent during an outage are sent when the Internet is back.'));
		place(s, 'notify');

		o = s.option(form.Flag, 'enabled', _('Send notifications'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.ListValue, 'service', _('Service'));
		o.value('ntfy', _('ntfy (app ntfy.sh)'));
		o.value('telegram', _('Telegram bot'));
		o.value('webhook', _('Webhook (JSON POST)'));
		o.default = 'ntfy';

		o = s.option(form.Value, 'url', _('URL'),
			_('ntfy: topic URL, e.g. <code>https://ntfy.sh/my-secret-topic-123</code> (anyone who knows the name can read it, so make it hard to guess). Webhook: URL that receives <code>{"text": …}</code>.'));
		o.datatype = 'string';
		o.depends('service', 'ntfy');
		o.depends('service', 'webhook');

		o = s.option(form.Value, 'token', _('Bot token'), _('From @BotFather.'));
		o.password = true;
		o.depends('service', 'telegram');

		o = s.option(form.Value, 'chat_id', _('Chat ID'));
		o.depends('service', 'telegram');

		o = s.option(form.ListValue, 'min_level', _('Send'));
		o.value('err', _('Faults only (and when they end)'));
		o.value('warn', _('Faults and warnings'));
		o.default = 'err';

		o = s.option(form.Value, 'cooldown', _('At most one message every (s)'),
			_('Events in between are collected into one message.'));
		o.datatype = 'range(30,86400)';
		o.placeholder = '300';

		o = s.option(form.ListValue, 'lang', _('Message language'));
		o.value('auto', _('As in LuCI (System → Language)'));
		o.value('en', 'English');
		o.value('pl', 'Polski');
		o.default = 'auto';

		o = s.option(form.Button, '_test', _('Test'));
		o.inputtitle = _('Send test message');
		o.inputstyle = 'action';
		o.onclick = function() {
			return callTestNotify().then(function(r) {
				ui.addNotification(null, E('p', r && r.running
					? _('The test message will be sent within one interval. Save & Apply changed settings first.')
					: _('Monitoring is not running, nothing can be sent.')), r && r.running ? 'info' : 'warning');
			});
		};

		/* ---- channel names */
		s = m.section(form.GridSection, 'channel', _('IPTV channel names'),
			_('Names set here win over the names read from the stream. Use them when the operator sends no names or a different one is wanted.'));
		place(s, 'channels', true);
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;

		o = s.option(form.Value, 'group', _('Multicast group'));
		o.datatype = 'ip4addr("nomask")';
		o.placeholder = '239.1.1.1';
		o.rmempty = false;
		o.validate = function(id, v) {
			if (v && !/^2(2[4-9]|3[0-9])\./.test(v)) return _('Expecting a multicast address (224.0.0.0 – 239.255.255.255)');
			return true;
		};

		o = s.option(form.Value, 'name', _('Name'));
		o.placeholder = _('e.g. TVP 1 HD');
		o.rmempty = false;

		s = m.section(form.NamedSection, 'iptv', 'iptv', _('Names read from the streams'));
		place(s, 'channels', true);
		o = s.option(form.DummyValue, '_learned');
		o.render = function() {
			return E('div', { 'class': 'cbi-section-node' }, renderLearned(learned));
		};

		/* ---- ports */
		s = m.section(form.GridSection, 'port', _('Ports'),
			_('Physical ports (or any devices) to watch for link drops, speed changes and errors.'));
		place(s, 'ports');
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.editable = true;
		o.rmempty = false;

		o = s.option(widgets.DeviceSelect, 'device', _('Device'));
		o.noaliases = true;
		o.rmempty = false;

		o = s.option(form.Value, 'label', _('Name'));
		o.placeholder = _('e.g. TV switch');

		o = s.option(form.Flag, 'expect_up', _('Must be up'),
			_('Link down counts as a fault (not just information).'));
		o.default = '1';
		o.editable = true;
		o.rmempty = false;

		return m.render();
	}
});
