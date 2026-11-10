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
 */
class CoRouteMessagingService : FirebaseMessagingService() {

    companion object {
        private const val CHANNEL_SOCIAL = "coroute_social" // same id as the app's "Friends" channel
        private const val CHANNEL_RIDE_INVITES = "coroute_ride_invites"
        private const val CHANNEL_PLAN = "coroute_plan_reminders"
        private const val CHANNEL_NEWS = "coroute_news"
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
        if (!PushConfig.isEnabled(applicationContext)) return
        if (type == "NEWS" && !PushConfig.isNewsEnabled(applicationContext)) return
        val live = PushChannel.active
        if (PushChannel.foreground && live != null) {
            live.deliverForeground(data)
            return
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
        val channelId = when {
            rideInvite -> CHANNEL_RIDE_INVITES
            news -> CHANNEL_NEWS
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
                if (rideInvite) Notification.PRIORITY_HIGH else Notification.PRIORITY_DEFAULT
            )
        }
        // Big picture (NEWS with an image), else the full text when expanded.
        val picture = if (news) data["imageUrl"]?.let { fetchImage(it) } else null
        val style: Notification.Style = if (picture != null) {
            Notification.BigPictureStyle().bigPicture(picture).setSummaryText(body)
        } else {
            Notification.BigTextStyle().bigText(body)
        }
        builder.setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(style)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setCategory(
                when {
                    rideInvite -> Notification.CATEGORY_EVENT
                    news -> Notification.CATEGORY_RECOMMENDATION
                    else -> Notification.CATEGORY_SOCIAL
                }
            )
            .setVisibility(Notification.VISIBILITY_PRIVATE)
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

    /** One notification per thing (a later push about the same request / crew / ride replaces it). */
    private fun notificationId(type: String, data: Map<String, String>): Int {
        val ref = data["requestId"] ?: data["inviteId"] ?: data["pollId"] ?: data["crewId"] ?: data["groupId"] ?: data["campaignId"] ?: ""
        return (type + "|" + ref).hashCode() and 0x7fffffff
    }

    private fun ensureChannel(nm: NotificationManager, id: String) {
        if (Build.VERSION.SDK_INT < 26) return
        if (nm.getNotificationChannel(id) != null) return
        val channel = when (id) {
            CHANNEL_RIDE_INVITES -> NotificationChannel(id, "Ride invites", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "A friend or crew invites you to a ride."
            }
            CHANNEL_PLAN -> NotificationChannel(id, "Plan reminders", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Tells you a few days before your CoRoute plan ends."
            }
            CHANNEL_NEWS -> NotificationChannel(id, "News and updates", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "New features and tips from CoRoute. Safety and ride alerts use other channels."
            }
            else -> NotificationChannel(id, "Friends", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Friend requests, crew invites and crew polls."
            }
        }
        nm.createNotificationChannel(channel)
    }
}
