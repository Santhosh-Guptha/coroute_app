package space.devmonks.coroute_app

import android.annotation.TargetApi
import android.app.Activity
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.WindowManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Who wants MainActivity's window over the keyguard (docs/features_355/lock_screen_cockpit.md).
 *
 *  - alarm: the crash alarm / SOS hold screen (SafetyChannel.alarmWindow, the ride notification's SOS
 *    trampoline). Shows over the keyguard AND turns the screen on, as before.
 *  - cockpit: the ride screen during a ride (RideWindowChannel "setCockpitOverKeyguard"). Shows over the keyguard
 *    only; it NEVER turns the screen on: a normal ride update must not wake the phone.
 *
 * One owner of the flags, so closing the SOS screen (alarm off) no longer takes the cockpit off the lock screen,
 * and the end of a ride (cockpit off) never hides an open crash alarm.
 */
object LockWindow {
    @Volatile
    private var alarm = false

    @Volatile
    private var cockpit = false

    val cockpitOn: Boolean get() = cockpit

    /** [keepScreenOn]: the crash alarm also keeps the screen on while it is open (unchanged behaviour). */
    fun setAlarm(activity: Activity, on: Boolean, keepScreenOn: Boolean) {
        alarm = on
        apply(activity)
        if (!keepScreenOn) return
        try {
            if (on) {
                activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        } catch (_: Exception) {
            // no window (activity finishing)
        }
    }

    fun setCockpit(activity: Activity, on: Boolean) {
        if (cockpit == on) return
        cockpit = on
        apply(activity)
    }

    @Suppress("DEPRECATION")
    private fun apply(activity: Activity) {
        val show = alarm || cockpit
        try {
            if (Build.VERSION.SDK_INT >= 27) {
                activity.setShowWhenLocked(show)
                activity.setTurnScreenOn(alarm)
            } else {
                val w = activity.window
                if (show) w.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED) else w.clearFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED)
                if (alarm) w.addFlags(WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON) else w.clearFlags(WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
            }
        } catch (_: Exception) {
            // no window (activity finishing)
        }
    }
}

/**
 * The lock-screen cockpit and the ride screen's heat check (MethodChannel "coroute/ride_window"):
 *
 *  - "setCockpitOverKeyguard" {on}: [LockWindow] cockpit flag (setShowWhenLocked on API 27+, the window flag
 *    before). Dart turns it on only during a ride, signed in, with the setting on and the cockpit in front.
 *  - "keyguardLocked": KeyguardManager.isKeyguardLocked. Changes go to Dart as "onKeyguardChanged" {locked}:
 *    checked on screen on / off, user present (unlocked), resume and window focus.
 *  - "requestUnlock": KeyguardManager.requestDismissKeyguard (API 26+) -> "ok", "cancelled", "error" or
 *    "notLocked". Android 6-7: the dismiss-keyguard window flag, answered by the next unlock (or "cancelled"
 *    after 30 s).
 *  - "thermalStatus": PowerManager.getCurrentThermalStatus (API 29+, 0 before). Changes go to Dart as
 *    "onThermalChanged" {status}.
 *
 * Framework APIs only; no new permission. Nothing is logged.
 */
class RideWindowChannel(private val activity: Activity, private val channel: MethodChannel) : MethodChannel.MethodCallHandler {

    companion object {
        private const val LEGACY_UNLOCK_TIMEOUT_MS = 30_000L
    }

