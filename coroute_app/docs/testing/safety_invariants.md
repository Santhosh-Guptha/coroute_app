# CoRoute Formal Safety Invariants Specification

Document Identifier: CR-DOC-TEST-INV-002  
Version: 1.0.0-PROD  
Classification: Formal Safety Verification and Invariant Assurance  
Status: Authoritative Engineering Safety Baseline  
Character Encoding: UTF-8 (Strict ASCII hyphens, Zero raw emojis)

--------------------------------------------------------------------------------

## 1. Safety Architecture Philosophy

In safety-critical group motorcycle coordination, a software bug is not merely an inconvenience; a software bug can strand a rider without help, mislead a convoy leader regarding emergency assistance, compromise private medical disclosures, or cause fatal handlebar distraction at 100 km/h.

Therefore, CoRoute enforces a mathematical invariant-first verification model. A feature cannot be released simply because its happy path succeeds; it must formally guarantee that its core safety invariants hold under all adversarial conditions, including extreme packet loss, process death, clock drift, and untrusted peer relays.

--------------------------------------------------------------------------------

## 2. Exhaustive Formal Safety Invariants

### 2.1 Invariant 1: SOS Bundle Cryptographic Integrity & Authenticity

Definition:
An emergency packet or delay-tolerant emergency bundle originating from Rider $A$ must be authenticated, integrity-protected, and immutable across intermediate transport hops. No intermediate node, untrusted courier, or compromised relay device shall be capable of silently altering emergency coordinates, medical flags, timestamps, or origin identities.

Formal Expression:
For an emergency bundle $B = \langle H, P, \sigma \rangle$ where $H$ is the header, $P$ is the protected payload, and $\sigma$ is the cryptographic signature/authentication tag:
$$\forall \text{ relay } R_i: \quad \text{Verify}(B, K_{origin}) = \text{TRUE}$$
If any byte in $P$ or critical fields of $H$ is altered:
$$\text{Verify}(B', K_{origin}) = \text{FALSE} \implies \text{Drop}(B')$$

Enforcement Rules:
1. Payloads must utilize Authenticated Encryption with Associated Data (AEAD, e.g., AES-GCM or ChaCha20-Poly1305).
2. The relay header must carry an integrity tag computed over immutable header fields (origin pseudonym, creation timestamp, emergency incident ID).
3. Any bundle whose integrity check fails must be isolated immediately into quarantine and never presented to group members or external responders as a valid emergency.

Codebase Ground Truth & Implementation:
- Client deduplication: `lib/data/models/pending_sos.dart`
- Server validation: `gateway/src/convoys.js` (`handleSos`), `gateway/src/validate.js`
- Automated Test: `gateway/test/safety_sos.test.js`, `gateway/test/incident.test.js`

--------------------------------------------------------------------------------

### 2.2 Invariant 2: Zero Private Group Leakage

Definition:
A convoy configured with private visibility must never be disclosed to unauthenticated users, public discovery feeds, nearby group queries, or external responders. Social privacy settings must remain strictly decoupled from safety relay operations.

Formal Expression:
Let $G$ be a convoy group, $V(G) \in \{\text{PUBLIC}, \text{PRIVATE}\}$ be its visibility setting, and $D$ be the public discovery query output:
$$V(G) = \text{PRIVATE} \implies G \notin D \land \forall r \in G: r \notin D$$
Furthermore:
$$\text{SocialPrivacy}(G) = \text{PRIVATE} \centernot\implies \text{SafetyRelayConsent}(G) = \text{FALSE}$$
A private group may opt to relay opaque safety bundles or receive approaching hazard notifications without disclosing its own identity, route, or rider coordinates to third parties.

Enforcement Rules:
1. Zero private group IDs or member callsigns in `GET /api/v1/discovery`.
2. Approaching hazard alerts broadcast to a private group must disclose only the hazard coordinates, never the identities of the approaching convoy members.
3. Responding to an external emergency exposes only the minimum operational fields (responder first name, vehicle brand, route ETA) strictly after explicit user confirmation ("I CAN HELP").

