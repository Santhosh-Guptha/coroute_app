import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/trip_storage_service.dart';

/// Moderation state of a rider's post-trip review (gateway codes in brackets).
enum TripReviewStatus {
  /// PENDING_REVIEW: waiting for an admin.
  pending,

  /// APPROVED: may be shown on the CoRoute website.
  approved,

  /// CHANGES_REQUESTED: the admin asked the rider to edit it.
  changesRequested,

  /// REJECTED: will not be published.
  rejected,

  /// WITHDRAWN: taken down by the rider or by CoRoute.
  withdrawn,
}

/// A photo the rider uploaded with a review. [url] is a gateway path (see [ApiClient.apiUrlOf])
/// that only the rider can open, with [ApiClient.authHeaders].
class TripReviewPhoto {
  final String id;
  final String url;
  const TripReviewPhoto({required this.id, required this.url});

  static TripReviewPhoto? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = json['id']?.toString() ?? '';
    final url = json['url']?.toString() ?? '';
    if (id.isEmpty || url.isEmpty) return null;
    return TripReviewPhoto(id: id, url: url);
  }
}

/// The signed-in rider's review of one trip, as the gateway returns it.
class TripReview {
  final String feedbackId;
  final String tripId;
  final int rating;
  final String writtenFeedback;
  final String safetyExperience;
  final String suggestions;
  final bool consentPublish;
  final bool consentTripDetails;
  final bool consentPhoto;
  final List<String> photos;

  /// Photos the rider uploaded (also listed by id in [photos]).
  final List<TripReviewPhoto> uploadedPhotos;
  final TripReviewStatus status;

  /// The admin's reason (changes requested, rejected, withdrawn); empty otherwise.
  final String statusReason;
  final int submittedAt;
  final int updatedAt;

  const TripReview({
    required this.feedbackId,
    required this.tripId,
    required this.rating,
    this.writtenFeedback = '',
    this.safetyExperience = '',
    this.suggestions = '',
    this.consentPublish = false,
    this.consentTripDetails = false,
    this.consentPhoto = false,
    this.photos = const <String>[],
    this.uploadedPhotos = const <TripReviewPhoto>[],
    this.status = TripReviewStatus.pending,
    this.statusReason = '',
    this.submittedAt = 0,
    this.updatedAt = 0,
  });

  static TripReviewStatus statusOf(Object? code) {
    switch ((code?.toString() ?? '').toUpperCase()) {
      case 'APPROVED':
        return TripReviewStatus.approved;
      case 'CHANGES_REQUESTED':
      case 'NEEDS_CLARIFICATION':
        return TripReviewStatus.changesRequested;
      case 'REJECTED':
        return TripReviewStatus.rejected;
      case 'WITHDRAWN':
        return TripReviewStatus.withdrawn;
      default:
        return TripReviewStatus.pending;
    }
  }

  static int _int(Object? v) => v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
  static String _str(Object? v) => v?.toString() ?? '';

  /// Null when [json] is not a review (no feedbackId).
  static TripReview? tryParse(Object? json) {
    if (json is! Map) return null;
    final j = Map<String, dynamic>.from(json);
    final id = _str(j['feedbackId']);
    if (id.isEmpty) return null;
    final photos = j['photos'] is List ? (j['photos'] as List).map((e) => e.toString()).toList() : <String>[];
    final uploaded = j['uploadedPhotos'] is List
        ? (j['uploadedPhotos'] as List).map(TripReviewPhoto.tryParse).whereType<TripReviewPhoto>().toList()
        : <TripReviewPhoto>[];
    return TripReview(
      feedbackId: id,
      tripId: _str(j['tripId']),
      rating: _int(j['rating']).clamp(0, 5).toInt(),
      writtenFeedback: _str(j['writtenFeedback']),
      safetyExperience: _str(j['safetyExperience']),
      suggestions: _str(j['suggestions']),
      consentPublish: j['consentPublish'] == true,
      consentTripDetails: j['consentTripDetails'] == true,
      consentPhoto: j['consentPhoto'] == true,
      photos: photos,
      uploadedPhotos: uploaded,
      status: statusOf(j['status']),
      statusReason: _str(j['statusReason']),
      submittedAt: _int(j['submittedAt']),
      updatedAt: _int(j['updatedAt']),
    );
  }

