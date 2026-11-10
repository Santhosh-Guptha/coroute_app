# Crews and crew polls (3.55)

A **crew** is a standing circle of riding friends. Riders create a crew, invite their friends, and plan rides with **polls**. A crew has no chat: the only thing members can post is a vote.

## Why "Crews"

The UX naming guide (`docs/UX_NAMING_GUIDE_v3.55.md`) already uses **group** / **group ride** for the people in a live ride ("Group spread", "Pause group ride", "Your group"). The plan names "Small Group" and "Large Group" also use the word. A standing circle therefore gets its own word: **Crew** ("Crews", "Create a crew", "Crew admin", "Co-admin", "Leave crew"). Proposed row for the guide:

| Concept | Use | Avoid |
| --- | --- | --- |
| A standing circle of friends, outside a ride | **Crew** (crew admin, co-admin, member) | group, club, community (in UI text) |

## Gateway files

| File | What it holds |
| --- | --- |
| `gateway/src/crews.js` | Storage, limits and rules: crews, members, invites, polls, votes, tally, account-erase cleanup |
| `gateway/src/crew_routes.js` | `registerCrewRoutes`: REST, views (privacy), socket pushes, rate limits, admin moderation, switches, erase hook |
| `gateway/test/crews_polls_355.test.js` | Gateway tests |

Small additive edits to shared files:

- `routes.js`: one `registerCrewRoutes(...)` line after the social routes, and one `registerCrewRideInviteRoutes(...)` line after it (crew rides, below).
- `feature_flags.js`: three Community switches, `crews`, `crewPolls` and `crewRides`. All are on by default.

Collections are created on first use (`ensureCrewStore`). `repo.migrate()` is unchanged.

| Collection | Document | Unique |
| --- | --- | --- |
| `crews` | `{crewId, name, description, adminId, settings:{membersCanCreatePolls}, memberCount, createdAt, updatedAt}` | `crewId` |
| `crew_members` | `{memberKey, crewId, userId, role: ADMIN, CO_ADMIN or MEMBER, joinedAt, addedBy}` | `memberKey` = `<crewId>\|<userId>` |
| `crew_invites` | `{inviteId, inviteKey, crewId, userId, invitedBy, createdAt, expiresAt}` | `inviteId`, `inviteKey` |
| `crew_polls` | `{pollId, crewId, createdBy, question, options:[{id,text}], multi, anonymous, template, status, createdAt, closesAt, closedAt, closedBy}` | `pollId` |
| `crew_votes` | `{voteKey, pollId, crewId, userId, optionIds, at, erased?}` | `voteKey` = `<pollId>\|<userId>` |

## Limits (`crews.LIMITS`)

| Limit | Value |
| --- | --- |
| Crew name | 3-40 characters after cleaning, with at least one letter or digit |
| Description | up to 200 characters |
| Crews one rider runs (as admin) | 10 |
| Crews one rider is in (any role) | 30 |
| Riders per crew | 100. Invites waiting for an answer count while inviting. |
| Co-admins per crew | 3 |
| Invite lifetime | 14 days |
| Names per invite request | 20 |
| Poll question | up to 120 characters |
| Poll options | 2-6, each 1-60 characters, no duplicates (case ignored) |
| Poll deadline | 10 minutes to 30 days. The default is 3 days. |
| Open polls per crew | 10 |
| Closed polls kept per crew | the newest 50. Older ones are deleted with their votes. |

**Text cleaning:** this applies to names, descriptions, questions and options.

- Control, zero-width and bidi characters become spaces. `<` and `>` are removed. Whitespace is collapsed.
- **Refused:** phone numbers (7 or more digits), e-mail addresses and links (`CREW_TEXT_CONTACT`).
- **Profanity:** the username list is reused. A few strong words are refused anywhere. The rest are refused only as whole words, so "Essex" and "Cockpit" are allowed.

## Roles

| Can | Admin | Co-admin | Member |
| --- | --- | --- | --- |
| Invite friends, cancel invites | yes | yes | no |
| Start polls | yes | yes | only when the crew setting "Members can create polls" is on (default off) |
| Close or delete a poll | yes | yes | only polls they started |
| Remove riders, change roles, hand over, rename, settings, delete crew | yes | no | no |
| Leave | yes (hands over) | yes | yes |

