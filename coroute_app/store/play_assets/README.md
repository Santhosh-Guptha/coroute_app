# CoRoute: Google Play listing graphics

Everything Play Console asks for on the main store listing: app icon, feature graphic, phone screenshots and 7-inch and 10-inch tablet screenshots, plus updated listing text. Screenshots are 24-bit PNGs with no alpha, each well under Play's 8 MB limit.

## Files

| File | Size (px) | Format | File size | Play Console slot |
|---|---|---|---|---|
| `icon_512.png` | 512 x 512 | 32-bit RGBA | 31 KB | App icon (Store settings > Main store listing > App icon) |
| `feature_graphic_1024x500.png` | 1024 x 500 | 24-bit RGB, no alpha | 258 KB | Feature graphic |
| `phone/phone_01_ride_together.png` | 1080 x 1920 | 24-bit RGB, no alpha | 663 KB | Phone screenshots |
| `phone/phone_02_sos.png` | 1080 x 1920 | 24-bit RGB, no alpha | 324 KB | Phone screenshots |
| `phone/phone_03_crash.png` | 1080 x 1920 | 24-bit RGB, no alpha | 372 KB | Phone screenshots |
| `phone/phone_04_intercom.png` | 1080 x 1920 | 24-bit RGB, no alpha | 306 KB | Phone screenshots |
| `phone/phone_05_group.png` | 1080 x 1920 | 24-bit RGB, no alpha | 616 KB | Phone screenshots |
| `phone/phone_06_sirens.png` | 1080 x 1920 | 24-bit RGB, no alpha | 504 KB | Phone screenshots |
| `phone/phone_07_people.png` | 1080 x 1920 | 24-bit RGB, no alpha | 407 KB | Phone screenshots |
| `phone/phone_08_trip_report.png` | 1080 x 1920 | 24-bit RGB, no alpha | 376 KB | Phone screenshots |
| `phone/phone_09_guardians.png` | 1080 x 1920 | 24-bit RGB, no alpha | 534 KB | Phone screenshots |
| `phone/phone_10_light_dark.png` | 1080 x 1920 | 24-bit RGB, no alpha | 620 KB | Phone screenshots |
| `tablet_7in/tablet7_01_map.png` | 1920 x 1080 | 24-bit RGB, no alpha | 623 KB | 7-inch tablet screenshots |
| `tablet_7in/tablet7_02_trip.png` | 1920 x 1080 | 24-bit RGB, no alpha | 389 KB | 7-inch tablet screenshots |
| `tablet_7in/tablet7_03_sos.png` | 1920 x 1080 | 24-bit RGB, no alpha | 403 KB | 7-inch tablet screenshots |
| `tablet_7in/tablet7_04_people.png` | 1920 x 1080 | 24-bit RGB, no alpha | 277 KB | 7-inch tablet screenshots |
| `tablet_10in/tablet10_01_map.png` | 2560 x 1440 | 24-bit RGB, no alpha | 942 KB | 10-inch tablet screenshots |
| `tablet_10in/tablet10_02_trip.png` | 2560 x 1440 | 24-bit RGB, no alpha | 571 KB | 10-inch tablet screenshots |
| `tablet_10in/tablet10_03_sos.png` | 2560 x 1440 | 24-bit RGB, no alpha | 611 KB | 10-inch tablet screenshots |
| `tablet_10in/tablet10_04_people.png` | 2560 x 1440 | 24-bit RGB, no alpha | 408 KB | 10-inch tablet screenshots |

## Suggested order

Phone screenshots (Play shows up to 8; the first 3 or 4 matter most, so the safety story comes first):

