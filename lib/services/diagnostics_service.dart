import 'package:flutter/foundation.dart';

import 'package:router_pilot/services/api_service.dart';
import 'package:router_pilot/services/interfaces/api_service_interface.dart';
import 'package:router_pilot/state/router_session.dart';

/// A network tool the router can run on the user's behalf.
///
/// Each tool carries more than one path because distributions disagree about
/// where these live: a minimal image has BusyBox's `/bin/traceroute` and no
/// `/usr/bin` one at all, while a full one ships the real traceroute under
/// `/usr/bin`. Stock LuCI grants both spellings for exactly that reason.
enum DiagnosticTool {
  ping(['/bin/ping', '/usr/bin/ping']),
  traceroute(['/usr/bin/traceroute', '/bin/traceroute']),
  nslookup(['/usr/bin/nslookup', '/bin/nslookup']);

  const DiagnosticTool(this.paths);

  /// Absolute paths to try in order, because rpcd's `file.exec` resolves
  /// nothing and an absent path answers NOT_FOUND rather than running anything.
  final List<String> paths;
}

@immutable
class DiagnosticResult {
  const DiagnosticResult({
    required this.output,
    required this.exitCode,
    this.stderr,
  });

  final String output;
  final int exitCode;
  final String? stderr;

  bool get succeeded => exitCode == 0;
}

/// Runs the router's own network tools and reads its logs.
class DiagnosticsService {
  const DiagnosticsService(this._api);

  final IApiService _api;

  /// Arguments for [tool] against [target].
  ///
  /// Counts and deadlines are bounded on purpose: `file.exec` is synchronous
  /// and rpcd times it out, so an unbounded `ping` would hang the call and
  /// return nothing at all.
  static List<String> argsFor(DiagnosticTool tool, String target) =>
      switch (tool) {
        DiagnosticTool.ping => ['-c', '5', '-W', '2', target],
        DiagnosticTool.traceroute => [
          '-n',
          '-w',
          '1',
          '-q',
          '1',
          '-m',
          '15',
          target,
        ],
        DiagnosticTool.nslookup => [target],
      };

  Future<DiagnosticResult> run(
    RouterSession session,
    DiagnosticTool tool,
    String target,
  ) async {
    final args = argsFor(tool, target);
    RpcException? refused;
    for (final path in tool.paths) {
      try {
        return await _exec(session, path, args);
      } on RpcException catch (error) {
        // NOT_FOUND means that name is not installed here and
        // PERMISSION_DENIED means the router's ACL lists the other spelling;
        // both are worth trying the next candidate for. The last one is what
        // the caller hears about if they all fail.
        refused = error;
      }
    }
    throw refused!;
  }

  /// Truncating `dmesg` wrapper, deployed on routers whose kernel ring buffer
  /// outgrows what `file.exec` will carry.
  ///
  /// rpcd answers with a bare `UNKNOWN_ERROR` and no payload at all once a
  /// command's output outgrows its buffer, which on a long-running embedded
  /// router happens as soon as the kernel has been logging debug spam for a
  /// few days. `/bin/dmesg` can be close to a megabyte by then; the last 200
  /// lines are what a log view shows anyway.
  static const String _kernelLogWrapper = '/usr/libexec/dmesg-wrap1';

  /// Stock OpenWrt does not grant `/sbin/logread`; it grants this instead.
  ///
  /// The wrapper exists because `logread` can deadlock when it is called from
  /// inside rpcd's own ubus call - which is the very situation `file.exec`
  /// creates. It ignores its arguments and hands back the whole log, so it is
  /// the fallback rather than the first choice.
  static const String _syslogWrapper = '/usr/libexec/syslog-wrapper';

  /// Reads the kernel ring buffer.
  ///
  /// Three paths, most-truncated first. A router that has never been given the
  /// wrappers still answers to `dmesg`, and stock OpenWrt grants that only as
  /// `/bin/dmesg -r` - the `-r` is part of its ACL entry, so it has to be sent.
  Future<DiagnosticResult> kernelLog(RouterSession session) async {
    try {
      return await _exec(session, _kernelLogWrapper, const []);
    } on RpcException {
      try {
        return await _exec(session, '/bin/dmesg', const ['-r']);
      } on RpcException {
        return _exec(session, '/bin/dmesg', const []);
      }
    }
  }

