# Operator Console Manual

*Every screen, button, limit and message in the CoRoute Operator console (3.56).*

Version: CoRoute 3.56 · November 2026 · Console address: **/operator** on the CoRoute website

---

## 1. Who can use the console

| Role | How you get it | What you can do |
|---|---|---|
| **Owner** | Your application was approved | Everything, including adding and removing co-organisers and removing any rider. |
| **Co-organiser** | The owner made you one (from the roster) | Everything except managing co-organisers. You can remove members but not other co-organisers. |
| **Member** (rider) | Accepted an invite or joined by link | No console access. Uses the app and **/clubs**. |

**Account states**

| State | What happens in the console |
|---|---|
| **Approved** | Full access within your limits and features. |
| **Expired** (past the "valid until" date) | A banner: "This operator account expired on <date>. You can read your reports; ask CoRoute to extend it to run rides again." Reads work, and every change is refused. |
| **Suspended** | The console shows **Account suspended**: "The CoRoute team suspended this operator account. Live rides already under way keep their safety features." The reason is shown if one was given. |
| Console turned off by CoRoute | Sign-in shows "The operator console is turned off for now." Live rides are not affected. |

---

## 2. Sign-in screen

| Element | Behaviour |
|---|---|
| **Email or callsign** | Your CoRoute account e-mail or callsign. |
| **Password** | Your CoRoute password. |
| **Sign in** | Shows "Signing in…" while it works. Errors include "Enter your email or callsign and password." and "Too many attempts. Wait a few minutes and try again." |
| **Apply for the console** | Link to /operators/apply. |
| Idle sign-out | "You were signed out after 60 minutes without activity." |
| Session ended | "Your session has ended. Please sign in again." |

If you are already signed in to the CoRoute website in the same browser tab, that session is used. Your session token is kept only in this browser tab (sessionStorage), and closing the tab ends it.

**No operator screen** (signed in, but not an operator):
- **No operator account**: "This account does not run an operator account and is not a co-organiser of one." Buttons: **Apply for the console**, **Sign out**.
- **Application waiting for review**: "The CoRoute team is reviewing "<name>". You can sign in here once it is approved." Button: **See your application**.
- **Application not approved**: "Your application "<name>" was not approved. Reason: …"

## 3. Layout

- **Side bar**:
  - the CoRoute **Operator** brand;
  - the operator selector, shown only if you belong to more than one operator. Co-organiser accounts are marked "(co-organiser)";
  - the navigation: **Overview, Roster, Rides, Live map, Attendance & reports, Broadcasts**;
  - your name and @username;
  - the theme selector (**Auto / Light / Dark**) and **Sign out**.
- **SOS badge**: a red **SOS** next to *Live map*, checked every 15 seconds whichever page you are on. It means at least one rider in one of your live rides has an open SOS or crash alert.
- **Messages** appear at the bottom: green for confirmations, red for errors.

---

## 4. Overview

**Header**:
- the organisation name, then type · city · "You own this account" or "You are a co-organiser";
- buttons: **Schedule a ride** (goes to Rides) and **Open live map**.

**Tiles** (with a usage bar where there is a limit):

| Tile | Shows |
|---|---|
| **Roster** | members / roster limit, and "n invites waiting". |
| **Rides this month** | rides scheduled, live or done this month / monthly limit. |
| **Live now** | live rides / concurrent limit. |
| **Riders per ride** | your per-ride limit (lead included). |
| **Co-organisers** | used / limit. |

**Your plan**: "Set by CoRoute when your account was approved. Valid until <date>." Below it, each feature is listed as **On** or **Off**:
- Multi-group live dashboard;
- Roster & emergency contacts during an SOS;
- Attendance;
- Ride calendar & public sign-ups;
- Broadcast messages to the roster;
- Export reports (CSV).

**Invite riders**: your invite link with a **Copy** button. When the link is turned off, the card says so. A privacy note sums up what you can see.

---

## 5. Roster

**Header**: "<n> riders · <n> invites waiting · up to <limit> (invites count)".

