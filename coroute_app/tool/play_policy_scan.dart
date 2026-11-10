// Play payments policy scan (docs/features_355/play_payments_policy.md).
//
// The Play app is consumption-only: no payment SDK, no prices, no buying words and no steering to
// an outside payment in anything a rider (or a store reviewer) can see. This scan checks:
//
//  * SDKs: pubspec.yaml / pubspec.lock, the Android Gradle files, ProGuard rules and the manifest
//    must not name a payment or billing SDK (Razorpay, Play Billing, Stripe, ...) or the Play
//    Install Referrer (used only by the removed coupon path).
//  * Text: every string literal in lib/**.dart (comments and identifiers are not shown to anyone
//    and are skipped), Android res/**.xml and the manifest (outside <!-- comments -->), Kotlin
//    string literals under android/app/src/main, and text assets, for the forbidden terms.
//
// Allowlist: [_allow] lists the few literals that are not UI text (API field names, matching a
// server error, the policy regex itself), each with the reason. Keep it short; never add UI text.
//
// Usage (from the repo root):  /opt/dartpkg/bin/dart run tool/play_policy_scan.dart [root]
// Prints every offending line and exits 1 when there is any, 0 when clean.
import 'dart:io';

/// Words that must not reach rider-facing text.
final RegExp forbiddenTerms = RegExp(
  r'(razorpay|₹|\bINR\b|price|pricing|per month|upgrade|purchase|\bbuy\b|\bbuying\b|checkout|coupon|discount|renew|payment)',
  caseSensitive: false,
);

/// Payment / billing SDKs (and the removed Install Referrer) that must not be in the build.
final RegExp forbiddenSdks = RegExp(
  r'(razorpay|com\.android\.billingclient|billingclient|in_app_purchase|stripe|paytm|phonepe|cashfree|payu|installreferrer|android:scheme="upi")',
  caseSensitive: false,
);

/// (file path suffix, literal pattern, reason). A literal is allowed only when both match.
final List<(String, RegExp, String)> _allow = [
  ('lib/data/models/membership_model.dart', RegExp(r'^paymentsEnabled$'), 'server JSON field name (plans on/off), never shown'),
  ('lib/domain/membership/plan_summary.dart', RegExp(r'^\(₹\|'), 'the policy regex itself (drops server lines with these words)'),
  // 3.55 ratings & reviews: the Play-policy guard that DROPS admin prompt texts carrying these words.
  ('lib/domain/engagement/engagement_config.dart', RegExp(r'^\((₹|coupon)\|'), 'the policy guard regex itself (drops admin texts with these words), never shown'),
  ('lib/data/services/realtime_service.dart', RegExp(r'^not upgraded$'), 'matches the WebSocket library error "not upgraded" (HTTP upgrade), never shown'),
  ('lib/domain/diag/diag_redact.dart', RegExp(r'payment|card', caseSensitive: false), 'key names redacted from diagnostics logs, never shown'),
  ('lib/domain/diag/diag_redact.dart', RegExp(r'^coupons$'), 'URL path segment redacted from diagnostics logs, never shown'),
  ('lib/data/services/ride_analytics_service.dart', RegExp(r'^coroute_analytics_fuel_price_v1$'), 'local storage key of the FUEL price the rider typed'),
  // Fuel money is about fuel the rider buys at a pump, never about CoRoute (allowed by the policy).
  ('lib/presentation/analytics/ride_analytics_screen.dart', RegExp(r'^(Fuel price|Add fuel price|Change fuel price|Fuel price per .*fuel cost.*)$'), 'FUEL price the rider typed (not CoRoute)'),
  // Staff-only admin console note required by the policy (no URL, no link, not rider-facing).
  ('lib/presentation/admin/admin_settings_screen.dart', RegExp(r'^Payments, coupons and marketing are managed in the web admin\.$'), 'staff-only note where the removed admin screens were'),
];

class Hit {
  final String file;
  final int line;
  final String text;
  final String kind;
  Hit(this.file, this.line, this.text, this.kind);
  @override
  String toString() => '$file:$line: [$kind] $text';
}

