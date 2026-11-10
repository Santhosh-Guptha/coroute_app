# Settings live audit (v3.55)

The report: "I changed the speed limit in the middle of the ride but it's not updating. Check the
other features too. Wherever switching or changing a setting should take effect, it must show."

For every setting or switch a rider, a lead or an admin can change, this audit followed the path
from the control to the service and its state, then to storage, then to every consumer. For each
one it asked:
- Does the consumer re-read the value when it uses it, or listen for changes, rather than caching
  it at ride start?
- Does the UI watch the right notifier?
- Do group settings reach the other riders?
- Is an offline change lost without telling the rider?

Fixes are tagged `3.55 fix` in the code.

"Live" means a change applies mid-ride without restarting the app or the ride.

## Rider settings (SettingsService)

| Setting | Changed in | Consumers | Live before? | Fix |
|---|---|---|---|---|
| Speed warning (personal km/h) | Settings | SafetyService._checkSpeedLimit, cockpit speed chip | **No**: the group limit always won | Lead fix: `effectiveSpeedLimit()` uses the stricter of the two, with an immediate re-check on a settings or convoy change |
| Crash detection | Settings, ride start view, pre-ride check | SafetyService (_onFix, _updateSensor, rider-down, alarm open) | Yes: read on every fix, and the sensor subscribes or unsubscribes in `_onSettings` | none. An alarm that is already counting down is not cancelled by switching off (safety) |
| Emergency texts (SMS fallback) | Settings | SafetyService SMS round and timer, ConvoyService roster | Yes: `_onSettings` arms a pending SOS timer, and the roster is fetched or cleared on change | none. The round re-checks the opt-out when it fires. An offline solo ride always texts the contact |
| Break reminder (fatigue) | Settings | SafetyService | **No**: the 2-hour rule (`FatigueTracker.onFix` returns `remind`) prompted and spoke even with the reminder off | `remind && _settings.fatigueReminder` (safety_service.dart, _onFix). The tracker keeps counting for stats and the score |
| "Are you OK?" check-in (solo) | Settings | SafetyService._evalCheckIn | Yes | none |
| Solo ETA check-in | Settings | SoloGuardianService._checkInAllowed (30 s tick and listener) | **Partly**: switching it off disarmed it, but switching it back on in the same ride never re-armed it (`_armedOnce`) | `_armedOnce.remove(groupId)` when disarmed because the check-in is not allowed (setting, admin switch, contact removed) |
| No-signal ahead | Settings | SoloGuardianService._evalSignalAhead | Yes (per tick) | none |
| Speak warnings and directions | Settings, quick settings | VoiceService._allowed / speak* | Yes for new lines; **no** for lines already queued | VoiceService listens to settings: `dropDisallowedQueued()` uses the new `AudioPriorityManager.dropQueuedWhere`. P0 and P1 are never dropped |
| Pause other audio (music pause or duck) | Settings | VoiceService passes `pauseOthers` on each submit | Yes (read on each line) | none |
| Accident warnings | Settings | VoiceService.speakHazard, ConvoyService.hazards | Yes | covered by the queued-line drop above |
| Language | Settings | L10n, VoiceService._onLanguage (releases the engine, re-inits on the next alert) | Yes | none |
| Ride on lock screen | Settings | RideNotificationService (listens to settings, rebuilds) | Yes | none. Device check: Android may need the notification re-posted for a visibility change |
| Data saver (low data) | Settings, data saver tile | ConvoyService telemetry cadence, RouteGuide/essentials (per fix), map places and tiles (context.select), weather and tile prefetch, intercom sample rate | **Partly**: intercom VOX keeps the mic open all ride, so the rate never changed. Data saver turned off mid-ride never ran the skipped weather check or the Wi-Fi route-map save | IntercomService listens to settings and re-opens an idle VOX mic at the new rate; a burst finishes first. SafetyService runs `_startWeather` / `_startTiles` when data saver goes off in a started ride |
| Battery saver | Settings, quick settings | ConvoyService `_onSettingsChanged` → `_syncBatterySaver` | Yes | none |
| Hardware PTT button | Intercom dock | IntercomService._handleKeyEvent (read on each key) | Yes | none |
| Auto re-route | Settings | RideEssentialsCoordinator._feed → RouteGuide.onFix (per fix) | Yes | none |
| Fuel profile, range, margin | Fuel sheet, Settings, garage | SafetyService fuel estimate (read when used), cockpit (select), FuelSharingBinding | Yes | none |
| Share fuel estimate | Fuel sheet | FuelSharingBinding | Yes | none |
| Theme and night map | Quick settings | ThemeController.setPreference → evaluate and notify | Yes | none |
| Keep screen on | Quick settings (cockpit local) | cockpit wakelock sync | Yes | the quick settings row now follows the state (see UI below) |

