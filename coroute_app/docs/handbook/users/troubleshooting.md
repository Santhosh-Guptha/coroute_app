---
title: CoRoute troubleshooting
subtitle: Common problems, step-by-step fixes, and when to send diagnostics.
version: App 3.55 · November 2026
---

# CoRoute troubleshooting

> [!TIP]
> Start with **Profile ›** gear **› Safety health**. It checks location, notifications, microphone, Bluetooth, battery limits, full-screen alerts and sound, and each problem has a button that opens the right page.

**When to send diagnostics.** If a fix below does not help, go to **Profile › Help › Send feedback**, choose **Report a problem**, describe what happened (date, time, what you saw), turn on **Attach diagnostics log** and **You may reply by e-mail**, and send. The log has no messages, names, phone numbers or exact places. Send it as soon as you can: the phone keeps it for 7 days at most.

Menu names differ between Android versions and brands. If you cannot find a menu, search for it in your phone's Settings.

---

## 1. Location: "Allow all the time"

**Signs:** your group loses you when your screen is off; Safety health shows location as limited.

1. Open **Settings › Apps › CoRoute › Permissions › Location**.
2. Choose **Allow all the time**.
3. Turn on **Use precise location**.
4. Make sure the phone's location (GPS) is on.

**Send diagnostics if** the group still loses you with the screen off after this and section 2.

## 2. Battery optimisation (your phone closes CoRoute)

**Signs:** the ride stops after some minutes with the screen off; alerts arrive late or only when you open the app; the ride notification disappears.

On every phone: **Settings › Apps › CoRoute › Battery › Unrestricted** (or "Don't optimise"). In Safety health, tap **Battery settings** or **Allow**. Then follow the steps for your brand:

| Brand | Steps |
|---|---|
| **Xiaomi / Redmi / POCO** (MIUI, HyperOS) | Settings › Apps › Manage apps › CoRoute: **Autostart** on; **Battery saver › No restrictions**. In Recent apps, pull CoRoute down or long-press and tap the **lock** icon. |
| **Samsung** (One UI) | Settings › Apps › CoRoute › Battery › **Unrestricted**. Settings › Battery › Background usage limits: make sure CoRoute is **not** in "Sleeping apps" or "Deep sleeping apps"; add it to **Never sleeping apps**. |
| **OnePlus** (OxygenOS) | Settings › Apps › CoRoute › Battery usage: **Allow background activity** on, optimisation **Don't optimise**. Lock CoRoute in Recent apps. |
| **Vivo / iQOO** (Funtouch, OriginOS) | Settings › Battery › Background power consumption management › CoRoute: **Allow high background power consumption** (or "Don't restrict"). Settings › Apps › Autostart: CoRoute on. Lock it in Recent apps. |
| **Oppo** (ColorOS) | Settings › Apps › CoRoute › Battery usage: **Allow background activity**, **Allow auto launch**. Lock CoRoute in Recent apps. |
| **Realme** (Realme UI) | Settings › Apps › CoRoute › Battery usage: **Allow background activity** and **Allow auto launch** on. Turn off any "optimise" option for CoRoute. Lock it in Recent apps. |
| **Google Pixel / Motorola / Nokia** | Settings › Apps › CoRoute › App battery usage › **Unrestricted**. |

Also: do not swipe CoRoute away during a ride, and avoid "ultra" or "extreme" power saving modes while riding.

**Send diagnostics if** CoRoute still stops during rides.

## 3. Notifications blocked

**Signs:** no ride notification, no crash countdown sound, friend requests or ride invitations do not arrive.

1. In **Safety health**, tap **Allow** next to notifications. If you blocked them before, it opens CoRoute's notification page.
2. Or open **Settings › Apps › CoRoute › Notifications** and turn them on, including the channels **SOS**, **Critical ride alerts**, **Friends** and **Ride invites**.
3. For friend and crew messages when CoRoute is closed, check **Settings › Push notifications** in CoRoute is on.
4. To hear critical alerts in Do Not Disturb: phone **Settings › Notifications › Do Not Disturb › Apps**, add CoRoute.
5. Android 14+: allow **full-screen alerts** for CoRoute (Safety health › **Open settings**) so the crash countdown shows over the lock screen.

## 4. Bluetooth headset audio

**Signs:** voice alerts or the group play on the phone speaker instead of the helmet.

1. Connect the headset **before** starting the ride and check it plays media (music) from the phone.
2. Allow **Nearby devices** for CoRoute: **Settings › Apps › CoRoute › Permissions**.
3. Raise the media volume on the phone and on the headset.
4. Some helmet sets connect for calls only. Turn on **Media audio** for the headset in the phone's Bluetooth settings (tap the gear next to it). With a calls-only connection, emergency lines play on the phone speaker.
5. Disconnect other Bluetooth audio devices (car, speaker, smartwatch audio).

**Send diagnostics if** alerts still play on the wrong device.

## 5. Intercom: the group cannot hear me, or I cannot hear them

