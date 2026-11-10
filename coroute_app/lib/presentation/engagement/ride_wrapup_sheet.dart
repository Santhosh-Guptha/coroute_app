import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/engagement_service.dart';
import '../../data/services/place_review_service.dart';
import '../../domain/engagement/engagement_config.dart';
import '../../domain/engagement/ride_wrapup_flow.dart';
import '../../domain/places/place_dwell.dart';
import '../map_places/place_review_sheet.dart';
import '../map_places/place_style.dart';
import '../trip/trip_feedback_sheet.dart';

/// What happened in one wrap-up.
class WrapUpResult {
  final bool tripReviewed;
  final int placesRated;

  /// The rider closed it or tapped "Skip all".
  final bool skipped;
  final TripReview? tripReview;
  const WrapUpResult({this.tripReviewed = false, this.placesRated = 0, this.skipped = false, this.tripReview});
}

/// 3.55 after-ride wrap-up (docs/features_355/ratings_reviews.md): one calm sheet with at most 3
/// cards, swiped through: "How was the ride?" (stars, quick chips, a short note), then the places
/// the rider stopped at long enough (stars, the chips of that category, an optional photo). Every
/// card has "Skip"; "Skip all" or closing the sheet ends it. Texts and chips come from the admin's
/// engagement templates. No "Rate CoRoute" here: that is asked later, on its own rules.
class RideWrapUpSheet extends StatefulWidget {
  const RideWrapUpSheet({
    super.key,
    required this.items,
    required this.config,
    required this.api,
    this.places,
    this.prompts = const {},
  });

  final List<WrapUpItem> items;
  final EngagementConfig config;
  final ApiClient api;
  final PlaceReviewService? places;

  /// The place prompts by place id (the review sheet needs the [PlaceReviewPrompt.place]).
  final Map<String, PlaceReviewPrompt> prompts;

  /// Builds the cards for a ride and shows the sheet when there is at least one. [rideId] limits
  /// the place questions to that ride (null: any stored ones). Closing the sheet counts as "Skip
  /// all" for the places (the trip report offers the trip review again for a few days).
  static Future<WrapUpResult?> show(
    BuildContext context, {
    required ApiClient api,
    required String tripId,
    required String tripName,
    required bool canReviewTrip,
    required bool tripReviewed,
    PlaceReviewService? places,
    bool placesEnabled = true,
    String? rideId,
    EngagementConfig? config,
  }) async {
    final cfg = config ?? EngagementService.instance?.config ?? EngagementConfig.defaults;
    final prompts = <String, PlaceReviewPrompt>{};
    final wrapPlaces = <WrapUpPlace>[];
    if (places != null && placesEnabled) {
      for (final p in places.afterRidePrompts(enabled: true, rideId: rideId)) {
        prompts[p.placeId] = p;
        wrapPlaces.add(WrapUpPlace(placeId: p.placeId, name: p.place.displayName, category: p.place.category.name, dwellMin: p.dwellMin, atMs: p.atMs));
      }
    }
    final items = RideWrapUpFlow.build(
      rules: cfg.reviews,
      tripId: tripId,
      tripName: tripName,
      canReviewTrip: canReviewTrip,
      tripReviewed: tripReviewed,
      places: wrapPlaces,
    );
    if (items.isEmpty || !context.mounted) return null;
    WrapUpResult? out;
    final popped = await showAppSheet<WrapUpResult>(
      context,
      isScrollControlled: true,
      builder: (_) => RideWrapUpSheet(items: items, config: cfg, api: api, places: places, prompts: prompts),
    );
    out = popped ?? const WrapUpResult(skipped: true);
    if (out.skipped && places != null) places.skipAfterRide(rideId: rideId);
    return out;
  }

  static const String skipLabel = 'Skip';
  static const String skipAllLabel = 'Skip all';
  static const String saveLabel = 'Save';
  static const String storyLabel = 'Add photos or a story';
  static const String photoLabel = 'Add a photo';

  @override
  State<RideWrapUpSheet> createState() => _RideWrapUpSheetState();
}

class _CardState {
  int rating = 0;
  final Set<String> chips = {};
  final TextEditingController note = TextEditingController();
  bool showNote = false;
  bool saved = false;
  Uint8List? photo;
  String? photoMime;
}

class _RideWrapUpSheetState extends State<RideWrapUpSheet> {
  final PageController _pages = PageController();
  late final List<_CardState> _cards = [for (final _ in widget.items) _CardState()];
  int _index = 0;
  bool _sending = false;
  String? _error;
  bool _tripReviewed = false;
  TripReview? _tripReview;
  int _placesRated = 0;

  String get _lang => L10n.current;

  @override
  void dispose() {
    _pages.dispose();
    for (final c in _cards) {
      c.note.dispose();
    }
    super.dispose();
  }

