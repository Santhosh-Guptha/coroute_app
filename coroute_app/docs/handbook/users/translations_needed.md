# Translations needed (users and support pack)

Internal list for the owner and the translation vendor. App 3.55, November 2026.

## Where things stand

- The app translates **safety screens and spoken alerts only** into **Hindi (hi)** and **Telugu (te)**. Every other screen is English (decision from 3.16). Settings › Language offers System, English, Hindi, Telugu.
- Tables: `lib/core/l10n/strings_core.dart` (41 keys), `strings_safety.dart` (34), `strings_screens.dart` (114): **189 keys**, each present in en, hi and te.
- Several 3.55 safety lines are **English only** today (they are not in the tables): siren alerts, the missing-rider check, "Bike down?", pillion notices, ride chat spoken lines, call summaries, Safety health.
- Planned next (v3.56 plan, item L1): **Tamil (ta), Kannada (kn), Malayalam (ml), Marathi (mr)** for the same scope, with TTS tags `ta-IN`, `kn-IN`, `ml-IN`, `mr-IN`.
- Rule for every language: a professional translator **plus one rider-reviewer** for road words (speed breaker, ghat, pillion, sweeper). Keep "SOS" as is. Check that spoken emergency lines stay short enough for the alarm timing.

Priority: **P1** = safety, needed before a language is offered; **P2** = important for understanding; **P3** = nice to have.

## A. App strings to add to the tables (all languages)

### P1: spoken safety lines (English only today)

| Area | English source (exact) | Notes |
|---|---|---|
| Siren close (×4 kinds) | "Ambulance siren close by. Keep left and give way." / "Police siren close by. …" / "Fire engine siren close by. …" / "Emergency vehicle siren close by. Keep left and give way." | Also "Keep right" variants for right-hand traffic. Never translate as "behind". Pre-synthesised at ride start: 16 lines per language |
| Siren approaching | "Ambulance approaching. Keep left and give way." (+ Police / Fire engine / Emergency vehicle) | |
| Siren closer | "Ambulance getting closer. Keep left and give way." (+ kinds) | |
| Siren far | "Ambulance siren in the distance." (+ kinds) | |
| Siren card | "AMBULANCE SIREN · GIVE WAY", "EMERGENCY VEHICLE SIREN · GIVE WAY", Approaching / Moving away / Close / Far | Upper case only in scripts that have it |
| Mic missing | "Siren alerts need the microphone. Allow it for CoRoute in phone settings to use them." | |
| Overspeed | "Slow down. 95 km/h, limit 65." | Numbers spoken in the language |
| Missing-rider check | "Are you OK? The group is moving on"; "I'm OK", "Need help", "Waiting for fuel", "Photo stop", "Taking a break", "Send SOS · hold to send", "Keep holding…", "Need help asks the group to wait. For an emergency, hold Send SOS.", "Your lead was told" | Card and spoken line |
| Bike down | "Bike down?" title; "Crash alarm cancelled. You are riding." | Countdown texts already exist (`crash.*`) |
| Crash off mid-countdown | "Crash detection is off for new alarms. This alarm is still running: tap I'm OK to cancel it." | Rare, keep anyway |
| Calls | "Safety alert during your call: …", "And 2 more safety alerts.", "While you were on the call: 2 road warnings, Asha fell behind." | Plural rules per language |
| Battery reserve | "Battery saver for SOS is on" | |
| Mount check | "Phone not in a mount? Crash detection works best with the phone in a handlebar mount." | |
| Solo ETA check-in | "Are you OK? Tap I am fine on the screen.", "I'm fine", "Add 30 min" | And the SMS texts to the contact: keep the link and time format |
| SOS SMS (phone) | "CoRoute SOS: {name} needs help at {time}. Live: {url} Lat {lat} Lng {lng}" | Must fit one SMS part; Indic scripts use UCS-2 (70 characters per part), so test length. Server SMS templates are DLT-registered in English: do not translate without new DLT registration |

### P2: safety screens and settings rows

