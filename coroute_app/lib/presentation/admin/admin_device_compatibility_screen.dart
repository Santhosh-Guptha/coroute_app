import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/device_diagnostic_report.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
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
        return const Color(0xFF10B981);
      case DiagnosticOverallResult.supportedWithLimitations:
        return const Color(0xFFF59E0B);
      case DiagnosticOverallResult.limitedCompatibility:
        return Colors.orangeAccent;
      case DiagnosticOverallResult.criticalIssueDetected:
        return const Color(0xFFEF4444);
      default:
        return const Color(0xFF6B7280);
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case DiagnosticLifecycleStatus.submitted:
        return const Color(0xFF3B82F6);
      case DiagnosticLifecycleStatus.reviewed:
        return const Color(0xFF8B5CF6);
      case DiagnosticLifecycleStatus.resolved:
        return const Color(0xFF10B981);
      case DiagnosticLifecycleStatus.failed:
        return const Color(0xFFEF4444);
      default:
        return const Color(0xFF9CA3AF);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    if (!auth.isMasterAdmin) {
      return Scaffold(
        backgroundColor: const Color(0xFF0D1117),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0D1117),
          title: const Text('Access Denied', style: TextStyle(color: Colors.white)),
        ),
        body: const Center(
          child: Text(
            'Master administrator privileges required to view device compatibility diagnostics.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1117),
        elevation: 0,
        title: const Text(
          'Phone compatibility',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            tooltip: 'Refresh',
            onPressed: () => _loadDashboardData(page: _page),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: Colors.tealAccent))
            : RefreshIndicator(
                color: Colors.tealAccent,
                onRefresh: () => _loadDashboardData(page: 1),
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    if (_error != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
                        ),
                        child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
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
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        const Spacer(),
                        if (_totalPages > 1)
                          Text(
                            'Page $_page of $_totalPages',
                            style: const TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    // Reports List
                    if (_reports.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(32),
                        decoration: BoxDecoration(
                          color: const Color(0xFF161B22),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: const Center(
                          child: Text(
                            'No diagnostic reports matching current criteria.',
                            style: TextStyle(color: Colors.white54, fontSize: 13),
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.analytics_rounded, color: Colors.tealAccent, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Overview',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
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
                  color: Colors.blueAccent,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildMetricTile(
                  title: '$fullySupportedPct%',
                  subtitle: 'Fully Supported',
                  icon: Icons.check_circle_rounded,
                  color: const Color(0xFF10B981),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildMetricTile(
                  title: topMfg.isNotEmpty ? (topMfg.first['manufacturer']?.toString() ?? 'N/A') : 'N/A',
                  subtitle: 'Top Hardware',
                  icon: Icons.phone_android_rounded,
                  color: Colors.purpleAccent,
                ),
              ),
            ],
          ),

          if (topFailures.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Top Failure / Limitation Categories:',
              style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
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
                    color: Colors.amber.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.amber.withOpacity(0.3)),
                  ),
                  child: Text(
                    '$cat: $count',
                    style: const TextStyle(color: Colors.amberAccent, fontSize: 11, fontWeight: FontWeight.w500),
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1117),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
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
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterSection() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: [
          // Search box
          TextField(
            controller: _searchCtrl,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Search model, manufacturer, email...',
              hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
              prefixIcon: const Icon(Icons.search_rounded, color: Colors.white38, size: 20),
              suffixIcon: _searchCtrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded, color: Colors.white38, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        _loadDashboardData(page: 1);
                      },
                    )
                  : null,
              filled: true,
              fillColor: const Color(0xFF0D1117),
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected ? Colors.tealAccent.withOpacity(0.2) : const Color(0xFF0D1117),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: isSelected ? Colors.tealAccent : Colors.white12),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? Colors.tealAccent : Colors.white70,
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
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
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        title: Row(
          children: [
            Text(
              '$mfg $model',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
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
                style: TextStyle(color: lifeCol, fontSize: 10, fontWeight: FontWeight.bold),
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
              const SizedBox(height: 2),
              Text(
                'Rider: $riderEmail • $dateStr',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
        ),
        trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
        onTap: () => _openReportDetailModal(diagnosticId),
      ),
    );
  }

  Widget _buildPaginationControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_back_ios_rounded, size: 16, color: Colors.white70),
          onPressed: _page > 1 ? () => _loadDashboardData(page: _page - 1) : null,
        ),
        Text(
          '$_page / $_totalPages',
          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
        ),
        IconButton(
          icon: const Icon(Icons.arrow_forward_ios_rounded, size: 16, color: Colors.white70),
          onPressed: _page < _totalPages ? () => _loadDashboardData(page: _page + 1) : null,
        ),
      ],
    );
  }

  void _openReportDetailModal(String diagnosticId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161B22),
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
      return const SizedBox(
        height: 350,
        child: Center(child: CircularProgressIndicator(color: Colors.tealAccent)),
      );
    }

    final r = _report;
    if (r == null) {
      return const SizedBox(
        height: 250,
        child: Center(child: Text('Report details unavailable.', style: TextStyle(color: Colors.white70))),
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
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 14),

            // Header
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${dev['manufacturer'] ?? ''} ${dev['model'] ?? 'Device'}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            Text(
              'Report ID: ${r['diagnosticId'] ?? widget.diagnosticId}',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const SizedBox(height: 12),

            // Overall Summary
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1117),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('Overall Compatibility: ', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      Text(overall, style: const TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    r['overallSummary']?.toString() ?? '',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Hardware Specs
            const Text('Hardware & OS Specifications', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),
            _specRow('Operating System', '${dev['osVersion'] ?? 'Android'} (API ${dev['apiLevel'] ?? ''})'),
            _specRow('App Version', 'v${dev['appVersion'] ?? ''}+${dev['buildNumber'] ?? ''}'),
            _specRow('CPU Architecture', dev['cpuArch']?.toString() ?? 'Unknown'),
            _specRow('Battery Optimization', dev['batteryOptimizationStatus']?.toString() ?? 'Unknown'),

            const SizedBox(height: 16),
            const Text('Categories & Sensors', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 8),

            ...categories.entries.map((e) {
              final val = e.value is Map ? e.value as Map : {};
              final title = val['title']?.toString() ?? e.key.toString();
              final status = val['status']?.toString() ?? 'Not Tested';
              final summary = val['summary']?.toString() ?? '';

              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D1117),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                          if (summary.isNotEmpty)
                            Text(summary, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                        ],
                      ),
                    ),
                    Text(status, style: TextStyle(color: _statusColor(status), fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
              );
            }),

            const SizedBox(height: 16),
            const Text('Admin Lifecycle Review & Notes', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 10),

            // Status Selector Dropdown
            DropdownButtonFormField<String>(
              value: _selectedStatus,
              dropdownColor: const Color(0xFF1E293B),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Lifecycle Status',
                labelStyle: const TextStyle(color: Colors.white54),
                filled: true,
                fillColor: const Color(0xFF0D1117),
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
            const SizedBox(height: 10),

            // Admin Notes Field
            TextField(
              controller: _notesCtrl,
              maxLines: 3,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Add internal engineering or support review notes...',
                hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                filled: true,
                fillColor: const Color(0xFF0D1117),
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
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : const Icon(Icons.check_circle_outline_rounded, size: 18),
                label: Text(_updating ? 'Saving...' : 'Update Report Status & Notes'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.tealAccent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _updating ? null : _submitStatusUpdate,
              ),
            ),

            if (reviewHistory.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('Audit & Review History', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              ...reviewHistory.map((h) {
                final action = h['action']?.toString() ?? '';
                final by = h['by']?.toString() ?? 'admin';
                final at = (h['at'] as num?)?.toInt() ?? 0;
                final atStr = at > 0 ? DateTime.fromMillisecondsSinceEpoch(at).toLocal().toString().split('.').first : '';
                final notes = h['adminNotes']?.toString() ?? '';

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '• [$action] by $by at $atStr ${notes.isNotEmpty ? "- $notes" : ""}',
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                );
              }),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _specRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const Spacer(),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case DiagnosticStatus.ready:
      case DiagnosticStatus.supported:
        return const Color(0xFF10B981);
      case DiagnosticStatus.limited:
      case DiagnosticStatus.permissionRequired:
        return const Color(0xFFF59E0B);
      case DiagnosticStatus.failed:
      case DiagnosticStatus.unsupported:
        return const Color(0xFFEF4444);
      default:
        return const Color(0xFF6B7280);
    }
  }
}
