import 'dart:async';
import 'dart:io';

/// Gateway host choice during the domain move (coroute.duckdns.org -> coroute.devmonks.space,
/// docs/DOMAIN_MIGRATION_devmonks.md).
///
/// The app tries the primary host first. When it cannot be reached at all (DNS lookup, TLS
/// handshake or connection failure, or a timeout) and no request has succeeded yet in this app
/// session, it switches to the next host (the legacy one, then back). The failed request is retried
/// once there only when it certainly never reached a server (DNS, TLS, connection refused), so a
/// POST is never sent twice. The first host where the gateway answers (a JSON reply, any status; never a
/// Wi-Fi login page) is kept for the rest of the session: nothing is stored, the next start tries the primary host again.
///
/// Both hosts serve the same gateway, so a switch never changes the rider's data or session.
/// A build with an explicit COROUTE_API override has a single host and never switches.
class GatewayHosts {
  GatewayHosts(List<String> hosts)
      : hosts = List.unmodifiable(_dedupe(hosts)),
        assert(hosts.isNotEmpty);

  /// Candidate bases (`https://host`), primary first.
  final List<String> hosts;
  int _index = 0;
  bool _locked = false;

  /// The base in use now.
  String get current => hosts[_index];

  /// True once a host answered: no more switching in this session.
  bool get locked => _locked;

  /// True when the legacy host is in use.
  bool get onFallback => _index != 0;

  /// The gateway at [base] answered (any status): keep it for the session.
  void reportSuccess(String base) {
    if (_locked) return;
    final i = hosts.indexOf(base);
    if (i < 0) return;
    _index = i;
    _locked = true;
  }

  /// A request to [base] failed with [error] before any answer. Returns true when the caller should
  /// retry the request once now (the host was switched and the error was not a timeout).
  bool reportFailure(String base, Object error) {
    if (_locked || hosts.length < 2 || base != current) return false;
    final kind = classify(error);
    if (kind == HostFailure.other) return false;
    _index = (_index + 1) % hosts.length;
    return kind == HostFailure.unreachable;
  }

  /// Whether [error] means "this host could not be reached" (worth trying the other host).
  static HostFailure classify(Object error) {
    if (error is TimeoutException) return HostFailure.unstable;
    if (error is HandshakeException || error is TlsException) return HostFailure.unreachable;
    // package:http wraps socket errors in ClientException: match the text (also for SocketException).
    final s = error.toString();
    const neverSent = ['Failed host lookup', 'No address associated with hostname', 'HandshakeException', 'CERTIFICATE_VERIFY_FAILED', 'Connection refused'];
    if (neverSent.any(s.contains)) return HostFailure.unreachable;
    if (error is SocketException || s.contains('SocketException')) return HostFailure.unstable;
    return HostFailure.other;
  }

  static List<String> _dedupe(List<String> hosts) {
    final out = <String>[];
    for (final h in hosts) {
      final v = h.endsWith('/') ? h.substring(0, h.length - 1) : h;
      if (v.isNotEmpty && !out.contains(v)) out.add(v);
    }
    return out;
  }
}

/// Why a request could not reach a host: [unreachable] never reached a server (switch and retry),
/// [unstable] may have (timeout, connection reset: switch for the next request, no retry),
/// [other] is not a host problem (no switch).
enum HostFailure { unreachable, unstable, other }
