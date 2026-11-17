import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// v3.62: the one secure storage setup for the app.
///
/// flutter_secure_storage 11 wipes EVERYTHING it stores when one read or write fails (Android `resetOnError`
/// defaults to true). A keystore that is briefly busy (just after boot, some phone makers, after a system update)
/// then deleted the sign-in tokens and the rider was signed out. Here a failure is only a failure: the callers retry
/// and the stored session stays. Same algorithms as before, so stored values are read as they are.
const FlutterSecureStorage kSecureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(resetOnError: false),
);
