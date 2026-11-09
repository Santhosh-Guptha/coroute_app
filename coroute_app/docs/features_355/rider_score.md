# 3.55 rider score and public leaderboard

Area: `rider_score`. A private 0–100 score of **how safely** someone rides, with tips, plus a public
leaderboard by username. Safety first: the score never rewards speed and never penalises using SOS.

Admin switches (gateway/src/feature_flags.js, group Community, default on): `riderScore` (off:
`/me/score` answers `enabled: false`, the app hides the card and screen) and `leaderboard` (off: every
list of `/public/leaderboard` is empty, `/me/leaderboard` answers `enabled: false`). Rides are still
recorded while a switch is off, so turning it back on loses no history.

## Endpoints

| Method | Path | Auth | Body / answer |
|---|---|---|---|
| GET | `/api/me/score` | rider | `{enabled, score: 0-100\|null, level: string\|null, components: {smoothness, speedDiscipline, safety, consistency}, ridesCounted, minRides, updatedAt, tips: [string]}` |
| POST | `/api/me/score/rides` | rider | `{groupId, hardBrakes, breaks, fatiguePeak, fatiguePrompts, overLimitMin}` → 202. Per-ride counts from the phone's ride safety report (see Privacy). Rate limited 60/h |
| DELETE | `/api/me/score/phone` | rider | forgets every phone count sent (setting switched off) |
| GET | `/api/me/leaderboard` | rider | `{enabled, username, onLeaderboard, ranks: {topScore, longestRide, mostKm, mostHours, mostRides}}` (place or null) |
| GET | `/api/public/leaderboard` | none | `{updatedAt, topScore:[{username, score, rides}], longestRide:[{username, km}], mostKm:[{username, km}], mostHours:[{username, hours}], mostRides:[{username, rides}]}` |

`score` is null until `minRides` (3) rides of 10 km or more. A component is null when nothing
measures it (smoothness without the phone counts; speed discipline when no counted ride had a speed
limit and no phone counts); the app shows "Not measured yet" for it.

Public leaderboard: 10 rows per board, all time, cached 5 min per node (`Cache-Control: public,
max-age=300`), rate limited 30/min per IP. km rounded to 1 km, hours to 0.1 h, score to 1. Only
riders with a valid `username` on the user document, `publicLeaderboard !== false` (missing = true),
an active account (not held / blocked) and at least 3 counted rides. Never a userId, real name, email,
place, date or ride.

