import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/plan_subscription_service.dart';
import '../../core/config/feature_gates.dart';

bool _isGuardianSheetShowing = false;

Future<void> showGuardianSheet(
  BuildContext context, {
  required String groupId,
}) async {
  if (_isGuardianSheetShowing) return;
  _isGuardianSheetShowing = true;
  try {
    await showAppSheet<void>(
      context,
      title: 'Ride Guardian',
      isScrollControlled: true,
      builder: (_) => GuardianSheet(groupId: groupId),
    );
  } finally {
    _isGuardianSheetShowing = false;
  }
}

class GuardianSheet extends StatelessWidget {
  const GuardianSheet({super.key, required this.groupId});
  final String groupId;

  @override
  Widget build(BuildContext context) {
    final planService = context.watch<PlanSubscriptionService?>();
    final isUnlocked = planService?.isUnlocked(Feature.guardianLiveShare) ??
        FeatureGates.isUnlocked(Feature.guardianLiveShare);

    if (!isUnlocked) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppTheme.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.warnBorder, width: 1.5),
              ),
              child: Column(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: AppTheme.warnTint,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.lock_rounded, size: 28, color: AppTheme.warnText),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Ride Guardian is a Pro Feature',
                    style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.w800, fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Ride Guardian encrypted browser live-share is available on CoRoute Pro and Road Captain Pass.\n\nIn this test build, you can test this instantly by switching your plan to CoRoute Pro (Free).',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.text2, fontSize: 13, height: 1.4),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: AppTheme.brand),
                      onPressed: () {
                        context.read<PlanSubscriptionService>().selectTier(SubscriptionTier.proRider);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).clearSnackBars();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            duration: const Duration(seconds: 2),
                            backgroundColor: AppTheme.card,
                            content: Text(
                              'Activated CoRoute Pro! Ride Guardian is now unlocked.',
                              style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.w700),
                            ),
                          ),
                        );
                      },
                      child: const Text('SWITCH TO COROUTE PRO TO TEST (FREE)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final token = context.select<ApiClient, String?>((api) => api.token);
    return _GuardianContent(key: ValueKey((groupId, token)), groupId: groupId);
  }
}

class _GuardianContent extends StatefulWidget {
  const _GuardianContent({super.key, required this.groupId});
  final String groupId;
  @override
  State<_GuardianContent> createState() => _GuardianSheetState();
}

class _GuardianSheetState extends State<_GuardianContent> {
  final _pin = TextEditingController();
  final _label = TextEditingController();
  int _hours = 72;
  @override
  void dispose() {
    _pin.dispose();
    _label.dispose();
    super.dispose();
  }

