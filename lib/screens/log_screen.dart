import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:luci_mobile/l10n/failure_text.dart';
import 'package:luci_mobile/widgets/luci_loading_states.dart';
import 'package:luci_mobile/design/luci_design_system.dart';
import 'package:luci_mobile/l10n/luci_localizations.dart';
import 'package:luci_mobile/screens/diagnostics_screen.dart';
import 'package:luci_mobile/services/diagnostics_service.dart';
import 'package:luci_mobile/state/app_state_provider.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';

enum _LogSource { system, kernel }

/// The text a row renders, and therefore the text hits are measured against.
///
/// Highlight offsets are indices into this string, so the scan and the widget
/// have to agree on which of `message` and `raw` is the one on screen.
String _displayedText(LogEntry entry) => entry.message ?? entry.raw;

/// One case-insensitive occurrence of the filter needle inside a line.
class _Hit {
  const _Hit({required this.start, required this.end, required this.ordinal});

  final int start;
  final int end;

  /// Position in the newest-to-oldest walk that navigation follows.
  final int ordinal;
}

/// Every hit of the current needle across the whole log.
class _Scan {
  const _Scan({
    required this.byEntry,
    required this.rowOf,
    required this.total,
  });

  /// Hit ranges per entry index, newest entry first.
  final Map<int, List<_Hit>> byEntry;

  /// `rowOf[ordinal]` is the entry index holding that hit.
  final List<int> rowOf;

  final int total;

  static const _Scan none = _Scan(byEntry: {}, rowOf: [], total: 0);
}

/// The router's system and kernel logs.
class LogScreen extends ConsumerStatefulWidget {
  const LogScreen({super.key});

  @override
  ConsumerState<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends ConsumerState<LogScreen> {
  _LogSource _source = _LogSource.system;
  final _filter = TextEditingController();
  final _scroll = ScrollController();
  bool _loading = false;

  /// Kept as the error, not as a sentence: the wording is looked up when
  /// it is shown, so it is in the user's language.
  Object? _error;
  List<LogEntry> _entries = const [];

  /// One key per rendered row, by entry index, so a jump can find its box.
  final Map<int, GlobalKey> _rowKeys = <int, GlobalKey>{};

  /// Which hit the counter sits on. Zero is the newest matching line: that is
  /// where the viewport rests, and on a live router the newest occurrence of
  /// a fault is the one worth reading first.
  int _currentHit = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _filter.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider);
    final service = ref.read(diagnosticsServiceProvider);
    if (session == null || service == null) return;