  static String labelOf(TripReviewStatus s) {
    switch (s) {
      case TripReviewStatus.pending:
        return 'Pending approval';
      case TripReviewStatus.approved:
        return 'Approved';
      case TripReviewStatus.changesRequested:
        return 'Changes requested';
      case TripReviewStatus.rejected:
        return 'Not published';
      case TripReviewStatus.withdrawn:
        return 'Withdrawn';
    }
  }

  static IconData iconOf(TripReviewStatus s) {
    switch (s) {
      case TripReviewStatus.pending:
        return Icons.hourglass_top_rounded;
      case TripReviewStatus.approved:
        return Icons.verified_rounded;
      case TripReviewStatus.changesRequested:
        return Icons.edit_note_rounded;
      case TripReviewStatus.rejected:
        return Icons.block_rounded;
      case TripReviewStatus.withdrawn:
        return Icons.visibility_off_rounded;
    }
  }

  static Color colorOf(TripReviewStatus s) {
    switch (s) {
      case TripReviewStatus.pending:
      case TripReviewStatus.changesRequested:
        return AppTheme.warnText;
      case TripReviewStatus.approved:
        return AppTheme.accentText;
      case TripReviewStatus.rejected:
        return AppTheme.sos;
      case TripReviewStatus.withdrawn:
        return AppTheme.muted;
    }
  }

  /// One plain sentence for the rider about where the review stands.
  String get statusMessage {
    switch (status) {
      case TripReviewStatus.pending:
        return consentPublish
            ? 'Thanks! An admin will check your review before it appears on the CoRoute website.'
            : 'Thanks! Your feedback is with the CoRoute team. It will not be published.';
      case TripReviewStatus.approved:
        return consentPublish ? 'Your review is approved and may be shown on the CoRoute website.' : 'Your feedback was read by the CoRoute team.';
      case TripReviewStatus.changesRequested:
        return statusReason.isEmpty ? 'An admin asked for a small change. Edit your review and send it again.' : 'An admin asked for a change: $statusReason';
      case TripReviewStatus.rejected:
        return statusReason.isEmpty ? 'This review will not be published.' : 'This review will not be published: $statusReason';
      case TripReviewStatus.withdrawn:
        return statusReason.isEmpty ? 'This review is no longer shown.' : statusReason;
    }
  }
}

/// Small status pill for a review: icon and text, never colour alone.
class TripReviewStatusChip extends StatelessWidget {
  final TripReviewStatus status;
  const TripReviewStatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final c = TripReview.colorOf(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(7)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(TripReview.iconOf(status), size: 14, color: c),
          const SizedBox(width: 5),
          Text(TripReview.labelOf(status), style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600, height: 1.2)),
        ],
      ),
    );
  }
}

/// Post-trip review: star rating, what made the ride memorable, how safe it
/// felt, private suggestions, publication consents and up to [maxPhotos]
/// photos of the group. Every review and photo is checked by an admin before
/// anything appears on the website. A second submission updates the same
/// review (one per rider per trip).
///
/// Photos are sent only with their own consent box ticked; they are picked
/// from the gallery or camera, made smaller on the phone (1600 px, quality
/// 80) and uploaded after the review text is saved.
class TripFeedbackSheet extends StatefulWidget {
  /// The rider's trip record id, or the convoy groupId (both are accepted by the gateway).
  final String tripId;
  final String tripName;

  /// The rider's existing review, if the caller already has it (prefills the form).
  final TripReview? existing;

  /// Called every time the review is saved, also when the rider then swipes the sheet away.
  final ValueChanged<TripReview>? onSaved;

  const TripFeedbackSheet({
    super.key,
    required this.tripId,
    required this.tripName,
    this.existing,
    this.onSaved,
  });

  /// The photo row and its consent box.
  static const bool photosEnabled = true;
  static const int maxPhotos = 3;

  /// The gateway's limit per photo; the picker's downscale keeps phone photos far below it.
  static const int maxPhotoBytes = 2 * 1024 * 1024;

