import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import 'admin_ui.dart';
import 'admin_nav.dart';

/// 3.55 admin: rider crews and their polls, for moderation (docs/features_355/crews_polls.md).
/// Lists crews (search by name), shows one crew's members and polls, deletes a poll or a whole
/// crew (both audited, members are told). There is no chat to moderate: crews only have polls.
///
/// GET /api/admin/crews?q=, GET /api/admin/crews/:crewId, DELETE /api/admin/crews/:crewId,
/// DELETE /api/admin/crews/:crewId/polls/:pollId.
class AdminCrewsScreen extends StatefulWidget {
  const AdminCrewsScreen({super.key});

  @override
  State<AdminCrewsScreen> createState() => _AdminCrewsScreenState();
}

class _AdminCrewsScreenState extends State<AdminCrewsScreen> {
  final _search = TextEditingController();
  List<Map<String, dynamic>> _crews = const [];
  int _total = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final q = _search.text.trim();
      final res = await context.read<ApiClient>().get('/admin/crews?limit=200${q.isEmpty ? '' : '&q=${Uri.encodeQueryComponent(q)}'}');
      if (!mounted) return;
      setState(() {
        _crews = res is Map && res['crews'] is List ? (res['crews'] as List).whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList() : const [];
        _total = res is Map && res['total'] is num ? (res['total'] as num).toInt() : _crews.length;
        _error = null;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not load crews.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _open(Map<String, dynamic> crew) async {
    final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => _AdminCrewDetail(crewId: crew['crewId'].toString())));
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    return AdminShell(
      title: 'Crews',
      subtitle: '$_total crews · polls only, no chat',
      onBack: () => Navigator.maybePop(context),
      nav: adminNavItems(context, AdminPage.crews),
      tabs: adminSectionTabs(context, AdminPage.crews),
      actions: [AdminIconAction(icon: Icons.refresh_rounded, label: 'Refresh', onTap: _load)],
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            children: [
              TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(labelText: 'Search by crew name', prefixIcon: Icon(Icons.search_rounded)),
                onSubmitted: (_) => _load(),
              ),
              const SizedBox(height: 12),
              if (_loading)
                const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
              else if (_error != null)
                AdminCard(warning: true, child: Text(_error!, style: AppText.body))
              else if (_crews.isEmpty)
                AdminCard(child: Text('No crews found.', style: AppText.body))
              else
                AdminCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: [
                      for (var i = 0; i < _crews.length; i++)
                        AdminRow(
                          leading: const AdminRowIcon(Icons.groups_2_outlined),
                          title: _crews[i]['name']?.toString() ?? '',
                          subtitle: 'Admin ${_crews[i]['admin'] ?? '-'} · ${_crews[i]['memberCount'] ?? 0} riders',
                          detail: '${_crews[i]['polls'] ?? 0} polls, ${_crews[i]['openPolls'] ?? 0} open',
                          divider: i < _crews.length - 1,
                          onTap: () => _open(_crews[i]),
                        ),
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

class _AdminCrewDetail extends StatefulWidget {
  final String crewId;
  const _AdminCrewDetail({required this.crewId});

  @override
  State<_AdminCrewDetail> createState() => _AdminCrewDetailState();
}

class _AdminCrewDetailState extends State<_AdminCrewDetail> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _path => '/admin/crews/${Uri.encodeComponent(widget.crewId)}';

  Future<void> _load() async {
    try {
      final res = await context.read<ApiClient>().get(_path);
      if (mounted) setState(() => _data = res is Map ? Map<String, dynamic>.from(res) : null);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _say(String text) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _deletePoll(Map poll) async {
    if (!await confirmAction(context,
        title: 'Delete this poll?', message: '"${poll['question']}" and its votes are deleted. This is recorded in the audit log.', confirmLabel: 'Delete', destructive: true)) {
      return;
    }
    if (!mounted) return;
    try {
      await context.read<ApiClient>().delete('$_path/polls/${Uri.encodeComponent(poll['pollId'].toString())}');
      _changed = true;
      _say('Poll deleted');
      await _load();
    } on ApiException catch (e) {
      _say(e.message);
    }
  }

  Future<void> _deleteCrew(String name) async {
    if (!await confirmAction(context,
        title: 'Delete $name?', message: 'The crew, its polls and votes are deleted and its riders are told. This is recorded in the audit log.', confirmLabel: 'Delete crew', destructive: true)) {
      return;
    }
    if (!mounted) return;
    try {
      await context.read<ApiClient>().delete(_path);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      _say(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final crew = d?['crew'] is Map ? d!['crew'] as Map : const {};
    final members = d?['members'] is List ? (d!['members'] as List).whereType<Map>().toList() : const <Map>[];
    final polls = d?['polls'] is List ? (d!['polls'] as List).whereType<Map>().toList() : const <Map>[];
    final name = crew['name']?.toString() ?? 'Crew';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: AdminShell(
        title: name,
        subtitle: '${members.length} riders · ${polls.length} polls',
        onBack: () => Navigator.pop(context, _changed),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
              children: [
                if (_error != null)
                  AdminCard(warning: true, child: Text(_error!, style: AppText.body))
                else if (d == null)
                  const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
                else ...[
                  if ((crew['description']?.toString() ?? '').isNotEmpty) ...[
                    AdminCard(child: Text(crew['description'].toString(), style: AppText.body)),
                    const SizedBox(height: 16),
                  ],
                  const AdminSectionLabel('Polls'),
                  const SizedBox(height: 8),
                  if (polls.isEmpty) AdminCard(child: Text('No polls.', style: AppText.body)),
                  for (final p in polls)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: AdminCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(children: [
                              Expanded(child: Text(p['question']?.toString() ?? '', style: AppText.title)),
                              AdminIconAction(icon: Icons.delete_outline_rounded, label: 'Delete poll', onTap: () => _deletePoll(p)),
                            ]),
                            Text('${p['status']} · ${p['totalVoters'] ?? 0} votes · by ${p['createdBy'] ?? 'former rider'}',
                                style: AppText.caption.copyWith(color: AppTheme.text2)),
                            const SizedBox(height: 6),
                            for (final o in (p['options'] is List ? (p['options'] as List).whereType<Map>() : const <Map>[]))
                              Text('${o['text']}: ${o['count'] ?? 0}', style: AppText.body),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  const AdminSectionLabel('Riders'),
                  const SizedBox(height: 8),
                  AdminCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Column(
                      children: [
                        for (var i = 0; i < members.length; i++)
                          AdminRow(
                            leading: const AdminRowIcon(Icons.person_outline_rounded),
                            title: members[i]['username']?.toString() ?? '',
                            subtitle: members[i]['role']?.toString(),
                            divider: i < members.length - 1,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  DsButton(label: 'Delete crew', icon: Icons.delete_outline_rounded, tone: DsButtonTone.sos, onPressed: () => _deleteCrew(name)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