## Quick settings sheet (glove modal)

| Control | Before | Fix |
|---|---|---|
| Voice, Battery saver | **Stale**: the sheet only read SettingsService and IntercomService, so a row kept its old state after a tap. A second tap repeated the same change, so Voice could not be turned back on without closing the sheet | `ListenableBuilder` on settings and intercom (glove_quick_settings_modal.dart, now a StatefulWidget) |
| Screen always on | **Stale**: a constructor value | a local copy flips with the tap |
| Voice off then on (intercom) | `setMicMuted(true)` disarmed hands-free (VOX), and unmuting left it off | IntercomService re-arms VOX on unmute when it was armed before the mute |

## Group settings (lead → every rider)

| Setting | App UI → send | Gateway | CONFIG payload | App CONFIG handler | Timeline / consumers | Live before? | Fix |
|---|---|---|---|---|---|---|---|
| Distance threshold | slider → updateGroupConfig | _updateConfig (clamped 100..20000) | yes | yes | timeline `_checkSeparation` reads room.meta on each check; app `_checkIn` / RideFacts read the convoy | Yes on the server; the app showed nothing until the echo | Lead fix: optimistic update plus a re-read if there is no echo in 6 s. Gateway test added |
| Stop threshold | slider | yes | yes | yes | timeline stops read `room.meta.stopThresholdSeconds` per fix; cockpit / notification read the convoy | Yes | test added |
| Spoken alerts (group voice) | switch | yes | yes | yes | AlertService → VoiceService.setGroupVoice | Yes for new lines, **no** for queued lines. **Bug**: after leaving a ride with group voice off, it stayed off (no convoy meant no update) | `convoy?.voiceGuidanceEnabled ?? true` in AlertService; `setGroupVoice(false)` drops queued lines |
| Group speed limit | chips | yes | yes | yes | timeline `_speed` reads meta per fix; app SafetyService and cockpit | Server yes; app: see the lead fix | Lead fix; gateway test (lowered and raised mid-ride) |
| Town limit | chips (ride316) | yes | yes | yes | timeline `_activeLimit` | **Server only**: the rider's own warning and display never used it | `groupLimitAt()` (effective_speed_limit.dart), used in SafetyService._checkSpeedLimit / _recheckSpeedLimit and the cockpit chip; same 1 km rule as the gateway |
| Feature policy switches and choices (incl. stretchAlertKm, guardian minutes) | updateGroupConfig(featurePolicy) | policyPatch | yes (featurePolicy) | yes | GroupSafetyService reads `c.featurePolicy` every 5 s; guardians.js reads meta per request | Yes, but **an offline tap was dropped without a word** | updateGroupConfig sets the offline error when a policy change cannot be sent; a sent change clears that note |
| Visibility, discovery, assist default | setGroupVisibility | yes | yes | yes | discovery and net services | Optimistic, **with no confirmation**: a refused change stayed on the lead's screen | `_awaitConfigEcho()` (shared 6 s re-read) |
| Automatic roles | setAutoRoles (own endpoint, AUTO_ROLES event) | setAutoRoles | **no** | n/a | timeline `_checkAutoRoles` reads meta | Yes via AUTO_ROLES; a missed event stayed wrong until a snapshot | `autoRoles` added to `_configPayload`, and the app CONFIG handler applies it |
| Buddy pairs | BuddyLine | buddies.js | BUDDIES event + snapshot | GroupSafetyService | | Yes | none |
| Public ride | PublicRideService sends CONFIG.publicRide | yes | yes (publicRide) | PublicRideService handles CONFIG | | Yes | none |
| Seats (capacity) | host plan upgrade | refreshHostCapacity emits CONFIG | yes | yes (soloRide is derived from capacity) | | Yes | none |
| Who may change | `canEditRoute` | `isLead()` (lead fix) | | | | The app left out the trip owner (not the creator), which the gateway allows | `c.tripOwnerUserId == uid` added to canEditRoute |

