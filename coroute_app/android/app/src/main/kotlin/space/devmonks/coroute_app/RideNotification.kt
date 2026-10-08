package space.devmonks.coroute_app

import android.annotation.TargetApi
import android.app.Activity
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.RemoteViews
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * The big ride notification (MethodChannel "coroute/ride_notification", 3.15).
 *
 * During a ride the app replaces the foreground service notification of
 * flutter_foreground_task IN PLACE: same notification id (the service id the app
 * passes to startService, 1001) and same channel ("coroute_convoy", created by the
 * plugin from the app's AndroidNotificationOptions). Android then shows one ongoing
 * notification and the service is unaffected.
 *
 * Methods: show {args} -> Boolean, supported -> Boolean (Android 7+),
 * takeLaunchAction -> {action, ref}?, ensure -> Boolean (post ours again when the
 * plugin replaced it), cancel -> null. Callback to Dart: onAction {action, ref}.
 *
 * Buttons: SOS opens the app's hold-to-send screen over the lock screen (through
 * [RideSosActivity]); it never sends anything by itself. Wait for me and I Can Help
 * are broadcasts to a receiver registered at run time (not exported), so they work
 * from the lock screen without unlocking. Open map and Navigate open the app.
 *
 * Built with the framework Notification.Builder (Android 7+ only), so no AndroidX
 * dependency is needed. Nothing here logs notification text.
 */
class RideNotification(private val activity: Activity, private val channel: MethodChannel) : MethodChannel.MethodCallHandler {

    companion object {
        const val ACTION_ACTIVITY = "space.devmonks.coroute_app.RIDE_ACTION"
        const val ACTION_BROADCAST = "space.devmonks.coroute_app.RIDE_BROADCAST"
        const val EXTRA_ACTION = "action"
        const val EXTRA_REF = "ref"
        const val EXTRA_TOKEN = "coroute_token"
        const val EXTRA_RICH = "coroute_rich"

        const val SOS = "SOS"
        const val WAIT = "WAIT"
        const val MAP = "MAP"
        const val NAV_EMERGENCY = "NAV_EMERGENCY"
        const val ASSIST_ACCEPT = "ASSIST_ACCEPT"

        private val ACTIVITY_ACTIONS = setOf(SOS, MAP, NAV_EMERGENCY, WAIT, ASSIST_ACCEPT)
        private val BROADCAST_ACTIONS = setOf(WAIT, ASSIST_ACCEPT)

        private const val RC_CONTENT = 7101
        private const val RC_SOS = 7102
        private const val RC_WAIT = 7103
        private const val RC_MAP = 7104
        private const val RC_NAV = 7105
        private const val RC_ASSIST = 7106

        private const val DEFAULT_ID = 1001
        private const val DEFAULT_CHANNEL = "coroute_convoy"
        private const val MAX_TEXT = 200

        /**
         * Secret of this process. Only intents built here carry it, so another app cannot
         * fake a button press (the activity is exported for the launcher and invite links).
         */
        val processToken: String = UUID.randomUUID().toString()

        private val ROW_IDS = intArrayOf(R.id.ride_notif_row0, R.id.ride_notif_row1, R.id.ride_notif_row2, R.id.ride_notif_row3)
        private val ROW_NAME_IDS = intArrayOf(R.id.ride_notif_row0_name, R.id.ride_notif_row1_name, R.id.ride_notif_row2_name, R.id.ride_notif_row3_name)
        private val ROW_DETAIL_IDS = intArrayOf(R.id.ride_notif_row0_detail, R.id.ride_notif_row1_detail, R.id.ride_notif_row2_detail, R.id.ride_notif_row3_detail)
        private val ROW_FLAG_IDS = intArrayOf(R.id.ride_notif_row0_flag, R.id.ride_notif_row1_flag, R.id.ride_notif_row2_flag, R.id.ride_notif_row3_flag)
    }

