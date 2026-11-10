import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/diag/diag_log.dart';
import '../../domain/diag/diag_policy.dart';
import '../../domain/diag/diag_redact.dart';
import 'api_client.dart';
import 'permissions_service.dart';
import 'push_service.dart';
import 'realtime_service.dart';
import 'safety_native.dart';

/// Why a log bundle is sent (the gateway accepts exactly these).
enum DiagUploadReason { manual, safetyPrompt, adminRequest }

extension on DiagUploadReason {
  String get wire => switch (this) {
        DiagUploadReason.manual => 'manual',
        DiagUploadReason.safetyPrompt => 'safety_prompt',
        DiagUploadReason.adminRequest => 'admin_request',
      };
}

/// A safety moment of a ride (SOS, crash alarm, false-alarm cancel) whose log the rider may send
/// after the ride ("Help us improve safety: send the log of this ride?").
class DiagSafetyMoment {
  final String kind;
  final int fromMs;
  final int toMs; // 0 while the ride still runs
  final String? rideId;
  const DiagSafetyMoment({required this.kind, required this.fromMs, this.toMs = 0, this.rideId});

  DiagSafetyMoment closed(int at) => DiagSafetyMoment(kind: kind, fromMs: fromMs, toMs: at, rideId: rideId);

  Map<String, Object?> toJson() => {'kind': kind, 'from': fromMs, 'to': toMs, 'ride': rideId};
  static DiagSafetyMoment? fromJson(Object? j) {
    if (j is! Map || j['from'] is! num) return null;
    return DiagSafetyMoment(
      kind: j['kind']?.toString() ?? 'safety',
      fromMs: (j['from'] as num).toInt(),
      toMs: j['to'] is num ? (j['to'] as num).toInt() : 0,
      rideId: j['ride']?.toString(),
    );
  }
}

/// 3.55 persistent, privacy-safe diagnostics log (docs/features_355/diagnostics_logs.md).
///
/// * [DiagLog] (pure, lib/domain/diag) redacts and stamps every entry; this service is its sink:
///   an async queue written to rotating JSON-lines files in `<filesDir>/diag` (one file per day,
///   a new part at 2 MB, closed files gzipped, last 7 days and 20 MB at most). Writes are batched
///   every 2 s; warn / error and safety entries are written at once. Nothing here blocks the UI or
///   an alert path: [DiagLog] only appends to a list.
/// * Native crashes and main-thread stalls (Kotlin CrashLog) are merged from
///   `diag/native_crashes.jsonl` at start.
/// * "Send logs to CoRoute" uploads a gzip bundle (POST /api/me/diagnostics); "Share log file"
///   shares the same bundle; "Clear logs" deletes the files.
/// * After an SOS / crash alarm / false-alarm cancel, a gentle prompt after the ride (or an
///   automatic send when "Send safety logs automatically" is on, default off). An admin's
///   "Ask for logs" (socket / push DIAG_LOG_REQUEST) asks the rider, who must tap Send.
class DiagLogService extends ChangeNotifier {
  DiagLogService._();
  static final DiagLogService instance = DiagLogService._();

  static const _kSalt = 'diag.salt';
  static const _kDetailed = 'diag.detailedUntil';
  static const _kAutoSafety = 'diag.autoSendSafety';
  static const _kLastError = 'diag.lastError';
  static const _kLastErrorAt = 'diag.lastErrorAt';
  static const _kMoment = 'diag.safetyMoment';
  static const _kLastSent = 'diag.lastSentAt';
  static const _kDismissedReq = 'diag.dismissedRequests';
  static const String nativeCrashFile = 'native_crashes.jsonl';

  /// Largest bundle the gateway accepts (gzip bytes).
  static const int maxBundleBytes = 5 * 1024 * 1024;
  static const Duration flushEvery = Duration(seconds: 2);
  static const int _maxQueued = 5000;

  String? _dir;
  SharedPreferences? _prefs;
  Timer? _timer;
  final List<String> _queue = [];
  int _dropped = 0;
  bool _writing = false;
  bool _again = false;
  String? _curName;
  int _curBytes = 0;
  String _curDay = '';
  bool _ready = false;
  ApiClient? _api;
  StreamSubscription<Map<String, dynamic>>? _rtSub;
  StreamSubscription<PushMessage>? _pushSub;
  AppLifecycleListener? _life;

  bool get ready => _ready;
  String? get directory => _dir;

