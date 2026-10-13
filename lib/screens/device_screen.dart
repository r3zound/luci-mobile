import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:luci_mobile/design/luci_design_system.dart';
import 'package:luci_mobile/l10n/luci_localizations.dart';
import 'package:luci_mobile/services/mu300_service.dart';
import 'package:luci_mobile/state/app_state_provider.dart';
import 'package:luci_mobile/utils/format_bytes.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';

final mu300ServiceProvider = Provider<Mu300Service?>((ref) {
  final api = ref.watch(apiServiceProvider);
  return api == null ? null : Mu300Service(api);
});

/// What the vendor's own `mu300dash` object knows about this router.
///
/// The rest of the app talks to stock OpenWrt ubus objects - `system`,
/// `network.device`, `luci-rpc` - and on a ZTE V50 those describe a router
/// with a WiFi radio and an Ethernet port, and stop there. The modem is
/// invisible to all of them. Everything cellular - which 5G cell, how good the
/// link is, how hot the baseband is, which bands are locked - only exists on
/// `mu300dash`, so it has its own screen rather than being folded into
/// Insights where it would be missing on every other router.
///
/// Two rules run through the whole file:
///
///   * A band or mode that gets locked wrong costs the connection for half a
///     minute, so every write goes through a confirmation that says so.
///   * The writes are *accepted*, not *finished* - see [LockApply] - so the
///     screen re-reads instead of trusting its own optimistic update.
class DeviceScreen extends ConsumerStatefulWidget {
  const DeviceScreen({super.key});

