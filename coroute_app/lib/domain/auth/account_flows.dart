/// Round 4 account flows (docs/features_355/sessions_and_security.md §9 and §10): the ride lock answer on sign-in
/// (423 RIDE_ACTIVE_ELSEWHERE + "Use e-mail code"), "Check your inbox" after creating an account, and the admin
/// 2-step prompt (403 MFA_REQUIRED). Pure Dart: the screens use these, the tests check them without a device.
library;

/// A sign-in refused because another phone of this account is on a ride.
class RideLockChallenge {
  const RideLockChallenge({required this.device, required this.lockToken, required this.message});

  static const String code = 'RIDE_ACTIVE_ELSEWHERE';

  /// The riding phone's label ("Pixel 7"), never a place or the ride.
  final String device;

  /// Short-lived token (15 min) that lets this phone ask for and enter the e-mail code.
  final String lockToken;

  /// The gateway's sentence, shown as is.
  final String message;

  /// The dialog title / first line.
  String get title => "You're on a ride on $device";

  /// From a failed sign-in result map (AuthService: success false, code, statusCode, body) or null.
  static RideLockChallenge? fromResult(Map<String, dynamic> res) {
    if (res['code']?.toString() != code) return null;
    final body = res['body'] is Map ? Map<String, dynamic>.from(res['body'] as Map) : const <String, dynamic>{};
    final token = (body['lockToken'] ?? res['lockToken'])?.toString() ?? '';
    if (token.isEmpty) return null;
    final device = (body['device'] ?? res['device'])?.toString().trim() ?? '';
    final dev = device.isEmpty ? 'another phone' : device;
    final msg = res['error']?.toString() ?? "You're on a ride on $dev. End the ride on that phone to sign in here.";
    return RideLockChallenge(device: dev, lockToken: token, message: msg);
  }
}

/// The "Send code again" countdown (the gateway allows one code per 60 s).
class ResendTimer {
  ResendTimer({this.waitSeconds = 60});

  final int waitSeconds;
  DateTime? _sentAt;

  /// A code (or link) was just sent; [serverWait] is the gateway's resendAfterSec / retryAfterSec when known.
  void sent(DateTime now, {int? serverWait}) {
    _sentAt = now;
    if (serverWait != null && serverWait > 0) _override = serverWait;
  }

  int? _override;

  /// Seconds until another code may be asked for (0 = now).
  int secondsLeft(DateTime now) {
    final at = _sentAt;
    if (at == null) return 0;
    final wait = _override ?? waitSeconds;
    final left = wait - now.difference(at).inSeconds;
    return left > 0 ? left : 0;
  }

  bool canResend(DateTime now) => secondsLeft(now) == 0;

  /// "Send again in 42 s" or "Send code again".
  String label(DateTime now, {String action = 'Send code again'}) {
    final s = secondsLeft(now);
    return s == 0 ? action : 'Send again in $s s';
  }
}

/// A 6-digit e-mail code as typed (spaces and dashes allowed).
String cleanEmailCode(String input) => input.replaceAll(RegExp(r'[\s-]'), '');
bool isValidEmailCode(String input) => RegExp(r'^\d{6}$').hasMatch(cleanEmailCode(input));

/// What happened after "Create account".
enum SignUpOutcome { signedIn, checkInbox, failed }

/// Reads the sign-up answer: an older gateway signs in at once (token), a round 4 gateway answers 202 pending
/// (or, for old builds, 400 EMAIL_VERIFICATION_SENT with the same meaning).
SignUpOutcome signUpOutcomeOf(Map<String, dynamic> res) {
  if (res['pending'] == true) return SignUpOutcome.checkInbox;
  if (res['success'] == true) return SignUpOutcome.signedIn;
  if (res['code']?.toString() == 'EMAIL_VERIFICATION_SENT') return SignUpOutcome.checkInbox;
  return SignUpOutcome.failed;
}

/// A sign-in refused because the address is not confirmed yet (offer "Send a new link").
bool needsEmailVerification(Map<String, dynamic> res) => res['code']?.toString() == 'EMAIL_NOT_VERIFIED';

/// An admin call answered 403 MFA_REQUIRED: what the prompt can offer.
class MfaChallenge {
  const MfaChallenge({required this.enrolled, required this.methods, required this.message});

  final bool enrolled;
  final List<String> methods;
  final String message;

  bool get canUseTotp => methods.contains('totp');
  bool get canUseRecovery => methods.contains('recovery');
  bool get canUseEmail => methods.contains('email');

  /// Not set up at all: the prompt explains where to set it up instead of asking for a code.
  bool get needsSetup => methods.isEmpty;

  static MfaChallenge fromBody(Map<String, dynamic> body) {
    final m = body['methods'];
    return MfaChallenge(
      enrolled: body['mfaEnrolled'] == true,
      methods: m is List ? [for (final x in m) x.toString()] : const [],
      message: body['error']?.toString() ?? 'Enter your 2-step verification code to use admin tools.',
    );
  }
}

/// A TOTP code (6 digits) or a recovery code (letters and digits, dashes allowed).
enum MfaCodeKind { totp, recovery, email, invalid }

MfaCodeKind mfaCodeKindOf(String input, {bool emailSent = false}) {
  final v = input.trim();
  if (RegExp(r'^\d{3}\s?\d{3}$').hasMatch(v)) return emailSent ? MfaCodeKind.email : MfaCodeKind.totp;
  if (RegExp(r'^[A-Za-z0-9]{4,6}-?[A-Za-z0-9]{4,6}$').hasMatch(v)) return MfaCodeKind.recovery;
  return MfaCodeKind.invalid;
}
