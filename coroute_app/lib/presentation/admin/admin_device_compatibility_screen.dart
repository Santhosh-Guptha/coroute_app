import '../../core/ui/app_motion.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/device_diagnostic_report.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/skeleton.dart';
import 'admin_ui.dart';

/// Admin Device Compatibility Dashboard (FEAT-DIAG-03).
///
/// Private console for platform master admins to inspect aggregated fleet device
/// metrics, filter compatibility reports, inspect individual sensor details, and
/// update report lifecycle statuses and review notes.
class AdminDeviceCompatibilityScreen extends StatefulWidget {
  const AdminDeviceCompatibilityScreen({super.key});

  @override
  State<AdminDeviceCompatibilityScreen> createState() => _AdminDeviceCompatibilityScreenState();
}

class _AdminDeviceCompatibilityScreenState extends State<AdminDeviceCompatibilityScreen> {
  bool _loading = true;
  String? _error;

  Map<String, dynamic>? _stats;
  List<dynamic> _reports = [];
  int _page = 1;
  int _totalPages = 1;
  int _totalCount = 0;

  final TextEditingController _searchCtrl = TextEditingController();
  String _selectedManufacturer = '';
  String _selectedStatus = '';
  String _selectedOverall = '';

  @override
  void initState() {
    super.initState();
    _loadDashboardData();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDashboardData({int page = 1}) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final client = context.read<ApiClient>();
      final qParams = <String, String>{
        'page': page.toString(),
        'limit': '20',
      };
      if (_searchCtrl.text.trim().isNotEmpty) qParams['search'] = _searchCtrl.text.trim();
      if (_selectedManufacturer.isNotEmpty) qParams['manufacturer'] = _selectedManufacturer;
      if (_selectedStatus.isNotEmpty) qParams['status'] = _selectedStatus;
      if (_selectedOverall.isNotEmpty) qParams['overallStatus'] = _selectedOverall;

      final uri = Uri(path: '/admin/diagnostics', queryParameters: qParams);
      final res = await client.get(uri.toString());

      if (res is Map && res['ok'] == true) {
        setState(() {
          _stats = res['stats'] is Map ? Map<String, dynamic>.from(res['stats'] as Map) : null;
          _reports = res['reports'] is List ? (res['reports'] as List) : [];
          final pagination = res['pagination'] as Map?;
          _page = (pagination?['page'] as num?)?.toInt() ?? 1;
          _totalPages = (pagination?['totalPages'] as num?)?.toInt() ?? 1;
          _totalCount = (pagination?['total'] as num?)?.toInt() ?? 0;
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'Failed to load device diagnostics.';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Network error: $e';
        _loading = false;
      });
    }
  }

