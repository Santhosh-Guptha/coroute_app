import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/ui/ui.dart';
import '../../data/local/rider_prefs_store.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/avatar_image_codec.dart';
import '../../data/services/friends_service.dart';
import '../../data/services/garage_service.dart';
import '../../data/services/meta_service.dart';
import '../../data/services/ride_invites_service.dart';
import '../../data/services/trip_storage_service.dart';
import '../../domain/profile/riding_checklist.dart';
import '../admin/master_admin_dashboard.dart';
import '../auth/access_gate_screen.dart';
import '../diagnostics/pre_ride_phone_check_screen.dart';
import '../engagement/rate_and_feedback.dart';
import '../garage/garage_screen.dart';
import '../home/device_safety_facts.dart';
import '../onboarding/welcome_screen.dart';
import '../report/trip_report_screen.dart';
import '../rider/rider_home_screen.dart';
import '../rider/trip_history_screen.dart';
import '../score/leaderboard_screen.dart';
import '../score/rider_score_card.dart';
import '../settings/push_notifications_tile.dart';
import '../settings/settings_screen.dart';
import '../social/profile_screen.dart';
import '../social/ride_invite_screen.dart';
import '../social/user_avatar.dart';
import '../widgets/feature_switch.dart';
import 'appearance_sheet.dart';
import 'edit_profile_screen.dart';
import 'privacy_terms_sheet.dart';
import 'sign_out_flow.dart';

/// The Profile (v3.58, docs/design/REDESIGN_v3.58.md), opened from the avatar on Home:
///  * cover photo (new: owner-only original + public cover, same pipeline as the picture) behind the avatar,
///    name, @username and "Riding since"; the gear opens Settings; tap opens the profile details;
///  * "Complete your riding profile" checklist with progress (safety items first);
///  * My preferences: bike (garage), riding style, riding interests (kept on this phone);
///  * rider score card, My rides (upcoming + recent, trip reports);
///  * Settings & info: My trips, Account, Notifications, Theme, Safety & emergency, Privacy, Invite friends,
///    Rate CoRoute, Help (send feedback), Leaderboard, Admin (admins), Advanced (Settings);
///  * Sign out (the existing flow) and Delete account (two steps).
/// No plan information (Play payments policy + owner decision).
class AccountScreen extends StatefulWidget {
  /// True when shown as a tab of the shell (Back returns to Home).
  final bool embedded;
  const AccountScreen({super.key, this.embedded = false});

  // Row names (docs/UX_NAMING_GUIDE_v3.55.md).
  static const String garageTitle = 'My bikes';
  static const String emergencyTitle = 'Emergency contact & Medical ID';
  static const String leaderboardTitle = 'Leaderboard';
  static const String helpTitle = 'Help';
  static const String accountTitle = 'Account';
  static const String signOutTitle = 'Sign out';
  static const String deleteTitle = 'Delete account';
  static const String settingsInfoTitle = 'Settings & info';
  static const String checklistTitle = 'Complete your riding profile';

  /// Keys of the Help rows, in order (tests check there are exactly these).
  static const List<String> helpRowKeys = ['profile_send_feedback', 'profile_rate_coroute', 'profile_privacy_terms'];

  /// Keys of the Account rows, in order.
  static const List<String> accountRowKeys = ['profile_sign_out', 'profile_delete_account'];

