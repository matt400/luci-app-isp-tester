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

		o = s.option(form.Value, 'persist_dir', _('Keep logs on'),
			_('Optional folder on persistent storage, e.g. a USB stick (<code>/mnt/sda1</code>). The timeline, history and CSV are copied there regularly and on reboot, and restored after a reboot. Do not use the internal flash: frequent writes wear it out. Empty = RAM only.'));
		o.placeholder = '/mnt/sda1';
		o.optional = true;

		o = s.option(form.Value, 'persist_interval', _('Copy every (s)'));
		o.datatype = 'range(60,86400)';
		o.placeholder = '900';
		o.depends({ persist_dir: '', '!reverse': true });

		o = s.option(form.Flag, 'syslog', _('Write problems to the system log'),
			_('Warnings and faults also go to the system log (logread) and to a remote syslog server, if one is set in System → System → Logging.'));
		o.default = '0';

		/* ---- WAN */
		s = m.section(form.NamedSection, 'wan', 'wan', _('Internet (WAN)'));

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

		o = s.option(form.Flag, 'ping_gateway', _('Ping ISP gateway'),
			_('Loss to the gateway points at the line / ISP access network; loss only to far targets points at the ISP backbone.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.DynamicList, 'target', _('Ping targets'));
		o.datatype = 'host';
		o.placeholder = '1.1.1.1';

		o = s.option(form.Value, 'count', _('Pings per round'));
		o.datatype = 'range(1,10)';
		o.placeholder = '3';

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
			_('Mean difference between consecutive ping replies. Matters for calls, games and IPTV over unicast. 0 = only measure, no warning.'));
		o.datatype = 'uinteger';
		o.placeholder = '0';

		o = s.option(form.Flag, 'dns', _('Check DNS'),
			_('Resolves a name every interval and logs failures and slow answers. "Internet does not work" is often DNS only.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'dns_host', _('Name to resolve'));
		o.datatype = 'hostname';
		o.placeholder = 'openwrt.org';
		o.depends('dns', '1');

		o = s.option(form.Value, 'dns_server', _('DNS server'),
			_('Empty = the router\'s own resolver (answers are often cached). Enter the ISP\'s DNS server to test it directly.'));
		o.datatype = 'host';
		o.optional = true;
		o.depends('dns', '1');

		o = s.option(form.Value, 'dns_warn', _('Slow DNS (ms)'), _('0 disables the warning.'));
		o.datatype = 'uinteger';
		o.placeholder = '500';
		o.depends('dns', '1');

		/* ---- IPTV */
		s = m.section(form.NamedSection, 'iptv', 'iptv', _('IPTV'));

		o = s.option(form.Flag, 'enabled', _('Monitor IPTV'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(widgets.DeviceSelect, 'device', _('IPTV device'),
			_('A device that carries only IPTV traffic: the IPTV VLAN (e.g. <code>eth1.236</code>) or the port the decoder is connected to. Watch TV and check that the bitrate on the overview matches.'));
		o.noaliases = true;
		o.optional = true;

		o = s.option(form.ListValue, 'direction', _('Measure'));
		o.value('rx', _('Incoming traffic (VLAN from the ISP)'));
		o.value('tx', _('Outgoing traffic (port towards the decoder)'));
		o.default = 'rx';

		o = s.option(widgets.DeviceSelect, 'bridge', _('Bridge for IGMP status'),
			_('Optional. Shows whether IGMP snooping and the querier are active on this bridge.'));
		o.noaliases = true;
		o.optional = true;

		o = s.option(form.Value, 'min_kbps', _('Stream threshold (kbit/s)'),
			_('Below this the stream counts as stopped. An HD channel usually uses 4000–12000 kbit/s.'));
		o.datatype = 'uinteger';
		o.placeholder = '500';

		o = s.option(form.Value, 'sample_interval', _('IPTV sampling interval (s)'),
			_('How often the IPTV bitrate is measured, independent of the main interval. 1 s catches freezes of a few seconds; 0 measures only once per main interval.'));
		o.datatype = 'or(0,range(0.5,10))';
		o.placeholder = '1';

		o = s.option(form.Value, 'stall_after', _('Freeze after (s)'),
			_('How long the bitrate must stay below the threshold to log a freeze. 2 s ignores single short gaps the decoder buffer hides.'));
		o.datatype = 'range(0,60)';
		o.placeholder = '2';

		o = s.option(form.Value, 'idle_after', _('Decoder off after (s)'),
			_('If the stream does not come back within this time, it is logged as “ended” instead of an ongoing outage.'));
		o.datatype = 'range(5,3600)';
		o.placeholder = '60';

		o = s.option(form.Value, 'dip_pct', _('Bitrate dip warning (%)'),
			_('Warn when the bitrate falls below this percentage of its usual value. 0 disables.'));
		o.datatype = 'range(0,100)';
		o.placeholder = '40';

		o = s.option(form.Flag, 'igmp', _('Watch IGMP'),
			_('Tracks which multicast groups (channels) are joined and whether the multicast proxy (igmpproxy, mcproxy) is running. This tells a channel change from a freeze, and an IGMP timeout from the ISP not sending.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(widgets.DeviceSelect, 'igmp_device', _('IGMP upstream device'),
			_('Where the proxy joins the groups (its upstream, usually the IPTV VLAN). Empty = the IPTV device when measuring incoming traffic.'));
		o.noaliases = true;
		o.optional = true;
		o.depends('igmp', '1');

		/* ---- router load */
		s = m.section(form.NamedSection, 'system', 'system', _('Router load'),
			_('An overloaded router drops packets too. Logged so it is not blamed on the ISP.'));

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
