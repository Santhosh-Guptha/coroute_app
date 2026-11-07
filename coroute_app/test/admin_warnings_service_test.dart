import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:coroute_app/data/services/admin_warnings_service.dart';
import 'package:coroute_app/data/services/api_client.dart';
import 'package:coroute_app/presentation/widgets/admin_warning_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AdminWarning.fromJson', () {
    test('valid warning parses; text cleaned and capped', () {
      final w = AdminWarning.fromJson({'id': 'AW-0123456789AB', 'message': ' Be\u0007  kind ', 'at': 1700000000000});
      expect(w, isNotNull);
      expect(w!.message, 'Be kind');
      expect(w.at, 1700000000000);
      final long = AdminWarning.fromJson({'id': 'AW-0123456789AB', 'message': 'x' * 400});
      expect(long!.message.length, AdminWarning.maxLength);
    });

    test('bad id, empty text or not a map: ignored', () {
      expect(AdminWarning.fromJson({'id': 'nope', 'message': 'hi'}), isNull);
      expect(AdminWarning.fromJson({'id': 'AW-0123456789AB', 'message': '   '}), isNull);
      expect(AdminWarning.fromJson('AW-0123456789AB'), isNull);
    });
  });

  group('AdminWarningsService', () {
    late List<http.Request> calls;
    late AdminWarningsService service;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      calls = [];
      final api = ApiClient(
        httpClient: MockClient((req) async {
          calls.add(req);
          return http.Response(jsonEncode({'ok': true}), 200);
        }),
        storage: const FlutterSecureStorage(),
      );
      service = AdminWarningsService(api, autoStart: false);
    });

    tearDown(() => service.dispose());

    test('oldest first; duplicates ignored; hide shows the next; acknowledge removes and posts', () async {
      const a = AdminWarning(id: 'AW-AAAAAAAAAAAA', message: 'First', at: 1);
      const b = AdminWarning(id: 'AW-BBBBBBBBBBBB', message: 'Second', at: 2);
      expect(service.add(a), isTrue);
      expect(service.add(a), isFalse);
      service.add(b);
      expect(service.current?.id, a.id);
      service.hide(a.id);
      expect(service.current?.id, b.id);
      await service.acknowledge(b.id);
      expect(service.current, isNull);
      expect(service.pending.map((w) => w.id), [a.id]);
      expect(calls.single.method, 'POST');
      expect(calls.single.url.path, endsWith('/me/warnings/AW-BBBBBBBBBBBB/ack'));
    });

    test('the gateway list replaces what the phone had', () {
      service.add(const AdminWarning(id: 'AW-AAAAAAAAAAAA', message: 'Old', at: 1));
      service.replaceAll(const [AdminWarning(id: 'AW-CCCCCCCCCCCC', message: 'New', at: 3)]);
      expect(service.pending.map((w) => w.id), ['AW-CCCCCCCCCCCC']);
    });
  });

  test('card text names the moderators', () {
    expect(AdminWarningCard.textFor('Please be polite.'), 'A message from CoRoute moderators: Please be polite.');
  });
}
