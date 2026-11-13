# Valhalla motorcycle routing (prepared, owner-gated, needs the A1)

Feature 13 of the round 4 road & safety intelligence. **Not for the E2.1.Micro VMs.** The default stays OSRM
(`ROUTER_KIND=osrm`, `GEO_ROUTE_URL=https://router.project-osrm.org`).

| Item | Value |
|---|---|
| Software | Valhalla (MIT), `ghcr.io/valhalla/valhalla-scripted` image (multi-arch, arm64 on the A1) |
| Data | Geofabrik India extract (`asia/india-latest.osm.pbf`, about 1.5 GB), OpenStreetMap, **ODbL**: attribution "© OpenStreetMap contributors" (shown in the app's map and the website footer) |
| Build | 1-2 h, **8-12 GB RAM peak**, about 10 GB disk for tiles (no elevation) |
| Serve | **2-4 GB RAM**, 1-3 threads; `GET /status`, `GET /route?json=...` on port 8002 |
| Costing | `motorcycle` (`use_highways` 0.6, `use_trails` 0), see `src/intel/router_adapter.js` |

## Steps (on the A1, once it is provisioned)

1. Install Docker (`curl -fsSL https://get.docker.com | sh`), then
   `sudo mkdir -p /opt/coroute/valhalla && sudo cp docker-compose.yml coroute-valhalla.service refresh_tiles.sh /opt/coroute/valhalla/`.
2. Set `VALHALLA_BIND` to the A1's private IP in `/opt/coroute/valhalla/.env`; open TCP 8002 in the VCN security list
   **only** from the two gateway VMs' private IPs (never public).
3. `sudo cp /opt/coroute/valhalla/coroute-valhalla.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now coroute-valhalla`.
4. Wait for the first build (`docker logs -f coroute-valhalla`) until `curl http://<private-ip>:8002/status` answers.
5. Smoke test: `curl "http://<private-ip>:8002/route?json=$(python3 -c 'import json,urllib.parse;print(urllib.parse.quote(json.dumps({"locations":[{"lat":12.9716,"lon":77.5946},{"lat":13.0012,"lon":77.63}],"costing":"motorcycle"})))')"`.
6. On both gateway VMs (`/etc/coroute/gateway.env`): `ROUTER_KIND=valhalla` and `GEO_ROUTE_URL=http://<a1-private-ip>:8002`,
   restart VM2 then VM1. Routes now carry `"router": "valhalla"`; old cached OSRM answers expire on their own (7 days).
7. Rollback: set `ROUTER_KIND=osrm` and `GEO_ROUTE_URL=https://router.project-osrm.org`, restart.

Monthly refresh: `sudo /opt/coroute/valhalla/refresh_tiles.sh` at night (routing is down during the rebuild; switch
`ROUTER_KIND=osrm` for that window, or keep a second tile directory if the A1 has the memory).

The OSRM table service used by the safety network (`GeoProxy.table`, "can a nearby rider really get there") stays
on OSRM (`OSRM_TABLE_URL`, default the public OSRM server) when `ROUTER_KIND=valhalla`: Valhalla's matrix API is not
wired in this round, and the SOS helper search must never depend on the new router.
