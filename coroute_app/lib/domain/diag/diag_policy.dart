// 3.55 diagnostics log: the rules for levels, log files (rotation, retention, size cap) and the
// periodic GPS summary. Pure Dart (no dart:io): the writer in DiagLogService asks these and does
// the file work. Tested in test/diag_log_355_test.dart.

import 'diag_entry.dart';

/// Which levels are written. Info and above always; debug only while "Detailed logs" is on, which
/// switches itself off [detailedFor] after it was turned on.
class DiagLevelGate {
  DiagLevelGate._();

  static const Duration detailedFor = Duration(hours: 24);

  /// True when [level] is written at [nowMs] with detailed logs on until [detailedUntilMs] (0 = off).
  static bool allows(DiagLevel level, {required int detailedUntilMs, required int nowMs}) {
    if (level != DiagLevel.debug) return true;
    return detailedUntilMs > nowMs;
  }

  /// The "on until" time for detailed logs turned on at [nowMs].
  static int untilFrom(int nowMs) => nowMs + detailedFor.inMilliseconds;
}

/// One log file as the writer sees it.
class DiagFileInfo {
  final String name;
  final int bytes;

  /// Last write, ms since epoch.
  final int modifiedMs;
  const DiagFileInfo(this.name, this.bytes, this.modifiedMs);

  bool get compressed => name.endsWith('.gz');

  /// The day of the file ('20261110') from its name, or null when the name is not a log file.
  String? get day => DiagFiles.dayOf(name);
}

/// What to do with the files on disk.
class DiagCleanupPlan {
  final List<String> delete;
  final List<String> compress;
  const DiagCleanupPlan(this.delete, this.compress);
  bool get isEmpty => delete.isEmpty && compress.isEmpty;
}

/// File names and limits: one file per day, a new part when a file reaches [maxFileBytes]
/// (`diag-20261110-00.jsonl`, `diag-20261110-01.jsonl` ...). Closed files are gzipped
/// (`.jsonl.gz`). Kept: the last [keepDays] days and at most [maxTotalBytes] in all, oldest first out.
class DiagFiles {
  DiagFiles._();

  static const int maxFileBytes = 2 * 1024 * 1024;
  static const int maxTotalBytes = 20 * 1024 * 1024;
  static const int keepDays = 7;
  static const String prefix = 'diag-';

  static final RegExp _name = RegExp(r'^diag-(\d{8})-(\d{2})\.jsonl(\.gz)?$');

  static bool isLogFile(String name) => _name.hasMatch(name);

  static String? dayOf(String name) => _name.firstMatch(name)?.group(1);

  static int partOf(String name) => int.tryParse(_name.firstMatch(name)?.group(2) ?? '') ?? 0;

  /// '20261110' for a local time.
  static String dayKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}';

  static String fileName(String day, int part) => '$prefix$day-${part.toString().padLeft(2, '0')}.jsonl';

  /// The file to append to now: the newest uncompressed part of [today] while it is under
  /// [maxFileBytes] (after adding [pendingBytes]), else the next part.
  static String currentFile(List<DiagFileInfo> files, String today, {int pendingBytes = 0}) {
    var best = -1;
    DiagFileInfo? bestFile;
    for (final f in files) {
      if (f.day != today) continue;
      final p = partOf(f.name);
      if (p > best) {
        best = p;
        bestFile = f;
      }
    }
    if (bestFile == null) return fileName(today, 0);
    if (!bestFile.compressed && bestFile.bytes + pendingBytes <= maxFileBytes) return bestFile.name;
    return fileName(today, (best + 1).clamp(0, 99));
  }

  /// Old days deleted, the total kept under [maxTotalBytes] (oldest first; the file being written
  /// [current] is never deleted), closed plain files compressed.
  static DiagCleanupPlan plan(List<DiagFileInfo> files, {required String today, required String? current}) {
    final logs = files.where((f) => f.day != null).toList()
      ..sort((a, b) {
        final d = a.day!.compareTo(b.day!);
        return d != 0 ? d : partOf(a.name).compareTo(partOf(b.name));
      });
    final delete = <String>[];
    final days = <String>{for (final f in logs) f.day!}.toList()..sort();
    // Keep the newest [keepDays] distinct days (today included when present).
    final keep = days.length <= keepDays ? days.toSet() : days.sublist(days.length - keepDays).toSet();
    // A day in the future (clock moved back) is kept, and so is today.
    final kept = <DiagFileInfo>[];
    for (final f in logs) {
      if (f.name == current || f.day == today || keep.contains(f.day) || f.day!.compareTo(today) > 0) {
        kept.add(f);
      } else {
        delete.add(f.name);
      }
    }
    var total = kept.fold<int>(0, (s, f) => s + f.bytes);
    for (final f in List<DiagFileInfo>.from(kept)) {
      if (total <= maxTotalBytes) break;
      if (f.name == current) continue;
      delete.add(f.name);
      kept.remove(f);
      total -= f.bytes;
    }
    final compress = [
      for (final f in kept)
        if (!f.compressed && f.name != current) f.name,
    ];
    return DiagCleanupPlan(delete, compress);
  }

  /// Files to put in a bundle, newest first, until [budgetBytes] (on-disk sizes; compressed
  /// files count as they are). Files of days before [sinceDay] (when given) are left out.
  static List<DiagFileInfo> forBundle(List<DiagFileInfo> files, {required int budgetBytes, String? sinceDay}) {
    final logs = files.where((f) => f.day != null && (sinceDay == null || f.day!.compareTo(sinceDay) >= 0)).toList()
      ..sort((a, b) {
        final d = b.day!.compareTo(a.day!);
        return d != 0 ? d : partOf(b.name).compareTo(partOf(a.name));
      });
    final out = <DiagFileInfo>[];
    var used = 0;
    for (final f in logs) {
      // gzip-in-gzip barely shrinks; a plain file shrinks to about a tenth.
      final cost = f.compressed ? f.bytes : f.bytes ~/ 8;
      if (out.isNotEmpty && used + cost > budgetBytes) break;
      out.add(f);
      used += cost;
    }
    return out;
  }
}

