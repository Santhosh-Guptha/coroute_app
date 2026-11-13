# CoRoute load tests (v3.56)

Two tools, no new dependencies (only `ws`, MIT, already used by the gateway). k6 (AGPL) is deliberately not used;
autocannon is not installed, so `http_load.js` is a small keep-alive client of its own.

| Tool | What it measures |
|---|---|
| `ws_load.js` | N riders in M convoys sending positions at `--hz`, random SOS presses. Position fan-out latency sender -> every peer (p50/p95/p99), SOS delivery latency sender -> every other member, frames and batches per second, gateway CPU / event-loop lag / memory per socket / DB calls (local mode). |
| `http_load.js` | Requests per second and latency per path with keep-alive connections; gateway CPU (local mode). |
| `seed_staging.js` | Creates load-test riders and convoys in the **staging** database and writes their tokens (refuses production). |
| `_seed.js`, `_db_counter.js` | Helpers: in-process seeding (no password hashing, no rate limits) and a SODA call counter. |

**Never point these at production.** Both tools refuse `coroute.devmonks.space` and `coroute.duckdns.org` unless the
host name contains `staging`.

## Locally (in-memory gateway, nothing to set up)

```bash
cd gateway
node tool/load/ws_load.js --riders 2000 --group-size 8 --hz 1   --seconds 30 --sos-per-min 30   # worst case (1 fix/s)
node tool/load/ws_load.js --riders 3000 --group-size 8 --hz 0.4 --seconds 30 --sos-per-min 30   # the app's cadence (2.5 s)
node tool/load/ws_load.js --riders 500  --group-size 50 --hz 1  --seconds 30                    # large rooms (batching)
node tool/load/ws_load.js ... --caps net1,pubride1      # an app without 'posbatch1' (older builds)
WS_DEFLATE=on node tool/load/ws_load.js ... --client-deflate   # any gateway env var reaches the forked gateway
LOAD_NODE_FLAGS="--max-old-space-size=384" node tool/load/ws_load.js ...   # V8 flags for the gateway process
node tool/load/http_load.js --connections 50 --seconds 15
node tool/load/http_load.js --gateway-dir /path/to/other/gateway ...       # compare two builds
```

Through a local Caddy (to measure Caddy's own memory per WebSocket): start `ws_load.js --via ws://127.0.0.1:8080/ws
--port-file /tmp/p --wait-via 5`, start Caddy with a site that proxies to the port in `/tmp/p`, and watch Caddy's RSS.

Add `--json --out results.jsonl --label "..."` to keep results.

## Against staging (vm4)

The staging gateway must use its **own** database (an Always Free ADB in tenancy 2, never production):
`seed_staging.js` refuses unless `PUBLIC_ORIGIN` contains `staging`, the database host is not in
`PRODUCTION_DB_HOSTS`, and `--confirm-db <host>` names it.

```bash
# on vm4 (deploy/staging/quick_load.sh does exactly this; deploy/release.sh runs it as the staging gate)
cd /opt/coroute/gateway
set -a; . /etc/coroute/gateway.env; . /run/coroute/secrets.env; . /etc/coroute/staging.env; set +a
node tool/load/seed_staging.js --riders 300 --group-size 8 --out /tmp/tokens.json --confirm-db <staging db host>
node tool/load/ws_load.js --target wss://staging.coroute.devmonks.space/ws --tokens /tmp/tokens.json --hz 0.4 --seconds 60
node tool/load/http_load.js --target https://staging.coroute.devmonks.space --connections 20 --seconds 30
```

Running the generator on vm4 itself shares vm4's 1/8 OCPU with the gateway under test: the numbers are a
regression gate, not capacity. For capacity numbers run the generator from another machine (the owner's PC or vm3)
and read the gateway side from `curl -s 127.0.0.1:3000/metrics` on vm4 (CPU seconds, event-loop lag, DB calls).

## Reading the results

* `fanoutLatencyMs`: sender's send -> peer's receive (same machine clock). Small rooms: positions go out at once;
  rooms above 20 riders flush every 500 ms by design (p50 ~250 ms), SOS never waits.
* `sos.deliveries / expected` must be equal; `sos.latencyMs` stays in single-digit ms locally.
* `gateway.cpuPctOfOneCore` is one core of the test machine. The E2.1.Micro's sustained baseline is 1/8 OCPU:
  divide local capacity by about 6-8 for sustained load (burst credits allow ~1.5x slower than local, briefly).
  See `docs/infra/INFRASTRUCTURE_PLAN_v3.56.md` section 4.
* `dbTop` lists the hottest SODA calls (`op collection`): the steady state should be room snapshots and consent
  reads, not users / sessions (those are cached for 120 s on the socket hot path since v3.56).

## Round 8: compact frames and stage gates

```bash
node tool/load/ws_load.js --riders 2000 --group-size 8 --hz 1 --seconds 30 --pos2        # P2 in, RU2 out (new apps)
node tool/load/ws_load.js --preset gate2x   --target-riders 1000 --seconds 120 --pos2 --gate   # 2x target, pass/fail
node tool/load/ws_load.js --preset soak     --target-riders 1000 --seconds 300 --sample-s 30   # memory / lag growth
node tool/load/ws_load.js --preset failover --target-riders 1000 --seconds 60                  # drop every socket half way
node tool/load/ws_load.js --preset flood    --target-riders 1000 --seconds 40                  # one IP + one account flood
```
`--failover-cmd "..."` (remote mode) runs a command at the failover point, e.g. stopping the staging gateway. The
summary ends with a GATE block (SOS p99 < 150 ms, positions p99 < 250 ms server side, every SOS delivered, >= 99 %
back within 10 s, flood limits engaged); `--gate` makes a failed target exit 1. Riders reconnect and resend an
un-echoed SOS like the app. Results of round 8: `docs/quality/ROUND8_REALTIME_NOTES.md`.
