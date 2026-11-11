# CoRoute Partner Program

*Real-world perks for riders at garages, hotels, dhabas and gear shops along their routes, curated by CoRoute.*

Version: CoRoute 3.56 · November 2026 · Status: **built parts marked "Built", future parts marked "Planned"**

---

## 1. What the program is

CoRoute riders stop for fuel, food, rest and repairs on almost every ride. The Partner Program lets businesses that serve riders offer them a **real-world perk**, for example "10% off a chain service at <garage> for CoRoute riders". CoRoute **curates** every perk: CoRoute chooses and checks partners and writes the message that riders receive.

What partners get:
- reach to riders who choose to hear about perks;
- a mention on CoRoute's website board;
- co-marketing with clubs and operators that ride on CoRoute.

What riders get: useful, honest perks, never pushed during a ride emergency, and only if they turned perks on.

## 2. What is built today (3.56)

### 2.1 Partner perk notifications (Built)
- **Who sends**: only CoRoute administrators, from the CoRoute web admin. Partners and operators cannot send perk notifications themselves.
- **Opt-in only**:
  - riders receive perks only if they turn on **Partner perks** in the app (**Settings > App & privacy**). It is **off by default**;
  - perks have their own Android notification channel, "Partner perks", set to low importance.
- **Labelled**: the phone shows **"Partner perk · <partner name>"**.
- **Curated**: the admin must name the partner (2 to 60 characters) and confirm "CoRoute curated this perk". Without that confirmation the perk cannot be sent.
- **Frequency**: at most **one partner perk per rider every 7 days**, on top of CoRoute's daily notification cap.
- **Never during safety moments**: safety alerts are separate notifications that riders cannot turn off, and perks never replace or delay them.

### 2.2 Website board: "Latest from CoRoute" (Built)
- CoRoute admins publish posts on the CoRoute website: the home page shows the latest 3, and **/updates** shows them all. The kinds are *update*, *offer*, *safety tip* and *event*.
- A post can feature a partner, a partner event or a club ride, with a title (up to 80 characters), text (up to 600), an optional image, a publish window and an optional pin.
- Links in a post may point **only to pages of the CoRoute website**, never to an outside site.
- Board posts are **website only**. They are never pushed to the app.

### 2.3 Offer e-mails (Built, consent-based)
- CoRoute can send offer e-mails **only to riders who opted in** on their website account ("Send me offer e-mails", off by default).
- Every e-mail has a one-click unsubscribe, and unsubscribed or bounced addresses are never mailed.
- These e-mails are CoRoute's channel for **CoRoute plan offers**. A partner may be mentioned in one with CoRoute's agreement. Links stay on the CoRoute website.

## 3. Play-safe rules (why some words are refused)

CoRoute is distributed on Google Play. To stay within Play's rules on payments and notifications, CoRoute separates **real-world partner perks** from **CoRoute's own plans**:

| Channel | Allowed | Never allowed |
|---|---|---|
| **Partner perk notification** | The words "% off", "offer", "deal", "discount" and "sale", about a real-world perk at a named partner | ₹ / Rs amounts, "price", "buy", "pay", "checkout", "subscription", "coupon", "promo code", "voucher", "code", any mention of CoRoute plans or membership, any link or web address |
| **Operator broadcasts and ride announcements** | Ride news and safety information | Prices, offers, coupons and buying words of any kind, phone numbers, e-mail addresses |
| **Website board** | Updates, events, safety tips, offers, partner features | Links to other websites |
| **Offer e-mail** (opted-in riders only) | CoRoute plan prices, coupons, partner mentions agreed with CoRoute | Mail to anyone who did not opt in or who unsubscribed |

**Key rule:** CoRoute plan prices and coupons **never** appear in a push notification. They appear only on the website and in opted-in offer e-mails.

A perk text that breaks these rules is refused by the server before sending. The admin sees a message that points to the offer e-mail instead.

## 4. How a partner gets listed (today)

1. **Contact CoRoute**: [OWNER TO FILL: partner contact e-mail / form].
2. **Suitability check by CoRoute**. Suggested criteria, [OWNER TO CONFIRM]:
   - a genuine business that serves riders (garage or service centre, fuel, food, stay, gear, riding academy);
   - valid registration (GST where applicable);
   - a real, honourable perk, with clear terms and an end date;
   - no alcohol, gambling or unsafe-riding themes.
3. **Agreement**: [OWNER / LEGAL TO FILL: partner terms, covering perk liability, honouring the perk, the validity period, brand usage and termination].
4. **CoRoute writes the perk message**, in line with section 3, and schedules it. Partners see no rider data: no names, numbers or locations.
5. **Website feature** (optional): CoRoute publishes a board post about the partner.

Commercial terms: [OWNER TO FILL: free during launch, listing fee or other. No numbers are promised here].

## 5. Co-marketing with clubs and operators

- **Club and operator rides** can be featured on the CoRoute website board as *event* posts (written by CoRoute), with a link to the ride's public sign-up page on the CoRoute website.
- **Operators** may mention a partner stop in a ride's **notes** (for example "Breakfast at <dhaba>"). Notes appear on the public ride page and must not contain prices, phone numbers or e-mail addresses.
- **Broadcasts** from operators must stay free of offers and buying words (section 3). Operators should not use broadcasts to promote partner deals.
- **Joint content** (photos, ride stories, social posts) needs written agreement from every party shown, and riders' consent for any photo of them.

## 6. Brand usage rules

[OWNER TO CONFIRM, suggested rules:]
- Use the CoRoute name and logo only as supplied by CoRoute, unaltered, with clear space around it.
- Write **CoRoute** (capital C and R), never "Coroute", "Co-Route" or "CR".
- Allowed wording: "Partner of CoRoute", "Perk for CoRoute riders", "We ride with CoRoute".
- Not allowed:
  - implying CoRoute endorses a product's safety or quality;
  - implying CoRoute guarantees emergency response;
  - using CoRoute's name in pricing claims;
  - using CoRoute's brand on alcohol, gambling or unsafe-riding content.
- Never state or imply that CoRoute shares rider data with partners. **It does not.**
- Partners may not contact riders using any information obtained through CoRoute. CoRoute does not provide any such information.
- Remove CoRoute branding within [OWNER TO FILL] days after the partnership ends.
- Brand assets and colours: teal #2B7A8C, amber #D9822B. [OWNER TO FILL: link to the logo pack.]

## 7. Planned (not built yet)

These items are on CoRoute's release plan for **v3.57** and are **not available today**:
- **Partners on route**:
  - partner places on the map and in route essentials, with a "Partner offer" tag;
  - offer cards shown only when the rider is stopped or planning, never while moving and never during an SOS or crash;
  - partners never rank above the nearest hospital, and cannot edit rider reviews.
- **Redemption page** for partners (`/partner`): riders show a code and the partner marks it used. Partners see counts and times only, never who.
- **Single-use perk codes** tied to rider levels ("Perks"). Partners never see a rider's score.
- **Partner accounts** with approval, audit and, later, billing and GST invoices.

---

*Questions: [OWNER TO FILL]. CoRoute never sells rider data.*