Codebase Ground Truth & Implementation:
- Policy Enforcement: `gateway/src/discovery.js` (`DiscoveryService`), `gateway/src/feature_policy.js`
- Sanitization: `gateway/src/safety_network.js` (`sanitizeIncidentForExternal`)
- Automated Test: `gateway/test/net_privacy.test.js`, `gateway/test/discovery.test.js`

--------------------------------------------------------------------------------

### 2.3 Invariant 3: Ride Guardian Capability Token Revocation & Isolation

Definition:
A Ride Guardian web monitor link provides capability-based, time-bounded, read-only observation. The existence of `noindex` metadata does NOT constitute access control. Revoking a token must immediately and irrevocably terminate all active data streaming and prevent subsequent access across all caching layers.

Formal Expression:
Let $T$ be a capability token, $H(T) = \text{SHA256}(T)$ be its stored hash, and $S(T) \in \{\text{ACTIVE}, \text{PAUSED}, \text{EXPIRED}, \text{REVOKED}\}$ be its grant state:
$$\text{Revoke}(T) \implies S(T) = \text{REVOKED}$$
$$\forall t > t_{revoke}: \quad \text{AccessRequest}(T) \implies \text{HTTP 410 GONE} \land \text{TerminateSockets}(T)$$
Furthermore, projection filtering must enforce:
$$\text{Level}(T) = \text{BASIC} \implies \text{Coordinates}(T) = \emptyset$$
$$\text{Level}(T) = \text{EMERGENCY\_ONLY} \land \neg \text{HasEmergency}(G) \implies \text{Coordinates}(T) = \emptyset$$

Enforcement Rules:
1. Raw tokens are never persisted in the database; only SHA-256 digests are stored.
2. Web monitoring pages (`gateway/public/watch.html`) must contain `<meta name="robots" content="noindex,nofollow">` and `Referrer-Policy: no-referrer`.
3. Revocation must close existing WebSocket/SSE streams within 500 ms and trigger client-side DOM sanitization.
4. When a ride ends, all issued Guardian tokens expire automatically at $T_{ended} + 6\text{ hours}$.

Codebase Ground Truth & Implementation:
- Token & Projection Engine: `gateway/src/guardians.js` (`GuardianService`, `projectPersonal`)
- Web Interface: `gateway/public/watch.html`, `gateway/public/assets/guardian.js`
- Automated Test: `gateway/test/guardians.test.js`, `gateway/test/guardian_browser.test.js`

--------------------------------------------------------------------------------

### 2.4 Invariant 4: Conservative Usable Fuel Reachability

Definition:
CoRoute provides fuel range estimations based on mathematical consumption modeling and rider profiles. The system shall NEVER display an estimated fuel range as an exact physical tank reading, and shall NEVER endorse skipping a fuel station if the subsequent mapped station exceeds the rider's conservative safe range.

Formal Expression:
Let $R_{baseline}$ be the confirmed baseline fuel range, $D_{ridden}$ be verified GPS distance, $R_{reserve}$ be mandatory reserve distance, and $B_{safety}$ be the caution buffer ($B_{safety} \ge 20\text{ km}$):
$$R_{safe} = \max(0, R_{baseline} - D_{ridden} - R_{reserve} - B_{safety})$$
Let $S_{next}$ and $S_{following}$ be the road distances to the next and subsequent mapped fuel stations along the route:
$$R_{safe} < S_{next} \implies \text{Advice} = \text{RANGE\_RISK}$$
$$S_{following} > R_{safe} \implies \text{Advice} = \text{RECOMMENDED (Refuel Now)}$$
$$S_{following} \le R_{safe} \land S_{following} + B_{safety} > R_{safe} \implies \text{Advice} = \text{CONSIDER}$$
$$S_{following} + B_{safety} \le R_{safe} \implies \text{Advice} = \text{WITHIN\_ESTIMATE}$$
$$\text{StationCoverage} = \text{PARTIAL} \implies \text{AllowSkipEndorsement} = \text{FALSE}$$

Enforcement Rules:
1. All displayed fuel values must carry explicit estimation labels in the UI.
2. If GPS tracking experiences an abnormal distance teleport (> 500 m jump) or extended gap, fuel state transitions to `uncertain = true` and suppresses skip endorsements.
3. In a group fuel bottleneck calculation (`group_fuel.dart`), individual rider private tank capacities must not be broadcast to the group; only the aggregated bottleneck stop and limiting rider name are surfaced.

