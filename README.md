# luci-app-isp-tester

An OpenWrt package with a LuCI web interface that watches your Internet connection, IPTV stream and switch ports, and records every problem with a timestamp. It is built for intermittent faults like IPTV freezing at random times, so you have concrete logs when you talk to your ISP.

Target: **OpenWrt 24.10 and 25.12** (ucode + rpcd + LuCI JS). No compiled code, the package is architecture-independent.

![Overview: status banner, probable cause and live cards](docs/screenshots/overview.png)

## Screenshots

*Demo data: evening IPTV freezes every ~260 s, two short packet-loss bursts at the ISP gateway, and a flapping LAN port.*

**Probable cause.** The verdict is ISP vs. router/home, with the findings behind it:

![Probable cause panel](docs/screenshots/probable-cause.png)

**History, last 24 h.** It shows a state strip, ping with packet-loss bands, IPTV bitrate and interface errors:

![24 h history](docs/screenshots/history-24h.png)

**Zoomed to one hour.** Here the freezes are clearly periodic:

![1 h zoom on IPTV freezes](docs/screenshots/history-zoom.png)

**Timeline.** Click an event to zoom the charts to that moment:

![Timeline](docs/screenshots/timeline.png)

## What it monitors

| Area | How | Logged events |
|------|-----|---------------|
| **Internet** | Ping results of **collectd** (luci-app-statistics, Ping plugin): loss, latency and jitter per host. The host netifd reports as gateway is marked as the ISP gateway | packet loss, high latency, high jitter (optional), host not responding, *Internet down* (no host responds), recovery with duration |
| **WAN session** | netifd status of the WAN interface | interface down/up (PPPoE/DHCP session lost), session restarted between two checks, WAN address changed |
| **System log** | `logread`: pppd, udhcpc, igmpproxy/mcproxy, kernel, dnsmasq | LCP echo timeouts, PPPoE discovery/authentication failures, DHCP lease lost, proxy errors, network driver hang, connection table full, out of memory, DNS query limit |
| **IPTV** | Bitrate of the IPTV VLAN (bridge per-VLAN counters), or of a device that carries only IPTV traffic (e.g. `eth1.387`, or the decoder's port measured outgoing) | stream started, **stream stopped**, stream resumed after *N s* (with what IGMP did meanwhile), **decoder switched off** (stream gone and no channel subscribed any more: logged as info, not a fault), stream lost (still subscribed: long outage), bitrate dip |
| **IGMP** | Joined groups on the proxy's upstream (`/proc/net/igmp`), multicast proxy process (igmpproxy, mcproxy, omcproxy), bridge MDB and IGMP timers | proxy stopped / restarted; every freeze is tagged as *channel change*, *membership dropped* or *still subscribed* |
| **IPTV picture quality** (optional) | The helper `isp-tester-tsmon` counts every packet of the incoming stream, continuously: MPEG-TS continuity errors (lost packets) of the channel being watched | **picture errors** (*N* lost-packet gaps, ~*M* packets, channel, longest pause); yellow for a while after errors |
| **Channel names** | Read from the stream itself (DVB SDT/PAT tables) by the same helper, or names set by hand | the channel being watched is named on the status page, in timeline events, the measurements CSV and notifications |
| **Ports** | `/sys/class/net/<dev>` counters and link state | link down/up, link flapping between samples, speed change (e.g. 1 Gbit → 100 Mbit), RX/TX/CRC errors, drops |
| **Router** | `/proc`: CPU per core (incl. softirq), RAM, connection tracking table. Only read to explain problems; for graphs use *Status → Realtime Graphs* or luci-app-statistics | router overloaded, low RAM, connection table full |
| **You** | **⚑ Problem now** button | your report with the time of the click and an optional note |
| **Path snapshot** | one `mtr -r` (when installed) or busybox `traceroute` when a loss starts or the WAN is down, at most every 10 min | *loss starts at hop N (IP) and carries on to the destination* – the hops fold out on the timeline and are in the report |
| **Bufferbloat** | collectd's ping matched with the WAN traffic of the same interval (device counters); line speed = highest 30 s rate seen or set | *bufferbloat: ping +N ms with the link X % full* / *over*; WAN traffic chart with the periods marked; card: ping idle vs. full link |
| **Wi-Fi** | hostapd over ubus (`get_clients` every interval + its disassoc/deauth/assoc notifications), signal from hostapd or iwinfo | a watched device (phone, TV) *dropped and reconnected* after N s (fault) or *left* (info), *moved to another band*, *weak signal* (two checks below the limit, default −75 dBm) |
| **Second router** (optional) | Events of a router behind this one (access point with a decoder, phone, TV), sent over UDP | everything that router logs, on the same timeline marked with its name; *router stopped reporting* / *reports again* |

Optionally it shows whether **IGMP snooping** and the **querier** are active on a bridge, and which group goes to which bridge port (needs `ip-bridge`).

The package does not duplicate what OpenWrt already does: ping comes from collectd, the session from netifd, messages from the system log, persistence from a mounted USB folder. The own measurements are the IPTV bitrate, read from the interface counters every second (collectd's 30 s average would hide freezes), and the optional picture quality scan (nothing in OpenWrt counts lost IPTV packets).

### Ping via collectd

```sh
opkg install luci-app-statistics collectd-mod-ping collectd-mod-unixsock
```

In *Statistics → Setup → Network plugins → Ping* add the ISP gateway (the WAN gateway or PPPoE peer) and one or two far hosts (e.g. `1.1.1.1`, `8.8.8.8`). Enable *UnixSock* in *General plugins* so the tester gets live values; without it, it reads the RRD files, which lag behind by the rrdtool cache time (minutes).

Gateway vs. far-target loss helps pinpoint the cause. Loss to the gateway points at the line or the ISP access network. Loss only to the far targets points further into the ISP's network.

## Web interface

**Status → ISP Tester → Overview**

- A large status banner: green "Everything works", yellow "Works, but there were problems" (within the last 15 min) or red "Fault right now".
- **Probable cause** panel for the selected period. It gives a verdict (*ISP*, *router / home network*, *mixed*), an ISP-vs-home ratio, and the findings behind it (see below).
- One card each for Internet, IPTV and Ports, with live values and the reason for any yellow or red state.
- **History** for up to 24 h: pick 1 h / 6 h / 24 h and move back and forward with ◀ ▶ (*Now* returns to live). A green/yellow/red state strip shows when things went wrong. The charts show ping with packet-loss bands, IPTV bitrate with stall bands, and interface errors. Hover a chart to see exact values. The last hour live uses 10 s samples; older data uses 1-minute aggregates (worst loss, minimum bitrate and summed errors are kept, so short glitches are not averaged away). The IPTV bitrate is measured on its own 1 s timer, so freezes of only a few seconds are logged with their exact start and length; the chart adds a *Lowest 1 s bitrate* line when a freeze is shorter than one chart point.
- A timeline of the selected period, filterable by area or "only problems". Click an event to zoom the charts to that moment.
- **When do problems happen**: problems per hour of the day. An evening peak points at an overloaded ISP network.
- **⚑ Problem now**: click it when the TV freezes or the Internet is slow. The mark goes on the timeline, and the analysis tells you whether the router measured anything at that moment. If not, the cause is probably the decoder, the TV, Wi-Fi, or the IPTV device is set wrong.
- **Report for the ISP**: a printable summary of the selected period (outages, freezes with total/longest duration, session drops, verdict, problems by hour, event log). Print it or save it as PDF and attach it to your complaint.
- Export buttons: measurements CSV (one row per interval) and timeline CSV.

**Status → ISP Tester → Settings** holds all thresholds, the IPTV VLAN (or device) and the list of ports. The ping hosts are set in collectd (luci-app-statistics).

The UI is in English and Polish.

## How the probable cause is decided

The panel looks at what happened **at the same time** (within 30 s) in the selected period:

| Observation | Points to |
|---|---|
| Packet loss already at the ISP gateway | ISP line / access network |
| Internet completely down while the WAN port keeps its link | ISP network |
| Loss only to far targets (2+ targets), gateway fine | ISP backbone / peering |
| Loss to a single far target only | that server (no weight) |
| WAN port loses link / has errors | line / ONT (counts half for both sides) |
| IPTV freeze together with Internet problems | ISP line |
| IPTV freeze together with a LAN port drop, error or speed downgrade | cable / switch at home |
| IPTV freezes at a regular interval (e.g. every ~125 s or ~260 s) | IGMP timeout, i.e. router configuration (querier / snooping / proxy) |
| IPTV freeze with nothing else happening, measured on the ISP VLAN | ISP multicast side (less often IGMP) |
| Lost packets (continuity errors) counted in the incoming IPTV stream | ISP IPTV / multicast side, not the home network |
| IPTV freeze with nothing else happening, measured on the decoder port | router (IGMP snooping / querier) |
| IPTV freeze while the router stayed subscribed to the channel | ISP multicast side |
| IPTV freeze that started with the IGMP membership being dropped | IGMP timeout on the router / switch |
| Freeze period matches the bridge's IGMP membership or query interval | IGMP timer, i.e. router configuration (stronger) |
| IPTV interruption with a different group after it | channel change: ignored |
| Stream gone and no channel subscribed for 15 s (`off_after`) | decoder switched off: not a fault, not counted |
| Multicast proxy stopped or restarted | router |
| PPPoE/DHCP session dropped while the WAN link stayed up | ISP |
| DNS failing while ping works | DNS server (ISP's, if you set it) |
| Problems while the router CPU / RAM / connection table was overloaded | router |
| Your "Problem now" reports with / without anything measured around them | context (no weight) |
| LAN link drops, CRC errors, renegotiation to 100 Mbit/s | cabling / devices at home |
| IGMP snooping on, querier off (with freezes) | router configuration |

Each finding is weighted (repeated occurrences count up to 5×). The verdict is "ISP" or "home" when one side has at least twice the weight of the other, otherwise "mixed". It is a hint, not proof. The timeline is the evidence you show the ISP.

## Data storage

Everything is kept in RAM in `/tmp/isp-tester/`, so flash is never written. The data survives a collector restart (e.g. after saving settings) but is lost on reboot, so download the CSVs before restarting the router.

To keep it across reboots, mount a USB stick (*System → Mount Points*) and set **Settings → General → Keep data on** to it (e.g. `/mnt/sda1`). `/tmp/isp-tester` then becomes a link to `<folder>/isp-tester`. If the stick is not mounted at start, the data stays in RAM. Do not point it at the internal flash. The current state (`state.json`) always stays in RAM in `/var/run/isp-tester/`.

### Archive: 7 / 30 days, weekly report

With the data on USB, **Settings → General → Archive on USB** (default 30 days) also keeps, per UTC day, in `/tmp/isp-tester/archive/`:

| File | Content |
|---|---|
| `ev-YYYYMMDD.jsonl` | every event of that day (also those of the second router), one JSON object per line |
| `h-YYYYMMDD.jsonl` | the chart data as 10-minute summaries (average / max / min as on the 24 h charts) |

The files are only appended to – one line per event and one per 10 minutes, never rewritten – which is easy on the stick; days older than the limit are deleted once an hour. The overview then offers **7 d** and **30 d**, and ◀ ▶ go back beyond 24 h: the page reads the day files it needs. The charts use the 10-minute summaries there, the timeline and the analysis use the archived events, and **Report for the ISP** covers the selected period – choose *7 d* for a weekly report. *Download timeline (CSV)* exports the selected period. In RAM the archive stays off (30 days would not fit); *Clear logs* deletes it too.

## Path snapshot at a loss

When a target starts losing packets (or everything is down), the collector runs one traceroute to a far target – the gateway alone would show nothing beyond hop 1. `mtr` (package `mtr`, 10 rounds at 0.5 s) is used when installed and gives loss per hop; otherwise busybox `traceroute -q 3`. The result is one event on the timeline: click it to fold out the hops.

How to read it: a loss that **starts at a hop and carries on to the destination** is where packets are lost – the event names that hop and the last good one before it. Loss at a single hop that does not continue is only a router answering pings slowly (ICMP rate limiting) and is ignored. If the destination shows no loss any more, the loss was already over when the snapshot ran (collectd reports per its interval, so the snapshot comes some seconds after the start; the event says how long after).

The report for the ISP lists every snapshot with its hop table. At most one per *At most every* (default 10 min), one at a time, stopped after 60 s.

## Bufferbloat: lags only when the link is full?

No speed test of its own: every collectd ping value (one average per collectd interval) is matched with the WAN traffic of the same interval, read from the WAN device's counters every tick. The line's speed is the highest 30-second rate ever seen (slowly forgotten, kept in `wanpeak.json`), or the speed of your plan when set (*Settings → Internet*).

- Ping at a load below 20 % is the base (median of the last 60 such values).
- Ping at a load of *Link full from* (70 %) or more that is *Ping increase* (30 ms) above the base, twice in a row, logs **bufferbloat** with the base, the ping, the load and the direction; two normal values end it.
- The Internet card shows *Ping idle / full link* – e.g. *10 ms / 80 ms (+70 ms) – lags only when the link is full* – and the line speed it uses. The chart *WAN traffic* marks the periods in yellow.
- The analysis puts it on the home side: your own traffic fills a buffer (modem or ISP). High-ping warnings during those periods are not counted against the ISP (loss still is). SQM (`luci-app-sqm`, cake, set a bit below the line speed) fixes it.

The load is known only when the link was full at least once (or the speed is set); until then the card says so.

## Wi-Fi

*Settings → Wi-Fi*: add the devices to watch (the list offers the ones connected now). Only those are logged; the others are counted per interface.

- **Dropped and reconnected** within *Reconnect within* (default 60 s) is a fault (yellow). A drop shorter than one interval is caught too, through hostapd's notifications.
- **Left** – away longer than that (the phone left the house) – is only noted.
- **Moved** to another band or access point of this router: noted, not a fault.
- **Weak signal**: two checks in a row below *Weak signal below*, back after two checks 5 dB above it; the event keeps the lowest value.

Why it matters: when you click **⚑ Problem now** and nothing was measured on the line, the analysis now says either *your report came with a Wi-Fi drop / weak signal of the phone – the cause is Wi-Fi*, or *the Wi-Fi of the watched devices was fine too – look at the decoder or the TV*. Devices behind a second router: set up Wi-Fi there and let it send its events here (next section).

Needs hostapd with ubus (the OpenWrt default) and, for the signal on drivers where hostapd gives none, `rpcd-mod-iwinfo` (installed with LuCI). Without an access point on the router the card says so.

## Two routers, one timeline

When the decoder, the phone or the TV sit behind a second router (e.g. an access point on a LAN port of the main router), each router only sees itself: the main one sees the ISP, the second one sees the devices. Install the package on both and let the second one send its events to the main one:

1. On the main router: *Settings → Second router → This router: Receives the events of a second router*, set a key (at least 8 characters).
2. On the second router: *Sends its events to the main router*, the main router's IPv4 address and the same key.

What you get on the main router:

- Every event of the second router appears on the timeline with its name in front (*M477S · Ports: lan1 link DOWN*). The timeline can be filtered by router; the report for the ISP includes them.
- A card shows the second router's state (its ports and IPTV), refreshed every interval. If it stops reporting for a minute (off, rebooting, the cable between the routers), that is logged and the banner turns yellow.
- The analysis uses its ports and your reports there as evidence for the home side, and points out IPTV freezes that the second router saw but the main router (nearer the ISP) did not: the stream was lost between the routers.
- Notifications of the main router include the second router's events.

How it works: UDP (default port 51477), one JSON message per datagram, signed with HMAC-SHA256 of the shared key; messages with another key are ignored and counted. The receiver confirms what it stored; anything unconfirmed is sent again every interval (up to 300 events are kept), so a short outage of the main router loses nothing. If the second router's clock is off by more than 5 s, its events are moved to the main router's time. The LAN zone of the default firewall accepts the port; if the second router is in another zone, open UDP 51477 on the main router for it. Only IPv4 addresses are used, so nothing needs to be resolved at boot.

## Notifications

**Settings → Notifications** sends a push message when something breaks and when it is fixed: [ntfy](https://ntfy.sh) (topic URL), a Telegram bot (token + chat id) or any webhook (JSON POST `{"text": …}`). Events are batched (default at most one message per 5 min). Messages that cannot be sent during an outage are sent when the Internet is back. Messages are in English or Polish. It uses `uclient-fetch` (part of OpenWrt) with HTTPS support.

| File | Content |
|------|---------|
| `/var/run/isp-tester/state.json` | current health + last hour of 10 s samples (always RAM) |
| `history.json` | 24 h of 1-minute aggregates for the history view |
| `events.json` | timeline (ring buffer, default 1000 entries) |
| `samples.csv` | one row per interval (ring buffer, default 8640 rows = 24 h at 10 s) |
| `samples.prev.csv` | previous CSV after the column layout changed (config change) |
| `archive/ev-*.jsonl`, `archive/h-*.jsonl` | with data on USB: events and 10-minute summaries per day (see *Archive*) |
| `wanpeak.json` | highest WAN rate seen (line speed for the bufferbloat check) |
| `/var/run/isp-tester/peers.json` | receiver: last event number stored per second router (always RAM) |

## Choosing what to measure IPTV on

**Simplest: enter the IPTV VLAN** (Settings → IPTV → *IPTV VLAN*, e.g. `387`). This is meant for the common setup where the ISP's IPTV VLAN is only bridged to the decoders (they get their address from the ISP) and the router has no `eth1.387` / `br-lan.387` device:

- the bridge, the port towards the ISP (e.g. `eth1`) and the decoder ports (e.g. `lan1`, `lan2`) are found from `bridge vlan show`;
- the bitrate comes from the bridge's per-VLAN counters (`bridge -s vlan show vid 387`). The kernel keeps them off by default, so the collector switches them on (`vlan_stats_enabled=1`, same as `ip link set br-lan type bridge vlan_stats_enabled 1`);
- the channels come from the bridge's multicast table (`bridge mdb`), shown per port, i.e. per decoder;
- link drops and errors of the ISP port count for the IPTV card.

One router is enough: decoders behind a second router/AP that only bridges the VLAN are seen through the port that leads to it (their IGMP joins pass through when snooping is off there). Only errors on the last cable behind that router are not visible.

Without a VLAN (under *Advanced*) you choose a device where **only IPTV** flows:

- **VLAN subinterface** from the ISP (e.g. `eth1.387`). Use *direction: incoming*.
- **Port towards the decoder**. Use *direction: outgoing*. This only works if nothing else uses that port.

Switch the TV on and check that the overview shows a few Mbit/s. Then set *stream threshold* below the lowest normal bitrate (default 500 kbit/s).

## IPTV picture quality (optional)

A freeze is only half of what goes wrong with IPTV: more often the picture breaks into blocks for a moment because a few packets were lost. The bitrate hardly changes then, so the bitrate monitor does not see it. The quality measurement counts the lost packets directly: every MPEG-TS packet carries a 4-bit continuity counter per stream, and a gap in it means packets are missing. Nothing is decoded, so it works on scrambled streams too.

Enable it in Settings → IPTV → *Picture quality*. It needs the package **`isp-tester-tsmon`** (see [Install](#install)); without it the IPTV card says so.

How it works, and what it costs:

- A small helper written in C (`/usr/sbin/isp-tester-tsmon`) listens on the ISP-side port of the IPTV VLAN, or on the configured device. The kernel filters the packets (only that VLAN, UDP multicast), so everything else, such as Internet traffic, never reaches it.
- It counts **every packet, all the time**, as it arrives: continuity errors, transport error flags, RTP gaps and pauses. Nothing is stored and no file is written except a small status file in RAM once a second. A HD stream is about 1000 packets/s and the work per packet is a few counter checks, so it is light even on small routers (`top` shows it after enabling).
- The collector reads the counters every interval. The thresholds count the errors **of the last minute**, so short glitches that happen once an hour or less are caught too, which short sampled captures would usually miss.
- If the router itself is too busy to take every packet (its socket buffer overflows), those packets are reported as *not counted*, and errors at that time are not logged as the ISP's fault.
- The channel being watched is the multicast group that carries TS, so channel changes need no setting and the log names the group. EPG/service groups are ignored. A second decoder on another channel is reported separately.
- Events are limited by the same cooldown as port errors; errors held back by it are added to the next event.
- It measures the stream **as it arrives at the router**, so lost packets found here come from the ISP side. Measured on the decoder port (direction *outgoing*), the result is only informational in the analysis.
- The helper is started by the collector, ends with it, and is restarted (with a growing pause) if it stops.

Thresholds (Settings → IPTV → Advanced): *Warn from* / *Fault from* count lost-packet gaps per minute (default 1 and 30), *Pause warning* flags a stream that pauses for that many ms (default 500).

## IPTV channel names

The status page, the timeline, the CSV and notifications name the channel being watched (*TVP 1 HD (239.1.1.1)*) instead of only its multicast group. The name comes from the stream: every DVB stream carries a Service Description Table with the service and provider name, and a PAT that says which service the stream is. Both are sent in the clear about every 1–2 s, also on encrypted channels.

- The same helper as the picture quality reads them from every channel that flows, so a new channel is named within a few seconds and known channels cost nothing extra. It runs for names alone too, when the picture quality is off.
- Learned names are kept in `channels.json` next to the timeline (so with *Keep data on* a USB folder they survive a reboot). Settings → *Names read from the streams* lists them and can forget them.
- Some operators send no names. Then the IPTV card says so, and names can be set by hand in Settings → *IPTV channel names* (multicast group → name); those always win.
- Text in DVB's own character sets (ISO 6937, ISO 8859-x, UTF-8, UCS-2) is converted to UTF-8, so Polish letters show correctly.
- Needs `isp-tester-tsmon`; can be switched off with *Identify channel names*.

## Install

### Package (recommended)

Ready-made packages are attached to every [release](https://github.com/matt400/luci-app-isp-tester/releases). `luci-app-isp-tester` is architecture-independent, so the same file works on every router. The helper for the picture quality and channel names, `isp-tester-tsmon`, is compiled, so there is one file per architecture: `isp-tester-tsmon_<arch>`, where `<arch>` is `OPENWRT_ARCH` from `/etc/os-release` (the commands below pick it automatically). Released architectures: `aarch64_cortex-a53`, `aarch64_cortex-a72`, `aarch64_generic`, `arm_cortex-a7_neon-vfpv4`, `arm_cortex-a9_vfpv3-d16`, `arm_cortex-a15_neon-vfpv4`, `mipsel_24kc`, `mips_24kc`, `x86_64`. For another one, build it yourself (below); everything else works without it.

**OpenWrt 24.10 (opkg):**

```sh
opkg update
opkg install https://github.com/matt400/luci-app-isp-tester/releases/latest/download/luci-app-isp-tester.ipk
# picture quality and channel names (optional, per architecture)
. /etc/os-release
opkg install https://github.com/matt400/luci-app-isp-tester/releases/latest/download/isp-tester-tsmon_${OPENWRT_ARCH}.ipk
# Polish translation (optional)
opkg install https://github.com/matt400/luci-app-isp-tester/releases/latest/download/luci-i18n-isp-tester-pl.ipk
```

**OpenWrt 25.12 and newer (apk):**

```sh
apk update
wget -O /tmp/isp-tester.apk https://github.com/matt400/luci-app-isp-tester/releases/latest/download/luci-app-isp-tester.apk
apk add --allow-untrusted /tmp/isp-tester.apk
# picture quality and channel names (optional, per architecture)
. /etc/os-release
wget -O /tmp/isp-tester-tsmon.apk https://github.com/matt400/luci-app-isp-tester/releases/latest/download/isp-tester-tsmon_${OPENWRT_ARCH}.apk
apk add --allow-untrusted /tmp/isp-tester-tsmon.apk
# Polish translation (optional)
wget -O /tmp/isp-tester-pl.apk https://github.com/matt400/luci-app-isp-tester/releases/latest/download/luci-i18n-isp-tester-pl.apk
apk add --allow-untrusted /tmp/isp-tester-pl.apk
```

`--allow-untrusted` is needed because the package is not signed with an OpenWrt key.

### Updating

Settings → **Updates** → *Check for updates*. The newest GitHub release is looked up, and a button installs it (`opkg` or `apk` is detected automatically), together with `isp-tester-tsmon` for the router's architecture when the release has it. The packages are downloaded from the release and verified against its `SHA256SUMS` before installing. Needs internet access from the router and `ca-bundle`.

### Build it yourself

In the OpenWrt SDK:

```sh
git clone https://github.com/matt400/luci-app-isp-tester package/luci-app-isp-tester
./scripts/feeds update -a && ./scripts/feeds install -a
make package/luci-app-isp-tester/compile V=s
# the helper: its own package in tsmon/
cp -r package/luci-app-isp-tester/tsmon package/isp-tester-tsmon
make package/isp-tester-tsmon/compile V=s
```

The packages end up in `bin/packages/*/base/`.

### Making a release

Push a tag like `v0.2.0`. GitHub Actions builds the `.ipk` (24.10) and `.apk` (25.12), the helper for each architecture listed above, and attaches them to the release. The version is taken from the tag.

### Quick test (copy files)

```sh
ROUTER=root@192.168.1.1
ssh $ROUTER 'opkg update && opkg install ucode-mod-fs ucode-mod-uloop ucode-mod-uci ucode-mod-ubus rpcd-mod-ucode'
scp -O -r root/* $ROUTER:/
scp -O -r htdocs/luci-static/resources/* $ROUTER:/www/luci-static/resources/
ssh $ROUTER 'chmod +x /etc/init.d/isp_tester && sh /etc/uci-defaults/80_luci-isp-tester'
```

This overwrites `/etc/config/isp_tester` and installs no translations. The helper is not included; build it with the SDK (or for a quick try with the toolchain: `$CC -O2 -o isp-tester-tsmon tsmon/src/tsmon.c`) and copy it to `/usr/sbin/`.

## Command line

```sh
/etc/init.d/isp_tester restart
logread -e isp-tester                 # collector errors
ubus call luci.isp_tester status
ubus call luci.isp_tester events '{"limit":20}'
```

## Development / testing off-device

The collector can run on any Linux machine with ucode (and the uloop module) against fake sysfs data:

```sh
ISP_TESTER_RUNDIR=/tmp/t/run ISP_TESTER_SYSNET=/tmp/t/sys \
ISP_TESTER_CONFIG=/tmp/t/cfg.json ISP_TESTER_VARDIR=/tmp/t/var \
ISP_TESTER_ROUTE=/tmp/t/route ucode root/usr/share/isp-tester/collector.uc
```

Further overrides: `ISP_TESTER_VARDIR`, `ISP_TESTER_PROC` (fake `/proc` with `stat`, `meminfo`, `net/igmp`, `<pid>/comm` …), `ISP_TESTER_WANSTATUS` (JSON file instead of `ubus call network.interface.wan status`), `ISP_TESTER_LOGREAD`, `ISP_TESTER_RRDTOOL`, `ISP_TESTER_FETCH`, `ISP_TESTER_BRIDGE`, and `ISP_TESTER_TSMON` (path of the helper; built with `cc -O2 -o tsmon tsmon/src/tsmon.c` it runs on any Linux, e.g. on `lo`, needs root). The helper also reads a capture: `isp-tester-tsmon -r capture.pcap` prints the same counters and names as JSON, handy to check a `tcpdump -w` recording from the router. Ping data comes from `wan.collectd_socket` (a collectd unixsock, e.g. a small test server) or `wan.rrd_dir` in the JSON config.

`ISP_TESTER_CONFIG` is a JSON file with the same keys as the UCI config (see `default_config()` in the collector).

## License

Apache-2.0
