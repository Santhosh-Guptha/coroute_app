// 3.55 bike / pillion swap: who may ask whom, the ask from the wire, and the cards and lines
// after SWAP_DONE / SWAP_RESULT.
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/domain/ride/vehicle_swap.dart';

RiderModel r(String id, {String plate = '', bool coRiding = false, String withId = ''}) =>
    RiderModel(userId: id, name: id, lat: 17, lng: 78, lastSeenEpochMs: 0, vehicleNo: plate, isCoRiding: coRiding, ridingWithUserId: withId);

void main() {
  test('rules: bikes with any other rider (no pillions); rider and pillion only when paired', () {
    final ravi = r('ravi', plate: 'TS09AB1234'), kiran = r('kiran', plate: 'KA01CD5678');
    final pillion = r('asha', plate: 'PILLION', coRiding: true, withId: 'ravi');
    expect(SwapRules.canSwapBikes(ravi, kiran), isTrue);
    expect(SwapRules.canSwapBikes(ravi, ravi), isFalse);
    expect(SwapRules.canSwapBikes(ravi, pillion), isFalse);
    expect(SwapRules.canSwapPillion(ravi, pillion), isTrue);
    expect(SwapRules.canSwapPillion(pillion, ravi), isTrue);
    expect(SwapRules.canSwapPillion(kiran, pillion), isFalse);
  });

  test('SWAP_ASK from the wire; malformed asks are ignored', () {
    final a = SwapAsk.fromWire({'requestId': 'SWP-0123456789AB', 'fromUserId': 'ravi', 'fromName': 'Ravi', 'kind': 'BIKES'})!;
    expect(a.kind, SwapKind.bikes);
    expect(a.title, 'Ravi wants to swap bikes with you');
    expect(a.speech, contains('Accept or decline'));
    expect(SwapAsk.fromWire({'requestId': 'x', 'fromUserId': 'ravi', 'kind': 'CARS'}), isNull);
    expect(SwapAsk.fromWire({'fromUserId': 'ravi', 'kind': 'BIKES'}), isNull);
  });

  test('SWAP_DONE card: my new bike, my new seat, or about others; never the word fuel', () {
    final e = {
      'kind': 'BIKES',
      'requestId': 'SWP-0123456789AB',
      'a': {'userId': 'ravi', 'name': 'Ravi', 'vehicleNo': 'KA01CD5678'},
      'b': {'userId': 'kiran', 'name': 'Kiran', 'vehicleNo': 'TS09AB1234'},
    };
    final mine = SwapNotice.done(e, myUserId: 'kiran')!;
    expect(mine.mine, isTrue);
    expect(mine.title, "You're now riding TS09AB1234");
    expect('${mine.title} ${mine.message} ${mine.speech}'.toLowerCase(), isNot(contains('fuel')));
    final others = SwapNotice.done(e, myUserId: 'arjun')!;
    expect(others.mine, isFalse);
    expect(others.title, 'Ravi and Kiran swapped bikes');
    expect(others.speech, isNull);
    final pillion = SwapNotice.done({
      'kind': 'PILLION',
      'a': {'userId': 'asha', 'name': 'Asha', 'vehicleNo': 'TS09AB1234'},
      'b': {'userId': 'ravi', 'name': 'Ravi', 'vehicleNo': 'PILLION'},
    }, myUserId: 'ravi')!;
    expect(pillion.title, 'You now ride pillion with Asha');
    expect(SwapNotice.done({'kind': 'BIKES'}, myUserId: 'x'), isNull);
  });

  test('declined, expired and refused cards', () {
    expect(SwapNotice.declined(name: 'Kiran', kind: SwapKind.bikes, expired: false).title, 'Kiran declined the bike swap');
    expect(SwapNotice.declined(name: 'Kiran', kind: SwapKind.pillion, expired: true).title, 'No answer from Kiran about changing places');
    expect(SwapNotice.refused('SWAP_PENDING', 'A swap is already waiting')?.message, 'A swap is already waiting');
    expect(SwapNotice.refused('NOT_MEMBER', 'x'), isNull);
  });
}
