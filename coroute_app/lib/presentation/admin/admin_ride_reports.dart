import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import 'admin_payments_logic.dart';
import 'admin_payments_widgets.dart';
import 'admin_ui.dart';
import 'admin_user_details_screen.dart';

/// "Abuse" for the reason code of a public ride report.
String adminReportReason(Object? code) => switch (code?.toString()) {
      'ABUSE' => 'Abuse',
      'SPAM' => 'Spam',
      'UNSAFE' => 'Unsafe riding',
      _ => 'Other',
    };

/// What an admin did about a report, in a few words ("" while it is open).
String adminReportOutcome(Map<String, dynamic> r) {
  final status = r['status']?.toString() ?? 'OPEN';
  if (status == 'OPEN') return '';
  switch (r['action']?.toString()) {
    case 'WARN':
      return 'Warned';
    case 'SUSPEND':
      final d = adminNumOrNull(r['actionDays'])?.toInt() ?? 0;
      return d > 0 ? 'Suspended $d days' : 'Suspended';
    case 'DISMISS':
      return 'Dismissed';
    default:
      return status == 'ACTIONED' ? 'Action taken' : 'Reviewed';
  }
}

/// One line of the conversation: the quick line (a code such as WHERE_TO) and the rider's text.
String adminReportLine(Map<String, dynamic> l) {
  final quick = (l['quick']?.toString() ?? '').trim();
  final text = (l['text']?.toString() ?? '').trim();
  final q = quick.isEmpty ? '' : adminCapitalize(quick.toLowerCase().replaceAll('_', ' '));
  if (q.isEmpty) return text.isEmpty ? '(no text)' : text;
  return text.isEmpty ? '[$q]' : '[$q] $text';
}

/// Safety: public ride reports. Riders report a rider who contacted them through a public ride; the
/// report keeps the conversation. Open reports first; each opens the conversation with the actions
/// (dismiss, warn, suspend public ride for 7 or 30 days) and a link to the rider.
/// API: `GET /admin/public-ride/reports?status=OPEN`, `PATCH /admin/public-ride/reports/:id`
/// ({status, action}), `POST /admin/public-ride/users/:id/suspension` ({days}).
class AdminRideReportsSection extends StatefulWidget {
  const AdminRideReportsSection({super.key});

  @override
  State<AdminRideReportsSection> createState() => AdminRideReportsSectionState();
}

class AdminRideReportsSectionState extends State<AdminRideReportsSection> {
  List<Map<String, dynamic>> _reports = [];
  bool _loading = true;
  bool _loaded = false;
  String? _error;

  /// 'OPEN' or '' (every report, newest first).
  String _filter = 'OPEN';

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// Loads the reports again (pull to refresh on the Safety screen).
  Future<void> reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    String? error;
    try {
      final res = await context.read<ApiClient>().get('/admin/public-ride/reports${_filter.isEmpty ? '' : '?status=$_filter'}');
      _reports = adminMapList(res is Map ? res['reports'] : null);
      _loaded = true;
    } catch (e) {
      error = adminErrorOf(e);
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error;
    });
  }

  Future<void> _open(Map<String, dynamic> r) async {
    final changed = await showAppSheet<bool>(
      context,
      isScrollControlled: true,
      title: 'Report',
      builder: (_) => AdminRideReportSheet(report: r),
    );
    if (changed == true && mounted) reload();
  }

  @override
  Widget build(BuildContext context) {
    final e = _error;
    final open = _filter == 'OPEN';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdminSectionLabel(
          open ? 'Public ride reports, open (${_reports.length})' : 'Public ride reports (${_reports.length})',
          trailing: AdminFilterButton<String>(
            value: _filter,
            label: open ? 'Open' : 'All',
            options: const [('OPEN', 'Open'), ('', 'All')],
            onSelected: (v) {
              setState(() => _filter = v);
              reload();
            },
          ),
        ),
        AdminTable(
          empty: Text(
            !_loaded && _loading ? 'Loading reports...' : (e ?? (open ? 'No open reports.' : 'No reports yet.')),
            style: AppText.body.copyWith(color: e != null ? AppTheme.sos : AppTheme.text2),
          ),
          rows: [
            for (var i = 0; i < _reports.length; i++) _row(_reports[i], last: i == _reports.length - 1),
          ],
        ),
      ],
    );
  }

  Widget _row(Map<String, dynamic> r, {required bool last}) {
    final name = (r['reportedName']?.toString() ?? '').trim();
    final by = (r['reporterName']?.toString() ?? '').trim();
    final note = (r['note']?.toString() ?? '').trim();
    final outcome = adminReportOutcome(r);
    final suspended = adminEpoch(r['reportedSuspendedUntil']) > DateTime.now().millisecondsSinceEpoch;
    return AdminRow(
      key: ValueKey(r['reportId']),
      leading: AdminRowIcon(Icons.flag_outlined, color: outcome.isEmpty ? AppTheme.warnText : null),
      title: name.isEmpty ? 'Rider' : name,
      subtitle: '${adminReportReason(r['reason'])} · reported by ${by.isEmpty ? 'a rider' : by} · ${adminDate(r['at'], time: true)}',
      detail: note.isEmpty ? null : '"$note"',
      status: suspended
          ? StatusTextChip(icon: Icons.block_rounded, text: 'Suspended until ${adminDate(r['reportedSuspendedUntil'])}', color: AppTheme.sos)
          : (outcome.isEmpty ? null : StatusTextChip(icon: Icons.check_circle_outline_rounded, text: outcome, color: AppTheme.text2)),
      divider: !last,
      onTap: () => _open(r),
    );
  }
}

/// One report: who, why, the conversation, and the actions. Pops `true` when something changed.
class AdminRideReportSheet extends StatefulWidget {
  final Map<String, dynamic> report;

