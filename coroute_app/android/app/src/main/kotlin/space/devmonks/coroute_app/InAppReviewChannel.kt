package space.devmonks.coroute_app

import android.app.Activity
import com.google.android.play.core.review.ReviewManagerFactory
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 3.55 "Rate CoRoute" (MethodChannel "coroute/in_app_review"): Google Play's In-App Review API
 * (com.google.android.play:review). `requestReview` runs requestReviewFlow -> launchReviewFlow and
 * answers {ok: true} once the flow finished, or {ok: false, error} when it could not run (no Play
 * Store, no activity, request failed).
 *
 * Google decides whether the card really shows (quota) and never tells the app whether, or how, the
 * rider rated; CoRoute never asks how the rider feels first (no review gating) and offers nothing for
 * a rating. When to ask is decided in Dart (lib/domain/engagement/rating_ask_scheduler.dart).
 */
class InAppReviewChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestReview" -> requestReview(result)
            else -> result.notImplemented()
        }
    }

    private fun gone(): Boolean = activity.isFinishing || activity.isDestroyed

    private fun requestReview(result: MethodChannel.Result) {
        var answered = false
        fun answer(ok: Boolean, error: String? = null) {
            if (answered) return
            answered = true
            val out = HashMap<String, Any>()
            out["ok"] = ok
            if (error != null) out["error"] = error
            result.success(out)
        }
        if (gone()) {
            answer(false, "NO_ACTIVITY")
            return
        }
        try {
            val manager = ReviewManagerFactory.create(activity)
            manager.requestReviewFlow().addOnCompleteListener { request ->
                if (!request.isSuccessful) {
                    answer(false, "REQUEST_FAILED")
                    return@addOnCompleteListener
                }
                if (gone()) {
                    answer(false, "NO_ACTIVITY")
                    return@addOnCompleteListener
                }
                try {
                    manager.launchReviewFlow(activity, request.result).addOnCompleteListener {
                        // Finished: shown and closed, or not shown at all (quota). The same answer either way.
                        answer(true)
                    }
                } catch (e: Exception) {
                    answer(false, "LAUNCH_FAILED")
                }
            }
        } catch (e: Exception) {
            // No Play Store / Play services on this phone.
            answer(false, "UNAVAILABLE")
        }
    }
}
