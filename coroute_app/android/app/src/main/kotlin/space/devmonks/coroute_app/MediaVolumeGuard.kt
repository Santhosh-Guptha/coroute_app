package space.devmonks.coroute_app

import android.content.Context
import android.content.SharedPreferences
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler

/**
 * 3.55 "Lower music when speeding" (native half; the decision is lib/domain/safety/speed_audio_policy.dart).
 *
 * Lowers OTHER apps' music while the rider is far over the speed limit and restores it after:
 * - apply(fraction): STREAM_MUSIC index = original x fraction (only ever lowered, at least 1).
 * - pause: holds a transient audio focus (silent) so music apps pause; abandoning it resumes them.
 * - restore: abandons the pause focus and ramps the volume back up one step every [RAMP_STEP_MS].
 * - The rider changed the volume (or pressed play, which takes the focus back) during an episode:
 *   reported as userChanged and the saved volume is forgotten (never restored over their choice).
 * - CoRoute's own guidance speech (and, via setOwnAudio, the intercom) is never lowered: while it
 *   plays the original index is put back (other music is then ducked by audio focus), and the lowered
 *   index is applied again when it ends. Critical lines on the phone speaker use the alarm stream (not
 *   affected at all); with a headset they are media speech too (TtsChannel), so the same applies.
 * - Volume indexes are per output device: a route change (Bluetooth helmet set connects or drops)
 *   keeps the old route's saved volume as pending and restores it when that route comes back.
 * - The saved volume survives an app kill (SharedPreferences): [restoreLeftovers] at the next start
 *   puts it back when the volume is still the one we set.
 *
 * Main thread only. Text and nothing personal is ever logged.
 */
class MediaVolumeGuard(context: Context, private val audio: AudioManager?, private val main: Handler) {
    private val prefs: SharedPreferences = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private var lowered = false
    private var route = ""
    private var originalIndex = -1
    private var setIndex = -1
    private var fraction = 1.0
    private var paused = false
    private var userChanged = false
    private var ownAudioDepth = 0

    /** [ownAudioBegin] put the original volume back; [ownAudioEnd] lowers it again. */
    private var raisedForOwn = false
    private var ramping = false
    private var pauseRequest: Any? = null
    private var ownFocusRequest: Any? = null
    private var deviceCallback: Any? = null

