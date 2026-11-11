package space.devmonks.coroute_app

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkRequest
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * 3.57 phone-first emergency texts: the queue that sends the rider's SOS / "safe now" / test texts
 * from their own SIM without a tap, also with the screen locked, the app in the background or the
 * process restarted (docs/features_355/sos_sms.md, "Phone-first").
 *
 * Dart (SafetyService + EmergencyTextLedger) decides who, what and when and hands over jobs
 * {id, kind, to, body, notBefore} with the retry delays. This queue:
 * - keeps the jobs in its own SharedPreferences file (committed before sending), so an app kill
 *   or a reboot does not lose them; a known id is ignored (dedupe per incident);
 * - sends each job once `notBefore` has passed (the grace window in which a cancel stops it),
 *   one text per contact, split into parts when needed, from the default SMS SIM (then the default
 *   SIM, then the system default; no READ_PHONE_STATE, so no SIM listing);
 * - gets a sent and a delivered report per part through [EmergencyTextReceiver] (explicit
 *   broadcasts, FLAG_IMMUTABLE, a unique request code per part), so reports arrive even after the
 *   process was restarted;
 * - retries NO_SERVICE / RADIO_OFF / GENERIC_FAILURE (and a missing report after 3 min) with the
 *   given delays (30 s, 2 min, 5 min, 10 min), woken by a Handler while the process lives, by an
 *   inexact AlarmManager alarm (setAndAllowWhileIdle, no extra permission) otherwise, and at once
 *   (after 3 s) when a network comes back (ConnectivityManager, ACCESS_NETWORK_STATE only);
 * - reports every state change to the listener (SmsChannel -> Dart "textStatus").
 *
 * Privacy: numbers and text stay in the private prefs file until 48 h after the job finished and
 * never go to Logcat or to Dart; statuses carry only the last 3 digits.
 */
object EmergencyTexts {
    private const val TAG = "CoRouteTexts"
    private const val PREFS = "coroute_emergency_texts"
    private const val KEY_JOBS = "jobs"
    private const val KEY_REQ = "req"
    const val ACTION_SENT = "space.devmonks.coroute_app.EMERGENCY_TEXT_SENT"
    const val ACTION_DELIVERED = "space.devmonks.coroute_app.EMERGENCY_TEXT_DELIVERED"
    const val ACTION_TICK = "space.devmonks.coroute_app.EMERGENCY_TEXT_TICK"
    const val EXTRA_ID = "id"
    const val EXTRA_ATTEMPT = "attempt"
    const val EXTRA_PART = "part"

    private const val REPORT_TIMEOUT_MS = 180_000L
    private const val KEEP_FINISHED_MS = 48L * 3600_000L
    private const val NETWORK_DEBOUNCE_MS = 3_000L
    private const val MAX_JOBS = 100
    private const val TICK_REQUEST_CODE = 0x5E57
    private const val REQ_BASE = 0x5E58
    private const val REQ_SPAN = 1_000_000

    // Mirrors EmergencyTextPolicy (lib/domain/safety/emergency_texts.dart).
    const val ERROR_GENERIC = 1 // SmsManager.RESULT_ERROR_GENERIC_FAILURE
    const val ERROR_RADIO_OFF = 2 // SmsManager.RESULT_ERROR_RADIO_OFF
    const val ERROR_NO_SERVICE = 4 // SmsManager.RESULT_ERROR_NO_SERVICE
    const val ERROR_TIMEOUT = -100
    const val ERROR_NO_PERMISSION = -10
    const val ERROR_NO_TELEPHONY = -3
    const val ERROR_NO_MANAGER = -4
    const val ERROR_EMPTY = -2

    private const val QUEUED = "QUEUED"
    private const val SENDING = "SENDING"
    private const val SENT = "SENT"
    private const val DELIVERED = "DELIVERED"
    private const val FAILED = "FAILED"
    private const val CANCELLED = "CANCELLED"

    private val thread: HandlerThread by lazy { HandlerThread("coroute-texts").apply { start() } }
    private val handler: Handler by lazy { Handler(thread.looper) }

    @Volatile private var app: Context? = null

    /** State changes (status maps without numbers). Called on the queue thread. */
    @Volatile var listener: ((List<Map<String, Any>>) -> Unit)? = null

    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val tickRunnable = Runnable { tickNow() }
    private val networkRunnable = Runnable { retryWaitingNow() }

    private fun attach(context: Context): Context {
        val a = app ?: context.applicationContext.also { app = it }
        return a
    }

    // ------------------------------------------------------------------ entry points

