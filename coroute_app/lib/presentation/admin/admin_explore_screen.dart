import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/explore_service.dart';
import 'admin_nav.dart';
import 'admin_payments_widgets.dart' show adminErrorOf;
import 'admin_ui.dart';

/// v3.59 in-app admin "Explore" (MASTER_ADMIN): the same settings as the web console's Explore page, for quick
/// changes from the phone:
///  * Places: show / hide each destination, feature it (adds it to "Picked for you").
///  * Layout: turn sections on or off and re-order them; show / hide categories; rider route switches.
///  * Rider routes: shared routes, hide / show / delete.
/// Adding places, photos and custom categories is done in the web console (bigger forms).
class AdminExploreScreen extends StatefulWidget {
  const AdminExploreScreen({super.key});

  @override
  State<AdminExploreScreen> createState() => _AdminExploreScreenState();
}

enum _Tab { places, layout, routes }

class _AdminExploreScreenState extends State<AdminExploreScreen> {
  _Tab _tab = _Tab.places;
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _places = const [];
  Map<String, dynamic>? _cfg;
  Map<String, int> _counts = const {};
  List<Map<String, dynamic>> _routes = const [];
  final Set<String> _busy = {};

  ExploreService get _svc => ExploreService(context.read<ApiClient>());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final svc = _svc;
      final results = await Future.wait([svc.adminDestinations(), svc.adminConfig(), svc.adminRoutes()]);
      if (!mounted) return;
      final cfgRes = results[1] as Map<String, dynamic>;
      setState(() {
        _places = results[0] as List<Map<String, dynamic>>;
        _cfg = Map<String, dynamic>.from(cfgRes['config'] as Map);
        final c = cfgRes['counts'];
        _counts = {if (c is Map) for (final e in c.entries) if (e.value is num) '${e.key}': (e.value as num).toInt()};
        _routes = results[2] as List<Map<String, dynamic>>;
      });
    } catch (e) {
      if (mounted) setState(() => _error = adminErrorOf(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(String key, Future<void> Function() job, String done) async {
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    try {
      await job();
      if (mounted) adminSnack(context, done);
      await _load();
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  List<String> get _featured => [for (final f in (_cfg?['featured'] as List? ?? const [])) '$f'];

  Future<void> _saveCfg(String done) => _run('cfg', () => _svc.adminSaveConfig(_cfg!), done);

  @override
  Widget build(BuildContext context) {
    final e = _error;
    return AdminShell(
      title: 'Explore',
      subtitle: 'What riders see in the Explore tab',
      actions: [AdminIconAction(icon: Icons.refresh_rounded, label: 'Refresh', onTap: _load)],
      nav: adminNavItems(context, AdminPage.explore),
      tabs: adminSectionTabs(context, AdminPage.explore),
      body: LoadingState(
        loading: _loading && _cfg == null,
        child: _cfg == null && e != null
            ? AdminErrorState(message: e, onRetry: _load)
            : adminRefresh(
                onRefresh: _load,
                child: LayoutBuilder(builder: (context, c) {
                  final wide = c.maxWidth >= adminWideBreakpoint;
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    children: [
                      AdminContent(
                        wide: wide,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SegmentedButton<_Tab>(
                              segments: const [
                                ButtonSegment(value: _Tab.places, label: Text('Places'), icon: Icon(Icons.place_outlined)),
                                ButtonSegment(value: _Tab.layout, label: Text('Layout'), icon: Icon(Icons.view_agenda_outlined)),
                                ButtonSegment(value: _Tab.routes, label: Text('Routes'), icon: Icon(Icons.alt_route_rounded)),
                              ],
                              selected: {_tab},
                              showSelectedIcon: false,
                              onSelectionChanged: (s) => setState(() => _tab = s.first),
                            ),
                            const SizedBox(height: Space.s16),
                            if (_cfg != null)
                              switch (_tab) {
                                _Tab.places => _placesTab(),
                                _Tab.layout => _layoutTab(),
                                _Tab.routes => _routesTab(),
                              },
                            const SizedBox(height: Space.s12),
                            Text('Add places, photos and your own categories in the web admin (Explore page).', style: AppText.caption),
                          ],
                        ),
                      ),
                    ],
                  );
                }),
              ),
      ),
    );
  }

  Widget _placesTab() {
    if (_places.isEmpty) return const AdminCard(child: Text('No places yet. Add them in the web admin.'));
    final featured = _featured;
    return AdminCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          for (var i = 0; i < _places.length; i++)
            Builder(builder: (_) {
              final p = _places[i];
              final id = '${p['id']}';
              final active = p['active'] != false;
              final isFeatured = featured.contains(id);
              final routes = _counts[id] ?? 0;
              return Container(
                constraints: const BoxConstraints(minHeight: 64),
                decoration: BoxDecoration(border: i < _places.length - 1 ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${p['name']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700, color: active ? AppTheme.text : AppTheme.muted)),
                          Text(['${p['region'] ?? ''}', '${p['category']}', if (routes > 0) '$routes routes'].where((s) => s.isNotEmpty).join(' · '),
                              maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: isFeatured ? 'Remove from Picked for you' : 'Add to Picked for you',
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      icon: Icon(isFeatured ? Icons.star_rounded : Icons.star_outline_rounded, color: isFeatured ? AppTheme.accentText : AppTheme.text2),
                      onPressed: !active && !isFeatured
                          ? null
                          : () {
                              final list = [...featured];
                              isFeatured ? list.remove(id) : list.add(id);
                              _cfg!['featured'] = list;
                              _saveCfg(isFeatured ? 'Removed from Picked for you' : 'Added to Picked for you');
                            },
                    ),
                    Switch(
                      value: active,
                      onChanged: _busy.contains(id) ? null : (v) => _run(id, () => _svc.adminPatchDestination(id, {'active': v}), v ? '${p['name']} is shown' : '${p['name']} is hidden'),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _layoutTab() {
    final cfg = _cfg!;
    final sections = [for (final s in (cfg['sections'] as List? ?? const [])) Map<String, dynamic>.from(s as Map)];
    final cats = [for (final s in (cfg['categories'] as List? ?? const [])) Map<String, dynamic>.from(s as Map)];
    final routes = Map<String, dynamic>.from((cfg['routes'] as Map?) ?? const {});
    void apply() {
      cfg['sections'] = sections;
      cfg['categories'] = cats;
      cfg['routes'] = routes;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdminTitledCard(
          title: 'Sections, top to bottom',
          child: Column(
            children: [
              for (var i = 0; i < sections.length; i++)
                Row(
                  children: [
                    Expanded(child: Text('${sections[i]['title']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body)),
                    IconButton(
                      tooltip: 'Move up',
                      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                      onPressed: i == 0
                          ? null
                          : () => setState(() {
                                sections.insert(i - 1, sections.removeAt(i));
                                apply();
                              }),
                      icon: const Icon(Icons.arrow_upward_rounded),
                    ),
                    Switch(
                      value: sections[i]['enabled'] != false,
                      onChanged: (v) => setState(() {
                        sections[i]['enabled'] = v;
                        apply();
                      }),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: Space.s12),
        AdminTitledCard(
          title: 'Categories',
          child: Column(
            children: [
              for (var i = 0; i < cats.length; i++)
                Row(
                  children: [
                    Expanded(child: Text('${cats[i]['label']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body)),
                    IconButton(
                      tooltip: 'Move up',
                      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                      onPressed: i == 0
                          ? null
                          : () => setState(() {
                                cats.insert(i - 1, cats.removeAt(i));
                                apply();
                              }),
                      icon: const Icon(Icons.arrow_upward_rounded),
                    ),
                    Switch(
                      value: cats[i]['enabled'] != false,
                      onChanged: (v) => setState(() {
                        cats[i]['enabled'] = v;
                        apply();
                      }),
                    ),
                  ],
                ),
              Text('Hiding a category hides its places too.', style: AppText.caption),
            ],
          ),
        ),
        const SizedBox(height: Space.s12),
        AdminTitledCard(
          title: 'Rider routes',
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Riders can share and see routes'),
                value: routes['enabled'] != false,
                onChanged: (v) => setState(() {
                  routes['enabled'] = v;
                  apply();
                }),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show riders\' tips with their routes'),
                value: routes['showNotes'] != false,
                onChanged: (v) => setState(() {
                  routes['showNotes'] = v;
                  apply();
                }),
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.s12),
        DsButton(label: _busy.contains('cfg') ? 'Saving…' : 'Save layout', icon: Icons.save_outlined, height: 52, onPressed: _busy.contains('cfg') ? null : () => _saveCfg('Explore layout saved')),
      ],
    );
  }

  Widget _routesTab() {
    if (_routes.isEmpty) return const AdminCard(child: Text('No rider has shared a route yet.'));
    final names = {for (final p in _places) '${p['id']}': '${p['name']}'};
    return AdminCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          for (var i = 0; i < _routes.length; i++)
            Builder(builder: (_) {
              final r = _routes[i];
              final id = '${r['id']}';
              final live = r['status'] == 'live';
              return Container(
                constraints: const BoxConstraints(minHeight: 64),
                decoration: BoxDecoration(border: i < _routes.length - 1 ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('@${r['username']} · ${names['${r['destId']}'] ?? 'place'}', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                          Text(['${r['day'] ?? ''}', '${r['distanceKm']} km', if ('${r['note'] ?? ''}'.isNotEmpty) '"${r['note']}"', if (!live) 'hidden'].where((s) => s.isNotEmpty).join(' · '),
                              maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.caption),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: live ? 'Hide route' : 'Show route',
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      onPressed: _busy.contains(id) ? null : () => _run(id, () => _svc.adminSetRouteStatus(id, live ? 'hidden' : 'live'), live ? 'Route hidden' : 'Route shown'),
                      icon: Icon(live ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    ),
                    IconButton(
                      tooltip: 'Delete route',
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      onPressed: _busy.contains(id)
                          ? null
                          : () async {
                              final ok = await confirmAction(context, title: 'Delete this route?', message: 'The route by @${r['username']} is deleted for good.', confirmLabel: 'Delete', destructive: true);
                              if (ok) await _run(id, () => _svc.adminDeleteRoute(id), 'Route deleted');
                            },
                      icon: Icon(Icons.delete_outline_rounded, color: AppTheme.sos),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}
