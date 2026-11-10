// 3.55 ratings & reviews: the engagement templates the web admin edits (gateway/src/engagement.js,
// docs/features_355/ratings_reviews.md). Pure Dart: no Flutter, no I/O.
//
// The app always works without the server: [EngagementConfig.defaults] mirrors the gateway's
// DEFAULT_CONFIG, and every part the server sends that is missing or malformed keeps its default.
// Texts that carry Play-policy words (prices, offers, rewards, gating) are dropped here too, so a
// bad template can never reach the screen even if the server check were bypassed.
import 'dart:convert';

/// A text in English, Hindi and Telugu; [pick] falls back to English.
class LocalText {
  final Map<String, String> byLang;
  const LocalText(this.byLang);

  static const LocalText empty = LocalText({});

  String pick(String lang) {
    final v = byLang[lang];
    if (v != null && v.trim().isNotEmpty) return v;
    return byLang['en'] ?? '';
  }

  bool get hasEnglish => (byLang['en'] ?? '').trim().isNotEmpty;

  /// Null when [j] has no usable English text (then the caller keeps its default).
  static LocalText? tryParse(Object? j, {int maxLen = 160}) {
    final out = <String, String>{};
    if (j is String) {
      final s = _clean(j, maxLen);
      if (s != null) out['en'] = s;
    } else if (j is Map) {
      for (final lang in EngagementConfig.languages) {
        final v = j[lang];
        if (v is! String) continue;
        final s = _clean(v, maxLen);
        if (s != null) out[lang] = s;
      }
    }
    final t = LocalText(out);
    return t.hasEnglish ? t : null;
  }

  static String? _clean(String raw, int maxLen) {
    final s = raw.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.isEmpty || s.length > maxLen) return null;
    if (EngagementConfig.policyProblem(s)) return null;
    return s;
  }
}

/// One quick chip ("Great route", "Clean"): a stable id (sent to the server) and its label.
class ReviewChip {
  final String id;
  final LocalText label;
  const ReviewChip(this.id, this.label);

  static final RegExp idPattern = RegExp(r'^[a-z][a-z0-9_]{0,31}$');

  static ReviewChip? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = j['id']?.toString().trim() ?? '';
    if (!idPattern.hasMatch(id)) return null;
    final label = LocalText.tryParse(j['label'], maxLen: 28);
    return label == null ? null : ReviewChip(id, label);
  }

  /// A list of chips: invalid and duplicate ids dropped, at most [EngagementConfig.maxChips].
  /// Null when [j] is not a list (keep the default).
  static List<ReviewChip>? tryParseList(Object? j) {
    if (j is! List) return null;
    final seen = <String>{};
    final out = <ReviewChip>[];
    for (final e in j) {
      final c = tryParse(e);
      if (c == null || !seen.add(c.id)) continue;
      out.add(c);
      if (out.length >= EngagementConfig.maxChips) break;
    }
    return out;
  }
}

/// "Rate CoRoute" timing rules (admin-configurable; the app enforces the hard limits too).
class RatingPromptRules {
  final bool enabled;
  final int afterRides;
  final int cooldownDays;
  final int maxPerYear;
  const RatingPromptRules({this.enabled = true, this.afterRides = 3, this.cooldownDays = 30, this.maxPerYear = 3});

  static const RatingPromptRules defaults = RatingPromptRules();

  /// Hard limits, whatever the server says: never more than 3 asks a year, never closer than 14 days.
  static const int maxPerYearCap = 3;
  static const int minCooldownDays = 14;

  static RatingPromptRules parse(Object? j) {
    if (j is! Map) return defaults;
    int n(Object? v, int def, int min, int max) {
      final x = v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');
      if (x == null) return def;
      return x.clamp(min, max).toInt();
    }

    return RatingPromptRules(
      enabled: j['enabled'] is bool ? j['enabled'] as bool : defaults.enabled,
      afterRides: n(j['afterRides'], defaults.afterRides, 1, 50),
      cooldownDays: n(j['cooldownDays'], defaults.cooldownDays, minCooldownDays, 365),
      maxPerYear: n(j['maxPerYear'], defaults.maxPerYear, 1, maxPerYearCap),
    );
  }
}

