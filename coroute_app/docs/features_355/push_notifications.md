# Push notifications (3.55)

Friend requests, accepted requests, crew invites, new crew polls and ride invites reach the
phone when CoRoute is closed, through Firebase Cloud Messaging (FCM HTTP v1). Before this, they
reached only a phone with a live socket.

## Architecture

```
action (friend request, crew invite, poll, ride invite)
   |  gateway route (social_routes.js / crew_routes.js / crew_ride_invites.js)
   |-- hub.sendToUser(...)            live socket: in-app notice as before
   '-- push (src/push.js)             no live socket (or RIDE_INVITE): FCM data message
          | push_tokens (SODA)        up to 5 tokens per rider
          '-- POST https://fcm.googleapis.com/v1/projects/<id>/messages:send
                 |
Android: CoRouteMessagingService (FirebaseMessagingService)
   |-- app in front  -> MethodChannel coroute/push "onMessage" -> PushRouterHost snackbar + refresh
   '-- app closed    -> local notification (channel "Friends" or "Ride invites")
                         tap -> MainActivity extras {pushType, payload}
                         -> PushService.opened / takeLaunchMessage -> PushRouterHost -> screen
```

### Gateway (`gateway/src/push.js`)

- `PushService`, one per gateway, attached in `app.js` as `hub.push`, `convoys.push` and
  `app.locals.push` (and returned by `createApp` as `push`).
- Contract for other modules: `push.notifyUsers(userIds, {type, title, body, data, ttlSec,
  priority, skipConnected})` returns `{sent, skipped, failed, disabled?}`, never throws. Callers
  do not await it on hot paths.
- `push.onSocketEvent(userId, payload, {delivered})` runs after `hub.sendToUser` in
  `social_routes.js` and `crew_routes.js`. `FRIEND_REQUEST`, `FRIEND_ACCEPTED`, `CREW_INVITE` and
  `POLL_CREATED` are pushed only when no socket on this gateway got the event, because a live app
  already showed it. `RIDE_INVITE` always pushes (crew ride invites call `notifyUsers` directly).
- Token registry: collection `push_tokens` `{userId, token, platform, appVersion, updatedAt}`.
  The token is unique: a token that signs in to another account moves to that account. The 5
  newest tokens per rider are kept. Tokens are removed when the rider deletes the account, signs
  out (`DELETE`), or turns the switch off, and when FCM answers `UNREGISTERED` /
  `INVALID_ARGUMENT` / `SENDER_ID_MISMATCH`.
- Endpoints (authenticated, 10 calls a minute per rider):
  - `POST /api/me/push-tokens {token, platform:'android', appVersion}` returns `{ok, tokens, enabled}`
  - `DELETE /api/me/push-tokens {token}` removes one token. An empty body removes all of the
    rider's tokens. Returns `{ok, removed}`.
- Messages are data-only. Android uses `priority HIGH` for `RIDE_INVITE` and `NORMAL` for the
  rest. TTL: ride invite 30 min, friend events and crew invites 3 days, polls 1 day. Collapse key:
  one per invite / request / poll.
- Every rider gets at most 30 pushes per 10 minutes on each node. A 429 / 5xx / network error is
  retried up to 3 times with exponential backoff, and `Retry-After` is honoured (capped at 30 s).
- The sender only talks to `fcm.googleapis.com` (a `HOSTS` allowlist like `guardian_push.js`).
  The OAuth token comes from `google-auth-library` (JWT, scope `firebase.messaging`).
- Admin switch `pushNotifications` (Platform group): off means no pushes for anyone. Tokens are
  still stored.

### Android

- `android/app/build.gradle.kts` adds `firebase-bom:33.7.0` + `firebase-messaging` (no Analytics).
  It does not use `google-services.json` or the google-services plugin. The four client values
  are injected as resource strings at build time.
- `PushChannel.kt`:
  - `PushConfig.ensureInit` builds the default FirebaseApp with `FirebaseOptions.Builder` when the
    values exist. Without them, push is off (`isAvailable` returns false) and nothing crashes.
  - MethodChannel `coroute/push`: `isAvailable`, `getToken`, `deleteToken`, `setEnabled`,
    `takeLaunchMessage`, `notificationsEnabled`. Android calls back with `onToken`, `onMessage`
    and `onMessageOpened`.
- `CoRouteMessagingService.kt`:
  - `onNewToken` forwards the new token to Dart, which registers it.
  - `onMessageReceived`: when the app is in front, the message goes to Dart. Otherwise it posts a
    local notification on `coroute_social` ("Friends", default importance),
    `coroute_ride_invites` ("Ride invites", high importance) or `coroute_plan_reminders`.
  - Visibility is private (no text on the lock screen). The tap opens MainActivity with
    `{pushType, payload}`.
  - Nothing is posted while POST_NOTIFICATIONS is denied (Android 13+) or notifications are off.
- The manifest declares the service with the `com.google.firebase.MESSAGING_EVENT` filter and
  `exported=false`.

### Dart