  String _level = 'BASIC', _subject = 'PERSONAL';
  bool _groupConsent = false;
  bool _acknowledged = false, _busy = false;
  String? _error, _url;
  List<Map<String, dynamic>> _links = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    await _run(() async {
      final consent = await context.read<ApiClient>().get(
        '/guardian/consent/${Uri.encodeComponent(widget.groupId)}',
      );
      if (mounted && consent is Map) _groupConsent = consent['allowed'] == true;
      if (!mounted) return;
      final data = await context.read<ApiClient>().get(
        '/guardian/links/${Uri.encodeComponent(widget.groupId)}',
      );
      if (mounted && data is Map && data['links'] is List) {
        _links = (data['links'] as List)
            .whereType<Map>()
            .map((v) => Map<String, dynamic>.from(v))
            .toList();
      }
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        _error = e is ApiException
            ? e.message
            : 'Could not complete the request. Try again.';
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _create() => _run(() async {
    if (_pin.text.isNotEmpty && !RegExp(r'^[0-9]{4,8}$').hasMatch(_pin.text)) {
      throw const ApiException(400, 'Use a PIN of 4 to 8 digits.');
    }
    final policy = context.read<ConvoyService?>()?.activeConvoy?.featurePolicy;
    if (policy?.guardianRequirePin == true && _pin.text.isEmpty) throw const ApiException(400, 'The lead requires a PIN for Guardian links.');
    final hours = _hours.clamp(1, policy?.guardianMaxHours ?? 336);
    final data = await context.read<ApiClient>().post('/guardian/links', {
      'label': _label.text.trim(),
      'expiresAt': DateTime.now().millisecondsSinceEpoch + Duration(hours: hours).inMilliseconds,
      if (_pin.text.isNotEmpty) 'pin': _pin.text,
      'groupId': widget.groupId,
      'subject': _subject,
      'level': _level,
      'acknowledged': _acknowledged,
    });
    if (!mounted) return;
    if (data is! Map || data['url'] is! String) {
      throw const FormatException('Invalid link');
    }
    _pin.clear();
    _url = data['url'] as String;
    _links.insert(0, Map<String, dynamic>.from(data)..remove('url'));
  });

  Future<void> _revoke(String id) => _run(() async {
    await context.read<ApiClient>().delete(
      '/guardian/links/${Uri.encodeComponent(id)}',
    );
    if (!mounted) return;
    for (final link in _links) {
      if (link['grantId'] == id) link['status'] = 'REVOKED';
    }
    _url = null;
  });

  static const Map<String, String> _levels = {
    'BASIC': 'Basic - status without exact location',
    'LIVE': 'Live - your last reported location',
    'EMERGENCY_ONLY': 'Emergency only - incident location when help is requested',
  };

  static IconData _levelIcon(String level) {
    switch (level) {
      case 'LIVE':
        return Icons.my_location_rounded;
      case 'EMERGENCY_ONLY':
        return Icons.emergency_share_rounded;
    }
    return Icons.visibility_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final lead = context.watch<ConvoyService?>()?.canEditRoute == true;
    final error = _error;
    final url = _url;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Watches over you while you ride', style: AppText.label),
          const SizedBox(height: 18),
          // Hero: who a guardian is and what they can (not) do.
          DsHeroCard(
            child: Column(
              children: [
                Container(
                  width: 84,
                  height: 84,
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x24FFFFFF)),
                  child: const Icon(Icons.verified_user_outlined, size: 44, color: Colors.white),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Guardian links',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.2),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Guardians can view the information you share, but cannot control the ride. Fuel and contacts remain private.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.4, color: DsHeroCard.secondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const DsSectionHeader('Group sharing'),
          const SizedBox(height: 10),
          DsCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _groupConsent,
              title: Text('Include me in Guardian group sharing', style: AppText.body.copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
              subtitle: Text(
                'Allow the lead to share my status, location and emergency updates through group links. Turning this off removes me from existing group links.',
                style: AppText.caption,
              ),
              onChanged: _busy
                  ? null
                  : (value) => _run(() async {
                      await context.read<ApiClient>().patch(
                        '/guardian/consent/${Uri.encodeComponent(widget.groupId)}',
                        {'allowed': value},
                      );
                      if (mounted) _groupConsent = value;
                    }),
            ),
          ),
          const SizedBox(height: 18),
          const DsSectionHeader('What they see'),
          const SizedBox(height: 10),
          if (lead) ...[
            DsSegment<String>(
              values: const ['PERSONAL', 'GROUP'],
              selected: _subject,
              label: (v) => v == 'GROUP' ? 'Consenting group riders' : 'My ride',
              onChanged: _busy
                  ? (_) {}
                  : (v) => setState(() {
                      _subject = v;
                      _acknowledged = false;
                    }),
            ),
            const SizedBox(height: 10),
          ],
          DsCard(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Column(
              children: [
                for (final option in _levels.entries)
                  RadioListTile<String>(
                    value: option.key,
                    groupValue: _level,
                    activeColor: AppTheme.brand,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    secondary: Icon(_levelIcon(option.key), size: 22, color: AppTheme.accentText),
                    title: Text(option.value, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                    onChanged: _busy
                        ? null
                        : (v) => setState(() {
                            _level = v!;
                            _acknowledged = false;
                          }),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Links expire at the selected time or 6 hours after the ride ends, whichever comes first. The lead can shorten the group limit. Browser alerts require support, server configuration and permission.',
            style: AppText.caption,
          ),
          const SizedBox(height: 18),
          const DsSectionHeader('New link'),
          const SizedBox(height: 10),
          TextField(
            controller: _label,
            enabled: !_busy,
            maxLength: 80,
            style: AppText.body,
            decoration: const InputDecoration(labelText: 'Guardian link label', helperText: 'For your reference; not a verified identity.'),
          ),
          const SizedBox(height: Space.s12),
          DropdownButtonFormField<int>(
            initialValue: _hours,
            decoration: const InputDecoration(labelText: 'Maximum hours'),
            style: AppText.body,
            dropdownColor: AppTheme.card,
            items: [for (final hours in [1, 6, 24, 72, 168, 336]) DropdownMenuItem(value: hours, child: Text('$hours hours'))],
            onChanged: _busy ? null : (hours) => setState(() { _hours = hours!; }),
          ),
          const SizedBox(height: Space.s12),
          TextField(
            key: const ValueKey('guardianPin'),
            controller: _pin,
            enabled: !_busy,
            obscureText: true,
            maxLength: 8,
            style: AppText.body,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Optional PIN',
              helperText: '4 to 8 digits. Send it separately from the link.',
            ),
          ),
          CheckboxListTile(
            value: _acknowledged,
            contentPadding: EdgeInsets.zero,
            activeColor: AppTheme.brand,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              'Anyone with this link can view the selected information until it expires or I revoke it.',
              style: AppText.body.copyWith(fontSize: 14),
            ),
            onChanged: _busy
                ? null
                : (v) => setState(() => _acknowledged = v == true),
          ),
          const SizedBox(height: Space.s8),
          // A plain FilledButton (not .icon): tests look it up by type.
          FilledButton(
            onPressed: _busy || !_acknowledged ? null : _create,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_link_rounded, size: 22),
                SizedBox(width: 10),
                Flexible(child: Text('Create Guardian link', maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
          if (url != null) ...[
            const SizedBox(height: Space.s12),
            DsCard(
              accent: true,
              tinted: true,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.check_circle_outline_rounded, size: 20, color: AppTheme.accentText),
                      const SizedBox(width: Space.s8),
                      Expanded(
                        child: Text(
                          'Share now. For privacy, the original link cannot be recovered after this sheet closes.',
                          style: AppText.body.copyWith(fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.s12),
                  DsButton(
                    tone: DsButtonTone.outline,
                    height: 48,
                    fontSize: 15,
                    icon: Icons.ios_share_rounded,
                    label: 'Share link',
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            final box = context.findRenderObject() as RenderBox?;
                            await Share.share(
                              url,
                              sharePositionOrigin: box == null
                                  ? null
                                  : box.localToGlobal(Offset.zero) & box.size,
                            );
                          }),
                  ),
                ],
              ),
            ),
          ],
          if (_busy)
            Padding(
              padding: const EdgeInsets.only(top: Space.s12),
              child: LinearProgressIndicator(color: AppTheme.brand, backgroundColor: AppTheme.map),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.s12),
              child: DsCard(
                warning: true,
                color: AppTheme.warnTint,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 20, color: AppTheme.warnText),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        error,
                        semanticsLabel: 'Error: $error',
                        style: AppText.body.copyWith(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.warnText),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 18),
          const DsSectionHeader('Your links'),
          const SizedBox(height: 10),
          if (_links.isEmpty)
            DsCard(
              dashed: true,
              child: Text('No Guardian links yet.', style: AppText.body.copyWith(color: AppTheme.text2)),
            )
          else
            DsCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  for (var i = 0; i < _links.length; i++)
                    _LinkRow(
                      link: _links[i],
                      divider: i < _links.length - 1,
                      busy: _busy,
                      onRevoke: () => _revoke(_links[i]['grantId'].toString()),
                      onPauseToggle: () => _run(() async {
                        final link = _links[i];
                        final paused = link['status'] != 'PAUSED';
                        await context.read<ApiClient>().patch(
                          '/guardian/links/${Uri.encodeComponent(link['grantId'].toString())}',
                          {'paused': paused},
                        );
                        if (mounted) {
                          link['status'] = paused ? 'PAUSED' : 'ACTIVE';
                        }
                      }),
                    ),
                ],
              ),
            ),
          TextButton(
            onPressed: _busy ? null : _load,
            child: const Text('Refresh links'),
          ),
        ],
      ),
    );
  }
}

