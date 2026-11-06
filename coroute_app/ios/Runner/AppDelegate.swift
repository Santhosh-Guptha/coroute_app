import Flutter
import UIKit
import CoreMotion
import AVFoundation
import CallKit
import UserNotifications
import Network

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var channelsRegistered = false
  private var accelStream: AccelStream?
  private var safetyChannel: SafetyChannel?
  private var smsChannel: SmsChannel?
  private var rideNotification: RideNotification?
  private var ttsChannel: TtsChannel?
  private var phoneCallChannel: PhoneCallChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    UNUserNotificationCenter.current().delegate = self

    if let controller = window?.rootViewController as? FlutterViewController {
      setupChannels(messenger: controller.binaryMessenger, controller: controller)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let messenger = (window?.rootViewController as? FlutterViewController)?.binaryMessenger {
      setupChannels(messenger: messenger, controller: window?.rootViewController as? FlutterViewController)
    }
  }

  private func setupChannels(messenger: FlutterBinaryMessenger, controller: FlutterViewController?) {
    guard !channelsRegistered else { return }
    channelsRegistered = true

    // 1. Ambient light stream (coroute/ambient_light)
    let ambientChannel = FlutterEventChannel(name: "coroute/ambient_light", binaryMessenger: messenger)
    ambientChannel.setStreamHandler(AmbientLightStream())

    // 2. High-precision Accelerometer/Gyroscope Stream for Crash Detection (coroute/accel)
    let accel = AccelStream()
    accelStream = accel
    let accelChannel = FlutterEventChannel(name: "coroute/accel", binaryMessenger: messenger)
    accelChannel.setStreamHandler(accel)

    // 3. Safety helpers (coroute/safety)
    let safety = SafetyChannel(controller: controller)
    safetyChannel = safety
    let safetyMethodChannel = FlutterMethodChannel(name: "coroute/safety", binaryMessenger: messenger)
    safetyMethodChannel.setMethodCallHandler { [weak safety] call, result in
      safety?.handle(call, result: result)
    }

    // 4. SMS / Emergency texts (coroute/sms)
    let sms = SmsChannel()
    smsChannel = sms
    let smsMethodChannel = FlutterMethodChannel(name: "coroute/sms", binaryMessenger: messenger)
    smsMethodChannel.setMethodCallHandler { [weak sms] call, result in
      sms?.handle(call, result: result)
    }

    // 5. Ride ongoing notification & lock-screen actions (coroute/ride_notification)
    let rideChannel = FlutterMethodChannel(name: "coroute/ride_notification", binaryMessenger: messenger)
    let ride = RideNotification(channel: rideChannel)
    rideNotification = ride
    rideChannel.setMethodCallHandler { [weak ride] call, result in
      ride?.handle(call, result: result)
    }

    // 6. Text-to-speech spoken alerts with audio ducking (coroute/tts)
    let tts = TtsChannel()
    ttsChannel = tts
    let ttsMethodChannel = FlutterMethodChannel(name: "coroute/tts", binaryMessenger: messenger)
    ttsMethodChannel.setMethodCallHandler { [weak tts] call, result in
      tts?.handle(call, result: result)
    }

    // 7. Phone call interruption detection (coroute/phone_call & coroute/phone_call_events)
    let phone = PhoneCallChannel()
    phoneCallChannel = phone
    let phoneMethodChannel = FlutterMethodChannel(name: "coroute/phone_call", binaryMessenger: messenger)
    phoneMethodChannel.setMethodCallHandler { [weak phone] call, result in
      phone?.handleMethod(call, result: result)
    }
    let phoneEventChannel = FlutterEventChannel(name: "coroute/phone_call_events", binaryMessenger: messenger)
    phoneEventChannel.setStreamHandler(phone)
  }

  // MARK: - UNUserNotificationCenterDelegate
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    rideNotification?.handleNotificationResponse(response)
    completionHandler()
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .sound, .list])
    } else {
      completionHandler([.alert, .sound])
    }
  }
}

// =============================================================================
// MARK: - 1. Ambient Light Stream
// =============================================================================
private class AmbientLightStream: NSObject, FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    events(FlutterError(code: "NO_SENSOR", message: "iOS ambient light sensor API is restricted to system auto-brightness.", details: nil))
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    return nil
  }
}

// =============================================================================
// MARK: - 2. High-Precision Accelerometer & Gyroscope Stream for Crash Detection
// =============================================================================
private class AccelStream: NSObject, FlutterStreamHandler {
  private let motion = CMMotionManager()
  private let queue = OperationQueue()
  private var sink: FlutterEventSink?
  private var active = false

