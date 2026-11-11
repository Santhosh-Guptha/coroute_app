# Ride chat (3.55)

Owner decision: "Ride chat is already there: put it in place, with simple action buttons instead
of heavy taps."

## What the rider sees

- **Chat button** on the cockpit map (right-hand stack, 56 dp, always visible in a group ride;
  not in a solo ride). A red badge shows unread messages (`9+` above nine).
- **Chat sheet** (compact, about two thirds of the screen):
  - recent messages: rider name, time, text; quick cards show their icon;
  - **quick actions**, one tap each, big tiles (icon + 1-2 words): Fuel, Break, Wait for me,
    I'm OK, Slow down, Regroup here, On my way, Arrived. Order: Settings > More > "Chat quick
    replies" (Move up / Move down);
  - a text field, **only when stopped** or riding pillion. While moving (8 km/h and more, same
    gate as the other cockpit cards, `RideTapGate`) the field is replaced by "Riding: one-tap
    replies only. Stop to type."
  - no microphone button: no speech-to-text package is in the app (none added); the keyboard's
    own voice typing works in the text field.
- **Before and after the ride**: the ride room exists from creation, so the Chat button works in
  the lobby before anyone moves. When the ride ends its messages are kept on the phone (last 10
  rides, 300 messages each) and shown read only in the trip summary ("Ride chat", last 5, "Show
  all").

## Incoming messages

| Message | What happens |
|---|---|
| Quick card from another rider | Spoken in one short line: "Kiran: fuel stop". No banner. |
| Text from another rider | Banner for 8 s (name + text, "Open chat"). Spoken "Kiran says: ..." when 40 characters or less, or when stopped; longer than 120: "Kiran sent a message". |
| My own lines, my own "Wait for me" card | Nothing. |
| Hidden rider | Not shown, counted or spoken. |
| SOS / crash alert open | Banner only, never spoken (the SOS owns the voice). |

Each message is announced once (`NoticeDedupe` key `CHAT:<messageId>`); messages older than
two minutes (replayed after a reconnect) are not announced. Opening the sheet marks everything
read and clears the banner.

## Moderation

- Long-press another rider's message: **Hide messages from Kiran** (this phone only) or **Report message** (also hides).
- Report: socket `CHAT_REPORT {messageId, reason}` -> `PublicRides.reportGroupChat`: stored with
  the public ride reports (same admin queue, `/admin/public-ride/reports`, ref
  `CHAT:<groupId>:<messageId>`, same 20 a day budget). The transcript holds only the reported
  rider's and the reporter's lines up to that message. The reported rider is not told.
- Rate limit: CHAT is 5 a second per socket (existing, `ws.js`), "Wait for me" keeps its own
  cooldown in the app (4 s) and on the gateway.

## Code

- Rules (pure): `lib/domain/ride/ride_chat.dart` (quick actions, order, moving gate, spoken
  lines, notices, unread counter).
- Service: `ConvoyService` "3.55 ride chat" section (`quickActions`, `sendQuickAction`,
  `unreadChat`, `setChatOpen`, `chatBanner`, `chatHidden`, `reportChatMessage`, `chatCanType`,
  `rideMoving` hook set by the cockpit). Phone storage: `lib/data/services/ride_chat_store.dart`.
- UI: `lib/presentation/ride/messages_sheet.dart` (`RideChatButton`, `MessagesView`,
  `QuickReplyBar`, `RideChatHistory`, `QuickActionOrderView`); cockpit button and banner slot in
  `live_cockpit_map_screen.dart`.
- Gateway: `gateway/src/ws.js` (`CHAT_REPORT`), `gateway/src/public_ride.js` (`reportGroupChat`).

## Tests

- `test/ride_chat_test.dart` (pure): quick action mapping and order, moving gate, spoken lines,
  notices, unread counter.
- `test/chat_and_end_ride_test.dart`: sheet while moving (no text field), quick card / wait,
  spoken incoming quick card, text banner, hidden rider, report, saved order.
- `test/share_card_quick_reply_test.dart`: tiles, double tap, offline line.
- `gateway/test/ride_chat_report.test.js`: card type kept, report stored with the two riders'
  lines only, refusals, chat rate limit.