### Invite by username
- **Usernames** field: separate usernames with commas or spaces.
- **Send invites**: disabled when the roster is full or the account is not writable.
- **Result message**, for example "2 invited, 1 not found.":

| Result | Meaning |
|---|---|
| invited | An invite was sent (in-app crew invite plus a push). |
| already invited | An earlier invite is still waiting. |
| already on the roster | Nothing to do. |
| not found | No CoRoute account has that username. |
| not sent (roster full) | The roster limit was reached during this batch. |

- An invite expires after **14 days**. You can send up to **300 invites a day** ("Too many invites today. Try again tomorrow.").

### Invite link

| Button | Effect |
|---|---|
| **Copy** | Copies `/clubs/join/<code>`. |
| **New link** | Makes a new code. The old link stops working. Message: "New invite link ready." |
| **Turn off** | Disables the link. Message: "Invite link turned off." |
| **Turn on** | Enables the link again. |

A rider opening a dead link sees "This club link does not work any more." A rider who has blocked the owner, or whom the owner has blocked, also gets that message.

### Riders table
Columns: **Username, Name** (first name), **Role** (Owner / Co-organiser / Member), **Joined, Via** (Invite / Link).

| Button | Who | Effect |
|---|---|---|
| **Make co-organiser** | Owner | Grants console access. Disabled at the limit ("Co-organiser limit reached"). |
| **Make member** | Owner | Removes the co-organiser role. |
| **Remove** | Owner (anyone except the owner), co-organiser (members only) | Asks to confirm: "They leave your roster and stop getting your ride invites. They can be invited again." |

### Waiting for an answer
Columns: Username, Sent, Expires. **Cancel invite** removes the invite and frees a roster place.

---

## 6. Rides

**Header**:
- "<n> of <limit> rides this month · <n> of <limit> live · up to <n> riders per ride";
- **New ride**.

**Table columns**:
- **Ride**: name, meeting point → destination, and a **Public page** link if there is one;
- **Starts (IST)**;
- **Status**;
- **Roles**: lead and sweeper;
- **Seats**;
- the actions.

**Status and actions**

| Status | Actions |
|---|---|
| **Scheduled** | **Start**, **Announce**, **Edit**, **Cancel**, and **Sign-ups (n)** if the ride has a public page |
| **Live** | **Invite roster**, **Live map**, **Roles**, **End**, **Attendance** (if in plan), **Sign-ups** |
| **Ended** | **Attendance** (if in plan) |
| **Cancelled** | none |

**Seats column**:
- Scheduled: "12 seats", or with a public page "3 / 12 booked" (the lead counts);
- Live: "5 / 10 riding".

### New ride / Edit ride dialog

| Field | Rule (message if wrong) |
|---|---|
| Ride name | 3 to 80 characters ("Ride name: 3 to 80 characters.") |
| Starts (India time) | Within the next year ("Pick a start date and time within the next year.") |
| Riders | At least 2 ("At least 2 riders."). At most your limit ("Your plan allows up to <n> riders per ride."). |
| Meeting point, Destination | Up to 120 characters each |
| Lead rider | On your roster. The default is you. |
| Sweeper | Optional, on your roster ("joins as sweeper") |
| Notes | Up to 500 characters. No phone numbers or e-mail ("Keep phone numbers and e-mail addresses out of the public notes.") |
| Public sign-up page on the CoRoute website | Only with "Ride calendar & public sign-ups". Otherwise the label says "(not in your plan)". |
| I approve each sign-up | On by default |

Buttons: **Cancel**, and **Schedule ride** or **Save**. Only a scheduled ride can be edited ("Only a scheduled ride can be changed.").

### Start
- Confirmation: "A CoRoute group ride starts with @lead as lead and trip owner (it shows on their phone). Up to <n> riders. Then use "Invite roster"."
- Result: "Ride started with <n> seats."
- The ride is a normal CoRoute group ride. Its seats come from your operator limits, not from anyone's personal plan. Riders join free, and all group features are available.
- The assigned sweeper gets the Sweeper role when they join.

