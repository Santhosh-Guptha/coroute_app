// Round 10 offline link: what the intercom needs from the offline link to talk over the mesh while the ride socket is
// down. Implemented by OfflineLinkService (lib/data/services/offline_link/offline_link_service.dart); the intercom
// (intercom_service.dart) hands it exactly the START / FRAME / END it would have sent to the gateway, already cleaned
// up by the RNNoise chain and (with Opus) encoded. Kinds are VoiceKind (realtime_service.dart): 1 start, 2 frame, 3 end.
library;

import 'dart:typed_data';

abstract class MeshVoiceGate {
  /// True while talk should go over the mesh (offline link running with a ride key). Live or clip is decided per talk.
  bool get canTalk;

  /// Codec the intercom should send for the next talk over the mesh: 'opus1' (the intercom's Opus encoder, at
  /// [opusBitrate]) or 'pcm16' (the gate turns it into IMA ADPCM for the air).
  String codecFor({required bool opusEncoder});

  /// Opus target bitrate for mesh talk (8000 or 12000 bit/s).
  int get opusBitrate;

  /// One voice message from the intercom (same kind / header / payload as the gateway path).
  void send(int kind, Map<String, dynamic> header, Uint8List? payload);
}
