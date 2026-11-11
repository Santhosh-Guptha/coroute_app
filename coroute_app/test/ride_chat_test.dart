// 3.55 ride chat (lib/domain/ride/ride_chat.dart): quick action list and order, the moving gate
// (no typing while riding, pillion can type), spoken lines, incoming notices and the unread badge.
import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/domain/ride/ride_chat.dart';
import 'package:coroute_app/domain/ride/ride_tap_gate.dart';

ChatLine line(String id, String from, String text, int ts, {bool quick = false, String card = 'CUSTOM', String name = 'Kiran Kumar', String requestedBy = ''}) =>
    ChatLine(id: id, senderId: from, senderName: name, text: text, timestamp: ts, isQuickCard: quick, cardType: card, requestedBy: requestedBy);

void main() {
  group('quick actions', () {
    test('the eight actions, 1-2 word labels, card types within the gateway limit', () {
      expect(RideChat.actions.map((a) => a.label).toList(),
          ['Fuel', 'Break', 'Wait for me', "I'm OK", 'Slow down', 'Regroup here', 'On my way', 'Arrived']);
      for (final a in RideChat.actions) {
        expect(a.cardType.length, lessThanOrEqualTo(24));
        expect(a.label.split(' ').length, lessThanOrEqualTo(3));
        expect(a.text.length, lessThanOrEqualTo(RideChat.maxTextChars));
      }
      expect(RideChat.actions.where((a) => a.isWait).map((a) => a.id), ['wait']);
      expect(RideChat.actions.map((a) => a.id).toSet().length, RideChat.actions.length);
      expect(RideChat.actions.map((a) => a.cardType).toSet().length, RideChat.actions.length);
    });

    test('card type mapping both ways', () {
      expect(RideChat.byCardType('FUEL')?.id, 'fuel');
      expect(RideChat.byCardType('WAIT_2MIN')?.isWait, isTrue);
      expect(RideChat.byCardType('ARRIVED')?.label, 'Arrived');
      expect(RideChat.byCardType('CUSTOM'), isNull);
      expect(RideChat.byId('regroup')?.cardType, 'REGROUP');
    });

    test('saved order: unknown ids dropped, duplicates once, missing ones follow in default order', () {
      expect(RideChat.ordered(null).map((a) => a.id).toList(), RideChat.actions.map((a) => a.id).toList());
      final o = RideChat.ordered(['arrived', 'nope', 'fuel', 'arrived']).map((a) => a.id).toList();
      expect(o.take(2), ['arrived', 'fuel']);
      expect(o, hasLength(8));
      expect(o.skip(2), ['break', 'wait', 'ok', 'slow', 'regroup', 'onmyway']);
    });

    test('move up / down, unchanged at the ends', () {
      final ids = ['a', 'b', 'c'];
      expect(RideChat.move(ids, 'b', up: true), ['b', 'a', 'c']);
      expect(RideChat.move(ids, 'b', up: false), ['a', 'c', 'b']);
      expect(RideChat.move(ids, 'a', up: true), ids);
      expect(RideChat.move(ids, 'c', up: false), ids);
      expect(RideChat.move(ids, 'x', up: true), ids);
    });
  });

  group('moving gate (no typing while riding)', () {
    test('RideTapGate: moving at 8 km/h hides typing; stopped 5 s shows it; pillion always types', () {
      final g = RideTapGate();
      expect(RideChat.canType(g), isTrue);
      g.update(speedKmh: 8, nowMs: 0);
      expect(RideChat.canType(g), isFalse);
      g.update(speedKmh: 2, nowMs: 1000);
      expect(RideChat.canType(g), isFalse, reason: 'stop hold not over');
      g.tick(6000);
      expect(RideChat.canType(g), isTrue);
      g.update(speedKmh: 40, nowMs: 7000, passenger: true);
      expect(RideChat.canType(g), isTrue, reason: 'pillion can type');
    });

    test('single sample rule', () {
      expect(RideChat.canTypeAt(speedKmh: 0), isTrue);
      expect(RideChat.canTypeAt(speedKmh: 7.9), isTrue);
      expect(RideChat.canTypeAt(speedKmh: 8), isFalse);
      expect(RideChat.canTypeAt(speedKmh: 60, passenger: true), isTrue);
      expect(RideChat.canTypeAt(speedKmh: double.nan), isTrue);
    });
  });

  group('spoken lines', () {
    test('quick cards: "Kiran: fuel stop" (older card types too)', () {
      expect(RideChat.quickSpoken(senderName: 'Kiran Kumar', cardType: 'FUEL', text: 'Fuel stop'), 'Kiran: fuel stop');
      expect(RideChat.quickSpoken(senderName: 'Asha', cardType: 'OK', text: 'All good'), "Asha: I'm OK");
      expect(RideChat.quickSpoken(senderName: 'Asha', cardType: 'MECHANICAL', text: 'x'), 'Asha: bike problem');
      expect(RideChat.quickSpoken(senderName: '', cardType: 'ARRIVED', text: 'x'), 'A rider: arrived');
      expect(RideChat.quickSpoken(senderName: 'Asha', cardType: 'CUSTOM', text: 'x'), isNull);
    });

    test('texts: short ones spoken; long ones not while moving; very long never word for word', () {
      expect(RideChat.textSpoken(senderName: 'Kiran', text: 'Tea at the next dhaba', moving: true), 'Kiran says: Tea at the next dhaba');
      final long = 'We should take the left at the next junction because the highway is blocked';
      expect(RideChat.textSpoken(senderName: 'Kiran', text: long, moving: true), isNull);
      expect(RideChat.textSpoken(senderName: 'Kiran', text: long, moving: false), 'Kiran says: $long');
      expect(RideChat.textSpoken(senderName: 'Kiran', text: 'x' * 200, moving: false), 'Kiran sent a message');
      expect(RideChat.textSpoken(senderName: 'Kiran', text: '   ', moving: false), isNull);
    });
  });

  group('incoming notices', () {
    test('quick card: spoken, no banner; text: banner (+ spoken when short)', () {
      final q = ChatRules.decide(line('1', 'u2', 'Fuel stop', 10, quick: true, card: 'FUEL'), myUserId: 'u1', moving: true);
      expect(q.speech, 'Kiran: fuel stop');
      expect(q.banner, isFalse);
      final t = ChatRules.decide(line('2', 'u2', 'Tea?', 10), myUserId: 'u1', moving: true);
      expect(t.banner, isTrue);
      expect(t.speech, 'Kiran says: Tea?');
      final unknownQuick = ChatRules.decide(line('3', 'u2', 'Custom card', 10, quick: true, card: 'WHATEVER'), myUserId: 'u1', moving: false);
      expect(unknownQuick.banner, isTrue, reason: 'unknown card types fall back to a text banner');
    });

    test('mine, hidden riders and my own wait card are silent; an emergency keeps the banner but no voice', () {
      expect(ChatRules.decide(line('1', 'u1', 'hi', 10), myUserId: 'u1', moving: false).isNone, isTrue);
      expect(ChatRules.decide(line('2', 'u2', 'hi', 10), myUserId: 'u1', moving: false, hidden: {'u2'}).isNone, isTrue);
      final myWait = line('3', 'SYSTEM', 'Please wait', 10, quick: true, card: 'WAIT_2MIN', requestedBy: 'u1');
      expect(ChatRules.decide(myWait, myUserId: 'u1', moving: true).isNone, isTrue);
      final theirWait = line('4', 'SYSTEM', 'Please wait', 10, quick: true, card: 'WAIT_2MIN', requestedBy: 'u2');
      expect(ChatRules.decide(theirWait, myUserId: 'u1', moving: true).speech, 'Kiran: wait for me');
      final sos = ChatRules.decide(line('5', 'u2', 'hi', 10), myUserId: 'u1', moving: false, emergency: true);
      expect(sos.speech, isNull);
      expect(sos.banner, isTrue);
    });

    test('visible: hidden riders removed', () {
      final lines = [line('1', 'u2', 'a', 1), line('2', 'u3', 'b', 2), line('3', 'SYSTEM', 'w', 3, requestedBy: 'u3')];
      expect(ChatRules.visible(lines, (l) => l.authorId, {'u3'}).map((l) => l.id), ['1']);
      expect(ChatRules.visible(lines, (l) => l.authorId, {}), lines);
    });
  });

  group('unread counter', () {
    test('counts others\' messages after the last look; hidden riders and mine excluded', () {
      final u = ChatUnread();
      final lines = [line('1', 'u2', 'a', 100), line('2', 'u1', 'mine', 200), line('3', 'u3', 'b', 300), line('4', 'u2', 'c', 400)];
      expect(u.count('G', lines, myUserId: 'u1'), 3);
      expect(u.count('G', lines, myUserId: 'u1', hidden: {'u2'}), 1);
      u.markSeen('G', 300);
      expect(u.count('G', lines, myUserId: 'u1'), 1);
      u.markSeen('G', 100); // never goes back
      expect(u.seenAt('G'), 300);
      expect(u.count('OTHER', lines, myUserId: 'u1'), 3, reason: 'per ride');
    });

    test('badge text and storage round trip', () {
      expect(ChatUnread.badge(0), '');
      expect(ChatUnread.badge(3), '3');
      expect(ChatUnread.badge(12), '9+');
      final a = ChatUnread()..markSeen('G', 5);
      final b = ChatUnread()..load(a.toJson());
      expect(b.seenAt('G'), 5);
      b.forget('G');
      expect(b.seenAt('G'), 0);
    });
  });
}
