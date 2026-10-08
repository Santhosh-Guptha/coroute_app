# Play Store listing: CoRoute

Text below follows the website rules: no emoji, no em dashes, no invented numbers or reviews.

**App name (max 30):** CoRoute: Group Ride Convoy
**Short description (max 80):** Keep your group together: live convoy map, intercom, SOS and trip reports.

**Full description (max 4000):**

CoRoute keeps a group of riders together. The lead creates a convoy and shares a six-digit code. Everyone who joins appears on one live map with speed, heading and battery, and the whole group can talk, send a status card or raise an SOS.

ON THE RIDE
- Live convoy map with the planned route, stops and destination
- Voice intercom: hold to talk or hands-free, to the whole group or privately to one rider; nothing is recorded
- One-tap SOS that stays on every rider's screen until someone resolves it, with distance, direction and a Navigate button
- Riders can answer an SOS with "I'm going" or "I'm with them", and the group sees who is on the way
- Crash detection during a ride: the phone rings first and counts down for 30 seconds, so you can cancel with "I'm OK"; you can switch it off
- If there is no internet, your phone can text your emergency contact, your lead and the nearest riders with a map link (you switch this on, up to 10 people)
- Optional medical info (blood group, allergies, notes) shown to your group only while your SOS is open
- A gentle break reminder after about 2 hours of riding, and an "Are you OK?" check when you have been far from the group for a long time
- The group sees the difference between "no signal" and "app closed"
- Status cards for fuel, rest, photo stop or a short regroup
- Each rider is marked as they reach a planned stop, and the stop is done when the whole group is there
- A group speed limit set by the lead: riding over it is logged and the group is told once
- The lock screen shows how far each rider is from you
- Light theme for bright sun and dark theme for night, switching by itself at sunrise and sunset

AFTER THE RIDE
- A trip report for every rider: distance, riding time, stops and top speed
- One map with each rider's route in their own colour, where they started, waited and finished
- A shared timeline of the ride: who stopped and for how long, who fell behind, who lost signal
- A replay of the whole ride and a GPX file of your own route

BATTERY AND SIGNAL
GPS slows down when you stop, audio is sent only while someone talks, and the app keeps a single connection. When there is no signal your route is kept on the phone and sent when the connection returns.

FREE AND NON-PROFIT
CoRoute is made by riders at devmonks.space as a public service. There is no subscription, no advertising, no trackers and no sale of data.

PRIVACY
Your position is shared only with the convoy you are in, and only while you are in it. Voice is relayed live and never stored. Recorded routes are deleted after 90 days; your account and ride summaries stay until you delete them, which you can do in the app. Full policy: https://coroute.duckdns.org/privacy

PERMISSIONS
Location, including in the background, so your convoy still sees you with the phone in your pocket. Microphone for the intercom. Both are used only while you are in an active convoy. SMS, only if you switch on emergency texts: used only to text for help when your SOS cannot be sent. Full-screen alarm, so the crash alarm can ring on the lock screen. The motion sensor is read on your phone only, during a ride.

**Category:** Maps & Navigation
**Tags:** motorcycle, group ride, convoy, intercom, touring
**Contact e-mail:** santhoshbukka5@gmail.com
**Website:** https://coroute.duckdns.org
**Privacy policy:** https://coroute.duckdns.org/privacy

## Graphics in this folder
- `icon_512.png`: hi-res icon (512 x 512, required)
- `feature_graphic_1024x500.png`: feature graphic (required)
- `ic_launcher_foreground_432.png`: adaptive icon foreground layer

## Screenshots (2 to 8 required, take them from a real ride)
Run `store/capture_screenshots.ps1` with a phone connected over USB. It walks you through these screens and saves each one into `store/screenshots/`:

1. Cockpit map during a ride with two or more riders
2. Convoy screen with the riders list
3. Intercom with the "Talk to" picker open
4. Stops list showing who reached a stop
5. Trip report, Map tab with each rider's coloured route
6. Trip report, Summary with the rider cards
7. Group timeline
8. Light theme on the cockpit (Account, Appearance, Light)

Use real rides with real riders who agreed to be shown. Do not stage numbers.

## Before the first release with SMS (3.14)
- Fill in the SMS Permissions Declaration Form (use case: emergency / safety alerts) and the full-screen intent declaration in Play Console. Wording, video steps and the fallback if Play refuses are in `gateway/deploy/PLAY_STORE_CHECKLIST.md`.
- Update the Data safety form: phone numbers of other users processed on the device only, optional health info, motion sensor on the device only (same file).
- Upgrade the gateway to 3.14.0 before publishing the app (see `gateway/deploy/RUNBOOK.md`, "Release order for 3.14").

## After the listing is live
1. Copy the Play Store link (https://play.google.com/store/apps/details?id=space.devmonks.coroute_app).
2. On the server add `PLAY_STORE_URL=<that link>` to `/etc/coroute/gateway.env` and restart the gateway (`sudo systemctl restart coroute-gateway`).
3. The website's download buttons and the app's "Get the update" button go through `/download`, which then opens the Play Store instead of the APK. Nothing in the app or the website needs to change.
