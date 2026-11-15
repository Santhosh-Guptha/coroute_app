import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/audio/talk_button_state.dart';

/// v3.61 compact talk button: hold, hands-free and private talk, always clear about who hears me.
void main() {
  TalkButtonState st({bool tx = false, bool rx = false, bool vox = false, bool muted = false, bool ok = true, String? priv, String? who}) =>
      TalkButtonState.of(transmitting: tx, receiving: rx, handsFree: vox, muted: muted, available: ok, privateName: priv, speakerName: who);

  test('idle: hold to talk, the group hears', () {
    final s = st();
    expect(s.look, TalkButtonLook.idle);
    expect(s.label, 'Talk');
    expect(s.hint, contains('group hears you'));
    expect(s.private, isFalse);
  });
  test('private talk names the one listener (first name)', () {
    final s = st(priv: 'Anu Rao');
    expect(s.label, 'Anu');
    expect(s.private, isTrue);
    expect(s.hint, contains('only Anu hears you'));
    expect(st(priv: 'Anu Rao', tx: true).label, 'Anu');
    expect(st(priv: '  ').private, isFalse);
  });
  test('hands-free says just speak and how to stop', () {
    final s = st(vox: true);
    expect(s.look, TalkButtonLook.handsFree);
    expect(s.hint, contains('just speak'));
    expect(s.hint, contains('Tap to stop'));
  });
  test('talking wins over hands-free and hearing; muted and off win over all', () {
    expect(st(tx: true, vox: true, rx: true).look, TalkButtonLook.talking);
    expect(st(tx: true).label, 'Live');
    expect(st(muted: true, tx: true).look, TalkButtonLook.muted);
    expect(st(ok: false, tx: true).look, TalkButtonLook.off);
  });
  test('hearing shows the speaker first name', () {
    final s = st(rx: true, who: 'Ravi Kumar');
    expect(s.look, TalkButtonLook.hearing);
    expect(s.label, 'Ravi');
    expect(st(rx: true).label, 'A rider');
  });
}
