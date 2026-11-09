package space.devmonks.coroute_app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * Spoken ride alerts with the phone's own text-to-speech engine (MethodChannel
 * "coroute/tts", 3.15). No package, no network.
 *
 * - init {language?} -> {ok, language}: binds the engine (lazily, on the first alert of a
 *   ride) and picks the requested voice (3.16: "hi-IN" / "te-IN", then "hi" / "te"), else
 *   Indian English, else US / UK / any English. ok=false when there is no engine or no
 *   usable voice (the app then stays silent; banners still show). The language in the
 *   answer tells Dart whether the requested one was found.
 * - speak {text, id, interrupt, isEmergency, pauseOthers, inCall?, afterCall?} -> Boolean:
 *   QUEUE_FLUSH when interrupt, else QUEUE_ADD.
 *     * ordinary lines: usage "navigation guidance" (goes to a Bluetooth helmet set over A2DP like
 *       map directions; SCO is never forced for speech) with transient focus that DUCKS other apps
 *       (AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK), or PAUSES them when the rider chose "Pause music".
 *     * isEmergency (P0 / P1 critical): AUDIOFOCUS_GAIN_TRANSIENT so music apps pause, and (3.55 rule
 *       for ALL critical lines) the route decides the usage:
 *         - a headset is connected (Bluetooth A2DP / LE audio / hearing aid / wired / USB): usage
 *           "navigation guidance", so the line plays in the helmet / earbuds over A2DP like media.
 *           Noise cancellation does not block playback. USAGE_ALARM is NOT used then, because
 *           Android may force alarms to the phone speaker as well (the rider would not hear it
 *           in the helmet, and bystanders would). The media volume is raised to at least
 *           [CRITICAL_HEADSET_MIN_FRACTION] of max for the line and put back after (unless the
 *           rider changed it meanwhile);
 *         - no headset: usage ALARM (heard on the speaker with media volume 0 and through Do Not
 *           Disturb when alarms are allowed).
 *     * inCall (3.55 call-aware): a short distinct tone and the (already shortened) phrase on the
 *       voice-call stream, so the rider hears it in the call audio; no focus is requested.
 *     * afterCall: waits (up to [AFTER_CALL_WAIT_MS]) for the phone to leave call mode, then speaks.
 *   Focus is released [FOCUS_GRACE_MS] after the engine's queue drains (not between lines, so the
 *   music does not pump), and re-requested when another app takes it during a critical line.
 * - fallbackAlert {critical, inCall} (3.55): tone + vibration when speech is impossible (no engine,
 *   engine error).
 * - speedAudio {action: apply|restore|forget|status, fraction, pause} -> {lowered, paused,
 *   userChanged} and ownAudio {active}: see [MediaVolumeGuard] ("Lower music when speeding").
 * - listeningState -> {headset: 'bluetooth'|'wired'|'hearingAid'|'', musicActive, inCall} (3.55 sound
 *   awareness): whether the rider may not hear outside sound. A cheap AudioManager query, no mic.
 * - alertTone (3.55): one short tone (siren close by while the rider can hear outside sound).
 * - stop, release (unbinds the engine at ride end).
 * Text is cut to 300 characters and never logged.
 */
class TtsChannel(context: Context) : MethodChannel.MethodCallHandler {
    private val app: Context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val audio: AudioManager? = app.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    /** 3.55: "Lower music when speeding" (native half). */
    val volumeGuard = MediaVolumeGuard(app, audio, main)

    private var tts: TextToSpeech? = null
    private var ready = false
    private var ok = false
    private var language = ""
    private var requested = ""
    private val waiting = ArrayList<MethodChannel.Result>()

    /** Utterances handed to the engine and not finished yet (main thread only). */
    private val active = HashSet<String>()

    /** Critical utterances among [active] (focus is fought for while one plays). */
    private val activeCritical = HashSet<String>()
    private var hasFocus = false
    private var currentFocusGain = 0

