package space.devmonks.coroute_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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
 * Manages phone call and audio focus interruption state for motorcycle rider safety.
 *
 * Detects incoming calls (RINGING) and active calls (OFFHOOK / IN_COMMUNICATION)
 * to safely pause intercom mic recording (preventing broadcasting private phone calls to the convoy)
 * and prioritize emergency audio / haptics during active calls.
 */
class PhoneCallChannel(private val context: Context) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    private val telephonyManager = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var eventSink: EventChannel.EventSink? = null
    private var isCallActive = false
    private var currentCallState = "IDLE" // IDLE, RINGING, OFFHOOK

    private var telephonyCallback: Any? = null
    private var callReceiver: BroadcastReceiver? = null

    init {
        registerCallStateListener()
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
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        val state = checkCurrentState()
        events?.success(mapOf(
            "state" to state,
            "isCallActive" to (state != "IDLE")
        ))
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun checkCurrentState(): String {
        val amMode = audioManager?.mode ?: AudioManager.MODE_NORMAL
        if (amMode == AudioManager.MODE_IN_CALL || amMode == AudioManager.MODE_IN_COMMUNICATION) {
            return "OFFHOOK"
        } else if (amMode == AudioManager.MODE_RINGTONE) {
            return "RINGING"
        }
        return currentCallState
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

    @Suppress("DEPRECATION")
    private fun registerCallStateListener() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && telephonyManager != null) {
                val callback = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                    override fun onCallStateChanged(state: Int) {
                        val stateStr = when (state) {
                            TelephonyManager.CALL_STATE_RINGING -> "RINGING"
                            TelephonyManager.CALL_STATE_OFFHOOK -> "OFFHOOK"
                            else -> "IDLE"
                        }
                        updateState(stateStr)
                    }
                }
                telephonyCallback = callback
                context.mainExecutor.let { executor ->
                    telephonyManager.registerTelephonyCallback(executor, callback)
                }
            } else {
                val receiver = object : BroadcastReceiver() {
                    override fun onReceive(ctx: Context?, intent: Intent?) {
                        if (intent?.action == TelephonyManager.ACTION_PHONE_STATE_CHANGED) {
                            val stateExtra = intent.getStringExtra(TelephonyManager.EXTRA_STATE)
                            val stateStr = when (stateExtra) {
                                TelephonyManager.EXTRA_STATE_RINGING -> "RINGING"
                                TelephonyManager.EXTRA_STATE_OFFHOOK -> "OFFHOOK"
                                else -> "IDLE"
                            }
                            updateState(stateStr)
                        }
                    }
                }
                callReceiver = receiver
                val filter = IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED)
                context.registerReceiver(receiver, filter)
            }
        } catch (e: Exception) {
            // Fallback to AudioManager mode polling
        }
    }

    fun dispose() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && telephonyManager != null && telephonyCallback != null) {
                (telephonyCallback as? TelephonyCallback)?.let {
                    telephonyManager.unregisterTelephonyCallback(it)
                }
            } else if (callReceiver != null) {
                context.unregisterReceiver(callReceiver)
            }
        } catch (e: Exception) {}
    }
}
