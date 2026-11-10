# Usernames, profiles, friends and profile pictures (3.55)

Each rider gets a unique public username. There is also a profile with ride analytics, friends
with mutual approval (plus blocking and invite links), and an optional profile picture.

## Gateway files

| File | What it holds |
| --- | --- |
| `gateway/src/usernames.js` | Username allocation and validation, the 30-day change rule, availability checks, `usernamesFor`, `ensureUsername`, the backfill job |
| `gateway/src/friends.js` | The friend graph (`friend_edges`), blocks (`user_blocks`) and personal invite codes (`invite_codes`) |
| `gateway/src/avatars.js` | Profile picture checks and storage (`avatars` collection, or Object Storage) |
| `gateway/src/social_routes.js` | `attachSocial` (auth hooks, backfill, account-erase cleanup, the `/join/friend/:code` page) and `registerSocialRoutes` (REST) |
| `gateway/test/usernames_friends_355.test.js` | Gateway tests |

Small additive edits to shared files:

- `app.js`: one `attachSocial(...)` line before the `/api` router.
- `routes.js`: one `registerSocialRoutes(...)` line. The admin user detail now also returns `username` and `avatarUrl`.
- `auth.js`: `publicUser` gains `username` and `avatarUrl`. `selfUser` gains `publicLeaderboard` and `usernameChangedAt`. A new `onUserReady` hook runs at register, Google sign-up and sign-in, password login and `/me`. `register` accepts `inviteCode`.
- `admin_analytics.js`: rider rows and the rider detail include `username` and `avatarUrl`, and `q=` also searches by username.
- `feature_flags.js`: new switches `friends` and `profilePhotos` (Community group). Usernames are core and have no switch.

Each module creates its own collections and indexes on first use. `repo.migrate()` is unchanged.

## Usernames

- **Format of generated names:** `<Adjective><RideWord><3-4 digits>`, for example `SwiftFalcon482` or `ThrottleTiger907`, picked from curated word lists. A generated name never contains parts of the rider's real name. Every word combination passes the rider rules (a test checks this).
- **Allowed format:** 3-20 characters from `A-Z a-z 0-9 _`, starting with a letter.
- **Fields:** the user document stores `username` and `usernameKey` (the lowercase form). Uniqueness ignores case. It is enforced by a reservation document per name in `usernames`, which has a unique index on `usernameKey`. The first insert wins, so two nodes can never hand out the same name. Allocation retries on a collision, and after 20 tries it falls back to a 5-digit suffix.
- **When names are allocated:**
  - at registration and Google sign-up;
  - lazily at sign-in and `GET /me` for older accounts;
  - by a startup backfill under the job lease (`username-backfill`). The backfill is idempotent and can also be run with `POST /api/admin/usernames/backfill`.
- **Changing it:** a rider may choose their own name once every 30 days (`usernameChangedAt`). A change that only alters capital letters is always allowed and does not start a new cooldown. The rules are:
  - reserved words are refused: admin, coroute, support, official, moderator, staff and others. "admin", "coroute", "support", "official", "moderator" and "staff" are refused anywhere in the name, including digit-for-letter swaps such as `c0route`;
  - a short profanity list (English and Hindi) is refused;
  - anything that looks like contact details is refused: 7 or more digits in a row, more than 8 digits in total, or an e-mail provider name.
- **After a change:** the old name is released at once.
- **`publicLeaderboard`:** a boolean on the user document, default `true`. The rider can hide their username from the website leaderboards. The scoring module reads this field.
- **Exports:**
  - `usernamesFor(repo, userIds)` returns a `Map` of userId to username. It allocates a name for any id that has none yet.
  - `ensureUsername(repo, user)` returns the user with a username. Concurrent calls for the same rider share one allocation.

## Endpoints (all under `/api` and authenticated unless noted)