  static const int maxMemorable = 1500;
  static const int maxSafety = 1000;
  static const int maxSuggestions = 1000;

  /// Opens the sheet. Resolves to the saved review, or null when nothing was saved. A review
  /// saved before the rider swiped the sheet closed is still returned.
  static Future<TripReview?> show(BuildContext context, {required String tripId, required String tripName, TripReview? existing}) async {
    TripReview? saved;
    final popped = await showAppSheet<TripReview>(
      context,
      isScrollControlled: true,
      builder: (_) => TripFeedbackSheet(tripId: tripId, tripName: tripName, existing: existing, onSaved: (r) => saved = r),
    );
    return popped ?? saved;
  }

  @override
  State<TripFeedbackSheet> createState() => _TripFeedbackSheetState();
}

class _TripFeedbackSheetState extends State<TripFeedbackSheet> {
  static const _ratingWords = ['', 'Poor', 'Fair', 'Good', 'Great', 'Excellent'];

  final TextEditingController _memorableCtrl = TextEditingController();
  final TextEditingController _safetyCtrl = TextEditingController();
  final TextEditingController _suggestionsCtrl = TextEditingController();

  int _rating = 0;
  bool _consentPublish = false;
  bool _consentTripDetails = false;
  bool _consentPhoto = false;

  /// Photos already on the server that the rider keeps.
  List<TripReviewPhoto> _keptPhotos = <TripReviewPhoto>[];

  /// Photos picked on this phone, sent after the review is saved.
  final List<_PickedPhoto> _newPhotos = <_PickedPhoto>[];
  bool _picking = false;
  String? _photoError;

  /// "Sending photo 1 of 2" while photos upload.
  String? _progress;