    private val app: Context = activity.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private var lastLocked: Boolean? = null
    private var receiverRegistered = false
    private var thermalListener: Any? = null
    private var legacyUnlock: MethodChannel.Result? = null
    private val checkNow = Runnable { checkKeyguard() }
    private val legacyTimeout = Runnable { finishLegacyUnlock("cancelled") }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_SCREEN_ON -> {
                    checkKeyguard()
                    // The keyguard state can settle a moment after the screen comes on.
                    main.postDelayed(checkNow, 400)
                    main.postDelayed(checkNow, 1200)
                }
                Intent.ACTION_SCREEN_OFF -> main.postDelayed(checkNow, 600)
                Intent.ACTION_USER_PRESENT -> {
                    finishLegacyUnlock("ok")
                    checkKeyguard()
                }
            }
        }
    }

    fun register() {
        if (!receiverRegistered) {
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_USER_PRESENT)
            }
            try {
                if (Build.VERSION.SDK_INT >= 33) {
                    app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
                } else {
                    app.registerReceiver(receiver, filter)
                }
                receiverRegistered = true
            } catch (_: Exception) {
                receiverRegistered = false
            }
        }
        if (Build.VERSION.SDK_INT >= 29) addThermalListener()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setCockpitOverKeyguard" -> {
                LockWindow.setCockpit(activity, call.argument<Boolean>("on") == true)
                checkKeyguard()
                result.success(null)
            }
            "keyguardLocked" -> {
                val locked = locked()
                lastLocked = locked
                result.success(locked)
            }
            "requestUnlock" -> requestUnlock(result)
            "thermalStatus" -> result.success(thermalStatus())
            else -> result.notImplemented()
        }
    }

    private fun keyguard(): KeyguardManager? = app.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager

    private fun locked(): Boolean = try { keyguard()?.isKeyguardLocked == true } catch (_: Exception) { false }

    /** Tells Dart when the keyguard state changed (MainActivity calls it on resume and window focus too). */
    fun checkKeyguard() {
        val now = locked()
        if (now == lastLocked) return
        lastLocked = now
        try {
            channel.invokeMethod("onKeyguardChanged", mapOf("locked" to now))
        } catch (_: Exception) {
            // engine going away
        }
    }

    private fun requestUnlock(result: MethodChannel.Result) {
        val km = keyguard()
        if (km == null || !km.isKeyguardLocked) {
            result.success("notLocked")
            return
        }
        if (Build.VERSION.SDK_INT >= 26) {
            dismissKeyguard(km, result)
            return
        }
        legacyDismiss(result)
    }

    @TargetApi(26)
    private fun dismissKeyguard(km: KeyguardManager, result: MethodChannel.Result) {
        val answered = AtomicBoolean(false)
        fun answer(value: String) {
            if (!answered.compareAndSet(false, true)) return
            try { result.success(value) } catch (_: Exception) { /* already answered */ }
            main.post(checkNow)
        }
        try {
            km.requestDismissKeyguard(activity, object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() = answer("ok")
                override fun onDismissCancelled() = answer("cancelled")
                override fun onDismissError() = answer("error")
            })
        } catch (_: Exception) {
            answer("error")
        }
    }

    /** Android 6-7: no dismiss callback; the window flag asks for the unlock and USER_PRESENT answers. */
    @Suppress("DEPRECATION")
    private fun legacyDismiss(result: MethodChannel.Result) {
        if (legacyUnlock != null) {
            result.success("cancelled")
            return
        }
        legacyUnlock = result
        try {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD)
        } catch (_: Exception) {
            finishLegacyUnlock("error")
            return
        }
        main.postDelayed(legacyTimeout, LEGACY_UNLOCK_TIMEOUT_MS)
    }

    @Suppress("DEPRECATION")
    private fun finishLegacyUnlock(value: String) {
        val r = legacyUnlock ?: return
        legacyUnlock = null
        main.removeCallbacks(legacyTimeout)
        try { activity.window.clearFlags(WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD) } catch (_: Exception) { /* gone */ }
        try { r.success(value) } catch (_: Exception) { /* already answered */ }
    }

    private fun thermalStatus(): Int = if (Build.VERSION.SDK_INT >= 29) currentThermal() else 0

    @TargetApi(29)
    private fun currentThermal(): Int = try {
        (app.getSystemService(Context.POWER_SERVICE) as? PowerManager)?.currentThermalStatus ?: 0
    } catch (_: Exception) {
        0
    }

    @TargetApi(29)
    private fun addThermalListener() {
        if (thermalListener != null) return
        val pm = app.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        val listener = PowerManager.OnThermalStatusChangedListener { status ->
            try {
                channel.invokeMethod("onThermalChanged", mapOf("status" to status))
            } catch (_: Exception) {
                // engine going away
            }
        }
        try {
            pm.addThermalStatusListener(app.mainExecutor, listener)
            thermalListener = listener
        } catch (_: Exception) {
            thermalListener = null
        }
    }

    @TargetApi(29)
    private fun removeThermalListener() {
        val listener = thermalListener as? PowerManager.OnThermalStatusChangedListener ?: return
        thermalListener = null
        try {
            (app.getSystemService(Context.POWER_SERVICE) as? PowerManager)?.removeThermalStatusListener(listener)
        } catch (_: Exception) {
            // already gone
        }
    }

    fun dispose() {
        main.removeCallbacks(checkNow)
        finishLegacyUnlock("cancelled")
        if (receiverRegistered) {
            try { app.unregisterReceiver(receiver) } catch (_: Exception) { /* already gone */ }
            receiverRegistered = false
        }
        if (Build.VERSION.SDK_INT >= 29) removeThermalListener()
        // Never left over the keyguard without a Dart side deciding it (sign-out, engine gone).
        LockWindow.setCockpit(activity, false)
    }
}
