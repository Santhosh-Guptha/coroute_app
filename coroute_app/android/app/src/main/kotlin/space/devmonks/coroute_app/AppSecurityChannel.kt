package space.devmonks.coroute_app

import android.annotation.TargetApi
import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.view.WindowManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Round 4 app security (docs/features_355/sessions_and_security.md §10, §11), framework APIs only (no new
 * dependency):
 *
 *  - "setSecure" {on}: FLAG_SECURE on the window while a sensitive screen is shown (sign-in, e-mail code entry,
 *    Medical ID edit form, 2-step prompt). Never set by map or ride screens.
 *  - "lockAvailable": the phone has a secure lock screen (PIN, pattern, password; fingerprint needs one).
 *  - "authenticate" {title, subtitle}: unlock CoRoute with fingerprint / face or the screen lock.
 *      API 30+: BiometricPrompt with BIOMETRIC_WEAK | DEVICE_CREDENTIAL.
 *      API 29:  BiometricPrompt with setDeviceCredentialAllowed(true).
 *      API 28:  BiometricPrompt with a "Use screen lock" button, and the screen lock when no fingerprint is enrolled.
 *      API 23-27: KeyguardManager.createConfirmDeviceCredentialIntent (result in MainActivity.onActivityResult).
 *    Answers "ok", "cancelled", "unavailable" (no secure lock screen: the app never locks then), "busy" or "error".
 *  - "openMedicalId": the lock-screen Medical ID card (MedicalIdActivity, shown over the lock screen, no unlock).
 */
class AppSecurityChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val REQUEST_CONFIRM = 7311
        // BiometricPrompt.BIOMETRIC_ERROR_NEGATIVE_BUTTON (API 28 sends it with the "Use screen lock" button).
        private const val ERROR_NEGATIVE_BUTTON = 13
    }

    private var pending: MethodChannel.Result? = null
    private var cancel: CancellationSignal? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setSecure" -> {
                val on = call.argument<Boolean>("on") == true
                activity.runOnUiThread {
                    if (on) {
                        activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                }
                result.success(null)
            }
            "lockAvailable" -> result.success(deviceSecure())
            "authenticate" -> authenticate(
                call.argument<String>("title") ?: "Unlock CoRoute",
                call.argument<String>("subtitle") ?: "",
                result,
            )
            "openMedicalId" -> result.success(openMedicalId())
            else -> result.notImplemented()
        }
    }

    private fun keyguard(): KeyguardManager? = activity.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager

    private fun deviceSecure(): Boolean = try { keyguard()?.isDeviceSecure == true } catch (_: Exception) { false }

    private fun finish(value: String) {
        val r = pending
        pending = null
        cancel = null
        try { r?.success(value) } catch (_: Exception) { /* already answered */ }
    }

    private fun authenticate(title: String, subtitle: String, result: MethodChannel.Result) {
        if (pending != null) {
            result.success("busy")
            return
        }
        if (!deviceSecure()) {
            result.success("unavailable")
            return
        }
        pending = result
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                biometric(title, subtitle)
                return
            } catch (_: Exception) {
                // falls back to the screen lock
            }
        }
        confirmCredential(title, subtitle)
    }

    @Suppress("DEPRECATION")
    private fun confirmCredential(title: String, subtitle: String) {
        val intent: Intent? = try { keyguard()?.createConfirmDeviceCredentialIntent(title, subtitle) } catch (_: Exception) { null }
        if (intent == null) {
            finish("unavailable")
            return
        }
        try {
            activity.startActivityForResult(intent, REQUEST_CONFIRM)
        } catch (_: Exception) {
            finish("error")
        }
    }

    /** From MainActivity.onActivityResult: true when it was the screen lock confirmation. */
    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != REQUEST_CONFIRM) return false
        finish(if (resultCode == Activity.RESULT_OK) "ok" else "cancelled")
        return true
    }

    @TargetApi(Build.VERSION_CODES.P)
    @Suppress("DEPRECATION")
    private fun biometric(title: String, subtitle: String) {
        val executor = activity.mainExecutor
        val builder = BiometricPrompt.Builder(activity).setTitle(title)
        if (subtitle.isNotEmpty()) builder.setSubtitle(subtitle)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL,
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setDeviceCredentialAllowed(true)
        } else {
            builder.setNegativeButton("Use screen lock", executor) { _, _ -> confirmCredential(title, subtitle) }
        }
        val signal = CancellationSignal()
        cancel = signal
        builder.build().authenticate(signal, executor, object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult?) {
                finish("ok")
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) {
                if (errorCode == ERROR_NEGATIVE_BUTTON) return // the screen lock opens instead
                // Android 9 without an enrolled fingerprint (or no sensor): the screen lock instead.
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && (
                        errorCode == BiometricPrompt.BIOMETRIC_ERROR_NO_BIOMETRICS ||
                            errorCode == BiometricPrompt.BIOMETRIC_ERROR_HW_NOT_PRESENT ||
                            errorCode == BiometricPrompt.BIOMETRIC_ERROR_HW_UNAVAILABLE
                        )
                ) {
                    confirmCredential(title, subtitle)
                    return
                }
                val cancelled = errorCode == BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED || errorCode == BiometricPrompt.BIOMETRIC_ERROR_CANCELED
                finish(if (cancelled) "cancelled" else "error")
            }
        })
    }

    private fun openMedicalId(): Boolean {
        return try {
            val intent = Intent(activity, MedicalIdActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    fun dispose() {
        try { cancel?.cancel() } catch (_: Exception) { /* gone */ }
        cancel = null
        finish("cancelled")
    }
}
