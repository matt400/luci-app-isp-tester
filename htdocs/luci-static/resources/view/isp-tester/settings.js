'use strict';
'require view';
'require form';
'require tools.widgets as widgets';

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('isp_tester', _('ISP Tester – Settings'),
			_('Changes are applied immediately after “Save & Apply”; the collector restarts, keeping the timeline (charts start over).'));

		/* ---- general */
		s = m.section(form.NamedSection, 'general', 'general', _('General'));

		o = s.option(form.Flag, 'enabled', _('Enable monitoring'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'diagnosis', _('Show “Probable cause” panel'),
			_('Heuristic verdict whether problems come from the ISP or from your side. Only affects the overview page.'));
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

		o = s.option(form.Value, 'idle_after', _('Decoder off after (s)'),
			_('If the stream does not come back within this time, it is logged as “ended” instead of an ongoing outage.'));
		o.datatype = 'range(5,3600)';
		o.placeholder = '60';

		o = s.option(form.Value, 'dip_pct', _('Bitrate dip warning (%)'),
			_('Warn when the bitrate falls below this percentage of its usual value. 0 disables.'));
		o.datatype = 'range(0,100)';
		o.placeholder = '40';

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