  // ------------------------------------------------------------------ state for the UI
  int totalBytes = 0;
  int fileCount = 0;
  String? oldestDay;
  String? lastError;
  int lastErrorAt = 0;
  int lastSentAt = 0;
  bool autoSendSafety = false;
  DiagSafetyMoment? _moment;
  bool _momentPromptReady = false;
  String? _pendingRequestId;
  bool busy = false;

  bool get detailedOn => DiagLog.detailed;
  int get detailedUntilMs => DiagLog.detailedUntilMs;

  /// A finished ride with a safety moment whose log the rider has not been asked about yet.
  DiagSafetyMoment? get safetyPrompt => _momentPromptReady && DiagLog.rideId == null ? _moment : null;

  /// An admin asked for this phone's logs (the rider must tap Send).
  String? get pendingRequestId => _pendingRequestId;

  // ------------------------------------------------------------------ start
  /// Opens the log folder, sets the [DiagLog] sink and merges native crashes. Safe to call twice;
  /// never throws (no folder: memory only).
  Future<void> init({required String build}) async {
    if (_ready) return;
    DiagLog.build = build;
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      var salt = prefs.getString(_kSalt);
      if (salt == null || salt.length < 16) {
        salt = _randomSalt();
        await prefs.setString(_kSalt, salt);
      }
      DiagLog.salt = salt;
      DiagLog.detailedUntilMs = prefs.getInt(_kDetailed) ?? 0;
      if (DiagLog.detailedUntilMs != 0 && !DiagLog.detailed) {
        DiagLog.detailedUntilMs = 0; // auto-off after 24 h
        await prefs.remove(_kDetailed);
      }
      autoSendSafety = prefs.getBool(_kAutoSafety) ?? false;
      lastError = prefs.getString(_kLastError);
      lastErrorAt = prefs.getInt(_kLastErrorAt) ?? 0;
      lastSentAt = prefs.getInt(_kLastSent) ?? 0;
      final m = prefs.getString(_kMoment);
      if (m != null) {
        try {
          _moment = DiagSafetyMoment.fromJson(jsonDecode(m));
        } catch (_) {}
        final mm = _moment;
        // Asked about within 3 days of the ride, never later.
        if (mm != null && DateTime.now().millisecondsSinceEpoch - mm.fromMs > const Duration(days: 3).inMilliseconds) {
          _moment = null;
          await prefs.remove(_kMoment);
        } else if (mm != null) {
          if (mm.toMs == 0) _moment = mm.closed(DateTime.now().millisecondsSinceEpoch); // app was closed mid-ride
          _momentPromptReady = true;
        }
      }
    } catch (_) {}
    DiagLog.onProblem = _onProblem;
    try {
      final base = await SafetyNative.filesDir() ?? await _fallbackDir();
      if (base != null) {
        final d = Directory('$base/diag');
        await d.create(recursive: true);
        _dir = d.path;
      }
    } catch (_) {
      _dir = null;
    }
    DiagLog.sink = _enqueue;
    DiagLog.drainEarly();
    _ready = true;
    _timer = Timer.periodic(flushEvery, (_) => _flush());
    DiagLog.info(DiagCat.lifecycle, 'app_start', {'detailed': DiagLog.detailed, 'storage': _dir != null});
    _life = AppLifecycleListener(onStateChange: _onLifecycle);
    await _mergeNativeCrashes();
    unawaited(_housekeeping());
  }

  /// Without the native method (older Android side): the sibling of the cache folder.
  Future<String?> _fallbackDir() async {
    final cache = await SafetyNative.cacheDir();
    if (cache == null) return null;
    final parent = Directory(cache).parent.path;
    return '$parent/files';
  }

  static String _randomSalt() {
    final r = Random.secure();
    return base64Url.encode(List<int>.generate(16, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  void _onLifecycle(AppLifecycleState s) {
    DiagLog.info(DiagCat.lifecycle, s.name);
    // The phone may kill a paused app: write what is queued now.
    if (s == AppLifecycleState.paused || s == AppLifecycleState.detached || s == AppLifecycleState.hidden) _flush();
  }

  void _onProblem(DiagEntry e) {
    if (e.level != DiagLevel.error) return;
    lastError = '${e.cat.wire} ${e.event}${e.fields['type'] != null ? ' (${e.fields['type']})' : ''}';
    lastErrorAt = e.wallMs;
    final p = _prefs;
    if (p != null) {
      p.setString(_kLastError, lastError!).ignore();
      p.setInt(_kLastErrorAt, lastErrorAt).ignore();
    }
  }

  /// Wires the gateway (upload, admin requests). Called once from main.dart.
  void attach({required ApiClient api, RealtimeService? realtime, PushService? push}) {
    _api = api;
    _rtSub?.cancel();
    _rtSub = realtime?.events.listen((m) {
      if (m['type'] == 'DIAG_LOG_REQUEST') _onAdminRequest(m['requestId']?.toString());
    });
    _pushSub?.cancel();
    _pushSub = push?.messages.listen((m) {
      if (m.type == 'DIAG_LOG_REQUEST') _onAdminRequest(m.payload['requestId']);
    });
    api.addListener(_onApi);
    if (api.hasToken) checkRequests().ignore();
  }

  bool _hadToken = false;
  void _onApi() {
    final has = _api?.hasToken ?? false;
    if (has && !_hadToken) checkRequests().ignore();
    _hadToken = has;
  }

  // ------------------------------------------------------------------ writing
  void _enqueue(DiagEntry e) {
    String line;
    try {
      line = e.encode();
    } catch (_) {
      return;
    }
    _queue.add(line);
    if (_queue.length > _maxQueued) {
      final drop = _queue.length - _maxQueued;
      _queue.removeRange(0, drop);
      _dropped += drop;
    }
    if (e.level.atLeast(DiagLevel.warn) || e.cat.urgent) scheduleMicrotask(_flush);
  }

  /// Writes everything queued (append-only). Re-entrant calls just ask for another round.
  Future<void> _flush() async {
    final dir = _dir;
    if (dir == null || _queue.isEmpty) return;
    if (_writing) {
      _again = true;
      return;
    }
    _writing = true;
    try {
      do {
        _again = false;
        if (_dropped > 0) {
          _queue.insert(0, DiagEntry(wallMs: DateTime.now().millisecondsSinceEpoch, monoMs: 0, level: DiagLevel.warn, cat: DiagCat.diag, event: 'queue_dropped', fields: {'count': _dropped}, build: DiagLog.build, session: DiagLog.session).encode());
          _dropped = 0;
        }
        final lines = List<String>.from(_queue);
        _queue.clear();
        final bytes = utf8.encode('${lines.join('\n')}\n');
        final name = await _fileFor(bytes.length);
        await File('$dir/$name').writeAsBytes(bytes, mode: FileMode.append, flush: true);
        _curBytes += bytes.length;
        totalBytes += bytes.length;
      } while (_again && _queue.isNotEmpty);
    } catch (_) {
      // Disk full / folder gone: entries of this round are lost, the app goes on.
    } finally {
      _writing = false;
    }
  }

  /// The file to append [pending] bytes to (a new day or a full file starts the next one).
  Future<String> _fileFor(int pending) async {
    final today = DiagFiles.dayKey(DateTime.now());
    final cur = _curName;
    if (cur != null && _curDay == today && _curBytes + pending <= DiagFiles.maxFileBytes) return cur;
    final files = await _listFiles();
    final next = DiagFiles.currentFile(files, today, pendingBytes: pending);
    final existing = files.where((f) => f.name == next).toList();
    final rolled = cur != null && cur != next;
    _curName = next;
    _curDay = today;
    _curBytes = existing.isEmpty ? 0 : existing.first.bytes;
    if (rolled) unawaited(_housekeeping());
    return next;
  }

  Future<List<DiagFileInfo>> _listFiles() async {
    final dir = _dir;
    if (dir == null) return const [];
    final out = <DiagFileInfo>[];
    try {
      await for (final e in Directory(dir).list(followLinks: false)) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (!DiagFiles.isLogFile(name)) continue;
        final st = await e.stat();
        out.add(DiagFileInfo(name, st.size, st.modified.millisecondsSinceEpoch));
      }
    } catch (_) {}
    return out;
  }

  bool _housekeepingRunning = false;

  /// Deletes old files, keeps the total under the cap, gzips closed files (in a background isolate).
  Future<void> _housekeeping() async {
    final dir = _dir;
    if (dir == null || _housekeepingRunning) return;
    _housekeepingRunning = true;
    try {
      final files = await _listFiles();
      final plan = DiagFiles.plan(files, today: DiagFiles.dayKey(DateTime.now()), current: _curName);
      for (final n in plan.delete) {
        try {
          await File('$dir/$n').delete();
        } catch (_) {}
      }
      for (final n in plan.compress) {
        final path = '$dir/$n';
        try {
          await Isolate.run(() => _gzipFile(path));
        } catch (_) {}
      }
      await refreshStats();
    } finally {
      _housekeepingRunning = false;
    }
  }

  /// Size, file count, oldest day (Diagnostics screen).
  Future<void> refreshStats() async {
    final files = await _listFiles();
    totalBytes = files.fold(0, (s, f) => s + f.bytes);
    fileCount = files.length;
    final days = files.map((f) => f.day).whereType<String>().toList()..sort();
    oldestDay = days.isEmpty ? null : days.first;
    notifyListeners();
  }

  // ------------------------------------------------------------------ native crashes
  Future<void> _mergeNativeCrashes() async {
    final dir = _dir;
    if (dir == null) return;
    final f = File('$dir/$nativeCrashFile');
    try {
      if (!await f.exists()) return;
      final lines = await f.readAsLines();
      await f.delete();
      var n = 0;
      for (final l in lines) {
        if (++n > 50) break;
        Object? d;
        try {
          d = jsonDecode(l);
        } catch (_) {
          continue;
        }
        if (d is! Map) continue;
        final stall = d['kind'] == 'stall';
        DiagLog.log(stall ? DiagLevel.warn : DiagLevel.error, DiagCat.errors, stall ? 'native_main_stall' : 'native_crash', {
          'atMs': d['t'],
          'type': d['type'],
          'what': d['msg'],
          'thread': d['thread'],
          'stallMs': d['ms'],
          'stack': d['stack'],
          'cause': d['cause'],
        });
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------------ settings
  Future<void> setDetailed(bool on) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    DiagLog.detailedUntilMs = on ? DiagLevelGate.untilFrom(now) : 0;
    DiagLog.info(DiagCat.diag, on ? 'detailed_on' : 'detailed_off');
    try {
      final p = _prefs ?? await SharedPreferences.getInstance();
      on ? await p.setInt(_kDetailed, DiagLog.detailedUntilMs) : await p.remove(_kDetailed);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setAutoSendSafety(bool on) async {
    autoSendSafety = on;
    DiagLog.info(DiagCat.diag, 'auto_send_safety', {'on': on});
    try {
      await (_prefs ?? await SharedPreferences.getInstance()).setBool(_kAutoSafety, on);
    } catch (_) {}
    notifyListeners();
  }

  // ------------------------------------------------------------------ safety moments
  /// An SOS, crash alarm or false-alarm cancel happened (SafetyService / ConvoyService hooks).
  void noteSafetyMoment(String kind) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cur = _moment;
    // Keep the earliest start of this ride's moments (one prompt per ride).
    final from = cur != null && cur.toMs == 0 ? cur.fromMs : now - const Duration(minutes: 15).inMilliseconds;
    _moment = DiagSafetyMoment(kind: cur != null && cur.toMs == 0 ? cur.kind : kind, fromMs: from, rideId: DiagLog.rideId);
    _momentPromptReady = false;
    _saveMoment();
    // Not in a ride (e.g. an SOS from Home): ask once the screen settles.
    if (DiagLog.rideId == null) rideEnded();
  }

  /// The ride ended: a safety moment of this ride is offered for sending (or sent by itself).
  void rideEnded() {
    final m = _moment;
    if (m == null || m.toMs != 0) return;
    _moment = m.closed(DateTime.now().millisecondsSinceEpoch + const Duration(minutes: 2).inMilliseconds);
    _saveMoment();
    if (autoSendSafety) {
      // Give the last entries time to land (the window ends 2 min after the ride).
      Timer(const Duration(minutes: 2, seconds: 10), () => sendSafetyMoment(auto: true).ignore());
    } else {
      _momentPromptReady = true;
      notifyListeners();
    }
  }

  void _saveMoment() {
    final p = _prefs;
    final m = _moment;
    if (p == null) return;
    (m == null ? p.remove(_kMoment) : p.setString(_kMoment, jsonEncode(m.toJson()))).ignore();
  }

  /// "Not now" on the safety prompt.
  void dismissSafetyPrompt() {
    DiagLog.info(DiagCat.diag, 'safety_prompt_dismissed', {'kind': _moment?.kind});
    _moment = null;
    _momentPromptReady = false;
    _saveMoment();
    notifyListeners();
  }

  /// Sends the log of the safety moment's ride. Returns null when sent, else the reason.
  Future<String?> sendSafetyMoment({bool auto = false}) async {
    final m = _moment;
    if (m == null) return null;
    final err = await upload(DiagUploadReason.safetyPrompt, fromMs: m.fromMs, toMs: m.toMs == 0 ? null : m.toMs, rideId: m.rideId, auto: auto);
    if (err == null || auto) {
      _moment = null;
      _momentPromptReady = false;
      _saveMoment();
      notifyListeners();
    }
    return err;
  }

  // ------------------------------------------------------------------ admin requests
  void _onAdminRequest(String? id) {
    if (id == null || id.isEmpty || !RegExp(r'^[A-Za-z0-9_\-]{4,64}$').hasMatch(id)) return;
    final dismissed = _prefs?.getStringList(_kDismissedReq) ?? const [];
    if (dismissed.contains(id)) return;
    DiagLog.info(DiagCat.diag, 'admin_request', {'requestId': id});
    _pendingRequestId = id;
    notifyListeners();
  }

  /// Open admin requests for this rider (GET /api/me/diagnostics/requests).
  Future<void> checkRequests() async {
    final api = _api;
    if (api == null || !api.hasToken) return;
    try {
      final res = await api.get('/me/diagnostics/requests');
      final list = res is Map && res['requests'] is List ? res['requests'] as List : const [];
      for (final r in list) {
        if (r is Map) _onAdminRequest(r['requestId']?.toString());
      }
    } catch (_) {}
  }

  void dismissAdminRequest() {
    final id = _pendingRequestId;
    _pendingRequestId = null;
    if (id != null) {
      final p = _prefs;
      final list = [...?p?.getStringList(_kDismissedReq), id];
      p?.setStringList(_kDismissedReq, list.length > 20 ? list.sublist(list.length - 20) : list).ignore();
      DiagLog.info(DiagCat.diag, 'admin_request_dismissed', {'requestId': id});
    }
    notifyListeners();
  }

  Future<String?> sendAdminRequest() async {
    final id = _pendingRequestId;
    if (id == null) return null;
    final err = await upload(DiagUploadReason.adminRequest, requestId: id);
    if (err == null) {
      _pendingRequestId = null;
      notifyListeners();
    }
    return err;
  }

  // ------------------------------------------------------------------ bundle, upload, share
  /// One gzip file with a meta line and the log lines (newest files first within the size cap),
  /// optionally only [fromMs]..[toMs]. Null when there is nothing to send.
  Future<Uint8List?> buildBundle({required String reason, int? fromMs, int? toMs, String? rideId}) async {
    await _flush();
    final dir = _dir;
    if (dir == null) return null;
    final files = await _listFiles();
    final sinceDay = fromMs == null ? null : DiagFiles.dayKey(DateTime.fromMillisecondsSinceEpoch(fromMs));
    final info = await SafetyNative.deviceInfo();
    final meta = jsonEncode({
      'meta': 'coroute-diag',
      'v': 1,
      'build': DiagLog.build,
      'device': DiagRedact.text('${info.manufacturer} ${info.model}'.trim(), max: 60),
      'os': info.release.isNotEmpty ? info.release : '${info.sdkInt}',
      'reason': reason,
      'rideId': ?rideId,
      'from': ?fromMs,
      'to': ?toMs,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
    var budget = maxBundleBytes - 64 * 1024;
    for (var attempt = 0; attempt < 4; attempt++) {
      final pick = DiagFiles.forBundle(files, budgetBytes: budget, sinceDay: sinceDay);
      if (pick.isEmpty) return null;
      final paths = [for (final f in pick.reversed) '$dir/${f.name}']; // oldest first in the bundle
      final job = _BundleJob(paths, meta, fromMs, toMs);
      final bytes = await Isolate.run(() => _bundleWork(job));
      if (bytes.isEmpty) return null;
      if (bytes.length <= maxBundleBytes) return bytes;
      budget = budget ~/ 2;
    }
    return null;
  }

  /// Sends the log to CoRoute (POST /api/me/diagnostics). Null when sent, else a short reason.
  Future<String?> upload(DiagUploadReason reason, {int? fromMs, int? toMs, String? rideId, String? requestId, bool auto = false}) async {
    final api = _api;
    if (api == null || !api.hasToken) return 'Sign in to send logs.';
    if (busy) return 'Already sending.';
    busy = true;
    notifyListeners();
    try {
      DiagLog.info(DiagCat.diag, 'upload_start', {'reason': reason.wire, 'auto': auto});
      final bytes = await buildBundle(reason: reason.wire, fromMs: fromMs, toMs: toMs, rideId: rideId);
      if (bytes == null) return 'There is no log to send yet.';
      final info = await SafetyNative.deviceInfo();
      final q = <String, String>{
        'reason': reason.wire,
        'build': DiagLog.build,
        'device': '${info.manufacturer} ${info.model}'.trim(),
        'os': info.release.isNotEmpty ? info.release : '${info.sdkInt}',
        'rideId': ?rideId,
        'requestId': ?requestId,
      };
      final query = q.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
      await api.postBytes('/me/diagnostics?$query', bytes, 'application/gzip', timeout: const Duration(seconds: 90));
      lastSentAt = DateTime.now().millisecondsSinceEpoch;
      _prefs?.setInt(_kLastSent, lastSentAt).ignore();
      DiagLog.info(DiagCat.diag, 'upload_ok', {'bytes': bytes.length, 'reason': reason.wire});
      return null;
    } on ApiException catch (e) {
      DiagLog.warn(DiagCat.diag, 'upload_failed', {'status': e.statusCode, 'code': e.code});
      if (e.statusCode == 429) return 'Logs were sent several times today. Try again tomorrow.';
      if (e.code == 'FEATURE_OFF') return 'Sending logs is turned off for now.';
      return e.isOffline ? 'No connection. Try again later.' : 'Could not send the logs (${e.statusCode}).';
    } catch (e) {
      DiagLog.warn(DiagCat.diag, 'upload_failed', {'type': e.runtimeType.toString()});
      return 'Could not send the logs.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Shares the bundle as a file (share sheet). Null when shared, else a short reason.
  Future<String?> shareFile() async {
    try {
      final bytes = await buildBundle(reason: 'share');
      if (bytes == null) return 'There is no log to share yet.';
      final now = DateTime.now();
      final name = 'coroute-logs-${DiagFiles.dayKey(now)}-${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}.jsonl.gz';
      final cache = await SafetyNative.cacheDir();
      XFile file;
      if (cache != null) {
        final f = File('$cache/$name');
        await f.writeAsBytes(bytes, flush: true);
        file = XFile(f.path, mimeType: 'application/gzip', name: name);
      } else {
        file = XFile.fromData(bytes, mimeType: 'application/gzip', name: name);
      }
      DiagLog.info(DiagCat.diag, 'share', {'bytes': bytes.length});
      await SharePlus.instance.share(ShareParams(files: [file], fileNameOverrides: [name], subject: 'CoRoute app log'));
      return null;
    } catch (e) {
      return 'Could not share the log file.';
    }
  }

  /// Deletes every log file and the memory copy.
  Future<void> clear() async {
    final dir = _dir;
    _queue.clear();
    DiagLog.clearRecent();
    if (dir != null) {
      for (final f in await _listFiles()) {
        try {
          await File('$dir/${f.name}').delete();
        } catch (_) {}
      }
    }
    _curName = null;
    _curBytes = 0;
    lastError = null;
    lastErrorAt = 0;
    _prefs?.remove(_kLastError).ignore();
    _prefs?.remove(_kLastErrorAt).ignore();
    DiagLog.info(DiagCat.diag, 'cleared');
    await refreshStats();
  }

  /// The last entries for the in-app viewer (newest last), at most [limit], optionally one category.
  List<DiagEntry> recent({int limit = 500, DiagCat? cat}) {
    final all = DiagLog.recent.where((e) => cat == null || e.cat == cat).toList();
    return all.length <= limit ? all : all.sublist(all.length - limit);
  }

  /// The viewer also reads today's file (entries from before this app start).
  Future<List<DiagEntry>> recentFromDisk({int limit = 500}) async {
    await _flush();
    final dir = _dir;
    if (dir == null) return recent(limit: limit);
    final files = (await _listFiles()).where((f) => !f.compressed).toList()..sort((a, b) => b.name.compareTo(a.name));
    final out = <DiagEntry>[];
    for (final f in files) {
      try {
        final lines = await File('$dir/${f.name}').readAsLines();
        final got = <DiagEntry>[];
        for (final l in lines.reversed) {
          final e = DiagEntry.decode(l);
          if (e != null) got.add(e);
          if (out.length + got.length >= limit) break;
        }
        out.insertAll(0, got.reversed);
      } catch (_) {}
      if (out.length >= limit) break;
    }
    return out.isEmpty ? recent(limit: limit) : out;
  }

  @visibleForTesting
  Future<void> flushNow() => _flush();

  @override
  void dispose() {
    _timer?.cancel();
    _rtSub?.cancel();
    _pushSub?.cancel();
    _life?.dispose();
    super.dispose();
  }
}

class _BundleJob {
  final List<String> paths;
  final String meta;
  final int? fromMs;
  final int? toMs;
  const _BundleJob(this.paths, this.meta, this.fromMs, this.toMs);
}

final RegExp _tField = RegExp(r'"t":(\d+)');

/// Runs in a background isolate: reads the files (gunzipping .gz), keeps the lines in the time
/// window, and gzips meta + lines.
Uint8List _bundleWork(_BundleJob job) {
  final out = StringBuffer()
    ..write(job.meta)
    ..write('\n');
  var lines = 0;
  for (final p in job.paths) {
    String text;
    try {
      final raw = File(p).readAsBytesSync();
      text = utf8.decode(p.endsWith('.gz') ? gzip.decode(raw) : raw, allowMalformed: true);
    } catch (_) {
      continue;
    }
    if (job.fromMs == null && job.toMs == null) {
      if (text.trim().isEmpty) continue;
      out.write(text);
      if (!text.endsWith('\n')) out.write('\n');
      lines++;
      continue;
    }
    for (final line in const LineSplitter().convert(text)) {
      final m = _tField.firstMatch(line);
      final t = m == null ? null : int.tryParse(m.group(1)!);
      if (t == null) continue;
      if (job.fromMs != null && t < job.fromMs!) continue;
      if (job.toMs != null && t > job.toMs!) continue;
      out
        ..write(line)
        ..write('\n');
      lines++;
    }
  }
  if (lines == 0) return Uint8List(0); // nothing in the window: no bundle
  return Uint8List.fromList(gzip.encode(utf8.encode(out.toString())));
}

/// Runs in a background isolate: path -> path.gz, then the plain file is deleted.
Future<void> _gzipFile(String path) async {
  final src = File(path);
  final data = await src.readAsBytes();
  final gz = File('$path.gz');
  await gz.writeAsBytes(gzip.encode(data), flush: true);
  await src.delete();
}

/// 3.55 diagnostics: ride start / end, battery and permission states at ride start / end
/// (wired in main.dart from ConvoyService / SafetyService; nothing personal).
class DiagRideObserver {
  DiagRideObserver({
    required this.groupId,
    required this.groupRideActive,
    required this.soloActive,
    required this.batteryPercent,
    required this.charging,
    required this.batterySaver,
    required this.riderCount,
  });

  final String? Function() groupId;
  final bool Function() groupRideActive;
  final bool Function() soloActive;
  final int Function() batteryPercent;
  final bool Function() charging;
  final bool Function() batterySaver;
  final int Function() riderCount;

  bool _riding = false;
  int _startedAt = 0;

  /// Call on every ConvoyService / SafetyService change (cheap when nothing changed).
  void changed() {
    final group = groupRideActive();
    final solo = !group && soloActive();
    final riding = group || solo;
    if (riding == _riding) return;
    _riding = riding;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (riding) {
      _startedAt = now;
      DiagLog.rideId = group ? (groupId() ?? 'ride-$now') : 'solo-$now';
      DiagLog.gps.reset();
      DiagLog.info(DiagCat.ride, 'ride_start', {'kind': group ? 'group' : 'solo', 'riders': riderCount()});
      _battery('ride_start');
      _permissions();
    } else {
      DiagLog.info(DiagCat.ride, 'ride_end', {'minutes': ((now - _startedAt) / 60000).round()});
      _battery('ride_end');
      DiagLog.rideId = null;
      DiagLogService.instance.rideEnded();
    }
  }

  void _battery(String at) {
    DiagLog.info(DiagCat.battery, 'battery', {'at': at, 'pct': batteryPercent(), 'charging': charging(), 'saver': batterySaver()});
  }

  Future<void> _permissions() async {
    try {
      final items = await PermissionsService.status();
      DiagLog.info(DiagCat.permissions, 'permissions', {for (final p in items) p.key: p.granted});
    } catch (e) {
      DiagLog.warn(DiagCat.permissions, 'permissions_unknown', {'type': e.runtimeType.toString()});
    }
  }
}
