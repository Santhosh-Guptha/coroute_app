package space.devmonks.coroute_app

import android.content.Context
import android.content.Intent
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var accelStream: AccelStream? = null
    private var smsChannel: SmsChannel? = null
    private var rideNotification: RideNotification? = null
    private var ttsChannel: TtsChannel? = null
    private var phoneCallChannel: PhoneCallChannel? = null
    private var pushChannel: PushChannel? = null
    private var appSecurity: AppSecurityChannel? = null
    private var rideWindow: RideWindowChannel? = null
    private var voiceCodec: VoiceCodecChannel? = null // Round 8 intercom Opus (VoiceCodecChannel.kt)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        EventChannel(messenger, "coroute/ambient_light")
            .setStreamHandler(AmbientLightStream(applicationContext))

        // Rider safety (3.14): accelerometer buckets for crash detection, device helpers
        // for the lock-screen alarm and the brand battery guide, and emergency texts.
        val accel = AccelStream(applicationContext)
        accelStream = accel
        EventChannel(messenger, "coroute/accel").setStreamHandler(accel)
        MethodChannel(messenger, "coroute/safety").setMethodCallHandler(SafetyChannel(this))
        // 3.56: the activity (weakly held) lets the SOS composer ask to unlock first when the SOS
        // screen is shown over the lock screen.
        val self = java.lang.ref.WeakReference(this)
        val sms = SmsChannel(applicationContext) { self.get() }
        smsChannel = sms
        val smsMethods = MethodChannel(messenger, "coroute/sms")
        smsMethods.setMethodCallHandler(sms)
        sms.events = smsMethods // 3.57: emergency text status (sent / delivered / retry) back to Dart

        // 3.15: the big ride notification (replaces the foreground service notification in
        // place) and spoken alerts with the phone's text-to-speech engine.
        val rideChannel = MethodChannel(messenger, "coroute/ride_notification")
        val ride = RideNotification(this, rideChannel)
        ride.register()
        rideNotification = ride
        rideChannel.setMethodCallHandler(ride)
        val tts = TtsChannel(applicationContext)
        ttsChannel = tts
        val ttsMethods = MethodChannel(messenger, "coroute/tts")
        ttsMethods.setMethodCallHandler(tts)
        tts.events = ttsMethods // 3.55: speech start / done and audio diagnostics back to Dart

        val phoneCall = PhoneCallChannel(applicationContext)
        phoneCallChannel = phoneCall
        MethodChannel(messenger, "coroute/phone_call").setMethodCallHandler(phoneCall)
        EventChannel(messenger, "coroute/phone_call_events").setStreamHandler(phoneCall)

        // 3.55 push notifications (FCM): token, foreground messages, tapped notifications.
        val pushMethods = MethodChannel(messenger, "coroute/push")
        val push = PushChannel(this, pushMethods)
        push.register()
        pushChannel = push
        pushMethods.setMethodCallHandler(push)

        // 3.55 "Rate CoRoute": Google Play in-app review card (InAppReviewChannel.kt).
        MethodChannel(messenger, "coroute/in_app_review").setMethodCallHandler(InAppReviewChannel(this))

        // 3.56 "Share to CoRoute": text shared from a maps app (ShareInActivity.kt).
        ShareIn.register(MethodChannel(messenger, "coroute/share_in"))

        // 3.55 "Navigate in Google Maps / Mappls": installed check and package-targeted links.
        MethodChannel(messenger, "coroute/nav_handoff").setMethodCallHandler(NavHandoffChannel(this))

        // 3.56 profile-picture cropper: JPEG encoding of the app's own canvas (ImageEncodeChannel.kt).
        MethodChannel(messenger, "coroute/image").setMethodCallHandler(ImageEncodeChannel())
        // Round 4: FLAG_SECURE on sensitive screens, fingerprint / screen-lock app lock, Medical ID (AppSecurityChannel.kt).
        val security = AppSecurityChannel(this)
        appSecurity = security
        MethodChannel(messenger, "coroute/app_security").setMethodCallHandler(security)

        // Cockpit on the lock screen while riding + the ride screen's heat check (RideWindowChannel.kt).
        val rideWindowMethods = MethodChannel(messenger, "coroute/ride_window")
        val rideWin = RideWindowChannel(this, rideWindowMethods)
        rideWin.register()
        rideWindow = rideWin
        rideWindowMethods.setMethodCallHandler(rideWin)
        // Round 8: intercom Opus encode / decode on MediaCodec (VoiceCodecChannel.kt).
        val codec = VoiceCodecChannel()
        voiceCodec = codec
        MethodChannel(messenger, "coroute/voice_codec").setMethodCallHandler(codec)
    }

    // The screen-lock confirmation of the app lock on Android 6-8 (AppSecurityChannel); everything else as before.
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (appSecurity?.onActivityResult(requestCode, resultCode) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // 3.55 diagnostics log: native crashes go to files/diag (merged into the app log next start).
        CrashLog.install(applicationContext)
        super.onCreate(savedInstanceState)
        // A ride notification button started the app: kept until Dart asks (takeLaunchAction).
        if (savedInstanceState == null) rideNotification?.handleActivityIntent(intent, coldStart = true)
        // A tapped push notification started the app: kept until Dart asks (takeLaunchMessage).
        if (savedInstanceState == null) pushChannel?.handleActivityIntent(intent, coldStart = true)
        // Text shared to CoRoute started the app: kept until Dart asks (takeSharedText).
        if (savedInstanceState == null) ShareIn.handleActivityIntent(intent, coldStart = true)
    }

    override fun onResume() {
        super.onResume()
        PushChannel.foreground = true
        CrashLog.startStallWatch() // 3.55: main-thread stalls of 5 s+ while in front (ANR-like)
        rideWindow?.checkKeyguard() // locked cockpit: the keyguard may have changed while away
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        rideWindow?.checkKeyguard() // the system unlock sheet comes and goes over the window
    }

    override fun onPause() {
        PushChannel.foreground = false
        CrashLog.stopStallWatch()
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        rideNotification?.handleActivityIntent(intent, coldStart = false)
        pushChannel?.handleActivityIntent(intent, coldStart = false)
        ShareIn.handleActivityIntent(intent, coldStart = false)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // The sensor must never outlive the screen's engine (battery).
        accelStream?.stop()
        accelStream = null
        smsChannel?.dispose()
        smsChannel = null
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        EventChannel(messenger, "coroute/accel").setStreamHandler(null)
        MethodChannel(messenger, "coroute/safety").setMethodCallHandler(null)
        MethodChannel(messenger, "coroute/sms").setMethodCallHandler(null)
        rideNotification?.dispose()
        rideNotification = null
        MethodChannel(messenger, "coroute/ride_notification").setMethodCallHandler(null)
        ttsChannel?.events = null
        ttsChannel?.dispose() // also gives back music lowered by "Lower music when speeding"
        ttsChannel = null
        MethodChannel(messenger, "coroute/tts").setMethodCallHandler(null)
        phoneCallChannel?.dispose()
        phoneCallChannel = null
        MethodChannel(messenger, "coroute/phone_call").setMethodCallHandler(null)
        EventChannel(messenger, "coroute/phone_call_events").setStreamHandler(null)
        pushChannel?.dispose()
        pushChannel = null
        MethodChannel(messenger, "coroute/push").setMethodCallHandler(null)
        MethodChannel(messenger, "coroute/nav_handoff").setMethodCallHandler(null)
        MethodChannel(messenger, "coroute/install_referrer").setMethodCallHandler(null)
        MethodChannel(messenger, "coroute/in_app_review").setMethodCallHandler(null)
        MethodChannel(messenger, "coroute/image").setMethodCallHandler(null)
        appSecurity?.dispose()
        appSecurity = null
        MethodChannel(messenger, "coroute/app_security").setMethodCallHandler(null)
        rideWindow?.dispose() // also takes the window off the keyguard
        rideWindow = null
        MethodChannel(messenger, "coroute/ride_window").setMethodCallHandler(null)
        MethodChannel(messenger, "coroute/voice_codec").setMethodCallHandler(null)
        voiceCodec?.dispose()
        voiceCodec = null
        ShareIn.channel?.let { ShareIn.dispose(it) }
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

/**
 * Ambient light in lux, for the "Light sensor" theme option. The sensor is
 * registered only while the app listens (CoRoute on screen with that option
 * chosen) and reports at most once a second, batched, to keep the phone asleep.
 */
private class AmbientLightStream(context: Context) : EventChannel.StreamHandler, SensorEventListener {
    private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val light = sensors.getDefaultSensor(Sensor.TYPE_LIGHT)
        if (light == null) {
            events.error("NO_SENSOR", "This phone has no light sensor.", null)
            return
        }
        sink = events
        sensors.registerListener(this, light, 1_000_000, 5_000_000)
    }

    override fun onCancel(arguments: Any?) {
        sensors.unregisterListener(this)
        sink = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        sink?.success(event.values[0].toDouble())
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
