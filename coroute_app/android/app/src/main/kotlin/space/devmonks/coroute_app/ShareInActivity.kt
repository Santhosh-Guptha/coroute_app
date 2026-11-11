package space.devmonks.coroute_app

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * 3.56 "Share to CoRoute": receives text shared from another app (a Google Maps place, a
 * maps link, coordinates) and hands it to the app's own task, then finishes at once. The
 * trampoline keeps CoRoute out of the sharing app's task (one CoRoute screen, one engine).
 * Dart opens the trip planner with the text in the destination search (map_link_parser.dart);
 * nothing is sent anywhere until the rider picks the place.
 */
class ShareInActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = ShareIn.textOf(intent)
        if (text != null) {
            try {
                startActivity(
                    Intent(this, MainActivity::class.java)
                        .setAction(ShareIn.ACTION)
                        .putExtra(ShareIn.EXTRA_TEXT, text)
                        .putExtra(ShareIn.EXTRA_TOKEN, ShareIn.processToken)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                )
            } catch (e: Exception) {
                // nothing to open
            }
        }
        finish()
    }
}

/** Shared text waiting for Dart (channel coroute/share_in: takeSharedText; sharedText when it arrives). */
object ShareIn {
    const val ACTION = "space.devmonks.coroute_app.SHARE_IN"
    const val EXTRA_TEXT = "coroute.shared_text"
    const val EXTRA_TOKEN = "coroute.share_token"
    private const val MAX_CHARS = 2000

    /** Only ShareInActivity (same process) knows it: other apps cannot fake a shared text. */
    val processToken: String = UUID.randomUUID().toString()

    @Volatile var pending: String? = null
    var channel: MethodChannel? = null

    /** The text of an ACTION_SEND text/plain intent (subject line first when it adds a name). */
    fun textOf(intent: Intent?): String? {
        if (intent == null || intent.action != Intent.ACTION_SEND) return null
        if (intent.type?.startsWith("text/plain") != true) return null
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.trim().orEmpty()
        val subject = intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT)?.toString()?.trim().orEmpty()
        val joined = if (subject.isNotEmpty() && !text.contains(subject)) "$subject\n$text" else text
        val out = joined.trim()
        return if (out.isEmpty()) null else out.take(MAX_CHARS)
    }

    /** MainActivity got an intent: keep a shared text from ShareInActivity and tell Dart. */
    fun handleActivityIntent(intent: Intent?, coldStart: Boolean) {
        if (intent == null || intent.action != ACTION || intent.getStringExtra(EXTRA_TOKEN) != processToken) return
        val text = intent.getStringExtra(EXTRA_TEXT)?.take(MAX_CHARS) ?: return
        pending = text
        intent.removeExtra(EXTRA_TEXT) // a recreated activity must not open it twice
        if (!coldStart) channel?.invokeMethod("sharedText", null)
    }

    fun register(channel: MethodChannel) {
        this.channel = channel
        channel.setMethodCallHandler { call, result ->
            if (call.method == "takeSharedText") {
                val t = pending
                pending = null
                result.success(t)
            } else {
                result.notImplemented()
            }
        }
    }

    fun dispose(channel: MethodChannel) {
        channel.setMethodCallHandler(null)
        if (this.channel === channel) this.channel = null
    }
}
