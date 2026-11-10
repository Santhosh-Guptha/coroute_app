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
import android.os.SystemClock

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
 * - 3.55 fallback so the music ALWAYS gets quieter: the volume we set is read back (now and
 *   [VERIFY_MS] later). On a fixed-volume device (AudioManager.isVolumeFixed), when setStreamVolume
 *   throws (Do Not Disturb policy, OEM restriction) or is ignored (some Bluetooth headsets with
 *   absolute volume keep their own level), a silent transient audio focus is held instead:
 *   AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK (Android 8+ ducks other apps by itself; apps that handle
 *   ducking lower themselves) for the 60 % / 30 % steps, AUDIOFOCUS_GAIN_TRANSIENT (pause) for the
 *   pause step. A headset that reports back a neighbouring index (absolute-volume rounding) is
 *   taken as the value we set, not as the rider changing the volume.
 * - Every change is written to the diagnostics callback [log] (logcat tag CoRouteAudio and the
 *   Dart ride audio log): levels, route kind, focus results. Nothing personal.
 *
 * Main thread only. Text and nothing personal is ever logged.
 */
class MediaVolumeGuard(
    context: Context,
    private val audio: AudioManager?,
    private val main: Handler,
    private val log: (String) -> Unit = {}
) {
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

    /** 3.55: the volume cannot be set here: other apps are ducked / paused by audio focus instead. */
    private var viaFocus = false
    private var duckRequest: Any? = null
    private var ducking = false
    private var lastSetAt = 0L

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

    /** Duck focus (fallback): a permanent loss means another app / the rider took the audio. */
    private val duckListener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change == AudioManager.AUDIOFOCUS_LOSS && ducking) {
            main.post {
                ducking = false
                duckRequest = null
                log("speed music: duck focus lost (other app took audio) -> rider's choice")
                markUserChanged()
            }
        }
    }

    init {
        registerDeviceCallback()
    }

    val isLowered: Boolean get() = lowered

    // ------------------------------------------------------------------ commands from Dart

    /** Lowers music to [fractionIn] of the original (pause = also pause it). */
    fun apply(fractionIn: Double, pause: Boolean): Map<String, Any> {
        val am = audio ?: return result()
        if (userChanged) return result()
        if (!lowered && volumeFixed(am)) viaFocus = true
        if (viaFocus) return applyViaFocus(am, fractionIn, pause)
        val current = currentIndex(am)
        val nowRoute = routeKey(am)
        if (ramping) {
            // Over the limit again while the volume was coming back: stop the ramp, lower from here.
            ramping = false
            setIndex = current
        }
        if (!lowered) {
            if (current <= 2) {
                // Too few volume steps to make it quieter: duck / pause by focus instead.
                viaFocus = true
                return applyViaFocus(am, fractionIn, pause)
            }
            originalIndex = current
            route = nowRoute
            setIndex = current
            lowered = true
        } else if (nowRoute != route) {
            onRouteChanged()
        } else if (ownAudioDepth == 0 && !raisedForOwn && !ramping && setIndex >= 0 && current != setIndex) {
            if (!adoptRounding(current)) {
                log("speed music: volume changed by the rider ($setIndex -> $current), stop lowering")
                markUserChanged()
                return result()
            }
        }
        fraction = fractionIn.coerceIn(0.0, 1.0)
        val target = targetIndex(originalIndex, if (pause) SpeedPauseVolumeFraction else fraction)
        if (target < setIndex || setIndex < 0) {
            setIndex = target
            if (ownAudioDepth == 0) {
                setAndVerify(am, target, current, fractionIn, pause)
            } else {
                // 3.55 fix: our own line is playing at the original volume right now. The lowered
                // index is applied when it ends (it used to be skipped, and the next status check
                // then took the unchanged volume for the rider's choice and stopped lowering).
                raisedForOwn = true
            }
        }
        log("speed music apply ${(fractionIn * 100).toInt()}%${if (pause) " pause" else ""} route=$route idx $originalIndex->$setIndex${if (ownAudioDepth > 0) " (after our line)" else ""}")
        if (pause && !paused) requestPause(am)
        if (viaFocus) return applyViaFocus(am, fractionIn, pause)
        persist()
        return result()
    }

    /** True when this device does not let apps change the media volume. */
    private fun volumeFixed(am: AudioManager): Boolean = try {
        am.isVolumeFixed
    } catch (e: Exception) {
        false
    }

    /**
     * Sets [index] and checks it took: read back now and [VERIFY_MS] later (Bluetooth absolute
     * volume reports asynchronously). Ignored or refused -> focus fallback ([applyViaFocus]).
     */
    private fun setAndVerify(am: AudioManager, index: Int, before: Int, fractionIn: Double, pause: Boolean) {
        if (!setVolume(am, index)) {
            log("speed music: setStreamVolume refused -> focus fallback")
            viaFocus = true
            return
        }
        lastSetAt = SystemClock.elapsedRealtime()
        if (index == before) return
        main.postDelayed({
            if (!lowered || viaFocus || userChanged || ownAudioDepth > 0 || ramping || setIndex != index) return@postDelayed
            val now = currentIndex(am)
            when {
                now == index -> log("speed music: volume set ok ($before -> $index)")
                now == before -> {
                    log("speed music: volume ignored by the device/headset ($before stays) -> focus fallback")
                    viaFocus = true
                    applyViaFocus(am, fractionIn, pause)
                }
                Math.abs(now - index) <= 1 && now < originalIndex -> {
                    log("speed music: headset rounded the volume ($index -> $now), kept")
                    setIndex = now
                    persist()
                }
                else -> Unit // a real change by the rider: status() will see it
            }
        }, VERIFY_MS)
    }

    /** Within [ROUNDING_WINDOW_MS] of our own change, a neighbouring index is the headset's rounding. */
    private fun adoptRounding(current: Int): Boolean {
        if (SystemClock.elapsedRealtime() - lastSetAt > ROUNDING_WINDOW_MS) return false
        if (Math.abs(current - setIndex) > 1 || current > originalIndex) return false
        setIndex = current
        return true
    }

    /** Fallback: the volume cannot be set, so other apps are ducked (or paused) by audio focus. */
    private fun applyViaFocus(am: AudioManager, fractionIn: Double, pause: Boolean): Map<String, Any> {
        if (!lowered) {
            lowered = true
            route = routeKey(am)
        }
        fraction = fractionIn.coerceIn(0.0, 1.0)
        // Put back any index we changed before falling back (the focus does the lowering now).
        if (originalIndex >= 0 && setIndex >= 0 && currentIndex(am) == setIndex && setIndex != originalIndex) setVolume(am, originalIndex)
        originalIndex = -1
        setIndex = -1
        raisedForOwn = false
        if (pause) {
            abandonDuck(am)
            if (!paused) requestPause(am)
        } else if (!ducking && !paused) {
            requestDuck(am)
        }
        clearPrefs()
        return result()
    }

    /** Episode over: resume paused music and bring the volume back smoothly. */
    fun restore(): Map<String, Any> {
        val am = audio
        abandonPause()
        if (am != null) abandonDuck(am)
        if (viaFocus) {
            log("speed music restore (focus released)")
            clear()
            return result()
        }
        if (lowered && !userChanged) log("speed music restore idx $setIndex->$originalIndex")
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
        audio?.let { abandonDuck(it) }
        clear()
        return result()
    }

    /** Checks for a manual change (called by Dart on each sample while lowered). */
    fun status(): Map<String, Any> {
        val am = audio
        if (lowered && !viaFocus && am != null && ownAudioDepth == 0 && !raisedForOwn && !ramping && setIndex >= 0) {
            if (routeKey(am) != route) {
                onRouteChanged()
            } else {
                val cur = currentIndex(am)
                if (cur != setIndex && !adoptRounding(cur)) {
                    log("speed music: volume changed by the rider ($setIndex -> $cur), stop lowering")
                    markUserChanged()
                }
            }
        }
        return result()
    }

    private fun result(): Map<String, Any> = mapOf(
        "lowered" to lowered,
        "paused" to paused,
        "userChanged" to userChanged,
        "mode" to (if (viaFocus) (if (paused) "focusPause" else "focusDuck") else "volume")
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
        if (lowered && !viaFocus && !ramping && ownAudioDepth == 1 && originalIndex >= 0 && currentIndex(am) == setIndex) {
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
        if (!lowered || viaFocus) return
        val current = currentIndex(am)
        if (current == originalIndex) {
            setAndVerify(am, setIndex, current, fraction, paused)
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
        if (viaFocus) {
            route = nowRoute // the focus follows the audio, nothing to move
            return
        }
        log("speed music: route $route -> $nowRoute")
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
            abandonDuck(am)
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
        audio?.let { abandonDuck(it) }
        viaFocus = false
        lowered = false
        ramping = false
        originalIndex = -1
        setIndex = -1
        clearPrefs()
    }

    private fun clear() {
        lowered = false
        viaFocus = false
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

    /** False when the system refused (Do Not Disturb policy, fixed volume, OEM restriction). */
    private fun setVolume(am: AudioManager, index: Int): Boolean {
        if (index < 0) return false
        return try {
            am.setStreamVolume(AudioManager.STREAM_MUSIC, index, 0)
            true
        } catch (e: Exception) {
            false
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
        log("speed music: pause focus ${if (paused) "granted" else "failed"}")
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

    /** Fallback duck: a silent transient "may duck" focus held while lowered (Android 8+ auto-ducks). */
    @Suppress("DEPRECATION")
    private fun requestDuck(am: AudioManager) {
        val granted = try {
            if (Build.VERSION.SDK_INT >= 26) {
                val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                    .setAudioAttributes(silentAttributes)
                    .setWillPauseWhenDucked(false)
                    .setOnAudioFocusChangeListener(duckListener, main)
                    .build()
                duckRequest = req
                am.requestAudioFocus(req)
            } else {
                am.requestAudioFocus(duckListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            }
        } catch (e: Exception) {
            AudioManager.AUDIOFOCUS_REQUEST_FAILED
        }
        ducking = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        log("speed music: duck focus ${if (ducking) "granted" else "failed"}")
    }

    @Suppress("DEPRECATION")
    private fun abandonDuck(am: AudioManager) {
        if (!ducking && duckRequest == null) return
        ducking = false
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                (duckRequest as? AudioFocusRequest)?.let { am.abandonAudioFocusRequest(it) }
            } else {
                am.abandonAudioFocus(duckListener)
            }
        } catch (e: Exception) {
            // ignore
        }
        duckRequest = null
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

        /** The volume we set is read back again this long after (Bluetooth absolute volume is async). */
        private const val VERIFY_MS = 600L

        /** A neighbouring index reported this soon after our change is the headset's rounding. */
        private const val ROUNDING_WINDOW_MS = 2000L

        /** While paused the volume stays at the 30 % step (music resumes quietly if an app ignores focus). */
        private const val SpeedPauseVolumeFraction = 0.3
    }
}
