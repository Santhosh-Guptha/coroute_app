package space.devmonks.coroute_app

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 3.55 coupon QR (docs/features_355/marketing_studio.md): the Play Install Referrer string
 * (e.g. "coupon=WELCOME50") the website put on the Play Store link. Dart asks once, on first
 * launch (PendingCouponStore.checkInstallReferrerOnce), and parses the code itself.
 *
 * Answers: the referrer string, null (no referrer / not supported / not from Play), or the error
 * "RETRY" when the Play Store service was not reachable (Dart asks again next launch). Never throws,
 * replies exactly once.
 */
class InstallReferrerChannel(private val context: Context) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "getInstallReferrer") {
            result.notImplemented()
            return
        }
        val replied = AtomicBoolean(false)
        fun reply(block: () -> Unit) {
            if (replied.compareAndSet(false, true)) main.post { runCatching(block) }
        }
        val client: InstallReferrerClient
        try {
            client = InstallReferrerClient.newBuilder(context.applicationContext).build()
        } catch (t: Throwable) {
            reply { result.success(null) }
            return
        }
        fun close() {
            runCatching { client.endConnection() }
        }
        try {
            client.startConnection(object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(responseCode: Int) {
                    when (responseCode) {
                        InstallReferrerClient.InstallReferrerResponse.OK -> {
                            val referrer = try {
                                client.installReferrer?.installReferrer
                            } catch (t: Throwable) {
                                null
                            }
                            reply { result.success(referrer) }
                        }
                        InstallReferrerClient.InstallReferrerResponse.SERVICE_UNAVAILABLE ->
                            reply { result.error("RETRY", "Play Store not reachable", null) }
                        // FEATURE_NOT_SUPPORTED, DEVELOPER_ERROR, PERMISSION_ERROR...: nothing to read.
                        else -> reply { result.success(null) }
                    }
                    close()
                }

                override fun onInstallReferrerServiceDisconnected() {
                    reply { result.error("RETRY", "Play Store disconnected", null) }
                    close()
                }
            })
        } catch (t: Throwable) {
            close()
            reply { result.success(null) }
        }
    }
}
