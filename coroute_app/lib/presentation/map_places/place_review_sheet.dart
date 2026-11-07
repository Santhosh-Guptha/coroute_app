import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/place_review_service.dart';
import '../../domain/places/place_poi.dart';
import '../../domain/places/poi_category.dart';
import 'place_style.dart';

/// 3.55: rate a place for the CoRoute riders coming after (stars, a few words, one photo).
/// True when a review was sent.
Future<bool?> showPlaceReviewSheet(
  BuildContext context, {
  required PlacePoi place,
  required PlaceReviewService service,
  int dwellMin = 0,
  PlaceReviewItem? mine,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: AppTheme.card,
    constraints: const BoxConstraints(maxWidth: 600),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => PlaceReviewSheet(place: place, service: service, dwellMin: dwellMin, mine: mine),
  );
}

/// 1–5 large, glove-friendly stars, an optional line of text (300 characters), an optional photo
/// (shown after a quick check), and the privacy line. Server refusals (links, phone numbers...)
/// are shown as the gateway words them.
class PlaceReviewSheet extends StatefulWidget {
  const PlaceReviewSheet({super.key, required this.place, required this.service, this.dwellMin = 0, this.mine});

  final PlacePoi place;
  final PlaceReviewService service;
  final int dwellMin;

  /// My earlier review of this place (a new one replaces it).
  final PlaceReviewItem? mine;

  /// Photos are downscaled on the phone; the gateway takes up to 2 MB.
  static const int maxPhotoBytes = 2 * 1024 * 1024;

  /// 'image/jpeg' | 'image/png' | 'image/webp' from the first bytes, or null (HEIC, GIF...). Same
  /// rule as the trip review sheet and the gateway's magic-byte check.
  static String? photoMimeOf(Uint8List b) {
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
    if (b.length >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return 'image/png';
    if (b.length >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return 'image/webp';
    }
    return null;
  }

  @override
  State<PlaceReviewSheet> createState() => _PlaceReviewSheetState();
}

class _PlaceReviewSheetState extends State<PlaceReviewSheet> {
  late int _rating = widget.mine?.rating ?? 0;
  late final TextEditingController _text = TextEditingController(text: widget.mine?.text ?? '');
  Uint8List? _photo;
  String? _photoMime;
  bool _sending = false;
  bool _picking = false;
  String? _error;
  String? _photoNote;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pick(ImageSource source) async {
    if (_picking || _sending) return;
    setState(() {
      _picking = true;
      _photoNote = null;
    });
    String? problem;
    Uint8List? bytes;
    String? mime;
    try {
      // Downscaled and without location metadata (the gateway strips the rest too).
      final f = await ImagePicker().pickImage(source: source, maxWidth: 1280, maxHeight: 1280, imageQuality: 75, requestFullMetadata: false);
      if (f != null) {
        bytes = await f.readAsBytes();
        mime = PlaceReviewSheet.photoMimeOf(bytes);
        if (mime == null) {
          problem = 'Use a JPEG, PNG or WebP photo.';
          bytes = null;
        } else if (bytes.length > PlaceReviewSheet.maxPhotoBytes) {
          problem = 'This photo is too large. Pick a smaller one.';
          bytes = null;
        }
      }
    } catch (_) {
      problem = source == ImageSource.camera ? 'Could not open the camera.' : 'Could not open your photos.';
    }
    if (!mounted) return;
    setState(() {
      _picking = false;
      if (bytes != null) {
        _photo = bytes;
        _photoMime = mime;
      }
      _photoNote = problem;
    });
  }