  /// Reads the system log.
  ///
  /// `logread` is asked for a bounded number of lines because it can be; the
  /// stock wrapper cannot be, so it is only used when `logread` is refused.
  /// That is the common case on a router nobody has prepared for this app.
  ///
  /// `logread` talks to ubus itself, and on some builds doing that from inside
  /// an `file.exec` — which is already a ubus call — deadlocks until rpcd
  /// times out. Callers must be ready for this to fail and say so rather than
  /// showing an empty log as if the router had nothing to report.
  Future<DiagnosticResult> systemLog(
    RouterSession session, {
    int lines = 200,
  }) async {
    try {
      return await _exec(session, '/sbin/logread', ['-l', '$lines']);
    } on RpcException {
      return _exec(session, _syslogWrapper, const []);
    }
  }

  /// Runs [command] and returns whatever it printed, whatever it exited with.
  ///
  /// Deliberately not `systemExec`, which throws on a non-zero exit: here a
  /// non-zero exit *is* the result. `ping` exits 1 for "100% packet loss"
  /// and `nslookup` for NXDOMAIN, and that output is exactly what the user
  /// ran the tool to see.
  Future<DiagnosticResult> _exec(
    RouterSession session,
    String command,
    List<String> params,
  ) async {
    final raw = await _api.call(
      session.ipAddress,
      session.sysauth,
      session.useHttps,
      object: 'file',
      method: 'exec',
      // Never add an `env` key here. rpcd rejects a `file.exec` request that
      // carries one with PERMISSION_DENIED (code 6) whatever the ACL says, and
      // the call still works a second later without it - which makes it look
      // exactly like a permissions problem and sends you off to re-check an
      // ACL that was never wrong.
      params: {'command': command, 'params': params},
    );
    // `call` has already turned a non-zero ubus status into an RpcException
    // with whatever detail the router sent; only the shape is checked here.
    if (raw is! List || raw.isEmpty) {
      throw const RpcException(
        object: 'file',
        method: 'exec',
        detail: 'invalid response',
      );
    }
    return _parseExec(raw);
  }

  static DiagnosticResult _parseExec(List<dynamic> raw) {
    // The envelope shape varies between rpcd builds; parse defensively.
    if (raw.length < 2 || raw[1] is! Map) {
      return const DiagnosticResult(output: '', exitCode: -1);
    }
    final data = raw[1] as Map;
    final code = data['code'];
    return DiagnosticResult(
      output: data['stdout']?.toString() ?? '',
      // Unknown, not zero: a body carrying no exit status is a run we
      // cannot vouch for, and calling it a success turns "the log could
      // not be read" into "the log is empty".
      exitCode: code is num ? code.toInt() : -1,
      stderr: data['stderr']?.toString(),
    );
  }
}

/// One parsed syslog line.
@immutable
class LogEntry {
  const LogEntry({
    required this.raw,
    this.timestamp,
    this.facility,
    this.level,
    this.message,
  });

  final String raw;
  final String? timestamp;
  final String? facility;
  final String? level;
  final String? message;

  /// True for anything the user would want to notice.
  bool get isProblem {
    final l = level?.toLowerCase();
    return l == 'err' || l == 'crit' || l == 'alert' || l == 'emerg';
  }

  bool get isWarning => level?.toLowerCase() == 'warn';

  /// Parses `Sun Sep 20 08:53:53 2026 daemon.notice netifd: ...`.
  ///
  /// Anything that does not match is kept verbatim rather than dropped: a log
  /// viewer that silently hides lines it cannot parse is worse than useless
  /// when you are chasing a problem.
  static LogEntry parse(String line) {
    final match = RegExp(
      r'^(\w{3}\s+\w{3}\s+\d+\s+[\d:]+\s+\d{4})\s+(\w+)\.(\w+)\s+(.*)$',
    ).firstMatch(line);
    if (match == null) return LogEntry(raw: line, message: line);
    return LogEntry(
      raw: line,
      timestamp: match.group(1),
      facility: match.group(2),
      level: match.group(3),
      message: match.group(4),
    );
  }

  static List<LogEntry> parseAll(String output) => [
    for (final line in output.split('\n'))
      if (line.trim().isNotEmpty) parse(line),
  ];
}
