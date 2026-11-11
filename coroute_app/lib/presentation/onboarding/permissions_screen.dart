import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/permissions_service.dart';
import '../safety/emergency_texts_disclosure.dart';

/// Explains each permission before asking for it. Opened in context (before
/// starting or joining a ride) and from the Profile tab.
class PermissionsScreen extends StatefulWidget {
  /// When true the screen pops with `true` once the required permissions are granted.
  final bool gate;
  const PermissionsScreen({super.key, this.gate = false});

  static bool _isEnsuring = false;

  /// Shows the screen if required permissions are missing. Returns true when the
  /// caller may continue (everything required is granted or the platform needs nothing).
  static Future<bool> ensure(BuildContext context) async {
    if (await PermissionsService.coreGranted()) {
      await PermissionsService.markIntroShown();
      return true;
    }
    if (!context.mounted) return false;
    if (_isEnsuring) return false;
    _isEnsuring = true;
    try {
      final ok = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const PermissionsScreen(gate: true)));
      return ok == true;
    } finally {
      _isEnsuring = false;
    }
  }

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> with WidgetsBindingObserver {
  List<PermissionItem> _items = const [];
  bool _loading = true;
  bool _isRequesting = false;
  bool _isContinuing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh(); // back from system settings
  }

  Future<void> _refresh() async {
    if (mounted && !_loading) setState(() => _loading = true);
    final items = await PermissionsService.status();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _request(PermissionItem p) async {
    if (_isRequesting) return;
    _isRequesting = true;
    try {
      if (p.key == 'sms') {
        // 3.57: the one-screen disclosure first, then the system prompt.
        await EmergencyTextsDisclosure.show(context);
      } else {
        await PermissionsService.request(p.key);
      }
      await _refresh();
    } finally {
      if (mounted) setState(() => _isRequesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final requiredOk = _items.where((p) => p.required).every((p) => p.granted);
    return Scaffold(
      backgroundColor: AppTheme.bg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: LoadingState(
              loading: _loading,
              hasData: _items.isNotEmpty || !_loading,
              child: ListView(
                padding: dsScreenPadding,
                physics: const BouncingScrollPhysics(),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  DsScreenHeader(
                    title: 'Permissions',
                    subtitle: 'Used only during a ride',
                    onBack: widget.gate ? null : () => Navigator.maybePop(context),
                  ),
                  const SizedBox(height: Space.s24),
                  for (final p in _items) _PermissionRow(item: p, onAllow: () => _request(p)),
                  const SizedBox(height: Space.s12),
                  if (widget.gate)
                    DsButton(
                      label: requiredOk ? 'Continue' : 'Allow required to continue',
                      onPressed: (requiredOk && !_isContinuing)
                          ? () async {
                              setState(() => _isContinuing = true);
                              try {
                                await PermissionsService.markIntroShown();
                                if (context.mounted) Navigator.pop(context, true);
                              } finally {
                                if (mounted) setState(() => _isContinuing = false);
                              }
                            }
                          : null,
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

class _PermissionRow extends StatelessWidget {
  final PermissionItem item;
  final VoidCallback onAllow;
  const _PermissionRow({required this.item, required this.onAllow});

  /// One outline icon per permission, so the list reads at a glance.
  static IconData iconFor(String key) => switch (key) {
        'location' => Icons.location_on_outlined,
        'locationAlways' => Icons.my_location_outlined,
        'microphone' => Icons.mic_none_outlined,
        'bluetooth' => Icons.bluetooth_outlined,
        'notification' => Icons.notifications_none_outlined,
        'battery' => Icons.battery_std_outlined,
        'fullScreen' => Icons.lock_open_outlined,
        'sms' => Icons.sms_outlined,
        _ => Icons.shield_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final p = item;
    final statusText = p.granted ? 'Allowed' : (p.required ? 'Required' : 'Optional');
    final attention = !p.granted && p.required;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s12),
      child: DsCard(
        warning: attention,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: p.granted ? AppTheme.primarySoft : (attention ? AppTheme.warnTint : AppTheme.soft),
                shape: BoxShape.circle,
              ),
              child: Icon(iconFor(p.key), size: 22, color: p.granted ? AppTheme.primary : (attention ? AppTheme.warnText : AppTheme.muted)),
            ),
            const SizedBox(width: Space.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 15))),
                      const SizedBox(width: 8),
                      if (p.granted)
                        Icon(Icons.check_circle_outline_rounded, size: 22, color: AppTheme.success, semanticLabel: statusText)
                      else
                        DsChip(statusText, warning: attention, color: attention ? null : AppTheme.muted, background: attention ? null : AppTheme.soft),
                    ],
                  ),
                  // Shown in full: the background-location line is the
                  // required prominent disclosure.
                  if (!p.granted) ...[
                    const SizedBox(height: Space.s4),
                    Text(p.reason, style: AppText.label),
                    const SizedBox(height: Space.s12),
                    SizedBox(
                      width: 160,
                      child: DsButton(label: 'Fix Permission', height: 44, fontSize: 14, onPressed: onAllow),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