  @override
  ConsumerState<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends ConsumerState<DeviceScreen> {
  /// `mu300dash.status`: `{info, cell, sig, cell_age, sig_age, refreshing}`.
  Map<String, dynamic>? _status;

  /// `mu300dash.lock_get`: current locks, supported bands, replay setting.
  Map<String, dynamic>? _lock;

  /// `mu300dash.power_get`: profile, supply, battery, every tunable knob.
  Map<String, dynamic>? _power;

  bool _loading = true;
  bool _applying = false;

  /// True once we know this router has no `mu300dash` at all, which is the
  /// normal case for anything that is not a ZTE V50.
  bool _unsupported = false;

  /// Pending band selections, keyed `nr` / `lte`. Null means "unchanged".
  final _picked = <String, Set<int>>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool reapplyLocks = false}) async {
    final session = ref.read(sessionProvider);
    final service = ref.read(mu300ServiceProvider);
    if (session == null || service == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (mounted) setState(() => _loading = true);

    // Three calls in parallel: `status` is the vendor's own combined snapshot
    // and is the expensive one, the other two are cached reads that answer
    // instantly. Nothing here blocks the others.
    final results = await Future.wait([
      service.status(session),
      service.bands(session),
      service.power(session),
    ]);
    if (!mounted) return;

    final status = results[0];
    final lock = results[1];
    final power = results[2];

    setState(() {
      _status = status;
      _lock = lock;
      _power = power;
      _loading = false;
      // Only conclude "unsupported" when the primary object is absent; a
      // transient failure of the two secondary reads must not blank the page.
      if (status == null) _unsupported = true;
      if (reapplyLocks) _picked.clear();
    });
  }

  /// Re-reads the locks a few seconds after an apply.
  ///
  /// The adapter itself loops for 30s in the background trying to get a fresh
  /// read-back; the app mirrors that rather than inventing an optimistic
  /// value, because a lock that did not take is the single most confusing
  /// failure this screen could have.
  Future<void> _recheckAfterApply() async {
    for (final wait in const [4, 10, 25]) {
      await Future<void>.delayed(Duration(seconds: wait));
      if (!mounted) return;
      await _load(reapplyLocks: true);
      if (!mounted) return;
    }
  }

  Future<void> _confirmAndApply(
    String title,
    String body,
    Future<LockApply> Function() action,
  ) async {
    final service = ref.read(mu300ServiceProvider);
    if (service == null || _applying) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.deviceApply),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _applying = true);
    final l10n = context.l10n;
    LockApply result;
    try {
      result = await action();
    } catch (error) {
      result = LockApply(accepted: false, message: error.toString());
    }
    if (!mounted) return;

    final message = result.accepted
        ? (result.detached ? l10n.deviceReconnecting : l10n.deviceApplyStarted)
        : (result.busy
              ? l10n.deviceRadioBusy
              : (result.message ?? l10n.deviceApplyRefused));

    setState(() => _applying = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
    if (result.accepted) await _recheckAfterApply();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    if (_unsupported) {
      return Scaffold(
        appBar: LuciAppBar(title: l10n.device, showBack: true),
        body: ListView(
          padding: const EdgeInsets.all(LuciSpacing.md),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(LuciSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.deviceUnsupportedTitle,
                      style: LuciTextStyles.cardTitle(context),
                    ),
                    const SizedBox(height: LuciSpacing.sm),
                    Text(l10n.deviceUnsupportedBody),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final info = _sub(_status, 'info');
    final sig = _sub(_status, 'sig') ?? _sub(_status, 'cell');

    return Scaffold(
      appBar: LuciAppBar(
        title: l10n.device,
        showBack: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.refresh,
            onPressed: _loading ? null : () => _load(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(reapplyLocks: true),
        child: ListView(
          padding: const EdgeInsets.all(LuciSpacing.md),
          children: [
            if (_loading && _status == null)
              const Padding(
                padding: EdgeInsets.all(LuciSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              ),

            if (sig != null) ...[
              _CellularCard(sig: sig),
              const SizedBox(height: LuciSpacing.md),
            ],
            if (info != null) _TemperaturesCard(info: info),
            if (info != null) _WanCard(info: info),
            if (info != null) _WifiCard(info: info),
            if (_power != null) _PowerCard(power: _power!),
            if (_lock != null && info != null) ...[
              const SizedBox(height: LuciSpacing.md),
              _ControlsCard(
                lock: _lock!,
                info: info,
                picked: _picked,
                busy: _applying,
                onToggleBand: (kind, band) => setState(() {
                  final set = _picked.putIfAbsent(kind, () => <int>{});
                  if (!set.remove(band)) set.add(band);
                }),
                onPickAutomatic: (kind) => setState(() => _picked.remove(kind)),
                onApplyBands: (kind) => _applyBands(kind),
                onMode: (mode) => _applyMode(mode),
                onToggleRadio: (arg) => _applyRadio(arg),
                onToggleWifi: (arg) => _applyWifi(arg),
                onToggleData: (arg) => _applyData(arg),
              ),
            ],
            if (info != null) _SystemCard(info: info),
          ],
        ),
      ),
    );
  }

  // ----------------------------------------------------------------- writes

  /// The set the user has actually chosen, or null when they have not touched
  /// the card - "unchanged" and "automatic" are different intents and must not
  /// collapse into one another.
  Set<int>? _selectionFor(String kind) {
    if (_picked.containsKey(kind)) return _picked[kind];
    return null;
  }

  Future<void> _applyBands(String kind) async {
    final session = ref.read(sessionProvider);
    final service = ref.read(mu300ServiceProvider);
    if (session == null || service == null) return;

    final picked = _selectionFor(kind);
    if (picked == null) return;
    // Empty string is the adapter's encoding for "automatic"; sending "1,,3"
    // would be refused.
    final bands = picked.isEmpty ? '' : (picked.toList()..sort()).join(',');
    final l10n = context.l10n;
    final label = kind == 'nr' ? 'NR' : 'LTE';
    final automatic = bands.isEmpty;

    await _confirmAndApply(
      l10n.deviceBandConfirmTitle,
      automatic
          ? l10n.deviceBandConfirmAutomatic(label)
          : l10n.deviceBandConfirmBands(label, bands),
      () => service.setBandLock(session, kind: kind, bands: bands),
    );
  }

  Future<void> _applyMode(String mode) async {
    final session = ref.read(sessionProvider);
    final service = ref.read(mu300ServiceProvider);
    if (session == null || service == null) return;
    final l10n = context.l10n;
    await _confirmAndApply(
      l10n.deviceModeConfirmTitle,
      l10n.deviceModeConfirmBody(_modeLabel(mode)),
      () => service.setNetworkMode(session, mode),
    );
  }

  Future<void> _applyRadio(String arg) async {
    final session = ref.read(sessionProvider);
    final service = ref.read(mu300ServiceProvider);
    if (session == null || service == null) return;
    final l10n = context.l10n;
    final turningOff = arg == 'off';
    await _confirmAndApply(
      turningOff ? l10n.deviceRadioOffTitle : l10n.deviceRadioOnTitle,
      turningOff ? l10n.deviceRadioOffBody : l10n.deviceRadioOnBody,
      () => service.act(session, op: 'radio', arg: arg),
    );
  }

  Future<void> _applyWifi(String arg) async {
    final session = ref.read(sessionProvider);
    final service = ref.read(mu300ServiceProvider);
    if (session == null || service == null) return;
    setState(() => _applying = true);
    final result = await service.act(session, op: 'wifi', arg: arg);
    if (!mounted) return;
    setState(() => _applying = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.accepted
              ? context.l10n.deviceApplyStarted
              : (result.message ?? context.l10n.deviceApplyRefused),
        ),
      ),
    );
    await _load(reapplyLocks: true);
  }

  Future<void> _applyData(String arg) async {
    final session = ref.read(sessionProvider);
    final service = ref.read(mu300ServiceProvider);
    if (session == null || service == null) return;
    final l10n = context.l10n;
    await _confirmAndApply(
      arg == 'down' ? l10n.deviceDataOffTitle : l10n.deviceDataOnTitle,
      arg == 'down' ? l10n.deviceDataOffBody : l10n.deviceDataOnBody,
      () => service.act(session, op: 'data', arg: arg),
    );
  }

  String _modeLabel(String mode) => switch (mode) {
    '4g' => context.l10n.deviceMode4g,
    'sa' => context.l10n.deviceModeSa,
    'nsa' => context.l10n.deviceModeNsa,
    _ => context.l10n.deviceModeAuto,
  };
}

/// Registration and radio measurements, the thing stock LuCI cannot show.
class _CellularCard extends StatelessWidget {
  const _CellularCard({required this.sig});

  final Map<String, dynamic> sig;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final measurements = _sub(sig, 'sig');
    final quality = SignalReading.grade(measurements);
    final source = (sig['sig_src'] ?? '').toString();
    final reg = _sub(sig, 'reg5g') ?? _sub(sig, 'reg');
    final lte = _sub(sig, 'lte');

    final readings = <SignalReading?>[
      SignalReading.tryBuild(measurements, 'rsrp', 'RSRP', unit: 'dBm'),
      SignalReading.tryBuild(measurements, 'rsrq', 'RSRQ', unit: 'dB'),
      SignalReading.tryBuild(measurements, 'sinr', 'SINR', unit: 'dB'),
      SignalReading.tryBuild(
        measurements,
        'band',
        source == 'nr' ? 'NR band' : 'LTE band',
      ),
      SignalReading.tryBuild(measurements, 'arfcn', 'ARFCN'),
      SignalReading.tryBuild(measurements, 'pci', 'PCI'),
      SignalReading.tryBuild(measurements, 'gnb', 'gNB'),
      SignalReading.tryBuild(measurements, 'cid', 'CID'),
      SignalReading.tryBuild(measurements, 'bw_mhz', 'BW', unit: 'MHz'),
      SignalReading.tryBuild(measurements, 'dl_mcs', 'DL MCS'),
      SignalReading.tryBuild(measurements, 'ul_mcs', 'UL MCS'),
    ].whereType<SignalReading>().toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(LuciSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.deviceCellular,
                    style: LuciTextStyles.cardTitle(context),
                  ),
                ),
                _QualityChip(quality: quality),
              ],
            ),
            const SizedBox(height: LuciSpacing.xs),
            Text(
              signalQualityText(context, quality),
              style: LuciTextStyles.cardSubtitle(context),
            ),
            const SizedBox(height: LuciSpacing.md),
            _ReadingGrid(readings: readings),
            if (lte != null) ...[
              const SizedBox(height: LuciSpacing.md),
              Text('LTE anchor', style: LuciTextStyles.cardSubtitle(context)),
              const SizedBox(height: LuciSpacing.xs),
              _ReadingGrid(
                readings: [
                  SignalReading.tryBuild(lte, 'rsrp', 'RSRP', unit: 'dBm'),
                  SignalReading.tryBuild(lte, 'rsrq', 'RSRQ', unit: 'dB'),
                  SignalReading.tryBuild(lte, 'sinr', 'SINR', unit: 'dB'),
                  SignalReading.tryBuild(lte, 'band', 'LTE band'),
                  SignalReading.tryBuild(lte, 'arfcn', 'ARFCN'),
                  SignalReading.tryBuild(lte, 'pci', 'PCI'),
                ].whereType<SignalReading>().toList(),
              ),
            ],
            if (reg != null) ...[
              const SizedBox(height: LuciSpacing.md),
              Text(
                l10n.deviceRegistration,
                style: LuciTextStyles.cardSubtitle(context),
              ),
              const SizedBox(height: LuciSpacing.xs),
              _KeyValues(
                entries: {
                  l10n.deviceRegistered: _registrationState(reg['stat']),
                  'TAC': (reg['tac'] ?? '').toString(),
                  'CID': (reg['cid'] ?? '').toString(),
                  'ACT': (reg['act'] ?? '').toString(),
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// `stat` is the modem's own registration code; 1 is "registered home",
  /// 5 is "registered roaming". Anything else is shown as the number rather
  /// than guessed at.
  static String _registrationState(Object? stat) => switch (stat) {
    1 => 'Home',
    5 => 'Roaming',
    null => '',
    _ => stat.toString(),
  };
}

/// The five sensors the vendor reads. `hottest` is the one that matters - it
/// is the value its thermal guard acts on.
class _TemperaturesCard extends StatelessWidget {
  const _TemperaturesCard({required this.info});

  final Map<String, dynamic> info;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final temps = _sub(info, 'temps');
    if (temps == null || temps.isEmpty) return const SizedBox.shrink();

    final readings = <SignalReading?>[
      SignalReading.tryBuild(temps, 'soc', l10n.deviceTempSoc, unit: '°C'),
      SignalReading.tryBuild(temps, 'cpu', l10n.deviceTempCpu, unit: '°C'),
      SignalReading.tryBuild(temps, 'modem', l10n.deviceTempModem, unit: '°C'),
      SignalReading.tryBuild(temps, 'board', l10n.deviceTempBoard, unit: '°C'),
      SignalReading.tryBuild(
        temps,
        'hottest',
        l10n.deviceTempHottest,
        unit: '°C',
      ),
    ].whereType<SignalReading>().toList();
    if (readings.isEmpty) return const SizedBox.shrink();

    return _SectionCard(
      title: l10n.deviceTemperatures,
      child: _ReadingGrid(readings: readings),
    );
  }
}

/// The cellular uplink, plus the counters the vendor keeps per interface.
class _WanCard extends StatelessWidget {
  const _WanCard({required this.info});

  final Map<String, dynamic> info;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final wan = _sub(info, 'wan');
    if (wan == null) return const SizedBox.shrink();
    final mobile = _sub(_sub(info, 'net'), 'mobile');

    return _SectionCard(
      title: l10n.deviceWan,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _KeyValues(
            entries: {
              l10n.status: wan['up'] == 1 ? l10n.up : l10n.down,
              'Protocol': (wan['proto'] ?? '—').toString(),
              'APN': (wan['apn'] ?? '—').toString(),
              'IPv4': (wan['ip4'] ?? '—').toString(),
              'IPv6': (wan['ip6'] ?? '—').toString(),
              'DNS': (wan['dns'] ?? '—').toString(),
              l10n.deviceUptime: _uptime(_int(wan['uptime'])),
            },
          ),
          if (mobile != null) ...[
            const SizedBox(height: LuciSpacing.md),
            Text(
              l10n.deviceDataUsage,
              style: LuciTextStyles.cardSubtitle(context),
            ),
            const SizedBox(height: LuciSpacing.xs),
            _KeyValues(
              entries: {
                l10n.download: formatBytes(_int(mobile['rx'])),
                l10n.upload: formatBytes(_int(mobile['tx'])),
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// The AP, as the vendor describes it. `clients_n` is a count because
/// `clients` is an empty array even when the AP is serving clients - the
/// firmware only fills it in for some code paths.
class _WifiCard extends StatelessWidget {
  const _WifiCard({required this.info});

  final Map<String, dynamic> info;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final wifi = _sub(info, 'wifi');
    if (wifi == null) return const SizedBox.shrink();

    return _SectionCard(
      title: l10n.deviceWifi,
      child: _KeyValues(
        entries: {
          l10n.status: wifi['up'] == 1 ? l10n.up : l10n.down,
          l10n.deviceSsid: (wifi['ssid'] ?? '—').toString(),
          l10n.deviceChannel: (wifi['channel'] ?? '—').toString(),
          'Band': wifi['band'] == '5g' ? '5 GHz' : '2.4 GHz',
          l10n.deviceWidth: (wifi['width'] ?? '—').toString(),
          l10n.deviceCountry: (wifi['country'] ?? '—').toString(),
          l10n.deviceEncryption: _encryption(wifi['enc']),
          l10n.clients: '${_int(wifi['clients_n'])}',
        },
      ),
    );
  }

  /// `enc` is hostapd's own vocabulary, not a WPA name.
  static String _encryption(Object? enc) => switch (enc) {
    'psk2' => 'WPA2-PSK',
    'psk3' => 'WPA3-PSK',
    'wpa2' => 'WPA2',
    'open' => 'Open',
    null => '—',
    _ => enc.toString(),
  };
}

class _PowerCard extends StatelessWidget {
  const _PowerCard({required this.power});

  final Map<String, dynamic> power;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final battery = _sub(power, 'battery');
    final charger = _sub(power, 'charger');

    return _SectionCard(
      title: l10n.devicePower,
      child: _KeyValues(
        entries: {
          l10n.deviceState: (power['state'] ?? '—').toString(),
          l10n.deviceProfile: (power['profile'] ?? '—').toString(),
          l10n.deviceSupply: (power['supply'] ?? '—').toString(),
          if (battery != null) ...{
            l10n.deviceBattery: '${_int(battery['capacity'])} %',
            l10n.deviceChargeState: (battery['status'] ?? '—').toString(),
            l10n.deviceVoltage: '${_int(battery['mv'])} mV',
          },
          if (charger != null)
            l10n.deviceCharger: (charger['status'] ?? '—').toString(),
        },
      ),
    );
  }
}

/// Everything that writes. Split out so the card stays readable: each block
/// states what it will do before it does it.
class _ControlsCard extends StatelessWidget {
  const _ControlsCard({
    required this.lock,
    required this.info,
    required this.picked,
    required this.busy,
    required this.onToggleBand,
    required this.onPickAutomatic,
    required this.onApplyBands,
    required this.onMode,
    required this.onToggleRadio,
    required this.onToggleWifi,
    required this.onToggleData,
  });

  final Map<String, dynamic> lock;
  final Map<String, dynamic> info;
  final Map<String, Set<int>> picked;
  final bool busy;
  final void Function(String kind, int band) onToggleBand;
  final void Function(String kind) onPickAutomatic;
  final void Function(String kind) onApplyBands;
  final void Function(String mode) onMode;
  final void Function(String arg) onToggleRadio;
  final void Function(String arg) onToggleWifi;
  final void Function(String arg) onToggleData;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final mode = _sub(lock, 'mode');
    final currentMode = (mode?['label'] ?? 'auto').toString();

    // Switch states come from the vendor's own snapshot, not from local
    // optimism: `wifi.up` is what hostapd reports, `modem.alive` is whether
    // the AT daemon still answers, `modem.data_paused` is the data toggle.
    // A switch that disagrees with the router is worse than no switch.
    final wifiUp = _sub(info, 'wifi')?['up'] == 1;
    final modem = _sub(info, 'modem');
    final radioUp = modem?['alive'] == 1;
    final dataUp = modem != null && modem['data_paused'] != 1;

    return _SectionCard(
      title: l10n.deviceControls,
      subtitle: l10n.deviceControlsHint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- network mode -------------------------------------------------
          Text(
            l10n.deviceNetworkMode,
            style: LuciTextStyles.cardSubtitle(context),
          ),
          const SizedBox(height: LuciSpacing.xs),
          Wrap(
            spacing: LuciSpacing.sm,
            children: [
              ChoiceChip(
                label: Text(l10n.deviceModeAuto),
                selected: currentMode == 'auto',
                onSelected: busy ? null : (_) => onMode('auto'),
              ),
              ChoiceChip(
                label: Text(l10n.deviceMode4g),
                selected: currentMode == '4g',
                onSelected: busy ? null : (_) => onMode('4g'),
              ),
              ChoiceChip(
                label: Text(l10n.deviceModeSa),
                selected: currentMode == 'sa',
                onSelected: busy ? null : (_) => onMode('sa'),
              ),
              ChoiceChip(
                label: Text(l10n.deviceModeNsa),
                selected: currentMode == 'nsa',
                onSelected: busy ? null : (_) => onMode('nsa'),
              ),
            ],
          ),
          const SizedBox(height: LuciSpacing.lg),

          // ---- band locks ---------------------------------------------------
          _BandBlock(
            label: 'NR',
            prefix: 'n',
            supported: Mu300Service.supportedBands(lock, 'nr'),
            locked: _bandsOf(lock, 'nr'),
            picked: picked['nr'],
            busy: busy,
            onToggleBand: (band) => onToggleBand('nr', band),
            onAutomatic: () => onPickAutomatic('nr'),
            onApply: () => onApplyBands('nr'),
            automaticLabel: l10n.deviceAutomatic,
            applyLabel: l10n.deviceApply,
          ),
          _BandBlock(
            label: 'LTE',
            prefix: '',
            supported: Mu300Service.supportedBands(lock, 'lte'),
            locked: _bandsOf(lock, 'lte'),
            picked: picked['lte'],
            busy: busy,
            onToggleBand: (band) => onToggleBand('lte', band),
            onAutomatic: () => onPickAutomatic('lte'),
            onApply: () => onApplyBands('lte'),
            automaticLabel: l10n.deviceAutomatic,
            applyLabel: l10n.deviceApply,
          ),
          const SizedBox(height: LuciSpacing.sm),

          // ---- switches -----------------------------------------------------
          _SwitchRow(
            label: l10n.deviceCellularRadio,
            value: radioUp,
            onChanged: busy ? null : (on) => onToggleRadio(on ? 'on' : 'off'),
          ),
          _SwitchRow(
            label: l10n.deviceMobileData,
            value: dataUp,
            onChanged: busy ? null : (on) => onToggleData(on ? 'up' : 'down'),
          ),
          _SwitchRow(
            label: l10n.deviceWifi,
            value: wifiUp,
            onChanged: busy ? null : (on) => onToggleWifi(on ? 'on' : 'off'),
          ),
        ],
      ),
    );
  }

  static Set<int> _bandsOf(Map<String, dynamic> lock, String kind) {
    final block = _sub(lock, kind);
    final raw = block?['locked'];
    if (raw is! String || raw.isEmpty) return const {};
    return raw
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .toSet();
  }
}

/// One RAT's band picker.
///
/// The chips offered come from `caps`, never from a hardcoded list: the
/// vendor's adapter refuses to program a band the RF chain cannot use, and its
/// own header records that an earlier wrong decode (n79) wedged the baseband
/// until the device was power-cycled. Offering a band the modem cannot
/// transmit on is exactly that failure, one tap away.
class _BandBlock extends StatelessWidget {
  const _BandBlock({
    required this.label,
    required this.prefix,
    required this.supported,
    required this.locked,
    required this.picked,
    required this.busy,
    required this.onToggleBand,
    required this.onAutomatic,
    required this.onApply,
    required this.automaticLabel,
    required this.applyLabel,
  });

  final String label;

  /// `n` for NR, which the 3GPP specs write as n28; empty for LTE, which they
  /// write as B28. Using the wrong prefix is not a cosmetic slip - "n28" and
  /// "28" name different things to anyone cross-checking against a spec.
  final String prefix;

  final List<int> supported;
  final Set<int> locked;
  final Set<int>? picked;
  final bool busy;
  final void Function(int band) onToggleBand;
  final VoidCallback onAutomatic;
  final VoidCallback onApply;
  final String automaticLabel;
  final String applyLabel;

  @override
  Widget build(BuildContext context) {
    if (supported.isEmpty) return const SizedBox.shrink();
    final selected = picked ?? locked;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: LuciTextStyles.cardSubtitle(context)),
            const Spacer(),
            Text(
              picked == null
                  ? (locked.isEmpty ? automaticLabel : locked.join(', '))
                  : (selected.isEmpty
                        ? automaticLabel
                        : (selected.toList()..sort()).join(', ')),
              style: LuciTextStyles.cardSubtitle(context),
            ),
          ],
        ),
        const SizedBox(height: LuciSpacing.xs),
        Wrap(
          spacing: LuciSpacing.sm,
          runSpacing: LuciSpacing.xs,
          children: [
            FilterChip(
              label: Text(automaticLabel),
              selected: selected.isEmpty,
              onSelected: busy ? null : (_) => onAutomatic(),
            ),
            for (final band in supported)
              FilterChip(
                label: Text('$prefix$band'),
                selected: selected.contains(band),
                onSelected: busy ? null : (_) => onToggleBand(band),
              ),
          ],
        ),
        if (picked != null) ...[
          const SizedBox(height: LuciSpacing.xs),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              onPressed: busy ? null : onApply,
              child: Text(applyLabel),
            ),
          ),
        ],
        const SizedBox(height: LuciSpacing.md),
      ],
    );
  }
}

