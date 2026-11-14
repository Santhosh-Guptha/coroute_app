# CoRoute: Google Play listing graphics (v3.58 design)

Round 12 (website and store). Everything the Play Console main store listing asks for: the app icon, the feature
graphic, 8 phone screenshots and 5 + 5 tablet screenshots, plus listing text drafts and release notes.
Generator: `tool/store_assets/render.js` (see "Regenerating").

> **Accuracy note: read before publishing.** These screenshots are **rendered from the v3.58 design mocks**
> (static HTML/CSS with the app's tokens, Manrope and demo data: `tool/store_assets/mocks/`), **not captured on a
> phone**. Before you upload them, compare each one with the real **3.55.0+10029 (or later)** build and re-capture
> any screen that differs (steps below). Google asks that screenshots show the real in-app experience.

## Google Play requirements checked (14 Nov 2026)

Read on: [Add preview assets to showcase your app](https://support.google.com/googleplay/android-developer/answer/9866151?hl=en)
and [Best practices for your store listing](https://support.google.com/googleplay/android-developer/answer/13393723?hl=en).

| Asset | Google's rule | These files |
|---|---|---|
| App icon | 512 x 512, 32-bit PNG (with alpha), max 1024 KB; no badges or text suggesting ranking, price or categories | 512 x 512 RGBA, 32 KB, the v3.58 helmet logo (full square teal; Play applies the mask; docs/brand/BRAND_GUIDE_v3.58.md) |
| Feature graphic | 1024 x 500, JPEG or 24-bit PNG (no alpha); keep key elements centred, away from the edges; avoid device imagery, store badges and words such as "Best", "#1", "Top", "New", "Free" | 1024 x 500 RGB; helmet wordmark + "Ride together. Stay safe." on a convoy illustration; no device, no badge |
| Screenshots | JPEG or 24-bit PNG (no alpha); min side 320 px, max side 3840 px; the long side at most twice the short side; up to 8 per device type; apps: at least 4 at 1080 px or more (portrait min 1080 x 1920) | phone: 8 x 1080 x 2160 (exactly 2:1) RGB |
| Tablets (7-inch, 10-inch) | at least 4; 1,080 to 7,680 px; 16:9 landscape or 9:16 portrait; no extra text outside the app experience | 7-inch: 1920 x 1080 + 4 x 1080 x 1920; 10-inch: 2880 x 1620 + 4 x 1620 x 2880; no captions |
| Content | real in-app experience; taglines at most 20 % of the image; full battery, Wi-Fi and signal icons, no carrier, no notifications; no ranking, award, price or promo claims; no calls to action ("Download now"); alt text up to 140 characters | caption band about 18 % of the height (the screen starts at 400 of 2160 px); neutral status bar (9:41, full Wi-Fi, signal and battery); no prices, rankings or CTAs |

Device frames: Google warns against device imagery in the feature graphic (and forbids frames on Wear OS). The
phone screenshots therefore show the screen itself with rounded top corners, no phone body.

## Files

| File | Size (px) | Format | File size | Play Console slot |
|---|---|---|---|---|
| `feature_graphic_1024x500.png` | 1024 x 500 | 24-bit PNG, no alpha | 140 KB | Main store listing > Graphics > Feature graphic |
| `icon_512.png` | 512 x 512 | 32-bit PNG (RGBA) | 32 KB | Main store listing > Graphics > App icon |
| `phone/phone_01_home.png` | 1080 x 2160 | 24-bit PNG, no alpha | 269 KB | Main store listing > Phone screenshots |
| `phone/phone_02_group_map.png` | 1080 x 2160 | 24-bit PNG, no alpha | 270 KB | Main store listing > Phone screenshots |
| `phone/phone_03_ride_stats.png` | 1080 x 2160 | 24-bit PNG, no alpha | 248 KB | Main store listing > Phone screenshots |
| `phone/phone_04_curve_warnings.png` | 1080 x 2160 | 24-bit PNG, no alpha | 277 KB | Main store listing > Phone screenshots |
| `phone/phone_05_offline_link.png` | 1080 x 2160 | 24-bit PNG, no alpha | 232 KB | Main store listing > Phone screenshots |
| `phone/phone_06_sos_finder.png` | 1080 x 2160 | 24-bit PNG, no alpha | 192 KB | Main store listing > Phone screenshots |
| `phone/phone_07_explore.png` | 1080 x 2160 | 24-bit PNG, no alpha | 223 KB | Main store listing > Phone screenshots |
| `phone/phone_08_trip_report.png` | 1080 x 2160 | 24-bit PNG, no alpha | 236 KB | Main store listing > Phone screenshots |
| `tablet_10in/tablet10_01_ride_landscape.png` | 2880 x 1620 | 24-bit PNG, no alpha | 339 KB | Main store listing > 10-inch tablet screenshots |
| `tablet_10in/tablet10_02_home.png` | 1620 x 2880 | 24-bit PNG, no alpha | 314 KB | Main store listing > 10-inch tablet screenshots |
| `tablet_10in/tablet10_03_explore.png` | 1620 x 2880 | 24-bit PNG, no alpha | 201 KB | Main store listing > 10-inch tablet screenshots |
| `tablet_10in/tablet10_04_community.png` | 1620 x 2880 | 24-bit PNG, no alpha | 208 KB | Main store listing > 10-inch tablet screenshots |
| `tablet_10in/tablet10_05_profile.png` | 1620 x 2880 | 24-bit PNG, no alpha | 242 KB | Main store listing > 10-inch tablet screenshots |
| `tablet_7in/tablet7_01_ride_landscape.png` | 1920 x 1080 | 24-bit PNG, no alpha | 214 KB | Main store listing > 7-inch tablet screenshots |
| `tablet_7in/tablet7_02_home.png` | 1080 x 1920 | 24-bit PNG, no alpha | 209 KB | Main store listing > 7-inch tablet screenshots |
| `tablet_7in/tablet7_03_explore.png` | 1080 x 1920 | 24-bit PNG, no alpha | 173 KB | Main store listing > 7-inch tablet screenshots |
| `tablet_7in/tablet7_04_community.png` | 1080 x 1920 | 24-bit PNG, no alpha | 173 KB | Main store listing > 7-inch tablet screenshots |
| `tablet_7in/tablet7_05_profile.png` | 1080 x 1920 | 24-bit PNG, no alpha | 166 KB | Main store listing > 7-inch tablet screenshots |

### Phone screenshots, in order (caption, then what the screen shows)

1. `phone_01_home.png` - "Ride together. Stay safe." Home: rides near you, the safety strip with Emergency, a nudge, communities.
2. `phone_02_group_map.png` - "Your group on one live map." Ride screen: destination pill, big turn card with the limit sign and then-line, SOS, speed / ETA / km left, group pill, Hold to talk.
3. `phone_03_ride_stats.png` - "Know your ride as you ride." Half sheet: arc speedometer with the limit, ride so far.
4. `phone_04_curve_warnings.png` - "Curves and limits, ahead." Night ride: Hairpin right, comfortable 25 in 300 m; offline link chip.
5. `phone_05_offline_link.png` - "When the signal drops." No mobile signal; Offline link, 5 riders, 2 hops; a few hundred metres per hop.
6. `phone_06_sos_finder.png` - "SOS, then help finds you." Find Ravi: colder / hotter meter, ~30 m estimated, Bluetooth and locator sound meters.
7. `phone_07_explore.png` - "Rides near you." Explore with chips and the ranked list.
8. `phone_08_trip_report.png` - "Every ride, remembered." Trip report: 128 km, moving time, stops, speed chart, ride summary e-mail, live link.

Suggested alt text (Play: 140 characters or less, do not start with "image of"):
1. CoRoute home with rides near you, a ride safety strip with an Emergency button and riding communities
2. CoRoute ride screen with a big turn card, speed limit sign, SOS button, group status and hold to talk
3. CoRoute ride stats sheet with a speedometer against the limit and ride so far
4. CoRoute night ride screen warning of a hairpin right with a comfortable speed of 25
5. CoRoute map with no mobile signal showing the offline link between 5 riders over 2 hops
6. CoRoute rescue finder with a colder to hotter meter and an estimated distance of about 30 metres
7. CoRoute Explore listing rides near you with breakfast, night and one day filters
8. CoRoute trip report with distance, moving time, stops and a speed chart

### Tablets

`tablet*_01_ride_landscape`: the landscape (handlebar mount) ride layout, side panel + map. `02_home`, `03_explore`,
`04_community`, `05_profile`: the phone layouts at tablet width (the app has no separate tablet layout; check them on a
real tablet and drop any that look stretched). Play needs at least 4 per tablet type: upload 4 or 5.

## Listing text drafts

Rules followed: no prices, offers, rankings, awards, download counts, testimonials or other brands; no emoji; no
calls to download; every claim is backed by a feature in the build (see the honest ranges in
docs/features_355/rescue_beacon.md and offline_long_range_link.md). The app name stays as it is in the Console.

**Short description (79 of 80):**

Ride together, stay safe: crash alerts, SOS without signal, group map, intercom

**Full description (3723 of 4000):**

```
CoRoute is a safety app for motorcycle riders, for group rides and solo rides. The lead starts a ride and shares a code; everyone who joins appears on one live map, and the group can talk, regroup or raise an SOS.

SAFETY, FREE FOR EVERY RIDER
- Crash detection: a hard fall starts a loud alarm and a 30-second "Are you OK?" check, even over the lock screen. Tap I'm OK and nobody is disturbed. No answer, and your group and emergency contact are alerted.
- Hold-to-send SOS on every ride screen.
- SOS without mobile data: your phone texts your location by SMS from your own SIM (carrier charges apply). With no network at all, the group's phones pass the SOS along, phone to phone, until one gets through.
- Rescue beacon and finder: after an unanswered crash alarm, the phone plays a siren that gets louder and sends a short-range locator signal. Riders who come to help tap Find and follow a hotter or colder meter. It helps in the last stretch (Bluetooth roughly 30 to 100 m, the siren tens of metres); GPS and the shared position bring helpers close.
- Medical ID shown to your group only while an SOS is open, and a live link your family can open in any browser.
- Siren alerts: during a ride the phone listens for ambulance, police and fire sirens and tells you, in your earbuds, to give way.

ON THE RIDE
- A big turn card with the distance to the next turn, the road name and a "then" line when two turns come close.
- Curve warnings with a comfortable speed, the road's speed limit (estimated limits are marked est. and never spoken) and hazards reported ahead, one advisory at a time.
- A speed dial that turns amber over your limit, and a ride sheet with ride so far, distance by speed and time over the limit.
- Live group map with lead and sweep roles; the sweep and lead are told when someone falls behind, and a regroup point keeps the plan.
- Offline link: when the signal drops, the group's phones pass messages along, a few hundred metres per hop. It works best when the group rides close; it needs no extra hardware.
- Intercom: push-to-talk or hands-free, to the group or one rider, through your helmet headset or the phone. Noise reduction takes out wind and engine noise. Voice is relayed live and never recorded.
- Glove-sized controls, hold-to-end, light and dark, portrait and a landscape handlebar layout.

YOUR RIDING COMMUNITY
- Explore rides near you: breakfast runs, night rides, one-day and weekend trips, ghats and twisty roads, with road notes from riders (anonymous, only where enough riders passed).
- Crews with polls and ride invites, friends by username, clubs you join with a code, a rider score and leaderboards you can hide from.

AFTER THE RIDE
- A trip report for every rider: distance, moving time, stops, speed against the limit and each rider's route on one map.
- A ride summary by e-mail, a replay and a GPX file.

FREE AND PRIVATE
Solo riding and every safety feature are free. Joining a group ride you are invited to is free. No ads, no trackers and no sale of data. Your position is shared only with the group you ride with, and only during the ride. Motion data for crash detection stays on your phone.

PERMISSIONS
Location, including in the background, so your group still sees you with the phone in your pocket. Microphone for the intercom and siren alerts, only during a ride. Nearby devices (Bluetooth) for the offline link, the rescue beacon and helmet headsets; not used to find your location. SMS (send only), asked with an explanation, so an SOS can reach your emergency contacts without data. Full-screen alarm for the crash check.

CoRoute adds to emergency services; it does not replace them. In an emergency in India, call 112.

Needs Android 7.0 or newer.
```

**Release notes, "What's new" (442 of 500):**

```
- New look: Home, Explore, Community, Chat and Profile, in light and dark.
- New ride screen: a big turn card, curve warnings with a comfortable speed, the limit sign, and ride stats as you ride.
- Offline link: with no signal, the group's phones pass messages along, a few hundred metres per hop.
- Rescue beacon and finder: helps riders find a fallen rider in the last stretch.
- Clearer intercom with noise reduction, and simpler settings.
```

Release notes describe the v3.58 redesign; publish them only with the build that contains it.

## Before publishing: compare with the real build and re-capture

1. Install the release build (3.55.0+10029 or later) on a phone with a 1080 px wide screen (or an emulator,
   Pixel 7 profile, 1080 x 2400). Sign in with a demo account; use the demo names (Meera, Imran, Kiran, Asha, Dev,
   Ravi) and no real phone numbers.
2. Set the clock to 9:41 and clean the status bar with Android's demo mode:
   ```
   adb shell settings put global sysui_demo_allowed 1
   adb shell am broadcast -a com.android.systemui.demo -e command enter
   adb shell am broadcast -a com.android.systemui.demo -e command clock -e hhmm 0941
   adb shell am broadcast -a com.android.systemui.demo -e command battery -e level 100 -e plugged false
   adb shell am broadcast -a com.android.systemui.demo -e command network -e wifi show -e level 4 -e mobile show -e datatype none -e level 4
   adb shell am broadcast -a com.android.systemui.demo -e command notifications -e visible false
   ```
3. Open each screen and capture it:
   `adb exec-out screencap -p > phone_02_raw.png` (or Android Studio > Running Devices > camera icon, or
   Logcat > Screen capture). End demo mode with `... -e command exit`.
4. For a screen that differs from the render, put the capture into the same frame and caption: replace the mock
   screenshot in `tool/store_assets/render.js` (`shootMock` for that job) with your PNG scaled to 792 x 1760, or
   upload the raw capture. A 1080 x 2400 capture is longer than Play's 2:1 limit (2400 / 1080 = 2.22), so crop it to
   1080 x 2160 first (for example `convert raw.png -gravity north -crop 1080x2160+0+0 +repage out.png`).
5. Screens with live data to check especially: the offline link chip text, the finder meter labels, the curve
   warning strip, the ride sheet stats, and that the Explore list shows only places you curated.

## Regenerating

```
node tool/store_assets/render.js play            # this folder
node tool/store_assets/render.js play phone_05   # one job
node tool/store_assets/render.js web             # the website phone screenshots (gateway/public/assets/screens)
node tool/store_assets/story_frames.js           # the website story's no-JS frames
```

Needs Playwright with Chromium (gateway/node_modules or the global npm root) and python3 with Pillow. The mocks:
`tool/store_assets/mocks/gen_redesign.py` (round 11 redesign screens), `gen_extra.py` (crash check, SOS sent,
finder, offline link, trip report) and `hud/*.html` (the round 11 ride screen mocks).