### Announce (scheduled) and Invite roster (live)
- **Announce**: "Your roster gets a notice with the ride name, date and meeting point." → "Announced to <n> riders." The notice is a "Community update" in the app.
- **Invite roster**: "Every roster rider not yet in the ride gets a ride invite in the app, while seats last." → "<n> invites sent."

### Roles (live)
- Dialog **Riding role**: **Rider** (username) and **Role** (**Sweeper**, **Lead** or **Middle (pack)**).
- The rider must be in the ride. "The group sees the change at once."

### End
"The ride ends for every rider in it, as when the trip owner ends it in the app." → "Ride ended."

### Cancel
"Riders who signed up see it as cancelled. It no longer counts against your monthly rides." A live ride cannot be cancelled: end it instead.

### Sign-ups dialog
- Shows "<taken> of <max> seats taken (lead included) · <n> waiting".
- Rows: username, first name, status (**Waiting**, **Approved**, **Declined**), time.
- Buttons: **Approve** and **Decline**.

**What the rider sees on the public page** (`/rides/<slug>`):
- the operator, the start time in IST, **Meet at**, **Ride to**, **Run by**, your notes and the seats left;
- the button: **Sign in to sign up**, **Sign up** or **Ask to join**;
- after signing up:
  - "Waiting for approval": "The organiser will approve or decline your sign-up.";
  - "You are in": "Your seat is held. The join code appears here when the ride starts.";
  - **Cancel my sign-up**;
- once the ride is live, approved riders see "The ride is live. Open CoRoute and join with this code:" with the 6-digit code and **Open in the app**.
- Closed states: "Sign-up is closed.", "This ride is full.", "The organiser did not approve your sign-up.", "This ride has ended.".

---

## 7. Live map

**Header**:
- with the multi-group feature: "Every live ride of <name> on one map. Updates every 5 seconds.";
- without it: "One live ride at a time (the multi-group dashboard is not in your plan)";
- **Fit all** zooms to all markers.

**Ride cards (left)**:
- the ride name and a chip: **Live**, **Paused** or **SOS**;
- "riders / seats · started <time> · to <destination>";
- one row per rider: role (**L** lead, **S** sweeper, **·** pack), @username, an **SOS** chip if their alert is open, speed and "x s ago";
- click a card to focus the map on that ride, and click again to show all.

**Map (right)**:
- OpenStreetMap tiles, one colour per ride;
- markers show L / S or the rider's initial;
- faded means no signal for 5 minutes;
- SOS markers are red and pulse;
- **+ / −** buttons to zoom.

**SOS banner**:
- for each open alert, a red banner at the top: "SOS: @rider in <ride> · <time ago>" or "Crash alert: …";
- if your plan includes emergency contacts, the banner has a button **Emergency contact**.

**Emergency contact dialog** ("SOS · <ride>"):
- "Emergency contact of @rider": the name and phone, which can be tapped to call on a phone. If none is saved, it says "No emergency contact saved.";
- **Rider's phone**, if saved;
- **Medical info**: blood group, allergies and notes, if the rider saved them;
- **Last position**: latitude and longitude;
- the note "Shown because of an open SOS. This view was recorded in the audit log. Call 112 first in a life-threatening emergency."

If you try to open it after the SOS has closed: "Emergency contacts are shown only while that rider has an open SOS."

---

## 8. Attendance & reports

This page needs the **Attendance** feature. Without it: "Attendance is not part of your plan. Ask CoRoute to add it."

**Header**:
- "Who joined and finished, distance and incidents, per month (India time). No home locations, no tracks.";
- the **month** picker;
- **Export CSV**, disabled without the export feature ("Export is not in your plan").

**Monthly tiles**:
- **Rides run** ("n still scheduled · n cancelled");
- **Riders joined**;
- **Finished** ("x% of riders");
- **Distance**;
- **Incidents**.

**Rides table**: Ride, Date, Status, Joined, Finished, Distance, Incidents. Click a row for the attendance of that ride.

