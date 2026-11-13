import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/friends_service.dart';
import '../../data/services/garage_service.dart';
import '../../domain/media/avatar_crop.dart';
import '../../domain/social/username_rules.dart';
import '../account/change_password_screen.dart';
import '../account/edit_profile_screen.dart';
import '../score/leaderboard_screen.dart';
import '../score/rider_score_card.dart';
import '../widgets/feature_switch.dart';
import 'avatar_crop_screen.dart';
import 'people_screen.dart';
import 'user_avatar.dart';

/// 3.55 my profile: picture, username (changeable once per 30 days), full name and ride analytics
/// (trips, km, riding hours, longest trip, largest group, member since, bikes) and the rider score card.
/// Privacy: the username and picture are what other riders and the website leaderboard see.
class MyProfileScreen extends StatefulWidget {
  const MyProfileScreen({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => const MyProfileScreen()));

  @override
  State<MyProfileScreen> createState() => _MyProfileScreenState();
}

class _MyProfileScreenState extends State<MyProfileScreen> {
  bool _busyPhoto = false;

  @override
  void initState() {
    super.initState();
    GarageService.shared.load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<FriendsService>().refreshAll();
    });
  }

  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  static String? mimeOf(Uint8List b) {
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
    if (b.length >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return 'image/png';
    if (b.length >= 12 && String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' && String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') {
      return 'image/webp';
    }
    return null;
  }

  /// 3.56: "Adjust picture" (the uploaded picture again), a new picture (through the same cropper)
  /// or Remove. docs/features_355/profile_photo_adjust.md
  Future<void> _pickPhoto(FriendsService svc) async {
    final hasPhoto = svc.profile?.avatarUrl != null;
    final choice = await showAppSheet<String>(
      context,
      title: 'Profile picture',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasPhoto) DsListRow(icon: Icons.crop_rotate_rounded, label: 'Adjust picture', onTap: () => Navigator.pop(ctx, 'adjust')),
          DsListRow(icon: Icons.photo_camera_rounded, label: 'Take a new photo', onTap: () => Navigator.pop(ctx, 'camera')),
          DsListRow(icon: Icons.photo_library_rounded, label: 'Choose a new picture', onTap: () => Navigator.pop(ctx, 'gallery'), divider: hasPhoto),
          if (hasPhoto) DsListRow(icon: Icons.delete_outline_rounded, label: 'Remove picture', divider: false, onTap: () => Navigator.pop(ctx, 'remove')),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => _busyPhoto = true);
    String? problem;
    try {
      if (choice == 'remove') {
        problem = await svc.removeAvatar();
      } else if (choice == 'adjust') {
        final src = await svc.adjustSource();
        if (!mounted) return;
        if (src == null) {
          problem = 'Your picture could not be loaded. Check your connection and try again.';
        } else {
          final saved = await _openCropper(
            svc,
            src.bytes,
            initialCrop: src.crop,
            // An older picture has no kept original: the current one becomes the original now.
            keepOriginal: !src.fromOriginal,
            note: src.fromOriginal ? null : 'The original of this picture was not kept, so you are adjusting the current picture. Choose a new picture for full quality.',
          );
          if (saved && mounted) _say('Picture saved');
        }
      } else {
        Uint8List? bytes;
        try {
          // Downsized on the phone (2048 px at most): the cropper works on it and it is kept as the
          // original for later adjusting. Camera metadata is not asked for and is removed on save.
          final f = await ImagePicker().pickImage(
            source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
            maxWidth: 2048,
            maxHeight: 2048,
            imageQuality: 90,
            requestFullMetadata: false,
            preferredCameraDevice: CameraDevice.front,
          );
          if (f != null) bytes = await f.readAsBytes();
        } catch (_) {
          problem = choice == 'camera' ? 'Could not open the camera.' : 'Could not open your photos.';
        }
        if (!mounted) return;
        if (bytes != null) {
          if (mimeOf(bytes) == null) {
            problem = 'Use a JPEG, PNG or WebP picture.';
          } else {
            final saved = await _openCropper(svc, bytes);
            if (saved && mounted) _say('Picture saved');
          }
        }
      }
    } finally {
      if (mounted) setState(() => _busyPhoto = false);
    }
    if (!mounted) return;
    if (problem != null) _say(problem);
  }

  Future<bool> _openCropper(FriendsService svc, Uint8List bytes, {AvatarCrop? initialCrop, bool keepOriginal = true, String? note}) {
    return AvatarCropScreen.open(
      context,
      bytes: bytes,
      initialCrop: initialCrop,
      keepOriginal: keepOriginal,
      note: note,
      onSave: (r) => svc.saveAdjustedAvatar(
        cropped: r.cropped.bytes,
        croppedMime: r.cropped.mime,
        crop: r.crop,
        original: r.original?.bytes,
        originalMime: r.original?.mime,
      ),
    );
  }

  Future<void> _editUsername(FriendsService svc) async {
    final p = svc.profile;
    if (p == null) return;
    final saved = await showAppSheet<bool>(
      context,
      title: 'Your username',
      isScrollControlled: true,
      builder: (_) => UsernameEditor(service: svc, current: p.username, nextChange: p.nextUsernameChange),
    );
    if (saved == true && mounted) _say('Username saved');
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<FriendsService>();
    final p = svc.profile;
    final s = svc.stats;
    final photosOn = context.featureOn(FriendsService.photosFlag);
    final friendsOn = context.featureOn(FriendsService.friendsFlag);
    final leaderboardOn = context.featureOn('leaderboard');
    final since = p?.memberSince ?? s.memberSince;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: RefreshIndicator(
              onRefresh: svc.refreshAll,
              child: ListView(
                padding: dsScreenPadding,
                children: [
                  TopProgressLine(active: svc.loading && p != null), // round 7: refreshing in place
                  DsScreenHeader(title: 'My profile', onBack: () => Navigator.maybePop(context)),
                  const SizedBox(height: 18),
                  if (p == null && svc.loading)
                    const SkeletonProfile(cards: 2) // round 7: shaped like the profile
                  else if (p == null)
                    DsCard(child: Text('Your profile could not be loaded. Pull down to try again.', style: AppText.body))
                  else ...[
                    DsCard(
                      radius: Radii.xl,
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        children: [
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              UserAvatar(label: p.username, avatarUrl: photosOn ? p.avatarUrl : null, size: 96, filled: true),
                              if (photosOn)
                                Positioned(
                                  right: -6,
                                  bottom: -6,
                                  child: DsRoundButton(
                                    icon: _busyPhoto ? Icons.hourglass_top_rounded : Icons.photo_camera_rounded,
                                    label: 'Change profile picture',
                                    size: 44,
                                    onTap: _busyPhoto ? () {} : () => _pickPhoto(svc),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Flexible(
                                child: Text(p.username,
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.headline.copyWith(fontSize: 22)),
                              ),
                              IconButton(
                                tooltip: 'Change username',
                                icon: const Icon(Icons.edit_rounded, size: 20),
                                onPressed: () => _editUsername(svc),
                              ),
                            ],
                          ),
                          if (p.name.isNotEmpty) Text(p.name, style: AppText.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 6),
                          Text('Other riders see your username and picture, never your phone or e-mail.',
                              textAlign: TextAlign.center, style: AppText.caption.copyWith(color: AppTheme.text2)),
                        ],
                      ),
                    ),
                    const SizedBox(height: Space.s24),
                    // 3.55 rider score: the one score display on the profile (opens tips and the leaderboard).
                    const RiderScoreCard(),
                    const SizedBox(height: Space.s24),
                    const DsSectionHeader('Ride analytics'),
                    const SizedBox(height: Space.s12),
                    _StatsGrid(cells: [
                      ('Trips', '${s.trips}'),
                      ('Distance', formatKm(s.totalKm)),
                      ('Riding hours', s.ridingHours % 1 == 0 ? '${s.ridingHours.toInt()} h' : '${s.ridingHours.toStringAsFixed(1)} h'),
                      ('Longest trip', formatKm(s.longestTripKm)),
                      ('Largest group', s.largestGroup > 0 ? '${s.largestGroup} riders' : '-'),
                      ('Member since', since > 0 ? DateFormat.yMMM().format(DateTime.fromMillisecondsSinceEpoch(since)) : '-'),
                    ], garage: true),
                    const SizedBox(height: Space.s24),
                    const DsSectionHeader('Privacy'),
                    const SizedBox(height: Space.s12),
                    DsCard(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Column(
                        children: [
                          DsSwitchRow(
                            key: const Key('profile_public_leaderboard'),
                            label: 'Show my username on public leaderboards',
                            subtitle: 'Only your username and rounded totals are shown on the CoRoute website.',
                            value: p.publicLeaderboard,
                            divider: friendsOn || leaderboardOn,
                            onChanged: (v) async {
                              final err = await svc.setPublicLeaderboard(v);
                              if (err != null && mounted) _say(err);
                            },
                          ),
                          if (friendsOn)
                            DsSwitchRow(
                              key: const Key('profile_discoverable'),
                              label: 'Let riders find me',
                              subtitle: 'Search by username and "People you rode with". Off: only your exact username finds you.',
                              value: p.discoverable,
                              divider: leaderboardOn,
                              onChanged: (v) async {
                                final err = await svc.setDiscoverable(v);
                                if (err != null && mounted) _say(err);
                              },
                            ),
                          if (leaderboardOn)
                            DsListRow(
                              key: const Key('profile_leaderboard'),
                              icon: Icons.emoji_events_rounded,
                              label: 'Leaderboard',
                              divider: false,
                              onTap: () => LeaderboardScreen.open(context),
                            ),
                        ],
                      ),
                    ),
                    // 3.55 People hub: friends, crews and every request live there (one tap from the
                    // bottom bar); this row is a shortcut with the same badge.
                    if (friendsOn || context.featureOn('crews')) ...[
                      const SizedBox(height: Space.s24),
                      DsCard(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        child: Builder(builder: (context) {
                          final b = peopleBadgesOf(context);
                          return DsListRow(
                            key: const Key('profile_people'),
                            icon: Icons.people_alt_rounded,
                            label: 'Friends & crews',
                            value: b.total > 0 ? '${b.total} new' : '${svc.friends.length}',
                            valueColor: b.total > 0 ? AppTheme.warnText : null,
                            divider: false,
                            onTap: () => PeopleScreen.open(context, segment: b.requests > 0 ? PeopleSegment.requests : PeopleSegment.friends),
                          );
                        }),
                      ),
                    ],
                  ],
                  // Moved here from the Profile tab (Nov 11): the details editor and the password.
                  const SizedBox(height: Space.s24),
                  DsCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Column(
                      children: [
                        DsListRow(
                          key: const Key('profile_edit_details'),
                          icon: Icons.edit_rounded,
                          label: 'Edit details',
                          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const EditProfileScreen())),
                        ),
                        DsListRow(
                          key: const Key('profile_change_password'),
                          icon: Icons.password_rounded,
                          label: 'Change password',
                          divider: false,
                          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ChangePasswordScreen())),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  final List<(String, String)> cells;
  final bool garage;
  const _StatsGrid({required this.cells, this.garage = false});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: GarageService.shared.bikesNotifier,
      builder: (context, bikes, _) {
        final all = [...cells, if (garage) ('Bikes in garage', '${bikes.length}')];
        return LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth >= 480 ? 3 : 2;
          final w = (c.maxWidth - (cols - 1) * 8) / cols;
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final cell in all) SizedBox(width: w, child: DsStatCell(label: cell.$1, value: cell.$2))],
          );
        });
      },
    );
  }
}

