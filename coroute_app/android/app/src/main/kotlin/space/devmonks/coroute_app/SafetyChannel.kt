package space.devmonks.coroute_app

import android.app.Activity
import android.app.ActivityManager
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.StatFs
import android.provider.Settings
import android.view.WindowManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Small device helpers for rider safety (MethodChannel "coroute/safety"):
 * device info, the Android 14 full-screen alarm permission, the brand
 * autostart / battery page, showing the crash alarm over the lock screen, and (3.16)
 * the app's cache folder and the network kind for the map tile cache.
 * Every call is quick and runs on the main thread (no blocking work).
 */
class SafetyChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    companion object {
        /** How long the pre-ride check listens to the motion sensors. */
        private const val PROBE_MS = 1500L
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "deviceInfo" -> result.success(deviceInfo())
            "canUseFullScreenIntent" -> result.success(canUseFullScreenIntent())
            "openFullScreenIntentSettings" -> result.success(openFullScreenIntentSettings())
            "openOemBatterySettings" -> result.success(openOemBatterySettings())
            "alarmWindow" -> {
                alarmWindow(call.argument<Boolean>("on") == true)
                result.success(null)
            }
            "cacheDir" -> result.success(cacheDir())
            "networkKind" -> result.success(networkKind())
            "phoneProbe" -> phoneProbe(result)
            "openSoundSettings" -> result.success(start(Intent(Settings.ACTION_SOUND_SETTINGS)))
            else -> result.notImplemented()
        }
    }

    /**
     * Pre-ride phone check: counts the real events of the motion sensors for [PROBE_MS]
     * (accelerometer, gyroscope, magnetometer) and reads the phone state that matters on a ride
     * (background limits, Do Not Disturb, volumes, headset outputs, free space, phone/SMS apps).
     * Needs no permission; nothing is stored or sent. Answers once, on the main thread.
     */
    private fun phoneProbe(result: MethodChannel.Result) {
        val app = activity.applicationContext
        val sm = app.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        val types = intArrayOf(Sensor.TYPE_ACCELEROMETER, Sensor.TYPE_GYROSCOPE, Sensor.TYPE_MAGNETIC_FIELD)
        val names = arrayOf("accel", "gyro", "mag")
        val counts = IntArray(types.size)
        val present = BooleanArray(types.size)
        val firstNs = LongArray(types.size)
        val lastNs = LongArray(types.size)
        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                val i = types.indexOf(event.sensor.type)
                if (i < 0) return
                if (counts[i] == 0) firstNs[i] = event.timestamp
                lastNs[i] = event.timestamp
                counts[i]++
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }
        val main = Handler(Looper.getMainLooper())
        if (sm != null) {
            for (i in types.indices) {
                val s = sm.getDefaultSensor(types[i]) ?: continue
                present[i] = true
                try {
                    sm.registerListener(listener, s, 20_000, main)
                } catch (_: Exception) {}
            }
        }
        main.postDelayed({
            try {
                sm?.unregisterListener(listener)
            } catch (_: Exception) {}
            val out = HashMap<String, Any>()
            for (i in types.indices) {
                val span = (lastNs[i] - firstNs[i]) / 1e9
                val hz = if (counts[i] >= 2 && span > 0) (counts[i] - 1) / span else 0.0
                out["${names[i]}Present"] = present[i]
                out["${names[i]}Events"] = counts[i]
                out["${names[i]}Hz"] = hz
            }
            out["probeMs"] = PROBE_MS
            try {
                out.putAll(phoneState(app))
            } catch (_: Exception) {}
            try {
                result.success(out)
            } catch (_: Exception) {}
        }, PROBE_MS)
    }

    private fun phoneState(app: Context): Map<String, Any> {
        val out = HashMap<String, Any>()
        out["sdkInt"] = Build.VERSION.SDK_INT
        try {
            val am = app.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            out["bgRestricted"] = if (Build.VERSION.SDK_INT >= 28) (am?.isBackgroundRestricted ?: false) else false
        } catch (_: Exception) {}
        try {
            val pm = app.getSystemService(Context.POWER_SERVICE) as? PowerManager
            out["powerSave"] = pm?.isPowerSaveMode ?: false
        } catch (_: Exception) {}
        try {
            // 1 = INTERRUPTION_FILTER_ALL (Do Not Disturb off); 2..4 = some form of Do Not Disturb.
            val nm = app.getSystemService(NotificationManager::class.java)
            out["dndFilter"] = nm?.currentInterruptionFilter ?: 0
        } catch (_: Exception) {}
        try {
            val audio = app.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            if (audio != null) {
                out["mediaVol"] = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
                out["mediaVolMax"] = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                out["alarmVol"] = audio.getStreamVolume(AudioManager.STREAM_ALARM)
                out["alarmVolMax"] = audio.getStreamMaxVolume(AudioManager.STREAM_ALARM)
                out["ringerMode"] = audio.ringerMode
                var bt = "none"
                var wired = false
                for (d in audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
                    when (d.type) {
                        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> bt = "sco"
                        AudioDeviceInfo.TYPE_BLE_HEADSET -> if (bt != "sco") bt = "ble"
                        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> if (bt == "none") bt = "a2dp"
                        AudioDeviceInfo.TYPE_WIRED_HEADSET,
                        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                        AudioDeviceInfo.TYPE_USB_HEADSET -> wired = true
                    }
                }
                var btMic = false
                for (d in audio.getDevices(AudioManager.GET_DEVICES_INPUTS)) {
                    if (d.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO || d.type == AudioDeviceInfo.TYPE_BLE_HEADSET) btMic = true
                }
                out["btOut"] = bt
                out["btMic"] = btMic
                out["wiredOut"] = wired
            }
        } catch (_: Exception) {}
        try {
            out["freeBytes"] = StatFs(app.cacheDir.absolutePath).availableBytes
        } catch (_: Exception) {}
        try {
            val pm = app.packageManager
            out["hasTelephony"] = pm.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)
            out["canCompose"] = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:")).resolveActivity(pm) != null
            out["canDial"] = Intent(Intent.ACTION_DIAL, Uri.parse("tel:")).resolveActivity(pm) != null
        } catch (_: Exception) {}
        return out
    }

    private fun deviceInfo(): Map<String, Any> {
        val sensors = activity.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        val accel = sensors?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        val gyro = sensors?.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
        return mapOf(
            "manufacturer" to (Build.MANUFACTURER ?: ""),
            "model" to (Build.MODEL ?: ""),
            "sdkInt" to Build.VERSION.SDK_INT,
            "release" to (Build.VERSION.RELEASE ?: ""),
            "cpuAbi" to (Build.SUPPORTED_ABIS?.firstOrNull() ?: System.getProperty("os.arch") ?: ""),
            "hasAccel" to (accel != null),
            "accelFifo" to (accel?.fifoMaxEventCount ?: 0),
            "hasGyro" to (gyro != null),
            "gyroFifo" to (gyro?.fifoMaxEventCount ?: 0),
        )
    }

    /** The app's own cache folder (cleared by Android when space is short; nothing leaves the phone). */
    private fun cacheDir(): String? {
        return try {
            activity.applicationContext.cacheDir?.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    /** "wifi", "mobile" or "none" for the active network (ACCESS_NETWORK_STATE, already declared). */
    private fun networkKind(): String {
        return try {
            val cm = activity.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return "none"
            val network = cm.activeNetwork ?: return "none"
            val caps = cm.getNetworkCapabilities(network) ?: return "none"
            when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) -> "mobile"
                else -> "none"
            }
        } catch (e: Exception) {
            "none"
        }
    }

    private fun canUseFullScreenIntent(): Boolean {
        if (Build.VERSION.SDK_INT < 34) return true
        val nm = activity.getSystemService(NotificationManager::class.java) ?: return true
        return nm.canUseFullScreenIntent()
    }

    private fun openFullScreenIntentSettings(): Boolean {
        if (Build.VERSION.SDK_INT < 34) return false
        return start(
            Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:" + activity.packageName))
        )
    }

    /**
     * Tries the known autostart / battery pages of the phone's brand, then the
     * app's own settings page. A page that does not exist (or is not exported)
     * on this phone simply fails and the next one is tried.
     */
    private fun openOemBatterySettings(): Boolean {
        val brand = (Build.MANUFACTURER ?: "").lowercase()
        val pkg = activity.packageName
        val candidates = ArrayList<Intent>()
        fun component(packageName: String, className: String): Intent =
            Intent().setComponent(ComponentName(packageName, className))
        when {
            brand.contains("xiaomi") || brand.contains("redmi") || brand.contains("poco") -> {
                candidates.add(component("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"))
                candidates.add(
                    component("com.miui.powerkeeper", "com.miui.powerkeeper.ui.HiddenAppsConfigActivity")
                        .putExtra("package_name", pkg)
                        .putExtra("package_label", "CoRoute")
                )
            }
            brand.contains("samsung") -> {
                candidates.add(component("com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity"))
                candidates.add(component("com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity"))
                candidates.add(component("com.samsung.android.sm", "com.samsung.android.sm.ui.battery.BatteryActivity"))
            }
            brand.contains("oneplus") -> {
                candidates.add(component("com.oneplus.security", "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"))
            }
            brand.contains("oppo") || brand.contains("realme") -> {
                candidates.add(component("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"))
                candidates.add(component("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"))
                candidates.add(component("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"))
                candidates.add(component("com.coloros.oppoguardelf", "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity"))
            }
            brand.contains("vivo") || brand.contains("iqoo") -> {
                candidates.add(component("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"))
                candidates.add(component("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"))
                candidates.add(component("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"))
            }
            brand.contains("huawei") || brand.contains("honor") -> {
                candidates.add(component("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"))
                candidates.add(component("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"))
                candidates.add(component("com.huawei.systemmanager", "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity"))
            }
        }
        candidates.add(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg")))
        for (intent in candidates) {
            if (start(intent)) return true
        }
        return false
    }

    private fun start(intent: Intent): Boolean {
        return try {
            activity.startActivity(intent)
            true
        } catch (e: Exception) {
            // ActivityNotFoundException or SecurityException: not on this phone.
            false
        }
    }

    /** Only while a crash alarm is open: show over the lock screen, turn the screen on, keep it on. */
    @Suppress("DEPRECATION")
    private fun alarmWindow(on: Boolean) {
        if (Build.VERSION.SDK_INT >= 27) {
            activity.setShowWhenLocked(on)
            activity.setTurnScreenOn(on)
            if (on) {
                activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        } else {
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            if (on) activity.window.addFlags(flags) else activity.window.clearFlags(flags)
        }
    }
}
