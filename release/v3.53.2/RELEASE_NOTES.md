# CoRoute v3.53.2+116 Production Release Notes
**Release Date:** 2026-10-30  
**Environment:** Dual-Node Oracle Cloud Cluster (Node 1: `152.67.181.198`, Node 2: `129.225.79.93`)  
**Gateway URL:** `https://coroute.duckdns.org`  

---

## 1. Executive Summary & Root Cause Analysis

### A. Crash Investigation (Rider Yaswanth / New User Ingestion Crash)
- **User Root Cause:** User `yaswanth901@gmail.com` registered at 06:52 AM IST.
- **Root Cause 1 — Timezone Uninitialized Crash:**
  - `AlarmNotifier.schedulePlanReminder` uses `tz.TZDateTime.from(at.toUtc(), tz.UTC)`.
  - In `timezone ^0.10.1`, if `tz_data.initializeTimeZones()` was never invoked before using `TZDateTime` or native alarm dispatchers, any timezone conversion or time evaluation outside initialized data throws an unhandled `TimeZoneInitException`.
  - **Resolution:**
    1. Added `tz_data.initializeTimeZones()` in `main()` immediately after `WidgetsFlutterBinding.ensureInitialized()`.
    2. Added `tz_data.initializeTimeZones()` in `AlarmNotifier._doInit()`.
    3. Wrapped all zoned notification scheduling inside defensive `try/catch` handlers.
- **Root Cause 2 — Missing Boot Receiver:**
  - `AndroidManifest.xml` lacked `ScheduledNotificationBootReceiver` and `RECEIVE_BOOT_COMPLETED` permission, causing Android AlarmManager schedule restoration on newer Android 13/14 devices to fail when the app reboots or registers inexact alarms.
  - **Resolution:** Added `RECEIVE_BOOT_COMPLETED` permission and `ScheduledNotificationBootReceiver` with `BOOT_COMPLETED`, `MY_PACKAGE_REPLACED`, `QUICKBOOT_POWERON` intent filters.

---

### B. Severe App Lag Investigation & Optimization
- **Root Cause 1 — `setState()` Called Inside `build()` in Cockpit:**
  - In `live_cockpit_map_screen.dart`, `_follow(me)` was called directly in `build()`, which conditionally ran `setState(() => _autoFollow = true)`. Calling `setState()` during the build pass caused dirty-tracking contention, frame drops, and infinite cascading rebuild loops.
  - **Resolution:** Eliminated `setState()` inside the build pass; mutations are now cleanly scheduled.
- **Root Cause 2 — Map Rasterization Contention:**
  - `FlutterMap` was not isolated by a `RepaintBoundary`. Every minor HUD change (speed text, battery indicator, clock, telemetry pills) forced the GPU to re-rasterize the entire OpenStreetMap tile layer.
  - **Resolution:** Wrapped `FlutterMap` inside a `RepaintBoundary` to keep the raster tile layer decoupled from interactive overlay controls.
- **Root Cause 3 — HTTP Client & TileProvider Churn:**
  - `appTileLayer()` previously created a brand new `CachedTileProvider` instance on every rebuild, which in turn allocated a new unclosed `http.Client()` instance and new connection pools.
  - **Resolution:** Introduced static cached singletons (`_sharedCachedTileProvider` / `_sharedNetworkTileProvider`) in `map_tiles.dart` to reuse existing HTTP connections and prevent GC/socket thrashing.
- **Root Cause 4 — Main Thread Blocking on App Startup in `TileCache`:**
  - `TileCache.open()` performed synchronous `dir.list()` and `e.stat()` queries across all cached map tiles before `runApp()`.
  - **Resolution:** Offloaded scanning and pruning to background execution (`_scanAndPruneBackground()`), making cache initialization instantaneous.
- **Root Cause 5 — Home Screen Selector Contention:**
  - `RiderHomeScreen.build` used a selector creating `HomeConvoyFacts` record objects comparing all fields on every telemetry ping.
  - **Resolution:** Optimized to `context.select<ConvoyService, String?>((s) => s.activeGroupId)`, eliminating unnecessary re-renders.

---

## 2. Verification & Integrity Matrix

| Check | Tool / Test | Result |
| :--- | :--- | :--- |
| Static Analysis | `flutter analyze` | **0 errors, 0 warnings (No issues found!)** |
| Unit Test Suite | `flutter test` | **119 / 119 unit tests passing** |
| Release Build | `flutter build apk --split-per-abi --release` | **Success (arm64-v8a: 12.4 MB, armeabi-v7a: 12.1 MB, x86_64: 12.6 MB)** |
| Universal Build | `flutter build apk --release` | **Success (universal: 31.9 MB)** |
| Production Nodes | Node 1 & Node 2 sync via SSH/SCP | **Active on `152.67.181.198` and `129.225.79.93`** |
| Public Download | `https://coroute.duckdns.org/coroute.apk` | **HTTP 200 OK (12,992,393 bytes)** |