  // Filter & telemetry state
  private var gravityInit = false
  private var gx: Double = 0.0
  private var gy: Double = 0.0
  private var gz: Double = 9.80665
  private var refGx: Double = 0.0
  private var refGy: Double = 0.0
  private var refGz: Double = 9.80665

  private var currentGyroRadS: Double = 0.0
  private var peakGyro: Double = 0.0

  private struct HighResSample {
    var tMs: Int64 = 0
    var gDyn: Double = 0.0
    var gRaw: Double = 0.0
    var gyroRadS: Double = 0.0
  }

  private let ringSize = 100
  private var ringBuf: [HighResSample] = (0..<100).map { _ in HighResSample() }
  private var ringHead = 0
  private var highRunMs: Double = 0.0

  // 1-second bucket aggregations
  private var bucketSecond: Int64 = Int64.min
  private var count = 0
  private var sumRaw: Double = 0.0
  private var sumSqRaw: Double = 0.0
  private var peakRaw: Double = 0.0
  private var peakDyn: Double = 0.0
  private var maxTilt: Double = 0.0
  private var maxDurationMs: Double = 0.0
  private var peakJerk: Double = 0.0

  private var closed = [Double]()
  private var lastFlushTime: TimeInterval = 0

  override init() {
    super.init()
    queue.name = "space.devmonks.coroute.accel"
    queue.maxConcurrentOperationCount = 1
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    let args = arguments as? [String: Any]
    let samplingUs = (args?["samplingUs"] as? NSNumber)?.intValue ?? 20_000
    let updateInterval = max(0.005, min(0.2, Double(samplingUs) / 1_000_000.0))

    guard motion.isDeviceMotionAvailable else {
      events(FlutterError(code: "NO_SENSOR", message: "Device motion hardware is not available on this iOS device.", details: nil))
      return nil
    }

    active = true
    closed.removeAll()
    count = 0
    sumRaw = 0
    sumSqRaw = 0
    peakRaw = 0
    peakDyn = 0
    peakGyro = 0
    maxTilt = 0
    maxDurationMs = 0
    peakJerk = 0
    highRunMs = 0
    gravityInit = false
    bucketSecond = Int64.min

    motion.deviceMotionUpdateInterval = updateInterval
    motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motionData, error in
      guard let self = self, self.active, let data = motionData else { return }
      self.processMotion(data: data)
    }

    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stop()
    return nil
  }

  func stop() {
    active = false
    motion.stopDeviceMotionUpdates()
    sink = nil
  }

  private func processMotion(data: CMDeviceMotion) {
    let earthG = 9.80665

    // Total raw acceleration (gravity + dynamic acceleration)
    let rawX = (data.gravity.x + data.userAcceleration.x) * earthG
    let rawY = (data.gravity.y + data.userAcceleration.y) * earthG
    let rawZ = (data.gravity.z + data.userAcceleration.z) * earthG
    let gRaw = sqrt(rawX * rawX + rawY * rawY + rawZ * rawZ) / earthG

    // Dynamic linear acceleration (gravity isolated by CoreMotion sensor fusion)
    let linX = data.userAcceleration.x * earthG
    let linY = data.userAcceleration.y * earthG
    let linZ = data.userAcceleration.z * earthG
    let gDyn = sqrt(linX * linX + linY * linY + linZ * linZ) / earthG

    // Real-time gravity reference
    let curGx = data.gravity.x * earthG
    let curGy = data.gravity.y * earthG
    let curGz = data.gravity.z * earthG
    if !gravityInit {
      gx = curGx; gy = curGy; gz = curGz
      refGx = curGx; refGy = curGy; refGz = curGz
      gravityInit = true
    } else {
      let alpha = 0.90
      gx = alpha * gx + (1.0 - alpha) * curGx
      gy = alpha * gy + (1.0 - alpha) * curGy
      gz = alpha * gz + (1.0 - alpha) * curGz
    }

    // Gyroscope rotation rate in rad/s
    let rx = data.rotationRate.x
    let ry = data.rotationRate.y
    let rz = data.rotationRate.z
    currentGyroRadS = sqrt(rx * rx + ry * ry + rz * rz)
    peakGyro = max(peakGyro, currentGyroRadS)

    // Motorcycle lean / tilt angle relative to upright riding baseline
    let dot = gx * refGx + gy * refGy + gz * refGz
    let normG = sqrt(gx * gx + gy * gy + gz * gz)
    let normRef = sqrt(refGx * refGx + refGy * refGy + refGz * refGz)
    let currentTiltDeg: Double
    if normG > 0.1 && normRef > 0.1 {
      let cosA = max(-1.0, min(1.0, dot / (normG * normRef)))
      currentTiltDeg = acos(cosA) * 180.0 / .pi
    } else {
      currentTiltDeg = 0.0
    }

    // Adapt upright reference baseline during steady riding
    if gDyn < 0.4 && currentGyroRadS < 0.25 {
      refGx = 0.995 * refGx + 0.005 * gx
      refGy = 0.995 * refGy + 0.005 * gy
      refGz = 0.995 * refGz + 0.005 * gz
    }

    // Monotonic timestamp
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000.0)
    let second = nowMs / 1000

    if second != bucketSecond {
      closeBucket()
      bucketSecond = second
    }

    // High-resolution rolling buffer and discrete jerk (da/dt) calculation
    let prevSample = ringBuf[ringHead]
    let dtSec = (prevSample.tMs > 0 && nowMs > prevSample.tMs) ? Double(nowMs - prevSample.tMs) / 1000.0 : 0.02
    let currentJerk = (dtSec >= 0.005 && dtSec <= 0.2) ? abs(gDyn - prevSample.gDyn) / dtSec : 0.0
    peakJerk = max(peakJerk, currentJerk)

    ringHead = (ringHead + 1) % ringSize
    ringBuf[ringHead] = HighResSample(tMs: nowMs, gDyn: gDyn, gRaw: gRaw, gyroRadS: currentGyroRadS)

    // Continuous impact duration tracking (shock >= 2.0g)
    if gDyn >= 2.0 {
      highRunMs += max(5.0, min(200.0, dtSec * 1000.0))
    } else {
      highRunMs = 0.0
    }
    let currentDurationMs = highRunMs

    count += 1
    sumRaw += gRaw
    sumSqRaw += gRaw * gRaw
    peakRaw = max(peakRaw, gRaw)
    peakDyn = max(peakDyn, gDyn)
    maxTilt = max(maxTilt, currentTiltDeg)
    maxDurationMs = max(maxDurationMs, currentDurationMs)

    let nowSec = ProcessInfo.processInfo.systemUptime
    if !closed.isEmpty && (nowSec - lastFlushTime >= 0.5) {
      lastFlushTime = nowSec
      flush()
    }
  }

  private func closeBucket() {
    guard count > 0, bucketSecond != Int64.min else { return }
    let mean = sumRaw / Double(count)
    let variance = max(0.0, sumSqRaw / Double(count) - mean * mean)
    // 10-element telemetry:
    // [tMs, peakRawG, meanRawG, stdRawG, peakDynG, peakGyroRadS, maxTiltDeg, maxDurationMs, peakJerkGPerS, sensorConfidence]
    closed.append(Double(bucketSecond * 1000))
    closed.append(peakRaw)
    closed.append(mean)
    closed.append(sqrt(variance))
    closed.append(peakDyn)
    closed.append(peakGyro)
    closed.append(maxTilt)
    closed.append(maxDurationMs)
    closed.append(peakJerk)
    closed.append(1.0) // 1.0 confidence: CoreMotion calibrated hardware

    count = 0
    sumRaw = 0.0
    sumSqRaw = 0.0
    peakRaw = 0.0
    peakDyn = 0.0
    peakGyro = 0.0
    maxTilt = 0.0
    maxDurationMs = 0.0
    peakJerk = 0.0
  }

  private func flush() {
    guard !closed.isEmpty else { return }
    let copy = closed
    closed.removeAll()
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.active else { return }
      self.sink?(copy)
    }
  }
}

