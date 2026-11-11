# CoRoute Handbook: Tour Operators, Clubs and Partners

Documentation pack for organisations that run group rides on CoRoute (tour operators, riding clubs, rental fleets, corporate fleets) and for real-world partners. It describes **CoRoute 3.56** as built. Items not built yet are marked **Planned** (from `docs/NEXT_RELEASE_PLAN_v3.56.md`). Legal documents are **DRAFTS for legal review**. Values to be decided by the owner are marked **[OWNER TO FILL]**.

## Contents

| # | Document | Audience | Files |
|---|---|---|---|
| 1 | **Operator overview**: what CoRoute gives operators, benefits, limits and pricing model, how to apply | Prospective operators | [operator_overview.md](operator_overview.md) · PDF |
| 2 | **Onboarding guide**: apply → approval → console → roster → co-organisers → ride → ride day → after the ride, with screenshots | New operators | [operator_onboarding_guide.md](operator_onboarding_guide.md) · PDF |
| 3 | **Ride organiser SOP**: briefing checklist, during the ride, emergency procedure, post-ride | Operators, leads, sweepers | [ride_organiser_sop.md](ride_organiser_sop.md) · PDF |
| 4 | **Safety briefing template**: printable one-page sheet | Leads at the meeting point | [safety_briefing_template.md](safety_briefing_template.md) · PDF |
| 5 | **Rider consent and waiver (DRAFT)**: template for operators, including the data shared during an SOS only | Operators + their lawyers | [rider_consent_and_waiver_DRAFT.md](rider_consent_and_waiver_DRAFT.md) · PDF |
| 6 | **Operator console manual**: every screen, button, limit and error message, privacy rules, audit | Operators, support staff | [operator_console_manual.md](operator_console_manual.md) · PDF |
| 7 | **Partner program**: partner perks, Play-safe rules, listing, co-marketing, brand rules | Partners, operators | [partner_program.md](partner_program.md) · PDF |
| 8 | **Operator terms (DRAFT)** | CoRoute legal, operators | [operator_terms_DRAFT.md](operator_terms_DRAFT.md) · PDF |
| 9 | **Data processing note (DRAFT)**: the operator as data recipient during an SOS, obligations, DPDP Act points | CoRoute legal, operators | [data_processing_note_DRAFT.md](data_processing_note_DRAFT.md) · PDF |
| 10 | **Operator FAQ** | Operators | [operator_faq.md](operator_faq.md) · PDF |
| 11 | **Support and escalation**: contact, response targets, emergency path (112 first) | Operators | [support_escalation.md](support_escalation.md) · PDF |

Each Markdown file has a PDF with the same name in this folder. The screenshots used in the onboarding guide are in `img/`. They come from the Playwright smoke run of the console (`tool/operators_smoke.js`) against a test-mode gateway and contain test data only.

## Sources
- `docs/features_355/operators.md`: the operator and club console as built (3.56).
- `gateway/public/operator/*`, `gateway/src/operator_routes.js`, `gateway/src/operators.js`, and the website pages `operators_apply.html`, `clubs.html`, `ride_public.html`: exact labels, flows and messages.
- `docs/features_355/`:
  - `access_modes.md`, `crews_polls.md`, `ride_chat.md`, `sensor_safety.md`, `group_safety.md`, `sos_sms.md`, `solo_guardian.md`: the app safety features referenced in the SOP;
  - `notifications_admin.md`, `marketing_board.md`, `play_payments_policy.md`: partner perks, Play-safe rules, the board and offer e-mails.
- `docs/SAFETY_SCENARIO_REVIEW_v3.55.md`, `docs/COMPETITOR_ANALYSIS_2026-11.md`, `docs/NEXT_RELEASE_PLAN_v3.56.md`: context and the Planned items.

## Known gaps to resolve before external use
1. **[OWNER TO FILL]** values: prices, support contacts, response targets, partner terms, brand pack link, legal entity name.
2. **Consent wording.** Fixed 11 Nov 2026: the `/clubs/join/<code>` card and the public ride page `/rides/<slug>` now also say "Your organiser sees your emergency contact only if you raise an SOS during their ride." and link to the privacy policy. An in-app consent screen at join ("This ride is run by …") is not built. See the data processing note, section 4.
3. **Privacy policy.** Updated 11 Nov 2026: `privacy.html` has a "Clubs and tour operators" section (organisers see an emergency contact only during that member's open SOS), DPDP rights and a Grievance Officer section; `terms.html` has a clubs and tour operators section. Legal review pending; the operator terms are not yet linked from the public terms.
4. Legal review of the three DRAFT documents.

## Rebuilding the PDFs
The PDFs were rendered from these Markdown files with Python-Markdown and Playwright (Chromium), using the calm brand palette (teal #2B7A8C, amber #D9822B). The render script lives outside the repository (in the session scratchpad). To rebuild, render each `.md` to HTML with a print stylesheet and print it to A4 with Chromium.
