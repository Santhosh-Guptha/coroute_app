import 'package:coroute_app/domain/safety/effective_speed_limit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the stricter of the group and personal limit applies; 0 means none', () {
    expect(effectiveSpeedLimit(groupKmh: 80, personalKmh: 60), 60);
    expect(effectiveSpeedLimit(groupKmh: 50, personalKmh: 70), 50);
    expect(effectiveSpeedLimit(groupKmh: 0, personalKmh: 70), 70);
    expect(effectiveSpeedLimit(groupKmh: 80, personalKmh: 0), 80);
    expect(effectiveSpeedLimit(groupKmh: 0, personalKmh: 0), 0);
  });
}
