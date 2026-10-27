# CoRoute v3.51.0 Production Release Notes

**Build Version:** `3.51.0+111`  
**Gateway Version:** `3.51.0`  
**Release Tag:** `v3.51.0`  
**Release Date:** 2026-10-27  
**Production Ingress:** `https://coroute.duckdns.org`  
**WebSocket Server:** `wss://coroute.duckdns.org/ws`  

---

## 1. Highlights & New Features

### 100% Razorpay UPI Payment Gateway
- Strictly restricted payment instruments to UPI (`upi://pay`, Google Pay, PhonePe, Paytm, BHIM, Cred, and UPI VPA/QR). Cards, netbanking, and wallets are blocked.
- 1-tap checkout modal with copyable VPA and 12-digit UTR input for instant reconciliation.

### Enterprise Payment Lifecycle, User Mapping & Expiry Tracking
- **Order & Payment ID Mapping:** Every transaction retains `orderId`, `paymentId`, `utr`, `vpa`, and `method: UPI`.
- **Immutable User Snapshot:** Binds `userId`, `name`, `email`, `phone`, and `callsign` to each payment record in Oracle Autonomous Database.
- **Fair Plan Expiry Extension:** When renewing an active plan, the expiry is extended from the existing valid date (`validUntil + duration`), guaranteeing zero lost days.
- **Permanent Payment Ledger (`paymentHistory`):** Full audit trail stored on the user record in Oracle DB.
- **Transaction History API:** New `GET /api/subscription/history` endpoint allowing riders to view their past orders, payment IDs, UTRs, and plan validity periods.
- **Automated Webhook Sync:** Razorpay `payment.captured` HMAC-SHA256 webhook unlocks subscriptions in real-time, pushes `SUBSCRIPTION_ACTIVATED` over WebSockets, and invalidates auth cache.

### UI Cleanup
- Completely removed test mode toggles, mock plan switchers, and debug banners across the mobile app.

---

## 2. Release Binaries & Checksums

| Binary | Architecture | Size | SHA256 Checksum |
| :--- | :--- | :--- | :--- |
| `coroute-v3.51.0-arm64-v8a.apk` | 64-bit ARM (Modern Android) | 11.6 MB (12,113,010 B) | `3F5AF7F9631D21A5F970AD04CFE29570AFEDE0C2D10C0D7B6E6F719011EF20A2` |
| `coroute-v3.51.0-armeabi-v7a.apk` | 32-bit ARM (Legacy Android) | 11.3 MB (11,821,531 B) | `D044C0D468395F7DF762D2E129F0D0C828C2229FE3E5B78C41E45FAA300173E3` |
| `coroute-v3.51.0-x86_64.apk` | x86_64 (Emulators / Intel Android) | 11.8 MB (12,326,148 B) | `2E4034672D149E535AB34CA6AFA515308C6B91208149FA6BCA158A5E0472211F` |
| `coroute-v3.51.0-universal.apk` | Universal Fat APK (All Devices) | 30.3 MB (31,807,453 B) | `18E34A830CF0A79F2A92E95B7D554A921329EEAD05CA15665C8728CD7AFF4240` |

---

## 3. Production Verification
- Gateway Test Suite: 344/344 passing (100%)
- Live Multi-Rider Convoy Scenarios on Production: 7/7 passing (100%)
- VM 1 (`152.67.181.198`) & VM 2 (`129.225.79.93`): Active and live on `version: 3.51.0`