Codebase Ground Truth & Implementation:
- Single-Rider Estimation: `lib/domain/safety/fuel_range.dart`, `lib/domain/safety/fuel_profile.dart` (`fuelAdvice`)
- Convoy Bottleneck: `lib/domain/safety/group_fuel.dart` (`commonFuelStop`)
- Automated Test: `test/fuel_range_test.dart`, `test/group_fuel_stop_test.dart`

--------------------------------------------------------------------------------

### 2.5 Invariant 5: Sweeper Distress Reverse-Escalation Safeguard

Definition:
The designated Sweeper rides at the rear of the convoy as the ultimate safety net. If the Sweeper halts or loses connectivity while the convoy pack continues moving forward, the system must immediately trigger a high-priority audible reverse-escalation alarm on the Convoy Lead's cockpit.

Formal Expression:
Let $R_{lead}$ and $R_{sweeper}$ be the designated lead and sweeper riders:
$$\text{Speed}(R_{sweeper}) < 5\text{ km/h} \land \text{Speed}(R_{lead}) > 35\text{ km/h} \land \Delta t_{halt} \ge 90\text{ s} \implies \text{Trigger}(\text{SWEEPER\_DISTRESS})$$
$$\text{HeartbeatAge}(R_{sweeper}) > 90\text{ s} \land \text{Speed}(R_{lead}) > 35\text{ km/h} \implies \text{Trigger}(\text{SWEEPER\_DISTRESS})$$

Enforcement Rules:
1. Reverse-escalation alert must sound an immediate spoken TTS cue to the Lead: "Attention Lead: Sweeper has stopped X kilometers behind. Halt convoy."
2. The Sweeper distress state cannot be auto-dismissed; it remains active on the Lead HUD until explicitly acknowledged or until the convoy halts.
3. If cellular data is absent on the Sweeper's device, the app initiates an automated emergency SMS directly to the Lead's phone number containing exact GPS coordinates.

Codebase Ground Truth & Implementation:
- Gateway Watchdog: `gateway/src/timeline.js` (`checkSweeperDistress`)
- Mobile Alert & TTS: `lib/data/services/voice_service.dart`, `lib/presentation/rider/live_cockpit_map_screen.dart`
- Automated Test: `gateway/test/convoy_watchdog.test.js`, `test/scenario_convoy_dynamics_test.dart`

--------------------------------------------------------------------------------

### 2.6 Invariant 6: In Case of Emergency (ICE) Medical Isolation & Purge

Definition:
A rider's confidential medical profile (blood group, severe allergies, chronic medications, organ donor flag) exists exclusively for lifesaving trauma response. Medical data must remain strictly isolated on the local device, disclosed to convoy members only while an active emergency alert is open, and permanently purged from server memory upon emergency resolution.

Formal Expression:
Let $M(u)$ be the medical profile of user $u$, $A(u)$ be the set of open emergency alerts for $u$, and $E$ be external systems (Admin APIs, Analytics, Public Discovery, Timeline):
$$\forall E: \quad M(u) \cap E = \emptyset$$
$$\text{Broadcast}(M(u)) = \begin{cases} \text{ActiveRoomMembers}, & \text{if } \exists a \in A(u): a.\text{open} = \text{TRUE} \\ \emptyset, & \text{otherwise} \end{cases}$$
$$\text{Resolve}(a) \lor \text{TripEnd}(G) \implies \text{PurgeServerMemory}(M(u))$$

Enforcement Rules:
1. Medical info is returned only to the owner during routine profile queries (`GET /me`); it is never returned in admin user lists or fleet dashboards.
2. When an emergency is resolved (`SOS_RESOLVE`), the gateway removes `medicalInfo` from memory and echoes the resolved alert without medical fields.
3. When a ride ends, all cached emergency alerts have their medical fields stripped immediately.

Codebase Ground Truth & Implementation:
- Data Model: `lib/data/models/medical_info.dart`, `lib/data/models/ice_profile.dart`
- Gateway Isolation: `gateway/src/auth.js`, `gateway/src/convoys.js` (`resolveSos`)
- Automated Test: `gateway/test/profile_medical.test.js`, `gateway/test/emergency_status.test.js`

