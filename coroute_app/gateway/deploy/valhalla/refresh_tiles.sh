#!/usr/bin/env bash
# Monthly: rebuild the India tiles from a fresh Geofabrik extract (A1 only; ~1-2 h, 8-12 GB RAM peak).
# The scripted image stops serving while it rebuilds: run this at night and switch the gateways to ROUTER_KIND=osrm
# for that window (the gateway does not fall back by itself).
set -euo pipefail
cd /opt/coroute/valhalla
free -g | awk '/Mem:/ { if ($2 < 16) { print "refusing: needs >= 16 GB RAM (this host has " $2 " GB)"; exit 1 } }'
docker compose down
sed -i 's/force_rebuild=False/force_rebuild=True/' docker-compose.yml
docker compose up -d
echo "Rebuild started. Watch: docker logs -f coroute-valhalla. When /status answers, set force_rebuild back to False:"
echo "  sed -i 's/force_rebuild=True/force_rebuild=False/' /opt/coroute/valhalla/docker-compose.yml"