**Attendance dialog** (one ride):
- tiles: Joined, Finished, Distance (all riders), Incidents;
- for each rider: Rider, Role, Joined, Left, Result (**Finished** or **Left early**), Distance, Incidents;
- an incident list: time · type · @rider · outcome;
- the note "No home locations or tracks are shown here or in the export: names, times, distance and outcomes only."

"Finished" means the rider arrived at the destination, or was still in the ride when it ended. Distance comes from the stored tracks.

**CSV export** (`coroute-YYYY-MM-attendance.csv`, UTF-8):
- columns: `ride, ride_date_ist, status, username, first_name, role, joined_ist, left_ist, finished, distance_km, incidents`;
- no coordinates, phone numbers or e-mail addresses;
- cells are protected against spreadsheet formula injection;
- each export is recorded in the audit log.

---

## 9. Broadcasts

This page needs the **Broadcast** feature. Without it: "Broadcasts are not part of your plan. Ask CoRoute to add them."

**New message**:
- **Title**: up to 60 characters;
- **Message**: up to 300 characters;
- **Send to roster**. The result: "Sent to <n> riders."

Riders get a notice in the app ("Community update") and see the broadcast on /clubs. A rider whose phone blocks notifications may miss the push, but the broadcast stays listed on /clubs.

**Sent**: earlier messages, with time · riders · by @username.

**Rules** (the server refuses a message that breaks them):

| Rule | Message |
|---|---|
| Title and message at least 3 characters | "Write a title and a message." |
| No prices, offers, coupons or buying words, in line with Google Play policy for app notifications | A message naming the word that was refused |
| No phone numbers or e-mail addresses | "Leave phone numbers and e-mail addresses out of broadcasts." |
| Up to 5 a day | "Up to 5 broadcasts a day." |

The same Play-policy check applies to the text of **Announce**.

---

## 10. Limits and error messages in plain language

| Code | When | What to do |
|---|---|---|
| `ROSTER_FULL` | "Your roster is full (<n> riders, counting invites waiting for an answer)." Riders using your link see "This club is full." | Cancel waiting invites, remove inactive riders, or ask CoRoute for a higher limit. |
| `RIDES_PER_MONTH_LIMIT` | "Your plan allows <n> rides a month; <YYYY-MM> is full." | Cancel a ride you will not run (cancelled rides do not count), move the ride to another month, or ask CoRoute. |
| `RIDERS_PER_RIDE_LIMIT` | "Your plan allows up to <n> riders per ride." | Lower the number, or split into two rides (A and B groups), each with its own lead and sweeper. |
| `CONCURRENT_RIDES_LIMIT` | "Your plan allows <n> live rides at a time. End one first." | End a finished ride, or ask CoRoute. |
| `CO_ORGANISER_LIMIT` | "Your plan allows <n> co-organisers." | Make a co-organiser a member first. |
| `RIDE_FULL` / `CONVOY_FULL` | "This ride is full." (sign-ups, invites, joining) | The seats are taken. Raise **Riders** before the start (up to your limit), or run a second ride. |
| `SIGNUPS_FULL` | "This ride has too many sign-ups waiting. Try again later." | Approve or decline the waiting sign-ups. |
| `NOT_IN_PLAN` | "<feature> is not part of your plan." | Ask CoRoute to add the feature. |
| `OPERATOR_SUSPENDED` | "This operator account is suspended." (with reason) | Contact CoRoute. Live rides keep running. |
| `OPERATOR_EXPIRED` | "This operator account has expired. Contact CoRoute to extend it." | Reports stay readable. Ask CoRoute to extend. |
| `OWNER_ONLY` | "Only the account owner can do this." | Ask the owner. |
| `NOT_A_MEMBER` | "Co-organisers are picked from your roster. Invite the rider first." / "This rider is not on the roster." | Invite the rider first. |
| `LEAD_UNAVAILABLE` | "The lead rider account is not available. Pick another lead." | Edit the ride and choose another lead. |
| `LEAD_NOT_ON_ROSTER` | "The lead must be on the roster to invite it." | Re-invite the lead to the roster. |
| `RIDE_NOT_SCHEDULED` | "Only a scheduled ride can be changed." / "…cancelled. End a live ride instead." / "This ride is not waiting to start." | Check the ride status. |
| `RIDE_NOT_LIVE` / `RIDE_ENDED` / `RIDE_NOT_STARTED` | "This ride is not live." / "This ride has ended." / "This ride has not started yet." | Check the ride status. |
| `BAD_ROLE` | "Role must be LEAD, SWEEPER or PACK." / "Assign LEAD or SWEEPER before the ride." | Choose a valid role. |
| `NO_ACTIVE_SOS` | "Emergency contacts are shown only while that rider has an open SOS." | Nothing to do. The SOS is closed. |
| `PLAY_POLICY` | The broadcast or announcement contains a refused word. | Remove prices, offers and buying words. |
| `CONTACT_IN_TEXT` | "Leave phone numbers and e-mail addresses out of broadcasts." | Remove them. |
| `BROADCAST_LIMIT` | "Up to 5 broadcasts a day." | Wait until tomorrow (India time). |
| `EMPTY_MESSAGE` | "Write a title and a message." | Fill both fields. |
| `NO_INVITEES` | "Enter at least one username." | Type a username. |
| `LINK_GONE` | "This club link does not work any more." | Share the current link (Roster > Invite link). |
| `RATE_LIMITED` | "Too many requests. Wait a minute." / "Too many changes. Wait a minute." | Wait a minute. |
| `FEATURE_OFF` | "This feature is turned off for now." | CoRoute has paused the console. Live rides are not affected. |