- Settings: "Safety is always on" and its 14 list items (two already exist: `settings.help`, `settings.ask`), "Safety health" / "Check your phone is ready", "Siren alerts" + subtitle "Listens on your phone during rides. Nothing is recorded.", "Voice alerts" / "Emergencies are always spoken", "Battery saver" / "Turns on by itself when low", "Data saver", "Speed warning", "Emergency contact & Medical ID", "More settings", "Pause music for alerts" / "Off: music only gets quieter", "Lower music when speeding", "Navigation app", "Chat quick replies".
- Safety health fix buttons: "Allow", "Battery settings", "Sound settings", "Show steps", "Open settings".
- Ride notification: "Talking", "Receiving {name}", "Group voice muted", "Hands-free on", "Voice paused (call)", buttons "Talk" / "Talk off", "Mute" / "Unmute", "Leave".
- Pillion: "I'm riding pillion (no bike)", "Whose bike are you on?", "Kiran is riding pillion with Asha.", "You're riding pillion with Asha", "Hold on. Your phone keeps its safety features on.", decline / remove texts (UX_NAMING_GUIDE §2c).
- Ride chat quick replies: Fuel, Break, Wait for me, I'm OK, Slow down, Regroup here, On my way, Arrived; spoken "Kiran: fuel stop", "Kiran says: …", "Kiran sent a message"; "Riding: one-tap replies only. Stop to type."
- Off-route: "You left the group's route", "Route to group", "Ask group to wait", "Keep my own route", "You're off the route. Stop when safe to route to your group."
- Guardian sheet: Basic / Live / Emergency only descriptions, "Share it now. The link cannot be shown again later."

### P3: rest of the app

Profile (My bikes, Leaderboard, Help, Send feedback, Rate CoRoute, Privacy & terms, Account, Sign out, Delete account), People, crews and polls, rider score levels (Learner, Steady, Skilled, Ace Rider), trip report, garage, map search. Requires the larger "all screens" decision (owner item D15): not in the current scope.

## B. Documents to translate

| Document | hi | te | ta / kn / ml / mr | Priority | Notes |
|---|---|---|---|---|---|
| `safety_guide.md` / `.pdf` | Yes | Yes | With L1 | **P1** | Emergency section (§1) and limits (§11) must be reviewed by a rider-reviewer |
| `quick_start.md` / `.pdf` | Yes | Yes | With L1 | **P1** | Keep UI names in English in **bold** with the translation in brackets while the screens stay English |
| `privacy_summary_for_riders.md` | Yes | Yes | With L1 | **P1** | Needs legal review in each language; the English privacy policy remains the binding text |
| `community_guidelines.md` | Yes | Yes | With L1 | P2 | |
| `faq.md` | Yes | Yes | Later | P2 | |
| `troubleshooting.md` | Yes | Yes | Later | P2 | Phone menu names: use the names the phone shows in that language (check on a real phone set to that language) |
| `release_notes_v3.55_users.md` (Play "What's new") | Yes | Yes | With L1 | P2 | Play Console has per-language "What's new"; 500 characters each |
| `user_guide.md` / `.pdf` | Yes | Yes | Later | P3 | Large; translate after the safety guide |
| Play Store listing (`store/out/play_assets/listing_text.md`) | Yes | Yes | With L1 | P2 | Play listing policy applies in every language: no prices, offers or rankings |
| Website: home, safety, privacy-and-security, delete-account | Yes | Yes | Later | P2 | Owned by the website work |
| Support canned replies (`support_playbook.md` §6) | Yes | Yes | Later | P2 | Support staff reply in the rider's language where possible |
| `support_playbook.md` (rest), `translations_needed.md` | No | No | No | — | Internal |

## C. Glossary to fix first (per language)

Agree one translation for each term before any other work, and reuse it everywhere: SOS (keep), crash detection, "Are you OK?", I'm OK, Need help, emergency contact, Medical ID, group ride, trip owner, trip head, Lead, Middle, Sweeper, pillion, regroup, speed breaker, pothole, rough road, siren, give way, guardian link, crew, poll, username, rider score, safety health, hands-free, hold to talk.

## D. Checks after translation

- Every key present in every language (add a key-coverage test).
- Text-to-speech voice present on budget phones; if missing, English speech with the screen in the chosen language.
- Indic glyphs render (Manrope has none; the system Noto fallback must cover all scripts) in cards and the ride notification.
- Long strings do not overflow at 360 dp width; spoken P0 lines stay short.
- SOS SMS stays within one part where possible.
