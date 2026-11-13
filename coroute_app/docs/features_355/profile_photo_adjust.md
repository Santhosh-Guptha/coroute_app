# Adjust your profile picture (3.56, round 6)

**What the rider gets.** In **My profile**, the camera button on the picture offers **Adjust picture**,
**Take a new photo**, **Choose a new picture** and **Remove picture**. Adjust opens CoRoute's own cropper: a round
frame, drag to move, pinch (or slider) to zoom, turn left / right by 90°, reset (also double tap), **Save**. A new
picture goes through the same screen before upload. The uploaded picture can be adjusted again at any time without
choosing it again. The website has the same on **/account › Edit picture**.

No new dependency anywhere: `dart:ui` on the phone, a `<canvas>` on the website, no image library on the gateway.

## Crop numbers (shared by app, website and gateway)

| Field | Meaning | Range |
|---|---|---|
| `rot` | quarter turns clockwise | 0..3 |
| `zoom` | 1 = the largest square that fits the turned picture | 1..8 (less for a tiny picture: the square keeps 32 px) |
| `cx`, `cy` | centre of the square, as a fraction of the picture **after** turning | 0..1 (clamped so the square stays inside) |

Saved with 4 decimals. Output: a square of 512 px, or smaller when the square holds fewer source pixels (never
enlarged). Original kept: at most 2048 px on the long side.

* App maths: `lib/domain/media/avatar_crop.dart` (pure Dart). Website maths: `window.CoAvatarCrop` in
  `gateway/public/assets/account.js`. Gateway validation: `normaliseCrop` in `gateway/src/avatars.js`.
* Both clients are tested with the same cases, so a picture adjusted on one can be re-adjusted on the other.

## Storage and privacy

| What | Who can read it | Limits | Id |
|---|---|---|---|
| Public round picture | signed-in riders (never a rider the owner blocked), admins | 2 MB, 1024 px per side through the crop route (clients write 512 px) | `av_` + 24 hex, `GET /api/avatars/:id` |
| Private original | **only the owner** (`GET /api/me/avatar/original`, no id in the path) | 2 MB, 2048 px per side | `avo_` + 24 hex: never a valid avatar id, so the public route can not serve it |
| Crop numbers | owner (`GET /api/me/profile`: `avatarCrop`) | see above | on the user document (`avatarCrop`, `avatarOriginalId`) |

* **EXIF / GPS:** both clients draw the picture on their own canvas and encode it again (the phone through
  `ImageEncodeChannel.kt`, JPEG; PNG if that channel is missing), so nothing of the camera file survives. The gateway
  runs the same cleaner as for review photos on **both** files anyway (EXIF, XMP, IPTC, comments, PNG text removed;
  only the orientation tag is kept so a JPEG from another client is not shown sideways).
* The gateway has no image library, so it can not crop or resize: it checks type by magic bytes, byte size and pixel
  size from the file header, and refuses what is over the limits.
* Stored where avatars already are: Object Storage (`avatars/<id>.<ext>`, originals under `avatars/original/`) when
  `REVIEW_PHOTO_STORE=par`, else the `avatars` collection. Original documents carry `kind: 'original'`.
* **Removal deletes both:** `DELETE /api/me/avatar` (rider), `DELETE /api/admin/users/:userId/avatar` (moderation,
  audited as `user.avatar.remove`, unchanged) and account deletion (`forgetAvatars` removes every document of the
  rider). A pending upload that was never cropped goes too.
* Admins have **no** route to a rider's original (moderation acts on the public picture).
* The phone keeps the original in memory only (dropped on sign-out, on removal and when `avatarOriginalTag` changes
  because another device stored a new one); nothing is written to the phone's storage.

## Endpoints (all in `gateway/src/social_routes.js`, already mounted; switch `profilePhotos`)

