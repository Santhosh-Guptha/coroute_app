# Wearable impact hook (CoRoute 3.16)

CoRoute does no Bluetooth or wearable device work in 3.16. The unused
`BLUETOOTH_CONNECT` permission was removed from the manifest. What exists is
one documented entry point so a future helmet, watch or crash sensor
integration can plug into the existing crash alarm without touching the alarm,
the SOS path or the server.

## The hook

```dart
// lib/data/services/safety_service.dart
enum ExternalImpactSource { wearable, developer }

void SafetyService.externalImpact({
  required ExternalImpactSource source,
  required double g,      // peak acceleration of the impact, in g
  required int atMs,      // when it happened, epoch ms
});
```

Call it from any future device bridge (`context.read<SafetyService>()` or the
instance main.dart creates). It opens the same 15 s crash alarm as the phone's
own accelerometer path ("Possible accident detected. Are you okay?", full
screen over the lock screen, I'm OK / Need Help), using the position and speed
of the rider's last GPS fix. When the alarm times out or the rider taps Need
Help, the SOS goes out with `source: WEARABLE` (the server already accepts it;
`EmergencySource.wearable` in `network_wire.dart`). I'm OK sends nothing.

The call is ignored (returns silently) when:

- no ride is active (no convoy, or the trip has ended),
- crash detection is off in Ride safety,
- a crash alarm is already open,
- the rider's own SOS is open or still waiting to be sent,
- `g` is not a finite positive number.

An I'm OK after a `wearable` impact schedules the same post-crash follow-up as
a real sensor impact ("Still okay? Anything hurt?" at the next stop or 20 min
later). A `developer` impact never does.

## Hidden developer action

Ride safety sheet: tap the title 7 times while a ride is active. A row
"Developer: simulate wearable impact" calls
`externalImpact(source: ExternalImpactSource.developer, g: SafetyConstants.wearableImpactG, atMs: now)`
(6.0 g). Use it to test the alarm, the lock screen and the WEARABLE source on
a real phone without riding; see `docs/SAFETY_DEVICE_TESTS.md` section 17.

## What a real integration must add (not in 3.16)

- The device bridge itself (BLE or the maker's SDK), its permissions
  (`BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN` on Android 12+) and the Play Data
  safety entries for them.
- A setting to pair and to turn the source off, in Ride safety.
- Rate limiting on the bridge side (the hook does not debounce; the alarm and
  the detector cooldown do the rest).
- Battery review: a BLE link during a ride is a new drain and must be measured
  as in `docs/SAFETY_DEVICE_TESTS.md` section 9.
