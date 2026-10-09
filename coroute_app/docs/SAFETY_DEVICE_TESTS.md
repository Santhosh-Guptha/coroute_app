# Rider safety: device tests (CoRoute 3.14, 3.15 and 3.16)

How to check crash detection, the crash alarm, emergency texts, the break
reminder and the "Are you OK?" check-in on real phones, safely, without a real
crash. Unit tests cover the rules with synthetic sensor traces
(`test/crash_detector_test.dart`, `test/safety_service_test.dart`,
`test/sms_fallback_test.dart`, `test/fatigue_checkin_test.dart`); these notes
cover what only a phone can show: sensors, the lock screen, SMS and battery.

## Safety first

- Never fall, brake hard or ride one-handed to "test" anything. Every test below
  is done parked, walking, or as a pillion with someone else riding normally.
- Drops are onto a cushion, sofa or bed, from about knee to waist height, with
  the phone in its case.
- Emergency texts go to real phones. Use your own second phone (or a friend who
  knows it is a test) as the emergency contact, and tell the test group first.
  Texts cost normal SMS charges.
- Remove test SOS alerts with "I am safe, cancel the SOS" so nobody keeps
  getting alarms.

## What you need

- Two Android phones (A = rider under test, B = lead / second rider), both on
  3.14 (build 74), signed in to two accounts, in the same test ride. The gateway
  must already run 3.14 (deploy it first; older gateways disable the new parts).
- On phone A: Profile > Edit profile: emergency contact = phone B's number (or a
  third phone). Profile > Ride safety: all four switches as each test says.
- Optional: a PC with `adb` for the sensor and battery checks.
- Useful phones: one Android 10 to 13, one Android 14 or newer, one Xiaomi or
  Samsung (battery killers), one dual-SIM phone.

## 1. Opt-in texts in the pre-ride checklist

1. On A, start a ride so the checklist opens (or clear "Do not show for 24 hours").
2. Under "Ride safety": "Crash detection" is on, "Text the group if there is no
   internet" is off. Read both explanations: plain words, no jargon, they say
   "up to 10", "map link" and "only during the ride".
3. Switch "Text the group" on: Android asks for SMS permission. Deny: the switch
   stays off and an amber line says texts need the SMS permission. Switch on
   again and allow: the switch stays on.
4. Android 14+: the row "Alarm on lock screen" is shown. If it is amber, tap Fix:
   the system page "Full-screen notifications" opens for CoRoute.
5. First time only: "Battery settings for <brand>" is shown. Tap Fix: the brand
   guide opens; "Open settings" opens the brand page (Xiaomi: Autostart; Samsung:
   Battery). After closing it, the row does not come back in the next checklist.

Expected: nothing blocks "Start the ride".

## 2. The accelerometer runs only when needed (battery)

With `adb` connected to A, during a ride:

```
adb shell dumpsys sensorservice | grep -i -A2 "accelerometer"
```

Look at the "active connections" / "registrations" of `space.devmonks.coroute_app`.

| Situation | Accelerometer registered by CoRoute |
|---|---|
| No ride, or ride but parked / walking | no |
| Pillion, above 25 km/h | yes, with a batch latency of 2 s (`maxReportLatency` 2000000 us) |
| 30 s after slowing below 25 km/h | no (removed on the next bucket) |
| Crash detection switched off | no, at once |
| Ride ended | no |

The theme option "Light sensor" uses the light sensor, not the accelerometer;
ignore it here.

## 3. Crash alarm without crashing

The rule: above 25 km/h in the last 30 s (and faster than 25 km/h in the 10 s
before the jolt), a jolt of 4 g or more, then 5 km/h or less within 10 s, then
20 s without riding on (no GPS speed above 15 km/h, not more than 80 m away).
Getting up and walking about does NOT stop the alarm: the rider answers "I'm OK"
(product decision 3.14). Only when the GPS gave no fix at all after the jolt must
the phone also lie still for those 20 s (otherwise riding on in a tunnel with the
GPS lost would look like a crash).

Pillion test (recommended, spec test): someone else rides at about 30 km/h on an
empty road. The pillion holds a cushion on the lap and drops A from about 30 cm
onto it, hard, or slaps the phone down on the cushion. The rider then stops
normally within 10 s and both stay still with A lying on the cushion for 20 s.

