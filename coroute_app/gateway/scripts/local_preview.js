'use strict';
process.env.NODE_ENV = 'test';
process.env.PORT = '3000';
process.env.HOST = '127.0.0.1';
process.env.JWT_SECRET = 'local_preview_secret_12345678901234567890';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');

async function run() {
  const soda = new MemorySoda();
  const logger = {
    info: (...a) => console.log('[LocalPreview]', ...a),
    warn: (...a) => console.warn('[LocalPreview]', ...a),
    error: (...a) => console.error('[LocalPreview]', ...a),
  };

  const gw = await createApp({ soda, logger });
  const repo = gw.repo;

  // 1. Configure community stats
  await repo.setCommunityStatsConfig({
    enabled: true,
    showLeaderboard: true,
    anonymizeRiders: true,
    prefix: 'Rider',
  });

  // 2. Add realistic seed feedback stories with photos and layout templates
  const f1 = await repo.addTripFeedback({
    tripId: 'trip_wghats_01',
    riderId: 'rider_arun',
    riderCallsign: 'FalconEye',
    rating: 5,
    feedback: 'Western Ghats Monsoon Expedition - Tested CoRoute\'s new crash detection along misty hairpin turns. The discrete jerk filtering and lean-angle detection kept our group completely false-alarm free over broken mountain asphalt.',
    suggestions: 'Keep adding offline terrain maps!',
    photos: [
      'https://images.unsplash.com/photo-1558981403-c5f9899a28bc?auto=format&fit=crop&w=600&q=80'
    ],
    publishConsent: true,
    photoConsent: true,
  });
  await repo.updateTripFeedbackReview(f1.id, {
    action: 'APPROVE',
    adminNotes: 'Excellent monsoon testing story',
    templateLayout: 'text-left-pic-right',
    formattedText: 'Western Ghats Monsoon Expedition — Tested CoRoute\'s enhanced Phase 2 crash detection along misty hairpin turns. The discrete jerk filtering and dynamic lean-angle detection kept our convoy completely false-alarm free over broken mountain asphalt.',
    selectedPhotos: f1.photos,
  });

  const f2 = await repo.addTripFeedback({
    tripId: 'trip_goa_02',
    riderId: 'rider_deepa',
    riderCallsign: 'NightCrawler',
    rating: 5,
    feedback: 'Bangalore to Goa Solo Night Ride - Low-side and high-side detection running 100% locally on device gave me real peace of mind. Knowing the 3-tier emergency hierarchy was ready offline made all the difference.',
    suggestions: 'Love the glove-friendly UI!',
    photos: [
      'https://images.unsplash.com/photo-1568772585407-9361f9bf3a87?auto=format&fit=crop&w=600&q=80'
    ],
    publishConsent: true,
    photoConsent: true,
  });
  await repo.updateTripFeedbackReview(f2.id, {
    action: 'APPROVE',
    adminNotes: 'Highlighting solo safety and offline tiers',
    templateLayout: 'pic-left-text-right',
    formattedText: 'Bangalore to Goa Solo Night Ride — Low-side and high-side detection running 100% locally on device gave me real peace of mind. Knowing the 3-tier emergency hierarchy was ready offline made all the difference.',
    selectedPhotos: f2.photos,
  });

  const f3 = await repo.addTripFeedback({
    tripId: 'trip_nilgiris_03',
    riderId: 'rider_vikram',
    riderCallsign: 'StormRider',
    rating: 5,
    feedback: 'Nilgiri Regroup & High-Speed Convoy - CoRoute\'s transparent maintenance pricing is so refreshing. We see new features dropping every week, and the voice intercom latency is razor sharp.',
    suggestions: 'Keep up the rapid iteration!',
    photos: [
      'https://images.unsplash.com/photo-1558981806-ec527fa84c39?auto=format&fit=crop&w=600&q=80',
      'https://images.unsplash.com/photo-1449426468159-d96dbf08f19f?auto=format&fit=crop&w=600&q=80'
    ],
    publishConsent: true,
    photoConsent: true,
  });
  await repo.updateTripFeedbackReview(f3.id, {
    action: 'APPROVE',
    adminNotes: 'Community pricing appreciation & multi-pic template',
    templateLayout: 'multi-pic-grid',
    formattedText: 'Nilgiri Regroup & High-Speed Convoy — CoRoute\'s transparent maintenance pricing is so refreshing. We see new features dropping every week, and the voice intercom latency is razor sharp.',
    selectedPhotos: f3.photos,
  });

  const port = 3000;
  const host = '127.0.0.1';
  gw.server.listen(port, host, () => {
    console.log(`\n======================================================`);
    console.log(` CoRoute Local Website Running Live at:`);
    console.log(`   http://${host}:${port}`);
    console.log(`   http://localhost:${port}`);
    console.log(`======================================================\n`);
  });
}

run().catch((err) => {
  console.error('Fatal local preview error:', err);
  process.exit(1);
});