    private val silentAttributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    /** Pause focus: a permanent loss means the rider resumed the music themselves. */
    private val pauseListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change == AudioManager.AUDIOFOCUS_LOSS && paused) {
            main.post {
                paused = false
                pauseRequest = null
                markUserChanged()
            }
        }
    }

    private val ownFocusListener = AudioManager.OnAudioFocusChangeListener { }

    init {
        registerDeviceCallback()
    }

    val isLowered: Boolean get() = lowered

    // ------------------------------------------------------------------ commands from Dart

    /** Lowers music to [fractionIn] of the original (pause = also pause it). */
    fun apply(fractionIn: Double, pause: Boolean): Map<String, Any> {
        val am = audio ?: return result()
        if (userChanged) return result()
        val current = currentIndex(am)
        val nowRoute = routeKey(am)
        if (ramping) {
            // Over the limit again while the volume was coming back: stop the ramp, lower from here.
            ramping = false
            setIndex = current
        }
        if (!lowered) {
            originalIndex = current
            route = nowRoute
            setIndex = current
            lowered = true
        } else if (nowRoute != route) {
            onRouteChanged()
        } else if (ownAudioDepth == 0 && !raisedForOwn && !ramping && setIndex >= 0 && current != setIndex) {
            markUserChanged()
            return result()
        }
        fraction = fractionIn.coerceIn(0.0, 1.0)
        val target = targetIndex(originalIndex, if (pause) SpeedPauseVolumeFraction else fraction)
        if (target < setIndex || setIndex < 0) {
            setIndex = target
            if (ownAudioDepth == 0) setVolume(am, target)
        }
        if (pause && !paused) requestPause(am)
        persist()
        return result()
    }

    /** Episode over: resume paused music and bring the volume back smoothly. */
    fun restore(): Map<String, Any> {
        val am = audio
        abandonPause()
        if (!lowered || am == null || userChanged) {
            clear()
            return result()
        }
        rampTo(am, originalIndex)
        return result()
    }

    /** Episode over and the rider took control: forget everything, touch nothing. */
    fun forget(): Map<String, Any> {
        abandonPause()
        clear()
        return result()
    }

    /** Checks for a manual change (called by Dart on each sample while lowered). */
    fun status(): Map<String, Any> {
        val am = audio
        if (lowered && am != null && ownAudioDepth == 0 && !raisedForOwn && !ramping && setIndex >= 0) {
            if (routeKey(am) != route) {
                onRouteChanged()
            } else if (currentIndex(am) != setIndex) {
                markUserChanged()
            }
        }
        return result()
    }

    private fun result(): Map<String, Any> = mapOf(
        "lowered" to lowered,
        "paused" to paused,
        "userChanged" to userChanged
    ).also { if (userChanged && !lowered) userChanged = false }

    // ------------------------------------------------------------------ own audio (never lowered)

    /**
     * CoRoute's own speech / intercom starts: put the rider's original volume back for it.
     * [duckOthers] requests a ducking focus too (the intercom; speech has its own focus).
     */
    fun ownAudioBegin(duckOthers: Boolean) {
        ownAudioDepth++
        val am = audio ?: return
        if (duckOthers) requestOwnFocus(am)
        if (lowered && !ramping && ownAudioDepth == 1 && originalIndex >= 0 && currentIndex(am) == setIndex) {
            setVolume(am, originalIndex)
            raisedForOwn = true
        }
    }

    fun ownAudioEnd(duckOthers: Boolean) {
        if (ownAudioDepth == 0) return
        ownAudioDepth--
        val am = audio ?: return
        if (duckOthers) abandonOwnFocus(am)
        if (ownAudioDepth > 0 || !raisedForOwn) return
        raisedForOwn = false
        if (!lowered) return
        val current = currentIndex(am)
        if (current == originalIndex) {
            setVolume(am, setIndex)
        } else {
            // The rider moved the volume while we were speaking: their choice wins.
            markUserChanged()
        }
    }

    // ------------------------------------------------------------------ start-up / routes

    /** At start: a volume left lowered by a killed app is put back if nobody changed it since. */
    fun restoreLeftovers() {
        val am = audio ?: return
        try {
            val wasLowered = prefs.getBoolean(K_LOWERED, false)
            val savedRoute = prefs.getString(K_ROUTE, "") ?: ""
            val orig = prefs.getInt(K_ORIG, -1)
            val set = prefs.getInt(K_SET, -1)
            val nowRoute = routeKey(am)
            if (wasLowered && orig >= 0) {
                if (savedRoute == nowRoute) {
                    if (currentIndex(am) == set) setVolume(am, orig)
                } else {
                    savePending(savedRoute, orig, set)
                }
            }
            prefs.edit().remove(K_LOWERED).remove(K_ROUTE).remove(K_ORIG).remove(K_SET).apply()
            restorePendingFor(am, nowRoute)
        } catch (e: Exception) {
            // never block start-up
        }
    }

    private fun onRouteChanged() {
        val am = audio ?: return
        val nowRoute = routeKey(am)
        if (!lowered) {
            restorePendingFor(am, nowRoute)
            return
        }
        if (nowRoute == route) return
        // The old route keeps its lowered index: remembered, restored when it comes back.
        savePending(route, originalIndex, setIndex)
        route = nowRoute
        val pending = takePending(nowRoute)
        val current = currentIndex(am)
        originalIndex = if (pending != null && current == pending.second) pending.first else current
        setIndex = current
        val target = targetIndex(originalIndex, if (paused) SpeedPauseVolumeFraction else fraction)
        if (target < setIndex) {
            setIndex = target
            if (ownAudioDepth == 0) setVolume(am, target)
        }
        persist()
    }

    private fun restorePendingFor(am: AudioManager, key: String) {
        val p = takePending(key) ?: return
        if (currentIndex(am) == p.second) setVolume(am, p.first)
    }

    private fun savePending(key: String, orig: Int, set: Int) {
        if (key.isEmpty() || orig < 0) return
        prefs.edit().putString(K_PENDING + key, "$orig,$set").apply()
    }

    private fun takePending(key: String): Pair<Int, Int>? {
        val raw = prefs.getString(K_PENDING + key, null) ?: return null
        prefs.edit().remove(K_PENDING + key).apply()
        val parts = raw.split(",")
        if (parts.size != 2) return null
        val o = parts[0].toIntOrNull() ?: return null
        val s = parts[1].toIntOrNull() ?: return null
        return Pair(o, s)
    }

    @Suppress("DEPRECATION")
    private fun registerDeviceCallback() {
        val am = audio ?: return
        try {
            val cb = object : AudioDeviceCallback() {
                override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
                    main.post { onRouteChanged() }
                }

                override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
                    main.post { onRouteChanged() }
                }
            }
            am.registerAudioDeviceCallback(cb, main)
            deviceCallback = cb
        } catch (e: Exception) {
            deviceCallback = null
        }
    }

    fun dispose() {
        val am = audio
        try {
            val cb = deviceCallback as? AudioDeviceCallback
            if (am != null && cb != null) am.unregisterAudioDeviceCallback(cb)
        } catch (e: Exception) {
            // ignore
        }
        deviceCallback = null
        abandonPause()
        if (am != null) {
            abandonOwnFocus(am)
            // The screen's engine goes away: put the rider's volume back now when nobody touched it.
            // (A killed process cannot do this; restoreLeftovers does it at the next start.)
            ramping = false
            if (lowered && !userChanged && originalIndex >= 0 && currentIndex(am) == setIndex) {
                setVolume(am, originalIndex)
                clear()
            }
        }
        ownAudioDepth = 0
        raisedForOwn = false
    }

    // ------------------------------------------------------------------ helpers

    private fun markUserChanged() {
        userChanged = true
        abandonPause()
        lowered = false
        ramping = false
        originalIndex = -1
        setIndex = -1
        clearPrefs()
    }

    private fun clear() {
        lowered = false
        paused = false
        ramping = false
        originalIndex = -1
        setIndex = -1
        fraction = 1.0
        userChanged = false
        clearPrefs()
    }

    private fun clearPrefs() {
        try {
            prefs.edit().remove(K_LOWERED).remove(K_ROUTE).remove(K_ORIG).remove(K_SET).apply()
        } catch (e: Exception) {
            // ignore
        }
    }

    private fun persist() {
        try {
            prefs.edit()
                .putBoolean(K_LOWERED, lowered)
                .putString(K_ROUTE, route)
                .putInt(K_ORIG, originalIndex)
                .putInt(K_SET, setIndex)
                .apply()
        } catch (e: Exception) {
            // ignore
        }
    }

    private fun rampTo(am: AudioManager, target: Int) {
        ramping = true
        var expected = currentIndex(am)
        val step = object : Runnable {
            override fun run() {
                if (!ramping) return
                val now = currentIndex(am)
                if (now != expected) {
                    // The rider took over during the ramp.
                    ramping = false
                    clear()
                    return
                }
                if (now >= target) {
                    ramping = false
                    clear()
                    return
                }
                expected = now + 1
                setVolume(am, expected)
                main.postDelayed(this, RAMP_STEP_MS)
            }
        }
        main.post(step)
    }

    private fun targetIndex(orig: Int, f: Double): Int {
        if (orig <= 0) return 0
        return Math.round(orig * f).toInt().coerceIn(1, orig)
    }

    private fun currentIndex(am: AudioManager): Int = try {
        am.getStreamVolume(AudioManager.STREAM_MUSIC)
    } catch (e: Exception) {
        0
    }

    private fun setVolume(am: AudioManager, index: Int) {
        if (index < 0) return
        try {
            am.setStreamVolume(AudioManager.STREAM_MUSIC, index, 0)
        } catch (e: Exception) {
            // DND / fixed volume device: nothing to do
        }
    }

    private fun routeKey(am: AudioManager): String {
        return try {
            val outs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            var wired = false
            for (d in outs) {
                val t = d.type
                if (t == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP) return "bt"
                if (Build.VERSION.SDK_INT >= 31 && (t == AudioDeviceInfo.TYPE_BLE_HEADSET || t == AudioDeviceInfo.TYPE_BLE_SPEAKER)) return "bt"
                if (t == AudioDeviceInfo.TYPE_WIRED_HEADSET || t == AudioDeviceInfo.TYPE_WIRED_HEADPHONES || t == AudioDeviceInfo.TYPE_USB_HEADSET) wired = true
            }
            if (wired) "wired" else "speaker"
        } catch (e: Exception) {
            "speaker"
        }
    }

    @Suppress("DEPRECATION")
    private fun requestPause(am: AudioManager) {
        val granted = try {
            if (Build.VERSION.SDK_INT >= 26) {
                val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                    .setAudioAttributes(silentAttributes)
                    .setOnAudioFocusChangeListener(pauseListener, main)
                    .build()
                pauseRequest = req
                am.requestAudioFocus(req)
            } else {
                am.requestAudioFocus(pauseListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            }
        } catch (e: Exception) {
            AudioManager.AUDIOFOCUS_REQUEST_FAILED
        }
        paused = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    @Suppress("DEPRECATION")
    private fun abandonPause() {
        if (!paused && pauseRequest == null) return
        paused = false
        val am = audio ?: return
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                (pauseRequest as? AudioFocusRequest)?.let { am.abandonAudioFocusRequest(it) }
            } else {
                am.abandonAudioFocus(pauseListener)
            }
        } catch (e: Exception) {
            // ignore
        }
        pauseRequest = null
    }

    @Suppress("DEPRECATION")
    private fun requestOwnFocus(am: AudioManager) {
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                    .setAudioAttributes(silentAttributes)
                    .setOnAudioFocusChangeListener(ownFocusListener, main)
                    .build()
                ownFocusRequest = req
                am.requestAudioFocus(req)
            } else {
                am.requestAudioFocus(ownFocusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            }
        } catch (e: Exception) {
            // ignore
        }
    }

    @Suppress("DEPRECATION")
    private fun abandonOwnFocus(am: AudioManager) {
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                (ownFocusRequest as? AudioFocusRequest)?.let { am.abandonAudioFocusRequest(it) }
            } else {
                am.abandonAudioFocus(ownFocusListener)
            }
        } catch (e: Exception) {
            // ignore
        }
        ownFocusRequest = null
    }

    companion object {
        private const val PREFS = "coroute_media_volume_guard"
        private const val K_LOWERED = "lowered"
        private const val K_ROUTE = "route"
        private const val K_ORIG = "orig"
        private const val K_SET = "set"
        private const val K_PENDING = "pending_"
        private const val RAMP_STEP_MS = 250L

        /** While paused the volume stays at the 30 % step (music resumes quietly if an app ignores focus). */
        private const val SpeedPauseVolumeFraction = 0.3
    }
}
