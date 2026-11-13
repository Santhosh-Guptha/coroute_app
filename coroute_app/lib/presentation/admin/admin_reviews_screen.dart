import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../trip/trip_feedback_sheet.dart';
import 'admin_ui.dart';
import 'master_admin_dashboard.dart';

/// Which reviews the moderation list shows.
enum AdminReviewFilter { pending, changesRequested, approved, rejected, withdrawn, all }

/// How an approved story looks on the website. Same ids and photo counts as the gateway's
/// TEMPLATES (gateway/src/trip_reviews.js) and the website (public/assets/site.js).
class ReviewTemplate {
  final String id;
  final String label;
  final String hint;
  final int minPhotos;
  final int maxPhotos;
  const ReviewTemplate(this.id, this.label, this.hint, this.minPhotos, this.maxPhotos);

  static const List<ReviewTemplate> all = [
    ReviewTemplate('photo-left', 'Photo beside story', 'One photo next to the words (stacked on phones).', 1, 1),
    ReviewTemplate('photo-top', 'Photo above story', 'One wide photo, the words below.', 1, 1),
    ReviewTemplate('quote-card', 'Quote card', 'Words only, set large. No photo.', 0, 0),
    ReviewTemplate('gallery', 'Photo gallery', 'Two or three photos above the words.', 2, 3),
  ];

  static ReviewTemplate? byId(String? id) {
    for (final t in all) {
      if (t.id == id) return t;
    }
    return null;
  }
}

final RegExp _emailInText = RegExp(r'[A-Z0-9._%+-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)*\.[A-Z]{2,}', caseSensitive: false);
final RegExp _phoneRunInText = RegExp(r'\+?\d[\d\s().-]{7,}\d');

/// 'email' | 'phone' | null: contact details a public excerpt must not carry (same rule as the gateway:
/// a phone is a run of 10 or more digits, spaces, dots, dashes and brackets allowed between them).
String? reviewExcerptContact(String text) {
  if (_emailInText.hasMatch(text)) return 'email';
  for (final m in _phoneRunInText.allMatches(text)) {
    if (m.group(0)!.replaceAll(RegExp(r'\D'), '').length >= 10) return 'phone';
  }
  return null;
}

/// A photo the rider attached. [uploaded] photos are opened through the admin-only gateway route.
class _AdminPhoto {
  final String id;
  final String url;
  final bool uploaded;
  const _AdminPhoto(this.id, this.url, this.uploaded);
}

/// Admin: post-trip rider reviews waiting for moderation. Nothing a rider
/// writes reaches the website until it is approved here. Filter chips sit
/// above the list; tapping a review opens its detail with approve, request
/// changes, reject and withdraw, the public excerpt and the public photos.
class AdminReviewsScreen extends StatefulWidget {
  final AdminReviewFilter initialFilter;
  const AdminReviewsScreen({super.key, this.initialFilter = AdminReviewFilter.pending});

  @override
  State<AdminReviewsScreen> createState() => _AdminReviewsScreenState();
}

