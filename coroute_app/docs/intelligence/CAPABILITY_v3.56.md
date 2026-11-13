# Road & safety intelligence: what fits the VMs we have (v3.56 note, round 4)

Written before building (12 Nov 2026). Hard constraint: production is **2 × OCI VM.Standard.E2.1.Micro**
(1/8 OCPU burstable, 1 GB RAM each, Node gateway behind Caddy) and **Oracle Autonomous DB Always Free**
(SODA, ~20 GB). The Ampere A1 (4 OCPU / 24 GB) is not provisioned. Everything below therefore runs **inside the
existing gateway process**, as incremental counters and small leased jobs, or **on the phone**.

## Budget we give ourselves

| Resource | Gateway today (RUNBOOK, SERVER_LOAD) | Intelligence budget (both nodes) |
|---|---|---|
| Heap | 150–250 MB of ~1 GB | **≤ 20 MB worst case**, ~3–6 MB typical |
| CPU (live node) | I/O bound, burst credits | **≤ 1 % of a core** at 300 live riders (≈ 5 µs per telemetry point) |
| CPU (job) | — | one leased batch every 5 min, ≤ 2,000 cell writes, yields every 10 rows (`setImmediate`) |
| DB rows | tens of MB | raw rows ≤ 90 days (~40–80 MB at 1,000 rides/week), aggregates ~10–30 MB |
| ORDS calls | — | batch reads with `$in` (50 ids per call), one replace per touched cell, ≤ 4 in flight |

## What runs where

| Feature | Where | Fits micro VMs now? | Memory / CPU estimate |
|---|---|---|---|
| 0 Consent, trimming, k-anonymity, retention | gateway (`src/intel/privacy.js`) + app | **Yes** | consent cache LRU 5,000 users × ~60 B ≈ 0.3 MB |
| 1 Hazard hotspots | app detects (existing sensor hub buckets) → batched events; gateway folds into geohash-7 cells | **Yes** | events are app-batched (≤ 200 per post); cells read per geohash-4 tile, LRU 200 tiles ≈ 2 MB |
| 2 Crash brain | app sends features of each crash alarm; gateway trains logistic regression nightly | **Yes** | ≤ 20,000 labelled rows × 8 features; training ≈ 50 ms, pure JS, deterministic |
| 3 Falling behind / regroup | **phone only** (lead / sweep phone already receives every rider's position) | **Yes** (no server work) | 0 on the server |
| 4 Fatigue and night rules | **phone only** | **Yes** | 0 on the server |
| 5 Rider stops / fuel gaps | gateway stop detection from WS telemetry it already receives; fuel gaps from cached places + learned stops | **Yes** | per active consenting rider accumulator ≤ 200 cells + 40-point FIFO ≈ 25 KB worst; cap 500 accumulators ⇒ **≤ 12 MB worst**, ~2 MB typical |
| 6 Motorcycle ETAs | same accumulator (geohash-6 × 12 time buckets), factor applied to router legs | **Yes** | factor lookup is a Map read per route sample (≤ 400 samples per route) |
| 7 Road quality | existing road-surface detector on the phone (mount aware) → events | **Yes** | as hazards |
| 8 Twisty roads | heading change per km from the accumulator (geohash-6); trip report computed on the phone | **Yes** | inside the accumulator |
| 9 Dangerous times | folded from hazard events into geohash-4 × 48 slots | **Yes** | ≤ ~1,000 docs nationally |
| 10 Valhalla motorcycle routing | adapter in gateway (`ROUTER_KIND`), Valhalla server on a separate box | **Adapter yes; server NO** | Valhalla India tiles: **build 8–12 GB RAM, runtime 2–4 GB** ⇒ needs the A1. Default stays OSRM (`router.project-osrm.org` / own OSRM). |

Not built (needs something we do not have):

* **Weather in dangerous times**: no unrestricted free weather source. Open-Meteo's free API is non-commercial;
  the existing 3.16 route weather already uses it (`WEATHER_URL`), which the owner should review before a
  commercial launch (owner decision O-W1). A licensed source can be added later behind `WEATHER_URL`.
* **Full raw tracks for analytics**: never stored. Only per-ride compact cell counters (one row per ride chunk).
* **Map matching / per-OSM-way segments**: needs Valhalla/OSRM `match` at volume (A1). We use geohash cells instead.

## Why geohash cells and not road segments

Cells need no map data, no map matching and no extra service: the gateway turns a position into a cell id in
about a microsecond. Geohash-7 (≈ 150 m × 150 m) for point things (hazards, stops, potholes), geohash-6
(≈ 1.2 km × 0.6 km) for stretch things (speed, twistiness), geohash-4 (≈ 39 km × 20 km) for regions
(dangerous times) and as the read tile. Direction is kept as an 8-way heading bucket.

## Two-node rules

* **Live node** (rooms, sockets) builds accumulators from telemetry and writes compact raw rows (insert only).
* **Job-lease holder** (prefers `web`) is the only writer of aggregates (`intel-aggregate`, `intel-daily`).
* **Both nodes** answer reads from `intel_cells` with a 10-minute memory cache per geohash-4 tile.
* A node restart loses at most the open accumulators of riders on the ride (≤ the last 30 min of telemetry,
  which is anyway not counted until the rider moves 300 m on).

## Upgrade path when the A1 arrives

1. Run Valhalla (`gateway/deploy/valhalla/`), set `ROUTER_KIND=valhalla`, `GEO_ROUTE_URL=http://<a1>:8002`.
2. Optionally move `intel-aggregate` to the A1 node (set its `GATEWAY_ROLE=web`; the lease follows the role).
3. Raise `INTEL_MAX_ACCUMULATORS` and `INTEL_JOB_MAX_CELLS`.

## Measured after building (12 Nov 2026, Node 22, this dev VM; the micro VM is roughly 3-6× slower per core)

| What | Measured | Bound in code |
|---|---|---|
| Heap, worst case: 500 riders on a ride, each with 200 cells + a full 150-point trimming FIFO | **14.6 MB** (estimate function says 18.1 MB) | `INTEL_MAX_ACCUMULATORS` 500, `INTEL_MAX_CELLS_PER_RIDE` 200, FIFO 150 (stationary points merged) |
| Heap, typical: 500 riders × 40 cells × 30 held points | **3.2 MB** | |
| CPU per position, consenting rider | **≈ 6 µs** (≈ 20-40 µs on the micro VM): 300 riders at 1 Hz ≈ 1 % of one core | settings read at most once a second |
| CPU per position, rider without consent | **≈ 0.5 µs** (one cached consent lookup) | consent LRU 5,000, 60 s |
| Aggregation run (6 ride rows → 1,182 cells, MemorySoda) | 17 ms of CPU; on ORDS dominated by ≈ 1,200 replaces at 4 in flight | ≤ 2,000 cell writes per run, `setImmediate` every 10 rows / 20 writes, aborts when the lease is lost |
| Raw rows | one row per ride chunk (≤ 200 cells, ≈ 6-10 KB) or per event batch (≤ 200 events) | queue ≤ 500 rows, then oldest dropped and counted |
| Read cache | ≤ 200 tiles per node | 10 min TTL |