// =============================================================================
// MARK: - 3. Safety Channel Helpers
// =============================================================================
private class SafetyChannel: NSObject {
  private weak var controller: FlutterViewController?
  private let motion = CMMotionManager()
  private let pathMonitor = NWPathMonitor()
  private var currentNetworkKind = "none"

  init(controller: FlutterViewController?) {
    self.controller = controller
    super.init()
    pathMonitor.pathUpdateHandler = { [weak self] path in
      if path.status == .satisfied {
        if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
          self?.currentNetworkKind = "wifi"
        } else if path.usesInterfaceType(.cellular) {
          self?.currentNetworkKind = "mobile"
        } else {
          self?.currentNetworkKind = "mobile"
        }
      } else {
        self?.currentNetworkKind = "none"
      }
    }
    pathMonitor.start(queue: DispatchQueue.global(qos: .background))
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "deviceInfo":
      result(deviceInfo())
    case "canUseFullScreenIntent":
      result(true)
    case "openFullScreenIntentSettings", "openOemBatterySettings", "openSoundSettings":
      result(openSettings())
    case "alarmWindow":
      let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
      DispatchQueue.main.async {
        UIApplication.shared.isIdleTimerDisabled = on
      }
      result(nil)
    case "cacheDir":
      let path = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path
      result(path)
    case "networkKind":
      result(currentNetworkKind)
    case "phoneProbe":
      phoneProbe(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func deviceInfo() -> [String: Any] {
    var systemInfo = utsname()
    uname(&systemInfo)
    let machine = withUnsafePointer(to: &systemInfo.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in String(validatingUTF8: ptr) ?? "iPhone" }
    }
    let os = ProcessInfo.processInfo.operatingSystemVersion
    return [
      "manufacturer": "Apple",
      "model": machine,
      "sdkInt": os.majorVersion,
      "release": UIDevice.current.systemVersion,
      "cpuAbi": "arm64",
      "hasAccel": motion.isAccelerometerAvailable,
      "accelFifo": 0,
      "hasGyro": motion.isGyroAvailable,
      "gyroFifo": 0,
    ]
  }