  const AdminRideReportSheet({super.key, required this.report});

  @override
  State<AdminRideReportSheet> createState() => _AdminRideReportSheetState();
}

class _AdminRideReportSheetState extends State<AdminRideReportSheet> {
  bool _busy = false;

  Map<String, dynamic> get r => widget.report;
  String get _id => r['reportId']?.toString() ?? '';
  String get _riderId => r['reportedId']?.toString() ?? '';
  String get _name {
    final n = (r['reportedName']?.toString() ?? '').trim();
    return n.isEmpty ? 'this rider' : n;
  }

  Future<void> _run(Future<void> Function(ApiClient api) call, String done) async {
    final api = context.read<ApiClient>();
    setState(() => _busy = true);
    try {
      await call(api);
      if (!mounted) return;
      adminSnack(context, done);
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      adminSnack(context, adminErrorOf(e), error: true);
    }
  }

  Future<void> _mark(ApiClient api, String status, String action) =>
      api.patch('/admin/public-ride/reports/${Uri.encodeComponent(_id)}', {'status': status, 'action': action});

  Future<void> _dismiss() => _run((api) => _mark(api, 'REVIEWED', 'DISMISS'), 'Report dismissed.');

  Future<void> _warn() async {
    final ok = await confirmAction(
      context,
      title: 'Warn $_name?',
      // 3.55: the rider also gets it as an in-app notice (gateway default text; switch adminWarnings).
      message: 'They see a message from CoRoute moderators asking them to follow the public ride guidelines. '
          'The warning is also kept on their public ride record, so the next report can be judged with it.',
      confirmLabel: 'Warn',
    );
    if (!ok || !mounted) return;
    await _run((api) => _mark(api, 'ACTIONED', 'WARN'), 'Warning recorded.');
  }

  Future<void> _suspend(int days) async {
    final ok = await confirmAction(
      context,
      title: 'Suspend public ride for $days days?',
      message: '$_name cannot show their rides on the public map or contact other riders for $days days. '
          'Their own group rides and every safety feature keep working.',
      confirmLabel: 'Suspend $days days',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _run((api) async {
      await api.post('/admin/public-ride/users/${Uri.encodeComponent(_riderId)}/suspension', {'days': days});
      await api.patch('/admin/public-ride/reports/${Uri.encodeComponent(_id)}', {'status': 'ACTIONED', 'action': 'SUSPEND', 'days': days});
    }, 'Public ride suspended for $days days.');
  }

  Future<void> _lift() => _run(
        (api) => api.post('/admin/public-ride/users/${Uri.encodeComponent(_riderId)}/suspension', {'days': 0}),
        'Suspension lifted.',
      );

  void _openRider() {
    if (_riderId.isEmpty) return;
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => AdminUserDetailsScreen(userId: _riderId)));
  }

  @override
  Widget build(BuildContext context) {
    final transcript = adminMapList(r['transcript']);
    final by = (r['reporterName']?.toString() ?? '').trim();
    final note = (r['note']?.toString() ?? '').trim();
    final outcome = adminReportOutcome(r);
    final until = adminEpoch(r['reportedSuspendedUntil']);
    final suspended = until > DateTime.now().millisecondsSinceEpoch;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AdminDetailLine('Reported rider', _name == 'this rider' ? 'Rider' : _name),
          AdminDetailLine('Reported by', by.isEmpty ? 'A rider' : by),
          AdminDetailLine('Reason', adminReportReason(r['reason'])),
          if (note.isNotEmpty) AdminDetailLine('Note', note),
          AdminDetailLine('When', adminDate(r['at'], time: true)),
          if (outcome.isNotEmpty) AdminDetailLine('Outcome', outcome),
          if (suspended) AdminDetailLine('Public ride', 'Suspended until ${adminDate(until, time: true)}', color: AppTheme.sos),
          const AdminSectionLabel('Conversation'),
          if (transcript.isEmpty)
            Text('No messages were kept with this report.', style: AppText.body.copyWith(color: AppTheme.text2))
          else
            AdminCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final l in transcript)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(
                            text: l['from'] == 'REPORTER' ? 'Reporter: ' : 'Reported rider: ',
                            style: AppText.label.copyWith(fontWeight: FontWeight.w800, color: l['from'] == 'REPORTER' ? AppTheme.text2 : AppTheme.text),
                          ),
                          TextSpan(text: adminReportLine(l), style: AppText.body),
                        ]),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          if (outcome.isEmpty) ...[
            DsButton(label: 'Dismiss', icon: Icons.done_rounded, tone: DsButtonTone.outline, onPressed: _busy ? null : _dismiss),
            const SizedBox(height: 8),
            DsButton(label: 'Warn', icon: Icons.report_outlined, tone: DsButtonTone.warn, onPressed: _busy ? null : _warn),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: DsButton(label: 'Suspend 7 days', tone: DsButtonTone.sos, onPressed: _busy || _riderId.isEmpty ? null : () => _suspend(7))),
                const SizedBox(width: 8),
                Expanded(child: DsButton(label: 'Suspend 30 days', tone: DsButtonTone.sos, onPressed: _busy || _riderId.isEmpty ? null : () => _suspend(30))),
              ],
            ),
            const SizedBox(height: 8),
          ],
          if (suspended) ...[
            DsButton(label: 'Lift suspension', icon: Icons.lock_open_rounded, tone: DsButtonTone.outline, onPressed: _busy ? null : _lift),
            const SizedBox(height: 8),
          ],
          TextButton.icon(
            onPressed: _riderId.isEmpty ? null : _openRider,
            icon: Icon(Icons.person_search_rounded, color: AppTheme.accentText),
            label: Text('Open rider details', style: TextStyle(color: AppTheme.accentText, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}