1. `phone_01_ride_together.png`: "Ride together. Stay safe." (live group map, 3D bikes, L/S roles)
2. `phone_02_sos.png`: "SOS in one hold"
3. `phone_03_crash.png`: "Crash detection" (30 s countdown, I'm OK / Need help)
4. `phone_05_group.png`: "Never lose your group" (fell behind 1.2 km, regroup point)
5. `phone_06_sirens.png`: "Hear sirens through earbuds"
6. `phone_04_intercom.png`: "Talk hands-free"
7. `phone_07_people.png`: "Your crew, your rides" (Friends, Crews, Requests, poll)
8. `phone_08_trip_report.png`: "Every ride, remembered" (Ace Rider)

Extras, if you want to swap any in: `phone_09_guardians.png` ("Guardians at home", live link page on coroute.devmonks.space) and `phone_10_light_dark.png` ("Light and dark"). The teal and warm backgrounds alternate in file-number order. If you use a different order, the series still looks consistent.

Tablet screenshots (7-inch and 10-inch, same order): map, trip report, SOS, People.

## Notes

- **App icon:** the old `store/icon_512.png` is 512 x 512 but 24-bit RGB. Play asks for a 32-bit PNG, so `icon_512.png` here is the same artwork saved as RGBA. It is a full square and Play applies the round mask itself.
- **Feature graphic:** the logo and headline sit in the left 45 %, and the bikes sit on the right with at least 50 px from every edge. The centre is kept fairly clear for the video play button.
- **Accuracy:** screens are drawn in HTML/CSS with the v3.55 design tokens, Manrope and the real map-bike PNG layers (base, tinted paint, gloss, shadow), so they are a stylised version of the real screens. Names (Asha, Kiran, Arjun, Meera, Ravi) and usernames (SwiftFalcon482 and so on) are demo data. Amounts on the screens (128 km, score 88, poll votes) are in-app sample values, not claims about the app.
- **Policy:** no prices, offers, rankings, ratings, awards, download counts, other brands or real people. Red is used only for SOS and crash. The siren alert uses amber.

## Regenerating

The sources are in `source/`: one HTML file per panel, `tablet.html?s=map|trip|sos|people`, `feature.html`, the shared `common.css`, `common.js` (map generator, 3D bike compositing, icons) and `cockpit.js`. Assets are in `source/assets/`.

```
cd source
node render.js            # renders everything into ../ (this folder)
node render.js /tmp/x p03 # renders only matching jobs into another folder
```

You need Playwright with Chromium. To flatten to RGB the script uses `sharp` if it is installed, and otherwise `python3` with Pillow. 10-inch tablet images are the same pages rendered at 4/3 scale (2560 x 1440).

## Listing text

Also saved as `listing_text.md`. The full description is 3917 characters, under the 4000 limit.

Follows Play listing policy: no prices, offers, rankings, ratings, awards, download counts or invented numbers; no emoji; no calls to download.

**App name (30 max, 26 used):**
CoRoute: Group Ride Safety

**Short description (80 max, 79 used):**
Ride together, stay safe: live group map, SOS, crash alerts, intercom and crews

**Full description (4000 max):**

CoRoute is a safety app for motorcycle riders in India, for group rides and solo rides. The lead starts a ride and shares a code. Everyone who joins shows up on one live map with speed, heading and battery, and the group can talk, raise an SOS or regroup.

SAFETY FIRST
- SOS in one hold: hold for 3 seconds and your group and emergency contacts are alerted with your location. The SOS stays on every screen until it is resolved, with distance, direction and Navigate; riders answer with "I'm going" or "I'm with them"
- Crash detection: after a hard stop CoRoute asks "Possible crash. Are you OK?" with a 30 second countdown. Tap "I'm OK" to cancel or "Need help" to send at once; if you don't answer, the SOS is sent
- Siren alerts: when an ambulance siren is close by, CoRoute tells you to give way through your earbuds, even with noise cancelling on
- Without internet, your phone can text your emergency contact, lead and nearest riders a map link (you switch this on)
- A safety card (blood group, allergies, notes for a doctor, emergency contact) shown to your group only while your SOS is open
- Guardians at home: share a live link so family can follow your ride in a browser (first name and position only); the link ends on its own

STAY TOGETHER
- Live group map with 3D rider markers, the planned route, stops and destination
- Lead and sweeper roles; the sweeper is told when a rider falls behind, with the gap in km
- Regroup points that everyone can navigate to
- A group speed limit set by the lead, with a lower limit near stops and in towns
- "No signal" versus "app closed", low battery and arrivals at stops
- A large ride notification on the lock screen with riders ahead and behind, SOS (hold to send), Wait for me and Open map
- Weather along the route and a sunset warning before you leave; route maps saved on the phone for areas without signal

TALK HANDS-FREE
- Group intercom: hands-free or hold to talk, to everyone or to one rider
- Clear voice with wind noise reduced
- Voice is relayed live and never recorded

YOUR CREW
- People hub with Friends, Crews and Requests
- Crews for the riders you ride with often, with the next ride and polls to pick where to go
- Push notifications for ride invites, crew polls, friend requests and safety alerts

EVERY RIDE, REMEMBERED
- A trip report for every rider: distance, riding time, stops and top speed
- One map with each rider's route in their own colour, where they started, waited and finished
- A shared timeline of the ride, a replay and a GPX file of your route
- A rider score for smooth, steady riding; ride well to earn Ace Rider

COMFORTABLE TO USE
- Calm light and dark themes, with a soft dark map for night riding
- Safety screens and spoken alerts in English, Hindi or Telugu
- Battery friendly: GPS slows down when you stop

PRIVACY
Your position is shared only with the group you are riding with, and only during the ride. A guardian live link shows only your first name and position, and ends on its own. Voice is relayed live and never stored. Recorded routes are deleted after 90 days; your account and ride summaries stay until you delete them, which you can do in the app. No advertising, no trackers, no sale of data. Full policy: https://coroute.devmonks.space/privacy

PERMISSIONS
Location, including in the background, so your group still sees you and crash detection still works with the phone in your pocket or the screen off; it is used only while you are in an active ride. Microphone for the intercom and for siren alerts, only during a ride. Notifications for ride alerts, SOS and push messages. SMS, only if you switch on emergency texts. Full-screen alarm for the crash countdown and the hold-to-send SOS screen on the lock screen. The motion sensor is read on your phone only, during a ride. Spoken alerts use your phone's own text-to-speech.

Made by riders at devmonks.space: https://coroute.devmonks.space

---

**Category:** Maps & Navigation
**Tags:** motorcycle, group ride, riding safety, intercom, touring
**Website:** https://coroute.devmonks.space
**Privacy policy:** https://coroute.devmonks.space/privacy
**Contact e-mail:** keep the address already set in Play Console
