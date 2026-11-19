'use strict';
'require view';
'require form';
'require tools.widgets as widgets';
'require rpc';
'require ui';

var callTestNotify = rpc.declare({
	object: 'luci.isp_tester',
	method: 'test_notify',
	expect: { '': {} }
});

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('isp_tester', _('ISP Tester – Settings'),
			_('Changes are applied immediately after “Save & Apply”; the collector restarts, keeping the timeline (charts start over).'));

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

		o = s.taboption('advanced', form.Value, 'dip_pct', _('Bitrate dip warning (%)'),
			_('Warn when the bitrate falls below this percentage of its usual value. 0 disables.'));
		o.datatype = 'range(0,100)';
		o.placeholder = '40';

		o = s.taboption('basic', form.Flag, 'igmp', _('Watch IGMP'),
			_('Tracks which multicast groups (channels) are joined and whether the multicast proxy (igmpproxy, mcproxy) is running. This tells a channel change from a freeze, and an IGMP timeout from the ISP not sending.'));
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

		return m.render();
	}
});
