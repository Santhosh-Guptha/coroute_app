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

  /// Shows the screen if required permissions are missing. Returns true when the
  /// caller may continue (everything required is granted or the platform needs nothing).
  static Future<bool> ensure(BuildContext context) async {
    if (await PermissionsService.coreGranted()) {
      await PermissionsService.markIntroShown();
      return true;
    }
    if (!context.mounted) return false;
    final ok = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const PermissionsScreen(gate: true)));
    return ok == true;
  }

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> with WidgetsBindingObserver {
  List<PermissionItem> _items = const [];
  bool _loading = true;

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
    await PermissionsService.request(p.key);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final requiredOk = _items.where((p) => p.required).every((p) => p.granted);
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(title: const Text('Permissions'), automaticallyImplyLeading: !widget.gate),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: LoadingState(
            loading: _loading,
            hasData: _items.isNotEmpty || !_loading,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(Space.s16, Space.s12, Space.s16, Space.s32),
              children: [
                Text(
                  widget.gate
                      ? 'Before the ride starts, CoRoute needs a few permissions. Each one is used only during an active ride.'
                      : 'Each permission is used only during an active ride.',
                  style: AppText.body.copyWith(color: AppTheme.textSecondary),
                ),
                const SizedBox(height: Space.s16),
                for (final p in _items) _PermissionRow(item: p, onAllow: () => _request(p)),
                const SizedBox(height: Space.s12),
                if (widget.gate)
                  FilledButton(
                    onPressed: requiredOk
                        ? () async {
                            await PermissionsService.markIntroShown();
                            if (context.mounted) Navigator.pop(context, true);
                          }
                        : null,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                    child: Text(
                      requiredOk ? 'Continue' : 'Allow the required permissions to continue',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
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
    final Color statusColor = p.granted ? StatusColors.success : (p.required ? StatusColors.warning : AppTheme.textMuted);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppTheme.slateCard,
          borderRadius: Radii.mdAll,
          border: Border.all(color: AppTheme.subtleBorder),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Space.s16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(p.granted ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, color: statusColor),
              const SizedBox(width: Space.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.title, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(statusText, style: AppText.label.copyWith(color: statusColor)),
                    const SizedBox(height: Space.s4),
                    Text(p.reason, style: AppText.label.copyWith(fontWeight: FontWeight.w400)),
                    if (!p.granted) ...[
                      const SizedBox(height: Space.s8),
                      OutlinedButton(
                        onPressed: onAllow,
                        style: OutlinedButton.styleFrom(minimumSize: const Size(96, 48)),
                        child: const Text('Allow'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