| Method and path | Purpose |
| --- | --- |
| `GET /me/profile` | `{profile:{username, name, avatarUrl, publicLeaderboard, usernameChangedAt, nextUsernameChangeAt, memberSince, inviteCode, inviteLink, shareText}, stats}` |
| `GET /me/stats[?fresh=1]` | `{stats:{trips, totalKm, ridingHours, longestTripKm, largestGroup, memberSince}}`, built from stored trips (see below). Cached for 2 minutes. |
| `GET /users/username-available?u=` | `{available, code?, message?}`. Rate limited to 30 per minute per rider. The rider's own name counts as available. |
| `PATCH /me/username {username}` | Changes the username. Errors: 422 (`USERNAME_FORMAT`, `_RESERVED`, `_NOT_ALLOWED`, `_CONTACT`), 409 `USERNAME_TAKEN`, 429 `USERNAME_COOLDOWN` with `nextChangeAt`. Rate limited to 10 per hour. |
| `PATCH /me/privacy {publicLeaderboard}` | Sets the leaderboard toggle. |
| `POST /me/avatar` (raw bytes) / `DELETE /me/avatar` | Uploads or removes the profile picture. Uploads are rate limited to 10 per hour. Switch: `profilePhotos`. |
| `GET /avatars/:avatarId` | Serves a picture to signed-in riders. Answers 404 to a rider the owner blocked. Switch: `profilePhotos`. |
| `GET /users/:username/profile` | Another rider's profile. See the privacy rules below. |
| `GET /convoys/:groupId/usernames` | `{riders:{userId:{username, avatarUrl}}}` for the members of a ride I am in. Answers 403 otherwise. |
| `GET /friends` | `{friends, incoming, outgoing, blocked, inviteCode, inviteLink, shareText}`. Switch: `friends`. |
| `GET /friends/invite` | Invite code, link and share text. |
| `POST /friends/requests {username}` or `{inviteCode}` | Sends a friend request. The username is matched ignoring capitals and a leading `@`; the code ignoring capitals, spaces and dashes. Limited to 20 per day per rider. Answers `202 {status:'REQUESTED', request:{requestId, username, avatarUrl, at}}` (the sender's own row, the same as in `outgoing`), or `200 {status:'FRIENDS' / 'ALREADY_FRIENDS', friend}`. An unknown username or invite code answers `404 NOT_FOUND` ("No rider has that username. Check the spelling." / "This invite code is not valid."). |
| `POST /friends/requests/:requestId/accept` and `/decline` | Answers a request. Only the addressee can. |
| `DELETE /friends/requests/:requestId` | The sender cancels a request. |
| `DELETE /friends/:username` | Removes a friend. |
| `GET /blocks`, `POST /blocks {username}`, `DELETE /blocks/:username` | Lists, adds and removes blocks. These work even while the `friends` switch is off. |
| `DELETE /admin/users/:userId/avatar` | Admin moderation. The removal is audited. |
| `GET /admin/users/:userId/social` | Admin summary: username, picture, friend counts. |
| `POST /admin/usernames/backfill` | Admin: runs the idempotent backfill. |
| `GET /join/friend/:code` (public web page) | Opens the app at `coroute://join/friend/<CODE>`, otherwise offers the download. Never names the inviter. |

**Socket pushes** go to the rider's open sockets, and are mirrored to the peer node when the rider is
connected there:

- `{type:'FRIEND_REQUEST', requestId, username, via}`
- `{type:'FRIEND_ACCEPTED', username}`

Pushes never include a userId.

## How ride analytics are computed

The stats come from the `trips` collection. Trip summaries are kept forever and written by the
server (`report.js`) or the phone (`POST /trips`).

- Each group ride counts once. When both the server and the phone stored a trip for the same group, the server trip wins.
- Solo trips count as they are.
- Riding hours use `movingMs`. When that is missing, they use the end time minus the start time, capped at 48 hours per trip.
- Largest group is the highest `riderCount`.
- The **rider score** comes from the scoring module: the app calls `GET /me/score` (404 or `score: null` until there are enough rides). A friend's profile reads the stored `rider_scores.score` (read-only, and only once that record has `eligible: true`).
- **Bikes in garage** is counted on the phone, because the garage lives on the phone.

## Privacy rules

- **Another rider's profile never includes:** phone, e-mail, medical info, emergency contacts, home or any location, guardian info, plan or payment, or the userId. The test checks both the field names and the values.
- **Non-friends** see the `username`, the `avatarUrl` and the `relation` only.
- **Friends** also see `displayName` (the first word of the name) and the totals: trips, km, hours and score.
- **Ride group members** see each other's username and picture by userId, because they already know each other's userIds during a ride.
- **Blocking:**
  - A rider who blocked me gets the same 404 as an unknown username, and I cannot load their picture.
  - A friend request to them gives the same `202 {status:'REQUESTED', request}` as any other request. It is stored as a `shadow` edge: the requester sees it under "Sent" as pending forever, the target never sees it and gets no push. So a block is never revealed.
  - Only the blocker's own copy is hidden: once they unblock, a new request from the same rider reaches them normally (tested in `gateway/test/friends_app_contract_355.test.js`).
  - When someone blocks a rider who already has a pending request to them, that request becomes a shadow too.
  - Unblocking drops shadow requests, as if they had been declined.
  - Blocking an unknown username gets the same answer as blocking a real one.
- **Username enumeration:** `GET /users/username-available` necessarily shows whether a name is taken. It is rate limited, and it never shows who holds the name. Because of that, a friend request to an unknown username answers `404` instead of a fake "sent" (before this fix it answered `202`, so a typo was reported as sent and the request then appeared nowhere, neither under "Sent" nor with anyone). Invite codes cannot be guessed (32^8) and requests are limited to 20 a day, so an unknown code also answers `404`.
- **Account erase:** the account's username reservations, friend edges, blocks, invite codes and pictures are deleted. `attachSocial` wraps `repo.deleteUserCascade` to do this.

## Profile pictures

- **Upload:** the app picks a picture with `image_picker` (camera or gallery). It is downsized to 512 px and re-encoded as JPEG at quality 80 on the phone, with `requestFullMetadata: false`.
- **Server checks:**
  - The type comes from the magic bytes (JPEG, PNG or WebP); the declared Content-Type is never trusted.
  - Maximum 2 MB and at most 2048 px per side.
  - The same plain-JavaScript cleaner as review photos (`review_photos.preparePhoto`) removes EXIF, XMP, IPTC and PNG text chunks.
  - **Pixels are not re-encoded on the server.** The gateway has no image library in `package.json`, so the phone does the re-encoding.
- **Storage:** OCI Object Storage (`avatars/<id>.<ext>`) when `REVIEW_PHOTO_STORE=par`, otherwise the `avatars` collection (base64), so both VMs serve the same file. Every upload gets a new random id, so the URL changes and caches never show an old picture. The previous picture is deleted.
- **Default:** a circle with initials (`UserAvatar`). It is also shown when the picture fails to load or the switch is off.

## Friends and invites

- Friendship needs both riders to agree. If the other rider already sent me a request, my request to them becomes an acceptance.
- **Limits:**
  - 20 requests per day (counted per node);
  - 50 pending outgoing requests;
  - 500 friends.
- **Invite codes:** each rider has a personal code: 8 characters from `A-Z` (no I or O) and `2-9`. The invite link is `https://<site>/join/friend/<CODE>`. Android App Links already cover `/join/`, so the manifest is unchanged.
- **Opening an invite link:**
  - Signed in: the app sends the request.
  - Not signed in: the code is remembered and sent with the registration (`inviteCode`). The gateway then sends the inviter a friend request from the new rider.

## App (Flutter) files

| File | What it holds |
| --- | --- |
| `lib/domain/social/username_rules.dart` | Pure rules: username check with the gateway's codes, cooldown, invite code parsing, initials, km format |
| `lib/domain/social/friends_models.dart` | Pure parsing of the gateway's friend JSON: `FriendsSnapshot` (GET /friends), `FriendRequestResult` (POST /friends/requests, with the sender's confirmation line), `FriendPush` (socket FRIEND_REQUEST / FRIEND_ACCEPTED), `usernameInput` (drops a leading `@`). Re-exported by `friends_service.dart`. |
| `lib/data/services/friends_service.dart` | `FriendsService`: profile, stats, score, friends, requests, blocks, avatar upload, group usernames, pending invites, socket pushes, badge count |
| `lib/presentation/social/friend_requests_card.dart` | "Friend requests" card with Accept / Decline per request: top of the Friends screen and of My profile |
| `lib/presentation/social/profile_screen.dart` | My profile: picture, username editor with live availability, analytics grid, leaderboard privacy toggle, invite sharing |
| `lib/presentation/social/friends_screen.dart` | Friends list, requests, sent requests, blocked riders, add by username or code |
| `lib/presentation/social/rider_profile_screen.dart` | Another rider's profile |
| `lib/presentation/social/user_avatar.dart`, `rider_username_line.dart` | Avatar widget; `@username` line on the ride rider card |

