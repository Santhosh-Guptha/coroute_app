import 'package:flutter/foundation.dart';

/// "Show this rider on the ride map": centre on them and open their card.
/// A new object for every request, so asking twice for the same rider
/// still notifies.
class MapFocusRequest {
  final String userId;
  MapFocusRequest(this.userId);
}

/// The hand-off between the Alerts tab and the ride map. The app shell owns
/// one and gives it to the ride screen; the ride screen consumes a request
/// (sets the value back to null) once it has handled it.
class MapFocus extends ValueNotifier<MapFocusRequest?> {
  MapFocus() : super(null);

  void showRider(String userId) => value = MapFocusRequest(userId);

  /// Takes the pending request, if any.
  MapFocusRequest? take() {
    final r = value;
    if (r != null) value = null;
    return r;
  }
}
