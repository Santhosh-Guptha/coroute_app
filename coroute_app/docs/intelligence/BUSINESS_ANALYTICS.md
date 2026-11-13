# Business analytics (round 6)

What the business brain does, how it stays inside the 1 GB micro VMs, what it stores, and what still waits for
vm5 (the Ampere A1). Code: `gateway/src/business/`. Web admin: group **Business**, plus **Servers** and
**Settings > Weekly summary**. Every page and endpoint is MASTER_ADMIN only.

## Rules it follows

- **Runs at night, under the job lease** (`business-nightly`, once a day on one node; `business-weekly-summary`
  hourly check). A MASTER_ADMIN can also press **Refresh numbers now** (one run at a time).
- **Batched.** Collections are read `BUSINESS_PAGE_SIZE` (200) documents at a time with a short pause between
  pages (`BUSINESS_PAGE_PAUSE_MS`, 40 ms), and the job stops at the next page when the gateway shuts down.
- **Bounded memory.** One compact record per rider with rides (`BUSINESS_MAX_RIDERS`, 100,000, about 100 bytes
  each), fixed-size aggregates, capped lists (200 riders at risk, 100 signals, 5,000 training rows, 5,000 riders
  of pending app opens per node). When a cap is reached the pages show a **Partial** chip.
- **Small aggregates, no copies of personal data.** `business_agg` holds one small document per page (counts).
  The two per-rider lists (at risk, signals) hold user ids and numbers only; names are joined when an admin opens
  the page. `business_riders` holds one tiny document per rider (hour-of-week histogram, best hour) and is deleted
  with the account. Device and network hashes are never stored in an aggregate or sent to the browser.
- **Staff accounts are left out** of every figure (admins, `BOOTSTRAP_ADMIN_EMAILS`, `STAFF_EMAILS`).
- **E-mail consent rules are the existing ones.** The business brain never sends a rider an e-mail. Win-back goes
  through the e-mail wizard, which checks consent, the block list and the weekly limit again at send time.
- **Never blocks anyone.** The review list is for a person. The code has no call that holds, blocks or signs out.
- Switch: `BUSINESS_ANALYTICS=off` stops the job, the app-open counter and the weekly summary.

## What is built

