import '../../models/rider_model.dart';
import 'language_resolver.dart';
import 'localized_response_service.dart';

/// Status of recipient name resolution.
enum RecipientResolutionStatus {
  exactMatch,
  ambiguous,
  notFound,
}

/// Result encapsulating the outcome of resolving a spoken recipient against convoy roster.
class RecipientResolutionResult {
  final RecipientResolutionStatus status;
  final RiderModel? matchedRider;
  final List<RiderModel> candidates;
  final String queriedName;
  final String? clarificationPrompt;

  const RecipientResolutionResult({
    required this.status,
    this.matchedRider,
    this.candidates = const [],
    required this.queriedName,
    this.clarificationPrompt,
  });

  bool get isExact => status == RecipientResolutionStatus.exactMatch;
  bool get isAmbiguous => status == RecipientResolutionStatus.ambiguous;
  bool get isNotFound => status == RecipientResolutionStatus.notFound;
}

/// Resolves spoken recipient callsigns and names against active convoy members.
///
/// Implements dative postposition stripping, token-level matching, disambiguation,
/// and Levenshtein phonetic fallback.
class RecipientResolver {
  /// Resolves a spoken recipient string against a collection of active riders.
  static RecipientResolutionResult resolve({
    required String rawRecipient,
    required List<RiderModel> activeRiders,
    String locale = 'en-IN',
  }) {
    // 1. Strip Dravidian / Indo-Aryan dative postpositions (e.g. "Rohit-ki" -> "Rohit")
    final cleanName = LanguageResolver.extractBaseRecipient(rawRecipient.trim());
    if (cleanName.isEmpty) {
      return RecipientResolutionResult(
        status: RecipientResolutionStatus.notFound,
        queriedName: rawRecipient,
        clarificationPrompt: 'Recipient name not recognized.',
      );
    }

    final queryLower = cleanName.toLowerCase();

    // 2. Exact match (case-insensitive) on full name
    final exactMatches = <RiderModel>[];
    for (final rider in activeRiders) {
      if (rider.name.toLowerCase() == queryLower) {
        exactMatches.add(rider);
      }
    }

    if (exactMatches.length == 1) {
      return RecipientResolutionResult(
        status: RecipientResolutionStatus.exactMatch,
        matchedRider: exactMatches.first,
        queriedName: cleanName,
      );
    } else if (exactMatches.length > 1) {
      return _buildAmbiguousResult(cleanName, exactMatches, locale);
    }

    // 3. Token-level match (e.g. "Rohit" matching "Rohit Sharma" or "Rohit Verma")
    final tokenMatches = <RiderModel>[];
    for (final rider in activeRiders) {
      final tokens = rider.name.toLowerCase().split(RegExp(r'\s+'));
      if (tokens.contains(queryLower) || rider.name.toLowerCase().startsWith(queryLower)) {
        tokenMatches.add(rider);
      }
    }

    if (tokenMatches.length == 1) {
      return RecipientResolutionResult(
        status: RecipientResolutionStatus.exactMatch,
        matchedRider: tokenMatches.first,
        queriedName: cleanName,
      );
    } else if (tokenMatches.length > 1) {
      return _buildAmbiguousResult(cleanName, tokenMatches, locale);
    }

    // 4. Fuzzy phonetic matching (Levenshtein similarity >= 0.8)
    final fuzzyMatches = <RiderModel>[];
    for (final rider in activeRiders) {
      final tokens = rider.name.toLowerCase().split(RegExp(r'\s+'));
      for (final t in tokens) {
        if (LanguageResolver.calculateSimilarity(t, queryLower) >= 0.8) {
          fuzzyMatches.add(rider);
          break;
        }
      }
    }

    if (fuzzyMatches.length == 1) {
      return RecipientResolutionResult(
        status: RecipientResolutionStatus.exactMatch,
        matchedRider: fuzzyMatches.first,
        queriedName: cleanName,
      );
    } else if (fuzzyMatches.length > 1) {
      return _buildAmbiguousResult(cleanName, fuzzyMatches, locale);
    }

    // 5. Not found in roster
    return RecipientResolutionResult(
      status: RecipientResolutionStatus.notFound,
      queriedName: cleanName,
      clarificationPrompt: 'Rider $cleanName was not found in your convoy.',
    );
  }

  static RecipientResolutionResult _buildAmbiguousResult(
    String name,
    List<RiderModel> candidates,
    String locale,
  ) {
    return RecipientResolutionResult(
      status: RecipientResolutionStatus.ambiguous,
      candidates: candidates,
      queriedName: name,
      clarificationPrompt: LocalizedResponseService.disambiguatePrompt(
        name: name,
        candidates: candidates.map((r) => r.name).toList(),
        locale: locale,
      ),
    );
  }
}
