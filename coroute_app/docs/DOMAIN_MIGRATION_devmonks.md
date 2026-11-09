# Domain move: coroute.duckdns.org → coroute.devmonks.space

The app package is `space.devmonks.coroute_app`, so `devmonks.space` is our own domain. The code is ready for the
move, so switching is now a matter of configuration and order. Builds 3.54 and 3.55 have
`https://coroute.duckdns.org` built in and **must keep working**. The DuckDNS name stays fully served for at least
6 months.

## What is already prepared in code

| Area | Change |
|---|---|
| Gateway origin | `PUBLIC_ORIGIN` is the single canonical origin for every generated link: friend invites `/join/friend/<code>`, ride join links, live emergency links `/e/<token>` (app and server SMS), guardian `/watch` links, website checkout, `/api/meta` links, canonical/og tags, `sitemap.xml`, `robots.txt`, the provider User-Agent. If it is empty, pages use the request host and other links use `https://coroute.duckdns.org` (never an unowned domain: the old `coroute.live` fallback in the SMS gateway is gone). Code: `gateway/src/domains.js`. |
| Both hosts accepted | `LEGACY_ORIGINS` (default `https://coroute.duckdns.org`) is served in full. CORS (when `CORS_ORIGINS` is set) and the guardian `Origin` checks accept PUBLIC_ORIGIN plus the legacy origins. The WebSocket `/ws` has no Origin/Host check (it authenticates by JWT), and nothing in the gateway checks the Host header, so both names work for REST and sockets. Live links of either host are accepted by `dispatch-external`. |
| Legacy redirect (opt-in) | `REDIRECT_LEGACY_HOST=true` sends **website pages only** (GET/HEAD) on a legacy host to PUBLIC_ORIGIN with a 301 that keeps the path and query. It never redirects `/api`, `/ws`, `/.well-known/` (App Links verification does not follow redirects), `/e/` live links, `/watch`, `/uploads/` or `/status`, and never a POST. |
| assetlinks.json | `GET /.well-known/assetlinks.json` doesn't depend on the host: the same file is served on both names (tested). |
| App | `AppConfig.defaultApiBaseUrl = https://coroute.devmonks.space` and `legacyApiBaseUrl = https://coroute.duckdns.org` (`lib/core/config/app_config.dart`). `--dart-define=COROUTE_API=…` still overrides, and an override has no fallback. `GatewayHosts` (`lib/core/config/gateway_hosts.dart`) tries the new name first. If it can't be reached (DNS, TLS, connection refused, timeout) before anything has answered in this session, the app switches to the legacy name. It retries the failed request once only when the request certainly never left the phone (DNS/TLS/refused), so a POST is never sent twice. The first host that gives a gateway JSON answer is kept for the session. Nothing is stored: every app start tries the new name again. The WebSocket and the share links (`/join/<code>`, marketing `{link}`) follow the host in use. |
| Android App Links | `AndroidManifest.xml` has a second `autoVerify` intent filter for `https://coroute.devmonks.space/join/…` next to the DuckDNS one. |
| iOS | No `ios/` folder is in this snapshot. When it is added, put `applinks:coroute.devmonks.space` and `applinks:coroute.duckdns.org` in `Runner.entitlements`. The gateway would also need to serve `/.well-known/apple-app-site-association`, which it does not do yet. |
| Caddy (two-VM cluster) | `gateway/deploy/caddy/Caddyfile.vm1/.vm2` serve `coroute.devmonks.space, coroute.duckdns.org`. The new name's ACME DNS challenge goes to DuckDNS through a CNAME (`dns_challenge_override_domain`), so the existing `DUCKDNS_TOKEN` issues and renews both certificates and no new secret is needed. HSTS stays 1 year on DuckDNS. On the new name it starts at `max-age=300`. `setup_node.sh` takes `PUBLIC_ORIGIN=…` and no longer rewrites the Caddyfile for these two names. Caddy redirects HTTP to HTTPS on its own. |
| Website | It has no hard-coded host. Canonical, og:url/og:image, sitemap and robots come from `__ORIGIN__` = PUBLIC_ORIGIN. |
| Tests | `gateway/test/domain_migration.test.js` covers links with PUBLIC_ORIGIN, both hosts (GET and POST), CORS, the redirect never touching `/api`, `/ws`, `/.well-known` or POSTs, assetlinks on both hosts and guardian Origin on both hosts. `test/gateway_hosts_test.dart` covers the fallback rules. |

## Environment variables (`/etc/coroute/gateway.env`, both VMs)