/// A string literal found in Dart or Kotlin source: its text (raw, without quotes) and line.
class Literal {
  final String text;
  final int line;
  Literal(this.text, this.line);
}

/// String literals of Dart (or Kotlin, close enough) source, skipping comments. Interpolations
/// (`${...}`) are scanned as code, so a string inside one is found too; their text is replaced by
/// `{}` in the outer literal.
List<Literal> stringLiterals(String src, {bool skipDirectives = true}) {
  final out = <Literal>[];
  var i = 0;
  var line = 1;
  final n = src.length;

  bool startsWith(String s, int at) => src.startsWith(s, at);

  // Skips a directive line (import/export/part/library): package names are not UI text.
  bool atLineStart(int at) {
    var j = at - 1;
    while (j >= 0 && (src[j] == ' ' || src[j] == '\t')) {
      j--;
    }
    return j < 0 || src[j] == '\n';
  }

  late void Function(int depthStop) scanCode;

  // Reads a string starting at i (at the quote, after an optional r prefix). Returns when closed.
  void readString({required bool raw}) {
    final startLine = line;
    String quote;
    if (startsWith("'''", i) || startsWith('"""', i)) {
      quote = src.substring(i, i + 3);
    } else {
      quote = src[i];
    }
    i += quote.length;
    final buf = StringBuffer();
    while (i < n) {
      if (startsWith(quote, i)) {
        i += quote.length;
        out.add(Literal(buf.toString(), startLine));
        return;
      }
      final c = src[i];
      if (c == '\n') {
        line++;
        if (quote.length == 1) {
          // Unterminated single-line string: stop here.
          out.add(Literal(buf.toString(), startLine));
          return;
        }
      }
      if (!raw && c == '\\' && i + 1 < n) {
        buf.write(src.substring(i, i + 2));
        if (src[i + 1] == '\n') line++;
        i += 2;
        continue;
      }
      if (!raw && c == r'$' && i + 1 < n && src[i + 1] == '{') {
        i += 2;
        scanCode(1);
        buf.write('{}');
        continue;
      }
      buf.write(c);
      i++;
    }
    out.add(Literal(buf.toString(), startLine));
  }

  // Scans code until the brace depth returns to 0 (for an interpolation) or the end.
  scanCode = (int depthStop) {
    var depth = depthStop;
    while (i < n) {
      final c = src[i];
      if (c == '\n') {
        line++;
        i++;
        continue;
      }
      if (startsWith('//', i)) {
        while (i < n && src[i] != '\n') {
          i++;
        }
        continue;
      }
      if (startsWith('/*', i)) {
        var d = 0;
        while (i < n) {
          if (startsWith('/*', i)) {
            d++;
            i += 2;
            continue;
          }
          if (startsWith('*/', i)) {
            d--;
            i += 2;
            if (d == 0) break;
            continue;
          }
          if (src[i] == '\n') line++;
          i++;
        }
        continue;
      }
      if (skipDirectives && depthStop == 0 && atLineStart(i)) {
        final rest = src.substring(i, i + 8 > n ? n : i + 8);
        if (rest.startsWith('import ') || rest.startsWith('export ') || rest.startsWith('part ') || rest.startsWith('library ')) {
          while (i < n && src[i] != ';' && src[i] != '\n') {
            i++;
          }
          continue;
        }
      }
      if ((c == 'r' || c == 'R') && i + 1 < n && (src[i + 1] == "'" || src[i + 1] == '"')) {
        final prev = i > 0 ? src[i - 1] : ' ';
        if (!RegExp(r'[A-Za-z0-9_$]').hasMatch(prev)) {
          i++;
          readString(raw: true);
          continue;
        }
      }
      if (c == "'" || c == '"') {
        readString(raw: false);
        continue;
      }
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depthStop > 0 && depth == 0) {
          i++;
          return;
        }
      }
      i++;
    }
  };

  scanCode(0);
  return out;
}

bool _allowed(String path, String literal) {
  final norm = path.replaceAll('\\', '/');
  for (final (suffix, pattern, _) in _allow) {
    if (norm.endsWith(suffix) && pattern.hasMatch(literal)) return true;
  }
  return false;
}

