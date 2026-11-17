# Intelligence insights (v3.62)

Code: `gateway/src/intel/insights.js`; admin page `#/insights` (`public/admin/intel.js`); app chip in Plan a ride
(`lib/domain/intel/route_difficulty.dart`). Tests: `gateway/test/intel_362_insights.test.js`,
`test/route_difficulty_362_test.dart`. Nothing new is collected; consent, trimming, k-anonymity and 90-day raw
retention from ROAD_AND_SAFETY_INTELLIGENCE.md apply unchanged.

| Insight | How | Privacy guard | Where |
|---|---|---|---|
| Popular roads (corridors) | neighbouring geohash-6 road cells, each with >= max(5, INTEL_K_MIN) riders and >= 5 km ridden, joined into chains of >= 3 cells; ranked by ridden km; weekend share from the time buckets | cell centres only (about 1 km), minimum riders per corridor shown as "5+" | admin Insights (map + table) |
| Route difficulty | samples the planned line every ~1 km: twisty (score >= 30) and ghat (>= 50) km, rough-road km, hazard spots (score >= 3), night share (19:00-06:00 IST at 40 km/h), length >= 400 km → points → Easy / Moderate / Challenging + up to 4 reasons | cells under k-min ignored; no per-rider data | `POST /api/intel/route-difficulty` (signed in), Plan a ride chip |
| Stop demand | stop cells per geohash-4 area: stops, fuel / food / other, six 4-hour slots, busiest slot | k-min cells only | admin Insights |
| Monthly trends | counted while raw rows are folded (km, riding hours, events by type), 24 months kept | totals only | admin Insights |
| Rider risk | hard brake + swerve + skid per 100 km over 30 days for riders with >= 50 km; buckets low < 2, medium 2-6, high >= 6; counts only, hidden under k riders | per rider: `GET /api/admin/intel/rider-risk/:userId`, MASTER_ADMIN only, every view in the audit log, computed on demand, never stored or shown to riders | admin Insights |

Jobs: `intel-insights` (job lease, daily, 40 min after start; `INTEL_INSIGHTS_MAX_CELLS`, default 20,000 cells per
layer; risk reads at most 20,000 raw rows). `POST /api/admin/intel/insights/run` recomputes on the lease holder.

Limits: corridors are cell chains, not map-matched road segments (that needs Valhalla on the A1); trends count rows
once when folded (a later "delete my contributions" does not lower past monthly totals); the risk view only sees
riders who share road data.
