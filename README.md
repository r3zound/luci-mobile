# RouterPilot

<div align="center">
  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/flutter_01.png" alt="RouterPilot dashboard on Android" width="320"/>
</div>

RouterPilot is an open-source Flutter client for OpenWrt routers and CPEs. It talks to LuCI RPC so you can check router health, inspect clients and interfaces, scan Wi-Fi networks, and handle common admin tasks from a phone.

> **Not published to any store yet.** There is no Google Play, App Store or
> IzzyOnDroid listing for RouterPilot — do not install "LuCI Mobile" expecting it
> to be this app, it is a different application by a different developer. Build
> from source for now; see [Install](#install).

## What it does

- Saves multiple router profiles and switches between them. A profile can include a fallback address for access from another network.
- Shows throughput, CPU load, memory use, uptime, wireless signal, and interface status on one dashboard.
- Lists clients for every saved router or only the selected router. Search by hostname, IP address, MAC address, or vendor.
- Tells wired and wireless clients apart, using the wireless association table and the bridge forwarding table.
- Shows wired and wireless interface details, traffic totals, addresses, radio state, and channel information.
- Scans nearby Wi-Fi networks and can connect a router radio as a station.
- Edits wireless networks and radios: SSID, security, channel, width and country code.
- Reserves a DHCP address for a client, or blocks one with a firewall rule.
- Wakes a sleeping device over the network.
- Manages port forwards, traffic rules, zones and static routes.
- Edits the hostname, timezone and description, and changes the router password.
- Starts, stops and restarts services, and configures SQM, adblock, UPnP and DDNS.
- Runs ping, traceroute and nslookup from the router, and reads its system and kernel logs with matching lines highlighted and clickable to jump.
- Keeps an activity feed of what changed, and on Android can notify about it in the background.
- Shows traffic history per client where the router records it.
- Reboots a router after confirmation.
- Follows the system theme or uses a selected light or dark theme.
- Localised into 14 languages.

Where the router allows it, configuration changes go through its own
apply-with-rollback protocol: if the phone cannot confirm a change in time,
the router puts the previous configuration back by itself. Some routers do
not grant the permission that makes this work, and there the change is
committed immediately; the app says so while it is going in, rather than
letting you rely on a safety net that is not there.

Credentials and router profiles are stored through `flutter_secure_storage`. The app asks before trusting a self-signed HTTPS certificate. It does not include analytics, tracking, or advertising SDKs.

## Screenshots

| Dashboard | Login | Clients | Client details |
| --- | --- | --- | --- |
| <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/flutter_01.png" alt="Router dashboard" width="200"/> | <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/flutter_02.png" alt="Router login" width="200"/> | <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/flutter_03.png" alt="Connected clients" width="200"/> | <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/flutter_04.png" alt="Expanded client details" width="200"/> |

| Interfaces | Interface details |
| --- | --- | --- |
| <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/flutter_05.png" alt="Router interfaces" width="200"/> | <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/flutter_06.png" alt="Expanded interface details" width="200"/> |

## Install

No store release yet. Build from source instead:

```bash
git clone https://github.com/r3zound/router-pilot.git
cd router-pilot
flutter pub get
flutter run
```

Useful checks:

```bash
flutter analyze
flutter test
```

## Router setup

The router must run OpenWrt with LuCI enabled. RouterPilot also needs the LuCI RPC and wireless information modules:

```sh
# OpenWrt using opkg
opkg update
opkg install rpcd-mod-luci rpcd-mod-iwinfo

# OpenWrt using apk
apk update
apk add rpcd-mod-luci rpcd-mod-iwinfo

/etc/init.d/rpcd restart
```

Check that the RPC object is available:

```sh
ubus list luci-rpc
ubus call luci-rpc getNetworkDevices '{}'
```

## Troubleshooting

- If the app cannot connect, open the same router address in a browser and check the scheme, port, firewall, and VPN route.
- If login fails, verify the username, password, and administrator permissions in LuCI.
- If the dashboard is empty, install the RPC modules above, restart `rpcd`, and run the two `ubus` checks.
- If login or the dashboard times out even though LuCI works in a browser, the router's LuCI may stall on parallel requests ([openwrt/luci#9091](https://github.com/openwrt/luci/issues/9091)). Limit uhttpd to one request at a time:

  ```sh
  uci set uhttpd.main.max_requests=1
  uci commit uhttpd
  /etc/init.d/uhttpd restart
  ```
- Accept a self-signed certificate only after checking that its fingerprint belongs to your router.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow. Bug reports and focused pull requests are welcome.

## Upstream and modifications

RouterPilot is a **modified fork** of
[luci-mobile](https://github.com/cogwheel0/luci-mobile) by Tunap Paul
(cogwheel0). Upstream is the original work and remains fully credited; this
project is not a replacement for it and is not endorsed by the OpenWrt project.

What changed here, roughly in order of size:

- **Renamed and repackaged.** Renamed from `LuCI Mobile` to `RouterPilot`,
  including a new application id (`com.r3zound.routerpilot`), a new Dart
  package name, and a new launcher icon.
- **Localisation.** Completed and corrected the translations for all 14
  languages, following a dedicated OpenWrt terminology glossary so that, for
  example, an interface that is `up` reads as *online* rather than *up*, and
  *bandwidth* is never used where *channel width* is meant.
- **Device page.** Cellular and uplink readings merged into one card,
  temperature folded into the system card, and the power card removed — it
  duplicated what the router's own web interface already shows.
- **Client link type.** Wired and wireless clients are now told apart using the
  wireless association table and the bridge forwarding table, instead of
  guessing.
- **Log viewer.** Matching lines are highlighted and each direction arrows let
  you jump to older or newer entries, without dropping anything from the list.
- **Cross-distribution compatibility.** System logs fall back to the router's
  own syslog wrapper when `logread` flags are unavailable, the kernel log
  reader was corrected, and diagnostics tools are looked for in every location
  a distribution might put them.
- **About box** points at this repository rather than upstream.

Firewall and traffic rules carry a section-name prefix that is written into the
router's own `/etc/config`. Rules created under the old `luci_mobile_` prefix
are still recognised and removed rather than stranded.

## License

RouterPilot is licensed under [GPL-3.0](LICENSE), the same license as upstream.
It is an independent project and is not affiliated with OpenWrt.

Original work Copyright (C) 2025 Tunap Paul (cogwheel0).
Modifications Copyright (C) 2026 r3zound.

Thanks to the OpenWrt and Flutter communities, the upstream project contributors and testers, and [OpenWrtManager](https://github.com/hagaygo/OpenWrtManager) for early inspiration.