Parked alternative (no riding at all): use a mock GPS app that plays a route with
speed (for example "Lockito"; Developer options > Select mock location app).
Play a route at 40 km/h, drop A onto a sofa cushion from waist height, stop the
mock route at once (speed 0) and leave A lying still for 20 s. A plain drop on a
soft cushion may stay under 4 g; a drop onto a bed or a firm sofa usually
reaches it. A drop while the mock speed is 0 must never ring (never armed).

Expected on A, about 20 s after the stop (3.15 texts):
- full screen red "Possible accident detected. Are you okay?", "Sending SOS to
  your group in 15 seconds.", counting down, big green "I'm OK" and red "Need Help";
- loud repeating sound at alarm volume and vibration (also in silent mode on most
  phones, because it uses the alarm stream; Do Not Disturb may block it unless
  alarms are allowed);
- a notification "Possible accident detected" ("Are you okay? Sending SOS to your
  group in 15 seconds.") with the buttons "I'm OK" and "Send now" (the button
  label of the notification is still "Send now" in 3.15; it does the same as Need Help).

Check each answer:
- "I'm OK" (screen or notification): alarm stops, nothing reaches B, the timeline
  shows nothing. No new alarm for 2 minutes.
- "Need Help" (or "Send now" on the notification): B gets the emergency at once
  (server source NEED_HELP); A's screen switches to the SOS sheet.
- No answer: after 15 s the same SOS is sent automatically (source CRASH_AUTO,
  shown to the group as an automatic alert).
- Walk around with A in the hand during the 20 s (mock speed 3 to 5 km/h): the
  alarm still comes; answer "I'm OK".
- Pick the phone up and ride on (mock speed above 15 km/h within the 20 s): no alarm.
- Mock route slowed to 3 km/h for 15 s first, then drop A (a phone dropped after
  arriving at a stop): no alarm.

## 4. Alarm on the lock screen (Android 10, 13, 14)

Do test 3, but press the power button to lock A right after the drop.

| Phone | Full-screen allowed | Expected |
|---|---|---|
| Android 10 to 13 | always | screen turns on, the red alarm shows over the lock screen; buttons work without unlocking |
| Android 14+ | allowed (checklist row green) | same as above |
| Android 14+ | denied (turn it off in Settings > Apps > CoRoute > Full-screen notifications) | no full screen, but a ringing heads-up notification; "I'm OK" and "Send now" on the notification work without unlocking; the countdown runs and the SOS is sent at 0 s |

After the alarm ends (any answer), lock A again: CoRoute must not show over the
lock screen any more (it does so only while the alarm is open).

Also check: notifications switched off for CoRoute (Android 13+ permission
denied). Expected: no sound from the notification, but the in-app screen and
vibration still appear when CoRoute is open, and the SOS is still sent at 0 s.

## 5. Emergency texts when there is no internet

Setup: on A, "Text the group if there is no internet" on, SMS allowed, emergency
contact set. B is the lead. Start the ride while online (A fetches the group's
numbers; nothing is shown).

Realistic test (no data, but phone signal): on A switch off mobile data and
Wi-Fi (not airplane mode). Hold SOS on A.
- The SOS sheet says "No signal. SOS not sent yet" and shows "Text the group now".
- After 45 s (or at once with "Text the group now") A texts: the emergency
  contact first, then the lead, then the nearest riders, at most 10.
- The sheet says for example "Texted your emergency contact and 1 rider."
- B's phone gets an SMS: "CoRoute SOS: <A> needs help (10:42). Map:
  https://maps.google.com/?q=..." with 5 decimals. The link opens the right spot.
- The text never contains other people's numbers.
- Turn data back on: the SOS reaches the group as usual; no second round of texts
  for the same SOS.

Airplane mode (spec test): with airplane mode on there is no phone signal either,
so the texts cannot go out. Expected: after 45 s the sheet says "The texts could
not be sent. Call your emergency contact or 112." Turning airplane mode off later
does not text again for that SOS; the SOS itself is sent when data returns.

Crash SOS: repeat test 3 with data off and let the countdown run out. The text
starts "CoRoute automatic alert: <A> may have crashed".

Delivered SOS: with data on, hold SOS: no texts are sent (the group got it).

Opt-out: on B, Profile > "Receive emergency texts from my ride group" off. Start a new ride
(or wait for the group list to refresh): A's next text round skips B.