ConvoyModel.copyWith carries every group field, including autoRoles, featurePolicy and capacity,
so no field is dropped or reset on copy. A test covers this.

## Admin feature switches (FEATURE_FLAGS mid-ride)

Most services take `FeatureFlagsService.on`, or a `featureOn` callback, and evaluate it when the
feature is used, so they are live. The widgets use `context.featureOn`, which watches the service.
These services keep state that a switch turned off mid-ride left running:

| Switch | Before | Fix |
|---|---|---|
| `intercom` | Only a *new* talk was refused: a held PTT or an armed VOX mic kept sending, and VOX could start new streams | `IntercomService.featureSwitchesChanged()` ends the stream, closes the mic and leaves VOX; it is wired as a FeatureFlagsService listener in main.dart. VOX `_onMicData` also checks the switch |
| `sirenDetector` | Turned off while a siren had ducked the audio: the duck stayed on | `_applyDucking(false)` when switched off |
| `soloCheckIn` | Disarmed on off, never re-armed on on | the same `_armedOnce` fix as the setting |
| others (road care, group safety, mesh, BLE remote, weather, engine care, public ride, essentials, heritage) | Read on use / per tick | none |

Locked safety ids (SOS, crash detection, emergency SMS, medical ID) are never gated.

## Garage, roles, plan

| Change | Before | Fix |
|---|---|---|
| Active bike changed mid-ride: engine care | live (`care.bike = bike`) | none |
| Active bike: fuel profile | live (adoptGarageFuelProfile → settings notify) | none |
| Active bike: fuel type and learned mileage (FuelEconomyService) | **No**: loaded only at ride start (`ensureLoaded(reload: true)` in SafetyService._onConvoy) | `FuelEconomyService.useBike()` is called from GarageBinding._onBike (wired in main.dart) |
| Active bike: vehicle colour | only sent on create / join | **open**: no protocol message updates the colour mid-ride (see remaining issues) |
| Riding role change (ROLE_CHANGE) | live | none |
| Plan pushed by admin (SUBSCRIPTION_*) | ConvoyService → onPlanChanged → MembershipService.fetchMyMembership → notify; FeatureGates is static (all unlocked) | none |

## Tests

- `gateway/test/config_live_355.test.js` covers:
  - CONFIG carries every group setting, with the snapshot's values, `autoRoles` included.
  - A non-lead change is refused: nothing changes and no CONFIG is sent. The trip head is allowed.
  - Lowering the speed limit makes the next fixes OVERSPEED at the new limit; raising it clears.
  - Changing the distance threshold changes SEPARATED.
  - Changing the stop threshold applies to a rider who is already stopped.
- `test/settings_live_355_test.dart` covers:
  - The speed limit precedence and the town limit (`groupLimitAt`).
  - The ConvoyModel copy and round trip keep every group setting.
  - `FuelEconomyService.useBike`.
  - Queued voice lines are dropped when warnings or group voice are turned off, and P0 is never dropped.
  - The break reminder switched off: no 2-hour prompt or voice; it comes back when switched on.
  - Quick settings rows flip on every tap.

  This file is analyzed only: the Flutter engine is not available here.

## Remaining issues and device checks

