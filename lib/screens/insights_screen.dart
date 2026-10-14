import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:router_pilot/design/luci_design_system.dart';
import 'package:router_pilot/l10n/luci_localizations.dart';
import 'package:router_pilot/screens/diagnostics_screen.dart';
import 'package:router_pilot/screens/traffic_screen.dart';
import 'package:router_pilot/screens/event_feed_screen.dart';
import 'package:router_pilot/screens/log_screen.dart';
import 'package:router_pilot/widgets/luci_app_bar.dart';
import 'package:router_pilot/widgets/luci_hub_tile.dart';

/// Read-only visibility into what the router is doing: logs, diagnostics and
/// activity.
class InsightsScreen extends ConsumerWidget {
  const InsightsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: LuciAppBar(title: l10n.insights),
      body: ListView(
        children: [
          LuciSectionHeader(l10n.insights),
          LuciHubSection(
            tiles: [
              LuciHubTile(
                icon: Icons.history,
                title: l10n.activity,
                subtitle: l10n.activityHubSubtitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const EventFeedScreen(),
                  ),
                ),
              ),
              LuciHubTile(
                icon: Icons.article_outlined,
                title: l10n.systemLog,
                subtitle: l10n.logHubSubtitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const LogScreen()),
                ),
              ),
              LuciHubTile(
                icon: Icons.data_usage,
                title: l10n.trafficHistory,
                subtitle: l10n.trafficHistorySubtitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const TrafficScreen(),
                  ),
                ),
              ),
              LuciHubTile(
                icon: Icons.network_ping,
                title: l10n.diagnostics,
                subtitle: l10n.diagnosticsHubSubtitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DiagnosticsScreen(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: LuciSpacing.lg),
        ],
      ),
    );
  }
}