  private func openSettings() -> Bool {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return false }
    if UIApplication.shared.canOpenURL(url) {
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
      return true
    }
    return false
  }

  private func phoneProbe(result: @escaping FlutterResult) {
    let probeMs: Double = 1500.0
    var accelCount = 0
    var gyroCount = 0
    var magCount = 0

    let opQueue = OperationQueue()
    opQueue.maxConcurrentOperationCount = 1

    if motion.isAccelerometerAvailable {
      motion.accelerometerUpdateInterval = 0.02
      motion.startAccelerometerUpdates(to: opQueue) { _, _ in accelCount += 1 }
    }
    if motion.isGyroAvailable {
      motion.gyroUpdateInterval = 0.02
      motion.startGyroUpdates(to: opQueue) { _, _ in gyroCount += 1 }
    }
    if motion.isMagnetometerAvailable {
      motion.magnetometerUpdateInterval = 0.02
      motion.startMagnetometerUpdates(to: opQueue) { _, _ in magCount += 1 }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + (probeMs / 1000.0)) { [weak self] in
      guard let self = self else { return }
      self.motion.stopAccelerometerUpdates()
      self.motion.stopGyroUpdates()
      self.motion.stopMagnetometerUpdates()

      let accelHz = accelCount > 1 ? Double(accelCount - 1) / (probeMs / 1000.0) : 0.0
      let gyroHz = gyroCount > 1 ? Double(gyroCount - 1) / (probeMs / 1000.0) : 0.0
      let magHz = magCount > 1 ? Double(magCount - 1) / (probeMs / 1000.0) : 0.0

      var freeBytes: Int64 = 0
      if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
         let free = attrs[.systemFreeSize] as? NSNumber {
        freeBytes = free.int64Value
      }

      let audio = AVAudioSession.sharedInstance()
      let vol = Double(audio.outputVolume)

      var btOut = "none"
      var btMic = false
      var wired = false
      for port in audio.currentRoute.outputs {
        if port.portType == .bluetoothA2DP || port.portType == .bluetoothLE {
          btOut = "a2dp"
        } else if port.portType == .bluetoothHFP {
          btOut = "sco"
        } else if port.portType == .headphones {
          wired = true
        }
      }
      for port in audio.currentRoute.inputs {
        if port.portType == .bluetoothHFP {
          btMic = true
        }
      }

      let canSms = UIApplication.shared.canOpenURL(URL(string: "sms:")!)
      let canTel = UIApplication.shared.canOpenURL(URL(string: "tel:")!)

      let out: [String: Any] = [
        "accelPresent": self.motion.isAccelerometerAvailable,
        "accelEvents": accelCount,
        "accelHz": accelHz,
        "gyroPresent": self.motion.isGyroAvailable,
        "gyroEvents": gyroCount,
        "gyroHz": gyroHz,
        "magPresent": self.motion.isMagnetometerAvailable,
        "magEvents": magCount,
        "magHz": magHz,
        "probeMs": probeMs,
        "sdkInt": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        "bgRestricted": false,
        "powerSave": ProcessInfo.processInfo.isLowPowerModeEnabled,
        "dndFilter": 0,
        "mediaVol": vol,
        "mediaVolMax": 1.0,
        "alarmVol": vol,
        "alarmVolMax": 1.0,
        "ringerMode": 2,
        "btOut": btOut,
        "btMic": btMic,
        "wiredOut": wired,
        "freeBytes": freeBytes,
        "hasTelephony": canTel,
        "canCompose": canSms,
        "canDial": canTel
      ]
      result(out)
    }
  }
}

