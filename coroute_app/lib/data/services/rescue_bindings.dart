// Round 10 rescue beacon: wiring to the existing services (main.dart creates these).
//  * [AppRescueVictimPort]: what RescueBeaconService reads, from SafetyService (crash alarm, solo
//    SOS, last fix), ConvoyService (my pending / open SOS, battery) and the SOS battery reserve;
//  * [rescueGroupTargets]: other riders' open SOS alerts, for RescueFinderService;
//  * [RescueSpeakerCheck]: the speaker self-test at ride start (which locator band this phone plays).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/diag/diag_log.dart';
import '../../domain/rescue/rescue_acoustics.dart';
import '../../domain/rescue/rescue_id.dart';
import '../../domain/rescue/speaker_self_test.dart';
import '../models/network_wire.dart';
import '../models/pending_sos.dart';
import '../models/sos_alert_model.dart';
import 'convoy_service.dart';
import 'rescue_beacon_service.dart';
import 'rescue_finder_service.dart';
import 'rescue_native.dart';
import 'ride_mic_hub.dart';
import 'safety_service.dart';
import 'sos_battery_reserve.dart';

class AppRescueVictimPort extends ChangeNotifier implements RescueVictimPort {
  AppRescueVictimPort(this._safety, this._convoys) {
    _safety.addListener(notifyListeners);
    _convoys.addListener(notifyListeners);
    SosBatteryReserve.shared.addListener(notifyListeners);
  }

  final SafetyService _safety;
  final ConvoyService _convoys;

  SosAlertModel? _myOpenAlert() {
    final c = _convoys.activeConvoy;
    final me = _convoys.myUserId;
    if (c == null || me == null) return null;
    for (final a in c.activeAlerts.reversed) {
      if (a.userId == me && !a.resolved && !a.isReport) return a;
    }
    return null;
  }

  @override
  RescueVictimState read() {
    final alarm = _safety.alarm;
    final PendingSos? pending = _convoys.pendingSos ?? _safety.offlineSoloSos;
    final open = _myOpenAlert();
    String? key;
    EmergencySource? source;
    if (pending != null && pending.clientId.isNotEmpty) {
      key = pending.clientId;
      source = pending.source;
    } else if (open != null) {
      key = open.clientId.isNotEmpty ? open.clientId : open.alertId;
      source = open.effectiveSource;
    }
    final fix = _safety.lastFix;
    return RescueVictimState(
      sosOpen: key != null,
      sosKey: key,
      alertId: open?.alertId,
      raisedByRider: source != null && source != EmergencySource.crashAuto && source != EmergencySource.wearable,
      alarmOpen: alarm != null,
      alarmSent: alarm?.sent ?? false,
      alarmUnresponsive: alarm?.isUnresponsive ?? false,
      alarmSirenActive: alarm?.isSirenActive ?? false,
      batteryPercent: _convoys.currentBatteryLevel,
      charging: _convoys.isCharging,
      reserveActive: SosBatteryReserve.isActive,
      lat: fix?.lat ?? open?.lat ?? pending?.lat ?? 0,
      lng: fix?.lng ?? open?.lng ?? pending?.lng ?? 0,
    );
  }

  @override
  void dispose() {
    _safety.removeListener(notifyListeners);
    _convoys.removeListener(notifyListeners);
    SosBatteryReserve.shared.removeListener(notifyListeners);
    super.dispose();
  }
}

/// Other riders' open SOS alerts in my group (not reports: their phone is not beaconing, but GPS
/// still helps, so reports are included with the reported position).
List<RescueTarget> rescueGroupTargets(ConvoyService convoys) {
  final c = convoys.activeConvoy;
  final me = convoys.myUserId;
  if (c == null) return const [];
  return [
    for (final a in c.activeAlerts)
      if (!a.resolved && a.userId != me)
        RescueTarget(
          alertId: a.alertId,
          userId: a.userId,
          name: a.userName,
          rescueId: RescueId.forAlert(clientId: a.clientId, alertId: a.alertId),
          lat: a.lat,
          lng: a.lng,
          lastUpdateAt: a.lastKnownAt,
          accuracyM: a.accuracyM,
        ),
  ];
}

/// The speaker self-test: once per 30 days, at ride start, only while the ride mic is already open
/// for siren alerts (no new microphone use just for this). Silent to most people (14..19 kHz,
/// locator level, media stream). Logged in the diagnostics log.
class RescueSpeakerCheck {
  RescueSpeakerCheck({required this.hub, RescueNativePort? native, this.onResult}) : _native = native ?? RescueNative.instance;

  final RideMicHub hub;
  final RescueNativePort _native;
  final void Function(BeaconBandMode mode)? onResult;
  bool _running = false;

  static const String _kMode = 'rescue_band_mode';
  static const String _kAt = 'rescue_band_tested_at';

  /// The stored band mode (both when never tested).
  static Future<BeaconBandMode> storedMode() async {
    try {
      final p = await SharedPreferences.getInstance();
      return BeaconBandMode.fromName(p.getString(_kMode));
    } catch (_) {
      return BeaconBandMode.both;
    }
  }

  /// Runs the test when due. Never throws; never runs during an SOS (the caller checks).
  Future<void> maybeRun() async {
    if (_running || !hub.detectionActive || defaultTargetPlatform != TargetPlatform.android) return;
    SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return;
    }
    final at = prefs.getInt(_kAt) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - at < SpeakerSelfTest.maxAge.inMilliseconds) return;
    _running = true;
    final captured = <double>[];
    void onFrame(Int16List f, MicFrameInfo _) {
      if (captured.length > 48000 * 3) return;
      for (final v in f) {
        captured.add(v / 32768.0);
      }
    }

    try {
      hub.addWideBandListener(onFrame);
      // Wait for the capture to re-open at 48 kHz (up to 3 s).
      for (var i = 0; i < 30 && !hub.wideBandActive; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!hub.wideBandActive) return;
      captured.clear();
      await Future<void>.delayed(Duration(milliseconds: (SpeakerSelfTest.leadInS * 1000).round()));
      final sig = SpeakerSelfTest.testSignal(RideMicHub.wideSampleRate);
      final pcm = Int16List.fromList([for (final v in sig) (v * 32767).round()]);
      await _native.playPcm(pcm, sampleRate: RideMicHub.wideSampleRate, alarm: false, maxVolume: false);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final r = SpeakerSelfTest.analyse(captured, RideMicHub.wideSampleRate);
      await prefs.setString(_kMode, r.mode.name);
      await prefs.setInt(_kAt, now);
      DiagLog.info(DiagCat.sos, 'rescue_speaker_test', r.toLog());
      onResult?.call(r.mode);
    } catch (e) {
      DiagLog.info(DiagCat.sos, 'rescue_speaker_test_failed', {'e': e.toString()});
    } finally {
      hub.removeWideBandListener(onFrame);
      _running = false;
    }
  }
}