| Method | Path | Body | Answer | Limit |
|---|---|---|---|---|
| POST | `/api/me/avatar/original` | picture bytes (JPEG / PNG / WebP) | `201 { originalId, width, height }`; stored as **pending** | 10 / hour / rider |
| POST | `/api/me/avatar/crop?cx=&cy=&zoom=&rot=[&original=<id>]` | the cropped picture | `201 { avatarUrl, avatarAdjustable: true, avatarCrop }` | 30 / hour / rider |
| GET | `/api/me/avatar/original` | | the bytes, `Cache-Control: no-store`, `X-Avatar-Crop` | 300 / min |
| POST | `/api/me/avatar` | picture bytes (older apps) | `201 { avatarUrl }`; **drops the stored original** (it no longer matches) | 10 / hour |
| DELETE | `/api/me/avatar` | | `{ removed }`; removes both | |
| GET | `/api/me/profile` | | adds `avatarAdjustable`, `avatarCrop`, `avatarOriginalTag` | |

Flow for a new picture: original → crop with `original=<id>` (the pending original becomes the current one, the old
one is deleted). Re-adjust: crop without `original` (the stored original stays). Errors: `409 NO_ORIGINAL` (nothing
to crop from, or an id that is not this rider's: another rider's id looks exactly like an unknown one),
`400 BAD_CROP`, `413 PHOTO_TOO_LARGE`, `415 UNSUPPORTED_PHOTO` / `PHOTO_TOO_BIG_SIDE`, `403 FEATURE_OFF`, `429`.

**Existing riders** (picture uploaded before 3.56): no original was ever kept. "Adjust picture" then loads the current
round picture, says so ("The original of this picture was not kept…"), and on Save stores that picture as the
original from now on.

**Older gateway:** when the adjust routes answer 404 the app saves the cropped picture through the old
`POST /me/avatar`.

## App

* `lib/presentation/social/avatar_crop_screen.dart`: the screen. Tool buttons are 88 x 56 dp; the slider and the
  buttons are labelled for TalkBack. **Not** a `SecureScreen`: FLAG_SECURE stays on sign-in, 2-step, ride lock and
  Medical ID only; screenshots of your own picture are allowed (asserted in `test/avatar_crop_screen_356_test.dart`).
* `lib/data/services/avatar_image_codec.dart`: decode (EXIF orientation applied, decoded at most 2048 px), draw,
  encode. `android/.../ImageEncodeChannel.kt` (channel `coroute/image`, `encodeJpeg`): framework `Bitmap.compress`
  on a worker thread, nothing written to storage.
* `lib/data/services/friends_service.dart`: `adjustSource()`, `saveAdjustedAvatar()`.
* `lib/presentation/social/profile_screen.dart`: the sheet and the flow.

## Website

`gateway/public/account.html` (a `<dialog>`), `assets/account.js`, `assets/shop.css`. Strict CSP unchanged: no inline
script or handler, no library, no `blob:` URL (pictures are fetched with the Bearer header and drawn on a canvas;
this also fixed the header picture, which was an `<img>` without the header and never loaded). Mouse, touch (pinch)
and keyboard: arrows move (Shift = faster), `+` `-` zoom, `[` `]` turn, `0` resets; the zoom is also a labelled
range input; every control is a real button.

## Tests

| Test | What |
|---|---|
| `test/avatar_crop_356_test.dart` (12, run here) | transform → source square, rotation mapping and round trip, bounds clamp, drag / pinch, output size, original size, wire format |
| `test/avatar_crop_screen_356_test.dart` (widget; needs Flutter) | controls, 48 dp, Save hands over crop + pictures, error keeps the screen, not FLAG_SECURE |
| `gateway/test/avatar_adjust_356.test.js` (6) | original + crop, EXIF / GPS removed from both, owner-only original, re-crop, limits, legacy upload drops the original, removal (rider, admin, pending) deletes both, switch, rate limit |
| `gateway/test/avatar_adjust_web_356.test.js` (4) | website maths = app maths = gateway validation; page rules (no inline script, labelled controls, keyboard) |
| Playwright screenshots | `web_cropper_desktop.png`, `web_cropper_desktop_turned.png`, `web_cropper_phone.png`, `web_cropper_readjust_*.png`, `web_account_after_save_*.png` |

## Known limits

* A pending original that is never cropped stays until the rider's next upload, removal or account deletion (at most
  one per rider, 2 MB). A retention sweep for pending originals older than a day would be tidy (`retention.js`).
* The phone's JPEG encoder is Android only; other platforms fall back to PNG (larger upload, same result).
* TalkBack users move the picture with the slider and the turn buttons only (no "nudge" buttons in the app; the
  website has arrow keys).