  Color _overallColor(String overall) {
    switch (overall) {
      case DiagnosticOverallResult.fullySupported:
        return AppTheme.palette.success;
      case DiagnosticOverallResult.supportedWithLimitations:
        return AppTheme.palette.warning;
      case DiagnosticOverallResult.limitedCompatibility:
        return AppTheme.palette.accentStrong;
      case DiagnosticOverallResult.criticalIssueDetected:
        return AppTheme.palette.danger;
      default:
        return AppTheme.palette.textMuted;
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case DiagnosticLifecycleStatus.submitted:
        return AppTheme.palette.primary;
      case DiagnosticLifecycleStatus.reviewed:
        return AppTheme.palette.accent;
      case DiagnosticLifecycleStatus.resolved:
        return AppTheme.palette.success;
      case DiagnosticLifecycleStatus.failed:
        return AppTheme.palette.danger;
      default:
        return AppTheme.palette.textFaint;
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    if (!auth.isMasterAdmin) {
      return Scaffold(
        backgroundColor: AppTheme.palette.background,
        appBar: AppBar(
          backgroundColor: AppTheme.palette.background,
          title: Text('Access denied', style: TextStyle(color: AppTheme.palette.text)),
        ),
        body: Center(
          child: Text(
            'Master administrator privileges required to view device compatibility diagnostics.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.palette.textMuted, fontSize: 14),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.palette.background,
      appBar: AppBar(
        backgroundColor: AppTheme.palette.background,
        elevation: 0,
        title: Text(
          'Phone compatibility',
          style: TextStyle(color: AppTheme.palette.text, fontWeight: FontWeight.w600, fontSize: 18),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh_rounded, color: AppTheme.palette.text),
            tooltip: 'Refresh',
            onPressed: () => _loadDashboardData(page: _page),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const SkeletonGroup(padding: EdgeInsets.all(16), children: [SkeletonCards(count: 4, stats: true)]) // round 7
            : RefreshIndicator(
                color: AppTheme.palette.primary,
                onRefresh: () => _loadDashboardData(page: 1),
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    if (_error != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.palette.danger.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.palette.danger.withValues(alpha: 0.3)),
                        ),
                        child: Text(_error!, style: TextStyle(color: AppTheme.palette.danger, fontSize: 13)),
                      ),
                      const SizedBox(height: 12),
                    ],

                    // Top Aggregated Stats
                    if (_stats != null) _buildAggregatedStatsCard(_stats!),
                    const SizedBox(height: 18),

                    // Filters and Search
                    _buildFilterSection(),
                    const SizedBox(height: 16),

                    // Reports Header
                    Row(
                      children: [
                        Text(
                          'Reports ($_totalCount)',
                          style: TextStyle(color: AppTheme.palette.text, fontWeight: FontWeight.w600, fontSize: 15),
                        ),
                        const Spacer(),
                        if (_totalPages > 1)
                          Text(
                            'Page $_page of $_totalPages',
                            style: TextStyle(color: AppTheme.palette.textMuted, fontSize: 12),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // Reports List
                    if (_reports.isEmpty)
                      Container(
                        padding: EdgeInsets.all(32),
                        decoration: BoxDecoration(
                          color: AppTheme.palette.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.palette.border),
                        ),
                        child: Center(
                          child: Text(
                            'No diagnostic reports matching current criteria.',
                            style: TextStyle(color: AppTheme.palette.textMuted, fontSize: 13),
                          ),
                        ),
                      )
                    else
                      ..._reports.map((r) => _buildReportListItem(r)),

                    const SizedBox(height: 16),

                    // Pagination controls
                    if (_totalPages > 1) _buildPaginationControls(),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildAggregatedStatsCard(Map<String, dynamic> stats) {
    final total = (stats['totalReports'] as num?)?.toInt() ?? 0;
    final fullySupportedPct = (stats['fullySupportedPercent'] as num?)?.toDouble() ?? 0.0;
    final topMfg = (stats['topManufacturers'] as List<dynamic>? ?? []);
    final topFailures = (stats['topFailureCategories'] as List<dynamic>? ?? []);

    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.analytics_rounded, color: AppTheme.palette.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                'Overview',
                style: TextStyle(color: AppTheme.palette.text, fontWeight: FontWeight.w600, fontSize: 15),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 3 KPI cards
          Row(
            children: [
              Expanded(
                child: _buildMetricTile(
                  title: '$total',
                  subtitle: 'Total Reports',
                  icon: Icons.assignment_rounded,
                  color: AppTheme.palette.primary,
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: _buildMetricTile(
                  title: '$fullySupportedPct%',
                  subtitle: 'Fully Supported',
                  icon: Icons.check_circle_rounded,
                  color: AppTheme.palette.success,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildMetricTile(
                  title: topMfg.isNotEmpty ? (topMfg.first['manufacturer']?.toString() ?? 'N/A') : 'N/A',
                  subtitle: 'Top Hardware',
                  icon: Icons.phone_android_rounded,
                  color: AppTheme.palette.accent,
                ),
              ),
            ],
          ),

          if (topFailures.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Top Failure / Limitation Categories:',
              style: TextStyle(color: AppTheme.palette.textMuted, fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: topFailures.take(5).map((f) {
                final cat = f['category']?.toString() ?? 'unknown';
                final count = f['failureCount']?.toString() ?? '0';
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.palette.accentSoft,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppTheme.palette.accentBorder),
                  ),
                  child: Text(
                    '$cat: $count',
                    style: TextStyle(color: AppTheme.palette.accentStrong, fontSize: 11, fontWeight: FontWeight.w500),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMetricTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.palette.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.palette.surfaceAlt),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppTheme.palette.text, fontWeight: FontWeight.w600, fontSize: 16),
          ),
          SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppTheme.palette.textMuted, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterSection() {
    return Container(
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.palette.border),
      ),
      child: Column(
        children: [
          // Search box
          TextField(
            controller: _searchCtrl,
            style: TextStyle(color: AppTheme.palette.text, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Search model, manufacturer, email...',
              hintStyle: TextStyle(color: AppTheme.palette.textFaint, fontSize: 13),
              prefixIcon: Icon(Icons.search_rounded, color: AppTheme.palette.textFaint, size: 20),
              suffixIcon: _searchCtrl.text.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.clear_rounded, color: AppTheme.palette.textFaint, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        _loadDashboardData(page: 1);
                      },
                    )
                  : null,
              filled: true,
              fillColor: AppTheme.palette.background,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
            onSubmitted: (_) => _loadDashboardData(page: 1),
          ),
          const SizedBox(height: 10),

          // Filters Row
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildFilterChip(
                  label: 'All Statuses',
                  isSelected: _selectedStatus.isEmpty,
                  onSelected: () {
                    setState(() => _selectedStatus = '');
                    _loadDashboardData(page: 1);
                  },
                ),
                _buildFilterChip(
                  label: 'Submitted',
                  isSelected: _selectedStatus == DiagnosticLifecycleStatus.submitted,
                  onSelected: () {
                    setState(() => _selectedStatus = DiagnosticLifecycleStatus.submitted);
                    _loadDashboardData(page: 1);
                  },
                ),
                _buildFilterChip(
                  label: 'Reviewed',
                  isSelected: _selectedStatus == DiagnosticLifecycleStatus.reviewed,
                  onSelected: () {
                    setState(() => _selectedStatus = DiagnosticLifecycleStatus.reviewed);
                    _loadDashboardData(page: 1);
                  },
                ),
                _buildFilterChip(
                  label: 'Resolved',
                  isSelected: _selectedStatus == DiagnosticLifecycleStatus.resolved,
                  onSelected: () {
                    setState(() => _selectedStatus = DiagnosticLifecycleStatus.resolved);
                    _loadDashboardData(page: 1);
                  },
                ),
                const SizedBox(width: 8),
                _buildFilterChip(
                  label: 'Critical Only',
                  isSelected: _selectedOverall == DiagnosticOverallResult.criticalIssueDetected,
                  onSelected: () {
                    setState(() => _selectedOverall = _selectedOverall.isEmpty
                        ? DiagnosticOverallResult.criticalIssueDetected
                        : '');
                    _loadDashboardData(page: 1);
                  },
                ),
                if (_selectedManufacturer.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  _buildFilterChip(
                    label: 'Mfg: $_selectedManufacturer ✕',
                    isSelected: true,
                    onSelected: () {
                      setState(() => _selectedManufacturer = '');
                      _loadDashboardData(page: 1);
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required bool isSelected,
    required VoidCallback onSelected,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: onSelected,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected ? AppTheme.palette.primarySoft : AppTheme.palette.background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: isSelected ? AppTheme.palette.primary : AppTheme.palette.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? AppTheme.palette.primary : AppTheme.palette.textMuted,
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReportListItem(dynamic item) {
    if (item is! Map) return const SizedBox.shrink();

    final diagnosticId = item['diagnosticId']?.toString() ?? 'Unknown';
    final dev = item['deviceInfo'] is Map ? item['deviceInfo'] as Map : {};
    final mfg = dev['manufacturer']?.toString() ?? 'Unknown';
    final model = dev['model']?.toString() ?? 'Unknown';
    final overall = item['overallResult']?.toString() ?? 'Unknown';
    final lifecycle = item['lifecycleStatus']?.toString() ?? 'Submitted';
    final riderEmail = item['riderEmail']?.toString() ?? 'Anonymous';
    final ts = (item['timestamp'] as num?)?.toInt() ?? 0;
    final dateStr = ts > 0 ? DateTime.fromMillisecondsSinceEpoch(ts).toLocal().toString().split('.').first : '';

    final overallCol = _overallColor(overall);
    final lifeCol = _statusColor(lifecycle);

    return Container(
      margin: EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppTheme.palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.palette.border),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        title: Row(
          children: [
            Text(
              '$mfg $model',
              style: TextStyle(color: AppTheme.palette.text, fontWeight: FontWeight.w600, fontSize: 14),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: lifeCol.withOpacity(0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                lifecycle,
                style: TextStyle(color: lifeCol, fontSize: 10, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: overallCol, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    overall,
                    style: TextStyle(color: overallCol, fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              SizedBox(height: 2),
              Text(
                'Rider: $riderEmail • $dateStr',
                style: TextStyle(color: AppTheme.palette.textFaint, fontSize: 11),
              ),
            ],
          ),
        ),
        trailing: Icon(Icons.chevron_right_rounded, color: AppTheme.palette.textFaint),
        onTap: () => _openReportDetailModal(diagnosticId),
      ),
    );
  }

  Widget _buildPaginationControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: Icon(Icons.arrow_back_ios_rounded, size: 16, color: AppTheme.palette.textMuted),
          onPressed: _page > 1 ? () => _loadDashboardData(page: _page - 1) : null,
        ),
        Text(
          '$_page / $_totalPages',
          style: TextStyle(color: AppTheme.palette.text, fontSize: 13, fontWeight: FontWeight.w600),
        ),
        IconButton(
          icon: Icon(Icons.arrow_forward_ios_rounded, size: 16, color: AppTheme.palette.textMuted),
          onPressed: _page < _totalPages ? () => _loadDashboardData(page: _page + 1) : null,
        ),
      ],
    );
  }

  void _openReportDetailModal(String diagnosticId) {
    showModalBottomSheet(
      context: context,
      sheetAnimationStyle: AppMotion.sheetStyleOf(context), // round 7: spring in, reduce-motion aware
      isScrollControlled: true,
      backgroundColor: AppTheme.palette.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _ReportDetailSheet(
        diagnosticId: diagnosticId,
        onStatusUpdated: () {
          _loadDashboardData(page: _page);
        },
      ),
    );
  }
}

/// Drill-down detail and status review modal sheet.
class _ReportDetailSheet extends StatefulWidget {
  final String diagnosticId;
  final VoidCallback onStatusUpdated;

  const _ReportDetailSheet({
    required this.diagnosticId,
    required this.onStatusUpdated,
  });

  @override
  State<_ReportDetailSheet> createState() => _ReportDetailSheetState();
}

class _ReportDetailSheetState extends State<_ReportDetailSheet> {
  bool _loading = true;
  bool _updating = false;
  Map<String, dynamic>? _report;
  final TextEditingController _notesCtrl = TextEditingController();
  String _selectedStatus = DiagnosticLifecycleStatus.reviewed;

  @override
  void initState() {
    super.initState();
    _fetchDetail();
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchDetail() async {
    try {
      final client = context.read<ApiClient>();
      final res = await client.get('/admin/diagnostics/${widget.diagnosticId}');
      if (res is Map && res['ok'] == true && res['report'] is Map) {
        final r = Map<String, dynamic>.from(res['report'] as Map);
        setState(() {
          _report = r;
          _selectedStatus = r['lifecycleStatus']?.toString() ?? DiagnosticLifecycleStatus.reviewed;
          _notesCtrl.text = r['adminNotes']?.toString() ?? '';
          _loading = false;
        });
      }
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _submitStatusUpdate() async {
    setState(() => _updating = true);
    try {
      final client = context.read<ApiClient>();
      final res = await client.patch('/admin/diagnostics/${widget.diagnosticId}', {
        'status': _selectedStatus,
        'adminNotes': _notesCtrl.text.trim(),
      });
      if (mounted) {
        if (res is Map && res['ok'] == true) {
          adminSnack(context, 'Report status updated to $_selectedStatus.');
          widget.onStatusUpdated();
          Navigator.pop(context);
        } else {
          adminSnack(context, 'Failed to update report status.', error: true);
        }
      }
    } catch (e) {
      if (mounted) adminSnack(context, 'Update error: $e', error: true);
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SizedBox(
        height: 350,
        child: const ClipRect(child: SkeletonList(padding: EdgeInsets.zero)), // round 7
      );
    }

    final r = _report;
    if (r == null) {
      return SizedBox(
        height: 250,
        child: Center(child: Text('Report details unavailable.', style: TextStyle(color: AppTheme.palette.textMuted))),
      );
    }

    final dev = r['deviceInfo'] is Map ? r['deviceInfo'] as Map : {};
    final overall = r['overallResult']?.toString() ?? 'Unknown';
    final categories = r['categories'] is Map ? r['categories'] as Map : {};
    final reviewHistory = r['reviewHistory'] is List ? (r['reviewHistory'] as List) : [];

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scrollCtrl) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: ListView(
          controller: scrollCtrl,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: AppTheme.palette.borderStrong, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 14),

            // Header
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${dev['manufacturer'] ?? ''} ${dev['model'] ?? 'Device'}',
                    style: TextStyle(color: AppTheme.palette.text, fontWeight: FontWeight.w600, fontSize: 18),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close_rounded, color: AppTheme.palette.textMuted),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            Text(
              'Report ID: ${r['diagnosticId'] ?? widget.diagnosticId}',
              style: TextStyle(color: AppTheme.palette.textFaint, fontSize: 11),
            ),
            const SizedBox(height: 12),

            // Overall Summary
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.palette.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.palette.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('Overall Compatibility: ', style: TextStyle(color: AppTheme.palette.textMuted, fontSize: 12)),
                      Text(overall, style: TextStyle(color: AppTheme.palette.primary, fontWeight: FontWeight.w600, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    r['overallSummary']?.toString() ?? '',
                    style: TextStyle(color: AppTheme.palette.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Hardware Specs
            Text('Hardware & OS Specifications', style: TextStyle(color: AppTheme.palette.text, fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 8),
            _specRow('Operating System', '${dev['osVersion'] ?? 'Android'} (API ${dev['apiLevel'] ?? ''})'),
            _specRow('App Version', 'v${dev['appVersion'] ?? ''}+${dev['buildNumber'] ?? ''}'),
            _specRow('CPU Architecture', dev['cpuArch']?.toString() ?? 'Unknown'),
            _specRow('Battery Optimization', dev['batteryOptimizationStatus']?.toString() ?? 'Unknown'),

            const SizedBox(height: 16),
            Text('Categories & Sensors', style: TextStyle(color: AppTheme.palette.text, fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 8),

            ...categories.entries.map((e) {
              final val = e.value is Map ? e.value as Map : {};
              final title = val['title']?.toString() ?? e.key.toString();
              final status = val['status']?.toString() ?? 'Not Tested';
              final summary = val['summary']?.toString() ?? '';

              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.palette.background,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: TextStyle(color: AppTheme.palette.text, fontSize: 13, fontWeight: FontWeight.w600)),
                          if (summary.isNotEmpty)
                            Text(summary, style: TextStyle(color: AppTheme.palette.textMuted, fontSize: 11)),
                        ],
                      ),
                    ),
                    Text(status, style: TextStyle(color: _statusColor(status), fontSize: 11, fontWeight: FontWeight.w600)),
                  ],
                ),
              );
            }),

            SizedBox(height: 16),
            Text('Admin Lifecycle Review & Notes', style: TextStyle(color: AppTheme.palette.text, fontWeight: FontWeight.w600, fontSize: 14)),
            SizedBox(height: 10),

            // Status Selector Dropdown
            DropdownButtonFormField<String>(
              value: _selectedStatus,
              dropdownColor: AppTheme.palette.surface,
              style: TextStyle(color: AppTheme.palette.text, fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Lifecycle Status',
                labelStyle: TextStyle(color: AppTheme.palette.textMuted),
                filled: true,
                fillColor: AppTheme.palette.background,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              ),
              items: DiagnosticLifecycleStatus.values.map((s) {
                return DropdownMenuItem(value: s, child: Text(s));
              }).toList(),
              onChanged: (v) {
                if (v != null) setState(() => _selectedStatus = v);
              },
            ),
            SizedBox(height: 10),

            // Admin Notes Field
            TextField(
              controller: _notesCtrl,
              maxLines: 3,
              style: TextStyle(color: AppTheme.palette.text, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Add internal engineering or support review notes...',
                hintStyle: TextStyle(color: AppTheme.palette.textFaint, fontSize: 12),
                filled: true,
                fillColor: AppTheme.palette.background,
                contentPadding: const EdgeInsets.all(12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 12),

            // Save Status Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: _updating
                    ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.palette.onPrimary))
                    : const Icon(Icons.check_circle_outline_rounded, size: 18),
                label: Text(_updating ? 'Saving...' : 'Update Report Status & Notes'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.palette.primary,
                  foregroundColor: AppTheme.palette.onPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _updating ? null : _submitStatusUpdate,
              ),
            ),

            if (reviewHistory.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Audit & Review History', style: TextStyle(color: AppTheme.palette.textMuted, fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              ...reviewHistory.map((h) {
                final action = h['action']?.toString() ?? '';
                final by = h['by']?.toString() ?? 'admin';
                final at = (h['at'] as num?)?.toInt() ?? 0;
                final atStr = at > 0 ? DateTime.fromMillisecondsSinceEpoch(at).toLocal().toString().split('.').first : '';
                final notes = h['adminNotes']?.toString() ?? '';

                return Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '• [$action] by $by at $atStr ${notes.isNotEmpty ? "- $notes" : ""}',
                    style: TextStyle(color: AppTheme.palette.textFaint, fontSize: 11),
                  ),
                );
              }),
            ],
            SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _specRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(label, style: TextStyle(color: AppTheme.palette.textMuted, fontSize: 12)),
          Spacer(),
          Text(value, style: TextStyle(color: AppTheme.palette.text, fontSize: 12, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case DiagnosticStatus.ready:
      case DiagnosticStatus.supported:
        return AppTheme.palette.success;
      case DiagnosticStatus.limited:
      case DiagnosticStatus.permissionRequired:
        return AppTheme.palette.warning;
      case DiagnosticStatus.failed:
      case DiagnosticStatus.unsupported:
        return AppTheme.palette.danger;
      default:
        return AppTheme.palette.textMuted;
    }
  }
}