    /** Our guidance speech asked the volume guard to put the original media volume back. */
    private var ownAudioHeld = false

    /** 3.55: media volume raised for a critical line on a headset (index before / index we set; -1 = none). */
    private var floorPrevIndex = -1
    private var floorSetIndex = -1

    /** Watchdog to ensure audio focus is never leaked if the TTS engine hangs or crashes. */
    private val safetyFocusWatchdog = Runnable {
        if (hasFocus && active.isNotEmpty()) {
            active.clear()
            activeCritical.clear()
            abandonFocus()
        }
    }

    /** Focus is given back a moment after the queue drained, so back-to-back lines share one duck. */
    private val delayedAbandon = Runnable { if (active.isEmpty()) abandonFocus() }

    /** Bumped by release, so a late init callback of an old engine is ignored. */
    private var generation = 0

    /** AudioFocusRequest on Android 8+ (kept as Any so older phones never load the class). */
    private var focusRequest: Any? = null

    private val guidanceAttributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    private val emergencyAttributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    /** 3.55: in-call critical phrase, mixed into the call audio the rider hears (never sent to the caller). */
    private val inCallAttributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    private val attributes: AudioAttributes = guidanceAttributes

    // Transient interruptions (calls, tones) duck audio focus without terminating the engine.
    private val focusListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        main.post { onFocusChange(focusChange) }
    }

    private fun onFocusChange(focusChange: Int) {
        when (focusChange) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                // Another app took permanent focus (started its music, navigation app...). Speech keeps
                // playing (focus is not enforced for guidance / alarm), but a critical line asks again
                // so the other app is paused / ducked while it is said.
                // An ordinary line just finishes; the next one asks again.
                hasFocus = false
                currentFocusGain = 0
                if (activeCritical.isNotEmpty()) {
                    main.postDelayed({
                        if (activeCritical.isNotEmpty() && !hasFocus) requestFocus(isEmergency = true, pauseOthers = true)
                    }, 300L)
                }
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                // Transient interruption (call alert, ducking); TTS guidance persists or recovers safely
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                hasFocus = true
            }
        }
    }

    private val initTimeout = Runnable { if (!ready) finishInit(false) }

    private val progress = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) {}

        override fun onDone(utteranceId: String?) {
            main.post { finished(utteranceId) }
        }

        @Deprecated("Deprecated in Java")
        override fun onError(utteranceId: String?) {
            main.post { finished(utteranceId) }
        }

        override fun onError(utteranceId: String?, errorCode: Int) {
            main.post { finished(utteranceId) }
        }

        override fun onStop(utteranceId: String?, interrupted: Boolean) {
            main.post { finished(utteranceId) }
        }
    }

    init {
        // A volume left lowered by a killed app ("Lower music when speeding") comes back now.
        volumeGuard.restoreLeftovers()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                requested = (call.argument<String>("language") ?: "").trim()
                init(result)
            }
            "speak" -> {
                val text = (call.argument<String>("text") ?: "").take(MAX_CHARS)
                val id = call.argument<String>("id") ?: "coroute"
                val interrupt = call.argument<Boolean>("interrupt") == true
                val isEmergency = call.argument<Boolean>("isEmergency") == true || call.argument<Boolean>("emergency") == true
                val pauseOthers = call.argument<Boolean>("pauseOthers") == true
                val inCall = call.argument<Boolean>("inCall") == true
                val afterCall = call.argument<Boolean>("afterCall") == true
                result.success(
                    when {
                        inCall && isCallConnected() -> speakInCall(text, id)
                        afterCall && isInPhoneCall() -> speakAfterCall(text, id, isEmergency, pauseOthers)
                        else -> speak(text, id, interrupt, isEmergency, pauseOthers)
                    }
                )
            }
            "fallbackAlert" -> {
                val critical = call.argument<Boolean>("critical") == true
                val inCall = call.argument<Boolean>("inCall") == true || isInPhoneCall()
                fallbackAlert(critical, inCall)
                result.success(true)
            }
            "requestEmergencyFocus" -> {
                requestFocus(isEmergency = true)
                result.success(hasFocus)
            }
            "abandonEmergencyFocus" -> {
                abandonFocus()
                result.success(null)
            }
            "speedAudio" -> {
                val action = call.argument<String>("action") ?: "status"
                val fraction = (call.argument<Number>("fraction") ?: 1.0).toDouble()
                val pause = call.argument<Boolean>("pause") == true
                result.success(
                    when (action) {
                        "apply" -> volumeGuard.apply(fraction, pause)
                        "restore" -> volumeGuard.restore()
                        "forget" -> volumeGuard.forget()
                        else -> volumeGuard.status()
                    }
                )
            }
            "ownAudio" -> {
                // The intercom is playing a rider's voice: never lowered by "Lower music when speeding".
                if (call.argument<Boolean>("active") == true) volumeGuard.ownAudioBegin(true) else volumeGuard.ownAudioEnd(true)
                result.success(null)
            }
            "audioState" -> result.success(audioState())
            "listeningState" -> result.success(listeningState())
            "alertTone" -> {
                // Headset: media stream (heard in the ears); speaker: alarm stream (heard at media volume 0).
                val stream = if (headsetOutput().isNotEmpty()) AudioManager.STREAM_MUSIC else AudioManager.STREAM_ALARM
                playTone(stream, ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD, 400)
                result.success(true)
            }
            "stop" -> {
                stop()
                result.success(null)
            }
            "release" -> {
                release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun init(result: MethodChannel.Result) {
        if (ready) {
            result.success(mapOf("ok" to ok, "language" to language))
            return
        }
        waiting.add(result)
        if (tts != null) return
        val gen = ++generation
        try {
            tts = TextToSpeech(app) { status -> main.post { if (gen == generation) onInit(status) } }
            main.postDelayed(initTimeout, INIT_TIMEOUT_MS)
        } catch (e: Exception) {
            finishInit(false)
        }
    }

    private fun onInit(status: Int) {
        if (ready) return
        val engine = tts
        if (status != TextToSpeech.SUCCESS || engine == null) {
            finishInit(false)
            return
        }
        val chosen = chooseLanguage(engine)
        if (chosen) {
            try {
                engine.setAudioAttributes(attributes)
                engine.setOnUtteranceProgressListener(progress)
            } catch (e: Exception) {
                // keep the defaults
            }
        }
        finishInit(chosen)
    }

    /**
     * The requested language first (its region tag, then the bare language), then Indian
     * English (familiar place names and numbers), then other English voices.
     */
    private fun chooseLanguage(engine: TextToSpeech): Boolean {
        val candidates = ArrayList<Locale>()
        val want = requested
        if (want.isNotEmpty() && !want.startsWith("en", ignoreCase = true)) {
            try {
                val loc = Locale.forLanguageTag(want)
                if (loc.language.isNotEmpty()) {
                    candidates.add(loc)
                    if (loc.country.isNotEmpty()) candidates.add(Locale.Builder().setLanguage(loc.language).build())
                }
            } catch (e: Exception) {
                // a bad tag: English below
            }
        }
        candidates.add(Locale.Builder().setLanguage("en").setRegion("IN").build())
        candidates.add(Locale.US)
        candidates.add(Locale.UK)
        candidates.add(Locale.ENGLISH)
        for (loc in candidates) {
            val available = try {
                engine.isLanguageAvailable(loc)
            } catch (e: Exception) {
                TextToSpeech.LANG_NOT_SUPPORTED
            }
            if (available < TextToSpeech.LANG_AVAILABLE) continue
            val set = try {
                engine.setLanguage(loc)
            } catch (e: Exception) {
                TextToSpeech.LANG_NOT_SUPPORTED
            }
            if (set >= TextToSpeech.LANG_AVAILABLE) {
                language = loc.toLanguageTag()
                return true
            }
        }
        return false
    }

    private fun finishInit(success: Boolean) {
        main.removeCallbacks(initTimeout)
        ready = true
        ok = success
        if (!success) {
            language = ""
            try {
                tts?.shutdown()
            } catch (e: Exception) {
                // ignore
            }
            tts = null
        }
        val reply = mapOf("ok" to ok, "language" to language)
        val results = ArrayList(waiting)
        waiting.clear()
        for (r in results) r.success(reply)
    }

    private fun isInPhoneCall(): Boolean {
        val amMode = audio?.mode ?: AudioManager.MODE_NORMAL
        if (amMode == AudioManager.MODE_IN_COMMUNICATION && PhoneCallChannel.ownCommunicationMode) return false
        return amMode == AudioManager.MODE_IN_CALL ||
               amMode == AudioManager.MODE_IN_COMMUNICATION ||
               amMode == AudioManager.MODE_RINGTONE ||
               (Build.VERSION.SDK_INT >= 30 && amMode == AudioManager.MODE_CALL_SCREENING)
    }

    /** A call is connected (not only ringing): audio goes to the call's own device and stream. */
    private fun isCallConnected(): Boolean {
        val amMode = audio?.mode ?: AudioManager.MODE_NORMAL
        if (amMode == AudioManager.MODE_IN_COMMUNICATION && PhoneCallChannel.ownCommunicationMode) return false
        return amMode == AudioManager.MODE_IN_CALL || amMode == AudioManager.MODE_IN_COMMUNICATION
    }

    private fun speak(text: String, id: String, interrupt: Boolean, isEmergency: Boolean = false, pauseOthers: Boolean = false): Boolean {
        val engine = tts
        if (!ready || !ok || engine == null || text.isBlank()) return false
        // Do not interfere with phone calls unless it is a genuine emergency alert
        if (isInPhoneCall() && !isEmergency) return false

        // ALWAYS request audio focus so background audio (Spotify, podcasts, music)
        // is ducked (lowered to quiet background) or paused during spoken alerts,
        // making speed warnings, hazard cues and guidance loud, distinct and audible!
        main.removeCallbacks(delayedAbandon)
        requestFocus(isEmergency = isEmergency, pauseOthers = pauseOthers)

        if (interrupt) {
            // the flushed ones report onStop; nothing waits for them
            active.clear()
            activeCritical.clear()
        }

        // 3.55: a critical line with a headset connected goes to the headset as media (A2DP), never
        // the alarm usage (which Android may also play on the phone speaker). See the class doc.
        val headsetCritical = isEmergency && headsetOutput().isNotEmpty()

        // Guidance speech uses the media volume: while music is lowered for speeding, our own
        // line plays at the rider's original volume (alarm-stream critical lines are unaffected).
        if ((!isEmergency || headsetCritical) && !ownAudioHeld) {
            ownAudioHeld = true
            volumeGuard.ownAudioBegin(false)
        }
        if (headsetCritical) raiseCriticalFloor()

        try {
            engine.setAudioAttributes(if (isEmergency && !headsetCritical) emergencyAttributes else guidanceAttributes)
        } catch (e: Exception) {
            // keep existing attributes
        }

        val params = Bundle().apply {
            putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 1.0f) // 100% maximum volume gain
            putString(TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID, id)
        }

        val code = try {
            engine.speak(text, if (interrupt) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD, params, id)
        } catch (e: Exception) {
            TextToSpeech.ERROR
        }
        if (code == TextToSpeech.SUCCESS) {
            active.add(id)
            if (isEmergency) activeCritical.add(id)
            main.removeCallbacks(safetyFocusWatchdog)
            main.postDelayed(safetyFocusWatchdog, 25000L)
            return true
        }
        if (active.isEmpty()) abandonFocus()
        return false
    }

    /**
     * 3.55 call-aware: a critical line while a call is connected. A short distinct tone on the
     * voice-call stream, then the phrase with the voice-communication usage (heard in the call
     * audio, on the earpiece or the helmet's call link). The caller does not hear it.
     */
    private fun speakInCall(text: String, id: String): Boolean {
        val engine = tts
        playTone(AudioManager.STREAM_VOICE_CALL, ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD, 450)
        vibrate(true)
        if (!ready || !ok || engine == null || text.isBlank()) return true // the tone and buzz still went out
        main.postDelayed({
            try {
                engine.setAudioAttributes(inCallAttributes)
                val params = Bundle().apply {
                    putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 1.0f)
                    putString(TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID, id)
                }
                if (engine.speak(text, TextToSpeech.QUEUE_FLUSH, params, id) == TextToSpeech.SUCCESS) {
                    active.add(id)
                    main.removeCallbacks(safetyFocusWatchdog)
                    main.postDelayed(safetyFocusWatchdog, 25000L)
                }
            } catch (e: Exception) {
                // the tone already went out
            }
        }, 550L)
        return true
    }

    /** 3.55: the after-call summary waits for the phone to leave call mode (hang-up takes a moment). */
    private fun speakAfterCall(text: String, id: String, isEmergency: Boolean, pauseOthers: Boolean): Boolean {
        val started = System.currentTimeMillis()
        val tryNow = object : Runnable {
            override fun run() {
                if (isInPhoneCall() && System.currentTimeMillis() - started < AFTER_CALL_WAIT_MS) {
                    main.postDelayed(this, 300L)
                    return
                }
                // Still in a call after the wait (a second call): only critical lines speak then.
                speak(text, id, false, isEmergency, pauseOthers)
            }
        }
        main.postDelayed(tryNow, 300L)
        return ready && ok && tts != null
    }

    /** 3.55: speech impossible (no engine, engine error): a tone and a buzz instead. */
    private fun fallbackAlert(critical: Boolean, inCall: Boolean) {
        val stream = when {
            inCall && isCallConnected() -> AudioManager.STREAM_VOICE_CALL
            critical && headsetOutput().isEmpty() -> AudioManager.STREAM_ALARM // headset: media, heard in the ears
            else -> AudioManager.STREAM_MUSIC
        }
        val tone = if (critical) ToneGenerator.TONE_CDMA_EMERGENCY_RINGBACK else ToneGenerator.TONE_PROP_BEEP2
        playTone(stream, tone, if (critical) 1200 else 400)
        vibrate(critical)
    }

    private fun playTone(stream: Int, tone: Int, durationMs: Int) {
        try {
            val gen = ToneGenerator(stream, 90)
            gen.startTone(tone, durationMs)
            main.postDelayed({
                try {
                    gen.release()
                } catch (e: Exception) {
                    // ignore
                }
            }, durationMs + 300L)
        } catch (e: Exception) {
            // no tone generator on this stream (busy or not allowed)
        }
    }

    @Suppress("DEPRECATION")
    private fun vibrate(critical: Boolean) {
        try {
            val vib: Vibrator? = if (Build.VERSION.SDK_INT >= 31) {
                (app.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
            } else {
                app.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
            if (vib == null || !vib.hasVibrator()) return
            val pattern = if (critical) longArrayOf(0, 500, 200, 500, 200, 500) else longArrayOf(0, 250)
            if (Build.VERSION.SDK_INT >= 26) {
                vib.vibrate(VibrationEffect.createWaveform(pattern, -1))
            } else {
                vib.vibrate(pattern, -1)
            }
        } catch (e: Exception) {
            // no vibrator / not allowed
        }
    }

    private fun audioState(): Map<String, Any> {
        val am = audio
        return mapOf(
            "musicActive" to (am?.isMusicActive == true),
            "musicVolume" to (try { am?.getStreamVolume(AudioManager.STREAM_MUSIC) ?: 0 } catch (e: Exception) { 0 }),
            "musicMax" to (try { am?.getStreamMaxVolume(AudioManager.STREAM_MUSIC) ?: 0 } catch (e: Exception) { 0 }),
            "alarmVolume" to (try { am?.getStreamVolume(AudioManager.STREAM_ALARM) ?: 0 } catch (e: Exception) { 0 }),
            "inCall" to isInPhoneCall(),
            "speedLowered" to volumeGuard.isLowered
        )
    }

    /**
     * 3.55: the output the rider hears through: 'bluetooth' (A2DP, LE audio headset; SCO too when
     * [includeSco]), 'hearingAid', 'wired' (wired / USB headset or headphones) or '' (phone speaker).
     * Routing uses includeSco = false: a call-only (HFP) headset does not carry media, so a critical
     * line for it stays on the alarm stream (speaker) rather than going silent into nowhere.
     */
    private fun headsetOutput(includeSco: Boolean = false): String {
        val am = audio ?: return ""
        return try {
            var kind = ""
            for (d in am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
                val t = d.type
                if (t == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP) return "bluetooth"
                if (includeSco && t == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) kind = "bluetooth"
                if (Build.VERSION.SDK_INT >= 31 && t == AudioDeviceInfo.TYPE_BLE_HEADSET) return "bluetooth"
                if (Build.VERSION.SDK_INT >= 28 && t == AudioDeviceInfo.TYPE_HEARING_AID) kind = "hearingAid"
                if (kind.isEmpty() && (t == AudioDeviceInfo.TYPE_WIRED_HEADSET || t == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                        (Build.VERSION.SDK_INT >= 26 && t == AudioDeviceInfo.TYPE_USB_HEADSET))) kind = "wired"
            }
            kind
        } catch (e: Exception) {
            ""
        }
    }

    /** 3.55 sound awareness: may the rider be unable to hear outside sound? (no mic needed) */
    private fun listeningState(): Map<String, Any> = mapOf(
        "headset" to headsetOutput(includeSco = true),
        "musicActive" to (try { audio?.isMusicActive == true } catch (e: Exception) { false }),
        "inCall" to isInPhoneCall()
    )

    /** A critical line on a headset: media volume at least [CRITICAL_HEADSET_MIN_FRACTION] of max. */
    private fun raiseCriticalFloor() {
        val am = audio ?: return
        if (floorSetIndex >= 0) return
        try {
            val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            val cur = am.getStreamVolume(AudioManager.STREAM_MUSIC)
            val floor = Math.ceil(max * CRITICAL_HEADSET_MIN_FRACTION).toInt()
            if (max > 0 && cur < floor) {
                am.setStreamVolume(AudioManager.STREAM_MUSIC, floor, 0)
                floorPrevIndex = cur
                floorSetIndex = floor
            }
        } catch (e: Exception) {
            // fixed-volume device / not allowed: the line plays at the current volume
        }
    }

    /** Puts the media volume back after the critical line, unless the rider changed it meanwhile. */
    private fun restoreCriticalFloor() {
        if (floorSetIndex < 0) return
        val am = audio
        try {
            if (am != null && am.getStreamVolume(AudioManager.STREAM_MUSIC) == floorSetIndex) {
                am.setStreamVolume(AudioManager.STREAM_MUSIC, floorPrevIndex, 0)
            }
        } catch (e: Exception) {
            // ignore
        }
        floorPrevIndex = -1
        floorSetIndex = -1
    }

    private fun finished(id: String?) {
        if (id != null) {
            active.remove(id)
            activeCritical.remove(id)
        }
        if (active.isEmpty()) {
            // Give the next line a moment to arrive before the music comes back up.
            main.removeCallbacks(delayedAbandon)
            main.postDelayed(delayedAbandon, FOCUS_GRACE_MS)
        }
    }

    private fun stop() {
        try {
            tts?.stop()
        } catch (e: Exception) {
            // ignore
        }
        active.clear()
        activeCritical.clear()
        main.removeCallbacks(delayedAbandon)
        abandonFocus()
    }

    /** Ride end: unbind the engine (it is started again by the next alert). */
    fun release() {
        generation++
        main.removeCallbacks(initTimeout)
        main.removeCallbacks(delayedAbandon)
        try {
            tts?.stop()
            tts?.shutdown()
        } catch (e: Exception) {
            // ignore
        }
        tts = null
        active.clear()
        activeCritical.clear()
        abandonFocus()
        val wasReady = ready
        ready = false
        ok = false
        language = ""
        if (!wasReady && waiting.isNotEmpty()) {
            val results = ArrayList(waiting)
            waiting.clear()
            for (r in results) r.success(mapOf("ok" to false, "language" to ""))
        }
    }

    /** The activity's engine is going away: release speech and give back any lowered music volume. */
    fun dispose() {
        release()
        volumeGuard.dispose()
    }

    @Suppress("DEPRECATION")
    private fun requestFocus(isEmergency: Boolean = false, pauseOthers: Boolean = false) {
        val am = audio ?: return
        val targetGain = if (isEmergency || pauseOthers) {
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
        } else {
            AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
        }

        // If we already hold focus of equal or higher exclusivity, keep it
        if (hasFocus && (currentFocusGain == targetGain || currentFocusGain == AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)) {
            return
        }

        val targetAttributes = if (isEmergency && headsetOutput().isEmpty()) emergencyAttributes else guidanceAttributes

        val granted = try {
            if (Build.VERSION.SDK_INT >= 26) {
                // Upgrading duck -> pause: give the old request back first so no stale entry stays.
                val old = focusRequest as? AudioFocusRequest
                if (hasFocus && old != null) am.abandonAudioFocusRequest(old)
                val request = AudioFocusRequest.Builder(targetGain)
                    .setAudioAttributes(targetAttributes)
                    .setOnAudioFocusChangeListener(focusListener)
                    .setWillPauseWhenDucked(false)
                    .build()
                focusRequest = request
                am.requestAudioFocus(request)
            } else {
                am.requestAudioFocus(
                    focusListener,
                    if (isEmergency && headsetOutput().isEmpty()) AudioManager.STREAM_ALARM else AudioManager.STREAM_MUSIC,
                    targetGain
                )
            }
        } catch (e: Exception) {
            AudioManager.AUDIOFOCUS_REQUEST_FAILED
        }
        hasFocus = (granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
        if (hasFocus) {
            currentFocusGain = targetGain
        }
    }

    @Suppress("DEPRECATION")
    private fun abandonFocus() {
        main.removeCallbacks(delayedAbandon)
        restoreCriticalFloor() // before ownAudioEnd: the guard expects the volume it put back
        if (ownAudioHeld) {
            ownAudioHeld = false
            volumeGuard.ownAudioEnd(false)
        }
        if (!hasFocus) return
        hasFocus = false
        currentFocusGain = 0
        main.removeCallbacks(safetyFocusWatchdog)
        val am = audio ?: return
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                val request = focusRequest as? AudioFocusRequest
                if (request != null) am.abandonAudioFocusRequest(request)
            } else {
                am.abandonAudioFocus(focusListener)
            }
        } catch (e: Exception) {
            // ignore
        }
    }

    companion object {
        private const val MAX_CHARS = 300
        private const val INIT_TIMEOUT_MS = 8000L

        /** Focus is kept this long after the last line, so a burst of lines is one duck. */
        private const val FOCUS_GRACE_MS = 700L

        /** 3.55: a critical line in the helmet / earbuds plays at least at this share of max media volume. */
        private const val CRITICAL_HEADSET_MIN_FRACTION = 0.6

        /** How long an after-call line waits for the phone to leave call mode. */
        private const val AFTER_CALL_WAIT_MS = 4000L
    }
}
