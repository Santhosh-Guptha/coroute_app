import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/diag_log_service.dart';
import '../../domain/diag/diag_log.dart';

/// 3.55 Settings › More › Diagnostics (docs/features_355/diagnostics_logs.md).
///
/// The app log kept on this phone: size, days kept, last error; "Send logs to CoRoute",
/// "Share log file", a simple viewer of the last 500 entries with a category filter, and
/// "Clear logs". "Send safety logs automatically" (off by default). "Detailed logs" is a
/// developer / admin switch: shown to admins, or after seven taps on the subtitle; it turns
/// itself off after 24 h.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  static const String title = 'Diagnostics';
  static const String privacyNote =
      'The log has no messages, names, phone numbers or exact places. Places are rounded to about 100 m and kept only during rides. '
      'It stays on this phone unless you send or share it.';

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  int _taps = 0;
  bool _devUnlocked = false;

  @override
  void initState() {
    super.initState();
    DiagLogService.instance.refreshStats();
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _send(DiagLogService d) async {
    final err = await d.upload(DiagUploadReason.manual);
    _say(err ?? 'Logs sent. Thank you!');
  }

  Future<void> _share(DiagLogService d) async {
    final err = await d.shareFile();
    if (err != null) _say(err);
  }

  Future<void> _clear(DiagLogService d) async {
    final ok = await confirmAction(context,
        title: 'Clear logs?', message: 'The app log on this phone is deleted. Logs already sent are not affected.', confirmLabel: 'Clear', destructive: true);
    if (!ok) return;
    await d.clear();
    _say('Logs cleared');
  }

  static String _size(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _when(int ms) {
    if (ms <= 0) return 'Never';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final time = '${two(d.hour)}:${two(d.minute)}';
    if (d.year == now.year && d.month == now.month && d.day == now.day) return 'Today $time';
    return '${d.day}/${d.month} $time';
  }

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DiagLogService?>() ?? DiagLogService.instance;
    final admin = context.watch<AuthService?>()?.isMasterAdmin ?? false;
    final showDev = admin || _devUnlocked || d.detailedOn;
    final days = d.oldestDay == null ? 0 : _daysSince(d.oldestDay!);
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
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (++_taps >= 7 && !_devUnlocked) {
                      setState(() => _devUnlocked = true);
                      _say('Developer options shown');
                    }
                  },
                  child: DsScreenHeader(title: DiagnosticsScreen.title, subtitle: 'App log on this phone', onBack: () => Navigator.maybePop(context)),
                ),
                const SizedBox(height: Space.s24),
                DsCard(
                  padding: const EdgeInsets.symmetric(horizontal: Space.s16),
                  child: Column(
                    children: [
                      DsListRow(icon: Icons.inventory_2_outlined, label: 'Log size', value: '${_size(d.totalBytes)} · ${d.fileCount} files'),
                      DsListRow(icon: Icons.date_range_rounded, label: 'Days kept', value: days == 0 ? 'Today' : 'Last ${days + 1} of 7'),
                      DsListRow(
                        icon: Icons.error_outline_rounded,
                        label: 'Last error',
                        value: d.lastError == null ? 'None' : '${_when(d.lastErrorAt)}\n${d.lastError}',
                        valueColor: d.lastError == null ? null : AppTheme.warnText,
                      ),
                      DsListRow(icon: Icons.cloud_done_outlined, label: 'Last sent', value: _when(d.lastSentAt), divider: false),
                    ],
                  ),
                ),
                const SizedBox(height: Space.s16),
                DsButton(
                  key: const ValueKey('diag_send'),
                  label: d.busy ? 'Sending…' : 'Send logs to CoRoute',
                  icon: Icons.send_rounded,
                  onPressed: d.busy ? null : () => _send(d),
                ),
                const SizedBox(height: Space.s12),
                DsButton(key: const ValueKey('diag_share'), label: 'Share log file', icon: Icons.ios_share_rounded, tone: DsButtonTone.outline, onPressed: () => _share(d)),
                const SizedBox(height: Space.s12),
                DsButton(
                  key: const ValueKey('diag_view'),
                  label: 'View log',
                  icon: Icons.list_alt_rounded,
                  tone: DsButtonTone.outline,
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DiagLogViewerScreen())),
                ),
                const SizedBox(height: Space.s24),
                DsCard(
                  padding: const EdgeInsets.symmetric(horizontal: Space.s16),
                  child: Column(
                    children: [
                      DsSwitchRow(
                        key: const ValueKey('diag_auto_safety'),
                        label: 'Send safety logs automatically',
                        subtitle: 'After an SOS or crash alarm. Off: we ask you first.',
                        value: d.autoSendSafety,
                        onChanged: d.setAutoSendSafety,
                        divider: showDev,
                      ),
                      if (showDev)
                        DsSwitchRow(
                          key: const ValueKey('diag_detailed'),
                          label: 'Detailed logs',
                          subtitle: d.detailedOn ? 'On until ${_when(d.detailedUntilMs)}' : 'Developer option. Turns off by itself after 24 h.',
                          value: d.detailedOn,
                          onChanged: d.setDetailed,
                          divider: false,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: Space.s16),
                Text(DiagnosticsScreen.privacyNote, style: AppText.caption),
                const SizedBox(height: Space.s24),
                Center(
                  child: TextButton.icon(
                    key: const ValueKey('diag_clear'),
                    onPressed: () => _clear(d),
                    icon: Icon(Icons.delete_outline_rounded, color: AppTheme.danger),
                    label: Text('Clear logs', style: AppText.body.copyWith(color: AppTheme.danger, fontWeight: FontWeight.w600)),
                    style: TextButton.styleFrom(minimumSize: const Size(160, 48)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static int _daysSince(String day) {
    final y = int.tryParse(day.substring(0, 4)) ?? 0, m = int.tryParse(day.substring(4, 6)) ?? 1, dd = int.tryParse(day.substring(6, 8)) ?? 1;
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).difference(DateTime(y, m, dd)).inDays.clamp(0, 6);
  }
}

/// The last 500 log entries, newest first, with a category filter (for the owner and testers).
class DiagLogViewerScreen extends StatefulWidget {
  const DiagLogViewerScreen({super.key});

  @override
  State<DiagLogViewerScreen> createState() => _DiagLogViewerScreenState();
}

class _DiagLogViewerScreenState extends State<DiagLogViewerScreen> {
  List<DiagEntry> _all = const [];
  DiagCat? _cat;
  bool _problemsOnly = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await DiagLogService.instance.recentFromDisk(limit: 500);
    if (!mounted) return;
    setState(() {
      _all = list.reversed.toList();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cats = <DiagCat>{for (final e in _all) e.cat}.toList()..sort((a, b) => a.wire.compareTo(b.wire));
    final shown = _all.where((e) => (_cat == null || e.cat == _cat) && (!_problemsOnly || e.level.atLeast(DiagLevel.warn))).toList();
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: DsScreenHeader(
                title: 'App log',
                subtitle: '${shown.length} of ${_all.length} entries',
                onBack: () => Navigator.maybePop(context),
                trailing: DsRoundButton(icon: Icons.refresh_rounded, label: 'Refresh', onTap: _load),
              ),
            ),
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  _chip('Problems', _problemsOnly, () => setState(() => _problemsOnly = !_problemsOnly)),
                  _chip('All', _cat == null, () => setState(() => _cat = null)),
                  for (final c in cats) _chip(c.wire, _cat == c, () => setState(() => _cat = _cat == c ? null : c)),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const SkeletonList(itemExtent: 48, itemBuilder: _logLineSkeleton) // round 7
                  : shown.isEmpty
                      ? Center(child: Text('Nothing logged yet.', style: AppText.body))
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                          itemCount: shown.length,
                          separatorBuilder: (_, _) => Divider(height: 1, color: AppTheme.border),
                          itemBuilder: (_, i) {
                            final e = shown[i];
                            final color = e.level == DiagLevel.error
                                ? AppTheme.danger
                                : e.level == DiagLevel.warn
                                    ? AppTheme.warnText
                                    : AppTheme.text;
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: SelectableText(e.display, style: AppText.caption.copyWith(color: color, fontFamily: 'monospace', fontSize: 12)),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: Space.s8),
        child: ChoiceChip(label: Text(label), selected: selected, onSelected: (_) => onTap()),
      );
}

/// Round 7: placeholder for one log line while the log is read.
Widget _logLineSkeleton(BuildContext _) => const SkeletonListTile(avatar: false, height: 48);