```
PUBLIC_ORIGIN=https://coroute.devmonks.space
# optional; this is the default:
LEGACY_ORIGINS=https://coroute.duckdns.org
# leave false until step 7:
REDIRECT_LEGACY_HOST=false
# only if CORS_ORIGINS is already set: both site origins are added automatically
```

## DNS records (at the DNS provider of devmonks.space)

| Name | Type | Value | TTL |
|---|---|---|---|
| `coroute.devmonks.space.` | A | **the OCI NLB reserved public IP**, the same address `coroute.duckdns.org` points to today (`dig +short coroute.duckdns.org`; see `docs/features_355/platform.md`, "Own domain instead of DuckDNS") | 300 during the move, 3600 once stable |
| `coroute.devmonks.space.` | AAAA | only if the NLB gets an IPv6 address (it has none today, so don't add one) | 300 |
| `_acme-challenge.coroute.devmonks.space.` | CNAME | `_acme-challenge.coroute.duckdns.org.` (lets the DuckDNS token answer the Let's Encrypt DNS challenge) | 300 |
| `coroute.devmonks.space.` | CAA (optional) | `0 issue "letsencrypt.org"` and `0 issue "sectigo.com"` (Caddy falls back to ZeroSSL, which issues through Sectigo) | 3600 |

Put the CAA record on `coroute.devmonks.space`, not on the `devmonks.space` apex, so other devmonks sites are not
restricted. Never send HSTS with `includeSubDomains` from `devmonks.space` itself.

## Step by step (in this order)

### 1. DNS record
Add the A record and the `_acme-challenge` CNAME above (TTL 300). Check it:
`dig +short coroute.devmonks.space` shows the NLB IP, and `dig +short CNAME _acme-challenge.coroute.devmonks.space`
shows the DuckDNS name. Wait until both public resolvers agree (`dig @1.1.1.1` and `dig @8.8.8.8`).

### 2. TLS on both names
Copy the new `deploy/caddy/Caddyfile.vm2` to VM2 and `Caddyfile.vm1` to VM1 (as `/etc/caddy/Caddyfile`, with the
peer IP that `setup_node.sh` puts in, or just re-run `setup_node.sh` with the same variables). Then:
`caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile`. **VM2 first**: `systemctl reload caddy`, wait for
"certificate obtained successfully" for `coroute.devmonks.space` in `journalctl -u caddy`. **Then VM1.** DuckDNS keeps
one TXT value, so two VMs (or two names) asking at the same moment collide. Caddy retries, but going one at a time is
faster. The DuckDNS certificate keeps renewing as before, and renewals stay apart once the first issuance is done.
Check: `curl -sI https://coroute.devmonks.space/api/health` gives 200 and a valid certificate, and
`curl -sI https://coroute.duckdns.org/api/health` still gives 200.

If `dns_challenge_override_domain` doesn't validate on the installed Caddy version, use a Caddy build with the DNS
plugin of the devmonks.space provider (for example `caddy-dns/cloudflare`). Put the new name in its own site block
with `tls { dns <provider> {env.TOKEN} }` and keep the DuckDNS block as it is. That option is also the long-term way
to stop depending on DuckDNS for issuance.

### 3. Deploy the gateway with PUBLIC_ORIGIN on the new name
Do this first: if server SMS (Twilio etc. to Indian numbers) is on, get the URL `coroute.devmonks.space` whitelisted
in the DLT templates. Since 2024, Indian operators block A2P SMS with URLs that are not whitelisted, and
PUBLIC_ORIGIN switches the live links in server SMS at once.
Deploy the gateway (both VMs, VM2 then VM1) with the variables above and restart. Check:
- `curl -s https://coroute.duckdns.org/api/meta` shows `downloadUrl: https://coroute.devmonks.space/download`.
- `https://coroute.devmonks.space/` loads, and the page source has `<link rel="canonical" href="https://coroute.devmonks.space/">`.
- `https://coroute.devmonks.space/sitemap.xml` lists the new origin.
- An installed 3.55 app (DuckDNS built in) can still sign in, start a ride, talk and share a join link.
- `./deploy/smoke_test.sh https://coroute.devmonks.space` and `./deploy/smoke_test.sh https://coroute.duckdns.org` both pass.

### 4. Verify assetlinks and App Links
- `curl -s https://coroute.devmonks.space/.well-known/assetlinks.json` is the same as on the DuckDNS host (200, `application/json`, no redirect).
- Google's checker: `https://digitalassetlinks.googleapis.com/v1/statements:list?source.web.site=https://coroute.devmonks.space&relation=delegate_permission/common.handle_all_urls`.
- If the Play Store build is signed by Play App Signing, its SHA-256 must be in `assetlinks.json`. Copy it from Play Console → App integrity.
- Raise the new name's HSTS in both Caddyfiles from `max-age=300` to `max-age=31536000` and reload.

### 5. Release the app build with the new default and the fallback
Build without `COROUTE_API`: `flutter build appbundle --release`. An explicit override turns the fallback off.
Release this build only after step 4. On Android 11 and older, all `autoVerify` hosts of an app are verified
together, so if the new host failed verification, DuckDNS invite links would also open in the browser. That still
works (the join page has "Open in CoRoute" and the code), but it's worse. On a test phone:
`adb shell pm verify-app-links --re-verify space.devmonks.coroute_app`, then
`adb shell pm get-app-links space.devmonks.coroute_app` should show both hosts as `verified`.
Check that `https://coroute.devmonks.space/join/ABC123` and `/join/friend/<code>` open the app.

### 6. Update URLs outside the code
- Play Console: privacy policy URL `https://coroute.devmonks.space/privacy`, website, and the store listing text (`store/LISTING.md`, `gateway/deploy/PLAY_STORE_CHECKLIST.md`). `PLAY_STORE_URL` (play.google.com) doesn't change.
- Razorpay: add a webhook `https://coroute.devmonks.space/api/subscription/webhook` (and `/api/membership/webhook` if it is used) with the same secret. Keep the DuckDNS webhook until the new one shows deliveries, then remove it so events are not handled twice. Update the website URL in the Razorpay account and KYC details. The checkout return URL is generated from PUBLIC_ORIGIN.
- Google Cloud OAuth: the Android client is bound to the package and SHA-1, not the domain. If the web client lists authorized JavaScript origins or redirect URIs, add `https://coroute.devmonks.space`. FCM isn't bound to a domain.
- Guardian web push: `GUARDIAN_VAPID_SUBJECT` can be `mailto:` (no change) or a URL. Browsers subscribed on the DuckDNS `/watch` page keep their subscription. New guardian links use the new name.
- SMS: DLT URL whitelisting (step 3), and the SMS template text if it names the host.
- Website and marketing material, QR codes already printed: the old QR codes keep working (DuckDNS stays up). New material uses the new name (marketing studio `{link}` follows the app's host).
- `gateway/deploy/RUNBOOK.md` smoke-test and curl examples can move to the new name as you go.

### 7. Keep DuckDNS alive for at least 6 months, then optionally redirect
Keep `coroute.duckdns.org` (DNS updater, certificate, Caddy site name) until `MIN_APP_BUILD` is at least the first
build released in step 5 and admin → app builds shows no older builds in use. Only then:
1. Optionally set `REDIRECT_LEGACY_HOST=true`: website pages on DuckDNS get a 301, while the API, sockets, assetlinks, live and guardian links stay served.
2. Later, remove `coroute.duckdns.org` from the Caddyfiles, the DuckDNS updater cron and `DUCKDNS_TOKEN` (after moving issuance to a provider DNS plugin), and drop the legacy intent filter in a later app release.

## Pros and cons of `coroute.devmonks.space`

Pros
- It's our own domain: no DuckDNS outages, rate limits or token-on-the-VM risk, and DNS and certificates are under our control.
- It matches the package name and the brand on the website, Play listing and privacy policy.
- A subdomain keeps `devmonks.space` free for other products. Cookies are host-only (no `Domain=`), so nothing leaks between subdomains.

Cons and things to check
- **Renewal:** set `devmonks.space` to auto-renew with a valid card and registrar lock. If the domain expires, every app on the new default falls back to DuckDNS only while DuckDNS is still kept.
- **DNS provider:** use a reliable provider, ideally one with a Caddy DNS plugin (Cloudflare, OCI DNS) so issuance can leave DuckDNS later. Turn on DNSSEC if the provider supports it.
- **`.space` reputation:** newer gTLDs are scored lower by some SMS and e-mail filters. Links in SMS with uncommon TLDs can be flagged or blocked, and in India links must be DLT-whitelisted anyway. Test a live-link SMS on Jio, Airtel and Vi before relying on it.
- A long hostname in SMS uses characters. Consider a short brand domain later (for example `coroute.in`) for SMS and QR links. That would be another `LEGACY_ORIGINS`-style move, already supported by the same code.

## Hygiene note
`gateway/deploy/setup_new_vm.sh` (legacy single-VM script) contains a DuckDNS token in clear text. Regenerate the
token at duckdns.org, store it only in Vault (`DUCKDNS_TOKEN`), and remove it from that script and from git history.
