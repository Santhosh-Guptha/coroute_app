import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/friends_service.dart';
import '../../data/services/meta_service.dart';
import '../admin/master_admin_dashboard.dart';
import '../auth/access_gate_screen.dart';
import '../engagement/rate_and_feedback.dart';
import '../garage/garage_screen.dart';
import '../score/leaderboard_screen.dart';
import '../score/rider_score_card.dart';
import '../settings/settings_screen.dart';
import '../social/profile_screen.dart';
import '../social/user_avatar.dart';
import '../widgets/feature_switch.dart';
import 'edit_profile_screen.dart';
import 'privacy_terms_sheet.dart';

/// The Profile tab, minimal (owner direction, Nov 11; docs/SETTINGS_MINIMAL_v3.55.md):
///  * Top box: picture, full name and @username; tap opens the profile details (My profile:
///    picture, name, username, stats). The gear in the box opens Settings.
///  * My bikes (garage), Emergency contact & Medical ID.
///  * Rider score card and a Leaderboard row.
///  * Help: Send feedback (report a problem, suggest a safety feature, other; optional diagnostics
///    log; Diagnostics is reached from there), Rate CoRoute, Privacy & terms.
///  * Account: Sign out and Delete account.
/// No plan information (Play payments policy + owner decision) and no ride history here (that is
/// the Trips tab). Friends and crews live in the People tab.
class AccountScreen extends StatelessWidget {
  /// True when shown as the Profile tab (no back button).
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

  /// Keys of the Help rows, in order (tests check there are exactly these).
  static const List<String> helpRowKeys = ['profile_send_feedback', 'profile_rate_coroute', 'profile_privacy_terms'];

  /// Keys of the Account rows, in order.
  static const List<String> accountRowKeys = ['profile_sign_out', 'profile_delete_account'];

  void _push(BuildContext context, Widget screen) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  /// "@asha_rides", or empty while the username is unknown (pure, for tests).
  static String handleOf(String username) {
    final u = username.trim();
    if (u.isEmpty) return '';
    return u.startsWith('@') ? u : '@$u';
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
    final handle = handleOf(username);
    final photosOn = context.featureOn(FriendsService.photosFlag);
    final contactName = (auth.emergencyContactName ?? '').trim();
    final contactPhone = (auth.emergencyContact ?? '').trim();
    final contactSet = contactPhone.length >= 7;
    final medicalSet = auth.bloodGroup.isNotEmpty || auth.medicalNotes.isNotEmpty;
    final leaderboardOn = context.featureOn('leaderboard');

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: dsScreenPadding,
              children: [
                DsScreenHeader(title: 'Profile', onBack: embedded ? null : () => Navigator.maybePop(context)),
                const SizedBox(height: 18),

                // Who you are: tap opens the profile details; the gear opens Settings.
                DsCard(
                  key: const Key('profile_top_box'),
                  radius: Radii.xl,
                  padding: const EdgeInsets.fromLTRB(18, 16, 8, 16),
                  onTap: () => social != null ? MyProfileScreen.open(context) : _push(context, const EditProfileScreen()),
                  semanticsLabel: 'Your profile',
                  child: Row(
                    children: [
                      UserAvatar(
                        label: name.isNotEmpty ? name : (username.isNotEmpty ? username : '?'),
                        avatarUrl: photosOn ? profile?.avatarUrl : null,
                        size: 56,
                        filled: true,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(name.isEmpty ? 'Your name' : name,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.headline.copyWith(fontSize: 20)),
                            if (handle.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(handle, key: const Key('profile_username'), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
                            ],
                            if (auth.isMasterAdmin) ...[
                              const SizedBox(height: 6),
                              const DsChip('Admin'),
                            ],
                          ],
                        ),
                      ),
                      IconButton(
                        key: const Key('profile_settings'),
                        tooltip: SettingsScreen.title,
                        icon: Icon(Icons.settings_rounded, color: AppTheme.text2),
                        iconSize: 26,
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        onPressed: () => SettingsScreen.open(context),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: Space.s24),
                DsCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: [
                      _SettingsRow(
                        key: const Key('profile_garage'),
                        icon: auth.isPillion ? Icons.airline_seat_recline_normal_rounded : Icons.two_wheeler_rounded,
                        title: garageTitle,
                        onTap: () => _push(context, const GarageScreen()),
                      ),
                      _SettingsRow(
                        key: const Key('profile_emergency'),
                        icon: contactSet ? Icons.contact_emergency_rounded : Icons.person_add_alt_1_rounded,
                        title: emergencyTitle,
                        subtitle: '${contactSet ? (contactName.isNotEmpty ? contactName : contactPhone) : 'Add a contact'} · '
                            '${medicalSet ? 'Medical ID set' : 'No Medical ID'}',
                        // Amber until a contact is set: the SOS screen calls or texts this person.
                        color: contactSet ? null : AppTheme.warnText,
                        divider: false,
                        onTap: () => _push(context, const EditProfileScreen()),
                      ),
                    ],
                  ),
                ),

                // 3.55 rider score card (hides itself when the riderScore switch is off).
                const SizedBox(height: Space.s24),
                const RiderScoreCard(),
                if (leaderboardOn) ...[
                  const SizedBox(height: Space.s12),
                  DsCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: _SettingsRow(
                      key: const Key('profile_tab_leaderboard'),
                      icon: Icons.emoji_events_rounded,
                      title: leaderboardTitle,
                      divider: false,
                      onTap: () => LeaderboardScreen.open(context),
                    ),
                  ),
                ],

                if (auth.isMasterAdmin) ...[
                  const SizedBox(height: Space.s24),
                  DsCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: _SettingsRow(
                      icon: Icons.admin_panel_settings_rounded,
                      title: 'Admin',
                      subtitle: 'Live rides, history and users',
                      // One admin console for phones and tablets (it adapts its layout).
                      onTap: () => _push(context, const MasterAdminDashboard()),
                      divider: false,
                    ),
                  ),
                ],