| Page | What it shows | Source |
|---|---|---|
| **Overview** | Activation funnel (signed up, confirmed e-mail, first ride, first group ride, paid), for the last 90 days of sign-ups and for all riders; net revenue per week (26 weeks); renewals due in 7 / 14 / 30 days | `users`, `rider_scores`, orders, `memberships` |
| **Retention** | Weekly sign-up cohorts (12 weeks) x weeks active. Active = rode at least once that week (a ride with a finished ride report) | `users`, `rider_scores` |
| **Conversion** | Per plan: orders started, paid, failed, refunded, net. Per coupon: uses, free activations, discount, revenue. Per e-mail campaign: sent, clicked, coupon uses, revenue, unsubscribed (the e-mail studio's own reports). `/plans` page views (the cookieless counter) | orders, coupon redemptions, e-mail studio, `pageviews` |
| **At risk** | The churn warning list with the reasons, and **Send win-back e-mail** | see below |
| **Best send time** | Riders per preferred hour of the week | `business_riders` |
| **Review list** | Payment, coupon and sign-up signals | see below |
| **Servers** | Both nodes, jobs, backups | `/metrics`, `leases`, `ops_status` |

"Rode" uses the ride facts the rider score already keeps (end time and group size, numbers only). A phone-only
offline trip without a server ride report is not counted.

### Churn warning

Riders who rode at least once or hold / held a paid plan get a score from 0 to 100. Riders with no ride for more
than 120 days and no running plan are "lost", not "at risk", and are left off the list.

**Rules (always on, shown as the reasons):**

| Fact | Points |
|---|---|
| No ride for more than 14 / 30 / 60 days | 15 / 30 / 40 |
| Rode about N days a month before and half as much now / not at all in 30 days | 20 / 25 |
| Paid plan ends within 14 days | 15 |
| Paid plan ended in the last 30 days and was not renewed | 20 |
| App not opened for more than 14 / 30 days | 10 / 20 |

The list holds scores of 50 or more (high = 70 or more), at most 200 riders, highest first.

**Learned model (only with enough data).** A logistic regression in pure JS (`churn_model.js`, like the crash
brain): five inputs from ride dates only (days since last ride, ride days in the last 30 days, ride days in the 60
days before, weeks since joining, share of group rides). Each night it is trained on "what did a rider look like 28
days ago, and did they ride since?" and checked on every fifth rider, which it has not seen. It is used only with
at least 200 riders, at least 30 of each outcome and a held-out AUC of 0.65 or more; otherwise the page says why
not. When in use, its probability is shown next to the rule score with the inputs that raised it. The rule score
stays the one the list is sorted by.

**Win-back.** "Send win-back e-mail" asks the server which listed riders may get offer e-mails now (consent on,
valid address, not unsubscribed or blocked), and opens the e-mail wizard with those usernames and the "Win-back"
starter. The admin chooses the coupon, checks and sends. Riders without consent are listed with the reason and a
disabled button.

### Best send time

- Every authenticated app open (`GET /api/me`) is counted at most once per rider per hour, as an hour of the week
  in India time. Each node writes its counts as small batch documents (`business_obs`) every 10 minutes; the
  nightly job folds them into the riders' histograms and deletes the batches.
- E-mail clicks count double (they say more about e-mail time). Clicks carry a hashed user id; they are matched
  for riders who agreed to offer e-mails.
- A rider has a best time after 5 events. The histogram halves when it passes 400 events, so old habits fade.
- **E-mail wizard, step 3:** "At each rider's best time (within 24 hours)". The campaign sends each rider at
  their preferred India-time hour in the 24 hours after the start. A due time inside the quiet hours moves to the
  hour they end. Riders without a best time get it at the start. Consent, block list and weekly limit are checked
  at send time as for every campaign.

### Review list (signals, never a block)

| Signal | Rule |
|---|---|
| Many accounts on one phone | 4 or more accounts signed in on one device hash in 90 days |
| Many sign-ups from one network | 8 or more accounts created in 7 days with one network hash |
| Burst of unconfirmed sign-ups | 10 or more sign-ups in one hour that never confirmed their e-mail (7 days) |
| Many failed payments | 4 or more failed orders of one rider in 30 days |
| Refund pattern | 2 or more refunded orders, or a refund within 48 hours of paying |
| Coupon orders started and left | 5 or more coupon orders of one rider not paid in 30 days |

An admin marks a signal **Reviewed** (with a note) or opens it again; both are in the audit log. Holding or
blocking an account stays a manual action on the rider page.

### Weekly owner summary

Monday 09:00 India time, to the active, verified MASTER_ADMIN accounts and `BOOTSTRAP_ADMIN_EMAILS`, through the
gateway's mailer. Plain language, counts only: riders active and new, riders who rode, SOS and crash alerts of
the last 7 days with how they ended, net revenue and refunds, plans ending, the size of the at-risk list, server
health. Sent once per week across both nodes (the week is claimed with a compare-and-replace). The words are the
template **Weekly owner summary e-mail** (Settings > Templates); the switch, a preview and "Send me a test now"
are under Settings > Weekly summary. Default: on (it needs SMTP to be configured).

### Servers

`GET /api/admin/business/servers` reads this node's metrics in process and the other node's `/metrics` over the
VCN (`PEER_METRICS_URL`, default `http://<mirror peer host>:PORT/metrics`). The peer must allow it: add this
node's private IP to the peer's `METRICS_ALLOW`, or set the same `METRICS_TOKEN` on both. Nothing is stored; one
small sample per node is kept in memory to turn counters into per-second rates.

| Number | Amber | Red |
|---|---|---|
| Event loop lag (p99) | 50 ms | 150 ms |
| Memory (RSS of `NODE_MEMORY_MB`, 1024) | 70% | 85% |
| Heap of its limit | 75% | 90% |
| Database calls waiting | 20 | 100 |
| Riders online of `LIVE_RIDER_CAP` (when set) | 80% | 95% |
| Load shedding | requests shed since the last look | shedding now |
| Link to the other node | down | |
| Scheduled job | missed more than two turns | |
| Last full backup / hourly backup | 26 h / 3 h | 50 h / 12 h, or a failed run |

The backup jobs write a small status document (`ops_status`) after every run, which is where the backup age
comes from.

## Cost on the micro VMs

- Nightly job: a few hundred page reads for 20,000 riders, mostly small documents; `rider_scores` pages are 100
  documents. Typical run: seconds to a few minutes. Peak memory: about 10 MB per 100,000 riders with rides.
- Daytime: the app-open counter is a map lookup per `/api/me`; one small insert per node every 10 minutes.
- Pages read the stored aggregates (one document each). The at-risk page joins 50 riders per view.

## What waits for vm5 (Ampere A1, 2 OCPU / 12 GB)

| Idea | Why it waits |
|---|---|
| Popular corridors and weekend routes, route difficulty labels | Need map matching (Valhalla) |
| Per-road-segment products, stop demand at fuel / food places | Segment data and partner terms |
| Larger models (per-rider next-ride prediction, lifetime value) | More memory and CPU than a micro has to spare |
| Counting phone-only offline trips as rides | Trip documents carry the track; reading them nightly is too heavy for a micro |
| Seasonal and festival trends over years | Long history scans |
| Insurer / fleet reports | Legal review and contracts first |

## Tests

`gateway/test/business_brain_356.test.js` (cohorts, funnel, conversion, revenue, authorisation, batching, memory
caps), `business_churn_356.test.js` (rules, model, list, consent, win-back, erase), `business_sendtime_356.test.js`
(histograms, open counter bounds, clicks, best-time campaigns and quiet hours), `business_signals_356.test.js`
(each signal, no automatic block, review decisions, cap), `business_summary_356.test.js` (time, once per week,
recipients, switch, template), `business_servers_356.test.js` (parsing, thresholds, peer, jobs, backups, API).