/// GPS fix cadence and accuracy summarised every [every] (one entry per 30 s instead of one per fix).
class GpsDiagSummary {
  GpsDiagSummary({this.every = const Duration(seconds: 30)});

  final Duration every;
  int _windowStart = 0;
  int _lastT = 0;
  int _fixes = 0;
  int _rejected = 0;
  int _maxGapMs = 0;
  double _maxKmh = 0;
  final List<double> _acc = [];

  /// Adds one fix. Returns the summary fields when the window is over (then a new window starts).
  Map<String, Object?>? add({required int tMs, required double accuracyM, required bool rejected, required double kmh}) {
    if (_windowStart == 0 || tMs < _windowStart) {
      _reset(tMs);
    }
    if (_lastT > 0 && tMs > _lastT) {
      final gap = tMs - _lastT;
      if (gap > _maxGapMs) _maxGapMs = gap;
    }
    _lastT = tMs;
    _fixes++;
    if (rejected) _rejected++;
    if (accuracyM.isFinite) _acc.add(accuracyM);
    if (kmh.isFinite && kmh > _maxKmh) _maxKmh = kmh;
    if (tMs - _windowStart < every.inMilliseconds) return null;
    final out = summary(tMs);
    _reset(tMs);
    return out;
  }

  Map<String, Object?> summary(int nowMs) {
    final acc = List<double>.from(_acc)..sort();
    double q(double p) => acc.isEmpty ? -1 : acc[((acc.length - 1) * p).round()];
    final spanS = ((nowMs - _windowStart) / 1000).clamp(1, 1e9);
    return {
      'fixes': _fixes,
      'hz': (_fixes / spanS * 100).round() / 100,
      'maxGapMs': _maxGapMs,
      'accP50': q(0.5).round(),
      'accMax': acc.isEmpty ? -1 : acc.last.round(),
      'rejected': _rejected,
      'maxKmh': _maxKmh.round(),
    };
  }

  void _reset(int t) {
    _windowStart = t;
    _fixes = 0;
    _rejected = 0;
    _maxGapMs = 0;
    _maxKmh = 0;
    _acc.clear();
  }

  void reset() {
    _windowStart = 0;
    _lastT = 0;
    _reset(0);
  }
}

/// Rate limit for noisy events (siren candidate rejections, socket churn): at most one per
/// [every] per key.
class DiagSampler {
  DiagSampler({this.every = const Duration(seconds: 30)});
  final Duration every;
  final Map<String, int> _last = {};

  bool take(String key, int nowMs) {
    final l = _last[key];
    if (l != null && nowMs - l < every.inMilliseconds && nowMs >= l) return false;
    _last[key] = nowMs;
    if (_last.length > 200) _last.remove(_last.keys.first);
    return true;
  }
}
