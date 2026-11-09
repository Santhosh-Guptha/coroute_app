import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/membership_service.dart';
import '../../data/services/meta_service.dart';
import '../../data/services/settings_service.dart';
import '../../data/services/trip_storage_service.dart';
import '../admin/master_admin_dashboard.dart';
import '../auth/access_gate_screen.dart';
import '../rider/rider_home_screen.dart';
import '../rider/trip_history_screen.dart';
import '../settings/settings_screen.dart';
import 'change_password_screen.dart';
import 'edit_profile_screen.dart';
import '../subscription/payment_history_screen.dart';
import '../subscription/membership_dashboard_screen.dart';
import '../../data/models/membership_model.dart';
import '../garage/garage_screen.dart';
import '../analytics/ride_analytics_screen.dart';
import '../feedback/suggest_feature_screen.dart';
import '../../data/services/friends_service.dart';
import '../../data/services/crews_service.dart';
import '../score/rider_score_card.dart';
import '../social/profile_screen.dart';

/// The Profile tab: who you are, your bike, emergency contact and plan, your
/// ride analytics, one row into Settings (every rider setting is there), help
/// and the account.
class AccountScreen extends StatelessWidget {
  /// True when shown as the Profile tab (no back button).
  final bool embedded;
  const AccountScreen({super.key, this.embedded = false});

  Future<void> _open(BuildContext context, String url) async {
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  void _push(BuildContext context, Widget screen) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1);
    return parts.first.substring(0, 1) + parts.last.substring(0, 1);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final meta = context.watch<MetaService>().meta;
    final settings = context.watch<SettingsService?>();
    final trips = context.watch<TripStorageService?>();
    final social = context.watch<FriendsService?>();
    // 3.55 crews: invitations + polls to answer join the friends badge on the profile row.
    final socialBadge = (social?.badgeCount ?? 0) + (context.watch<CrewsService?>()?.badgeCount ?? 0);
    final base = AppConfig.apiBaseUrl;
    final privacyUrl = meta?.privacyUrl.isNotEmpty == true ? meta!.privacyUrl : '$base/privacy';
    final termsUrl = meta?.termsUrl.isNotEmpty == true ? meta!.termsUrl : '$base/terms';
    final support = meta?.supportEmail ?? '';
    final name = (auth.currentUserName ?? '').trim();
    final email = (auth.currentUserEmail ?? '').trim();
    final vehicleType = (auth.vehicleType ?? '').trim();
    final plate = (auth.vehicleNo ?? '').trim();
    final contactName = (auth.emergencyContactName ?? '').trim();
    final contactPhone = (auth.emergencyContact ?? '').trim();
    final contactSet = contactPhone.length >= 7 && contactName.length >= 2;
    final analytics = trips == null ? null : HomeAnalytics.of(trips.trips);

    final bikeTitle = auth.isPillion ? 'Pillion' : (vehicleType.isNotEmpty ? vehicleType : 'Your bike');
    final memService = context.watch<MembershipService?>();
    final access = (memService?.planAccess ?? PlanAccess.community).current;

    final bikeFacts = <String>[
      if (!auth.isPillion && plate.isNotEmpty) plate,
      if (auth.isPillion) 'No bike registration needed',
      if (settings != null && settings.fuelRangeKm > 0) '${settings.fuelRangeKm} km range',
      'All your bikes',
    ];

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
                DsScreenHeader(
                  title: 'Profile',
                  onBack: embedded ? null : () => Navigator.maybePop(context),
                  trailing: DsRoundButton(
                    icon: Icons.edit_rounded,
                    label: 'Edit profile',
                    size: 48,
                    onTap: () => _push(context, const EditProfileScreen()),
                  ),
                ),
                const SizedBox(height: 18),