    setState(() {
      _loading = true;
      _error = null;
      _currentHit = 0;
    });
    try {
      final result = _source == _LogSource.system
          ? await service.systemLog(session)
          : await service.kernelLog(session);
      if (!mounted) return;
      setState(() {
        _entries = LogEntry.parseAll(result.output);
        // A reload can come back shorter; drop the keys of rows that are gone
        // so the map cannot creep upwards over a long session of reloading.
        _rowKeys.removeWhere((index, _) => index >= _entries.length);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _entries = const [];
        // Saying "no log entries" when the read failed would suggest the
        // router had nothing to report, which is the opposite of the truth.
        _error = e;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Case-insensitive hits of [needle], newest entry first.
  ///
  /// Recomputed on every frame that carries a needle. The log is capped at a
  /// couple of hundred short lines, so this is cheaper than keeping a cache
  /// honest across reloads, source switches and keystrokes.
  _Scan _scan(String needle) {
    if (needle.isEmpty) return _Scan.none;
    // Folding happens inside the regex engine rather than against a
    // lowercased copy: case folding can change a line's length, and the
    // offsets below index into the original.
    final pattern = RegExp(RegExp.escape(needle), caseSensitive: false);
    final byEntry = <int, List<_Hit>>{};
    final rowOf = <int>[];
    for (var i = _entries.length - 1; i >= 0; i--) {
      final hits = <_Hit>[];
      for (final m in pattern.allMatches(_displayedText(_entries[i]))) {
        hits.add(_Hit(start: m.start, end: m.end, ordinal: rowOf.length));
        rowOf.add(i);
      }
      if (hits.isNotEmpty) byEntry[i] = hits;
    }
    return _Scan(byEntry: byEntry, rowOf: rowOf, total: rowOf.length);
  }

  void _onFilterChanged(String _) {
    setState(() => _currentHit = 0);
    final scan = _scan(_filter.text.trim());
    if (scan.total == 0) return;
    // Land on the newest match, so the counter and the highlighted line agree
    // instead of the counter claiming a row the user cannot see.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _revealRow(scan.rowOf.first);
    });
  }

  /// Moves one hit along the walk; positive goes towards older lines.
  void _step(int delta) {
    final scan = _scan(_filter.text.trim());
    final next = _currentHit + delta;
    if (next < 0 || next >= scan.total || next == _currentHit) return;
    setState(() => _currentHit = next);
    _revealRow(scan.rowOf[next]);
  }

  /// Brings [entryIndex]'s row into view and centres it.
  void _revealRow(int entryIndex) {
    // A row far from the viewport has never been built, so there is nothing to
    // measure yet: nudge the viewport into its build range first.
    if (_rowKeys[entryIndex]?.currentContext == null) {
      _estimateScroll(entryIndex);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _rowKeys[entryIndex]?.currentContext;
      if (target == null) return;
      // Centred rather than merely "on screen": a wrapped log line can be
      // taller than the space left over, and being nudged into view by a few
      // pixels is no help when stepping through hits by hand.
      Scrollable.ensureVisible(
        target,
        alignment: 0.5,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        duration: LuciAnimations.standard,
        curve: Curves.easeOut,
      );
    });
  }