    private val app: Context = activity.applicationContext
    private var receiverRegistered = false

    /** The button that launched the activity before Dart was listening (taken once). */
    @Volatile
    private var pendingLaunch: Map<String, String>? = null

    private var lastNotification: Notification? = null
    private var lastId = DEFAULT_ID
    private var layoutsVerified = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ACTION_BROADCAST) return
            if (intent.getStringExtra(EXTRA_TOKEN) != processToken) return
            val action = intent.getStringExtra(EXTRA_ACTION) ?: return
            if (action !in BROADCAST_ACTIONS) return
            deliver(action, intent.getStringExtra(EXTRA_REF) ?: "", fromBroadcast = true)
        }
    }

    fun register() {
        if (receiverRegistered) return
        val filter = IntentFilter(ACTION_BROADCAST)
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                app.registerReceiver(receiver, filter)
            }
            receiverRegistered = true
        } catch (e: Exception) {
            receiverRegistered = false
        }
    }

    fun dispose() {
        if (receiverRegistered) {
            try {
                app.unregisterReceiver(receiver)
            } catch (e: Exception) {
                // already gone
            }
            receiverRegistered = false
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "supported" -> result.success(Build.VERSION.SDK_INT >= 24)
            "show" -> {
                val args = call.arguments as? Map<*, *>
                result.success(if (args == null) false else show(args))
            }
            "ensure" -> result.success(ensure())
            "takeLaunchAction" -> {
                val p = pendingLaunch
                pendingLaunch = null
                result.success(p)
            }
            "cancel" -> {
                // The service owns the notification and removes it when it stops.
                lastNotification = null
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------ intents from the buttons

    /**
     * Called by MainActivity for its launch intent ([coldStart] true: only kept for
     * takeLaunchAction) and for every onNewIntent (sent to Dart at once).
     * Returns true when the intent was a ride notification button.
     */
    fun handleActivityIntent(intent: Intent?, coldStart: Boolean): Boolean {
        if (intent == null || intent.action != ACTION_ACTIVITY) return false
        val action = intent.getStringExtra(EXTRA_ACTION) ?: return false
        if (action !in ACTIVITY_ACTIONS) return false
        val ref = intent.getStringExtra(EXTRA_REF) ?: ""
        // Only intents built by this process (the activity is exported for the launcher and links).
        if (intent.getStringExtra(EXTRA_TOKEN) != processToken) return false
        if (action == SOS) {
            // From our own lock-screen trampoline: show over the lock screen for this launch.
            // The hold screen calls alarmWindow(false) when it closes.
            showOverLockScreen()
        }
        // Consumed: a later recreation of the activity must not replay it.
        intent.removeExtra(EXTRA_ACTION)
        if (coldStart) {
            pendingLaunch = mapOf("action" to action, "ref" to ref)
        } else {
            deliver(action, ref, fromBroadcast = false)
        }
        return true
    }

    @Suppress("DEPRECATION")
    private fun showOverLockScreen() {
        if (Build.VERSION.SDK_INT >= 27) {
            activity.setShowWhenLocked(true)
            activity.setTurnScreenOn(true)
        } else {
            activity.window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
    }

    /** Sends the press to Dart; if nobody answers, keeps it (activity) or opens the app (broadcast). */
    private fun deliver(action: String, ref: String, fromBroadcast: Boolean) {
        val args = mapOf("action" to action, "ref" to ref)
        try {
            channel.invokeMethod("onAction", args, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (result != true) fallback(action, ref, fromBroadcast)
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    fallback(action, ref, fromBroadcast)
                }

                override fun notImplemented() {
                    fallback(action, ref, fromBroadcast)
                }
            })
        } catch (e: Exception) {
            fallback(action, ref, fromBroadcast)
        }
    }

    private fun fallback(action: String, ref: String, fromBroadcast: Boolean) {
        pendingLaunch = mapOf("action" to action, "ref" to ref)
        if (!fromBroadcast) return
        // No Dart listening: open the app with the same action (may be refused by
        // Android 12+ for a broadcast started from a notification; the press is then kept).
        try {
            val i = Intent(app, MainActivity::class.java)
                .setAction(ACTION_ACTIVITY)
                .putExtra(EXTRA_ACTION, action)
                .putExtra(EXTRA_REF, ref)
                .putExtra(EXTRA_TOKEN, processToken)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            app.startActivity(i)
        } catch (e: Exception) {
            // kept in pendingLaunch for the next takeLaunchAction
        }
    }

    private fun immutable(): Int = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT

    private fun activityIntent(action: String, ref: String, requestCode: Int): PendingIntent {
        val i = Intent(app, MainActivity::class.java)
            .setAction(ACTION_ACTIVITY)
            .putExtra(EXTRA_ACTION, action)
            .putExtra(EXTRA_REF, ref)
            .putExtra(EXTRA_TOKEN, processToken)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(app, requestCode, i, immutable())
    }

    private fun sosIntent(): PendingIntent {
        val i = Intent(app, RideSosActivity::class.java).putExtra(EXTRA_TOKEN, processToken)
        return PendingIntent.getActivity(app, RC_SOS, i, immutable())
    }

    private fun broadcastIntent(action: String, ref: String, requestCode: Int): PendingIntent {
        val i = Intent(ACTION_BROADCAST)
            .setPackage(app.packageName)
            .putExtra(EXTRA_ACTION, action)
            .putExtra(EXTRA_REF, ref)
            .putExtra(EXTRA_TOKEN, processToken)
        return PendingIntent.getBroadcast(app, requestCode, i, immutable())
    }

    // ------------------------------------------------------------ the notification

    private fun manager(): NotificationManager? = app.getSystemService(NotificationManager::class.java)

    /** The service's notification (plain or ours) is up: never create one when the service is gone. */
    private fun isActive(nm: NotificationManager, id: Int): Boolean = try {
        nm.activeNotifications.any { it.id == id }
    } catch (e: Exception) {
        false
    }

    private fun show(args: Map<*, *>): Boolean {
        if (Build.VERSION.SDK_INT < 24) return false
        val nm = manager() ?: return false
        return try {
            if (!nm.areNotificationsEnabled()) return false
            val id = (args["notificationId"] as? Number)?.toInt() ?: DEFAULT_ID
            val channelId = (args["channelId"] as? String)?.takeIf { it.isNotEmpty() } ?: DEFAULT_CHANNEL
            if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(channelId) == null) return false
            if (!isActive(nm, id)) return false
            val n = build(args, channelId) ?: return false
            nm.notify(id, n)
            lastNotification = n
            lastId = id
            true
        } catch (e: Exception) {
            // SecurityException (notifications not allowed), RemoteViews errors, anything else:
            // Dart falls back to the plain notification.
            false
        }
    }

    /** Puts ours back when the plugin re-posted its plain notification. True when ours shows. */
    private fun ensure(): Boolean {
        if (Build.VERSION.SDK_INT < 24) return false
        val n = lastNotification ?: return false
        val nm = manager() ?: return false
        return try {
            val active = nm.activeNotifications.firstOrNull { it.id == lastId } ?: return false
            if (active.notification.extras.getBoolean(EXTRA_RICH, false)) return true
            nm.notify(lastId, n)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun str(args: Map<*, *>, key: String): String = ((args[key] as? String) ?: "").take(MAX_TEXT)
    private fun bool(args: Map<*, *>, key: String, default: Boolean): Boolean = (args[key] as? Boolean) ?: default

    private fun color(resId: Int): Int = app.getColor(resId)

    @Suppress("DEPRECATION")
    private fun builder(channelId: String): Notification.Builder =
        if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(app, channelId)
        } else {
            Notification.Builder(app).setPriority(Notification.PRIORITY_LOW)
        }

    @TargetApi(24)
    private fun build(args: Map<*, *>, channelId: String): Notification? {
        if (Build.VERSION.SDK_INT < 24) return null
        val mode = str(args, "mode")
        val tone = str(args, "tone")
        val title = str(args, "title")
        val subtitle = str(args, "subtitle")
        val header = str(args, "header")
        val status = str(args, "status")
        val statusPositive = bool(args, "statusPositive", false)
        val context = str(args, "context")
        val contextLabel = str(args, "contextLabel")
        val contextRef = str(args, "contextRef")
        val lockScreenPublic = bool(args, "lockScreenPublic", true)
        val showSos = bool(args, "showSos", true)
        val showWait = bool(args, "showWait", true)
        val emergency = mode == "GROUP_EMERGENCY" || mode == "ASSIST"

        val toneColor = when (tone) {
            "CRITICAL" -> color(R.color.ride_notif_critical)
            "WARNING" -> color(R.color.ride_notif_warning)
            "POSITIVE" -> color(R.color.ride_notif_positive)
            else -> null
        }

        // Collapsed: two lines.
        val collapsed = RemoteViews(app.packageName, R.layout.ride_notif_collapsed)
        collapsed.setTextViewText(R.id.ride_notif_c_title, title)
        collapsed.setTextViewText(R.id.ride_notif_c_subtitle, subtitle)
        if (toneColor != null && tone != "POSITIVE") collapsed.setTextColor(R.id.ride_notif_c_title, toneColor)

        // Expanded: title, convoy line, ladder, status, buttons.
        val expanded = RemoteViews(app.packageName, R.layout.ride_notif_expanded)
        expanded.setTextViewText(R.id.ride_notif_title, title)
        if (toneColor != null && tone != "POSITIVE") expanded.setTextColor(R.id.ride_notif_title, toneColor)
        setOptionalText(expanded, R.id.ride_notif_header, header)
        setOptionalText(expanded, R.id.ride_notif_status, status)
        if (statusPositive && status.isNotEmpty()) expanded.setTextColor(R.id.ride_notif_status, color(R.color.ride_notif_positive))

        val rows = (args["rows"] as? List<*>) ?: emptyList<Any?>()
        var shownRows = 0
        for (i in ROW_IDS.indices) {
            val row = rows.getOrNull(i) as? Map<*, *>
            if (row == null) {
                expanded.setViewVisibility(ROW_IDS[i], View.GONE)
                continue
            }
            shownRows++
            expanded.setViewVisibility(ROW_IDS[i], View.VISIBLE)
            expanded.setTextViewText(ROW_NAME_IDS[i], str(row, "name"))
            expanded.setTextViewText(ROW_DETAIL_IDS[i], str(row, "detail"))
            setOptionalText(expanded, ROW_FLAG_IDS[i], str(row, "flag"))
        }
        expanded.setViewVisibility(R.id.ride_notif_rows, if (shownRows > 0) View.VISIBLE else View.GONE)

        // Buttons (48 dp high, one tap each). SOS only opens the hold-to-send screen.
        val sosLabel = str(args, "sosLabel").ifEmpty { "SOS" }
        val waitLabel = str(args, "waitLabel").ifEmpty { "Wait for me" }
        val mapLabel = str(args, "mapLabel").ifEmpty { "Open map" }
        setButton(expanded, R.id.ride_notif_btn_sos, showSos, sosLabel, "$sosLabel, opens the hold to send screen", sosIntent())
        setButton(expanded, R.id.ride_notif_btn_wait, showWait, waitLabel, waitLabel, broadcastIntent(WAIT, "", RC_WAIT))
        setButton(expanded, R.id.ride_notif_btn_map, true, mapLabel, mapLabel, activityIntent(MAP, "", RC_MAP))
        val contextIntent = when (context) {
            NAV_EMERGENCY -> activityIntent(NAV_EMERGENCY, contextRef, RC_NAV)
            ASSIST_ACCEPT -> if (contextRef.isEmpty()) null else broadcastIntent(ASSIST_ACCEPT, contextRef, RC_ASSIST)
            else -> null
        }
        setButton(expanded, R.id.ride_notif_btn_context, contextIntent != null && contextLabel.isNotEmpty(), contextLabel, contextLabel, contextIntent)

        if (!layoutsVerified) {
            // Inflate once here: a layout error must fail in this call (plain fallback),
            // never as a "bad notification" in the system UI.
            val parent = FrameLayout(app)
            collapsed.apply(app, parent)
            expanded.apply(app, parent)
            layoutsVerified = true
        }

        val content = activityIntent(MAP, "", RC_CONTENT)
        val publicTitle = str(args, "publicTitle").ifEmpty { "CoRoute ride active" }
        val publicText = str(args, "publicText")
        val publicVersion = builder(channelId)
            .setSmallIcon(app.applicationInfo.icon)
            .setContentTitle(publicTitle)
            .setOngoing(true)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setContentIntent(content)
        if (publicText.isNotEmpty()) publicVersion.setContentText(publicText)
        if (toneColor != null) publicVersion.setColor(toneColor) else publicVersion.setColor(color(R.color.ride_notif_accent))

        val extras = Bundle()
        extras.putBoolean(EXTRA_RICH, true)
        val b = builder(channelId)
            .setSmallIcon(app.applicationInfo.icon)
            .setStyle(Notification.DecoratedCustomViewStyle())
            .setCustomContentView(collapsed)
            .setCustomBigContentView(expanded)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setLocalOnly(true)
            .setCategory(if (emergency) Notification.CATEGORY_STATUS else Notification.CATEGORY_NAVIGATION)
            .setColor(toneColor ?: color(R.color.ride_notif_accent))
            .setContentIntent(content)
            // Plain lines too: for phones that ignore custom layouts, for accessibility and wearables.
            .setContentTitle(title)
            .setContentText(subtitle)
            .setVisibility(if (lockScreenPublic) Notification.VISIBILITY_PUBLIC else Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion.build())
            .addExtras(extras)
        if (Build.VERSION.SDK_INT >= 26) b.setColorized(false)
        if (Build.VERSION.SDK_INT >= 31) b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        return b.build()
    }

    private fun setOptionalText(views: RemoteViews, id: Int, text: String) {
        if (text.isEmpty()) {
            views.setViewVisibility(id, View.GONE)
        } else {
            views.setViewVisibility(id, View.VISIBLE)
            views.setTextViewText(id, text)
        }
    }

    private fun setButton(views: RemoteViews, id: Int, visible: Boolean, label: String, description: String, intent: PendingIntent?) {
        if (!visible || intent == null) {
            views.setViewVisibility(id, View.GONE)
            return
        }
        views.setViewVisibility(id, View.VISIBLE)
        views.setTextViewText(id, label)
        views.setContentDescription(id, description)
        views.setOnClickPendingIntent(id, intent)
    }
}

/**
 * Invisible trampoline for the notification's SOS button. Declared showWhenLocked +
 * turnScreenOn in the manifest, so the system UI starts it over the lock screen
 * without asking for the PIN; it opens MainActivity with the SOS action (MainActivity
 * then shows over the lock screen for this launch only) and finishes at once.
 * Not exported; it needs this process's token.
 */
class RideSosActivity : Activity() {
    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT < 27) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        }
        if (intent?.getStringExtra(RideNotification.EXTRA_TOKEN) == RideNotification.processToken) {
            try {
                startActivity(
                    Intent(this, MainActivity::class.java)
                        .setAction(RideNotification.ACTION_ACTIVITY)
                        .putExtra(RideNotification.EXTRA_ACTION, RideNotification.SOS)
                        .putExtra(RideNotification.EXTRA_TOKEN, RideNotification.processToken)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                )
            } catch (e: Exception) {
                // nothing to open
            }
        }
        finish()
    }
}
