'use strict';

/* luci-app-isp-tester: part of the collector (see ../collector.uc) */

function tstamp(t) {
	let lt = localtime(t);
	return sprintf('%04d-%02d-%02d %02d:%02d:%02d', lt.year, lt.mon, lt.mday, lt.hour, lt.min, lt.sec);
}

/* short plain-text messages for syslog and push notifications (the web UI
 * has its own translated texts) */
const MSG = {
	en: {
		link_down: '%s: link DOWN', link_up: '%s: link up again after %s', link_flap: '%s: link dropped for a moment',
		speed_change: '%s: link speed %s -> %s Mbit/s', errors: '%s: %d port errors (%d CRC)', drops: '%s: %d dropped packets',
		dev_missing: 'Device %s disappeared', dev_present: 'Device %s is back',
		target_degraded: '%s: degraded (loss %d%%, ping %s ms, jitter %s ms)', target_fail: '%s: not responding (%d%% loss)', target_loss: '%s: heavy packet loss (%d%%)', target_ok: '%s: OK again after %s',
		wan_down: 'INTERNET DOWN - no target responds', wan_up: 'Internet back after %s',
		wan_if_down: 'WAN interface %s went down', wan_if_up: 'WAN interface %s up again after %s', wan_reconnect: 'WAN session restarted (was up %s)',
		wan_ip_change: 'WAN address changed %s -> %s',
		log: '%s: %s',
		stream_stall: 'IPTV STREAM STOPPED', stream_stall_zap: 'IPTV: the new channel did not start after a channel change', stream_resume: 'IPTV stream resumed after %s', stream_lost: 'IPTV stream did not come back within %s', stream_off: 'IPTV stream ended: decoder switched off (no channel subscribed)', stream_unwatched: 'IPTV stream ended - nobody was watching (not an outage)', stream_svc: 'Decoders fetched data in standby (guide or update) for %s',
		stream_dip: 'IPTV bitrate dropped to %d kbit/s',
		ts_errors: '%s: ~%d IPTV packets lost in %ss (%d gaps) - possible picture glitch',
		proxy_down: 'Multicast proxy %s is not running', proxy_up: 'Multicast proxy %s running again', proxy_restart: 'Multicast proxy %s restarted',
		cpu_high: 'Router CPU busy: %d%% (softirq %d%%)', mem_low: 'Router RAM low: %d%% free', conntrack_full: 'Connection table %d%% full',
		igmp_noquery: 'No IGMP query from the operator for %s (usually every %s)', igmp_noquery_ok: 'IGMP queries from the operator again after %s',
		igmp_querier: 'IGMP querier of VLAN %s: %s -> %s', igmp_no_querier: 'NO IGMP querier on VLAN %s - the memberships will expire',
		igmp_no_querier_ok: 'IGMP querier on VLAN %s again after %s: %s',
		sfp_rx_drop: 'Optical signal weak: RX %s dBm (usually %s dBm)', sfp_los: 'NO LIGHT from the line on %s (SFP RX)',
		sfp_alarm: 'SFP module alarm: %s', sfp_gone: 'SFP module on %s does not answer any more',
		sfp_rx_drop_ok: 'Optical signal back to %s dBm after %s', sfp_los_ok: 'Light is back after %s (RX %s dBm)',
		sfp_alarm_ok: 'SFP module alarm over after %s', sfp_gone_ok: 'SFP module on %s answers again after %s',
		cpu_high_ok: 'Router CPU load normal again after %s', mem_low_ok: 'Router RAM OK again after %s',
		conntrack_full_ok: 'Connection table OK again after %s',
		user_mark: 'Problem reported by user: %s', test: 'Test message - notifications work.',
		peer_lost: 'Router %s does not report any more', peer_back: 'Router %s reports again after %s',
		trace: 'Traceroute to %s: %s',
		decoder_restart: 'Decoder %s restarted (gone %s, %s)', decoder_off: 'Decoder %s switched off or unplugged (%s)',
		decoder_on: 'Decoder %s is back after %s',
		bufferbloat: 'Bufferbloat: ping +%s ms with the link %d%% full (%s)', bufferbloat_ok: 'Bufferbloat over after %s (up to +%s ms)',
		v6_down: 'IPv6 DOWN - no IPv6 target responds (IPv4 works)', v6_up: 'IPv6 back after %s',
		v6_if_down: 'IPv6 interface %s went down', v6_if_up: 'IPv6 interface %s up again after %s',
		v6_pd_lost: 'IPv6 prefix lost (%s)', v6_pd_back: 'IPv6 prefix back after %s: %s', v6_pd_change: 'IPv6 prefix changed %s -> %s',
		v6_no_route: 'No IPv6 default route (no router advertisement) on %s', v6_route_back: 'IPv6 default route back after %s',
		dns_fail: 'DNS: %d%% of the queries sent upstream unanswered (%d of %d in %ss)', dns_ok: 'DNS OK again after %s (at worst %d%% unanswered)',
		dns_server_bad: 'DNS server %s: %d of %d queries retried or failed in %s', dns_server_ok: 'DNS server %s OK again',
		router_reboot: 'Router restarted (up since %s)', data_gap: 'No measurements from %s to %s (%s): %s',
		collector_restart: 'Monitor restarted after it %s',
		ntp_sync: 'Clock synchronized (NTP stratum %s)', ntp_unsync: 'Clock NOT synchronized - times in the log may be wrong',
		ntp_off: 'No NTP client running - times in the log may be wrong', clock_step: 'Clock set by %ss',
		maint_start: 'Maintenance until %s: not counted, no notifications (%s)', maint_end: 'Maintenance over after %s',
		dhcp_lease: 'Decoder %s: address %s from the operator (lease %s)', dhcp_new: 'Decoder %s took an address anew (switched on or restarted): %s',
		dhcp_ip_change: 'Decoder %s: address CHANGED %s -> %s', dhcp_nak: 'Decoder %s: operator REFUSED the lease (DHCPNAK)',
		dhcp_expired: 'Decoder %s: lease of %s expired without renewal while switched on', dhcp_expired_unk: 'Decoder %s: lease of %s expired - probably switched off', dhcp_late: 'Decoder %s renewed its lease %s too late'
	},
	pl: {
		link_down: '%s: BRAK ŁĄCZA', link_up: '%s: łącze wróciło po %s', link_flap: '%s: łącze na chwilę zanikło',
		speed_change: '%s: prędkość łącza %s -> %s Mbit/s', errors: '%s: błędy portu: %d (CRC: %d)', drops: '%s: %d odrzuconych pakietów',
		dev_missing: 'Urządzenie %s zniknęło', dev_present: 'Urządzenie %s wróciło',
		target_degraded: '%s: problemy (straty %d%%, ping %s ms, jitter %s ms)', target_fail: '%s: nie odpowiada (%d%% strat)', target_loss: '%s: duże straty pakietów (%d%%)', target_ok: '%s: znów OK po %s',
		wan_down: 'BRAK INTERNETU - żaden cel nie odpowiada', wan_up: 'Internet wrócił po %s',
		wan_if_down: 'Interfejs WAN %s rozłączony', wan_if_up: 'Interfejs WAN %s znów działa po %s', wan_reconnect: 'Sesja WAN zestawiona od nowa (trwała %s)',
		wan_ip_change: 'Zmiana adresu WAN %s -> %s',
		log: '%s: %s',
		stream_stall: 'STRUMIEŃ IPTV ZATRZYMANY', stream_stall_zap: 'IPTV: nowy kanał nie ruszył po zmianie kanału', stream_resume: 'Strumień IPTV wrócił po %s', stream_lost: 'Strumień IPTV nie wrócił w ciągu %s', stream_off: 'Strumień IPTV zakończony: dekoder wyłączony (brak subskrybowanego kanału)', stream_unwatched: 'Strumień IPTV zakończony - nikt go nie oglądał (nie awaria)', stream_svc: 'Dekodery pobrały dane w czuwaniu (EPG lub aktualizacja) przez %s',
		stream_dip: 'Bitrate IPTV spadł do %d kbit/s',
		ts_errors: '%s: zgubione pakiety IPTV ~%d w %ss (przerw: %d) - możliwe zakłócenie obrazu',
		proxy_down: 'Proxy multicast %s nie działa', proxy_up: 'Proxy multicast %s znów działa', proxy_restart: 'Proxy multicast %s zrestartowany',
		cpu_high: 'Router przeciążony: CPU %d%% (softirq %d%%)', mem_low: 'Mało RAM: wolne %d%%', conntrack_full: 'Tablica połączeń zajęta w %d%%',
		igmp_noquery: 'Brak zapytań IGMP od operatora od %s (zwykle co %s)', igmp_noquery_ok: 'Zapytania IGMP od operatora wróciły po %s',
		igmp_querier: 'Querier IGMP w VLAN %s: %s -> %s', igmp_no_querier: 'BRAK queriera IGMP w VLAN %s - subskrypcje wygasną',
		igmp_no_querier_ok: 'Querier IGMP w VLAN %s znów jest po %s: %s',
		sfp_rx_drop: 'Słaby sygnał optyczny: RX %s dBm (zwykle %s dBm)', sfp_los: 'BRAK ŚWIATŁA z linii na %s (RX SFP)',
		sfp_alarm: 'Alarm modułu SFP: %s', sfp_gone: 'Moduł SFP na %s przestał odpowiadać',
		sfp_rx_drop_ok: 'Sygnał optyczny wrócił do %s dBm po %s', sfp_los_ok: 'Światło z linii wróciło po %s (RX %s dBm)',
		sfp_alarm_ok: 'Alarm modułu SFP minął po %s', sfp_gone_ok: 'Moduł SFP na %s znów odpowiada po %s',
		cpu_high_ok: 'Obciążenie CPU routera znów w normie po %s', mem_low_ok: 'RAM routera znów w normie po %s',
		conntrack_full_ok: 'Tablica połączeń znów w normie po %s',
		user_mark: 'Problem zgłoszony ręcznie: %s', test: 'Wiadomość testowa - powiadomienia działają.',
		peer_lost: 'Router %s przestał się zgłaszać', peer_back: 'Router %s znów się zgłasza po %s',
		trace: 'Traceroute do %s: %s',
		decoder_restart: 'Dekoder %s zrestartował się (nie było go %s, %s)', decoder_off: 'Dekoder %s wyłączony lub odłączony (%s)',
		decoder_on: 'Dekoder %s wrócił po %s',
		bufferbloat: 'Bufferbloat: ping +%s ms przy łączu zajętym w %d%% (%s)', bufferbloat_ok: 'Bufferbloat minął po %s (do +%s ms)',
		v6_down: 'IPv6 NIE DZIAŁA - żaden cel IPv6 nie odpowiada (IPv4 działa)', v6_up: 'IPv6 wróciło po %s',
		v6_if_down: 'Interfejs IPv6 %s rozłączony', v6_if_up: 'Interfejs IPv6 %s znów działa po %s',
		v6_pd_lost: 'Utrata prefiksu IPv6 (%s)', v6_pd_back: 'Prefiks IPv6 wrócił po %s: %s', v6_pd_change: 'Zmiana prefiksu IPv6 %s -> %s',
		v6_no_route: 'Brak domyślnej trasy IPv6 (brak RA) na %s', v6_route_back: 'Domyślna trasa IPv6 wróciła po %s',
		dns_fail: 'DNS: %d%% zapytań wysłanych dalej bez odpowiedzi (%d z %d w %ss)', dns_ok: 'DNS znów OK po %s (najgorzej %d%% bez odpowiedzi)',
		dns_server_bad: 'Serwer DNS %s: %d z %d zapytań ponowionych lub nieudanych w %s', dns_server_ok: 'Serwer DNS %s znów OK',
		router_reboot: 'Router uruchomiony ponownie (działa od %s)', data_gap: 'Brak pomiarów od %s do %s (%s): %s',
		collector_restart: 'Monitor uruchomiony ponownie, bo %s',
		ntp_sync: 'Zegar zsynchronizowany (NTP stratum %s)', ntp_unsync: 'Zegar NIE jest zsynchronizowany - czasy w logu mogą być błędne',
		ntp_off: 'Brak klienta NTP - czasy w logu mogą być błędne', clock_step: 'Zegar przestawiony o %ss',
		maint_start: 'Prace serwisowe do %s: bez liczenia i powiadomień (%s)', maint_end: 'Prace serwisowe zakończone po %s',
		dhcp_lease: 'Dekoder %s: adres %s od operatora (dzierżawa %s)', dhcp_new: 'Dekoder %s pobrał adres od nowa (włączenie lub restart): %s',
		dhcp_ip_change: 'Dekoder %s: ZMIANA adresu %s -> %s', dhcp_nak: 'Dekoder %s: operator ODMÓWIŁ dzierżawy (DHCPNAK)',
		dhcp_expired: 'Dekoder %s: dzierżawa %s wygasła bez odnowienia, choć dekoder jest włączony', dhcp_expired_unk: 'Dekoder %s: dzierżawa %s wygasła - pewnie wyłączony', dhcp_late: 'Dekoder %s odnowił dzierżawę %s za późno'
	}
};