  /// Moves the viewport roughly into the build range of [entryIndex].
  ///
  /// `ListView.builder` mounts only what is near the viewport, so a jump to a
  /// distant hit has no box to measure. The estimate is deliberately crude;
  /// `_revealRow` measures the row for real on the following frame.
  void _estimateScroll(int entryIndex) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final newest = _entries.length - 1;
    if (newest <= 0 || !position.hasContentDimensions) return;
    // `reverse: true` lays the newest row out at offset 0 and grows the offset
    // towards older rows, so a row's share of the scroll extent follows from
    // how far back it sits in the log.
    final share = (newest - entryIndex) / newest;
    final target = position.maxScrollExtent * share;
    position.jumpTo(
      target
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scan = _scan(_filter.text.trim());

    return Scaffold(
      appBar: LuciAppBar(
        title: l10n.systemLog,
        showBack: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: l10n.copy,
            onPressed: _entries.isEmpty
                ? null
                : () => copyToClipboard(
                    context,
                    _entries.map((e) => e.raw).join('\n'),
                    label: l10n.systemLog,
                  ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.retry,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(LuciSpacing.md),
            child: SegmentedButton<_LogSource>(
              segments: [
                ButtonSegment(
                  value: _LogSource.system,
                  label: Text(l10n.systemLog),
                ),
                ButtonSegment(
                  value: _LogSource.kernel,
                  label: Text(l10n.kernelLog),
                ),
              ],
              selected: {_source},
              onSelectionChanged: _loading
                  ? null
                  : (s) {
                      setState(() => _source = s.first);
                      _load();
                    },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: LuciSpacing.md),
            child: TextField(
              controller: _filter,
              onChanged: _onFilterChanged,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: l10n.filterLog,
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: _filter.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(_filter.clear),
                      ),
                suffix: _hitControls(context, scan),
              ),
            ),
          ),
          const SizedBox(height: LuciSpacing.sm),
          Expanded(child: _body(context, scan)),
        ],
      ),
    );
  }

  /// The hit counter and its two jumps, shown beside the filter.
  Widget? _hitControls(BuildContext context, _Scan scan) {
    final l10n = context.l10n;
    if (_filter.text.trim().isEmpty) return null;
    final muted = TextStyle(
      fontSize: 12,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );

    if (scan.total == 0) {
      return Padding(
        padding: const EdgeInsets.only(right: LuciSpacing.sm),
        child: Text(l10n.logNoMatches, style: muted),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The arrows name the direction on screen rather than the order of
        // the internal walk: up is a line further back in time, down is a
        // later one.
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_up),
          iconSize: 20,
          tooltip: l10n.logOlderMatch,
          onPressed: _currentHit < scan.total - 1 ? () => _step(1) : null,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        ),
        Tooltip(
          message: l10n.logMatches(_currentHit + 1, scan.total),
          child: Text('${_currentHit + 1}/${scan.total}', style: muted),
        ),
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          iconSize: 20,
          tooltip: l10n.logNewerMatch,
          onPressed: _currentHit > 0 ? () => _step(-1) : null,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, _Scan scan) {
    final l10n = context.l10n;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return LuciMessageState(
        scrollable: false,
        icon: Icons.error_outline,
        title: l10n.logUnavailable,
        message: apiErrorText(context, _error!),
        action: l10n.retry,
        onAction: _load,
      );
    }
    if (_entries.isEmpty) {
      return LuciMessageState(
        scrollable: false,
        icon: Icons.article_outlined,
        message: l10n.logEmpty,
      );
    }

    // There is no "nothing matched" state any more. Every line stays on
    // screen because a hit rarely explains itself: it is the lines around it
    // that say what led to it.
    return ListView.builder(
      controller: _scroll,
      // Newest last is how logs read; start the user at the bottom.
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: LuciSpacing.md),
      itemCount: _entries.length,
      itemBuilder: (context, i) {
        final index = _entries.length - 1 - i;
        return _LogRow(
          key: _rowKeys.putIfAbsent(index, () => GlobalKey()),
          entry: _entries[index],
          hits: scan.byEntry[index] ?? const <_Hit>[],
          currentHit: _currentHit,
        );
      },
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({
    super.key,
    required this.entry,
    required this.hits,
    required this.currentHit,
  });

  final LogEntry entry;

  /// Hit ranges within the rendered text; empty when there is no needle.
  final List<_Hit> hits;

  /// The selected hit's ordinal across the whole log.
  final int currentHit;

  static const TextStyle _log = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    height: 1.35,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = entry.isProblem
        ? scheme.error
        : entry.isWarning
        ? scheme.tertiary
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A thin severity rail rather than a coloured row: errors need to
          // be findable while scrolling without the log turning into stripes.
          Container(
            width: 3,
            height: 18,
            margin: const EdgeInsets.only(top: 2, right: LuciSpacing.sm),
            decoration: BoxDecoration(
              color: accent ?? Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.timestamp != null)
                  Text(
                    '${entry.timestamp}  ${entry.facility}.${entry.level}',
                    style: TextStyle(
                      fontSize: 11,
                      color: accent ?? scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                SelectableText.rich(_message(scheme), style: _log),
              ],
            ),
          ),
        ],
      ),
    );
  }

  InlineSpan _message(ColorScheme scheme) {
    final text = _displayedText(entry);
    if (hits.isEmpty) return TextSpan(text: text);

    final spans = <InlineSpan>[];
    var at = 0;
    for (final hit in hits) {
      if (hit.start > at) {
        spans.add(TextSpan(text: text.substring(at, hit.start)));
      }
      final isCurrent = hit.ordinal == currentHit;
      spans.add(
        TextSpan(
          text: text.substring(hit.start, hit.end),
          style: TextStyle(
            // Two strengths, because one colour leaves the selected hit no
            // easier to pick out of a long run of identical highlights.
            backgroundColor: isCurrent
                ? scheme.primary
                : scheme.primary.withValues(alpha: 0.28),
            color: isCurrent ? scheme.onPrimary : null,
            fontWeight: isCurrent ? FontWeight.bold : null,
          ),
        ),
      );
      at = hit.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return TextSpan(children: spans);
  }
}
