# CoRoute pitch deck outline (13 slides)

For the founders building the deck. Each slide has a headline, talking points and the visual to show. **No invented numbers:** every figure below is either cited (source in the speaker notes) or a placeholder marked **[OWNER TO FILL]**. Screens are in `assets/screens/` (copies of the Play listing graphics in `/home/claude/store/out/play_assets/phone/`); the feature graphic and icon are in `assets/`.

Style: calm brand palette (teal #2B7A8C, amber #D9822B, warm off-white #F6F4F0, charcoal text #1F2328), Manrope. One idea per slide, no more than about 25 words of body text. Red (#D93A2F) is for SOS and crash only.

---

### 1. Title

- **Headline:** CoRoute: ride together, come home safe.
- **Talking points:** The safety and coordination app for India's motorcycle riders, solo and in groups. Pre-launch, Android first.
- **Visual:** Feature graphic (`assets/feature_graphic.jpg`) full-bleed; logo; website coroute.devmonks.space; presenter name **[OWNER TO FILL]**.

### 2. The problem

- **Headline:** Two-wheeler riders are 44.8 % of India's road deaths.
- **Talking points:**
  - 1,72,890 road deaths in India in 2023; 44.8 % were two-wheeler riders, the highest of any group (MoRTH 2023, reported Aug 2025).
  - A solo crash depends on a passer-by. Dead zones on ghats and highways stop calls.
  - Riders in ANC earbuds and helmet sets often can't hear an ambulance.
- **Visual:** One large number (44.8 %), with the source line. A quiet highway photo **[OWNER TO SOURCE, licensed image]**.

### 3. How groups ride today

- **Headline:** Group rides run on WhatsApp, which has no safety layer.
- **Talking points:** Live location expires and shows separate bubbles; no roles, no fall-behind alert, no SOS, no crash detection, no voice while riding; nothing without data. Calls at speed are unsafe.
- **Visual:** Side by side: a WhatsApp chat with scattered location bubbles (mock-up, no real people) vs the CoRoute group map (`phone_01_ride_together.jpg`).

### 4. The solution

- **Headline:** The phone you already carry becomes a crash detector, an SOS beacon and a group radio.
- **Talking points:** No hardware. Safety free for every rider. One live map for the group.
- **Visual:** Three phones: `phone_01_ride_together`, `phone_03_crash`, `phone_04_intercom`.

### 5. What only CoRoute does

- **Headline:** Four things no competitor we found combines.
- **Talking points:**
  1. Crash detection with a 30 s "Are you OK?" check and false-alarm suppression.
  2. SOS without signal: text from the phone, text from the server, phone-to-phone relay.
  3. Siren alerts in your earbuds, even with noise cancelling on.
  4. Live hands-free intercom with wind and breath cleanup.
- **Visual:** 2 × 2 grid of icons with one-line captions; `phone_06_sirens.jpg` as the hero. Footnote: "Desk research of Indian and international riding apps, Nov 2026."

### 6. Trust and privacy

- **Headline:** Safety is free. Always. And your data is yours.
- **Talking points:** SOS, crash alerts, guardians and medical ID are never gated, in any plan or mode. Encrypted in transit; no ads; no trackers; no sale of data; routes deleted after 90 days. Family follow by browser link, no app needed.
- **Visual:** `phone_09_guardians.jpg` plus four short privacy badges.

### 7. Product depth (built)

- **Headline:** Built, tested, ready for real roads.
- **Talking points:** v3.55 code-complete; 66 admin feature switches (safety core locked on); 904 / 904 server tests at the last full run (Nov 2026); two-node failover on Oracle Cloud; web admin, operator console and website payments (3.56). Honest line: real-device validation and Play launch are next.
- **Visual:** Simple architecture strip (phone → gateway live node ⇄ web node → database) and a row of four small screens (`phone_05_group`, `phone_07_people`, `phone_08_trip_report`, `phone_10_light_dark`).

### 8. Market

- **Headline:** A large and growing base of riders with smartphones.
- **Talking points:**
  - 19.61 M two-wheelers and 12.25 M motorcycles dispatched in India in FY2025 (SIAM via Autocar Professional).
  - Royal Enfield sold over 1 M motorcycles in FY2025; One Ride 2025 drew 150,000+ riders.
  - 85.5 % of households own a smartphone (MoSPI CMS Telecom 2025).
  - TAM / SAM / SOM: **[OWNER TO FILL]**, using the method in the investor memo (section 5). Do not show a TAM number until its inputs are sourced.
- **Visual:** Three stat tiles with sources, and a TAM → SAM → SOM funnel with placeholder labels.

### 9. Competition

- **Headline:** Others help you plan and chat. CoRoute keeps you safe on the ride.
- **Talking points:** Trilyt, Asteride, RideClan, MileVoy, Riding Verse are free and lead on community, planning or navigation. None we found combines crash detection, offline SOS, siren alerts and live voice. Hardware intercoms coexist. WhatsApp is the real default.
- **Visual:** Feature matrix (rows: crash detection, offline SOS, siren alerts, live intercom, guardian link, no ads/trackers; columns: CoRoute, Trilyt, Asteride, MileVoy, WhatsApp). Use only facts from `docs/COMPETITOR_ANALYSIS_2026-11.md`; "not stated" where a listing does not say.

### 10. Business model

- **Headline:** Free safety builds trust. Groups and clubs pay for coordination.
- **Talking points:**
  - Host plans: one member pays, everyone joins free. Bought on the website only (Google Play policy).
  - Access modes switch the product between Paid, Free for everyone and Free up to limits without an app update.
  - Operators and clubs: approved B2B console with limits per operator.
  - Later: partner perks, insurance safe-rider certificate, fleet safety.
  - Prices: current default config Small Group ₹49 / 30 days, Large Group ₹99 / 30 days; launch prices **[OWNER TO FILL]**.
- **Visual:** Three columns (Riders: free · Hosts: plan · Operators: console), with the future lines greyed.

### 11. Go-to-market

- **Headline:** Riders bring riders.
- **Talking points:** Clubs first (one host brings 5–11 riders); dealer and community-ride partnerships; WhatsApp-native invite and guardian links; Play listing that leads on safety; short demo reels (siren alert, crash countdown, offline SOS). City order and partner clubs **[OWNER TO FILL]**.
- **Visual:** A loop diagram: host invites → riders join free → guardians see the link → riders become hosts → clubs onboard.

### 12. Roadmap and milestones

- **Headline:** From launch to platform in three steps.
- **Talking points:** Launch gates (device validation, Play launch, baselines) → v3.56.0 quick safety wins (112 fallback, helmet button, route weather alerts, more Indian languages) → v3.56.x growth (ride planner, referrals, watch, events, offline voice) → v3.57 business (partners, insurance certificate, fleet pilot). Dates **[OWNER TO FILL]**.
- **Visual:** Horizontal timeline with three milestones; no dates until the owner sets them.

### 13. Team and the ask

- **Headline:** **[OWNER TO FILL]**
- **Talking points:** Founders and key hires (name, role, relevant experience); amount and instrument; use of funds by bucket; the measurable 12-month milestones the round buys. Traction slide only once there is real data (see `traction_and_kpis.md`).
- **Visual:** Team photos (with consent); a use-of-funds bar; milestone list. Contact details.

---

### Optional appendix slides

- **A. Safety engineering:** crash false-alarm scenario table (synthetic results, clearly labelled), siren detection lab results, offline SOS paths diagram.
- **B. Architecture and cost drivers:** two-node HA, cost per rider drivers (VMs, SMS per SOS, e-mail, payment fees; push is free).
- **C. Compliance:** Play payments policy approach, DPDP plan, terms disclaimer.
- **D. Metrics we will report:** the KPI list from `traction_and_kpis.md` (definitions, no numbers until live).

### Speaker-note sources

- MoRTH 2023 figures: https://www.dtnext.in/news/national/172-lakh-people-died-in-480-lakh-road-accidents-in-2023-road-ministry-report-844831 (28 Aug 2025)
- SIAM FY2025: https://www.autocarpro.in/analysis/fy25-a-year-of-revival-for-the-2-wheeler-industry-126152 (2025)
- Royal Enfield FY2025: https://www.freepressjournal.in/automobiles/royal-enfield-celebrates-historic-1-million-sales-milestone-for-fy-2025 (2025)
- One Ride: https://royalenfield.com/OneRide/
- Smartphones: https://www.easternmirrornagaland.com/855-pc-of-indian-households-now-own-at-least-1-smartphone-centre (MoSPI CMS Telecom 2025)
- Competitors: `docs/COMPETITOR_ANALYSIS_2026-11.md` (11 Nov 2026)
