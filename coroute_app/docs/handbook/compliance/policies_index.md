# Policies index

All public and draft policies for CoRoute, where they live and their review status. Written
11 Nov 2026. **No policy has had a legal review yet.**

## 1. Public policies (live on the website)

| Policy | Public URL | Source file | Status | Notes |
|---|---|---|---|---|
| Privacy Policy | `https://coroute.devmonks.space/privacy` | [`gateway/public/privacy.html`](../../../gateway/public/privacy.html) | Live, updated 11 Nov 2026: the 10 findings in [privacy_compliance_pack.md §3](privacy_compliance_pack.md#3-findings-privacyhtml-out-of-date-with-the-code-11-nov-2026) are **fixed** (always-on safety, diagnostics path, deletion timeline, service providers, rights, grievance officer). **Legal review pending.** | Play privacy policy URL |
| Privacy & security (plain language) | `https://coroute.devmonks.space/privacy-and-security` | [`gateway/public/privacy-and-security.html`](../../../gateway/public/privacy-and-security.html) | Live (3.56). Linked from the app (Profile > Help > Privacy & terms > Your data). **Legal review pending.** | Must stay consistent with privacy.html |
| Terms of Use | `https://coroute.devmonks.space/terms` | [`gateway/public/terms.html`](../../../gateway/public/terms.html) | Live, updated 11 Nov 2026. **Legal review pending.** | **Fixed:** roles (Trip owner = creator, Trip head = settings only, Lead = riding role), plans bought on the website, upgrade-only while active, no auto-renewal, access modes may make hosting free, refunds per `/refunds`, clubs/operators section, "assists, does not replace emergency services, call 112". Still open: link the community guidelines once published; link the operator terms after legal review. |
| Account deletion | `https://coroute.devmonks.space/delete-account` | [`gateway/public/delete-account.html`](../../../gateway/public/delete-account.html) | Live. **Aligned** with privacy.html (11 Nov): in the app at once, by request within 48 h, backups expire within 30 days; current app path. **Legal review pending.** | Play "delete account URL" |
| Safety page | `https://coroute.devmonks.space/safety` | `gateway/public/safety.html` | Live (marketing + safety claims) | Claims must match device-tested behaviour |
| Refund / cancellation policy | `https://coroute.devmonks.space/refunds` | [`gateway/public/refund_policy.html`](../../../gateway/public/refund_policy.html) | Live (11 Nov). Website purchases only, no auto-renewal, admin full/partial refunds (a full refund ends the plan). Linked from the footer, terms, plans, checkout, account and receipt. **Refund criteria, reply and settlement times [OWNER TO FILL]** (HTML comment). **Legal review pending.** | Razorpay checks the site for it |
| Grievance officer / contact | `/privacy#grievance` | privacy.html | Section live; shows the `SUPPORT_EMAIL` address. **Name, postal address, response times [OWNER TO FILL]** | DPDP Act |
| security.txt / responsible disclosure | `/.well-known/security.txt`, `/security` | `src/app.js` `securityTxt()` (served from config), [`gateway/public/security.html`](../../../gateway/public/security.html) | Live (11 Nov). Contact = `SECURITY_CONTACT`, else `SUPPORT_EMAIL`, else the `/security` page; Expires one year ahead | Response targets in §10 of the security overview stay [OWNER TO FILL] |

## 2. Community and operator policies (handbook drafts)

| Policy | Path | Status |
|---|---|---|
| Community guidelines (riders) | [../users/community_guidelines.md](../users/community_guidelines.md) (users pack, index [../users/00_README.md](../users/00_README.md)) | Draft; not yet published on the website; admin "Warn" uses a guidelines line. **Legal review pending.** |
| Privacy summary for riders | [../users/privacy_summary_for_riders.md](../users/privacy_summary_for_riders.md) | Draft; must match privacy.html after its update |
| Operator terms (draft) | [../operators/operator_terms_DRAFT.md](../operators/operator_terms_DRAFT.md) (operators pack, index [../operators/00_README.md](../operators/00_README.md)) | Draft. **Legal review pending.** Needed before approving the first operator |
| Operator data processing note (draft) | [../operators/data_processing_note_DRAFT.md](../operators/data_processing_note_DRAFT.md) | Draft; decide whether operators are joint controllers or processors (privacy pack §1 row 33) |
| Rider consent and waiver for operator rides (draft) | [../operators/rider_consent_and_waiver_DRAFT.md](../operators/rider_consent_and_waiver_DRAFT.md) | Draft. **Legal review pending.** |
| Partner programme | [../operators/partner_program.md](../operators/partner_program.md) | Draft; partner perks must follow the Play policy guard |

## 3. Internal compliance documents

| Document | Path |
|---|---|
| Privacy compliance pack (data inventory, DPDP) | [privacy_compliance_pack.md](privacy_compliance_pack.md) |
| Google Play compliance | [play_store_compliance.md](play_store_compliance.md) |
| Consent and retention register | [consent_and_retention_register.md](consent_and_retention_register.md) |
| Security overview | [../technical/security_overview.md](../technical/security_overview.md) |
| Incident response (breach handling) | [../technical/incident_response_and_sos_ops.md](../technical/incident_response_and_sos_ops.md) |
| Play payments policy (engineering rules) | [docs/features_355/play_payments_policy.md](../../features_355/play_payments_policy.md) |
| Play permissions and data safety checklist | [docs/PLAYSTORE_PERMISSIONS.md](../../PLAYSTORE_PERMISSIONS.md) |
| Web payments security review | [docs/features_355/web_payments_security.md](../../features_355/web_payments_security.md) |

## 4. Review status and next steps

| Step | Owner | Status |
|---|---|---|
| Fix privacy.html findings and align deletion wording | owner + dev | **Done** (11 Nov 2026) |
| Name grievance officer; role e-mail addresses (support, security, grievance) | owner | Open: set `SUPPORT_EMAIL` / `SECURITY_CONTACT` to role addresses; fill the grievance comment in privacy.html |
| Write refund / cancellation policy | owner + lawyer | Page live (`/refunds`); owner fills criteria and timelines; lawyer review pending |
| Publish community guidelines on the website and link from Terms | owner | Open |
| Legal review of privacy, terms, deletion, operator terms, waiver | lawyer | **Pending** |
| DPDP gap closure (notice languages, consent records, 18+ confirmation, export, nominee) | owner + dev | Open |
| Hindi / Telugu versions of the privacy notice | owner | Open (see [../users/translations_needed.md](../users/translations_needed.md)) |

Review cadence: re-check all policies at every release that changes data, permissions, settings or
payments, and at least every 6 months.
