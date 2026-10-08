package space.devmonks.coroute_app

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Accelerometer for crash detection (EventChannel "coroute/accel").
 *
 * Registered only while Dart listens, which the app does only during a ride,
 * above 25 km/h in the last 30 s, with crash detection on. The sensor is the
 * non-wake-up accelerometer, registered with a hardware batch latency
 * (maxReportLatencyUs) so the sensor hub buffers samples and the CPU can sleep.
 * Samples are reduced on a background HandlerThread to one-second buckets
 * (peak, mean and standard deviation of |a| in g) and posted to Dart as one
 * DoubleArray [tMs, peakG, meanG, stdG, ...] at most every 500 ms.
 */
class AccelStream(context: Context) : EventChannel.StreamHandler {
    private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var session: Session? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        session?.stop()
        session = null
        val args = arguments as? Map<*, *>
        val samplingUs = (args?.get("samplingUs") as? Number)?.toInt() ?: 20_000
        val maxLatencyUs = (args?.get("maxLatencyUs") as? Number)?.toInt() ?: 2_000_000
        val sensor = sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER, false)
            ?: sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        if (sensor == null) {
            events.error("NO_SENSOR", "This phone has no accelerometer.", null)
            return
        }
        val s = Session(sensors, sensor, events, samplingUs.coerceIn(5_000, 200_000), maxLatencyUs.coerceIn(0, 10_000_000))
        if (!s.start()) {
            events.error("NO_SENSOR", "The accelerometer could not be started.", null)
            return
        }
        session = s
    }

    override fun onCancel(arguments: Any?) {
        stop()
    }

    fun stop() {
        session?.stop()
        session = null
    }

    private class Session(
        private val sensors: SensorManager,
        private val sensor: Sensor,
        private val sink: EventChannel.EventSink,
        private val samplingUs: Int,
        private val maxLatencyUs: Int,
    ) : SensorEventListener {
        private val main = Handler(Looper.getMainLooper())
        private var thread: HandlerThread? = null

        @Volatile
        private var active = false

        // Bucket state: touched only on the sensor thread.
        private var bucketSecond = Long.MIN_VALUE
        private var count = 0
        private var sum = 0.0
        private var sumSq = 0.0
        private var peak = 0.0
        private val closed = ArrayList<Double>(64)
        private var lastFlush = 0L

        fun start(): Boolean {
            val t = HandlerThread("coroute-accel")
            t.start()
            thread = t
            active = true
            val ok = sensors.registerListener(this, sensor, samplingUs, maxLatencyUs, Handler(t.looper))
            if (!ok) stop()
            return ok
        }

        fun stop() {
            if (!active && thread == null) return
            active = false
            sensors.unregisterListener(this)
            thread?.quitSafely()
            thread = null
        }

        override fun onSensorChanged(event: SensorEvent) {
            if (!active) return
            val x = event.values[0].toDouble()
            val y = event.values[1].toDouble()
            val z = event.values[2].toDouble()
            val g = sqrt(x * x + y * y + z * z) / SensorManager.GRAVITY_EARTH
            // event.timestamp is on the elapsedRealtimeNanos clock; turn it into epoch ms.
            val ageMs = (SystemClock.elapsedRealtimeNanos() - event.timestamp) / 1_000_000L
            val nowMs = System.currentTimeMillis()
            val tMs = if (ageMs in 0..60_000) nowMs - ageMs else nowMs
            val second = tMs / 1000L
            if (second != bucketSecond) {
                closeBucket()
                bucketSecond = second
            }
            count++
            sum += g
            sumSq += g * g
            peak = max(peak, g)
            val now = SystemClock.elapsedRealtime()
            if (closed.isNotEmpty() && now - lastFlush >= 500L) {
                lastFlush = now
                flush()
            }
        }

        private fun closeBucket() {
            if (count > 0 && bucketSecond != Long.MIN_VALUE) {
                val mean = sum / count
                val variance = max(0.0, sumSq / count - mean * mean)
                closed.add((bucketSecond * 1000L).toDouble())
                closed.add(peak)
                closed.add(mean)
                closed.add(sqrt(variance))
            }
            count = 0
            sum = 0.0
            sumSq = 0.0
            peak = 0.0
        }

        private fun flush() {
            val data = DoubleArray(closed.size) { closed[it] }
            closed.clear()
            main.post {
                if (active) sink.success(data)
            }
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
    }
}