--------------------------------------------------------------------------------

## 3. The Seven Cardinal Distinctions (State-Confusion Prevention)

To prevent catastrophic false-confidence across mobile UX, gateway telemetry, and test assertions, every layer must preserve the following formal distinctions:

1. `MESSAGE_CREATED != MESSAGE_DELIVERED`:
   Queuing an emergency SOS into the local device SQLite outbox does not mean the message has been received by the group. The UI must state "Waiting for signal / Sending...", never "Delivered".
2. `RELAY_ACCEPTED != CLOUD_REACHED`:
   An offline courier or peer accepting an encrypted emergency bundle indicates transport pickup only. The app must never report "Emergency Help Contacted" upon peer handoff.
3. `CLOUD_REACHED != HUMAN_HELP_ARRIVED`:
   The gateway acknowledging an emergency SOS packet means the convoy room has been notified. The UI must never state "Help has reached you" until a responder reports `ARRIVED` or the rider confirms resolution.
4. `ESTIMATED_FUEL_RANGE != MEASURED_FUEL_LEVEL`:
   Because motorcycles lack OBD-II/sensor integration in CoRoute, all fuel calculations are estimations. The UI must explicitly label every fuel metric as an estimate.
5. `NOINDEX != AUTHORISATION`:
   Placing `<meta name="robots" content="noindex">` on a webpage does not protect private trip coordinates. Cryptographic capability token validation and PIN access control must be evaluated independently.
6. `PRIVATE_SOCIALLY != UNAVAILABLE_FOR_SAFETY`:
   A convoy that elects private social visibility is hidden from discovery feeds, but remains capable of receiving approaching hazard alerts and relaying opaque emergency bundles.
7. `LAST_KNOWN_LOCATION != LIVE_LOCATION`:
   When GPS updates cease (tunnel, dead zone, dead battery), the last fix must be prominently marked with an elapsed staleness timer and degraded confidence indicator. It must never be rendered as a live fix.

--------------------------------------------------------------------------------

## 4. Delay-Tolerant Network (DTN) Circulation Invariants

For all current and future delay-tolerant routing protocols (RFC 9171 / 9172):

### 4.1 Bounded Bundle Lifetime (TTL Invariant)
Let $B$ be a bundle with creation time $t_{create}$ and time-to-live $\text{TTL}$. Let $t_{now}$ be the current verification time:
$$t_{age} = t_{now} - t_{create}$$
$$t_{age} \ge \text{TTL} \implies \text{DropBundle}(B) \land \neg \text{Deliver}(B)$$
An expired bundle shall NEVER be delivered to riders, guardians, or cloud gateways as an active emergency. If retained for crash forensic audit, it must be flagged with `EXPIRED_STATUS = TRUE`.

### 4.2 Strictly Monotonic Hop Counter (Loop Elimination Invariant)
Every bundle forwarding step between two distinct nodes must increment the hop count:
$$H_{next} = H_{current} + 1$$
$$H_{next} > H_{limit} \implies \text{DropBundle}(B)$$
A bundle must never circulate indefinitely in relay cycles ($A \to B \to C \to A$).

### 4.3 Replication Budget Conservation
Under Spray-and-Wait routing with initial replication budget $L$:
$$\sum_{i \in \text{Carriers}} L_i \le L_{initial}$$
Replication budget must strictly decrement upon forwarding and shall never underflow below 0 or spawn infinite epidemic copies.

--------------------------------------------------------------------------------

## 5. Audio Safety and Preemption Invariant

Audio alerts received over Bluetooth helmet communicators (Cardo, Sena, BluArmor) must obey a strict hierarchical preemption order:

$$\text{Priority}(\text{P0 SOS / Crash}) > \text{Priority}(\text{P1 Sweeper Distress}) > \text{Priority}(\text{P2 Intercom Audio}) > \text{Priority}(\text{P3 Music / Chimes})$$

1. Active routine intercom audio must never block, silence, or delay a P0 life-safety voice alert.
2. Playing an earcon or text-to-speech warning must duck background media by at least 70% ($0.3 \times \text{Volume}_{media}$).
3. Speech notifications must be throttled to a maximum of 6 words per utterance to minimize cognitive load while cruising at highway speeds.