    /** Adds jobs (known ids are skipped) and answers the accepted ids on the queue thread. */
    fun enqueue(context: Context, jobs: List<Map<*, *>>, retryMs: List<Long>, done: (List<String>) -> Unit) {
        val ctx = attach(context)
        handler.post {
            val accepted = ArrayList<String>()
            try {
                val list = load(ctx)
                val known = HashSet<String>()
                for (i in 0 until list.length()) list.optJSONObject(i)?.optString("id")?.let { known.add(it) }
                val now = System.currentTimeMillis()
                val retry = JSONArray()
                for (ms in retryMs) if (ms > 0) retry.put(ms)
                for (j in jobs) {
                    val id = (j["id"] as? String).orEmpty()
                    val to = (j["to"] as? String).orEmpty().replace(Regex("[^0-9+]"), "")
                    val body = (j["body"] as? String).orEmpty()
                    if (id.isEmpty() || to.isEmpty() || body.isEmpty() || !known.add(id)) continue
                    val notBefore = (j["notBefore"] as? Number)?.toLong() ?: now
                    val o = JSONObject()
                    o.put("id", id)
                    o.put("kind", (j["kind"] as? String).orEmpty())
                    o.put("to", to)
                    o.put("body", body)
                    o.put("notBefore", notBefore)
                    o.put("nextAt", 0L)
                    o.put("state", QUEUED)
                    o.put("attempts", 0)
                    o.put("code", 0)
                    o.put("retry", retry)
                    o.put("updatedAt", now)
                    list.put(o)
                    accepted.add(id)
                }
                save(ctx, trim(list))
            } catch (e: Exception) {
                Log.w(TAG, "enqueue failed: ${e.javaClass.simpleName}")
            }
            done(accepted)
            tickNow()
        }
    }

    /** Cancels jobs that have not left the phone (QUEUED only). */
    fun cancel(context: Context, ids: List<String>, done: () -> Unit) {
        val ctx = attach(context)
        handler.post {
            try {
                val list = load(ctx)
                val wanted = ids.toHashSet()
                val changed = ArrayList<JSONObject>()
                val now = System.currentTimeMillis()
                for (i in 0 until list.length()) {
                    val o = list.optJSONObject(i) ?: continue
                    if (o.optString("id") in wanted && o.optString("state") == QUEUED) {
                        o.put("state", CANCELLED)
                        o.put("updatedAt", now)
                        changed.add(o)
                    }
                }
                if (changed.isNotEmpty()) {
                    save(ctx, list)
                    notifyChanged(changed)
                }
            } catch (e: Exception) {
                Log.w(TAG, "cancel failed: ${e.javaClass.simpleName}")
            }
            done()
            tickNow()
        }
    }

    /** Every job's status (no numbers, no text). */
    fun statuses(context: Context, done: (List<Map<String, Any>>) -> Unit) {
        val ctx = attach(context)
        handler.post {
            val out = ArrayList<Map<String, Any>>()
            try {
                val list = load(ctx)
                for (i in 0 until list.length()) list.optJSONObject(i)?.let { out.add(statusOf(it)) }
            } catch (e: Exception) {
                Log.w(TAG, "status failed: ${e.javaClass.simpleName}")
            }
            done(out)
        }
    }

    /** Sends what is due and plans the next wake-up (app start, alarm, boot). */
    fun tick(context: Context, done: (() -> Unit)? = null) {
        attach(context)
        handler.post {
            tickNow()
            done?.invoke()
        }
    }

    /** A sent or delivered report for one part of one try. */
    fun onReport(context: Context, action: String, id: String, attempt: Int, resultCode: Int, done: () -> Unit) {
        val ctx = attach(context)
        handler.post {
            try {
                handleReport(ctx, action, id, attempt, resultCode)
            } catch (e: Exception) {
                Log.w(TAG, "report failed: ${e.javaClass.simpleName}")
            }
            done()
        }
    }

    // ------------------------------------------------------------------ queue thread only

    private fun prefs(ctx: Context): SharedPreferences = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun load(ctx: Context): JSONArray = try {
        JSONArray(prefs(ctx).getString(KEY_JOBS, "[]") ?: "[]")
    } catch (e: Exception) {
        JSONArray()
    }

    private fun save(ctx: Context, list: JSONArray) {
        // commit(): on disk before a text is handed to the radio (survives a kill right after).
        prefs(ctx).edit().putString(KEY_JOBS, list.toString()).commit()
    }