Wiring:

- `main.dart`: the `FriendsService` provider, plus the invite branch in `_DeepLinkListener`.
- `auth_service.dart`: a `username` getter, and `inviteCode` sent at registration.
- Profile tab: a badge with the number of waiting friend requests (plus crew invitations and polls) on the bottom-bar Profile icon, and a "My profile & friends" row that says "1 friend request" / "N friend requests" (or "N new" when crew items wait too).
- My profile: the "Friend requests" card at the top (first three, then "See all"); the Friends row shows "N new".
- Friends screen, top to bottom: "Friend requests" (Accept / Decline / Block), invite button, "Sent" (Cancel), "My friends", "Blocked". Sending shows "Request sent to X. It is under Sent until they answer." and the row appears under "Sent" at once (from the 202 `request`).
- Admin users list: searches and shows the username.
- Admin user detail: shows `@username` and a "Remove profile picture" button.
- `test/username_rules_test.dart`: Dart tests.

Notifications: an in-app badge. `FriendsService` reads GET /friends at app start (also with a saved session: `ApiClient.init()` now tells its listeners that a saved token was loaded; before, services created before the token was read never loaded anything, so incoming requests stayed invisible until the rider happened to open the Friends screen), at sign-in, on resume, whenever the socket (re)connects, and on every FRIEND_REQUEST push (which also adds the row at once, before GET /friends answers). A push that arrives
while the app is open shows "X wants to be friends" / "X accepted your friend request" as a snackbar
(`FriendNoticeHost` in `MaterialApp.builder`); in the background (socket still open, e.g. during a
ride) it is a local system notification on the `coroute_social` channel (`AlarmNotifier.showSocialNotice`).
With no open socket (app closed) the gateway sends an FCM push instead (`gateway/src/push.js`, when FCM is
configured); the socket message and the push share one `eventId`, so the app shows the first and drops the
second (`NoticeDedupe`), never the first.

Tests: `gateway/test/usernames_friends_355.test.js`, `gateway/test/friends_app_contract_355.test.js` (the
exact answers the app reads, checked against `test/fixtures/friends_355_gateway.json`, captured from an
end-to-end run on the real gateway) and `test/friends_parse_355_test.dart` (the app parses that fixture).
