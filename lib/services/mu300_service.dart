import 'package:flutter/foundation.dart';

import 'package:luci_mobile/services/interfaces/api_service_interface.dart';
import 'package:luci_mobile/state/router_session.dart';
import 'package:luci_mobile/utils/logger.dart';

/// Reads the vendor ubus object `mu300dash`.
///
/// ZTE's MU300 firmware exposes a `mu300dash` object that no stock OpenWrt
/// build has, and it is the only place the cellular radio is described at
/// all: band, ARFCN, PCI, RSRP/RSRQ/SINR, gNB, cell id, MCS and BLER. Stock
/// `iwinfo`/`system.info` can say the radio is up; only this can say *which
/// 5G cell, and how good the link is*.
///
/// Every getter returns `null` instead of throwing. The object is absent on
/// ordinary routers and on the vendor's own web UI sessions, and a screen that
/// cannot find it should say so once - not fail to open.
class Mu300Service {
  const Mu300Service(this._api);

  final IApiService _api;

  static const String object = 'mu300dash';

  /// Whether the router answers this object at all.
  Future<bool> isAvailable(RouterSession session) async =>
      await sysinfo(session) != null;

  /// The combined snapshot the firmware's own dashboard reads.
  ///
  /// `mu300dash.status` is `{info, cell, sig, cell_age, sig_age, refreshing}`:
  /// the vendor caches each half separately because they refresh at different
  /// rates, and `*_age` says how stale each one is. One call therefore beats
  /// three, and unlike [signal] it never returns a half-built object while the
  /// modem is mid-poll - it serves the previous reading instead.
  ///
  /// This is the primary read for the device screen; [sysinfo], [signal] and
  /// [cell] exist for when only one half is wanted.
  Future<Map<String, dynamic>?> status(RouterSession session) =>
      _get(session, 'status');

  /// Device overview: firmware, uptime, cpu, memory, storage, temperatures,
  /// per-interface counters, WAN, WiFi.
  Future<Map<String, dynamic>?> sysinfo(RouterSession session) =>
      _get(session, 'sysinfo');

  /// Registration state: serving cell, TAC, cell id, access technology.
  Future<Map<String, dynamic>?> cell(RouterSession session) =>
      _get(session, 'status').then((d) => _sub(d, 'cell'));

  /// Cellular registration and radio measurements.
  ///
  /// Returns `null` when the modem is between polls: `mu300dash.signal`
  /// answers `{"error": ...}` rather than a ubus status while it re-reads the
  /// AT state, and treating that as "no signal" would make the reading flicker
  /// to zero for no reason the user can act on.
  Future<Map<String, dynamic>?> signal(RouterSession session) async {
    final data = await _get(session, 'signal');
    if (data == null || data.containsKey('error')) return null;
    return data;
  }

  /// Battery, charger and the three power profiles.
  Future<Map<String, dynamic>?> power(RouterSession session) =>
      _get(session, 'power_get');

  /// Band locking state and what the modem supports.
  Future<Map<String, dynamic>?> bands(
    RouterSession session, {
    String fresh = '0',
  }) =>
      _get(session, 'lock_get', {'fresh': fresh});

  /// USB networking role.
  Future<Map<String, dynamic>?> usb(RouterSession session) =>
      _get(session, 'usb_get');

  /// TTL rewriting state.
  Future<Map<String, dynamic>?> ttl(RouterSession session) =>
      _get(session, 'ttl_get');

  /// System and LuCI language.
  Future<Map<String, dynamic>?> language(RouterSession session) =>
      _get(session, 'lang_get');

  /// Messages written by the firmware's own agent.
  Future<Map<String, dynamic>?> messages(RouterSession session) =>
      _get(session, 'sms_list', {'page': '1'});

  /// Runs an AT command against the baseband and returns its reply.
  ///
  /// Only ever called on an explicit user action: this is a raw escape hatch
  /// into the modem, and some AT commands change radio state.
  ///
  /// The parameter is `cmd`, not `command` - that is what
  /// `ubus -v list mu300dash` declares, and a wrong key is rejected silently
  /// by rpcd rather than loudly.
  Future<String> at(RouterSession session, String command) async {
    final raw = await _api.call(
      session.ipAddress,
      session.sysauth,
      session.useHttps,
      object: object,
      method: 'at',
      params: {'cmd': command},
    );
    if (raw is List && raw.length > 1 && raw[0] == 0) {
      final data = raw[1];
      if (data is Map) {
        return (data['response'] ?? data['stdout'] ?? data['data'] ?? '')
            .toString();
      }
    }
    return '';
  }

  /// The band sets this modem can actually be locked to.
  ///
  /// Read from `lock_get`'s `caps`, never hardcoded: the vendor's own header
  /// records that an earlier decoder reported n79, which this RF chain cannot
  /// use, and locking it wedged the CP until the firmware was power-cycled.
  /// Anything offered in the UI has to come from here.
  static List<int> supportedBands(
    Map<String, dynamic>? lock,
    String kind,
  ) {
    final caps = lock?['caps'];
    if (caps is! Map) return const [];
    final raw = caps[kind];
    if (raw is! String) return const [];
    return raw
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .where((b) => b > 0)
        .toList()
      ..sort();
  }