## Rules (validated scenarios)

**Inviting**

- Only the admin and co-admins can invite. A member who tries gets `403 NOT_CREW_ADMIN`.
- Only **mutual friends of the person inviting** can be invited (`friends.areFriends`).
- An invite is refused when the invitee and the inviter have blocked each other (either way). It is also refused when the invitee and the crew admin have blocked each other (either way).
- There is no adding by phone or e-mail and no stranger search. The invite picker lists only my friends.

**No enumeration**

These cases all get the **same** `404 {code:'NOT_A_FRIEND'}`:

- an unknown username;
- a rider who is not my friend;
- a rider blocked either way;
- a suspended account.

**Idempotent invites and accepts**

| Situation | Answer |
| --- | --- |
| Invite sent | `201 INVITED` |
| Friend already invited | `200 ALREADY_INVITED` |
| Friend already a member, or myself | `200 ALREADY_MEMBER` |
| Invite accepted again after joining | `404` (the invite is gone). The membership stays. |

**The friend accepts or declines**

- Nobody joins a crew without accepting.
- At accept time, the gateway checks again that the inviter is still a member and still a friend, and that there is no block with the inviter or the admin. If any check fails, the invite is dropped: `410 INVITE_GONE`.

**Expiry:** an invite expires after 14 days.

- An expired invite is hidden and deleted on the next read.
- Accepting it answers `410 INVITE_EXPIRED`.
- It can be sent again.

**Friendship removed after joining:** the rider **stays a member**. Friendship is a rule for inviting only. The admin can remove the rider. Blocking another member does not remove anyone either; the admin decides.

**Suspended or deleted accounts**

- A suspended account (`status: 'BLOCKED'`) is removed from the crew on the next crew read.
- A deleted account is removed by the erase hook.
- If that rider was the admin, the admin role moves on as described under "Leaving and handing over".

**Crew full:** members plus waiting invites at 100 gives `409 CREW_FULL` when inviting. Accepting into a full crew gives `409 CREW_FULL` and the invite is kept.

**Limits reached**

| Situation | Answer |
| --- | --- |
| Creating an 11th crew as admin | `409 CREW_LIMIT` |
| Joining a 31st crew | `409 TOO_MANY_CREWS` |
| A 4th co-admin | `409 CO_ADMIN_LIMIT` |
| An 11th open poll | `409 TOO_MANY_OPEN_POLLS` |

**Leaving and handing over**

- The admin can hand the crew to any member with `POST /transfer`. The old admin becomes a co-admin if a seat is free, otherwise a member.
- An admin who leaves can name a successor (`transferTo`). Otherwise the **oldest co-admin**, then the **oldest member**, takes over.
- When the last rider leaves, the crew is deleted with its polls and votes.

**Crew privacy**

- Non-members see nothing.
- Every `/crews/:crewId...` route answers non-members exactly like an unknown crew: `404 CREW_NOT_FOUND`.
- Waiting invites are shown to the admin and co-admins only.

**Member rows** carry `username`, `displayName` (first name only), `avatarUrl` (null if that rider blocked me, or when the `profilePhotos` switch is off), `role` and `joinedAt`. They **never** carry phone, e-mail, medical info, location or userId. This follows the social privacy rules in `usernames_friends_profiles.md`.

**Rate limits (per rider)**

| Action | Limit |
| --- | --- |
| Create a crew | 20 per hour (refused attempts count) |
| Invite requests | 50 per day |
| Changes | 60 per minute |
| New polls | 30 per day |
| Votes | 60 per minute |
| Reads | 120 per minute |

## Polls

There is no chat and no free-text reply anywhere. A poll is a question with fixed options, and members can only pick options.