- `lib/data/services/push_service.dart` (`PushService`, provider in `main.dart`):
  - Registers the token after sign-in and on every refresh.
  - On sign-out, sends `DELETE` with the last session and deletes the FCM token, so even a
    missed `DELETE` stops pushes.
  - Exposes `opened` (tapped pushes; the cold start is read with `takeLaunchMessage`) and
    `messages` (pushes received while in front).
- `lib/domain/notify/push_routing.dart`: the pure type-to-screen map (all ids are validated
  because the activity is exported):
  - `FRIEND_REQUEST` / `FRIEND_ACCEPTED` go to the Friends screen.
  - `CREW_INVITE` goes to the Crews screen (invites).
  - `POLL_CREATED` goes to the crew's page (polls).
  - `RIDE_INVITE` goes to `PushRouterHost.openRideInvite(context, inviteId)`.
  - `ADMIN_WARNING` refreshes the moderator warnings.
  - `SUBSCRIPTION*` goes to the membership page.
- `lib/presentation/widgets/push_router_host.dart` (in `MaterialApp.builder`): opens the screen.
  On a cold start it waits for sign-in and for the splash hand-over. A push that arrives while
  the app is in front becomes a snackbar with "View".
- Settings > Account & privacy has a **Push notifications** switch (default on). It is shown
  only when the build has push. Turning it on asks for the notification permission if Android
  has not granted it. Turning it off removes the token from the gateway and from FCM.
- The permission is not asked at startup. The onboarding permissions screen already asks for
  notifications, and the switch asks again if needed.

## Owner setup

1. Create a Firebase project at https://console.firebase.google.com (Analytics is not needed).
2. **Add app > Android**, package name `space.devmonks.coroute_app`. You do not need to add the
   downloaded `google-services.json` to the repo. Only take these four values from it, or from
   Project settings > General > Your apps:
   - `COROUTE_FCM_APP_ID`: mobilesdk_app_id, like `1:1234567890:android:abc123...`
   - `COROUTE_FCM_API_KEY`: current_key, like `AIza...`
   - `COROUTE_FCM_PROJECT_ID`: project_id
   - `COROUTE_FCM_SENDER_ID`: project_number
3. Give them to the release build, and never commit them. Either put them in
   `~/.gradle/gradle.properties` on the build machine:
   ```
   COROUTE_FCM_APP_ID=1:...:android:...
   COROUTE_FCM_API_KEY=AIza...
   COROUTE_FCM_PROJECT_ID=coroute-xxxxx
   COROUTE_FCM_SENDER_ID=1234567890
   ```
   or set them as environment variables / CI secrets with the same names.
4. In Google Cloud Console (same project), make sure **Firebase Cloud Messaging API (V1)** is
   enabled (APIs & Services > Library).
5. Create a service account (IAM & Admin > Service accounts) with the role **Firebase Cloud
   Messaging API Admin** (`roles/firebasemessaging.admin`). Create a JSON key.
6. Put the key in the server secret store, never in the repo, as `FCM_SERVICE_ACCOUNT_JSON`
   (the whole JSON on one line). Or store it as a file readable only by the gateway user and set
   `FCM_SERVICE_ACCOUNT_FILE=/path/key.json`. Optionally set `FCM_PROJECT_ID` (the default is the
   key's `project_id`). Set it on both gateway VMs and restart.
7. Check: the gateway log no longer says "FCM not configured". In the app, Settings > Account &
   privacy shows "Push notifications".

### Without the setup

- App built without the four values: no FirebaseApp, no token, no Settings switch. Everything
  else works as before (in-app socket notices).
- Gateway without the service account: tokens are still stored, sending is a no-op (logged once).
  Pushes start as soon as the key is configured. Phones do not need to re-register.

## Privacy

- Data-only messages with ids and a short line that names the other rider by **username** only,
  for example "SwiftFalcon482 sent you a friend request".
- No phone number, e-mail, name, medical info, emergency contact, location or user id is ever
  sent. `push.js` drops data keys naming such fields and values that look like an e-mail or
  phone number, and strips them from the text. `test/push_355.test.js` checks this.
- Lock screen: private visibility (Android shows "CoRoute" and hides the text until unlock,
  depending on the rider's system settings).
- Tokens are deleted on sign-out, when the switch is turned off, on account erase, and when FCM
  reports them dead.

## Device checks

1. Sign in on phone A and allow notifications. Force-stop CoRoute (swipe away).
2. From phone B, send A a friend request. A shows "Friend request: <username> sent you a friend
   request". Tap it: CoRoute opens on Friends.
3. Repeat with a crew invite (opens Crews with the invite), a new poll (opens the crew page) and
   a ride invite (opens the ride invitation, high priority).
4. With A open on screen, the socket shows the in-app notice and no system notification
   appears. With A in front but offline then back online, any push received shows as a snackbar.
5. Token refresh: clear CoRoute's storage or reinstall, sign in again. The new token is
   registered (gateway `push_tokens` has it) and the old one is pruned on the next send.
6. Sign out on A. Friend requests to A no longer notify the phone.
7. Settings > Push notifications off: no pushes. On: the permission prompt if needed, then pushes
   resume.
8. Admin console > Features > Push notifications off: no pushes for anyone.