    /** Oldest finished jobs go first when the queue grows past [MAX_JOBS]. */
    private fun trim(list: JSONArray): JSONArray {
        if (list.length() <= MAX_JOBS) return list
        val items = ArrayList<JSONObject>()
        for (i in 0 until list.length()) list.optJSONObject(i)?.let { items.add(it) }
        while (items.size > MAX_JOBS) {
            val idx = items.indexOfFirst { finished(it.optString("state")) }
            if (idx < 0) break
            items.removeAt(idx)
        }
        return JSONArray().apply { items.forEach { put(it) } }
    }

    private fun finished(state: String) = state == SENT || state == DELIVERED || state == FAILED || state == CANCELLED

    private fun nextRequestCode(ctx: Context): Int {
        val p = prefs(ctx)
        val n = (p.getInt(KEY_REQ, 0) + 1) % REQ_SPAN
        p.edit().putInt(KEY_REQ, n).commit()
        return REQ_BASE + n
    }

    private fun last3(to: String): String {
        val d = to.filter { it.isDigit() }
        return if (d.length < 3) "" else d.substring(d.length - 3)
    }

    private fun statusOf(o: JSONObject): Map<String, Any> = hashMapOf(
        "id" to o.optString("id"),
        "kind" to o.optString("kind"),
        "state" to o.optString("state"),
        "attempts" to o.optInt("attempts"),
        "code" to o.optInt("code"),
        "last3" to last3(o.optString("to")),
        "updatedAt" to o.optLong("updatedAt"),
    )

    private fun notifyChanged(changed: List<JSONObject>) {
        if (changed.isEmpty()) return
        val l = listener ?: return
        try {
            l(changed.map { statusOf(it) })
        } catch (e: Exception) {
            // the screen's engine is going away
        }
    }

