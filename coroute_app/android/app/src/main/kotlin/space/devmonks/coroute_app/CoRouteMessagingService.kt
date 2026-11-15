package space.devmonks.coroute_app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.SystemClock
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.URL
import javax.net.ssl.HttpsURLConnection

/**
 * 3.55 push notifications: receives the gateway's FCM data messages (src/push.js).
 *
 * App in front (MainActivity resumed and Flutter attached): the message goes to Dart, no system
 * notification. Otherwise a local notification on the matching channel; tapping it opens
 * MainActivity with extras {pushType, payload} (PushChannel.handleActivityIntent).
 * Declared in AndroidManifest.xml (MESSAGING_EVENT, not exported).
 *
 * 3.56 admin "News and updates" pushes (type NEWS, gateway src/push_campaigns.js): own channel
 * "News and updates" (the rider can also mute it in Android settings), dropped while the in-app
 * switch is off (PushConfig.isNewsEnabled), and a big picture when the data carries `imageUrl`:
 * https only, no redirects, 5 s timeouts, at most 1 MB, decoded downscaled; any problem falls back
 * to the text notification. The tap opens the `target` screen (Dart push_routing.dart).
 *
 * 3.56 push kinds (data `kind`, gateway push_campaigns.js KINDS; Dart lib/domain/notify/push_kinds.dart):
 * update -> "News and updates" (coroute_news), event -> "Events" (coroute_events), safety_tip ->
 * "Safety tips" (coroute_safety_tips), community -> "Community" (coroute_community), partner_perk ->
 * "Partner perks" (coroute_partner_perks, off until the rider turns it on; labelled "Partner perk").
 * A kind switched off in the app (PushConfig.isKindEnabled) is dropped, also in the foreground.
 * A NEWS push without `kind` (older gateway) is an update. Every kind may carry a big picture.
 */
class CoRouteMessagingService : FirebaseMessagingService() {

    companion object {
        private const val CHANNEL_SOCIAL = "coroute_social" // same id as the app's "Friends" channel
        private const val CHANNEL_RIDE_INVITES = "coroute_ride_invites"
        private const val CHANNEL_PLAN = "coroute_plan_reminders"
        private const val CHANNEL_NEWS = "coroute_news"
        private const val CHANNEL_EVENTS = "coroute_events"
        private const val CHANNEL_SAFETY_TIPS = "coroute_safety_tips"
        private const val CHANNEL_COMMUNITY = "coroute_community"
        private const val CHANNEL_PARTNER_PERKS = "coroute_partner_perks"
        // v3.62: a group member's SOS while my app is closed (gateway GROUP_SOS). Same ids as the app's
        // AlertService channels ("SOS alerts" on the alarm sound, "Group alerts"), created here if the app
        // has not made them yet.
        private const val CHANNEL_SOS = "coroute_sos_v2"
        private const val CHANNEL_GROUP_ALERTS = "coroute_alerts"
        private const val MAX_PARTNER = 60
        private const val MAX_IMAGE_BYTES = 1024 * 1024
        private const val IMAGE_TIMEOUT_MS = 5000
        private const val IMAGE_DEADLINE_MS = 8000L
        private const val MAX_IMAGE_SIDE = 2048
        private const val TAG = "coroute_push"
        private const val MAX_TITLE = 80
        private const val MAX_BODY = 240
        private val TYPE_RE = Regex("^[A-Z][A-Z_]{2,31}$")
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        PushChannel.active?.deliverToken(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)
        val data = message.data
        val type = data["type"] ?: return
        if (!TYPE_RE.matches(type)) return
        // v3.62: a group member's SOS is never dropped by an app switch, and is shown even with the app in front
        // (the push only comes when this phone had no live connection, so the in-app alarm may not have fired).
        val sos = isSos(type)
        if (!sos && !PushConfig.isEnabled(applicationContext)) return
        if (type == "NEWS" && !PushConfig.isNewsEnabled(applicationContext)) return
        if (type == "NEWS" && !PushConfig.isKindEnabled(applicationContext, newsKind(data))) return
        val live = PushChannel.active
        if (PushChannel.foreground && live != null) {
            live.deliverForeground(data)
            if (!sos) return
        }
        showNotification(type, data)
    }

