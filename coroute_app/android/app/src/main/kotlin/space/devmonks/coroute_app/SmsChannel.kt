package space.devmonks.coroute_app

import android.Manifest
import android.app.Activity
import android.app.KeyguardManager
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
 *
 * 3.56: launchSmsIntent from the SOS screen shown over the lock screen asks the system to unlock
 * first (KeyguardManager.requestDismissKeyguard on [activity]); after the unlock the messages app
 * opens with every contact and the text filled in. Cancelled: answers false (the rider can tap
 * "Text the group now" again). The messages app queues and retries the text itself when there is
 * no signal yet.
 *
 * 3.57 phone-first emergency texts (SEND_SMS declared, asked after an in-app disclosure):
 * - enqueue {jobs: [{id, incident, kind, to, body, notBefore}], retryMs} -> accepted ids
 * - cancelTexts {ids} -> null (jobs that have not left the phone)
 * - textStatuses -> [{id, kind, state, attempts, code, last3, updatedAt}]
 * - Dart gets "textStatus" [status...] on every change (set [events]).
 * The queue itself is [EmergencyTexts] (works without this channel: alarm, reports, boot).
 */
class SmsChannel(context: Context, private val activity: () -> Activity? = { null }) : MethodChannel.MethodCallHandler {
    private val app: Context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    private val sequence = AtomicInteger(0)

    /** The channel for "textStatus" calls back to Dart (MainActivity sets it). */
    var events: MethodChannel? = null

    private val textListener: (List<Map<String, Any>>) -> Unit = { list ->
        main.post {
            try {
                events?.invokeMethod("textStatus", list)
            } catch (e: Exception) {
                // the engine is gone; Dart reads textStatuses at the next start
            }
        }
    }

    init {
        EmergencyTexts.listener = textListener
        EmergencyTexts.tick(app) // resumes texts left from before an app kill
    }

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
            "enqueue" -> {
                val jobs = call.argument<List<Any?>>("jobs").orEmpty().filterIsInstance<Map<*, *>>()
                val retry = call.argument<List<Any?>>("retryMs").orEmpty().mapNotNull { (it as? Number)?.toLong() }
                EmergencyTexts.enqueue(app, jobs, retry) { ids -> main.post { result.success(ids) } }
            }
            "cancelTexts" -> {
                val ids = call.argument<List<Any?>>("ids").orEmpty().mapNotNull { it as? String }
                EmergencyTexts.cancel(app, ids) { main.post { result.success(null) } }
            }
            "textStatuses" -> EmergencyTexts.statuses(app) { list -> main.post { result.success(list) } }
            "launchSmsIntent" -> {
                val body = call.argument<String>("body").orEmpty()
                // Several people at once (emergency texts without SEND_SMS): the rider or a
                // bystander only has to press Send in the messages app.
                val list = call.argument<List<String>>("toList")
                val to = if (!list.isNullOrEmpty()) {
                    val sep = if ((Build.MANUFACTURER ?: "").lowercase().contains("samsung")) "," else ";"
                    list.map { it.replace(Regex("[^0-9+]"), "") }.filter { it.isNotEmpty() }.distinct().joinToString(sep)
                } else {
                    call.argument<String>("to")?.trim().orEmpty()
                }
                launchSmsIntent(to, body, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun launchSmsIntent(to: String, body: String, result: MethodChannel.Result) {
        val intent = try {
            val cleanTo = to.replace(Regex("[^0-9+;,]"), "")
            val uri = if (cleanTo.isNotEmpty()) android.net.Uri.parse("smsto:$cleanTo") else android.net.Uri.parse("smsto:")
            Intent(Intent.ACTION_SENDTO, uri).apply {
                if (body.isNotEmpty()) {
                    putExtra("sms_body", body)
                }
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        } catch (e: Exception) {
            result.success(false)
            return
        }
        val act = activity()
        val km = app.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        if (act != null && km != null && km.isKeyguardLocked && Build.VERSION.SDK_INT >= 26) {
            val answered = AtomicBoolean(false)
            fun answer(value: Boolean) {
                if (answered.compareAndSet(false, true)) result.success(value)
            }
            try {
                km.requestDismissKeyguard(act, object : KeyguardManager.KeyguardDismissCallback() {
                    override fun onDismissSucceeded() = answer(startComposer(intent))
                    override fun onDismissCancelled() = answer(false)
                    override fun onDismissError() = answer(startComposer(intent))
                })
            } catch (e: Exception) {
                answer(startComposer(intent))
            }
            return
        }
        result.success(startComposer(intent))
    }

    private fun startComposer(intent: Intent): Boolean = try {
        app.startActivity(intent)
        true
    } catch (e: Exception) {
        false
    }

    fun dispose() {
        worker.shutdown()
        events = null
        if (EmergencyTexts.listener === textListener) EmergencyTexts.listener = null
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
