# luci-app-isp-tester

An OpenWrt package with a LuCI web interface that watches your Internet connection, IPTV stream and switch ports, and records every problem with a timestamp. It is built for intermittent faults like IPTV freezing at random times, so you have concrete logs when you talk to your ISP.

Target: **OpenWrt 24.10** (ucode + rpcd + LuCI JS). No compiled code, the package is architecture-independent.

## What it monitors

| Area | How | Logged events |
|------|-----|---------------|
| **Internet** | Ping to the ISP gateway (auto-detected) and to configured targets (default `1.1.1.1`, `8.8.8.8`) in every interval | packet loss, high latency, target not responding, *Internet down* (no target responds), recovery with duration |
| **IPTV** | Bitrate on a device that carries only IPTV traffic (e.g. the IPTV VLAN `eth1.236`, or the decoder's port measured outgoing) | stream started, **stream stopped**, stream resumed after *N s*, stream lost (decoder off or long outage), bitrate dip |
| **Ports** | `/sys/class/net/<dev>` counters and link state | link down/up, link flapping between samples, speed change (e.g. 1 Gbit → 100 Mbit), RX/TX/CRC errors, drops |

Optionally it shows whether **IGMP snooping** and the **querier** are active on a bridge.

Gateway vs. far-target loss helps pinpoint the cause. Loss to the gateway points at the line or the ISP access network. Loss only to the far targets points further into the ISP's network.

## Web interface

**Status → ISP Tester → Overview**

- A large status banner: green "Everything works", yellow "Works, but there were problems" (within the last 15 min) or red "Fault right now".
- One card each for Internet, IPTV and Ports, with live values and the reason for any yellow or red state.
- Charts for the last hour: ping with packet-loss bands, IPTV bitrate with stall bands, and interface errors.
- A timeline of all events, filterable by area or "only problems".
- Export buttons: measurements CSV (one row per interval) and timeline CSV.

**Status → ISP Tester → Settings** holds all thresholds, ping targets, the IPTV device and the list of ports.

The UI is in English and Polish.

## Data storage

Everything is kept in RAM in `/tmp/isp-tester/`, so flash is never written. The data is lost on reboot, so download the CSVs before restarting.

| File | Content |
|------|---------|
| `state.json` | current health + chart history |
| `events.json` | timeline (ring buffer, default 1000 entries) |
| `samples.csv` | one row per interval (ring buffer, default 8640 rows = 24 h at 10 s) |
| `samples.prev.csv` | previous CSV after the column layout changed (config change) |

## Choosing the IPTV device

The bitrate has to be measured where **only IPTV** flows:

- **VLAN subinterface** from the ISP (e.g. `eth1.236`). Use *direction: incoming*. This is the best choice if it exists.
- **Port towards the decoder**. Use *direction: outgoing*. This only works if nothing else uses that port.

If the IPTV VLAN is bridged by hardware (DSA bridge VLAN filtering), multicast forwarded between bridge ports never reaches the bridge device's own counters. In that case, pick the decoder's port.

Switch the TV on and check that the overview shows a few Mbit/s. Then set *stream threshold* below the lowest normal bitrate (default 500 kbit/s).

## Install

### Build with the SDK / buildroot

```sh
# in the OpenWrt 24.10 SDK
git clone https://github.com/matt400/luci-app-isp-tester package/luci-app-isp-tester
./scripts/feeds update -a && ./scripts/feeds install -a
make package/luci-app-isp-tester/compile V=s
```

Copy the resulting package to the router and install it with `opkg install` / `apk add --allow-untrusted`.

### Quick test without building (copy files)

```sh
ROUTER=root@192.168.1.1
opkg update && opkg install ucode-mod-fs ucode-mod-uloop ucode-mod-uci ucode-mod-ubus rpcd-mod-ucode   # on the router
scp -O -r root/* $ROUTER:/
scp -O -r htdocs/luci-static/resources/view/isp-tester $ROUTER:/www/luci-static/resources/view/
ssh $ROUTER 'chmod +x /etc/init.d/isp_tester && sh /etc/uci-defaults/80_luci-isp-tester'
```

Translations are only installed by the package build.

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
ISP_TESTER_CONFIG=/tmp/t/cfg.json ISP_TESTER_PING=/tmp/t/ping.sh \
ISP_TESTER_ROUTE=/tmp/t/route ucode root/usr/share/isp-tester/collector.uc
```

`ISP_TESTER_CONFIG` is a JSON file with the same keys as the UCI config (see `default_config()` in the collector).

## License

Apache-2.0