    private fun showNotification(type: String, data: Map<String, String>) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        if (Build.VERSION.SDK_INT >= 24 && !nm.areNotificationsEnabled()) return

        val rideInvite = type == "RIDE_INVITE"
        val news = type == "NEWS"
        val groupSos = type == "GROUP_SOS"
        val kind = if (news) newsKind(data) else ""
        val channelId = when {
            groupSos -> CHANNEL_SOS
            type == "GROUP_SOS_RESOLVED" -> CHANNEL_GROUP_ALERTS
            rideInvite -> CHANNEL_RIDE_INVITES
            news -> when (kind) {
                "event" -> CHANNEL_EVENTS
                "safety_tip" -> CHANNEL_SAFETY_TIPS
                "community" -> CHANNEL_COMMUNITY
                "partner_perk" -> CHANNEL_PARTNER_PERKS
                else -> CHANNEL_NEWS
            }
            type.startsWith("SUBSCRIPTION") -> CHANNEL_PLAN
            else -> CHANNEL_SOCIAL
        }
        ensureChannel(nm, channelId)

        val title = (data["title"] ?: "CoRoute").take(MAX_TITLE)
        val body = (data["body"] ?: "").take(MAX_BODY)
        val payload = JSONObject()
        for ((k, v) in data) if (k != "type" && k != "title" && k != "body") payload.put(k, v)

