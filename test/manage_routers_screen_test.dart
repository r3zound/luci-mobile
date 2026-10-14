import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:router_pilot/main.dart';
import 'package:router_pilot/models/router.dart' as model;
import 'package:router_pilot/screens/manage_routers_screen.dart';
import 'package:router_pilot/services/mock_api_service.dart';
import 'package:router_pilot/services/mock_auth_service.dart';
import 'package:router_pilot/state/app_state.dart';

void main() {
  testWidgets('fallback removal requires confirmation', (tester) async {
    final state = _TestAppState(
      model.Router(
        id: 'router',
        ipAddress: '192.168.1.1',
        username: 'root',
        password: 'password',
        useHttps: false,
        alternateAddress: 'router.example.com',
        alternateUseHttps: true,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStateProvider.overrideWith((ref) => state)],
        child: const MaterialApp(home: ManageRoutersScreen()),
      ),
    );

    await tester.tap(find.byTooltip('Remove fallback address'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(state.updatedRouter, isNull);

    await tester.tap(find.byTooltip('Remove fallback address'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(state.updatedRouter?.hasFallback, isFalse);
  });
}

class _TestAppState extends AppState {
  _TestAppState(this.router)
    : super.forTesting(
        apiService: MockApiService(),
        authService: MockAuthService(),
      );

  final model.Router router;
  model.Router? updatedRouter;

  @override
  List<model.Router> get routers => [router];

  @override
  Future<void> updateRouter(model.Router router) async =>
      updatedRouter = router;
}
