package space.devmonks.coroute_app

import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 3.55 push notifications (docs/features_355/push_notifications.md).
 *
 * The Firebase client values are injected at build time (android/app/build.gradle.kts reads
 * COROUTE_FCM_APP_ID / COROUTE_FCM_API_KEY / COROUTE_FCM_PROJECT_ID / COROUTE_FCM_SENDER_ID from
 * gradle properties or the environment). No google-services.json, no google-services plugin.
 * Without the values push is off: FirebaseApp is never initialised and Dart sees available=false.
 */
object PushConfig {
    /** True when the default FirebaseApp exists (created here from the build values if needed). */
    fun ensureInit(context: Context): Boolean {
        try {
            if (FirebaseApp.getApps(context).isNotEmpty()) return true
            val appId = context.getString(R.string.coroute_fcm_app_id).trim()
            val apiKey = context.getString(R.string.coroute_fcm_api_key).trim()
            val projectId = context.getString(R.string.coroute_fcm_project_id).trim()
            val senderId = context.getString(R.string.coroute_fcm_sender_id).trim()
            if (appId.isEmpty() || apiKey.isEmpty() || projectId.isEmpty() || senderId.isEmpty()) return false
            val options = FirebaseOptions.Builder()
                .setApplicationId(appId)
                .setApiKey(apiKey)
                .setProjectId(projectId)
                .setGcmSenderId(senderId)
                .build()
            FirebaseApp.initializeApp(context.applicationContext, options)
            return true
        } catch (t: Throwable) {
            // A bad value never crashes the app: push simply stays off.
            return false
        }
    }

    private const val PREFS = "coroute_push"
    private const val KEY_ENABLED = "enabled"

    /** The rider's "Push notifications" switch (mirrored here so the service can honour it). */
    fun isEnabled(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ENABLED, true)

    fun setEnabled(context: Context, on: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_ENABLED, on).apply()
    }
}

/**
 * MethodChannel "coroute/push".
 *
 * Dart -> Android: isAvailable, getToken, deleteToken, setEnabled {on}, takeLaunchMessage,
 * notificationsEnabled.
 * Android -> Dart (invokeMethod): onToken {token}, onMessage {data map} (app in front: no system
 * notification is shown), onMessageOpened {type, payload} (a push notification was tapped while
 * the app was running; a cold start is read with takeLaunchMessage).
 */
class PushChannel(activity: Activity, private val channel: MethodChannel) : MethodChannel.MethodCallHandler {

    companion object {
        const val EXTRA_MARK = "coroute_push"
        const val EXTRA_TYPE = "pushType"
        const val EXTRA_PAYLOAD = "payload"

        /** The channel of the live Flutter screen, or null (app closed / engine gone). */
        @Volatile
        var active: PushChannel? = null

        /** MainActivity is resumed (set in onResume / onPause). */
        @Volatile
        var foreground: Boolean = false
    }

    private val app: Context = activity.applicationContext
    private val main = Handler(Looper.getMainLooper())

    /** A tapped push notification that started the activity before Dart was listening. */
    @Volatile
    private var pendingLaunch: Map<String, String>? = null

    fun register() {
        active = this
    }

    fun dispose() {
        if (active === this) active = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(PushConfig.ensureInit(app))
            "getToken" -> getToken(result)
            "deleteToken" -> deleteToken(result)
            "setEnabled" -> {
                val on = call.argument<Boolean>("on") != false
                PushConfig.setEnabled(app, on)
                if (PushConfig.ensureInit(app)) {
                    try {
                        FirebaseMessaging.getInstance().isAutoInitEnabled = on
                    } catch (_: Throwable) {
                    }
                }
                result.success(null)
            }
            "takeLaunchMessage" -> {
                val m = pendingLaunch
                pendingLaunch = null
                result.success(m)
            }
            "notificationsEnabled" -> result.success(notificationsEnabled())
            else -> result.notImplemented()
        }
    }

    private fun getToken(result: MethodChannel.Result) {
        if (!PushConfig.ensureInit(app)) {
            result.success(null)
            return
        }
        try {
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                val token = if (task.isSuccessful) task.result else null
                main.post { result.success(token) }
            }
        } catch (t: Throwable) {
            result.success(null)
        }
    }

    private fun deleteToken(result: MethodChannel.Result) {
        if (!PushConfig.ensureInit(app)) {
            result.success(false)
            return
        }
        try {
            FirebaseMessaging.getInstance().deleteToken().addOnCompleteListener { task ->
                val ok = task.isSuccessful
                main.post { result.success(ok) }
            }
        } catch (t: Throwable) {
            result.success(false)
        }
    }

    private fun notificationsEnabled(): Boolean {
        val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return false
        return if (Build.VERSION.SDK_INT >= 24) nm.areNotificationsEnabled() else true
    }

    /** MainActivity.onCreate (coldStart) / onNewIntent: a tapped push notification. */
    fun handleActivityIntent(intent: Intent?, coldStart: Boolean) {
        if (intent == null || !intent.getBooleanExtra(EXTRA_MARK, false)) return
        val type = intent.getStringExtra(EXTRA_TYPE) ?: return
        val payload = intent.getStringExtra(EXTRA_PAYLOAD) ?: "{}"
        // Taken once: a configuration change or a recreated activity does not open it again.
        intent.removeExtra(EXTRA_MARK)
        intent.removeExtra(EXTRA_TYPE)
        intent.removeExtra(EXTRA_PAYLOAD)
        val m = mapOf("type" to type, "payload" to payload)
        if (coldStart) {
            pendingLaunch = m
        } else {
            main.post { channel.invokeMethod("onMessageOpened", m) }
        }
    }

    /** CoRouteMessagingService: a new FCM token (Dart registers it with the gateway). */
    fun deliverToken(token: String) {
        main.post { channel.invokeMethod("onToken", mapOf("token" to token)) }
    }

    /** CoRouteMessagingService: a data message while the app is in front. */
    fun deliverForeground(data: Map<String, String>) {
        val copy = HashMap(data)
        main.post { channel.invokeMethod("onMessage", copy) }
    }
}
