'use strict';
'require view';
'require form';
'require tools.widgets as widgets';
'require rpc';
'require ui';
'require dom';

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
			E('td', { 'class': 'td', 'style': 'font-family:monospace' }, g),
			E('td', { 'class': 'td' }, e.name ? e.name : E('em', {},
				e.why === 'no_sdt' ? _('no name in the stream') : _('not found'))),
			E('td', { 'class': 'td' }, e.provider || ''),
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

var callUpdateCheck = rpc.declare({
	object: 'luci.isp_tester',
	method: 'update_check',
	expect: { '': {} }
});

var callUpdateStatus = rpc.declare({
	object: 'luci.isp_tester',
	method: 'update_status',
	expect: { '': {} }
});

var callUpdateApply = rpc.declare({
	object: 'luci.isp_tester',
	method: 'update_apply',
	params: [ 'tag' ],
	expect: { '': {} }
});

function updateError(code) {
	switch (code) {
	case 'no_pkg_manager': return _('No package manager (opkg / apk) found.');
	case 'fetch_failed':   return _('Cannot reach GitHub. Check the internet connection (the ca-bundle package is needed for HTTPS).');
	case 'bad_response':   return _('Unexpected answer from GitHub.');
	case 'busy':           return _('An update is already running.');
	case 'download':       return _('Download failed.');
	case 'checksum':       return _('Checksum mismatch – the update was not installed.');
	case 'install':        return _('Installation failed (see opkg / apk output on the router).');
	default:               return code || _('Unknown error');
	}
}

function renderUpdates() {
	var box = E('div', { 'class': 'cbi-section-descr' });
	var info = E('div', { 'style': 'margin:.4em 0' }, _('Press the button to look for a newer release on GitHub.'));
	var btn = E('button', { 'class': 'cbi-button cbi-button-action' }, _('Check for updates'));
	var tag = null;

	function note(text, cls) {
		dom.content(info, [ E('span', { 'class': cls || '' }, text) ]);
	}

	function poll(n) {
		return callUpdateStatus().then(function(st) {
			if (st.state == 'done') {
				note(_('Updated to %s. Reloading…').format(st.msg), 'ispt-update-ok');
				window.setTimeout(function() { window.location.reload(true); }, 4000);
			}
			else if (st.state == 'error') {
				note(updateError(st.msg), 'ispt-update-err');
				btn.disabled = false;
			}
			else if (n > 90) {
				note(_('The update takes unusually long. Reload the page later.'), 'ispt-update-err');
				btn.disabled = false;
			}
			else {
				window.setTimeout(function() { poll(n + 1); }, 2000);
			}
		}).catch(function() {
			/* rpcd restarts while the package is installed */
			window.setTimeout(function() { poll(n + 1); }, 2000);
		});
	}

	function apply() {
		btn.disabled = true;
		note(_('Downloading and installing %s…').format(tag));
		return callUpdateApply(tag).then(function(r) {
			if (!r.result) {
				note(updateError(r.error), 'ispt-update-err');
				btn.disabled = false;
				return;
			}
			poll(0);
		});
	}

	function check() {
		btn.disabled = true;
		note(_('Checking…'));
		return callUpdateCheck().then(function(r) {
			btn.disabled = false;
			if (r.error) {
				note(updateError(r.error), 'ispt-update-err');
				return;
			}
			if (!r.available) {
				note(_('You have the newest version (%s).').format(r.current || r.latest));
				return;
			}
			if (!r.has_asset) {
				note(_('Release %s has no package for this router.').format(r.latest), 'ispt-update-err');
				return;
			}
			tag = r.tag;
			dom.content(info, [
				E('div', {}, _('New version %s is available (installed: %s).').format(r.latest, r.current || '?')),
				r.notes ? E('pre', { 'style': 'white-space:pre-wrap;max-height:12em;overflow:auto;margin:.4em 0' }, r.notes) : '',
				E('a', { 'href': r.url, 'target': '_blank', 'rel': 'noreferrer' }, _('Release page'))
			]);
			btn.textContent = _('Install %s').format(r.latest);
			btn.className = 'cbi-button cbi-button-positive';
			btn.onclick = ui.createHandlerFn(null, apply);
		});
	}

	btn.onclick = ui.createHandlerFn(null, check);

	/* pick up an update that is already running (e.g. page reloaded) */
	callUpdateStatus().then(function(st) {
		if (st.state == 'running' && Date.now() / 1000 - st.ts < 300) {
			btn.disabled = true;
			note(_('An update is running…'));
			poll(0);
		}
	});

	box.appendChild(info);
	box.appendChild(btn);
	return box;
}

