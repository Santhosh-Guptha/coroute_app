package space.devmonks.coroute_app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
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
 * - speak {text, id, interrupt} -> Boolean: QUEUE_FLUSH when interrupt, else QUEUE_ADD.
 *   Audio usage "navigation guidance" (goes to a Bluetooth helmet set like map directions),
 *   transient focus that ducks music and the intercom, released when the queue is empty.
 * - stop, release (unbinds the engine at ride end).
 * Text is cut to 300 characters and never logged.
 */
class TtsChannel(context: Context) : MethodChannel.MethodCallHandler {
    private val app: Context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val audio: AudioManager? = app.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    private var tts: TextToSpeech? = null
    private var ready = false
    private var ok = false
    private var language = ""
    private var requested = ""
    private val waiting = ArrayList<MethodChannel.Result>()

    /** Utterances handed to the engine and not finished yet (main thread only). */
    private val active = HashSet<String>()
    private var hasFocus = false
    private var currentFocusGain = 0

    /** Watchdog to ensure audio focus is never leaked if the TTS engine hangs or crashes. */
    private val safetyFocusWatchdog = Runnable {
        if (hasFocus && active.isNotEmpty()) {
            active.clear()
            abandonFocus()
        }
    }

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

    private val attributes: AudioAttributes = guidanceAttributes

    // Transient interruptions (calls, tones) duck audio focus without terminating the engine.
    private val focusListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        when (focusChange) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                hasFocus = false
                currentFocusGain = 0
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
                result.success(speak(text, id, interrupt, isEmergency, pauseOthers))
            }
            "requestEmergencyFocus" -> {
                requestFocus(isEmergency = true)
                result.success(hasFocus)
            }
            "abandonEmergencyFocus" -> {
                abandonFocus()
                result.success(null)
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
        return amMode == AudioManager.MODE_IN_CALL ||
               amMode == AudioManager.MODE_IN_COMMUNICATION ||
               amMode == AudioManager.MODE_RINGTONE
    }

    private fun speak(text: String, id: String, interrupt: Boolean, isEmergency: Boolean = false, pauseOthers: Boolean = false): Boolean {
        val engine = tts
        if (!ready || !ok || engine == null || text.isBlank()) return false
        // Do not interfere with phone calls unless it is a genuine emergency alert
        if (isInPhoneCall() && !isEmergency) return false

        // ALWAYS request audio focus so background audio (Spotify, podcasts, music)
        // is ducked (lowered to quiet background) or paused during spoken alerts,
        // making speed warnings, hazard cues and guidance loud, distinct and audible!
        requestFocus(isEmergency = isEmergency, pauseOthers = pauseOthers)

        if (interrupt) active.clear() // the flushed ones report onStop; nothing waits for them

        try {
            engine.setAudioAttributes(if (isEmergency) emergencyAttributes else guidanceAttributes)
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
            main.removeCallbacks(safetyFocusWatchdog)
            main.postDelayed(safetyFocusWatchdog, 25000L)
            return true
        }
        if (active.isEmpty()) abandonFocus()
        return false
    }

    private fun finished(id: String?) {
        if (id != null) active.remove(id)
        if (active.isEmpty()) {
            abandonFocus()
        }
    }

    private fun stop() {
        try {
            tts?.stop()
        } catch (e: Exception) {
            // ignore
        }
        active.clear()
        abandonFocus()
    }

    /** Ride end: unbind the engine (it is started again by the next alert). */
    fun release() {
        generation++
        main.removeCallbacks(initTimeout)
        try {
            tts?.stop()
            tts?.shutdown()
        } catch (e: Exception) {
            // ignore
        }
        tts = null
        active.clear()
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

        val targetAttributes = if (isEmergency) emergencyAttributes else guidanceAttributes

        val granted = try {
            if (Build.VERSION.SDK_INT >= 26) {
                val request = AudioFocusRequest.Builder(targetGain)
                    .setAudioAttributes(targetAttributes)
                    .setOnAudioFocusChangeListener(focusListener)
                    .setWillPauseWhenDucked(true)
                    .build()
                focusRequest = request
                am.requestAudioFocus(request)
            } else {
                am.requestAudioFocus(
                    focusListener,
                    if (isEmergency) AudioManager.STREAM_ALARM else AudioManager.STREAM_MUSIC,
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
    }
}