/// Username editor: local rules at once, server availability after a pause, then save.
class UsernameEditor extends StatefulWidget {
  final FriendsService service;
  final String current;
  final DateTime? nextChange;
  const UsernameEditor({super.key, required this.service, required this.current, this.nextChange});

  @override
  State<UsernameEditor> createState() => _UsernameEditorState();
}

class _UsernameEditorState extends State<UsernameEditor> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.current);
  Timer? _debounce;
  String? _problem;
  bool _available = false;
  bool _checking = false;
  bool _saving = false;
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  bool get _locked => widget.nextChange != null;

  void _changed(String v) {
    _debounce?.cancel();
    final caseOnly = UsernameRules.sameIgnoringCase(v, widget.current);
    final local = UsernameRules.check(v);
    setState(() {
      _problem = local.message;
      _available = local.ok && caseOnly && v.trim() != widget.current;
      _checking = local.ok && !caseOnly;
    });
    if (!local.ok || caseOnly) return;
    final seq = ++_seq;
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      final err = await widget.service.checkAvailable(v);
      if (!mounted || seq != _seq) return;
      setState(() {
        _checking = false;
        _problem = err;
        _available = err == null;
      });
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final err = await widget.service.changeUsername(_ctrl.text);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _problem = err;
    });
    if (err == null) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final caseOnly = UsernameRules.sameIgnoringCase(_ctrl.text, widget.current);
    final canSave = _available && !_saving && (!_locked || caseOnly);
    final next = widget.nextChange;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            next == null
                ? 'You can change your username once every ${UsernameRules.changeDays} days. Do not use your real name, phone or e-mail: it is shown publicly.'
                : 'You can pick a new username on ${DateFormat.yMMMd().format(next)}. Changing only capital letters is always possible.',
            style: AppText.body.copyWith(color: AppTheme.text2),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            maxLength: UsernameRules.maxLength,
            autocorrect: false,
            enableSuggestions: false,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_]'))],
            decoration: InputDecoration(
              labelText: 'Username',
              errorText: _problem,
              helperText: _checking ? 'Checking...' : (_available ? 'Available' : null),
              suffixIcon: _available ? Icon(Icons.check_circle_rounded, color: AppTheme.accentText) : null,
            ),
            onChanged: _changed,
            onSubmitted: (_) => canSave ? _save() : null,
          ),
          const SizedBox(height: 12),
          DsButton(label: _saving ? 'Saving...' : 'Save username', onPressed: canSave ? _save : null),
        ],
      ),
    );
  }
}