/// The after-ride review switches.
class ReviewRules {
  final bool tripEnabled;
  final bool placesEnabled;

  /// Places asked about after one ride (0 to 2).
  final int maxPlaces;

  /// A skipped trip review is offered again on the trip report for this many days (0 to 7).
  final int reportDays;
  const ReviewRules({this.tripEnabled = true, this.placesEnabled = true, this.maxPlaces = 2, this.reportDays = 7});

  static const ReviewRules defaults = ReviewRules();

  static ReviewRules parse(Object? j) {
    if (j is! Map) return defaults;
    int n(Object? v, int def, int max) {
      final x = v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');
      return x == null ? def : x.clamp(0, max).toInt();
    }

    return ReviewRules(
      tripEnabled: j['tripEnabled'] is bool ? j['tripEnabled'] as bool : defaults.tripEnabled,
      placesEnabled: j['placesEnabled'] is bool ? j['placesEnabled'] as bool : defaults.placesEnabled,
      maxPlaces: n(j['maxPlaces'], defaults.maxPlaces, 2),
      reportDays: n(j['reportDays'], defaults.reportDays, 7),
    );
  }
}

/// Place chip groups (same names as the gateway).
enum ChipGroup { stay, food, fuel, viewpoint, other }

class EngagementConfig {
  final int version;
  final Map<String, LocalText> texts;
  final List<ReviewChip> tripChips;
  final Map<ChipGroup, List<ReviewChip>> placeChips;
  final RatingPromptRules ratingPrompt;
  final ReviewRules reviews;

  const EngagementConfig({
    required this.version,
    required this.texts,
    required this.tripChips,
    required this.placeChips,
    required this.ratingPrompt,
    required this.reviews,
  });

  static const List<String> languages = ['en', 'hi', 'te'];
  static const int maxChips = 10;

  /// The optional note under a trip or place rating.
  static const int noteMax = 280;

  /// Text keys and their length limits (as the gateway's TEXT_KEYS).
  static const Map<String, int> textKeys = {
    'tripTitle': 60,
    'tripSubtitle': 160,
    'noteHint': 80,
    'placesTitle': 60,
    'placesSubtitle': 160,
    'rateTitle': 40,
    'rateSubtitle': 120,
    'feedbackTitle': 40,
    'feedbackSubtitle': 160,
    'thanks': 80,
  };

  /// Words a prompt must never carry (Google Play: no prices, offers, rewards or incentives to
  /// rate, and no gating). A safety net: the gateway refuses these already.
  static final List<RegExp> _policy = [
    RegExp(r'(₹|\$|€|£|\brs\.?\s*\d|\binr\b|rupee|price|pricing|payment|purchase|\bbuy|checkout|subscri|premium|upgrade|renew|refund)', caseSensitive: false),
    RegExp(r'(coupon|discount|voucher|promo|offer|cashback|\d+\s*%\s*off|free\s+(month|week|day|plan|trial|ride|pro|access|upgrade)|\btrial)', caseSensitive: false),
    RegExp(r'(reward|gift|prize|\bwin\b|winner|lucky draw|contest|giveaway|bonus|\bpoints?\b|unlock|in exchange)', caseSensitive: false),
    RegExp(r"((enjoy|enjoying|like|love|loving|happy)\b.{0,40}\b(rate|review|play store|google play|stars?)|(not happy|unhappy|dislike|disappointed)\b.{0,60}\b(feedback|tell us|instead))", caseSensitive: false),
    RegExp(r'(कीमत|भुगतान|खरीद|सदस्यता|कूपन|छूट|डिस्काउंट|ऑफ़र|ऑफर|मुफ़्त|मुफ्त|इनाम|उपहार|ధర|చెల్లింపు|కొనుగోలు|కూపన్|డిస్కౌంట్|తగ్గింపు|ఆఫర్|ఉచిత|బహుమతి)'),
  ];

  /// True when [text] carries a Play-policy word (then the text is not shown).
  static bool policyProblem(String text) => _policy.any((r) => r.hasMatch(text));

  /// The text [key] in [lang] (English fallback, then the built-in default).
  String text(String key, String lang) {
    final t = texts[key]?.pick(lang) ?? '';
    return t.isNotEmpty ? t : (defaults.texts[key]?.pick(lang) ?? '');
  }

