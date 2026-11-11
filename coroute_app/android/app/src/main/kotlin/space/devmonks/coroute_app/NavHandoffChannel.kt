package space.devmonks.coroute_app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 3.55 "Navigate in Google Maps / Mappls" (MethodChannel "coroute/nav_handoff").
 *
 * - `installed` {packages: [String]} -> {package: Boolean}: whether each navigation app is installed.
 *   Needs the <queries> <package> entries in AndroidManifest.xml on Android 11+ (package visibility).
 * - `open` {uri, package} -> Boolean: ACTION_VIEW of the uri sent only to that package. False when the
 *   app is missing or does not take the link (Dart then tries the next link).
 *
 * The ride's foreground service is not touched: the ride, intercom and safety keep running while the
 * other app navigates; the ride notification brings the rider back to CoRoute.
 */
class NavHandoffChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "installed" -> {
                val out = HashMap<String, Boolean>()
                val packages = call.argument<List<String>>("packages") ?: emptyList()
                for (p in packages) out[p] = isInstalled(p)
                result.success(out)
            }
            "open" -> {
                val uri = call.argument<String>("uri")
                val pkg = call.argument<String>("package")
                if (uri.isNullOrEmpty() || pkg.isNullOrEmpty()) {
                    result.success(false)
                    return
                }
                result.success(open(uri, pkg))
            }
            else -> result.notImplemented()
        }
    }

    private fun isInstalled(pkg: String): Boolean {
        return try {
            val pm = activity.packageManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(pkg, 0)
            }
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        } catch (e: Exception) {
            false
        }
    }

    private fun open(uri: String, pkg: String): Boolean {
        if (activity.isFinishing || activity.isDestroyed) return false
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uri))
            intent.setPackage(pkg)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        } catch (e: Exception) {
            false
        }
    }
}