Dual SIM: on a dual-SIM phone set Settings > SIM > SMS to "Ask every time". The
texts go from the default SIM without a question. Note which SIM sent them. If
nothing is sent, the sheet says so (report the phone model).

Limit: Android asks the user after about 30 texts in 30 minutes. CoRoute sends at
most 10 per SOS and 20 text parts in 30 minutes, so the system question should
never appear. Report it if it does.

## 6. Brand battery guide (Xiaomi, Samsung)

1. In the checklist, tap Fix on "Battery settings for Xiaomi" (or Samsung).
2. The steps match the phone. "Open settings" opens the brand page (Xiaomi:
   Autostart list; Samsung: battery page) or, if that page does not exist on this
   model, CoRoute's app settings.
3. Follow the steps, then lock the phone for 30 minutes during a parked ride: B
   must keep seeing A (not "App closed on this phone").

## 7. Break reminder

Needs a real ride of 2 hours without a stop of 10 minutes (stops under 10
minutes do not count as a break). Expected: "Time for a break" for the rider
only, once, then again after 60 minutes without a break; a 10-minute stop
resets it. With CoRoute in the background a quiet notification appears. Profile
> Ride safety > "Break reminder" off: never shown. The rule itself is unit tested.

## 8. "Are you OK?" check-in

1. B is the lead. In group settings set the separation distance to the lowest
   value.
2. Take A (riding pillion, driving with someone else, or simply leave A at home
   while B travels) farther than that distance from the group for 15 minutes.
   Other riders must have sent a position in the last 5 minutes.
3. A shows "Are you OK?" with a sound and a notification. Do not answer.
4. After 2 minutes B (lead) gets "No reply from <A>", labelled automatic.
5. Tap "I'm OK" on A: the lead's alert closes. If A answers before the 2 minutes,
   nothing is sent to anyone.
6. Not asked again for 30 minutes. With the switch off, never asked.

## 9. Battery over a 2-hour ride

Compare two similar rides (same phone, same route type, screen off, intercom off):
crash detection on vs off.

```
adb shell dumpsys batterystats --reset     # before the ride
adb shell dumpsys batterystats space.devmonks.coroute_app > ride.txt   # after
```

Or Settings > Battery > App usage. Expected: the difference is small (target:
under 2 % of the battery over 2 hours), because the sensor runs only above
25 km/h, in 2-second hardware batches, reduced to one small message per second.
Note the phone model (phones without sensor batching deliver samples directly and
may use a little more).

## 10. Big ride notification on the home and lock screen (3.15)

During a ride the plain "Convoy: ..." notification is replaced in place by a large
one: destination, km left and ETA; up to 2 riders ahead and 2 behind with
distances and flags ("No signal", "Stopped 5 min"); a group status line; buttons
SOS, Wait for me, Open map, and Navigate / I Can Help during an emergency.
Settings > Ride safety: "Large ride notification" (on) and "Show ride on lock
screen" (on).

Phones: at least one each of Pixel or Android One, Samsung (One UI), Xiaomi or
Redmi (MIUI / HyperOS), Oppo or Realme (ColorOS), on Android 8, 10, 12 and 14.
Use two phones in one convoy (A and B), B riding ahead (mock route) by 1 to 3 km.