  /// "@asha_rides", or empty while the username is unknown (pure, for tests).
  static String handleOf(String username) {
    final u = username.trim();
    if (u.isEmpty) return '';
    return u.startsWith('@') ? u : '@$u';
  }

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  List<String> _interests = const [];
  String _style = '';
  DeviceSafetyFacts _facts = DeviceSafetyFacts.last ?? const DeviceSafetyFacts(nearbyOk: false, preRideDue: true);
  bool _coverBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final i = await RiderPrefsStore.interests();
    final st = await RiderPrefsStore.style();
    if (!mounted) return;
    setState(() {
      _interests = i;
      _style = st;
    });
    final social = context.read<FriendsService?>();
    if (social != null && social.profile == null) social.refreshProfile().ignore();
    final f = await DeviceSafetyFacts.load(context);
    if (mounted) setState(() => _facts = f);
  }

  void _push(Widget screen) => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => screen));

  void _back() {
    if (widget.embedded) {
      RiderHomeScreen.selectTab(context, HomeTab.ride);
    } else {
      Navigator.maybePop(context);
    }
  }

  Future<void> _share() async {
    final svc = context.read<FriendsService?>();
    if (svc == null) return;
    if (svc.profile?.shareText == null) await svc.refreshProfile();
    final text = svc.profile?.shareText;
    if (!mounted) return;
    if (text == null) return showAppToast(context, 'Could not load your invite link. Try again.', error: true);
    await SharePlus.instance.share(ShareParams(text: text, subject: 'Ride with me on CoRoute'));
  }

  Future<void> _editPreferences() async {
    final saved = await showAppSheet<(List<String>, String)>(
      context,
      title: 'My preferences',
      isScrollControlled: true,
      builder: (_) => SingleChildScrollView(child: _PreferencesEditor(interests: _interests, style: _style)),
    );
    if (saved == null || !mounted) return;
    await RiderPrefsStore.setInterests(saved.$1);
    await RiderPrefsStore.setStyle(saved.$2);
    if (mounted) {
      setState(() {
        _interests = saved.$1;
        _style = saved.$2;
      });
    }
  }

  Future<void> _notifications() => showAppSheet<void>(
        context,
        title: 'Notifications',
        builder: (ctx) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PushNotificationsTile(),
            const SizedBox(height: Space.s8),
            Text('SOS, crash and ride alerts always arrive.', style: AppText.caption),
            const SizedBox(height: Space.s12),
            DsButton(label: 'More in Settings', tone: DsButtonTone.outline, height: 48, fontSize: 15, onPressed: () {
              Navigator.pop(ctx);
              SettingsScreen.open(context);
            }),
          ],
        ),
      );

  /// v3.58 cover photo: pick, cut the wide middle on the phone (no metadata), keep the original privately.
  Future<void> _cover(FriendsService svc) async {
    final has = svc.profile?.coverUrl != null;
    final choice = await showAppSheet<String>(
      context,
      title: 'Cover photo',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DsListRow(icon: Icons.photo_library_rounded, label: has ? 'Choose a new cover' : 'Choose a cover photo', divider: has, onTap: () => Navigator.pop(ctx, 'pick')),
          if (has) DsListRow(icon: Icons.delete_outline_rounded, label: 'Remove cover', divider: false, onTap: () => Navigator.pop(ctx, 'remove')),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => _coverBusy = true);
    String? problem;
    try {
      if (choice == 'remove') {
        problem = await svc.removeCover();
      } else {
        final f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2048, maxHeight: 2048, imageQuality: 90, requestFullMetadata: false);
        if (f == null) return;
        final bytes = await f.readAsBytes();
        if (_imageMime(bytes) == null) {
          problem = 'Use a JPEG, PNG or WebP picture.';
        } else {
          final image = await AvatarImageCodec.decode(bytes);
          try {
            final cover = await AvatarImageCodec.renderCover(image);
            final original = await AvatarImageCodec.encodeOriginal(image);
            problem = await svc.saveCover(cover: cover.bytes, coverMime: cover.mime, original: original?.bytes, originalMime: original?.mime);
          } finally {
            image.dispose();
          }
        }
      }
    } catch (_) {
      problem = 'Could not open your photos.';
    } finally {
      if (mounted) setState(() => _coverBusy = false);
    }
    if (mounted) showAppToast(context, problem ?? (choice == 'remove' ? 'Cover removed' : 'Cover saved'), error: problem != null);
  }

  Future<void> _actOn(ChecklistItem item) async {
    switch (item) {
      case ChecklistItem.emergencyContact:
      case ChecklistItem.medicalId:
        _push(const EditProfileScreen());
      case ChecklistItem.bike:
        _push(const GarageScreen());
      case ChecklistItem.nearbyDevices:
        final ok = await DeviceSafetyFacts.requestNearby();
        if (mounted) setState(() => _facts = DeviceSafetyFacts(nearbyOk: ok, preRideDue: _facts.preRideDue));
      case ChecklistItem.preRideCheck:
        await PreRidePhoneCheckScreen.open(context);
        if (mounted) _load();
      case ChecklistItem.avatar:
        final social = context.read<FriendsService?>();
        social != null ? MyProfileScreen.open(context) : _push(const EditProfileScreen());
      case ChecklistItem.interests:
        await _editPreferences();
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final meta = context.watch<MetaService>().meta;
    final social = context.watch<FriendsService?>();
    final profile = social?.profile;
    final support = meta?.supportEmail ?? '';
    final name = (auth.currentUserName ?? '').trim().isNotEmpty ? auth.currentUserName!.trim() : (profile?.name ?? '').trim();
    final username = auth.username.isNotEmpty ? auth.username : (profile?.username ?? '');
    final handle = AccountScreen.handleOf(username);
    final photosOn = context.featureOn(FriendsService.photosFlag);
    final contactName = (auth.emergencyContactName ?? '').trim();
    final contactPhone = (auth.emergencyContact ?? '').trim();
    final contactSet = contactPhone.length >= 7;
    final medicalSet = auth.bloodGroup.isNotEmpty || auth.medicalNotes.isNotEmpty;
    final leaderboardOn = context.featureOn('leaderboard');
    final garage = Provider.of<GarageService?>(context, listen: false) ?? GarageService.shared;
    final checklist = RidingChecklist.of(ProfileFacts(
      hasEmergencyContact: contactSet,
      hasMedicalId: medicalSet,
      hasBike: garage.bikesNotifier.value.isNotEmpty,
      pillion: auth.isPillion,
      nearbyDevicesOk: _facts.nearbyOk,
      preRideCheckDone: !_facts.preRideDue,
      hasAvatar: profile?.avatarUrl != null,
      hasInterests: _interests.isNotEmpty,
      photosOn: photosOn && social != null,
    ));
    final since = RidingChecklist.ridingSince(profile?.memberSince ?? 0);
    final trips = [...context.watch<TripStorageService?>()?.trips ?? const <TripHistoryModel>[]]..sort((a, b) => b.startTimeEpochMs.compareTo(a.startTimeEpochMs));
    final invites = context.watch<RideInvitesService?>()?.pending ?? const [];
    final theme = Provider.of<ThemeController?>(context);

    Widget card(List<Widget> rows) => DsCard(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Column(children: rows));

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SingleChildScrollView(
        physics: AppScrollBehavior.physics,
        padding: const EdgeInsets.only(bottom: 96),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Who you are: cover + picture + name. Tap the name block for the profile details; the gear opens Settings.
            _ProfileHeader(
              key: const Key('profile_top_box'),
              name: name.isEmpty ? 'Your name' : name,
              handle: handle,
              since: since,
              isAdmin: auth.isMasterAdmin,
              avatarUrl: photosOn ? profile?.avatarUrl : null,
              coverUrl: photosOn ? profile?.coverUrl : null,
              coverBusy: _coverBusy,
              onBack: _back,
              onCover: social != null && photosOn ? () => _cover(social) : null,
              onOpen: () => social != null ? MyProfileScreen.open(context) : _push(const EditProfileScreen()),
              onSettings: () => SettingsScreen.open(context),
            ),
            ContentWidth(
              maxWidth: 640,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!checklist.complete) ...[
                      _ChecklistCard(result: checklist, onTap: _actOn),
                      const SizedBox(height: Space.s16),
                    ],
                    // My preferences: bike, riding style, interests.
                    DsCard(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text('My preferences', style: AppText.title)),
                              TextButton(key: const Key('profile_prefs_edit'), onPressed: _editPreferences, style: TextButton.styleFrom(minimumSize: const Size(48, 48)), child: Text(_interests.isEmpty && _style.isEmpty ? 'Add' : 'Edit')),
                            ],
                          ),
                          if (_style.isNotEmpty || _interests.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Wrap(spacing: 8, runSpacing: 8, children: [
                                if (_style.isNotEmpty) InfoPill(icon: Icons.speed_rounded, text: _style, color: AppTheme.accentText, background: AppTheme.tint),
                                for (final i in _interests) InfoPill(icon: Icons.favorite_border_rounded, text: i),
                              ]),
                            )
                          else
                            Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Your riding style and the rides you enjoy.', style: AppText.label)),
                          ValueListenableBuilder(
                            valueListenable: garage.activeBikeNotifier,
                            builder: (context, bike, _) => DsListRow(
                              key: const Key('profile_garage'),
                              icon: auth.isPillion ? Icons.airline_seat_recline_normal_rounded : Icons.two_wheeler_rounded,
                              label: AccountScreen.garageTitle,
                              value: bike?.name,
                              divider: false,
                              onTap: () => _push(const GarageScreen()),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Space.s16),
                    // 3.55 rider score card (hides itself when the riderScore switch is off).
                    const RiderScoreCard(),
                    const SizedBox(height: Space.s24),
                    SectionTitle('My rides', action: 'All trips', onAction: () => _push(const TripHistoryScreen())),
                    const SizedBox(height: Space.s8),
                    if (trips.isEmpty && invites.isEmpty)
                      DsCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('Your upcoming group rides and finished rides show here, with their trip reports.', style: AppText.label),
                            const SizedBox(height: Space.s12),
                            DsButton(label: 'Explore rides', icon: Icons.explore_outlined, tone: DsButtonTone.outline, height: 48, fontSize: 15, onPressed: () => RiderHomeScreen.selectTab(context, HomeTab.explore)),
                          ],
                        ),
                      )
                    else
                      card([
                        for (final i in invites.take(2))
                          DsListRow(icon: Icons.mail_outline_rounded, label: i.rideName.isNotEmpty ? i.rideName : 'Ride with ${i.crewName}', value: 'Invite', onTap: () => RideInviteScreen.open(context, i.inviteId)),
                        for (var k = 0; k < trips.length && k < 3; k++)
                          DsListRow(
                            icon: Icons.route_outlined,
                            label: trips[k].tripName.trim().isNotEmpty ? trips[k].tripName.trim() : 'Ride',
                            value: '${trips[k].totalDistanceKm.toStringAsFixed(0)} km',
                            divider: k < trips.length - 1 && k < 2,
                            onTap: () => _push(trips[k].hasReport ? TripReportScreen(trip: trips[k]) : TripReplayDetailScreen(trip: trips[k])),
                          ),
                      ]),
                    const SizedBox(height: Space.s24),
                    const SectionTitle(AccountScreen.settingsInfoTitle),
                    const SizedBox(height: Space.s8),
                    card([
                      _SettingsRow(key: const Key('profile_trips'), icon: Icons.map_outlined, title: 'My trips', onTap: () => _push(const TripHistoryScreen())),
                      _SettingsRow(key: const Key('profile_account'), icon: Icons.account_circle_outlined, title: AccountScreen.accountTitle, subtitle: 'Name, phone and vehicle', onTap: () => _push(const EditProfileScreen())),
                      _SettingsRow(key: const Key('profile_notifications'), icon: Icons.notifications_none_rounded, title: 'Notifications', onTap: _notifications),
                      if (theme != null)
                        _SettingsRow(key: const Key('profile_theme'), icon: Icons.contrast_rounded, title: 'Theme', subtitle: AppearanceSheet.summary(theme), onTap: () => AppearanceSheet.show(context)),
                      _SettingsRow(
                        key: const Key('profile_emergency'),
                        icon: contactSet ? Icons.contact_emergency_rounded : Icons.person_add_alt_1_rounded,
                        title: AccountScreen.emergencyTitle,
                        subtitle: '${contactSet ? (contactName.isNotEmpty ? contactName : contactPhone) : 'Add a contact'} · '
                            '${medicalSet ? 'Medical ID set' : 'No Medical ID'}',
                        // Amber until a contact is set: the SOS screen calls or texts this person.
                        color: contactSet ? null : AppTheme.warnText,
                        onTap: () => _push(const EditProfileScreen()),
                      ),
                      _SettingsRow(
                        key: Key(AccountScreen.helpRowKeys[2]),
                        icon: Icons.privacy_tip_outlined,
                        title: PrivacyTermsSheet.title,
                        onTap: () => PrivacyTermsSheet.show(context, meta),
                      ),
                      if (social != null) _SettingsRow(key: const Key('profile_invite'), icon: Icons.share_outlined, title: 'Invite friends', onTap: _share),
                      // 3.55 ratings & reviews: straight to Google Play's in-app review (no "do you like us?").
                      _SettingsRow(key: Key(AccountScreen.helpRowKeys[1]), icon: Icons.star_outline_rounded, title: RateAndFeedback.rateTitle, onTap: () => RateAndFeedback.rate(context)),
                      // One screen: report a problem, suggest a safety feature, other (+ diagnostics log).
                      _SettingsRow(key: Key(AccountScreen.helpRowKeys[0]), icon: Icons.help_outline_rounded, title: RateAndFeedback.feedbackTitle, subtitle: 'Help & support', onTap: () => RateAndFeedback.openFeedback(context)),
                      if (leaderboardOn)
                        _SettingsRow(key: const Key('profile_tab_leaderboard'), icon: Icons.emoji_events_outlined, title: AccountScreen.leaderboardTitle, onTap: () => LeaderboardScreen.open(context)),
                      if (auth.isMasterAdmin)
                        _SettingsRow(
                          icon: Icons.admin_panel_settings_rounded,
                          title: 'Admin',
                          subtitle: 'Live rides, history and users',
                          // One admin console for phones and tablets (it adapts its layout).
                          onTap: () => _push(const MasterAdminDashboard()),
                        ),
                      _SettingsRow(key: const Key('profile_advanced'), icon: Icons.tune_rounded, title: SettingsScreen.moreTitle, subtitle: 'All settings', divider: false, onTap: () => SettingsScreen.open(context)),
                    ]),
                    const SizedBox(height: Space.s24),
                    card([
                      _SettingsRow(
                        key: Key(AccountScreen.accountRowKeys[0]),
                        icon: Icons.logout_rounded,
                        title: AccountScreen.signOutTitle,
                        color: AppTheme.danger,
                        chevron: false,
                        // 3.57: this phone or every device, keep emergency info (default), never mid-ride,
                        // then the sign-in screen with the stack cleared (lib/presentation/account/sign_out_flow.dart).
                        onTap: () => SignOutFlow.run(context, auth, welcome: (_) => const WelcomeScreen()),
                      ),
                      _SettingsRow(
                        key: Key(AccountScreen.accountRowKeys[1]),
                        icon: Icons.delete_forever_rounded,
                        title: AccountScreen.deleteTitle,
                        color: AppTheme.sos,
                        chevron: false,
                        divider: false,
                        onTap: () => widget._confirmDelete(context),
                      ),
                    ]),
                    const SizedBox(height: Space.s24),
                    Text(
                      'CoRoute ${MetaService.currentVersion} (build ${MetaService.currentBuild})${support.isNotEmpty ? ', $support' : ''}',
                      style: AppText.caption,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text('Ride together. Stay safe.', style: AppText.caption, textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// JPEG / PNG / WebP by magic bytes, else null.
String? _imageMime(List<int> b) {
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
  if (b.length >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return 'image/png';
  if (b.length >= 12 && String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' && String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') return 'image/webp';
  return null;
}

extension on AccountScreen {
  /// Two steps: the standard confirm, then type DELETE in a sheet.
  Future<void> _confirmDelete(BuildContext context) async {
    final go = await confirmAction(
      context,
      title: 'Delete your account?',
      message: 'Your account, profile and ride history will be deleted. This cannot be undone.',
      confirmLabel: 'Continue',
      destructive: true,
    );
    if (!go || !context.mounted) return;
    final typed = await showAppSheet<bool>(
      context,
      title: 'Type DELETE to confirm',
      isScrollControlled: true,
      builder: (_) => const _TypeDeleteSheet(),
    );
    if (typed != true || !context.mounted) return;
    final auth = context.read<AuthService>();
    var res = await auth.deleteAccount();
    if (!context.mounted) return;
    // 3.57: the gateway asks to confirm it is the rider (password, or Google), then the deletion runs again.
    if (res['code'] == 'REAUTH_REQUIRED') {
      final ok = await _reauth(context, auth);
      if (!ok || !context.mounted) return;
      res = await auth.deleteAccount();
      if (!context.mounted) return;
    }
    if (res['success'] == true) {
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const AccessGateScreen()), (_) => false);
      messenger.clearSnackBars();
      messenger.showSnackBar(const SnackBar(content: Text('Your account has been deleted.')));
    } else {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(res['error']?.toString() ?? 'Could not delete the account.')));
    }
  }
}

