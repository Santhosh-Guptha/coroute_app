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
 * - init -> {ok, language}: binds the engine (lazily, on the first alert of a ride) and
 *   picks Indian English, else US / UK / any English. ok=false when there is no engine
 *   or no English voice (the app then stays silent; banners still show).
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
    private val waiting = ArrayList<MethodChannel.Result>()

    /** Utterances handed to the engine and not finished yet (main thread only). */
    private val active = HashSet<String>()
    private var hasFocus = false

    /** Bumped by release, so a late init callback of an old engine is ignored. */
    private var generation = 0

    /** AudioFocusRequest on Android 8+ (kept as Any so older phones never load the class). */
    private var focusRequest: Any? = null

    private val attributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    // Phrases are short: a focus loss just lets the engine finish or be stopped by the app.
    private val focusListener = AudioManager.OnAudioFocusChangeListener { }

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
            "init" -> init(result)
            "speak" -> {
                val text = (call.argument<String>("text") ?: "").take(MAX_CHARS)
                val id = call.argument<String>("id") ?: "coroute"
                val interrupt = call.argument<Boolean>("interrupt") == true
                result.success(speak(text, id, interrupt))
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

    /** Indian English first (familiar place names and numbers), then other English voices. */
    private fun chooseLanguage(engine: TextToSpeech): Boolean {
        val candidates = listOf(
            Locale.Builder().setLanguage("en").setRegion("IN").build(),
            Locale.US,
            Locale.UK,
            Locale.ENGLISH,
        )
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

    private fun speak(text: String, id: String, interrupt: Boolean): Boolean {
        val engine = tts
        if (!ready || !ok || engine == null || text.isBlank()) return false
        requestFocus()
        if (interrupt) active.clear() // the flushed ones report onStop; nothing waits for them
        val code = try {
            engine.speak(text, if (interrupt) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD, Bundle(), id)
        } catch (e: Exception) {
            TextToSpeech.ERROR
        }
        if (code == TextToSpeech.SUCCESS) {
            active.add(id)
            return true
        }
        if (active.isEmpty()) abandonFocus()
        return false
    }

    private fun finished(id: String?) {
        if (id != null) active.remove(id)
        if (active.isEmpty()) abandonFocus()
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
    private fun requestFocus() {
        if (hasFocus) return
        val am = audio ?: return
        val granted = try {
            if (Build.VERSION.SDK_INT >= 26) {
                val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                    .setAudioAttributes(attributes)
                    .setOnAudioFocusChangeListener(focusListener)
                    .build()
                focusRequest = request
                am.requestAudioFocus(request)
            } else {
                am.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            }
        } catch (e: Exception) {
            AudioManager.AUDIOFOCUS_REQUEST_FAILED
        }
        // Speak even without focus (an alert matters more than the music); only remember a grant.
        hasFocus = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    @Suppress("DEPRECATION")
    private fun abandonFocus() {
        if (!hasFocus) return
        hasFocus = false
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
