# Background-location video for Google Play (30–60 s)

Google needs **real footage of the real app**. A mock-up or animation can get the declaration rejected,
so record it on a phone with the Play build installed. These files make that a 10-minute job.

## What the video must show (in this order)

| Time | Shot | On screen | Caption (added by `make_video`) |
|---|---|---|---|
| 0–8 s | 1. Open the app, tap **Start ride** | Home → Start ride | 1. Open CoRoute and start a ride |
| 8–20 s | 2. In-app prominent disclosure | "Location in the background" screen with the full text: *CoRoute collects your location to share your live position with your riding group and to send it with an SOS or crash alert, even when the app is closed or not in use. Only during an active ride.* → tap **Continue** | 2. In-app notice before asking |
| 20–32 s | 3. Android permission dialog | First "While using the app", then the settings page → select **Allow all the time** → back | 3. Choose "Allow all the time" |
| 32–55 s | 4. Lock the phone while riding | Press power, lock screen shows the CoRoute ride notification (speed / distance updating); unlock → cockpit map shows the position kept moving | 4. Phone locked: tracking continues |

Keep it under 60 s. No prices, no other apps, no personal data (use a test account and test contacts).

## Record

1. Install the Play build (Internal testing) on an Android 13+ phone, sign in with the **reviewer test account**.
2. Plug in the phone (USB debugging on). On Windows run `record.ps1`, on Linux/macOS `record.sh`.
   It resets CoRoute's location permission (so the dialogs appear again), shows taps, and records the 4 shots one by one
   (press Enter to start/stop each shot). For shot 4, walk or ride a few hundred metres (or use a mock-location app
   *only if it doesn't show in the frame*) so the position visibly moves.
3. It pulls `shot1.mp4 … shot4.mp4` to this folder.

## Make the final video

`make_video.ps1` / `make_video.sh` (needs ffmpeg) trims each shot to its slot, adds the captions above at the bottom,
joins them and writes `coroute_background_location.mp4` (1080p max, ≤ 60 s, silent).

## Upload

YouTube → Create → Upload video → title "CoRoute – background location use" → Visibility **Unlisted** → copy the link.
Play Console → Policy → App content → Location permissions → paste the link, and use this description:

> CoRoute is a motorcycle group-riding safety app. During an active ride it uses location in the background so the
> group can see each rider's live position on the map, warn when a rider falls behind, and send the rider's location
> with an SOS or automatic crash alert, even when the phone is locked in a tank bag or pocket. Background location is
> used only while a ride is active and stops when the ride ends. The app shows a prominent disclosure before asking
> for the permission.
