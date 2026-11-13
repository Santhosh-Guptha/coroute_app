package space.devmonks.coroute_app

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel
import kotlin.math.acos
import kotlin.math.max
import kotlin.math.sqrt

/**
 * High-precision Accelerometer and Gyroscope Stream for Motorcycle Crash Detection (EventChannel "coroute/accel").
 *
 * Registered only while Dart listens (during active rides, speed > 25 km/h in last 30s or evaluating candidate).
 * Features:
 * - Dynamic linear acceleration with continuous gravity compensation (low-pass IIR filter).
 * - Real-time gyroscope angular velocity (rad/s) integration for rollover/fall analysis.
 * - Reference orientation tilt tracking to detect lowside and highside falls onto bike sides.
 * - Lightweight 100-sample (2s @ 50 Hz) pre/post impact rolling buffer for impact duration estimation.
 * - Monotonic timestamp-aware discrete jerk (da/dt) calculation for rapid transient shock analysis.
 * - Hardware and sensor health tracking (gyroscope availability and sample rate confidence).
 * - Bounded Android partial wake-lock scoped strictly to active sensor sessions to survive deep sleep.
 * - Hardware batching (maxLatencyUs) to permit sensor hub batching and low battery consumption.
 * - Posts 10-element telemetry: [tMs, peakRawG, meanRawG, stdRawG, peakDynG, peakGyroRadS, tiltDeg, durationMs, peakJerkGPerS, sensorConfidence].
 */
class AccelStream(context: Context) : EventChannel.StreamHandler {
    private val appContext = context.applicationContext
    private val sensors = appContext.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var session: Session? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        session?.stop()
        session = null
        val args = arguments as? Map<*, *>
        val samplingUs = (args?.get("samplingUs") as? Number)?.toInt() ?: 20_000
        val maxLatencyUs = (args?.get("maxLatencyUs") as? Number)?.toInt() ?: 2_000_000