// =============================================================================
// MARK: - 4. SMS / Messages Channel
// =============================================================================
private class SmsChannel: NSObject {
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "capability":
      let canSms = UIApplication.shared.canOpenURL(URL(string: "sms:")!)
      result([
        "hasTelephony": canSms,
        "permission": true,
        "simReady": true,
        "canSendDirect": false
      ])
    case "launchSmsIntent":
      launchSmsIntent(call: call, result: result)
    case "send":
      // Direct silent background SMS is blocked by iOS sandbox; return FAILED to trigger composer fallback
      result(["status": "FAILED", "code": -1, "reason": "DIRECT_SMS_NOT_SUPPORTED_ON_IOS"])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func launchSmsIntent(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let body = (args?["body"] as? String) ?? ""
    let toList = args?["toList"] as? [String]
    let to = (args?["to"] as? String) ?? (toList?.joined(separator: ",") ?? "")
    let cleanTo = to.components(separatedBy: CharacterSet(charactersIn: "0123456789+,").inverted).joined()

    var urlString = "sms:\(cleanTo)"
    if !body.isEmpty, let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
      urlString += "&body=\(encoded)"
    }

    if let url = URL(string: urlString), UIApplication.shared.canOpenURL(url) {
      UIApplication.shared.open(url, options: [:]) { ok in
        result(ok)
      }
    } else {
      result(false)
    }
  }
}

// =============================================================================
// MARK: - 5. Ride Notification & Lock-Screen Actions
// =============================================================================
private class RideNotification: NSObject {
  private let channel: FlutterMethodChannel
  private var pendingLaunch: [String: String]?
  private let categoryId = "COROUTE_RIDE_ACTIONS"
  private let notifId = "coroute_ride_ongoing"

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    setupNotificationCategories()
  }

  private func setupNotificationCategories() {
    let sosAction = UNNotificationAction(identifier: "SOS", title: "🚨 SOS Emergency", options: [.foreground, .destructive])
    let waitAction = UNNotificationAction(identifier: "WAIT", title: "⏱ Wait for me", options: [])
    let mapAction = UNNotificationAction(identifier: "MAP", title: "🗺 Open Map", options: [.foreground])
    let navAction = UNNotificationAction(identifier: "NAV_EMERGENCY", title: "🧭 Navigate", options: [.foreground])
    let assistAction = UNNotificationAction(identifier: "ASSIST_ACCEPT", title: "🤝 I Can Help", options: [.foreground])

    let category = UNNotificationCategory(
      identifier: categoryId,
      actions: [sosAction, waitAction, mapAction, navAction, assistAction],
      intentIdentifiers: [],
      options: [.customDismissAction]
    )
    UNUserNotificationCenter.current().setNotificationCategories([category])
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "supported":
      result(true)
    case "show":
      show(call: call, result: result)
    case "ensure":
      result(true)
    case "takeLaunchAction":
      let p = pendingLaunch
      pendingLaunch = nil
      result(p)
    case "cancel":
      UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notifId])
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func show(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(false)
      return
    }

    let title = (args["title"] as? String) ?? "CoRoute Active Convoy"
    let body = (args["body"] as? String) ?? "Convoy tracking and emergency safety active"
    let ref = (args["ref"] as? String) ?? ""

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.categoryIdentifier = categoryId
    content.userInfo = ["ref": ref]
    content.sound = nil // Silent ongoing tracking notification

    let request = UNNotificationRequest(identifier: notifId, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { error in
      DispatchQueue.main.async {
        result(error == nil)
      }
    }
  }

  func handleNotificationResponse(_ response: UNNotificationResponse) {
    let action = response.actionIdentifier
    let ref = (response.notification.request.content.userInfo["ref"] as? String) ?? ""
    if action == UNNotificationDefaultActionIdentifier {
      deliver(action: "MAP", ref: ref)
    } else if action != UNNotificationDismissActionIdentifier {
      deliver(action: action, ref: ref)
    }
  }

  private func deliver(action: String, ref: String) {
    let payload = ["action": action, "ref": ref]
    pendingLaunch = payload
    channel.invokeMethod("onAction", arguments: payload)
  }
}

