import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/presentation/admin/admin_reviews_screen.dart';
import 'package:coroute_app/presentation/trip/trip_feedback_sheet.dart';

void main() {
  test('website templates match the gateway (ids and photo counts)', () {
    expect(ReviewTemplate.all.map((t) => t.id).toList(), ['photo-left', 'photo-top', 'quote-card', 'gallery']);
    expect(ReviewTemplate.byId('gallery')!.minPhotos, 2);
    expect(ReviewTemplate.byId('gallery')!.maxPhotos, 3);
    expect(ReviewTemplate.byId('quote-card')!.maxPhotos, 0);
    expect(ReviewTemplate.byId('text-left-pic-right'), isNull);
  });

  test('public excerpt: e-mail addresses and phone numbers are caught, distances and dates are not', () {
    expect(reviewExcerptContact('Write to rider.one@example.com'), 'email');
    expect(reviewExcerptContact('Call +91 98765 43210'), 'phone');
    expect(reviewExcerptContact('Call 98765-43210'), 'phone');
    expect(reviewExcerptContact('We rode 1,250 km over 3 days in 2024.'), isNull);
    expect(reviewExcerptContact('Back on 12.10.2024 at 05:30.'), isNull);
  });

  test('a review carries its uploaded photos', () {
    final r = TripReview.tryParse({
      'feedbackId': 'FB-1',
      'tripId': 'GRP-1',
      'rating': 5,
      'photos': ['rp_0123456789abcdef01234567'],
      'uploadedPhotos': [
        {'id': 'rp_0123456789abcdef01234567', 'url': '/trips/GRP-1/feedback/photos/rp_0123456789abcdef01234567'},
        {'id': '', 'url': '/x'},
      ],
      'consentPhoto': true,
      'consentPublish': true,
      'status': 'PENDING_REVIEW',
    })!;
    expect(r.uploadedPhotos.length, 1);
    expect(r.uploadedPhotos.first.url, startsWith('/trips/GRP-1/feedback/photos/'));
    expect(r.consentPhoto, isTrue);
    expect(TripFeedbackSheet.maxPhotos, 3);
    expect(TripFeedbackSheet.photosEnabled, isTrue);
  });
}