        // Prefer wake-up sensor variant for background/locked-screen reliability
        val accelSensor = sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER, true)
            ?: sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        if (accelSensor == null) {
            events.error("NO_SENSOR", "This phone has no accelerometer.", null)
            return
        }

        val gyroSensor = sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE, true)
            ?: sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE)

        val s = Session(
            context = appContext,
            sensors = sensors,
            accelSensor = accelSensor,
            gyroSensor = gyroSensor,
            sink = events,
            samplingUs = samplingUs.coerceIn(5_000, 200_000),
            maxLatencyUs = maxLatencyUs.coerceIn(0, 10_000_000)
        )
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

    companion object {
        /** Partial wake-lock timeout; re-armed every [WAKE_RENEW_MS] while sensor events arrive. */
        private const val WAKE_TIMEOUT_MS = 30 * 60 * 1000L
        private const val WAKE_RENEW_MS = 10 * 60 * 1000L
    }

    private class HighResSample {
        var tMs: Long = 0L
        var gDyn: Double = 0.0
        var gRaw: Double = 0.0
        var gyroRadS: Double = 0.0
    }

    private class Session(
        private val context: Context,
        private val sensors: SensorManager,
        private val accelSensor: Sensor,
        private val gyroSensor: Sensor?,
        private val sink: EventChannel.EventSink,
        private val samplingUs: Int,
        private val maxLatencyUs: Int,
    ) : SensorEventListener {
        private val main = Handler(Looper.getMainLooper())
        private var thread: HandlerThread? = null
        private var wakeLock: PowerManager.WakeLock? = null

        @Volatile
        private var active = false

        // Gravity estimation filter state (alpha = 0.90 for ~0.8 Hz cutoff at 50 Hz)
        private var gravityInit = false
        private var gx = 0.0
        private var gy = 0.0
        private var gz = SensorManager.GRAVITY_EARTH.toDouble()
        private var refGx = 0.0
        private var refGy = 0.0
        private var refGz = SensorManager.GRAVITY_EARTH.toDouble()

        // Gyroscope tracking
        private var currentGyroRadS = 0.0
        private var peakGyro = 0.0

        // High-resolution rolling buffer (100 samples = 2 seconds at 50 Hz)
        private val ringSize = 100
        private val ringBuf = Array(ringSize) { HighResSample() }
        private var ringHead = 0
        private var highRunMs = 0.0
        private var wakeLockAt = 0L

        // Bucket state (touched only on the sensor thread)
        private var bucketSecond = Long.MIN_VALUE
        private var count = 0
        private var sumRaw = 0.0
        private var sumSqRaw = 0.0
        private var peakRaw = 0.0
        private var peakDyn = 0.0
        private var maxTilt = 0.0
        private var maxDurationMs = 0.0
        private var peakJerk = 0.0

        /// Std (g) of the last closed one-second bucket: below 0.02 g the phone lies dead still.
        private var lastBucketStd = 1.0

        private val closed = ArrayList<Double>(128)
        private var lastFlush = 0L

        fun start(): Boolean {
            val t = HandlerThread("coroute-accel")
            t.start()
            thread = t
            active = true

            // Acquire bounded partial wake-lock strictly while active sensor session runs
            try {
                val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
                wakeLock = pm?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "coroute:safety_sensor")?.apply {
                    setReferenceCounted(false)
                    acquire(WAKE_TIMEOUT_MS) // bounded; renewed from onSensorChanged while the session runs
                }
                wakeLockAt = SystemClock.elapsedRealtime()
            } catch (_: Exception) {}

            val handler = Handler(t.looper)
            val accelOk = sensors.registerListener(this, accelSensor, samplingUs, maxLatencyUs, handler)
            if (!accelOk) {
                stop()
                return false
            }

            // Register gyroscope if device hardware supports it
            if (gyroSensor != null) {
                sensors.registerListener(this, gyroSensor, samplingUs, maxLatencyUs, handler)
            }

            return true
        }

        fun stop() {
            if (!active && thread == null) return
            active = false
            try {
                sensors.unregisterListener(this)
            } catch (_: Exception) {}

            try {
                if (wakeLock?.isHeld == true) {
                    wakeLock?.release()
                }
            } catch (_: Exception) {}
            wakeLock = null

            thread?.quitSafely()
            thread = null
        }

        override fun onSensorChanged(event: SensorEvent) {
            if (!active) return

            if (event.sensor.type == Sensor.TYPE_GYROSCOPE) {
                val rx = event.values[0].toDouble()
                val ry = event.values[1].toDouble()
                val rz = event.values[2].toDouble()
                currentGyroRadS = sqrt(rx * rx + ry * ry + rz * rz)
                peakGyro = max(peakGyro, currentGyroRadS)
                return
            }

            if (event.sensor.type != Sensor.TYPE_ACCELEROMETER) return

            val x = event.values[0].toDouble()
            val y = event.values[1].toDouble()
            val z = event.values[2].toDouble()

            val gRaw = sqrt(x * x + y * y + z * z) / SensorManager.GRAVITY_EARTH

            // Real-time gravity isolation (IIR low-pass filter)
            if (!gravityInit) {
                gx = x; gy = y; gz = z
                refGx = x; refGy = y; refGz = z
                gravityInit = true
            } else {
                val alpha = 0.90
                gx = alpha * gx + (1.0 - alpha) * x
                gy = alpha * gy + (1.0 - alpha) * y
                gz = alpha * gz + (1.0 - alpha) * z
            }

            // Linear acceleration vector (gravity subtracted)
            val linX = x - gx
            val linY = y - gy
            val linZ = z - gz
            val gDyn = sqrt(linX * linX + linY * linY + linZ * linZ) / SensorManager.GRAVITY_EARTH

            // Tilt angle calculation relative to upright riding baseline
            val dot = gx * refGx + gy * refGy + gz * refGz
            val normG = sqrt(gx * gx + gy * gy + gz * gz)
            val normRef = sqrt(refGx * refGx + refGy * refGy + refGz * refGz)
            val currentTiltDeg = if (normG > 0.1 && normRef > 0.1) {
                val cosA = (dot / (normG * normRef)).coerceIn(-1.0, 1.0)
                Math.toDegrees(acos(cosA))
            } else {
                0.0
            }

            // Slowly adapt the baseline orientation while riding (calm sample, but the phone vibrates
            // with the bike: last second's std >= 0.02 g), time constant about 30 s at 50 Hz.
            // 3.55 false-SOS review: it used to adapt with a ~4 s time constant on ANY calm sample,
            // including a phone lying dead still on a fallen bike, so the tilt read "upright" again
            // within seconds of a crash or a tip-over (the rider-down check cancelled as "lifted",
            // and post-impact orientation could not be judged). A phone clipped into the mount after
            // the start still re-baselines within about a minute of riding.
            if (gDyn < 0.4 && currentGyroRadS < 0.25 && lastBucketStd >= 0.02) {
                refGx = 0.9993 * refGx + 0.0007 * gx
                refGy = 0.9993 * refGy + 0.0007 * gy
                refGz = 0.9993 * refGz + 0.0007 * gz
            }

            // Event timestamp converted to epoch ms
            val ageMs = (SystemClock.elapsedRealtimeNanos() - event.timestamp) / 1_000_000L
            val nowMs = System.currentTimeMillis()
            val tMs = if (ageMs in 0..60_000) nowMs - ageMs else nowMs
            val second = tMs / 1000L

            if (second != bucketSecond) {
                closeBucket()
                bucketSecond = second
            }

            // High-resolution rolling buffer entry and discrete jerk (da/dt) calculation
            val prevSample = ringBuf[ringHead]
            val dtSec = if (prevSample.tMs > 0 && tMs > prevSample.tMs) (tMs - prevSample.tMs) / 1000.0 else 0.02
            val currentJerk = if (dtSec in 0.005..0.2) kotlin.math.abs(gDyn - prevSample.gDyn) / dtSec else 0.0
            peakJerk = max(peakJerk, currentJerk)

            ringHead = (ringHead + 1) % ringSize
            ringBuf[ringHead].apply {
                this.tMs = tMs
                this.gDyn = gDyn
                this.gRaw = gRaw
                this.gyroRadS = currentGyroRadS
            }

            // Continuous impact duration tracking (samples >= 2.0g dynamic linear shock). Uses the real
            // sample spacing (the requested 50 Hz is only a hint to Android) and survives the 1 s bucket
            // boundary, so an impact that straddles two buckets is not cut short and mistaken for a
            // pothole (<= 35 ms) or a pebble hit (< 25 ms) by the Dart crash rule.
            if (gDyn >= 2.0) {
                highRunMs += (dtSec * 1000.0).coerceIn(5.0, 200.0)
            } else {
                highRunMs = 0.0
            }
            val currentDurationMs = highRunMs

            count++
            sumRaw += gRaw
            sumSqRaw += gRaw * gRaw
            peakRaw = max(peakRaw, gRaw)
            peakDyn = max(peakDyn, gDyn)
            maxTilt = max(maxTilt, currentTiltDeg)
            maxDurationMs = max(maxDurationMs, currentDurationMs)

            val now = SystemClock.elapsedRealtime()
            // Round 7 (faster safety response): a closed bucket that holds an impact (peak of 3 g or
            // more) is handed to Dart at once instead of waiting out the 500 ms flush spacing. The
            // buckets themselves are unchanged (same one-second windows, same numbers), so the crash
            // rule sees exactly what it saw before, up to half a second sooner.
            val urgent = closed.size >= 10 && closed[closed.size - 9] >= 3.0
            if (closed.isNotEmpty() && (urgent || now - lastFlush >= 500L)) {
                lastFlush = now
                flush()
            }

            // Rides last longer than the wake-lock timeout: before it ran out the lock was simply
            // gone after 30 min and crash detection could stall in deep sleep for the rest of the
            // ride. Re-arming the timeout keeps it bounded (it still ends if events stop coming).
            if (now - wakeLockAt >= WAKE_RENEW_MS) {
                wakeLockAt = now
                try {
                    wakeLock?.acquire(WAKE_TIMEOUT_MS)
                } catch (_: Exception) {}
            }
        }

        private fun closeBucket() {
            if (count > 0 && bucketSecond != Long.MIN_VALUE) {
                val mean = sumRaw / count
                val variance = max(0.0, sumSqRaw / count - mean * mean)
                val sensorConfidence = if (gyroSensor != null) (if (count >= 30) 1.0 else 0.8) else (if (count >= 30) 0.7 else 0.5)
                // 10-element telemetry:
                // [tMs, peakRawG, meanRawG, stdRawG, peakDynG, peakGyroRadS, maxTiltDeg, maxDurationMs, peakJerkGPerS, sensorConfidence]
                closed.add((bucketSecond * 1000L).toDouble())
                closed.add(peakRaw)
                closed.add(mean)
                lastBucketStd = sqrt(variance)
                closed.add(lastBucketStd)
                closed.add(peakDyn)
                closed.add(peakGyro)
                closed.add(maxTilt)
                closed.add(maxDurationMs)
                closed.add(peakJerk)
                closed.add(sensorConfidence)
            }
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
