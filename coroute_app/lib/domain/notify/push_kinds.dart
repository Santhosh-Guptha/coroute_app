/// 3.56 kinds of admin pushes (gateway `src/push_campaigns.js` KINDS), pure Dart.
///
/// Each kind has its own Android notification channel (`CoRouteMessagingService.kt`) and its own
/// switch in Settings > App & privacy, saved on the gateway (`PUT /api/me/push-prefs`, [serverKey])
/// and on the phone ([localKey]; Android drops a push of a kind that is off). The FCM type stays
/// `NEWS`; the kind rides in the data (`kind`), so an older app shows every kind as "News and updates".
///
/// Safety alerts, ride and social pushes are not kinds and can never be turned off here.
/// Partner perks are off until the rider turns them on: a real-world perk at a partner CoRoute
/// curated (never a CoRoute plan, a price, a coupon or a purchase link: Google Play policies).
class PushKind {
  const PushKind({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.serverKey,
    required this.localKey,
    required this.channel,
    required this.defaultOn,
  });

  /// Wire id (`kind` in the push data): update, event, safety_tip, community, partner_perk.
  final String id;

  /// Settings row title and subtitle.
  final String title;
  final String subtitle;

  /// Field of `/api/me/push-prefs`.
  final String serverKey;

  /// SharedPreferences key on the phone (mirrored to Android).
  final String localKey;

  /// Android notification channel id.
  final String channel;

  final bool defaultOn;
}

class PushKinds {
  PushKinds._();

  static const PushKind update = PushKind(
    id: 'update',
    title: 'News and updates',
    subtitle: 'New features and tips from CoRoute. Safety and ride alerts always arrive.',
    serverKey: 'news',
    localKey: 'push_news_enabled',
    channel: 'coroute_news',
    defaultOn: true,
  );
  static const PushKind event = PushKind(
    id: 'event',
    title: 'Events',
    subtitle: 'Group rides, meet-ups and community events.',
    serverKey: 'events',
    localKey: 'push_kind_events',
    channel: 'coroute_events',
    defaultOn: true,
  );
  static const PushKind safetyTip = PushKind(
    id: 'safety_tip',
    title: 'Safety tips',
    subtitle: 'Riding tips from CoRoute. SOS and crash alerts are separate and always arrive.',
    serverKey: 'safetyTips',
    localKey: 'push_kind_safety_tips',
    channel: 'coroute_safety_tips',
    defaultOn: true,
  );
  static const PushKind community = PushKind(
    id: 'community',
    title: 'Community',
    subtitle: 'Rider stories and community milestones.',
    serverKey: 'community',
    localKey: 'push_kind_community',
    channel: 'coroute_community',
    defaultOn: true,
  );
  static const PushKind partnerPerk = PushKind(
    id: 'partner_perk',
    title: 'Partner perks',
    subtitle: 'Perks for riders at partners CoRoute picked, like a garage or a gear shop. Off unless you turn it on.',
    serverKey: 'partnerPerks',
    localKey: 'push_kind_partner_perks',
    channel: 'coroute_partner_perks',
    defaultOn: false,
  );

  /// In the order of the settings rows.
  static const List<PushKind> all = [update, event, safetyTip, community, partnerPerk];

  /// The kind of a push's `kind` value; anything unknown (an older gateway) is [update].
  static PushKind of(String? id) {
    for (final k in all) {
      if (k.id == id) return k;
    }
    return update;
  }

  /// The small label above a push's title on the phone: "Partner perk · Speed Garage", else null.
  static String? labelFor(String? kind, String? partner) {
    if (kind != partnerPerk.id) return null;
    final p = (partner ?? '').trim();
    return p.isEmpty ? 'Partner perk' : 'Partner perk · $p';
  }
}