                // Who you are: one tap opens the one profile editor.
                DsCard(
                  radius: Radii.xl,
                  padding: const EdgeInsets.all(18),
                  onTap: () => _push(context, const EditProfileScreen()),
                  semanticsLabel: 'Edit profile',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          DsAvatar(_initials(name.isEmpty ? '?' : name), size: 56, filled: true),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(name.isEmpty ? 'Your name' : name,
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.headline.copyWith(fontSize: 20)),
                                if (email.isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Text(email, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
                                ],
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: [
                                    if (auth.isPillion) const DsChip('Pillion') else const DsChip('Rider'),
                                    if (auth.isMasterAdmin) const DsChip('Admin'),
                                    if (settings != null && settings.crashDetection) const DsChip('Guardian on'),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Icon(
                            contactSet ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                            size: 16,
                            color: contactSet ? AppTheme.accentText : AppTheme.warnText,
                          ),
                          const SizedBox(width: Space.s4),
                          Flexible(
                            child: Text(
                              contactSet ? 'Emergency contact: set' : 'Emergency contact: not set',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.caption.copyWith(
                                fontWeight: FontWeight.w700,
                                color: contactSet ? AppTheme.text2 : AppTheme.warnText,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (analytics != null) ...[
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(child: DsStatCell(label: 'Rides', value: '${analytics.rides}')),
                            const SizedBox(width: 8),
                            Expanded(child: DsStatCell(label: 'Distance', value: formatDistance(analytics.totalDistanceKm * 1000))),
                            const SizedBox(width: 8),
                            Expanded(
                              child: DsStatCell(
                                label: 'Riding time',
                                value: formatDuration(Duration(minutes: analytics.totalMinutes)),
                                valueColor: AppTheme.accentText,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: Space.s24),
                const DsSectionHeader('My bikes'),
                const SizedBox(height: Space.s12),
                DsCard(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                  onTap: () => _push(context, const GarageScreen()),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(color: AppTheme.tint, borderRadius: BorderRadius.circular(14)),
                        child: Icon(
                          auth.isPillion ? Icons.airline_seat_recline_normal_rounded : Icons.two_wheeler_rounded,
                          size: 26,
                          color: AppTheme.accentText,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(bikeTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 15)),
                            if (bikeFacts.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(bikeFacts.join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _SquareButton(icon: Icons.garage_rounded, label: 'Garage', onTap: () => _push(context, const GarageScreen())),
                    ],
                  ),
                ),

                const SizedBox(height: Space.s24),
                const DsSectionHeader('Emergency contact'),
                const SizedBox(height: Space.s12),
                DsCard(
                  padding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
                  onTap: () => _push(context, const EditProfileScreen()),
                  semanticsLabel: contactSet ? 'Emergency contact $contactName, edit' : 'Add an emergency contact',
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 54),
                    child: Row(
                      children: [
                        if (contactSet)
                          Container(
                            width: 36,
                            height: 36,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(color: AppTheme.tint, shape: BoxShape.circle),
                            child: Text(
                              _initials(contactName).toUpperCase(),
                              textScaler: TextScaler.noScaling,
                              style: TextStyle(color: AppTheme.accentText, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          )
                        else
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(color: AppTheme.warnTint, shape: BoxShape.circle),
                            child: Icon(Icons.person_add_alt_1_rounded, size: 18, color: AppTheme.warnText),
                          ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                contactSet ? contactName : 'Add an emergency contact',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.body.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                contactSet ? contactPhone : 'Your SOS screen calls or texts this person.',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.caption,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (contactSet)
                          Text('PRIMARY', style: TextStyle(color: AppTheme.accentText, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1))
                        else
                          Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
                      ],
                    ),
                  ),
                ),

                if (memService?.paymentsEnabled == true) ...[
                  const SizedBox(height: Space.s24),
                  const DsSectionHeader('Membership & plans'),
                  const SizedBox(height: Space.s12),
                  DsCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Column(
                      children: [
                        _SettingsRow(
                          icon: Icons.card_membership_rounded,
                          title: 'Membership & plans',
                          subtitle: access.isPaid
                              ? access.statusLine()
                              : (memService != null && memService.participating.isNotEmpty
                                  ? 'Group member · Free for you'
                                  : access.statusLine(groupFromPrice: memService?.groupFromPrice)),
                          value: access.isPaid
                              ? (access.isLegacy ? 'LEGACY' : 'ACTIVE')
                              : (memService != null && memService.participating.isNotEmpty ? 'PARTICIPANT' : 'FREE'),
                          color: AppTheme.accentText,
                          divider: true,
                          onTap: () => _push(context, const MembershipDashboardScreen()),
                        ),
                        _SettingsRow(
                          icon: Icons.receipt_long_rounded,
                          title: 'Payments & plan history',
                          subtitle: 'Past plans and payments',
                          divider: false,
                          onTap: () => _push(context, const PaymentHistoryScreen()),
                        ),
                      ],
                    ),
                  ),
                ],
                // 3.55 rider score card (hides itself when the riderScore switch is off).
                const SizedBox(height: Space.s24),
                const RiderScoreCard(),
                // Every rider setting lives on the one Settings screen.
                const SizedBox(height: Space.s24),
                DsCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: [
                      // 3.55 public profile: username, picture, totals, friends (badge = new requests).
                      if (social != null)
                        _SettingsRow(
                          key: const Key('profile_public_profile'),
                          icon: Icons.account_circle_rounded,
                          title: 'My profile & friends',
                          subtitle: auth.username.isEmpty ? 'Username, picture and friends' : auth.username,
                          value: socialBadge > 0 ? '$socialBadge new' : null,
                          color: socialBadge > 0 ? AppTheme.warnText : null,
                          onTap: () => MyProfileScreen.open(context),
                        ),
                      _SettingsRow(
                        key: const Key('profile_ride_analytics'),
                        icon: Icons.insights_rounded,
                        title: 'Your ride analytics',
                        subtitle: 'Calculated on your phone. Only you can see this.',
                        onTap: () => RideAnalyticsScreen.open(context),
                      ),
                      _SettingsRow(
                        key: const Key('profile_settings'),
                        icon: Icons.settings_rounded,
                        title: SettingsScreen.title,
                        subtitle: 'Ride, safety, voice, map and privacy',
                        // Reflects the real switch, so a rider never misses that crash detection is off.
                        value: settings == null || settings.crashDetection ? null : 'Crash detection off',
                        color: settings != null && !settings.crashDetection ? AppTheme.warnText : null,
                        divider: false,
                        onTap: () => SettingsScreen.open(context),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: Space.s24),
                const DsSectionHeader('App'),
                const SizedBox(height: Space.s12),
                DsCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: [
                      _SettingsRow(
                        icon: Icons.password_rounded,
                        title: 'Change password',
                        onTap: () => _push(context, const ChangePasswordScreen()),
                        divider: auth.isMasterAdmin,
                      ),
                      if (auth.isMasterAdmin)
                        _SettingsRow(
                          icon: Icons.admin_panel_settings_rounded,
                          title: 'Admin',
                          subtitle: 'Live rides, history and users',
                          // One admin console for phones and tablets (it adapts its layout).
                          onTap: () => _push(context, const MasterAdminDashboard()),
                          divider: false,
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: Space.s24),
                const DsSectionHeader('Help'),
                const SizedBox(height: Space.s12),
                DsCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: [
                      _SettingsRow(
                        icon: Icons.bug_report_rounded,
                        title: 'Report a problem',
                        subtitle: 'We reply by e-mail.',
                        onTap: () => _push(context, const ReportProblemScreen()),
                      ),
                      _SettingsRow(
                        key: const Key('profile_suggest_feature'),
                        icon: Icons.lightbulb_outline_rounded,
                        title: 'Suggest a safety feature',
                        subtitle: 'Your ideas shape what we build next',
                        onTap: () => SuggestFeatureScreen.open(context),
                      ),
                      _SettingsRow(icon: Icons.privacy_tip_rounded, title: 'Privacy policy', onTap: () => _open(context, privacyUrl)),
                      _SettingsRow(icon: Icons.gavel_rounded, title: 'Terms of use', onTap: () => _open(context, termsUrl), divider: false),
                    ],
                  ),
                ),

                const SizedBox(height: Space.s24),
                const DsSectionHeader('Account'),
                const SizedBox(height: Space.s12),
                DsCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: [
                      _SettingsRow(
                        icon: Icons.logout_rounded,
                        title: 'Sign out',
                        chevron: false,
                        onTap: () async {
                          await auth.logout();
                          if (context.mounted) {
                            Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const AccessGateScreen()), (_) => false);
                          }
                        },
                      ),
                      _SettingsRow(
                        icon: Icons.delete_forever_rounded,
                        title: 'Delete my account',
                        subtitle: 'Removes your account, profile and ride history.',
                        color: AppTheme.sos,
                        chevron: false,
                        divider: false,
                        onTap: () => _confirmDelete(context),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                DsButton(
                  label: 'Ride history',
                  icon: Icons.history_rounded,
                  tone: DsButtonTone.outline,
                  onPressed: () {
                    if (embedded) {
                      RiderHomeScreen.selectTab(context, HomeTab.trips);
                    } else {
                      _push(context, const TripHistoryScreen());
                    }
                  },
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

/// A settings row inside a [DsCard] list (canvas "More" rows): teal icon,
/// 15/700 label with an optional 12/600 line under it, a muted value or a
/// chevron on the right, and a hairline under it.
class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? value;
  final VoidCallback? onTap;
  final Color? color;
  final bool chevron;
  final bool divider;

  const _SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.onTap,
    this.color,
    this.chevron = true,
    this.divider = true,
  });

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    final v = value;
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
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700, color: color ?? AppTheme.text)),
                if (sub != null && sub.isNotEmpty) Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption),
              ],
            ),
          ),
          if (v != null && v.isNotEmpty) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(v, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.end, style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
            ),
          ],
          if (chevron && onTap != null) Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