/// 3.57: "Confirm it is you" before deleting the account (password; Google accounts confirm with Google).
Future<bool> _reauth(BuildContext context, AuthService auth) async {
  if (auth.signsInWithGoogle) {
    final r = await auth.reauthenticate(withGoogle: true);
    if (r['success'] != true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['error']?.toString() ?? 'Google did not confirm.')));
    }
    return r['success'] == true;
  }
  final ctrl = TextEditingController();
  final pw = await showAppDialog<String>(
    context, // round 7: app motion (spring scale + fade, reduce-motion aware)
    builder: (ctx) => AlertDialog(
      title: const Text('Confirm it is you'),
      content: TextField(
        key: const Key('reauth_password'),
        controller: ctrl,
        obscureText: true,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Your password'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Confirm')),
      ],
    ),
  );
  ctrl.dispose();
  if (pw == null || pw.isEmpty || !context.mounted) return false;
  final r = await auth.reauthenticate(password: pw);
  if (r['success'] != true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r['error']?.toString() ?? 'That password is not right.')));
  }
  return r['success'] == true;
}

/// A row inside a [DsCard] list: teal icon, label with an optional caption under it, a
/// chevron on the right, and a hairline under it.
class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Color? color;
  final bool chevron;
  final bool divider;

  const _SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.color,
    this.chevron = true,
    this.divider = true,
  });

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    final row = Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
      child: Row(
        children: [
          Icon(icon, size: 22, color: color ?? AppTheme.accentText),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600, color: color ?? AppTheme.text)),
                if (sub != null && sub.isNotEmpty) Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption),
              ],
            ),
          ),
          if (chevron && onTap != null) Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

