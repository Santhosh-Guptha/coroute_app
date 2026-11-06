import 'nav_prompts.dart';
import 'off_route_monitor.dart';
import 'reroute_scheduler.dart';

/// What the caller does after one fix.
class RerouteStep {
  const RerouteStep({this.event = FollowEvent.none, this.request = false, this.prompts = const []});

  /// I just left the route or came back to it.
  final FollowEvent event;

  /// Ask for a new route now (then call [RerouteController.begin]).
  final bool request;

  /// Lines to say, in order (already limited by [NavPromptGate]).
  final List<NavPrompt> prompts;
}

/// The answer to a request, as the caller uses it.
class RerouteOutcome {
  const RerouteOutcome({required this.current, this.prompts = const []});

  /// False for a late answer (timed out, I came back, a new group route):
  /// the caller drops it.
  final bool current;

  /// Lines to say.
  final List<NavPrompt> prompts;
}

/// The route state for the status line.
enum RerouteStatus {
  /// On the route (or leaving it, not decided yet).
  following,

  /// Off the route, a new route is on its way.
  finding,

  /// Off the route, no network for a new route.
  noSignal,

  /// Off the route, gave up asking.
  gaveUp,

  /// Off the route, waiting before the next request (or auto re-route off).
  off,
}

/// Leaving the route, asking for a new route and what is said, in one pure
/// state machine ([OffRouteMonitor] + [RerouteScheduler] + [NavPromptGate]).
/// The caller matches each fix to the route it shows, passes the distance
/// here, and does what the returned step says: fetch a route, speak lines.
///
/// * Leaving the route: one line, "Off route. Finding a new route." and a
///   request from where I am (online), or "Off route. No signal for a new
///   route." once (offline; the request follows when the network is back).
/// * A new route: "New route ready." once; the caller replaces the route it
///   follows and calls nothing else (the monitor starts over on it).
/// * Three failures: "Couldn't find a new route. Follow the group." once,
///   and the caller keeps showing the route it had.
/// * Back on the route: quiet; the next departure starts afresh.
class RerouteController {
  final OffRouteMonitor monitor = OffRouteMonitor();
  final RerouteScheduler scheduler = RerouteScheduler();
  final NavPromptGate prompts = NavPromptGate();
  bool _online = true;
  bool _auto = true;

  bool get isOff => monitor.isOff;

  RerouteStatus get status {
    if (!monitor.isOff) return RerouteStatus.following;
    if (scheduler.inFlight) return RerouteStatus.finding;
    if (!_auto) return RerouteStatus.off;
    if (!_online) return RerouteStatus.noSignal;
    if (scheduler.gaveUp) return RerouteStatus.gaveUp;
    return RerouteStatus.off;
  }

  /// One fix [offM] metres from the route I follow.
  ///
  /// [canReroute] false (no destination, the ride is paused, ...) still
  /// tracks the state but never asks for a route or speaks.
  RerouteStep onFix(
    NavFix fix, {
    required double offM,
    double? routeBearingDeg,
    bool suppress = false,
    required bool online,
    bool autoReroute = true,
    bool canReroute = true,
  }) {
    final now = fix.tsMs;
    _online = online;
    _auto = autoReroute;
    final say = <NavPrompt>[];
    void add(NavPrompt p) {
      final t = prompts.take(p, nowMs: now, reroutePending: scheduler.inFlight);
      if (t != null) say.add(t);
    }

    if (scheduler.expire(now) && scheduler.gaveUp && monitor.isOff && canReroute) add(NavPrompt.rerouteFailed);
    final event = monitor.onFix(fix, offM: offM, routeBearingDeg: routeBearingDeg, suppress: suppress);
    if (event == FollowEvent.cameBack) {
      _abandon();
      return RerouteStep(event: event, prompts: say);
    }
    if (!monitor.isOff || !canReroute) return RerouteStep(event: event, prompts: say);

    if (!autoReroute) {
      if (event == FollowEvent.wentOff) add(NavPrompt.offRoute);
      return RerouteStep(event: event, prompts: say);
    }
    if (!online) {
      add(NavPrompt.offRouteNoSignal);
      return RerouteStep(event: event, prompts: say);
    }
    final gate = scheduler.check(nowMs: now, online: true);
    if (event == FollowEvent.wentOff && gate != RerouteGate.gaveUp) add(NavPrompt.offRouteFinding);
    return RerouteStep(event: event, request: gate == RerouteGate.go, prompts: say);
  }

  /// A request starts at [nowMs]; returns its ticket for [finish].
  int begin(int nowMs) => scheduler.start(nowMs);

  /// The request with [ticket] answered: [ok] when a usable route came
  /// back; [online] false when the network was gone.
  RerouteOutcome finish(int ticket, {required bool ok, bool online = true, required int nowMs}) {
    if (!scheduler.finish(ticket, ok: ok, online: online, nowMs: nowMs)) return const RerouteOutcome(current: false);
    final say = <NavPrompt>[];
    if (ok) {
      monitor.reset();
      prompts.rerouted(nowMs);
      prompts.newEpisode();
      final p = prompts.take(NavPrompt.rerouteReady, nowMs: nowMs);
      if (p != null) say.add(p);
    } else if (!online) {
      final p = prompts.take(NavPrompt.offRouteNoSignal, nowMs: nowMs);
      if (p != null) say.add(p);
    } else if (scheduler.gaveUp) {
      final p = prompts.take(NavPrompt.rerouteFailed, nowMs: nowMs);
      if (p != null) say.add(p);
    }
    return RerouteOutcome(current: true, prompts: say);
  }

  /// I follow a different line now that was not asked for here (a fuel
  /// detour, back on the group plan): start over on it, keep the quiet times.
  void followNewLine() {
    monitor.reset();
    _abandon();
  }

  /// Back on the route or on a new line: a request on its way is dropped
  /// (not a failure), the next departure starts afresh.
  void _abandon() {
    scheduler.newEpisode();
    if (scheduler.inFlight) scheduler.cancel();
    prompts.newEpisode();
  }

  /// Forget everything (a new group route, arrival, a new ride).
  void reset() {
    monitor.reset();
    scheduler.reset();
    prompts.newEpisode();
  }
}