    private fun hasTelephony(ctx: Context): Boolean =
        ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)

    private fun hasPermission(ctx: Context): Boolean =
        ctx.checkSelfPermission(Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED

    /** Default SMS SIM, else the default SIM (API 24+), else the system default. */
    @Suppress("DEPRECATION")
    private fun smsManager(ctx: Context): SmsManager? = try {
        var id = SubscriptionManager.getDefaultSmsSubscriptionId()
        if (id == SubscriptionManager.INVALID_SUBSCRIPTION_ID && Build.VERSION.SDK_INT >= 24) {
            id = SubscriptionManager.getDefaultSubscriptionId()
        }
        if (Build.VERSION.SDK_INT >= 31) {
            val base = ctx.getSystemService(SmsManager::class.java)
            if (base != null && id != SubscriptionManager.INVALID_SUBSCRIPTION_ID) base.createForSubscriptionId(id) else base
        } else {
            if (id != SubscriptionManager.INVALID_SUBSCRIPTION_ID) SmsManager.getSmsManagerForSubscriptionId(id) else SmsManager.getDefault()
        }
    } catch (e: Exception) {
        null
    }

    private fun retryable(code: Int) =
        code == ERROR_GENERIC || code == ERROR_RADIO_OFF || code == ERROR_NO_SERVICE || code == ERROR_TIMEOUT

    /** A try failed: wait and try again (retryable code, delays left), else FAILED. */
    private fun failed(o: JSONObject, code: Int, now: Long) {
        val attempts = o.optInt("attempts")
        val retry = o.optJSONArray("retry")
        o.put("code", code)
        o.put("updatedAt", now)
        if (retryable(code) && retry != null && attempts >= 1 && attempts <= retry.length()) {
            o.put("state", QUEUED)
            o.put("nextAt", now + retry.optLong(attempts - 1, 30_000L))
        } else {
            o.put("state", FAILED)
        }
    }

    private fun reportIntent(ctx: Context, action: String, id: String, attempt: Int, part: Int): PendingIntent {
        val req = nextRequestCode(ctx)
        val intent = Intent(ctx, EmergencyTextReceiver::class.java)
            .setAction(action)
            .setData(Uri.parse("coroute-text://report/$req"))
            .putExtra(EXTRA_ID, id)
            .putExtra(EXTRA_ATTEMPT, attempt)
            .putExtra(EXTRA_PART, part)
        return PendingIntent.getBroadcast(ctx, req, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT)
    }

    /** Hands one job to the radio. The reports come back through [EmergencyTextReceiver]. */
    private fun send(ctx: Context, o: JSONObject, list: JSONArray, now: Long) {
        val manager = smsManager(ctx)
        if (manager == null) {
            o.put("attempts", o.optInt("attempts") + 1)
            failed(o, ERROR_NO_MANAGER, now)
            return
        }
        val parts = try {
            manager.divideMessage(o.optString("body"))
        } catch (e: Exception) {
            null
        }
        if (parts == null || parts.isEmpty()) {
            o.put("state", FAILED)
            o.put("code", ERROR_EMPTY)
            o.put("updatedAt", now)
            return
        }
        val attempt = o.optInt("attempts") + 1
        val id = o.optString("id")
        o.put("attempts", attempt)
        o.put("state", SENDING)
        o.put("sentAt", now)
        o.put("parts", parts.size)
        o.put("partsDone", 0)
        o.put("partErr", 0)
        o.put("delivered", 0)
        o.put("updatedAt", now)
        save(ctx, list) // the reports must find this try
        try {
            val sent = ArrayList<PendingIntent>(parts.size)
            val delivered = ArrayList<PendingIntent>(parts.size)
            for (i in parts.indices) {
                sent.add(reportIntent(ctx, ACTION_SENT, id, attempt, i))
                delivered.add(reportIntent(ctx, ACTION_DELIVERED, id, attempt, i))
            }
            val to = o.optString("to")
            if (parts.size == 1) {
                manager.sendTextMessage(to, null, parts[0], sent[0], delivered[0])
            } else {
                manager.sendMultipartTextMessage(to, null, parts, sent, delivered)
            }
        } catch (e: SecurityException) {
            o.put("state", FAILED)
            o.put("code", ERROR_NO_PERMISSION)
            o.put("updatedAt", now)
        } catch (e: Exception) {
            failed(o, ERROR_GENERIC, now)
        }
    }

    private fun handleReport(ctx: Context, action: String, id: String, attempt: Int, resultCode: Int) {
        val list = load(ctx)
        var job: JSONObject? = null
        for (i in 0 until list.length()) {
            val o = list.optJSONObject(i) ?: continue
            if (o.optString("id") == id) {
                job = o
                break
            }
        }
        val o = job ?: return
        if (o.optInt("attempts") != attempt) return // a late report of an earlier try
        val now = System.currentTimeMillis()
        val parts = maxOf(o.optInt("parts", 1), 1)
        val before = o.optString("state")
        if (action == ACTION_SENT) {
            if (before != SENDING) return
            val done = o.optInt("partsDone") + 1
            o.put("partsDone", done)
            if (resultCode != Activity.RESULT_OK && o.optInt("partErr") == 0) o.put("partErr", resultCode)
            if (done >= parts) {
                val err = o.optInt("partErr")
                if (err == 0) {
                    o.put("state", if (o.optInt("delivered") >= parts) DELIVERED else SENT)
                    o.put("code", 0)
                    o.put("updatedAt", now)
                } else {
                    failed(o, err, now)
                }
            }
        } else if (action == ACTION_DELIVERED) {
            // FLAG_IMMUTABLE: the report PDU is not filled in, so a delivery report counts as delivered.
            val d = o.optInt("delivered") + 1
            o.put("delivered", d)
            if (before == SENT && d >= parts) {
                o.put("state", DELIVERED)
                o.put("updatedAt", now)
            }
        }
        save(ctx, list)
        if (o.optString("state") != before) {
            notifyChanged(listOf(o))
            tickNow() // plans the retry, or drops the wake-up / network watch once nothing waits
        }
    }

    /** Due jobs go out; then the next wake-up is planned. */
    private fun tickNow() {
        val ctx = app ?: return
        try {
            val list = load(ctx)
            val now = System.currentTimeMillis()
            val changed = ArrayList<JSONObject>()
            val keep = JSONArray()
            for (i in 0 until list.length()) {
                val o = list.optJSONObject(i) ?: continue
                val state = o.optString("state")
                if (finished(state) && now - o.optLong("updatedAt") > KEEP_FINISHED_MS) continue // purged
                if (state == SENDING && now - o.optLong("sentAt") > REPORT_TIMEOUT_MS) {
                    failed(o, ERROR_TIMEOUT, now)
                    changed.add(o)
                }
                keep.put(o)
            }
            val due = ArrayList<JSONObject>()
            for (i in 0 until keep.length()) {
                val o = keep.optJSONObject(i) ?: continue
                if (o.optString("state") == QUEUED && o.optLong("notBefore") <= now && o.optLong("nextAt") <= now) due.add(o)
            }
            if (due.isNotEmpty()) {
                val permission = hasPermission(ctx)
                val telephony = hasTelephony(ctx)
                for (o in due) {
                    when {
                        !telephony -> {
                            o.put("state", FAILED)
                            o.put("code", ERROR_NO_TELEPHONY)
                            o.put("updatedAt", now)
                        }
                        !permission -> {
                            o.put("state", FAILED)
                            o.put("code", ERROR_NO_PERMISSION)
                            o.put("updatedAt", now)
                        }
                        else -> send(ctx, o, keep, now)
                    }
                    changed.add(o)
                }
            }
            save(ctx, keep)
            notifyChanged(changed)
            plan(ctx, keep, now)
        } catch (e: Exception) {
            Log.w(TAG, "tick failed: ${e.javaClass.simpleName}")
        }
    }

    /** Next wake-up (Handler + inexact alarm) and the network watch while a retry waits. */
    private fun plan(ctx: Context, list: JSONArray, now: Long) {
        var next = Long.MAX_VALUE
        var retryWaiting = false
        for (i in 0 until list.length()) {
            val o = list.optJSONObject(i) ?: continue
            when (o.optString("state")) {
                QUEUED -> {
                    next = minOf(next, maxOf(o.optLong("notBefore"), o.optLong("nextAt")))
                    if (o.optInt("attempts") > 0) retryWaiting = true
                }
                SENDING -> next = minOf(next, o.optLong("sentAt") + REPORT_TIMEOUT_MS + 1_000L)
            }
        }
        handler.removeCallbacks(tickRunnable)
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
        val tick = PendingIntent.getBroadcast(
            ctx,
            TICK_REQUEST_CODE,
            Intent(ctx, EmergencyTextReceiver::class.java).setAction(ACTION_TICK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        if (next == Long.MAX_VALUE) {
            try {
                am?.cancel(tick)
            } catch (e: Exception) {
                // nothing planned
            }
        } else {
            handler.postDelayed(tickRunnable, maxOf(next - now, 1_000L))
            try {
                // Inexact and allowed in Doze (no SCHEDULE_EXACT_ALARM): wakes the queue after an app kill.
                am?.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, maxOf(next, now + 1_000L), tick)
            } catch (e: Exception) {
                // the Handler still runs while the process lives
            }
        }
        watchNetwork(ctx, retryWaiting)
    }

    /** A network came back: waiting retries go now (the radio likely has service again). */
    private fun retryWaitingNow() {
        val ctx = app ?: return
        try {
            val list = load(ctx)
            val now = System.currentTimeMillis()
            var any = false
            for (i in 0 until list.length()) {
                val o = list.optJSONObject(i) ?: continue
                if (o.optString("state") == QUEUED && o.optInt("attempts") > 0 && o.optLong("nextAt") > now) {
                    o.put("nextAt", now)
                    any = true
                }
            }
            if (any) save(ctx, list)
        } catch (e: Exception) {
            // the timer retries anyway
        }
        tickNow()
    }

    private fun watchNetwork(ctx: Context, on: Boolean) {
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        if (on && networkCallback == null) {
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    handler.removeCallbacks(networkRunnable)
                    handler.postDelayed(networkRunnable, NETWORK_DEBOUNCE_MS)
                }
            }
            try {
                if (Build.VERSION.SDK_INT >= 26) {
                    cm.registerDefaultNetworkCallback(cb, handler)
                } else if (Build.VERSION.SDK_INT >= 24) {
                    cm.registerDefaultNetworkCallback(cb)
                } else {
                    cm.registerNetworkCallback(NetworkRequest.Builder().build(), cb)
                }
                networkCallback = cb
            } catch (e: Exception) {
                // the retry timer still runs
            }
        } else if (!on) {
            networkCallback?.let {
                try {
                    cm.unregisterNetworkCallback(it)
                } catch (e: Exception) {
                    // already gone
                }
            }
            networkCallback = null
        }
    }
}

/**
 * Sent / delivered reports of the emergency texts, the queue's alarm, and boot / app update (the
 * queue resumes). Not exported: the reports are this app's own PendingIntents; boot and package
 * replaced are system broadcasts.
 */
class EmergencyTextReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        // Read before goAsync(): afterwards the receiver's own getResultCode() answers 0.
        val code = resultCode
        val pending = goAsync()
        val finish = {
            try {
                pending.finish()
            } catch (e: Exception) {
                // already finished
            }
        }
        when (action) {
            EmergencyTexts.ACTION_SENT, EmergencyTexts.ACTION_DELIVERED -> {
                val id = intent.getStringExtra(EmergencyTexts.EXTRA_ID)
                if (id.isNullOrEmpty()) {
                    finish()
                    return
                }
                EmergencyTexts.onReport(context, action, id, intent.getIntExtra(EmergencyTexts.EXTRA_ATTEMPT, 0), code, finish)
            }
            else -> EmergencyTexts.tick(context, finish)
        }
    }
}
