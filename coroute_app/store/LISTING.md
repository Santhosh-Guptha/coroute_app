# Play Store listing: CoRoute

Text below follows the website rules: no emoji, no em dashes, no invented numbers or reviews.

**App name (max 30):** CoRoute: Group Ride Convoy
**Short description (max 80):** Keep your group together: live convoy map, intercom, SOS and trip reports.

**Full description (max 4000):**

CoRoute keeps a group of riders together. The lead creates a convoy and shares a six-digit code. Everyone who joins appears on one live map with speed, heading and battery, and the whole group can talk, send a status card or raise an SOS.

ON THE RIDE
- Live convoy map with the planned route, stops and destination
- Voice intercom: hold to talk or hands-free, to the group or one rider; nothing is recorded
- SOS that stays on every screen until resolved, with distance, direction and Navigate; answer with "I'm going" or "I'm with them"
- Crash detection: "Possible accident detected. Are you okay?" with a 15 second countdown; cancel with "I'm OK" or send at once with "Need Help"; a follow-up check at your next stop
- Without internet, your phone can text your emergency contact, lead and nearest riders a map link (you switch this on)
- A safety card (blood group, allergies, notes for a doctor, emergency contact) shown to your group only while your SOS is open
- Break, fuel and "Are you OK?" reminders
- Status cards, "no signal" versus "app closed", and arrivals at every planned stop
- A group speed limit set by the lead, with a lower limit near stops and in towns; riding over it is logged
- A sweeper chosen by the lead is told when a rider drops behind; the lead sees low batteries and missing updates
- Weather along the route and a sunset warning before you leave; route maps saved on the phone for areas without signal
- During an SOS, share a 30 minute live link (first name and position only) and see the nearest hospital
- A large ride notification on the lock screen with riders ahead and behind, SOS (hold to send), Wait for me and Open map
- Navigation to a rider in trouble with spoken distances; spoken alerts can be switched off
- Light and dark themes; safety screens and spoken alerts in English, Hindi or Telugu

HELP FROM NEARBY RIDERS
- After an accident your group is alerted first. A few riders of other groups riding toward it on the same road can be asked to help if they may arrive sooner
- They see only where and how far until they agree, then the first name and vehicle; never phone numbers or the group
- Riders heading toward an accident on the same road get a caution
- You can switch off being asked, or others being asked for you

GROUPS NEARBY (OPTIONAL)
- Only when both leads make their group Public with discovery on: group name, rider count and rounded distance, and a wave. Never positions or names

AFTER THE RIDE
- A trip report for every rider: distance, riding time, stops, top speed and your own hard-stop count
- One map with each rider's route in their own colour, where they started, waited and finished
- A shared timeline of the ride: who stopped and for how long, who fell behind, who lost signal
- A replay of the ride and a GPX file of your route

BATTERY AND SIGNAL
GPS slows down when you stop and audio is sent only while someone talks. Without signal your route is kept on the phone and sent later.

FREE AND NON-PROFIT
CoRoute is made by riders at devmonks.space as a public service. There is no subscription, no advertising, no trackers and no sale of data.

PRIVACY
Your position is shared only with the convoy you are in, and only while you are in it. In an emergency you raise, riders of other groups who are asked to help see the emergency point only. Voice is relayed live and never stored. Recorded routes are deleted after 90 days; your account and ride summaries stay until you delete them, which you can do in the app. Full policy: https://coroute.duckdns.org/privacy

PERMISSIONS
Location, including in the background, so your convoy still sees you with the phone in your pocket. Microphone for the intercom. Both only while you are in an active convoy. SMS, only if you switch on emergency texts. Full-screen alarm for the crash alarm and the hold-to-send SOS screen on the lock screen. The motion sensor is read on your phone only, during a ride. Spoken alerts use your phone's own text-to-speech. No Bluetooth.

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

## Before the safety round release (3.16)
- Upgrade the gateway to 3.16.0 before publishing build 76 (see `gateway/deploy/RUNBOOK.md`, "Release order for 3.16"); allow the new outbound host api.open-meteo.com on the server.
- Update the Data safety form (rows marked 3.16 in `gateway/deploy/PLAY_STORE_CHECKLIST.md`): weather route points to Open-Meteo through the CoRoute server, live emergency links, the nearest hospital lookup; the unused Bluetooth permission was removed.
- Check the full description length after any edit (4000 characters at most).

## Before the release with the nearby rider network (3.15)
- Upgrade the gateway to 3.15.0 before publishing build 75 (see `gateway/deploy/RUNBOOK.md`, "Release order for 3.15").
- Update the Data safety form (rows marked 3.15 in `gateway/deploy/PLAY_STORE_CHECKLIST.md`) and the full-screen intent description (15 second countdown, hold-to-send SOS screen).
- Optional new screenshots: the large ride notification on the lock screen, and the "Rider emergency nearby" request. Only from real rides or a test with riders who agreed; do not stage numbers.

## After the listing is live
1. Copy the Play Store link (https://play.google.com/store/apps/details?id=space.devmonks.coroute_app).
2. On the server add `PLAY_STORE_URL=<that link>` to `/etc/coroute/gateway.env` and restart the gateway (`sudo systemctl restart coroute-gateway`).
3. The website's download buttons and the app's "Get the update" button go through `/download`, which then opens the Play Store instead of the APK. Nothing in the app or the website needs to change.
