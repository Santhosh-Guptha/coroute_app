# 07. Backend APIs & External Integrations

**Target**: CoRoute Network & Gateway Interoperability Layer  
**Public Gateway Base URL**: `https://coroute.duckdns.org/api`  
**Public WebSocket URL**: `wss://coroute.duckdns.org/ws`  
**Configuration File**: [`app_config.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/core/config/app_config.dart)  

---

## 1. REST API Inventory

| Name | Source File | Method | Endpoint | Request Data | Response Data | Auth Required | Callers | Status |
| :--- | :--- | :---: | :--- | :--- | :--- | :---: | :--- | :--- |
| **Meta Info** | `routes.js:45` | `GET` | `/meta` | None | `{ minBuild, latestBuild, downloadUrl }` | No | `MetaService.load()` | `VERIFIED_LIVE` |
| **Health Check** | `routes.js:42` | `GET` | `/health` | None | `{ status: "ok", uptime }` | No | Caddy load balancer | `VERIFIED_LIVE` |
| **Register** | `routes.js:52` | `POST` | `/auth/register` | `{ email, password, name, phone }` | `{ token, user }` | No | `AccessGateScreen` | `VERIFIED_LOCAL` |
| **Login** | `routes.js:53` | `POST` | `/auth/login` | `{ email, password }` | `{ token, user }` | No | `AccessGateScreen` | `VERIFIED_LOCAL` |
| **Google Sign-In** | `routes.js:54` | `POST` | `/auth/google` | `{ idToken }` | `{ token, user }` | No | `AuthService.loginWithGoogle()` | `VERIFIED_LOCAL` |
| **Get My Profile** | `routes.js:68` | `GET` | `/me` | None | `{ user }` | Bearer JWT | `AuthService.revalidate()` | `VERIFIED_LOCAL` |
| **Update Profile** | `routes.js:72` | `PATCH` | `/me` | `{ name, phone, bikeModel, bloodGroup }` | `{ user }` | Bearer JWT | `EditProfileScreen` | `VERIFIED_LOCAL` |
| **Change Password** | `routes.js:73` | `POST` | `/me/password`| `{ currentPassword, newPassword }` | `{ ok: true }` | Bearer JWT | `ChangePasswordScreen` | `VERIFIED_LOCAL` |
| **Delete Account** | `routes.js:74` | `DELETE` | `/me` | `{ password }` | `{ ok: true }` | Bearer JWT | `AccountScreen` | `VERIFIED_LOCAL` |
| **Create Convoy** | `routes.js:90` | `POST` | `/convoys` | `{ name, isPublic, maxBikes }` | `{ convoy }` | Bearer JWT | `CreateRideSheet` | `VERIFIED_LOCAL` |
| **Join Convoy** | `routes.js:95` | `POST` | `/convoys/join`| `{ joinCode }` | `{ convoy }` | Bearer JWT | `JoinRideSheet` | `VERIFIED_LOCAL` |
| **Get Active Convoy**| `routes.js:100`| `GET` | `/convoys/active`| None | `{ convoy }` (or 204) | Bearer JWT | `ConvoyService._restoreActiveConvoy` | `VERIFIED_LOCAL` |
| **Get Convoy By ID** | `routes.js:105`| `GET` | `/convoys/:id` | None | `{ convoy }` | Bearer JWT | `ConvoyService.fetchConvoy` | `VERIFIED_LOCAL` |
| **Leave Convoy** | `routes.js:240`| `POST` | `/convoys/:id/leave`| None | `{ ok: true }` | Bearer JWT | `leaveFromNotification()` | `VERIFIED_LOCAL` |
| **Set Trip Status**| `routes.js:247`| `POST` | `/convoys/:id/status`| `{ status: "STARTED"\|"PAUSED"\|"ENDED" }` | `{ tripStatus }` | Lead/Admin JWT | `ConvoyService.endRide()` | `VERIFIED_LIVE` |
| **Emergency Roster**| `routes.js:220`| `GET` | `/convoys/:id/emergency-roster` | None | `{ roster: [...] }` | Bearer JWT | `ConvoyService.refreshEmergencyRoster` | `VERIFIED_LOCAL` |
| **List Trips** | `routes.js:260`| `GET` | `/trips` | None | `{ trips: [...] }` | Bearer JWT | `TripStorageService.syncWithCloud` | `VERIFIED_LOCAL` |
| **Get Trip Report** | `routes.js:315`| `GET` | `/trips/:id/report` | None | `{ report: {...} }` | Bearer JWT | `TripReportScreen` | `VERIFIED_LOCAL` |
| **Save Trip** | `routes.js:275`| `POST` | `/trips` | `{ trip: {...} }` | `{ tripId }` | Bearer JWT | `TripStorageService.saveTrip` | `VERIFIED_LOCAL` |
| **Upload Tracks** | `routes.js:290`| `POST` | `/convoys/:id/tracks` | `{ chunks: [...] }` | `{ received: N }` | Bearer JWT | `TrackUploader` | `VERIFIED_LOCAL` |
| **Export GPX** | `routes.js:305`| `GET` | `/convoys/:id/gpx` | Query `?uid=...` | XML GPX 1.1 file | Bearer JWT | `TripReportScreen.exportGpx` | `VERIFIED_LOCAL` |
| **Routing (OSRM)** | `routes.js:325`| `POST` | `/geo/route` | `{ points: [[lat, lng], ...] }` | `{ polyline, distance, duration }` | Bearer JWT | `GeoService.route()` | `VERIFIED_LOCAL` |
| **Reverse Geocode** | `routes.js:320`| `GET` | `/geo/reverse` | Query `?lat=...&lng=...` | `{ name, address }` | Bearer JWT | `GeoService.reverse()` | `VERIFIED_LOCAL` |
| **Route Weather** | `routes.js:335`| `POST` | `/geo/weather` | `{ points: [...] }` | `{ forecasts: [...] }` | Bearer JWT | `WeatherService.fetchWeather()` | `VERIFIED_LOCAL` |
| **Guardian Links** | `guardian_routes.js:15` | `POST` | `/guardians/links` | `{ groupId, durationMinutes }` | `{ grantId, token, url }` | Bearer JWT | `GuardianSheet` | `VERIFIED_LOCAL` |
| **Admin Fleet** | `routes.js:400`| `GET` | `/admin/fleet` | None | `{ convoys: [...] }` | Admin JWT | `MasterAdminDashboard` | `VERIFIED_LOCAL` |
| **Admin Emergencies**| `routes.js:405`| `GET` | `/admin/emergencies` | None | `{ emergencies: [...] }` | Admin JWT | `AdminEmergenciesPanel` | `VERIFIED_LOCAL` |
| **Admin Stats** | `routes.js:440`| `GET` | `/admin/stats` | None | `{ activeUsers, activeConvoys, uptime }` | Admin JWT | `MasterAdminDashboard` | `VERIFIED_LOCAL` |

---

## 2. WebSocket Real-Time Event Protocol (`/ws`)

### Client-to-Server Events
* `JOIN`: Binds the socket connection to a specific convoy room (`groupId`). Supports `prevExit: "KILLED"` for crash recovery.
* `TELEMETRY`: Streams rider latitude, longitude, speed, heading, battery, and optional fuel/biometrics (2.5s cadence).
* `CHAT`: Group text messages, tactical signals, or quick-reply chips.
* `WAIT`: Request for convoy to slow down or halt for a regroup.
* `STATUS`: Sets rider status (`OK`, `STOPPED`, `MECHANICAL`, `FLAT_TIRE`, `LOW_FUEL`).
* `SOS`: Broadcasts emergency distress (`CRASH_AUTO`, `CRASH_MANUAL`, `MEDICAL`, `PANIC`).
* `SOS_RESOLVE`: Resolves an active emergency with reason (`RESOLVED`, `FALSE_ALARM`).
* `REPORT_DOWN`: Downed rider report submitted by a fellow pack member.
* `ROAD_HAZARD`: Broadcasts GPS coordinates and severity of a newly detected road hazard.
* `ROLE_SET`: Assigns convoy role (`LEAD`, `SWEEPER`, `PACK`).
* `ROUTE_SET`: Updates planned polyline coordinates and stop list.
* `REGROUP_SET`: Designates a physical regroup coordinate with convergence radius.
* `MIC_STATE`: Signals microphone mute/unmute state.
* `PING`: Heartbeat frame; server responds with `PONG`.

### Server-to-Client Broadcasts
* `SNAPSHOT`: Complete room state payload delivered upon joining (members, route, alerts, messages).
* `RIDER_UPDATE`: Broadcasts another member's updated coordinates, heading, and speed.
* `RIDER_LEFT`: Notifies room that a member disconnected or departed.
* `ALERT`: Urgent convoy notification (Crash, Behind Sweeper, Off Route, Stray Rider).
* `ALERT_RESOLVED`: Informs riders that an active emergency has been resolved.
* `TRIP_STATUS`: Informs riders of state changes (`STARTED`, `PAUSED`, `ENDED`).
* `DISSOLVED`: Forces immediate convoy termination and teardown across all client UIs.
* `ROAD_HAZARD`: Alerts following riders of an approaching pothole or hazard.
* `ASSIST_REQUEST`: Dispatches cross-group mutual aid request to nearby highway riders.
* `ACK`: Confirms delivery of queued outbox items (`clientId`).
* `ERROR`: Relays error code and descriptive reason (`NOT_MEMBER`, `CAPACITY_REACHED`).

---

## 3. External Third-Party Integrations

1. **Routing Engine (OSRM / OpenStreetMap)**:
   * Self-hosted or public OSRM proxy for motorcycle route calculations, distance matrices, and turn-by-turn geometry.
2. **Geocoding & Reverse Geocoding (Photon / Komoot)**:
   * OpenStreetMap-derived geocoding service queried through `/api/geo/search` and `/api/geo/reverse`.
3. **Weather Forecasts (Open-Meteo)**:
   * Free, high-resolution meteorological models providing precipitation, wind speed, and temperature along the route corridor.
4. **Google Sign-In (OAuth 2.0)**:
   * Client ID: `87798956679-ivggpbpote5cf2cvi8mtg8gja3r1sfve.apps.googleusercontent.com`.
   * Verifies Google ID tokens on the Gateway via `google-auth-library`.
5. **Organic Maps Intent Interop**:
   * Offline turn-by-turn fallback triggered via custom URL scheme `om://` or package `app.organicmaps`.
6. **Oracle Cloud Infrastructure (OCI)**:
   * Oracle Autonomous Database with SODA Document Store; VM clustering managed by systemd and Caddy 2 reverse proxy.
