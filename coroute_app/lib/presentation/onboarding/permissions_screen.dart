import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/permissions_service.dart';

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
      await PermissionsService.request(p.key);
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
                    subtitle: 'Used only during an active ride',
                    onBack: widget.gate ? null : () => Navigator.maybePop(context),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    widget.gate
                        ? 'Before the ride starts, CoRoute needs a few permissions. Each one is used only during an active ride.'
                        : 'Each permission is used only during an active ride.',
                    style: AppText.body.copyWith(color: AppTheme.text2),
                  ),
                  const SizedBox(height: Space.s16),
                  for (final p in _items) _PermissionRow(item: p, onAllow: () => _request(p)),
                  const SizedBox(height: Space.s12),
                  if (widget.gate)
                    DsButton(
                      label: requiredOk ? 'Continue' : 'Allow the required permissions to continue',
                      fontSize: requiredOk ? 16 : 14,
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

  @override
  Widget build(BuildContext context) {
    final p = item;
    final statusText = p.granted ? 'Allowed' : (p.required ? 'Required' : 'Optional');
    final attention = !p.granted && p.required;
    final Color statusColor = p.granted ? AppTheme.accentText : (attention ? AppTheme.warnText : AppTheme.muted);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DsCard(
        warning: attention,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: p.granted ? AppTheme.tint : (attention ? AppTheme.warnTint : AppTheme.soft),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(p.granted ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, size: 22, color: statusColor),
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
                      DsChip(statusText, warning: attention, color: p.granted ? null : (attention ? null : AppTheme.muted), background: p.granted ? null : (attention ? null : AppTheme.soft)),
                    ],
                  ),
                  const SizedBox(height: Space.s4),
                  Text(p.reason, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.label),
                  if (!p.granted) ...[
                    const SizedBox(height: Space.s12),
                    SizedBox(
                      width: 140,
                      child: DsButton(label: 'Allow', height: 48, fontSize: 15, onPressed: onAllow),
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
