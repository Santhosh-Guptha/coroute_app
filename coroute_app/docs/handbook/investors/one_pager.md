# CoRoute: one-page overview

**The safety and coordination app for India's motorcycle riders, solo and in groups.**
Website: https://coroute.devmonks.space · Status (November 2026): pre-launch, Android app code-complete, not yet on Google Play.

---

## The problem

- Two-wheeler riders are the most exposed group on Indian roads. In 2023, **1,72,890 people died in 4,80,583 road accidents in India, and two-wheeler riders were 44.8 % of those deaths**, the highest share of any road-user group (MoRTH, *Road Accidents in India 2023*, as reported Aug 2025 [1]).
- When a rider crashes alone, help depends on someone passing by. On a highway or a ghat road with no signal, a phone call may not be possible at all.
- Group rides are coordinated on WhatsApp and phone calls. WhatsApp live location expires, shows each rider in a separate bubble, has no roles or fall-behind alerts, no SOS or crash detection, and stops without data [2].
- Riders in noise-cancelling earbuds or helmet sets often cannot hear an ambulance behind them.

## The solution

CoRoute turns the phone the rider already carries into a safety device and a group radio. No extra hardware.

| | What CoRoute does |
|---|---|
| **Crash detection** | After a hard stop the phone asks "Possible crash. Are you OK?" with a **30-second countdown**. "I'm OK" cancels; no answer sends the SOS. False-alarm suppression (potholes, speed breakers, rough road, a loose phone, riding on after a jolt cancels the alarm) and per-bike learning from "I'm OK" answers. |
| **SOS that works without signal** | Three paths: a text from the rider's **own phone**, a text from the **server** to emergency contacts, and a **phone-to-phone** relay between nearby riders on a shared hotspot. |
| **Siren alerts for ANC earbud users** | The phone's own microphone recognises ambulance, police and fire-engine sirens and says "Keep left and give way" in the rider's earbuds or helmet set. We found no other app that does this. |
| **Live hands-free intercom** | Push-to-talk or hands-free group talk over mobile data, with wind, engine and breath cleanup. Relayed live, never recorded. |
| **Guardian live link** | Family follow the ride in a browser, no app needed (first name and position only); the link ends on its own. |
| **Privacy** | Encrypted in transit, no ads, no third-party analytics or tracking SDKs, no sale of data. Routes deleted after 90 days. |

Plus: one live group map with Lead / Middle / Sweeper roles, fall-behind and stretch alerts, regroup points, medical ID on the lock screen, trip reports, crews with polls, and a private rider score that never rewards speed.

## Why now

- Phones already carry the sensors needed (accelerometer, gyroscope, GPS, microphone); **85.5 % of Indian households own at least one smartphone** (MoSPI CMS: Telecom 2025 [3]).
- Leisure riding is growing: **Royal Enfield sold over 1 million motorcycles in FY2025** [4], and its One Ride 2025 event drew **150,000+ riders** [5]. Clubs still run on WhatsApp.
- Indian group-ride apps compete on community and planning. None we found ships crash detection, offline SOS and live voice together (see the competition section of the investor memo).

## Business model

- **Safety is free for every rider.** SOS, crash alerts, emergency texts, medical ID and guardians are never gated, in any mode.
- **Group plans** for riders who host group rides (one host plan per ride; everyone else joins free). Plans are bought **only on the website** to comply with Google Play's payments policy; the app sells nothing.
- **Configurable access modes** in the web admin: Paid, Free for everyone, or Free up to limits.
- **Operators and clubs (B2B):** a web console for tour operators, riding clubs, rental and corporate fleets, approved by CoRoute with per-operator limits.
- **Later:** partner perks on route, an opt-in insurance safe-rider certificate, fleet safety.

## Status

- Android app (Flutter) and Node.js gateway code-complete for v3.55; 3.56 adds website payments, access modes and the operator console. Server suite: **904 / 904 tests passing** at the last full documented run (Nov 9, 2026).
- Runs on two Oracle Cloud VMs with live failover. Website live at coroute.devmonks.space.
- **Not yet done:** real-device validation of sensor and audio features, production deploy of the latest build, Google Play launch, iOS app.
- No users, revenue or ratings yet. We will report real numbers from launch.

## The ask

**[OWNER TO FILL]**: amount, instrument, use of funds and the 12-month milestones it buys.

Contact: **[OWNER TO FILL: founder name, e-mail, phone]**

---

Sources: [1] DT Next / PTI, 28 Aug 2025, https://www.dtnext.in/news/national/172-lakh-people-died-in-480-lakh-road-accidents-in-2023-road-ministry-report-844831 · [2] Tom's Guide, https://www.tomsguide.com/how-to/how-to-share-your-live-location-in-whatsapp · [3] Eastern Mirror (MoSPI Comprehensive Modular Survey: Telecom, 2025), https://www.easternmirrornagaland.com/855-pc-of-indian-households-now-own-at-least-1-smartphone-centre · [4] Free Press Journal, 2025, https://www.freepressjournal.in/automobiles/royal-enfield-celebrates-historic-1-million-sales-milestone-for-fy-2025 · [5] Royal Enfield One Ride, https://royalenfield.com/OneRide/
