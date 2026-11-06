import 'reroute_rules.dart';

/// Short spoken lines about leaving the route and the new route. The text
/// is looked up by [l10nKey] in the rider's voice language (en, hi, te).
enum NavPrompt {
  /// "Off route." (auto re-route switched off)
  offRoute('nav.offRoute'),

  /// "Off route. Finding a new route."
  offRouteFinding('nav.offRoute.finding'),

  /// "Off route. No signal for a new route."
  offRouteNoSignal('nav.offRoute.noSignal'),

  /// "New route ready."
  rerouteReady('nav.reroute.ready'),

  /// "Couldn't find a new route. Follow the group."
  rerouteFailed('nav.reroute.failed');

  const NavPrompt(this.l10nKey);

  /// Key of the text in the string tables.
  final String l10nKey;

  /// English text (tests, logs; the app speaks the localized one).
  String get english => switch (this) {
        NavPrompt.offRoute => 'Off route.',
        NavPrompt.offRouteFinding => 'Off route. Finding a new route.',
        NavPrompt.offRouteNoSignal => 'Off route. No signal for a new route.',
        NavPrompt.rerouteReady => 'New route ready.',
        NavPrompt.rerouteFailed => "Couldn't find a new route. Follow the group.",
      };

  /// True for the lines that say I left the route.
  bool get isOffRoute => this == NavPrompt.offRoute || this == NavPrompt.offRouteFinding || this == NavPrompt.offRouteNoSignal;
}

/// Keeps the navigation voice quiet ([RerouteRules]):
///
/// * At most one off-route line per [RerouteRules.offRoutePromptEvery],
///   none while a new route is on its way, none within
///   [RerouteRules.quietAfterReroute] after a new route arrived.
/// * At most one off-route line per departure ([newEpisode] starts the
///   next one), and "No signal" / "Couldn't find" once per departure.
/// * "New route ready." at most once per [RerouteRules.readyPromptEvery].
class NavPromptGate {
  int? _lastOffMs;
  int? _lastRerouteMs;
  int? _lastReadyMs;
  bool _offSaid = false;
  bool _noSignalSaid = false;
  bool _failedSaid = false;

  /// True when an off-route line may be said now.
  bool offRouteAllowed({required int nowMs, required bool reroutePending}) {
    if (reroutePending || _offSaid) return false;
    final r = _lastRerouteMs;
    if (r != null && nowMs - r < RerouteRules.quietAfterReroute.inMilliseconds) return false;
    final o = _lastOffMs;
    if (o != null && nowMs - o < RerouteRules.offRoutePromptEvery.inMilliseconds) return false;
    return true;
  }

  /// [p] if it may be said now (and records it), else null.
  NavPrompt? take(NavPrompt p, {required int nowMs, bool reroutePending = false}) {
    switch (p) {
      case NavPrompt.offRoute:
      case NavPrompt.offRouteFinding:
      case NavPrompt.offRouteNoSignal:
        if (p == NavPrompt.offRouteNoSignal && _noSignalSaid) return null;
        if (!offRouteAllowed(nowMs: nowMs, reroutePending: reroutePending)) {
          // Not said, but the departure is known: no off-route line later in it.
          _offSaid = true;
          return null;
        }
        _offSaid = true;
        _lastOffMs = nowMs;
        if (p == NavPrompt.offRouteNoSignal) _noSignalSaid = true;
        return p;
      case NavPrompt.rerouteReady:
        final r = _lastReadyMs;
        if (r != null && nowMs - r < RerouteRules.readyPromptEvery.inMilliseconds) return null;
        _lastReadyMs = nowMs;
        return p;
      case NavPrompt.rerouteFailed:
        if (_failedSaid) return null;
        _failedSaid = true;
        return p;
    }
  }

  /// A new route arrived at [nowMs].
  void rerouted(int nowMs) => _lastRerouteMs = nowMs;

  /// A new departure from the route (after coming back, or on a new route).
  void newEpisode() {
    _offSaid = false;
    _noSignalSaid = false;
    _failedSaid = false;
  }

  /// Forget everything (a new ride).
  void reset() {
    _lastOffMs = null;
    _lastRerouteMs = null;
    _lastReadyMs = null;
    newEpisode();
  }
}