  /// Chips for a place of [category] (PoiCategory name or the gateway's category).
  List<ReviewChip> chipsForPlace(String category) => placeChips[groupOf(category)] ?? const [];

  /// Place category -> chip group (same table as the gateway's chipGroupOf).
  static ChipGroup groupOf(String category) {
    switch (category.toLowerCase()) {
      case 'stay':
        return ChipGroup.stay;
      case 'food':
        return ChipGroup.food;
      case 'fuel':
      case 'ev':
        return ChipGroup.fuel;
      case 'viewpoint':
      case 'heritage':
        return ChipGroup.viewpoint;
      default:
        return ChipGroup.other;
    }
  }

  /// The config the server sent (`{version, config}` or the bare config). Anything missing or
  /// malformed keeps the default; never throws.
  static EngagementConfig parse(Object? j) {
    if (j is String) {
      try {
        j = jsonDecode(j);
      } catch (_) {
        return defaults;
      }
    }
    if (j is! Map) return defaults;
    final cfg = j['config'] is Map ? j['config'] as Map : j;
    final version = j['version'] is num ? (j['version'] as num).toInt() : 0;
    final d = defaults;
    final texts = <String, LocalText>{};
    final srcTexts = cfg['texts'] is Map ? cfg['texts'] as Map : const {};
    textKeys.forEach((k, max) => texts[k] = LocalText.tryParse(srcTexts[k], maxLen: max) ?? d.texts[k]!);
    final srcPlace = cfg['placeChips'] is Map ? cfg['placeChips'] as Map : const {};
    return EngagementConfig(
      version: version < 0 ? 0 : version,
      texts: texts,
      tripChips: ReviewChip.tryParseList(cfg['tripChips']) ?? d.tripChips,
      placeChips: {for (final g in ChipGroup.values) g: ReviewChip.tryParseList(srcPlace[g.name]) ?? d.placeChips[g]!},
      ratingPrompt: RatingPromptRules.parse(cfg['ratingPrompt']),
      reviews: ReviewRules.parse(cfg['reviews']),
    );
  }

  /// For the local cache (the same shape the server sends).
  Map<String, Object?> toJson() => {
        'version': version,
        'config': {
          'texts': {for (final e in texts.entries) e.key: e.value.byLang},
          'tripChips': [for (final c in tripChips) _chipJson(c)],
          'placeChips': {for (final e in placeChips.entries) e.key.name: [for (final c in e.value) _chipJson(c)]},
          'ratingPrompt': {
            'enabled': ratingPrompt.enabled,
            'afterRides': ratingPrompt.afterRides,
            'cooldownDays': ratingPrompt.cooldownDays,
            'maxPerYear': ratingPrompt.maxPerYear,
          },
          'reviews': {
            'tripEnabled': reviews.tripEnabled,
            'placesEnabled': reviews.placesEnabled,
            'maxPlaces': reviews.maxPlaces,
            'reportDays': reviews.reportDays,
          },
        },
      };

  static Map<String, Object?> _chipJson(ReviewChip c) => {'id': c.id, 'label': c.label.byLang};

  static LocalText _t(String en, String hi, String te) => LocalText({'en': en, 'hi': hi, 'te': te});
  static ReviewChip _c(String id, String en, String hi, String te) => ReviewChip(id, _t(en, hi, te));