var UPD_CSS = E('style', {}, '.ispt-update-ok{color:#2e9d4f;font-weight:bold}.ispt-update-err{color:#d64541;font-weight:bold}');

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

		m = new form.Map('isp_tester', _('ISP Tester – Settings'),
			_('Changes are applied immediately after “Save & Apply”; the collector restarts, keeping the timeline (charts start over).'));

		/* ---- updates */
		s = m.section(form.NamedSection, 'general', 'general', _('Updates'),
			_('Installs the newest release from GitHub (checksum verified).'));
		o = s.option(form.DummyValue, '_update', _('Plugin update'));
		o.rawhtml = true;
		o.cfgvalue = function() { return null; };
		o.render = function() {
			return E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Plugin update')),
				E('div', { 'class': 'cbi-value-field' }, renderUpdates())
			]);
		};

		/* ---- general */
		s = m.section(form.NamedSection, 'general', 'general', _('General'));

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

		/* ---- IPTV */
		s = m.section(form.NamedSection, 'iptv', 'iptv', _('IPTV'),
			_('Usually it is enough to enter the IPTV VLAN of your ISP. The bridge, the port towards the ISP and the decoder ports are then found automatically.'));
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

		/* ---- Wi-Fi */
		s = m.section(form.NamedSection, 'wifi', 'wifi', _('Wi-Fi'),
			_('Watches the Wi-Fi clients of this router\'s access points (hostapd over ubus): when a watched device (phone, TV) drops and comes back, and when its signal gets weak. Then a “Problem now” report with nothing measured on the line has proof: it was Wi-Fi – or, when its Wi-Fi was fine, it was not. On a second router behind this one, set it up there and let it send its events here.'));

		o = s.option(form.Flag, 'enabled', _('Watch Wi-Fi'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'signal_warn', _('Weak signal below (dBm)'),
			_('Two checks in a row below this are logged. Around −70 dBm streaming starts to suffer.'));
		o.datatype = 'range(-100,-30)';
		o.placeholder = '-75';

		o = s.option(form.Value, 'reconnect_s', _('Reconnect within (s)'),
			_('A device that is back within this time was dropped (a fault). One that stays away longer just left (e.g. the phone left the house) and is only noted.'));
		o.datatype = 'range(5,3600)';
		o.placeholder = '60';

		s = m.section(form.GridSection, 'station', _('Wi-Fi devices to watch'),
			_('Only these are logged; the others are counted. Devices connected now are offered in the list.'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.editable = true;
		o.rmempty = false;

		o = s.option(form.Value, 'mac', _('MAC address'));
		o.datatype = 'macaddr';
		o.rmempty = false;
		(state.wifi_clients || []).forEach(function(c) {
			o.value(c.mac, '%s (%s%s)'.format(c.mac, c.iface, c.signal != null ? ', %d dBm'.format(c.signal) : ''));
		});

		o = s.option(form.Value, 'label', _('Name'));
		o.placeholder = _('e.g. Phone');

		/* ---- second router */
		s = m.section(form.NamedSection, 'peer', 'peer', _('Second router'),
			_('Two routers, one timeline: a router behind this one (e.g. an access point with a decoder, a phone or the TV behind it) sends every event it logs to the main router, which shows them on its timeline marked with the sender\'s name and uses them in the analysis. Install the package on both, choose “Send” on the second one and “Receive” on the main one, with the same key. Over UDP, signed with the key (HMAC-SHA256); events that cannot be delivered are sent again.'));

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

		/* ---- notifications */
		s = m.section(form.NamedSection, 'notify', 'notify', _('Notifications'),
			_('Push a message to your phone when something breaks. Messages that cannot be sent during an outage are sent when the Internet is back.'));

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
		o.value('en', 'English');
		o.value('pl', 'Polski');
		o.default = 'en';

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
		o = s.option(form.DummyValue, '_learned');
		o.render = function() {
			return E('div', { 'class': 'cbi-section-node' }, renderLearned(learned));
		};

		/* ---- ports */
		s = m.section(form.GridSection, 'port', _('Ports'),
			_('Physical ports (or any devices) to watch for link drops, speed changes and errors.'));
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

		return m.render().then(function(n) { n.insertBefore(UPD_CSS, n.firstChild); return n; });
	}
});