class _TypeDeleteSheet extends StatefulWidget {
  const _TypeDeleteSheet();

  @override
  State<_TypeDeleteSheet> createState() => _TypeDeleteSheetState();
}

class _TypeDeleteSheetState extends State<_TypeDeleteSheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ok = _ctrl.text.trim() == 'DELETE';
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            onChanged: (_) => setState(() {}),
            style: AppText.body,
            decoration: const InputDecoration(labelText: 'Type DELETE'),
          ),
          const SizedBox(height: Space.s16),
          DsButton(
            label: 'Delete permanently',
            tone: DsButtonTone.sos,
            onPressed: ok ? () => Navigator.pop(context, true) : null,
          ),
        ],
      ),
    );
  }
}


/// Cover photo (or our own illustration) with the picture over its lower edge, name, @username, "Riding since".
class _ProfileHeader extends StatelessWidget {
  final String name;
  final String handle;
  final String since;
  final bool isAdmin;
  final String? avatarUrl;
  final String? coverUrl;
  final bool coverBusy;
  final VoidCallback onBack;
  final VoidCallback? onCover;
  final VoidCallback onOpen;
  final VoidCallback onSettings;
  const _ProfileHeader({
    super.key,
    required this.name,
    required this.handle,
    required this.since,
    required this.isAdmin,
    required this.avatarUrl,
    required this.coverUrl,
    required this.coverBusy,
    required this.onBack,
    required this.onCover,
    required this.onOpen,
    required this.onSettings,
  });

