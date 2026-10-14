import 'package:router_pilot/models/glinet_data.dart';
import 'package:router_pilot/services/interfaces/glinet_api_service_interface.dart';

class MockGlInetApiService implements IGlInetApiService {
  @override
  bool get isAuthenticated => false;

  @override
  Future<GlInetData?> fetchData(
    String host,
    String password,
    bool useHttps,
  ) async => null;

  @override
  void clearSession() {}
}