- **Choice:** single choice (exactly one option) or multiple choice (1-n distinct options): `multi`.
- **Votes:** named within the crew by default (`anonymous: false`). Named polls show who picked each option, by username and first name. Anonymous polls show counts only. Anonymous votes are still stored per rider, so a rider can change their vote and cannot vote twice. They are never shown.
- **Changing a vote:** members can vote, change their vote (same endpoint) or remove it until the poll closes. After that, voting answers `409 POLL_CLOSED`.
- **Closing:** a poll closes at its deadline. A closed poll is settled lazily on the next read or vote. The creator, the admin or a co-admin can close it early or delete it.
- **Results:** members see `totalVoters` and, per option, `count` and `percent`. The percent is of voters, rounded, so with multiple choice the total can be over 100. They also see `leaders` (one or more, for a tie) and `myVote`.
- **Closed polls:** results stay visible, and the newest 50 closed polls are kept.
- **Template:** `template: 'RIDE_DATE_PLACE'` is a label only. The app fills the question "When shall we ride?" and the next four weekend days as options. There is no extra logic.

## Endpoints (under `/api`, authenticated)

| Method and path | Purpose |
| --- | --- |
| `GET /crews` | `{crews:[{crewId, name, description, memberCount, myRole, admin, openPolls, pendingVotes, nextPollClosesAt, canInvite, canCreatePoll, settings}], invites:[{inviteId, crewId, crewName, description, memberCount, invitedBy:{username, avatarUrl}, createdAt, expiresAt}], limits}` |
| `POST /crews {name, description?}` | Creates a crew; I am the admin. Answers `201 {crew}`. |
| `GET /crews/:crewId` | `{crew, members, invites}` (`invites` only for managers). Removes suspended or deleted riders. |
| `PATCH /crews/:crewId {name?, description?, membersCanCreatePolls?}` | Admin only. |
| `DELETE /crews/:crewId` | Admin only. Deletes polls, votes and invites; members get `CREW_DELETED`. |
| `GET /crews/:crewId/invitable` | Managers: my friends with `status` AVAILABLE, INVITED or MEMBER. |
| `POST /crews/:crewId/invites {username}` or `{usernames:[...]}` | Managers. Single: 201, 200 or 404 (see the rules above). Batch: `{results:[{username, status}]}`. |
| `DELETE /crews/:crewId/invites/:inviteId` | Managers cancel a waiting invite. |
| `POST /crews/invites/:inviteId/accept` and `/decline` | The invitee answers. |
| `POST /crews/:crewId/leave {transferTo?}` | Leave. An admin hands over (see above). |
| `DELETE /crews/:crewId/members/:username` | Admin removes a rider, who gets `CREW_REMOVED`. |
| `PATCH /crews/:crewId/members/:username {role: CO_ADMIN or MEMBER}` | Admin. |
| `POST /crews/:crewId/transfer {username}` | Admin hands the crew to a member. |
| `GET /crews/:crewId/polls` | Polls, newest first, with results. Switch: `crewPolls`. |
| `POST /crews/:crewId/polls {question, options, multi?, anonymous?, closesAt? or durationHours?, template?}` | Creates a poll. Unknown fields (for example a comment) are ignored. |
| `POST /crews/:crewId/polls/:pollId/vote {optionIds}` | Vote or change the vote. Answers `{poll}`. |
| `DELETE /crews/:crewId/polls/:pollId/vote` | Remove my vote. |
| `POST /crews/:crewId/polls/:pollId/close` | The creator, admin or co-admins close the poll early. |
| `DELETE /crews/:crewId/polls/:pollId` | The creator, admin or co-admins delete the poll. |
| `GET /admin/crews?q=&limit=` | Admin console: crews (name search), admin username, members, polls, open polls. |
| `GET /admin/crews/:crewId` | Admin: members (username, role) and polls with counts. |
| `DELETE /admin/crews/:crewId` | Admin moderation. Audited as `crew.delete`; members are told. |
| `DELETE /admin/crews/:crewId/polls/:pollId` | Admin moderation. Audited as `crew.poll.delete`. |

**Error codes:**