/// 48 px square button on a soft fill (canvas "Edit bike").
class _SquareButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SquareButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: AppTheme.soft,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(width: 48, height: 48, child: Icon(icon, size: 20, color: AppTheme.text)),
        ),
      ),
    );
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

/// In-app problem report. Posts to the same endpoint as the website form and
/// adds the app version and platform so reports are actionable.
class ReportProblemScreen extends StatefulWidget {
  const ReportProblemScreen({super.key});

  @override
  State<ReportProblemScreen> createState() => _ReportProblemScreenState();
}

class _ReportProblemScreenState extends State<ReportProblemScreen> {
  final _message = TextEditingController();
  bool _busy = false;
  String? _error;
  final int _openedAt = DateTime.now().millisecondsSinceEpoch;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _message.text.trim();
    if (text.length < 20) {
      setState(() => _error = 'Please describe the problem in at least 20 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = context.read<AuthService>();
    final device = kIsWeb ? 'web' : '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    try {
      await context.read<ApiClient>().post('/feedback', {
        'name': auth.currentUserName ?? '',
        'email': auth.currentUserEmail ?? '',
        'message': text,
        't': _openedAt,
        'appVersion': '${MetaService.currentVersion}+${MetaService.currentBuild}',
        'device': device,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Thanks. Your report was sent.')));
      Navigator.pop(context);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Could not send right now. Please try again later.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              physics: const BouncingScrollPhysics(),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: dsScreenPadding,
              children: [
                DsScreenHeader(title: 'Report a problem', onBack: () => Navigator.maybePop(context)),
                const SizedBox(height: 18),
                Text(
                  'Tell us what happened and on which screen. We add your e-mail and app version so we can reply.',
                  style: AppText.label,
                ),
                const SizedBox(height: Space.s12),
                TextField(
                  controller: _message,
                  minLines: 6,
                  maxLines: 12,
                  maxLength: 2000,
                  style: AppText.body,
                  decoration: InputDecoration(
                    hintText: 'Describe the problem',
                    counterStyle: AppText.caption,
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: Space.s8),
                  RideAlert(tier: AlertTier.important, title: _error!),
                ],
                const SizedBox(height: 16),
                DsButton(
                  label: _busy ? 'Sending...' : 'Send report',
                  icon: _busy ? null : Icons.send_rounded,
                  onPressed: _busy ? null : _send,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
