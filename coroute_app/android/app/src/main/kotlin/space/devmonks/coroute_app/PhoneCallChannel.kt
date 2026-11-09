package space.devmonks.coroute_app

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Phone call state for rider safety (MethodChannel "coroute/phone_call", EventChannel
 * "coroute/phone_call_events"): {state: IDLE | RINGING | OFFHOOK, isCallActive}.
 *
 * Used to pause the intercom mic during calls (private calls never go to the convoy), to hold
 * ordinary spoken lines and to send critical ones through the call audio (3.55 call-aware alerts).
 *
 * Sources (3.55 fix: the app has no READ_PHONE_STATE, so the telephony listener alone never fired):
 *  - the audio mode (no permission; also catches WhatsApp / VoIP calls): Android 12+ listens to mode
 *    changes, older phones read it every [POLL_MS] while Dart listens;
 *  - the telephony call state when READ_PHONE_STATE happens to be granted (adds early RINGING).
 * The state is the stronger of the two. MODE_IN_COMMUNICATION set by CoRoute itself (an intercom
 * voice-call link) is ignored when Dart says so (setOwnCommunication), so the intercom is never taken
 * for a phone call. CoRoute never answers, declines or ends a call.
 */
class PhoneCallChannel(private val context: Context) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        /** True while CoRoute's own audio (intercom) holds MODE_IN_COMMUNICATION. Read by TtsChannel. */
        @Volatile
        var ownCommunicationMode: Boolean = false

        private const val POLL_MS = 1500L
    }

    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    private val telephonyManager = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var eventSink: EventChannel.EventSink? = null
    private var isCallActive = false
    private var currentCallState = "IDLE" // IDLE, RINGING, OFFHOOK (what Dart was told last)
    private var telephonyState = "IDLE"

    private var telephonyCallback: Any? = null
    private var callReceiver: BroadcastReceiver? = null
    private var modeListener: Any? = null
    private var polling = false

    private val poll = object : Runnable {
        override fun run() {
            if (!polling) return
            refresh()
            mainHandler.postDelayed(this, POLL_MS)
        }
    }

    init {
        registerCallStateListener()
        registerModeListener()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getCallState" -> {
                val state = checkCurrentState()
                result.success(mapOf(
                    "state" to state,
                    "isCallActive" to (state != "IDLE")
                ))
            }
            "isAudioPlaying" -> {
                val isMusicActive = audioManager?.isMusicActive == true
                result.success(isMusicActive)
            }
            "setOwnCommunication" -> {
                ownCommunicationMode = call.argument<Boolean>("active") == true
                refresh()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        val state = checkCurrentState()
        currentCallState = state
        isCallActive = state != "IDLE"
        events?.success(mapOf(
            "state" to state,
            "isCallActive" to (state != "IDLE")
        ))
        startPollingIfNeeded()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        stopPolling()
    }

    private fun modeState(): String {
        val amMode = audioManager?.mode ?: AudioManager.MODE_NORMAL
        if (amMode == AudioManager.MODE_IN_COMMUNICATION && ownCommunicationMode) return "IDLE"
        if (amMode == AudioManager.MODE_IN_CALL || amMode == AudioManager.MODE_IN_COMMUNICATION) return "OFFHOOK"
        if (Build.VERSION.SDK_INT >= 30 && amMode == AudioManager.MODE_CALL_SCREENING) return "RINGING"
        if (amMode == AudioManager.MODE_RINGTONE) return "RINGING"
        return "IDLE"
    }

    /** The stronger of the audio mode and the telephony state (OFFHOOK > RINGING > IDLE). */
    private fun checkCurrentState(): String {
        val a = modeState()
        val t = telephonyState
        return when {
            a == "OFFHOOK" || t == "OFFHOOK" -> "OFFHOOK"
            a == "RINGING" || t == "RINGING" -> "RINGING"
            else -> "IDLE"
        }
    }

    private fun refresh() {
        updateState(checkCurrentState())
    }

    private fun updateState(newState: String) {
        if (currentCallState == newState) return
        currentCallState = newState
        isCallActive = newState != "IDLE"
        mainHandler.post {
            eventSink?.success(mapOf(
                "state" to currentCallState,
                "isCallActive" to isCallActive
            ))
        }
    }

    private fun hasPhoneStatePermission(): Boolean = try {
        context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED
    } catch (e: Exception) {
        false
    }

    private fun telephonyStateFrom(state: Int): String = when (state) {
        TelephonyManager.CALL_STATE_RINGING -> "RINGING"
        TelephonyManager.CALL_STATE_OFFHOOK -> "OFFHOOK"
        else -> "IDLE"
    }

    @Suppress("DEPRECATION")
    private fun registerCallStateListener() {
        if (!hasPhoneStatePermission()) return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && telephonyManager != null) {
                val callback = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                    override fun onCallStateChanged(state: Int) {
                        telephonyState = telephonyStateFrom(state)
                        refresh()
                    }
                }
                telephonyManager.registerTelephonyCallback(context.mainExecutor, callback)
                telephonyCallback = callback
            } else {
                val receiver = object : BroadcastReceiver() {
                    override fun onReceive(ctx: Context?, intent: Intent?) {
                        if (intent?.action == TelephonyManager.ACTION_PHONE_STATE_CHANGED) {
                            telephonyState = when (intent.getStringExtra(TelephonyManager.EXTRA_STATE)) {
                                TelephonyManager.EXTRA_STATE_RINGING -> "RINGING"
                                TelephonyManager.EXTRA_STATE_OFFHOOK -> "OFFHOOK"
                                else -> "IDLE"
                            }
                            refresh()
                        }
                    }
                }
                context.registerReceiver(receiver, IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED))
                callReceiver = receiver
            }
        } catch (e: Exception) {
            // SecurityException etc.: the audio mode below still works
        }
    }

    /** Android 12+: audio mode changes without any permission (cellular and VoIP calls). */
    private fun registerModeListener() {
        if (Build.VERSION.SDK_INT < 31) return
        val am = audioManager ?: return
        try {
            val listener = AudioManager.OnModeChangedListener { _ -> mainHandler.post { refresh() } }
            am.addOnModeChangedListener(context.mainExecutor, listener)
            modeListener = listener
        } catch (e: Exception) {
            modeListener = null
        }
    }

    /** Older phones (or no mode listener): read the audio mode while Dart listens. */
    private fun startPollingIfNeeded() {
        if (modeListener != null || polling) return
        polling = true
        mainHandler.postDelayed(poll, POLL_MS)
    }

    private fun stopPolling() {
        polling = false
        mainHandler.removeCallbacks(poll)
    }

    fun dispose() {
        stopPolling()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && telephonyManager != null && telephonyCallback != null) {
                (telephonyCallback as? TelephonyCallback)?.let {
                    telephonyManager.unregisterTelephonyCallback(it)
                }
            } else if (callReceiver != null) {
                context.unregisterReceiver(callReceiver)
            }
        } catch (e: Exception) {}
        telephonyCallback = null
        callReceiver = null
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                (modeListener as? AudioManager.OnModeChangedListener)?.let { audioManager?.removeOnModeChangedListener(it) }
            }
        } catch (e: Exception) {}
        modeListener = null
    }
}