  Future<void> _send() async {
    if (_rating < 1 || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    String? error;
    var photoFailed = false;
    try {
      final review = await widget.service.submit(place: widget.place, rating: _rating, text: _text.text, dwellMin: widget.dwellMin);
      final photo = _photo, mime = _photoMime;
      if (photo != null && mime != null && review != null) {
        try {
          await widget.service.uploadPhoto(review.reviewId, photo, mime);
        } catch (_) {
          photoFailed = true;
        }
      }
    } on ApiException catch (e) {
      error = e.statusCode == 0 ? 'No connection. Try again when you have signal.' : e.message;
    } catch (_) {
      error = 'Could not send your rating. Please try again.';
    }
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _sending = false;
        _error = error;
      });
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop(true);
    messenger?.showSnackBar(SnackBar(
      content: Text(photoFailed
          ? 'Thanks! Your rating is in, but the photo did not upload.'
          : (_photo != null ? 'Thanks! Your photo appears after a quick check.' : 'Thanks! Your rating helps the riders coming after you.')),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.place;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Space.s24, Space.s16, Space.s24, Space.s24 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              CircleAvatar(radius: 22, backgroundColor: p.category.color, child: Icon(p.category.icon, color: Colors.white)),
              const SizedBox(width: Space.s12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Rate ${p.displayName}', style: AppText.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  Text(
                    widget.dwellMin > 0 ? 'You spent ${widget.dwellMin} min here' : p.category.singular,
                    style: AppText.caption.copyWith(color: AppTheme.muted),
                  ),
                ]),
              ),
            ]),
            const SizedBox(height: Space.s16),
            Semantics(
              label: _rating == 0 ? 'Rating: not chosen' : 'Rating: $_rating of 5 stars',
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 1; i <= 5; i++)
                    IconButton(
                      key: ValueKey('placeStar$i'),
                      iconSize: 44,
                      constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
                      tooltip: '$i star${i == 1 ? '' : 's'}',
                      onPressed: _sending ? null : () => setState(() => _rating = i),
                      icon: Icon(i <= _rating ? Icons.star_rounded : Icons.star_outline_rounded, color: i <= _rating ? AppTheme.hyperAmber : AppTheme.muted),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Space.s12),
            TextField(
              key: const ValueKey('placeReviewText'),
              controller: _text,
              enabled: !_sending,
              maxLength: PlaceReviewService.maxTextChars,
              maxLines: 3,
              minLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Food, parking for bikes, clean toilets... (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Space.s8),
            if (_photo != null)
              Row(children: [
                ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(_photo!, width: 64, height: 64, fit: BoxFit.cover)),
                const SizedBox(width: Space.s12),
                Expanded(child: Text('Photos appear after a quick check.', style: AppText.caption.copyWith(color: AppTheme.text2))),
                IconButton(tooltip: 'Remove photo', onPressed: _sending ? null : () => setState(() => _photo = null), icon: const Icon(Icons.close_rounded)),
              ])
            else
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('placeReviewCamera'),
                    onPressed: _sending || _picking ? null : () => _pick(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('Camera'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                  ),
                ),
                const SizedBox(width: Space.s12),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('placeReviewGallery'),
                    onPressed: _sending || _picking ? null : () => _pick(ImageSource.gallery),
                    icon: const Icon(Icons.photo_outlined),
                    label: const Text('Photo'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                  ),
                ),
              ]),
            if (_photo == null)
              Padding(
                padding: const EdgeInsets.only(top: Space.s4),
                child: Text('Optional. Photos appear after a quick check.', style: AppText.caption.copyWith(color: AppTheme.muted)),
              ),
            if (_photoNote != null)
              Padding(
                padding: const EdgeInsets.only(top: Space.s4),
                child: Text(_photoNote!, style: AppText.caption.copyWith(color: AppTheme.warnText)),
              ),
            const SizedBox(height: Space.s12),
            Row(children: [
              Icon(Icons.lock_outline_rounded, size: 16, color: AppTheme.muted),
              const SizedBox(width: Space.s8),
              Expanded(child: Text('Shown with your first name only.', style: AppText.caption.copyWith(color: AppTheme.muted))),
            ]),
            if (_error != null) ...[
              const SizedBox(height: Space.s12),
              Container(
                key: const ValueKey('placeReviewError'),
                padding: const EdgeInsets.all(Space.s12),
                decoration: BoxDecoration(color: AppTheme.warnTint, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.warnBorder)),
                child: Text(_error!, style: AppText.body.copyWith(color: AppTheme.warnText)),
              ),
            ],
            const SizedBox(height: Space.s16),
            FilledButton(
              key: const ValueKey('placeReviewSend'),
              onPressed: _rating < 1 || _sending ? null : _send,
              style: FilledButton.styleFrom(minimumSize: const Size(0, 52), backgroundColor: AppTheme.brand),
              child: _sending
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                  : Text(_rating < 1 ? 'Tap the stars to rate' : (widget.mine != null ? 'Update rating' : 'Send rating')),
            ),
          ],
        ),
      ),
    );
  }
}