  /// Mirrors DEFAULT_CONFIG in gateway/src/engagement.js.
  static final EngagementConfig defaults = EngagementConfig(
    version: 0,
    texts: {
      'tripTitle': _t('How was the ride?', 'राइड कैसी रही?', 'రైడ్ ఎలా ఉంది?'),
      'tripSubtitle': _t('Optional. Only you and the CoRoute team see your note.', 'वैकल्पिक। आपका नोट सिर्फ़ आप और CoRoute टीम देखती है।',
          'ఐచ్ఛికం. మీ నోట్ మీకు మరియు CoRoute టీమ్‌కు మాత్రమే కనిపిస్తుంది.'),
      'noteHint': _t('Add a short note (optional)', 'छोटा नोट लिखें (वैकल्पिक)', 'చిన్న నోట్ రాయండి (ఐచ్ఛికం)'),
      'placesTitle': _t('Places you stopped at', 'जहाँ आप रुके', 'మీరు ఆగిన చోట్లు'),
      'placesSubtitle': _t('A quick rating helps the next riders.', 'आपकी रेटिंग अगले राइडर्स की मदद करती है।', 'మీ రేటింగ్ తర్వాతి రైడర్లకు ఉపయోగపడుతుంది.'),
      'rateTitle': _t('Rate CoRoute', 'CoRoute को रेट करें', 'CoRouteకి రేటింగ్ ఇవ్వండి'),
      'rateSubtitle': _t('Share your opinion on Google Play', 'Google Play पर अपनी राय दें', 'Google Playలో మీ అభిప్రాయం చెప్పండి'),
      'feedbackTitle': _t('Send feedback', 'सुझाव भेजें', 'అభిప్రాయం పంపండి'),
      'feedbackSubtitle': _t('Tell the CoRoute team what to fix or improve.', 'CoRoute टीम को बताएं क्या सुधारें।', 'ఏమి మెరుగుపరచాలో CoRoute టీమ్‌కు చెప్పండి.'),
      'thanks': _t('Thanks, saved.', 'धन्यवाद, सेव हो गया।', 'ధన్యవాదాలు, సేవ్ అయింది.'),
    },
    tripChips: [
      _c('great_route', 'Great route', 'बढ़िया रास्ता', 'మంచి రూట్'),
      _c('good_pace', 'Good pace', 'सही रफ़्तार', 'సరైన వేగం'),
      _c('too_fast', 'Too fast', 'बहुत तेज़', 'చాలా వేగం'),
      _c('long_breaks', 'Long breaks', 'लंबे ब्रेक', 'పెద్ద బ్రేక్‌లు'),
      _c('bad_roads', 'Bad roads', 'खराब सड़कें', 'చెడ్డ రోడ్లు'),
      _c('safe_group', 'Safe group', 'सुरक्षित ग्रुप', 'సురక్షిత గ్రూప్'),
    ],
    placeChips: {
      ChipGroup.stay: [
        _c('clean', 'Clean', 'साफ़', 'శుభ్రంగా'),
        _c('bike_parking', 'Bike parking', 'बाइक पार्किंग', 'బైక్ పార్కింగ్'),
        _c('safe', 'Safe', 'सुरक्षित', 'సురక్షితం'),
        _c('good_value', 'Good value', 'पैसा वसूल', 'విలువైనది'),
      ],
      ChipGroup.food: [
        _c('tasty', 'Tasty', 'स्वादिष्ट', 'రుచికరం'),
        _c('quick', 'Quick', 'जल्दी', 'త్వరగా'),
        _c('hygienic', 'Hygienic', 'साफ़-सुथरा', 'పరిశుభ్రం'),
        _c('bike_parking', 'Bike parking', 'बाइक पार्किंग', 'బైక్ పార్కింగ్'),
      ],
      ChipGroup.fuel: [
        _c('quick', 'Quick', 'जल्दी', 'త్వరగా'),
        _c('clean_toilets', 'Clean toilets', 'साफ़ शौचालय', 'శుభ్రమైన టాయిలెట్లు'),
        _c('air_pump', 'Air pump', 'हवा भरने की मशीन', 'గాలి పంపు'),
      ],
      ChipGroup.viewpoint: [
        _c('great_view', 'Great view', 'शानदार नज़ारा', 'అద్భుత దృశ్యం'),
        _c('safe_parking', 'Safe parking', 'सुरक्षित पार्किंग', 'సురక్షిత పార్కింగ్'),
        _c('crowded', 'Crowded', 'भीड़', 'రద్దీ'),
      ],
      ChipGroup.other: [
        _c('helpful', 'Helpful', 'मददगार', 'సహాయకరం'),
        _c('clean', 'Clean', 'साफ़', 'శుభ్రంగా'),
        _c('safe', 'Safe', 'सुरक्षित', 'సురక్షితం'),
      ],
    },
    ratingPrompt: RatingPromptRules.defaults,
    reviews: ReviewRules.defaults,
  );
}
