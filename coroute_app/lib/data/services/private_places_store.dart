import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/privacy/private_places.dart';

/// 3.56 (round 6): the rider's private places, kept only on this phone (app-private storage; never
/// sent to the gateway, not part of any backup the app makes). One shared instance: the track
/// recorder and the road-data queue ask it on every fix, so reads are from memory.
class PrivatePlacesStore extends ChangeNotifier {
  PrivatePlacesStore._();
  static final PrivatePlacesStore shared = PrivatePlacesStore._();

  static const String prefKey = 'private_places_v1';

  List<PrivatePlace> _places = const [];
  bool _loaded = false;

  List<PrivatePlace> get places => _places;
  bool get isFull => _places.length >= PrivatePlaces.maxPlaces;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      _places = PrivatePlaces.decode((await SharedPreferences.getInstance()).getString(prefKey));
    } catch (_) {
      _places = const [];
    }
    notifyListeners();
  }

  /// Memory only: is this point near a private place? False until [load] finished.
  bool isNear(double lat, double lng) => _places.isNotEmpty && PrivatePlaces.isNear(_places, lat, lng);

  /// The places as (lat, lng) pairs for the road-data queue's privacy zones.
  List<(double, double)> get zones => [for (final p in _places) (p.lat, p.lng)];

  Future<bool> add(PrivatePlace place) async {
    final next = PrivatePlaces.add(_places, place);
    if (next == null) return false;
    await _save(next);
    return true;
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _places.length) return;
    await _save([..._places]..removeAt(index));
  }

  /// Sign-out / account removal on this phone.
  Future<void> clear() => _save(const []);

  Future<void> _save(List<PrivatePlace> next) async {
    _places = List.unmodifiable(next);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (next.isEmpty) {
        await prefs.remove(prefKey);
      } else {
        await prefs.setString(prefKey, PrivatePlaces.encode(next));
      }
    } catch (_) {}
  }

  @visibleForTesting
  void setForTest(List<PrivatePlace> places) {
    _places = List.unmodifiable(places);
    _loaded = true;
  }
}