const GAP_WHY_EN = { reboot: 'router restarted', stopped: 'monitoring was off', crash: 'the collector stopped unexpectedly',
	hung: 'the collector hung (restarted by the watchdog)', stall: 'the collector was blocked' };

const GAP_WHY_PL = { reboot: 'restart routera', stopped: 'monitorowanie wyłączone', crash: 'collector nieoczekiwanie się zatrzymał',
	hung: 'collector się zawiesił (zrestartowany przez watchdog)', stall: 'collector był zablokowany' };

/* the choices of the "Problem now" button (overview.js MARKS) */
const MARK_EN = { tv_freeze: 'TV froze', tv_pixel: 'TV picture breaks up', net_slow: 'Internet is slow',
	net_down: 'Internet does not work', other: 'something else' };

const MARK_PL = { tv_freeze: 'obraz TV zamarzł', tv_pixel: 'obraz TV się rozpada', net_slow: 'Internet działa wolno',
	net_down: 'Internet nie działa', other: 'coś innego' };

function dur_txt(s) {
	s = int(s ?? 0);
	if (s >= 3600) return sprintf('%dh%02dm', s / 3600, (s % 3600) / 60);
	if (s >= 60) return sprintf('%dm%02ds', s / 60, s % 60);
	return sprintf('%ds', s);
}