  /// After saving: photos that could not be sent, in plain words.
  String? _photoNote;
  bool _loading = true;
  bool _submitting = false;
  bool _done = false;
  String? _error;
  TripReview? _existing;
  TripReview? _saved;
  bool _canReview = true;
  String? _blockCode;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) _prefill(e);
    _load();
  }

  @override
  void dispose() {
    _memorableCtrl.dispose();
    _safetyCtrl.dispose();
    _suggestionsCtrl.dispose();
    super.dispose();
  }

  void _prefill(TripReview e) {
    _existing = e;
    _rating = e.rating;
    _memorableCtrl.text = e.writtenFeedback;
    _safetyCtrl.text = e.safetyExperience;
    _suggestionsCtrl.text = e.suggestions;
    _consentPublish = e.consentPublish;
    _consentTripDetails = e.consentTripDetails;
    _consentPhoto = e.consentPhoto && e.consentPublish;
    _keptPhotos = e.consentPhoto ? List<TripReviewPhoto>.of(e.uploadedPhotos) : <TripReviewPhoto>[];
  }

  int get _photoCount => _keptPhotos.length + _newPhotos.length;

  /// 'image/jpeg' | 'image/png' | 'image/webp' from the first bytes, or null (HEIC, GIF, anything else).
  static String? photoMimeOf(Uint8List b) {
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
    if (b.length >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return 'image/png';
    if (b.length >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return 'image/webp';
    }
    return null;
  }

  Future<void> _pickPhotos(ImageSource source) async {
    final room = TripFeedbackSheet.maxPhotos - _photoCount;
    if (room <= 0 || _picking || _submitting) return;
    setState(() {
      _picking = true;
      _photoError = null;
    });
    final picker = ImagePicker();
    List<XFile> files = const <XFile>[];
    String? problem;
    try {
      if (source == ImageSource.gallery && room > 1) {
        files = await picker.pickMultiImage(maxWidth: 1600, maxHeight: 1600, imageQuality: 80, requestFullMetadata: false);
      } else {
        final f = await picker.pickImage(source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 80, requestFullMetadata: false);
        if (f != null) files = <XFile>[f];
      }
    } catch (_) {
      problem = source == ImageSource.camera ? 'Could not open the camera.' : 'Could not open your photos.';
    }
    final picked = <_PickedPhoto>[];
    var skipped = 0;
    var tooBig = 0;
    for (final f in files.take(room)) {
      try {
        final bytes = await f.readAsBytes();
        final mime = photoMimeOf(bytes);
        if (mime == null) {
          skipped++;
        } else if (bytes.length > TripFeedbackSheet.maxPhotoBytes) {
          tooBig++;
        } else {
          picked.add(_PickedPhoto(bytes, mime));
        }
      } catch (_) {
        skipped++;
      }
    }
    if (files.length > room) problem = 'You can add up to ${TripFeedbackSheet.maxPhotos} photos.';
    if (tooBig > 0) problem = tooBig == 1 ? 'One photo is too large. Pick a smaller one.' : '$tooBig photos are too large. Pick smaller ones.';
    if (skipped > 0) problem = 'Use a JPEG, PNG or WebP photo.';
    if (!mounted) return;
    setState(() {
      _picking = false;
      _newPhotos.addAll(picked);
      _photoError = problem;
    });
  }

  Future<void> _load() async {
    if (widget.tripId.isEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _canReview = false;
          _blockCode = 'TRIP_NOT_FOUND';
        });
      }
      return;
    }
    try {
      final res = await context.read<ApiClient>().getTripReview(widget.tripId);
      if (!mounted) return;
      final mine = TripReview.tryParse(res['feedback']);
      setState(() {
        if (mine != null && widget.existing == null) _prefill(mine);
        if (mine != null) _existing = mine;
        _canReview = res['canReview'] != false;
        _blockCode = res['code']?.toString();
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 403) {
        setState(() {
          _canReview = false;
          _blockCode = e.code ?? 'NOT_PARTICIPANT';
        });
      }
      // Offline or a server hiccup: the form stays usable and the submit reports any problem.
    } catch (_) {
      // Same as above.
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (_rating < 1) {
      setState(() => _error = 'Tap a star to rate your ride.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
      _photoNote = null;
    });
    final api = context.read<ApiClient>();
    final consentPhoto = _consentPublish && _consentPhoto;
    // Older https links (from earlier builds) stay; uploaded photos are kept by id.
    final keptIds = _keptPhotos.map((p) => p.id).toSet();
    final uploadedIds = (_existing?.uploadedPhotos ?? const <TripReviewPhoto>[]).map((p) => p.id).toSet();
    final links = (_existing?.photos ?? const <String>[]).where((p) => !uploadedIds.contains(p) && !p.startsWith('rp_')).toList();
    try {
      final res = await api.submitTripReview(widget.tripId, {
        'rating': _rating,
        'writtenFeedback': _memorableCtrl.text.trim(),
        'safetyExperience': _safetyCtrl.text.trim(),
        'suggestions': _suggestionsCtrl.text.trim(),
        'consentPublish': _consentPublish,
        'consentTripDetails': _consentPublish && _consentTripDetails,
        'consentPhoto': consentPhoto,
        'photos': consentPhoto ? <String>[...links, ...keptIds] : const <String>[],
      });
      var saved = TripReview.tryParse(res['feedback']);
      if (saved != null) widget.onSaved?.call(saved);
      // Photos go up one by one after the text is saved; a failed photo never loses the review.
      final toSend = consentPhoto ? List<_PickedPhoto>.of(_newPhotos) : const <_PickedPhoto>[];
      var sent = 0;
      String? failure;
      for (var i = 0; i < toSend.length; i++) {
        if (mounted) setState(() => _progress = 'Sending photo ${i + 1} of ${toSend.length}…');
        try {
          final up = await api.uploadTripReviewPhoto(widget.tripId, toSend[i].bytes, toSend[i].mime);
          saved = TripReview.tryParse(up['feedback']) ?? saved;
          sent++;
        } on ApiException catch (e) {
          failure = e.isOffline ? 'You are offline.' : e.message;
          break;
        } catch (_) {
          failure = 'The connection dropped.';
          break;
        }
      }
      final finalSaved = saved;
      if (finalSaved != null && sent > 0) widget.onSaved?.call(finalSaved);
      if (!mounted) return;
      final missed = toSend.length - sent;
      setState(() {
        _saved = finalSaved;
        if (finalSaved != null) _existing = finalSaved;
        _keptPhotos = finalSaved != null ? List<TripReviewPhoto>.of(finalSaved.uploadedPhotos) : _keptPhotos;
        if (sent > 0) _newPhotos.removeRange(0, sent);
        _photoNote = missed > 0
            ? '${missed == 1 ? 'One photo was' : '$missed photos were'} not sent. ${failure ?? ''} You can add ${missed == 1 ? 'it' : 'them'} again from this trip\'s report.'
            : null;
        _progress = null;
        _submitting = false;
        _done = true;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _progress = null;
        _error = e.isOffline ? 'You are offline. Your review was not sent; try again when you have signal.' : e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _progress = null;
        _error = 'Could not send your review. Please try again.';
      });
    }
  }

  void _close() => Navigator.of(context).maybePop(_saved);

  static String _blockedMessage(String? code) {
    switch (code) {
      case 'TRIP_NOT_COMPLETED':
        return 'You can review this trip once it has ended.';
      case 'NOT_PARTICIPANT':
        return 'Only riders who took part in this trip can review it.';
      case 'TRIP_NOT_FOUND':
      case 'BAD_TRIP_ID':
        return 'This trip has not reached the CoRoute server yet. Try again when you are online.';
      default:
        return 'This trip cannot be reviewed right now.';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return _successView();
    final existing = _existing;
    final blocked = !_canReview && existing == null;
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSheetHeader(
            title: existing == null ? 'How was your ride?' : 'Your review',
            subtitle: widget.tripName,
            showClose: true,
          ),
          if (_loading)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s12),
              child: LinearProgressIndicator(minHeight: 2, color: AppTheme.brand, backgroundColor: Colors.transparent),
            ),
          if (existing != null) ...[
            _statusBanner(existing),
            const SizedBox(height: Space.s16),
          ],
          if (blocked && !_loading)
            _blockedView()
          else ...[
            _stars(),
            const SizedBox(height: Space.s16),
            _field(
              controller: _memorableCtrl,
              label: 'What made this ride memorable?',
              hint: 'Roads, views, the group, a moment you will remember…',
              maxLength: TripFeedbackSheet.maxMemorable,
              minLines: 3,
            ),
            const SizedBox(height: Space.s8),
            _field(
              controller: _safetyCtrl,
              label: 'How safe did the ride feel?',
              hint: 'Group spacing, alerts, anything that worried you…',
              maxLength: TripFeedbackSheet.maxSafety,
            ),
            const SizedBox(height: Space.s8),
            _field(
              controller: _suggestionsCtrl,
              label: 'Suggestions for the CoRoute team (optional)',
              hint: 'Only the CoRoute team sees this.',
              maxLength: TripFeedbackSheet.maxSuggestions,
            ),
            const SizedBox(height: Space.s8),
            _consents(),
            const SizedBox(height: Space.s12),
            _approvalNote(),
            if (_error != null) ...[
              const SizedBox(height: Space.s12),
              _errorLine(_error!),
            ],
            const SizedBox(height: Space.s16),
            DsButton(
              label: _submitting ? (_progress ?? 'Sending…') : (existing == null ? 'Send review' : 'Update review'),
              icon: Icons.send_rounded,
              fontSize: 15,
              onPressed: _submitting || _loading || _picking ? null : _submit,
            ),
            const SizedBox(height: Space.s4),
            Center(
              child: TextButton(
                onPressed: _submitting ? null : _close,
                child: Text('Maybe later', style: AppText.label),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stars() {
    return Column(
      children: [
        Semantics(
          label: _rating == 0 ? 'Rating, not set' : 'Rating, $_rating of 5 stars',
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 1; i <= 5; i++)
                IconButton(
                  tooltip: i == 1 ? '1 star' : '$i stars',
                  iconSize: 38,
                  onPressed: _submitting ? null : () => setState(() {
                        _rating = i;
                        if (_error != null && _error!.startsWith('Tap a star')) _error = null;
                      }),
                  icon: Icon(
                    i <= _rating ? Icons.star_rounded : Icons.star_outline_rounded,
                    color: i <= _rating ? AppTheme.warnText : AppTheme.muted,
                  ),
                ),
            ],
          ),
        ),
        Text(_rating == 0 ? 'Tap to rate' : _ratingWords[_rating], style: AppText.label),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    required int maxLength,
    int minLines = 2,
  }) {
    return TextField(
      controller: controller,
      enabled: !_submitting,
      maxLength: maxLength,
      minLines: minLines,
      maxLines: 6,
      keyboardType: TextInputType.multiline,
      textCapitalization: TextCapitalization.sentences,
      style: AppText.body.copyWith(fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        alignLabelWithHint: true,
        filled: true,
        fillColor: AppTheme.soft,
        border: const OutlineInputBorder(borderRadius: Radii.mdAll, borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.all(Space.s12),
      ),
    );
  }

  Widget _consents() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          value: _consentPublish,
          onChanged: _submitting
              ? null
              : (v) => setState(() {
                    _consentPublish = v ?? false;
                    // The photo box also allows publishing the story: it cannot stay ticked without this one.
                    if (!_consentPublish) _consentPhoto = false;
                  }),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          activeColor: AppTheme.brand,
          title: Text('Feature my review on the CoRoute website', style: AppText.body.copyWith(fontSize: 14, fontWeight: FontWeight.w700)),
          subtitle: Text('Shown with your rating and a "Rider #" label, never your name, phone or e-mail.', style: AppText.caption),
        ),
        CheckboxListTile(
          value: _consentPublish && _consentTripDetails,
          onChanged: _submitting || !_consentPublish ? null : (v) => setState(() => _consentTripDetails = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: const EdgeInsets.only(left: Space.s24),
          activeColor: AppTheme.brand,
          title: Text('Show my trip details', style: AppText.body.copyWith(fontSize: 14, fontWeight: FontWeight.w700)),
          subtitle: Text('Trip name, distance, days and the start and end place names. Never your GPS track.', style: AppText.caption),
        ),
        if (TripFeedbackSheet.photosEnabled) ...[
          const SizedBox(height: Space.s8),
          _photoSection(),
        ],
      ],
    );
  }

  Widget _photoSection() {
    final canAdd = _consentPhoto && !_submitting && !_picking && _photoCount < TripFeedbackSheet.maxPhotos;
    // Not context.read: this runs during build.
    final api = Provider.of<ApiClient>(context, listen: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Group photo (optional)', style: AppText.body.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text('Up to ${TripFeedbackSheet.maxPhotos} photos of your group\'s best moment. Location data is removed.', style: AppText.caption),
        CheckboxListTile(
          value: _consentPhoto,
          onChanged: _submitting
              ? null
              : (v) => setState(() {
                    _consentPhoto = v ?? false;
                    if (_consentPhoto) _consentPublish = true;
                  }),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          activeColor: AppTheme.brand,
          checkboxShape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(2))),
          title: Text('I agree CoRoute may publish this photo and story on its website after review',
              style: AppText.body.copyWith(fontSize: 14, fontWeight: FontWeight.w700)),
          subtitle: Text('Only photos an admin approves are shown. Without this box, no photo is sent.', style: AppText.caption),
        ),
        if (_photoCount > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s8),
            child: Wrap(
              spacing: Space.s8,
              runSpacing: Space.s8,
              children: [
                for (final p in _keptPhotos)
                  _thumb(
                    Image.network(
                      api.apiUrlOf(p.url),
                      headers: api.authHeaders,
                      width: 88,
                      height: 88,
                      fit: BoxFit.cover,
                      cacheWidth: 264,
                      errorBuilder: (ctx, err, st) => Container(width: 88, height: 88, color: AppTheme.soft, child: Icon(Icons.image_outlined, color: AppTheme.muted)),
                    ),
                    onRemove: () => setState(() => _keptPhotos = _keptPhotos.where((x) => x.id != p.id).toList()),
                  ),
                for (final p in _newPhotos)
                  _thumb(
                    Image.memory(p.bytes, width: 88, height: 88, fit: BoxFit.cover, cacheWidth: 264, gaplessPlayback: true),
                    onRemove: () => setState(() => _newPhotos.remove(p)),
                  ),
              ],
            ),
          ),
        if (!_consentPhoto && _photoCount > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s8),
            child: Text('Tick the box to send these photos.', style: AppText.caption.copyWith(color: AppTheme.warnText, fontWeight: FontWeight.w700)),
          ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: canAdd ? () => _pickPhotos(ImageSource.gallery) : null,
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                icon: const Icon(Icons.photo_library_outlined, size: 20),
                label: const Text('Gallery'),
              ),
            ),
            const SizedBox(width: Space.s8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: canAdd ? () => _pickPhotos(ImageSource.camera) : null,
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                icon: const Icon(Icons.photo_camera_outlined, size: 20),
                label: const Text('Camera'),
              ),
            ),
          ],
        ),
        if (!_consentPhoto)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Tick the box above to add photos.', style: AppText.caption),
          ),
        if (_photoError != null) ...[
          const SizedBox(height: Space.s8),
          _errorLine(_photoError!),
        ],
      ],
    );
  }

  Widget _thumb(Widget image, {required VoidCallback onRemove}) {
    return SizedBox(
      width: 88,
      height: 88,
      child: Stack(
        children: [
          ClipRRect(borderRadius: Radii.mdAll, child: image),
          Positioned(
            top: -4,
            right: -4,
            child: IconButton(
              tooltip: 'Remove photo',
              onPressed: _submitting ? null : onRemove,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              icon: Container(
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                child: const Icon(Icons.close_rounded, size: 16, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _approvalNote() {
    return Container(
      padding: const EdgeInsets.all(Space.s12),
      decoration: BoxDecoration(color: AppTheme.tint, borderRadius: Radii.mdAll),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.verified_user_outlined, size: 20, color: AppTheme.accentText),
          const SizedBox(width: Space.s8),
          Expanded(
            child: Text(
              'Your review will be published after admin approval. You can edit or withdraw it later from this trip.',
              style: AppText.caption.copyWith(color: AppTheme.text2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorLine(String message) {
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: AppTheme.sos),
          const SizedBox(width: Space.s8),
          Expanded(child: Text(message, style: AppText.caption.copyWith(color: AppTheme.sos, fontWeight: FontWeight.w700))),
        ],
      ),
    );
  }

  Widget _statusBanner(TripReview r) {
    final c = TripReview.colorOf(r.status);
    return Container(
      padding: const EdgeInsets.all(Space.s12),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: Radii.mdAll,
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TripReviewStatusChip(status: r.status),
          const SizedBox(height: Space.s8),
          Text(r.statusMessage, style: AppText.caption.copyWith(color: AppTheme.text2)),
          if (r.status != TripReviewStatus.withdrawn) ...[
            const SizedBox(height: Space.s4),
            Text('Sending changes puts the review back in the approval queue.', style: AppText.caption),
          ],
        ],
      ),
    );
  }

  Widget _blockedView() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.info_outline_rounded, size: 40, color: AppTheme.muted),
          const SizedBox(height: Space.s12),
          Text(_blockedMessage(_blockCode), textAlign: TextAlign.center, style: AppText.body),
          const SizedBox(height: Space.s16),
          DsButton(label: 'Close', tone: DsButtonTone.outline, fontSize: 15, onPressed: _close),
        ],
      ),
    );
  }

  Widget _successView() {
    final s = _saved;
    final published = s?.consentPublish ?? _consentPublish;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: Space.s16),
          Icon(Icons.check_circle_rounded, size: 56, color: AppTheme.accentText),
          const SizedBox(height: Space.s12),
          Semantics(
            liveRegion: true,
            header: true,
            child: Text('Thanks for your review!', textAlign: TextAlign.center, style: AppText.title.copyWith(fontSize: 18)),
          ),
          const SizedBox(height: Space.s8),
          Text(
            published
                ? 'An admin will check it. Once approved, it appears on the CoRoute website. You can see its status in this trip\'s report.'
                : 'Your feedback goes to the CoRoute team only. It will not be published.',
            textAlign: TextAlign.center,
            style: AppText.label,
          ),
          if ((s?.uploadedPhotos.length ?? 0) > 0) ...[
            const SizedBox(height: Space.s8),
            Text(
              s!.uploadedPhotos.length == 1 ? 'Your photo was sent.' : '${s.uploadedPhotos.length} photos were sent.',
              textAlign: TextAlign.center,
              style: AppText.caption,
            ),
          ],
          if (_photoNote != null) ...[
            const SizedBox(height: Space.s12),
            _errorLine(_photoNote!),
          ],
          if (s != null) ...[
            const SizedBox(height: Space.s12),
            Center(child: TripReviewStatusChip(status: s.status)),
          ],
          const SizedBox(height: Space.s24),
          DsButton(label: 'Done', fontSize: 15, onPressed: _close),
        ],
      ),
    );
  }
}