- Validation: `CREW_NAME_FORMAT`, `CREW_NAME_NOT_ALLOWED`, `CREW_DESC_FORMAT`, `CREW_DESC_NOT_ALLOWED`, `CREW_TEXT_CONTACT`, `POLL_QUESTION`, `POLL_OPTIONS`, `POLL_OPTION_TEXT`, `POLL_OPTION_DUPLICATE`, `POLL_NOT_ALLOWED`, `POLL_DEADLINE`, `VOTE_INVALID` (all 422).
- Access and invites: `CREW_NOT_FOUND`, `POLL_NOT_FOUND`, `NOT_A_FRIEND`, `NOT_A_MEMBER` (404 or 422); `NOT_CREW_ADMIN`, `NOT_ALLOWED` (403 or 409); `INVITE_EXPIRED`, `INVITE_GONE` (410).
- Limits: `CREW_FULL`, `CREW_LIMIT`, `TOO_MANY_CREWS`, `CO_ADMIN_LIMIT`, `TOO_MANY_OPEN_POLLS`, `POLL_CLOSED` (409); `RATE_LIMITED` (429).
- Switches: `FEATURE_OFF` (403).

## Notifications

Pushes go to the rider's open sockets. When the rider is connected to the other gateway node, `Hub.sendToUser` passes them on. Pushes never carry a userId.

| Push | Fields | When |
| --- | --- | --- |
| `CREW_INVITE` | `inviteId, crewId, crewName, username` (the inviter) | A friend invited me |
| `POLL_CREATED` | `crewId, crewName, pollId, question, username` | A new poll, sent to every member except its creator |
| `POLL_UPDATED` | `crewId, pollId, closed?, deleted?` | A vote, close or delete. Live result bars, never who voted. |
| `CREW_UPDATED` | `crewId, event` | `event` is JOINED, LEFT, REMOVED, ROLE, ADMIN, YOU_ARE_ADMIN or SETTINGS |
| `CREW_REMOVED` | `crewId, crewName` | The admin removed me |
| `CREW_DELETED` | `crewId, crewName` | The crew was deleted |

**In-app badge:** invitations plus open polls I have not answered (`pendingVotes`). It shows on the "Crews" row of My profile and is added to the "My profile & friends" row on the Profile tab. There is no system notification; this follows the friends pattern.

## Admin switches

- `crews` off: every `/crews*` route answers `403 FEATURE_OFF`, and the app hides crews and invitations.
- `crewPolls` off: only the poll routes answer `403`, `canCreatePoll` is false, and the polls section is hidden.
- Admin moderation routes are never behind the switches.

## Account erase

`registerCrewRoutes` wraps `repo.deleteUserCascade` once, guarded by `repo.__crewsCascade`.

- **Crews the rider runs:** handed to the successor (oldest co-admin, else oldest member), or deleted when the rider was alone.
- **Memberships:** removed.
- **Invites:** removed, both those received and those sent.
- **Votes:** in open polls they are removed. In closed polls they are kept as anonymous counts: the userId is replaced, `erased: true` is set, and the vote is never named.
- **Polls the rider created:** they stay, with no creator ("former rider").

## App (Flutter) files

| File | What it holds |
| --- | --- |
| `lib/domain/social/people_models.dart` | `crewHint`, `mergeRequests` (crew invites in the one Requests list), `PeopleBadges`, friend picker filter / select all (tested in `test/people_hub_355_test.dart`) |
| `lib/domain/social/crew_rules.dart` | Pure rules: limits, name, description and poll checks, `checkVote`, `PollTally` (result math), the "Ride date" template, "Closes in" label |
| `lib/data/services/crews_service.dart` | `CrewsService` and its models: list, invites, detail, invitable friends, invite, accept and decline, leave, remove, roles, transfer, settings, delete, polls, vote, retract, close, delete; socket pushes; badge |
| `lib/presentation/social/people_screen.dart` | People hub: the **Crews** segment (Create crew, crew cards with rider count and a hint from `crewHint`: ride invite waiting, polls to vote, "Poll closes in 5 h") and crew invitations under **Requests** (Join / Decline, swipe) next to friend requests and ride invites |
| `lib/presentation/social/crew_create_flow.dart` | "Create crew" in 2 steps (name, then friends to invite with search and "Select all"); `FriendPickerList` shared with the crew invite picker |
| `lib/presentation/social/crews_screen.dart` | Thin redirect kept for old entry points (crew pushes): opens the People hub on Requests (invites waiting) or Crews |
| `lib/presentation/social/crew_detail_screen.dart` | Crew screen with tabs **Members · Polls · Rides** (opens on Polls when a vote waits). Header: Invite friends (and settings for the admin). Members: prominent Invite friends button, riders (tap = profile, ⋮ = admin actions), waiting invites (cancel), leave / delete. Polls: New poll, live result bars (tap to vote; multiple choice: tick and "Save my vote"; "Who voted"). Rides: Start a ride / Invite crew to my ride, ride invites from this crew |
| `lib/presentation/admin/admin_crews_screen.dart` | Admin console: crews list with search, crew detail, delete a poll or a crew |
| `test/crews_polls_355_test.dart` | Dart tests: rules, result math, payload parsing, template, labels |

