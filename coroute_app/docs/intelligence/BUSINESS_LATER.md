# Business analytics for later (not built in round 4)

Safety came first; these reuse the round 4 aggregates (consented, k-anonymous, decayed) and fit the micro VMs unless
noted. Each needs an owner decision and a privacy check before building. No raw tracks, no individual profiles.

| Idea | Uses | Value | Notes |
|---|---|---|---|
| Popular riding corridors and weekend routes | `rd` cells (distance by time bucket) | Plan partner offers, events, club rides | k ≥ 5 per cell; show as heat bands, never routes of a person |
| Stop demand at fuel / food places | `st` cells with place match | Partner perks for highway dhabas and pumps (Partner perks are off by default) | Needs partner terms; counts rounded |
| Club / operator dashboards: their own group rides' safety stats | rider score + trip reports (already per ride) | Value for paid operators | Only their own rides; opt-in per club |
| Fleet safety index (rental / corporate) | hazard and hard-brake rates per fleet ride | B2B feature for operators | Contract and consent of fleet riders first |
| Route difficulty labels (twisty, rough, fuel gaps) on public rides | `rd`, `rq`, fuel gaps | Better discovery, premium planner later | Website shows only labels |
| Seasonal and festival riding trends | `dt` + `rd` time buckets | Marketing timing, server capacity planning | Aggregate only |
| Insurer data partnership (aggregate road risk by region) | `hz`, `dt` | Possible revenue | Legal review, DPDP purpose limitation; never per-rider data without explicit consent |
| Product analytics: which warnings riders mute | phone counters (not collected today) | Tune warnings | Would need a new consented counter |
| Capacity forecast | ride starts per hour | When to move to the A1 | Already visible in admin analytics |

Out of scope on the micro VMs: per-road-segment products (need Valhalla / map matching on the A1), any raw-track
product, weather-linked products (need a licensed weather source).
