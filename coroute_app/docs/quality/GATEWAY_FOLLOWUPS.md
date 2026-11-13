# Gateway follow-ups (after round 6)

`gateway/src` has no TODO / FIXME markers. The follow-up notes in `docs/features_355` that touch the gateway or
the web admin, and what round 6 found, are below. Done items are listed so nobody repeats them.

## Done in round 6

| Item | Where |
|---|---|
| Route split complete and strict; check walks the real app | `deploy/route_split.md`, `deploy/gen_caddy_routes.js`, `deploy/release.sh`, `test/route_split_356.test.js` |
| Real values out of tracked files; inventory loaders | `deploy/_inventory.py`, `deploy/_inventory.sh`, `test/deploy_inventory_356.test.js` |
| `.env.example` tracked and complete (about 60 variables were undocumented) | `deploy/.env.example`, `test/config_env_example_356.test.js` |
| Compare-and-replace made safe again (`casRev`) | `src/oracle/soda.js`, `test/cas_rev_356.test.js` |
| Backup jobs report their last run | `src/backup_jobs.js` (`ops_status`) |
| `VALHALLA_BIND` default is loopback, not a private address | `deploy/valhalla/docker-compose.yml` |

## Open (small, not done because they need a decision or a device)

| # | Item | Why not now | Suggested next step |
|---|---|---|---|
| F1 | **E-mail code tries are not atomic** (`src/email_codes.js`: ride lock override, operator e-mail 2-step). `verify` reads the user, compares, then writes `tries + 1` with a plain update. Several wrong codes sent at the same instant are counted as one try. It does not use compare-and-replace at all, so the round 6 change did not affect it | Fixing it means a compare-and-replace on `users`, the hottest and field-encrypted collection; that deserves its own review. The per-IP limiters on `/api/auth/ride-lock/verify` and `/api/auth/mfa/*` bound the practical gain to a few extra guesses of a 6-digit code | Add `users` to `CAS_COLLECTIONS`, make `verify` a compare-and-replace loop, test with parallel wrong codes |
| F2 | `repo.listCouponRedemptions` reads at most 2,000 redemption rows before filtering | Changing it touches coupon admin paging | Page it like `listRazorpayOrders` |
| F3 | `web_admin.revenueSummary` and the e-mail studio's `_memberships` / `report` load whole collections per request | Works at today's size; the business brain reads the same data page by page at night | Serve the Revenue page from the nightly aggregates once the numbers match for a month |
| F4 | `VM_OPERATIONS_LOG.md` names OS logins | History document | Owner: keep, trim or move out of the repository |
| F5 | The DR node (vm3) is not on the Servers page | It serves no traffic and is in another tenancy | Add a second `PEER_METRICS_URL` once vm3's `/metrics` is reachable over the tunnel |
| F6 | Weekly summary recipients are the administrators only | Owner decision | Add an "extra addresses" field if an accountant should get it |

## From `docs/features_355` (app side, for the app agent / lead)

- `lock_screen_cockpit.md` Follow-ups: translations of the new Ride screen texts; device QA list.
- `operators.md` App follow-up: label club crews in the app (optional).
- `sessions_and_security.md` §8: remaining owner decisions are in the security audit.
