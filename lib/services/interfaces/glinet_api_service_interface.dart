import 'package:router_pilot/models/glinet_data.dart';

abstract class IGlInetApiService {
  bool get isAuthenticated;

  Future<GlInetData?> fetchData(String host, String password, bool useHttps);

  void clearSession();
}