/// One Guardian link: tinted icon disc, "subject · level · status", the
/// reminder that a link is not a verified person, and the pause/revoke menu.
class _LinkRow extends StatelessWidget {
  final Map<String, dynamic> link;
  final bool divider;
  final bool busy;
  final VoidCallback onRevoke;
  final VoidCallback onPauseToggle;

  const _LinkRow({
    required this.link,
    required this.divider,
    required this.busy,
    required this.onRevoke,
    required this.onPauseToggle,
  });

  @override
  Widget build(BuildContext context) {
    final status = link['status'];
    final revoked = status == 'REVOKED';
    final paused = status == 'PAUSED';
    final iconColor = revoked ? AppTheme.muted : AppTheme.accentText;
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null,
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(shape: BoxShape.circle, color: revoked ? AppTheme.soft : AppTheme.tint),
            child: Icon(
              revoked
                  ? Icons.link_off_rounded
                  : paused
                      ? Icons.pause_rounded
                      : Icons.link_rounded,
              size: 18,
              color: iconColor,
            ),
          ),
          const SizedBox(width: Space.s12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${link['subject']} · ${link['level']} · ${link['status']}',
                  style: AppText.body.copyWith(fontWeight: FontWeight.w700, color: revoked ? AppTheme.muted : AppTheme.text),
                ),
                const SizedBox(height: 1),
                Text('An invitation, not a verified person.', style: AppText.caption),
              ],
            ),
          ),
          if (!revoked)
            PopupMenuButton<String>(
              enabled: !busy,
              tooltip: 'Link options',
              icon: Icon(Icons.more_vert_rounded, color: AppTheme.muted),
              color: AppTheme.card,
              onSelected: (action) {
                if (action == 'revoke') {
                  onRevoke();
                  return;
                }
                onPauseToggle();
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'pause',
                  child: Text(paused ? 'Resume access' : 'Pause access'),
                ),
                const PopupMenuItem(
                  value: 'revoke',
                  child: Text('Revoke link'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