Wiring (small additive edits):

- `main.dart`: the `CrewsService` provider, next to `FriendsService`.
- `rider_home_screen.dart`: the People tab (bottom bar); its badge adds crew invites and polls to vote (`PeopleBadges`).
- `profile_screen.dart`: a "Friends & crews" shortcut row with the same badge.
- `master_admin_dashboard.dart`: a "Crews" admin row.

The live result bars come from a `POLL_UPDATED` push, which makes an open crew screen reload. Reloads are debounced by 400 ms.

## Crew rides: "Start a ride with this crew"

The host of a live group ride invites chosen crew members; each one accepts (joins the ride) or declines. Built after the first round skipped it: there is **no join code in any crew push or view** on this path, accepting needs no code.

**Who can host:** any crew member (admin, co-admin or member) who is the **trip owner** of the ride (`tripOwnerUserId`, else the creator). The ride's seats follow the host's plan (`convoys._currentCapacity`), so a host without a group plan gets `409 SOLO_TRIP_ONLY`. The trip head cannot invite (owner decision: the trip head only changes the trip's settings).

**App flow (crew screen):** "Start a ride" (switch `crewRides`). With no live ride, the usual ride creation opens (trip planner, plan checks); once the new ride is live the member picker opens by itself (`RideInvitesService.setPendingCrewRide`, `RideInviteHost`; forgotten after 30 min). When I already run a live ride the button reads "Invite crew to my ride" and opens the picker at once. The picker lists the crew members (username, first name, picture; me left out) with "Select all", shows each invite's status (Waiting / Joined / Declined / Expired) and a summary after sending ("2 invited · 1 no seat left").

**Invitee:** `RideInviteScreen` (`lib/presentation/social/ride_invite_screen.dart`, `RideInviteScreen.open(context, inviteId)`, also used for RIDE_INVITE push taps through `PushRouterHost.openRideInvite`): host username, first name and picture, crew name, ride name, start and destination **names** (never coordinates), when it started, riders (`3 of 6 riders`), big Accept / Decline. Accept runs the normal join: profile check, permissions, "Complete your bike" or "I'm riding pillion" (then the pillion's bike pick), `ConvoyService.joinFromRideInvite`, the pre-ride checklist. When the app opens or comes back and an open invite was not shown yet, it opens by itself (once per invite, ids kept on the phone; several: `RideInviteListScreen`); never over a live ride. A `RIDE_INVITE` socket message in the foreground shows a banner with "View". The host gets a snackbar when someone accepts or declines.

| Collection | Document | Unique |
| --- | --- | --- |
| `ride_invites` | `{inviteId, inviteKey, groupId, crewId, fromUserId, toUserId, status: PENDING, ACCEPTED, DECLINED, EXPIRED or CANCELLED, createdAt, expiresAt, answeredAt}` | `inviteId` (`inviteKey` = `<groupId>\|<toUserId>`, one live invite per rider per ride) |

**Rules (gateway `src/crew_ride_invites.js`, tests `gateway/test/crew_ride_invites_355.test.js`):**

| Situation | Answer |
| --- | --- |
| Caller not in the crew (or unknown crew) | `404 CREW_NOT_FOUND` |
| Caller not the ride's trip owner, or unknown ride | `403 NOT_RIDE_HOST` |
| Ride ended | `409 RIDE_ENDED` |
| Host's plan has one seat | `409 SOLO_TRIP_ONLY` |
| No names / more than 50 | `422 NO_INVITEES` / `422 TOO_MANY_INVITEES` |
| Per name: unknown, not in the crew, blocked either way, suspended | `NOT_A_MEMBER` (same answer, no enumeration) |
| Per name: me or already riding | `ALREADY_IN_RIDE` |
| Per name: an open invite exists | `ALREADY_INVITED` (no duplicate) |
| Per name: riders + open invites reach the seats | `RIDE_FULL` |
| Per name: sent | `INVITED` (201 when at least one was sent) |
| Invite older than 12 h, or the ride ended | `EXPIRED` (lazily, on every read); accept answers `410 INVITE_EXPIRED` |
| Declined, cancelled by the host, the inviter or invitee left the crew, a block, the host no longer the trip owner | accept answers `410 INVITE_GONE` |
| Accept into a full ride, while in another active trip, after being removed | the normal join errors (`409 CONVOY_FULL`, `409 ACTIVE_TRIP_CONFLICT`, `403 JOIN_BLOCKED`) |

A declined, expired or cancelled invite can be sent again (the record is replaced). Rate limits: 30 invite requests per hour and 300 names per day per host; 30 answers per minute; reads 120 per minute. Account erase removes the rider's invites both ways.

**Endpoints (under `/api`, authenticated; switches `crews` and `crewRides`, else `403 FEATURE_OFF`):**

| Method and path | Purpose |
| --- | --- |
| `POST /crews/:crewId/ride-invites {groupId, usernames}` | The host invites. `{results:[{username, status, inviteId?}], invites:[host rows], capacity, riders}` |
| `GET /crews/:crewId/ride-invites?groupId=` | The host's rows: `{inviteId, username, displayName, avatarUrl, status, createdAt, expiresAt, answeredAt}` and `rideActive` |
| `DELETE /crews/:crewId/ride-invites/:inviteId` | The host takes back a waiting invite (invitee gets `RIDE_INVITE_UPDATE` CANCELLED) |
| `GET /me/ride-invites` | My open invites: `{inviteId, status, createdAt, expiresAt, host:{username, displayName, avatarUrl}, crew:{crewId, name}, ride:{groupId, name, startName, destinationName, startedAt, status, riders, capacity}}` |
| `GET /ride-invites/:inviteId` | One invite (the invitee or its host; others 404) |
| `POST /ride-invites/:inviteId/accept {rider?}` | Joins through `convoys.joinByCode` with the ride's code kept on the server; `{status: ACCEPTED, convoy}` (the usual join snapshot). Again after joining: the same answer |
| `POST /ride-invites/:inviteId/decline` | `{status: DECLINED}` |

**Notifications:**

| Push | Fields | When |
| --- | --- | --- |
| socket `RIDE_INVITE` | `inviteId, crewId, crewName, rideName, username` (the host), `expiresAt` | to each invitee |
| push (FCM) | `push.notifyUsers([userId], {type:'RIDE_INVITE', title:'Ride invitation', body:'<username> invited you to <ride> with <crew>', data:{inviteId}, priority:'high', ttlSec:1800})` | to each invitee, not awaited, never breaks the request (`hub.push`, see push_notifications.md) |
| socket `RIDE_INVITE_UPDATE` | `inviteId, crewId, status, username` (the invitee) | to the host on accept / decline; to the invitee on cancel |

**App files:** `lib/domain/social/ride_invite_rules.dart` (pure: parsing, app-open check, picker, labels; tests `test/crew_ride_invites_355_test.dart`), `lib/data/services/ride_invites_service.dart` (`RideInvitesService`, provider in `main.dart`), `lib/presentation/social/ride_invite_screen.dart` (`RideInviteScreen`, `RideInviteListScreen`, `RideInviteHost` in `MaterialApp.builder`, `CrewRideInviteSheet`, `startRideWithCrew`), the button in `crew_detail_screen.dart`, `ConvoyService.joinFromRideInvite`. Switch `crewRides` (Community, on by default) in `feature_flags.js`.