Re-checked after the follow-up round (gateway / group / garage agent). Items owned by the
audio and mic agents are marked "audio/mic round in progress".

1. **Vehicle colour mid-ride**: RESOLVED (gateway / garage round). New socket message
   `RIDER_VEHICLE {vehicleColor?, vehicleModel?}`, advertised as HELLO feature `vehicle1` (older
   apps never send it; older gateways are never sent it) and gated by the admin switch
   `riderVehicleLive`.
   - Gateway (`gateway/src/convoys.js` `setRiderVehicle`, `riderVehicleInput`; `gateway/src/ws.js`):
     the colour is a colour name (letters first, at most 20 characters, the garage keeps free-text
     names such as "Kaza Brown") or `#RRGGBB`; the model is plain text of at most 40 characters
     (control and direction-override characters removed). One applied update per rider per 10 s
     (409 `VEHICLE_RATE`). Refused for a pillion (409 `PILLION_RIDER`) and for a rider whose bike
     was swapped in this ride (409 `BIKE_SWAPPED`: the swap decides). Applied to this ride's rider
     record only (never the profile), broadcast as `RIDER_UPDATE` and kept in every snapshot.
     `publicRider` gained `vehicleModel` ('' when unknown; old apps ignore it). Create / join also
     accept `vehicleModel`.
   - App: `GarageBinding.onVehicle` -> `ConvoyService.setActiveVehicle` sends the change during a
     group ride (`lib/data/models/rider_vehicle.dart` builds it: only changed, valid fields;
     nothing for a pillion). The latest bike is sent once the 10 s window has passed; offline it is
     retried until the ride shows it; a final refusal stops it for that ride, quietly (no error
     banner). The rider card shows the model when known.
   - Tests: `gateway/test/rider_vehicle_355.test.js`, `test/rider_vehicle_355_test.dart`.
2. **Native TTS queue** (lines already handed to Android TextToSpeech): audio/mic round in
   progress (voice_service is owned by the audio agent).
3. **Group sliders**: RESOLVED. `ReleaseSlider` (`lib/presentation/ride/group_settings_sheet.dart`)
   previews the value while dragging and sends one CONFIG on release; the optimistic value, the
   offline note and the 6 s re-read of `ConvoyService.updateGroupConfig` are unchanged. Rapid
   repeated taps on switches / chips that wait for the gateway's confirmation no longer send the
   same CONFIG twice within 1.5 s (`configRepeatWindow`). Test: `test/group_settings_release_355_test.dart`.
4. **Device checks** (still to do on a phone):
   - The lock-screen visibility switch updates the posted notification.
   - Data saver toggled during hands-free talk: there is a short mic re-open with no audible gap
     for listeners (audio/mic round in progress).
   - The siren duck is released when the admin switch goes off (audio/mic round in progress).
   - The town limit warning near a planned stop.
   - The admin "intercom" switch off during a held PTT ends the talk for listeners.
   - A bike change in the garage mid-ride recolours the rider on the other phones within a second
     (and again after 10 s for a second change).
5. **Crash detection switched off while an alarm is counting down**: RESOLVED (made explicit).
   The running alarm still continues (never cancelled behind the rider: they may be hurt, the
   switch may have been bumped) and new alarms stop at once. Now the alarm screen replaces its
   hint with "Crash detection is off for new alarms. This alarm is still running: tap I'm OK to
   cancel it." (`SafetyService.alarmRunsWithDetectionOff`, `crashAlarmStillRunning`) and the alarm
   notification is re-posted with the same words. Test: `test/crash_alarm_screen_test.dart`.
6. **New admin switches** (`gateway/src/feature_flags.js`, default on, not locked; the admin
   console and the `FEATURE_FLAGS` push list them from the catalog; the app treats unknown ids as
   on): `speedAudio`, `callAwareAlerts`, `voiceCleanup`, `riderVehicleLive`;
   `sirenDetector` now mentions ambulance, police and fire sirens. The app-side checks of the
   first four (`FeatureFlagsService.on(id)`) belong to the audio/mic round in progress.