  static const double coverHeight = 150;
  static const double avatarSize = 104;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final api = context.read<ApiClient?>();
    final cover = coverUrl;
    final w = MediaQuery.sizeOf(context).width;
    return Column(
      children: [
        SizedBox(
          height: top + coverHeight + avatarSize / 2,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: top + coverHeight,
                child: Semantics(
                  button: onCover != null,
                  label: cover == null ? 'Add a cover photo' : 'Change cover photo',
                  child: GestureDetector(
                    onTap: onCover,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (cover != null && api != null)
                          AppNetworkImage(api.apiUrlOf(cover.substring(4)), headers: api.authHeaders, width: w, height: top + coverHeight, fallback: PlaceArt(seed: name, borderRadius: BorderRadius.zero))
                        else
                          PlaceArt(seed: name, borderRadius: BorderRadius.zero),
                        if (cover == null && onCover != null)
                          Align(
                            alignment: const Alignment(0, -0.25),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(999)),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                if (coverBusy)
                                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                else
                                  const Icon(Icons.photo_camera_outlined, color: Colors.white, size: 18),
                                const SizedBox(width: 8),
                                const Text('Add a cover photo', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                              ]),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(left: 16, top: top + 8, child: DsRoundButton(icon: Icons.chevron_left_rounded, label: 'Back', size: 48, onTap: onBack)),
              Positioned(
                right: 16,
                top: top + 8,
                child: Material(
                  color: AppTheme.card,
                  shape: CircleBorder(side: BorderSide(color: AppTheme.border)),
                  child: IconButton(
                    key: const Key('profile_settings'),
                    tooltip: SettingsScreen.title,
                    icon: Icon(Icons.settings_outlined, color: AppTheme.text),
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    onPressed: onSettings,
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: top + coverHeight - avatarSize / 2,
                child: Center(
                  child: Container(
                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: AppTheme.bg, width: 4)),
                    child: Pressable(onTap: onOpen, semanticsLabel: 'Your profile', child: UserAvatar(label: name, avatarUrl: avatarUrl, size: avatarSize, filled: true)),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.s12),
        Semantics(
          button: true,
          label: 'Your profile',
          child: InkWell(
            onTap: onOpen,
            borderRadius: Radii.mdAll,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Column(
                children: [
                  Text(name, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.headline.copyWith(fontSize: 24)),
                  if (handle.isNotEmpty) Text(handle, key: const Key('profile_username'), style: AppText.label),
                  if (since.isNotEmpty) ...[const SizedBox(height: 2), Text(since, style: AppText.caption)],
                  if (isAdmin) ...[const SizedBox(height: 6), const DsChip('Admin')],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ChecklistCard extends StatelessWidget {
  final ChecklistResult result;
  final ValueChanged<ChecklistItem> onTap;
  const _ChecklistCard({required this.result, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return DsCard(
      key: const Key('profile_checklist'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(AccountScreen.checklistTitle, style: AppText.title)),
              Text(result.summary, style: AppText.label),
            ],
          ),
          const SizedBox(height: 4),
          Text('Safety first: these help riders and responders reach you.', style: AppText.caption),
          const SizedBox(height: 10),
          Semantics(
            label: 'Profile ${(result.progress * 100).round()} percent complete',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(value: result.progress, minHeight: 8, color: AppTheme.primary, backgroundColor: AppTheme.soft),
            ),
          ),
          const SizedBox(height: 6),
          for (final (item, done) in result.items)
            Semantics(
              button: !done,
              checked: done,
              label: item.label,
              excludeSemantics: true,
              child: InkWell(
                key: Key('check_${item.key}'),
                onTap: done ? null : () => onTap(item),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Row(
                    children: [
                      Icon(done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, color: done ? AppTheme.success : AppTheme.border2, size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          item.label,
                          style: AppText.body.copyWith(color: done ? AppTheme.text2 : AppTheme.text, decoration: done ? TextDecoration.lineThrough : null, decorationColor: AppTheme.text2),
                        ),
                      ),
                      if (item.safety && !done) Icon(Icons.shield_outlined, size: 18, color: AppTheme.accentText),
                      if (!done) Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Riding style (one) and interests (several), kept on this phone. Pops (interests, style).
class _PreferencesEditor extends StatefulWidget {
  final List<String> interests;
  final String style;
  const _PreferencesEditor({required this.interests, required this.style});

  @override
  State<_PreferencesEditor> createState() => _PreferencesEditorState();
}

class _PreferencesEditorState extends State<_PreferencesEditor> {
  late final Set<String> _picked = {...widget.interests};
  late String _style = widget.style;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Riding style', style: AppText.overline),
        const SizedBox(height: Space.s8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final s in RidingChecklist.styleChoices)
            ChoiceChip(label: Text(s), selected: _style == s, onSelected: (on) => setState(() => _style = on ? s : '')),
        ]),
        const SizedBox(height: Space.s16),
        Text('Riding interests', style: AppText.overline),
        const SizedBox(height: Space.s8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final i in RidingChecklist.interestChoices)
            FilterChip(label: Text(i), selected: _picked.contains(i), onSelected: (on) => setState(() => on ? _picked.add(i) : _picked.remove(i))),
        ]),
        const SizedBox(height: Space.s8),
        Text('Kept on this phone. Used to suggest rides on Explore.', style: AppText.caption),
        const SizedBox(height: Space.s16),
        DsButton(label: 'Save', onPressed: () => Navigator.pop(context, ([for (final i in RidingChecklist.interestChoices) if (_picked.contains(i)) i], _style))),
        const SizedBox(height: Space.s8),
      ],
    );
  }
}