String _rel(String root, String path) => path.startsWith(root) ? path.substring(root.length).replaceFirst(RegExp(r'^/'), '') : path;

Iterable<File> _files(Directory d, bool Function(String) want) sync* {
  if (!d.existsSync()) return;
  for (final e in d.listSync(recursive: true, followLinks: false)) {
    if (e is File && want(e.path) && !e.path.contains('/build/')) yield e;
  }
}

/// Text of an XML file with comments blanked out (line numbers kept).
String _stripXmlComments(String s) => s.replaceAllMapped(RegExp(r'<!--[\s\S]*?-->'), (m) => m[0]!.replaceAll(RegExp(r'[^\n]'), ' '));

List<Hit> scan(String root) {
  final hits = <Hit>[];

  // 1. SDKs and build files.
  for (final p in [
    'pubspec.yaml',
    'pubspec.lock',
    'android/app/build.gradle.kts',
    'android/app/build.gradle',
    'android/build.gradle.kts',
    'android/settings.gradle.kts',
    'android/app/proguard-rules.pro',
    'android/app/src/main/AndroidManifest.xml',
  ]) {
    final f = File('$root/$p');
    if (!f.existsSync()) continue;
    final lines = f.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (forbiddenSdks.hasMatch(lines[i])) hits.add(Hit(p, i + 1, lines[i].trim(), 'sdk'));
    }
  }

  // 2. Dart string literals.
  for (final f in _files(Directory('$root/lib'), (p) => p.endsWith('.dart'))) {
    final rel = _rel(root, f.path);
    final src = f.readAsStringSync();
    for (final l in stringLiterals(src)) {
      if (forbiddenTerms.hasMatch(l.text) && !_allowed(rel, l.text)) hits.add(Hit(rel, l.line, l.text, 'text'));
    }
    // A payment SDK import would not be a literal hit (directives are skipped): check it here.
    final lines = src.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trimLeft();
      if ((t.startsWith('import ') || t.startsWith('export ')) && forbiddenSdks.hasMatch(t)) hits.add(Hit(rel, i + 1, t, 'sdk'));
    }
  }

  // 3. Android resources, manifest (outside comments) and Kotlin string literals.
  final main = '$root/android/app/src/main';
  for (final f in [
    ..._files(Directory('$main/res'), (p) => p.endsWith('.xml')),
    File('$main/AndroidManifest.xml'),
  ]) {
    if (!f.existsSync()) continue;
    final rel = _rel(root, f.path);
    final lines = _stripXmlComments(f.readAsStringSync()).split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (forbiddenTerms.hasMatch(lines[i])) hits.add(Hit(rel, i + 1, lines[i].trim(), 'text'));
    }
  }
  for (final f in _files(Directory('$main/kotlin'), (p) => p.endsWith('.kt'))) {
    final rel = _rel(root, f.path);
    for (final l in stringLiterals(f.readAsStringSync())) {
      if (forbiddenTerms.hasMatch(l.text) || forbiddenSdks.hasMatch(l.text)) hits.add(Hit(rel, l.line, l.text, 'text'));
    }
  }

  // 4. Text assets.
  const textExt = ['.json', '.txt', '.md', '.html', '.arb', '.yaml', '.csv', '.xml'];
  for (final f in _files(Directory('$root/assets'), (p) => textExt.any(p.toLowerCase().endsWith))) {
    final rel = _rel(root, f.path);
    final lines = f.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (forbiddenTerms.hasMatch(lines[i]) || forbiddenSdks.hasMatch(lines[i])) hits.add(Hit(rel, i + 1, lines[i].trim(), 'text'));
    }
  }
  return hits;
}

void main(List<String> args) {
  final root = (args.isNotEmpty ? args.first : Directory.current.path).replaceFirst(RegExp(r'/$'), '');
  final hits = scan(root);
  for (final h in hits) {
    stdout.writeln(h);
  }
  stdout.writeln(hits.isEmpty
      ? 'Play payments policy scan: 0 hits (lib, android/app/src/main, assets, pubspec, gradle, proguard).'
      : 'Play payments policy scan: ${hits.length} hit(s).');
  exitCode = hits.isEmpty ? 0 : 1;
}