1. Check the microphone permission: **Settings › Apps › CoRoute › Permissions › Microphone › Allow**.
2. Check you are not muted: the ride notification shows **Group voice muted** when you are. Tap **Unmute**.
3. **Hold to talk:** hold the button for the whole sentence. **Hands-free:** speak clearly; very quiet speech may not open the mic.
4. During a phone call, group talk pauses ("Voice paused (call)") and comes back after.
5. Check mobile data. Talk needs a connection; in poor signal voice can break up.
6. If only one rider is not heard, ask them to check these steps.
7. If talk is missing entirely in this ride, the ride may not include group talk: the app says "This isn't included in this ride."

**Send diagnostics if** talk keeps dropping with good signal (send from both phones if possible).

## 6. Alerts are late or missing

1. Run **Safety health** and fix anything it shows, especially battery (section 2).
2. Check **Settings › Voice alerts** is on. Emergencies are always spoken.
3. Check the phone's media volume. Critical alerts sound anyway; ordinary ones follow your volume.
4. Install or update your phone's text-to-speech engine (Google Speech Services) and the voice for your chosen language.
5. Keep the phone in a mount, with GPS working (alerts depend on fresh GPS).
6. Speed warnings use the true GPS speed. Bike speedometers read a few km/h high by law, so the app showing a little less than your speedometer is normal.

**Send diagnostics if** an alert came clearly late: say which alert, roughly when, and where you were.

## 7. Siren alerts do not work

1. Check **Settings › Siren alerts** is on.
2. Allow the microphone. If it is missing, CoRoute says: "Siren alerts need the microphone. Allow it for CoRoute in phone settings to use them."
3. Siren alerts work only during a ride.
4. Put the phone in a mount or tank bag. In a pocket at speed, wind and clothing can hide the siren.
5. Music on the phone's own speaker pauses detection. Use earbuds or a headset.
6. Below 15 % battery, detection pauses to save power.
7. The alert comes about 3 seconds after the siren starts. Short chirps do not alert.

## 8. Too many crash alarms (false alarms)

1. Use a firm **handlebar mount**. A loose phone in a bag or pocket is the most common cause.
2. Always tap **I'm OK** when you are fine: CoRoute learns from it for your bike.
3. If you simply ride on, the alarm cancels itself.
4. Do not hold the phone loosely while riding.

**Send diagnostics after any false alarm.** CoRoute may ask "send the log of this ride?" after the ride: tap to send.

## 9. SOS text (SMS) not sent

1. Open **Safety health** and look at **Emergency texts**. "Not allowed": tap **Allow** and allow texts. Until then CoRoute opens your messages app with the text ready: tap **Send**, or **Text the group now** on the SOS screen (it asks you to unlock first when the phone is locked).
2. "No SIM is ready": insert a SIM or turn off airplane mode. With two SIMs, set a default SIM for SMS in the phone's settings (otherwise the phone picks one or may ask).
3. No signal: the SOS screen says "No signal yet". The phone tries again by itself (30 s, 2, 5 and 10 minutes, and as soon as the network returns), also with the screen locked or after the app was closed.
4. Check your SIM credit / SMS pack and that your emergency contact's number is correct (**Profile › Emergency contact & Medical ID**). Tap **Send a test text to my emergency contact** in Safety health.
5. Cancelled the SOS within 10 seconds of pressing it? Then nothing was sent, on purpose.
6. More than 30 emergency texts in a day: the daily limit stops further texts until the next day.

**Send diagnostics** after any real or test SOS where texts did not go out.

## 10. Map search finds nothing

1. Check your internet connection. CoRoute shows the reason and a **Retry** button.
2. "Too many searches": wait a minute and try again.
3. "No matching places found in India": tap **Search everywhere**, or try a shorter name or a nearby town.
4. Paste a Google Maps link instead, or share the place from Google Maps to CoRoute (**Plan a ride in CoRoute**).
5. "Signed out": sign in again.

## 11. Friend requests do not arrive

1. Check the username is exact. A request to a name that does not exist is refused, so ask your friend to read theirs from **My profile**.
2. Look under **People › Requests** (and pull to refresh).
3. If someone blocked you, or you blocked them, requests do not get through. Check your blocked list.
4. There is a daily limit of 20 requests and 50 waiting.
5. For notices when CoRoute is closed, check **Settings › Push notifications** and the phone's notification settings (section 3).
6. Invite links: tap the link on the phone that has CoRoute installed. If it opens the website instead, install or update CoRoute, then tap the link again.

**Send diagnostics if** a request was sent but never appears.

## 12. Other common issues

| Problem | Fix |
|---|---|
| "Add your safety details" when joining | Add your phone number and an emergency contact in **Profile › Emergency contact & Medical ID**. |
| "Complete your bike" keeps showing | Fill in make and model, bike type and colour, plus engine, tank and mileage for a fuel bike. Riding on someone else's bike? Choose **I'm riding pillion (no bike)**. |
| "No active ride found for this code." | Check the code with the trip owner. The ride may have ended. |
| "This ride is full." | The ride has reached its rider limit. Ask the trip owner. |
| "Reconnecting to your ride…" | No signal yet. Your group sees you again as soon as the phone reconnects. |
| Wrong language | **Settings › Language**. Safety screens and spoken alerts are in English, Hindi or Telugu; other screens are in English. |
| Screen dims while riding | Battery saver may dim the screen. Charge the phone or turn **Battery saver** off. |
