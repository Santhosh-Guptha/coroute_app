# CoRoute – Inaccessible Screens & External Dependency Audit

This document catalogues screens, components, and modal states in the **CoRoute** application that cannot be reached or captured in a standard headless or emulator testing environment without live physical peripherals, external payment gateways, or government emergency dispatch integrations.

---

## 1. Summary of Inaccessible UI Surfaces

| Inaccessible Screen / Feature | Reason for Inaccessibility | Required Hardware / Data / Permissions | Reproduction Strategy for Future Pass |
|---|---|---|---|
| **SCR-080: Razorpay Gateway Callback Sheet** | Requires active Razorpay checkout intent and live bank redirect callback | Live merchant credentials, simulated webhook/deep link callback | Razorpay Sandbox mock intent with registered test UPI VPA |
| **SCR-081: BLE Handlebar PTT Pairing Screen** | Requires a physical Bluetooth Low Energy GATT peripheral advertising CoRoute PTT UUID | Physical Bluetooth handlebar PTT button (e.g., Sena, Cardo, or custom BLE button) | Android Virtual Device BLE peripheral simulation script using BlueZ or nRF Connect |
| **SCR-082: Satellite SOS Bridge Uplink View** | Requires physical Garmin inReach or Iridium satellite transceiver link | Physical satellite transceiver paired via serial or BLE | Satellite serial mock daemon sending NMEA/Iridium SBD frames |
| **SCR-083: Live Police ERSS 112 Dispatch View** | Government safety API access restricted to authenticated emergency dispatchers | Authorized ERSS API token and live incident clearance | Mock government gateway stub using isolated staging tenant |

---

## 2. Detailed Technical Breakdown

### 1. Razorpay Live Callback & Webhook Verification (`SCR-080`)
- **Location:** `coroute_app/lib/presentation/subscription/payment_checkout_modal.dart` & Gateway endpoints.
- **Why Inaccessible:**
  The checkout modal renders inside CoRoute, but the final bank verification redirect takes place via an external Webview or browser tab managed by Razorpay. A live transaction requires real Indian banking credentials or Razorpay API test-key signatures.
- **Prerequisites to Unlock:**
  1. Active Razorpay Test Key (`rzp_test_...`).
  2. Test UPI VPA (`success@razorpay`) or test NetBanking bank credentials.
  3. Webhook listener running on `https://gateway.coroute.in/webhooks/razorpay`.
- **How to Capture in Future Pass:**
  Deploy the payment mock service with `--dart-define=RAZORPAY_TEST_MODE=true` and invoke the success callback hook directly using deep link `coroute://payment/callback?status=success&payment_id=pay_mock_123`.

---

### 2. Physical BLE Handlebar PTT Pairing Wizard (`SCR-081`)
- **Location:** `coroute_app/lib/data/services/ble_remote_service.dart`.
- **Why Inaccessible:**
  CoRoute includes dedicated GATT services for listening to physical push-to-talk handlebar buttons so riders don't take their hands off the grips. Standard Android emulators cannot emulate a Bluetooth Low Energy peripheral advertising the CoRoute GATT characteristic.
- **Prerequisites to Unlock:**
  1. Physical Android device running Android 10+.
  2. BLE peripheral hardware (e.g., ESP32 running GATT button firmware or commercial Sena handlebar PTT).
- **How to Capture in Future Pass:**
  Run `flutter run -d <physical_device>` with a paired Nordic Semiconductor nRF52-DK or nRF Connect mobile app simulating the GATT characteristic `0000FFE0-0000-1000-8000-00805F9B34FB`.

---

### 3. Satellite SOS Uplink View (`SCR-082`)
- **Location:** `coroute_app/lib/data/services/sms_sender.dart` & `scenario_f_indian_emergency_fallback_test.dart`.
- **Why Inaccessible:**
  When cellular connectivity is completely lost, CoRoute supports an external hardware bridge fallback to satellite messaging networks. Without an active satellite device or simulated serial link, this interface remains in an idle state.
- **Prerequisites to Unlock:**
  1. Satellite transceiver (Garmin inReach / Iridium Edge).
  2. Satellite airtime subscription.
- **How to Capture in Future Pass:**
  Use a mock serial port loopback harness providing canned Iridium Short Burst Data (SBD) responses to trigger the active satellite telemetry HUD pill.

---

### 4. Government ERSS 112 Live Emergency Dispatch (`SCR-083`)
- **Location:** `coroute_app/lib/presentation/admin/admin_emergencies_panel.dart` (Authority escalation).
- **Why Inaccessible:**
  Direct escalation to India's Emergency Response Support System (ERSS 112) is gated by certified government API keys and IP whitelists to prevent accidental emergency service dispatching.
- **Prerequisites to Unlock:**
  1. Dedicated state police ERSS test environment credentials.
  2. Dispatch authority role assigned to admin account.
- **How to Capture in Future Pass:**
  Activate the `ADMIN_DISPATCH_MOCK_ENV=true` test flag in `ApiClient` to render the national emergency responder dispatch console without calling live dialers.

---

## 3. Compliance and Safety Notice

> [!IMPORTANT]
> Live emergency services, SOS dispatches, and real banking transactions were deliberately omitted from live device testing to avoid triggering genuine emergency service responses, false 112 calls, or non-refundable transactions.

