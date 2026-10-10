package space.devmonks.coroute_app

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * Emergency texts sent by the rider's own phone when an SOS cannot reach the
 * group over the internet (MethodChannel "coroute/sms").
 *
 * - capability -> {hasTelephony, permission, simReady} (no READ_PHONE_STATE needed)
 * - send {to, body} -> {status: SENT | FAILED | NO_SERVICE | NO_PERMISSION | TIMEOUT, code?}
 *
 * Uses the default SMS SIM (then the default SIM, then the system default),
 * splits long texts into parts, and answers after the last part's sent report
 * or after 20 s. The send itself runs off the main thread. Phone numbers and
 * text are never logged.
 */
class SmsChannel(context: Context) : MethodChannel.MethodCallHandler {
    private val app: Context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    private val sequence = AtomicInteger(0)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capability" -> result.success(capability())
            "send" -> {
                val to = call.argument<String>("to")?.trim().orEmpty()
                val body = call.argument<String>("body").orEmpty()
                if (to.isEmpty() || body.isEmpty()) {
                    result.success(mapOf("status" to "FAILED", "code" to -2))
                    return
                }
                send(to, body, result)
            }
            "launchSmsIntent" -> {
                val to = call.argument<String>("to")?.trim().orEmpty()
                val body = call.argument<String>("body").orEmpty()
                launchSmsIntent(to, body, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun launchSmsIntent(to: String, body: String, result: MethodChannel.Result) {
        try {
            val cleanTo = to.replace(Regex("[^0-9+]"), "")
            val uri = if (cleanTo.isNotEmpty()) android.net.Uri.parse("smsto:$cleanTo") else android.net.Uri.parse("smsto:")
            val intent = Intent(Intent.ACTION_SENDTO, uri).apply {
                if (body.isNotEmpty()) {
                    putExtra("sms_body", body)
                }
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            app.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    fun dispose() {
        worker.shutdown()
    }

    private fun hasTelephony(): Boolean =
        app.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)

    private fun hasPermission(): Boolean =
        app.checkSelfPermission(Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED

    @Suppress("DEPRECATION")
    private fun simReady(): Boolean {
        val tm = app.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager ?: return false
        return try {
            if (Build.VERSION.SDK_INT >= 26) {
                val slots = if (Build.VERSION.SDK_INT >= 30) tm.activeModemCount else tm.phoneCount
                (0 until maxOf(slots, 1)).any { tm.getSimState(it) == TelephonyManager.SIM_STATE_READY }
            } else {
                tm.simState == TelephonyManager.SIM_STATE_READY
            }
        } catch (e: Exception) {
            tm.simState == TelephonyManager.SIM_STATE_READY
        }
    }

    private fun capability(): Map<String, Boolean> {
        val telephony = hasTelephony()
        return mapOf(
            "hasTelephony" to telephony,
            "permission" to hasPermission(),
            "simReady" to (telephony && simReady()),
        )
    }

    private fun subscriptionId(): Int {
        var id = SubscriptionManager.getDefaultSmsSubscriptionId()
        if (id == SubscriptionManager.INVALID_SUBSCRIPTION_ID && Build.VERSION.SDK_INT >= 24) {
            id = SubscriptionManager.getDefaultSubscriptionId()
        }
        return id
    }

    @Suppress("DEPRECATION")
    private fun smsManager(): SmsManager? {
        val id = subscriptionId()
        return if (Build.VERSION.SDK_INT >= 31) {
            val base = app.getSystemService(SmsManager::class.java) ?: return null
            if (id != SubscriptionManager.INVALID_SUBSCRIPTION_ID) base.createForSubscriptionId(id) else base
        } else {
            if (id != SubscriptionManager.INVALID_SUBSCRIPTION_ID) SmsManager.getSmsManagerForSubscriptionId(id) else SmsManager.getDefault()
        }
    }

    private fun send(to: String, body: String, result: MethodChannel.Result) {
        if (!hasTelephony()) {
            result.success(mapOf("status" to "NO_SERVICE", "code" to -3))
            return
        }
        if (!hasPermission()) {
            result.success(mapOf("status" to "NO_PERMISSION"))
            return
        }
        val done = AtomicBoolean(false)
        val action = app.packageName + ".EMERGENCY_SMS_SENT." + sequence.incrementAndGet()
        val receiver = AtomicReference<BroadcastReceiver?>(null)
        val timeout = AtomicReference<Runnable?>(null)

        fun finish(status: String, code: Int?) {
            if (!done.compareAndSet(false, true)) return
            main.post {
                receiver.get()?.let {
                    try {
                        app.unregisterReceiver(it)
                    } catch (e: Exception) {
                        // already gone
                    }
                }
                timeout.get()?.let { main.removeCallbacks(it) }
                val answer = HashMap<String, Any>()
                answer["status"] = status
                if (code != null) answer["code"] = code
                result.success(answer)
            }
        }

        try {
            worker.execute {
                try {
                    val manager = smsManager()
                    if (manager == null) {
                        finish("FAILED", -4)
                        return@execute
                    }
                    val parts = manager.divideMessage(body)
                    if (parts == null || parts.isEmpty()) {
                        finish("FAILED", -2)
                        return@execute
                    }
                    val expected = parts.size
                    val received = AtomicInteger(0)
                    var firstError = 0
                    val r = object : BroadcastReceiver() {
                        override fun onReceive(context: Context, intent: Intent) {
                            val code = resultCode
                            if (code != Activity.RESULT_OK && firstError == 0) firstError = code
                            if (received.incrementAndGet() >= expected) {
                                when (firstError) {
                                    0 -> finish("SENT", null)
                                    SmsManager.RESULT_ERROR_NO_SERVICE, SmsManager.RESULT_ERROR_RADIO_OFF -> finish("NO_SERVICE", firstError)
                                    else -> finish("FAILED", firstError)
                                }
                            }
                        }
                    }
                    receiver.set(r)
                    val filter = IntentFilter(action)
                    if (Build.VERSION.SDK_INT >= 33) {
                        app.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
                    } else {
                        app.registerReceiver(r, filter)
                    }
                    val sentIntents = ArrayList<PendingIntent>(expected)
                    for (i in 0 until expected) {
                        val intent = Intent(action).setPackage(app.packageName).putExtra("part", i)
                        sentIntents.add(
                            PendingIntent.getBroadcast(
                                app,
                                i,
                                intent,
                                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT,
                            )
                        )
                    }
                    val t = Runnable { finish("TIMEOUT", null) }
                    timeout.set(t)
                    main.postDelayed(t, SEND_TIMEOUT_MS)
                    manager.sendMultipartTextMessage(to, null, parts, sentIntents, null)
                } catch (e: SecurityException) {
                    finish("NO_PERMISSION", null)
                } catch (e: Exception) {
                    finish("FAILED", -1)
                }
            }
        } catch (e: Exception) {
            // The worker was shut down (the screen's engine is going away).
            finish("FAILED", -5)
        }
    }

    private companion object {
        const val SEND_TIMEOUT_MS = 20_000L
    }
}
