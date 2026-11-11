# CoRoute handbook

The documentation set for everyone who works with CoRoute: investors, operators and partners,
riders and support staff, engineers and operators of the service, and whoever owns privacy and
store compliance. Prepared 11 November 2026 from the code and docs of v3.55 (with the 3.56 web,
payments and operator work in the tree). CoRoute is **pre-launch**.

For a one-file overview (what CoRoute is, owner decisions, current state, repo map, where things
live) read **[PROJECT_CONTEXT.md](../../PROJECT_CONTEXT.md)** first.

## Packs

| Pack | For | Start here | Highlights |
|---|---|---|---|
| **Investors** | investors, accelerators, partners, press | [investors/00_README.md](investors/00_README.md) | one pager, investor memo, pitch deck outline, business model and pricing, financial model template, KPIs, due diligence checklist, press kit |
| **Operators** | tour operators, riding clubs, rental and corporate fleets, partners | [operators/00_README.md](operators/00_README.md) | overview, onboarding guide, operator console manual, ride organiser SOP, safety briefing template, FAQ, support escalation, partner programme; drafts: operator terms, data processing note, rider consent and waiver |
| **Users** | riders and the support team | [users/00_README.md](users/00_README.md) | quick start, user guide, safety guide, FAQ, troubleshooting, privacy summary, community guidelines, release notes, support playbook |
| **Technical** | engineers, coding agents, the people running the servers | [technical/](#technical) | architecture, API, data model, mobile app, development, deployment and operations, incident and SOS operations, security, QA, glossary |
| **Compliance** | owner, privacy / grievance officer, legal reviewer, Play Console owner | [compliance/](#compliance) | privacy pack (data inventory, DPDP Act), Google Play compliance, consent and retention register, policies index |

## Technical

| # | Document | What it covers |
|---|---|---|
| 1 | [architecture.md](technical/architecture.md) | System overview, two-VM live/web roles, mirror, job leases, realtime protocol and HELLO features, data flows (live positions, SOS end to end, crash detection, siren/audio, intercom, web purchase → capabilities, access modes, operator rides), push/mail/SMS, TLS and domains, external services |
| 2 | [api_reference.md](technical/api_reference.md) | Every REST endpoint by area with auth and limits; WebSocket message types both ways; close codes |
| 3 | [data_model.md](technical/data_model.md) | Collections, key fields, indexes, retention and purge jobs, replication and backups |
| 4 | [mobile_app.md](technical/mobile_app.md) | App structure, services, Kotlin platform channels, permissions, background service, settings migrations, feature flags, diagnostics logging, Play policy scan |
| 5 | [development_guide.md](technical/development_guide.md) | Setup, build, tests and counts, conventions, adding a feature switch, release versioning |
| 6 | [deployment_and_operations.md](technical/deployment_and_operations.md) | Environments, environment variable catalogue, deploy, monitoring and logs, scaling, backups and restore, domains and TLS, failover drills, secrets rotation |
| 7 | [incident_response_and_sos_ops.md](technical/incident_response_and_sos_ops.md) | Severity matrix, on-call, SOS/crash playbook, outage runbooks, communication templates, post-mortem template |
| 8 | [security_overview.md](technical/security_overview.md) | Threat model, auth, transport, web security, payments, admin audit, privacy by design, known limits and pending items, responsible disclosure draft |
| 9 | [qa_test_plan.md](technical/qa_test_plan.md) | Automated test inventory, device test matrix, regression checklist, Play pre-launch report handling |
| 10 | [glossary.md](technical/glossary.md) | Trip owner, trip head, Lead, Middle, Sweeper, crew, operator, access mode, capability and more |

## Compliance

All compliance documents are **drafts for legal review, not legal advice**.

| # | Document | What it covers |
|---|---|---|
| 1 | [privacy_compliance_pack.md](compliance/privacy_compliance_pack.md) | Data inventory (element, purpose, basis, who sees it, retention, deletion), India DPDP Act 2023 (notice, consent, rights, grievance officer, breach notification, children, processors and cross-border transfers), findings where `privacy.html` is out of date |
| 2 | [play_store_compliance.md](compliance/play_store_compliance.md) | Consumption-only payments policy, data safety answers, sensitive permission declarations, in-app review rules, notifications and ads, account deletion, target API, closed testing requirement, app content checklist |
| 3 | [consent_and_retention_register.md](compliance/consent_and_retention_register.md) | Every consent, opt-in, opt-out and fixed default; every server and phone retention rule, verified in code |
| 4 | [policies_index.md](compliance/policies_index.md) | Public policies (privacy, privacy & security, terms, account deletion) and drafts (community guidelines, operator terms, waiver) with paths, URLs and review status |

## Other sources

- Engineering docs: [docs/](../) (release notes `V3_55_RELEASE.md`, `FEATURE_STATUS.md`,
  `features_355/`, runbooks, `testing/`).
- Release procedure: [docs/MASTER_AGENT_PROMPT_v3.55.md](../MASTER_AGENT_PROMPT_v3.55.md).
- Next release: [docs/NEXT_RELEASE_PLAN_v3.56.md](../NEXT_RELEASE_PLAN_v3.56.md).
- Older PDF manuals: [docs/manuals/](../manuals/) (superseded by the users and investors packs).

## Conventions across packs

- Names follow the [UX naming guide](../UX_NAMING_GUIDE_v3.55.md) and the [glossary](technical/glossary.md).
- Values the owner must decide are marked **[OWNER TO FILL]**; legal questions **[LEGAL REVIEW]**.
- No secrets in any document: environment variables are named, never valued.
- Update the relevant pack whenever a release changes behaviour, data, permissions or payments.
