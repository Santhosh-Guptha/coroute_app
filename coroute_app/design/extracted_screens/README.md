# CoRoute Extracted Screens Library

This directory contains the standalone, fully rendered screens extracted from the Claude Artifact export (`CoRoute Rider App Screens.html`).

---

## Quick Start
Open **`index.html`** in any web browser to access the interactive device viewer:
- **Device View**: Preview any screen inside an iPhone 14/15 frame with real scale and touch target boundaries.
- **Dark / Light Toggle**: Switch instantly between the high-contrast Dark theme and daylight Light theme.
- **All Screens Grid**: View all 16 artboards simultaneously.
- **Open Fullscreen**: Direct links to open any screen in its own browser tab.

---

## Directory Structure

```
CoRoute_Extracted_Screens/
├── index.html                           # Master Interactive Viewer Hub
├── README.md                            # Documentation & Screen Catalog
├── dark/                                # 16 Dark Mode Screens (Obsidian #0F171D & Electric Mint #5CCAD3)
│   ├── 01_Start_a_ride.html
│   ├── 02_Navigation_while_riding.html
│   ├── 03_Orbit_quick_access.html
│   ├── 04_Intercom.html
│   ├── 05_Group_riders.html
│   ├── 06_Fuel.html
│   ├── 07_Route.html
│   ├── 08_Guardian.html
│   ├── 09_Emergency_SOS.html
│   ├── 10_Stop_or_pause_ride.html
│   ├── 11_More_and_settings.html
│   ├── 12_Ride_summary.html
│   ├── 13_Trips.html
│   ├── 14_Alerts.html
│   ├── 15_Profile.html
│   └── 16_Admin_operations_dashboard.html
└── light/                               # 16 Light Mode Screens (Daylight #F4F7F9 & Deep Petrol Teal #0B6E78)
    ├── 01_Start_a_ride.html
    ├── 02_Navigation_while_riding.html
    ├── 03_Orbit_quick_access.html
    ├── 04_Intercom.html
    ├── 05_Group_riders.html
    ├── 06_Fuel.html
    ├── 07_Route.html
    ├── 08_Guardian.html
    ├── 09_Emergency_SOS.html
    ├── 10_Stop_or_pause_ride.html
    ├── 11_More_and_settings.html
    ├── 12_Ride_summary.html
    ├── 13_Trips.html
    ├── 14_Alerts.html
    ├── 15_Profile.html
    └── 16_Admin_operations_dashboard.html
```

---

## Screen Catalog

| # | Screen File | Core Functionality | Mode |
|---|---|---|---|
| **01** | `01_Start_a_ride.html` | Pre-ride home screen with convoy card, route distance, joined riders, and bike readiness | Mobile 390x844 |
| **02** | `02_Navigation_while_riding.html` | Active Cockpit Map hero with top maneuver HUD, speedometer, 6-button glove dock, convoy pill | Mobile 390x844 |
| **03** | `03_Orbit_quick_access.html` | Modal popup over cockpit map with 7 quick access actions (Intercom, Group, Fuel, SOS, etc.) | Mobile 390x844 |
| **04** | `04_Intercom.html` | Helmet headset status, PTT button, channel picker (Convoy vs Lead), live speaker status | Mobile 390x844 |
| **05** | `05_Group_riders.html` | Convoy spread distance (4.6 km), riding order ladder with individual live speeds and fuel | Mobile 390x844 |
| **06** | `06_Fuel.html` | Usable range vs destination, low-fuel teammate alert, corridor pump suggestions & 1-tap add stop | Mobile 390x844 |
| **07** | `07_Route.html` | Trip distance, ETA, waypoint timeline (Start, Fuel Regroup, Destination), add stop action | Mobile 390x844 |
| **08** | `08_Guardian.html` | Active safety monitors (crash, motionless, spread gap), emergency contact escalation | Mobile 390x844 |
| **09** | `09_Emergency_SOS.html` | Urgent red alert modal, 10s auto-dispatch countdown, GPS coordinates, helpline 1033 button | Mobile 390x844 |
| **10** | `10_Stop_or_pause_ride.html` | 3-way rider intent selector: Quick break (~10m), I'll catch up, End my ride | Mobile 390x844 |
| **11** | `11_More_and_settings.html` | Rider profile, helmet audio, speed limit alerts, screen wake lock, tank specs, offline maps | Mobile 390x844 |
| **12** | `12_Ride_summary.html` | Ride completion report: distance, duration, avg/top speed, fuel consumed, stops, companion badges | Mobile 390x844 |
| **13** | `13_Trips.html` | Upcoming convoy schedule with start timer countdown, past ride logs and safety badges | Mobile 390x844 |
| **14** | `14_Alerts.html` | Notification inbox categorized into All, Safety alerts, and Convoy alerts | Mobile 390x844 |
| **15** | `15_Profile.html` | Rider lifetime stats (rides, distance, safety score 96), bike specifications, emergency contacts | Mobile 390x844 |
| **16** | `16_Admin_operations_dashboard.html` | Web operations console for regional convoy monitoring, incident queue, server health (99.98%) | Desktop 1200x840 |