  /// Locks or unlocks bands.
  ///
  /// `kind` is `nr` or `lte`; `bands` is a comma-separated list, or `''` to
  /// hand the modem back its own automatic behaviour. Only the adapter's
  /// codec can send these, so the app sends band *numbers* and lets
  /// `/usr/libexec/unisoc-modem/lock` translate - the app must never try to
  /// build the modem's `AT+SPLBAND` bit masks itself.
  ///
  /// **The call returns before anything happens.** `m_lock_set` replies
  /// `{"ok":1,"started":1}` and runs `setsid lock apply ... &` detached,
  /// because applying does `AT+SFUN=5` then `AT+SFUN=4` and takes half a
  /// minute - far longer than a ubus request may hold. So [LockApply] reports
  /// *accepted*, never *finished*, and the screen has to re-read the lock
  /// state afterwards instead of trusting its own optimistic update.
  Future<LockApply> setBandLock(
    RouterSession session, {
    required String kind,
    required String bands,
  }) =>
      _write(session, 'lock_set', {'kind': kind, 'val': bands});

  /// Switches the network mode: `auto`, `4g`, `sa` or `nsa`.
  ///
  /// Same detached-apply semantics as [setBandLock], same half-minute outage.
  Future<LockApply> setNetworkMode(
    RouterSession session,
    String mode,
  ) =>
      _write(session, 'lock_set', {'kind': 'mode', 'val': mode});

  /// Runs one of the firmware's control actions.
  ///
  /// `op` is one of `radio`, `wifi`, `data`, `vpn`, `modem-reset`, `reboot`;
  /// the allowed `arg` per op is narrow - `on`/`off` for radio and wifi,
  /// `up`/`down` for data, `start`/`stop` for vpn, and nothing at all for the
  /// two resets. Passing anything else is refused by the router.
  ///
  /// `radio`, `modem-reset`, `reboot` and `vpn` also detach, so the same
  /// "accepted, not finished" rule applies. `radio` and `modem-reset` answer
  /// `{"ok":0,"busy":1}` while the dial script or the watchdog holds the radio
  /// lock - a retry, not a failure.
  Future<LockApply> act(
    RouterSession session, {
    required String op,
    String arg = '',
  }) =>
      _write(session, 'act', {'op': op, 'arg': arg});

  /// Turns TTL rewriting on or off, or changes the value it rewrites to.
  ///
  /// `value` is `off` or a number in 1-255; the router rejects anything else.
  Future<LockApply> setTtl(RouterSession session, String value) =>
      _write(session, 'ttl_set', {'value': value});

  /// A write that reports whether the router accepted it.
  ///
  /// ubus answers a void method with `[0]`, and rpcd turns a throwing method
  /// into an exception rather than a non-zero status, so the only honest
  /// success signal is "the call returned without throwing".
  Future<LockApply> _write(
    RouterSession session,
    String method,
    Map<String, dynamic> params,
  ) async {
    try {
      final raw = await _api.call(
        session.ipAddress,
        session.sysauth,
        session.useHttps,
        object: object,
        method: method,
        params: params,
      );
      if (raw is! List || raw.length < 2 || raw[0] != 0) {
        return const LockApply.rejected();
      }
      final data = raw[1];
      if (data is! Map) return const LockApply.rejected();

      // The vendor's writes answer `{"ok":0,...}` for a refusal rather than
      // throwing, and `busy:1` is a retry rather than a failure - collapsing
      // those two would tell the user their radio is broken when the dial
      // script merely holds the lock for a moment.
      if (data['ok'] == 0) {
        final busy = data['busy'] == 1;
        final reason = (data['error'] ?? data['reason'] ?? '').toString();
        Logger.debug('$object.$method refused: $data');
        return LockApply(
          accepted: false,
          busy: busy,
          message: reason.isEmpty ? null : reason,
        );
      }
      return LockApply(
        accepted: true,
        // `started`/`queued` are only present on the detached ones, but they
        // are the whole point: without them the caller cannot tell an
        // instantaneous write from one that is about to drop the connection.
        detached: data['started'] == 1,
        queued: data['queued'] == 1,
      );
    } catch (error) {
      Logger.debug('$object.$method failed: $error');
      return LockApply(accepted: false, message: error.toString());
    }
  }

  /// Pulls one nested object out of a `status` reply.
  static Map<String, dynamic>? _sub(
    Map<String, dynamic>? source,
    String key,
  ) {
    if (source == null) return null;
    final value = source[key];
    return value is Map<String, dynamic> ? value : null;
  }