Admin: `GET /api/admin/users/:userId/details` has `riderScore` (score, components, totals, last 20
rides' per-ride parts, no places), shown in the admin user detail as "Rider score".

## Data used (all already on the gateway, numbers only)

From each finished group ride (`TimelineEngine.finishTrip` → `convoys.riderScore.onTripFinished`,
one ride per analysed member that kept a trip document; a rebuilt report replaces the ride, never
doubles it):

- trip report row: distance, riding (moving) time, end time, stats source;
- the report's stop list (uploaded track): longest stretch without a stop of 10 min or more;
- timeline `OVERSPEED` episodes of this rider: limit (group or town limit), top speed, duration;
- timeline `SEPARATED` episodes: count and total time; group size.

From the phone, only while the rider's setting **"Use my ride safety report for my rider score"**
(score screen, default ON) is on: per ride `hardBrakes`, `breaks`, `fatiguePeak` (0–100),
`fatiguePrompts`, `overLimitMin`. The app sends them once per finished ride (RideStatsStore entries
with an end time, last 30 days), at ride end (`SafetyService.onRideStatsEnded` → `RiderScoreService.syncAfterRide`, fire-and-forget) and when the score card or screen opens. Counts that arrive before the
report is built wait up to 14 days.

**Never read:** SOS, crash alarms, "Bike down?" checks, `POSSIBLE_INCIDENT` (hard stop), false
alarms, OFFLINE (signal), night riding, average or top speed, positions, routes, times of day.

## Formula

Per ride (rides of 10 km or more count):

- **Speed discipline** (null when the ride had no limit and no phone count):
  `100 − 100·min(1, 3·W / movingMin) − 10·severe`, where `W = Σ episode minutes × f(over)`,
  `over = (top − limit) / limit`, `f = 1 (<10%), 2 (10–25%), 4 (25–40%), 8 (≥40%)`, `severe` =
  episodes ≥ 40% over. Minutes the phone saw over its limit beyond the server's count add with
  `f = 1.5`. Under the limit nothing changes: going faster under the limit never adds a point.
- **Smoothness** (null without phone counts): `100·exp(−hardBrakesPer100km / 10)` (distance at least 10 km).
- **Safety habits**: starts at 100; longest stretch without a 10-min break over 2.5 h:
  `−min(30, (h − 2)·15)`; if the server could not see stops: very tired (peak ≥ 80) and no break −10;
  group rides: `−5` per separation after the first (max −20), separated more than 25% of the time −10.
  Breaks never lower it. SOS / crash never touch it.

Rider level:

- each component = weighted average over counted rides, weight = `0.5^(age/60 days) × clamp(hours, 0.25, 4)`;
- **Regular riding** = share of the last 13 fortnights with a counted ride, each fortnight weighted
  by the same 60-day half-life (riding every fortnight = 100);
- **Overall** = weights speed 40, smoothness 25, safety 25, regular 10, over the components that are
  measured (weights re-normalised); capped at 70 while speed discipline is not measured, so hiding
  speed data never helps;
- levels: Learner (< 50), Steady (50–69), Skilled (70–84), Ace Rider (85+). The top level was called "Road Captain" until the owner renamed it (Road Captain is a retired plan name); the app shows "Ace Rider" when an older gateway still sends the old name;
- up to 4 tips from the weakest parts ("Keep within the limit on highways…", "Take a 10-minute
  break at least every 2 hours…", "Leave more gap to the vehicle ahead…").

Recompute: on every ride write (incremental) and by the daily job `rider-score-daily` (job lease,
one node, 24 h) because decay and regular riding move with time. `GET /me/score` also recomputes on
read.

Leaderboard totals (all rides, archived totals kept beyond the last 400 rides): km, moving hours,
rides (10 km or more), longest ride. A ride over 2000 km, or averaging over 150 km/h, or with
distance but no riding time, is kept for the rider's own score but never counts publicly.

## Storage

`rider_scores` (own collection, unique `userId`, created at boot by `RiderScoreService.init`):
`{userId, rides: [{rideId, endedAt, km, movingMs, source, speedKnown, episodes: [{limitKmh, maxKmh, durMs}], separatedCount, separatedMs, groupSize, longestStretchMs, phone: {hb, br, fp, fn, ol} | null}], pending, archived, score, level, components, ridesCounted, tips, updatedAt, eligible, lbPublic, lbScore, lbKm, lbHours, lbRides, lbLongestKm}`.
No names, no coordinates. Writes are compare-and-replace (two nodes never lose a ride). Removed with
the account (`Repo.deleteUserCascade`).

## Privacy

- The ride safety report stays private: the phone sends only five counts per ride, only with the
  setting on (default on, explained on the score screen); switching it off deletes the counts sent.
- The score is visible only to the rider (and the master admin in user detail).
- The leaderboard shows usernames and rounded totals only; opting out (`publicLeaderboard: false`,
  profile setting owned by the profile screen) hides the rider at the next cache refresh (≤ 5 min).
  Own places (`/me/leaderboard`) use a `lbPublic` flag refreshed on each ride and daily.

## Fairness notes

- Speed is judged only against the limit that applied (group limit, town limit near stops, the
  phone's limit check), never against other riders' speed.
- Riders without a group speed limit and without the phone counts cannot reach above 70.
- Short city hops under 10 km do not count, so a commute does not swamp touring rides; long rides
  weigh more but are capped at 4 h per ride.
- Being separated once is free (traffic, signals); OFFLINE (no signal) is never judged.
- Smoothness is self-reported by the phone (a modified app could send zero hard brakes); it is at most
  25% of the score and the public top-score board also requires 3 server-recorded rides.
- Recent riding counts more (half-life 60 days), so a rider who improves sees it within weeks.

## Files

Gateway: `src/rider_score.js` (pure math + `RiderScoreService`), `src/leaderboard.js` (`Leaderboard`
+ routes), small hooks in `src/app.js` (service, router, daily job), `src/timeline.js` (finishTrip),
`src/routes.js` (admin user detail), `src/oracle/repo.js` (account erase), `src/feature_flags.js`.
App: `lib/domain/score/rider_score.dart`, `lib/data/services/rider_score_service.dart`,
`lib/presentation/score/` (`rider_score_screen.dart`, `rider_score_card.dart` = `RiderScoreCard` for the
profile, `leaderboard_screen.dart`, `admin_rider_score_section.dart`), entry in the Trips header
(`trip_history_screen.dart`), section in `admin_user_details_screen.dart`.

## Tests

- `gateway/test/rider_score_355.test.js` (11): overspeed lowers / 40%+ weighs heavily, speed never
  raises (speeds not even stored), SOS / crash / incident no penalty, breaks and separation, smoothness,
  minRides and short rides, decay and consistency, speed-unknown cap, API + phone counts (pending and
  merged, no position stored, delete), leaderboard privacy (no userIds / names / emails / rides),
  opt-out, no username, below minRides, implausible rides, rounding, 5-min cache, own places, both
  switches, admin view, daily recompute, account erase, finishTrip hook (episodes recorded, rebuild idempotent).
- `test/rider_score_355_test.dart` (pure): parsing, clamping, explanations, "You: #42", counts-only body.
