import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/services/permissions_service.dart';

/// Explains each permission before asking for it. Shown once before the first
/// convoy, and reachable again from the account menu.
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
          child: _loading
              ? Center(child: CircularProgressIndicator(color: AppTheme.neonCyan))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                  children: [
                    Text(
                      'CoRoute needs a few permissions to keep your convoy together. Each one is used only while you are in a convoy.',
                      style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                    ),
                    const SizedBox(height: 16),
                    for (final p in _items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: GlassCard(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(p.granted ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                                  color: p.granted ? AppTheme.emeraldSafe : AppTheme.textMuted),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(child: Text(p.title, style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 14))),
                                        if (p.required) ...[
                                          const SizedBox(width: 6),
                                          Text('Required', style: TextStyle(color: AppTheme.hyperAmber, fontSize: 10, fontWeight: FontWeight.bold)),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(p.reason, style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                                    if (!p.granted) ...[
                                      const SizedBox(height: 8),
                                      OutlinedButton(
                                        onPressed: () => _request(p),
                                        style: OutlinedButton.styleFrom(foregroundColor: AppTheme.neonCyan, side: BorderSide(color: AppTheme.neonCyan), visualDensity: VisualDensity.compact),
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
                    const SizedBox(height: 12),
                    if (widget.gate)
                      ElevatedButton(
                        onPressed: requiredOk
                            ? () async {
                                await PermissionsService.markIntroShown();
                                if (context.mounted) Navigator.pop(context, true);
                              }
                            : null,
                        style: ElevatedButton.styleFrom(backgroundColor: AppTheme.neonCyan, foregroundColor: Colors.black, minimumSize: const Size.fromHeight(48)),
                        child: Text(requiredOk ? 'Continue' : 'Allow the required permissions to continue'),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}
