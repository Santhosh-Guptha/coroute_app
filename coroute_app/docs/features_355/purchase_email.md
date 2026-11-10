# Purchase receipt and refund e-mails (3.56)

After a successful website payment the rider gets one receipt e-mail with the payment details.
After a refund they get one refund e-mail. The e-mails go out over SMTP (nodemailer). When SMTP is
not configured they are off and nothing else changes.

## When they are sent

Every write of a ledger order goes through `repo.updateRazorpayOrder`. `attachPurchaseEmail`
(`gateway/src/purchase_email.js`) wraps that method once, so all payment paths are covered
without changing them:

| Order patch | E-mail | Sent once per |
| --- | --- | --- |
| `status: 'PAID'`: `/membership/verify`, the Razorpay webhooks (`settleMembershipPayment`), downgrades, legacy paths | Receipt | order: key `receipt:<orderId>` |
| `refundedAmountInPaise` / `refundStatus`: the admin refund or the `refund.processed` webhook | Refund (only when the refund status is PROCESSED) | refunded amount: key `refund:<orderId>:<paise>` |

- **Exactly once**: before sending, a row with a unique `key` is inserted in `mail_log`. A second
  insert (the webhook after the payment check, a retried webhook, the other gateway node) fails,
  and nothing is sent.
- The e-mail is sent in the background, never on the payment request.
- A failed SMTP send is marked RETRY. The leased job `mail-retry` (every 5 min) tries again, 3
  tries in all.
- **No receipt** for a ₹0 / free activation.
- The `mail_log` row keeps a masked address only (`a***@example.com`) plus the message id or the
  error code. Logs never carry addresses or bodies.

## The address

1. The order's `receiptEmail`: the optional **"Email for your receipt"** field on `/plans`.
   - `public/assets/plans.js` posts it after the order is created, to
     `POST /api/web/receipt-email {orderId, email}`. This endpoint is for the rider's own order
     only, rate limited 10 a minute.
   - The address is stored on the order only, never on the account.
2. Else the account e-mail.
3. Neither: skipped. No row is written, so an address given right after a very fast payment still
   gets the receipt (the endpoint sends it then).

## What the receipt says

The words (subject, heading, intro, footer) come from the editable template **Purchase receipt
e-mail** (web admin > Templates). The rest is built by the server from `web_shop.receiptOf`, the
same data as the `/receipt` page:

- the plan line with the list price, the launch offer, the coupon and the credit for the
  remaining plan, each exactly as the server priced the order (the quote breakdown);
- tax lines, if the server ever adds them to the breakdown (it computes no tax today);
- **Amount charged**;
- plan, period (India dates), payment id, order id, receipt number, date and time (IST), paid
  with;
- a "View receipt" button to `https://<PUBLIC_ORIGIN>/receipt?order=<orderId>`;
- the support e-mail (`SUPPORT_EMAIL`).

The e-mail has an HTML part (calm, branded, table layout that works in mail apps; every value
escaped) and a plain-text part.

The refund e-mail (template **Refund e-mail**) shows what was paid, what was refunded, the refund
id and full / part refund.

## Owner setup (SMTP)

1. Pick a sender. Any SMTP service works: Amazon SES, Zoho Mail, Google Workspace SMTP relay,
   Brevo, Mailgun or Postmark (SMTP mode).
2. Verify the sending domain at the provider. Add the SPF and DKIM records it gives you to your
   DNS, and add a DMARC record (`v=DMARC1; p=none; rua=mailto:...` to start).
3. Set on both gateway VMs (server secret store, never in the repo):

   | Variable | Example |
   | --- | --- |
   | `SMTP_HOST` | `email-smtp.ap-south-1.amazonaws.com` |
   | `SMTP_PORT` | `587` (STARTTLS, default) or `465` (implicit TLS) |
   | `SMTP_USER` / `SMTP_PASS` | SMTP credentials |
   | `MAIL_FROM` | `CoRoute <receipts@your-domain>` |
   | `MAIL_REPLY_TO` | optional, for example `support@your-domain` |
   | `SMTP_SECURE` | optional `true` / `false`; the default is from the port |
   | `SUPPORT_EMAIL` | already used by the site; shown in the e-mails |

   TLS certificates are always verified (TLS 1.2 or newer). Without `SMTP_HOST` and `MAIL_FROM`
   the mailer is a no-op, logged once.
4. Restart the gateways. Make a test purchase in Razorpay test mode. The receipt arrives, and
   `mail_log` has a SENT row.
5. Optional: edit the words in web admin > Templates > Purchase receipt e-mail / Refund e-mail.
   The preview shows sample values.

## Files

- `gateway/src/mailer.js`: SMTP transport from env; `send()` never throws.
- `gateway/src/purchase_email.js`: the hook, idempotency, layout, retry, `/api/web/receipt-email`.
- `gateway/src/templates.js`: `purchase_receipt`, `refund`.
- `gateway/public/plans.html`, `gateway/public/assets/plans.js`: the optional receipt address.
- Dependency: `nodemailer` 10.2.1 (exact).
- Test: `gateway/test/purchase_email_355.test.js` (fake transport). It covers:
  - one receipt across webhook + verify;
  - every detail line;
  - receipt address on the order;
  - other rider's order refused;
  - free and missing-address skips;
  - disabled mailer;
  - refund once;
  - SMTP retry;
  - template edit, validation, history and reset;
  - plan push template.