                const SizedBox(height: Space.s24),
                const DsSectionHeader(helpTitle),
                const SizedBox(height: Space.s12),
                DsCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: [
                      // One screen: report a problem, suggest a safety feature, other (+ diagnostics log).
                      _SettingsRow(
                        key: Key(helpRowKeys[0]),
                        icon: Icons.chat_bubble_outline_rounded,
                        title: RateAndFeedback.feedbackTitle,
                        onTap: () => RateAndFeedback.openFeedback(context),
                      ),
                      // 3.55 ratings & reviews: straight to Google Play's in-app review (no "do you like us?").
                      _SettingsRow(
                        key: Key(helpRowKeys[1]),
                        icon: Icons.star_outline_rounded,
                        title: RateAndFeedback.rateTitle,
                        onTap: () => RateAndFeedback.rate(context),
                      ),
                      _SettingsRow(
                        key: Key(helpRowKeys[2]),
                        icon: Icons.privacy_tip_rounded,
                        title: PrivacyTermsSheet.title,
                        divider: false,
                        onTap: () => PrivacyTermsSheet.show(context, meta),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: Space.s24),
                const DsSectionHeader(accountTitle),
                const SizedBox(height: Space.s12),
                DsCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: [
                      _SettingsRow(
                        key: Key(accountRowKeys[0]),
                        icon: Icons.logout_rounded,
                        title: signOutTitle,
                        chevron: false,
                        onTap: () async {
                          await auth.logout();
                          if (context.mounted) {
                            Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const AccessGateScreen()), (_) => false);
                          }
                        },
                      ),
                      _SettingsRow(
                        key: Key(accountRowKeys[1]),
                        icon: Icons.delete_forever_rounded,
                        title: deleteTitle,
                        color: AppTheme.sos,
                        chevron: false,
                        divider: false,
                        onTap: () => _confirmDelete(context),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Space.s24),
                Text(
                  'CoRoute ${MetaService.currentVersion} (build ${MetaService.currentBuild})${support.isNotEmpty ? ', $support' : ''}',
                  style: AppText.caption,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

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
    final res = await context.read<AuthService>().deleteAccount();
    if (!context.mounted) return;
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