| Check | Expected |
|---|---|
| Start the ride, pull down the shade | ONE ongoing CoRoute notification (never two). Collapsed: "Goa, 42 km, ETA 4:35 PM" and "Arjun 1.2 km ahead". Expanded: the ladder, status line and 3 large buttons |
| `adb shell dumpsys notification --noredact \| grep -A3 coroute` | one entry with id 1001 on channel coroute_convoy (if the plugin used another id or channel, two entries show: report it, see DEV_NATIVE.md "Plugin id and channel") |
| Dark mode on, then off | text readable on both shades; SOS red with white text; other buttons visible on both |
| Font size largest (Settings > Display) | lines cut with "...", nothing overlaps, buttons still 48 dp high |
| Move B 400 m | the distance changes within about 10 s, not more often |
| B stops for 5 min / turns data off for 3 min | "Stopped 5 min" / "No signal" next to B |
| B raises SOS | A's notification turns red at once: "EMERGENCY: <B> needs help" (or "may have met with an accident"), "4.8 km ahead, updated 10:42", button "Navigate to <B>" |
| Tap Wait for me on the lock screen (phone locked with a PIN) | no unlock asked; within about 10 s the status line says "You asked the group to wait"; B sees the wait request |
| Tap SOS on the lock screen (PIN set) | the hold-to-send SOS screen opens OVER the lock screen without the PIN; nothing is sent until the button is held; Cancel goes back to the lock screen and the app no longer shows over it |
| Tap Open map on the lock screen | Android asks to unlock, then the ride map opens |
| "Show ride on lock screen" on (default), phone set to "Hide sensitive content" | the full large notification still shows on the lock screen (the rider chose it); never phone numbers |
| "Show ride on lock screen" off, phone set to "Hide sensitive content" (or "Show sensitive content only when unlocked") | locked: "CoRoute ride active" only (during an emergency "Rider emergency nearby, open CoRoute"), no names, no distances |
| "Show ride on lock screen" off, phone set to "Show all content" | Android shows private notifications in full in this mode; note what the brand shows |
| "Large ride notification" off | the plain one-line notification comes back within 10 s and keeps updating |
| Android 14: swipe the notification away | it comes back within about 10 s (plain or large) |
| Turn the intercom microphone permission on during the ride (service restart) | after the restart the large notification is back within 3 s |
| Notifications for CoRoute turned off in system settings | ride continues; no crash; turning them on again shows the large one |

Brand quirks to note (not failures): MIUI may show custom layouts only after
"Notification shade > Use Android style"; some ColorOS versions crop the
expanded view at 3 riders; One UI may colour the background.

## 11. Spoken alerts (3.15)