        val id = notificationId(type, data)
        val open = Intent(this, MainActivity::class.java).apply {
            action = "space.devmonks.coroute_app.PUSH_OPEN"
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra(PushChannel.EXTRA_MARK, true)
            putExtra(PushChannel.EXTRA_TYPE, type)
            putExtra(PushChannel.EXTRA_PAYLOAD, payload.toString())
        }
        val pi = PendingIntent.getActivity(
            this, id, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(
                when {
                    groupSos -> Notification.PRIORITY_MAX
                    rideInvite || isSos(type) -> Notification.PRIORITY_HIGH
                    else -> Notification.PRIORITY_DEFAULT
                }
            )
        }
        // Big picture (NEWS with an image), else the full text when expanded.
        val picture = if (news) data["imageUrl"]?.let { fetchImage(it) } else null
        val style: Notification.Style = if (picture != null) {
            Notification.BigPictureStyle().bigPicture(picture).setSummaryText(body)
        } else {
            Notification.BigTextStyle().bigText(body)
        }
        // A partner perk is always labelled as one ("Partner perk · Speed Garage").
        if (kind == "partner_perk") {
            val partner = (data["partner"] ?: "").trim().take(MAX_PARTNER)
            builder.setSubText(if (partner.isEmpty()) "Partner perk" else "Partner perk · $partner")
        }
        builder.setSmallIcon(R.drawable.ic_stat_coroute)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(style)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setCategory(
                when {
                    groupSos -> Notification.CATEGORY_ALARM
                    isSos(type) -> Notification.CATEGORY_STATUS
                    rideInvite -> Notification.CATEGORY_EVENT
                    news -> Notification.CATEGORY_RECOMMENDATION
                    else -> Notification.CATEGORY_SOCIAL
                }
            )
            // An SOS reads on the lock screen (first name and ride name only; never a place or medical info).
            .setVisibility(if (isSos(type)) Notification.VISIBILITY_PUBLIC else Notification.VISIBILITY_PRIVATE)
        try {
            nm.notify(TAG, id, builder.build())
        } catch (_: SecurityException) {
            // Notifications blocked between the check and the post.
        }
    }

    /**
     * The big picture of an admin push, or null (then the text notification is shown). https only,
     * no redirects, 5 s connect / read timeouts and an 8 s deadline, at most 1 MB read, decoded
     * downscaled to at most ~2048 px. Runs on the FCM worker thread (never the main thread).
     */
    private fun fetchImage(raw: String): Bitmap? {
        return try {
            val url = URL(raw)
            if (url.protocol != "https" || url.host.isNullOrEmpty()) return null
            val conn = url.openConnection() as? HttpsURLConnection ?: return null
            conn.connectTimeout = IMAGE_TIMEOUT_MS
            conn.readTimeout = IMAGE_TIMEOUT_MS
            conn.instanceFollowRedirects = false
            conn.useCaches = false
            conn.setRequestProperty("Accept", "image/jpeg, image/png, image/webp")
            try {
                if (conn.responseCode != 200) return null
                val declared = conn.contentLength
                if (declared > MAX_IMAGE_BYTES) return null
                val bytes = conn.inputStream.use { readCapped(it) } ?: return null
                decodeScaled(bytes)
            } finally {
                conn.disconnect()
            }
        } catch (_: Exception) {
            null
        } catch (_: OutOfMemoryError) {
            null
        }
    }

    private fun readCapped(input: InputStream): ByteArray? {
        val started = SystemClock.elapsedRealtime()
        val out = ByteArrayOutputStream()
        val buf = ByteArray(16 * 1024)
        var total = 0
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            total += n
            if (total > MAX_IMAGE_BYTES) return null
            if (SystemClock.elapsedRealtime() - started > IMAGE_DEADLINE_MS) return null
            out.write(buf, 0, n)
        }
        return if (total > 0) out.toByteArray() else null
    }

    private fun decodeScaled(bytes: ByteArray): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (bounds.outWidth / sample > MAX_IMAGE_SIDE || bounds.outHeight / sample > MAX_IMAGE_SIDE) sample *= 2
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
    }

    /** The kind of an admin NEWS push; missing or unknown (older gateway) is "update". */
    private fun newsKind(data: Map<String, String>): String {
        val k = data["kind"] ?: return "update"
        return if (k == "event" || k == "safety_tip" || k == "community" || k == "partner_perk") k else "update"
    }

    private fun isSos(type: String): Boolean = type == "GROUP_SOS" || type == "GROUP_SOS_RESOLVED"

    /** One notification per thing (a later push about the same request / crew / ride replaces it). */
    private fun notificationId(type: String, data: Map<String, String>): Int {
        // v3.62: the SOS and its close share one notification per alert (the close replaces the alarm).
        if (isSos(type)) return ("GROUP_SOS|" + (data["alertId"] ?: data["groupId"] ?: "")).hashCode() and 0x7fffffff
        val ref = data["requestId"] ?: data["inviteId"] ?: data["pollId"] ?: data["crewId"] ?: data["groupId"] ?: data["campaignId"] ?: ""
        return (type + "|" + ref).hashCode() and 0x7fffffff
    }

    private fun ensureChannel(nm: NotificationManager, id: String) {
        if (Build.VERSION.SDK_INT < 26) return
        if (nm.getNotificationChannel(id) != null) return
        val channel = when (id) {
            CHANNEL_SOS -> NotificationChannel(id, "SOS alerts", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "A rider in your convoy needs help."
                setBypassDnd(true)
                setSound(
                    android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_ALARM),
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_ALARM)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                enableVibration(true)
            }
            CHANNEL_GROUP_ALERTS -> NotificationChannel(id, "Group alerts", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "A rider stopped for long, fell behind or lost signal."
            }
            CHANNEL_RIDE_INVITES -> NotificationChannel(id, "Ride invites", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "A friend or crew invites you to a ride."
            }
            CHANNEL_PLAN -> NotificationChannel(id, "Plan reminders", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Tells you a few days before your CoRoute plan ends."
            }
            CHANNEL_NEWS -> NotificationChannel(id, "News and updates", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "New features and tips from CoRoute. Safety and ride alerts use other channels."
            }
            CHANNEL_EVENTS -> NotificationChannel(id, "Events", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Group rides, meet-ups and community events."
            }
            CHANNEL_SAFETY_TIPS -> NotificationChannel(id, "Safety tips", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Riding tips from CoRoute. SOS and crash alerts use other channels."
            }
            CHANNEL_COMMUNITY -> NotificationChannel(id, "Community", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Rider stories and community milestones."
            }
            CHANNEL_PARTNER_PERKS -> NotificationChannel(id, "Partner perks", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Perks for riders at partners CoRoute picked. Off unless you turn it on in the app."
            }
            else -> NotificationChannel(id, "Friends", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Friend requests, crew invites and crew polls."
            }
        }
        nm.createNotificationChannel(channel)
    }
}
