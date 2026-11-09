package space.devmonks.coroute_app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONObject

/**
 * 3.55 push notifications: receives the gateway's FCM data messages (src/push.js).
 *
 * App in front (MainActivity resumed and Flutter attached): the message goes to Dart, no system
 * notification. Otherwise a local notification on the matching channel; tapping it opens
 * MainActivity with extras {pushType, payload} (PushChannel.handleActivityIntent).
 * Declared in AndroidManifest.xml (MESSAGING_EVENT, not exported).
 */
class CoRouteMessagingService : FirebaseMessagingService() {

    companion object {
        private const val CHANNEL_SOCIAL = "coroute_social" // same id as the app's "Friends" channel
        private const val CHANNEL_RIDE_INVITES = "coroute_ride_invites"
        private const val CHANNEL_PLAN = "coroute_plan_reminders"
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
        val channelId = when {
            rideInvite -> CHANNEL_RIDE_INVITES
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
        builder.setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setCategory(if (rideInvite) Notification.CATEGORY_EVENT else Notification.CATEGORY_SOCIAL)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
        try {
            nm.notify(TAG, id, builder.build())
        } catch (_: SecurityException) {
            // Notifications blocked between the check and the post.
        }
    }

    /** One notification per thing (a later push about the same request / crew / ride replaces it). */
    private fun notificationId(type: String, data: Map<String, String>): Int {
        val ref = data["requestId"] ?: data["inviteId"] ?: data["pollId"] ?: data["crewId"] ?: data["groupId"] ?: ""
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
            else -> NotificationChannel(id, "Friends", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Friend requests, crew invites and crew polls."
            }
        }
        nm.createNotificationChannel(channel)
    }
}