Spoken through the phone's text-to-speech engine (no download by CoRoute),
Indian English when installed, else US or UK English. Settings > Ride safety >
Voice: "Speak emergency alerts" (on) and "Speak warnings and directions" (on,
also needs the group's voice guidance switch).

| Check | Expected |
|---|---|
| B raises SOS, A in a pocket with the screen off | A hears once: "Emergency. <B> may have met with an accident 4.8 kilometers behind you." Music on A ducks while it speaks and comes back |
| Same SOS again within 10 min (reconnect) | not spoken again |
| Bluetooth helmet intercom paired to A | the voice comes through the helmet like map directions; the CoRoute intercom continues afterwards |
| Settings > System > Languages: Hindi as the phone language, CoRoute language "System language" (3.16) | spoken in Hindi when the phone has a Hindi voice (Settings > Accessibility > Text-to-speech, Google engine, install the voice); without one, English |
| Text-to-speech engine disabled (Settings > Apps > Speech Services by Google > Disable) or a phone without one | no voice, no error, banners and notifications still show |
| "Speak emergency alerts" off | silent, banner still shows |
| Group voice guidance off | warnings and directions silent, emergencies still spoken |
| `adb logcat \| grep -i coroute` while speaking | no spoken text in the log |

## 12. Battery with the large notification (3.15)

Same as section 9 over 2 hours, screen off: "Large ride notification" on vs off.
Expected: no measurable difference (it redraws at most every 10 s from data the
app already has; no extra GPS or network). `adb shell dumpsys notification`
should show the CoRoute notification updated at most about 6 times a minute.

## 13. Fuel reminder (3.16)

Profile (or Ride safety) > "Tank range (km)": set 10 km for the test. Ride, or
use a mock-location app that moves the position along a road at 40 km/h.
Expected: at about 8 km since the ride started (or since the last "Filled up")
one prompt "Fuel soon" with "OK" and "Filled up", also as a notification when
the screen is off; never a second one for the same tank. "Filled up" (the
prompt, or the ride sheet row) restarts the count; so does arriving at a stop
of the category Fuel on the plan. Kill the app mid-ride and open it again: the
"km since last fill" row keeps its value. Range 0: no reminder.

## 14. Hard stops (3.16)

Ride above 25 km/h and brake firmly (from 60 to 30 within 3 s) three times, at
least 10 s apart; also ride over a pothole without braking. After the ride the
trip report shows "3 hard stops" with "Only you can see this." The pothole does
not count, nor does braking below 25 km/h. The count is on the phone only:
`adb logcat` and the server never see it. Another rider's report never shows yours.

## 15. Post-crash follow-up (3.16)

Trigger the crash alarm as in section 3 and tap "I'm OK". Ride on, then stop
for a minute: one prompt "Still okay? Anything hurt?" with "Yes, fine" and
"Need help" (also a notification with both buttons). "Yes, fine" writes "Kiran
said they are still OK" to the timeline; "Need help" raises an SOS. Without a
stop the prompt comes 20 min after "I'm OK". It comes once. The hidden
developer action (section 17) never asks it.

## 16. Night voice (3.16)

Ride after sunset with "Speak warnings and directions" OFF and "Speak more after
dark" ON (default). Expected: stopped-rider and separation alerts are spoken;
hazard directions are not. By day, with the same settings, nothing is spoken
except emergencies. With "Speak emergency alerts" OFF nothing is spoken at all.
The day/night switch comes from the ride's own fixes (no timer): `dumpsys
alarm` shows nothing new for CoRoute.

## 17. Wearable hook (3.16, developer action)

Ride safety sheet: tap the title 7 times while a ride is active. The row
"Developer: simulate wearable impact" opens the crash alarm (15 s, "Possible
accident detected") exactly like the sensor would. Let it time out once: the
server's alert shows source WEARABLE in the admin emergencies panel. Tap "I'm
OK" once: no follow-up prompt comes later (the simulation is not a real
impact). No Bluetooth permission is asked anywhere (it was removed in 3.16;
`adb shell dumpsys package space.devmonks.coroute_app | grep BLUETOOTH` prints nothing).

## 18. Weather and sunset lines (3.16)

Plan a route of 2 hours or more and open the review sheet. Expected: "Checking
weather..." then one line, for example "Rain likely after Warangal around 3 PM"
or "No rain expected on the route", with "Weather data by Open-Meteo.com"
underneath; the sunset line "You will reach the destination after dark (sunset
6:10 PM)" when the ETA passes sunset. Start the ride: the ride sheet shows the
rain line only while rain is expected, and "Dark in 40 min" within an hour of
sunset. Data saver on: "Weather check skipped (data saver)" and no request
(`adb logcat | grep weather` stays quiet; the gateway log shows no
`/api/geo/weather` call). Two requests per ride at most: review and start.

## 19. Route map saved on the phone (3.16)

Settings > "Save route maps on Wi-Fi" on. Plan a route, connect to Wi-Fi, start
the ride: the ride sheet shows "Saving route map: 240 of 600" then "Route map
saved" (about 12 MB for a long route; `du -sh` of the app's cache folder
`tiles` grows accordingly). On mobile data nothing is downloaded until the rider
taps "Save route map". Then switch to airplane mode and pan the ride map along
the route: tiles at the overview and the street zoom show without a network;
other areas show the empty tile. The cache keeps at most 60 MB and drops tiles
after 30 days; Android may clear it when space is short (nothing breaks, maps
load from the network again). `adb logcat | grep tile.openstreetmap` during the
prefetch: requests at least 150 ms apart with the CoRoute User-Agent.

## 20. Medical ID on the lock screen and Leave ride (3.16)

Profile: blood group, allergies and an emergency contact set. Ride safety:
"Show my medical ID on the lock screen during an SOS" OFF (default). Raise an
SOS, lock the phone: the lock screen shows "Your SOS is active" only. Switch
the setting on and raise an SOS again: the lock screen shows "Your SOS is
active. Blood group O+. Allergies: ... Emergency contact: Asha 98765 43210"
even with "Show ride on lock screen" off (with it off, the rest of the ride,
names and distances, stays hidden: only that line shows). Another rider's SOS
never shows your medical ID, and neither does a "Rider down here" report you
made about someone else. Lock-screen notification button "Leave ride": the app opens with a
confirm "Leave the ride?"; nothing happens until "Leave ride" is tapped there.

## 21. Hindi and Telugu (3.16)

Profile > Language > Hindi (then Telugu): crash alarm, SOS hold screen, incident
and assist sheets, hazard banner, safety settings, the crash notification and
the prompts (fuel, follow-up, check-in, break) show in that language; everything
else stays English. Spoken alerts use the Hindi or Telugu voice when the phone
has one (Settings > Accessibility > Text-to-speech output); otherwise they are
spoken in English. Change the language between rides: the next ride speaks in
the new language.

## What to send back

For each test: phone model, Android version, pass or fail, and for a failure what
the screen said. Do not paste phone numbers or the SMS text of other riders.
`adb logcat` from CoRoute never contains numbers or texts; if you see one,
report it as a bug.