---

## 11. Privacy rules for operators

**You can see**:
- usernames, first names, roster role and join date, and how each rider joined (invite or link);
- during **your own live rides**: positions, speed, battery level, last update and riding role;
- attendance: joined or left times, finished, distance, incident type, time and outcome;
- **during an open SOS in your ride only**, with the emergency-contact feature: the emergency contact (name, phone), the rider's phone, the medical info and the last position.

**You never see, through CoRoute**:
- riders' phone numbers, e-mail addresses or medical info outside an open SOS;
- positions outside your live rides, home locations, or stored tracks on a map;
- coordinates in reports or CSV files;
- riders' plans or payments.

**Your obligations** (see *Operator Terms (DRAFT)* and *Data Processing Note (DRAFT)*):
- open the emergency contact only to help that rider in that emergency;
- do not copy, store or share medical info or contacts beyond what the emergency needs;
- keep exported CSV files secure and delete them when you no longer need them;
- respect a rider's decision to leave the club.

**Riders' controls**:
- leave the club at any time (**Leave** on /clubs, or leave the crew in the app);
- decline invites;
- cancel a sign-up;
- deleting the account removes the rider from your roster and sign-ups.

## 12. Audit

CoRoute records these actions with the time and the account that did them:

| Area | Actions recorded |
|---|---|
| Account | applied, approved, rejected, suspended, reinstated, limits changed |
| Roster | invites sent, rider removed, invite link changed, co-organiser added or removed |
| Rides | created, updated, cancelled, started, announced, roster invited, ended, role changed |
| Sign-ups | approve or decline decisions |
| Safety and data | **emergency contact viewed during an SOS** (rider, ride, alert), **report exported** (month) |
| Messages | broadcast sent |

The audit log is kept by CoRoute and is not shown in the console. If you need an extract, for example after an incident, contact CoRoute (see *Support and Escalation*).

---

## 13. Members' side (for reference)

| Page | What riders do |
|---|---|
| App, **People > Requests** | Accept or decline your club invite (it shows as a crew invite). |
| App, ride invites | Accept your ride invite after **Invite roster**. |
| **/clubs** | See invites (**Join** / **Decline**), clubs they are in, upcoming rides with sign-up links, your latest broadcasts; **Leave**; join with an invite link. |
| **/clubs/join/<code>** | "Join club" card: "Joining shares your username and first name with the organiser, and your live position only during their rides. Your phone, e-mail and medical ID stay private." |
| **/rides/<slug>** | Public ride page and sign-up. |
