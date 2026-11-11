# CoRoute handbook: users and support

Documentation for riders and for the support team. It describes the CoRoute Android app **3.55** as built on 11 November 2026 (minimal Profile and Settings, safety always on, automatic offline maps). Other packs: `../investors/`, `../operators/`, `../technical/`.

## Rider-facing

| File | What it is | PDF |
|---|---|---|
| [quick_start.md](quick_start.md) | 2 pages: install, sign in, permissions and why, emergency contact and Medical ID, add a bike, solo ride, create or join a group ride | [quick_start.pdf](quick_start.pdf) |
| [user_guide.md](user_guide.md) | The full guide, by area: Safety, Group riding, Talk, Navigation and maps, Community, Trips and score, Notifications, Settings, Your data. Replaces the earlier `docs/manuals/CoRoute_User_Manual_v3.55.pdf` | [user_guide.pdf](user_guide.pdf) |
| [safety_guide.md](safety_guide.md) | How SOS, crash detection, "Bike down?", "Are you OK?" checks, siren alerts, SMS fallback, Ride Guardian and nearby help work; what to do in an emergency; phone placement; honest limits | [safety_guide.pdf](safety_guide.pdf) |
| [faq.md](faq.md) | 50 questions and answers | [faq.pdf](faq.pdf) |
| [troubleshooting.md](troubleshooting.md) | Common problems with steps (incl. battery settings per phone brand) and when to send diagnostics | [troubleshooting.pdf](troubleshooting.pdf) |
| [privacy_summary_for_riders.md](privacy_summary_for_riders.md) | Plain-language privacy summary | [privacy_summary_for_riders.pdf](privacy_summary_for_riders.pdf) |
| [community_guidelines.md](community_guidelines.md) | Rules for chat, reviews, crews and photos; reporting; consequences | [community_guidelines.pdf](community_guidelines.pdf) |
| [release_notes_v3.55_users.md](release_notes_v3.55_users.md) | Play "What's new" (432 characters) and a longer blog version | [release_notes_v3.55_users.pdf](release_notes_v3.55_users.pdf) |

## Internal

| File | What it is |
|---|---|
| [support_playbook.md](support_playbook.md) | Support workflow, severity levels (safety = P0), 30 canned replies, reading diagnostics logs with `tool/diag/analyze_logs.js`, escalation, deletion and data requests, website refunds, moderation, and a list of public texts that no longer match the app |
| [translations_needed.md](translations_needed.md) | Strings and documents to translate to Hindi and Telugu, then Tamil, Kannada, Malayalam and Marathi |

## Rules these docs follow

- Exact UI names from `docs/UX_NAMING_GUIDE_v3.55.md` and the app source (`lib/presentation/...`).
- The app shows **no prices or plans**. Rider docs never tell riders to buy anything in the app. Where hosting limits come up they say only: "Group hosting is managed in your CoRoute account on the website." Access modes may make hosting free for everyone. Solo riding, joining group rides and every safety feature are free.
- No invented numbers. Figures used (3 s SOS hold, 30 s countdown, 7-day map retention, 300 MB, 90-day route deletion, and so on) come from `docs/FEATURE_STATUS.md`, `docs/SETTINGS_MINIMAL_v3.55.md`, `docs/features_355/*` and the app source.
- Honest limits: crash detection cannot catch everything, a phone in a pocket may miss sirens, everything needs battery and permissions.
- Calm palette in the PDFs: teal `#2B7A8C`, amber `#D9822B`.

## Images

`assets/` holds the Play Store illustrations (`store/out/play_assets/phone/`, downsized) and three mock-ups rendered from `docs/manuals/source/mock/html/` (missing-rider check, lock screen, moving chip). They are marked as illustrations: some wording differs slightly from the app (for example the store crash image says "Possible crash" where the app says "Possible accident detected"). Replace with real screenshots after the device pass.

## Rebuilding the PDFs

```
python3 docs/handbook/users/_build/build.py            # all rider-facing PDFs
python3 docs/handbook/users/_build/build.py faq        # one document
```

Uses python-markdown and the pre-installed Playwright + Chromium (do not reinstall). Fonts: Manrope (`_build/fonts`). Intermediate HTML goes to `_build/html/`.

## Open items for the owner

- **[OWNER TO FILL]** in `support_playbook.md`: support mailbox, on-call rota, P0 channel, deletion/export procedures and timelines, refund policy and bank timelines, legal contact.
- **Public texts out of date** (listed in `support_playbook.md` §11): `privacy.html` and `terms.html` still say crash detection, emergency texts and nearby help can be switched off, the Medical ID lock screen is opt-in, diagnostics live in Settings, deletion is under "Account & security", plans are managed in the app, and the trip head is the on-road lead. The privacy summary here follows the current app.
- The app crash-detection start speed (home screen: about 12 km/h) differs from `privacy.html` (25 km/h). The docs use 12 km/h.
- Server SOS texts depend on the SMS provider and DLT setup; the docs say "where text alerts are available".
- Real screenshots after the device pass.