/// Firmware, uptime, CPU, memory, storage.
class _SystemCard extends StatelessWidget {
  const _SystemCard({required this.info});

  final Map<String, dynamic> info;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cpu = _sub(info, 'cpu');
    final mem = _sub(info, 'mem');
    final storage = _sub(info, 'storage');

    return _SectionCard(
      title: l10n.deviceSystem,
      child: _KeyValues(
        entries: {
          l10n.deviceHost: (info['host'] ?? '—').toString(),
          l10n.deviceModel: (info['model'] ?? '—').toString(),
          l10n.deviceFirmware: (info['fw'] ?? '—').toString(),
          l10n.deviceKernel: (info['kernel'] ?? '—').toString(),
          l10n.deviceUptime: _uptime(_int(info['uptime'])),
          if (cpu != null) l10n.deviceCpuCores: '${_int(cpu['n'])}',
          if (mem != null)
            l10n.deviceMemory:
                '${formatBytes(_int(mem['avail_kb']) * 1024)} / ${formatBytes(_int(mem['total_kb']) * 1024)}',
          if (storage != null)
            l10n.deviceStorage:
                '${formatBytes(_int(storage['used_kb']) * 1024)} / ${formatBytes(_int(storage['total_kb']) * 1024)}',
        },
      ),
    );
  }
}