class _AdminReviewsScreenState extends State<AdminReviewsScreen> {
  List<Map<String, dynamic>> _reviews = [];
  bool _loaded = false;
  bool _loading = true;
  String? _error;
  late AdminReviewFilter _filter = widget.initialFilter;

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
    String? error;
    try {
      final res = await context.read<ApiClient>().adminListReviews();
      _reviews = adminMapList(res['reviews']);
      _loaded = true;
    } on ApiException catch (e) {
      error = e.message;
    } catch (_) {
      error = 'Could not load reviews.';
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error;
    });
    if (error != null && _loaded) adminSnack(context, error, error: true);
  }

  static bool _matches(Map<String, dynamic> r, AdminReviewFilter f) {
    final s = TripReview.statusOf(r['status']);
    switch (f) {
      case AdminReviewFilter.pending:
        return s == TripReviewStatus.pending;
      case AdminReviewFilter.changesRequested:
        return s == TripReviewStatus.changesRequested;
      case AdminReviewFilter.approved:
        return s == TripReviewStatus.approved;
      case AdminReviewFilter.rejected:
        return s == TripReviewStatus.rejected;
      case AdminReviewFilter.withdrawn:
        return s == TripReviewStatus.withdrawn;
      case AdminReviewFilter.all:
        return true;
    }
  }

  static String _filterLabel(AdminReviewFilter f) {
    switch (f) {
      case AdminReviewFilter.pending:
        return 'Pending';
      case AdminReviewFilter.changesRequested:
        return 'Changes requested';
      case AdminReviewFilter.approved:
        return 'Approved';
      case AdminReviewFilter.rejected:
        return 'Rejected';
      case AdminReviewFilter.withdrawn:
        return 'Withdrawn';
      case AdminReviewFilter.all:
        return 'All';
    }
  }

  Future<void> _open(Map<String, dynamic> r) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => AdminReviewDetailScreen(review: r)),
    );
    if (changed == true && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _reviews.where((r) => _matches(r, _filter)).toList();
    final pending = _reviews.where((r) => _matches(r, AdminReviewFilter.pending)).length;

    final Widget content;
    if (!_loaded && _error != null) {
      content = AdminScrollFill(child: AdminErrorState(message: _error!, onRetry: _load));
    } else if (visible.isEmpty) {
      content = AdminScrollFill(
        child: EmptyState(
          icon: Icons.rate_review_outlined,
          title: _filter == AdminReviewFilter.pending ? 'Nothing to moderate' : 'No ${_filterLabel(_filter).toLowerCase()} reviews',
          message: 'Riders can review a trip after it ends. New reviews wait here for approval.',
          primaryLabel: _filter != AdminReviewFilter.all ? 'Show all' : null,
          onPrimary: _filter != AdminReviewFilter.all ? () => setState(() => _filter = AdminReviewFilter.all) : null,
        ),
      );
    } else {
      content = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        children: [
          AdminTable(
            columns: const ['Review', 'Status'],
            rows: [
              for (var i = 0; i < visible.length; i++)
                _ReviewRow(
                  key: ValueKey(visible[i]['feedbackId']),
                  review: visible[i],
                  last: i == visible.length - 1,
                  onTap: () => _open(visible[i]),
                ),
            ],
          ),
        ],
      );
    }

    return AdminShell(
      title: 'Reviews',
      subtitle: _loaded ? '$pending waiting for approval' : 'Post-trip reviews',
      actions: [
        AdminIconAction(icon: Icons.refresh_rounded, label: 'Refresh', onTap: _load),
      ],
      nav: adminNavItems(context, AdminPage.reviews),
      tabs: adminSectionTabs(context, AdminPage.reviews),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 56,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  children: [
                    for (final f in AdminReviewFilter.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text('${_filterLabel(f)} (${_reviews.where((r) => _matches(r, f)).length})'),
                          selected: _filter == f,
                          onSelected: (_) => setState(() => _filter = f),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: LoadingState(
                  loading: _loading,
                  hasData: _loaded || _error != null,
                  child: adminRefresh(onRefresh: _load, child: content),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _stars(Object? rating) {
  final n = (rating is num ? rating.toInt() : 0).clamp(0, 5).toInt();
  return '${'★' * n}${'☆' * (5 - n)}';
}

class _ReviewRow extends StatelessWidget {
  final Map<String, dynamic> review;
  final bool last;
  final VoidCallback onTap;

  const _ReviewRow({super.key, required this.review, required this.onTap, this.last = false});

  @override
  Widget build(BuildContext context) {
    final r = review;
    final status = TripReview.statusOf(r['status']);
    final text = (r['writtenFeedback']?.toString() ?? '').trim();
    final who = (r['userName']?.toString() ?? '').trim();
    final consent = r['canPublish'] == true ? 'May be published' : 'Team only (no publish consent)';
    return AdminRow(
      leading: AdminRowIcon(Icons.rate_review_outlined, color: TripReview.colorOf(status)),
      title: (r['tripName']?.toString() ?? '').isEmpty ? 'Trip review' : r['tripName'].toString(),
      subtitle: '${_stars(r['rating'])}  ${who.isEmpty ? 'Rider' : who}',
      detail: text.isEmpty ? consent : '$text\n$consent',
      trailing: Padding(padding: const EdgeInsets.only(left: 8), child: TripReviewStatusChip(status: status)),
      divider: !last,
      onTap: onTap,
    );
  }
}

/// One review: what the rider wrote and agreed to, the public excerpt and
/// photo choice, the moderation actions and the audit history. Pops `true`
/// when something changed.
class AdminReviewDetailScreen extends StatefulWidget {
  final Map<String, dynamic> review;
  const AdminReviewDetailScreen({super.key, required this.review});

  @override
  State<AdminReviewDetailScreen> createState() => _AdminReviewDetailScreenState();
}

class _AdminReviewDetailScreenState extends State<AdminReviewDetailScreen> {
  late Map<String, dynamic> _r = Map<String, dynamic>.from(widget.review);
  late final TextEditingController _excerptCtrl = TextEditingController(
    text: (_r['formattedText']?.toString() ?? '').trim().isNotEmpty ? _r['formattedText'].toString() : (_r['writtenFeedback']?.toString() ?? ''),
  );
  late final Set<String> _selected = {
    ...((_r['selectedPhotos'] is List) ? (_r['selectedPhotos'] as List).map((e) => e.toString()) : const <String>[]),
  };
  late bool _showTripDetails = _r['showTripDetails'] != false;
  late String _template = _initialTemplate();
  bool _busy = false;
  bool _changed = false;

  String _initialTemplate() {
    for (final k in ['templateChosen', 'template']) {
      final v = _r[k]?.toString();
      if (ReviewTemplate.byId(v) != null) return v!;
    }
    return 'quote-card';
  }

  /// Every photo the rider attached (uploads first-class; older https links too).
  List<_AdminPhoto> get _photoItems {
    final items = _r['photoItems'];
    if (items is List) {
      return items.whereType<Map>().map((m) {
        final id = m['id']?.toString() ?? '';
        return _AdminPhoto(id, m['url']?.toString() ?? id, m['uploaded'] == true);
      }).where((p) => p.id.isNotEmpty).toList();
    }
    return _photos.map((p) => _AdminPhoto(p, p, false)).toList();
  }

  /// Selected photos, in the rider's order; none without photo consent.
  List<_AdminPhoto> get _chosenPhotos => _photoConsent ? _photoItems.where((p) => _selected.contains(p.id)).toList() : <_AdminPhoto>[];

  ReviewTemplate get _templateDef => ReviewTemplate.byId(_template) ?? ReviewTemplate.all[2];

  /// Why the story cannot go on the website as set up now, or null.
  String? get _publishProblem {
    final text = _excerptCtrl.text.trim();
    if (text.isEmpty) return 'Add a public excerpt first.';
    final contact = reviewExcerptContact(text);
    if (contact == 'email') return 'Remove the e-mail address from the excerpt.';
    if (contact == 'phone') return 'Remove the phone number from the excerpt.';
    final need = _templateDef.minPhotos;
    if (_chosenPhotos.length < need) {
      return '"${_templateDef.label}" needs ${need == 1 ? 'a selected photo' : '$need selected photos'}. Select ${need == 1 ? 'one' : 'more'} or pick another template.';
    }
    return null;
  }

  Widget _photoImage(_AdminPhoto p, {double? width, double? height}) {
    // Not context.read: this runs during build.
    final api = Provider.of<ApiClient>(context, listen: false);
    return Image.network(
      p.uploaded ? api.apiUrlOf(p.url) : _photoUrl(p.url),
      headers: p.uploaded ? api.authHeaders : null,
      width: width,
      height: height,
      fit: BoxFit.cover,
      cacheWidth: 800,
      errorBuilder: (ctx, err, st) => Container(
        width: width,
        height: height,
        color: AppTheme.soft,
        alignment: Alignment.center,
        child: Icon(Icons.broken_image_outlined, color: AppTheme.muted),
      ),
    );
  }

  static const int _maxExcerpt = 1000;

  @override
  void dispose() {
    _excerptCtrl.dispose();
    super.dispose();
  }

  String get _id => _r['feedbackId']?.toString() ?? '';
  TripReviewStatus get _status => TripReview.statusOf(_r['status']);
  bool get _canPublish => _r['canPublish'] == true;
  bool get _photoConsent => _r['consentPhoto'] == true;
  bool get _detailsConsent => _r['consentTripDetails'] == true;
  List<String> get _photos => _r['photos'] is List ? (_r['photos'] as List).map((e) => e.toString()).toList() : <String>[];

  static String _photoUrl(String p) {
    if (p.startsWith('http')) return p;
    final api = AppConfig.apiUrl;
    final origin = api.endsWith('/api') ? api.substring(0, api.length - 4) : api;
    return '$origin$p';
  }

  /// The dialog owns its text controller, so it is disposed only after the
  /// closing animation (disposing it when the pop future completes threw
  /// "TextEditingController was used after being disposed").
  Future<String?> _askReason(String title, String hint) {
    return showAppDialog<String>(
      context, // round 7: app motion (spring scale + fade, reduce-motion aware)
      builder: (ctx) => _ReasonDialog(title: title, hint: hint),
    );
  }

  Future<void> _act(String action) async {
    String? reason;
    if (action == 'REJECT') {
      reason = await _askReason('Reject review', 'Why it will not be published');
      if (reason == null) return;
    } else if (action == 'REQUEST_CHANGES') {
      reason = await _askReason('Request changes', 'What the rider should change');
      if (reason == null) return;
    } else if (action == 'WITHDRAW') {
      final ok = await confirmAction(context, title: 'Remove from the website?', message: 'The review stops showing on the website at once. You can approve it again later.', confirmLabel: 'Remove', destructive: true);
      if (!ok) return;
    }
    if (!mounted) return;
    final body = <String, dynamic>{'action': action};
    if (reason != null) body['reason'] = reason;
    if (action == 'APPROVE' || action == 'EDIT') {
      final problem = _publishProblem;
      if (problem != null) {
        adminSnack(context, problem, error: true);
        return;
      }
      body['formattedText'] = _excerptCtrl.text.trim();
      body['selectedPhotos'] = _chosenPhotos.map((p) => p.id).toList();
      body['template'] = _template;
      if (_detailsConsent) body['showTripDetails'] = _showTripDetails;
    }
    setState(() => _busy = true);
    try {
      final res = await context.read<ApiClient>().adminModerateReview(_id, body);
      if (!mounted) return;
      final fb = res['feedback'];
      setState(() {
        if (fb is Map) _r = Map<String, dynamic>.from(fb);
        _changed = true;
        _busy = false;
      });
      adminSnack(context, 'Review ${TripReview.labelOf(_status).toLowerCase()}.');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      adminSnack(context, e.message, error: true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      adminSnack(context, 'The action failed. Try again.', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    final status = _status;
    final fmt = DateFormat('d MMM yyyy, HH:mm');
    final submitted = (r['submittedAt'] as num?)?.toInt() ?? 0;
    final history = adminMapList(r['reviewHistory']).reversed.toList();
    final route = [r['routeFrom'], r['routeTo']].where((x) => x != null && x.toString().isNotEmpty).join(' to ');
    final facts = <String>[
      if ((r['distanceKm'] as num? ?? 0) > 0) '${(r['distanceKm'] as num).round()} km',
      if ((r['durationDays'] as num? ?? 0) > 0) '${(r['durationDays'] as num).toInt()} ${(r['durationDays'] as num).toInt() == 1 ? 'day' : 'days'}',
      if (route.isNotEmpty) route,
    ].join(' · ');

    Widget block(String label, Object? value) {
      final v = (value?.toString() ?? '').trim();
      if (v.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: Space.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AdminOverline(label),
            const SizedBox(height: 4),
            SelectableText(v, style: AppText.body.copyWith(fontSize: 14)),
          ],
        ),
      );
    }

    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: AdminShell(
        title: (r['tripName']?.toString() ?? '').isEmpty ? 'Review' : r['tripName'].toString(),
        subtitle: TripReview.labelOf(status),
        onBack: () => Navigator.of(context).pop(_changed),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              children: [
                AdminTitledCard(
                  title: 'What the rider wrote',
                  trailing: TripReviewStatusChip(status: status),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(_stars(r['rating']), style: TextStyle(color: AppTheme.warnText, fontSize: 20)),
                      const SizedBox(height: 4),
                      Text(
                        [r['userName'], r['userEmail']].where((x) => x != null && x.toString().isNotEmpty).join(', '),
                        style: AppText.caption,
                      ),
                      if (submitted > 0) Text('Sent ${fmt.format(DateTime.fromMillisecondsSinceEpoch(submitted))}', style: AppText.caption),
                      if (facts.isNotEmpty) Text(facts, style: AppText.caption),
                      block('What made the ride memorable', r['writtenFeedback']),
                      block('Safety experience', r['safetyExperience']),
                      block('Suggestions (private)', r['suggestions']),
                      if ((r['statusReason']?.toString() ?? '').isNotEmpty) block('Reason given to the rider', r['statusReason']),
                    ],
                  ),
                ),
                const SizedBox(height: Space.s16),
                AdminTitledCard(
                  title: 'Consent',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _consentLine(_canPublish, 'Review may be published on the website'),
                      const SizedBox(height: 6),
                      _consentLine(_detailsConsent, 'Trip details may be shown'),
                      const SizedBox(height: 6),
                      _consentLine(_photoConsent, 'Photos may be shown'),
                      if (!_canPublish) ...[
                        const SizedBox(height: Space.s8),
                        Text('Without the rider\'s consent this review stays with the team and cannot be approved for the website.', style: AppText.caption.copyWith(color: AppTheme.warnText)),
                      ],
                    ],
                  ),
                ),
                if (_canPublish) ...[
                  const SizedBox(height: Space.s16),
                  AdminTitledCard(
                    title: 'Public story',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _excerptCtrl,
                          enabled: !_busy,
                          maxLength: _maxExcerpt,
                          minLines: 3,
                          maxLines: 8,
                          textCapitalization: TextCapitalization.sentences,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText: 'Public excerpt',
                            helperText: 'Plain text. Remove names, plates, phone numbers and exact places.',
                            alignLabelWithHint: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                        if (reviewExcerptContact(_excerptCtrl.text) != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4, bottom: Space.s8),
                            child: StatusLine(
                              icon: Icons.warning_amber_rounded,
                              text: reviewExcerptContact(_excerptCtrl.text) == 'email'
                                  ? 'The excerpt has an e-mail address. Remove it before approving.'
                                  : 'The excerpt has a phone number. Remove it before approving.',
                              color: AppTheme.sos,
                            ),
                          ),
                        if (_detailsConsent)
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _showTripDetails,
                            onChanged: _busy ? null : (v) => setState(() => _showTripDetails = v),
                            title: Text('Show trip details', style: AppText.body.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
                            subtitle: Text('Trip name, distance, days and place names.', style: AppText.caption),
                          ),
                        if (_photoItems.isNotEmpty) ...[
                          const SizedBox(height: Space.s8),
                          AdminOverline(_photoConsent ? 'Photos to show (tap to select)' : 'Photos (no consent to show)'),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: Space.s8,
                            runSpacing: Space.s8,
                            children: [
                              for (final p in _photoItems) _photoChoice(p),
                            ],
                          ),
                          if (!_photoConsent)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text('The rider did not tick the photo box, so these photos can never be shown.', style: AppText.caption),
                            ),
                        ],
                        const SizedBox(height: Space.s16),
                        const AdminOverline('Website template'),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: Space.s8,
                          runSpacing: Space.s8,
                          children: [
                            for (final t in ReviewTemplate.all)
                              ChoiceChip(
                                label: Text(t.label),
                                selected: _template == t.id,
                                onSelected: _busy ? null : (_) => setState(() => _template = t.id),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(_templateDef.hint, style: AppText.caption),
                        const SizedBox(height: Space.s16),
                        const AdminOverline('Preview'),
                        const SizedBox(height: 6),
                        ReviewStoryPreview(
                          template: _template,
                          text: _excerptCtrl.text.trim(),
                          rating: (r['rating'] as num?)?.toInt() ?? 0,
                          title: _detailsConsent && _showTripDetails && (r['tripName']?.toString() ?? '').isNotEmpty ? r['tripName'].toString() : 'A CoRoute ride',
                          facts: _detailsConsent && _showTripDetails ? facts : '',
                          photos: [
                            for (final p in _chosenPhotos.take(_templateDef.maxPhotos)) _photoImage(p),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text('Close to how the card looks on the website. The rider shows as "Rider #" and a number, never by name.', style: AppText.caption),
                        if (_publishProblem != null) ...[
                          const SizedBox(height: Space.s8),
                          StatusLine(icon: Icons.info_outline_rounded, text: _publishProblem!, color: AppTheme.warnText),
                        ],
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: Space.s16),
                _actions(status),
                if (history.isNotEmpty) ...[
                  const SizedBox(height: Space.s16),
                  AdminTitledCard(
                    title: 'History',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final h in history)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              [
                                adminCapitalize((h['action']?.toString() ?? '').toLowerCase().replaceAll('_', ' ')),
                                h['by']?.toString() ?? '',
                                if ((h['at'] as num? ?? 0) > 0) fmt.format(DateTime.fromMillisecondsSinceEpoch((h['at'] as num).toInt())),
                                if ((h['reason']?.toString() ?? '').isNotEmpty) '"${h['reason']}"',
                              ].where((s) => s.isNotEmpty).join(' · '),
                              style: AppText.caption,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _photoChoice(_AdminPhoto p) {
    final on = _selected.contains(p.id);
    final enabled = !_busy && _photoConsent;
    return Semantics(
      button: true,
      selected: on,
      label: on ? 'Photo selected for the website' : 'Photo not selected',
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: enabled
            ? () => setState(() {
                  if (on) {
                    _selected.remove(p.id);
                  } else {
                    _selected.add(p.id);
                  }
                })
            : null,
        child: Container(
          width: 112,
          height: 112,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: on ? AppTheme.brand : AppTheme.border, width: on ? 3 : 1),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _photoImage(p, width: 112, height: 112),
                Positioned(
                  top: 6,
                  left: 6,
                  child: Icon(
                    on ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                    color: on ? AppTheme.brand : Colors.white,
                    shadows: const [Shadow(blurRadius: 4, color: Colors.black54)],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _consentLine(bool ok, String text) => StatusLine(
        icon: ok ? Icons.check_circle_rounded : Icons.cancel_outlined,
        text: ok ? text : 'No: ${text.toLowerCase()}',
        color: ok ? AppTheme.accentText : AppTheme.muted,
      );

  Widget _actions(TripReviewStatus status) {
    final buttons = <Widget>[
      if (status != TripReviewStatus.approved)
        DsButton(
          label: 'Approve for website',
          icon: Icons.check_rounded,
          fontSize: 15,
          height: 48,
          onPressed: _busy || !_canPublish || _publishProblem != null ? null : () => _act('APPROVE'),
        ),
      if (status == TripReviewStatus.approved)
        DsButton(
          label: 'Save public story',
          icon: Icons.save_outlined,
          fontSize: 15,
          height: 48,
          onPressed: _busy || _publishProblem != null ? null : () => _act('EDIT'),
        ),
      if (status == TripReviewStatus.pending || status == TripReviewStatus.approved)
        DsButton(
          label: 'Request changes',
          icon: Icons.edit_note_rounded,
          tone: DsButtonTone.outline,
          fontSize: 15,
          height: 48,
          onPressed: _busy ? null : () => _act('REQUEST_CHANGES'),
        ),
      if (status != TripReviewStatus.rejected)
        DsButton(
          label: 'Reject',
          icon: Icons.block_rounded,
          tone: DsButtonTone.outline,
          fontSize: 15,
          height: 48,
          onPressed: _busy ? null : () => _act('REJECT'),
        ),
      if (status == TripReviewStatus.approved)
        DsButton(
          label: 'Remove from website',
          icon: Icons.visibility_off_outlined,
          tone: DsButtonTone.sos,
          fontSize: 15,
          height: 48,
          onPressed: _busy ? null : () => _act('WITHDRAW'),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          if (i > 0) const SizedBox(height: Space.s8),
          buttons[i],
        ],
      ],
    );
  }
}

/// Asks the admin for the reason the rider will see; pops the trimmed text, or null on cancel.
class _ReasonDialog extends StatefulWidget {
  final String title;
  final String hint;
  const _ReasonDialog({required this.title, required this.hint});

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLength: 500,
        minLines: 2,
        maxLines: 5,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(hintText: widget.hint, helperText: 'The rider sees this.'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final v = _ctrl.text.trim();
            if (v.isNotEmpty) Navigator.pop(context, v);
          },
          child: const Text('Send'),
        ),
      ],
    );
  }
}

/// Approximates a story card on the CoRoute website for the chosen [template]: the admin sees
/// the layout, the selected photos and the excerpt before approving.
class ReviewStoryPreview extends StatelessWidget {
  final String template;
  final String text;
  final int rating;
  final String title;
  final String facts;
  final List<Widget> photos;

  const ReviewStoryPreview({
    super.key,
    required this.template,
    required this.text,
    required this.rating,
    required this.title,
    this.facts = '',
    this.photos = const <Widget>[],
  });

  Widget _body(bool quote) {
    final r = rating.clamp(0, 5).toInt();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 1; i <= 5; i++)
                Icon(i <= r ? Icons.star_rounded : Icons.star_outline_rounded, size: 18, color: i <= r ? AppTheme.warnText : AppTheme.muted),
            ],
          ),
          const SizedBox(height: 4),
          Text(title, style: AppText.title.copyWith(fontSize: 16)),
          if (facts.isNotEmpty) Text(facts, style: AppText.caption),
          const SizedBox(height: 8),
          if (quote) Text('\u201C', style: TextStyle(fontSize: 40, height: 0.8, color: AppTheme.brand, fontFamily: 'serif')),
          Container(
            padding: quote ? EdgeInsets.zero : const EdgeInsets.only(left: 10),
            decoration: quote ? null : BoxDecoration(border: Border(left: BorderSide(color: AppTheme.brand, width: 3))),
            child: Text(
              text.isEmpty ? 'The public excerpt shows here.' : text,
              maxLines: 7,
              overflow: TextOverflow.ellipsis,
              style: AppText.body.copyWith(fontSize: quote ? 16 : 14, color: text.isEmpty ? AppTheme.muted : AppTheme.text),
            ),
          ),
          const SizedBox(height: 10),
          Divider(height: 1, color: AppTheme.border),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Rider #1', style: AppText.caption.copyWith(fontWeight: FontWeight.w600, color: AppTheme.text)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: AppTheme.tint, borderRadius: BorderRadius.circular(99)),
                child: Text('Completed trip, approved', style: AppText.caption.copyWith(color: AppTheme.brand, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _photo(Widget w, double ratio) => AspectRatio(aspectRatio: ratio, child: SizedBox.expand(child: w));

  @override
  Widget build(BuildContext context) {
    final t = ReviewTemplate.byId(template) ?? ReviewTemplate.all[2];
    final shown = photos.take(t.maxPhotos).toList();
    // The website falls back the same way when a template has fewer photos than it needs.
    var id = t.id;
    if (shown.length < t.minPhotos) id = (id == 'gallery' && shown.isNotEmpty) ? 'photo-top' : 'quote-card';
    final quote = id == 'quote-card';
    Widget content;
    if (quote) {
      content = _body(true);
    } else if (id == 'gallery') {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (shown.length == 3) _photo(shown[0], 4 / 3),
          Row(
            children: [
              for (final w in (shown.length == 3 ? shown.sublist(1) : shown)) Expanded(child: Padding(padding: const EdgeInsets.all(1), child: _photo(w, 4 / 3))),
            ],
          ),
          _body(false),
        ],
      );
    } else if (id == 'photo-left') {
      content = LayoutBuilder(
        builder: (ctx, c) {
          if (c.maxWidth < 520) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [_photo(shown.first, 4 / 3), _body(false)]);
          }
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: c.maxWidth * 0.44, child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 240), child: shown.first)),
                Expanded(child: _body(false)),
              ],
            ),
          );
        },
      );
    } else {
      content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [_photo(shown.first, 16 / 10), _body(false)]);
    }
    return Semantics(
      label: 'Website preview, ${ReviewTemplate.byId(id)?.label ?? 'Quote card'}',
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: quote ? AppTheme.tint : AppTheme.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: quote ? Colors.transparent : AppTheme.border),
        ),
        child: content,
      ),
    );
  }
}
