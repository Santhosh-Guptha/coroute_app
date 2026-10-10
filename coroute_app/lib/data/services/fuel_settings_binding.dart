import 'auth_service.dart';
import 'settings_service.dart';

/// Account identity, never a rotating JWT, owns fuel preferences and consent.
class FuelSettingsBinding {
  FuelSettingsBinding(this.auth, this.settings) {
    auth.addListener(_sync);
    _sync();
  }
  final AuthService auth;
  final SettingsService settings;
  void _sync() {
    settings.selectFuelUser(auth.currentUserId).ignore();
  }

  void dispose() {
    auth.removeListener(_sync);
  }
}
