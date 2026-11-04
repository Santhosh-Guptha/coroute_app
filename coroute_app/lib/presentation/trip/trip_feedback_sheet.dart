import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/api_client.dart';

/// Bottom sheet dialog prompting rider for post-trip feedback, star rating,
/// suggestions, and two independent publication consents for the website.
class TripFeedbackSheet extends StatefulWidget {
  final String tripId;
  final String tripName;

  const TripFeedbackSheet({
    super.key,
    required this.tripId,
    required this.tripName,
  });

  static Future<void> show(BuildContext context, {required String tripId, required String tripName}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => TripFeedbackSheet(tripId: tripId, tripName: tripName),
    );
  }

  @override
  State<TripFeedbackSheet> createState() => _TripFeedbackSheetState();
}

class _TripFeedbackSheetState extends State<TripFeedbackSheet> {
  int _rating = 5;
  final TextEditingController _feedbackCtrl = TextEditingController();
  final TextEditingController _suggestionsCtrl = TextEditingController();
  final TextEditingController _photoUrlCtrl = TextEditingController();

  bool _consentTripDetails = true;
  bool _consentPhoto = false;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _feedbackCtrl.dispose();
    _suggestionsCtrl.dispose();
    _photoUrlCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitFeedback() async {
    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final client = context.read<ApiClient>();
      await client.post('/trips/${widget.tripId}/feedback', {
        'rating': _rating,
        'writtenFeedback': _feedbackCtrl.text.trim(),
        'suggestions': _suggestionsCtrl.text.trim(),
        'consentTripDetails': _consentTripDetails,
        'consentPhoto': _consentPhoto,
        'photoUrl': _consentPhoto && _photoUrlCtrl.text.trim().isNotEmpty ? _photoUrlCtrl.text.trim() : null,
      });

      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Thank you! Your feedback and story have been submitted.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Could not submit feedback: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        top: 20,
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.brand.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.rate_review_rounded, color: AppTheme.brand, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'How Was Your Ride?',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      Text(
                        widget.tripName,
                        style: const TextStyle(color: Colors.white60, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white60),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Rating Stars
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (int i = 1; i <= 5; i++)
                    GestureDetector(
                      onTap: () => setState(() => _rating = i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(
                          i <= _rating ? Icons.star_rounded : Icons.star_outline_rounded,
                          color: Colors.amber,
                          size: 36,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Feedback Textfield
            TextField(
              controller: _feedbackCtrl,
              maxLines: 3,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Share your riding experience, route highlights or road conditions...',
                hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                filled: true,
                fillColor: const Color(0xFF1F2937),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.all(12),
              ),
            ),
            const SizedBox(height: 12),

            // Suggestions Textfield
            TextField(
              controller: _suggestionsCtrl,
              maxLines: 2,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Suggestions for CoRoute team (optional)...',
                hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                filled: true,
                fillColor: const Color(0xFF1F2937),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.all(12),
              ),
            ),
            const SizedBox(height: 16),

            // Consent 1: Feedback & Trip Details
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              activeColor: AppTheme.brand,
              title: const Text('Publish Story on Website', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
              subtitle: const Text('Allow CoRoute to feature your review and distance on the community feed.', style: TextStyle(color: Colors.white60, fontSize: 11)),
              value: _consentTripDetails,
              onChanged: (val) => setState(() => _consentTripDetails = val),
            ),

            // Consent 2: Group Photo
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              activeColor: AppTheme.brand,
              title: const Text('Include Convoy / Group Photo', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
              subtitle: const Text('Allow publishing group photo alongside your story.', style: TextStyle(color: Colors.white60, fontSize: 11)),
              value: _consentPhoto,
              onChanged: (val) => setState(() => _consentPhoto = val),
            ),

            if (_consentPhoto) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _photoUrlCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                decoration: InputDecoration(
                  hintText: 'Photo URL or uploaded image link...',
                  hintStyle: const TextStyle(color: Colors.white38, fontSize: 11),
                  filled: true,
                  fillColor: const Color(0xFF1F2937),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],

            const SizedBox(height: 20),

            // Submit Button
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _submitting ? null : _submitFeedback,
                child: _submitting
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                    : const Text('Submit Feedback & Story', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 14)),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Maybe Later', style: TextStyle(color: Colors.white60, fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