  void _next() {
    if (!mounted) return;
    setState(() => _error = null);
    if (_index >= widget.items.length - 1) {
      Navigator.of(context).pop(WrapUpResult(tripReviewed: _tripReviewed, placesRated: _placesRated, tripReview: _tripReview));
      return;
    }
    _pages.nextPage(duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
  }

  Future<void> _save() async {
    final item = widget.items[_index];
    final c = _cards[_index];
    if (c.rating < 1 || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final offered = RideWrapUpFlow.chipsFor(item, widget.config);
      if (item.kind == WrapUpKind.trip) {
        final res = await widget.api.submitTripReview(item.id, RideWrapUpFlow.tripBody(rating: c.rating, chips: c.chips, note: c.note.text, offered: offered));
        _tripReview = TripReview.tryParse(res['feedback']);
        _tripReviewed = true;
      } else {
        final prompt = widget.prompts[item.id];
        final svc = widget.places;
        if (prompt != null && svc != null) {
          final review = await svc.submit(
            place: prompt.place,
            rating: c.rating,
            text: RideWrapUpFlow.cleanNote(c.note.text),
            dwellMin: prompt.dwellMin,
            chips: RideWrapUpFlow.cleanChips(c.chips, offered),
          );
          svc.answerAfterRide(item.id);
          final photo = c.photo, mime = c.photoMime;
          if (review != null && photo != null && mime != null) {
            // The rating is saved already; a photo that fails to upload never undoes it.
            unawaited(svc.uploadPhoto(review.reviewId, photo, mime).then((_) {}, onError: (_) {}));
          }
          _placesRated++;
        }
      }
      c.saved = true;
      if (!mounted) return;
      setState(() => _sending = false);
      _next();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = 'Could not save. Check your connection and try again.';
        });
      }
    }
  }

  Future<void> _openFullStory(WrapUpItem item) async {
    final saved = await TripFeedbackSheet.show(context, tripId: item.id, tripName: item.title);
    if (saved != null && mounted) {
      _tripReview = saved;
      _tripReviewed = true;
      _cards[_index].saved = true;
      _next();
    }
  }

  Future<void> _pickPhoto(_CardState c) async {
    try {
      final f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1280, maxHeight: 1280, imageQuality: 75, requestFullMetadata: false);
      if (f == null) return;
      final bytes = await f.readAsBytes();
      final mime = PlaceReviewSheet.photoMimeOf(bytes);
      if (!mounted) return;
      if (mime == null || bytes.length > PlaceReviewSheet.maxPhotoBytes) {
        setState(() => _error = 'Use a JPEG, PNG or WebP photo up to 2 MB.');
        return;
      }
      setState(() {
        c.photo = bytes;
        c.photoMime = mime;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not open the photo.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.items.length;
    final height = (MediaQuery.sizeOf(context).height * 0.62).clamp(380.0, 560.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          if (n > 1)
            Semantics(
              label: 'Card ${_index + 1} of $n',
              child: Row(children: [
                for (var i = 0; i < n; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.only(right: Space.s4),
                    width: i == _index ? 18 : 8,
                    height: 8,
                    decoration: BoxDecoration(color: i == _index ? AppTheme.primary : AppTheme.border, borderRadius: BorderRadius.circular(4)),
                  ),
              ]),
            ),
          const Spacer(),
          TextButton(
            key: const ValueKey('wrapup_skip_all'),
            onPressed: _sending ? null : () => Navigator.of(context).pop(WrapUpResult(tripReviewed: _tripReviewed, placesRated: _placesRated, skipped: true, tripReview: _tripReview)),
            style: TextButton.styleFrom(minimumSize: const Size(88, 48)),
            child: const Text(RideWrapUpSheet.skipAllLabel),
          ),
        ]),
        SizedBox(
          height: height,
          child: PageView.builder(
            controller: _pages,
            itemCount: n,
            onPageChanged: (i) => setState(() {
              _index = i;
              _error = null;
            }),
            itemBuilder: (context, i) => SingleChildScrollView(child: _card(widget.items[i], _cards[i])),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s8),
            child: Text(_error!, style: AppText.label.copyWith(color: AppTheme.danger)),
          ),
        Row(children: [
          Expanded(
            child: DsButton(
              key: const ValueKey('wrapup_skip'),
              label: RideWrapUpSheet.skipLabel,
              tone: DsButtonTone.outline,
              onPressed: _sending ? null : _next,
            ),
          ),
          const SizedBox(width: Space.s12),
          Expanded(
            child: DsButton(
              key: const ValueKey('wrapup_save'),
              label: _sending ? 'Saving…' : RideWrapUpSheet.saveLabel,
              icon: Icons.check_rounded,
              onPressed: _sending || _cards[_index].rating < 1 || _cards[_index].saved ? null : _save,
            ),
          ),
        ]),
      ],
    );
  }

  Widget _card(WrapUpItem item, _CardState c) {
    final cfg = widget.config;
    final isTrip = item.kind == WrapUpKind.trip;
    final chips = RideWrapUpFlow.chipsFor(item, cfg);
    final place = isTrip ? null : widget.prompts[item.id]?.place;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: Space.s8),
        if (isTrip) ...[
          Semantics(header: true, child: Text(cfg.text('tripTitle', _lang), style: AppText.headline)),
          if (item.title.isNotEmpty) Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
          const SizedBox(height: Space.s4),
          Text(cfg.text('tripSubtitle', _lang), style: AppText.caption),
        ] else ...[
          Text(cfg.text('placesTitle', _lang), style: AppText.overline),
          const SizedBox(height: Space.s8),
          Row(children: [
            if (place != null)
              CircleAvatar(radius: 18, backgroundColor: place.category.color, child: Icon(place.category.icon, size: 20, color: Colors.white)),
            const SizedBox(width: Space.s12),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(item.title.isEmpty ? 'Place' : item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
              ),
            ),
          ]),
          const SizedBox(height: Space.s4),
          Text(
            '${item.place != null ? 'You stayed ${item.place!.dwellMin} min. ' : ''}${cfg.text('placesSubtitle', _lang)}',
            style: AppText.caption,
          ),
        ],
        const SizedBox(height: Space.s16),
        _Stars(value: c.rating, enabled: !c.saved, onChanged: (v) => setState(() => c.rating = v)),
        if (chips.isNotEmpty) ...[
          const SizedBox(height: Space.s12),
          Wrap(
            spacing: Space.s8,
            runSpacing: Space.s8,
            children: [
              for (final chip in chips)
                FilterChip(
                  key: ValueKey('wrapup_chip:${chip.id}'),
                  label: Text(chip.label.pick(_lang)),
                  selected: c.chips.contains(chip.id),
                  onSelected: c.saved ? null : (on) => setState(() => on ? c.chips.add(chip.id) : c.chips.remove(chip.id)),
                  showCheckmark: true,
                  selectedColor: AppTheme.primarySoft,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                ),
            ],
          ),
        ],
        const SizedBox(height: Space.s12),
        if (isTrip || c.showNote)
          TextField(
            controller: c.note,
            enabled: !c.saved,
            maxLength: EngagementConfig.noteMax,
            minLines: 1,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(hintText: cfg.text('noteHint', _lang)),
          )
        else
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: c.saved ? null : () => setState(() => c.showNote = true),
              icon: const Icon(Icons.edit_note_rounded),
              label: Text(cfg.text('noteHint', _lang)),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            ),
          ),
        if (isTrip)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('wrapup_story'),
              onPressed: c.saved || _sending ? null : () => _openFullStory(item),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text(RideWrapUpSheet.storyLabel),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            ),
          )
        else
          Row(children: [
            TextButton.icon(
              key: const ValueKey('wrapup_photo'),
              onPressed: c.saved ? null : () => _pickPhoto(c),
              icon: Icon(c.photo == null ? Icons.add_a_photo_outlined : Icons.check_circle_rounded),
              label: Text(c.photo == null ? RideWrapUpSheet.photoLabel : 'Photo added'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            ),
            if (c.photo != null && !c.saved)
              IconButton(
                tooltip: 'Remove photo',
                onPressed: () => setState(() {
                  c.photo = null;
                  c.photoMime = null;
                }),
                icon: const Icon(Icons.close_rounded),
              ),
          ]),
        if (c.saved)
          Padding(
            padding: const EdgeInsets.only(top: Space.s8),
            child: Row(children: [
              Icon(Icons.check_circle_rounded, color: AppTheme.success, size: 20),
              const SizedBox(width: Space.s8),
              Expanded(child: Text(cfg.text('thanks', _lang), style: AppText.label)),
            ]),
          ),
      ],
    );
  }
}

/// Five large, glove-friendly stars (48 dp targets).
class _Stars extends StatelessWidget {
  const _Stars({required this.value, required this.onChanged, this.enabled = true});
  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;

  static const _words = ['', 'Poor', 'Fair', 'Good', 'Great', 'Excellent'];

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 1; i <= 5; i++)
            Semantics(
              button: true,
              selected: i <= value,
              label: '$i star${i == 1 ? '' : 's'}',
              child: IconButton(
                key: ValueKey('wrapup_star_$i'),
                iconSize: 40,
                constraints: const BoxConstraints(minWidth: 52, minHeight: 52),
                onPressed: enabled ? () => onChanged(i) : null,
                icon: Icon(i <= value ? Icons.star_rounded : Icons.star_outline_rounded, color: i <= value ? AppTheme.accent : AppTheme.textMuted),
              ),
            ),
        ],
      ),
      SizedBox(height: 20, child: Text(_words[value.clamp(0, 5)], style: AppText.label)),
    ]);
  }
}