  /// A read that never throws.
  ///
  /// A vendor object can be absent, ACL-denied, or mid-refresh; none of those
  /// is worth an error screen, so each becomes `null` and the caller decides
  /// what to omit.
  Future<Map<String, dynamic>?> _get(
    RouterSession session,
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    try {
      final raw = await _api.call(
        session.ipAddress,
        session.sysauth,
        session.useHttps,
        object: object,
        method: method,
        params: params,
      );
      if (raw is List && raw.length > 1 && raw[0] == 0) {
        final data = raw[1];
        if (data is Map<String, dynamic>) return data;
      }
      Logger.debug('$object.$method returned nothing usable');
    } catch (error) {
      Logger.debug('$object.$method skipped: $error');
    }
    return null;
  }
}

/// What happened when a control action was sent - and, more importantly, what
/// did *not* happen yet.
///
/// Every radio-touching method on this object answers `{"ok":1,"started":1}`
/// and forks the real work into the background, because the work includes an
/// `AT+SFUN=5` / `AT+SFUN=4` cycle lasting about half a minute. A screen that
/// treated [accepted] as "done" would paint the new band and then watch it
/// silently snap back when the re-read lands. So [detached] exists purely to
/// let the UI say "reconnecting" and then go and look.
@immutable
class LockApply {
  const LockApply({
    required this.accepted,
    this.detached = false,
    this.queued = false,
    this.busy = false,
    this.message,
  });

  const LockApply.rejected() : this(accepted: false);

  /// The router took the request. Says nothing about the outcome.
  final bool accepted;

  /// The work is running detached; cellular will drop while it does.
  final bool detached;

  /// Another apply is still running, so this one is waiting its turn.
  final bool queued;

  /// The radio lock is held by the dial script or watchdog. Retry shortly.
  final bool busy;

  /// The router's own words, when it had any.
  final String? message;
}

/// How good the current radio link is, judged from the modem's own numbers.
///
/// RSRP/RSRQ/SINR are three different questions - how loud, how clean, how far
/// above the noise floor - and no single one of them decides. [grade] scores
/// all three and takes the weakest, so a strong RSRP carrying a terrible SINR
/// cannot report itself as 'excellent'.
///
/// The thresholds are the ones field engineers quote for NR; they are the
/// reason the result is a four-step ladder rather than a 0-100 bar.
enum SignalQuality { excellent, good, fair, poor, unknown }

/// Scores the `sig` block of `mu300dash.signal` / `mu300dash.status`.
@immutable
class SignalReading {
  const SignalReading(this.label, this.value, {this.unit});

  final String label;
  final String value;
  final String? unit;

  /// Builds a reading, or `null` when the router did not report the field.
  ///
  /// Skipping absent fields beats showing an em dash everywhere: an empty row
  /// tells the reader nothing, a missing one tells them the modem does not
  /// report it.
  static SignalReading? tryBuild(
    Map<String, dynamic>? source,
    String key,
    String label, {
    String? unit,
  }) {
    if (source == null) return null;
    final raw = source[key];
    if (raw == null) return null;
    final text = raw is num
        ? (raw % 1 == 0 ? raw.toInt().toString() : raw.toString())
        : raw.toString();
    if (text.isEmpty || text == 'null') return null;
    return SignalReading(label, text, unit: unit);
  }

  /// Reduces RSRP/RSRQ/SINR to one rung of the ladder.
  ///
  /// Returns [SignalQuality.unknown] when the modem reported none of the
  /// three, which is what an older LTE modem looks like - not zero signal,
  /// just a different way of saying it.
  static SignalQuality grade(Map<String, dynamic>? sig) {
    if (sig == null) return SignalQuality.unknown;
    final rsrp = _asDouble(sig['rsrp']);
    final rsrq = _asDouble(sig['rsrq']);
    final sinr = _asDouble(sig['sinr']);
    if (rsrp == null && rsrq == null && sinr == null) {
      return SignalQuality.unknown;
    }

    // Each metric maps to 0..3 where 3 is best; the link takes the minimum.
    var score = 3;
    if (rsrp != null) {
      final r = switch (rsrp) {
        >= -80 => 3,
        >= -90 => 2,
        >= -100 => 1,
        _ => 0,
      };
      if (r < score) score = r;
    }
    if (rsrq != null) {
      final r = switch (rsrq) {
        >= -10 => 3,
        >= -15 => 2,
        >= -20 => 1,
        _ => 0,
      };
      if (r < score) score = r;
    }
    if (sinr != null) {
      final r = switch (sinr) {
        >= 20 => 3,
        >= 13 => 2,
        >= 0 => 1,
        _ => 0,
      };
      if (r < score) score = r;
    }
    return switch (score) {
      3 => SignalQuality.excellent,
      2 => SignalQuality.good,
      1 => SignalQuality.fair,
      _ => SignalQuality.poor,
    };
  }

  /// Vendor counters arrive as `int`, `double` or occasionally a quoted
  /// `"-83.9"`, so nothing here can assume a type.
  static double? _asDouble(Object? raw) => switch (raw) {
        final num n => n.toDouble(),
        final String s => double.tryParse(s),
        _ => null,
      };
}