/* who asks on the IPTV VLAN (querier.uc) */
function querier_name(who, addr, port, lang) {
	let pl = (lang == 'pl');
	switch (who) {
	case 'isp': return (pl ? 'operator' : 'ISP') + (addr ? ` (${addr})` : '');
	case 'other': return (pl ? 'inne urządzenie' : 'another device') + ` (${addr ?? '?'}${port ? ', ' + port : ''})`;
	case 'router': return pl ? 'router' : 'the router';
	case 'wire': return (pl ? 'niewybrany querier' : 'an unelected querier') + ` (${addr ?? '0.0.0.0'})`;
	case 'off': return pl ? 'snooping wyłączony' : 'snooping off';
	default: return pl ? 'brak' : 'none';
	}
}

function event_text(e, lang) {
	let m = MSG[lang] ?? MSG.en, d = e.d ?? {}, f = m[e.type];
	if (e.type == 'stream_off' && d.unwatched) f = m.stream_unwatched;
	if (e.type == 'stream_off' && d.svc) f = m.stream_svc;
	if (e.type == 'stream_stall' && d.zap) f = m.stream_stall_zap;
	/* "not responding" only when nothing came back: 1 of 2 pings lost was that too */
	if (e.type == 'target_fail' && d.loss != null && d.loss < 100) f = m.target_loss;
	if (e.type == 'dhcp_expired' && d.unk) f = m.dhcp_expired_unk;
	if (!f) return e.type;
	switch (e.type) {
	case 'link_down': case 'link_flap': return sprintf(f, d.dev);
	case 'link_up': return sprintf(f, d.dev, dur_txt(d.dur));
	case 'speed_change': return sprintf(f, d.dev, d.from, d.to);
	case 'errors': return sprintf(f, d.dev, d.err, d.crc);
	case 'drops': return sprintf(f, d.dev, d.n);
	case 'dev_missing': case 'dev_present': return sprintf(f, d.dev);
	case 'target_degraded': return sprintf(f, e.src, d.loss, d.rtt ?? '-', d.jitter ?? '-');
	case 'target_fail': case 'target_loss': return sprintf(f, e.src, d.loss ?? 100);
	case 'target_ok': return sprintf(f, e.src, dur_txt(d.dur));
	case 'wan_up': case 'stream_resume': case 'stream_lost': return sprintf(f, dur_txt(d.dur));
	case 'stream_off': case 'stream_svc': return d.svc || e.type == 'stream_svc' ? sprintf(f, dur_txt(d.dur)) : f;
	case 'wan_if_down': return sprintf(f, d.iface);
	case 'wan_if_up': return sprintf(f, d.iface, dur_txt(d.dur));
	case 'wan_reconnect': return sprintf(f, dur_txt(d.prev));
	case 'wan_ip_change': return sprintf(f, d.from, d.to);
	case 'log': return sprintf(f, d.prog, d.msg) + ((d.n > 1) ? ` (${d.n}x)` : '');
	case 'stream_dip': return sprintf(f, d.kbps);
	case 'ts_errors': return sprintf(f, d.ch ? `${d.ch} (${d.grp})` : (d.grp ?? '?'), d.lost, d.win, d.cc + (d.tei ?? 0));
	case 'proxy_down': case 'proxy_up': case 'proxy_restart': return sprintf(f, d.name);
	case 'cpu_high': return sprintf(f, d.cpu, d.sirq);
	case 'mem_low': return sprintf(f, d.pct);
	case 'sfp_rx_drop': return sprintf(f, d.rx, d.base ?? '?');
	case 'sfp_los': case 'sfp_gone': return sprintf(f, d.dev);
	case 'sfp_alarm': return sprintf(f, join(', ', d.flags ?? []));
	case 'sfp_rx_drop_ok': return sprintf(f, d.rx, dur_txt(d.dur));
	case 'sfp_los_ok': return sprintf(f, dur_txt(d.dur), d.rx ?? '?');
	case 'sfp_gone_ok': return sprintf(f, d.dev, dur_txt(d.dur));
	case 'sfp_alarm_ok': case 'cpu_high_ok': case 'mem_low_ok': case 'conntrack_full_ok':
		return sprintf(f, dur_txt(d.dur));
	case 'igmp_noquery': return sprintf(f, dur_txt(d.silent), dur_txt(d.expected));
	case 'igmp_noquery_ok': return sprintf(f, dur_txt(d.dur));
	case 'igmp_querier': return sprintf(f, d.vlan ?? '?', querier_name(d.from, d.prev_addr, d.prev_port, lang), querier_name(d.to, d.addr, d.port, lang));
	case 'igmp_no_querier': return sprintf(f, d.vlan ?? '?');
	case 'igmp_no_querier_ok': return sprintf(f, d.vlan ?? '?', dur_txt(d.dur), querier_name(d.to, d.addr, d.port, lang));
	case 'conntrack_full': return sprintf(f, d.pct);
	/* what was picked ("TV froze"), and the note when there is one: without
	 * a note the message said only "Problem reported by user: -" */
	case 'user_mark': {
		let w = ((lang == 'pl') ? MARK_PL : MARK_EN)[d.what] ?? ((lang == 'pl') ? MARK_PL : MARK_EN).other;
		return sprintf(f, d.note ? `${w} - ${d.note}` : w);
	}
	case 'peer_lost': return sprintf(f, e.src);
	case 'peer_back': return sprintf(f, e.src, dur_txt(d.dur));
	case 'trace': return sprintf(f, d.host, d.first_bad
		? sprintf(lang == 'pl' ? 'straty od hopa %d (%s)' : 'loss starts at hop %d (%s)', d.first_bad, d.bad_ip ?? '?')
		: (lang == 'pl' ? 'bez strat do celu' : 'no loss to the destination'));
	case 'decoder_restart': return sprintf(f, e.src, dur_txt(d.dur), d.port ?? '?');
	case 'decoder_off': return sprintf(f, e.src, d.port ?? '?');
	case 'decoder_on': return sprintf(f, e.src, dur_txt(d.dur));
	case 'bufferbloat': return sprintf(f, d.add, d.load, d.dir == 'up' ? (lang == 'pl' ? 'wysyłanie' : 'upload') : (lang == 'pl' ? 'pobieranie' : 'download'));
	case 'bufferbloat_ok': return sprintf(f, dur_txt(d.dur), d.max_add);
	case 'v6_up': case 'v6_route_back': return sprintf(f, dur_txt(d.dur));
	case 'v6_if_down': case 'v6_no_route': return sprintf(f, d.iface);
	case 'v6_if_up': return sprintf(f, d.iface, dur_txt(d.dur));
	case 'v6_pd_lost': return sprintf(f, join(' ', d.prev ?? []) || '-');
	case 'v6_pd_back': return sprintf(f, dur_txt(d.dur), join(' ', d.prefix ?? []));
	case 'v6_pd_change': return sprintf(f, join(' ', d.from ?? []), join(' ', d.to ?? []));
	case 'dns_fail': return sprintf(f, d.pct, d.unans, d.fwd, d.win);
	case 'dns_ok': return sprintf(f, dur_txt(d.dur), d.max_pct);
	case 'dns_server_bad': return sprintf(f, e.src, d.bad, d.sent, dur_txt(d.win));
	case 'dns_server_ok': return d.no_data
		? sprintf((lang == 'pl') ? 'Serwer DNS %s: brak statystyk (usunięty z ustawień DNS lub statystyki wyłączone)'
			: 'DNS server %s: no statistics any more (removed from the DNS settings, or statistics off)', e.src)
		: sprintf(f, e.src);
	/* no boot time when /proc/uptime could not be read: localtime(null) is "now" */
	case 'router_reboot': return sprintf(f, (type(d.boot) == 'int') ? tstamp(d.boot) : '?');
	case 'collector_restart': return sprintf(f, d.why == 'hung'
		? (lang == 'pl' ? 'się zawiesił (watchdog)' : 'hung (watchdog)')
		: (lang == 'pl' ? 'nieoczekiwanie się zatrzymał' : 'stopped unexpectedly'));
	case 'ntp_sync': return sprintf(f, d.stratum ?? '?');
	case 'clock_step': return sprintf(f, (d.by > 0 ? '+' : '') + d.by);
	case 'maint_start': return sprintf(f, substr(tstamp(d.until), 11, 5), d.note || '-');
	case 'maint_end': return sprintf(f, dur_txt(d.dur));
	case 'dhcp_lease': return sprintf(f, e.src, d.ip, d.lease ? dur_txt(d.lease) : '?');
	case 'dhcp_new': return sprintf(f, e.src, d.ip);
	case 'dhcp_ip_change': return sprintf(f, e.src, d.from, d.to);
	case 'dhcp_nak': return sprintf(f, e.src);
	case 'dhcp_expired': case 'dhcp_expired_unk': return sprintf(f, e.src, d.ip);
	case 'dhcp_late': return sprintf(f, e.src, dur_txt(d.late));
	case 'data_gap': return sprintf(f, d.from ? tstamp(d.from) : '?', tstamp(d.to), dur_txt(d.len),
		(lang == 'pl' ? GAP_WHY_PL : GAP_WHY_EN)[d.why] ?? d.why);
	default: return f;
	}
}

function event_msg(e, lang) {
	let s = event_text(e, lang), d = e.d ?? {};
	/* the channel(s) being watched, when known */
	if (e.area == 'iptv' && d.ch && e.type != 'ts_errors') s += ` [${d.ch}]`;
	/* received from the second router */
	if (e.host) s = `[${e.host}] ${s}`;
	return s;
}

export { tstamp, MSG, GAP_WHY_EN, GAP_WHY_PL, MARK_EN, MARK_PL, dur_txt, event_text, event_msg };
