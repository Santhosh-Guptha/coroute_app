# Marketing board: "Latest from CoRoute" (3.56)

Admins post updates, offers, safety tips and events in the web admin; riders read them on the website:
the home page shows the top 3 (section `#latest`, hidden while empty) and **`/updates`** shows all, with a kind
filter (`/updates?kind=offer` preselects). **Website only**: board content is never pushed to the app (no push,
no socket event; `src/board.js` has no notification code, checked by a test).

## A post

| Field | Rule |
|---|---|
| kind | `update`, `offer`, `safety_tip`, `event` |
| title | one line, 1–80 characters (control characters removed) |
| body | plain text, 1–600 characters, line breaks kept (at most one empty line in a row) |
| link, linkLabel | optional page of this website (`/plans`, `/safety#sos`, `/plans?coupon=X`); no other site, no `//`, `/api`, `/admin`, `..`; label ≤ 40 |
| imageId | optional uploaded image: JPEG / PNG / WebP by magic bytes, ≤ 2 MB, EXIF / XMP / IPTC removed (the review-photo pipeline and store: disk outside `public/` or Object Storage) |
| couponCode | optional; must be active or scheduled when chosen. The website shows the chip ("40% off", code, **Copy code**, **Use on plans** → `/plans?coupon=CODE`, valid until) only while the coupon is usable and not private |
| startAt, endAt | publish window (India time in the editor; end exclusive) |
| pinned | pinned posts first |
| status | `draft`, `published`, `archived` |

Order on the website: pinned first, then newest (window start, else publish time).

## Endpoints

| Endpoint | Auth | Notes |
|---|---|---|
| `GET /api/public/board?kind=&limit=` | public | published and in window; whitelisted plain fields only (`id, kind, kindLabel, title, body, link, linkLabel, image, coupon, pinned, date, endsAt`); `Cache-Control: public, max-age=60`, 60 s server cache (cleared by an admin write on that node); 120/min per IP |
| `GET /api/public/board/images/:imageId` | public | only for a visible post; `nosniff`, `CORP same-origin`, sandbox CSP |
| `GET /api/admin/board` | MASTER_ADMIN | every post with `visibleNow` |
| `POST /api/admin/board`, `PATCH/DELETE /api/admin/board/:id` | MASTER_ADMIN | `baseUpdatedAt` guards against overwriting another admin's save (409) |
| `POST /api/admin/board/images` | MASTER_ADMIN | raw bytes; 415 / 413 |
| `GET /api/admin/board/images/:id` | MASTER_ADMIN | editor preview (drafts) |
| `GET /api/admin/board/coupons` | MASTER_ADMIN | coupon picker: active and scheduled |

Audit: `board.create`, `board.update`, `board.publish`, `board.unpublish`, `board.archive`, `board.delete`,
`board.image.upload`. Storage: collection `board_posts` (posts `type: 'post'`, image metadata `type: 'image'`).

## Code

- Server: `gateway/src/board.js` (registered in `routes.js`), collection in `oracle/repo.js`.
- Website: `public/assets/board.js` + `board.css` (text nodes only; links, image URLs and codes re-checked
  against strict patterns), home section in `index.html`, page `public/updates.html` (no inline script, in the
  sitemap and the footer).
- Web admin: `public/admin/board.js` (Board section: list, editor with live preview of the website card, image
  upload, coupon picker, schedule, publish / archive / delete).
- Tests: `gateway/test/marketing_board_355.test.js`.