// ------------------------------------------------------------------ pieces

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child, this.subtitle});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: LuciSpacing.md),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(LuciSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: LuciTextStyles.cardTitle(context)),
              if (subtitle != null) ...[
                const SizedBox(height: LuciSpacing.xs),
                Text(subtitle!, style: LuciTextStyles.cardSubtitle(context)),
              ],
              const SizedBox(height: LuciSpacing.md),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// A two-column list. Right-aligned values so digits line up, which is what
/// makes a column of dBm readings scannable instead of a ragged wall.
class _KeyValues extends StatelessWidget {
  const _KeyValues({required this.entries});

  final Map<String, String> entries;

  @override
  Widget build(BuildContext context) {
    final visible = entries.entries.where((e) => e.value.isNotEmpty).toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in visible)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 4,
                  child: Text(
                    entry.key,
                    style: LuciTextStyles.detailLabel(context),
                  ),
                ),
                Expanded(
                  flex: 6,
                  child: Text(
                    entry.value,
                    textAlign: TextAlign.end,
                    style: LuciTextStyles.detailValue(context),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Label / value / unit in a wrapping grid - used for the radio readings,
/// where the number is the point and the label is context.
class _ReadingGrid extends StatelessWidget {
  const _ReadingGrid({required this.readings});

  final List<SignalReading> readings;

  @override
  Widget build(BuildContext context) {
    if (readings.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: LuciSpacing.lg,
      runSpacing: LuciSpacing.sm,
      children: [
        for (final reading in readings)
          SizedBox(
            width: 104,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reading.label,
                  style: LuciTextStyles.cardSubtitle(context),
                ),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(
                        reading.value,
                        style: LuciTextStyles.detailValue(context),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (reading.unit != null)
                      Text(
                        ' ${reading.unit}',
                        style: LuciTextStyles.cardSubtitle(
                          context,
                        ).copyWith(color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _QualityChip extends StatelessWidget {
  const _QualityChip({required this.quality});

  final SignalQuality quality;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Green / amber / red straight from the scheme so it survives dark mode;
    // hand-picked colours are the thing that always ends up unreadable.
    final (background, foreground) = switch (quality) {
      SignalQuality.excellent => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      SignalQuality.good => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      SignalQuality.fair => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      SignalQuality.poor => (scheme.errorContainer, scheme.onErrorContainer),
      SignalQuality.unknown => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        signalQualityText(context, quality),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final void Function(bool)? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(label, style: LuciTextStyles.detailLabel(context)),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

// ----------------------------------------------------------------- helpers

/// The router's replies are `Map` or `Map<String, dynamic>` depending on which
/// JSON decoder produced them, so every nested read goes through here rather
/// than casting at each call site.
Map<String, dynamic>? _sub(Map<String, dynamic>? source, String key) {
  if (source == null) return null;
  final value = source[key];
  return value is Map ? Map<String, dynamic>.from(value) : null;
}

int _int(Object? raw) => switch (raw) {
  final num n => n.toInt(),
  final String s => int.tryParse(s) ?? 0,
  _ => 0,
};

String _uptime(int seconds) {
  if (seconds <= 0) return '';
  final d = Duration(seconds: seconds);
  final parts = <String>[];
  if (d.inDays > 0) parts.add('${d.inDays}d');
  if (d.inHours.remainder(24) > 0) parts.add('${d.inHours.remainder(24)}h');
  parts.add('${d.inMinutes.remainder(60)}m');
  return parts.join(' ');
}

String signalQualityText(BuildContext context, SignalQuality quality) =>
    switch (quality) {
      SignalQuality.excellent => context.l10n.deviceQualityExcellent,
      SignalQuality.good => context.l10n.deviceQualityGood,
      SignalQuality.fair => context.l10n.deviceQualityFair,
      SignalQuality.poor => context.l10n.deviceQualityPoor,
      SignalQuality.unknown => context.l10n.deviceQualityUnknown,
    };
