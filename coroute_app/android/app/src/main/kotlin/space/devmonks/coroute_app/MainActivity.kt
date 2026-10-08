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
        val sms = SmsChannel(applicationContext)
        smsChannel = sms
        MethodChannel(messenger, "coroute/sms").setMethodCallHandler(sms)

        // 3.15: the big ride notification (replaces the foreground service notification in
        // place) and spoken alerts with the phone's text-to-speech engine.
        val rideChannel = MethodChannel(messenger, "coroute/ride_notification")
        val ride = RideNotification(this, rideChannel)
        ride.register()
        rideNotification = ride
        rideChannel.setMethodCallHandler(ride)
        val tts = TtsChannel(applicationContext)
        ttsChannel = tts
        MethodChannel(messenger, "coroute/tts").setMethodCallHandler(tts)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A ride notification button started the app: kept until Dart asks (takeLaunchAction).
        if (savedInstanceState == null) rideNotification?.handleActivityIntent(intent, coldStart = true)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        rideNotification?.handleActivityIntent(intent, coldStart = false)
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
        ttsChannel?.release()
        ttsChannel = null
        MethodChannel(messenger, "coroute/tts").setMethodCallHandler(null)
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
