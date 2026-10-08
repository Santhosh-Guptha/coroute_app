package space.devmonks.coroute_app

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var accelStream: AccelStream? = null
    private var smsChannel: SmsChannel? = null

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
