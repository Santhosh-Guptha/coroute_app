import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/place_review_service.dart';
import 'admin_ui.dart';
import 'master_admin_dashboard.dart';

/// 3.55 admin: CoRoute rider place reviews (restaurants, stays, fuel...). Stars and text are shown
/// to riders at once; photos only after they are approved here. A review can be hidden (and shown
/// again). Opened from the Reviews section ("Place reviews").
///
/// GET /api/admin/place-reviews (?pending=1: only those with a photo waiting),
/// PUT /api/admin/place-reviews/:id { action: hide | publish | approvePhoto | rejectPhoto, photoId }.
class AdminPlaceReviewsScreen extends StatefulWidget {
  const AdminPlaceReviewsScreen({super.key, this.pendingOnly = true});

  /// Start with the reviews that have a photo waiting.
  final bool pendingOnly;

  @override
  State<AdminPlaceReviewsScreen> createState() => _AdminPlaceReviewsScreenState();
}

class _AdminPlaceReviewsScreenState extends State<AdminPlaceReviewsScreen> {
  List<Map<String, dynamic>> _reviews = [];
  late bool _pendingOnly = widget.pendingOnly;
  bool _loading = true;
  bool _loaded = false;
  String? _error;
  final Set<String> _busy = {};

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
      final res = await context.read<ApiClient>().get('/admin/place-reviews${_pendingOnly ? '?pending=1' : ''}', timeout: const Duration(seconds: 15));
      _reviews = adminMapList(res is Map ? res['reviews'] : null);
      _loaded = true;
    } on ApiException catch (e) {
      error = e.message;
    } catch (_) {
      error = 'Could not load place reviews.';
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error;
    });
  }

  Future<void> _act(Map<String, dynamic> r, String action, {String? photoId}) async {
    final id = r['reviewId']?.toString() ?? '';
    if (id.isEmpty || _busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await context.read<ApiClient>().put('/admin/place-reviews/${Uri.encodeComponent(id)}', {'action': action, 'photoId': ?photoId});
      if (!mounted) return;
      adminSnack(context, switch (action) {
        'hide' => 'Review hidden from riders.',
        'publish' => 'Review shown to riders again.',
        'approvePhoto' => 'Photo approved.',
        _ => 'Photo removed.',
      });
      await _load();
    } on ApiException catch (e) {
      if (mounted) adminSnack(context, e.message, error: true);
    } catch (_) {
      if (mounted) adminSnack(context, 'Could not save. Try again.', error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiClient>();
    final Widget content;
    if (!_loaded && _error != null) {
      content = AdminScrollFill(child: AdminErrorState(message: _error!, onRetry: _load));
    } else if (_reviews.isEmpty) {
      content = AdminScrollFill(
        child: EmptyState(
          icon: Icons.place_outlined,
          title: _pendingOnly ? 'No photos waiting' : 'No place reviews yet',
          message: 'Riders rate the places they stopped at. Their photos wait here for a quick check.',
          primaryLabel: _pendingOnly ? 'Show all' : null,
          onPrimary: _pendingOnly
              ? () {
                  setState(() => _pendingOnly = false);
                  _load();
                }
              : null,
        ),
      );
    } else {
      content = ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        itemCount: _reviews.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (_, i) => _PlaceReviewCard(
          key: ValueKey(_reviews[i]['reviewId']),
          review: _reviews[i],
          api: api,
          busy: _busy.contains(_reviews[i]['reviewId']),
          onAction: (action, {photoId}) => _act(_reviews[i], action, photoId: photoId),
        ),
      );
    }
    return AdminShell(
      title: 'Place reviews',
      subtitle: _loaded ? '${_reviews.length} ${_pendingOnly ? 'with a photo waiting' : 'reviews'}' : 'CoRoute rider ratings of places',
      onBack: () => Navigator.maybePop(context),
      actions: [AdminIconAction(icon: Icons.refresh_rounded, label: 'Refresh', onTap: _load)],
      nav: adminNavItems(context, AdminPage.places),
      tabs: adminSectionTabs(context, AdminPage.places),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Wrap(spacing: 8, children: [
                ChoiceChip(
                  label: const Text('Photos waiting'),
                  selected: _pendingOnly,
                  onSelected: (_) {
                    setState(() => _pendingOnly = true);
                    _load();
                  },
                ),
                ChoiceChip(
                  label: const Text('All'),
                  selected: !_pendingOnly,
                  onSelected: (_) {
                    setState(() => _pendingOnly = false);
                    _load();
                  },
                ),
              ]),
            ),
            Expanded(
              child: LoadingState(
                loading: _loading,
                hasData: _loaded || _error != null,
                child: adminRefresh(onRefresh: _load, child: content),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

typedef _PlaceReviewAction = void Function(String action, {String? photoId});

class _PlaceReviewCard extends StatelessWidget {
  const _PlaceReviewCard({super.key, required this.review, required this.api, required this.busy, required this.onAction});

  final Map<String, dynamic> review;
  final ApiClient api;
  final bool busy;
  final _PlaceReviewAction onAction;

  @override
  Widget build(BuildContext context) {
    final r = review;
    final rating = (r['rating'] as num?)?.toInt() ?? 0;
    final hidden = r['status'] == 'HIDDEN';
    final uploads = adminMapList(r['uploads']);
    final text = r['text']?.toString() ?? '';
    return AdminCard(
      warning: hidden,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text(r['placeName']?.toString() ?? 'Place', style: AppText.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (hidden) StatusTextChip(icon: Icons.visibility_off_rounded, text: 'Hidden', color: AppTheme.warnText),
        ]),
        const SizedBox(height: 4),
        Text(
          '${'★' * rating.clamp(0, 5)}${'☆' * (5 - rating.clamp(0, 5))}  ·  ${r['firstName'] ?? 'Rider'}  ·  ${r['category'] ?? 'other'}',
          style: AppText.caption.copyWith(color: AppTheme.text2),
        ),
        if (text.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(text, style: AppText.body),
        ],
        if (uploads.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 12, children: [
            for (final u in uploads)
              SizedBox(
                width: 132,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.network(
                      api.apiUrlOf(PlaceReviewService.relativePath(u['url']?.toString() ?? '')),
                      headers: api.authHeaders,
                      width: 132,
                      height: 100,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(height: 100, color: AppTheme.soft, child: Icon(Icons.broken_image_outlined, color: AppTheme.muted)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (u['approved'] == true)
                    Text('Approved', textAlign: TextAlign.center, style: AppText.caption.copyWith(color: AppTheme.emeraldSafe, fontWeight: FontWeight.w600))
                  else
                    Row(children: [
                      Expanded(
                        child: IconButton(
                          tooltip: 'Approve photo',
                          onPressed: busy ? null : () => onAction('approvePhoto', photoId: u['id']?.toString()),
                          icon: Icon(Icons.check_circle_outline_rounded, color: AppTheme.emeraldSafe),
                        ),
                      ),
                      Expanded(
                        child: IconButton(
                          tooltip: 'Reject photo',
                          onPressed: busy ? null : () => onAction('rejectPhoto', photoId: u['id']?.toString()),
                          icon: Icon(Icons.cancel_outlined, color: AppTheme.sos),
                        ),
                      ),
                    ]),
                ]),
              ),
          ]),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: busy ? null : () => onAction(hidden ? 'publish' : 'hide'),
            icon: Icon(hidden ? Icons.visibility_rounded : Icons.visibility_off_rounded),
            label: Text(hidden ? 'Show to riders' : 'Hide review'),
          ),
        ),
      ]),
    );
  }
}
