# Data Processing Note for Operators (DRAFT)

> **DRAFT FOR LEGAL REVIEW. Not legal advice.** This note describes, from the product as built (CoRoute 3.56), what rider data an Operator receives through CoRoute and when. It also lists the points CoRoute's counsel should settle under India's **Digital Personal Data Protection Act, 2023 ("DPDP Act")** and the rules made under it. The data flows below are factual. The legal characterisations are proposals, marked [LEGAL] for counsel to confirm.

---

## 1. Parties and roles (proposal)
- **CoRoute** collects riders' personal data to provide the app, and decides why and how that data is processed. It is proposed to act as a **Data Fiduciary** towards riders.
- **Operator** receives a limited set of rider data through the Console and uses it for its own purposes: organising rides and responding to emergencies. [LEGAL: decide whether the Operator is (a) an independent Data Fiduciary for the data it receives, or (b) a Data Processor acting for CoRoute, or a mix by data type. This note assumes **(a) for organising rides and SOS response**, because the Operator decides how it acts on the data. Draft the obligations below to work in either case.]
- **Riders** are the **Data Principals**.

## 2. What data the Operator receives, and when

| Data | When visible | Where | Notes |
|---|---|---|---|
| Username, first name, roster role, join date, how they joined | While the rider is on the roster | Console > Roster | Riders accept invites themselves. |
| Ride sign-up (username, first name, status) | For rides with a public sign-up page | Console > Rides > Sign-ups | |
| Live position, speed, battery level, last update, riding role | **Only during the Operator's own live rides** | Console > Live map | The map refreshes every 5 s. Nothing is shown after the ride ends. |
| Attendance: joined and left times, finished, distance, incident type, time and outcome | After the ride | Console > Attendance & reports, and CSV | **No coordinates, phone numbers or e-mail.** |
| **SOS data**: emergency contact name and phone, rider's phone, medical info (blood group, allergies, notes), last position | **Only while that rider has an open SOS or crash alert in the Operator's live ride**, and only if the "Roster & emergency contacts during an SOS" feature is granted | Console > Live map > Emergency contact | Every view is recorded in CoRoute's audit log (`operator.sos_contacts_viewed`). The view closes once the alert is resolved. |

**Not provided to the Operator**:
- phone, e-mail or medical info outside an open SOS;
- positions outside the Operator's live rides;
- stored tracks on a map, home locations;
- plans and payments;
- device or sensor data.

**Data the Operator gives CoRoute**:
- the business e-mail and phone (seen only by CoRoute admins and the Owner);
- the organisation details;
- ride details;
- broadcast text.

## 3. Purposes (proposal)
1. Organising rides: rosters, invitations, sign-ups, ride roles, attendance.
2. Rider safety during rides: the live map and alerts.
3. **Responding to a medical or safety emergency** of a rider, using the SOS data.
4. Records the Operator must keep by law or for its legitimate business needs (for example, an attendance record). [LEGAL]

## 4. Lawful basis (points for counsel)
- **Consent (DPDP Act s.6)**: riders accept an Operator's invitation or sign up for its ride.
  - The /clubs page, the join-link page and the public ride page tell riders that the organiser sees their username, first name and live position during rides.
  - The **/clubs** page also says that an emergency contact is shown to the organiser only during the rider's open SOS.
  - **Gap to fix**: the join-link card and the public ride page say only "Your phone, e-mail and medical ID stay private" and do not mention the SOS exception.
  - **Gap to fix**: there is no in-app consent screen at join ("This ride is run by …"). It is listed as not built.
  - [LEGAL: decide whether the current notices meet s.5 (notice) and s.6 (free, specific, informed, unambiguous consent), and in which languages.]
- **Legitimate uses (s.7)**: s.7 lists certain uses without consent, including responding to a **medical emergency involving a threat to the life or health** of the Data Principal. [LEGAL: confirm whether, and how far, the SOS view can rely on s.7, given that it is limited to an open alert.]
- **Medical information**: the DPDP Act does not create a separate "sensitive" category, but medical info calls for high care. [LEGAL: confirm.]
- **Children**: verifiable parental consent is needed for riders under 18 (s.9). CoRoute does not verify age at club join. [LEGAL / OWNER: set the policy.]
- **CoRoute privacy policy**: an update for the DPDP Act is listed as **Planned (v3.57)** in CoRoute's release plan. [LEGAL: align this note with it.]

## 5. Operator obligations (proposal)
The Operator shall:
1. **Purpose limitation**: use rider data only for the purposes in section 3. Use SOS data **only to help that rider during that emergency**, for example by calling the emergency contact, informing 112 or responders, or guiding the sweeper.
2. **Minimisation**: not copy SOS data out of the Console (screenshots, chat groups, spreadsheets) unless the emergency requires it, and then share it only with people helping the rider.
3. **Retention**: delete SOS data and exported CSV files once the purpose is served, unless the law requires keeping them. Keep incident records only as [LEGAL / OWNER TO FILL].
4. **Security**: keep console accounts to named people, use strong passwords, sign out of shared computers, and store exports encrypted or access-controlled.
5. **Co-organisers**: give access only to trained staff or volunteers bound by confidentiality, and remove it when they leave.
6. **Breach**: tell CoRoute without undue delay [OWNER TO FILL: e.g. within 24 hours] of any suspected unauthorised access or disclosure, and cooperate on the notices to the Data Protection Board and the affected riders that the DPDP Act and Rules require. [LEGAL: confirm the timelines under the DPDP Rules.]
7. **Rider rights**: pass any request about data held by the Operator (access, correction, erasure, grievance) to the right handler. Respond to requests about the Operator's own copies, such as CSV files and incident logs, and refer requests about CoRoute's data to CoRoute.
8. **No onward transfer or sale** of rider data. No marketing to riders using CoRoute data.
9. **Cross-border**: not transfer rider data outside India except as the law permits. [LEGAL: confirm the current government notifications under s.16.]
10. **Audit cooperation**: answer CoRoute's questions about logged SOS views or exports.

## 6. What CoRoute does (as built)
- Shows SOS data only during an open alert in the Operator's own live ride, behind a feature switch.
- Records each SOS view and each report export in the audit log.
- Keeps phone numbers, e-mail and contact fields out of roster, sign-up, live and report responses. This is covered by automated tests.
- Leaves coordinates out of reports and CSV files, and protects CSV cells against formula injection.
- Lets riders leave a club at any time (website or app), decline invites and cancel sign-ups.
- When a rider deletes their account, removes them from rosters and sign-ups. When an Operator owner deletes their account, removes the operator, its rides, broadcasts and club roster.
- Gives the Console a strict content security policy and loads no third-party scripts. Map tiles come from OpenStreetMap.
- Masks server SMS logs and deletes SMS rows after 48 hours (for the SOS texts CoRoute sends to emergency contacts).

## 7. Open points for counsel
1. The Operator's role: independent fiduciary or processor (section 1).
2. Whether the existing notices and the missing in-app consent screen are sufficient (section 4).
3. Whether s.7 covers the SOS view.
4. Children's data policy.
5. The retention period for Operator incident records and CSV exports.
6. The breach-notice chain and timelines under the DPDP Rules, and which obligations are in force on the signing date.
7. Grievance officer details for CoRoute and for each Operator.
8. Interaction with the Operator's other duties (tourism, transport, insurance, police reporting after accidents).

*Prepared from the CoRoute 3.56 product documentation. Not legal advice.*