// =============================================================================
// MARK: - 6. Text-to-Speech Spoken Alerts Channel
// =============================================================================
private class TtsChannel: NSObject, AVSpeechSynthesizerDelegate {
  private let synth = AVSpeechSynthesizer()
  private var selectedVoice: AVSpeechSynthesisVoice?
  private var currentLanguage = "en-IN"
  private var activeUtterances = 0

  override init() {
    super.init()
    synth.delegate = self
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "init":
      let args = call.arguments as? [String: Any]
      let requestedLang = (args?["language"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      initEngine(requestedLang: requestedLang)
      result(["ok": true, "language": currentLanguage])
    case "speak":
      speak(call: call, result: result)
    case "requestEmergencyFocus":
      activateAudioSession(duck: false)
      result(true)
    case "abandonEmergencyFocus":
      deactivateAudioSession()
      result(nil)
    case "stop":
      synth.stopSpeaking(at: .immediate)
      deactivateAudioSession()
      result(nil)
    case "release":
      synth.stopSpeaking(at: .immediate)
      deactivateAudioSession()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func initEngine(requestedLang: String) {
    var candidateTags = [String]()
    if !requestedLang.isEmpty {
      candidateTags.append(requestedLang)
      if let prefix = requestedLang.split(separator: "-").first {
        candidateTags.append(String(prefix))
      }
    }
    candidateTags.append(contentsOf: ["en-IN", "en-GB", "en-US", "en"])

    for tag in candidateTags {
      if let voice = AVSpeechSynthesisVoice(language: tag) {
        selectedVoice = voice
        currentLanguage = voice.language
        return
      }
    }
    selectedVoice = AVSpeechSynthesisVoice(language: "en-US")
    currentLanguage = selectedVoice?.language ?? "en-US"
  }

  private func speak(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let text = args["text"] as? String, !text.isEmpty else {
      result(false)
      return
    }

    let interrupt = (args["interrupt"] as? Bool) == true
    if interrupt {
      synth.stopSpeaking(at: .immediate)
      activeUtterances = 0
    }

    activateAudioSession(duck: true)

    let utterance = AVSpeechUtterance(string: String(text.prefix(300)))
    utterance.voice = selectedVoice ?? AVSpeechSynthesisVoice(language: "en-IN")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    utterance.volume = 1.0

    activeUtterances += 1
    synth.speak(utterance)
    result(true)
  }

  private func activateAudioSession(duck: Bool) {
    let session = AVAudioSession.sharedInstance()
    var options: AVAudioSession.CategoryOptions = [.allowBluetooth, .mixWithOthers]
    if duck { options.insert(.duckOthers) }
    try? session.setCategory(.playback, mode: .voicePrompt, options: options)
    try? session.setActive(true)
  }

  private func deactivateAudioSession() {
    activeUtterances = 0
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    activeUtterances = max(0, activeUtterances - 1)
    if activeUtterances == 0 {
      deactivateAudioSession()
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    activeUtterances = max(0, activeUtterances - 1)
    if activeUtterances == 0 {
      deactivateAudioSession()
    }
  }
}

// =============================================================================
// MARK: - 7. Phone Call Interruption Channel
// =============================================================================
private class PhoneCallChannel: NSObject, FlutterStreamHandler, CXCallObserverDelegate {
  private let observer = CXCallObserver()
  private var sink: FlutterEventSink?
  private var currentCallState = "IDLE"

  override init() {
    super.init()
    observer.setDelegate(self, queue: DispatchQueue.main)
  }

  func handleMethod(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getCallState":
      let state = evaluateState()
      result(["state": state, "isCallActive": (state != "IDLE")])
    case "isAudioPlaying":
      let playing = AVAudioSession.sharedInstance().isOtherAudioPlaying
      result(playing)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    let state = evaluateState()
    events(["state": state, "isCallActive": (state != "IDLE")])
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
    let state = evaluateState()
    if state != currentCallState {
      currentCallState = state
      sink?(["state": currentCallState, "isCallActive": (currentCallState != "IDLE")])
    }
  }

  private func evaluateState() -> String {
    for call in observer.calls {
      if !call.hasEnded {
        return call.hasConnected ? "OFFHOOK" : "RINGING"
      }
    }
    return "IDLE"
  }
}