/// A photo picked on this phone, not uploaded yet.
class _PickedPhoto {
  final Uint8List bytes;
  final String mime;
  const _PickedPhoto(this.bytes, this.mime);
}

/// Asks for a post-trip review on the home screen when the cockpit did not get to: the lead
/// ended the ride, or the rider left from the notification while the ride screen was closed.
/// Looks at the newest saved trip that ended within [window]; shares the once-per-trip flag
/// (`review_prompted_<id>`) with the cockpit and the trip report, so a rider is asked once.
/// Renders nothing.
class PendingTripReviewCheck extends StatefulWidget {
  const PendingTripReviewCheck({super.key});

  static const Duration window = Duration(days: 3);

  /// Lets the cockpit's own prompt (1.5 s after the end) go first.
  static const Duration startDelay = Duration(seconds: 4);

  @override
  State<PendingTripReviewCheck> createState() => _PendingTripReviewCheckState();
}

class _PendingTripReviewCheckState extends State<PendingTripReviewCheck> {
  static bool _running = false;

  /// A real Timer (cancelled in dispose), so a screen test never leaves a pending delay behind.
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(PendingTripReviewCheck.startDelay, () => unawaited(_check()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static TripHistoryModel? _newestRecent(List<TripHistoryModel> trips) {
    final now = DateTime.now().millisecondsSinceEpoch;
    TripHistoryModel? best;
    for (final t in trips) {
      final end = t.endTimeEpochMs;
      if (end <= 0 || now - end > PendingTripReviewCheck.window.inMilliseconds) continue;
      if (t.tripId.isEmpty && t.groupId.isEmpty) continue;
      if (best == null || end > best.endTimeEpochMs) best = t;
    }
    return best;
  }

  Future<void> _check() async {
    if (_running || !mounted) return;
    _running = true;
    try {
      ApiClient? api;
      TripStorageService? storage;
      try {
        api = context.read<ApiClient>();
        storage = context.read<TripStorageService>();
      } catch (_) {
        api = null;
        storage = null;
      }
      if (api == null || storage == null || !api.hasToken) return;
      final trip = _newestRecent(storage.trips);
      if (trip == null) return;
      final keys = <String>{
        if (trip.tripId.isNotEmpty) 'review_prompted_${trip.tripId}',
        if (trip.groupId.isNotEmpty) 'review_prompted_${trip.groupId}',
      };
      final prefs = await SharedPreferences.getInstance();
      if (keys.any((k) => prefs.getBool(k) == true)) return;
      // The convoy id is known to the gateway at once; the rider's trip record may still be syncing.
      final reviewId = trip.groupId.isNotEmpty ? trip.groupId : trip.tripId;
      final res = await api.getTripReview(reviewId);
      if (res['canReview'] != true || TripReview.tryParse(res['feedback']) != null) return;
      await prefs.reload();
      if (keys.any((k) => prefs.getBool(k) == true)) return;
      if (!mounted) return;
      // Not over another screen or sheet (the cockpit's own prompt, a dialog, the trip report).
      if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
      for (final k in keys) {
        await prefs.setBool(k, true);
      }
      if (!mounted) return;
      await TripFeedbackSheet.show(context, tripId: reviewId, tripName: trip.tripName);
    } catch (_) {
      // Offline or no answer: the trip report asks later.
    } finally {
      _running = false;
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
