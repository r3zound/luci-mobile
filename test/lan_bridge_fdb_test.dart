import 'package:flutter_test/flutter_test.dart';
import 'package:router_pilot/services/api_service.dart';

/// The forwarding table exactly as a router prints it, captured over
/// `/usr/libexec/lan-fdb` on a ZTE V50.
///
/// Both kinds of line matter: the two learned clients, and the bridge's own
/// `permanent` / `self` addresses that must not be mistaken for one.
const String _captured = '''
02:50:2e:70:77:04 dev rndis0 master br-lan 
02:50:2e:70:77:03 dev rndis0 vlan 1 master br-lan permanent
02:50:2e:70:77:03 dev rndis0 master br-lan permanent
33:33:00:00:00:01 dev rndis0 self permanent
01:00:5e:00:00:01 dev rndis0 self permanent
6e:20:97:b4:76:3a dev wlan0 master br-lan 
5c:7d:ae:3b:d6:08 dev wlan0 vlan 1 master br-lan permanent
5c:7d:ae:3b:d6:08 dev wlan0 master br-lan permanent
33:33:00:00:00:02 dev wlan0 self permanent
''';

void main() {
  group('parseLanBridgeFdb', () {
    test('keeps learned clients and normalizes their addresses', () {
      expect(parseLanBridgeFdb(_captured), {
        '02:50:2E:70:77:04': 'rndis0',
        '6E:20:97:B4:76:3A': 'wlan0',
      });
    });

    test('skips the entries that belong to the bridge itself', () {
      // The port MAC and the multicast entries are permanent or self, and the
      // router would otherwise be typed as one of its own clients.
      final table = parseLanBridgeFdb(_captured);
      expect(table.containsKey('02:50:2E:70:77:03'), isFalse);
      expect(table.containsKey('5C:7D:AE:3B:D6:08'), isFalse);
      expect(table.containsKey('33:33:00:00:00:01'), isFalse);
      expect(table.length, 2);
    });

    test('returns nothing for empty or unparseable output', () {
      // A router that answers with an empty body, or with something that is not
      // a forwarding table at all, must not produce a half-read map.
      expect(parseLanBridgeFdb(''), isEmpty);
      expect(parseLanBridgeFdb('\n  \n'), isEmpty);
      expect(parseLanBridgeFdb('not a forwarding table'), isEmpty);
      expect(
        parseLanBridgeFdb('zz:zz:zz:zz:zz:zz dev wlan0 master br-lan'),
        isEmpty,
      );
    });

    test('finds a client on a wired port', () {
      // The port in the middle is the whole point: it is what turns "not on a
      // radio" into "wired" in the caller.
      expect(parseLanBridgeFdb('aa:bb:cc:dd:ee:ff dev eth0 master br-lan'), {
        'AA:BB:CC:DD:EE:FF': 'eth0',
      });
    });
  });
}
