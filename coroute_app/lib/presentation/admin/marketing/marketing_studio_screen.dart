import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../data/services/api_client.dart';
import '../../../domain/marketing/marketing_placeholders.dart';
import '../../../domain/marketing/marketing_template.dart';
import '../../../domain/marketing/starter_templates.dart';
import '../admin_payments_logic.dart';
import '../admin_payments_widgets.dart';
import '../admin_ui.dart';
import 'marketing_api.dart';
import 'marketing_editor_screen.dart';
import 'marketing_painter.dart';

/// 3.55 Marketing studio (admin console): saved offer-image templates, starter templates and the
/// editor. Templates live on the gateway (/api/admin/marketing/templates); while the admin switch
/// `marketingStudio` is off the gateway answers FEATURE_OFF and this screen says so.
class MarketingStudioScreen extends StatefulWidget {
  const MarketingStudioScreen({super.key});

  @override
  State<MarketingStudioScreen> createState() => _MarketingStudioScreenState();
}

class _MarketingStudioScreenState extends State<MarketingStudioScreen> {
  List<MkTemplateSummary> _templates = const [];
  String _status = 'active';
  bool _loading = true;
  bool _loaded = false;
  String? _error;

  MarketingApi get _api => MarketingApi(context.read<ApiClient>());

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _templates = await _api.list(status: _status);
      _loaded = true;
    } catch (e) {
      _error = e is ApiException && e.code == 'FEATURE_OFF' ? 'The marketing studio is switched off. Turn on "Marketing studio" in Features to use it.' : adminErrorOf(e);
      if (mounted && _loaded) adminSnack(context, _error!, error: true);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openEditor(MarketingTemplate t) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => MarketingEditorScreen(initial: t)));
    if (mounted) _load();
  }

  Future<void> _open(MkTemplateSummary s) async {
    try {
      final t = await _api.get(s.id);
      if (!mounted) return;
      await _openEditor(t);
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
    }
  }

  Future<void> _new() async {
    final picked = await showAppSheet<MarketingTemplate>(
      context,
      isScrollControlled: true,
      title: 'New offer image',
      builder: (_) => const _StarterPicker(),
    );
    if (picked != null && mounted) await _openEditor(picked);
  }

  Future<void> _rowAction(MkTemplateSummary s, String action) async {
    try {
      switch (action) {
        case 'duplicate':
          await _api.duplicate(s.id);
          if (mounted) adminSnack(context, 'Copied "${s.name}".');
        case 'archive':
          await _api.setStatus(s.id, 'archived');
          if (mounted) adminSnack(context, 'Archived "${s.name}".');
        case 'restore':
          await _api.setStatus(s.id, 'active');
          if (mounted) adminSnack(context, 'Restored "${s.name}".');
        case 'delete':
          final ok = await confirmAction(context, title: 'Delete template?', message: '"${s.name}" is deleted for every admin. Images already shared are not affected.', confirmLabel: 'Delete', destructive: true);
          if (!ok) return;
          await _api.delete(s.id);
          if (mounted) adminSnack(context, 'Deleted "${s.name}".');
      }
      _load();
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AdminShell(
      title: 'Marketing studio',
      subtitle: 'Offer and coupon images to share',
      onBack: () => Navigator.maybePop(context),
      actions: [AdminIconAction(icon: Icons.add_rounded, label: 'New image', onTap: _new)],
      body: AdminTabBody(
        loading: _loading,
        hasData: _loaded,
        error: _error,
        onRefresh: _load,
        children: [
          Row(children: [
            for (final s in const ['active', 'archived', 'all'])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(adminCapitalize(s)),
                  selected: _status == s,
                  onSelected: (_) {
                    setState(() => _status = s);
                    _load();
                  },
                ),
              ),
          ]),
          const SizedBox(height: 12),
          AdminTable(
            title: 'Templates (${_templates.length})',
            trailing: TextButton.icon(
              onPressed: _new,
              icon: Icon(Icons.add_rounded, color: AppTheme.accentText),
              label: Text('New image', style: TextStyle(color: AppTheme.accentText, fontWeight: FontWeight.w800)),
            ),
            rows: [
              for (var i = 0; i < _templates.length; i++) _row(_templates[i], i == _templates.length - 1),
            ],
            empty: Text('No templates yet. Start from a starter template.', style: AppText.caption),
          ),
          const SizedBox(height: 16),
          StatusLine(
            icon: Icons.info_outline_rounded,
            text: 'Bind a template to an active coupon: the code, discount, validity and plan fill in by themselves and follow coupon changes.',
            color: AppTheme.text2,
          ),
        ],
      ),
    );
  }

  Widget _row(MkTemplateSummary s, bool last) {
    final archived = s.status == 'archived';
    return AdminRow(
      key: ValueKey(s.id),
      leading: AdminRowIcon(Icons.image_outlined, color: archived ? AppTheme.muted : null),
      title: s.name,
      subtitle: [s.size.label, s.couponCode == null ? 'no coupon' : 'code ${s.couponCode}', '${s.layerCount} layers'].join(' · '),
      detail: s.updatedAt == null ? null : 'Saved ${adminDate(s.updatedAt, time: true)}${s.updatedBy == null ? '' : ' by ${s.updatedBy}'}',
      status: archived ? StatusTextChip(icon: Icons.inventory_2_outlined, text: 'Archived', color: AppTheme.muted) : null,
      onTap: () => _open(s),
      divider: !last,
      trailing: PopupMenuButton<String>(
        tooltip: 'More',
        onSelected: (a) => _rowAction(s, a),
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
          PopupMenuItem(value: archived ? 'restore' : 'archive', child: Text(archived ? 'Restore' : 'Archive')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}

/// The starter gallery: each starter drawn with sample values, plus a blank canvas per size.
class _StarterPicker extends StatelessWidget {
  const _StarterPicker();

  @override
  Widget build(BuildContext context) {
    final site = AppConfig.apiBaseUrl;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        Text('Starter templates', style: AppText.label),
        const SizedBox(height: 8),
        Wrap(spacing: 12, runSpacing: 12, children: [
          for (final s in MkStarters.all) _StarterTile(template: s.build(), title: s.title, subtitle: s.description, site: site),
        ]),
        const SizedBox(height: 20),
        Text('Blank canvas', style: AppText.label),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in MkSizePreset.all)
            ActionChip(
              label: Text('${p.label} ${p.width}×${p.height}'),
              onPressed: () => Navigator.pop(context, MkStarters.blank(MkSize.of(p))),
            ),
        ]),
      ],
    );
  }
}

class _StarterTile extends StatelessWidget {
  final MarketingTemplate template;
  final String title;
  final String subtitle;
  final String site;
  const _StarterTile({required this.template, required this.title, required this.subtitle, required this.site});

  @override
  Widget build(BuildContext context) {
    const w = 160.0;
    final h = w * template.size.height / template.size.width;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.pop(context, template),
      child: SizedBox(
        width: w,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: w,
              height: h.clamp(60.0, 240.0),
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: w,
                  height: h,
                  child: CustomPaint(painter: MarketingPreviewPainter(template: template, values: MkPlaceholders.valuesFor(template, siteBase: site), images: const {})),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(title, style: AppText.label, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(subtitle, style: AppText.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }
}
